local M     = {}
local state = require("chatforge.core.state")
local log   = require("chatforge.utils.logger")
local render = require("chatforge.ui.render")
local config = require("chatforge.config")
local patch = require("chatforge.core.patch")
local NS = vim.api.nvim_create_namespace("chatforge_proposed_change")

vim.api.nvim_set_hl(0, "ChatforgeProposedChange", { underline = true, sp = "#7aa2f7", default = true })

-- ── helpers ────────────────────────────────────────────────────────────────

--- Return the lines of pending block N (1-based).
---@param  idx number
---@return string[]|nil, string|nil  lines, err
local function get_block_lines(idx)
  local block = state.pending_blocks[idx]
  if not block then
    return nil, "No pending code block #" .. idx
  end
  return vim.split(block.content, "\n"), nil
end

local function fallback_target_bufnr()
  local current = vim.api.nvim_get_current_buf()
  if not state.is_plugin_buf(current) then
    return current
  end
  if state.source_bufnr and vim.api.nvim_buf_is_valid(state.source_bufnr) then
    return state.source_bufnr
  end
  return nil
end

local function target_bufnr_for_block(idx)
  local block = state.pending_blocks[idx]
  if block and block.target_bufnr and vim.api.nvim_buf_is_valid(block.target_bufnr) then
    return block.target_bufnr
  end
  return fallback_target_bufnr()
end

local function focus_source_window(bufnr)
  if state.source_winnr and vim.api.nvim_win_is_valid(state.source_winnr) then
    vim.api.nvim_set_current_win(state.source_winnr)
    if vim.api.nvim_win_get_buf(state.source_winnr) ~= bufnr then
      vim.api.nvim_win_set_buf(state.source_winnr, bufnr)
    end
    return
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      vim.api.nvim_set_current_win(win)
      state.source_winnr = win
      return
    end
  end
end

local function block_target(idx, bufnr)
  local block = state.pending_blocks[idx]
  local target = block and block.target
  if target and target.bufnr ~= bufnr then
    target = nil
  end
  return target
end

local function block_while_applying(action)
  if not state.applying then
    return false
  end
  vim.notify("[chatforge] Wait for the staged implementation to finish writing before " .. action .. ".", vim.log.levels.WARN)
  return true
end

local function find_window_for_buf(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function use_source_buffer_for_path(path)
  local absolute = vim.fn.fnamemodify(path, ":p")
  local bufnr = vim.fn.bufadd(absolute)
  vim.fn.bufload(bufnr)

  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("[chatforge] Could not open " .. path .. ".", vim.log.levels.ERROR)
    return nil
  end

  local win = find_window_for_buf(bufnr)
  if not win then
    win = state.source_winnr
    if not win or not vim.api.nvim_win_is_valid(win) then
      win = vim.api.nvim_get_current_win()
      if state.is_plugin_buf(vim.api.nvim_win_get_buf(win)) then
        win = nil
      end
    end
  end

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    if vim.api.nvim_win_get_buf(win) ~= bufnr then
      vim.api.nvim_win_set_buf(win, bufnr)
    end
    state.source_winnr = win
  end

  state.source_bufnr = bufnr
  return bufnr
end

local function write_buffer_to_disk(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" or vim.api.nvim_buf_get_name(bufnr) == "" then
    return true
  end

  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent write")
  end)
  if not ok then
    vim.notify("[chatforge] Could not write accepted change: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function proposed_hl()
  local cfg = config.values or {}
  return cfg.highlights
    and cfg.highlights.diff
    and cfg.highlights.diff.incoming
    or "ChatforgeProposedChange"
end

local function changed_line_marks(original, proposed)
  local marks = {}
  local max_len = math.max(#original, #proposed)
  for i = 1, max_len do
    if original[i] ~= proposed[i] and proposed[i] ~= nil then
      marks[i] = true
    end
  end
  return marks
end

local function add_proposed_highlight(bufnr, start_idx, line_count, marks)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, start_idx, start_idx + math.max(line_count, 1))
  for offset = 0, line_count - 1 do
    if not marks or marks[offset + 1] then
      vim.api.nvim_buf_add_highlight(bufnr, NS, proposed_hl(), start_idx + offset, 0, -1)
    end
  end
end

local function meaningful_line(line)
  local trimmed = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if trimmed == "" then
    return nil
  end
  if trimmed:match("^#") or trimmed:match("^//") or trimmed:match("^%-%-") then
    return nil
  end
  return trimmed
end

local function significant_lines(lines)
  local result = {}
  for _, line in ipairs(lines) do
    local meaningful = meaningful_line(line)
    if meaningful then
      table.insert(result, meaningful)
    end
  end
  return result
end

local function looks_like_whole_file(original, proposed)
  if #original < 4 or #proposed < 4 then
    return false
  end
  if #proposed < math.floor(#original * 0.65) then
    return false
  end

  local original_sig = significant_lines(original)
  local proposed_sig = significant_lines(proposed)
  if #original_sig < 3 or #proposed_sig < 3 then
    return false
  end

  local proposed_seen = {}
  for _, line in ipairs(proposed_sig) do
    proposed_seen[line] = true
  end

  local common = 0
  for _, line in ipairs(original_sig) do
    if proposed_seen[line] then
      common = common + 1
    end
  end

  return common >= 3 and (common / #original_sig) >= 0.55
end

local function clear_proposed_highlight(change)
  if change and change.bufnr and vim.api.nvim_buf_is_valid(change.bufnr) then
    vim.api.nvim_buf_clear_namespace(change.bufnr, NS, 0, -1)
  end
end

local function prompt_summary(block)
  local summary = block and block.prompt_summary or ""
  summary = summary:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  return summary:sub(1, 120)
end

local function staged_metadata(block, bufnr, start_idx, end_idx, original, proposed, original_changedtick)
  return {
    id = string.format("%d-%d-%d", os.time(), bufnr, math.random(100000, 999999)),
    bufnr = bufnr,
    buffer = bufnr,
    file_path = vim.api.nvim_buf_get_name(bufnr),
    original_changedtick = original_changedtick,
    staged_changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    original_lines = vim.deepcopy(original),
    proposed_lines = vim.deepcopy(proposed),
    original = original,
    start_idx = start_idx,
    end_idx = end_idx,
    start_line = start_idx + 1,
    end_line = start_idx + math.max(#proposed, 1),
    new_line_count = #proposed,
    target = block and block.target or nil,
    timestamp = os.time(),
    model = block and block.model or nil,
    prompt_summary = prompt_summary(block),
    status = "pending",
  }
end

local function is_stale(change)
  return change.staged_changedtick
    and vim.api.nvim_buf_is_valid(change.bufnr)
    and vim.api.nvim_buf_get_changedtick(change.bufnr) ~= change.staged_changedtick
end

local function report_stale(idx)
  local message = "Implementation #" .. idx .. " is stale because the buffer changed after staging. Review it with :ChatDiff " .. idx .. "."
  render.append_status(message, "error")
  vim.notify("[chatforge] " .. message, vim.log.levels.WARN)
end

local function first_staged_idx()
  local best = nil
  for idx in pairs(state.staged_changes) do
    if not best or idx < best then
      best = idx
    end
  end
  return best
end

local function jump_staged(direction)
  local idx = first_staged_idx()
  local change = idx and state.staged_changes[idx]
  if not change or not change.bufnr or not vim.api.nvim_buf_is_valid(change.bufnr) then
    vim.notify("[chatforge] No staged implementation to jump to.", vim.log.levels.INFO)
    return
  end
  focus_source_window(change.bufnr)
  local line = direction == "prev" and change.start_idx + 1
    or change.start_idx + math.max(change.new_line_count, 1)
  vim.api.nvim_win_set_cursor(state.source_winnr, { math.max(line, 1), 0 })
end

local function cursor_insert_idx(bufnr)
  local win = find_window_for_buf(bufnr)
  if win and vim.api.nvim_win_is_valid(win) then
    return math.max(vim.api.nvim_win_get_cursor(win)[1] - 1, 0)
  end
  return vim.api.nvim_buf_line_count(bufnr)
end

local function stage_range(bufnr, target, block)
  if target and target.line1 then
    return target.line1 - 1, target.line2, "replace"
  end
  if block and block.action == "create_file" then
    return 0, -1, "replace"
  end
  local insert_at = cursor_insert_idx(bufnr)
  return insert_at, insert_at, "insert"
end

local function stage_range_for_lines(bufnr, target, block, lines)
  local start_idx, end_idx, mode = stage_range(bufnr, target, block)
  if mode ~= "insert" then
    return start_idx, end_idx, mode
  end

  local original = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if looks_like_whole_file(original, lines) then
    return 0, -1, "replace"
  end
  return start_idx, end_idx, mode
end

local function remove_eof_blank_after_replace(bufnr, start_idx, inserted_count, end_idx, original_line_count)
  if end_idx ~= -1 and end_idx < original_line_count then
    return
  end
  local blank_idx = start_idx + inserted_count
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if blank_idx >= line_count then
    return
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, blank_idx, blank_idx + 1, false)[1]
  if line == "" then
    vim.api.nvim_buf_set_lines(bufnr, blank_idx, blank_idx + 1, false, {})
  end
end

local function write_lines_live(bufnr, lines, target, opts, on_done)
  opts = opts or {}
  focus_source_window(bufnr)

  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  local block = state.pending_blocks[opts.block_index or 1]
  local original_line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_idx, end_idx, mode = stage_range_for_lines(bufnr, target, block, lines)
  local original_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local original = vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
  vim.api.nvim_buf_set_lines(bufnr, start_idx, end_idx, false, {})

  local i = 1
  local chunk_size = 2
  local insert_at = start_idx
  state.applying = true
  render.start_forging_status()

  local function step()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      state.applying = false
      render.stop_forging_status()
      return
    end

    local chunk = {}
    for _ = 1, chunk_size do
      if i > #lines then break end
      table.insert(chunk, lines[i])
      i = i + 1
    end

    if #chunk > 0 then
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, chunk)
      insert_at = insert_at + #chunk
      if opts.highlight then
        add_proposed_highlight(bufnr, start_idx, insert_at - start_idx)
      end
      if state.source_winnr and vim.api.nvim_win_is_valid(state.source_winnr) then
        vim.api.nvim_win_set_cursor(state.source_winnr, { math.max(insert_at, 1), 0 })
      end
    end

    if i <= #lines then
      vim.defer_fn(step, 18)
    else
      if opts.highlight then
        add_proposed_highlight(bufnr, start_idx, #lines, changed_line_marks(original, lines))
      end
      if mode == "replace" then
        remove_eof_blank_after_replace(bufnr, start_idx, #lines, end_idx, original_line_count)
      end
      vim.bo[bufnr].modifiable = was_modifiable
      state.applying = false
      render.stop_forging_status()
      if on_done then
        on_done(staged_metadata(block, bufnr, start_idx, end_idx, original, lines, original_changedtick))
      end
    end
  end

  step()
end

local function stage_patch_live(bufnr, content, block, opts, on_done)
  opts = opts or {}
  focus_source_window(bufnr)

  local original_line_count = vim.api.nvim_buf_line_count(bufnr)
  local full_original = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local changes, err = patch.build_changes(full_original, content)
  if err then
    vim.notify("[chatforge] " .. err, vim.log.levels.WARN)
    render.append_status(err, "error")
    return
  end

  local start_idx, end_idx, original, proposed = patch.range_for_changes(full_original, changes)
  local original_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true

  state.applying = true
  render.start_forging_status()

  for idx = #changes, 1, -1 do
    local change = changes[idx]
    vim.api.nvim_buf_set_lines(bufnr, change.start_idx, change.end_idx, false, change.new_lines)
  end

  if opts.highlight then
    add_proposed_highlight(bufnr, start_idx, #proposed, changed_line_marks(original, proposed))
  end
  if end_idx == original_line_count then
    remove_eof_blank_after_replace(bufnr, start_idx, #proposed, -1, original_line_count)
  end

  vim.bo[bufnr].modifiable = was_modifiable
  state.applying = false
  render.stop_forging_status()

  if on_done then
    on_done(staged_metadata(block, bufnr, start_idx, end_idx, original, proposed, original_changedtick))
  end
end

local function insert_stream_line(stream, line)
  vim.bo[stream.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(stream.bufnr, stream.insert_at, stream.insert_at, false, { line })
  table.insert(stream.lines, line)
  stream.insert_at = stream.insert_at + 1
  if state.source_winnr and vim.api.nvim_win_is_valid(state.source_winnr) then
    vim.api.nvim_win_set_cursor(state.source_winnr, { math.max(stream.insert_at, 1), 0 })
  end
  add_proposed_highlight(stream.bufnr, stream.start_idx, #stream.lines)
end

function M.start_stream_preview(idx, block)
  if state.streaming_change or state.staged_changes[idx] then
    return false
  end

  local bufnr = block.target_bufnr
  if block.target_file then
    bufnr = use_source_buffer_for_path(block.target_file)
    if not bufnr then
      return false
    end
    block.target_bufnr = bufnr
    state.source_bufnr = bufnr
  end

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local target = block.target
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  focus_source_window(bufnr)

  local original_line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_idx, end_idx, mode = stage_range(bufnr, target, block)
  local original_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local original = vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
  local full_original = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.api.nvim_buf_set_lines(bufnr, start_idx, end_idx, false, {})

  state.streaming_change = {
    idx = idx,
    bufnr = bufnr,
    block = block,
    start_idx = start_idx,
    end_idx = end_idx,
    insert_at = start_idx,
    original = original,
    full_original = full_original,
    original_line_count = original_line_count,
    original_changedtick = original_changedtick,
    mode = mode,
    target = target,
    was_modifiable = was_modifiable,
    pending = "",
    lines = {},
  }
  state.applying = true
  render.start_forging_status()
  return true
end

function M.append_stream_preview(text)
  local stream = state.streaming_change
  if not stream or not text or text == "" or not vim.api.nvim_buf_is_valid(stream.bufnr) then
    return
  end

  stream.pending = stream.pending .. text
  while true do
    local newline = stream.pending:find("\n", 1, true)
    if not newline then
      break
    end
    local line = stream.pending:sub(1, newline - 1)
    stream.pending = stream.pending:sub(newline + 1)
    insert_stream_line(stream, line)
  end
end

function M.finish_stream_preview()
  local stream = state.streaming_change
  if not stream then
    return nil
  end

  if stream.pending ~= "" then
    insert_stream_line(stream, stream.pending)
  end

  if stream.mode == "replace" then
    remove_eof_blank_after_replace(stream.bufnr, stream.start_idx, #stream.lines, stream.end_idx, stream.original_line_count)
  elseif looks_like_whole_file(stream.full_original, stream.lines) then
    vim.bo[stream.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(stream.bufnr, stream.start_idx, stream.start_idx + #stream.lines, false, {})
    vim.api.nvim_buf_set_lines(stream.bufnr, 0, -1, false, stream.lines)
    stream.start_idx = 0
    stream.end_idx = -1
    stream.original = stream.full_original
    stream.mode = "replace"
    remove_eof_blank_after_replace(stream.bufnr, 0, #stream.lines, -1, #stream.full_original)
  end

  vim.bo[stream.bufnr].modifiable = stream.was_modifiable
  local change = staged_metadata(
    stream.block,
    stream.bufnr,
    stream.start_idx,
    stream.end_idx,
    stream.original,
    stream.lines,
    stream.original_changedtick
  )
  add_proposed_highlight(stream.bufnr, stream.start_idx, #stream.lines, changed_line_marks(stream.original, stream.lines))
  state.staged_changes[stream.idx] = change
  state.streaming_change = nil
  state.applying = false
  render.stop_forging_status()
  return change
end

-- ── public API ─────────────────────────────────────────────────────────────

--- Apply block N to the current buffer (replaces entire contents).
---@param idx number  1-based index into state.pending_blocks
function M.apply_to_current(idx)
  if block_while_applying("applying") then
    return
  end

  local staged = state.staged_changes[idx]
  if staged then
    if is_stale(staged) then
      report_stale(idx)
      return
    end
    if not write_buffer_to_disk(staged.bufnr) then
      render.append_status("Could not write implementation #" .. idx .. ".")
      return
    end
    clear_proposed_highlight(staged)
    staged.status = "accepted"
    state.staged_changes[idx] = nil
    if state.pending_blocks[idx] then
      state.pending_blocks[idx].applied = true
    end
    render.append_status("Accepted implementation #" .. idx .. " and wrote the source buffer.")
    vim.notify("[chatforge] Accepted implementation #" .. idx, vim.log.levels.INFO)
    return
  end

  local block = state.pending_blocks[idx]
  if block and block.stageable == false then
    vim.notify("[chatforge] That block is an example, not a staged implementation.", vim.log.levels.INFO)
    return
  end

  if block then
    vim.notify("[chatforge] Implementation #" .. idx .. " is not staged in the source buffer yet.", vim.log.levels.WARN)
  else
    vim.notify("[chatforge] No pending implementation #" .. idx .. ".", vim.log.levels.WARN)
  end
end

function M.accept_current()
  M.apply_to_current(first_staged_idx() or 1)
end

function M.diff_current()
  M.diff_with_current(first_staged_idx() or 1)
end

function M.jump_next()
  jump_staged("next")
end

function M.jump_prev()
  jump_staged("prev")
end

function M.stage_preview(idx)
  if block_while_applying("staging another change") then
    return
  end

  if state.staged_changes[idx] then
    return
  end

  local block = state.pending_blocks[idx]
  if not block or block.stageable == false then
    return
  end

  local lines, err = get_block_lines(idx)
  if err then
    vim.notify("[chatforge] " .. err, vim.log.levels.WARN)
    return
  end

  local bufnr = target_bufnr_for_block(idx)
  if block.target_file then
    bufnr = use_source_buffer_for_path(block.target_file)
    if not bufnr then
      return
    end
    block.target_bufnr = bufnr
    state.source_bufnr = bufnr
  end

  if not bufnr then
    vim.notify("[chatforge] Open or focus a source buffer first.", vim.log.levels.WARN)
    return
  end

  local target = block_target(idx, bufnr)
  if patch.is_search_replace(block.content) then
    stage_patch_live(bufnr, block.content, block, { highlight = true }, function(change)
      state.staged_changes[idx] = change
      render.append_status("Implementation #" .. idx .. " staged. Use :ChatAccept, :ChatReject, or :ChatDiff.")
      log.log("stage_preview_patch: block=%d bufnr=%d", idx, bufnr)
    end)
    return
  end

  write_lines_live(bufnr, lines, target, { highlight = true, block_index = idx }, function(change)
    state.staged_changes[idx] = change
    render.append_status("Implementation #" .. idx .. " staged. Use :ChatAccept, :ChatReject, or :ChatDiff.")
    log.log("stage_preview: block=%d bufnr=%d", idx, bufnr)
  end)
end

--- Apply block N to a specific file path (writes to disk, opens buffer).
---@param idx    number
---@param fpath  string
function M.apply_to_file(idx, fpath)
  if block_while_applying("applying") then
    return
  end

  local lines, err = get_block_lines(idx)
  if err then
    vim.notify("[chatforge] " .. err, vim.log.levels.WARN)
    return
  end

  -- Open (or create) the file in the source area and write it live.
  local bufnr = use_source_buffer_for_path(fpath)
  if not bufnr then
    return
  end

  write_lines_live(bufnr, lines, nil, { highlight = false }, function()
    write_buffer_to_disk(bufnr)
    state.pending_blocks[idx].applied = true
    vim.notify("[chatforge] Written block #" .. idx .. " -> " .. fpath, vim.log.levels.INFO)
  end)
end

function M.preview(idx)
  local block = state.pending_blocks[idx]
  if not block then
    vim.notify("[chatforge] No pending implementation #" .. idx .. ".", vim.log.levels.WARN)
    return
  end

  local width = math.max(math.floor(vim.o.columns * 0.72), 50)
  local height = math.max(math.floor(vim.o.lines * 0.62), 16)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = block.lang or vim.bo[block.target_bufnr or 0].filetype or ""
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(block.content or "", "\n", { plain = true }))

  local winnr = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " ChatPreview " .. idx .. " ",
    title_pos = "center",
  })

  local opts = { noremap = true, silent = true, buffer = bufnr }
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(winnr) then
      vim.api.nvim_win_close(winnr, true)
    end
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(winnr) then
      vim.api.nvim_win_close(winnr, true)
    end
  end, opts)
  vim.keymap.set("n", "a", function()
    if vim.api.nvim_win_is_valid(winnr) then
      vim.api.nvim_win_close(winnr, true)
    end
    M.accept_current()
  end, opts)
  vim.keymap.set("n", "r", function()
    if vim.api.nvim_win_is_valid(winnr) then
      vim.api.nvim_win_close(winnr, true)
    end
    M.reject_all()
  end, opts)
end

--- Open a diff between block N and the current buffer in a new tab.
---@param idx number
function M.diff_with_current(idx)
  if block_while_applying("opening a diff") then
    return
  end

  local lines, err = get_block_lines(idx)
  if err then
    vim.notify("[chatforge] " .. err, vim.log.levels.WARN)
    return
  end

  local staged = state.staged_changes[idx]
  local orig_bufnr = target_bufnr_for_block(idx)
  local original_scratch = nil
  local proposed_scratch = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(proposed_scratch, 0, -1, false, lines)

  if staged and staged.bufnr and vim.api.nvim_buf_is_valid(staged.bufnr) then
    original_scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(original_scratch, 0, -1, false, staged.original)
    vim.bo[original_scratch].filetype = vim.bo[staged.bufnr].filetype
    vim.bo[proposed_scratch].filetype = vim.bo[staged.bufnr].filetype
  else
    if not orig_bufnr then
      vim.notify("[chatforge] Open or focus a source buffer first.", vim.log.levels.WARN)
      return
    end
    vim.bo[proposed_scratch].filetype = vim.bo[orig_bufnr].filetype
  end

  vim.cmd("tabnew")
  if original_scratch then
    vim.api.nvim_set_current_buf(original_scratch)
    vim.bo[original_scratch].buftype = "nofile"
  else
    vim.api.nvim_set_current_buf(orig_bufnr)
  end
  vim.cmd("diffthis")
  vim.cmd("vsplit")
  vim.api.nvim_set_current_buf(proposed_scratch)
  vim.cmd("diffthis")
  vim.bo[proposed_scratch].buftype = "nofile"

  vim.notify("[chatforge] Diff opened in new tab. :tabclose when done.", vim.log.levels.INFO)
end

--- Discard all pending blocks (Reject all).
function M.reject_all()
  if block_while_applying("rejecting") then
    return
  end

  local retained = {}
  for idx, change in pairs(state.staged_changes) do
    if is_stale(change) then
      retained[idx] = change
      report_stale(idx)
    elseif change.bufnr and vim.api.nvim_buf_is_valid(change.bufnr) then
      local was_modifiable = vim.bo[change.bufnr].modifiable
      vim.bo[change.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(
        change.bufnr,
        change.start_idx,
        change.start_idx + change.new_line_count,
        false,
        change.original
      )
      vim.bo[change.bufnr].modifiable = was_modifiable
      change.status = "rejected"
      clear_proposed_highlight(change)
    end
    if not retained[idx] and state.pending_blocks[idx] then
      state.pending_blocks[idx].applied = false
    end
  end
  state.staged_changes = retained
  if next(retained) == nil then
    state.pending_blocks = {}
  end
  state.edit_target = nil
  if next(retained) == nil then
    render.append_status("Rejected pending implementation.")
    vim.notify("[chatforge] All pending changes rejected.", vim.log.levels.INFO)
  end
end

return M
