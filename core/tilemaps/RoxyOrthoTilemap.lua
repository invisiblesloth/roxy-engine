-- core/tilemaps/RoxyOrthoTilemap.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
local Camera  <const> = r.Camera

local min   <const> = math.min
local max   <const> = math.max
local round <const> = r.Math.round

local tableInsert <const> = table.insert
local tableSort   <const> = table.sort

local getCameraPosition <const> = Camera.getPosition
local addDirtyRect      <const> = Sprite.addDirtyRect

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Compute Draw Parameters
-- Compute draw parameters for orthographic projection.
-- Returns: screenX, screenY, sourceX, sourceY, sourceWidth, sourceHeight, culled
local function _computeDrawParams(layer)
  local cameraX, cameraY = getCameraPosition()
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local originX, originY = layer.originX or 0, layer.originY or 0
  local mapPixelWidth, mapPixelHeight = layer.mapPixelWidth or 0, layer.mapPixelHeight or 0

  -- Respect parallax origin
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local screenX, screenY
  if layer.anchor == "topLeft" then
    -- Include pivot adjust so sprites vs direct draw match.
    screenX = round(originX + pivotAdjustX - cameraX * parallaxX)
    screenY = round(originY + pivotAdjustY - cameraY * parallaxY)
  else
    screenX = round(originX - (mapPixelWidth  * 0.5) + pivotAdjustX - cameraX * parallaxX)
    screenY = round(originY - (mapPixelHeight * 0.5) + pivotAdjustY - cameraY * parallaxY)
  end

  local sourceX, sourceY = 0, 0
  local sourceWidth, sourceHeight = mapPixelWidth, mapPixelHeight

  if screenX < 0 then sourceX = -screenX end
  if screenY < 0 then sourceY = -screenY end

  local maxW = DISPLAY_WIDTH - max(0, screenX)
  local maxH = DISPLAY_HEIGHT - max(0, screenY)
  sourceWidth  = min(sourceWidth - sourceX, max(0, maxW))
  sourceHeight = min(sourceHeight - sourceY, max(0, maxH))

  if sourceWidth <= 0 or sourceHeight <= 0 then
    return screenX, screenY, nil, true
  end

  return screenX, screenY, sourceX, sourceY, sourceWidth, sourceHeight, false
end

--------------------------------------------------------------------------------
-- ! Class Definition and Initialization
--------------------------------------------------------------------------------

class("RoxyOrthoTilemap").extends(RoxyTilemap)

function RoxyOrthoTilemap:init(jsonPath, opts, scene)
  RoxyOrthoTilemap.super.init(self, jsonPath, opts, scene)
  self._projection = "orthogonal"
end

--------------------------------------------------------------------------------
-- Projection methods
--------------------------------------------------------------------------------

-- ! World to Screen (orthogonal)
function RoxyOrthoTilemap:worldToScreen(worldX, worldY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  -- Parallax-origin pivot to match sprite behavior (like other tilemap classes)
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local orthoX = originX + worldX * tileWidth
  local orthoY = originY + worldY * tileHeight

  -- Include pivotAdjust* before subtracting camera (consistent with other classes)
  return round(orthoX + pivotAdjustX - cameraX * parallaxX),
         round(orthoY + pivotAdjustY - cameraY * parallaxY)
end

-- ! Screen to World (orthogonal)
function RoxyOrthoTilemap:screenToWorld(screenX, screenY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  -- Parallax-origin pivot to match sprite behavior
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  -- Undo camera and pivot before converting to world
  local dx = (screenX + cameraX * parallaxX) - (originX + pivotAdjustX)
  local dy = (screenY + cameraY * parallaxY) - (originY + pivotAdjustY)

  local worldX = dx / tileWidth
  local worldY = dy / tileHeight
  return worldX, worldY
end

--------------------------------------------------------------------------------
-- Public API preserved from original class
--------------------------------------------------------------------------------

-- ! Set Tile At
-- Sets the tile at the given tile coordinates (x, y) on the specified layer.
-- Note: Coordinates are in tile units, not pixels.
function RoxyOrthoTilemap:setTileAt(name, x, y, tileIndex, updateSprite)
  local layer = self.layers and self.layers[name]
  if not layer then return end

  layer.tilemap:setTileAtPosition(x, y, tileIndex)

  if updateSprite then
    local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
    -- Use consistent world-to-screen conversion
    local screenX, screenY = self:worldToScreen(x - 1, y - 1, layer)

    -- Support both sprite-based and direct drawing approaches
    if layer.sprite then
      addDirtyRect(screenX, screenY, tileWidth, tileHeight)
    else
      -- For direct drawing, mark the area as needing refresh
      addDirtyRect(screenX, screenY, tileWidth, tileHeight)
    end
  end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- ! Draw
-- Draw a single tile layer directly (no sprite required)
function RoxyOrthoTilemap:draw(name)
  local layer = self.layers and self.layers[name]
  if not layer or not layer.tilemap or layer.visible == false then return end

  local screenX, screenY, sourceX, sourceY, sourceWidth, sourceHeight, culled = _computeDrawParams(layer)
  if culled then return end

  -- Use drawIgnoringOffset because we already applied camera/offset logic
  local drawIgnoring = layer.tilemap.drawIgnoringOffset
  if sourceX then
    drawIgnoring(layer.tilemap, screenX, screenY, sourceX, sourceY, sourceWidth, sourceHeight)
  else
    drawIgnoring(layer.tilemap, screenX, screenY)
  end
end

-- ! Draw Visible
-- Draw all visible tile layers by zIndex (ascending)
function RoxyOrthoTilemap:drawVisible()
  if not self.layers then return end

  -- Collect visible layers
  local list = {}
  for name, layer in pairs(self.layers) do
    if layer.tilemap and layer.visible ~= false then
      tableInsert(list, layer)
    end
  end

  -- Sort by zIndex to match sprite render order
  tableSort(list, function(a, b)
    return (a.zIndex or 0) < (b.zIndex or 0)
  end)

  -- Draw in order
  for i = 1, #list do
    local layer = list[i]
    local screenX, screenY, sourceX, sourceY, sourceWidth, sourceHeight, culled = _computeDrawParams(layer)
    if not culled then
      local drawIgnoring = layer.tilemap.drawIgnoringOffset
      if sourceX then
        drawIgnoring(layer.tilemap, screenX, screenY, sourceX, sourceY, sourceWidth, sourceHeight)
      else
        drawIgnoring(layer.tilemap, screenX, screenY)
      end
    end
  end
end

-- ! Draw Layer Region (for consistency with other tilemap classes)
function RoxyOrthoTilemap:drawLayerRegion(layerName, minTileX, maxTileX, minTileY, maxTileY)
  local layer = self.layers and self.layers[layerName]
  if not layer or not layer.tilemap or layer.visible == false then return end

  local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight

  -- Clamp bounds
  minTileX = max(1, minTileX)
  maxTileX = min(mapWidthTiles, maxTileX)
  minTileY = max(1, minTileY)
  maxTileY = min(mapHeightTiles, maxTileY)

  if minTileX > maxTileX or minTileY > maxTileY then return end

  -- Calculate screen rectangle for the tile region
  local topLeftX, topLeftY = self:worldToScreen(minTileX - 1, minTileY - 1, layer)
  local regionWidth = (maxTileX - minTileX + 1) * tileWidth
  local regionHeight = (maxTileY - minTileY + 1) * tileHeight

  -- Convert to source rectangle (pixels within the tilemap image)
  local sourceX = (minTileX - 1) * tileWidth
  local sourceY = (minTileY - 1) * tileHeight

  -- Clamp to screen bounds
  local screenX, screenY = max(0, topLeftX), max(0, topLeftY)
  local sourceOffsetX = screenX - topLeftX
  local sourceOffsetY = screenY - topLeftY

  local visibleWidth = min(regionWidth - sourceOffsetX, DISPLAY_WIDTH - screenX)
  local visibleHeight = min(regionHeight - sourceOffsetY, DISPLAY_HEIGHT - screenY)

  if visibleWidth > 0 and visibleHeight > 0 then
    layer.tilemap:drawIgnoringOffset(
      screenX, screenY,
      sourceX + sourceOffsetX, sourceY + sourceOffsetY,
      visibleWidth, visibleHeight
    )
  end
end

-- ! Draw with Region-Based Culling (optional alternative to current draw method)
function RoxyOrthoTilemap:drawWithTileCulling(name)
  local layer = self.layers and self.layers[name]
  if not layer or not layer.tilemap or layer.visible == false then return end

  local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight

  -- Calculate visible tile bounds
  local topLeftX, topLeftY = self:screenToWorld(0, 0, layer)
  local bottomRightX, bottomRightY = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)

  local minTileX = max(1, math.floor(topLeftX) + 1)
  local maxTileX = min(mapWidthTiles, math.ceil(bottomRightX) + 1)
  local minTileY = max(1, math.floor(topLeftY) + 1)
  local maxTileY = min(mapHeightTiles, math.ceil(bottomRightY) + 1)

  self:drawLayerRegion(name, minTileX, maxTileX, minTileY, maxTileY)
end
