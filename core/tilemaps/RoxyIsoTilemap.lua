-- core/tilemaps/RoxyIsoTilemap.lua
-- Classic diamond isometric tilemaps for Roxy (no stagger logic).

local pd        <const> = playdate
local Graphics  <const> = pd.graphics

local r       <const> = roxy
local Camera  <const> = r.Camera

local min   <const> = math.min
local max   <const> = math.max
local floor <const> = math.floor
local ceil  <const> = math.ceil
local round <const> = r.Math.round

local tableInsert <const> = table.insert
local tableSort   <const> = table.sort

local setDrawOffset <const> = Graphics.setDrawOffset
local getDrawOffset <const> = Graphics.getDrawOffset

local getCameraPosition <const> = Camera.getPosition

local _isoDrawOffsets   <const> = RoxyTilemap._isoDrawOffsets
local _beginManualDraw  <const> = RoxyTilemap._beginManualDraw
local _endManualDraw    <const> = RoxyTilemap._endManualDraw

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- Helper to compute and cache max image height for the layer
local function _getMaxImgH(layer)
  if layer._maxImgH then return layer._maxImgH end
  local imagetable = layer.imageTable
  local imagetableLength = imagetable and imagetable:getLength() or 0
  local maxH = layer.tileHeight or 0
  for i = 1, imagetableLength do
    local img = imagetable:getImage(i)
    if img then
      local _, height = img:getSize()
      if height and height > maxH then
        maxH = height
      end
    end
  end
  layer._maxImgH = maxH
  return maxH
end

--------------------------------------------------------------------------------
-- ! Class Definition and Initialize
--------------------------------------------------------------------------------

class("RoxyIsoTilemap").extends(RoxyTilemap)

function RoxyIsoTilemap:init(jsonPath, opts, scene)
  opts = opts or {}
  opts.wrapInSprites = false
  opts.anchor = "topLeft"
  RoxyIsoTilemap.super.init(self, jsonPath, opts, scene)

  -- Mark the projection for clarity/debugging
  self._projection = "iso"
end

--------------------------------------------------------------------------------
-- Projection (classic diamond isometric)
-- screenX = originX + (worldX - worldY) * (tileWidth  * 0.5)
-- screenY = originY + (worldX + worldY) * (tileHeight * 0.5)
--------------------------------------------------------------------------------

-- ! World to Screen
function RoxyIsoTilemap:worldToScreen(worldX, worldY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local halfWidth, halfHeight = tileWidth * 0.5, tileHeight * 0.5

  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  -- Parallax-origin pivot so direct math matches sprite path
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local isoX = originX + (worldX - worldY) * halfWidth
  local isoY = originY + (worldX + worldY) * halfHeight

  -- Include pivotAdjust* before subtracting camera
  return round(isoX + pivotAdjustX - cameraX * parallaxX),
         round(isoY + pivotAdjustY - cameraY * parallaxY)
end

-- ! Screen to World
function RoxyIsoTilemap:screenToWorld(screenX, screenY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local halfWidth, halfHeight = tileWidth * 0.5, tileHeight * 0.5

  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  -- Parallax-origin pivot so direct math matches sprite path
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  -- Undo camera and pivot before converting to world
  local dx = (screenX + cameraX * parallaxX) - (originX + pivotAdjustX)
  local dy = (screenY + cameraY * parallaxY) - (originY + pivotAdjustY)

  local worldX = (dx / halfWidth + dy / halfHeight) * 0.5
  local worldY = (dy / halfHeight - dx / halfWidth) * 0.5
  return worldX, worldY
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Set Tile At
function RoxyIsoTilemap:setTileAt(name, x, y, tileIndex, updateSprite)
  local layer = self.layers and self.layers[name]
  if not layer then return end

  layer.tilemap:setTileAtPosition(x, y, tileIndex)

  if updateSprite and layer.imageTable then
    local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
    local screenX, screenY = self:worldToScreen(x - 1, y - 1, layer)
    Graphics.sprite.addDirtyRect(screenX, screenY, tileWidth, tileHeight)
  end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- ! Draw
-- Draw a single tile layer with conservative vertical culling.
function RoxyIsoTilemap:draw(name)
  local layer = self.layers and self.layers[name]
  if not layer or not layer.tilemap or layer.visible == false then return end

  local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight

  -- Get world coordinates of screen corners
  local topLeftX, topLeftY = self:screenToWorld(0, 0, layer)
  local topRightX, topRightY = self:screenToWorld(DISPLAY_WIDTH, 0, layer)
  local bottomLeftX, bottomLeftY = self:screenToWorld(0, DISPLAY_HEIGHT, layer)
  local bottomRightX, bottomRightY = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)

  -- Find the bounds of visible tiles with margin for image height
  local maxImgH = _getMaxImgH(layer)
  local halfHeight = tileHeight * 0.5
  local overdraw = max(0, maxImgH - tileHeight)
  local margin = ceil(overdraw / max(1, halfHeight)) + 1

  -- Calculate conservative bounds
  local minWorldX = min(topLeftX, topRightX, bottomLeftX, bottomRightX) - margin
  local maxWorldX = max(topLeftX, topRightX, bottomLeftX, bottomRightX) + margin
  local minWorldY = min(topLeftY, topRightY, bottomLeftY, bottomRightY) - margin
  local maxWorldY = max(topLeftY, topRightY, bottomLeftY, bottomRightY) + margin

  -- Convert to tile coordinates (1-based)
  local minTileX = max(1, floor(minWorldX) + 1)
  local maxTileX = min(mapWidthTiles, ceil(maxWorldX) + 1)
  local minTileY = max(1, floor(minWorldY) + 1)
  local maxTileY = min(mapHeightTiles, ceil(maxWorldY) + 1)

  self:drawLayerRegion(name, minTileX, maxTileX, minTileY, maxTileY)
end

-- ! Draw Visible
-- Draw all visible tile layers sorted by z-index.
function RoxyIsoTilemap:drawVisible()
  if not self.layers then return end

  local list = {}
  for _, layer in pairs(self.layers) do
    if layer.tilemap and layer.visible ~= false then
      tableInsert(list, layer)
    end
  end
  tableSort(list, function(a, b) return (a.zIndex or 0) < (b.zIndex or 0) end)

  for i = 1, #list do
    local layer = list[i]
    local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()
    local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight

    -- Get world coordinates of screen corners
    local topLeftX, topLeftY = self:screenToWorld(0, 0, layer)
    local topRightX, topRightY = self:screenToWorld(DISPLAY_WIDTH, 0, layer)
    local bottomLeftX, bottomLeftY = self:screenToWorld(0, DISPLAY_HEIGHT, layer)
    local bottomRightX, bottomRightY = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)

    -- Find the bounds of visible tiles with margin for image height
    local maxImgH = _getMaxImgH(layer)
    local halfHeight = tileHeight * 0.5
    local overdraw = max(0, maxImgH - tileHeight)
    local margin = ceil(overdraw / max(1, halfHeight)) + 1

    -- Calculate conservative bounds
    local minWorldX = min(topLeftX, topRightX, bottomLeftX, bottomRightX) - margin
    local maxWorldX = max(topLeftX, topRightX, bottomLeftX, bottomRightX) + margin
    local minWorldY = min(topLeftY, topRightY, bottomLeftY, bottomRightY) - margin
    local maxWorldY = max(topLeftY, topRightY, bottomLeftY, bottomRightY) + margin

    -- Convert to tile coordinates (1-based)
    local minTileX = max(1, floor(minWorldX) + 1)
    local maxTileX = min(mapWidthTiles, ceil(maxWorldX) + 1)
    local minTileY = max(1, floor(minWorldY) + 1)
    local maxTileY = min(mapHeightTiles, ceil(maxWorldY) + 1)

    self:drawLayerRegion(layer.name, minTileX, maxTileX, minTileY, maxTileY)
  end
end

-- ! Draw Layer Region
function RoxyIsoTilemap:drawLayerRegion(layerName, minTileX, maxTileX, minTileY, maxTileY)
  local restoreX, restoreY = _beginManualDraw()

  local layer = self.layers and self.layers[layerName]
  if not layer or not layer.tilemap or layer.visible == false then
    _endManualDraw(restoreX, restoreY); return
  end

  local imageTable = layer.imageTable
  if not imageTable then
    _endManualDraw(restoreX, restoreY); return
  end

  local cache = layer._imgCache
  if not cache then cache = {}; layer._imgCache = cache end

  local tilemap = layer.tilemap
  local mapWidthTiles, mapHeightTiles = tilemap:getSize()
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight

  -- Clamp bounds
  minTileX = max(1, minTileX)
  maxTileX = min(mapWidthTiles, maxTileX)
  minTileY = max(1, minTileY)
  maxTileY = min(mapHeightTiles, maxTileY)

  if minTileX > maxTileX or minTileY > maxTileY then
    _endManualDraw(restoreX, restoreY); return
  end

  local tiles, widthFromTileMap = tilemap:getTiles()
  local stride = widthFromTileMap or mapWidthTiles

  -- Camera and parallax calculations
  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local cameraX, cameraY = getCameraPosition()
  local halfHeight, halfWidth = tileHeight * 0.5, tileWidth * 0.5

  -- Draw tiles in the specified region
  for tileY = minTileY, maxTileY do
    for tileX = minTileX, maxTileX do
      local i = (tileY - 1) * stride + tileX
      local idx = tiles and tiles[i] or 0

      if idx and idx ~= 0 then
        local img = cache[idx]
        if not img then img = imageTable:getImage(idx); cache[idx] = img end

        if img then
          -- Convert tile coordinates to screen position
          local worldX, worldY = tileX - 1, tileY - 1
          local screenX = originX + (worldX - worldY) * halfWidth
          local screenY = originY + (worldX + worldY) * halfHeight

          local finalScreenX = round(screenX + pivotAdjustX - cameraX * parallaxX)
          local finalScreenY = round(screenY + pivotAdjustY - cameraY * parallaxY)

          local offX, offY = _isoDrawOffsets(tileWidth, tileHeight, img)
          local drawX, drawY = finalScreenX + offX, finalScreenY + offY

          -- Final screen bounds check (optional optimization)
          local imgW, imgH = img:getSize()
          if not (drawX > DISPLAY_WIDTH or drawY > DISPLAY_HEIGHT or
                  drawX + imgW < 0 or drawY + imgH < 0) then
            img:draw(drawX, drawY)
          end
        end
      end
    end
  end

  _endManualDraw(restoreX, restoreY)
end

-- ! Get Rows From Screen
-- Convert a screen pixel to a 1-based row (tileY).
function RoxyIsoTilemap:getRowFromScreen(screenX, screenY, layerName)
  local targetLayer = self.layers and self.layers[layerName]
  if not targetLayer then
    -- Fall back to any layer if needed
    for _, layer in pairs(self.layers or {}) do
      if layer.tilemap then
        targetLayer = layer
        break
      end
    end
    if not targetLayer then return 1 end
  end

  local _, mapHeightTiles = targetLayer.tilemap:getSize()
  local _, worldY = self:screenToWorld(screenX, screenY, targetLayer)
  local row = floor(worldY + 1)
  if row < 1 then
    row = 1
  elseif row > mapHeightTiles then
    row = mapHeightTiles
  end
  return row
end
