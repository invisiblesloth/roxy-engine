-- core/modules/Sounds.lua

roxy = roxy or {}
roxy.Sounds = roxy.Sounds or {}
local Sounds <const> = roxy.Sounds

local pd <const> = playdate

local Cache <const> = roxy.Cache

local clamp <const> = roxy.Math.clamp
local max   <const> = math.max

local newSamplePlayer <const> = pd.sound.sampleplayer.new

local cacheAsset      <const> = Cache.cacheAsset
local getCachedAsset  <const> = Cache.getCachedAsset
local evictAsset      <const> = Cache.evictAsset

local VOLUME_DEFAULT    <const> = 1.0
local DURATION_DEFAULT  <const> = 0.25  -- Seconds (short, SFX‑friendly)
local DURATION_MAX      <const> = 10    -- Fade sanity cap

-- @type table<string,{path:string,tag:string?}>
local soundsRegistry = {}

local players        = {}
local soundKeys      = setmetatable({}, { __mode = "k" })
local rememberedVols = {}
local isMutedGlobal  = false

-- ----------------------------------------
-- Helpers
-- ----------------------------------------

-- ! Get Entry
local function getEntry(name)
  return soundsRegistry[name]
end

-- ! Get Player
local function getPlayer(name)
  local cacheKey = "sound:" .. name

  -- Fast path: both a player *and* its cache entry exist
  local player = players[name]
  if player and getCachedAsset(cacheKey) then
    return player
  end

  -- If we get here, either the player is missing or its cache record
  -- was evicted by the LRU. Clear the stale pointer so we don’t use it.
  players[name] = nil

  -- Slow path: load (or re‑load) from disk
  local entry = soundsRegistry[name]
  if not (entry and entry.path) then
    Log.warn("[getPlayer] Sounds: no entry for '" .. tostring(name) .. "'") --#DEBUG
    return nil
  end

  player = getCachedAsset(cacheKey)
  if not player then
    player = newSamplePlayer(entry.path)
    if not player then
      Log.warn("[getPlayer] Sounds: failed to load '" .. name .. "' at '" .. entry.path .. "'")
      return nil
    end
    cacheAsset(cacheKey, function() return player end)
    -- Weak‑key tracking: key = player | value = cacheKey
    soundKeys[player] = cacheKey
  end

  local volume = rememberedVols[name] or VOLUME_DEFAULT
  rememberedVols[name] = volume -- record before applying mute
  player:setVolume(isMutedGlobal and 0 or volume)

  players[name] = player
  return player
end

-- ! Fade
local function fade(player, fromVolume, toVolume, seconds, callback)
  seconds = clamp(seconds or DURATION_DEFAULT, 0, DURATION_MAX)
  player:setVolume(fromVolume)
  if seconds > 0 then
    player:setVolume(fromVolume, toVolume, seconds, callback)
  else
    player:setVolume(toVolume)
    if callback then callback(player) end
  end
end

-- ! For Each Tag
local function forEachTag(tag, fn)
  for name, entry in pairs(soundsRegistry) do
    if entry.tag == tag then fn(name) end
  end
end

-- ! Mute Global
local function muteGlobal(muted, seconds, callback)
  isMutedGlobal = muted
  for name, player in pairs(players) do
    local targetVolume = muted and 0 or (rememberedVols[name] or VOLUME_DEFAULT)
    fade(player, player:getVolume(), targetVolume, seconds, callback)
  end
end

-- ----------------------------------------
-- Registration & (Pre)Loading
-- ----------------------------------------

-- ! Register Sounds
-- Register many sounds: { name = "path", name2 = {path="…", tag="…"} }
function Sounds.registerSounds(sounds)
  for name, sound in pairs(sounds) do
    if type(sound) == "string" then
      soundsRegistry[name] = { path = sound }
    elseif type(sound) == "table" and type(sound.path) == "string" then
      soundsRegistry[name] = sound
    else --#DEBUG
      Log.warn("[Sounds.registerSounds] invalid entry for '" .. tostring(name) .. "'") --#DEBUG
    end
  end
end

-- ! Preload Sound
-- Pre‑load one sound so first playback has no I/O stutter
function Sounds.load(name)
  getPlayer(name)
end

-- ! Load All
-- Preload all registered sounds
function Sounds.loadAll()
  for name in pairs(soundsRegistry) do
    Sounds.load(name)
  end
end

-- ! Unload
-- Remove a single sound from memory (does not touch registry entry)
function Sounds.unload(name)
  local cacheKey = "sound:" .. name
  local player = players[name]

  if player and soundKeys[player] then
    evictAsset(cacheKey) -- Drop from cache
    soundKeys[player] = nil -- Remove weak‑table entry
  end

  players[name], rememberedVols[name] = nil, nil
end

-- ! Unload All
-- Stop everything, evict every cached sample, and reset bookkeeping.
function Sounds.unloadAll()
  Sounds.stopAll() -- Ensure nothing keeps playing
  for player, cacheKey in pairs(soundKeys) do
    evictAsset(cacheKey) -- Remove from LRU cache
  end
  soundKeys = setmetatable({}, { __mode = "k" })
  players = {}
  rememberedVols = {}
end

-- ! Refill Cache
function Sounds.refillCache()
  local allLoaded = true
  for name in pairs(soundsRegistry) do
    if not getPlayer(name) then -- Silently reloads if needed
      Log.warn("[Sounds.refillCache] failed to load '" .. name .. "'") --#DEBUG
      allLoaded = false
    end
  end
  return allLoaded
end

-- ----------------------------------------
-- Core Controls
-- ----------------------------------------

-- ! Play Sound
-- repeatCount: nil --> 1, 0 --> loop forever, > 0 --> that many times, < 0 --> 1
-- rate:        nil --> 1, else your multiplier
function Sounds.play(name, repeatCount, rate)
  if isMutedGlobal then return end

  local player = getPlayer(name)
  if not player then return end

  -- Default to one shot
  if repeatCount == nil then
    repeatCount = 1
  -- Negative is invalid --> treat like a single play
  elseif repeatCount < 0 then
    repeatCount = 1
  end

  player:play(repeatCount, rate or 1)
end

-- ! Stop
function Sounds.stop(name)
  local player = players[name]
  if player then
    player:stop()
  end
end

-- ! Stop All
function Sounds.stopAll()
  for _, player in pairs(players) do
    player:stop()
  end
end

-- ----------------------------------------
-- Volume / Fade
-- ----------------------------------------

-- ! Set Volume
function Sounds.setVolume(name, volume)
  local player = getPlayer(name); if not player then return end

  volume = clamp(volume or VOLUME_DEFAULT, 0, 1)
  rememberedVols[name] = volume

  if not isMutedGlobal then
    player:setVolume(volume)
  end
end

-- ! Fade Volume
-- Fade volume of a specific sound
function Sounds.fadeVolume(name, toVolume, seconds, callback)
  local player = players[name]; if not player then return end
  fade(player, player:getVolume(), clamp(toVolume, 0, 1), seconds, callback)
  rememberedVols[name] = toVolume
end

-- ----------------------------------------
-- Tags
-- ----------------------------------------

-- ! Set Tag
-- Assign a tag to a sound for grouping
function Sounds.setTag(name, tag)
  local entry = soundsRegistry[name]
  if entry then
    entry.tag = tag
  end
end

-- ----------------------------------------
-- Mute / Unmute
-- ----------------------------------------

-- ! Mute Tag
function Sounds.muteTag(tag, seconds, callback)
  forEachTag(tag, function(name)
    local player = players[name]; if player then fade(player, player:getVolume(), 0, seconds, callback) end
  end)
end

-- ! Unmute Tag
function Sounds.unmuteTag(tag, seconds)
  forEachTag(tag, function(name)
    local player = players[name]
    local targetVolume = rememberedVols[name] or VOLUME_DEFAULT
    if player then fade(player, player:getVolume(), targetVolume, seconds) end
  end)
end

-- ! Mute All
function Sounds.muteAll(seconds, callback)
  muteGlobal(true, seconds, callback)
end

-- ! Unmute All
function Sounds.unmuteAll(seconds)
  muteGlobal(false, seconds)
end

-- ----------------------------------------
-- Getters
-- ----------------------------------------

-- ! Get isPlaying
function Sounds.isPlaying(name)
  local player = players[name]
  return player and player:isPlaying() or false
end

-- ! Get isMuted
function Sounds.isMuted( )
  return isMutedGlobal
end

-- ! Get volume of a specific sound
function Sounds.getVolume(name)
  local player = players[name]

  -- Real‑time value
  if player then
    return player:getVolume()
  end

  return rememberedVols[name] -- May be nil
end
