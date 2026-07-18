local M = {}

local registry = {}

function M.register(name, provider)
  registry[name] = provider
end

function M.get(name)
  return registry[name]
end

function M.list()
  local keys = {}
  for k in pairs(registry) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return keys
end

-- Register default providers
M.register("ollama", require("chatforge.providers.ollama"))
M.register("openai_compatible", require("chatforge.providers.openai"))

return M
