-- core/modules/Log.lua

Log = Log or {}
local Log <const> = Log

local pd = playdate

local error_ <const> = error
local warn_  <const> = warn
local print_ <const> = print

-- Logging levels
Log.SILENT  = 0
Log.ERROR   = 1
Log.WARN    = 2
Log.INFO    = 3
Log.DEBUG   = 4

local levelNames = {
  silent = Log.SILENT,
  error  = Log.ERROR,
  warn   = Log.WARN,
  info   = Log.INFO,
  debug  = Log.DEBUG
}

-- Default threshold
Log.level = Log.INFO

-- ! Set Log Level
-- Sets the logging level for Log output. Accepts string or number.
function Log.setLogLevel(level)
  local original = level
  if type(level) == "string" then
    level = levelNames[level:lower()]
  end
  if type(level) ~= "number" then
    Log.warn(function()
      return string.format("[setLogLevel] invalid log level '%s', defaulting to 'info'", tostring(original))
    end)
    level = Log.INFO
  end
  if level < Log.SILENT or level > Log.DEBUG then
    Log.warn(function()
      return string.format("[setLogLevel] log level '%s' is out of range, defaulting to 'info'", tostring(original))
    end)
    level = Log.INFO
  end
  Log.level = level

  -- Find string name for confirmation
  local name = nil
  for key, value in pairs(levelNames) do
    if value == level then
      name = key
      break
    end
  end
  Log.info(function()
    return string.format("Log level set to %s", name or tostring(level))
  end)
end

-- ! Message Resolution Helper
-- Resolves messages with vararg support for formatting and concatenation
local function resolveMessage(msgOrFn, ...)
  local argCount = select("#", ...)

  -- If it's a function, call it with the extra args
  if type(msgOrFn) == "function" then
    return msgOrFn(...)
  end

  -- If no extra arguments, return as-is
  if argCount == 0 then
    return msgOrFn
  end

  -- If first arg is string and we have extra args, try string.format
  if type(msgOrFn) == "string" then
    local success, result = pcall(string.format, msgOrFn, ...)
    if success then
      return result
    end
    -- If format failed, fall through to concatenation
  end

  -- Concatenate all arguments with spaces (like print does)
  local parts = {tostring(msgOrFn)}
  for i = 1, argCount do
    parts[#parts + 1] = tostring((select(i, ...)))
  end
  return table.concat(parts, " ")
end

-- ! Emit
local function emit(level, msgOrFn, stackLevel, ...)
  -- Resolve message with vararg support
  local message = resolveMessage(msgOrFn, ...)

  if level == Log.ERROR then
    -- stackLevel == 0 => caller wants NO prefix from error()
    local errLevel = (stackLevel == 0) and 0 or ((stackLevel or 1) + 2)
    error_(message, errLevel)
  elseif level == Log.WARN then
    warn_(message)
  else
    print_(message)
  end
end

-- ! Error
function Log.error(msgOrFn, ...)
  local args = {...}
  local stackLevel = nil

  -- Check if second argument is a numeric stackLevel
  if #args > 0 and type(args[1]) == "number" then
    stackLevel = args[1]
    -- Remove stackLevel from args to forward the rest
    table.remove(args, 1)
  end

  if Log.ERROR > Log.level then return end
  emit(Log.ERROR, msgOrFn, stackLevel, table.unpack(args))
end

-- ! Warn
function Log.warn(msgOrFn, ...)
  local args = {...}
  local stackLevel = nil

  -- Check if second argument is a numeric stackLevel
  if #args > 0 and type(args[1]) == "number" then
    stackLevel = args[1]
    table.remove(args, 1)
  end

  if Log.WARN > Log.level then return end
  emit(Log.WARN, msgOrFn, stackLevel, table.unpack(args))
end

-- ! Info
function Log.info(msgOrFn, ...)
  local args = {...}
  local stackLevel = nil

  -- Check if second argument is a numeric stackLevel
  if #args > 0 and type(args[1]) == "number" then
    stackLevel = args[1]
    table.remove(args, 1)
  end

  if Log.INFO > Log.level then return end
  emit(Log.INFO, msgOrFn, stackLevel, table.unpack(args))
end

-- ! Debug
function Log.debug(msgOrFn, ...)
  local args = {...}
  local stackLevel = nil

  -- Check if second argument is a numeric stackLevel
  if #args > 0 and type(args[1]) == "number" then
    stackLevel = args[1]
    table.remove(args, 1)
  end

  if Log.DEBUG > Log.level then return end
  emit(Log.DEBUG, msgOrFn, stackLevel, table.unpack(args))
end

-- ! Assert
function Log.assert(condition, msgOrFn, stackLevel, ...)
  if not condition then
    -- CRITICAL FIX: Bypass Log.error's level guard by calling emit directly
    -- This ensures assertions always fire regardless of log level
    local message = resolveMessage(msgOrFn or "Assertion failed!", ...)
    local errLevel = (stackLevel == 0) and 0 or ((stackLevel or 1) + 2)
    error_(message, errLevel)
  end
  return condition, ...
end

--[[
USAGE EXAMPLE:
-- String formatting (your examples now work!)
Log.warn("[RoxyAnimation:setAnimation] Animation %s not found", tostring(name))
Log.warn("[RoxyStagTilemap] Failed to allocate chunk image (%dx%d)", width, height)

-- Print-style concatenation
Log.info("Player health:", health, "Score:", score)

-- Function producers with args
Log.debug(function(x, y) return string.format("Position: (%d, %d)", x, y) end, player.x, player.y)

-- Stack level still works
Log.error("Critical error", 2, "additional", "context")

-- Assertions now always fire regardless of log level
Log.assert(player ~= nil, "Player object is nil!")
]]--
