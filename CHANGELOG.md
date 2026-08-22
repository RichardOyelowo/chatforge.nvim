# Changelog

All notable changes to ChatForge are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.4.0] - 2026-08-20

### Added

- OpenRouter provider (`openrouter`), speaking the OpenAI chat-completions wire format against `openrouter.ai/api/v1`.
- Groq provider (`groq`), speaking the OpenAI chat-completions wire format against `api.groq.com/openai/v1`.
- Google AI Studio provider (`google`), using Gemini's native `generateContent` REST API rather than the OpenAI format.
- Combined `:ChatModel` picker: with no argument, it now queries every registered provider in parallel and lists all available models as `provider/model` in one picker, so choosing a model can also switch provider. Providers with no key configured, or that are unreachable, contribute nothing to the list instead of erroring.
- `{afile path}` legacy shorthand context reference. Documented and tested since 0.2.0, but missing from the dispatcher until now.
- Vim help section 10, "Providers", documenting every provider's environment variable, base URL, and config keys.
- README table of contents and a matching Providers section.

### Changed

- `default_provider` has no built-in value anymore. No provider runs until one is set in `setup()` or chosen with `:ChatBackend switch`.
- `:ChatBackend switch`, `:ChatBackend status`, `:ChatBackend models`, the chat header, and the combined model picker all show a clear message pointing at `:ChatBackend switch <provider>` instead of silently assuming Ollama when no provider is configured.
- README and vim help rewritten for the seven-provider, no-default reality.

### Fixed

- API keys read through `vim.fn.getenv()` could silently carry Neovim's `vim.NIL` sentinel through a fallback chain instead of failing cleanly, only crashing later at string concatenation rather than reporting a missing key. Affected `anthropic`, `openai_compatible`, and `deepseek`.
- `providers.ollama.url` was documented and accepted in `setup()` but never actually read; only the deprecated top-level `ollama_url` worked.
- Per-provider default models were only resolved for `openai_compatible`. Every other provider silently fell back to the Ollama-oriented `default_model` instead of its own configured model.
- `:ChatBackend switch` duplicated, and had drifted from, that same default-model logic instead of reusing one shared resolver.
- `completeopt` was assigned as a buffer-local option on the input buffer, which Neovim has never supported for that option. It is now scoped to the buffer through `BufEnter`/`BufLeave` instead.
- Removed dead `lua/chatforge/api/backends.lua`, a second, disconnected Ollama implementation that nothing in the plugin required.

### Breaking

- Buffers no longer default to Ollama. Configs that relied on the implicit default must set `default_provider` explicitly, or run `:ChatBackend switch <provider>` before sending the first message.

## [0.3.0] - 2026-07-17

### Added

- Multi-provider support with provider registry and standard streaming contract.
- OpenAI-compatible API provider with SSE streaming (`openai_compatible`).
- `:ChatStop` command to cancel active requests and stop underlying curl jobs.
- `:ChatBackend switch <provider>` and `:ChatBackend models` subcommands.

### Changed

- Staging now uses diff hunks via `vim.diff` for non-disruptive insertions and deletions without altering unchanged lines.
- Proposed line highlight style updated to background tint (`#2e3b52`) instead of underline.
- Chat buffer excludes large staged code blocks (over 5 lines) when code is staged directly in the source buffer.
- Restricted scroll clamping autocmds to prevent window bouncing during input.

### Fixed

- Health check now verifies all registered providers via the new health contract.

## [0.2.3] - 2026-06-26

### Added

- Avante-inspired SEARCH/REPLACE patch staging for edit requests.
- Dedicated patch parser for exact old-text matching and targeted source-buffer replacement.

### Fixed

- Edit responses that contain patch text no longer write that patch text into the source buffer.
- Inferred edits can now replace only the matched changed section instead of appending a whole-file response below the cursor.

## [0.2.2] - 2026-06-26

### Fixed

- Whole-file model responses for inferred live edits now replace the matching source buffer instead of appending a duplicate copy at the cursor.
- Changed-line highlights still mark only the proposed differences after a whole-file rewrite is detected.
- Reject restores the original whole buffer after an inferred whole-file rewrite.

## [0.2.1] - 2026-06-26

### Fixed

- Removed literal `AI` virtual text from staged source lines.
- Inferred live edits no longer clear the whole file before streaming.
- Partial edit responses now insert highlighted proposed code at the source cursor.
- Visual selections still replace only the selected line range.
- The chat waiting status now uses `Chat's forging` with a small spinner.

### Changed

- Edit prompts now ask for stageable code instead of always asking for a full-file replacement.

## [0.2.0] - 2026-06-25

### Added

- `:ChatEdit` for forcing a live staged edit when prompt wording is unclear.
- Broader edit-intent detection for add, change, update, remove, rewrite, generate, create, improve, and similar requests.
- Exact preview and diff hints in chat output for each response block.
- Related file context memory for cross-file questions, such as checking CSS against a recently shared HTML file.
- `{afile path}` compatibility shorthand for named file context.
- Optional dressing.nvim support for model and backend prompts, with native `vim.ui` fallback.
- Buffer-local completion settings for the ChatForge input buffer.
- Scroll clamping for the chat pane so resizing or scrolling cannot leave a mostly empty one-line view.
- Tests for forced staging, related file context, dressing fallback, and input completion behavior.

### Changed

- Edit-shaped prompts now stage in the live source buffer by default.
- Review and explanation prompts stay in chat unless `:ChatEdit` is used.
- Intent classification now uses the user's prompt only, not injected source text.
- The message input pane is eight lines tall.
- README and Vim help now describe the v0.2 workflow and supported commands.

### Removed

- Removed stale demo recordings and README demo links.

### Safety

- `:ChatReset` clears remembered related file context.
- Recent related context is added only for prompts that clearly ask about relationships between files.
- Global completion UI settings are not changed.

## [0.1.0] - 2026-06-22

### Added

- Per-buffer conversations and model selection.
- Ollama chat with streamed response handling.
- Right-side Markdown chat and bottom input pane.
- Bare current-buffer and current-directory context references.
- Braced named context through `@{file path}` and `@{dir path}`.
- Live source-buffer staging with proposed-line highlights.
- Preview, diff, accept, reject, and staged-change navigation commands.
- Visual-selection rewrites.
- Changed-buffer protection for stale staged proposals.
- `:checkhealth chatforge` diagnostics.
- `:help chatforge` documentation.
- Dependency-free headless Neovim tests and GitHub Actions CI.

### Safety

- Injected source is not recursively parsed for context references.
- Normal prose after bare `@file` is never interpreted as a path.
- Stale Accept and Reject operations stop before overwriting newer buffer edits.

[Unreleased]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/RichardOyelowo/chatforge.nvim/releases/tag/v0.1.0
