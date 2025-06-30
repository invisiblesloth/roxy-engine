-- utilities/JSON.lua

roxy = roxy or {}
roxy.JSON = roxy.JSON or {}
local JSON <const> = roxy.JSON

local decodeFile   <const> = json.decodeFile
local encode       <const> = json.encode
local encodePretty <const> = json.encodePretty
local encodeToFile <const> = json.encodeToFile

-- ! Load JSON
-- Loads and parses a JSON file. Returns nil and error on failure.
function JSON.loadJson(path)
  Log.assert(path, "Path is required to load JSON data.")
  local jsonData, err = decodeFile(path)

  --#DEBUG START
  if not jsonData then
    Log.warn("Could not load JSON from " .. path .. ": " .. err)
    return nil, err
  end
  --#DEBUG END

  return jsonData
end

-- ! Encode JSON
-- Converts a Lua table to a JSON string. Supports optional pretty formatting.
function JSON.encode(table, pretty)
  Log.assert(table, "Table is required to encode JSON.")
  local jsonString = pretty and encodePretty(table) or encode(table)
  return jsonString
end

-- ! Save JSON
-- Saves a table as a JSON file. Returns true on success, or nil and error on failure.
function JSON.saveJson(path, table, pretty)
  Log.assert(path,  "Path is required to save JSON data.")
  Log.assert(table, "Table is required to save JSON data.")
  local success = encodeToFile(path, table, pretty)

  --#DEBUG START
  if not success then
    Log.warn("Could not save JSON to " .. path .. ": " .. "Unknown error")
    return nil, "Unknown error"
  end
  --#DEBUG END

  return true
end
