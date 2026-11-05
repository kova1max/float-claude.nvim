-- One-key actions: which ones a buffer offers, and which lines an action works
-- on without a selection.
local M = {}

-- The root of the buffer's syntax tree; nil without a treesitter parser.
local function root(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  return parser:parse()[1]:root()
end

local function line_at(buf, lnum)
  return vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
end

-- Whether line `lnum` is a comment: its first non-blank character is in a
-- treesitter comment node or, without a parser, it starts with the
-- 'commentstring' leader. nil for a blank line.
local function is_comment(buf, tree, lnum)
  local line = line_at(buf, lnum)
  local col = line:find("%S")
  if not col then
    return nil
  end
  if tree then
    local node = tree:named_descendant_for_range(lnum - 1, col - 1, lnum - 1, col - 1)
    return node ~= nil and node:type():find("comment") ~= nil
  end
  local leader = vim.trim(vim.bo[buf].commentstring:match("^(.-)%%s") or "")
  return leader ~= "" and vim.startswith(line:sub(col), leader)
end

---Whether lines `first`..`last` are comments (blank lines aside), at least one.
function M.comments(buf, first, last)
  local tree, any = root(buf), false
  for lnum = first, last do
    local c = is_comment(buf, tree, lnum)
    if c == false then
      return false
    end
    any = any or c
  end
  return any
end

local function prose_buffer(buf, opts)
  return vim.tbl_contains(opts.prose_filetypes, vim.bo[buf].filetype)
end

---Whether `action` is offered for lines `first`..`last` of `buf`: one with
---`filetypes` only there; a prose action in prose_filetypes buffers and on
---comments; any other in the rest.
function M.available(action, buf, first, last, opts)
  if action.filetypes then
    return vim.tbl_contains(action.filetypes, vim.bo[buf].filetype)
  end
  if prose_buffer(buf, opts) then
    return action.prose == true
  end
  return not action.prose or M.comments(buf, first, last)
end

-- The run of lines around `lnum` that pass `test` (just `lnum` if it does not).
local function block(buf, lnum, test)
  if not test(lnum) then
    return lnum, lnum
  end
  local first, last, count = lnum, lnum, vim.api.nvim_buf_line_count(buf)
  while first > 1 and test(first - 1) do
    first = first - 1
  end
  while last < count and test(last + 1) do
    last = last + 1
  end
  return first, last
end

-- Node types that are a function or method definition, not a call of or a
-- part of one.
local function is_function(type)
  return (type:find("function") or type:find("method"))
    and not (type:find("call") or type:find("name") or type:find("index") or type:find("param")
      or type:find("argument") or type:find("type") or type:find("signature") or type:find("body"))
end

---The lines an action works on without a selection, around line `lnum`: for
---a prose action the paragraph (in a prose_filetypes buffer) or the comment
---block, for any other the innermost function (through treesitter); else the line.
---@return integer first
---@return integer last
function M.range(action, buf, lnum, opts)
  local tree = root(buf)
  if action.prose then
    if prose_buffer(buf, opts) then
      return block(buf, lnum, function(l)
        return line_at(buf, l):find("%S") ~= nil
      end)
    end
    return block(buf, lnum, function(l)
      return is_comment(buf, tree, l) == true
    end)
  end
  local col = (line_at(buf, lnum):find("%S") or 1) - 1
  local node = tree and tree:named_descendant_for_range(lnum - 1, col, lnum - 1, col)
  while node do
    if is_function(node:type()) then
      local first, _, last, end_col = node:range()
      return first + 1, end_col == 0 and last > first and last or last + 1
    end
    node = node:parent()
  end
  return lnum, lnum
end

return M
