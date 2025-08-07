-- core/tilemaps/RoxyTilemap.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r         <const> = roxy
local Cache     <const> = r.Cache
local Camera    <const> = r.Camera

local max   <const> = math.max
local round <const> = r.Math.round

local createTable <const> = table.create
local tableInsert <const> = table.insert
local tableSort   <const> = table.sort

local loadJSON <const> = r.JSON.loadJson

local newImage        <const> = Graphics.image.new
local newImagetable   <const> = Graphics.imagetable.new
local newTilemap      <const> = Graphics.tilemap.new
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

local DISPLAY_WIDTH     <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT    <const> = r.Graphics.displayHeight

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
  local base     = filename:gsub("%-table%-%d+%-%d+%.png$", "")
  if base == filename then
    Log.warn("[normalizeImgPath] Unexpected image path pattern: " .. tostring(tiledImgPath)) --#DEBUG
    return IMAGE_PATH_PREFIX .. filename
  end
  return IMAGE_PATH_PREFIX .. base
end

-- ! Get Image Table
local function getImageTable(path)
  if type(path) ~= "string" or path == "" then
    Log.warn("[getImageTable] Invalid or missing path: " .. tostring(path))
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
    Log.warn("[getImageTable] Failed to load image table at path: " .. path) --#DEBUG
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
  local objectProperties = {}

  -- Parse object properties
  if obj.properties then
    for _, prop in ipairs(obj.properties) do
      objectProperties[prop.name] = prop.value

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
  if objectProperties.image or objectProperties.sprite then
    imagePath = IMAGE_PATH_PREFIX .. (objectProperties.image or objectProperties.sprite)
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

  local sprite

  -- Create parallax sprite if needed and RoxyParallaxSprite is available
  if hasParallax and r.RoxyParallaxSprite then
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
    -- Create regular sprite
    sprite = newSprite()
    if image then
      sprite:setImage(image)
    end
  end

  -- Fallback image creation for regular sprites
  if not image and not hasParallax then
    -- Create a simple rectangle sprite as fallback
    local width = obj.width or 16
    local height = obj.height or 16
    local fallbackImage = Graphics.image.new(width, height)
    Graphics.pushContext(fallbackImage)
    Graphics.setColor(Graphics.kColorBlack)
    Graphics.drawRect(0, 0, width, height)
    Graphics.popContext()
    sprite:setImage(fallbackImage)
  end

  -- Store all object properties on the sprite for reference
  sprite.objectProperties = objectProperties

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

      -- Compute final screen coordinates (sx, sy)
      local sx, sy
      if self.isIsometric then
        -- Convert from world-pixels to world-tiles for projection
        local layerData = self.layers[layer.name] or self.layers[Object.keys(self.layers)[1]]
        if layerData then
          local tileX = x / layerData.tileWidth
          local tileY = y / layerData.tileHeight
          sx, sy = self:worldToScreen(tileX, tileY, layerData)
        else
          sx, sy = x, y -- fallback
        end
      else
        sx, sy = x, y
      end

      -- Position the sprite
      if sprite.setWorldPosition then
        -- Parallax‐aware sprite
        sprite:setWorldPosition(sx, sy)
      else
        -- Normal screen‐positioned sprite
        sprite:moveTo(sx, sy)
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
local function createParallaxUpdate(worldX, worldY, pivotAdjustX, pivotAdjustY, px, py, rnd, camGetter)
  return function(self)
    local cameraX, cameraY = camGetter()
    local screenX = rnd(worldX + pivotAdjustX - cameraX * px)
    local screenY = rnd(worldY + pivotAdjustY - cameraY * py)
    local currentX, currentY = self:getPosition()
    if screenX ~= currentX or screenY ~= currentY then
      self:moveTo(screenX, screenY)
    end
  end
end

--------------------------------------------------------------------------------
-- ! Class Definition & Init
--------------------------------------------------------------------------------

class("RoxyTilemap").extends(Object)

--[[
  jsonPath  : string - Path to Tiled JSON map
  opts   : table  - Configuration opts (see validateOptions)
    autoAddSprites (bool) - automatically add layer sprites (default true)
  scene     : table? - Optional scene object with addSprite method
]]
function RoxyTilemap:init(jsonPath, opts, scene)
  opts = validateOptions(opts)
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

  -- Read Tiled’s orientation field and set a flag
  self.orientation = mapData.orientation or "orthogonal"
  self.isIsometric = (self.orientation == "isometric")

  -- Build GID ranges for tileset auto-detection
  local gidRanges = {}
  for _, tileset in ipairs(mapData.tilesets or {}) do
    gidRanges[#gidRanges + 1] = {
      first   = tileset.firstgid,
      last    = tileset.firstgid + (tileset.tilecount or 0) - 1,
      tileset = tileset
    }
  end
  tableSort(gidRanges, function(a, b) return a.first < b.first end)

  -- Cache First Tileset per Layer - Define tilesetForGid function once
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

  self.worldWidth  = (mapData.width  or 0) * (mapData.tilewidth  or 0)
  self.worldHeight = (mapData.height or 0) * (mapData.tileheight or 0)

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

    tileset.imagePath = normPath -- store normalized path
    tileset.imageTable = getImageTable(normPath)
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

        local tileWidth, tileHeight = tilemap:getTileSize()
        local layerData = {
          tilemap = tilemap,
          anchor = opts.anchor,
          tileWidth = tileWidth,
          tileHeight = tileHeight,
          isIsometric = self.isIsometric,
          imageTable = usedTileset.imageTable
        }

        -- Wrap in sprite if requested
        if opts.wrapInSprites then
          local offsetX = tonumber(layer.offsetx) or 0
          local offsetY = tonumber(layer.offsety) or 0
          local width, height = tilemap:getSize()
          local tileWidth, tileHeight = tilemap:getTileSize()
          local mapWidth = width * tileWidth
          local mapHeight = height * tileHeight

          local originX, originY
          if opts.anchor == "topLeft" then
            originX, originY = offsetX, offsetY
          else -- "center"
            originX = (mapWidth * 0.5) + offsetX
            originY = (mapHeight * 0.5) + offsetY
          end

          -- Keep this for both projections, so worldToScreen can use it
          layerData.originX = originX
          layerData.originY = originY

          local sprite = newSprite()
          sprite:setTilemap(tilemap)
          if opts.anchor == "topLeft" then
            sprite:setCenter(0, 0)
          else
            sprite:setCenter(0.5, 0.5)
          end
          sprite:setZIndex(layerOptions.zIndex or opts.zIndices[layer.name] or 0)


          local px = tonumber(layer.parallaxx) or 1
          local py = tonumber(layer.parallaxy) or 1
          local pox = opts.parallaxOriginX or mapPox
          local poy = opts.parallaxOriginY or mapPoy

          layerData.parallaxx = px
          layerData.parallaxy = py
          layerData.parallaxoriginx = pox
          layerData.parallaxoriginy = poy

          -- Hoist and Cache sprite:update - Cache constants as locals
          local camGetter = getCameraPosition
          local rnd = round

          local useParallax = (layerOptions.parallax ~= false)
          if useParallax and (px ~= 1 or py ~= 1 or offsetX ~= 0 or offsetY ~= 0) then
            sprite:setIgnoresDrawOffset(true)
            sprite:setUpdatesEnabled(true)

            -- Cache constants as locals to avoid table lookups each frame
            local pivotAdjustX = pox * (1 - px)
            local pivotAdjustY = poy * (1 - py)
            local worldX, worldY = originX, originY

            -- Use the hoisted createParallaxUpdate function
            sprite.update = createParallaxUpdate(worldX, worldY, pivotAdjustX, pivotAdjustY, px, py, rnd, camGetter)
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

          -- Set visibility per layerOption
          sprite:setVisible(layerOptions.visible ~= false)
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
              sprite:setGroups(type(wallGroup) == "table" and wallGroup or {wallGroup})
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

  -- Process object layers (NEW SECTION)
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

  -- Attach to a scene immediately (optional)
  if scene and scene.addTilemap then
    scene:addTilemap(self)
  end
end

--------------------------------------------------------------------------------
-- ! Public Methods
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
    sprite:remove()
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

-- ! Set Tile At
-- Sets the tile at the given tile coordinates (x, y) on the specified layer.
-- Note: Coordinates are in tile units, not pixels.
function RoxyTilemap:setTileAt(name, x, y, tileIndex, updateSprite)
  local layer = self.layers[name]
  if not layer then return end

  layer.tilemap:setTileAtPosition(x, y, tileIndex)

  if updateSprite and layer.sprite then
    local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
    local camX, camY = getCameraPosition()
    local px, py = (x - 1) * tileWidth, (y - 1) * tileHeight
    addDirtyRect(px - camX, py - camY, tileWidth, tileHeight)
  end
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

-- ! World to Screen
-- Convert tile/world coords to screen coords, with parallax & orientation
function RoxyTilemap:worldToScreen(worldX, worldY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local originX, originY = layer.originX or 0, layer.originY or 0
  local px, py = layer.parallaxx or 1, layer.parallaxy or 1
  local camX, camY = getCameraPosition()
  if self.isIsometric then
    -- Isometric projection
    local isoX = originX + (worldX - worldY) * (tileWidth / 2)
    local isoY = originY + (worldX + worldY) * (tileHeight / 2)
    return round(isoX - camX * px), round(isoY - camY * py)
  else
    -- Orthogonal projection
    local orthoX = originX + worldX * tileWidth
    local orthoY = originY + worldY * tileHeight
    return round(orthoX - camX * px), round(orthoY - camY * py)
  end
end

-- ! Screen to World
-- Convert screen coordinates back to world coordinates
function RoxyTilemap:screenToWorld(screenX, screenY, layer)
  local tileWidth, tileHeight = layer.tileWidth, layer.tileHeight
  local originX, originY = layer.originX or 0, layer.originY or 0
  local px, py = layer.parallaxx or 1, layer.parallaxy or 1
  local camX, camY = getCameraPosition()

  if self.isIsometric then
    -- Reverse isometric projection
    local adjX = (screenX + camX * px) - originX
    local adjY = (screenY + camY * py) - originY
    local worldX = (adjX / (tileWidth / 2) + adjY / (tileHeight / 2)) / 2
    local worldY = (adjY / (tileHeight / 2) - adjX / (tileWidth / 2)) / 2
    return worldX, worldY
  else
    -- Reverse orthogonal projection
    local worldX = ((screenX + camX * px) - originX) / tileWidth
    local worldY = ((screenY + camY * py) - originY) / tileHeight
    return worldX, worldY
  end
end

-- ! Hide Layer
function RoxyTilemap:hideLayer(name)
  local sprite = self:getSprite(name)
  if sprite then
    sprite:setVisible(false)
  end
end

-- ! Show Layer
function RoxyTilemap:showLayer(name)
  local sprite = self:getSprite(name)
  if sprite then
    sprite:setVisible(true)
  end
end

-- ! Remove Layer
function RoxyTilemap:removeLayer(name)
  local layer = self.layers[name]
  if not layer then return end

  if layer.sprite then
    layer.sprite:remove()
    layer.sprite = nil
  end
  if layer.collisionSprites then
    for _, sprite in ipairs(layer.collisionSprites) do
      sprite:remove()
    end
    layer.collisionSprites = nil
  end
  layer.tilemap = nil

  self.layers[name] = nil
end

-- ! Destroy
function RoxyTilemap:destroy()
  -- Existing tile layer cleanup...
  for _, layer in pairs(self.layers) do
    if layer.sprite then
      layer.sprite:remove()
      layer.sprite = nil
    end
    if layer.collisionSprites then
      for _, sprite in ipairs(layer.collisionSprites) do
        sprite:remove()
      end
      layer.collisionSprites = nil
    end
    layer.tilemap = nil
  end

  -- Clean up object sprites
  for _, sprites in pairs(self.objectSprites or {}) do
    for _, sprite in ipairs(sprites) do
      sprite:remove()
    end
  end

  for _, tileset in pairs(self.tilesets or {}) do
    if tileset.imagePath then
      release(tileset.imagePath)
    end
  end

  self.layers = {}
  self.sprites = {}
  self.objectSprites = {} -- NEW
  self.tilesets = nil
  self.objectLayers = nil

  if self.scene then
    local scene = self.scene
    self.scene = nil
    if scene.removeTilemap then scene:removeTilemap(self) end
  end
end
