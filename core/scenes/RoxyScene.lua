-- core/scenes/RoxyScene.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics

-- Constants
local BLACK       <const> = Graphics.kColorBlack
local CLEAR_COLOR <const> = BLACK

-- Aliases
local clearScreen   <const> = Graphics.clear
local setDrawOffset <const> = Graphics.setDrawOffset

-- ----------------------------------------
-- Class Definition & Init
-- ----------------------------------------

class("RoxyScene").extends()

--! Initialize
function RoxyScene:init()
  self.name = self.className or "RoxyScene"
  print("[D][RoxyScene:init] Initializing Scene: " .. self.name) --#DEBUG

  self.isPaused = false
  self._didEnter = false
  self._didExit = false
  self._didCleanup = false
end

-- ----------------------------------------
-- Scene Lifecycle (Core Methods)
-- ----------------------------------------

-- ! Enter
function RoxyScene:enter()
  if self._didEnter then return end
  self._didEnter = true
  print("[D][RoxyScene:enter] Entering Scene: " .. self.name) --#DEBUG
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
end

-- ! Resume
function RoxyScene:resume()
  if not self.isPaused then return end
  print("[D][RoxyScene:resume] Resuming Scene: " .. self.name) --#DEBUG
  self.isPaused = false
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

  self:resetDrawOffset()
  -- self:clearScreen()
end

-- TODO: Add sprite management methods etc. HERE

-- ----------------------------------------
-- ! Public API
-- ----------------------------------------

function RoxyScene:resetDrawOffset()
  setDrawOffset(0, 0)
end

function RoxyScene:clearScreen()
  clearScreen(CLEAR_COLOR)
end
