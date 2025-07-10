-- core/transitions/Cut.lua

-- Playdate API
local pd <const> = playdate

-- Roxy Framework
local r           <const> = roxy
local Config      <const> = r.Config
local Transition  <const> = r.Transition

-- Config
local getTransitionConfig <const> = Config.getTransitionConfig

-- Expose stack-op constants so children don’t need to re-require them
local STACK_OP_REPLACE <const> = Transition.STACK_OP_REPLACE
local STACK_OP_PUSH    <const> = Transition.STACK_OP_PUSH
local STACK_OP_POP     <const> = Transition.STACK_OP_POP

-- Utility constants
local EMPTY_TABLE <const> = {}

--------------------------------------------------------------------------------
-- ! Class Definition & Initialization
--------------------------------------------------------------------------------

class("Cut").extends(RoxyTransition)

function Cut:init(opts)
  opts = opts or EMPTY_TABLE

  --#DEBUG START
  if opts.duration or opts.holdTime then
    Log.warn("duration/holdTime ignored for cut transitions")
  end
  --#DEBUG END

  -- Get base configuration for this transition type
  local baseConfig = getTransitionConfig("Cut")

  -- Build final configuration with runtime options
  local builder = ConfigBuilder(baseConfig)
    :with(opts)

  local config = builder:build()

  -- Call parent constructor with processed config
  Cut.super.init(self, {
    name = config.name or "Cut",
    type = "Cut",
    stackOp = config.stackOp or STACK_OP_REPLACE,
    captureScreenshot = config.captureScreenshot or false
  })

  -- Cut-specific properties (overridden to be 0 for instant transitions)
  self.duration = 0
  self.holdTime = 0
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Execute
-- Main execution method - Cut transitions happen immediately
function Cut:execute(newScene, currentScene)
  Cut.super.execute(self, newScene, currentScene)

  -- Execute all lifecycle methods immediately for instant transition
  self:_onStart()
  self:_onMidpoint()
  self:_onHoldElapsed()
  self:_onComplete()
end
