local M = {}

local did_setup_dressing = false

local function maybe_setup_dressing()
  if did_setup_dressing then
    return
  end
  did_setup_dressing = true

  local ok, dressing = pcall(require, "dressing")
  if not ok or type(dressing) ~= "table" or type(dressing.setup) ~= "function" then
    return
  end

  dressing.setup({})
end

function M.input(opts, on_confirm)
  maybe_setup_dressing()
  return vim.ui.input(opts, on_confirm)
end

function M.select(items, opts, on_choice)
  maybe_setup_dressing()
  return vim.ui.select(items, opts, on_choice)
end

return M
