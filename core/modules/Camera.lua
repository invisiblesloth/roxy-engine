-- core/modules/Camera.lua

roxy = roxy or {}
roxy.Camera = roxy.Camera or {}
local Camera <const> = roxy.Camera

local pd        <const> = playdate
local Display   <const> = pd.display
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite

local abs   <const> = math.abs
local min   <const> = math.min
local max   <const> = math.max
local sin   <const> = math.sin
local cos   <const> = math.cos
local clamp <const> = roxy.Math.clamp
local floor <const> = math.floor
local ceil  <const> = math.ceil
local pi    <const> = math.pi
local lerp  <const> = roxy.Math.lerp
local round <const> = roxy.Math.roundInt

local setDrawOffset <const> = Graphics.setDrawOffset

local redrawBackground <const> = Sprite.redrawBackground

local CAMERA_SPEED_DEFAULT <const> = 120  -- Default pan velocity (pixels per second)
local FRICTION_DEFAULT <const>     = 0.85 -- Default friction factor (0 to 1, higher = slower stop)

local DISPLAY_WIDTH   <const> = roxy.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = roxy.Graphics.displayHeight
local CENTER_X        <const> = roxy.Graphics.displayWidthCenter
local CENTER_Y        <const> = roxy.Graphics.displayHeightCenter

-- Global State
Camera.x                = 0     -- current x position
Camera.y                = 0     -- current y position
Camera._velocityX       = 0     -- velocity in x direction
Camera._velocityY       = 0     -- velocity in y direction
Camera._lastX           = 0     -- last x position for dirty rect
Camera._lastY           = 0     -- last y position for dirty rect
Camera._targetX         = 0     -- target x position
Camera._targetY         = 0     -- target y position
Camera.target           = nil   -- sprite to follow
Camera._bounds          = nil   -- { x1, y1, x2, y2 }
Camera._boundsCache     = nil
Camera._hasBounds       = false -- whether bounds are active
Camera._minX            = 0     -- minimum x bound
Camera._minY            = 0     -- minimum y bound
Camera._maxX            = 0     -- maximum x bound
Camera._maxY            = 0     -- maximum y bound
Camera.smoothing        = 0     -- smoothing rate in 1/seconds (0 = instant)
Camera._shakeAmplitude  = 0     -- Shake intensity (pixels)
Camera.shakeDuration    = 0     -- Remaining shake time (seconds)
Camera._shakeFrequency  = 0     -- Shake oscillations per second
Camera._shakeTimer      = 0     -- Tracks elapsed shake time
Camera._deadZoneWidth   = 0     -- Dead zone width (pixels, 0 = disabled)
Camera._deadZoneHeight  = 0     -- Dead zone height (pixels, 0 = disabled)
Camera.friction         = FRICTION_DEFAULT

-- Indicates whether the camera needs an update this frame.
-- Remains true while there’s an active target, any velocity, or an ongoing shake.
Camera._isActive = true -- Ensure initial update

-- Default to static mode (must be set after all Camera functions exist!)
Camera._updateFunc = nil

-- ----------------------------------------
-- Helpers
-- ----------------------------------------

-- ! Helper: Shake helper
-- _applyShake(dt) only uses dt to advance the internal shake timer.
-- All offset calculations are based on the timer; dt is not used elsewhere here.
local function _applyShake(dt)
  if Camera.shakeDuration <= 0 then return 0, 0 end
  Camera._shakeTimer = Camera._shakeTimer + dt
  if Camera._shakeTimer >= Camera.shakeDuration then
    Camera.shakeDuration = 0
    Camera._shakeAmplitude = 0
    Camera._shakeTimer = 0
    return 0, 0
  end
  local t = Camera._shakeTimer * Camera._shakeFrequency * 2 * pi
  local amplitude = Camera._shakeAmplitude * (1 - Camera._shakeTimer / Camera.shakeDuration) -- Linear decay
  return round(amplitude * sin(t)), round(amplitude * cos(t))
end

-- ! Helper: Commit Offset
local function _commitOffset(dt)
  local newX = round(Camera.x)
  local newY = round(Camera.y)
  local shakeX, shakeY = (Camera.shakeDuration > 0) and _applyShake(dt) or 0, 0
  local totalOffsetX = newX + shakeX
  local totalOffsetY = newY + shakeY
  if abs(totalOffsetX - Camera._lastX) >= 1 or abs(totalOffsetY - Camera._lastY) >= 1 then
    setDrawOffset(-totalOffsetX, -totalOffsetY)
    redrawBackground()
    Camera._lastX, Camera._lastY = totalOffsetX, totalOffsetY
    Camera._isActive = true
  else
    Camera._isActive = Camera.shakeDuration > 0 or Camera._velocityX ~= 0 or Camera._velocityY ~= 0 or Camera.target ~= nil
  end
end

-- ----------------------------------------
-- Public API
-- ----------------------------------------

-- ! Set Position
-- Sets the camera position to (x, y) instantly
function Camera.setPosition(x, y)
  --#DEBUG START
  if type(x) ~= "number" or type(y) ~= "number" then
    Log.error("[Camera.setPosition] Invalid position: expected numbers (x, y)", 2)
  end
  --#DEBUG END
  Camera.x, Camera.y = x, y
  Camera._targetX, Camera._targetY = x, y
  Camera._velocityX, Camera._velocityY = 0, 0
  Camera._updateFunc = Camera.updateStatic
  Camera._isActive = true -- Ensure update runs at least once
end

-- ! Set Pan Velocity
-- Sets pan velocity (pixels/second). If vx is nil, uses CAMERA_SPEED_DEFAULT (120).
-- If vy is nil, uses vx. Set vx=0, vy=0 to stop panning.
function Camera.setPanVelocity(vx, vy)
  --#DEBUG START
  if vx ~= nil and type(vx) ~= "number" then
    Log.error("[Camera.setPanVelocity] Invalid vx: expected a number or nil", 2)
    return
  end
  --#DEBUG END

  -- Apply defaults
  vx = vx or CAMERA_SPEED_DEFAULT
  vy = vy or vx

  --#DEBUG START
  if type(vy) ~= "number" then
    Log.error("[Camera.setPanVelocity] Invalid vy: expected a number or nil", 2)
    return
  end
  --#DEBUG END

  Camera._velocityX = vx
  Camera._velocityY = vy
  Camera._updateFunc = Camera.updateManualPan
  Camera._isActive = true -- Ensure updates run
end

-- ! Set Target
-- Follows a sprite (or nil to stop).
-- Optional smoothing rate controls interpolation speed:
--   0 = Snap instantly to target each frame
--  >0 = Rate in “per second” at which camera moves toward target.
--       Actual lerp factor per frame is t = min(rate * dt, 1).
function Camera.setTarget(sprite, smoothing)
  --#DEBUG START
  if sprite and not sprite.getPosition then
    Log.error("[Camera.setTarget] Invalid sprite: expected a sprite with getPosition method", 2)
  end
  --#DEBUG END
  Camera.target = sprite
  if smoothing ~= nil then
    Camera.smoothing = max(smoothing, 0)
  end
  if sprite then
    Camera._updateFunc = Camera.updateFollow
  else
    Camera._updateFunc = Camera.updateStatic -- Default to static when no target
  end
  Camera._isActive = true
end

-- ! Set Smoothing
-- Sets the global smoothing rate for interpolation:
--   0 = Camera jumps immediately to its desired position
--  >0 = Interpolation rate (1/seconds).
--       Higher values → faster convergence
--       (e.g. rate = 2 means ~50% of gap closed each 1/2s).
function Camera.setSmoothing(rate)
  --#DEBUG START
  if type(rate) ~= "number" then
    Log.error("[Camera.setSmoothing] Invalid smoothing rate: expected a number", 2)
  end
  --#DEBUG END
  Camera.smoothing = max(rate, 0)
end

-- ! Shake
-- Triggers a camera shake effect with amplitude (pixels), duration (seconds), and frequency (oscillations per second).
-- Works in all modes (follow, pan, static).
function Camera.shake(amplitude, duration, frequency)
  --#DEBUG START
  if type(amplitude) ~= "number" or type(duration) ~= "number" or type(frequency) ~= "number" then
    Log.error("[Camera.shake] Invalid shake parameters: expected numbers (amplitude, duration, frequency)", 2)
    return
  end
  --#DEBUG END
  Camera._shakeAmplitude = max(amplitude, 0)
  Camera.shakeDuration = max(duration, 0)
  Camera._shakeFrequency = max(frequency, 0)
  Camera._shakeTimer = 0
  Camera._isActive = true -- Ensure updates run during shake
end

-- ! Set Dead Zone
-- Sets a dead zone rectangle (width, height in pixels). Camera only moves when sprite exits this zone.
-- Use width=0, height=0 to disable.
function Camera.setDeadZone(width, height)
  --#DEBUG START
  if type(width) ~= "number" or type(height) ~= "number" then
    Log.error("[Camera.setDeadZone] Invalid dead zone: expected numbers (width, height)", 2)
    return
  end
  --#DEBUG END
  Camera._deadZoneWidth = max(width, 0)
  Camera._deadZoneHeight = max(height, 0)
end

-- ! Set Friction
-- Sets the default friction factor (0–1) applied when no pan input is active.
function Camera.setFriction(friction)
  --#DEBUG START
  if type(friction) ~= "number" then
    Log.error("[Camera.setFriction] Invalid friction: expected a number", 2)
    return
  end
  --#DEBUG END
  Camera.friction = clamp(friction, 0, 1)
end

-- ! Set Bounds
-- Clamps the camera to a rectangle {x1, y1, x2, y2}
function Camera.setBounds(bounds)
  --#DEBUG START
  if not bounds or type(bounds.x1) ~= "number" or type(bounds.y1) ~= "number" or type(bounds.x2) ~= "number" or type(bounds.y2) ~= "number" then
    Log.error("[Camera.setBounds] Invalid bounds: expected {x1, y1, x2, y2} with numbers", 2)
    Camera._bounds = nil
    Camera._hasBounds = false
    Camera._minX, Camera._minY = 0, 0
    Camera._maxX, Camera._maxY = 0, 0
    return
  end
  --#DEBUG END

  Camera._bounds = bounds
  Camera._hasBounds = true
  Camera._minX = min(bounds.x1, bounds.x2)
  Camera._maxX = max(bounds.x1, bounds.x2)
  Camera._minY = min(bounds.y1, bounds.y2)
  Camera._maxY = max(bounds.y1, bounds.y2)

  -- Cache bounds table for getBounds efficiency
  Camera._boundsCache = Camera._boundsCache or { x1 = 0, y1 = 0, x2 = 0, y2 = 0 }
  Camera._boundsCache.x1 = Camera._minX
  Camera._boundsCache.y1 = Camera._minY
  Camera._boundsCache.x2 = Camera._maxX
  Camera._boundsCache.y2 = Camera._maxY
end

-- ! Clear Bounds
-- Clears the camera bounds
function Camera.clearBounds()
  Camera._bounds = nil
  Camera._hasBounds = false
  Camera._minX, Camera._minY = 0, 0
  Camera._maxX, Camera._maxY = 0, 0
  Camera._boundsCache = nil
end

-- ! Reset
-- Resets the camera to its default state
function Camera.reset()
  Camera.x                = 0
  Camera.y                = 0
  Camera._velocityX       = 0
  Camera._velocityY       = 0
  Camera._lastX           = 0
  Camera._lastY           = 0
  Camera._targetX         = 0
  Camera._targetY         = 0
  Camera.target           = nil
  Camera._bounds          = nil
  Camera._boundsCache     = nil
  Camera._hasBounds       = false
  Camera._minX            = 0
  Camera._minY            = 0
  Camera._maxX            = 0
  Camera._maxY            = 0
  Camera.smoothing        = 0
  Camera._shakeAmplitude  = 0
  Camera.shakeDuration    = 0
  Camera._shakeFrequency  = 0
  Camera._shakeTimer      = 0
  Camera._deadZoneWidth   = 0
  Camera._deadZoneHeight  = 0
  Camera.friction         = FRICTION_DEFAULT
  Camera._updateFunc      = Camera.updateStatic

  -- Immediate screen‑space reset
  setDrawOffset(0, 0)
  redrawBackground()

  Camera._isActive = true
end

-- ! Update
-- Dispatches to updateFollow, updateManualPan, or updateStatic based on camera mode
function Camera.update(dt)
  -- Only update if active, or if shake in progress
  if Camera._isActive or Camera.shakeDuration > 0 then
    Camera._updateFunc(dt)
  end
end

-- ! Update Follow
-- Update camera position following a target sprite
-- Clamps target position before interpolation to ensure smooth boundary stops, and final position for safety.
function Camera.updateFollow(dt)
  --#DEBUG START
  if not Camera.target or not Camera.target.getPosition then
    Log.error("[Camera.updateFollow] Target sprite is invalid or removed", 2)
  end
  --#DEBUG END

  local px, py = Camera.target:getPosition()

  --#DEBUG START
  if type(px) ~= "number" or type(py) ~= "number" then
    Log.error("[Camera.updateFollow] Invalid sprite position: expected numbers (x, y)")
  end
  --#DEBUG END

  -- Calculate desired target position
  local desiredX = px - CENTER_X
  local desiredY = py - CENTER_Y

  -- Apply dead zone
  if Camera._deadZoneWidth > 0 and Camera._deadZoneHeight > 0 then
    local dx = desiredX - Camera._targetX
    local dy = desiredY - Camera._targetY
    local halfW = Camera._deadZoneWidth / 2
    local halfH = Camera._deadZoneHeight / 2
    if abs(dx) > halfW then
      desiredX = desiredX - (dx - (dx > 0 and halfW or -halfW))
    else
      -- desiredX = Camera._targetX
    end
    if abs(dy) > halfH then
      desiredY = desiredY - (dy - (dy > 0 and halfH or -halfH))
    else
      -- desiredY = Camera._targetY
    end
  end

  Camera._targetX, Camera._targetY = desiredX, desiredY

  -- Clamp target position only if smoothing
  local hasSmoothing = Camera.smoothing > 0
  if Camera._hasBounds and hasSmoothing then
    Camera._targetX = clamp(Camera._targetX, Camera._minX, Camera._maxX)
    Camera._targetY = clamp(Camera._targetY, Camera._minY, Camera._maxY)
  end

  -- Interpolate or set position
  if hasSmoothing then
    local t = min(Camera.smoothing * dt, 1)
    Camera.x = lerp(Camera.x, Camera._targetX, t)
    Camera.y = lerp(Camera.y, Camera._targetY, t)

    -- Snap to nearest pixel
    Camera.x = round(Camera.x)
    Camera.y = round(Camera.y)
  else
    Camera.x, Camera.y = Camera._targetX, Camera._targetY
  end

  -- Clamp final position
  if Camera._hasBounds then
    Camera.x = clamp(Camera.x, Camera._minX, Camera._maxX)
    Camera.y = clamp(Camera.y, Camera._minY, Camera._maxY)

    -- Snap to nearest pixel
    Camera.x = round(Camera.x)
    Camera.y = round(Camera.y)
  end

  if Camera.smoothing > 0
    and abs(Camera.x - Camera._targetX) < 0.05
    and abs(Camera.y - Camera._targetY) < 0.05
    and abs(Camera._velocityX or 0) < 0.01
    and abs(Camera._velocityY or 0) < 0.01
  then
    Camera.x = round(Camera.x)
    Camera.y = round(Camera.y)
    Camera._targetX = Camera.x
    Camera._targetY = Camera.y
  end

  -- Apply shake and update draw offset
  _commitOffset(dt)
end

-- ! Update Manual Pan
-- Update camera position using pan velocity and friction
-- Clamps target position before interpolation (if smoothing enabled) to avoid boundary tug, and final position for safety.
function Camera.updateManualPan(dt)
  -- Apply velocity for panning
  Camera._targetX = Camera._targetX + Camera._velocityX * dt
  Camera._targetY = Camera._targetY + Camera._velocityY * dt

  -- Apply friction when no new input is given
  if Camera._velocityX == 0 and Camera._velocityY == 0 then
    Camera._targetX = lerp(Camera._targetX, Camera.x, 1 - Camera.friction)
    Camera._targetY = lerp(Camera._targetY, Camera.y, 1 - Camera.friction)
    -- (Uncomment below for snap if necessary)
    -- if abs(Camera._targetX - Camera.x) < 0.1 then Camera._targetX = Camera.x end
    -- if abs(Camera._targetY - Camera.y) < 0.1 then Camera._targetY = Camera.y end
  end

  -- Clamp target position only if smoothing
  local hasSmoothing = Camera.smoothing > 0
  if Camera._hasBounds and hasSmoothing then
    Camera._targetX = clamp(Camera._targetX, Camera._minX, Camera._maxX)
    Camera._targetY = clamp(Camera._targetY, Camera._minY, Camera._maxY)
  end

  -- Interpolate or set position
  if hasSmoothing then
    local t = min(Camera.smoothing * dt, 1)
    Camera.x = lerp(Camera.x, Camera._targetX, t)
    Camera.y = lerp(Camera.y, Camera._targetY, t)

    -- Snap to nearest pixel
    Camera.x = round(Camera.x)
    Camera.y = round(Camera.y)
  else
    Camera.x, Camera.y = Camera._targetX, Camera._targetY
  end

  -- Clamp final position
  if Camera._hasBounds then
    Camera.x = clamp(Camera.x, Camera._minX, Camera._maxX)
    Camera.y = clamp(Camera.y, Camera._minY, Camera._maxY)

    -- Snap to nearest pixel
    Camera.x = round(Camera.x)
    Camera.y = round(Camera.y)
  end

  -- Apply shake and update draw offset
  _commitOffset(dt)
end

-- ! Update Static
-- Update camera position when static
function Camera.updateStatic(dt)
  if not Camera._isActive then return end

  _commitOffset(dt)

  if not (Camera.shakeDuration > 0 or Camera._velocityX ~= 0
      or Camera._velocityY ~= 0 or Camera.target ~= nil) then
    Camera._isActive = false
  end
end

-- ----------------------------------------
-- Getters
-- ----------------------------------------

-- ! Get Offset
-- Returns the current camera position (x, y)
function Camera.getPosition()
  return Camera.x, Camera.y
end

-- ! Get Bounds
-- Returns the current bounds if set, or nil
function Camera.getBounds()
  if not Camera._hasBounds then return nil end

  -- Lazily allocate once, then just update fields
  if not Camera._boundsCache then
    Camera._boundsCache = { x1 = 0, y1 = 0, x2 = 0, y2 = 0 }
  end

  local cache = Camera._boundsCache
  cache.x1 = Camera._minX
  cache.y1 = Camera._minY
  cache.x2 = Camera._maxX
  cache.y2 = Camera._maxY
  return cache
end

-- ! Get Bound X1
function Camera.getBoundX1()
  return Camera._hasBounds and Camera._minX or nil
end

-- ! Get Bound X2
function Camera.getBoundX2()
  return Camera._hasBounds and Camera._maxX or nil
end

-- ! Get Bound Y1
function Camera.getBoundY1()
  return Camera._hasBounds and Camera._minY or nil
end

-- ! Get Bound Y2
function Camera.getBoundY2()
  return Camera._hasBounds and Camera._maxY or nil
end

-- ! Get Draw Offset
-- Returns the current draw offset (x, y) applied to the screen
function Camera.getDrawOffset()
  return -Camera._lastX, -Camera._lastY
end

-- ! World to Screen Converter
-- Converts world coordinates to screen coordinates, using the current camera offset
function Camera.worldToScreen(worldX, worldY)
  if worldX == nil or worldY == nil then
    Log.warn("worldToScreen received nil coordinate(s)") --#DEBUG
  end

  local screenX = worldX ~= nil and (worldX - Camera._lastX) or 0
  local screenY = worldY ~= nil and (worldY - Camera._lastY) or 0
  return screenX, screenY
end

-- ! Screen to World Converter
-- Converts screen coordinates to world coordinates, using the current camera offset
function Camera.screenToWorld(screenX, screenY)
  if screenX == nil or screenY == nil then
    Log.warn("screenToWorld received nil coordinate(s)") --#DEBUG
  end

  local worldX = screenX ~= nil and (screenX + Camera._lastX) or 0
  local worldY = screenY ~= nil and (screenY + Camera._lastY) or 0
  return worldX, worldY
end

-- ! Is On Screen
-- Returns true if the point (x, y) is within the current screen bounds
function Camera.isOnScreen(x, y)
  return x >= Camera._lastX
     and x <  Camera._lastX + DISPLAY_WIDTH
     and y >= Camera._lastY
     and y <  Camera._lastY + DISPLAY_HEIGHT
end

-- Default to static mode
Camera._updateFunc = Camera.updateStatic
