-- core/modules/Assets.lua

roxy = roxy or {}
roxy.Assets = roxy.Assets or {}
local Assets <const> = roxy.Assets

local min <const> = math.min

local pools = {}

-- ! Register Pool
function Assets.registerPool(key, initialCount, loaderFunction, options)
  if type(loaderFunction) ~= "function" then
    Log.warn("[Assets.registerPool] loaderFunction is not callable for key '" .. tostring(key) .. "'. Expected a function.") --#DEBUG
    return false
  end

  if pools[key] then
    Log.warn("[Assets.registerPool] Pool for key '" .. tostring(key) .. "' is already registered.") --#DEBUG
    return false
  end

  local pool = {
    assets = {},
    loader = loaderFunction,
    availableCount = 0,
    totalSize = 0,
    initialCount = initialCount or 1,
    maxSize = (options and options.maxSize) or ((initialCount or 1) * 2),
    growthFactor = (options and options.growthFactor) or 1,
  }

  if pool.initialCount > pool.maxSize then
    Log.warn("[Assets.registerPool] initialCount (" .. pool.initialCount .. ") exceeds maxSize (" .. pool.maxSize .. ") for pool '" .. tostring(key) .. "'. Clamping to maxSize.") --#DEBUG
    pool.initialCount = pool.maxSize
  end

  local assets = pool.assets
  local loader = pool.loader
  for i = 1, pool.initialCount do
    local newAsset = loader()
    if newAsset then
      assets[#assets + 1] = newAsset
      pool.availableCount += 1
      pool.totalSize += 1
    else --#DEBUG
      Log.warn("[Assets.registerPool] Loader function returned nil when registering pool '" .. tostring(key) .. "'.") --#DEBUG
    end
  end

  pools[key] = pool

  Log.info("Asset pool '" .. tostring(key) .. "' registered with " .. tostring(pool.initialCount) .. " assets.") --#DEBUG

  return true
end

-- ! Get Asset
function Assets.getAsset(key)
  local pool = pools[key]
  if not pool then
    Log.warn("[Assets.getAsset] Attempted to get asset from unregistered pool: " .. tostring(key)) --#DEBUG
    return nil
  end

  local assets = pool.assets
  if pool.availableCount > 0 then
    local i = #assets
    local asset = assets[i]
    assets[i] = nil

    pool.availableCount -= 1
    return asset
  else
    if pool.totalSize < pool.maxSize then
      local needed = min(pool.growthFactor, pool.maxSize - pool.totalSize)
      local loader = pool.loader
      for i = 1, needed do
        local newAsset = loader()
        if newAsset then
          assets[#assets + 1] = newAsset
          pool.availableCount += 1
          pool.totalSize += 1
        else --#DEBUG
          Log.warn("[Assets.getAsset] Loader returned nil while growing pool '" .. tostring(key) .. "'.") --#DEBUG
        end
      end

      if pool.availableCount > 0 then
        local i = #assets
        local asset = assets[i]
        assets[i] = nil

        pool.availableCount -= 1
        return asset
      else
        Log.warn("[Assets.getAsset] Pool '" .. tostring(key) .. "' is empty after attempting to grow.") --#DEBUG
        return nil
      end
    else
      Log.warn("[Assets.getAsset] Pool '" .. tostring(key) .. "' is empty and at max capacity (" .. tostring(pool.maxSize) .. ").") --#DEBUG
      return nil
    end
  end
end

-- ! Recycle Asset
function Assets.recycleAsset(key, asset)
  local pool = pools[key]
  if not pool then
    Log.warn("[Assets.recycleAsset] Attempted to recycle asset to unregistered pool: " .. tostring(key)) --#DEBUG
    return false
  end

  if not asset then
    Log.warn("[Assets.recycleAsset] Attempted to recycle a nil asset to pool: " .. tostring(key)) --#DEBUG
    return false
  end

  local assets = pool.assets
  assets[#assets + 1] = asset
  pool.availableCount += 1
  return true
end

-- ! Get Is Pool Registered
function Assets.getIsPoolRegistered(key)
  return pools[key] ~= nil
end

-- Load the Asset Pool Registry helper
import "libraries/roxy/core/modules/AssetPoolRegistry"
