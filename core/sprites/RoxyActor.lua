-- core/sprites/RoxyActor.lua

local pd       <const> = playdate
local Graphics <const> = pd.graphics
local r        <const> = roxy

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
    Log.warn("[RoxyActor:init] No spritesheet/imagetable provided in manifest")
  end
  --#DEBUG END

  -- default and current states
  self.defaultState = defaultState or manifest.default
  self.currentState = nil
  self.nextState    = nil
  self.facing       = 1

  -- Set up view based on sheet type
  if manifest.sheet then
    local sheet = manifest.sheet
    local sheetType = type(sheet)

    if sheetType == "string" then
      self:setView(sheet, true, false, false)
    elseif sheetType == "userdata" and sheet.getImage then  -- Fixed: changed from drawImage to getImage
      self:setView(RoxyAnimation.fromImagetable(sheet))
    elseif sheetType == "table" then
      -- Accept a direct RoxyAnimation, or a wrapper {animation=anim}
      if sheet.isRoxyAnimation then
        self:setView(sheet:retain()) -- Fixed: changed from s:retain() to sheet:retain()
      elseif sheet.animation and sheet.animation.isRoxyAnimation then
        self:setView(sheet.animation:retain())
      else --#DEBUG
        Log.warn("[RoxyActor:init] Unsupported table for 'sheet' (expected RoxyAnimation or {animation=...})") --#DEBUG
      end
    else --#DEBUG
      Log.warn("[RoxyActor:init] Unsupported sheet type; expected path, imagetable, RoxyAnimation, or {animation=...}") --#DEBUG
    end
  end

  -- Prepare for building animations
  local animation = self.animation
  local imagetable = animation and animation.imagetable
  local rows = manifest.rows

  -- Only build if rows is actually a table.
  if type(rows) == "table" and imagetable then
    local perRow = manifest.frames or (imagetable and #imagetable) or 1  -- Fixed: safer nil handling
    local doLoop = manifest.loop or {}
    local doNext = manifest.next or {}

    for stateName, info in pairs(rows) do
      local startFrame, endFrame
      if type(info) == "table" then
        startFrame = info.start
        endFrame   = info.finish
      else
        startFrame = (info - 1) * perRow + 1
        endFrame   = info * perRow
      end
      self:addAnimation{
        name       = stateName,
        startFrame = startFrame,
        endFrame   = endFrame,
        loop       = (doLoop[stateName] ~= false),
        next       = doNext[stateName],
        speed      = (type(info) == "table") and info.speed or nil,
        frameDuration = (type(info) == "table") and info.frameDuration or nil,
        onCompleteCallback = function() self:_onAnimationComplete(stateName) end,
      }
    end
  else
    -- rows missing is fine when we already have a prebuilt animation
    -- (do nothing)
  end

  -- Ensure animations table is present
  local animation = self.animation
  self.animations = (animation and animation.animations) or self.animations or {}

  -- Cache transition rules for physics updates
  self:_cacheTransitionRules()

  -- Start in default state (only if it exists)
  -- Fixed: Removed the undefined self.defaultName condition
  if self.defaultState and self.animations[self.defaultState] then
    self:setState(self.defaultState)
  end
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

  -- Pre-parse condition types for performance
  for _, rule in ipairs(rules) do
    if rule.state then
      local conds = {}
      for key, value in pairs(rule) do
        if key ~= "state" then
          -- Parse condition type once during caching
          local condType = "eq" -- default to equality
          local optionName = key

          if key:find("GreaterThan$") then
            condType = "gt"
            optionName = key:gsub("GreaterThan$", "")
          elseif key:find("LessThan$") then
            condType = "lt"
            optionName = key:gsub("LessThan$", "")
          elseif key:find("AtLeast$") then
            condType = "gte"
            optionName = key:gsub("AtLeast$", "")
          elseif key:find("AtMost$") then
            condType = "lte"
            optionName = key:gsub("AtMost$", "")
          end

          table.insert(conds, {
            type = condType,
            option = optionName,
            value = value
          })
        end
      end
      table.insert(self._transitionRulesCache, { state = rule.state, conditions = conds })
    else --#DEBUG
      Log.warn("[RoxyActor:_cacheTransitionRules] Invalid transition rule: missing state key") --#DEBUG
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
    Log.warn("[RoxyActor:setState] Expected string for stateName, got", type(stateName))
    return self
  end
  if not self.animations[stateName] then
    Log.warn("[RoxyActor:setState] Unknown state:", stateName)
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
    Log.warn("[RoxyActor:queueState] Expected string for queued stateName, got", type(stateName))
    return self
  end
  if not self.animations[stateName] then
    Log.warn("[RoxyActor:queueState] Unknown state to queue:", stateName)
    return self
  end
  --#DEBUG END

  self.nextState = stateName

  return self
end

-- ! Play Once
-- Play a one-shot animation state, then return to the previous/default.
function RoxyActor:playOnce(stateName, onFinish)
  if not self.animation or not self.animations then return self end

  if type(stateName) ~= "string" or not self.animations[stateName] then
    Log.warn("[RoxyActor:playOnce] Unknown one-shot state:" .. tostring(stateName)) --#DEBUG
    return self
  end
  local prev = self.currentState or self.defaultState
  self:queueState(prev)
  if type(onFinish) == "function" then
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

  -- Override only this instance's update(dt)
  function self:update(dt)
    dt = dt or r.deltaTime or 0

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

function RoxyActor:updatePhysics(opts)
  opts = opts or {}

  -- Provide defaults for commonly used options
  local vx        = opts.vx        or 0
  local vy        = opts.vy        or 0
  local desiredVx = opts.intentVX  or vx
  local onGround  = opts.onGround ~= nil and opts.onGround or true  -- Fixed: safer default handling

  -- Cache frequently accessed values
  local anim = self.animation
  local currentAnimation = anim and anim.currentAnimation

  -- Check one-shots first to avoid interruption
  if currentAnimation and not currentAnimation.loop then
    return self
  end

  -- Set facing based on desired velocity (intent, not actual)
  self:setFacing(desiredVx)

  -- Cached transition rules with optimized condition checking
  local cache = self._transitionRulesCache
  if cache and #cache > 0 then
    for _, rule in ipairs(cache) do
      local ok = true
      for _, cond in ipairs(rule.conditions) do
        local optVal = opts[cond.option]
        if cond.type == "gt" then
          if not (optVal and optVal > cond.value) then ok = false break end
        elseif cond.type == "lt" then
          if not (optVal and optVal < cond.value) then ok = false break end
        elseif cond.type == "gte" then
          if not (optVal and optVal >= cond.value) then ok = false break end
        elseif cond.type == "lte" then
          if not (optVal and optVal <= cond.value) then ok = false break end
        else -- equality
          if optVal ~= cond.value then ok = false break end
        end
      end
      if ok and rule.state ~= self.currentState then
        return self:setState(rule.state) -- Matched rule --> switch & exit
      end
    end
  end

  -- Generic fallback (idle / run / jump / fall)
  local targetState
  if onGround == false then
    targetState = (vy < 0) and "jump" or "fall"
  elseif abs(desiredVx) > 0 then
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
