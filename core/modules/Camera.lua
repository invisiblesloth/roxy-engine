-- core/modules/Camera.lua

roxy = roxy or {}
roxy.Camera = roxy.Camera or {}
local Camera <const> = roxy.Camera

local pd        <const> = playdate
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

local tableRemove <const> = table.remove
local tableInsert <const> = table.insert

local setDrawOffset <const> = Graphics.setDrawOffset

local redrawBackground <const> = Sprite.redrawBackground

--
-- Constants
--

local CAMERA_SPEED_DEFAULT  <const> = 120   -- Default pan velocity (pixels per second)
local FRICTION_DEFAULT      <const> = 0.85  -- Default friction factor (0 to 1, higher = slower stop)

local DISPLAY_WIDTH   <const> = roxy.Graphics.displayWidth
local DISPLAY_HEIGHT  <const> = roxy.Graphics.displayHeight
local CENTER_X        <const> = roxy.Graphics.displayWidthCenter
local CENTER_Y        <const> = roxy.Graphics.displayHeightCenter

--
-- Public Variables (externally visible state)
--

Camera.x              = 0   -- Current x position
Camera.y              = 0   -- Current y position
Camera.target         = nil -- Sprite to follow
Camera.smoothing      = 0   -- Smoothing rate in 1/seconds (0 = instant)
Camera.shakeDuration  = 0   -- Remaining shake time (seconds)
Camera.friction       = FRICTION_DEFAULT

-- Public feel knobs
Camera.targetBiasX    = 0       -- Extra pixels from center (screen space), x
Camera.targetBiasY    = 0       -- Extra pixels from center (screen space), y
Camera.biasReturnRate = 6       -- How fast bias returns to 0 (1/sec)
Camera.mode           = "lerp"  -- "lerp" or "spring"

-- Spring parameters (used when mode=="spring")
Camera.springFreq = 6.0 -- Hz, natural frequency
Camera.springDamp = 0.9 -- 0..1 (1=critical-ish)

--
-- Private Variables (internal module state; underscore-reserved)
--

Camera._velocityX         = 0     -- Velocity in x direction
Camera._velocityY         = 0     -- Velocity in y direction
Camera._lastX             = 0     -- Last x position for dirty rect
Camera._lastY             = 0     -- Last y position for dirty rect
Camera._screenLeft        = 0     -- Cached screen left boundary
Camera._screenTop         = 0     -- Cached screen top boundary
Camera._screenRight       = DISPLAY_WIDTH   -- Cached screen right boundary
Camera._screenBottom      = DISPLAY_HEIGHT  -- Cached screen bottom boundary
Camera._targetX           = 0     -- Target x position
Camera._targetY           = 0     -- Target y position
Camera._bounds            = nil   -- { x1, y1, x2, y2 }
Camera._hasBounds         = false -- Whether bounds are active
Camera._minX              = 0     -- Minimum x bound
Camera._minY              = 0     -- Minimum y bound
Camera._maxX              = 0     -- Maximum x bound
Camera._maxY              = 0     -- Maximum y bound
Camera._shakeAmplitude    = 0     -- Shake intensity (pixels)
Camera._shakeFrequency    = 0     -- Shake oscillations per second
Camera._shakeAngularFreq  = 0     -- Cached angular frequency (frequency * 2π)
Camera._shakeTimer        = 0     -- Tracks elapsed shake time
Camera._deadZoneWidth     = 0     -- Dead zone width (pixels, 0 = disabled)
Camera._deadZoneHeight    = 0     -- Dead zone height (pixels, 0 = disabled)
Camera._deadZoneHalfW     = 0     -- Cached half width for performance
Camera._deadZoneHalfH     = 0     -- Cached half height for performance
Camera._isActive          = true  -- Ensure initial update
Camera._updateFunc        = nil   -- Default to static mode (set after functions defined)

-- Parallax listeners
Camera._onOffsetChanged = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Apply Shake
-- Advances the internal shake timer and returns rounded shake offsets (x, y)
-- Note: dt only advances time; the offset calculation uses the accumulated timer
local function _applyShake(dt)
  if Camera.shakeDuration <= 0 then return 0, 0 end
  Camera._shakeTimer += dt
  if Camera._shakeTimer >= Camera.shakeDuration then
    Camera.shakeDuration = 0
    Camera._shakeAmplitude = 0
    Camera._shakeTimer = 0
    return 0, 0
  end
  local timer = Camera._shakeTimer * Camera._shakeAngularFreq
  local amplitude = Camera._shakeAmplitude * (1 - Camera._shakeTimer / Camera.shakeDuration)
  return round(amplitude * sin(timer)), round(amplitude * cos(timer))
end

-- ! Commit Offset
-- Rounds the camera position, applies shake, commits draw offset, updates screen bounds
-- invalidates conversion caches when the offset changes, and maintains _isActive
local function _commitOffset(dt)
  local newX = round(Camera.x)
  local newY = round(Camera.y)
  local shakeX, shakeY = (Camera.shakeDuration > 0) and _applyShake(dt) or 0, 0
  local totalOffsetX = newX + shakeX
  local totalOffsetY = newY + shakeY
  local lastX, lastY = Camera._lastX, Camera._lastY
  if abs(totalOffsetX - lastX) >= 1 or abs(totalOffsetY - lastY) >= 1 then
    setDrawOffset(-totalOffsetX, -totalOffsetY)
    redrawBackground()
    Camera._lastX = totalOffsetX
    Camera._lastY = totalOffsetY
    Camera._screenLeft = totalOffsetX
    Camera._screenTop = totalOffsetY
    Camera._screenRight = totalOffsetX + DISPLAY_WIDTH
    Camera._screenBottom = totalOffsetY + DISPLAY_HEIGHT
    Camera._isActive = true
    for i=1,#Camera._onOffsetChanged do
      Camera._onOffsetChanged[i](totalOffsetX, totalOffsetY)
    end
  else
    Camera._isActive = Camera.shakeDuration > 0 or Camera._velocityX ~= 0 or Camera._velocityY ~= 0 or Camera.target ~= nil
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Set Position
-- Sets the camera position to (x, y) instantly
function Camera.setPosition(x, y)
  --#DEBUG START
  if type(x) ~= "number" or type(y) ~= "number" then
    Log.error("[Camera.setPosition] Invalid position: expected numbers (x, y)", 2)
  end
  --#DEBUG END

  Camera.x = x
  Camera.y = y
  Camera._targetX = x
  Camera._targetY = y
  Camera._velocityX = 0
  Camera._velocityY = 0
  Camera._updateFunc = Camera.updateStatic
  Camera._isActive = true
end

-- ! Set Pan Velocity
-- Sets pan velocity (pixels/second). If vx is nil, uses CAMERA_SPEED_DEFAULT (120).
-- If vy is nil, uses vx. Set vx=0, vy=0 to stop panning
function Camera.setPanVelocity(vx, vy)
  --#DEBUG START
  if vx ~= nil and type(vx) ~= "number" then
    Log.error("[Camera.setPanVelocity] Invalid vx: expected a number or nil", 2)
  end
  --#DEBUG END

  -- Apply defaults
  vx = vx or CAMERA_SPEED_DEFAULT
  vy = vy or vx

  --#DEBUG START
  if type(vy) ~= "number" then
    Log.error("[Camera.setPanVelocity] Invalid vy: expected a number or nil", 2)
  end
  --#DEBUG END

  Camera._velocityX = vx
  Camera._velocityY = vy
  Camera._updateFunc = Camera.updateManualPan
  Camera._isActive = true
end

-- ! Set Target
-- Follows a sprite (or nil to stop)
-- Optional smoothing rate controls interpolation speed:
--   0 = Snap instantly to target each frame
--  >0 = Rate in "per second" at which camera moves toward target (t = min(rate * dt, 1))
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

  -- Default to static when no target
  Camera._updateFunc = sprite and Camera.updateFollow or Camera.updateStatic
  Camera._isActive = true
end

-- ! Set Smoothing
-- Sets the global smoothing rate for interpolation (1/seconds)
function Camera.setSmoothing(rate)
  --#DEBUG START
  if type(rate) ~= "number" then
    Log.error("[Camera.setSmoothing] Invalid smoothing rate: expected a number", 2)
  end
  --#DEBUG END
  Camera.smoothing = max(rate, 0)
end

-- ! Shake
-- Triggers a camera shake with amplitude (pixels), duration (seconds), and frequency (oscillations per second)
function Camera.shake(amplitude, duration, frequency)
  --#DEBUG START
  if type(amplitude) ~= "number" or type(duration) ~= "number" or type(frequency) ~= "number" then
    Log.error("[Camera.shake] Invalid shake parameters: expected numbers (amplitude, duration, frequency)", 2)
  end
  --#DEBUG END

  Camera._shakeAmplitude = max(amplitude, 0)
  Camera.shakeDuration = max(duration, 0)
  Camera._shakeFrequency = max(frequency, 0)
  Camera._shakeAngularFreq = Camera._shakeFrequency * 2 * pi
  Camera._shakeTimer = 0
  Camera._isActive = true
end

-- ! Set Dead Zone
-- Sets a dead zone rectangle (width, height in pixels). Use 0,0 to disable.
function Camera.setDeadZone(width, height)
  --#DEBUG START
  if type(width) ~= "number" or type(height) ~= "number" then
    Log.error("[Camera.setDeadZone] Invalid dead zone: expected numbers (width, height)", 2)
  end
  --#DEBUG END

  Camera._deadZoneWidth = max(width, 0)
  Camera._deadZoneHeight = max(height, 0)
  Camera._deadZoneHalfW = Camera._deadZoneWidth / 2
  Camera._deadZoneHalfH = Camera._deadZoneHeight / 2
end

-- ! Set Friction
-- Sets the default friction factor (0–1) applied when no pan input is active
function Camera.setFriction(friction)
  --#DEBUG START
  if type(friction) ~= "number" then
    Log.error("[Camera.setFriction] Invalid friction: expected a number", 2)
  end
  --#DEBUG END
  Camera.friction = clamp(friction, 0, 1)
end

-- ! Set Bounds
-- Clamps the camera to a rectangle {x1, y1, x2, y2}
function Camera.setBounds(bounds)
  if not bounds or type(bounds.x1) ~= "number" or type(bounds.y1) ~= "number" or type(bounds.x2) ~= "number" or type(bounds.y2) ~= "number" then
    Log.error("[Camera.setBounds] Invalid bounds: expected {x1, y1, x2, y2} with numbers", 2) --#DEBUG
    Camera._bounds = nil
    Camera._hasBounds = false
    Camera._minX, Camera._minY = 0, 0
    Camera._maxX, Camera._maxY = 0, 0
    return
  end

  Camera._bounds = bounds
  Camera._hasBounds = true
  Camera._minX = min(bounds.x1, bounds.x2)
  Camera._maxX = max(bounds.x1, bounds.x2)
  Camera._minY = min(bounds.y1, bounds.y2)
  Camera._maxY = max(bounds.y1, bounds.y2)
end

-- ! Clear Bounds
-- Clears the camera bounds
function Camera.clearBounds()
  Camera._bounds = nil
  Camera._hasBounds = false
  Camera._minX = 0
  Camera._minY = 0
  Camera._maxX = 0
  Camera._maxY = 0
end

-- ! Reset
-- Resets the camera to its default state
function Camera.reset()
  Camera.x                  = 0
  Camera.y                  = 0
  Camera._velocityX         = 0
  Camera._velocityY         = 0
  Camera._lastX             = 0
  Camera._lastY             = 0
  Camera._screenLeft        = 0
  Camera._screenTop         = 0
  Camera._screenRight       = DISPLAY_WIDTH
  Camera._screenBottom      = DISPLAY_HEIGHT
  Camera._targetX           = 0
  Camera._targetY           = 0
  Camera.target             = nil
  Camera._bounds            = nil
  Camera._hasBounds         = false
  Camera._minX              = 0
  Camera._minY              = 0
  Camera._maxX              = 0
  Camera._maxY              = 0
  Camera.smoothing          = 0
  Camera._shakeAmplitude    = 0
  Camera.shakeDuration      = 0
  Camera._shakeFrequency    = 0
  Camera._shakeAngularFreq  = 0
  Camera._shakeTimer        = 0
  Camera._deadZoneWidth     = 0
  Camera._deadZoneHeight    = 0
  Camera._deadZoneHalfW     = 0
  Camera._deadZoneHalfH     = 0
  Camera.friction           = FRICTION_DEFAULT
  Camera._updateFunc        = Camera.updateStatic

  -- Reset feel controls
  Camera.targetBiasX        = 0
  Camera.targetBiasY        = 0
  Camera.biasReturnRate     = 6
  Camera.mode               = "lerp"
  Camera.springFreq         = 6.0
  Camera.springDamp         = 0.9
  Camera._onOffsetChanged   = {}

  -- Immediate screen‑space reset
  setDrawOffset(0, 0)
  redrawBackground()

  Camera._isActive = true
end

-- ! Set Bias
function Camera.setBias(x, y)
  Camera.targetBiasX, Camera.targetBiasY = x or 0, y or 0
end

-- ! Add Offset Listener
function Camera.addOffsetListener(fn)  -- fn(totalOffsetX, totalOffsetY)
  if type(fn) == "function" then table.insert(Camera._onOffsetChanged, fn) end
end

-- ! Clear Offset Listeners
function Camera.clearOffsetListeners()
  Camera._onOffsetChanged = {}
end

-- ! Set Mode
function Camera.setMode(mode) -- "lerp" or "spring"
  if mode == "spring" or mode == "lerp" then Camera.mode = mode end
end

-- ! Update
-- Dispatches to updateFollow, updateManualPan, or updateStatic based on camera mode
function Camera.update(dt)
  Camera._isActive = Camera._isActive or Camera.shakeDuration > 0 or Camera._velocityX ~= 0 or Camera._velocityY ~= 0 or Camera.target ~= nil
  if Camera._isActive then
    Camera._updateFunc(dt)
  end
end

--------------------------------------------------------------------------------
-- Update Modes
--------------------------------------------------------------------------------

-- ! Update Follow
-- Follows a target sprite; applies dead zone and optional smoothing; clamps to bounds
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

  -- Calculate desired target position (world top-left for screen center)
  local desiredX = (px - CENTER_X) + Camera.targetBiasX
  local desiredY = (py - CENTER_Y) + Camera.targetBiasY

  -- Apply dead zone
  if Camera._deadZoneWidth > 0 and Camera._deadZoneHeight > 0 then
    local dx = desiredX - Camera._targetX
    local dy = desiredY - Camera._targetY
    if abs(dx) > Camera._deadZoneHalfW then
      desiredX = Camera._targetX + (dx > 0 and Camera._deadZoneHalfW or -Camera._deadZoneHalfW)
    else
      desiredX = Camera._targetX
    end
    if abs(dy) > Camera._deadZoneHalfH then
      desiredY = Camera._targetY + (dy > 0 and Camera._deadZoneHalfH or -Camera._deadZoneHalfH)
    else
      desiredY = Camera._targetY
    end
  end
  Camera._targetX = desiredX
  Camera._targetY = desiredY

  -- Clamp target position only if smoothing
  local hasSmoothing = Camera.smoothing > 0
  if Camera._hasBounds and hasSmoothing then
    Camera._targetX = clamp(Camera._targetX, Camera._minX, Camera._maxX)
    Camera._targetY = clamp(Camera._targetY, Camera._minY, Camera._maxY)
  end

  -- Interpolate or set position
  if Camera.mode == "spring" then
    -- critically damped spring (Tustin-ish simple integrator)
    -- convert freq,damp to params
    local omega = 2 * pi * Camera.springFreq
    local zeta  = Camera.springDamp
    -- velocity form
    local ax = omega * omega * (desiredX - Camera.x) - 2 * zeta * omega * Camera._velocityX
    local ay = omega * omega * (desiredY - Camera.y) - 2 * zeta * omega * Camera._velocityY
    Camera._velocityX = Camera._velocityX + ax * dt
    Camera._velocityY = Camera._velocityY + ay * dt
    Camera.x = Camera.x + Camera._velocityX * dt
    Camera.y = Camera.y + Camera._velocityY * dt
  else
    if hasSmoothing then
      local t = min(Camera.smoothing * dt, 1)
      Camera.x = lerp(Camera.x, Camera._targetX, t)
      Camera.y = lerp(Camera.y, Camera._targetY, t)
    else
      Camera.x = Camera._targetX
      Camera.y = Camera._targetY
    end
  end

  -- Clamp final position
  if Camera._hasBounds then
    Camera.x = clamp(Camera.x, Camera._minX, Camera._maxX)
    Camera.y = clamp(Camera.y, Camera._minY, Camera._maxY)
  end

  if Camera.smoothing > 0
    and abs(Camera.x - Camera._targetX) < 0.05
    and abs(Camera.y - Camera._targetY) < 0.05
  then
    Camera._targetX = Camera.x
    Camera._targetY = Camera.y
  end

  _commitOffset(dt)
end

-- ! Update Manual Pan
-- Integrates pan velocity with optional smoothing; applies friction when idle; clamps to bounds
function Camera.updateManualPan(dt)
  -- Apply velocity for panning
  Camera._targetX += Camera._velocityX * dt
  Camera._targetY += Camera._velocityY * dt

  -- Apply friction to velocity if no new input
  local hasInput = Camera._velocityX ~= 0 or Camera._velocityY ~= 0
  if not hasInput then
    Camera._velocityX *= Camera.friction
    Camera._velocityY *= Camera.friction
    if abs(Camera._velocityX) < 0.01 then Camera._velocityX = 0 end
    if abs(Camera._velocityY) < 0.01 then Camera._velocityY = 0 end
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
  else
    Camera.x = Camera._targetX
    Camera.y = Camera._targetY
  end

  -- Clamp final position
  if Camera._hasBounds then
    Camera.x = clamp(Camera.x, Camera._minX, Camera._maxX)
    Camera.y = clamp(Camera.y, Camera._minY, Camera._maxY)
  end

  _commitOffset(dt)
end

-- ! Update Static
-- Holds current draw offset active while shaking or until activity stops
function Camera.updateStatic(dt)
  if not Camera._isActive then return end

  _commitOffset(dt)

  if not (Camera.shakeDuration > 0 or Camera._velocityX ~= 0 or Camera._velocityY ~= 0 or Camera.target ~= nil) then
    Camera._isActive = false
  end
end

--------------------------------------------------------------------------------
-- Getters
--------------------------------------------------------------------------------

-- ! Get Position
-- Returns the current camera position (x, y)
function Camera.getPosition()
  return Camera.x, Camera.y
end

-- ! Get Bounds
-- Returns the current bounds table if set, or nil
function Camera.getBounds()
  if not Camera._hasBounds then return nil end
  return {
    x1 = Camera._minX,
    y1 = Camera._minY,
    x2 = Camera._maxX,
    y2 = Camera._maxY
  }
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

--------------------------------------------------------------------------------
-- Converters
--------------------------------------------------------------------------------

-- ! World to Screen Converter
-- Converts world coordinates to screen coordinates, using the current camera offset
function Camera.worldToScreen(worldX, worldY)
  --#DEBUG START
  if worldX == nil or worldY == nil then
    Log.warn("worldToScreen received nil coordinate(s)")
  end
  --#DEBUG END

  worldX = worldX or 0
  worldY = worldY or 0
  return worldX - Camera._lastX, worldY - Camera._lastY
end

-- ! Screen to World Converter
-- Converts screen coordinates to world coordinates, using the current camera offset
function Camera.screenToWorld(screenX, screenY)
  --#DEBUG START
  if screenX == nil or screenY == nil then
    Log.warn("screenToWorld received nil coordinate(s)")
  end
  --#DEBUG END

  screenX = screenX or 0
  screenY = screenY or 0
  return screenX + Camera._lastX, screenY + Camera._lastY
end

--------------------------------------------------------------------------------
-- Visibility
--------------------------------------------------------------------------------

-- ! Is On Screen
-- Returns true if the point (x, y) is within the current screen bounds
function Camera.isOnScreen(x, y)
  local left    = Camera._screenLeft
  local right   = Camera._screenRight
  local top     = Camera._screenTop
  local bottom  = Camera._screenBottom
  return x >= left and x < right and y >= top and y < bottom
end

-- Default to static mode
Camera._updateFunc = Camera.updateStatic
