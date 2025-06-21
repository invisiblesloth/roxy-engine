-- core/modules/Transition.lua

roxy = roxy or {}
roxy.Transition = roxy.Transition or {}
local Transition <const> = roxy.Transition

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local r         <const> = roxy
local Scene     <const> = r.Scene

local STACK_OP_REPLACE <const> = 0
local STACK_OP_PUSH    <const> = 1
local STACK_OP_POP     <const> = 2

local TRANSITION_DEFAULT <const> = "Cut"

local DRAW_MODE_COPY  <const> = Graphics.kDrawModeCopy

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

-- Aliases
local pushContext <const> = Graphics.pushContext
local popContext  <const> = Graphics.popContext
local newImage    <const> = Graphics.image.new
local getDrawMode <const> = Graphics.getImageDrawMode
local setDrawMode <const> = Graphics.setImageDrawMode

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
    error("[*][Transition.loadTransitions] transitionsTable must be a table.", 2) --#DEBUG
    return
  end
  for key, value in pairs(transitionsTable) do
    if type(key) ~= "string" then
      error("[*][Transition.loadTransitions] Transition key must be a string.", 2) --#DEBUG
      return
    elseif type(value) ~= "table" or not value.__index then
      error("[*][Transition.loadTransitions] Transition value must be a valid class.", 2) --#DEBUG
      return
    end
  end

  transitions = transitionsTable
end

-- ! Replace Scene
function Transition.replaceScene(newSceneClass, transitionName, duration, holdTime, opts)
  Transition.stackOp = STACK_OP_REPLACE
  Transition.transitionToScene(newSceneClass, transitionName, duration, holdTime, opts)
end

-- ! Push Scene
function Transition.pushScene(newSceneClass, transitionName, duration, holdTime, opts)
  Transition.stackOp = STACK_OP_PUSH
  Transition.transitionToScene(newSceneClass, transitionName, duration, holdTime, opts)
end

-- ! Pop Scene
function Transition.popScene(transitionName, duration, holdTime, opts)
  Transition.stackOp = STACK_OP_POP
  Transition.transitionToScene(nil, transitionName, duration, holdTime, opts)
end

-- ! Transition to Scene
-- Initiates a scene transition using the specified effect and timing.
function Transition.transitionToScene(newSceneClass, transitionName, duration, holdTime, opts)
  --#DEBUG START
  if Transition.isTransitioning then
    warn("[W][Transition.transitionToScene] Transition already in progress.")
    return
  end
  --#DEBUG END

  local stackOp = Transition.stackOp
  local newScene = nil
  if stackOp ~= STACK_OP_POP then
    newScene = newSceneClass()
    --#DEBUG START
    if not newScene then
      error("[*][Transition.transitionToScene] Failed to instantiate newSceneClass.", 2)
    end
    --#DEBUG END
  end

  Transition.isTransitioning = true
  local currentScene = Scene.currentScene

  -- Use transition or fallback to default
  local transitionClass = transitions[(transitionName or TRANSITION_DEFAULT)]
  if not transitionClass then
    warn("[W][Transition.transitionToScene] Unknown transition " .. transitionName .. ", falling back to " .. TRANSITION_DEFAULT) --#DEBUG
    transitionClass = transitions[TRANSITION_DEFAULT]
  end

  -- Construct and execute the transition instance
  local transitionInstance = transitionClass(duration, holdTime, opts, stackOp)
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
