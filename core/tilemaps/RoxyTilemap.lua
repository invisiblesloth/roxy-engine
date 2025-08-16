-- core/tilemaps/RoxyTilemap.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
local Cache   <const> = r.Cache
local Camera  <const> = r.Camera

local min   <const> = math.min
local max   <const> = math.max
local floor <const> = math.floor
local ceil  <const> = math.ceil
local round <const> = r.Math.round

local createTable <const> = table.create
local tableInsert <const> = table.insert
local tableRemove <const> = table.remove
local tableSort   <const> = table.sort

local loadJSON <const> = r.JSON.loadJson

local pushContext     <const> = Graphics.pushContext
local popContext      <const> = Graphics.popContext
local setColor        <const> = Graphics.setColor
local newImage        <const> = Graphics.image.new
local newImagetable   <const> = Graphics.imagetable.new
local newTilemap      <const> = Graphics.tilemap.new
local fillRect        <const> = Graphics.fillRect
local addWallSprites  <const> = Graphics.sprite.addWallSprites
local newSprite       <const> = Graphics.sprite.new

local addDirtyRect <const> = Sprite.addDirtyRect

local getCachedAsset    <const> = Cache.getCachedAsset
local cacheAsset        <const> = Cache.cacheAsset
local evictAsset        <const> = Cache.evictAsset
local getIsAssetCached  <const> = Cache.getIsAssetCached

local setCameraBounds   <const> = Camera.setBounds
local getCameraPosition <const> = Camera.getPosition

local IMAGE_PATH_PREFIX <const> = "assets/images/"

local SPRITE_DEFAULT_DIMS <const> = 16

local COLOR_BLACK <const> = Graphics.kColorBlack

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local EMPTY_TABLE <const> = {}

-- Shared reference counts for all RoxyTilemap instances.
-- Be sure to call retain/release in pairs so you don't
-- evict an asset another map still needs.
local refCount = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Retain
local function retain(path, tbl)
  refCount[path] = (refCount[path] or 0) + 1
  if not getIsAssetCached(path) then
    cacheAsset(path, function() return tbl end)
  end
end

-- ! Release
local function release(path)
  local n = refCount[path]
  if not n then return end
  if n <= 1 then
    evictAsset(path)
    refCount[path] = nil
  else
    refCount[path] = n - 1
  end
end

-- ! Normalize Image Path
local function normalizeImgPath(tiledImgPath)
  if type(tiledImgPath) ~= "string" then
    Log.warn("[normalizeImgPath] Expected string, got " .. type(tiledImgPath)) --#DEBUG
    return nil
  end
  local filename = tiledImgPath:match("([^/]+)$") or ""
  local base = filename:gsub("%-table%-%d+%-%d+%.png$", "")
  if base == filename then
    Log.warn("[normalizeImgPath] Unexpected image path pattern: " .. tostring(tiledImgPath)) --#DEBUG
    return IMAGE_PATH_PREFIX .. filename
  end
  return IMAGE_PATH_PREFIX .. base
end

-- ! Get Imagetable
local function getImagetable(path)
  if type(path) ~= "string" or path == "" then
    Log.warn("[getImagetable] Invalid or missing path: " .. tostring(path))
    return nil
  end
  local cached = getCachedAsset(path)
  if cached then
    -- If cached is a thunk, call it
    local tbl = (type(cached) == "function") and cached() or cached
    return tbl
  end

  local loaded = newImagetable(path)
  if loaded then
    cacheAsset(path, function() return loaded end)
  else --#DEBUG
    Log.warn("[getImagetable] Failed to load imagetable at path: " .. path) --#DEBUG
  end

  return loaded
end

-- ! Validate Options
local function validateOptions(opts)
  -- Mutate the original opts table instead of creating a new one
  opts = opts or {}

  -- Only create layerOptions table if it doesn't exist
  if not opts.layerOptions then
    opts.layerOptions = EMPTY_TABLE
  end
  local layerOptions = opts.layerOptions

  -- Validate per-layer emptyIDs
  for layerName, layerOpts in pairs(layerOptions) do
    if layerOpts.emptyIDs ~= nil then
      if type(layerOpts.emptyIDs) ~= "table" then
        Log.warn("[validateOptions] layerOptions['" .. layerName .. "'].emptyIDs must be a table") --#DEBUG
        layerOpts.emptyIDs = EMPTY_TABLE
      else
        for i, id in ipairs(layerOpts.emptyIDs) do
          if type(id) ~= "number" then
            Log.warn("[validateOptions] emptyIDs contains non-number at index " .. i .. " for layer '" .. layerName .. "'") --#DEBUG
            layerOpts.emptyIDs[i] = 0
          end
        end
      end
    end
  end

  -- Set defaults directly on opts
  if opts.layers == nil then opts.layers = EMPTY_TABLE end
  if opts.wrapInSprites == nil then opts.wrapInSprites = true end
  if opts.zIndices == nil or type(opts.zIndices) ~= "table" then opts.zIndices = EMPTY_TABLE end
  if opts.cameraBounds == nil then opts.cameraBounds = false end
  if opts.anchor == nil or opts.anchor ~= "topLeft" then opts.anchor = "center" end
  if opts.collisionResponse == nil then opts.collisionResponse = "overlap" end
  if opts.wallCollidesWithGroups == nil then opts.wallCollidesWithGroups = EMPTY_TABLE end
  if opts.objectLayers == nil then opts.objectLayers = EMPTY_TABLE end

  -- Return the mutated opts instead of a new table
  return opts
end

-- ! Create default Object Sprite
local function createDefaultObjectSprite(obj, layerOpts)
  -- Check if object has parallax properties
  local hasParallax = false
  local parallaxX, parallaxY = 1, 1
  local parallaxOriginX, parallaxOriginY = 0, 0
  local objectProps = {}

  -- Parse object properties
  if obj.properties then
    for _, prop in ipairs(obj.properties) do
      objectProps[prop.name] = prop.value

      -- Check for parallax properties
      if prop.name == "parallaxX" or prop.name == "parallaxx" then
        parallaxX = tonumber(prop.value) or 1
        hasParallax = hasParallax or (parallaxX ~= 1)
      elseif prop.name == "parallaxY" or prop.name == "parallaxy" then
        parallaxY = tonumber(prop.value) or 1
        hasParallax = hasParallax or (parallaxY ~= 1)
      elseif prop.name == "parallaxOriginX" or prop.name == "parallaxoriginx" then
        parallaxOriginX = tonumber(prop.value) or 0
      elseif prop.name == "parallaxOriginY" or prop.name == "parallaxoriginy" then
        parallaxOriginY = tonumber(prop.value) or 0
      end
    end
  end

  -- Try to load image based on object properties
  local imagePath = nil

  -- Check for image in object properties (common Tiled pattern)
  if objectProps.image or objectProps.sprite then
    imagePath = IMAGE_PATH_PREFIX .. (objectProps.image or objectProps.sprite)
  end

  -- Fallback to type-based or name-based image loading
  if not imagePath then
    local baseName = obj.type or obj.name or "default"
    imagePath = IMAGE_PATH_PREFIX .. baseName
  end

  -- Try to load the image
  local image = nil
  local ok, err = pcall(function()
    image = newImage(imagePath)
  end)
  if not ok or not image then
    Log.warn("[createDefaultObjectSprite] Failed to load image at: " .. tostring(imagePath))
  end

  -- Create parallax sprite if needed
  local sprite
  if hasParallax then
    local spriteOpts = {
      view = image,
      worldX = obj.x or 0,
      worldY = obj.y or 0,
      parallaxX = parallaxX,
      parallaxY = parallaxY,
      parallaxOriginX = parallaxOriginX,
      parallaxOriginY = parallaxOriginY
    }
    sprite = r.RoxyParallaxSprite(spriteOpts)
  else
    sprite = newSprite()
    if image then sprite:setImage(image) end
  end

  -- Fallback image creation for regular sprites
  if not image and not hasParallax then
    -- Create a simple rectangle sprite as fallback
    local width = obj.width or SPRITE_DEFAULT_DIMS
    local height = obj.height or SPRITE_DEFAULT_DIMS
    local fallbackImage = newImage(width, height)
    pushContext(fallbackImage)
      setColor(COLOR_BLACK)
      fillRect(0, 0, width, height)
    popContext()
    sprite:setImage(fallbackImage)
  end

  -- Store all object properties on the sprite for reference
  sprite.objectProps = objectProps

  return sprite
end

-- ! Process Object Layer
local function processObjectLayer(self, layer, opts, layerOpts, autoAdd, scene, sceneHasAdd, newSprites)
  local objects = layer.objects or {}

  -- Preallocate Object-Layer Tables
  local layerSprites = createTable(#objects, 0)

  for _, obj in ipairs(objects) do
    local sprite = nil

    -- Use custom sprite factory if provided
    if opts.spriteFactory and type(opts.spriteFactory) == "function" then
      sprite = opts.spriteFactory(obj, layer.name, layerOpts)
    elseif layerOpts.spriteFactory and type(layerOpts.spriteFactory) == "function" then
      sprite = layerOpts.spriteFactory(obj, layer.name, layerOpts)
    else
      -- Default sprite creation
      sprite = createDefaultObjectSprite(obj, layerOpts)
    end

    if sprite then
      -- Base object position in world‐pixels (top‐left or centered)
      local x, y = obj.x or 0, obj.y or 0
      if opts.anchor == "center" then
        x = x + (obj.width  or 0) * 0.5
        y = y + (obj.height or 0) * 0.5
      end

      -- Compute final screen coordinates (screenX, screenY)
      local screenX, screenY = x, y

      -- Position the sprite
      if sprite.setWorldPosition then
        -- Parallax‐aware sprite
        sprite:setWorldPosition(screenX, screenY)
      else
        -- Normal screen‐positioned sprite
        sprite:moveTo(screenX, screenY)
      end

      -- Set z-index if specified
      local zIndex = layerOpts.zIndex or opts.zIndices[layer.name] or 0
      sprite:setZIndex(zIndex)

      -- Set visibility
      sprite:setVisible(layerOpts.visible ~= false)

      -- Store object data on sprite for reference
      sprite.tiledObject = obj

      -- Add collision if requested
      if layerOpts.collidable == true then
        sprite:setTag(layerOpts.tag or 2) -- Different from wall sprites (tag 1)
        sprite:setCollideRect(0, 0, sprite:getSize())
        if layerOpts.spriteGroup then
          sprite:setGroups(type(layerOpts.spriteGroup) == "table" and layerOpts.spriteGroup or {layerOpts.spriteGroup})
        end
        if layerOpts.collidesWithGroups and type(layerOpts.collidesWithGroups) == "table" and #layerOpts.collidesWithGroups > 0 then
          sprite:setCollidesWithGroups(layerOpts.collidesWithGroups)
        end
        sprite.collisionResponse = layerOpts.collisionResponse or opts.collisionResponse
      end

      tableInsert(layerSprites, sprite)

      -- Directly Append Sprites
      if newSprites then
        tableInsert(newSprites, sprite)
      end

      -- Auto-add sprite if requested
      if autoAdd then
        if sceneHasAdd then
          scene:addSprite(sprite)
        else
          sprite:add()
        end
      end
    end
  end

  return layerSprites
end

-- ! Create Parallax Update
-- Hoist and Cache sprite:update - Move parallax update function outside per-sprite loop
-- Define the parallax update function once, outside the sprite creation loop
-- This avoids creating new function instances for each sprite
local function createParallaxUpdate(worldX, worldY, parallaxX, parallaxY, parallaxOriginX, parallaxOriginY, rnd, camGetter, anchor, mapPixelWidth, mapPixelHeight)
  return function(self)
    local cameraX, cameraY = camGetter()

    -- Apply parallax origin pivot (consistent with projection classes)
    local pivotAdjustX = parallaxOriginX * (1 - parallaxX)
    local pivotAdjustY = parallaxOriginY * (1 - parallaxY)

    local screenX = rnd(worldX + pivotAdjustX - cameraX * parallaxX)
    local screenY = rnd(worldY + pivotAdjustY - cameraY * parallaxY)

    local currentX, currentY = self:getPosition()
    if screenX ~= currentX or screenY ~= currentY then
      self:moveTo(screenX, screenY)
    end
  end
end

--------------------------------------------------------------------------------
-- ! Class Definition
--------------------------------------------------------------------------------

class("RoxyTilemap").extends(Object)

--------------------------------------------------------------------------------
-- Isometric helpers (shared by iso/staggered leaves)
--------------------------------------------------------------------------------

-- ! Isometric Draw Offsets
-- Per-tile draw offsets so diamonds align with Tiled.
function RoxyTilemap._isoDrawOffsets(tileWidth, tileHeight, img)
  local imgWidth, imgHeight = img:getSize()
  local offsetX = (tileWidth - imgWidth) * 0.5
  local offsetY = (tileHeight - imgHeight)
  return offsetX, offsetY
end

-- ! Begin Manual Draw
-- Temporarily zero draw offset when doing manual placement.
function RoxyTilemap._beginManualDraw()
  local offsetX, offsetY = playdate.graphics.getDrawOffset()
  if offsetX ~= 0 or offsetY ~= 0 then playdate.graphics.setDrawOffset(0, 0) end
  return offsetX, offsetY
end

-- ! End Manual Draw
-- Restore draw offset after manual placement.
function RoxyTilemap._endManualDraw(offsetX, offsetY)
  if offsetX ~= 0 or offsetY ~= 0 then playdate.graphics.setDrawOffset(offsetX, offsetY) end
end

-- ! Get Valid Layer
function RoxyTilemap._getValidLayer(layerName)
  if not layerName or not self.layers then return nil end
  local layer = self.layers[layerName]
  if not layer or not layer.tilemap or layer.visible == false then
    return nil
  end
  return layer
end

--------------------------------------------------------------------------------
-- ! Initialize
--------------------------------------------------------------------------------

--[[
  jsonPath: string - Path to Tiled JSON map
  opts:     table  - Configuration opts (see validateOptions)
  scene:    table? - Optional scene object with addSprite method
]]
function RoxyTilemap:init(jsonPath, opts, scene)
  opts = validateOptions(opts)

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

  -- Your original world size (orthographic assumption)
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
  tableSort(gidRanges, function(a, b) return a.first < b.first end)

  -- Cache First Tileset per Layer
  local function tilesetForGid(gid)
    for i = #gidRanges, 1, -1 do
      local range = gidRanges[i]
      if gid >= range.first then
        if gid <= range.last then return range.tileset end
        break
      end
    end
    return nil
  end

  -- Apply camera bounds if requested
  if opts.cameraBounds then
    setCameraBounds({
      x1 = 0,
      y1 = 0,
      x2 = max(0, self.worldWidth - DISPLAY_WIDTH),
      y2 = max(0, self.worldHeight - DISPLAY_HEIGHT)
    })
  end

  local mapPox = tonumber(mapData.parallaxoriginx) or 0
  local mapPoy = tonumber(mapData.parallaxoriginy) or 0

  -- Build tileset lookup (for loading imageTables)
  local tilesets = {}
  for _, tileset in ipairs(mapData.tilesets or {}) do
    local normPath = normalizeImgPath(tileset.image)
    if not normPath then
      Log.warn("[RoxyTilemap:init] Skipping tileset '" .. tostring(tileset.name) .. "' due to invalid image path") --#DEBUG
      goto continueTileset
    end

    tileset.imagePath = normPath -- Store normalized path
    tileset.imageTable = getImagetable(normPath)
    retain(normPath, tileset.imageTable)
    tilesets[tileset.name] = tileset

    ::continueTileset::
  end
  self.tilesets = tilesets

  -- Build layers
  self.layers = {}
  local newSprites = {}
  local processAll = next(opts.layers) == nil

  for _, layer in ipairs(mapData.layers or {}) do
    if layer.type == "tilelayer" and (processAll or opts.layers[layer.name]) then
      local layerOptions = (opts.layerOptions and opts.layerOptions[layer.name]) or {}
      local data = layer.data or {}

      -- Cache First Tileset per Layer - Find first nonzero GID and cache the tileset
      local usedTileset = nil
      for i = 1, #data do
        local rawGid = data[i]
        local gid = rawGid & 0x1FFFFFFF
        if gid ~= 0 then
          usedTileset = tilesetForGid(gid)
          break
        end
      end

      if not usedTileset then
        Log.warn("[RoxyTilemap:init] Layer '"..layer.name.."' has no matching tileset") --#DEBUG
        goto continue -- Skip this layer if no valid tileset
      end

      -- Check for non-empty layer
      local isEmpty = true
      for i = 1, #data do
        if data[i] ~= 0 then
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

      if usedTileset and not isEmpty and usedTileset.imageTable then
        local firstgid = usedTileset.firstgid
        local tilemap = newTilemap()
        tilemap:setSize(layer.width, layer.height)
        tilemap:setImageTable(usedTileset.imageTable)

        -- Set the tiles in the tilemap
        local indices = createTable(#data, 0)
        for i = 1, #data do
          local rawGid = data[i]
          local gid = rawGid & 0x1FFFFFFF
          -- Use cached usedTileset instead of calling tilesetForGid for each tile
          indices[i] = (gid ~= 0) and (gid - firstgid + 1) or 0
        end
        tilemap:setTiles(indices, layer.width)
        local tiles, stride = tilemap:getTiles()

        -- Use logical map tile size (e.g., 64x32) for iso math/culling
        -- Actual image size (e.g., 64x64) is handled via per-image offsets
        local tileWidth, tileHeight = self.mapTileWidth, self.mapTileHeight

        -- Precompute map pixel size for direct draw
        local width, height = tilemap:getSize()
        local mapPixelWidth  = width  * tileWidth
        local mapPixelHeight = height * tileHeight

        local maxImgH = 0
        do
          local tbl = usedTileset.imageTable
          local n = tbl and tbl:getLength() or 0
          for i = 1, n do
            local img = tbl:getImage(i)
            if img then
              local _, h = img:getSize()
              if h and h > maxImgH then maxImgH = h end
            end
          end
        end

        local layerData = {
          name = layer.name,
          tilemap = tilemap,
          tiledId = layer.id,
          anchor = opts.anchor,
          imageTable = usedTileset.imageTable,
          imagePath = usedTileset.imagePath,
          tileWidth = tileWidth,
          tileHeight = tileHeight,
          tilesFlat  = tiles,
          tilesStride = stride or layer.width,
          maxImgH = maxImgH,
          zIndex = (layerOptions.zIndex or opts.zIndices[layer.name] or 0),
          visible = (layerOptions.visible ~= false),
          mapPixelWidth = mapPixelWidth,
          mapPixelHeight = mapPixelHeight,
          _imgCache = {},
          _offCache = {},
        }

        -- Compute origin/parallax regardless of wrapping in sprites
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
        local pox = opts.parallaxOriginX or mapPox
        local poy = opts.parallaxOriginY or mapPoy
        layerData.parallaxx = parallaxX
        layerData.parallaxy = parallaxY
        layerData.parallaxoriginx = pox
        layerData.parallaxoriginy = poy

        -- Wrap in sprite if requested
        if opts.wrapInSprites then
          local sprite = newSprite()
          sprite:setTilemap(tilemap)
          if opts.anchor == "topLeft" then
            sprite:setCenter(0, 0)
          else
            sprite:setCenter(0.5, 0.5)
          end
          sprite:setZIndex(layerData.zIndex)

          local camGetter = getCameraPosition
          local rnd = round
          local useParallax = (layerOptions.parallax ~= false)
          if useParallax and (parallaxX ~= 1 or parallaxY ~= 1 or offsetX ~= 0 or offsetY ~= 0) then
            sprite:setIgnoresDrawOffset(true)
            sprite:setUpdatesEnabled(true)

            -- Use consistent pivot calculation like projection classes
            local pivotAdjustX = pox * (1 - parallaxX)
            local pivotAdjustY = poy * (1 - parallaxY)
            local worldX, worldY = originX, originY

            sprite.update = createParallaxUpdate(
              worldX, worldY,
              parallaxX, parallaxY,
              pox, poy,
              rnd, camGetter,
              opts.anchor, mapPixelWidth, mapPixelHeight
            )
          else
            sprite:moveTo(originX, originY)
          end

          tableInsert(newSprites, sprite)
          layerData.sprite = sprite
          if autoAdd then
            if sceneHasAdd then
              scene:addSprite(sprite)
            else
              sprite:add()
            end
          end

          sprite:setVisible(layerData.visible)
        end

        -- Add collision sprites (if collidable)
        if layerOptions.collidable == true then
          local emptyIDs = layerOptions.emptyIDs or {}
          local wallGroup = layerOptions.wallSpriteGroup or opts.wallSpriteGroup
          local layerCollidesWithGroups = layerOptions.wallCollidesWithGroups or opts.wallCollidesWithGroups

          local collisionSprites = addWallSprites(tilemap, emptyIDs)
          for _, sprite in ipairs(collisionSprites) do
            sprite:setTag(1)
            sprite:setCollideRect(0, 0, sprite:getSize())
            if wallGroup then
              sprite:setGroups(type(wallGroup) == "table" and wallGroup or { wallGroup })
            end
            if layerCollidesWithGroups and type(layerCollidesWithGroups) == "table" and #layerCollidesWithGroups > 0 then
              sprite:setCollidesWithGroups(layerCollidesWithGroups)
            end
            sprite.collisionResponse = layerOptions.collisionResponse or opts.collisionResponse
          end
          layerData.collisionSprites = collisionSprites
        end

        self.layers[layer.name] = layerData
      end
    end
    ::continue::
  end
  self.sprites = newSprites

  -- Process object layers
  local objectSprites = {}
  for _, layer in ipairs(mapData.layers or {}) do
    if layer.type == "objectgroup" and (processAll or opts.objectLayers[layer.name]) then
      local layerOptions = (opts.layerOptions and opts.layerOptions[layer.name]) or {}

      -- Pass newSprites to processObjectLayer for direct insertion
      local sprites = processObjectLayer(self, layer, opts, layerOptions, autoAdd, scene, sceneHasAdd, newSprites)
      objectSprites[layer.name] = sprites
    end
  end
  self.objectSprites = objectSprites -- Store object sprites

  self.objectLayers = {}
  for _, layer in ipairs(mapData.layers or {}) do
    if layer.type == "objectgroup" then
      self.objectLayers[layer.name] = layer.objects or {}
    end
  end

  -- Attach to a scene immediately
  if scene and scene.addTilemap then
    scene:addTilemap(self)
  end
end

--------------------------------------------------------------------------------
-- Public Methods
--------------------------------------------------------------------------------

-- ! Get Tilemap
function RoxyTilemap:getTilemap(name)
  return self.layers[name] and self.layers[name].tilemap
end

-- ! Get Sprite
function RoxyTilemap:getSprite(name)
  return self.layers[name] and self.layers[name].sprite
end

-- ! Get Objects
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
  return self.sprites or {}
end

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
  return self:findObjectSprites(layerName, function(obj)
    return obj.type == objectType
  end)
end

-- ! Find Object Sprites By Name
-- Returns all sprites from the layer whose Tiled objects have the specified name
function RoxyTilemap:findObjectSpritesByName(layerName, objectName)
  return self:findObjectSprites(layerName, function(obj)
    return obj.name == objectName
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
function RoxyTilemap:removeObjectLayer(layerName)
  local sprites = self:getObjectSprites(layerName)
  for _, sprite in ipairs(sprites) do
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

-- ! Get Tile At
-- Returns the tile index at the given tile coordinates (x, y) on the specified layer.
-- Note: Coordinates are in tile units, not pixels.
function RoxyTilemap:getTileAt(name, x, y)
  local tilemap = self:getTilemap(name)
  return tilemap and tilemap:getTileAtPosition(x, y) or nil
end

-- ! For Each Tile
-- Iterates over each tile on the specified layer, calling the provided function.
-- Note: Coordinates passed to the function are in tile units.
function RoxyTilemap:forEachTile(name, fn)
  local tilemap = self:getTilemap(name)
  if not tilemap or type(fn) ~= "function" then return end

  local width, height = tilemap:getSize()
  for y = 1, height do
    for x = 1, width do
      fn(x, y, tilemap:getTileAtPosition(x, y))
    end
  end
end

-- ! Get World Size
-- Returns the pixel dimensions of the tilemap, based on the first tile layer.
-- This is cached at init-time and available even if cameraBounds is false.
function RoxyTilemap:getWorldSize()
  return self.worldWidth, self.worldHeight
end

-- ! Hide Layer
function RoxyTilemap:hideLayer(name)
  local layer = self.layers and self.layers[name]
  if not layer then return end

  -- Ensure direct draw respects visibility
  layer.visible = false

  local sprite = layer.sprite
  if sprite then
    sprite:setVisible(false)
  end
end

-- ! Show Layer
function RoxyTilemap:showLayer(name)
  local layer = self.layers and self.layers[name]
  if not layer then return end

  -- Ensure direct draw respects visibility
  layer.visible = true

  local sprite = layer.sprite
  if sprite then
    sprite:setVisible(true)
  end
end

-- ! Remove Layer
function RoxyTilemap:removeLayer(name)
  local layer = self.layers[name]
  if not layer then return end

  -- Release only paths this instance retained
  if layer.imagePath and self._retainedPaths and self._retainedPaths[layer.imagePath] then
    release(layer.imagePath)
    self._retainedPaths[layer.imagePath] = nil
  end

  -- Remove display sprite & keep scene list in sync
  if layer.sprite then
    local sprite = layer.sprite
    if self.scene and self.scene.removeSprite then
      self.scene:removeSprite(sprite)
    else
      sprite:remove()
    end
    if self.sprites then
      for i = #self.sprites, 1, -1 do
        if self.sprites[i] == sprite then tableRemove(self.sprites, i) break end
      end
    end
    layer.sprite = nil
  end

  -- Remove collision sprites (they were not added via scene list, so display remove is fine)
  if layer.collisionSprites then
    for _, sprite in ipairs(layer.collisionSprites) do
      sprite:remove()
    end
    layer.collisionSprites = nil
  end

  -- Clear heavy references
  layer.tilemap = nil
  layer.imageTable = nil
  layer._imgCache = nil

  self.layers[name] = nil
end

--------------------------------------------------------------------------------
-- Swap / Set Layer Imagetable and Collisions
--------------------------------------------------------------------------------

-- ! Set Layer ImageTable
-- Swap the imagetable used by a tile layer at runtime.
-- newImageTableOrPath: a playdate.graphics.imagetable or a string path (Tiled/normalized)
-- remap: optional table or function to remap tile indices (oldIndex --> newIndex)
--   - If a table, remap[oldIndex] = newIndex
--   - If a function, newIndex = remap(oldIndex) (return nil to keep oldIndex)
function RoxyTilemap:setLayerImageTable(name, newImageTableOrPath, remap)
  local layer = self.layers and self.layers[name]
  if not layer or not layer.tilemap then
    Log.warn("[RoxyTilemap:setLayerImageTable] No layer or tilemap for '" .. tostring(name) .. "'") --#DEBUG
    return false
  end

  -- Resolve imagetable
  local newPath, newTable
  if type(newImageTableOrPath) == "string" then
    -- Normalize path like tileset loader does
    newPath = normalizeImgPath(newImageTableOrPath) or newImageTableOrPath
    newTable = getImagetable(newPath)
    if not newTable then
      Log.warn("[RoxyTilemap:setLayerImageTable] Failed to load imagetable: " .. tostring(newPath)) --#DEBUG
      return false
    end
  else
    newTable = newImageTableOrPath
    if not newTable then
      Log.warn("[RoxyTilemap:setLayerImageTable] Expected imagetable or path, got nil") --#DEBUG
      return false
    end
  end

  -- Optional remap of existing tile indices
  if remap then
    local data, width = layer.tilemap:getTiles()
    if data and width then
      if type(remap) == "function" then
        for i = 1, #data do
          local idx = data[i]
          if idx ~= 0 then
            local mapped = remap(idx)
            if mapped ~= nil then data[i] = mapped end -- Allow mapping to 0
          end
        end
      elseif type(remap) == "table" then
        for i = 1, #data do
          local idx = data[i]
          if idx ~= 0 then
            local mapped = remap[idx]
            if mapped ~= nil then
              data[i] = mapped -- Allow mapping to 0
            end
          end
        end
      else
        Log.warn("[RoxyTilemap:setLayerImageTable] Invalid remap; expected table or function") --#DEBUG
      end
      layer.tilemap:setTiles(data, width)
    end
  end

  -- Swap imagetable
  layer.tilemap:setImageTable(newTable)
  layer.imageTable = newTable
  layer._imgCache = {}
  layer._offCache = {}  -- reset offset cache

  -- Recompute max image height (use newTable, not usedTileset)
  local maxImgH = 0
  do
    local tbl = newTable
    local n = tbl and tbl:getLength() or 0
    for i = 1, n do
      local img = tbl:getImage(i)
      if img then
        local _, h = img:getSize()
        if h and h > maxImgH then maxImgH = h end
      end
    end
  end
  layer.maxImgH = maxImgH

  -- Update asset retention (if a path swap)
  if newPath then
    if not self._retainedPaths[newPath] then
      retain(newPath, newTable) -- Retain the newly used imagetable path
      self._retainedPaths[newPath] = true -- Track so we can release on destroy
    end

    local oldPath = layer.imagePath
    if oldPath and oldPath ~= newPath and self._retainedPaths[oldPath] then
      release(oldPath) -- Only release paths this instance retained
      self._retainedPaths[oldPath] = nil
    end
    layer.imagePath = newPath
  end

  -- Force a redraw of the area this layer covers (sprite or direct draw)
  -- Note: Sprites use dirty-rect optimization; we proactively invalidate.
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()
  local mapPixelWidth  = mapWidthTiles  * tileWidth
  local mapPixelHeight = mapHeightTiles * tileHeight

  local parallaxX, parallaxY = layer.parallaxx or 1, layer.parallaxy or 1
  local cameraX, cameraY = getCameraPosition()
  local originX, originY = layer.originX or 0, layer.originY or 0
  local centerX = (layer.anchor == "topLeft") and 0 or 0.5
  local centerY = (layer.anchor == "topLeft") and 0 or 0.5

  local screenX = round(originX - mapPixelWidth * centerX  - cameraX * parallaxX)
  local screenY = round(originY - mapPixelHeight * centerY - cameraY * parallaxY)

  addDirtyRect(screenX, screenY, mapPixelWidth, mapPixelHeight)

  return true
end

-- ! Rebuild Layer Collisions
-- Recreates wall sprites for a tile layer using the provided emptyIDs.
-- Use when a tileset swap changes which tile indices should be passable vs solid.
function RoxyTilemap:rebuildLayerCollisions(name, emptyIDs, wallGroup, collidesWithGroups, collisionResponse)
  local layer = self.layers and self.layers[name]
  if not layer or not layer.tilemap then return end

  -- Remove previous collision sprites (if any)
  if layer.collisionSprites then
    for _, sprite in ipairs(layer.collisionSprites) do
      sprite:remove()
    end
    layer.collisionSprites = nil
  end

  -- Build new collision sprites from current tile indices
  local collisionSprites = addWallSprites(layer.tilemap, emptyIDs or {})

  -- Configure sprites similar to init-time setup
  for _, sprite in ipairs(collisionSprites) do
    sprite:setTag(1)
    sprite:setCollideRect(0, 0, sprite:getSize())
    if wallGroup then
      sprite:setGroups(type(wallGroup) == "table" and wallGroup or { wallGroup })
    end
    if collidesWithGroups and type(collidesWithGroups) == "table" and #collidesWithGroups > 0 then
      sprite:setCollidesWithGroups(collidesWithGroups)
    end
    sprite.collisionResponse = collisionResponse or "overlap"
  end

  layer.collisionSprites = collisionSprites
end

--------------------------------------------------------------------------------
-- Projection methods
--------------------------------------------------------------------------------

-- ! World to Screen (abstract method)
function RoxyTilemap:worldToScreen(worldX, worldY, layer)
  Log.error("[RoxyTilemap:worldToScreen] Abstract method - must be implemented by projection subclass")
end

-- ! Screen to World (abstract method)
function RoxyTilemap:screenToWorld(screenX, screenY, layer)
  Log.error("[RoxyTilemap:screenToWorld] Abstract method - must be implemented by projection subclass")
end

-- ! Set Tile At (abstract method)
function RoxyTilemap:setTileAt(name, x, y, tileIndex, updateSprite)
  Log.error("[RoxyTilemap:setTileAt] Abstract method - must be implemented by projection subclass")
end

--------------------------------------------------------------------------------
-- Origin helpers
--------------------------------------------------------------------------------

-- ! Set Layer Origin
-- Updates the origin for a single layer and keeps any display sprite in sync.
function RoxyTilemap:setLayerOrigin(name, originX, originY)
  local layer = self.layers and self.layers[name]
  if not layer then return false end

  -- Update stored origin used by both sprite and direct draw
  layer.originX = originX or 0
  layer.originY = originY or 0

  -- Keep an existing sprite in sync
  local sprite = layer.sprite
  if sprite then
    local parallaxX = layer.parallaxx or 1
    local parallaxY = layer.parallaxy or 1
    local pox = layer.parallaxoriginx or 0
    local poy = layer.parallaxoriginy or 0

    -- If this layer was using a parallax update closure, rebuild it with the new origin.
    if sprite.update and sprite.setUpdatesEnabled then
      -- Recreate the cached updater using the helper
      sprite.update = createParallaxUpdate(
        layer.originX, layer.originY,
        parallaxX, parallaxY,
        pox, poy, -- Pass origins separately for consistency
        round, getCameraPosition,
        layer.anchor, layer.mapPixelWidth, layer.mapPixelHeight
      )
      -- Ensure we do not double-apply draw offset
      sprite:setIgnoresDrawOffset(true)
      sprite:setUpdatesEnabled(true)
    else
      -- No parallax updater; just move the sprite to the new origin
      sprite:moveTo(layer.originX, layer.originY)
    end
  end

  return true
end

-- ! Set Origin For All Layers
-- Convenience to apply the same origin to every tile layer.
function RoxyTilemap:setOriginForAllLayers(originX, originY)
  if not self.layers then return end
  for name, _ in pairs(self.layers) do
    self:setLayerOrigin(name, originX, originY)
  end
end

--------------------------------------------------------------------------------
-- Culling Utilities
--------------------------------------------------------------------------------

-- ! Get Screen Bounds In World Space
-- Returns the world coordinates of screen corners for a given layer
function RoxyTilemap:getScreenBoundsInWorld(layer)
  if not layer then return 0, 0, 0, 0 end

  local topLeftX, topLeftY = self:screenToWorld(0, 0, layer)
  local topRightX, topRightY = self:screenToWorld(DISPLAY_WIDTH, 0, layer)
  local bottomLeftX, bottomLeftY = self:screenToWorld(0, DISPLAY_HEIGHT, layer)
  local bottomRightX, bottomRightY = self:screenToWorld(DISPLAY_WIDTH, DISPLAY_HEIGHT, layer)

  local minX = min(topLeftX, topRightX, bottomLeftX, bottomRightX)
  local maxX = max(topLeftX, topRightX, bottomLeftX, bottomRightX)
  local minY = min(topLeftY, topRightY, bottomLeftY, bottomRightY)
  local maxY = max(topLeftY, topRightY, bottomLeftY, bottomRightY)

  return minX, minY, maxX, maxY
end

-- ! Get Visible Tile Bounds
-- Calculate which tiles are potentially visible with proper margin
function RoxyTilemap:getVisibleTileBounds(layer, extraMargin)
  if not layer then return 1, 1, 1, 1 end

  local mapWidthTiles, mapHeightTiles = layer.tilemap:getSize()

  -- Get world bounds of screen
  local minWorldX, minWorldY, maxWorldX, maxWorldY = self:getScreenBoundsInWorld(layer)

  -- Calculate margin based on image heights (if needed)
  local margin = extraMargin or 0
  if not extraMargin and layer.imageTable then
    -- Calculate proper margin like the projection classes do
    local tileHeight = layer.tileHeight or 0
    local halfHeight = tileHeight * 0.5

    -- Find max image height (similar to _getMaxImgH in projection classes)
    local maxImgH = 0
    local imageTable = layer.imageTable
    local imageTableLength = imageTable and imageTable:getLength() or 0
    for i = 1, imageTableLength do
      local img = imageTable:getImage(i)
      if img then
        local _, height = img:getSize()
        if height and height > maxImgH then
          maxImgH = height
        end
      end
    end

    local overdraw = max(0, maxImgH - tileHeight)
    margin = ceil(overdraw / max(1, halfHeight)) + 1
  end

  -- Apply margin and convert to tile coordinates
  minWorldX = minWorldX - margin
  maxWorldX = maxWorldX + margin
  minWorldY = minWorldY - margin
  maxWorldY = maxWorldY + margin

  local minTileX = max(1, floor(minWorldX) + 1)
  local maxTileX = min(mapWidthTiles, ceil(maxWorldX) + 1)
  local minTileY = max(1, floor(minWorldY) + 1)
  local maxTileY = min(mapHeightTiles, ceil(maxWorldY) + 1)

  return minTileX, minTileY, maxTileX, maxTileY
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- ! Draw
function RoxyTilemap:draw(name)
  -- Subclasses should implement their own drawing.
  Log.warn("[RoxyTilemap:draw] Abstract. Implement in a projection leaf.") --#DEBUG
end

-- ! Draw Visible
function RoxyTilemap:drawVisible()
  -- Subclasses should implement their own drawing.
  Log.warn("[RoxyTilemap:drawVisible] Abstract. Implement in a projection leaf.") --#DEBUG
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- ! Destroy
function RoxyTilemap:destroy()
  -- Remove layer sprites & collision sprites
  for _, layer in pairs(self.layers) do
    if layer.sprite then
      if self.scene and self.scene.removeSprite then
        self.scene:removeSprite(layer.sprite)
      else
        layer.sprite:remove()
      end
      layer.sprite = nil
    end
    if layer.collisionSprites then
      for _, sprite in ipairs(layer.collisionSprites) do
        sprite:remove()
      end
      layer.collisionSprites = nil
    end

    -- Clear heavy references
    layer.tilemap = nil
    layer.imageTable = nil
    layer._imgCache = nil
  end

  -- Remove object sprites (tracked by scene if added that way)
  for _, sprites in pairs(self.objectSprites or {}) do
    for _, sprite in ipairs(sprites) do
      if self.scene and self.scene.removeSprite then
        self.scene:removeSprite(sprite)
      else
        sprite:remove()
      end
    end
  end

  -- Clean up tilesets retained at init
  for _, tileset in pairs(self.tilesets or {}) do
    if tileset.imagePath then
      release(tileset.imagePath)
    end
  end

  -- Release any imagetable paths retained via swaps
  if self._retainedPaths then
    for path, _ in pairs(self._retainedPaths) do
      release(path)
    end
    self._retainedPaths = nil
  end

  self.layers = {}
  self.sprites = {}
  self.objectSprites = {}
  self.tilesets = nil
  self.objectLayers = nil

  -- Detach from scene and let it drop us from its tilemaps list
  if self.scene then
    local scene = self.scene
    self.scene = nil
    if scene.removeTilemap then
      scene:removeTilemap(self)
    end
  end
end

--#DEBUG START
--------------------------------------------------------------------------------
-- Debugging
-- Useful for troubleshooting the projection classes
--------------------------------------------------------------------------------

-- ! Debug Layer Info
function RoxyTilemap:debugLayerInfo(layerName)
  local layer = self.layers and self.layers[layerName]
  if not layer then
    Log.debug("Layer '" .. tostring(layerName) .. "' not found")
    return
  end

  Log.debug("**Layer: " .. layerName .. "**")
  Log.debug("Projection: " .. tostring(self._projection))
  Log.debug("Origin: " .. tostring(layer.originX) .. ", " .. tostring(layer.originY))
  Log.debug("Parallax: " .. tostring(layer.parallaxx) .. ", " .. tostring(layer.parallaxy))
  Log.debug("Parallax Origin: " .. tostring(layer.parallaxoriginx) .. ", " .. tostring(layer.parallaxoriginy))
  Log.debug("Tile Size: " .. tostring(layer.tileWidth) .. "x" .. tostring(layer.tileHeight))
  Log.debug("Map Size: " .. tostring(layer.mapPixelWidth) .. "x" .. tostring(layer.mapPixelHeight))
  Log.debug("Visible: " .. tostring(layer.visible))
  Log.debug("Has Sprite: " .. tostring(layer.sprite ~= nil))
  Log.debug("Has Collisions: " .. tostring(layer.collisionSprites ~= nil))
end

-- ! Debug Visible Bounds
function RoxyTilemap:debugVisibleBounds(layerName)
  local layer = self.layers and self.layers[layerName]
  if not layer then
    log.debug("Layer '" .. tostring(layerName) .. "' not found")
    return
  end

  local minWorldX, minWorldY, maxWorldX, maxWorldY = self:getScreenBoundsInWorld(layer)
  local minTileX, minTileY, maxTileX, maxTileY = self:getVisibleTileBounds(layer)

  log.debug("**Visible Bounds for " .. layerName .. "**")
  log.debug("World bounds: (" .. minWorldX .. ", " .. minWorldY .. ") to (" .. maxWorldX .. ", " .. maxWorldY .. ")")
  log.debug("Tile bounds: (" .. minTileX .. ", " .. minTileY .. ") to (" .. maxTileX .. ", " .. maxTileY .. ")")

  local cameraX, cameraY = getCameraPosition()
  log.debug("Camera: (" .. cameraX .. ", " .. cameraY .. ")")
end
--#DEBUG END
