-- core/sequences/RoxySequence.lua

--[[
  *
  * Adapted from Nic Magnier's Sequence library.
  * (https://github.com/NicMagnier/PlaydateSequence)
  *
]]

local pd      <const> = playdate
local Object  <const> = pd.object

local r         <const> = roxy
local Sequencer <const> = r.Sequencer

local addSequence     <const> = Sequencer.add
local removeSequence  <const> = Sequencer.remove

--------------------------------------------------------------------------------
-- Private Helper Functions
--------------------------------------------------------------------------------

-- ! Helper: Reset Current Value To Start
local function _resetCurrentValueToStart(sequence)
  local easingArray = sequence.easingArray
  sequence.currentValue = (#easingArray > 0) and easingArray:getValue(0) or 0
end

-- ! Helper: Reset Current Value If Changed
local function _resetCurrentValueIfChanged(sequence, didChange)
  if didChange then
    _resetCurrentValueToStart(sequence)
    return
  end

  Log.warn("[RoxySequence] Native mutation failed") --#DEBUG
end

--------------------------------------------------------------------------------
-- ! Class Definition & Init
--------------------------------------------------------------------------------

class("RoxySequence").extends(Object)

function RoxySequence:init(scene)
  self.isRunning    = false
  self.pacing       = 1
  self.loopType     = 0 -- 0 = no loop, 1 = loop, and 2 = ping-pong
  self.easingArray  = RoxySequenceC.new()
  self.callbacks    = {}
  self.currentValue = 0

  -- Attach to a scene immediately (optional)
  if scene and scene.addSequence then
    scene:addSequence(self)
  end
end

--------------------------------------------------------------------------------
-- Sequence Props
--------------------------------------------------------------------------------

-- ! Set Name
function RoxySequence:setName(name)
  self.easingArray:setName(name)
  return self
end

-- ! Set Pacing
function RoxySequence:setPacing(pacing)
  self.pacing = pacing or 1
  return self
end

-- ! Get Pacing
function RoxySequence:getPacing()
  return self.pacing
end

--------------------------------------------------------------------------------
-- Manage Sequence
--------------------------------------------------------------------------------

-- ! Add
function RoxySequence:add()
  if #self.easingArray == 0 then return self end
  if self.isRunning then return self end
  addSequence(self)
  self.isRunning = true
  return self
end

-- ! Remove
function RoxySequence:remove()
  removeSequence(self)
  self.isRunning = false
  return self
end

-- ! Clear
function RoxySequence:clear(clearEasings)
  self:reset()  -- Stop and reset the sequence
  self.callbacks = {}
  if clearEasings then
    if self.easingArray:clear() then
      self.currentValue = 0
      self.loopType = 0
    end
  end

  if self.scene then
    local scene = self.scene
    self.scene = nil
    -- Guard against double-removal
    if scene.removeSequence then scene:removeSequence(self) end
  end

  return self
end

--------------------------------------------------------------------------------
-- Easing & Keyframing
--------------------------------------------------------------------------------

-- ! Add Easing
function RoxySequence:addEasing(timestamp, from, to, duration, easeFn)
  local didChange = self.easingArray:addEasing(timestamp, from, to, duration, easeFn)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

-- ! Set Easing At
function RoxySequence:setEasingAt(idx, timestamp, from, to, duration, easeFn)
  local didChange = self.easingArray:setEasingAt(idx, timestamp, from, to, duration, easeFn)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

-- ! From
function RoxySequence:from(from)
  local value = from or 0
  local didChange = self.easingArray:from(value)
  if didChange then
    self.currentValue = value
  end
  --#DEBUG START
  if not didChange then Log.warn("[RoxySequence:from] Native mutation failed") end
  --#DEBUG END
  return self
end

-- ! To
function RoxySequence:to(to, duration, easeFn)
  if #self.easingArray == 0 then return self end
  local didChange = self.easingArray:to(to, duration, easeFn)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

-- ! Set
function RoxySequence:set(value)
  if #self.easingArray == 0 then return self end
  local didChange = self.easingArray:set(value)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

-- ! Sleep
function RoxySequence:sleep(duration)
  if #self.easingArray == 0 then return self end
  local didChange = self.easingArray:sleep(duration)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

-- ! Callback
function RoxySequence:callback(callback, timeOffset)
  local easingArray = self.easingArray
  local easingCount = #easingArray
  if easingCount == 0 or not callback then
    return self
  end

  local getEasingData = easingArray.getEasingData
  local lastTimestamp, _, _, lastDuration = getEasingData(easingArray, easingCount)
  local timestamp = lastTimestamp + lastDuration + (timeOffset or 0)

  self.callbacks[#self.callbacks + 1] = { callback, timestamp, false }

  return self
end

--------------------------------------------------------------------------------
-- Rinse & Repeat
--------------------------------------------------------------------------------

-- ! Loop
-- Set sequence to loop continuously
function RoxySequence:loop(loopCount)
  self.loopType = 1
  local didChange = self.easingArray:setLoopType(self.loopType, loopCount)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

-- ! Ping Pong
-- Set sequence to alternate direction after each completion
function RoxySequence:pingPong(loopCount)
  self.loopType = 2
  local didChange = self.easingArray:setLoopType(self.loopType, loopCount)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

-- ! Again
function RoxySequence:again(repeatCount)
  if #self.easingArray == 0 then return self end
  local didChange = self.easingArray:again(repeatCount)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

-- ! Reverse
function RoxySequence:reverse(appendNew)
  if #self.easingArray == 0 then return self end
  local didChange = self.easingArray:reverse(appendNew)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

-- ! Disable Loop
function RoxySequence:disableLoop()
  self.loopType = 0
  local didChange = self.easingArray:setLoopType(self.loopType)
  _resetCurrentValueIfChanged(self, didChange)
  return self
end

--------------------------------------------------------------------------------
-- Playback
--------------------------------------------------------------------------------

-- ! Play
-- Start or resume the sequence from current position
function RoxySequence:play()
  if #self.easingArray == 0 then return self end
  if not self.isRunning then
    self:add()
  end
  return self
end

-- ! Pause
-- Pause the sequence at current position (can be resumed with play)
function RoxySequence:pause()
  if self.isRunning then
    self:remove()
  end
  return self
end

-- ! Is Paused
-- Check if sequence is paused (has easings but not running)
function RoxySequence:isPaused()
  return #self.easingArray > 0 and not self.isRunning
end

-- ! Is Playing
-- Check if sequence is actively playing
function RoxySequence:isPlaying()
  return self.isRunning
end

-- ! Stop
function RoxySequence:stop()
  self:remove()
  return self
end

-- ! Restart
function RoxySequence:restart()
  if #self.easingArray == 0 then return self end
  self:remove()
  self.easingArray:reset()
  _resetCurrentValueToStart(self)
  self:add()
  return self
end

-- ! Reset
function RoxySequence:reset()
  self:remove()
  self.easingArray:reset()
  _resetCurrentValueToStart(self)
  for i = 1, #self.callbacks do
    self.callbacks[i][3] = false -- Reset triggered flags
  end
  return self
end

--------------------------------------------------------------------------------
-- Runtime
--------------------------------------------------------------------------------

-- ! Is Done
function RoxySequence:isDone()
  local easingArray = self.easingArray
  local isDone = easingArray.isDone
  return isDone(easingArray)
end

-- ! Update Loop
function RoxySequence:update(dt)
  local easingArray = self.easingArray
  local pacing = self.pacing
  dt = dt * pacing

  local updateAndGetValue = easingArray.updateAndGetValue
  local oldTime, newTime, newValue, done = updateAndGetValue(easingArray, dt)

  local callbacks = self.callbacks
  local numCallbacks = #callbacks
  for i = 1, numCallbacks do
    local callback = callbacks[i]
    local callbackFn, timestamp, triggered = callback[1], callback[2], callback[3]
    if timestamp >= oldTime and timestamp <= newTime and not triggered then
      callbackFn()
      callback[3] = true
    end
  end

  self.currentValue = newValue
  if done then self:remove() end
end

-- ! Get Value
function RoxySequence:getValue(time)
  return time and self.easingArray:getValue(time) or self.currentValue
end

-- ! Get Total Duration
function RoxySequence:getTotalDuration()
  return self.easingArray:getTotalDuration()
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[
RoxySequence builds fluent numeric timelines for scene-owned or standalone playback.

-- Scene-Owned Position Tween
function GameplayScene:enter()
  self.playerX = 40
  self.playerMove = self:spawnSequence()
    :setName("PlayerMove")
    :from(self.playerX)
    :to(220, 0.35, EasingMap.outCubic)
    :callback(function()
      self.playerState = "idle"
    end)
    :play()
end

function GameplayScene:update(dt)
  self.playerX = self.playerMove:getValue()
end

-- Looping UI Pulse
self.cursorPulse = RoxySequence()
  :from(0.8)
  :to(1.0, 0.2, EasingMap.inOutSine)
  :pingPong()
  :play()

-- Reuse and Cleanup
self.fade = RoxySequence()
  :from(0)
  :to(1, 0.25, EasingMap.linear)

self.fadeDuration = self.fade:getTotalDuration()
self.fade:play()

function GameplayScene:exit()
  self.fade:clear(true)
  self.cursorPulse:stop()
end

-- Rebuild After Completion or Mid-Play
self.fade:reset()
  :from(1)
  :sleep(0.1)
  :to(0, 0.25, EasingMap.outQuad)
  :play()

-- Build Repeated or Mirrored Segments
local patrol = RoxySequence()
  :from(20)
  :to(180, 1.0, EasingMap.inOutCubic)
  :again(1)
  :reverse(true)
  :loop()
  :play()
--]]
