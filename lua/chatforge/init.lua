-- Commands:
--   :Chat                   open / focus the chat window
--   :ChatSend [message]     no args = focus input area, args = send, visual = send selection
--   :ChatEdit [message]     force a live staged source-buffer edit
--   :ChatModel [model]      set model for current buffer, or open picker
--   :ChatReset              clear history and reopen
--   :ChatApply [N]          accept staged implementation N
--   :ChatAccept             accept the first staged implementation
--   :ChatDiff  [N]          diff block N against current buffer
--   :ChatPreview [N]       preview staged implementation N
--   :ChatReject             discard all pending blocks
--   :ChatBackend <cmd>      manage local backend helpers

local M = {}

M.version = "0.3.0"

function M.setup(opts)
  local config  = require("chatforge.config")
  local log     = require("chatforge.utils.logger")

  config.setup(opts)
  log.setup(config.values.debug)

  local chat     = require("chatforge.ui.chat")
  local actions  = require("chatforge.core.actions")
  local state    = require("chatforge.core.state")
  local dialog   = require("chatforge.ui.dialog")
  local backend_control = require("chatforge.api.backend_control")

  local group = vim.api.nvim_create_augroup("chatforge_source_tracking", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      if state.is_plugin_buf(bufnr) or vim.bo[bufnr].buftype ~= "" then
        return
      end
      state.source_bufnr = bufnr
      state.source_winnr = vim.api.nvim_get_current_win()
    end,
  })

  -- ── :Chat ──────────────────────────────────────────────────────────────
  vim.api.nvim_create_user_command("Chat", function()
    chat.open()
  end, { desc = "Open chatforge window" })

  -- ── :ChatSend [message] ───────────────────────────────────────────────
  -- No args      → focuses the right-side input area
  -- With args    → sends the text directly
  -- Visual range → wraps selected lines in a code block and sends
  vim.api.nvim_create_user_command("ChatSend", function(cmd)
    local src = vim.api.nvim_get_current_buf()

    -- Don't let src be the chat UI itself
    if state.is_plugin_buf(src) then
      src = state.source_bufnr
    end

    if not src or not vim.api.nvim_buf_is_valid(src) then
      vim.notify(
        "[chatforge] Switch to your source buffer first, then run :ChatSend.",
        vim.log.levels.WARN
      )
      return
    end

    local input = nil

    if cmd.range > 0 then
      -- Visual selection: wrap in a fenced code block
      local lines = vim.api.nvim_buf_get_lines(src, cmd.line1 - 1, cmd.line2, false)
      local ft    = vim.bo[src].filetype or ""
      state.edit_target = {
        bufnr = src,
        line1 = cmd.line1,
        line2 = cmd.line2,
        kind = "selection",
      }
      input = string.format(
        "Rewrite only this selected range. Return only the replacement code for these selected lines.\n\n```%s\n%s\n```",
        ft,
        table.concat(lines, "\n")
      )
    elseif cmd.args ~= "" then
      state.edit_target = nil
      input = cmd.args
    else
      state.edit_target = nil
    end
    -- input == nil  →  send_message focuses the right-side input area

    chat.open(src)
    vim.defer_fn(function()
      chat.send_message(src, input)
    end, 80)
  end, { desc = "Send a message to chatforge", nargs = "*", range = true })

  -- ── :ChatEdit [message] ───────────────────────────────────────────────
  vim.api.nvim_create_user_command("ChatEdit", function(cmd)
    local src = vim.api.nvim_get_current_buf()
    if state.is_plugin_buf(src) then
      src = state.source_bufnr
    end

    if not src or not vim.api.nvim_buf_is_valid(src) then
      vim.notify("[chatforge] Switch to your source buffer first, then run :ChatEdit.", vim.log.levels.WARN)
      return
    end

    local input = cmd.args
    if cmd.range > 0 then
      local lines = vim.api.nvim_buf_get_lines(src, cmd.line1 - 1, cmd.line2, false)
      local ft = vim.bo[src].filetype or ""
      state.edit_target = {
        bufnr = src,
        line1 = cmd.line1,
        line2 = cmd.line2,
        kind = "selection",
      }
      input = string.format(
        "Rewrite only this selected range. Return only the replacement code for these selected lines.\n\n```%s\n%s\n```",
        ft,
        table.concat(lines, "\n")
      )
    else
      state.edit_target = nil
    end

    if input == "" then
      vim.notify("[chatforge] Usage: :ChatEdit <change request>", vim.log.levels.WARN)
      return
    end

    chat.open(src)
    vim.defer_fn(function()
      chat.send_message(src, input, { force_stage = true })
    end, 80)
  end, { desc = "Force a live staged chatforge edit", nargs = "*", range = true })

  -- ── :ChatModel / :ChatForgeSelectModel / :ChatForgeSetModel ───────────
  local function select_model_cmd(cmd)
    local src = vim.api.nvim_get_current_buf()
    if state.is_plugin_buf(src) then
      src = state.source_bufnr or src
    end
    local render = require("chatforge.ui.render")
    if cmd.args ~= "" then
      state.set_model(src, cmd.args)
      vim.notify("[chatforge] Model → " .. cmd.args, vim.log.levels.INFO)
      if state.chat_is_open() then
        render.write_header(src)
      end
      return
    end

    local prov = state.get_provider(src)
    local providers = require("chatforge.providers")

    -- Query every registered provider in parallel and build one combined
    -- picker across all of them, rather than only the active buffer's
    -- provider. Providers with no API key configured, or that are
    -- unreachable, simply contribute nothing (list_models already
    -- degrades to an empty list in those cases) instead of erroring.
    local names = providers.list()
    if #names == 0 then
      vim.notify("[chatforge] No providers registered.", vim.log.levels.ERROR)
      return
    end

    local aggregated = {}
    local remaining = #names

    local function finish()
      if #aggregated == 0 then
        if not prov then
          vim.notify(
            "[chatforge] No provider configured for this buffer and no provider returned any models. "
              .. "Run :ChatBackend switch <provider>, where <provider> is one of: "
              .. table.concat(names, ", ") .. ".",
            vim.log.levels.WARN
          )
          return
        end
        dialog.input({ prompt = "Model (" .. prov .. "): ", default = state.get_model(src) }, function(model)
          if model and model ~= "" then
            state.set_model(src, model)
            vim.notify("[chatforge] Model → " .. model, vim.log.levels.INFO)
            if state.chat_is_open() then
              render.write_header(src)
            end
          end
        end)
        return
      end

      table.sort(aggregated, function(a, b)
        if a.provider ~= b.provider then
          return a.provider < b.provider
        end
        return a.model < b.model
      end)

      dialog.select(aggregated, {
        prompt = "Select ChatForge Model (all providers):",
        format_item = function(item)
          local label = item.provider .. "/" .. item.model
          local is_active = item.provider == prov and item.model == state.get_model(src)
          return is_active and (label .. " (active)") or label
        end,
      }, function(choice)
        if choice then
          state.set_provider(src, choice.provider)
          state.set_model(src, choice.model)
          vim.notify("[chatforge] Provider → " .. choice.provider .. ", Model → " .. choice.model, vim.log.levels.INFO)
          if state.chat_is_open() then
            render.write_header(src)
          end
        end
      end)
    end

    for _, name in ipairs(names) do
      local be = providers.get(name)
      local settled = false

      local function settle(models)
        if settled then return end
        settled = true
        for _, m in ipairs(models or {}) do
          table.insert(aggregated, { provider = name, model = m })
        end
        remaining = remaining - 1
        if remaining == 0 then
          finish()
        end
      end

      -- list_models has no built-in request timeout (unlike health()), so a
      -- single slow or unreachable provider must not be able to block the
      -- combined picker for everyone else.
      local timer_id = vim.fn.timer_start(3000, function()
        settle({})
      end)

      be.list_models(function(models)
        pcall(vim.fn.timer_stop, timer_id)
        settle(models)
      end)
    end
  end

  vim.api.nvim_create_user_command("ChatModel", select_model_cmd, { desc = "Set or select chatforge model for current buffer", nargs = "?" })
  vim.api.nvim_create_user_command("ChatForgeSelectModel", select_model_cmd, { desc = "Interactively select chatforge model for current buffer", nargs = "?" })
  vim.api.nvim_create_user_command("ChatForgeSetModel", select_model_cmd, { desc = "Set chatforge model for current buffer", nargs = "?" })

  -- ── :ChatReset ────────────────────────────────────────────────────────
  vim.api.nvim_create_user_command("ChatReset", function()
    local src = vim.api.nvim_get_current_buf()
    if state.is_plugin_buf(src) then
      src = state.source_bufnr or src
    end
    chat.open(src)
    vim.defer_fn(function() chat.reset(src) end, 80)
  end, { desc = "Reset chatforge history" })

  -- ── :ChatApply [N] ───────────────────────────────────────────────────
  local function do_apply(cmd)
    local n = tonumber(cmd.args) or 1
    actions.apply_to_current(n)
  end
  vim.api.nvim_create_user_command("ChatApply", do_apply, { desc = "Accept staged implementation N", nargs = "?" })

  vim.api.nvim_create_user_command("ChatAccept", function()
    actions.accept_current()
  end, { desc = "Accept the first staged implementation" })

  -- ── :ChatDiff [N] ─────────────────────────────────────────────────────
  vim.api.nvim_create_user_command("ChatDiff", function(cmd)
    local n = tonumber(cmd.args) or 1
    actions.diff_with_current(n)
  end, { desc = "Diff pending code block N against current buffer", nargs = "?" })

  vim.api.nvim_create_user_command("ChatReviewDiff", function()
    actions.diff_current()
  end, { desc = "Diff the first staged implementation" })

  vim.api.nvim_create_user_command("ChatPreview", function(cmd)
    actions.preview(tonumber(cmd.args) or 1)
  end, { desc = "Preview pending implementation N", nargs = "?" })

  vim.api.nvim_create_user_command("ChatNextChange", function()
    actions.jump_next()
  end, { desc = "Jump to the next staged implementation line" })

  vim.api.nvim_create_user_command("ChatPrevChange", function()
    actions.jump_prev()
  end, { desc = "Jump to the previous staged implementation line" })

  -- ── :ChatReject ───────────────────────────────────────────────────────
  vim.api.nvim_create_user_command("ChatReject", function()
    actions.reject_all()
  end, { desc = "Reject all pending code blocks" })

  vim.api.nvim_create_user_command("ChatStop", function()
    if state.active_request_cancel then
      state.active_request_cancel()
      state.active_request_cancel = nil
      state.loading = false
      local render_module = require("chatforge.ui.render")
      render_module.stop_forging_status()
      render_module.append_status("Request cancelled.", "error")
      vim.notify("[chatforge] Request cancelled.", vim.log.levels.INFO)
    else
      vim.notify("[chatforge] No active request to stop.", vim.log.levels.INFO)
    end
  end, { desc = "Stop the active chat request" })

  -- ── :ChatBackend status|start|stop|switch|models ─────────────────────
  vim.api.nvim_create_user_command("ChatBackend", function(cmd)
    backend_control.command(cmd.args)
  end, {
    desc = "Manage chatforge backend helpers",
    nargs = "?",
    complete = function()
      return { "status", "start", "stop", "switch", "models" }
    end,
  })

  log.log("chatforge ready  default_model=%s", config.values.default_model)
end

function M.open() require("chatforge.ui.chat").open() end

return M

