-- core/modules/Debug.lua

local pd <const> = playdate

roxy = roxy or {}
roxy.Debug = roxy.Debug or {}
local Debug <const> = roxy.Debug

local max   <const> = math.max
local floor <const> = math.floor

local performAfterDelay <const> = pd.timer.performAfterDelay

-- C heap guard bindings are optional in non-debug builds.
local heapGuardVerifyAll_C  <const> = roxy.heapGuardVerifyAll
local heapGuardDumpActive_C <const> = roxy.heapGuardDumpActive
local heapGuardSnap_C       <const> = roxy.heapGuardSnap

local HEAP_GUARD_ENABLED <const> = (type(heapGuardVerifyAll_C) == "function")
Debug.heapGuardEnabled = HEAP_GUARD_ENABLED

local debugCheckingEnabled  = false
local debugChecksActive     = false

Debug.visualDebug = false

-- ! Capture Original Functions
-- Store expected Playdate SDK handlers for tamper detection.
--
-- 'roxy.*' values are read inside this function, never aliased at module scope:
-- Debug is imported near the start of roxy.lua, before the lifecycle forwarders
-- are defined, so a load-time alias would capture nil. By the time this runs --
-- from roxy.init() via enableDebugChecking() -- they exist.
local debugFunctions = {}
local function captureOriginalFunctions()
  -- 'pd.update' and the crank callbacks have no Roxy-owned counterpart, so the
  -- installed value is the only available baseline.
  debugFunctions.update = pd.update
  debugFunctions.crankDocked = pd.crankDocked
  debugFunctions.crankUndocked = pd.crankUndocked

  -- Roxy owns these, so the baseline is Roxy's own function, not whatever is
  -- currently installed. Reading a pd.* value here would canonize a game's
  -- pre-init override and defeat the check entirely.
  debugFunctions.gameWillPause = roxy.gameWillPause
  debugFunctions.gameWillResume = roxy.gameWillResume
  debugFunctions.gameWillTerminate = roxy.gameWillTerminate
  debugFunctions.deviceWillSleep = roxy.deviceWillSleep
  debugFunctions.deviceWillLock = roxy.deviceWillLock
end

--------------------------------------------------------------------------------
-- Visual‑Debug Toggles
--------------------------------------------------------------------------------

-- ! Enable Visual Debug
function Debug.enableVisualDebug()
  Debug.visualDebug = true
  Log.info("Visual debug overlays enabled.")
end

-- ! Disable Visual Debug
function Debug.disableVisualDebug()
  Debug.visualDebug = false
  Log.info("Visual debug overlays disabled.")
end

-- ! Toggle Visual Debug
function Debug.toggleVisualDebug()
  Debug.visualDebug = not Debug.visualDebug
  Log.info(function()
    return string.format("Visual debug overlays set to %s", tostring(Debug.visualDebug))
  end)
end

--------------------------------------------------------------------------------
-- Heap Guard Helpers
--------------------------------------------------------------------------------

-- ! Heap Guard Verify All
function Debug.heapGuardVerify()
  if HEAP_GUARD_ENABLED then heapGuardVerifyAll_C() end
end

-- ! Heap Guard Dump Active
function Debug.heapGuardDump()
  if HEAP_GUARD_ENABLED then heapGuardDumpActive_C() end
end

-- ! Heap Guard Snap
function Debug.heapGuardSnap(tag)
  if HEAP_GUARD_ENABLED then heapGuardSnap_C(tag) end
end

-- ! Heap Guard Verify For (Frames)
-- Verify for N frames without touching pd.update
function Debug.heapGuardVerifyFor(frames)
  if not HEAP_GUARD_ENABLED then return end
  local n = max(1, floor(frames or 60))
  local function tick()
    if n <= 0 then return end
    heapGuardVerifyAll_C()
    n = n - 1
    performAfterDelay(0, tick) -- Schedule next frame
  end
  tick()
end

--------------------------------------------------------------------------------
-- Debug Checking Lifecycle
--------------------------------------------------------------------------------

-- ! Enable Debug Checking
function Debug.enableDebugChecking()
  if not debugCheckingEnabled then
    captureOriginalFunctions()
    debugCheckingEnabled = true
    Log.info("Debug checking enabled.")
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
    Log.info("Debug checks started.")
  else
    Log.warn("[Debug.startDebugChecks] Debug checks are already active.")
  end
end

-- ! Stop Debug Checks
function Debug.stopDebugChecks()
  if debugChecksActive then
    debugChecksActive = false
    Log.info("Debug checks stopped.")
  else
    Log.warn("[Debug.stopDebugChecks] Debug checks were not active.")
  end
end

-- ! Disable Debug Checking
function Debug.disableDebugChecking()
  if debugCheckingEnabled then
    debugCheckingEnabled = false
    debugChecksActive = false
    Log.info("Debug checking disabled.")
  else
    Log.warn("[Debug.disableDebugChecking] Debug checking was not enabled.")
  end
end

--------------------------------------------------------------------------------
-- Runtime Check Implementation
--------------------------------------------------------------------------------

-- ! Check
local function check(funcRef, original, name)
  if funcRef ~= original then
    Log.error("[Debug.runChecks] Debug check failed: " .. name .. " has been overridden.", 2)
  end
end

-- ! Run Checks
function Debug.runChecks()
  if not debugCheckingEnabled then
    Log.error("[Debug.runChecks] Cannot run debug checks: debug checking is not enabled.", 2)
    return
  end
  if debugChecksActive then
    check(pd.update, debugFunctions.update, "playdate.update")
    -- Roxy does not assign 'crankDocked' / 'crankUndocked': scenes receive
    -- those events through 'playdate.inputHandlers', so globals would
    -- double-fire. Debug checking snapshots their values when checks begin and
    -- treats a later replacement as tampering.
    check(pd.crankDocked, debugFunctions.crankDocked, "playdate.crankDocked")
    check(pd.crankUndocked, debugFunctions.crankUndocked, "playdate.crankUndocked")
    check(pd.gameWillPause, debugFunctions.gameWillPause, "playdate.gameWillPause")
    check(pd.gameWillResume, debugFunctions.gameWillResume, "playdate.gameWillResume")
    check(pd.gameWillTerminate, debugFunctions.gameWillTerminate, "playdate.gameWillTerminate")
    check(pd.deviceWillSleep, debugFunctions.deviceWillSleep, "playdate.deviceWillSleep")
    check(pd.deviceWillLock, debugFunctions.deviceWillLock, "playdate.deviceWillLock")
  end
end

-- ! Update
function Debug.update()
  if debugChecksActive then
    Debug.runChecks()
  end
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

Debug provides runtime diagnostics for debug builds.

-- Enable Checks Through Roxy Configuration
roxy.init({
  debugging = {
    enableDebugChecks = true,
    enableVisualDebugChecks = true,
  },
})

-- Toggle Visual Diagnostics at Runtime
Debug.toggleVisualDebug()
Debug.disableVisualDebug()

-- Inspect Native Heap Guards When Available
if Debug.heapGuardEnabled then
  Debug.heapGuardSnap("before-level-load")
  loadLevel()
  Debug.heapGuardVerifyFor(120)
  Debug.heapGuardDump()
end

--]]
