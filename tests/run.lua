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
  state.forging_status_active = false
  state.forging_status_entry = nil
  state.forging_status_frame = 1
  state.pending_blocks = {}
  state.staged_changes = {}
  state.recent_contexts = {}
  state.streaming_change = nil
  state.edit_target = nil
  state.applying = false
  state.loading = false
  return state
end

-- default_provider stays "ollama" here so default_model below (a generic
-- placeholder, not tied to any real provider) is what buffers actually get.
-- Anthropic, OpenAI-compatible, and DeepSeek each ship their own baked-in
-- providers.<name>.model, which default_model_for() prefers over this value.
require("chatforge.config").setup({ default_provider = "ollama", default_model = "test-model" })

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

test("afile shorthand injects named file context", function()
  local dispatcher = require("chatforge.core.dispatcher")
  local path = vim.fn.tempname() .. " shorthand.html"
  vim.fn.writefile({ "<main class=\"content\"></main>" }, path)

  local result = dispatcher.dispatch("review {afile " .. path .. "}", vim.api.nvim_get_current_buf())
  truthy(result.prompt:find("<main class=\"content\"></main>", 1, true), "afile shorthand should inject file content")
  equal(#result.contexts, 1)

  vim.fn.delete(path)
end)

test("related file context carries across buffers", function()
  local dispatcher = require("chatforge.core.dispatcher")
  local state = reset_state()
  local html_path = vim.fn.tempname() .. ".html"
  vim.fn.writefile({ "<button class=\"btn_primary\" id=\"save_btn\">Save</button>" }, html_path)

  local html_buf = vim.api.nvim_create_buf(false, true)
  local first = dispatcher.dispatch("this is the html @{file " .. html_path .. "}", html_buf)
  state.remember_contexts(first.contexts)

  local css_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(css_buf, vim.fn.tempname() .. ".css")
  vim.bo[css_buf].filetype = "css"
  vim.api.nvim_buf_set_lines(css_buf, 0, -1, false, { ".btn_primary { color: white; }" })

  local second = dispatcher.dispatch("does this css match the html @file?", css_buf, {
    related_contexts = state.recent_contexts,
  })

  truthy(second.prompt:find(".btn_primary { color: white; }", 1, true), "current css should be included")
  truthy(second.prompt:find("save_btn", 1, true), "recent html should be included")

  vim.fn.delete(html_path)
end)

test("source text does not control intent classification", function()
  local dispatcher = require("chatforge.core.dispatcher")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
  vim.bo[bufnr].filetype = "lua"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "-- please update this later", "return true" })

  local result = dispatcher.dispatch("review @file", bufnr)
  equal(result.action, "chat")
  truthy(not result.stage, "review should not stage because source text contains edit words")
end)

test("chat reset clears remembered related file context", function()
  local state = reset_state()
  state.remember_contexts({
    { path = "one.html", block = "html" },
  })
  equal(#state.recent_contexts, 1)

  state.clear(1)
  equal(state.recent_contexts, {})
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
  truthy(edit.prompt:find("SEARCH/REPLACE", 1, true), "edit prompt should ask for exact patches")
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
  truthy(forced.prompt:find("SEARCH/REPLACE", 1, true), "forced prompt should use edit instructions")
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

test("chat input uses local completion menu settings", function()
  local state = reset_state()
  local chat = require("chatforge.ui.chat")
  local source = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(source)

  chat.open(source)

  truthy(state.input_bufnr and vim.api.nvim_buf_is_valid(state.input_bufnr), "input buffer should exist")
  equal(vim.bo[state.input_bufnr].completeopt, "menuone,noinsert,noselect")

  if state.chat_winnr and vim.api.nvim_win_is_valid(state.chat_winnr) then
    vim.api.nvim_win_close(state.chat_winnr, true)
  end
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
      target = {
        bufnr = bufnr,
        line1 = 1,
        line2 = 1,
        kind = "selection",
      },
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

test("inferred streamed staging inserts without clearing the file", function()
  local state = reset_state()
  local actions = require("chatforge.core.actions")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "local before = true",
    "local anchor = true",
    "local after = true",
  })
  state.source_bufnr = bufnr
  state.source_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.source_winnr, bufnr)
  vim.api.nvim_win_set_cursor(state.source_winnr, { 2, 0 })
  state.pending_blocks = {
    {
      content = "local inserted = true",
      lang = "lua",
      target_bufnr = bufnr,
      stageable = true,
    },
  }

  truthy(actions.start_stream_preview(1, state.pending_blocks[1]), "stream preview should start")
  actions.append_stream_preview("local inserted = true\n")
  local change = actions.finish_stream_preview()

  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
    "local before = true",
    "local inserted = true",
    "local anchor = true",
    "local after = true",
  })
  equal(change.original_lines, {})
  equal(change.start_line, 2)

  actions.reject_all()
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
    "local before = true",
    "local anchor = true",
    "local after = true",
  })
end)

test("search replace patch stages only matching source range", function()
  local state = reset_state()
  local actions = require("chatforge.core.actions")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "import datetime as dt",
    "import smtplib",
    "from random import randint",
    "import pandas",
    "",
    "#................................. converting csv to dictionary ............................................",
    "data = pandas.read_csv(\"birthdays.csv\")",
    "pandas.DataFrame(data)",
    "data_dict = data.to_dict(\"records\")",
    "",
    "#.................................. working with birthday_date .............................................",
    "now = dt.datetime.now()",
  })
  state.source_bufnr = bufnr
  state.pending_blocks = {
    {
      content = table.concat({
        "------- SEARCH",
        "#................................. converting csv to dictionary ............................................",
        "data = pandas.read_csv(\"birthdays.csv\")",
        "pandas.DataFrame(data)",
        "data_dict = data.to_dict(\"records\")",
        "=======",
        "# Convert CSV data to list of dictionaries",
        "data = pandas.read_csv(\"birthdays.csv\")",
        "data_dict = data.to_dict(\"records\")",
        "+++++++ REPLACE",
      }, "\n"),
      lang = "diff",
      target_bufnr = bufnr,
      stageable = true,
    },
  }

  actions.stage_preview(1)

  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
    "import datetime as dt",
    "import smtplib",
    "from random import randint",
    "import pandas",
    "",
    "# Convert CSV data to list of dictionaries",
    "data = pandas.read_csv(\"birthdays.csv\")",
    "data_dict = data.to_dict(\"records\")",
    "",
    "#.................................. working with birthday_date .............................................",
    "now = dt.datetime.now()",
  })
  truthy(state.staged_changes[1], "patch should stage a pending change")
  equal(state.staged_changes[1].start_line, 6)
  equal(state.staged_changes[1].original_lines, {
    "#................................. converting csv to dictionary ............................................",
    "data = pandas.read_csv(\"birthdays.csv\")",
    "pandas.DataFrame(data)",
    "data_dict = data.to_dict(\"records\")",
  })

  actions.reject_all()
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
    "import datetime as dt",
    "import smtplib",
    "from random import randint",
    "import pandas",
    "",
    "#................................. converting csv to dictionary ............................................",
    "data = pandas.read_csv(\"birthdays.csv\")",
    "pandas.DataFrame(data)",
    "data_dict = data.to_dict(\"records\")",
    "",
    "#.................................. working with birthday_date .............................................",
    "now = dt.datetime.now()",
  })
end)

test("search replace patch supports multiple sections", function()
  local state = reset_state()
  local actions = require("chatforge.core.actions")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "local one = 1",
    "local keep = true",
    "local two = 2",
  })
  state.source_bufnr = bufnr
  state.pending_blocks = {
    {
      content = table.concat({
        "------- SEARCH",
        "local one = 1",
        "=======",
        "local one = 10",
        "+++++++ REPLACE",
        "------- SEARCH",
        "local two = 2",
        "=======",
        "local two = 20",
        "+++++++ REPLACE",
      }, "\n"),
      lang = "diff",
      target_bufnr = bufnr,
      stageable = true,
    },
  }

  actions.stage_preview(1)

  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
    "local one = 10",
    "local keep = true",
    "local two = 20",
  })
  equal(state.staged_changes[1].original_lines, {
    "local one = 1",
    "local keep = true",
    "local two = 2",
  })

  actions.reject_all()
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
    "local one = 1",
    "local keep = true",
    "local two = 2",
  })
end)

test("inferred whole-file stream replaces instead of duplicating", function()
  local state = reset_state()
  local actions = require("chatforge.core.actions")
  local bufnr = vim.api.nvim_create_buf(false, true)
  local original = {
    "import datetime as dt",
    "import smtplib",
    "from random import randint",
    "import pandas",
    "",
    "#................................. converting csv to dictionary ............................................",
    "data = pandas.read_csv(\"birthdays.csv\")",
    "pandas.DataFrame(data)",
    "data_dict = data.to_dict(\"records\")",
    "",
    "#.................................. working with birthday_date .............................................",
    "now = dt.datetime.now()",
    "",
    "for item in data_dict: # loops through each dict in list",
    "    if item['month'] == now.month and item['day'] == now.day: # finds the value of this key in the dict",
    "        celebrant = item['name'] # picks the str assigned to the name key",
    "        email = item['email'] # picks the str assigned to the email key",
    "        with open(f\"letter_templates/letter_{randint(1,3)}.txt\") as content:",
    "            letter = content.read()",
    "            letter = letter.replace(\"[NAME]\", celebrant)",
    "        # print(letter) # for debugging",
    "",
    "        with smtplib.SMTP(\"smtp.gmail.com\") as connection:",
    "            connection.starttls()",
    "            connection.login(\"richaffiliations@gmail.com\", \"zzdbtxgjnpurtfus\")",
    "            connection.sendmail(\"richaffiliations@gmial.com\",f\"{email}\",",
    "                                f\"subject: Happy Birthday!\\n\\n{letter}\")",
  }
  local proposed = {
    "import datetime as dt",
    "import smtplib",
    "from random import randint",
    "import pandas",
    "",
    "# Convert CSV data to list of dictionaries",
    "data = pandas.read_csv(\"birthdays.csv\")",
    "data_dict = data.to_dict(\"records\")",
    "",
    "# Check each birthday entry against current date",
    "now = dt.datetime.now()",
    "",
    "for item in data_dict:",
    "    # If today matches a birthday, send email",
    "    if item['month'] == now.month and item['day'] == now.day:",
    "        celebrant = item['name']",
    "        email = item['email']",
    "",
    "        # Read random letter template and replace placeholder",
    "        with open(f\"letter_templates/letter_{randint(1,3)}.txt\") as content:",
    "            letter = content.read()",
    "            letter = letter.replace(\"[NAME]\", celebrant)",
    "",
    "        # Send birthday email",
    "        with smtplib.SMTP(\"smtp.gmail.com\") as connection:",
    "            connection.starttls()",
    "            connection.login(\"richaffiliations@gmail.com\", \"zzdbtxgjnpurtfus\")",
    "            connection.sendmail(\"richaffiliations@gmail.com\", f\"{email}\",",
    "                                f\"subject: Happy Birthday!\\n\\n{letter}\")",
  }

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original)
  state.source_bufnr = bufnr
  state.source_winnr = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.source_winnr, bufnr)
  vim.api.nvim_win_set_cursor(state.source_winnr, { 14, 0 })
  state.pending_blocks = {
    {
      content = table.concat(proposed, "\n"),
      lang = "python",
      target_bufnr = bufnr,
      stageable = true,
    },
  }

  truthy(actions.start_stream_preview(1, state.pending_blocks[1]), "stream preview should start")
  actions.append_stream_preview(table.concat(proposed, "\n") .. "\n")
  local change = actions.finish_stream_preview()

  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), proposed)
  equal(change.start_idx, 0)
  equal(change.end_idx, -1)
  equal(change.original_lines, original)

  actions.reject_all()
  equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), original)
end)

test("proposed highlights do not add AI virtual text", function()
  local state = reset_state()
  local actions = require("chatforge.core.actions")
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "return true" })
  state.source_bufnr = bufnr
  state.pending_blocks = {
    {
      content = "return false",
      lang = "lua",
      target = {
        bufnr = bufnr,
        line1 = 1,
        line2 = 1,
        kind = "selection",
      },
      target_bufnr = bufnr,
      stageable = true,
    },
  }

  truthy(actions.start_stream_preview(1, state.pending_blocks[1]))
  actions.append_stream_preview("return false\n")
  actions.finish_stream_preview()

  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })
  for _, mark in ipairs(extmarks) do
    local details = mark[4] or {}
    truthy(details.virt_text == nil, "staged highlights should not add AI virtual text")
  end
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
      target = {
        bufnr = bufnr,
        line1 = 1,
        line2 = 1,
        kind = "selection",
      },
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
