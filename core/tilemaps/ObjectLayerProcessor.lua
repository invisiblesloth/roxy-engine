-- core/tilemaps/ObjectLayerProcessor.lua

roxy = roxy or {}
roxy.ObjectLayerProcessor = roxy.ObjectLayerProcessor or {}
local ObjectLayerProcessor <const> = roxy.ObjectLayerProcessor

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r           <const> = roxy
local AssetStore  <const> = r.AssetStore

local tableCreate <const> = table.create
local tableInsert <const> = table.insert

local pushContext <const> = Graphics.pushContext
local popContext  <const> = Graphics.popContext
local newImage    <const> = Graphics.image.new
local setColor    <const> = Graphics.setColor
local fillRect    <const> = Graphics.fillRect

local newSprite <const> = Sprite.new

local retain          <const> = AssetStore.retain
local getImageCached  <const> = AssetStore.getImageCached

local IMAGE_PATH_PREFIX <const> = "assets/images/"

local SPRITE_DEFAULT_DIMS <const> = 16

local OBJECT_TAG <const> = 2

local COLOR_BLACK <const> = Graphics.kColorBlack

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Non-Empty String
-- Returns a string only when it contains visible text.
local function _nonEmptyString(value)
  if type(value) == "string" and value:match("%S") then
    return value
  end
  return nil
end

--------------------------------------------------------------------------------
-- Create Default Object Sprite
--------------------------------------------------------------------------------

-- ! Create Default Object Sprite
function ObjectLayerProcessor.createDefaultObjectSprite(object, layerOptions, fallbackParallaxX, fallbackParallaxY)
  -- Initialize parallax values and object properties
  local parallaxX, parallaxY = 1, 1
  local parallaxOriginX, parallaxOriginY = 0, 0
  local objectProperties = {}

  if object.properties then
    for _, property in ipairs(object.properties) do
      local name = property.name
      local value = property.value
      objectProperties[name] = value
      if name == "parallaxX" then
        parallaxX = tonumber(value) or 1
      elseif name == "parallaxY" then
        parallaxY = tonumber(value) or 1
      elseif name == "parallaxOriginX" then
        parallaxOriginX = tonumber(value) or 0
      elseif name == "parallaxOriginY" then
        parallaxOriginY = tonumber(value) or 0
      end
    end
  end

  -- Use layer fallback only if object did not override
  if parallaxX == 1 and parallaxY == 1 then
    if fallbackParallaxX then parallaxX = fallbackParallaxX end
    if fallbackParallaxY then parallaxY = fallbackParallaxY end
  end

  -- Determine if parallax is needed
  local hasParallax = parallaxX ~= 1 or parallaxY ~= 1

  -- Determine image path
  local imagePath = nil
  local explicitImage = _nonEmptyString(objectProperties.image) or _nonEmptyString(objectProperties.sprite)
  if explicitImage then
    imagePath = IMAGE_PATH_PREFIX .. explicitImage
  else
    local baseName = _nonEmptyString(object.type) or _nonEmptyString(object.name)
    if baseName then
      imagePath = IMAGE_PATH_PREFIX .. baseName
    end
  end

  -- Try to load the image (optional)
  local img = imagePath and getImageCached(imagePath) or nil
  local didRetain = false
  if img then
    didRetain = retain(imagePath, img)
    if not didRetain then
      Log.warn("[ObjectLayerProcessor] Failed to retain image: " .. tostring(imagePath)) --#DEBUG
    end
  end

  -- Create appropriate sprite type
  local sprite
  if hasParallax then
    sprite = RoxySprite({
      view = img,
      worldX = object.x or 0,
      worldY = object.y or 0,
      parallaxX = parallaxX,
      parallaxY = parallaxY,
      parallaxOriginX = parallaxOriginX,
      parallaxOriginY = parallaxOriginY
    })
  else
    sprite = newSprite()
    if img then
      sprite:setImage(img)
    --#DEBUG START
    else
      -- Create fallback image for debugging
      local width = object.width or SPRITE_DEFAULT_DIMS
      local height = object.height or SPRITE_DEFAULT_DIMS
      local fallbackImage = newImage(width, height)
      pushContext(fallbackImage)
        setColor(COLOR_BLACK)
        fillRect(0, 0, width, height)
      popContext()
      sprite:setImage(fallbackImage)
    --#DEBUG END
    end
  end

  -- Track retained image path for cleanup
  sprite._retainedImagePath = didRetain and imagePath or nil

  -- Store object properties on sprite for reference
  sprite.objectProps = objectProperties
  return sprite
end

--------------------------------------------------------------------------------
-- Process a single object layer into sprites
--------------------------------------------------------------------------------

-- ! Process Object Layer
function ObjectLayerProcessor.processObjectLayer(layer, opts, layerOptions, autoAdd, scene, sceneHasAdd, outSprites)
  local objects = layer.objects or {}

  -- Resolve per-layer parallax once.
  -- (1) Prefer explicit layerOptions (both camelCase and lowercase accepted),
  -- (2) then Tiled layer fields (parallaxx/parallaxy),
  -- (3) default to 1.
  local optPX = layerOptions.parallaxX or layerOptions.parallaxx
  local optPY = layerOptions.parallaxY or layerOptions.parallaxy
  local layerPX = tonumber(layer.parallaxx) or nil
  local layerPY = tonumber(layer.parallaxy) or nil
  local resolvedParallaxX = tonumber(optPX) or layerPX or 1
  local resolvedParallaxY = tonumber(optPY) or layerPY or 1

  local layerSprites = tableCreate(#objects, 0)

  for _, object in ipairs(objects) do
    local sprite = nil

    if opts.spriteFactory and type(opts.spriteFactory) == "function" then
      sprite = opts.spriteFactory(object, layer, layerOptions)
    elseif layerOptions.spriteFactory and type(layerOptions.spriteFactory) == "function" then
      sprite = layerOptions.spriteFactory(object, layer, layerOptions)
    else
      -- Default creation uses resolved layer parallax as a fallback.
      -- Object properties can still override it.
      sprite = ObjectLayerProcessor.createDefaultObjectSprite(object, layerOptions, resolvedParallaxX, resolvedParallaxY)
    end

    if sprite then
      -- Compute world position from the configured anchor
      local positionX, positionY = object.x or 0, object.y or 0
      if opts.anchor == "center" then
        positionX += (object.width  or 0) * 0.5
        positionY += (object.height or 0) * 0.5
      end

      if sprite.setWorldPosition then
        sprite:setWorldPosition(positionX, positionY)
      else
        sprite:moveTo(positionX, positionY)
      end

      -- Z-index and visibility
      local zIndex = layerOptions.zIndex or (opts.zIndices and opts.zIndices[layer.name]) or 0
      sprite:setZIndex(zIndex)
      sprite:setVisible(layerOptions.visible ~= false)

      -- Back-reference to Tiled object
      sprite.tiledObject = object

      -- Optional collisions for object sprites
      if layerOptions.collidable == true then
        sprite:setTag(layerOptions.tag or OBJECT_TAG)
        sprite:setCollideRect(0, 0, sprite:getSize())

        if layerOptions.spriteGroup then
          sprite:setGroups(type(layerOptions.spriteGroup) == "table" and layerOptions.spriteGroup or { layerOptions.spriteGroup })
        end
        if layerOptions.collidesWithGroups and type(layerOptions.collidesWithGroups) == "table" and #layerOptions.collidesWithGroups > 0 then
          sprite:setCollidesWithGroups(layerOptions.collidesWithGroups)
        end

        sprite.collisionResponse = layerOptions.collisionResponse or opts.collisionResponse
      end

      tableInsert(layerSprites, sprite)

      -- Append into global new-sprites list if provided
      if outSprites then
        tableInsert(outSprites, sprite)
      end

      -- Optionally add to display/scene immediately
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

--------------------------------------------------------------------------------
-- Process multiple layers by name-set (or all object layers on the map)
--------------------------------------------------------------------------------

-- ! Process Object Layers
function ObjectLayerProcessor.processObjectLayers(tilemapInstance, mapData, opts, layersToProcess, autoAdd, scene, sceneHasAdd, outSprites)
  -- layersToProcess is an optional set: { ["Layer Name"] = true, ... }
  local objectSprites = tilemapInstance.objectSprites or {}
  local processedCount = 0

  for _, layer in ipairs(mapData.layers or {}) do
    if layer.type == "objectgroup" then
      local shouldProcess = not layersToProcess or layersToProcess[layer.name]
      if shouldProcess then
        local layerOptions = (opts.layerOptions and opts.layerOptions[layer.name]) or {}
        local sprites = ObjectLayerProcessor.processObjectLayer(layer, opts, layerOptions, autoAdd, scene, sceneHasAdd, outSprites)
        objectSprites[layer.name] = sprites
        processedCount += 1
      end
    end
  end

  tilemapInstance.objectSprites = objectSprites
  return processedCount
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

local scene = RoxyScene()

local map = RoxyOrthoTilemap("assets/maps/level-01.json", {
  objectLayers = {
    Pickups = true,
  },
  layerOptions = {
    Pickups = {
      collidable = true,
      spriteGroup = 2,
      collidesWithGroups = { 1 },
      parallaxX = 1,
      parallaxY = 1,
    },
  },
})
scene:addTilemap(map)

local pickups = map:getObjectSprites("Pickups")
local strawberry = map:findObjectSprite("Pickups", function(sprite)
  return sprite.objectProps.kind == "strawberry"
end)

map:removeObjectLayer("Pickups")

]]--
