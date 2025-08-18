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
local DEFAULT_CHUNK_CACHE   <const> = 200
local DEFAULT_CHUNK_OVERLAP <const> = 32

-- Coarse safety margin (in tiles) for dynamic fallback culling
local TILE_MARGIN <const> = 0.5

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local COLOR_CLEAR <const> = Graphics.kColorClear

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Row Shift X for Row 0
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

-- ! Helper: Visible Layer Rectangle
-- Compute visible layer-space rect
local function _visibleLayerRect(self, layer)
  local screenX, screenY = self:worldToScreen(0, 0, layer)
  -- screen shows [0..width, 0..height]
  -- which corresponds to layer pixels [-screenX..-screenX+width, -screenY..-screenY+height]
  return floor(-screenX), floor(-screenY), DISPLAY_WIDTH, DISPLAY_HEIGHT
end

-- ! Helper: Chunk Indices for Rect
-- Which chunk indices intersect a pixel rect?
local function _chunkIndicesForRect(x, y, width, height, size)
  local minChunkX = floor(x / size)
  local maxChunkX = floor((x + width  - 1) / size)
  local minChunkY = floor(y / size)
  local maxChunkY = floor((y + height - 1) / size)
  return minChunkX, maxChunkX, minChunkY, maxChunkY
end

-- ! Helper: Find First Available Layer
-- Extracted repeated layer finding logic
local function _findFirstAvailableLayer(layers)
  for _, layer in pairs(layers or {}) do
    if layer.tilemap then return layer end
  end
  return nil
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

  -- Static / chunk config and ordered layers
  self._staticChunkLayers = {}
  self._orderedLayers = {}

  -- Map-scoped cache key namespace
  self._mapCacheId = jsonPath or tostring(self)

  self:_initializeStaticLayers(opts)
  for _, layerData in pairs(self.layers) do
    if layerData.tilemap then
      self:_preloadLayerCaches(layerData)
    end
  end

  self:_rebuildOrderedLayers()
end

--------------------------------------------------------------------------------
-- Static Layer Configuration
--------------------------------------------------------------------------------

-- ! Utility: Initialize Static Layers
-- Build chunk/static configuration per layer
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
    end
  end
end

-- ! Utility: Rebuild Ordered Layers
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

-- ! Utility: Preload Layer Caches
function RoxyStagTilemap:_preloadLayerCaches(layerData)
  if not layerData.imageTable or not layerData.tileWidth or not layerData.tileHeight then return end

  local n = layerData.imageCount
  layerData._imageCache = {} -- Overwrite if exists to ensure fresh
  layerData._offsetCache = {}

  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight

  for i = 1, n do
    local img = layerData.imageTable:getImage(i)
    if img then
      layerData._imageCache[i] = img
      local offsetX, offsetY = _isoDrawOffsets(tileWidth, tileHeight, img)
      layerData._offsetCache[i] = offsetX
      layerData._offsetCache[i + 0.5] = offsetY
    end
  end
end

--------------------------------------------------------------------------------
-- Chunk building & drawing
--------------------------------------------------------------------------------

-- ! Utility: Get or Build Chunk
-- Build or fetch a prerendered chunk image from the cache
function RoxyStagTilemap:_getOrBuildChunk(layerData, chunkX, chunkY)
  local key = layerData.keyPrefix .. chunkX .. ":" .. chunkY
  return getOrLoadAsset(self._globalChunkBucket, key, function()
    local size, overlap = layerData.size, layerData.overlap
    local width, height = size + 2 * overlap, size + 2 * overlap
    local img = newImage(width, height)

    -- Convert chunk indices to layer pixel origin for this chunk
    local pixelX = chunkX * size - overlap
    local pixelY = chunkY * size - overlap

    pushContext(img)
      setClipRect(0, 0, width, height)
      clear(COLOR_CLEAR)
      self:_renderLayerToBuffer(layerData.layer, -pixelX, -pixelY, width, height)
      clearClipRect()
    popContext()

    return img
  end)
end

-- ! Utility: Render Layer to Buffer
-- Render a layer directly to a buffer context (in layer-local coordinates)
function RoxyStagTilemap:_renderLayerToBuffer(layerData, offsetX, offsetY, bufferWidth, bufferHeight)
  local imageTable = layerData.imageTable
  local mapWidth, mapHeight = layerData.mapWidth, layerData.mapHeight
  if not mapWidth or not mapHeight or not imageTable then return end

  local n = layerData.imageCount
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  -- Parity helper (odd rows shift by half tile width)
  local function rowShiftX(row0) return (row0 % 2 == 0) and 0 or halfWidth end

  -- How tall can any tile image be? (margin for tall isometric art)
  local maxImageHeight = layerData.maxImgH or 0
  local overdrawRows = ceil(max(0, maxImageHeight - tileHeight) / max(1, halfHeight)) + 1

  -- Row range that can touch this buffer (layer-local coords)
  -- drawY = row0 * halfHeight + offsetY
  local minRow0 = floor((-offsetY - maxImageHeight) / halfHeight) - 1
  local maxRow0 = ceil ((bufferHeight - offsetY) / halfHeight) + 1
  minRow0 = max(0, minRow0 - overdrawRows)
  maxRow0 = min(mapHeight - 1, maxRow0 + overdrawRows)

  -- Flat tiles + stride (fallback to map width)
  local tiles  = layerData.tilesFlat
  local stride = layerData.tilesStride or mapWidth

  -- Per-tile offset cache (avoid repeated _isoDrawOffsets calls)
  local offsetCache = layerData._offsetCache
  if not offsetCache then
    offsetCache = {}
    layerData._offsetCache = offsetCache
  end

  for row0 = minRow0, maxRow0 do
    local baseX = rowShiftX(row0) + offsetX
    local baseY = row0 * halfHeight + offsetY

    -- In this row, drawX = baseX + (tileX-1)*tileWidth
    -- Choose tiles whose drawX overlaps the buffer with a 1-tile margin
    local minTileX = floor((-tileWidth - baseX) / tileWidth)      -- 0-based col
    local maxTileX = floor((bufferWidth - 1 - baseX) / tileWidth) -- 0-based col
    minTileX = max(0, minTileX - 1)
    maxTileX = min(mapWidth - 1, maxTileX + 1)

    if minTileX <= maxTileX then
      local rowIndex = row0 * stride + (minTileX + 1) -- tiles[] is 1-based
      local drawX = baseX + minTileX * tileWidth

      for col0 = minTileX, maxTileX do
        local tileIndex = tiles and tiles[rowIndex] or 0
        if tileIndex and tileIndex > 0 and tileIndex <= n then
          local img = layerData._imageCache[tileIndex]
          if not img then
            img = imageTable:getImage(tileIndex)
            layerData._imageCache[tileIndex] = img
          end

          if img then
            -- Cached isometric draw offsets per tileIndex
            local offsetX, offsetY = offsetCache[tileIndex]
            if not offsetX then
              offsetX, offsetY = _isoDrawOffsets(tileWidth, tileHeight, img)
              offsetCache[tileIndex] = offsetX
              offsetCache[tileIndex + 0.5] = offsetY -- Cheap 2nd key to store Y
            else
              offsetY = offsetCache[tileIndex + 0.5]
            end

            local drawPositionX, drawPositionY = drawX + offsetX, baseY + offsetY
            -- Quick clip against the buffer (0..bufferWidth/Height)
            if drawPositionX < bufferWidth and drawPositionY < bufferHeight
            and drawPositionX > -tileWidth and drawPositionY > -tileHeight then
              img:draw(drawPositionX, drawPositionY)
            end
          end
        end
        rowIndex += 1
        drawX += tileWidth
      end
    end
  end
end

-- ! Utility: Draw Static Layer Chunked
-- Render a chunked layer using prebuilt chunk images
function RoxyStagTilemap:_drawStaticLayerChunked(layerName)
  local currentLayer = self._staticChunkLayers[layerName]
  if not currentLayer then return end

  local layer   = currentLayer.layer
  local size    = currentLayer.size
  local overlap = currentLayer.overlap

  -- Visible rect in layer coordinates (inflate by overlap)
  local visibleX, visibleY, visibleWidth, visibleHeight = _visibleLayerRect(self, layer)
  visibleX -= overlap; visibleY -= overlap
  visibleWidth += 2 * overlap; visibleHeight += 2 * overlap

  local minChunkX, maxChunkX, minChunkY, maxChunkY = _chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)
  local screenX, screenY = self:worldToScreen(0, 0, layer)

  for chunkY = minChunkY, maxChunkY do
    local rowDestY = chunkY * size - overlap + screenY
    for chunkX = minChunkX, maxChunkX do
      local img = self:_getOrBuildChunk(currentLayer, chunkX, chunkY)
      if img then
        local destX = chunkX * size - overlap + screenX
        local destY = rowDestY

        -- Simple on-screen test
        local imageWidth, imageHeight = img:getSize()
        if not (destX >= DISPLAY_WIDTH or destY >= DISPLAY_HEIGHT
             or destX + imageWidth <= 0 or destY + imageHeight <= 0) then
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
-- Convert world coordinates to screen coordinates with parallax support
function RoxyStagTilemap:worldToScreen(worldX, worldY, layerData)
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  local originX, originY = layerData.originX or 0, layerData.originY or 0
  local parallaxX, parallaxY = layerData.parallaxx or 1, layerData.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  local row0 = floor(worldY + 1e-6)
  local shiftX = _rowShiftX_for_row0(self, row0, halfWidth)

  -- Parallax-origin pivot to mirror sprite behavior
  local parallaxOriginX = layerData.parallaxoriginx or 0
  local parallaxOriginY = layerData.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local screenX = originX + worldX * tileWidth + shiftX
  local screenY = originY + worldY * halfHeight

  -- Apply pivotAdjust* before subtracting camera
  return round(screenX + pivotAdjustX - cameraX * parallaxX),
         round(screenY + pivotAdjustY - cameraY * parallaxY)
end

-- ! Screen to World
-- Convert screen coordinates to world coordinates with parallax support
function RoxyStagTilemap:screenToWorld(screenX, screenY, layerData)
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  local originX, originY = layerData.originX or 0, layerData.originY or 0
  local parallaxX, parallaxY = layerData.parallaxx or 1, layerData.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  -- Parallax-origin pivot to mirror sprite behavior
  local parallaxOriginX = layerData.parallaxoriginx or 0
  local parallaxOriginY = layerData.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  -- Undo camera and pivot before converting to world
  local deltaX = (screenX + cameraX * parallaxX) - (originX + pivotAdjustX)
  local deltaY = (screenY + cameraY * parallaxY) - (originY + pivotAdjustY)

  local worldY = deltaY / halfHeight
  local row0 = floor(worldY + 1e-6)
  local shiftX = _rowShiftX_for_row0(self, row0, halfWidth)

  local worldX = (deltaX - shiftX) / tileWidth
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
-- Determine which tile row corresponds to screen coordinates
function RoxyStagTilemap:getRowFromScreen(screenX, screenY, layerName)
  local targetLayer = self.layers and self.layers[layerName]
  if not targetLayer then
    targetLayer = _findFirstAvailableLayer(self.layers)
    if not targetLayer then return 1 end
  end

  local _, mapHeightTiles = targetLayer.tilemap:getSize()
  local _, worldY = self:screenToWorld(screenX, screenY, targetLayer)
  local row = floor(worldY + 1)
  if row < 1 then row = 1 elseif row > mapHeightTiles then row = mapHeightTiles end
  return row
end

-- ! Resort Layers
-- Rebuild the layer drawing order (call after changing layer z-indices)
function RoxyStagTilemap:resortLayers()
  self:_rebuildOrderedLayers()
end

-- ! Mark Tiles Dirty
-- Tile edits --> evict overlapping chunks (they will rebuild lazily)
function RoxyStagTilemap:markTilesDirty(layerName, tileX, tileY, tileCountWidth, tileCountHeight)
  local currentLayer = self._staticChunkLayers[layerName]
  if not currentLayer then return end

  -- Calculate affected chunks and evict from global bucket
  local tileWidth, tileHeight = currentLayer.layer.tileWidth, currentLayer.layer.tileHeight
  local pixelX = (tileX - 1) * tileWidth
  local pixelY = (tileY - 1) * (tileHeight * 0.5)
  local pixelWidth = (tileCountWidth or 1) * tileWidth
  local pixelHeight = (tileCountHeight or 1) * (tileHeight * 0.5)

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    _chunkIndicesForRect(pixelX, pixelY, pixelWidth, pixelHeight, currentLayer.size)
  for chunkY = minChunkY, maxChunkY do
    for chunkX = minChunkX, maxChunkX do
      evictAsset(self._globalChunkBucket, currentLayer.keyPrefix .. chunkX .. ":" .. chunkY)
    end
  end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- ! Draw
-- Draw a single layer (chunked or dynamic fallback)
function RoxyStagTilemap:draw(layerName)
  if self._staticChunkLayers[layerName] then
    self:_drawStaticLayerChunked(layerName); return
  end

  -- Dynamic fallback (rare):
  -- draw only visible rows/cols with coarse margin
  local layerData = self.layers and self.layers[layerName]
  if not layerData or not layerData.tilemap or layerData.visible == false then return end

  local mapWidth, mapHeight = layerData.mapWidth, layerData.mapHeight
  local tileHeight = layerData.tileHeight or 0

  local leftWorld, topWorld = self:screenToWorld(0, 0, layerData)
  local rightWorld, bottomWorld = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layerData)

  local margin = TILE_MARGIN

  local minWorldX = min(leftWorld, rightWorld) - margin
  local maxWorldX = max(leftWorld, rightWorld) + margin
  local minWorldY = min(topWorld, bottomWorld) - margin
  local maxWorldY = max(topWorld, bottomWorld) + margin

  local minTileX = max(1, floor(minWorldX) + 1)
  local maxTileX = min(mapWidth, ceil(maxWorldX) + 1)
  local minTileY = max(1, floor(minWorldY) + 1)
  local maxTileY = min(mapHeight, ceil(maxWorldY) + 1)

  self:drawLayerRows(layerName, minTileY, maxTileY, minTileX, maxTileX)
end

-- ! Draw Visible
-- Draw all visible layers in the correct z-order
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
-- Draw visible layers within a clipping rectangle
function RoxyStagTilemap:drawVisibleInRect(x, y, width, height)
  setClipRect(x, y, width, height)
    self:drawVisible()
  clearClipRect()
end

-- ! Draw Layer Rows
-- Dynamic row/column renderer with manual sprite positioning
function RoxyStagTilemap:drawLayerRows(layerName, minRow, maxRow, minColumn, maxColumn)
  local restoreX, restoreY = _beginManualDraw()

  local layerData = self.layers and self.layers[layerName]
  if not layerData or not layerData.tilemap or layerData.visible == false then
    _endManualDraw(restoreX, restoreY); return
  end

  local imageTable = layerData.imageTable
  if not imageTable then
    _endManualDraw(restoreX, restoreY); return
  end

  local n = layerData.imageCount
  local mapWidth, mapHeight = layerData.mapWidth, layerData.mapHeight
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight

  local rowStart = max(1, minRow or 1)
  local rowEnd = min(mapHeight, maxRow or mapHeight)
  if rowStart > rowEnd then _endManualDraw(restoreX, restoreY); return end

  local minX, maxX
  if minColumn and maxColumn then
    minX = max(1, minColumn)
    maxX = min(mapWidth, maxColumn)
  else
    -- Fallback to coarse bounds if none provided
    local leftWorld, topWorld = self:screenToWorld(0, 0, layerData)
    local rightWorld, bottomWorld = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layerData)
    local minWorldX = floor(min(leftWorld, rightWorld)) - 2
    local maxWorldX = ceil(max(leftWorld, rightWorld)) + 2
    minX = max(1, minWorldX + 1)
    maxX = min(mapWidth, maxWorldX + 1)
  end
  if minX > maxX then _endManualDraw(restoreX, restoreY); return end

  local tiles = layerData.tilesFlat
  local stride = layerData.tilesStride

  -- Hoisted transforms to avoid repeated calculations
  local originX, originY      = layerData.originX or 0, layerData.originY or 0
  local parallaxX, parallaxY  = layerData.parallaxx or 1, layerData.parallaxy or 1
  local parallaxOriginX       = layerData.parallaxoriginx or 0
  local parallaxOriginY       = layerData.parallaxoriginy or 0
  local pivotAdjustX          = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY          = parallaxOriginY * (1 - parallaxY)
  local cameraX, cameraY      = getCameraPosition()
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  -- Add lightweight per-layer caches for images and offsets (no LRU overhead)
  layerData._imageCache  = layerData._imageCache  or {}
  layerData._offsetCache = layerData._offsetCache or {}

  for tileY = rowStart, rowEnd do
    local row0 = tileY - 1
    local rowShiftX = _rowShiftX_for_row0(self, row0, halfWidth)

    local baseScreenX = round(originX + rowShiftX + pivotAdjustX - cameraX * parallaxX)
    local baseScreenY = round(originY + row0 * halfHeight + pivotAdjustY - cameraY * parallaxY)

    local currentX = baseScreenX + (minX - 1) * tileWidth
    local rowIndex = row0 * stride + minX

    for tileX = minX, maxX do
      local tileIndex = tiles and tiles[rowIndex] or 0
      if tileIndex and tileIndex > 0 and tileIndex <= n then
        local img = layerData._imageCache[tileIndex]
        if not img then
          img = imageTable:getImage(tileIndex)
          layerData._imageCache[tileIndex] = img
        end
        if img then
          local offsetX = layerData._offsetCache[tileIndex]
          local offsetY
          if not offsetX then
            offsetX, offsetY = _isoDrawOffsets(tileWidth, tileHeight, img)
            layerData._offsetCache[tileIndex] = offsetX
            layerData._offsetCache[tileIndex + 0.5] = offsetY
          else
            offsetY = layerData._offsetCache[tileIndex + 0.5]
          end
          img:draw(currentX + offsetX, baseScreenY + offsetY)
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

-- ! Destroy
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
