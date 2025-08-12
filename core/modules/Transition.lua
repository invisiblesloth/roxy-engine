-- core/modules/Transition.lua

import "libraries/roxy/core/transitions/RoxyTransition"
import "libraries/roxy/core/transitions/Cut"
import "libraries/roxy/core/transitions/FadeToColor"
import "libraries/roxy/core/transitions/CrossDissolve"
import "libraries/roxy/core/transitions/ImageTable"

roxy = roxy or {}
roxy.Transition = roxy.Transition or {}
local Transition <const> = roxy.Transition

local pd        <const> = playdate
local Graphics  <const> = pd.graphics

local r       <const> = roxy
local Config  <const> = r.Config
local Scene   <const> = r.Scene

local mergeImmutable <const> = r.Table.mergeImmutable

local getConfig           <const> = Config.get
local getTransitionConfig <const> = Config.getTransitionConfig

local pushContext <const> = Graphics.pushContext
local popContext  <const> = Graphics.popContext
local setColor    <const> = Graphics.setColor
local fillRect    <const> = Graphics.fillRect
local newImage    <const> = Graphics.image.new
local getDrawMode <const> = Graphics.getImageDrawMode
local setDrawMode <const> = Graphics.setImageDrawMode

local EMPTY_TABLE   <const> = {}

local COLOR_WHITE     <const> = Graphics.kColorWhite
local DRAW_MODE_COPY  <const> = Graphics.kDrawModeCopy

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local STACK_OP_REPLACE <const> = 0
local STACK_OP_PUSH    <const> = 1
local STACK_OP_POP     <const> = 2

local TRANSITION_DEFAULT          <const> = "Cut"
local TRANSITION_DURATION_DEFAULT <const> = 1.5
local HOLD_TIME_DEFAULT           <const> = 0.25

local DEFAULT_TRANSITIONS = {
  Cut           = Cut,
  FadeToColor   = FadeToColor,
  CrossDissolve = CrossDissolve,
  ImageTable    = ImageTable,
}

-- Global
Transition.currentTransition  = nil
Transition.isTransitioning    = false
Transition.stackOp            = STACK_OP_REPLACE
Transition.STACK_OP_REPLACE   = STACK_OP_REPLACE
Transition.STACK_OP_PUSH      = STACK_OP_PUSH
Transition.STACK_OP_POP       = STACK_OP_POP

-- Local
local transitions = {}

-- ----------------------------------------
-- ! Initialize Transition module
-- ----------------------------------------

function Transition.init()
  -- Reset transient state
  Transition.currentTransition = nil
  Transition.isTransitioning   = false
  Transition.stackOp           = STACK_OP_REPLACE

  -- Clear out any previously loaded classes
  transitions = {}

  -- Merge in user’s customTransitions if present
  local config          = getConfig("transitions") or EMPTY_TABLE
  local userTransitions = config.customTransitions
  local allTransitions  = DEFAULT_TRANSITIONS

  if type(userTransitions) == "table" and next(userTransitions) then
    allTransitions = mergeImmutable(DEFAULT_TRANSITIONS, userTransitions)
  end

  -- Actually register them
  Transition.loadTransitions(allTransitions)

  -- Prime the per‑transition duration/holdTime tables
  Transition.reloadTransitionsWithNewConfig()
end

-- ----------------------------------------
-- Scene Management
-- ----------------------------------------

-- ! Load Transitions
-- Loads a table of transition classes into the transition module.
function Transition.loadTransitions(transitionsTable)
  if type(transitionsTable) ~= "table" then
    Log.error("[Transition.loadTransitions] transitionsTable must be a table.", 2) --#DEBUG
    return
  end

  for key, value in pairs(transitionsTable) do
    if type(key) ~= "string" then
      Log.error("[Transition.loadTransitions] Transition key must be a string.", 2) --#DEBUG
      return
    elseif type(value) ~= "table" or not value.__index then
      Log.error("[Transition.loadTransitions] Transition value must be a valid class.", 2) --#DEBUG
      return
    end
    transitions[key] = value
    if value.warmUpAssetPool then value:warmUpAssetPool() end
  end
end

-- ! Get Transitions
function Transition.getTransitions()
  return transitions
end

-- ! Transition.reloadTransitionsWithNewConfig
-- Updates transition durations and hold times using the active configuration.
function Transition.reloadTransitionsWithNewConfig()
  if not transitions then return end

  -- Pull the whole "transitions" block from Config
  local rootConfig      = getConfig("transitions") or EMPTY_TABLE
  local globalDuration  = rootConfig.duration or TRANSITION_DURATION_DEFAULT
  local globalHoldTime  = rootConfig.holdTime or HOLD_TIME_DEFAULT
  local overridesTbl    = rootConfig.overrides or EMPTY_TABLE

  -- Build & store a fresh per-transition default config
  for name, class in pairs(transitions) do

    -- Layer order:
    --    (a)  Hard-coded fallback
    --    (b)  Global duration / holdTime
    --    (c)  Per-transition overrides (wins on clash)

    local builder = TableBuilder({
      duration  = globalDuration,
      holdTime  = globalHoldTime,
      name      = name,
    })
      :with(overridesTbl[name]) -- Transition-specific layer

    -- Final immutable table:
    local config = builder:build()

    Config.setTransitionConfig(name, config)
  end
end

-- ! Replace Scene
function Transition.replaceScene(newSceneClass, transitionName, opts)
  Transition.stackOp = STACK_OP_REPLACE
  Transition.transitionToScene(newSceneClass, transitionName, opts)
end

-- ! Push Scene
function Transition.pushScene(newSceneClass, transitionName, opts)
  Transition.stackOp = STACK_OP_PUSH
  Transition.transitionToScene(newSceneClass, transitionName, opts)
end

-- ! Pop Scene
function Transition.popScene(transitionName, opts)
  Transition.stackOp = STACK_OP_POP
  Transition.transitionToScene(nil, transitionName, opts)
end

-- ! Transition to Scene
-- Initiates a scene transition using the specified effect and timing.
function Transition.transitionToScene(newSceneClass, transitionName, opts)
  if Transition.isTransitioning then
    Log.warn("[Transition.transitionToScene] Transition already in progress.") --#DEBUG
    return
  end

  local stackOp = Transition.stackOp
  local newScene = nil
  if stackOp ~= STACK_OP_POP then
    newScene = newSceneClass()
    --#DEBUG START
    if not newScene then
      Log.error("[Transition.transitionToScene] Failed to instantiate newSceneClass.", 2)
    end
    --#DEBUG END
  end

  Transition.isTransitioning = true
  local scene = Scene.currentScene

  -- Use transition or fallback to default
  local config = getConfig("transitions") or EMPTY_TABLE
  local transition = config.defaultTransition or TRANSITION_DEFAULT
  local transitionClass = transitions[(transitionName or transition)]
  if not transitionClass then
    Log.warn("[Transition.transitionToScene] Unknown transition " .. transitionName .. ", falling back to " .. transition) --#DEBUG
    transitionClass = transitions[transition]
  end

  -- Merge options (arguments take precedence)
  local transitionOpts = mergeImmutable(opts or {}, { stackOp = stackOp })

  -- Construct and execute the transition instance
  local transitionInstance = transitionClass(transitionOpts)
  Transition.currentTransition = transitionInstance
  transitionInstance:execute(newScene, scene)
end

-- ----------------------------------------
-- Rendering
-- ----------------------------------------

-- ! Prepare Transition Screenshot
-- Prepares a screenshot for transitions if needed.
function Transition.prepareTransitionScreenshot()
  local transition = Transition.currentTransition
  if not transition or not transition.captureScreenshot then return end

  -- Reuse the same image
  local img = transition.newSceneScreenshot
  if not img or img.width ~= DISPLAY_WIDTH or img.height ~= DISPLAY_HEIGHT then
    img = newImage(DISPLAY_WIDTH, DISPLAY_HEIGHT)
    transition.newSceneScreenshot = img
  end

  pushContext(img) -- Draw the whole frame into this image
  transition._screenshotContextPushed = true
end

-- ! Clear Transition Screenshot
-- Fills the current transition's screenshot image with a solid color.
-- This is optional — most transitions fully redraw the frame anyway.
function Transition.clearTransitionScreenshot(color)
  local transition = Transition.currentTransition
  if not transition or not transition.newSceneScreenshot then return end

  -- Default to white if no color passed
  local fillColor = color or COLOR_WHITE

  pushContext(transition.newSceneScreenshot)
    setColor(fillColor)
    fillRect(0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT)
  popContext()
end

-- ! Execute Transition Drawing
-- Executes rendering for the active transition effect, restoring draw mode afterward.
function Transition.executeTransitionDrawing()
  if not Transition.isTransitioning then return end
  local transition = Transition.currentTransition
  if not transition then return end

  -- Pop only if we pushed this frame
  if transition.captureScreenshot and transition._screenshotContextPushed then
    popContext()
    transition._screenshotContextPushed = false
  end

  local drawMode = transition.drawMode or DRAW_MODE_COPY
  local prev = getDrawMode()
  if prev ~= drawMode then
    setDrawMode(drawMode)
  end
  transition:draw()
  if drawMode ~= prev then
    setDrawMode(prev)
  end
end
