-- Headless tests. Run from the repo root: nvim --clean --headless -l tests/run.lua
-- Each case drives a fresh child Neovim over RPC, so keys go through real input
-- handling (mappings, mode changes, autocmds). tests/fake_claude.lua stands in
-- for the Claude Code CLI, so no network or account is needed.

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

-- Run the child's event loop until `cond` (Lua code returning a boolean) holds.
local function wait(cond, what)
  if not lua("return vim.wait(5000, function() " .. cond .. " end, 10)") then
    error("timed out waiting for " .. (what or cond), 2)
  end
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
  io.stdout:write((ok and "ok   " or "FAIL ") .. name .. (ok and "" or ("\n     " .. err)) .. "\n")
  failures = failures + (ok and 0 or 1)
end

local ORIGINAL = {
  "function f(nums)",
  "  for i = 1, #nums do",
  "    for j = i + 1, #nums do",
  "      print(i, j)",
  "    end",
  "  end",
  "end",
}

-- Set up the plugin with the fake CLI replying `replies` in order, and a buffer
-- holding ORIGINAL (padded to 40 lines) with the cursor on line 1. `opts` are
-- extra setup() options.
local function setup(replies, delay, opts)
  local log = vim.fn.tempname()
  lua(
    [[
    local root, log, replies, delay, opts = ...
    vim.env.FAKE_CLAUDE_REPLIES = vim.json.encode(replies)
    vim.env.FAKE_CLAUDE_DELAY = tostring(delay)
    vim.env.FAKE_CLAUDE_LOG = log
    vim.g.mapleader = " "
    require("float-claude").setup(vim.tbl_extend("force", {
      cmd = { vim.v.progpath, "--clean", "--headless", "-l", root .. "/tests/fake_claude.lua" },
    }, opts))
    local lines = vim.deepcopy(]] .. vim.inspect(ORIGINAL) .. [[)
    for i = #lines + 1, 40 do lines[i] = "-- " .. i end
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.filetype = "lua"
    vim.wo.number = true
    -- Test helpers: the transcript lines, and whether `n` answers are complete.
    function _G.transcript()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].filetype == "float-claude-transcript" then
          return vim.api.nvim_buf_get_lines(b, 0, -1, false)
        end
      end
      return {}
    end
    function _G.answered(n)
      local done = 0
      for _, l in ipairs(transcript()) do
        done = done + (l == "" and 1 or 0)
      end
      return done >= n and vim.bo.filetype == "float-claude"
    end
    function _G.logged(n)
      return vim.fn.filereadable(vim.env.FAKE_CLAUDE_LOG) == 1 and #vim.fn.readfile(vim.env.FAKE_CLAUDE_LOG) >= n
    end
  ]],
    root,
    log,
    replies or {},
    delay or 0,
    opts or {}
  )
  return log
end

-- Lines 2-6 selected linewise, popup opened with the default keymap.
local function ask()
  keys("2GV4j ai")
end

local function floats()
  return lua([[
    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local c = vim.api.nvim_win_get_config(win)
      if c.relative ~= "" and not c.hide then
        local pos = vim.api.nvim_win_get_position(win)
        local buf = vim.api.nvim_win_get_buf(win)
        out[vim.bo[buf].filetype] = {
          row = pos[1], col = pos[2], width = c.width, height = c.height,
          lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
          top = vim.fn.line("w0", win),
        }
      end
    end
    return out
  ]])
end

local function buffer()
  return lua("return vim.api.nvim_buf_get_lines(1, 0, 7, false)")
end

local function marks()
  return lua("return #vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, {})")
end

local function sent(log)
  local out = {}
  for _, line in ipairs(vim.fn.readfile(log)) do
    local msg = vim.json.decode(line)
    table.insert(out, msg.argv and "<start>" or msg.message.content)
  end
  return out
end

local function last_message()
  return lua([[return vim.trim(vim.fn.execute("1messages"))]])
end

test("popup opens under the selection with text at the last line's indent", function()
  setup()
  ask()
  local text_col = lua("return vim.fn.screenpos(1000, 6, 3).col - 1")
  eq({ row = 6, col = text_col - 3, width = 60, height = 1, lines = { "" }, top = 1 }, floats()["float-claude"])
  eq("i", lua("return vim.fn.mode()"), "mode")
  local sel = lua([[
    local m = vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true })[1]
    return { m[2], m[4].end_row, m[4].hl_group }
  ]])
  eq({ 1, 6, "FloatClaudeSelection" }, sel, "selection highlight rows")
end)

test("Normal mode trigger uses the current line", function()
  local log = setup({ "ANSWER\nok" })
  keys("4G ai")
  eq(4, floats()["float-claude"].row, "row below line 4")
  keys("q?<CR>")
  wait("return logged(2)")
  assert(sent(log)[2]:find("Selected lines 4-4:\n<selection>\n      print(i, j)\n</selection>", 1, true))
end)

test("the popup has a fixed width; a long prompt wraps onto more rows", function()
  setup()
  ask()
  local f = floats()["float-claude"]
  keys(string.rep("x", 30))
  eq({ 60, 1 }, { floats()["float-claude"].width, floats()["float-claude"].height }, "short prompt")
  keys(string.rep("x", 60))
  eq({ 60, 2, 1 }, { floats()["float-claude"].width, floats()["float-claude"].height, floats()["float-claude"].top }, "wrapped")
  eq(0, lua("return vim.fn.winsaveview().leftcol"), "no sideways scroll")
  -- The wrapped row lines up with the text above it, after the prefix.
  eq({ f.row + 2, f.col + 4 }, lua("local p = vim.fn.screenpos(0, 1, 58) return { p.row, p.col }"), "wrapped text position")
  keys(string.rep(" word", 10))
  eq({ 60, 3 }, { floats()["float-claude"].width, floats()["float-claude"].height }, "words wrap too")
end)

test("the width is a setup option, used by the conversation too", function()
  setup({ "ANSWER\none two three four five six seven" }, 0, { width = 20 })
  ask()
  eq(20, floats()["float-claude"].width, "prompt width")
  keys("hello there<CR>")
  wait("return answered(1)", "the answer")
  local t = floats()["float-claude-transcript"]
  eq(20, t.width, "conversation width")
  eq({ " ❯ hello there", "   one two three", "   four five six", "   seven", "" }, t.lines)
end)

test("Shift-Enter and Ctrl-J add lines; every line stays visible", function()
  setup()
  ask()
  for _, key in ipairs({ "first", "<S-CR>", "second", "<C-j>", "third" }) do
    keys(key)
    eq(1, floats()["float-claude"].top, "top line after " .. key)
  end
  eq({ "first", "second", "third" }, floats()["float-claude"].lines, "input lines")
end)

test("Ctrl-J splitting a line counts the new line's prefix in the height", function()
  setup()
  ask()
  keys("a" .. string.rep("x", 58) .. "<Home><Right><C-j>")
  eq({ "a", string.rep("x", 58) }, floats()["float-claude"].lines, "input lines")
  eq({ 3, 1 }, { floats()["float-claude"].height, floats()["float-claude"].top }, "height and top line")
end)

test("opens above the selection when there is no room below", function()
  setup()
  keys("30GV2j")
  lua("vim.cmd('normal! zb')")
  keys(" ai")
  local first_row = lua("return vim.fn.screenpos(1000, 30, 1).row - 1")
  eq(first_row - 1, floats()["float-claude"].row, "row above the first selected line")
end)

test("opens below the selection in a window with a winbar", function()
  setup()
  lua("vim.wo.winbar = 'bar'")
  ask()
  eq(lua("return vim.fn.screenpos(1000, 6, 1).row"), floats()["float-claude"].row, "row")
end)

test("Esc closes the popup and restores everything", function()
  setup()
  ask()
  keys("abc<Esc>")
  eq({ mode = "n", cursor = { 6, 0 }, wins = 1, bufs = 1, marks = 0 }, lua([[return {
    mode = vim.fn.mode(), cursor = vim.api.nvim_win_get_cursor(0),
    wins = #vim.api.nvim_list_wins(), bufs = #vim.api.nvim_list_bufs(),
    marks = #vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, {}) }]]))
end)

test("edit: the reply replaces the selection, fences stripped; the popup stays; one u undoes it", function()
  local log = setup({ "EDIT\n```lua\n  for _, a in ipairs(nums) do\n    print(a)\n  end\n```\n" })
  ask()
  keys("use ipairs<CR>")
  wait("return answered(1)", "the edit")
  eq({ "function f(nums)", "  for _, a in ipairs(nums) do", "    print(a)", "  end", "end", "-- 8", "-- 9" }, buffer())
  local t = floats()["float-claude-transcript"]
  eq({ " ❯ use ipairs", "   refactored 5 → 3 lines · u to undo", "" }, t.lines)
  eq(lua("return vim.fn.screenpos(1000, 4, 1).row"), t.row, "popup moved under the new lines")
  eq({ "float-claude", "i" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "back in the input, Insert mode")
  eq(true, lua("return vim.bo[1].modifiable"), "modifiable restored")
  wait("return #vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, {}) == 1", "the green flash to clear")
  local sel = lua([[
    local m = vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true })[1]
    return { m[2], m[4].end_row, m[4].hl_group }
  ]])
  eq({ 1, 4, "FloatClaudeSelection" }, sel, "the new lines are the selection now")
  keys("<Esc>")
  eq({ 1, 0, "n" }, { #lua("return vim.api.nvim_list_wins()"), marks(), lua("return vim.fn.mode()") }, "closed")
  eq({ 2, 2 }, lua("return vim.api.nvim_win_get_cursor(0)"), "cursor on the first new line")
  keys("u")
  eq(ORIGINAL, buffer(), "after one undo")
  local msg = sent(log)[2]
  assert(msg:find("File: ", 1, true) and msg:find("(filetype: lua)", 1, true), msg)
  assert(msg:find("Selected lines 2-6:\n<selection>\n" .. table.concat(ORIGINAL, "\n", 2, 6), 1, true), msg)
  assert(msg:find("Request: use ipairs", 1, true), msg)
end)

test("edit: streams line by line with the new lines highlighted", function()
  setup({ "EDIT\n  a()\n  b()\n  c()\n" }, 150)
  ask()
  keys("go<CR>")
  wait("return vim.api.nvim_buf_get_lines(1, 1, 2, false)[1] == '  a()'", "the first line")
  eq({ "function f(nums)", "  a()", "end", "-- 8" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 4, false)"))
  eq(false, lua("return vim.bo[1].modifiable"), "buffer locked while streaming")
  local t = floats()["float-claude-transcript"]
  assert(t.lines[2]:find("refactoring…", 1, true), t.lines[2])
  eq(lua("return vim.fn.screenpos(1000, 2, 1).row"), t.row, "popup under the lines written so far")
  local added = lua([[
    local n = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true })) do
      if m[4].line_hl_group == "FloatClaudeAdded" then n = n + 1 end
    end
    return n
  ]])
  eq(1, added, "highlighted new lines")
  wait("return answered(1)", "the edit")
  keys("<Esc>u")
  eq(ORIGINAL, buffer(), "after one undo")
end)

test("edit: Esc while streaming stops and restores the original", function()
  setup({ "EDIT\n  a()\n  b()\n  c()\n  d()\n" }, 200)
  ask()
  keys("go<CR>")
  wait("return vim.api.nvim_buf_get_lines(1, 1, 2, false)[1] == '  a()'", "the first line")
  keys("<Esc>")
  eq(ORIGINAL, buffer(), "original restored")
  eq({ true, 0, 1 }, lua("return { vim.bo.modifiable, #vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, {}), #vim.api.nvim_list_wins() }"))
  lua("vim.wait(600)")
  eq(ORIGINAL, buffer(), "nothing written after cancel")
end)

test("edit: a buffer that is not modifiable is left alone", function()
  setup({ "EDIT\n  a()\n" })
  lua("vim.bo.modifiable = false")
  ask()
  keys("go<CR>")
  wait("return #vim.api.nvim_list_wins() == 1", "the popup to close")
  eq("float-claude: the buffer is not modifiable", last_message())
  eq(ORIGINAL, buffer(), "buffer untouched")
  eq({ false, 0, "n" }, { lua("return vim.bo.modifiable"), marks(), lua("return vim.fn.mode()") })
end)

test("edit: a reply that is only the tag ends with an error and restores everything", function()
  setup({ "EDIT" })
  ask()
  keys("go<CR>")
  wait("return #vim.api.nvim_list_wins() == 1", "the popup to close")
  eq("float-claude: Claude returned no code", last_message())
  eq(ORIGINAL, buffer(), "buffer untouched")
  eq({ true, 0, "n" }, { lua("return vim.bo.modifiable"), marks(), lua("return vim.fn.mode()") })
end)

test("answer: a popup squeezed against the right edge still wraps", function()
  setup({ "ANSWER\nok then" })
  lua([[vim.api.nvim_buf_set_lines(0, 3, 4, false, { string.rep(" ", 75) .. "x" })]])
  keys("4G ai")
  eq(4, floats()["float-claude"].width, "squeezed width")
  keys("hello<CR>")
  wait("return answered(1)", "the answer")
  eq({ " ❯ h", "   e", "   l", "   l", "   o", "   o", "   k", "   t", "   h", "   e", "   n", "" },
    floats()["float-claude-transcript"].lines)
end)

test("answer: streams into the popup, then a fresh input; history is read-only", function()
  local log = setup({ "ANSWER\nO(n^2): the nested loops compare every pair. Space is O(1)." })
  ask()
  keys("what's the time complexity?<CR>")
  wait("return answered(1)", "the answer")
  local f = floats()
  eq({
    " ❯ what's the time complexity?",
    "   O(n^2): the nested loops compare every pair. Space is",
    "   O(1).",
    "",
  }, f["float-claude-transcript"].lines)
  eq(60, f["float-claude-transcript"].width, "chat width")
  eq(f["float-claude-transcript"].row + 4, f["float-claude"].row, "input right below the transcript")
  eq({ "float-claude", "i" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "back in the input, Insert mode")
  local readonly = lua([[
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "float-claude-transcript" then return not vim.bo[b].modifiable end
    end
  ]])
  eq(true, readonly, "transcript not modifiable")
  eq(1, marks(), "selection still highlighted")
  eq("<start>", sent(log)[1])
end)

test("follow-ups reuse the process and carry the conversation", function()
  local log = setup({ "ANSWER\nO(n^2).", "ANSWER\nYes, with a hash map." })
  ask()
  keys("complexity?<CR>")
  wait("return answered(1)", "the first answer")
  keys("can it be O(n)?<CR>")
  wait("return answered(2)", "the second answer")
  local s = sent(log)
  eq({ "<start>", "can it be O(n)?" }, { s[1], s[3] }, "one process, the follow-up sent as is")
  eq({
    " ❯ complexity?",
    "   O(n^2).",
    "",
    " ❯ can it be O(n)?",
    "   Yes, with a hash map.",
    "",
  }, floats()["float-claude-transcript"].lines)
end)

test("a follow-up can edit the original selection", function()
  setup({ "ANSWER\nIt loops twice.", "EDIT\n  print(#nums)\n" })
  ask()
  keys("explain<CR>")
  wait("return answered(1)", "the answer")
  keys("simplify it<CR>")
  wait("return answered(2)", "the edit")
  eq({ "function f(nums)", "  print(#nums)", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 3, false)"))
  eq({ " ❯ explain", "   It loops twice.", "", " ❯ simplify it", "   refactored 5 → 1 lines · u to undo", "" },
    floats()["float-claude-transcript"].lines)
end)

test("after an edit, a follow-up edit works on the edited lines; each is one undo", function()
  local log = setup({ "EDIT\n  a()\n  b()\n", "EDIT\n  c()\n" })
  ask()
  keys("go<CR>")
  wait("return answered(1)", "the first edit")
  keys("also merge them<CR>")
  wait("return answered(2)", "the second edit")
  eq({ "function f(nums)", "  c()", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 3, false)"))
  eq("also merge them", sent(log)[3], "the follow-up is sent as is")
  keys("<Esc>")
  keys("u")
  eq({ "function f(nums)", "  a()", "  b()", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 4, false)"))
  keys("u")
  eq(ORIGINAL, buffer(), "after two undos")
end)

test("leaving the popup while an edit streams lets the edit finish", function()
  setup({ "EDIT\n  a()\n  b()\n  c()\n" }, 150)
  ask()
  keys("go<CR>")
  wait("return vim.api.nvim_buf_get_lines(1, 1, 2, false)[1] == '  a()'", "the first line")
  lua("vim.api.nvim_set_current_win(1000)")
  lua("")
  eq(1, #lua("return vim.api.nvim_list_wins()"), "popup closed")
  wait("return vim.fn.execute('1messages'):find('refactored') ~= nil", "the edit")
  eq({ "function f(nums)", "  a()", "  b()", "  c()", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 5, false)"))
  eq("refactored 5 → 3 lines · u to undo", last_message())
  wait("return #vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, {}) == 0", "the highlights to clear")
  keys("u")
  eq(ORIGINAL, buffer(), "after one undo")
end)

test("answer: the tag may share its line with the answer, split across deltas", function()
  setup({ { "ANS", "WER It loops", " twice.\nThen", " stops." }, "ANSWER Yes." })
  ask()
  keys("explain<CR>")
  wait("return answered(1)", "the first answer")
  keys("sure?<CR>")
  wait("return answered(2)", "the second answer")
  eq({
    " ❯ explain",
    "   It loops twice.",
    "   Then stops.",
    "",
    " ❯ sure?",
    "   Yes.",
    "",
  }, floats()["float-claude-transcript"].lines)
end)

test("edit: the tag may share its line with the code", function()
  setup({ { "EDIT", " local n = #nums\n" } })
  ask()
  keys("simplify<CR>")
  wait("return answered(1)", "the edit")
  eq({ "function f(nums)", "local n = #nums", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 3, false)"))
end)

test("chat scrolls like a chat: question to the top, follows, scroll-back is kept", function()
  local long = {}
  for i = 1, 40 do
    long[i] = "line " .. i
  end
  setup({ "ANSWER\n" .. table.concat(long, "\n", 1, 20), "ANSWER\n" .. table.concat(long, "\n") .. "\n" }, 60)
  keys("1GV ai") -- 21 rows of room below line 1
  keys("first<CR>")
  wait("return answered(1)", "the first answer")
  keys("second<CR>")
  wait("return vim.api.nvim_buf_line_count(0) > 26", "the second answer to start")
  local t = floats()["float-claude-transcript"]
  eq(" ❯ second", t.lines[23], "question line")
  eq(23, t.top, "the new question sits at the top")
  wait("return vim.api.nvim_buf_line_count(0) > 45", "more of the answer")
  t = floats()["float-claude-transcript"]
  eq(#t.lines - t.height + 1, t.top, "newest line in view")
  keys("<C-u>")
  local scrolled = floats()["float-claude-transcript"].top
  assert(scrolled < t.top, "scrolled back")
  wait("return vim.api.nvim_buf_line_count(0) > 55", "even more of the answer")
  eq(scrolled, floats()["float-claude-transcript"].top, "scrolled-back view is not yanked")
  keys("G")
  wait("return answered(2)", "the second answer")
  t = floats()["float-claude-transcript"]
  eq(#t.lines - t.height + 1, t.top, "following again at the bottom")
  keys("<ScrollWheelUp>")
  eq(t.top - 3, floats()["float-claude-transcript"].top, "the wheel scrolls the conversation from the input")
  keys("<ScrollWheelDown>")
  eq(t.top, floats()["float-claude-transcript"].top, "and back")
end)

test("scrolled back, the view stays put while the next prompt is typed", function()
  local long = {}
  for i = 1, 25 do
    long[i] = "line " .. i
  end
  setup({ "ANSWER\n" .. table.concat(long, "\n"), "ANSWER\nYes." })
  keys("1GV ai")
  keys("first<CR>")
  wait("return answered(1)", "the first answer")
  keys("second<CR>")
  wait("return answered(2)", "the second answer")
  local top = floats()["float-claude-transcript"].top
  eq(" ❯ second", floats()["float-claude-transcript"].lines[top], "the question sits at the top")
  keys("<C-u>")
  local scrolled = floats()["float-claude-transcript"].top
  assert(scrolled < top, "scrolled back")
  keys("x")
  eq(scrolled, floats()["float-claude-transcript"].top, "not yanked back by typing")
  keys("<Down>")
  eq(scrolled + 1, floats()["float-claude-transcript"].top, "one line down is one line")
  keys("<C-d><C-d>")
  eq(top, floats()["float-claude-transcript"].top, "scrolled down, it follows again")
end)

test("with the mouse off, arrow keys (the wheel, in most terminals) scroll the conversation", function()
  local long = {}
  for i = 1, 25 do
    long[i] = "line " .. i
  end
  setup({ "ANSWER\n" .. table.concat(long, "\n"), "ANSWER\n" .. table.concat(long, "\n") }, 20)
  -- Like hardtime.nvim: no mouse, arrow keys disabled everywhere else.
  lua([[
    vim.o.mouse = ""
    for _, key in ipairs({ "<Up>", "<Down>" }) do vim.keymap.set({ "", "i" }, key, "") end
  ]])
  keys("1GV ai")
  keys("first<CR>")
  wait("return answered(1)", "the first answer")
  local top = floats()["float-claude-transcript"].top
  assert(top > 1, "the conversation overflows")
  keys("<Up><Up>")
  eq(top - 2, floats()["float-claude-transcript"].top, "up from the input")
  keys("<Down>")
  eq(top - 1, floats()["float-claude-transcript"].top, "down from the input")
  keys("a<C-j>b")
  top = floats()["float-claude-transcript"].top
  keys("<Up>")
  eq({ top, 1 }, { floats()["float-claude-transcript"].top, lua("return vim.fn.line('.')") },
    "in a multi-line prompt the arrows move between its lines first")
  keys("<Up>")
  eq(top - 1, floats()["float-claude-transcript"].top, "then scroll")
  keys("<C-u>")
  lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'second' })")
  keys("<CR>")
  wait("return vim.api.nvim_buf_line_count(0) > 35", "the second answer to stream")
  local t = floats()["float-claude-transcript"]
  keys("<Up><Up><Up>")
  eq(t.top - 3, floats()["float-claude-transcript"].top, "up while it streams")
  wait("return answered(2)", "the second answer")
  eq(t.top - 3, floats()["float-claude-transcript"].top, "the view stays put")
end)

test("errors show as one line and close everything", function()
  setup({ "!error Invalid API key · Please run /login" })
  ask()
  keys("hi<CR>")
  wait("return #vim.api.nvim_list_wins() == 1", "the popup to close")
  eq("float-claude: Invalid API key · Please run /login", last_message())
  eq({ 0, "n" }, { marks(), lua("return vim.fn.mode()") })
  setup({ "!exit boom\nsecond line" })
  ask()
  keys("hi<CR>")
  wait("return vim.fn.execute('1messages'):find('boom') ~= nil", "the exit error")
  eq("float-claude: boom", last_message())
end)

test("a missing CLI is reported, not thrown", function()
  setup()
  lua([[require("float-claude").setup({ cmd = { "float-claude-no-such-cli" } })]])
  ask()
  local msg = last_message()
  assert(vim.startswith(msg, "float-claude: cannot run float-claude-no-such-cli"), msg)
  assert(vim.fn.strdisplaywidth(msg) < 80, "fits on one line: " .. msg)
  eq({ 1, 0 }, { #lua("return vim.api.nvim_list_wins()"), marks() })
end)

test("leaving the popup cancels it", function()
  setup()
  ask()
  keys("<Esc>")
  ask()
  keys("abc")
  lua("vim.cmd.wincmd('p')")
  lua("")
  eq({ 1, 0, 1 }, { #lua("return vim.api.nvim_list_wins()"), marks(), #lua("return vim.api.nvim_list_bufs()") })
end)

test("highlight groups can be overridden", function()
  setup()
  lua([[vim.api.nvim_set_hl(0, "FloatClaudeNormal", { bg = "#123456" })]])
  ask()
  eq(0x123456, lua([[return vim.api.nvim_get_hl(0, { name = "FloatClaudeNormal" }).bg]]), "bg")
  eq(0x3fb5c9, lua([[return vim.api.nvim_get_hl(0, { name = "FloatClaudePrompt" }).fg]]), "prompt fg")
  eq(0x8a8a8a, lua([[return vim.api.nvim_get_hl(0, { name = "FloatClaudeHistory" }).fg]]), "history fg")
  eq(0x12301f, lua([[return vim.api.nvim_get_hl(0, { name = "FloatClaudeAdded" }).bg]]), "added bg")
end)

if failures > 0 then
  io.stdout:write(failures .. " failed\n")
  os.exit(1)
end
io.stdout:write("all passed\n")
