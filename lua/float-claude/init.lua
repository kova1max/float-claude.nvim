local M = {}

local config = {
  -- Visual (and Normal: current line) mode mapping that opens the popup. `false` disables it.
  keymap = "<leader>ai",
  -- The Claude Code CLI; extra arguments may follow, e.g. { "claude", "--model", "sonnet" }.
  cmd = { "claude" },
  -- Popup width in columns (capped to the screen). Longer lines wrap onto more rows.
  width = 50,
  -- Where the popup opens: "top-right" (pinned to the editor's top-right corner)
  -- or "cursor" (1 row below and 3 columns right of the cursor).
  placement = "top-right",
  -- Show an edit as an inline diff in the buffer and apply it only once accepted.
  review_edits = false,
  -- With review_edits: the keys, in the popup, that accept or discard the diff.
  accept_key = "<leader>yy",
  discard_key = "<leader>nn",
  -- Keys in the popup (Insert and Normal mode): hide it, or go back to the code
  -- leaving it on screen. The conversation goes on; `keymap` comes back to it.
  hide_key = "<C-q>",
  unfocus_key = "<C-o>",
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
  chat.open({
    first = math.min(first, last),
    last = math.max(first, last),
    selected = selected,
    cmd = config.cmd,
    width = config.width,
    placement = config.placement,
    review_edits = config.review_edits,
    accept_key = config.accept_key,
    discard_key = config.discard_key,
    hide_key = config.hide_key,
    unfocus_key = config.unfocus_key,
  })
end

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
  if config.keymap then
    vim.keymap.set({ "n", "x" }, config.keymap, M.ask, { desc = "float-claude: ask Claude" })
  end
end

return M
