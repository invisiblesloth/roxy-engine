-- core/tilemaps/RoxyIsoTilemap.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
local Camera  <const> = r.Camera
local Cache   <const> = r.Cache

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
local setDrawOffset <const> = Graphics.setDrawOffset
local getDrawOffset <const> = Graphics.getDrawOffset

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
local TILE_MARGIN <const> = 1

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local COLOR_CLEAR <const> = Graphics.kColorClear

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Visible Layer Rectangle
-- Compute visible layer-space rect for clipping/chunk selection
local function _visibleLayerRect(self, layerData)
  local screenX, screenY = self:worldToScreen(0, 0, layerData)
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
local function _findFirstAvailableLayer(layers)
  for _, layerData in pairs(layers or {}) do
    if layerData.tilemap then return layerData end
  end
  return nil
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

  self._projection = "iso"

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
function RoxyIsoTilemap:_initializeStaticLayers(opts)
  local layerOptions = (opts and opts.layerOptions) or {}
  local totalChunkCache = opts.totalChunkCache or DEFAULT_CHUNK_CACHE

  -- One shared bucket for all chunk images on this map
  self._globalChunkBucket = newCacheBucket(totalChunkCache)

  for layerName, layerData in pairs(self.layers) do
    local lopts = layerOptions[layerName] or {}
    if lopts.preRenderChunked then
      self._staticChunkLayers[layerName] = {
        name      = layerName,
        layer     = layerData,
        size      = max(1, lopts.chunkSizePx or DEFAULT_CHUNK_SIZE),
        overlap   = lopts.overlapPx or DEFAULT_CHUNK_OVERLAP,
        keyPrefix = "chunk:" .. (self._mapCacheId or "map") .. ":" ..
                    tostring(layerData.tiledId or layerName) .. ":",
      }
    end
  end
end

-- ! Utility: Rebuild Ordered Layers (z-sorted)
function RoxyIsoTilemap:_rebuildOrderedLayers()
  local items = {}
  for name, layerData in pairs(self.layers) do
    if layerData.tilemap and layerData.visible ~= false then
      local renderType = self._staticChunkLayers[name] and "chunked" or "dynamic"
      tableInsert(items, { layer = layerData, name = name, type = renderType, z = layerData.zIndex or 0 })
    end
  end
  tableSort(items, function(a, b) return a.z < b.z end)
  self._orderedLayers = items
end

-- ! Utility: Preload Layer Caches
function RoxyIsoTilemap:_preloadLayerCaches(layerData)
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
function RoxyIsoTilemap:_getOrBuildChunk(layerCfg, chunkX, chunkY)
  local key = layerCfg.keyPrefix .. chunkX .. ":" .. chunkY
  return getOrLoadAsset(self._globalChunkBucket, key, function()
    local size, overlap = layerCfg.size, layerCfg.overlap
    local width, height = size + 2 * overlap, size + 2 * overlap
    local img = newImage(width, height)

    -- Convert chunk indices to layer pixel origin for this chunk
    local pixelX = chunkX * size - overlap
    local pixelY = chunkY * size - overlap

    pushContext(img)
      setClipRect(0, 0, width, height)
      clear(COLOR_CLEAR)
      self:_renderLayerToBuffer(layerCfg.layer, -pixelX, -pixelY, width, height)
      clearClipRect()
    popContext()

    return img
  end)
end

-- ! Utility: Render Layer to Buffer
-- Render a layer directly to a buffer context (in layer-local coordinates)
function RoxyIsoTilemap:_renderLayerToBuffer(layerData, offsetX, offsetY, bufferWidth, bufferHeight)
  local imageTable = layerData.imageTable
  local mapWidth, mapHeight = layerData.mapWidth, layerData.mapHeight
  if not mapWidth or not mapHeight or not imageTable then return end

  local n = layerData.imageCount
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  -- Use the canonical field name for tall art margin
  local maxImageHeight = layerData.maxImageHeight or 0
  local overdrawRows = ceil(max(0, maxImageHeight - tileHeight) / max(1, halfHeight)) + 1

  -- Determine the iso rows/cols that can touch this buffer
  -- Using iso formulas:
  -- screenX = originX + (worldX - worldY) * halfWidth  (originX cancels due to offset application)
  -- screenY = originY + (worldX + worldY) * halfHeight
  -- We step by integer worldX/worldY (tile coords)

  -- Conservative bounds in world space:
  local minWorldX = floor((-offsetX) / halfWidth) - (overdrawRows + 2)
  local maxWorldX = ceil((bufferWidth  - offsetX) / halfWidth) + (overdrawRows + 2)
  local minWorldY = floor((-offsetY) / halfHeight) - (overdrawRows + 2)
  local maxWorldY = ceil((bufferHeight - offsetY) / halfHeight) + (overdrawRows + 2)

  -- Clamp to map
  local minTileY = max(0, -maxWorldY)
  local maxTileY = min(mapHeight - 1, maxWorldY)
  local minTileX = max(0, -maxWorldX)
  local maxTileX = min(mapWidth  - 1, maxWorldX)

  local tiles  = layerData.tilesFlat
  local stride = layerData.tilesStride or mapWidth

  -- Per-tile offset cache (avoid repeated _isoDrawOffsets calls)
  local offsetCache = layerData._offsetCache
  if not offsetCache then
    offsetCache = {}
    layerData._offsetCache = offsetCache
  end

  -- Per-tile image cache (avoid imageTable:getImage repeats)
  local imageCache = layerData._imageCache
  if not imageCache then
    imageCache = {}
    layerData._imageCache = imageCache
  end

  for row0 = minTileY, maxTileY do
    -- Draw across columns for this row
    local rowIndex = row0 * stride + (minTileX + 1)
    for col0 = minTileX, maxTileX do
      local tileIndex = tiles and tiles[rowIndex] or 0
      if tileIndex and tileIndex > 0 and tileIndex <= n then
        local img = imageCache[tileIndex]
        if not img then
          img = imageTable:getImage(tileIndex)
          imageCache[tileIndex] = img
        end
        if img then
          local offX = offsetCache[tileIndex]
          local offY
          if not offX then
            offX, offY = _isoDrawOffsets(tileWidth, tileHeight, img)
            offsetCache[tileIndex] = offX
            offsetCache[tileIndex + 0.5] = offY
          else
            offY = offsetCache[tileIndex + 0.5]
          end

          local worldX, worldY = col0, row0
          local drawX = (worldX - worldY) * halfWidth + offsetX + offX
          local drawY = (worldX + worldY) * halfHeight + offsetY + offY

          if drawX < bufferWidth and drawY < bufferHeight
             and drawX > -tileWidth and drawY > -tileHeight then
            img:draw(drawX, drawY)
          end
        end
      end
      rowIndex += 1
    end
  end
end

-- ! Utility: Draw Static Layer Chunked
function RoxyIsoTilemap:_drawStaticLayerChunked(layerName)
  local config = self._staticChunkLayers[layerName]
  if not config then return end

  local layerData = config.layer
  local size    = config.size
  local overlap = config.overlap

  local visibleX, visibleY, visibleWidth, visibleHeight = _visibleLayerRect(self, layerData)
  visibleX -= overlap; visibleY -= overlap
  visibleWidth += 2 * overlap; visibleHeight += 2 * overlap

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    _chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)

  local screenX, screenY = self:worldToScreen(0, 0, layerData)

  for chunkY = minChunkY, maxChunkY do
    local rowDestY = chunkY * size - overlap + screenY
    for chunkX = minChunkX, maxChunkX do
      local img = self:_getOrBuildChunk(config, chunkX, chunkY)
      if img then
        local destX = chunkX * size - overlap + screenX
        local destY = rowDestY

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
-- Projection (classic diamond isometric)
-- screenX = originX + (worldX - worldY) * (tileWidth  * 0.5)
-- screenY = originY + (worldX + worldY) * (tileHeight * 0.5)
--------------------------------------------------------------------------------

-- ! World to Screen
function RoxyIsoTilemap:worldToScreen(worldX, worldY, layerData)
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  local originX, originY = layerData.originX or 0, layerData.originY or 0
  local parallaxX, parallaxY = layerData.parallaxx or 1, layerData.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  local parallaxOriginX = layerData.parallaxoriginx or 0
  local parallaxOriginY = layerData.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local isoX = originX + (worldX - worldY) * halfWidth
  local isoY = originY + (worldX + worldY) * halfHeight

  return round(isoX + pivotAdjustX - cameraX * parallaxX),
         round(isoY + pivotAdjustY - cameraY * parallaxY)
end

-- ! Screen to World
function RoxyIsoTilemap:screenToWorld(screenX, screenY, layerData)
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  local originX, originY = layerData.originX or 0, layerData.originY or 0
  local parallaxX, parallaxY = layerData.parallaxx or 1, layerData.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  local parallaxOriginX = layerData.parallaxoriginx or 0
  local parallaxOriginY = layerData.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local deltaX = (screenX + cameraX * parallaxX) - (originX + pivotAdjustX)
  local deltaY = (screenY + cameraY * parallaxY) - (originY + pivotAdjustY)

  local worldX = (deltaX / halfWidth + deltaY / halfHeight) * 0.5
  local worldY = (deltaY / halfHeight - deltaX / halfWidth) * 0.5
  return worldX, worldY
end


--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Set Tile At
function RoxyIsoTilemap:setTileAt(layerName, x, y, tileIndex, updateSprite)
  local layerData = self.layers and self.layers[layerName]
  if not layerData then return end

  layerData.tilemap:setTileAtPosition(x, y, tileIndex)

  -- Update cached flat data used by dynamic paths
  local tiles = layerData.tilesFlat
  if tiles then
    local stride = layerData.tilesStride or layerData.mapWidth
    if stride and stride > 0 then
      local idx = (y - 1) * stride + x
      if idx >= 1 and idx <= #tiles then
        tiles[idx] = tileIndex
      end
    end
  end

  -- Evict any overlapping chunks so they rebuild lazily
  if self._staticChunkLayers[layerName] then
    self:markTilesDirty(layerName, x, y, 1, 1)
  end

  if updateSprite and layerData.imageTable then
    local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
    local screenX, screenY = self:worldToScreen(x - 1, y - 1, layerData)
    addDirtyRect(screenX, screenY, tileWidth, tileHeight)
  end
end

-- ! Get Row From Screen
-- Convert a screen pixel to a 1-based row (tileY)
function RoxyIsoTilemap:getRowFromScreen(screenX, screenY, layerName)
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
function RoxyIsoTilemap:resortLayers()
  self:_rebuildOrderedLayers()
end

-- ! Mark Tiles Dirty
-- Evict any chunks overlapped by the edited tile region
function RoxyIsoTilemap:markTilesDirty(layerName, tileX, tileY, tileCountWidth, tileCountHeight)
  local cfg = self._staticChunkLayers[layerName]
  if not cfg then return end

  local tileWidth, tileHeight = cfg.layer.tileWidth, cfg.layer.tileHeight
  local pixelX = (tileX - 1) * (tileWidth * 0.5) * 2
  local pixelY = (tileY - 1) * (tileHeight * 0.5)

  local pixelWidth  = (tileCountWidth  or 1) * tileWidth
  local pixelHeight = (tileCountHeight or 1) * (tileHeight * 0.5)

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    _chunkIndicesForRect(pixelX, pixelY, pixelWidth, pixelHeight, cfg.size)

  for cy = minChunkY, maxChunkY do
    for cx = minChunkX, maxChunkX do
      evictAsset(self._globalChunkBucket, cfg.keyPrefix .. cx .. ":" .. cy)
    end
  end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- ! Draw
-- Draw a single tile layer with conservative vertical culling
function RoxyIsoTilemap:draw(layerName)
  if self._staticChunkLayers and self._staticChunkLayers[layerName] then
    self:_drawStaticLayerChunked(layerName); return
  end

  local layerData = self.layers and self.layers[layerName]
  if not layerData or not layerData.tilemap or layerData.visible == false then return end

  local minTileX, minTileY, maxTileX, maxTileY = self:getVisibleTileBounds(layerData)

  self:drawLayerRows(layerName, minTileY, maxTileY, minTileX, maxTileX)
end

-- ! Draw Visible
-- Draw all visible tile layers sorted by z-index
function RoxyIsoTilemap:drawVisible()
  -- Keep ordered layers if you have them; otherwise, iterate layers
  local list = self._orderedLayers
  if list and #list > 0 then
    for i = 1, #list do
      local item = list[i]
      if item.type == "chunked" then
        self:_drawStaticLayerChunked(item.name)
      else
        local layerData = item.layer
        if layerData.tilemap and layerData.visible ~= false then
          local minTileX, minTileY, maxTileX, maxTileY = self:getVisibleTileBounds(layerData)
          self:drawLayerRows(item.name, minTileY, maxTileY, minTileX, maxTileX)
        end
      end
    end
    return
  end

  -- Fallback if ordered list isn't used
  for name, layerData in pairs(self.layers or {}) do
    if layerData.tilemap and layerData.visible ~= false then
      local minTileX, minTileY, maxTileX, maxTileY = self:getVisibleTileBounds(layerData)
      self:drawLayerRows(name, minTileY, maxTileY, minTileX, maxTileX)
    end
  end
end

-- ! Draw Visible in Rectangle
-- Clip helper for UI overlays, etc.
function RoxyIsoTilemap:drawVisibleInRect(x, y, width, height)
  setClipRect(x, y, width, height)
    self:drawVisible()
  clearClipRect()
end

-- ! Draw Layer Rows
function RoxyIsoTilemap:drawLayerRows(layerName, minRow, maxRow, minColumn, maxColumn)
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
  local rowEnd   = min(mapHeight, maxRow or mapHeight)
  if rowStart > rowEnd then _endManualDraw(restoreX, restoreY); return end

  local minX, maxX
  if minColumn and maxColumn then
    minX = max(1, minColumn)
    maxX = min(mapWidth, maxColumn)
  else
    -- Ask base class for safe visible bounds
    -- Only take X since rows are fixed above
    local visibleX1, visibleY1, visibleX2, visibleY2 = self:getVisibleTileBounds(layerData)
    minX = visibleX1; maxX = visibleX2
  end
  if minX > maxX then _endManualDraw(restoreX, restoreY); return end

  local tiles  = layerData.tilesFlat
  local stride = layerData.tilesStride

  -- Hoisted transforms
  local originX, originY      = layerData.originX or 0, layerData.originY or 0
  local parallaxX, parallaxY  = layerData.parallaxx or 1, layerData.parallaxy or 1
  local parallaxOriginX       = layerData.parallaxoriginx or 0
  local parallaxOriginY       = layerData.parallaxoriginy or 0
  local pivotAdjustX          = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY          = parallaxOriginY * (1 - parallaxY)
  local cameraX, cameraY      = getCameraPosition()
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  layerData._imageCache  = layerData._imageCache  or {}
  layerData._offsetCache = layerData._offsetCache or {}

  for tileY = rowStart, rowEnd do
    local row0 = tileY - 1

    -- Base isometric screen position for the leftmost column
    local baseScreenX = round(originX + ((minX - 1) - row0) * halfWidth + pivotAdjustX - cameraX * parallaxX)
    local baseScreenY = round(originY + ((minX - 1) + row0) * halfHeight + pivotAdjustY - cameraY * parallaxY)

    local currentX = baseScreenX
    local currentY = baseScreenY
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
          local offX = layerData._offsetCache[tileIndex]
          local offY
          if not offX then
            offX, offY = _isoDrawOffsets(tileWidth, tileHeight, img)
            layerData._offsetCache[tileIndex] = offX
            layerData._offsetCache[tileIndex + 0.5] = offY
          else
            offY = layerData._offsetCache[tileIndex + 0.5]
          end

          img:draw(currentX + offX, currentY + offY)
        end
      end

      -- Advance to next iso column (worldX += 1)
      currentX += halfWidth
      currentY += halfHeight
      rowIndex += 1
    end
  end

  _endManualDraw(restoreX, restoreY)
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- ! Destroy
-- Clear chunk bucket as well as per-layer references
function RoxyIsoTilemap:destroy()
  if self._globalChunkBucket then
    clearCache(self._globalChunkBucket)
    self._globalChunkBucket = nil
  end
  self._staticChunkLayers = {}
  self._orderedLayers = {}
  RoxyIsoTilemap.super.destroy(self)
end
