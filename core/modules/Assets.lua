-- core/modules/Assets.lua

-- Manages reusable asset pools with lazy growth and ownership checks
-- Pool keys must be non-empty strings without leading or trailing whitespace
-- Key-shape checks in getAsset/recycleAsset strip from release; lookups fail soft

roxy = roxy or {}
roxy.Assets = roxy.Assets or {}
local Assets <const> = roxy.Assets

local min <const> = math.min

local stringFormat <const> = string.format --#DEBUG

-- Asset pool registry (indexed by pool key)
local pools = {}
-- Static alias for hot paths. Tradeoff: does not see full table replacement of
-- roxy.AssetPoolRegistry after module load, but does see method monkey-patching
-- on the same table.
local Registry

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--#DEBUG START
local function _formatPoolKeyValue(key)
  return stringFormat("%q", tostring(key))
end
--#DEBUG END

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
-- @param key Non-empty string key with no leading/trailing whitespace
-- @param initialCount Number of assets to pre-allocate, defaults to 1
-- @param loaderFunction Function that creates and returns a new asset instance
-- @param options Optional table with maxSize and positive integer growthFactor fields
-- @return Boolean true if registration succeeded

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
    assets = {},              -- Array of available assets
    loader = loaderFunction,  -- Factory function for new assets
    availableCount = 0,       -- Number of assets currently available
    totalSize = 0,            -- Total allocated assets (in-use + available)
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
-- @param key Non-empty string key with no leading/trailing whitespace
-- @return Asset instance if available, otherwise nil

function Assets.getAsset(key)
  -- Hot path: release builds rely on pool lookup to fail soft
  --#DEBUG START
  if not _isValidPoolKey(key) then
    Log.warn("[Assets.getAsset] invalid pool key: " .. _formatPoolKeyValue(key))
    return nil
  end
  --#DEBUG END

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
    return Registry.markFromPoolDirect(asset, key) -- Internal: key already validated, asset guaranteed non-nil
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
        return Registry.markFromPoolDirect(asset, key) -- Internal: key already validated, asset guaranteed non-nil
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
-- @param key Non-empty string key with no leading/trailing whitespace
-- @param asset Asset instance to return to the pool
-- @return Boolean true if recycled successfully

function Assets.recycleAsset(key, asset)
  -- Hot path: release builds rely on lookup and ownership checks to fail soft
  --#DEBUG START
  if not _isValidPoolKey(key) then
    Log.warn("[Assets.recycleAsset] invalid pool key: " .. _formatPoolKeyValue(key))
    return false
  end
  --#DEBUG END

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
  -- Internal: single-lookup replaces isFromPool + getPoolKey + clearFromPool sequence
  local originKey, isPooled = Registry.getOriginKey(asset)
  if not isPooled or originKey == nil then
    Log.warn("[Assets.recycleAsset] Attempted to recycle a non-pooled asset to pool: " .. tostring(key)) --#DEBUG
    return false
  end

  if originKey ~= key then
    Log.warn("[Assets.recycleAsset] Attempted to recycle asset owned by pool '" .. tostring(originKey) .. "' into pool: " .. tostring(key)) --#DEBUG
    return false
  end

  Registry.clearFromPoolDirect(asset)

  local assets = pool.assets
  assets[#assets + 1] = asset
  pool.availableCount += 1
  return true
end

-- ! Get Is Pool Registered
-- Checks if a pool with the given key exists
-- @param key Pool key to check
-- @return Boolean true if pool is registered

function Assets.getIsPoolRegistered(key)
  return pools[key] ~= nil
end

-- AssetPoolRegistry depends on the asset pool functions above at import time.
import "libraries/roxy/core/modules/AssetPoolRegistry"
Registry = roxy.AssetPoolRegistry

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

Assets provides reusable object pools with lazy growth and ownership checks.

-- Register and Reuse a Pool
Assets.registerPool("particles/smoke", 2, function()
  return playdate.graphics.image.new("images/particle-smoke")
end, {
  maxSize = 6,
  growthFactor = 2,
})

local smokeA = Assets.getAsset("particles/smoke")
local smokeB = Assets.getAsset("particles/smoke")
Assets.recycleAsset("particles/smoke", smokeA)
Assets.recycleAsset("particles/smoke", smokeB)

-- Growth and Exhaustion
Assets.registerPool("enemies/basic", 1, function()
  return playdate.graphics.image.new("images/enemy")
end, {
  maxSize = 2,
  growthFactor = 1,
})

local enemyA = Assets.getAsset("enemies/basic")
local enemyB = Assets.getAsset("enemies/basic") -- Pool grows to maxSize
local enemyC = Assets.getAsset("enemies/basic") -- nil once pool is exhausted

-- Scene Lifecycle
function CombatScene:init()
  if not Assets.getIsPoolRegistered("combat/hit-flash") then
    Assets.registerPool("combat/hit-flash", 2, function()
      return playdate.graphics.image.new("images/hit-flash")
    end, {
      maxSize = 4,
      growthFactor = 1,
    })
  end

  self.hitFlash = Assets.getAsset("combat/hit-flash")
end

function CombatScene:cleanup()
  if self.hitFlash then
    Assets.recycleAsset("combat/hit-flash", self.hitFlash)
    self.hitFlash = nil
  end
end

-- Ownership Safety
local pooledSmoke = Assets.getAsset("particles/smoke")
local recycledWrongPool = Assets.recycleAsset("enemies/basic", pooledSmoke) -- false
local recycledRightPool = Assets.recycleAsset("particles/smoke", pooledSmoke)

--]]
