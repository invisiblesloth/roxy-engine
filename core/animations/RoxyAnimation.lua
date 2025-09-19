-- core/animations/RoxyAnimation.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics

local max   <const> = math.max
local min   <const> = math.min
local fmod  <const> = math.fmod

local newImagetable <const> = Graphics.imagetable.new
local drawImage     <const> = Graphics.imagetable.drawImage

local performAfterDelay <const> = pd.timer.performAfterDelay

local r         <const> = roxy
local Math      <const> = r.Math
local Assets    <const> = r.Assets
local Animation <const> = r.Animation

local clamp           <const> = Math.clamp
local truncateDecimal <const> = Math.truncateDecimal

local getAsset <const> = Assets.getAsset

local updateAnimation <const> = Animation.update -- C Function

local UNFLIPPED <const> = Graphics.kImageUnflipped

local FRAME_DURATION_DEFAULT  <const> = 0.033 -- About 30 FPS
local MIN_FRAME_DURATION      <const> = 0.016 -- Guard against >60 FPS
local MAX_FRAME_DURATION      <const> = 10    -- Sensible upper limit (sec)
local MAX_ANIMATION_SPEED     <const> = 100   -- UI clamp for setSpeed

-- Track shared animations by imagetable identity (weak keys)
local _animCache = setmetatable({}, { __mode = "k" })
-- Cache animations by path to avoid duplicate imagetables
local _pathCache = setmetatable({}, { __mode = "k" })

-- ----------------------------------------
-- Class Definition and Initialize
-- ----------------------------------------

class("RoxyAnimation").extends(Object)

-- ! Helper: From Image Table
-- Constructor for imagetable objects
function RoxyAnimation.fromImagetable(imagetable)
  if not (imagetable and imagetable.drawImage) then
    Log.error("[RoxyAnimation.fromImagetable] Expected imagetable userdata")
    return nil
  end

  local cached = _animCache[imagetable]
  if cached then
    return cached:retain()
  end

  local self = RoxyAnimation(imagetable) -- init handles imagetable or path
  self._refcount = 1
  _animCache[imagetable] = self
  return self
end

-- ! Helper: From Pool
-- Helper to fetch from Assets pool directly
function RoxyAnimation.fromPool(poolKey)
  local imagetable = getAsset(poolKey)
  if not imagetable then
    Log.error("[RoxyAnimation.fromPool] No asset for key: ", tostring(poolKey)) --#DEBUG
    return nil
  end
  return RoxyAnimation.fromImagetable(imagetable)
end

-- ! Initialize
-- Keep existing path constructor but delegate the config init to a helper
function RoxyAnimation:init(view)
  self.isRoxyAnimation = true

  local viewType = type(view)
  if viewType == "string" then
    -- Check path cache first to avoid duplicate imagetables
    local cached = _pathCache[view]
    if cached then
      return cached:retain()
    end

    local imagetable = Graphics.imagetable.new(view)
    --#DEBUG START
    Log.assert(imagetable, function()
      return string.format("[RoxyAnimation:init] Failed to create imagetable from: %s", tostring(view))
    end, 1)
    --#DEBUG END
    self:_initCommon()
    self.imagetable = imagetable
    self._length = #imagetable
    self._refcount  = 1
    self._path = view -- Store path for cleanup
    _pathCache[view] = self
    _animCache[imagetable] = self -- Add to both caches
    return
  end

  -- Support imagetables directly
  if viewType == "userdata" and view and view.drawImage then
    self:_initCommon()
    self.imagetable = view
    self._length = #view
    self._refcount = 1
    return
  end

  Log.error("[RoxyAnimation:init] Expected string path or imagetable userdata (got " .. viewType .. ")", 1) --#DEBUG
end

-- ! Common Initialize
-- Common initialization for both constructors
function RoxyAnimation:_initCommon()
  self.animations       = {}
  self.defaultName      = nil
  self.currentName      = nil
  self.currentAnimation = nil
  self.currentFrame     = 1
  self.isFirstCycle     = true
  self.isReversed       = false
  self.accumulator      = 0
  -- _length will be set after imagetable is assigned
end

-- ! Retain
-- Increment reference count
function RoxyAnimation:retain()
  self._refcount = (self._refcount or 0) + 1
  return self
end

-- ! Release
-- Reference release; recycles imagetable when count drops to zero
function RoxyAnimation:release()
  if not self._refcount then return end

  self._refcount = self._refcount - 1
  if self._refcount <= 0 then
    _animCache[self.imagetable] = nil
    -- Remove from path cache using stored path
    if self._path then
      _pathCache[self._path] = nil
    end
    -- Do not free imagetable here; Assets pool owns it.
    self:destroy()
  end
end

-- ----------------------------------------
-- Internal Methods
-- ----------------------------------------

-- ! Should Prevent Animation Change
function RoxyAnimation:shouldPreventAnimationChange(unlessThisAnimation)
  return unlessThisAnimation and (
    (type(unlessThisAnimation) == "string" and self.currentName == unlessThisAnimation) or
    (type(unlessThisAnimation) == "table"  and self.currentAnimation == unlessThisAnimation)
  )
end

-- ----------------------------------------
-- Public API
-- ----------------------------------------

-- ! Add Animation
function RoxyAnimation:addAnimation(opts)
  -- Validate animation name
  if not opts.name or type(opts.name) ~= "string" then
    Log.error("[RoxyAnimation:addAnimation] Animation name must be a non-empty string")
    return self
  end

  -- Check for empty imagetable
  if self._length == 0 then
    Log.error("[RoxyAnimation:addAnimation] Cannot add animation to empty imagetable")
    return self
  end

  -- Build animation directly to avoid unnecessary table creation
  local animation = {
    name               = opts.name,
    startFrame         = tonumber(opts.startFrame) or 1,
    endFrame           = tonumber(opts.endFrame) or self._length,
    loop               = (opts.loop ~= false),
    next               = opts.next,
    onCompleteCallback = opts.onCompleteCallback or opts.onComplete,
    speed              = opts.speed or 1,
    frameDuration      = opts.frameDuration or FRAME_DURATION_DEFAULT
  }

  -- Swap if out of order
  if animation.startFrame > animation.endFrame then
    animation.startFrame, animation.endFrame = animation.endFrame, animation.startFrame
  end

  -- Clamp into valid ranges
  animation.startFrame    = max(1, animation.startFrame)
  animation.endFrame      = min(self._length, animation.endFrame)
  animation.speed         = clamp(animation.speed, 0, MAX_ANIMATION_SPEED)
  animation.frameDuration = clamp(animation.frameDuration, MIN_FRAME_DURATION, MAX_FRAME_DURATION)

  -- Validate frame range after clamping
  if animation.endFrame < animation.startFrame then
    Log.warn("[RoxyAnimation:addAnimation] Invalid frame range after clamping: start=" .. animation.startFrame .. " end=" .. animation.endFrame)
    return self
  end

  -- Precompute range for performance
  animation.range = animation.endFrame - animation.startFrame + 1

  self.animations[animation.name] = animation

  if not self.defaultName then
    self.defaultName = animation.name
  end
  if not self.currentName then
    self:setAnimation(animation.name)
  end

  return self
end

-- ! Get Start Frame
function RoxyAnimation:getStartFrame(newAnimation, nextContinuity)
  local currentAnimation = self.currentAnimation
  if not currentAnimation then
    return newAnimation.startFrame
  end

  local range     = currentAnimation.range or (currentAnimation.endFrame - currentAnimation.startFrame + 1)
  local newRange  = newAnimation.range or (newAnimation.endFrame - newAnimation.startFrame + 1)
  local frame     = newAnimation.startFrame

  if nextContinuity then
    -- Handle edge cases for range calculations
    if range <= 0 or newRange <= 0 then
      return newAnimation.startFrame
    end

    -- Ensure current frame is within bounds for robust calculation
    local current = clamp(self.currentFrame, currentAnimation.startFrame, currentAnimation.endFrame)
    -- Adjust progress calculation for reversed animations
    local progress
    if self.isReversed then
      progress = (currentAnimation.endFrame - current) / range
    else
      progress = (current - currentAnimation.startFrame) / range
    end

    -- Handle NaN
    progress = (progress == progress) and progress or 0
    frame = newAnimation.startFrame + truncateDecimal(progress * newRange)
    frame = clamp(frame, newAnimation.startFrame, newAnimation.endFrame)
  end

  return frame
end

-- ! Set Animation
function RoxyAnimation:setAnimation(name, nextContinuity, unlessThisAnimation)
  if self:shouldPreventAnimationChange(unlessThisAnimation) then
    return self
  end

  name = name or self.defaultName
  local animation = self.animations[name]
  --#DEBUG START
  if not animation then
    Log.warn("[RoxyAnimation:setAnimation] Animation", tostring(name), "not found; retaining", self.currentName or "<none>")
    return self
  end
  --#DEBUG END

  self.currentFrame     = self:getStartFrame(animation, nextContinuity)
  self.currentAnimation = animation
  self.currentName      = name

  if not nextContinuity then
    self:resetAnimationStart()
  end

  return self
end

-- ! Animation Speed
function RoxyAnimation:getSpeed()
  if self.currentAnimation then
    return self.currentAnimation.speed
  end
  Log.warn("[RoxyAnimation:getSpeed] No current animation or speed not set") --#DEBUG
  return nil
end

-- ! Set Speed
function RoxyAnimation:setSpeed(speed, currentOnly)
  if type(speed) ~= "number" then
    Log.warn("[RoxyAnimation:setSpeed] Expected number for speed, got", type(speed)) --#DEBUG
    return self
  end
  speed = clamp(speed, 0, MAX_ANIMATION_SPEED)

  if not currentOnly then
    for _, animation in pairs(self.animations) do
      animation.speed = speed
    end
  elseif self.currentAnimation then
    self.currentAnimation.speed = speed
  end

  return self
end

-- ! Frame Duration
function RoxyAnimation:getFrameDuration()
  if self.currentAnimation then
    return self.currentAnimation.frameDuration
  end
  Log.warn("[RoxyAnimation:getFrameDuration] No current animation or frameDuration not set") --#DEBUG
  return nil
end

-- ! Set Frame Duration
function RoxyAnimation:setFrameDuration(frameDuration, currentOnly)
  if type(frameDuration) ~= "number" then
    Log.warn("[RoxyAnimation:setFrameDuration] Expected number for frameDuration, got", type(frameDuration)) --#DEBUG
    return self
  end

  frameDuration = clamp(frameDuration, MIN_FRAME_DURATION, MAX_FRAME_DURATION)

  if not currentOnly then
    for _, animation in pairs(self.animations) do
      animation.frameDuration = frameDuration
    end
  elseif self.currentAnimation then
    self.currentAnimation.frameDuration = frameDuration
  end

  return self
end

-- ! Start With Delay
function RoxyAnimation:startWithDelay(delay, animationName)
  -- Add type check for animationName and fallback to defaultName
  animationName = animationName or self.defaultName
  if type(delay) ~= "number" or delay <= 0 or not self.animations[animationName] then
    Log.warn("[RoxyAnimation:startWithDelay] Invalid delay or animation for startWithDelay:", delay, tostring(animationName)) --#DEBUG
    return self
  end

  performAfterDelay(delay, function()
    self:setAnimation(animationName)
  end)

  return self
end

-- ! Jump to Specific Frame
function RoxyAnimation:jumpToSpecificFrame(frame)
  local currentAnimation = self.currentAnimation
  if not currentAnimation then return self end

  self.currentFrame = max(currentAnimation.startFrame, min(frame, currentAnimation.endFrame))

  return self
end

-- ! Step Frame
-- Note: This steps absolute frame indices, not in playback direction
function RoxyAnimation:stepFrame(direction)
  local currentAnimation = self.currentAnimation
  if not currentAnimation then return self end

  local step = (direction == -1 or direction == "back") and -1 or 1
  local range = currentAnimation.range or (currentAnimation.endFrame - currentAnimation.startFrame + 1)

  -- Guard against zero-length animations
  if range <= 0 then return self end

  -- Compute offset relative to startFrame
  local offset = self.currentFrame + step - currentAnimation.startFrame
  -- Wrap using fmod, ensure positive
  local wrapped = fmod(offset, range)
  if wrapped < 0 then wrapped = wrapped + range end

  -- Translate back into absolute frame index
  self.currentFrame = wrapped + currentAnimation.startFrame

  return self
end

-- ! Stop
function RoxyAnimation:stop()
  self.currentAnimation = nil
  return self
end

-- ! Reverse
function RoxyAnimation:reverse()
  self.isReversed = not self.isReversed
  return self
end

-- ! Reset Animation Start
function RoxyAnimation:resetAnimationStart()
  self.isFirstCycle = true
  return self
end

-- ! Update
function RoxyAnimation:update()
  local currentAnimation = self.currentAnimation
  if not currentAnimation or currentAnimation.speed == 0 then return end

  local newFrame, newIsFirst, newAccumulator = updateAnimation(
    self.currentFrame,
    currentAnimation.startFrame, currentAnimation.endFrame,
    currentAnimation.loop and 1 or 0,
    self.isReversed and 1 or 0,
    self.isFirstCycle and 1 or 0,
    currentAnimation.speed,
    currentAnimation.frameDuration,
    r.deltaTime,
    self.accumulator
  )

  -- Clamp again after reversal to avoid off-by-one flash
  newFrame = clamp(newFrame, currentAnimation.startFrame, currentAnimation.endFrame)

  self.currentFrame = newFrame
  self.isFirstCycle = (newIsFirst == 1)
  self.accumulator  = newAccumulator

  if not currentAnimation.loop and
     ((not self.isReversed and newFrame >= currentAnimation.endFrame)  or
      (self.isReversed   and newFrame <= currentAnimation.startFrame)) then

    if currentAnimation.next then
      -- Call completion callback before transitioning if both exist
      if type(currentAnimation.onCompleteCallback) == "function" then
        currentAnimation.onCompleteCallback()
      end
      self:setAnimation(currentAnimation.next, true) -- Use continuity for smoother chaining
    elseif type(currentAnimation.onCompleteCallback) == "function" then
      currentAnimation.onCompleteCallback()
    end
  end
end

-- ! Draw
function RoxyAnimation:draw(x, y, flip)
  local currentAnimation = self.currentAnimation
  if not currentAnimation then return end
  drawImage(
    self.imagetable,
    self.currentFrame,
    x or 0,
    y or 0,
    flip or UNFLIPPED
  )
end

-- ! Destroy
function RoxyAnimation:destroy()
  if self.currentAnimation then
    self.currentAnimation.onCompleteCallback = nil
  end
  self.currentAnimation = nil
  self.animations = {}
  self.imagetable = nil
  self._refcount = nil
  self._length = nil
end
