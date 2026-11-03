# float-claude.nvim
Neovim: ask Claude Code about the file or selection from a cursor-anchored popup

Press the keymap, type a prompt in a small borderless popup that opens right at the cursor, and press Enter.
The prompt goes to the Claude Code session that [claudecode.nvim](https://github.com/coder/claudecode.nvim) runs, with context attached:

- **Normal mode**: the current file (as an absolute `@/path/to/file` mention), so "summarize this file" or "refactor this file" work.
- **Visual mode**: the selected lines (`@/path/to/file#L3-7`), so "refactor this part" works.

Answers show up in the Claude pane. Edits come back through claudecode.nvim's usual diff accept/deny flow (`:ClaudeCodeDiffAccept` / `:ClaudeCodeDiffDeny`).
If Claude Code is not running yet, float-claude starts it and sends the prompt once it has connected.

## Requirements

- Neovim >= 0.10
- [coder/claudecode.nvim](https://github.com/coder/claudecode.nvim) from `main` with `:ClaudeCodeSendText` (added after v0.3.0), using its `snacks` or `native` terminal provider.
  float-claude types the prompt into the Claude terminal inside Neovim, so the `external` and `none` providers are not supported.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kova1max/float-claude.nvim",
  dependencies = { "coder/claudecode.nvim" },
  opts = {},
}
```

## Usage

| Key | Where | Action |
|---|---|---|
| `<leader>ai` | Normal, Visual | Open the popup at the cursor |
| `<CR>` | Popup | Send the prompt |
| `<S-CR>` or `<C-j>` | Popup, Insert mode | New line (use `<C-j>` if your terminal does not send Shift-Enter) |
| `<Esc>` | Popup, Insert mode | Back to Normal mode |
| `<Esc>` or `q` | Popup, Normal mode | Cancel |

An empty prompt sends nothing. Claude reads the file from disk, so save unsaved changes first (float-claude warns when the buffer is modified).
claudecode.nvim's `focus_after_send` decides whether focus moves to the Claude pane after sending.

## Configuration

```lua
require("float-claude").setup({
  keymap = "<leader>ai", -- normal + visual mode; false to skip it and map require("float-claude").ask yourself
})
```

The popup colors come from two highlight groups, defined with `default = true` so a colorscheme or your config can override them:

| Group | Default |
|---|---|
| `FloatClaudeNormal` | `fg = #e6e6e6, bg = #1c1c1f` (popup and typed text) |
| `FloatClaudePrompt` | `fg = #3fb5c9, bg = #1c1c1f` (the `❯`) |

The popup alone is plain Lua with no dependencies:

```lua
require("float-claude.input").open({
  default = "",       -- initial text, may contain "\n" when multiline
  multiline = false,  -- true: Shift-Enter / Ctrl-J add lines; Enter always submits
  on_submit = function(text) end, -- the typed lines joined with "\n"
  on_cancel = function() end,     -- optional
})
```

## Development

Run the tests (headless, no network, no plugins needed):

```sh
nvim --clean --headless -l tests/run.lua
```
