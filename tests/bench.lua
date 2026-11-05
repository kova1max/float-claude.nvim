-- Benchmark. Run from the repo root: nvim --clean --headless -l tests/bench.lua
-- Measures, in this Neovim, what the plugin costs: setup() time and what it
-- leaves running, then chats on a 10,000-line file with an LSP server
-- attached, streaming a long answer and a long edit from tests/fake_claude.lua
-- (CPU time of this process per streamed delta, and the longest the main
-- loop was blocked), a follow-up after a hand edit, and memory.
-- Numbers vary between machines; compare runs on the same one.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
local xdg = vim.fn.tempname()
vim.env.XDG_STATE_HOME = xdg -- saved chats go here

local uv = vim.uv
local function cpu_ms()
  local r = uv.getrusage()
  return (r.utime.sec + r.stime.sec) * 1e3 + (r.utime.usec + r.stime.usec) / 1e3
end
local function report(what, value, unit)
  io.stdout:write(string.format("%-48s %9.3f %s\n", what, value, unit))
end
local function idle(ms)
  vim.wait(ms, function()
    return false
  end)
end
-- CPU ms used in a second of doing nothing: timers, polling.
local function idle_cpu()
  local c0 = cpu_ms()
  idle(1000)
  return cpu_ms() - c0
end
-- The plugin's autocmds for events that come all the time, in any buffer.
local FREQUENT = { "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "TextChangedP", "WinScrolled",
  "BufEnter", "WinEnter", "WinLeave", "ModeChanged", "InsertCharPre", "SafeState", "CursorHold" }
local function frequent_autocmds()
  return #vim.tbl_filter(function(a)
    return (a.group_name or ""):match("^float%-claude") and not a.buflocal
  end, vim.api.nvim_get_autocmds({ event = FREQUENT }))
end

-- setup(), the first time: what loading the plugin adds to startup.
local t0 = uv.hrtime()
require("float-claude").setup({})
report("setup() (require + setup)", (uv.hrtime() - t0) / 1e6, "ms")
local loaded = vim.tbl_filter(function(name)
  return name:match("^float%-claude")
end, vim.tbl_keys(package.loaded))
report("modules loaded by setup()", #loaded, "")
report("autocmds after setup()", #vim.api.nvim_get_autocmds({ group = "float-claude" }), "")
report("CPU per idle second after setup()", idle_cpu(), "ms")

-- A 10,000-line Lua file.
local lines = {}
for i = 1, 10000 do
  lines[i] = i % 10 == 1 and string.format("local function f%d(a, b)", i) or string.format("  local x%d = a + b * %d -- note", i, i)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.api.nvim_buf_set_name(0, xdg .. "/bench.lua")
vim.bo.filetype = "lua"

-- An LSP server that finds the definition of every name where it is asked.
vim.lsp.start({
  name = "bench",
  cmd = function()
    local closing, id = false, 0
    return {
      request = function(method, params, callback)
        id = id + 1
        local result = {}
        if method == "initialize" then
          result = { capabilities = { definitionProvider = true, workspaceSymbolProvider = true } }
        elseif method == "textDocument/definition" then
          result = { uri = params.textDocument.uri, range = { start = params.position, ["end"] = params.position } }
        end
        vim.schedule(function()
          callback(nil, result)
        end)
        return true, id
      end,
      notify = function(method)
        closing = closing or method == "exit"
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        closing = true
      end,
    }
  end,
}, { bufnr = 0 })

-- An answer of prose with inline code and code blocks (~4.5 KB), and an
-- edit of 400 lines; both streamed in 16-byte deltas, 1 ms apart (the CLI's
-- come further apart).
local answer = { "ANSWER" }
for i = 1, 60 do
  table.insert(answer, string.format("Step %d calls `f%d` with `a` and `b`, then adds the result to `x%d`.", i, i * 10 + 1, i))
  if i % 6 == 0 then
    vim.list_extend(answer, { "```lua", "local y = f" .. i * 10 + 1 .. "(1, 2)", "print(y + x" .. i .. ")", "```" })
  end
end
local edit = { "EDIT" }
for i = 1, 400 do
  table.insert(edit, string.format("  local y%d = a * b + %d", i, i))
end
local function deltas(reply)
  local out = {}
  for i = 1, #reply, 16 do
    table.insert(out, reply:sub(i, i + 15))
  end
  return out
end
local replies = { deltas(table.concat(answer, "\n")), deltas(table.concat(edit, "\n")), "ANSWER\nok" }
vim.env.FAKE_CLAUDE_REPLIES = vim.json.encode(replies)
vim.env.FAKE_CLAUDE_DELAY = "1"
vim.env.FAKE_CLAUDE_LOG = vim.fn.tempname()
require("float-claude").setup({ cmd = { vim.v.progpath, "--clean", "--headless", "-l", root .. "/tests/fake_claude.lua" } })
local chat = require("float-claude.chat")

-- Send `prompt` to chat `c` and wait for the reply, then `after` ms more:
-- CPU ms of this process per delta until the reply ended, and the longest
-- the main loop was blocked, in ms.
local function stream(c, prompt, count, after)
  local stall, last = 0, uv.hrtime()
  local probe = assert(uv.new_timer())
  probe:start(1, 1, function()
    local now = uv.hrtime()
    stall, last = math.max(stall, (now - last) / 1e6), now
  end)
  local c0 = cpu_ms()
  c.send(prompt)
  assert(vim.wait(60000, function()
    return not c.answering()
  end, 1), "no reply")
  local cpu = cpu_ms() - c0
  idle(after or 0)
  probe:close()
  return cpu / count, stall
end

-- One chat: open it on lines 5001-5040, an answer (and the LSP lookups of
-- its names), an edit (undone), a hand edit and a follow-up, then close it.
local function scenario()
  local out = {}
  local t = uv.hrtime()
  require("float-claude").ask({ 5001, 5040 })
  out.open = (uv.hrtime() - t) / 1e6
  local c = chat.current()
  out.answer_cpu, out.answer_stall = stream(c, "explain", #replies[1], 500)
  out.edit_cpu, out.edit_stall = stream(c, "rewrite", #replies[2])
  vim.cmd("silent undo") -- back to the original lines
  vim.api.nvim_buf_set_lines(0, 5010, 5011, false, { "  local changed = 1" }) -- a hand edit
  out.followup = stream(c, "again", 1)
  idle(1000) -- the edit highlight's fade, the streaming redraws: all done
  out.idle_cpu, out.autocmds = idle_cpu(), frequent_autocmds()
  collectgarbage("collect")
  out.mem = collectgarbage("count")
  c.close()
  vim.cmd("silent undo")
  idle(200)
  collectgarbage("collect")
  collectgarbage("collect")
  out.after = collectgarbage("count")
  return out
end

-- The first chat also loads what chats need (treesitter, LSP, ...); the
-- second one is measured, three more show whether closed chats leave memory behind.
local first = scenario()
local m = scenario()
local last
for _ = 1, 3 do
  last = scenario()
end
report("first chat: open the popup", first.open, "ms")
report("open the popup", m.open, "ms")
report(string.format("answer: CPU per streamed delta (%d deltas)", #replies[1]), m.answer_cpu, "ms")
report("answer + LSP lookups: longest main-loop block", m.answer_stall, "ms")
report(string.format("edit: CPU per streamed delta (%d deltas)", #replies[2]), m.edit_cpu, "ms")
report("edit: longest main-loop block", m.edit_stall, "ms")
report("follow-up after a hand edit (10k-line file)", m.followup, "ms CPU")
report("CPU per idle second, chat open", m.idle_cpu, "ms")
report("autocmds on frequent events, chat open", m.autocmds, "")
report("Lua memory in use with a chat open", (m.mem - first.after) / 1024, "MB")
report("Lua memory left by 3 more closed chats", (last.after - m.after) / 1024, "MB")
report("CPU per idle second, chats closed", idle_cpu(), "ms")
report("autocmds on frequent events, chats closed", frequent_autocmds(), "")
