# float-claude.nvim
Neovim: select code, press a key, and ask Claude in a small popup pinned to the top-right corner

Select some lines, press `<leader>ai`, type a prompt in the borderless popup, and press Enter. The popup is pinned to the editor's top-right corner (or opens next to the cursor, see `placement`); the selection stays highlighted while it is open. Claude decides what the prompt needs:

- **Edit**: "use a hash map, one pass". The selected lines are rewritten in place, streaming in line by line with the new lines briefly highlighted. The popup stays open with a note that the edit was applied, so you can keep going ("also rename x"); a follow-up edit works on the lines as they are now. Each edit is one `u` in the buffer.
- **Answer**: "what's the time complexity?". The answer streams into the popup and you can keep asking follow-ups ("can it be O(n)?"). Code in it is syntax-highlighted, and with LSP the names in it jump to their definitions (see [Code in answers](#code-in-answers)). A follow-up can also ask for an edit of the selection.

```
  test.js · L7–13 · 7 lines
  ❯ what's the time complexity?
    O(n²): the nested loops compare every pair.
    Space is O(1).

  ❯ █
```

The header names the file and the lines Claude sees (`test.js · L7` for a single line). Past questions are dimmed, replies are indented under them, and a fresh `❯` prompt waits at the bottom.

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
| `<leader>ai` | Normal | Back to the open popup (shown again if hidden); with none open, ask about the current line (not highlighted) |
| `<CR>` | Popup | Send the prompt |
| `<S-CR>` or `<C-j>` | Popup | New line in the prompt (use `<C-j>` if your terminal does not send Shift-Enter) |
| `<C-u>` / `<C-d>`, mouse wheel, `<Up>` / `<Down>` | Popup | Scroll the conversation (in a multi-line prompt the arrows first move between its lines) |
| `<Esc>` | Popup | Close and end the conversation; a half-written edit is undone |
| `<C-q>` | Popup | Hide it; the conversation goes on in the background |
| `<C-o>` | Popup | Back to the code; the popup stays on screen |
| `<leader>yy` / `<leader>nn` | Popup, with `review_edits` | Accept / discard the edit shown as a diff |
| `<CR>` or a click / `K` | Conversation, on an underlined name | Jump to its definition in the code window / show its hover (see below) |

The popup has a fixed width (see `width` below) and grows downwards with the conversation; a longer prompt or answer wraps onto more rows, never scrolling sideways.

The conversation scrolls like a chat: once it no longer fits, each new question moves to the top of the popup and the answer streams in below it, following the newest line. Scroll back and the view stays put while the answer streams and while you type the next prompt; scroll down again to follow. The history is read-only. While a reply streams, the cursor sits in the conversation, so Normal-mode motions scroll it too; `<Esc>` or `q` closes. With `mouse` off (as with hardtime.nvim), most terminals send the wheel as arrow keys, so the wheel still scrolls.

### Hiding and leaving the popup

The popup does not have to be in the way, and does not have to go away:

- `<C-q>` hides it and puts you back in the code. The conversation goes on: an answer keeps streaming and an edit keeps writing while it is hidden.
- `<C-o>` (or leaving it any other way: another window, a split, another file) puts you back in the code with the popup still on screen, on top of whatever is shown there. It stays where it opened (top-right, or at the cursor it opened at) and answers keep streaming into it.

`<leader>ai` in Normal mode brings you back into it, showing it first if hidden, with the same conversation and scroll position. A new Visual selection with `<leader>ai` starts a fresh chat in its place. `<Esc>` in the popup (or `:q` in it) closes it and ends the conversation. Files never open inside the popup; `:e` there is refused.

### Code in answers

Answers put names from the code in `inline code` and snippets in fenced code blocks. The popup shows them without the backticks and fences: inline code on a slightly lighter background, and both syntax-highlighted with treesitter in the file's language (or the language a fence names). Without a treesitter parser for the language the code stays plain; Neovim ships parsers for Lua, Vim script, C, Markdown and a few more, and others (JavaScript, TypeScript, ...) come from e.g. [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter). A code line too long for the popup is cut onto the next row.

With an LSP server attached to the file, names in the code (inline code and code blocks) that the server knows are underlined: the definition at the name's occurrence in the file (in the selected lines first), or else a workspace symbol of that name. They are looked up in the background, so answers never wait for the server; a name shows underlined once found. In the conversation (`<C-w>w` from the prompt, or a click), `<CR>` or a click on an underlined name jumps to its definition in the code window, with the popup staying on screen, and `K` shows the server's hover for it. Names the server does not know stay plain, and without LSP nothing is underlined.

### Reviewing edits

With `review_edits = true`, an edit is not applied straight away. It shows as an inline diff in the buffer: the removed lines turn red and the new lines stream in as green virtual lines (without syntax highlighting) under them. The buffer stays untouched and locked until you decide in the popup:

- `<leader>yy` accepts: the new lines are written, and one `u` brings back the original.
- `<leader>nn` discards: the buffer is exactly as before, and Claude is told with your next message.

The popup stays open either way, so you can keep asking. Hiding or leaving the popup keeps the diff waiting; closing the popup before deciding discards the edit.

### What Claude sees

Claude gets the file name and filetype, the selected lines, and up to 40 lines around them. Every follow-up sends the selected lines again as they are at that moment, and the lines around them too unless they are unchanged since the last message, so Claude always works on the current code: the selection follows its applied edits, your own changes to the lines, and lines added or removed above them, and there is no need to select again. It runs with no tools, MCP servers, hooks or settings files, so it only reads what the popup sends.

Claude also remembers what it changed. Each follow-up starts with a short record of what happened since its last reply, as diffs rather than copies of the code:

- its edit: applied (with the diff), accepted in review (with the diff), or discarded;
- your own changes near the selection, as a separate diff (changes elsewhere in the file are only counted);
- the numbered list of its edits applied so far.

So "what did you change?" gets its edits apart from yours, and "undo your second change" reverts just that one on top of the current code.

Because no settings files are loaded, your Claude Code hooks, `CLAUDE.md` files and `settings.json` are not used. Auth must come from your normal `claude` login or from environment variables such as `ANTHROPIC_API_KEY` or `CLAUDE_CODE_USE_BEDROCK` set in the shell Neovim runs in; provider settings or an `apiKeyHelper` in `settings.json` are not read.

## Configuration

```lua
require("float-claude").setup({
  keymap = "<leader>ai", -- Visual + Normal mode; false to skip it and map require("float-claude").ask yourself
  cmd = { "claude" }, -- the CLI, with extra arguments if you like, e.g. { "claude", "--model", "sonnet" }
  width = 50, -- popup width in columns, capped to the screen; longer lines wrap
  placement = "top-right", -- or "cursor": the popup's top-left corner 1 row below and 3 columns right of the cursor
  review_edits = false, -- true: show an edit as a diff and apply it only once accepted
  accept_key = "<leader>yy", -- with review_edits: accept the diff (Normal mode, in the popup)
  discard_key = "<leader>nn", -- with review_edits: discard it
  hide_key = "<C-q>", -- in the popup (Insert and Normal mode): hide it, the conversation goes on
  unfocus_key = "<C-o>", -- in the popup: back to the code, the popup stays on screen
})
```

Colors come from highlight groups defined with `default = true`, so a colorscheme or your config can override them:

| Group | Default | Used for |
|---|---|---|
| `FloatClaudeNormal` | `fg = #e6e6e6, bg = #1c1c1f` | popup, typed text, answers |
| `FloatClaudePrompt` | `fg = #3fb5c9` | the `❯` |
| `FloatClaudeHistory` | `fg = #8a8a8a` | sent questions, spinners, `refactoring…`, edit notes |
| `FloatClaudeHeader` | `fg = #4e4e55` | the file and lines header |
| `FloatClaudeSelection` | links to `Visual` | the selected lines while the popup or an edit is active |
| `FloatClaudeAdded` | `bg = #12301f` | freshly written lines, added lines in a review diff |
| `FloatClaudeRemoved` | `bg = #3a1d22` | removed lines in a review diff |
| `FloatClaudeCode` | `bg = #2a2a2f` | inline code in answers |
| `FloatClaudeLink` | `underline = true` | names in answers that resolve through LSP |

## Development

Run the tests (headless; a fake CLI stands in for Claude and a fake LSP server for a language server, so no network or account is needed):

```sh
nvim --clean --headless -l tests/run.lua
```
