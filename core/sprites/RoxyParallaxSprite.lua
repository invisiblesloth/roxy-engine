-- core/sprites/RoxyParallaxSprite.lua

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local Camera <const> = roxy.Camera

local round <const> = roxy.Math.round

class("RoxyParallaxSprite").extends(RoxySprite)

--[[
  opts: table {
    view               = image or imagetable path or RoxyAnimation,
    singleAnim         = bool,
    singleAnimLoop     = bool,
    isSheet            = bool,
    frameDuration      = number,
    name               = string,

    -- Parallax-specific:
    worldX             = number,
    worldY             = number,
    parallaxX          = number,
    parallaxY          = number,
    parallaxOriginX    = number,
    parallaxOriginY    = number,
  }
  scene: optional scene with addSprite method
]]
function RoxyParallaxSprite:init(opts, scene)
  -- Forward opts and scene to RoxySprite
  RoxyParallaxSprite.super.init(self, opts, scene)

  opts = opts or {}
  -- Parallax state
  self.worldX = opts.worldX or (self.x or 0)
  self.worldY = opts.worldY or (self.y or 0)
  self.parallaxX = opts.parallaxX or 1
  self.parallaxY = opts.parallaxY or 1
  self.parallaxOriginX = opts.parallaxOriginX or 0
  self.parallaxOriginY = opts.parallaxOriginY or 0

  -- Enable custom positioning
  self:setIgnoresDrawOffset(true)
  self:setUpdatesEnabled(true)
end

-- Allow changing at runtime
function RoxyParallaxSprite:setWorldPosition(x, y)
  self.worldX = x or self.worldX
  self.worldY = y or self.worldY
  return self
end

function RoxyParallaxSprite:setParallax(px, py)
  self.parallaxX = px or self.parallaxX
  self.parallaxY = py or self.parallaxY
  return self
end

function RoxyParallaxSprite:setParallaxOrigin(ox, oy)
  self.parallaxOriginX = ox or self.parallaxOriginX
  self.parallaxOriginY = oy or self.parallaxOriginY
  return self
end

function RoxyParallaxSprite:update()
  -- Compute parallax-based position
  local camX, camY = Camera.getPosition()

  -- World position & parallax settings:
  local wx, wy    = self.worldX, self.worldY
  local px, py    = self.parallaxX, self.parallaxY
  local pox, poy  = self.parallaxOriginX, self.parallaxOriginY

  local screenX = round(wx + pox * (1 - px) - camX * px)
  local screenY = round(wy + poy * (1 - py) - camY * py)
  self:moveTo(screenX, screenY)

  -- Continue with normal animation/etc
  RoxyParallaxSprite.super.update(self)
end
