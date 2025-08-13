-- core/tilemaps/RoxyIsoTilemap.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics

local r       <const> = roxy
local Camera  <const> = r.Camera

local floor <const> = math.floor
local min   <const> = math.min
local ceil  <const> = math.ceil
local max   <const> = math.max
local round <const> = r.Math.round

local tableInsert <const> = table.insert
local tableSort   <const> = table.sort

local getCameraPosition <const> = Camera.getPosition

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Isometric Draw Offset
-- Per-tile draw offsets so diamonds align with Tiled
local function _isoDrawOffsets(tileWidth, tileHeight, img)
  -- Tiled’s isometric origin expects images taller than the logical tile.
  -- Offset X by half the extra width; offset Y by the full extra height.
  local imgWidth, imgHeight = img:getSize()
  local offsetX = (tileWidth - imgWidth) * 0.5
  local offsetY = (tileHeight - imgHeight)
  return offsetX, offsetY
end

--------------------------------------------------------------------------------
-- ! Class Definition
--------------------------------------------------------------------------------

class("RoxyIsoTilemap").extends(RoxyTilemap)

function RoxyIsoTilemap:init(jsonPath, opts, scene)
  opts = opts or {}
  
  -- Disable sprite wrapping to avoid orthographic renderer
  opts.wrapInSprites = false
  RoxyIsoTilemap.super.init(self, jsonPath, opts, scene)

  -- World height for staggered‑Y: rows advance by half tile height
  if self.mapOrientation == "staggered" and self.staggerAxis == "y" then
    local halfHeight = (self.mapTileHeight or 0) * 0.5
    self.worldHeight = halfHeight * (self.mapHeight + 1) -- First row full + (rows-1) half steps

    -- World width when the last row is shifted to the right
    local halfWidth = (self.mapTileWidth or 0) * 0.5
    local lastRowIsShifted =
      (self.staggerIndex == "odd"  and (self.mapHeight % 2 == 1)) or -- H odd --> last row is odd --> shifted
      (self.staggerIndex == "even" and (self.mapHeight % 2 == 0)) -- H even --> last row is even --> shifted
    if lastRowIsShifted then
      self.worldWidth += halfWidth -- Add the extra overhang on the right edge
    end
  end
end

--------------------------------------------------------------------------------
-- Projection Methods
--------------------------------------------------------------------------------

-- Isometric projection uses half tile width/height for diamond mapping.
--     screenX = originX + (worldX - worldY) * (tileWidth  * 0.5)
--     screenY = originY + (worldX + worldY) * (tileHeight * 0.5)
--     Then apply camera/parallax and round.

-- ! World to Screen
function RoxyIsoTilemap:worldToScreen(worldX, worldY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local halfWidth = tileWidth * 0.5
  local halfHeight = tileHeight * 0.5

  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  -- Staggered-Y support
  if self.mapOrientation == "staggered" and self.staggerAxis == "y" then
    -- Parity: odd rows shift, based on 0-based worldY.
    local isOddRow = (worldY % 2) == 1
    local applyShift = (self.staggerIndex == "odd"  and isOddRow) or (self.staggerIndex == "even" and not isOddRow)
    local shiftX = applyShift and halfWidth or 0
  
    local screenX = originX + worldX * tileWidth + shiftX
    local screenY = originY + worldY * halfHeight
    return round(screenX - cameraX * parallaxX), round(screenY - cameraY * parallaxY)
  end

  -- Default diamond (classic isometric)
  local isoX = originX + (worldX - worldY) * halfWidth
  local isoY = originY + (worldX + worldY) * halfHeight
  return round(isoX - cameraX * parallaxX), round(isoY - cameraY * parallaxY)
end

-- ! Screen to World
-- Inverse of the above:
--   dx = (screenX + cameraX*px - originX)
--   dy = (screenY + cameraY*py - originY)
--   worldX = (dx/halfWidth + dy/halfHeight) * 0.5
--   worldY = (dy/halfHeight - dx/halfWidth) * 0.5
function RoxyIsoTilemap:screenToWorld(screenX, screenY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local halfWidth = tileWidth * 0.5
  local halfHeight = tileHeight * 0.5

  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  local dx = (screenX + cameraX * parallaxX) - originX
  local dy = (screenY + cameraY * parallaxY) - originY

  -- Staggered-Y inverse mapping
  if self.mapOrientation == "staggered" and self.staggerAxis == "y" then
    local worldY = dy / halfHeight
    local row = math.floor(worldY + 1e-6)
    local isOddRow  = (row % 2) == 1
    local applyShift = (self.staggerIndex == "odd"  and isOddRow) or (self.staggerIndex == "even" and not isOddRow)
    local shiftX = applyShift and halfWidth or 0
  
    local worldX = (dx - shiftX) / tileWidth
    return worldX, worldY
  end

  -- Default diamond (classic isometric inverse)
  local worldX = (dx / halfWidth + dy / halfHeight) * 0.5
  local worldY = (dy / halfHeight - dx / halfWidth) * 0.5
  return worldX, worldY
end

--------------------------------------------------------------------------------
-- Public API Preserved From Original Class
--------------------------------------------------------------------------------

-- ! Set Tile At
-- Sets the tile at the given tile coordinates (x, y) on the specified layer.
-- Note: Coordinates are in tile units, not pixels.
function RoxyIsoTilemap:setTileAt(name, x, y, tileIndex, updateSprite)
  local layer = self.layers[name]
  if not layer then return end

  layer.tilemap:setTileAtPosition(x, y, tileIndex)

  -- Invalidate just the changed tile’s diamond bounds
  if updateSprite and layer.imageTable then
    local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
    local screenX, screenY = self:worldToScreen(x - 1, y - 1, layer)
    -- Draw positions assume top-left of the tile image at screenX/screenY
    Graphics.sprite.addDirtyRect(screenX, screenY, tileWidth, tileHeight)
  end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- ! Draw
-- Draw a single tile layer (isometric, direct draw)
function RoxyIsoTilemap:draw(name)
  local layer = self.layers and self.layers[name]
  if not layer or not layer.tilemap or layer.visible == false then return end
  local imageTable = layer.imageTable
  if not imageTable then return end

  local tilemap = layer.tilemap
  local mapWidthTiles, mapHeightTiles = tilemap:getSize()
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight

  -- Basic camera-space culling (coarse). We skip tiles unlikely to be visible.
  -- Convert screen rect corners back to approximate world tile coords, clamp, and draw.
  local leftWorld,  topWorld  = self:screenToWorld(0, 0, layer)
  local rightWorld, bottomWorld = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)

  -- Expand a bit to avoid edge gaps from rounding
  local minWorldX = floor(min(leftWorld, rightWorld)) - 2
  local maxWorldX = ceil (max(leftWorld, rightWorld)) + 2
  local minWorldY = floor(min(topWorld, bottomWorld)) - 2
  local maxWorldY = ceil (max(topWorld, bottomWorld)) + 2

  -- Clamp to map bounds (tile coordinates are 1..width/height in tilemap API)
  local minX = max(1, minWorldX + 1)
  local maxX = min(mapWidthTiles, maxWorldX + 1)
  local minY = max(1, minWorldY + 1)
  local maxY = min(mapHeightTiles, maxWorldY + 1)

  for tileY = minY, maxY do
    for tileX = minX, maxX do
      local idx = tilemap:getTileAtPosition(tileX, tileY)
      if idx and idx ~= 0 then
        local screenX, screenY = self:worldToScreen(tileX - 1, tileY - 1, layer)

        -- Tight screen cull for the tile’s image rect
        if not (screenX > DISPLAY_WIDTH or screenY > DISPLAY_HEIGHT or screenX + tileWidth < 0 or screenY + tileHeight < 0) then
          local img = imageTable:getImage(idx)
          if img then
            local offsetX, offsetY = _isoDrawOffsets(tileWidth, tileHeight, img)
            img:draw(screenX + offsetX, screenY + offsetY)
          end
        end
      end
    end
  end
end

-- ! Draw Visible
-- Draw all visible tile layers by z-index
function RoxyIsoTilemap:drawVisible()
  if not self.layers then return end

  -- Collect visible layers
  local list = {}
  for _, layer in pairs(self.layers) do
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
    local imageTable = layer.imageTable
    if imageTable then
      local tilemap = layer.tilemap
      local mapWidthTiles, mapHeightTiles = tilemap:getSize()
      local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  
      -- Coarse camera culling once per layer.
      local leftWorld, topWorld = self:screenToWorld(0, 0, layer)
      local rightWorld, bottomWorld = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)
  
      local minWorldX = floor(min(leftWorld, rightWorld)) - 2
      local maxWorldX = ceil(max(leftWorld, rightWorld)) + 2
      local minWorldY = floor(min(topWorld, bottomWorld)) - 2
      local maxWorldY = ceil(max(topWorld, bottomWorld)) + 2
  
      local minX = max(1, minWorldX + 1)
      local maxX = min(mapWidthTiles,  maxWorldX + 1)
      local minY = max(1, minWorldY + 1)
      local maxY = min(mapHeightTiles, maxWorldY + 1)
  
      for tileY = minY, maxY do
        for tileX = minX, maxX do
          local idx = tilemap:getTileAtPosition(tileX, tileY)
          if idx and idx ~= 0 then
            local screenX, screenY = self:worldToScreen(tileX - 1, tileY - 1, layer)
            if not (screenX > DISPLAY_WIDTH or screenY > DISPLAY_HEIGHT or screenX + tileWidth < 0 or screenY + tileHeight < 0) then
              local img = imageTable:getImage(idx)
              if img then
                local offsetX, offsetY = _isoDrawOffsets(tileWidth, tileHeight, img)
                img:draw(screenX + offsetX, screenY + offsetY)
              end
            end
          end
        end
      end
    end
  end
end
