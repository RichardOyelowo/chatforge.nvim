# <img src="images/chatforge_logo.svg" alt="ChatForge">

Provider-agnostic, staged AI coding chat for Neovim.

ChatForge keeps the coding assistant inside the editor flow:

1. Open a file.
2. Ask for a change.
3. Watch the proposal stage directly in the live Neovim buffer.
4. Review the diff.
5. Accept to write it, or reject to restore the original text.

Version `0.3.0` adds multi-provider support, reliable staged edits, and interactive model selection. Anthropic, OpenAI-compatible endpoints, DeepSeek, OpenRouter, Groq, Google AI Studio, and Ollama all work behind the same streaming contract, so the workflow stays the same no matter which one answers the request. Context stays explicit and edits stay reversible proposals until you accept them.

Full reference documentation ships with the plugin. Run `:help chatforge` once it's installed.

## Table of Contents

- [Why This Project Matters](#why-this-project-matters)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Chat Interface](#chat-interface)
- [Live Edit Workflow](#live-edit-workflow)
- [Review Commands](#review-commands)
- [Context](#context)
  - [Current Buffer](#current-buffer)
  - [Named Files](#named-files)
  - [Directories](#directories)
  - [Related File Context](#related-file-context)
  - [Completion](#completion)
- [Commands](#commands)
- [Providers](#providers)
- [Safety Model](#safety-model)
- [Backend And Model Recovery](#backend-and-model-recovery)
- [Configuration](#configuration)
- [Health Check](#health-check)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [Known Limitations](#known-limitations)

## Why This Project Matters

Chat tools are useful, but copying code between a chat panel and an editor hides where a change will land. ChatForge stages changes in the source buffer itself. The proposed lines are highlighted, the original text is kept, and the file is written only when you accept the proposal.

The main design choices are:

- **Live staged edits:** edit requests stream into the opened source buffer.
- **Review before write:** `:ChatAccept` writes, `:ChatReject` restores.
- **Per-buffer sessions:** each source buffer keeps its own provider, model, and chat history.
- **Any provider:** Anthropic, OpenAI-compatible endpoints, DeepSeek, OpenRouter, Groq, Google AI Studio, or Ollama, switchable per buffer with `:ChatBackend switch`. ChatForge does not assume any one of them, see [Providers](#providers).
- **Explicit context:** use `@file`, `@{file path}`, `@dir`, or `@{dir path}` when the model needs code or project layout.
- **Related file memory:** recently shared files can be reused when you ask whether files match each other, such as CSS against HTML.
- **No surprise keymaps:** ChatForge creates commands and buffer-local input mappings only.

## Requirements

- Neovim 0.10 or newer
- `curl` in `$PATH`
- A provider: an API key for Anthropic, OpenAI, DeepSeek, OpenRouter, Groq, or Google AI Studio, or a local Ollama install

Optional:

- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) can render the Markdown chat and input buffers.
- [dressing.nvim](https://github.com/stevearc/dressing.nvim) is used for model and backend prompts when available. Native `vim.ui.input` and `vim.ui.select` remain the fallback.

Both optional plugins are detected by `:checkhealth chatforge`.

## Installation

### lazy.nvim

```lua
{
  "RichardOyelowo/chatforge.nvim",
  version = "v0.3.0",
  -- No external plugin dependencies. Only `curl` on $PATH is required at runtime.
  cmd = {
    "Chat",
    "ChatSend",
    "ChatEdit",
    "ChatModel",
    "ChatForgeSelectModel",
    "ChatForgeSetModel",
    "ChatReset",
    "ChatApply",
    "ChatAccept",
    "ChatDiff",
    "ChatReviewDiff",
    "ChatPreview",
    "ChatReject",
    "ChatNextChange",
    "ChatPrevChange",
    "ChatBackend",
    "ChatStop",
  },
  opts = {
    -- default_provider has no built-in value. Pick one, or leave it unset
    -- and run :ChatBackend switch <provider> the first time you open a buffer.
    default_provider = "anthropic",
    providers = {
      anthropic = { base_url = "https://api.anthropic.com", model = "claude-3-5-sonnet-20241022" },
      openai_compatible = { base_url = "https://api.openai.com/v1", model = "gpt-4o" },
      deepseek = { base_url = "https://api.deepseek.com", model = "deepseek-chat" },
      openrouter = { base_url = "https://openrouter.ai/api/v1", model = "anthropic/claude-sonnet-4.6" },
      groq = { base_url = "https://api.groq.com/openai/v1", model = "openai/gpt-oss-120b" },
      google = { base_url = "https://generativelanguage.googleapis.com/v1beta", model = "gemini-2.5-flash" },
      ollama = { url = "http://localhost:11434" },
    },
  },
}
```

Set the API key for whichever provider you use:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export DEEPSEEK_API_KEY=sk-...
export OPENROUTER_API_KEY=sk-or-...
export GROQ_API_KEY=gsk_...
export GOOGLE_API_KEY=AI...   # GEMINI_API_KEY also works
```

An `api_key` field under `providers.<name>` works the same way if you keep secrets out of your shell environment.

Ollama needs no key, only a running server:

```sh
ollama serve
ollama pull llama3
```

Check the editor setup:

```vim
:checkhealth chatforge
```

Use `event = "VeryLazy"` instead of `cmd` if you want ChatForge loaded before its first command.

## Quick Start

Open a source file:

```vim
:Chat
```

Ask a read-only question:

```vim
:ChatSend review @file for error-handling gaps
```

Ask for a live staged edit:

```vim
:ChatSend fix the error handling in this file
```

Force a live staged edit when the wording is unclear:

```vim
:ChatEdit add input validation to this file
```

Review the proposal:

```vim
:ChatDiff
```

Keep it:

```vim
:ChatAccept
```

Restore the original text:

```vim
:ChatReject
```

## Chat Interface

`:Chat` opens a 65-column right split. The chat buffer is above an eight-line message pane. Both buffers use the `markdown` filetype and are temporary `nofile` buffers.

The message pane behavior is buffer-local:

- `<Enter>` sends.
- `<Enter>` accepts the selected completion item first when completion is visible.
- `<C-j>` inserts a newline.
- Typing `@` opens context completion.
- Completion uses buffer-local menu settings and does not change the user's global completion UI.

The chat view clamps scrolling so it does not collapse into a mostly empty one-line view after resizing or scrolling.

Normal-mode editing keys in the read-only chat pane redirect to the input. ChatForge does not define global keymaps.

## Live Edit Workflow

ChatForge stages code when a prompt asks to:

- fix
- refactor
- add
- change
- update
- remove
- rewrite
- generate
- implement
- create
- improve
- make code changes

Plain review and explanation prompts stay in chat. Fenced code in those answers is shown as example code and is not staged unless you use `:ChatEdit`.

For normal edit requests, ChatForge asks the model for exact SEARCH/REPLACE patch blocks. The old text is matched against the current buffer, and only the matching range is replaced. ChatForge highlights proposed lines with `ChatforgeProposedChange` and does not add text markers into the source buffer.

Targets:

- Edit-shaped prompts without a selected range use SEARCH/REPLACE patches when available. Small raw-code fallbacks insert at the source cursor. Whole-file fallbacks replace the buffer only when they match the open file shape.
- Visual selections replace only the selected line range.
- `create file <path>` opens or creates that path in the source window, then stages the generated block there.

Before another message can be sent, accept or reject any existing staged edit.

## Review Commands

The chat output prints exact commands for each response block, such as:

```vim
:ChatPreview 2
:ChatDiff 2
```

Use these commands:

| Command | Behavior |
|---|---|
| `:ChatPreview [N]` | Open response block N in a centered floating window. |
| `:ChatDiff [N]` | Open a diff tab for response block N. |
| `:ChatReviewDiff` | Diff the first staged block. |
| `:ChatAccept` | Accept and write the first staged block. |
| `:ChatApply [N]` | Accept and write staged block N. |
| `:ChatReject` | Restore original lines for all fresh staged blocks. |
| `:ChatPrevChange` | Jump to the start of the first staged block. |
| `:ChatNextChange` | Jump to the end of the first staged block. |

Preview window keys:

- `q` or `<Esc>` closes the preview.
- `a` accepts the first staged change.
- `r` rejects all fresh staged changes.

## Context

Context references are case-insensitive. `@FILE`, `@File`, and `@file` behave the same way.

### Current Buffer

```vim
:ChatSend can you review @file fully?
```

`@file` injects the current live Neovim buffer, including unsaved edits. It does not consume nearby prose, so `fully?` remains part of the question.

### Named Files

```vim
:ChatSend compare @{file lua/old.lua} with @{file lua/new.lua}
:ChatSend review @{file docs/design notes.md}
```

Named files are read from disk. Relative paths use Neovim's current working directory. Absolute paths, `~`, and environment variables use `vim.fn.expand()`.

ChatForge also accepts this compatibility shorthand:

```vim
:ChatSend review {afile ./team.html}
```

`@{file .}`, `@{file /}`, and an empty file reference mean the current live buffer. That special `/` meaning applies only to file context.

Unreadable files become inline HTML context errors in the model prompt. The request still runs.

### Directories

```vim
:ChatSend use @dir to explain the project layout
:ChatSend inspect @{dir lua/chatforge}
```

`@dir` injects a sorted, one-level listing of the current working directory. `@{dir path}` injects a sorted, one-level listing under the current working directory.

Named directory paths stay under `:pwd`. A leading slash is stripped, so `@{dir /lua}` means `<cwd>/lua`. Absolute directory paths, `~`, and environment variable expansion are not supported yet.

One directory read returns at most 64 entries.

### Related File Context

When a message shares file context with `@file`, `@{file path}`, or `{afile path}`, ChatForge remembers the most recent files in the current Neovim session. Later prompts that clearly ask about file relationships, such as whether CSS matches HTML, include those recent files as related context.

This fixes the common workflow where you first share an HTML file, then switch to a CSS file and ask whether they match. `:ChatReset` clears the remembered context.

### Completion

Typing `@` in the message pane opens context completion. ChatForge scans the current working directory recursively and offers up to 80 items:

- `@file`
- `@dir`
- `@{dir path}`
- `@{file path}`

Directories appear before files. Paths under `.git` are skipped. The list is cached by working directory, so new paths may not appear until the working directory changes or Neovim restarts.

Injected source is protected from a second context pass. An `@{file ...}` string inside source code remains literal and cannot pull in another file.

## Commands

| Command | Behavior |
|---|---|
| `:Chat` | Open ChatForge for the current source buffer, or focus the existing chat input. |
| `:ChatSend [message]` | Send text. With no text, focus the input or send its contents. A range sends a selected-line rewrite. |
| `:ChatEdit <message>` | Force a live staged edit in the source buffer. A range rewrites only the selected lines. |
| `:ChatModel [model]` | Set the model for the current source buffer. With no argument, query every registered provider in parallel and open one combined picker across all of them, labeled `provider/model`, so picking a model can also switch provider. Providers with no key configured, or that are unreachable, simply contribute nothing to the list. |
| `:ChatReset` | Ignore the current request result, reject fresh staged work, clear staged metadata, clear remembered related context, and redraw the chat. |
| `:ChatPreview [N]` | Open response block N in a float. Default: 1. |
| `:ChatDiff [N]` | Open a diff for response block N. Default: 1. |
| `:ChatReviewDiff` | Diff the first staged block. |
| `:ChatAccept` | Accept and write the first staged block. |
| `:ChatApply [N]` | Accept and write staged block N. Default: 1. |
| `:ChatReject` | Restore original lines for all non-stale staged blocks. |
| `:ChatNextChange` | Jump to the end of the first staged block. |
| `:ChatPrevChange` | Jump to the start of the first staged block. |
| `:ChatStop` | Cancel the active request and stop its `curl` job. |
| `:ChatBackend status` | Show the active provider and model for the current buffer, plus Ollama job state when the active provider is Ollama. Warns instead if no provider is set yet. |
| `:ChatBackend switch <provider>` | Switch the current buffer to `ollama`, `openai_compatible`, `anthropic`, `deepseek`, `openrouter`, `groq`, or `google`, and reset the model to that provider's configured default. |
| `:ChatBackend models` | List models available from the current buffer's active provider. |
| `:ChatBackend start` | Show the `ollama serve` command. It does not start a server. |
| `:ChatBackend stop` | Stop a plugin-managed Ollama server or `ollama pull` job. |

`:ChatForgeSelectModel` and `:ChatForgeSetModel` are aliases for `:ChatModel`, kept for discoverability.

## Providers

ChatForge ships seven providers behind one streaming contract. None of them runs by default, see [Configuration](#configuration) for `default_provider`.

| Name | Key | Base URL |
|---|---|---|
| `anthropic` | `ANTHROPIC_API_KEY` | `api.anthropic.com` |
| `openai_compatible` | `OPENAI_API_KEY` | `api.openai.com/v1` |
| `deepseek` | `DEEPSEEK_API_KEY` | `api.deepseek.com` |
| `openrouter` | `OPENROUTER_API_KEY` | `openrouter.ai/api/v1` |
| `groq` | `GROQ_API_KEY` | `api.groq.com/openai/v1` |
| `google` | `GOOGLE_API_KEY` or `GEMINI_API_KEY` | `generativelanguage.googleapis.com` |
| `ollama` | none | `localhost:11434` |

Every provider reads `providers.<name>.api_key` from `setup()` before its environment variable, and `providers.<name>.model` for the model a new buffer starts on when `default_provider` is that provider. Ollama has no key and reads `providers.ollama.url` instead of a `base_url`.

`openai_compatible`, `openrouter`, and `groq` all speak the OpenAI chat-completions wire format, so any endpoint implementing that format can be pointed at through `openai_compatible`'s `base_url`.

`google` speaks Gemini's native `generateContent` REST API rather than the OpenAI format. System prompts are sent as a separate `systemInstruction` field rather than a system-role message.

Switch a buffer's provider at any time:

```vim
:ChatBackend switch groq
```

This resets the buffer's model to that provider's configured default from `providers.<name>.model`.

## Safety Model

Staging is an in-memory buffer edit. It is not a disk write.

`ChatAccept` and `ChatApply` check the target buffer's `changedtick`. If the buffer changed after staging, accept stops instead of overwriting newer edits.

`ChatReject` uses the same stale check. A fresh proposal is replaced with the saved original lines. Reject does not write the restored text to disk.

The source buffer becomes modified during staging. Autosave plugins, manual `:write`, or other editor commands can still write the proposal before acceptance. ChatForge does not block external writes.

There is no force-accept or force-reject command. Review the diff and resolve stale buffers manually.

## Backend And Model Recovery

Each provider reports failures through the same handler, so recovery looks different depending on what went wrong:

- **No provider configured.** Sending a message, or running `:ChatBackend status` or `models`, on a buffer with no provider set shows a message pointing at `:ChatBackend switch <provider>` instead of guessing one.
- **Missing API key.** Anthropic, OpenAI-compatible, DeepSeek, OpenRouter, Groq, and Google AI Studio requests fail immediately with a message naming the expected environment variable, or the `api_key` field to set under `providers.<name>` instead.
- **Ollama unreachable.** ChatForge offers to show the `ollama serve` command or ignore the error. `:ChatBackend start` also shows the command. It does not start an Ollama server.
- **Ollama model missing.** ChatForge can run `ollama pull <model>` as a Neovim job, show the command only, or ignore the error. `:ChatBackend stop` can stop a plugin-managed pull. It cannot stop an Ollama server started outside ChatForge.

`:ChatBackend status` reports the active provider and model for the current buffer. For Ollama it also reports tracked server and model-pull state. Since ChatForge does not start the server itself, server status normally reads `not-managed` even when Ollama is reachable.

## Configuration

All fields are optional except `default_provider`, which has no built-in value. These are the current defaults:

```lua
require("chatforge").setup({
  default_provider = nil, -- set this, or run :ChatBackend switch
  default_model = "llama3",
  ollama_url = "http://localhost:11434",
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
    openrouter = {
      base_url = "https://openrouter.ai/api/v1",
      model = "anthropic/claude-sonnet-4.6",
    },
    groq = {
      base_url = "https://api.groq.com/openai/v1",
      model = "openai/gpt-oss-120b",
    },
    google = {
      base_url = "https://generativelanguage.googleapis.com/v1beta",
      model = "gemini-2.5-flash",
    },
  },
  max_tokens = 4096,
  max_output_tokens = 2048,
  context_tokens = 64000,
  temperature = 0.2,
  highlights = {
    diff = {
      incoming = "ChatforgeProposedChange",
    },
  },
  debug = false,
  system_prompt = "You are a helpful coding assistant embedded in Neovim. "
    .. "Be concise. Use fenced code blocks with language tags for all code. "
    .. "When ChatForge context is included, it is accessible user-provided content from the editor. "
    .. "Do not claim that you cannot see that content. "
    .. "When suggesting file changes, clearly state the filename.",
})
```

| Field | Meaning |
|---|---|
| `default_provider` | Provider a new buffer starts on: `ollama`, `openai_compatible`, `anthropic`, `deepseek`, `openrouter`, `groq`, or `google`. Unset by default, see [Providers](#providers). |
| `default_model` | Fallback model used only when the active provider's own `providers.<name>.model` is unset. |
| `providers.<name>.model` | Model tag for that provider. Read first when a new buffer picks its starting model. |
| `providers.<name>.base_url` / `.url` | Base URL for that provider's API. Ollama uses `.url`; the others use `.base_url`. |
| `providers.<name>.api_key` | API key for that provider, checked before the matching environment variable. |
| `ollama_url` | Fallback base URL used only if `providers.ollama.url` is unset. |
| `max_output_tokens` | Requested output token limit. Takes precedence over `max_tokens`. |
| `max_tokens` | Legacy fallback for `max_output_tokens` when it is absent. |
| `context_tokens` | Context window size passed to Ollama as `num_ctx`. Separate from the 160-line automatic context cap. |
| `temperature` | Sampling temperature. |
| `highlights.diff.incoming` | Highlight group applied to proposed lines. |
| `debug` | Show `[chatforge]` dispatch, request, parser, and backend notifications. |
| `system_prompt` | System message prepended to every request. Set to an empty string to omit it. |

Unknown fields are retained by the config merge but are not used by ChatForge itself.

## Health Check

```vim
:checkhealth chatforge
```

The health check reports:

- Neovim 0.10 support
- `curl` availability
- whether `setup()` ran
- writable state directory status
- reachability for every registered provider, using each provider's own health contract
- render-markdown.nvim detection
- dressing.nvim detection

The writable state directory check is diagnostic. ChatForge keeps chat sessions in memory and does not persist them there.

## Testing

From the repository root:

```sh
nvim --headless -n -i NONE -u tests/minimal_init.lua -l tests/run.lua
```

The suite needs Neovim 0.10 or newer. It does not need a running provider or external Lua test libraries.

## Troubleshooting

### No Provider Configured

Set `default_provider` in `setup()`, or run `:ChatBackend switch <provider>` for the current buffer. See [Providers](#providers) for the list of names.

### API Key Not Set

Set the environment variable named in the error (see [Providers](#providers)), or add `api_key` under `providers.<name>` in `setup()`. Then run `:checkhealth chatforge`.

### `Ollama unreachable`

Start Ollama in a terminal:

```sh
ollama serve
```

Check `providers.ollama.url` (or the legacy `ollama_url`), then run `:checkhealth chatforge`.

### Model Not Found

For Ollama:

```sh
ollama pull llama3
```

Replace `llama3` with the model shown by `:ChatModel` or your configuration. For API providers, check that the model name matches one your account has access to; `:ChatBackend models` lists what the provider reports.

### A Proposal Will Not Accept Or Reject

The target buffer changed after staging. ChatForge leaves the newer buffer untouched. Run `:ChatDiff N`, then resolve the file manually. There is no force action.

### `That block is an example, not a staged implementation`

The request was treated as normal chat, or a full-file response was too short to look like a replacement. Use edit-shaped wording, `:ChatEdit`, `edit file <path>`, or a visual selection when you want a live edit.

### Context Points At The Wrong Place

Run `:pwd`. Bare `@dir`, named file paths, named directory paths, and completion all depend on Neovim's current working directory. Bare `@file` always uses the live source buffer.

### Context Completion Is Missing A New Path

Completion is cached by working directory and capped at 80 entries. Type the braced reference manually, change directories, or restart Neovim.

### Debugging A Request

Set `debug = true`, reproduce the problem, and inspect `:messages`.

## Known Limitations

- No provider is assumed. Requests fail with a clear message until `default_provider` is set or `:ChatBackend switch` has run at least once for the buffer.
- Chat and model state are not persisted across Neovim sessions.
- One request can be active at a time across the plugin.
- Reset ignores an active request's eventual result but does not stop its underlying `curl` job.
- One staged edit must be accepted or rejected before another message is sent.
- Edit requests prefer exact SEARCH/REPLACE patch blocks. Raw code blocks remain a fallback.
- Inferred raw-code edit fallbacks insert small proposed blocks at the cursor. Whole-file model responses that match the open buffer replace the buffer and highlight only changed lines. Use SEARCH/REPLACE or a visual selection for precise replacement of a known range.
- Multi-file patches are not parsed or applied as one transaction.
- `delete file` does not delete files.
- Staging changes the live buffer. Autosave or manual `:write` can put an unaccepted proposal on disk.
- Reject restores the buffer in memory but does not write the restoration to disk.
- Stale proposals have no force action and Diff does not include the newer user-edited state.
- Named staging target paths cannot contain spaces.
- Named directory context stays under the current working directory and returns at most 64 entries from one level.
- Context and completion do not apply ignore files such as `.gitignore`.
- Completion is capped at 80 items and cached until the working directory changes.
- `list_models` has a three-second timeout per provider inside the combined `:ChatModel` picker, so one slow or unreachable provider cannot block the others.
- The parser recognizes triple-backtick fences only when the opening fence ends with a newline.
- ChatForge defines no global keymaps.
