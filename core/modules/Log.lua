-- core/modules/Log.lua

Log = Log or {}
local Log <const> = Log

local pd = playdate

local error_  = error
local warn_   = warn
local print_  = print

-- Logging levels
Log.SILENT  = 0
Log.ERROR   = 1
Log.WARN    = 2
Log.INFO    = 3
Log.DEBUG   = 4

-- Default threshold
Log.level = Log.DEBUG

-- ! Emit
local function emit(level, tag, msgOrFn, stackLevel)
  if level > Log.level then return end

  -- Evaluate lazily if passed a function
  local message = (type(msgOrFn) == "function") and msgOrFn() or msgOrFn
  local prefix = string.format("%s %s", tag, message)

  if level == Log.ERROR then
    -- stackLevel == 0 => caller wants NO prefix from error()
    local errLevel = (stackLevel == 0) and 0 or ((stackLevel or 1) + 2)
    error_(prefix, errLevel)
  elseif level == Log.WARN then
    warn_(prefix)
  else
    print_(prefix)
  end
end

function Log.error(msgOrFn, stackLevel)
  emit(Log.ERROR, "Roxy ERROR:", msgOrFn, stackLevel)
end

function Log.warn (msgOrFn, stackLevel)
  emit(Log.WARN, "Warning:", msgOrFn, stackLevel)
end

function Log.info (msgOrFn, stackLevel)
  emit(Log.INFO, "(i)", msgOrFn, stackLevel)
end

function Log.debug(msgOrFn, stackLevel)
  emit(Log.DEBUG, "[D]", msgOrFn, stackLevel)
end

function Log.assert(condition, msgOrFn, stackLevel, ...)
  if not condition then
    Log.error(msgOrFn or "Assertion failed!", (stackLevel or 1) + 2)
  end
  return condition, ...
end
