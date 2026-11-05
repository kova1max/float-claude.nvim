-- :checkhealth float-claude
local M = {}

-- The options holding a key mapped in Normal mode by setup() for every buffer.
local KEYS = { "keymap", "add_range_key", "clear_ranges_key", "next_chat_key", "prev_chat_key", "chats_key", "history_key" }

function M.check()
  local health = vim.health
  local config = require("float-claude").config()
  health.start("float-claude")

  local v = vim.version()
  local version = string.format("Neovim %d.%d.%d", v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.10") == 1 then
    health.ok(version)
  else
    health.error(version .. ": float-claude needs Neovim 0.10 or later")
  end

  if vim.fn.exists(":FloatClaude") == 2 then
    health.ok("setup() has run")
  else
    health.warn("setup() has not run: no keys or commands yet", {
      'Call require("float-claude").setup(), or with lazy.nvim give the plugin `opts = {}`',
    })
  end

  local exe = config.cmd[1]
  if vim.fn.executable(exe) == 0 then
    health.error(exe .. " not found", {
      "Install Claude Code (https://claude.com/claude-code), then run `claude` once and sign in",
      "Or set `cmd` in setup() to the CLI's path",
    })
  else
    local out = vim.system({ exe, "--version" }, { text = true }):wait(5000)
    local line = out.code == 0 and (out.stdout or ""):match("[^\n]+")
    if line then
      health.ok(string.format("%s: %s", exe, vim.trim(line)))
    else
      health.warn(exe .. " --version failed: " .. vim.trim(out.stderr or ""):match("[^\n]*"))
    end
    health.info("Replies need the CLI signed in: run `" .. exe .. "` once in a terminal if you have not")
  end

  local keys = {}
  for _, name in ipairs(KEYS) do
    table.insert(keys, { name, config[name] })
  end
  for name, action in pairs(config.actions) do
    if action and not action.filetypes then
      table.insert(keys, { "actions." .. name, action.key })
    end
  end
  local taken = 0
  for _, key in ipairs(keys) do
    local name, lhs = key[1], key[2]
    local map = lhs and vim.fn.maparg(lhs, "n", false, true) or {}
    if lhs and not vim.tbl_isempty(map) and not vim.startswith(map.desc or "", "float-claude") then
      taken = taken + 1
      health.warn(string.format("%s (%s) is mapped by something else: %s", lhs, name, map.desc or map.rhs or "a Lua function"), {
        "Change the key in setup(), or the other mapping",
      })
    end
  end
  if taken == 0 and vim.fn.exists(":FloatClaude") == 2 then
    health.ok("No other mapping took the plugin's keys")
  end

  if config.history then
    health.info("Chats are saved in " .. vim.fs.joinpath(vim.fn.stdpath("state"), "float-claude"))
  end
end

return M
