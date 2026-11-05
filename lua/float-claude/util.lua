local M = {}

M.diff = vim.text and vim.text.diff or vim.diff -- vim.diff is deprecated since Neovim 0.11

---Echo an error as one line: truncated to fit, so it never asks to press Enter.
function M.error(msg)
  local text = "float-claude: " .. msg:match("[^\n]*")
  if vim.fn.strdisplaywidth(text) > vim.v.echospace then
    text = vim.fn.strcharpart(text, 0, vim.v.echospace - 1) .. "…"
  end
  vim.api.nvim_echo({ { text, "ErrorMsg" } }, true, {})
end

---The diagnostics of `buf` (those on lines `first`..`last` when given), in
---line order, each as "- line 4: warning: message (source)".
function M.diagnostics(buf, first, last)
  local diags = vim.tbl_filter(function(d)
    return not first or (d.lnum + 1 <= last and (d.end_lnum or d.lnum) + 1 >= first)
  end, vim.diagnostic.get(buf))
  table.sort(diags, function(a, b)
    return a.lnum < b.lnum
  end)
  return vim.tbl_map(function(d)
    local severity = ({ "error", "warning", "info", "hint" })[d.severity] or "info"
    local source = d.source and " (" .. d.source .. ")" or ""
    return string.format("- line %d: %s: %s%s", d.lnum + 1, severity, (d.message:gsub("%s*\n%s*", " ")), source)
  end, diags)
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
