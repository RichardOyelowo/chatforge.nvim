local M = {}

--- vim.fn.getenv() returns the vim.NIL sentinel (a non-nil userdata value),
--- not Lua nil, when the variable is unset. Left unguarded, `a or vim.fn.getenv(...)`
--- fallback chains and `if not value` checks silently treat a missing
--- environment variable as present, and the value only fails much later
--- wherever it finally gets used as a string (e.g. header concatenation).
--- Every provider that reads an API key from the environment should go
--- through this instead of calling vim.fn.getenv() directly.
---@param name string
---@return string|nil
function M.get(name)
  local value = vim.fn.getenv(name)
  if value == vim.NIL then
    return nil
  end
  return value
end

return M
