-- core/sprites/RoxyActor.lua

-- Math functions
local abs   <const> = math.abs
local floor <const> = math.floor
local max   <const> = math.max
local min   <const> = math.min

-- Table functions
local tableInsert <const> = table.insert

-- Core Playdate
local pd        <const> = playdate
local Graphics  <const> = pd.graphics

-- Timer functions
local performAfterDelay <const> = pd.timer.performAfterDelay

-- Roxy core
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
  self:_parseInitArgs(manifest, defaultState, opts, scene)

  RoxyActor.super.init(self, self._opts, self._scene)

  self:_initializeProperties()
  self:_setupSheet()
  self:_buildAnimationsFromRows()
  self:_finalizeSetup()
end

--------------------------------------------------------------------------------
-- Private Init Helpers
--------------------------------------------------------------------------------

-- ! Parse Init Arguments
-- Handle flexible argument patterns
function RoxyActor:_parseInitArgs(manifest, defaultState, opts, scene)
  -- Allow 3-arg form where 2nd arg is actually scene
  if defaultState and type(defaultState) == "table" and defaultState.addSprite and not opts and not scene then
    scene, defaultState = defaultState, nil
  end
  -- Allow 3-arg form where 3rd arg is scene (when opts omitted)
  if opts and opts.addSprite and scene == nil then
    scene, opts = opts, nil
  end

  self._manifest = manifest or {}
  self._defaultState = defaultState or self._manifest.default
  self._opts = opts or {}
  self._scene = scene
end

-- ! Initialize Properties
function RoxyActor:_initializeProperties()
  self.manifest     = self._manifest
  self.defaultState = self._defaultState
  self.currentState = nil
  self.nextState    = nil
  self.facing       = 1

  --#DEBUG START
  if not self.animation and not self._manifest.sheet then
    Log.warn("[RoxyActor:init] No spritesheet/imagetable provided in manifest")
  end
  --#DEBUG END
end

-- ! Setup Sheet
function RoxyActor:_setupSheet()
  -- Only set view if one isn't already set (respects opts.view or pre-set view)
  if not self.animation and self._manifest.sheet then
    local sheet, sheetType = self._manifest.sheet, type(self._manifest.sheet)
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
end

-- ! Build Animations From Rows
function RoxyActor:_buildAnimationsFromRows()
  local animation = self.animation
  local imagetable = animation and animation.imagetable
  local rows = self._manifest.rows

  if type(rows) == "table" and imagetable then
    local perRow = self._manifest.frames or #imagetable or 1
    local doLoop = self._manifest.loop or {}
    local doNext = self._manifest.next or {}

    for stateName, info in pairs(rows) do
      local startFrame, endFrame = self:_calculateFrameRange(info, perRow)
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
end

-- ! Calculate Frame Range
function RoxyActor:_calculateFrameRange(info, perRow)
  if type(info) == "table" then
    return info.start, info.finish
  else
    local startFrame = (info - 1) * perRow + 1
    local endFrame = info * perRow
    return startFrame, endFrame
  end
end

-- ! Finalize Setup
function RoxyActor:_finalizeSetup()
  -- Ensure animations table present
  local animation = self.animation
  self.animations = (animation and animation.animations) or self.animations or {}

  self:_ensureAnimationCallbacks()
  self:_cacheTransitionRules()

  if self.defaultState and self.animations[self.defaultState] then
    self:setState(self.defaultState)
  end

  -- Clean up temporary init properties
  self._manifest = nil
  self._defaultState = nil
  self._opts = nil
  self._scene = nil
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
      local conditions = {}
      for key, value in pairs(rule) do
        if key ~= "state" then
          local condition = self:_parseCondition(key, value)
          tableInsert(conditions, condition)
        end
      end
      tableInsert(self._transitionRulesCache, { state = rule.state, conditions = conditions })
    --#DEBUG START
    else
      Log.warn("[RoxyActor:_cacheTransitionRules] Invalid transition rule: missing state key")
    --#DEBUG END
    end
  end
end

-- ! Parse Condition
-- Extract condition type and option name from rule key
function RoxyActor:_parseCondition(key, value)
  local conditionType = "eq" -- Default to equality
  local optionName = key

  if key:find("GreaterThan$") then
    conditionType = "gt"
    optionName = key:gsub("GreaterThan$", "")
  elseif key:find("LessThan$") then
    conditionType = "lt"
    optionName = key:gsub("LessThan$", "")
  elseif key:find("AtLeast$") then
    conditionType = "gte"
    optionName = key:gsub("AtLeast$", "")
  elseif key:find("AtMost$") then
    conditionType = "lte"
    optionName = key:gsub("AtMost$", "")
  end

  return {
    type = conditionType,
    option = optionName,
    value = value
  }
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
  local holdMS = floor(1000 * max(0.05, min(frameDuration, 0.25)))

  -- Token to cancel stale timers if we settle again quickly
  local token = (self._settleToken or 0) + 1
  self._settleToken = token

  performAfterDelay(holdMS, function()
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
  local animations = animation and animation.animations
  if not animations then return end

  for name, clip in pairs(animations) do
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
    --    user callback now to snap + unlock.)
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
    local nextState = self.nextState
    self.nextState = nil
    self:setState(nextState)
  elseif self.manifest.next and self.manifest.next[stateName] then
    self:setState(self.manifest.next[stateName])
  end
end

-- ! Evaluate Condition
-- Optimized condition evaluation with early exit
function RoxyActor:_evaluateCondition(condition, opts)
  local optVal = opts[condition.option]
  if condition.type == "gt" then
    return optVal and optVal > condition.value
  elseif condition.type == "lt" then
    return optVal and optVal < condition.value
  elseif condition.type == "gte" then
    return optVal and optVal >= condition.value
  elseif condition.type == "lte" then
    return optVal and optVal <= condition.value
  else -- equality
    return optVal == condition.value
  end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- ! Set State
-- Immediately switch to stateName.
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
  local vx        = opts.vx or 0
  local vy        = opts.vy or 0
  local desiredVx = opts.intentVX or vx
  local onGround  = opts.onGround ~= nil and opts.onGround or true

  -- Cache frequently accessed values
  local animation = self.animation
  local currentAnimation = animation and animation.currentAnimation

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
      local allConditionsMet = true
      for _, condition in ipairs(rule.conditions) do
        if not self:_evaluateCondition(condition, opts) then
          allConditionsMet = false
          break
        end
      end
      if allConditionsMet and rule.state ~= self.currentState then
        return self:setState(rule.state) -- Matched rule --> switch & exit
      end
    end
  end

  -- Generic fallback (idle / run / jump / fall)
  local targetState = self:_determineDefaultState(desiredVx, vy, onGround)

  if self.animations[targetState] and targetState ~= self.currentState then
    self:setState(targetState)
  end

  return self
end

-- ! Determine Default State
-- Extract default state logic for better testability and clarity
function RoxyActor:_determineDefaultState(desiredVx, vy, onGround)
  if onGround == false then
    return (vy < 0) and "jump" or "fall"
  elseif abs(desiredVx) > 0 then
    return "run"
  else
    return "idle"
  end
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

--------------------------------------------------------------------------------
-- Usage Examples
--------------------------------------------------------------------------------

--[[

-- Basic Setup with Manifest
local playerManifest = {
  sheet = "images/player-spritesheet", -- Path to spritesheet
  rows = {
    idle = 1, -- Row 1 for idle animation
    run = 2,  -- Row 2 for running
    jump = 3, -- Row 3 for jumping
    fall = 4  -- Row 4 for falling
  },
  frames = 8, -- 8 frames per row
  default = "idle", -- Starting state
  loop = {
    idle = true,
    run = true,
    jump = false, -- One-shot animation
    fall = false
  },
  next = {
    jump = "fall",  -- Jump chains to fall
    fall = "idle"   -- Fall returns to idle
  }
}

local player = RoxyActor(playerManifest, scene)

-- Advanced Manifest with Transition Rules
local advancedManifest = {
  sheet = "images/character",
  rows = {
    idle = { start = 1, finish = 4, speed = 1 },
    run = { start = 9, finish = 16, speed = 2 },
    jump = { start = 17, finish = 24, frameDuration = 0.05 },
    attack = { start = 25, finish = 32 }
  },
  default = "idle",
  transitions = {
    { state = "run", vxGreaterThan = 10, onGround = true },
    { state = "jump", vy = -50, onGround = false },
    { state = "fall", vyGreaterThan = 0, onGround = false },
    { state = "idle", vx = 0, onGround = true }
  }
}

-- State Management
player:setState("run")        -- Immediate state change
player:queueState("jump")     -- Queue next state
player:setState("idle", true) -- Force restart even if already idle

-- One-Shot Animations
player:playOnce("attack", function(actor)
  Log.debug("Attack animation completed!")
  -- Automatically returns to previous state
end)

-- Physics Integration
local physicsBody = RoxyPhysicsBody({
  x = 100, y = 100,
  width = 32, height = 48
})

player:addPhysics(physicsBody)

-- Custom updatePhysics override
function player:updatePhysics(opts)
  -- opts contains: vx, vy, onGround, intentVX, etc.
  local vx = opts.vx or 0
  local vy = opts.vy or 0
  local onGround = opts.onGround

  -- Custom state logic
  if opts.isAttacking then
    if self.currentState ~= "attack" then
      self:playOnce("attack")
    end
  else
    -- Let parent handle default transitions
    RoxyActor.super.updatePhysics(self, opts)
  end
end

-- Manual Physics Updates
player:updatePhysics({
  vx = 15,            -- Current horizontal velocity
  vy = -20,           -- Current vertical velocity
  intentVX = 25,      -- Desired horizontal velocity (for facing)
  onGround = false,   -- Ground collision state
  isSliding = true,   -- Custom condition
  healthAtLeast = 50  -- Custom condition with suffix
})

-- Facing Direction
player:setFacing(velocity.x) -- Positive = right, negative = left

-- Multiple Initialization Patterns
local actor1 = RoxyActor(manifest, scene)               -- 2-arg
local actor2 = RoxyActor(manifest, "idle", opts, scene) -- 4-arg
local actor3 = RoxyActor(manifest, "idle", scene)       -- 3-arg scene
local actor4 = RoxyActor(manifest, opts, scene)         -- 3-arg opts

-- Asset Pool Integration
local pooledActor = RoxyActor({
  sheet = RoxyAnimation.fromPool("shared_character_animations")
}, scene)

-- Custom Animation Building (without rows)
local customActor = RoxyActor({}, scene)
customActor:addAnimation({
  name = "dance",
  startFrame = 1,
  endFrame = 12,
  loop = true,
  speed = 1.5,
  onCompleteCallback = function()
    Log.debug("Dance loop completed!")
  end
})

-- Cleanup
player:clearPhysics() -- Remove physics integration
player:remove()       -- Remove from scene
player:destroy()      -- Full cleanup

-- In your game loop
function GameScene:update()
  -- Physics bodies update the actor automatically
  physicsWorld:update()

  -- Or update manually for non-physics actors
  for _, actor in ipairs(self.actors) do
    if not actor.physicsBody then
      actor:update()
    end
  end
end

-- Querying Actor State
if player.currentState == "jump" then
  Log.debug("Player is jumping!")
end

if player.facing == -1 then
  Log.debug("Player is facing left")
end

-- Debug Information
Log.debug("Current state:", player.currentState)  --#DEBUG
Log.debug("Queued state:", player.nextState)      --#DEBUG
Log.debug("Available states:")                    --#DEBUG
--#DEBUG START
for name, _ in pairs(player.animations) do
  Log.debug("  -", name)
end
--#DEBUG END

--]]
