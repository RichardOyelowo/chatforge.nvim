local log = require("chatforge.utils.logger")
local env = require("chatforge.utils.env")

local M = {}

local function provider_config()
  local config = require("chatforge.config").values
  local prov_cfg = (config.providers and config.providers.groq) or {}
  local base_url = prov_cfg.base_url or "https://api.groq.com/openai/v1"
  local api_key = prov_cfg.api_key or env.get("GROQ_API_KEY")
  return base_url, api_key
end

function M.stream(params, handlers)
  local base_url, api_key = provider_config()

  if not api_key or api_key == "" then
    handlers.on_error("GROQ_API_KEY environment variable is not set.")
    return nil
  end

  local url = base_url .. "/chat/completions"
  local body = vim.json.encode({
    model = params.model,
    messages = params.messages,
    stream = true,
    temperature = params.options.temperature,
    max_tokens = params.options.max_tokens,
  })

  local cmd = {
    "curl", "--silent", "--no-buffer",
    "-X", "POST", url,
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. api_key,
    "-d", body,
  }

  local text = ""
  local pending = ""
  local stderr = {}

  local function handle_line(line)
    if line == "" then return end
    line = line:gsub("\r$", "")

    if line:match("^data:%s*%[DONE%]") then
      return
    end

    local data = line:match("^data:%s*(.-)$")
    if data then
      local ok, decoded = pcall(vim.json.decode, data)
      if not ok then
        log.err("groq stream JSON decode failed: %s", data:sub(1, 200))
        return
      end
      if decoded.choices and decoded.choices[1] and decoded.choices[1].delta and decoded.choices[1].delta.content then
        local chunk = decoded.choices[1].delta.content
        text = text .. chunk
        handlers.on_chunk(chunk)
      end
    else
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and decoded.error then
        local msg = decoded.error.message or vim.inspect(decoded.error)
        table.insert(stderr, msg)
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
        handlers.on_error("Groq request failed: " .. msg)
        return
      end
      if #stderr > 0 then
        handlers.on_error(table.concat(stderr, "\n"))
        return
      end
      if text == "" then
        handlers.on_error("Empty response from Groq.")
        return
      end
      handlers.on_done(text)
    end,
  })

  if job <= 0 then
    handlers.on_error("Groq: could not start curl")
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
  local base_url, api_key = provider_config()

  if not api_key or api_key == "" then
    vim.schedule(function() cb({}) end)
    return
  end

  local url = base_url .. "/models"
  vim.system({
    "curl", "--silent",
    "-H", "Authorization: Bearer " .. api_key,
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
  local base_url, api_key = provider_config()

  if not api_key or api_key == "" then
    vim.schedule(function() cb(false, "GROQ_API_KEY environment variable is not set") end)
    return
  end

  local url = base_url .. "/models"
  vim.system({
    "curl", "--silent", "--max-time", "2",
    "-H", "Authorization: Bearer " .. api_key,
    url
  }, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function() cb(false, "Groq unreachable: " .. (result.stderr ~= "" and result.stderr or ("exit code " .. result.code))) end)
      return
    end
    local ok, payload = pcall(vim.json.decode, result.stdout)
    if not ok or type(payload) ~= "table" then
      vim.schedule(function() cb(false, "Invalid response from Groq") end)
      return
    end
    vim.schedule(function() cb(true, "Groq reachable") end)
  end)
end

return M
