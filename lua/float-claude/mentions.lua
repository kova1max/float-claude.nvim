-- @ mentions in the prompt, pulling more context into a message: @diagnostics
-- (all of the chat's file), or @<name> for an open buffer (its text as it is
-- now, saved or not) or else a file, relative to the current directory.
local util = require("float-claude.util")

local M = {}

local KEYWORDS = { diagnostics = "of the file" } -- word = what the menu says about it

-- Loaded file buffers: { buf, name relative to the current directory }.
local function buffers()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and name ~= "" then
      table.insert(out, { buf, vim.fn.fnamemodify(name, ":~:.") })
    end
  end
  return out
end

-- The open buffer `name` names: by its path, or by its file name alone when only one has it.
local function buffer_named(name)
  local full, tails = vim.fn.fnamemodify(name, ":p"), {}
  for _, b in ipairs(buffers()) do
    local bname = vim.api.nvim_buf_get_name(b[1])
    if bname == full then
      return b[1], b[2]
    end
    if vim.fn.fnamemodify(bname, ":t") == name then
      table.insert(tails, b)
    end
  end
  if #tails == 1 then
    return tails[1][1], tails[1][2]
  end
end

local function binary(path)
  local f = io.open(path, "rb")
  local head = f and f:read(8000) or ""
  if f then
    f:close()
  end
  return head:find("\0", 1, true) ~= nil
end

-- `lines` cut to `max` (also when `more` says there were more than given): the
-- lines kept, and their count, "first <max>" when cut.
local function clip(lines, max, more)
  if #lines > max or more then
    return vim.list_slice(lines, 1, max), "first " .. max, true
  end
  return lines, tostring(#lines), false
end

-- "1 line", "first 3 lines".
local function count(n, unit)
  return n .. " " .. (n == "1" and unit:sub(1, -2) or unit)
end

-- What `name` (a mention without its @) stands for: { key, label, text }, or nil.
local function resolve(name, buf, max)
  if name == "diagnostics" then
    local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
    file = file == "" and "[No Name]" or file
    local lines, n, cut = clip(util.diagnostics(buf), max, false)
    if #lines == 0 then
      return { key = name, label = "diagnostics (none)", text = string.format("@diagnostics: %s has no diagnostics.", file) }
    end
    return {
      key = name,
      label = string.format("diagnostics (%s)", n),
      text = string.format("@diagnostics, those of %s (%s%s):\n%s", file, count(n, "diagnostics"),
        cut and "; the rest were not sent" or "", table.concat(lines, "\n")),
    }
  end
  local b, shown = buffer_named(name)
  local lines, more, kind
  if b then
    lines, kind = vim.api.nvim_buf_get_lines(b, 0, -1, false), "an open buffer, its text as it is now"
  else
    local path = vim.fs.normalize(name)
    if vim.fn.filereadable(path) == 0 then
      return nil
    end
    shown = vim.fn.fnamemodify(path, ":~:.")
    if binary(path) then
      return { key = vim.fn.fnamemodify(path, ":p"), label = shown .. " (binary, not sent)",
        text = string.format("@%s: a binary file, not sent.", shown) }
    end
    lines, kind = vim.fn.readfile(path, "", max + 1), "a file"
    more = #lines > max
  end
  local n, cut
  lines, n, cut = clip(lines, max, more)
  return {
    key = b or vim.fn.fnamemodify(shown, ":p"),
    label = string.format("%s (%s)", shown, count(n, "lines")),
    text = string.format('@%s: %s (%s%s):\n<mention name="%s">\n%s\n</mention>', shown, kind, count(n, "lines"),
      cut and "; the rest was not sent" or "", shown, table.concat(lines, "\n")),
  }
end

---What `text` mentions with @ (an @ at its start or after a space), each once,
---in order: { label (for the conversation), text (for the message) }. A
---mention that names nothing is left as it is, plain text.
---@param buf integer the chat's buffer, the one @diagnostics is about
---@param opts { max_lines: integer } the `mentions` option
function M.expand(text, buf, opts)
  local out, seen = {}, {}
  for name in text:gmatch("%f[%S]@(%S+)") do
    -- "see @a.lua." mentions a.lua.
    local m = resolve(name, buf, opts.max_lines)
    local bare = name:gsub("[%.,;:!?%)%]}'\"`]+$", "")
    if not m and bare ~= name and bare ~= "" then
      m = resolve(bare, buf, opts.max_lines)
    end
    if m and not seen[m.key] then
      seen[m.key] = true
      table.insert(out, m)
    end
  end
  return out
end

-- The mention before the cursor: its 0-based start column (after the @) and
-- the text typed so far, or nil.
local function typed()
  local line = vim.api.nvim_get_current_line():sub(1, vim.fn.col(".") - 1)
  local at = line:match("()@%S*$")
  if at and (at == 1 or line:sub(at - 1, at - 1):match("%s")) then
    return at, line:sub(at + 1)
  end
end

-- What may follow `base` after an @: the keywords, open buffers, and files and
-- directories (ending in /).
local function candidates(base)
  local items, seen = {}, {}
  for word, info in pairs(KEYWORDS) do
    if vim.startswith(word, base) then
      table.insert(items, { word = word, menu = info })
    end
  end
  for _, b in ipairs(buffers()) do
    if vim.startswith(b[2], base) or vim.startswith(vim.fn.fnamemodify(b[2], ":t"), base) then
      seen[b[2]] = true
      table.insert(items, { word = b[2], menu = "buffer" })
    end
  end
  for _, path in ipairs(vim.fn.getcompletion(base, "file")) do
    if not seen[path] then
      table.insert(items, { word = path, menu = vim.endswith(path, "/") and "directory" or "file" })
    end
  end
  return items
end

---'omnifunc' of the prompt: completes the mention before the cursor.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local col = typed()
    return col or -3
  end
  return candidates(base)
end

---Complete mentions in prompt buffer `buf` with the built-in completion
---(<C-x><C-o>), and as they are typed where 'completeopt' allows a menu that
---inserts nothing by itself: always from Neovim 0.11 (it is set for the
---buffer), on 0.10 when the global value has noinsert or noselect.
function M.attach(buf, group)
  vim.bo[buf].omnifunc = "v:lua.require'float-claude.mentions'.omnifunc"
  if vim.api.nvim_get_option_info2("completeopt", {}).scope == "buf" then
    vim.bo[buf].completeopt = "menuone,noselect"
  elseif not (vim.o.completeopt:find("noinsert") or vim.o.completeopt:find("noselect")) then
    return
  end
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = group,
    buffer = buf,
    callback = function()
      local col, base = typed()
      if not col or vim.fn.pumvisible() == 1 then
        return
      end
      -- Not for a mention just completed: only it would be listed.
      local items = vim.tbl_filter(function(item)
        return item.word ~= base or vim.endswith(base, "/")
      end, candidates(base))
      if #items > 0 then
        vim.api.nvim_feedkeys(vim.keycode("<C-x><C-o>"), "n", false)
      end
    end,
  })
end

return M
