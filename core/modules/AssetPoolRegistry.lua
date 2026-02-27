-- core/modules/AssetPoolRegistry.lua

--------------------------------------------------------------------------------
-- AssetPoolRegistry - Asset Pool Registration and Lifecycle Management
--------------------------------------------------------------------------------
--
-- Provides centralized pool registration for Roxy asset types, including
-- tracking mechanisms for identifying pooled assets and ensuring consistent
-- pool initialization across the framework.
--
-- Key Features:
--  - Pool registration with lazy initialization
--  - Weak-reference tagging for pool-sourced assets
--  - Ownership tracking by origin pool key
--  - Convenience wrappers for path-based and object-based pools
--  - Integration with roxy.Assets core pooling system
--
-- Pool Key Contract:
--  - key must be a non-empty string
--  - key cannot have leading/trailing whitespace
--
--------------------------------------------------------------------------------

roxy = roxy or {}
roxy.AssetPoolRegistry = roxy.AssetPoolRegistry or {}
local Registry <const> = roxy.AssetPoolRegistry

--------------------------------------------------------------------------------
-- Roxy Framework Function Aliases
--------------------------------------------------------------------------------

-- Asset functions
local Assets              <const> = roxy.Assets
local getIsPoolRegistered <const> = Assets.getIsPoolRegistered
local registerPool        <const> = Assets.registerPool

-- String functions
local stringFormat        <const> = string.format

--------------------------------------------------------------------------------
-- Local State Variables
--------------------------------------------------------------------------------

-- Weak-key map to remember pooled state and origin pool ownership
-- value: string pool key (owned) | true (legacy pooled tag)
local poolTag = setmetatable({}, { __mode = "k" })

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

-- ! Mark From Pool
-- Tags an asset as originating from a pool using weak-reference tracking
--  @param asset Asset instance to tag (any type)
--  @param key   Optional pool key (non-empty string, no leading/trailing whitespace)
--
--  @return The asset instance (for chaining)

function Registry.markFromPool(asset, key)
  if not asset then return asset end

  local existing = poolTag[asset]

  if key == nil then
    if existing == nil then
      poolTag[asset] = true
    end
    return asset
  end

  if not _isValidPoolKey(key) then
    Log.warn("[AssetPoolRegistry.markFromPool] invalid pool key: " .. _formatPoolKeyValue(key)) --#DEBUG
    return asset
  end

  poolTag[asset] = key
  return asset
end

-- ! Is From Pool
-- Checks whether an asset was retrieved from a registered pool
--  @param asset Asset instance to check (any type)
--
--  @return Boolean true if asset came from a pool

function Registry.isFromPool(asset)
  return asset and poolTag[asset] ~= nil or false
end

-- ! Get Pool Key
-- Returns the owned pool key for an asset (if available)
--  @param asset Asset instance to check (any type)
--
--  @return String pool key or nil if untagged/legacy-tagged

function Registry.getPoolKey(asset)
  if not asset then return nil end

  local tag = poolTag[asset]
  if type(tag) == "string" then
    return tag
  end
  return nil
end

-- ! Clear From Pool
-- Clears the pool tag for an asset (used after recycling)
--  @param asset Asset instance to untag (any type)
--
--  @return The asset instance (for chaining)

function Registry.clearFromPool(asset)
  if asset then poolTag[asset] = nil end
  return asset
end

-- ! Register
-- Registers a pool for any asset type if not already registered
--  @param key    Non-empty string key for the pool (no leading/trailing whitespace)
--  @param loader Function that returns a new asset instance
--  @param opts   Optional table with pool options (initialCount, maxSize, growthFactor)
--
--  @return The pool key string, or nil on invalid key

function Registry.register(key, loader, opts)
  if not _isValidPoolKey(key) then
    Log.warn("[AssetPoolRegistry.register] invalid pool key: " .. _formatPoolKeyValue(key)) --#DEBUG
    return nil
  end

  if not getIsPoolRegistered(key) then
    local initialCount = (opts and opts.initialCount) or 1
    registerPool(key, initialCount, loader, opts)
  end
  return key
end

-- ! Ensure Pool
-- Returns the pool key if it exists, or registers it on-demand
--  @param key          Non-empty string key for the pool (no leading/trailing whitespace)
--  @param initialCount Initial number of assets to pre-allocate (defaults to 1)
--  @param loader       Function that returns a new asset instance
--  @param options      Optional table with pool options (maxSize, growthFactor)
--
--  @return The pool key string, or nil on invalid key

function Registry.ensurePool(key, initialCount, loader, options)
  if not _isValidPoolKey(key) then
    Log.warn("[AssetPoolRegistry.ensurePool] invalid pool key: " .. _formatPoolKeyValue(key)) --#DEBUG
    return nil
  end

  if not getIsPoolRegistered(key) then
    registerPool(key, initialCount or 1, loader, options)
  end
  return key
end

-- ! Ensure For Path
-- Convenience wrapper for path-based asset pools (images, sounds, etc)
--  @param key         Non-empty string key for the pool (no leading/trailing whitespace)
--  @param assetPath   File path to the asset resource
--  @param constructor Function that creates the asset (e.g., playdate.graphics.image.new)
--  @param opts        Optional table with pool options (initialCount, maxSize, growthFactor)
--
--  @return The pool key string, or nil on invalid key

function Registry.ensureForPath(key, assetPath, constructor, opts)
  return Registry.register(
    key,
    function() return constructor(assetPath) end,
    opts
  )
end

-- ! Ensure For Object
-- Convenience wrapper for fixed object pools (caches a single object instance)
--  @param key    Non-empty string key for the pool (no leading/trailing whitespace)
--  @param object The object instance to cache
--  @param opts   Optional table with pool options (initialCount, maxSize, growthFactor)
--
--  @return The pool key string, or nil on invalid key

function Registry.ensureForObject(key, object, opts)
  return Registry.register(
    key,
    function() return object end,
    opts
  )
end
