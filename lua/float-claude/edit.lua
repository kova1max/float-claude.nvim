-- Streams Claude's replacement into the selected lines (or a block's parts,
-- or several ranges), one line at a time.
-- Writes are joined into a single undo block, and the buffer is locked
-- ('nomodifiable') between writes so nothing else can change the range.
-- In review mode nothing is written while the reply streams: it shows as an
-- inline diff (removed lines highlighted, added lines as virtual lines) until
-- it is accepted or discarded.
local util = require("float-claude.util")

local M = {}

local ns = vim.api.nvim_create_namespace("float-claude-edit")
local diff_ns = vim.api.nvim_create_namespace("float-claude-diff")
local SPINNER = { "◐", "◓", "◑", "◒" }
local diff = util.diff

---@alias float-claude.Target { first: integer, last: integer, rows: { [1]: integer, [2]: integer, [3]: integer, pad: integer }[]? }
---@param opts { buf: integer, win: integer, targets: float-claude.Target[], numbered: boolean?, review: boolean?, on_end: fun(result: { old: integer, new: integer, ranges: { n: integer, first: integer, was: integer, old: integer, new: integer }[], pending: boolean? }?) }
---  `buf` must be modifiable.
---  `targets` are what the reply replaces, in file order, apart from each
---  other: lines `first`..`last` (1-based), or with `rows` a block: the bytes
---  [rows[k][2], rows[k][3]) of line rows[k][1] (lines first..last), and `pad`
---  spaces to put before text added to a line that ends left of the block. The
---  reply's line k replaces a block's row k; rows it leaves out are emptied,
---  lines past them are added below. With `numbered`, the reply gives each
---  target it changes as a line "@@ range <n> @@" then its lines.
---  `on_end` runs once the edit is over, with the old and new line counts
---  (`ranges`: per changed target, its number, first line now and before, and counts) when
---  it was applied, or nil when it was cancelled or came back empty (the
---  original lines are back in place then). With `review`, the reply ends
---  with `pending = true` and the diff on screen; call accept() or discard()
---  then. on_end(nil) also follows if the buffer changes while the diff waits
---  (it is discarded).
function M.start(opts)
  local buf, review, targets = opts.buf, opts.review, opts.targets
  for _, t in ipairs(targets) do
    t.old = vim.api.nvim_buf_get_lines(buf, t.first - 1, t.last, false)
    t.new = {} -- the reply's lines for it
    t.delta = 0 -- lines it gained (lost) so far
  end
  local active = not opts.numbered and targets[1] or nil -- the target the reply is writing
  local written, partial, frame = 0, "", 1
  local writing, ended, pending, joined = false, false, false, false -- joined: the buffer was written (one undo block)
  local spinner_mark
  local timer = assert(vim.uv.new_timer())
  local self = {}

  -- 0-based row of target `t`'s first line now: the targets above it may have
  -- grown or shrunk.
  local function top(t)
    local row = t.first - 1
    for _, o in ipairs(targets) do
      row = row + (o.first < t.first and o.delta or 0)
    end
    return row
  end

  local function draw_spinner()
    local t = active or targets[1]
    local row = review and t.first - 1 or top(t) + math.max(#t.new - 1, 0)
    local text = written == 0 and (SPINNER[frame] .. " refactoring…") or SPINNER[frame]
    spinner_mark = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      id = spinner_mark,
      virt_text = { { " " .. text, "FloatClaudeHistory" } },
      virt_text_pos = "eol",
    })
  end

  -- The reply stopped streaming. `locked` keeps the buffer locked (a diff waits).
  local function finish_ui(locked)
    ended = true
    timer:stop()
    timer:close()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = not locked
      if spinner_mark then
        vim.api.nvim_buf_del_extmark(buf, ns, spinner_mark)
      end
    end
  end

  local function clear()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    end
  end

  -- A block target's lines with the reply's parts so far; once it is `done`,
  -- the rows the reply left out are emptied. Then the reply's lines past its rows.
  local function block_lines(t, done)
    local out = {}
    for k, row in ipairs(t.rows) do
      local line = t.old[k]
      local part = t.new[k] or (done and "" or line:sub(row[2] + 1, row[3]))
      local pad = t.new[k] and part ~= "" and string.rep(" ", row.pad) or ""
      table.insert(out, line:sub(1, row[2]) .. pad .. part .. line:sub(row[3] + 1))
    end
    return vim.list_extend(out, t.new, #t.rows + 1)
  end

  -- Review mode: draw the diff of target `t`'s lines `old` against `new`.
  -- While it streams (`open`), old lines past the last match are not decided
  -- yet: they stay plain and the new lines show above them.
  local function render_target(t, old, new, open)
    local first = t.first
    local width, tabstop = vim.o.columns, vim.bo[buf].tabstop
    local hunks = diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", { result_type = "indices" })
    for i, h in ipairs(hunks) do
      local a, a_count, b, b_count = unpack(h)
      if open and i == #hunks and a_count > 0 and a + a_count - 1 == #old then
        a, a_count = a - 1, 0
      end
      for r = a, a + a_count - 1 do
        vim.api.nvim_buf_set_extmark(buf, diff_ns, first - 2 + r, 0, {
          end_col = #old[r],
          hl_group = "FloatClaudeRemoved", -- the text, over the selection
          priority = 300,
          line_hl_group = "FloatClaudeRemoved", -- the rest of the line
        })
      end
      if b_count > 0 then
        local lines = {}
        for k = b, b + b_count - 1 do
          local text = util.expand_tabs(new[k], tabstop) -- virtual text does not expand them
          -- Padded so the background spans the window like a line highlight.
          text = text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
          table.insert(lines, { { text, "FloatClaudeAdded" } })
        end
        -- Below the last removed line, or the line they follow (above line 1 for 0).
        local after = a_count > 0 and a + a_count - 1 or a
        vim.api.nvim_buf_set_extmark(buf, diff_ns, first - 2 + math.max(after, 1), 0, {
          virt_lines = lines,
          virt_lines_above = after == 0,
        })
        if after == 0 and first == 1 and vim.api.nvim_win_is_valid(opts.win) and vim.api.nvim_win_get_buf(opts.win) == buf then
          -- Lines above line 1 show only as the window's top filler.
          vim.api.nvim_win_call(opts.win, function()
            if vim.fn.line("w0") == 1 then
              vim.fn.winrestview({ topfill = #lines })
            end
          end)
        end
      end
    end
  end

  -- Review mode: draw the diff of each target against the reply so far.
  local function render()
    vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    for _, t in ipairs(targets) do
      if #t.new > 0 then
        local done = ended or t.done
        render_target(t, t.old, t.rows and block_lines(t, done) or t.new, not done and not t.rows)
      end
    end
  end

  -- Put the original lines back by undoing the joined block (nothing else can be in it).
  local function revert()
    if joined and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent undo")
      end)
    end
  end

  -- Write line `k` of the reply for target `t` into the buffer, all writes in
  -- one undo block.
  local function put(t, k, line)
    writing = true
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_call(buf, function()
      if joined then
        vim.cmd("undojoin")
      else
        -- Start a new undo block: an earlier edit from the same popup can still
        -- be open, as nothing was typed in this buffer since.
        vim.cmd("let &l:undolevels = &l:undolevels")
        joined = true
      end
      local row = top(t) + k - 1
      local r = t.rows and t.rows[k]
      if r then -- a block's row: its part
        vim.api.nvim_buf_set_text(buf, row, r[2], row, r[3], { (line ~= "" and string.rep(" ", r.pad) or "") .. line })
      else
        -- The first line takes the place of the target's lines, the others
        -- (and a block's lines past its rows) are added.
        local replace = k == 1 and not t.rows
        vim.api.nvim_buf_set_lines(buf, row, replace and row + #t.old or row, false, { line })
        t.delta = t.delta + (replace and 1 - #t.old or 1)
      end
    end)
    vim.bo[buf].modifiable = false
    writing = false
  end

  -- The rows of block `t` its reply left out are emptied.
  local function empty_rest(t)
    if t.rows and #t.new > 0 then
      for k = #t.new + 1, #t.rows do
        put(t, k, "")
      end
    end
  end

  -- The reply is done with the active target.
  local function close_target()
    if active then
      active.done = true
      if not review then
        empty_rest(active)
      end
    end
    active = nil
  end

  local function write(line)
    if line:match("^%s*```") then
      return -- a stray fence
    end
    local n = opts.numbered and line:match("^%s*@@%s*[Rr]ange%s+(%d+)%s*@@%s*$")
    if n then
      close_target()
      active = targets[tonumber(n)]
      if active and active.done then
        active = nil -- given twice: the first one counts
      end
      return
    end
    local t = active
    if not t or (not t.rows and #t.new == 0 and vim.trim(line) == "") then
      return -- outside a target, or blank lines before its code
    end
    table.insert(t.new, line)
    written = written + 1
    if review then
      return render()
    end
    put(t, #t.new, line)
    vim.api.nvim_buf_set_extmark(buf, ns, top(t) + #t.new - 1, 0, { line_hl_group = "FloatClaudeAdded" })
    draw_spinner()
  end

  -- The line counts, in all and per target the reply changed.
  local function result()
    local out = { old = 0, new = 0, ranges = {} }
    for i, t in ipairs(targets) do
      if #t.new > 0 then
        local count = t.rows and math.max(#t.new, #t.rows) or #t.new
        table.insert(out.ranges, { n = i, first = top(t) + 1, was = t.first, old = #t.old, new = count })
        out.old, out.new = out.old + #t.old, out.new + count
      end
    end
    return out
  end

  -- The new lines are in the buffer: put the cursor on them, fade their highlight.
  local function applied()
    local out = result()
    if vim.api.nvim_win_is_valid(opts.win) and vim.api.nvim_win_get_buf(opts.win) == buf then
      vim.api.nvim_win_set_cursor(opts.win, { out.ranges[1].first, 0 })
      vim.api.nvim_win_call(opts.win, function()
        vim.cmd("normal! ^")
      end)
    end
    vim.defer_fn(clear, 700)
    return out
  end

  ---Feed reply text (after the EDIT tag line); complete lines are written as they arrive.
  function self.feed(text)
    if ended then
      return
    end
    partial = partial .. text
    for line in partial:gmatch("([^\n]*)\n") do
      write(line)
    end
    partial = partial:match("[^\n]*$")
  end

  ---The reply is complete.
  function self.finish()
    if ended then
      return
    end
    if partial ~= "" then
      write(partial)
    end
    close_target()
    pending = review and written > 0
    finish_ui(pending)
    if written == 0 then
      clear()
      opts.on_end(nil)
      util.error("Claude returned no code")
      return
    end
    if pending then
      render() -- the leftover old lines are removed now
      return opts.on_end(vim.tbl_extend("force", result(), { pending = true }))
    end
    opts.on_end(applied())
  end

  ---Review mode: write the reply over the targets (one undo block).
  ---@return { old: integer, new: integer, ranges: table[] }
  function self.accept()
    pending = false
    clear()
    -- The bottom target first, so the ones above stay where they are meanwhile.
    for i = #targets, 1, -1 do
      local t = targets[i]
      for k, line in ipairs(t.new) do
        put(t, k, line)
      end
      empty_rest(t)
    end
    vim.bo[buf].modifiable = true
    for _, r in ipairs(result().ranges) do
      for row = r.first - 1, r.first + r.new - 2 do
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "FloatClaudeAdded" })
      end
    end
    return applied()
  end

  ---Review mode: drop the diff; the buffer was never changed.
  ---@return { discarded: true }
  function self.discard()
    pending = false
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = true
    end
    clear()
    return { discarded = true }
  end

  ---Stop and restore the original lines. `msg` is echoed as an error when given.
  function self.cancel(msg)
    if ended then
      return
    end
    finish_ui()
    revert()
    clear()
    opts.on_end(nil)
    if msg then
      util.error(msg)
    end
  end

  -- Changed by someone else despite the lock: stop, touch nothing.
  local function changed()
    vim.schedule(function()
      if pending then
        self.discard()
        opts.on_end(nil)
        util.error("the buffer changed during the review; the edit was discarded")
      elseif not ended then
        joined = false -- the undo block holds that change now: nothing to revert
        self.cancel("the buffer changed during the edit; stopped")
      end
    end)
  end
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if ended and not pending then
        return true
      end
      if not writing then
        changed()
        return true
      end
    end,
    -- Reloaded from disk: reported here, not through on_lines.
    on_reload = function()
      if ended and not pending then
        return true
      end
      changed()
      return true
    end,
  })

  vim.bo[buf].modifiable = false
  draw_spinner()
  timer:start(130, 130, vim.schedule_wrap(function()
    if not ended then
      frame = frame % #SPINNER + 1
      draw_spinner()
    end
  end))
  return self
end

return M
