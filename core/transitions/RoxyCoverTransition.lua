-- core/transitions/RoxyCoverTransition.lua

local pd            <const> = playdate
local r             <const> = roxy
local Graphics      <const> = pd.graphics
local Ease          <const> = r.EasingFunctions
local Transition    <const> = r.Transition

local mergeTableImmutable <const> = r.Table.mergeImmutable

local newImage          <const> = Graphics.image.new
local drawImage         <const> = Graphics.image.draw
local drawFaded         <const> = Graphics.image.drawFaded
local setImageDrawMode  <const> = Graphics.setImageDrawMode

local EMPTY_TABLE <const> = {}

local COLOR_BLACK       <const> = Graphics.kColorBlack
local DRAW_MODE_COPY    <const> = Graphics.kDrawModeCopy
local DITHER_BAYER_8X8  <const> = Graphics.image.kDitherTypeBayer8x8

local DISPLAY_WIDTH   <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = r.Graphics.displayHeight

local SEQUENCE_START_VALUE    <const> = 0
local SEQUENCE_MIDPOINT_VALUE <const> = 1
local SEQUENCE_RESUME_VALUE   <const> = 1
local SEQUENCE_COMPLETE_VALUE <const> = 0

local FALLBACK_DITHER   <const> = DITHER_BAYER_8X8
local FALLBACK_PANEL    <const> = newImage(DISPLAY_WIDTH, DISPLAY_HEIGHT, COLOR_BLACK)
local FALLBACK_SEQUENCE <const> = RoxySequence()

local DEFAULT_OPTS <const> = {
  name                  = "Cover",
  type                  = "Cover",
  ease                  = Ease.linear,
  drawMode              = DRAW_MODE_COPY,
  dither                = false,
  panelImage            = false,
  sequenceStartValue    = SEQUENCE_START_VALUE,
  sequenceMidpointValue = SEQUENCE_MIDPOINT_VALUE,
  sequenceResumeValue   = SEQUENCE_RESUME_VALUE,
  sequenceCompleteValue = SEQUENCE_COMPLETE_VALUE,
}

-- ----------------------------------------
-- ! Class Definition & Init
-- ----------------------------------------

class("RoxyCoverTransition").extends(RoxyTransition)

function RoxyCoverTransition:init(duration, holdTime, opts, stackOp)
  local opts = mergeTableImmutable(DEFAULT_OPTS, (opts or EMPTY_TABLE))

  -- Lazy-load assets if not provided
  if not opts.dither then
    opts.dither = FALLBACK_DITHER
    self._ownsDither = true
  end
  if not opts.panelImage then
    opts.panelImage = FALLBACK_PANEL
    self._ownsPanel = true
  end
  if not opts.sequence then
    opts.sequence = FALLBACK_SEQUENCE
    self._ownsSequence = true
  end

  RoxyCoverTransition.super.init(self, duration, holdTime, opts, stackOp)

  -- Easing
  self.ease = opts.ease
  local enter = Ease.enter
  local exit  = Ease.exit
  self.easeEnter  = enter(self.ease) or self.ease
  self.easeExit   = exit (self.ease) or self.ease

  -- Graphics
  self.drawMode   = opts.drawMode
  self.dither     = opts.dither
  self.panelImage = opts.panelImage

  -- Sequence
  self.sequenceStartValue     = opts.sequenceStartValue
  self.sequenceMidpointValue  = opts.sequenceMidpointValue
  self.sequenceResumeValue    = opts.sequenceResumeValue
  self.sequenceCompleteValue  = opts.sequenceCompleteValue
  self.sequence               = opts.sequence
end

-- ----------------------------------------
-- Lifecycle Execution
-- ----------------------------------------

-- ! Set Up Sequence
-- Creates the animation sequence to cover and reveal the scene.
function RoxyCoverTransition:setUpSequence(onStart, onMidpoint, onHoldTimeElapsed, onComplete)
  local halfHold  = self.holdTime / 2
  local enterTime = self.durationEnter - halfHold
  local exitTime  = self.durationExit  - halfHold
  local sequence  = self.sequence

  sequence
    :from(self.sequenceStartValue)
    :to(self.sequenceMidpointValue, enterTime, self.easeEnter)
    :callback(onMidpoint)
    :sleep(self.holdTime)
    :callback(onHoldTimeElapsed)
    :to(self.sequenceResumeValue, 0)
    :to(self.sequenceCompleteValue, exitTime, self.easeExit)
    :callback(onComplete)

  onStart()
  sequence:start()
end

-- ! Cleanup
-- Frees allocated assets and clears the transition state.
function RoxyCoverTransition:cleanup()
  if self._ownsSequence then
    self.sequence:clear(true)
    self.sequence = nil
  end

  self.panelImage = nil
  self.dither = nil

  RoxyCoverTransition.super.cleanup(self)
end

-- ----------------------------------------
-- Rendering
-- ----------------------------------------

-- ! Draw
-- Renders the panel image at varying opacity based on sequence progress.
function RoxyCoverTransition:draw()
  local sequence = self.sequence
  if not sequence then return end

  local alpha = sequence:getValue() or 0
  if alpha <= 0 then return end

  if self.drawMode ~= DRAW_MODE_COPY then
    setImageDrawMode(self.drawMode)
  end

  if alpha >= 1 then
    drawImage(self.panelImage, self.x, self.y)
  else
    drawFaded(self.panelImage, self.x, self.y, alpha, self.dither)
  end

  if self.drawMode ~= DRAW_MODE_COPY then
    setImageDrawMode(DRAW_MODE_COPY)
  end
end
