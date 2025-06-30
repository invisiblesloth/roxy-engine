-- core/sprites/RoxyParticles.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite
local r         <const> = roxy

local random  <const> = math.random
local max     <const> = math.max
local min     <const> = math.min
local cos     <const> = math.cos
local sin     <const> = math.sin
local rad     <const> = math.rad
local floor   <const> = math.floor
local ceil    <const> = math.ceil
local clamp   <const> = r.Math.clamp

local tableInsert <const> = table.insert

local setColor          <const> = Graphics.setColor
local getColor          <const> = Graphics.getColor
local setPattern        <const> = Graphics.setPattern
local pushContext       <const> = Graphics.pushContext  --#DEBUG
local popContext        <const> = Graphics.popContext   --#DEBUG
local newImage          <const> = Graphics.image.new    --#DEBUG
local drawCircleAtPoint <const> = Graphics.drawCircleAtPoint
local fillCircleAtPoint <const> = Graphics.fillCircleAtPoint
local drawRect          <const> = Graphics.drawRect
local fillRect          <const> = Graphics.fillRect

local COLOR_BLACK <const> = Graphics.kColorBlack
local COLOR_WHITE <const> = Graphics.kColorWhite

local DISPLAY_WIDTH  <const> = r.Graphics.displayWidth
local DISPLAY_HEIGHT <const> = r.Graphics.displayHeight

-- ----------------------------------------
-- Helpers
-- ----------------------------------------

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

-- ! Normalize Range
-- Returns a normalized angle range: [-180, 180] with span < 360
local function normalizeRange(a, b)
  a = ((a + 180) % 360) - 180
  b = ((b + 180) % 360) - 180
  local span = b - a
  if span <= -360 or span >= 360 then
    return -180, 180, true -- Full circle
  end
  if span < 0 then b = b + 360 end
  return a, b, false
end

-- ! Random Range
-- Returns a uniform float in the closed range [lo, hi]
local function randRange(lo, hi)
  if lo == hi then return lo end
  return lo + random() * (hi - lo)
end

-- ! Compute AABB (Bounding Box)
-- Compute the axis-aligned bounding box (AABB) for a given configuration
local function computeAABB(opts, angleMin, angleMax, fullCircle, frameWidth, frameHeight)
  local tMin, tMax = opts.lifetime[1], opts.lifetime[2]
  local vMin, vMax = opts.speed[1], opts.speed[2]
  local ax         = opts.accel.x or 0
  local ay         = opts.accel.y or 0
  local sizeMin    = opts.size[1] or 0
  local sizeMax    = opts.size[2] or 0

  local left, right, top, bottom = 0, 0, 0, 0
  local function add(dx, dy)
    if dx < left   then left   = dx end
    if dx > right  then right  = dx end
    if dy < top    then top    = dy end
    if dy > bottom then bottom = dy end
  end

  -- Always include emitter origin
  add(0, 0)

  -- List all angles to check (same as before)
  local candidateAngles = { angleMin, angleMax }
  local function inSweep(d)
    if fullCircle then return true end
    local degrees = d
    if degrees < angleMin then degrees = degrees + 360 end
    return degrees >= angleMin and degrees <= angleMax
  end
  if inSweep(0)   then tableInsert(candidateAngles, 0)   end
  if inSweep(90)  then tableInsert(candidateAngles, 90)  end
  if inSweep(-90) then tableInsert(candidateAngles, -90) end

  -- Try all extremes of lifetime and speed
  local lifetimeList = { tMin, tMax }
  local speedList    = { vMin, vMax }

  local function feedAll(v, th, t)
    local vx = v * cos(th)
    local vy = v * sin(th)

    -- At end of life
    add(
      vx * t + 0.5 * ax * t * t,
      vy * t + 0.5 * ay * t * t
    )
    -- At turning points in X/Y (if in range)
    if ax ~= 0 then
      local tx = -vx / ax
      if tx > 0 and tx < t then
        add(
          vx * tx + 0.5 * ax * tx * tx,
          vy * tx + 0.5 * ay * tx * tx
        )
      end
    end
    if ay ~= 0 then
      local ty = -vy / ay
      if ty > 0 and ty < t then
        add(
          vx * ty + 0.5 * ax * ty * ty,
          vy * ty + 0.5 * ay * ty * ty
        )
      end
    end
  end

  -- For each candidate angle, check both min/max speeds and lifetimes
  for _, deg in ipairs(candidateAngles) do
    local th = rad(deg)
    for _, v in ipairs(speedList) do
      for _, t in ipairs(lifetimeList) do
        feedAll(v, th, t)
      end
    end
  end

  -- Padding: use max size
  local pad
  if opts.imageTable and frameWidth and frameHeight then
    pad = ceil(max(frameWidth, frameHeight) / 2)
  else
    pad = ceil(sizeMax / 2)
  end

  left   = floor(left - pad)
  right  = ceil(right + pad)
  top    = floor(top - pad)
  bottom = ceil(bottom + pad)

  local boxW = max(1, right - left)
  local boxH = max(1, bottom - top)

  return left, right, top, bottom, boxW, boxH
end

-- ! Shape Drawers
-- Pre-localize shape drawers (micro-opt)
local shapeDrawers = {
  circle = function(x, y, size)
    fillCircleAtPoint(x, y, size / 2)
  end,
  ["outline-circle"] = function(x, y, size)
    drawCircleAtPoint(x, y, size / 2)
  end,
  square = function(x, y, size)
    fillRect(x - size / 2, y - size / 2, size, size)
  end,
  ["outline-square"] = function(x, y, size)
    drawRect(x - size / 2, y - size / 2, size, size)
  end
}

-- ----------------------------------------
-- ! Class Definition & Init
-- ----------------------------------------

class("RoxyParticles").extends(RoxySprite)

function RoxyParticles:init(x, y, opts)
  RoxySprite.super.init(self)

  -- Sanitize/patch missing opts fields
  opts            = opts or {}
  opts.accel      = opts.accel      or { x = 0, y = 0 }
  opts.speed      = opts.speed      or { 20, 20 }
  opts.lifetime   = opts.lifetime   or { 1.0, 1.0 }
  opts.size       = opts.size       or { 2, 8 }
  opts.angleRange = opts.angleRange or { -180, 180 }
  opts.maxCount   = opts.maxCount   or 20
  self.opts       = opts

  self:setZIndex(opts.zIndex or 1)

  -- Normalized angle range
  local angMin, angMax, fullCircle
  if not opts.angleRange
      or type(opts.angleRange[1]) ~= "number"
      or type(opts.angleRange[2]) ~= "number" then
    angMin, angMax, fullCircle = -180, 180, true
  else
    angMin, angMax, fullCircle = normalizeRange(opts.angleRange[1], opts.angleRange[2])
    if angMin == angMax and not fullCircle then
      angMin = angMin - 0.01
      angMax = angMax + 0.01
    end
  end
  self.angleMin = angMin
  self.angleMax = angMax
  self.fullCircle = fullCircle

  -- ImageTable
  if opts.imageTable then
    self.frameCount = opts.imageTable:getLength()
    local frameImage = opts.imageTable:getImage(1)
    self.frameWidth, self.frameHeight = frameImage:getSize()
  end

  -- Calculate AABB
  local left, right, top, bottom, boxW, boxH = computeAABB(
    opts, self.angleMin, self.angleMax, self.fullCircle, self.frameWidth, self.frameHeight
  )

  -- Sprite Positioning
  self:setSize(boxW, boxH)
  self:setCenter(-left / boxW, -top / boxH)
  self:moveTo(x, y)
  self.emitterOffsetX = -left
  self.emitterOffsetY = -top

  -- Particle Pool
  self.pool = {}
  for i = 1, opts.maxCount do
    self.pool[i] = { alive = false }
  end
  self.accumulator = 0

  -- Static Frame Clamp
  if opts.frameMode == "static" and self.frameCount then
    local staticFrame = opts.staticFrame or 1
    self.staticFrameClamped = clamp(staticFrame, 1, self.frameCount)
  end

  --#DEBUG START
  -- Debug crosshair singleton
  self.debugCrosshairImage = getCrosshairImage()
  --#DEBUG END
end

-- ----------------------------------------
-- Internal Methods
-- ----------------------------------------

-- ! Recalculate AABB
-- Recalculate and apply AABB, reposition sprite
function RoxyParticles:_recalcAABB()
  local left, right, top, bottom, boxW, boxH = computeAABB(
    self.opts, self.angleMin, self.angleMax, self.fullCircle, self.frameWidth, self.frameHeight
  )
  self:setSize(boxW, boxH)
  self:setCenter(-left / boxW, -top / boxH)
  self.emitterOffsetX = -left
  self.emitterOffsetY = -top
end

-- ! Spawn
-- Spawn a single particle
function RoxyParticles:spawn()
  for i = 1, #self.pool do
    local p = self.pool[i]
    if not p.alive then
      p.alive = true; p.age = 0
      p.lifetime = randRange(self.opts.lifetime[1], self.opts.lifetime[2])
      local theta = rad(randRange(self.angleMin, self.angleMax))
      local speed = randRange(self.opts.speed[1], self.opts.speed[2])
      p.vx, p.vy = speed * cos(theta), speed * sin(theta)
      p.x, p.y = self.emitterOffsetX, self.emitterOffsetY
      p.size = randRange(self.opts.size[1], self.opts.size[2])

      -- Frame setup (imageTable mode)
      if self.opts.imageTable and self.frameCount and self.frameCount > 0 then
        if self.frameWidth and self.frameHeight then
          p.x = self.emitterOffsetX - self.frameWidth / 2
          p.y = self.emitterOffsetY - self.frameHeight / 2
        end
        local mode = self.opts.frameMode or "static"
        if mode == "sequential" or mode == "reverse" then
          p.frame = (mode == "sequential") and 1 or self.frameCount
          p.frameRate = self.opts.frameRate or 12
          p.frameTimer = 0
        elseif mode == "random" then
          p.frameRate = self.opts.frameRate or 0
          p.frame = random(1, self.frameCount)
          p.frameTimer = 0
        elseif mode == "static" then
          p.frame = self.staticFrameClamped or 1
        end
      end

      -- break
      return true
    end
  end
  return false
end

-- ! Update
function RoxyParticles:update()
  local dt = r.deltaTime
  local dirty = false

  -- Cache hot opts fields
  local accelX, accelY = self.opts.accel.x, self.opts.accel.y
  local imgTable       = self.opts.imageTable
  local frameCnt       = self.frameCount
  local axdt, aydt     = accelX * dt, accelY * dt

  -- Spawn particles based on rate
  local rate = self.opts.rate or 0
  if rate > 0 then
    self.accumulator += dt * rate
    while self.accumulator >= 1 do
      self:spawn()
      self.accumulator -= 1
      dirty = true
    end
  end

  -- Update particles
  for i = 1, #self.pool do
    local p = self.pool[i]
    if p.alive then
      p.age += dt
      if p.age >= p.lifetime then
        p.alive = false
        dirty = true
      else
        -- Euler step
        p.vx += axdt
        p.vy += aydt
        p.x  += p.vx * dt
        p.y  += p.vy * dt

        dirty = true

        -- Animation frames
        if imgTable and frameCnt and frameCnt > 0 then
          local mode = self.opts.frameMode or "static"
          if (mode == "sequential" or mode == "reverse") and p.frameRate then
            if p.frameRate == 0 then goto continue end -- Avoid division by zero
            p.frameTimer = (p.frameTimer or 0) + dt
            local frameAdvance = floor(p.frameTimer * p.frameRate)
            if frameAdvance > 0 then
              local loop = self.opts.loop
              if mode == "sequential" then
                p.frame = p.frame + frameAdvance
                if loop then
                  p.frame = ((p.frame - 1) % frameCnt) + 1
                else
                  p.frame = min(frameCnt, p.frame)
                end
              else
                p.frame = p.frame - frameAdvance
                if loop then
                  p.frame = ((p.frame - 1 + frameCnt) % frameCnt) + 1
                else
                  p.frame = max(1, p.frame)
                end
              end
              p.frameTimer = p.frameTimer - frameAdvance / p.frameRate
            end
          elseif mode == "random" and p.frameRate and p.frameRate > 0 then
            p.frameTimer = (p.frameTimer or 0) + dt
            if p.frameTimer >= 1 / p.frameRate then
              p.frame = random(1, frameCnt)
              p.frameTimer = p.frameTimer - 1 / p.frameRate
            end
          end
        end
        ::continue::
      end
    end
  end

  if dirty then self:markDirty() end
end

-- ! Draw
function RoxyParticles:draw()
  local oldColor = getColor()

  -- Set color/pattern for particle batch
  if self.opts.pattern then
    setPattern(self.opts.pattern)
  else
    setColor(self.opts.color or COLOR_BLACK)
  end

  local imgTable, frameCnt = self.opts.imageTable, self.frameCount
  for i = 1, #self.pool do
    local p = self.pool[i]
    if p.alive then
      if imgTable and frameCnt and frameCnt > 0 then
        imgTable:drawImage(p.frame or 1, p.x, p.y)
      else
        local shape = self.opts.shape or "circle"
        local drawer = shapeDrawers[shape]
        if drawer then
          drawer(p.x, p.y, p.size)
        elseif type(shape) == "function" then
          shape(p.x, p.y, p.size, p)
        end
      end
    end
  end

  --#DEBUG START
  -- Draw debug crosshair
  if Debug.visualDebug and self.debugCrosshairImage then
    self.debugCrosshairImage:draw(self.emitterOffsetX - 4, self.emitterOffsetY - 4)
  end
  --#DEBUG END

  -- Restore previous draw state
  setColor(oldColor)
end

-- ----------------------------------------
-- Public API
-- -----------------------------------------

-- ! Clear
function RoxyParticles:clear()
  for i = 1, #self.pool do
    self.pool[i].alive = false
  end
  self.accumulator = 0
  self:markDirty()
end

-- ! Burst Emit
-- Instantly spawn `count` particles regardless of rate
function RoxyParticles:emit(count)
  count = floor(count or 1)
  for i = 1, count do
    if self:spawn() == false then break end
  end
  self:markDirty()
end

-- ! Set Particle Rate
function RoxyParticles:setRate(rate)
  self.opts.rate = rate or 10
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
  local angMin, angMax, fullCircle = normalizeRange(a, b)
  self.angleMin, self.angleMax, self.fullCircle = angMin, angMax, fullCircle
  self:_recalcAABB()
  self:markDirty()
end

-- ! Set Acceleration
function RoxyParticles:setAccel(a, b)
  self.opts.accel = { x = a, y = b }
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
  newMax = floor(newMax)
  local oldPool = self.pool
  self.pool = {}
  for i = 1, newMax do
    self.pool[i] = oldPool[i] or { alive = false }
  end
  self.opts.maxCount = newMax
  self:markDirty()
end

-- ! Set Z-Index
function RoxyParticles:setZIndex(z)
  RoxyParticles.super.setZIndex(self, z or 1)
end

-- ! Set Frame Rate
function RoxyParticles:setFrameRate(frameRate)
  self.opts.frameRate = frameRate or 12
end

-- ! Set Shape
function RoxyParticles:setShape(shape)
  self.opts.shape = shape
  self:markDirty()
end

-- ! Set Frame Mode
function RoxyParticles:setFrameMode(mode, staticFrame)
  self.opts.frameMode = mode
  if mode == "static" and self.frameCount then
    self.staticFrameClamped = clamp(staticFrame or 1, 1, self.frameCount)
  end
end

-- ! Set Static Frame
function RoxyParticles:setStaticFrame(frame)
  self.opts.staticFrame = frame or 1
  if self.frameCount then
    self.staticFrameClamped = clamp(frame or 1, 1, self.frameCount)
  end
end

-- ! Set Loop
function RoxyParticles:setLoop(loop)
  self.opts.loop = (loop == nil) or loop
end

-- ! Set Image Table
function RoxyParticles:setImageTable(imageTable, frameMode, loop)
  self.opts.imageTable = imageTable
  self.opts.frameMode = frameMode or "static"
  self.opts.loop = (loop == nil) or loop
  if imageTable then
    self.frameCount = imageTable:getLength()
    local frameImage = imageTable:getImage(1)
    self.frameWidth, self.frameHeight = frameImage:getSize()
  else
    self.frameCount = 0
    self.frameWidth = nil
    self.frameHeight = nil
  end
  self:_recalcAABB()
  self:markDirty()
end

-- ! Set Pattern
function RoxyParticles:setPattern(newPattern)
  self.opts.pattern = newPattern
  self:markDirty()
end

-- ! Set Color
function RoxyParticles:setColor(newColor)
  self.opts.color = newColor
  self:markDirty()
end
