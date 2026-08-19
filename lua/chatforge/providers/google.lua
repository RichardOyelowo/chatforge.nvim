local log = require("chatforge.utils.logger")
local env = require("chatforge.utils.env")

local M = {}

local function provider_config()
  local config = require("chatforge.config").values
  local prov_cfg = (config.providers and config.providers.google) or {}
  local base_url = prov_cfg.base_url or "https://generativelanguage.googleapis.com/v1beta"
  local api_key = prov_cfg.api_key
    or env.get("GOOGLE_API_KEY")
    or env.get("GEMINI_API_KEY")
  return base_url, api_key
end

-- Gemini takes a role-tagged contents array like Anthropic/OpenAI, but with
-- "model" instead of "assistant", parts instead of a flat content string,
-- and the system prompt as its own top-level field instead of a message.
local function to_gemini_contents(messages)
  local system_instruction = nil
  local contents = {}
  for _, msg in ipairs(messages or {}) do
    if msg.role == "system" then
      system_instruction = { parts = { { text = msg.content } } }
    else
      table.insert(contents, {
        role = msg.role == "assistant" and "model" or "user",
        parts = { { text = msg.content } },
      })
    end
  end
  return contents, system_instruction
end

function M.stream(params, handlers)
  local base_url, api_key = provider_config()

  if not api_key or api_key == "" then
    handlers.on_error("GOOGLE_API_KEY (or GEMINI_API_KEY) environment variable is not set.")
    return nil
  end

  local model = params.model or "gemini-2.5-flash"
  local contents, system_instruction = to_gemini_contents(params.messages)

  local payload = {
    contents = contents,
    generationConfig = {
      temperature = params.options.temperature,
      maxOutputTokens = params.options.max_tokens,
    },
  }
  if system_instruction then
    payload.systemInstruction = system_instruction
  end

  local url = base_url .. "/models/" .. model .. ":streamGenerateContent?alt=sse"
  local body = vim.json.encode(payload)

  local cmd = {
    "curl", "--silent", "--no-buffer",
    "-X", "POST", url,
    "-H", "Content-Type: application/json",
    "-H", "x-goog-api-key: " .. api_key,
    "-d", body,
  }

  local text = ""
  local pending = ""
  local stderr = {}
  local block_reason = nil

  local function handle_line(line)
    if line == "" then return end
    line = line:gsub("\r$", "")

    local data = line:match("^data:%s*(.-)$")
    if not data then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and decoded.error then
        local msg = decoded.error.message or vim.inspect(decoded.error)
        table.insert(stderr, msg)
      end
      return
    end

    local ok, decoded = pcall(vim.json.decode, data)
    if not ok then
      log.err("google stream JSON decode failed: %s", data:sub(1, 200))
      return
    end

    if decoded.promptFeedback and decoded.promptFeedback.blockReason then
      block_reason = decoded.promptFeedback.blockReason
      return
    end

    local candidate = decoded.candidates and decoded.candidates[1]
    if candidate and candidate.content and candidate.content.parts then
      for _, part in ipairs(candidate.content.parts) do
        if part.text then
          text = text .. part.text
          handlers.on_chunk(part.text)
        end
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
        handlers.on_error("Google AI Studio request failed: " .. msg)
        return
      end
      if #stderr > 0 then
        handlers.on_error(table.concat(stderr, "\n"))
        return
      end
      if block_reason then
        handlers.on_error("Google AI Studio blocked the response: " .. block_reason)
        return
      end
      if text == "" then
        handlers.on_error("Empty response from Google AI Studio.")
        return
      end
      handlers.on_done(text)
    end,
  })

  if job <= 0 then
    handlers.on_error("Google AI Studio: could not start curl")
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
    "-H", "x-goog-api-key: " .. api_key,
    url
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
      local supports_chat = false
      for _, method in ipairs(model.supportedGenerationMethods or {}) do
        if method == "streamGenerateContent" or method == "generateContent" then
          supports_chat = true
        end
      end
      if model.name and supports_chat then
        table.insert(models, (model.name:gsub("^models/", "")))
      end
    end
    table.sort(models)
    vim.schedule(function() cb(models) end)
  end)
end

function M.health(cb)
  local base_url, api_key = provider_config()

  if not api_key or api_key == "" then
    vim.schedule(function() cb(false, "GOOGLE_API_KEY (or GEMINI_API_KEY) environment variable is not set") end)
    return
  end

  local url = base_url .. "/models"
  vim.system({
    "curl", "--silent", "--max-time", "2",
    "-H", "x-goog-api-key: " .. api_key,
    url
  }, { text = true }, function(result)
    if result.code ~= 0 then
      vim.schedule(function() cb(false, "Google AI Studio unreachable: " .. (result.stderr ~= "" and result.stderr or ("exit code " .. result.code))) end)
      return
    end
    local ok, payload = pcall(vim.json.decode, result.stdout)
    if not ok or type(payload) ~= "table" then
      vim.schedule(function() cb(false, "Invalid response from Google AI Studio") end)
      return
    end
    if payload.error then
      vim.schedule(function() cb(false, "Google AI Studio: " .. (payload.error.message or "request rejected")) end)
      return
    end
    vim.schedule(function() cb(true, "Google AI Studio reachable") end)
  end)
end

return M
