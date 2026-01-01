-- core/modules/AssetStore.lua

--------------------------------------------------------------------------------
-- AssetStore - Reference-Counted Asset Management
--------------------------------------------------------------------------------
--
-- Provides high-level asset loading and lifecycle management with automatic
-- reference counting. Integrates with roxy.Cache for storage and implements
-- retain/release semantics for memory-efficient asset sharing.
--
-- Key Features:
--  - Reference counting for shared asset lifecycle management
--  - Loader function support for asset initialization
--  - Cached image and imagetable loading with path validation
--  - Integration with roxy.Cache for centralized asset storage
--
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Global Table Initialization
--------------------------------------------------------------------------------

roxy = roxy or {}
roxy.AssetStore = roxy.AssetStore or {}
local AssetStore <const> = roxy.AssetStore

--------------------------------------------------------------------------------
-- Playdate SDK Aliases
--------------------------------------------------------------------------------

local pd        <const> = playdate
local Graphics  <const> = pd.graphics

--------------------------------------------------------------------------------
-- Playdate SDK Function Aliases
--------------------------------------------------------------------------------

local newImage      <const> = Graphics.image.new
local newImagetable <const> = Graphics.imagetable.new

--------------------------------------------------------------------------------
-- Roxy Framework Aliases
--------------------------------------------------------------------------------

local r     <const> = roxy
local Cache <const> = r.Cache

--------------------------------------------------------------------------------
-- Roxy Framework Function Aliases
--------------------------------------------------------------------------------

local getCachedAsset    <const> = Cache.getCachedAsset
local cacheAsset        <const> = Cache.cacheAsset
local evictAsset        <const> = Cache.evictAsset
local getIsAssetCached  <const> = Cache.getIsAssetCached

--------------------------------------------------------------------------------
-- Local State Variables
--------------------------------------------------------------------------------

-- Reference count table for asset retention tracking
local referenceCount = {}

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Retain Asset
-- Increments the reference count for an asset and caches it if not already stored
--  @param path          Unique path string identifying the asset
--  @param assetOrThunk  Either a concrete asset value or a thunk function that creates it
--
--  @return Boolean true on success

function AssetStore.retain(path, assetOrThunk)
  if type(path) ~= "string" or path == "" then
    Log.warn("[AssetStore.retain] Invalid or missing path: " .. tostring(path)) --#DEBUG
    return false
  end

  if getIsAssetCached(path) then
    referenceCount[path] = (referenceCount[path] or 0) + 1
    return true
  end

  local didCache
  if type(assetOrThunk) == "function" then
    -- Store the thunk for deferred asset creation on first access
    didCache = cacheAsset(path, assetOrThunk)
  else
    -- Wrap the concrete asset value in a thunk for consistent retrieval
    local value = assetOrThunk
    didCache = cacheAsset(path, function() return value end)
  end

  if not didCache then
    return false
  end

  referenceCount[path] = (referenceCount[path] or 0) + 1
  return true
end

-- ! Release Asset
-- Decrements the reference count for an asset and evicts it when count reaches zero
--  @param path Unique path string identifying the asset to release
--
--  @return None

function AssetStore.release(path)
  local count = referenceCount[path]
  if not count then return end

  if count <= 1 then
    evictAsset(path)
    referenceCount[path] = nil
  else
    referenceCount[path] = count - 1
  end
end

-- ! Get Imagetable
-- Loads and caches an imagetable asset
--  @param path File path string to the imagetable resource
--
--  @return The imagetable instance, or nil if path is invalid or loading fails

function AssetStore.getImagetable(path)
  if type(path) ~= "string" or path == "" then
    Log.warn("[AssetStore.getImagetable] Invalid or missing path: " .. tostring(path)) --#DEBUG
    return nil
  end

  local cached = getCachedAsset(path)
  if cached then
    return cached
  end

  local loaded = newImagetable(path)
  if loaded then
    cacheAsset(path, function() return loaded end)
  else
    Log.warn("[AssetStore.getImagetable] Failed to load imagetable: " .. path) --#DEBUG
  end

  return loaded
end

-- ! Get Image Cached
-- Loads and caches an image asset
--  @param path File path string to the image resource
--
--  @return The image instance, or nil if path is invalid or loading fails

function AssetStore.getImageCached(path)
  if type(path) ~= "string" or path == "" then
    Log.warn("[AssetStore.getImageCached] Invalid or missing path: " .. tostring(path)) --#DEBUG
    return nil
  end

  local cached = getCachedAsset(path)
  if cached then
    return cached
  end

  local loaded = newImage(path)
  if loaded then
    cacheAsset(path, function() return loaded end)
  else
    Log.warn("[AssetStore.getImageCached] Failed to load image: " .. path) --#DEBUG
  end

  return loaded
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

AssetStore provides reference-counted asset caching with automatic cleanup.

-- Basic Loading
local image = AssetStore.getImageCached("images/background")
local sheet = AssetStore.getImagetable("images/player-sheet")

-- Retain/Release Pattern
AssetStore.retain("images/texture", playdate.graphics.image.new("images/texture"))
AssetStore.retain("images/texture", texture) -- Count = 2
AssetStore.release("images/texture")         -- Count = 1
AssetStore.release("images/texture")         -- Evicted from cache

-- Loader Function (asset created during retain)
AssetStore.retain("images/heavy", function()
  return playdate.graphics.image.new("images/large-background")
end)

-- Scene Lifecycle
function MyScene:init()
  AssetStore.retain("images/player", function()
    return AssetStore.getImagetable("images/player-sheet")
  end)
end

function MyScene:cleanup()
  AssetStore.release("images/player")
end

-- Shared Assets (multiple retains keep asset cached until all release)
AssetStore.retain("images/particle", loader) -- SpriteA retains
AssetStore.retain("images/particle", loader) -- SpriteB retains (count = 2)
AssetStore.release("images/particle")        -- SpriteA releases (count = 1)
AssetStore.release("images/particle")        -- SpriteB releases (evicted)

--]]
