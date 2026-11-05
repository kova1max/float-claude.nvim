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
---`retention` ({ max = count, days = age }; either may be false). A chat's
---age is its file's: it is written when saved.
function M.save(chat, retention)
  vim.fn.mkdir(dir(), "p")
  -- Without an fsync, which can take milliseconds; a chat is saved after each reply.
  vim.fn.writefile({ vim.json.encode(chat) }, path(chat.id), "S")
  -- From the files' times: reading every saved chat would take long.
  local files = {}
  for name, kind in vim.fs.dir(dir()) do
    local stat = kind == "file" and name:match("%.json$") and vim.uv.fs_stat(vim.fs.joinpath(dir(), name))
    if stat then
      table.insert(files, { name = name, time = stat.mtime.sec + stat.mtime.nsec / 1e9 })
    end
  end
  table.sort(files, function(a, b)
    return a.time > b.time
  end)
  local cutoff = retention.days and os.time() - retention.days * 86400
  for i, file in ipairs(files) do
    if (retention.max and i > retention.max) or (cutoff and file.time < cutoff) then
      os.remove(vim.fs.joinpath(dir(), file.name))
    end
  end
end

return M
