local M = {}

local defaults = {
  -- Normal + visual mode mapping that opens the popup. `false` disables it.
  keymap = "<leader>ai",
}

local function notify(msg, level)
  vim.notify("floatcc: " .. msg, level or vim.log.levels.ERROR)
end

-- "@file#L3-5" on its own first line, then the prompt. The newline also makes
-- claudecode.nvim send everything as one bracketed paste, so Claude Code does not
-- open its file picker on the typed "@" and swallow the submitting Enter.
local function message(prompt, context)
  if not context then
    return prompt
  end
  local mention = "@" .. vim.fn.fnamemodify(context.file, ":.")
  if context.first_line then
    mention = string.format("%s#L%d-%d", mention, context.first_line, context.last_line)
  end
  return mention .. "\n" .. prompt
end

-- The file (or line range) under the cursor, or nil for buffers that are not files.
local function capture_context()
  local file = vim.api.nvim_buf_get_name(0)
  if vim.bo.buftype ~= "" or file == "" or vim.fn.filereadable(file) == 0 then
    return nil
  end
  local context = { file = file, modified = vim.bo.modified }
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    context.first_line, context.last_line = math.min(a, b), math.max(a, b)
  end
  return context
end

local function send(prompt, context)
  if prompt:match("^%s*$") then
    return
  end
  local ok, claudecode = pcall(require, "claudecode")
  if not ok then
    return notify("coder/claudecode.nvim is not installed")
  end
  local terminal = require("claudecode.terminal")
  if not terminal.send_to_terminal then
    return notify("claudecode.nvim is too old: update it to a version with :ClaudeCodeSendText")
  end
  if context and context.modified then
    notify("buffer has unsaved changes; Claude reads the file from disk", vim.log.levels.WARN)
  end
  local focus = claudecode.state.config.focus_after_send

  local function deliver()
    if terminal.send_to_terminal(message(prompt, context), { focus = focus }) and not focus then
      terminal.ensure_visible()
    end
  end

  if terminal.get_active_terminal_bufnr() then
    return deliver()
  end

  -- No Claude session yet: start one and send once Claude Code has connected back.
  if not claudecode.state.server and not claudecode.start(false) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  terminal.ensure_visible()
  -- The snacks provider focuses a newly started terminal even when asked not to.
  vim.api.nvim_set_current_win(win)
  local deadline = vim.uv.now() + claudecode.state.config.connection_timeout
  local function wait()
    if claudecode.is_claude_connected() then
      -- Give the freshly started prompt a moment to accept input.
      vim.defer_fn(deliver, claudecode.state.config.connection_wait_delay)
    elseif vim.uv.now() < deadline and terminal.get_active_terminal_bufnr() then
      vim.defer_fn(wait, 100)
    else
      notify("Claude Code did not connect; prompt not sent")
    end
  end
  wait()
end

---Open the popup at the cursor and send the prompt to Claude Code, with the
---current file (normal mode) or the selected lines (visual mode) attached.
function M.ask()
  local context = capture_context()
  if vim.fn.mode():match("^[vV\22]") then
    vim.cmd("normal! \27")
  end
  require("floatcc.input").open({
    multiline = true,
    on_submit = function(text)
      send(text, context)
    end,
  })
end

function M.setup(opts)
  opts = vim.tbl_deep_extend("force", defaults, opts or {})
  if opts.keymap then
    vim.keymap.set({ "n", "x" }, opts.keymap, M.ask, { desc = "floatcc: ask Claude" })
  end
end

return M
