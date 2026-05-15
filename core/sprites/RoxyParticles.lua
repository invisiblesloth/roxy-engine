-- core/sprites/RoxyParticles.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite
local r         <const> = roxy
local Debug     <const> = r.Debug

local max   <const> = math.max
local floor <const> = math.floor
local clamp <const> = r.Math.clamp

local tableUnpack         <const> = table.unpack
local mergeTableImmutable <const> = r.Table.mergeImmutable

local char <const> = string.char

local setColor    <const> = Graphics.setColor
local pushContext <const> = Graphics.pushContext  --#DEBUG
local popContext  <const> = Graphics.popContext   --#DEBUG
local newImage    <const> = Graphics.image.new    --#DEBUG
local fillRect    <const> = Graphics.fillRect

-- C-side binding names updated for registered class/object API:
local new_C           <const> = RoxyParticlesC.new
local computeAABB_C   <const> = RoxyParticlesC.computeAABB
local setPattern_C    <const> = RoxyParticlesC.setPattern
local setImageTable_C <const> = RoxyParticlesC.setImageTable
local setFrameRate_C  <const> = RoxyParticlesC.setFrameRate
local spawn_C         <const> = RoxyParticlesC.spawn
local spawnMultiple_C <const> = RoxyParticlesC.spawnMultiple
local update_C        <const> = RoxyParticlesC.update
local draw_C          <const> = RoxyParticlesC.draw
local resizePool_C    <const> = RoxyParticlesC.resizePool
local clear_C         <const> = RoxyParticlesC.clear
local destroy_C       <const> = RoxyParticlesC.destroy

local EMPTY_TABLE <const> = {}

local COLOR_BLACK <const> = Graphics.kColorBlack
local COLOR_WHITE <const> = Graphics.kColorWhite

local MAX_PARTICLE_COUNT    <const> = 1000
local BATCH_THRESHOLD       <const> = 3
local MAX_FRAME_RATE        <const> = 50
local DELTA_TIME_THRESHOLD  <const> = 0.05 -- 20 FPS

local FRAME_MODE_STATIC     <const> = 0
local FRAME_MODE_SEQUENTIAL <const> = 1
local FRAME_MODE_REVERSE    <const> = 2
local FRAME_MODE_RANDOM     <const> = 3
local MODE_MAP <const> = {
  static     = FRAME_MODE_STATIC,
  sequential = FRAME_MODE_SEQUENTIAL,
  reverse    = FRAME_MODE_REVERSE,
  random     = FRAME_MODE_RANDOM
}

local SHAPE_MAP <const> = {
  circle              = 0,
  ["outline-circle"]  = 1,
  square              = 2,
  ["outline-square"]  = 3,
}

local RATE_DEFAULT <const> = 10
local DEFAULT_OPTS <const> = {
  maxCount   = 20,
  accel      = { x = 0, y = 0 },
  speed      = { 10, 20 },
  lifetime   = { 0.5, 1.0 },
  size       = { 2, 8 },
  angleRange = { -180, 180 },
  color      = COLOR_BLACK,
  shape      = "circle",
  frameRate  = 12,
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--#DEBUG START
-- ! Crosshair Image
-- Singleton crosshair cache
local _crosshairImage = false
local function getCrosshairImage()
  if not _crosshairImage then
    local img = newImage(9, 9)
    pushContext(img)
      setColor(COLOR_BLACK)
      fillRect(0, 3, 9, 3) -- Thick horizontal
      fillRect(3, 0, 3, 9) -- Thick vertical
      setColor(COLOR_WHITE)
      fillRect(0, 4, 9, 1) -- Thin white horizontal (on top)
      fillRect(4, 0, 1, 9) -- Thin white vertical (on top)
      setColor(COLOR_BLACK)
    popContext()
    _crosshairImage = img
  end
  return _crosshairImage
end
--#DEBUG END

-- ! Compute AABB (Bounding Box)
local function computeAABB(opts, frameW, frameH)
  return computeAABB_C(
    opts.lifetime[1] or 1, opts.lifetime[2] or 1,
    opts.speed[1] or 20, opts.speed[2] or 20,
    opts.size[1] or 2, opts.size[2] or 8,
    opts.accel.x or 0, opts.accel.y or 0,
    opts.angleRange[1] or -180, opts.angleRange[2] or 180,
    frameW or 0, frameH or 0
  )
end

--------------------------------------------------------------------------------
-- ! Class Definition and Initialize
--------------------------------------------------------------------------------

class("RoxyParticles").extends(RoxySprite)

-- ! Initialize
function RoxyParticles:init(x, y, opts)
  RoxySprite.super.init(self)
  self._roxyScenePausePlayback = false
  self._roxyScenePauseUpdates = true
  self._roxyScenePauseCollisions = false

  local opts = mergeTableImmutable(DEFAULT_OPTS, (opts or EMPTY_TABLE))

  -- Clamp and validate ranges for safety
  opts.maxCount   = clamp(floor(opts.maxCount), 1, MAX_PARTICLE_COUNT)
  opts.frameRate  = clamp(opts.frameRate, 1, MAX_FRAME_RATE)
  opts.lifetime   = {
    max(0.01, opts.lifetime[1]),
    max(0.01, opts.lifetime[2]),
  }

  -- Handle color, pattern, shape defaults
  opts.color = opts.color
  opts.pattern = opts.pattern -- may be nil
  opts.shape = opts.shape or ((opts.imageTable and "image") or DEFAULT_OPTS.shape)

  self.opts = opts

  -- Cache frequently accessed values for hot loops
  self.accelX = opts.accel.x
  self.accelY = opts.accel.y
  self.rate = opts.rate or 0
  self.shape = opts.shape
  self.shapeID = SHAPE_MAP[self.shape] or 0
  self.color = opts.color

  -- Image table handling
  if opts.imageTable then
    self.frameCount = opts.imageTable:getLength()
    local img = opts.imageTable:getImage(1)
    self.frameWidth, self.frameHeight = img:getSize()
  else
    self.frameCount = 1
    self.frameWidth = 0
    self.frameHeight = 0
  end

  self.frameMode = opts.frameMode and MODE_MAP[opts.frameMode] or FRAME_MODE_SEQUENTIAL
  self.staticFrame = opts.imageTable and clamp(opts.staticFrame or 1, 1, self.frameCount) or 1
  self.opts.loop = (self.opts.loop == false) and 0 or 1

  -- Allocate a C-side pool object
  self.cpool = new_C(
    opts.maxCount,
    opts.imageTable or nil,
    self.frameMode,
    self.staticFrame,
    self.opts.loop,
    self.opts.frameRate
  )
  --#DEBUG START
  if not self.cpool then
    Log.error("[RoxyParticles:init] Failed to allocate particle pool")
  end
  --#DEBUG END

  -- If the user supplied an initial pattern table, push it into C
  if opts.pattern then
    self:setPattern(opts.pattern)
  end

  -- Calculate AABB via C
  local left, right, top, bottom, boxW, boxH = computeAABB(opts, self.frameWidth or 0, self.frameHeight or 0)
  self.emitterOffsetX = -left
  self.emitterOffsetY = -top

  -- Sprite Positioning
  self:setZIndex(opts.zIndex or 1)
  self:setSize(boxW, boxH)
  self:setCenter(-left / boxW, -top / boxH)
  self:moveTo(x, y)

  -- Accumulator
  self.accumulator = 0

  -- On finish
  self.onFinished = opts.onFinished
  self.autoRemove = opts.autoRemove or false

  --#DEBUG START
  if Debug and Debug.visualDebug then
    self.debugCrosshairImage = getCrosshairImage()
  end
  --#DEBUG END
end

--------------------------------------------------------------------------------
-- Internal Methods
--------------------------------------------------------------------------------

-- ! Recalculate AABB
-- Recalculate and apply AABB, reposition sprite
function RoxyParticles:_recalcAABB()
  local left, right, top, bottom, boxW, boxH = computeAABB(self.opts, self.frameWidth or 0, self.frameHeight or 0)
  self:setSize(boxW, boxH)
  self:setCenter(-left/boxW, -top/boxH)
  self.emitterOffsetX = -left
  self.emitterOffsetY = -top
end

-- ! Spawn
-- Spawn a single particle
function RoxyParticles:spawn()
  return spawn_C(
    self.cpool,
    self.opts.lifetime[1], self.opts.lifetime[2],
    self.opts.speed[1], self.opts.speed[2],
    self.opts.size[1], self.opts.size[2],
    self.opts.angleRange[1], self.opts.angleRange[2],
    self.emitterOffsetX, self.emitterOffsetY
  )
end

-- ! Spawn Multiple Particles (Batch)
-- Returns the actual number of particles spawned
function RoxyParticles:spawnMultiple(count)
  if count <= 0 then return 0 end

  return spawnMultiple_C(
    self.cpool,
    count,
    self.opts.lifetime[1], self.opts.lifetime[2],
    self.opts.speed[1], self.opts.speed[2],
    self.opts.size[1], self.opts.size[2],
    self.opts.angleRange[1], self.opts.angleRange[2],
    self.emitterOffsetX, self.emitterOffsetY
  )
end

-- ! Update
-- Hybrid single/batch spawning
function RoxyParticles:update()
  local dt = r.deltaTime

  if self.rate > 0 then
    self.accumulator = self.accumulator + dt * self.rate

    local spawnCount = floor(self.accumulator)
    if spawnCount > 0 then
      local actualSpawned = 0

      -- Use batch spawning for multiple particles
      if spawnCount >= BATCH_THRESHOLD then
        actualSpawned = self:spawnMultiple(spawnCount)
      else
        -- Handle small counts individually
        for i = 1, spawnCount do
          if self:spawn() then
            actualSpawned = actualSpawned + 1
          else
            break -- Pool full
          end
        end
      end

      -- Deduct the spawned particles from accumulator
      self.accumulator = self.accumulator - actualSpawned

      -- If pool is full and nothing spawned, reset accumulator
      -- This prevents it from growing indefinitely.
      if actualSpawned == 0 then
        self.accumulator = 0
      end
    end
  end

  -- Update all particles and get active status
  local active
  if dt <= DELTA_TIME_THRESHOLD then -- Fast path
    active = update_C(self.cpool, dt, self.accelX, self.accelY) or false
  else -- Slow path
    -- Emergency split for frame drops
    local halfDt = dt * 0.5
    active = update_C(self.cpool, halfDt, self.accelX, self.accelY)
    active = update_C(self.cpool, halfDt, self.accelX, self.accelY) or active
  end

  self._hasActiveParticles = active
  if active then
    self:markDirty()
  end

  local wasActive = self._hadActiveParticles or false
  local isActive = self._hasActiveParticles

  -- Call onFinished ONLY when transitioning from active to inactive
  if wasActive and not isActive then
    if self.onFinished then
      self:onFinished(self)
    end
    if self.autoRemove then
      self:remove()
      self:destroy()
    end
  end

  self._hadActiveParticles = isActive
end

-- ! Draw
function RoxyParticles:draw()
  draw_C(self.cpool, self.color, self.shapeID)

  --#DEBUG START
  if Debug.visualDebug and self.debugCrosshairImage then
    self.debugCrosshairImage:draw(self.emitterOffsetX - 4, self.emitterOffsetY - 4)
  end
  --#DEBUG END
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Reset
-- Completely tear down and re-create the C-side pool so you can emit again
function RoxyParticles:reset()
  self:clear()
  self.accumulator = 0
  self._hasActiveParticles = false
  self:markDirty()
end

-- ! Clear
function RoxyParticles:clear()
  clear_C(self.cpool)
  self.accumulator = 0
  self._hasActiveParticles = false
  self:markDirty()
end

-- ! Destroy
function RoxyParticles:destroy()
  if self.cpool then
    clear_C(self.cpool)   -- Wipe any live particles
    destroy_C(self.cpool) -- Free the pool entirely
    self.cpool = nil
  end
end

-- ! Burst Emit
-- Instantly spawn count particles regardless of rate
function RoxyParticles:emit(count)
  count = floor(count or 1)
  if count <= 0 then return end

  local actualSpawned = self:spawnMultiple(count) or 0

  -- Cache the result so hasActiveParticles() works immediately
  self._hasActiveParticles = actualSpawned > 0

  if actualSpawned > 0 then
    self:markDirty()
  end
end

-- ! Set Particle Rate
function RoxyParticles:setRate(rate)
  -- Only accept non-negative numeric rates
  local valid = (type(rate) == "number" and rate >= 0) and rate or RATE_DEFAULT
  self.rate = valid
  self.opts.rate = valid
  self:markDirty()
end

-- ! Set Lifetime Range
function RoxyParticles:setLifetimeRange(minLife, maxLife)
  self.opts.lifetime = { minLife, maxLife }
  self:_recalcAABB()
  self:markDirty()
end

-- ! Set Speed Range
function RoxyParticles:setSpeedRange(minSpeed, maxSpeed)
  self.opts.speed = { minSpeed, maxSpeed }
  self:_recalcAABB()
  self:markDirty()
end

-- ! Set Angle Range
function RoxyParticles:setAngleRange(a, b)
  self.opts.angleRange = { a, b }
  self:_recalcAABB()
  self:markDirty()
end

-- ! Set Acceleration
function RoxyParticles:setAccel(xx, yy)
  self.opts.accel = { x = xx, y = yy }
  -- Cache the values for hot loop
  self.accelX = xx
  self.accelY = yy
  self:_recalcAABB()
  self:markDirty()
end

-- ! Set Size Range
function RoxyParticles:setSizeRange(minSize, maxSize)
  self.opts.size = { minSize, maxSize }
  self:_recalcAABB()
  self:markDirty()
end

-- ! Set Max Count
function RoxyParticles:setMaxCount(newMax)
  newMax = math.floor(newMax or 1)
  if not self.cpool or newMax <= 0 or newMax == self.opts.maxCount then return end

  local success = resizePool_C(self.cpool, newMax)
  if success then
    self.opts.maxCount = newMax
    if self.opts.pattern then
      self:setPattern(self.opts.pattern)
    end
    self:markDirty()
  else --#DEBUG
    Log.error("[RoxyParticles:setMaxCount] Failed to resize particle pool") --#DEBUG
  end
end

-- ! Set Z-Index
function RoxyParticles:setZIndex(z)
  RoxyParticles.super.setZIndex(self, z or 1)
  self:markDirty()
end

-- ! Set Frame Rate
function RoxyParticles:setFrameRate(frameRate)
  self.opts.frameRate = frameRate or DEFAULT_OPTS.frameRate
  -- Push the new FPS into C so spawn/update use it
  setFrameRate_C(self.cpool, self.opts.frameRate)
  -- Force a redraw so any timing-sensitive visuals pick up the new rate immediately
  self:markDirty()
end

-- ! Set Shape
function RoxyParticles:setShape(shape)
  self.opts.shape = shape
  -- Cache the values for hot loop
  self.shape = shape
  self.shapeID = SHAPE_MAP[shape] or 0
  self:markDirty()
end

-- ! Set Frame Mode
function RoxyParticles:setFrameMode(mode, staticFrame)
  --#DEBUG START
  if not MODE_MAP[mode] then
    Log.error("[RoxyParticles:setFrameMode] Invalid frameMode: " .. tostring(mode))
  end
  --#DEBUG END

  self.opts.frameMode = mode
  -- Clamp 1-based
  if mode == "static" and self.frameCount then
    self.staticFrame = clamp(staticFrame or 1, 1, self.frameCount)
  end

  -- Push into C if we have a table
  if self.opts.imageTable then
    local modeInt = MODE_MAP[self.opts.frameMode] or FRAME_MODE_SEQUENTIAL
    local loopInt = (self.opts.loop == false) and 0 or 1
    setImageTable_C(
      self.cpool,
      self.opts.imageTable,
      modeInt,
      self.staticFrame,
      loopInt
    )
  end

  self:markDirty()
end

-- ! Set Static Frame
function RoxyParticles:setStaticFrame(frame)
  self.opts.staticFrame = frame or 1
  if self.frameCount then
    self.staticFrame = clamp(self.opts.staticFrame, 1, self.frameCount)
  end

  -- Push into C
  if self.opts.imageTable then
    local modeInt = MODE_MAP[self.opts.frameMode] or FRAME_MODE_SEQUENTIAL
    local loopInt = (self.opts.loop == false) and 0 or 1
    setImageTable_C(
      self.cpool,
      self.opts.imageTable,
      modeInt,
      self.staticFrame,
      loopInt
    )
  end

  self:markDirty()
end

-- ! Set Loop
function RoxyParticles:setLoop(loop)
  -- False --> 0, true or nil --> 1
  self.opts.loop = (loop == nil) or loop

  -- Push into C
  if self.opts.imageTable then
    local modeInt = MODE_MAP[self.opts.frameMode] or FRAME_MODE_SEQUENTIAL
    local loopInt = (self.opts.loop == false) and 0 or 1
    setImageTable_C(
      self.cpool,
      self.opts.imageTable,
      modeInt,
      self.staticFrame,
      loopInt
    )
  end

  self:markDirty()
end

-- ! Set Image Table
function RoxyParticles:setImageTable(imageTable, frameMode, loop)
  self.opts.imageTable = imageTable
  self.opts.frameMode  = frameMode or "sequential"
  self.opts.loop       = (loop == nil) or loop

  if imageTable then
    -- Get length + dimensions
    self.frameCount  = imageTable:getLength()
    local img        = imageTable:getImage(1)
    self.frameWidth, self.frameHeight = img:getSize()

    -- Clamp the static frame (1-based)
    self.staticFrame = clamp(self.opts.staticFrame or 1, 1, self.frameCount)

    -- Map Lua string --> int, and bool --> 0/1
    local modeInt = MODE_MAP[self.opts.frameMode] or FRAME_MODE_SEQUENTIAL
    local loopInt = (self.opts.loop == false) and 0 or 1

    -- Pass everything into C
    setImageTable_C(
      self.cpool,
      imageTable,
      modeInt,
      self.staticFrame,  -- Still 1-based; C will subtract 1
      loopInt
    )
  else
    -- No table: clear on C side
    self.frameCount  = 0
    self.frameWidth  = nil
    self.frameHeight = nil
    self.opts.shape = self.opts.shape or DEFAULT_OPTS.shape
    setImageTable_C(
      self.cpool,
      nil,
      FRAME_MODE_SEQUENTIAL,
      1,  -- StaticFrame --> frame 1
      1   -- Loop=true
    )
  end

  self:_recalcAABB()
  self:markDirty()
end

-- ! Set Pattern
function RoxyParticles:setPattern(pattern)
  if type(pattern) == "table" then
    --#DEBUG START
    -- Validate that we have exactly 8 entries of 8-bit numbers
    Log.assert(#pattern >= 8,
      "[RoxyParticles:setPattern] Pattern table must have at least 8 entries")
    for i = 1, 8 do
      Log.assert(
        type(pattern[i]) == "number" and pattern[i] >= 0 and pattern[i] <= 0xFF,
        "[RoxyParticles:setPattern] Pattern entries must be 8-bit numbers"
      )
    end
    --#DEBUG END

    -- Convert table of bytes into a raw string for the C backend
    local raw = char(tableUnpack(pattern))
    setPattern_C(self.cpool, raw)
    self.opts.pattern = pattern
  elseif type(pattern) == "string" and pattern:match("^%s*{") then
    -- Hex-list string like "{ 0xaa, 0x55, ... }"
    local tbl   = {}
    local count = 0
    -- Each iteration is O(1)
    for hex in pattern:gmatch("0x[%da-fA-F]+") do
      count = count + 1
      tbl[count] = tonumber(hex)
    end
    Log.assert(count == 8, "[RoxyParticles:setPattern] Pattern string must have 8 hex entries") --#DEBUG
    return self:setPattern(tbl)
  elseif type(pattern) == "string" then
    -- Raw 8-byte string
    Log.assert(#pattern == 8, "[RoxyParticles:setPattern] Pattern string must be 8 bytes") --#DEBUG
    setPattern_C(self.cpool, pattern)
    self.opts.pattern = pattern
  elseif pattern == nil then
    -- Clear pattern, revert to color
    setPattern_C(self.cpool, nil)
    self.opts.pattern = nil
  else --#DEBUG
    Log.error("[RoxyParticles:setPattern] Pattern must be a table, string, or nil") --#DEBUG
  end

  self:markDirty()
end

-- ! Set Color
function RoxyParticles:setColor(newColor)
  self.opts.color = newColor
  -- Cache the value for hot loop
  self.color = newColor
  self:markDirty()
end

-- ! Check Active Particles
-- Returns true if any particles are active
function RoxyParticles:hasActiveParticles()
  -- Simply return the last-update result
  return self._hasActiveParticles or false
end

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

RoxyParticles creates sprite-backed particle emitters with C-side simulation.

local Graphics <const> = playdate.graphics

-- Burst Emitter
local sparks = RoxyParticles(120, 80, {
  maxCount = 80,
  lifetime = { 0.25, 0.6 },
  speed = { 40, 120 },
  size = { 1, 4 },
  angleRange = { -120, -60 },
  color = Graphics.kColorBlack,
})
scene:addSprite(sparks)
sparks:emit(24)

-- Continuous Emitter
local smoke = RoxyParticles(200, 180, {
  rate = 12,
  lifetime = { 1.0, 2.0 },
  speed = { 8, 18 },
  accel = { x = 0, y = -8 },
  size = { 3, 8 },
  shape = "outline-circle",
})
scene:addSprite(smoke)
smoke:setRate(20)
smoke:setAngleRange(-100, -80)

-- Imagetable Particles
local leaves = RoxyParticles(200, 40, {
  imageTable = Graphics.imagetable.new("images/particles/leaves"),
  frameMode = "random",
  loop = false,
  rate = 8,
  accel = { x = 6, y = 18 },
  speed = { 10, 30 },
})
scene:addSprite(leaves)
leaves:setFrameRate(16)

-- Pattern, Finish, and Cleanup
sparks:setPattern({ 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55, 0xaa, 0x55 })
sparks.onFinished = function(emitter)
  emitter:remove()
  emitter:destroy()
end

smoke:clear()
leaves:reset()
leaves:setImageTable(nil)

--]]
