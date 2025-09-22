-- libraries/roxy/core/sprites/RoxySprite.lua

--------------------------------------------------------------------------------
-- Standard Lua Function Aliases
--------------------------------------------------------------------------------

local floor <const> = math.floor

--------------------------------------------------------------------------------
-- Playdate SDK Imports
--------------------------------------------------------------------------------

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

-- Playdate SDK Function Aliases
local performAfterDelay <const> = pd.timer.performAfterDelay
local newImage          <const> = Graphics.image.new
local newImageTable     <const> = Graphics.imagetable.new

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
-- Defaults
--------------------------------------------------------------------------------

local DELAY_DEFAULT <const> = 1 -- Seconds

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
-- Display Constants (Cached for Performance)
--------------------------------------------------------------------------------

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

-- Screen bounds constants for isOnScreen optimization
local SCREEN_LEFT_LIMIT   <const> = 0
local SCREEN_TOP_LIMIT    <const> = 0
local SCREEN_RIGHT_LIMIT  <const> = DISPLAY_WIDTH
local SCREEN_BOTTOM_LIMIT <const> = DISPLAY_HEIGHT

--------------------------------------------------------------------------------
-- Class Definition & Init
--------------------------------------------------------------------------------

class("RoxySprite").extends(Sprite)

-- ! Initialize
function RoxySprite:init(options, scene)
  options = options or {}
  RoxySprite.super.init(self)

  self.name               = options.name or "RoxySprite"
  self.isRoxySprite       = true
  self._added             = false
  self.isPaused           = true
  self.flip               = UNFLIPPED
  self.animation          = nil
  self._animationRetained = false -- Track if we retained the current animation
  self.simpleAnimation    = nil
  self._drawFn            = nil
  self._ignoresDrawOffset = false
  self._destroyed         = false -- Prevent use-after-destroy

  -- Parallax (optional; only active if configured)
  self.worldX, self.worldY        = nil, nil
  self.parallaxX, self.parallaxY  = nil, nil
  self.parallaxOriginX, self.parallaxOriginY = nil, nil

  -- Initialize from options if provided
  if options.worldX or options.worldY or options.parallaxX or options.parallaxY
     or options.parallaxOriginX or options.parallaxOriginY then
    self.worldX           = options.worldX or (self.x or 0)
    self.worldY           = options.worldY or (self.y or 0)
    self.parallaxX        = options.parallaxX or 1
    self.parallaxY        = options.parallaxY or 1
    self.parallaxOriginX  = options.parallaxOriginX or 0
    self.parallaxOriginY  = options.parallaxOriginY or 0
    self:setIgnoresDrawOffset(true)
    self:setUpdatesEnabled(true)
  end

  if options.view then
    self:setView(
      options.view,
      options.isSheet,
      options.singleAnimation,
      options.singleAnimationLoop ~= false,
      options.frameDuration or 0.1
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
  assert(type(flag) == "boolean", "[RoxySprite:setIgnoresDrawOffset] Expected boolean, got " .. tostring(type(flag)))

  self._ignoresDrawOffset = flag
  RoxySprite.super.setIgnoresDrawOffset(self, flag)
  return self
end

-- ! Set Z-Index
function RoxySprite:setZIndex(zIndex)
  assert(type(zIndex) == "number", "[RoxySprite:setZIndex] Expected number, got " .. tostring(type(zIndex)))

  RoxySprite.super.setZIndex(self, zIndex)
  return self
end

-- ! Set Size
function RoxySprite:setSize(width, height)
  assert(type(width) == "number" and type(height) == "number", "[RoxySprite:setSize] Width and height must be numbers")

  RoxySprite.super.setSize(self, width, height)
  return self
end

-- ! Set Center
function RoxySprite:setCenter(x, y)
  assert(type(x) == "number" and type(y) == "number", "[RoxySprite:setCenter] Center coordinates must be numbers")

  RoxySprite.super.setCenter(self, x, y)
  return self
end

-- ! Move To
function RoxySprite:moveTo(x, y)
  assert(type(x) == "number" and type(y) == "number", "[RoxySprite:moveTo] Coordinates must be numbers")

  RoxySprite.super.moveTo(self, x, y)
  return self
end

--------------------------------------------------------------------------------
-- Parallax API (optional)
--------------------------------------------------------------------------------

-- ! Enable/adjust world position used for parallax placement
function RoxySprite:setWorldPosition(x, y)
  if x ~= nil and type(x) ~= "number" then
    Log.warn("[RoxySprite:setWorldPosition] x must be a number or nil; keeping current x=%s", tostring(self.worldX or self.x or 0)) --#DEBUG
    x = nil
  end
  if y ~= nil and type(y) ~= "number" then
    Log.warn("[RoxySprite:setWorldPosition] y must be a number or nil; keeping current y=%s", tostring(self.worldY or self.y or 0)) --#DEBUG
    y = nil
  end

  self.worldX = x or self.worldX or self.x or 0
  self.worldY = y or self.worldY or self.y or 0
  return self
end

-- ! Set Parallax factors (1 = normal scrolling, 0 = fixed position, 0.5 = half speed)
function RoxySprite:setParallax(parallaxX, parallaxY)
  if parallaxX ~= nil and type(parallaxX) ~= "number" then
    Log.warn("[RoxySprite:setParallax] parallaxX must be a number or nil; keeping current parallaxX=%s", tostring(self.parallaxX or 1)) --#DEBUG
    parallaxX = nil
  end
  if parallaxY ~= nil and type(parallaxY) ~= "number" then
    Log.warn("[RoxySprite:setParallax] parallaxY must be a number or nil; keeping current parallaxY=%s", tostring(self.parallaxY or 1)) --#DEBUG
    parallaxY = nil
  end

  self.parallaxX = parallaxX or self.parallaxX or 1
  self.parallaxY = parallaxY or self.parallaxY or 1
  -- Parallax uses screen-space placement
  self:setIgnoresDrawOffset(true)
  self:setUpdatesEnabled(true)
  return self
end

-- ! Set Parallax origin (anchor in screen/world terms)
function RoxySprite:setParallaxOrigin(originX, originY)
  if originX ~= nil and type(originX) ~= "number" then
    Log.warn("[RoxySprite:setParallaxOrigin] originX must be a number or nil; keeping current originX=%s", tostring(self.parallaxOriginX or 0)) --#DEBUG
    originX = nil
  end
  if originY ~= nil and type(originY) ~= "number" then
    Log.warn("[RoxySprite:setParallaxOrigin] originY must be a number or nil; keeping current originY=%s", tostring(self.parallaxOriginY or 0)) --#DEBUG
    originY = nil
  end

  self.parallaxOriginX = originX or self.parallaxOriginX or 0
  self.parallaxOriginY = originY or self.parallaxOriginY or 0
  return self
end

-- ! Parallax enabled?
function RoxySprite:isParallaxEnabled()
  return self.parallaxX ~= nil or self.parallaxY ~= nil
end

--------------------------------------------------------------------------------
-- View Management
--------------------------------------------------------------------------------

-- ! Clear View Helper - Fixed memory leak by properly tracking retained animations
function RoxySprite:clearView()
  -- Properly release retained animations to prevent memory leaks
  if self.animation then
    self.animation:stop()
    -- Only release if we retained it
    if self._animationRetained and self.animation.release then
      self.animation:release()
    end
    self.animation = nil
    self._animationRetained = false
  end

  self.simpleAnimation = nil -- Clear any previous simpleAnimation
  if self:getImage() then
    self:setImage(nil)
  end
  self._drawFn = nil
  -- Set fallback size when clearing view
  self:setSize(0, 0)
end

-- ! Helper: Apply sprite size from first frame of an image table
local function _applySizeFromImageTable(sprite, imagetable)
  if not imagetable or not imagetable.getImage then return end

  local first = imagetable:getImage(1)
  if not first or not first.getSize then return end

  local width, height = first:getSize()
  if width and height then
    sprite:setSize(width, height)
    sprite:setCenter(0.5, 0.5)
  end
end

-- ! Helper: Setup pooled animation with proper memory management
local function _setupPooledAnimation(sprite, view)
  local kind = view.kind or "sheet"

  if kind == "sheet" then
    -- Load imagetable from pool; wrap as RoxyAnimation
    local imagetable = getAsset(view.poolKey)
    if not imagetable then
      error(("[RoxySprite:setView] Pool key not found: %s"):format(tostring(view.poolKey)), 3)
    end
    sprite.animation = RoxyAnimation.fromImagetable(imagetable) -- Refcount owned by this sprite
    sprite._animationRetained = false -- We own this, don't need to release
    _applySizeFromImageTable(sprite, imagetable)
    sprite._drawFn = function(s, x, y, flip) s.animation:draw(x, y, flip) end

  elseif kind == "animation" then
    -- Pooled/shared animation object in Assets pool
    local animation = getAsset(view.poolKey)
    if not (type(animation) == "table" and animation.isRoxyAnimation) then
      error(("[RoxySprite:setView] Pool key does not resolve to RoxyAnimation: %s"):format(tostring(view.poolKey)), 3)
    end
    if animation.retain then
      animation:retain()
      sprite._animationRetained = true -- Track that we retained this
    end
    sprite.animation = animation
    _applySizeFromImageTable(sprite, animation.imagetable)
    sprite._drawFn = function(s, x, y, flip) s.animation:draw(x, y, flip) end

  elseif kind == "image" then
    local image = getAsset(view.poolKey)
    if not (image and image.draw) then
      error(("[RoxySprite:setView] Pool key does not resolve to Image: %s"):format(tostring(view.poolKey)), 3)
    end
    sprite:setImage(image) -- Sets sprite size from image
    sprite._drawFn = function(_, x, y, flip) image:draw(x, y, flip) end

  else
    error(("[RoxySprite:setView] Unknown view kind: %s"):format(tostring(kind)), 3)
  end
end

-- ! Helper: Setup simple animation with validation
local function _setupSimpleAnimation(sprite, imagetable, frameDuration, loop)
  assert(imagetable, "[RoxySprite:setView] Failed to load imagetable for simpleAnimation")

  -- Validate frame duration to prevent infinite update loops
  if not frameDuration or frameDuration <= 0 then
    error("[RoxySprite:setView] frameDuration must be > 0 for simpleAnimation", 3)
  end

  sprite.simpleAnimation = {
    imagetable    = imagetable,
    startFrame    = 1,
    endFrame      = imagetable:getLength(),
    currentFrame  = 1,
    frameDuration = frameDuration,
    accumulator   = 0,
    loop          = loop,
  }

  _applySizeFromImageTable(sprite, imagetable)
  -- Optimized draw function for simpleAnimation
  sprite._drawFn = function(s, x, y, flip)
    local simpleAnimation = s.simpleAnimation
    if simpleAnimation and simpleAnimation.imagetable then
      simpleAnimation.imagetable:drawImage(simpleAnimation.currentFrame, x, y, flip)
    end
  end
end

-- ! Set View
function RoxySprite:setView(view, viewIsSpritesheet, singleAnimation, singleAnimationLoop, frameDuration)
  --#DEBUG START
  if self._destroyed then
    error("[RoxySprite:setView] Cannot set view on destroyed sprite", 2)
  end
  --#DEBUG END

  if not view then
    self:setVisible(false)
    self:clearView()
    return self
  end
  self:setVisible(true)

  -- Clear previous state (handles memory cleanup properly)
  self:clearView()

  -- Handle descriptor table form
  if type(view) == "table" and view.poolKey then
    _setupPooledAnimation(self, view)
    return self
  end

  -- Handle direct pooled objects
  if type(view) == "table" and view.imagetable then
    self.animation = RoxyAnimation.fromImagetable(view.imagetable)
    self._animationRetained = false
    _applySizeFromImageTable(self, view.imagetable)
    self._drawFn = function(s, x, y, flip) s.animation:draw(x, y, flip) end
    return self
  end

  if type(view) == "table" and view.animation and
     (type(view.animation) == "table" and view.animation.isRoxyAnimation) then
    if view.animation.retain then
      view.animation:retain()
      self._animationRetained = true
    end
    self.animation = view.animation
    _applySizeFromImageTable(self, view.animation.imagetable)
    self._drawFn = function(s, x, y, flip) s.animation:draw(x, y, flip) end
    return self
  end

  -- Handle string paths
  if type(view) == "string" then
    if viewIsSpritesheet then
      if singleAnimation then
        -- Simple looping spritesheet
        local imagetable = newImageTable(view)
        _setupSimpleAnimation(self, imagetable, frameDuration or 0.1, singleAnimationLoop ~= false)
      else
        -- Full RoxyAnimation
        self.animation = RoxyAnimation(view) -- Path-based constructor
        self._animationRetained = false
        if not (self.animation and self.animation.imagetable) then
          error("[RoxySprite:setView] Failed to load spritesheet for RoxySprite", 2)
        end
        _applySizeFromImageTable(self, self.animation.imagetable)
        self._drawFn = function(s, x, y, flip) s.animation:draw(x, y, flip) end
      end
    else
      -- Static image
      local image = newImage(view)
      if not image then
        error("[RoxySprite:setView] Failed to load image: " .. tostring(view), 2)
      end
      self:setImage(image) -- Playdate sets sprite size from image
      self._drawFn = function(s, x, y, flip)
        local image = s:getImage()
        if image then image:draw(x, y, flip) end
      end
    end

  elseif type(view) == "table" and (view.isRoxyAnimation == true) then
    -- Direct RoxyAnimation instance
    if view.retain then
      view:retain()
      self._animationRetained = true
    end
    self.animation = view
    _applySizeFromImageTable(self, view.imagetable)
    self._drawFn = function(s, x, y, flip) s.animation:draw(x, y, flip) end

  elseif type(view) == "userdata" then
    -- Handle ImageTable or Image userdata
    if view.drawImage then
      -- ImageTable - treat as simple animation
      _setupSimpleAnimation(self, view, frameDuration or 0.1, singleAnimationLoop ~= false)
    elseif view.draw then
      -- Image
      self:setImage(view)
      self._drawFn = function(_, x, y, flip) view:draw(x, y, flip) end
    else
      error("[RoxySprite:setView] Unsupported userdata type for view", 2)
    end

  else
    error(("[RoxySprite:setView] Unsupported view type: %s"):format(type(view)), 2)
  end

  return self
end

--------------------------------------------------------------------------------
-- Flip State Management
--------------------------------------------------------------------------------

-- ! Set Flip State
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
-- Animation Definition
--------------------------------------------------------------------------------

-- ! Add Animation
function RoxySprite:addAnimation(name, nextContinuity, unlessThisAnimation)
  if not name or type(name) ~= "string" then
    assert(type(name) == "string" and name ~= "", "[RoxySprite:addAnimation] Animation name must be a non-empty string")
  end

  if self.animation then
    self.animation:addAnimation(name, nextContinuity, unlessThisAnimation)
  --#DEBUG START
  else
    Log.warn("[RoxySprite:addAnimation] Sprite has no animation system")
  --#DEBUG END
  end
  return self
end

-- ! Set Animation
function RoxySprite:setAnimation(name, nextContinuity, unlessThisAnimation)
  if not name or type(name) ~= "string" then
    assert(type(name) == "string" and name ~= "", "[RoxySprite:setAnimation] Animation name must be a non-empty string")
  end

  if self.animation then
    self.animation:setAnimation(name, nextContinuity, unlessThisAnimation)
  --#DEBUG START
  else
    Log.warn("[RoxySprite:setAnimation] Sprite has no animation system")
  --#DEBUG END
  end
  return self
end

--------------------------------------------------------------------------------
-- Playback Control
--------------------------------------------------------------------------------

-- ! Get isPaused
function RoxySprite:getIsPaused()
  return self.isPaused
end

-- ! Set isPaused
function RoxySprite:setIsPaused(flag)
  if type(flag) == "boolean" then
    self.isPaused = flag
  --#DEBUG START
  else
    Log.warn("[RoxySprite:setIsPaused] Expected boolean, got %s", type(flag))
  --#DEBUG END
  end
  return self
end

-- ! Play
function RoxySprite:play()
  if self.animation or self.simpleAnimation then
    self.isPaused = false
    self:setUpdatesEnabled(true) -- Enable engine updates
  end
  return self
end

-- ! Play With Delay - Fixed race condition
function RoxySprite:playWithDelay(delay, animationName)
  if not (type(delay) == "number" and delay > 0) then
    Log.warn("[RoxySprite:playWithDelay] Delay must be a positive number") --#DEBUG
    delay = DELAY_DEFAULT
  end

  if self.animation or self.simpleAnimation then
    performAfterDelay(delay * MS_PER_SECOND, function()
      -- Check if sprite still exists and hasn't been destroyed
      if not self._destroyed and self.animation then
        if animationName then
          self:setAnimation(animationName)
        end
        self:play()
      end
    end)
  end
  return self
end

-- ! Pause
function RoxySprite:pause()
  if self.animation or self.simpleAnimation then
    self.isPaused = true
    self:setUpdatesEnabled(false) -- Disable engine updates
  end
  return self
end

-- ! Toggle Play/Pause
function RoxySprite:togglePlayPause()
  if self.isPaused then
    return self:play()
  else
    return self:pause()
  end
end

-- ! Replay
function RoxySprite:replay()
  if self.animation then
    self.animation:resetAnimationStart()
  elseif self.simpleAnimation then
    self.simpleAnimation.currentFrame = self.simpleAnimation.startFrame
    self.simpleAnimation.accumulator  = 0
  end
  self.isPaused = false
  self:setUpdatesEnabled(true)
  return self
end

-- ! Stop
function RoxySprite:stop()
  if self.animation or self.simpleAnimation then
    self.isPaused = true
    self:setUpdatesEnabled(false)
    if self.animation then
      self.animation:resetAnimationStart()
    elseif self.simpleAnimation then
      self.simpleAnimation.currentFrame = self.simpleAnimation.startFrame
      self.simpleAnimation.accumulator  = 0
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
    Log.warn("[RoxySprite:reverse] Sprite has no animation system")
  --#DEBUG END
  end
  return self
end

--------------------------------------------------------------------------------
-- Speed and Frame Duration Control
--------------------------------------------------------------------------------

-- ! Get Speed
function RoxySprite:getSpeed()
  if self.animation then
    return self.animation:getSpeed()
  end
  return nil
end

-- ! Set Speed
function RoxySprite:setSpeed(speed, currentOnly)
  assert(type(speed) == "number", "[RoxySprite:setSpeed] Speed must be a number")

  if self.animation then
    self.animation:setSpeed(speed, currentOnly)
  --#DEBUG START
  else
    Log.warn("[RoxySprite:setSpeed] Sprite has no animation system")
  --#DEBUG END
  end

  return self
end

-- ! Get Frame Duration
function RoxySprite:getFrameDuration()
  if self.animation then
    return self.animation:getFrameDuration()
  end
  return nil
end

-- ! Set Frame Duration
function RoxySprite:setFrameDuration(frameDuration, currentOnly)
  assert(type(frameDuration) == "number" and frameDuration > 0,
         "[RoxySprite:setFrameDuration] Frame duration must be a positive number")

  if self.animation then
    self.animation:setFrameDuration(frameDuration, currentOnly)
  --#DEBUG START
  else
    Log.warn("[RoxySprite:setFrameDuration] Sprite has no animation system")
  --#DEBUG END
  end

  return self
end

--------------------------------------------------------------------------------
-- Frame Control
--------------------------------------------------------------------------------

-- ! Draw Specific Frame
function RoxySprite:drawSpecificFrame(frame, andPause)
  if type(frame) ~= "number" or frame < 1 then
    Log.warn("[RoxySprite:drawSpecificFrame] Frame must be a positive number") --#DEBUG
    frame = 1
  end

  if self.animation then
    if andPause then self:pause() end
    self.animation:jumpToSpecificFrame(frame)
    if self.isPaused then self:markDirty() end
  --#DEBUG START
  else
    Log.warn("[RoxySprite:drawSpecificFrame] Sprite has no animation system")
  --#DEBUG END
  end
  return self
end

-- ! Step Frame
function RoxySprite:stepFrame(direction)
  direction = direction or 1
  if type(direction) ~= "number" then
    Log.warn("[RoxySprite:stepFrame] Direction must be a number") --#DEBUG
    direction = 1
  end

  if self.animation then
    self:pause()
    self.animation:stepFrame(direction)
    self:markDirty()
  --#DEBUG START
  else
    Log.warn("[RoxySprite:stepFrame] Sprite has no animation system")
  --#DEBUG END
  end
  return self
end

--------------------------------------------------------------------------------
-- Rendering - Optimized to cache camera position once
--------------------------------------------------------------------------------

-- ! Update
function RoxySprite:update()
  if self._destroyed then return end

  local hasParallax = (self.parallaxX ~= nil) or (self.parallaxY ~= nil)
  local cameraX, cameraY

  if hasParallax or not self._ignoresDrawOffset then
    cameraX, cameraY = Camera.getPosition()
  end

  if hasParallax then
    local worldX = self.worldX or 0
    local worldY = self.worldY or 0
    local parallaxX = self.parallaxX or 1
    local parallaxY = self.parallaxY or 1
    local parallaxOriginX = self.parallaxOriginX or 0
    local parallaxOriginY = self.parallaxOriginY or 0

    local spriteX = floor(parallaxOriginX + (worldX - cameraX) * parallaxX + 0.5)
    local spriteY = floor(parallaxOriginY + (worldY - cameraY) * parallaxY + 0.5)
    self:moveTo(spriteX, spriteY)
  end

  -- Skip all animations if sprite is paused or off-screen
  if self.isPaused then return end
  if not self:isOnScreen(cameraX, cameraY) then return end

  local dt = r.deltaTime or 0

  -- Fast path: Simple animation with reduced local variable copying
  local simpleAnimation = self.simpleAnimation
  if simpleAnimation then
    local oldFrame = simpleAnimation.currentFrame -- Track if frame changes
    simpleAnimation.accumulator += dt

    -- Handle large delta times properly
    while simpleAnimation.accumulator >= simpleAnimation.frameDuration do
      simpleAnimation.currentFrame += 1
      if simpleAnimation.currentFrame > simpleAnimation.endFrame then
        if simpleAnimation.loop then
          simpleAnimation.currentFrame = simpleAnimation.startFrame
        else
          simpleAnimation.currentFrame = simpleAnimation.endFrame
          -- Auto-pause to save CPU when one-shot completes
          self:pause()
          break
        end
      end
      simpleAnimation.accumulator -= simpleAnimation.frameDuration
    end

    -- Only mark dirty if frame actually changed
    if simpleAnimation.currentFrame ~= oldFrame then
      self:markDirty()
    end
    return
  end

  -- Full RoxyAnimation path
  if self.animation then
    local previousFrame = self.animation.currentFrame
    self.animation:update()
    if self.animation.currentFrame ~= previousFrame then
      self:markDirty()
    end
  end
end

-- ! Draw
function RoxySprite:draw()
  if self._drawFn and not self._destroyed then
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
  if self.isRoxySprite and (self.animation or self.simpleAnimation) then
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
function RoxySprite:isOnScreen(cachedCamX, cachedCamY)
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
    leftLimit, topLimit = SCREEN_LEFT_LIMIT, SCREEN_TOP_LIMIT
    rightLimit, bottomLimit = SCREEN_RIGHT_LIMIT, SCREEN_BOTTOM_LIMIT
  else
    -- World-space bounds with camera (use cached values if provided)
    local camX, camY = cachedCamX, cachedCamY
    if not camX then
      camX, camY = getPosition()
    end
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
function RoxySprite:destroy()
  if self._destroyed then return end -- Prevent double-destroy

  self._destroyed = true
  self:remove()

  -- Release retained animations to prevent memory leaks
  if self.animation and self._animationRetained and self.animation.release then
    self.animation:release()
  end

  self.animation = nil
  self._animationRetained = false
  self.simpleAnimation = nil
  self:setImage(nil)
  self:setSize(0, 0)
  self._drawFn = nil
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
