local failures = {}
local passed = 0

local function fail(message)
  error(message, 2)
end

local function equal(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    fail(string.format(
      "%s\nexpected: %s\nactual:   %s",
      message or "values differ",
      vim.inspect(expected),
      vim.inspect(actual)
    ))
  end
end

local function truthy(value, message)
  if not value then
    fail(message or "expected a truthy value")
  end
end

local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("ok - " .. name)
  else
    table.insert(failures, name .. "\n" .. err)
    print("not ok - " .. name)
  end
end

local function reset_state()
  local state = require("chatforge.core.state")
  state.buffers = {}
  state.chat_bufnr = nil
  state.chat_winnr = nil
  state.input_bufnr = nil
  state.input_winnr = nil
  state.source_bufnr = nil
  state.source_winnr = nil
  state.chat_source_bufnr = nil
  state.chat_entries = {}
  state.pending_blocks = {}
  state.staged_changes = {}
  state.streaming_change = nil
  state.edit_target = nil
  state.applying = false
  state.loading = false
  return state
end

require("chatforge.config").setup({ default_model = "test-model" })

test("parser keeps text and indexes multiple fenced blocks", function()
  local parser = require("chatforge.core.parser")
  local segments = parser.parse("First\n```lua\na = 1\n```\nSecond\n```js\nb = 2\n```")
  local blocks = parser.extract_code_blocks("```lua\na = 1\n```\n```js\nb = 2\n```")

  equal(#blocks, 2, "two code blocks should be extracted")
  equal(blocks[1].index, 1)
  equal(blocks[2].index, 2)
  equal(blocks[1].content, "a = 1")
  equal(blocks[2].lang, "js")
  truthy(segments[1].content:find("First", 1, true), "leading text should remain")
end)

test("bare @file injects the live buffer without consuming prose", function()
  local dispatcher = require("chatforge.core.dispatcher")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
  vim.bo[bufnr].filetype = "lua"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local live = true" })

  local prompt = dispatcher.dispatch("can you see @file fully?", bufnr).prompt
  truthy(prompt:find("local live = true", 1, true), "live buffer content should be injected")
  truthy(prompt:find("fully?", 1, true), "prose after @file should remain")
  truthy(not prompt:find("fully? could not be read", 1, true), "prose must not become a path")
  truthy(prompt:find("accessible user%-provided code"), "context should be labelled for the model")
end)

test("named file context uses braced syntax and supports spaces", function()
  local dispatcher = require("chatforge.core.dispatcher")
  local path = vim.fn.tempname() .. " named.lua"
  vim.fn.writefile({ "local named = true" }, path)

  local prompt = dispatcher.dispatch("review @{file " .. path .. "} please", vim.api.nvim_get_current_buf()).prompt
  truthy(prompt:find("local named = true", 1, true), "named file content should be injected")
  truthy(prompt:find("please", 1, true), "text after named context should remain")
  truthy(not prompt:find("CHATFORGE_CONTEXT", 1, true), "internal placeholders must not leak")
  vim.fn.delete(path)
end)

test("injected source is not recursively parsed for context tokens", function()
  local dispatcher = require("chatforge.core.dispatcher")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "-- example: @{file missing.lua}", "return true" })

  local prompt = dispatcher.dispatch("review @file", bufnr).prompt
  truthy(prompt:find("@{file missing.lua}", 1, true), "source token should remain literal")
  truthy(not prompt:find("missing.lua} could not be read", 1, true), "injected source must not be expanded")
end)

test("edit intent stages by default and review intent stays chat", function()
  local dispatcher = require("chatforge.core.dispatcher")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
  vim.bo[bufnr].filetype = "lua"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = 1" })

  local edit = dispatcher.dispatch("please update this to return two", bufnr)
  equal(edit.action, "edit_file")
  truthy(edit.stage, "edit intent should be stageable")
  truthy(edit.prompt:find("complete replacement", 1, true), "edit prompt should ask for a full replacement")
  truthy(edit.prompt:find("local value = 1", 1, true), "edit prompt should include the live buffer")

  local review = dispatcher.dispatch("how is my code @file ?", bufnr)
  equal(review.action, "chat")
  truthy(not review.stage, "review intent should not stage by default")
  truthy(review.prompt:find("local value = 1", 1, true), "explicit context should still be included")

  local context_question = dispatcher.dispatch("use @dir to explain the project layout", bufnr)
  equal(context_question.action, "chat")
  truthy(not context_question.stage, "directory explanation should not stage")
end)

test("forced staging turns a normal prompt into an edit request", function()
  local dispatcher = require("chatforge.core.dispatcher")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].filetype = "lua"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "return 1" })

  local forced = dispatcher.dispatch("make this cleaner", bufnr, { force_stage = true })
  equal(forced.action, "edit_file")
  truthy(forced.stage, "forced prompt should be stageable")
  truthy(forced.prompt:find("complete replacement", 1, true), "forced prompt should use edit instructions")
end)

test("dialog wrapper falls back to native vim.ui", function()
  package.loaded["chatforge.ui.dialog"] = nil
  package.loaded["dressing"] = nil
  local old_input = vim.ui.input
  local called = false
  vim.ui.input = function(opts, cb)
    called = opts.prompt == "Model: "
    cb("fallback-model")
  end

  local dialog = require("chatforge.ui.dialog")
  local value = nil
  dialog.input({ prompt = "Model: " }, function(model)
    value = model
  end)

  vim.ui.input = old_input
  truthy(called, "native vim.ui.input should be called")
  equal(value, "fallback-model")
end)

test("dialog wrapper sets up dressing when available", function()
  package.loaded["chatforge.ui.dialog"] = nil
  package.loaded["dressing"] = nil
  local setup_count = 0
  package.preload["dressing"] = function()
    return {
      setup = function()
        setup_count = setup_count + 1
      end,
    }
  end

  local old_select = vim.ui.select
  vim.ui.select = function(items, _, cb)
    cb(items[1])
  end

  local dialog = require("chatforge.ui.dialog")
  local choice = nil
  dialog.select({ "one", "two" }, { prompt = "Pick:" }, function(selected)
    choice = selected
  end)
  dialog.select({ "one", "two" }, { prompt = "Pick:" }, function() end)

  vim.ui.select = old_select
  package.preload["dressing"] = nil
  package.loaded["dressing"] = nil

  equal(choice, "one")
  equal(setup_count, 1, "dressing should be set up once")
end)

test("sessions remain isolated by source buffer", function()
  local state = reset_state()
  local first = vim.api.nvim_create_buf(false, true)
  local second = vim.api.nvim_create_buf(false, true)

  state.append_message(first, "user", "first")
  state.append_message(second, "user", "second")
  state.set_model(first, "model-a")

  equal(state.get_buf(first).history[1].content, "first")
  equal(state.get_buf(second).history[1].content, "second")
  equal(state.get_model(first), "model-a")
  equal(state.get_model(second), "test-model")
end)

test("streamed staging changes the live buffer and reject restores it", function()
  local state = reset_state()
  local actions = require("chatforge.core.actions")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = 1" })
  state.source_bufnr = bufnr
  state.pending_blocks = {
    {
      content = "local value = 2",
      lang = "lua",
      target_bufnr = bufnr,
      stageable = true,
    },
  }

  truthy(actions.start_stream_preview(1, state.pending_blocks[1]), "stream preview should start")
  actions.append_stream_preview("local value = 2\n")
  local change = actions.finish_stream_preview()

  truthy(change, "stream preview should produce staged metadata")
  truthy(change.id and change.id ~= "", "staged change should have an id")
  equal(change.status, "pending")
  equal(change.original_lines, { "local value = 1" })
  equal(change.proposed_lines, { "local value = 2" })
  truthy(change.staged_changedtick, "staged changedtick should be recorded")
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { "local value = 2" })
  truthy(state.staged_changes[1], "change should remain pending")

  actions.reject_all()
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { "local value = 1" })
  equal(state.staged_changes, {})
end)

test("reject refuses to overwrite edits made after staging", function()
  local state = reset_state()
  local actions = require("chatforge.core.actions")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = 1" })
  state.source_bufnr = bufnr
  state.pending_blocks = {
    {
      content = "local value = 2",
      lang = "lua",
      target_bufnr = bufnr,
      stageable = true,
      model = "test-model",
      prompt_summary = "change the value",
    },
  }

  truthy(actions.start_stream_preview(1, state.pending_blocks[1]))
  actions.append_stream_preview("local value = 2\n")
  actions.finish_stream_preview()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local user_edit = 3" })

  actions.accept_current()
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { "local user_edit = 3" })
  truthy(state.staged_changes[1], "stale proposal must not be accepted")

  actions.reject_all()
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { "local user_edit = 3" })
  truthy(state.staged_changes[1], "stale proposal should remain available for review")
end)

if #failures > 0 then
  print(string.format("\n%d passed, %d failed", passed, #failures))
  for _, failure in ipairs(failures) do
    print("\n" .. failure)
  end
  vim.cmd("cquit 1")
else
  print(string.format("\n%d passed, 0 failed", passed))
  vim.cmd("qa!")
end
