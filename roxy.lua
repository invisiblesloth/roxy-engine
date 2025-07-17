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
import "CoreLibs/ui/crankIndicator"
import "CoreLibs/ui/gridview"

-- Logging and debugging
import "libraries/roxy/core/modules/Log"
import "libraries/roxy/core/modules/Debug" --#DEBUG

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
import "libraries/roxy/core/modules/Scene"
import "libraries/roxy/core/modules/Transition"
import "libraries/roxy/core/modules/Sounds"
import "libraries/roxy/core/modules/Music"

-- Core Components
import "libraries/roxy/core/sequences/RoxySequence"
import "libraries/roxy/core/sprites/RoxySprite"
import "libraries/roxy/core/sprites/RoxyActor"
import "libraries/roxy/core/sprites/RoxyParticles"
import "libraries/roxy/core/physics/RoxyPhysicsBody"
import "libraries/roxy/core/animations/RoxyAnimation"
import "libraries/roxy/core/tilemaps/RoxyTilemap"
import "libraries/roxy/core/scenes/RoxyScene"

-- Transitions
import "libraries/roxy/core/transitions/RoxyTransition"
import "libraries/roxy/core/transitions/Cut"
import "libraries/roxy/core/transitions/FadeToColor"
import "libraries/roxy/core/transitions/CrossDissolve"
import "libraries/roxy/core/transitions/ImageTable"

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

local mergeImmutable <const> =roxy.Table.mergeImmutable

local initConfig <const> = Config.init

local getDeltaTime <const> = r.getDeltaTime

local handleInput         <const> = Input.handleInput
local drawCrankIndicator  <const> = Input.drawCrankIndicator

local updateSequences <const> = Sequencer.update

local loadTransitions             <const> = Transition.loadTransitions
local prepareTransitionScreenshot <const> = Transition.prepareTransitionScreenshot
local executeTransitionDrawing    <const> = Transition.executeTransitionDrawing

local replaceScene      <const> = Scene.replaceScene
local getUpdateList     <const> = Scene.getUpdateList
local getBackgroundList <const> = Scene.getBackgroundList

local updateDebug <const> = Debug.update --#DEBUG
local drawFPS     <const> = pd.drawFPS --#DEBUG

-- Constants
local SHOW_FPS_DEFAULT  <const> = true    --#DEBUG
local FPS_X_DEFAULT     <const> = 385     --#DEBUG
local FPS_Y_DEFAULT     <const> = 228     --#DEBUG
local LOG_LEVEL_DEFAULT <const> = "info"  --#DEBUG

local DEFAULT_TRANSITIONS = {
  Cut           = Cut,
  FadeToColor   = FadeToColor,
  CrossDissolve = CrossDissolve,
  ImageTable    = ImageTable,
}

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
  -- Register transitions
  local userTransitions
  local allTransitions
  if config.customTransitions then
    userTransitions = config and config.customTransitions or {}
    allTransitions = mergeImmutable(DEFAULT_TRANSITIONS, userTransitions)
  else
    allTransitions = DEFAULT_TRANSITIONS
  end
  loadTransitions(allTransitions)

  -- Initialize managers
  Cache.init()
  Input.init()
  Sequencer.init()
  Camera.reset()
  Scene.init()
  Sounds.init()
  Music.init()
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
-- Pause and Resume
--------------------------------------------------------------------------------

-- ! Game Will Pause
function r.gameWillPause()
  local currentScene = Scene.currentScene
  if currentScene.pause then
    currentScene:pause()
  end
end

-- ! Game Will Resume
function r.gameWillResume()
  local currentScene = Scene.currentScene
  if currentScene.resume then
    currentScene:resume()
  end
end

--------------------------------------------------------------------------------
-- Main Game Loop
--------------------------------------------------------------------------------

-- ! Update
function pd.update()
  local dt = getDeltaTime()
  r.deltaTime = dt

  handleInput()
  updateSequences(dt)
  spriteUpdate()

  local updateList = getUpdateList()
  for i = 1, #updateList do
    updateList[i]:update(dt)
  end
  local bgList = getBackgroundList()
  for i = 1, #bgList do
    bgList[i]:updateBackground(dt)
  end

  if Transition.isTransitioning then
    local currentTransition = Transition.currentTransition
    if currentTransition.captureScreenshotsDuringTransition then
      prepareTransitionScreenshot()
    end
    executeTransitionDrawing()
  end

  drawCrankIndicator()

  updateDebug() --#DEBUG
  if showFPS then drawFPS(fpsX, fpsY) end --#DEBUG
end
