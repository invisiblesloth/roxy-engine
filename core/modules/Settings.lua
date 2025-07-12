-- core/modules/Settings.lua

roxy = roxy or {}
roxy.Settings = roxy.Settings or {}
local Settings <const> = roxy.Settings

local pd        <const> = playdate
local Datastore <const> = pd.datastore

local cloneDeep <const> = roxy.Table.cloneWithCycles

local readData  <const> = Datastore.read
local writeData <const> = Datastore.write

local settings          = {}  -- Current settings
local settingsDefault   = {}  -- Default templates
local haveSetup         = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Setting Exists
local function settingExists(itemKey)
  return settingsDefault[itemKey] ~= nil
end

-- ! Is Same Type
local function isSameType(a, b)
  return type(a) == type(b)
end

-- ! Try Set
local function trySet(key, value)
  if not settingExists(key) then return false end

  if not isSameType(value, settingsDefault[key]) then
    Log.warn("Settings.set: wrong type for '" .. key ..
             "' (expected " .. type(settingsDefault[key]) ..
             ", got " .. type(value) .. ")") --#DEBUG
    return false
  end

  settings[key] = cloneDeep(value)
  return true
end

--------------------------------------------------------------------------------
-- Private Functions
--------------------------------------------------------------------------------

--#DEBUG START
-- ! Reset (for unit tests)
function Settings._reset()
  settings = {}
  settingsDefault = {}
  haveSetup = false
  Log.warn("Settings have been reset!")
end
--#DEBUG END

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Setup
-- initialSettings: table of default settings
-- keepSavedSettings: if true (default), merge saved values
-- saveToDisk: if true, persist immediately
function Settings.setup(initialSettings, keepSavedSettings, saveToDisk)
  if haveSetup then
    Log.warn("Settings.setup: already initialized") --#DEBUG
    return false
  end
  if type(initialSettings) ~= "table" or next(initialSettings) == nil then
    Log.error("Settings.setup requires a non-empty table of defaults") --#DEBUG
    return false
  end

  keepSavedSettings = (keepSavedSettings ~= false)
  settingsDefault = cloneDeep(initialSettings)
  settings = cloneDeep(settingsDefault)

  if keepSavedSettings then
    local stored = readData("Settings")
    if type(stored) == "table" then
      for key, value in pairs(stored) do
        if settingsDefault[key] ~= nil then
          settings[key] = value
        end
      end
    end
  end

  haveSetup = true
  if saveToDisk then
    return Settings.save()
  end
  return true
end

-- ! Get Setting
-- Retrieves one or more settings by name or table of names.
function Settings.get(itemKeyOrKeys)
  if type(itemKeyOrKeys) == "string" then
    if settingExists(itemKeyOrKeys) then
      return cloneDeep(settings[itemKeyOrKeys])
    end
    return nil
  elseif type(itemKeyOrKeys) == "table" then
    local result = {}
    for _, key in ipairs(itemKeyOrKeys) do
      if settingExists(key) then
        result[key] = cloneDeep(settings[key])
      end
    end
    return result
  end
  return nil
end

-- ! Get All Settings
-- Returns a copy of all current settings.
function Settings.getAllSettings()
  return cloneDeep(settings)
end

-- ! Get Default Settings
-- Returns a copy of the default settings.
function Settings.getDefaultSettings()
  return cloneDeep(settingsDefault)
end

-- ! Set setting(s)
-- itemKeyOrTable: string or table {key=value,...}
-- value: when itemKeyOrTable is string
-- saveToDisk: if true, persist after set
function Settings.set(itemKeyOrTable, value, saveToDisk)
  local changed = false

  if type(itemKeyOrTable) == "string" then
    changed = trySet(itemKeyOrTable, value)
  elseif type(itemKeyOrTable) == "table" then
    for k, v in pairs(itemKeyOrTable) do
      if trySet(k, v) then changed = true end
    end
  end

  if changed and saveToDisk then Settings.save() end
  return changed
end

-- ! Set and Save Setting(s)
function Settings.setAndSave(itemKeyOrTable, value)
  return Settings.set(itemKeyOrTable, value, true)
end

-- ! Remove setting(s)
-- Behavior: revert to default rather than nil
function Settings.remove(itemKeyOrKeys, saveToDisk)
  local changed = false
  if type(itemKeyOrKeys) == "string" then
    if settingExists(itemKeyOrKeys) then
      settings[itemKeyOrKeys] = cloneDeep(settingsDefault[itemKeyOrKeys])
      changed = true
    end
  elseif type(itemKeyOrKeys) == "table" then
    for _, key in ipairs(itemKeyOrKeys) do
      if settingExists(key) then
        settings[key] = cloneDeep(settingsDefault[key])
        changed = true
      end
    end
  end
  if changed and saveToDisk then
    Settings.save()
  end
  return changed
end

-- ! Reset all settings
function Settings.resetAll(saveToDisk)
  for key, _ in pairs(settingsDefault) do
    settings[key] = cloneDeep(settingsDefault[key])
  end
  if saveToDisk then
    return Settings.save()
  end
  return true
end

-- ! Save to disk
function Settings.save()
  if not haveSetup then
    Log.error("Settings.save: not initialized") --#DEBUG
    return false
  end
  local ok, err = writeData(settings, "Settings")
  if not ok then
    Log.error("Settings.save: failed to write - " .. tostring(err)) --#DEBUG
    return false
  end
  return true
end
