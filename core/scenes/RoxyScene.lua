-- core/scenes/RoxyScene.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
local Input   <const> = r.Input
local Camera  <const> = r.Camera

local tableInsert <const> = table.insert
local tableRemove <const> = table.remove

local clearScreen         <const> = Graphics.clear
local setColor            <const> = Graphics.setColor
local setDrawOffset       <const> = Graphics.setDrawOffset
local setBackgroundColor  <const> = Graphics.setBackgroundColor
local fillRect            <const> = Graphics.fillRect
local setClipRect         <const> = Graphics.setClipRect
local clearClipRect       <const> = Graphics.clearClipRect

local redrawBackground <const> = Sprite.redrawBackground

local addHandler    <const> = Input.addHandler
local pauseHandler  <const> = Input.pause
local resumeHandler <const> = Input.resume
local removeHandler <const> = Input.removeHandler

local resetCamera           <const> = Camera.reset
local setCameraBounds       <const> = Camera.setBounds
local clearCameraBounds     <const> = Camera.clearBounds
local setCameraPosition     <const> = Camera.setPosition
local setCameraTarget       <const> = Camera.setTarget
local setCameraSmoothing    <const> = Camera.setSmoothing
local setCameraPanVelocity  <const> = Camera.setPanVelocity
local setCameraDeadZone     <const> = Camera.setDeadZone
local setCameraFriction     <const> = Camera.setFriction
local setCameraBias         <const> = Camera.setBias
local setCameraMode         <const> = Camera.setMode
local snapshotCameraState   <const> = Camera._snapshotState
local restoreCameraState    <const> = Camera._restoreState

local COLOR_WHITE <const> = Graphics.kColorWhite
local COLOR_BLACK <const> = Graphics.kColorBlack
local CLEAR_COLOR <const> = COLOR_WHITE

local UNFLIPPED <const> = Graphics.kImageUnflipped

local SCENE_PAUSE_NONE        <const> = 0
local SCENE_PAUSE_PLAYBACK    <const> = 1
local SCENE_PAUSE_UPDATES     <const> = 2
local SCENE_PAUSE_COLLISIONS  <const> = 4
local SCENE_PAUSE_PLAYBACK_UPDATES <const> = SCENE_PAUSE_PLAYBACK + SCENE_PAUSE_UPDATES
local SCENE_PAUSE_PLAYBACK_COLLISIONS <const> = SCENE_PAUSE_PLAYBACK + SCENE_PAUSE_COLLISIONS
local SCENE_PAUSE_UPDATES_COLLISIONS <const> = SCENE_PAUSE_UPDATES + SCENE_PAUSE_COLLISIONS
local SCENE_PAUSE_ALL <const> = SCENE_PAUSE_PLAYBACK + SCENE_PAUSE_UPDATES + SCENE_PAUSE_COLLISIONS

local RESTORE_UPDATES     <const> = 1
local RESTORE_COLLISIONS  <const> = 2
local SHOULD_PLAY         <const> = 4

local NO_OP_BG_DRAW <const> = function(x, y, width, height) end

local _colorCallbacks = {} -- Cache: color --> fn
local _imageCallbacks = setmetatable({}, { __mode = "k" }) -- Cache: image --> fn, weak keys

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Helper: Remove Item From Array
-- Removes every matching item and returns whether the array changed
local function _removeItem(array, item)
  if not array or not item then return false end

  local removed = false
  for i = #array, 1, -1 do
    if array[i] == item then
      tableRemove(array, i)
      removed = true
    end
  end
  return removed
end

-- ! Helper: Has Item In Array
-- Returns true when the array contains the given item
local function _hasItem(array, item)
  if not array or not item then return false end

  for i = 1, #array do
    if array[i] == item then return true end
  end
  return false
end

-- ! Helper: Append Indexed Item
-- Appends an item and records its array position
local function _appendIndexed(array, index, item)
  if not array or not index or not item then return false end

  local existingIndex = index[item]
  if existingIndex ~= nil then
    if array[existingIndex] == item then return false end
    index[item] = nil
  end

  local nextIndex = #array + 1
  array[nextIndex] = item
  index[item] = nextIndex
  return true
end

-- ! Helper: Remove Indexed Item
-- Swap-removes an item from an indexed array
local function _removeIndexed(array, index, item)
  if not array or not index or not item then return false end

  local itemIndex = index[item]
  if itemIndex == nil then return false end
  if array[itemIndex] ~= item then
    index[item] = nil
    return false
  end

  local lastIndex = #array
  local lastItem = array[lastIndex]

  array[itemIndex] = lastItem
  array[lastIndex] = nil
  index[item] = nil

  if itemIndex ~= lastIndex and lastItem ~= nil then
    index[lastItem] = itemIndex
  end

  return true
end

-- ! Helper: Has Indexed Item
-- Returns true when the indexed array points back to the item
local function _hasIndexed(array, index, item)
  if not array or not index or not item then return false end

  local itemIndex = index[item]
  return itemIndex ~= nil and array[itemIndex] == item
end

-- ! Helper: Is Bounds Table
-- Returns true for camera bounds tables accepted by Camera.setBounds
local function _isBoundsTable(bounds)
  return type(bounds) == "table"
     and type(bounds.x1) == "number"
     and type(bounds.y1) == "number"
     and type(bounds.x2) == "number"
     and type(bounds.y2) == "number"
end

-- ! Helper: Read XY Pair
-- Reads either { x, y } or array-style { x, y } option pairs
local function _readXYPair(value)
  if type(value) ~= "table" then return nil, nil end
  return value.x or value[1], value.y or value[2]
end

-- ! Helper: Get Scene Pause Mask
-- Nil classification fields keep custom sprites on the legacy full-dynamic path;
-- False opts a subsystem out. The scene caches this at registration time.
local function _getScenePauseMask(sprite)
  if not sprite then return SCENE_PAUSE_NONE end

  local mask = SCENE_PAUSE_NONE
  if sprite._roxyScenePausePlayback ~= false then
    mask = mask + SCENE_PAUSE_PLAYBACK
  end
  if sprite._roxyScenePauseUpdates ~= false then
    mask = mask + SCENE_PAUSE_UPDATES
  end
  if sprite._roxyScenePauseCollisions ~= false then
    mask = mask + SCENE_PAUSE_COLLISIONS
  end
  return mask
end

-- ! Helper: Clear Scene Pause Registration
-- Clears registration-only pause fields when the scene stops tracking a sprite
local function _clearScenePauseRegistration(sprite)
  if not sprite then return end

  sprite._roxyScenePauseMask = nil

  -- Remove fields from older cache-based builds when dirty scenes are recycled.
  sprite._roxyScenePausePause = nil
  sprite._roxyScenePausePlay = nil
  sprite._roxyScenePauseGetIsPaused = nil
  sprite._roxyScenePauseReadIsPaused = nil
  sprite._roxyScenePauseSetUpdatesEnabled = nil
  sprite._roxyScenePauseUpdatesEnabled = nil
  sprite._roxyScenePauseSetCollisionsActive = nil
  sprite._roxyScenePauseSetCollisionsEnabled = nil
  sprite._roxyScenePauseCollisionsEnabled = nil
end

-- ! Helper: Remove Sprite From Scene Pause Buckets
local function _removeFromScenePauseBuckets(scene, sprite)
  _removeIndexed(scene._pauseSprites, scene._pauseSpriteIndex, sprite)
  _removeIndexed(scene._pauseUpdateSprites, scene._pauseUpdateSpriteIndex, sprite)
  _removeIndexed(scene._pauseCollisionSprites, scene._pauseCollisionSpriteIndex, sprite)
end

-- ! Helper: Add Sprite To Scene Pause Bucket
local function _addToScenePauseBucket(scene, sprite, pauseMask)
  if pauseMask == SCENE_PAUSE_NONE then return end

  if pauseMask == SCENE_PAUSE_COLLISIONS then
    _appendIndexed(scene._pauseCollisionSprites, scene._pauseCollisionSpriteIndex, sprite)
  elseif pauseMask == SCENE_PAUSE_UPDATES then
    _appendIndexed(scene._pauseUpdateSprites, scene._pauseUpdateSpriteIndex, sprite)
  else
    _appendIndexed(scene._pauseSprites, scene._pauseSpriteIndex, sprite)
  end
end

-- ! Helper: Scene Pause Mask Has Playback
local function _pauseMaskHasPlayback(mask)
  return mask == SCENE_PAUSE_PLAYBACK
      or mask == SCENE_PAUSE_PLAYBACK_UPDATES
      or mask == SCENE_PAUSE_PLAYBACK_COLLISIONS
      or mask == SCENE_PAUSE_ALL
end

-- ! Helper: Scene Pause Mask Has Updates
local function _pauseMaskHasUpdates(mask)
  return mask == SCENE_PAUSE_UPDATES
      or mask == SCENE_PAUSE_PLAYBACK_UPDATES
      or mask == SCENE_PAUSE_UPDATES_COLLISIONS
      or mask == SCENE_PAUSE_ALL
end

-- ! Helper: Scene Pause Mask Has Collisions
local function _pauseMaskHasCollisions(mask)
  return mask == SCENE_PAUSE_COLLISIONS
      or mask == SCENE_PAUSE_PLAYBACK_COLLISIONS
      or mask == SCENE_PAUSE_UPDATES_COLLISIONS
      or mask == SCENE_PAUSE_ALL
end

-- ! Helper: Read Sprite Paused State
-- Returns (isPaused, didRead). Custom sprites without state keep legacy resume.
local function _readSpritePaused(sprite)
  local getIsPaused = sprite and sprite.getIsPaused
  if type(getIsPaused) == "function" then
    local value = getIsPaused(sprite)
    if type(value) == "boolean" then
      return value, true
    end
  end

  local value = sprite and sprite.isPaused
  if type(value) == "boolean" then
    return value, true
  end

  return nil, false
end

-- ! Helper: Read Sprite Updates Enabled
local function _readSpriteUpdatesEnabled(sprite)
  local updatesEnabled = sprite and sprite.updatesEnabled
  if type(updatesEnabled) ~= "function" then
    return true
  end

  local value = updatesEnabled(sprite)
  return value ~= false and value ~= 0
end

-- ! Helper: Read Sprite Collisions Enabled
local function _readSpriteCollisionsEnabled(sprite)
  local collisionsEnabled = sprite and sprite.collisionsEnabled
  if type(collisionsEnabled) ~= "function" then
    return true
  end

  local value = collisionsEnabled(sprite)
  return value ~= false and value ~= 0
end

-- ! Helper: Run Sprite Pause
local function _runSpritePause(sprite)
  local pause = sprite and sprite.pause
  if type(pause) ~= "function" then return end

  pause(sprite)
end

-- ! Helper: Run Sprite Play
local function _runSpritePlay(sprite)
  local play = sprite and sprite.play
  if type(play) ~= "function" then return end

  play(sprite)
end

-- ! Helper: Set Sprite Updates Active
local function _setSpriteUpdatesActive(sprite, flag)
  local setter = sprite and sprite.setUpdatesEnabled
  if type(setter) ~= "function" then return end

  setter(sprite, flag)
end

-- ! Helper: Set Sprite Collisions Active
-- RoxySprite exposes a scene-pause-only path that preserves desired collisions.
local function _setSpriteCollisionsActive(sprite, flag)
  local sceneSetter = sprite and sprite._setScenePauseCollisionsActive
  if type(sceneSetter) == "function" then
    sceneSetter(sprite, flag)
    return
  end

  local setter = sprite and sprite.setCollisionsEnabled
  if type(setter) ~= "function" then return end

  setter(sprite, flag)
end

-- ! Helper: Clear Scene Pause Snapshot
local function _clearScenePauseSnapshot(scene, sprite)
  if not sprite then return end
  if scene ~= nil and sprite._roxyScenePauseOwner ~= scene then return end

  sprite._roxyScenePauseOwner = nil
  sprite._roxyScenePauseState = nil

  -- Remove fields from older snapshot builds when dirty scenes are recycled.
  sprite._roxyScenePauseHadUpdates = nil
  sprite._roxyScenePauseHadCollisions = nil
  sprite._roxyScenePauseShouldPlay = nil
end

-- ! Helper: Reapply Existing Scene Pause
-- Used when add() re-enables sprite systems while the owning scene is paused.
local function _reapplyScenePauseSprite(sprite, pauseMask)
  pauseMask = pauseMask or sprite._roxyScenePauseMask or _getScenePauseMask(sprite)

  if _pauseMaskHasPlayback(pauseMask) then
    local isPaused, didReadPaused = _readSpritePaused(sprite)
    if (not didReadPaused) or isPaused == false then
      _runSpritePause(sprite)
    end
  end
  if _pauseMaskHasUpdates(pauseMask) then
    _setSpriteUpdatesActive(sprite, false)
  end
  if _pauseMaskHasCollisions(pauseMask) then
    _setSpriteCollisionsActive(sprite, false)
  end
end

-- ! Helper: Build Scene Pause State
-- Stores only the restore bits needed for the subsystems this mask pauses
local function _buildScenePauseState(sprite, pauseMask)
  local state = 0

  if _pauseMaskHasPlayback(pauseMask) then
    local wasPaused, didReadPaused = _readSpritePaused(sprite)
    if (not didReadPaused) or wasPaused == false then
      state = state + SHOULD_PLAY
    end
  end

  if _pauseMaskHasUpdates(pauseMask) and _readSpriteUpdatesEnabled(sprite) then
    state = state + RESTORE_UPDATES
  end

  if _pauseMaskHasCollisions(pauseMask) and _readSpriteCollisionsEnabled(sprite) then
    state = state + RESTORE_COLLISIONS
  end

  return state
end

-- ! Helper: Pause Scene Collision Sprite
local function _pauseSceneCollisionSprite(scene, sprite)
  if not sprite then return end

  if sprite._roxyScenePauseOwner == scene then
    _setSpriteCollisionsActive(sprite, false)
    return
  elseif sprite._roxyScenePauseOwner ~= nil then
    _clearScenePauseSnapshot(nil, sprite)
  end

  local state = _readSpriteCollisionsEnabled(sprite) and RESTORE_COLLISIONS or 0
  sprite._roxyScenePauseOwner = scene
  sprite._roxyScenePauseState = state

  if (state & RESTORE_COLLISIONS) ~= 0 then
    _setSpriteCollisionsActive(sprite, false)
  end
end

-- ! Helper: Resume Scene Collision Sprite
local function _resumeSceneCollisionSprite(scene, sprite)
  if not sprite or sprite._roxyScenePauseOwner ~= scene then return end

  local state = sprite._roxyScenePauseState or 0
  _setSpriteCollisionsActive(sprite, (state & RESTORE_COLLISIONS) ~= 0)
  _clearScenePauseSnapshot(scene, sprite)
end

-- ! Helper: Pause Scene Update Sprite
local function _pauseSceneUpdateSprite(scene, sprite)
  if not sprite then return end

  if sprite._roxyScenePauseOwner == scene then
    _setSpriteUpdatesActive(sprite, false)
    return
  elseif sprite._roxyScenePauseOwner ~= nil then
    _clearScenePauseSnapshot(nil, sprite)
  end

  local state = _readSpriteUpdatesEnabled(sprite) and RESTORE_UPDATES or 0
  sprite._roxyScenePauseOwner = scene
  sprite._roxyScenePauseState = state

  if (state & RESTORE_UPDATES) ~= 0 then
    _setSpriteUpdatesActive(sprite, false)
  end
end

-- ! Helper: Resume Scene Update Sprite
local function _resumeSceneUpdateSprite(scene, sprite)
  if not sprite or sprite._roxyScenePauseOwner ~= scene then return end

  local state = sprite._roxyScenePauseState or 0
  _setSpriteUpdatesActive(sprite, (state & RESTORE_UPDATES) ~= 0)
  _clearScenePauseSnapshot(scene, sprite)
end

-- ! Helper: Pause Scene Sprite
-- Snapshots update, collision, and playback state before any mutation.
local function _pauseSceneSprite(scene, sprite, pauseMask)
  if not sprite then return end

  pauseMask = pauseMask or sprite._roxyScenePauseMask or _getScenePauseMask(sprite)
  if pauseMask == SCENE_PAUSE_NONE then return end
  if sprite._roxyScenePauseMask == nil then
    sprite._roxyScenePauseMask = pauseMask
  end

  if sprite._roxyScenePauseOwner == scene then
    _reapplyScenePauseSprite(sprite, pauseMask)
    return
  elseif sprite._roxyScenePauseOwner ~= nil then
    _clearScenePauseSnapshot(nil, sprite)
  end

  if pauseMask == SCENE_PAUSE_ALL then
    local state = 0
    local getIsPaused = sprite.getIsPaused
    if type(getIsPaused) == "function" then
      local wasPaused = getIsPaused(sprite)
      if type(wasPaused) ~= "boolean" or wasPaused == false then
        state = state + SHOULD_PLAY
      end
    else
      local wasPaused = sprite.isPaused
      if type(wasPaused) ~= "boolean" or wasPaused == false then
        state = state + SHOULD_PLAY
      end
    end

    local updatesEnabled = sprite.updatesEnabled
    local updatesValue = type(updatesEnabled) == "function" and updatesEnabled(sprite) or nil
    if updatesValue == nil or (updatesValue ~= false and updatesValue ~= 0) then
      state = state + RESTORE_UPDATES
    end

    local collisionsEnabled = sprite.collisionsEnabled
    local collisionsValue = type(collisionsEnabled) == "function" and collisionsEnabled(sprite) or nil
    if collisionsValue == nil or (collisionsValue ~= false and collisionsValue ~= 0) then
      state = state + RESTORE_COLLISIONS
    end

    sprite._roxyScenePauseOwner = scene
    sprite._roxyScenePauseState = state

    local pause = sprite.pause
    if type(pause) == "function" then pause(sprite) end

    if (state & RESTORE_UPDATES) ~= 0 then
      local setUpdatesEnabled = sprite.setUpdatesEnabled
      if type(setUpdatesEnabled) == "function" then setUpdatesEnabled(sprite, false) end
    end

    if (state & RESTORE_COLLISIONS) ~= 0 then
      local setCollisionsActive = sprite._setScenePauseCollisionsActive
      if type(setCollisionsActive) == "function" then
        setCollisionsActive(sprite, false)
      else
        local setCollisionsEnabled = sprite.setCollisionsEnabled
        if type(setCollisionsEnabled) == "function" then setCollisionsEnabled(sprite, false) end
      end
    end
    return
  end

  if pauseMask == SCENE_PAUSE_COLLISIONS then
    _pauseSceneCollisionSprite(scene, sprite)
    return
  end

  if pauseMask == SCENE_PAUSE_UPDATES then
    _pauseSceneUpdateSprite(scene, sprite)
    return
  end

  local pausePlayback = _pauseMaskHasPlayback(pauseMask)
  local pauseUpdates = _pauseMaskHasUpdates(pauseMask)
  local pauseCollisions = _pauseMaskHasCollisions(pauseMask)
  local state = _buildScenePauseState(sprite, pauseMask)

  sprite._roxyScenePauseOwner = scene
  sprite._roxyScenePauseState = state

  if pausePlayback then _runSpritePause(sprite) end
  if pauseUpdates and (state & RESTORE_UPDATES) ~= 0 then
    _setSpriteUpdatesActive(sprite, false)
  end
  if pauseCollisions and (state & RESTORE_COLLISIONS) ~= 0 then
    _setSpriteCollisionsActive(sprite, false)
  end
end

-- ! Helper: Resume Scene Sprite
local function _resumeSceneSprite(scene, sprite)
  if not sprite or sprite._roxyScenePauseOwner ~= scene then return end

  local pauseMask = sprite._roxyScenePauseMask or _getScenePauseMask(sprite)
  if pauseMask == SCENE_PAUSE_NONE then
    _clearScenePauseSnapshot(scene, sprite)
    return
  end

  if pauseMask == SCENE_PAUSE_ALL then
    local state = sprite._roxyScenePauseState or 0

    if (state & SHOULD_PLAY) ~= 0 then
      local play = sprite.play
      if type(play) == "function" then play(sprite) end
    end

    local setUpdatesEnabled = sprite.setUpdatesEnabled
    if type(setUpdatesEnabled) == "function" then
      setUpdatesEnabled(sprite, (state & RESTORE_UPDATES) ~= 0)
    end

    local setCollisionsActive = sprite._setScenePauseCollisionsActive
    if type(setCollisionsActive) == "function" then
      setCollisionsActive(sprite, (state & RESTORE_COLLISIONS) ~= 0)
    else
      local setCollisionsEnabled = sprite.setCollisionsEnabled
      if type(setCollisionsEnabled) == "function" then
        setCollisionsEnabled(sprite, (state & RESTORE_COLLISIONS) ~= 0)
      end
    end

    _clearScenePauseSnapshot(scene, sprite)
    return
  end

  if pauseMask == SCENE_PAUSE_COLLISIONS then
    _resumeSceneCollisionSprite(scene, sprite)
    return
  end

  if pauseMask == SCENE_PAUSE_UPDATES then
    _resumeSceneUpdateSprite(scene, sprite)
    return
  end

  local state = sprite._roxyScenePauseState or 0
  local pausePlayback = _pauseMaskHasPlayback(pauseMask)
  local pauseUpdates = _pauseMaskHasUpdates(pauseMask)
  local pauseCollisions = _pauseMaskHasCollisions(pauseMask)

  if pausePlayback and (state & SHOULD_PLAY) ~= 0 then _runSpritePlay(sprite) end
  if pauseUpdates then
    _setSpriteUpdatesActive(sprite, (state & RESTORE_UPDATES) ~= 0)
  end
  if pauseCollisions then
    _setSpriteCollisionsActive(sprite, (state & RESTORE_COLLISIONS) ~= 0)
  end

  _clearScenePauseSnapshot(scene, sprite)
end

-- ! Helper: Pause Registered Scene Sprite
local function _pauseRegisteredSceneSprite(scene, sprite, pauseMask)
  pauseMask = pauseMask or sprite._roxyScenePauseMask or _getScenePauseMask(sprite)
  if pauseMask == SCENE_PAUSE_COLLISIONS then
    _pauseSceneCollisionSprite(scene, sprite)
  elseif pauseMask == SCENE_PAUSE_UPDATES then
    _pauseSceneUpdateSprite(scene, sprite)
  elseif pauseMask ~= SCENE_PAUSE_NONE then
    _pauseSceneSprite(scene, sprite, pauseMask)
  end
end

-- ! Helper: Resume Registered Scene Sprite
local function _resumeRegisteredSceneSprite(scene, sprite, pauseMask)
  pauseMask = pauseMask or sprite._roxyScenePauseMask or _getScenePauseMask(sprite)
  if pauseMask == SCENE_PAUSE_COLLISIONS then
    _resumeSceneCollisionSprite(scene, sprite)
  elseif pauseMask == SCENE_PAUSE_UPDATES then
    _resumeSceneUpdateSprite(scene, sprite)
  elseif pauseMask ~= SCENE_PAUSE_NONE then
    _resumeSceneSprite(scene, sprite)
  end
end

-- ! Helper: Restore Scene Pause Before Unregister
-- Normal removal detaches restored sprites; transfers preserve captured state.
local function _restoreScenePauseBeforeUnregister(scene, sprite)
  if not sprite or sprite._roxyScenePauseOwner ~= scene then return end

  _resumeRegisteredSceneSprite(scene, sprite, sprite._roxyScenePauseMask)
end

-- ! Helper: Get Color Callback
-- Builds (and returns) a drawing callback for a solid color
local function _getColorCallback(color)
  local fn = _colorCallbacks[color]
  if fn == nil then
    fn = function(x, y, width, height)
      -- Draw only the dirty rect
      setColor(color)
      fillRect(x, y, width, height)
    end
    _colorCallbacks[color] = fn
  end
  return fn
end

-- ! Helper: Get Image Callback
-- Helper for static image. Draws only the dirty rect via clipping.
local function _getImageCallback(img)
  local fn = _imageCallbacks[img]
  if fn == nil then
    fn = function(x, y, width, height)
      -- Set a clip to the dirty rect, then draw the full image once
      setClipRect(x, y, width, height)  -- Only redraw the dirty rect
      img:draw(0, 0, UNFLIPPED)         -- Avoid per-call src rect; let clip do the work
      clearClipRect()                   -- Restore clip
    end
    _imageCallbacks[img] = fn
  end
  return fn
end

-- ! Helper: Read Sequence Playing
-- Returns readable running state when the sequence exposes one
local function _readSequencePlaying(sequence)
  if not sequence then return nil end
  if type(sequence.isPlaying) == "function" then
    return sequence:isPlaying() == true
  end
  if type(sequence.isRunning) == "boolean" then
    return sequence.isRunning
  end
  return nil
end

-- ! Helper: Clear Scene Pause Sequence Snapshot
-- Clears sequence pause fields owned by the pausing scene
local function _clearScenePauseSequenceSnapshot(scene, sequence)
  if not sequence or sequence._roxyScenePauseOwner ~= scene then return end
  sequence._roxyScenePauseOwner = nil
  sequence._roxyScenePauseWasRunning = nil
end

-- ! Helper: Pause Scene Sequence
-- Pauses a scene-managed sequence while remembering whether it should resume
local function _pauseSceneSequence(scene, sequence)
  if not sequence then return end
  local wasRunning = _readSequencePlaying(sequence)
  local shouldPause = wasRunning ~= false

  sequence._roxyScenePauseOwner = scene
  sequence._roxyScenePauseWasRunning = shouldPause

  if shouldPause and type(sequence.pause) == "function" then
    sequence:pause()
  end
end

-- ! Helper: Resume Scene Sequence
-- Restores a sequence paused by the same scene
local function _resumeSceneSequence(scene, sequence)
  if not sequence or sequence._roxyScenePauseOwner ~= scene then return end

  local shouldResume = sequence._roxyScenePauseWasRunning ~= false
  if shouldResume and type(sequence.play) == "function" then
    sequence:play()
  end

  _clearScenePauseSequenceSnapshot(scene, sequence)
end

--------------------------------------------------------------------------------
-- ! Class Definition and Initialize
--------------------------------------------------------------------------------

class("RoxyScene").extends(Object)

-- ! Initialize
function RoxyScene:init(background)
  self.name = self.className or "RoxyScene"
  Log.debug("[RoxyScene:init] Initializing Scene: " .. self.name) --#DEBUG

  self.isPaused = false
  self._didEnter = false
  self._didStart = false
  self._didExit = false
  self._didCleanup = false

  self.inputHandler = {}
  self.sprites = {}
  self.tilemaps = {}
  self.sequences = {}

  self._spriteSet = {}
  self._spriteIndex = {}
  self._spriteAutoAddQueue = {}
  self._spriteAutoAddIndex = {}
  self._pauseSprites = {}
  self._pauseSpriteIndex = {}
  self._pauseUpdateSprites = {}
  self._pauseUpdateSpriteIndex = {}
  self._pauseCollisionSprites = {}
  self._pauseCollisionSpriteIndex = {}
  self._sequenceAutoStartQueue = {}
  self._roxyCameraActivated = false
  self._roxyScenePauseCameraSnapshot = nil

  -- Sensible defaults used by Scene draw filtering
  self.isVisible = true
  self.blocksLowerDraw = false

  self.backgroundColor = nil
  self.backgroundImage = nil
  self.backgroundDrawFn = NO_OP_BG_DRAW -- Use shared no-op (avoid per-instance closure)

  self:setBackground(background)
end

--------------------------------------------------------------------------------
-- Scene Lifecycle
--------------------------------------------------------------------------------

-- ! Enter
function RoxyScene:enter()
  if self._didEnter then return end
  Log.debug("[RoxyScene:enter] Entering Scene: " .. self.name) --#DEBUG
  self._didEnter = true

  -- Flush any queued sprite auto-adds
  local spriteQueue = self._spriteAutoAddQueue
  for i = 1, #spriteQueue do
    local sprite = spriteQueue[i]
    sprite:add()
    if self.isPaused then
      _pauseRegisteredSceneSprite(self, sprite)
    end
  end
  self._spriteAutoAddQueue = {}
  self._spriteAutoAddIndex = {}

  -- Activate tilemap resources that cannot be created detached from display
  for i = 1, #self.tilemaps do
    local tilemap = self.tilemaps[i]
    if tilemap and tilemap.sceneDidEnter then
      tilemap:sceneDidEnter(self)
    end
  end

  -- Flush any queued sequence auto-starts
  local sequenceQueue = self._sequenceAutoStartQueue
  for i = 1, #sequenceQueue do
    sequenceQueue[i]:play()
  end
  self._sequenceAutoStartQueue = {}
end

-- ! Start
function RoxyScene:start()
  if self._didStart then return end
  Log.debug("[RoxyScene:start] Starting Scene: " .. self.name) --#DEBUG
  self._didStart = true

  self:addHandler()
end

-- ! Activate Camera
-- Opt-in scene camera setup. Scenes that do not use Camera pay no enter cost.
-- Supports tilemap bounds, raw bounds, or explicitly clearing bounds.
function RoxyScene:activateCamera(opts)
  opts = opts or {}
  self._roxyCameraActivated = true

  --#DEBUG START
  if opts.cameraBounds ~= nil then
    error("[RoxyScene:activateCamera] Use tilemap = map for tilemap bounds or bounds = { x1, y1, x2, y2 } for raw bounds", 2)
  end
  if opts.map ~= nil then
    error("[RoxyScene:activateCamera] Use tilemap = map for tilemap bounds", 2)
  end
  --#DEBUG END

  if opts.reset ~= false then
    resetCamera()
  end

  if opts.mode then setCameraMode(opts.mode) end
  if opts.friction ~= nil then setCameraFriction(opts.friction) end
  if opts.smoothing ~= nil then setCameraSmoothing(opts.smoothing) end

  local deadZoneX, deadZoneY = _readXYPair(opts.deadZone)
  if deadZoneX and deadZoneY then setCameraDeadZone(deadZoneX, deadZoneY) end

  local biasX, biasY = _readXYPair(opts.bias)
  if biasX and biasY then setCameraBias(biasX, biasY) end

  local rawBounds = opts.bounds
  if opts.clearBounds or rawBounds == false then
    clearCameraBounds()
  elseif rawBounds ~= nil then
    if _isBoundsTable(rawBounds) then
      setCameraBounds(rawBounds)
    else --#DEBUG
      error("[RoxyScene:activateCamera] Expected bounds = { x1, y1, x2, y2 }; use tilemap = map for tilemap bounds", 2) --#DEBUG
    end
  elseif opts.tilemap ~= nil then
    local tilemap = opts.tilemap
    local didApply = false
    if type(tilemap) == "table" and type(tilemap.applyCameraBounds) == "function" then
      didApply = tilemap:applyCameraBounds() == true
    end
    if not didApply and type(tilemap) == "table" and type(tilemap.getCameraBounds) == "function" then
      local bounds = tilemap:getCameraBounds()
      if bounds then setCameraBounds(bounds) end
    end
  end

  local positionX, positionY = _readXYPair(opts.position)
  if positionX and positionY then
    setCameraPosition(positionX, positionY)
  elseif opts.x ~= nil and opts.y ~= nil then
    setCameraPosition(opts.x, opts.y)
  end

  if opts.target ~= nil then
    setCameraTarget(opts.target ~= false and opts.target or nil, opts.targetSmoothing or opts.smoothing)
  elseif opts.panVelocity then
    local velocityX, velocityY = _readXYPair(opts.panVelocity)
    setCameraPanVelocity(velocityX, velocityY)
  end

  return true
end

-- ! Update
function RoxyScene:update(dt)
  -- No-op by default
end

-- ! Draw
function RoxyScene:draw(dt)
  -- No-op by default
end

-- ! Pause
function RoxyScene:pause()
  if self.isPaused then return end
  Log.debug("[RoxyScene:pause] Pausing Scene: " .. self.name) --#DEBUG
  self.isPaused = true

  if self._roxyCameraActivated and snapshotCameraState then
    self._roxyScenePauseCameraSnapshot = snapshotCameraState()
  end

  -- Disable sprites from updating or colliding
  local collisionSprites = self._pauseCollisionSprites
  for i = #collisionSprites, 1, -1 do
    local sprite = collisionSprites[i]
    if sprite._roxyScenePauseOwner == self then
      local setCollisionsActive = sprite._setScenePauseCollisionsActive
      if setCollisionsActive then
        setCollisionsActive(sprite, false)
      else
        local setCollisionsEnabled = sprite.setCollisionsEnabled
        if setCollisionsEnabled then setCollisionsEnabled(sprite, false) end
      end
    else
      if sprite._roxyScenePauseOwner ~= nil then
        _clearScenePauseSnapshot(nil, sprite)
      end

      local collisionsEnabled = sprite.collisionsEnabled
      local state = 0
      if not collisionsEnabled then
        state = RESTORE_COLLISIONS
      else
        local value = collisionsEnabled(sprite)
        if value ~= false and value ~= 0 then
          state = RESTORE_COLLISIONS
        end
      end

      sprite._roxyScenePauseOwner = self
      sprite._roxyScenePauseState = state

      if (state & RESTORE_COLLISIONS) ~= 0 then
        local setCollisionsActive = sprite._setScenePauseCollisionsActive
        if setCollisionsActive then
          setCollisionsActive(sprite, false)
        else
          local setCollisionsEnabled = sprite.setCollisionsEnabled
          if setCollisionsEnabled then setCollisionsEnabled(sprite, false) end
        end
      end
    end
  end

  local updateSprites = self._pauseUpdateSprites
  for i = #updateSprites, 1, -1 do
    local sprite = updateSprites[i]
    if sprite._roxyScenePauseOwner == self then
      local setUpdatesEnabled = sprite.setUpdatesEnabled
      if setUpdatesEnabled then setUpdatesEnabled(sprite, false) end
    else
      if sprite._roxyScenePauseOwner ~= nil then
        _clearScenePauseSnapshot(nil, sprite)
      end

      local updatesEnabled = sprite.updatesEnabled
      local state = 0
      if not updatesEnabled then
        state = RESTORE_UPDATES
      else
        local value = updatesEnabled(sprite)
        if value ~= false and value ~= 0 then
          state = RESTORE_UPDATES
        end
      end

      sprite._roxyScenePauseOwner = self
      sprite._roxyScenePauseState = state

      if (state & RESTORE_UPDATES) ~= 0 then
        local setUpdatesEnabled = sprite.setUpdatesEnabled
        if setUpdatesEnabled then setUpdatesEnabled(sprite, false) end
      end
    end
  end

  local sprites = self._pauseSprites
  for i = #sprites, 1, -1 do
    local sprite = sprites[i]
    local pauseMask = sprite._roxyScenePauseMask or _getScenePauseMask(sprite)

    if pauseMask == SCENE_PAUSE_ALL and sprite._roxyScenePauseOwner ~= self then
      if sprite._roxyScenePauseOwner ~= nil then
        _clearScenePauseSnapshot(nil, sprite)
      end

      local state = 0
      local getIsPaused = sprite.getIsPaused
      if type(getIsPaused) == "function" then
        local wasPaused = getIsPaused(sprite)
        if type(wasPaused) ~= "boolean" or wasPaused == false then
          state = state + SHOULD_PLAY
        end
      else
        local wasPaused = sprite.isPaused
        if type(wasPaused) ~= "boolean" or wasPaused == false then
          state = state + SHOULD_PLAY
        end
      end

      local updatesEnabled = sprite.updatesEnabled
      if not updatesEnabled then
        state = state + RESTORE_UPDATES
      else
        local value = updatesEnabled(sprite)
        if value ~= false and value ~= 0 then
          state = state + RESTORE_UPDATES
        end
      end

      local collisionsEnabled = sprite.collisionsEnabled
      if not collisionsEnabled then
        state = state + RESTORE_COLLISIONS
      else
        local value = collisionsEnabled(sprite)
        if value ~= false and value ~= 0 then
          state = state + RESTORE_COLLISIONS
        end
      end

      sprite._roxyScenePauseOwner = self
      sprite._roxyScenePauseState = state

      local pause = sprite.pause
      if pause then pause(sprite) end

      if (state & RESTORE_UPDATES) ~= 0 then
        local setUpdatesEnabled = sprite.setUpdatesEnabled
        if setUpdatesEnabled then setUpdatesEnabled(sprite, false) end
      end

      if (state & RESTORE_COLLISIONS) ~= 0 then
        local setCollisionsActive = sprite._setScenePauseCollisionsActive
        if setCollisionsActive then
          setCollisionsActive(sprite, false)
        else
          local setCollisionsEnabled = sprite.setCollisionsEnabled
          if setCollisionsEnabled then setCollisionsEnabled(sprite, false) end
        end
      end
    else
      _pauseSceneSprite(self, sprite, pauseMask)
    end
  end

  -- Disable sequences from updating
  local sequences = self.sequences
  for i = #sequences, 1, -1 do
    _pauseSceneSequence(self, sequences[i])
  end

  removeHandler(self)
end

-- ! Resume
function RoxyScene:resume()
  if not self.isPaused then return end
  Log.debug("[RoxyScene:resume] Resuming Scene: " .. self.name) --#DEBUG
  self.isPaused = false

  -- Enable sprites for updating and colliding
  local collisionSprites = self._pauseCollisionSprites
  for i = #collisionSprites, 1, -1 do
    local sprite = collisionSprites[i]
    if sprite._roxyScenePauseOwner == self then
      local state = sprite._roxyScenePauseState or 0
      local restoreCollisions = (state & RESTORE_COLLISIONS) ~= 0
      local setCollisionsActive = sprite._setScenePauseCollisionsActive
      if setCollisionsActive then
        setCollisionsActive(sprite, restoreCollisions)
      else
        local setCollisionsEnabled = sprite.setCollisionsEnabled
        if setCollisionsEnabled then setCollisionsEnabled(sprite, restoreCollisions) end
      end
      sprite._roxyScenePauseOwner = nil
      sprite._roxyScenePauseState = nil
    end
  end

  local updateSprites = self._pauseUpdateSprites
  for i = #updateSprites, 1, -1 do
    local sprite = updateSprites[i]
    if sprite._roxyScenePauseOwner == self then
      local state = sprite._roxyScenePauseState or 0
      local setUpdatesEnabled = sprite.setUpdatesEnabled
      if setUpdatesEnabled then
        setUpdatesEnabled(sprite, (state & RESTORE_UPDATES) ~= 0)
      end
      sprite._roxyScenePauseOwner = nil
      sprite._roxyScenePauseState = nil
    end
  end

  local sprites = self._pauseSprites
  for i = #sprites, 1, -1 do
    local sprite = sprites[i]
    local pauseMask = sprite._roxyScenePauseMask or _getScenePauseMask(sprite)
    if pauseMask == SCENE_PAUSE_ALL and sprite._roxyScenePauseOwner == self then
      local state = sprite._roxyScenePauseState or 0

      if (state & SHOULD_PLAY) ~= 0 then
        local play = sprite.play
        if play then play(sprite) end
      end

      local setUpdatesEnabled = sprite.setUpdatesEnabled
      if setUpdatesEnabled then
        setUpdatesEnabled(sprite, (state & RESTORE_UPDATES) ~= 0)
      end

      local setCollisionsActive = sprite._setScenePauseCollisionsActive
      if setCollisionsActive then
        setCollisionsActive(sprite, (state & RESTORE_COLLISIONS) ~= 0)
      else
        local setCollisionsEnabled = sprite.setCollisionsEnabled
        if setCollisionsEnabled then
          setCollisionsEnabled(sprite, (state & RESTORE_COLLISIONS) ~= 0)
        end
      end

      sprite._roxyScenePauseOwner = nil
      sprite._roxyScenePauseState = nil
    else
      _resumeSceneSprite(self, sprite)
    end
  end

  -- Enable sequences for updating
  local sequences = self.sequences
  for i = #sequences, 1, -1 do
    _resumeSceneSequence(self, sequences[i])
  end

  if self._roxyScenePauseCameraSnapshot and restoreCameraState then
    restoreCameraState(self._roxyScenePauseCameraSnapshot)
    self._roxyScenePauseCameraSnapshot = nil
  end

  self:addHandler()
end

-- ! Exit
function RoxyScene:exit()
  if self._didExit then return end
  Log.debug("[RoxyScene:exit] Exiting Scene: " .. self.name) --#DEBUG
  self._didExit = true

  pauseHandler()
end

-- ! Cleanup
function RoxyScene:cleanup()
  if self._didCleanup then return end
  Log.debug("[RoxyScene:cleanup] Cleaning Up Scene: " .. self.name) --#DEBUG
  self._didCleanup = true

  resumeHandler(true)
  removeHandler(self)

  self:removeAllSprites()
  self:removeAllTilemaps()
  self:removeAllSequences()
  self:resetDrawOffset()

  resetCamera()
  self._roxyCameraActivated = false
  self._roxyScenePauseCameraSnapshot = nil

  self._spriteAutoAddQueue = {}
  self._spriteAutoAddIndex = {}
  self._sequenceAutoStartQueue = {}

  self.backgroundColor = nil
  self.backgroundImage = nil
  self.backgroundDrawFn = nil
  self.frozenBackground = nil -- Clean up screenshot from transitions
end

--------------------------------------------------------------------------------
-- Background Drawing
--------------------------------------------------------------------------------

-- ! Set Background
function RoxyScene:setBackground(background)
  -- Solid color
  if background == nil or type(background) == "number" then
    local color = background or CLEAR_COLOR
    local colorFn = _getColorCallback(color) -- Avoid double lookup/construction

    -- Early-out if unchanged color and no image
    if self.backgroundImage == nil and self.backgroundColor == color and self.backgroundDrawFn == colorFn then
      return
    end

    Log.debug("[RoxyScene:setBackground] Setting background color to " .. color) --#DEBUG
    setBackgroundColor(color)
    self.backgroundColor = color
    self.backgroundImage = nil
    self.backgroundDrawFn = colorFn
    redrawBackground()
    return
  end

  -- Background image
  if type(background) == "userdata" then
    local img = background
    -- Early-out if unchanged image
    if self.backgroundImage == img then
      return
    end

    Log.debug("[RoxyScene:setBackground] Setting background image") --#DEBUG
    self.backgroundColor = nil
    self.backgroundImage = img
    self.backgroundDrawFn = _getImageCallback(img)
    redrawBackground()
    return
  end

  -- Fallback
  Log.debug("[RoxyScene:setBackground] Falling back to background color: " .. CLEAR_COLOR) --#DEBUG
  local colorFn = _getColorCallback(CLEAR_COLOR) -- Avoid double lookup/construction
  setBackgroundColor(CLEAR_COLOR)
  self.backgroundColor = CLEAR_COLOR
  self.backgroundImage = nil
  self.backgroundDrawFn = colorFn
  redrawBackground()
end

--------------------------------------------------------------------------------
-- Sprites
--------------------------------------------------------------------------------

-- ! Add Sprite
function RoxyScene:addSprite(sprite)
  if not sprite then return end

  local pauseMask = _getScenePauseMask(sprite)

  if self._spriteSet[sprite] == true then
    local isTracked = _hasIndexed(self.sprites, self._spriteIndex, sprite)
    local isQueued = self._didEnter or _hasIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
    local cachedPauseMask = sprite._roxyScenePauseMask or SCENE_PAUSE_NONE
    if sprite.scene == self and isTracked and isQueued then
      if cachedPauseMask == pauseMask then return end

      if sprite._roxyScenePauseOwner == self then
        _resumeRegisteredSceneSprite(self, sprite, cachedPauseMask)
      end

      _removeFromScenePauseBuckets(self, sprite)
      _clearScenePauseRegistration(sprite)
      _clearScenePauseSnapshot(self, sprite)

      if pauseMask ~= SCENE_PAUSE_NONE then
        sprite._roxyScenePauseMask = pauseMask
        _addToScenePauseBucket(self, sprite, pauseMask)
      end

      if self.isPaused and pauseMask ~= SCENE_PAUSE_NONE then
        _pauseRegisteredSceneSprite(self, sprite, pauseMask)
      end

      return
    end

    _removeIndexed(self.sprites, self._spriteIndex, sprite)
    _removeIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
    _removeFromScenePauseBuckets(self, sprite)
    self._spriteSet[sprite] = nil
    _clearScenePauseRegistration(sprite)
    _clearScenePauseSnapshot(self, sprite)
  end

  local currentScene = sprite.scene
  local transferPauseMask = nil
  local transferPauseState = nil
  if currentScene ~= nil and currentScene ~= self and type(currentScene) == "table" then
    if sprite._roxyScenePauseOwner == currentScene then
      transferPauseMask = sprite._roxyScenePauseMask or _getScenePauseMask(sprite)
      transferPauseState = sprite._roxyScenePauseState
    end

    if type(currentScene._unregisterSprite) == "function" then
      currentScene:_unregisterSprite(sprite, true, true)
    elseif type(currentScene.removeSprite) == "function" then
      currentScene:removeSprite(sprite)
    end
  end

  -- Give the sprite a back-pointer so it can self-remove later
  sprite.scene = self

  _appendIndexed(self.sprites, self._spriteIndex, sprite)
  self._spriteSet[sprite] = true

  if pauseMask ~= SCENE_PAUSE_NONE then
    sprite._roxyScenePauseMask = pauseMask
    _addToScenePauseBucket(self, sprite, pauseMask)
  else
    _clearScenePauseRegistration(sprite)
  end

  if transferPauseMask ~= nil and self.isPaused and pauseMask ~= SCENE_PAUSE_NONE then
    sprite._roxyScenePauseOwner = self
    sprite._roxyScenePauseState = transferPauseState
  end

  if self._didEnter then
    -- Scene is active -- attach immediately
    sprite:add()
  else
    -- Scene isn't active yet -- queue for enter()
    _appendIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
  end

  if self.isPaused and pauseMask ~= SCENE_PAUSE_NONE then
    _pauseRegisteredSceneSprite(self, sprite, pauseMask)
  elseif transferPauseMask ~= nil then
    local restoreMask = sprite._roxyScenePauseMask
    sprite._roxyScenePauseMask = transferPauseMask
    sprite._roxyScenePauseOwner = self
    sprite._roxyScenePauseState = transferPauseState
    _resumeRegisteredSceneSprite(self, sprite, transferPauseMask)
    if pauseMask ~= SCENE_PAUSE_NONE then
      sprite._roxyScenePauseMask = restoreMask or pauseMask
    else
      _clearScenePauseRegistration(sprite)
    end
  end
end

-- ! Remove Sprite
function RoxyScene:removeSprite(sprite)
  self:_unregisterSprite(sprite, true)
end

-- ! Unregister Sprite
-- Private cleanup path used by tilemaps and direct scene sprite removal
function RoxyScene:_unregisterSprite(sprite, removeFromDisplay, preserveScenePauseState)
  if not sprite then return end

  local wasSelfOwnedAtEntry = sprite.scene == self
  local wasSelfTrackedAtEntry = self._spriteSet[sprite] == true

  if preserveScenePauseState ~= true then
    _restoreScenePauseBeforeUnregister(self, sprite)
  end

  -- Remove only this scene's ownership state
  -- Direct external writes to scene.sprites are unsupported, but removeAllSprites remains tolerant.
  _removeIndexed(self.sprites, self._spriteIndex, sprite)
  _removeIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
  _removeFromScenePauseBuckets(self, sprite)
  self._spriteSet[sprite] = nil
  if wasSelfTrackedAtEntry then
    _clearScenePauseRegistration(sprite)
  end
  _clearScenePauseSnapshot(self, sprite)

  if wasSelfOwnedAtEntry and sprite.scene == self then
    sprite.scene = nil -- Clear back-pointer
  end

  if removeFromDisplay ~= false and wasSelfOwnedAtEntry then
    sprite:remove()
  end
end

-- ! Unregister Sprites
-- Private batch cleanup path used by tilemap teardown.
-- Removes many scene-managed sprites without rescanning scene lists per sprite.
function RoxyScene:_unregisterSprites(sprites, removeFromDisplay)
  if not sprites then return end

  -- Build a unique target list so duplicate inputs stay idempotent
  local targets = nil
  local targetList = nil
  for i = 1, #sprites do
    local sprite = sprites[i]
    if sprite and (not targets or not targets[sprite]) then
      targets = targets or {}
      targetList = targetList or {}
      targets[sprite] = true
      targetList[#targetList + 1] = sprite
    end
  end
  if not targets then return end

  local shouldRemove = removeFromDisplay ~= false
  for i = 1, #targetList do
    local sprite = targetList[i]
    local wasSelfOwnedAtEntry = sprite.scene == self
    local wasSelfTrackedAtEntry = self._spriteSet[sprite] == true

    _restoreScenePauseBeforeUnregister(self, sprite)

    _removeIndexed(self.sprites, self._spriteIndex, sprite)
    _removeIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
    _removeFromScenePauseBuckets(self, sprite)
    self._spriteSet[sprite] = nil
    if wasSelfTrackedAtEntry then
      _clearScenePauseRegistration(sprite)
    end
    _clearScenePauseSnapshot(self, sprite)

    if wasSelfOwnedAtEntry and sprite.scene == self then
      sprite.scene = nil -- Clear back-pointer
    end

    if shouldRemove and wasSelfOwnedAtEntry then
      sprite:remove()
    end
  end
end

-- ! Remove All Sprites
function RoxyScene:removeAllSprites()
  local sprites = self.sprites

  self.sprites = {}
  self._spriteSet = {}
  self._spriteIndex = {}
  self._spriteAutoAddQueue = {}
  self._spriteAutoAddIndex = {}
  self._pauseSprites = {}
  self._pauseSpriteIndex = {}
  self._pauseUpdateSprites = {}
  self._pauseUpdateSpriteIndex = {}
  self._pauseCollisionSprites = {}
  self._pauseCollisionSpriteIndex = {}

  for i = #sprites, 1, -1 do
    local sprite = sprites[i]
    _restoreScenePauseBeforeUnregister(self, sprite)
    _clearScenePauseRegistration(sprite)
    _clearScenePauseSnapshot(self, sprite)
    if sprite.scene == self then
      sprite.scene = nil -- Clear back-pointer
    end
  end

  for i = #sprites, 1, -1 do
    local sprite = sprites[i]
    -- Prefer view-aware cleanup so pooled sprite assets are released
    if sprite.removeAndClearView then
      sprite:removeAndClearView()
    else
      sprite:remove()
    end
  end
end

-- ! Spawn Sprite
function RoxyScene:spawnSprite(spriteOpts)
  return RoxySprite(spriteOpts, self)
end

--------------------------------------------------------------------------------
-- Tilemaps
--------------------------------------------------------------------------------

-- ! Add Tilemap
-- Attaches a load-only tilemap to this scene
function RoxyScene:addTilemap(tilemap)
  if not tilemap then return false end

  for i = 1, #self.tilemaps do
    if self.tilemaps[i] == tilemap then return true end
  end

  if type(tilemap.attachToScene) ~= "function" then
    Log.warn("[RoxyScene:addTilemap] Expected tilemap with attachToScene") --#DEBUG
    return false
  end

  if not tilemap:attachToScene(self) then
    return false
  end

  tableInsert(self.tilemaps, tilemap)
  return true
end

-- ! Remove Tilemap
-- Destroys a tilemap and unregisters it from this scene
function RoxyScene:removeTilemap(tilemap)
  if not tilemap then return false end
  if tilemap.scene ~= self and not _hasItem(self.tilemaps, tilemap) then return false end

  if type(tilemap.destroy) ~= "function" then
    Log.warn("[RoxyScene:removeTilemap] Expected tilemap with destroy") --#DEBUG
    return false
  end

  tilemap:destroy()
  return true
end

-- ! Detach Tilemap
-- Detaches scene/display state while preserving pooled tilemap resources
function RoxyScene:detachTilemap(tilemap)
  if not tilemap then return false end
  if tilemap.scene ~= self and not _hasItem(self.tilemaps, tilemap) then return false end

  if type(tilemap.detachFromScene) ~= "function" then
    Log.warn("[RoxyScene:detachTilemap] Expected tilemap with detachFromScene") --#DEBUG
    return false
  end

  return tilemap:detachFromScene()
end

-- ! Unregister Tilemap
-- Removes a tilemap from scene ownership without destroying it
function RoxyScene:_unregisterTilemap(tilemap)
  if not tilemap then return end

  _removeItem(self.tilemaps, tilemap)

  if tilemap.scene == self then
    tilemap.scene = nil
  end

  local layerManager = tilemap.layerManager
  if layerManager and layerManager.scene == self and layerManager.setScene then
    layerManager:setScene(nil)
  end
end

-- ! Remove All Tilemaps
function RoxyScene:removeAllTilemaps()
  local tilemaps = self.tilemaps
  self.tilemaps = {}

  for i = #tilemaps, 1, -1 do
    local tilemap = tilemaps[i]
    if type(tilemap.destroy) == "function" then
      tilemap:destroy()
    end
  end
end

-- ! Spawn Tilemap
-- Convenience helper that creates and attaches an orthogonal tilemap
function RoxyScene:spawnTilemap(path, tilemapOpts)
  local tilemap = RoxyOrthoTilemap(path, tilemapOpts)
  self:addTilemap(tilemap)
  return tilemap
end

--------------------------------------------------------------------------------
-- Sequences
--------------------------------------------------------------------------------

-- ! Add Sequence
function RoxyScene:addSequence(sequence)
  if not sequence then return end
  if sequence.scene == self then return end

  for i = 1, #self.sequences do
    if self.sequences[i] == sequence then return end
  end

  tableInsert(self.sequences, sequence)

  -- Give the sequence a back-pointer so it can self-remove later
  sequence.scene = self

  if self._didEnter then
    -- Scene is active -- start now
    sequence:play()
  else
    -- Scene isn't active yet -- queue for enter()
    tableInsert(self._sequenceAutoStartQueue, sequence)
  end
end

-- ! Remove Sequence
function RoxyScene:removeSequence(sequence)
  if not sequence then return end
  for i = #self.sequences, 1, -1 do
    if self.sequences[i] == sequence then
      _clearScenePauseSequenceSnapshot(self, sequence)
      sequence.scene = nil -- Clear back-pointer
      sequence:clear(true)
      tableRemove(self.sequences, i)
      return
    end
  end
end

-- ! Remove All Sequences
function RoxyScene:removeAllSequences()
  local sequences = self.sequences
  for i = #sequences, 1, -1 do
    local sequence = sequences[i]
    _clearScenePauseSequenceSnapshot(self, sequence)
    sequence.scene = nil -- Clear back-pointer
    sequence:clear(true)
  end
  self.sequences = {}
end

-- ! Spawn Sequence
function RoxyScene:spawnSequence()
  return RoxySequence(self)
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

-- ! Set Input Handler
function RoxyScene:addHandler()
  local inputHandler = self.inputHandler
  if inputHandler and (type(inputHandler) == "table" or type(inputHandler) == "function") then
    addHandler(self, inputHandler, 0)
  end
end

-- ! Reset Draw Offset
function RoxyScene:resetDrawOffset()
  setDrawOffset(0, 0)
end

-- ! Clear Screen
function RoxyScene:clearScreen()
  clearScreen(CLEAR_COLOR)
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

RoxyScene owns scene lifecycle, input, sprites, tilemaps, sequences, and camera setup.

-- Gameplay Scene
local Graphics <const> = playdate.graphics

local COLOR_WHITE <const> = Graphics.kColorWhite

class("GameplayScene").extends(RoxyScene)

function GameplayScene:init()
  GameplayScene.super.init(self, COLOR_WHITE)

  self.inputHandler = {
    BButtonDown = function()
      roxy.Scene.pushScene(PauseScene)
    end,
  }
end

function GameplayScene:start()
  GameplayScene.super.start(self)

  self.player = RoxySprite({ name = "player" })
  self:addSprite(self.player)

  self.map = self:spawnTilemap("assets/maps/level-01.json", {
    cameraBounds = true,
    layerOptions = {
      Walls = { collidable = true },
    },
  })
  self:activateCamera({
    tilemap = self.map,
    target = self.player,
    smoothing = 4,
    deadZone = { 48, 32 },
  })

  self.fadeIn = self:spawnSequence():from(0):to(1, 0.25):play()
end

function GameplayScene:update(dt)
  roxy.Camera.update(dt)
end

function GameplayScene:cleanup()
  GameplayScene.super.cleanup(self)
  self.player = nil
  self.map = nil
  self.fadeIn = nil
end

-- Overlay Scene
local pauseScene = RoxyScene(Graphics.kColorBlack)
pauseScene.isVisible = true
pauseScene.blocksLowerDraw = false
pauseScene.updateBackground = true

-- Manual Ownership
local scene = RoxyScene()
local player = RoxySprite({ name = "player" })
local tilemap = RoxyOrthoTilemap("assets/maps/level-01.json")

scene:addSprite(player)
scene:addTilemap(tilemap)
scene:activateCamera({ tilemap = tilemap, target = player })

scene:detachTilemap(tilemap)
scene:removeSprite(player)
scene:cleanup()

--]]
