-- core/sprites/RoxySprite.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite
local r         <const> = roxy
local Camera   <const> = r.Camera

local newImage      <const> = Graphics.image.new
local newImagetable <const> = Graphics.imagetable.new

local performAfterDelay <const> = pd.timer.performAfterDelay

local getPosition <const> = Camera.getPosition

local UNFLIPPED   <const> = Graphics.kImageUnflipped
local FLIPPED_X   <const> = Graphics.kImageFlippedX
local FLIPPED_Y   <const> = Graphics.kImageFlippedY
local FLIPPED_X_Y <const> = Graphics.kImageFlippedXY

local MS_PER_SECOND <const> = 1000

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

-- ----------------------------------------
-- Class Definition & Init
-- ----------------------------------------

class("RoxySprite").extends(Sprite)

function RoxySprite:init(opts)
  opts = opts or {}
  RoxySprite.super.init(self)

  self.name         = opts.name or "RoxySprite"
  self.isRoxySprite = true
  self._added       = false
  self.isPaused     = true
  self.flip         = UNFLIPPED
  self.animation    = nil
  self.simpleAnim   = nil
  self._drawFn      = nil

  if opts.view then
    self:setView(
      opts.view,
      opts.isSheet,
      opts.singleAnim,
      opts.singleAnimLoop ~= false,
      opts.frameDuration or 0.1
    )
  end
end

-- ----------------------------------------
-- Sprite Setup
-- ----------------------------------------

-- ! Set Z-Index
function RoxySprite:setZIndex(zIndex)
  RoxySprite.super.setZIndex(self, zIndex)
  return self
end

-- ! Set Size
function RoxySprite:setSize(width, height)
  RoxySprite.super.setSize(self, width, height)
  return self
end

-- ! Set Center
function RoxySprite:setCenter(x, y)
  RoxySprite.super.setCenter(self, x, y)
  return self
end

-- ! Move To
function RoxySprite:moveTo(x, y)
  RoxySprite.super.moveTo(self, x, y)
  return self
end

-- ----------------------------------------
-- View Management
-- ----------------------------------------

-- ! Set View
-- Sets the visual representation for the sprite (image or animation).
function RoxySprite:setView(view, viewIsSpritesheet, singleAnimation, singleAnimationLoop, frameDuration)
  if not view then
    self:setVisible(false)
    self._drawFn = nil
    return self
  end
  self:setVisible(true)

  -- Dispose previous visual
  if self.animation then
    self.animation:stop()
    self.animation = nil
  end
  self.simpleAnim = nil -- Clear any previous simpleAnim
  if self:getImage() then
    self:setImage(nil)
  end

  -- Pick and cache draw path
  if type(view) == "string" then
    if viewIsSpritesheet then
      if singleAnimation then
        -- Simple looping spritesheet
        local imagetable = newImagetable(view)
        if not imagetable then
          Log.error("[RoxySprite:setView] Failed to load imagetable for simpleAnim") --#DEBUG
          return self
        end
        self.simpleAnim = {
          imagetable    = imagetable,
          startFrame    = 1,
          endFrame      = imagetable:getLength(),
          currentFrame  = 1,
          frameDuration = frameDuration,
          accumulator   = 0,
          loop          = singleAnimationLoop,
        }
        -- Draw function for simpleanim
        self._drawFn = function(sprite, x, y, flip)
          local simpleAnim = sprite.simpleAnim
          if simpleAnim and simpleAnim.imagetable then
            simpleAnim.imagetable:drawImage(simpleAnim.currentFrame, x, y, flip)
          end
        end
      else
        -- Full RoxyAnimation
        self.animation = RoxyAnimation(view)
        if not (self.animation and self.animation.imagetable) then
          Log.error("[RoxySprite:setView] Failed to load spritesheet for RoxySprite") --#DEBUG
        end
        self._drawFn = function(sprite, x, y, flip)
          sprite.animation:draw(x, y, flip)
        end
      end
    else
      -- Static
      local image = newImage(view)
      self:setImage(image)
      self._drawFn = function(sprite, x, y, flip)
        local img = sprite:getImage()
        if img then img:draw(x, y, flip) end
      end
    end
  elseif type(view) == "table" and RoxyAnimation:isa(view) then
    self.animation = view
    self._drawFn = function(sprite, x, y, flip)
      sprite.animation:draw(x, y, flip)
    end
  elseif type(view) == "userdata" then
    self:setImage(view)
    self._drawFn = function(_, x, y, flip)
      view:draw(x, y, flip)
    end
  else
    Log.error("[RoxySprite:setView] Unsupported view type for RoxySprite:", type(view)) --#DEBUG
    self._drawFn = nil
  end

  return self
end

-- ----------------------------------------
-- Flip Flip
-- ----------------------------------------

-- ! Set Flip State
-- Updates flip state and marks dirty only when changed.
function RoxySprite:setFlipState(newFlip)
  if self.flip ~= newFlip then
    self.flip = newFlip
    self:markDirty()
  end
  return self
end
function RoxySprite:unflip()
  return self:setFlipState(UNFLIPPED)
end
function RoxySprite:flipX()
  return self:setFlipState(FLIPPED_X)
end
function RoxySprite:flipY()
  return self:setFlipState(FLIPPED_Y)
end
function RoxySprite:flipXY()
  return self:setFlipState(FLIPPED_X_Y)
end
function RoxySprite:getOrientation()
  return self.flip
end

-- ----------------------------------------
-- Animation Helpers
-- ----------------------------------------

--
-- ! Add Animation
-- Adds an animation definition to this sprite.
-- Table‑based addAnimation; delegates cleanly to RoxyAnimation
function RoxySprite:addAnimation(name, nextContinuity, unlessThisAnimation)
  if self.animation then
    self.animation:addAnimation(name, nextContinuity, unlessThisAnimation)
  end
  return self
end

--
-- ! Set Animation
-- Switches the currently playing animation.
--
function RoxySprite:setAnimation(name, nextContinuity, unlessThisAnimation)
  if self.animation then
    self.animation:setAnimation(name, nextContinuity, unlessThisAnimation)
  else --#DEBUG
    Log.warn("[RoxySprite:setAnimation] Sprite is not animated.") --#DEBUG
  end
  return self
end

-- ----------------------------------------
-- Playback
-- ----------------------------------------

-- ! Get isPaused
function RoxySprite:getIsPaused()
  return self.isPaused
end

-- ! Set isPaused
function RoxySprite:setIsPaused(flag)
  if type(flag) == "boolean" then
    self.isPaused = flag
  else --#DEBUG
    Log.warn("[RoxySprite:setIsPaused] Expected boolean for 'isPaused', got", type(flag)) --#DEBUG
  end
  return self
end

-- ! Play
function RoxySprite:play()
  if self.animation or self.simpleAnim then
    self.isPaused = false
  end
  return self
end

-- ! Play With Delay
function RoxySprite:playWithDelay(delay, animationName)
  if (self.animation or self.simpleAnim) and type(delay) == "number" and delay > 0 then
    performAfterDelay(delay * MS_PER_SECOND, function()
      if self.animation then
        self:setAnimation(animationName)
      end
      self:play()
    end)
  end
  return self
end

-- ! Pause
function RoxySprite:pause()
  if self.animation or self.simpleAnim then
    self.isPaused = true
  end
  return self
end

-- ! Toggle Play/Pause
function RoxySprite:togglePlayPause()
  if self.isPaused then return self:play() else return self:pause() end
end

-- ! Replay
function RoxySprite:replay()
  if self.animation then
    self.animation:resetAnimationStart()
  elseif self.simpleAnim then
    self.simpleAnim.currentFrame = self.simpleAnim.startFrame
    self.simpleAnim.accumulator  = 0
  end
  self.isPaused = false
  return self
end

-- ! Stop
-- Stops the sprite's animation and resets it to the first frame.
function RoxySprite:stop()
  if self.animation or self.simpleAnim then
    self.isPaused = true
    if self.animation then
      self.animation:resetAnimationStart()
    elseif self.simpleAnim then
      self.simpleAnim.currentFrame = self.simpleAnim.startFrame
      self.simpleAnim.accumulator  = 0
    end
    self:markDirty()
  end
  return self
end

-- ! Reverse
function RoxySprite:reverse()
  if self.animation then
    self.animation:reverse()
  else --#DEBUG
    Log.warn("[RoxySprite:reverse] Sprite has no animation (or simpleAnim) to reverse.") --#DEBUG
  end
  return self
end

-- ----------------------------------------
-- Speed and Frame Duration
-- ----------------------------------------

-- ! Get Speed
function RoxySprite:getSpeed()
  if self.animation then
    return self.animation:getSpeed()
  end
  Log.warn("[RoxySprite:getSpeed] Sprite has no animation (or simpleAnim) for speed.") --#DEBUG
  return nil
end

-- ! Set Speed
function RoxySprite:setSpeed(speed, currentOnly)
  if self.animation then
    if type(speed) == "number" then
      self.animation:setSpeed(speed, currentOnly)
    else --#DEBUG
      Log.warn("[RoxySprite:setSpeed] Expected number for 'speed', got", type(speed)) --#DEBUG
    end
  else --#DEBUG
    Log.warn("[RoxySprite:setSpeed] Sprite has no animation (or simpleAnim) to set speed.") --#DEBUG
  end
  return self
end

-- ! Get Frame Duration
function RoxySprite:getFrameDuration()
  if self.animation then
    return self.animation:getFrameDuration()
  end
  Log.warn("[RoxySprite:getFrameDuration] Sprite has no animation (or simpleAnim) for frame duration.") --#DEBUG
  return nil
end

-- ! Set Frame Duration
function RoxySprite:setFrameDuration(frameDuration, currentOnly)
  if self.animation then
    if type(frameDuration) == "number" then
      self.animation:setFrameDuration(frameDuration, currentOnly)
    else --#DEBUG
      Log.warn("[RoxySprite:setFrameDuration] Expected number for 'frameDuration', got", type(frameDuration)) --#DEBUG
    end
  else --#DEBUG
    Log.warn("[RoxySprite:setFrameDuration] Sprite has no animation (or simpleAnim) to set frame duration.") --#DEBUG
  end
  return self
end

-- ----------------------------------------
-- Frame Control
-- ----------------------------------------

-- ! Draw Specific Frame
function RoxySprite:drawSpecificFrame(frame, andPause)
  if self.animation then
    if andPause then self:pause() end
    self.animation:jumpToSpecificFrame(frame)
    if self.isPaused then self:markDirty() end
  else --#DEBUG
    Log.warn("[RoxySprite:drawSpecificFrame] Sprite has no animation (or simpleAnim) to draw specific frame.") --#DEBUG
  end
  return self
end

-- ! Step Frame
function RoxySprite:stepFrame(direction)
  if self.animation then
    self:pause()
    self.animation:stepFrame(direction)
    self:markDirty()
  else --#DEBUG
    Log.warn("[RoxySprite:stepFrame] Sprite has no animation (or simpleAnim) to step frame.") --#DEBUG
  end
  return self
end

-- ----------------------------------------
-- Rendering
-- ----------------------------------------

-- ! Update
function RoxySprite:update()
  if self.isPaused then return end

  -- Skip all animations if sprite is off-screen
  if not self:isOnScreen() then return end

  local dt = r.deltaTime or 0

  -- (Fast) Simple animation path
  local simpleAnimation = self.simpleAnim
  if simpleAnimation then
    local old = simpleAnimation.currentFrame
    simpleAnimation.accumulator = simpleAnimation.accumulator + dt
    if simpleAnimation.accumulator >= simpleAnimation.frameDuration then
      simpleAnimation.currentFrame = simpleAnimation.currentFrame + 1
      if simpleAnimation.currentFrame > simpleAnimation.endFrame then
        if simpleAnimation.loop then
          simpleAnimation.currentFrame = simpleAnimation.startFrame
        else
          simpleAnimation.currentFrame = simpleAnimation.endFrame
        end
      end
      simpleAnimation.accumulator = simpleAnimation.accumulator - simpleAnimation.frameDuration -- Preserve overflow for smooth timing
      if simpleAnimation.currentFrame ~= old then
        self:markDirty()
      end
    end
    return
  end

  -- (Normal) Full roxyanimation path
  local animation = self.animation
  if animation then
    local prev = animation.currentFrame
    animation:update()
    if animation.currentFrame ~= prev then
      self:markDirty()
    end
  end
end

-- ! Draw
function RoxySprite:draw()
  if self._drawFn then
    self._drawFn(self, 0, 0, self.flip)
  end
end

-- ----------------------------------------
-- Sprite Lifecycle
-- ----------------------------------------

-- ! Add Sprite
function RoxySprite:add()
  RoxySprite.super.add(self)
  self._added = true
  return self
end

-- ! Remove Sprite
function RoxySprite:remove()
  if self.isRoxySprite and (self.animation or self.simpleAnim) then
    self:stop()
  end
  self._added = false
  RoxySprite.super.remove(self)
  return self
end

-- ! Get isAdded
function RoxySprite:isAdded()
  return self._added == true
end

-- ! Is on Screen
function RoxySprite:isOnScreen()
  local spriteX, spriteY = self:getPosition()
  local spriteWidth, spriteHeight = self:getSize()
  local centerX, centerY = self:getCenter()
  local left = spriteX - spriteWidth * centerX
  local top = spriteY - spriteHeight * centerY
  local right = left + spriteWidth
  local bottom = top + spriteHeight

  -- Get camera position (top-left corner)
  local camX, camY = getPosition()
  local screenWidth, screenHeight = DISPLAY_WIDTH, DISPLAY_HEIGHT

  return not (
    right < camX or
    left > camX + screenWidth or
    bottom < camY or
    top > camY + screenHeight
  )
end

-- ! Destroy
function RoxySprite:destroy()
  self:remove()
  self.animation  = nil
  self.simpleAnim = nil
  self:setImage(nil)
end
