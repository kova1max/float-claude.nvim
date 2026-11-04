-- Streams Claude's replacement into the selected lines, one line at a time.
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
local diff = vim.text and vim.text.diff or vim.diff -- vim.diff is deprecated since Neovim 0.11

-- `line` as it shows on screen: virtual text does not expand tabs.
local function expand_tabs(line, tabstop)
  local i = line:find("\t", 1, true)
  while i do
    local before = line:sub(1, i - 1)
    line = before .. string.rep(" ", tabstop - vim.fn.strdisplaywidth(before) % tabstop) .. line:sub(i + 1)
    i = line:find("\t", i, true)
  end
  return line
end

---@param opts { buf: integer, win: integer, first: integer, last: integer, review: boolean?, on_end: fun(result: { old: integer, new: integer, pending: boolean? }?) }
---  `buf` must be modifiable.
---  `first`/`last` are the 1-based selected lines. `on_end` runs once the edit is
---  over, with the old and new line counts when it was applied, or nil when it was
---  cancelled or came back empty (the original lines are back in place then).
---  With `review`, the reply ends with `pending = true` and the diff on screen;
---  call accept() or discard() then. on_end(nil) also follows if the buffer
---  changes while the diff waits (it is discarded).
function M.start(opts)
  local buf, first, review = opts.buf, opts.first, opts.review
  local old_count = opts.last - first + 1
  local old = vim.api.nvim_buf_get_lines(buf, first - 1, opts.last, false)
  local new = {} -- review mode: the reply's lines
  local written, partial, frame = 0, "", 1
  local writing, ended, pending = false, false, false
  local spinner_mark
  local timer = assert(vim.uv.new_timer())
  local self = {}

  local function draw_spinner()
    local row = (written == 0 or review) and first - 1 or first - 1 + written - 1
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
      pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
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

  -- Review mode: draw the diff of the selected lines against the reply so far.
  -- While it streams, old lines past the last match are not decided yet: they
  -- stay plain and the new lines show above them.
  local function render()
    vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
    if #new == 0 then
      return
    end
    local width, tabstop = vim.o.columns, vim.bo[buf].tabstop
    local hunks = diff(table.concat(old, "\n") .. "\n", table.concat(new, "\n") .. "\n", { result_type = "indices" })
    for i, h in ipairs(hunks) do
      local a, a_count, b, b_count = unpack(h)
      if not ended and i == #hunks and a_count > 0 and a + a_count - 1 == #old then
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
          local text = expand_tabs(new[k], tabstop)
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

  -- Put the original lines back by undoing the joined block (nothing else can be in it).
  local function revert()
    if written > 0 and not review and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent undo")
      end)
    end
  end

  local function write(line)
    if line:match("^%s*```") or (written == 0 and vim.trim(line) == "") then
      return -- stray fence, or blank lines before the code
    end
    if review then
      table.insert(new, line)
      written = written + 1
      return render()
    end
    writing = true
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_call(buf, function()
      if written > 0 then
        vim.cmd("undojoin")
      else
        -- Start a new undo block: an earlier edit from the same popup can still
        -- be open, as nothing was typed in this buffer since.
        vim.cmd("let &l:undolevels = &l:undolevels")
      end
      local row = first - 1 + written
      vim.api.nvim_buf_set_lines(buf, row, written == 0 and opts.last or row, false, { line })
    end)
    vim.bo[buf].modifiable = false
    writing = false
    vim.api.nvim_buf_set_extmark(buf, ns, first - 1 + written, 0, { line_hl_group = "FloatClaudeAdded" })
    written = written + 1
    draw_spinner()
  end

  -- The new lines are in the buffer: put the cursor on them, fade their highlight.
  local function applied()
    if vim.api.nvim_win_is_valid(opts.win) and vim.api.nvim_win_get_buf(opts.win) == buf then
      vim.api.nvim_win_set_cursor(opts.win, { first, 0 })
      vim.api.nvim_win_call(opts.win, function()
        vim.cmd("normal! ^")
      end)
    end
    vim.defer_fn(clear, 700)
    return { old = old_count, new = written }
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
      return opts.on_end({ old = old_count, new = written, pending = true })
    end
    opts.on_end(applied())
  end

  ---Review mode: write the reply over the selected lines (one undo block).
  ---@return { old: integer, new: integer }
  function self.accept()
    pending = false
    clear()
    writing = true
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("let &l:undolevels = &l:undolevels") -- a new undo block, see write()
      vim.api.nvim_buf_set_lines(buf, first - 1, opts.last, false, new)
    end)
    writing = false
    for i = 1, written do
      vim.api.nvim_buf_set_extmark(buf, ns, first - 2 + i, 0, { line_hl_group = "FloatClaudeAdded" })
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
        written = 0
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
  vim.keymap.set("n", "<Esc>", function()
    self.cancel()
  end, { buffer = buf, desc = "float-claude: cancel the edit" })
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
