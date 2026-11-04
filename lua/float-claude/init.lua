local M = {}

local config = {
  -- Visual (and Normal: current line) mode mapping that opens the popup. `false` disables it.
  keymap = "<leader>ai",
  -- The Claude Code CLI; extra arguments may follow, e.g. { "claude", "--model", "sonnet" }.
  cmd = { "claude" },
  -- Popup width in columns (capped to the screen). Longer lines wrap onto more rows.
  width = 60,
}

---Open the popup for the selected lines (Visual mode) or the current line (Normal mode).
function M.ask()
  local first, last = vim.fn.line("v"), vim.fn.line(".")
  if vim.fn.mode():match("^[vV\22]") then
    vim.cmd("normal! \27")
  else
    first = last
  end
  require("float-claude.chat").open({ first = math.min(first, last), last = math.max(first, last), cmd = config.cmd, width = config.width })
end

function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
  if config.keymap then
    vim.keymap.set({ "n", "x" }, config.keymap, M.ask, { desc = "float-claude: ask Claude" })
  end
end

return M
