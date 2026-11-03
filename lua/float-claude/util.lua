local M = {}

---Echo an error as one line: truncated to fit, so it never asks to press Enter.
function M.error(msg)
  local text = "float-claude: " .. msg:match("[^\n]*")
  if vim.fn.strdisplaywidth(text) > vim.v.echospace then
    text = vim.fn.strcharpart(text, 0, vim.v.echospace - 1) .. "…"
  end
  vim.api.nvim_echo({ { text, "ErrorMsg" } }, true, {})
end

return M
