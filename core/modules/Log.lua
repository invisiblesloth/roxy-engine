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

-- Set the logging level for controllable output (warn, info, debug).
-- Errors and asserts always fire regardless of level.
function Log.setLogLevel(level)
  local original = level
  if type(level) == "string" then
    level = levelNames[level:lower()] or Log.INFO
  end
  if type(level) ~= "number" or level < Log.SILENT or level > Log.DEBUG then
    Log.warn(function()
      return string.format("[setLogLevel] Invalid log level '%s', defaulting to 'info'", tostring(original))
    end)
    level = Log.INFO
  end
  Log.level = level
  Log.info(function()
    local name = ({[Log.SILENT]="silent", [Log.ERROR]="error", [Log.WARN]="warn", [Log.INFO]="info", [Log.DEBUG]="debug"})[level]
    return string.format("Log level set to %s", name or tostring(level))
  end)
end

-- Resolves messages with vararg support for formatting and concatenation.
local function resolveMessage(msgOrFn, ...)
  local argCount = select("#", ...)
  if type(msgOrFn) == "function" then
    return msgOrFn(...)
  end
  if argCount == 0 then
    return msgOrFn
  end
  if type(msgOrFn) == "string" then
    local success, result = pcall(string.format, msgOrFn, ...)
    if success then
      return result
    end
  end
  local parts = {tostring(msgOrFn)}
  for i = 1, argCount do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  return table.concat(parts, " ")
end

-- Error: Always emits, regardless of Log.level (uncontrollable).
function Log.error(msgOrFn, ...)
  local args = {...}
  local stackLevel = nil
  if #args > 0 and type(args[1]) == "number" then
    stackLevel = args[1]
    table.remove(args, 1)
  end
  local message = resolveMessage(msgOrFn, table.unpack(args))
  local errLevel = (stackLevel == 0) and 0 or ((stackLevel or 1) + 2)
  error_(message, errLevel)
end

-- Warn: Controllable based on Log.level.
function Log.warn(msgOrFn, ...)
  if Log.level < Log.WARN then return end
  warn_(resolveMessage(msgOrFn, ...))
end

-- Info: Controllable based on Log.level.
function Log.info(msgOrFn, ...)
  if Log.level < Log.INFO then return end
  print_(resolveMessage(msgOrFn, ...))
end

-- Debug: Controllable based on Log.level.
function Log.debug(msgOrFn, ...)
  if Log.level < Log.DEBUG then return end
  print_(resolveMessage(msgOrFn, ...))
end

-- Assert: Always fires, regardless of Log.level (uncontrollable).
function Log.assert(condition, msgOrFn, ...)
  if not condition then
    local message = resolveMessage(msgOrFn or "Assertion failed!", ...)
    error_(message, 2)
  end
  return condition, ...
end

--[[
USAGE EXAMPLE:

Three-tier behavior model:
1. UNCONTROLLABLE (always fire): Log.error, Log.assert
2. CONTROLLABLE CRITICAL: Log.warn
3. CONTROLLABLE NON-CRITICAL: Log.info, Log.debug

-- Using Log module (formatted, unified API)
Log.error("Critical error occurred")                -- Always shown
Log.error("File not found: %s", filename, 2)        -- Always shown, custom stack level
Log.assert(player ~= nil, "Player object is nil!")  -- Always fires
Log.warn("[RoxyAnimation] Animation %s not found", name)  -- Shown if level >= WARN
Log.info("Player health:", health, "Score:", score)       -- Shown if level >= INFO
Log.debug(function() return expensive_debug_info() end)   -- Shown if level >= DEBUG

-- Using native Lua calls (clean output, can coexist)
error("Critical error")         -- Same as Log.error
assert(player, "Player is nil") -- Same as Log.assert
--#DEBUG warn("Debug warning")  -- Stripped in production
--#DEBUG print("Debug info")    -- Stripped in production

-- Level control examples
Log.setLogLevel("error")  -- Only errors/asserts fire
Log.setLogLevel("warn")   -- Errors, asserts, warnings
Log.setLogLevel("info")   -- Errors, asserts, warnings, info
Log.setLogLevel("debug")  -- All logs fire
Log.setLogLevel("silent") -- Only errors and asserts fire
]]--
