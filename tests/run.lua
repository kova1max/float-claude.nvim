-- Headless tests. Run from the repo root: nvim --clean --headless -l tests/run.lua
-- Each case drives a fresh child Neovim over RPC, so keys go through real input
-- handling (mappings, mode changes, autocmds).

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local failures, chan = 0, nil

local function lua(code, ...)
  return vim.rpcrequest(chan, "nvim_exec_lua", code, { ... })
end

local function keys(str)
  vim.rpcrequest(chan, "nvim_input", str)
  -- Requests run once the typeahead is consumed; one more lets vim.schedule callbacks run.
  lua("")
  lua("")
end

local function eq(expected, actual, what)
  if not vim.deep_equal(expected, actual) then
    error(string.format("%s: expected %s, got %s", what or "value", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local function test(name, fn)
  chan = vim.fn.jobstart({ vim.v.progpath, "--clean", "--embed", "--headless", "--cmd", "set rtp^=" .. root }, {
    rpc = true,
  })
  vim.rpcrequest(chan, "nvim_ui_attach", 80, 24, {})
  local ok, err = pcall(fn)
  vim.fn.jobstop(chan)
  print((ok and "ok   " or "FAIL ") .. name .. (ok and "" or ("\n     " .. err)))
  failures = failures + (ok and 0 or 1)
end

-- A 40-line buffer with the cursor on line 7, byte col 5; the popup records its result in vim.g.result.
local function setup_buffer()
  lua([[
    local lines = {}
    for i = 1, 40 do lines[i] = "line " .. i end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.cmd("normal! 7G05l")
  ]])
end

local function open(opts)
  lua(
    [[
    local opts = ...
    opts.on_submit = function(text) vim.g.result = text end
    opts.on_cancel = function() vim.g.cancelled = true end
    require("floatcc.input").open(opts)
  ]],
    opts or {}
  )
end

local function popup()
  return lua([[
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local config = vim.api.nvim_win_get_config(win)
      if config.relative ~= "" then
        local pos = vim.api.nvim_win_get_position(win)
        return { row = pos[1], col = pos[2], width = config.width, height = config.height }
      end
    end
  ]])
end

local function state()
  return lua([[
    return {
      result = vim.g.result,
      cancelled = vim.g.cancelled,
      mode = vim.fn.mode(),
      cursor = vim.api.nvim_win_get_cursor(0),
      wins = #vim.api.nvim_list_wins(),
      bufs = #vim.api.nvim_list_bufs(),
    }
  ]])
end

test("single line: opens under the cursor with the text in the cursor column", function()
  setup_buffer()
  local cursor_col = lua("return vim.fn.wincol() - 1")
  open()
  eq("i", lua("return vim.fn.mode()"), "mode")
  eq({ row = 7, col = cursor_col - 3, width = 26, height = 1 }, popup(), "popup")
  eq("floatcc", lua("return vim.bo.filetype"), "filetype")
end)

test("single line: Enter submits exactly the typed text and restores focus", function()
  setup_buffer()
  open()
  keys("hello world<CR>")
  eq({ result = "hello world", mode = "n", cursor = { 7, 5 }, wins = 1, bufs = 1 }, state())
end)

test("prefix is virtual and stays left of text typed at column 0", function()
  setup_buffer()
  open({ default = "world" })
  keys("<Home>hello ")
  local marks = lua([[
    local ns = vim.api.nvim_get_namespaces().floatcc
    local mark = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })[1]
    return { mark[2], mark[3], mark[4].virt_text[1][1], vim.api.nvim_win_get_cursor(0)[2] }
  ]])
  eq({ 0, 0, " ❯ ", 6 }, marks, "extmark row, col, text and cursor col")
  keys("<CR>")
  eq("hello world", state().result, "result")
end)

test("single line: Esc cancels; empty submit passes an empty string", function()
  setup_buffer()
  open()
  keys("abc<Esc>")
  eq({ cancelled = true, mode = "n", cursor = { 7, 5 }, wins = 1, bufs = 1 }, state())
  open()
  keys("<CR>")
  eq("", state().result, "empty submit")
end)

test("width grows with the longest line, from 26 up to 60 cells", function()
  setup_buffer()
  open()
  keys(string.rep("x", 30))
  eq(34, popup().width, "width after 30 chars")
  keys(string.rep("x", 70))
  eq(60, popup().width, "width after 100 chars")
end)

test("growing width keeps the typed text in the cursor column", function()
  setup_buffer()
  open({ multiline = true })
  for _, key in ipairs({ string.rep("x", 30), "<C-j>", string.rep("y", 40), string.rep("y", 16) }) do
    keys(key)
    eq(0, lua("return vim.fn.winsaveview().leftcol"), "horizontal scroll after " .. key)
  end
end)

test("multiline: Shift-Enter and Ctrl-J add lines, Enter submits", function()
  setup_buffer()
  open({ multiline = true })
  keys("find all pairs where<S-CR>a + b equals target<C-j>and return indices")
  eq(3, popup().height, "height")
  eq(7, popup().row, "grows downward")
  keys("<CR>")
  eq({ result = "find all pairs where\na + b equals target\nand return indices", mode = "n", wins = 1, bufs = 1 }, {
    result = state().result,
    mode = state().mode,
    wins = state().wins,
    bufs = state().bufs,
  })
end)

test("multiline: every line stays visible while the popup grows", function()
  setup_buffer()
  open({ multiline = true })
  for _, key in ipairs({ "first", "<S-CR>", "second", "<C-j>", "third" }) do
    keys(key)
    eq(1, lua("return vim.fn.line('w0')"), "top line after " .. key)
  end
end)

test("multiline: height caps at 8", function()
  setup_buffer()
  open({ multiline = true })
  keys(string.rep("x<C-j>", 11))
  eq(8, popup().height, "height")
end)

test("multiline: Esc leaves Insert mode, then Enter submits and q cancels", function()
  setup_buffer()
  open({ multiline = true, default = "one\ntwo" })
  keys("<Esc>")
  eq("n", lua("return vim.fn.mode()"), "mode in popup")
  keys("<CR>")
  eq("one\ntwo", state().result, "submitted")
  open({ multiline = true })
  keys("x<Esc>q")
  eq(true, state().cancelled, "cancelled")
end)

test("opens above the cursor when there is no room below", function()
  setup_buffer()
  lua("vim.cmd('normal! 40Gzb')")
  local cursor_row = lua("return vim.fn.winline() - 1")
  open({ multiline = true })
  eq(cursor_row - 1, popup().row, "single row sits right above the cursor")
  keys("a<C-j>b<C-j>c")
  eq({ cursor_row - 3, 3 }, { popup().row, popup().height }, "grows upward")
end)

test("returns to Insert mode at the original position when opened from Insert mode", function()
  setup_buffer()
  lua([[vim.keymap.set("i", "<F2>", function() vim.g.result = nil; require("floatcc.input").open({ on_submit = function(t) vim.g.result = t end }) end)]])
  keys("i<F2>abc<CR>")
  eq({ result = "abc", mode = "i", cursor = { 7, 5 } }, {
    result = state().result,
    mode = state().mode,
    cursor = state().cursor,
  })
  keys("X")
  eq("line X7", lua("return vim.fn.getline(7)"), "insert position")
end)

test("leaving the popup window cancels and wipes its buffer", function()
  setup_buffer()
  open({ multiline = true })
  keys("<Esc><C-w>p")
  eq({ cancelled = true, wins = 1, bufs = 1 }, { cancelled = state().cancelled, wins = state().wins, bufs = state().bufs })
end)

test("highlight groups can be overridden", function()
  lua([[vim.api.nvim_set_hl(0, "FloatCCNormal", { bg = "#123456" })]])
  setup_buffer()
  open()
  eq(0x123456, lua([[return vim.api.nvim_get_hl(0, { name = "FloatCCNormal" }).bg]]), "bg")
  eq(0x3fb5c9, lua([[return vim.api.nvim_get_hl(0, { name = "FloatCCPrompt" }).fg]]), "prompt fg")
end)

-- floatcc.ask with a stub claudecode.nvim that records what would reach the Claude terminal.
local function stub_claudecode()
  lua([[
    vim.g.sent = nil
    package.loaded["claudecode"] = {
      state = { config = { focus_after_send = false } },
    }
    package.loaded["claudecode.terminal"] = {
      get_active_terminal_bufnr = function() return 1 end,
      send_to_terminal = function(text, opts) vim.g.sent = text; return true end,
      ensure_visible = function() end,
    }
    vim.cmd.cd(vim.fn.fnamemodify(vim.fn.tempname(), ":h"))
    vim.cmd.edit("sample.lua")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "a", "b", "c", "d", "e" })
    vim.cmd.write()
    vim.g.mapleader = " "
    require("floatcc").setup()
  ]])
end

test("ask from Normal mode sends the prompt with the file attached", function()
  stub_claudecode()
  keys(" ai")
  eq("floatcc", lua("return vim.bo.filetype"), "popup opened by the default keymap")
  keys("summarize<S-CR>in one line<CR>")
  local file = lua("return vim.fn.fnamemodify('sample.lua', ':p')")
  eq("@" .. file .. "\nsummarize\nin one line", lua("return vim.g.sent"), "sent text")
end)

test("ask from Visual mode sends the selected line range", function()
  stub_claudecode()
  keys("4GVk ai")
  eq("i", lua("return vim.fn.mode()"), "popup open in Insert mode")
  keys("refactor this<CR>")
  local file = lua("return vim.fn.fnamemodify('sample.lua', ':p')")
  eq("@" .. file .. "#L3-4\nrefactor this", lua("return vim.g.sent"), "sent text")
end)

test("ask sends nothing for an empty prompt", function()
  stub_claudecode()
  keys(" ai<CR>")
  eq(vim.NIL, lua("return vim.g.sent"), "sent text")
end)

test("auto-start waits for the new terminal to connect even if another client is connected", function()
  stub_claudecode()
  lua([[
    local claudecode = package.loaded["claudecode"]
    local terminal = package.loaded["claudecode.terminal"]
    vim.g.clients = 1
    claudecode.state.config.connection_timeout = 5000
    claudecode.state.config.connection_wait_delay = 0
    claudecode.state.server = { get_status = function() return { client_count = vim.g.clients } end }
    claudecode.is_claude_connected = function() return vim.g.clients > 0 end
    local active = false
    terminal.get_active_terminal_bufnr = function() return active and 1 or nil end
    terminal.ensure_visible = function() active = true end
  ]])
  keys(" aiexplain<CR>")
  lua("vim.wait(300)")
  eq(vim.NIL, lua("return vim.g.sent"), "nothing sent before the new terminal connects")
  lua("vim.g.clients = 2")
  eq(true, lua("return vim.wait(1000, function() return vim.g.sent ~= nil end)"), "sent after it connects")
end)

if failures > 0 then
  print(failures .. " failed")
  os.exit(1)
end
print("all passed")
