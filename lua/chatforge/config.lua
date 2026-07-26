local M = {}
 
---@class AiChatConfig
---@field default_model  string   Model tag passed to Ollama (e.g. "llama3", "codestral")
---@field ollama_url     string   Base URL for the Ollama API
---@field max_tokens     number   Max tokens to request
---@field temperature    number   Sampling temperature
---@field system_prompt  string   Prepended on every request
---@field debug          boolean  Enable debug logging
M.defaults = {
  default_model = "llama3",
  ollama_url    = "http://localhost:11434",
  max_tokens    = 4096,
  temperature   = 0.2,
  max_output_tokens = 2048,
  context_tokens = 64000,
  highlights = {
    diff = {
      incoming = "ChatforgeProposedChange",
    },
  },
  default_provider = "ollama",
  providers = {
    ollama = {
      url = "http://localhost:11434",
    },
    openai_compatible = {
      base_url = "https://api.openai.com/v1",
      model = "gpt-4o",
    },
    anthropic = {
      base_url = "https://api.anthropic.com",
      model = "claude-3-5-sonnet-20241022",
    },
    deepseek = {
      base_url = "https://api.deepseek.com",
      model = "deepseek-chat",
    },
  },
  debug         = false,
  system_prompt = "You are a helpful coding assistant embedded in Neovim. "
               .. "Be concise. Use fenced code blocks with language tags for all code. "
               .. "When ChatForge context is included, it is accessible user-provided content from the editor. "
               .. "Do not claim that you cannot see that content. "
               .. "When suggesting file changes, clearly state the filename.",
}
 
---@type AiChatConfig
M.values = {}
 
function M.setup(opts)
  M.values = vim.tbl_deep_extend("force", M.defaults, opts or {})
end
 
return M
 
