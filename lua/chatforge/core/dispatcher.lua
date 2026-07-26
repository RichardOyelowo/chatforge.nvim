-- Enriches user input before it goes to the API.
-- Handles:
--   @file                inject the current live buffer
--   @{file path/to/file} inject a named file
--   @dir                 inject the current working directory
--   @{dir path/to/dir}   inject a named directory
--   explain / fix / refactor prefix -> inject current buffer content

local M     = {}
local log   = require("chatforge.utils.logger")
local buf_u = require("chatforge.utils.buffer")

local MAX_AUTO_CONTEXT_LINES = 160

local RULES = {
  { pattern = "^[cC][rR][eE][aA][tT][eE]%s+[fF][iI][lL][eE]%s+(%S+)",  action = "create_file", capture = 1 },
  { pattern = "^[eE][dD][iI][tT]%s+[fF][iI][lL][eE]%s+(%S+)",          action = "edit_file",   capture = 1 },
  { pattern = "^[dD][eE][lL][eE][tT][eE]%s+[fF][iI][lL][eE]%s+(%S+)",  action = "delete_file", capture = 1 },
  { pattern = "^[eE][xX][pP][lL][aA][iI][nN]%s+",                     action = "explain" },
  { pattern = "^[fF][iI][xX]%s+",                                      action = "edit_file" },
  { pattern = "^[rR][eE][fF][aA][cC][tT][oO][rR]%s+",                 action = "edit_file" },
}

local READ_ONLY_PATTERNS = {
  "^%s*explain%s+",
  "^%s*review%s+",
  "^%s*describe%s+",
  "^%s*summarize%s+",
  "^%s*what%s+",
  "^%s*why%s+",
  "^%s*how%s+",
  "^%s*can%s+you%s+see%s+",
  "^%s*do%s+not%s+edit",
  "^%s*do%s+not%s+change",
  "^%s*do%s+not%s+modify",
  "^%s*don't%s+edit",
  "^%s*don't%s+change",
  "^%s*don't%s+modify",
  "^%s*just%s+explain",
  "^%s*just%s+review",
  "^%s*just%s+tell",
  "^%s*just%s+show",
  "^%s*only%s+explain",
  "^%s*only%s+review",
  "^%s*only%s+tell",
  "^%s*only%s+show",
  "no%s+changes",
  "without%s+changing",
  "example%s+only",
  "just%s+an%s+example",
}

local EDIT_PATTERNS = {
  "^%s*add%s+",
  "^%s*change%s+",
  "^%s*update%s+",
  "^%s*modify%s+",
  "^%s*replace%s+",
  "^%s*remove%s+",
  "^%s*delete%s+",
  "^%s*rewrite%s+",
  "^%s*generate%s+",
  "^%s*implement%s+",
  "^%s*create%s+",
  "^%s*improve%s+",
  "^%s*optimi[sz]e%s+",
  "^%s*convert%s+",
  "^%s*migrate%s+",
  "^%s*extract%s+",
  "^%s*rename%s+",
  "^%s*make%s+this%s+",
  "^%s*make%s+it%s+",
  "^%s*turn%s+",
  "please%s+add",
  "please%s+change",
  "please%s+update",
  "please%s+modify",
  "please%s+replace",
  "please%s+remove",
  "please%s+rewrite",
  "please%s+generate",
  "please%s+implement",
  "please%s+create",
  "please%s+improve",
  "can%s+you%s+add",
  "can%s+you%s+change",
  "can%s+you%s+update",
  "can%s+you%s+modify",
  "can%s+you%s+replace",
  "can%s+you%s+remove",
  "can%s+you%s+rewrite",
  "can%s+you%s+generate",
  "can%s+you%s+implement",
  "can%s+you%s+create",
  "can%s+you%s+improve",
  "could%s+you%s+add",
  "could%s+you%s+change",
  "could%s+you%s+update",
  "could%s+you%s+modify",
  "could%s+you%s+replace",
  "could%s+you%s+remove",
  "could%s+you%s+rewrite",
  "could%s+you%s+generate",
  "could%s+you%s+implement",
  "could%s+you%s+create",
  "could%s+you%s+improve",
  "i%s+need%s+.*added",
  "i%s+need%s+.*changed",
  "i%s+need%s+.*updated",
  "i%s+need%s+.*modified",
  "i%s+need%s+.*replaced",
  "i%s+need%s+.*removed",
  "i%s+need%s+.*rewritten",
  "i%s+need%s+.*generated",
  "i%s+need%s+.*created",
  "i%s+need%s+.*improved",
  "i%s+want%s+.*added",
  "i%s+want%s+.*changed",
  "i%s+want%s+.*updated",
  "i%s+want%s+.*modified",
  "i%s+want%s+.*replaced",
  "i%s+want%s+.*removed",
  "i%s+want%s+.*rewritten",
  "i%s+want%s+.*generated",
  "i%s+want%s+.*created",
  "i%s+want%s+.*improved",
}

function M.is_read_only_request(input)
  local lower = (input or ""):lower()
  for _, pattern in ipairs(READ_ONLY_PATTERNS) do
    if lower:match(pattern) then
      return true
    end
  end
  return false
end

function M.is_edit_request(input)
  local lower = (input or ""):lower()
  if M.is_read_only_request(lower) then
    return false
  end
  for _, pattern in ipairs(EDIT_PATTERNS) do
    if lower:match(pattern) then
      return true
    end
  end
  return false
end

local function classify(input)
  for _, rule in ipairs(RULES) do
    local m = { input:match(rule.pattern) }
    if m[1] ~= nil then
      return rule.action, rule.capture and m[rule.capture] or nil
    end
  end
  if M.is_edit_request(input) then
    return "edit_file", nil
  end
  return "chat", nil
end

local function read_file(path)
  local expanded = vim.fn.expand(path)
  local f, err = io.open(expanded, "r")
  if not f then return nil, "cannot open " .. expanded .. ": " .. (err or "unknown") end
  local contents = f:read("*a")
  f:close()
  return contents, nil
end

local function is_current_file_ref(path)
  return path == "/" or path == "." or path == ""
end

local function resolve_dir_path(path)
  local cwd = vim.fn.getcwd()
  if path == "/" or path == "." or path == "" then
    return cwd
  end
  local stripped = path:match("^/(.+)$")
  if stripped then
    return cwd .. "/" .. stripped
  end
  return cwd .. "/" .. path
end

local function read_dir(path)
  local resolved = resolve_dir_path(path)
  local handle = vim.uv.fs_opendir(resolved, nil, 64)
  if not handle then return nil, "cannot open dir: " .. resolved end
  local entries, err2 = vim.uv.fs_readdir(handle)
  vim.uv.fs_closedir(handle)
  if not entries then return nil, err2 or "readdir failed" end
  local lines = { "Directory: " .. resolved }
  table.sort(entries, function(a, b) return a.name < b.name end)
  for _, e in ipairs(entries) do
    table.insert(lines, string.format("  %s  %s", e.type == "directory" and "d" or "f", e.name))
  end
  return table.concat(lines, "\n"), nil
end

local function cursor_line_for_buffer(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return vim.api.nvim_win_get_cursor(win)[1]
    end
  end
  return 1
end

local function resolve_at_mentions(input, src_bufnr)
  local injections = {}
  local contexts = {}
  local resolved   = input
  local placeholders = {}
  local placeholder_count = 0

  local function hold(block)
    placeholder_count = placeholder_count + 1
    local key = "\1CHATFORGE_CONTEXT_" .. tostring(placeholder_count) .. "\1"
    placeholders[key] = block
    return key
  end

  local function current_file_block(path_label)
    local name    = buf_u.get_name(src_bufnr)
    local ft      = buf_u.get_filetype(src_bufnr)
    local content = buf_u.get_content(src_bufnr)
    table.insert(injections, { tag = "@file", path = path_label or "(current buffer)", ok = true })
    local display_name = name ~= "" and name or "(unnamed)"
    local block = string.format(
      "\n\n[ChatForge context: current live Neovim buffer %s. This is accessible user-provided code.]\nFile: %s\n```%s\n%s\n```",
      display_name,
      display_name,
      ft,
      content
    )
    table.insert(contexts, { path = display_name, block = block })
    return hold(block)
  end

  local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
  end

  -- Resolve explicit named contexts first
  resolved = resolved:gsub("@%{[fF][iI][lL][eE]%s*([^}]*)%}", function(raw_path)
    local path = trim(raw_path)
    if is_current_file_ref(path) then
      return current_file_block("(current buffer)")
    end
    local contents, err = read_file(path)
    if err then
      return hold("\n<!-- @{file " .. path .. "} could not be read: " .. err .. " -->")
    end
    local ft = vim.filetype.match({ filename = path }) or ""
    table.insert(injections, { tag = "@{file}", path = path, ok = true })
    local block = string.format(
      "\n\n[ChatForge context: named file %s. This is accessible user-provided code.]\nFile: %s\n```%s\n%s\n```",
      path,
      path,
      ft,
      contents
    )
    table.insert(contexts, { path = vim.fn.expand(path), block = block })
    return hold(block)
  end)

  resolved = resolved:gsub("@%{[dD][iI][rR]%s*([^}]*)%}", function(raw_path)
    local path = trim(raw_path)
    local listing, err = read_dir(path)
    if err then
      return hold("\n<!-- @{dir " .. path .. "} could not be read: " .. err .. " -->")
    end
    table.insert(injections, { tag = "@{dir}", path = path, ok = true })
    return hold(string.format(
      "\n\n[ChatForge context: directory listing %s.]\n```\n%s\n```",
      path == "" and vim.fn.getcwd() or path,
      listing
    ))
  end)

  local function replace_bare_token(text, token_pattern, replacement)
    local source = text
    return source:gsub("()" .. token_pattern .. "()", function(start_pos, end_pos)
      local before = source:sub(start_pos - 1, start_pos - 1)
      local after = source:sub(end_pos, end_pos)
      if before:match("[%w_]") or after:match("[%w_]") then
        return source:sub(start_pos, end_pos - 1)
      end
      return replacement()
    end)
  end

  resolved = replace_bare_token(resolved, "@[fF][iI][lL][eE]", function()
    return current_file_block("(current buffer)")
  end)
  resolved = replace_bare_token(resolved, "@[dD][iI][rR]", function()
    local listing, err = read_dir("")
    if err then
      return hold("\n<!-- @dir could not be read: " .. err .. " -->")
    end
    table.insert(injections, { tag = "@dir", path = "(cwd)", ok = true })
    return hold(string.format(
      "\n\n[ChatForge context: current working directory listing.]\n```\n%s\n```",
      listing
    ))
  end)

  -- Safely restore held placeholders escaping gsub magic characters (%)
  for key, block in pairs(placeholders) do
    resolved = resolved:gsub(vim.pesc(key), function() return block end)
  end

  return resolved, injections, contexts
end

local function should_include_related_context(input)
  local lower = (input or ""):lower()
  return lower:match("match")
    or lower:match("related")
    or lower:match("previous")
    or lower:match("worked%s+on")
    or lower:match("both")
    or lower:match("html")
    or lower:match("css")
    or lower:match("@file")
    or lower:match("@%{file")
end

local function add_related_contexts(input, related_contexts, current_contexts)
  if not should_include_related_context(input) or type(related_contexts) ~= "table" then
    return input
  end

  local current_paths = {}
  for _, context in ipairs(current_contexts or {}) do
    current_paths[context.path] = true
  end

  local blocks = {}
  for _, context in ipairs(related_contexts) do
    if context.path and context.block and not current_paths[context.path] then
      table.insert(blocks, context.block)
    end
    if #blocks >= 3 then
      break
    end
  end

  if #blocks == 0 then
    return input
  end

  return input
    .. "\n\n[ChatForge related context from recently shared files. Use this only when the user asks about relationships between files.]"
    .. table.concat(blocks, "")
end

local function build_prompt(input, action, src_bufnr)
  local ft   = buf_u.get_filetype(src_bufnr)
  local name = buf_u.get_name(src_bufnr)
  local edit_instruction = ""
  if action == "edit_file" then
    edit_instruction = "\n\n[ChatForge edit request]\n"
      .. "Return one fenced diff block using exact SEARCH/REPLACE sections. "
      .. "The SEARCH text must match the current buffer exactly, including indentation. "
      .. "Include only the smallest old text needed to identify the change and the replacement text. "
      .. "Use multiple SEARCH/REPLACE sections for separate changes. "
      .. "Do not return the whole file unless every line truly changes. "
      .. "Format the first fenced block exactly like this:\n"
      .. "```diff\n"
      .. "------- SEARCH\n"
      .. "old text from the current buffer\n"
      .. "=======\n"
      .. "new text to stage\n"
      .. "+++++++ REPLACE\n"
      .. "```\n"
      .. "Text outside that first fenced block is allowed, but the first fenced block is what ChatForge stages live in Neovim."
  end

  if action == "edit_file" or action == "explain" then
    local line_count = vim.api.nvim_buf_line_count(src_bufnr)
    if line_count > MAX_AUTO_CONTEXT_LINES then
      local cursor_line = cursor_line_for_buffer(src_bufnr)
      local half = math.floor(MAX_AUTO_CONTEXT_LINES / 2)
      local start_line = math.max(cursor_line - half, 1)
      local end_line = math.min(start_line + MAX_AUTO_CONTEXT_LINES - 1, line_count)
      start_line = math.max(end_line - MAX_AUTO_CONTEXT_LINES + 1, 1)
      local lines = vim.api.nvim_buf_get_lines(src_bufnr, start_line - 1, end_line, false)
      return string.format(
        "%s%s\n\n[ChatForge context: current live Neovim buffer. This is accessible user-provided code.]\nFile: %s\nContext: lines %d-%d of %d. Use visual selection or @{file path} for a different scope.\n```%s\n%s\n```",
        input,
        edit_instruction,
        name ~= "" and name or "(unnamed)",
        start_line,
        end_line,
        line_count,
        ft,
        table.concat(lines, "\n")
      )
    else
      local content = buf_u.get_content(src_bufnr)
      return string.format("%s%s\n\n[ChatForge context: current live Neovim buffer. This is accessible user-provided code.]\nFile: %s\n```%s\n%s\n```",
        input, edit_instruction, name ~= "" and name or "(unnamed)", ft, content)
    end
  end

  return input
end

function M.dispatch(input, src_bufnr, opts)
  opts = opts or {}
  local resolved, injections, contexts = resolve_at_mentions(input, src_bufnr)
  for _, inj in ipairs(injections) do
    log.log("dispatch: injected %s %s", inj.tag, inj.path)
  end

  local action, target = classify(input)
  if opts.force_stage and action ~= "create_file" and action ~= "delete_file" then
    action = "edit_file"
    target = nil
  end

  resolved = add_related_contexts(resolved, opts.related_contexts, contexts)
  local prompt = build_prompt(resolved, action, src_bufnr)

  log.log("dispatch: action=%s target=%s", action, target or "nil")

  return {
    action = action,
    prompt = prompt,
    target = target,
    stage = action == "edit_file" or action == "create_file",
    contexts = contexts,
  }
end

return M