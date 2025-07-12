-- core/modules/GameData.lua
-- Lean, robust save-slot manager for Playdate

roxy = roxy or {}
roxy.GameData = roxy.GameData or {}
local GameData <const> = roxy.GameData

local pd        <const> = playdate
local File      <const> = pd.file
local Datastore <const> = pd.datastore

-- Time helpers
local getTime       <const> = pd.getGMTTime
local epochFromTime <const> = pd.epochFromGMTTime
local timeFromEpoch <const> = pd.timeFromEpoch

local stringFormat <const> = string.format

local max <const> = math.max

-- Roxy utilities
local clamp     <const> = roxy.Math.clamp
local cloneDeep <const> = roxy.Table.cloneWithCycles

-- File I/O
local fileExists <const> = File.exists
local renameFile <const> = File.rename
local writeData  <const> = Datastore.write
local readData   <const> = Datastore.read
local deleteData <const> = Datastore.delete

-- Timer for zero-delay batching
local performAfterDelay <const> = pd.timer.performAfterDelay

local getConfig <const> = roxy.Config.get

------------------------------------------------------------------------------
-- Configurable slot count (no hard limit)
------------------------------------------------------------------------------

local SAVE_SLOTS_DEFAULT <const> = 3
local maxSlots = SAVE_SLOTS_DEFAULT -- getConfig("maxSaveSlots", SAVE_SLOTS_DEFAULT)

------------------------------------------------------------------------------
-- Internal state
------------------------------------------------------------------------------

local gameData         = {}   -- [slot] = { data=tbl, timestamp=int, dirty=bool }
local defaults         = nil  -- template table
local haveSetup        = false
local slotCountAtSetup = 1
local numberOfSlots    = 1
local currentSlot      = 1

-- Batch-save flag
local savePending = false

------------------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------------------

-- ! Utility: Apply Defaults
local function applyDefaults(tbl, def)
  setmetatable(tbl, { __index = def })
end

-- ! Utility: Copy With Defaults
local function copyWithDefaults(src)
  if not defaults then
    Log.error("GameData not initialised; call setup() first")
  end
  local copy = cloneDeep(src)
  applyDefaults(copy, defaults)
  return copy
end

-- ! Utility: Mark Dirty
local function markDirty(slotIndex)
  if gameData[slotIndex] then
    gameData[slotIndex].dirty = true
  end
end

------------------------------------------------------------------------------
-- Zero-delay save batching
------------------------------------------------------------------------------

-- ! Helper: Schedule Save
local function scheduleSave()
  if not savePending then
    savePending = true
    performAfterDelay(0, function()
      savePending = false
      GameData.saveAll(true)
    end)
  end
end

--#DEBUG START
-- ! Reset (for unit tests)
function GameData._reset()
  -- wipe all internal state
  gameData         = {}
  defaults         = nil
  haveSetup        = false
  slotCountAtSetup = 1
  numberOfSlots    = 1
  currentSlot      = 1
  savePending      = false
  Log.warn("GameData has been reset!")
end
--#DEBUG END

------------------------------------------------------------------------------
-- Slot existence checks
------------------------------------------------------------------------------

-- ! Helper: Slot Exists
local function slotExists(slotIndex)
  return slotIndex and slotIndex > 0 and slotIndex <= numberOfSlots and gameData[slotIndex] ~= nil
end

-- ! Helper: Data Exists
local function datumExists(slotIndex, itemKey)
  return slotExists(slotIndex) and gameData[slotIndex].data[itemKey] ~= nil
end

-- ! Key Allowed
local function slotAllowed(slot)
  return defaults and defaults[slot] ~= nil
end

-- ! Try Set
local function trySet(set, slot, value)
  if not slotAllowed(slot) then return false end
  if type(value) ~= type(defaults[slot]) then return false end
  set.data[slot] = cloneDeep(value)
  return true
end

------------------------------------------------------------------------------
-- Reload all slots from disk (1..maxSlots), simple scan
------------------------------------------------------------------------------

-- ! Reload All From Disk
function GameData.reloadAllFromDisk()
  local newTable = {}
  local highest = 0
  for i = 1, maxSlots do
    local root = "Game" .. i
    if fileExists(root .. ".json") then
      local data = readData(root)
      if type(data) == "table" and type(data.data) == "table" then
        applyDefaults(data.data, defaults)
        newTable[i] = data
        highest = i
      else
        -- Corrupt or unexpected format: revert to defaults
        newTable[i] = { data = copyWithDefaults({}), timestamp = getTime(), dirty = false }
        highest = i
      end
    end
  end
  gameData = newTable
  numberOfSlots = (highest > 0) and highest or slotCountAtSetup
  if currentSlot > numberOfSlots then currentSlot = 1 end
end

------------------------------------------------------------------------------
-- Setup
------------------------------------------------------------------------------

-- ! Setup
function GameData.setup(template, slots, opts)
  if haveSetup then return false end
  if type(template) ~= "table" then return false end
  if slots and (type(slots) ~= "number" or slots < 1) then return false end
  opts = opts or {}

  defaults = template
  slotCountAtSetup = slots or 1
  -- TODO: Add in config `getConfig("maxSaveSlots", SAVE_SLOTS_DEFAULT)`
  maxSlots = max(slotCountAtSetup, SAVE_SLOTS_DEFAULT)

  for i = 1, slotCountAtSetup do
    local stored = readData("Game" .. i)
    local useStored = type(stored) == "table" and type(stored.data) == "table" and not opts.overrideExisting
    local dataTbl = useStored and stored.data or cloneDeep(defaults)
    applyDefaults(dataTbl, defaults)

    local missing = false
    if useStored then
      for k in pairs(defaults) do
        if rawget(dataTbl, k) == nil then dataTbl[k] = defaults[k]; missing = true end
      end
    end

    gameData[i] = {
      data      = dataTbl,
      timestamp = useStored and stored.timestamp or getTime(),
      dirty     = not useStored or missing
    }
  end
  numberOfSlots = slotCountAtSetup
  haveSetup = true
  if opts.save then GameData.saveAll(true) end
  return true
end

------------------------------------------------------------------------------
-- Retrieval
------------------------------------------------------------------------------

-- ! Get Fast (not using clone with cycles)
function GameData.getFast(itemKey, slot)
  slot = slot or currentSlot
  return datumExists(slot, itemKey) and gameData[slot].data[itemKey] or nil
end

-- ! Get
function GameData.get(itemKey, slot)
  slot = slot or currentSlot
  if datumExists(slot, itemKey) then
    return cloneDeep(gameData[slot].data[itemKey])
  end
  return nil
end

-- ! Get Slot
function GameData.getSlot(slot)
  slot = slot or currentSlot
  return slotExists(slot) and cloneDeep(gameData[slot]) or nil
end

-- ! Get All
function GameData.getAll()
  return cloneDeep(gameData)
end

-- ! Get Defaults
function GameData.getDefaults()
  return cloneDeep(defaults)
end

-- ! Get Is Dirty
function GameData.isDirty(slot)
  slot = slot or currentSlot
  return slotExists(slot) and gameData[slot].dirty or false
end

------------------------------------------------------------------------------
-- Mutation helper
------------------------------------------------------------------------------

-- ! Helper: Mutate Slot
local function mutateSlot(slotIndex, fn, opts)
  if not slotExists(slotIndex) then return false end
  opts = opts or {}
  fn(gameData[slotIndex])
  markDirty(slotIndex)
  if opts.updateTimestamp then gameData[slotIndex].timestamp = getTime() end
  if opts.save then scheduleSave() end
  return true
end

------------------------------------------------------------------------------
-- Mutations
------------------------------------------------------------------------------

-- ! Set
function GameData.set(itemKeyOrTable, value, slot, opts)
  slot = slot or currentSlot
  return mutateSlot(slot, function(s)
    if type(itemKeyOrTable) == "string" then
      return trySet(s, itemKeyOrTable, value)
    elseif type(itemKeyOrTable) == "table" then
      local any = false
      for k, v in pairs(itemKeyOrTable) do
        if trySet(s, k, v) then any = true end
      end
      return any
    end
    return false
  end, opts)
end

-- ! Set Slot
function GameData.setSlot(tbl, slot, opts)
  if type(tbl) ~= "table" then return false end
  slot = slot or currentSlot
  return mutateSlot(slot, function(s) s.data = copyWithDefaults(tbl) end, opts)
end

-- ! Reset
function GameData.reset(itemKey, slot, opts)
  slot = slot or currentSlot
  return mutateSlot(slot, function(s) s.data[itemKey] = defaults[itemKey] end, opts)
end

-- ! Reset Slot
function GameData.resetSlot(slot, opts)
  slot = slot or currentSlot
  return mutateSlot(slot, function(s) s.data = copyWithDefaults({}) end, opts)
end

-- ! Reset All
function GameData.resetAll(opts)
  local ok = true
  for i = 1, numberOfSlots do
    ok = mutateSlot(i, function(s) s.data = copyWithDefaults({}) end, opts) and ok
  end
  return ok
end

------------------------------------------------------------------------------
-- Deletion (always collapse)
------------------------------------------------------------------------------

-- ! Delete Slot
function GameData.deleteSlot(slot, opts)
  opts = opts or {}
  if not slotExists(slot) then return false end

  if slot <= slotCountAtSetup and not opts.force then
    return GameData.resetSlot(slot, { updateTimestamp = true, save = opts.save })
  end

  -- Delete file
  local root = "Game" .. slot
  if fileExists(root .. ".json") then deleteData(root) end

  gameData[slot] = nil
  for i = slot + 1, numberOfSlots do
    local oldF = "Game" .. i .. ".json"
    local newF = "Game" .. (i - 1) .. ".json"
    if fileExists(oldF) then renameFile(oldF, newF) end
    gameData[i - 1] = gameData[i]
  end
  gameData[numberOfSlots] = nil
  numberOfSlots = numberOfSlots - 1

  if slot == currentSlot then currentSlot = 1 end
  scheduleSave()
  return true
end

-- ! Delete All
function GameData.deleteAll(opts)
  opts = opts or {}
  for i = numberOfSlots, 1, -1 do
    GameData.deleteSlot(i, { save = false, force = opts.force })
  end
  if opts.save then scheduleSave() end
  return true
end

------------------------------------------------------------------------------
-- Saving
------------------------------------------------------------------------------

-- ! Save
function GameData.save(slot)
  slot = slot or currentSlot
  if not slotExists(slot) then return false end

  local ok = writeData(gameData[slot], "Game" .. slot)
  if ok then gameData[slot].dirty = false end
  return ok
end

-- ! Save All
function GameData.saveAll(force)
  local ok = true
  for i = 1, numberOfSlots do
    if slotExists(i) and (force or gameData[i].dirty) then
      ok = GameData.save(i) and ok
    end
  end
  return ok
end

------------------------------------------------------------------------------
-- Accessors
------------------------------------------------------------------------------

-- ! Get Timestamp
function GameData.getTimestamp(slot, human)
  slot = slot or currentSlot
  if not slotExists(slot) then return end
  local timestamp = gameData[slot].timestamp
  if not human then return timestamp end
  local s, ms = epochFromTime(timestamp)
  local t = timeFromEpoch(s, ms)
  return stringFormat("%04d-%02d-%02d %02d:%02d:%02d.%03d",
    t.year, t.month, t.day, t.hour, t.minute, t.second, t.millisecond), timestamp
end

-- ! Get Number of Slots
function GameData.getNumberOfSlots()
  return numberOfSlots
end

-- ! Get Current Slot
function GameData.getCurrentSlot()
  return currentSlot
end

-- ! Set Current Slot
function GameData.setCurrentSlot(slot)
  if slotExists(slot) then
    currentSlot = slot
    return true
  end
  return false
end

------------------------------------------------------------------------------
-- Auto-save on quit/pause
------------------------------------------------------------------------------

-- ! Get Will Terminate
function playdate.gameWillTerminate()
  GameData.saveAll(true)
end

-- ! Get Will Pause
function playdate.gameWillPause()
  GameData.saveAll(true)
end
