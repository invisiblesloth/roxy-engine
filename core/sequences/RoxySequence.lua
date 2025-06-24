-- core/sequences/RoxySequence.lua

--[[
  *
  * Adapted from Nic Magnier's Sequence library.
  * (https://github.com/NicMagnier/PlaydateSequence)
  *
]]

local pd <const> = playdate

local addSequence     <const> = roxy.Sequencer.add
local removeSequence  <const> = roxy.Sequencer.remove

-- ----------------------------------------
-- ! Class Definition & Init
-- ----------------------------------------

class("RoxySequence").extends()

function RoxySequence:init()
  self.isRunning    = false
  self.pacing       = 1
  self.loopType     = 0 -- 0 = no loop, 1 = loop, and 2 = ping-pong
  self.easingArray  = RoxySequenceC.new()
  self.callbacks    = {}
  self.currentValue = 0
  self.completed    = false

  self.updateAndGetValue = self.easingArray.updateAndGetValue
  self.getTotalDuration = self.easingArray.getTotalDuration
end

-- ----------------------------------------
-- Sequence Props
-- ----------------------------------------

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

-- ! Get and Set Pacing
function RoxySequence:getPacing()
  return self.pacing
end

-- ----------------------------------------
-- Manage Sequence
-- ----------------------------------------

-- ! Add
function RoxySequence:add()
  if #self.easingArray == 0 then return end
  addSequence(self)
  self.isRunning = true
end

-- ! Remove
function RoxySequence:remove()
  removeSequence(self)
  self.isRunning = false
end

-- ! Clear
function RoxySequence:clear(clearEasings)
  self:reset()  -- Stop and reset the sequence
  self.callbacks = {}
  if clearEasings then
    self.easingArray:clear()
  end
end

-- ----------------------------------------
-- Easing & Keyframing
-- ----------------------------------------

-- ! Add Easing
function RoxySequence:addEasing(timestamp, from, to, duration, easeFunction)
  self.easingArray:addEasing(timestamp, from, to, duration, easeFunction)
end

-- ! From
function RoxySequence:from(from)
  self.easingArray:from(from or 0)
  return self
end

-- ! To
function RoxySequence:to(to, duration, easeFunction)
  if #self.easingArray == 0 then return self end
  self.easingArray:to(to, duration, easeFunction)
  return self
end

-- ! Set
function RoxySequence:set(value)
  if #self.easingArray == 0 then return self end
  self.easingArray:set(value)
  return self
end

-- ! Sleep
function RoxySequence:sleep(duration)
  if #self.easingArray == 0 then return self end
  self.easingArray:sleep(duration)
  return self
end

-- ! Callback
function RoxySequence:callback(callbackFunction, timeOffset)
  local easingArray = self.easingArray
  local numEasingArray = #easingArray
  if numEasingArray == 0 or not callbackFunction then
    return self
  end

  local getEasingData = easingArray.getEasingData
  local lastTimestamp, _, _, lastDuration = getEasingData(easingArray, numEasingArray)
  local timestamp = lastTimestamp + lastDuration + (timeOffset or 0)

  self.callbacks[#self.callbacks + 1] = { callbackFunction, timestamp, false }

  return self
end

-- ----------------------------------------
-- Rinse & Repeat
-- ----------------------------------------

-- ! Loop
-- Set sequence to loop continuously
function RoxySequence:loop(loopCount)
  self.loopType = 1
  self.easingArray:setLoopType(self.loopType, loopCount)
  return self
end

-- ! Ping Pong
-- Set sequence to alternate direction after each completion
function RoxySequence:pingPong(loopCount)
  self.loopType = 2
  self.easingArray:setLoopType(self.loopType, loopCount)
  return self
end

-- ! Again
function RoxySequence:again(repeatCount)
  if #self.easingArray == 0 then return self end
  self.easingArray:again(repeatCount)
  return self
end

-- ! Reverse
function RoxySequence:reverse(appendNew)
  if #self.easingArray == 0 then return self end
  self.easingArray:reverse(appendNew)
  return self
end

-- ! Disable loop
function RoxySequence:disableLoop()
  self.loopType = 0
  self.easingArray:setLoopType(self.loopType)
  return self
end

-- ----------------------------------------
-- Playback
-- ----------------------------------------

-- ! Start
function RoxySequence:start()
  if #self.easingArray == 0 then return self end
  if not self.isRunning then
    self:add()
  end
  return self
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
  self:add()
  return self
end

-- ! Reset
function RoxySequence:reset()
  self:remove()
  self.easingArray:reset()
  for i = 1, #self.callbacks do
    self.callbacks[i][3] = false -- Reset triggered flags
  end
  return self
end

-- ----------------------------------------
-- Runtime
-- ----------------------------------------

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
    local callbackFunction, timestamp, triggered = callback[1], callback[2], callback[3]
    if timestamp >= oldTime and timestamp <= newTime and not triggered then
      callbackFunction()
      callback[3] = true
    end
  end

  self.currentValue = newValue
  if done then self:remove() end
end

-- ! Get Value (Value Calculation/Progress)
function RoxySequence:getValue(time)
  return time and self.easingArray:getValue(time) or self.currentValue
end
