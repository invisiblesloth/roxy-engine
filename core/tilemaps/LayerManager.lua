-- core/tilemaps/LayerManager.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r           <const> = roxy
local AssetStore  <const> = r.AssetStore
local Camera      <const> = r.Camera
local Scene       <const> = r.Scene

local tableInsert <const> = table.insert
local tableRemove <const> = table.remove

local round <const> = r.Math.round

local newSprite      <const> = Sprite.new
local retain         <const> = AssetStore.retain
local release        <const> = AssetStore.release
local getTable       <const> = AssetStore.getImagetable
local getShakeOffset <const> = Camera.getShakeOffset

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Create Parallax Update
-- Parallax updater with stable factors and a mutable origin holder
local function _createParallaxUpdate(origin, parallaxX, parallaxY, pivotAdjustX, pivotAdjustY)
  return function(sprite)
    local cameraX, cameraY = Camera.getPosition()
    local shakeX, shakeY = getShakeOffset()

    local screenX = round(origin.x + pivotAdjustX - cameraX * parallaxX - shakeX)
    local screenY = round(origin.y + pivotAdjustY - cameraY * parallaxY - shakeY)

    local currentX, currentY = sprite:getPosition()
    if screenX ~= currentX or screenY ~= currentY then
      sprite:moveTo(screenX, screenY)
    end
  end
end

-- ! Helper: Configure Managed Parallax Sprite
local function _configureManagedParallaxSprite(layer, sprite, parallaxX, parallaxY)
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)
  local origin = layer._managedParallaxOrigin or {}
  origin.x, origin.y = layer.originX or 0, layer.originY or 0

  sprite:setIgnoresDrawOffset(true)
  sprite:setUpdatesEnabled(true)
  sprite.update = _createParallaxUpdate(origin, parallaxX, parallaxY, pivotAdjustX, pivotAdjustY)
  layer._managedParallaxOrigin = origin
  layer._managedParallaxSprite = sprite
  sprite._roxyLayerManagedParallax = true
end

-- ! Helper: Clear Managed Parallax Sprite
local function _clearManagedParallaxSprite(layer)
  local sprite = layer._managedParallaxSprite
  if sprite and sprite == layer.sprite then
    sprite.update = nil
    sprite._roxyLayerManagedParallax = nil
  end
  layer._managedParallaxOrigin = nil
  layer._managedParallaxSprite = nil
end

-- ! Helper: Remove Sprites From Scene
-- Uses the scene batch unregister path when available; otherwise removes directly
local function _removeSpritesFromScene(scene, sprites)
  if not sprites or #sprites == 0 then
    return
  end

  if scene and scene._unregisterSprites then
    scene:_unregisterSprites(sprites, true)
  elseif scene and scene.removeSprite then
    for i = 1, #sprites do
      scene:removeSprite(sprites[i])
    end
  else
    for i = 1, #sprites do
      sprites[i]:remove()
    end
  end
end

-- ! Helper: Set Scene Pause Classification
local function _setScenePauseClassification(sprite, playback, updates, collisions)
  Scene.setSpritePauseClassification(sprite, {
    playback = playback,
    updates = updates,
    collisions = collisions,
  })
end

--------------------------------------------------------------------------------
-- ! Class Definition and Initialize
--------------------------------------------------------------------------------

class("LayerManager").extends(Object)

-- ! Initialize
function LayerManager:init(opts, scene, backingLayersTable, backingSpritesList)
  self._opts = opts or {}
  self.scene = scene
  self.layers = backingLayersTable or {}  -- Shares storage with owner (RoxyTilemap)
  self._spritesList = backingSpritesList or {} -- Optional external list to append into
  self._retainedPaths = {} -- Only paths retained by swaps (not tilesets)
  self._autoAdd = (self._opts.wrapInSprites ~= false) and (self._opts.autoAddSprites ~= false)
  self._sceneHasAdd = scene and type(scene.addSprite) == "function" or false
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Set Scene
function LayerManager:setScene(scene)
  self.scene = scene
  self._sceneHasAdd = scene and type(scene.addSprite) == "function" or false
end

-- ! Add Layer
-- Register or replace layer data without creating a sprite yet
function LayerManager:addLayer(layerData)
  if layerData.visible == nil then
    layerData.visible = true
  end
  self.layers[layerData.name] = layerData
end

-- ! Ensure Sprite
-- Creates if needed and returns the sprite for a layer
-- @param name Layer name
-- @return Sprite instance, or nil if the layer is missing or wrapping is disabled
function LayerManager:ensureSprite(name)
  local layer = self.layers[name]
  if not layer then
    return nil
  end

  if self._opts.wrapInSprites == false then
    return layer.sprite
  end

  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local useParallax = (not layer.layerOptions) or (layer.layerOptions.parallax ~= false)
  local hasParallax = useParallax and (parallaxX ~= 1 or parallaxY ~= 1)

  if layer.sprite then
    -- Keep classification current before addSprite's same-owner fast path
    _setScenePauseClassification(layer.sprite, false, hasParallax, false)
    if self._autoAdd and self._sceneHasAdd then
      self.scene:addSprite(layer.sprite)
    end
    return layer.sprite
  end

  local sprite = newSprite()
  sprite:setTilemap(layer.tilemap)
  if (layer.anchor or self._opts.anchor) == "topLeft" then
    sprite:setCenter(0, 0)
  else
    sprite:setCenter(0.5, 0.5)
  end
  sprite:setZIndex(layer.zIndex or 0)
  -- Keep classification current before addSprite's same-owner fast path
  _setScenePauseClassification(sprite, false, hasParallax, false)

  if hasParallax then
    _configureManagedParallaxSprite(layer, sprite, parallaxX, parallaxY)
  else
    _clearManagedParallaxSprite(layer)
    sprite:moveTo(layer.originX or 0, layer.originY or 0)
  end

  if self._autoAdd and self._sceneHasAdd then
    self.scene:addSprite(sprite)
  end
  sprite:setVisible(layer.visible ~= false)

  tableInsert(self._spritesList, sprite)
  layer.sprite = sprite
  return sprite
end

-- ! Ensure Sprites for All
function LayerManager:ensureSpritesForAll()
  for name, _ in pairs(self.layers) do
    self:ensureSprite(name)
  end
end

--
-- Lookups
--

-- ! Get Tilemap
function LayerManager:getTilemap(name)
  return self.layers[name] and self.layers[name].tilemap or nil
end

-- ! Get Sprite
function LayerManager:getSprite(name)
  return self.layers[name] and self.layers[name].sprite or nil
end

-- ! Get All Sprites
function LayerManager:getAllSprites()
  return self._spritesList
end

--
-- Visibility
--

-- ! Hide
-- @param name Layer name
-- @return Boolean true if the layer exists
function LayerManager:hide(name)
  local layer = self.layers[name]
  if not layer then
    return false
  end

  layer.visible = false
  if layer.sprite then
    layer.sprite:setVisible(false)
  end
  return true
end

-- ! Show
-- @param name Layer name
-- @return Boolean true if the layer exists
function LayerManager:show(name)
  local layer = self.layers[name]
  if not layer then
    return false
  end

  layer.visible = true
  local sprite = self:ensureSprite(name)
  if sprite then
    sprite:setVisible(true)
  end
  return true
end

-- ! Remove
-- Remove layer + sprites + collision sprites + retained paths from swaps
-- @param name Layer name
-- @return Boolean true if the layer existed and was removed
function LayerManager:remove(name)
  local layer = self.layers[name]
  if not layer then
    return false
  end

  if layer.sprite then
    local sprite = layer.sprite
    _removeSpritesFromScene(self.scene, { sprite })
    -- Remove from external list if present
    for i = #self._spritesList, 1, -1 do
      if self._spritesList[i] == sprite then
        tableRemove(self._spritesList, i)
        break
      end
    end
    _clearManagedParallaxSprite(layer)
    layer.sprite = nil
  else
    _clearManagedParallaxSprite(layer)
  end

  if layer.collisionSprites then
    _removeSpritesFromScene(self.scene, layer.collisionSprites)
    layer.collisionSprites = nil
  end

  if layer.imagePath and self._retainedPaths[layer.imagePath] then
    release(layer.imagePath)
    self._retainedPaths[layer.imagePath] = nil
  end

  layer.tilemap, layer.imageTable, layer._imageCache, layer._offsetCache = nil, nil, nil, nil
  self.layers[name] = nil
  return true
end

-- ! Set Image Table
-- Runtime image table swap with index remap and proper retention accounting
-- @param name Layer name
-- @param newImageTableOrPath Imagetable instance or image-table path
-- @param remapFn Optional remap function or lookup table for tile indices
-- @return Boolean true when the image table was applied
function LayerManager:setImageTable(name, newImageTableOrPath, remapFn)
  local layer = self.layers[name]
  if not layer or not layer.tilemap then
    return false
  end

  local newPath, newTable
  if type(newImageTableOrPath) == "string" then
    -- Normalize like RoxyTilemap expects ("assets/images/<base>")
    local filename = newImageTableOrPath:match("([^/]+)$") or ""
    local base = filename:gsub("%-table%-%d+%-%d+%.png$", "")
    newPath = "assets/images/" .. base
    newTable = getTable(newPath)
    if not newTable then
      return false
    end
  else
    newTable = newImageTableOrPath
    if not newTable then
      return false
    end
  end

  if remapFn then
    local tiles, width
    if layer.tilemap.getTiles then
      tiles, width = layer.tilemap:getTiles()
    end
    if not tiles then
      tiles = layer.tilesFlat
      width = layer.tilesStride or layer.mapWidth
    end
    if tiles and width then
      if type(remapFn) == "function" then
        for index = 1, #tiles do
          local tileIndex = tiles[index]
          if tileIndex ~= 0 then
            local mappedIndex = remapFn(tileIndex)
            if mappedIndex ~= nil then
              tiles[index] = mappedIndex
            end
          end
        end

      elseif type(remapFn) == "table" then
        for index = 1, #tiles do
          local tileIndex = tiles[index]
          if tileIndex ~= 0 then
            local mappedIndex = remapFn[tileIndex]
            if mappedIndex ~= nil then
              tiles[index] = mappedIndex
            end
          end
        end
      end

      layer.tilemap:setTiles(tiles, width)
      layer.tilesFlat = tiles
      layer.tilesStride = width
    end
  end

  layer.tilemap:setImageTable(newTable)
  layer.imageTable, layer._imageCache, layer._offsetCache = newTable, {}, {}

  -- Recompute image metadata
  local maxHeight, count = 0, newTable and newTable:getLength() or 0
  for i = 1, count do
    local img = newTable:getImage(i)
    if img then
      local _, height = img:getSize()
      if height and height > maxHeight then
        maxHeight = height
      end
    end
  end
  layer.maxImageHeight, layer.imageCount = maxHeight, count

  -- Update retention for swap paths only
  if newPath then
    if not self._retainedPaths[newPath] then
      if retain(newPath, newTable) then
        self._retainedPaths[newPath] = true
      else --#DEBUG
        Log.warn("[LayerManager:setImageTable] Failed to retain image table: " .. tostring(newPath)) --#DEBUG
      end
    end
    local oldPath = layer.imagePath
    if oldPath and oldPath ~= newPath and self._retainedPaths[oldPath] then
      release(oldPath)
      self._retainedPaths[oldPath] = nil
    end
    layer.imagePath = newPath
  end

  -- Mark layer rect dirty
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()
  local mapPixelWidth, mapPixelHeight = mapWidthTiles * tileWidth, mapHeightTiles * tileHeight

  local cameraX, cameraY = Camera.getPosition()
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local originX, originY = layer.originX or 0, layer.originY or 0

  local anchorOffsetX = (layer.anchor == "topLeft") and 0 or 0.5
  local anchorOffsetY = (layer.anchor == "topLeft") and 0 or 0.5

  local screenX = round(originX - mapPixelWidth * anchorOffsetX - cameraX * parallaxX)
  local screenY = round(originY - mapPixelHeight * anchorOffsetY - cameraY * parallaxY)

  Sprite.addDirtyRect(screenX, screenY, mapPixelWidth, mapPixelHeight)

  return true
end

-- ! Set Origin
-- Keep origin/sprite in sync (parallax-aware)
-- @param name Layer name
-- @param x New origin x, defaults to 0
-- @param y New origin y, defaults to 0
-- @return Boolean true if the layer exists
function LayerManager:setOrigin(name, x, y)
  local layer = self.layers[name]
  if not layer then
    return false
  end

  x, y = x or 0, y or 0
  local sprite = layer.sprite
  if layer._managedParallaxSprite and layer._managedParallaxSprite ~= sprite then
    _clearManagedParallaxSprite(layer)
  end

  if layer.originX == x and layer.originY == y then
    return true
  end

  layer.originX, layer.originY = x, y
  if sprite then
    if layer._managedParallaxSprite == sprite then
      local origin = layer._managedParallaxOrigin
      if origin then
        origin.x, origin.y = layer.originX, layer.originY
      end
    else
      sprite:moveTo(layer.originX, layer.originY)
    end
  end
  return true
end

-- ! Set Origin for All
function LayerManager:setOriginForAll(x, y)
  for name, _ in pairs(self.layers) do
    self:setOrigin(name, x, y)
  end
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- ! Detach
-- Remove layer and collision sprites without releasing retained swap paths
function LayerManager:detach()
  -- Collect layer sprites so the scene can unregister them in one batch
  local layerSprites = nil

  for _, layer in pairs(self.layers) do
    if layer.sprite then
      layerSprites = layerSprites or {}
      tableInsert(layerSprites, layer.sprite)
    end
  end

  _removeSpritesFromScene(self.scene, layerSprites)
end

-- ! Destroy
-- Cleanly remove all layer sprites, collisions, and swap-retained paths
function LayerManager:destroy()
  -- Collect layer sprites so the scene can unregister them in one batch
  local layerSprites = nil
  local collisionSprites = nil

  for _, layer in pairs(self.layers) do
    if layer.sprite then
      layerSprites = layerSprites or {}
      tableInsert(layerSprites, layer.sprite)
      _clearManagedParallaxSprite(layer)
      layer.sprite = nil
    else
      _clearManagedParallaxSprite(layer)
    end
    if layer.collisionSprites then
      for _, collisionSprite in ipairs(layer.collisionSprites) do
        collisionSprites = collisionSprites or {}
        tableInsert(collisionSprites, collisionSprite)
      end
      layer.collisionSprites = nil
    end
    layer.tilemap, layer.imageTable, layer._imageCache, layer._offsetCache = nil, nil, nil, nil
  end
  _removeSpritesFromScene(self.scene, layerSprites)
  _removeSpritesFromScene(self.scene, collisionSprites)
  for path, _ in pairs(self._retainedPaths) do
    release(path)
  end
  self._retainedPaths = {}
  self._spritesList = {}
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

LayerManager owns tile layer sprites for RoxyTilemap. Most callers use it through
RoxyTilemap, but direct usage is useful for advanced tilemap tooling.

local Graphics <const> = playdate.graphics

local scene = RoxyScene()
local layers = {}
local sprites = {}

local manager = LayerManager({
  wrapInSprites = true,
  autoAddSprites = true,
  anchor = "topLeft",
}, scene, layers, sprites)

-- Register Static and Parallax Layers
local imageTable = Graphics.imagetable.new("images/terrain")
local groundTilemap = Graphics.tilemap.new()
groundTilemap:setImageTable(imageTable)
groundTilemap:setTiles({
  1, 1, 0,
  2, 2, 1,
}, 3)

manager:addLayer({
  name = "Ground",
  tilemap = groundTilemap,
  imageTable = imageTable,
  tileWidth = 16,
  tileHeight = 16,
  originX = 0,
  originY = 0,
  zIndex = 0,
  visible = true,
  anchor = "topLeft",
})

local cloudsTilemap = Graphics.tilemap.new()
cloudsTilemap:setImageTable(imageTable)
cloudsTilemap:setTiles({
  0, 1, 0,
  1, 0, 1,
}, 3)

manager:addLayer({
  name = "Clouds",
  tilemap = cloudsTilemap,
  imageTable = imageTable,
  tileWidth = 16,
  tileHeight = 16,
  originX = 0,
  originY = 0,
  zIndex = 20,
  visible = true,
  anchor = "topLeft",
  parallaxx = 0.5,
  parallaxy = 0.75,
  parallaxoriginx = 200,
  parallaxoriginy = 120,
})

-- Sprite Lifecycle and Visibility
manager:ensureSpritesForAll()
local groundSprite = manager:getSprite("Ground")
local cloudsSprite = manager:getSprite("Clouds")

manager:hide("Ground")
manager:show("Ground")
manager:setOrigin("Ground", 32, 16)

roxy.Camera.setPosition(40, 16)
manager:setOrigin("Clouds", 12, 8) -- Applied on the next parallax sprite update
roxy.Camera.shake(6, 0.35, 18) -- Managed parallax sprites include committed camera shake automatically

-- Runtime Image Table Swap
local winterTiles = Graphics.imagetable.new("images/terrain-winter")
manager:setImageTable("Ground", winterTiles, {
  [1] = 2,
  [2] = 1,
})

-- Cleanup
manager:detach()
manager:remove("Clouds")
manager:destroy()

--]]
