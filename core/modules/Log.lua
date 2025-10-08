-- core/modules/Log.lua

Log = Log or {}
local Log <const> = Log

--------------------------------------------------------------------------------
-- Standard Lua Function Aliases
--------------------------------------------------------------------------------

-- Core Lua Functions
local error_  <const> = error
local warn_   <const> = warn
local print_  <const> = print

-- String Functions
local formatString <const> = string.format

-- Table Functions
local tableConcat  <const> = table.concat
local tableRemove  <const> = table.remove
local tableUnpack  <const> = table.unpack

--------------------------------------------------------------------------------
-- Logging Level Constants
--------------------------------------------------------------------------------

Log.SILENT  = 0
Log.ERROR   = 1
Log.WARN    = 2
Log.INFO    = 3
Log.DEBUG   = 4

--------------------------------------------------------------------------------
-- Level Name Mapping
--------------------------------------------------------------------------------

local levelNames = {
  silent = Log.SILENT,
  error  = Log.ERROR,
  warn   = Log.WARN,
  info   = Log.INFO,
  debug  = Log.DEBUG
}

-- Hoist reverse mapping so we do not recreate a table each call
local levelToName = {
  [Log.SILENT] = "silent",
  [Log.ERROR]  = "error",
  [Log.WARN]   = "warn",
  [Log.INFO]   = "info",
  [Log.DEBUG]  = "debug",
}

--------------------------------------------------------------------------------
-- Default Configuration
--------------------------------------------------------------------------------

-- Default threshold
Log.level = Log.INFO

--------------------------------------------------------------------------------
-- Private Helper Functions
--------------------------------------------------------------------------------

-- ! Resolve Message
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
    local success, result = pcall(formatString, msgOrFn, ...)
    if success then
      return result
    end
  end
  local parts = { tostring(msgOrFn) }
  for i = 1, argCount do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  return tableConcat(parts, " ")
end

--------------------------------------------------------------------------------
-- Public API Functions
--------------------------------------------------------------------------------

-- ! Set Log Level
-- Set the logging level for controllable output (warn, info, debug).
-- Errors and asserts always fire regardless of level.
function Log.setLogLevel(level)
  local original = level
  if type(level) == "string" then
    level = levelNames[level:lower()] or Log.INFO
  end
  if type(level) ~= "number" or level < Log.SILENT or level > Log.DEBUG then
    -- Note: This warning depends on current Log.level. With default INFO it will show.
    Log.warn(function()
      return formatString("[setLogLevel] Invalid log level '%s', defaulting to 'info'", tostring(original))
    end)
    level = Log.INFO
  end
  Log.level = level
  -- Use prebuilt reverse map to avoid per-call allocation
  Log.info(function()
    local name = levelToName[level] or tostring(level)
    return formatString("Log level set to %s", name)
  end)
end

-- ! Error
-- Always emits, regardless of Log.level (uncontrollable)
-- Deprecated in spirit: Prefer 'error()' at call sites; this remains for compatibility
function Log.error(msgOrFn, ...)
  -- Stack level behavior:
  --    - If first vararg is a number, treat it as stack level parameter
  --    - Default is 1, which points to the caller of Log.error
  --    - If '0' is passed, honor Lua's special case (no stack level adjustment)
  local args = {...}
  local stackLevel = nil
  if #args > 0 and type(args[1]) == "number" then
    stackLevel = args[1]
    tableRemove(args, 1)
  end
  local message = resolveMessage(msgOrFn, tableUnpack(args))

  -- Compute error level:
  -- stackLevel 1 = caller of Log.error (default)
  -- stackLevel 2 = caller's caller
  -- stackLevel 0 = special case (no stack trace adjustment)
  -- Examples:
  --    nil --> 2 (caller of Log.error)
  --    1   --> 2 (caller of Log.error)
  --    2   --> 3 (caller's caller)
  --    0   --> 0 (special: pass-through)
  local errLevel
  if stackLevel == 0 then
    errLevel = 0 -- Respect special meaning of 0
  else
    local relative = (stackLevel or 1)
    errLevel = 1 + relative
  end

  error_(message, errLevel)
end

-- ! Warn
-- Controllable based on Log.level
function Log.warn(msgOrFn, ...)
  if Log.level < Log.WARN then return end
  warn_(resolveMessage(msgOrFn, ...))
end

-- ! Info
-- Controllable based on Log.level
function Log.info(msgOrFn, ...)
  if Log.level < Log.INFO then return end
  print_(resolveMessage(msgOrFn, ...))
end

-- ! Debug
-- Controllable based on Log.level
function Log.debug(msgOrFn, ...)
  if Log.level < Log.DEBUG then return end
  print_(resolveMessage(msgOrFn, ...))
end

-- ! Assert
-- Always fires, regardless of Log.level (uncontrollable)
-- Deprecated in spirit: Prefer native 'assert(condition, message)' at call sites
function Log.assert(condition, msgOrFn, ...)
  if not condition then
    local message = resolveMessage(msgOrFn or "Assertion failed!", ...)
    error_(message, 2)
  end
  return condition, ...
end

--[[

GUIDANCE:
Prefer native Lua 'error()' and 'assert()' at call sites going forward.
Keep 'Log.warn'/'Log.info'/'Log.debug' for controllable, non-fatal output.
Strip debug-only calls with '--#DEBUG' or '--#DEBUG START/END' at the call site
so they do not ship in release builds. (See Roxy Overview debug-strip docs.)
We intentionally DO NOT wrap 'error()' and 'assert()' with debug tags so they
remain active in release builds, catching invariant/fatal conditions.

USAGE EXAMPLES:

Three-tier behavior model:
1. UNCONTROLLABLE (always fire in all builds): native 'error', native 'assert'
2. CONTROLLABLE CRITICAL: Log.warn
3. CONTROLLABLE NON-CRITICAL: Log.info, Log.debug

-- Prefer native Lua:
error("Critical error occurred")                -- Always shown
assert(player ~= nil, "Player object is nil!")  -- Always checks

-- If you need custom stack level with 'error', pass it as 2nd parameter:
error(("File not found: %s"):format(filename), 2) -- '2' is the stack level

-- Controllable logs with strip tags in call sites:
--#DEBUG Log.debug(function() return ("[Anim] %s step %d"):format(name, step) end)
--#DEBUG Log.info("Player health: %d  Score: %d", health, score)

-- Warnings can be left in release if they indicate recoverable but important issues:
Log.warn("[RoxyAnimation] Animation %s not found", name)

-- Level control examples:
Log.setLogLevel("error") -- Only warn/info/debug are suppressed; errors/asserts still fire
Log.setLogLevel("warn")
Log.setLogLevel("info")
Log.setLogLevel("debug")
Log.setLogLevel("silent") -- Only native errors/asserts fire; controllable logs suppressed

]]--
