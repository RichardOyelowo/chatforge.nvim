-- Enriches user input before it goes to the API.
-- Handles:
--   @file                inject the current live buffer
--   @{file path/to/file} inject a named file
--   @dir                 inject the current working directory
--   @{dir path/to/dir}   inject a named directory
--   explain / fix / refactor prefix → inject current buffer content

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

local function classify(input)
  for _, rule in ipairs(RULES) do
    local m = { input:match(rule.pattern) }
    if m[1] ~= nil then
      return rule.action, rule.capture and m[rule.capture] or nil
    end
  end
  return "chat", nil
end

-- Read a file from disk and return its contents, or an error string.
-- Uses vim.fn.expand so ~, $VAR, relative, and absolute paths all work as-is.
local function read_file(path)
  local expanded = vim.fn.expand(path)
  local f, err = io.open(expanded, "r")
  if not f then return nil, "cannot open " .. expanded .. ": " .. (err or "unknown") end
  local contents = f:read("*a")
  f:close()
  return contents, nil
end

-- True when the path means "inject the currently open buffer" rather than read a real path.
local function is_current_file_ref(path)
  return path == "/" or path == "." or path == ""
end

-- Resolve a dir path relative to cwd.
-- "/" and "." both mean cwd. No way to escape outside the project root.
-- by accident. "/src" means cwd/src, not filesystem /src.
local function resolve_dir_path(path)
  local cwd = vim.fn.getcwd()
  if path == "/" or path == "." or path == "" then
    return cwd
  end
  -- Strip a leading slash so @{dir /src} means cwd/src.
  local stripped = path:match("^/(.+)$")
  if stripped then
    return cwd .. "/" .. stripped
  end
  -- relative path: resolve from cwd
  return cwd .. "/" .. path
end

-- Return a simple directory listing (one level deep).
local function read_dir(path)
  local resolved = resolve_dir_path(path)
  local handle = vim.loop.fs_opendir(resolved, nil, 64)
  if not handle then return nil, "cannot open dir: " .. resolved end
  local entries, err2 = vim.loop.fs_readdir(handle)
  vim.loop.fs_closedir(handle)
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

-- Named context uses braces so normal prose after a bare token is never
-- interpreted as a path: "review @file fully" means current buffer + "fully".
local function resolve_at_mentions(input, src_bufnr)
  local injections = {}
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
    return hold(string.format(
      "\n\n[ChatForge context: current live Neovim buffer %s. This is accessible user-provided code.]\nFile: %s\n```%s\n%s\n```",
      display_name,
      display_name,
      ft,
      content
    ))
  end

  local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
  end

  -- Resolve explicit named contexts first. Their replacement is held behind a
  -- placeholder so tokens inside injected source code are not parsed again.
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
    return hold(string.format(
      "\n\n[ChatForge context: named file %s. This is accessible user-provided code.]\nFile: %s\n```%s\n%s\n```",
      path,
      path,
      ft,
      contents
    ))
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

  for key, block in pairs(placeholders) do
    resolved = resolved:gsub(vim.pesc(key), block)
  end

  return resolved, injections
end

local function build_prompt(input, action, src_bufnr)
  local ft   = buf_u.get_filetype(src_bufnr)
  local name = buf_u.get_name(src_bufnr)

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
        "%s\n\n[ChatForge context: current live Neovim buffer. This is accessible user-provided code.]\nFile: %s\nContext: lines %d-%d of %d. Use visual selection or @{file path} for a different scope.\n```%s\n%s\n```",
        input,
        name ~= "" and name or "(unnamed)",
        start_line,
        end_line,
        line_count,
        ft,
        table.concat(lines, "\n")
      )
    else
      local content = buf_u.get_content(src_bufnr)
      return string.format("%s\n\n[ChatForge context: current live Neovim buffer. This is accessible user-provided code.]\nFile: %s\n```%s\n%s\n```",
        input, name ~= "" and name or "(unnamed)", ft, content)
    end
  end

  return input
end

function M.dispatch(input, src_bufnr)
  -- 1. Resolve @file / @dir mentions first
  local resolved, injections = resolve_at_mentions(input, src_bufnr)
  for _, inj in ipairs(injections) do
    log.log("dispatch: injected %s %s", inj.tag, inj.path)
  end

  -- 2. Classify action
  local action, target = classify(resolved)

  -- 3. Enrich with buffer content for edit/explain actions
  local prompt = build_prompt(resolved, action, src_bufnr)

  log.log("dispatch: action=%s target=%s", action, target or "nil")

  return { action = action, prompt = prompt, target = target }
end

return M
