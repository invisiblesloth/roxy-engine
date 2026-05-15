-- core/tilemaps/LayerManager.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r           <const> = roxy
local AssetStore  <const> = r.AssetStore
local Camera      <const> = r.Camera

local round <const> = r.Math.round

local tableInsert <const> = table.insert
local tableRemove <const> = table.remove

local newSprite <const> = Sprite.new

local retain    <const> = AssetStore.retain
local release   <const> = AssetStore.release
local getTable  <const> = AssetStore.getImagetable

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Create Parallax Update
-- Parallax updater (same behavior as in RoxyTilemap)
local function _createParallaxUpdate(worldX, worldY, parallaxX, parallaxY, parallaxOriginX, parallaxOriginY)
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  return function(sprite)
    local cameraX, cameraY = Camera.getPosition()

    local screenX = round(worldX + pivotAdjustX - cameraX * parallaxX)
    local screenY = round(worldY + pivotAdjustY - cameraY * parallaxY)

    local currentX, currentY = sprite:getPosition()
    if screenX ~= currentX or screenY ~= currentY then
      sprite:moveTo(screenX, screenY)
    end
  end
end

-- ! Helper: Remove Sprites From Scene
-- Uses the scene batch unregister path when available; otherwise removes directly.
local function _removeSpritesFromScene(scene, sprites)
  if not sprites or #sprites == 0 then return end

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
  sprite._roxyScenePausePlayback = playback
  sprite._roxyScenePauseUpdates = updates
  sprite._roxyScenePauseCollisions = collisions
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
  if layerData.visible == nil then layerData.visible = true end
  self.layers[layerData.name] = layerData
end

-- ! Ensure Sprite
-- Creates if needed and returns the sprite for a layer
function LayerManager:ensureSprite(name)
  local layer = self.layers[name]; if not layer then return nil end
  if self._opts.wrapInSprites == false then return layer.sprite end

  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local useParallax = (not layer.layerOptions) or (layer.layerOptions.parallax ~= false)
  local hasParallax = useParallax and (parallaxX ~= 1 or parallaxY ~= 1)

  if layer.sprite then
    -- Keep classification current before addSprite's same-owner fast path.
    _setScenePauseClassification(layer.sprite, false, hasParallax, false)
    if self._autoAdd and self._sceneHasAdd then
      self.scene:addSprite(layer.sprite)
    end
    return layer.sprite
  end

  local sprite = newSprite()
  sprite:setTilemap(layer.tilemap)
  if (layer.anchor or self._opts.anchor) == "topLeft" then sprite:setCenter(0, 0) else sprite:setCenter(0.5, 0.5) end
  sprite:setZIndex(layer.zIndex or 0)
  -- Keep classification current before addSprite's same-owner fast path.
  _setScenePauseClassification(sprite, false, hasParallax, false)

  if hasParallax then
    sprite:setIgnoresDrawOffset(true)
    sprite:setUpdatesEnabled(true)
    sprite.update = _createParallaxUpdate(
      layer.originX or 0, layer.originY or 0,
      parallaxX, parallaxY,
      layer.parallaxoriginx or 0, layer.parallaxoriginy or 0
    )
  else
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
  for name, _ in pairs(self.layers) do self:ensureSprite(name) end
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
function LayerManager:hide(name)
  local layer = self.layers[name]
  if not layer then return false end

  layer.visible = false
  if layer.sprite then layer.sprite:setVisible(false) end
  return true
end

-- ! Show
function LayerManager:show(name)
  local layer = self.layers[name]
  if not layer then return false end

  layer.visible = true
  local sprite = self:ensureSprite(name)
  if sprite then sprite:setVisible(true) end
  return true
end

-- ! Remove
-- Remove layer + sprites + collision sprites + retained paths from swaps
function LayerManager:remove(name)
  local layer = self.layers[name]
  if not layer then return false end

  if layer.sprite then
    local sprite = layer.sprite
    _removeSpritesFromScene(self.scene, { sprite })
    -- Remove from external list if present
    for i = #self._spritesList, 1, -1 do
      if self._spritesList[i] == sprite then tableRemove(self._spritesList, i); break end
    end
    layer.sprite = nil
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
function LayerManager:setImageTable(name, newImageTableOrPath, remapFn)
  local layer = self.layers[name]
  if not layer or not layer.tilemap then return false end

  local newPath, newTable
  if type(newImageTableOrPath) == "string" then
    -- Normalize like RoxyTilemap expects ("assets/images/<base>")
    local filename = newImageTableOrPath:match("([^/]+)$") or ""
    local base = filename:gsub("%-table%-%d+%-%d+%.png$", "")
    newPath = "assets/images/" .. base
    newTable = getTable(newPath)
    if not newTable then return false end
  else
    newTable = newImageTableOrPath
    if not newTable then return false end
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
    if img then local _, height = img:getSize()
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
      else
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
function LayerManager:setOrigin(name, x, y)
  local layer = self.layers[name]
  if not layer then return false end

  x, y = x or 0, y or 0
  if layer.originX == x and layer.originY == y then return true end

  layer.originX, layer.originY = x, y
  local sprite = layer.sprite
  if sprite then
    local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
    local parallaxOriginX, parallaxOriginY = layer.parallaxoriginx or 0, layer.parallaxoriginy or 0
    if sprite.update and sprite.setUpdatesEnabled then
      sprite.update = _createParallaxUpdate(layer.originX, layer.originY, parallaxX, parallaxY, parallaxOriginX, parallaxOriginY)
      sprite:setIgnoresDrawOffset(true); sprite:setUpdatesEnabled(true)
    else
      sprite:moveTo(layer.originX, layer.originY)
    end
  end
  return true
end

-- ! Set Origin for All
function LayerManager:setOriginForAll(x, y)
  for name, _ in pairs(self.layers) do self:setOrigin(name, x, y) end
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- ! Detach
-- Remove layer and collision sprites without releasing retained swap paths.
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
      layer.sprite = nil
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
  for path, _ in pairs(self._retainedPaths) do release(path) end
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

-- Register a Layer
local imageTable = Graphics.imagetable.new("images/terrain")
local tilemap = Graphics.tilemap.new()
tilemap:setImageTable(imageTable)
tilemap:setTiles({
  1, 1, 0,
  2, 2, 1,
}, 3)

manager:addLayer({
  name = "Ground",
  tilemap = tilemap,
  imageTable = imageTable,
  tileWidth = 16,
  tileHeight = 16,
  originX = 0,
  originY = 0,
  zIndex = 0,
  visible = true,
  anchor = "topLeft",
  parallaxx = 0.5,
  parallaxy = 1,
  parallaxoriginx = 200,
  parallaxoriginy = 120,
})

-- Sprite Lifecycle and Visibility
manager:ensureSpritesForAll()
local groundSprite = manager:getSprite("Ground")
local groundTilemap = manager:getTilemap("Ground")
local allLayerSprites = manager:getAllSprites()

manager:hide("Ground")
manager:show("Ground")
manager:setOrigin("Ground", 32, 16)
manager:setOriginForAll(0, 0)

-- Runtime Image Table Swap
local winterTiles = Graphics.imagetable.new("images/terrain-winter")
manager:setImageTable("Ground", winterTiles, {
  [1] = 2,
  [2] = 1,
})

-- Cleanup
manager:detach()
manager:remove("Ground")
manager:destroy()

--]]
