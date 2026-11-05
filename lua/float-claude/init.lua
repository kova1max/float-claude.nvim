local M = {}

-- Every option, with its default. The README documents them.
local config = {
  -- Visual (and Normal: current line) mode mapping that opens the popup. `false` disables it.
  keymap = "<leader>ai",
  -- The Claude Code CLI; extra arguments may follow.
  cmd = { "claude" },
  -- The model each chat starts with: an alias ("opus", "sonnet", "haiku", "fable")
  -- or a full model name; false: the CLI's default. :FloatClaudeModel switches a chat's.
  model = false,
  -- The effort each chat starts with: "low", "medium", "high", "xhigh" or "max";
  -- false: the CLI's default. :FloatClaudeEffort switches a chat's.
  effort = false,
  -- @ mentions in the prompt (@diagnostics, @<buffer or file>), each sending at
  -- most max_lines lines; false: off.
  mentions = { max_lines = 500 },
  -- Your own instructions for Claude, added to the built-in ones in every chat:
  -- a string, or a function(ctx) returning one (ctx: buf, file, filetype).
  prompt = false,
  -- A file whose text is added too, found in the file's directory or above it,
  -- e.g. ".float-claude.md". Off by default: a cloned repository could steer Claude.
  project_prompt = false,
  -- Unselected lines sent above and below the selection.
  context_lines = 40,
  -- Send the diagnostics (errors, warnings, ...) in the selected lines too, as they are at each message.
  diagnostics = true,
  -- One-key actions: a prompt sent right away about the selection (or, in Normal
  -- mode, the lines around the cursor, see actions.lua). Each is { key, prompt },
  -- plus `prose = true` for one offered in prose_filetypes buffers and on comments
  -- instead of in code, or `filetypes` to offer it only there. `false` removes one.
  actions = {
    explain = { key = "<leader>ae", prompt = "Explain what this code does." },
    fix = {
      key = "<leader>af",
      prompt = "Fix the problems the diagnostics report in this code; with none listed, fix the bugs you find.",
    },
    tests = {
      key = "<leader>at",
      prompt = "Write unit tests for this code, in the project's test style, as an answer with a code block; do not edit the code.",
    },
    types = { key = "<leader>ay", prompt = "Add type annotations to this code, in the language's usual way. Change nothing else." },
    docstring = {
      key = "<leader>ad",
      prompt = "Add a doc comment to each function in this code, in the language's usual style. Change nothing else.",
    },
    simplify = { key = "<leader>as", prompt = "Simplify this code without changing what it does." },
    reword = { key = "<leader>ar", prompt = "Reword this text so it reads clearly; keep its meaning and tone.", prose = true },
    shorten = { key = "<leader>ah", prompt = "Shorten this text; keep its meaning.", prose = true },
    grammar = {
      key = "<leader>ag",
      prompt = "Fix the spelling, grammar and punctuation of this text. Change nothing else.",
      prose = true,
    },
  },
  -- Filetypes whose buffers are prose: they offer the prose actions instead of the code ones.
  prose_filetypes = { "markdown", "gitcommit", "text" },
  -- Chats open at once (one shown, the others hidden); opening one more ends
  -- the one used longest ago.
  max_chats = 5,
  -- Save chats about a file, to reopen them later (:FloatClaudeHistory): at most
  -- `max` of them, none older than `days` days (either can be false). false: off.
  history = { max = 100, days = 30 },
  -- require("float-claude").status() for a statusline: a spinner while a hidden
  -- chat is answering, `unread` when one has a reply you have not seen.
  status = { spinner = { "◐", "◓", "◑", "◒" }, unread = "●" },
  -- Popup width in columns (capped to the screen). Longer lines wrap onto more rows.
  width = 50,
  -- Popup height cap in rows; `false`: as tall as the screen allows.
  max_height = false,
  -- Where the popup opens: "top-right" (pinned to the editor's top-right corner)
  -- or "cursor" (next to the cursor).
  placement = "top-right",
  -- "top-right": rows from the top and columns from the right edge.
  top_right_offset = { row = 0, col = 0 },
  -- "cursor": rows below and columns right of the cursor (above it when there is no room below).
  cursor_offset = { row = 1, col = 3 },
  -- Popup colors: "auto" (from your colorscheme) or a preset, see require("float-claude.theme").presets.
  theme = "auto",
  -- Single colors over the theme: bg, fg, prompt, header, history, code, selection, added,
  -- removed, and for code in answers comment, keyword, string, number, func, type, constant,
  -- operator, property. E.g. { bg = "#000000" }.
  colors = {},
  -- Show an edit as an inline diff in the buffer and apply it only once accepted.
  review_edits = false,
  -- Close the popup (ending the chat) once an edit is applied.
  close_after_edit = false,
  -- Close the popup (ending the chat) when you leave it, other than with unfocus_key or a jump.
  close_on_leave = false,
  -- Normal mode keys for the open chats. Any of them can be `false` to leave it unmapped.
  next_chat_key = "<leader>an", -- show the next chat
  prev_chat_key = "<leader>ap", -- show the previous one
  chats_key = "<leader>al", -- pick an open chat from a list
  history_key = "<leader>aH", -- pick a saved chat to reopen
  -- Normal and Visual mode: add the selection (Normal: the current line) to
  -- the ranges to ask about together with the next `keymap` or action.
  add_range_key = "<leader>am",
  clear_ranges_key = "<leader>ax", -- Normal mode: clear them
  -- Keys in the popup. Any of them can be `false` to leave it unmapped.
  submit_key = "<CR>", -- send the prompt
  newline_keys = { "<S-CR>", "<C-j>" }, -- Insert mode: a new line in the prompt
  close_key = "q", -- Normal mode: close the popup and end the chat
  hide_key = "<C-q>", -- hide it; the chat goes on, `keymap` brings it back
  unfocus_key = "<C-o>", -- back to the code, the popup stays on screen
  accept_key = "<leader>yy", -- with review_edits: accept the diff
  discard_key = "<leader>nn", -- with review_edits: discard it
  scroll_up_key = "<C-u>", -- scroll the conversation half a screen
  scroll_down_key = "<C-d>",
  line_up_key = "<Up>", -- scroll it a line (in a multi-line prompt, first move between its lines)
  line_down_key = "<Down>",
  jump_key = "<CR>", -- in the conversation, on an underlined name: go to its definition
  hover_key = "K", -- in the conversation, on an underlined name: show its hover
  insert_keys = { "i", "a" }, -- in the conversation: back to the prompt
}

-- The range (a spec, see ranges.lua) `range` ({ first, last }, from a
-- command) names, else the Visual selection's (leaving Visual mode), else nil.
local function selection(range)
  local ranges = require("float-claude.ranges")
  if range then
    return ranges.lines(range[1], range[2])
  end
  if vim.fn.mode():match("^[vV\22]") then
    return ranges.visual()
  end
end

local function in_popup()
  return vim.startswith(vim.bo.filetype, "float-claude")
end

-- Color the popup with the configured theme, an open one too.
local function restyle()
  local theme_ns = require("float-claude.theme").apply(config.theme, config.colors)
  if package.loaded["float-claude.chat"] then
    require("float-claude.chat").restyle(theme_ns)
  end
end

-- Whether the theme's colors were set: nothing shows them before.
local function styled()
  local theme = package.loaded["float-claude.theme"]
  return theme ~= nil and theme.ns() ~= nil
end

-- The ranges to ask about: the pending ones of the current buffer with
-- `spec` added, else `spec` alone (nil without either).
local function gather(spec)
  local ranges, buf = require("float-claude.ranges"), vim.api.nvim_get_current_buf()
  if #ranges.pending(buf) == 0 then
    return spec and { spec }
  end
  if spec then
    local ok, err = ranges.add(buf, spec)
    if not ok then
      return nil, "not asked: " .. err
    end
  end
  return ranges.take(buf)
end

---Open the popup for the selected lines or block (Visual mode) or lines
---`range` ({ first, last }), with the ranges collected by M.add() too. In
---Normal mode, open it for the collected ranges, else focus the open popup
---(showing it if hidden), or open one for the current line.
function M.ask(range)
  local spec = selection(range)
  local chat = require("float-claude.chat")
  -- A selection in the popup itself is not a new chat.
  if in_popup() and chat.focus() then
    return
  end
  local specs, err = gather(spec)
  if err then
    return require("float-claude.util").error(err)
  end
  if not specs and chat.focus() then
    return
  end
  chat.open(vim.tbl_extend("force", config, {
    ranges = specs or { { first = vim.fn.line("."), last = vim.fn.line(".") } },
    selected = specs ~= nil,
  }))
end

---Add the selected lines or block (Visual mode), lines `range` ({ first,
---last }) or the current line to the ranges to ask about together: the next
---M.ask() or action is about all of them.
function M.add(range)
  local ranges, util = require("float-claude.ranges"), require("float-claude.util")
  local spec = selection(range) or { first = vim.fn.line("."), last = vim.fn.line(".") }
  if in_popup() then
    return util.error("select the range in the code")
  end
  if not styled() then -- the collected ranges show in its colors
    restyle()
  end
  local ok, err = ranges.add(vim.api.nvim_get_current_buf(), spec)
  if not ok then
    util.error("not added: " .. err)
  end
end

---Clear the ranges collected by M.add().
function M.clear()
  require("float-claude.ranges").clear()
end

---Run action `name`: send its prompt about the selected lines (Visual mode),
---lines `range` ({ first, last }), or the lines around the cursor (see
---actions.range), in a fresh popup. In the popup, it is a follow-up there.
function M.run(name, range)
  local action = config.actions[name]
  local actions, chat = require("float-claude.actions"), require("float-claude.chat")
  if not action then
    return require("float-claude.util").error(string.format('unknown action "%s"', name))
  end
  local current = chat.current()
  local buf, spec, specs
  if in_popup() and current then
    selection(range) -- a selection in the popup is not one of the code
    local first, last
    buf, first, last = current.source()
    specs = { { first = first, last = last } }
  else
    buf, spec = vim.api.nvim_get_current_buf(), selection(range)
    -- The collected ranges too; nothing is added to them or taken if the
    -- action is not offered there.
    specs = vim.list_extend(require("float-claude.ranges").pending(buf), { spec })
    if #specs == 0 then
      local first, last = actions.range(action, buf, vim.fn.line("."), config)
      specs = { { first = first, last = last } }
    end
  end
  for _, s in ipairs(specs) do
    if not actions.available(action, buf, s.first, s.last, config) then
      local where = action.filetypes and table.concat(action.filetypes, ", ")
        or action.prose and table.concat(config.prose_filetypes, ", ") .. " and comments"
        or "code"
      return require("float-claude.util").error(string.format("%s is for %s", name, where))
    end
  end
  if in_popup() and current then
    return current.send(action.prompt)
  end
  if #require("float-claude.ranges").pending(buf) > 0 then
    local err
    specs, err = gather(spec)
    if err then
      return require("float-claude.util").error(err)
    end
  end
  chat.open(vim.tbl_extend("force", config, { ranges = specs, selected = true, send = action.prompt }))
end

---Pick what to do from a list (vim.ui.select): the actions offered here, open
---the popup, hide it, or switch its theme. They work on lines `range` ({ first,
---last }) when given, as from `:'<,'>FloatClaude`, else as their key in Normal mode.
function M.palette(range)
  local actions, chat = require("float-claude.actions"), require("float-claude.chat")
  local current = chat.current()
  local buf = vim.api.nvim_get_current_buf()
  local source = in_popup() and current and { current.source() }
  local items = {}
  local names = vim.tbl_keys(config.actions)
  table.sort(names)
  for _, name in ipairs(names) do
    local action = config.actions[name]
    if action then
      local b, first, last = buf, range and range[1], range and range[2]
      if source then
        b, first, last = unpack(source)
      elseif not first then
        first, last = actions.range(action, buf, vim.fn.line("."), config)
      end
      if actions.available(action, b, first, last, config) then
        table.insert(items, {
          label = string.format("%-11s %s", name, action.key or ""),
          run = function()
            M.run(name, range)
          end,
        })
      end
    end
  end
  local pending = #require("float-claude.ranges").pending(buf)
  table.insert(items, {
    label = string.format("%-11s %s", current and not range and pending == 0 and "back to the popup" or "ask",
      config.keymap or ""),
    run = function()
      M.ask(range)
    end,
  })
  if not source then
    table.insert(items, {
      label = string.format("%-11s %s", "add range", config.add_range_key or ""),
      run = function()
        M.add(range)
      end,
    })
  end
  if pending > 0 then
    table.insert(items, { label = string.format("%-11s %s", "clear", config.clear_ranges_key or ""), run = M.clear })
  end
  if current and not current.hidden() then
    table.insert(items, { label = string.format("%-11s %s", "hide", config.hide_key or ""), run = current.hide })
  end
  if #chat.list() > 1 then
    for _, item in ipairs({ { "next chat", config.next_chat_key, 1 }, { "prev chat", config.prev_chat_key, -1 } }) do
      table.insert(items, {
        label = string.format("%-11s %s", item[1], item[2] or ""),
        run = function()
          M.cycle(item[3])
        end,
      })
    end
    table.insert(items, { label = string.format("%-11s %s", "chats", config.chats_key or ""), run = M.chats })
  end
  if config.history then
    table.insert(items, { label = string.format("%-11s %s", "history", config.history_key or ""), run = M.history })
  end
  if current then
    for _, kind in ipairs({ "model", "effort" }) do
      table.insert(items, {
        label = string.format("%-11s %s", kind, current[kind]() or "default"),
        run = function()
          M.switch(kind)
        end,
      })
    end
  end
  table.insert(items, {
    label = string.format("%-11s %s", "theme", config.theme),
    run = function()
      vim.ui.select(require("float-claude.theme").names(), { prompt = "float-claude theme" }, function(name)
        if name then
          vim.cmd.FloatClaudeTheme(name)
        end
      end)
    end,
  })
  vim.ui.select(items, {
    prompt = "float-claude",
    format_item = function(item)
      return item.label
    end,
  }, function(item)
    if item then
      item.run()
    end
  end)
end

---Switch the open chat's `kind` ("model" or "effort") to `value`, or to one
---picked from a list (vim.ui.select) without it. It applies from the next message.
function M.switch(kind, value)
  local current = require("float-claude.chat").current()
  local claude, util = require("float-claude.claude"), require("float-claude.util")
  if not current then
    return util.error("no chat is open")
  end
  local values = kind == "model" and claude.models or claude.efforts
  local function set(v)
    if kind == "effort" and not vim.tbl_contains(values, v) then
      return util.error("unknown effort " .. v)
    end
    current["set_" .. kind](v)
  end
  if value then
    return set(value)
  end
  vim.ui.select(values, { prompt = "float-claude " .. kind }, function(v)
    if v then
      set(v)
    end
  end)
end

---Show and focus the open chat `step` places after the current one (before
---it, if negative).
function M.cycle(step)
  if not require("float-claude.chat").cycle(step) then
    require("float-claude.util").error("no chat is open")
  end
end

---Pick an open chat from a list (vim.ui.select) and show it.
function M.chats()
  local chat = require("float-claude.chat")
  local list = chat.list()
  if #list == 0 then
    return require("float-claude.util").error("no chat is open")
  end
  vim.ui.select(list, {
    prompt = "float-claude chats",
    format_item = function(c)
      local _, i = chat.find(c.id)
      local state = c.answering() and " (answering)" or c.unread() and " (new reply)" or ""
      return string.format("%d/%d %s%s", i, #list, c.label(), state)
    end,
  }, function(c)
    if c and chat.find(c.id) then
      c.focus()
    end
  end)
end

-- "5m ago", "3h ago", ...
local function ago(time)
  local secs = os.time() - time
  for _, unit in ipairs({ { 86400, "d" }, { 3600, "h" }, { 60, "m" } }) do
    if secs >= unit[1] then
      return math.floor(secs / unit[1]) .. unit[2] .. " ago"
    end
  end
  return "just now"
end

-- Reopen saved chat `saved` (see history.lua) in the window it is picked from,
-- or show it if it is open.
local function reopen(saved)
  local chat, util = require("float-claude.chat"), require("float-claude.util")
  local open = chat.find(saved.id)
  if open then
    return open.focus()
  end
  if vim.fn.filereadable(saved.file) == 0 then
    return util.error("cannot reopen the chat, its file is gone: " .. saved.file)
  end
  chat.hide() -- from the popup: back in the code
  if vim.api.nvim_buf_get_name(0) ~= saved.file then
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(saved.file))
    if not ok then
      return util.error(err)
    end
  end
  -- The file may have changed since: the ranges are kept within it, and those
  -- past its end left out (all of them: its last line).
  local count = vim.api.nvim_buf_line_count(0)
  local specs = {}
  for _, s in ipairs(saved.ranges or { saved }) do
    local rows = s.rows and vim.tbl_filter(function(row)
      return row[1] <= count
    end, s.rows)
    if s.first <= count and (not rows or #rows > 0) then
      table.insert(specs, { first = s.first, last = math.min(s.last, count), rows = rows, from = s.from })
    end
  end
  chat.open(vim.tbl_extend("force", config, {
    ranges = #specs > 0 and specs or { { first = count, last = count } },
    selected = saved.selected,
    restore = saved,
  }))
end

---Pick a saved chat about the current file or a file under the current
---directory from a list (vim.ui.select), latest first, and reopen it.
function M.history()
  local chat, util = require("float-claude.chat"), require("float-claude.util")
  if not config.history then
    return util.error("history is off")
  end
  local current = chat.current()
  local buf = in_popup() and current and current.source() or vim.api.nvim_get_current_buf()
  local file, cwd = vim.api.nvim_buf_get_name(buf), vim.fn.getcwd()
  local saved = vim.tbl_filter(function(c)
    return c.file == file or vim.startswith(c.file, cwd .. "/")
  end, require("float-claude.history").list())
  if #saved == 0 then
    return vim.api.nvim_echo({ { "float-claude: no saved chats for this file or directory" } }, false, {})
  end
  vim.ui.select(saved, {
    prompt = "float-claude history",
    format_item = function(c)
      local q = vim.trim((c.exchanges[1].q:gsub("%s+", " ")))
      return string.format("%s · L%s · %s · %s", vim.fn.fnamemodify(c.file, ":~:."),
        c.first == c.last and c.first or c.first .. "–" .. c.last, ago(c.time),
        vim.fn.strchars(q) > 50 and vim.fn.strcharpart(q, 0, 49) .. "…" or q)
    end,
  }, function(c)
    if c then
      reopen(c)
    end
  end)
end

---For a statusline: a spinner while a hidden chat is answering, a dot when
---one has a reply you have not seen, else "" (see the `status` option).
function M.status()
  return require("float-claude.chat").status(config.status)
end

function M.setup(opts)
  opts = opts or {}
  -- Actions merge one by one, so one can be changed or removed alone.
  local actions = vim.tbl_deep_extend("force", config.actions, opts.actions or {})
  config = vim.tbl_extend("force", config, opts)
  config.actions = actions
  if config.keymap then
    vim.keymap.set({ "n", "x" }, config.keymap, function()
      M.ask()
    end, { desc = "float-claude: ask Claude" })
  end
  if config.add_range_key then
    vim.keymap.set({ "n", "x" }, config.add_range_key, function()
      M.add()
    end, { desc = "float-claude: add the selection to the ranges to ask about" })
  end
  if config.clear_ranges_key then
    vim.keymap.set("n", config.clear_ranges_key, M.clear, { desc = "float-claude: clear the ranges to ask about" })
  end
  vim.api.nvim_create_user_command("FloatClaudeAdd", function(cmd)
    M.add(cmd.range > 0 and { cmd.line1, cmd.line2 } or nil)
  end, { range = true, desc = "float-claude: add the lines to the ranges to ask about" })
  vim.api.nvim_create_user_command("FloatClaudeClear", M.clear, { desc = "float-claude: clear the ranges to ask about" })
  local chat_commands = {
    { "Next", config.next_chat_key, "show the next chat", function()
      M.cycle(1)
    end },
    { "Prev", config.prev_chat_key, "show the previous chat", function()
      M.cycle(-1)
    end },
    { "Chats", config.chats_key, "pick an open chat", M.chats },
    { "History", config.history_key, "reopen a saved chat", M.history },
  }
  for _, c in ipairs(chat_commands) do
    local name, key, desc, run = unpack(c)
    vim.api.nvim_create_user_command("FloatClaude" .. name, function()
      run()
    end, { desc = "float-claude: " .. desc })
    if key then
      vim.keymap.set("n", key, run, { desc = "float-claude: " .. desc })
    end
  end
  local group = vim.api.nvim_create_augroup("float-claude", {})
  for name, action in pairs(config.actions) do
    if action and action.key then
      local function map(buf)
        vim.keymap.set({ "n", "x" }, action.key, function()
          M.run(name)
        end, { buffer = buf, desc = "float-claude: " .. name })
      end
      if action.filetypes then
        -- Mapped only in buffers of those filetypes, open ones and later ones,
        -- and in a popup whose conversation is about one.
        local function offered(buf)
          local source = vim.b[buf].float_claude_source or buf
          return vim.api.nvim_buf_is_valid(source) and vim.tbl_contains(action.filetypes, vim.bo[source].filetype)
        end
        vim.api.nvim_create_autocmd("FileType", {
          group = group,
          pattern = vim.list_extend({ "float-claude", "float-claude-transcript" }, action.filetypes),
          callback = function(ev)
            if offered(ev.buf) then
              map(ev.buf)
            end
          end,
        })
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) and offered(buf) then
            map(buf)
          end
        end
      else
        map()
      end
    end
  end
  vim.api.nvim_create_user_command("FloatClaude", function(cmd)
    M.palette(cmd.range > 0 and { cmd.line1, cmd.line2 } or nil)
  end, { range = true, desc = "float-claude: pick an action" })
  -- The colors are set once something shows them; then a new colorscheme
  -- clears them, and "auto" follows it.
  if styled() then
    restyle()
  end
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      if styled() then
        restyle()
      end
    end,
  })
  for _, kind in ipairs({ "Model", "Effort" }) do
    vim.api.nvim_create_user_command("FloatClaude" .. kind, function(cmd)
      M.switch(kind:lower(), cmd.args ~= "" and cmd.args or nil)
    end, {
      nargs = "?",
      desc = "float-claude: switch the chat's " .. kind:lower(),
      complete = function(lead)
        local claude = require("float-claude.claude")
        return vim.tbl_filter(function(v)
          return vim.startswith(v, lead)
        end, kind == "Model" and claude.models or claude.efforts)
      end,
    })
  end
  vim.api.nvim_create_user_command("FloatClaudeTheme", function(cmd)
    if not vim.tbl_contains(require("float-claude.theme").names(), cmd.args) then
      return require("float-claude.util").error(string.format('unknown theme "%s"', cmd.args))
    end
    config.theme = cmd.args
    restyle()
  end, {
    nargs = 1,
    desc = "float-claude: set the popup's theme",
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return vim.startswith(name, lead)
      end, require("float-claude.theme").names())
    end,
  })
end

return M
