local log = require("chatforge.utils.logger")

local M = {}

function M.stream(params, handlers)
  local config = require("chatforge.config").values
  local url = config.ollama_url .. "/api/chat"
  
  local body = vim.json.encode({
    model = params.model,
    messages = params.messages,
    stream = true,
    options = {
      temperature = params.options.temperature,
      num_predict = params.options.max_tokens,
      num_ctx = params.options.context_tokens,
    },
  })

  local cmd = {
    "curl", "--silent", "--no-buffer",
    "-X", "POST", url,
    "-H", "Content-Type: application/json",
    "-d", body,
  }

  local text = ""
  local pending = ""
  local stderr = {}

  local function handle_line(line)
    if line == "" then return end
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok then
      log.err("ollama stream JSON decode failed: %s", line:sub(1, 200))
      return
    end
    if decoded.error then
      table.insert(stderr, type(decoded.error) == "string" and decoded.error or vim.inspect(decoded.error))
      return
    end
    if decoded.message and decoded.message.content then
      local chunk = decoded.message.content
      text = text .. chunk
      handlers.on_chunk(chunk)
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
          if line ~= "" then
            table.insert(stderr, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if pending ~= "" then
        handle_line(pending)
      end
      if code ~= 0 then
        local msg = #stderr > 0 and table.concat(stderr, "\n") or ("curl exit " .. code)
        handlers.on_error("Ollama unreachable: " .. msg)
        return
      end
      if #stderr > 0 then
        handlers.on_error(table.concat(stderr, "\n"))
        return
      end
      if text == "" then
        handlers.on_error("Empty response from Ollama.")
        return
      end
      handlers.on_done(text)
    end,
  })

  if job <= 0 then
    handlers.on_error("Ollama unreachable: could not start curl")
    return nil
  end

  return {
    cancel = function()
      if job > 0 then
        vim.fn.jobstop(job)
      end
    end
  }
end

function M.list_models(cb)
  local config = require("chatforge.config").values
  local url = config.ollama_url .. "/api/tags"
  
  vim.system({
    "curl", "--silent", url
  }, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function() cb({}) end)
      return
    end
    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok or type(decoded) ~= "table" or not decoded.models then
      vim.schedule(function() cb({}) end)
      return
    end
    local models = {}
    for _, model in ipairs(decoded.models) do
      table.insert(models, model.name or model.model)
    end
    vim.schedule(function() cb(models) end)
  end)
end

function M.health(cb)
  local config = require("chatforge.config").values
  local url = config.ollama_url .. "/api/tags"

  vim.system({
    "curl", "--silent", "--show-error", "--max-time", "2", url
  }, { text = true }, function(result)
    if result.code ~= 0 then
      local msg = result.stderr ~= "" and result.stderr or ("exit code " .. result.code)
      vim.schedule(function() cb(false, "Ollama unreachable at " .. config.ollama_url .. ": " .. msg) end)
      return
    end
    local ok, payload = pcall(vim.json.decode, result.stdout)
    if not ok or type(payload) ~= "table" then
      vim.schedule(function() cb(false, "Invalid response from Ollama") end)
      return
    end
    vim.schedule(function() cb(true, "Ollama reachable at " .. config.ollama_url) end)
  end)
end

return M
