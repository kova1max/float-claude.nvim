local M = {}

-- Where the two numbers in `nums` that
-- add up to `target` are.
function M.two_sum(nums, target)
  for i = 1, #nums do
    for j = i + 1, #nums do
      if nums[i] + nums[j] == target then
        return i, j
      end
    end
  end
end

return M
