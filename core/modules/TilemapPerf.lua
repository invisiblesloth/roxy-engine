-- core/modules/TilemapPerf.lua

roxy = roxy or {}
roxy.TilemapPerf = roxy.TilemapPerf or {}
local TilemapPerf <const> = roxy.TilemapPerf

local pd <const> = playdate

local formatString  <const> = string.format
local tablePack     <const> = table.pack
local tableInsert   <const> = table.insert
local tableSort     <const> = table.sort
local tableUnpack   <const> = table.unpack

local clock             <const> = os and os.clock or nil
local resetElapsedTime  <const> = pd and pd.resetElapsedTime or nil
local getElapsedTime    <const> = pd and pd.getElapsedTime or nil

local samples   = {}
local counters  = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Get Memory KB
local function getMemoryKB()
  if type(collectgarbage) ~= "function" then return nil end

  local ok, value = pcall(collectgarbage, "count")
  if ok and type(value) == "number" then
    return value
  end
  return nil
end

-- ! Measure Seconds
local function measureSeconds(fn)
  if type(resetElapsedTime) == "function" and type(getElapsedTime) == "function" then
    resetElapsedTime()
    local results = tablePack(fn())
    return getElapsedTime(), results
  end

  if type(clock) == "function" then
    local started = clock()
    local results = tablePack(fn())
    return clock() - started, results
  end

  local results = tablePack(fn())
  return 0, results
end

-- ! Format MS
local function formatMS(seconds)
  return formatString("%.3fms", (seconds or 0) * 1000)
end

-- ! Format Memory
local function formatMemory(delta)
  if type(delta) ~= "number" then return "N/A" end
  return formatString("%.1fKB", delta)
end

-- ! Sorted Labels
local function sortedLabels()
  local labels = {}
  for label, _ in pairs(samples) do
    tableInsert(labels, label)
  end
  tableSort(labels)
  return labels
end

-- ! Sorted Counter Labels
local function sortedCounterLabels()
  local labels = {}
  for label, _ in pairs(counters) do
    tableInsert(labels, label)
  end
  tableSort(labels)
  return labels
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Reset
function TilemapPerf.reset()
  samples = {}
  counters = {}
end

-- ! Record
function TilemapPerf.record(label, seconds, memoryDeltaKB)
  if type(label) ~= "string" or label == "" then return nil end

  seconds = tonumber(seconds) or 0
  local sample = samples[label]
  if not sample then
    sample = {
      count = 0,
      total = 0,
      min = seconds,
      max = seconds,
      last = seconds,
      memoryDeltaKB = memoryDeltaKB,
    }
    samples[label] = sample
  end

  sample.count += 1
  sample.total += seconds
  sample.last = seconds
  if seconds < sample.min then sample.min = seconds end
  if seconds > sample.max then sample.max = seconds end
  sample.memoryDeltaKB = memoryDeltaKB

  return sample
end

-- ! Count
function TilemapPerf.count(label, amount)
  if type(label) ~= "string" or label == "" then return nil end
  amount = tonumber(amount) or 1
  counters[label] = (counters[label] or 0) + amount
  return counters[label]
end

-- ! Measure
function TilemapPerf.measure(label, fn)
  if type(fn) ~= "function" then return nil end

  local memoryBefore = getMemoryKB()
  local elapsed, results = measureSeconds(fn)
  local memoryAfter = getMemoryKB()
  local memoryDelta = nil
  if memoryBefore and memoryAfter then
    memoryDelta = memoryAfter - memoryBefore
  end

  TilemapPerf.record(label, elapsed, memoryDelta)
  return tableUnpack(results, 1, results.n)
end

-- ! Snapshot
function TilemapPerf.snapshot()
  local snapshot = {}
  for label, sample in pairs(samples) do
    snapshot[label] = {
      count = sample.count,
      min = sample.min,
      max = sample.max,
      average = sample.count > 0 and (sample.total / sample.count) or 0,
      last = sample.last,
      memoryDeltaKB = sample.memoryDeltaKB,
    }
  end
  return snapshot
end

-- ! Counter Snapshot
function TilemapPerf.counterSnapshot()
  local snapshot = {}
  for label, value in pairs(counters) do
    snapshot[label] = value
  end
  return snapshot
end

-- ! Report Lines
function TilemapPerf.reportLines()
  local lines = {
    "TilemapPerf",
    "label | count | min | max | avg | last | memory",
  }

  local snapshot = TilemapPerf.snapshot()
  for _, label in ipairs(sortedLabels()) do
    local sample = snapshot[label]
    tableInsert(lines, formatString(
      "%s | %d | %s | %s | %s | %s | %s",
      label,
      sample.count,
      formatMS(sample.min),
      formatMS(sample.max),
      formatMS(sample.average),
      formatMS(sample.last),
      formatMemory(sample.memoryDeltaKB)
    ))
  end

  local counterLabels = sortedCounterLabels()
  if #counterLabels > 0 then
    tableInsert(lines, "TilemapPerfCounters")
    tableInsert(lines, "label | count")
    for _, label in ipairs(counterLabels) do
      tableInsert(lines, formatString("%s | %d", label, counters[label]))
    end
  end

  return lines
end

-- ! Print Report
function TilemapPerf.printReport()
  for _, line in ipairs(TilemapPerf.reportLines()) do
    print(line)
  end
end
