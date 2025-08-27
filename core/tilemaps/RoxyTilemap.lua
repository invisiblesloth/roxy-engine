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

local min   <const> = math.min
local max   <const> = math.max
local floor <const> = math.floor
local ceil  <const> = math.ceil

local createTable <const> = table.create
local tableInsert <const> = table.insert
local tableSort   <const> = table.sort

local loadJSON <const> = r.JSON.loadJson

local getDrawOffset   <const> = Graphics.getDrawOffset
local setDrawOffset   <const> = Graphics.setDrawOffset
local newTilemap      <const> = Graphics.tilemap.new
local addWallSprites  <const> = Graphics.sprite.addWallSprites

local retain          <const> = AssetStore.retain
local release         <const> = AssetStore.release
local getImagetable   <const> = AssetStore.getImagetable

local setCameraBounds   <const> = Camera.setBounds

local ObjectLayerProcessor  <const> = r.ObjectLayerProcessor
local processObjectLayer    <const> = ObjectLayerProcessor.processObjectLayer
local processObjectLayers   <const> = ObjectLayerProcessor.processObjectLayers

local IMAGE_PATH_PREFIX <const> = "assets/images/"

local SPRITE_DEFAULT_DIMS <const> = 16

local COLOR_BLACK <const> = Graphics.kColorBlack

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local WALL_TAG   <const> = 1
local OBJECT_TAG <const> = 2

local EMPTY_TABLE <const> = {}

-- Shared reference counts for all RoxyTilemap instances.
-- Be sure to call _retain/_release in pairs so you don't
-- evict an asset another map still needs.
local referenceCount = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

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

--
-- Configuration & Validation Helpers
--

-- ! Helper: Validate Options
-- Ensures all required options have sensible defaults
local function _validateOptions(opts)
  -- Mutate the original options table instead of creating a new one
  opts = opts or {}

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

  -- Set defaults directly on options
  if opts.layers == nil then opts.layers = {} end
  if opts.wrapInSprites == nil then opts.wrapInSprites = true end
  if opts.zIndices == nil or type(opts.zIndices) ~= "table" then opts.zIndices = {} end
  if opts.cameraBounds == nil then opts.cameraBounds = false end
  if opts.deferCameraBounds == nil then opts.deferCameraBounds = false end
  if opts.anchor == nil or opts.anchor ~= "topLeft" then opts.anchor = "center" end
  if opts.collisionResponse == nil then opts.collisionResponse = "overlap" end
  if opts.wallCollidesWithGroups == nil then opts.wallCollidesWithGroups = {} end
  if opts.objectLayers == nil then opts.objectLayers = {} end

  -- Return the mutated options instead of a new table
  return opts
end

--
-- Parallax System Helpers
--

-- ! Helper: Create Parallax Update Function
-- Creates an update function for parallax sprites (hoisted to avoid per-sprite function creation)
local function _createParallaxUpdate(worldX, worldY, parallaxX, parallaxY, parallaxOriginX, parallaxOriginY, roundFn, cameraGetter)
  return function(self)
    local cameraX, cameraY = cameraGetter()

    -- Apply parallax origin pivot (consistent with projection classes)
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

--[[
  jsonPath: string - Path to Tiled JSON map
  opts:   table  - Configuration opts (see _validateOptions)
  scene:  table? - Optional scene object with addSprite method
]]
function RoxyTilemap:init(jsonPath, opts, scene)
  opts = _validateOptions(opts)
  self._opts = opts
  self.scene = scene
  self._retainedPaths = {}

  local autoAdd = opts.wrapInSprites and (opts.autoAddSprites ~= false)
  local sceneHasAdd = scene and type(scene) == "table" and type(scene.addSprite) == "function" or false

  --#DEBUG START
  if scene and not sceneHasAdd then
    Log.warn("[RoxyTilemap:init] RoxyTilemap: scene provided but has no addSprite method")
    -- Will fall back to sprite:add()
  end
  --#DEBUG END

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

  -- Helper: Find tileset for a given GID
  -- Use binary search over sorted gidRanges (firstgid ascending)
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

    if opts.deferCameraBounds == true then
      -- store for later, do NOT apply now (Loader scene)
      self._pendingCameraBounds = bounds
    else
      -- apply immediately
      setCameraBounds(bounds)
      self._pendingCameraBounds = nil
    end
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
    retain(normalizedPath, tileset.imageTable)

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
  self.layerManager = LayerManager(self._opts, scene, self.layers, newSprites)
  local processAllLayers = next(opts.layers) == nil -- Process all if none specified

  for _, layer in ipairs(mapData.layers or {}) do
    if layer.type == "tilelayer" and (processAllLayers or opts.layers[layer.name]) then
      local layerOptions = (opts.layerOptions and opts.layerOptions[layer.name]) or {}
      local data = layer.data or {}

      -- Find first nonzero GID and cache the tileset
      -- We break early for the first non-empty tile to avoid O(n) on dense layers
      -- For very sparse/empty layers the scan is still O(n); consider precomputing a
      -- layer->tileset mapping at export time in Tiled for true O(1)
      local usedTileset = nil
      for index = 1, #data do
        local rawGid = data[index]
        local gid = rawGid & 0x1FFFFFFF -- Remove flip flags
        if gid ~= 0 then
          usedTileset = _tilesetForGid(gid)
          break
        end
      end

      if not usedTileset then
        Log.warn("[RoxyTilemap:init] Layer '"..layer.name.."' has no matching tileset") --#DEBUG
        goto continueLayer -- Skip this layer if no valid tileset
      end

      -- Check if layer is non-empty
      local isEmpty = true
      for index = 1, #data do
        if data[index] ~= 0 then
          isEmpty = false
          break
        end
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
        local firstgid = usedTileset.firstgid
        local tilemap = newTilemap()
        tilemap:setSize(layer.width, layer.height)
        tilemap:setImageTable(usedTileset.imageTable)

        -- Convert GIDs to tilemap indices
        local indices = createTable(#data, 0)
        for index = 1, #data do
          local rawGid = data[index]
          local gid = rawGid & 0x1FFFFFFF -- Remove flip flags
          -- Use cached usedTileset instead of calling _tilesetForGid for each tile
          indices[index] = (gid ~= 0) and (gid - firstgid + 1) or 0
        end
        tilemap:setTiles(indices, layer.width)
        local tiles, stride = tilemap:getTiles()

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
          tilesFlat  = tiles,
          tilesStride = stride or layer.width,
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

        -- Add collision sprites if layer is collidable
        if layerOptions.collidable == true then
          local emptyIDs = layerOptions.emptyIDs or {}
          local wallGroup = layerOptions.wallSpriteGroup or opts.wallSpriteGroup
          local layerCollidesWithGroups = layerOptions.wallCollidesWithGroups or opts.wallCollidesWithGroups

          local collisionSprites = addWallSprites(tilemap, emptyIDs)
          for _, sprite in ipairs(collisionSprites) do
            -- Use const for tag instead of magic number
            sprite:setTag(WALL_TAG)
            sprite:setCollideRect(0, 0, sprite:getSize())

            if wallGroup then
              sprite:setGroups(type(wallGroup) == "table" and wallGroup or { wallGroup })
            end

            if layerCollidesWithGroups and type(layerCollidesWithGroups) == "table" and #layerCollidesWithGroups > 0 then
              sprite:setCollidesWithGroups(layerCollidesWithGroups)
            end

            -- Default collisionResponse from layerOptions or global, not hard-coded
            sprite.collisionResponse = layerOptions.collisionResponse or opts.collisionResponse
          end
          layerData.collisionSprites = collisionSprites
        end
      end
    end
    ::continueLayer::
  end
  -- Optionally defer sprite creation for layers
  -- Default behavior remains "create now" unless explicitly deferred
  if self._opts.wrapInSprites and (self._opts.deferLayerSprites ~= true) then
    self.layerManager:ensureSpritesForAll()
  end
  self.sprites = newSprites

  -- Optional deferral of object-layer processing
  local shouldDeferObjects = (opts.deferObjectProcessing == true)

  -- Process object layers now unless deferred
  local objectSprites = {}
  if not shouldDeferObjects then
    for _, layer in ipairs(mapData.layers or {}) do
      if layer.type == "objectgroup" and (processAllLayers or opts.objectLayers[layer.name]) then
        local layerOptions = (opts.layerOptions and opts.layerOptions[layer.name]) or EMPTY_TABLE
        local sprites = processObjectLayer(layer, opts, layerOptions, autoAdd, scene, sceneHasAdd, newSprites)
        objectSprites[layer.name] = sprites
      end
    end
  end
  self.objectSprites = objectSprites

  -- Keep raw object data for later on-demand processing
  self.objectLayers = {}
  for _, layer in ipairs(mapData.layers or {}) do
    if layer.type == "objectgroup" then
      -- Store name, objects, and Tiled per-layer parallax so deferred processing can inherit it
      self.objectLayers[layer.name] = {
        name      = layer.name,
        objects   = layer.objects or {},
        parallaxx = tonumber(layer.parallaxx),
        parallaxy = tonumber(layer.parallaxy),
      }
    end
  end

  -- Attach to a scene immediately if it supports tilemaps
  if scene and scene.addTilemap then
    scene:addTilemap(self)
  end
end

--------------------------------------------------------------------------------
--  Camera Controls
--------------------------------------------------------------------------------

-- ! Apply Camera Bounds
-- Apply the precomputed bounds now (e.g., when a scene enters)
function RoxyTilemap:applyCameraBounds()
  local pending = self._pendingCameraBounds
  if pending then
    setCameraBounds(pending)
    self._pendingCameraBounds = nil
    return true
  end
  return false
end

-- ! Update Camera Bounds
-- Recompute (in case the display size or map changed) and optionally apply or defer
function RoxyTilemap:updateCameraBounds(shouldApply)
  local bounds = {
    x1 = 0,
    y1 = 0,
    x2 = max(0, self.worldWidth  - DISPLAY_WIDTH),
    y2 = max(0, self.worldHeight - DISPLAY_HEIGHT),
  }
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
  return self.objectLayers and self.objectLayers[name]
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
  return self:findObjectSprites(layerName, function(object)
    return object.type == objectType
  end)
end

-- ! Find Object Sprites By Name
-- Returns all sprites from the layer whose Tiled objects have the specified name
function RoxyTilemap:findObjectSpritesByName(layerName, objectName)
  return self:findObjectSprites(layerName, function(object)
    return object.name == objectName
  end)
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
  for _, sprite in ipairs(sprites) do
    if sprite._retainedImagePath then
      release(sprite._retainedImagePath)
      sprite._retainedImagePath = nil
    end
    if self.scene and self.scene.removeSprite then
      self.scene:removeSprite(sprite)
    else
      sprite:remove()
    end
  end
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
  local tilemap = self:getTilemap(name)
  return tilemap and tilemap:getTileAtPosition(tileX, tileY) or nil
end

-- ! For Each Tile
-- Iterates over each tile on the specified layer, calling the provided function
-- Note: Coordinates passed to the function are in tile units.
function RoxyTilemap:forEachTile(name, fn)
  local tilemap = self:getTilemap(name)
  if not tilemap or type(fn) ~= "function" then return end

  local width, height = tilemap:getSize()
  for tileY = 1, height do
    for tileX = 1, width do
      fn(tileX, tileY, tilemap:getTileAtPosition(tileX, tileY))
    end
  end
end

--------------------------------------------------------------------------------
-- Layer Visibility & Management
--------------------------------------------------------------------------------

-- ! Hide Layer
-- Hides a tile layer from rendering (affects both sprites and direct drawing)
function RoxyTilemap:hideLayer(name)
  if self.layerManager then self.layerManager:hide(name) end
end

-- ! Show Layer
-- Shows a previously hidden tile layer
function RoxyTilemap:showLayer(name)
  if self.layerManager then self.layerManager:show(name) end
end


-- ! Remove Layer
-- Completely removes a tile layer and cleans up all associated resources
function RoxyTilemap:removeLayer(name)
  if self.layerManager then self.layerManager:remove(name) end
end

--------------------------------------------------------------------------------
-- Dynamic Layer Modification
--------------------------------------------------------------------------------

-- ! Set Layer ImageTable
-- Swap the imagetable used by a tile layer at runtime
-- newImageTableOrPath: a playdate.graphics.imagetable or a string path (Tiled/normalized)
-- remapFn: optional table or function to remap tile indices (oldIndex --> newIndex)
--   - If a table, remapFn[oldIndex] = newIndex
--   - If a function, newIndex = remapFn(oldIndex) (return nil to keep oldIndex)
function RoxyTilemap:setLayerImageTable(name, newImageTableOrPath, remapFn)
  return self.layerManager and self.layerManager:setImageTable(name, newImageTableOrPath, remapFn)
end

-- ! Rebuild Layer Collisions
-- Recreates wall sprites for a tile layer using the provided emptyIDs
-- Use when a tileset swap changes which tile indices should be passable vs solid
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

  -- Remove previous collision sprites
  if layerData.collisionSprites then
    for _, sprite in ipairs(layerData.collisionSprites) do
      sprite:remove()
    end
    layerData.collisionSprites = nil
  end

  -- Build new collision sprites from current tile indices
  local collisionSprites = addWallSprites(layerData.tilemap, resolvedEmptyIDs)

  -- Configure sprites with collision properties
  for _, sprite in ipairs(collisionSprites) do
    -- Use const for tag, apply resolved defaults
    sprite:setTag(WALL_TAG)
    sprite:setCollideRect(0, 0, sprite:getSize())

    if resolvedWallGroup then
      sprite:setGroups(type(resolvedWallGroup) == "table" and resolvedWallGroup or { resolvedWallGroup })
    end

    if resolvedCollidesWithGroups and type(resolvedCollidesWithGroups) == "table" and #resolvedCollidesWithGroups > 0 then
      sprite:setCollidesWithGroups(resolvedCollidesWithGroups)
    end

    sprite.collisionResponse = resolvedResponse
  end

  layerData.collisionSprites = collisionSprites
end

--------------------------------------------------------------------------------
-- Layer Origin Management
--------------------------------------------------------------------------------

-- ! Set Layer Origin
-- Updates the origin for a single layer and keeps any display sprite in sync
function RoxyTilemap:setLayerOrigin(name, x, y)
  return self.layerManager and self.layerManager:setOrigin(name, x, y)
end

-- ! Set Origin For All Layers
-- Convenience method to apply the same origin to every tile layer
function RoxyTilemap:setOriginForAllLayers(x, y)
  return self.layerManager and self.layerManager:setOriginForAll(x, y)
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

-- ! Detach Sprites
function RoxyTilemap:detachSprites()
  if self.layerManager then self.layerManager:detach() end
  for _, sprites in pairs(self.objectSprites or {}) do
    for _, sprite in ipairs(sprites) do
      if self.scene and self.scene.removeSprite then self.scene:removeSprite(sprite) else sprite:remove() end
    end
  end
  self.objectSprites = {}
end

-- ! Destroy
-- Cleans up all resources and removes sprites from display
function RoxyTilemap:destroy()
  -- Manager handles layer sprites, collisions, and swap-retained paths
  if self.layerManager then
    self.layerManager:destroy()
    self.layerManager = nil
  end

  -- Remove object sprites (unchanged from your current logic)
  for _, sprites in pairs(self.objectSprites or {}) do
    for _, sprite in ipairs(sprites) do
      if sprite._retainedImagePath then
        release(sprite._retainedImagePath)
        sprite._retainedImagePath = nil
      end
      if self.scene and self.scene.removeSprite then
        self.scene:removeSprite(sprite)
      else
        sprite:remove()
      end
    end
  end

  -- Clean up tilesets retained at initialization (unchanged)
  for _, tileset in pairs(self.tilesets or {}) do
    if tileset.imagePath then
      release(tileset.imagePath)
    end
  end

  -- Clear refs + detach from scene (unchanged)
  self.layers = {}
  self.sprites = {}
  self.objectSprites = {}
  self.tilesets = nil
  self.objectLayers = nil

  if self.scene then
    local scene = self.scene
    self.scene = nil
    if scene.removeTilemap then scene:removeTilemap(self) end
  end
end
