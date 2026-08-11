-- core/scenes/RoxyScene.lua

local pd        <const> = playdate
local Object    <const> = pd.object
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r       <const> = roxy
local Input   <const> = r.Input
local Camera  <const> = r.Camera
local Scene   <const> = r.Scene

local tableInsert   <const> = table.insert
local tableRemove   <const> = table.remove
local setMetatable  <const> = setmetatable
local rawGet        <const> = rawget
local rawSet        <const> = rawset
local luaType       <const> = type

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

local restoreHandler          <const> = Input._restoreHandler
local getHandlerRegistration  <const> = Input._getHandlerRegistration

local getSpritePauseMask <const> = Scene._getSpritePauseMask

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

local SCENE_PAUSE_NONE        <const> = Scene._SCENE_PAUSE_NONE
local SCENE_PAUSE_PLAYBACK    <const> = Scene._SCENE_PAUSE_PLAYBACK
local SCENE_PAUSE_UPDATES     <const> = Scene._SCENE_PAUSE_UPDATES
local SCENE_PAUSE_COLLISIONS  <const> = Scene._SCENE_PAUSE_COLLISIONS
local SCENE_PAUSE_PLAYBACK_UPDATES <const> = SCENE_PAUSE_PLAYBACK + SCENE_PAUSE_UPDATES
local SCENE_PAUSE_PLAYBACK_COLLISIONS <const> = SCENE_PAUSE_PLAYBACK + SCENE_PAUSE_COLLISIONS
local SCENE_PAUSE_UPDATES_COLLISIONS <const> = SCENE_PAUSE_UPDATES + SCENE_PAUSE_COLLISIONS
local SCENE_PAUSE_ALL <const> = Scene._SCENE_PAUSE_ALL

local RESTORE_UPDATES         <const> = 1
local RESTORE_COLLISIONS      <const> = 2
local SHOULD_PLAY             <const> = 4
local SNAPSHOT_STATE_MASK     <const> = 7
local SNAPSHOT_STATE_BITS     <const> = 3
local SNAPSHOT_UPDATES_OFF    <const> = SCENE_PAUSE_UPDATES << SNAPSHOT_STATE_BITS
local SNAPSHOT_UPDATES_ON     <const> = SNAPSHOT_UPDATES_OFF + RESTORE_UPDATES
local SNAPSHOT_COLLISIONS_OFF <const> = SCENE_PAUSE_COLLISIONS << SNAPSHOT_STATE_BITS
local SNAPSHOT_COLLISIONS_ON  <const> = SNAPSHOT_COLLISIONS_OFF + RESTORE_COLLISIONS
local SNAPSHOT_ALL_BASE       <const> = SCENE_PAUSE_ALL << SNAPSHOT_STATE_BITS

local NO_OP_BG_DRAW <const> = function(x, y, width, height) end

local _colorCallbacks = {} -- Cache: color --> fn
local _imageCallbacks = setMetatable({}, { __mode = "k" }) -- Cache: image --> fn, weak keys

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
  return luaType(bounds) == "table"
     and luaType(bounds.x1) == "number"
     and luaType(bounds.y1) == "number"
     and luaType(bounds.x2) == "number"
     and luaType(bounds.y2) == "number"
end

-- ! Helper: Read XY Pair
-- Reads either { x, y } or array-style { x, y } option pairs
local function _readXYPair(value)
  if luaType(value) ~= "table" then return nil, nil end
  return value.x or value[1], value.y or value[2]
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

-- ! Scene Pause Hot Path Contract
-- The pause loop treats nil hook slots as absent and every non-nil hook as
-- callable. That avoids type checks in large sprite loops; Roxy-owned sprites
-- and custom sprites must leave optional hooks nil or provide a function.

-- ! Helper: Pack Scene Pause Snapshot
local function _packScenePauseSnapshot(pauseMask, state)
  return (pauseMask << SNAPSHOT_STATE_BITS) + state
end

-- ! Helper: Unpack Scene Pause Snapshot Mask
local function _scenePauseSnapshotMask(snapshot)
  return snapshot >> SNAPSHOT_STATE_BITS
end

-- ! Helper: Unpack Scene Pause Snapshot State
local function _scenePauseSnapshotState(snapshot)
  return snapshot & SNAPSHOT_STATE_MASK
end

-- ! Helper: Read Sprite Paused State
-- Returns (isPaused, didRead). Custom sprites without state keep legacy resume.
local function _readSpritePaused(sprite)
  local getIsPaused = sprite and sprite.getIsPaused
  if getIsPaused ~= nil then
    local value = getIsPaused(sprite)
    if luaType(value) == "boolean" then
      return value, true
    end
  end

  local value = sprite and sprite.isPaused
  if luaType(value) == "boolean" then
    return value, true
  end

  return nil, false
end

-- ! Helper: Read Sprite Updates Enabled
local function _readSpriteUpdatesEnabled(sprite)
  local updatesEnabled = sprite and sprite.updatesEnabled
  if updatesEnabled == nil then
    return true
  end

  local value = updatesEnabled(sprite)
  return value ~= false and value ~= 0
end

-- ! Helper: Read Sprite Collisions Enabled
local function _readSpriteCollisionsEnabled(sprite)
  local collisionsEnabled = sprite and sprite.collisionsEnabled
  if collisionsEnabled == nil then
    return true
  end

  local value = collisionsEnabled(sprite)
  return value ~= false and value ~= 0
end

-- ! Helper: Run Sprite Pause
local function _runSpritePause(sprite)
  local pause = sprite and sprite.pause
  if pause == nil then return end

  pause(sprite)
end

-- ! Helper: Run Sprite Play
local function _runSpritePlay(sprite)
  local play = sprite and sprite.play
  if play == nil then return end

  play(sprite)
end

-- ! Helper: Set Sprite Updates Active
local function _setSpriteUpdatesActive(sprite, flag)
  local setter = sprite and sprite.setUpdatesEnabled
  if setter == nil then return end

  setter(sprite, flag)
end

-- ! Helper: Set Sprite Collisions Active
-- RoxySprite exposes a scene-pause-only path that preserves desired collisions.
local function _setSpriteCollisionsActive(sprite, flag)
  local sceneSetter = sprite and sprite._setScenePauseCollisionsActive
  if sceneSetter ~= nil then
    sceneSetter(sprite, flag)
    return
  end

  local setter = sprite and sprite.setCollisionsEnabled
  if setter == nil then return end

  setter(sprite, flag)
end

-- ! Helper: Build Scene Pause State
-- Stores only the restore bits needed for the subsystems this mask pauses
local function _buildScenePauseState(sprite, pauseMask)
  local state = 0

  if pauseMask == SCENE_PAUSE_ALL then
    local wasPaused, didReadPaused = _readSpritePaused(sprite)
    if (not didReadPaused) or wasPaused == false then
      state = state + SHOULD_PLAY
    end
    if _readSpriteUpdatesEnabled(sprite) then state = state + RESTORE_UPDATES end
    if _readSpriteCollisionsEnabled(sprite) then state = state + RESTORE_COLLISIONS end
    return state
  elseif pauseMask == SCENE_PAUSE_UPDATES then
    if _readSpriteUpdatesEnabled(sprite) then state = RESTORE_UPDATES end
    return state
  elseif pauseMask == SCENE_PAUSE_COLLISIONS then
    if _readSpriteCollisionsEnabled(sprite) then state = RESTORE_COLLISIONS end
    return state
  elseif pauseMask == SCENE_PAUSE_PLAYBACK then
    local wasPaused, didReadPaused = _readSpritePaused(sprite)
    if (not didReadPaused) or wasPaused == false then state = SHOULD_PLAY end
    return state
  else
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
  end

  return state
end

-- ! Helper: Apply Scene Pause Mutations
local function _applyScenePauseSprite(sprite, pauseMask, state)
  if state ~= nil then
    if pauseMask == SCENE_PAUSE_ALL then
      _runSpritePause(sprite)
      if (state & RESTORE_UPDATES) ~= 0 then _setSpriteUpdatesActive(sprite, false) end
      if (state & RESTORE_COLLISIONS) ~= 0 then _setSpriteCollisionsActive(sprite, false) end
      return
    elseif pauseMask == SCENE_PAUSE_UPDATES then
      if (state & RESTORE_UPDATES) ~= 0 then _setSpriteUpdatesActive(sprite, false) end
      return
    elseif pauseMask == SCENE_PAUSE_COLLISIONS then
      if (state & RESTORE_COLLISIONS) ~= 0 then _setSpriteCollisionsActive(sprite, false) end
      return
    elseif pauseMask == SCENE_PAUSE_PLAYBACK then
      _runSpritePause(sprite)
      return
    end
  end

  if _pauseMaskHasPlayback(pauseMask) then
    if state == nil then
      local isPaused, didReadPaused = _readSpritePaused(sprite)
      if (not didReadPaused) or isPaused == false then
        _runSpritePause(sprite)
      end
    else
      _runSpritePause(sprite)
    end
  end

  if _pauseMaskHasUpdates(pauseMask) and (state == nil or (state & RESTORE_UPDATES) ~= 0) then
    _setSpriteUpdatesActive(sprite, false)
  end

  if _pauseMaskHasCollisions(pauseMask) and (state == nil or (state & RESTORE_COLLISIONS) ~= 0) then
    _setSpriteCollisionsActive(sprite, false)
  end
end

-- ! Helper: Store Scene Pause Snapshot
local function _storeScenePauseSnapshot(scene, sprite, pauseMask, state)
  local snapshots = scene._pauseSpriteSnapshots
  if not snapshots then
    snapshots = {}
    scene._pauseSpriteSnapshots = snapshots
  end
  local snapshot = _packScenePauseSnapshot(pauseMask, state)
  if not snapshots[sprite] then
    local list = scene._pauseSpriteSnapshotList
    if not list then
      list = {}
      scene._pauseSpriteSnapshotList = list
    end
    list[#list + 1] = sprite
  end
  snapshots[sprite] = snapshot
  return snapshot
end

-- ! Helper: Forget Scene Pause Snapshot
local function _forgetScenePauseSnapshot(scene, sprite, pruneList)
  local snapshots = scene._pauseSpriteSnapshots
  if snapshots then snapshots[sprite] = nil end

  if pruneList == false then return end

  local snapshotList = scene._pauseSpriteSnapshotList
  if not snapshotList then return end

  for i = #snapshotList, 1, -1 do
    if snapshotList[i] == sprite then
      snapshotList[i] = false
      return
    end
  end
end

-- ! Helper: Prune Scene Pause Snapshot List
local function _pruneScenePauseSnapshotList(scene, sprites)
  local snapshotList = scene._pauseSpriteSnapshotList
  if not snapshotList or not sprites then return end

  for i = #snapshotList, 1, -1 do
    if sprites[snapshotList[i]] == true then
      snapshotList[i] = false
    end
  end
end

-- ! Helper: Read Scene Stack Sprite Visibility
local function _readSceneStackSpriteVisibility(sprite)
  local reader = sprite and sprite.isVisible
  if luaType(reader) ~= "function" then return true end

  local value = reader(sprite)
  return value ~= false and value ~= 0
end

-- ! Helper: Scene Stack Visibility SetVisible Wrapper
local function _sceneStackVisibilitySetVisible(sprite, value)
  if not sprite or sprite._roxySceneStackVisibilityOwner == nil then
    local setter = sprite and sprite._roxySceneStackSavedSetVisible
    if luaType(setter) == "function" then return setter(sprite, value) end
    return
  end

  sprite._roxySceneStackWasVisible = value ~= false

  local setter = sprite._roxySceneStackSavedSetVisible
  if luaType(setter) == "function" then return setter(sprite, false) end
end

-- ! Helper: Scene Stack Visibility IsVisible Wrapper
local function _sceneStackVisibilityIsVisible(sprite)
  if sprite and sprite._roxySceneStackVisibilityOwner ~= nil then
    return sprite._roxySceneStackWasVisible ~= false
  end

  local reader = sprite and sprite._roxySceneStackSavedIsVisible
  if luaType(reader) == "function" then return reader(sprite) end
  return true
end

-- ! Helper: Mark Scene Stack Visibility Snapshot Pruned
local function _markSceneStackVisibilitySnapshotPruned(scene, sprite)
  local snapshotList = scene and scene._sceneStackVisibilitySnapshotList
  if not snapshotList then return end

  for i = #snapshotList, 1, -1 do
    if snapshotList[i] == sprite then
      snapshotList[i] = false
      return
    end
  end
end

-- ! Helper: Prune Scene Stack Visibility Snapshot List
local function _pruneSceneStackVisibilitySnapshotList(scene, sprites)
  local snapshotList = scene._sceneStackVisibilitySnapshotList
  if not snapshotList or not sprites then return end

  for i = #snapshotList, 1, -1 do
    if sprites[snapshotList[i]] == true then
      snapshotList[i] = false
    end
  end
end

-- ! Helper: Clear Scene Stack Visibility Snapshot
local function _clearSceneStackVisibilitySnapshot(scene, sprite, pruneList)
  if not scene or not sprite then return end

  if sprite._roxySceneStackVisibilityOwner ~= scene then
    if pruneList ~= false then _markSceneStackVisibilitySnapshotPruned(scene, sprite) end
    return
  end

  local desiredVisible = sprite._roxySceneStackWasVisible ~= false
  local savedSetVisible = sprite._roxySceneStackSavedSetVisible
  local savedIsVisible = sprite._roxySceneStackSavedIsVisible
  local setVisibleWasOwn = sprite._roxySceneStackSetVisibleWasOwn == true
  local isVisibleWasOwn = sprite._roxySceneStackIsVisibleWasOwn == true

  if rawGet(sprite, "setVisible") == _sceneStackVisibilitySetVisible then
    if setVisibleWasOwn then
      rawSet(sprite, "setVisible", savedSetVisible)
    else
      rawSet(sprite, "setVisible", nil)
    end
  end

  if rawGet(sprite, "isVisible") == _sceneStackVisibilityIsVisible then
    if isVisibleWasOwn then
      rawSet(sprite, "isVisible", savedIsVisible)
    else
      rawSet(sprite, "isVisible", nil)
    end
  end

  local currentSetter = sprite.setVisible

  sprite._roxySceneStackVisibilityOwner = nil
  sprite._roxySceneStackWasVisible = nil
  sprite._roxySceneStackSavedSetVisible = nil
  sprite._roxySceneStackSetVisibleWasOwn = nil
  sprite._roxySceneStackSavedIsVisible = nil
  sprite._roxySceneStackIsVisibleWasOwn = nil

  if luaType(currentSetter) == "function" then
    currentSetter(sprite, desiredVisible)
  end

  if pruneList ~= false then
    _markSceneStackVisibilitySnapshotPruned(scene, sprite)
  end
end

-- ! Helper: Hide Scene Sprite For Stack
local function _hideSceneSpriteForStack(scene, sprite)
  if not scene or not sprite or sprite.scene ~= scene then return end

  if sprite._roxySceneStackVisibilityOwner == scene then
    local setter = sprite._roxySceneStackSavedSetVisible
    if luaType(setter) == "function" then setter(sprite, false) end
    return
  end

  local oldOwner = sprite._roxySceneStackVisibilityOwner
  if oldOwner then
    _clearSceneStackVisibilitySnapshot(oldOwner, sprite)
  end

  local ownSetVisible = rawGet(sprite, "setVisible")
  local ownIsVisible = rawGet(sprite, "isVisible")
  local setVisibleWasOwn = ownSetVisible ~= nil
  local isVisibleWasOwn = ownIsVisible ~= nil
  local savedSetVisible = setVisibleWasOwn and ownSetVisible or sprite.setVisible
  local savedIsVisible = isVisibleWasOwn and ownIsVisible or sprite.isVisible

  sprite._roxySceneStackVisibilityOwner = scene
  sprite._roxySceneStackWasVisible = _readSceneStackSpriteVisibility(sprite)
  sprite._roxySceneStackSavedSetVisible = savedSetVisible
  sprite._roxySceneStackSetVisibleWasOwn = setVisibleWasOwn
  sprite._roxySceneStackSavedIsVisible = savedIsVisible
  sprite._roxySceneStackIsVisibleWasOwn = isVisibleWasOwn

  rawSet(sprite, "setVisible", _sceneStackVisibilitySetVisible)
  rawSet(sprite, "isVisible", _sceneStackVisibilityIsVisible)

  local snapshotList = scene._sceneStackVisibilitySnapshotList
  if not snapshotList then
    snapshotList = {}
    scene._sceneStackVisibilitySnapshotList = snapshotList
  end
  snapshotList[#snapshotList + 1] = sprite

  if luaType(savedSetVisible) == "function" then
    savedSetVisible(sprite, false)
  end
end

-- ! Helper: Hide Scene Sprites For Stack
local function _hideSceneSpritesForStack(scene)
  if not scene then return end
  scene._sceneStackSpritesHidden = true

  if not scene._didEnter then return end

  local sprites = scene.sprites
  for i = #sprites, 1, -1 do
    _hideSceneSpriteForStack(scene, sprites[i])
  end
end

-- ! Helper: Restore Scene Sprites For Stack
local function _restoreSceneSpritesForStack(scene)
  if not scene then return end
  scene._sceneStackSpritesHidden = false

  local snapshotList = scene._sceneStackVisibilitySnapshotList
  if snapshotList then
    for i = #snapshotList, 1, -1 do
      local sprite = snapshotList[i]
      if sprite then _clearSceneStackVisibilitySnapshot(scene, sprite, false) end
    end
  end

  scene._sceneStackVisibilitySnapshotList = {}
end

-- ! Helper: Pause Scene Sprite
-- Snapshots update, collision, and playback state before any mutation.
local function _pauseSceneSprite(scene, sprite, pauseMask)
  if not sprite then return end

  pauseMask = pauseMask or getSpritePauseMask(sprite)
  if pauseMask == SCENE_PAUSE_NONE then return end

  local snapshots = scene._pauseSpriteSnapshots
  if not snapshots then
    snapshots = {}
    scene._pauseSpriteSnapshots = snapshots
  end
  local snapshot = snapshots[sprite]
  if snapshot then
    _applyScenePauseSprite(sprite, _scenePauseSnapshotMask(snapshot))
    return
  end

  if pauseMask == SCENE_PAUSE_ALL then
    local state = 0

    local getIsPaused = sprite.getIsPaused
    if getIsPaused ~= nil then
      local value = getIsPaused(sprite)
      if luaType(value) ~= "boolean" or value == false then state = state + SHOULD_PLAY end
    elseif luaType(sprite.isPaused) == "boolean" then
      if sprite.isPaused == false then state = state + SHOULD_PLAY end
    else
      state = state + SHOULD_PLAY
    end

    local updatesEnabled = sprite.updatesEnabled
    if updatesEnabled ~= nil then
      local value = updatesEnabled(sprite)
      if value ~= false and value ~= 0 then state = state + RESTORE_UPDATES end
    else
      state = state + RESTORE_UPDATES
    end

    local collisionsEnabled = sprite.collisionsEnabled
    if collisionsEnabled ~= nil then
      local value = collisionsEnabled(sprite)
      if value ~= false and value ~= 0 then state = state + RESTORE_COLLISIONS end
    else
      state = state + RESTORE_COLLISIONS
    end

    _storeScenePauseSnapshot(scene, sprite, pauseMask, state)

    local pause = sprite.pause
    if pause ~= nil then pause(sprite) end
    if (state & RESTORE_UPDATES) ~= 0 then
      local setter = sprite.setUpdatesEnabled
      if setter ~= nil then setter(sprite, false) end
    end
    if (state & RESTORE_COLLISIONS) ~= 0 then
      local sceneSetter = sprite._setScenePauseCollisionsActive
      if sceneSetter ~= nil then
        sceneSetter(sprite, false)
      else
        local setter = sprite.setCollisionsEnabled
        if setter ~= nil then setter(sprite, false) end
      end
    end
    return
  elseif pauseMask == SCENE_PAUSE_UPDATES then
    local state = 0
    local updatesEnabled = sprite.updatesEnabled
    if updatesEnabled ~= nil then
      local value = updatesEnabled(sprite)
      if value ~= false and value ~= 0 then state = RESTORE_UPDATES end
    else
      state = RESTORE_UPDATES
    end

    _storeScenePauseSnapshot(scene, sprite, pauseMask, state)
    if (state & RESTORE_UPDATES) ~= 0 then
      local setter = sprite.setUpdatesEnabled
      if setter ~= nil then setter(sprite, false) end
    end
    return
  elseif pauseMask == SCENE_PAUSE_COLLISIONS then
    local state = 0
    local collisionsEnabled = sprite.collisionsEnabled
    if collisionsEnabled ~= nil then
      local value = collisionsEnabled(sprite)
      if value ~= false and value ~= 0 then state = RESTORE_COLLISIONS end
    else
      state = RESTORE_COLLISIONS
    end

    _storeScenePauseSnapshot(scene, sprite, pauseMask, state)
    if (state & RESTORE_COLLISIONS) ~= 0 then
      local sceneSetter = sprite._setScenePauseCollisionsActive
      if sceneSetter ~= nil then
        sceneSetter(sprite, false)
      else
        local setter = sprite.setCollisionsEnabled
        if setter ~= nil then setter(sprite, false) end
      end
    end
    return
  end

  local state = _buildScenePauseState(sprite, pauseMask)
  _storeScenePauseSnapshot(scene, sprite, pauseMask, state)

  _applyScenePauseSprite(sprite, pauseMask, state)
end

-- ! Helper: Resume Scene Sprite
local function _resumeSceneSprite(scene, sprite, snapshot, pruneList)
  if not sprite then return end
  local snapshots = scene._pauseSpriteSnapshots
  snapshot = snapshot or (snapshots and snapshots[sprite])
  if not snapshot then return end

  local pauseMask = _scenePauseSnapshotMask(snapshot)
  if pauseMask == SCENE_PAUSE_NONE then
    _forgetScenePauseSnapshot(scene, sprite, pruneList)
    return
  end

  local state = _scenePauseSnapshotState(snapshot)
  if pauseMask == SCENE_PAUSE_ALL then
    if (state & SHOULD_PLAY) ~= 0 then
      local play = sprite.play
      if play ~= nil then play(sprite) end
    end
    local updateSetter = sprite.setUpdatesEnabled
    if updateSetter ~= nil then
      updateSetter(sprite, (state & RESTORE_UPDATES) ~= 0)
    end
    local sceneSetter = sprite._setScenePauseCollisionsActive
    if sceneSetter ~= nil then
      sceneSetter(sprite, (state & RESTORE_COLLISIONS) ~= 0)
    else
      local collisionSetter = sprite.setCollisionsEnabled
      if collisionSetter ~= nil then
        collisionSetter(sprite, (state & RESTORE_COLLISIONS) ~= 0)
      end
    end
  elseif pauseMask == SCENE_PAUSE_UPDATES then
    local setter = sprite.setUpdatesEnabled
    if setter ~= nil then setter(sprite, (state & RESTORE_UPDATES) ~= 0) end
  elseif pauseMask == SCENE_PAUSE_COLLISIONS then
    local sceneSetter = sprite._setScenePauseCollisionsActive
    if sceneSetter ~= nil then
      sceneSetter(sprite, (state & RESTORE_COLLISIONS) ~= 0)
    else
      local setter = sprite.setCollisionsEnabled
      if setter ~= nil then setter(sprite, (state & RESTORE_COLLISIONS) ~= 0) end
    end
  elseif pauseMask == SCENE_PAUSE_PLAYBACK then
    if (state & SHOULD_PLAY) ~= 0 then _runSpritePlay(sprite) end
  else
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
  end

  _forgetScenePauseSnapshot(scene, sprite, pruneList)
end

-- ! Helper: Pause Registered Scene Sprite
local function _pauseRegisteredSceneSprite(scene, sprite, pauseMask)
  pauseMask = pauseMask or getSpritePauseMask(sprite)
  if pauseMask ~= SCENE_PAUSE_NONE then _pauseSceneSprite(scene, sprite, pauseMask) end
end

-- ! Helper: Resume Registered Scene Sprite
local function _resumeRegisteredSceneSprite(scene, sprite, pruneList)
  _resumeSceneSprite(scene, sprite, nil, pruneList)
end

-- ! Helper: Restore Scene State Before Unregister
local function _restoreScenePauseBeforeUnregister(scene, sprite, pruneList)
  _clearSceneStackVisibilitySnapshot(scene, sprite, pruneList)
  _resumeRegisteredSceneSprite(scene, sprite, pruneList)
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
  if luaType(sequence.isPlaying) == "function" then
    return sequence:isPlaying() == true
  end
  if luaType(sequence.isRunning) == "boolean" then
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

  if shouldPause and luaType(sequence.pause) == "function" then
    sequence:pause()
  end
end

-- ! Helper: Resume Scene Sequence
-- Restores a sequence paused by the same scene
local function _resumeSceneSequence(scene, sequence)
  if not sequence or sequence._roxyScenePauseOwner ~= scene then return end

  local shouldResume = sequence._roxyScenePauseWasRunning ~= false
  if shouldResume and luaType(sequence.play) == "function" then
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
  self._pauseSpriteSnapshots = {}
  self._pauseSpriteSnapshotList = {}
  self._pausedHandlerPriority = nil
  self._pausedHandlerSeq = nil
  self._sceneStackSpritesHidden = false
  self._sceneStackVisibilitySnapshotList = {}
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
    if self._sceneStackSpritesHidden then
      _hideSceneSpriteForStack(self, sprite)
    end
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
    if luaType(tilemap) == "table" and luaType(tilemap.applyCameraBounds) == "function" then
      didApply = tilemap:applyCameraBounds() == true
    end
    if not didApply and luaType(tilemap) == "table" and luaType(tilemap.getCameraBounds) == "function" then
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
  local snapshots = {}
  local snapshotList = {}
  self._pauseSpriteSnapshots = snapshots
  self._pauseSpriteSnapshotList = snapshotList

  if self._roxyCameraActivated and snapshotCameraState then
    self._roxyScenePauseCameraSnapshot = snapshotCameraState()
  end

  local sprites = self.sprites
  local snapshotCount = 0
  local scenePauseAll = SCENE_PAUSE_ALL
  local scenePauseUpdates = SCENE_PAUSE_UPDATES
  local scenePauseCollisions = SCENE_PAUSE_COLLISIONS
  local scenePauseNone = SCENE_PAUSE_NONE
  local restoreUpdates = RESTORE_UPDATES
  local restoreCollisions = RESTORE_COLLISIONS
  local shouldPlay = SHOULD_PLAY
  local snapshotStateBits = SNAPSHOT_STATE_BITS
  local snapshotUpdatesOff = SNAPSHOT_UPDATES_OFF
  local snapshotUpdatesOn = SNAPSHOT_UPDATES_ON
  local snapshotCollisionsOff = SNAPSHOT_COLLISIONS_OFF
  local snapshotCollisionsOn = SNAPSHOT_COLLISIONS_ON
  -- Before enter(), tracked sprites are only queued and sprite:add() has not
  -- run. Skip sprite pause work so enter() snapshots after add; once entered,
  -- keep the loop free of queued-state checks and trust scene ownership.
  if self._didEnter then
    for i = #sprites, 1, -1 do
      local sprite = sprites[i]
      local pauseMask = sprite._roxyScenePauseMask
      if pauseMask == nil then
        pauseMask = scenePauseAll
      end

      if pauseMask == scenePauseAll then
        local state = 0

        local getIsPaused = sprite.getIsPaused
        if getIsPaused ~= nil then
          local value = getIsPaused(sprite)
          if value ~= true then state = state + shouldPlay end
        else
          if sprite.isPaused ~= true then state = state + shouldPlay end
        end

        local updatesEnabled = sprite.updatesEnabled
        if updatesEnabled ~= nil then
          local value = updatesEnabled(sprite)
          if value ~= false and value ~= 0 then state = state + restoreUpdates end
        else
          state = state + restoreUpdates
        end

        local collisionsEnabled = sprite.collisionsEnabled
        if collisionsEnabled ~= nil then
          local value = collisionsEnabled(sprite)
          if value ~= false and value ~= 0 then state = state + restoreCollisions end
        else
          state = state + restoreCollisions
        end

        local snapshot = (pauseMask << snapshotStateBits) + state
        snapshots[sprite] = snapshot
        snapshotCount = snapshotCount + 1
        snapshotList[snapshotCount] = sprite

        local pause = sprite.pause
        if pause ~= nil then pause(sprite) end
        if (state & restoreUpdates) ~= 0 then
          local setter = sprite.setUpdatesEnabled
          if setter ~= nil then setter(sprite, false) end
        end
        if (state & restoreCollisions) ~= 0 then
          local sceneSetter = sprite._setScenePauseCollisionsActive
          if sceneSetter ~= nil then
            sceneSetter(sprite, false)
          else
            local setter = sprite.setCollisionsEnabled
            if setter ~= nil then setter(sprite, false) end
          end
        end
      elseif pauseMask == scenePauseUpdates then
        local state = 0
        local updatesEnabled = sprite.updatesEnabled
        if updatesEnabled ~= nil then
          local value = updatesEnabled(sprite)
          if value ~= false and value ~= 0 then state = restoreUpdates end
        else
          state = restoreUpdates
        end

        local snapshot = state ~= 0 and snapshotUpdatesOn or snapshotUpdatesOff
        snapshots[sprite] = snapshot
        snapshotCount = snapshotCount + 1
        snapshotList[snapshotCount] = sprite

        if state ~= 0 then
          local setter = sprite.setUpdatesEnabled
          if setter ~= nil then setter(sprite, false) end
        end
      elseif pauseMask == scenePauseCollisions then
        local state = 0
        local collisionsEnabled = sprite.collisionsEnabled
        if collisionsEnabled ~= nil then
          local value = collisionsEnabled(sprite)
          if value ~= false and value ~= 0 then state = restoreCollisions end
        else
          state = restoreCollisions
        end

        local snapshot = state ~= 0 and snapshotCollisionsOn or snapshotCollisionsOff
        snapshots[sprite] = snapshot
        snapshotCount = snapshotCount + 1
        snapshotList[snapshotCount] = sprite

        if state ~= 0 then
          local sceneSetter = sprite._setScenePauseCollisionsActive
          if sceneSetter ~= nil then
            sceneSetter(sprite, false)
          else
            local setter = sprite.setCollisionsEnabled
            if setter ~= nil then setter(sprite, false) end
          end
        end
      elseif pauseMask ~= scenePauseNone then
        _pauseSceneSprite(self, sprite, pauseMask)
        snapshotCount = #snapshotList
      end
    end
  end

  -- Disable sequences from updating
  local sequences = self.sequences
  for i = #sequences, 1, -1 do
    _pauseSceneSequence(self, sequences[i])
  end

  -- Capture registration metadata so resume() can reinstate precedence.
  -- removeHandler discards the record, so lifecycle restoration must recover
  -- the sequence without overwriting an explicit paused-time registration.
  self._pausedHandlerPriority, self._pausedHandlerSeq = getHandlerRegistration(self)
  removeHandler(self)
end

-- ! Resume
function RoxyScene:resume()
  if not self.isPaused then return end
  Log.debug("[RoxyScene:resume] Resuming Scene: " .. self.name) --#DEBUG
  self.isPaused = false

  local snapshots = self._pauseSpriteSnapshots
  local snapshotList = self._pauseSpriteSnapshotList
  local scenePauseAll = SCENE_PAUSE_ALL
  local scenePauseUpdates = SCENE_PAUSE_UPDATES
  local scenePauseCollisions = SCENE_PAUSE_COLLISIONS
  local scenePausePlayback = SCENE_PAUSE_PLAYBACK
  local restoreUpdates = RESTORE_UPDATES
  local restoreCollisions = RESTORE_COLLISIONS
  local shouldPlay = SHOULD_PLAY
  local snapshotStateMask = SNAPSHOT_STATE_MASK
  local snapshotStateBits = SNAPSHOT_STATE_BITS
  local snapshotUpdatesOff = SNAPSHOT_UPDATES_OFF
  local snapshotUpdatesOn = SNAPSHOT_UPDATES_ON
  local snapshotCollisionsOff = SNAPSHOT_COLLISIONS_OFF
  local snapshotCollisionsOn = SNAPSHOT_COLLISIONS_ON
  local snapshotAllBase = SNAPSHOT_ALL_BASE
  for i = #snapshotList, 1, -1 do
    local sprite = snapshotList[i]
    local snapshot = snapshots[sprite]
    if snapshot then
      repeat
        if snapshot < snapshotAllBase then
          if snapshot == snapshotCollisionsOn or snapshot == snapshotCollisionsOff then
            local restoreActive = snapshot == snapshotCollisionsOn
            local sceneSetter = sprite._setScenePauseCollisionsActive
            if sceneSetter ~= nil then
              sceneSetter(sprite, restoreActive)
            else
              local setter = sprite.setCollisionsEnabled
              if setter ~= nil then setter(sprite, restoreActive) end
            end
            snapshots[sprite] = nil
            break
          elseif snapshot == snapshotUpdatesOn or snapshot == snapshotUpdatesOff then
            local setter = sprite.setUpdatesEnabled
            if setter ~= nil then setter(sprite, snapshot == snapshotUpdatesOn) end
            snapshots[sprite] = nil
            break
          end
        end

        local pauseMask = snapshot >> snapshotStateBits
        local state = snapshot & snapshotStateMask

        if pauseMask == scenePauseAll then
          if (state & shouldPlay) ~= 0 then
            local play = sprite.play
            if play ~= nil then play(sprite) end
          end
          local updateSetter = sprite.setUpdatesEnabled
          if updateSetter ~= nil then
            updateSetter(sprite, (state & restoreUpdates) ~= 0)
          end
          local sceneSetter = sprite._setScenePauseCollisionsActive
          if sceneSetter ~= nil then
            sceneSetter(sprite, (state & restoreCollisions) ~= 0)
          else
            local collisionSetter = sprite.setCollisionsEnabled
            if collisionSetter ~= nil then
              collisionSetter(sprite, (state & restoreCollisions) ~= 0)
            end
          end
          snapshots[sprite] = nil
        elseif pauseMask == scenePauseUpdates then
          local setter = sprite.setUpdatesEnabled
          if setter ~= nil then setter(sprite, (state & restoreUpdates) ~= 0) end
          snapshots[sprite] = nil
        elseif pauseMask == scenePauseCollisions then
          local sceneSetter = sprite._setScenePauseCollisionsActive
          if sceneSetter ~= nil then
            sceneSetter(sprite, (state & restoreCollisions) ~= 0)
          else
            local setter = sprite.setCollisionsEnabled
            if setter ~= nil then setter(sprite, (state & restoreCollisions) ~= 0) end
          end
          snapshots[sprite] = nil
        elseif pauseMask == scenePausePlayback then
          if (state & shouldPlay) ~= 0 then
            local play = sprite.play
            if play ~= nil then play(sprite) end
          end
          snapshots[sprite] = nil
        else
          _resumeSceneSprite(self, sprite, snapshot, false)
        end
      until true
    end
  end
  self._pauseSpriteSnapshots = {}
  self._pauseSpriteSnapshotList = {}

  -- Enable sequences for updating
  local sequences = self.sequences
  for i = #sequences, 1, -1 do
    _resumeSceneSequence(self, sequences[i])
  end

  if self._roxyScenePauseCameraSnapshot and restoreCameraState then
    restoreCameraState(self._roxyScenePauseCameraSnapshot)
    self._roxyScenePauseCameraSnapshot = nil
  end

  -- Reconcile only when pause() captured a registration. A missing owner is
  -- restored from the snapshot; an explicit paused-time registration keeps its
  -- handler and priority while recovering captured sequence precedence. A nil
  -- sequence means the scene was not registered at pause time, so resume leaves
  -- any current registration untouched.
  local pausedPriority, pausedSeq = self._pausedHandlerPriority, self._pausedHandlerSeq
  self._pausedHandlerPriority, self._pausedHandlerSeq = nil, nil
  if pausedSeq then
    self:_restoreHandler(pausedPriority, pausedSeq)
  end
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
  self._sceneStackSpritesHidden = false
  self._sceneStackVisibilitySnapshotList = {}
  self._pausedHandlerPriority = nil
  self._pausedHandlerSeq = nil

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

-- ! Sprite Pause Classification Did Change
function RoxyScene:_spritePauseClassificationDidChange(sprite, oldMask, newMask)
  if oldMask == newMask then return end
  if not sprite or sprite.scene ~= self or self._spriteSet[sprite] ~= true then return end
  if not self.isPaused then return end
  if not self._didEnter or self._spriteAutoAddIndex[sprite] ~= nil then return end

  _resumeSceneSprite(self, sprite)

  if newMask ~= SCENE_PAUSE_NONE then
    _pauseSceneSprite(self, sprite, newMask)
  end
end

-- ! Set Scene Stack Sprites Hidden
function RoxyScene:_setSceneStackSpritesHidden(hidden)
  if hidden == true then
    _hideSceneSpritesForStack(self)
  else
    _restoreSceneSpritesForStack(self)
  end
end

-- ! Add Sprite
function RoxyScene:addSprite(sprite)
  if not sprite then return end

  if self._spriteSet[sprite] == true then
    local isTracked = _hasIndexed(self.sprites, self._spriteIndex, sprite)
    local isQueued = self._didEnter or _hasIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
    if sprite.scene == self and isTracked and isQueued then
      return
    end

    _restoreScenePauseBeforeUnregister(self, sprite, false)
    _removeIndexed(self.sprites, self._spriteIndex, sprite)
    _removeIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
    self._spriteSet[sprite] = nil
  end

  local currentScene = sprite.scene
  if currentScene ~= nil and currentScene ~= self and luaType(currentScene) == "table" then
    if luaType(currentScene._unregisterSprite) == "function" then
      currentScene:_unregisterSprite(sprite, true)
    elseif luaType(currentScene.removeSprite) == "function" then
      currentScene:removeSprite(sprite)
    end
  end

  -- Give the sprite a back-pointer so it can self-remove later
  sprite.scene = self

  _appendIndexed(self.sprites, self._spriteIndex, sprite)
  self._spriteSet[sprite] = true

  if self._didEnter then
    -- Scene is active -- attach immediately
    sprite:add()
    if self._sceneStackSpritesHidden then
      _hideSceneSpriteForStack(self, sprite)
    end
  else
    -- Scene isn't active yet -- queue for enter()
    _appendIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
  end

  if self.isPaused and self._didEnter then
    _pauseRegisteredSceneSprite(self, sprite)
  end
end

-- ! Remove Sprite
function RoxyScene:removeSprite(sprite)
  self:_unregisterSprite(sprite, true)
end

-- ! Unregister Sprite
-- Private cleanup path used by tilemaps and direct scene sprite removal
function RoxyScene:_unregisterSprite(sprite, removeFromDisplay)
  if not sprite then return end

  local wasSelfOwnedAtEntry = sprite.scene == self

  _restoreScenePauseBeforeUnregister(self, sprite)

  -- Remove only this scene's ownership state
  -- Direct external writes to scene.sprites are unsupported, but removeAllSprites remains tolerant.
  _removeIndexed(self.sprites, self._spriteIndex, sprite)
  _removeIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
  self._spriteSet[sprite] = nil

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

    _restoreScenePauseBeforeUnregister(self, sprite, false)

    _removeIndexed(self.sprites, self._spriteIndex, sprite)
    _removeIndexed(self._spriteAutoAddQueue, self._spriteAutoAddIndex, sprite)
    self._spriteSet[sprite] = nil

    if wasSelfOwnedAtEntry and sprite.scene == self then
      sprite.scene = nil -- Clear back-pointer
    end

    if shouldRemove and wasSelfOwnedAtEntry then
      sprite:remove()
    end
  end
  _pruneScenePauseSnapshotList(self, targets)
  _pruneSceneStackVisibilitySnapshotList(self, targets)
end

-- ! Remove All Sprites
function RoxyScene:removeAllSprites()
  local sprites = self.sprites
  local wasStackHidden = self._sceneStackSpritesHidden == true

  self.sprites = {}
  self._spriteSet = {}
  self._spriteIndex = {}
  self._spriteAutoAddQueue = {}
  self._spriteAutoAddIndex = {}

  for i = #sprites, 1, -1 do
    local sprite = sprites[i]
    _restoreScenePauseBeforeUnregister(self, sprite, false)
    if sprite.scene == self then
      sprite.scene = nil -- Clear back-pointer
    end
  end
  self._pauseSpriteSnapshots = {}
  self._pauseSpriteSnapshotList = {}
  self._sceneStackSpritesHidden = wasStackHidden
  self._sceneStackVisibilitySnapshotList = {}

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

  if luaType(tilemap.attachToScene) ~= "function" then
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

  if luaType(tilemap.destroy) ~= "function" then
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

  if luaType(tilemap.detachFromScene) ~= "function" then
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
    if luaType(tilemap.destroy) == "function" then
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
  if inputHandler and (luaType(inputHandler) == "table" or luaType(inputHandler) == "function") then
    addHandler(self, inputHandler, 0)
  end
end

-- ! Restore Input Handler (internal)
-- Lifecycle-only: restores missing captured state or reconciles the captured
-- sequence with an explicit paused-time handler and priority.
function RoxyScene:_restoreHandler(priority, seq)
  -- Prefer a handler explicitly registered while paused. The scene property may
  -- have changed or been cleared, but the live registry entry remains valid.
  local _, registeredSeq, registeredHandler = getHandlerRegistration(self)
  local inputHandler = self.inputHandler
  if registeredSeq ~= nil then inputHandler = registeredHandler end
  if inputHandler and (luaType(inputHandler) == "table" or luaType(inputHandler) == "function") then
    restoreHandler(self, inputHandler, priority or 0, seq)
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

RoxyScene owns scene lifecycle, input, sprites, tilemaps, sequences, camera setup, stack visibility, and pause state.

-- Gameplay Scene
local Graphics <const> = playdate.graphics

local COLOR_WHITE <const> = Graphics.kColorWhite

class("GameplayScene").extends(RoxyScene)

function GameplayScene:init()
  GameplayScene.super.init(self, COLOR_WHITE)
  self.blocksLowerDraw = true

  self.inputHandler = {
    BButtonDown = function()
      roxy.Scene.pushScene(PauseScene)
    end,
  }
end

function GameplayScene:start()
  GameplayScene.super.start(self)

  self.player = RoxySprite({ name = "player" })
  self.player:setPauseClassification(nil) -- Default dynamic pause behavior
  self:addSprite(self.player)

  self.marker = Graphics.sprite.new()
  roxy.Scene.setSpritePauseClassification(self.marker, {})
  self:addSprite(self.marker)

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
  self.marker = nil
  self.map = nil
  self.fadeIn = nil
end

-- Overlay Scene
local pauseScene = RoxyScene(Graphics.kColorBlack)
pauseScene.isVisible = true
pauseScene.blocksLowerDraw = false -- Keep lower draw and scene-owned sprites visible
pauseScene.updateBackground = true

-- Full-Screen Pushed Scene
local inventoryScene = RoxyScene(COLOR_WHITE)
inventoryScene.blocksLowerDraw = true -- Hide lower draw and scene-owned sprites

-- Manual Ownership
local scene = RoxyScene()
local player = RoxySprite({ name = "player" })
local tilemap = RoxyOrthoTilemap("assets/maps/level-01.json")

scene:addSprite(player)
scene:addTilemap(tilemap) -- Tilemap sprites classify their own pause behavior
scene:activateCamera({ tilemap = tilemap, target = player })

scene:detachTilemap(tilemap)
scene:removeSprite(player)
scene:cleanup()

--]]
