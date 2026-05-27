-- core/modules/Camera.lua

roxy = roxy or {}
roxy.Camera = roxy.Camera or {}
local Camera <const> = roxy.Camera

local pd        <const> = playdate
local Graphics  <const> = pd.graphics
local Sprite    <const> = Graphics.sprite
local Timer     <const> = pd.timer

local r             <const> = roxy
local RoxyGraphics  <const> = r.Graphics
local Math          <const> = r.Math

local abs <const> = math.abs
local min <const> = math.min
local max <const> = math.max
local sin <const> = math.sin
local cos <const> = math.cos
local pi  <const> = math.pi

local performAfterDelay <const> = Timer.performAfterDelay
local setDrawOffset     <const> = Graphics.setDrawOffset
local redrawBackground  <const> = Sprite.redrawBackground
local clamp             <const> = Math.clamp
local lerp              <const> = Math.lerp
local round             <const> = Math.roundInt

local DISPLAY_WIDTH   <const> = RoxyGraphics.displayWidth
local DISPLAY_HEIGHT  <const> = RoxyGraphics.displayHeight
local CENTER_X        <const> = RoxyGraphics.displayWidthCenter
local CENTER_Y        <const> = RoxyGraphics.displayHeightCenter

local CAMERA_SPEED_DEFAULT  <const> = 120   -- Default pan velocity (pixels per second)
local FRICTION_DEFAULT      <const> = 0.85  -- Default friction factor (0 to 1, higher = slower stop)

--------------------------------------------------------------------------------
-- Public Variables (externally visible state)
--------------------------------------------------------------------------------

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
Camera.springFreq = 4.0 -- Hz, natural frequency
Camera.springDamp = 0.9 -- 0..1 (1=critical-ish)

--------------------------------------------------------------------------------
-- Private Variables (internal module state)
--------------------------------------------------------------------------------

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
Camera._logicalBounds     = nil   -- { x1, y1, x2, y2 } - developer-set bounds (before bias expansion)
Camera._hasBounds         = false -- Whether bounds are active
Camera._minX              = 0     -- Minimum effective x bound
Camera._minY              = 0     -- Minimum effective y bound
Camera._maxX              = 0     -- Maximum effective x bound
Camera._maxY              = 0     -- Maximum effective y bound
Camera._shakeAmplitude    = 0     -- Shake intensity (pixels)
Camera._shakeFrequency    = 0     -- Shake oscillations per second
Camera._shakeAngularFreq  = 0     -- Cached angular frequency (frequency * 2 * pi)
Camera._shakeTimer        = 0     -- Tracks elapsed shake time
Camera._shakeOffsetX      = 0     -- Last committed shake x offset
Camera._shakeOffsetY      = 0     -- Last committed shake y offset
Camera._deadZoneWidth     = 0     -- Dead zone width (pixels, 0 = disabled)
Camera._deadZoneHeight    = 0     -- Dead zone height (pixels, 0 = disabled)
Camera._deadZoneHalfW     = 0     -- Cached half width for performance
Camera._deadZoneHalfH     = 0     -- Cached half height for performance
Camera._isActive          = true  -- Ensure initial update
Camera._updateFunc        = nil   -- Default to static mode (set after functions defined)
Camera._followIdleValid   = false -- Whether the follow fast-path cache can be used

-- Parallax listeners
Camera._onOffsetChanged = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Invalidate Follow Idle
-- Clears the cached no-op follow state used by the idle fast path
local function _invalidateFollowIdle()
  Camera._followIdleValid = false
  Camera._followIdleTarget = nil
end

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
-- Invalidates conversion caches when the offset changes, and maintains _isActive
local function _commitOffset(dt)
  local newX = round(Camera.x)
  local newY = round(Camera.y)
  local shakeX, shakeY = 0, 0
  if Camera.shakeDuration > 0 then
    shakeX, shakeY = _applyShake(dt)
  end
  Camera._shakeOffsetX = shakeX
  Camera._shakeOffsetY = shakeY
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
    for i = 1, #Camera._onOffsetChanged do
      Camera._onOffsetChanged[i](totalOffsetX, totalOffsetY)
    end
  else
    Camera._isActive = Camera.shakeDuration > 0 or Camera._velocityX ~= 0 or Camera._velocityY ~= 0 or Camera.target ~= nil
  end
end

-- ! Is Follow Offset Committed
-- Returns true when the draw-offset cache already reflects the raw camera position
local function _isFollowOffsetCommitted()
  local lastX, lastY = Camera._lastX, Camera._lastY
  return round(Camera.x) == lastX
    and round(Camera.y) == lastY
    and Camera._screenLeft == lastX
    and Camera._screenTop == lastY
    and Camera._screenRight == lastX + DISPLAY_WIDTH
    and Camera._screenBottom == lastY + DISPLAY_HEIGHT
end

-- ! Recalculate Effective Bounds
-- Expands logical bounds by bias amount so camera can apply bias without hitting bounds
local function _recalculateEffectiveBounds()
  if not Camera._logicalBounds then
    Camera._hasBounds = false
    Camera._minX = 0
    Camera._minY = 0
    Camera._maxX = 0
    Camera._maxY = 0
    return
  end

  local bounds = Camera._logicalBounds

  -- Shift bounds by bias to maintain symmetric movement range
  local x1 = bounds.x1 + Camera.targetBiasX
  local y1 = bounds.y1 + Camera.targetBiasY
  local x2 = bounds.x2 + Camera.targetBiasX
  local y2 = bounds.y2 + Camera.targetBiasY

  -- Update cached min/max for clamping
  Camera._minX = min(x1, x2)
  Camera._maxX = max(x1, x2)
  Camera._minY = min(y1, y2)
  Camera._maxY = max(y1, y2)
  Camera._hasBounds = true
end

-- ! Copy Bounds
-- Copies a camera bounds table without keeping caller-owned table identity
local function _copyBounds(bounds)
  if not bounds then return nil end
  return {
    x1 = bounds.x1,
    y1 = bounds.y1,
    x2 = bounds.x2,
    y2 = bounds.y2,
  }
end

-- ! Copy List
-- Copies an array-style listener list while preserving listener references
local function _copyList(list)
  local copy = {}
  if type(list) ~= "table" then return copy end
  for i = 1, #list do
    copy[i] = list[i]
  end
  return copy
end

-- ! Validate Target
-- Keeps restored snapshots from following an object that lost getPosition
local function _validateTarget(target)
  if target == nil then return nil end
  if type(target.getPosition) == "function" then return target end
  return nil
end

-- ! Resolve Follow Target
-- Calculates the desired follow point and the clamped interpolation target
local function _resolveFollowTarget(px, py)
  local desiredX = (px - CENTER_X) + Camera.targetBiasX
  local desiredY = (py - CENTER_Y) + Camera.targetBiasY

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

  local targetX = desiredX
  local targetY = desiredY
  local hasSmoothing = Camera.smoothing > 0
  if Camera._hasBounds and hasSmoothing then
    targetX = clamp(targetX, Camera._minX, Camera._maxX)
    targetY = clamp(targetY, Camera._minY, Camera._maxY)
  end

  return desiredX, desiredY, targetX, targetY, hasSmoothing
end

-- ! Can Skip Follow
-- Returns true when an identical follow update would be a complete no-op
local function _canSkipFollow(px, py, dt)
  return Camera._followIdleValid
    and type(dt) == "number"
    and Camera.target == Camera._followIdleTarget
    and px == Camera._followIdlePX
    and py == Camera._followIdlePY
    and Camera.x == Camera._followIdleX
    and Camera.y == Camera._followIdleY
    and Camera._targetX == Camera._followIdleTargetX
    and Camera._targetY == Camera._followIdleTargetY
    and Camera._velocityX == 0
    and Camera._velocityY == 0
    and Camera._velocityX == Camera._followIdleVelocityX
    and Camera._velocityY == Camera._followIdleVelocityY
    and Camera._lastX == Camera._followIdleLastX
    and Camera._lastY == Camera._followIdleLastY
    and Camera._screenLeft == Camera._followIdleScreenLeft
    and Camera._screenTop == Camera._followIdleScreenTop
    and Camera._screenRight == Camera._followIdleScreenRight
    and Camera._screenBottom == Camera._followIdleScreenBottom
    and Camera._isActive == Camera._followIdleIsActive
    and Camera.smoothing == Camera._followIdleSmoothing
    and Camera.mode == Camera._followIdleMode
    and Camera.springFreq == Camera._followIdleSpringFreq
    and Camera.springDamp == Camera._followIdleSpringDamp
    and Camera.targetBiasX == Camera._followIdleTargetBiasX
    and Camera.targetBiasY == Camera._followIdleTargetBiasY
    and Camera._deadZoneWidth == Camera._followIdleDeadZoneWidth
    and Camera._deadZoneHeight == Camera._followIdleDeadZoneHeight
    and Camera._deadZoneHalfW == Camera._followIdleDeadZoneHalfW
    and Camera._deadZoneHalfH == Camera._followIdleDeadZoneHalfH
    and Camera._hasBounds == Camera._followIdleHasBounds
    and Camera._minX == Camera._followIdleMinX
    and Camera._minY == Camera._followIdleMinY
    and Camera._maxX == Camera._followIdleMaxX
    and Camera._maxY == Camera._followIdleMaxY
    and Camera._shakeAmplitude == Camera._followIdleShakeAmplitude
    and Camera.shakeDuration == Camera._followIdleShakeDuration
    and Camera._shakeFrequency == Camera._followIdleShakeFrequency
    and Camera._shakeAngularFreq == Camera._followIdleShakeAngularFreq
    and Camera._shakeTimer == Camera._followIdleShakeTimer
    and Camera.shakeDuration <= 0
    and Camera.x == Camera._targetX
    and Camera.y == Camera._targetY
    and _isFollowOffsetCommitted()
end

-- ! Is Follow Idle Stable
-- Verifies that a repeated full follow update would leave all follow state unchanged
local function _isFollowIdleStable(px, py)
  if Camera.shakeDuration > 0
    or Camera._velocityX ~= 0
    or Camera._velocityY ~= 0
    or Camera.x ~= Camera._targetX
    or Camera.y ~= Camera._targetY
    or not _isFollowOffsetCommitted()
  then
    return false
  end

  if Camera._hasBounds
    and (Camera.x < Camera._minX or Camera.x > Camera._maxX
      or Camera.y < Camera._minY or Camera.y > Camera._maxY)
  then
    return false
  end

  local _, _, targetX, targetY = _resolveFollowTarget(px, py)
  return targetX == Camera._targetX
    and targetY == Camera._targetY
end

-- ! Remember Follow Idle
-- Captures the current settled follow state for the next identical frame
local function _rememberFollowIdle(px, py)
  if not _isFollowIdleStable(px, py) then
    _invalidateFollowIdle()
    return
  end

  Camera._followIdleValid = true
  Camera._followIdleTarget = Camera.target
  Camera._followIdlePX = px
  Camera._followIdlePY = py
  Camera._followIdleX = Camera.x
  Camera._followIdleY = Camera.y
  Camera._followIdleTargetX = Camera._targetX
  Camera._followIdleTargetY = Camera._targetY
  Camera._followIdleVelocityX = Camera._velocityX
  Camera._followIdleVelocityY = Camera._velocityY
  Camera._followIdleLastX = Camera._lastX
  Camera._followIdleLastY = Camera._lastY
  Camera._followIdleScreenLeft = Camera._screenLeft
  Camera._followIdleScreenTop = Camera._screenTop
  Camera._followIdleScreenRight = Camera._screenRight
  Camera._followIdleScreenBottom = Camera._screenBottom
  Camera._followIdleIsActive = Camera._isActive
  Camera._followIdleSmoothing = Camera.smoothing
  Camera._followIdleMode = Camera.mode
  Camera._followIdleSpringFreq = Camera.springFreq
  Camera._followIdleSpringDamp = Camera.springDamp
  Camera._followIdleTargetBiasX = Camera.targetBiasX
  Camera._followIdleTargetBiasY = Camera.targetBiasY
  Camera._followIdleDeadZoneWidth = Camera._deadZoneWidth
  Camera._followIdleDeadZoneHeight = Camera._deadZoneHeight
  Camera._followIdleDeadZoneHalfW = Camera._deadZoneHalfW
  Camera._followIdleDeadZoneHalfH = Camera._deadZoneHalfH
  Camera._followIdleHasBounds = Camera._hasBounds
  Camera._followIdleMinX = Camera._minX
  Camera._followIdleMinY = Camera._minY
  Camera._followIdleMaxX = Camera._maxX
  Camera._followIdleMaxY = Camera._maxY
  Camera._followIdleShakeAmplitude = Camera._shakeAmplitude
  Camera._followIdleShakeDuration = Camera.shakeDuration
  Camera._followIdleShakeFrequency = Camera._shakeFrequency
  Camera._followIdleShakeAngularFreq = Camera._shakeAngularFreq
  Camera._followIdleShakeTimer = Camera._shakeTimer
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Set Position
-- Sets the camera position to (x, y) instantly
function Camera.setPosition(x, y)
  --#DEBUG START
  if type(x) ~= "number" or type(y) ~= "number" then
    error("[Camera.setPosition] Invalid position: expected numbers (x, y)", 2)
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
  _invalidateFollowIdle()
end

-- ! Set Pan Velocity
-- Sets pan velocity (pixels/second). If vx is nil, uses CAMERA_SPEED_DEFAULT (120).
-- If vy is nil, uses vx. Set vx=0, vy=0 to stop panning
function Camera.setPanVelocity(vx, vy)
  --#DEBUG START
  if vx ~= nil and type(vx) ~= "number" then
    error("[Camera.setPanVelocity] Invalid vx: expected a number or nil", 2)
  end
  --#DEBUG END

  -- Apply defaults
  vx = vx or CAMERA_SPEED_DEFAULT
  vy = vy or vx

  --#DEBUG START
  if type(vy) ~= "number" then
    error("[Camera.setPanVelocity] Invalid vy: expected a number or nil", 2)
  end
  --#DEBUG END

  Camera._velocityX = vx
  Camera._velocityY = vy
  Camera._updateFunc = Camera.updateManualPan
  Camera._isActive = true
  _invalidateFollowIdle()
end

-- ! Set Target
-- Follows a sprite (or nil to stop)
-- Optional smoothing rate controls interpolation speed:
--   0 = Snap instantly to target each frame
--  >0 = Rate in "per second" at which camera moves toward target (t = min(rate * dt, 1))
function Camera.setTarget(sprite, smoothing)
  --#DEBUG START
  if sprite and not sprite.getPosition then
    error("[Camera.setTarget] Invalid sprite: expected a sprite with getPosition method", 2)
  end
  --#DEBUG END

  Camera.target = sprite
  if smoothing ~= nil then
    Camera.smoothing = max(smoothing, 0)
  end

  -- Default to static when no target
  Camera._updateFunc = sprite and Camera.updateFollow or Camera.updateStatic
  Camera._isActive = true
  _invalidateFollowIdle()
end

-- ! Set Smoothing
-- Sets the global smoothing rate for interpolation (1/seconds)
function Camera.setSmoothing(rate)
  --#DEBUG START
  if type(rate) ~= "number" then
    error("[Camera.setSmoothing] Invalid smoothing rate: expected a number", 2)
  end
  --#DEBUG END
  Camera.smoothing = max(rate, 0)
  _invalidateFollowIdle()
end

-- ! Shake
-- Triggers a camera shake with amplitude (pixels), duration (seconds), and frequency (oscillations per second)
function Camera.shake(amplitude, duration, frequency)
  --#DEBUG START
  if type(amplitude) ~= "number" or type(duration) ~= "number" or type(frequency) ~= "number" then
    error("[Camera.shake] Invalid shake parameters: expected numbers (amplitude, duration, frequency)", 2)
  end
  --#DEBUG END

  Camera._shakeAmplitude = max(amplitude, 0)
  Camera.shakeDuration = max(duration, 0)
  Camera._shakeFrequency = max(frequency, 0)
  Camera._shakeAngularFreq = Camera._shakeFrequency * 2 * pi
  Camera._shakeTimer = 0
  Camera._isActive = true
  _invalidateFollowIdle()
end

-- ! Set Dead Zone
-- Sets a dead zone rectangle (width, height in pixels). Use 0,0 to disable.
function Camera.setDeadZone(width, height)
  --#DEBUG START
  if type(width) ~= "number" or type(height) ~= "number" then
    error("[Camera.setDeadZone] Invalid dead zone: expected numbers (width, height)", 2)
  end
  --#DEBUG END

  Camera._deadZoneWidth = max(width, 0)
  Camera._deadZoneHeight = max(height, 0)
  Camera._deadZoneHalfW = Camera._deadZoneWidth / 2
  Camera._deadZoneHalfH = Camera._deadZoneHeight / 2
  _invalidateFollowIdle()
end

-- ! Set Friction
-- Sets the default friction factor (0-1) applied when no pan input is active
function Camera.setFriction(friction)
  --#DEBUG START
  if type(friction) ~= "number" then
    error("[Camera.setFriction] Invalid friction: expected a number", 2)
  end
  --#DEBUG END
  Camera.friction = clamp(friction, 0, 1)
end

-- ! Set Bounds
-- Clamps the camera to a rectangle {x1, y1, x2, y2}
-- Bounds are automatically expanded by camera bias to prevent conflicts
function Camera.setBounds(bounds)
  if not bounds or type(bounds.x1) ~= "number" or type(bounds.y1) ~= "number" or type(bounds.x2) ~= "number" or type(bounds.y2) ~= "number" then
    error("[Camera.setBounds] Invalid bounds: expected {x1, y1, x2, y2} with numbers", 2) --#DEBUG
    Camera._logicalBounds = nil
    Camera._hasBounds = false
    Camera._minX, Camera._minY = 0, 0
    Camera._maxX, Camera._maxY = 0, 0
    _invalidateFollowIdle()
    return
  end

  Camera._logicalBounds = bounds
  _recalculateEffectiveBounds()
  _invalidateFollowIdle()
end

-- ! Clear Bounds
-- Clears the camera bounds
function Camera.clearBounds()
  Camera._logicalBounds = nil
  Camera._hasBounds = false
  Camera._minX = 0
  Camera._minY = 0
  Camera._maxX = 0
  Camera._maxY = 0
  _invalidateFollowIdle()
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
  Camera._logicalBounds     = nil
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
  Camera._shakeOffsetX      = 0
  Camera._shakeOffsetY      = 0
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
  Camera.springFreq         = 4.0
  Camera.springDamp         = 0.9
  Camera._onOffsetChanged   = {}

  -- Immediate screen-space reset
  setDrawOffset(0, 0)
  redrawBackground()

  Camera._isActive = true
  _invalidateFollowIdle()
end

-- ! Snapshot State
-- Captures the active camera state so a paused scene can restore ownership
-- Restores correctly after stack pop cleanup resets the global camera
function Camera._snapshotState()
  return {
    x                 = Camera.x,
    y                 = Camera.y,
    _velocityX        = Camera._velocityX,
    _velocityY        = Camera._velocityY,
    _targetX          = Camera._targetX,
    _targetY          = Camera._targetY,
    target            = Camera.target,
    _logicalBounds    = _copyBounds(Camera._logicalBounds),
    smoothing         = Camera.smoothing,
    _shakeAmplitude   = Camera._shakeAmplitude,
    shakeDuration     = Camera.shakeDuration,
    _shakeFrequency   = Camera._shakeFrequency,
    _shakeAngularFreq = Camera._shakeAngularFreq,
    _shakeTimer       = Camera._shakeTimer,
    _deadZoneWidth    = Camera._deadZoneWidth,
    _deadZoneHeight   = Camera._deadZoneHeight,
    _deadZoneHalfW    = Camera._deadZoneHalfW,
    _deadZoneHalfH    = Camera._deadZoneHalfH,
    friction          = Camera.friction,
    _updateFunc       = Camera._updateFunc,
    targetBiasX       = Camera.targetBiasX,
    targetBiasY       = Camera.targetBiasY,
    biasReturnRate    = Camera.biasReturnRate,
    mode              = Camera.mode,
    springFreq        = Camera.springFreq,
    springDamp        = Camera.springDamp,
    _onOffsetChanged  = _copyList(Camera._onOffsetChanged),
  }
end

-- ! Restore State
-- Restores a snapshot created by Camera._snapshotState().
function Camera._restoreState(snapshot)
  if type(snapshot) ~= "table" then return false end
  _invalidateFollowIdle()

  local target = _validateTarget(snapshot.target)

  Camera.x                  = snapshot.x or 0
  Camera.y                  = snapshot.y or 0
  Camera._velocityX         = snapshot._velocityX or 0
  Camera._velocityY         = snapshot._velocityY or 0
  Camera._targetX           = snapshot._targetX or Camera.x
  Camera._targetY           = snapshot._targetY or Camera.y
  Camera.target             = target
  Camera.smoothing          = snapshot.smoothing or 0
  Camera._shakeAmplitude    = snapshot._shakeAmplitude or 0
  Camera.shakeDuration      = snapshot.shakeDuration or 0
  Camera._shakeFrequency    = snapshot._shakeFrequency or 0
  Camera._shakeAngularFreq  = snapshot._shakeAngularFreq or 0
  Camera._shakeTimer        = snapshot._shakeTimer or 0
  Camera._deadZoneWidth     = snapshot._deadZoneWidth or 0
  Camera._deadZoneHeight    = snapshot._deadZoneHeight or 0
  Camera._deadZoneHalfW     = snapshot._deadZoneHalfW or 0
  Camera._deadZoneHalfH     = snapshot._deadZoneHalfH or 0
  Camera.friction           = snapshot.friction ~= nil and snapshot.friction or FRICTION_DEFAULT
  Camera.targetBiasX        = snapshot.targetBiasX or 0
  Camera.targetBiasY        = snapshot.targetBiasY or 0
  Camera.biasReturnRate     = snapshot.biasReturnRate or 6
  Camera.mode               = snapshot.mode or "lerp"
  Camera.springFreq         = snapshot.springFreq or 4.0
  Camera.springDamp         = snapshot.springDamp or 0.9
  Camera._onOffsetChanged   = _copyList(snapshot._onOffsetChanged)
  Camera._logicalBounds     = _copyBounds(snapshot._logicalBounds)

  _recalculateEffectiveBounds()

  local updateFunc = snapshot._updateFunc
  if updateFunc == Camera.updateFollow and Camera.target == nil then
    updateFunc = Camera.updateStatic
  end
  Camera._updateFunc = updateFunc
    or (Camera.target and Camera.updateFollow or Camera.updateStatic)

  -- Force the draw offset and parallax listeners to observe the restored camera.
  Camera._lastX = round(Camera.x) + 1
  Camera._lastY = round(Camera.y) + 1
  Camera._isActive = true
  _commitOffset(0)

  return true
end

-- ! Set Bias
function Camera.setBias(x, y)
  Camera.targetBiasX, Camera.targetBiasY = x or 0, y or 0
  -- Recalculate bounds to account for new bias
  if Camera._logicalBounds then
    _recalculateEffectiveBounds()
  end
  _invalidateFollowIdle()
end

-- ! Add Offset Listener
-- @param fn Function called with totalOffsetX and totalOffsetY when the draw offset changes
function Camera.addOffsetListener(fn)
  if type(fn) == "function" then table.insert(Camera._onOffsetChanged, fn) end
end

-- ! Clear Offset Listeners
function Camera.clearOffsetListeners()
  Camera._onOffsetChanged = {}
end

-- ! Set Mode
function Camera.setMode(mode) -- "lerp" or "spring"
  if mode == "spring" or mode == "lerp" then
    Camera.mode = mode
    _invalidateFollowIdle()
  end
end

-- ! Follow After Delay
-- Delayed follow helper: stop following, then start after N ms
function Camera.followAfterDelay(sprite, delayMS, smoothing)
  -- Keep current offset; just stop following briefly
  Camera.setTarget(nil)
  performAfterDelay(delayMS or 0, function()
    -- Only re-attach if the sprite still exists
    if sprite and sprite.getPosition then
      Camera.setTarget(sprite, smoothing)
    end
  end)
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
    error("[Camera.updateFollow] Target sprite is invalid or removed", 2)
  end
  --#DEBUG END

  local px, py = Camera.target:getPosition()

  --#DEBUG START
  if type(px) ~= "number" or type(py) ~= "number" then
    error("[Camera.updateFollow] Invalid sprite position: expected numbers (x, y)")
  end
  --#DEBUG END

  if _canSkipFollow(px, py, dt) then return end

  -- Calculate desired target position (world top-left for screen center)
  local desiredX, desiredY, targetX, targetY, hasSmoothing = _resolveFollowTarget(px, py)
  Camera._targetX = targetX
  Camera._targetY = targetY

  -- Interpolate or set position
  if Camera.mode == "spring" then
    -- Critically damped spring
    local omega = 2 * pi * Camera.springFreq
    local zeta  = Camera.springDamp
    -- Velocity form
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
    local boundsX, boundsY = Camera.x, Camera.y
    Camera.x = clamp(Camera.x, Camera._minX, Camera._maxX)
    Camera.y = clamp(Camera.y, Camera._minY, Camera._maxY)
    if Camera.x ~= boundsX then Camera._velocityX = 0 end
    if Camera.y ~= boundsY then Camera._velocityY = 0 end
  end

  if Camera.smoothing > 0
    and abs(Camera.x - Camera._targetX) < 0.05
    and abs(Camera.y - Camera._targetY) < 0.05
  then
    Camera._targetX = Camera.x
    Camera._targetY = Camera.y
  end

  _commitOffset(dt)
  _rememberFollowIdle(px, py)
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
-- Returns the logical bounds (as set by developer, before bias expansion) or nil
function Camera.getBounds()
  if not Camera._logicalBounds then return nil end
  return {
    x1 = Camera._logicalBounds.x1,
    y1 = Camera._logicalBounds.y1,
    x2 = Camera._logicalBounds.x2,
    y2 = Camera._logicalBounds.y2
  }
end

-- ! Get Bound X1
function Camera.getBoundX1()
  return Camera._logicalBounds and Camera._logicalBounds.x1 or nil
end

-- ! Get Bound X2
function Camera.getBoundX2()
  return Camera._logicalBounds and Camera._logicalBounds.x2 or nil
end

-- ! Get Bound Y1
function Camera.getBoundY1()
  return Camera._logicalBounds and Camera._logicalBounds.y1 or nil
end

-- ! Get Bound Y2
function Camera.getBoundY2()
  return Camera._logicalBounds and Camera._logicalBounds.y2 or nil
end

-- ! Get Draw Offset
-- Returns the current draw offset (x, y) applied to the screen
function Camera.getDrawOffset()
  return -Camera._lastX, -Camera._lastY
end

-- ! Get Shake Offset
-- Returns the screen-space shake offset included in the committed draw offset
function Camera.getShakeOffset()
  return Camera._shakeOffsetX, Camera._shakeOffsetY
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

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

Camera controls the global draw offset for world-space scenes.

-- Follow a Player
Camera.reset()
Camera.setBounds({ x1 = 0, y1 = 0, x2 = 1600, y2 = 960 })
Camera.setTarget(player, 10)
Camera.setDeadZone(48, 32)

function GameScene:update(dt)
  Camera.update(dt)
end

-- Manual Panning
Camera.reset()
Camera.setBounds({ x1 = 0, y1 = 0, x2 = 1200, y2 = 800 })
Camera.setPosition(200, 120)
Camera.setPanVelocity(80, 0)

function MapScene:update(dt)
  Camera.update(dt)
end

-- Screen and World Coordinates
local screenX, screenY = Camera.worldToScreen(player.x, player.y)
local worldX, worldY = Camera.screenToWorld(200, 120)

-- Shake and Manual Screen-Space Effects
Camera.shake(6, 0.35, 18)
-- Read after Camera.update(dt) has committed the frame offset
local shakeX, shakeY = Camera.getShakeOffset()
local effectX, effectY = 200 - shakeX, 120 - shakeY
Camera.setTarget(nil)

--]]
