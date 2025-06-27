-- core/scenes/RoxyScene.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite
local r         <const> = roxy

local clearScreen         <const> = Graphics.clear
local setColor            <const> = Graphics.setColor
local setDrawOffset       <const> = Graphics.setDrawOffset
local setBackgroundColor  <const> = Graphics.setBackgroundColor
local fillRect            <const> = Graphics.fillRect

local redrawBackground    <const> = Sprite.redrawBackground

local addHandler    <const> = r.Input.addHandler
local removeHandler <const> = r.Input.removeHandler

local COLOR_WHITE <const> = Graphics.kColorWhite
local COLOR_BLACK <const> = Graphics.kColorBlack
local CLEAR_COLOR <const> = COLOR_WHITE

local _colorCallbacks = {} -- Cache: color --> fn

-- ----------------------------------------
-- Helper
-- ----------------------------------------

-- ! Helper: Get Color Callback
-- builds (and returns) a drawing callback for a solid color
local function _getColorCallback(color)
  local fn = _colorCallbacks[color]
  if fn == nil then
    fn = function(x, y, width, height)
      setColor(color)
      fillRect(x, y, width, height) -- Draw only the dirty rect
    end
    _colorCallbacks[color] = fn
  end
  return fn
end

-- ----------------------------------------
-- Class Definition & Init
-- ----------------------------------------

class("RoxyScene").extends()

--! Initialize
function RoxyScene:init(background)
  self.name = self.className or "RoxyScene"
  print("[D][RoxyScene:init] Initializing Scene: " .. self.name) --#DEBUG

  self.isPaused = false
  self._didEnter = false
  self._didExit = false
  self._didCleanup = false

  self.inputHandler = {}

  self.backgroundColor = nil
  self.backgroundImage = nil
  self.backgroundDrawFn = function(x, y, width, height) end

  self:setBackground(background)
end

-- ----------------------------------------
-- Scene Lifecycle
-- ----------------------------------------

-- ! Enter
function RoxyScene:enter()
  if self._didEnter then return end
  self._didEnter = true
  print("[D][RoxyScene:enter] Entering Scene: " .. self.name) --#DEBUG
  self:addHandler()
end

-- ! Update
function RoxyScene:update()
  -- noop by default
end

-- ! Pause
function RoxyScene:pause()
  if self.isPaused then return end
  print("[D][RoxyScene:pause] Pausing Scene: " .. self.name) --#DEBUG
  self.isPaused = true
  removeHandler(self)
end

-- ! Resume
function RoxyScene:resume()
  if not self.isPaused then return end
  print("[D][RoxyScene:resume] Resuming Scene: " .. self.name) --#DEBUG
  self.isPaused = false
  self:addHandler()
end

-- ! Exit
function RoxyScene:exit()
  if self._didExit then return end
  self._didExit = true
  print("[D][RoxyScene:exit] Exiting Scene: " .. self.name) --#DEBUG
end

-- ! Cleanup
function RoxyScene:cleanup()
  if self._didCleanup then return end
  self._didCleanup = true

  print("[D][RoxyScene:cleanup] Cleaning Up Scene: " .. self.name) --#DEBUG

  removeHandler(self)
  self:resetDrawOffset()

  self.backgroundColor = nil
  self.backgroundImage = nil
  self.backgroundDrawFn = nil
  self.frozenBackground = nil
end

-- TODO: Add sprite management methods etc. HERE

-- ----------------------------------------
-- Background Drawing
-- ----------------------------------------

-- ! Set Background
function RoxyScene:setBackground(background)
  -- Solid color
  if background == nil or type(background) == "number" then
    local color = background or CLEAR_COLOR
    print("[D][RoxyScene:setBackground] Setting background color to " .. color)
    setBackgroundColor(color)
    self.backgroundColor = color
    self.backgroundImage = nil
    self.backgroundDrawFn = _getColorCallback(color)
    redrawBackground()
    return
  end

  -- Background image
  if type(background) == "userdata" then
    print("[D][RoxyScene:setBackground] Setting background image")
    local img = background
    self.backgroundColor = nil
    self.backgroundImage = img
    self.backgroundDrawFn = function(x, y, width, height)
      img:draw(x, y, nil, x, y, width, height)
    end
    redrawBackground()
    return
  end

  print("[D][RoxyScene:setBackground] Falling back to background color: " .. CLEAR_COLOR)
  -- Fallback
  setBackgroundColor(CLEAR_COLOR)
  self.backgroundColor = CLEAR_COLOR
  self.backgroundImage = nil
  self.backgroundDrawFn = _getColorCallback(CLEAR_COLOR)
  redrawBackground()
end

-- ----------------------------------------
-- Utilities
-- ----------------------------------------

-- ! Set Input Handler
function RoxyScene:addHandler()
  if self.inputHandler and (type(self.inputHandler) == "table" or type(self.inputHandler) == "function") then
    addHandler(self, self.inputHandler, 0)
  end
end

-- ! Reset Draw Offset
function RoxyScene:resetDrawOffset()
  setDrawOffset(0, 0)
end

-- ! Clear Screen
function RoxyScene:clearScreen()
  clearScreen(CLEAR_COLOR)
end
