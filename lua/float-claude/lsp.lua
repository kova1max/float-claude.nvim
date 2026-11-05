-- Looks up names from answers through the LSP clients attached to the source
-- buffer, in the background: the definition at an occurrence of the name in
-- the buffer (in the selected lines first), else a workspace symbol named so.
local M = {}

---@class float-claude.Target
---@field client_id integer
---@field location table the definition: an LSP Location or LocationLink
---@field at table? where the name occurs in the buffer (TextDocumentPositionParams)

local function request(client, method, params, handler, buf)
  if vim.fn.has("nvim-0.11") == 1 then
    client:request(method, params, handler, buf)
  else
    client.request(method, params, handler, buf)
  end
end

local function client_for(buf, method)
  return vim.lsp.get_clients({ bufnr = buf, method = method })[1]
end

-- The first line of `lines` that has `text` as whole words, lines first..last
-- first: 0-based row and byte column.
local function occurrence(lines, first, last, text)
  local pattern = "%f[%w_]" .. vim.pesc(text) .. "%f[^%w_]"
  for _, span in ipairs({ { first, last }, { 1, #lines } }) do
    for r = span[1], math.min(span[2], #lines) do
      -- A plain search first: much faster on the many lines without it.
      local col = lines[r]:find(text, 1, true) and lines[r]:find(pattern)
      if col then
        return r - 1, col - 1
      end
    end
  end
end

local function first_location(result)
  if type(result) ~= "table" or vim.tbl_isempty(result) then
    return nil
  end
  return (result.uri or result.targetUri) and result or result[1]
end

---@param s { buf: integer, first: integer, last: integer } the conversation; its selection may move
---@param on_resolved fun() called when a name was found
---@return fun(name: string, chain: string): float-claude.Target? lookup the name's target, once found
function M.resolver(s, on_resolved)
  local found = {} -- chain .. name: the target; false while looking or when not found
  local queue = {} -- names to look up, one per turn of the main loop
  local lines, tick -- the buffer's lines, as of its changedtick `tick`

  local function workspace_symbol(name, done)
    local client = client_for(s.buf, "workspace/symbol")
    if not client then
      return done(nil)
    end
    request(client, "workspace/symbol", { query = name }, function(err, result)
      for _, sym in ipairs(not err and result or {}) do
        local n = sym.name
        if (n == name or vim.endswith(n, "." .. name) or vim.endswith(n, ":" .. name)) and sym.location and sym.location.range then
          return done({ client_id = client.id, location = sym.location })
        end
      end
      done(nil)
    end, s.buf)
  end

  local function resolve(name, chain, done)
    local client = client_for(s.buf, "textDocument/definition")
    if not vim.api.nvim_buf_is_loaded(s.buf) then
      return done(nil)
    end
    if tick ~= vim.api.nvim_buf_get_changedtick(s.buf) then
      lines, tick = vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), vim.api.nvim_buf_get_changedtick(s.buf)
    end
    local row, col = occurrence(lines, s.first, s.last, chain .. name)
    if row then
      col = col + #chain
    elseif chain ~= "" then
      row, col = occurrence(lines, s.first, s.last, name)
    end
    if not (client and row) then
      return workspace_symbol(name, done)
    end
    local at = {
      textDocument = { uri = vim.uri_from_bufnr(s.buf) },
      position = { line = row, character = vim.lsp.util.character_offset(s.buf, row, col, client.offset_encoding) },
    }
    request(client, "textDocument/definition", at, function(err, result)
      local location = not err and first_location(result)
      if location then
        return done({ client_id = client.id, location = location, at = at })
      end
      workspace_symbol(name, done)
    end, s.buf)
  end

  -- Look up the first queued name, then the next one on the next turn (a
  -- timer: what vim.schedule() queues runs before Neovim reads keys again).
  local function next_name()
    local name, chain, key = unpack(table.remove(queue, 1))
    resolve(name, chain, function(target)
      found[key] = target or false
      if target then
        on_resolved()
      end
    end)
    if #queue > 0 then
      vim.defer_fn(next_name, 0)
    end
  end

  return function(name, chain)
    local key = chain .. name
    if found[key] == nil then
      if not (client_for(s.buf, "textDocument/definition") or client_for(s.buf, "workspace/symbol")) then
        return nil -- no LSP (yet): look again next time
      end
      found[key] = false
      -- Looked up later, one name a turn, so drawing and typing never wait for it.
      table.insert(queue, { name, chain, key })
      if #queue == 1 then
        vim.defer_fn(next_name, 0)
      end
    end
    return found[key] or nil
  end
end

---Show the definition in the current window.
---@param target float-claude.Target
function M.jump(target)
  local client = vim.lsp.get_client_by_id(target.client_id)
  vim.lsp.util.show_document(target.location, client and client.offset_encoding or "utf-16", { focus = true })
end

---Show hover information for the name in a floating window at the cursor.
---@param target float-claude.Target
function M.hover(target)
  local client = vim.lsp.get_client_by_id(target.client_id)
  if not client then
    return
  end
  local loc = target.location
  local at = target.at
    or { textDocument = { uri = loc.uri or loc.targetUri }, position = (loc.targetSelectionRange or loc.range).start }
  local win = vim.api.nvim_get_current_win()
  request(client, "textDocument/hover", at, function(err, result)
    local lines = {}
    if not err and result and result.contents then
      lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
      lines = vim.split(table.concat(lines, "\n"), "\n", { trimempty = true })
    end
    if vim.api.nvim_get_current_win() ~= win then
      return -- moved on meanwhile
    end
    if #lines == 0 then
      return vim.api.nvim_echo({ { "float-claude: no hover information" } }, false, {})
    end
    -- Over the borderless popup it needs a border ('winborder', if set, decides
    -- which), and its own colors, not the popup's it would inherit.
    local own_border = vim.fn.exists("+winborder") == 1 and vim.o.winborder ~= ""
    local _, hover_win = vim.lsp.util.open_floating_preview(lines, "markdown", {
      focus_id = "float-claude-hover",
      border = not own_border and "rounded" or nil,
    })
    vim.wo[hover_win].winhighlight = ""
  end)
end

return M
