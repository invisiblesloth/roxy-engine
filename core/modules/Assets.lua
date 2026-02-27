-- core/modules/Assets.lua

--------------------------------------------------------------------------------
-- Assets - Roxy Asset Pool Management System
--------------------------------------------------------------------------------
--
-- Provides object pooling for efficient reuse of expensive game assets like
-- sprites, images, and other resources. Reduces garbage collection pressure
-- and improves performance by pre-allocating and recycling objects.
--
-- Key Features:
--  - Dynamic pool registration with custom loader functions
--  - Automatic pool growth up to configurable max size
--  - Configurable initial size, max size, and growth factor
--  - Asset recycling to minimize allocations
--  - Pool availability and capacity tracking
--  - Integration with AssetPoolRegistry for declarative setup
--
-- Usage Pattern:
--  1. Register pool with Assets.registerPool(key, count, loader, options)
--  2. Acquire asset with Assets.getAsset(key)
--  3. Use asset in game logic
--  4. Return asset with Assets.recycleAsset(key, asset)
--
-- Pool Key Contract:
--  - key must be a non-empty string
--  - key cannot have leading/trailing whitespace
--
--------------------------------------------------------------------------------

roxy = roxy or {}
roxy.Assets = roxy.Assets or {}
local Assets <const> = roxy.Assets

--------------------------------------------------------------------------------
-- Standard Lua Function Aliases
--------------------------------------------------------------------------------

-- Math functions
local min <const> = math.min

-- String functions
local stringFormat <const> = string.format

--------------------------------------------------------------------------------
-- Local State Variables
--------------------------------------------------------------------------------

-- Asset pool registry (indexed by pool key)
local pools = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function _formatPoolKeyValue(key)
  return stringFormat("%q", tostring(key))
end

local function _isValidPoolKey(key)
  if type(key) ~= "string" then return false end
  if not key:match("%S") then return false end
  if key:match("^%s") or key:match("%s$") then return false end
  return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Register Pool
-- Registers a new asset pool with initial allocation and growth configuration
--  @param key            Non-empty string key (no leading/trailing whitespace)
--  @param initialCount   Number of assets to pre-allocate (default 1)
--  @param loaderFunction Function that creates and returns a new asset instance
--  @param options        Optional table with maxSize and growthFactor fields
--
--  @return Boolean true if registration succeeded, false on invalid key/duplicate/invalid loader

function Assets.registerPool(key, initialCount, loaderFunction, options)
  if not _isValidPoolKey(key) then
    Log.warn("[Assets.registerPool] invalid pool key: " .. _formatPoolKeyValue(key)) --#DEBUG
    return false
  end

  if type(loaderFunction) ~= "function" then
    Log.warn("[Assets.registerPool] loaderFunction is not callable for key '" .. tostring(key) .. "'. Expected a function.") --#DEBUG
    return false
  end

  if pools[key] then
    Log.warn("[Assets.registerPool] Pool for key '" .. tostring(key) .. "' is already registered.") --#DEBUG
    return false
  end

  local initialCountValue = tonumber(initialCount) or 1
  local maxSizeValue = options and tonumber(options.maxSize) or nil
  local growthFactorValue = options and tonumber(options.growthFactor) or 1

  if initialCountValue < 0 then
    Log.warn("[Assets.registerPool] initialCount (" .. tostring(initialCountValue) .. ") must be >= 0 for pool '" .. tostring(key) .. "'. Clamping to 0.") --#DEBUG
    initialCountValue = 0
  end

  if maxSizeValue == nil then
    maxSizeValue = initialCountValue * 2
  end
  if maxSizeValue < 1 then
    Log.warn("[Assets.registerPool] maxSize (" .. tostring(maxSizeValue) .. ") must be >= 1 for pool '" .. tostring(key) .. "'. Clamping to 1.") --#DEBUG
    maxSizeValue = 1
  end

  if growthFactorValue < 1 then
    Log.warn("[Assets.registerPool] growthFactor (" .. tostring(growthFactorValue) .. ") must be >= 1 for pool '" .. tostring(key) .. "'. Clamping to 1.") --#DEBUG
    growthFactorValue = 1
  end

  -- Create pool metadata structure
  local pool = {
    assets = {},                -- Array of available assets
    loader = loaderFunction,    -- Factory function for new assets
    availableCount = 0,         -- Number of assets currently available
    totalSize = 0,              -- Total allocated assets (in-use + available)
    initialCount = initialCountValue,
    maxSize = maxSizeValue,
    growthFactor = growthFactorValue,
  }

  -- Validate and clamp initialCount
  if pool.initialCount > pool.maxSize then
    Log.warn("[Assets.registerPool] initialCount (" .. pool.initialCount .. ") exceeds maxSize (" .. pool.maxSize .. ") for pool '" .. tostring(key) .. "'. Clamping to maxSize.") --#DEBUG
    pool.initialCount = pool.maxSize
  end

  -- Pre-allocate initial assets
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
-- Retrieves an available asset from the pool, growing the pool if needed
--  @param key Non-empty string key for the pool (no leading/trailing whitespace)
--
--  @return Asset instance if available, nil if key invalid/pool exhausted/unregistered

function Assets.getAsset(key)
  if not _isValidPoolKey(key) then
    Log.warn("[Assets.getAsset] invalid pool key: " .. _formatPoolKeyValue(key)) --#DEBUG
    return nil
  end

  local pool = pools[key]
  if not pool then
    Log.warn("[Assets.getAsset] Attempted to get asset from unregistered pool: " .. tostring(key)) --#DEBUG
    return nil
  end

  local assets = pool.assets

  -- Fast path: return available asset from pool
  if pool.availableCount > 0 then
    local i = #assets
    local asset = assets[i]
    assets[i] = nil

    pool.availableCount -= 1
    return roxy.AssetPoolRegistry.markFromPool(asset, key)
  else
    -- Pool exhausted, attempt to grow if under max capacity
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

      -- Retry retrieval after growth
      if pool.availableCount > 0 then
        local i = #assets
        local asset = assets[i]
        assets[i] = nil

        pool.availableCount -= 1
        return roxy.AssetPoolRegistry.markFromPool(asset, key)
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
-- Returns an asset to the pool for reuse
--  @param key   Non-empty string key for the pool (no leading/trailing whitespace)
--  @param asset Asset instance to return to the pool
--
--  @return Boolean true if recycled successfully, false on invalid key/reject conditions

function Assets.recycleAsset(key, asset)
  if not _isValidPoolKey(key) then
    Log.warn("[Assets.recycleAsset] invalid pool key: " .. _formatPoolKeyValue(key)) --#DEBUG
    return false
  end

  local pool = pools[key]
  if not pool then
    Log.warn("[Assets.recycleAsset] Attempted to recycle asset to unregistered pool: " .. tostring(key)) --#DEBUG
    return false
  end

  if not asset then
    Log.warn("[Assets.recycleAsset] Attempted to recycle a nil asset to pool: " .. tostring(key)) --#DEBUG
    return false
  end
  -- Prevent double-recycle and foreign assets from entering the wrong pool.
  if not roxy.AssetPoolRegistry.isFromPool(asset) then
    Log.warn("[Assets.recycleAsset] Attempted to recycle a non-pooled asset to pool: " .. tostring(key)) --#DEBUG
    return false
  end

  local originKey = roxy.AssetPoolRegistry.getPoolKey(asset)
  if originKey ~= key then
    Log.warn("[Assets.recycleAsset] Attempted to recycle asset owned by pool '" .. tostring(originKey) .. "' into pool: " .. tostring(key)) --#DEBUG
    return false
  end

  roxy.AssetPoolRegistry.clearFromPool(asset)

  local assets = pool.assets
  assets[#assets + 1] = asset
  pool.availableCount += 1
  return true
end

-- ! Get Is Pool Registered
-- Checks if a pool with the given key exists
--  @param key Non-empty string key for the pool (no leading/trailing whitespace)
--
--  @return Boolean true if pool is registered, false otherwise

function Assets.getIsPoolRegistered(key)
  return pools[key] ~= nil
end

--------------------------------------------------------------------------------
-- Roxy Framework Imports
--------------------------------------------------------------------------------

-- Asset Pool Registry helper
import "libraries/roxy/core/modules/AssetPoolRegistry"
