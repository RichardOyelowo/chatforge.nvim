local log = require("chatforge.utils.logger")
local env = require("chatforge.utils.env")

local M = {}

function M.stream(params, handlers)
  local config = require("chatforge.config").values
  local prov_cfg = (config.providers and config.providers.anthropic) or {}
  local base_url = prov_cfg.base_url or "https://api.anthropic.com"
  local api_key = prov_cfg.api_key or env.get("ANTHROPIC_API_KEY")

  if not api_key or api_key == "" then
    handlers.on_error("ANTHROPIC_API_KEY environment variable is not set.")
    return nil
  end

  local system_prompt = nil
  local filtered_messages = {}
  for _, msg in ipairs(params.messages or {}) do
    if msg.role == "system" then
      system_prompt = msg.content
    else
      table.insert(filtered_messages, {
        role = msg.role,
        content = msg.content,
      })
    end
  end

  local payload = {
    model = params.model or "claude-3-5-sonnet-20241022",
    messages = filtered_messages,
    max_tokens = params.options.max_tokens or 4096,
    stream = true,
  }
  if system_prompt then
    payload.system = system_prompt
  end

  local body = vim.json.encode(payload)

  local cmd = {
    "curl", "--silent", "--no-buffer",
    "-X", "POST", base_url .. "/v1/messages",
    "-H", "content-type: application/json",
    "-H", "x-api-key: " .. api_key,
    "-H", "anthropic-version: 2023-06-01",
    "-d", body,
  }

  local text = ""
  local pending = ""
  local stderr = {}

  local function handle_line(line)
    if line == "" then return end
    line = line:gsub("\r$", "")

    local data = line:match("^data:%s*(.-)$")
    if data then
      local ok, decoded = pcall(vim.json.decode, data)
      if not ok then return end
      if decoded.type == "content_block_delta" and decoded.delta and decoded.delta.text then
        local chunk = decoded.delta.text
        text = text .. chunk
        handlers.on_chunk(chunk)
      elseif decoded.type == "error" and decoded.error then
        table.insert(stderr, decoded.error.message or vim.inspect(decoded.error))
      end
    else
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and decoded.error then
        table.insert(stderr, decoded.error.message or vim.inspect(decoded.error))
      end
    end
  end

  local job = vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      pending = pending .. table.concat(data, "\n")
      while true do
        local newline = pending:find("\n", 1, true)
        if not newline then break end
        local line = pending:sub(1, newline - 1)
        pending = pending:sub(newline + 1)
        handle_line(line)
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(stderr, line) end
        end
      end
    end,
    on_exit = function(_, code)
      if pending ~= "" then handle_line(pending) end
      if code ~= 0 then
        local msg = #stderr > 0 and table.concat(stderr, "\n") or ("curl exit " .. code)
        handlers.on_error("Anthropic request failed: " .. msg)
        return
      end
      if #stderr > 0 then
        handlers.on_error(table.concat(stderr, "\n"))
        return
      end
      if text == "" then
        handlers.on_error("Empty response from Anthropic.")
        return
      end
      handlers.on_done(text)
    end,
  })

  if job <= 0 then
    handlers.on_error("Anthropic: could not start curl")
    return nil
  end

  return {
    cancel = function()
      if job > 0 then vim.fn.jobstop(job) end
    end
  }
end

function M.list_models(cb)
  local config = require("chatforge.config").values
  local prov_cfg = (config.providers and config.providers.anthropic) or {}
  local base_url = prov_cfg.base_url or "https://api.anthropic.com"
  local api_key = prov_cfg.api_key or env.get("ANTHROPIC_API_KEY")

  if not api_key or api_key == "" then
    vim.schedule(function() cb({}) end)
    return
  end

  local url = base_url .. "/v1/models"
  vim.system({
    "curl", "--silent",
    "-H", "x-api-key: " .. api_key,
    "-H", "anthropic-version: 2023-06-01",
    url
  }, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function() cb({}) end)
      return
    end
    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok or type(decoded) ~= "table" or not decoded.data then
      vim.schedule(function() cb({}) end)
      return
    end
    local models = {}
    for _, model in ipairs(decoded.data) do
      if model.id then
        table.insert(models, model.id)
      end
    end
    table.sort(models)
    vim.schedule(function() cb(models) end)
  end)
end

function M.health(cb)
  local config = require("chatforge.config").values
  local prov_cfg = (config.providers and config.providers.anthropic) or {}
  local api_key = prov_cfg.api_key or env.get("ANTHROPIC_API_KEY")

  if not api_key or api_key == "" then
    vim.schedule(function() cb(false, "ANTHROPIC_API_KEY environment variable is not set") end)
    return
  end
  vim.schedule(function() cb(true, "Anthropic API key configured") end)
end

return M
