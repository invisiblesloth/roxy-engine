-- core/sprites/RoxySprite.lua

-- Extends Playdate sprites with scene ownership, view management, and animation helpers
-- Supports simple spritesheets, pooled assets, pause classification, and parallax positioning
-- Simple animations store frameDuration in seconds; frameRate is a convenience input

local floor <const> = math.floor

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r             <const> = roxy
local Assets        <const> = r.Assets
local Camera        <const> = r.Camera
local Scene         <const> = r.Scene
local RoxyGraphics  <const> = r.Graphics

local clamp <const> = r.Math.clamp

local performAfterDelay <const> = pd.timer.performAfterDelay
local newImage          <const> = Graphics.image.new
local newImageTable     <const> = Graphics.imagetable.new
local getAsset          <const> = Assets.getAsset
local recycleAsset      <const> = Assets.recycleAsset
local getPosition       <const> = Camera.getPosition
local getShakeOffset    <const> = Camera.getShakeOffset
local worldToScreen     <const> = Camera.worldToScreen
local getRefreshRate    <const> = RoxyGraphics.getRefreshRate

local UNFLIPPED   <const> = Graphics.kImageUnflipped
local FLIPPED_X   <const> = Graphics.kImageFlippedX
local FLIPPED_Y   <const> = Graphics.kImageFlippedY
local FLIPPED_X_Y <const> = Graphics.kImageFlippedXY

local MS_PER_SECOND <const> = 1000
local DELAY_DEFAULT <const> = 1 -- Seconds

local DISPLAY_WIDTH   <const> = RoxyGraphics.displayWidth
local DISPLAY_HEIGHT  <const> = RoxyGraphics.displayHeight

local SCREEN_LEFT_LIMIT   <const> = 0
local SCREEN_TOP_LIMIT    <const> = 0
local SCREEN_RIGHT_LIMIT  <const> = DISPLAY_WIDTH
local SCREEN_BOTTOM_LIMIT <const> = DISPLAY_HEIGHT

local FRAME_RATE_DEFAULT      <const> = 30
local FRAME_DURATION_DEFAULT  <const> = 1 / FRAME_RATE_DEFAULT
local MIN_FRAME_DURATION      <const> = 0.016
local MAX_FRAME_DURATION      <const> = 10

--------------------------------------------------------------------------------
-- Private Helper Functions
--------------------------------------------------------------------------------

-- ! Helper: Draw Animation
local function _drawAnimation(sprite, x, y, flip)
  sprite.animation:draw(x, y, flip)
end

-- ! Helper: Draw Simple Animation
local function _drawSimpleAnimation(sprite, x, y, flip)
  local simpleAnimation = sprite.simpleAnimation
  if simpleAnimation and simpleAnimation.imagetable then
    simpleAnimation.imagetable:drawImage(simpleAnimation.currentFrame, x, y, flip)
  end
end

-- ! Helper: Has Parallax
-- Returns true when the sprite needs camera-relative parallax updates
local function _hasParallax(sprite)
  return sprite.parallaxX ~= nil or sprite.parallaxY ~= nil
end

-- ! Helper: Set Collisions Active
-- Toggles the Playdate collision system without changing Roxy's desired state
local function _setCollisionsActive(sprite, flag)
  sprite._collisionsActive = flag == true
  RoxySprite.super.setCollisionsEnabled(sprite, flag)
end

-- ! Helper: Resolve Simple Frame Rate
local function _resolveSimpleFrameRate(frameRate, fallbackDuration, label, warnOnInvalid)
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

-- ! Helper: Resolve Simple Frame Duration Config
local function _resolveSimpleFrameDuration(frameDuration, frameRate, fallbackDuration, label)
  if frameDuration ~= nil then
    return frameDuration
  end
  if frameRate ~= nil then
    return _resolveSimpleFrameRate(frameRate, fallbackDuration, label, true)
  end
  return fallbackDuration
end

-- ! Helper: Resolve Simple Frame Rate Setter
local function _resolveSimpleFrameRateSetter(frameRate)
  if not ((type(frameRate) == "number" and frameRate > 0) or frameRate == "display") then
    error("[RoxySprite:setFrameRate] Frame rate must be a positive number or \"display\"", 3)
  end

  if frameRate == "display" then
    local displayRate = getRefreshRate(true)
    if type(displayRate) ~= "number" or displayRate <= 0 then
      error("[RoxySprite:setFrameRate] Display refresh rate must be a positive number", 3)
    end
    return 1 / displayRate
  end

  return 1 / frameRate
end

--------------------------------------------------------------------------------
-- Class Definition
--------------------------------------------------------------------------------

class("RoxySprite").extends(Sprite)

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

-- ! Initialize
function RoxySprite:init(options, scene)
  options = options or {}
  RoxySprite.super.init(self)

  self.name                     = options.name or "RoxySprite"
  self.isRoxySprite             = true
  self._added                   = false
  self.isPaused                 = true
  self.flip                     = UNFLIPPED
  self.animation                = nil
  self._animationRetained       = false -- Track if the current animation should be released
  self._animationPoolKey        = nil   -- Track checked-out full animation objects
  self._imagePoolKey            = nil
  self._pooledImage             = nil
  self.simpleAnimation          = nil
  self._drawFn                  = nil
  self._ignoresDrawOffset       = false
  self._collisionsEnabled       = true
  self._collisionsActive        = true
  self._restoreCollisionsOnAdd  = false
  self._destroyed               = false -- Prevent use-after-destroy
  -- Authoritative Roxy culling anchor; center changes must route through setCenter.
  self._centerX                 = 0.5
  self._centerY                 = 0.5

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
      options.frameDuration,
      options.frameRate
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

-- ! Set Pause Classification
function RoxySprite:setPauseClassification(opts)
  return Scene.setSpritePauseClassification(self, opts)
end

-- ! Set Ignores Draw Offset
function RoxySprite:setIgnoresDrawOffset(flag)
  if type(flag) ~= "boolean" then
    error("[RoxySprite:setIgnoresDrawOffset] Expected boolean, got " .. tostring(type(flag)), 2)
  end

  self._ignoresDrawOffset = flag
  RoxySprite.super.setIgnoresDrawOffset(self, flag)
  return self
end

-- ! Set Collisions Enabled
-- Sets the desired collision state and applies it immediately
function RoxySprite:setCollisionsEnabled(flag)
  if type(flag) ~= "boolean" then
    error("[RoxySprite:setCollisionsEnabled] Expected boolean, got " .. tostring(type(flag)), 2)
  end

  self._collisionsEnabled = flag
  if flag == false then
    self._restoreCollisionsOnAdd = false
  end
  _setCollisionsActive(self, flag)
  return self
end

-- ! Set Scene Pause Collisions Active
-- Temporarily toggles collision participation without changing desired state.
function RoxySprite:_setScenePauseCollisionsActive(flag)
  if type(flag) ~= "boolean" then
    error("[RoxySprite:_setScenePauseCollisionsActive] Expected boolean, got " .. tostring(type(flag)), 2)
  end

  _setCollisionsActive(self, flag)
  return self
end

-- ! Set Z-Index
function RoxySprite:setZIndex(zIndex)
  if type(zIndex) ~= "number" then
    error("[RoxySprite:setZIndex] Expected number, got " .. tostring(type(zIndex)), 2)
  end

  RoxySprite.super.setZIndex(self, zIndex)
  return self
end

-- ! Set Size
function RoxySprite:setSize(width, height)
  if type(width) ~= "number" or type(height) ~= "number" then
    error("[RoxySprite:setSize] Width and height must be numbers", 2)
  end

  RoxySprite.super.setSize(self, width, height)
  return self
end

-- ! Set Center
function RoxySprite:setCenter(x, y)
  if type(x) ~= "number" or type(y) ~= "number" then
    error("[RoxySprite:setCenter] Center coordinates must be numbers", 2)
  end

  RoxySprite.super.setCenter(self, x, y)
  self._centerX = x
  self._centerY = y
  return self
end

-- ! Move To
function RoxySprite:moveTo(x, y)
  if type(x) ~= "number" or type(y) ~= "number" then
    error("[RoxySprite:moveTo] Coordinates must be numbers", 2)
  end

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
  return _hasParallax(self)
end

--------------------------------------------------------------------------------
-- View Management
--------------------------------------------------------------------------------

-- ! Clear View
-- Releases sprite-owned view resources and clears display state
function RoxySprite:clearView()
  -- Release current animation ownership
  if self.animation then
    self.animation:stop()
    if self._animationPoolKey then
      recycleAsset(self._animationPoolKey, self.animation)
    elseif self._animationRetained and self.animation.release then
      self.animation:release()
    end
    self.animation = nil
    self._animationRetained = false
    self._animationPoolKey = nil
  end

  if self._imagePoolKey and self._pooledImage then
    recycleAsset(self._imagePoolKey, self._pooledImage)
    self._imagePoolKey = nil
    self._pooledImage = nil
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

-- ! Helper: Setup Pooled View
-- Sets up pooled sheet, full-animation, or image descriptors
local function _setupPooledAnimation(sprite, view)
  local kind = view.kind or "sheet"

  if kind == "sheet" then
    -- Pooled sheets share image data with sprite-local playback state
    sprite.animation = RoxyAnimation.fromPool(view.poolKey)
    sprite._animationRetained = true
    _applySizeFromImageTable(sprite, sprite.animation.imagetable)
    sprite._drawFn = _drawAnimation

  elseif kind == "animation" then
    -- Pooled full animation object from an Assets pool
    local animation = getAsset(view.poolKey)
    if not (type(animation) == "table" and animation.isRoxyAnimation) then
      if animation then
        recycleAsset(view.poolKey, animation)
      end
      error(("[RoxySprite:setView] Pool key does not resolve to RoxyAnimation: %s"):format(tostring(view.poolKey)), 3)
    end
    sprite.animation = animation
    sprite._animationRetained = false
    sprite._animationPoolKey = view.poolKey
    _applySizeFromImageTable(sprite, animation.imagetable)
    sprite._drawFn = _drawAnimation

  elseif kind == "image" then
    local image = getAsset(view.poolKey)
    if not (image and image.draw) then
      if image then
        recycleAsset(view.poolKey, image)
      end
      error(("[RoxySprite:setView] Pool key does not resolve to Image: %s"):format(tostring(view.poolKey)), 3)
    end
    sprite._imagePoolKey = view.poolKey
    sprite._pooledImage = image
    sprite:setImage(image) -- Sets sprite size from image
    sprite._drawFn = function(_, x, y, flip) image:draw(x, y, flip) end

  else
    error(("[RoxySprite:setView] Unknown view kind: %s"):format(tostring(kind)), 3)
  end
end

-- ! Helper: Setup simple animation with validation
local function _setupSimpleAnimation(sprite, imagetable, frameDuration, loop)
  if not imagetable then
    error("[RoxySprite:setView] Failed to load imagetable for simpleAnimation", 3)
  end

  -- Validate frame duration to prevent infinite update loops
  if not frameDuration or frameDuration <= 0 then
    error("[RoxySprite:setView] frameDuration must be > 0 for simpleAnimation", 3)
  end
  frameDuration = clamp(frameDuration, MIN_FRAME_DURATION, MAX_FRAME_DURATION)

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
  sprite._drawFn = _drawSimpleAnimation
end

-- ! Set View
function RoxySprite:setView(view, viewIsSpritesheet, singleAnimation, singleAnimationLoop, frameDuration, frameRate)
  if self._destroyed then
    error("[RoxySprite:setView] Cannot set view on destroyed sprite", 2)
  end

  if not view then
    self:setVisible(false)
    self:clearView()
    return self
  end
  self:setVisible(true)

  -- Clear previous view state before installing the new one
  self:clearView()

  -- Handle descriptor table form
  if type(view) == "table" and view.poolKey then
    _setupPooledAnimation(self, view)
    return self
  end

  if type(view) == "table" and (view.isRoxyAnimation == true) then
    -- Direct RoxyAnimation instances share playback state explicitly
    if view.retain then
      view:retain()
      self._animationRetained = true
    end
    self.animation = view
    _applySizeFromImageTable(self, view.imagetable)
    self._drawFn = _drawAnimation
    return self
  end

  if type(view) == "table" and view.animation and
     (type(view.animation) == "table" and view.animation.isRoxyAnimation) then
    -- Wrapped RoxyAnimation instances share playback state explicitly
    if view.animation.retain then
      view.animation:retain()
      self._animationRetained = true
    end
    self.animation = view.animation
    _applySizeFromImageTable(self, view.animation.imagetable)
    self._drawFn = _drawAnimation
    return self
  end

  -- Handle imagetable descriptor tables
  if type(view) == "table" and view.imagetable then
    self.animation = RoxyAnimation.fromImagetable(view.imagetable)
    self._animationRetained = true
    _applySizeFromImageTable(self, view.imagetable)
    self._drawFn = _drawAnimation
    return self
  end

  -- Handle string paths
  if type(view) == "string" then
    if viewIsSpritesheet then
      if singleAnimation then
        -- Simple looping spritesheet
        local imagetable = newImageTable(view)
        local resolvedFrameDuration = _resolveSimpleFrameDuration(
          frameDuration,
          frameRate,
          FRAME_DURATION_DEFAULT,
          "RoxySprite:setView"
        )
        _setupSimpleAnimation(self, imagetable, resolvedFrameDuration, singleAnimationLoop ~= false)
      else
        -- Full RoxyAnimation
        self.animation = RoxyAnimation(view) -- Path-based constructor
        self._animationRetained = true
        if not (self.animation and self.animation.imagetable) then
          error("[RoxySprite:setView] Failed to load spritesheet for RoxySprite", 2)
        end
        _applySizeFromImageTable(self, self.animation.imagetable)
        self._drawFn = _drawAnimation
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

  elseif type(view) == "userdata" then
    -- Handle ImageTable or Image userdata
    if view.drawImage then
      -- ImageTable - treat as simple animation
      local resolvedFrameDuration = _resolveSimpleFrameDuration(
        frameDuration,
        frameRate,
        FRAME_DURATION_DEFAULT,
        "RoxySprite:setView"
      )
      _setupSimpleAnimation(self, view, resolvedFrameDuration, singleAnimationLoop ~= false)
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

-- ! Unflip
function RoxySprite:unflip()
  return self:setFlipState(UNFLIPPED)
end

-- ! Flip X
function RoxySprite:flipX()
  return self:setFlipState(FLIPPED_X)
end

-- ! Flip Y
function RoxySprite:flipY()
  return self:setFlipState(FLIPPED_Y)
end

-- ! Flip XY
function RoxySprite:flipXY()
  return self:setFlipState(FLIPPED_X_Y)
end

-- ! Get Orientation
function RoxySprite:getOrientation()
  return self.flip
end

--------------------------------------------------------------------------------
-- Animation Definition
--------------------------------------------------------------------------------

-- ! Add Animation
-- Accepts either an options table or legacy (name, opts) arguments
function RoxySprite:addAnimation(optsOrName, legacyOpts)
  local animationOpts

  if type(optsOrName) == "table" then
    animationOpts = optsOrName
  elseif type(optsOrName) == "string" then
    local providedOpts = (type(legacyOpts) == "table") and legacyOpts or nil

    if providedOpts then
      animationOpts = {}
      for key, value in pairs(providedOpts) do
        animationOpts[key] = value
      end
    else
      animationOpts = {}
    end

    animationOpts.name = optsOrName
  end

  local hasValidName = type(animationOpts) == "table"
    and type(animationOpts.name) == "string"
    and animationOpts.name ~= ""
  if not hasValidName then
    error("[RoxySprite:addAnimation] Animation name must be a non-empty string", 2)
  end

  if self.animation then
    self.animation:addAnimation(animationOpts)
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
    error("[RoxySprite:setAnimation] Animation name must be a non-empty string", 2)
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

-- ! Play With Delay
function RoxySprite:playWithDelay(delay, animationName)
  if not (type(delay) == "number" and delay > 0) then
    Log.warn("[RoxySprite:playWithDelay] Delay must be a positive number") --#DEBUG
    delay = DELAY_DEFAULT
  end

  if self.animation or self.simpleAnimation then
    performAfterDelay(delay * MS_PER_SECOND, function()
      -- Skip delayed resume if the sprite was destroyed
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
    self:setUpdatesEnabled(_hasParallax(self)) -- Parallax placement still needs updates
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
    self:setUpdatesEnabled(_hasParallax(self))
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
  if type(speed) ~= "number" then
    error("[RoxySprite:setSpeed] Speed must be a number", 2)
  end

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
  if self.simpleAnimation then
    return self.simpleAnimation.frameDuration
  end
  return nil
end

-- ! Set Frame Duration
function RoxySprite:setFrameDuration(frameDuration, currentOnly)
  if type(frameDuration) ~= "number" or frameDuration <= 0 then
    error("[RoxySprite:setFrameDuration] Frame duration must be a positive number", 2)
  end

  if self.animation then
    self.animation:setFrameDuration(frameDuration, currentOnly)
  elseif self.simpleAnimation then
    self.simpleAnimation.frameDuration = clamp(frameDuration, MIN_FRAME_DURATION, MAX_FRAME_DURATION)
  --#DEBUG START
  else
    Log.warn("[RoxySprite:setFrameDuration] Sprite has no animation system")
  --#DEBUG END
  end

  return self
end

-- ! Get Frame Rate
function RoxySprite:getFrameRate()
  local frameDuration = self:getFrameDuration()
  if not frameDuration or frameDuration <= 0 then return nil end
  return 1 / frameDuration
end

-- ! Set Frame Rate
function RoxySprite:setFrameRate(frameRate, currentOnly)
  local frameDuration = _resolveSimpleFrameRateSetter(frameRate)
  return self:setFrameDuration(frameDuration, currentOnly)
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
-- Rendering
--------------------------------------------------------------------------------

-- ! Update
function RoxySprite:update()
  if self._destroyed then return end

  local hasParallax = _hasParallax(self)
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
    local shakeX, shakeY = getShakeOffset()

    local spriteX = floor(parallaxOriginX + (worldX - cameraX) * parallaxX - shakeX + 0.5)
    local spriteY = floor(parallaxOriginY + (worldY - cameraY) * parallaxY - shakeY + 0.5)
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

    -- Handle large delta times
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
    self.animation:update(dt)
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
-- Re-adds the sprite and restores state needed by pooled scene reuse
function RoxySprite:add()
  RoxySprite.super.add(self)
  self._added = true
  if self._restoreCollisionsOnAdd and self._collisionsEnabled ~= false then
    _setCollisionsActive(self, true)
  end
  self._restoreCollisionsOnAdd = false
  if _hasParallax(self) then
    self:setIgnoresDrawOffset(true)
    self:setUpdatesEnabled(true)
  elseif (self.animation or self.simpleAnimation) and not self.isPaused then
    self:setUpdatesEnabled(true)
  end
  return self
end

-- ! Remove Sprite
-- Removes the sprite while remembering state that should resume on add()
function RoxySprite:remove()
  if self.isRoxySprite and (self.animation or self.simpleAnimation) then
    self:stop()
  end

  -- Pause and disable sprite systems
  if self.isRoxySprite then self:pause() end
  self._restoreCollisionsOnAdd = self._collisionsEnabled ~= false
  self:setUpdatesEnabled(false)
  _setCollisionsActive(self, false)

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

-- ! Remove and Clear View
-- Fully releases sprite-owned view resources during scene cleanup
function RoxySprite:removeAndClearView()
  self:remove()
  self:clearView()
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
  local centerX = self._centerX or 0.5
  local centerY = self._centerY or 0.5

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
  self:clearView()
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[
RoxySprite wraps Playdate sprites with image, animation, parallax, and scene ownership helpers.

local player = RoxySprite({
  name = "PlayerSprite",
  view = "images/player-idle",
}, scene)

player:moveTo(100, 100)
player:setZIndex(10)
player:setCenter(0.5, 1.0)
player:setCollisionsEnabled(false)
player:setPauseClassification(nil) -- Default dynamic scene pause behavior

local enemy = RoxySprite({
  name = "Enemy",
  view = "images/enemy-walk",
  isSheet = true,
}, scene)

enemy:addAnimation({
  name = "walk",
  startFrame = 1,
  endFrame = 4,
  loop = true,
  frameRate = 10,
})
enemy:addAnimation({
  name = "attack",
  startFrame = 5,
  endFrame = 7,
  next = "walk",
  frameRate = "display",
})
enemy:setAnimation("walk"):play()
enemy:setSpeed(1.5)
enemy:setFrameRate(12) -- Applies to all full-animation clips
enemy:drawSpecificFrame(1, true)
enemy:stepFrame(1)

local coin = RoxySprite({
  name = "Coin",
  view = "images/coin-spin",
  isSheet = true,
  singleAnimation = true,
  singleAnimationLoop = true,
  frameRate = "display",
}, scene)
-- Omit frameRate/frameDuration for the 30 FPS simple-animation default
coin:play()
coin:setFrameRate(15)

local mountains = RoxySprite({
  name = "Mountains",
  view = "images/mountains",
  worldX = 400,
  worldY = 240,
  parallaxX = 0.3,
  parallaxY = 0.1,
  parallaxOriginX = 200,
  parallaxOriginY = 120,
}, scene)
mountains:setWorldPosition(420, 240)
mountains:setParallax(0.25, 0.1)
mountains:setParallaxOrigin(200, 120)
roxy.Camera.shake(6, 0.35, 18) -- Parallax sprites include committed camera shake automatically

-- After registering an image pool with Assets.registerPool
local pooledItem = RoxySprite({
  name = "PooledItem",
  view = { poolKey = "item_image_pool", kind = "image" },
}, scene)

local looseSprite = RoxySprite({ name = "LooseSprite", view = "images/item" })
scene:addSprite(looseSprite)
local screenX, screenY = looseSprite:getScreenPosition()
local onScreen = looseSprite:isOnScreen()

looseSprite:flipX()
pooledItem:clearView()
looseSprite:removeAndClearView()
enemy:destroy()
--]]
