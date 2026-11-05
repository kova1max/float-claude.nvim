-- Saved chats: one JSON file each under stdpath("state")/float-claude, so a
-- chat can be reopened after Neovim restarts.
local M = {}

local function dir()
  return vim.fs.joinpath(vim.fn.stdpath("state"), "float-claude")
end

local function path(id)
  return vim.fs.joinpath(dir(), id .. ".json")
end

---The saved chats, the latest first. A chat is { id, time, cwd, file, first,
---last, selected, session, model, effort, exchanges, edits }.
function M.list()
  local out = {}
  if vim.fn.isdirectory(dir()) == 0 then
    return out
  end
  for name, kind in vim.fs.dir(dir()) do
    if kind == "file" and name:match("%.json$") then
      local ok, chat = pcall(vim.json.decode, table.concat(vim.fn.readfile(vim.fs.joinpath(dir(), name)), "\n"),
        { luanil = { object = true, array = true } })
      if ok and type(chat) == "table" and type(chat.id) == "string" and type(chat.time) == "number" then
        table.insert(out, chat)
      end
    end
  end
  table.sort(out, function(a, b)
    return a.time > b.time
  end)
  return out
end

---Save `chat`, replacing its earlier save, then delete the chats beyond
---`retention` ({ max = count, days = age }; either may be false).
function M.save(chat, retention)
  vim.fn.mkdir(dir(), "p")
  vim.fn.writefile({ vim.json.encode(chat) }, path(chat.id))
  local cutoff = retention.days and os.time() - retention.days * 86400
  for i, saved in ipairs(M.list()) do
    if (retention.max and i > retention.max) or (cutoff and saved.time < cutoff) then
      os.remove(path(saved.id))
    end
  end
end

return M
