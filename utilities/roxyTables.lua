roxy = roxy or {}
roxy.table = {}

-- Creates a deep copy of a table, handling cyclic references.
-- `seenObjects` is used to track already copied objects to avoid infinite loops.
function roxy.table.copy(originalObject, seenObjects)
	if type(originalObject) ~= "table" then 
		return originalObject  -- Return non-table values as-is
	end
	
	if seenObjects and seenObjects[originalObject] then 
		return seenObjects[originalObject]  -- Return the already copied object to handle cyclic references
	end
	
	local seenObjects = seenObjects or {}
	local copiedObject = setmetatable({}, getmetatable(originalObject))  -- Preserve the metatable of the original object
	seenObjects[originalObject] = copiedObject
	
	for key, value in pairs(originalObject) do
		-- Recursively copy keys and values
		copiedObject[roxy.table.copy(key, seenObjects)] = roxy.table.copy(value, seenObjects)
	end
	
	return copiedObject
end

-- Recursively merges `table2` into `table1`, overwriting values in `table1`.
-- If both values are tables, they are recursively merged.
function roxy.table.deepMerge(table1, table2)
	for k, v in pairs(table2) do
		if type(v) == "table" and type(table1[k]) == "table" then
			roxy.table.deepMerge(table1[k], v)  -- Recursively merge nested tables
		else
			table1[k] = v  -- Overwrite non-table values
		end
	end
	return table1
end

-- Merges `overrides` into a deep copy of `defaults`, returning a new table.
-- The original `defaults` table remains unchanged.
function roxy.table.mergeImmutable(defaults, overrides)
	local merged = table.deepcopy(defaults)  -- Create a deep copy to avoid modifying the original
	if overrides then
		roxy.table.deepMerge(merged, overrides)  -- Perform in-place deep merge
	end
	return merged
end

-- Converts a table to a string for printing, handling cyclic references and nested tables.
-- `depth` limits the recursion depth to avoid overly deep structures.
local function tableToString(_table, indent, seen, depth)
	seen = seen or {}
	depth = depth or 3
	if depth <= 0 then return "{...}" end  -- Prevent deep recursion
	if seen[_table] then return "{cyclic reference}" end  -- Detect and prevent cyclic references
	seen[_table] = true

	indent = indent or 0
	local toprint = string.rep(" ", indent) .. "{\n"
	indent = indent + 2
	for k, v in pairs(_table) do
		toprint = toprint .. string.rep(" ", indent)
		if type(k) == "number" then
			toprint = toprint .. "[" .. k .. "] = "
		else
			toprint = toprint .. k .. " = "
		end
		if type(v) == "table" then
			toprint = toprint .. tableToString(v, indent, seen, depth - 1) .. ",\n"
		else
			toprint = toprint .. tostring(v) .. ",\n"
		end
	end
	return toprint .. string.rep(" ", indent - 2) .. "}"
end

-- Prints a labeled table with formatted output.
function roxy.table.printTable(label, _table)
	print(label .. " = " .. tableToString(_table))
end

-- Checks if any keys have been added or removed between two tables.
-- Returns `true` if there is a difference in keys, `false` otherwise.
function roxy.table.keyChange(dataDefault, data)
	local keysDefault = {}
	local keysData = {}

	for key in pairs(dataDefault) do
		keysDefault[key] = true
	end

	for key in pairs(data) do
		keysData[key] = true
	end
	
	-- Check for missing keys in `data`
	for key in pairs(keysDefault) do
		if not keysData[key] then
			return true
		end
	end
	
	-- Check for additional keys in `data`
	for key in pairs(keysData) do
		if not keysDefault[key] then
			return true
		end
	end

	return false
end

-- Returns the number of key-value pairs in a table.
function roxy.table.getSize(_table)
	local count = 0
	
	for _, _ in pairs(_table) do
		count += 1
	end
	
	return count
end
