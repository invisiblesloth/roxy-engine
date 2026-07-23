-- core/transitions/ImageTable.lua

-- Playdate API
local pd        <const> = playdate
local Graphics  <const> = pd.graphics

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
local getOriginKey  <const> = Registry.getOriginKey

-- Graphics
local newImageTable <const> = Graphics.imagetable.new

-- Easing
local getEaseEnter  <const> = Ease.enter
local getEaseExit   <const> = Ease.exit

-- Stack operations
local STACK_OP_REPLACE  <const> = RoxyTransition.STACK_OP_REPLACE
local STACK_OP_PUSH     <const> = RoxyTransition.STACK_OP_PUSH
local STACK_OP_POP      <const> = RoxyTransition.STACK_OP_POP

-- Transition binding cache
local transitionBindingCache = {}

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
local FLIPPED_XY  <const> = Graphics.kImageFlippedXY
local FLIPPED_X   <const> = Graphics.kImageFlippedX
local FLIPPED_Y   <const> = Graphics.kImageFlippedY
local UNFLIPPED   <const> = Graphics.kImageUnflipped

-- Easing constants
local LINEAR_EASING <const> = Ease.linear

-- Defaults
local DURATION_DEFAULT  <const> = 1.5
local HOLD_TIME_DEFAULT <const> = 0

-- Utility constants
local SEQUENCE_POOL_KEY         <const> = "Transition_Sequence"
local IMAGETABLE_ENTER_POOL_KEY <const> = "Transition_ImageTable_Enter"
local IMAGETABLE_EXIT_POOL_KEY  <const> = "Transition_ImageTable_Exit"
local EMPTY_TABLE               <const> = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Initialize Asset Pool
-- Initialize asset pools (called once per module)
local function initializeAssetPool(userImageTableEnter, userImageTableExit)
  -- Enter image table
  ensurePool(
    IMAGETABLE_ENTER_POOL_KEY,
    1,
    function()
      return userImageTableEnter or newImageTable("libraries/roxy/assets/images/SLOTHUniversalLeaderEnter")
    end, {
      maxSize = 4,
      growthFactor = 1
    })

  -- Exit image table
  ensurePool(
    IMAGETABLE_EXIT_POOL_KEY,
    1,
    function()
      return userImageTableExit or newImageTable("libraries/roxy/assets/images/SLOTHUniversalLeaderExit")
    end, {
      maxSize = 4,
      growthFactor = 1
    })

  -- Sequence
  ensurePool(
    SEQUENCE_POOL_KEY,
    1,
    function() return RoxySequence() end, {
      maxSize = 4,
      growthFactor = 1
    })
end

-- ! Recycle To Origin Pool
-- Recycles a pooled asset back to its explicit owner key.
local function recycleToOriginPool(asset)
  if not asset then return end

  local originKey, isPooled = getOriginKey(asset)
  if not isPooled or originKey == nil then return end

  recycleAsset(originKey, asset)
end

--------------------------------------------------------------------------------
-- ! Class Definition & Initialization
--------------------------------------------------------------------------------

class("ImageTable").extends(RoxyTransition)

function ImageTable:init(opts)
  opts = opts or EMPTY_TABLE

  -- Get base configuration for this transition type
  local baseConfig = getTransitionConfig("ImageTable")

  -- Build final configuration with runtime options
  local builder = TableBuilder(baseConfig)
    :with(opts)

  local config = builder:build()

  -- Handle a single user image table
  if config.imageTable and not config.imageTableEnter and not config.imageTableExit then
    config.imageTableEnter = config.imageTable
    config.imageTableExit  = config.imageTable
    if config.reverseExit == nil then
      config.reverseExit = true -- Mirror exit for single table by default
    end
  end

  -- Initialize parent class
  ImageTable.super.init(self, {
    name = config.name or "ImageTable",
    type = "Cover",
    stackOp = config.stackOp or STACK_OP_REPLACE,
    captureScreenshot = config.captureScreenshot or false
  })

  -- ImageTable-specific properties
  local duration = config.duration or DURATION_DEFAULT
  self.duration = duration
  self.holdTime = config.holdTime or HOLD_TIME_DEFAULT

  -- Pre-calculate timing values for performance
  local halfHold = self.holdTime / 2
  self.enterTime = (duration / 2) - halfHold
  self.exitTime = (duration / 2) - halfHold

  -- Easing configuration
  local ease = config.ease or LINEAR_EASING
  self.ease = ease
  self.easeEnter = config.easeEnter or getEaseEnter(ease) or ease
  self.easeExit = config.easeExit or getEaseExit(ease) or ease

  -- Initialize asset pool on first use
  initializeAssetPool(config.imageTableEnter, config.imageTableExit)

  -- Image tables
  self:_acquireImageTableEnter(config.imageTableEnter)
  self:_acquireImageTableExit(config.imageTableExit)

  self.reverse = config.reverse and true or false -- Coerce to boolean

  if self.reverse then
    self.imageTableEnter, self.imageTableExit = self.imageTableExit, self.imageTableEnter
    self.reverseEnter, self.reverseExit = true, true
  else
    self.reverseEnter = config.reverseEnter and true or false
    self.reverseExit  = config.reverseExit  and true or false
  end

  -- Transformation options

  -- Reverse
  self.reverseEnter = config.reverseEnter or (self.reverse and true)
  self.reverseExit  = config.reverseExit  or (self.reverse and true)

  -- Flip
  -- Apply generic flipX/flipY to both phases if per-phase flags aren't set
  if config.flipX and config.flipXEnter == nil and config.flipXExit == nil then
    config.flipXEnter = true
    config.flipXExit  = true
  end
  if config.flipY and config.flipYEnter == nil and config.flipYExit == nil then
    config.flipYEnter = true
    config.flipYExit  = true
  end

  self.flipX        = config.flipX
  self.flipY        = config.flipY
  self.flipXEnter   = config.flipXEnter
  self.flipYEnter   = config.flipYEnter
  self.flipXExit    = config.flipXExit
  self.flipYExit    = config.flipYExit

  -- Rotate
  self.rotate       = config.rotate
  self.rotateEnter  = config.rotateEnter
  self.rotateExit   = config.rotateExit

  -- Precompute flip values
  self.flipValueEnter = self:_getFlipValue(self.rotateEnter, self.flipXEnter, self.flipYEnter)
  self.flipValueExit = self:_getFlipValue(self.rotateExit, self.flipXExit, self.flipYExit)

  -- Frame counts
  self.frameCountEnter = self.imageTableEnter and #self.imageTableEnter or 0
  self.frameCountExit  = self.imageTableExit  and #self.imageTableExit  or 0

  -- Sequence

  -- Enter start and end
  local enterStartValue = self.reverseEnter and 1 or 0
  local enterEndValue   = 1 - enterStartValue

  -- Exit start and end
  local exitStartValue  = self.reverseExit and 1 or 0
  local exitEndValue    = 1 - exitStartValue

  self.sequenceStartValue     = enterStartValue
  self.sequenceMidpointValue  = enterEndValue
  self.sequenceResumeValue    = exitStartValue
  self.sequenceCompleteValue  = exitEndValue

  -- Initialize sequence
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

-- ! Acquire Image Table Enter
-- Acquire the enter image table from the pool
function ImageTable:_acquireImageTableEnter(userImageTableEnter)
  if self.imageTableEnter then return end

  local imageTableEnter
  if userImageTableEnter then
    imageTableEnter = userImageTableEnter -- One-off or caller-managed
  else
    -- Pull from pool, or nil if empty
    imageTableEnter = getAsset(IMAGETABLE_ENTER_POOL_KEY)
  end

  if not imageTableEnter then
    -- Fallback
    imageTableEnter = userImageTableEnter or newImageTable("libraries/roxy/assets/images/SLOTHUniversalLeaderEnter")
  end

  self.imageTableEnter = imageTableEnter
end

-- ! Release Image Table Enter
-- Release the enter image table back to pool
function ImageTable:_releaseImageTableEnter()
  local imageTableEnter = self.imageTableEnter
  if not imageTableEnter then return end

  recycleToOriginPool(imageTableEnter)

  self.imageTableEnter = nil
end

-- ! Acquire Image Table Exit
-- Acquire the exit image table from the pool
function ImageTable:_acquireImageTableExit(userImageTableExit)
  if self.imageTableExit then return end

  local imageTableExit
  if userImageTableExit then
    imageTableExit = userImageTableExit -- One-off or caller-managed
  else
    -- Pull from pool, or nil if empty
    imageTableExit = getAsset(IMAGETABLE_EXIT_POOL_KEY)
  end

  if not imageTableExit then
    -- Fallback
    imageTableExit = userImageTableExit or newImageTable("libraries/roxy/assets/images/SLOTHUniversalLeaderExit")
  end

  self.imageTableExit = imageTableExit
end

-- ! Release Image Table Exit
-- Release the exit image table back to pool
function ImageTable:_releaseImageTableExit()
  local imageTableExit = self.imageTableExit
  if not imageTableExit then return end

  recycleToOriginPool(imageTableExit)

  self.imageTableExit = nil
end

-- ! Acquire Sequence
-- Acquire a sequence from the pool
function ImageTable:_acquireSequence()
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
function ImageTable:_releaseSequence()
  local sequence = self.sequence
  if not sequence then return end

  sequence:clear(true)

  recycleToOriginPool(sequence)

  self.sequence = nil
end

-- ! Get Flip Value
-- Calculates the flip value constant for rendering.
function ImageTable:_getFlipValue(rotate, flipX, flipY)
  if rotate or (flipX and flipY) then return FLIPPED_XY end
  if flipX then return FLIPPED_X end
  if flipY then return FLIPPED_Y end
  return UNFLIPPED
end

-- ! Set Up Sequence
-- Configure the animation sequence
function ImageTable:_setupSequence()
  local sequence = self.sequence
  if not sequence then return end

  -- Use pre-calculated timing values
  local enterTime = self.enterTime
  local exitTime = self.exitTime
  local holdTime = self.holdTime
  local easeEnter = self.easeEnter
  local easeExit = self.easeExit

  sequence
    :from(self.sequenceStartValue)
    :to(self.sequenceMidpointValue, enterTime, easeEnter)
    :callback(self._onMidpointFn)
    :sleep(holdTime)
    :callback(self._onHoldElapsedFn)
    :set(self.sequenceResumeValue)
    :to(self.sequenceCompleteValue, exitTime, easeExit)
    :callback(self._onCompleteFn)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Execute
-- Main execution method
function ImageTable:execute(newScene, currentScene)
  ImageTable.super.execute(self, newScene, currentScene)

  -- ImageTable-specific execution
  self._drawFrame = resolveTransitionBinding("imageTableDrawFrame")
  self:_setupSequence()
  self:_onStart()
  self.sequence:play()
end

-- ! Draw
-- Render the transition effect
function ImageTable:draw()
  local sequence = self.sequence
  if not sequence then return end

  local value = sequence:getValue()
  if not value then return end

  local drawFrame = self._drawFrame
  if not drawFrame then
    drawFrame = resolveTransitionBinding("imageTableDrawFrame")
    self._drawFrame = drawFrame
  end
  drawFrame(
    self.imageTableEnter, self.frameCountEnter, self.flipValueEnter,
    self.imageTableExit,  self.frameCountExit,  self.flipValueExit,
    value,
    self.state
  )
end

-- ! Cleanup
-- Clean up resources
function ImageTable:cleanup()
  -- Release ImageTable-specific resources
  self:_releaseImageTableEnter()
  self:_releaseImageTableExit()
  self:_releaseSequence()
  self._drawFrame = nil

  -- Call parent cleanup
  ImageTable.super.cleanup(self)

  Log.debug("Transition '" .. self.name .. "' cleanup completed") --#DEBUG
end

-- ! Warm Up Asset Pools
-- Public function to warm up asset pools
function ImageTable:warmUpAssetPool(userImageTableEnter, userImageTableExit)
  initializeAssetPool(userImageTableEnter, userImageTableExit)
end
