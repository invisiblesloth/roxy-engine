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
--  - Convenience wrappers for path-based and object-based pools
--  - Integration with roxy.Assets core pooling system
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

--------------------------------------------------------------------------------
-- Local State Variables
--------------------------------------------------------------------------------

-- Weak-key set to remember "came from pool"
local poolTag = setmetatable({}, { __mode = "k" })  -- Weak keys

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Mark From Pool
-- Tags an asset as originating from a pool using weak-reference tracking
--  @param asset Asset instance to tag (any type)
--
--  @return The asset instance (for chaining)

function Registry.markFromPool(asset)
  if asset then poolTag[asset] = true end
  return asset
end

-- ! Is From Pool
-- Checks whether an asset was retrieved from a registered pool
--  @param asset Asset instance to check (any type)
--
--  @return Boolean true if asset came from a pool

function Registry.isFromPool(asset)
  return asset and poolTag[asset] or false
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
--  @param key    Unique identifier string for the pool
--  @param loader Function that returns a new asset instance
--  @param opts   Optional table with pool options (initialCount, maxSize, growthFactor)
--
--  @return The pool key string (for chaining)

function Registry.register(key, loader, opts)
  if not getIsPoolRegistered(key) then
    local initialCount = (opts and opts.initialCount) or 1
    registerPool(key, initialCount, loader, opts)
  end
  return key
end

-- ! Ensure Pool
-- Returns the pool key if it exists, or registers it on-demand
--  @param key          Unique identifier string for the pool
--  @param initialCount Initial number of assets to pre-allocate (defaults to 1)
--  @param loader       Function that returns a new asset instance
--  @param options      Optional table with pool options (maxSize, growthFactor)
--
--  @return The pool key string

function Registry.ensurePool(key, initialCount, loader, options)
  if not getIsPoolRegistered(key) then
    registerPool(key, initialCount or 1, loader, options)
  end
  return key
end

-- ! Ensure For Path
-- Convenience wrapper for path-based asset pools (images, sounds, etc)
--  @param key         Unique identifier string for the pool
--  @param assetPath   File path to the asset resource
--  @param constructor Function that creates the asset (e.g., playdate.graphics.image.new)
--  @param opts        Optional table with pool options (initialCount, maxSize, growthFactor)
--
--  @return The pool key string

function Registry.ensureForPath(key, assetPath, constructor, opts)
  return Registry.register(
    key,
    function() return constructor(assetPath) end,
    opts
  )
end

-- ! Ensure For Object
-- Convenience wrapper for fixed object pools (caches a single object instance)
--  @param key    Unique identifier string for the pool
--  @param object The object instance to cache
--  @param opts   Optional table with pool options (initialCount, maxSize, growthFactor)
--
--  @return The pool key string

function Registry.ensureForObject(key, object, opts)
  return Registry.register(
    key,
    function() return object end,
    opts
  )
end
