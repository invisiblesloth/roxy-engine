-- core/tilemaps/LayerManager.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r           <const> = roxy
local AssetStore  <const> = r.AssetStore
local Camera      <const> = r.Camera

local round     <const> = r.Math.round

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
  return function(sprite)
    local cameraX, cameraY = Camera.getPosition()
    local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
    local pivotAdjustY = parallaxOriginY * (1 - parallaxY)
  
    local screenX = round(worldX + pivotAdjustX - cameraX * parallaxX)
    local screenY = round(worldY + pivotAdjustY - cameraY * parallaxY)
  
    local currentX, currentY = sprite:getPosition()
    if screenX ~= currentX or screenY ~= currentY then
      sprite:moveTo(screenX, screenY)
    end
  end
end

--------------------------------------------------------------------------------
-- ! Class Definition and Initialize
--------------------------------------------------------------------------------

class("LayerManager").extends(Object)

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

-- ! Add Layer
-- Register/replace layer data. Does NOT create a sprite yet.
function LayerManager:addLayer(layerData)
  if layerData.visible == nil then layerData.visible = true end
  self.layers[layerData.name] = layerData
end

-- ! Ensure Sprite
-- Create (if needed) and return the sprite for a layer
function LayerManager:ensureSprite(name)
  local layer = self.layers[name]; if not layer then return nil end
  if layer.sprite or self._opts.wrapInSprites == false then return layer.sprite end

  local sprite = newSprite()
  sprite:setTilemap(layer.tilemap)
  if (layer.anchor or self._opts.anchor) == "topLeft" then sprite:setCenter(0, 0) else sprite:setCenter(0.5, 0.5) end
  sprite:setZIndex(layer.zIndex or 0)

  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local useParallax = (not layer.layerOptions) or (layer.layerOptions.parallax ~= false)
  if useParallax and (parallaxX ~= 1 or parallaxY ~= 1) then
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

  if self._autoAdd then
    if self._sceneHasAdd then
      self.scene:addSprite(sprite)
    else
      sprite:add()
    end
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
  if not layer then return end
  
  layer.visible = false
  if layer.sprite then layer.sprite:setVisible(false) end
end

-- ! Show
function LayerManager:show(name)
  local layer = self.layers[name]
  if not layer then return end
  
  layer.visible = true
  local sprite = self:ensureSprite(name)
  if sprite then sprite:setVisible(true) end
end

-- ! Remove
-- Remove layer + sprites + collision sprites + retained paths from swaps
function LayerManager:remove(name)
  local layer = self.layers[name]
  if not layer then return end

  if layer.sprite then
    local sprite = layer.sprite
    if self.scene and self.scene.removeSprite then self.scene:removeSprite(sprite) else sprite:remove() end
    -- remove from external list if present
    for i = #self._spritesList, 1, -1 do
      if self._spritesList[i] == sprite then tableRemove(self._spritesList, i); break end
    end
    layer.sprite = nil
  end

  if layer.collisionSprites then
    for _, collisionSprite in ipairs(layer.collisionSprites) do collisionSprite:remove() end
    layer.collisionSprites = nil
  end

  if layer.imagePath and self._retainedPaths[layer.imagePath] then
    release(layer.imagePath)
    self._retainedPaths[layer.imagePath] = nil
  end

  layer.tilemap, layer.imageTable, layer._imageCache, layer._offsetCache = nil, nil, nil, nil
  self.layers[name] = nil
end

-- ! Set Image Table
-- Runtime imagetable swap with index remap and proper retention accounting
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
    local tiles, width = layer.tilemap:getTiles()
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
    end
  end

  layer.tilemap:setImageTable(newTable)
  layer.imageTable, layer._imageCache, layer._offsetCache = newTable, {}, {}

  -- recompute image meta
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

  -- update retention (for swap paths only)
  if newPath then
    if not self._retainedPaths[newPath] then
      retain(newPath, newTable)
      self._retainedPaths[newPath] = true
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
  
  layer.originX, layer.originY = x or 0, y or 0
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

-- ! Destroy
-- Cleanly remove all layer sprites + collisions and release swap-retained paths
function LayerManager:destroy()
  for _, layer in pairs(self.layers) do
    if layer.sprite then
      if self.scene and self.scene.removeSprite then self.scene:removeSprite(layer.sprite) else layer.sprite:remove() end
      layer.sprite = nil
    end
    if layer.collisionSprites then
      for _, collisionSprite in ipairs(layer.collisionSprites) do collisionSprite:remove() end
      layer.collisionSprites = nil
    end
    layer.tilemap, layer.imageTable, layer._imageCache, layer._offsetCache = nil, nil, nil, nil
  end
  for path, _ in pairs(self._retainedPaths) do release(path) end
  self._retainedPaths = {}
  self._spritesList = {}
end
