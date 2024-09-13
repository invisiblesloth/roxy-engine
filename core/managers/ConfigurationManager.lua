local pd <const> = playdate
local Object <const> = pd.object

class("ConfigurationManager").extends()

-- Singleton instance for managing configurations globally
local instance = nil

function ConfigurationManager:init()
	self.configuration = {}  -- Initialize an empty configuration table
	self:loadDefaultConfiguration()  -- Load the default configuration settings
end

-- ! Load Default Config
function ConfigurationManager:loadDefaultConfiguration()
	local path = "libraries/roxy/config/config.json"
	local configData = roxy.json.loadJson(path)  -- Load configuration data from JSON file
	if not configData or not configData.defaultConfiguration then
		error("ERROR: Configuration data is missing or corrupted.")  -- Error if the configuration is not properly loaded
	end

	local config = configData.defaultConfiguration
	
	-- Ensure 'fpsPosition' is set, defaulting to "topLeft" if not present
	config.fpsPosition = config.fpsPosition or "topLeft"
	
	self.configuration = config  -- Save the loaded configuration
end

-- ! Get, Set, and Reset Config
function ConfigurationManager:getConfig()
	return self.configuration  -- Return the current configuration
end

function ConfigurationManager:setConfig(config)
	if not config then
		error("ERROR: Configuration cannot be nil. Use 'resetConfig()' to reset to default values.")
	end
	
	-- Update configuration settings from the provided config dictionary
	for key, value in pairs(config) do
		if self.configuration[key] ~= nil then  -- Only update existing keys to prevent adding invalid ones
			self.configuration[key] = value
		end
	end
	
	-- Ensure 'fpsPosition' has a valid value, defaulting if necessary
	self.configuration.fpsPosition = config.fpsPosition or self.configuration.fpsPosition or "topLeft"
end

function ConfigurationManager:resetConfig()
	self:loadDefaultConfiguration()  -- Reload the default configuration settings
end

-- Singleton access method to get the instance of ConfigurationManager
-- @return The singleton instance of ConfigurationManager
function ConfigurationManager.getInstance()
	if not instance then
		instance = ConfigurationManager()  -- Create the instance if it doesn't exist
	end
	return instance  -- Return the singleton instance
end
