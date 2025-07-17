-- core/modules/Config.lua

roxy = roxy or {}
roxy.Config = roxy.Config or {}
local Config <const> = roxy.Config

local tableInsert       <const> = table.insert
local tableConcat       <const> = table.concat
local tableShallowCopy  <const> = table.shallowcopy
local deepMerge         <const> = roxy.Table.deepMerge

local loadJSON          <const> = roxy.JSON.loadJson

local FALLBACKS <const> = {
  input = {
    buttonHoldBufferAmount = 3,
    crankDirection = 1
  },
  assets = {
    maxCacheSize = 50,
    musicCacheSize = 3,
    soundsCacheSize = 20
  },
  transitions = {
    duration = 1.5,
    holdTime = 0.25
  },
  gameData = {
    saveSlots = 3
  }
}

local SCHEMA <const> = {
  logLevel = "string",
  debugging = {
    showFPS = "boolean",
    fpsPosition = "table",
    enableDebugChecks = "boolean",
    enableVisualDebugChecks = "boolean"
  },
  input = {
    buttonHoldBufferAmount = "number",
    crankDirection = "number"
  },
  assets = {
    maxCacheSize = "number",
    musicCacheSize = "number",
    soundsCacheSize = "number"
  },
  transitions = {
    defaultTransition = "string",
    duration = "number",
    holdTime = "number",
    overrides = "table"
  },
  gameData = {
    saveSlots = "number"
  }
}

local activeConfig = {} -- Private configuration state
local changeListeners = {}
local isInitialized = false -- Track initialization state
Config.transitionConfigs = {} -- Initialize transition configs storage

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Validate Config
local function validateConfig(config, schema, path)
  path = path or "config"
  for key, value in pairs(config) do
    local expectedType = schema[key]
    if not expectedType then
      Log.warn(function()
        return string.format("Unknown config key: %s.%s", path, key)
      end)
    elseif type(expectedType) == "table" then
      if type(value) == "table" then
        validateConfig(value, expectedType, path .. "." .. key)
      else
        Log.error(function()
          return string.format("Expected table for %s.%s, got %s", path, key, type(value))
        end)
      end
    elseif type(value) ~= expectedType then
      Log.error(function()
        return string.format("Expected %s for %s.%s, got %s", expectedType, path, key, type(value))
      end)
    end
  end
end

-- ! Load File
-- Loads configuration from a JSON file at the specified path.
-- @param path string File path to load
-- @return table|nil Configuration data or nil if loading failed
local function loadConfigFile(path)
  local data = loadJSON(path)
  if data and type(data) == "table" then
    Log.debug("Loaded config from: " .. path) --#DEBUG
    return data
  end

  Log.debug("Config file not found or invalid: " .. path) --#DEBUG
  return nil
end

-- ! Notify Change
-- Notifies all registered change callbacks
-- @param config table Current configuration snapshot
local function notifyConfigChanged(config)
  for _, callback in ipairs(changeListeners) do
    local ok, err = pcall(callback, config)
    if not ok then
      Log.warn("Config change callback failed: " .. tostring(err)) --#DEBUG
    end
  end
end

-- ! Set Metatable
-- Read-only proxy for configuration access
local peekProxy = setmetatable({}, {
  __index = function(_, key)
    if not isInitialized then
      Log.warn("Config accessed before initialization - using fallbacks") --#DEBUG
      return FALLBACKS[key]
    end
    return activeConfig[key]
  end,
  __newindex = function()
    Log.error("Config table is read-only. Use Config.setConfig() to modify.", 2)
  end,
  __pairs = function()
    if not isInitialized then
      return pairs(FALLBACKS)
    end
    return pairs(activeConfig)
  end
})

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Initialize Configuration
-- Loads and merges all configurations using the builder pattern.
-- Priority: FALLBACKS < default config.json < user config.json < overrides
-- @param overrides table|nil Optional runtime overrides (highest priority)
-- @return table The final merged configuration
function Config.init(overrides)
  if isInitialized then
    Log.warn("Config already initialized - use Config.applyOverrides() instead") --#DEBUG
    return activeConfig
  end

  local userPath = "config/config.json"
  local defaultPath = "libraries/roxy/config/config.json"

  local defaultConfig = loadConfigFile(defaultPath)
  local userConfig = loadConfigFile(userPath)

  local builder = TableBuilder(FALLBACKS)
    :with(defaultConfig)
    :with(userConfig)
    :with(overrides)

  activeConfig = builder:build()
  validateConfig(activeConfig, SCHEMA)
  isInitialized = true

  --#DEBUG START
  -- Log what was actually loaded
  local loadedSources = {}
  if defaultConfig then tableInsert(loadedSources, "engine defaults") end
  if userConfig then tableInsert(loadedSources, "user config") end
  if overrides then tableInsert(loadedSources, "runtime overrides") end

  if #loadedSources > 0 then
    Log.info("Config initialized with: " .. tableConcat(loadedSources, " + "))
  else
    Log.info("Config initialized with fallbacks only")
  end
  --#DEBUG END

  notifyConfigChanged(Config.peek())
  return activeConfig
end

-- ! Load All Configurations (Deprecated)
-- Backwards compatibility wrapper
-- @param overrides table|nil Optional runtime overrides
-- @return table The final merged configuration
function Config.loadAllConfigs(overrides)
  Log.warn("Config.loadAllConfigs() is deprecated - use Config.initialize()") --#DEBUG
  return Config.initialize(overrides)
end

-- ! Is Initialized
-- Checks if configuration has been initialized
-- @return boolean True if initialized
function Config.isInitialized()
  return isInitialized
end

-- ! Peek
-- Returns a read-only proxy to the current configuration.
-- @return table Read-only configuration proxy
function Config.peek()
  return peekProxy
end

-- ! Get Configuration
-- Gets a configuration value with optional fallback.
-- Returns a safe copy of table values to prevent mutation.
-- @param key string Configuration key
-- @param fallback any Default value if key doesn't exist
-- @return any Configuration value or fallback
function Config.get(key, fallback)
  if not isInitialized then
    Log.warn("Config.get() called before initialization") --#DEBUG
    return FALLBACKS[key] or fallback
  end

  local value = activeConfig[key]
  if value == nil then return fallback end
  if type(value) == "table" then
    return tableShallowCopy(value)
  end
  return value
end

-- ! Get All Configurations
-- Returns a shallow copy of the entire configuration.
-- @return table Complete configuration copy
function Config.getAll()
  if not isInitialized then
    Log.warn("Config.getAll() called before initialization") --#DEBUG
    return tableShallowCopy(FALLBACKS)
  end
  return tableShallowCopy(activeConfig)
end

-- ! Set Configuration
-- Updates configuration values and notifies change listeners.
-- Validates that keys exist in current config to prevent typos.
-- @param newConfig table New configuration values to apply
function Config.setConfig(newConfig)
  if not isInitialized then
    Log.error("Cannot set config before initialization") --#DEBUG
    return
  end

  if type(newConfig) ~= "table" then
    Log.warn("Config.setConfig() requires a table argument") --#DEBUG
    return
  end

  local hasChanges = false
  for key, value in pairs(newConfig) do
    if activeConfig[key] ~= nil then
      if activeConfig[key] ~= value then
        activeConfig[key] = value
        hasChanges = true
      end
    else --#DEBUG
      Log.warn("Unknown configuration key '" .. tostring(key) .. "' ignored") --#DEBUG
    end
  end

  if hasChanges then
    notifyConfigChanged(Config.peek())
  end
end

-- ! Reset All Configurations
-- Resets configuration to defaults and notifies listeners.
function Config.resetConfig()
  if not isInitialized then
    Log.warn("Cannot reset config before initialization") --#DEBUG
    return
  end

  -- Reset to fallbacks + default configs (no user overrides)
  isInitialized = false
  Config.initialize()
end

-- ! Set on Changed Callback
-- Registers a callback function to be called when configuration changes.
-- @param callback function Function to call on config changes
function Config.onChanged(callback)
  if type(callback) == "function" then
    tableInsert(changeListeners, callback)
  else --#DEBUG
    Log.warn("Config.onChanged() requires a function argument") --#DEBUG
  end
end

-- ! Apply Overrides
-- Applies runtime configuration overrides and notifies listeners.
-- @param overrides table Configuration overrides to apply
function Config.applyOverrides(overrides)
  if not isInitialized then
    Log.error("Cannot apply overrides before initialization") --#DEBUG
    return
  end

  if type(overrides) ~= "table" then
    Log.warn("Config.applyOverrides() requires a table argument") --#DEBUG
    return
  end

  Config.setConfig(overrides)
end

--------------------------------------------------------------------------------
-- Transitions
--------------------------------------------------------------------------------

-- ! Set Transition Config
-- Stores transition configuration in Config.transitionConfigs
function Config.setTransitionConfig(name, config)
  Config.transitionConfigs[name] = config
end

-- ! Get Transition Configuration
-- Retrieves transition configuration from Config.transitionConfigs
-- Falls back to the an override system if not found in transitionConfigs
-- @param className string Name of the transition class
-- @return table Complete configuration for the class
function Config.getTransitionConfig(className)
  -- First, check if we have a direct config in transitionConfigs
  local directConfig = Config.transitionConfigs[className]
  if directConfig then
    local result = tableShallowCopy(directConfig)
    result.name = className
    return result
  end

  -- Override fallback
  local config = Config.get("transitions", {})
  local overrides = config.overrides or {}

  -- Start with base config, excluding the overrides key
  local result = tableShallowCopy(config)
  result.overrides = nil

  -- Apply class-specific overrides
  if overrides[className] then
    result = deepMerge(result, overrides[className])
  end

  -- Set computed name
  result.name = className

  return result
end
