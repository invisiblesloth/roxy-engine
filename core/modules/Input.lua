-- core/modules/Input.lua

roxy = roxy or {}
roxy.Input = roxy.Input or {}
local Input <const> = roxy.Input

local pd              <const> = playdate
local CrankIndicator  <const> = pd.ui.crankIndicator

local r       <const> = roxy
local Config  <const> = r.Config

local tableInsert <const> = table.insert
local tableRemove <const> = table.remove
local tableSort   <const> = table.sort

local max <const> = math.max

local getButtonState    <const> = pd.getButtonState
local pushInputHandlers <const> = pd.inputHandlers.push
local popInputHandlers  <const> = pd.inputHandlers.pop

local getConfig <const> = Config.get

-- Configuration constants
local BUTTON_HOLD_BUFFER_DEFAULT  <const> = 3
local CRANK_DIRECTION_DEFAULT     <const> = 1

-- Pre-defined array for efficient iteration instead of pairs()
local BUTTON_NAMES  <const> = { "A", "B", "up", "down", "left", "right" }
local BUTTON_COUNT  <const> = #BUTTON_NAMES

-- Input event keys - kept in sync with handler merging system
local INPUT_KEYS <const> = {
  "AButtonDown", "AButtonHeld", "AButtonUp", "AButtonHold",
  "BButtonDown", "BButtonHeld", "BButtonUp", "BButtonHold",
  "downButtonDown", "downButtonUp", "downButtonHold",
  "leftButtonDown", "leftButtonUp", "leftButtonHold",
  "rightButtonDown", "rightButtonUp", "rightButtonHold",
  "upButtonDown", "upButtonUp", "upButtonHold",
  "cranked", "crankDocked", "crankUndocked"
}
local INPUT_KEY_COUNT <const> = #INPUT_KEYS

-- Button name to callback key mapping
local BUTTON_KEYS <const> = {
  A     = { down = "AButtonDown",     up = "AButtonUp",     hold = "AButtonHold"     },
  B     = { down = "BButtonDown",     up = "BButtonUp",     hold = "BButtonHold"     },
  up    = { down = "upButtonDown",    up = "upButtonUp",    hold = "upButtonHold"    },
  down  = { down = "downButtonDown",  up = "downButtonUp",  hold = "downButtonHold"  },
  left  = { down = "leftButtonDown",  up = "leftButtonUp",  hold = "leftButtonHold"  },
  right = { down = "rightButtonDown", up = "rightButtonUp", hold = "rightButtonHold" },
}

--------------------------------------------------------------------------------
-- Module State
--------------------------------------------------------------------------------

-- Button hold state tracking - using direct table access for performance
local held = {}
local heldFrames = {}

-- Handler management
local handlerRegistry = {}
local activeMergedHandler = nil
local persistentMergedHandler = {} -- Reused table to avoid allocation

-- Monotonic registration counter. Breaks priority ties deterministically:
-- table.sort is not stable, so equal-priority handlers would otherwise swap
-- precedence whenever the registry is rebuilt.
local handlerSeq = 0

-- Cache hold callbacks to avoid repeated table lookups in hot path
local cachedHoldCallbacks = {}

-- Configuration state
local cachedBufferAmount = BUTTON_HOLD_BUFFER_DEFAULT

-- Combined crank indicator state into single object
local crankIndicator = {
  active = false,
  forced = false
}

-- Core input state
local autoFlushEnabled = true
local pendingRegistryDirty = false

-- Public state
Input.crankDirection = CRANK_DIRECTION_DEFAULT
Input.isEnabled = true
Input._blocked = false -- Blocks input until all buttons released
Input._paused = false  -- Pauses all input callbacks until resumed

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Priority Comparator
-- Cached comparison function to avoid creating closures repeatedly.
-- Ties break on registration order so precedence is deterministic across the
-- unstable sort in mergeHandlers().
local function priorityComparator(a, b)
  if a.priority ~= b.priority then
    return a.priority > b.priority
  end
  return a.seq < b.seq
end

-- ! Reset Button Flags
-- Fast reset using array iteration instead of pairs()
local function resetButtonFlags()
  for i = 1, BUTTON_COUNT do
    local name = BUTTON_NAMES[i]
    held[name] = false
    heldFrames[name] = 0
  end
end

-- ! Cache Hold Callbacks
-- Cache hold callbacks when handler changes to avoid lookups in handleInput
local function cacheHoldCallbacks(handler)
  if not handler then
    for i = 1, BUTTON_COUNT do
      cachedHoldCallbacks[BUTTON_NAMES[i]] = nil
    end
    return
  end

  for i = 1, BUTTON_COUNT do
    local name = BUTTON_NAMES[i]
    local keys = BUTTON_KEYS[name]
    cachedHoldCallbacks[name] = handler[keys.hold]
  end
end

-- ! Should Process Input
-- Centralized check for whether callbacks should run
local function shouldProcessInput()
  return Input.isEnabled and (not Input._paused) and (not Input._blocked)
end

-- ! Merge Handlers
-- Efficient handler merging with minimal garbage creation
local function mergeHandlers()
  -- Sort handlers by priority (higher numbers = higher priority)
  tableSort(handlerRegistry, priorityComparator)

  local merged = persistentMergedHandler

  -- Clear only known keys instead of using pairs() which creates garbage
  for i = 1, INPUT_KEY_COUNT do
    merged[INPUT_KEYS[i]] = nil
  end

  -- Find the highest priority handler for each input event
  for i = 1, INPUT_KEY_COUNT do
    local key = INPUT_KEYS[i]
    for j = 1, #handlerRegistry do
      local handler = handlerRegistry[j]
      local fn = handler.tbl[key]
      if fn then
        merged[key] = fn
        break -- First match wins (highest priority)
      end
    end
  end

  return merged
end

-- ! Wrap Merged Handler
-- Enhanced wrapper that tracks button hold state for Down/Up events
local function wrapMergedHandler(userHandler)
  if not userHandler then return nil end

  -- Copy handler to avoid mutating the pooled table
  local wrappedHandler = {}
  for i = 1, INPUT_KEY_COUNT do
    local key = INPUT_KEYS[i]
    local original = userHandler[key]
    if original then
      -- Gate every callback behind shouldProcessInput()
      wrappedHandler[key] = function(...)
        if shouldProcessInput() then original(...) end
      end
    end
  end

  -- Wrap Down/Up events to track hold state (only if handlers exist)
  for i = 1, BUTTON_COUNT do
    local name = BUTTON_NAMES[i]
    local keys = BUTTON_KEYS[name]
    local origDown, origUp = userHandler[keys.down], userHandler[keys.up]

    -- Only create wrapper functions if original handlers exist or we need state tracking
    if origDown or userHandler[keys.up] or userHandler[keys.hold] then
      wrappedHandler[keys.down] = function(...)
        if not shouldProcessInput() then return end
        held[name] = true
        heldFrames[name] = 0
        if origDown then origDown(...) end
      end
    end

    if origUp or userHandler[keys.down] or userHandler[keys.hold] then
      wrappedHandler[keys.up] = function(...)
        if not shouldProcessInput() then return end
        held[name] = false
        heldFrames[name] = 0
        if origUp then origUp(...) end
      end
    end
  end

  return wrappedHandler
end

--------------------------------------------------------------------------------
-- Handler Registration API
--------------------------------------------------------------------------------

-- ! Initialize
function Input.init()
  local inputConfig = getConfig("input") or {}

  cachedBufferAmount = inputConfig.buttonHoldBufferAmount or BUTTON_HOLD_BUFFER_DEFAULT
  Input.crankDirection = inputConfig.crankDirection or CRANK_DIRECTION_DEFAULT

  -- Reset all state
  crankIndicator.active = false
  crankIndicator.forced = false
  Input.isEnabled = true
  Input._blocked = false
  Input._paused = false

  handlerRegistry = {}
  handlerSeq = 0
  activeMergedHandler = nil
  autoFlushEnabled = true
  pendingRegistryDirty = false

  resetButtonFlags()
end

-- ! Helper: Register Handler
-- Shared path for Input.addHandler and Input._restoreHandler. A nil 'seq'
-- performs an ordinary add/update; a non-nil 'seq' reconciles lifecycle state.
local function registerHandler(owner, tbl, priority, seq)
  -- Replace existing handler in-place to avoid array shifts. Mutating the
  -- record (rather than rebuilding it) preserves ordinary update ordering.
  for i = 1, #handlerRegistry do
    local existing = handlerRegistry[i]
    if existing.owner == owner then
      if seq ~= nil then
        -- The owner was explicitly re-registered while lifecycle code held a
        -- snapshot. Preserve that visible handler/priority change while
        -- returning the owner to its captured equal-priority position.
        existing.seq = seq
        handlerSeq = max(handlerSeq, seq + 1)
      else
        existing.tbl = tbl
        existing.priority = priority
      end
      if autoFlushEnabled then
        Input.flush()
      else
        pendingRegistryDirty = true
      end
      return
    end
  end

  -- Add new handler
  local assigned = seq or handlerSeq
  tableInsert(handlerRegistry, {
    owner = owner,
    tbl = tbl,
    priority = priority,
    seq = assigned
  })
  -- Keep the counter ahead of any restored sequence so a future registration
  -- can never tie an existing one.
  handlerSeq = max(handlerSeq, assigned + 1)

  if autoFlushEnabled then
    Input.flush()
  else
    pendingRegistryDirty = true
  end
end

-- ! Add Handler
-- Register or update a handler with given priority (higher = more important).
-- New owners mint a registration sequence; updating an existing owner preserves
-- it. A removed-then-re-added owner therefore sorts last among equal priorities.
function Input.addHandler(owner, tbl, priority)
  Log.assert(owner and tbl, "[Input.addHandler] Must provide owner and table.", 2) --#DEBUG
  registerHandler(owner, tbl, priority or 0, nil)
end

-- ! Restore Handler (internal)
-- Lifecycle-only: restores a missing owner from captured state. If the owner
-- was explicitly re-registered, preserves its handler and priority while
-- reinstating captured sequence precedence. Registration sequence is engine
-- bookkeeping, not a game-facing contract -- games use Input.addHandler.
function Input._restoreHandler(owner, tbl, priority, seq)
  Log.assert(owner and tbl, "[Input._restoreHandler] Must provide owner and table.", 2) --#DEBUG
  registerHandler(owner, tbl, priority or 0, seq)
end

-- ! Get Handler Registration (internal)
-- Returns priority, seq, handler table for an owner; nil values when absent.
function Input._getHandlerRegistration(owner)
  for i = 1, #handlerRegistry do
    local entry = handlerRegistry[i]
    if entry.owner == owner then
      return entry.priority, entry.seq, entry.tbl
    end
  end
end

--Remove Handler
-- Remove handler by owner identity
function Input.removeHandler(owner)
  for i = #handlerRegistry, 1, -1 do
    if handlerRegistry[i].owner == owner then
      tableRemove(handlerRegistry, i)
      if autoFlushEnabled then
        Input.flush()
      else
        pendingRegistryDirty = true
      end
      return
    end
  end
end

-- ! List Handler
-- Get list of all registered handlers (for debugging)
function Input.listHandlers()
  return handlerRegistry
end

-- ! Flush
-- Rebuild and activate the merged handler - this is where the magic happens
function Input.flush()
  -- Clean up previous handler
  if activeMergedHandler then
    popInputHandlers()
  end

  if #handlerRegistry == 0 then
    activeMergedHandler = nil
    cacheHoldCallbacks(nil) -- Clear cached callbacks
    pendingRegistryDirty = false
    resetButtonFlags()
    return
  end

  -- Build new merged handler
  local mergedUser = mergeHandlers()
  local wrapped = wrapMergedHandler(mergedUser)
  activeMergedHandler = wrapped

  -- Cache hold callbacks for fast access in handleInput
  cacheHoldCallbacks(wrapped)

  pushInputHandlers(wrapped, true)
  pendingRegistryDirty = false
  Log.debug("[Input.flush] Merged " .. #handlerRegistry .. " handlers") --#DEBUG
end

-- ! Suspend Auto Flush
-- Batch registration control - disable auto-flush for performance
function Input.suspendAutoFlush()
  autoFlushEnabled = false
end

-- ! Resume Auto Flush
function Input.resumeAutoFlush()
  autoFlushEnabled = true
  if pendingRegistryDirty then
    Input.flush()
  end
end

-- ! Clear All Handlers
-- Clear all handlers and reset state
function Input.clearAllHandlers()
  handlerRegistry = {}
  if activeMergedHandler then
    popInputHandlers()
    activeMergedHandler = nil
  end
  cacheHoldCallbacks(nil) -- Clear cached callbacks
  pendingRegistryDirty = false
  resetButtonFlags()
  Log.debug("[Input.clearAllHandlers] Cleared all handlers.") --#DEBUG
end

-- ! Make Modal Handler
-- Create a modal handler that blocks all inputs not explicitly handled
function Input.makeModalHandler(handler)
  handler = handler or {}
  for i = 1, INPUT_KEY_COUNT do
    local key = INPUT_KEYS[i]
    if handler[key] == nil then
      handler[key] = function() end -- Inert callback
    end
  end
  return handler
end

--------------------------------------------------------------------------------
-- Button State Management
--------------------------------------------------------------------------------

-- ! Flush Button Queue
-- Direct access to Playdate button state (removed wrapper function)
function Input.flushButtonQueue()
  getButtonState() -- Consume queued events
end

-- ! Block Until Clear
-- Block input processing until all buttons are released (for scene transitions)
function Input.blockUntilClear()
  Input._blocked = true
end

-- ! Get Held
-- Query if a specific button is currently held
function Input.getHeld(name)
  return held[name] == true
end

-- ! Get Held Frames
-- Get how many frames a button has been held
function Input.getHeldFrames(name)
  return heldFrames[name] or 0
end

-- ! Set Button Hold Buffer Amount
-- Configure hold detection sensitivity
function Input.setButtonHoldBufferAmount(frames)
  frames = tonumber(frames) or BUTTON_HOLD_BUFFER_DEFAULT
  if frames < 0 then frames = 0 end
  cachedBufferAmount = frames
end

--------------------------------------------------------------------------------
-- Pause / Resume Controls
--------------------------------------------------------------------------------

-- ! Pause
-- Pause all input handling immediately (no callbacks will fire)
function Input.pause()
  Input._paused = true
  -- Flush any queued events so they do not leak through after resume
  Input.flushButtonQueue()
  resetButtonFlags()
  Log.debug("[Input.pause] Input paused") --#DEBUG
end

-- ! Resume
-- Resume input handling. Optionally block until buttons are clear.
function Input.resume(blockUntilClear)
  Input._paused = false
  if blockUntilClear then
    Input.blockUntilClear()
  else
    Input.flushButtonQueue()
    resetButtonFlags()
  end
  Log.debug("[Input.resume] Input resumed (blockUntilClear=" .. tostring(blockUntilClear) .. ")") --#DEBUG
end

-- ! Is Paused
-- Query paused state
function Input.isPaused()
  return Input._paused
end

--------------------------------------------------------------------------------
-- Crank Controls
--------------------------------------------------------------------------------

-- ! Set Crank Indicator
-- Single function to configure crank indicator
function Input.setCrankIndicator(config, forced)
  if type(config) == "table" then
    crankIndicator.active = config.active or false
    crankIndicator.forced = config.forced or false
  else
    crankIndicator.active = config == true
    crankIndicator.forced = forced == true
  end
  Log.debug("[Input.setCrankIndicator] active=" .. tostring(crankIndicator.active) .. ", forced=" .. tostring(crankIndicator.forced)) --#DEBUG
end

-- ! Get Crank Indicator
-- Get current crank indicator state
function Input.getCrankIndicator()
  return {
    active = crankIndicator.active,
    forced = crankIndicator.forced
  }
end

-- ! Draw Crank Indicator
-- Draw crank indicator if conditions are met
function Input.drawCrankIndicator()
  if crankIndicator.active and (pd.isCrankDocked() or crankIndicator.forced) then
    CrankIndicator:draw()
  end
end

-- ! Get Crank Direction
-- Crank direction controls
function Input.getCrankDirection()
  return Input.crankDirection
end

-- ! Set Crank Direction
function Input.setCrankDirection(direction)
  if direction == nil then
    Input.crankDirection = -Input.crankDirection
    Log.debug("[Input.setCrankDirection] Toggled crank direction") --#DEBUG
  elseif direction == 1 or direction == -1 then
    Input.crankDirection = direction
    Log.debug("[Input.setCrankDirection] Set direction to " .. direction) --#DEBUG
  end
end

-- ! Reset Crank Direction
function Input.resetCrankDirection()
  Input.crankDirection = CRANK_DIRECTION_DEFAULT
  Log.debug("[Input.resetCrankDirection] Reset to default") --#DEBUG
end

--------------------------------------------------------------------------------
-- Crank Event Handlers
--------------------------------------------------------------------------------

-- ! Crank Docked
-- Trigger crank docked callback through merged handler
function Input.crankDocked()
  if shouldProcessInput() and activeMergedHandler and activeMergedHandler.crankDocked then
    activeMergedHandler.crankDocked()
  end
end

-- ! Crank Undocked
-- Trigger crank undocked callback through merged handler
function Input.crankUndocked()
  if shouldProcessInput() and activeMergedHandler and activeMergedHandler.crankUndocked then
    activeMergedHandler.crankUndocked()
  end
end

--------------------------------------------------------------------------------
-- Main Input Processing (Performance Critical)
--------------------------------------------------------------------------------

-- ! Handle Input
-- Main per-frame input processing with minimal overhead
function Input.handleInput()
  if not activeMergedHandler then return end
  if not shouldProcessInput() then
    -- Handle input blocking during scene transitions
    -- Avoid double getButtonState() call if not blocked
    if Input._blocked and getButtonState() == 0 then
      Log.debug("[Input.handleInput] Unblocking input") --#DEBUG
      Input._blocked = false
      getButtonState() -- Flush button state
      resetButtonFlags()
    end
    return
  end

  local buf = cachedBufferAmount

  -- Use cached callbacks and array iteration for maximum performance
  for i = 1, BUTTON_COUNT do
    local name = BUTTON_NAMES[i]
    if held[name] then
      local frames = heldFrames[name] + 1
      heldFrames[name] = frames
      if frames >= buf then
        local callback = cachedHoldCallbacks[name]
        if callback then callback() end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Enable / Disable Controls
--------------------------------------------------------------------------------

-- ! Get isEnabled
function Input.getIsEnabled()
  return Input.isEnabled
end

-- ! Set isEnabled
function Input.setIsEnabled(value)
  if value ~= true and value ~= false then
    Log.warn("[Input.setIsEnabled] Expected boolean value") --#DEBUG
    return
  end
  Input.isEnabled = value
  Log.debug("[Input.setIsEnabled] Set to " .. tostring(value)) --#DEBUG
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

Input merges prioritized handlers and centralizes hold, crank, and pause state.

-- Register Gameplay Controls
local playerControls = {
  AButtonDown = function() player:jump() end,
  AButtonHold = function() player:chargeJump() end,
  cranked = function(change) player:turnCrank(change) end,
}

Input.setButtonHoldBufferAmount(4)
Input.addHandler(player, playerControls, 0)
Input.addHandler(companion, companionControls, 0)
-- Earlier registration wins shared keys when priorities are equal.

-- Add a Modal Menu Above Gameplay
local menuControls = Input.makeModalHandler({
  BButtonDown = function() menu:close() end,
})
Input.addHandler(menu, menuControls, 100)
Input.removeHandler(menu)

-- Batch Handler Changes into One Rebuild
Input.suspendAutoFlush()
for _, widget in ipairs(widgets) do
  Input.addHandler(widget, widget:getInputTable(), 20)
end
Input.resumeAutoFlush()

-- Pause Input and Wait for Released Buttons Before Resuming
Input.pause()
Input.resume(true)

--]]
