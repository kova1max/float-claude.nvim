local M = {}

local TAX_RATE = 0.2

local function subtotal(items)
  local sum = 0
  for _, item in ipairs(items) do
    sum = sum + item.price * item.qty
  end
  return sum
end

---Takes 10% off with the code WELCOME10.
local function apply_discount(amount, code)
  if code == "WELCOME10" then
    return amount * 0.9
  end
  return amount
end

function M.total(items, code)
  local amount = apply_discount(subtotal(items), code)
  return amount * (1 + TAX_RATE)
end

return M
