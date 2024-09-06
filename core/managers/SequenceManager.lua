--
-- Adapted from 
-- Nic Magnier's Sequence library (https://github.com/NicMagnier/PlaydateSequence)
--

local pd <const> = playdate
local Object <const> = pd.object

class("SequenceManager").extends()

-- Singleton instance for managing sequences globally
local instance = nil

function SequenceManager:init()
	SequenceManager.super.init(self)
	self.runningSequences = {}  -- Table to hold all currently running sequences
end

-- ! Add and Remove Sequence
function SequenceManager:add(sequence)
	-- Add a sequence to the list of running sequences
	table.insert(self.runningSequences, sequence)
end

function SequenceManager:remove(sequenceToRemove)
	-- Remove a specific sequence from the list of running sequences
	for i = #self.runningSequences, 1, -1 do
		if self.runningSequences[i] == sequenceToRemove then
			table.remove(self.runningSequences, i)
			break  -- Exit the loop once the sequence is found and removed
		end
	end
end

function SequenceManager:removeAll()
	-- Remove all sequences from the list of running sequences
	for i = #self.runningSequences, 1, -1 do
		table.remove(self.runningSequences, i)
	end
end

-- ! Stop All Sequences
function SequenceManager:stopAll()
	-- Stop all running sequences and then remove them from the list
	for i = #self.runningSequences, 1, -1 do
		local sequence = self.runningSequences[i]
		sequence:stop()  -- Call the stop method on each sequence
	end
end

-- ! Update
function SequenceManager:update(deltaTime)
	local runningSequences = self.runningSequences
	-- Iterate through all running sequences, updating each one
	for i = #runningSequences, 1, -1 do
		local sequence = runningSequences[i]
		
		sequence:update(deltaTime)  -- Update the sequence with the current delta time
		
		-- If the sequence is done, remove it from the list
		if sequence:isDone() then
			self:remove(sequence)
		end
	end
end

-- Singleton access method to get the instance of SequenceManager
-- @return The singleton instance of SequenceManager
function SequenceManager.getInstance()
	if not instance then
		instance = SequenceManager()  -- Create the instance if it doesn't exist
	end
	return instance
end
