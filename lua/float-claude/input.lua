-- Cursor-anchored, borderless input popup. Pure Lua, no plugin dependencies.
local M = {}

local ns = vim.api.nvim_create_namespace("float-claude")

local PREFIX_WIDTH = 3 -- " ❯ " on the first line, three spaces on the others
local MIN_WIDTH = 26
local MAX_WIDTH = 60
local MAX_HEIGHT = 8

local function set_highlights()
  -- `default = true` lets colorschemes and users override these.
  vim.api.nvim_set_hl(0, "FloatClaudeNormal", { default = true, fg = "#e6e6e6", bg = "#1c1c1f" })
  vim.api.nvim_set_hl(0, "FloatClaudePrompt", { default = true, fg = "#3fb5c9", bg = "#1c1c1f" })
end

-- The prefix is virtual text, so the buffer holds exactly what the user typed.
local function draw_prefix(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for lnum = 0, vim.api.nvim_buf_line_count(buf) - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, lnum, 0, {
      virt_text = { lnum == 0 and { " ❯ ", "FloatClaudePrompt" } or { "   ", "FloatClaudeNormal" } },
      virt_text_pos = "inline",
      right_gravity = false, -- keep the prefix left of text typed at column 0
    })
  end
end

-- `row`/`col` are the 0-based screen cell of the cursor the popup is anchored to.
local function win_config(buf, row, col)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local longest = 0
  for _, line in ipairs(lines) do
    longest = math.max(longest, vim.fn.strdisplaywidth(line))
  end
  local width = math.min(math.max(longest + PREFIX_WIDTH + 1, MIN_WIDTH), MAX_WIDTH)
  local height = math.min(#lines, MAX_HEIGHT)
  local bottom = vim.o.lines - vim.o.cmdheight - (vim.o.laststatus == 0 and 0 or 1)
  local top = row + 1 + height <= bottom and row + 1 or row - height
  return { relative = "editor", row = top, col = col - PREFIX_WIDTH, width = width, height = height }, longest
end

---@class float-claude.InputOpts
---@field default? string Initial text; may contain "\n" in multiline mode.
---@field multiline? boolean Shift-Enter / Ctrl-J insert a newline; Enter still submits.
---@field on_submit fun(text: string) Receives the typed lines joined with "\n".
---@field on_cancel? fun()

---Open the popup at the cursor of the current window.
---@param opts float-claude.InputOpts
function M.open(opts)
  set_highlights()

  local origin_win = vim.api.nvim_get_current_win()
  local origin_cursor = vim.api.nvim_win_get_cursor(origin_win)
  local origin_insert = vim.fn.mode() == "i"
  local win_pos = vim.fn.win_screenpos(origin_win)
  local row = win_pos[1] - 1 + vim.fn.getwininfo(origin_win)[1].winbar + vim.fn.winline() - 1
  local col = win_pos[2] - 1 + vim.fn.wincol() - 1

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "float-claude"
  local lines = vim.split(opts.default or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  draw_prefix(buf)

  local config = win_config(buf, row, col)
  config.style = "minimal"
  config.border = "none"
  config.focusable = true
  config.noautocmd = true
  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = false
  vim.wo[win].scrolloff = 0
  vim.wo[win].sidescrolloff = 0
  vim.wo[win].winhighlight =
    "Normal:FloatClaudeNormal,NormalNC:FloatClaudeNormal,NormalFloat:FloatClaudeNormal,EndOfBuffer:FloatClaudeNormal"
  vim.api.nvim_win_set_cursor(win, { #lines, #lines[#lines] })
  vim.cmd("startinsert!")

  local done = false
  -- `restore` is false when the user left the popup on their own (another window, :q):
  -- focus then stays where they went.
  local function finish(text, restore)
    if done then
      return
    end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if restore and vim.api.nvim_win_is_valid(origin_win) then
      vim.api.nvim_set_current_win(origin_win)
    end
    if not origin_insert then
      vim.cmd("stopinsert")
    end
    -- Leaving Insert mode moves the cursor one cell left; put it back once that happened.
    vim.schedule(function()
      if restore and vim.api.nvim_win_is_valid(origin_win) then
        vim.api.nvim_win_set_cursor(origin_win, origin_cursor)
      end
      if text then
        opts.on_submit(text)
      elseif opts.on_cancel then
        opts.on_cancel()
      end
    end)
  end

  local function submit()
    finish(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), true)
  end
  local function cancel()
    finish(nil, true)
  end

  local function map(modes, lhs, rhs)
    vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true })
  end
  map({ "i", "n" }, "<CR>", submit)
  map("n", "<Esc>", cancel)
  map("n", "q", cancel)
  if opts.multiline then
    map("i", "<S-CR>", "<CR>")
    map("i", "<C-j>", "<CR>")
  else
    map("i", "<S-CR>", submit)
    map("i", "<C-j>", submit)
    map("i", "<Esc>", cancel)
  end

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    buffer = buf,
    callback = function()
      draw_prefix(buf)
      local config, longest = win_config(buf, row, col)
      vim.api.nvim_win_set_config(win, config)
      -- A new line scrolls the still-short window before it grows; scroll back so
      -- no line is hidden above while filler rows show below.
      vim.api.nvim_win_call(win, function()
        local topline = math.max(1, vim.fn.line("$") - config.height + 1)
        if vim.fn.line("w0") > topline then
          vim.fn.winrestview({ topline = topline })
        end
        if longest + PREFIX_WIDTH + 1 <= config.width and vim.fn.winsaveview().leftcol > 0 then
          vim.fn.winrestview({ leftcol = 0 })
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = buf,
    callback = function()
      vim.schedule(function()
        finish(nil, false)
      end)
    end,
  })
end

return M
