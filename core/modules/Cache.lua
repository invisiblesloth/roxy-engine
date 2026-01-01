-- core/modules/Cache.lua

--------------------------------------------------------------------------------
-- Cache - LRU Asset Caching with Bucket Support
--------------------------------------------------------------------------------
--
-- Provides a Least-Recently-Used (LRU) caching system for assets with support
-- for multiple isolated cache buckets. Automatically evicts least-used assets
-- when capacity is reached, and tracks access patterns for optimal performance.
--
-- Key Features:
--  - LRU eviction policy with doubly-linked list implementation
--  - Multiple independent cache buckets for namespace isolation
--  - Configurable max size per bucket with dynamic resizing
--  - Automatic cache-miss loading with loader functions
--  - Thread-safe access pattern with MRU promotion
--
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Global Table Initialization
--------------------------------------------------------------------------------

roxy = roxy or {}
roxy.Cache = roxy.Cache or {}
local Cache <const> = roxy.Cache

--------------------------------------------------------------------------------
-- Roxy Framework Function Aliases
--------------------------------------------------------------------------------

local getConfig <const> = roxy.Config.get

--------------------------------------------------------------------------------
-- Module Constants
--------------------------------------------------------------------------------

local MAX_CACHE_SIZE_DEFAULT <const> = 50

--------------------------------------------------------------------------------
-- Local State Variables
--------------------------------------------------------------------------------

-- Default bucket instance for simplified API when bucket parameter is omitted
local defaultBucket

--------------------------------------------------------------------------------
-- Internal Helper Functions
--------------------------------------------------------------------------------

-- ! New Entry
-- Creates a new doubly-linked list entry for cache storage
--  @param key   Cache key (string or number)
--  @param asset Asset instance to cache
--
--  @return Table with key, asset, prev, and next fields

local function _newEntry(key, asset)
  return {
    key = key,
    asset = asset,
    prev = nil,
    next = nil
  }
end

-- ! Move to Head
-- Promotes an existing entry to the head (most-recently-used position)
--  @param bucket Cache bucket containing the entry
--  @param entry  Entry to promote to MRU position

local function _moveToHead(bucket, entry)
  if bucket.head == entry then return end

  -- Unlink from current position
  if entry.prev then
    entry.prev.next = entry.next
  end
  if entry.next then
    entry.next.prev = entry.prev
  end

  -- Update tail if we're moving the tail entry
  if bucket.tail == entry then
    bucket.tail = entry.prev
  end

  -- Insert at head
  entry.next = bucket.head
  entry.prev = nil
  if bucket.head then
    bucket.head.prev = entry
  end
  bucket.head = entry

  -- Update tail if list was empty
  if not bucket.tail then
    bucket.tail = entry
  end
end

-- ! Add to Head
-- Inserts a new entry at the head (most-recently-used position)
--  @param bucket Cache bucket to insert into
--  @param entry  New entry to add at head

local function _addToHead(bucket, entry)
  entry.next = bucket.head
  entry.prev = nil
  if bucket.head then
    bucket.head.prev = entry
  end
  bucket.head = entry

  -- Initialize tail if this is the first entry
  if not bucket.tail then
    bucket.tail = entry
  end
  bucket.currentSize += 1
end

-- ! Remove Tail
-- Evicts the least-recently-used entry from the tail
--  @param bucket Cache bucket to evict from

local function _removeTail(bucket)
  local tail = bucket.tail
  if not tail then return end

  -- Remove from cache table
  bucket.cache[tail.key] = nil

  -- Update linked list pointers
  if tail.prev then
    tail.prev.next = nil
    bucket.tail = tail.prev
  else
    -- List is now empty
    bucket.head = nil
    bucket.tail = nil
  end
  bucket.currentSize -= 1
end

-- ! Resolve Bucket
-- Determines if first argument is a bucket or defaults to global bucket
--  @param firstArg First function argument (bucket or key)
--  @param ...      Remaining arguments
--
--  @return Resolved bucket followed by all original arguments (excluding bucket if provided)

local function resolveBucket(firstArg, ...)
  if type(firstArg) == "table" and firstArg.cache then
    return firstArg, ...
  end
  return defaultBucket, firstArg, ...
end

--------------------------------------------------------------------------------
-- Bucket Constructor
--------------------------------------------------------------------------------

-- ! New Bucket
-- Creates a new isolated cache bucket with LRU eviction
--  @param maxSize Maximum number of entries before LRU eviction (defaults to config or 50)
--
--  @return New bucket table with cache, head, tail, currentSize, and maxCacheSize fields

function Cache.newBucket(maxSize)
  local assetsConfig = getConfig("assets") or {}
  return {
    cache        = {},  -- Key-to-entry mapping table
    head         = nil, -- Most recently used entry
    tail         = nil, -- Least recently used entry
    currentSize  = 0,   -- Current number of cached entries
    maxCacheSize = maxSize or assetsConfig.maxCacheSize or MAX_CACHE_SIZE_DEFAULT,
  }
end

--------------------------------------------------------------------------------
-- Public API - Initialization
--------------------------------------------------------------------------------

-- ! Initialize Cache Module
-- Initializes the default cache bucket for use by the simplified API
--
--  @return None

function Cache.init()
  defaultBucket = Cache.newBucket()
end

--------------------------------------------------------------------------------
-- Public API - Configuration
--------------------------------------------------------------------------------

-- ! Set Max Cache Size
-- Updates the maximum cache capacity and evicts LRU entries if over limit
--  @param bucketOrSize Bucket instance or new size if using default bucket
--  @param maybeSize    New size value when bucket is explicitly provided
--
--  @return Boolean true on success

function Cache.setMaxCacheSize(bucketOrSize, maybeSize)
  local bucket, newSize = resolveBucket(bucketOrSize, maybeSize)

  local assetsConfig = getConfig("assets") or {}
  newSize = newSize or bucket.maxCacheSize or assetsConfig.maxCacheSize or MAX_CACHE_SIZE_DEFAULT

  --#DEBUG START
  if newSize < 0 then
    Log.warn("[Cache.setMaxCacheSize] Invalid max cache size: " .. tostring(newSize) .. "; using 0")
    newSize = 0
  end
  --#DEBUG END

  bucket.maxCacheSize = newSize

  Log.info("Cache max size set to " .. tostring(newSize)) --#DEBUG

  -- Clear entire cache if size is zero
  if newSize == 0 and bucket.currentSize > 0 then
    bucket.cache = {}
    bucket.head = nil
    bucket.tail = nil
    bucket.currentSize = 0
  else
    -- Evict LRU entries until under new limit
    while bucket.currentSize > bucket.maxCacheSize do
      _removeTail(bucket)
    end
  end

  return true
end

--------------------------------------------------------------------------------
-- Public API - Cache Operations
--------------------------------------------------------------------------------

-- ! Cache Asset
-- Loads and caches a new asset using a loader function, fails if key exists
--  @param bucketOrKey   Bucket instance or cache key if using default bucket
--  @param keyOrLoader   Cache key or loader function when bucket provided
--  @param maybeLoader   Loader function when bucket and key are explicitly provided
--
--  @return Boolean true on success, false if key exists or loader fails

function Cache.cacheAsset(bucketOrKey, keyOrLoader, maybeLoader)
  local bucket, key, loaderFunction = resolveBucket(bucketOrKey, keyOrLoader, maybeLoader)

  --#DEBUG START
  if type(key) ~= "string" and type(key) ~= "number" then
    Log.warn("[Cache.cacheAsset] Expected string or number for key, got " .. type(key))
    return false
  end
  --#DEBUG END
  if bucket.maxCacheSize == 0 then
    Log.warn("[Cache.cacheAsset] Cache size is 0; skipping cache for key '" .. tostring(key) .. "'.") --#DEBUG
    return false
  end

  if type(loaderFunction) ~= "function" then
    Log.warn("[Cache.cacheAsset] loaderFunction is not callable for key '" .. tostring(key) .. "'.") --#DEBUG
    return false
  end
  if bucket.cache[key] then
    Log.warn("[Cache.cacheAsset] Asset with key '" .. tostring(key) .. "' already cached.") --#DEBUG
    return false
  end

  local asset = loaderFunction()
  if not asset then
    Log.warn("[Cache.cacheAsset] loaderFunction failed for key '" .. tostring(key) .. "'.") --#DEBUG
    return false
  end

  local entry = _newEntry(key, asset)
  bucket.cache[key] = entry
  _addToHead(bucket, entry)

  -- Evict LRU if over capacity
  if bucket.currentSize > bucket.maxCacheSize then
    _removeTail(bucket)
  end

  return true
end

-- ! Get Cached Asset
-- Retrieves a cached asset and promotes it to most-recently-used position
--  @param bucketOrKey Bucket instance or cache key if using default bucket
--  @param maybeKey    Cache key when bucket is explicitly provided
--
--  @return Asset instance or nil if not found

function Cache.getCachedAsset(bucketOrKey, maybeKey)
  local bucket, key = resolveBucket(bucketOrKey, maybeKey)

  --#DEBUG START
  if type(key) ~= "string" and type(key) ~= "number" then
    Log.warn("[Cache.getCachedAsset] Expected string or number for key, got " .. type(key))
    return nil
  end
  --#DEBUG END

  local entry = bucket.cache[key]
  if not entry then
    -- Log.debug("[Cache.getCachedAsset] Asset with key '" .. tostring(key) .. "' not cached.") --#DEBUG
    return nil
  end

  _moveToHead(bucket, entry)
  return entry.asset
end

-- ! Get Is Asset Cached
-- Tests whether a cache key exists without affecting LRU ordering
--  @param bucketOrKey Bucket instance or cache key if using default bucket
--  @param maybeKey    Cache key when bucket is explicitly provided
--
--  @return Boolean true if key exists in cache

function Cache.getIsAssetCached(bucketOrKey, maybeKey)
  local bucket, key = resolveBucket(bucketOrKey, maybeKey)
  return bucket.cache[key] ~= nil
end

-- ! Get or Load Asset
-- Retrieves cached asset or loads and caches it on cache-miss
--  @param bucketOrKey   Bucket instance or cache key if using default bucket
--  @param keyOrLoader   Cache key or loader function when bucket provided
--  @param maybeLoader   Loader function when bucket and key are explicitly provided
--
--  @return Asset instance or nil if loader fails

function Cache.getOrLoadAsset(bucketOrKey, keyOrLoader, maybeLoader)
  local bucket, key, loaderFunction = resolveBucket(bucketOrKey, keyOrLoader, maybeLoader)

  --#DEBUG START
  if type(key) ~= "string" and type(key) ~= "number" then
    Log.warn("[Cache.getOrLoadAsset] Expected string or number for key, got " .. type(key))
    return nil
  end
  --#DEBUG END
  if bucket.maxCacheSize == 0 then
    if type(loaderFunction) ~= "function" then
      Log.warn("[Cache.getOrLoadAsset] loaderFunction is not callable for key '" .. tostring(key) .. "'.") --#DEBUG
      return nil
    end
    local asset = loaderFunction()
    if not asset then
      Log.warn("[Cache.getOrLoadAsset] loaderFunction failed for key '" .. tostring(key) .. "'.") --#DEBUG
      return nil
    end
    return asset
  end

  -- Cache hit: promote to MRU and return
  local entry = bucket.cache[key]
  if entry then
    _moveToHead(bucket, entry)
    return entry.asset
  end

  -- Cache miss: load and cache
  if type(loaderFunction) ~= "function" then
    Log.warn("[Cache.getOrLoadAsset] loaderFunction is not callable for key '" .. tostring(key) .. "'.") --#DEBUG
    return nil
  end

  local asset = loaderFunction()
  if not asset then
    Log.warn("[Cache.getOrLoadAsset] loaderFunction failed for key '" .. tostring(key) .. "'.") --#DEBUG
    return nil
  end

  entry = _newEntry(key, asset)
  bucket.cache[key] = entry
  _addToHead(bucket, entry)

  -- Evict LRU if over capacity
  if bucket.currentSize > bucket.maxCacheSize then
    _removeTail(bucket)
  end

  return asset
end

-- ! Put Asset
-- Inserts or replaces an asset directly and promotes to most-recently-used
--  @param bucketOrKey Bucket instance or cache key if using default bucket
--  @param keyOrAsset  Cache key or asset instance when bucket provided
--  @param maybeAsset  Asset instance when bucket and key are explicitly provided
--
--  @return Boolean true on success, false if key or asset is invalid

function Cache.putAsset(bucketOrKey, keyOrAsset, maybeAsset)
  local bucket, key, asset = resolveBucket(bucketOrKey, keyOrAsset, maybeAsset)

  --#DEBUG START
  if (type(key) ~= "string" and type(key) ~= "number") then
    Log.warn("[Cache.putAsset] Expected string/number for key, got " .. type(key))
    return false
  end
  if asset == nil then
    Log.warn("[Cache.putAsset] Nil asset for key '" .. tostring(key) .. "'.")
    return false
  end
  --#DEBUG END
  if bucket.maxCacheSize == 0 then
    Log.warn("[Cache.putAsset] Cache size is 0; skipping cache for key '" .. tostring(key) .. "'.") --#DEBUG
    return false
  end

  local entry = bucket.cache[key]
  if entry then
    -- Replace existing asset and promote to MRU
    entry.asset = asset
    _moveToHead(bucket, entry)
  else
    -- Insert new entry at MRU position
    entry = _newEntry(key, asset)
    bucket.cache[key] = entry
    _addToHead(bucket, entry)

    -- Evict LRU if over capacity
    if bucket.currentSize > bucket.maxCacheSize then
      _removeTail(bucket)
    end
  end
  return true
end

-- ! Evict Asset
-- Removes a specific cached asset by key regardless of LRU position
--  @param bucketOrKey Bucket instance or cache key if using default bucket
--  @param maybeKey    Cache key when bucket is explicitly provided
--
--  @return Boolean true on success, false if key does not exist

function Cache.evictAsset(bucketOrKey, maybeKey)
  local bucket, key = resolveBucket(bucketOrKey, maybeKey)

  --#DEBUG START
  if type(key) ~= "string" and type(key) ~= "number" then
    Log.warn("[Cache.evictAsset] Expected string or number for key, got " .. type(key))
    return false
  end
  --#DEBUG END

  local entry = bucket.cache[key]

  if not entry then
    Log.warn("[Cache.evictAsset] Attempted to evict non-existent asset '" .. tostring(key) .. "'.") --#DEBUG
    return false
  end

  -- Unlink from doubly-linked list
  if entry.prev then
    entry.prev.next = entry.next
  end
  if entry.next then
    entry.next.prev = entry.prev
  end

  -- Update head/tail pointers if necessary
  if bucket.head == entry then
    bucket.head = entry.next
  end
  if bucket.tail == entry then
    bucket.tail = entry.prev
  end

  -- Remove from cache table
  bucket.cache[key] = nil
  bucket.currentSize -= 1

  return true
end

-- ! Clear Cache
-- Removes all entries from the cache and resets state
--  @param bucket Bucket instance to clear (defaults to global bucket if omitted)
--
--  @return Boolean true on success

function Cache.clearCache(bucket)
  bucket = bucket or defaultBucket
  bucket.cache = {}
  bucket.head = nil
  bucket.tail = nil
  bucket.currentSize = 0
  return true
end

--------------------------------------------------------------------------------
-- Asset Store Helper Import
--------------------------------------------------------------------------------

-- Load the Asset Store helper
import "libraries/roxy/core/modules/AssetStore"

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

Cache provides LRU asset caching with automatic eviction and bucket support.

-- Basic Caching with Default Bucket
Cache.init()
Cache.cacheAsset("player", function() return playdate.graphics.imagetable.new("images/player") end)
local player = Cache.getCachedAsset("player")
local exists = Cache.getIsAssetCached("player")

-- Get or Load Pattern (cache-miss loads automatically)
local enemy = Cache.getOrLoadAsset("enemy", function()
  return playdate.graphics.imagetable.new("images/enemy")
end)

-- Put Asset Directly (no loader function needed)
local texture = playdate.graphics.image.new("images/texture")
Cache.putAsset("texture", texture)

-- Multiple Buckets (isolated caches)
local menuBucket = Cache.newBucket(20)
local gameBucket = Cache.newBucket(50)

Cache.cacheAsset(menuBucket, "bg", function() return playdate.graphics.image.new("images/menu-bg") end)
Cache.cacheAsset(gameBucket, "bg", function() return playdate.graphics.image.new("images/game-bg") end)

-- Bucket gets its own "bg" asset, isolated from menu

-- Configure Max Size (evicts LRU when over capacity)
Cache.setMaxCacheSize(30)           -- Default bucket
Cache.setMaxCacheSize(menuBucket, 10) -- Specific bucket

-- LRU Eviction (automatic when capacity exceeded)
for i = 1, 60 do
  Cache.cacheAsset("asset" .. i, function() return playdate.graphics.image.new("images/tile") end)
end
-- Oldest assets auto-evicted to maintain maxSize (default 50)

-- Manual Eviction
Cache.evictAsset("player")
local wasEvicted = Cache.getIsAssetCached("player") -- false

-- Clear Entire Cache
Cache.clearCache()              -- Default bucket
Cache.clearCache(menuBucket)    -- Specific bucket

-- Scene Lifecycle Example
function GameScene:init()
  self.cache = Cache.newBucket(100)
  Cache.cacheAsset(self.cache, "tileset", function()
    return playdate.graphics.imagetable.new("images/tiles")
  end)
end

function GameScene:cleanup()
  Cache.clearCache(self.cache)
end

-- Integration with AssetStore
Cache.init()
if not AssetStore.retain("shared", function()
  return Cache.getOrLoadAsset("shared", function()
    return playdate.graphics.image.new("images/shared")
  end)
end) then return end

--]]
