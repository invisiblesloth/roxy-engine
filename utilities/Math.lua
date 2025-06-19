-- utilities/Math.lua

roxy = roxy or {}
roxy.Math = roxy.Math or {}
local Math <const> = roxy.Math

-- Is NaN
-- Returns true if the value is NaN (not equal to itself).
function Math.isNaN(x)
  return x ~= x
end