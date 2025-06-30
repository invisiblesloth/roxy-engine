-- utilities/Table.lua

roxy = roxy or {}
roxy.Table = roxy.Table or {}
local Table <const> = roxy.Table

local getTableSize <const> = table.getsize

-- ! Clone With Cycles
-- Deep copies a table while handling cyclic references. Returns the input if not a table.
function Table.cloneWithCycles(originalObject, seenObjects)
  if type(originalObject) ~= "table" then
    return originalObject
  end

  if seenObjects and seenObjects[originalObject] then
    return seenObjects[originalObject]
  end

  local localSeen = seenObjects or {}
  local copiedObject = setmetatable({}, getmetatable(originalObject))
  localSeen[originalObject] = copiedObject

  for key, value in pairs(originalObject) do
    local copyKey = Table.cloneWithCycles(key, localSeen)
    local copyValue = Table.cloneWithCycles(value, localSeen)
    copiedObject[copyKey] = copyValue
  end

  return copiedObject
end

-- ! Deep Merge
-- Recursively merges values from tbl2 into tbl1.
function Table.deepMerge(tbl1, tbl2)
  Log.assert(tbl1, "[Table.deepMerge] tbl1 is required for deepMerge.") --#DEBUG
  Log.assert(tbl2, "[Table.deepMerge] tbl2 is required for deepMerge.") --#DEBUG

  for key, value in pairs(tbl2) do
    if type(value) == "table" and type(tbl1[key]) == "table" then
      Table.deepMerge(tbl1[key], value)
    else
      tbl1[key] = value
    end
  end

  return tbl1
end

-- ! Merge Immutable
-- Returns a deep copy of defaults merged with overrides. Original tables remain unchanged.
function Table.mergeImmutable(defaults, overrides)
  Log.assert(defaults, "[Table.mergeImmutable] defaults is required for mergeImmutable.") --#DEBUG

  local merged = Table.cloneWithCycles(defaults)
  if overrides then
    Table.deepMerge(merged, overrides)
  else
    Log.warn("[Table.mergeImmutable] No overrides provided; returning a copy of defaults unchanged") --#DEBUG
  end

  return merged
end

--
-- ! Table.keyChange
-- Returns true if keys differ between two tables (missing or extra keys).
--
function Table.keyChange(dataDefault, data)
  Log.assert(dataDefault, "[Table.keyChange] dataDefault is required for keyChange.") --#DEBUG
  Log.assert(data, "[Table.keyChange] data is required for keyChange.") --#DEBUG

  local keysDefault = {}
  local keysData = {}

  for key in pairs(dataDefault) do
    keysDefault[key] = true
  end
  for key in pairs(data) do
    keysData[key] = true
  end

  for key in pairs(keysDefault) do
    if not keysData[key] then
      Log.warn("[Table.keyChange] Key '" .. tostring(key) .. "' missing in data") --#DEBUG
      return true
    end
  end

  for key in pairs(keysData) do
    if not keysDefault[key] then
      Log.warn("[Table.keyChange] Extra key '" .. tostring(key) .. "' found in data") --#DEBUG
      return true
    end
  end

  return false
end

-- ! Get Total Size
-- Returns total count of entries in a table (array + hash parts).
function Table.getTotalSize(tbl)
  Log.assert(tbl, "[Table.getTotalSize] tbl is required for getTotalSize.") --#DEBUG
  local arrayCount, hashCount = getTableSize(tbl)
  return arrayCount + hashCount
end
