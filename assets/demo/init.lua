-- The Neovim config the README's GIFs are recorded with (see assets/record.sh).
-- $FLOAT_CLAUDE_DEMO picks the scenario. Replies come from the repo's fake CLI
-- (tests/fake_claude.lua), so every recording streams the same text.
local demo = vim.env.FLOAT_CLAUDE_DEMO or "answer"
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h:h")

vim.opt.rtp:prepend(root)
if vim.env.TOKYONIGHT then
  vim.opt.rtp:prepend(vim.env.TOKYONIGHT)
  vim.cmd.colorscheme("tokyonight-night")
end

vim.g.mapleader = " "
vim.o.number = true
vim.o.swapfile = false
vim.o.ruler = false
vim.o.showcmd = false
vim.o.shortmess = vim.o.shortmess .. "IsS"
vim.o.hlsearch = false
vim.o.laststatus = 2
vim.o.statusline = " %f%=%{v:lua.require'float-claude'.status()}  "
vim.diagnostic.config({ virtual_text = false, signs = false, underline = false })

-- A reply streamed a couple of words at a time, as the CLI streams it.
local function words(text)
  local deltas = {}
  for w in text:gmatch("%s*%S+%s*%S*") do
    table.insert(deltas, w)
  end
  return deltas
end

local hash_map = [[
function M.two_sum(nums, target)
  local seen = {}
  for i, n in ipairs(nums) do
    if seen[target - n] then
      return seen[target - n], i
    end
    seen[n] = i
  end
end
]]

local replies = {
  answer = {
    words([[
ANSWER
O(n²): the two loops compare every pair in `nums`. Space is O(1).
One pass with a table of the numbers seen so far makes it O(n):
```lua
local seen = {}
for i, n in ipairs(nums) do
  if seen[target - n] then
    return seen[target - n], i
  end
  seen[n] = i
end
```]]),
  },
  edit = { "EDIT\n" .. hash_map },
  review = {
    [[
EDIT
function M.total(items, code)
  local amount = apply_discount(subtotal(items), code)
  local total = amount * (1 + TAX_RATE)
  return math.floor(total * 100 + 0.5) / 100
end
]],
  },
  hide = {
    words([[
ANSWER
`total` adds up the cart with `subtotal`, takes 10% off with `apply_discount` for the code `WELCOME10`, then adds the 20% `TAX_RATE`, so the tax is on the discounted amount.]]),
  },
  lsp = {
    words([[
ANSWER
It sums the items with `subtotal`, takes the discount off with `apply_discount`, then adds `TAX_RATE`.]]),
  },
}

vim.env.FAKE_CLAUDE_REPLIES = vim.json.encode(replies[demo])
-- Milliseconds between deltas: words for answers, lines for edits.
vim.env.FAKE_CLAUDE_DELAY = tostring(({ answer = 40, edit = 150, review = 150, hide = 60, lsp = 30 })[demo])
vim.env.FAKE_CLAUDE_LOG = "/dev/null"

require("float-claude").setup({
  cmd = { vim.v.progpath, "--clean", "--headless", "-l", root .. "/tests/fake_claude.lua" },
  review_edits = demo == "review",
  history = false,
})

if demo == "lsp" then
  local state = vim.fn.stdpath("state")
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "lua",
    callback = function(ev)
      vim.lsp.start({
        name = "lua_ls",
        cmd = { "lua-language-server", "--logpath=" .. state .. "/lua_ls", "--metapath=" .. state .. "/lua_ls" },
        root_dir = here,
      }, { bufnr = ev.buf })
    end,
  })
end
