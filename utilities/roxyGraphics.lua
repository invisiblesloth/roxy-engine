local pd <const> = playdate
local Display <const> = pd.display
local Graphics <const> = pd.graphics

roxy = roxy or {}
roxy.graphics = {}

-- Returns the display's refresh rate, caching it after the first successful retrieval.
-- If the refresh rate is already cached, it returns the cached value.
-- If the retrieval fails, an error is thrown.
function roxy.graphics.getRefreshRate()
	if not roxy.graphics.refreshRate then
		local success, rate = pcall(Display.getRefreshRate)  -- Safe call to get the refresh rate
		if success then
			roxy.graphics.refreshRate = rate  -- Cache the refresh rate for future calls
		else
			error("ERROR: Failed to get refresh rate: " .. tostring(rate))  -- Handle failure
		end
	end
	return roxy.graphics.refreshRate  -- Return the cached or newly retrieved refresh rate
end

-- Returns the display size, along with the center coordinates.
-- Caches the values after the first successful retrieval to avoid redundant calls.
-- If the retrieval fails, an error is thrown.
function roxy.graphics.getDisplaySize()
	if not (roxy.graphics.displayWidth and roxy.graphics.displayHeight and roxy.graphics.displayWidthCenter and roxy.graphics.displayHeightCenter) then
		local success, width, height = pcall(Display.getSize)  -- Safe call to get the display size
		if success then
			-- Cache the width, height, and center coordinates
			roxy.graphics.displayWidth, roxy.graphics.displayHeight = width, height
			roxy.graphics.displayWidthCenter, roxy.graphics.displayHeightCenter = width / 2, height / 2
		else
			error("Failed to get display size: " .. tostring(width))  -- Handle failure
		end
	end
	-- Return the cached or newly retrieved display dimensions and center coordinates
	return roxy.graphics.displayWidth, roxy.graphics.displayHeight, roxy.graphics.displayWidthCenter, roxy.graphics.displayHeightCenter
end
