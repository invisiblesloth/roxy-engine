-- core/physics/RoxyPhysicsBody.lua

local abs     <const> = math.abs
local pd      <const> = playdate
local Object  <const> = pd.object

local FLOOR_LIMIT <const> = 0.7 --  normal.y  < -FLOOR_LIMIT  --> floor
local CEIL_LIMIT  <const> = 0.7 --  normal.y  >  CEIL_LIMIT   --> ceiling
local WALL_LIMIT <const> = 0.7  -- |normal.x| >  WALL_LIMIT   --> wall

--------------------------------------------------------------------------------
-- Class Definition & Init
--------------------------------------------------------------------------------

class("RoxyPhysicsBody").extends(Object)

-- ! Initializes
function RoxyPhysicsBody:init(owner, opts)
  opts = opts or {}
  self.owner = owner -- The RoxyActor/RoxySprite
  self.vx = opts.vx or 0
  self.vy = opts.vy or 0
  self.ax = 0
  self.ay = opts.gravity or 200
  self.onGround = false
  self.onCollision = opts.onCollision -- Optional user function

  -- Collision flags
  self.enableCollisions = (opts.enableCollisions ~= false)
  self.autoSetCollideRect = (opts.autoSetCollideRect == true)

  -- Clear ay each frame by default when gravity is zero (top-down mode).
  -- You can override explicitly via opts.clearAyEachFrame = true/false.
  if opts.clearAyEachFrame ~= nil then
    self.clearAyEachFrame = opts.clearAyEachFrame
  else
    self.clearAyEachFrame = (opts.gravity == 0)
  end

  -- Optionally set a collide rect to the sprite size if requested and missing
  if self.enableCollisions and self.autoSetCollideRect and self._hasInvalidCollideRect(owner) then
    local width, height = owner:getSize()
    if width and height and width > 0 and height > 0 then
      owner:setCollideRect(0, 0, width, height)
    end
  end
end

-- ! Has Invalid Collide Rectangle
-- Helper to detect an invalid collide rect (nil or zero width/height)
function RoxyPhysicsBody:_hasInvalidCollideRect(sprite)
  local rect = sprite:getCollideRect()
  if not rect then return true end
  -- Playdate rect provides .width and .height
  if rect.width == 0 or rect.height == 0 then return true end
  return false
end

-- ! Update
function RoxyPhysicsBody:update(dt)
  -- Integrate acceleration
  self.vx = self.vx + self.ax * dt
  self.vy = self.vy + self.ay * dt

  -- Apply friction if on ground and no acceleration
  if self.onGround and self.friction then
    if abs(self.vx) > 0 then
      local sign = self.vx > 0 and 1 or -1
      local frictionForce = self.friction * dt * sign
      if abs(frictionForce) > abs(self.vx) then
        self.vx = 0
      else
        self.vx = self.vx - frictionForce
      end
    end
  end

  -- Compute target position
  local sprite = self.owner
  local targetX, targetY = sprite.x + self.vx * dt, sprite.y + self.vy * dt

  self.onGround = false

  -- Move: collisions if enabled and collide rect valid; else simple moveTo
  local useCollisions = self.enableCollisions and (not self:_hasInvalidCollideRect(sprite))
  if useCollisions then
    local _, _, collisions = sprite:moveWithCollisions(targetX, targetY)

    -- Resolve collisions
    for _, collision in ipairs(collisions) do
      local nx, ny = collision.normal.x, collision.normal.y

      -- Prefer axis with largest absolute value (dominant axis)
      if abs(ny) > abs(nx) then
        if ny < -FLOOR_LIMIT then -- Floor
          self.vy = 0
          self.onGround = true
        elseif ny > CEIL_LIMIT then -- Ceiling
          self.vy = 0
        end
      else
        if abs(nx) > WALL_LIMIT then -- Wall
          self.vx = 0
        end
      end

      -- Clamp residual velocity to avoid micro-jitter
      if abs(self.vx) < 0.01 then self.vx = 0 end
      if abs(self.vy) < 0.01 then self.vy = 0 end

      if self.onCollision then
        self:onCollision(collision)
      end
    end
  else
    -- No-collision path
    sprite:moveTo(targetX, targetY)
    -- Clamp here too so tiny velocities actually settle
    if abs(self.vx) < 0.01 then self.vx = 0 end
    if abs(self.vy) < 0.01 then self.vy = 0 end
  end

  -- Zero ax so you treat acceleration as an instant "force" per input frame
  self.ax = 0

  -- Also clear ay if we're in top-down/no-gravity mode so forces don't accumulate.
  if self.clearAyEachFrame then
    self.ay = 0
  end
end
