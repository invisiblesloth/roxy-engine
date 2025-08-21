-- core/tilemaps/RoxyIsoTilemap.lua

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
local setCameraBounds   <const> = Camera.setBounds

local _isoDrawOffsets   <const> = RoxyTilemap._isoDrawOffsets
local _beginManualDraw  <const> = RoxyTilemap._beginManualDraw
local _endManualDraw    <const> = RoxyTilemap._endManualDraw

-- C-side bindings
local newTileRenderer_C <const> = RoxyTileRendererC and RoxyTileRendererC.new or nil

-- Default chunk settings
local DEFAULT_CHUNK_SIZE    <const> = 320 -- Adjusted for iso diamond (e.g., tileWidth * 5)
local DEFAULT_CHUNK_CACHE   <const> = 200
local DEFAULT_CHUNK_OVERLAP <const> = 32

-- Cull margins / epsilon
local TILE_MARGIN          <const> = 1 -- Coarse safety margin for dynamic draw
local VISIBLE_MARGIN_TILES <const> = 2
local FLOAT_EPSILON        <const> = 0.000001

local PREFETCH_RINGS  <const> = 1  -- 1 ring beyond visible
local BUILD_BUDGET    <const> = 2  -- Build at most 2 chunks per frame

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local COLOR_CLEAR <const> = Graphics.kColorClear

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

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
  local format = stringRep("<I2", n)
  local temp = {}
  for i = 1, n do
    local v = tiles[i] or 0
    if v < 0 then v = 0 elseif v > 0xFFFF then v = 0xFFFF end
    temp[i] = v
  end
  return stringPack(format, tableUnpack(temp, 1, n))
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

-- ! Helper: Warm Score
-- Warm queue prioritization helper (closest chunk to visible center)
local function _warmScore(self, job)
  local layerConfig = job.layerConfig
  local size = layerConfig.size
  local visibleX, visibleY, visibleWidth, visibleHeight = _visibleLayerRect(self, layerConfig.layer)
  local minX, maxX, minY, maxY = _chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)
  local centerX = (minX + maxX) * 0.5
  local centerY = (minY + maxY) * 0.5
  local dx = abs(job.chunkX - centerX)
  local dy = abs(job.chunkY - centerY)
  return dx + dy -- Manhattan distance is cheap and good enough
end

-- ! Helper: Dequeue Best Warm Job
local function _dequeueBestWarmJob(self)
  local queue = self._warmQueue
  local bestIndex, bestScore
  for idx = 1, #queue do
    local score = _warmScore(self, queue[idx])
    if not bestScore or score < bestScore then
      bestScore, bestIndex = score, idx
    end
  end
  if not bestIndex then return nil end
  local job = queue[bestIndex]
  tableRemove(queue, bestIndex)
  self._warmSet[job.key] = nil
  return job
end

--------------------------------------------------------------------------------
-- Class Definition / Initialize
--------------------------------------------------------------------------------

class("RoxyIsoTilemap").extends(RoxyTilemap)

function RoxyIsoTilemap:init(jsonPath, opts, scene)
  opts = opts or {}
  opts.wrapInSprites = false
  opts.anchor = "topLeft"
  RoxyIsoTilemap.super.init(self, jsonPath, opts, scene)

  -- Override world size for isometric projection
  local mapWidthTiles   = self.mapWidth  or 0
  local mapHeightTiles  = self.mapHeight or 0
  local tileWidth       = self.mapTileWidth or 0
  local tileHeight      = self.mapTileHeight or 0

  local halfWidthPx   = tileWidth * 0.5
  local halfHeightPx  = tileHeight * 0.5

  -- Horizontal/vertical span: sum of widths/heights in diamond
  self.worldWidth = (mapWidthTiles + mapHeightTiles) * halfWidthPx

  -- Vertical span: sum of heights in diamond
  local worldHeightBase = (mapWidthTiles + mapHeightTiles) * halfHeightPx

  -- Adjust for any tall tiles (maxImageHeight across layers)
  local maxOverdrawPx = 0
  for _, layer in pairs(self.layers or {}) do
    if layer.tilemap then
      local maxImageHeight = layer.maxImageHeight or 0
      if maxImageHeight > tileHeight then
        local over = max(0, (maxImageHeight - tileHeight) * 0.5)
        if over > maxOverdrawPx then maxOverdrawPx = over end
      end
    end
  end
  self.worldHeight = worldHeightBase + maxOverdrawPx

  -- Refresh camera bounds if requested
  if opts and opts.cameraBounds then
    local x2 = max(0, self.worldWidth - DISPLAY_WIDTH)
    local y2 = max(0, self.worldHeight - DISPLAY_HEIGHT)

    if type(self.setCameraBounds) == "function" then
      pcall(function() self:setCameraBounds(0, 0, x2, y2) end)
    elseif Camera and type(setCameraBounds) == "function" then
      pcall(function() setCameraBounds({ x1 = 0, y1 = 0, x2 = x2, y2 = y2 }) end)
    end
  end

  self._projection = "iso"

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

        local isIsometric = 1
        local staggerIndexOdd = 0
        local staggerDirectionRight = 0

        --#DEBUG START
        if (layerData.tileWidth or 0) <= 0 or (layerData.tileHeight or 0) <= 0
           or (layerData.halfWidth or 0) <= 0 or (layerData.halfHeight or 0) <= 0 then
          Log.error("[RoxyIsoTilemap] Invalid tile metrics; width/height/halves must be > 0")
        end
        --#DEBUG END

        layerData._nativeRenderer = newTileRenderer_C(
          isIsometric,
          staggerIndexOdd,
          staggerDirectionRight,
          layerData.mapWidth,       -- Tiles
          layerData.mapHeight,      -- Tiles
          layerData.tileWidth,      -- px
          layerData.tileHeight,     -- px
          layerData.halfWidth,      -- px
          layerData.halfHeight,     -- px
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
function RoxyIsoTilemap:_initializeStaticLayers(opts)
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
        _dirty    = true, -- Per-layer dirty bit
      }
    end
  end
end

-- ! Prime Visible Chunks
-- Build currently visible chunks once to avoid first-frame misses
function RoxyIsoTilemap:_primeVisibleChunks()
  if self._didPrimeVisible then return end
  for _, layerConfig in pairs(self._staticChunkLayers) do
    local layer = layerConfig.layer
    local size, overlap = layerConfig.size, layerConfig.overlap

    local visibleX, visibleY, visibleWidth, visibleHeight = _visibleLayerRect(self, layer)
    visibleX -= overlap; visibleY -= overlap; visibleWidth += 2 * overlap; visibleHeight += 2 * overlap

    local minX, maxX, minY, maxY = _chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)
    for chunkY = minY, maxY do
      for chunkX = minX, maxX do
        local key = layerConfig.keyPrefix .. chunkX .. ":" .. chunkY
        if not getIsAssetCached(self._globalChunkBucket, key) then
          self:_enqueueWarm(layerConfig, chunkX, chunkY)
        end
      end
    end
  end
  self._didPrimeVisible = true
  self._frameDirty = true
end

-- ! Rebuild Ordered Layers
-- Build a stable, z-sorted draw list (rarely changes)
function RoxyIsoTilemap:_rebuildOrderedLayers()
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
function RoxyIsoTilemap:_preloadLayerCaches(layerData)
  layerData._imageCache  = layerData._imageCache  or {}
  layerData._offsetCache = layerData._offsetCache or {}
end

--
-- Chunk building & warming
--

-- ! Enqueue Warm
function RoxyIsoTilemap:_enqueueWarm(layerConfig, chunkX, chunkY)
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
function RoxyIsoTilemap:_warmSomeChunks()
  local built = 0
  while built < BUILD_BUDGET and #self._warmQueue > 0 do
    local job = _dequeueBestWarmJob(self) -- Pick closest
    if not job then break end
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
function RoxyIsoTilemap:_hasWarmWork()
  return self._warmQueue and #self._warmQueue > 0
end

-- ! Build Chunk
function RoxyIsoTilemap:_buildChunk(layerConfig, chunkX, chunkY)
  local size, overlap = layerConfig.size, layerConfig.overlap
  local width, height = size + 2 * overlap, size + 2 * overlap
  local img = newImage(width, height)
  if not img then
    -- Low-memory guard
    Log.warn("[RoxyIsoTilemap] Failed to allocate chunk image (%dx%d)", width, height)
    return nil
  end

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
function RoxyIsoTilemap:_enqueueRing(layerData, layerConfig)
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
function RoxyIsoTilemap:_renderLayerToBuffer(layerData, targetImage, offsetX, offsetY, bufferWidth, bufferHeight)
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

  local maxImageHeight = layerData.maxImageHeight or 0
  local overdrawRows = ceil(max(0, maxImageHeight - tileHeight) / max(1, halfHeight)) + 1 -- Safety +1

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
  local stride = layerData.tilesStride or mapWidth  -- Restore fallback

  local offsetCache = layerData._offsetCache
  if not offsetCache then
    offsetCache = {}
    layerData._offsetCache = offsetCache
  end

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

--
-- Chunked draw (with single-pass fallback)
--

-- ! Draw Static Layer Chunked
-- Render a chunked layer using prebuilt chunk images (row-clipped fallback)
function RoxyIsoTilemap:_drawStaticLayerChunked(layerName)
  local layerConfig = self._staticChunkLayers[layerName]
  if not layerConfig then return end

  local layer         = layerConfig.layer
  local size, overlap = layerConfig.size, layerConfig.overlap

  -- Visible rect in layer coords, padded by overlap.
  local visibleX, visibleY, visibleWidth, visibleHeight = _visibleLayerRect(self, layer)
  visibleX -= overlap; visibleY -= overlap
  visibleWidth += 2 * overlap; visibleHeight += 2 * overlap

  local minX, maxX, minY, maxY = _chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)
  local screenX, screenY = self:worldToScreen(0, 0, layer)

  -- First pass — scan for any missing chunks and enqueue builds.
  local anyMissing = false
  local toDraw = {} -- {img, dx, dy, imageWidth, imageHeight}
  local imageWidth, imageHeight = size + 2 * overlap, size + 2 * overlap

  for chunkY = minY, maxY do
    local rowDeltaY = chunkY * size - overlap + screenY
    for chunkX = minX, maxX do
      local key = layerConfig.keyPrefix .. chunkX .. ":" .. chunkY
      local img = getCachedAsset(self._globalChunkBucket, key)
      if img then
        local dx = chunkX * size - overlap + screenX
        local dy = rowDeltaY
        -- Offscreen culling
        if dx < DISPLAY_WIDTH and dy < DISPLAY_HEIGHT and (dx + imageWidth) > 0 and (dy + imageHeight) > 0 then
          toDraw[#toDraw + 1] = { img = img, dx = dx, dy = dy } -- ints already
        end
      else
        anyMissing = true
        self:_enqueueWarm(layerConfig, chunkX, chunkY)
      end
    end
  end

  if anyMissing then
    -- Single-pass fallback — render the layer once (native rows or Lua), not per-miss.
    -- Clip to screen to be safe.
    setClipRect(0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT)
      self:drawLayerRows(layerName, nil, nil, nil, nil)
    clearClipRect()
    return
  end

  -- All chunks available — draw them.
  for index = 1, #toDraw do
    local element = toDraw[index]
    -- dx/dy are already integers; removed floor() for tiny win.
    element.img:draw(element.dx, element.dy)
  end
end

--
-- Projection (classic diamond isometric)
--

-- ! World to Screen
-- Convert world coordinates to screen coordinates with parallax support
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
-- Convert screen coordinates to world coordinates with parallax support.
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

-- ! Mark Dirty
-- Public dirty marker for external animation/parallax/etc
function RoxyIsoTilemap:markDirty(redrawBackground)
  self._frameDirty = true

  if redrawBackground == nil then redrawBackground = true end
  if redrawBackground then
    if Sprite.redrawBackground then
      Sprite.redrawBackground()
    else
      addDirtyRect(0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT)
    end
  end
end

-- ! Set Tile At
-- Override setTileAt to handle static layer updates
function RoxyIsoTilemap:setTileAt(layerName, x, y, tileIndex, updateSprite)
  local layer = self.layers and self.layers[layerName]
  if not layer then return end

  -- CHANGE: explicit bounds check to avoid native issues
  local mapWidth, mapHeight = layer.mapWidth or 0, layer.mapHeight or 0
  if x < 1 or y < 1 or x > mapWidth or y > mapHeight then
    Log.warn("[RoxyIsoTilemap] setTileAt out of bounds (".. x .. ", ".. y .. ") not in [1..".. mapWidth .. ",1.." .. mapHeight .."]") --#DEBUG
    return
  end

  local cleanIndex = _sanitizeTileIndex(tileIndex, layer.imageCount)

  layer.tilemap:setTileAtPosition(x, y, cleanIndex)

  local tiles = layer.tilesFlat
  if tiles then
    local stride = layer.tilesStride or layer.mapWidth
    if stride and stride > 0 then
      local index = (y - 1) * stride + x
      if index >= 1 and index <= #tiles then
        tiles[index] = cleanIndex
      end
    end
  end

  local nativeRenderer = layer._nativeRenderer
  if nativeRenderer then
    nativeRenderer:setTileAt(x, y, cleanIndex)
  end

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
-- Tile edits --> evict overlapping chunks (they will rebuild lazily)
function RoxyIsoTilemap:markTilesDirty(layerName, tileX, tileY, tileCountWidth, tileCountHeight)
  local layerConfig = self._staticChunkLayers[layerName]
  if not layerConfig then return end

  self._frameDirty = true

  local tileWidth, tileHeight = layerConfig.layer.tileWidth, layerConfig.layer.tileHeight
  local pixelX = (tileX - 1) * (tileWidth * 0.5) * 2
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
function RoxyIsoTilemap:draw(layerName)
  if self._staticChunkLayers[layerName] then
    self:_drawStaticLayerChunked(layerName); return
  end

  -- Dynamic fallback (rare): draw only visible rows/cols with coarse margin
  local layerData = self.layers and self.layers[layerName]
  if not layerData or not layerData.tilemap or layerData.visible == false then return end

  local minTileX, minTileY, maxTileX, maxTileY = self:getVisibleTileBounds(layerData)

  self:drawLayerRows(layerName, minTileY, maxTileY, minTileX, maxTileX)
end

-- ! Draw Visible
-- Draw all visible layers in z-order, with smart skipping
function RoxyIsoTilemap:drawVisible()
  local cameraX, cameraY = getCameraPosition()
  local cameraUnchanged = (self._lastCameraX == cameraX) and (self._lastCameraY == cameraY)
  local hasWarmWork = self:_hasWarmWork()

  -- Do not early-out if this call was explicitly forced by drawVisibleInRect.
  if (not self._forceDraw) and cameraUnchanged and not self._frameDirty and not hasWarmWork then
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
function RoxyIsoTilemap:drawVisibleInRect(x, y, width, height)
  setClipRect(x, y, width, height)
    -- Force this particular draw to paint even if the camera did not move.
    self._forceDraw = true
    self:drawVisible()
    self._forceDraw = false
  clearClipRect()
end

-- ! Draw Layer Rows
-- Dynamic row/column renderer with manual sprite positioning
function RoxyIsoTilemap:drawLayerRows(layerName, minRow, maxRow, minColumn, maxColumn)
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
    local minWorldX = floor(min(leftWorld, rightWorld)) - VISIBLE_MARGIN_TILES
    local maxWorldX = ceil (max(leftWorld, rightWorld)) + VISIBLE_MARGIN_TILES
    minX = max(1, minWorldX + 1)
    maxX = min(mapWidth, maxWorldX + 1)
  end
  if minX > maxX then _endManualDraw(restoreX, restoreY); return end

  local tiles = layerData.tilesFlat
  local stride = layerData.tilesStride or mapWidth

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
          local offsetX = layerData._offsetCache[tileIndex]
          local offsetY
          if not offsetX then
            offsetX, offsetY = _isoDrawOffsets(tileWidth, tileHeight, img)
            layerData._offsetCache[tileIndex] = offsetX
            layerData._offsetCache[tileIndex + 0.5] = offsetY
          else
            offsetY = layerData._offsetCache[tileIndex + 0.5]
          end
          img:draw(currentX + offsetX, currentY + offsetY)
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
-- Clean up static layer resources
function RoxyIsoTilemap:destroy()
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

  RoxyIsoTilemap.super.destroy(self)
end
