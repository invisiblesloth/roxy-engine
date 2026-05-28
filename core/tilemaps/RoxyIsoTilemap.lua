-- core/tilemaps/RoxyIsoTilemap.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r               <const> = roxy
local Camera          <const> = r.Camera
local Cache           <const> = r.Cache
local RoxyGraphics    <const> = r.Graphics
local TilemapHelpers  <const> = r.TilemapHelpers

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
local getShakeOffset    <const> = Camera.getShakeOffset
local setCameraBounds   <const> = Camera.setBounds

local _isoDrawOffsets   <const> = RoxyTilemap._isoDrawOffsets
local _beginManualDraw  <const> = RoxyTilemap._beginManualDraw
local _endManualDraw    <const> = RoxyTilemap._endManualDraw

local visibleLayerRect        <const> = TilemapHelpers.visibleLayerRect
local chunkIndicesForRect     <const> = TilemapHelpers.chunkIndicesForRect
local findFirstAvailableLayer <const> = TilemapHelpers.findFirstAvailableLayer
local sanitizeTileIndex       <const> = TilemapHelpers.sanitizeTileIndex
local sanitizeTilesInPlace    <const> = TilemapHelpers.sanitizeTilesInPlace
local syncNativeTiles         <const> = TilemapHelpers.syncNativeTiles
local dequeueBestWarmJob      <const> = TilemapHelpers.dequeueBestWarmJob
local clearChunkDrawScratch   <const> = TilemapHelpers.clearChunkDrawScratch
local recordPerfCount         <const> = TilemapHelpers.recordPerfCount --#DEBUG

-- C-side bindings
local newTileRenderer_C <const> = RoxyTileRendererC and RoxyTileRendererC.new or nil

-- Default chunk settings
local DEFAULT_CHUNK_SIZE    <const> = 320 -- Adjusted for iso diamond (e.g., tileWidth * 5)
local DEFAULT_CHUNK_CACHE   <const> = 200
local DEFAULT_CHUNK_OVERLAP <const> = 32

local VISIBLE_MARGIN_TILES <const> = 2

local PREFETCH_RINGS  <const> = 1  -- 1 ring beyond visible
local BUILD_BUDGET    <const> = 2  -- Build at most 2 chunks per frame

local DISPLAY_WIDTH   <const> = RoxyGraphics.displayWidth
local DISPLAY_HEIGHT  <const> = RoxyGraphics.displayHeight

local COLOR_CLEAR <const> = Graphics.kColorClear

--------------------------------------------------------------------------------
-- ! Class Definition / Initialize
--------------------------------------------------------------------------------

class("RoxyIsoTilemap").extends(RoxyTilemap)

-- ! Initialize
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

  -- Store camera bounds for attach/apply time; constructors are load-only
  if opts and opts.cameraBounds then
    self:updateCameraBounds(false)
  end

  self._projection = "iso"

  -- Static / chunk config and ordered layers
  self._staticChunkLayers = {}
  self._orderedLayers = {}

  self._warmQueue = {}  -- Queue of { layerConfig, chunkX, chunkY, key }
  self._warmSet = {}  -- Tracks keys already queued
  self._chunkDrawScratch = { images = {}, xs = {}, ys = {} }

  self._didPrimeVisible = false -- One-time prime flag
  self._frameDirty = true -- Assume dirty until first frame settles
  self._forceDrawFrames = 0 -- Track a small "force draw" window for explicit repaints
  self._lastCameraX, self._lastCameraY = nil, nil -- Camera stamp

  -- Map-scoped cache key namespace
  self._mapCacheId = jsonPath or tostring(self)

  self:_initializeStaticLayers(opts)

  for _, layerData in pairs(self.layers) do
    if layerData.tilemap then
      self:_preloadLayerCaches(layerData)
      self:_createNativeRenderer(layerData)
    end
  end

  self:_rebuildOrderedLayers()
end

--------------------------------------------------------------------------------
-- Internal API
--------------------------------------------------------------------------------

-- ! Auto Chunk Overlap
local function _autoChunkOverlap(layer)
  local tileWidth = layer.tileWidth or 0
  local halfWidth = layer.halfWidth or floor(tileWidth * 0.5)
  local tileHeight = layer.tileHeight or 0
  local maxImageHeight = layer.maxImageHeight or tileHeight
  local tallOverdraw = max(0, ceil(maxImageHeight - tileHeight))

  return max(halfWidth, tallOverdraw, DEFAULT_CHUNK_OVERLAP)
end

-- ! Create Native Renderer
function RoxyIsoTilemap:_createNativeRenderer(layerData)
  if not layerData or not layerData.imageTable or not newTileRenderer_C then return end

  --#DEBUG START
  if (layerData.tileWidth or 0) <= 0 or (layerData.tileHeight or 0) <= 0
     or (layerData.halfWidth or 0) <= 0 or (layerData.halfHeight or 0) <= 0 then
    error("[RoxyIsoTilemap] Invalid tile metrics; width/height/halves must be > 0")
  end
  --#DEBUG END

  local halfWidth = layerData.halfWidth or 0
  local halfHeight = layerData.halfHeight or 0
  if halfWidth ~= floor(halfWidth) or halfHeight ~= floor(halfHeight) then
    layerData._nativeRenderer = nil
    Log.warn("[RoxyIsoTilemap] Fractional half-tile metrics; using Lua renderer fallback") --#DEBUG
    return
  end

  sanitizeTilesInPlace(layerData.tilesFlat, layerData.imageCount)

  layerData._nativeRenderer = newTileRenderer_C(
    1,                        -- Isometric
    0,                        -- staggerIndexOdd
    0,                        -- staggerDirectionRight
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
  syncNativeTiles(layerData)
end

-- ! Refresh Projection Layer Render Resources
function RoxyIsoTilemap:_refreshProjectionLayerRenderResources(layerName, layerData)
  if not layerData then return end

  if layerData._nativeRenderer then
    layerData._nativeRenderer:destroy()
    layerData._nativeRenderer = nil
  end

  local layerConfig = self._staticChunkLayers and self._staticChunkLayers[layerName]
  if layerConfig then
    if not layerConfig._explicitOverlap then
      layerConfig.overlap = _autoChunkOverlap(layerData)
    end
    layerConfig.bufferWidth = layerConfig.size + 2 * layerConfig.overlap
    layerConfig.bufferHeight = layerConfig.bufferWidth
    layerConfig._dirty = true
  end

  self:_preloadLayerCaches(layerData)
  self:_createNativeRenderer(layerData)
end

-- ! Project Dirty Tile Rect
function RoxyIsoTilemap:_projectDirtyTileRect(layerConfig, tileX, tileY, tileCountWidth, tileCountHeight)
  local layer = layerConfig and layerConfig.layer
  if not layer then return 0, 0, 0, 0 end

  local halfWidth = layer.halfWidth or ((layer.tileWidth or 0) * 0.5)
  local halfHeight = layer.halfHeight or ((layer.tileHeight or 0) * 0.5)
  local tileWidth = layer.tileWidth or 0
  local tileHeight = layer.tileHeight or 0
  local tallOverdraw = max(0, (layer.maxImageHeight or tileHeight) - tileHeight)

  local minColumn = (tileX or 1) - 1
  local minRow = (tileY or 1) - 1
  local maxColumn = minColumn + (tileCountWidth or 1)
  local maxRow = minRow + (tileCountHeight or 1)

  local minX, minY = math.huge, math.huge
  local maxX, maxY = -math.huge, -math.huge

  -- ! Helper: Include Projected Tile
  local function include(column, row)
    local screenX = (column - row) * halfWidth
    local screenY = (column + row) * halfHeight
    if screenX < minX then minX = screenX end
    if screenX > maxX then maxX = screenX end
    if screenY < minY then minY = screenY end
    if screenY > maxY then maxY = screenY end
  end

  include(minColumn, minRow)
  include(maxColumn, minRow)
  include(minColumn, maxRow)
  include(maxColumn, maxRow)

  minX -= tileWidth
  maxX += tileWidth
  minY -= tallOverdraw

  return minX, minY, max(1, maxX - minX), max(1, maxY - minY + tallOverdraw)
end

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
      local overlap = layerOpts.overlapPx or _autoChunkOverlap(layer)
      local size = max(1, layerOpts.chunkSizePx or DEFAULT_CHUNK_SIZE)
      local bufferSize = size + 2 * overlap

      self._staticChunkLayers[layerName] = {
        name         = layerName,
        layer        = layer,
        size         = size,
        overlap      = overlap,
        bufferWidth  = bufferSize,
        bufferHeight = bufferSize,
        keyPrefix    = "chunk:" .. (self._mapCacheId or "map") .. ":" .. tostring(layer.tiledId or layerName) .. ":",
        _dirty       = true, -- Per-layer dirty bit
        _explicitOverlap = layerOpts.overlapPx ~= nil,
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

    local visibleX, visibleY, visibleWidth, visibleHeight = visibleLayerRect(self, layer)
    visibleX -= overlap; visibleY -= overlap; visibleWidth += 2 * overlap; visibleHeight += 2 * overlap

    local minX, maxX, minY, maxY = chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)
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
  RoxyTilemap._rebuildOrderedLayers(self)
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
  local centerCache = {}
  while built < BUILD_BUDGET and #self._warmQueue > 0 do
    local job = dequeueBestWarmJob(self, centerCache) -- Pick closest
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

-- ! Render Layer to Image
function RoxyIsoTilemap:_renderLayerToImage(layerName, opts)
  local primaryLayer = self:_getValidLayer(layerName)
  if not primaryLayer then return nil end

  local renderQueue = {}
  local seen = {}
  local order = 0

  -- ! Helper: Enqueue Layer
  local function enqueueLayer(name, layer)
    if not layer or seen[layer] then return end

    seen[layer] = true
    order += 1

    renderQueue[#renderQueue + 1] = {
      layer = layer,
      name = name,
      z = layer.zIndex or 0,
      order = order,
    }
  end

  enqueueLayer(layerName, primaryLayer)

  if opts and opts.compositeLayers then
    for index = 1, #opts.compositeLayers do
      local compositeName = opts.compositeLayers[index]
      if type(compositeName) == "string" then
        enqueueLayer(compositeName, self:_getValidLayer(compositeName))
      end
    end
  end

  if #renderQueue == 0 then return nil end

  tableSort(renderQueue, function(a, b)
    if a.z == b.z then return a.order < b.order end
    return a.z < b.z
  end)

  local minScreenX, minScreenY = math.huge, math.huge
  local maxScreenX, maxScreenY = -math.huge, -math.huge

  for index = 1, #renderQueue do
    local layer = renderQueue[index].layer
    local mapWidth = layer.mapWidth or 0
    local mapHeight = layer.mapHeight or 0
    if mapWidth > 0 and mapHeight > 0 then
      local halfWidth = layer.halfWidth or (layer.tileWidth or 0) * 0.5
      local halfHeight = layer.halfHeight or (layer.tileHeight or 0) * 0.5
      local tileWidth = layer.tileWidth or 0
      local tileHeight = layer.tileHeight or 0

      local maxImageHeight = layer.maxImageHeight or tileHeight
      if maxImageHeight < tileHeight then
        maxImageHeight = tileHeight
      end

      local originX = layer.originX or 0
      local originY = layer.originY or 0

      local layerMinX = originX - (mapHeight - 1) * halfWidth
      local layerMaxX = originX + (mapWidth - 1) * halfWidth + tileWidth

      local layerMinY = originY + tileHeight - maxImageHeight
      local layerMaxY = originY + (mapWidth + mapHeight - 2) * halfHeight + tileHeight

      if layerMinX < minScreenX then minScreenX = layerMinX end
      if layerMaxX > maxScreenX then maxScreenX = layerMaxX end
      if layerMinY < minScreenY then minScreenY = layerMinY end
      if layerMaxY > maxScreenY then maxScreenY = layerMaxY end
    end
  end

  if minScreenX == math.huge or minScreenY == math.huge then
    return nil
  end

  local minPixelX = floor(minScreenX)
  local minPixelY = floor(minScreenY)
  local maxPixelX = ceil(maxScreenX)
  local maxPixelY = ceil(maxScreenY)

  local pixelWidth = max(0, maxPixelX - minPixelX)
  local pixelHeight = max(0, maxPixelY - minPixelY)
  if pixelWidth <= 0 or pixelHeight <= 0 then return nil end

  local image = newImage(pixelWidth, pixelHeight)
  if not image then return nil end

  pushContext(image)
    clear(COLOR_CLEAR)
    for index = 1, #renderQueue do
      local layer = renderQueue[index].layer
      local offsetX = (layer.originX or 0) - minPixelX
      local offsetY = (layer.originY or 0) - minPixelY
      self:_renderLayerToBuffer(layer, image, offsetX, offsetY, pixelWidth, pixelHeight)
    end
  popContext()

  local anchor = (primaryLayer.anchor or (self._opts and self._opts.anchor)) or "center"
  local offsetX, offsetY
  if anchor == "topLeft" then
    offsetX = (primaryLayer.originX or 0) - minPixelX
    offsetY = (primaryLayer.originY or 0) - minPixelY
  else
    offsetX = (primaryLayer.originX or 0) - (minPixelX + pixelWidth * 0.5)
    offsetY = (primaryLayer.originY or 0) - (minPixelY + pixelHeight * 0.5)
  end

  return image, offsetX, offsetY
end

-- ! Build Chunk
function RoxyIsoTilemap:_buildChunk(layerConfig, chunkX, chunkY)
  local size, overlap = layerConfig.size, layerConfig.overlap
  local width, height = layerConfig.bufferWidth, layerConfig.bufferHeight
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

  local visibleX, visibleY, visibleWidth, visibleHeight = visibleLayerRect(self, layerData)
  visibleX -= (overlap + size * PREFETCH_RINGS)
  visibleY -= (overlap + size * PREFETCH_RINGS)
  visibleWidth  += 2 * (overlap + size * PREFETCH_RINGS)
  visibleHeight += 2 * (overlap + size * PREFETCH_RINGS)

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)

  -- Skip if ring bounds didn't change
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
    recordPerfCount("tilemap.nativeBuffer.iso") --#DEBUG
    nativeRenderer:renderToBuffer(targetImage, offsetX, offsetY, bufferWidth, bufferHeight)
    return
  end

  -- Fallback Lua implementation (rare in practice)
  recordPerfCount("tilemap.luaBuffer.iso") --#DEBUG
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
  local visibleX, visibleY, visibleWidth, visibleHeight = visibleLayerRect(self, layer)
  visibleX -= overlap; visibleY -= overlap
  visibleWidth += 2 * overlap; visibleHeight += 2 * overlap

  local minX, maxX, minY, maxY = chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)
  local screenX, screenY = self:worldToScreen(0, 0, layer)

  -- First pass - scan for any missing chunks and enqueue builds.
  local anyMissing = false
  local imageWidth, imageHeight = layerConfig.bufferWidth, layerConfig.bufferHeight

  local scratch = self._chunkDrawScratch
  local images, xs, ys = scratch.images, scratch.xs, scratch.ys
  local drawCount = 0

  for chunkY = minY, maxY do
    local rowDeltaY = chunkY * size - overlap + screenY
    for chunkX = minX, maxX do
      local key = layerConfig.keyPrefix .. chunkX .. ":" .. chunkY
      local img = getCachedAsset(self._globalChunkBucket, key)
      if img then
        recordPerfCount("tilemap.chunkHit.iso") --#DEBUG
        local dx = chunkX * size - overlap + screenX
        local dy = rowDeltaY
        -- Offscreen culling
        if dx < DISPLAY_WIDTH and dy < DISPLAY_HEIGHT and (dx + imageWidth) > 0 and (dy + imageHeight) > 0 then
          drawCount += 1
          images[drawCount] = img
          xs[drawCount] = dx
          ys[drawCount] = dy
        end
      else
        recordPerfCount("tilemap.chunkMiss.iso") --#DEBUG
        anyMissing = true
        self:_enqueueWarm(layerConfig, chunkX, chunkY)
      end
    end
  end

  if anyMissing then
    clearChunkDrawScratch(scratch, drawCount)
    -- Single-pass fallback - render the layer once (native rows or Lua), not per-miss.
    -- Clip to screen to be safe.
    setClipRect(0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT)
      self:drawLayerRows(layerName, nil, nil, nil, nil)
    clearClipRect()
    return
  end

  -- All chunks available - draw them.
  for index = 1, drawCount do
    -- The dx/dy values are already integers; removed floor() for a small win.
    images[index]:draw(xs[index], ys[index])
  end
  clearChunkDrawScratch(scratch, drawCount)
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
  local shakeX, shakeY = getShakeOffset()

  local isoX = originX + (worldX - worldY) * halfWidth
  local isoY = originY + (worldX + worldY) * halfHeight

  return round(isoX + pivotAdjustX - cameraX * parallaxX - shakeX),
         round(isoY + pivotAdjustY - cameraY * parallaxY - shakeY)
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
  local shakeX, shakeY = getShakeOffset()

  local deltaX = (screenX + shakeX + cameraX * parallaxX) - (originX + pivotAdjustX)
  local deltaY = (screenY + shakeY + cameraY * parallaxY) - (originY + pivotAdjustY)

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

  -- Explicit bounds check to avoid native issues
  local mapWidth, mapHeight = layer.mapWidth or 0, layer.mapHeight or 0
  if x < 1 or y < 1 or x > mapWidth or y > mapHeight then
    Log.warn("[RoxyIsoTilemap] setTileAt out of bounds (".. x .. ", ".. y .. ") not in [1..".. mapWidth .. ",1.." .. mapHeight .."]") --#DEBUG
    return
  end

  local cleanIndex = sanitizeTileIndex(tileIndex, layer.imageCount)

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

  self:_onLayerTilesChanged(layerName, layer)

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
    targetLayer = findFirstAvailableLayer(self.layers)
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
  self:markLayerImageDirty(layerName)

  local layerConfig = self._staticChunkLayers[layerName]
  if not layerConfig then return end

  self._frameDirty = true

  local pixelX, pixelY, pixelWidth, pixelHeight =
    self:_projectDirtyTileRect(layerConfig, tileX, tileY, tileCountWidth, tileCountHeight)

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    chunkIndicesForRect(pixelX, pixelY, pixelWidth, pixelHeight, layerConfig.size)
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
  local layerData = self.layers and self.layers[layerName]
  if not layerData or not layerData.tilemap or layerData.visible == false then return end

  if self._staticChunkLayers[layerName] then
    self:_drawStaticLayerChunked(layerName); return
  end

  -- Dynamic fallback (rare): draw only visible rows and columns with coarse margin
  local minTileX, minTileY, maxTileX, maxTileY = self:getVisibleTileBounds(layerData)

  self:drawLayerRows(layerName, minTileY, maxTileY, minTileX, maxTileX)
end

-- ! Draw Visible
-- Draw all visible layers in z-order, with smart skipping
function RoxyIsoTilemap:drawVisible()
  local cameraX, cameraY = getCameraPosition()
  local shakeX, shakeY = getShakeOffset()
  local cameraUnchanged = (self._lastCameraX == cameraX)
    and (self._lastCameraY == cameraY)
    and (self._lastShakeX == shakeX)
    and (self._lastShakeY == shakeY)
  local hasWarmWork = self:_hasWarmWork()

  -- Do not early-out if we are within a forced-draw window
  if (self._forceDrawFrames or 0) == 0 and cameraUnchanged and not self._frameDirty and not hasWarmWork then
    return -- Nothing to do this frame.
  end

  self._lastCameraX, self._lastCameraY = cameraX, cameraY
  self._lastShakeX, self._lastShakeY = shakeX, shakeY
  self._frameDirty = false -- We will render now; clear until something changes again

  -- Consume one forced frame if active
  if self._forceDrawFrames and self._forceDrawFrames > 0 then
    self._forceDrawFrames -= 1
  end

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
    -- Force this paint to occur at least this frame
    -- This does not make the renderer "always repaint"
    -- It is one-shot unless bumped again
    local n = (self._forceDrawFrames or 0)
    if n < 1 then self._forceDrawFrames = 1 end

    self:drawVisible()
  clearClipRect()
end

-- ! Force Redraw
-- Request forced redraws for N frames (e.g., 1-2 frames around transition end)
function RoxyIsoTilemap:forceRedraw(frames)
  -- Keep the largest pending window; do not shrink an existing request
  local n = max(0, frames or 1)
  if (self._forceDrawFrames or 0) < n then
    self._forceDrawFrames = n
  end
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
    local shakeX, shakeY        = getShakeOffset()

    local tr = layerData._nativeRenderer
    if tr then
      recordPerfCount("tilemap.nativeRows.iso") --#DEBUG
      tr:drawRows(
        rowStart, rowEnd,
        minX, maxX,
        originX - shakeX, originY - shakeY,
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
  recordPerfCount("tilemap.luaRows.iso") --#DEBUG

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
  local shakeX, shakeY        = getShakeOffset()
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  layerData._imageCache  = layerData._imageCache  or {}
  layerData._offsetCache = layerData._offsetCache or {}

  for tileY = rowStart, rowEnd do
    local row0 = tileY - 1

    -- Base isometric screen position for the leftmost column
    local baseScreenX = round(originX + ((minX - 1) - row0) * halfWidth + pivotAdjustX - cameraX * parallaxX - shakeX)
    local baseScreenY = round(originY + ((minX - 1) + row0) * halfHeight + pivotAdjustY - cameraY * parallaxY - shakeY)

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
  if self._destroyed or self._destroying then return end

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

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

local scene = RoxyScene()

local map = RoxyIsoTilemap("assets/maps/isometric-test-3.json", {
  cameraBounds = true,
  wrapInSprites = false,
  layerOptions = {
    ground = {
      preRenderChunked = true,
      chunkSizePx = 96,
      overlapPx = 32,
    },
    blocks = {
      preRenderChunked = true,
      chunkSizePx = 96,
      overlapPx = 32,
      zIndex = 10,
    },
  },
})
scene:addTilemap(map)

function scene:start()
  scene:activateCamera({ tilemap = map })
  map:forceRedraw(2)
end

function scene:draw()
  map:drawVisible()
end

map:setTileAt("blocks", 4, 6, 2, true)
map:markTilesDirty("blocks", 4, 6, 2, 2)

local row = map:getRowFromScreen(200, 120, "blocks")
map:drawLayerRows("blocks", 1, row, 1, 12)

roxy.Camera.shake(6, 0.35, 18)
-- Projection helpers include committed camera shake offsets
local screenX, screenY = map:worldToScreen(4, 6, map.layers.blocks)
local worldX, worldY = map:screenToWorld(screenX, screenY, map.layers.blocks)

local previewImage, offsetX, offsetY = map:getLayerImage("ground", {
  compositeLayers = { "blocks" },
})

map:drawVisibleInRect(0, 0, 400, 240)
map:destroy()

]]
