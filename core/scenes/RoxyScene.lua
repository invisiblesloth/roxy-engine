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

local redrawBackground    <const> = Sprite.redrawBackground

local addHandler    <const> = r.Input.addHandler
local removeHandler <const> = r.Input.removeHandler

local resetCamera <const> = Camera.reset

local COLOR_WHITE <const> = Graphics.kColorWhite
local COLOR_BLACK <const> = Graphics.kColorBlack
local CLEAR_COLOR <const> = COLOR_WHITE

local _colorCallbacks = {} -- Cache: color --> fn

--------------------------------------------------------------------------------
-- Helper
--------------------------------------------------------------------------------

-- ! Helper: Get Color Callback
-- builds (and returns) a drawing callback for a solid color
local function _getColorCallback(color)
  local fn = _colorCallbacks[color]
  if fn == nil then
    fn = function(x, y, width, height)
      setColor(color)
      fillRect(x, y, width, height) -- Draw only the dirty rect
    end
    _colorCallbacks[color] = fn
  end
  return fn
end

--------------------------------------------------------------------------------
-- Class Definition & Init
--------------------------------------------------------------------------------

class("RoxyScene").extends(Object)

--! Initialize
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

  self.backgroundColor = nil
  self.backgroundImage = nil
  self.backgroundDrawFn = function(x, y, width, height) end

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
end

-- ! Update
function RoxyScene:update()
  -- noop by default
end

-- ! Pause
function RoxyScene:pause()
  if self.isPaused then return end
  Log.debug("[RoxyScene:pause] Pausing Scene: " .. self.name) --#DEBUG
  self.isPaused = true

  -- Disable sprites from updating or colliding
  for i = #self.sprites, 1, -1 do
    local sprite = self.sprites[i]
    sprite:pause()
    sprite:setUpdatesEnabled(false)
    sprite:setCollisionsEnabled(false)
  end

  removeHandler(self)
end

-- ! Resume
function RoxyScene:resume()
  if not self.isPaused then return end
  Log.debug("[RoxyScene:resume] Resuming Scene: " .. self.name) --#DEBUG
  self.isPaused = false

  -- Enable sprites for updating and colliding
  for i = #self.sprites, 1, -1 do
    local sprite = self.sprites[i]
    sprite:setUpdatesEnabled(true)
    sprite:setCollisionsEnabled(true)
    sprite:play()
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

  for i = #self.sprites, 1, -1 do
    local sprite = self.sprites[i]
    if sprite.isRoxySprite then sprite:pause() end
    sprite:setUpdatesEnabled(false)
    sprite:setCollisionsEnabled(false)
  end

  self:removeAllSprites()
  self:removeAllTilemaps()

  self:resetDrawOffset()

  resetCamera()

  self.backgroundColor = nil
  self.backgroundImage = nil
  self.backgroundDrawFn = nil
  self.frozenBackground = nil -- Clean up screenshot from transitions
end

-- TODO: Add sprite management methods etc. HERE

--------------------------------------------------------------------------------
-- Background Drawing
--------------------------------------------------------------------------------

-- ! Set Background
function RoxyScene:setBackground(background)
  -- Solid color
  if background == nil or type(background) == "number" then
    local color = background or CLEAR_COLOR
    Log.debug("[RoxyScene:setBackground] Setting background color to " .. color)
    setBackgroundColor(color)
    self.backgroundColor = color
    self.backgroundImage = nil
    self.backgroundDrawFn = _getColorCallback(color)
    redrawBackground()
    return
  end

  -- Background image
  if type(background) == "userdata" then
    Log.debug("[RoxyScene:setBackground] Setting background image")
    local img = background
    self.backgroundColor = nil
    self.backgroundImage = img
    self.backgroundDrawFn = function(x, y, width, height)
      img:draw(x, y, nil, x, y, width, height)
    end
    redrawBackground()
    return
  end

  Log.debug("[RoxyScene:setBackground] Falling back to background color: " .. CLEAR_COLOR)
  -- Fallback
  setBackgroundColor(CLEAR_COLOR)
  self.backgroundColor = CLEAR_COLOR
  self.backgroundImage = nil
  self.backgroundDrawFn = _getColorCallback(CLEAR_COLOR)
  redrawBackground()
end

--------------------------------------------------------------------------------
-- Sprites
--------------------------------------------------------------------------------

-- ! Add Sprite
function RoxyScene:addSprite(sprite)
  if not sprite then return end

  -- Give the sprite a back‑pointer so it can self‑remove later
  sprite.scene = self

  for i = 1, #self.sprites do
    if self.sprites[i] == sprite then
      return
    end
  end

  tableInsert(self.sprites, sprite)
  sprite:add()
end

-- ! Remove Sprite
function RoxyScene:removeSprite(sprite)
  if not sprite then return end

  for i = #self.sprites, 1, -1 do
    if self.sprites[i] == sprite then
      sprite.scene = nil -- Clear back‑pointer
      sprite:remove()
      tableRemove(self.sprites, i)
      return
    end
  end
end

-- ! Remove All Sprites
function RoxyScene:removeAllSprites()
  for i = #self.sprites, 1, -1 do
    self.sprites[i]:remove()
  end
  self.sprites = {}
end

-- ! Spawn Sprite
function RoxyScene:spawnSprite(spriteOpts)
  spriteOpts = spriteOpts or {}
  spriteOpts.scene = self
  return RoxySprite(spriteOpts)
end

--------------------------------------------------------------------------------
-- Tilemaps
--------------------------------------------------------------------------------

-- ! Add Tilemap
function RoxyScene:addTilemap(tilemap)
  if not tilemap then return end

  for i = 1, #self.tilemaps do
    if self.tilemaps[i] == tilemap then
      return
    end
  end

  tableInsert(self.tilemaps, tilemap)

  -- Give the tilemap a back‑pointer so it can self‑remove later
  tilemap.scene = self
end

-- ! Remove Tilemap
function RoxyScene:removeTilemap(tilemap)
  if not tilemap then return end
  for i = #self.tilemaps, 1, -1 do
    if self.tilemaps[i] == tilemap then
      tilemap.scene = nil -- Clear back‑pointer
      tilemap:destroy()
      tableRemove(self.tilemaps, i)
      return
    end
  end
end

-- ! Remove All Tilemaps
function RoxyScene:removeAllTilemaps()
  for i = #self.tilemaps, 1, -1 do
    self.tilemaps[i]:destroy() -- <-- Call destroy on each!
  end
  self.tilemaps = {}
end

-- ! Spawn Tilemap
function RoxyScene:spawnTilemap(path, tilemapOpts)
  local tilemap = RoxyTilemap(path, tilemapOpts, self)
  self:addTilemap(tilemap)
  return tilemap
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

-- ! Set Input Handler
function RoxyScene:addHandler()
  if self.inputHandler and (type(self.inputHandler) == "table" or type(self.inputHandler) == "function") then
    addHandler(self, self.inputHandler, 0)
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
