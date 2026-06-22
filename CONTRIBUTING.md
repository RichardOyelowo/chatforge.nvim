# Contributing

## Local setup

Requirements:

- Neovim 0.10 or newer
- `curl`
- Ollama for manual backend testing

Clone the repository and run the headless suite:

```sh
nvim --headless -n -i NONE -u tests/minimal_init.lua -l tests/run.lua
```

For manual testing, add the repository root to `runtimepath`, call `require("chatforge").setup()`, open a source file, and run `:Chat`.

## Pull requests

- Keep changes focused.
- Add a regression test for behavior changes.
- Do not introduce global keymaps.
- Preserve live-buffer staging and explicit review.
- Run `:checkhealth chatforge` when changing backend or setup behavior.
- Update `doc/chatforge.txt` and the README when commands or configuration change.

## Commit messages

Use a short imperative subject that describes one logical change. Keep formatting-only work separate from behavior changes.

## Reporting security issues

Do not open a public issue for a vulnerability that could expose files, credentials, or execute commands unexpectedly. Contact the maintainer privately through the repository owner's GitHub profile.
