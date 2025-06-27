-- core/sprites/RoxyActor.lua

local pd       <const> = playdate
local Graphics <const> = pd.graphics

local abs <const> = math.abs

-- ----------------------------------------
-- Class Definition & Init
-- ----------------------------------------

class("RoxyActor").extends(RoxySprite)

-- Manifest may include:
--   sheet, rows, frames, loop, next, default, transitions
function RoxyActor:init(manifest, defaultState)
  RoxyActor.super.init(self)

  -- Cache manifest locally
  manifest = manifest or {}
  self.manifest = manifest

  --#DEBUG START
  if not manifest.sheet then
    warn("[W][RoxyActor:init] No spritesheet provided in manifest")
  end
  --#DEBUG END

  -- default and current states
  self.defaultState = defaultState or manifest.default
  self.currentState = nil
  self.nextState    = nil
  self.facing       = 1

  -- Set up view if sheet provided
  if manifest.sheet then
    self:setView(manifest.sheet, true, false, false)
  end

  -- Prepare for building animations
  local animation = self.animation
  local imagetable = animation and animation.imagetable
  local perRow = manifest.frames or (imagetable and #imagetable) or 1
  local rows = manifest.rows
  if type(rows) ~= "table" then
    warn("[W][RoxyActor:init] Manifest.rows missing or not a table; defaulting to empty") --#DEBUG
    rows = {}
  end
  local doLoop = manifest.loop or {}
  local doNext = manifest.next or {}

  -- Build animations from rows
  if imagetable then
    for stateName, info in pairs(rows) do
      local startFrame, endFrame
      if type(info) == "table" then
        startFrame = info.start
        endFrame = info.finish
      else
        -- fallback older style: index by row
        startFrame = (info - 1) * perRow + 1
        endFrame = info * perRow
      end

      local loop      = doLoop[stateName] ~= false
      local nextState = doNext[stateName]
      local speed    = (type(info) == "table") and info.speed or nil
      local frameDur = (type(info) == "table") and info.frameDuration or nil
      self:addAnimation{
        name                = stateName,
        startFrame          = startFrame,
        endFrame            = endFrame,
        loop                = loop,
        next                = nextState,
        speed               = speed,
        frameDuration       = frameDur,
        onCompleteCallback  = function()
          self:_onAnimationComplete(stateName)
        end,
      }
    end
  else --#DEBUG
    warn("[W][RoxyActor:init] No valid imagetable; animation states not set up") --#DEBUG
  end

  -- Ensure animations table is present
  self.animations = self.animations or (animation and animation.animations) or {}

  -- Cache transition rules for physics updates
  self:_cacheTransitionRules()

  -- Start in default or first-added state
  self:setState(self.defaultState or self.defaultName)
end

-- ----------------------------------------
-- Internal Methods
-- ----------------------------------------

-- TODO: Should these be local helpers not methods?

-- ! Cache Transition Rules
-- Cache transition rules to avoid per-frame parsing
function RoxyActor:_cacheTransitionRules()
  local rules = self.manifest.transitions
  self._transitionRulesCache = {}
  if type(rules) ~= "table" then
    return
  end
  for _, rule in ipairs(rules) do
    if rule.state then
      local conds = {}
      for key, value in pairs(rule) do
        if key ~= "state" then
          conds[key] = value
        end
      end
      table.insert(self._transitionRulesCache, { state = rule.state, conditions = conds })
    else --#DEBUG
      warn("[W][RoxyActor:_cacheTransitionRules] Invalid transition rule: missing state key") --#DEBUG
    end
  end
end

-- ! On Animation Complete
-- Handle completion callbacks and queued transitions
function RoxyActor:_onAnimationComplete(stateName)
  if self.nextState then
    local nextState = self.nextState
    self.nextState = nil
    self:setState(nextState)
  elseif self.manifest.next and self.manifest.next[stateName] then
    self:setState(self.manifest.next[stateName])
  end

  -- Call playOnce callback if present
  if self._onPlayOnceFinish then
    self._onPlayOnceFinish(self)
    self._onPlayOnceFinish = nil
  end
end

-- ----------------------------------------
-- Public API
-- ----------------------------------------

-- ! Set State
-- Immediately switch to `stateName`.
-- If force=true, will restart even if already in that state.
function RoxyActor:setState(stateName, force)
  --#DEBUG START
  if type(stateName) ~= "string" then
    warn("[W][RoxyActor:setState] Expected string for stateName, got", type(stateName))
    return self
  end
  if not self.animations[stateName] then
    warn("[W][RoxyActor:setState] Unknown state:", stateName)
    return self
  end
  --#DEBUG END

  if not force and self.currentState == stateName then return self end

  self.currentState = stateName

  if self.animation then
    self:setAnimation(stateName)
    local currentAnimation = self.animation.currentAnimation
    if currentAnimation then
      self.animation.currentFrame = currentAnimation.startFrame
      self.animation.accumulator = 0
    end
  end

  self:markDirty()

  return self
end

-- ! Queue State
-- Queue up a state change to occur as soon as the current clip finishes.
function RoxyActor:queueState(stateName)
  --#DEBUG START
  if type(stateName) ~= "string" then
    warn("[W][RoxyActor:queueState] Expected string for queued stateName, got", type(stateName))
    return self
  end
  if not self.animations[stateName] then
    warn("[W][RoxyActor:queueState] Unknown state to queue:", stateName)
    return self
  end
  --#DEBUG END

  self.nextState = stateName

  return self
end

-- ! Play Once
-- Play a one-shot animation state, then return to the previous/default.
function RoxyActor:playOnce(stateName, onFinish)
  --#DEBUG START
  if type(stateName) ~= "string" then
    warn("[W][RoxyActor:playOnce] Expected string for playOnce stateName, got", type(stateName))
    return self
  end
  if not self.animations[stateName] then
    warn("[W][RoxyActor:playOnce] Unknown one-shot state:", stateName)
    return self
  end
  --#DEBUG END

  local prev = self.currentState or self.defaultState
  self:queueState(prev)
  if type(onFinish) == "function" then
    -- Attach a temporary callback for when the animation completes
    self._onPlayOnceFinish = onFinish
  else
    self._onPlayOnceFinish = nil
  end

  return self:setState(stateName, true)
end

-- ! Set Facing
function RoxyActor:setFacing(vx)
  if vx < 0 then
    self.facing = -1
    self:flipX()
  elseif vx > 0 then
    self.facing = 1
    self:unflip()
  end
  return self
end

-- ! Add Physics
-- Attach a physics body and override this instance's update method to step physics before animation.
function RoxyActor:addPhysics(body)
  self.physicsBody = body

  -- Capture the original update method once
  local originalUpdate = self.update

  -- Override only this instance’s update(dt)
  function self:update(dt)
    dt = dt or roxy.deltaTime or 0

    -- (1) Step physics first
    if self.physicsBody and self.physicsBody.update then
      self.physicsBody:update(dt)
      if self.updatePhysics then
        self:updatePhysics(self.physicsBody)
      end
    end

    -- (2) Proceed with original update
    originalUpdate(self, dt)
  end

  return self
end

function RoxyActor:updatePhysics(props)
  props = props or {}
  local vx        = props.vx        or 0
  local vy        = props.vy        or 0
  local desiredVx = props.intentVX  or vx

  self:setFacing(vx)

  -- Cached transition rules
  local cache = self._transitionRulesCache
  if cache and #cache > 0 then
    for _, rule in ipairs(cache) do
      local ok = true
      for key, value in pairs(rule.conditions) do
        if key:find("GreaterThan$") then
          local prop = key:gsub("GreaterThan$", "")
          if not (props[prop] and props[prop] > value) then ok = false break end
        elseif key:find("LessThan$") then
          local prop = key:gsub("LessThan$", "")
          if not (props[prop] and props[prop] < value) then ok = false break end
        elseif key:find("AtLeast$") then
          local prop = key:gsub("AtLeast$", "")
          if not (props[prop] and props[prop] >= value) then ok = false break end
        elseif key:find("AtMost$") then
          local prop = key:gsub("AtMost$", "")
          if not (props[prop] and props[prop] <= value) then ok = false break end
        else
          if props[key] ~= value then ok = false break end
        end
      end
      if ok and rule.state ~= self.currentState then
        return self:setState(rule.state) -- Matched rule --> switch & exit
      end
    end
  end

  -- Don't interrupt one-shots
  local currentAnimation = self.animation and self.animation.currentAnimation
  if currentAnimation and not currentAnimation.loop then
    return self
  end

  -- Generic fallback (idle / run / jump / fall)
  local targetState
  if props.onGround == false then
    targetState = (vy < 0) and "jump" or "fall"
  elseif abs(desiredVx) > 0 then
    self.facing = desiredVx < 0 and -1 or 1
    if self.facing < 0 then self:flipX() else self:unflip() end
    targetState = "run"
  else
    targetState = "idle"
  end

  if self.animations[targetState] and targetState ~= self.currentState then
    self:setState(targetState)
  end

  return self
end

-- ! Update
-- Pass through to base update (which updates sprite and animation)
function RoxyActor:update(dt)
  RoxyActor.super.update(self, dt)
end
