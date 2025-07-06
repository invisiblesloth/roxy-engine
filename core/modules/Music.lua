-- core/modules/Music.lua

roxy = roxy or {}
roxy.Music = roxy.Music or {}
local Music <const> = roxy.Music

local pd <const> = playdate

local Cache <const> = roxy.Cache

local clamp <const> = roxy.Math.clamp

local newFilePlayer <const> = pd.sound.fileplayer.new

local newBucket       <const> = Cache.newBucket
local cacheAsset      <const> = Cache.cacheAsset
local getCachedAsset  <const> = Cache.getCachedAsset
local evictAsset      <const> = Cache.evictAsset
local setMaxCacheSize <const> = Cache.setMaxCacheSize

local VOLUME_DEFAULT            <const> = 1.0
local DURATION_DEFAULT          <const> = 2   -- Seconds
local DURATION_MAX              <const> = 15  -- Fade sanity cap
local LOOP_FOREVER              <const> = 0
local RATE_DEFAULT              <const> = 1
local OFFSET_DEFAULT            <const> = 0
local MUSIC_CACHE_SIZE_DEFAULT  <const> = 3

local musicCache = newBucket(MAX_MUSIC_CACHE_SIZE)

-- @type table<string,{path:string,title:string?}>
local trackRegistry = {}

local currentPlayer = nil -- Active pd.sound.fileplayer
local musicKeys     = {}  -- { ["music:demo"]=true, ... }
local currentName   = nil
local lastVolume    = VOLUME_DEFAULT
local isMuted       = false

-- ----------------------------------------
-- Helpers
-- ----------------------------------------

-- ! Get Player
-- helper: get (or create & cache) a fileplayer
local function getPlayer(name)
  local entry = trackRegistry[name]
  if not (entry and entry.path) then
    Log.warn("[Music.getPlayer] no entry for '" .. tostring(name) .. "'") --#DEBUG
    return nil
  end

  local cacheKey  = "music:" .. name
  local filePlayer = getCachedAsset(musicCache, cacheKey)

  if not filePlayer then
    filePlayer = newFilePlayer(entry.path)
    if not filePlayer then
      Log.warn("[Music.getPlayer] failed to load track '" .. name .. "' at '" .. entry.path .. "'") --#DEBUG
      return nil
    end
    cacheAsset(musicCache, cacheKey, function() return filePlayer end)
    musicKeys[cacheKey] = true
  end

  return filePlayer
end

-- ! Effective Volume
local function effectiveVolume(volume)
  if volume ~= nil then
    return clamp(volume, 0, 1)
  end
  return isMuted and 0 or lastVolume
end

-- ! Fade
local function fade(filePlayer, fromVolume, toVolume, seconds, callback)
  if not filePlayer then return end
  seconds = clamp(seconds or 0, 0, DURATION_MAX)
  filePlayer:setVolume(fromVolume)
  if seconds > 0 then
    filePlayer:setVolume(fromVolume, toVolume, seconds, callback)
  else
    filePlayer:setVolume(toVolume)
    if callback then callback(filePlayer) end
  end
end

-- ----------------------------------------
-- Registration & (Pre)Loading
-- ----------------------------------------

-- ! Set Music Cache Size
function Music.setCacheSize(size)
  setMaxCacheSize(musicCache, size)
end

-- ! Register Tracks
function Music.registerTracks(tracks)
  for name, entry in pairs(tracks) do
    if type(entry) == "string" then
      trackRegistry[name] = { path = entry }
    elseif type(entry) == "table" and type(entry.path) == "string" then
      trackRegistry[name] = entry
    else
      Log.warn("[Music.registerTracks] invalid entry for '" .. tostring(name) .. "'") --#DEBUG
    end
  end
end

-- ! Preload Track
function Music.load(name)
  getPlayer(name)
end

-- ! Unload Track
function Music.unload(name)
  if not name then return end
  local cacheKey = "music:" .. name
  Music.stop()
  if musicKeys[cacheKey] then
    evictAsset(musicCache, cacheKey)
    musicKeys[cacheKey] = nil
  end
  if currentName == name then
    currentPlayer, currentName = nil, nil
  end
end

-- ! Unload All
function Music.unloadAll()
  Music.stop()
  for key in pairs(musicKeys) do
    evictAsset(musicCache, key)
    musicKeys[key] = nil
  end
  currentPlayer, currentName = nil, nil
end

-- ----------------------------------------
-- Core Controls
-- ----------------------------------------

-- ! Play
function Music.play(name, repeatCount, volume, rate)
  -- Attempt to fetch (and cache) the player
  local filePlayer = getPlayer(name)
  if not filePlayer then
    return false, "Unknown track " .. tostring(name)
  end

  -- If it's a different song, stop the old one
  if currentName and currentName ~= name then
    Music.stop()
  end

  currentPlayer, currentName = filePlayer, name
  filePlayer:setRate(rate or RATE_DEFAULT)
  filePlayer:setVolume(effectiveVolume(volume))
  return filePlayer:play(repeatCount or LOOP_FOREVER)
end

-- ! Stop
function Music.stop()
  if currentPlayer then
    currentPlayer:stop()
  end
end

-- ! Stop and Unload
function Music.stopAndUnload()
  Music.stop()
  if currentName then
    Music.unload(currentName)
  end
end

-- ! Pause
function Music.pause(seconds)
  if not currentPlayer then return end
  seconds = clamp(seconds or 0, 0, DURATION_MAX)
  if seconds > 0 then
    fade(currentPlayer, currentPlayer:getVolume(), 0, seconds, function(filePlayer) filePlayer:pause() end)
  else
    currentPlayer:pause()
    currentPlayer:setVolume(0)
  end
end

-- ! Resume
function Music.resume(seconds, repeatCount)
  if not currentPlayer then return end
  if currentPlayer:isPlaying() then return end

  seconds  = clamp(seconds or 0, 0, DURATION_MAX)
  isMuted   = false
  local vol = effectiveVolume()

  if seconds > 0 then
    currentPlayer:setVolume(0)
    currentPlayer:play(repeatCount or LOOP_FOREVER)
    fade(currentPlayer, 0, vol, seconds)
  else
    currentPlayer:setVolume(vol)
    currentPlayer:play(repeatCount or LOOP_FOREVER)
  end
end

-- ! Restart
function Music.restart(seconds, repeatCount)
  if not currentPlayer then return end
  currentPlayer:stop()
  currentPlayer:setOffset(0)
  Music.resume(seconds, repeatCount)
end

-- ! Loop (Repeat)
function Music.loop(repeatCount)
  if currentPlayer then
    currentPlayer:play(repeatCount or LOOP_FOREVER)
  end
end

-- ----------------------------------------
-- Volume / Rate / Offset
-- ----------------------------------------

-- ! Set Volume
function Music.setVolume(volume)
  lastVolume = clamp(volume or VOLUME_DEFAULT, 0, 1)
  if currentPlayer and not isMuted then
    currentPlayer:setVolume(lastVolume)
  end
end

-- ! Set Rate
function Music.setRate(rate)
  if currentPlayer then
    currentPlayer:setRate(rate or RATE_DEFAULT)
  end
end

-- ! Set Offset
function Music.setOffset(seconds)
  if currentPlayer then
    currentPlayer:setOffset(seconds or OFFSET_DEFAULT)
  end
end

-- ----------------------------------------
-- Fades
-- ----------------------------------------

-- ! Fade In
function Music.fadeIn(name, seconds, repeatCount)
  seconds = clamp(seconds or DURATION_DEFAULT, 0, DURATION_MAX)
  Music.play(name, repeatCount)
  if currentPlayer then
    fade(currentPlayer, 0, effectiveVolume(), seconds)
  end
end

-- ! Fade Out
function Music.fadeOut(seconds)
  if not currentPlayer then return end
  seconds = clamp(seconds or DURATION_DEFAULT, 0, DURATION_MAX)
  fade(currentPlayer, currentPlayer:getVolume(), 0, seconds, function(filePlayer) filePlayer:stop() end)
end

-- ! Fade Out and Unload
function Music.fadeOutAndUnload(seconds)
  if not currentPlayer then return end
  seconds = clamp(seconds or DURATION_DEFAULT, 0, DURATION_MAX)
  fade(currentPlayer, currentPlayer:getVolume(), 0, seconds, function(filePlayer)
    Music.stopAndUnload()
  end)
end

-- ! Cross Fade
function Music.crossFade(newName, seconds, repeatCount)
  seconds = clamp(seconds or DURATION_DEFAULT, 0, DURATION_MAX)
  if currentName == newName then return end

  local incoming = getPlayer(newName)
  if not incoming then return end

  local targetVolume = effectiveVolume()
  incoming:setVolume(0)
  incoming:play(repeatCount or LOOP_FOREVER)

  -- Debug‑only sanity check (does nothing in release)
  local actual = incoming:getVolume(); if actual ~= 0 then Log.warn("[Music.crossFade] volume was " .. actual .. " after play(); expected 0") end --#DEBUG

  fade(incoming, 0, targetVolume, seconds)

  -- Fade out old track, then stop
  if currentPlayer then
    fade(currentPlayer, currentPlayer:getVolume(), 0, seconds, function(filePlayer)
      filePlayer:stop()
    end)
  end

  currentPlayer, currentName = incoming, newName
end

-- ----------------------------------------
-- Mute / Unmute
-- ----------------------------------------

-- ! Mute
function Music.mute(seconds)
  if isMuted or not currentPlayer then return end
  isMuted    = true
  seconds   = clamp(seconds or 0, 0, DURATION_MAX)
  lastVolume = currentPlayer:getVolume()
  fade(currentPlayer, lastVolume, 0, seconds)
end

-- ! Unmute
function Music.unmute(seconds)
  if not isMuted or not currentPlayer then return end
  isMuted  = false
  seconds = clamp(seconds or 0, 0, DURATION_MAX)
  fade(currentPlayer, currentPlayer:getVolume(), lastVolume, seconds)
end

-- ----------------------------------------
-- Loops
-- ----------------------------------------

-- ! Set Loop Range
function Music.setLoopRange(startTime, endTime, callback, arg)
  if currentPlayer then
    currentPlayer:setLoopRange(startTime or 0, endTime, callback, arg)
  end
end

-- ! Set Loop Callback
function Music.setLoopCallback(callback, arg)
  if currentPlayer then
    currentPlayer:setLoopCallback(callback, arg)
  end
end

-- ----------------------------------------
-- Getters
-- ----------------------------------------

-- ! Get isPlaying
function Music.isPlaying()
  return currentPlayer and currentPlayer:isPlaying() or false
end

-- ! Get isMuted
function Music.isMuted()
  return isMuted
end

-- ! Get current track name
function Music.getCurrentName()
  return currentName
end

-- ! Get current track title
function Music.getCurrentTitle()
  local entry = trackRegistry[currentName]
  return (entry and entry.title) or currentName or ""
end

-- ! Get current track volume
function Music.getVolume()
  return currentPlayer and currentPlayer:getVolume() or lastVolume
end
