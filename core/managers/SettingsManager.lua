local pd <const> = playdate
local Object <const> = pd.object
local Datastore <const> = pd.datastore
local Table <const> = roxy.table

class("SettingsManager").extends()

-- Singleton instance for managing settings globally
local instance = nil

function SettingsManager:init()
	self.settings = {}
	self.settingsDefault = {}
	self.settingsHaveBeenSetup = false
end

-- ! Setup Game Settings Manager
function SettingsManager:setup(settings, saveToDisk, updateValuesIfChanged, retainOldKeys)
	if self.settingsHaveBeenSetup then
		warn("Warning: You can only run 'SettingsManager.setup()' once.")
		return
	end

	-- Ensure settings are provided before attempting setup
	if settings == nil or Table.getSize(settings) == 0 then
		warn("Warning: Use 'SettingsManager.setup' only if you have settings to register. New settings must be declared upfront in 'SettingsManager.setup'.")
		return
	end

	-- Load existing settings from disk if they exist
	local existingSettings = Datastore.read("Settings")

	-- Store the provided settings as the defaults
	self.settingsDefault = table.deepcopy(settings)

	if existingSettings then
		-- Merge existing settings with the provided defaults
		self.settingsDefault = Table.deepMerge(self.settingsDefault, existingSettings)
	end

	-- Initialize current settings based on existing settings or defaults
	self.settings = existingSettings and table.deepcopy(existingSettings) or table.deepcopy(self.settingsDefault)

	if existingSettings then
		for key, value in pairs(settings) do
			-- Update settings if they are new or if update is allowed
			if existingSettings[key] == nil or updateValuesIfChanged ~= false then
				self.settings[key] = value
				self.settingsDefault[key] = value
			end
		end

		-- Optionally remove old keys that are not in the provided settings
		if retainOldKeys ~= true then
			for key in pairs(existingSettings) do
				if settings[key] == nil then
					self.settings[key] = nil
					self.settingsDefault[key] = nil
				end
			end
		end
	end

	-- Mark the settings as having been set up
	self.settingsHaveBeenSetup = true

	-- Optionally save settings to disk
	if saveToDisk ~= false then
		self:save()
	end
end

-- Check if a specific setting exists
function SettingsManager:settingExists(settingKey)
	if self.settings[settingKey] ~= nil then
		return true
	end
	warn("Warning: Setting '" .. settingKey .. "' does not exist.")
	return false
end

-- ! Get, Set, and Reset Game Setting
function SettingsManager:get(settingName)
	if self:settingExists(settingName) then
		return self.settings[settingName]  -- Return the value of the requested setting
	end
end

function SettingsManager:getAllSettings()
	return self.settings  -- Return all current settings
end

function SettingsManager:getDefaultSettings()
	return self.settingsDefault  -- Return the default settings
end

function SettingsManager:set(settingNameOrTable, settingValue, saveToDisk)
	-- Allow setting multiple values if a table is passed
	if type(settingNameOrTable) == "table" then
		for key, value in pairs(settingNameOrTable) do
			if self:settingExists(key) then
				self.settings[key] = value  -- Update the setting
			end
		end
	else
		-- Update a single setting
		if self:settingExists(settingNameOrTable) then
			self.settings[settingNameOrTable] = settingValue
		end
	end

	-- Optionally save changes to disk
	if saveToDisk ~= false then
		self:save()
	end
end

function SettingsManager:reset(settingName, saveToDisk)
	-- Reset a setting to its default value
	if self:settingExists(settingName) then
		self.settings[settingName] = self.settingsDefault[settingName]
		if saveToDisk ~= false then
			self:save()
		end
	end
end

function SettingsManager:resetSome(settingNames, saveToDisk)
	-- Reset multiple settings to their default values
	for i = #settingNames, 1, -1 do
		self:reset(settingNames[i], saveToDisk)
	end
end

function SettingsManager:resetAll(saveToDisk)
	-- Reset all settings to their default values
	self.settings = table.deepcopy(self.settingsDefault)
	if saveToDisk ~= false then
		self:save()
	end
end

-- ! Save Settings to Disk
function SettingsManager:save()
	-- Save the current settings to disk
	Datastore.write(self.settings, "Settings")
end

-- Singleton access method to get the instance of SettingsManager
-- @return The singleton instance of SettingsManager
function SettingsManager.getInstance()
	if not instance then
		instance = SettingsManager()  -- Create the instance if it doesn't exist
	end
	return instance
end
