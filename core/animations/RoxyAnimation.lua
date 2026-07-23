-- core/animations/RoxyAnimation.lua

--------------------------------------------------------------------------------
-- RoxyAnimation - Spritesheet Playback and Shared Image Data
--------------------------------------------------------------------------------
--
-- Manages named frame ranges over a Playdate imagetable. Each instance owns
-- private playback state while factory helpers can share retained image data
-- to reduce memory pressure.
--
-- Key Features:
--  - Path, imagetable, and pool-backed construction
--  - Named clips with speed, loop, chaining, nextDelay, and callbacks
--  - frameRate config with frameDuration compatibility
--  - Optional display refresh-rate resolution for animation cadence
--  - Retain/release lifecycle for shared image data
--
-- Timing Contract:
--  - frameDuration is the runtime cadence in seconds per animation frame
--  - frameRate is converted to frameDuration when config or setter code runs
--  - frameDuration takes precedence when both frameDuration and frameRate are set
--
--------------------------------------------------------------------------------

local max   <const> = math.max
local min   <const> = math.min
local fmod  <const> = math.fmod

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics

local performAfterDelay <const> = pd.timer.performAfterDelay
local newImagetable <const> = Graphics.imagetable.new
local drawImage     <const> = Graphics.imagetable.drawImage

local r             <const> = roxy
local Math          <const> = r.Math
local Cache         <const> = r.Cache
local AssetStore    <const> = r.AssetStore
local Assets        <const> = r.Assets
local Registry      <const> = r.AssetPoolRegistry
local Animation     <const> = r.Animation
local RoxyGraphics  <const> = r.Graphics

local clamp           <const> = Math.clamp
local truncateDecimal <const> = Math.truncateDecimal
local getCachedAsset  <const> = Cache.getCachedAsset
local retainAsset     <const> = AssetStore.retain
local releaseAsset    <const> = AssetStore.release
local getAsset        <const> = Assets.getAsset
local recycleAsset    <const> = Assets.recycleAsset
local isFromPool      <const> = Registry.isFromPool
local updateAnimation <const> = Animation.update -- C Function
local getRefreshRate  <const> = RoxyGraphics.getRefreshRate

local UNFLIPPED <const> = Graphics.kImageUnflipped

local FRAME_RATE_DEFAULT            <const> = 30
local FRAME_DURATION_DEFAULT        <const> = 1 / FRAME_RATE_DEFAULT
local MIN_FRAME_DURATION            <const> = 0.016 -- Guard against >60 FPS
local MAX_FRAME_DURATION            <const> = 10    -- Sensible upper limit (sec)
local MAX_ANIMATION_SPEED           <const> = 100   -- UI clamp for setSpeed
local PATH_IMAGETABLE_CACHE_PREFIX  <const> = "RoxyAnimation.imagetable:"

--------------------------------------------------------------------------------
-- Private Helper Functions
--------------------------------------------------------------------------------

-- ! Helper: Probe Image Table Draw Image
-- Reads drawImage through pcall so hostile userdata/table access stays protected
local function _probeImageTableDrawImage(value)
  return value.drawImage
end

-- ! Helper: Probe Image Table Length
-- Reads table length through pcall so unsupported length operations stay protected
local function _probeImageTableLength(imagetable)
  return #imagetable
end

-- ! Helper: Construct From Image Table
-- Builds an animation through pcall while forwarding the imagetable explicitly
local function _constructFromImagetable(imagetable)
  return RoxyAnimation.fromImagetable(imagetable)
end

-- ! Helper: Is Image Table
-- Returns true for Playdate imagetable-like values
local function _isImageTable(value)
  local valueType = type(value)
  if valueType ~= "table" and valueType ~= "userdata" then return false end

  local ok, drawImage = pcall(_probeImageTableDrawImage, value)
  return ok and type(drawImage) == "function"
end

-- ! Helper: Get Image Table Length
-- Reads frame count from table length, then Playdate-style getLength()
local function _getImageTableLength(imagetable)
  local ok, length = pcall(_probeImageTableLength, imagetable)
  if ok and type(length) == "number" and length > 0 then
    return length
  end

  if imagetable and type(imagetable.getLength) == "function" then
    return imagetable:getLength() or 0
  end

  return 0
end

-- ! Helper: Get Path Cache Key
-- Namespaces path-backed imagetable assets inside AssetStore
local function _getPathCacheKey(path)
  return PATH_IMAGETABLE_CACHE_PREFIX .. path
end

-- ! Helper: Resolve Frame Rate
local function _resolveFrameRate(frameRate, fallbackDuration, label, warnOnInvalid)
  local frameRateType = type(frameRate)
  if frameRateType == "number" and frameRate > 0 then
    return 1 / frameRate
  end

  if frameRate == "display" then
    local displayRate = getRefreshRate(true)
    if type(displayRate) == "number" and displayRate > 0 then
      return 1 / displayRate
    end
    if warnOnInvalid then
      Log.warn("[" .. label .. "] frameRate=\"display\" could not resolve a positive display refresh rate, got " .. tostring(displayRate)) --#DEBUG
    end
    return fallbackDuration
  end

  if warnOnInvalid then
    Log.warn("[" .. label .. "] frameRate must be a positive number or \"display\", got " .. frameRateType) --#DEBUG
  end
  return fallbackDuration
end

-- ! Helper: Resolve Frame Duration Config
local function _resolveFrameDurationConfig(opts, fallbackDuration, label)
  if opts.frameDuration ~= nil then
    return opts.frameDuration
  end
  if opts.frameRate ~= nil then
    return _resolveFrameRate(opts.frameRate, fallbackDuration, label, true)
  end
  return fallbackDuration
end

-- ! Helper: Resolve Frame Rate Setter
local function _resolveFrameRateSetter(frameRate, label)
  local duration = _resolveFrameRate(frameRate, nil, label, true)
  return duration and clamp(duration, MIN_FRAME_DURATION, MAX_FRAME_DURATION) or nil
end

--------------------------------------------------------------------------------
-- Class Definition
--------------------------------------------------------------------------------

class("RoxyAnimation").extends(Object)

RoxyAnimation.PATH_IMAGETABLE_CACHE_PREFIX = PATH_IMAGETABLE_CACHE_PREFIX

--------------------------------------------------------------------------------
-- Static Factory Methods
--------------------------------------------------------------------------------

-- ! Get Path Cache Key
-- Returns the AssetStore key used for a path-backed animation imagetable
function RoxyAnimation.getPathCacheKey(path)
  return _getPathCacheKey(path)
end

-- ! From Path
-- Creates fresh playback state backed by a retained cached imagetable
function RoxyAnimation.fromPath(path)
  return RoxyAnimation(path)
end

-- ! From Image Table
-- Creates fresh playback state over an existing imagetable
function RoxyAnimation.fromImagetable(imagetable)
  if not _isImageTable(imagetable) then
    error("[RoxyAnimation.fromImagetable] Expected imagetable")
    return nil
  end

  return RoxyAnimation(imagetable)
end

-- ! From Pool
-- Creates fresh playback state over an imagetable checked out of an Assets pool
function RoxyAnimation.fromPool(poolKey)
  local imagetable = getAsset(poolKey)
  if not imagetable then
    error("[RoxyAnimation.fromPool] No asset for key: " .. tostring(poolKey))
    return nil
  end

  local ok, animation = pcall(_constructFromImagetable, imagetable)

  if not ok then
    -- Return checked-out image data before rethrowing construction errors
    if isFromPool(imagetable) then
      recycleAsset(poolKey, imagetable)
    end
    error(animation, 2)
  end

  animation._pooledKey = poolKey
  animation._pooledAsset = imagetable
  animation._pooledAssetKind = "imagetable"
  animation._pooledAssetRecycled = false
  return animation
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

-- ! Initialize
-- Initialize with path string or imagetable userdata
function RoxyAnimation:init(view)
  self.isRoxyAnimation = true

  local viewType = type(view)
  if viewType == "string" then
    return self:_initFromPath(view)
  elseif _isImageTable(view) then
    return self:_initFromImagetable(view)
  else
    error("[RoxyAnimation:init] Expected string path or imagetable (got " .. viewType .. ")")
  end
end

-- ! Initialize From Path
-- Initialize fresh animation state from a retained cached imagetable
function RoxyAnimation:_initFromPath(path)
  if type(path) ~= "string" or path == "" then
    error("[RoxyAnimation:_initFromPath] Expected non-empty path")
  end

  local cacheKey = _getPathCacheKey(path)
  -- Cache only image data; each animation keeps private playback state
  local retained = retainAsset(cacheKey, function()
    return newImagetable(path)
  end)
  if not retained then
    error("[RoxyAnimation:_initFromPath] Failed to retain imagetable from: " .. path)
    return
  end

  local imagetable = getCachedAsset(cacheKey)
  if not imagetable then
    releaseAsset(cacheKey)
    error("[RoxyAnimation:_initFromPath] Failed to get retained imagetable from: " .. path)
    return
  end
  if not _isImageTable(imagetable) then
    releaseAsset(cacheKey)
    error("[RoxyAnimation:_initFromPath] Retained asset is not an imagetable: " .. path)
    return
  end

  self:_initCommon()
  self.imagetable = imagetable
  self._length = _getImageTableLength(imagetable)
  self._path = path
  self._retainedPath = cacheKey
  self._retainedPathReleased = false
end

-- ! Initialize From Image Table
-- Initialize from existing imagetable
function RoxyAnimation:_initFromImagetable(imagetable)
  self:_initCommon()
  self.imagetable = imagetable
  self._length = _getImageTableLength(imagetable)
end

-- ! Initialize Common
-- Common initialization for all constructors
function RoxyAnimation:_initCommon()
  self.animations       = {}
  self.defaultName      = nil
  self.currentName      = nil
  self.currentAnimation = nil
  self.currentFrame     = 1
  self.isFirstCycle     = true
  self.isReversed       = false
  self.accumulator      = 0
  self._completeFired   = false
  self._pendingNext     = nil
  self._switchNextTick  = nil
  self._tailHoldSec     = 0
  self._refcount        = 1
  self._destroyed       = false
  self._path            = nil
  self._retainedPath    = nil
  self._retainedPathReleased = true
  self._pooledKey       = nil
  self._pooledAsset     = nil
  self._pooledAssetKind = nil
  self._pooledAssetRecycled = true
end

--------------------------------------------------------------------------------
-- Reference Counting
--------------------------------------------------------------------------------

-- ! Retain
-- Increment reference count and return self for chaining
function RoxyAnimation:retain()
  if self._destroyed then return self end
  self._refcount = (self._refcount or 0) + 1
  return self
end

-- ! Release
-- Decrement reference count, cleanup when reaches zero
function RoxyAnimation:release()
  if self._destroyed or not self._refcount then return end

  self._refcount -= 1
  if self._refcount <= 0 then
    self:destroy()
  end
end

-- ! Is Destroyed
-- Returns true after this animation has been destroyed
function RoxyAnimation:isDestroyed()
  return self._destroyed == true
end

-- ! Release Retained Path
-- Releases a retained path imagetable exactly once
function RoxyAnimation:_releaseRetainedPath()
  if self._retainedPath and not self._retainedPathReleased then
    releaseAsset(self._retainedPath)
    self._retainedPathReleased = true
  end
  self._retainedPath = nil
end

-- ! Recycle Pooled Asset
-- Returns a checked-out pooled imagetable exactly once
function RoxyAnimation:_recyclePooledAsset()
  local pooledAsset = self._pooledAsset
  if pooledAsset and self._pooledKey and not self._pooledAssetRecycled and isFromPool(pooledAsset) then
    recycleAsset(self._pooledKey, pooledAsset)
  end
  self._pooledAssetRecycled = true
  self._pooledAsset = nil
  self._pooledKey = nil
  self._pooledAssetKind = nil
end


--------------------------------------------------------------------------------
-- Animation Management
--------------------------------------------------------------------------------

-- ! Add Animation
-- Add named animation with frame range and playback options
function RoxyAnimation:addAnimation(opts)
  if not self:_validateAnimationOpts(opts) then
    return self
  end

  local animation = self:_buildAnimationConfig(opts)
  self.animations[animation.name] = animation

  -- Set as default if this is the first animation
  if not self.defaultName then
    self.defaultName = animation.name
  end

  -- Auto-start if no current animation
  if not self.currentName then
    self:setAnimation(animation.name)
  end

  return self
end

-- ! Validate Animation Options
-- Validate required parameters for addAnimation
function RoxyAnimation:_validateAnimationOpts(opts)
  if not opts or not opts.name or type(opts.name) ~= "string" then
    error("[RoxyAnimation:addAnimation] Animation name must be a non-empty string")
    return false
  end

  if self._length == 0 then
    error("[RoxyAnimation:addAnimation] Cannot add animation to empty imagetable")
    return false
  end

  return true
end

-- ! Build Animation Config
-- Build animation config with defaults and validation
function RoxyAnimation:_buildAnimationConfig(opts)
  local animation = {
    name                = opts.name,
    startFrame          = tonumber(opts.startFrame) or 1,
    endFrame            = tonumber(opts.endFrame) or self._length,
    loop                = (opts.loop ~= false), -- Default true
    next                = opts.next,
    onCompleteCallback  = opts.onCompleteCallback or opts.onComplete,
    speed               = opts.speed or 1,
    frameDuration       = _resolveFrameDurationConfig(opts, FRAME_DURATION_DEFAULT, "RoxyAnimation:addAnimation")
  }

  -- Ensure start <= end (swap if needed)
  if animation.startFrame > animation.endFrame then
    animation.startFrame, animation.endFrame = animation.endFrame, animation.startFrame
  end

  -- Clamp to valid ranges
  animation.startFrame    = clamp(animation.startFrame, 1, self._length)
  animation.endFrame      = clamp(animation.endFrame, 1, self._length)
  animation.speed         = clamp(animation.speed, 0, MAX_ANIMATION_SPEED)
  animation.frameDuration = clamp(animation.frameDuration, MIN_FRAME_DURATION, MAX_FRAME_DURATION)

  animation.exitTime = (opts.exitTime ~= nil) and max(0, min(1, opts.exitTime)) or 1.0
  animation.nextDelay = (type(opts.nextDelay) == "number" and opts.nextDelay > 0) and opts.nextDelay or 0

  -- Precompute frame counts for performance
  animation.range = animation.endFrame - animation.startFrame + 1
  animation.progressDenominator = max(1, animation.endFrame - animation.startFrame)

  return animation
end

-- ! Set Animation
-- Switch to named animation with optional frame continuity
function RoxyAnimation:setAnimation(name, nextContinuity, unlessThisAnimation)
  -- Skip if already playing the excluded animation
  if self:_shouldPreventAnimationChange(unlessThisAnimation) then
    return self
  end

  name = name or self.defaultName
  local animation = self.animations[name]
  if not animation then
    Log.warn("[RoxyAnimation:setAnimation] Animation '" .. tostring(name) .. "' not found") --#DEBUG
    return self
  end

  -- Calculate starting frame (with continuity if requested)
  self.currentFrame     = self:_getStartFrame(animation, nextContinuity)
  self.currentAnimation = animation
  self.currentName      = name

  -- Reset cycle state unless continuing from previous animation
  if not nextContinuity then
    self:resetAnimationStart()
  else
    self:_clearCompletionState()
  end

  return self
end

-- ! Stop
-- Stop current animation playback
function RoxyAnimation:stop()
  self.currentAnimation = nil
  self.currentName = nil
  self:_clearCompletionState()
  return self
end

-- ! Reverse
-- Toggle playback direction
function RoxyAnimation:reverse()
  self.isReversed = not self.isReversed
  return self
end

-- ! Reset Animation Start
-- Reset to beginning of current animation cycle
function RoxyAnimation:resetAnimationStart()
  self.isFirstCycle = true
  self.accumulator = 0
  if self.currentAnimation then
    self.currentFrame = self.currentAnimation.startFrame
  end
  self:_clearCompletionState()
  return self
end

-- ! Clear Completion State
-- Reset completion guards and any deferred completion transition
function RoxyAnimation:_clearCompletionState()
  self._completeFired = false
  self._pendingNext = nil
  self._switchNextTick = nil
  self._tailHoldSec = 0
end

--------------------------------------------------------------------------------
-- Playback Control
--------------------------------------------------------------------------------

-- ! Get Speed
-- Get current animation speed multiplier
function RoxyAnimation:getSpeed()
  return self.currentAnimation and self.currentAnimation.speed or nil
end

-- ! Set Speed
-- Set animation speed (affects all animations unless currentOnly=true)
function RoxyAnimation:setSpeed(speed, currentOnly)
  if not self:_validateSpeedInput(speed) then
    return self
  end

  speed = clamp(speed, 0, MAX_ANIMATION_SPEED)

  if currentOnly and self.currentAnimation then
    self.currentAnimation.speed = speed
  else
    -- Apply to all animations
    for _, animation in pairs(self.animations) do
      animation.speed = speed
    end
  end

  return self
end

-- ! Validate Speed Input
-- Validate speed parameter for setSpeed
function RoxyAnimation:_validateSpeedInput(speed)
  if type(speed) ~= "number" then
    Log.warn("[RoxyAnimation:setSpeed] Expected number, got " .. type(speed)) --#DEBUG
    return false
  end
  return true
end

-- ! Get Frame Duration
-- Get current frame duration in seconds
function RoxyAnimation:getFrameDuration()
  return self.currentAnimation and self.currentAnimation.frameDuration or nil
end

-- ! Get Frame Rate
-- Get current frame rate in frames per second
function RoxyAnimation:getFrameRate()
  local frameDuration = self:getFrameDuration()
  if not frameDuration or frameDuration <= 0 then return nil end
  return 1 / frameDuration
end

-- ! Set Frame Duration
-- Set frame duration (affects all animations unless currentOnly=true)
function RoxyAnimation:setFrameDuration(frameDuration, currentOnly)
  if not self:_validateFrameDurationInput(frameDuration) then
    return self
  end

  frameDuration = clamp(frameDuration, MIN_FRAME_DURATION, MAX_FRAME_DURATION)

  if currentOnly and self.currentAnimation then
    self.currentAnimation.frameDuration = frameDuration
  else
    -- Apply to all animations
    for _, animation in pairs(self.animations) do
      animation.frameDuration = frameDuration
    end
  end

  return self
end

-- ! Set Frame Rate
-- Set frame rate (affects all animations unless currentOnly=true)
function RoxyAnimation:setFrameRate(frameRate, currentOnly)
  local frameDuration = _resolveFrameRateSetter(frameRate, "RoxyAnimation:setFrameRate")
  if not frameDuration then return self end
  return self:setFrameDuration(frameDuration, currentOnly)
end

-- ! Validate Frame Duration Input
-- Validate frameDuration parameter for setFrameDuration
function RoxyAnimation:_validateFrameDurationInput(frameDuration)
  if type(frameDuration) ~= "number" then
    Log.warn("[RoxyAnimation:setFrameDuration] Expected number, got " .. type(frameDuration)) --#DEBUG
    return false
  end
  return true
end

-- ! Start With Delay
-- Start animation after specified delay
function RoxyAnimation:startWithDelay(delay, animationName)
  if not self:_validateDelayedStart(delay, animationName) then
    return self
  end

  performAfterDelay(delay, function()
    self:setAnimation(animationName)
  end)

  return self
end

-- ! Validate Delayed Start
-- Validate parameters for startWithDelay
function RoxyAnimation:_validateDelayedStart(delay, animationName)
  animationName = animationName or self.defaultName

  if type(delay) ~= "number" or delay <= 0 then
    Log.warn("[RoxyAnimation:startWithDelay] Invalid delay: " .. tostring(delay)) --#DEBUG
    return false
  end

  if not self.animations[animationName] then
    Log.warn("[RoxyAnimation:startWithDelay] Animation not found: " .. tostring(animationName)) --#DEBUG
    return false
  end

  return true
end

--------------------------------------------------------------------------------
-- Frame Control
--------------------------------------------------------------------------------

-- ! Jump To Frame
-- Jump to specific frame within current animation range
function RoxyAnimation:jumpToFrame(frame)
  local currentAnimation = self.currentAnimation
  if not currentAnimation then
    Log.warn("[RoxyAnimation:jumpToFrame] No current animation") --#DEBUG
    return self
  end

  -- Clamp to animation's frame range
  self.currentFrame = clamp(frame, currentAnimation.startFrame, currentAnimation.endFrame)
  return self
end

-- ! Jump To Specific Frame
-- Legacy alias for jumpToFrame
function RoxyAnimation:jumpToSpecificFrame(frame)
  return self:jumpToFrame(frame)
end

-- ! Step Frame
-- Step forward or backward by one frame with wrapping
function RoxyAnimation:stepFrame(direction)
  local currentAnimation = self.currentAnimation
  if not currentAnimation or currentAnimation.range <= 0 then
    return self
  end

  local step = (direction == -1 or direction == "back") and -1 or 1

  -- Calculate new frame with wrapping within animation range
  local offset = self.currentFrame + step - currentAnimation.startFrame
  local wrapped = fmod(offset, currentAnimation.range)
  if wrapped < 0 then
    wrapped = wrapped + currentAnimation.range
  end

  self.currentFrame = wrapped + currentAnimation.startFrame
  return self
end

-- ! Get Current Frame
-- Get current frame number
function RoxyAnimation:getCurrentFrame()
  return self.currentFrame
end

-- ! Get Current Animation
-- Get current animation name
function RoxyAnimation:getCurrentAnimation()
  return self.currentName
end

-- ! Is Playing
-- Check if animation is currently playing
function RoxyAnimation:isPlaying()
  return self.currentAnimation ~= nil
end

--------------------------------------------------------------------------------
-- Update and Draw
--------------------------------------------------------------------------------

-- ! Update
-- Update animation state (call each frame)
function RoxyAnimation:update(dt)
  local animation = self.currentAnimation
  if not animation or animation.speed == 0 then
    return
  end

  dt = dt or r.deltaTime or 0

  -- Handle tail-hold (explicit nextDelay > 0)
  if self:_handleTailHold(dt) then
    return
  end

  -- One-frame defer for next (ensures last frame rendered once)
  if self:_handleNextTickSwitch() then
    return
  end

  -- Advance animation normally
  self:_updateAnimationFrame(animation, dt)

  -- For non-loop clips, check exitTime & next/nextDelay behavior
  if not animation.loop then
    self:_handleNonLoopCompletion(animation)
  end
end

-- ! Handle Tail Hold
-- Handle explicit nextDelay > 0 behavior
function RoxyAnimation:_handleTailHold(dt)
  if not self._tailHoldSec or self._tailHoldSec <= 0 then
    return false
  end

  self._tailHoldSec = self._tailHoldSec - dt

  -- Pin on last frame while holding
  local animation = self.currentAnimation
  if animation then
    self.currentFrame = self.isReversed and animation.startFrame or animation.endFrame
  end

  if self._tailHoldSec <= 0 and self._pendingNext then
    local next = self._pendingNext
    self._pendingNext, self._tailHoldSec = nil, 0
    self:setAnimation(next, false)
  end

  return true
end

-- ! Handle Next Tick Switch
-- Handle one-frame defer for next animation
function RoxyAnimation:_handleNextTickSwitch()
  if not self._switchNextTick then return false end

  local next = self._pendingNext
  self._switchNextTick, self._pendingNext = nil, nil

  if next then
    self:setAnimation(next, false)
    return true
  end

  return false
end

-- ! Update Animation Frame
-- Core animation frame advancement logic
function RoxyAnimation:_updateAnimationFrame(animation, dt)
  local newFrame, newIsFirst, newAccumulator = updateAnimation(
    self.currentFrame,
    animation.startFrame,
    animation.endFrame,
    animation.loop and 1 or 0,
    self.isReversed and 1 or 0,
    self.isFirstCycle and 1 or 0,
    animation.speed,
    animation.frameDuration,
    dt,
    self.accumulator
  )

  self.currentFrame = newFrame
  self.isFirstCycle = (newIsFirst == 1)
  self.accumulator  = newAccumulator
end

-- ! Handle Non-Loop Completion
-- Handle completion behavior for non-looping animations
function RoxyAnimation:_handleNonLoopCompletion(animation)
  if self._completeFired then return end

  local exitTime  = animation.exitTime or 1
  local nextDelay = animation.nextDelay or 0

  -- Compute normalized progress 0..1
  local denominator = animation.progressDenominator or 1
  local progressed = self.isReversed
    and (animation.endFrame - self.currentFrame)
    or  (self.currentFrame - animation.startFrame)
  local progress = progressed / denominator

  if progress >= exitTime then
    self._completeFired = true

    -- Fire onComplete once we reach exitTime
    if type(animation.onCompleteCallback) == "function" then
      animation.onCompleteCallback()
    end

    if self.currentAnimation ~= animation then
      return
    end

    if animation.next then
      -- Pin on last frame while waiting or deferring the switch
      self.currentFrame = self.isReversed and animation.startFrame or animation.endFrame

      if nextDelay > 0 then
        -- Explicit tail hold
        self._pendingNext = animation.next
        self._tailHoldSec = nextDelay
        return
      else
        -- Switch on next tick so the final frame renders this frame
        self._pendingNext     = animation.next
        self._switchNextTick  = true
        return
      end
    end
    -- No explicit 'next': leave state as-is; higher layer (e.g. Actor) may handle settle/default
  end
end

-- ! Draw
-- Draw current frame at specified position
function RoxyAnimation:draw(x, y, flip)
  if not self.currentAnimation then
    return
  end

  drawImage(
    self.imagetable,
    self.currentFrame,
    x or 0,
    y or 0,
    flip or UNFLIPPED
  )
end

--------------------------------------------------------------------------------
-- Internal Helper Methods
--------------------------------------------------------------------------------

-- ! Should Prevent Animation Change
-- Check if animation change should be prevented
function RoxyAnimation:_shouldPreventAnimationChange(unlessThisAnimation)
  if not unlessThisAnimation then
    return false
  end

  return (type(unlessThisAnimation) == "string" and self.currentName == unlessThisAnimation) or
         (type(unlessThisAnimation) == "table" and self.currentAnimation == unlessThisAnimation)
end

-- ! Get Start Frame
-- Calculate starting frame for animation transition
function RoxyAnimation:_getStartFrame(newAnimation, nextContinuity)
  if not nextContinuity or not self.currentAnimation then
    return newAnimation.startFrame
  end

  local currentAnimation = self.currentAnimation
  local currentRange = currentAnimation.range or 1
  local newRange = newAnimation.range or 1

  -- Guard against division by zero
  if currentRange <= 0 or newRange <= 0 then
    return newAnimation.startFrame
  end

  -- Calculate progress through current animation
  local current = clamp(self.currentFrame, currentAnimation.startFrame, currentAnimation.endFrame)
  local progress = self.isReversed
    and (currentAnimation.endFrame - current) / currentRange
    or (current - currentAnimation.startFrame) / currentRange

  -- Handle NaN from calculation errors
  if progress ~= progress then
    progress = 0
  end

  -- Apply progress to new animation range
  local frame = newAnimation.startFrame + truncateDecimal(progress * newRange)
  return clamp(frame, newAnimation.startFrame, newAnimation.endFrame)
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- ! Destroy
-- Clean up resources and break references
function RoxyAnimation:destroy()
  if self._destroyed then return end

  self._destroyed = true
  self:_releaseRetainedPath()
  self:_recyclePooledAsset()

  -- Clear callback to prevent retention cycles
  if self.currentAnimation and self.currentAnimation.onCompleteCallback then
    self.currentAnimation.onCompleteCallback = nil
  end

  -- Clear all animation callbacks
  for _, animation in pairs(self.animations or {}) do
    if animation.onCompleteCallback then
      animation.onCompleteCallback = nil
    end
  end

  -- Clear all references
  self.currentAnimation = nil
  self.animations = {}
  self.imagetable = nil
  self._refcount = nil
  self._length = nil
  self._path = nil
  self._retainedPath = nil
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[
RoxyAnimation manages spritesheet playback state over retained or shared imagetables.

-- Path-backed animation with named clips
local playerAnimation = RoxyAnimation("images/player")
playerAnimation:addAnimation({
  name = "idle",
  startFrame = 1,
  endFrame = 4,
  loop = true,
  frameRate = 12,
})
:addAnimation({
  name = "run",
  startFrame = 5,
  endFrame = 12,
  frameRate = "display",
})
:addAnimation({
  name = "jump",
  startFrame = 13,
  endFrame = 20,
  loop = false,
  next = "idle",
  nextDelay = 0.1,
  frameRate = 12,
  frameDuration = 0.05, -- Takes precedence over frameRate
  onComplete = function()
    Log.debug("[PlayerAnimation] jump complete") --#DEBUG
  end,
})

playerAnimation:setAnimation("idle")
playerAnimation:setSpeed(1.25)
playerAnimation:setFrameRate(10, true)

-- Manual frame control
playerAnimation:setAnimation("run")
playerAnimation:jumpToFrame(8)
playerAnimation:stepFrame(1)
playerAnimation:stepFrame("back")
playerAnimation:reverse()

-- Delayed Start
playerAnimation:startWithDelay(1500, "jump")

-- Factory helpers share image data while returning fresh playback state
local sharedPathAnimation = RoxyAnimation.fromPath("images/player")
local existingImagetable = playdate.graphics.imagetable.new("images/player")
local tableAnimation = RoxyAnimation.fromImagetable(existingImagetable)

-- Update and draw from your sprite or scene loop
function MySprite:update()
  self.animation:update()
end

function MySprite:draw()
  self.animation:draw(self.x, self.y, self.flip)
end

-- Release retained image data when the owner is done
sharedPathAnimation:release()
tableAnimation:release()
playerAnimation:release()
--]]
