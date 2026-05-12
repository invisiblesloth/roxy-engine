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
local setCameraBounds   <const> = Camera.setBounds

local _isoDrawOffsets   <const> = RoxyTilemap._isoDrawOffsets
local _beginManualDraw  <const> = RoxyTilemap._beginManualDraw
local _endManualDraw    <const> = RoxyTilemap._endManualDraw

local TilemapHelpers          <const> = r.TilemapHelpers
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
local DEFAULT_CHUNK_SIZE    <const> = 256 -- tileWidth * 4
local DEFAULT_CHUNK_CACHE   <const> = 200
local DEFAULT_CHUNK_OVERLAP <const> = 32

-- Cull margins / epsilon
local TILE_MARGIN          <const> = 0.5 -- Coarse safety margin for dynamic draw
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

-- ! Helper: Camera Position
-- Reuse drawVisible's camera stamp during a frame; otherwise query once.
local function _cameraPositionFor(self)
  local cameraX, cameraY = self._cameraX, self._cameraY
  if cameraX ~= nil and cameraY ~= nil then
    return cameraX, cameraY
  end
  return getCameraPosition()
end

-- ! Helper: Staggered Layer Image Bounds
local function _staggeredLayerImageBounds(self, layer)
  local mapWidth = layer.mapWidth or 0
  local mapHeight = layer.mapHeight or 0
  if mapWidth <= 0 or mapHeight <= 0 then return nil end

  local tileWidth = layer.tileWidth or 0
  local tileHeight = layer.tileHeight or 0
  local halfWidth = layer.halfWidth or tileWidth * 0.5
  local halfHeight = layer.halfHeight or tileHeight * 0.5

  local maxImageHeight = layer.maxImageHeight or tileHeight
  if maxImageHeight < tileHeight then
    maxImageHeight = tileHeight
  end

  local originX = layer.originX or 0
  local originY = layer.originY or 0

  local minShift = math.huge
  local maxShift = -math.huge
  for row0 = 0, mapHeight - 1 do
    local shift = _rowShiftX_for_row0(self, row0, halfWidth)
    if shift < minShift then minShift = shift end
    if shift > maxShift then maxShift = shift end
  end
  if minShift == math.huge then minShift = 0 end
  if maxShift == -math.huge then maxShift = 0 end

  local layerMinX = originX + minShift
  local layerMaxX = originX + (mapWidth - 1) * tileWidth + maxShift + tileWidth

  local layerMinY = originY + tileHeight - maxImageHeight
  local layerMaxY = originY + (mapHeight - 1) * halfHeight + tileHeight

  return layerMinX, layerMinY, layerMaxX, layerMaxY
end

-- ! Helper: Layer Image Anchor Offset
local function _layerImageAnchorOffset(self, primaryLayer, minPixelX, minPixelY, pixelWidth, pixelHeight)
  local anchor = (primaryLayer.anchor or (self._opts and self._opts.anchor)) or "center"
  if anchor == "topLeft" then
    return (primaryLayer.originX or 0) - minPixelX,
      (primaryLayer.originY or 0) - minPixelY
  end

  return (primaryLayer.originX or 0) - (minPixelX + pixelWidth * 0.5),
    (primaryLayer.originY or 0) - (minPixelY + pixelHeight * 0.5)
end

--------------------------------------------------------------------------------
-- ! Class Definition / Initialize
--------------------------------------------------------------------------------

class("RoxyStagTilemap").extends(RoxyTilemap)

-- ! Initialize
function RoxyStagTilemap:init(jsonPath, opts, scene)
  opts = opts or {}
  opts.wrapInSprites = false
  opts.anchor = "topLeft"
  RoxyStagTilemap.super.init(self, jsonPath, opts, scene)

  -- Scratch reused across frames to avoid allocations in _drawStaticLayerChunked
  self._chunkDrawScratch = { images = {}, xs = {}, ys = {} }

  -- Override world size for staggered-y projection
  local mapWidthTiles   = self.mapWidth  or 0
  local mapHeightTiles  = self.mapHeight or 0
  local tileWidth       = self.mapTileWidth or 0
  local tileHeight      = self.mapTileHeight or 0

  local halfWidthPx   = tileWidth * 0.5
  local halfHeightPx  = tileHeight * 0.5

  -- Horizontal span: columns plus stagger overhang
  self.worldWidth = mapWidthTiles * tileWidth + halfWidthPx

  -- Vertical span: rows spaced by halfHeight
  local worldHeightBase = mapHeightTiles * halfHeightPx

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

  -- Store camera bounds for attach/apply time; constructors are load-only.
  if opts and opts.cameraBounds then
    self:updateCameraBounds(false)
  end

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
function RoxyStagTilemap:_createNativeRenderer(layerData)
  if not layerData or not layerData.imageTable or not newTileRenderer_C then return end

  sanitizeTilesInPlace(layerData.tilesFlat, layerData.imageCount)

  local staggerIndexOdd = (self.staggerIndex == "odd") and 1 or 0
  local staggerDirectionRight = (self.staggerDirection == "right") and 1 or 0

  --#DEBUG START
  if (layerData.tileWidth or 0) <= 0 or (layerData.tileHeight or 0) <= 0
     or (layerData.halfWidth or 0) <= 0 or (layerData.halfHeight or 0) <= 0 then
    Log.error("[RoxyStagTilemap] Invalid tile metrics; width/height/halves must be > 0")
  end
  --#DEBUG END

  layerData._nativeRenderer = newTileRenderer_C(
    0,                        -- Staggered
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
  syncNativeTiles(layerData)
end

-- ! Refresh Projection Layer Render Resources
function RoxyStagTilemap:_refreshProjectionLayerRenderResources(layerName, layerData)
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
    layerConfig.imageWidth = layerConfig.size + 2 * layerConfig.overlap
    layerConfig.imageHeight = layerConfig.imageWidth
    layerConfig._dirty = true
  end

  self:_preloadLayerCaches(layerData)
  self:_createNativeRenderer(layerData)
end

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
      local overlap = layerOpts.overlapPx or _autoChunkOverlap(layer)
      local size    = max(1, layerOpts.chunkSizePx or DEFAULT_CHUNK_SIZE)

      self._staticChunkLayers[layerName] = {
        name      = layerName,
        layer     = layer,
        size      = size,
        overlap   = overlap,
        keyPrefix = "chunk:" .. (self._mapCacheId or "map") .. ":" .. tostring(layer.tiledId or layerName) .. ":",
        _dirty    = true,
        imageWidth  = size + 2 * overlap,
        imageHeight = size + 2 * overlap,
        _explicitOverlap = layerOpts.overlapPx ~= nil,
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
function RoxyStagTilemap:_rebuildOrderedLayers()
  RoxyTilemap._rebuildOrderedLayers(self)
end

-- ! Preload Layer Caches
function RoxyStagTilemap:_preloadLayerCaches(layerData)
  layerData._imageCache  = layerData._imageCache  or {}
  layerData._offsetCache = layerData._offsetCache or {}
end

--
-- Chunk building & warming
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
  local centerCache = {}
  while built < BUILD_BUDGET and #self._warmQueue > 0 do
    local job = dequeueBestWarmJob(self, centerCache)
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
    -- Ensure at least one redraw even if camera is stationary
    self._forceDrawFrames = max(self._forceDrawFrames or 0, 1)
  end
end

-- ! Has Warm Work
-- True when there are chunks waiting to build
function RoxyStagTilemap:_hasWarmWork()
  return self._warmQueue and #self._warmQueue > 0
end

-- ! Render Layer to Image
function RoxyStagTilemap:_renderLayerToImage(layerName, opts)
  local primaryLayer = self:_getValidLayer(layerName)
  if not primaryLayer then return nil end

  local compositeLayers = opts and opts.compositeLayers
  if type(compositeLayers) ~= "table" or #compositeLayers == 0 then
    -- Fast path avoids queue, entry, and sort overhead for common single-layer renders
    local minScreenX, minScreenY, maxScreenX, maxScreenY = _staggeredLayerImageBounds(self, primaryLayer)
    if not minScreenX then return nil end

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
      local bufferOffsetX = (primaryLayer.originX or 0) - minPixelX
      local bufferOffsetY = (primaryLayer.originY or 0) - minPixelY
      self:_renderLayerToBuffer(primaryLayer, image, bufferOffsetX, bufferOffsetY, pixelWidth, pixelHeight)
    popContext()

    local anchorOffsetX, anchorOffsetY =
      _layerImageAnchorOffset(self, primaryLayer, minPixelX, minPixelY, pixelWidth, pixelHeight)
    return image, anchorOffsetX, anchorOffsetY
  end

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

  for index = 1, #compositeLayers do
    local compositeName = compositeLayers[index]
    if type(compositeName) == "string" then
      enqueueLayer(compositeName, self:_getValidLayer(compositeName))
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
    local layerMinX, layerMinY, layerMaxX, layerMaxY = _staggeredLayerImageBounds(self, layer)
    if layerMinX then
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

  local offsetX, offsetY =
    _layerImageAnchorOffset(self, primaryLayer, minPixelX, minPixelY, pixelWidth, pixelHeight)
  return image, offsetX, offsetY
end

-- ! Build Chunk
function RoxyStagTilemap:_buildChunk(layerConfig, chunkX, chunkY)
  local size, overlap = layerConfig.size, layerConfig.overlap
  local width, height = layerConfig.imageWidth, layerConfig.imageHeight
  local img = newImage(width, height)
  if not img then
    -- Low-memory guard
    Log.warn("[RoxyStagTilemap] Failed to allocate chunk image (%dx%d)", width, height)
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
function RoxyStagTilemap:_enqueueRing(layerData, layerConfig)
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
function RoxyStagTilemap:_renderLayerToBuffer(layerData, targetImage, offsetX, offsetY, bufferWidth, bufferHeight)
  local nativeRenderer = layerData._nativeRenderer

  -- Fast path: native renderer to a real LCDBitmap
  if nativeRenderer and targetImage ~= nil then
    recordPerfCount("tilemap.nativeBuffer.stag") --#DEBUG
    nativeRenderer:renderToBuffer(targetImage, offsetX, offsetY, bufferWidth, bufferHeight)
    return
  end

  -- Fallback Lua implementation (rare in practice)
  recordPerfCount("tilemap.luaBuffer.stag") --#DEBUG
  Log.debug("[_renderLayerToBuffer] Falling back on Lua implementation") --#DEBUG

  local imageTable = layerData.imageTable
  local mapWidth, mapHeight = layerData.mapWidth, layerData.mapHeight
  if not mapWidth or not mapHeight or not imageTable then return end

  local n = layerData.imageCount
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local halfWidth, halfHeight = layerData.halfWidth, layerData.halfHeight

  -- Respect stagger axis/index/direction like the fast path
  -- ! Helper: Row Shift X
  local function rowShiftX(row0) return _rowShiftX_for_row0(self, row0, halfWidth) end

  local maxImageHeight = layerData.maxImageHeight or 0
  local overdrawRows = ceil(max(0, maxImageHeight - tileHeight) / max(1, halfHeight)) + 1 -- Safety +1

  local minRow0 = floor((-offsetY - maxImageHeight) / halfHeight) - 1
  local maxRow0 = ceil ((bufferHeight - offsetY) / halfHeight) + 1
  minRow0 = max(0, minRow0 - overdrawRows)
  maxRow0 = min(mapHeight - 1, maxRow0 + overdrawRows)

  local tiles  = layerData.tilesFlat
  local stride = layerData.tilesStride or mapWidth  -- Restore fallback

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

--
-- Chunked draw (with single-pass fallback)
--

-- ! Draw Static Layer Chunked
-- Render a chunked layer using prebuilt chunk images (row-clipped fallback)
function RoxyStagTilemap:_drawStaticLayerChunked(layerName)
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
  local imageWidth, imageHeight = layerConfig.imageWidth, layerConfig.imageHeight
  local scratch = self._chunkDrawScratch
  local images, xs, ys = scratch.images, scratch.xs, scratch.ys
  local drawCount = 0

  for chunkY = minY, maxY do
    local rowDeltaY = chunkY * size - overlap + screenY
    for chunkX = minX, maxX do
      local key = layerConfig.keyPrefix .. chunkX .. ":" .. chunkY
      local img = getCachedAsset(self._globalChunkBucket, key)
      if img then
        recordPerfCount("tilemap.chunkHit.stag") --#DEBUG
        local dx = chunkX * size - overlap + screenX
        local dy = rowDeltaY
        if dx < DISPLAY_WIDTH and dy < DISPLAY_HEIGHT and (dx + imageWidth) > 0 and (dy + imageHeight) > 0 then
          drawCount += 1
          images[drawCount] = img
          xs[drawCount] = dx
          ys[drawCount] = dy
        end
      else
        recordPerfCount("tilemap.chunkMiss.stag") --#DEBUG
        anyMissing = true
        self:_enqueueWarm(layerConfig, chunkX, chunkY)
      end
    end
  end

  if anyMissing then
    clearChunkDrawScratch(scratch, drawCount)
    setClipRect(0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT)
      self:drawLayerRows(layerName, nil, nil, nil, nil)
    clearClipRect()
    return
  end

  for index = 1, drawCount do
    images[index]:draw(xs[index], ys[index])
  end
  clearChunkDrawScratch(scratch, drawCount)
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

  local cameraX, cameraY = _cameraPositionFor(self)

  local row0 = floor(worldY + FLOAT_EPSILON)
  local shiftX = _rowShiftX_for_row0(self, row0, halfWidth)

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

  local cameraX, cameraY = _cameraPositionFor(self)

  local parallaxOriginX = layerData.parallaxoriginx or 0
  local parallaxOriginY = layerData.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local deltaX = (screenX + cameraX * parallaxX) - (originX + pivotAdjustX)
  local deltaY = (screenY + cameraY * parallaxY) - (originY + pivotAdjustY)

  local worldY = deltaY / halfHeight
  local row0 = floor(worldY + FLOAT_EPSILON)
  local shiftX = _rowShiftX_for_row0(self, row0, halfWidth)

  local worldX = (deltaX - shiftX) / tileWidth
  return worldX, worldY
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Mark Dirty
-- Public dirty marker for external animation/parallax/etc
function RoxyStagTilemap:markDirty(redrawBackground)
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
function RoxyStagTilemap:setTileAt(layerName, x, y, tileIndex, updateSprite)
  local layer = self.layers and self.layers[layerName]
  if not layer then return end

  -- Explicit bounds check to avoid native issues
  local mapWidth, mapHeight = layer.mapWidth or 0, layer.mapHeight or 0
  if x < 1 or y < 1 or x > mapWidth or y > mapHeight then
    Log.warn("[RoxyStagTilemap] setTileAt out of bounds (".. x .. ", ".. y .. ") not in [1..".. mapWidth .. ",1.." .. mapHeight .."]") --#DEBUG
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
function RoxyStagTilemap:getRowFromScreen(screenX, screenY, layerName)
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
function RoxyStagTilemap:resortLayers()
  self:_rebuildOrderedLayers()
end

-- ! Mark Tiles Dirty
-- Tile edits --> evict overlapping chunks (they will rebuild lazily)
function RoxyStagTilemap:markTilesDirty(layerName, tileX, tileY, tileCountWidth, tileCountHeight)
  self:markLayerImageDirty(layerName)

  local layerConfig = self._staticChunkLayers[layerName]
  if not layerConfig then return end

  self._frameDirty = true

  local tileWidth, tileHeight = layerConfig.layer.tileWidth, layerConfig.layer.tileHeight
  local pixelX = (tileX - 1) * tileWidth
  local pixelY = (tileY - 1) * (tileHeight * 0.5)
  local pixelWidth = (tileCountWidth or 1) * tileWidth
  local pixelHeight = (tileCountHeight or 1) * (tileHeight * 0.5)

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
function RoxyStagTilemap:draw(layerName)
  local layerData = self.layers and self.layers[layerName]
  if not layerData or not layerData.tilemap or layerData.visible == false then return end

  if self._staticChunkLayers[layerName] then
    self:_drawStaticLayerChunked(layerName); return
  end

  -- Dynamic fallback (rare): draw only visible rows and columns with coarse margin
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

  -- Do not early-out if we are within a forced-draw window
  if (self._forceDrawFrames or 0) == 0 and cameraUnchanged and not self._frameDirty and not hasWarmWork then
    return -- Nothing to do this frame.
  end

  self._lastCameraX, self._lastCameraY = cameraX, cameraY
  self._frameDirty = false -- We will render now; clear until something changes again

  -- Consume one forced frame if active
  if self._forceDrawFrames and self._forceDrawFrames > 0 then
    self._forceDrawFrames -= 1
  end

  self._cameraX, self._cameraY = cameraX, cameraY

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

  -- Clear camera cache after use
  self._cameraX, self._cameraY = nil, nil
end

-- ! Draw Visible in Rectangle
function RoxyStagTilemap:drawVisibleInRect(x, y, width, height)
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
function RoxyStagTilemap:forceRedraw(frames)
  -- Keep the largest pending window; do not shrink an existing request
  local n = max(0, frames or 1)
  if (self._forceDrawFrames or 0) < n then
    self._forceDrawFrames = n
  end
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
    local cameraX, cameraY      = _cameraPositionFor(self)

    local tr = layerData._nativeRenderer
    if tr then
      recordPerfCount("tilemap.nativeRows.stag") --#DEBUG
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
  recordPerfCount("tilemap.luaRows.stag") --#DEBUG

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
  local cameraX, cameraY      = _cameraPositionFor(self)
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

  RoxyStagTilemap.super.destroy(self)
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

local scene = RoxyScene()

local map = RoxyStagTilemap("assets/maps/isometric-test-4.json", {
  cameraBounds = true,
  layerOptions = {
    ground = {
      preRenderChunked = true,
      chunkSizePx = 256,
      overlapPx = 32,
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

map:setTileAt("ground", 8, 10, 2, true)
map:markTilesDirty("ground", 8, 10, 2, 2)

local row = map:getRowFromScreen(200, 120, "ground")
map:drawLayerRows("ground", 1, row, 1, 16)

local previewImage, offsetX, offsetY = map:getLayerImage("ground")

map:drawVisibleInRect(0, 0, 400, 240)
map:destroy()

]]
