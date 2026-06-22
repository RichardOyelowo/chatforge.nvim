# Changelog

All notable changes to ChatForge are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/RichardOyelowo/chatforge.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/RichardOyelowo/chatforge.nvim/releases/tag/v0.1.0
