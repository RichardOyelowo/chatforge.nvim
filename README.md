# <img src="images/chatforge_logo.svg">

Local-first, staged coding chat for Neovim.

## What it does

chatforge.nvim keeps an Ollama conversation attached to each source buffer. Edit requests stream into the live Neovim buffer as a marked proposal. You can preview, diff, accept, or reject that proposal before it reaches disk.

Version 0.2.0 supports one Ollama backend and one staged buffer change at a time.

## Why it exists

Copying code between an editor and a separate chat hides where a proposed edit will land. ChatForge puts the proposal in the source buffer first. The original text stays available until you accept or reject the change.

Context is explicit. Use `@file` or `@dir` when the model needs source or project structure. ChatForge does not scan the whole project for every request.

## Requirements

- Neovim 0.10 or newer
- `curl` in `$PATH`
- [Ollama](https://ollama.com) for the v0.2.0 backend
- An installed Ollama model, such as `llama3`

Optional:

- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) can render the Markdown chat and input buffers.
- [dressing.nvim](https://github.com/stevearc/dressing.nvim) is used for ChatForge prompts when available. Native `vim.ui.input` and `vim.ui.select` remain the fallback.

Neither optional plugin is required. Both are reported by `:checkhealth chatforge`.

## Installation

### lazy.nvim

```lua
{
  "RichardOyelowo/chatforge.nvim",
  version = "v0.2.0",
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

Start Ollama and download the configured model:

```sh
ollama serve
```

In another terminal:

```sh
ollama pull llama3
```

Then check the editor setup:

```vim
:checkhealth chatforge
```

Use `event = "VeryLazy"` instead of `cmd` if you want the plugin loaded before its first command.

## Quick start

Open a source file, then run:

```vim
:Chat
```

Type a normal question in the bottom message pane. Press `<Enter>` to send it. Use `<C-j>` when the message needs a newline.

Try a read-only question:

```vim
:ChatSend review @file for error-handling gaps
```

Try a staged edit. Edit-shaped prompts write into the live source buffer as a proposal:

```vim
:ChatSend fix the error handling in this file
```

Use `:ChatEdit` when you want to force a live staged edit regardless of wording:

```vim
:ChatEdit add input validation to this file
```

The first fenced code block starts replacing the source buffer while Ollama responds. Review the marked lines, then choose one action:

```vim
:ChatDiff
:ChatAccept
```

Use `:ChatReject` instead if the proposal is wrong.

## Normal chat workflow

`:Chat` opens a 65-column vertical split on the right. The chat occupies the upper window. An eight-line message pane sits below it. Both buffers use the `markdown` filetype and are temporary `nofile` buffers.

The source buffer that opened the chat owns the conversation and model choice. Open ChatForge from another source buffer to switch sessions. Session state lives only in the current Neovim process.

There are three ways to send a message:

- Run `:ChatSend some text` to send text directly. Edit-shaped text stages live in the source buffer.
- Run `:ChatEdit some text` to force a live staged source-buffer edit.
- Run `:ChatSend` to focus the message pane. If the pane already has focus, the same command sends its contents.
- Select source lines and run `:'<,'>ChatSend`. ChatForge asks for replacement code and stages the result back into that range.

The message pane has buffer-local behavior:

- `<Enter>` sends. If completion is visible, it accepts the selected completion item first.
- `<C-j>` inserts a newline.
- Typing an `@` reference opens context completion.
- Completion uses buffer-local menu settings so it does not change the user's global completion UI.

ChatForge sets no global keymaps.

Edit-shaped requests stage code. ChatForge treats prompts that ask to add, change, update, remove, rewrite, generate, implement, create, improve, or make code as live edit requests. Plain review and explanation prompts keep fenced code in the chat as example code. Before another message can be sent, accept or reject any existing staged change.

## Context references

Context references are case-insensitive. `@FILE`, `@File`, and `@file` have the same meaning.

### Bare `@file`

`@file` injects the current live Neovim buffer. Unsaved edits are included. The token does not consume nearby prose.

```vim
:ChatSend can you review @file fully?
```

The word `fully?` remains part of the question. It is not treated as a path.

### Braced `@{file path}`

Use braces for a named file:

```vim
:ChatSend compare @{file lua/old.lua} with @{file lua/new.lua}
:ChatSend review @{file docs/design notes.md}
```

Named files are read from disk. Relative paths use Neovim's current working directory. Absolute paths, `~`, and environment variables use `vim.fn.expand()`.

ChatForge also accepts `{afile path}` as a compatibility shorthand for named file context.

`@{file .}`, `@{file /}`, and an empty file reference mean the current live buffer. This special `/` meaning applies only to file context. It does not mean the filesystem root.

A missing or unreadable file becomes an inline HTML context error in the model prompt. The request still runs.

### Bare `@dir`

`@dir` injects a sorted, one-level listing of Neovim's current working directory:

```vim
:ChatSend use @dir to explain the project layout
```

Each entry is marked `d` for directory or `f` for every other entry type.

### Braced `@{dir path}`

Use braces for a named directory:

```vim
:ChatSend inspect @{dir lua/chatforge} and suggest a starting point
:ChatSend inspect @{dir source files}
```

Named directory paths are always resolved under Neovim's current working directory. A leading slash is stripped, so `@{dir /lua}` means `<cwd>/lua`. Absolute directory paths, `~`, and environment variable expansion are not supported in v0.2.0.

Directory context is not recursive. One read returns at most 64 entries. Use another `@{dir path}` reference for a nested directory.

### Completion behavior

The message pane scans the current working directory recursively and offers up to 80 items. Bare `@file` and `@dir` come first. Directory suggestions come before file suggestions. Paths inside `.git` are skipped.

The completion list is cached for the current working directory. New files may not appear until the working directory changes or Neovim restarts. You can always type a reference manually.

Injected source is protected from a second context pass. An `@{file ...}` string inside source code remains literal and cannot pull in another file.

### Related file context

When a message shares file context with `@file`, `@{file path}`, or `{afile path}`, ChatForge remembers the most recent files in the current Neovim session. Later prompts that clearly ask about file relationships, such as whether CSS matches HTML, include those recent files as related context. `:ChatReset` clears this remembered context.

## Intent and automatic context

ChatForge classifies the start of each message. Matching is case-insensitive.

| Message wording | Result |
|---|---|
| `explain ` | Add current-buffer context. Do not stage code. |
| `review `, `how `, `what `, `why ` | Chat/review mode. Do not stage code unless `:ChatEdit` is used. |
| `fix ` | Add current-buffer context. Treat the first code block as an edit. |
| `refactor ` | Add current-buffer context. Treat the first code block as an edit. |
| `add`, `change`, `update`, `remove`, `rewrite`, `generate`, `implement`, `create`, `improve`, `make` | Add current-buffer context. Treat the first code block as an edit. |
| `edit file <path>` | Add context from the current source buffer. Stage into `<path>`. |
| `create file <path>` | Stage into `<path>` without automatic source context. |
| `delete file <path>` | Classify the request, but do not delete or stage a file. |
| `:ChatEdit <prompt>` | Force the prompt to stage live in the source buffer. |
| Anything else | Send as normal chat unless it came from a visual selection. |

Automatic current-buffer context is capped at 160 lines. For a larger buffer, ChatForge sends a 160-line window around the visible cursor. Bare `@file` sends the full live buffer and bypasses that cap.

Target paths after `edit file` and `create file` stop at whitespace. Paths with spaces cannot be staging targets in v0.2.0. A braced file reference adds context only. It does not select the staging target.

## Live staging and disk writes

Staging is an in-memory buffer edit. It is not a disk write.

For edit-shaped prompts, `:ChatEdit`, `edit file`, `create file`, and visual-selection requests, ChatForge asks Ollama for a streamed response. When the first fenced code block starts, ChatForge removes the target text and inserts complete response lines into the target buffer. Proposed lines use `ChatforgeProposedChange` and an `AI` end-of-line marker.

The target depends on the request:

- Edit-shaped prompts replace the full current buffer.
- A visual selection replaces only its original line range.
- `edit file <path>` and `create file <path>` open or create that path in the source window, then replace the full buffer.

The source buffer becomes modified during staging. Other editor commands, autosave plugins, or `:write` can write that proposal before acceptance. ChatForge does not block external writes.

`:ChatAccept` and `:ChatApply N` check the staged buffer's `changedtick`. If it still matches, they write the buffer with `:write`, remove the proposal marks, and clear that staged item. Unnamed buffers and special buffers cannot be written, so acceptance only clears the staged state for those buffers.

`:ChatReject` also checks `changedtick`. A fresh proposal is replaced with the saved original lines. Reject does not write the restored text to disk. The buffer remains modified if its disk state differs.

## Preview, Diff, Accept, and Reject

### Preview

```vim
:ChatPreview
:ChatPreview 2
```

Preview opens the selected response block in a centered floating window. It does not compare text.

The chat output prints the exact command for each block, such as `Preview this block: :ChatPreview 2` and `Review this block: :ChatDiff 2`. Users do not have to guess the block number.

Inside the preview:

- `q` or `<Esc>` closes it.
- `a` closes it and accepts the first staged change.
- `r` closes it and rejects all fresh staged changes.

### Diff

```vim
:ChatDiff
:ChatDiff 2
:ChatReviewDiff
```

For a staged block, Diff opens a new tab comparing the saved original snapshot with the proposal. For an unstaged block, it compares the current target buffer with the response block. `:ChatReviewDiff` selects the first staged block. Close the review with `:tabclose`.

### Accept

```vim
:ChatAccept
:ChatApply 2
```

`:ChatAccept` accepts the lowest-numbered staged block. `:ChatApply N` accepts a specific staged block. Acceptance writes named file buffers to disk.

### Reject

```vim
:ChatReject
```

Reject restores the original snapshot for every fresh staged block. It clears pending blocks when nothing stale remains.

### Navigation

```vim
:ChatPrevChange
:ChatNextChange
```

These commands use the first staged block. Prev jumps to its first line. Next jumps to its last proposed line.

## Stale changedtick protection

ChatForge records the target buffer's `changedtick` after staging finishes. Any later buffer change makes the proposal stale. This includes a manual edit, formatting, undo, reload, or another plugin changing the buffer.

Accept and Reject stop when the proposal is stale. They do not overwrite the newer buffer state. The staged metadata stays available. `:ChatDiff N` still compares the original snapshot with the proposal, not the newer user-edited buffer.

There is no force-accept or force-reject command in v0.2.0. Review the diff, then resolve the buffer manually if it became stale.

## Commands

| Command | Behavior |
|---|---|
| `:Chat` | Open the chat for the current source buffer, or focus the existing chat input. |
| `:ChatSend [message]` | Send text. With no text, focus the input or send its current contents. A range sends a selected-line rewrite. |
| `:ChatEdit <message>` | Force a live staged edit in the source buffer. A range rewrites only the selected lines. |
| `:ChatModel [model]` | Set the model for the current source buffer. With no argument, open `vim.ui.input`. |
| `:ChatReset` | Ignore the current request result, reject fresh staged work, clear all staged metadata and this buffer's history, then redraw the chat. |
| `:ChatPreview [N]` | Open response block N in a float. Default: 1. |
| `:ChatDiff [N]` | Open a diff for response block N. Default: 1. |
| `:ChatReviewDiff` | Diff the first staged block. |
| `:ChatAccept` | Accept and write the first staged block. |
| `:ChatApply [N]` | Accept and write staged block N. Default: 1. |
| `:ChatReject` | Restore original lines for all non-stale staged blocks. |
| `:ChatNextChange` | Jump to the end of the first staged block. |
| `:ChatPrevChange` | Jump to the start of the first staged block. |
| `:ChatBackend [status\|start\|stop]` | Inspect backend helper state, show the Ollama start command, or stop a plugin-managed model pull. Default: `status`. |

## Backend and model recovery

If Ollama is unreachable, ChatForge opens a `vim.ui.select` prompt with two choices: show `ollama serve`, or ignore the error. `:ChatBackend start` also shows the command. It does not start an Ollama server in v0.2.0.

If Ollama reports a missing model, ChatForge can start `ollama pull <model>` as a Neovim job, show the command only, or ignore it. `:ChatBackend stop` can stop that plugin-managed pull. It cannot stop an Ollama server started in another terminal.

`:ChatBackend status` reports whether ChatForge tracks a server job and whether a model pull is running. Since v0.2.0 does not start the server itself, server status normally reads `not-managed` even when Ollama is reachable.

## Configuration

All fields are optional. These are the v0.2.0 defaults:

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
| `ollama_url` | Base URL used for `/api/chat` and the health check's `/api/tags`. |
| `max_output_tokens` | Ollama `num_predict` value. This takes precedence over `max_tokens`. |
| `max_tokens` | Legacy fallback for `num_predict` when `max_output_tokens` is absent. The default `max_output_tokens` normally makes this field inactive. |
| `context_tokens` | Ollama `num_ctx` value. This is the model context window request, not the 160-line automatic context cap. |
| `temperature` | Ollama sampling temperature. |
| `highlights.diff.incoming` | Highlight group applied to proposed lines. |
| `debug` | Show `[chatforge]` request, dispatch, parser, and backend notifications. |
| `system_prompt` | System message prepended to every request. Set it to an empty string to omit the system message. |

Unknown fields are retained by the config merge but are not used by v0.2.0.

## Health check

Run:

```vim
:checkhealth chatforge
```

The check reports:

- whether Neovim 0.10 or newer is running
- whether `curl` is executable
- whether `setup()` ran, otherwise defaults are checked
- whether `stdpath("state")` exists and is writable
- whether `<ollama_url>/api/tags` answers within two seconds
- whether `default_model` appears in the returned model list
- whether render-markdown.nvim and dressing.nvim are on `runtimepath`

The writable state directory is a setup diagnostic. ChatForge v0.2.0 keeps chat sessions in memory and does not persist them there.

## Testing

From the repository root, run:

```sh
nvim --headless -n -i NONE -u tests/minimal_init.lua -l tests/run.lua
```

The suite needs Neovim 0.10 or newer. It does not need Ollama or external Lua test libraries. GitHub Actions runs the same command on pushes to `main` and on pull requests.

## Troubleshooting

### `Ollama unreachable`

Start Ollama in a terminal:

```sh
ollama serve
```

Check `ollama_url`, then run `:checkhealth chatforge`. `:ChatBackend start` only displays the terminal command.

### Model not found

Run:

```sh
ollama pull llama3
```

Replace `llama3` with the model shown by `:ChatModel` or your configuration. The recovery prompt can run the pull from Neovim.

### A proposal will not Accept or Reject

The target buffer changed after staging. ChatForge leaves the newer buffer untouched. Run `:ChatDiff N`, then resolve the file manually. There is no force action.

### `That block is an example, not a staged implementation`

The request was treated as normal chat, or a non-streamed full-file response was too short to look like a replacement. Start the message with `fix` or `refactor`, use `edit file <path>`, or send a visual selection when you want an edit.

### `Implementation #N is not staged`

Only a stageable response block can be accepted. ChatForge stages the first eligible block. Later blocks may remain previewable without becoming staged.

### Context points at the wrong place

Run `:pwd`. Bare `@dir`, named file paths, named directory paths, and completion all depend on Neovim's current working directory. Bare `@file` always uses the live source buffer.

### Context completion is missing a new path

Completion is cached by working directory and capped at 80 entries. Type the braced reference manually, change directories, or restart Neovim.

### Debugging a request

Set `debug = true`, reproduce the problem, and inspect `:messages`. Debug output includes dispatch decisions, request details, parser counts, and backend errors.

## Known limitations

- Ollama is the only backend.
- Chat and model state are not persisted across Neovim sessions.
- One request can be active at a time across the plugin.
- Reset ignores an active request's eventual result but does not stop its underlying `curl` job.
- One staged edit must be accepted or rejected before another message is sent.
- Edit streaming uses the first fenced code block as replacement text. Explanatory fenced blocks can produce a bad proposal.
- Whole-buffer edit requests expect a full-file response. A partial snippet can replace the whole buffer.
- Multi-file patches are not parsed or applied as one transaction.
- `delete file` does not delete files.
- Staging changes the live buffer. Autosave or a manual write can put an unaccepted proposal on disk.
- Reject restores the buffer in memory but does not write the restoration to disk.
- Stale proposals have no force action and Diff does not include the newer user-edited state.
- Named staging target paths cannot contain spaces.
- Named directory context stays under the current working directory and returns at most 64 entries from one level.
- Context and completion do not apply ignore files such as `.gitignore`; completion only filters paths under `.git`.
- Completion is capped at 80 items and cached until the working directory changes.
- The parser recognizes triple-backtick fences only when the opening fence ends with a newline.
- ChatForge does not set global keymaps.

Full editor help is available at `:help chatforge`.
