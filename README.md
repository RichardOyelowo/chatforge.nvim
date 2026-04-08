<div align=center>

# <img src="images/chatforge_logo.svg">

  ![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey.svg)
  ![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-green.svg)

</div>

A Neovim AI dev assistant — persistent chat per buffer, Ollama backend, code block actions, per-buffer model switching. No keymaps set for you.

Most AI plugins do one thing — a floating prompt, a one-shot completion, or a diff you didn't ask for. This one gives you a proper chat window that stays open, remembers your conversation per buffer, understands when you're asking it to edit a file vs just explain something, and drops action buttons on every code block so you can apply or preview it without leaving Neovim.

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Commands](#commands)
- [Setting Up Keymaps](#setting-up-keymaps)
- [How the Chat Works](#how-the-chat-works)
- [Action Buttons](#action-buttons)
- [Floating Code Preview](#floating-code-preview)
- [Model Picker](#model-picker)
- [Dispatcher — Natural Language Routing](#dispatcher--natural-language-routing)
- [Data Flow](#data-flow)
- [Project Layout](#project-layout)
- [Adding Another Backend](#adding-another-backend)
- [Troubleshooting](#troubleshooting)
- [Known Limitations](#known-limitations)

---

## Requirements

- Neovim ≥ 0.10 — uses `vim.system`, `vim.ui.input`, `vim.ui.select`
- [Ollama](https://ollama.com) running locally (default `localhost:11434`)
- `curl` in `$PATH`

Optional but worth having:
- [render-markdown.nvim](https://github.com/RichardOyelowo/render-markdown.nvim) — the chat buffer is `filetype=markdown` so it just works
- [dressing.nvim](https://github.com/stevearc/dressing.nvim) — nicer input/select UI

---

## Installation

### lazy.nvim

```lua
{
  "RichardOyelowo/chatforge.nvim",

  -- Lazy-load on all available Chat commands
  cmd = {
    "Chat",
    "ChatSend",
    "ChatSetModel",
    "ChatReset",
    "ChatActivate",
    "ChatApply",
    "ChatDiff",
    "ChatYank",
    "ChatPreview",
    "ChatReject",
  },

  -- Optional: you can also lazy-load on events instead
  -- event = "VeryLazy",

  config = function()
    require("chatforge").setup({
      ollama_url = "http://localhost:11434",
      default_model = "qwen3-coder:480b-cloud",   -- matches your defaults
      max_tokens = 4096,
      temperature = 0.2,
      debug = false,

      -- You can customize this if you want different behavior
      system_prompt = "You are a helpful coding assistant embedded in Neovim. "
        .. "Be concise. Use fenced code blocks with language tags for all code. "
        .. "When suggesting file changes, clearly state the filename.",
    })
  end,
}
```

Drop the folder anywhere in your `runtimepath`. No dependencies outside of Neovim itself and curl.

---

## Configuration

All fields are optional. These are the defaults:

```lua
require("chatforge").setup({
  default_model = "llama3",
  ollama_url    = "http://localhost:11434",
  max_tokens    = 4096,
  temperature   = 0.2,
  debug         = false,
  system_prompt = "You are a helpful coding assistant embedded in Neovim. "
               .. "Be concise. Use fenced code blocks with language tags for all code.",
})
```

`debug = true` will emit `[chatforge]` notifications for every significant step — request sent, response received, blocks parsed, etc. Useful when something isn't working and you want to trace where it breaks.

---

## Commands

These are everything the plugin exposes. No keymaps are set. Wire them up however fits your config.

| Command | What it does |
|---|---|
| `:Chat` | Open or focus the chat window |
| `:ChatSend <message>` | Send a message without the input prompt |
| `:ChatSetModel [name]` | Set the model for this buffer. Leave name out to get the picker |
| `:ChatReset` | Clear the conversation and reopen |
| `:ChatActivate` | Activate the action button the cursor is sitting on |
| `:ChatApply [N]` | Apply code block N to the current buffer. Defaults to 1 |
| `:ChatDiff [N]` | Diff block N against the current buffer in a new tab |
| `:ChatYank [N]` | Yank block N to the unnamed register |
| `:ChatPreview [N]` | Open block N in a floating window with syntax highlighting |
| `:ChatReject` | Discard all pending blocks |

Block numbers come from the response — if the model returned two code blocks, they're #1 and #2 in order. The action buttons in the chat buffer show the numbers explicitly.

---

## Setting Up Keymaps

The plugin intentionally sets nothing. Here's a starting point you can adjust:

```lua
-- open chat
vim.keymap.set("n", "<leader>ac", "<cmd>Chat<cr>",         { desc = "AI Chat" })
vim.keymap.set("n", "<leader>am", "<cmd>ChatSetModel<cr>", { desc = "AI model picker" })

-- inside the chat buffer
vim.api.nvim_create_autocmd("BufEnter", {
  pattern = "AI Chat",
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    local o = { buffer = buf, silent = true }

    -- send a new message
    vim.keymap.set("n", "<CR>", "<cmd>ChatActivate<cr>", o)
    vim.keymap.set("n", "s",    function()
      require("chatforge.ui.chat").send_message(
        -- pass the source bufnr you want context from
        vim.fn.bufnr("#")
      )
    end, o)

    vim.keymap.set("n", "q",  "<cmd>quit<cr>",          o)
    vim.keymap.set("n", "R",  "<cmd>ChatReset<cr>",      o)
    vim.keymap.set("n", "m",  "<cmd>ChatSetModel<cr>",   o)

    -- block actions
    vim.keymap.set("n", "<leader>ca", "<cmd>ChatApply<cr>",   o)
    vim.keymap.set("n", "<leader>cd", "<cmd>ChatDiff<cr>",    o)
    vim.keymap.set("n", "<leader>cy", "<cmd>ChatYank<cr>",    o)
    vim.keymap.set("n", "<leader>cp", "<cmd>ChatPreview<cr>", o)
    vim.keymap.set("n", "<leader>cr", "<cmd>ChatReject<cr>",  o)
  end,
})
```

The `BufEnter AI Chat` autocmd is the cleanest way to scope keymaps to just the chat buffer without polluting everything else.

---

## How the Chat Works

`:Chat` opens a vertical split on the right. The buffer is `filetype=markdown`, read-only except when the plugin is writing into it.

The conversation is stored per source buffer — whichever buffer you had open when you ran `:Chat`. If you open a chat from `init.lua` and another from `main.go`, they each get their own history and model selection.

Sending a message:
1. Your input goes through the dispatcher, which classifies what you're asking and optionally injects context (like the current buffer contents for `fix` or `explain` requests)
2. The full conversation history plus your message gets sent to Ollama
3. The response is parsed into text and code block segments
4. Everything renders in the chat buffer with action buttons below each code block

The window stays open across sends. History accumulates until you run `:ChatReset`.

---

## Action Buttons

Every code block in a response gets a button row directly below it:

```
  [ Accept #1 ]  [ Diff #1 ]  [ Yank #1 ]  [ Preview #1 ]  ->  path/to/file.lua
```

The file path hint after `->` is guessed from the surrounding text — if the model said "edit `utils/buffer.lua`" before the code block, that path shows up there. When you accept, you get a prompt pre-filled with that path and can override it.

Move your cursor anywhere on the button line and run `:ChatActivate` (or whatever you mapped it to). The plugin detects which button your cursor is nearest to and runs it.

Or skip the buttons entirely and use the commands directly: `:ChatApply 2`, `:ChatDiff 2`, etc.

---

## Floating Code Preview

`:ChatPreview [N]` opens the code block in a floating window centred on your screen. The window uses the correct filetype so syntax highlighting just works — a `lua` block opens with `filetype=lua`, `python` with `filetype=python`, and so on.

A small action bar sits below the main float showing the available keys:

```
  a Apply   d Diff   y Yank   q Close   (block #1)
```

- `a` applies to the current buffer and closes the float
- `d` opens a diff tab and closes the float
- `y` yanks to the unnamed register — float stays open so you can keep reading
- `q` or `<Esc>` closes without doing anything

The float auto-closes if focus moves away from it.

---

## Model Picker

`:ChatSetModel` without an argument fetches the list of models from Ollama's `/api/tags` endpoint and opens a `vim.ui.select` picker. The currently active model for that buffer is marked with ✓.

If Ollama isn't running or the request fails, it falls back to showing just the configured default model so you're not stuck.

Model selection is per buffer. You can have one buffer using `codestral` and another using `llama3` at the same time — state is stored separately for each source buffer.

`:ChatSetModel codestral` sets it directly without opening the picker.

---

## Dispatcher — Natural Language Routing

The dispatcher reads your input before sending it to the model and enriches the prompt based on what it thinks you're doing.

| Input starts with | What happens |
|---|---|
| `explain …` | Current buffer content + filename injected into the prompt |
| `fix …` / `refactor …` | Same — buffer content injected automatically |
| `edit file <path>` | Classified as a file edit, context injected |
| `create file <path>` | Classified as file creation |
| `delete file <path>` | Classified as file deletion |
| Anything else | Sent as-is |

You don't have to use these prefixes — they just trigger automatic context injection so you don't have to paste your code into the chat manually. If you type `fix this function` while `utils/buffer.lua` is your source buffer, the dispatcher appends the full file content to the prompt before it goes to the model.

---

## Data Flow

```
:Chat  →  chat.open(src_bufnr)
              │
         vim.ui.input  ←  user types message
              │
         dispatcher.dispatch(input, src_bufnr)
              │  enriches prompt, classifies action
              │
         state.append_message(src_bufnr, "user", enriched_prompt)
              │
         client.complete(src_bufnr, history, on_done)
              │
         backends.ollama.ask(url, model, messages, on_done)
              │   async via vim.system + curl
              │
         parser.parse(raw_response)
              │  → [{type="text"}, {type="code"}, {type="action"}, …]
              │
         state.pending_blocks  ←  code segments stored here
              │
         render.append_segments(segments)
              │  → text + code fences + [ Accept ] [ Diff ] … buttons
              │
         :ChatActivate / :ChatApply / :ChatPreview / …
              │
         actions.apply_to_current / diff_with_current / yank / reject_all
              OR
         floating.preview(idx)  →  popup with syntax highlighting
```

---

## Project Layout

```
lua/chatforge/
  init.lua              entry point — setup(), all command registrations
  config.lua            defaults + M.setup()

  ui/
    chat.lua            chat buffer, send flow, cursor button activation
    render.lua          writes markdown + action buttons into the buffer
    model_picker.lua    fetches Ollama models, opens vim.ui.select
    floating.lua        syntax-highlighted code block popup + action bar

  core/
    state.lua           per-buffer { model, history } + pending_blocks
    dispatcher.lua      classifies + enriches user input before sending
    parser.lua          splits AI response into text / code / action segments
    actions.lua         apply / diff / yank / reject_all

  api/
    client.lua          unified send — picks backend, prepends system prompt
    backends.lua        Ollama HTTP implementation via curl
    prompts.lua         optional prompt templates (fix, explain, refactor, …)

  utils/
    buffer.lua          get_content, get_visual_selection, get_name, get_filetype
    window.lua          open_float / close_float helpers
    logger.lua          log / warn / err — gated behind config.debug
```

---

## Adding Another Backend

`api/backends.lua` has a registry table. Add an entry following the same contract:

```lua
-- in api/backends.lua

local openai = {}

function openai.ask(base_url, model, messages, on_done)
  -- base_url comes from config, model from per-buffer state
  -- call on_done(text, nil) on success or on_done(nil, err_string) on failure
  -- must be async — use vim.system
end

local registry = {
  ollama = ollama,
  openai = openai,  -- add here
}
```

Then in `api/client.lua`, change `backends.get("ollama")` to read from `config.values.backend` or from per-buffer state — whichever makes sense for how you want to select it. The rest of the stack doesn't need to change.

---

## Troubleshooting

**`Ollama unreachable`**
Check that `ollama serve` is running. Verify `ollama_url` in your config matches where it's listening.

**Model not found**
Run `ollama pull <model>` in your terminal first. `:ChatSetModel` with the picker shows only models Ollama currently has downloaded.

**Empty response**
Check Ollama's own logs. Sometimes a model just times out or returns nothing — try a smaller/faster model to rule out resource issues.

**`No action button on this line`**
The cursor is on a text line, not a button line. Move it to the `[ Accept #1 ] [ Diff #1 ] …` row and try again.

**`No pending blocks`**
The last response had no fenced code blocks — the model responded with plain text only. The block commands have nothing to act on.

**Debug mode**
Set `debug = true` in `setup()`. Every significant step logs a `[chatforge]` notification — request sent, curl result, JSON decoded, blocks parsed, etc.

---

## Known Limitations

- No streaming — response appears all at once when the request finishes
- Refresh token rotation, revocation, blocklists — none of that exists here, this is a chat plugin
- Only Ollama backend right now — OpenAI or any other is a couple dozen lines in `backends.lua` if you want to add it
- Pending blocks only track the most recent response — if you send a second message before acting on the first, those blocks are replaced
- No multi-buffer file edits in a single response — the dispatcher handles one source buffer at a time

---

<div align= center>

  **Built by Richard for the love of development.**

</p>
