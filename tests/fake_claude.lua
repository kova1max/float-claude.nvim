-- Stand-in for `claude -p --input-format stream-json --output-format stream-json`.
-- Run with `nvim -l`. For each user message read from stdin it streams the next
-- reply from $FAKE_CLAUDE_REPLIES (a JSON list) as text deltas, then a result.
-- A reply is a string streamed one line per delta, or a list of the deltas.
-- A reply "!error <msg>" ends the turn with an error result; "!exit <msg>" prints
-- <msg> to stderr and exits 1. Control requests get a control response. With
-- $FAKE_CLAUDE_MODEL, each turn starts with an init event naming it. Received
-- messages are appended to $FAKE_CLAUDE_LOG.
local replies = vim.json.decode(os.getenv("FAKE_CLAUDE_REPLIES"))
local delay = tonumber(os.getenv("FAKE_CLAUDE_DELAY") or "0")
local log = io.open(os.getenv("FAKE_CLAUDE_LOG"), "a")
log:write(vim.json.encode({ argv = arg }), "\n")
log:flush()

local function emit(event)
  io.stdout:write(vim.json.encode(event), "\n")
  io.stdout:flush()
end

local turn = 0
for line in io.stdin:lines() do
  log:write(line, "\n")
  log:flush()
  local msg = vim.json.decode(line)
  if msg.type == "control_request" then
    -- Answered right away; a model named "bad" is refused.
    local r = msg.request
    if r.subtype == "set_model" and r.model == "bad" then
      emit({ type = "control_response", response = { subtype = "error", request_id = msg.request_id, error = "Model 'bad' not found" } })
    else
      emit({ type = "control_response", response = { subtype = "success", request_id = msg.request_id } })
    end
    goto continue
  end
  turn = turn + 1
  if os.getenv("FAKE_CLAUDE_MODEL") then
    emit({ type = "system", subtype = "init", model = os.getenv("FAKE_CLAUDE_MODEL") })
  end
  local reply = replies[turn] or ""
  local deltas = type(reply) == "table" and reply or nil
  if deltas then
    reply = table.concat(deltas)
  end
  if reply:match("^!exit ") then
    io.stderr:write(reply:sub(7), "\n")
    os.exit(1)
  elseif reply:match("^!error ") then
    emit({ type = "result", subtype = "error_during_execution", is_error = true, result = reply:sub(8) })
  else
    deltas = deltas or vim.iter(reply:gmatch("[^\n]*\n?")):totable()
    for _, chunk in ipairs(deltas) do
      if chunk ~= "" then
        emit({ type = "stream_event", event = { type = "content_block_delta", delta = { type = "text_delta", text = chunk } } })
        vim.uv.sleep(delay)
      end
    end
    emit({ type = "result", subtype = "success", is_error = false, result = reply })
  end
  ::continue::
end
