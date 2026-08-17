local M = {}

local state = require("chatforge.core.state")
local dialog = require("chatforge.ui.dialog")

local function notify(msg, level)
  vim.notify("[chatforge] " .. msg, level or vim.log.levels.INFO)
end

function M.ollama_status()
  if state.ollama_job and vim.fn.jobwait({ state.ollama_job }, 0)[1] == -1 then
    return "managed-running"
  end
  state.ollama_job = nil
  state.ollama_job_stopping = false
  return "not-managed"
end

function M.pull_status()
  if state.ollama_pull_job and vim.fn.jobwait({ state.ollama_pull_job }, 0)[1] == -1 then
    return "pull-running"
  end
  state.ollama_pull_job = nil
  state.ollama_pull_job_stopping = false
  return "pull-idle"
end

function M.start_ollama()
  notify("Run this in a terminal: ollama serve")
end

function M.stop_ollama()
  local stopped = false
  if M.ollama_status() == "managed-running" then
    state.ollama_job_stopping = true
    vim.fn.jobstop(state.ollama_job)
    state.ollama_job = nil
    stopped = true
  end

  if state.ollama_pull_job and vim.fn.jobwait({ state.ollama_pull_job }, 0)[1] == -1 then
    state.ollama_pull_job_stopping = true
    vim.fn.jobstop(state.ollama_pull_job)
    state.ollama_pull_job = nil
    stopped = true
  end

  if not stopped then
    notify("No plugin-managed Ollama server is running.")
    return
  end

  notify("Stopped plugin-managed Ollama process.")
end

function M.offer_ollama_start(reason)
  vim.schedule(function()
    local msg = reason or "Ollama is not reachable."
    dialog.select({
      "Show command",
      "Ignore",
    }, {
      prompt = msg .. " What do you want to do?",
    }, function(choice)
      if choice == "Show command" then
        notify("Run this in a terminal: ollama serve")
      end
    end)
  end)
end

function M.pull_ollama_model(model)
  if not model or model == "" then
    notify("No model selected to pull.", vim.log.levels.WARN)
    return
  end

  if state.ollama_pull_job and vim.fn.jobwait({ state.ollama_pull_job }, 0)[1] == -1 then
    notify("An `ollama pull` job is already running. Stop it with :ChatBackend stop.", vim.log.levels.WARN)
    return
  end

  local job
  job = vim.fn.jobstart({ "ollama", "pull", model }, {
    detach = false,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if data and data[1] and data[1] ~= "" then
        notify("ollama pull: " .. data[1], vim.log.levels.DEBUG)
      end
    end,
    on_stderr = function(_, data)
      if data and data[1] and data[1] ~= "" then
        notify("ollama pull: " .. data[1], vim.log.levels.DEBUG)
      end
    end,
    on_exit = function(_, code)
      if state.ollama_pull_job == job then
        state.ollama_pull_job = nil
      end
      local stopped = state.ollama_pull_job_stopping
      state.ollama_pull_job_stopping = false
      if code == 0 then
        notify("Pulled Ollama model `" .. model .. "`.")
      elseif not stopped then
        notify("`ollama pull " .. model .. "` stopped with code " .. code, vim.log.levels.WARN)
      end
    end,
  })

  if job <= 0 then
    notify("Could not run `ollama pull " .. model .. "`. Run it in a terminal.", vim.log.levels.ERROR)
    return
  end

  state.ollama_pull_job = job
  notify("Started `ollama pull " .. model .. "`. Stop it with :ChatBackend stop.")
end

function M.offer_model_pull(model, reason)
  vim.schedule(function()
    local command = "ollama pull " .. model
    dialog.select({
      "Run `" .. command .. "` from Neovim",
      "Show command only",
      "Ignore",
    }, {
      prompt = (reason or "Model is not available.") .. " What do you want to do?",
    }, function(choice)
      if choice == "Run `" .. command .. "` from Neovim" then
        M.pull_ollama_model(model)
      elseif choice == "Show command only" then
        notify("Run this in a terminal: " .. command)
      end
    end)
  end)
end

function M.command(arg)
  local parts = vim.split(arg or "", "%s+")
  local subcommand = (parts[1] or "status"):lower()

  if subcommand == "start" then
    M.start_ollama()
  elseif subcommand == "stop" then
    M.stop_ollama()
  elseif subcommand == "status" then
    local src = state.source_bufnr or vim.api.nvim_get_current_buf()
    local prov = state.get_provider(src)
    local mod = state.get_model(src)
    notify(string.format("Active provider: %s, Model: %s", prov, mod))
    if prov == "ollama" then
      notify("Ollama backend status: server=" .. M.ollama_status() .. ", pull=" .. M.pull_status())
    end
  elseif subcommand == "switch" then
    local prov = parts[2]
    if not prov or prov == "" then
      notify("Usage: :ChatBackend switch <provider_name>", vim.log.levels.WARN)
      return
    end
    local providers = require("chatforge.providers")
    if not vim.tbl_contains(providers.list(), prov) then
      notify("Unknown provider: " .. prov .. ". Available: " .. table.concat(providers.list(), ", "), vim.log.levels.WARN)
      return
    end
    local src = state.source_bufnr or vim.api.nvim_get_current_buf()
    state.set_provider(src, prov)
    local default_mod = state.default_model_for(prov)
    state.set_model(src, default_mod)
    notify(string.format("Switched buffer to provider '%s' with model '%s'", prov, default_mod))
  elseif subcommand == "models" then
    local src = state.source_bufnr or vim.api.nvim_get_current_buf()
    local prov = state.get_provider(src)
    local providers = require("chatforge.providers")
    local be = providers.get(prov)
    if not be then
      notify("No active provider found for buffer.", vim.log.levels.ERROR)
      return
    end
    notify("Fetching models for " .. prov .. "...")
    be.list_models(function(models)
      if #models == 0 then
        notify("No models found for " .. prov)
      else
        notify("Available models for " .. prov .. ": " .. table.concat(models, ", "))
      end
    end)
  else
    notify("Usage: :ChatBackend status|start|stop|switch|models", vim.log.levels.WARN)
  end
end

return M
