# <img src="images/chatforge_logo.svg" alt="ChatForge">

Local-first, staged AI coding chat for Neovim.

ChatForge keeps the coding assistant inside the editor flow:

1. Open a file.
2. Ask for a change.
3. Watch the proposal stage directly in the live Neovim buffer.
4. Review the diff.
5. Accept to write it, or reject to restore the original text.

Version `0.2.3` is focused on making that loop reliable. It uses Ollama, keeps context explicit, avoids global keymaps, and treats AI edits as reversible proposals before they reach disk.

## Why ChatForge

Chat tools are useful, but copying code between a chat panel and an editor hides where a change will land. ChatForge stages changes in the source buffer itself. The proposed lines are highlighted, the original text is kept, and the file is written only when you accept the proposal.

The main design choices are:

- **Live staged edits:** edit requests stream into the opened source buffer.
- **Review before write:** `:ChatAccept` writes, `:ChatReject` restores.
- **Per-buffer sessions:** each source buffer keeps its own model and chat history.
- **Explicit context:** use `@file`, `@{file path}`, `@dir`, or `@{dir path}` when the model needs code or project layout.
- **Related file memory:** recently shared files can be reused when you ask whether files match each other, such as CSS against HTML.
- **No surprise keymaps:** ChatForge creates commands and buffer-local input mappings only.
- **Local-first backend:** Ollama is the v0.2 backend. No API key is required.

## Requirements

- Neovim 0.10 or newer
- `curl` in `$PATH`
- [Ollama](https://ollama.com)
- An installed Ollama model, such as `llama3`

Optional:

- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) can render the Markdown chat and input buffers.
- [dressing.nvim](https://github.com/stevearc/dressing.nvim) is used for model and backend prompts when available. Native `vim.ui.input` and `vim.ui.select` remain the fallback.

Both optional plugins are detected by `:checkhealth chatforge`.

## Installation

### lazy.nvim

```lua
{
  "RichardOyelowo/chatforge.nvim",
  version = "v0.2.3",
  cmd = {
    "Chat",
    "ChatSend",
    "ChatEdit",
    "ChatModel",
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
  },
  opts = {
    default_model = "llama3",
    ollama_url = "http://localhost:11434",
  },
}
```

Start Ollama:

```sh
ollama serve
```

Install the model in another terminal:

```sh
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

Named directory paths stay under `:pwd`. A leading slash is stripped, so `@{dir /lua}` means `<cwd>/lua`. Absolute directory paths, `~`, and environment variable expansion are not supported in v0.2.3.

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
| `:ChatModel [model]` | Set the model for the current source buffer. With no argument, open a prompt. |
| `:ChatReset` | Ignore the current request result, reject fresh staged work, clear staged metadata, clear remembered related context, and redraw the chat. |
| `:ChatPreview [N]` | Open response block N in a float. Default: 1. |
| `:ChatDiff [N]` | Open a diff for response block N. Default: 1. |
| `:ChatReviewDiff` | Diff the first staged block. |
| `:ChatAccept` | Accept and write the first staged block. |
| `:ChatApply [N]` | Accept and write staged block N. Default: 1. |
| `:ChatReject` | Restore original lines for all non-stale staged blocks. |
| `:ChatNextChange` | Jump to the end of the first staged block. |
| `:ChatPrevChange` | Jump to the start of the first staged block. |
| `:ChatBackend [status\|start\|stop]` | Inspect backend helper state, show the Ollama start command, or stop a plugin-managed model pull. Default: `status`. |

## Safety Model

Staging is an in-memory buffer edit. It is not a disk write.

`ChatAccept` and `ChatApply` check the target buffer's `changedtick`. If the buffer changed after staging, accept stops instead of overwriting newer edits.

`ChatReject` uses the same stale check. A fresh proposal is replaced with the saved original lines. Reject does not write the restored text to disk.

The source buffer becomes modified during staging. Autosave plugins, manual `:write`, or other editor commands can still write the proposal before acceptance. ChatForge does not block external writes.

There is no force-accept or force-reject command in v0.2.3. Review the diff and resolve stale buffers manually.

## Backend And Model Recovery

Ollama is the only backend in v0.2.3.

If Ollama is unreachable, ChatForge offers to show the `ollama serve` command or ignore the error. `:ChatBackend start` also shows the command. It does not start an Ollama server.

If the selected model is missing, ChatForge can run `ollama pull <model>` as a Neovim job, show the command only, or ignore the error. `:ChatBackend stop` can stop a plugin-managed pull. It cannot stop an Ollama server started outside ChatForge.

`:ChatBackend status` reports tracked server and model-pull state. Since v0.2.3 does not start the server itself, server status normally reads `not-managed` even when Ollama is reachable.

## Configuration

All fields are optional. These are the v0.2.3 defaults:

```lua
require("chatforge").setup({
  default_model = "llama3",
  ollama_url = "http://localhost:11434",
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
| `default_model` | Initial Ollama model for each new source-buffer session. |
| `ollama_url` | Base URL used for `/api/chat` and `/api/tags`. |
| `max_output_tokens` | Ollama `num_predict` value. Takes precedence over `max_tokens`. |
| `max_tokens` | Legacy fallback for `num_predict` when `max_output_tokens` is absent. |
| `context_tokens` | Ollama `num_ctx` value. Separate from the 160-line automatic context cap. |
| `temperature` | Ollama sampling temperature. |
| `highlights.diff.incoming` | Highlight group applied to proposed lines. |
| `debug` | Show `[chatforge]` dispatch, request, parser, and backend notifications. |
| `system_prompt` | System message prepended to every request. Set to an empty string to omit it. |

Unknown fields are retained by the config merge but are not used by v0.2.3.

## Health Check

```vim
:checkhealth chatforge
```

The health check reports:

- Neovim 0.10 support
- `curl` availability
- whether `setup()` ran
- writable state directory status
- Ollama `/api/tags` reachability
- default model presence in the returned model list
- render-markdown.nvim detection
- dressing.nvim detection

The writable state directory check is diagnostic. ChatForge v0.2.3 keeps chat sessions in memory and does not persist them there.

## Testing

From the repository root:

```sh
nvim --headless -n -i NONE -u tests/minimal_init.lua -l tests/run.lua
```

The suite needs Neovim 0.10 or newer. It does not need Ollama or external Lua test libraries.

## Troubleshooting

### `Ollama unreachable`

Start Ollama in a terminal:

```sh
ollama serve
```

Check `ollama_url`, then run `:checkhealth chatforge`.

### Model Not Found

```sh
ollama pull llama3
```

Replace `llama3` with the model shown by `:ChatModel` or your configuration.

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

- Ollama is the only backend.
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
- The parser recognizes triple-backtick fences only when the opening fence ends with a newline.
- ChatForge defines no global keymaps.

Full editor help is available at `:help chatforge`.
