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

local function test(name, fn)
  chan = vim.fn.jobstart({ vim.v.progpath, "--clean", "-n", "--embed", "--headless", "--cmd", "set rtp^=" .. root }, {
    rpc = true,
    env = env,
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
    -- Test helpers: the transcript lines, and whether `n` answers are complete
    -- (each ends with a blank row; the first row is padding).
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
    table.insert(out, msg.argv and "<start>" or msg.message.content)
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

test("Esc closes the popup and restores everything", function()
  setup()
  ask()
  keys("abc<Esc>")
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
  keys("<Esc>u")
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
  keys("<Esc>")
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
  keys("<Esc>")
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
  keys("<Esc>")
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

test("<leader>ai on a new selection starts a fresh chat in place of the open one", function()
  local log = setup({ "ANSWER\nok", "ANSWER\nfresh" })
  ask()
  keys("first<CR>")
  wait("return answered(1)", "the answer")
  keys("<C-o>")
  keys(" ai")
  eq({ "  ❯ first", "    ok", "" }, turns(), "Normal mode: the same chat")
  keys("<C-o>")
  keys("8GVj ai")
  eq({ "", "  [No Name] · L8–9 · 2 lines" }, floats()["float-claude-transcript"].lines, "a fresh chat")
  eq({ 3, 1 }, { #lua("return vim.api.nvim_list_wins()"), marks() }, "one popup, one selection")
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

test("highlight groups can be overridden", function()
  setup()
  lua([[vim.api.nvim_set_hl(0, "FloatClaudeNormal", { bg = "#123456" })]])
  ask()
  eq(0x123456, lua([[return vim.api.nvim_get_hl(0, { name = "FloatClaudeNormal" }).bg]]), "bg")
  eq(0x3fb5c9, lua([[return vim.api.nvim_get_hl(0, { name = "FloatClaudePrompt" }).fg]]), "prompt fg")
  eq(0x8a8a8a, lua([[return vim.api.nvim_get_hl(0, { name = "FloatClaudeHistory" }).fg]]), "history fg")
  eq(0x12301f, lua([[return vim.api.nvim_get_hl(0, { name = "FloatClaudeAdded" }).bg]]), "added bg")
  eq(0x3a1d22, lua([[return vim.api.nvim_get_hl(0, { name = "FloatClaudeRemoved" }).bg]]), "removed bg")
end)

if failures > 0 then
  io.stdout:write(failures .. " failed\n")
  os.exit(1)
end
io.stdout:write("all passed\n")
