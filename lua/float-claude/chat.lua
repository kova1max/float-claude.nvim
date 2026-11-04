-- The popup, pinned top-right or next to the cursor: a read-only, scrollable
-- conversation window (header, past turns) stacked right above the prompt input.
local answer = require("float-claude.answer")
local claude = require("float-claude.claude")
local edit = require("float-claude.edit")
local lsp = require("float-claude.lsp")
local mentions = require("float-claude.mentions")
local theme = require("float-claude.theme")
local util = require("float-claude.util")

local M = {}

local active -- the open popup, if any: { focus = fun(), close = fun(), restyle = fun(ns) }

local ns = vim.api.nvim_create_namespace("float-claude")
local PREFIX = 4 -- "  ❯ " / "    " before every text line: 2 columns of padding, then the prompt
local SPINNER = { "◐", "◓", "◑", "◒" }
local DIFF_CONTEXT = 2 -- unchanged lines around each change in the diffs sent

local function width_of(s)
  return vim.fn.strdisplaywidth(s)
end

-- The lines sent around the selection.
local function window(s)
  return math.max(1, s.first - s.context_lines), math.min(vim.api.nvim_buf_line_count(s.buf), s.last + s.context_lines)
end

-- The user's own instructions: the `prompt` option, then the project's file.
local function instructions(opts, buf)
  local parts = {}
  local prompt = opts.prompt
  if type(prompt) == "function" then
    local name = vim.api.nvim_buf_get_name(buf)
    prompt = prompt({ buf = buf, file = name, filetype = vim.bo[buf].filetype })
  end
  if type(prompt) == "string" and vim.trim(prompt) ~= "" then
    table.insert(parts, vim.trim(prompt))
  end
  local root = opts.project_prompt and vim.fs.root(buf, opts.project_prompt)
  if root then
    local text = vim.trim(table.concat(vim.fn.readfile(vim.fs.joinpath(root, opts.project_prompt)), "\n"))
    if text ~= "" then
      table.insert(parts, text)
    end
  end
  return #parts > 0 and table.concat(parts, "\n\n") or nil
end

-- A unified diff from `old` to `new` (lists of lines) with file line numbers,
-- "" if they are the same. Given `from`/`to`, only the hunks touching those
-- lines of `new` are kept; the second result counts the others.
local function unified(old, new, from, to)
  local text = util.diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", { ctxlen = DIFF_CONTEXT })
  local hunks = {}
  for line in text:gmatch("[^\n]*\n") do
    if line:match("^@@") then
      table.insert(hunks, { line })
    else
      table.insert(hunks[#hunks], line)
    end
  end
  local kept, skipped = {}, 0
  for _, hunk in ipairs(hunks) do
    local start, count = hunk[1]:match("^@@ %-[%d,]+ %+(%d+),?(%d*) @@")
    local stop = tonumber(start) + math.max(tonumber(count) or 1, 1) - 1
    if not from or (stop >= from and tonumber(start) <= to) then
      table.insert(kept, table.concat(hunk))
    else
      skipped = skipped + 1
    end
  end
  return table.concat(kept), skipped
end

-- A request shortened to one line, to name Claude's edits by.
local function summary(request)
  local text = vim.trim((request:gsub("%s+", " ")))
  return vim.fn.strchars(text) > 60 and vim.fn.strcharpart(text, 0, 59) .. "…" or text
end

-- The request with the selected lines and their context as they are now. A
-- follow-up starts with what happened to the code since Claude's last reply
-- (s.log) and the list of Claude's edits applied so far (s.edits); the
-- context, if unchanged since the last message, is not sent again. `mentioned`
-- is what the request names with @ (see mentions.lua).
local function message(s, prompt, followup, mentioned)
  local buf = s.buf
  local name = vim.api.nvim_buf_get_name(buf)
  name = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":~:.")
  local ft = vim.bo[buf].filetype
  local from, to = window(s)
  local function lines(a, b)
    return table.concat(vim.api.nvim_buf_get_lines(buf, a - 1, b, false), "\n")
  end
  local out = {}
  if #s.log > 0 then
    table.insert(out, "Since your last reply:")
    vim.list_extend(out, s.log)
  end
  if #s.edits > 0 then
    table.insert(out, "Your edits applied in this conversation so far (each diff was sent once, when it was applied):")
    local function span(n, count)
      return count == 1 and "line " .. n or string.format("lines %d-%d", n, n + count - 1)
    end
    for i, e in ipairs(s.edits) do
      table.insert(out, string.format('#%d "%s": %s became %s', i, e.request, span(e.first, e.old), span(e.first, e.new)))
    end
  end
  if followup then
    table.insert(out, "The current version of the code (it replaces every earlier version):")
  end
  table.insert(out, string.format("File: %s (filetype: %s)", name, ft == "" and "none" or ft))
  local context = { from, to, lines(from, to) }
  if followup and vim.deep_equal(context, s.sent_context) then
    table.insert(out, string.format("Lines %d-%d of the file, for context: unchanged since my last message.", from, to))
  else
    vim.list_extend(out, { string.format("Lines %d-%d of the file, for context:", from, to), "<context>", context[3], "</context>" })
  end
  s.sent_context = context
  vim.list_extend(out, {
    string.format("Selected lines %d-%d:", s.first, s.last),
    "<selection>",
    lines(s.first, s.last),
    "</selection>",
  })
  if s.diagnostics then
    local diags = util.diagnostics(buf, s.first, s.last)
    if #diags > 0 then
      table.insert(out, "Diagnostics in the selected lines:")
      vim.list_extend(out, diags)
    elseif s.sent_diagnostics then
      table.insert(out, "Diagnostics in the selected lines: none now.")
    end
    s.sent_diagnostics = #diags > 0
  end
  if #mentioned > 0 then
    table.insert(out, "Mentioned in the request (with @):")
    vim.list_extend(out, vim.tbl_map(function(m)
      return m.text
    end, mentioned))
  end
  table.insert(out, "Request: " .. prompt)
  return table.concat(out, "\n")
end

-- Splits a reply into its EDIT/ANSWER tag and the rest. The tag is the first
-- word; the rest may start on the same line. Returns nil while the reply is
-- too short to tell, unless `final`. An untagged reply is an answer.
local function parse_tag(reply, final)
  local s = reply:gsub("^%s+", "")
  local word = s:match("^%a*")
  local tag = word:upper()
  if #word == #s and not final then
    if ("EDIT"):sub(1, #tag) == tag or ("ANSWER"):sub(1, #tag) == tag then
      return nil
    end
    return "ANSWER", reply
  end
  if tag ~= "EDIT" and tag ~= "ANSWER" then
    return "ANSWER", reply
  end
  local after = s:sub(#word + 1)
  if after:match("^:?[ \t]*$") and not final then
    return nil
  end
  local rest, n = after:gsub("^:?[ \t]*\n", "", 1)
  if n == 0 then
    rest = after:gsub("^:?[ \t]?", "", 1)
  end
  return tag, rest
end

-- Map `lhs` (skipped when false) in buffer `buf`.
local function map(buf, modes, lhs, rhs)
  if lhs then
    vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true })
  end
end

-- Transcript window keys: it is read-only; the close key closes, the insert
-- keys and the jump key go back to the input. On a name that resolved through
-- LSP, the jump key and a click jump to its definition and the hover key shows
-- hover: `on_link(action)` does that and returns true there.
local function transcript_keymaps(s, opts, close, on_link)
  local function to_input()
    local ex = s.exchanges[#s.exchanges]
    if not ex or ex.done then
      vim.api.nvim_set_current_win(s.iwin)
      vim.cmd("startinsert")
    end
  end
  map(s.tbuf, "n", opts.close_key, close)
  for _, lhs in ipairs(opts.insert_keys or {}) do
    map(s.tbuf, "n", lhs, to_input)
  end
  map(s.tbuf, "n", opts.jump_key, function()
    if not on_link("jump") then
      to_input()
    end
  end)
  vim.keymap.set({ "n", "i" }, "<LeftRelease>", function()
    on_link("jump")
  end, { buffer = s.tbuf })
  map(s.tbuf, "n", opts.hover_key, function()
    on_link("hover")
  end)
  map(s.tbuf, "n", opts.scroll_up_key, "<C-u>")
  map(s.tbuf, "n", opts.scroll_down_key, "<C-d>")
  -- Arrow keys (the wheel, with 'mouse' off) scroll.
  map(s.tbuf, "n", opts.line_up_key, "<C-y>")
  map(s.tbuf, "n", opts.line_down_key, "<C-e>")
end

-- "test.js · L7–13 · 7 lines", or "test.js · L7" for a single line, then the
-- chat's model (as chosen, else as the CLI reports it) and effort, if known.
local function header(s, width)
  local name = vim.api.nvim_buf_get_name(s.buf)
  name = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":t")
  local text = s.first == s.last and string.format("%s · L%d", name, s.first)
    or string.format("%s · L%d–%d · %d lines", name, s.first, s.last, s.last - s.first + 1)
  local tail = ""
  for _, part in ipairs({ s.model or s.reported or false, s.effort or false }) do
    if part then
      tail = tail .. " · " .. part
    end
  end
  while width_of(text .. tail) > width and vim.fn.strchars(text) > 1 do -- too long: cut the file part's end
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 2) .. "…"
  end
  return text .. tail
end

---Open the popup for lines `first`..`last` of the current window's buffer.
---@param opts table the setup() options (see init.lua), plus `first`, `last` and `selected`
---  `selected` is true when the lines come from a Visual selection; they stay
---  highlighted while the popup is open. With `review_edits`, an edit shows as
---  a diff until `accept_key` or `discard_key` is pressed in the popup.
---  `hide_key` hides the popup and `unfocus_key` leaves it on screen; either
---  way the conversation goes on, and M.focus() comes back to it. A popup
---  already open is closed first. With `send`, that prompt is sent right away.
function M.open(opts)
  if active then
    active.close()
  end
  local hl_ns = theme.apply(opts.theme, opts.colors)
  local s = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    cursor = vim.api.nvim_win_get_cursor(0),
    first = opts.first,
    last = opts.last,
    context_lines = opts.context_lines,
    diagnostics = opts.diagnostics,
    model = opts.model or nil, -- as chosen; `reported` is what the CLI says it runs
    effort = opts.effort or nil,
    -- { q = string, a = string, done = boolean, edit = boolean?, note = string?, mentions = string[]? }
    exchanges = {},
    follow = true,
    frame = 1,
    hidden = false,
    ts_cache = {}, -- treesitter results for code in answers
    links = {}, -- transcript row: { from, to, target } for names that resolved through LSP
    -- The change history: `known` is the buffer's lines as Claude knows them
    -- (as last sent, with its applied edits), `log` what happened to the code
    -- since its last reply, `edits` its applied edits.
    known = nil,
    log = {},
    edits = {}, -- { request, first, old, new }
  }
  local ft = vim.bo[s.buf].filetype
  s.lang = ft ~= "" and (vim.treesitter.language.get_lang(ft) or ft) or nil
  -- The window (and its buffer) the popup was last entered from; `cursor` is
  -- its cursor then. Closing the popup goes back there.
  s.from, s.from_buf = s.win, s.buf

  local closed = false
  local proc, editing, reviewing, spin_timer -- reviewing: the edit whose diff waits for a decision
  local close

  -- Screen cell of the cursor (0-based), for the "cursor" placement.
  local cursor_pos = vim.fn.screenpos(s.win, s.cursor[1], s.cursor[2] + 1)
  local cursor_row, cursor_col = cursor_pos.row - 1, cursor_pos.col - 1

  -- The selected lines are an extmark, so they follow changes made since: typing
  -- in them, lines added or removed above them. Highlighted if from Visual mode.
  local function set_selection()
    local count = vim.api.nvim_buf_line_count(s.buf)
    local last_line = vim.api.nvim_buf_get_lines(s.buf, s.last - 1, s.last, false)[1]
    s.sel_mark = vim.api.nvim_buf_set_extmark(s.buf, ns, s.first - 1, 0, {
      end_row = s.last < count and s.last or s.last - 1,
      end_col = s.last < count and 0 or #last_line,
      hl_group = opts.selected and "FloatClaudeSelection" or nil,
      priority = 200,
    })
  end
  set_selection()

  -- Read the selected lines back from the extmark (all of them deleted: the
  -- line that took their place).
  local function sync_selection()
    local m = vim.api.nvim_buf_is_loaded(s.buf) and vim.api.nvim_buf_get_extmark_by_id(s.buf, ns, s.sel_mark, { details = true })
    if m and m[1] then
      local row, end_row, end_col = m[1], m[3].end_row, m[3].end_col
      s.first = row + 1
      s.last = math.max(end_col == 0 and end_row > row and end_row or end_row + 1, s.first)
    end
  end

  -- The user's own changes since s.known (near the selection) go into the log
  -- as a diff; Claude knows the code as it is now then.
  local function note_hand_changes()
    local now = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
    if s.known then
      local d, skipped = unified(s.known, now, window(s))
      if d ~= "" then
        table.insert(s.log, "- I changed the code myself:\n<diff>\n" .. d .. "</diff>")
      end
      if skipped > 0 then
        table.insert(s.log, string.format("- I also changed the file in %d place(s) away from these lines (not shown).", skipped))
      end
    end
    s.known = now
  end

  local function float_win(buf, enter)
    local win = vim.api.nvim_open_win(buf, enter, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 1, -- set by layout()
      height = 1,
      style = "minimal",
      border = "none",
      focusable = true,
      noautocmd = true,
    })
    vim.wo[win].wrap = false
    vim.wo[win].winfixbuf = true -- :e, a jump or a picker opens files elsewhere, not here
    vim.wo[win].scrolloff = 0
    vim.wo[win].sidescrolloff = 0
    vim.wo[win].fillchars = "eob: "
    vim.api.nvim_win_set_hl_ns(win, hl_ns) -- the theme: popup colors, code highlighting in answers
    return win
  end

  local function scratch(ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.b[buf].float_claude_source = s.buf
    vim.bo[buf].filetype = ft
    return buf
  end

  -- The popup is two windows stacked: the conversation (padding row, header,
  -- past turns; read-only) and the prompt input below it.
  s.tbuf = scratch("float-claude-transcript")
  vim.bo[s.tbuf].modifiable = false
  s.twin = float_win(s.tbuf, false)
  s.ibuf = scratch("float-claude")
  local group = vim.api.nvim_create_augroup("float-claude-" .. s.ibuf, {})
  s.iwin = float_win(s.ibuf, true)
  -- A long prompt wraps at word boundaries, lined up after the prefix.
  vim.wo[s.iwin].wrap = true
  vim.wo[s.iwin].linebreak = true
  vim.wo[s.iwin].breakindent = true
  vim.wo[s.iwin].breakindentopt = "shift:" .. PREFIX
  vim.wo[s.iwin].showbreak = "NONE"

  local function streaming()
    local ex = s.exchanges[#s.exchanges]
    return ex ~= nil and not ex.done
  end

  -- Transcript lines with their highlights, rebuilt from s.exchanges: a padding
  -- row, the header, then each turn ("  ❯ question", the reply indented under
  -- it, a blank row). While a reply streams the prompt is hidden, so a last
  -- blank row pads the bottom.
  local function transcript(width)
    local lines, hls = {}, {} -- hls: { row, group, from?, to?, priority? }; whole row without from/to
    s.links = {}
    local function add(text, hl)
      table.insert(lines, text)
      if hl then
        table.insert(hls, { #lines - 1, hl })
      end
    end
    -- An answer's rows: code highlighted, names that resolve through LSP underlined.
    local function add_answer(ex, text_width)
      local rows = answer.render(ex.a, {
        width = text_width,
        lang = s.lang,
        done = ex.done,
        cache = s.ts_cache,
        tabstop = vim.bo[s.buf].tabstop,
      })
      for _, row in ipairs(rows) do
        add("    " .. row.text)
        for _, hl in ipairs(row.hls) do
          table.insert(hls, { #lines - 1, hl[3], hl[1] + 4, hl[2] + 4, hl[4] })
        end
        for _, name in ipairs(row.names) do
          local target = s.resolve and s.resolve(name[3], name[4])
          if target then
            table.insert(hls, { #lines - 1, "FloatClaudeLink", name[1] + 4, name[2] + 4, 150 })
            s.links[#lines] = s.links[#lines] or {}
            table.insert(s.links[#lines], { name[1] + 4, name[2] + 4, target })
          end
        end
      end
    end
    local text_width = width - PREFIX - 1
    add("")
    add("  " .. header(s, width - 3), "FloatClaudeHeader")
    for _, ex in ipairs(s.exchanges) do
      ex.line = #lines + 1
      for i, l in ipairs(answer.wrap(ex.q, text_width)) do
        add((i == 1 and "  ❯ " or "    ") .. l, "FloatClaudeHistory")
      end
      if ex.mentions then -- what the @ mentions sent
        for _, l in ipairs(answer.wrap("+ " .. table.concat(ex.mentions, ", "), text_width)) do
          add("    " .. l, "FloatClaudeHistory")
        end
      end
      if ex.edit then -- the spinner rides on the lines being written
        for _, l in ipairs(answer.wrap(ex.note or "refactoring…", text_width)) do
          add("    " .. l, "FloatClaudeHistory")
        end
      elseif ex.a == "" and not ex.done then
        add("    " .. SPINNER[s.frame], "FloatClaudeHistory")
      else
        add_answer(ex, text_width)
      end
      if ex.done then
        add("")
      end
    end
    if streaming() then
      add("")
    end
    return lines, hls
  end

  -- Scroll the transcript like a chat: the latest question at the top once
  -- everything no longer fits, then keep the newest line in view.
  local function follow_top()
    local n = vim.api.nvim_buf_line_count(s.tbuf)
    local h = vim.api.nvim_win_get_height(s.twin)
    local ex = s.exchanges[#s.exchanges]
    local q = ex and ex.line or 1
    return n <= h and 1 or math.max(math.min(q, n), n - h + 1), n
  end

  local function follow_view()
    if not s.follow then
      return
    end
    local top, n = follow_top()
    vim.api.nvim_win_call(s.twin, function()
      vim.api.nvim_win_set_cursor(0, { n, 0 })
      vim.fn.winrestview({ topline = top, leftcol = 0 })
    end)
  end

  local function layout()
    if closed then
      return
    end
    if not editing then -- an edit sets the selection once it is over
      sync_selection()
    end
    local width = math.max(math.min(opts.width, vim.o.columns), 1)

    local kept = not s.follow and vim.fn.line("w0", s.twin)
    local tlines, hls = transcript(width)
    vim.bo[s.tbuf].modifiable = true
    vim.api.nvim_buf_set_lines(s.tbuf, 0, -1, false, tlines)
    vim.bo[s.tbuf].modifiable = false
    vim.api.nvim_buf_clear_namespace(s.tbuf, ns, 0, -1)
    for _, hl in ipairs(hls) do
      vim.api.nvim_buf_set_extmark(s.tbuf, ns, hl[1], hl[3] or 0, {
        end_col = hl[4] or #tlines[hl[1] + 1],
        hl_group = hl[2],
        priority = hl[5],
      })
      if tlines[hl[1] + 1]:sub(1, 5) == "  ❯" then
        vim.api.nvim_buf_set_extmark(s.tbuf, ns, hl[1], 2, { end_col = 5, hl_group = "FloatClaudePrompt", priority = 5000 })
      end
    end

    -- Input: the prefix is virtual text so the buffer holds exactly what was typed.
    vim.api.nvim_buf_clear_namespace(s.ibuf, ns, 0, -1)
    for lnum = 0, vim.api.nvim_buf_line_count(s.ibuf) - 1 do
      vim.api.nvim_buf_set_extmark(s.ibuf, ns, lnum, 0, {
        virt_text = { lnum == 0 and { "  ❯ ", "FloatClaudePrompt" } or { "    ", "FloatClaudeNormal" } },
        virt_text_pos = "inline",
        right_gravity = false, -- keep the prefix left of text typed at column 0
      })
    end
    -- The prompt wraps one column short of the popup's edge, like the
    -- conversation: a 1-cell right border pads it. While the cursor sits after
    -- a full last row, the window takes that cell so the cursor stays there,
    -- unless that rewraps the rows (an unbroken word filling them): then the
    -- cursor goes to a new row, under the text.
    local iwidth, pad = math.max(width - 1, 1), { "", "", "", " ", "", "", "", "" }
    vim.api.nvim_win_set_config(s.iwin, { width = iwidth, border = pad })
    vim.api.nvim_win_call(s.iwin, function()
      local lnum, c = unpack(vim.api.nvim_win_get_cursor(0))
      local endcol = c > 0 and c == #vim.api.nvim_get_current_line() and vim.fn.screenpos(0, lnum, c).endcol or 0
      if endcol > 0 and endcol - vim.fn.win_screenpos(0)[2] + 1 == iwidth then
        -- Each line's row breaks, as the virtual columns where a new row starts.
        local function breaks()
          local out = {}
          for l = 1, vim.fn.line("$") do
            local rows = 1
            for v = 1, vim.fn.virtcol({ l, "$" }) do
              local h = vim.api.nvim_win_text_height(0, { start_row = l - 1, end_row = l - 1, end_vcol = v }).all
              if h > rows then
                rows = h
                table.insert(out, l .. ":" .. v)
              end
            end
          end
          return table.concat(out, ",")
        end
        local narrow = breaks()
        vim.api.nvim_win_set_config(0, { width = width, border = "none" })
        if breaks() == narrow then
          iwidth, pad = width, "none"
        else
          vim.api.nvim_win_set_config(0, { width = iwidth, border = pad })
          -- A cell after the text wraps onto a new row; the cursor is drawn before it.
          vim.api.nvim_buf_set_extmark(s.ibuf, ns, lnum - 1, c, {
            virt_text = { { " ", "FloatClaudeNormal" } },
            virt_text_pos = "inline",
            right_gravity = true,
          })
        end
      end
    end)
    -- The input's height is its rows once wrapped, plus a padding row.
    local input_rows = vim.api.nvim_win_text_height(s.iwin, {}).all
    local ih = streaming() and 0 or input_rows + 1
    local bottom = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus == 0 and 0 or 1)
    local need = #tlines + ih
    local cap = opts.max_height or math.huge
    local col, top, room
    if opts.placement == "cursor" then
      local off = opts.cursor_offset
      col = math.max(math.min(cursor_col + off.col, vim.o.columns - width), 0)
      -- Above the cursor, the popup ends as far from its line as it starts below it.
      local gap = math.max(off.row - 1, 0)
      local room_below, room_above = bottom - (cursor_row + off.row), cursor_row - gap
      local below = math.min(need, cap) <= room_below or room_below >= room_above
      room = math.max(math.min(below and room_below or room_above, cap), 1)
      top = below and cursor_row + off.row or cursor_row - gap - math.min(need, room)
    else
      local off = opts.top_right_offset
      col, top = math.max(vim.o.columns - width - off.col, 0), off.row
      room = math.max(math.min(bottom - off.row, cap), 1)
    end
    ih = math.min(ih, room)
    local th = math.min(#tlines, room - ih)

    vim.api.nvim_win_set_config(s.twin, {
      relative = "editor",
      row = top,
      col = col,
      width = width,
      height = math.max(th, 1),
      hide = s.hidden or th == 0,
      focusable = not s.hidden,
    })
    vim.api.nvim_win_set_config(s.iwin, {
      relative = "editor",
      row = top + th,
      col = col,
      width = iwidth,
      border = pad,
      height = math.max(ih, 1),
      hide = s.hidden or ih == 0,
      focusable = not s.hidden,
    })

    -- A new row scrolls the still-short input before it grows; undo that once
    -- everything fits.
    if input_rows < ih then
      vim.api.nvim_win_call(s.iwin, function()
        local view = vim.fn.winsaveview()
        if view.topline > 1 or (view.skipcol or 0) > 0 then
          vim.fn.winrestview({ topline = 1, skipcol = 0 })
        end
      end)
    end
    if kept then
      -- Scrolled back: keep the view through a resize; the cursor moves instead.
      vim.api.nvim_win_call(s.twin, function()
        local last = math.min(kept + vim.api.nvim_win_get_height(0) - 1, vim.fn.line("$"))
        vim.fn.winrestview({ topline = kept, lnum = math.min(math.max(vim.fn.line("."), kept), last) })
      end)
    else
      follow_view()
    end
  end
  s.resolve = lsp.resolver(s, layout) -- a name found: redraw to underline it

  local function stop_spinner()
    if spin_timer then
      spin_timer:stop()
      spin_timer:close()
      spin_timer = nil
    end
  end

  local function focused()
    local cur = vim.api.nvim_get_current_win()
    return cur == s.iwin or cur == s.twin
  end

  -- Focus the window the popup was entered from (or another editor window if
  -- it is gone), in Normal mode. Its cursor stays put, or with `restore` goes
  -- back to where it was when the popup was entered.
  local function leave(restore)
    local win = s.from
    if not vim.api.nvim_win_is_valid(win) then
      win = vim.iter(vim.api.nvim_tabpage_list_wins(0)):find(function(w)
        return vim.api.nvim_win_get_config(w).relative == ""
      end)
    end
    local buf = vim.api.nvim_win_get_buf(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    if restore and win == s.from and buf == s.from_buf then
      -- The buffer may have shrunk meanwhile (e.g. reloaded from disk).
      cursor = { math.min(s.cursor[1], vim.api.nvim_buf_line_count(buf)), s.cursor[2] }
    end
    s.keep = true -- not a leave that closes it (close_on_leave)
    vim.api.nvim_set_current_win(win)
    s.keep = false
    vim.api.nvim_win_set_cursor(win, cursor)
    vim.cmd("stopinsert")
    -- Leaving Insert mode moves the cursor one cell left; put it back once that happened.
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        pcall(vim.api.nvim_win_set_cursor, win, cursor)
      end
    end)
  end

  local function close_windows()
    closed = true
    stop_spinner()
    vim.api.nvim_del_augroup_by_id(group)
    for _, win in pairs({ transcript = s.twin, input = s.iwin }) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
  end

  local function clear_selection()
    if vim.api.nvim_buf_is_valid(s.buf) then
      pcall(vim.api.nvim_buf_del_extmark, s.buf, ns, s.sel_mark)
    end
  end

  ---Close the popup and end the conversation: a streaming edit is undone, a
  ---diff waiting for review discarded. Focus, if in the popup, goes back.
  close = function()
    if closed then
      return
    end
    local refocus = focused()
    if active and active.close == close then
      active = nil
    end
    close_windows()
    if reviewing then
      reviewing.discard() -- nothing is applied without a decision
      reviewing = nil
    end
    if editing then
      editing.cancel()
    end
    if proc then
      proc.stop()
    end
    clear_selection()
    if refocus then
      leave(true)
    end
  end

  local function fail(msg)
    if editing then
      editing.cancel(msg)
    else
      close()
      util.error(msg)
    end
    if proc then
      proc.stop()
    end
  end

  -- The edit is over: `result` has the line counts when it was applied, also
  -- `pending` while its diff waits for a decision, or is `{ discarded = true }`.
  local function end_edit(ex, result)
    local handle = editing
    editing, reviewing = nil, nil
    local note = result and result.old and string.format("refactored %d → %d lines · u to undo", result.old, result.new)
    if closed then -- cancelled by close()
      return
    end
    if not result then
      return close()
    end
    if result.pending then
      reviewing = handle
      ex.note = string.format("review: %d → %d lines\n%s accept · %s discard", result.old, result.new,
        opts.accept_key, opts.discard_key)
      stop_spinner()
      return layout()
    end
    if result.discarded then
      table.insert(s.log, string.format('- Your EDIT for "%s" was discarded: the code stayed as it was.', summary(ex.q)))
      note = "edit discarded"
    else
      local now = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false)
      table.insert(s.edits, { request = summary(ex.q), first = s.first, old = result.old, new = result.new })
      table.insert(s.log, string.format('- Your EDIT for "%s" (edit #%d) was %s:\n<diff>\n%s</diff>', summary(ex.q), #s.edits,
        opts.review_edits and "accepted and applied" or "applied as is", unified(s.known, now)))
      s.known = now
      -- Follow-ups work on the new lines.
      s.last = s.first + result.new - 1
      if s.from == s.win and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == s.buf then
        s.from_buf, s.cursor = s.buf, vim.api.nvim_win_get_cursor(s.win) -- on the new lines
      end
      clear_selection()
      set_selection()
      if opts.close_after_edit then
        return close()
      end
    end
    ex.note = note
    ex.done = true
    stop_spinner()
    layout()
    if focused() then
      vim.api.nvim_set_current_win(s.iwin)
      vim.cmd("startinsert")
    end
  end

  -- The popup stays open while the reply streams into the selected lines.
  local function start_edit(code)
    if not vim.api.nvim_buf_is_loaded(s.buf) then
      return fail("the buffer was unloaded")
    end
    if not vim.bo[s.buf].modifiable then
      return fail("the buffer is not modifiable")
    end
    local ex = s.exchanges[#s.exchanges]
    ex.edit = true
    sync_selection()
    note_hand_changes() -- made while Claude was replying; its edit's diff leaves them out
    editing = edit.start({
      buf = s.buf,
      win = s.win,
      first = s.first,
      last = s.last,
      review = opts.review_edits,
      on_end = function(result)
        end_edit(ex, result)
      end,
    })
    editing.feed(code)
    layout()
  end

  -- The reply's first word says which flow runs: EDIT or ANSWER.
  local reply, tag = "", nil
  local function on_delta(text)
    if editing then
      return editing.feed(text)
    end
    if closed then
      return
    end
    local ex = s.exchanges[#s.exchanges]
    if not tag then
      reply = reply .. text
      local rest
      tag, rest = parse_tag(reply, false)
      if not tag then
        return
      end
      if tag == "EDIT" then
        return start_edit(rest)
      end
      ex.a = rest
    else
      ex.a = ex.a .. text
    end
    if ex.a ~= "" then
      stop_spinner()
    end
    layout()
  end

  local function on_done()
    if editing then
      return editing.finish()
    end
    if closed then
      return
    end
    local ex = s.exchanges[#s.exchanges]
    if not tag then -- short reply, still undecided
      local rest
      tag, rest = parse_tag(reply, true)
      if tag == "EDIT" then
        start_edit(rest)
        if editing then
          editing.finish()
        end
        return
      end
      ex.a = rest
    end
    ex.a = vim.trim(ex.a)
    ex.done = true
    stop_spinner()
    layout()
    if focused() then
      vim.api.nvim_set_current_win(s.iwin)
      vim.cmd("startinsert")
    end
  end

  local function submit()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(s.ibuf, 0, -1, false), "\n"))
    if text == "" or streaming() then
      return
    end
    sync_selection()
    note_hand_changes()
    local mentioned = opts.mentions and mentions.expand(text, s.buf, opts.mentions) or {}
    local msg = message(s, text, #s.exchanges > 0, mentioned)
    s.log = {}
    table.insert(s.exchanges, {
      q = text,
      a = "",
      done = false,
      mentions = #mentioned > 0 and vim.tbl_map(function(m)
        return m.label
      end, mentioned) or nil,
    })
    reply, tag = "", nil
    s.follow = true
    vim.api.nvim_buf_set_lines(s.ibuf, 0, -1, false, {})
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(s.twin)
    layout()
    spin_timer = assert(vim.uv.new_timer())
    spin_timer:start(130, 130, vim.schedule_wrap(function()
      if spin_timer then
        s.frame = s.frame % #SPINNER + 1
        layout()
      end
    end))
    proc.send(msg)
  end

  -- Scroll the transcript from the input. Scrolling down when it cannot go
  -- further (e.g. the newest question is pinned at the top) follows again.
  local function scroll(key, down)
    if vim.api.nvim_win_is_valid(s.twin) then
      local top = vim.fn.line("w0", s.twin)
      vim.api.nvim_win_call(s.twin, function()
        vim.cmd("normal! " .. vim.keycode(key))
      end)
      if down and vim.fn.line("w0", s.twin) == top then
        s.follow = true
        follow_view()
      end
    end
  end

  local function imap(modes, lhs, rhs)
    map(s.ibuf, modes, lhs, rhs)
  end
  -- Keys the completion menu (of @ mentions) takes while an item in it is
  -- selected, or for <Up>/<Down> while it shows.
  local function menu_key(lhs, selected)
    if vim.fn.pumvisible() == 1 and (not selected or vim.fn.complete_info({ "selected" }).selected ~= -1) then
      vim.api.nvim_feedkeys(vim.keycode(lhs), "n", false)
      return true
    end
  end
  imap({ "i", "n" }, opts.submit_key, function()
    if not menu_key("<C-y>", true) then
      submit()
    end
  end)
  for _, lhs in ipairs(opts.newline_keys or {}) do
    imap("i", lhs, "<CR>")
  end
  -- <Esc> just leaves Insert mode; the close key (Normal mode) closes.
  imap("n", opts.close_key, close)
  imap({ "i", "n" }, opts.scroll_up_key, function()
    scroll("<C-u>")
  end)
  imap({ "i", "n" }, opts.scroll_down_key, function()
    scroll("<C-d>", true)
  end)
  -- The wheel does not reach an unfocused float, so the input forwards it.
  imap({ "i", "n" }, "<ScrollWheelUp>", function()
    scroll("3<C-y>")
  end)
  imap({ "i", "n" }, "<ScrollWheelDown>", function()
    scroll("3<C-e>", true)
  end)
  -- With 'mouse' off, terminals send the wheel as arrow keys. They move between
  -- the prompt's lines, and past the first or last one scroll the conversation.
  imap({ "i", "n" }, opts.line_up_key, function()
    if menu_key("<Up>") then
      return
    end
    if vim.fn.line(".") > 1 then
      return vim.api.nvim_feedkeys(vim.keycode("<Up>"), "n", false)
    end
    scroll("<C-y>")
  end)
  imap({ "i", "n" }, opts.line_down_key, function()
    if menu_key("<Down>") then
      return
    end
    if vim.fn.line(".") < vim.fn.line("$") then
      return vim.api.nvim_feedkeys(vim.keycode("<Down>"), "n", false)
    end
    scroll("<C-e>", true)
  end)

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    pattern = tostring(s.twin),
    callback = function()
      -- Scrolled back, the view stays put; scrolled down to where following
      -- would put it, it follows again.
      if vim.api.nvim_win_is_valid(s.twin) then
        s.follow = vim.fn.line("w0", s.twin) >= follow_top()
      end
    end,
  })
  transcript_keymaps(s, opts, close, function(action)
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local link = vim.iter(s.links[row] or {}):find(function(l)
      return col >= l[1] and col < l[2]
    end)
    if not link then
      return false
    end
    if action == "hover" then
      lsp.hover(link[3])
    else -- in the code window; the popup stays
      leave(false)
      vim.schedule(function()
        lsp.jump(link[3])
      end)
    end
    return true
  end)
  if opts.review_edits then
    -- While a diff waits the cursor sits in the conversation, in Normal mode.
    for _, key in ipairs({ { opts.accept_key, true }, { opts.discard_key, false } }) do
      local lhs, accept = unpack(key)
      if lhs then
        vim.keymap.set("n", lhs, function()
          if reviewing then
            end_edit(s.exchanges[#s.exchanges], accept and reviewing.accept() or reviewing.discard())
          end
        end, { buffer = s.tbuf, desc = accept and "float-claude: accept the edit" or "float-claude: discard the edit" })
      end
    end
  end

  -- Hidden or unfocused, the conversation goes on; enter() comes back to it.
  local function enter()
    if not focused() then
      s.from, s.from_buf, s.cursor = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf(),
        vim.api.nvim_win_get_cursor(0)
    end
    s.hidden = false
    layout()
    if streaming() then -- the cursor sits in the conversation, as after sending
      vim.api.nvim_set_current_win(s.twin)
      vim.cmd("stopinsert")
    else
      vim.api.nvim_set_current_win(s.iwin)
      vim.cmd("startinsert!")
    end
  end
  local function set_hidden(hidden)
    if focused() then
      leave(false)
    end
    s.hidden = hidden
    layout()
  end
  for _, key in ipairs({ { opts.hide_key, true }, { opts.unfocus_key, false } }) do
    local lhs, hide = unpack(key)
    local function run()
      set_hidden(hide)
    end
    if lhs then
      local desc = hide and "float-claude: hide the popup" or "float-claude: back to the code, popup stays"
      vim.keymap.set({ "i", "n" }, lhs, run, { buffer = s.ibuf, nowait = true, desc = desc })
      vim.keymap.set("n", lhs, run, { buffer = s.tbuf, nowait = true, desc = desc })
    end
  end
  if opts.close_on_leave then
    -- Leaving it other than with the unfocus key or a jump (leave()) closes it;
    -- its hover window counts as part of it.
    local function inside(win)
      return win == s.iwin or win == s.twin or vim.w[win]["float-claude-hover"] ~= nil
    end
    vim.api.nvim_create_autocmd("WinLeave", {
      group = group,
      callback = function()
        if not s.keep and inside(vim.api.nvim_get_current_win()) then
          vim.schedule(function()
            if not closed and not s.hidden and not inside(vim.api.nvim_get_current_win()) then
              close()
            end
          end)
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd(
    { "TextChanged", "TextChangedI", "TextChangedP" },
    { group = group, buffer = s.ibuf, callback = layout }
  )
  if opts.mentions then
    mentions.attach(s.ibuf, group)
  end
  -- Closed some other way (:q, :only): the conversation ends.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if win == s.iwin or win == s.twin then
        vim.schedule(close)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = s.buf, callback = close })
  -- Unloaded (:bd); `:e!` also unloads it, but reloads it right away.
  vim.api.nvim_create_autocmd("BufUnload", {
    group = group,
    buffer = s.buf,
    callback = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_loaded(s.buf) then
          close()
        end
      end)
    end,
  })

  -- Send `text` as if typed in the prompt; while a reply streams, say so and leave the prompt alone.
  local function send(text)
    if streaming() then
      return util.error("a reply is still streaming")
    end
    vim.api.nvim_buf_set_lines(s.ibuf, 0, -1, false, vim.split(text, "\n"))
    submit()
  end

  active = {
    focus = enter,
    close = close,
    send = send,
    hide = function()
      set_hidden(true)
    end,
    hidden = function()
      return s.hidden
    end,
    -- The buffer and lines the conversation is about.
    source = function()
      sync_selection()
      return s.buf, s.first, s.last
    end,
    restyle = function(theme_ns)
      for _, win in ipairs({ s.twin, s.iwin }) do
        vim.api.nvim_win_set_hl_ns(win, theme_ns)
      end
    end,
    -- The chat's model and effort (nil: the CLI's default), and switching them
    -- for the next message: the running CLI is told, so the conversation goes on.
    model = function()
      return s.model or s.reported
    end,
    effort = function()
      return s.effort
    end,
    set_model = function(name)
      proc.control({ subtype = "set_model", model = name }, function(err)
        if err then
          return util.error(string.format("model %s: %s", name, err))
        end
        s.model = name
        layout()
      end)
    end,
    set_effort = function(level)
      proc.control({ subtype = "apply_flag_settings", settings = { effortLevel = level } }, function(err)
        if err then
          return util.error(string.format("effort %s: %s", level, err))
        end
        s.effort = level
        layout()
      end)
    end,
  }
  -- Start the CLI now so its startup overlaps with typing the prompt.
  local err
  proc, err = claude.start({
    cmd = opts.cmd,
    model = s.model,
    effort = s.effort,
    instructions = instructions(opts, s.buf),
    on_delta = on_delta,
    on_done = on_done,
    on_error = fail,
    on_model = function(model)
      s.reported = model:gsub("^claude%-", "") -- "claude-opus-5-5": "opus-5-5"
      layout()
    end,
  })
  if not proc then
    return fail(err)
  end
  layout()
  if opts.send then
    send(opts.send)
  else
    vim.cmd("startinsert")
  end
  return s
end

---Focus the open popup, showing it first if hidden.
---@return boolean focused false when no popup is open
function M.focus()
  if not active then
    return false
  end
  active.focus()
  return true
end

---The open popup, if any: send(text) as a prompt, hide(), hidden(), source()
---for the buffer and lines its conversation is about, and model(), effort(),
---set_model(name), set_effort(level).
function M.current()
  return active
end

---Color the open popup, if any, with the theme namespace `theme_ns`.
function M.restyle(theme_ns)
  if active then
    active.restyle(theme_ns)
  end
end

return M
