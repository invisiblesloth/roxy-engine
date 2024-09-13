roxy = roxy or {}
roxy.json = {}

-- Loads and parses a JSON file from the specified path.
-- @param path The file path to the JSON file.
-- @return The parsed JSON data as a table, or an error if the parsing fails.
function roxy.json.loadJson(path)
	assert(path, "ERROR: 'path' is required to load JSON data.")  -- Ensure a path is provided.

	local jsonData, err = json.decodeFile(path)  -- Attempt to decode the JSON file.
	if not jsonData then
		error("ERROR: Parsing JSON data for " .. path .. " failed with error: " .. err)  -- Handle and report errors during parsing.
		return nil  -- Return nil in case of an error (although unnecessary due to the error call).
	end

	return jsonData  -- Return the parsed JSON data.
end
