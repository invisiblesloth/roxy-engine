-- core/modules/Input.lua

roxy = roxy or {}
roxy.Input = roxy.Input or {}
local Input <const> = roxy.Input

local pd  <const> = playdate
local r   <const> = roxy

local tableInsert <const> = table.insert
local tableRemove <const> = table.remove
local tableSort   <const> = table.sort

local getButtonState    <const> = pd.getButtonState
local pushInputHandlers <const> = pd.inputHandlers.push
local popInputHandlers  <const> = pd.inputHandlers.pop
local CrankIndicator    <const> = pd.ui.crankIndicator

-- C functions
local SetButtonHoldBufferAmount <const> = Input.setButtonHoldBufferAmount
local processAllButtons         <const> = Input.processAllButtons

local flushButtonQueue          <const> = Input.flushButtonQueue

local BUTTON_HOLD_BUFFER_DEFAULT  <const> = 3 -- Frames for button hold detection
local CRANK_DIRECTION_DEFAULT     <const> = 1

-- Handler Merging State
local handlerRegistry = {}          -- [{owner=..., tbl=..., priority=...}, ...]
local activeMergedHandler = nil     -- Currently active merged handler table
local autoFlushEnabled = true       -- Push after register/unregister?
local pendingRegistryDirty = false  -- Tracks unflushed changes when autoFlush is off

-- List of supported input event keys (keep in sync with stubHandler)
local inputKeys = {
  "AButtonDown",
  "AButtonHeld",
  "AButtonUp",
  "AButtonHold",
  "BButtonDown",
  "BButtonHeld",
  "BButtonUp",
  "BButtonHold",
  "downButtonDown",
  "downButtonUp",
  "downButtonHold",
  "leftButtonDown",
  "leftButtonUp",
  "leftButtonHold",
  "rightButtonDown",
  "rightButtonUp",
  "rightButtonHold",
  "upButtonDown",
  "upButtonUp",
  "upButtonHold",
  "cranked",
  "crankDocked",
  "crankUndocked"
}

-- Inert stub for blocking and compatibility
local stubHandler = {}
for _, k in ipairs(inputKeys) do stubHandler[k] = function() end end

-- Other Internal State
local buttonHoldBufferAmount  = BUTTON_HOLD_BUFFER_DEFAULT
local crankIndicatorActive    = false
local crankIndicatorForced    = false

Input.crankDirection = CRANK_DIRECTION_DEFAULT
Input.isEnabled               = true  -- Input starts enabled
Input._blocked                = false -- true when blocking until all buttons are released
Input.clearQueueOnSetHandler  = true  -- auto flush/block on handler set

-- ----------------------------------------
-- Helpers
-- ----------------------------------------

local buttonEventMap = {
  [0] = "AButtonHold",
  [1] = "BButtonHold",
  [2] = "upButtonHold",
  [3] = "downButtonHold",
  [4] = "leftButtonHold",
  [5] = "rightButtonHold"
}

-- ! Dispatch
-- Dispatch helper for button-hold events
local function _dispatch(handler, eventIndex)
  local callbackName = buttonEventMap[eventIndex]
  if handler and handler[callbackName] then
    handler[callbackName]()
  end
end

-- ! Merge Handlers
-- Merges all handlers by priority into a new table
local function _mergeHandlers()
  tableSort(handlerRegistry, function(a, b) return a.priority > b.priority end)
  local merged = {}
  for _, key in ipairs(inputKeys) do
    for _, handler in ipairs(handlerRegistry) do
      local fn = handler.tbl[key]
      if fn then
        merged[key] = fn
        break
      end
    end
  end
  return merged
end

-- ----------------------------------------
-- Handler Registration API
-- ----------------------------------------

-- ! Add Handler
-- Add (or replace) a handler for an owner at a given priority.
function Input.addHandler(owner, tbl, priority)
  assert(owner and tbl, "[*][Input.addHandler] Must provide owner and table.", 2) --#DEBUG
  priority = priority or 0

  -- Replace if already present
  for i, handler in ipairs(handlerRegistry) do
    if handler.owner == owner then
      handlerRegistry[i] = {
        owner = owner,
        tbl = tbl,
        priority = priority
      }
      if autoFlushEnabled then
        Input.flush()
      else
        pendingRegistryDirty = true
      end
      return
    end
  end

  tableInsert(handlerRegistry, {
    owner = owner,
    tbl = tbl,
    priority = priority
  })

  if autoFlushEnabled then
    Input.flush()
  else
    pendingRegistryDirty = true
  end
end

-- ! Remove Handler
-- Remove a handler by owner identity.
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

-- ! List Handlers
-- List all registered handlers (for debugging/UI)
function Input.listHandlers()
  return handlerRegistry
end

-- ! Flush
-- Explicitly rebuilds and pushes merged handler to SDK stack.
function Input.flush()
  if activeMergedHandler then popInputHandlers() end
  if #handlerRegistry == 0 then
    activeMergedHandler = nil
    pendingRegistryDirty = false
    return
  end

  local merged = _mergeHandlers()
  activeMergedHandler = merged
  pushInputHandlers(merged, true)
  pendingRegistryDirty = false
  print("[D][Input.flush] Flushed/merged handlers: count=" .. tostring(#handlerRegistry)) --#DEBUG
end

-- ! Suspend Auto Flush
-- Disable auto-flush for batch registration.
function Input.suspendAutoFlush()
  autoFlushEnabled = false
end

-- ! Resume Auto Flush
-- Re-enable auto-flush and flush if dirty.
function Input.resumeAutoFlush()
  autoFlushEnabled = true
  if pendingRegistryDirty then
    Input.flush()
  end
end

-- ! Clear All Handlers
-- Remove all registered handlers and pop from SDK.
function Input.clearAllHandlers()
  handlerRegistry = {}
  if activeMergedHandler then
    popInputHandlers()
    activeMergedHandler = nil
  end
  pendingRegistryDirty = false
  print("[D][Input.clearAllHandlers] Cleared all handlers.") --#DEBUG
end

-- ! Make Modal Handler
-- Builds a modal handler table with inert callbacks for all supported
function Input.makeModalHandler(handler)
  handler = handler or {}
  for _, key in ipairs(inputKeys) do
    if handler[key] == nil then
      handler[key] = function() end
    end
  end
  return handler
end

-- ----------------------------------------
-- Button and Input Processing
-- ----------------------------------------

-- ! Flush Button Queue
-- Call once to consume any queued Down/Up events and
-- reset the justPressed/justReleased state.
function Input.flushButtonQueue()
  getButtonState() -- Consume current/pressed/released
end

-- ! Block Until Clear
-- Disable Input.handleInput() until *no* buttons are held.
-- Prevents handling a release that began in the previous scene.
function Input.blockUntilClear()
  Input._blocked = true
end

-- ----------------------------------------
-- Crank Indicator Controls
-- ----------------------------------------

-- ! Get Crank Indicator Status
-- Returns the crank indicator’s active and forced states.
function Input.getCrankIndicatorStatus()
  return crankIndicatorActive, crankIndicatorForced
end

-- ! Input.setCrankIndicatorStatus
-- Sets the crank indicator’s visibility and behavior.
function Input.setCrankIndicatorStatus(active, evenWhenUndocked)
  crankIndicatorActive = active
  crankIndicatorForced = evenWhenUndocked == true
  print("[D][Input.setCrankIndicatorStatus] Set crank indicator active = " .. tostring(active) .. ", forced = " .. tostring(evenWhenUndocked)) --#DEBUG
end

-- ! Get Crank Indicator
-- Returns whether the crank indicator is active.
function Input.getCrankIndicator()
  return crankIndicatorActive
end

-- ! Get Crank Indicator Forced
-- Returns whether the crank indicator is forced to show.
function Input.getCrankIndicatorForced()
  return crankIndicatorForced
end

-- ! Draw Crank Indicator
-- Draws the crank indicator if active and conditions are met.
function Input.drawCrankIndicator()
  if crankIndicatorActive and (pd.isCrankDocked() or crankIndicatorForced) then
    CrankIndicator:draw()
  end
end

-- ----------------------------------------
-- Crank Direction Controls
-- ----------------------------------------

-- ! Get Crank Direction
-- Returns the current crank direction multiplier.
function Input.getCrankDirection()
  return Input.crankDirection
end

-- ! Input.setCrankDirection
-- Sets or toggles the crank direction multiplier.
function Input.setCrankDirection(direction)
  if direction == nil then
    Input.crankDirection = -Input.crankDirection
    print("[D][Input.setCrankDirection] toggled crank direction.") --#DEBUG
  elseif direction == 1 or direction == -1 then
    Input.crankDirection = direction
    print("[D][Input.setCrankDirection] set crank direction to " .. direction) --#DEBUG
  end
end

-- ! Reset Crank Direction
-- Resets the crank direction to its default value.
function Input.resetCrankDirection()
  Input.crankDirection = CRANK_DIRECTION_DEFAULT
  print("[D][Input.resetCrankDirection] Reset crank direction to default.") --#DEBUG
end

-- ----------------------------------------
-- Crank Events (uses merged handler)
-- ----------------------------------------

-- ! Crank Docked
-- Triggers the crankDocked callback if defined and enabled.
function Input.crankDocked()
  if Input.isEnabled and activeMergedHandler and activeMergedHandler.crankDocked then
    activeMergedHandler.crankDocked()
  end
end

-- ! Crank Undocked
-- Triggers the crankUndocked callback if defined and enabled.
function Input.crankUndocked()
  if Input.isEnabled and activeMergedHandler and activeMergedHandler.crankUndocked then
    activeMergedHandler.crankUndocked()
  end
end

-- ----------------------------------------
-- Main Per-frame Input Processing
-- ----------------------------------------

-- ! Handle Input
-- Processes button hold events and triggers corresponding callbacks.
function Input.handleInput()
  if not Input.isEnabled or not activeMergedHandler then return end

  if Input._blocked then
    local current = getButtonState()
    if current == 0 then
      print("[D][Input.handleInput] Buttons released, unblocking input handler.") --#DEBUG
      Input._blocked = false
      getButtonState() -- Safety
    end
    return
  end

  local handler = activeMergedHandler
  local mask = processAllButtons()
  if not mask then return end

  -- Test each bit (0–5)
  if mask & 0x01 ~= 0 then _dispatch(handler, 0) end
  if mask & 0x02 ~= 0 then _dispatch(handler, 1) end
  if mask & 0x04 ~= 0 then _dispatch(handler, 2) end
  if mask & 0x08 ~= 0 then _dispatch(handler, 3) end
  if mask & 0x10 ~= 0 then _dispatch(handler, 4) end
  if mask & 0x20 ~= 0 then _dispatch(handler, 5) end
end

-- ----------------------------------------
-- Enable/Disable Processing
-- ----------------------------------------

-- ! Get Is Enabled
-- Returns whether input processing is enabled.
function Input.getIsEnabled()
  return Input.isEnabled
end

-- ! Set Is Enabled
-- Sets whether input processing is enabled.
function Input.setIsEnabled(value)
  if value ~= true and value ~= false then
    warn("[W][Input.setIsEnabled] setIsEnabled: Expected boolean.") --#DEBUG
    return
  end
  Input.isEnabled = value
  print("[D][Input.setIsEnabled] set isEnabled = " .. tostring(value)) --#DEBUG
end

--[[

Example usage:

Input.addHandler(player, playerControls, 0)
Input.addHandler(menu, menuControls, 100)
Input.removeHandler(menu)

Input.suspendAutoFlush()
for _, w in ipairs(widgets) do
  Input.addHandler(w, w:getInputTable(), 20)
end
Input.resumeAutoFlush()

]]--
