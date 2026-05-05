-- core/tilemaps/RoxyTilemap.lua

import "libraries/roxy/core/tilemaps/ObjectLayerProcessor"
import "libraries/roxy/core/tilemaps/TilemapHelpers"
import "libraries/roxy/core/tilemaps/LayerManager"

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics

local r           <const> = roxy
local AssetStore  <const> = r.AssetStore
local Camera      <const> = r.Camera
local Cache       <const> = r.Cache

local min   <const> = math.min
local max   <const> = math.max
local floor <const> = math.floor
local ceil  <const> = math.ceil

local createTable <const> = table.create
local tableInsert <const> = table.insert
local tableRemove <const> = table.remove
local tableSort   <const> = table.sort
local tableConcat <const> = table.concat

local loadJSON <const> = r.JSON.loadJson

local getDrawOffset   <const> = Graphics.getDrawOffset
local setDrawOffset   <const> = Graphics.setDrawOffset
local newTilemap      <const> = Graphics.tilemap.new
local addWallSprites  <const> = Graphics.sprite.addWallSprites

local retain        <const> = AssetStore.retain
local release       <const> = AssetStore.release
local getImagetable <const> = AssetStore.getImagetable
local evictAsset    <const> = Cache.evictAsset

local setCameraBounds   <const> = Camera.setBounds

-- Tile map specific aliases (core/tilemaps/ObjectLayerProcessor.lua)
local ObjectLayerProcessor  <const> = r.ObjectLayerProcessor
local processObjectLayer    <const> = ObjectLayerProcessor.processObjectLayer
local processObjectLayers   <const> = ObjectLayerProcessor.processObjectLayers

local IMAGE_PATH_PREFIX <const> = "assets/images/"

local TILED_GID_MASK        <const> = 0x0FFFFFFF
local TILED_TRANSFORM_MASK  <const> = 0xF0000000

local SPRITE_DEFAULT_DIMS <const> = 16

local WALL_TAG    <const> = 1
local OBJECT_TAG  <const> = 2

local RESERVED_IMAGE_OPTS <const> = {
  registerSprite  = true,
  applyImage      = true,
  onRefresh       = true,
  force           = true,
  cacheKey        = true,
  compositeLayers = true,
  layers          = true,
}

local EMPTY_TABLE <const> = {}

local COLOR_BLACK <const> = Graphics.kColorBlack

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

-- Shared reference counts for all RoxyTilemap instances.
-- Call _retain/_release in pairs so assets another map needs are not evicted.
local referenceCount = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Remove Sprites From Scene
-- Uses the scene batch unregister path when available; otherwise removes directly.
local function _removeSpritesFromScene(scene, sprites)
  if not sprites or #sprites == 0 then return end

  if scene and scene._unregisterSprites then
    scene:_unregisterSprites(sprites, true)
  elseif scene and scene.removeSprite then
    for i = 1, #sprites do
      scene:removeSprite(sprites[i])
    end
  else
    for i = 1, #sprites do
      sprites[i]:remove()
    end
  end
end

-- ! Helper: Add Sprites To Scene
-- Adds a batch through scene ownership so pooled re-add paths stay consistent.
local function _addSpritesToScene(scene, sprites)
  if not scene or not sprites or #sprites == 0 then return end

  for i = 1, #sprites do
    scene:addSprite(sprites[i])
  end
end

--
-- Asset Management Helpers
--

-- ! Helper: Normalize Image Path
-- Converts Tiled-exported image paths to Roxy's expected format
local function _normalizeImagePath(tiledImagePath)
  if type(tiledImagePath) ~= "string" then
    Log.warn("[_normalizeImagePath] Expected string, got " .. type(tiledImagePath)) --#DEBUG
    return nil
  end

  local filename = tiledImagePath:match("([^/]+)$") or ""
  local base = filename:gsub("%-table%-%d+%-%d+%.png$", "")

  if base == filename then
    Log.warn("[_normalizeImagePath] Unexpected image path pattern: " .. tostring(tiledImagePath)) --#DEBUG
    return IMAGE_PATH_PREFIX .. filename
  end

  return IMAGE_PATH_PREFIX .. base
end

-- ! Helper: Clean Tiled GID
-- Strips Tiled transform bits and returns the raw tile GID.
local function _cleanTiledGid(rawGid)
  return (rawGid or 0) & TILED_GID_MASK
end

-- ! Helper: Has Tiled Transform Flags
-- Returns true when a Tiled GID includes unsupported transform flags.
local function _hasTiledTransformFlags(rawGid)
  return rawGid ~= nil and ((rawGid & TILED_TRANSFORM_MASK) ~= 0)
end

-- ! Helper: Build Layer Tile Indices
-- Rejects unsupported Tiled data while converting GIDs in a single pass.
local function _buildLayerTileIndices(layer, tilesetForGid)
  local data = layer.data or EMPTY_TABLE
  local indices = createTable(#data, 0)
  local usedTileset = nil
  local firstgid = nil
  local lastgid = nil
  local isEmpty = true

  for index = 1, #data do
    local rawGid = data[index] or 0
    local tileIndex = 0

    if _hasTiledTransformFlags(rawGid) then
      error("[RoxyTilemap:init] Unsupported Tiled transform flags in layer '" .. tostring(layer.name) .. "' at tile " .. tostring(index), 2)
    end

    local gid = _cleanTiledGid(rawGid)
    if gid ~= 0 then
      isEmpty = false

      if not usedTileset then
        usedTileset = tilesetForGid(gid)
        if usedTileset then
          firstgid = usedTileset.firstgid
          lastgid = firstgid + (usedTileset.tilecount or 0) - 1
        end
      end

      if usedTileset then
        if gid < firstgid or gid > lastgid then
          error("[RoxyTilemap:init] Unsupported mixed tilesets in tile layer '" .. tostring(layer.name) .. "'", 2)
        end
        tileIndex = gid - firstgid + 1
      end
    end

    indices[index] = tileIndex
  end

  return usedTileset, indices, isEmpty
end

-- ! Helper: Remove Keys With Prefix
-- Evicts every cached asset whose key starts with the layer chunk prefix.
local function _evictCacheKeysWithPrefix(bucket, prefix)
  if not bucket or not bucket.cache or not prefix then return end

  local keys = {}
  local prefixLength = #prefix
  for key, _ in pairs(bucket.cache) do
    if tostring(key):sub(1, prefixLength) == prefix then
      keys[#keys + 1] = key
    end
  end

  for index = 1, #keys do
    evictAsset(bucket, keys[index])
  end
end

--
-- Configuration & Validation Helpers
--

local REMOVED_OPTIONS <const> = {
  layers = "use tileLayers for tile-layer load selection",
  deferCameraBounds = "constructors always store camera bounds for explicit activation",
  deferLayerSprites = "layer sprites are created during scene attachment",
  deferObjectProcessing = "object sprites are created during scene attachment",
}

-- ! Helper: Validate Options
-- Ensures all required options have sensible defaults
local function _validateOptions(opts)
  -- Mutate the original options table instead of creating a new one
  opts = opts or {}

  for optionName, message in pairs(REMOVED_OPTIONS) do
    if opts[optionName] ~= nil then
      error("[RoxyTilemap:_validateOptions] Unsupported option '" .. optionName .. "': " .. message, 3)
    end
  end

  -- Only create layerOptions table if it doesn't exist
  if not opts.layerOptions then
    opts.layerOptions = {}
  end

  local layerOptions = opts.layerOptions

  -- Validate per-layer emptyIDs
  for layerName, layerConfig in pairs(layerOptions) do
    if layerConfig.emptyIDs ~= nil then
      if type(layerConfig.emptyIDs) ~= "table" then
        Log.warn("[_validateOptions] layerOptions['" .. layerName .. "'].emptyIDs must be a table") --#DEBUG
        layerConfig.emptyIDs = {}
      else
        for index, identifier in ipairs(layerConfig.emptyIDs) do
          if type(identifier) ~= "number" then
            Log.warn("[_validateOptions] emptyIDs contains non-number at index " .. index .. " for layer '" .. layerName .. "'") --#DEBUG
            layerConfig.emptyIDs[index] = 0
          end
        end
      end
    end
  end

  -- Set defaults directly on options. Preserve nil versus empty selection tables:
  -- Nil means "load all"; an empty table means "load none".
  if opts.wrapInSprites == nil then opts.wrapInSprites = true end
  if opts.zIndices == nil or type(opts.zIndices) ~= "table" then opts.zIndices = {} end
  if opts.cameraBounds == nil then opts.cameraBounds = false end
  if opts.anchor == nil or opts.anchor ~= "topLeft" then opts.anchor = "center" end
  if opts.collisionResponse == nil then opts.collisionResponse = "overlap" end
  if opts.wallCollidesWithGroups == nil then opts.wallCollidesWithGroups = {} end

  -- Return the mutated options instead of a new table
  return opts
end

--
-- Layer Image Handle Helpers
--

-- ! Clone Table
-- Returns a shallow copy, or nil when the source is nil.
local function _cloneTable(source)
  if not source then return nil end
  local clone = {}
  for key, value in pairs(source) do
    clone[key] = value
  end
  return clone
end

-- ! Normalize Composite List
-- Builds a deduplicated composite layer list for layer image handles.
local function _normalizeCompositeList(primaryName, opts)
  if not opts then return nil end

  local list = opts.compositeLayers
  if type(list) ~= "table" then return nil end

  local deduped = {}
  local seen = {}
  for index = 1, #list do
    local name = list[index]
    if type(name) == "string" and name ~= primaryName and not seen[name] then
      seen[name] = true
      tableInsert(deduped, name)
    end
  end

  if #deduped == 0 then return nil end
  return deduped
end

-- ! Build Image Handle Key
-- Builds a stable cache key for a primary layer and optional composites.
local function _buildImageHandleKey(layerName, compositeLayers, opts)
  if opts and opts.cacheKey then
    return tostring(opts.cacheKey)
  end

  if not compositeLayers or #compositeLayers == 0 then
    return layerName
  end

  local sorted = {}
  for index = 1, #compositeLayers do
    sorted[index] = compositeLayers[index]
  end
  tableSort(sorted)

  return layerName .. "::" .. tableConcat(sorted, ",")
end

--
-- Parallax System Helpers
--

-- ! Helper: Create Parallax Update Function
-- Creates a parallax updater hoisted away from object creation hot paths
local function _createParallaxUpdate(worldX, worldY, parallaxX, parallaxY, parallaxOriginX, parallaxOriginY, roundFn, cameraGetter)
  return function(self)
    local cameraX, cameraY = cameraGetter()

    -- Apply parallax origin pivot consistent with projection classes
    local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
    local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

    local screenX = roundFn(worldX + pivotAdjustX - cameraX * parallaxX)
    local screenY = roundFn(worldY + pivotAdjustY - cameraY * parallaxY)

    local currentX, currentY = self:getPosition()
    if screenX ~= currentX or screenY ~= currentY then
      self:moveTo(screenX, screenY)
    end
  end
end

--------------------------------------------------------------------------------
-- ! Class Definition and Initialize
--------------------------------------------------------------------------------

class("RoxyTilemap").extends(Object)

-- ! Initialize
-- Parameter jsonPath: path to a Tiled JSON map
-- Parameter opts: configuration options; see _validateOptions
-- Parameter scene: unsupported; attach maps with scene:addTilemap(map)
function RoxyTilemap:init(jsonPath, opts, scene)
  --#DEBUG START
  if scene ~= nil then
    error("[RoxyTilemap:init] Expected RoxyTilemap(jsonPath, opts); attach with scene:addTilemap(map)", 2)
  end
  --#DEBUG END

  opts = _validateOptions(opts)
  self._opts = opts
  self.scene = nil
  self._retainedPaths = {}
  self._layerImageHandles = {}
  self._destroying = false
  self._destroyed = false

  -- Load the map JSON
  local mapData, err = loadJSON(jsonPath)
  if not mapData then
    Log.error("[RoxyTilemap:init] " .. (err or "unknown error")) --#DEBUG
    self.layers, self.sprites, self.tilesets, self.objectLayers, self.objectSprites = {}, {}, nil, nil, {}
    self.worldWidth, self.worldHeight = 0, 0
    return
  end

  -- Keep raw map/grid metadata for projection leaves
  self.mapWidth = mapData.width or 0
  self.mapHeight = mapData.height or 0
  self.mapTileWidth = mapData.tilewidth or 0
  self.mapTileHeight = mapData.tileheight or 0

  -- Store Tiled map orientation metadata for projection leaves
  self.mapOrientation = mapData.orientation -- "isometric" | "staggered" | "orthogonal" | ...
  self.staggerAxis = mapData.staggeraxis -- "x" | "y" | nil
  self.staggerIndex = mapData.staggerindex -- "odd" | "even" | nil

  -- Calculate world size (orthographic assumption)
  self.worldWidth = (mapData.width or 0) * (mapData.tilewidth or 0)
  self.worldHeight = (mapData.height or 0) * (mapData.tileheight or 0)

  -- Build GID ranges for tileset auto-detection
  local gidRanges = {}
  for _, tileset in ipairs(mapData.tilesets or {}) do
    gidRanges[#gidRanges + 1] = {
      first = tileset.firstgid,
      last = tileset.firstgid + (tileset.tilecount or 0) - 1,
      tileset = tileset
    }
  end
  tableSort(gidRanges, function(rangeA, rangeB) return rangeA.first < rangeB.first end)

  -- ! Helper: Tileset For GID
  -- Uses binary search over sorted gidRanges
  local function _tilesetForGid(gid)
    local lo, hi = 1, #gidRanges
    local candidate = nil
    while lo <= hi do
      local mid = floor((lo + hi) * 0.5)
      local range = gidRanges[mid]
      if gid < range.first then
        hi = mid - 1
      else
        candidate = range
        lo = mid + 1
      end
    end
    if candidate and gid <= candidate.last then
      return candidate.tileset
    end
    return nil
  end

  -- Apply (or defer) camera bounds
  if opts.cameraBounds then
    local bounds = {
      x1 = 0,
      y1 = 0,
      x2 = max(0, self.worldWidth  - DISPLAY_WIDTH),
      y2 = max(0, self.worldHeight - DISPLAY_HEIGHT),
    }
    self._cameraBounds = bounds
    self._pendingCameraBounds = bounds
  end

  -- Get map-level parallax origins
  local mapParallaxOriginX = tonumber(mapData.parallaxoriginx) or 0
  local mapParallaxOriginY = tonumber(mapData.parallaxoriginy) or 0

  -- Build tileset lookup (for loading imageTables)
  local tilesets = {}
  for _, tileset in ipairs(mapData.tilesets or {}) do
    local normalizedPath = _normalizeImagePath(tileset.image)
    if not normalizedPath then
      Log.warn("[RoxyTilemap:init] Skipping tileset '" .. tostring(tileset.name) .. "' due to invalid image path") --#DEBUG
      goto continueTileset
    end

    tileset.imagePath  = normalizedPath
    tileset.imageTable = getImagetable(normalizedPath)
    if tileset.imageTable then
      if not retain(normalizedPath, tileset.imageTable) then
        Log.warn("[RoxyTilemap:init] Failed to retain tileset image: " .. tostring(normalizedPath)) --#DEBUG
      end
    end

    -- Precompute once per tileset
    local maxImageHeight = 0
    local imageCount = tileset.imageTable and tileset.imageTable:getLength() or 0
    for index = 1, imageCount do
      local img = tileset.imageTable:getImage(index)
      if img then
        local _, height = img:getSize()
        if height and height > maxImageHeight then
          maxImageHeight = height
        end
      end
    end
    tileset.maxImageHeight = maxImageHeight
    tileset.imageCount = imageCount

    tilesets[tileset.name] = tileset
    ::continueTileset::
  end
  self.tilesets = tilesets

  -- Assert/early-out if no usable tilesets were loaded
  --#DEBUG START
  Log.assert(next(self.tilesets) ~= nil, "[RoxyTilemap:init] No tilesets were loaded; check map JSON and image paths")
  --#DEBUG END
  if not next(self.tilesets) then
    Log.error("[RoxyTilemap:init] No tilesets were loaded; aborting init") --#DEBUG
    self.layers, self.sprites, self.objectSprites = {}, {}, {}
    self.tilesets, self.objectLayers = nil, nil
    self.worldWidth, self.worldHeight = 0, 0
    return
  end

  -- Build layers
  self.layers = {}
  local newSprites = {}
  self.layerManager = LayerManager(self._opts, nil, self.layers, newSprites)
  local tileLayerSelection = opts.tileLayers
  local processAllTileLayers = tileLayerSelection == nil

  for layerIndex, layer in ipairs(mapData.layers or {}) do
    if layer.type == "tilelayer" and (processAllTileLayers or tileLayerSelection[layer.name]) then
      local layerOptions = (opts.layerOptions and opts.layerOptions[layer.name]) or {}

      -- Reject unsupported Tiled features before converting GIDs to tile indices
      local usedTileset, indices, isEmpty = _buildLayerTileIndices(layer, _tilesetForGid)

      if not usedTileset then
        Log.warn("[RoxyTilemap:init] Layer '"..layer.name.."' has no matching tileset") --#DEBUG
        goto continueLayer -- Skip this layer if no valid tileset
      end

      --#DEBUG START
      if isEmpty then
        Log.warn("[RoxyTilemap:init] Skipping empty layer '" .. layer.name .. "'")
      end
      if usedTileset and not usedTileset.imageTable then
        Log.warn("[RoxyTilemap:init] Skipping layer '" .. layer.name .. "' due to missing imagetable")
      end
      --#DEBUG END

      -- Only process layers with valid tilesets and non-empty data
      if usedTileset and not isEmpty and usedTileset.imageTable then
        local tilemap = newTilemap()
        tilemap:setSize(layer.width, layer.height)
        tilemap:setImageTable(usedTileset.imageTable)

        tilemap:setTiles(indices, layer.width)

        -- Use logical map tile size (e.g., 64x32) for iso math/culling
        -- Actual image size (e.g., 64x64) is handled via per-image offsets
        local tileWidth, tileHeight = self.mapTileWidth, self.mapTileHeight

        -- Precompute map pixel size
        local mapWidth, mapHeight = tilemap:getSize()
        local mapPixelWidth  = mapWidth  * tileWidth
        local mapPixelHeight = mapHeight * tileHeight

        -- Calculate maximum image height for this layer's tileset
        local imageTable = usedTileset.imageTable
        local imageCount = usedTileset.imageCount or 0
        local maxImageHeight = usedTileset.maxImageHeight or 0

        -- Create layer data structure
        local layerData = {
          name = layer.name,
          tiledOrder = layerIndex,
          tilemap = tilemap,
          tiledId = layer.id,
          anchor = opts.anchor,
          imagePath = usedTileset.imagePath,
          imageTable = imageTable,
          imageCount = imageCount,
          tileWidth = tileWidth,
          tileHeight = tileHeight,
          halfWidth = tileWidth * 0.5,
          halfHeight = tileHeight * 0.5,
          tilesFlat  = indices,
          tilesStride = layer.width,
          maxImageHeight = maxImageHeight,
          zIndex = (layerOptions.zIndex or opts.zIndices[layer.name] or 0),
          visible = (layerOptions.visible ~= false),
          mapWidth = mapWidth,
          mapHeight = mapHeight,
          mapPixelWidth = mapPixelWidth,
          mapPixelHeight = mapPixelHeight,
          layerOptions = layerOptions,
          _imageCache = {},
          _offsetCache = {},
        }

        -- Compute origin/parallax values
        local offsetX = tonumber(layer.offsetx) or 0
        local offsetY = tonumber(layer.offsety) or 0
        local originX, originY
        if opts.anchor == "topLeft" then
          originX, originY = offsetX, offsetY
        else
          originX = (mapPixelWidth  * 0.5) + offsetX
          originY = (mapPixelHeight * 0.5) + offsetY
        end
        layerData.originX = originX
        layerData.originY = originY

        local parallaxX = tonumber(layer.parallaxx) or 1
        local parallaxY = tonumber(layer.parallaxy) or 1
        local parallaxOriginX = opts.parallaxOriginX or mapParallaxOriginX
        local parallaxOriginY = opts.parallaxOriginY or mapParallaxOriginY
        layerData.parallaxx = parallaxX
        layerData.parallaxy = parallaxY
        layerData.parallaxoriginx = parallaxOriginX
        layerData.parallaxoriginy = parallaxOriginY

        self.layerManager:addLayer(layerData)

        -- Store collision config for lazy attach-time sprite creation
        if layerOptions.collidable == true then
          layerData.collisionConfig = {
            emptyIDs = layerOptions.emptyIDs or {},
            wallGroup = layerOptions.wallSpriteGroup or opts.wallSpriteGroup,
            collidesWithGroups = layerOptions.wallCollidesWithGroups or opts.wallCollidesWithGroups,
            collisionResponse = layerOptions.collisionResponse or opts.collisionResponse,
          }
          layerData._collisionDirty = true
        end
      end
    end
    ::continueLayer::
  end
  self.sprites = newSprites

  self.objectSprites = {}

  -- Keep raw object data for later on-demand processing
  self.objectLayers = {}
  for layerIndex, layer in ipairs(mapData.layers or {}) do
    if layer.type == "objectgroup" then
      -- Store name, objects, and Tiled per-layer parallax for deferred processing
      self.objectLayers[layer.name] = {
        name      = layer.name,
        tiledOrder = layerIndex,
        objects   = layer.objects or {},
        parallaxx = tonumber(layer.parallaxx),
        parallaxy = tonumber(layer.parallaxy),
      }
    end
  end
end

--------------------------------------------------------------------------------
-- Scene Attachment
--------------------------------------------------------------------------------

-- ! Configure Collision Sprites
-- Applies tag, group, and response options to wall sprites.
function RoxyTilemap:_configureCollisionSprites(sprites, config)
  if not sprites or not config then return end

  for _, sprite in ipairs(sprites) do
    sprite:setTag(WALL_TAG)
    sprite:setCollideRect(0, 0, sprite:getSize())

    local wallGroup = config.wallGroup
    if wallGroup then
      sprite:setGroups(type(wallGroup) == "table" and wallGroup or { wallGroup })
    end

    local collidesWithGroups = config.collidesWithGroups
    if collidesWithGroups and type(collidesWithGroups) == "table" and #collidesWithGroups > 0 then
      sprite:setCollidesWithGroups(collidesWithGroups)
    end

    sprite.collisionResponse = config.collisionResponse or "overlap"
  end
end

-- ! Rebuild Layer Collision Sprites
-- Recreates wall sprites for one layer from its current tile values.
function RoxyTilemap:_rebuildLayerCollisionSprites(layerData, config)
  if not layerData or not layerData.tilemap then return nil end
  config = config or layerData.collisionConfig
  if not config then return nil end

  if layerData.collisionSprites then
    _removeSpritesFromScene(self.scene, layerData.collisionSprites)
    layerData.collisionSprites = nil
  end

  local collisionSprites = addWallSprites(layerData.tilemap, config.emptyIDs or {})
  self:_configureCollisionSprites(collisionSprites, config)
  layerData.collisionSprites = collisionSprites
  layerData._collisionDirty = false
  layerData._collisionAttachPending = false
  return collisionSprites
end

-- ! Ensure Collision Sprites Attached
-- Builds or re-adds collision sprites once the scene can own display sprites.
function RoxyTilemap:_ensureCollisionSpritesAttached(scene)
  local sceneEntered = scene and scene._didEnter

  for _, layerData in pairs(self.layers or {}) do
    if layerData.collisionConfig then
      if not layerData.collisionSprites or layerData._collisionDirty then
        if not sceneEntered then
          layerData._collisionAttachPending = true
          goto continueCollisionLayer
        end
        self:_rebuildLayerCollisionSprites(layerData, layerData.collisionConfig)
      end
      _addSpritesToScene(scene, layerData.collisionSprites)
    end
    ::continueCollisionLayer::
  end
end

-- ! Ensure Object Sprites Attached
-- Processes pending object layers and re-adds preserved object sprites.
function RoxyTilemap:_ensureObjectSpritesAttached(scene)
  local opts = self._opts or {}
  local objectSelection = opts.objectLayers
  local objectSprites = self.objectSprites or {}

  for layerName, _ in pairs(self.objectLayers or {}) do
    local shouldProcess = objectSelection == nil or objectSelection[layerName]
    if shouldProcess and not objectSprites[layerName] then
      self:processObjectLayers({ [layerName] = true }, false, nil)
      objectSprites = self.objectSprites or objectSprites
    end
  end

  if opts.wrapInSprites == false or opts.autoAddSprites == false then
    return
  end

  for _, sprites in pairs(objectSprites) do
    _addSpritesToScene(scene, sprites)
  end
end

-- ! Attach To Scene
-- Attaches layer, object, and collision sprites to a scene.
function RoxyTilemap:attachToScene(scene)
  if self._destroyed then
    Log.warn("[RoxyTilemap:attachToScene] Cannot attach destroyed tilemap") --#DEBUG
    return false
  end

  if not scene or type(scene.addSprite) ~= "function" then
    Log.warn("[RoxyTilemap:attachToScene] Expected a scene with addSprite") --#DEBUG
    return false
  end

  if self.scene == scene then
    return true
  end

  if self.scene and self.scene ~= scene then
    Log.warn("[RoxyTilemap:attachToScene] Tilemap is already attached to another scene") --#DEBUG
    return false
  end

  self.scene = scene

  if self.layerManager then
    self.layerManager:setScene(scene)
    if self._opts.wrapInSprites then
      self.layerManager:ensureSpritesForAll()
    end
  end

  self:_ensureCollisionSpritesAttached(scene)
  self:_ensureObjectSpritesAttached(scene)

  return true
end

-- ! Scene Did Enter
-- Builds display-bound resources that were deferred during pre-enter attach.
function RoxyTilemap:sceneDidEnter(scene)
  if self.scene ~= scene then return false end
  self:_ensureCollisionSpritesAttached(scene)
  return true
end

-- ! Detach From Scene
-- Removes scene/display ownership while preserving reusable resources.
function RoxyTilemap:detachFromScene()
  local scene = self.scene

  if self.layerManager then
    self.layerManager:detach()
  end

  local collisionSprites = nil
  for _, layerData in pairs(self.layers or {}) do
    if layerData.collisionSprites then
      for _, sprite in ipairs(layerData.collisionSprites) do
        collisionSprites = collisionSprites or {}
        tableInsert(collisionSprites, sprite)
      end
    end
  end
  _removeSpritesFromScene(scene, collisionSprites)

  local objectSprites = nil
  for _, sprites in pairs(self.objectSprites or {}) do
    for _, sprite in ipairs(sprites) do
      objectSprites = objectSprites or {}
      tableInsert(objectSprites, sprite)
    end
  end
  _removeSpritesFromScene(scene, objectSprites)

  if scene and scene._unregisterTilemap then
    scene:_unregisterTilemap(self)
  else
    self.scene = nil
    if self.layerManager then
      self.layerManager:setScene(nil)
    end
  end

  return true
end

--------------------------------------------------------------------------------
--  Camera Controls
--------------------------------------------------------------------------------

-- ! Apply Camera Bounds
-- Apply the precomputed bounds now (e.g., when a scene enters)
function RoxyTilemap:applyCameraBounds()
  local bounds = self._cameraBounds or self._pendingCameraBounds
  if bounds then
    setCameraBounds(bounds)
    self._pendingCameraBounds = nil
    return true
  end
  return false
end

-- ! Get Camera Bounds
-- Returns a copy of stored camera bounds without applying them.
function RoxyTilemap:getCameraBounds()
  local bounds = self._cameraBounds or self._pendingCameraBounds
  if not bounds then return nil end
  return {
    x1 = bounds.x1,
    y1 = bounds.y1,
    x2 = bounds.x2,
    y2 = bounds.y2,
  }
end

-- ! Update Camera Bounds
-- Recompute bounds after a display or map-size change and optionally apply them.
function RoxyTilemap:updateCameraBounds(shouldApply)
  local bounds = {
    x1 = 0,
    y1 = 0,
    x2 = max(0, self.worldWidth  - DISPLAY_WIDTH),
    y2 = max(0, self.worldHeight - DISPLAY_HEIGHT),
  }
  self._cameraBounds = bounds
  if shouldApply then
    setCameraBounds(bounds)
    self._pendingCameraBounds = nil
  else
    self._pendingCameraBounds = bounds
  end
end

--------------------------------------------------------------------------------
--  Isometric Rendering Helpers
--------------------------------------------------------------------------------

-- ! Shared: Isometric Draw Offsets
-- Per-tile draw offsets so diamonds align with Tiled.
function RoxyTilemap._isoDrawOffsets(tileWidth, tileHeight, image)
  local imageWidth, imageHeight = image:getSize()
  local offsetX = (tileWidth - imageWidth) * 0.5
  local offsetY = (tileHeight - imageHeight)
  return offsetX, offsetY
end

-- ! Shared: Begin Manual Draw
-- Temporarily zero draw offset when doing manual placement.
function RoxyTilemap._beginManualDraw()
  local offsetX, offsetY = getDrawOffset()
  if offsetX ~= 0 or offsetY ~= 0 then
    setDrawOffset(0, 0)
  end
  return offsetX, offsetY
end

-- ! Shared: End Manual Draw
-- Restore draw offset after manual placement.
function RoxyTilemap._endManualDraw(offsetX, offsetY)
  if offsetX ~= 0 or offsetY ~= 0 then
    setDrawOffset(offsetX, offsetY)
  end
end

--------------------------------------------------------------------------------
-- Core Data Access Methods
--------------------------------------------------------------------------------

-- ! Get Tilemap
-- Returns the Playdate tilemap for the specified layer
function RoxyTilemap:getTilemap(name)
  return self.layerManager and self.layerManager:getTilemap(name)
end

-- ! Get Sprite
-- Returns the display sprite for the specified layer (if wrapInSprites was enabled)
function RoxyTilemap:getSprite(name)
  return self.layerManager and self.layerManager:getSprite(name)
end

-- ! Get World Size
-- Returns the pixel dimensions of the tilemap, based on the first tile layer
-- This is cached at init-time and available even if cameraBounds is false
function RoxyTilemap:getWorldSize()
  return self.worldWidth, self.worldHeight
end

--------------------------------------------------------------------------------
-- Object Layer Management
--------------------------------------------------------------------------------

-- ! Process Object Layers
-- Process object layers on-demand, after init
function RoxyTilemap:processObjectLayers(layersToProcess, autoAdd, scene)
  local opts = self._opts or {}
  local useAutoAdd = (autoAdd ~= nil) and autoAdd or (opts.wrapInSprites and (opts.autoAddSprites ~= false))
  scene = scene or self.scene
  local sceneHasAdd = scene and type(scene.addSprite) == "function" or false

  -- Build a minimal map-like table so ObjectLayerProcessor can iterate layers
  local mapLike = { layers = {} }
  for _, entry in pairs(self.objectLayers or {}) do
    local shouldProcess = not layersToProcess or layersToProcess[entry.name]
    if shouldProcess then
      tableInsert(mapLike.layers, {
        type      = "objectgroup",
        name      = entry.name,
        objects   = entry.objects,
        parallaxx = entry.parallaxx,
        parallaxy = entry.parallaxy,
      })
    end
  end

  local outSprites = self.sprites or {}

  -- Correct argument order: self first, then mapLike, then opts, etc.
  local processed = processObjectLayers(self, mapLike, opts, layersToProcess, useAutoAdd, scene, sceneHasAdd, outSprites)

  self.sprites = outSprites
  return processed
end

-- ! Get Objects
-- Returns the raw Tiled object data for the specified object layer
function RoxyTilemap:getObjects(name)
  local entry = self.objectLayers and self.objectLayers[name]
  return entry and entry.objects or nil
end

-- ! Get Object Sprites
-- Returns all sprites created from the specified object layer
function RoxyTilemap:getObjectSprites(layerName)
  return self.objectSprites and self.objectSprites[layerName] or {}
end

-- ! Get All Sprites
-- Returns all sprites managed by this tilemap (tile layers + objects)
function RoxyTilemap:getAllSprites()
  -- Layer sprites + object sprites
  local list = {}
  if self.layerManager then
    for _, sprite in ipairs(self.layerManager:getAllSprites()) do tableInsert(list, sprite) end
  end
  for _, objectSprite in pairs(self.objectSprites or {}) do
    for _, sprite in ipairs(objectSprite) do tableInsert(list, sprite) end
  end
  return list
end

--
-- Object Sprite Queries
--

-- ! Find Object Sprite
-- Finds the first sprite whose Tiled object matches the given predicate function
function RoxyTilemap:findObjectSprite(layerName, predicate)
  local sprites = self:getObjectSprites(layerName)
  for _, sprite in ipairs(sprites) do
    if sprite.tiledObject and predicate(sprite.tiledObject) then
      return sprite
    end
  end
  return nil
end

-- ! Find Object Sprites By Type
-- Returns all sprites from the layer whose Tiled objects have the specified type
function RoxyTilemap:findObjectSpritesByType(layerName, objectType)
  local sprites = self:getObjectSprites(layerName)
  local matches = {}

  for index = 1, #sprites do
    local sprite = sprites[index]
    local object = sprite.tiledObject
    if object and object.type == objectType then
      matches[#matches + 1] = sprite
    end
  end

  return matches
end

-- ! Find Object Sprites By Name
-- Returns all sprites from the layer whose Tiled objects have the specified name
function RoxyTilemap:findObjectSpritesByName(layerName, objectName)
  local sprites = self:getObjectSprites(layerName)
  local matches = {}

  for index = 1, #sprites do
    local sprite = sprites[index]
    local object = sprite.tiledObject
    if object and object.name == objectName then
      matches[#matches + 1] = sprite
    end
  end

  return matches
end

-- ! Find Object Sprites
-- Returns all sprites whose Tiled objects match the given predicate function
function RoxyTilemap:findObjectSprites(layerName, predicate)
  local sprites = self:getObjectSprites(layerName)
  local matches = {}
  for _, sprite in ipairs(sprites) do
    if sprite.tiledObject and predicate(sprite.tiledObject) then
      tableInsert(matches, sprite)
    end
  end
  return matches
end

-- ! Remove Object Layer
-- Removes all sprites from an object layer and cleans up references
function RoxyTilemap:removeObjectLayer(layerName)
  local sprites = self:getObjectSprites(layerName)

  -- Release retained images before unregistering sprites
  for _, sprite in ipairs(sprites) do
    if sprite._retainedImagePath then
      release(sprite._retainedImagePath)
      sprite._retainedImagePath = nil
    end
  end

  -- Remove from scene/display in one batch
  _removeSpritesFromScene(self.scene, sprites)

  if self.objectSprites then
    self.objectSprites[layerName] = nil
  end
end

--------------------------------------------------------------------------------
-- Tile Data Access & Manipulation
--------------------------------------------------------------------------------

-- ! Get Tile At
-- Returns the tile index at the given tile coordinates (x, y) on the specified layer
-- Note: Coordinates are in tile units, not pixels
function RoxyTilemap:getTileAt(name, tileX, tileY)
  local layerData = self.layers and self.layers[name]
  if not layerData then return nil end

  local tiles = layerData.tilesFlat
  local stride = layerData.tilesStride or layerData.mapWidth
  local mapWidth = layerData.mapWidth
  local mapHeight = layerData.mapHeight
  if tiles and stride and mapWidth and mapHeight then
    if tileX < 1 or tileY < 1 or tileX > mapWidth or tileY > mapHeight then return nil end
    local tileIndex = tiles[(tileY - 1) * stride + tileX]
    return tileIndex ~= 0 and tileIndex or nil
  end

  local tilemap = layerData.tilemap
  local tileIndex = tilemap and tilemap:getTileAtPosition(tileX, tileY) or nil
  return tileIndex ~= 0 and tileIndex or nil
end

-- ! For Each Tile
-- Iterates over each tile on the specified layer, calling the provided function
-- Note: Coordinates passed to the function are in tile units.
function RoxyTilemap:forEachTile(name, fn)
  local layerData = self.layers and self.layers[name]
  if not layerData or type(fn) ~= "function" then return end

  local tiles = layerData.tilesFlat
  local stride = layerData.tilesStride or layerData.mapWidth
  local width = layerData.mapWidth
  local height = layerData.mapHeight
  if tiles and stride and width and height then
    for tileY = 1, height do
      local rowOffset = (tileY - 1) * stride
      for tileX = 1, width do
        fn(tileX, tileY, tiles[rowOffset + tileX])
      end
    end
    return
  end

  local tilemap = layerData.tilemap
  if not tilemap then return end
  local width, height = tilemap:getSize()
  for tileY = 1, height do
    for tileX = 1, width do
      fn(tileX, tileY, tilemap:getTileAtPosition(tileX, tileY))
    end
  end
end

-- ! Sync Layer Tiles
-- Sanitizes cached tile indices and writes them back to the Playdate tilemap.
function RoxyTilemap:_syncLayerTilesFromTilemap(layerData)
  if not layerData or not layerData.tilemap then return end

  local tiles, stride = nil, nil
  if layerData.tilemap.getTiles then
    tiles, stride = layerData.tilemap:getTiles()
  end
  if not tiles then
    tiles = layerData.tilesFlat
    stride = layerData.tilesStride or layerData.mapWidth
  end
  if not tiles then return end

  local imageCount = layerData.imageCount or 0
  for index = 1, #tiles do
    local tileIndex = tiles[index]
    if tileIndex == nil or tileIndex == 0 then
      tiles[index] = 0
    else
      tiles[index] = (tileIndex >= 1 and tileIndex <= imageCount) and tileIndex or 0
    end
  end

  layerData.tilemap:setTiles(tiles, stride or layerData.mapWidth)
  layerData.tilesFlat = tiles
  layerData.tilesStride = stride or layerData.mapWidth
end

-- ! Clear Layer Chunk State
-- Evicts cached chunks and pending warm jobs for a layer.
function RoxyTilemap:_clearLayerChunkState(layerName, removeConfig)
  local staticLayers = self._staticChunkLayers
  local layerConfig = staticLayers and staticLayers[layerName] or nil
  if not layerConfig then return end

  local prefix = layerConfig.keyPrefix
  if prefix then
    _evictCacheKeysWithPrefix(self._globalChunkBucket, prefix)

    if self._warmQueue then
      local prefixLength = #prefix
      for index = #self._warmQueue, 1, -1 do
        local job = self._warmQueue[index]
        if job and job.key and tostring(job.key):sub(1, prefixLength) == prefix then
          tableRemove(self._warmQueue, index)
        end
      end
    end

    if self._warmSet then
      local prefixLength = #prefix
      for key, _ in pairs(self._warmSet) do
        if tostring(key):sub(1, prefixLength) == prefix then
          self._warmSet[key] = nil
        end
      end
    end
  end

  layerConfig._dirty = true
  layerConfig._lastRingBounds = nil

  if removeConfig and staticLayers then
    staticLayers[layerName] = nil
  end

  self._didPrimeVisible = false
  self._frameDirty = true
end

-- ! Rebuild Ordered Layers
-- Cold-path stable z-order cache used by projection draw loops.
function RoxyTilemap:_rebuildOrderedLayers()
  local items = {}
  local staticLayers = self._staticChunkLayers or EMPTY_TABLE

  for name, layerData in pairs(self.layers or EMPTY_TABLE) do
    if layerData.tilemap and layerData.visible ~= false then
      local renderType = staticLayers[name] and "chunked" or "dynamic"
      tableInsert(items, {
        layer = layerData,
        name = name,
        type = renderType,
        z = layerData.zIndex or 0,
        order = layerData.tiledOrder or 0,
      })
    end
  end

  tableSort(items, function(a, b)
    if a.z == b.z then return a.order < b.order end
    return a.z < b.z
  end)

  self._orderedLayers = items
end

-- ! Layer Structure Changed
-- Invalidates ordered layers and render state after hide/show/remove.
function RoxyTilemap:_onLayerStructureChanged(layerName, reason, layerData)
  self:markLayerImageDirty(layerName)
  self._frameDirty = true
  self._didPrimeVisible = false

  if reason == "remove" then
    self:_clearLayerChunkState(layerName, true)
  end

  if type(self._rebuildOrderedLayers) == "function" then
    self:_rebuildOrderedLayers()
  end
end

-- ! Layer Render Resources Changed
-- Refreshes cached/native render state after image table changes.
function RoxyTilemap:_onLayerRenderResourcesChanged(layerName)
  local layerData = self.layers and self.layers[layerName]
  if not layerData or not layerData.tilemap then return end

  self:_syncLayerTilesFromTilemap(layerData)

  layerData._imageCache = {}
  layerData._offsetCache = {}

  self:_clearLayerChunkState(layerName, false)
  self:markLayerImageDirty(layerName)
  self._frameDirty = true

  if type(self._refreshProjectionLayerRenderResources) == "function" then
    self:_refreshProjectionLayerRenderResources(layerName, layerData)
  end
end

-- ! Layer Tiles Changed
-- Marks derived state that depends on tile values.
function RoxyTilemap:_onLayerTilesChanged(layerName, layerData)
  layerData = layerData or (self.layers and self.layers[layerName])
  if not layerData then return end

  if layerData.collisionConfig then
    layerData._collisionDirty = true
  end

  self:markLayerImageDirty(layerName)
  self._frameDirty = true
end

--------------------------------------------------------------------------------
-- Layer Visibility & Management
--------------------------------------------------------------------------------

-- ! Hide Layer
-- Hides a tile layer from rendering (affects both sprites and direct drawing)
function RoxyTilemap:hideLayer(name)
  local layerData = self.layers and self.layers[name]
  if self.layerManager and self.layerManager:hide(name) then
    self:_onLayerStructureChanged(name, "hide", layerData)
    return true
  end
  return false
end

-- ! Show Layer
-- Shows a previously hidden tile layer
function RoxyTilemap:showLayer(name)
  local layerData = self.layers and self.layers[name]
  if self.layerManager and self.layerManager:show(name) then
    self:_onLayerStructureChanged(name, "show", layerData)
    return true
  end
  return false
end

-- ! Set Layer Visible
-- Convenience wrapper for showLayer and hideLayer.
function RoxyTilemap:setLayerVisible(name, visible)
  if visible ~= false then
    return self:showLayer(name)
  end
  return self:hideLayer(name)
end

-- ! Remove Layer
-- Completely removes a tile layer and cleans up all associated resources
function RoxyTilemap:removeLayer(name)
  local layerData = self.layers and self.layers[name]
  if self.layerManager and self.layerManager:remove(name) then
    self:_onLayerStructureChanged(name, "remove", layerData)
    return true
  end
  return false
end

--------------------------------------------------------------------------------
-- Dynamic Layer Modification
--------------------------------------------------------------------------------

-- ! Set Layer Image Table
-- Swap the image table used by a tile layer at runtime.
-- Parameter newImageTableOrPath: a Playdate image table object or a string path.
-- Parameter remapFn: optional table or function to remap tile indices (oldIndex --> newIndex).
--   - If a table, remapFn[oldIndex] = newIndex
--   - If a function, newIndex = remapFn(oldIndex) (return nil to keep oldIndex)
-- Does not rebuild collision sprites; call rebuildLayerCollisions if passability changes.
function RoxyTilemap:setLayerImageTable(name, newImageTableOrPath, remapFn)
  local updated = self.layerManager and self.layerManager:setImageTable(name, newImageTableOrPath, remapFn)
  if updated then
    self:_onLayerRenderResourcesChanged(name)
  end

  return updated
end

-- ! Rebuild Layer Collisions
-- Recreates wall sprites for a tile layer using the provided emptyIDs.
-- Use when a tileset swap changes which tile indices should be passable or solid.
function RoxyTilemap:rebuildLayerCollisions(name, emptyIDs, wallGroup, collidesWithGroups, collisionResponse)
  local layerData = self.layers and self.layers[name]
  if not layerData or not layerData.tilemap then return end

  -- Pull defaults from stored layer options or global options
  local layerOptions = (layerData and layerData.layerOptions) or EMPTY_TABLE
  local global = self._opts or EMPTY_TABLE

  local resolvedEmptyIDs = emptyIDs or layerOptions.emptyIDs or {}
  local resolvedWallGroup =
    (wallGroup ~= nil and wallGroup)
    or layerOptions.wallSpriteGroup
    or global.wallSpriteGroup

  local resolvedCollidesWithGroups =
    (collidesWithGroups ~= nil and collidesWithGroups)
    or layerOptions.wallCollidesWithGroups
    or global.wallCollidesWithGroups

  local resolvedResponse =
    (collisionResponse ~= nil and collisionResponse)
    or layerOptions.collisionResponse
    or global.collisionResponse
    or "overlap"

  layerData.collisionConfig = {
    emptyIDs = resolvedEmptyIDs,
    wallGroup = resolvedWallGroup,
    collidesWithGroups = resolvedCollidesWithGroups,
    collisionResponse = resolvedResponse,
  }

  if not (self.scene and self.scene._didEnter) then
    if layerData.collisionSprites then
      _removeSpritesFromScene(self.scene, layerData.collisionSprites)
      layerData.collisionSprites = nil
    end
    layerData._collisionDirty = true
    layerData._collisionAttachPending = true
    return nil
  end

  local collisionSprites = self:_rebuildLayerCollisionSprites(layerData, layerData.collisionConfig)
  _addSpritesToScene(self.scene, collisionSprites)
  return collisionSprites
end

--------------------------------------------------------------------------------
-- Layer Origin Management
--------------------------------------------------------------------------------

-- ! Set Layer Origin
-- Updates the origin for a single layer and keeps any display sprite in sync.
function RoxyTilemap:setLayerOrigin(name, x, y)
  local updated = self.layerManager and self.layerManager:setOrigin(name, x, y)
  if updated then
    self:markLayerImageDirty(name)
    self._frameDirty = true
  end
  return updated
end

-- ! Set Origin For All Layers
-- Convenience method to apply the same origin to every tile layer.
function RoxyTilemap:setOriginForAllLayers(x, y)
  if not self.layerManager then return false end
  self.layerManager:setOriginForAll(x, y)
  for name, _ in pairs(self.layers or {}) do
    self:markLayerImageDirty(name)
  end
  self._frameDirty = true
  return true
end

--------------------------------------------------------------------------------
-- Culling & Visibility Utilities
--------------------------------------------------------------------------------

-- ! Get Screen Bounds In World Space
-- Returns the world coordinates of screen corners for a given layer
function RoxyTilemap:getScreenBoundsInWorld(layer)
  if not layer then return 0, 0, 0, 0 end

  -- Get world coordinates of each screen corner
  local topLeftX, topLeftY = self:screenToWorld(0, 0, layer)
  local topRightX, topRightY = self:screenToWorld(DISPLAY_WIDTH, 0, layer)
  local bottomLeftX, bottomLeftY = self:screenToWorld(0, DISPLAY_HEIGHT, layer)
  local bottomRightX, bottomRightY = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)

  -- Find the bounding box
  local minX = min(topLeftX, topRightX, bottomLeftX, bottomRightX)
  local maxX = max(topLeftX, topRightX, bottomLeftX, bottomRightX)
  local minY = min(topLeftY, topRightY, bottomLeftY, bottomRightY)
  local maxY = max(topLeftY, topRightY, bottomLeftY, bottomRightY)

  return minX, minY, maxX, maxY
end

-- ! Get Visible Tile Bounds
-- Calculate which tiles are potentially visible with proper margin for tall sprites
function RoxyTilemap:getVisibleTileBounds(layer, extraMargin)
  if not layer then return 1, 1, 1, 1 end

  local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()

  -- Get world bounds of screen
  local minWorldX, minWorldY, maxWorldX, maxWorldY = self:getScreenBoundsInWorld(layer)

  -- Calculate margin based on image heights if not provided
  local margin = extraMargin or 0
  if not extraMargin and layer.imageTable then
    local tileHeight = layer.tileHeight or 0
    local halfHeight = tileHeight * 0.5

    -- Use the precomputed max image height
    local maxImageHeight = layer.maxImageHeight or 0
    local overdraw = max(0, maxImageHeight - tileHeight)
    margin = ceil(overdraw / max(1, halfHeight)) + 1
  end

  -- Apply margin and convert to tile coordinates
  minWorldX -= margin
  maxWorldX += margin
  minWorldY -= margin
  maxWorldY += margin

  local minTileX = max(1, floor(minWorldX) + 1)
  local maxTileX = min(mapWidthTiles, ceil(maxWorldX) + 1)
  local minTileY = max(1, floor(minWorldY) + 1)
  local maxTileY = min(mapHeightTiles, ceil(maxWorldY) + 1)

  return minTileX, minTileY, maxTileX, maxTileY
end

--------------------------------------------------------------------------------
-- Layer Image Handles
--------------------------------------------------------------------------------

-- ! Acquire Layer Image Handle
function RoxyTilemap:_acquireLayerImageHandle(layerName, opts, createIfMissing)
  if not layerName then return nil end

  if not self._layerImageHandles and createIfMissing then
    self._layerImageHandles = {}
  end

  local handles = self._layerImageHandles
  if not handles then return nil end

  local compositeLayers = _normalizeCompositeList(layerName, opts)
  local key = _buildImageHandleKey(layerName, compositeLayers, opts)
  if not key then return nil end

  local handle = handles[key]
  if not handle and createIfMissing then
    handle = {
      key = key,
      layerName = layerName,
      compositeLayers = compositeLayers,
      sprites = {},
      dirty = true,
      image = nil,
      offsetX = 0,
      offsetY = 0,
    }
    handles[key] = handle
  elseif handle and compositeLayers and not handle.compositeLayers then
    handle.compositeLayers = compositeLayers
  end

  return handle
end

-- ! Prune Layer Image Sprites
function RoxyTilemap:_pruneLayerImageSprites(handle)
  if not handle or not handle.sprites then return end

  for index = #handle.sprites, 1, -1 do
    local entry = handle.sprites[index]
    local sprite = entry and entry.sprite
    if sprite == nil then
      tableRemove(handle.sprites, index)
    end
  end
end

-- ! Apply Handle Image to Sprite
function RoxyTilemap:_applyHandleImageToSprite(handle, entry)
  if not handle or not entry then return end

  local sprite = entry.sprite
  if not sprite then return end

  local image = handle.image
  if not image then return end

  local offsetX = handle.offsetX or 0
  local offsetY = handle.offsetY or 0

  if entry.onRefresh then
    local ok, err = pcall(entry.onRefresh, sprite, image, offsetX, offsetY)
    if not ok then
      Log.warn("[RoxyTilemap:_applyHandleImageToSprite] onRefresh error: " .. tostring(err)) --#DEBUG
    end
  end

  if entry.applyImage ~= false and sprite.setImage then
    sprite:setImage(image)
  end
end

-- ! Apply Handle Image to Sprites
function RoxyTilemap:_applyHandleImageToSprites(handle)
  if not handle or not handle.sprites then return end
  if not handle.image then return end

  self:_pruneLayerImageSprites(handle)

  for index = 1, #handle.sprites do
    self:_applyHandleImageToSprite(handle, handle.sprites[index])
  end
end

-- ! Register Sprite for Image Handle
function RoxyTilemap:_registerSpriteForImageHandle(handle, sprite, applyImage, onRefresh)
  if not handle or not sprite then return nil end

  if not handle.sprites then handle.sprites = {} end

  for index = 1, #handle.sprites do
    local entry = handle.sprites[index]
    if entry and entry.sprite == sprite then
      entry.applyImage = (applyImage ~= false)
      entry.onRefresh = onRefresh
      return entry
    end
  end

  local entry = {
    sprite = sprite,
    applyImage = (applyImage ~= false),
    onRefresh = onRefresh,
  }

  tableInsert(handle.sprites, entry)
  return entry
end

-- ! Render Layer Image
function RoxyTilemap:_renderLayerImage(handle, opts)
  if not handle then return nil end

  if type(self._renderLayerToImage) ~= "function" then
    Log.error("[RoxyTilemap:_renderLayerImage] Projection is missing _renderLayerToImage implementation") --#DEBUG
    return nil
  end

  local renderOpts = nil
  if opts then
    for key, value in pairs(opts) do
      if not RESERVED_IMAGE_OPTS[key] then
        if not renderOpts then renderOpts = {} end
        renderOpts[key] = value
      end
    end
  end

  if handle.compositeLayers and #handle.compositeLayers > 0 then
    renderOpts = renderOpts or {}
    renderOpts.compositeLayers = handle.compositeLayers
  end

  local image, offsetX, offsetY = self:_renderLayerToImage(handle.layerName, renderOpts)
  if not image then return nil end

  return image, offsetX or 0, offsetY or 0
end

-- ! Mark Layer Image Dirty
function RoxyTilemap:markLayerImageDirty(layerName)
  if not self._layerImageHandles or not layerName then return end

  for _, handle in pairs(self._layerImageHandles) do
    if handle.layerName == layerName then
      handle.dirty = true
    elseif handle.compositeLayers then
      for index = 1, #handle.compositeLayers do
        if handle.compositeLayers[index] == layerName then
          handle.dirty = true
          break
        end
      end
    end
  end
end

-- ! Mark All Layer Images Dirty
function RoxyTilemap:markAllLayerImagesDirty()
  if not self._layerImageHandles then return end

  for _, handle in pairs(self._layerImageHandles) do
    handle.dirty = true
  end
end

-- ! Get Layer Image
function RoxyTilemap:getLayerImage(layerName, opts)
  if not layerName then
    Log.warn("[RoxyTilemap:getLayerImage] layerName is required") --#DEBUG
    return nil
  end

  if not (self.layers and self.layers[layerName]) then
    Log.warn("[RoxyTilemap:getLayerImage] Unknown layer '" .. tostring(layerName) .. "'") --#DEBUG
    return nil
  end

  local handle = self:_acquireLayerImageHandle(layerName, opts, true)
  if not handle then return nil end

  local shouldRender = handle.dirty or handle.image == nil or (opts and opts.force == true)

  if opts and opts.registerSprite then
    local entry = self:_registerSpriteForImageHandle(handle, opts.registerSprite, opts.applyImage, opts.onRefresh)
    if handle.image and entry then
      self:_applyHandleImageToSprite(handle, entry)
    end
  end

  if shouldRender then
    local image, offsetX, offsetY = self:_renderLayerImage(handle, opts)
    if not image then
      return nil
    end

    handle.image = image
    handle.offsetX = offsetX
    handle.offsetY = offsetY
    handle.dirty = false

    self:_applyHandleImageToSprites(handle)
  end

  return handle.image, handle.offsetX or 0, handle.offsetY or 0
end

-- ! Refresh Layer Image
function RoxyTilemap:refreshLayerImage(layerName, opts)
  local refreshOpts = opts and _cloneTable(opts) or {}
  refreshOpts.force = true

  return self:getLayerImage(layerName, refreshOpts)
end

--------------------------------------------------------------------------------
-- Coordinate Projection (Abstract Methods)
-- Methods that must be implemented by projection-specific subclasses
--------------------------------------------------------------------------------

-- ! Shared: Get Valid Layer
-- Returns a layer if it exists and is drawable
function RoxyTilemap:_getValidLayer(layerName)
  if not layerName or not self.layers then return nil end

  local layerData = self.layers[layerName]
  if not layerData or not layerData.tilemap or layerData.visible == false then
    return nil
  end

  return layerData
end

-- ! Get Map Size in Tiles
function RoxyTilemap:getMapSizeInTiles()
  return self.mapWidth, self.mapHeight
end

-- ! World to Screen
-- Converts world coordinates to screen coordinates for the given layer
function RoxyTilemap:worldToScreen(worldX, worldY, layer)
  Log.error("[RoxyTilemap:worldToScreen] Abstract method - must be implemented by projection subclass")
end

-- ! Screen to World
-- Converts screen coordinates to world coordinates for the given layer
function RoxyTilemap:screenToWorld(screenX, screenY, layer)
  Log.error("[RoxyTilemap:screenToWorld] Abstract method - must be implemented by projection subclass")
end

-- ! Set Tile At
-- Sets a tile at the given coordinates and optionally updates the display sprite
function RoxyTilemap:setTileAt(name, tileX, tileY, tileIndex, updateSprite)
  Log.error("[RoxyTilemap:setTileAt] Abstract method - must be implemented by projection subclass")
end

-- ! Render Layer to Image
function RoxyTilemap:_renderLayerToImage(layerName, opts)
  Log.error("[RoxyTilemap:_renderLayerToImage] Abstract method - must be implemented by projection subclass")
end


--------------------------------------------------------------------------------
-- Drawing (Abstract Methods)
-- Must be implemented by projection-specific subclasses
--------------------------------------------------------------------------------

-- ! Draw
-- Draws the specified layer (or all layers if no name provided)
function RoxyTilemap:draw(name)
  -- Subclasses should implement their own drawing logic
  Log.warn("[RoxyTilemap:draw] Abstract method. Implement in a projection leaf.") --#DEBUG
end

-- ! Draw Visible
-- Draws only the visible portions of layers for performance
function RoxyTilemap:drawVisible()
  -- Subclasses should implement their own drawing logic
  Log.warn("[RoxyTilemap:drawVisible] Abstract method. Implement in a projection leaf.") --#DEBUG
end

-- ! Draw Visible in Rectangle
-- Draws visible portions within a specific screen rectangle
function RoxyTilemap:drawVisibleInRect(screenX, screenY, width, height)
  -- Subclasses should implement their own drawing logic
  Log.warn("[RoxyTilemap:drawVisibleInRect] Abstract method. Implement in a projection leaf.") --#DEBUG
end

-- ! Draw Layer Rows
-- Dynamic row/column renderer with manual sprite positioning
function RoxyTilemap:drawLayerRows(layerName, minRow, maxRow, minColumn, maxColumn)
  -- Subclasses should implement their own drawing logic
  Log.warn("[RoxyTilemap:drawLayerRows] Abstract method. Implement in a projection leaf.") --#DEBUG
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- ! Destroy
-- Cleans up all resources and removes sprites from display
function RoxyTilemap:destroy()
  if self._destroyed or self._destroying then return end
  self._destroying = true

  local scene = self.scene

  -- Manager handles layer sprites, collisions, and swap-retained paths
  if self.layerManager then
    self.layerManager:destroy()
    self.layerManager = nil
  end

  -- Release cached layer images and sprite bindings
  if self._layerImageHandles then
    for _, handle in pairs(self._layerImageHandles) do
      if handle.sprites then
        for index = #handle.sprites, 1, -1 do
          local entry = handle.sprites[index]
          if entry then
            entry.sprite = nil
            entry.onRefresh = nil
          end
          handle.sprites[index] = nil
        end
      end

      handle.image = nil
      handle.dirty = true
      handle.compositeLayers = nil
    end
    self._layerImageHandles = nil
  end

  -- Release retained images, then unregister object sprites in one batch
  local objectSprites = nil
  for _, sprites in pairs(self.objectSprites or {}) do
    for _, sprite in ipairs(sprites) do
      if sprite._retainedImagePath then
        release(sprite._retainedImagePath)
        sprite._retainedImagePath = nil
      end
      objectSprites = objectSprites or {}
      tableInsert(objectSprites, sprite)
    end
  end
  _removeSpritesFromScene(scene, objectSprites)

  -- Clean up tilesets retained at initialization
  for _, tileset in pairs(self.tilesets or {}) do
    if tileset.imagePath then
      release(tileset.imagePath)
    end
  end

  -- Clear refs and detach from scene
  self.layers = {}
  self.sprites = {}
  self.objectSprites = {}
  self.tilesets = nil
  self.objectLayers = nil

  if scene and scene._unregisterTilemap then
    scene:_unregisterTilemap(self)
  end

  self.scene = nil
  self._destroyed = true
  self._destroying = false
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

local Graphics <const> = playdate.graphics

local scene = RoxyScene()

-- RoxyTilemap is usually instantiated through a projection subclass.
local map = RoxyOrthoTilemap("assets/maps/level-01.json", {
  cameraBounds = true,
  wrapInSprites = true,
  layerOptions = {
    Ground = {
      preRenderChunked = true,
      chunkSizePx = 320,
      overlapPx = 32,
    },
    Walls = {
      collidable = true,
      emptyIDs = { 0 },
      wallSpriteGroup = 1,
      wallCollidesWithGroups = { 2 },
    },
    Objects = {
      collidable = true,
      spriteGroup = 2,
    },
  },
})
scene:addTilemap(map)

scene:activateCamera({ tilemap = map })
local worldWidth, worldHeight = map:getWorldSize()

map:hideLayer("Decor")
map:showLayer("Decor")
map:setLayerOrigin("Ground", 0, 16)

local winterTiles = Graphics.imagetable.new("images/terrain-winter")
map:setLayerImageTable("Ground", winterTiles, {
  [1] = 2,
  [2] = 1,
})
map:rebuildLayerCollisions("Walls", { 0 })

map:processObjectLayers({ Objects = true })
local pickups = map:findObjectSpritesByType("Objects", "pickup")

scene:detachTilemap(map)
scene:addTilemap(map)
map:removeObjectLayer("Objects")
map:removeLayer("Decor")
map:destroy()

]]
