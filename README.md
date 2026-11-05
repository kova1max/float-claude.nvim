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
| `<Esc>` | Popup | Leave Insert mode, as anywhere in Vim |
| `q` | Popup, Normal mode | Close and end the conversation; a half-written edit is undone |
| `<C-q>` | Popup | Hide it; the conversation goes on in the background |
| `<C-o>` | Popup | Back to the code; the popup stays on screen |
| `<leader>yy` / `<leader>nn` | Popup, with `review_edits` | Accept / discard the edit shown as a diff |
| `<CR>` or a click / `K` | Conversation, on an underlined name | Jump to its definition in the code window / show its hover (see below) |
| `<leader>ae`, `<leader>af`, ... | Normal, Visual, popup | One-key actions: send a ready-made prompt (see [Actions](#actions)) |
| `@` | Popup | Mention a file, an open buffer or `@diagnostics` to send it too, with completion (see [Mentions](#mentions)) |
| `:FloatClaude` | Normal, Visual | Pick an action, open or hide the popup, or switch its theme, model or effort from a list |
| `:FloatClaudeModel`, `:FloatClaudeEffort` | Anywhere | Switch the open chat's model or effort (see [Model and effort](#model-and-effort)) |
| `<leader>an` / `<leader>ap`, `<leader>al` | Normal | Show the next / previous open chat, or pick one from a list (see [Several chats](#several-chats)) |
| `<leader>aH` | Normal | Reopen a saved chat, also after restarting Neovim (see [History](#history)) |

Every key above is a setup option (see [Configuration](#configuration)).

The popup has a fixed width (see `width` below) and grows downwards with the conversation; a longer prompt or answer wraps onto more rows, never scrolling sideways.

The conversation scrolls like a chat: once it no longer fits, each new question moves to the top of the popup and the answer streams in below it, following the newest line. Scroll back and the view stays put while the answer streams and while you type the next prompt; scroll down again to follow. The history is read-only. While a reply streams, the cursor sits in the conversation, so Normal-mode motions scroll it too; `q` closes. With `mouse` off (as with hardtime.nvim), most terminals send the wheel as arrow keys, so the wheel still scrolls.

### Hiding and leaving the popup

The popup does not have to be in the way, and does not have to go away:

- `<C-q>` hides it and puts you back in the code. The conversation goes on: an answer keeps streaming and an edit keeps writing while it is hidden.
- `<C-o>` (or leaving it any other way: another window, a split, another file) puts you back in the code with the popup still on screen, on top of whatever is shown there. It stays where it opened (top-right, or at the cursor it opened at) and answers keep streaming into it.

`<leader>ai` in Normal mode brings you back into it, showing it first if hidden, with the same conversation and scroll position. A new Visual selection with `<leader>ai` starts another chat, and the open one waits hidden (see [Several chats](#several-chats)). `q` in the popup (Normal mode; `<Esc>` first if you are typing) or `:q` in it closes it and ends the conversation. Prefer the popup to go away on its own? See `close_after_edit` and `close_on_leave` below. Files never open inside the popup; `:e` there is refused.

### Actions

One key sends a ready-made prompt: the popup opens and the prompt goes out right away, as if you had typed it.

| Key | Action | Prompt |
|---|---|---|
| `<leader>ae` | explain | Explain what this code does. |
| `<leader>af` | fix | Fix the problems the diagnostics report in this code; with none listed, fix the bugs you find. |
| `<leader>at` | tests | Write unit tests for this code, ... as an answer with a code block; do not edit the code. |
| `<leader>ay` | types | Add type annotations to this code, ... Change nothing else. |
| `<leader>ad` | docstring | Add a doc comment to each function in this code, ... Change nothing else. |
| `<leader>as` | simplify | Simplify this code without changing what it does. |
| `<leader>ar` | reword | Reword this text so it reads clearly; keep its meaning and tone. (prose) |
| `<leader>ah` | shorten | Shorten this text; keep its meaning. (prose) |
| `<leader>ag` | grammar | Fix the spelling, grammar and punctuation of this text. Change nothing else. (prose) |

In Visual mode an action works on the selected lines. In Normal mode it picks the lines for you and highlights them, so you see what Claude got: for a code action, the function around the cursor (found with treesitter; without a parser, or outside a function, the current line); for a prose action, the paragraph around the cursor in a prose buffer, or the block of comment lines around it in code. In the popup an action is a follow-up about the same lines, and outside it an action always starts another chat (an open one waits hidden).

Prose works like code: the reply is an answer, or an edit that replaces the text in place (one `u`, or a diff with `review_edits`). Buffers whose filetype is in `prose_filetypes` (Markdown, commit messages, plain text) offer the prose actions instead of the code ones; in code, the prose actions work on comments (a selection of comment lines only). An action where it is not offered says so and does nothing.

Change an action's key or prompt, remove one, or add your own in `actions`; each action is merged on its own, so you only give what changes:

```lua
opts = {
  actions = {
    explain = { key = "<leader>aE" }, -- another key, same prompt
    simplify = false, -- no simplify action
    todo = { key = "<leader>ao", prompt = "List the TODOs in this code." },
    commit = { key = "<leader>ac", prompt = "Write a commit message for this diff.", filetypes = { "gitcommit" } },
  },
}
```

An action is `{ key, prompt }` (`key = false`: no mapping, still in `:FloatClaude`), plus `prose = true` to offer it for prose and comments instead of code, or `filetypes = { ... }` to offer it only in those filetypes: its key is then mapped only in buffers of those filetypes (and in the popup of a chat about one), and `:FloatClaude` lists it only there.

`:FloatClaude` lists the actions offered for the current buffer with their keys, plus opening the popup (or going back to the open one), hiding it, switching its theme, reopening a saved chat, with a chat open switching its model and effort, and with several open going to another, through `vim.ui.select` (so a picker plugin that replaces it, like telescope or snacks, shows it). From Visual mode (`:'<,'>FloatClaude`) the pick works on the selection; otherwise it does what its key does in Normal mode.

### Mentions

Type `@` in the prompt to send more than the selection with the message:

- `@diagnostics`: all diagnostics of the file, not only those in the selected lines;
- `@<buffer>`: an open buffer, by its path (or just its file name, when no other open buffer has it), with its text as it is now, unsaved changes included;
- `@<path>`: any other file, relative to the current directory (`:pwd`), read from disk.

```
  demo.lua · L2–6 · 5 lines
  ❯ does f match how @lua/api.lua calls it?
    + lua/api.lua (120 lines)
    Yes: `api.run` passes a list, as `f` expects.
```

The conversation lists what each message sent, under the question. A mention sends at most 500 lines (`mentions.max_lines`); a longer file or buffer sends its first 500 lines, and Claude is told the rest was not sent. A binary file is not sent. An `@` that names nothing (`@property`, `@nothing`) stays plain text, and so does one inside a word (`me@example.com`); punctuation right after a mention (`see @a.lua.`) is not part of it.

Typing `@` opens the built-in completion menu: `diagnostics`, the open buffers, then the files and directories in the current directory (a directory completes on to its files). It narrows as you type; `<C-n>` / `<C-p>` (or `<Down>` / `<Up>`) pick an item and `<CR>` takes it, while `<CR>` with nothing picked sends the prompt. No completion plugin is needed. On Neovim 0.10 the menu opens as you type only when your `completeopt` has `noselect` or `noinsert` (else press `<C-x><C-o>`); from 0.11 the popup sets its own. `mentions = false` turns mentions off.

### Model and effort

Each chat starts with the `model` and `effort` from setup (by default the CLI's own), shown at the end of the header:

```
  demo.lua · L2–6 · 5 lines · sonnet · high
```

`:FloatClaudeModel <model>` switches the open chat's model (`opus`, `sonnet`, `haiku`, `fable`, or any model name the CLI takes; with completion), and `:FloatClaudeEffort <level>` its effort (`low`, `medium`, `high`, `xhigh`, `max`). Without an argument, or from `:FloatClaude`, they offer a list. The switch applies from the next message and the conversation goes on: the running `claude` process is told to switch, so nothing restarts and nothing is lost. A model the CLI refuses shows an error and the chat keeps its model. The next chat starts with the setup values again. Without a `model` set, the header shows the model the CLI reports once the first reply starts.

### Several chats

A chat you hide keeps going, and opening the popup on a new selection (or running an action outside the popup) starts another chat instead of ending it: the one on screen is hidden, so up to `max_chats` (5) chats live side by side, one per selection. Each stays bound to its own lines, which it follows through your edits, and has its own conversation and `claude` process. One chat is on screen at a time; only its lines are highlighted. With more than one open, the header says which one it is:

```
  demo.lua · L11–13 · 3 lines · 2/3
```

- `<leader>an` / `<leader>ap` (`:FloatClaudeNext` / `:FloatClaudePrev`) show and focus the next / previous chat, wrapping around;
- `<leader>al` (`:FloatClaudeChats`) picks one from a list, which also says which ones are still answering or have a reply you have not seen;
- `<leader>ai` in Normal mode goes back to the chat shown last.

One chat edits a file at a time. While a chat's edit is still writing into a file, or its diff there waits for review, an edit another chat replies with is not applied: Claude's reply stays in that chat as text, with a note such as `chat 1/2 has an edit pending on this file - accept or discard it first`, and Claude is told with the next message. Ask again once the other edit is over.

`q` ends only the chat it is pressed in. Opening one more than `max_chats` ends the one used longest ago (it stays in the [history](#history)).

### History

Each chat about a file is saved once a reply ends: its file and lines, the conversation, Claude's edits, the model and effort, and the CLI's session id. `<leader>aH` (`:FloatClaudeHistory`, or `history` in `:FloatClaude`) lists the saved chats about the current file or any file under the current directory, latest first:

```
lua/demo.lua · L2–6 · 3h ago · what's the time complexity?
```

Picking one opens its file and reopens the chat on the same lines (kept within the file, which may have changed since), with the conversation as it was, also after restarting Neovim. The `claude` process resumes the chat's session (`claude --resume`), so Claude remembers it, and the next message sends the code as it is now. If the session cannot be resumed (e.g. you deleted it), the popup says so and the next message sends the conversation so far as text instead, so Claude still knows what was said. A chat that is still open is just shown.

Chats are saved under `stdpath("state")/float-claude` (e.g. `~/.local/state/nvim/float-claude`), one JSON file each; the latest 100 are kept, none older than 30 days (`history = { max = 100, days = 30 }`, either can be `false`). For the sessions to resume, the `claude` CLI saves them too, as it does for any session, so they also show in `claude --resume` in that directory. `history = false` saves nothing, and the CLI then saves no sessions either.

### Statusline

`require("float-claude").status()` returns a spinner while a hidden chat is answering, `●` when one has a reply you have not seen yet (until you show it), and `""` otherwise, so the statusline tells you when to come back. While a hidden chat answers, the plugin redraws the statuslines a few times a second for the spinner; otherwise it redraws only when the status changes. With [lualine](https://github.com/nvim-lualine/lualine.nvim):

```lua
sections = {
  lualine_x = { function() return require("float-claude").status() end, "filetype" },
}
```

Or in a plain `statusline`: `vim.o.statusline = "%f %= %{v:lua.require'float-claude'.status()} "`. The icons are the `status` option.

### Code in answers

Answers put names from the code in `inline code` and snippets in fenced code blocks. The popup shows them without the backticks and fences: inline code on a slightly lighter background, and both syntax-highlighted with treesitter in the file's language (or the language a fence names). Without a treesitter parser for the language the code stays plain; Neovim ships parsers for Lua, Vim script, C, Markdown and a few more, and others (JavaScript, TypeScript, ...) come from e.g. [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter). A code line too long for the popup is cut onto the next row.

With an LSP server attached to the file, names in the code (inline code and code blocks) that the server knows are underlined: the definition at the name's occurrence in the file (in the selected lines first), or else a workspace symbol of that name. They are looked up in the background, so answers never wait for the server; a name shows underlined once found. In the conversation (`<C-w>w` from the prompt, or a click), `<CR>` or a click on an underlined name jumps to its definition in the code window, with the popup staying on screen, and `K` shows the server's hover for it. Names the server does not know stay plain, and without LSP nothing is underlined.

### Reviewing edits

With `review_edits = true`, an edit is not applied straight away. It shows as an inline diff in the buffer: the removed lines turn red and the new lines stream in as green virtual lines (without syntax highlighting) under them. The buffer stays untouched and locked until you decide in the popup:

- `<leader>yy` accepts: the new lines are written, and one `u` brings back the original.
- `<leader>nn` discards: the buffer is exactly as before, and Claude is told with your next message.

The popup stays open either way, so you can keep asking. Hiding or leaving the popup keeps the diff waiting; closing the popup before deciding discards the edit.

### What Claude sees

Claude gets the file name and filetype, the selected lines, up to 40 lines around them (`context_lines`), and the diagnostics in the selected lines (errors, warnings, ... from LSP or a linter, with their line, severity, message and source; `diagnostics = false` leaves them out), plus whatever the message mentions with `@`. Each follow-up sends the diagnostics as they are then, so after an edit Claude sees whether the errors went away. Every follow-up sends the selected lines again as they are at that moment, and the lines around them too unless they are unchanged since the last message, so Claude always works on the current code: the selection follows its applied edits, your own changes to the lines, and lines added or removed above them, and there is no need to select again. It runs with no tools, MCP servers, hooks or settings files, so it only reads what the popup sends (and, for a [reopened](#history) chat, its own saved session).

Claude also remembers what it changed. Each follow-up starts with a short record of what happened since its last reply, as diffs rather than copies of the code:

- its edit: applied (with the diff), accepted in review (with the diff), or discarded;
- your own changes near the selection, as a separate diff (changes elsewhere in the file are only counted);
- the numbered list of its edits applied so far.

So "what did you change?" gets its edits apart from yours, and "undo your second change" reverts just that one on top of the current code.

Because no settings files are loaded, your Claude Code hooks, `CLAUDE.md` files and `settings.json` are not used. Auth must come from your normal `claude` login or from environment variables such as `ANTHROPIC_API_KEY` or `CLAUDE_CODE_USE_BEDROCK` set in the shell Neovim runs in; provider settings or an `apiKeyHelper` in `settings.json` are not read.

### Your own instructions

To tell Claude something in every chat ("answer in Ukrainian", "prefer early returns"), use the `prompt` option: a string, or a function that gets `{ buf, file, filetype }` and returns one (or `nil`), so it can depend on the language or the project:

```lua
opts = {
  prompt = function(ctx)
    if ctx.filetype == "go" then
      return "Wrap errors with fmt.Errorf and %w."
    end
  end,
}
```

A project can add its own too, once you opt in: with `project_prompt = ".float-claude.md"` (or another file name), that file in the file's directory or any directory above it (the nearest one wins) is added after `prompt`. It is off by default because a cloned repository can bring such a file: it can steer the replies and edits you get in that project (Claude still has no tools there, and edits show in the buffer, one `u` away, or as a diff with `review_edits`).

Both come after the built-in instructions, and the reply format (an edit or an answer) always wins over them.

### Themes

The popup follows your colorscheme by default (`theme = "auto"`): its text and background come from your floating windows' colors (or your editor background, a little lighter or darker, so the borderless popup stands out), the `❯` from `Function`, the dimmed text from `Comment` and `LineNr`, and the diff colors from `DiffAdd` and `DiffDelete`. It follows a `:colorscheme` change too.

Or give the popup a look of its own, whatever the colorscheme: `theme` can be one of `night-owl`, `dracula`, `tokyonight`, `catppuccin` (mocha), `gruvbox` (dark), `nord`, `onedark`, `rose-pine`, or `float-claude` (the plugin's original look: near-black with a cyan `❯`). A theme colors the popup only: its background, text, prompt, header and the code in answers (a preset's own syntax colors; with `auto` and `float-claude` your colorscheme's), plus the selection and diff lines in the code. The rest of Neovim keeps its colorscheme.

`:FloatClaudeTheme <name>` (with completion) switches it for the session, an open popup included; put the one you like in `theme` to keep it.

`colors` sets single colors on top of any theme, `auto` included:

```lua
opts = {
  theme = "tokyonight",
  colors = { bg = "#000000", prompt = "#ff9e64" },
}
```

| Key | Used for |
|---|---|
| `bg`, `fg` | popup background, typed text and answers |
| `prompt` | the `❯` |
| `history` | sent questions, spinners, `refactoring…`, edit notes |
| `header` | the file and lines header |
| `code` | inline code background in answers (default: `bg`, a little towards `fg`) |
| `selection` | the selected lines while the popup or an edit is active (default: `Visual`) |
| `added`, `removed` | new lines of an edit and of a review diff, removed lines of a review diff |
| `comment`, `keyword`, `string`, `number`, `func`, `type`, `constant`, `operator`, `property` | code in answers |

The popup's colors are the highlight groups `FloatClaudeNormal`, `FloatClaudePrompt`, `FloatClaudeHistory`, `FloatClaudeHeader`, `FloatClaudeCode`, `FloatClaudeSelection`, `FloatClaudeAdded`, `FloatClaudeRemoved` and `FloatClaudeLink` (underlined names); the plugin sets them from the theme, so change them through `theme` and `colors`.

## Configuration

Every option, with its default (`opts` for lazy.nvim, or `require("float-claude").setup({...})`). Any key can be `false` to leave it unmapped. A table option (like `cursor_offset`) is replaced as a whole, so give all of its fields; `actions` is the exception, merged action by action.

```lua
{
  keymap = "<leader>ai", -- Visual + Normal mode: ask about the selection / back to the popup; false to map require("float-claude").ask yourself
  cmd = { "claude" }, -- the CLI, with extra arguments if you like
  model = false, -- each chat's model to start with: "opus", "sonnet", "haiku", "fable" or a model name; false: the CLI's default
  effort = false, -- each chat's effort to start with: "low", "medium", "high", "xhigh" or "max"; false: the CLI's default
  mentions = { max_lines = 500 }, -- @ mentions in the prompt, each sending at most max_lines lines; false: off
  prompt = false, -- your instructions for every chat: a string, or function(ctx) returning one (see above)
  project_prompt = false, -- e.g. ".float-claude.md": that file, from the file's directory or above, is added
  context_lines = 40, -- unselected lines sent above and below the selection
  diagnostics = true, -- send the diagnostics in the selected lines too
  actions = { -- one-key actions, see Actions; each is merged on its own, false removes one
    explain = { key = "<leader>ae", prompt = "Explain what this code does." },
    fix = { key = "<leader>af", prompt = "Fix the problems the diagnostics report in this code; with none listed, fix the bugs you find." },
    tests = { key = "<leader>at", prompt = "Write unit tests for this code, in the project's test style, as an answer with a code block; do not edit the code." },
    types = { key = "<leader>ay", prompt = "Add type annotations to this code, in the language's usual way. Change nothing else." },
    docstring = { key = "<leader>ad", prompt = "Add a doc comment to each function in this code, in the language's usual style. Change nothing else." },
    simplify = { key = "<leader>as", prompt = "Simplify this code without changing what it does." },
    reword = { key = "<leader>ar", prompt = "Reword this text so it reads clearly; keep its meaning and tone.", prose = true },
    shorten = { key = "<leader>ah", prompt = "Shorten this text; keep its meaning.", prose = true },
    grammar = { key = "<leader>ag", prompt = "Fix the spelling, grammar and punctuation of this text. Change nothing else.", prose = true },
  },
  prose_filetypes = { "markdown", "gitcommit", "text" }, -- buffers offering the prose actions instead of the code ones
  max_chats = 5, -- chats open at once (one shown, the others hidden); one more ends the one used longest ago
  history = { max = 100, days = 30 }, -- save chats to reopen them (see History); either can be false; false: off
  status = { spinner = { "◐", "◓", "◑", "◒" }, unread = "●" }, -- what status() shows, see Statusline
  width = 50, -- popup width in columns, capped to the screen; longer lines wrap
  max_height = false, -- popup height cap in rows; false: as tall as the screen allows
  placement = "top-right", -- or "cursor": next to the cursor
  top_right_offset = { row = 0, col = 0 }, -- "top-right": rows from the top, columns from the right edge
  cursor_offset = { row = 1, col = 3 }, -- "cursor": rows below, columns right of the cursor (above it when there is no room below)
  theme = "auto", -- or a preset, see Themes
  colors = {}, -- single colors over the theme, see Themes
  review_edits = false, -- true: show an edit as a diff and apply it only once accepted
  close_after_edit = false, -- true: close the popup (ending the chat) once an edit is applied
  close_on_leave = false, -- true: leaving the popup (other than with unfocus_key or a jump) closes it
  -- Normal mode keys for the open chats:
  next_chat_key = "<leader>an", -- show the next chat
  prev_chat_key = "<leader>ap", -- show the previous one
  chats_key = "<leader>al", -- pick an open chat from a list
  history_key = "<leader>aH", -- pick a saved chat to reopen
  -- Keys in the popup:
  submit_key = "<CR>", -- send the prompt (Insert and Normal mode)
  newline_keys = { "<S-CR>", "<C-j>" }, -- Insert mode: a new line in the prompt
  close_key = "q", -- Normal mode: close the popup and end the chat
  hide_key = "<C-q>", -- hide it; the chat goes on, keymap brings it back
  unfocus_key = "<C-o>", -- back to the code, the popup stays on screen
  accept_key = "<leader>yy", -- with review_edits: accept the diff (Normal mode)
  discard_key = "<leader>nn", -- with review_edits: discard it
  scroll_up_key = "<C-u>", -- scroll the conversation half a screen
  scroll_down_key = "<C-d>",
  line_up_key = "<Up>", -- scroll it a line (in a multi-line prompt, first move between its lines)
  line_down_key = "<Down>",
  jump_key = "<CR>", -- in the conversation, on an underlined name: go to its definition
  hover_key = "K", -- in the conversation, on an underlined name: show its hover
  insert_keys = { "i", "a" }, -- in the conversation: back to the prompt
}
```

Changed an option? Restart Neovim for it to apply.

## Development

Run the tests (headless; a fake CLI stands in for Claude and a fake LSP server for a language server, so no network or account is needed):

```sh
nvim --clean --headless -l tests/run.lua
```

`ONLY=<text>` runs just the tests whose name contains the text.
