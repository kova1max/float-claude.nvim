-- The popup under the selection: a prompt input, and once a conversation starts a
-- read-only, scrollable transcript window stacked right above the input.
local claude = require("float-claude.claude")
local edit = require("float-claude.edit")
local util = require("float-claude.util")

local M = {}

local ns = vim.api.nvim_create_namespace("float-claude")
local PREFIX = 3 -- " ❯ " / "   " before every text line
local SPINNER = { "◐", "◓", "◑", "◒" }
local CONTEXT_LINES = 40 -- unselected lines sent around the selection

local function set_highlights()
  -- `default = true` lets colorschemes and users override these.
  local bg = "#1c1c1f"
  vim.api.nvim_set_hl(0, "FloatClaudeNormal", { default = true, fg = "#e6e6e6", bg = bg })
  vim.api.nvim_set_hl(0, "FloatClaudePrompt", { default = true, fg = "#3fb5c9", bg = bg })
  vim.api.nvim_set_hl(0, "FloatClaudeHistory", { default = true, fg = "#8a8a8a" })
  vim.api.nvim_set_hl(0, "FloatClaudeSelection", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "FloatClaudeAdded", { default = true, bg = "#12301f" })
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
    if ex and ex.done then
      vim.api.nvim_set_current_win(s.iwin)
      vim.cmd("startinsert")
    end
  end
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, function()
      close(true)
    end, { buffer = s.tbuf, nowait = true })
  end
  for _, lhs in ipairs({ "i", "a", "<CR>" }) do
    vim.keymap.set("n", lhs, to_input, { buffer = s.tbuf, nowait = true })
  end
  -- Arrow keys (the wheel, with 'mouse' off) scroll.
  vim.keymap.set("n", "<Up>", "<C-y>", { buffer = s.tbuf })
  vim.keymap.set("n", "<Down>", "<C-e>", { buffer = s.tbuf })
end

---Open the popup for lines `first`..`last` of the current window's buffer.
---@param opts { first: integer, last: integer, cmd: string[], width: integer }
function M.open(opts)
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
  }

  local closed = false
  local proc, editing, spin_timer
  local close

  -- Anchor: screen row of the first/last selected line, and the screen column of
  -- the last line's first non-blank character (where typed text starts). An edit
  -- in progress counts the lines written so far.
  local function anchor()
    local function screen(lnum, col)
      local pos = vim.fn.screenpos(s.win, lnum, col)
      return pos.row - 1, pos.col - 1
    end
    local last = editing and s.first + editing.lines() - 1 or s.last
    local last_line = vim.api.nvim_buf_get_lines(s.buf, last - 1, last, false)[1]
    local indent = #last_line:match("^%s*")
    local row_last, col = screen(last, math.min(indent, math.max(#last_line - 1, 0)) + 1)
    local row_first = screen(s.first, 1)
    if row_last < 0 then -- last line scrolled out of view: anchor at the cursor line instead
      row_last, col = screen(s.cursor[1], s.cursor[2] + 1)
    end
    if row_first < 0 then
      row_first = row_last
    end
    if indent >= #last_line and #last_line > 0 then
      col = col + 1 -- whitespace-only line: text would start after it
    end
    return row_last, row_first, col
  end
  -- The column stays where the popup opened; the rows follow the selection.
  local _, _, text_col = anchor()

  local function set_selection()
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
    vim.wo[win].scrolloff = 0
    vim.wo[win].sidescrolloff = 0
    vim.wo[win].fillchars = "eob: "
    vim.wo[win].winhighlight = "Normal:FloatClaudeNormal,NormalNC:FloatClaudeNormal,NormalFloat:FloatClaudeNormal"
    return win
  end

  local function scratch(ft)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = ft
    return buf
  end

  s.ibuf = scratch("float-claude")
  local group = vim.api.nvim_create_augroup("float-claude-" .. s.ibuf, {})
  s.iwin = float_win(s.ibuf, true)
  -- A long prompt wraps at word boundaries, lined up after the prefix.
  vim.wo[s.iwin].wrap = true
  vim.wo[s.iwin].linebreak = true
  vim.wo[s.iwin].breakindent = true
  vim.wo[s.iwin].breakindentopt = "shift:" .. PREFIX
  vim.wo[s.iwin].showbreak = "NONE"

  -- Transcript lines with their highlights, rebuilt from s.exchanges.
  local function transcript(width)
    local lines, hls = {}, {}
    local function add(text, hl)
      table.insert(lines, text)
      if hl then
        table.insert(hls, { #lines - 1, hl })
      end
    end
    for _, ex in ipairs(s.exchanges) do
      ex.line = #lines + 1
      for i, l in ipairs(wrap(ex.q, width - PREFIX - 1)) do
        add((i == 1 and " ❯ " or "   ") .. l, "FloatClaudeHistory")
      end
      if ex.edit then -- the spinner rides on the lines being written
        for _, l in ipairs(wrap(ex.note or "refactoring…", width - PREFIX - 1)) do
          add("   " .. l, "FloatClaudeHistory")
        end
      elseif ex.a == "" and not ex.done then
        add("   " .. SPINNER[s.frame], "FloatClaudeHistory")
      else
        for _, l in ipairs(wrap(ex.a, width - PREFIX - 1)) do
          add("   " .. l)
        end
      end
      if ex.done then
        add("")
      end
    end
    return lines, hls
  end

  local function streaming()
    local ex = s.exchanges[#s.exchanges]
    return ex ~= nil and not ex.done
  end

  -- Scroll the transcript like a chat: the latest question at the top once
  -- everything no longer fits, then keep the newest line in view.
  local function follow_top()
    local n = vim.api.nvim_buf_line_count(s.tbuf)
    local h = vim.api.nvim_win_get_height(s.twin)
    local q = s.exchanges[#s.exchanges].line
    return n <= h and 1 or math.max(math.min(q, n), n - h + 1), n
  end

  local function follow_view()
    if not (s.twin and s.follow) then
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
    local chatting = #s.exchanges > 0
    local row_last, row_first = anchor()
    local col = math.max(text_col - PREFIX, 0)
    local width = math.max(math.min(opts.width, vim.o.columns - col), 1)

    local kept = s.twin and not s.follow and vim.fn.line("w0", s.twin)
    local tlines, hls = {}, {}
    if chatting then
      tlines, hls = transcript(width)
      vim.bo[s.tbuf].modifiable = true
      vim.api.nvim_buf_set_lines(s.tbuf, 0, -1, false, tlines)
      vim.bo[s.tbuf].modifiable = false
      vim.api.nvim_buf_clear_namespace(s.tbuf, ns, 0, -1)
      for _, hl in ipairs(hls) do
        vim.api.nvim_buf_set_extmark(s.tbuf, ns, hl[1], 0, { end_col = #tlines[hl[1] + 1], hl_group = hl[2] })
        if tlines[hl[1] + 1]:sub(1, 4) == " ❯" then
          vim.api.nvim_buf_set_extmark(s.tbuf, ns, hl[1], 1, { end_col = 4, hl_group = "FloatClaudePrompt", priority = 5000 })
        end
      end
    end

    -- The input's height is its rows once wrapped to the width.
    vim.api.nvim_win_set_config(s.iwin, { width = width })
    local input_rows = vim.api.nvim_win_text_height(s.iwin, {}).all
    local show_input = not streaming()
    local ih = show_input and input_rows or 0
    local bottom = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus == 0 and 0 or 1)
    local room_below, room_above = bottom - (row_last + 1), row_first
    local need = #tlines + ih
    local below = need <= room_below or room_below >= room_above
    local room = math.max(below and room_below or room_above, 1)
    ih = math.min(ih, room)
    local th = math.min(#tlines, room - ih)
    local top = below and row_last + 1 or row_first - (th + ih)

    if s.twin then
      vim.api.nvim_win_set_config(s.twin, {
        relative = "editor",
        row = top,
        col = col,
        width = width,
        height = math.max(th, 1),
        hide = th == 0,
      })
    end
    vim.api.nvim_win_set_config(s.iwin, {
      relative = "editor",
      row = top + th,
      col = col,
      width = width,
      height = math.max(ih, 1),
      hide = ih == 0,
    })

    -- Input: the prefix is virtual text so the buffer holds exactly what was typed.
    vim.api.nvim_buf_clear_namespace(s.ibuf, ns, 0, -1)
    for lnum = 0, vim.api.nvim_buf_line_count(s.ibuf) - 1 do
      vim.api.nvim_buf_set_extmark(s.ibuf, ns, lnum, 0, {
        virt_text = { lnum == 0 and { " ❯ ", "FloatClaudePrompt" } or { "   ", "FloatClaudeNormal" } },
        virt_text_pos = "inline",
        right_gravity = false, -- keep the prefix left of text typed at column 0
      })
    end
    -- A new row scrolls the still-short input before it grows; undo that once
    -- everything fits.
    if input_rows <= ih then
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

  local function restore_focus()
    if vim.api.nvim_win_is_valid(s.win) then
      vim.api.nvim_set_current_win(s.win)
      vim.api.nvim_win_set_cursor(s.win, s.cursor)
    end
    vim.cmd("stopinsert")
    -- Leaving Insert mode moves the cursor one cell left; put it back once that happened.
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == s.buf then
        pcall(vim.api.nvim_win_set_cursor, s.win, s.cursor)
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

  ---Close the popup and cancel any request. `refocus` is false when the user left
  ---on their own; an edit that is streaming then finishes without the popup.
  close = function(refocus)
    if closed then
      return
    end
    close_windows()
    if editing then
      if not refocus then
        return
      end
      editing.cancel()
    end
    if proc then
      proc.stop()
    end
    clear_selection()
    if refocus then
      restore_focus()
    end
  end

  local function fail(msg)
    if editing then
      editing.cancel(msg)
    else
      close(true)
      util.error(msg)
    end
    if proc then
      proc.stop()
    end
  end

  -- The edit is over: `result` has the line counts when it was applied.
  local function end_edit(ex, result)
    editing = nil
    local note = result and string.format("refactored %d → %d lines · u to undo", result.old, result.new)
    if closed then -- the user left while it streamed
      clear_selection()
      proc.stop()
      if note then
        vim.api.nvim_echo({ { note } }, true, {})
      end
      return
    end
    if not result then
      return close(true)
    end
    -- Follow-ups work on the new lines.
    s.last = s.first + result.new - 1
    s.cursor = vim.api.nvim_win_get_cursor(s.win)
    clear_selection()
    set_selection()
    ex.note = note
    ex.done = true
    stop_spinner()
    layout()
    vim.api.nvim_set_current_win(s.iwin)
    vim.cmd("startinsert")
  end

  -- The popup stays open while the reply streams into the selected lines.
  local function start_edit(code)
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
      editing.feed(text)
      return layout() -- the popup follows the written lines
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
        return start_edit(rest)
      end
      ex.a = rest
    end
    ex.a = vim.trim(ex.a)
    ex.done = true
    stop_spinner()
    layout()
    vim.api.nvim_set_current_win(s.iwin)
    vim.cmd("startinsert")
  end

  local function submit()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(s.ibuf, 0, -1, false), "\n"))
    if text == "" or streaming() then
      return
    end
    local message = #s.exchanges == 0 and first_message(s, text) or text
    if not s.twin then
      s.tbuf = scratch("float-claude-transcript")
      vim.bo[s.tbuf].modifiable = false
      s.twin = float_win(s.tbuf, false)
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
    if s.twin and vim.api.nvim_win_is_valid(s.twin) then
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
  map({ "i", "n" }, "<Esc>", function()
    close(true)
  end)
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

  vim.api.nvim_create_autocmd(
    { "TextChanged", "TextChangedI", "TextChangedP" },
    { group = group, buffer = s.ibuf, callback = layout }
  )
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    callback = function()
      vim.schedule(function()
        local cur = vim.api.nvim_get_current_win()
        if not closed and cur ~= s.iwin and cur ~= s.twin then
          close(false) -- the user went elsewhere: cancel, leave focus where it went
        end
      end)
    end,
  })

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

return M
