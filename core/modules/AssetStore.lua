-- core/modules/AssetStore.lua

roxy = roxy or {}
roxy.AssetStore = roxy.AssetStore or {}
local AssetStore <const> = roxy.AssetStore

local pd        <const> = playdate
local Graphics  <const> = pd.graphics

local newImage      <const> = Graphics.image.new
local newImagetable <const> = Graphics.imagetable.new

local r     <const> = roxy
local Cache <const> = r.Cache

local getCachedAsset    <const> = Cache.getCachedAsset
local cacheAsset        <const> = Cache.cacheAsset
local evictAsset        <const> = Cache.evictAsset
local getIsAssetCached  <const> = Cache.getIsAssetCached

-- Shared reference counts for the entire runtime
local referenceCount = {}

-- ! Retain Asset
function AssetStore.retain(path, assetOrThunk)
  referenceCount[path] = (referenceCount[path] or 0) + 1

  if not getIsAssetCached(path) then
    if type(assetOrThunk) == "function" then
      -- Store the thunk so the asset is created on first use
      cacheAsset(path, assetOrThunk)
    else
      -- Store a thunk that returns the concrete asset value
      local value = assetOrThunk
      cacheAsset(path, function() return value end)
    end
  end
end

-- ! Release Asset
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

-- Get Imagetable
function AssetStore.getImagetable(path)
  if type(path) ~= "string" or path == "" then
    Log.warn("[AssetStore.getImagetable] Invalid or missing path: " .. tostring(path)) --#DEBUG
    return nil
  end

  local cached = getCachedAsset(path)
  if cached then
    -- Realize thunk if needed
    return (type(cached) == "function") and cached() or cached
  end

  local loaded = newImagetable(path)
  if loaded then
    cacheAsset(path, function() return loaded end)
  else
    Log.warn("[AssetStore.getImagetable] Failed to load imagetable: " .. path) --#DEBUG
  end

  return loaded
end

-- Get Image (cached)
function AssetStore.getImageCached(path)
  if type(path) ~= "string" or path == "" then
    Log.warn("[AssetStore.getImageCached] Invalid or missing path: " .. tostring(path)) --#DEBUG
    return nil
  end

  local cached = getCachedAsset(path)
  if cached then
    -- Realize thunk if needed.
    return (type(cached) == "function") and cached() or cached
  end

  local loaded = newImage(path)
  if loaded then
    cacheAsset(path, function() return loaded end)
  else
    Log.warn("[AssetStore.getImageCached] Failed to load image: " .. path) --#DEBUG
  end

  return loaded
end
