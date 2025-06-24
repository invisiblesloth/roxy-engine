-- core/transitions/RoxyTransition.lua

local pd          <const> = playdate
local Scene       <const> = roxy.Scene
local Transition  <const> = roxy.Transition

local max             <const> = math.max
local pushRaw         <const> = Scene.pushRaw
local popRaw          <const> = Scene.popRaw
local replaceRaw      <const> = Scene.replaceRaw

local EMPTY_TABLE <const> = {}

local STACK_OP_REPLACE <const> = Transition.STACK_OP_REPLACE
local STACK_OP_PUSH    <const> = Transition.STACK_OP_PUSH
local STACK_OP_POP     <const> = Transition.STACK_OP_POP

local DEFAULT_TRANSITION_DURATION <const> = 1.5  -- Default transition duration in seconds
local DEFAULT_HOLD_TIME_MEDIUM    <const> = 0.25 -- Default hold time in seconds

local STATE_MIDPOINT_REACHED <const> = 1 -- Flag for midpoint event
local STATE_HOLD_ELAPSED     <const> = 2 -- Flag for hold time elapsed

local isHoldTimeAddedToDuration <const> = false

-- ----------------------------------------
-- ! Class Definition & Init
-- ----------------------------------------

class("RoxyTransition").extends()

function RoxyTransition:init(duration, holdTime, opts, stackOp)
  local opts = opts or EMPTY_TABLE
  self.opts = opts

  -- General
  self.name = opts.name or "Base"
  self.type = opts.type or "Cut"

  -- Positioning
  self.x = opts.x or 0
  self.y = opts.y or 0

  -- Accept stackOp
  self.stackOp = stackOp or STACK_OP_REPLACE

  -- Timing
  self.holdTime = holdTime or opts.holdTime or DEFAULT_HOLD_TIME_MEDIUM
  local baseDuration = duration or opts.duration or DEFAULT_TRANSITION_DURATION

  self.duration = baseDuration + (isHoldTimeAddedToDuration and self.holdTime or 0)
  self.durationEnter = max(0, opts.durationEnter or self.duration * 0.5)
  self.durationExit = max(0, opts.durationExit or self.durationEnter)

  -- Screenshots
  self.captureScreenshot = opts.captureScreenshot

  self.captureScreenshotsDuringTransition = opts.captureScreenshotsDuringTransition or false

  -- Bit-flag state tracker
  self.state = 0 -- 0 = fresh state (no midpoint or hold elapsed)

  -- ----------------------------------------
  -- Transition Lifecycle
  -- ----------------------------------------

  -- ! On transition start
  self._dispatchStart = function()
    print("[D][RoxyTransition:execute] Transition '" .. self.name .. "' started.") --#DEBUG

    local oldScene  = self._currentScene
    local stackOp   = self.stackOp

    if stackOp == STACK_OP_REPLACE then
      if oldScene then
        oldScene:exit()
      end
    end
  end

  -- ! On transition midpoint reached
  self._dispatchMidpoint = function()
    print("[D][RoxyTransition:execute] Transition '" .. self.name .. "' midpoint reached.") --#DEBUG

    if self.state & STATE_MIDPOINT_REACHED ~= 0 then return end
    self.state |= STATE_MIDPOINT_REACHED

    local stackOp   = self.stackOp
    local newScene  = self._newScene
    local oldScene  = self._currentScene

    -- Perform raw stack op without managed hooks
    if stackOp == STACK_OP_PUSH then
      pushRaw(newScene)
    elseif stackOp == STACK_OP_POP then
      popRaw()
      newScene = Scene.currentScene
    else -- Replace Scene
      replaceRaw(newScene)
    end

    -- Lifecycle hook
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
    else -- Replace Scene
      if oldScene then
        oldScene:cleanup()
      end
      if newScene then
        newScene:enter()
      end
    end

    self._newScene = newScene
  end

  -- ! On hold time elapsed
  self._dispatchHoldElapsed = function()
    self.state |= STATE_HOLD_ELAPSED
    print("[D][RoxyTransition:execute] Transition '" .. self.name .. "' hold elapsed.") --#DEBUG
  end

  -- ! On transition complete
  self._dispatchComplete = function()
    Transition.isTransitioning = false
    self:cleanup()
    Transition.currentTransition = nil

    print("[D][RoxyTransition:execute] Transition '" .. self.name .. "' completed.") --#DEBUG
  end
end

-- ----------------------------------------
-- Lifecycle Execution
-- ----------------------------------------

-- ! Execute
-- Starts the transition and binds scene lifecycle events.
function RoxyTransition:execute(newScene, currentScene)
  self._newScene      = newScene
  self._currentScene  = currentScene
  self.state          = 0 -- reset flags

  self:setUpSequence(
    self._dispatchStart,
    self._dispatchMidpoint,
    self._dispatchHoldElapsed,
    self._dispatchComplete
  )
end

-- ! Cleanup
-- Clears internal state and logs transition cleanup.
function RoxyTransition:cleanup()
  self._newScene          = nil
  self._currentScene      = nil
  self.state              = 0
  self.newSceneScreenshot = nil
  self.opts               = nil
  self.captureScreenshot  = nil

  print("[D][RoxyTransition:cleanup] Transition '" .. self.name .. "' cleanup completed.") --#DEBUG
end

-- ----------------------------------------
-- Stubs
-- ----------------------------------------

-- ! Set Up Sequence
-- Stub to be overridden in derived classes to define transition timing.
function RoxyTransition:setUpSequence(_, _, _, _)
  error("[*][RoxyTransition:setUpSequence] Must be implemented in derived class '" .. self.name .. "'.", 2) --#DEBUG
end

-- ! Draw
-- Stub to be overridden for transition rendering.
function RoxyTransition:draw()
  error("[*][RoxyTransition:draw] Must be implemented in derived class '" .. self.name .. "'.", 2) --#DEBUG
end
