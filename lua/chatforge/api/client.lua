local M        = {}
local config   = require("chatforge.config")
local state    = require("chatforge.core.state")
local log      = require("chatforge.utils.logger")
local backend_control = require("chatforge.api.backend_control")

--- Send messages to whatever backend the buffer has selected.
---@param src_bufnr number          source (non-chat) buffer
---@param messages  {role:string, content:string}[]
---@param on_done   fun(text:string|nil, err:string|nil)
---@param request_id number|nil
---@param opts table|nil
function M.complete(src_bufnr, messages, on_done, request_id, opts)
  if state.loading then
    on_done(nil, "A request is already in progress.")
    return
  end

  local cfg = config.values
  local provider_name = state.get_provider(src_bufnr) or cfg.default_provider or "ollama"
  local providers = require("chatforge.providers")
  local be = providers.get(provider_name)

  if not be then
    on_done(nil, "Provider '" .. provider_name .. "' not found.")
    return
  end

  local model = state.get_model(src_bufnr)

  -- Prepend system prompt
  local full = {}
  if cfg.system_prompt ~= "" then
    table.insert(full, { role = "system", content = cfg.system_prompt })
  end
  for _, m in ipairs(messages) do table.insert(full, m) end

  state.loading = true
  log.log("client.complete: provider=%s model=%s msgs=%d", provider_name, model, #full)

  opts = vim.tbl_deep_extend("force", {
    temperature = cfg.temperature,
    max_output_tokens = cfg.max_output_tokens or cfg.max_tokens,
    context_tokens = cfg.context_tokens,
  }, opts or {})

  local cancel_handle = be.stream({
    model = model,
    messages = full,
    options = {
      temperature = opts.temperature,
      max_tokens = opts.max_output_tokens,
      context_tokens = opts.context_tokens,
    }
  }, {
    on_chunk = function(chunk)
      if opts.stream and opts.on_delta then
        opts.on_delta(chunk)
      end
    end,
    on_done = function(text)
      if request_id and request_id ~= state.request_id then
        return
      end
      state.loading = false
      state.active_request_cancel = nil
      on_done(text, nil)
    end,
    on_error = function(err)
      if request_id and request_id ~= state.request_id then
        return
      end
      state.loading = false
      state.active_request_cancel = nil
      if err and err:match("Ollama unreachable") then
        backend_control.offer_ollama_start(err)
      elseif err and (err:lower():match("model") and (err:lower():match("not found") or err:lower():match("pull"))) then
        backend_control.offer_model_pull(model, err)
      end
      on_done(nil, err)
    end
  })

  if cancel_handle then
    state.active_request_cancel = cancel_handle.cancel
  end
end

return M
