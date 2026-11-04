-- One headless Claude Code CLI process per popup conversation, spoken to over
-- stream-json on stdio so follow-ups reuse the same session.
local M = {}

M.system_prompt = [[You are a coding assistant inside Neovim. The user selected some lines of a file and typed a request about them.
Reply in exactly one of two forms:
- If the request asks to change the selected code, the first line is EDIT and every following line is the complete replacement for the selected lines only: code only, keep the file's indentation, no code fences, no explanation.
- Otherwise the first line is ANSWER followed by a short answer in plain text. Put names from the code (functions, variables, types, fields) in inline `code`, and code snippets in fenced code blocks; no other markdown (no headings, bold or tables). Be brief.
Every message carries the selected lines and their context as they are at that moment: the user may have changed them, or applied or discarded your edits, since. Always treat the code in the latest message as the truth and ignore earlier versions; context said to be unchanged is the one last sent. An EDIT replaces the selected lines of that latest version.
A follow-up starts with what happened to the code since your last reply: whether your EDIT was applied (with its diff) or discarded, and diffs of the changes the user made by hand. It also lists your applied edits so far, numbered. Use this record to tell your own work from the user's: a change is yours only if it came from one of your applied edits, and a hand change may rework or undo one of them. To undo one of your edits, reply with an EDIT of the current selected lines with that change reverted.]]

local ARGS = {
  "-p",
  "--input-format",
  "stream-json",
  "--output-format",
  "stream-json",
  "--verbose",
  "--include-partial-messages",
  -- A plain chat: no tools, MCP servers, hooks, settings, skills or saved session.
  "--tools",
  "",
  "--strict-mcp-config",
  "--setting-sources",
  "",
  "--disable-slash-commands",
  "--no-session-persistence",
}

---@class float-claude.Process
---@field send fun(text: string)
---@field stop fun()

---Start the CLI. Callbacks run on the main loop. `instructions` are the user's
---own, added after the built-in system prompt.
---@param opts { cmd: string[], instructions: string?, on_delta: fun(text: string), on_done: fun(), on_error: fun(msg: string) }
---@return float-claude.Process? process
---@return string? err
function M.start(opts)
  local cmd = vim.list_extend(vim.deepcopy(opts.cmd), ARGS)
  local system_prompt = M.system_prompt
  if opts.instructions then
    system_prompt = system_prompt
      .. "\n\nThe user's own instructions follow. Follow them, but the reply format above (the EDIT or ANSWER first line, and an EDIT being code only) always comes first:\n"
      .. opts.instructions
  end
  vim.list_extend(cmd, { "--system-prompt", system_prompt })

  local stopped, busy, failed = false, false, false
  local pending, stderr = "", ""

  local function fail(msg)
    if not failed and not stopped then
      failed = true
      opts.on_error(msg)
    end
  end

  local function handle(line)
    local ok, event = pcall(vim.json.decode, line)
    if not ok or type(event) ~= "table" then
      return
    end
    if event.type == "stream_event" then
      local e = event.event
      if e.type == "content_block_delta" and e.delta.type == "text_delta" then
        opts.on_delta(e.delta.text)
      end
    elseif event.type == "result" then
      busy = false
      if event.is_error then
        fail(type(event.result) == "string" and event.result or ("request failed (" .. tostring(event.subtype) .. ")"))
      else
        opts.on_done()
      end
    end
  end

  local ok, proc = pcall(vim.system, cmd, {
    stdin = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          if stopped then
            return
          end
          pending = pending .. data
          for line in pending:gmatch("([^\n]*)\n") do
            handle(line)
          end
          pending = pending:match("[^\n]*$")
        end)
      end
    end,
    stderr = function(_, data)
      stderr = stderr .. (data or "")
    end,
  }, function(out)
    vim.schedule(function()
      if busy or out.code ~= 0 then
        local reason = vim.trim(stderr):match("[^\n]+")
        fail(reason or ("claude exited with code " .. out.code))
      end
    end)
  end)
  if not ok then
    return nil, "cannot run " .. opts.cmd[1] .. " (is Claude Code installed?)"
  end

  return {
    send = function(text)
      busy = true
      proc:write(vim.json.encode({ type = "user", message = { role = "user", content = text } }) .. "\n")
    end,
    stop = function()
      if not stopped then
        stopped = true
        proc:kill("sigterm")
      end
    end,
  }
end

return M
