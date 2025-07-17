-- core/modules/Sequencer.lua

--[[
  *
  * Adapted from Nic Magnier's Sequence library.
  * (https://github.com/NicMagnier/PlaydateSequence)
  *
]]

roxy = roxy or {}
roxy.Sequencer = roxy.Sequencer or {}
local Sequencer <const> = roxy.Sequencer

local pd <const> = playdate

local tableInsert <const> = table.insert
local tableRemove <const> = table.remove

local runningSequences

-- ! Initialize
function Sequencer.init()
  runningSequences = {}
end

-- ! Add
-- Adds a sequence to the list of running sequences.
function Sequencer.add(sequence)
  tableInsert(runningSequences, sequence)
end

-- ! Remove
-- Removes a specific sequence from the list of running sequences.
function Sequencer.remove(sequenceToRemove)
  for i = #runningSequences, 1, -1 do
    if runningSequences[i] == sequenceToRemove then
      tableRemove(runningSequences, i)
      break
    end
  end
end

-- ! Remove All
-- Clears all sequences from the list of running sequences.
function Sequencer.removeAll()
  for i = #runningSequences, 1, -1 do
    runningSequences[i] = nil
  end
end

-- ! Stop All
-- Stops all currently running sequences.
function Sequencer.stopAll()
  for i = #runningSequences, 1, -1 do
    local sequence = runningSequences[i]
    sequence:stop()
  end
end

-- ! Update
-- Updates all running sequences with the given delta time.
function Sequencer.update(dt)
  for i = #runningSequences, 1, -1 do
    local sequence = runningSequences[i]
    sequence:update(dt)
  end
end
