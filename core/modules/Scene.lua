-- core/modules/Scene.lua

roxy = roxy or {}
roxy.Scene = roxy.Scene or {}
local Scene <const> = roxy.Scene

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local getDisplayImage <const> = Graphics.getDisplayImage

local setBackgroundDrawing  <const> = Sprite.setBackgroundDrawingCallback
local redrawBackground      <const> = Sprite.redrawBackground

-- Cache base scene class draw if available
local BaseSceneDraw <const> = (rawget(_G, "RoxyScene") and RoxyScene.draw) or nil

local MAX_SCENE_DEPTH <const> = 32

local SCENE_PAUSE_NONE        <const> = 0
local SCENE_PAUSE_PLAYBACK    <const> = 1
local SCENE_PAUSE_UPDATES     <const> = 2
local SCENE_PAUSE_COLLISIONS  <const> = 4
local SCENE_PAUSE_ALL         <const> = SCENE_PAUSE_PLAYBACK + SCENE_PAUSE_UPDATES + SCENE_PAUSE_COLLISIONS

-- Shared no-op function to avoid per-activation allocations
local NO_OP_BG_DRAW <const> = function(x, y, width, height) end

-- Global
Scene.currentScene            = nil
Scene._SCENE_PAUSE_NONE       = SCENE_PAUSE_NONE
Scene._SCENE_PAUSE_PLAYBACK   = SCENE_PAUSE_PLAYBACK
Scene._SCENE_PAUSE_UPDATES    = SCENE_PAUSE_UPDATES
Scene._SCENE_PAUSE_COLLISIONS = SCENE_PAUSE_COLLISIONS
Scene._SCENE_PAUSE_ALL        = SCENE_PAUSE_ALL

-- Local
local scenes
local stack
local updateList
local bgList
local drawList
local stackHiddenScenes
local stackHiddenSceneList

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

-- ! Utility: Get Sprite Pause Mask
-- Internal helper; mask values are an implementation detail, not public API.
function Scene._getSpritePauseMask(sprite)
  if not sprite then return SCENE_PAUSE_NONE end

  local mask = sprite._roxyScenePauseMask
  if mask == nil then return SCENE_PAUSE_ALL end
  return mask
end

-- ! Utility: Set Sprite Pause Classification
function Scene.setSpritePauseClassification(sprite, opts)
  if not sprite then return nil end

  local oldMask = Scene._getSpritePauseMask(sprite)
  local newMask = nil

  if opts == nil then
    sprite._roxyScenePauseMask = nil
    newMask = SCENE_PAUSE_ALL
  else
    if type(opts) ~= "table" then
      error("[Scene.setSpritePauseClassification] Expected table or nil", 3)
    end

    local playback = opts.playback
    local updates = opts.updates
    local collisions = opts.collisions

    -- Validate in all builds; silent coercion makes pause state difficult to trace.
    if playback ~= nil and type(playback) ~= "boolean" then
      error("[Scene.setSpritePauseClassification] playback must be a boolean when supplied", 3)
    end
    if updates ~= nil and type(updates) ~= "boolean" then
      error("[Scene.setSpritePauseClassification] updates must be a boolean when supplied", 3)
    end
    if collisions ~= nil and type(collisions) ~= "boolean" then
      error("[Scene.setSpritePauseClassification] collisions must be a boolean when supplied", 3)
    end

    newMask = SCENE_PAUSE_NONE
    if playback == true then newMask = newMask + SCENE_PAUSE_PLAYBACK end
    if updates == true then newMask = newMask + SCENE_PAUSE_UPDATES end
    if collisions == true then newMask = newMask + SCENE_PAUSE_COLLISIONS end
    sprite._roxyScenePauseMask = newMask
  end

  if oldMask ~= newMask then
    local scene = sprite.scene
    if scene and type(scene._spritePauseClassificationDidChange) == "function" then
      scene:_spritePauseClassificationDidChange(sprite, oldMask, newMask)
    end
  end

  return sprite
end

-- ! Utility: Set Scene Stack Sprites Hidden
local function setSceneStackSpritesHidden(scene, hidden)
  local setter = scene and scene._setSceneStackSpritesHidden
  if type(setter) == "function" then
    setter(scene, hidden == true)
  end
end

-- ! Utility: Restore All Stack Hidden Scenes
local function restoreAllStackHiddenScenes()
  local hiddenList = stackHiddenSceneList
  if hiddenList then
    for i = #hiddenList, 1, -1 do
      local scene = hiddenList[i]
      if scene then
        setSceneStackSpritesHidden(scene, false)
      end
    end
  end

  stackHiddenScenes = {}
  stackHiddenSceneList = {}
end

-- ! Utility: Sync Stack Sprite Visibility
local function syncStackSpriteVisibility(sceneStack, depth)
  local blockingIndex = nil

  for i = depth, 1, -1 do
    local scene = sceneStack[i]
    if scene and scene.blocksLowerDraw == true then
      blockingIndex = i
      break
    end
  end

  local nextHiddenScenes = {}
  local nextHiddenSceneList = {}
  local nextHiddenCount = 0
  local hideThrough = blockingIndex and blockingIndex - 1 or 0

  for i = 1, hideThrough do
    local scene = sceneStack[i]
    if scene and nextHiddenScenes[scene] ~= true then
      nextHiddenScenes[scene] = true
      nextHiddenCount += 1
      nextHiddenSceneList[nextHiddenCount] = scene

      if not stackHiddenScenes or stackHiddenScenes[scene] ~= true then
        setSceneStackSpritesHidden(scene, true)
      end
    end
  end

  local hiddenList = stackHiddenSceneList
  if hiddenList then
    for i = #hiddenList, 1, -1 do
      local scene = hiddenList[i]
      if scene and nextHiddenScenes[scene] ~= true then
        setSceneStackSpritesHidden(scene, false)
      end
    end
  end

  stackHiddenScenes = nextHiddenScenes
  stackHiddenSceneList = nextHiddenSceneList

  return blockingIndex or 1
end

-- ! Utility: Rebuild Lists
-- Rebuilds the update lists based on the current stack.
local function rebuildLists()
  local currentScene = Scene.currentScene
  local updateCount, bgCount = 0, 0 -- Counters for update lists
  local drawCount = 0 -- Counter for draw list

  -- Localize frequently used references for speed
  local sceneStack = stack
  local uList = updateList
  local bList = bgList
  local dList = drawList
  local depth = #sceneStack
  local startIndex = syncStackSpriteVisibility(sceneStack, depth)

  -- Early out for empty stack
  if depth == 0 then
    -- Trim tails in case previous state left items in the lists
    if #uList > 0 then for i = 1, #uList do uList[i] = nil end end
    if #bList > 0 then for i = 1, #bList do bList[i] = nil end end
    if #dList > 0 then for i = 1, #dList do dList[i] = nil end end
    Log.debug("[Scene.rebuildLists] update=0 bg=0 draw=0") --#DEBUG
    return
  end

  -- (1) Build update and background lists
  for i = 1, depth do
    local scene = sceneStack[i]
    if scene == currentScene or scene.alwaysUpdate then
      updateCount += 1
      uList[updateCount] = scene
    elseif scene.updateBackground then
      bgCount += 1
      bList[bgCount] = scene
    end
  end

  -- (2) Build draw list honoring scene stacking rules
  -- Collect visible scenes from startIndex --> top (bottom-to-top draw order)
  for i = startIndex, depth do
    local scene = sceneStack[i]
    if scene and scene.isVisible ~= false then
      -- Only include scenes that override draw (skip base no-op)
      local cls = getmetatable(scene)
      cls = cls and cls.__index or nil -- Class table for this instance
      local fn = cls and cls.draw or nil -- Resolved draw for this class
      local include = false

      if type(fn) == "function" then
        if BaseSceneDraw then
          include = (fn ~= BaseSceneDraw) -- Different from base no-op
        else
          include = true -- Fallback if base unknown
        end
      end

      if include then
        drawCount += 1
        dList[drawCount] = scene
      end
    end
  end

  -- (3) Trim tails
  local uLen = #uList
  local bLen = #bList
  local dLen = #dList

  if updateCount < uLen then
    for i = updateCount + 1, uLen do uList[i] = nil end
  end
  if bgCount < bLen then
    for i = bgCount + 1, bLen do bList[i] = nil end
  end
  if drawCount < dLen then
    for i = drawCount + 1, dLen do dList[i] = nil end
  end

  Log.debug("[Scene.rebuildLists] update=" .. updateCount .. " bg=" .. bgCount .. " draw=" .. drawCount) --#DEBUG
end

-- ! Utility: Activate Scene
-- Sets up the background callback for the provided scene.
local function activateScene(scene)
  Scene.currentScene = scene
  if scene then
    scene:enter()
    local backgroundDrawFn = scene.backgroundDrawFn or NO_OP_BG_DRAW
    setBackgroundDrawing(backgroundDrawFn)
    redrawBackground()
    scene:start()
  end
end

--------------------------------------------------------------------------------
-- ! Initialize Scene module
--------------------------------------------------------------------------------

function Scene.init()
  restoreAllStackHiddenScenes()

  -- Clear registered scenes, stack and lists
  scenes = {}     -- Registered scenes
  stack = {}      -- Scene stack
  updateList = {} -- Pre-filtered update list
  bgList = {}     -- Pre-filtered bg update lists
  drawList = {}   -- Pre-filtered draw list
  stackHiddenScenes = {}
  stackHiddenSceneList = {}

  Scene.currentScene = nil -- Currently active scene (top of stack)

  rebuildLists()
end

--------------------------------------------------------------------------------
-- Scene Registration
--------------------------------------------------------------------------------

-- ! Register Scenes
function Scene.registerScenes(...)
  local args = { ... }
  local argCount = #args

  -- Case 1: registerScenes("name", sceneTable)
  if argCount == 2 then
    local sceneName, sceneTable = args[1], args[2]

    if type(sceneName) ~= "string" then
      error("[Scene.registerScenes] First argument must be a string scene name.", 2) --#DEBUG
      return
    end
    if type(sceneTable) ~= "table" then
      error("[Scene.registerScenes] Second argument must be a table.", 2) --#DEBUG
      return
    end

    scenes[sceneName] = sceneTable
    return
  end

  -- Case 2: registerScenes({ name1 = table1, name2 = table2, ... })
  if argCount == 1 then
    local sceneTable = args[1]

    if type(sceneTable) ~= "table" then
      error("[Scene.registerScenes] Single argument must be a table of scenes.", 2) --#DEBUG
      return
    end

    for name, table in pairs(sceneTable) do
      -- TODO: Should the if statement be removed from release build or just the error log?
      if type(name) ~= "string" then
        error("[Scene.registerScenes] Skipping scene - key is not a string.", 2) --#DEBUG
        return
      elseif type(table) ~= "table" then
        error("[Scene.registerScenes] Skipping scene '" .. tostring(name) .. "' - value is not a table.", 2) --#DEBUG
        return
      else
        scenes[name] = table
      end
    end
    return
  end

  error("[Scene.registerScenes] Invalid parameters to roxy.Scene.registerScenes.", 2) --#DEBUG
end

--------------------------------------------------------------------------------
-- Scene Stack Management
--------------------------------------------------------------------------------

-- ! Replace Scene Raw
function Scene.replaceRaw(newScene)
  if type(newScene) ~= "table" then
    error("[Scene.replaceRaw] A valid scene table must be provided.", 2) --#DEBUG
    return
  end

  -- Clear every scene currently on the stack
  for i = #stack, 1, -1 do
    stack[i] = nil
  end
  -- Make new scene the sole occupant
  stack[1] = newScene
  Scene.currentScene = newScene
  rebuildLists()

  Log.debug("[Scene.replaceRaw] Stack cleared. Set '" .. (newScene.name or "Unnamed") .. "' as sole scene.") --#DEBUG
end

-- ! Replace Scene
function Scene.replaceScene(newScene)
  if type(newScene) ~= "table" then
    error("[Scene.replaceScene] A valid scene table must be provided.", 2) --#DEBUG
    return
  end

  -- Exit and cleanup all scenes on the stack before replacing
  for i = #stack, 1, -1 do
    local scene = stack[i]
    if scene then
      scene:exit()
      scene:cleanup()
    end
  end

  Scene.replaceRaw(newScene)
  activateScene(newScene)
end

-- ! Push Scene Raw
function Scene.pushRaw(newScene)
  if type(newScene) ~= "table" then
    error("[Scene.pushRaw] A valid scene table must be provided.", 2) --#DEBUG
    return
  end

  -- Soft stack overflow cap
  if #stack >= MAX_SCENE_DEPTH then
    error("[Scene.pushRaw] Stack depth exceeded (limit: " .. MAX_SCENE_DEPTH .. ")", 2) --#DEBUG
    return
  end

  stack[#stack+1] = newScene
  Scene.currentScene = newScene
  rebuildLists()

  Log.debug("[Scene.pushRaw] Pushing Scene " .. (newScene.name or "Unnamed")) --#DEBUG
end

-- ! Push Scene
function Scene.pushScene(newScene)
  if type(newScene) ~= "table" then
    error("[Scene.pushScene] A valid scene table must be provided.", 2) --#DEBUG
    return
  end

  local oldScene = Scene.currentScene
  if oldScene then
    oldScene:pause()
  end

  Scene.pushRaw(newScene)
  activateScene(newScene)
end

-- ! Pop Scene Raw
function Scene.popRaw()
  local depth = #stack
  if depth == 0 then
    Log.warn("[Scene.popRaw] Stack already empty.") --#DEBUG
    Scene.currentScene = nil
    rebuildLists()
    return
  end

  local popped = stack[depth]
  stack[depth] = nil
  Scene.currentScene = stack[#stack] -- Now top
  rebuildLists()

  Log.debug("[Scene.popRaw] Popping Scene " .. (popped.name or "Unnamed")) --#DEBUG

  return popped
end

-- ! Pop Scene
function Scene.popScene()
  local oldScene = Scene.popRaw()

  if oldScene then
    oldScene:exit()
    oldScene:cleanup()
  end

  local newScene = Scene.currentScene
  if newScene then
    newScene:resume()
  end

  activateScene(newScene)
end

-- ! Invalidate Lists
-- Public access to rebuild lists utility
function Scene.invalidateLists()
  rebuildLists()
end

--------------------------------------------------------------------------------
-- Scene State / Getters
--------------------------------------------------------------------------------

-- ! Get Current Scene
function Scene.getCurrentScene()
  return Scene.currentScene
end

-- ! Set Current Scene
function Scene.setCurrentScene(scene)
  Scene.replaceScene(scene)
end

-- ! Get Stack Depth
function Scene.getStackDepth()
  return #stack
end

-- ! Get Update List
function Scene.getUpdateList()
  return updateList
end

-- ! Get Background List
function Scene.getBackgroundList()
  return bgList
end

-- ! Get Draw List
-- Returns the cached draw list honoring blocksLowerDraw and isVisible flags.
function Scene.getDrawList()
  return drawList
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

Scene manages registration, stack flow, stack visibility, background updates, and sprite pause classification.

-- Register and Start Scenes
Scene.init()
Scene.registerScenes({
  Title     = TitleScene,
  Gameplay  = GameplayScene,
  Pause     = PauseScene,
  Inventory = InventoryScene,
})

Scene.replaceScene(TitleScene)

-- Stack Overlay and Full-Screen Scenes
PauseScene.blocksLowerDraw = false -- Keep lower draw and scene-owned sprites visible
Scene.pushScene(PauseScene)
local currentScene = Scene.getCurrentScene()
local depth = Scene.getStackDepth()
Scene.popScene()

InventoryScene.blocksLowerDraw = true -- Hide lower draw and scene-owned sprites
Scene.pushScene(InventoryScene)
Scene.popScene()

-- Keep a Background Scene Updating
GameplayScene.alwaysUpdate = true
GameplayScene.updateBackground = true
Scene.invalidateLists()

-- Classify Sprites for Scene Pause
local player = RoxySprite({ name = "player" })
player:setPauseClassification(nil) -- Default dynamic behavior

local decoration = playdate.graphics.sprite.new()
Scene.setSpritePauseClassification(decoration, {}) -- Static; skip pause/resume work

local parallaxLayer = playdate.graphics.sprite.new()
Scene.setSpritePauseClassification(parallaxLayer, { updates = true })

local wall = playdate.graphics.sprite.new()
Scene.setSpritePauseClassification(wall, { collisions = true })

-- Manual Loop Integration
for _, scene in ipairs(Scene.getUpdateList()) do
  scene:update(dt)
end

for _, scene in ipairs(Scene.getDrawList()) do
  scene:draw(dt)
end

--]]
