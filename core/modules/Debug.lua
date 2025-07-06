-- core/modules/Debug.lua

local pd  = playdate

roxy = roxy or {}
local Debug = roxy.Debug or {}
roxy.Debug = Debug

local debugCheckingEnabled = false
local debugChecksActive    = false

Debug.visualDebug = false

-- ! Capture Original Functions
-- Store original Playdate SDK functions for tamper detection
local debugFunctions = {}
local function captureOriginalFunctions()
  debugFunctions.update         = pd.update
  debugFunctions.crankDocked    = pd.crankDocked
  debugFunctions.crankUndocked  = pd.crankUndocked
  debugFunctions.gameWillPause  = pd.gameWillPause
  debugFunctions.gameWillResume = pd.gameWillResume
end

-- ----------------------------------------
-- Visual‑debug toggles
-- ----------------------------------------

-- ! Enable Visual Debug
function Debug.enableVisualDebug()
  Debug.visualDebug = true
  Log.info("[Debug.enableVisualDebug] Visual debug overlays enabled.")
end

-- ! Disable Visual Debug
function Debug.disableVisualDebug()
  Debug.visualDebug = false
  Log.info("[Debug.disableVisualDebug] Visual debug overlays disabled.")
end

-- ! Toggle Visual Debug
function Debug.toggleVisualDebug()
  Debug.visualDebug = not Debug.visualDebug
  Log.info(function()
    return string.format("[Debug.toggleVisualDebug] Visual debug overlays set to %s", tostring(Debug.visualDebug))
  end)
end

-- ----------------------------------------
-- Debug checking lifecycle
-- ----------------------------------------

-- ! Enable Debug Checking
function Debug.enableDebugChecking()
  if not debugCheckingEnabled then
    captureOriginalFunctions()
    debugCheckingEnabled = true
    Log.info("[Debug.enableDebugChecking] Debug checking enabled.")
  else
    Log.warn("[Debug.enableDebugChecking] Debug checking is already enabled.")
  end
end

-- ! Start Debug Checks
function Debug.startDebugChecks()
  if not debugCheckingEnabled then
    Log.error("[Debug.startDebugChecks] Cannot start debug checks: debug checking not enabled. Call Debug.enableDebugChecking() first.", 2)
    return
  end
  if not debugChecksActive then
    debugChecksActive = true
    Log.info("[Debug.startDebugChecks] Debug checks started.")
  else
    Log.warn("[Debug.startDebugChecks] Debug checks are already active.")
  end
end

-- ! Stop Debug Checks
function Debug.stopDebugChecks()
  if debugChecksActive then
    debugChecksActive = false
    Log.info("[Debug.stopDebugChecks] Debug checks stopped.")
  else
    Log.warn("[Debug.stopDebugChecks] Debug checks were not active.")
  end
end

-- ! Disable Debug Checking
function Debug.disableDebugChecking()
  if debugCheckingEnabled then
    debugCheckingEnabled = false
    debugChecksActive    = false
    Log.info("[Debug.disableDebugChecking] Debug checking disabled.")
  else
    Log.warn("[Debug.disableDebugChecking] Debug checking was not enabled.")
  end
end

-- ----------------------------------------
-- Runtime check Implementation
-- ----------------------------------------

-- ! Check
local function check(funcRef, original, name)
  if funcRef ~= original then
    Log.error(string.format("[Debug.runChecks] Debug check failed: %s has been overridden.", name), 2)
  end
end

-- ! Run Checks
function Debug.runChecks()
  if not debugCheckingEnabled then
    Log.error("[Debug.runChecks] Cannot run debug checks: debug checking is not enabled.", 2)
    return
  end
  if debugChecksActive then
    check(pd.update,        debugFunctions.update,        "playdate.update")
    check(pd.crankDocked,   debugFunctions.crankDocked,   "playdate.crankDocked")
    check(pd.crankUndocked, debugFunctions.crankUndocked, "playdate.crankUndocked")
    check(pd.gameWillPause, debugFunctions.gameWillPause, "playdate.gameWillPause")
    check(pd.gameWillResume,debugFunctions.gameWillResume,"playdate.gameWillResume")
  end
end

-- ! Update
function Debug.update()
  if debugChecksActive then
    Debug.runChecks()
  end
end
