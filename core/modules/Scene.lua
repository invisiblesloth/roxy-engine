-- core/modules/Scene.lua

roxy = roxy or {}
roxy.Scene = roxy.Scene or {}
local Scene <const> = roxy.Scene

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

-- Constants
local MAX_SCENE_DEPTH <const> = 32

-- Aliases
local redrawBackground <const> = Sprite.redrawBackground

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
    if scene.enter and not scene._didEnter then
      scene:enter()
    end
    redrawBackground()
  end
end

-- ----------------------------------------
-- Core Logic
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

-- ! Replace Scene
-- Clears the stack and sets the provided scene as the only active scene.
function Scene.replaceScene(scene)
  if type(scene) ~= "table" then
    error("[*][Scene.replaceScene] A valid scene table must be provided.", 2) --#DEBUG
    return
  end

  print("[D][Scene.replaceScene] Stack cleared. Set '" .. (scene.name or "Unnamed") .. "' as sole scene.") --#DEBUG

  -- Clean up every scene currently on the stack
  for i = #stack, 1, -1 do
    local scene = stack[i]
    if scene.exit and not scene._didExit then
      scene:exit()
    end
    if scene.cleanup and not scene._didCleanup then
      scene:cleanup()
    end
    stack[i] = nil
  end

  -- Make new scene the sole occupant
  stack[1] = scene
  activateScene(scene)
  rebuildLists()
end

-- ! Push Scene
-- Pauses the current scene and pushes a new scene onto the stack.
function Scene.pushScene(scene)
  if type(scene) ~= "table" then
    error("[*][Scene.pushScene] A valid scene table must be provided.", 2) --#DEBUG
    return
  end

  print("[D][Scene.pushScene] Pushing Scene " .. (scene.name or "Unnamed")) --#DEBUG

  -- Soft stack overflow cap
  if #stack >= MAX_SCENE_DEPTH then
    error("[*][Scene.pushScene] Stack depth exceeded (limit: " .. MAX_SCENE_DEPTH .. ")", 2) --#DEBUG
    return
  end

  local current = Scene.currentScene
  if current and current.pause then
    current:pause()
  end

  stack[#stack + 1] = scene
  activateScene(scene)
  rebuildLists()
end

-- ! Pop Scene
-- Removes the current scene and resumes the previous one.
function Scene.popScene()
  local depth = #stack
  if depth == 0 then
    warn("[W][Scene.popScene] Stack is already empty.", 2) --#DEBUG
    Scene.currentScene = nil
    return
  end

  local scene = stack[depth]
  print("[D][Scene.popScene] Popping Scene " .. (scene.name or "Unnamed")) --#DEBUG

  if scene.cleanup and not scene._didCleanup then
    scene:cleanup()
  end

  stack[depth] = nil
  local previous = stack[depth - 1]
  if previous and previous.resume and previous.isPaused then
    previous:resume()
  end

  activateScene(previous)
  rebuildLists()
end

-- ----------------------------------------
-- Public API
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

