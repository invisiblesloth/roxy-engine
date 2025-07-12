-- core/physics/RoxyPhysicsBody.lua

local pd      <const> = playdate
local Object  <const> = pd.object

local abs <const> = math.abs

local FLOOR_LIMIT <const> = 0.7 --  normal.y  < -FLOOR_LIMIT  --> floor
local CEIL_LIMIT  <const> = 0.7 --  normal.y  >  CEIL_LIMIT   --> ceiling
local WALL_LIMIT <const> = 0.7 -- |normal.x| >  WALL_LIMIT  --> wall

-- ----------------------------------------
-- Class Definition & Init
-- ----------------------------------------

class("RoxyPhysicsBody").extends(Object)

function RoxyPhysicsBody:init(owner, opts)
  opts = opts or {}
  self.owner = owner -- The RoxyActor/RoxySprite
  self.vx = opts.vx or 0
  self.vy = opts.vy or 0
  self.ax = 0
  self.ay = opts.gravity or 200
  self.onGround = false
  self.onCollision = opts.onCollision -- Optional user function
end

function RoxyPhysicsBody:update(dt)
  -- (1) Integrate acceleration
  self.vx = self.vx + self.ax * dt
  self.vy = self.vy + self.ay * dt

  -- Optional polish: Apply friction if on ground and no acceleration
  -- (Set self.friction elsewhere as needed)
  if self.onGround and self.friction then
    if abs(self.vx) > 0 then
      local sign = self.vx > 0 and 1 or -1
      local frictionForce = self.friction * dt * sign
      -- Only zero out or reduce velocity, not reverse it
      if abs(frictionForce) > abs(self.vx) then
        self.vx = 0
      else
        self.vx = self.vx - frictionForce
      end
    end
  end

  -- (2) Try to move
  local sprite = self.owner
  local targetX, targetY = sprite.x + self.vx * dt, sprite.y + self.vy * dt
  local _, _, collisions = sprite:moveWithCollisions(targetX, targetY)

  self.onGround = false

  -- (3) Resolve collisions
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

  -- Zero ax so you treat acceleration as an instant "force" per input frame
  self.ax = 0
end
