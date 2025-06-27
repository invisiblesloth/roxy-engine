-- core/modules/Cache.lua

roxy = roxy or {}
roxy.Cache = roxy.Cache or {}
local Cache <const> = roxy.Cache

local MAX_CACHE_SIZE_DEFAULT <const> = 50

-- ----------------------------------------
-- Internal Functions
-- ----------------------------------------

-- ! New Entry
-- Creates a new cache entry for the given key and asset.
local function newEntry(key, asset)
  return {
    key = key,
    asset = asset,
    prev = nil,
    next = nil
  }
end

-- ! Move to Head
-- Moves an entry to the head, marking it as most recently used.
local function moveToHead(bucket, entry)
  if bucket.head == entry then return end

  if entry.prev then
    entry.prev.next = entry.next
  end
  if entry.next then
    entry.next.prev = entry.prev
  end

  if bucket.tail == entry then
    bucket.tail = entry.prev
  end

  entry.next = bucket.head
  entry.prev = nil
  if bucket.head then
    bucket.head.prev = entry
  end
  bucket.head = entry

  if not bucket.tail then
    bucket.tail = entry
  end
end

-- ! Add to Head
-- Adds a new entry to the head of the linked list.
local function addToHead(bucket, entry)
  entry.next = bucket.head
  entry.prev = nil
  if bucket.head then
    bucket.head.prev = entry
  end
  bucket.head = entry

  if not bucket.tail then
    bucket.tail = entry
  end
  bucket.currentSize += 1
end

-- ! Remove Tail
-- Removes the least recently used entry from the tail.
local function removeTail(bucket)
  local tail = bucket.tail
  if not tail then return end -- Nothing to remove
  bucket.cache[tail.key] = nil
  if tail.prev then
    tail.prev.next = nil
    bucket.tail = tail.prev
  else
    bucket.head = nil
    bucket.tail = nil
  end
  bucket.currentSize -= 1
end

-- ----------------------------------
-- ! Bucket Constructor
-- ----------------------------------

-- ! New Bucket
-- Creates a new cache bucket with specified max size.
function Cache.newBucket(maxSize)
  return {
    cache        = {},  -- Key to entry mapping
    head         = nil, -- Most recently used
    tail         = nil, -- Least recently used
    currentSize  = 0,
    maxCacheSize = maxSize or MAX_CACHE_SIZE_DEFAULT,
  }
end

local DEFAULT_BUCKET = Cache.newBucket()

-- ! Resolve Bucket
-- Resolves the bucket, defaulting if omitted.
local function resolveBucket(firstArg, ...)
  if type(firstArg) == "table" and firstArg.cache then
    return firstArg, ...
  end
  return DEFAULT_BUCKET, firstArg, ...
end

-- ----------------------------------
-- ! Public API
-- ----------------------------------

-- ! Set Max Cache Size
-- Sets the maximum cache size and evicts entries if necessary.
function Cache.setMaxCacheSize(bucketOrSize, maybeSize)
  local bucket, newSize = resolveBucket(bucketOrSize, maybeSize)

  newSize = newSize or bucket.maxCacheSize or MAX_CACHE_SIZE_DEFAULT

  --#DEBUG START
  if newSize < 0 then
    warn("[W][Cache.setMaxCacheSize] Invalid max cache size: " .. tostring(newSize) .. "; using 0")
    newSize = 0
  end
  --#DEBUG END

  bucket.maxCacheSize = newSize

  print("[i][Cache.setMaxCacheSize] Cache max size set to " .. tostring(newSize)) --#DEBUG

  if newSize == 0 and bucket.currentSize > 0 then
    bucket.cache = {}
    bucket.head = nil
    bucket.tail = nil
    bucket.currentSize = 0
  else
    while bucket.currentSize > bucket.maxCacheSize do
      removeTail(bucket)
    end
  end

  return true
end

-- ! Cache Asset
-- Adds an asset to the cache using the provided loader function.
function Cache.cacheAsset(bucketOrKey, keyOrLoader, maybeLoader)
  local bucket, key, loaderFn = resolveBucket(bucketOrKey, keyOrLoader, maybeLoader)

  --#DEBUG START
  if type(key) ~= "string" and type(key) ~= "number" then
    warn("[W][Cache.cacheAsset] Expected string or number for key, got " .. type(key))
    return false
  end
  --#DEBUG END

  if type(loaderFn) ~= "function" then
    warn("[W][Cache.cacheAsset] loaderFunction is not callable for key '" .. tostring(key) .. "'.") --#DEBUG
    return false
  end
  if bucket.cache[key] then
    warn("[W][Cache.cacheAsset] Asset with key '" .. tostring(key) .. "' already cached.") --#DEBUG
    return false
  end

  local asset = loaderFn()
  if not asset then
    warn("[W][Cache.cacheAsset] loaderFunction failed for key '" .. tostring(key) .. "'.") --#DEBUG
    return false
  end

  local entry = newEntry(key, asset)
  bucket.cache[key] = entry
  addToHead(bucket, entry)

  if bucket.currentSize > bucket.maxCacheSize then
    removeTail(bucket)
  end

  return true
end

-- ! Get Cached Asset
-- Retrieves an asset from the cache, updating it to MRU status.
function Cache.getCachedAsset(bucketOrKey, maybeKey)
  local bucket, key = resolveBucket(bucketOrKey, maybeKey)

  --#DEBUG START
  if type(key) ~= "string" and type(key) ~= "number" then
    warn("[W][Cache.getCachedAsset] Expected string or number for key, got " .. type(key))
    return nil
  end
  --#DEBUG END

  local entry = bucket.cache[key]
  if not entry then
    warn("[W][Cache.getCachedAsset] Asset with key '" .. tostring(key) .. "' not cached.") --#DEBUG
    return nil
  end

  moveToHead(bucket, entry)
  return entry.asset
end

-- ! Get or Load Asset
-- Gets or loads an asset, caching it if necessary.
function Cache.getOrLoadAsset(bucketOrKey, keyOrLoader, maybeLoader)
  local bucket, key, loaderFn = resolveBucket(bucketOrKey, keyOrLoader, maybeLoader)

  --#DEBUG START
  if type(key) ~= "string" and type(key) ~= "number" then
    warn("[W][Cache.getOrLoadAsset] Expected string or number for key, got " .. type(key))
    return nil
  end
  --#DEBUG END

  local entry = bucket.cache[key]
  if entry then
    moveToHead(bucket, entry)
    return entry.asset
  else
    if type(loaderFn) ~= "function" then
      warn("[W][Cache.getOrLoadAsset] loaderFunction is not callable for key '" .. tostring(key) .. "'.") --#DEBUG
      return nil
    end
    local asset = loaderFn()
    if not asset then
      warn("[W][Cache.getOrLoadAsset] loaderFunction failed for key '" .. tostring(key) .. "'.") --#DEBUG
      return nil
    end

    local entry = newEntry(key, asset)
    bucket.cache[key] = entry
    addToHead(bucket, entry)
    if bucket.currentSize > bucket.maxCacheSize then
      removeTail(bucket)
    end

    return asset
  end
end

-- ! Get Is Asset Cached
-- Checks if an asset is cached for the given key.
function Cache.getIsAssetCached(bucketOrKey, maybeKey)
  local bucket, key = resolveBucket(bucketOrKey, maybeKey)
  return bucket.cache[key] ~= nil
end

-- ! Evict Asset
-- Removes a specific asset from the cache.
function Cache.evictAsset(bucketOrKey, maybeKey)
  local bucket, key = resolveBucket(bucketOrKey, maybeKey)

  --#DEBUG START
  if type(key) ~= "string" and type(key) ~= "number" then
    warn("[W][Cache.evictAsset] Expected string or number for key, got " .. type(key))
    return false
  end
  --#DEBUG END

  local entry = bucket.cache[key]

  if not entry then
    warn("[W][Cache.evictAsset] Attempted to evict non-existent asset '" .. tostring(key) .. "'.") --#DEBUG
    return false
  end

  if entry.prev then
    entry.prev.next = entry.next
  end
  if entry.next then
    entry.next.prev = entry.prev
  end

  if bucket.head == entry then
    bucket.head = entry.next
  end
  if bucket.tail == entry then
    bucket.tail = entry.prev
  end

  bucket.cache[key] = nil
  bucket.currentSize -= 1

  return true
end

-- ! Clear Cache
-- Clears all entries from the cache.
function Cache.clearCache(bucket)
  bucket = bucket or DEFAULT_BUCKET
  bucket.cache = {}
  bucket.head = nil
  bucket.tail = nil
  bucket.currentSize = 0
  return true
end
