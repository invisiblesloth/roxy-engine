-- core/tilemaps/RoxyStagTilemap.lua
-- Staggered-Y isometric tilemaps that match Tiled:
-- Only rows whose parity matches Tiled's staggerindex are shifted.
-- Direction is configurable via self.staggerDirection = "left" | "right" (default "right").

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

-- ! Row Shift X for Row 0
-- Return the horizontal row shift (in pixels) for a given 0-based row index.
-- Matches Tiled: shift ONLY rows whose parity equals self.staggerIndex.
local function _rowShiftX_for_row0(self, row0, halfWidth)
  if self.staggerAxis ~= "y" then return 0 end

  local rowIsOdd = (row0 % 2) == 1
  local shouldShift
  if self.staggerIndex == "odd" then
    shouldShift = rowIsOdd
  elseif self.staggerIndex == "even" then
    shouldShift = not rowIsOdd
  else
    shouldShift = false
  end
  if not shouldShift then return 0 end

  local direction = self.staggerDirection or "right"
  return (direction == "right") and (halfWidth) or (-halfWidth)
end

-- ! Get Max Image Height
-- Helper to compute and cache max image height for the layer
local function _getMaxImgHeight(layer)
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

class("RoxyStagTilemap").extends(RoxyTilemap)

function RoxyStagTilemap:init(jsonPath, opts, scene)
  opts = opts or {}
  opts.wrapInSprites = false
  opts.anchor = "topLeft"
  RoxyStagTilemap.super.init(self, jsonPath, opts, scene)

  self._projection = "staggered-y"

  -- Tiled fields read in base class:
  --   self.staggerAxis  -> expected "y"
  --   self.staggerIndex -> "odd" | "even"
  -- Direction knob: which way the shifted rows move horizontally in pixels
  self.staggerDirection = self.staggerDirection or "right" -- "left" | "right"
end

--------------------------------------------------------------------------------
-- Projection (Staggered-Y)
-- Row spacing = halfHeight; Column step = tileWidth.
-- Shift rule (Tiled):
--   If row parity matches staggerIndex -> shift by ±halfWidth (dir knob)
--   Otherwise -> no shift
--------------------------------------------------------------------------------

-- ! World to Screen
function RoxyStagTilemap:worldToScreen(worldX, worldY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local halfWidth, halfHeight = tileWidth * 0.5, tileHeight * 0.5

  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  local row0 = floor(worldY + 1e-6)
  local shiftX = _rowShiftX_for_row0(self, row0, halfWidth)

  -- Parallax-origin pivot to mirror sprite behavior
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local screenX = originX + worldX * tileWidth + shiftX
  local screenY = originY + worldY * halfHeight

  -- Apply pivotAdjust* before subtracting camera
  return round(screenX + pivotAdjustX - cameraX * parallaxX),
         round(screenY + pivotAdjustY - cameraY * parallaxY)
end

-- ! Screen to World
function RoxyStagTilemap:screenToWorld(screenX, screenY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local halfWidth, halfHeight = tileWidth * 0.5, tileHeight * 0.5

  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  -- Parallax-origin pivot to mirror sprite behavior
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  -- Undo camera and pivot before converting to world
  local dx = (screenX + cameraX * parallaxX) - (originX + pivotAdjustX)
  local dy = (screenY + cameraY * parallaxY) - (originY + pivotAdjustY)

  local worldY = dy / halfHeight
  local row0 = floor(worldY + 1e-6)
  local shiftX = _rowShiftX_for_row0(self, row0, halfWidth)

  local worldX = (dx - shiftX) / tileWidth
  return worldX, worldY
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Set Tile At
function RoxyStagTilemap:setTileAt(name, x, y, tileIndex, updateSprite)
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
function RoxyStagTilemap:draw(name)
  local layer = self.layers and self.layers[name]
  if not layer or not layer.tilemap or layer.visible == false then return end

  local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()
  local tileHeight = layer.tileHeight or 0
  local halfHeight = tileHeight * 0.5
  
  -- Get screen corners in world space
  local leftWorld, topWorld = self:screenToWorld(0, 0, layer)
  local rightWorld, bottomWorld = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)
  
  -- Calculate margin based on tallest image (like RoxyIsoTilemap)
  local maxImgH = _getMaxImgHeight(layer)
  local overdraw = max(0, maxImgH - tileHeight)
  local margin = ceil(overdraw / max(1, halfHeight)) + 1
  
  -- Calculate bounds with proper margin
  local minWorldX = min(leftWorld, rightWorld) - margin
  local maxWorldX = max(leftWorld, rightWorld) + margin
  local minWorldY = min(topWorld, bottomWorld) - margin
  local maxWorldY = max(topWorld, bottomWorld) + margin
  
  -- Convert to tile coordinates (1-based)
  local minTileX = max(1, floor(minWorldX) + 1)
  local maxTileX = min(mapWidthTiles, ceil(maxWorldX) + 1)
  local minTileY = max(1, floor(minWorldY) + 1)
  local maxTileY = min(mapHeightTiles, ceil(maxWorldY) + 1)

  self:drawLayerRows(name, minTileY, maxTileY, minTileX, maxTileX)
end

-- ! Draw Visible
function RoxyStagTilemap:drawVisible()
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
    local tileHeight = layer.tileHeight or 0
    local halfHeight = tileHeight * 0.5
    
    -- Get screen corners in world space
    local leftWorld, topWorld = self:screenToWorld(0, 0, layer)
    local rightWorld, bottomWorld = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)
    
    -- Calculate margin based on tallest image
    local maxImgH = _getMaxImgHeight(layer)
    local overdraw = max(0, maxImgH - tileHeight)
    local margin = ceil(overdraw / max(1, halfHeight)) + 1
    
    -- Calculate bounds with proper margin
    local minWorldX = min(leftWorld, rightWorld) - margin
    local maxWorldX = max(leftWorld, rightWorld) + margin
    local minWorldY = min(topWorld, bottomWorld) - margin
    local maxWorldY = max(topWorld, bottomWorld) + margin
    
    -- Convert to tile coordinates (1-based)
    local minTileX = max(1, floor(minWorldX) + 1)
    local maxTileX = min(mapWidthTiles, ceil(maxWorldX) + 1)
    local minTileY = max(1, floor(minWorldY) + 1)
    local maxTileY = min(mapHeightTiles, ceil(maxWorldY) + 1)

    self:drawLayerRows(layer.name, minTileY, maxTileY, minTileX, maxTileX)
  end
end

-- ! Draw Layer Rows
function RoxyStagTilemap:drawLayerRows(layerName, minRow, maxRow, minCol, maxCol)
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

  local rowStart = max(1, minRow or 1)
  local rowEnd   = min(mapHeightTiles, maxRow or mapHeightTiles)
  if rowStart > rowEnd then _endManualDraw(restoreX, restoreY); return end

  -- Use passed column bounds if provided, otherwise calculate them
  local minX, maxX
  if minCol and maxCol then
    minX = max(1, minCol)
    maxX = min(mapWidthTiles, maxCol)
  else
    -- Fallback to old calculation for backwards compatibility
    local leftWorld, topWorld = self:screenToWorld(0, 0, layer)
    local rightWorld, bottomWorld = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)
    local minWorldX = floor(min(leftWorld, rightWorld)) - 2
    local maxWorldX = ceil (max(leftWorld, rightWorld)) + 2
    minX = max(1, minWorldX + 1)
    maxX = min(mapWidthTiles, maxWorldX + 1)
  end

  if minX > maxX then _endManualDraw(restoreX, restoreY); return end

  local tiles, widthFromTileMap = tilemap:getTiles()
  local stride = widthFromTileMap or mapWidthTiles

  -- Use the same pivot adjust as worldToScreen/sprite path (like RoxyIsoTilemap)
  local originX, originY = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local parallaxOriginX = layer.parallaxoriginx or 0
  local parallaxOriginY = layer.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)
  
  local cameraX, cameraY = getCameraPosition()
  local halfHeight, halfWidth = tileHeight * 0.5, tileWidth * 0.5

  for tileY = rowStart, rowEnd do
    local row0 = tileY - 1
    local rowShiftX = _rowShiftX_for_row0(self, row0, halfWidth)

    -- Apply pivot adjustments consistently
    local baseScreenX = round(originX + rowShiftX + pivotAdjustX - cameraX * parallaxX)
    local baseScreenY = round(originY + row0 * halfHeight + pivotAdjustY - cameraY * parallaxY)

    local currentX = baseScreenX + (minX - 1) * tileWidth
    local currentY = baseScreenY

    local i = row0 * stride + minX
    for tileX = minX, maxX do
      local idx = tiles and tiles[i] or 0
      if idx and idx ~= 0 then
        local img = cache[idx]
        if not img then img = imageTable:getImage(idx); cache[idx] = img end
        if img then
          local offX, offY = _isoDrawOffsets(tileWidth, tileHeight, img)
          local drawX, drawY = currentX + offX, currentY + offY
          local imgWidth, imgHeight = img:getSize()
          if not (drawX > DISPLAY_WIDTH or drawY > DISPLAY_HEIGHT or
                  drawX + imgWidth < 0 or drawY + imgHeight < 0) then
            img:draw(drawX, drawY)
          end
        end
      end

      currentX = currentX + tileWidth
      i += 1
    end
  end

  _endManualDraw(restoreX, restoreY)
end

-- ! Get Row From Screen
function RoxyStagTilemap:getRowFromScreen(screenX, screenY, layerName)
  local targetLayer = self.layers and self.layers[layerName]
  if not targetLayer then
    for _, layer in pairs(self.layers or {}) do if layer.tilemap then targetLayer = layer; break end end
    if not targetLayer then return 1 end
  end

  local _, mapHeightTiles = targetLayer.tilemap:getSize()
  local _, worldY = self:screenToWorld(screenX, screenY, targetLayer)
  local row = floor(worldY + 1)
  if row < 1 then row = 1 elseif row > mapHeightTiles then row = mapHeightTiles end
  return row
end
