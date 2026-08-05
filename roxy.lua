-- source/libraries/roxy/roxy.lua
--
-- Roxy Game Engine
-- MIT License
--

-- Playdate SDK
import "CoreLibs/object"
import "CoreLibs/graphics"
import 'CoreLibs/nineslice'
import "CoreLibs/sprites"
import "CoreLibs/crank"
import "CoreLibs/animation"
import "CoreLibs/animator"
import "CoreLibs/timer"
import "CoreLibs/frameTimer"
import "CoreLibs/ui/crankIndicator"
import "CoreLibs/ui/gridview"

-- Logging and debugging
import "libraries/roxy/core/modules/Log"
import "libraries/roxy/core/modules/Debug" --#DEBUG
import "libraries/roxy/core/modules/TilemapPerf" --#DEBUG

-- Utilities
import "libraries/roxy/utilities/Table"
import "libraries/roxy/utilities/TableBuilder"
import "libraries/roxy/utilities/Math"
import "libraries/roxy/utilities/JSON"
import "libraries/roxy/utilities/Ease"
import "libraries/roxy/utilities/Graphics"

-- Core Modules
import "libraries/roxy/core/modules/Config"
import "libraries/roxy/core/modules/Settings"
import "libraries/roxy/core/modules/GameData"
import "libraries/roxy/core/modules/Cache"
import "libraries/roxy/core/modules/Assets"
import "libraries/roxy/core/modules/Input"
import "libraries/roxy/core/modules/Sequencer"
import "libraries/roxy/core/modules/Camera"
import "libraries/roxy/core/modules/Sounds"
import "libraries/roxy/core/modules/Music"
import "libraries/roxy/core/modules/Scene"
import "libraries/roxy/core/modules/Transition"

-- Core Components
import "libraries/roxy/core/sequences/RoxySequence"
import "libraries/roxy/core/sprites/RoxySprite"
import "libraries/roxy/core/sprites/RoxyActor"
import "libraries/roxy/core/sprites/RoxyParticles"
import "libraries/roxy/core/physics/RoxyPhysicsBody"
import "libraries/roxy/core/animations/RoxyAnimation"
import "libraries/roxy/core/tilemaps/RoxyTilemap"
import "libraries/roxy/core/tilemaps/RoxyOrthoTilemap"
import "libraries/roxy/core/tilemaps/RoxyIsoTilemap"
import "libraries/roxy/core/tilemaps/RoxyStagTilemap"
import "libraries/roxy/core/scenes/RoxyScene"

-- Create global Roxy table if it does not already exist
roxy = roxy or {}

-- Aliases
local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r           <const> = roxy
local Debug       <const> = r.Debug
local GameData    <const> = r.GameData
local Cache       <const> = r.Cache
local Config      <const> = r.Config
local Input       <const> = r.Input
local Sequencer   <const> = r.Sequencer
local Camera      <const> = r.Camera
local Scene       <const> = r.Scene
local Transition  <const> = r.Transition
local Music       <const> = r.Music
local Sounds      <const> = r.Sounds

local randomseed <const> = math.randomseed

local getSecondsSinceEpoch  <const> = pd.getSecondsSinceEpoch
local spriteUpdate          <const> = Sprite.update

local updateTimers      <const> = pd.timer.updateTimers
local updateFrameTimers <const> = pd.frameTimer.updateTimers

local initConfig <const> = Config.init

local getDeltaTime <const> = r.getDeltaTime

local handleInput         <const> = Input.handleInput
local drawCrankIndicator  <const> = Input.drawCrankIndicator

local updateSequences <const> = Sequencer.update

local prepareTransitionScreenshot <const> = Transition.prepareTransitionScreenshot
local executeTransitionDrawing    <const> = Transition.executeTransitionDrawing

local replaceScene      <const> = Scene.replaceScene
local getUpdateList     <const> = Scene.getUpdateList
local getBackgroundList <const> = Scene.getBackgroundList
local getDrawList       <const> = Scene.getDrawList

local updateDebug <const> = Debug.update  --#DEBUG
local drawFPS     <const> = pd.drawFPS    --#DEBUG

local SHOW_FPS_DEFAULT  <const> = true    --#DEBUG
local FPS_X_DEFAULT     <const> = 385     --#DEBUG
local FPS_Y_DEFAULT     <const> = 228     --#DEBUG
local LOG_LEVEL_DEFAULT <const> = "info"  --#DEBUG

-- Local State
local engineInitialized = false
local engineStarted = false

local showFPS --#DEBUG
local fpsX    --#DEBUG
local fpsY    --#DEBUG

--------------------------------------------------------------------------------
-- Engine Initialization
--------------------------------------------------------------------------------

--#DEBUG START
-- ! Set up Logging and Debug
function r.setupLoggingAndDebug(config)
  if config.debugging.enableDebugChecks then
    Debug.enableDebugChecking()
    Debug.startDebugChecks()
  end
  if config.debugging.enableVisualDebugChecks then
    Debug.enableVisualDebug()
  end

  Log.setLogLevel(config.logLevel or LOG_LEVEL_DEFAULT)

  showFPS = config.debugging.showFPS
  if showFPS == nil then
    showFPS = SHOW_FPS_DEFAULT
  end
  fpsX = config.debugging.fpsPosition and config.debugging.fpsPosition[1] or FPS_X_DEFAULT
  fpsY = config.debugging.fpsPosition and config.debugging.fpsPosition[2] or FPS_Y_DEFAULT
end
--#DEBUG END

-- ! Register Modules
function r.registerModules(config)
  Cache.init()
  Input.init()
  Sequencer.init()
  Camera.reset()
  Sounds.init()
  Music.init()
  Scene.init()
  Transition.init()
end

-- ! Replace Scene
function r.goToScene(sceneFn)
  local scene = sceneFn()
  --#DEBUG START
  if type(scene) ~= "table" then
    Log.error("[goToScene] 'sceneFn' must return a valid scene table", 2)
  end
  --#DEBUG END
  replaceScene(scene)
end

-- ! Initialize Roxy
-- Initializes the engine and transitions to the first scene
function r.init(userConfig)
  if engineInitialized then
    Log.error("Engine already initialized. 'roxy.init()' can only be called once") --#DEBUG
    return
  end

  Log.info("Roxy Engine initializing ...") --#DEBUG

  -- (1) Environment
  randomseed(getSecondsSinceEpoch())

  -- (2) Config
  local config = initConfig(userConfig)

  --#DEBUG START
  -- Logging and debug
  r.setupLoggingAndDebug(config)
  --#DEBUG END

  -- (3) Register modules
  r.registerModules(config)

  engineInitialized = true

  Log.info("Roxy Engine ready") --#DEBUG
end

-- ! Start Game
function r.start(startingSceneFn)
  if engineStarted then
    Log.error("Engine already started. 'roxy.start()' can only be called once")
    return
  end

  local scene = startingSceneFn()
  --#DEBUG START
  if type(scene) ~= "table" then
    Log.error("'startingSceneFn' must return a valid scene table", 2)
  end
  --#DEBUG END
  replaceScene(scene)

  engineStarted = true
end

--------------------------------------------------------------------------------
-- System Lifecycle
--------------------------------------------------------------------------------

-- Roxy owns the Playdate system-event globals. Every forwarder runs an optional
-- game hook. Pause, terminate, sleep, and lock force a GameData autosave; pause
-- and resume also drive the current scene. Games set 'roxy.onGameWillPause' etc.
-- instead of assigning the corresponding Playdate globals, which would bypass
-- Roxy's autosave or scene forwarding and, when debug checks are enabled, trip
-- the tamper check.
--
-- 'GameData' is a '<const>' table alias, but 'autosave' is intentionally looked
-- up on that table at each call.

--#DEBUG START
-- A repeated import may encounter the forwarders from the prior Roxy import.
-- Preserve them so the migration diagnostic does not mistake them for game code.
local priorLifecycleForwarders <const> = {
  gameWillPause     = r.gameWillPause,
  gameWillResume    = r.gameWillResume,
  gameWillTerminate = r.gameWillTerminate,
  deviceWillSleep   = r.deviceWillSleep,
  deviceWillLock    = r.deviceWillLock,
}
--#DEBUG END

-- Records the exact scene this module paused, so a system resume never
-- un-pauses a scene that game code paused itself. System resume requires the
-- RoxyScene boolean 'isPaused' state to distinguish partial pause work from a
-- pause override that failed before it reached the superclass. Cleared on
-- every resume.
local systemPausedScene = nil

-- ! Utility: Call Game Hook
-- Runs an optional game hook under protection so a broken hook cannot defeat
-- autosave or scene pause. Returns pcall's success flag and value separately:
-- 'error(nil)' and 'error(false)' are legal, so branching on the value alone
-- would swallow those failures.
local function callGameHook(hook)
  if not hook then return true, nil end
  return pcall(hook)
end

-- ! Game Will Pause
function r.gameWillPause()
  -- Hook first: GameData mutations are synchronous but the save I/O defers
  -- through a zero-delay timer that cannot fire while paused, so the autosave
  -- below must be the thing that observes whatever the hook staged.
  local hookOk, hookErr = callGameHook(r.onGameWillPause)

  local autosaveOk, autosaveErr = pcall(GameData.autosave)

  local pauseOk, pauseErr = true, nil
  local currentScene = Scene.currentScene
  if currentScene and currentScene.isPaused ~= true and currentScene.pause then
    -- Record ownership before the fallible pause work. RoxyScene:pause() sets
    -- isPaused before its internal sprite, sequence, camera, and input work.
    systemPausedScene = currentScene
    pauseOk, pauseErr = pcall(currentScene.pause, currentScene)
  end

  -- Rethrow only after persistence and scene pause are complete. The first
  -- lifecycle failure wins so later failures cannot hide the original cause.
  if not hookOk then error(hookErr, 0) end
  if not autosaveOk then error(autosaveErr, 0) end
  if not pauseOk then error(pauseErr, 0) end
end

-- ! Game Will Resume
function r.gameWillResume()
  -- Clear first so a stale reference can never drive a later resume and never
  -- anchors a replaced scene's sprite graph.
  local pausedScene = systemPausedScene
  systemPausedScene = nil

  if pausedScene and pausedScene == Scene.currentScene
    and pausedScene.isPaused == true and pausedScene.resume then
    pausedScene:resume()
  end

  -- Unprotected: the scene is already restored, so an error can propagate.
  local onGameWillResume = r.onGameWillResume
  if onGameWillResume then onGameWillResume() end
end

-- ! Game Will Terminate
function r.gameWillTerminate()
  local hookOk, hookErr = callGameHook(r.onGameWillTerminate)
  GameData.autosave()
  if not hookOk then error(hookErr, 0) end
end

-- ! Device Will Sleep
-- Save point only: Roxy has no paired wake callback to resume the scene.
function r.deviceWillSleep()
  local hookOk, hookErr = callGameHook(r.onDeviceWillSleep)
  GameData.autosave()
  if not hookOk then error(hookErr, 0) end
end

-- ! Device Will Lock
-- Save point only: Playdate provides deviceDidUnlock, but Roxy does not use
-- lock/unlock to drive scene pause state.
function r.deviceWillLock()
  local hookOk, hookErr = callGameHook(r.onDeviceWillLock)
  GameData.autosave()
  if not hookOk then error(hookErr, 0) end
end

--#DEBUG START
-- ! Reset System Pause State (unit tests)
function r._resetSystemPauseState()
  systemPausedScene = nil
end
--#DEBUG END

-- Install at file scope after GameData is imported so Roxy is the last writer,
-- and before 'roxy.init()' so Debug.captureOriginalFunctions snapshots these as
-- the originals. Same seam as 'pd.update' below.

--#DEBUG START
local lifecycleCallbacks <const> = {
  { playdateName = "gameWillPause",     forwarderName = "gameWillPause",     hookName = "onGameWillPause" },
  { playdateName = "gameWillResume",    forwarderName = "gameWillResume",    hookName = "onGameWillResume" },
  { playdateName = "gameWillTerminate", forwarderName = "gameWillTerminate", hookName = "onGameWillTerminate" },
  { playdateName = "deviceWillSleep",   forwarderName = "deviceWillSleep",   hookName = "onDeviceWillSleep" },
  { playdateName = "deviceWillLock",    forwarderName = "deviceWillLock",    hookName = "onDeviceWillLock" },
}

local replacedLifecycleCallbacks = {}
for i = 1, #lifecycleCallbacks do
  local callback = lifecycleCallbacks[i]
  local existingCallback = pd[callback.playdateName]
  if existingCallback ~= nil and existingCallback ~= priorLifecycleForwarders[callback.forwarderName] then
    replacedLifecycleCallbacks[#replacedLifecycleCallbacks + 1] =
      "playdate." .. callback.playdateName .. " (use roxy." .. callback.hookName .. ")"
  end
end

if #replacedLifecycleCallbacks > 0 then
  Log.warn(
    "[Roxy] Roxy owns these Playdate lifecycle globals and will replace their pre-existing values: "
      .. table.concat(replacedLifecycleCallbacks, ", ") .. "."
  )
end
--#DEBUG END

pd.gameWillPause      = r.gameWillPause
pd.gameWillResume     = r.gameWillResume
pd.gameWillTerminate  = r.gameWillTerminate
pd.deviceWillSleep    = r.deviceWillSleep
pd.deviceWillLock     = r.deviceWillLock

--------------------------------------------------------------------------------
-- Main Game Loop
--------------------------------------------------------------------------------

-- ! Update
function pd.update()
  local dt = getDeltaTime()
  r.deltaTime = dt

  --#DEBUG START
  if dt > 0.05 then
    Log.debug("Long frame: " .. dt)
  end
  --#DEBUG END

  updateTimers()
  updateFrameTimers()

  handleInput()
  updateSequences(dt)

  -- Active scenes
  local updateList = getUpdateList()
  local updateCount = #updateList
  for i = 1, updateCount do
    updateList[i]:update(dt)
  end

  -- Background scenes
  local bgList = getBackgroundList()
  local bgCount = #bgList
  for i = 1, bgCount do
    bgList[i]:updateBackground(dt)
  end

  local isTransitioning = Transition.isTransitioning

  if isTransitioning then
    local currentTransition = Transition.currentTransition
    if currentTransition then
      prepareTransitionScreenshot() -- Push offscreen context here (pre-render)
    end
  end

  spriteUpdate()

  -- Scene draw methods (run after sprites)
  local list = getDrawList()
  local drawCount = #list
  for i = 1, drawCount do
    list[i]:draw(dt)
  end

  -- Now render the transition overlay
  if isTransitioning then
    executeTransitionDrawing() -- This will pop the offscreen context
  end

  drawCrankIndicator()

  updateDebug() --#DEBUG
  if showFPS then drawFPS(fpsX, fpsY) end --#DEBUG
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

-- Extend Roxy's lifecycle handling; do not replace the playdate callbacks.
local function stageSessionState()
  roxy.GameData.set({
    room = currentRoom,
    checkpoint = currentCheckpoint,
  })
end

roxy.onGameWillPause = stageSessionState
roxy.onGameWillTerminate = stageSessionState
roxy.onDeviceWillSleep = stageSessionState
roxy.onDeviceWillLock = stageSessionState

roxy.onGameWillResume = function()
  refreshControllerState()
end

-- Keep scene-specific pause behavior on the scene.
function GameplayScene:pause()
  GameplayScene.super.pause(self)
  self.ambientTrack:pause()
end

function GameplayScene:resume()
  GameplayScene.super.resume(self)
  self.ambientTrack:play()
end

--]]
