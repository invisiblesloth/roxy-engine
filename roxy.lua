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

-- Core Modules
import "libraries/roxy/core/modules/Scene"

-- Core Components
import "libraries/roxy/core/scenes/RoxyScene"

-- Create global Roxy table if it does not already exist
roxy = roxy or {}

-- Local State
local engineInitialized = false

-- SDK & Modules
local pd        <const> = playdate
local Graphics  <const> = pd.graphics

local r     <const> = roxy
local Scene <const> = r.Scene

-- Constants
local COLOR_BLACK     <const> = Graphics.kColorBlack
local COLOR_WHITE     <const> = Graphics.kColorWhite
local DRAW_MODE_COPY  <const> = Graphics.kDrawModeCopy

local DEFAULT_FPS_X <const> = 385 --#DEBUG
local DEFAULT_FPS_Y <const> = 228 --#DEBUG

-- Aliases
local getDeltaTime  <const> = r.getDeltaTime

local randomseed            <const> = math.randomseed
local getSecondsSinceEpoch  <const> = pd.getSecondsSinceEpoch

local setColor    <const> = Graphics.setColor
local setBgColor  <const> = Graphics.setBackgroundColor
local getDrawMode <const> = Graphics.getImageDrawMode
local setDrawMode <const> = Graphics.setImageDrawMode

local replaceScene      <const> = Scene.replaceScene
local getUpdateList     <const> = Scene.getUpdateList
local getBackgroundList <const> = Scene.getBackgroundList

-- ----------------------------------------
-- Public API
-- ----------------------------------------

-- ! New
-- Initializes the engine and transitions to the first scene
function r.new(startingScene)
  if engineInitialized then
    error("You can only run 'roxy.new()' once.") --#DEBUG
    return
  end

  -- (1) Seed random number generator
  randomseed(getSecondsSinceEpoch())

  -- (2) Set initial graphics state
  setColor(COLOR_WHITE)
  setBgColor(COLOR_BLACK)
  setDrawMode(DRAW_MODE_COPY)

  -- (3) Start starting scene
  engineInitialized = true
  local scene = startingScene()

  --#DEBUG START
  if type(scene) ~= "table" then
    error("[*][roxy.new] StartingScene function must return a scene table.", 2)
  end
  --#DEBUG END

  replaceScene(scene)
end

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
-- Implementation
-- ----------------------------------------

-- ! Main Loop
function pd.update()
  local dt = getDeltaTime()
  r.deltaTime = dt

  local updateList = getUpdateList()
  for i = 1, #updateList do
    updateList[i]:update(dt)
  end

  local bgList = getBackgroundList()
  for i = 1, #bgList do
    bgList[i]:updateBackground(dt)
  end
end
