-- utilities/Graphics.lua

roxy = roxy or {}
roxy.Graphics = roxy.Graphics or {}
local RoxyGraphics <const> = roxy.Graphics

local pd        <const> = playdate
local Display   <const> = pd.display

local DEFAULT_REFRESH_RATE <const>  = 30  -- Fallback to 30 FPS
local PLAYDATE_WIDTH <const>        = 400 -- Native Playdate screen width (px)
local PLAYDATE_HEIGHT <const>       = 240 -- Native Playdate screen height (px)

-- ! Get Refresh Rate
-- Returns cached display refresh rate, or 30 FPS fallback on failure.
function RoxyGraphics.getRefreshRate()
  if not RoxyGraphics.refreshRate then
    local success, rate = pcall(Display.getRefreshRate)
    RoxyGraphics.refreshRate = success and rate or DEFAULT_REFRESH_RATE
    --#DEBUG START
    if not success then
      error("[*][RoxyGraphics.getRefreshRate] Failed to query refresh rate; defaulting to 30 Hz")
    end
    --#DEBUG END
  end
  return RoxyGraphics.refreshRate
end

-- ! Get Display Size
-- Returns cached display width, height, and center coordinates.
function RoxyGraphics.getDisplaySize()
  if not RoxyGraphics.isDisplaySizeCached then
    local success, width, height = pcall(Display.getSize)
    if success then
      -- Cache dimensions and center coordinates
      RoxyGraphics.displayWidth, RoxyGraphics.displayHeight = width, height
      RoxyGraphics.displayWidthCenter, RoxyGraphics.displayHeightCenter = width / 2, height / 2
    else
      error("[*][RoxyGraphics.getDisplaySize] Failed to get display size; defaulting to 400x240") --#DEBUG

      -- Fallback to Playdate defaults
      RoxyGraphics.displayWidth, RoxyGraphics.displayHeight = PLAYDATE_WIDTH, PLAYDATE_HEIGHT
      RoxyGraphics.displayWidthCenter, RoxyGraphics.displayHeightCenter = PLAYDATE_WIDTH / 2, PLAYDATE_HEIGHT / 2
    end
    RoxyGraphics.isDisplaySizeCached = true
  end
  return RoxyGraphics.displayWidth, RoxyGraphics.displayHeight, RoxyGraphics.displayWidthCenter, RoxyGraphics.displayHeightCenter
end

-- Preload values to avoid runtime delays
RoxyGraphics.getDisplaySize()
RoxyGraphics.getRefreshRate()
