local M = {}

local function runtime_file(path)
  return #vim.api.nvim_get_runtime_file(path, false) > 0
end

local function configured_values()
  local config = require("chatforge.config")
  if next(config.values) then
    return config.values, true
  end
  return config.defaults, false
end

local function check_ollama(cfg)
  if vim.fn.executable("curl") ~= 1 then
    return
  end

  local result = vim.system({
    "curl",
    "--silent",
    "--show-error",
    "--max-time",
    "2",
    cfg.ollama_url .. "/api/tags",
  }, { text = true }):wait()

  if result.code ~= 0 then
    vim.health.warn("Ollama is not reachable at " .. cfg.ollama_url, {
      "Start it with: ollama serve",
      "Check ollama_url in require('chatforge').setup().",
    })
    return
  end

  local ok, payload = pcall(vim.json.decode, result.stdout)
  if not ok or type(payload) ~= "table" then
    vim.health.error("Ollama returned an invalid response from /api/tags")
    return
  end

  vim.health.ok("Ollama is reachable at " .. cfg.ollama_url)
  for _, model in ipairs(payload.models or {}) do
    local name = model.name or model.model
    if name == cfg.default_model then
      vim.health.ok("Default model is installed: " .. cfg.default_model)
      return
    end
  end
  vim.health.warn("Default model is not installed: " .. cfg.default_model, {
    "Run: ollama pull " .. cfg.default_model,
  })
end

function M.check()
  vim.health.start("chatforge.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim 0.10 or newer")
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl is executable")
  else
    vim.health.error("curl was not found in $PATH")
  end

  local cfg, loaded = configured_values()
  if loaded then
    vim.health.ok("Plugin configuration is loaded")
  else
    vim.health.warn("setup() has not run in this session; checking defaults")
  end

  local state_dir = vim.fn.stdpath("state")
  if vim.fn.isdirectory(state_dir) == 1 and vim.fn.filewritable(state_dir) == 2 then
    vim.health.ok("State directory is writable: " .. state_dir)
  else
    vim.health.error("State directory is not writable: " .. state_dir)
  end

  check_ollama(cfg)

  if runtime_file("lua/render-markdown/init.lua") then
    vim.health.ok("Optional render-markdown.nvim detected")
  else
    vim.health.info("Optional render-markdown.nvim not detected")
  end

  if runtime_file("lua/dressing/init.lua") then
    vim.health.ok("Optional dressing.nvim detected")
  else
    vim.health.info("Optional dressing.nvim not detected")
  end
end

return M
