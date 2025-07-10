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
local DITHER_BASE_SIZES <const> = {
  [Image.kDitherTypeNone]           = PATCH_SIZE_DEFAULT, -- Default patch size
  [Image.kDitherTypeDiagonalLine]   = 8,  -- Matches 8px diagonal repeat
  [Image.kDitherTypeVerticalLine]   = 8,  -- Matches 8px vertical repeat
  [Image.kDitherTypeHorizontalLine] = 8,  -- Matches 8px horizontal repeat
  [Image.kDitherTypeScreen]         = 8,  -- 8x8 screen pattern
  [Image.kDitherTypeBayer2x2]       = 4,  -- 2x2 Bayer, tile at 4
  [Image.kDitherTypeBayer4x4]       = 8,  -- 4x4 Bayer, tile at 8
  [Image.kDitherTypeBayer8x8]       = 16, -- 8x8 Bayer, tile at 16
  [Image.kDitherTypeFloydSteinberg] = 8,  -- Error diffusion, use 8
  [Image.kDitherTypeBurkes]         = 8,  -- Burkes error diffusion
  [Image.kDitherTypeAtkinson]       = 8,  -- Atkinson error diffusion
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
  self.dither = config.dither or DITHER_DEFAULT
  self.fadeSteps = config.fadeSteps or FADE_STEPS_DEFAULT
  self.patchSize = config.patchSize or nil

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
  local patterns = {}

  -- Cache frequently accessed properties for performance
  local fadeSteps = self.fadeSteps
  local oneOverSteps = 1 / fadeSteps
  local dither = self.dither
  local patchSize = self.patchSize or DITHER_BASE_SIZES[dither] or PATCH_SIZE_DEFAULT
  local tiles = ceil(TILE_SIZE / patchSize)

  for i = 0, fadeSteps do
    local alpha = 1 - (i * oneOverSteps)
    local base = newImage(patchSize, patchSize)
    pushContext(base)
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
    :to(0, 0, FLAT_EASING)
    :callback(function() self._screenshot = getDisplayImage() end)
    :to(0, 0, FLAT_EASING)
    :callback(function() self:_onMidpoint() end)
    :to(0, 0, FLAT_EASING)
    :callback(function() self:_onHoldElapsed() end)
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
  self:_onStart()
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
