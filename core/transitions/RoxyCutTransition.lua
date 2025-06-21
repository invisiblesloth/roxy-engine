-- core/transitions/RoxyCutTransition.lua

local Scene       <const> = roxy.Scene
local Transition  <const> = roxy.Transition

local EMPTY_TABLE <const> = {}

class("RoxyCutTransition").extends(RoxyTransition)

function RoxyCutTransition:init(duration, holdTime, opts, stackOp)
  local opts = opts or EMPTY_TABLE
  
  RoxyCutTransition.super.init(self, duration, holdTime, opts, stackOp)
  
  self.name = opts.name or "Cut"
  self.type = opts.type or "Cut"
end

function RoxyCutTransition:setUpSequence(onStart, onMidpoint, onHoldTimeElapsed, onComplete)
  -- Cut transitions are instant, so we just run the lifecycle functions without timing
  onStart()
  onMidpoint()
  onHoldTimeElapsed()
  onComplete()
end