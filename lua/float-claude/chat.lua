-- The popup, pinned top-right or next to the cursor: a read-only, scrollable
-- conversation window (header, past turns) stacked right above the prompt input.
local claude = require("float-claude.claude")
local edit = require("float-claude.edit")
local util = require("float-claude.util")

local M = {}

local active -- the open popup, if any: { focus = fun(), close = fun() }

local ns = vim.api.nvim_create_namespace("float-claude")
local PREFIX = 4 -- "  ❯ " / "    " before every text line: 2 columns of padding, then the prompt
local SPINNER = { "◐", "◓", "◑", "◒" }
local CONTEXT_LINES = 40 -- unselected lines sent around the selection

local function set_highlights()
  -- `default = true` lets colorschemes and users override these.
  local bg = "#1c1c1f"
  vim.api.nvim_set_hl(0, "FloatClaudeNormal", { default = true, fg = "#e6e6e6", bg = bg })
  vim.api.nvim_set_hl(0, "FloatClaudePrompt", { default = true, fg = "#3fb5c9", bg = bg })
  vim.api.nvim_set_hl(0, "FloatClaudeHistory", { default = true, fg = "#8a8a8a" })
  vim.api.nvim_set_hl(0, "FloatClaudeHeader", { default = true, fg = "#4e4e55" })
  vim.api.nvim_set_hl(0, "FloatClaudeSelection", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "FloatClaudeAdded", { default = true, bg = "#12301f" })
  vim.api.nvim_set_hl(0, "FloatClaudeRemoved", { default = true, bg = "#3a1d22" })
end

local function width_of(s)
  return vim.fn.strdisplaywidth(s)
end

-- Word-wrap `text` to `width` display cells; words longer than a line are split.
local function wrap(text, width)
  width = math.max(width, 1)
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      while width_of(word) > width do
        if line ~= "" then
          table.insert(out, line)
          line = ""
        end
        local n = vim.fn.strchars(word)
        local cut = n
        while cut > 1 and width_of(vim.fn.strcharpart(word, 0, cut)) > width do
          cut = cut - 1
        end
        table.insert(out, vim.fn.strcharpart(word, 0, cut))
        word = vim.fn.strcharpart(word, cut, n)
      end
      if line == "" then
        line = word
      elseif width_of(line) + 1 + width_of(word) <= width then
        line = line .. " " .. word
      else
        table.insert(out, line)
        line = word
      end
    end
    table.insert(out, line)
  end
  return out
end

local function first_message(s, prompt)
  local buf = s.buf
  local name = vim.api.nvim_buf_get_name(buf)
  name = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":~:.")
  local ft = vim.bo[buf].filetype
  local total = vim.api.nvim_buf_line_count(buf)
  local from, to = math.max(1, s.first - CONTEXT_LINES), math.min(total, s.last + CONTEXT_LINES)
  local function lines(a, b)
    return table.concat(vim.api.nvim_buf_get_lines(buf, a - 1, b, false), "\n")
  end
  return table.concat({
    string.format("File: %s (filetype: %s)", name, ft == "" and "none" or ft),
    string.format("Lines %d-%d of the file, for context:", from, to),
    "<context>",
    lines(from, to),
    "</context>",
    string.format("Selected lines %d-%d:", s.first, s.last),
    "<selection>",
    lines(s.first, s.last),
    "</selection>",
    "Request: " .. prompt,
  }, "\n")
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

-- Transcript window keys: it is read-only; <Esc>/q close, i/a/<CR> go back to the input.
local function transcript_keymaps(s, close)
  local function to_input()
    local ex = s.exchanges[#s.exchanges]
    if not ex or ex.done then
      vim.api.nvim_set_current_win(s.iwin)
      vim.cmd("startinsert")
    end
  end
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, close, { buffer = s.tbuf, nowait = true })
  end
  for _, lhs in ipairs({ "i", "a", "<CR>" }) do
    vim.keymap.set("n", lhs, to_input, { buffer = s.tbuf, nowait = true })
  end
  -- Arrow keys (the wheel, with 'mouse' off) scroll.
  vim.keymap.set("n", "<Up>", "<C-y>", { buffer = s.tbuf })
  vim.keymap.set("n", "<Down>", "<C-e>", { buffer = s.tbuf })
end

-- "test.js · L7–13 · 7 lines", or "test.js · L7" for a single line.
local function header(s, width)
  local name = vim.api.nvim_buf_get_name(s.buf)
  name = name == "" and "[No Name]" or vim.fn.fnamemodify(name, ":t")
  local text = s.first == s.last and string.format("%s · L%d", name, s.first)
    or string.format("%s · L%d–%d · %d lines", name, s.first, s.last, s.last - s.first + 1)
  while width_of(text) > width and vim.fn.strchars(text) > 1 do -- too long: cut the end
    text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 2) .. "…"
  end
  return text
end

---Open the popup for lines `first`..`last` of the current window's buffer.
---@param opts { first: integer, last: integer, selected: boolean, cmd: string[], width: integer, placement: string, review_edits: boolean, accept_key: string, discard_key: string, hide_key: string, unfocus_key: string }
---  `selected` is true when the lines come from a Visual selection; they stay
---  highlighted while the popup is open. `placement` is "top-right" (pinned to
---  the editor's top-right corner) or "cursor" (1 row below, 3 columns right of it).
---  With `review_edits`, an edit shows as a diff until `accept_key` or
---  `discard_key` is pressed in the popup. `hide_key` hides the popup and
---  `unfocus_key` leaves it on screen; either way the conversation goes on,
---  and M.focus() comes back to it. A popup already open is closed first.
function M.open(opts)
  if active then
    active.close()
  end
  set_highlights()
  local s = {
    win = vim.api.nvim_get_current_win(),
    buf = vim.api.nvim_get_current_buf(),
    cursor = vim.api.nvim_win_get_cursor(0),
    first = opts.first,
    last = opts.last,
    exchanges = {}, -- { q = string, a = string, done = boolean, edit = boolean?, note = string? }
    follow = true,
    frame = 1,
    hidden = false,
  }
  -- The window (and its buffer) the popup was last entered from; `cursor` is
  -- its cursor then. Closing the popup goes back there.
  s.from, s.from_buf = s.win, s.buf

  local closed = false
  local proc, editing, reviewing, spin_timer -- reviewing: the edit whose diff waits for a decision
  local close

  -- Screen cell of the cursor (0-based), for the "cursor" placement.
  local cursor_pos = vim.fn.screenpos(s.win, s.cursor[1], s.cursor[2] + 1)
  local cursor_row, cursor_col = cursor_pos.row - 1, cursor_pos.col - 1

  local function set_selection()
    if not opts.selected then
      return
    end
    local count = vim.api.nvim_buf_line_count(s.buf)
    local last_line = vim.api.nvim_buf_get_lines(s.buf, s.last - 1, s.last, false)[1]
    s.sel_mark = vim.api.nvim_buf_set_extmark(s.buf, ns, s.first - 1, 0, {
      end_row = s.last < count and s.last or s.last - 1,
      end_col = s.last < count and 0 or #last_line,
      hl_group = "FloatClaudeSelection",
      priority = 200,
    })
  end
  set_selection()

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
    vim.wo[win].winhighlight = "Normal:FloatClaudeNormal,NormalNC:FloatClaudeNormal,NormalFloat:FloatClaudeNormal,FloatBorder:FloatClaudeNormal"
    return win
  end

  local function scratch(ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
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
    local lines, hls = {}, {}
    local function add(text, hl)
      table.insert(lines, text)
      if hl then
        table.insert(hls, { #lines - 1, hl })
      end
    end
    local text_width = width - PREFIX - 1
    add("")
    add("  " .. header(s, width - 3), "FloatClaudeHeader")
    for _, ex in ipairs(s.exchanges) do
      ex.line = #lines + 1
      for i, l in ipairs(wrap(ex.q, text_width)) do
        add((i == 1 and "  ❯ " or "    ") .. l, "FloatClaudeHistory")
      end
      if ex.edit then -- the spinner rides on the lines being written
        for _, l in ipairs(wrap(ex.note or "refactoring…", text_width)) do
          add("    " .. l, "FloatClaudeHistory")
        end
      elseif ex.a == "" and not ex.done then
        add("    " .. SPINNER[s.frame], "FloatClaudeHistory")
      else
        for _, l in ipairs(wrap(ex.a, text_width)) do
          add("    " .. l)
        end
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
    local width = math.max(math.min(opts.width, vim.o.columns), 1)

    local kept = not s.follow and vim.fn.line("w0", s.twin)
    local tlines, hls = transcript(width)
    vim.bo[s.tbuf].modifiable = true
    vim.api.nvim_buf_set_lines(s.tbuf, 0, -1, false, tlines)
    vim.bo[s.tbuf].modifiable = false
    vim.api.nvim_buf_clear_namespace(s.tbuf, ns, 0, -1)
    for _, hl in ipairs(hls) do
      vim.api.nvim_buf_set_extmark(s.tbuf, ns, hl[1], 0, { end_col = #tlines[hl[1] + 1], hl_group = hl[2] })
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
    local col, top, room
    if opts.placement == "cursor" then
      col = math.max(math.min(cursor_col + 3, vim.o.columns - width), 0)
      local room_below, room_above = bottom - (cursor_row + 1), cursor_row
      local below = need <= room_below or room_below >= room_above
      room = math.max(below and room_below or room_above, 1)
      top = below and cursor_row + 1 or cursor_row - math.min(need, room)
    else
      col, top, room = vim.o.columns - width, 0, math.max(bottom, 1)
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
    vim.api.nvim_set_current_win(win)
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
      s.discarded = true -- Claude is told with the next message
      note = "edit discarded"
    else
      -- Follow-ups work on the new lines.
      s.last = s.first + result.new - 1
      if s.from == s.win and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == s.buf then
        s.from_buf, s.cursor = s.buf, vim.api.nvim_win_get_cursor(s.win) -- on the new lines
      end
      clear_selection()
      set_selection()
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
    local message = #s.exchanges == 0 and first_message(s, text) or text
    if s.discarded then
      message = "(I discarded your last EDIT; the selected lines are unchanged.)\n" .. message
      s.discarded = false
    end
    table.insert(s.exchanges, { q = text, a = "", done = false })
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
    proc.send(message)
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

  local function map(modes, lhs, rhs)
    vim.keymap.set(modes, lhs, rhs, { buffer = s.ibuf, nowait = true })
  end
  map({ "i", "n" }, "<CR>", submit)
  map("i", "<S-CR>", "<CR>")
  map("i", "<C-j>", "<CR>")
  map({ "i", "n" }, "<Esc>", close)
  map({ "i", "n" }, "<C-u>", function()
    scroll("<C-u>")
  end)
  map({ "i", "n" }, "<C-d>", function()
    scroll("<C-d>", true)
  end)
  -- The wheel does not reach an unfocused float, so the input forwards it.
  map({ "i", "n" }, "<ScrollWheelUp>", function()
    scroll("3<C-y>")
  end)
  map({ "i", "n" }, "<ScrollWheelDown>", function()
    scroll("3<C-e>", true)
  end)
  -- With 'mouse' off, terminals send the wheel as arrow keys. They move between
  -- the prompt's lines, and past the first or last one scroll the conversation.
  map({ "i", "n" }, "<Up>", function()
    if vim.fn.line(".") > 1 then
      return vim.api.nvim_feedkeys(vim.keycode("<Up>"), "n", false)
    end
    scroll("<C-y>")
  end)
  map({ "i", "n" }, "<Down>", function()
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
  transcript_keymaps(s, close)
  if opts.review_edits then
    -- While a diff waits the cursor sits in the conversation, in Normal mode.
    for key, accept in pairs({ [opts.accept_key] = true, [opts.discard_key] = false }) do
      vim.keymap.set("n", key, function()
        if reviewing then
          end_edit(s.exchanges[#s.exchanges], accept and reviewing.accept() or reviewing.discard())
        end
      end, { buffer = s.tbuf, desc = accept and "float-claude: accept the edit" or "float-claude: discard the edit" })
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
  for key, hide in pairs({ [opts.hide_key] = true, [opts.unfocus_key] = false }) do
    local function run()
      if focused() then
        leave(false)
      end
      s.hidden = hide
      layout()
    end
    local desc = hide and "float-claude: hide the popup" or "float-claude: back to the code, popup stays"
    vim.keymap.set({ "i", "n" }, key, run, { buffer = s.ibuf, nowait = true, desc = desc })
    vim.keymap.set("n", key, run, { buffer = s.tbuf, nowait = true, desc = desc })
  end

  vim.api.nvim_create_autocmd(
    { "TextChanged", "TextChangedI", "TextChangedP" },
    { group = group, buffer = s.ibuf, callback = layout }
  )
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

  active = { focus = enter, close = close }
  -- Start the CLI now so its startup overlaps with typing the prompt.
  local err
  proc, err = claude.start({ cmd = opts.cmd, on_delta = on_delta, on_done = on_done, on_error = fail })
  if not proc then
    return fail(err)
  end
  layout()
  vim.cmd("startinsert")
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

return M
