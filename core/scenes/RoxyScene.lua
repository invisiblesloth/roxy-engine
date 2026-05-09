-- core/scenes/RoxyScene.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
local Input   <const> = r.Input
local Camera  <const> = r.Camera

local tableInsert <const> = table.insert
local tableRemove <const> = table.remove

local clearScreen         <const> = Graphics.clear
local setColor            <const> = Graphics.setColor
local setDrawOffset       <const> = Graphics.setDrawOffset
local setBackgroundColor  <const> = Graphics.setBackgroundColor
local fillRect            <const> = Graphics.fillRect
local setClipRect         <const> = Graphics.setClipRect
local clearClipRect       <const> = Graphics.clearClipRect

local redrawBackground <const> = Sprite.redrawBackground

local addHandler    <const> = Input.addHandler
local pauseHandler  <const> = Input.pause
local resumeHandler <const> = Input.resume
local removeHandler <const> = Input.removeHandler

local resetCamera           <const> = Camera.reset
local setCameraBounds       <const> = Camera.setBounds
local clearCameraBounds     <const> = Camera.clearBounds
local setCameraPosition     <const> = Camera.setPosition
local setCameraTarget       <const> = Camera.setTarget
local setCameraSmoothing    <const> = Camera.setSmoothing
local setCameraPanVelocity  <const> = Camera.setPanVelocity
local setCameraDeadZone     <const> = Camera.setDeadZone
local setCameraFriction     <const> = Camera.setFriction
local setCameraBias         <const> = Camera.setBias
local setCameraMode         <const> = Camera.setMode

local COLOR_WHITE <const> = Graphics.kColorWhite
local COLOR_BLACK <const> = Graphics.kColorBlack
local CLEAR_COLOR <const> = COLOR_WHITE

local UNFLIPPED <const> = Graphics.kImageUnflipped

local NO_OP_BG_DRAW <const> = function(x, y, width, height) end

local _colorCallbacks = {} -- Cache: color --> fn
local _imageCallbacks = setmetatable({}, { __mode = "k" }) -- Cache: image --> fn, weak keys

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Remove Item From Array
-- Removes every matching item and returns whether the array changed
local function _removeItem(array, item)
  if not array or not item then return false end

  local removed = false
  for i = #array, 1, -1 do
    if array[i] == item then
      tableRemove(array, i)
      removed = true
    end
  end
  return removed
end

-- ! Helper: Has Item In Array
-- Returns true when the array contains the given item
local function _hasItem(array, item)
  if not array or not item then return false end

  for i = 1, #array do
    if array[i] == item then return true end
  end
  return false
end

-- ! Helper: Is Bounds Table
-- Returns true for camera bounds tables accepted by Camera.setBounds
local function _isBoundsTable(bounds)
  return type(bounds) == "table"
     and type(bounds.x1) == "number"
     and type(bounds.y1) == "number"
     and type(bounds.x2) == "number"
     and type(bounds.y2) == "number"
end

-- ! Helper: Read XY Pair
-- Reads either { x, y } or array-style { x, y } option pairs
local function _readXYPair(value)
  if type(value) ~= "table" then return nil, nil end
  return value.x or value[1], value.y or value[2]
end

-- ! Helper: Get Color Callback
-- Builds (and returns) a drawing callback for a solid color
local function _getColorCallback(color)
  local fn = _colorCallbacks[color]
  if fn == nil then
    fn = function(x, y, width, height)
      -- Draw only the dirty rect
      setColor(color)
      fillRect(x, y, width, height)
    end
    _colorCallbacks[color] = fn
  end
  return fn
end

-- ! Helper: Get Image Callback
-- Helper for static image. Draws only the dirty rect via clipping.
local function _getImageCallback(img)
  local fn = _imageCallbacks[img]
  if fn == nil then
    fn = function(x, y, width, height)
      -- Set a clip to the dirty rect, then draw the full image once
      setClipRect(x, y, width, height)  -- Only redraw the dirty rect
      img:draw(0, 0, UNFLIPPED)         -- Avoid per-call src rect; let clip do the work
      clearClipRect()                   -- Restore clip
    end
    _imageCallbacks[img] = fn
  end
  return fn
end

--------------------------------------------------------------------------------
-- ! Class Definition and Initialize
--------------------------------------------------------------------------------

class("RoxyScene").extends(Object)

-- ! Initialize
function RoxyScene:init(background)
  self.name = self.className or "RoxyScene"
  Log.debug("[RoxyScene:init] Initializing Scene: " .. self.name) --#DEBUG

  self.isPaused = false
  self._didEnter = false
  self._didStart = false
  self._didExit = false
  self._didCleanup = false

  self.inputHandler = {}
  self.sprites = {}
  self.tilemaps = {}
  self.sequences = {}

  self._spriteAutoAddQueue = {}
  self._sequenceAutoStartQueue = {}

  -- Sensible defaults used by Scene draw filtering
  self.isVisible = true
  self.blocksLowerDraw = false

  self.backgroundColor = nil
  self.backgroundImage = nil
  self.backgroundDrawFn = NO_OP_BG_DRAW -- Use shared no-op (avoid per-instance closure)

  self:setBackground(background)
end

--------------------------------------------------------------------------------
-- Scene Lifecycle
--------------------------------------------------------------------------------

-- ! Enter
function RoxyScene:enter()
  if self._didEnter then return end
  Log.debug("[RoxyScene:enter] Entering Scene: " .. self.name) --#DEBUG
  self._didEnter = true

  -- Flush any queued sprite auto-adds
  local spriteQueue = self._spriteAutoAddQueue
  for i = 1, #spriteQueue do
    spriteQueue[i]:add()
  end
  self._spriteAutoAddQueue = {}

  -- Activate tilemap resources that cannot be created detached from display
  for i = 1, #self.tilemaps do
    local tilemap = self.tilemaps[i]
    if tilemap and tilemap.sceneDidEnter then
      tilemap:sceneDidEnter(self)
    end
  end

  -- Flush any queued sequence auto-starts
  local sequenceQueue = self._sequenceAutoStartQueue
  for i = 1, #sequenceQueue do
    sequenceQueue[i]:play()
  end
  self._sequenceAutoStartQueue = {}
end

-- ! Start
function RoxyScene:start()
  if self._didStart then return end
  Log.debug("[RoxyScene:start] Starting Scene: " .. self.name) --#DEBUG
  self._didStart = true

  self:addHandler()
end

-- ! Activate Camera
-- Opt-in scene camera setup. Scenes that do not use Camera pay no enter cost.
-- Supports tilemap bounds, raw bounds, or explicitly clearing bounds.
function RoxyScene:activateCamera(opts)
  opts = opts or {}

  --#DEBUG START
  if opts.cameraBounds ~= nil then
    error("[RoxyScene:activateCamera] Use tilemap = map for tilemap bounds or bounds = { x1, y1, x2, y2 } for raw bounds", 2)
  end
  if opts.map ~= nil then
    error("[RoxyScene:activateCamera] Use tilemap = map for tilemap bounds", 2)
  end
  --#DEBUG END

  if opts.reset ~= false then
    resetCamera()
  end

  if opts.mode then setCameraMode(opts.mode) end
  if opts.friction ~= nil then setCameraFriction(opts.friction) end
  if opts.smoothing ~= nil then setCameraSmoothing(opts.smoothing) end

  local deadZoneX, deadZoneY = _readXYPair(opts.deadZone)
  if deadZoneX and deadZoneY then setCameraDeadZone(deadZoneX, deadZoneY) end

  local biasX, biasY = _readXYPair(opts.bias)
  if biasX and biasY then setCameraBias(biasX, biasY) end

  local rawBounds = opts.bounds
  if opts.clearBounds or rawBounds == false then
    clearCameraBounds()
  elseif rawBounds ~= nil then
    if _isBoundsTable(rawBounds) then
      setCameraBounds(rawBounds)
    else --#DEBUG
      error("[RoxyScene:activateCamera] Expected bounds = { x1, y1, x2, y2 }; use tilemap = map for tilemap bounds", 2) --#DEBUG
    end
  elseif opts.tilemap ~= nil then
    local tilemap = opts.tilemap
    local didApply = false
    if type(tilemap) == "table" and type(tilemap.applyCameraBounds) == "function" then
      didApply = tilemap:applyCameraBounds() == true
    end
    if not didApply and type(tilemap) == "table" and type(tilemap.getCameraBounds) == "function" then
      local bounds = tilemap:getCameraBounds()
      if bounds then setCameraBounds(bounds) end
    end
  end

  local positionX, positionY = _readXYPair(opts.position)
  if positionX and positionY then
    setCameraPosition(positionX, positionY)
  elseif opts.x ~= nil and opts.y ~= nil then
    setCameraPosition(opts.x, opts.y)
  end

  if opts.target ~= nil then
    setCameraTarget(opts.target ~= false and opts.target or nil, opts.targetSmoothing or opts.smoothing)
  elseif opts.panVelocity then
    local velocityX, velocityY = _readXYPair(opts.panVelocity)
    setCameraPanVelocity(velocityX, velocityY)
  end

  return true
end

-- ! Update
function RoxyScene:update(dt)
  -- noop by default
end

-- ! Draw
function RoxyScene:draw(dt)
  -- noop by default
end

-- ! Pause
function RoxyScene:pause()
  if self.isPaused then return end
  Log.debug("[RoxyScene:pause] Pausing Scene: " .. self.name) --#DEBUG
  self.isPaused = true

  -- Disable sprites from updating or colliding
  local sprites = self.sprites
  for i = #sprites, 1, -1 do
    local sprite = sprites[i]
    sprite:pause()
    sprite:setUpdatesEnabled(false)
    sprite:setCollisionsEnabled(false)
  end

  -- Disable sequences from updating
  local sequences = self.sequences
  for i = #sequences, 1, -1 do
    local sequence = sequences[i]
    sequence:pause()
  end

  removeHandler(self)
end

-- ! Resume
function RoxyScene:resume()
  if not self.isPaused then return end
  Log.debug("[RoxyScene:resume] Resuming Scene: " .. self.name) --#DEBUG
  self.isPaused = false

  -- Enable sprites for updating and colliding
  local sprites = self.sprites
  for i = #sprites, 1, -1 do
    local sprite = sprites[i]
    sprite:setUpdatesEnabled(true)
    sprite:setCollisionsEnabled(true)
    sprite:play()
  end

  -- Enable sequences for updating
  local sequences = self.sequences
  for i = #sequences, 1, -1 do
    local sequence = sequences[i]
    sequence:play()
  end

  self:addHandler()
end

-- ! Exit
function RoxyScene:exit()
  if self._didExit then return end
  Log.debug("[RoxyScene:exit] Exiting Scene: " .. self.name) --#DEBUG
  self._didExit = true

  pauseHandler()
end

-- ! Cleanup
function RoxyScene:cleanup()
  if self._didCleanup then return end
  Log.debug("[RoxyScene:cleanup] Cleaning Up Scene: " .. self.name) --#DEBUG
  self._didCleanup = true

  resumeHandler(true)
  removeHandler(self)

  self:removeAllSprites()
  self:removeAllTilemaps()
  self:removeAllSequences()
  self:resetDrawOffset()

  resetCamera()

  self._spriteAutoAddQueue = {}
  self._sequenceAutoStartQueue = {}

  self.backgroundColor = nil
  self.backgroundImage = nil
  self.backgroundDrawFn = nil
  self.frozenBackground = nil -- Clean up screenshot from transitions
end

--------------------------------------------------------------------------------
-- Background Drawing
--------------------------------------------------------------------------------

-- ! Set Background
function RoxyScene:setBackground(background)
  -- Solid color
  if background == nil or type(background) == "number" then
    local color = background or CLEAR_COLOR
    local colorFn = _getColorCallback(color) -- Avoid double lookup/construction

    -- Early-out if unchanged color and no image
    if self.backgroundImage == nil and self.backgroundColor == color and self.backgroundDrawFn == colorFn then
      return
    end

    Log.debug("[RoxyScene:setBackground] Setting background color to " .. color) --#DEBUG
    setBackgroundColor(color)
    self.backgroundColor = color
    self.backgroundImage = nil
    self.backgroundDrawFn = colorFn
    redrawBackground()
    return
  end

  -- Background image
  if type(background) == "userdata" then
    local img = background
    -- Early-out if unchanged image
    if self.backgroundImage == img then
      return
    end

    Log.debug("[RoxyScene:setBackground] Setting background image") --#DEBUG
    self.backgroundColor = nil
    self.backgroundImage = img
    self.backgroundDrawFn = _getImageCallback(img)
    redrawBackground()
    return
  end

  -- Fallback
  Log.debug("[RoxyScene:setBackground] Falling back to background color: " .. CLEAR_COLOR) --#DEBUG
  local colorFn = _getColorCallback(CLEAR_COLOR) -- Avoid double lookup/construction
  setBackgroundColor(CLEAR_COLOR)
  self.backgroundColor = CLEAR_COLOR
  self.backgroundImage = nil
  self.backgroundDrawFn = colorFn
  redrawBackground()
end

--------------------------------------------------------------------------------
-- Sprites
--------------------------------------------------------------------------------

-- ! Add Sprite
function RoxyScene:addSprite(sprite)
  if not sprite then return end
  if sprite.scene == self then return end

  -- Avoid duplicates
  for i = 1, #self.sprites do
    if self.sprites[i] == sprite then return end
  end

  -- Give the sprite a back-pointer so it can self-remove later
  sprite.scene = self

  tableInsert(self.sprites, sprite)

  if self._didEnter then
    -- Scene is active -- attach immediately
    sprite:add()
  else
    -- Scene isn't active yet -- queue for enter()
    tableInsert(self._spriteAutoAddQueue, sprite)
  end
end

-- ! Remove Sprite
function RoxyScene:removeSprite(sprite)
  self:_unregisterSprite(sprite, true)
end

-- ! Unregister Sprite
-- Private cleanup path used by tilemaps and direct scene sprite removal
function RoxyScene:_unregisterSprite(sprite, removeFromDisplay)
  if not sprite then return end

  -- Remove from active scene list and pre-enter auto-add queue
  local wasManaged = _removeItem(self.sprites, sprite)
  wasManaged = _removeItem(self._spriteAutoAddQueue, sprite) or wasManaged
  wasManaged = (sprite.scene == self) or wasManaged

  if sprite.scene == self then
    sprite.scene = nil -- Clear back-pointer
  end

  if removeFromDisplay ~= false and wasManaged then
    sprite:remove()
  end
end

-- ! Unregister Sprites
-- Private batch cleanup path used by tilemap teardown.
-- Removes many scene-managed sprites without rescanning scene lists per sprite.
function RoxyScene:_unregisterSprites(sprites, removeFromDisplay)
  if not sprites then return end

  -- Build a lookup set so scene lists only need one pass each
  local targets = nil
  for i = 1, #sprites do
    local sprite = sprites[i]
    if sprite then
      targets = targets or {}
      targets[sprite] = true
    end
  end
  if not targets then return end

  local managed = {}

  -- Remove from active scene list
  local sceneSprites = self.sprites
  for i = #sceneSprites, 1, -1 do
    local sprite = sceneSprites[i]
    if targets[sprite] then
      tableRemove(sceneSprites, i)
      managed[sprite] = true
    end
  end

  -- Remove from pre-enter auto-add queue
  local spriteQueue = self._spriteAutoAddQueue
  for i = #spriteQueue, 1, -1 do
    local sprite = spriteQueue[i]
    if targets[sprite] then
      tableRemove(spriteQueue, i)
      managed[sprite] = true
    end
  end

  local shouldRemove = removeFromDisplay ~= false
  for sprite, _ in pairs(targets) do
    if sprite.scene == self then
      sprite.scene = nil -- Clear back-pointer
      managed[sprite] = true
    end

    if shouldRemove and managed[sprite] then
      sprite:remove()
    end
  end
end

-- ! Remove All Sprites
function RoxyScene:removeAllSprites()
  local sprites = self.sprites
  for i = #sprites, 1, -1 do
    local sprite = sprites[i]
    if sprite.scene == self then
      sprite.scene = nil -- Clear back-pointer
    end
    -- Prefer view-aware cleanup so pooled sprite assets are released
    if sprite.removeAndClearView then
      sprite:removeAndClearView()
    else
      sprite:remove()
    end
  end
  self.sprites = {}
  self._spriteAutoAddQueue = {}
end

-- ! Spawn Sprite
function RoxyScene:spawnSprite(spriteOpts)
  return RoxySprite(spriteOpts, self)
end

--------------------------------------------------------------------------------
-- Tilemaps
--------------------------------------------------------------------------------

-- ! Add Tilemap
-- Attaches a load-only tilemap to this scene
function RoxyScene:addTilemap(tilemap)
  if not tilemap then return false end

  for i = 1, #self.tilemaps do
    if self.tilemaps[i] == tilemap then return true end
  end

  if type(tilemap.attachToScene) ~= "function" then
    Log.warn("[RoxyScene:addTilemap] Expected tilemap with attachToScene") --#DEBUG
    return false
  end

  if not tilemap:attachToScene(self) then
    return false
  end

  tableInsert(self.tilemaps, tilemap)
  return true
end

-- ! Remove Tilemap
-- Destroys a tilemap and unregisters it from this scene
function RoxyScene:removeTilemap(tilemap)
  if not tilemap then return false end
  if tilemap.scene ~= self and not _hasItem(self.tilemaps, tilemap) then return false end

  if type(tilemap.destroy) ~= "function" then
    Log.warn("[RoxyScene:removeTilemap] Expected tilemap with destroy") --#DEBUG
    return false
  end

  tilemap:destroy()
  return true
end

-- ! Detach Tilemap
-- Detaches scene/display state while preserving pooled tilemap resources
function RoxyScene:detachTilemap(tilemap)
  if not tilemap then return false end
  if tilemap.scene ~= self and not _hasItem(self.tilemaps, tilemap) then return false end

  if type(tilemap.detachFromScene) ~= "function" then
    Log.warn("[RoxyScene:detachTilemap] Expected tilemap with detachFromScene") --#DEBUG
    return false
  end

  return tilemap:detachFromScene()
end

-- ! Unregister Tilemap
-- Removes a tilemap from scene ownership without destroying it
function RoxyScene:_unregisterTilemap(tilemap)
  if not tilemap then return end

  _removeItem(self.tilemaps, tilemap)

  if tilemap.scene == self then
    tilemap.scene = nil
  end

  local layerManager = tilemap.layerManager
  if layerManager and layerManager.scene == self and layerManager.setScene then
    layerManager:setScene(nil)
  end
end

-- ! Remove All Tilemaps
function RoxyScene:removeAllTilemaps()
  local tilemaps = self.tilemaps
  self.tilemaps = {}

  for i = #tilemaps, 1, -1 do
    local tilemap = tilemaps[i]
    if type(tilemap.destroy) == "function" then
      tilemap:destroy()
    end
  end
end

-- ! Spawn Tilemap
-- Convenience helper that creates and attaches an orthogonal tilemap
function RoxyScene:spawnTilemap(path, tilemapOpts)
  local tilemap = RoxyOrthoTilemap(path, tilemapOpts)
  self:addTilemap(tilemap)
  return tilemap
end

--------------------------------------------------------------------------------
-- Sequences
--------------------------------------------------------------------------------

-- ! Add Sequence
function RoxyScene:addSequence(sequence)
  if not sequence then return end
  if sequence.scene == self then return end

  for i = 1, #self.sequences do
    if self.sequences[i] == sequence then return end
  end

  tableInsert(self.sequences, sequence)

  -- Give the sequence a back-pointer so it can self-remove later
  sequence.scene = self

  if self._didEnter then
    -- Scene is active -- start now
    sequence:play()
  else
    -- Scene isn't active yet -- queue for enter()
    tableInsert(self._sequenceAutoStartQueue, sequence)
  end
end

-- ! Remove Sequence
function RoxyScene:removeSequence(sequence)
  if not sequence then return end
  for i = #self.sequences, 1, -1 do
    if self.sequences[i] == sequence then
      sequence.scene = nil -- Clear back-pointer
      sequence:clear(true)
      tableRemove(self.sequences, i)
      return
    end
  end
end

-- ! Remove All Sequences
function RoxyScene:removeAllSequences()
  local sequences = self.sequences
  for i = #sequences, 1, -1 do
    local sequence = sequences[i]
    sequence.scene = nil -- Clear back-pointer
    sequence:clear(true)
  end
  self.sequences = {}
end

-- ! Spawn Sequence
function RoxyScene:spawnSequence()
  return RoxySequence(self)
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

-- ! Set Input Handler
function RoxyScene:addHandler()
  local inputHandler = self.inputHandler
  if inputHandler and (type(inputHandler) == "table" or type(inputHandler) == "function") then
    addHandler(self, inputHandler, 0)
  end
end

-- ! Reset Draw Offset
function RoxyScene:resetDrawOffset()
  setDrawOffset(0, 0)
end

-- ! Clear Screen
function RoxyScene:clearScreen()
  clearScreen(CLEAR_COLOR)
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

local Graphics <const> = playdate.graphics

local COLOR_WHITE <const> = Graphics.kColorWhite
local COLOR_BLACK <const> = Graphics.kColorBlack

-- Basic Scene Subclass
class("GameplayScene").extends(RoxyScene)

function GameplayScene:init()
  GameplayScene.super.init(self, COLOR_WHITE)

  self.inputHandler = {
    BButtonDown = function()
      roxy.Scene.popScene()
    end,
  }
end

function GameplayScene:start()
  GameplayScene.super.start(self)

  self.player = RoxySprite({ name = "player" }, self)
  self.map = self:spawnTilemap("assets/maps/level-01.json", {
    cameraBounds = true,
    layerOptions = {
      Walls = { collidable = true },
    },
  })
  self:activateCamera({
    tilemap = self.map,
    target = self.player,
    smoothing = 0.2,
  })

  self.fadeIn = RoxySequence(self):from(0):to(1, 0.25):play()
end

function GameplayScene:update(dt)
  -- Game logic here
end

function GameplayScene:cleanup()
  GameplayScene.super.cleanup(self)
  self.player = nil
  self.map = nil
  self.fadeIn = nil
end

-- Backgrounds and Draw Stack Behavior
local pauseScene = RoxyScene(COLOR_BLACK)
pauseScene.isVisible = true
pauseScene.blocksLowerDraw = false
pauseScene.updateBackground = true

-- Manual Ownership Cleanup
local scene = RoxyScene()
local player = RoxySprite({ name = "player" }, scene)
local map = scene:spawnTilemap("assets/maps/level-01.json")

scene:removeSprite(player)
scene:detachTilemap(map)
scene:addTilemap(map)
scene:removeTilemap(map)
scene:cleanup()

]]
