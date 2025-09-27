-- core/sprites/RoxyActor.lua

-- Math Functions
local abs   <const> = math.abs
local floor <const> = math.floor
local max   <const> = math.max
local min   <const> = math.min

-- Core Playdate
local pd        <const> = playdate
local Graphics  <const> = pd.graphics

-- Timer Functions
local performAfterDelay <const> = pd.timer.performAfterDelay

-- Roxy Core
local r <const> = roxy

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- ! Resolve Terminal
-- When starting a one-shot, find the last NON-looping clip in the .next chain.
-- Stops before a loop, on missing next, or on cycles.
local function _resolveTerminal(self, startName)
  local seen, prev = {}, nil
  local name = startName
  while true do
    local clip = self.animations and self.animations[name]
    if not clip then
      return prev or name -- Missing: return last valid
    end
    if clip.loop then
      return prev or name -- Don't ever return a looping clip
    end
    if not clip.next or seen[name] then
      return name -- Last non-loop or cycle
    end
    seen[name] = true
    prev = name
    name = clip.next
  end
end

--------------------------------------------------------------------------------
-- Class Definition & Init
--------------------------------------------------------------------------------

class("RoxyActor").extends(RoxySprite)

-- ! Initialize
-- Manifest may include:
--   sheet, rows, frames, loop, next, default, transitions
-- Sprite options (forwarded to RoxySprite) may include:
--   name, worldX, worldY, parallaxX, parallaxY, parallaxOriginX, parallaxOriginY, view, isSheet, singleAnimation, frameDuration
function RoxyActor:init(manifest, defaultState, opts, scene)
  -- Allow 3-arg form where 2nd arg is actually scene
  if defaultState and type(defaultState) == "table" and defaultState.addSprite and not opts and not scene then
    scene, defaultState = defaultState, nil
  end
  -- Allow 3-arg form where 3rd arg is scene (when opts omitted)
  if opts and opts.addSprite and scene == nil then
    scene, opts = opts, nil
  end

  manifest = manifest or {}
  opts = opts or {}

  RoxyActor.super.init(self, opts, scene)

  self.manifest     = manifest
  self.defaultState = defaultState or manifest.default
  self.currentState = nil
  self.nextState    = nil
  self.facing       = 1

  --#DEBUG START
  if not self.animation and not manifest.sheet then
    Log.warn("[RoxyActor:init] No spritesheet/imagetable provided in manifest")
  end
  --#DEBUG END

  -- Only set view if one isn't already set (respects opts.view or pre-set view)
  if not self.animation and manifest.sheet then
    local sheet, sheetType = manifest.sheet, type(manifest.sheet)
    if sheetType == "string" then
      self:setView(sheet, true, false, false)
    elseif sheetType == "userdata" and sheet.getImage then
      self:setView(RoxyAnimation.fromImagetable(sheet))
    elseif sheetType == "table" then
      if sheet.isRoxyAnimation then
        self:setView(sheet:retain())
      elseif sheet.animation and sheet.animation.isRoxyAnimation then
        self:setView(sheet.animation:retain())
      --#DEBUG START
      else
        Log.warn("[RoxyActor:init] Unsupported table for 'sheet'")
      --#DEBUG END
      end
    --#DEBUG START
    else
      Log.warn("[RoxyActor:init] Unsupported sheet type; expected path, imagetable, RoxyAnimation, or {animation=...}")
    --#DEBUG END
    end
  end

  -- Build animations from manifest.rows if we have an imagetable
  local animation = self.animation
  local imagetable = animation and animation.imagetable
  local rows = manifest.rows
  if type(rows) == "table" and imagetable then
    local perRow = manifest.frames or #imagetable or 1
    local doLoop = manifest.loop or {}
    local doNext = manifest.next or {}
    for stateName, info in pairs(rows) do
      local startFrame, endFrame
      if type(info) == "table" then
        startFrame = info.start
        endFrame = info.finish
      else
        startFrame = (info - 1) * perRow + 1
        endFrame = info * perRow
      end
      self:addAnimation{
        name          = stateName,
        startFrame    = startFrame,
        endFrame      = endFrame,
        loop          = (doLoop[stateName] ~= false),
        next          = doNext[stateName],
        speed         = (type(info) == "table") and info.speed or nil,
        frameDuration = (type(info) == "table") and info.frameDuration or nil,
        onCompleteCallback = function() self:_onAnimationComplete(stateName) end,
      }
    end
  end

  -- Ensure animations table present
  animation = self.animation
  self.animations = (animation and animation.animations) or self.animations or {}

  self:_ensureAnimationCallbacks()

  self:_cacheTransitionRules()

  if self.defaultState and self.animations[self.defaultState] then
    self:setState(self.defaultState)
  end
end

--------------------------------------------------------------------------------
-- Internal Methods
--------------------------------------------------------------------------------

-- ! Finish Play Once
-- Helper so we centralize finishing semantics
function RoxyActor:_finishPlayOnce()
  local fn = self._onPlayOnceFinish
  self._onPlayOnceFinish = nil
  self._playOnceTerminal = nil
  if fn then fn(self) end
end

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

-- ! Maybe Settle / Hold
-- Returns true if a settle timer was scheduled (and we should early-return)
function RoxyActor:_maybeSettleHold(stateName)
  local clip = self.animations and self.animations[stateName]
  if not clip then return false end

  -- Only settle for one-shots that don't chain anywhere
  if clip.loop then return false end
  if clip.next then return false end

  self:_settleThenDefault(stateName, clip)
  return true
end

-- ! Settle Then Default
-- Called when a non-loop clip with no next completes.
function RoxyActor:_settleThenDefault(stateName, clip)
  local default = self.defaultState or (self.manifest and self.manifest.default)
  if not (default and self.animations and self.animations[default]) then return end

  -- Derive a small hold from the clip's frameDuration; clamp to a sane range
  local frameDuration = (clip and clip.frameDuration) or 0.12
  local holdMs = floor(1000 * max(0.05, min(frameDuration, 0.25)))

  -- Token to cancel stale timers if we settle again quickly
  local token = (self._settleToken or 0) + 1
  self._settleToken = token

  timerPerformAfterDelay(holdMs, function()
    -- Abort if another settle was scheduled or state changed meanwhile
    if self._settleToken ~= token then return end
    if self.currentState ~= stateName then return end
    self:setState(default)
  end)
end

-- ! Ensure Animation Callbacks
-- Attach onComplete callbacks to prebuilt clips (if missing)
function RoxyActor:_ensureAnimationCallbacks()
  local animation = self.animation
  local tbl = animation and animation.animations
  if not tbl then return end

  for name, clip in pairs(tbl) do
    if clip and clip.onCompleteCallback == nil then
      local clipName = name -- Capture a unique local per iteration
      clip.onCompleteCallback = function()
        self:_onAnimationComplete(clipName)
      end
    end
  end
end

-- ! On Animation Complete
-- Handle completion callbacks and queued transitions
function RoxyActor:_onAnimationComplete(stateName)
  local clip = self.animations and self.animations[stateName]

  -- If we're in a playOnce flow:
  if self._playOnceTerminal then
    -- If this clip has an explicit next, finish playOnce now.
    --    (Animation layer will switch to clip.next; we want to run the
    --     user callback now to snap + unlock.)
    if clip and clip.next then
      self:_finishPlayOnce()
      return
    end

    -- Otherwise finish when the resolved terminal (last non-loop) ends.
    if stateName == self._playOnceTerminal then
      self:_finishPlayOnce()
      return
    end

    -- Not our terminal yet; ignore
    return
  end

  -- "Settle" for non-loop, no-next clips (actor-owned return to default)
  if self:_maybeSettleHold(stateName) then
    return
  end

  -- Fallback routing
  if self.nextState then
    local nextState = self.nextState; self.nextState = nil
    self:setState(nextState)
  elseif self.manifest.next and self.manifest.next[stateName] then
    self:setState(self.manifest.next[stateName])
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

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
  if not self.animation or not self.animations or not self.animations[stateName] then return self end

  -- Compute last non-loop terminal
  self._playOnceTerminal = _resolveTerminal(self, stateName)

  -- Only queue a return if our terminal has no explicit next
  local terminal = self.animations[self._playOnceTerminal]
  if terminal and not terminal.next then
    local prev = self.currentState or self.defaultState
    self:queueState(prev)
  else
    self.nextState = nil
  end

  self._onPlayOnceFinish = (type(onFinish) == "function") and onFinish or nil
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
-- Attach physics and patch update in a reversible way
function RoxyActor:addPhysics(body)
  self.physicsBody = body

  -- Save the pre-physics update once
  if not self._updateBeforePhysics then
    self._updateBeforePhysics = self.update
  end

  -- Instance-level update wrapper
  function self:update(dt)
    dt = dt or r.deltaTime or 0

    -- (1) Step physics first if present
    local physicsBody = self.physicsBody
    if physicsBody and physicsBody.update then
      physicsBody:update(dt)
      if self.updatePhysics then
        self:updatePhysics(physicsBody)
      end
    end

    -- (2) Continue with original update
    if self._updateBeforePhysics then
      self._updateBeforePhysics(self, dt)
    else
      -- Fallback to super if somehow missing
      RoxyActor.super.update(self, dt)
    end
  end

  return self
end

-- ! Update Physics
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

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

-- ! Clear Physics
function RoxyActor:clearPhysics()
  local physicsBody = self.physicsBody
  if not physicsBody then return self end

  -- Break back-reference to help GC and avoid accidental use
  physicsBody.owner = nil
  self.physicsBody = nil

  -- Restore original update if we had patched it
  if self._updateBeforePhysics then
    self.update = self._updateBeforePhysics
    self._updateBeforePhysics = nil
  end

  return self
end

-- ! Remove
function RoxyActor:remove()
  self:clearPhysics()
  return RoxyActor.super.remove(self)
end

-- ! Destroy
function RoxyActor:destroy()
  self:clearPhysics()
  RoxyActor.super.destroy(self)
end
