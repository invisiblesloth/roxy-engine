-- Most math utilities can be found in `roxy/utilities/roxy_math.c`

roxy = roxy or {}
roxy.math = roxy.math or {}

-- Checks if a value is NaN (Not-a-Number)
-- In Lua, the only value that is not equal to itself is NaN, so this function
-- returns true if x is NaN and false otherwise.
function roxy.math.isNaN(x)
	return x ~= x  -- NaN is the only value that doesn't equal itself.
end
