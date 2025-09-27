-- core/animations/RoxyAnimation.lua

--------------------------------------------------------------------------------
-- Standard Lua Function Aliases
--------------------------------------------------------------------------------

-- Math Functions
local max   <const> = math.max
local min   <const> = math.min
local fmod  <const> = math.fmod

--------------------------------------------------------------------------------
-- Playdate SDK Aliases
--------------------------------------------------------------------------------

-- Core Playdate
local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics

-- Timer Functions
local performAfterDelay <const> = pd.timer.performAfterDelay

-- Graphics Functions
local newImagetable <const> = Graphics.imagetable.new
local drawImage     <const> = Graphics.imagetable.drawImage

--------------------------------------------------------------------------------
-- Roxy Framework Aliases
--------------------------------------------------------------------------------

-- Roxy Core
local r         <const> = roxy
local Math      <const> = r.Math
local Assets    <const> = r.Assets
local Animation <const> = r.Animation

-- Roxy Framework Function Aliases
local clamp           <const> = Math.clamp
local truncateDecimal <const> = Math.truncateDecimal
local getAsset        <const> = Assets.getAsset
local updateAnimation <const> = Animation.update -- C Function

--------------------------------------------------------------------------------
-- Graphics Constants
--------------------------------------------------------------------------------

-- Image Flip States
local UNFLIPPED <const> = Graphics.kImageUnflipped

--------------------------------------------------------------------------------
-- Animation Constants
--------------------------------------------------------------------------------

local FRAME_DURATION_DEFAULT  <const> = 0.033 -- About 30 FPS
local MIN_FRAME_DURATION      <const> = 0.016 -- Guard against >60 FPS
local MAX_FRAME_DURATION      <const> = 10    -- Sensible upper limit (sec)
local MAX_ANIMATION_SPEED     <const> = 100   -- UI clamp for setSpeed

--------------------------------------------------------------------------------
-- Local State Variables
--------------------------------------------------------------------------------

-- Track shared animations by imagetable identity (weak keys)
local _animCache = setmetatable({}, { __mode = "k" })
-- Cache animations by path to avoid duplicate imagetables
local _pathCache = setmetatable({}, { __mode = "k" })

--------------------------------------------------------------------------------
-- Class Definition
--------------------------------------------------------------------------------

class("RoxyAnimation").extends(Object)

--------------------------------------------------------------------------------
-- Static Factory Methods
--------------------------------------------------------------------------------

-- ! From Image Table
-- Create animation from existing imagetable with reference counting
function RoxyAnimation.fromImagetable(imagetable)
  if not (imagetable and imagetable.drawImage) then
    Log.error("[RoxyAnimation.fromImagetable] Expected imagetable userdata")
    return nil
  end

  -- Return existing cached instance with incremented reference count
  local cached = _animCache[imagetable]
  if cached then
    return cached:retain()
  end

  -- Create new instance and add to cache
  local self = RoxyAnimation(imagetable)
  self._refcount = 1
  _animCache[imagetable] = self
  return self
end

-- ! From Pool
-- Create animation from Assets pool
function RoxyAnimation.fromPool(poolKey)
  local imagetable = getAsset(poolKey)
  if not imagetable then
    Log.error("[RoxyAnimation.fromPool] No asset for key: ", tostring(poolKey))
    return nil
  end
  return RoxyAnimation.fromImagetable(imagetable)
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
  elseif viewType == "userdata" and view and view.drawImage then
    return self:_initFromImagetable(view)
  else
    Log.error("[RoxyAnimation:init] Expected string path or imagetable userdata (got " .. viewType .. ")")
  end
end

-- ! Initialize From Path
-- Initialize from file path with caching
function RoxyAnimation:_initFromPath(path)
  -- Check path cache to avoid duplicate imagetables
  local cached = _pathCache[path]
  if cached then
    return cached:retain()
  end

  local imagetable = newImagetable(path)
  if not imagetable then
    Log.error("[RoxyAnimation:_initFromPath] Failed to create imagetable from: " .. path)
    return
  end

  self:_initCommon()
  self.imagetable = imagetable
  self._length = #imagetable
  self._refcount = 1
  self._path = path -- Store for cache cleanup

  -- Add to both caches
  _pathCache[path] = self
  _animCache[imagetable] = self
end

-- ! Initialize From Image Table
-- Initialize from existing imagetable
function RoxyAnimation:_initFromImagetable(imagetable)
  self:_initCommon()
  self.imagetable = imagetable
  self._length = #imagetable
  self._refcount = 1
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
end

--------------------------------------------------------------------------------
-- Reference Counting
--------------------------------------------------------------------------------

-- ! Retain
-- Increment reference count and return self for chaining
function RoxyAnimation:retain()
  self._refcount = (self._refcount or 0) + 1
  return self
end

-- ! Release
-- Decrement reference count, cleanup when reaches zero
function RoxyAnimation:release()
  if not self._refcount then return end

  self._refcount = self._refcount - 1
  if self._refcount <= 0 then
    -- Remove from caches
    _animCache[self.imagetable] = nil
    if self._path then
      _pathCache[self._path] = nil
    end
    self:destroy()
  end
end

--------------------------------------------------------------------------------
-- Animation Management
--------------------------------------------------------------------------------

-- ! Add Animation
-- Add named animation with frame range and playback options
function RoxyAnimation:addAnimation(opts)
  -- Validate required parameters
  if not opts or not opts.name or type(opts.name) ~= "string" then
    Log.error("[RoxyAnimation:addAnimation] Animation name must be a non-empty string")
    return self
  end

  if self._length == 0 then
    Log.error("[RoxyAnimation:addAnimation] Cannot add animation to empty imagetable")
    return self
  end

  -- Build animation config with defaults
  local animation = {
    name               = opts.name,
    startFrame         = tonumber(opts.startFrame) or 1,
    endFrame           = tonumber(opts.endFrame) or self._length,
    loop               = (opts.loop ~= false), -- Default true
    next               = opts.next,
    onCompleteCallback = opts.onCompleteCallback or opts.onComplete,
    speed              = opts.speed or 1,
    frameDuration      = opts.frameDuration or FRAME_DURATION_DEFAULT
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

  animation.exitTime  = (opts.exitTime ~= nil) and max(0, min(1, opts.exitTime)) or 1.0
  animation.nextDelay = (type(opts.nextDelay) == "number" and opts.nextDelay > 0) and opts.nextDelay or 0

  -- Precompute frame count for performance
  animation.range = animation.endFrame - animation.startFrame + 1

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
    Log.warn("[RoxyAnimation:setAnimation] Animation '" .. tostring(name) .. "' not found")
    return self
  end

  -- Calculate starting frame (with continuity if requested)
  self.currentFrame     = self:_getStartFrame(animation, nextContinuity)
  self.currentAnimation = animation
  self.currentName      = name

  -- Reset cycle state unless continuing from previous animation
  if not nextContinuity then
    self:resetAnimationStart()
  end

  return self
end

-- ! Stop
-- Stop current animation playback
function RoxyAnimation:stop()
  self.currentAnimation = nil
  self.currentName = nil
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
  return self
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
  if type(speed) ~= "number" then
    Log.warn("[RoxyAnimation:setSpeed] Expected number, got " .. type(speed))
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

-- ! Get Frame Duration
-- Get current frame duration in seconds
function RoxyAnimation:getFrameDuration()
  return self.currentAnimation and self.currentAnimation.frameDuration or nil
end

-- Set frame duration (affects all animations unless currentOnly=true)
function RoxyAnimation:setFrameDuration(frameDuration, currentOnly)
  if type(frameDuration) ~= "number" then
    Log.warn("[RoxyAnimation:setFrameDuration] Expected number, got " .. type(frameDuration))
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

-- ! Start With Delay
-- Start animation after specified delay
function RoxyAnimation:startWithDelay(delay, animationName)
  animationName = animationName or self.defaultName

  if type(delay) ~= "number" or delay <= 0 then
    Log.warn("[RoxyAnimation:startWithDelay] Invalid delay: " .. tostring(delay))
    return self
  end

  if not self.animations[animationName] then
    Log.warn("[RoxyAnimation:startWithDelay] Animation not found: " .. tostring(animationName))
    return self
  end

  performAfterDelay(delay, function()
    self:setAnimation(animationName)
  end)

  return self
end

--------------------------------------------------------------------------------
-- Frame Control
--------------------------------------------------------------------------------

-- ! Jump To Frame
-- Jump to specific frame within current animation range
function RoxyAnimation:jumpToFrame(frame)
  local currentAnimation = self.currentAnimation
  if not currentAnimation then
    Log.warn("[RoxyAnimation:jumpToFrame] No current animation")
    return self
  end

  -- Clamp to animation's frame range
  self.currentFrame = clamp(frame, currentAnimation.startFrame, currentAnimation.endFrame)
  return self
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
  if self._tailHoldSec and self._tailHoldSec > 0 then
    self._tailHoldSec = self._tailHoldSec - dt
    -- Pin on last frame while holding
    if animation then
      self.currentFrame = self.isReversed and animation.startFrame or animation.endFrame
    end
    if self._tailHoldSec <= 0 and self._pendingNext then
      local next = self._pendingNext
      self._pendingNext, self._tailHoldSec = nil, 0
      self:setAnimation(next, false)
    end
    return
  end

  -- One-frame defer for next (ensures last frame rendered once)
  if self._switchNextTick then
    local next = self._pendingNext
    self._switchNextTick, self._pendingNext = nil, nil
    if next then self:setAnimation(next, false) end
    -- Fall through to normal update after switching
    animation = self.currentAnimation
    if not animation then return end
  end

  -- Advance animation normally
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

  -- For non-loop clips, check exitTime & next/nextDelay behavior
  if not animation.loop then
    -- Defaults: exitTime=1 (play entire clip), nextDelay=0 (no hold)
    local exitTime  = (animation.exitTime ~= nil) and animation.exitTime or 1
    local nextDelay = animation.nextDelay or 0

    -- Compute normalized progress 0..1
    local range = animation.endFrame - animation.startFrame
    local denominator = (range ~= 0) and range or 1
    local progressed = self.isReversed
      and (animation.endFrame - newFrame)
      or  (newFrame - animation.startFrame)
    local progress = progressed / denominator

    if progress >= exitTime then
      -- Fire onComplete once we reach exitTime
      if type(animation.onCompleteCallback) == "function" then
        animation.onCompleteCallback()
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
          self._pendingNext   = animation.next
          self._switchNextTick = true
          return
        end
      end
      -- No explicit 'next': leave state as-is; higher layer (e.g. Actor) may handle settle/default
    end
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

-- ! Handle Animation Complete
-- Handle animation completion callbacks and chaining
function RoxyAnimation:_handleAnimationComplete(animation)
  -- Execute completion callback if provided
  if type(animation.onCompleteCallback) == "function" then
    animation.onCompleteCallback()
  end

  -- Chain to next animation if specified
  if animation.next then
    self:setAnimation(animation.next, false) -- No frame continuity
  end
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- ! Destroy
-- Clean up resources and break references
function RoxyAnimation:destroy()
  -- Clear callback to prevent retention cycles
  if self.currentAnimation and self.currentAnimation.onCompleteCallback then
    self.currentAnimation.onCompleteCallback = nil
  end

  -- Clear all references
  self.currentAnimation = nil
  self.animations = {}
  self.imagetable = nil
  self._refcount = nil
  self._length = nil
  self._path = nil
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

-- Basic Usage
local anim = RoxyAnimation("path/to/spritesheet")
anim:addAnimation({
  name = "idle",
  startFrame = 1,
  endFrame = 4,
  loop = true,
  speed = 1
})

-- Multiple Animations with Chaining
anim:addAnimation({
  name = "walk",
  startFrame = 5,
  endFrame = 12,
  loop = true
})
:addAnimation({
  name = "jump",
  startFrame = 13,
  endFrame = 20,
  loop = false,
  next = "idle", -- Auto-transition back to idle
  onComplete = function()
    print("Jump completed!")
  end
})

-- Frame Control
anim:setAnimation("walk")
anim:jumpToFrame(8)
anim:stepFrame(1) -- Step forward
anim:stepFrame("back") -- Step backward

-- Playback Control
anim:setSpeed(2) -- Double speed for all animations
anim:setSpeed(0.5, true) -- Half speed for current animation only
anim:reverse() -- Play backwards
anim:stop() -- Stop playback

-- Delayed Start
anim:startWithDelay(1.5, "jump") -- Start jump animation after 1.5 seconds

-- Animation Queries
if anim:isPlaying() then
  print("Current animation:", anim:getCurrentAnimation())
  print("Current frame:", anim:getCurrentFrame())
end

-- Factory Methods for Asset Management
local poolAnim = RoxyAnimation.fromPool("character_animations")
local sharedAnim = RoxyAnimation.fromImagetable(existingImagetable)

-- Reference Counting (for shared resources)
local anim2 = anim:retain() -- Increment reference count
anim:release() -- Decrement reference count
anim2:release() -- Final release cleans up resources

-- In your update loop
function MySprite:update()
  self.animation:update()
end

-- In your draw method
function MySprite:draw()
  self.animation:draw(self.x, self.y, self.flip)
end

--]]
