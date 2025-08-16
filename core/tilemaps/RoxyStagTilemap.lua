-- core/tilemaps/RoxyStagTilemap.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
local Camera  <const> = r.Camera
local Cache   <const> = roxy.Cache

local min   <const> = math.min
local max   <const> = math.max
local floor <const> = math.floor
local ceil  <const> = math.ceil
local round <const> = r.Math.round

local tableInsert <const> = table.insert
local tableSort   <const> = table.sort

local pushContext   <const> = Graphics.pushContext
local popContext    <const> = Graphics.popContext
local setClipRect   <const> = Graphics.setClipRect
local clearClipRect <const> = Graphics.clearClipRect
local newImage      <const> = Graphics.image.new
local clear         <const> = Graphics.clear

local addDirtyRect <const> = Sprite.addDirtyRect

local newCacheBucket  <const> = Cache.newBucket
local getOrLoadAsset  <const> = Cache.getOrLoadAsset
local evictAsset      <const> = Cache.evictAsset
local clearCache      <const> = Cache.clearCache

local getCameraPosition <const> = Camera.getPosition

local _isoDrawOffsets   <const> = RoxyTilemap._isoDrawOffsets
local _beginManualDraw  <const> = RoxyTilemap._beginManualDraw
local _endManualDraw    <const> = RoxyTilemap._endManualDraw

-- Default chunk settings
local DEFAULT_CHUNK_SIZE    <const> = 320
local DEFAULT_CHUNK_CACHE   <const> = 72
local DEFAULT_CHUNK_OVERLAP <const> = 32

-- Coarse safety margin (in tiles) for dynamic fallback culling
local TILE_MARGIN <const> = 2

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local COLOR_CLEAR <const> = Graphics.kColorClear

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Row Shift X for Row 0
-- Shift in pixels for a 0-based row index (Tiled staggered-y)
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
  return (direction == "right") and halfWidth or -halfWidth
end

-- ! Visible Layer Rectangle
-- Compute visible layer-space rect
local function _visibleLayerRect(self, layer)
  local screenX, screenY = self:worldToScreen(0, 0, layer)
  -- screen shows [0..W, 0..H]
  -- which corresponds to layer pixels [-screenX..-screenX+W, -screenY..-screenY+H]
  return floor(-screenX), floor(-screenY), DISPLAY_WIDTH, DISPLAY_HEIGHT
end

-- ! Chunk Indices for Rect
-- Which chunk indices intersect a pixel rect?
local function _chunkIndicesForRect(x, y, width, height, size)
  local minChunkX = floor(x / size)
  local maxChunkX = floor((x + width  - 1) / size)
  local minChunkY = floor(y / size)
  local maxChunkY = floor((y + height - 1) / size)
  return minChunkX, maxChunkX, minChunkY, maxChunkY
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
  self.staggerAxis = self.staggerAxis or "y"
  self.staggerDirection = self.staggerDirection or "right" -- "left" | "right"

  self._staticChunkLayers = {}  -- name --> { layer, size, overlap, chunkBucket }
  self._orderedLayers     = {}  -- array of { layer, type="chunked" | "dynamic" }

  self._mapCacheId = jsonPath or tostring(self) -- Used only for namespacing keys

  self:_initializeStaticLayers(opts)
  self:_rebuildOrderedLayers()
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

-- ! Initialize Static Layers
-- Build chunk/static config per layer
function RoxyStagTilemap:_initializeStaticLayers(opts)
  local layerOptions = (opts and opts.layerOptions) or {}
  local totalChunkCache = opts.totalChunkCache or DEFAULT_CHUNK_CACHE

  -- One shared bucket for all chunk images on this map
  self._globalChunkBucket = newCacheBucket(totalChunkCache)

  for layerName, layer in pairs(self.layers) do
    local layerOpts = layerOptions[layerName] or {}
    if layerOpts.preRenderChunked then
      self._staticChunkLayers[layerName] = {
        name      = layerName,
        layer     = layer,
        size      = max(1, layerOpts.chunkSizePx or DEFAULT_CHUNK_SIZE),
        overlap   = layerOpts.overlapPx or DEFAULT_CHUNK_OVERLAP,
        keyPrefix = "chunk:" .. (self._mapCacheId or "map") .. ":" ..
                    tostring(layer.tiledId or layerName) .. ":",
      }
      Log.debug("keyPrefix: " .. self._staticChunkLayers[layerName].keyPrefix) --#DEBUG
    end
  end
end

-- ! Get or Build Chunk
-- Build or fetch a prerendered chunk image from the cache
function RoxyStagTilemap:_getOrBuildChunk(layerInfo, chunkX, chunkY)
  local key = layerInfo.keyPrefix .. chunkX .. ":" .. chunkY
  return getOrLoadAsset(self._globalChunkBucket, key, function()
    local size, overlap = layerInfo.size, layerInfo.overlap
    local width, height = size + 2 * overlap, size + 2 * overlap
    local img = newImage(width, height)

    -- Convert chunk indices to layer pixel origin for this chunk
    local px = chunkX * size - overlap
    local py = chunkY * size - overlap

    pushContext(img)
      setClipRect(0, 0, width, height)
      clear(COLOR_CLEAR)
      self:_renderLayerToBuffer(layerInfo.layer, -px, -py, width, height)
      clearClipRect()
    popContext()

    return img
  end)
end

-- ! Rebuild Ordered Layers
-- Build a stable, z-sorted draw list once (rarely changes)
function RoxyStagTilemap:_rebuildOrderedLayers()
  local items = {}
  for name, layer in pairs(self.layers) do
    if layer.tilemap and layer.visible ~= false then
      local renderType = self._staticChunkLayers[name] and "chunked" or "dynamic"
      tableInsert(items, { layer = layer, name = name, type = renderType, z = layer.zIndex or 0 })
    end
  end
  tableSort(items, function(a, b) return a.z < b.z end)
  self._orderedLayers = items
end

--------------------------------------------------------------------------------
-- Chunk building & drawing
--------------------------------------------------------------------------------

-- ! Render Layer to Buffer
-- Render a layer directly to a buffer context (in layer-local coordinates)
function RoxyStagTilemap:_renderLayerToBuffer(layer, offsetX, offsetY, bufferWidth, bufferHeight)
  local tilemap     = layer.tilemap
  local imageTable  = layer.imageTable
  if not tilemap or not imageTable then return end

  local len = imageTable:getLength()
  local mapWidthTiles, mapHeightTiles = tilemap:getSize()
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local halfWidth, halfHeight = tileWidth * 0.5, tileHeight * 0.5

  -- Parity helper (odd rows shift by half tile width)
  local function rowShiftX(row0) return (row0 % 2 == 0) and 0 or halfWidth end

  -- How tall can any tile image be? (margin for tall isometric art)
  local maxImgH = layer.maxImgH or 0
  local overdrawRows = ceil(max(0, maxImgH - tileHeight) / max(1, halfHeight)) + 1

  -- Row range that can touch this buffer (layer-local coords)
  -- drawY = row0 * halfHeight + offsetY
  local minRow0 = floor((-offsetY - maxImgH) / halfHeight) - 1
  local maxRow0 = ceil ((bufferHeight - offsetY) / halfHeight) + 1
  minRow0 = max(0, minRow0 - overdrawRows)
  maxRow0 = min(mapHeightTiles - 1, maxRow0 + overdrawRows)

  -- Flat tiles + stride (fallback to map width)
  local tiles  = layer.tilesFlat
  local stride = layer.tilesStride or mapWidthTiles

  -- Per-tile offset cache (avoid repeated _isoDrawOffsets calls)
  local offCache = layer._offCache
  if not offCache then
    offCache = {}
    layer._offCache = offCache
  end

  for row0 = minRow0, maxRow0 do
    local baseX = rowShiftX(row0) + offsetX
    local baseY = row0 * halfHeight + offsetY

    -- In this row, drawX = baseX + (tileX-1)*tileWidth
    -- Choose tiles whose drawX overlaps the buffer with a 1-tile margin
    local minTileX = floor((-tileWidth - baseX) / tileWidth)       -- 0-based col
    local maxTileX = floor((bufferWidth - 1 - baseX) / tileWidth)  -- 0-based col
    minTileX = max(0, minTileX - 1)
    maxTileX = min(mapWidthTiles - 1, maxTileX + 1)

    if minTileX <= maxTileX then
      local rowIndex = row0 * stride + (minTileX + 1) -- tiles[] is 1-based
      local drawX    = baseX + minTileX * tileWidth

      for col0 = minTileX, maxTileX do
        local tileIndex = tiles and tiles[rowIndex] or 0
        if tileIndex and tileIndex > 0 and tileIndex <= len then
          local img = layer._imgCache[tileIndex]
          if not img then
            img = imageTable:getImage(tileIndex)
            layer._imgCache[tileIndex] = img
          end

          if img then
            -- cached isometric draw offsets per tileIndex
            local offX, offY = offCache[tileIndex]
            if not offX then
              offX, offY = _isoDrawOffsets(tileWidth, tileHeight, img)
              offCache[tileIndex] = offX
              offCache[tileIndex + 0.5] = offY -- cheap 2nd key to store Y
            else
              offY = offCache[tileIndex + 0.5]
            end

            local dx, dy = drawX + offX, baseY + offY
            -- Quick clip against the buffer (0..bufferWidth/Height)
            if dx < bufferWidth and dy < bufferHeight and dx > -tileWidth and dy > -tileHeight then
              img:draw(dx, dy)
            end
          end
        end
        rowIndex = rowIndex + 1
        drawX    = drawX + tileWidth
      end
    end
  end
end

-- ! Draw Static Layer Chunked
function RoxyStagTilemap:_drawStaticLayerChunked(layerName)
  local layerInfo = self._staticChunkLayers[layerName]
  if not layerInfo then return end

  local layer   = layerInfo.layer
  local size    = layerInfo.size
  local overlap = layerInfo.overlap

  -- Visible rect in layer coordinates (inflate by overlap)
  local vx, vy, vw, vh = _visibleLayerRect(self, layer)
  vx = vx - overlap; vy = vy - overlap
  vw = vw + 2 * overlap; vh = vh + 2 * overlap

  local minCX, maxCX, minCY, maxCY = _chunkIndicesForRect(vx, vy, vw, vh, size)
  local screenX, screenY = self:worldToScreen(0, 0, layer)

  for cy = minCY, maxCY do
    local rowDestY = cy * size - overlap + screenY
    for cx = minCX, maxCX do
      local img = self:_getOrBuildChunk(layerInfo, cx, cy)
      if img then
        local destX = cx * size - overlap + screenX
        local destY = rowDestY

        -- Simple on-screen test, but DO NOT modify the clip rect here.
        local iw, ih = img:getSize()
        if not (destX >= DISPLAY_WIDTH or destY >= DISPLAY_HEIGHT
             or destX + iw <= 0      or destY + ih <= 0) then
          img:draw(destX, destY)
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Projection (Staggered-Y)
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
-- Override setTileAt to handle static layer updates
function RoxyStagTilemap:setTileAt(layerName, x, y, tileIndex, updateSprite)
  local layer = self.layers and self.layers[layerName]
  if not layer then return end
  layer.tilemap:setTileAtPosition(x, y, tileIndex)

  -- Mark region as dirty for static layers
  if self._staticChunkLayers[layerName] then
    self:markTilesDirty(layerName, x, y, 1, 1)
  end

  if updateSprite and layer.imageTable then
    local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
    local screenX, screenY = self:worldToScreen(x - 1, y - 1, layer)
    addDirtyRect(screenX, screenY, tileWidth, tileHeight)
  end
end

-- ! Get Row From Screen
function RoxyStagTilemap:getRowFromScreen(screenX, screenY, layerName)
  local targetLayer = self.layers and self.layers[layerName]
  if not targetLayer then
    for _, layer in pairs(self.layers or {}) do
      if layer.tilemap then targetLayer = layer; break end
    end
    if not targetLayer then return 1 end
  end

  local _, mapHeightTiles = targetLayer.tilemap:getSize()
  local _, worldY = self:screenToWorld(screenX, screenY, targetLayer)
  local row = floor(worldY + 1)
  if row < 1 then row = 1 elseif row > mapHeightTiles then row = mapHeightTiles end
  return row
end

-- ! Resort Layers
function RoxyStagTilemap:resortLayers()
  self:_rebuildOrderedLayers()
end

-- ! Mark Tiles Dirty
-- Tile edits --> evict overlapping chunks (they will rebuild lazily)
function RoxyStagTilemap:markTilesDirty(layerName, tileX, tileY, tileCountWidth, tileCountHeight)
  local layerInfo = self._staticChunkLayers[layerName]
  if not layerInfo then return end

  -- Calculate affected chunks and evict from global bucket
  local tileWidth, tileHeight = layerInfo.layer.tileWidth, layerInfo.layer.tileHeight
  local pixelX = (tileX - 1) * tileWidth
  local pixelY = (tileY - 1) * (tileHeight * 0.5)
  local pixelWidth = (tileCountWidth or 1) * tileWidth
  local pixelHeight = (tileCountHeight or 1) * (tileHeight * 0.5)

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    _chunkIndicesForRect(pixelX, pixelY, pixelWidth, pixelHeight, layerInfo.size)
  for chunkY = minY, maxY do
    for chunkX = minX, maxX do
      evictAsset(self._globalChunkBucket, layerInfo.keyPrefix .. chunkX .. ":" .. chunkY)
    end
  end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- ! Draw
function RoxyStagTilemap:draw(layerName)
  if self._staticChunkLayers[layerName] then
    self:_drawStaticLayerChunked(layerName); return
  end

  -- Dynamic fallback (rare):
  -- draw only visible rows/cols with coarse margin
  local layer = self.layers and self.layers[layerName]
  if not layer or not layer.tilemap or layer.visible == false then return end

  local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()
  local tileHeight = layer.tileHeight or 0
  local halfHeight = tileHeight * 0.5

  local leftWorld, topWorld = self:screenToWorld(0, 0, layer)
  local rightWorld, bottomWorld = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)

  local margin = TILE_MARGIN

  local minWorldX = min(leftWorld, rightWorld) - margin
  local maxWorldX = max(leftWorld, rightWorld) + margin
  local minWorldY = min(topWorld, bottomWorld) - margin
  local maxWorldY = max(topWorld, bottomWorld) + margin

  local minTileX = max(1, floor(minWorldX) + 1)
  local maxTileX = min(mapWidthTiles, ceil(maxWorldX) + 1)
  local minTileY = max(1, floor(minWorldY) + 1)
  local maxTileY = min(mapHeightTiles, ceil(maxWorldY) + 1)

  self:drawLayerRows(layerName, minTileY, maxTileY, minTileX, maxTileX)
end

-- ! Draw Visible
-- Straight loop using pre-sorted layers
function RoxyStagTilemap:drawVisible()
  local ordered = self._orderedLayers
  for i = 1, #ordered do
    local item = ordered[i]
    if item.type == "chunked" then
      self:_drawStaticLayerChunked(item.name)
    else
      self:draw(item.name)
    end
  end
end

-- ! Draw Visible in Rectangle
-- Draw Visible in Rectangle (unchanged structure, keep the outer clip only)
function RoxyStagTilemap:drawVisibleInRect(x, y, width, height)
  setClipRect(x, y, width, height)
    self:drawVisible()
  clearClipRect()
end

-- ! Draw Layer Rows
-- Dynamic row/column renderer (no per-tile img:getSize culling)
function RoxyStagTilemap:drawLayerRows(layerName, minRow, maxRow, minColumn, maxColumn)
  local restoreX, restoreY = _beginManualDraw()

  local layer = self.layers and self.layers[layerName]
  if not layer or not layer.tilemap or layer.visible == false then
    _endManualDraw(restoreX, restoreY); return
  end

  local imageTable = layer.imageTable
  if not imageTable then
    _endManualDraw(restoreX, restoreY); return
  end

  local len = imageTable:getLength()
  local tilemap = layer.tilemap
  local mapWidthTiles, mapHeightTiles = tilemap:getSize()
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight

  local rowStart = max(1, minRow or 1)
  local rowEnd = min(mapHeightTiles, maxRow or mapHeightTiles)
  if rowStart > rowEnd then _endManualDraw(restoreX, restoreY); return end

  local minX, maxX
  if minColumn and maxColumn then
    minX = max(1, minColumn)
    maxX = min(mapWidthTiles, maxColumn)
  else
    -- Fallback to coarse bounds if none provided
    local leftWorld, topWorld = self:screenToWorld(0, 0, layer)
    local rightWorld, bottomWorld = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)
    local minWorldX = floor(min(leftWorld, rightWorld)) - 2
    local maxWorldX = ceil (max(leftWorld, rightWorld)) + 2
    minX = max(1, minWorldX + 1)
    maxX = min(mapWidthTiles, maxWorldX + 1)
  end
  if minX > maxX then _endManualDraw(restoreX, restoreY); return end

  local tiles = layer.tilesFlat
  local stride = layer.tilesStride

  -- Hoisted transforms
  local originX, originY      = layer.originX or 0, layer.originY or 0
  local parallaxX, parallaxY  = layer.parallaxx or 1, layer.parallaxy or 1
  local parallaxOriginX       = layer.parallaxoriginx or 0
  local parallaxOriginY       = layer.parallaxoriginy or 0
  local pivotAdjustX          = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY          = parallaxOriginY * (1 - parallaxY)
  local cameraX, cameraY      = getCameraPosition()
  local halfHeight, halfWidth = tileHeight * 0.5, tileWidth * 0.5

  local tilesetKeyPrefix = "tilesetimg:" .. tostring(imageTable) .. ":"

  for tileY = rowStart, rowEnd do
    local row0 = tileY - 1
    local rowShiftX = _rowShiftX_for_row0(self, row0, halfWidth)

    local baseScreenX = round(originX + rowShiftX + pivotAdjustX - cameraX * parallaxX)
    local baseScreenY = round(originY + row0 * halfHeight + pivotAdjustY - cameraY * parallaxY)

    local currentX = baseScreenX + (minX - 1) * tileWidth
    local rowIndex = row0 * stride + minX

    for tileX = minX, maxX do
      local tileIndex = tiles and tiles[rowIndex] or 0
      if tileIndex and tileIndex > 0 and tileIndex <= len then
        local key = tilesetKeyPrefix .. tileIndex
        local img = getOrLoadAsset(key, function() return imageTable:getImage(tileIndex) end)
        if img then
          local offX, offY = _isoDrawOffsets(tileWidth, tileHeight, img)
          img:draw(currentX + offX, baseScreenY + offY)
        end
      end
      currentX += tileWidth
      rowIndex += 1
    end
  end

  _endManualDraw(restoreX, restoreY)
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- Clean up static layer resources
function RoxyStagTilemap:destroy()
  if self._globalChunkBucket then
    clearCache(self._globalChunkBucket)
    self._globalChunkBucket = nil
  end
  self._staticChunkLayers = {}
  self._orderedLayers = {}
  RoxyStagTilemap.super.destroy(self)
end
