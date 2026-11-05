-- The parts of a buffer a chat is about. A range is whole lines, or a block
-- (Visual-block mode): a column range on each of some lines. It is tracked by
-- extmarks, so it follows the changes made since. Also the pending list:
-- ranges collected one by one, to ask about together.
--
-- A spec describes a range: { first, last } for lines, plus for a block
-- `from` and `to` (display columns, 1-based; `to = false` to each line's end)
-- or `rows` (each { lnum, scol, ecol }: the bytes [scol, ecol) of line lnum).
local M = {}

local CHAR = "[%z\1-\127\194-\244][\128-\191]*" -- one UTF-8 character

-- The bytes [scol, ecol) of `line` that display columns from..to (to = false:
-- to the end) cover, with any character partly in them.
local function cols(line, from, to)
  local scol, ecol, i = nil, nil, 1
  for char in line:gmatch(CHAR) do
    local start = vim.fn.strdisplaywidth(line:sub(1, i - 1)) + 1
    local stop = vim.fn.strdisplaywidth(line:sub(1, i - 1 + #char))
    if to and start > to then
      ecol = i - 1
      break
    end
    if not scol and stop >= from then
      scol = i - 1
    end
    i = i + #char
  end
  scol = scol or #line
  return scol, math.max(ecol or #line, scol)
end

-- The display columns of the character at `pos` (from getpos()), first and last.
local function cells(pos)
  local line = vim.fn.getline(pos[2])
  local before = line:sub(1, pos[3] - 1)
  local char = line:sub(pos[3]):match("^" .. CHAR) or ""
  local start = vim.fn.strdisplaywidth(before) + 1 + pos[4]
  return start, math.max(vim.fn.strdisplaywidth(before .. char) + pos[4], start)
end

-- The spec of the area between positions `a` and `b` (from getpos()), lines,
-- or a block when `mode` is Visual-block; `dollar`: to each line's end.
local function spec(a, b, mode, dollar)
  local s = { first = math.min(a[2], b[2]), last = math.max(a[2], b[2]) }
  if mode == "\22" then
    local a1, a2 = cells(a)
    local b1, b2 = cells(b)
    s.from, s.to = math.min(a1, b1), not dollar and math.max(a2, b2)
  end
  return s
end

local MAXCOL = vim.v.maxcol or 2147483647

---The Visual selection's spec, leaving Visual mode.
function M.visual()
  local s = spec(vim.fn.getpos("v"), vim.fn.getpos("."), vim.fn.mode(), vim.fn.getcurpos()[5] == MAXCOL)
  vim.cmd("normal! \27")
  return s
end

---The spec of lines first..last, from a command's range: a block when they
---are the lines of the last Visual selection and it was a block.
function M.lines(first, last)
  local a, b = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  if vim.fn.visualmode() == "\22" and first == math.min(a[2], b[2]) and last == math.max(a[2], b[2]) then
    return spec(a, b, "\22", math.max(a[3], b[3]) >= MAXCOL)
  end
  return { first = first, last = last }
end

-- The mark of lines first..last (mark `id` moved there, if given): gone
-- (invalid) once they are all deleted or replaced.
local function lines_mark(buf, ns, first, last, hl, id)
  return vim.api.nvim_buf_set_extmark(buf, ns, first - 1, 0, {
    id = id,
    end_row = last,
    end_col = 0,
    strict = false,
    invalidate = true,
    hl_group = hl,
    priority = 200,
  })
end

---Track the range `s` describes in `buf` with extmarks in `ns`, highlighted
---with `hl` when given. Returns the range: { marks, lines, block, from }
---(`lines`: for a block, a mark per row on its whole line).
function M.track(buf, ns, s, hl)
  local r = { marks = {}, lines = {}, block = s.from ~= nil or s.rows ~= nil, from = s.from }
  if not r.block then
    r.marks[1] = lines_mark(buf, ns, s.first, s.last, hl)
    return r
  end
  local rows = {}
  for i, lnum in ipairs(s.rows and vim.tbl_map(function(row)
    return row[1]
  end, s.rows) or vim.fn.range(s.first, s.last)) do
    local line = vim.fn.getbufline(buf, lnum)[1]
    if s.rows then -- kept within the line, which may have changed since
      local scol = math.min(s.rows[i][2], #line)
      table.insert(rows, { lnum, scol, math.min(math.max(s.rows[i][3], scol), #line) })
    else
      table.insert(rows, { lnum, cols(line, s.from, s.to) })
    end
  end
  for _, row in ipairs(rows) do
    -- Gravity so the text that replaces the part (or is typed at its edges) is in it.
    table.insert(r.marks, vim.api.nvim_buf_set_extmark(buf, ns, row[1] - 1, row[2], {
      end_row = row[1] - 1,
      end_col = row[3],
      right_gravity = false,
      end_right_gravity = true,
      hl_group = hl,
      priority = 200,
    }))
    -- Its line: gone (invalid) only once the line is deleted.
    table.insert(r.lines, vim.api.nvim_buf_set_extmark(buf, ns, row[1] - 1, 0, {
      end_row = row[1],
      end_col = 0,
      strict = false,
      invalidate = true,
    }))
  end
  return r
end

---Move range `r` of lines to lines first..last (the lines an edit put in
---their place), so that undoing the edit puts it back on the old lines.
function M.move(buf, ns, r, first, last, hl)
  lines_mark(buf, ns, first, last, hl, r.marks[1])
end

---Highlight range `r` with `hl`, or not (nil).
function M.highlight(buf, ns, r, hl)
  for _, id in ipairs(r.marks) do
    local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
    if m[1] and not m[3].invalid then
      vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], {
        id = id,
        end_row = m[3].end_row,
        end_col = m[3].end_col,
        strict = false,
        invalidate = m[3].invalidate,
        right_gravity = m[3].right_gravity,
        end_right_gravity = m[3].end_right_gravity,
        hl_group = hl,
        priority = 200,
      })
    end
  end
end

---Stop tracking range `r`.
function M.untrack(buf, ns, r)
  for _, id in ipairs(vim.list_extend(vim.list_slice(r.marks), r.lines)) do
    pcall(vim.api.nvim_buf_del_extmark, buf, ns, id)
  end
end

-- A mark of whole lines (from lines_mark or a block row's line) is gone once
-- invalid, or collapsed: Neovim 0.10.0 does not invalidate one spanning
-- several deleted lines.
local function gone(m)
  return m[3].invalid or (m[1] == m[3].end_row and m[2] == m[3].end_col)
end

---Where range `r` is now, as a spec { first, last, rows?, from?, deleted? }
---(rows for a block); nil if its marks are gone. Lines all deleted (or
---replaced): `deleted`, on the line that took their place (for a block, an
---empty row at its start); a block's rows whose lines were deleted are gone.
function M.read(buf, ns, r)
  local marks, any = {}, nil
  for k, id in ipairs(r.marks) do
    local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, { details = true })
    local line = r.lines[k] and vim.api.nvim_buf_get_extmark_by_id(buf, ns, r.lines[k], { details = true })
    any = any or (m[1] and m)
    if m[1] and not (m[3].invalid or not r.block and gone(m) or line and gone(line)) then
      table.insert(marks, m)
    end
  end
  if not any then
    return nil
  end
  if #marks == 0 then
    local lnum = math.min(any[1] + 1, vim.api.nvim_buf_line_count(buf))
    return { first = lnum, last = lnum, rows = r.block and { { lnum, 0, 0 } } or nil, from = r.from, deleted = true }
  end
  if not r.block then
    local row, end_row, end_col = marks[1][1], marks[1][3].end_row, marks[1][3].end_col
    return { first = row + 1, last = math.max(end_col == 0 and end_row > row and end_row or end_row + 1, row + 1) }
  end
  local by_line = {}
  for _, m in ipairs(marks) do
    -- A part's line joined with another one's: the part now ends on that line.
    local ecol = math.max(m[3].end_row == m[1] and m[3].end_col or #vim.fn.getbufline(buf, m[1] + 1)[1], m[2])
    -- Parts now on one line (lines joined) are one part.
    local row = by_line[m[1] + 1]
    if row then
      row[2], row[3] = math.min(row[2], m[2]), math.max(row[3], ecol)
    else
      by_line[m[1] + 1] = { m[1] + 1, m[2], ecol }
    end
  end
  local rows = vim.tbl_values(by_line)
  table.sort(rows, function(a, b)
    return a[1] < b[1]
  end)
  return { first = rows[1][1], last = rows[#rows][1], rows = rows, from = r.from }
end

---The text of the range spec `s` (from read()): its lines, or for a block
---each line's part.
function M.text(buf, s)
  local lines = vim.api.nvim_buf_get_lines(buf, s.first - 1, s.last, false)
  if not s.rows then
    return lines
  end
  return vim.tbl_map(function(row)
    return vim.fn.getbufline(buf, row[1])[1]:sub(row[2] + 1, row[3])
  end, s.rows)
end

---The first two of `specs` (from read()) that share a line, by index.
function M.overlap(specs)
  for i = 1, #specs do
    for j = i + 1, #specs do
      if specs[i].first <= specs[j].last and specs[i].last >= specs[j].first then
        return i, j
      end
    end
  end
end

---"L7" or "L7–13".
function M.label(s)
  return s.first == s.last and "L" .. s.first or string.format("L%d–%d", s.first, s.last)
end

-- The pending list: ranges of one buffer, tracked in their own namespace,
-- highlighted and numbered in file order.
local pns = vim.api.nvim_create_namespace("float-claude-ranges")
local label_ns = vim.api.nvim_create_namespace("float-claude-range-labels")
local pending = { buf = nil, list = {} }

local function specs()
  local out = {}
  for _, r in ipairs(pending.list) do
    local s = vim.api.nvim_buf_is_valid(pending.buf) and M.read(pending.buf, pns, r)
    if s and not s.deleted then
      table.insert(out, s)
    end
  end
  table.sort(out, function(a, b)
    return a.first < b.first
  end)
  return out
end

-- Number the pending ranges at the end of their first line.
local function relabel()
  if not (pending.buf and vim.api.nvim_buf_is_valid(pending.buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(pending.buf, label_ns, 0, -1)
  for i, s in ipairs(specs()) do
    vim.api.nvim_buf_set_extmark(pending.buf, label_ns, s.first - 1, 0, {
      virt_text = { { " range " .. i, "FloatClaudeHistory" } },
      virt_text_pos = "eol",
    })
  end
end

---Clear the pending list.
function M.clear()
  if pending.buf and vim.api.nvim_buf_is_valid(pending.buf) then
    vim.api.nvim_buf_clear_namespace(pending.buf, pns, 0, -1)
    vim.api.nvim_buf_clear_namespace(pending.buf, label_ns, 0, -1)
  end
  pending.buf, pending.list = nil, {}
end

---The pending ranges of `buf` as specs, in file order ({} for another buffer).
function M.pending(buf)
  return pending.buf == buf and specs() or {}
end

---Add the range spec `s` of `buf` to the pending list.
---@return boolean ok
---@return string? err when it is about another buffer or shares lines with a pending range
function M.add(buf, s)
  if pending.buf and pending.buf ~= buf and #specs() > 0 then
    local name = vim.api.nvim_buf_get_name(pending.buf)
    return false, "the collected ranges are in " .. (name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":t"))
  end
  if pending.buf ~= buf then
    M.clear()
    pending.buf = buf
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = vim.api.nvim_create_augroup("float-claude-ranges", {}),
      buffer = buf,
      callback = M.clear,
    })
  end
  for i, p in ipairs(specs()) do
    if s.first <= p.last and s.last >= p.first then
      return false, string.format("it shares lines with range %d", i)
    end
  end
  table.insert(pending.list, M.track(buf, pns, s, "FloatClaudeSelection"))
  relabel()
  return true
end

---Take the pending ranges of `buf` as specs, in file order, clearing the list.
function M.take(buf)
  local out = M.pending(buf)
  if #out > 0 then
    M.clear()
  end
  return out
end

return M
