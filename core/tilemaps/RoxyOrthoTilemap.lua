-- core/tilemaps/RoxyOrthoTilemap.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
local Camera  <const> = r.Camera
local Cache   <const> = r.Cache

local min   <const> = math.min
local max   <const> = math.max
local floor <const> = math.floor
local round <const> = r.Math.round

local tableInsert <const> = table.insert
local tableSort   <const> = table.sort

local pushContext   <const> = Graphics.pushContext
local popContext    <const> = Graphics.popContext
local setClipRect   <const> = Graphics.setClipRect
local clearClipRect <const> = Graphics.clearClipRect
local newImage      <const> = Graphics.image.new
local clear         <const> = Graphics.clear

local addDirtyRect      <const> = Sprite.addDirtyRect
local getCameraPosition <const> = Camera.getPosition

local newCacheBucket  <const> = Cache.newBucket
local getOrLoadAsset  <const> = Cache.getOrLoadAsset
local evictAsset      <const> = Cache.evictAsset
local clearCache      <const> = Cache.clearCache

local TilemapHelpers          <const> = r.TilemapHelpers
local visibleLayerRect        <const> = TilemapHelpers.visibleLayerRect
local chunkIndicesForRect     <const> = TilemapHelpers.chunkIndicesForRect
local findFirstAvailableLayer <const> = TilemapHelpers.findFirstAvailableLayer

-- Default chunk settings
local DEFAULT_CHUNK_SIZE    <const> = 320
local DEFAULT_CHUNK_CACHE   <const> = 200
local DEFAULT_CHUNK_OVERLAP <const> = 32

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local COLOR_CLEAR <const> = Graphics.kColorClear

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Render Layer Region To Buffer
-- Render a rectangular region of the layer directly into the given buffer.
-- For orthographic, we can draw the exact source rect from the tilemap.
local function _drawLayerRegionToBuffer(layerData, destinationX, destinationY, sourceX, sourceY, width, height)
  -- Clamp source rect to layer bounds to avoid asking tilemap for out-of-range pixels.
  local mapPixelWidth, mapPixelHeight = layerData.mapPixelWidth or 0, layerData.mapPixelHeight or 0
  if sourceX >= mapPixelWidth or sourceY >= mapPixelHeight then return end

  if sourceX < 0 then
    local delta = -sourceX
    sourceX += delta; width -= delta; destinationX += delta
  end
  if sourceY < 0 then
    local delta = -sourceY
    sourceY += delta; height -= delta; destinationY += delta
  end

  width  = min(width,  mapPixelWidth  - sourceX)
  height = min(height, mapPixelHeight - sourceY)
  if width <= 0 or height <= 0 then return end

  layerData.tilemap:drawIgnoringOffset(destinationX, destinationY, sourceX, sourceY, width, height)
end

--------------------------------------------------------------------------------
-- ! Class Definition and Initialization
--------------------------------------------------------------------------------

class("RoxyOrthoTilemap").extends(RoxyTilemap)

function RoxyOrthoTilemap:init(jsonPath, opts, scene)
  opts = opts or {}
  RoxyOrthoTilemap.super.init(self, jsonPath, opts, scene)
  self._projection = "orthogonal"

  -- Static / chunk config and ordered layers
  self._staticChunkLayers = {}
  self._orderedLayers = {}

  -- Map-scoped cache key namespace
  self._mapCacheId = jsonPath or tostring(self)

  self:_initializeStaticLayers(opts)
  self:_rebuildOrderedLayers()
end

--------------------------------------------------------------------------------
-- Static Layer Configuration
--------------------------------------------------------------------------------

-- ! Utility: Initialize Static Layers
-- Build chunk/static configuration per layer
function RoxyOrthoTilemap:_initializeStaticLayers(opts)
  local layerOptions = (opts and opts.layerOptions) or {}
  local totalChunkCache = opts.totalChunkCache or DEFAULT_CHUNK_CACHE

  -- One shared bucket for all chunk images on this map
  self._globalChunkBucket = newCacheBucket(totalChunkCache)

  for layerName, layerData in pairs(self.layers) do
    local lopts = layerOptions[layerName] or {}
    if lopts.preRenderChunked then
      local size = max(1, lopts.chunkSizePx or DEFAULT_CHUNK_SIZE)
      local overlap = lopts.overlapPx or DEFAULT_CHUNK_OVERLAP
      local bufferSize = size + 2 * overlap
      self._staticChunkLayers[layerName] = {
        name         = layerName,
        layer        = layerData,
        size         = size,
        overlap      = overlap,
        bufferWidth  = bufferSize,
        bufferHeight = bufferSize,
        keyPrefix    = "chunk:" .. (self._mapCacheId or "map") .. ":" ..
                       tostring(layerData.tiledId or layerName) .. ":",
      }
    end
  end
end

-- ! Utility: Rebuild Ordered Layers
-- Build a stable, z-sorted draw list once (rarely changes)
function RoxyOrthoTilemap:_rebuildOrderedLayers()
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

--------------------------------------------------------------------------------
-- Chunk building & drawing
--------------------------------------------------------------------------------

-- ! Utility: Get or Build Chunk
-- Build or fetch a prerendered chunk image from the cache
function RoxyOrthoTilemap:_getOrBuildChunk(layerConfig, chunkX, chunkY)
  local key = layerConfig.keyPrefix .. chunkX .. ":" .. chunkY
  return getOrLoadAsset(self._globalChunkBucket, key, function()
    local size, overlap = layerConfig.size, layerConfig.overlap
    local width, height = layerConfig.bufferWidth, layerConfig.bufferHeight
    local img = newImage(width, height)

    -- Convert chunk indices to layer pixel origin for this chunk
    local pixelX = chunkX * size - overlap
    local pixelY = chunkY * size - overlap

    pushContext(img)
      setClipRect(0, 0, width, height)
      clear(COLOR_CLEAR)
      -- Draw the corresponding source rect from the tilemap into the buffer
      _drawLayerRegionToBuffer(layerConfig.layer, 0, 0, pixelX, pixelY, width, height)
      clearClipRect()
    popContext()

    return img
  end)
end

-- ! Utility: Draw Static Layer Chunked
-- Render a chunked layer using prebuilt chunk images
function RoxyOrthoTilemap:_drawStaticLayerChunked(layerName)
  local config = self._staticChunkLayers[layerName]
  if not config then return end

  local layerData = config.layer
  local size, overlap = config.size, config.overlap

  -- Visible rect in layer coordinates (inflate by overlap)
  local visibleX, visibleY, visibleWidth, visibleHeight = visibleLayerRect(self, layerData)
  visibleX -= overlap; visibleY -= overlap
  visibleWidth += 2 * overlap; visibleHeight += 2 * overlap

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    chunkIndicesForRect(visibleX, visibleY, visibleWidth, visibleHeight, size)

  -- Top-left screen position of layer pixel (0,0)
  local screenX, screenY = self:worldToScreen(0, 0, layerData)

  for chunkY = minChunkY, maxChunkY do
    local rowDestY = chunkY * size - overlap + screenY
    for chunkX = minChunkX, maxChunkX do
      local img = self:_getOrBuildChunk(config, chunkX, chunkY)
      if img then
        local destX = chunkX * size - overlap + screenX
        local destY = rowDestY

        local imageWidth, imageHeight = config.bufferWidth, config.bufferHeight
        if not (destX >= DISPLAY_WIDTH or destY >= DISPLAY_HEIGHT
             or destX + imageWidth <= 0 or destY + imageHeight <= 0) then
          img:draw(destX, destY)
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Projection methods
--------------------------------------------------------------------------------

-- ! World to Screen (orthogonal)
function RoxyOrthoTilemap:worldToScreen(worldX, worldY, layerData)
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local originX, originY = layerData.originX or 0, layerData.originY or 0
  local parallaxX, parallaxY = layerData.parallaxx or 1, layerData.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  -- Parallax-origin pivot to match sprite behavior (like other tilemap classes)
  local parallaxOriginX = layerData.parallaxoriginx or 0
  local parallaxOriginY = layerData.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local orthoX = originX + worldX * tileWidth
  local orthoY = originY + worldY * tileHeight

  return round(orthoX + pivotAdjustX - cameraX * parallaxX),
         round(orthoY + pivotAdjustY - cameraY * parallaxY)
end

-- ! Screen to World (orthogonal)
function RoxyOrthoTilemap:screenToWorld(screenX, screenY, layerData)
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
  local originX, originY = layerData.originX or 0, layerData.originY or 0
  local parallaxX, parallaxY = layerData.parallaxx or 1, layerData.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()

  local parallaxOriginX = layerData.parallaxoriginx or 0
  local parallaxOriginY = layerData.parallaxoriginy or 0
  local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
  local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

  local deltaX = (screenX + cameraX * parallaxX) - (originX + pivotAdjustX)
  local deltaY = (screenY + cameraY * parallaxY) - (originY + pivotAdjustY)

  local worldX = deltaX / tileWidth
  local worldY = deltaY / tileHeight
  return worldX, worldY
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Set Tile At
-- Sets the tile at the given tile coordinates (x, y) on the specified layer.
function RoxyOrthoTilemap:setTileAt(layerName, x, y, tileIndex, updateSprite)
  local layerData = self.layers and self.layers[layerName]
  if not layerData then return end

  layerData.tilemap:setTileAtPosition(x, y, tileIndex)

  -- Keep tilesFlat in sync so dynamic path sees edits immediately
  local tiles = layerData.tilesFlat
  if tiles then
    local stride = layerData.tilesStride or layerData.mapWidth
    if stride and stride > 0 then
      local tileOffset = (y - 1) * stride + x
      if tileOffset >= 1 and tileOffset <= #tiles then
        tiles[tileOffset] = tileIndex
      end
    end
  end

  -- If chunked, evict overlapping chunks so they rebuild lazily
  if self._staticChunkLayers[layerName] then
    self:markTilesDirty(layerName, x, y, 1, 1)
  end

  self:markLayerImageDirty(layerName)

  if updateSprite then
    local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight
    local screenX, screenY = self:worldToScreen(x - 1, y - 1, layerData)
    addDirtyRect(screenX, screenY, tileWidth, tileHeight)
  end
end

-- ! Render Layer to Image
function RoxyOrthoTilemap:_renderLayerToImage(layerName, opts)
  local primaryLayer = self:_getValidLayer(layerName)
  if not primaryLayer then return nil end

  local renderQueue = {}
  local order = 0

  local function enqueueLayer(name, layer)
    if not layer then return end

    for index = 1, #renderQueue do
      if renderQueue[index].layer == layer then
        return
      end
    end

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

  local defaultWidth = primaryLayer.mapPixelWidth or 0
  local defaultHeight = primaryLayer.mapPixelHeight or 0

  local tileWidth = primaryLayer.tileWidth or 0
  local tileHeight = primaryLayer.tileHeight or 0

  local sourceX = 0
  local sourceY = 0
  local pixelWidth = defaultWidth
  local pixelHeight = defaultHeight

  if opts then
    if opts.tileX or opts.tileY then
      local tileX = tonumber(opts.tileX)
      local tileY = tonumber(opts.tileY)

      if tileX then sourceX = (tileX - 1) * tileWidth end
      if tileY then sourceY = (tileY - 1) * tileHeight end
    end

    if opts.tileWidth or opts.tileHeight then
      local widthTiles = tonumber(opts.tileWidth)
      local heightTiles = tonumber(opts.tileHeight)

      if widthTiles then pixelWidth = widthTiles * tileWidth end
      if heightTiles then pixelHeight = heightTiles * tileHeight end
    end

    if opts.sourceX ~= nil then sourceX = tonumber(opts.sourceX) or sourceX end
    if opts.sourceY ~= nil then sourceY = tonumber(opts.sourceY) or sourceY end

    if opts.width ~= nil then pixelWidth = tonumber(opts.width) or pixelWidth end
    if opts.height ~= nil then pixelHeight = tonumber(opts.height) or pixelHeight end

    if opts.pixelWidth ~= nil then pixelWidth = tonumber(opts.pixelWidth) or pixelWidth end
    if opts.pixelHeight ~= nil then pixelHeight = tonumber(opts.pixelHeight) or pixelHeight end
  end

  sourceX = floor(sourceX or 0)
  sourceY = floor(sourceY or 0)
  pixelWidth = max(0, floor(pixelWidth or 0))
  pixelHeight = max(0, floor(pixelHeight or 0))

  if pixelWidth <= 0 or pixelHeight <= 0 then return nil end

  if sourceX < 0 then sourceX = 0 end
  if sourceY < 0 then sourceY = 0 end

  local image = newImage(pixelWidth, pixelHeight)
  if not image then return nil end

  pushContext(image)
    clear(COLOR_CLEAR)
    for index = 1, #renderQueue do
      local entry = renderQueue[index]
      _drawLayerRegionToBuffer(entry.layer, 0, 0, sourceX, sourceY, pixelWidth, pixelHeight)
    end
  popContext()

  local originX = primaryLayer.originX or 0
  local originY = primaryLayer.originY or 0
  local anchor = (primaryLayer.anchor or (self._opts and self._opts.anchor)) or "center"

  local offsetX, offsetY
  if anchor == "topLeft" then
    offsetX = originX - sourceX
    offsetY = originY - sourceY
  else
    offsetX = originX - (sourceX + pixelWidth * 0.5)
    offsetY = originY - (sourceY + pixelHeight * 0.5)
  end

  return image, offsetX, offsetY
end

-- ! Get Row From Screen
function RoxyOrthoTilemap:getRowFromScreen(screenX, screenY, layerName)
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
function RoxyOrthoTilemap:resortLayers()
  self:_rebuildOrderedLayers()
end

-- ! Mark Tiles Dirty
-- Evict any chunks overlapped by the edited tile region
function RoxyOrthoTilemap:markTilesDirty(layerName, tileX, tileY, tileCountWidth, tileCountHeight)
  self:markLayerImageDirty(layerName)

  local config = self._staticChunkLayers[layerName]
  if not config then return end

  local tileWidth, tileHeight = config.layer.tileWidth, config.layer.tileHeight
  local pixelX = (tileX - 1) * tileWidth
  local pixelY = (tileY - 1) * tileHeight
  local pixelWidth = (tileCountWidth  or 1) * tileWidth
  local pixelHeight = (tileCountHeight or 1) * tileHeight

  local minChunkX, maxChunkX, minChunkY, maxChunkY =
    chunkIndicesForRect(pixelX, pixelY, pixelWidth, pixelHeight, config.size)

  for chunkY = minChunkY, maxChunkY do
    for chunkX = minChunkX, maxChunkX do
      evictAsset(self._globalChunkBucket, config.keyPrefix .. chunkX .. ":" .. chunkY)
    end
  end
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- ! Draw
-- Draw a single tile layer directly (no sprite required)
function RoxyOrthoTilemap:draw(layerName)
  local layerData = self.layers and self.layers[layerName]
  if not layerData or not layerData.tilemap or layerData.visible == false then return end

  if self._staticChunkLayers[layerName] then
    self:_drawStaticLayerChunked(layerName); return
  end

  -- Use base helper so tall tiles near edges are included
  local minTileX, minTileY, maxTileX, maxTileY = self:getVisibleTileBounds(layerData)
  self:_drawLayerRegionData(layerData, minTileX, maxTileX, minTileY, maxTileY)
end

-- ! Draw Visible
-- Draw all visible tile layers by zIndex (ascending)
function RoxyOrthoTilemap:drawVisible()
  local ordered = self._orderedLayers
  for i = 1, #ordered do
    local item = ordered[i]
    if item.type == "chunked" then
      self:_drawStaticLayerChunked(item.name)
    else
      local layerData = item.layer
      if layerData.tilemap and layerData.visible ~= false then
        local minTileX, minTileY, maxTileX, maxTileY = self:getVisibleTileBounds(layerData)
        self:_drawLayerRegionData(layerData, minTileX, maxTileX, minTileY, maxTileY)
      end
    end
  end
end

-- ! Draw Visible In Rectangle
function RoxyOrthoTilemap:drawVisibleInRect(x, y, width, height)
  setClipRect(x, y, width, height)
    self:drawVisible()
  clearClipRect()
end

-- ! Draw Layer Region Data
-- Internal region renderer for callers that already have layerData.
function RoxyOrthoTilemap:_drawLayerRegionData(layerData, minTileX, maxTileX, minTileY, maxTileY)
  if not layerData or not layerData.tilemap or layerData.visible == false then return end

  local mapWidthTiles, mapHeightTiles = layerData.mapWidth, layerData.mapHeight
  if not mapWidthTiles or not mapHeightTiles then
    mapWidthTiles, mapHeightTiles = layerData.tilemap:getSize()
  end
  local tileWidth, tileHeight = layerData.tileWidth, layerData.tileHeight

  -- Clamp bounds
  minTileX = max(1, minTileX)
  maxTileX = min(mapWidthTiles, maxTileX)
  minTileY = max(1, minTileY)
  maxTileY = min(mapHeightTiles, maxTileY)
  if minTileX > maxTileX or minTileY > maxTileY then return end

  -- Convert tiles to pixels
  local sourceX = (minTileX - 1) * tileWidth
  local sourceY = (minTileY - 1) * tileHeight
  local regionWidth = (maxTileX - minTileX + 1) * tileWidth
  local regionHeight = (maxTileY - minTileY + 1) * tileHeight

  -- Screen position for top-left of region
  local screenX, screenY = self:worldToScreen(minTileX - 1, minTileY - 1, layerData)

  -- Clip against the display to avoid overdraw
  local clippedScreenX = max(0, screenX)
  local clippedScreenY = max(0, screenY)
  local sourceOffsetX = clippedScreenX - screenX
  local sourceOffsetY = clippedScreenY - screenY

  local visibleWidth = min(regionWidth - sourceOffsetX, DISPLAY_WIDTH - clippedScreenX)
  local visibleHeight = min(regionHeight - sourceOffsetY, DISPLAY_HEIGHT - clippedScreenY)
  if visibleWidth <= 0 or visibleHeight <= 0 then return end

  layerData.tilemap:drawIgnoringOffset(
    clippedScreenX, clippedScreenY,
    sourceX + sourceOffsetX, sourceY + sourceOffsetY,
    visibleWidth, visibleHeight
  )
end

-- ! Draw Layer Region
-- Region-based renderer that batches via tilemap:drawIgnoringOffset.
function RoxyOrthoTilemap:drawLayerRegion(layerName, minTileX, maxTileX, minTileY, maxTileY)
  local layerData = self.layers and self.layers[layerName]
  self:_drawLayerRegionData(layerData, minTileX, maxTileX, minTileY, maxTileY)
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- ! Destroy
-- Clean up static layer resources and defer remainder to base class.
function RoxyOrthoTilemap:destroy()
  if self._destroyed or self._destroying then return end

  -- Clear pre-rendered chunk cache for this map
  if self._globalChunkBucket then
    clearCache(self._globalChunkBucket)
    self._globalChunkBucket = nil
  end
  self._staticChunkLayers = {}
  self._orderedLayers = {}

  RoxyOrthoTilemap.super.destroy(self)
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

local scene = RoxyScene()

local map = RoxyOrthoTilemap("assets/maps/level-01.json", {
  cameraBounds = true,
  deferCameraBounds = true,
  wrapInSprites = false,
  layerOptions = {
    Ground = {
      preRenderChunked = true,
      chunkSizePx = 320,
      overlapPx = 32,
    },
    Props = {
      zIndex = 10,
    },
  },
}, scene)

function scene:start()
  map:applyCameraBounds()
end

function scene:draw()
  map:drawVisible()
end

map:setTileAt("Ground", 12, 8, 4, true)
map:markTilesDirty("Ground", 10, 8, 3, 2)

local row = map:getRowFromScreen(200, 120, "Ground")

local previewImage, offsetX, offsetY = map:getLayerImage("Ground", {
  tileX = 1,
  tileY = 1,
  tileWidth = 10,
  tileHeight = 8,
})

map:drawVisibleInRect(0, 0, 400, 120)
map:drawLayerRegion("Ground", 1, 20, 1, 15)

map:destroy()

]]
