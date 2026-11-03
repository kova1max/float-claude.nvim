-- Streams Claude's replacement into the selected lines, one line at a time.
-- Writes are joined into a single undo block, and the buffer is locked
-- ('nomodifiable') between writes so nothing else can change the range.
local util = require("float-claude.util")

local M = {}

local ns = vim.api.nvim_create_namespace("float-claude-edit")
local SPINNER = { "◐", "◓", "◑", "◒" }

---@param opts { buf: integer, win: integer, first: integer, last: integer, on_end: fun() }
---  `first`/`last` are the 1-based selected lines; `on_end` runs once the edit is over.
function M.start(opts)
  local buf, first = opts.buf, opts.first
  local old_count = opts.last - first + 1
  local written, partial, frame = 0, "", 1
  local writing, ended = false, false
  local was_modifiable = vim.bo[buf].modifiable
  local spinner_mark
  local timer = assert(vim.uv.new_timer())
  local self = {}

  local function draw_spinner()
    local row = written == 0 and first - 1 or first - 1 + written - 1
    local text = written == 0 and (SPINNER[frame] .. " refactoring…") or SPINNER[frame]
    spinner_mark = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      id = spinner_mark,
      virt_text = { { " " .. text, "FloatClaudeHistory" } },
      virt_text_pos = "eol",
    })
  end

  local function finish_ui()
    ended = true
    timer:stop()
    timer:close()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = was_modifiable
      pcall(vim.keymap.del, "n", "<Esc>", { buffer = buf })
      if spinner_mark then
        vim.api.nvim_buf_del_extmark(buf, ns, spinner_mark)
      end
    end
    opts.on_end()
  end

  local function clear()
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end

  -- Put the original lines back by undoing the joined block (nothing else can be in it).
  local function revert()
    if written > 0 and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent undo")
      end)
    end
  end

  local function write(line)
    if line:match("^%s*```") or (written == 0 and vim.trim(line) == "") then
      return -- stray fence, or blank lines before the code
    end
    writing = true
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_call(buf, function()
      if written > 0 then
        vim.cmd("undojoin")
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
    finish_ui()
    if written == 0 then
      clear()
      util.error("Claude returned no code")
      return
    end
    if vim.api.nvim_win_is_valid(opts.win) and vim.api.nvim_win_get_buf(opts.win) == buf then
      vim.api.nvim_win_set_cursor(opts.win, { first, 0 })
      vim.api.nvim_win_call(opts.win, function()
        vim.cmd("normal! ^")
      end)
    end
    vim.api.nvim_echo({ { string.format("refactored %d → %d lines · u to undo", old_count, written) } }, true, {})
    vim.defer_fn(clear, 700)
  end

  ---Stop and restore the original lines. `msg` is echoed as an error when given.
  function self.cancel(msg)
    if ended then
      return
    end
    finish_ui()
    revert()
    clear()
    if msg then
      util.error(msg)
    end
  end

  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if ended then
        return true
      end
      if not writing then
        -- Changed by someone else despite the lock (e.g. reloaded from disk): stop, touch nothing.
        vim.schedule(function()
          if not ended then
            written = 0
            self.cancel("the buffer changed during the edit; stopped")
          end
        end)
        return true
      end
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
