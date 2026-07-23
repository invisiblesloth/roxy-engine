-- core/transitions/FadeToColor.lua

-- Playdate API
local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Image     <const> = Graphics.image

-- Roxy Framework
local r         <const> = roxy
local Config    <const> = r.Config
local Assets    <const> = r.Assets
local Registry  <const> = r.AssetPoolRegistry
local Ease      <const> = r.EasingFunctions

-- Config
local getTransitionConfig <const> = Config.getTransitionConfig

-- Assets
local getAsset      <const> = Assets.getAsset
local recycleAsset  <const> = Assets.recycleAsset
local ensurePool    <const> = Registry.ensurePool
local isFromPool    <const> = Registry.isFromPool

-- Math
local min   <const> = math.min
local floor <const> = math.floor
local ceil  <const> = math.ceil

-- Table operations
local tableRemove <const> = table.remove

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

-- Stack operations
local STACK_OP_REPLACE  <const> = RoxyTransition.STACK_OP_REPLACE
local STACK_OP_PUSH     <const> = RoxyTransition.STACK_OP_PUSH
local STACK_OP_POP      <const> = RoxyTransition.STACK_OP_POP

-- Transition binding cache
local transitionBindingCache = {}

-- FadeToColor pattern cache
local patternCache = {}
local patternCacheEntries = {}
local patternCacheBytes = 0
local patternCacheAccess = 0

local function resolveTransitionBinding(bindingName)
  local fn = transitionBindingCache[bindingName]
  if fn then return fn end

  local transition = roxy and roxy.Transition
  fn = transition and transition[bindingName]
  assert(type(fn) == "function", "[TransitionBinding] missing roxy.Transition." .. bindingName)
  transitionBindingCache[bindingName] = fn
  return fn
end

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

-- Pattern cache limits
-- The byte limit is an estimated bitmap-payload admission budget. It does not
-- represent a physical cap on native bitmap or Lua object allocations.
local PATTERN_CACHE_MAX_ENTRIES <const> = 4
local PATTERN_CACHE_MAX_BYTES   <const> = 64 * 1024

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

-- ! Get Pattern Cache Bucket
-- Return the pattern cache bucket for an effective visual configuration.
local function getPatternCacheBucket(dither, patchSize, fadeSteps)
  local byDither = patternCache[dither]
  if not byDither then
    byDither = {}
    patternCache[dither] = byDither
  end

  local byPatchSize = byDither[patchSize]
  if not byPatchSize then
    byPatchSize = {}
    byDither[patchSize] = byPatchSize
  end

  local byFadeSteps = byPatchSize[fadeSteps]
  if not byFadeSteps then
    byFadeSteps = {}
    byPatchSize[fadeSteps] = byFadeSteps
  end

  return byFadeSteps, byPatchSize, byDither
end

-- ! Get Cached Pattern Entry
-- Look up a cache entry without creating empty buckets for uncached values.
local function getCachedPatternEntry(dither, patchSize, fadeSteps, color)
  local byDither = patternCache[dither]
  local byPatchSize = byDither and byDither[patchSize]
  local byFadeSteps = byPatchSize and byPatchSize[fadeSteps]
  return byFadeSteps and byFadeSteps[color]
end

-- ! Estimate Pattern Bytes
-- Estimate one-bit bitmap payload bytes for cache admission only.
local function estimatePatternBytes(patchSize, fadeSteps)
  return fadeSteps * patchSize * ceil(patchSize / 8)
end

-- ! Is Cacheable Patch Size
-- Cache only valid bitmap dimensions so invalid runtime options continue to
-- reach the graphics API's existing validation path.
local function isCacheablePatchSize(patchSize)
  return type(patchSize) == "number"
    and patchSize > 0
    and patchSize < math.huge
    and patchSize == floor(patchSize)
end

-- ! Touch Pattern Cache Entry
-- Update recency for the small fixed-size LRU cache.
local function touchPatternCacheEntry(entry)
  patternCacheAccess += 1
  entry.lastUsed = patternCacheAccess
end

-- ! Remove Pattern Cache Entry
-- Drop the cache's strong reference while active transition instances retain
-- their own references until cleanup.
local function removePatternCacheEntry(entry)
  entry.byFadeSteps[entry.color] = nil

  if next(entry.byFadeSteps) == nil then
    entry.byPatchSize[entry.fadeSteps] = nil
    if next(entry.byPatchSize) == nil then
      entry.byDither[entry.patchSize] = nil
      if next(entry.byDither) == nil then
        patternCache[entry.dither] = nil
      end
    end
  end

  for i = #patternCacheEntries, 1, -1 do
    if patternCacheEntries[i] == entry then
      tableRemove(patternCacheEntries, i)
      break
    end
  end

  patternCacheBytes -= entry.bytes
end

-- ! Evict Pattern Cache Entries
-- Evict least-recently-used entries until a new cacheable entry fits.
local function evictPatternCacheEntries(requiredBytes)
  while #patternCacheEntries >= PATTERN_CACHE_MAX_ENTRIES
      or patternCacheBytes + requiredBytes > PATTERN_CACHE_MAX_BYTES do
    local oldestEntry = patternCacheEntries[1]
    if not oldestEntry then return end

    for i = 2, #patternCacheEntries do
      local entry = patternCacheEntries[i]
      if entry.lastUsed < oldestEntry.lastUsed then
        oldestEntry = entry
      end
    end

    removePatternCacheEntry(oldestEntry)
  end
end

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

  -- Reused sequence callbacks
  self._onMidpointFn = function() self:_onMidpoint() end
  self._onHoldElapsedFn = function() self:_onHoldElapsed() end
  self._onCompleteFn = function() self:_onComplete() end

  -- Draw binding resolved during execute
  self._drawFrame = nil
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
  local cacheable = isCacheablePatchSize(patchSize)
  local estimatedBytes

  if cacheable then
    local cachedEntry = getCachedPatternEntry(dither, patchSize, fadeSteps, color)
    if cachedEntry then
      touchPatternCacheEntry(cachedEntry)
      return cachedEntry.patterns
    end

    estimatedBytes = estimatePatternBytes(patchSize, fadeSteps)
  end

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

  if not cacheable or estimatedBytes > PATTERN_CACHE_MAX_BYTES then
    return patterns
  end

  evictPatternCacheEntries(estimatedBytes)
  local byFadeSteps, byPatchSize, byDither = getPatternCacheBucket(dither, patchSize, fadeSteps)

  local entry = {
    patterns = patterns,
    bytes = estimatedBytes,
    dither = dither,
    patchSize = patchSize,
    fadeSteps = fadeSteps,
    color = color,
    byFadeSteps = byFadeSteps,
    byPatchSize = byPatchSize,
    byDither = byDither,
  }
  touchPatternCacheEntry(entry)
  byFadeSteps[color] = entry
  patternCacheEntries[#patternCacheEntries + 1] = entry
  patternCacheBytes += estimatedBytes

  return patterns
end

-- ! Acquire Sequence
-- Acquire a sequence from the pool
function FadeToColor:_acquireSequence()
  if self.sequence then return end

  -- Pull from pool, or nil if empty
  local sequence = getAsset(SEQUENCE_POOL_KEY)
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
    :callback(self._onMidpointFn)
    :sleep(holdTime)
    :callback(self._onHoldElapsedFn)
    :to(1, 0)
    :to(0, exitTime, easeExit)
    :callback(self._onCompleteFn)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Execute
-- Main execution method
function FadeToColor:execute(newScene, currentScene)
  FadeToColor.super.execute(self, newScene, currentScene)

  self._drawFrame = resolveTransitionBinding("fadeToColorDrawFrame")
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
  local drawFrame = self._drawFrame
  if not drawFrame then
    drawFrame = resolveTransitionBinding("fadeToColorDrawFrame")
    self._drawFrame = drawFrame
  end
  drawFrame(pattern)
end

-- ! Cleanup
-- Clean up resources
function FadeToColor:cleanup()
  FadeToColor.super.cleanup(self)

  -- Release sequence back to pool
  self:_releaseSequence()

  self.patterns = nil
  self._drawFrame = nil

  Log.debug("Transition '" .. self.name .. "' cleanup completed") --#DEBUG
end

-- ! Warm Up Asset Pools
-- Public function to warm up asset pools
function FadeToColor:warmUpAssetPool()
  initializeAssetPool()
end
