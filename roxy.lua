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

-- Utilities
import "libraries/roxy/utilities/Math"
import "libraries/roxy/utilities/Table"
import "libraries/roxy/utilities/Ease"
import "libraries/roxy/utilities/Graphics"

-- Core Modules
import "libraries/roxy/core/modules/Input"
import "libraries/roxy/core/modules/Sequencer"
import "libraries/roxy/core/modules/Camera"
import "libraries/roxy/core/modules/Scene"
import "libraries/roxy/core/modules/Transition"

-- Core Components
import "libraries/roxy/core/sequences/RoxySequence"
import "libraries/roxy/core/sprites/RoxySprite"
import "libraries/roxy/core/sprites/RoxyActor"
import "libraries/roxy/core/animations/RoxyAnimation"
import "libraries/roxy/core/scenes/RoxyScene"

-- Create global Roxy table if it does not already exist
roxy = roxy or {}

-- Aliases
local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local r           <const> = roxy
local Sequencer   <const> = r.Sequencer
local Scene       <const> = r.Scene
local Transition  <const> = r.Transition

local getDeltaTime    <const> = r.getDeltaTime
local loadTransitions <const> = Transition.loadTransitions

local randomseed            <const> = math.randomseed
local getSecondsSinceEpoch  <const> = pd.getSecondsSinceEpoch

local setColor    <const> = Graphics.setColor
local setBgColor  <const> = Graphics.setBackgroundColor
local getDrawMode <const> = Graphics.getImageDrawMode
local setDrawMode <const> = Graphics.setImageDrawMode

local spriteUpdate <const> = Sprite.update

local Input               <const> = r.Input
local handleInput         <const> = Input.handleInput
local drawCrankIndicator  <const> = Input.drawCrankIndicator

local updateSequences <const> = Sequencer.update

local replaceScene      <const> = Scene.replaceScene
local getUpdateList     <const> = Scene.getUpdateList
local getBackgroundList <const> = Scene.getBackgroundList

local prepareTransitionScreenshot <const> = Transition.prepareTransitionScreenshot
local executeTransitionDrawing    <const> = Transition.executeTransitionDrawing

local drawFPS <const> = pd.drawFPS --#DEBUG

-- Constants
local COLOR_BLACK     <const> = Graphics.kColorBlack
local COLOR_WHITE     <const> = Graphics.kColorWhite
local DRAW_MODE_COPY  <const> = Graphics.kDrawModeCopy

local DEFAULT_FPS_X <const> = 385 --#DEBUG
local DEFAULT_FPS_Y <const> = 228 --#DEBUG

-- Import Transitions
import "libraries/roxy/core/transitions/RoxyTransition"
import "libraries/roxy/core/transitions/RoxyCutTransition"
import "libraries/roxy/core/transitions/Cut"
import "libraries/roxy/core/transitions/RoxyCoverTransition"
import "libraries/roxy/core/transitions/FadeToBlack"

-- Local State
local engineInitialized = false

local showFPS = true          --#DEBUG
local fpsX    = DEFAULT_FPS_X --#DEBUG
local fpsY    = DEFAULT_FPS_Y --#DEBUG

-- ----------------------------------------
-- Engine
-- ----------------------------------------

-- ! New
-- Initializes the engine and transitions to the first scene
function r.new(startingScene)
  if engineInitialized then
    error("You can only run 'roxy.new()' once.") --#DEBUG
    return
  end

  --#DEBUG START
  if not startingScene then
    error("[*][roxy.new] startingScene is required for roxy.new.", 2)
  end
  --#DEBUG END

  -- (1) Seed random number generator
  randomseed(getSecondsSinceEpoch())

  -- (2) Load transitions
  loadTransitions({
    Cut = Cut,
    FadeToBlack = FadeToBlack
  })

  -- (3) Start starting scene
  engineInitialized = true
  local scene = startingScene()

  --#DEBUG START
  if type(scene) ~= "table" then
    error("[*][roxy.new] startingScene initialization must return a scene table.", 2)
  end
  --#DEBUG END

  replaceScene(scene)
end

-- ----------------------------------------
-- Pause and Resume
-- ----------------------------------------

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

-- ----------------------------------------
-- Main Game Loop
-- ----------------------------------------

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
  if showFPS then drawFPS(fpsX, fpsY) end --#DEBUG
end
