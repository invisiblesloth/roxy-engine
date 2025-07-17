-- core/modules/AssetPoolRegistry.lua

roxy = roxy or {}
roxy.AssetPoolRegistry = roxy.AssetPoolRegistry or {}
local Registry <const> = roxy.AssetPoolRegistry

local Assets              <const> = roxy.Assets
local getIsPoolRegistered <const> = Assets.getIsPoolRegistered
local registerPool        <const> = Assets.registerPool

-- Weak-key set to remember “came from pool”
local poolTag = setmetatable({}, { __mode = "k" })  -- Weak keys

-- ! Make From Pool
function Registry.markFromPool(asset)
  if asset then poolTag[asset] = true end
  return asset
end

-- ! Is From Pool
function Registry.isFromPool(asset)
  return asset and poolTag[asset] or false
end

-- ! Register
-- Registers (or ensures) a pool for any asset type.
-- Arguments:
--   key (string)  - Unique identifier for the pool.
--   loader (func) - Function that returns a new asset instance.
--   opts (table)  - (optional) Pool options: initialCount, maxSize, growthFactor, etc.
function Registry.register(key, loader, opts)
  if not getIsPoolRegistered(key) then
    local initial = (opts and opts.initialCount) or 1
    registerPool(key, initial, loader, opts)
  end
  return key
end

-- ! Ensure Pool
-- Returns the pool if it exists, or registers it on-demand.
-- Makes the “first call wins” rule go away.
function Registry.ensurePool(key, initialCount, loaderFn, options)
  if not getIsPoolRegistered(key) then
    registerPool(key, initialCount or 1, loaderFn, options)
  end
  return key
end

-- ! Ensure For Path
-- Sugar: if you have an asset path or single object, this builds a loader for you.
-- Use this for typical cases like images, sounds, etc.
function Registry.ensureForPath(key, assetPath, constructor, opts)
  -- Constructor: a function like playdate.graphics.image.new
  return Registry.register(
    key,
    function() return constructor(assetPath) end,
    opts
  )
end

-- ! Ensure For Object
-- Sugar: if you want to cache a fixed object (rare, but possible).
function Registry.ensureForObject(key, object, opts)
  return Registry.register(
    key,
    function() return object end,
    opts
  )
end
