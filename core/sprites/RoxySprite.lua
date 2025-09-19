-- libraries/roxy/core/sprites/RoxySprite.lua

--------------------------------------------------------------------------------
-- Playdate SDK Imports
--------------------------------------------------------------------------------

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

-- Playdate SDK Function Aliases
local performAfterDelay   <const> = pd.timer.performAfterDelay
local newImage            <const> = Graphics.image.new
local newImagetable       <const> = Graphics.imagetable.new

--------------------------------------------------------------------------------
-- Roxy Framework Imports
--------------------------------------------------------------------------------

local r       <const> = roxy
local Assets  <const> = r.Assets
local Camera  <const> = r.Camera

-- Roxy Utilities
local round <const> = r.Math.round

-- Roxy Framework Function Aliases
local getAsset      <const> = Assets.getAsset
local getPosition   <const> = Camera.getPosition
local worldToScreen <const> = Camera.worldToScreen

--------------------------------------------------------------------------------
-- Graphics Constants
--------------------------------------------------------------------------------

local UNFLIPPED   <const> = Graphics.kImageUnflipped
local FLIPPED_X   <const> = Graphics.kImageFlippedX
local FLIPPED_Y   <const> = Graphics.kImageFlippedY
local FLIPPED_X_Y <const> = Graphics.kImageFlippedXY

--------------------------------------------------------------------------------
-- Time Constants
--------------------------------------------------------------------------------

local MS_PER_SECOND <const> = 1000

--------------------------------------------------------------------------------
-- Display Constants
--------------------------------------------------------------------------------

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

--------------------------------------------------------------------------------
-- Class Definition & Init
--------------------------------------------------------------------------------

class("RoxySprite").extends(Sprite)

-- ! Initialize
function RoxySprite:init(opts, scene)
  opts = opts or {}
  RoxySprite.super.init(self)

  self.name               = opts.name or "RoxySprite"
  self.isRoxySprite       = true
  self._added             = false
  self.isPaused           = true
  self.flip               = UNFLIPPED
  self.animation          = nil
  self.simpleAnim         = nil
  self._drawFn            = nil
  self._ignoresDrawOffset = false

  -- Parallax (optional; only active if configured)
  self.worldX, self.worldY           = nil, nil
  self.parallaxX, self.parallaxY     = nil, nil
  self.parallaxOriginX, self.parallaxOriginY = nil, nil

  -- Initialize from opts if provided
  if opts.worldX or opts.worldY or opts.parallaxX or opts.parallaxY
     or opts.parallaxOriginX or opts.parallaxOriginY then
    self.worldX         = opts.worldX or (self.x or 0)
    self.worldY         = opts.worldY or (self.y or 0)
    self.parallaxX      = opts.parallaxX or 1
    self.parallaxY      = opts.parallaxY or 1
    self.parallaxOriginX= opts.parallaxOriginX or 0
    self.parallaxOriginY= opts.parallaxOriginY or 0
    self:setIgnoresDrawOffset(true)
    self:setUpdatesEnabled(true)
  end

  if opts.view then
    self:setView(
      opts.view,
      opts.isSheet,
      opts.singleAnim,
      opts.singleAnimLoop ~= false,
      opts.frameDuration or 0.1
    )
  end

  -- Attach to a scene immediately (optional)
  if scene and scene.addSprite then
    scene:addSprite(self)
  end
end

--------------------------------------------------------------------------------
-- Sprite Setup
--------------------------------------------------------------------------------

-- ! Set Ignores Draw Offset
function RoxySprite:setIgnoresDrawOffset(flag)
  self._ignoresDrawOffset = flag
  RoxySprite.super.setIgnoresDrawOffset(self, flag)
  return self
end

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

--------------------------------------------------------------------------------
-- Parallax API (optional)
--------------------------------------------------------------------------------

-- ! Enable/adjust world position used for parallax placement
function RoxySprite:setWorldPosition(x, y)
  self.worldX = (x ~= nil) and x or self.worldX or self.x or 0
  self.worldY = (y ~= nil) and y or self.worldY or self.y or 0
  return self
end

-- ! Set Parallax factors (1 = camera-locked like world space)
function RoxySprite:setParallax(px, py)
  self.parallaxX = (px ~= nil) and px or self.parallaxX or 1
  self.parallaxY = (py ~= nil) and py or self.parallaxY or 1
  -- Parallax uses screen-space placement
  self:setIgnoresDrawOffset(true)
  self:setUpdatesEnabled(true)
  return self
end

-- ! Set Parallax origin (anchor in screen/world terms)
function RoxySprite:setParallaxOrigin(ox, oy)
  self.parallaxOriginX = (ox ~= nil) and ox or self.parallaxOriginX or 0
  self.parallaxOriginY = (oy ~= nil) and oy or self.parallaxOriginY or 0
  return self
end

-- ! Parallax enabled?
function RoxySprite:isParallaxEnabled()
  return self.parallaxX ~= nil or self.parallaxY ~= nil
end

--------------------------------------------------------------------------------
-- View Management
--------------------------------------------------------------------------------

-- ! Clear View Helper
function RoxySprite:clearView()
  -- Dispose previous visual
  if self.animation then
    self.animation:stop()
    if self.animation.release then self.animation:release() end -- Balance any retain
    self.animation = nil
  end
  self.simpleAnim = nil -- Clear any previous simpleAnim
  if self:getImage() then
    self:setImage(nil)
  end
  self._drawFn = nil
  -- Set fallback size when clearing view
  self:setSize(0, 0)
end

-- ! Set View
-- Sets the visual representation for the sprite (image or animation).
function RoxySprite:setView(view, viewIsSpritesheet, singleAnimation, singleAnimationLoop, frameDuration)
  if not view then
    self:setVisible(false)
    self:clearView()
    return self
  end
  self:setVisible(true)

  -- Clear previous state
  self:clearView()

  -- Small helper: size this sprite from the first frame of an imagetable
  local function _applySizeFromImagetable(imagetable)
    if imagetable and imagetable.getImage then
      local first = imagetable:getImage(1)
      if first and first.getSize then
        local width, height = first:getSize()
        if width and height then
          self:setSize(width, height)
          self:setCenter(0.5, 0.5)
        end
      end
    end
  end

  -- Handle descriptor table form
  if type(view) == "table" and view.poolKey then
    local kind = view.kind or "sheet"
    if kind == "sheet" then
      -- Load imagetable from pool; wrap as RoxyAnimation
      local imagetable = getAsset(view.poolKey)
      if not imagetable then
        error(("[RoxySprite:setView] Pool key not found: %s"):format(tostring(view.poolKey)), 2)
      end
      self.animation = RoxyAnimation.fromImagetable(imagetable) -- Refcount owned by this sprite
      _applySizeFromImagetable(self.animation.imagetable)
      self._drawFn = function(sprite, x, y, flip) sprite.animation:draw(x, y, flip) end

    elseif kind == "animation" then
      -- Pooled/shared animation object in Assets pool
      local animation = getAsset(view.poolKey)
      if type(animation) == "table" and animation.isRoxyAnimation then
        if animation.retain then animation:retain() end -- Retain while this sprite uses it
        self.animation = animation
        _applySizeFromImagetable(self.animation.imagetable)
        self._drawFn = function(sprite, x, y, flip) sprite.animation:draw(x, y, flip) end
      else
        error(("[RoxySprite:setView] Pool key does not resolve to RoxyAnimation: %s"):format(tostring(view.poolKey)), 2)
      end

    elseif kind == "image" then
      local img = getAsset(view.poolKey)
      if img and img.draw then
        self:setImage(img) -- Sets sprite size from image
        self._drawFn = function(_, x, y, flip) img:draw(x, y, flip) end
      else
        error(("[RoxySprite:setView] Pool key does not resolve to Image: %s"):format(tostring(view.poolKey)), 2)
      end
    end
    return self
  end

  -- Handle direct pooled objects (existing extension)
  if type(view) == "table" and view.imagetable then
    -- Direct imagetable object from pool
    self.animation = RoxyAnimation.fromImagetable(view.imagetable) -- refcount owned by this sprite
    _applySizeFromImagetable(self.animation.imagetable)
    self._drawFn = function(sprite, x, y, flip) sprite.animation:draw(x, y, flip) end
    return self
  end

  if type(view) == "table" and view.animation and (type(view.animation) == "table" and view.animation.isRoxyAnimation) then
    -- Direct pooled animation object
    if view.animation.retain then view.animation:retain() end -- retain while this sprite uses it
    self.animation = view.animation
    _applySizeFromImagetable(self.animation.imagetable)
    self._drawFn = function(sprite, x, y, flip) sprite.animation:draw(x, y, flip) end
    return self
  end

  -- Pick and cache draw path
  if type(view) == "string" then
    if viewIsSpritesheet then
      if singleAnimation then
        -- Simple looping spritesheet
        local imagetable = newImagetable(view)
        if not imagetable then
          error("[RoxySprite:setView] Failed to load imagetable for simpleAnim", 2)
        end
        --#DEBUG START
        -- Assert positive frame duration to prevent infinite update loops
        assert((frameDuration or 0.1) > 0, "[RoxySprite:setView] frameDuration must be > 0 for simpleAnim")
        --#DEBUG END
        self.simpleAnim = {
          imagetable    = imagetable,
          startFrame    = 1,
          endFrame      = imagetable:getLength(),
          currentFrame  = 1,
          frameDuration = frameDuration or 0.1,
          accumulator   = 0,
          loop          = (singleAnimationLoop ~= false),
        }
        -- Ensure the sprite has bounds for culling/dirty-rects
        _applySizeFromImagetable(imagetable)
        -- Draw function for simpleanim
        self._drawFn = function(sprite, x, y, flip)
          local simpleAnim = sprite.simpleAnim
          if simpleAnim and simpleAnim.imagetable then
            simpleAnim.imagetable:drawImage(simpleAnim.currentFrame, x, y, flip)
          end
        end
      else
        -- Full RoxyAnimation
        self.animation = RoxyAnimation(view) -- Path-based constructor
        if not (self.animation and self.animation.imagetable) then
          error("[RoxySprite:setView] Failed to load spritesheet for RoxySprite", 2)
        end
        _applySizeFromImagetable(self.animation and self.animation.imagetable)
        self._drawFn = function(sprite, x, y, flip)
          sprite.animation:draw(x, y, flip)
        end
      end
    else
      -- Static
      local image = newImage(view)
      self:setImage(image) -- Playdate sets sprite size from image
      self._drawFn = function(sprite, x, y, flip)
        local img = sprite:getImage()
        if img then img:draw(x, y, flip) end
      end
    end

  elseif type(view) == "table" and (view.isRoxyAnimation == true) then
    -- Passed a RoxyAnimation instance directly
    if view.retain then view:retain() end -- Retain while this sprite uses it
    self.animation = view
    _applySizeFromImagetable(self.animation.imagetable)
    self._drawFn = function(sprite, x, y, flip)
      sprite.animation:draw(x, y, flip)
    end

  elseif type(view) == "userdata" then
    -- If it is an ImageTable (has drawImage), treat as a simpleAnim
    if view.drawImage then
      local length = view:getLength()
      self.simpleAnim = {
        imagetable    = view,
        startFrame    = 1,
        endFrame      = length,
        currentFrame  = 1,
        frameDuration = frameDuration or 0.1,
        accumulator   = 0,
        loop          = (singleAnimationLoop ~= false),
      }
      -- Ensure the sprite has bounds for culling/dirty-rects
      _applySizeFromImagetable(view)
      self._drawFn = function(sprite, x, y, flip)
        local anim = sprite.simpleAnim
        if anim and anim.imagetable then
          anim.imagetable:drawImage(anim.currentFrame, x, y, flip)
        end
      end
    elseif view.draw then
      self:setImage(view)
      self._drawFn = function(_, x, y, flip)
        view:draw(x, y, flip)
      end
    else
      error("[RoxySprite:setView] Unsupported userdata type for view", 2)
    end

  else
    error(("[RoxySprite:setView] Unsupported view type for RoxySprite: %s"):format(type(view)), 2)
  end

  return self
end

--------------------------------------------------------------------------------
-- Flip Flip
--------------------------------------------------------------------------------

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

--------------------------------------------------------------------------------
-- Animation Helpers
--------------------------------------------------------------------------------

-- ! Add Animation
-- Adds an animation definition to this sprite.
-- Table-based addAnimation; delegates cleanly to RoxyAnimation
function RoxySprite:addAnimation(name, nextContinuity, unlessThisAnimation)
  if self.animation then
    self.animation:addAnimation(name, nextContinuity, unlessThisAnimation)
  end
  return self
end

-- ! Set Animation
-- Switches the currently playing animation.
--
function RoxySprite:setAnimation(name, nextContinuity, unlessThisAnimation)
  --#DEBUG START
  if not self.animation then
    assert(false, "[RoxySprite:setAnimation] Sprite is not animated.")
  end
  --#DEBUG END

  if self.animation then
    self.animation:setAnimation(name, nextContinuity, unlessThisAnimation)
  end
  return self
end

--------------------------------------------------------------------------------
-- Playback
--------------------------------------------------------------------------------

-- ! Get isPaused
function RoxySprite:getIsPaused()
  return self.isPaused
end

-- ! Set isPaused
function RoxySprite:setIsPaused(flag)
  --#DEBUG START
  if type(flag) ~= "boolean" then
    Log.warn("[RoxySprite:setIsPaused] Expected boolean for 'isPaused', got", type(flag))
    return self
  end
  --#DEBUG END

  self.isPaused = flag
  return self
end

-- ! Play
function RoxySprite:play()
  if self.animation or self.simpleAnim then
    self.isPaused = false
    self:setUpdatesEnabled(true)  -- Enable engine updates
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
    self:setUpdatesEnabled(false)  -- Disable engine updates
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
  self:setUpdatesEnabled(true)  -- Enable engine updates
  return self
end

-- ! Stop
-- Stops the sprite's animation and resets it to the first frame.
function RoxySprite:stop()
  if self.animation or self.simpleAnim then
    self.isPaused = true
    self:setUpdatesEnabled(false)  -- Disable engine updates
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
  --#DEBUG START
  else
    Log.warn("[RoxySprite:reverse] Sprite has no animation (or simpleAnim) to reverse.")
  --#DEBUG END
  end
  return self
end

--------------------------------------------------------------------------------
-- Speed and Frame Duration
--------------------------------------------------------------------------------

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
  assert(type(speed) == "number", "[RoxySprite:setSpeed] 'speed' must be a number") --#DEBUG

  if self.animation then
    self.animation:setSpeed(speed, currentOnly)
  --#DEBUG START
  else
    Log.warn("[RoxySprite:setSpeed] Sprite has no animation (or simpleAnim) to set speed.")
  --#DEBUG END
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
  assert(type(frameDuration) == "number", "[RoxySprite:setFrameDuration] 'frameDuration' must be a number") --#DEBUG

  if self.animation then
    self.animation:setFrameDuration(frameDuration, currentOnly)
  --#DEBUG START
  else
    Log.warn("[RoxySprite:setFrameDuration] Sprite has no animation (or simpleAnim) to set frame duration.")
  --#DEBUG END
  end

  return self
end

--------------------------------------------------------------------------------
-- Frame Control
--------------------------------------------------------------------------------

-- ! Draw Specific Frame
function RoxySprite:drawSpecificFrame(frame, andPause)
  if self.animation then
    if andPause then self:pause() end
    self.animation:jumpToSpecificFrame(frame)
    if self.isPaused then self:markDirty() end
  --#DEBUG START
  else
    Log.warn("[RoxySprite:drawSpecificFrame] Sprite has no animation (or simpleAnim) to draw specific frame.")
  --#DEBUG END
  end
  return self
end

-- ! Step Frame
function RoxySprite:stepFrame(direction)
  if self.animation then
    self:pause()
    self.animation:stepFrame(direction)
    self:markDirty()
  --#DEBUG START
  else
    Log.warn("[RoxySprite:stepFrame] Sprite has no animation (or simpleAnim) to step frame.")
  --#DEBUG END
  end
  return self
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

-- ! Update
function RoxySprite:update()
  if self.isPaused then return end

  -- If parallax is configured, compute screen-space placement first.
  if self.parallaxX or self.parallaxY then
    local camX, camY = getPosition()
    local wx  = self.worldX or self.x or 0
    local wy  = self.worldY or self.y or 0
    local px  = self.parallaxX or 1
    local py  = self.parallaxY or 1
    local pox = self.parallaxOriginX or 0
    local poy = self.parallaxOriginY or 0
    local screenX = round(wx + pox * (1 - px) - camX * px)
    local screenY = round(wy + poy * (1 - py) - camY * py)
    self:moveTo(screenX, screenY)
  end

  -- Cache camera position once for all sprites that need it
  local camX, camY
  if not self._ignoresDrawOffset then
    camX, camY = getPosition()
  end

  -- Skip all animations if sprite is off-screen
  if not self:isOnScreenCached(camX, camY) then return end

  local dt = r.deltaTime or 0

  -- (Fast) Simple animation path
  local simpleAnim = self.simpleAnim
  if simpleAnim then
    -- Cache frequently accessed table fields as locals
    local currentFrame = simpleAnim.currentFrame
    local accumulator = simpleAnim.accumulator
    local frameDuration = simpleAnim.frameDuration
    local endFrame = simpleAnim.endFrame
    local startFrame = simpleAnim.startFrame
    local loop = simpleAnim.loop

    local oldFrame = currentFrame -- Track if frame changes

    accumulator = accumulator + dt

    -- Use while loop to handle large delta times properly
    while accumulator >= frameDuration do
      currentFrame = currentFrame + 1
      if currentFrame > endFrame then
        if loop then
          currentFrame = startFrame
        else
          currentFrame = endFrame
          -- Auto-pause completed one-shot animations for performance
          if not loop then
            self:pause()
          end
        end
      end
      accumulator = accumulator - frameDuration
    end

    -- Write back the changed values
    simpleAnim.currentFrame = currentFrame
    simpleAnim.accumulator = accumulator

    -- Only mark dirty if frame actually changed
    if currentFrame ~= oldFrame then
      self:markDirty()
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

--------------------------------------------------------------------------------
-- Sprite Lifecycle
--------------------------------------------------------------------------------

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

  -- Pause and disable sprite systems
  if self.isRoxySprite then self:pause() end
  self:setUpdatesEnabled(false)
  self:setCollisionsEnabled(false)

  -- Automatically detach from owning scene, if any
  if self.scene then
    local scene = self.scene
    self.scene = nil
    -- Guard against double-removal
    if scene.removeSprite then scene:removeSprite(self) end
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
-- Unified bounds calculation logic with proper center anchor handling
function RoxySprite:isOnScreen()
  local spriteX = self.x or 0
  local spriteY = self.y or 0
  local spriteWidth = self.width or 0
  local spriteHeight = self.height or 0
  local centerX, centerY = self:getCenter()

  -- Calculate actual bounds based on center anchor
  local left = spriteX - spriteWidth * centerX
  local top = spriteY - spriteHeight * centerY
  local right = left + spriteWidth
  local bottom = top + spriteHeight

  local leftLimit, topLimit, rightLimit, bottomLimit
  if self._ignoresDrawOffset then
    -- Screen-space bounds
    leftLimit, topLimit = 0, 0
    rightLimit, bottomLimit = DISPLAY_WIDTH, DISPLAY_HEIGHT
  else
    -- World-space bounds with camera
    local camX, camY = getPosition()
    leftLimit, topLimit = camX, camY
    rightLimit, bottomLimit = camX + DISPLAY_WIDTH, camY + DISPLAY_HEIGHT
  end

  return not (right < leftLimit or left > rightLimit or bottom < topLimit or top > bottomLimit)
end

-- ! Is on Screen (with cached camera)
-- Unified with isOnScreen logic and proper fallbacks
function RoxySprite:isOnScreenCached(camX, camY)
  local spriteX = self.x or 0
  local spriteY = self.y or 0
  local spriteWidth = self.width or 0
  local spriteHeight = self.height or 0
  local centerX, centerY = self:getCenter()

  -- Calculate actual bounds based on center anchor
  local left = spriteX - spriteWidth * centerX
  local top = spriteY - spriteHeight * centerY
  local right = left + spriteWidth
  local bottom = top + spriteHeight

  local leftLimit, topLimit, rightLimit, bottomLimit
  if self._ignoresDrawOffset then
    -- Screen-space bounds (camera position irrelevant)
    leftLimit, topLimit = 0, 0
    rightLimit, bottomLimit = DISPLAY_WIDTH, DISPLAY_HEIGHT
  else
    -- World-space bounds with provided camera coordinates
    leftLimit, topLimit = camX, camY
    rightLimit, bottomLimit = camX + DISPLAY_WIDTH, camY + DISPLAY_HEIGHT
  end

  return not (right < leftLimit or left > rightLimit or bottom < topLimit or top > bottomLimit)
end

-- ! Get Screen Position
function RoxySprite:getScreenPosition()
  if self._ignoresDrawOffset then
    return self.x, self.y
  else
    return worldToScreen(self.x, self.y)
  end
end

-- ! Destroy
-- On destroy/remove, release shared animation
function RoxySprite:destroy()
  self:remove()
  if self.animation and self.animation.release then
    self.animation:release()
  end
  self.animation  = nil
  self.simpleAnim = nil
  self:setImage(nil)
end

--[[
USAGE EXAMPLE:
RoxySprite is the foundation sprite class with optional parallax support

-- Basic sprite creation
local sprite = RoxySprite({
  name = "PlayerSprite",
  view = "images/player-idle"
}, scene)

-- Animated sprite with spritesheet
local animatedSprite = RoxySprite({
  name = "Enemy",
  view = "images/enemy-walk",
  isSheet = true
})

-- Simple looping animation
local simpleSprite = RoxySprite({
  view = "images/coin-spin",
  isSheet = true,
  singleAnim = true,
  frameDuration = 0.2
})

-- Parallax background layer
local backgroundSprite = RoxySprite({
  name = "Mountains",
  view = "images/mountains",
  worldX = 400,
  worldY = 240,
  parallaxX = 0.3, -- Moves slower than camera
  parallaxY = 0.1,
  parallaxOriginX = 200,
  parallaxOriginY = 120
})

-- Setup and positioning
sprite:moveTo(100, 100)
sprite:setZIndex(10)
sprite:setCenter(0.5, 1.0) -- Bottom-center anchor

-- Animation control
animatedSprite:addAnimation("walk", { frames = {1, 2, 3, 4}, loop = true })
animatedSprite:addAnimation("attack", { frames = {5, 6, 7}, nextAnimation = "walk" })
animatedSprite:setAnimation("walk")
animatedSprite:play()

-- Playback control
sprite:pause()
sprite:play()
sprite:setSpeed(2.0) -- Double speed
sprite:setFrameDuration(0.05) -- 20 FPS

-- Parallax control (can be added later)
sprite:setParallax(0.5, 0.8)
sprite:setWorldPosition(200, 150)
sprite:setParallaxOrigin(100, 75)

-- Sprite management
sprite:add()            -- Add to display list
scene:addSprite(sprite) -- Add to scene
sprite:remove()         -- Remove from display list
sprite:destroy()        -- Clean up resources

-- Utility methods
local onScreen = sprite:isOnScreen()
local screenX, screenY = sprite:getScreenPosition()
local isParallax = sprite:isParallaxEnabled()

-- Flip states
sprite:flipX()
sprite:flipY()
sprite:flipXY()
sprite:unflip()

-- Frame control (for animations)
sprite:drawSpecificFrame(5, true) -- Jump to frame 5 and pause
sprite:stepFrame(1)               -- Step forward one frame
sprite:stepFrame(-1)              -- Step backward one frame
]]--
