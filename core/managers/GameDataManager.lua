local MAX_SLOT_LIMIT = 1000  -- Maximum limit for the number of game data slots

local configurationManager <const> = ConfigurationManager.getInstance()

local pd <const> = playdate
local Object <const> = pd.object
local File <const> = pd.file
local Datastore <const> = pd.datastore

class("GameDataManager").extends()

-- Singleton instance for managing game data globally
local instance = nil

function GameDataManager:init()
	self.gameDatas = {}
	self.gameDataDefault = nil
	self.numberOfGameDataSlotsAtSetup = 1	-- Number of slots at setup
	self.numberOfSlots = 1					-- Current number of active slots
	self.currentSlot = 1					-- Slot currently in use
	self.gameDataHasBeenSetup = false		-- Flag to prevent multiple setups
	
	-- Determine the maximum number of slots allowed, with validation
	local maxSaveSlots = configurationManager:getConfig().maxSaveSlots
	self.maxNumberOfSlots = self:validateMaxSlots(maxSaveSlots) or 10
end

function GameDataManager:validateMaxSlots(maxSlots)
	-- Validate and cap the maximum number of slots within the allowed limit
	if type(maxSlots) == "number" and maxSlots >= 1 then
		return math.min(maxSlots, MAX_SLOT_LIMIT)
	end
	return nil
end

-- ! Setup Game Data Manager
function GameDataManager:setup(gameData, numberOfSlots, saveToDisk, modifyExistingData)
	if self.gameDataHasBeenSetup then
		error("ERROR: You can only run 'GameDataManager:setup()' once.")
		return
	end
	
	numberOfSlots = numberOfSlots or self.numberOfSlots
	self.numberOfGameDataSlotsAtSetup = numberOfSlots
	self.maxNumberOfSlots = math.min(math.max(self.maxNumberOfSlots, numberOfSlots), MAX_SLOT_LIMIT)
	self.gameDataDefault = gameData
	local gameDatas = self.gameDatas
	
	-- Function to set default values for game data using metatables
	local function setDefaults(t, defaults)
		if type(t) ~= "table" or type(defaults) ~= "table" then
			error("ERROR: setDefaults expects two tables.")
		end
		setmetatable(t, {
			__index = function(_, key)
				return defaults[key]
			end
		})
	end
	
	modifyExistingData = modifyExistingData ~= false
	
	-- Initialize game data for each slot
	for i = 1, numberOfSlots do
		local success, existingGameData = pcall(Datastore.read, "Game" .. i)
		if not success then
			error("ERROR: Failed to read data from Datastore for slot " .. i)
		end
		
		if existingGameData == nil or modifyExistingData then
			local successCopy, defaultData = pcall(roxy.table.copy, self.gameDataDefault)
			if not successCopy then
				error("ERROR: Failed to copy gameDataDefault for slot " .. i)
			end
			
			gameDatas[i] = {
				data = defaultData,
				timestamp = pd.getGMTTime()  -- Record the setup time
			}
			setDefaults(gameDatas[i].data, self.gameDataDefault)
		else
			local successCopy, retainedData = pcall(roxy.table.copy, existingGameData.data)
			if not successCopy then
				error("ERROR: Failed to copy existing game data for slot " .. i)
			end
			
			setDefaults(retainedData, self.gameDataDefault)
			gameDatas[i] = {
				data = retainedData,
				timestamp = existingGameData.timestamp
			}
		end
	end
	
	self.numberOfSlots = numberOfSlots
	self.gameDataHasBeenSetup = true
	
	if saveToDisk ~= false then
		self:saveAll()  -- Save all slots to disk if required
	end
end

-- Check if a game data slot and optionally a specific data item exist
function GameDataManager:exists(gameDataSlot, gameDataKey)
	-- Validate the game slot number
	if gameDataSlot > #self.gameDatas or gameDataSlot <= 0 then
		error("ERROR: Game Slot number " .. gameDataSlot .. " does not exist.")
		return false
	end

	if gameDataKey ~= nil then
		-- Check if the specific data item exists in the slot
		if self.gameDatas[gameDataSlot].data[gameDataKey] ~= nil then
			return true
		else
			error("ERROR: Game Datum '" .. gameDataKey .. "' does not exist.")
			return false
		end
	else
		-- If no specific data key, just confirm the slot exists
		return true
	end
end

-- ! Get Game Data
function GameDataManager:get(dataItemName, gameDataSlot)
	local slot = gameDataSlot or self.currentSlot
	if self:exists(slot, dataItemName) then
		return self.gameDatas[slot].data[dataItemName]  -- Return the requested game data item
	end
end

function GameDataManager:getSlot(gameDataSlot)
	self.currentSlot = gameDataSlot or self.currentSlot
	if self:exists(self.currentSlot) then
		return self.gameDatas[self.currentSlot]  -- Return game data for the specified or current slot
	end
end

function GameDataManager:getAllGameData()
	return self.gameDatas  -- Return all game data across all slots
end

-- ! Set Game Data
function GameDataManager:set(dataItemName, itemValue, gameDataSlot, saveToDisk, updateTimestamp)
	local slot = gameDataSlot or self.currentSlot
	
	if self:exists(slot, dataItemName) then
		self.gameDatas[slot].data[dataItemName] = itemValue  -- Set the new value for the data item
		if updateTimestamp ~= false then
			self.gameDatas[slot].timestamp = pd.getGMTTime()  -- Update the timestamp if required
		end
		if saveToDisk ~= false then
			self:save(slot)  -- Save the slot data to disk if required
		end
	end
end

function GameDataManager:setSlot(dataTable, gameDataSlot, saveToDisk, updateTimestamp)
	if type(dataTable) ~= "table" then
		error("ERROR: The 'dataTable' parameter must be a non-nil table. The provided value is either nil or not a table. Nothing was set.")
		return
	end

	local slot = gameDataSlot or self.currentSlot
	
	if self:exists(slot) then
		self.gameDatas[slot].data = roxy.table.copy(dataTable)  -- Set the entire slot data to the provided table
		if updateTimestamp ~= false then
			self.gameDatas[slot].timestamp = pd.getGMTTime()  -- Update the timestamp if required
		end
		if saveToDisk ~= false then
			self:save(slot)  -- Save the slot data to disk if required
		end
	end
end

-- ! Reset Game Data
function GameDataManager:reset(dataItemName, gameDataSlot, saveToDisk, updateTimestamp)
	local slot = gameDataSlot or self.currentSlot

	if self:exists(slot, dataItemName) then
		-- Reset the specified data item to its default value
		self.gameDatas[slot].data[dataItemName] = self.gameDataDefault[dataItemName]
		
		if updateTimestamp ~= false then
			self.gameDatas[slot].timestamp = pd.getGMTTime()  -- Update the timestamp if required
		end

		if saveToDisk ~= false then
			self:save(slot)  -- Save the slot data to disk if required
		end
	end
end

function GameDataManager:resetSlot(gameDataSlot, saveToDisk, updateTimestamp)
	local slot = gameDataSlot or self.currentSlot

	if not self:exists(slot) then
		error("ERROR: Game Slot number " .. slot .. " does not exist. Cannot reset slot.")
		return
	end

	local slotData = self.gameDatas[slot]
	if slotData then
		slotData.data = table.deepcopy(self.gameDataDefault)  -- Reset all data in the slot to defaults

		if updateTimestamp ~= false then
			slotData.timestamp = pd.getGMTTime()  -- Update the timestamp if required
		end

		if saveToDisk ~= false then
			self:save(slot)  -- Save the slot data to disk if required
		end
	end
end

function GameDataManager:resetAll(saveToDisk, updateTimestamp)
	-- Iterate through each game data slot and reset it to defaults
	for slotIndex = 1, self.numberOfSlots do
		self:resetSlot(slotIndex, saveToDisk, updateTimestamp)
	end
end

-- ! Add Slots
function GameDataManager:addSlots(numberToAdd, saveToDisk)
	numberToAdd = numberToAdd or 1
	
	if numberToAdd < 1 then
		warn("Warning: Don't use a number smaller than 1. Nothing was added.")
		return
	end
	
	-- Check if adding slots would exceed the maximum allowed
	if self.numberOfSlots + numberToAdd > self.maxNumberOfSlots then
		error("ERROR: Exceeding the maximum number of slots. Nothing was added.")
		return
	end
	
	-- Add the specified number of slots with default data
	for i = 1, numberToAdd do
		self.gameDatas[i + self.numberOfSlots] = {
			data = table.deepcopy(self.gameDataDefault),
			timestamp = pd.getGMTTime()  -- Set the creation timestamp
		}
		
		if saveToDisk ~= false then
			self:save(i + self.numberOfSlots)  -- Save the new slot to disk if required
		end
	end
	
	self.numberOfSlots += numberToAdd  -- Update the slot count
end

-- ! Delete Slot
function GameDataManager:deleteSlot(gameDataSlot, collapseGameData, saveToDisk, forceDelete)
	if gameDataSlot == nil then
		error("ERROR: You must specify a game data slot to delete. Nothing was deleted.")
		return
	end
	
	-- Validate the game slot number
	if gameDataSlot > self.numberOfSlots or gameDataSlot <= 0 then
		error("ERROR: Game Slot number " .. gameDataSlot .. " does not exist. Nothing was deleted.")
		return
	end
	
	collapseGameData = collapseGameData ~= false
	forceDelete = forceDelete ~= false

	if self:exists(gameDataSlot) then
		local fileName = "Game" .. gameDataSlot .. ".json"
		if gameDataSlot > self.numberOfGameDataSlotsAtSetup or forceDelete then
			-- If the slot is beyond the initial setup or 
			-- force deletion is enabled, delete it
			if File.exists(fileName) then
				self.gameDatas[gameDataSlot] = nil  -- Clear from memory
				Datastore.delete("Game" .. gameDataSlot)  -- Clear from disk
				
				if self.currentSlot == gameDataSlot then
					self.currentSlot = 1  -- Reset current slot to 1 if the deleted slot was active
				end

				if collapseGameData then
					-- Collapse the game data to remove gaps in slot numbering
					local newGameDatas = {}
					for i = 1, #self.gameDatas do
						if self.gameDatas[i] ~= nil then
							table.insert(newGameDatas, self.gameDatas[i])
							if i >= gameDataSlot then
								-- Rename files to reflect collapsed slot numbers
								local oldFileName = "Game" .. i .. ".json"
								local newFileName = "Game" .. (i - 1) .. ".json"
								if File.exists(oldFileName) then
									File.rename(oldFileName, newFileName)
								end
							end
						end
					end
					self.gameDatas = newGameDatas
					self.numberOfSlots = #self.gameDatas
					
					-- Adjust the number of default slots if a default slot was force deleted
					if gameDataSlot <= self.numberOfGameDataSlotsAtSetup then
						self.numberOfGameDataSlotsAtSetup -= 1
					end
				end
			else
				self.gameDatas[gameDataSlot] = nil  -- Remove from memory if not on disk
			end
		else
			-- If the slot was part of the default setup, reset it instead of deleting
			self:resetSlot(gameDataSlot, saveToDisk, true)
		end
	end
end

function GameDataManager:deleteAll(saveToDisk, forceDelete)
	if self.numberOfSlots == 0 then
		warn("Warning: No slots available to delete.")
		return
	end
	
	-- Iterate backwards through the slots and delete each one
	for i = self.numberOfSlots, 1, -1 do
		self:deleteSlot(i, false, saveToDisk, forceDelete)
	end
end

-- ! Get Data Timestamp
function GameDataManager:getTimestamp(gameDataSlot, humanReadable)
	if self:exists(gameDataSlot) then
		local rawTimestamp = self.gameDatas[gameDataSlot].timestamp
		
		if humanReadable then
			-- Convert raw timestamp to human-readable format
			local seconds, milliseconds = pd.epochFromGMTTime(rawTimestamp)
			local readableTimestamp = pd.timeFromEpoch(seconds, milliseconds)
			
			-- Format human-readable timestamp
			local humanReadableString = string.format(
				"%04d-%02d-%02d %02d:%02d:%02d.%03d",
				readableTimestamp.year,
				readableTimestamp.month,
				readableTimestamp.day,
				readableTimestamp.hour,
				readableTimestamp.minute,
				readableTimestamp.second,
				readableTimestamp.millisecond
			)
	
			return humanReadableString, rawTimestamp
		else
			return rawTimestamp  -- Return raw timestamp if human-readable is not requested
		end
	end
end

-- ! Get Number of Slots
function GameDataManager:getNumberOfSlots()
	return self.numberOfSlots  -- Return the current number of slots
end

-- ! Get Current Slot
function GameDataManager:getCurrentSlot()
	return self.currentSlot  -- Return the current slot in use
end

-- ! Set Current Slot
function GameDataManager:setCurrentSlot(gameDataSlot)
	if not gameDataSlot or type(gameDataSlot) ~= "number" then
		error("ERROR: Invalid slot number. The slot number must be a valid integer.")
	elseif gameDataSlot <= 0 or gameDataSlot > self.numberOfSlots then
		error("ERROR: Game Slot number " .. gameDataSlot .. " does not exist. Cannot set current slot.")
	else
		self.currentSlot = gameDataSlot  -- Set the current slot to the specified slot
	end
end

-- ! Save Game Data to Disk
function GameDataManager:save(gameDataSlot)
	gameDataSlot = gameDataSlot or self.currentSlot
	if self:exists(gameDataSlot) then
		Datastore.write(self.gameDatas[gameDataSlot], "Game" .. gameDataSlot)  -- Save the slot data to disk
	end
end

function GameDataManager:saveAll()
	for i = 1, self.numberOfSlots do
		Datastore.write(self.gameDatas[i], "Game" .. i)  -- Save all slots to disk
	end
end

-- Singleton access method to get the instance of GameDataManager
-- @return The singleton instance of GameDataManager
function GameDataManager.getInstance()
	if not instance then
		instance = GameDataManager()  -- Create and return the singleton instance
	end
	return instance
end
