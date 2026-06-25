# Changelog

All notable changes to ChatForge are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/RichardOyelowo/chatforge.nvim/releases/tag/v0.1.0
