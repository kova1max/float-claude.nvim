local M = {}

---Echo an error as one line: truncated to fit, so it never asks to press Enter.
function M.error(msg)
  local text = "float-claude: " .. msg:match("[^\n]*")
  if vim.fn.strdisplaywidth(text) > vim.v.echospace then
    text = vim.fn.strcharpart(text, 0, vim.v.echospace - 1) .. "…"
  end
  vim.api.nvim_echo({ { text, "ErrorMsg" } }, true, {})
end

---`line` with its tabs replaced by the spaces they show as.
function M.expand_tabs(line, tabstop)
  local i = line:find("\t", 1, true)
  while i do
    local before = line:sub(1, i - 1)
    line = before .. string.rep(" ", tabstop - vim.fn.strdisplaywidth(before) % tabstop) .. line:sub(i + 1)
    i = line:find("\t", i, true)
  end
  return line
end

return M
