-- core/scenes/RoxyScene.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
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

local addHandler    <const> = r.Input.addHandler
local removeHandler <const> = r.Input.removeHandler

local resetCamera <const> = Camera.reset

local COLOR_WHITE   <const> = Graphics.kColorWhite
local COLOR_BLACK   <const> = Graphics.kColorBlack
local CLEAR_COLOR   <const> = COLOR_WHITE

local UNFLIPPED     <const> = Graphics.kImageUnflipped

local NO_OP_BG_DRAW <const> = function(x, y, width, height) end

local _colorCallbacks = {} -- Cache: color --> fn
local _imageCallbacks = setmetatable({}, { __mode = "k" }) -- Cache: image --> fn, weak keys

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Get Color Callback
-- Builds (and returns) a drawing callback for a solid color.
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
      -- Set a clip to the dirty rect, then draw the full image once.
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

function RoxyScene:init(background)
  self.name = self.className or "RoxyScene"
  Log.debug("[RoxyScene:init] Initializing Scene: " .. self.name) --#DEBUG

  self.isPaused = false
  self._didEnter = false
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
  self._didEnter = true
  Log.debug("[RoxyScene:enter] Entering Scene: " .. self.name) --#DEBUG
  self:addHandler()

  -- Flush any queued sprite auto-adds
  local spriteQueue = self._spriteAutoAddQueue
  for i = 1, #spriteQueue do
    spriteQueue[i]:add()
  end
  self._spriteAutoAddQueue = {}

  -- Flush any queued sequence auto-starts
  local sequenceQueue = self._sequenceAutoStartQueue
  for i = 1, #sequenceQueue do
    sequenceQueue[i]:play()
  end
  self._sequenceAutoStartQueue = {}
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
  self._didExit = true

  Log.debug("[RoxyScene:exit] Exiting Scene: " .. self.name) --#DEBUG
end

-- ! Cleanup
function RoxyScene:cleanup()
  if self._didCleanup then return end
  self._didCleanup = true

  Log.debug("[RoxyScene:cleanup] Cleaning Up Scene: " .. self.name) --#DEBUG

  removeHandler(self)

  self:removeAllSprites()
  self:removeAllTilemaps()
  self:removeAllSequences()
  self:resetDrawOffset()

  resetCamera()

  self._spriteAutoAddQueue = {}
  self._sequenceAutoStartQueue = {}
  self._tilemapActivateQueue = {}

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
  if not sprite then return end

  for i = #self.sprites, 1, -1 do
    if self.sprites[i] == sprite then
      sprite.scene = nil -- Clear back-pointer
      sprite:remove()
      tableRemove(self.sprites, i)
      return
    end
  end
end

-- ! Remove All Sprites
function RoxyScene:removeAllSprites()
  local sprites = self.sprites
  for i = #sprites, 1, -1 do
    local sprite = sprites[i]
    sprite.scene = nil -- Clear back-pointer
    sprite:remove()
  end
  self.sprites = {}
end

-- ! Spawn Sprite
function RoxyScene:spawnSprite(spriteOpts)
  return RoxySprite(spriteOpts, self)
end

--------------------------------------------------------------------------------
-- Tilemaps
--------------------------------------------------------------------------------

-- ! Add Tilemap
function RoxyScene:addTilemap(tilemap)
  if not tilemap then return end

  for i = 1, #self.tilemaps do
    if self.tilemaps[i] == tilemap then return end
  end

  tableInsert(self.tilemaps, tilemap)

  -- Give the tilemap a back-pointer so it can self-remove later
  tilemap.scene = self
end

-- ! Remove Tilemap
function RoxyScene:removeTilemap(tilemap)
  if not tilemap then return end
  for i = #self.tilemaps, 1, -1 do
    if self.tilemaps[i] == tilemap then
      tilemap.scene = nil -- Clear back-pointer
      tilemap:destroy()
      tableRemove(self.tilemaps, i)
      return
    end
  end
end

-- ! Remove All Tilemaps
function RoxyScene:removeAllTilemaps()
  local tilemaps = self.tilemaps
  for i = #tilemaps, 1, -1 do
    local tilemap = tilemaps[i]
    tilemap.scene = nil -- Clear back-pointer
    tilemap:destroy()
  end
  self.tilemaps = {}
end

-- ! Spawn Tilemap
function RoxyScene:spawnTilemap(path, tilemapOpts)
  return RoxyOrthoTilemap(path, tilemapOpts, self)
end

--------------------------------------------------------------------------------
-- Sequences
--------------------------------------------------------------------------------

-- ! Add Sequence
function RoxyScene:addSequence(sequence)
  if not sequence then return end

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
