-- core/animations/RoxyAnimation.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics

local r         <const> = roxy

local max             <const> = math.max
local min             <const> = math.min
local fmod            <const> = math.fmod
local clamp           <const> = r.Math.clamp
local truncateDecimal <const> = r.Math.truncateDecimal

local newImagetable <const> = Graphics.imagetable.new
local drawImage     <const> = Graphics.imagetable.drawImage

local performAfterDelay <const> = pd.timer.performAfterDelay

local updateAnimation <const> = r.Animation.update -- C Function

local UNFLIPPED <const> = Graphics.kImageUnflipped

local FRAME_DURATION_DEFAULT  <const> = 0.033 -- ≈30 FPS
local MIN_FRAME_DURATION      <const> = 0.016 -- Guard against >60 FPS
local MAX_FRAME_DURATION      <const> = 10    -- Sensible upper limit (sec)
local MAX_ANIMATION_SPEED     <const> = 100   -- UI clamp for setSpeed

-- ----------------------------------------
-- Class Definition & Init
-- ----------------------------------------

class("RoxyAnimation").extends(Object)

function RoxyAnimation:init(view)
  self.isRoxyAnimation = true

  --#DEBUG START
  if type(view) ~= "string" then
    Log.error("[RoxyAnimation:init] Invalid view type for RoxyAnimation:", type(view), 2)
  end
  --#DEBUG END

  self.imagetable = newImagetable(view)
  --#DEBUG START
  if not self.imagetable then
    Log.error("[RoxyAnimation:init] Failed to create imagetable from view:", view)
  end
  --#DEBUG END

  self.animations       = {}
  self.defaultName      = nil
  self.currentName      = nil
  self.currentAnimation = nil
  self.currentFrame     = 1
  self.isFirstCycle     = true
  self.isReversed       = false
  self.accumulator      = 0
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
  local def = {}
  def.name                = opts.name
  def.startFrame          = opts.startFrame or 1
  def.endFrame            = opts.endFrame or #self.imagetable
  def.loop                = (opts.loop ~= false)
  def.next                = opts.next
  def.onCompleteCallback  = opts.onCompleteCallback or opts.onComplete
  def.speed               = opts.speed or 1
  def.frameDuration       = opts.frameDuration or FRAME_DURATION_DEFAULT

  -- Ensure numeric defaults
  def.startFrame  = tonumber(def.startFrame) or 1
  def.endFrame    = tonumber(def.endFrame) or #self.imagetable

  -- Swap if out of order
  if def.startFrame > def.endFrame then
    def.startFrame, def.endFrame = def.endFrame, def.startFrame
  end

  -- Clamp into valid ranges
  def.startFrame    = max(1, def.startFrame)
  def.endFrame      = min(#self.imagetable, def.endFrame)
  def.loop          = def.loop ~= false
  def.speed         = clamp(def.speed, 0, MAX_ANIMATION_SPEED)
  def.frameDuration = clamp(def.frameDuration, MIN_FRAME_DURATION, MAX_FRAME_DURATION)

  -- Build the actual animation entry
  local animation = {
    name                = def.name,
    startFrame          = def.startFrame,
    endFrame            = def.endFrame,
    loop                = def.loop,
    next                = def.next,
    onCompleteCallback  = def.onCompleteCallback,
    speed               = def.speed,
    frameDuration       = def.frameDuration,
  }

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

  local range     = currentAnimation.endFrame - currentAnimation.startFrame + 1
  local newRange  = newAnimation.endFrame - newAnimation.startFrame + 1
  local frame     = newAnimation.startFrame

  if nextContinuity then
    local progress = (self.currentFrame - currentAnimation.startFrame) / range
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
function RoxyAnimation:stepFrame(direction)
  local currentAnimation = self.currentAnimation
  if not currentAnimation then return self end

  local step = (direction == -1 or direction == "back") and -1 or 1
  local startFrame = currentAnimation.startFrame
  local endFrame = currentAnimation.endFrame
  -- Guard against zero-length animations
  -- (Shouldn’t happen under normal addAnimation, but protects against division by zero)
  local range = endFrame - startFrame + 1
  if range <= 0 then return self end

  -- Compute offset relative to startFrame
  local offset = self.currentFrame + step - startFrame
  -- Wrap using fmod, ensure positive
  local wrapped = fmod(offset, range)
  if wrapped < 0 then wrapped = wrapped + range end

  -- Translate back into absolute frame index
  self.currentFrame = wrapped + startFrame

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
      self:setAnimation(currentAnimation.next)
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
end
