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
      Log.error("[Scene.setSpritePauseClassification] Expected table or nil", 2)
    end

    local playback = opts.playback
    local updates = opts.updates
    local collisions = opts.collisions

    -- Validate in all builds; silent coercion makes pause state difficult to trace.
    if playback ~= nil and type(playback) ~= "boolean" then
      Log.error("[Scene.setSpritePauseClassification] playback must be a boolean when supplied", 2)
    end
    if updates ~= nil and type(updates) ~= "boolean" then
      Log.error("[Scene.setSpritePauseClassification] updates must be a boolean when supplied", 2)
    end
    if collisions ~= nil and type(collisions) ~= "boolean" then
      Log.error("[Scene.setSpritePauseClassification] collisions must be a boolean when supplied", 2)
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

if type(Sprite.setPauseClassification) ~= "function" then
  function Sprite:setPauseClassification(opts)
    return Scene.setSpritePauseClassification(self, opts)
  end
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
  -- Find the highest scene that blocks lower draw, scanning from top downward.
  local startIndex = 1
  for i = depth, 1, -1 do
    local scene = sceneStack[i]
    if scene and scene.blocksLowerDraw == true then
      startIndex = i
      break
    end
  end

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
  -- Clear registered scenes, stack and lists
  scenes = {}     -- Registered scenes
  stack = {}      -- Scene stack
  updateList = {} -- Pre-filtered update list
  bgList = {}     -- Pre-filtered bg update lists
  drawList = {}   -- Pre-filtered draw list

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
      Log.error("[Scene.registerScenes] First argument must be a string scene name.", 2) --#DEBUG
      return
    end
    if type(sceneTable) ~= "table" then
      Log.error("[Scene.registerScenes] Second argument must be a table.", 2) --#DEBUG
      return
    end

    scenes[sceneName] = sceneTable
    return
  end

  -- Case 2: registerScenes({ name1 = table1, name2 = table2, ... })
  if argCount == 1 then
    local sceneTable = args[1]

    if type(sceneTable) ~= "table" then
      Log.error("[Scene.registerScenes] Single argument must be a table of scenes.", 2) --#DEBUG
      return
    end

    for name, table in pairs(sceneTable) do
      -- TODO: Should the if statement be removed from release build or just the error log?
      if type(name) ~= "string" then
        Log.error("[Scene.registerScenes] Skipping scene - key is not a string.", 2) --#DEBUG
        return
      elseif type(table) ~= "table" then
        Log.error("[Scene.registerScenes] Skipping scene '" .. tostring(name) .. "' - value is not a table.", 2) --#DEBUG
        return
      else
        scenes[name] = table
      end
    end
    return
  end

  Log.error("[Scene.registerScenes] Invalid parameters to roxy.Scene.registerScenes.", 2) --#DEBUG
end

--------------------------------------------------------------------------------
-- Scene Stack Management
--------------------------------------------------------------------------------

-- ! Replace Scene Raw
function Scene.replaceRaw(newScene)
  if type(newScene) ~= "table" then
    Log.error("[Scene.replaceRaw] A valid scene table must be provided.", 2) --#DEBUG
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
    Log.error("[Scene.replaceScene] A valid scene table must be provided.", 2) --#DEBUG
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
    Log.error("[Scene.pushRaw] A valid scene table must be provided.", 2) --#DEBUG
    return
  end

  -- Soft stack overflow cap
  if #stack >= MAX_SCENE_DEPTH then
    Log.error("[Scene.pushRaw] Stack depth exceeded (limit: " .. MAX_SCENE_DEPTH .. ")", 2) --#DEBUG
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
    Log.error("[Scene.pushScene] A valid scene table must be provided.", 2) --#DEBUG
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
    Log.warn("[Scene.popRaw] Stack already empty.")
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

Scene manages registration, stack flow, background updates, and sprite pause classification.

-- Register and Start Scenes
Scene.init()
Scene.registerScenes({
  Title    = TitleScene,
  Gameplay = GameplayScene,
  Pause    = PauseScene,
})

Scene.replaceScene(TitleScene)

-- Stack a Pause Scene
Scene.pushScene(PauseScene)
local currentScene = Scene.getCurrentScene()
local depth = Scene.getStackDepth()
Scene.popScene()

-- Keep a Background Scene Updating
GameplayScene.alwaysUpdate = true
GameplayScene.updateBackground = true
Scene.invalidateLists()

-- Classify Sprites for Scene Pause
local player = RoxySprite({ name = "player" })
player:setPauseClassification(nil) -- Default dynamic behavior

local decoration = playdate.graphics.sprite.new()
decoration:setPauseClassification({}) -- Static; skip pause/resume work

local parallaxLayer = playdate.graphics.sprite.new()
parallaxLayer:setPauseClassification({ updates = true })

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
