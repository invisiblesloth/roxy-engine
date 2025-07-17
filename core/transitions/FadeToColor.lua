-- core/transitions/FadeToColor.lua

-- Playdate API
local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Image     <const> = Graphics.image

-- Roxy Framework
local r           <const> = roxy
local Config      <const> = r.Config
local Assets      <const> = r.Assets
local Registry    <const> = r.AssetPoolRegistry
local Ease        <const> = r.EasingFunctions
local Transition  <const> = r.Transition

-- Config
local getTransitionConfig <const> = Config.getTransitionConfig

-- Assets
local getAsset            <const> = Assets.getAsset
local recycleAsset        <const> = Assets.recycleAsset
local ensurePool          <const> = Registry.ensurePool
local markFromPool        <const> = Registry.markFromPool
local isFromPool          <const> = Registry.isFromPool

-- Math
local min   <const> = math.min
local floor <const> = math.floor

-- Graphics
local pushContext       <const> = Graphics.pushContext
local popContext        <const> = Graphics.popContext
local setColor          <const> = Graphics.setColor
local setDitherPattern  <const> = Graphics.setDitherPattern
local fillRect          <const> = Graphics.fillRect
local newImage          <const> = Image.new

-- Easing
local getEaseEnter  <const> = Ease.enter
local getEaseExit   <const> = Ease.exit

-- C-side binding
local drawTiled_C <const> = Transition.fadeToColorDrawFrame

-- Stack operations
local STACK_OP_REPLACE <const> = Transition.STACK_OP_REPLACE
local STACK_OP_PUSH    <const> = Transition.STACK_OP_PUSH
local STACK_OP_POP     <const> = Transition.STACK_OP_POP

-- Graphics constants
local COLOR_BLACK       <const> = Graphics.kColorBlack
local DITHER_BAYER_8X8  <const> = Image.kDitherTypeBayer8x8

-- Easing constants
local OUT_IN_QUAD <const> = Ease.outInQuad

-- Defaults
local DURATION_DEFAULT    <const> = 1.5
local HOLD_TIME_DEFAULT   <const> = 0.25
local EASE_DEFAULT        <const> = OUT_IN_QUAD
local COLOR_DEFAULT       <const> = COLOR_BLACK
local DITHER_DEFAULT      <const> = DITHER_BAYER_8X8
local FADE_STEPS_DEFAULT  <const> = 65
local PATCH_SIZE_DEFAULT  <const> = 16

-- Dither pattern configs
local DITHER_LIMITS <const> = {
  [Image.kDitherTypeNone]           = { size = 8,  steps = 2  },
  [Image.kDitherTypeDiagonalLine]   = { size = 8,  steps = 5  },
  [Image.kDitherTypeVerticalLine]   = { size = 8,  steps = 5  },
  [Image.kDitherTypeHorizontalLine] = { size = 8,  steps = 5  },
  [Image.kDitherTypeScreen]         = { size = 8,  steps = 5  },
  [Image.kDitherTypeBayer2x2]       = { size = 4,  steps = 5  },
  [Image.kDitherTypeBayer4x4]       = { size = 8,  steps = 17 },
  [Image.kDitherTypeBayer8x8]       = { size = 16, steps = 65 },
  [Image.kDitherTypeFloydSteinberg] = { size = 8,  steps = 17 },
  [Image.kDitherTypeBurkes]         = { size = 8,  steps = 17 },
  [Image.kDitherTypeAtkinson]       = { size = 8,  steps = 17 },
}

-- Utility constants
local SEQUENCE_POOL_KEY <const> = "Transition_Sequence"
local EMPTY_TABLE       <const> = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Initialize Asset Pool
-- Initialize asset pools (called once per module)
local function initializeAssetPool()
  ensurePool(
    SEQUENCE_POOL_KEY,
    1,
    function() return RoxySequence() end, {
      maxSize = 4,
      growthFactor = 1
    })
end

--------------------------------------------------------------------------------
-- ! Class Definition & Initialization
--------------------------------------------------------------------------------

class("FadeToColor").extends(RoxyTransition)

function FadeToColor:init(opts)
  opts = opts or EMPTY_TABLE

  -- Get base configuration for this transition type
  local baseConfig = getTransitionConfig("FadeToColor")

  -- Build final configuration with runtime options
  local builder = TableBuilder(baseConfig)
    :with(opts)

  local config = builder:build()

  -- Initialize asset pool on first use
  initializeAssetPool()

  -- Call parent constructor
  FadeToColor.super.init(self, {
    name = config.name or "FadeToColor",
    type = "Cover",
    stackOp = config.stackOp or STACK_OP_REPLACE,
    captureScreenshot = config.captureScreenshot or false
  })

  -- FadeToColor-specific properties
  local duration = config.duration or DURATION_DEFAULT
  self.duration = duration
  self.holdTime = config.holdTime or HOLD_TIME_DEFAULT

  -- Visual properties
  self.color = config.color or COLOR_DEFAULT
  local dither = config.dither or DITHER_DEFAULT
  self.dither = dither
  local ditherConf = DITHER_LIMITS[dither] or { size = PATCH_SIZE_DEFAULT, steps = FADE_STEPS_DEFAULT }
  self.fadeSteps = min(config.fadeSteps or ditherConf.steps, ditherConf.steps)
  self.patchSize = config.patchSize or ditherConf.size

  -- Pre-calculate optimization
  self.fadeStepsMinus1 = self.fadeSteps - 1

  -- Easing configuration
  local ease = config.ease or EASE_DEFAULT
  self.ease = ease
  self.easeEnter = config.easeEnter or getEaseEnter(ease) or ease
  self.easeExit = config.easeExit or getEaseExit(ease) or ease

  -- Pre-calculate timing values for performance
  local halfHold = self.holdTime / 2
  self.enterTime = (duration / 2) - halfHold
  self.exitTime = (duration / 2) - halfHold

  -- Initialize patterns and sequence
  self.patterns = self:_createPatternArray()
  self:_acquireSequence()
end

--------------------------------------------------------------------------------
-- Private Methods
--------------------------------------------------------------------------------

-- ! Create Pattern Array
-- Create dithered pattern array for fade effect
function FadeToColor:_createPatternArray()
  -- Cache frequently accessed properties for performance
  local dither = self.dither
  local fadeSteps = self.fadeSteps
  local patchSize = self.patchSize
  local color = self.color
  local oneOverSteps = 1 / (fadeSteps - 1)

  local patterns = {}
  for i = 1, fadeSteps do
    local alpha = 1.0 - ((i - 1) * oneOverSteps)
    local img = newImage(patchSize, patchSize)
    pushContext(img)
      setColor(color)
      -- Calculate opacity: starts at 1.0 (opaque) and decreases to 0.0 (transparent)
      setDitherPattern(alpha, dither)
      fillRect(0, 0, patchSize, patchSize)
    popContext()
    patterns[i] = img
  end

  return patterns
end

-- ! Acquire Sequence
-- Acquire a sequence from the pool
function FadeToColor:_acquireSequence()
  if self.sequence then return end

  -- Pull from pool (tagged), or nil if empty
  local sequence = markFromPool(getAsset(SEQUENCE_POOL_KEY))
  if not sequence then
    sequence = RoxySequence() -- Fallback
  end

  self.sequence = sequence
end

-- ! Release Sequence
-- Release sequence back to pool
function FadeToColor:_releaseSequence()
  local sequence = self.sequence
  if not sequence then return end

  sequence:clear(true)

  -- Only recycle if it came from the pool
  if isFromPool(sequence) then
    recycleAsset(SEQUENCE_POOL_KEY, sequence)
  end

  self.sequence = nil
end

-- ! Set Up Sequence
-- Configure the animation sequence
function FadeToColor:_setupSequence()
  local sequence = self.sequence
  if not sequence then return end

  -- Use pre-calculated timing values
  local enterTime = self.enterTime
  local exitTime = self.exitTime
  local holdTime = self.holdTime
  local easeEnter = self.easeEnter
  local easeExit = self.easeExit

  sequence
    :from(0)
    :to(1, enterTime, easeEnter)
    :callback(function() self:_onMidpoint() end)
    :sleep(holdTime)
    :callback(function() self:_onHoldElapsed() end)
    :to(1, 0)
    :to(0, exitTime, easeExit)
    :callback(function() self:_onComplete() end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Execute
-- Main execution method
function FadeToColor:execute(newScene, currentScene)
  FadeToColor.super.execute(self, newScene, currentScene)

  self:_setupSequence()
  self:_onStart()
  self.sequence:play()
end

-- ! Draw
-- Render the transition effect
function FadeToColor:draw()
  local sequence = self.sequence
  if not sequence then return end

  local alpha = sequence:getValue()
  if not alpha or alpha <= 0 then return end

  -- Cache for performance in frequently called method
  local fadeSteps = self.fadeSteps
  local fadeStepsMinus1 = self.fadeStepsMinus1
  local patterns = self.patterns

  -- Calculate pattern index based on alpha value
  local idx = min(fadeSteps, floor(alpha * fadeStepsMinus1) + 1)
  -- patterns[idx]:drawTiled(0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT)
  local pattern = patterns[idx]
  drawTiled_C(pattern)
end

-- ! Cleanup
-- Clean up resources
function FadeToColor:cleanup()
  FadeToColor.super.cleanup(self)

  -- Release sequence back to pool
  self:_releaseSequence()

  self.patterns = nil

  Log.debug("Transition '" .. self.name .. "' cleanup completed") --#DEBUG
end

-- ! Warm Up Asset Pools
-- Public function to warm up asset pools
function FadeToColor:warmUpAssetPool()
  initializeAssetPool()
end
