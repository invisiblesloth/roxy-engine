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
local abs   <const> = math.abs
local round <const> = r.Math.round

local stringRep   <const> = string.rep
local stringPack  <const> = string.pack

local tableInsert <const> = table.insert
local tableRemove <const> = table.remove
local tableSort   <const> = table.sort
local tableUnpack <const> = table.unpack

local pushContext   <const> = Graphics.pushContext
local popContext    <const> = Graphics.popContext
local setClipRect   <const> = Graphics.setClipRect
local clearClipRect <const> = Graphics.clearClipRect
local newImage      <const> = Graphics.image.new
local clear         <const> = Graphics.clear

local addDirtyRect <const> = Sprite.addDirtyRect

local newCacheBucket    <const> = Cache.newBucket
local getIsAssetCached  <const> = Cache.getIsAssetCached
local getCachedAsset    <const> = Cache.getCachedAsset
local putAsset          <const> = Cache.putAsset
local evictAsset        <const> = Cache.evictAsset
local clearCache        <const> = Cache.clearCache

local getCameraPosition <const> = Camera.getPosition

local _isoDrawOffsets   <const> = RoxyTilemap._isoDrawOffsets
local _beginManualDraw  <const> = RoxyTilemap._beginManualDraw
local _endManualDraw    <const> = RoxyTilemap._endManualDraw

-- C-side bindings
local newTileRenderer_C <const> = RoxyTileRendererC and RoxyTileRendererC.new or nil

-- Default chunk settings
local DEFAULT_CHUNK_SIZE    <const> = 256 -- Rule of thumb: tileWidth * 4
local DEFAULT_CHUNK_CACHE   <const> = 200
local DEFAULT_CHUNK_OVERLAP <const> = 32
local DEFAULT_TILE_WIDTH    <const> = 64 -- Default tile width

-- Coarse safety margin (in tiles) for dynamic fallback culling
local TILE_MARGIN <const> = 0.5

local PREFETCH_RINGS  <const> = 1  -- 1 ring beyond visible
local BUILD_BUDGET    <const> = 2  -- Build at most 2 chunks per frame

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local COLOR_CLEAR <const> = Graphics.kColorClear

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Row Shift X for Row 0
-- Shift, in pixels, for a 0-based row index (Tiled staggered-y)
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
  -- The screen shows [0..width, 0..height] which corresponds to
  -- layer pixels [-screenX..-screenX+width, -screenY..-screenY+height]
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
  for _, layer in pairs(layers or {}) do
    if layer.tilemap then return layer end
  end
  return nil
end

-- ! Helper: Pack Tiles U16
-- Pack tiles as little-endian uint16 with clamping
local function _packTilesU16(tiles)
  if not tiles or #tiles == 0 then return nil end
  local n = #tiles
  local fmt = stringRep("<I2", n)
  local tmp = {}
  for i = 1, n do
    local v = tiles[i] or 0
    if v < 0 then v = 0 elseif v > 0xFFFF then v = 0xFFFF end
    tmp[i] = v
  end
  return stringPack(fmt, tableUnpack(tmp, 1, n))
end

-- ! Helper: Sanitize a single tile index
-- Returns 0 for out-of-range/invalid, else the original index (1..imageCount)
local function _sanitizeTileIndex(tileIndex, imageCount)
  if tileIndex == nil or type(tileIndex) ~= "number" then return 0 end
  if tileIndex == 0 then return 0 end
  if tileIndex < 1 or (imageCount and tileIndex > imageCount) then return 0 end
  return tileIndex
end

-- ! Helper: Sanitize tiles in place
-- Ensures every tile is 0 or in [1..imageCount]
local function _sanitizeTilesInPlace(tiles, imageCount)
  if not tiles then return end
  for i = 1, #tiles do
    tiles[i] = _sanitizeTileIndex(tiles[i], imageCount)
  end
end

-- ! Helper: Sync Native Tiles
-- Sync native tiles from current tilesFlat
local function _syncNativeTiles(layerData)
  if not layerData or not layerData._nativeRenderer or not layerData.tilesFlat then return end
  local blob = _packTilesU16(layerData.tilesFlat)
  if blob then
    layerData._nativeRenderer:updateTilesBytes(blob)
    local selfRef = layerData.ownerTilemap
    if selfRef then selfRef._frameDirty = true end
  end
end

--------------------------------------------------------------------------------
-- Class Definition / Initialize
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

  self._warmQueue = {}  -- Queue of { layerConfig, chunkX, chunkY, key }
  self._warmSet   = {}  -- Tracks keys already queued

  self._didPrimeVisible = false -- One-time prime flag

  self._frameDirty = true -- Assume dirty until first frame settles
  self._lastCameraX, self._lastCameraY = nil, nil -- Camera stamp

  -- Map-scoped cache key namespace
  self._mapCacheId = jsonPath or tostring(self)

  self:_initializeStaticLayers(opts)

  for _, layerData in pairs(self.layers) do
    if layerData.tilemap then
      self:_preloadLayerCaches(layerData)

      -- Create native renderer instance for this layer
      if layerData.imageTable and newTileRenderer_C then
        -- Sanitize tiles once on load so the native blob never sees out-of-range values
        _sanitizeTilesInPlace(layerData.tilesFlat, layerData.imageCount)

        local isIsometric              = 0
        local staggerIndexOdd          = (self.staggerIndex == "odd") and 1 or 0
        local staggerDirectionRight    = (self.staggerDirection == "right") and 1 or 0

        --#DEBUG START
        if (layerData.tileWidth or 0) <= 0 or (layerData.tileHeight or 0) <= 0
           or (layerData.halfWidth or 0) <= 0 or (layerData.halfHeight or 0) <= 0 then
          Log.error("[RoxyStagTilemap] Invalid tile metrics; width/height/halves must be > 0")
        end
        --#DEBUG END

        layerData._nativeRenderer = newTileRenderer_C(
          isIsometric,
          staggerIndexOdd,
          staggerDirectionRight,
          layerData.mapWidth,       -- Tiles
          layerData.mapHeight,      -- Tiles
          layerData.tileWidth,      -- Pixels
          layerData.tileHeight,     -- Pixels
          layerData.halfWidth,      -- Pixels
          layerData.halfHeight,     -- Pixels
          layerData.maxImageHeight, -- Tall art overdraw
          layerData.imageTable,     -- LCDBitmapTable
          layerData.imageCount,     -- Frames in table
          nil                       -- Optional tiles blob
        )
        layerData.ownerTilemap = self
        _syncNativeTiles(layerData)
      end
    end
  end

  self:_rebuildOrderedLayers()
end

--------------------------------------------------------------------------------
-- Internal API
--------------------------------------------------------------------------------

--
-- Static Layer Configuration
--

-- ! Initialize Static Layers
-- Build chunk/static configuration per layer
function RoxyStagTilemap:_initializeStaticLayers(opts)
  local layerOptions = (opts and opts.layerOptions) or {}
  local totalChunkCache = opts.totalChunkCache or DEFAULT_CHUNK_CACHE

  self._globalChunkBucket = newCacheBucket(totalChunkCache)

  for layerName, layer in pairs(self.layers) do
    local layerOpts = layerOptions[layerName] or {}
    if layerOpts.preRenderChunked then
      local halfWidth = layer.halfWidth or floor((layer.tileWidth or DEFAULT_TILE_WIDTH) * 0.5)

      local tallOverdraw = 0
      if layer.maxImageHeight and layer.tileHeight then
        tallOverdraw = max(0, ceil((layer.maxImageHeight - layer.tileHeight) * 0.5))
      end

      local overlap = layerOpts.overlapPx or max(halfWidth, tallOverdraw, DEFAULT_CHUNK_OVERLAP)

      self._staticChunkLayers[layerName] = {
        name      = layerName,
        layer     = layer,
        size      = max(1, layerOpts.chunkSizePx or DEFAULT_CHUNK_SIZE),
        overlap   = overlap,
        keyPrefix = "chunk:" .. (self._mapCacheId or "map") .. ":" .. tostring(layer.tiledId or layerName) .. ":",
      }
    end
  end
end

-- ! Prime Visible Chunks
-- Build currently visible chunks once to avoid first-frame misses
function RoxyStagTilemap:_primeVisibleChunks()
  if self._didPrimeVisible then return end

  for _, layerConfig in pairs(self._staticChunkLayers) do
    local layer = layerConfig.layer
    local size, overlap = layerConfig.size, layerConfig.overlap

    local vx, vy, vw, vh = _visibleLayerRect(self, layer)
    vx -= overlap; vy -= overlap; vw += 2 * overlap; vh += 2 * overlap

    local minChunkX, maxChunkX, minChunkY, maxChunkY = _chunkIndicesForRect(vx, vy, vw, vh, size)

    for cy = minChunkY, maxChunkY do
      for cx = minChunkX, maxChunkX do
        local key = layerConfig.keyPrefix .. cx .. ":" .. cy
        if not getIsAssetCached(self._globalChunkBucket, key) then
          local img = self:_buildChunk(layerConfig, cx, cy)
          if img then putAsset(self._globalChunkBucket, key, img) end
        end
      end
    end
  end

  self._didPrimeVisible = true
end

-- ! Rebuild Ordered Layers
-- Build a stable, z-sorted draw list (rarely changes)
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

-- ! Preload Layer Caches
function RoxyStagTilemap:_preloadLayerCaches(layerData)
  if not layerData.imageTable or not layerData.tileWidth or not layerData.tileHeight then return end

  local n = layerData.imageCount
  layerData._imageCache = {}
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

--
-- Chunk building & drawing
--

-- ! Enqueue Warm
function RoxyStagTilemap:_enqueueWarm(layerConfig, chunkX, chunkY)
  local key = layerConfig.keyPrefix .. chunkX .. ":" .. chunkY
  if self._warmSet[key] then return end
  self._warmSet[key] = true
  self._warmQueue[#self._warmQueue + 1] = {
    layerConfig = layerConfig,
    chunkX = chunkX,
    chunkY = chunkY,
    key = key
  }
end

-- ! Warm Some Chunks
-- Amortize chunk builds across frames
function RoxyStagTilemap:_warmSomeChunks()
  local built = 0
  while built < BUILD_BUDGET and #self._warmQueue > 0 do
    local job = tableRemove(self._warmQueue)
    self._warmSet[job.key] = nil
    if not getIsAssetCached(self._globalChunkBucket, job.key) then
      local img = self:_buildChunk(job.layerConfig, job.chunkX, job.chunkY)
      if img then
        putAsset(self._globalChunkBucket, job.key, img)
        built += 1
      end
    end
  end

  if built > 0 then
    self._frameDirty = true
  end
end

-- ! Has Warm Work
-- True when there are chunks waiting to build
function RoxyStagTilemap:_hasWarmWork()
  return self._warmQueue and #self._warmQueue > 0
end

-- ! Build Chunk
function RoxyStagTilemap:_buildChunk(layerConfig, chunkX, chunkY)
  local size, overlap = layerConfig.size, layerConfig.overlap
  local width, height = size + 2 * overlap, size + 2 * overlap
  local img = newImage(width, height)

  local pixelX = chunkX * size - overlap
  local pixelY = chunkY * size - overlap

  pushContext(img)
    setClipRect(0, 0, width, height)
    clear(COLOR_CLEAR)
    self:_renderLayerToBuffer(layerConfig.layer, img, -pixelX, -pixelY, width, height)
    clearClipRect()
  popContext()
  return img
end

-- ! Enqueue Ring
function RoxyStagTilemap:_enqueueRing(layerData, layerConfig)
  local size, overlap = layerConfig.size, layerConfig.overlap

  local visibleX, visibleY, visibleWidth, visibleHeight = _visibleLayerRect(self, layerData)
  visibleX -= (overlap + size * PREFETCH_RINGS)
  visibleY -= (overlap + size * PREFETCH_RINGS)
  visibleWidth  += 2 * (overlap + size * PREFETCH_RINGS)
  visibleHeight += 2 * (overlap + size * PREFETCH_RINGS)

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    _chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)

  -- Skip if ring bounds didn’t change
  local last = layerConfig._lastRingBounds
  if last
    and last.minX == minChunkX and last.maxX == maxChunkX
    and last.minY == minChunkY and last.maxY == maxChunkY
  then
    return
  end
  layerConfig._lastRingBounds = { minX = minChunkX, maxX = maxChunkX, minY = minChunkY, maxY = maxChunkY }

  for chunkY = minChunkY, maxChunkY do
    for chunkX = minChunkX, maxChunkX do
      local key = layerConfig.keyPrefix .. chunkX .. ":" .. chunkY
      if not getIsAssetCached(self._globalChunkBucket, key) then
        self:_enqueueWarm(layerConfig, chunkX, chunkY)
      end
    end
  end
end

-- ! Render Layer to Buffer
function RoxyStagTilemap:_renderLayerToBuffer(layerData, targetImage, offsetX, offsetY, bufferWidth, bufferHeight)
  local nativeRenderer = layerData._nativeRenderer

  -- Fast path: native renderer to a real LCDBitmap
  if nativeRenderer and targetImage ~= nil then
    nativeRenderer:renderToBuffer(targetImage, offsetX, offsetY, bufferWidth, bufferHeight)
    return
  end

  -- Fallback Lua implementation (rare in practice)
  Log.debug("[_renderLayerToBuffer] Falling back on Lua implementation") --#DEBUG

  local imageTable = layerData.imageTable
  local mapWidth, mapHeight = layerData.mapWidth, layerData.mapHeight
  if not mapWidth or not mapHeight or not imageTable then return end

  local n = layerData.imageCount
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  local function rowShiftX(row0) return (row0 % 2 == 0) and 0 or halfWidth end

  local maxImageHeight = layerData.maxImageHeight or 0
  local overdrawRows = ceil(max(0, maxImageHeight - tileHeight) / max(1, halfHeight)) + 1

  local minRow0 = floor((-offsetY - maxImageHeight) / halfHeight) - 1
  local maxRow0 = ceil ((bufferHeight - offsetY) / halfHeight) + 1
  minRow0 = max(0, minRow0 - overdrawRows)
  maxRow0 = min(mapHeight - 1, maxRow0 + overdrawRows)

  local tiles  = layerData.tilesFlat
  local stride = layerData.tilesStride or mapWidth

  local offsetCache = layerData._offsetCache
  if not offsetCache then
    offsetCache = {}
    layerData._offsetCache = offsetCache
  end

  for row0 = minRow0, maxRow0 do
    local baseX = rowShiftX(row0) + offsetX
    local baseY = row0 * halfHeight + offsetY

    local minTileX = floor((-tileWidth - baseX) / tileWidth)
    local maxTileX = floor((bufferWidth - 1 - baseX) / tileWidth)
    minTileX = max(0, minTileX - 1)
    maxTileX = min(mapWidth - 1, maxTileX + 1)

    if minTileX <= maxTileX then
      local rowIndex = row0 * stride + (minTileX + 1)
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
            local offsetX2, offsetY2 = offsetCache[tileIndex], offsetCache[tileIndex + 0.5]
            if not offsetX2 then
              offsetX2, offsetY2 = _isoDrawOffsets(tileWidth, tileHeight, img)
              offsetCache[tileIndex] = offsetX2
              offsetCache[tileIndex + 0.5] = offsetY2
            end

            local drawPosX, drawPosY = drawX + offsetX2, baseY + offsetY2
            if drawPosX < bufferWidth and drawPosY < bufferHeight
            and drawPosX > -tileWidth and drawPosY > -tileHeight then
              img:draw(drawPosX, drawPosY)
            end
          end
        end
        rowIndex += 1
        drawX += tileWidth
      end
    end
  end
end

-- ! Draw Static Layer Chunked
-- Render a chunked layer using prebuilt chunk images (row-clipped fallback)
function RoxyStagTilemap:_drawStaticLayerChunked(layerName)
  local layerConfig = self._staticChunkLayers[layerName]
  if not layerConfig then return end

  local layer         = layerConfig.layer
  local size, overlap = layerConfig.size, layerConfig.overlap

  local visibleX, visibleY, visibleWidth, visibleHeight = _visibleLayerRect(self, layer)
  visibleX -= overlap; visibleY -= overlap
  visibleWidth  += 2 * overlap; visibleHeight += 2 * overlap

  local minChunkX, maxChunkX, minChunkY, maxChunkY = _chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)
  local screenX, screenY = self:worldToScreen(0, 0, layer)

  for chunkY = minChunkY, maxChunkY do
    local rowDeltaY = chunkY * size - overlap + screenY
    for chunkX = minChunkX, maxChunkX do
      local key = layerConfig.keyPrefix .. chunkX .. ":" .. chunkY

      local dx = chunkX * size - overlap + screenX
      local dy = rowDeltaY
      local imageWidth = size + 2 * overlap
      local imageHeight = size + 2 * overlap

      -- Try blitting the prebuilt chunk image
      local img = getCachedAsset(self._globalChunkBucket, key)
      if img then
        img:draw(floor(dx), floor(dy))
      else
        -- Fallback: clip to chunk rect and render rows
        local imageX, imageY = floor(dx), floor(dy)
        local imageWidthFloored, imageHeightFloored = floor(imageWidth), floor(imageHeight)
        if imageWidthFloored > 0 and imageHeightFloored > 0 then
          setClipRect(imageX, imageY, imageWidthFloored, imageHeightFloored)
            self:drawLayerRows(layerName, nil, nil, nil, nil)
          clearClipRect()
        end
        -- Queue this chunk to build for future frames
        self:_enqueueWarm(layerConfig, chunkX, chunkY)
      end
    end
  end
end

--
-- Projection (Staggered-Y)
--

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

  -- Parallax-origin pivot to mirror sprite behavior.
  local parallaxOriginX = layerData.parallaxoriginx or 0
  local parallaxOriginY = layerData.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local screenX = originX + worldX * tileWidth + shiftX
  local screenY = originY + worldY * halfHeight

  return round(screenX + pivotAdjustX - cameraX * parallaxX),
         round(screenY + pivotAdjustY - cameraY * parallaxY)
end

-- ! Screen to World
-- Convert screen coordinates to world coordinates with parallax support.
function RoxyStagTilemap:screenToWorld(screenX, screenY, layerData)
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  local originX, originY = layerData.originX or 0, layerData.originY or 0
  local parallaxX, parallaxY = layerData.parallaxx or 1, layerData.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  local parallaxOriginX = layerData.parallaxoriginx or 0
  local parallaxOriginY = layerData.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

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

  -- Sanitize incoming edit
  local cleanIndex = _sanitizeTileIndex(tileIndex, layer.imageCount)

  -- Write to Tiled tilemap.
  layer.tilemap:setTileAtPosition(x, y, cleanIndex)

  -- Update cached flat data used by dynamic paths
  local tiles = layer.tilesFlat
  if tiles then
    local stride = layer.tilesStride or layer.mapWidth
    if stride and stride > 0 then
      local idx = (y - 1) * stride + x
      if idx >= 1 and idx <= #tiles then
        tiles[idx] = cleanIndex
      end
    end
  end

  -- Mirror to native renderer for C-side fast paths
  local nativeRenderer = layer._nativeRenderer
  if nativeRenderer then
    nativeRenderer:setTileAt(x, y, cleanIndex)
  end

  -- Evict overlapping chunks so they rebuild lazily
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
function RoxyStagTilemap:resortLayers()
  self:_rebuildOrderedLayers()
end

-- ! Mark Tiles Dirty
-- Tile edits --> evict overlapping chunks (they will rebuild lazily)
function RoxyStagTilemap:markTilesDirty(layerName, tileX, tileY, tileCountWidth, tileCountHeight)
  local layerConfig = self._staticChunkLayers[layerName]
  if not layerConfig then return end

  self._frameDirty = true

  local tileWidth, tileHeight = layerConfig.layer.tileWidth, layerConfig.layer.tileHeight
  local pixelX = (tileX - 1) * tileWidth
  local pixelY = (tileY - 1) * (tileHeight * 0.5)
  local pixelWidth = (tileCountWidth or 1) * tileWidth
  local pixelHeight = (tileCountHeight or 1) * (tileHeight * 0.5)

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    _chunkIndicesForRect(pixelX, pixelY, pixelWidth, pixelHeight, layerConfig.size)
  for chunkY = minChunkY, maxChunkY do
    for chunkX = minChunkX, maxChunkX do
      evictAsset(self._globalChunkBucket, layerConfig.keyPrefix .. chunkX .. ":" .. chunkY)
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

  -- Dynamic fallback (rare): draw only visible rows/cols with coarse margin
  local layerData = self.layers and self.layers[layerName]
  if not layerData or not layerData.tilemap or layerData.visible == false then return end

  local mapWidth, mapHeight = layerData.mapWidth, layerData.mapHeight

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
-- Draw all visible layers in z-order, with smart skipping
function RoxyStagTilemap:drawVisible()
  local cameraX, cameraY = getCameraPosition()
  local cameraUnchanged = (self._lastCameraX == cameraX) and (self._lastCameraY == cameraY)
  local hasWarmWork = self:_hasWarmWork()

  if cameraUnchanged and not self._frameDirty and not hasWarmWork then
    return -- Nothing to do this frame.
  end

  self._lastCameraX, self._lastCameraY = cameraX, cameraY
  self._frameDirty = false -- We will render now; clear until something changes again

  self:_primeVisibleChunks()

  local ordered = self._orderedLayers
  for i = 1, #ordered do
    local item = ordered[i]
    if item.type == "chunked" then
      self:_enqueueRing(item.layer, self._staticChunkLayers[item.name])
      self:_drawStaticLayerChunked(item.name)
    else
      self:draw(item.name)
    end
  end

  self:_warmSomeChunks()
end

-- ! Draw Visible in Rectangle
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

  -- Fast path: native renderer draws rows directly
  if RoxyTileRendererC and layerData._nativeRenderer then
    local mapWidth, mapHeight = layerData.mapWidth, layerData.mapHeight
    local rowStart = max(1, minRow or 1)
    local rowEnd   = min(mapHeight, maxRow or mapHeight)
    if rowStart > rowEnd then _endManualDraw(restoreX, restoreY); return end

    local minX, maxX
    if minColumn and maxColumn then
      minX = max(1, minColumn)
      maxX = min(mapWidth, maxColumn)
    else
      local x1, _, x2, _ = self:getVisibleTileBounds(layerData)
      minX, maxX = x1, x2
    end
    if minX > maxX then _endManualDraw(restoreX, restoreY); return end

    local originX, originY      = layerData.originX or 0, layerData.originY or 0
    local parallaxX, parallaxY  = layerData.parallaxx or 1, layerData.parallaxy or 1
    local parallaxOriginX       = layerData.parallaxoriginx or 0
    local parallaxOriginY       = layerData.parallaxoriginy or 0
    local cameraX, cameraY      = getCameraPosition()

    local tr = layerData._nativeRenderer
    if tr then
      tr:drawRows(
        rowStart, rowEnd,
        minX, maxX,
        originX, originY,
        parallaxX, parallaxY,
        parallaxOriginX, parallaxOriginY,
        cameraX, cameraY
      )
      _endManualDraw(restoreX, restoreY)
      return
    end
  end

  --
  -- Fallback Lua Implementation
  --

  Log.debug("[drawLayerRows] Falling back on Lua implementation") --#DEBUG

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
  -- Destroy native renderers first
  for _, layerData in pairs(self.layers or {}) do
    if layerData._nativeRenderer then
      layerData._nativeRenderer:destroy()
      layerData._nativeRenderer = nil
    end
  end

  if self._globalChunkBucket then
    clearCache(self._globalChunkBucket)
    self._globalChunkBucket = nil
  end

  self._staticChunkLayers = {}
  self._orderedLayers = {}

  RoxyStagTilemap.super.destroy(self)
end
