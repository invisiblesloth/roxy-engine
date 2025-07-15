-- core/modules/Transition.lua

roxy = roxy or {}
roxy.Transition = roxy.Transition or {}
local Transition <const> = roxy.Transition

local pd        <const> = playdate
local Graphics  <const> = pd.graphics

local r       <const> = roxy
local Config  <const> = r.Config
local Scene   <const> = r.Scene

local mergeTableImmutable <const> = r.Table.mergeImmutable

local getConfig           <const> = Config.get
local getTransitionConfig <const> = Config.getTransitionConfig

local pushContext <const> = Graphics.pushContext
local popContext  <const> = Graphics.popContext
local newImage    <const> = Graphics.image.new
local getDrawMode <const> = Graphics.getImageDrawMode
local setDrawMode <const> = Graphics.setImageDrawMode

local EMPTY_TABLE   <const> = {}

local STACK_OP_REPLACE <const> = 0
local STACK_OP_PUSH    <const> = 1
local STACK_OP_POP     <const> = 2

local TRANSITION_DEFAULT          <const> = "Cut"
local TRANSITION_DURATION_DEFAULT <const> = 1.5
local HOLD_TIME_DEFAULT           <const> = 0.25

local DRAW_MODE_COPY  <const> = Graphics.kDrawModeCopy

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

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

    local builder = ConfigBuilder({
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
  local currentScene = Scene.currentScene

  -- Use transition or fallback to default
  local transition = getConfig("transitions").defaultTransition or TRANSITION_DEFAULT
  local transitionClass = transitions[(transitionName or transition)]
  if not transitionClass then
    Log.warn("[Transition.transitionToScene] Unknown transition " .. transitionName .. ", falling back to " .. transition) --#DEBUG
    transitionClass = transitions[transition]
  end

  -- Merge options (arguments take precedence)
  local transitionOpts = mergeTableImmutable(opts or {}, { stackOp = stackOp })

  -- Construct and execute the transition instance
  local transitionInstance = transitionClass(transitionOpts)
  Transition.currentTransition = transitionInstance
  transitionInstance:execute(newScene, currentScene)
end

-- ----------------------------------------
-- Rendering
-- ----------------------------------------

-- ! Prepare Transition Screenshot
-- Prepares a screenshot for transitions if needed.
function Transition.prepareTransitionScreenshot()
  local currentTransition = Transition.currentTransition
  if not currentTransition or not currentTransition.captureScreenshotsDuringTransition then return end

  currentTransition.newSceneScreenshot = newImage(DISPLAY_WIDTH, DISPLAY_HEIGHT)
  pushContext(currentTransition.newSceneScreenshot) -- Push context for capturing screenshot
  currentTransition._screenshotContextPushed = true -- Track context state
end

-- ! Execute Transition Drawing
-- Executes rendering for the active transition effect, restoring draw mode afterward.
function Transition.executeTransitionDrawing()
  if not Transition.isTransitioning then return end
  local currentTransition = Transition.currentTransition
  if not currentTransition then return end

  -- Pop context only once after capture, not every frame!
  if currentTransition.captureScreenshotsDuringTransition and currentTransition._screenshotContextPushed then
    popContext()
    currentTransition._screenshotContextPushed = false
  end

  local drawMode = currentTransition.drawMode or DRAW_MODE_COPY
  local prevDrawMode = getDrawMode()
  if prevDrawMode ~= drawMode then
    setDrawMode(drawMode)
  end
  currentTransition:draw()
  if drawMode ~= prevDrawMode then
    setDrawMode(prevDrawMode)
  end
end
