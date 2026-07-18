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

local function check_providers()
  if vim.fn.executable("curl") ~= 1 then
    return
  end
  local providers = require("chatforge.providers")
  for _, name in ipairs(providers.list()) do
    local be = providers.get(name)
    if be and be.health then
      local done = false
      be.health(function(ok, msg)
        if ok then
          vim.health.ok(name .. ": " .. msg)
        else
          vim.health.warn(name .. ": " .. msg)
        end
        done = true
      end)
      local start = vim.loop.hrtime()
      while not done and (vim.loop.hrtime() - start) < 2.5e9 do
        vim.cmd("sleep 10m")
      end
      if not done then
        vim.health.warn(name .. ": health check timed out")
      end
    end
  end
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

  check_providers()

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
