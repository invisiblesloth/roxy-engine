-- core/transitions/CrossDissolve.lua

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
local Scene       <const> = r.Scene
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
local ceil  <const> = math.ceil

-- Graphics
local clear             <const> = Graphics.clear
local pushContext       <const> = Graphics.pushContext
local popContext        <const> = Graphics.popContext
local setColor          <const> = Graphics.setColor
local setDitherPattern  <const> = Graphics.setDitherPattern
local getDisplayImage   <const> = Graphics.getDisplayImage
local fillRect          <const> = Graphics.fillRect
local newImage          <const> = Image.new

-- C-side binding
local drawFrame_C <const> = Transition.crossDissolveDrawFrame

-- Stack operations
local STACK_OP_REPLACE <const> = Transition.STACK_OP_REPLACE
local STACK_OP_PUSH    <const> = Transition.STACK_OP_PUSH
local STACK_OP_POP     <const> = Transition.STACK_OP_POP

-- Graphics constants
local COLOR_BLACK       <const> = Graphics.kColorBlack
local COLOR_WHITE       <const> = Graphics.kColorWhite
local DITHER_BAYER_8X8  <const> = Image.kDitherTypeBayer8x8

-- Easing constants
local FLAT_EASING    <const> = Ease.flat
local LINEAR_EASING  <const> = Ease.linear

-- Defaults
local DURATION_DEFAULT    <const> = 1.5
local EASE_DEFAULT        <const> = LINEAR_EASING
local DITHER_DEFAULT      <const> = DITHER_BAYER_8X8
local FADE_STEPS_DEFAULT  <const> = 32
local PATCH_SIZE_DEFAULT  <const> = 8

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
local TILE_SIZE <const> = 32

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
    SEQUENCE_POOL_KEY,  -- key
    1,                  -- initialCount
    function() return RoxySequence() end, {
      maxSize = 4,
      growthFactor = 1
    })
end

--------------------------------------------------------------------------------
-- ! Class Definition & Initialization
--------------------------------------------------------------------------------

class("CrossDissolve").extends(RoxyTransition)

function CrossDissolve:init(opts)
  opts = opts or EMPTY_TABLE

  --#DEBUG START
  if opts.holdTime then
    Log.warn("holdTime has no effect on CrossDissolve transitions")
  end
  --#DEBUG END

  -- Get base configuration for this transition type
  local baseConfig = getTransitionConfig("CrossDissolve")

  -- Build final configuration with runtime options
  local builder = ConfigBuilder(baseConfig)
    :with(opts)

  local config = builder:build()

  -- Initialize asset pool on first use
  initializeAssetPool()

  -- Call parent constructor
  CrossDissolve.super.init(self, {
    name = config.name or "CrossDissolve",
    type = "Mix",
    stackOp = config.stackOp or STACK_OP_REPLACE,
    captureScreenshot = config.captureScreenshot or false
  })

  -- CrossDissolve-specific properties
  local duration = config.duration or DURATION_DEFAULT
  self.duration = duration

  -- Visual properties
  local dither = config.dither or DITHER_DEFAULT
  self.dither = dither
  local ditherConf = DITHER_LIMITS[dither] or { size = PATCH_SIZE_DEFAULT, steps = FADE_STEPS_DEFAULT }
  self.fadeSteps = min(config.fadeSteps or ditherConf.steps, ditherConf.steps)
  self.patchSize = config.patchSize or ditherConf.size

  -- Pre-calculate optimization
  self.fadeStepsMinus1 = self.fadeSteps - 1

  -- Easing configuration
  self.ease = config.ease or EASE_DEFAULT

  -- Initialize patterns and sequence
  self.patterns = self:_createPatternArray()
  self:_acquireSequence()

  -- Screenshots
  self._screenshot = nil
end

--------------------------------------------------------------------------------
-- Private Methods
--------------------------------------------------------------------------------

-- ! Create Pattern Array
-- Create dithered pattern array for dissolve effect
function CrossDissolve:_createPatternArray()
  -- Cache frequently accessed properties for performance
  local dither = self.dither
  local fadeSteps = self.fadeSteps
  local patchSize = self.patchSize
  local oneOverSteps = 1 / (fadeSteps - 1)
  local tiles = ceil(TILE_SIZE / patchSize)

  local patterns = {}
  for i = 0, fadeSteps do
    local alpha = 1.0 - ((i - 1) * oneOverSteps)
    local base = newImage(patchSize, patchSize)
    pushContext(base)
      setColor(COLOR_WHITE)
      clear(COLOR_BLACK)
      -- Calculate opacity: starts at 1.0 (opaque) and decreases to 0.0 (transparent)
      setDitherPattern(alpha, dither)
      fillRect(0, 0, patchSize, patchSize)
    popContext()

    -- Tile to TILE_SIZE x TILE_SIZE
    local tileImage = newImage(TILE_SIZE, TILE_SIZE)
    pushContext(tileImage)
      for y = 0, tiles - 1 do
        for x = 0, tiles - 1 do
          base:draw(x * patchSize, y * patchSize)
        end
      end
    popContext()

    patterns[i] = tileImage
  end

  return patterns
end

-- ! Acquire Sequence
-- Acquire a sequence from the pool
function CrossDissolve:_acquireSequence()
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
function CrossDissolve:_releaseSequence()
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
function CrossDissolve:_setupSequence()
  local sequence = self.sequence
  if not sequence then return end

  -- Use pre-calculated timing values
  local duration = self.duration
  local ease = self.ease

  sequence
    :from(0)
    :to(1, duration, ease)
    :callback(function() self:_onComplete() end)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Execute
-- Main execution method
function CrossDissolve:execute(newScene, currentScene)
  CrossDissolve.super.execute(self, newScene, currentScene)

  self:_setupSequence()
  self._screenshot = getDisplayImage()
  self:_onStart()
  self:_onMidpoint()
  self:_onHoldElapsed()
  self.sequence:start()
end

-- ! Draw
-- Render the transition effect
function CrossDissolve:draw()
  local screenshot = self._screenshot
  if not screenshot then return end

  local alpha = 1 - self.sequence:getValue()
  if alpha <= 0 then return end

  -- Cache for performance in frequently called method
  local fadeSteps = self.fadeSteps
  local fadeStepsMinus1 = self.fadeStepsMinus1
  local patterns = self.patterns

  -- Calculate pattern index based on alpha value
  local idx = min(fadeSteps, floor(alpha * fadeStepsMinus1) + 1)
  local pattern = patterns[idx]
  drawFrame_C(screenshot, pattern)
end

-- ! Cleanup
-- Clean up resources
function CrossDissolve:cleanup()
  -- Call parent cleanup first
  CrossDissolve.super.cleanup(self)

  -- Release sequence back to pool
  self:_releaseSequence()

  self.patterns = nil
  self._screenshot = nil

  Log.debug("Transition '" .. self.name .. "' cleanup completed") --#DEBUG
end

-- ! Warm Up Asset Pools
-- Public function to warm up asset pools
function CrossDissolve:warmUpAssetPool()
  initializeAssetPool()
end
