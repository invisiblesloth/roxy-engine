-- core/tilemaps/TilemapHelpers.lua

roxy = roxy or {}
roxy.TilemapHelpers = roxy.TilemapHelpers or {}
local TilemapHelpers <const> = roxy.TilemapHelpers

local r <const> = roxy

local floor <const> = math.floor
local abs   <const> = math.abs
local min   <const> = math.min
local max   <const> = math.max

local stringRep   <const> = string.rep
local stringPack  <const> = string.pack

local tableUnpack <const> = table.unpack

local DISPLAY_WIDTH  <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT <const> = r.Graphics.displayHeight

local NATIVE_SYNC_CHUNK_CELLS <const> = 512
local MAX_PACK_FORMAT_CACHE_CELLS <const> = 2048
local packU16Formats = {}

local function packU16Format(count)
  if count <= MAX_PACK_FORMAT_CACHE_CELLS then
    local format = packU16Formats[count]
    if not format then
      format = stringRep("<I2", count)
      packU16Formats[count] = format
    end
    return format
  end

  return stringRep("<I2", count)
end

-- ! Visible Layer Rectangle
-- Compute visible layer-space rect
function TilemapHelpers.visibleLayerRect(self, layer)
  local screenX, screenY = self:worldToScreen(0, 0, layer)
  return floor(-screenX), floor(-screenY), DISPLAY_WIDTH, DISPLAY_HEIGHT
end

-- ! Chunk Indices for Rect
-- Which chunk indices intersect a pixel rect?
function TilemapHelpers.chunkIndicesForRect(x, y, width, height, size)
  local minChunkX = floor(x / size)
  local maxChunkX = floor((x + width  - 1) / size)
  local minChunkY = floor(y / size)
  local maxChunkY = floor((y + height - 1) / size)
  return minChunkX, maxChunkX, minChunkY, maxChunkY
end

-- ! Find First Available Layer
function TilemapHelpers.findFirstAvailableLayer(layers)
  for _, layer in pairs(layers or {}) do
    if layer.tilemap then return layer end
  end
  return nil
end

-- ! Pack Tiles U16
-- Pack tiles as little-endian uint16 with clamping
function TilemapHelpers.packTilesU16(tiles)
  if not tiles or #tiles == 0 then return nil end
  local n = #tiles
  local format = packU16Format(n)
  local temp = {}
  for i = 1, n do
    local v = tiles[i] or 0
    if v < 0 then v = 0 elseif v > 0xFFFF then v = 0xFFFF end
    temp[i] = v
  end
  return stringPack(format, tableUnpack(temp, 1, n))
end

-- ! Pack Tiles U16 Range
-- Pack a 1-based tile range as little-endian uint16 with clamping
function TilemapHelpers.packTilesU16Range(tiles, startIndex, count)
  if not tiles or not startIndex or startIndex < 1 or not count or count <= 0 then return nil end
  local format = packU16Format(count)
  local temp = {}
  local sourceIndex = startIndex
  for outputIndex = 1, count do
    local v = tiles[sourceIndex] or 0
    if v < 0 then v = 0 elseif v > 0xFFFF then v = 0xFFFF end
    temp[outputIndex] = v
    sourceIndex = sourceIndex + 1
  end
  return stringPack(format, tableUnpack(temp, 1, count))
end

-- ! Sanitize a single tile index
-- Returns 0 for out-of-range/invalid, else the original index (1..imageCount)
function TilemapHelpers.sanitizeTileIndex(tileIndex, imageCount)
  if tileIndex == nil or type(tileIndex) ~= "number" then return 0 end
  if tileIndex == 0 then return 0 end
  if tileIndex < 1 or (imageCount and tileIndex > imageCount) then return 0 end
  return tileIndex
end

-- ! Sanitize tiles in place
-- Ensures every tile is 0 or in [1..imageCount]
function TilemapHelpers.sanitizeTilesInPlace(tiles, imageCount)
  if not tiles then return end
  for i = 1, #tiles do
    tiles[i] = TilemapHelpers.sanitizeTileIndex(tiles[i], imageCount)
  end
end

-- ! Sync Native Tiles
-- Sync native tiles from current tilesFlat
function TilemapHelpers.syncNativeTiles(layerData)
  if not layerData or not layerData._nativeRenderer or not layerData.tilesFlat then
    return
  end

  local renderer = layerData._nativeRenderer
  local tiles = layerData.tilesFlat
  local tileCount = #tiles
  local selfRef = layerData.ownerTilemap

  local function syncFull()
    local blob = TilemapHelpers.packTilesU16(tiles)
    if blob then
      renderer:updateTilesBytes(blob)
      if selfRef then selfRef._frameDirty = true end
    end
  end

  if type(renderer.updateTilesBytesRange) ~= "function" then
    syncFull()
    return
  end

  local startIndex = 1
  while startIndex <= tileCount do
    local count = min(NATIVE_SYNC_CHUNK_CELLS, tileCount - startIndex + 1)
    local blob = TilemapHelpers.packTilesU16Range(tiles, startIndex, count)
    if not blob or renderer:updateTilesBytesRange(blob, startIndex, count) ~= true then
      Log.warn("[TilemapHelpers.syncNativeTiles] Range sync failed; falling back to full sync") --#DEBUG
      syncFull()
      return
    end
    startIndex = startIndex + count
  end

  if selfRef then selfRef._frameDirty = true end
end

-- ! Native Sync Chunk Cells
function TilemapHelpers.nativeSyncChunkCells()
  return NATIVE_SYNC_CHUNK_CELLS
end

-- ! Record Perf Count
function TilemapHelpers.recordPerfCount(label, amount)
  local perf = r.TilemapPerf
  if perf and type(perf.count) == "function" then
    perf.count(label, amount)
  end
end

-- ! Warm Center
-- Compute visible chunk center once per layer config batch.
function TilemapHelpers.warmCenter(self, layerConfig)
  local size = layerConfig.size
  local visibleX, visibleY, visibleWidth, visibleHeight = TilemapHelpers.visibleLayerRect(self, layerConfig.layer)
  local minX, maxX, minY, maxY = TilemapHelpers.chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)
  return (minX + maxX) * 0.5, (minY + maxY) * 0.5
end

-- ! Warm Center From Cache
function TilemapHelpers.warmCenterFromCache(self, layerConfig, centerCache)
  if not centerCache then return TilemapHelpers.warmCenter(self, layerConfig) end

  local center = centerCache[layerConfig]
  if not center then
    local centerX, centerY = TilemapHelpers.warmCenter(self, layerConfig)
    center = { x = centerX, y = centerY }
    centerCache[layerConfig] = center
  end
  return center.x, center.y
end

-- ! Clear Chunk Draw Scratch
function TilemapHelpers.clearChunkDrawScratch(scratch, drawCount)
  if not scratch then return end
  local images = scratch.images or {}
  local xs = scratch.xs or {}
  local ys = scratch.ys or {}
  scratch.images = images
  scratch.xs = xs
  scratch.ys = ys
  local clearCount = max(drawCount or 0, scratch.count or 0)
  for index = 1, clearCount do
    images[index] = nil
    xs[index] = nil
    ys[index] = nil
  end
  scratch.count = 0
end

-- ! Warm Score
-- Warm queue prioritization helper (closest chunk to visible center)
function TilemapHelpers.warmScore(self, job, centerCache)
  local centerX, centerY = TilemapHelpers.warmCenterFromCache(self, job.layerConfig, centerCache)
  local dx = abs(job.chunkX - centerX)
  local dy = abs(job.chunkY - centerY)
  return dx + dy -- Manhattan distance is cheap and good enough
end

-- ! Dequeue Best Warm Job
function TilemapHelpers.dequeueBestWarmJob(self, centerCache)
  local queue = self._warmQueue
  local bestIndex, bestScore
  for i = 1, #queue do
    local score = TilemapHelpers.warmScore(self, queue[i], centerCache)
    if not bestScore or score < bestScore then
      bestScore, bestIndex = score, i
    end
  end
  if not bestIndex then return nil end

  local job = queue[bestIndex]
  queue[bestIndex] = queue[#queue]
  queue[#queue] = nil
  self._warmSet[job.key] = nil
  return job
end

-- ! Sync Native Tiles Full
function TilemapHelpers.syncNativeTilesFull(layerData)
  if not layerData or not layerData._nativeRenderer or not layerData.tilesFlat then
    return
  end
  local blob = TilemapHelpers.packTilesU16(layerData.tilesFlat)
  if blob then
    layerData._nativeRenderer:updateTilesBytes(blob)
    local selfRef = layerData.ownerTilemap
    if selfRef then selfRef._frameDirty = true end
  end
end
