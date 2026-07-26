local M = {}

local providers = require("chatforge.providers")

function M.get(name)
  return providers.get(name)
end

function M.list()
  return providers.list()
end

return M