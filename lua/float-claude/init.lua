local M = {}

-- Every option, with its default. The README documents them.
local config = {
  -- Visual (and Normal: current line) mode mapping that opens the popup. `false` disables it.
  keymap = "<leader>ai",
  -- The Claude Code CLI; extra arguments may follow, e.g. { "claude", "--model", "sonnet" }.
  cmd = { "claude" },
  -- Your own instructions for Claude, added to the built-in ones in every chat:
  -- a string, or a function(ctx) returning one (ctx: buf, file, filetype).
  prompt = false,
  -- A file whose text is added too, found in the file's directory or above it,
  -- e.g. ".float-claude.md". Off by default: a cloned repository could steer Claude.
  project_prompt = false,
  -- Unselected lines sent above and below the selection.
  context_lines = 40,
  -- Popup width in columns (capped to the screen). Longer lines wrap onto more rows.
  width = 50,
  -- Popup height cap in rows; `false`: as tall as the screen allows.
  max_height = false,
  -- Where the popup opens: "top-right" (pinned to the editor's top-right corner)
  -- or "cursor" (next to the cursor).
  placement = "top-right",
  -- "top-right": rows from the top and columns from the right edge.
  top_right_offset = { row = 0, col = 0 },
  -- "cursor": rows below and columns right of the cursor (above it when there is no room below).
  cursor_offset = { row = 1, col = 3 },
  -- Popup colors: "auto" (from your colorscheme) or a preset, see require("float-claude.theme").presets.
  theme = "auto",
  -- Single colors over the theme: bg, fg, prompt, header, history, code, selection, added,
  -- removed, and for code in answers comment, keyword, string, number, func, type, constant,
  -- operator, property. E.g. { bg = "#000000" }.
  colors = {},
  -- Show an edit as an inline diff in the buffer and apply it only once accepted.
  review_edits = false,
  -- Close the popup (ending the chat) once an edit is applied.
  close_after_edit = false,
  -- Close the popup (ending the chat) when you leave it, other than with unfocus_key or a jump.
  close_on_leave = false,
  -- Keys in the popup. Any of them can be `false` to leave it unmapped.
  submit_key = "<CR>", -- send the prompt
  newline_keys = { "<S-CR>", "<C-j>" }, -- Insert mode: a new line in the prompt
  close_key = "q", -- Normal mode: close the popup and end the chat
  hide_key = "<C-q>", -- hide it; the chat goes on, `keymap` brings it back
  unfocus_key = "<C-o>", -- back to the code, the popup stays on screen
  accept_key = "<leader>yy", -- with review_edits: accept the diff
  discard_key = "<leader>nn", -- with review_edits: discard it
  scroll_up_key = "<C-u>", -- scroll the conversation half a screen
  scroll_down_key = "<C-d>",
  line_up_key = "<Up>", -- scroll it a line (in a multi-line prompt, first move between its lines)
  line_down_key = "<Down>",
  jump_key = "<CR>", -- in the conversation, on an underlined name: go to its definition
  hover_key = "K", -- in the conversation, on an underlined name: show its hover
  insert_keys = { "i", "a" }, -- in the conversation: back to the prompt
}

---Open the popup for the selected lines (Visual mode). In Normal mode, focus the
---open popup (showing it if hidden), or open one for the current line.
function M.ask()
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  local selected = vim.fn.mode():match("^[vV\22]") ~= nil
  if selected then
    vim.cmd("normal! \27")
  else
    first = last
  end
  local chat = require("float-claude.chat")
  -- A selection in the popup itself is not a new chat.
  if (not selected or vim.startswith(vim.bo.filetype, "float-claude")) and chat.focus() then
    return
  end
  chat.open(vim.tbl_extend("force", config, {
    first = math.min(first, last),
    last = math.max(first, last),
    selected = selected,
  }))
end

-- Color the popup with the configured theme, an open one too.
local function restyle()
  require("float-claude.chat").restyle(require("float-claude.theme").apply(config.theme, config.colors))
end

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
  if config.keymap then
    vim.keymap.set({ "n", "x" }, config.keymap, M.ask, { desc = "float-claude: ask Claude" })
  end
  restyle()
  -- A new colorscheme clears the groups, and "auto" follows it.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("float-claude", {}),
    callback = restyle,
  })
  vim.api.nvim_create_user_command("FloatClaudeTheme", function(cmd)
    if not vim.tbl_contains(require("float-claude.theme").names(), cmd.args) then
      return require("float-claude.util").error(string.format('unknown theme "%s"', cmd.args))
    end
    config.theme = cmd.args
    restyle()
  end, {
    nargs = 1,
    desc = "float-claude: set the popup's theme",
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, require("float-claude.theme").names())
    end,
  })
end

return M
