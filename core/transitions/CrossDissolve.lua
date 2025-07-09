-- core/transitions/CrossDissolve.lua

-- Playdate API
local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite
local Image     <const> = Graphics.image

-- Roxy Framework
local r           <const> = roxy
local Config      <const> = r.Config
local Assets      <const> = r.Assets
local Ease        <const> = r.EasingFunctions
local Scene       <const> = r.Scene
local Transition  <const> = r.Transition

-- Config
local getTransitionConfig <const> = Config.getTransitionConfig

-- Assets
local registerPool        <const> = Assets.registerPool
local getIsPoolRegistered <const> = Assets.getIsPoolRegistered
local getAsset            <const> = Assets.getAsset
local recycleAsset        <const> = Assets.recycleAsset

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

-- Sprite
local redrawBackground      <const> = Sprite.redrawBackground
local setBackgroundDrawing  <const> = Sprite.setBackgroundDrawingCallback

-- Scene management
local pushRaw     <const> = Scene.pushRaw
local popRaw      <const> = Scene.popRaw
local replaceRaw  <const> = Scene.replaceRaw

-- Easing
local flatEasing    <const> = Ease.flat
local linearEasing  <const> = Ease.linear

-- C-side binding
local drawFaded_C <const> = Transition.crossDissolveDrawFrame

-- Stack operations
local STACK_OP_REPLACE <const> = Transition.STACK_OP_REPLACE
local STACK_OP_PUSH    <const> = Transition.STACK_OP_PUSH
local STACK_OP_POP     <const> = Transition.STACK_OP_POP

-- State flags for tracking transition progress
local STATE_MIDPOINT_REACHED <const> = 1
local STATE_HOLD_ELAPSED     <const> = 2

-- Graphics constants
local DRAW_MODE_COPY    <const> = Graphics.kDrawModeCopy
local DITHER_BAYER_8X8  <const> = Image.kDitherTypeBayer8x8
local DITHER_DEFAULT    <const> = DITHER_BAYER_8X8

-- Defaults
local DURATION_DEFAULT    <const> = 1.5
local EASE_DEFAULT        <const> = linearEasing
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
local EMPTY_TABLE <const> = {}

-- Module-level initialization flag
local assetsInitialized = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Initialize Asset Pool
-- Initialize asset pools (called once per module)
local function initializeAssetPool()
  if assetsInitialized then return end

  if not getIsPoolRegistered(SEQUENCE_POOL_KEY) then
    registerPool(SEQUENCE_POOL_KEY, 2, function() return RoxySequence() end, {
      maxSize = 1,
      growthFactor = 0
    })
  end

  assetsInitialized = true
end

--------------------------------------------------------------------------------
-- ! Class Definition & Initialization
--------------------------------------------------------------------------------

class("CrossDissolve").extends()

function CrossDissolve:init(opts)
  opts = opts or EMPTY_TABLE

  --#DEBUG START
  if opts.holdTime then
    Log.warn("holdTime has no effect on CrossDissolve")
  end
  if opts.easeEnter or opts.easeExit then
    Log.warn("easeEnter and easeExit are ignored for Mix type. Use ease instead")
  end
  --#DEBUG END

  -- Initialize asset pool on first use
  initializeAssetPool()

  -- Get base configuration for this transition type
  local baseConfig = getTransitionConfig("CrossDissolve")

  -- Build final configuration with runtime options
  local builder = ConfigBuilder(baseConfig)
    :with(opts)

  local config = builder:build()

  -- Basic properties
  self.name = config.name or "CrossDissolve"
  self.type = "Mix"
  self.stackOp = config.stackOp or STACK_OP_REPLACE
  local duration = config.duration or DURATION_DEFAULT
  self.duration = duration

  -- Visual properties
  self.dither = config.ditherPattern or DITHER_DEFAULT
  self.fadeSteps = config.fadeSteps or FADE_STEPS_DEFAULT
  self.patchSize = config.patchSize or nil
  self.drawMode = DRAW_MODE_COPY

  -- Pre-calculate optimization
  self.fadeStepsMinus1 = self.fadeSteps - 1

  -- State tracking
  self.state = 0

  -- Easing configuration
  self.ease = config.ease or EASE_DEFAULT

  -- Initialize patterns and sequence
  self.patterns = self:_createPatternArray()
  self:_acquireSequence()

  -- Screenshots
  self._screenshot = nil
  self.captureScreenshot = config.captureScreenshot or false

  -- Scene references
  self._newScene = nil
  self._currentScene = nil
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
    local alpha = i * oneOverSteps
    local base = newImage(patchSize, patchSize)
    pushContext(base)
      clear()
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

  local sequence = getAsset(SEQUENCE_POOL_KEY)
  if not sequence then
    -- Fallback if pool is empty
    sequence = RoxySequence()
  end

  self.sequence = sequence
end

-- ! Release Sequence
-- Release sequence back to pool
function CrossDissolve:_releaseSequence()
  local sequence = self.sequence
  if not sequence then return end

  sequence:clear(true)
  recycleAsset(SEQUENCE_POOL_KEY, sequence)
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
    :to(0, 0, flatEasing)
    :callback(function() self._screenshot = getDisplayImage() end)
    :to(0, 0, flatEasing)
    :callback(function() self:_onMidpoint() end)
    :to(0, 0, flatEasing)
    :callback(function() self:_onHoldElapsed() end)
    :from(0)
    :to(1, duration, ease)
    :callback(function() self:_onComplete() end)
end

--------------------------------------------------------------------------------
-- Transition Lifecycle
--------------------------------------------------------------------------------

-- ! On Start
function CrossDissolve:_onStart()
  Log.debug("Transition '" .. self.name .. "' started") --#DEBUG

  if self.stackOp == STACK_OP_REPLACE and self._currentScene then
    self._currentScene:exit()
  end
end

-- ! On Midpoint
function CrossDissolve:_onMidpoint()
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

  self._newScene = newScene
end

-- ! On Hold Elapsed
function CrossDissolve:_onHoldElapsed()
  self.state |= STATE_HOLD_ELAPSED
  Log.debug("Transition '" .. self.name .. "' hold elapsed") --#DEBUG
end

-- ! On Complete
function CrossDissolve:_onComplete()
  Transition.isTransitioning = false
  Transition.currentTransition = nil
  self:cleanup()
  Log.debug("Transition '" .. self.name .. "' completed") --#DEBUG
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Execute
-- Main execution method
function CrossDissolve:execute(newScene, currentScene)
  self._newScene = newScene
  self._currentScene = currentScene
  self.state = 0 -- Reset state flags

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

  drawFaded_C(screenshot, pattern)
end

-- ! Cleanup
-- Clean up resources
function CrossDissolve:cleanup()
  self._newScene = nil
  self._currentScene = nil
  self.state = 0

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
