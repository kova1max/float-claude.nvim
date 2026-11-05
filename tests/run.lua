-- Headless tests. Run from the repo root: nvim --clean --headless -l tests/run.lua
-- Each case drives a fresh child Neovim over RPC, so keys go through real input
-- handling (mappings, mode changes, autocmds). tests/fake_claude.lua stands in
-- for the Claude Code CLI, so no network or account is needed.

io.stdout:setvbuf("line") -- results show as they come, also when piped
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local failures, chan = 0, nil
-- Children keep their state (swap, shada, logs) out of the user's directories.
local xdg = vim.fn.tempname()
local env = {}
for _, dir in ipairs({ "CONFIG", "DATA", "STATE", "CACHE" }) do
  env["XDG_" .. dir .. "_HOME"] = xdg .. "/" .. dir:lower()
end

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

-- Start the child Neovim; again (`restart`) for a fresh one with the same state directory.
local function restart()
  if chan then
    vim.fn.jobstop(chan)
  end
  chan = vim.fn.jobstart({ vim.v.progpath, "--clean", "-n", "--embed", "--headless", "--cmd", "set rtp^=" .. root }, {
    rpc = true,
    env = env,
  })
  vim.rpcrequest(chan, "nvim_ui_attach", 80, 24, {})
end

local function test(name, fn)
  -- ONLY=<text> runs just the tests whose name contains it.
  if os.getenv("ONLY") and not name:find(os.getenv("ONLY"), 1, true) then
    return
  end
  env.XDG_STATE_HOME = vim.fn.tempname() -- saved chats (history) start empty
  chan = nil
  restart()
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
    -- Test helpers: the transcript lines (of the chat shown, else of the
    -- first one), and whether `n` answers are complete (each ends with a
    -- blank row; the first row is padding).
    function _G.transcript()
      local found
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].filetype == "float-claude-transcript" and (not found or not vim.api.nvim_win_get_config(w).hide) then
          found = b
        end
      end
      return found and vim.api.nvim_buf_get_lines(found, 0, -1, false) or {}
    end
    function _G.answered(n)
      local done = 0
      for i, l in ipairs(transcript()) do
        done = done + ((i > 1 and l == "") and 1 or 0)
      end
      return done >= n and vim.bo.filetype == "float-claude"
    end
    -- The review diff in buffer 1: rows of removed lines, and the virtual added
    -- lines as { row, above, texts } (padding trimmed).
    function _G.diff_view()
      local out = { removed = {}, added = {} }
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true })) do
        local d = m[4]
        if d.hl_group == "FloatClaudeRemoved" then
          table.insert(out.removed, m[2])
        end
        if d.virt_lines then
          local texts = {}
          for _, l in ipairs(d.virt_lines) do
            table.insert(texts, (l[1][1]:gsub("%s+$", "")))
          end
          table.insert(out.added, { m[2], d.virt_lines_above or false, texts })
        end
      end
      return out
    end
    function _G.reviewing()
      return vim.iter(transcript()):any(function(l) return l:find("review", 1, true) ~= nil end)
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
        -- The width on screen: the prompt's right margin is a 1-cell border.
        local right = c.border and c.border[4]
        local margin = right and (type(right) == "table" and right[1] or right) ~= "" and 1 or 0
        out[vim.bo[buf].filetype] = {
          row = pos[1], col = pos[2], width = c.width + margin, height = c.height,
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
    local r = msg.request -- a control request: "<set_model opus>"
    table.insert(out, msg.argv and "<start>"
      or r and string.format("<%s %s>", r.subtype, r.model or vim.json.encode(r.settings))
      or msg.message.content)
  end
  return out
end

-- The conversation's turns: the transcript without its padding row and header.
local function turns()
  return vim.list_slice(floats()["float-claude-transcript"].lines, 3)
end

local function last_message()
  return lua([[return vim.trim(vim.fn.execute("1messages"))]])
end

test("the popup is pinned top-right: padding, header, then the prompt", function()
  setup()
  lua("vim.api.nvim_buf_set_name(0, 'demo.lua')")
  ask()
  local f = floats()
  eq({ row = 0, col = 30, width = 50, height = 2, lines = { "", "  demo.lua · L2–6 · 5 lines" }, top = 1 },
    f["float-claude-transcript"], "padding row and header")
  eq({ row = 2, col = 30, width = 50, height = 2, lines = { "" }, top = 1 }, f["float-claude"], "prompt and padding row")
  eq("  ❯ ", lua("return vim.fn.screenstring(3, 31) .. vim.fn.screenstring(3, 32) .. vim.fn.screenstring(3, 33) .. vim.fn.screenstring(3, 34)"), "prompt")
  eq("i", lua("return vim.fn.mode()"), "mode")
  local sel = lua([[
    local m = vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true })[1]
    return { m[2], m[4].end_row, m[4].hl_group }
  ]])
  eq({ 1, 6, "FloatClaudeSelection" }, sel, "selection highlight rows")
end)

test("Normal mode trigger uses the current line, not highlighted", function()
  local log = setup({ "ANSWER\nok" })
  keys("4G ai")
  eq("  [No Name] · L4", floats()["float-claude-transcript"].lines[2], "header")
  eq(true, lua([[return vim.iter(vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true })):all(function(m)
    return m[4].hl_group == nil
  end)]]), "no selection highlight")
  keys("q?<CR>")
  wait("return logged(2)")
  assert(sent(log)[2]:find("Selected lines 4-4:\n<selection>\n      print(i, j)\n</selection>", 1, true))
end)

test("the popup has a fixed width; a long prompt wraps onto more rows", function()
  setup()
  ask()
  local f = floats()["float-claude"]
  -- Heights count a padding row under the prompt.
  keys(string.rep("x", 30))
  eq({ 50, 2 }, { floats()["float-claude"].width, floats()["float-claude"].height }, "short prompt")
  keys(string.rep("x", 30))
  eq({ 50, 3, 1 }, { floats()["float-claude"].width, floats()["float-claude"].height, floats()["float-claude"].top }, "wrapped")
  eq(0, lua("return vim.fn.winsaveview().leftcol"), "no sideways scroll")
  -- The wrapped row lines up with the text above it, after the prefix.
  eq({ f.row + 2, f.col + 5 }, lua("local p = vim.fn.screenpos(0, 1, 46) return { p.row, p.col }"), "wrapped text position")
  keys(string.rep(" word", 7))
  eq({ 50, 4 }, { floats()["float-claude"].width, floats()["float-claude"].height }, "words wrap too")
end)

test("the prompt wraps where the sent question does; the cursor stays inside the popup", function()
  setup({ "ANSWER\nok" })
  ask()
  -- 45 cells fill a row: the prefix takes 4 and the last column is a margin.
  keys(string.rep("x", 45))
  eq(2, floats()["float-claude"].height, "a full row stays one row")
  eq({ 1, 50 }, lua("return { vim.fn.winline(), vim.fn.wincol() }"), "cursor in the last column")
  keys("y")
  eq(3, floats()["float-claude"].height, "one more cell wraps")
  eq({ 2, 6 }, lua("return { vim.fn.winline(), vim.fn.wincol() }"), "cursor after the wrapped text")
  keys("<CR>")
  wait("return answered(1)", "the answer")
  eq({ "  ❯ " .. string.rep("x", 45), "    y" }, vim.list_slice(turns(), 1, 2), "same rows once sent")
end)

test("the prompt wraps a mention like the sent question: at a space, not inside its path", function()
  setup({ "ANSWER\nok" })
  ask()
  local f = floats()["float-claude"]
  -- "@lua/api.lua" does not fit after these 34 cells; 'breakat' would split it after "@lua/api.".
  keys("does this match how it is used in @lua/api.lua and more")
  eq({ f.row + 2, f.col + 5 }, lua("local p = vim.fn.screenpos(0, 1, 35) return { p.row, p.col }"), "the mention starts row 2")
  keys("<C-o>")
  eq(vim.o.breakat, lua("return vim.o.breakat"), "the user's 'breakat' back in the code")
  keys(" ai")
  eq({ "float-claude", " " }, lua("return { vim.bo.filetype, vim.o.breakat }"), "back in the prompt")
  keys("<CR>")
  wait("return answered(1)", "the answer")
  eq({ "  ❯ does this match how it is used in", "    @lua/api.lua and more" }, vim.list_slice(turns(), 1, 2), "same rows once sent")
  keys("<Esc>q")
  eq(vim.o.breakat, lua("return vim.o.breakat"), "the user's 'breakat' back once closed")
end)

test("an unbroken prompt filling two rows keeps its wrapping; the cursor goes under the text", function()
  setup()
  ask()
  local f = floats()["float-claude"]
  keys(string.rep("x", 90))
  -- Rows hold 45 cells, as in the sent question: widening for the cursor would rewrap them.
  eq({ f.row + 1, f.col + 49 }, lua("local p = vim.fn.screenpos(0, 1, 45) return { p.row, p.col }"), "row 1 ends at 45")
  eq({ f.row + 2, f.col + 5 }, lua("local p = vim.fn.screenpos(0, 1, 46) return { p.row, p.col }"), "row 2 starts at 46")
  eq({ 3, 5 }, lua("return { vim.fn.winline(), vim.fn.wincol() }"), "cursor on a new row, under the text")
  eq(4, floats()["float-claude"].height, "two rows, the cursor row and padding")
  keys("y")
  eq({ 3, 6 }, lua("return { vim.fn.winline(), vim.fn.wincol() }"), "typed text lands where the cursor was")
  eq(4, floats()["float-claude"].height, "the cursor row now holds text")
end)

test("the width is a setup option, used by the conversation too", function()
  setup({ "ANSWER\none two three four five six seven" }, 0, { width = 20 })
  ask()
  eq(20, floats()["float-claude"].width, "prompt width")
  keys("hello there<CR>")
  wait("return answered(1)", "the answer")
  local t = floats()["float-claude-transcript"]
  eq(20, t.width, "conversation width")
  eq({ "", "  [No Name] · L2–6…", "  ❯ hello there", "    one two three", "    four five six", "    seven", "" }, t.lines)
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
  -- 47 cells fit in a row without the 4-cell prefix, not with it.
  keys("a" .. string.rep("x", 47) .. "<Home><Right><C-j>")
  eq({ "a", string.rep("x", 47) }, floats()["float-claude"].lines, "input lines")
  eq({ 4, 1 }, { floats()["float-claude"].height, floats()["float-claude"].top }, "height and top line")
end)

test("cursor placement: 1 row below and 3 columns right of the cursor", function()
  setup(nil, 0, { placement = "cursor" })
  keys("2GV4jll ai")
  local cursor = lua([[
    local c = vim.api.nvim_win_get_cursor(1000)
    local p = vim.fn.screenpos(1000, c[1], c[2] + 1)
    return { p.row - 1, p.col - 1 }
  ]])
  local f = floats()
  eq({ cursor[1] + 1, cursor[2] + 3 }, { f["float-claude-transcript"].row, f["float-claude-transcript"].col }, "position")
  eq({ cursor[1] + 3, cursor[2] + 3 }, { f["float-claude"].row, f["float-claude"].col }, "prompt below the header")
end)

test("cursor placement: above the cursor when there is no room below, left of the right edge", function()
  setup(nil, 0, { placement = "cursor" })
  lua([[vim.api.nvim_buf_set_lines(0, 31, 32, false, { string.rep("x", 70) })]])
  keys("30GV2j$")
  lua("vim.cmd('normal! zb')")
  keys(" ai")
  local row = lua("return vim.fn.screenpos(1000, 32, 1).row - 1")
  local f = floats()
  eq(row - 4, f["float-claude-transcript"].row, "the popup ends right above the cursor line")
  eq(30, f["float-claude-transcript"].col, "shifted left to fit")
end)

test("cursor placement in a window with a winbar", function()
  setup(nil, 0, { placement = "cursor" })
  lua("vim.wo.winbar = 'bar'")
  ask()
  eq(lua("return vim.fn.screenpos(1000, 6, 1).row"), floats()["float-claude-transcript"].row, "row")
end)

test("Esc only leaves Insert mode; q closes the popup and restores everything", function()
  setup()
  ask()
  keys("abc<Esc>")
  eq({ "float-claude", "n", 3 }, lua("return { vim.bo.filetype, vim.fn.mode(), #vim.api.nvim_list_wins() }"),
    "still in the prompt, Normal mode")
  keys("iq<Esc>")
  eq({ "abqc" }, lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"), "q types q in Insert mode")
  keys("q")
  eq({ mode = "n", cursor = { 6, 0 }, wins = 1, bufs = 1, marks = 0 }, lua([[return {
    mode = vim.fn.mode(), cursor = vim.api.nvim_win_get_cursor(0),
    wins = #vim.api.nvim_list_wins(), bufs = #vim.api.nvim_list_bufs(),
    marks = #vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, {}) }]]))
end)

test("before the first send, i in the conversation window goes back to the prompt", function()
  setup()
  ask()
  keys("abc<C-\\><C-n><C-w>w")
  eq({ "float-claude-transcript", "n" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "in the conversation")
  keys("i")
  eq({ "float-claude", "i", 3 }, lua("return { vim.bo.filetype, vim.fn.mode(), #vim.api.nvim_list_wins() }"),
    "back in the prompt, Insert mode")
end)

test("edit: the reply replaces the selection, fences stripped; the popup stays; one u undoes it", function()
  local log = setup({ "EDIT\n```lua\n  for _, a in ipairs(nums) do\n    print(a)\n  end\n```\n" })
  ask()
  keys("use ipairs<CR>")
  wait("return answered(1)", "the edit")
  eq({ "function f(nums)", "  for _, a in ipairs(nums) do", "    print(a)", "  end", "end", "-- 8", "-- 9" }, buffer())
  eq({ "", "  [No Name] · L2–4 · 3 lines", "  ❯ use ipairs", "    refactored 5 → 3 lines · u to undo", "" },
    floats()["float-claude-transcript"].lines, "the header shows the new lines")
  eq({ "float-claude", "i" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "back in the input, Insert mode")
  eq(true, lua("return vim.bo[1].modifiable"), "modifiable restored")
  wait("return #vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, {}) == 1", "the green flash to clear")
  local sel = lua([[
    local m = vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true })[1]
    return { m[2], m[4].end_row, m[4].hl_group }
  ]])
  eq({ 1, 4, "FloatClaudeSelection" }, sel, "the new lines are the selection now")
  keys("<Esc>q")
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
  eq("    refactoring…", turns()[2], "status")
  local added = lua([[
    local n = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true })) do
      if m[4].line_hl_group == "FloatClaudeAdded" then n = n + 1 end
    end
    return n
  ]])
  eq(1, added, "highlighted new lines")
  wait("return answered(1)", "the edit")
  keys("<Esc>qu")
  eq(ORIGINAL, buffer(), "after one undo")
end)

test("edit: q while streaming stops and restores the original", function()
  setup({ "EDIT\n  a()\n  b()\n  c()\n  d()\n" }, 200)
  ask()
  keys("go<CR>")
  wait("return vim.api.nvim_buf_get_lines(1, 1, 2, false)[1] == '  a()'", "the first line")
  keys("<Esc>")
  eq(3, #lua("return vim.api.nvim_list_wins()"), "Esc does not close")
  keys("q")
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

test("review_edits: an edit shows as a diff until <leader>yy accepts it; one u undoes it", function()
  setup({ "EDIT\n  for _, a in ipairs(nums) do\n    print(a)\n  end\n" }, 0, { review_edits = true })
  ask()
  keys("use ipairs<CR>")
  wait("return reviewing()", "the diff")
  eq(ORIGINAL, buffer(), "nothing written yet")
  eq(false, lua("return vim.bo[1].modifiable"), "locked while the diff waits")
  eq({ removed = { 1, 2, 3, 4 }, added = { { 4, false, { "  for _, a in ipairs(nums) do", "    print(a)" } } } },
    lua("return diff_view()"), "removed lines and added lines")
  eq({ "  ❯ use ipairs", "    review: 5 → 3 lines", "    <leader>yy accept · <leader>nn discard", "" }, turns())
  eq({ "float-claude-transcript", "n" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "in the conversation")
  keys(" yy")
  eq({ "function f(nums)", "  for _, a in ipairs(nums) do", "    print(a)", "  end", "end", "-- 8", "-- 9" }, buffer())
  eq({ "  ❯ use ipairs", "    refactored 5 → 3 lines · u to undo", "" }, turns())
  eq({ "float-claude", "i", true }, lua("return { vim.bo.filetype, vim.fn.mode(), vim.bo[1].modifiable }"),
    "back in the prompt, buffer unlocked")
  eq({ removed = {}, added = {} }, lua("return diff_view()"), "diff gone")
  keys("<Esc>qu")
  eq(ORIGINAL, buffer(), "after one undo")
end)

test("review_edits: the discard key (configurable) leaves the buffer as it was; Claude is told", function()
  local log = setup({ "EDIT\n  a()\n", "ANSWER\nok" }, 0, { review_edits = true, discard_key = "<leader>d" })
  local before = lua("return { vim.fn.changenr(), vim.bo.modified }")
  ask()
  keys("go<CR>")
  wait("return reviewing()", "the diff")
  keys(" d")
  eq(ORIGINAL, buffer())
  eq(before, lua("return { vim.api.nvim_buf_call(1, vim.fn.changenr), vim.bo[1].modified }"), "undo state and modified")
  eq({ true, 1 }, { lua("return vim.bo[1].modifiable"), marks() }, "unlocked, only the selection highlight left")
  eq({ "  ❯ go", "    edit discarded", "" }, turns())
  eq({ "float-claude", "i" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "back in the prompt")
  keys("and now?<CR>")
  wait("return answered(2)", "the answer")
  local msg = sent(log)[3]
  assert(vim.startswith(msg, 'Since your last reply:\n- Your EDIT for "go" was discarded: the code stayed as it was.\n'
    .. "The current version of the code"), msg)
  assert(msg:find("<selection>\n" .. table.concat(ORIGINAL, "\n", 2, 6) .. "\n</selection>\nRequest: and now?", 1, true), msg)
end)

test("review_edits: new lines stream into the diff; old lines not reached yet stay plain", function()
  setup({ "EDIT\n  a()\n  b()\n" }, 300, { review_edits = true })
  ask()
  keys("go<CR>")
  wait("return #diff_view().added > 0", "the first line")
  eq({ removed = {}, added = { { 1, true, { "  a()" } } } }, lua("return diff_view()"), "while streaming")
  eq(ORIGINAL, buffer(), "nothing written")
  wait("return reviewing()", "the diff")
  eq({ removed = { 1, 2, 3, 4, 5 }, added = { { 5, false, { "  a()", "  b()" } } } }, lua("return diff_view()"), "done")
end)

test("review_edits: lines added above buffer line 1 show on screen", function()
  setup({ "EDIT\n-- header\nfunction f(nums)\n  for i = 1, #nums do\n    for j = i + 1, #nums do\n" }, 0,
    { review_edits = true })
  keys("1GV2j ai")
  keys("add a header<CR>")
  wait("return reviewing()", "the diff")
  eq({ removed = {}, added = { { 0, true, { "-- header" } } } }, lua("return diff_view()"), "the added line")
  eq({ "-- header", "function f(nums)" }, lua([[
    vim.cmd.redraw()
    local rows = {}
    for row = 1, 2 do
      local s = ""
      for col = 5, 20 do s = s .. vim.fn.screenstring(row, col) end
      table.insert(rows, vim.trim(s))
    end
    return rows
  ]]), "screen rows 1-2")
end)

test("review_edits: reloading the buffer from disk discards the diff", function()
  setup({ "EDIT\n  a()\n" }, 0, { review_edits = true })
  vim.rpcrequest(chan, "nvim_ui_try_resize", 100, 24) -- room for the whole error
  local file = vim.fn.tempname() .. ".lua"
  lua("vim.cmd.write(...)", file)
  ask()
  keys("go<CR>")
  wait("return reviewing()", "the diff")
  vim.fn.writefile({ "-- changed outside" }, file)
  lua("vim.o.autoread = true; vim.cmd.checktime()")
  wait("return not reviewing() and vim.bo[1].modifiable", "the review to end")
  eq("float-claude: the buffer changed during the review; the edit was discarded", last_message())
  eq({ removed = {}, added = {} }, lua("return diff_view()"), "diff gone")
  keys("<Esc> yy")
  eq({ "-- changed outside" }, buffer(), "the reloaded text is kept")
  vim.fn.delete(file)
end)

test("review_edits: closing the popup discards the diff", function()
  setup({ "EDIT\n  a()\n" }, 0, { review_edits = true })
  ask()
  keys("go<CR>")
  wait("return reviewing()", "the diff")
  keys("q")
  eq(ORIGINAL, buffer())
  eq({ 1, 0, true, "n" }, { #lua("return vim.api.nvim_list_wins()"), marks(), lua("return vim.bo[1].modifiable"),
    lua("return vim.fn.mode()") })
end)

test("review_edits: the diff streams on after leaving the popup; back in it, <leader>yy accepts", function()
  setup({ "EDIT\n  a()\n  b()\n  c()\n" }, 150, { review_edits = true })
  ask()
  keys("go<CR>")
  wait("return #diff_view().added > 0", "the first line")
  lua("vim.api.nvim_set_current_win(1000)")
  wait("return reviewing()", "the diff")
  eq({ 1000, "n", 3 }, lua("return { vim.api.nvim_get_current_win(), vim.fn.mode(), #vim.api.nvim_list_wins() }"),
    "focus stays in the code, the popup on screen")
  eq(ORIGINAL, buffer(), "nothing written yet")
  keys(" ai")
  eq({ "float-claude-transcript", "n" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "back in the conversation")
  keys(" yy")
  eq({ "function f(nums)", "  a()", "  b()", "  c()", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 5, false)"))
end)

test("block edit: each line's columns are replaced, a short line padded out to them; one u undoes it", function()
  local log = setup({ "EDIT\nqux\nquux\nnew\nzap\n", "ANSWER\nok" })
  lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = foo(1)", "y = bar(2)", "z", "w = baz(3)", "end" })]])
  keys("1G04l<C-v>3j2l ai")
  eq("  [No Name] · L1–4 · 4 lines · block", floats()["float-claude-transcript"].lines[2], "the header")
  local sel = lua([[
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true })) do
      if m[4].hl_group == "FloatClaudeSelection" then table.insert(out, { m[2], m[3], m[4].end_col }) end
    end
    return out
  ]])
  eq({ { 0, 4, 7 }, { 1, 4, 7 }, { 3, 4, 7 } }, vim.tbl_filter(function(m)
    return m[3] > m[2]
  end, sel), "the block's parts are highlighted")
  keys("rename<CR>")
  wait("return answered(1)", "the edit")
  eq({ "x = qux(1)", "y = quux(2)", "z   new", "w = zap(3)", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, -1, false)"))
  eq({ "  ❯ rename", "    refactored 4 → 4 lines · u to undo", "" }, turns())
  keys("and now?<CR>")
  wait("return answered(2)", "the answer")
  local s = sent(log)
  assert(s[2]:find("Selected: a block, a column range in lines 1-4 (each line below is the selected part of one line of it, "
    .. "in order):\n<selection>\nfoo\nbar\n\nbaz\n</selection>\nRequest: rename", 1, true), s[2])
  assert(s[3]:find("<selection>\nqux\nquux\n   new\nzap\n</selection>\nRequest: and now?", 1, true), "the follow-up: the new parts")
  keys("<Esc>qu")
  eq({ "x = foo(1)", "y = bar(2)", "z", "w = baz(3)", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, -1, false)"),
    "after one undo")
end)

test("block edit: a $ block goes to each line's end; a row the reply leaves out is emptied, lines past them added", function()
  local log = setup({ "EDIT\nx)\n", "EDIT\na)\nb)\nc)\nd\n" })
  lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "call(a, 1)", "call(bb, 22)", "call(ccc, 333)", "end" })]])
  keys("1G05l<C-v>2j$ ai")
  keys("one<CR>")
  wait("return answered(1)", "the edit")
  assert(sent(log)[2]:find("<selection>\na, 1)\nbb, 22)\nccc, 333)\n</selection>", 1, true), sent(log)[2])
  eq({ "call(x)", "call(", "call(", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, -1, false)"))
  keys("two<CR>")
  wait("return answered(2)", "the edit")
  eq({ "call(a)", "call(b)", "call(c)", "d", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, -1, false)"))
end)

-- The pending ranges in buffer 1: { row, end row, label } each.
local function pending()
  return lua([[
    local out = {}
    local ns = vim.api.nvim_create_namespace("float-claude-ranges")
    local labels = vim.api.nvim_create_namespace("float-claude-range-labels")
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(1, ns, 0, -1, { details = true })) do
      table.insert(out, { m[2], m[4].end_row })
    end
    for i, m in ipairs(vim.api.nvim_buf_get_extmarks(1, labels, 0, -1, { details = true })) do
      out[i][3] = m[4].virt_text[1][1]
    end
    return out
  ]])
end

test("ranges: <leader>am collects ranges, numbered in file order; one sharing lines is refused; <leader>ax clears", function()
  setup({})
  keys("10GVj am")
  keys("2G am")
  eq({ { 1, 2, " range 1" }, { 9, 11, " range 2" } }, pending(), "highlighted and numbered")
  keys("1GVj am")
  eq("float-claude: not added: it shares lines with range 1", last_message())
  eq(2, #pending(), "not added")
  lua("vim.cmd.enew()")
  keys(" am")
  eq("float-claude: not added: the collected ranges are in [No Name]", last_message(), "another buffer")
  lua("vim.cmd.buffer(1)")
  keys(" ax")
  eq({}, pending(), "cleared")
  keys(":4,5FloatClaudeAdd<CR>")
  eq({ { 3, 5, " range 1" } }, pending(), ":FloatClaudeAdd")
end)

test("ranges: one reply edits several ranges in place, each by its number; one u undoes them all", function()
  local log = setup({
    "EDIT\n@@ range 2 @@\n-- ten\n-- eleven\n-- more\n@@ range 1 @@\n  for _, a in ipairs(nums) do\n",
    "ANSWER\nok",
  })
  keys("2GVj am")
  keys("10GVj ai")
  eq("  [No Name] · L2–3, L10–11 · 2 ranges", floats()["float-claude-transcript"].lines[2], "the header")
  eq({}, pending(), "the chat took the collected ranges")
  keys("go<CR>")
  wait("return answered(1)", "the edit")
  eq({ "function f(nums)", "  for _, a in ipairs(nums) do", "      print(i, j)", "    end", "  end", "end", "-- 8", "-- 9",
    "-- ten", "-- eleven", "-- more", "-- 12" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 12, false)"))
  eq({ "  [No Name] · L2, L9–11 · 2 ranges", "  ❯ go", "    refactored ranges 1, 2 · u to undo" },
    vim.list_slice(floats()["float-claude-transcript"].lines, 2, 4), "the ranges follow the edit")
  keys("and now?<CR>")
  wait("return answered(2)", "the answer")
  local s = sent(log)
  assert(s[2]:find("Selected ranges (2), numbered in file order:\nRange 1: lines 2-3:\n<range 1>\n"
    .. "  for i = 1, #nums do\n    for j = i + 1, #nums do\n</range 1>\nRange 2: lines 10-11:\n<range 2>\n-- 10\n-- 11\n</range 2>\n",
    1, true), s[2])
  assert(s[3]:find('#1 "go": range 1 (lines 2-3) became line 2, range 2 (lines 10-11) became lines 9-11\n', 1, true), s[3])
  assert(s[3]:find("<range 1>\n  for _, a in ipairs(nums) do\n</range 1>\nRange 2: lines 9-11:\n<range 2>\n-- ten\n-- eleven\n"
    .. "-- more\n</range 2>\nRequest: and now?", 1, true), "the follow-up: every range as it is now")
  keys("<Esc>qu")
  eq(ORIGINAL, buffer(), "after one undo")
  eq({ "-- 10", "-- 11" }, lua("return vim.api.nvim_buf_get_lines(1, 9, 11, false)"), "range 2 too")
end)

test("ranges: review_edits shows a diff per range, a block's too; one accept writes all; one u undoes it", function()
  setup({ "EDIT\n@@ range 2 @@\nX\nY\n@@ range 1 @@\n  a()\n" }, 0, { review_edits = true })
  keys("2GVj am")
  keys("10G03l<C-v>j1l am")
  keys(" ai")
  keys("go<CR>")
  wait("return reviewing()", "the diff")
  eq(ORIGINAL, buffer(), "nothing written yet")
  eq({ removed = { 1, 2, 9, 10 }, added = { { 2, false, { "  a()" } }, { 10, false, { "-- X", "-- Y" } } } },
    lua("return diff_view()"), "a diff per range")
  eq({ "  ❯ go", "    review: ranges 1, 2", "    <leader>yy accept · <leader>nn discard", "" }, turns())
  keys(" yy")
  eq({ "-- 8", "-- 9", "-- X", "-- Y", "-- 12" }, lua("return vim.api.nvim_buf_get_lines(1, 6, 11, false)"))
  eq("  a()", lua("return vim.api.nvim_buf_get_lines(1, 1, 2, false)[1]"))
  eq({ "  ❯ go", "    refactored ranges 1, 2 · u to undo", "" }, turns())
  keys("<Esc>qu")
  eq(ORIGINAL, buffer(), "after one undo")
  eq({ "-- 10", "-- 11" }, lua("return vim.api.nvim_buf_get_lines(1, 9, 11, false)"), "range 2 too")
end)

test("ranges: an action is about the collected ranges and the selection", function()
  local log = setup({ "ANSWER\nok" })
  keys("2G am")
  keys("10GVj ae")
  wait("return answered(1)", "the answer")
  local msg = sent(log)[2]
  assert(msg:find("Range 1: line 2:\n<range 1>\n  for i = 1, #nums do\n</range 1>\nRange 2: lines 10-11:", 1, true), msg)
  assert(vim.endswith(msg, "Request: Explain what this code does."), msg)
end)

test("answer: a screen narrower than the popup caps its width and still wraps", function()
  setup({ "ANSWER\nok then" })
  vim.rpcrequest(chan, "nvim_ui_try_resize", 12, 24) -- the narrowest Neovim allows
  ask()
  eq({ 0, 12 }, { floats()["float-claude"].col, floats()["float-claude"].width }, "capped width")
  keys("hello you<CR>")
  wait("return answered(1)", "the answer")
  eq({ "", "  [No Name…", "  ❯ hello", "    you", "    ok then", "" }, floats()["float-claude-transcript"].lines)
end)

test("answer: streams into the popup, then a fresh input; history is read-only", function()
  local log = setup({ "ANSWER\nO(n^2): the nested loops compare every pair. Space is O(1)." })
  ask()
  keys("what's the time complexity?<CR>")
  wait("return answered(1)", "the answer")
  local f = floats()
  eq({
    "",
    "  [No Name] · L2–6 · 5 lines",
    "  ❯ what's the time complexity?",
    "    O(n^2): the nested loops compare every pair.",
    "    Space is O(1).",
    "",
  }, f["float-claude-transcript"].lines)
  eq(50, f["float-claude-transcript"].width, "chat width")
  eq(f["float-claude-transcript"].row + 6, f["float-claude"].row, "input right below the transcript")
  -- The question is dimmed, its ❯ is not.
  local hl = lua([[
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "float-claude-transcript" then
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })) do
          table.insert(out, { m[2], m[3], m[4].hl_group })
        end
      end
    end
    return out
  ]])
  eq({ { 1, 0, "FloatClaudeHeader" }, { 2, 0, "FloatClaudeHistory" }, { 2, 2, "FloatClaudePrompt" } }, hl, "highlights")
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
  eq({ "<start>", true }, { s[1], vim.endswith(s[3], "Request: can it be O(n)?") }, "one process, a follow-up")
  eq({
    "  ❯ complexity?",
    "    O(n^2).",
    "",
    "  ❯ can it be O(n)?",
    "    Yes, with a hash map.",
    "",
  }, turns())
end)

test("a follow-up can edit the original selection", function()
  setup({ "ANSWER\nIt loops twice.", "EDIT\n  print(#nums)\n" })
  ask()
  keys("explain<CR>")
  wait("return answered(1)", "the answer")
  keys("simplify it<CR>")
  wait("return answered(2)", "the edit")
  eq({ "function f(nums)", "  print(#nums)", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 3, false)"))
  eq({ "  ❯ explain", "    It loops twice.", "", "  ❯ simplify it", "    refactored 5 → 1 lines · u to undo", "" },
    turns())
end)

test("after an edit, a follow-up edit works on the edited lines; each is one undo", function()
  local log = setup({ "EDIT\n  a()\n  b()\n", "EDIT\n  c()\n" })
  ask()
  keys("go<CR>")
  wait("return answered(1)", "the first edit")
  keys("also merge them<CR>")
  wait("return answered(2)", "the second edit")
  eq({ "function f(nums)", "  c()", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 3, false)"))
  assert(sent(log)[3]:find("Selected lines 2-3:\n<selection>\n  a()\n  b()\n</selection>\nRequest: also merge them", 1, true),
    "the follow-up carries the edited lines")
  keys("<Esc>q")
  keys("u")
  eq({ "function f(nums)", "  a()", "  b()", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 4, false)"))
  keys("u")
  eq(ORIGINAL, buffer(), "after two undos")
end)

test("a follow-up sends the code as it is now: after an edit, hand edits and a line added above", function()
  local log = setup({ "EDIT\n  a()\n  b()\n", "ANSWER\nok" })
  ask()
  keys("go<CR>")
  wait("return answered(1)", "the edit")
  keys("<C-o>")
  keys("3GA -- by hand<Esc>ggOtop<Esc>")
  keys(" ai")
  eq("  [No Name] · L3–4 · 2 lines", floats()["float-claude-transcript"].lines[2], "the header follows")
  keys("and now?<CR>")
  wait("return answered(2)", "the answer")
  local msg = sent(log)[3]
  assert(msg:find("\nThe current version of the code (it replaces every earlier version):\n", 1, true), msg)
  assert(msg:find("<context>\ntop\nfunction f(nums)\n  a()\n  b() -- by hand\nend\n", 1, true), msg)
  assert(msg:find("Selected lines 3-4:\n<selection>\n  a()\n  b() -- by hand\n</selection>\nRequest: and now?", 1, true), msg)
end)

-- What a sent message says before the code: the change record and the edits list.
local function record(msg)
  return msg:match("^(.-)\n?The current version of the code") or msg
end

test("change history: two edits, a discard and a hand edit; Claude's changes listed apart from the user's", function()
  local log = setup({ "EDIT\n  a()\n", "EDIT\n  a()\n  b()\n", "EDIT\n  c()\n", "ANSWER\nTwo." }, 0, { review_edits = true })
  ask()
  for _, step in ipairs({ { "first", " yy" }, { "second", " yy" }, { "third", " nn" } }) do
    keys(step[1] .. "<CR>")
    wait("return reviewing()", "the diff for " .. step[1])
    keys(step[2])
  end
  keys("<C-o>")
  keys("3GA -- mine<Esc>")
  keys(" ai")
  keys("what did you change?<CR>")
  wait("return answered(4)", "the answer")
  local s = sent(log)
  eq(table.concat({
    "Since your last reply:",
    '- Your EDIT for "first" (edit #1) was accepted and applied:',
    "<diff>",
    "@@ -1,8 +1,4 @@",
    " function f(nums)",
    "-  for i = 1, #nums do",
    "-    for j = i + 1, #nums do",
    "-      print(i, j)",
    "-    end",
    "-  end",
    "+  a()",
    " end",
    " -- 8",
    "</diff>",
    "Your edits applied in this conversation so far (each diff was sent once, when it was applied):",
    '#1 "first": lines 2-6 became line 2',
  }, "\n"), record(s[3]))
  eq(table.concat({
    "Since your last reply:",
    '- Your EDIT for "second" (edit #2) was accepted and applied:',
    "<diff>",
    "@@ -1,4 +1,5 @@",
    " function f(nums)",
    "   a()",
    "+  b()",
    " end",
    " -- 8",
    "</diff>",
    "Your edits applied in this conversation so far (each diff was sent once, when it was applied):",
    '#1 "first": lines 2-6 became line 2',
    '#2 "second": line 2 became lines 2-3',
  }, "\n"), record(s[4]))
  eq(table.concat({
    "Since your last reply:",
    '- Your EDIT for "third" was discarded: the code stayed as it was.',
    "- I changed the code myself:",
    "<diff>",
    "@@ -1,5 +1,5 @@",
    " function f(nums)",
    "   a()",
    "-  b()",
    "+  b() -- mine",
    " end",
    " -- 8",
    "</diff>",
    "Your edits applied in this conversation so far (each diff was sent once, when it was applied):",
    '#1 "first": lines 2-6 became line 2',
    '#2 "second": line 2 became lines 2-3',
  }, "\n"), record(s[5]))
  assert(s[5]:find("<selection>\n  a()\n  b() -- mine\n</selection>\nRequest: what did you change?", 1, true), s[5])
  assert(s[5]:find("<context>\nfunction f(nums)\n  a()\n  b() -- mine\nend\n", 1, true), s[5])
end)

test("change history: unchanged context is not sent again; changes far from the selection are counted", function()
  local log = setup({ "ANSWER\nok", "ANSWER\nok", "ANSWER\nok" })
  lua("for i = 41, 60 do vim.api.nvim_buf_set_lines(1, -1, -1, false, { '-- ' .. i }) end")
  ask()
  keys("one<CR>")
  wait("return answered(1)", "the first answer")
  keys("two<CR>")
  wait("return answered(2)", "the second answer")
  keys("<C-o>")
  lua("vim.api.nvim_buf_set_lines(1, 59, 60, false, { '-- far' })")
  keys(" ai")
  keys("three<CR>")
  wait("return answered(3)", "the third answer")
  local s = sent(log)
  assert(s[2]:find("Lines 1-46 of the file, for context:\n<context>\n", 1, true), s[2])
  eq("The current version of the code (it replaces every earlier version):\nFile: [No Name] (filetype: lua)\n"
    .. "Lines 1-46 of the file, for context: unchanged since my last message.\nSelected lines 2-6:",
    s[3]:match("^(.-)\n<selection>"))
  eq("Since your last reply:\n- I also changed the file in 1 place(s) away from these lines (not shown).", record(s[4]))
  assert(s[4]:find("Lines 1-46 of the file, for context: unchanged since my last message.", 1, true), s[4])
end)

test("leaving the popup while an edit streams: the edit finishes, the popup stays", function()
  setup({ "EDIT\n  a()\n  b()\n  c()\n" }, 150)
  ask()
  keys("go<CR>")
  wait("return vim.api.nvim_buf_get_lines(1, 1, 2, false)[1] == '  a()'", "the first line")
  lua("vim.api.nvim_set_current_win(1000)")
  wait("return vim.tbl_contains(transcript(), '    refactored 5 → 3 lines · u to undo')", "the edit")
  eq({ "function f(nums)", "  a()", "  b()", "  c()", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 5, false)"))
  eq({ 1000, "n", 3 }, lua("return { vim.api.nvim_get_current_win(), vim.fn.mode(), #vim.api.nvim_list_wins() }"),
    "focus stays in the code, the popup on screen")
  keys("u")
  eq(ORIGINAL, buffer(), "after one undo")
  eq(3, #lua("return vim.api.nvim_list_wins()"), "still open")
end)

test("Esc in the code while an edit streams with the popup hidden leaves both alone", function()
  setup({ "EDIT\n  a()\n  b()\n  c()\n" }, 150)
  ask()
  keys("go<CR>")
  wait("return vim.api.nvim_buf_get_lines(1, 1, 2, false)[1] == '  a()'", "the first line")
  keys("<C-q>")
  eq({ 1000, {} }, { lua("return vim.api.nvim_get_current_win()"), floats() }, "hidden, in the code")
  keys("<Esc>")
  wait("return vim.tbl_contains(transcript(), '    refactored 5 → 3 lines · u to undo')", "the edit")
  eq({ "function f(nums)", "  a()", "  b()", "  c()", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 5, false)"))
  keys(" ai")
  eq({ "float-claude", "i" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "the popup comes back")
end)

for _, review in ipairs({ false, true }) do
  local what = review and "a diff waits" or "an edit streams"
  test("unloading the source buffer while " .. what .. " ends the conversation", function()
    setup({ "EDIT\n  a()\n" }, 300, { review_edits = review })
    ask()
    keys("go<CR>")
    wait(review and "return reviewing()" or "return vim.tbl_contains(transcript(), '    refactoring…')", "the edit")
    lua("vim.api.nvim_set_current_win(1000)")
    lua("vim.cmd('bdelete! 1')")
    lua("vim.wait(500)")
    eq({ 1, false, "" }, { #lua("return vim.api.nvim_list_wins()"), lua("return vim.api.nvim_buf_is_loaded(1)"),
      lua("return vim.v.errmsg") }, "closed, no errors")
  end)
end

test("answer: the tag may share its line with the answer, split across deltas", function()
  setup({ { "ANS", "WER It loops", " twice.\nThen", " stops." }, "ANSWER Yes." })
  ask()
  keys("explain<CR>")
  wait("return answered(1)", "the first answer")
  keys("sure?<CR>")
  wait("return answered(2)", "the second answer")
  eq({
    "  ❯ explain",
    "    It loops twice.",
    "    Then stops.",
    "",
    "  ❯ sure?",
    "    Yes.",
    "",
  }, turns())
end)

-- An LSP server in the child, attached to buffer 1 (named demo.lua): `defs`
-- maps a name to its definition { line, character } (both 0-based) and
-- answers textDocument/definition for the name at the given position; `symbols`
-- does the same for workspace/symbol. Hover shows "hover: <name>".
local function fake_lsp(defs, symbols)
  lua([[
    local defs, symbols = ...
    vim.api.nvim_buf_set_name(1, vim.fn.getcwd() .. "/demo.lua")
    local function location(uri, at)
      return { uri = uri, range = { start = { line = at[1], character = at[2] }, ["end"] = { line = at[1], character = at[2] } } }
    end
    vim.lsp.start({ name = "fake", cmd = function()
      local closing, id = false, 0
      return {
        request = function(method, params, callback)
          id = id + 1
          local result = vim.NIL
          local name
          if params and params.position then
            local line = vim.api.nvim_buf_get_lines(1, params.position.line, params.position.line + 1, false)[1]
            name = line:sub(params.position.character + 1):match("^[%w_]+")
          end
          if method == "initialize" then
            result = { capabilities = { definitionProvider = true, hoverProvider = true, workspaceSymbolProvider = true } }
          elseif method == "textDocument/definition" then
            result = defs[name] and location(params.textDocument.uri, defs[name]) or {}
          elseif method == "workspace/symbol" then
            local at = symbols[params.query]
            result = at and { { name = params.query, kind = 12, location = location(vim.uri_from_bufnr(1), at) } } or {}
          elseif method == "textDocument/hover" then
            result = { contents = { kind = "markdown", value = "hover: " .. name } }
          end
          vim.schedule(function() callback(nil, result) end)
          return true, id
        end,
        notify = function(method)
          closing = closing or method == "exit"
          return true
        end,
        is_closing = function() return closing end,
        terminate = function() closing = true end,
      }
    end }, { bufnr = 1 })
  ]], defs, symbols)
end

-- The transcript's highlights as { row (1-based), text under it, group }.
local function transcript_hls()
  return lua([[
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "float-claude-transcript" then
        local out = {}
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, 0, -1, { details = true })) do
          local line = vim.api.nvim_buf_get_lines(b, m[2], m[2] + 1, false)[1]
          table.insert(out, { m[2] + 1, line:sub(m[3] + 1, m[4].end_col), m[4].hl_group })
        end
        return out
      end
    end
  ]])
end

local CODE_ANSWER = "ANSWER\nUse `f` with `nums`; `missing` is unknown.\n```lua\nlocal n = f(nums)\n```\n"

test("answer: inline code and code blocks show without backticks and fences, highlighted", function()
  setup({ CODE_ANSWER })
  ask()
  keys("explain<CR>")
  wait("return answered(1)", "the answer")
  eq({ "  ❯ explain", "    Use f with nums; missing is unknown.", "    local n = f(nums)", "" }, turns())
  local hls = transcript_hls()
  local function has(entry)
    return vim.iter(hls):any(function(h)
      return vim.deep_equal(h, entry)
    end)
  end
  for _, span in ipairs({ "f", "nums", "missing" }) do
    assert(has({ 4, span, "FloatClaudeCode" }), "inline code " .. span .. ": " .. vim.inspect(hls))
  end
  assert(has({ 5, "local", "@keyword.lua" }), "the code block, in the source's language: " .. vim.inspect(hls))
  eq(false, vim.iter(hls):any(function(h)
    return h[3] == "FloatClaudeLink"
  end), "no LSP, no links")
  eq("", lua("return vim.v.errmsg"), "no errors")
end)

test("answer: a fence names the language; code too long for a row is cut, not wrapped at words", function()
  setup()
  local function render(text, done)
    return lua([[return require("float-claude.answer").render(..., { width = 20, done = ]] .. tostring(done)
      .. [[, cache = {}, tabstop = 8 })]], text)
  end
  eq({ { text = "say `hi", hls = {}, names = {} } }, render("say `hi", true), "an unclosed backtick is text")
  eq({ { text = "say hi", hls = { { 4, 6, "FloatClaudeCode", 90 } }, names = {} } }, render("say `hi", false),
    "unless the line is still streaming")
  local rows = lua([[return require("float-claude.answer").render(
    "a `x y` b\n```vim\nlet g:abc = 1\n```", { width = 6, lang = "lua", done = true, cache = {}, tabstop = 8 })]])
  eq({ "a x y", "b", "let g:", "abc = ", "1" }, vim.tbl_map(function(r)
    return r.text
  end, rows), "rows")
  eq({ { 2, 5, "FloatClaudeCode", 90 } }, vim.tbl_filter(function(h)
    return h[3] == "FloatClaudeCode"
  end, rows[1].hls), "the span, spaces included")
  eq("@keyword.vim", rows[3].hls[1][3], "highlighted as the fence's language")
end)

test("answer: names resolve through LSP; <CR> or a click jumps to the definition, K shows hover", function()
  setup({ CODE_ANSWER })
  -- nums: a definition at its occurrence in the selection; f: none there, a workspace symbol.
  fake_lsp({ nums = { 0, 11 } }, { f = { 0, 9 } })
  ask()
  keys("explain<CR>")
  wait("return answered(1)", "the answer")
  local function links()
    return vim.tbl_filter(function(h)
      return h[3] == "FloatClaudeLink"
    end, transcript_hls())
  end
  for _ = 1, 50 do
    if #links() == 4 then
      break
    end
    lua("vim.wait(20)")
  end
  eq({ { 4, "f" }, { 4, "nums" }, { 5, "f" }, { 5, "nums" } }, vim.tbl_map(function(h)
    return { h[1], h[2] }
  end, links()), "underlined names; missing and n stay plain")
  keys("<C-\\><C-n><C-w>w")
  eq("float-claude-transcript", lua("return vim.bo.filetype"), "in the conversation")
  lua("vim.api.nvim_win_set_cursor(0, { 4, 15 })") -- on nums
  keys("K")
  wait([[return vim.iter(vim.api.nvim_list_wins()):any(function(w)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)[1] == "hover: nums"
  end)]], "the hover window")
  keys("<CR>")
  eq({ 1000, { 1, 11 }, "n" }, lua("return { vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0), vim.fn.mode() }"),
    "at the definition, in the code window")
  local t = floats()["float-claude-transcript"]
  assert(t, "the popup stays")
  lua("vim.api.nvim_win_set_cursor(0, { 3, 0 })")
  -- Click on the f in the code block: row 5 of the transcript, column 14.
  vim.rpcrequest(chan, "nvim_input_mouse", "left", "press", "", 0, t.row + 4, t.col + 14)
  vim.rpcrequest(chan, "nvim_input_mouse", "left", "release", "", 0, t.row + 4, t.col + 14)
  lua("")
  wait("return vim.api.nvim_get_current_win() == 1000 and vim.api.nvim_win_get_cursor(0)[2] == 9", "the jump to f")
  eq({ 1, 9 }, lua("return vim.api.nvim_win_get_cursor(0)"), "at f's definition")
  eq("", lua("return vim.v.errmsg"), "no errors")
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
  keys("1GV ai") -- 22 rows of room
  keys("first<CR>")
  wait("return answered(1)", "the first answer")
  keys("second<CR>")
  wait("return vim.api.nvim_buf_line_count(0) > 26", "the second answer to start")
  local t = floats()["float-claude-transcript"]
  eq("  ❯ second", t.lines[25], "question line")
  eq(25, t.top, "the new question sits at the top")
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
  eq("  ❯ second", floats()["float-claude-transcript"].lines[top], "the question sits at the top")
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

test("the unfocus key leaves the popup on screen over other files and splits; <leader>ai comes back", function()
  setup()
  ask()
  keys("abc")
  local before = floats()
  keys("<C-o>")
  eq({ 1000, "n", { 6, 0 } }, lua("return { vim.api.nvim_get_current_win(), vim.fn.mode(), vim.api.nvim_win_get_cursor(0) }"),
    "in the code, cursor put")
  lua("vim.cmd('vsplit | enew')")
  eq(before, floats(), "the popup stays where it was")
  eq(1, marks(), "the selection stays highlighted")
  keys(" ai")
  eq({ "float-claude", "i", { "abc" }, 4 }, lua([[return { vim.bo.filetype, vim.fn.mode(),
    vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.fn.col(".") }]]), "back in the prompt, after the text")
  eq(false, lua("return pcall(vim.cmd.edit, 'other.txt')"), "files do not open in the popup")
  keys("<Esc>q")
  eq({ 2, 0, 2 }, { #lua("return vim.api.nvim_list_wins()"), marks(), #lua("return vim.api.nvim_list_bufs()") },
    "closed, back in the new window")
  eq(false, lua("return vim.api.nvim_get_current_win() == 1000"), "the window <leader>ai was pressed in")
end)

test("the hide key hides the popup; the answer streams on; <leader>ai shows it at the same scroll", function()
  local long = {}
  for i = 1, 25 do
    long[i] = "line " .. i
  end
  setup({ "ANSWER\n" .. table.concat(long, "\n"), "ANSWER\n" .. table.concat(long, "\n") }, 20)
  keys("1GV ai")
  keys("first<CR>")
  wait("return answered(1)", "the first answer")
  keys("<C-u>")
  local scrolled = floats()["float-claude-transcript"].top
  keys("<C-q>")
  eq({}, floats(), "hidden")
  eq({ 1000, "n", { 1, 0 } }, lua("return { vim.api.nvim_get_current_win(), vim.fn.mode(), vim.api.nvim_win_get_cursor(0) }"),
    "in the code, cursor put")
  eq(false, lua("vim.cmd.wincmd('w') return vim.api.nvim_get_current_win() ~= 1000"), "<C-w>w skips it")
  keys(" ai")
  eq({ scrolled, "float-claude", "i" }, { floats()["float-claude-transcript"].top, lua("return vim.bo.filetype"),
    lua("return vim.fn.mode()") }, "same view, back in the prompt")
  keys("second<CR>")
  wait("return vim.api.nvim_buf_line_count(0) > 30", "the second answer to start")
  keys("<C-q>")
  -- Once answered, the (hidden) prompt is two rows high again: the prompt and padding.
  wait([[return vim.iter(vim.api.nvim_list_wins()):any(function(w)
    return vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "float-claude" and vim.api.nvim_win_get_height(w) == 2
  end)]], "the second answer to end")
  eq({ {}, 1000, "n" }, { floats(), lua("return vim.api.nvim_get_current_win()"), lua("return vim.fn.mode()") },
    "still hidden, focus not taken")
  keys(" ai")
  local t = floats()["float-claude-transcript"]
  eq({ #t.lines - t.height + 1, "float-claude", "i" }, { t.top, lua("return vim.bo.filetype"), lua("return vim.fn.mode()") },
    "following the newest line, back in the prompt")
end)

test("hide, come back and unfocus with a config like the author's (no mouse, Esc saves, scrolloff)", function()
  setup()
  -- From the author's Neovim config: options and mappings that touch these keys.
  lua([[
    vim.o.mouse = ""
    vim.o.scrolloff = 16
    vim.o.relativenumber = true
    vim.keymap.set("n", "<Esc>", "<cmd>if &buftype == '' | w | endif<CR>", { desc = "Save" })
    vim.keymap.set("n", "<C-a>", "ggVG")
    for _, key in ipairs({ "<Up>", "<Down>", "<Left>", "<Right>" }) do vim.keymap.set({ "", "i" }, key, "") end
  ]])
  ask()
  keys("hello<C-q>")
  eq({ {}, 1000, "n" }, { floats(), lua("return vim.api.nvim_get_current_win()"), lua("return vim.fn.mode()") }, "hidden")
  keys(" ai")
  eq({ "float-claude", "i", { "hello" } }, lua("return { vim.bo.filetype, vim.fn.mode(), vim.api.nvim_buf_get_lines(0, 0, -1, false) }"),
    "back in the prompt")
  local before = floats()
  keys("<C-o>")
  eq({ 1000, "n" }, lua("return { vim.api.nvim_get_current_win(), vim.fn.mode() }"), "in the code")
  keys("<Esc><C-w>v")
  eq(before, floats(), "on screen after Esc in the code and a split")
  keys(" ai<C-\\><C-n><C-w>w")
  eq("float-claude-transcript", lua("return vim.bo.filetype"), "<C-w>w reaches the conversation")
end)

test("<leader>ai on a new selection starts another chat; the open one is hidden, not ended", function()
  local log = setup({ "ANSWER\nok", "ANSWER\nfresh" })
  ask()
  keys("first<CR>")
  wait("return answered(1)", "the answer")
  keys("<C-o>")
  keys(" ai")
  eq({ "  ❯ first", "    ok", "" }, turns(), "Normal mode: the same chat")
  keys("<C-o>")
  keys("8GVj ai")
  eq({ "", "  [No Name] · L8–9 · 2 lines · 2/2" }, floats()["float-claude-transcript"].lines, "a fresh chat")
  eq({ 5, 2 }, { #lua("return vim.api.nvim_list_wins()"), marks() }, "the first one's windows and selection are kept")
  keys("again<CR>")
  wait("return answered(1)", "the answer")
  eq({ "<start>", "<start>" }, { sent(log)[1], sent(log)[3] }, "a new process")
end)

test(":q in the popup or wiping the buffer ends the conversation", function()
  setup()
  ask()
  keys("abc<C-\\><C-n>:q<CR>")
  eq({ 1, 0, 1 }, { #lua("return vim.api.nvim_list_wins()"), marks(), #lua("return vim.api.nvim_list_bufs()") })
  ask()
  keys("<C-o>")
  lua("vim.cmd('enew | bwipeout! 1')")
  eq({ 1, 1 }, { #lua("return vim.api.nvim_list_wins()"), #lua("return vim.api.nvim_list_bufs()") })
  keys(" ai")
  eq(3, #lua("return vim.api.nvim_list_wins()"), "a new chat opens")
end)

-- Highlight `name` as defined in namespace `ns` (0: global).
local function hl(name, ns)
  return lua("local ns, name = ... return vim.api.nvim_get_hl(ns, { name = name })", ns or 0, name)
end

-- The highlight namespace of each window, by its buffer's filetype ("lua" for the code).
local function hl_namespaces()
  return lua([[
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      out[vim.bo[vim.api.nvim_win_get_buf(w)].filetype] = vim.api.nvim_get_hl_ns({ winid = w })
    end
    return out
  ]])
end

test("theme auto (the default) follows the colorscheme, also on a change", function()
  setup()
  lua([[
    vim.cmd("hi clear | hi clear NormalFloat")
    vim.cmd("hi Normal guifg=#101010 guibg=#fafafa | hi Comment guifg=#777777 | hi Function guifg=#0000aa")
    vim.cmd("hi LineNr guifg=#bbbbbb | hi DiffAdd guibg=#ddffdd")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
  ]])
  ask()
  eq({ fg = 0x101010, bg = 0xeaeaea }, hl("FloatClaudeNormal"), "text, and the editor's background a little towards it")
  eq({ 0x0000aa, 0x777777, 0xbbbbbb, 0xddffdd }, { hl("FloatClaudePrompt").fg, hl("FloatClaudeHistory").fg,
    hl("FloatClaudeHeader").fg, hl("FloatClaudeAdded").bg }, "prompt, history, header, added")
  local ns = hl_namespaces()
  eq(true, ns["float-claude"] > 0 and ns["float-claude"] == ns["float-claude-transcript"], "the popup's own namespace")
  eq(-1, ns.lua, "not the code window")
  eq({ link = "FloatClaudeNormal" }, hl("Normal", ns["float-claude"]), "the popup's Normal")
  lua([[vim.cmd("hi NormalFloat guifg=#202020 guibg=#e0e0e0") vim.api.nvim_exec_autocmds("ColorScheme", {})]])
  eq({ fg = 0x202020, bg = 0xe0e0e0 }, hl("FloatClaudeNormal"), "the colorscheme's float colors, once it has them")
end)

test("themes: a preset and single colors restyle only the popup; :FloatClaudeTheme switches live", function()
  setup(nil, 0, { theme = "nord", colors = { bg = "#000000", keyword = "#123456" } })
  local keyword = hl("@keyword")
  lua([[vim.api.nvim_set_hl(0, "@function.method.call", { fg = "#010203" })]]) -- a colorscheme's specific group
  ask()
  eq({ fg = 0xd8dee9, bg = 0 }, hl("FloatClaudeNormal"), "nord with its bg overridden")
  local ns = hl_namespaces()["float-claude"]
  eq({ 0x123456, 0xa3be8c }, { hl("@keyword", ns).fg, hl("@string", ns).fg }, "code in answers: overridden, nord")
  eq(keyword, hl("@keyword"), "the rest of Neovim keeps its colors")
  eq({ "dracula" }, lua([[return vim.fn.getcompletion("FloatClaudeTheme dr", "cmdline")]]), "completion")
  lua("vim.cmd('FloatClaudeTheme dracula')")
  ns = hl_namespaces()["float-claude"]
  eq({ fg = 0xf8f8f2, bg = 0 }, hl("FloatClaudeNormal"), "dracula, the colors option still applies")
  eq({ 0x123456, 0xf1fa8c, 0x44475a }, { hl("@keyword", ns).fg, hl("@string", ns).fg, hl("FloatClaudeSelection").bg },
    "dracula's code colors and selection")
  eq(0x50fa7b, hl("@function.method.call", ns).fg, "the colorscheme's specific groups follow the theme too")
  eq(ns, hl_namespaces()["float-claude-transcript"], "both popup windows switched")
  lua("vim.cmd('FloatClaudeTheme float-claude')")
  eq({ 0x3fb5c9, 0x8a8a8a }, { hl("FloatClaudePrompt").fg, hl("FloatClaudeHistory").fg }, "the original look")
  ns = hl_namespaces()["float-claude"]
  eq({ {}, 0x123456 }, { hl("@string", ns), hl("@keyword", ns).fg },
    "without syntax colors it keeps the colorscheme's, but for the colors option")
  lua("vim.cmd('FloatClaudeTheme nope')")
  eq('float-claude: unknown theme "nope"', last_message())
  eq(0x3fb5c9, hl("FloatClaudePrompt").fg, "unchanged")
end)

-- The system prompt the fake CLI was started with.
local function system_prompt(log)
  wait("return logged(1)", "the CLI to start")
  local argv = vim.json.decode(vim.fn.readfile(log)[1]).argv -- an object: Lua's `arg` has an index 0
  for i = 1, vim.tbl_count(argv) do
    if argv[tostring(i)] == "--system-prompt" then
      return argv[tostring(i + 1)]
    end
  end
end

test("custom prompt: the prompt option and, opted in, the project's .float-claude.md reach Claude", function()
  local log = setup()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile({ "Prefer early returns.", "" }, dir .. "/.float-claude.md")
  lua("vim.api.nvim_buf_set_name(0, ...)", dir .. "/src/demo.lua")
  ask()
  eq(lua("return require('float-claude.claude').system_prompt"), system_prompt(log), "by default the file is not used")
  keys("<Esc>q")
  log = setup()
  lua([[require("float-claude").setup({ project_prompt = ".float-claude.md", prompt = function(ctx)
    return "Reply in " .. ctx.filetype .. " style."
  end })]])
  ask()
  local text = system_prompt(log)
  assert(vim.startswith(text, lua("return require('float-claude.claude').system_prompt")), "built-in rules first")
  assert(vim.endswith(text, "always comes first:\nReply in lua style.\n\nPrefer early returns."), text)
  keys("<Esc>q")
  log = setup(nil, 0, { prompt = false, project_prompt = false })
  ask()
  eq(lua("return require('float-claude.claude').system_prompt"), system_prompt(log), "only the built-in prompt")
  vim.fn.delete(dir, "rf")
end)

test("keys are setup options; false leaves one unmapped", function()
  local log = setup({ "ANSWER\nok" }, 0, {
    submit_key = "<C-s>", newline_keys = { "<C-l>" }, close_key = "Q", insert_keys = { "o" }, hide_key = false,
  })
  ask()
  keys("a<CR>b<C-l>c")
  eq({ "a", "b", "c" }, floats()["float-claude"].lines, "Enter and the newline key add lines")
  eq({ "", "" }, lua([[return { vim.fn.maparg("<C-q>", "i"), vim.fn.maparg("<Esc>", "i") }]]),
    "the hide key is unmapped, Esc too")
  keys("<C-s>")
  wait("return answered(1)", "the answer")
  eq("Request: a\nb\nc", sent(log)[2]:match("Request: .*$"), "sent with the submit key")
  keys("<Esc><C-w>wo")
  eq({ "float-claude", "i" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "an insert key")
  eq("", lua([[return vim.fn.maparg("q", "n")]]), "q is not the close key")
  keys("<Esc>Q")
  eq(1, #lua("return vim.api.nvim_list_wins()"), "closed")
end)

test("placement offsets and max_height", function()
  setup(nil, 0, { top_right_offset = { row = 2, col = 5 }, max_height = 5 })
  ask()
  local f = floats()
  eq({ 2, 25 }, { f["float-claude-transcript"].row, f["float-claude-transcript"].col }, "top right, offset")
  keys("a<C-j>b<C-j>c")
  f = floats()
  eq({ 1, 4 }, { f["float-claude-transcript"].height, f["float-claude"].height }, "capped: 6 rows in 5")
  keys("<Esc>q")
  setup(nil, 0, { placement = "cursor", cursor_offset = { row = 2, col = 0 } })
  ask()
  local cursor = lua("local p = vim.fn.screenpos(1000, 6, 1) return { p.row - 1, p.col - 1 }")
  f = floats()
  eq({ cursor[1] + 2, cursor[2] }, { f["float-claude-transcript"].row, f["float-claude-transcript"].col }, "at the cursor, offset")
end)

test("close_after_edit closes once the edit is applied; close_on_leave closes when leaving", function()
  setup({ "EDIT\n  a()\n" }, 0, { close_after_edit = true })
  ask()
  keys("go<CR>")
  wait("return #vim.api.nvim_list_wins() == 1", "the popup to close")
  eq({ "function f(nums)", "  a()", "end" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 3, false)"), "applied")
  eq({ "n", { 2, 2 } }, { lua("return vim.fn.mode()"), lua("return vim.api.nvim_win_get_cursor(0)") },
    "back on the new lines")
  wait("return #vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, {}) == 0", "the selection and the green flash to clear")
  setup({ "ANSWER\nok" }, 0, { close_on_leave = true })
  ask()
  keys("hi<CR>")
  wait("return answered(1)", "the answer")
  keys("<C-\\><C-n><C-w>w")
  eq(3, #lua("return vim.api.nvim_list_wins()"), "moving within the popup keeps it")
  keys("<C-o>")
  eq(3, #lua("return vim.api.nvim_list_wins()"), "the unfocus key keeps it")
  keys(" ai<C-\\><C-n><C-w>p")
  wait("return #vim.api.nvim_list_wins() == 1", "the popup to close")
end)

test("close_on_leave: focusing the hover window (K twice) keeps the popup", function()
  setup({ CODE_ANSWER }, 0, { close_on_leave = true })
  fake_lsp({ nums = { 0, 11 } }, {})
  ask()
  keys("explain<CR>")
  wait("return answered(1)", "the answer")
  keys("<C-\\><C-n><C-w>w")
  lua("vim.api.nvim_win_set_cursor(0, { 4, 15 })") -- on nums
  wait([[return vim.iter(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })):any(function(m)
    return m[4].hl_group == "FloatClaudeLink" and m[2] == 3
  end)]], "nums to be underlined")
  keys("K")
  wait([[return vim.iter(vim.api.nvim_list_wins()):any(function(w)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false)[1] == "hover: nums"
  end)]], "the hover window")
  keys("K")
  eq({ "hover: nums" }, lua("return vim.api.nvim_buf_get_lines(0, 0, 1, false)"), "the hover window has focus")
  lua("vim.wait(50)")
  assert(floats()["float-claude-transcript"], "the popup stays")
  keys("<C-w>p")
  lua("vim.wait(50)")
  assert(floats()["float-claude-transcript"], "back in the popup, it stays")
end)

local DIAGNOSTICS = [[
  _G.dns = vim.api.nvim_create_namespace("test-diagnostics")
  vim.diagnostic.set(dns, 1, {
    { lnum = 3, col = 6, message = "undefined global\nprint", severity = vim.diagnostic.severity.WARN, source = "lua_ls" },
    { lnum = 1, col = 2, message = "unused loop variable", severity = vim.diagnostic.severity.ERROR },
    { lnum = 20, col = 0, message = "far away", severity = vim.diagnostic.severity.ERROR },
  })
]]

test("diagnostics in the selected lines are sent, as they are at each message; diagnostics = false leaves them out", function()
  local log = setup({ "ANSWER\nok", "ANSWER\nok" })
  lua(DIAGNOSTICS)
  ask()
  keys("fix<CR>")
  wait("return answered(1)", "the answer")
  local msg = sent(log)[2]
  assert(msg:find("</selection>\nDiagnostics in the selected lines:\n- line 2: error: unused loop variable\n"
    .. "- line 4: warning: undefined global print (lua_ls)\nRequest: fix", 1, true), msg)
  lua("vim.diagnostic.reset(dns, 1)")
  keys("again<CR>")
  wait("return answered(2)", "the second answer")
  msg = sent(log)[3]
  assert(msg:find("</selection>\nDiagnostics in the selected lines: none now.\nRequest: again", 1, true), msg)
  keys("<Esc>q")
  log = setup({ "ANSWER\nok" }, 0, { diagnostics = false })
  lua(DIAGNOSTICS)
  ask()
  keys("fix<CR>")
  wait("return answered(1)", "the answer")
  msg = sent(log)[2]
  assert(not msg:find("Diagnostics", 1, true), msg)
end)

-- vim.ui.select stand-in: records the labels in _G.listed and picks the first
-- item whose label starts with `label` (none: cancelled).
local function pick(label)
  lua([[
    local label = ...
    vim.ui.select = function(items, o, done)
      _G.listed = vim.tbl_map(o.format_item or tostring, items)
      for _, item in ipairs(items) do
        if vim.startswith((o.format_item or tostring)(item), label) then
          return done(item)
        end
      end
      done(nil)
    end
  ]], label)
end

test("actions: a key sends its prompt about the selection, in Normal mode the function around the cursor", function()
  local log = setup({ "ANSWER\nIt prints pairs.", "ANSWER\nNothing to fix." })
  keys("2GVj ae")
  wait("return answered(1)", "the answer")
  local msg = sent(log)[2]
  assert(msg:find("Selected lines 2-3:", 1, true) and vim.endswith(msg, "\nRequest: Explain what this code does."), msg)
  eq({ "  ❯ Explain what this code does.", "    It prints pairs.", "" }, turns())
  keys("<Esc> af") -- in the popup: a follow-up
  wait("return answered(2)", "the follow-up")
  msg = sent(log)[3]
  assert(msg:find("Selected lines 2-3:", 1, true) and msg:find("Request: Fix the problems", 1, true), msg)
  keys("<Esc>q")
  log = setup({ "EDIT\nfunction f(nums)\n  print(#nums)\nend" })
  keys("4G as")
  wait("return answered(1)", "the edit")
  msg = sent(log)[2]
  assert(msg:find("Selected lines 1-7:", 1, true) and vim.endswith(msg, "Request: Simplify this code without changing what it does."), msg)
  eq({ "function f(nums)", "  print(#nums)", "end", "-- 8" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 4, false)"))
  keys("<Esc>q")
  log = setup({ "ANSWER\nok" })
  keys("20G ae")
  wait("return answered(1)", "the answer")
  msg = sent(log)[2]
  assert(msg:find("Selected lines 20-20:", 1, true), "outside a function: the line\n" .. msg)
end)

test("actions: in the popup while a reply streams, an action leaves the prompt alone and says so", function()
  local log = setup({ "ANSWER\none\ntwo\nthree\nfour", "ANSWER\nok" }, 200)
  ask()
  keys("go<CR>")
  wait("return vim.tbl_contains(transcript(), '    one')", "the reply streaming")
  keys(" af")
  eq({ "float-claude: a reply is still streaming", { "" } }, { last_message(),
    lua([[for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "float-claude" then return vim.api.nvim_buf_get_lines(b, 0, -1, false) end
    end]]) }, "the prompt stays empty")
  wait("return answered(1)", "the answer")
  eq(2, #sent(log), "nothing more sent")
end)

test("actions: one with filetypes is mapped and offered only in those buffers", function()
  local log = setup({ "ANSWER\nok", "ANSWER\nnone left" }, 0,
    { actions = { todo = { key = "<leader>ao", prompt = "List the TODOs.", filetypes = { "markdown" } } } })
  pick("nothing")
  keys(":FloatClaude<CR>")
  eq({ false, "", "" }, { vim.tbl_contains(lua("return listed"), "todo        <leader>ao"),
    lua([[return vim.fn.maparg(" ao", "n")]]), lua([[return vim.fn.maparg(" ao", "x")]]) }, "not in a lua buffer")
  lua([[vim.cmd.enew()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# Notes", "", "- TODO: write" })
    vim.bo.filetype = "markdown"]])
  keys(":FloatClaude<CR>")
  eq({ true, true }, { vim.tbl_contains(lua("return listed"), "todo        <leader>ao"),
    lua([[return vim.fn.maparg(" ao", "n") ~= ""]]) }, "offered and mapped in a markdown buffer")
  keys("3G ao")
  wait("return answered(1)", "the answer")
  local msg = sent(log)[2]
  assert(msg:find("(filetype: markdown)", 1, true) and vim.endswith(msg, "Request: List the TODOs."), msg)
  keys("<Esc> ao") -- in the popup: a follow-up
  wait("return answered(2)", "the follow-up")
  assert(vim.endswith(sent(log)[3], "Request: List the TODOs."), sent(log)[3])
  keys("<Esc>q")
  lua("vim.cmd.buffer(1)")
  keys(" ai")
  eq({ "float-claude", "" }, { lua("return vim.bo.filetype"), lua([[return vim.fn.maparg(" ao", "n")]]) },
    "not in the popup of a lua chat")
end)

test("actions: setup changes a key, adds an action and removes one (false)", function()
  local log = setup({ "ANSWER\nok" }, 0, {
    actions = { explain = { key = "<leader>aE" }, simplify = false, todo = { key = "<leader>ao", prompt = "List the TODOs." } },
  })
  eq({ "", "", true, true }, lua([[return { vim.fn.maparg(" ae", "n"), vim.fn.maparg(" as", "x"),
    vim.fn.maparg(" aE", "x") ~= "", vim.fn.maparg(" ao", "n") ~= "" }]]), "mappings")
  keys("4G ao")
  wait("return answered(1)", "the answer")
  assert(vim.endswith(sent(log)[2], "Request: List the TODOs."), sent(log)[2])
  keys("<Esc>q")
  pick("nothing")
  keys(":FloatClaude<CR>")
  eq(true, vim.tbl_contains(lua("return listed"), "explain     <leader>aE"), "the explain prompt is kept")
end)

test(":FloatClaude lists the actions offered here and runs the one picked", function()
  local log = setup({ "ANSWER\nok" })
  pick("nothing")
  keys(":FloatClaude<CR>")
  eq({
    "docstring   <leader>ad",
    "explain     <leader>ae",
    "fix         <leader>af",
    "simplify    <leader>as",
    "tests       <leader>at",
    "types       <leader>ay",
    "ask         <leader>ai",
    "add range   <leader>am",
    "history     <leader>aH",
    "theme       auto",
  }, lua("return listed"), "code actions, ask, add range, history, theme")
  pick("simplify")
  keys("2GVj:FloatClaude<CR>")
  wait("return answered(1)", "the answer")
  local msg = sent(log)[2]
  assert(msg:find("Selected lines 2-3:", 1, true) and vim.endswith(msg, "Request: Simplify this code without changing what it does."), msg)
  pick("hide")
  keys("<Esc>:FloatClaude<CR>")
  eq(true, vim.tbl_contains(lua("return listed"), "back to the popup <leader>ai"), "the popup is open")
  eq({ "lua", nil }, { lua("return vim.bo.filetype"), floats()["float-claude-transcript"] }, "hidden")
  -- "theme" (the last item), then "dracula" from the themes.
  lua([[vim.ui.select = function(items, _, done)
    vim.ui.select = function(_, _, d) d("dracula") end
    done(items[#items])
  end]])
  keys(":FloatClaude<CR>")
  eq(true, lua("return require('float-claude.theme').ns() == vim.api.nvim_create_namespace('float-claude-theme-dracula')"),
    "the theme picked")
end)

test("prose actions: reword edits a markdown paragraph in place; offered on comments, refused on code", function()
  local log = setup({ "EDIT\nA clearer first line.\nAnd a second one." })
  lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# Title", "", "first line  of text", "second line", "", "after" })
    vim.bo.filetype = "markdown"]])
  pick("nothing")
  keys("3G:FloatClaude<CR>")
  eq({ "grammar     <leader>ag", "reword      <leader>ar", "shorten     <leader>ah", "ask         <leader>ai", "add range   <leader>am",
    "history     <leader>aH", "theme       auto" },
    lua("return listed"), "prose actions only")
  keys(" ar")
  wait("return answered(1)", "the edit")
  eq({ "# Title", "", "A clearer first line.", "And a second one.", "", "after" }, lua("return vim.api.nvim_buf_get_lines(1, 0, -1, false)"))
  local msg = sent(log)[2]
  assert(msg:find("(filetype: markdown)", 1, true) and msg:find("Selected lines 3-4:", 1, true)
    and vim.endswith(msg, "Request: Reword this text so it reads clearly; keep its meaning and tone."), msg)
  keys("<Esc>q")
  keys("3G ae")
  eq("float-claude: explain is for code", last_message())
  eq(1, #lua("return vim.api.nvim_list_wins()"), "no popup")
  log = setup({ "ANSWER\nok" })
  keys("2G ar")
  eq("float-claude: reword is for markdown, gitcommit, text and comments", last_message())
  keys("10G ag")
  wait("return answered(1)", "the answer")
  msg = sent(log)[2]
  assert(msg:find("Selected lines 8-40:", 1, true), "the comment block\n" .. msg)
end)

-- A temporary directory, the child's current directory, holding `files` ({ name = lines }).
local function workdir(files)
  local dir = vim.fn.tempname()
  for name, lines in pairs(files) do
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. name), "p")
    vim.fn.writefile(lines, dir .. "/" .. name)
  end
  lua("vim.cmd.cd(...)", dir)
  return dir
end

test("@ mentions: a file, an open buffer as it is now and @diagnostics are sent and listed; mentions = false", function()
  local log = setup({ "ANSWER\nok" }, 0, { mentions = { max_lines = 3 } })
  workdir({ ["notes.txt"] = { "one", "two" }, ["big.txt"] = { "1", "2", "3", "4", "5" }, ["other.lua"] = { "on disk" } })
  lua([[local b = vim.fn.bufadd("other.lua")
    vim.fn.bufload(b)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "local x = 1 -- unsaved" })]])
  lua(DIAGNOSTICS)
  ask()
  keys("see @notes.txt, @other.lua and @big.txt. @diagnostics @notes.txt; not @nothing or a@big.txt<CR>")
  wait("return answered(1)", "the answer")
  local msg = sent(log)[2]
  local expected = table.concat({
    "Mentioned in the request (with @):",
    "@notes.txt: a file (2 lines):",
    '<mention name="notes.txt">',
    "one",
    "two",
    "</mention>",
    "@other.lua: an open buffer, its text as it is now (1 line):",
    '<mention name="other.lua">',
    "local x = 1 -- unsaved",
    "</mention>",
    "@big.txt: a file (first 3 lines; the rest was not sent):",
    '<mention name="big.txt">',
    "1",
    "2",
    "3",
    "</mention>",
    "@diagnostics, those of [No Name] (3 diagnostics):",
    "- line 2: error: unused loop variable",
    "- line 4: warning: undefined global print (lua_ls)",
    "- line 21: error: far away",
    "Request: see @notes.txt",
  }, "\n")
  assert(msg:find(expected, 1, true), msg)
  eq({
    "  ❯ see @notes.txt, @other.lua and @big.txt.",
    "    @diagnostics @notes.txt; not @nothing or",
    "    a@big.txt",
    "    + notes.txt (2 lines), other.lua (1 line),",
    "    big.txt (first 3 lines), diagnostics (3)",
    "    ok",
    "",
  }, turns(), "the mentions listed under the question")
  keys("<Esc>q")
  log = setup({ "ANSWER\nok" }, 0)
  lua(DIAGNOSTICS)
  ask()
  keys("@diagnostics fix these<CR>")
  wait("return answered(1)", "the answer")
  msg = sent(log)[2]
  assert(msg:find("Mentioned in the request (with @):\n@diagnostics, those of [No Name] (3 diagnostics):", 1, true), msg)
  keys("<Esc>q")
  log = setup({ "ANSWER\nok" }, 0, { mentions = false })
  ask()
  eq("", lua("return vim.bo.omnifunc"), "no completion")
  keys("see @notes.txt<CR>")
  wait("return answered(1)", "the answer")
  msg = sent(log)[2]
  assert(not msg:find("Mentioned", 1, true), msg)
end)

-- The words in the completion menu, false when it is not showing.
local function menu()
  return lua([[
    if vim.fn.pumvisible() == 0 then return false end
    local info = vim.fn.complete_info({ "matches", "items" })
    local typed = vim.api.nvim_get_current_line():sub(1, vim.fn.col(".") - 1):match("@(%S*)$")
    -- Neovim 0.10 has no "matches": the items that start with what was typed.
    return vim.iter(info.items):filter(function(i) return i.match or (i.match == nil and vim.startswith(i.word, typed)) end)
      :map(function(i) return i.word end):totable()
  ]])
end

test("@ mentions: completion lists keywords, open buffers and files as you type; Enter takes a selected item", function()
  local log = setup({ "ANSWER\nok" })
  workdir({ ["alpha.lua"] = { "return 1" }, ["sub/beta.txt"] = { "beta" } })
  lua([[vim.fn.bufload(vim.fn.bufadd("gamma.md"))]])
  lua("vim.o.completeopt = 'menuone,noselect'") -- Neovim 0.10: as you type only with noselect (or noinsert)
  ask()
  keys("look at @")
  wait("return vim.fn.pumvisible() == 1", "the menu")
  eq({ "diagnostics", "gamma.md", "alpha.lua", "sub/" }, menu(), "keywords, open buffers, files")
  keys("g")
  eq({ "gamma.md" }, menu(), "narrowed as you type")
  keys("<BS>su<C-n>")
  eq({ "sub/" }, menu())
  keys("<CR>")
  wait("return vim.deep_equal(vim.fn.pumvisible() == 1 and vim.fn.complete_info({ 'items' }).items[1].word, 'sub/beta.txt')",
    "the directory's files")
  eq({ "look at @sub/" }, floats()["float-claude"].lines, "Enter took the item, nothing sent")
  keys("<C-n><CR>")
  eq({ "look at @sub/beta.txt" }, floats()["float-claude"].lines)
  eq(false, menu(), "no menu for a mention just completed")
  keys("<CR>")
  wait("return answered(1)", "the answer")
  local msg = sent(log)[2]
  assert(msg:find('@sub/beta.txt: a file (1 line):\n<mention name="sub/beta.txt">\nbeta\n</mention>', 1, true), msg)
end)

test("model and effort: the CLI starts with the setup ones; shown in the header; switched per chat", function()
  local log = setup({ "ANSWER\nok", "ANSWER\nok" }, 0, { model = "sonnet", effort = "high" })
  lua("vim.api.nvim_buf_set_name(0, 'demo.lua')")
  ask()
  local function header()
    return floats()["float-claude-transcript"].lines[2]
  end
  eq("  demo.lua · L2–6 · 5 lines · sonnet · high", header())
  wait("return logged(1)", "the CLI to start")
  local argv = vim.json.decode(vim.fn.readfile(log)[1]).argv
  local args = table.concat(vim.tbl_map(function(i)
    return argv[tostring(i)]
  end, vim.fn.range(1, vim.tbl_count(argv) - 1)), " ")
  assert(args:find("--model sonnet --effort high", 1, true), args)
  keys("<Esc>:FloatClaudeModel opus<CR>")
  wait([[return transcript()[2]:find("opus") ~= nil]], "the header to show the model")
  keys(":FloatClaudeEffort low<CR>")
  wait([[return transcript()[2]:find("low") ~= nil]], "the header to show the effort")
  eq("  demo.lua · L2–6 · 5 lines · opus · low", header())
  keys(":FloatClaudeEffort turbo<CR>")
  eq("float-claude: unknown effort turbo", last_message())
  keys(":FloatClaudeModel bad<CR>")
  wait([[return vim.fn.execute("1messages"):find("bad") ~= nil]], "the refusal")
  eq("float-claude: model bad: Model 'bad' not found", last_message())
  eq("  demo.lua · L2–6 · 5 lines · opus · low", header(), "unchanged")
  eq({ "sonnet" }, lua([[return vim.fn.getcompletion("FloatClaudeModel s", "cmdline")]]), "models complete")
  eq({ "xhigh" }, lua([[return vim.fn.getcompletion("FloatClaudeEffort x", "cmdline")]]), "efforts complete")
  -- From the palette: "model", then "haiku" from the models.
  lua([[vim.ui.select = function(items, o, done)
    _G.listed = vim.tbl_map(o.format_item or tostring, items)
    vim.ui.select = function(_, _, d) d("haiku") end
    done(vim.iter(items):find(function(i) return i.label and vim.startswith(i.label, "model") end))
  end]])
  keys(":FloatClaude<CR>")
  assert(vim.tbl_contains(lua("return listed"), "model       opus") and vim.tbl_contains(lua("return listed"), "effort      low"),
    vim.inspect(lua("return listed")))
  wait([[return transcript()[2]:find("haiku") ~= nil]], "the palette's switch")
  keys("ihi<CR>")
  wait("return answered(1)", "the answer")
  eq({ "<start>", "<set_model opus>", '<apply_flag_settings {"effortLevel":"low"}>', "<set_model bad>", "<set_model haiku>" },
    vim.list_slice(sent(log), 1, 5), "one process: switched in place")
  keys("<Esc>q")
  ask()
  eq("  demo.lua · L2–6 · 5 lines · sonnet · high", header(), "a new chat starts with the setup ones")
end)

test("model: without one set, the header shows the model the CLI reports", function()
  setup({ "ANSWER\nok" })
  lua("vim.env.FAKE_CLAUDE_MODEL = 'claude-fake-1' vim.api.nvim_buf_set_name(0, 'demo.lua')")
  ask()
  eq("  demo.lua · L2–6 · 5 lines", floats()["float-claude-transcript"].lines[2], "not known yet")
  keys("hi<CR>")
  wait("return answered(1)", "the answer")
  eq("  demo.lua · L2–6 · 5 lines · fake-1", floats()["float-claude-transcript"].lines[2])
end)

-- The header of the chat on screen.
local function shown_header()
  return floats()["float-claude-transcript"].lines[2]
end

test("multiple chats: hidden ones stay independent; next/prev and the picker show one; q ends only that one", function()
  local log = setup({ "ANSWER\nfirst reply", "ANSWER\nsecond reply" })
  local function highlighted()
    return lua([[return #vim.tbl_filter(function(m) return m[4].hl_group == "FloatClaudeSelection" end,
      vim.api.nvim_buf_get_extmarks(1, -1, 0, -1, { details = true }))]])
  end
  ask()
  keys("a<CR>")
  wait("return answered(1)", "chat 1's answer")
  keys("<C-q>")
  keys("8GVj ai")
  eq("  [No Name] · L8–9 · 2 lines · 2/2", shown_header(), "a second chat")
  eq(1, highlighted(), "only the shown chat's lines are highlighted")
  keys("b<CR>")
  wait("return answered(1)", "chat 2's answer")
  keys("<Esc> ap")
  eq({ "  [No Name] · L2–6 · 5 lines · 1/2", { "  ❯ a", "    first reply", "" }, 2 },
    { shown_header(), turns(), vim.tbl_count(floats()) }, "previous: chat 1 alone on screen")
  eq({ "float-claude", "i" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "in its prompt")
  keys("<Esc> an")
  eq({ "  [No Name] · L8–9 · 2 lines · 2/2", { "  ❯ b", "    first reply", "" } }, { shown_header(), turns() }, "next: chat 2")
  keys("<Esc> an")
  eq("  [No Name] · L2–6 · 5 lines · 1/2", shown_header(), "wraps around")
  pick("2/2")
  keys("<Esc>:FloatClaudeChats<CR>")
  eq({ "1/2 [No Name] · L2–6 · a", "2/2 [No Name] · L8–9 · b" }, lua("return listed"), "the picker lists both")
  eq("  [No Name] · L8–9 · 2 lines · 2/2", shown_header(), "picked")
  eq({ "float-claude", "i" }, lua("return { vim.bo.filetype, vim.fn.mode() }"), "in its prompt")
  keys("c<CR>")
  wait("return answered(2)", "chat 2's follow-up")
  eq({ "  ❯ b", "    first reply", "", "  ❯ c", "    second reply", "" }, turns(), "its own conversation")
  local msgs = sent(log)
  eq({ "<start>", "<start>" }, { msgs[1], msgs[3] }, "a process each")
  assert(msgs[5]:find("Selected lines 8-9:", 1, true), msgs[5])
  keys("<Esc>q")
  eq({ {}, 1 }, { floats(), lua("return #require('float-claude.chat').list()") }, "chat 2 ended, chat 1 still hidden")
  keys(" ai")
  eq({ "  [No Name] · L2–6 · 5 lines", { "  ❯ a", "    first reply", "" } }, { shown_header(), turns() },
    "<leader>ai shows chat 1; one chat: no count")
  -- Past max_chats, opening one more ends the one used longest ago.
  lua([[require("float-claude").setup({ max_chats = 2 })]])
  keys("<Esc><C-o>12GV ai")
  keys("<C-o>20GV ai")
  eq({ "  [No Name] · L20 · 2/2", 2 }, { shown_header(), lua("return #require('float-claude.chat').list()") })
  keys("<Esc> ap")
  eq("  [No Name] · L12 · 1/2", shown_header(), "chat 1 (lines 2-6) ended")
end)

test("multiple chats: an edit while another chat's diff waits on the file is refused; the chat stays open", function()
  local log = setup({ "EDIT\n  a()\n", "EDIT\n  b()\n" }, 0, { review_edits = true })
  ask()
  keys("one<CR>")
  wait("return reviewing()", "chat 1's diff")
  keys("<C-q>")
  keys("8GVj ai")
  keys("two<CR>")
  wait("return answered(1)", "chat 2's reply")
  eq({ "  ❯ two", "      a()", "", "  chat 1/2 has an edit pending on this file -", "  accept or discard it first", "" }, turns(),
    "the reply stays as a code block, indented as sent, with a note")
  eq("@function.call.lua", lua([[
    local b = vim.api.nvim_win_get_buf(vim.iter(vim.api.nvim_list_wins()):find(function(w)
      return vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "float-claude-transcript" and not vim.api.nvim_win_get_config(w).hide
    end))
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, -1, { 3, 0 }, { 3, -1 }, { details = true })) do
      if m[4].hl_group == "@function.call.lua" then return m[4].hl_group end
    end
  ]]), "highlighted as the source's language")
  eq({ 2, ORIGINAL }, { lua("return #require('float-claude.chat').list()"), buffer() }, "chat 2 open, nothing written")
  keys("<Esc> ap")
  eq({ "  [No Name] · L2–6 · 5 lines · 1/2", "float-claude-transcript" }, { shown_header(), lua("return vim.bo.filetype") },
    "chat 1, at its diff")
  keys(" yy")
  eq("  a()", buffer()[2], "chat 1's edit accepted")
  keys("<Esc> an")
  keys("again<CR>")
  wait("return reviewing()", "chat 2's diff")
  keys(" yy")
  eq({ "function f(nums)", "  a()", "end", "  b()", "-- 10" }, lua("return vim.api.nvim_buf_get_lines(1, 0, 5, false)"),
    "chat 2 edits its lines once the file is free")
  assert(sent(log)[5]:find("was not applied: another chat was editing the file", 1, true), sent(log)[5])
end)

test("multiple chats: an edit while a hidden chat's edit streams into the file is refused", function()
  setup({ "EDIT\n  a()\n  b()\n  c()\n" }, 300)
  ask()
  keys("one<CR>")
  wait("return vim.api.nvim_buf_get_lines(1, 1, 2, false)[1] == '  a()'", "chat 1's first line")
  keys("<C-q>")
  keys("8GVj ai")
  keys("two<CR>")
  wait("return answered(1)", "chat 2's reply")
  eq({ "  ❯ two", "      a()", "      b()", "      c()", "", "  chat 1/2 is editing this file - ask again once", "  it is done", "" },
    turns(), "the reply stays as a code block, indented as sent, with a note")
  wait("return not require('float-claude.chat').list()[1].answering()", "chat 1's edit")
  eq({ "function f(nums)", "  a()", "  b()", "  c()", "end", "-- 8", "-- 9" }, buffer(), "only chat 1's edit written")
  lua("vim.api.nvim_set_current_win(1000)")
  keys("<Esc>u")
  eq(ORIGINAL, buffer(), "one undo reverts it")
end)

test("status(): a spinner while a hidden chat answers, a dot for a reply not seen, redrawn only while busy", function()
  local long = {}
  for i = 1, 30 do
    long[i] = "line " .. i
  end
  setup({ "ANSWER\n" .. table.concat(long, "\n") }, 30)
  -- Count the statusline's redraws.
  lua([[
    _G.redraws = 0
    function _G.statusline() _G.redraws = _G.redraws + 1 return require("float-claude").status() end
    vim.o.laststatus = 2
    vim.o.statusline = "%{v:lua.statusline()}"
  ]])
  local function status()
    return lua([[return require("float-claude").status()]])
  end
  ask()
  eq("", status(), "idle")
  keys("hi<CR>")
  wait([[return transcript()[4] == "    line 1"]], "the answer to start")
  eq("", status(), "answering on screen")
  keys("<C-q>")
  assert(vim.tbl_contains({ "◐", "◓", "◑", "◒" }, status()), status())
  local before = lua("return redraws")
  lua("vim.wait(400)")
  assert(lua("return redraws") - before >= 2, "redrawn while answering")
  wait([[return require("float-claude").status() == "●"]], "the answer to end")
  lua("vim.wait(200)")
  before = lua("return redraws")
  lua("vim.wait(400)")
  eq(before, lua("return redraws"), "no redraws once idle")
  keys(" ai")
  eq("", status(), "seen")
end)

-- The arguments the fake CLI was started with, each start as one string.
local function starts(log)
  local out = {}
  for _, line in ipairs(vim.fn.readfile(log)) do
    local argv = vim.json.decode(line).argv
    if argv then
      table.insert(out, table.concat(vim.tbl_map(function(i)
        return argv[tostring(i)]
      end, vim.fn.range(1, vim.tbl_count(argv) - 1)), " "))
    end
  end
  return out
end

test("history: a chat is saved, reopened after a restart from the picker, and its session resumed", function()
  setup({ "ANSWER\nO(n²).", "ANSWER\nYes." })
  local dir = workdir({ ["demo.lua"] = ORIGINAL, ["other.lua"] = { "x" } })
  keys(":edit demo.lua<CR>")
  ask()
  keys("time complexity?<CR>")
  wait("return answered(1)", "the answer")
  keys("<Esc>q")
  restart()
  local log = setup({ "ANSWER\nStill O(n²)." })
  lua("vim.cmd.cd(...)", dir)
  keys(":edit other.lua<CR>")
  pick("demo.lua")
  keys(":FloatClaudeHistory<CR>")
  eq({ "demo.lua · L2–6 · just now · time complexity?" }, lua("return listed"), "the saved chat")
  eq({ "demo.lua", "  demo.lua · L2–6 · 5 lines", { "  ❯ time complexity?", "    O(n²).", "" } },
    { lua("return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(vim.b.float_claude_source), ':t')"), shown_header(), turns() },
    "reopened on its file")
  wait("return logged(1)", "the CLI to start")
  assert(starts(log)[1]:find("--resume fake-session", 1, true) and not starts(log)[1]:find("--no-session-persistence", 1, true), starts(log)[1])
  keys("and now?<CR>")
  wait("return answered(2)", "the answer")
  local msg = sent(log)[2]
  assert(vim.startswith(msg, "The current version of the code") and vim.endswith(msg, "Request: and now?"), msg)
  keys("<Esc>q")
  eq(1, #lua([[return require("float-claude.history").list()]]), "saved again, as the same chat")
end)

test("history: a session that cannot be resumed starts afresh with the conversation as text; history = false", function()
  setup({ "ANSWER\nO(n²)." })
  local dir = workdir({ ["demo.lua"] = ORIGINAL })
  keys(":edit demo.lua<CR>")
  ask()
  keys("time complexity?<CR>")
  wait("return answered(1)", "the answer")
  keys("<Esc>q")
  -- The CLI no longer has the session.
  lua([[local h = require("float-claude.history")
    local c = h.list()[1]
    c.session = "gone"
    h.save(c, {})]])
  local log = setup({ "ANSWER\nStill O(n²)." })
  pick("demo.lua")
  keys(":FloatClaudeHistory<CR>")
  wait([[return vim.iter(transcript()):any(function(l) return l:find("could not resume", 1, true) ~= nil end)]], "the notice")
  eq({ "  ❯ time complexity?", "    O(n²).", "", "  Claude could not resume this chat (No", "  conversation found with session ID: gone), so",
    "  it gets the conversation above as text.", "" }, turns())
  keys("and now?<CR>")
  wait("return answered(3)", "the answer")
  eq({ "--resume gone", "" }, vim.tbl_map(function(a)
    return a:match("%-%-resume %S+") or ""
  end, starts(log)), "started again without it")
  local msg = sent(log)[3]
  assert(vim.startswith(msg, "This chat was reopened, but your session could not be resumed. The conversation so far:\n"
    .. "Request: time complexity?\nYour reply: O(n²).\n\nThe current version of the code"), msg)
  -- Off: nothing saved, the CLI saves no session either.
  keys("<Esc>q")
  lua("vim.fn.delete(vim.fn.stdpath('state') .. '/float-claude', 'rf')")
  log = setup({ "ANSWER\nok" }, 0, { history = false })
  lua("vim.cmd.cd(...)", dir)
  ask()
  keys("hi<CR>")
  wait("return answered(1)", "the answer")
  eq({ {}, true }, { lua([[return require("float-claude.history").list()]]), starts(log)[1]:find("--no-session-persistence", 1, true) ~= nil })
  keys("<Esc>:FloatClaudeHistory<CR>")
  eq("float-claude: history is off", last_message())
end)

test("history: a chat about several ranges, one a block, reopens on the same ranges", function()
  setup({ "ANSWER\nok" })
  local dir = workdir({ ["demo.lua"] = ORIGINAL })
  keys(":edit demo.lua<CR>")
  keys("2GVj am")
  keys("4G04l<C-v>j1l ai")
  keys("q?<CR>")
  wait("return answered(1)", "the answer")
  keys("<Esc>q")
  restart()
  local log = setup({ "ANSWER\nok" })
  lua("vim.cmd.cd(...)", dir)
  keys(":edit demo.lua<CR>")
  pick("demo.lua")
  keys(":FloatClaudeHistory<CR>")
  eq("  demo.lua · L2–3, L4–5 · 2 ranges", shown_header())
  keys("and?<CR>")
  wait("return answered(2)", "the answer")
  assert(sent(log)[2]:find("Range 2: a block, a column range in lines 4-5 (each line below is the selected part of one line "
    .. "of it, in order):\n<range 2>\n  \nen\n</range 2>", 1, true), sent(log)[2])
end)

test("history: retention keeps the latest max chats, none older than days", function()
  setup()
  eq({ { "c", "b", "a" }, { "d", "c" } }, lua([[
    local h = require("float-claude.history")
    local function ids() return vim.tbl_map(function(c) return c.id end, h.list()) end
    h.save({ id = "a", time = os.time() - 40 * 86400 }, {})
    h.save({ id = "b", time = os.time() - 2 }, {})
    h.save({ id = "c", time = os.time() - 1 }, {})
    local kept = ids()
    h.save({ id = "d", time = os.time() }, { max = 2, days = 30 })
    return { kept, ids() }
  ]]))
end)

if failures > 0 then
  io.stdout:write(failures .. " failed\n")
  os.exit(1)
end
io.stdout:write("all passed\n")
