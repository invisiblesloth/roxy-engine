-- core/transitions/RoxyTransition.lua

-- Playdate API
local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

-- Roxy Framework
local r     <const> = roxy
local Scene <const> = r.Scene

-- Graphics
local getDisplayImage       <const> = Graphics.getDisplayImage
local redrawBackground      <const> = Sprite.redrawBackground
local setBackgroundDrawing  <const> = Sprite.setBackgroundDrawingCallback

-- Scene management
local pushRaw     <const> = Scene.pushRaw
local popRaw      <const> = Scene.popRaw
local replaceRaw  <const> = Scene.replaceRaw

-- Stack operations
local STACK_OP_REPLACE  <const> = 0
local STACK_OP_PUSH     <const> = 1
local STACK_OP_POP      <const> = 2

-- State flags
local STATE_MIDPOINT_REACHED  <const> = 1
local STATE_HOLD_ELAPSED      <const> = 2

-- Utility constants
local NO_OP_BG_DRAW <const> = function(x, y, width, height) end

--------------------------------------------------------------------------------
-- ! Class Definition & Initialization
--------------------------------------------------------------------------------

class("RoxyTransition").extends(Object)

-- ! Initialize
function RoxyTransition:init(opts)
  opts = opts or {}

  -- Basic properties
  self.name = opts.name or "UnnamedTransition"
  self.type = opts.type or "Base"
  self.stackOp  = opts.stackOp or STACK_OP_REPLACE

  -- Bookkeeping
  self.state = 0

  -- Screenshot
  self.captureScreenshot = opts.captureScreenshot or false
  self._capturedScreenshot = nil

  -- Scene references
  self._newScene = nil
  self._currentScene = nil
end

--------------------------------------------------------------------------------
-- Transition Lifecycle
--------------------------------------------------------------------------------

-- ! On Start
function RoxyTransition:_onStart()
  Log.debug("Transition '" .. self.name .. "' started") --#DEBUG

  if self.stackOp == STACK_OP_REPLACE and self._currentScene then
    self._currentScene:exit()
  end
end

-- ! On Midpoint
function RoxyTransition:_onMidpoint()
  Log.debug("Transition '" .. self.name .. "' midpoint reached") --#DEBUG

  if self.state & STATE_MIDPOINT_REACHED ~= 0 then return end
  self.state |= STATE_MIDPOINT_REACHED

  local stackOp = self.stackOp
  local newScene = self._newScene
  local oldScene = self._currentScene

  -- Perform stack operation
  if stackOp == STACK_OP_PUSH then
    pushRaw(newScene)
  elseif stackOp == STACK_OP_POP then
    popRaw()
    newScene = Scene.currentScene
  else -- Replace
    replaceRaw(newScene)
  end

  -- Handle scene lifecycle
  if stackOp == STACK_OP_POP then
    if oldScene then
      oldScene:cleanup()
    end
    if newScene then
      newScene:resume()
      local backgroundDrawFn = newScene.backgroundDrawFn or NO_OP_BG_DRAW
      setBackgroundDrawing(backgroundDrawFn)
      redrawBackground()
    end
  elseif stackOp == STACK_OP_PUSH then
    if oldScene then
      oldScene:pause()
    end
    if newScene then
      newScene:enter()
      local backgroundDrawFn = newScene.backgroundDrawFn or NO_OP_BG_DRAW
      setBackgroundDrawing(backgroundDrawFn)
      redrawBackground()
    end
  else -- Replace
    if oldScene then
      oldScene:cleanup()
    end
    if newScene then
      newScene:enter()
      local backgroundDrawFn = newScene.backgroundDrawFn or NO_OP_BG_DRAW
      setBackgroundDrawing(backgroundDrawFn)
      redrawBackground()
    end
  end

  -- Hand the screenshot to the new (incoming) scene and make it its background
  if self._capturedScreenshot then
    -- Handoff
    newScene.frozenBackground = self._capturedScreenshot

    -- Set as background
    if newScene.setBackground then
      newScene:setBackground(self._capturedScreenshot)
    end

    self._capturedScreenshot = nil -- Scene now owns it
  end

  self._newScene = newScene
end

-- ! On Hold Elapsed
function RoxyTransition:_onHoldElapsed()
  self.state |= STATE_HOLD_ELAPSED
  Log.debug("Transition '" .. self.name .. "' hold elapsed") --#DEBUG
end

-- ! On Complete
function RoxyTransition:_onComplete()
  local scene = self._newScene
  local completedName = self.name

  if scene and scene.start then
    scene:start()
  end

  local transition = roxy and roxy.Transition
  assert(type(transition) == "table", "[RoxyTransition] missing roxy.Transition during completion")
  transition.isTransitioning = false
  transition.currentTransition = nil

  local flushBusySummary = transition._flushBusyTransitionSummary
  if type(flushBusySummary) == "function" then
    flushBusySummary(completedName)
  end

  self:cleanup()
  Log.debug("Transition '" .. self.name .. "' completed") --#DEBUG
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Execute
function RoxyTransition:execute(newScene, currentScene)
  self._newScene     = newScene
  self._currentScene = currentScene
  self.state         = 0

  -- Capture screenshot of the current (outgoing) scene if requested.
  -- Do this once, before any visual effect starts.
  if self.captureScreenshot and currentScene then
    self._capturedScreenshot = getDisplayImage()
  end
end

-- ! Cleanup
function RoxyTransition:cleanup()
  self._newScene     = nil
  self._currentScene = nil
  self.state         = 0
  self._capturedScreenshot  = nil
end

-- Re-export constants so children can reference them via RoxyTransition
RoxyTransition.STATE_MIDPOINT_REACHED = STATE_MIDPOINT_REACHED
RoxyTransition.STATE_HOLD_ELAPSED     = STATE_HOLD_ELAPSED
RoxyTransition.STACK_OP_REPLACE       = STACK_OP_REPLACE
RoxyTransition.STACK_OP_PUSH          = STACK_OP_PUSH
RoxyTransition.STACK_OP_POP           = STACK_OP_POP

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

RoxyTransition is the base lifecycle helper for transition effects.
Subclasses call the lifecycle hooks when their visual timing reaches each phase.

-- Custom Instant Transition
class("FlashCut").extends(RoxyTransition)

function FlashCut:init(opts)
  opts = opts or {}
  FlashCut.super.init(self, {
    name = opts.name or "FlashCut",
    type = "Custom",
    stackOp = opts.stackOp or RoxyTransition.STACK_OP_REPLACE,
    captureScreenshot = opts.captureScreenshot or false,
  })
end

function FlashCut:execute(newScene, currentScene)
  FlashCut.super.execute(self, newScene, currentScene)
  self:_onStart()
  self:_onMidpoint()
  self:_onHoldElapsed()
  self:_onComplete()
end

-- Timed Transition Skeleton
class("HoldThenCut").extends(RoxyTransition)

function HoldThenCut:init(opts)
  opts = opts or {}
  HoldThenCut.super.init(self, {
    name = opts.name or "HoldThenCut",
    type = "Custom",
    stackOp = opts.stackOp or RoxyTransition.STACK_OP_REPLACE,
    captureScreenshot = true,
  })
  self.duration = opts.duration or 0.4
end

function HoldThenCut:execute(newScene, currentScene)
  HoldThenCut.super.execute(self, newScene, currentScene)
  self:_onStart()

  playdate.timer.performAfterDelay(self.duration * 500, function()
    self:_onMidpoint()
  end)
  playdate.timer.performAfterDelay(self.duration * 1000, function()
    self:_onHoldElapsed()
    self:_onComplete()
  end)
end

-- Register With Transition Module
roxy.Transition.loadTransitions({
  FlashCut = FlashCut,
  HoldThenCut = HoldThenCut,
})
roxy.Transition.replaceScene(GameplayScene, "FlashCut")

--]]
