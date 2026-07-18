local M = {}

---@type table<number, { model:string, history:{role:string,content:string,display:string|nil}[] }>
M.buffers = {}

M.chat_bufnr    = nil  ---@type number|nil
M.chat_winnr    = nil  ---@type number|nil
M.input_bufnr   = nil  ---@type number|nil
M.input_winnr   = nil  ---@type number|nil
M.source_bufnr  = nil  ---@type number|nil
M.source_winnr  = nil  ---@type number|nil
M.chat_source_bufnr = nil  ---@type number|nil
M.input_lines = { "" }
M.chat_lines = {}
M.chat_spans = {}
M.chat_entries = {}
M.last_status_entry = nil
M.forging_status_active = false
M.forging_status_entry = nil
M.forging_status_frame = 1
M.render_ns = vim.api.nvim_create_namespace("chatforge_chat_render")
M.loading       = false
M.request_id    = 0
M.applying      = false
M.edit_target   = nil  ---@type {bufnr:number,line1:number,line2:number,kind:string}|nil
M.pending_blocks = {}  ---@type {lang:string,content:string,applied:boolean,target:table|nil}[]
M.staged_changes = {}  ---@type table<number, table>
M.recent_contexts = {}
M.streaming_change = nil
M.ollama_job = nil
M.ollama_pull_job = nil
M.ollama_job_stopping = false
M.ollama_pull_job_stopping = false
M.active_request_cancel = nil

local config
local function default_provider()
  config = config or require("chatforge.config")
  return config.values.default_provider or "ollama"
end

local function default_model(provider_name)
  config = config or require("chatforge.config")
  if provider_name == "openai_compatible" then
    return (config.values.providers and config.values.providers.openai_compatible and config.values.providers.openai_compatible.model) or "gpt-4o"
  end
  return config.values.default_model or "llama3"
end

function M.get_buf(bufnr)
  if not M.buffers[bufnr] then
    local prov = default_provider()
    local mod = default_model(prov)
    M.buffers[bufnr] = { model = mod, provider = prov, history = {} }
  end
  return M.buffers[bufnr]
end

function M.get_model(bufnr)   return M.get_buf(bufnr).model end
function M.set_model(bufnr, model) M.get_buf(bufnr).model = model end

function M.get_provider(bufnr) return M.get_buf(bufnr).provider end
function M.set_provider(bufnr, provider) M.get_buf(bufnr).provider = provider end

function M.append_message(bufnr, role, content, display)
  table.insert(M.get_buf(bufnr).history, { role = role, content = content, display = display })
end

function M.remember_contexts(contexts)
  if type(contexts) ~= "table" then
    return
  end

  for _, context in ipairs(contexts) do
    if context.path and context.block then
      for i = #M.recent_contexts, 1, -1 do
        if M.recent_contexts[i].path == context.path then
          table.remove(M.recent_contexts, i)
        end
      end
      table.insert(M.recent_contexts, 1, context)
    end
  end

  while #M.recent_contexts > 4 do
    table.remove(M.recent_contexts)
  end
end

function M.clear(bufnr)
  if M.buffers[bufnr] then M.buffers[bufnr].history = {} end
  M.pending_blocks = {}
  M.staged_changes = {}
  M.recent_contexts = {}
  M.edit_target = nil
  M.last_status_entry = nil
  M.forging_status_active = false
  M.forging_status_entry = nil
  M.forging_status_frame = 1
end

function M.chat_is_open()
  return M.chat_bufnr ~= nil
    and vim.api.nvim_buf_is_valid(M.chat_bufnr)
    and M.chat_winnr ~= nil
    and vim.api.nvim_win_is_valid(M.chat_winnr)
    and vim.api.nvim_win_get_buf(M.chat_winnr) == M.chat_bufnr
end

function M.input_is_open()
  return M.chat_is_open()
    and M.input_bufnr ~= nil
    and vim.api.nvim_buf_is_valid(M.input_bufnr)
    and M.input_winnr ~= nil
    and vim.api.nvim_win_is_valid(M.input_winnr)
    and vim.api.nvim_win_get_buf(M.input_winnr) == M.input_bufnr
end

function M.is_plugin_buf(bufnr)
  return bufnr == M.chat_bufnr or bufnr == M.input_bufnr
end

return M
