# float-claude.nvim
Neovim: select code, press a key, and ask Claude in a small popup right under the selection

Select some lines, press `<leader>ai`, type a prompt in the borderless popup that opens under the selection, and press Enter. Claude decides what the prompt needs:

- **Edit**: "use a hash map, one pass". The selected lines are rewritten in place, streaming in line by line with the new lines briefly highlighted. The popup stays open with a note that the edit was applied, so you can keep going ("also rename x"); a follow-up edit works on the lines as they are now. Each edit is one `u` in the buffer.
- **Answer**: "what's the time complexity?". The answer streams into the popup and you can keep asking follow-ups ("can it be O(n)?"). A follow-up can also ask for an edit of the selection.

Pure Lua, no plugin dependencies. Replies come from the [Claude Code](https://claude.com/claude-code) CLI running headless in the background (one `claude -p` process per popup, so follow-ups continue the same conversation); no API key and no HTTP code in the plugin.

## Requirements

- Neovim >= 0.10
- The `claude` CLI on your `PATH`, logged in (run `claude` once and sign in)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "kova1max/float-claude.nvim",
  opts = {},
}
```

## Usage

| Key | Where | Action |
|---|---|---|
| `<leader>ai` | Visual | Ask about the selected lines (any Visual mode; whole lines are used) |
| `<leader>ai` | Normal | Ask about the current line |
| `<CR>` | Popup | Send the prompt |
| `<S-CR>` or `<C-j>` | Popup | New line in the prompt (use `<C-j>` if your terminal does not send Shift-Enter) |
| `<C-u>` / `<C-d>`, mouse wheel, `<Up>` / `<Down>` | Popup | Scroll the conversation (in a multi-line prompt the arrows first move between its lines) |
| `<Esc>` | Popup, or while an edit streams | Close and cancel the request; a half-written edit is undone |

The popup has a fixed width (see `width` below); a longer prompt or answer wraps onto more rows, never scrolling sideways.

The conversation scrolls like a chat: once it no longer fits, each new question moves to the top of the popup and the answer streams in below it, following the newest line. Scroll back and the view stays put while the answer streams and while you type the next prompt; scroll down again to follow. The history is read-only. While a reply streams, the cursor sits in the conversation, so Normal-mode motions scroll it too; `<Esc>` or `q` closes. With `mouse` off (as with hardtime.nvim), most terminals send the wheel as arrow keys, so the wheel still scrolls.

Leaving the popup (focusing another window) closes it and cancels an answer; an edit that is already streaming finishes in the buffer.

Claude gets the file name and filetype, the selected lines, and up to 40 lines around them. It runs with no tools, MCP servers, hooks or settings files, so it only reads what the popup sends.

Because no settings files are loaded, your Claude Code hooks, `CLAUDE.md` files and `settings.json` are not used. Auth must come from your normal `claude` login or from environment variables such as `ANTHROPIC_API_KEY` or `CLAUDE_CODE_USE_BEDROCK` set in the shell Neovim runs in; provider settings or an `apiKeyHelper` in `settings.json` are not read.

## Configuration

```lua
require("float-claude").setup({
  keymap = "<leader>ai", -- Visual + Normal mode; false to skip it and map require("float-claude").ask yourself
  cmd = { "claude" }, -- the CLI, with extra arguments if you like, e.g. { "claude", "--model", "sonnet" }
  width = 60, -- popup width in columns, capped to the screen; longer lines wrap
})
```

Colors come from highlight groups defined with `default = true`, so a colorscheme or your config can override them:

| Group | Default | Used for |
|---|---|---|
| `FloatClaudeNormal` | `fg = #e6e6e6, bg = #1c1c1f` | popup, typed text, answers |
| `FloatClaudePrompt` | `fg = #3fb5c9` | the `❯` |
| `FloatClaudeHistory` | `fg = #8a8a8a` | sent questions, spinners, `refactoring…`, edit notes |
| `FloatClaudeSelection` | links to `Visual` | the selection while the popup or an edit is active |
| `FloatClaudeAdded` | `bg = #12301f` | freshly written lines |

## Development

Run the tests (headless; a fake CLI stands in for Claude, so no network or account is needed):

```sh
nvim --clean --headless -l tests/run.lua
```
