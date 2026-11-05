-- Lays out text for the popup. An answer may hold `inline code` and fenced
-- code blocks: they show without backticks and fences, syntax-highlighted with
-- treesitter (plain when there is no parser for the language), and the names in
-- them are reported so they can be looked up through LSP.
local util = require("float-claude.util")

local M = {}

-- Captures that are never names of symbols.
local NOT_NAMES = { "keyword", "string", "comment", "number", "boolean", "float", "character", "operator", "punctuation", "constant.builtin", "label" }

local function width_of(s)
  return vim.fn.strdisplaywidth(s)
end

-- Bytes in the longest start of `s` that fits in `width` cells, at least one character.
local function fit(s, width)
  local n = vim.fn.strchars(s)
  local cut = n
  while cut > 1 and width_of(vim.fn.strcharpart(s, 0, cut)) > width do
    cut = cut - 1
  end
  return #vim.fn.strcharpart(s, 0, cut)
end

-- A row of output: its text, and pieces { from, to, col } saying that bytes
-- from..to-1 (0-based) of the source line sit at byte `col` of the row.
local function new_row()
  return { text = "", pieces = {} }
end

-- Word-wrap one line to `width` cells; words longer than a row are split.
local function wrap_line(text, width)
  local rows, row = {}, new_row()
  local function push()
    table.insert(rows, row)
    row = new_row()
  end
  local function add(from, piece)
    if row.text ~= "" then
      table.insert(row.pieces, { from - 1, from, #row.text }) -- the space before it
      row.text = row.text .. " "
    end
    table.insert(row.pieces, { from, from + #piece, #row.text })
    row.text = row.text .. piece
  end
  for from, word in text:gmatch("()(%S+)") do
    from = from - 1
    while width_of(word) > width do
      if row.text ~= "" then
        push()
      end
      local head = word:sub(1, fit(word, width))
      add(from, head)
      push()
      from, word = from + #head, word:sub(#head + 1)
    end
    if row.text ~= "" and width_of(row.text) + 1 + width_of(word) > width then
      push()
    end
    add(from, word)
  end
  push()
  return rows
end

-- Cut one line of code into rows of `width` cells, keeping its spacing.
local function cut_line(text, width)
  local rows, from = {}, 0
  repeat
    local n = fit(text:sub(from + 1), width)
    table.insert(rows, { text = text:sub(from + 1, from + n), pieces = { { from, from + n, 0 } } })
    from = from + n
  until from >= #text
  return rows
end

-- Byte range from..to-1 of the source line, as ranges on `row`.
local function map(row, from, to)
  local out = {}
  for _, p in ipairs(row.pieces) do
    local a, b = math.max(from, p[1]), math.min(to, p[2])
    local prev = out[#out]
    if a < b and prev and prev[2] == p[3] + a - p[1] then -- right after the last one
      prev[2] = p[3] + b - p[1]
    elseif a < b then
      table.insert(out, { p[3] + a - p[1], p[3] + b - p[1] })
    end
  end
  return out
end

---Word-wrap `text` to `width` cells, each of its lines on its own rows.
---@return string[]
function M.wrap(text, width)
  local out = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    for _, row in ipairs(wrap_line(line, math.max(width, 1))) do
      table.insert(out, row.text)
    end
  end
  return out
end

-- Treesitter captures of `code`, per 0-based line: { from, to, name, priority }.
-- Empty without a parser or highlight query for `lang`.
local function captures(code, lang, cache)
  local key = lang .. "\0" .. code
  if cache and cache[key] then
    return cache[key]
  end
  local out = {}
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, lang)
  local query = ok and parser and vim.treesitter.query.get(lang, "highlights")
  if query then
    local lines = vim.split(code, "\n", { plain = true })
    for id, node, metadata in query:iter_captures(parser:parse()[1]:root(), code) do
      local name = query.captures[id]
      if not name:match("^_") and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
        local priority = tonumber(metadata.priority or metadata[id] and metadata[id].priority) or 100
        local sr, sc, er, ec = node:range()
        for r = sr, er do
          local from, to = r == sr and sc or 0, r == er and ec or #lines[r + 1]
          if from < to then
            out[r] = out[r] or {}
            table.insert(out[r], { from, to, name, priority })
          end
        end
      end
    end
  end
  if cache then
    cache[key] = out
  end
  return out
end

-- Names in a line of code, as { from, to, name, chain }: identifiers outside
-- keywords, strings, comments and the like. `chain` is what qualifies it, as
-- "vim.api." for `nvim_buf_get_lines` in "vim.api.nvim_buf_get_lines".
local function names(line, caps)
  local out = {}
  for from, name, to in line:gmatch("%f[%w_]()([%a_][%w_]*)()") do
    from, to = from - 1, to - 1
    local excluded = vim.iter(caps or {}):any(function(c)
      return c[1] < to and c[2] > from and vim.iter(NOT_NAMES):any(function(n)
        return c[3] == n or vim.startswith(c[3], n .. ".")
      end)
    end)
    if not excluded then
      local chain = line:sub(1, from):match("[%w_.:]*$"):gsub("^[.:]+", "")
      table.insert(out, { from, to, name, chain:match("[.:]$") and chain or "" })
    end
  end
  return out
end

-- Splits a line of prose into its text without backticks and the byte ranges
-- of its code spans. With `open`, a span still streaming in runs to the end.
local function spans(line, open)
  local text, out, pos = {}, {}, 1
  local len = 0
  local function put(s)
    table.insert(text, s)
    len = len + #s
  end
  while true do
    local a, b = line:find("`+", pos)
    if not a then
      break
    end
    local ticks = line:sub(a, b)
    local c, d = line:find(ticks, b + 1, true)
    if c or open then
      put(line:sub(pos, a - 1))
      local code = line:sub(b + 1, c and c - 1 or -1)
      table.insert(out, { len, len + #code, code })
      put(code)
      pos = c and d + 1 or #line + 1
    else -- no closing backticks: they are text
      put(line:sub(pos, b))
      pos = b + 1
    end
  end
  put(line:sub(pos))
  return table.concat(text), out
end

---@class float-claude.Row
---@field text string
---@field hls { [1]: integer, [2]: integer, [3]: string, [4]: integer }[] byte columns from, to; group; priority
---@field names { [1]: integer, [2]: integer, [3]: string, [4]: string }[] byte columns from, to; name; chain

---Lay out an answer in rows of `opts.width` cells. `lang` is the language of
---code without a fence tag; `done` says the answer is complete (otherwise
---its last line is still streaming, and has no names yet); `cache` keeps
---treesitter results across calls.
---@param opts { width: integer, lang: string?, done: boolean, cache: table, tabstop: integer }
---@return float-claude.Row[]
function M.render(text, opts)
  local width = math.max(opts.width, 1)
  local lines = vim.split(text, "\n", { plain = true })
  local rows = {}
  local function finished(i)
    return opts.done or i < #lines
  end
  -- Rows for one source line; `ranges` are { from, to, group, priority } and
  -- `found` the line's names, in its bytes.
  local function emit(line_rows, ranges, found)
    for _, row in ipairs(line_rows) do
      local out = { text = row.text, hls = {}, names = {} }
      for _, r in ipairs(ranges) do
        for _, m in ipairs(map(row, r[1], r[2])) do
          table.insert(out.hls, { m[1], m[2], r[3], r[4] })
        end
      end
      for _, n in ipairs(found) do
        for _, m in ipairs(map(row, n[1], n[2])) do
          table.insert(out.names, { m[1], m[2], n[3], n[4] })
        end
      end
      table.insert(rows, out)
    end
  end
  local function highlights(caps, lang, offset, ranges)
    for _, c in ipairs(caps or {}) do
      table.insert(ranges, { offset + c[1], offset + c[2], "@" .. c[3] .. "." .. lang, c[4] })
    end
  end

  local i = 1
  while i <= #lines do
    local indent, fence, tag = lines[i]:match("^(%s*)(```+)%s*([^`%s]*)")
    if fence then
      -- A code block, to a closing fence or the end.
      local code, j = {}, i + 1
      while j <= #lines and not (lines[j]:match("^%s*(```+)%s*$") or ""):find(fence, 1, true) do
        local l = lines[j]
        table.insert(code, util.expand_tabs(l:sub(1, #indent) == indent and l:sub(#indent + 1) or l, opts.tabstop))
        j = j + 1
      end
      local lang = tag ~= "" and (vim.treesitter.language.get_lang(tag) or tag) or opts.lang
      local complete = j <= #lines or opts.done
      local caps = lang and captures(table.concat(code, "\n"), lang, complete and opts.cache) or {}
      for k, l in ipairs(code) do
        local ranges = {}
        highlights(caps[k - 1], lang, 0, ranges)
        emit(cut_line(l, width), ranges, finished(i + k) and names(l, caps[k - 1]) or {})
      end
      i = j + 1
    else
      local line, code_spans = spans(lines[i], not finished(i))
      local ranges, found = {}, {}
      for _, span in ipairs(code_spans) do
        local from, to, code = unpack(span)
        table.insert(ranges, { from, to, "FloatClaudeCode", 90 })
        local caps = opts.lang and captures(code, opts.lang, finished(i) and opts.cache)[0]
        highlights(caps, opts.lang, from, ranges)
        if finished(i) then
          for _, n in ipairs(names(code, caps)) do
            table.insert(found, { from + n[1], from + n[2], n[3], n[4] })
          end
        end
      end
      emit(wrap_line(line, width), ranges, found)
      i = i + 1
    end
  end
  return rows
end

return M
