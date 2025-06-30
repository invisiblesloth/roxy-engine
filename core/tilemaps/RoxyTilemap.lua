-- core/tilemaps/RoxyTilemap.lua

local pd        <const> = playdate
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

-- ----------------------------------------
-- Helpers
-- ----------------------------------------

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
    warn("[W][normalizeImgPath] Expected string, got " .. type(tiledImgPath)) --#DEBUG
    return nil
  end
  local filename = tiledImgPath:match("([^/]+)$") or ""
  local base     = filename:gsub("%-table%-%d+%-%d+%.png$", "")
  if base == filename then
    warn("[W][normalizeImgPath] Unexpected image path pattern: " .. tostring(tiledImgPath)) --#DEBUG
    return IMAGE_PATH_PREFIX .. filename
  end
  return IMAGE_PATH_PREFIX .. base
end

-- ! Get Image Table
local function getImageTable(path)
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
    warn("[W][getImageTable] Failed to load image table at path: " .. path) --#DEBUG
  end

  return loaded
end

-- ! Validate Options
local function validateOptions(opts)
  opts = opts or {}
  local layerOptions = opts.layerOptions or {}

  -- Validate per-layer emptyIDs
  for layerName, opts in pairs(layerOptions) do
    if opts.emptyIDs ~= nil then
      if type(opts.emptyIDs) ~= "table" then
        warn("[W][validateOptions] layerOptions['" .. layerName .. "'].emptyIDs must be a table") --#DEBUG
        opts.emptyIDs = EMPTY_TABLE
      else
        for i, id in ipairs(opts.emptyIDs) do
          if type(id) ~= "number" then
            warn("[W][validateOptions] emptyIDs contains non-number at index " .. i .. " for layer '" .. layerName .. "'") --#DEBUG
            opts.emptyIDs[i] = 0
          end
        end
      end
    end
  end

  return {
    layers                 = opts.layers or {},
    wrapInSprites          = opts.wrapInSprites ~= false,
    autoAddSprites         = opts.autoAddSprites ~= false,
    zIndices               = type(opts.zIndices) == "table" and opts.zIndices or {},
    cameraBounds           = opts.cameraBounds or false,
    anchor                 = (opts.anchor == "topLeft") and "topLeft" or "center",
    collisionResponse      = opts.collisionResponse or "overlap",
    parallaxOriginX        = opts.parallaxOriginX,
    parallaxOriginY        = opts.parallaxOriginY,
    wallSpriteGroup        = opts.wallSpriteGroup,
    wallCollidesWithGroups = opts.wallCollidesWithGroups or {},
    layerOptions           = layerOptions,
  }
end

-- ----------------------------------------
-- ! Class Definition & Init
-- ----------------------------------------

class("RoxyTilemap").extends()

--[[
  jsonPath  : string - Path to Tiled JSON map
  opts   : table  - Configuration opts (see validateOptions)
    autoAddSprites (bool) - automatically add layer sprites (default true)
  scene     : table? - Optional scene object with addSprite method
]]
function RoxyTilemap:init(jsonPath, opts, scene)
  opts = validateOptions(opts)
  local autoAdd = opts.wrapInSprites and opts.autoAddSprites
  local sceneHasAdd = scene and type(scene) == "table" and type(scene.addSprite) == "function" or false

  --#DEBUG START
  if scene and not sceneHasAdd then
    warn("[W][RoxyTilemap:init] RoxyTilemap: scene provided but has no addSprite method")
    -- Will fall back to sprite:add()
  end
  --#DEBUG END

  -- Load the map JSON
  local mapData, err = loadJSON(jsonPath)
  if not mapData then
    error("[*][RoxyTilemap:init] " .. (err or "unknown error")) --#DEBUG
    self.layers, self.sprites, self.tilesets, self.objectLayers = {}, {}, nil, nil
    self.worldWidth, self.worldHeight = 0, 0
    return
  end

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
      warn("[W][RoxyTilemap:init] Skipping tileset '" .. tostring(tileset.name) .. "' due to invalid image path") --#DEBUG
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

      -- Auto-detect the tileset for this layer (first nonzero GID)
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
        warn("[W][RoxyTilemap:init] Layer '"..layer.name.."' has no matching tileset") --#DEBUG
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
        warn("[W][RoxyTilemap:init] Skipping empty layer '" .. layer.name .. "'")
      end
      if usedTileset and not usedTileset.imageTable then
        warn("[W][RoxyTilemap:init] Skipping layer '" .. layer.name .. "' due to missing imagetable")
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
          indices[i] = (gid ~= 0) and (gid - firstgid + 1) or 0
        end
        tilemap:setTiles(indices, layer.width)

        local tileWidth, tileHeight = tilemap:getTileSize()
        local layerData = {
          tilemap = tilemap,
          anchor = opts.anchor,
          tileWidth = tileWidth,
          tileHeight = tileHeight
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

          local sprite = newSprite()
          sprite:setTilemap(tilemap)
          if opts.anchor == "topLeft" then
            sprite:setCenter(0, 0)
          else
            sprite:setCenter(0.5, 0.5)
          end
          sprite:setZIndex(opts.zIndices[layer.name] or 0)

          local px = tonumber(layer.parallaxx) or 1
          local py = tonumber(layer.parallaxy) or 1
          local pox = opts.parallaxOriginX or mapPox
          local poy = opts.parallaxOriginY or mapPoy

          layerData.parallaxx = px
          layerData.parallaxy = py
          layerData.parallaxoriginx = pox
          layerData.parallaxoriginy = poy

          local camGetter = getCameraPosition
          local rnd = round

          local useParallax = (layerOptions.parallax ~= false)
          if useParallax and (px ~= 1 or py ~= 1 or offsetX ~= 0 or offsetY ~= 0) then
            sprite:setIgnoresDrawOffset(true)
            sprite:setUpdatesEnabled(true)
            local pivotAdjustX = pox * (1 - px)
            local pivotAdjustY = poy * (1 - py)
            local worldX, worldY = originX, originY
            function sprite:update()
              local cameraX, cameraY = camGetter()
              local screenX = rnd(worldX + pivotAdjustX - cameraX * px)
              local screenY = rnd(worldY + pivotAdjustY - cameraY * py)
              local currentX, currentY = self:getPosition()
              if screenX ~= currentX or screenY ~= currentY then
                self:moveTo(screenX, screenY)
              end
            end
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

  self.objectLayers = {}
  for _, layer in ipairs(mapData.layers or {}) do
    if layer.type == "objectgroup" then
      self.objectLayers[layer.name] = layer.objects or {}
    end
  end
end

-- ---------------------------------- --
-- ! Public Methods                   --
-- ---------------------------------- --

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
  for _, tileset in pairs(self.tilesets or {}) do
    if tileset.imagePath then
      release(tileset.imagePath)
    end
  end
  self.layers = {}
  self.sprites = {}
  self.tilesets = nil
  self.objectLayers = nil
end
