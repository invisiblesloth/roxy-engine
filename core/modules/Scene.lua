-- core/modules/Scene.lua

roxy = roxy or {}
roxy.Scene = roxy.Scene or {}
local Scene <const> = roxy.Scene

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local redrawBackground <const> = Sprite.redrawBackground

local MAX_SCENE_DEPTH <const> = 32

-- Global
Scene.currentScene = nil  -- Currently active scene (top of stack)

-- Local
local scenes = {}     -- Registered scenes
local stack = {}      -- Scene stack
local updateList = {} -- Pre-filtered update list
local bgList = {}     -- Pre-filtered bg update lists

-- ----------------------------------------
-- Utilities
-- ----------------------------------------

-- ! Utility: Rebuild Lists
-- Rebuilds the update lists based on the current stack.
local function rebuildLists()
  local currentScene = Scene.currentScene
  local updateCount, bgCount = 0, 0
  for i = 1, #stack do
    local scene = stack[i]
    if scene == currentScene or scene.alwaysUpdate then
      updateCount += 1
      updateList[updateCount] = scene
    elseif scene.updateBackground then
      bgCount += 1
      bgList[bgCount] = scene
    end
  end

  -- Trim tails
  for i = updateCount + 1, #updateList do
    updateList[i] = nil
  end
  for i = bgCount + 1, #bgList do
    bgList[i] = nil
  end

  print("[D][Scene.rebuildLists] update=".. updateCount .. " bg=" .. bgCount) --#DEBUG
end

-- ! Utility: Activate Scene
-- Sets up the background callback for the provided scene.
local function activateScene(scene)
  Scene.currentScene = scene
  if scene then
    scene:enter()
    redrawBackground()
  end
end

-- ----------------------------------------
-- Scene Registration
-- ----------------------------------------

-- ! Register Scenes
function Scene.registerScenes(...)
  local params = { ... }
  local paramCount = #params

  -- Case 1: registerScenes("name", sceneTable)
  if paramCount == 2 then
    local sceneName, sceneTable = params[1], params[2]

    if type(sceneName) ~= "string" then
      error("[*][Scene.registerScenes] First argument must be a string scene name.", 2) --#DEBUG
      return
    end
    if type(sceneTable) ~= "table" then
      error("[*][Scene.registerScenes] Second argument must be a table.", 2) --#DEBUG
      return
    end

    scenes[sceneName] = sceneTable
    return
  end

  -- Case 2: registerScenes({ name1 = table1, name2 = table2, ... })
  if paramCount == 1 then
    local sceneTable = params[1]

    if type(sceneTable) ~= "table" then
      error("[*][Scene.registerScenes] Single argument must be a table of scenes.", 2) --#DEBUG
      return
    end

    for name, table in pairs(sceneTable) do
      -- TODO: Should the if statement be removed from release build or just the error log?
      if type(name) ~= "string" then
        error("[*][Scene.registerScenes] Skipping scene — key is not a string.", 2) --#DEBUG
        return
      elseif type(table) ~= "table" then
        error("[*][Scene.registerScenes] Skipping scene '" .. tostring(name) .. "' — value is not a table.", 2) --#DEBUG
        return
      else
        scenes[name] = table
      end
    end
    return
  end

  error("[*][Scene.registerScenes] Invalid parameters to roxy.Scene.registerScenes.", 2) --#DEBUG
end

-- ----------------------------------------
-- Scene Stack Management
-- ----------------------------------------

-- ! Replace Scene Raw
function Scene.replaceRaw(newScene)
  if type(newScene) ~= "table" then
    error("[*][Scene.replaceRaw] A valid scene table must be provided.", 2) --#DEBUG
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

  print("[D][Scene.replaceRaw] Stack cleared. Set '" .. (newScene.name or "Unnamed") .. "' as sole scene.") --#DEBUG
end

-- ! Replace Scene
function Scene.replaceScene(newScene)
  if type(newScene) ~= "table" then
    error("[*][Scene.replaceScene] A valid scene table must be provided.", 2) --#DEBUG
    return
  end

  local oldScene = Scene.currentScene
  Scene.replaceRaw(newScene)

  if oldScene then
    oldScene:exit()
    oldScene:cleanup()
  end

  activateScene(newScene)
end

-- ! Push Scene Raw
function Scene.pushRaw(newScene)
  if type(newScene) ~= "table" then
    error("[*][Scene.pushRaw] A valid scene table must be provided.", 2) --#DEBUG
    return
  end

  -- Soft stack overflow cap
  if #stack >= MAX_SCENE_DEPTH then
    error("[*][Scene.pushRaw] Stack depth exceeded (limit: " .. MAX_SCENE_DEPTH .. ")", 2) --#DEBUG
    return
  end

  stack[#stack+1] = newScene
  Scene.currentScene = newScene
  rebuildLists()

  print("[D][Scene.pushRaw] Pushing Scene " .. (newScene.name or "Unnamed")) --#DEBUG
end

-- ! Push Scene
function Scene.pushScene(newScene)
  if type(newScene) ~= "table" then
    error("[*][Scene.pushScene] A valid scene table must be provided.", 2) --#DEBUG
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
    warn("[W][Scene.popRaw] Stack already empty.")
    Scene.currentScene = nil
    rebuildLists()
    return
  end

  local popped = stack[depth]
  stack[depth] = nil
  Scene.currentScene = stack[#stack] -- Now top
  rebuildLists()

  print("[D][Scene.popRaw] Popping Scene " .. (popped.name or "Unnamed")) --#DEBUG

  return popped
end

-- ! Pop Scene
function Scene.popScene()
  local oldScene = Scene.popRaw()

  if oldScene then
    oldScene:cleanup()
  end

  local newScene = Scene.currentScene
  if newScene then
    newScene:resume()
  end

  activateScene(newScene)
end

-- ----------------------------------------
-- Scene State / Getters
-- ----------------------------------------

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
