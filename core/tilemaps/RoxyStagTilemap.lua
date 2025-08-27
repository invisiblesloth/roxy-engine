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

--------------------------------------------------------------------------------
-- ! Class Definition / Initialize
--------------------------------------------------------------------------------

class("RoxyStagTilemap").extends(RoxyTilemap)

function RoxyStagTilemap:init(jsonPath, opts, scene)
  opts = opts or {}
  opts.wrapInSprites = false
  opts.anchor = "topLeft"
  RoxyStagTilemap.super.init(self, jsonPath, opts, scene)

  -- Scratch reused across frames to avoid allocations in _drawStaticLayerChunked
  self._scratchToDraw = {} -- { {img=..., dx=..., dy=...}, ... }

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

      -- Create native renderer instance for this layer
      if layerData.imageTable and newTileRenderer_C then
        -- Sanitize tiles once on load so the native blob never sees out-of-range values
        sanitizeTilesInPlace(layerData.tilesFlat, layerData.imageCount)

        local isIsometric = 0
        local staggerIndexOdd = (self.staggerIndex == "odd") and 1 or 0
        local staggerDirectionRight = (self.staggerDirection == "right") and 1 or 0

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
      local tileWidth = layer.tileWidth or 0
      local halfWidth = layer.halfWidth or floor(tileWidth * 0.5)

      local tallOverdraw = 0
      if layer.maxImageHeight and layer.tileHeight then
        tallOverdraw = max(0, ceil((layer.maxImageHeight - layer.tileHeight) * 0.5))
      end

      local overlap = layerOpts.overlapPx or max(halfWidth, tallOverdraw, DEFAULT_CHUNK_OVERLAP)
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
  while built < BUILD_BUDGET and #self._warmQueue > 0 do
    local job = dequeueBestWarmJob(self)
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

-- ! Build Chunk
function RoxyStagTilemap:_buildChunk(layerConfig, chunkX, chunkY)
  local size, overlap = layerConfig.size, layerConfig.overlap
  local width, height = size + 2 * overlap, size + 2 * overlap
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

  -- Respect stagger axis/index/direction like the fast path
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

  -- First pass — scan for any missing chunks and enqueue builds.
  local anyMissing = false
  local toDraw = self._scratchToDraw
  local count = 0

  local imageWidth, imageHeight = layerConfig.imageWidth, layerConfig.imageHeight

  for chunkY = minY, maxY do
    local rowDeltaY = chunkY * size - overlap + screenY
    for chunkX = minX, maxX do
      local key = layerConfig.keyPrefix .. chunkX .. ":" .. chunkY
      local img = getCachedAsset(self._globalChunkBucket, key)
      if img then
        local dx = chunkX * size - overlap + screenX
        local dy = rowDeltaY
        if dx < DISPLAY_WIDTH and dy < DISPLAY_HEIGHT and (dx + imageWidth) > 0 and (dy + imageHeight) > 0 then
          count += 1
          local slot = toDraw[count]
          if slot then
            slot.img, slot.dx, slot.dy = img, dx, dy
          else
            toDraw[count] = { img = img, dx = dx, dy = dy }
          end
        end
      else
        anyMissing = true
        self:_enqueueWarm(layerConfig, chunkX, chunkY)
      end
    end
  end

  if anyMissing then
    setClipRect(0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT)
      self:drawLayerRows(layerName, nil, nil, nil, nil)
    clearClipRect()
    -- Trim scratch table length for next frame
    for i = count + 1, #toDraw do toDraw[i] = nil end
    return
  end

  for i = 1, count do
    local e = toDraw[i]
    e.img:draw(e.dx, e.dy)
  end
  -- Trim for next frame
  for i = count + 1, #toDraw do toDraw[i] = nil end
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

  local cameraX = self._cameraX ~= nil and self._cameraX or select(1, getCameraPosition())
  local cameraY = self._cameraY ~= nil and self._cameraY or select(2, getCameraPosition())

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

  local cameraX = self._cameraX ~= nil and self._cameraX or select(1, getCameraPosition())
  local cameraY = self._cameraY ~= nil and self._cameraY or select(2, getCameraPosition())

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

  -- CHANGE: explicit bounds check to avoid native issues
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
-- Request forced redraws for N frames (e.g., 1–2 frames around transition end)
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
