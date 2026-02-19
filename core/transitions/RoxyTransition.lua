-- core/transitions/RoxyTransition.lua

-- Playdate API
local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

-- Graphics helpers
local getDisplayImage <const> = Graphics.getDisplayImage

-- Roxy Framework
local r     <const> = roxy
local Scene <const> = r.Scene

-- Sprite helpers used during scene switching
local redrawBackground      <const> = Sprite.redrawBackground
local setBackgroundDrawing  <const> = Sprite.setBackgroundDrawingCallback

local STACK_OP_REPLACE  <const> = 0
local STACK_OP_PUSH     <const> = 1
local STACK_OP_POP      <const> = 2

-- Scene management
local pushRaw     <const> = Scene.pushRaw
local popRaw      <const> = Scene.popRaw
local replaceRaw  <const> = Scene.replaceRaw

-- Bit-flags that track where we are in the life-cycle
local STATE_MIDPOINT_REACHED  <const> = 1
local STATE_HOLD_ELAPSED      <const> = 2

--------------------------------------------------------------------------------
-- ! Class Definition & Initialization
--------------------------------------------------------------------------------

class("RoxyTransition").extends(Object)

function RoxyTransition:init(opts)
  opts = opts or {}

  -- Basic properties
  self.name = opts.name or "UnnamedTransition"
  self.type = opts.type or "Base"
  self.stackOp  = opts.stackOp or STACK_OP_REPLACE

  -- bookkeeping
  self.state = 0

  -- Screenshot
  self.captureScreenshot = opts.captureScreenshot or false
  self._capturedScreenshot = nil

  -- Scene references
  self._newScene = nil
  self._currentScene= nil
end

--------------------------------------------------------------------------------
-- Transition Lifecycle
--------------------------------------------------------------------------------

-- !  On Start
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
    end
  elseif stackOp == STACK_OP_PUSH then
    if oldScene then
      oldScene:pause()
    end
    if newScene then
      newScene:enter()
    end
  else -- Replace
    if oldScene then
      oldScene:cleanup()
    end
    if newScene then
      newScene:enter()
      local backgroundDrawFn = newScene.backgroundDrawFn or function() end
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
