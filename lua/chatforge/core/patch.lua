local M = {}

local SEARCH_MARKER = "^%s*-------*%s+SEARCH%s*$"
local SPLIT_MARKER = "^%s*=======*%s*$"
local REPLACE_MARKER = "^%s*+++++++*%s+REPLACE%s*$"

local function trim_trailing(line)
  local trimmed = (line or ""):gsub("%s+$", "")
  return trimmed
end

local function same_line(a, b)
  if a == nil or b == nil then
    return false
  end
  return trim_trailing(a) == trim_trailing(b)
end

function M.is_search_replace(content)
  local has_search = false
  local has_split = false
  local has_replace = false
  for _, line in ipairs(vim.split(content or "", "\n", { plain = true })) do
    has_search = has_search or line:match(SEARCH_MARKER) ~= nil
    has_split = has_split or line:match(SPLIT_MARKER) ~= nil
    has_replace = has_replace or line:match(REPLACE_MARKER) ~= nil
  end
  return has_search and has_split and has_replace
end

function M.parse_search_replace(content)
  local blocks = {}
  local mode = nil
  local old_lines = {}
  local new_lines = {}

  for _, line in ipairs(vim.split(content or "", "\n", { plain = true })) do
    if line:match(SEARCH_MARKER) then
      mode = "search"
      old_lines = {}
      new_lines = {}
    elseif line:match(SPLIT_MARKER) and mode == "search" then
      mode = "replace"
    elseif line:match(REPLACE_MARKER) and mode == "replace" then
      table.insert(blocks, {
        old_lines = old_lines,
        new_lines = new_lines,
      })
      mode = nil
      old_lines = {}
      new_lines = {}
    elseif mode == "search" then
      table.insert(old_lines, trim_trailing(line))
    elseif mode == "replace" then
      table.insert(new_lines, trim_trailing(line))
    end
  end

  return blocks
end

local function find_exact(lines, needle, from_idx)
  if #needle == 0 then
    return from_idx, from_idx - 1
  end

  local max_start = #lines - #needle + 1
  for line_idx = math.max(from_idx, 1), max_start do
    local ok = true
    for offset = 1, #needle do
      if not same_line(lines[line_idx + offset - 1], needle[offset]) then
        ok = false
        break
      end
    end
    if ok then
      return line_idx, line_idx + #needle - 1
    end
  end

  return nil, nil
end

function M.build_changes(original_lines, content)
  local blocks = M.parse_search_replace(content)
  if #blocks == 0 then
    return nil, "No SEARCH/REPLACE blocks found."
  end

  local changes = {}
  local search_from = 1
  for idx, block in ipairs(blocks) do
    local start_line, end_line = find_exact(original_lines, block.old_lines, search_from)
    if not start_line or not end_line then
      return nil, "SEARCH block #" .. idx .. " did not match the current buffer."
    end
    table.insert(changes, {
      start_idx = start_line - 1,
      end_idx = end_line,
      old_lines = block.old_lines,
      new_lines = block.new_lines,
    })
    search_from = end_line + 1
  end

  return changes, nil
end

function M.range_for_changes(original_lines, changes)
  local start_idx = changes[1].start_idx
  local end_idx = changes[#changes].end_idx
  local proposed = vim.deepcopy(original_lines)

  for idx = #changes, 1, -1 do
    local change = changes[idx]
    local before = vim.list_slice(proposed, 1, change.start_idx)
    local after = vim.list_slice(proposed, change.end_idx + 1)
    proposed = before
    vim.list_extend(proposed, change.new_lines)
    vim.list_extend(proposed, after)
  end

  local delta_before = 0
  local delta_inside = 0
  for _, change in ipairs(changes) do
    if change.end_idx <= start_idx then
      delta_before = delta_before + #change.new_lines - #change.old_lines
    elseif change.start_idx < end_idx then
      delta_inside = delta_inside + #change.new_lines - #change.old_lines
    end
  end

  local proposed_start = start_idx + delta_before
  local proposed_end = end_idx + delta_before + delta_inside
  return start_idx, end_idx, vim.list_slice(original_lines, start_idx + 1, end_idx), vim.list_slice(proposed, proposed_start + 1, proposed_end)
end

return M
