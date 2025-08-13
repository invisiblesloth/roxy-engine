-- core/tilemaps/RoxyOrthoTilemap.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
local Camera  <const> = r.Camera

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
  -- (Moved from the old base helper; logic unchanged except local names.)
  local cameraX, cameraY = getCameraPosition()
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local originX, originY = layer.originX or 0, layer.originY or 0
  local mapPixelWidth, mapPixelHeight = layer.mapPixelWidth or 0, layer.mapPixelHeight or 0

  local screenX, screenY
  if layer.anchor == "topLeft" then
    screenX = round(originX - cameraX * parallaxX)
    screenY = round(originY - cameraY * parallaxY)
  else
    screenX = round(originX - (mapPixelWidth  * 0.5) - cameraX * parallaxX)
    screenY = round(originY - (mapPixelHeight * 0.5) - cameraY * parallaxY)
  end

  local sourceX, sourceY = 0, 0
  local sourceWidth, sourceHeight = mapPixelWidth, mapPixelHeight

  if screenX < 0 then sourceX = -screenX end
  if screenY < 0 then sourceY = -screenY end

  local maxW = DISPLAY_WIDTH - math.max(0, screenX)
  local maxH = DISPLAY_HEIGHT - math.max(0, screenY)
  sourceWidth  = math.min(sourceWidth - sourceX, math.max(0, maxW))
  sourceHeight = math.min(sourceHeight - sourceY, math.max(0, maxH))

  if sourceWidth <= 0 or sourceHeight <= 0 then
    return screenX, screenY, nil, true
  end

  return screenX, screenY, sourceX, sourceY, sourceWidth, sourceHeight, false
end

--------------------------------------------------------------------------------
-- ! Class Definition
--------------------------------------------------------------------------------

class("RoxyOrthoTilemap").extends(RoxyTilemap)

--------------------------------------------------------------------------------
-- Projection methods
--------------------------------------------------------------------------------

-- ! World to Screen (orthogonal)
function RoxyOrthoTilemap:worldToScreen(worldX, worldY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  local orthoX = originX + worldX * tileWidth
  local orthoY = originY + worldY * tileHeight
  return round(orthoX - cameraX * parallaxX), round(orthoY - cameraY * parallaxY)
end

-- ! Screen to World (orthogonal)
function RoxyOrthoTilemap:screenToWorld(screenX, screenY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  local worldX = ((screenX + cameraX * parallaxX) - originX) / tileWidth
  local worldY = ((screenY + cameraY * parallaxY) - originY) / tileHeight
  return worldX, worldY
end

--------------------------------------------------------------------------------
-- Public API preserved from original class
--------------------------------------------------------------------------------

-- ! Set Tile At
-- Sets the tile at the given tile coordinates (x, y) on the specified layer.
-- Note: Coordinates are in tile units, not pixels.
function RoxyOrthoTilemap:setTileAt(name, x, y, tileIndex, updateSprite)
  local layer = self.layers[name]
  if not layer then return end

  layer.tilemap:setTileAtPosition(x, y, tileIndex)

  if updateSprite and layer.sprite then
    local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
    -- Top-left of tile in pixels
    local screenX, screenY = self:worldToScreen(x - 1, y - 1, layer)
    addDirtyRect(screenX, screenY, tileWidth, tileHeight)
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