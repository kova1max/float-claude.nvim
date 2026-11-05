-- Popup colors: "auto" (derived from the current colorscheme) or a preset, with
-- single colors overridden by the `colors` option. The FloatClaude* groups are
-- the plugin's own; everything else the popup shows (its background and the
-- syntax highlighting of code in answers) comes from a highlight namespace set
-- on the popup's windows only, so the rest of Neovim keeps its colorscheme.
local M = {}

-- Popup: bg, fg, prompt (the ❯), header, history (sent questions, notes), code
-- (inline code background; derived when unset). Code window: selection (the
-- selected lines; Visual when unset), added and removed (edit and diff lines).
-- Syntax of code in answers: comment ... property (unset: the colorscheme's).
M.presets = {
  ["float-claude"] = {
    bg = "#1c1c1f", fg = "#e6e6e6", prompt = "#3fb5c9", header = "#4e4e55", history = "#8a8a8a", code = "#2a2a2f",
    added = "#12301f", removed = "#3a1d22",
  },
  ["night-owl"] = {
    bg = "#0b2942", fg = "#d6deeb", prompt = "#7fdbca", header = "#4b6479", history = "#7e97ac",
    selection = "#1d3b53", added = "#2b4d49", removed = "#393145",
    comment = "#637777", keyword = "#c792ea", string = "#ecc48d", number = "#f78c6c", func = "#82aaff",
    type = "#ffcb8b", constant = "#ff5874", operator = "#7fdbca", property = "#baebe2",
  },
  dracula = {
    bg = "#21222c", fg = "#f8f8f2", prompt = "#bd93f9", header = "#4d5066", history = "#6272a4",
    selection = "#44475a", added = "#2a4d3c", removed = "#4d2c34",
    comment = "#6272a4", keyword = "#ff79c6", string = "#f1fa8c", number = "#bd93f9", func = "#50fa7b",
    type = "#8be9fd", constant = "#bd93f9", operator = "#ff79c6", property = "#8be9fd",
  },
  tokyonight = {
    bg = "#16161e", fg = "#c0caf5", prompt = "#7dcfff", header = "#3b4261", history = "#737aa2",
    selection = "#283457", added = "#20303b", removed = "#37222c",
    comment = "#565f89", keyword = "#9d7cd8", string = "#9ece6a", number = "#ff9e64", func = "#7aa2f7",
    type = "#2ac3de", constant = "#ff9e64", operator = "#89ddff", property = "#73daca",
  },
  catppuccin = { -- mocha
    bg = "#181825", fg = "#cdd6f4", prompt = "#cba6f7", header = "#585b70", history = "#7f849c",
    selection = "#45475a", added = "#34413e", removed = "#442f3f",
    comment = "#9399b2", keyword = "#cba6f7", string = "#a6e3a1", number = "#fab387", func = "#89b4fa",
    type = "#f9e2af", constant = "#fab387", operator = "#89dceb", property = "#b4befe",
  },
  gruvbox = { -- dark, hard contrast
    bg = "#1d2021", fg = "#ebdbb2", prompt = "#8ec07c", header = "#665c54", history = "#928374",
    selection = "#504945", added = "#3c3f22", removed = "#492825",
    comment = "#928374", keyword = "#fb4934", string = "#b8bb26", number = "#d3869b", func = "#b8bb26",
    type = "#fabd2f", constant = "#d3869b", operator = "#fe8019", property = "#83a598",
  },
  nord = {
    bg = "#3b4252", fg = "#d8dee9", prompt = "#88c0d0", header = "#616e88", history = "#9aa3b5",
    selection = "#434c5e", added = "#505b5e", removed = "#554857",
    comment = "#8a95ab", keyword = "#81a1c1", string = "#a3be8c", number = "#b48ead", func = "#88c0d0",
    type = "#8fbcbb", constant = "#81a1c1", operator = "#81a1c1", property = "#d8dee9",
  },
  onedark = {
    bg = "#21252b", fg = "#abb2bf", prompt = "#56b6c2", header = "#4b5263", history = "#7f848e",
    selection = "#3e4452", added = "#39453b", removed = "#47333a",
    comment = "#7f848e", keyword = "#c678dd", string = "#98c379", number = "#d19a66", func = "#61afef",
    type = "#e5c07b", constant = "#d19a66", operator = "#56b6c2", property = "#e06c75",
  },
  ["rose-pine"] = {
    bg = "#1f1d2e", fg = "#e0def4", prompt = "#9ccfd8", header = "#6e6a86", history = "#908caa",
    selection = "#403d52", added = "#384150", removed = "#482d42",
    comment = "#6e6a86", keyword = "#31748f", string = "#f6c177", number = "#f6c177", func = "#ebbcba",
    type = "#9ccfd8", constant = "#f6c177", operator = "#908caa", property = "#9ccfd8",
  },
}

-- Treesitter captures for each syntax color; more specific captures fall back to these.
local SYNTAX = {
  comment = { "@comment" },
  keyword = { "@keyword", "@label", "@tag" },
  string = { "@string", "@character" },
  number = { "@number", "@boolean" },
  func = { "@function" },
  type = { "@type", "@constructor", "@module" },
  constant = { "@constant", "@variable.builtin" },
  operator = { "@operator" },
  property = { "@property", "@variable.member", "@field", "@tag.attribute" },
  fg = { "@variable", "@punctuation" },
}
local KEY = {} -- capture: its SYNTAX key
for key, captures in pairs(SYNTAX) do
  for _, capture in ipairs(captures) do
    KEY[capture] = key
  end
end

-- The color in `p` for highlight group `group` ("@function.method.call"): that
-- of the nearest capture in SYNTAX it falls under ("@function").
local function syntax_color(p, group)
  local name = group
  while name do
    local key = KEY[name]
    if key then
      -- A theme without syntax colors keeps the colorscheme's plain text.
      return (key ~= "fg" or p.comment) and p[key] or nil
    end
    name = name:match("^(.+)%.[^.]+$")
  end
end

---Theme names for completion: "auto" and the presets.
function M.names()
  local names = vim.tbl_keys(M.presets)
  table.sort(names)
  return vim.list_extend({ "auto" }, names)
end

local function rgb(c)
  return type(c) == "string" and tonumber(c:sub(2), 16) or c
end

-- `a` moved a fraction `t` of the way to `b`.
local function blend(a, b, t)
  a, b = rgb(a), rgb(b)
  local out = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local x, y = bit.band(bit.rshift(a, shift), 255), bit.band(bit.rshift(b, shift), 255)
    out = out + bit.lshift(math.floor(x + (y - x) * t + 0.5), shift)
  end
  return out
end

-- The popup's colors from the current colorscheme.
local function auto()
  -- Links followed by hand: resolving them (link = false) would see the popup's
  -- namespace when it has the focus.
  local function get(name)
    local hl = vim.api.nvim_get_hl(0, { name = name })
    while hl.link do
      hl = vim.api.nvim_get_hl(0, { name = hl.link })
    end
    return hl
  end
  local normal, float = get("Normal"), get("NormalFloat")
  local dark = vim.o.background == "dark"
  local base = normal.bg or (dark and 0 or 0xffffff) -- the editor's background
  local fg = float.fg or normal.fg or (dark and 0xe6e6e6 or 0x1c1c1f)
  -- Without a border the popup needs its own background: the colorscheme's for
  -- floats, or the editor's, a little towards the text (more over a transparent
  -- one, whose real color is unknown).
  local bg = float.bg and float.bg ~= normal.bg and float.bg or blend(base, fg, normal.bg and 0.07 or 0.11)
  local add, delete = get("DiffAdd"), get("DiffDelete")
  return {
    bg = bg,
    fg = fg,
    prompt = get("Function").fg or get("Special").fg or fg,
    header = get("LineNr").fg or blend(bg, fg, 0.3),
    history = get("Comment").fg or blend(bg, fg, 0.55),
    added = add.bg or blend(base, add.fg or 0x3fb950, 0.2),
    removed = delete.bg or blend(base, delete.fg or 0xf85149, 0.2),
  }
end

local current -- the namespace of the theme applied last

---Set the colors of `name` ("auto" or a preset) with `colors` over them.
---Unknown names fall back to "auto" with an error.
---@return integer ns the namespace for the popup's windows
function M.apply(name, colors)
  local base = name == "auto" and auto() or M.presets[name]
  if not base then
    require("float-claude.util").error(string.format('unknown theme "%s"; using "auto"', tostring(name)))
    name, base = "auto", auto()
  end
  local p = vim.tbl_extend("force", base, colors or {})
  p.code = p.code or blend(p.bg, p.fg, 0.08)
  local set = vim.api.nvim_set_hl
  set(0, "FloatClaudeNormal", { fg = p.fg, bg = p.bg })
  set(0, "FloatClaudePrompt", { fg = p.prompt, bg = p.bg })
  set(0, "FloatClaudeHistory", { fg = p.history })
  set(0, "FloatClaudeHeader", { fg = p.header })
  set(0, "FloatClaudeCode", { bg = p.code })
  set(0, "FloatClaudeLink", { underline = true })
  set(0, "FloatClaudeSelection", p.selection and { bg = p.selection } or { link = "Visual" })
  set(0, "FloatClaudeAdded", { bg = p.added })
  set(0, "FloatClaudeRemoved", { bg = p.removed })

  current = vim.api.nvim_create_namespace("float-claude-theme-" .. name)
  for _, group in ipairs({ "Normal", "NormalNC", "NormalFloat", "FloatBorder", "EndOfBuffer" }) do
    set(current, group, { link = "FloatClaudeNormal" })
  end
  if p.selection then
    set(current, "Visual", { bg = p.selection })
  end
  -- The colorscheme's more specific groups ("@function.method.call") would win
  -- over the theme's general ones, so they are set here too.
  local groups = vim.tbl_keys(KEY)
  for group in pairs(vim.api.nvim_get_hl(0, {})) do
    if group:sub(1, 1) == "@" then
      table.insert(groups, group)
    end
  end
  for _, group in ipairs(groups) do
    local color = syntax_color(p, group)
    if color then
      set(current, group, { fg = color })
    end
  end
  return current
end

---The namespace of the theme applied last.
function M.ns()
  return current
end

return M
