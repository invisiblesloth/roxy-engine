-- core/modules/AssetPoolRegistry.lua

-- Tracks asset pool ownership with weak keys and wraps pool registration
-- Pool keys must be non-empty strings without leading or trailing whitespace

roxy = roxy or {}
roxy.AssetPoolRegistry = roxy.AssetPoolRegistry or {}
local Registry <const> = roxy.AssetPoolRegistry

-- Imported by Assets.lua after asset pool functions exist, so these aliases
-- intentionally capture the current Assets table and methods
local r       <const> = roxy
local Assets  <const> = r.Assets

local stringFormat <const> = string.format --#DEBUG

local getIsPoolRegistered <const> = Assets.getIsPoolRegistered
local registerPool        <const> = Assets.registerPool

-- Weak-key map to remember pooled ownership by origin pool key
-- Value: string pool key (owned)
local poolTag = setmetatable({}, { __mode = "k" })

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

-- ! Mark From Pool
-- Tags an asset as originating from a pool using weak-reference tracking
--  @param asset Asset instance to tag (any type)
--  @param key   Pool key (non-empty string, no leading/trailing whitespace)
--
--  @return The asset instance (for chaining)

function Registry.markFromPool(asset, key)
  if not asset then return asset end

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
  return asset and type(poolTag[asset]) == "string" or false
end

-- ! Get Pool Key
-- Returns the owned pool key for an asset (if available)
--  @param asset Asset instance to check (any type)
--
--  @return String pool key or nil if untagged

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

--------------------------------------------------------------------------------
-- Internal API (pre-validated fast paths)
--------------------------------------------------------------------------------
--
-- Used only by roxy.Assets. External code should use the public API above.
--

-- ! Mark From Pool Direct
-- Fast-path pool tagging. Skips all validation.
-- Caller contract: asset ~= nil, key is a validated non-empty string.
--  @param asset Asset instance to tag
--  @param key   Validated pool key string
--
--  @return The asset instance

function Registry.markFromPoolDirect(asset, key)
  --#DEBUG START
  if type(key) ~= "string" then
    Log.warn("[AssetPoolRegistry.markFromPoolDirect] invalid pool key: " .. _formatPoolKeyValue(key))
    return asset
  end
  --#DEBUG END

  poolTag[asset] = key
  return asset
end

-- ! Get Origin Key
-- Single-lookup ownership query. Replaces isFromPool + getPoolKey sequence.
--  @param asset Asset instance to check
--
--  @return originKey, isPooled (two values)
--    (string, true)  - asset is owned by the named pool
--    (nil,    false) - asset is not tagged at all

function Registry.getOriginKey(asset)
  local tag = poolTag[asset]
  if type(tag) == "string" then return tag, true end
  return nil, false
end

-- ! Clear From Pool Direct
-- Fast-path tag removal. Skips nil-asset guard.
-- Caller contract: asset ~= nil
--  @param asset Asset instance to untag

function Registry.clearFromPoolDirect(asset)
  poolTag[asset] = nil
end

--------------------------------------------------------------------------------
-- Pool Registration API
--------------------------------------------------------------------------------

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
-- Convenience wrapper for path-based asset pools (images, sounds, and similar)
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

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

AssetPoolRegistry wraps pool registration and tracks asset ownership.

local Registry <const> = roxy.AssetPoolRegistry
local Assets   <const> = roxy.Assets

-- Register or Ensure a Pool
Registry.ensurePool("particles/smoke", 2, function()
  return playdate.graphics.image.new("images/particle-smoke")
end, {
  maxSize = 6,
  growthFactor = 2,
})

local smoke = Assets.getAsset("particles/smoke")
if Registry.isFromPool(smoke) then
  Assets.recycleAsset(Registry.getPoolKey(smoke), smoke)
end

-- Path-Based Pool
Registry.ensureForPath(
  "ui/button",
  "images/ui-button",
  playdate.graphics.image.new,
  {
    initialCount = 1,
    maxSize = 3,
  }
)

local buttonImage = Assets.getAsset("ui/button")
Assets.recycleAsset("ui/button", buttonImage)

-- Object Pool
local sharedBadge = playdate.graphics.image.new("images/badge")
Registry.ensureForObject("ui/badge", sharedBadge, {
  initialCount = 1,
  maxSize = 1,
})

local badge = Assets.getAsset("ui/badge")
Assets.recycleAsset("ui/badge", badge)

-- Manual Ownership Tags
local previewImage = playdate.graphics.image.new("images/preview")
Registry.markFromPool(previewImage, "manual/preview")

local originKey, isPooled = Registry.getOriginKey(previewImage)
if isPooled then
  Registry.clearFromPool(previewImage)
end

--]]
