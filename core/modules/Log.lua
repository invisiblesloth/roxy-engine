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

-- ! Emit
local function emit(level, msgOrFn, stackLevel)
  -- Evaluate lazily if passed a function
  local message = (type(msgOrFn) == "function") and msgOrFn() or msgOrFn

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
function Log.error(msgOrFn, stackLevel)
  if Log.ERROR > Log.level then return end
  emit(Log.ERROR, msgOrFn, stackLevel)
end

-- ! Warn
function Log.warn (msgOrFn, stackLevel)
  if Log.WARN > Log.level then return end
  emit(Log.WARN, msgOrFn, stackLevel)
end

-- ! Info
function Log.info (msgOrFn, stackLevel)
  if Log.INFO > Log.level then return end
  emit(Log.INFO, msgOrFn, stackLevel)
end

-- ! Debug
function Log.debug(msgOrFn, stackLevel)
  if Log.DEBUG > Log.level then return end
  emit(Log.DEBUG, msgOrFn, stackLevel)
end

-- ! Assert
function Log.assert(condition, msgOrFn, stackLevel, ...)
  if not condition then
    Log.error(msgOrFn or "Assertion failed!", (stackLevel or 1) + 2)
  end
  return condition, ...
end
