local pd <const> = playdate
local Object <const> = pd.object
local Display <const> = pd.display
local Graphics <const> = pd.graphics
local Ease <const> = roxy.easingFunctions

class("RoxyAnimation").extends()

function RoxyAnimation:init(view)
	if type(view) ~= "string" then
		error("ERROR: Invalid 'view' type provided to RoxyAnimation: " .. type(view))
	end

	self.imagetable = Graphics.imagetable.new(view)
	if not self.imagetable then
		error("ERROR: Failed to create image table from view: " .. view)
	end

	self.animations = {}
	self.currentAnimation = nil
	self.currentName = nil
	self.currentFrame = 1
	self.isFirstFrame = true
	self.frameTick = 0
	self.isReversed = false
end

function RoxyAnimation:resetAnimationStart()
	self.isFirstCycle = true
	self.frameTick = 0
end

-- ! Add Animation
function RoxyAnimation:addAnimation(name, startFrame, endFrame, loop, next, onCompleteCallback, speed, frameDuration)
	self.animations[name] = {
		name = name,								-- Name of the animation
		startFrame = startFrame,					-- Starting frame of the animation
		endFrame = endFrame,						-- Ending frame of the animation
		loop = loop == nil and true or loop,		-- Whether the animation loops (default: true)
		next = next,								-- Name of the next animation to transition to after completion
		onCompleteCallback = onCompleteCallback,	-- Callback function after the animation completes
		speed = speed or 1,							-- Speed of the animation (default: 1)
		frameDuration = frameDuration or 1,  		-- Duration of each frame in game ticks (default: 1)
	}

	if not self.currentAnimation then
		self:setAnimation(name)  -- Set the first added animation as the current animation
	end
	
	return self
end

function RoxyAnimation:shouldPreventAnimationChange(unlessThisAnimation)
	-- Check if the current animation should prevent a change, unless it's the specified animation
	return unlessThisAnimation and (
		(type(unlessThisAnimation) == "string" and self.currentName == unlessThisAnimation) or 
		(type(unlessThisAnimation) == "table" and self.currentAnimation == unlessThisAnimation)
	)
end

function RoxyAnimation:getStartFrame(newAnimation, nextContinuity)
	local currentFrame = newAnimation.startFrame
	if nextContinuity and self.currentAnimation then
		local currentAnimation = self.animations[self.currentName]
		local currentProgress = (self.currentFrame - currentAnimation.startFrame) / (currentAnimation.endFrame - currentAnimation.startFrame + 1)
		
		-- Check for NaN on currentProgress
		if currentProgress ~= currentProgress then
			currentProgress = 0
		end
		
		local newFrameCount = newAnimation.endFrame - newAnimation.startFrame + 1
		currentFrame = newAnimation.startFrame + math.floor(currentProgress * newFrameCount)
		currentFrame = math.max(newAnimation.startFrame, math.min(currentFrame, newAnimation.endFrame))
	end
	return currentFrame
end

-- ! Set Animation
function RoxyAnimation:setAnimation(name, nextContinuity, unlessThisAnimation)
	if self:shouldPreventAnimationChange(unlessThisAnimation) then return self end
	
	-- Use the first animation if no name is provided
	if not name then
		for animName in pairs(self.animations) do
			name = animName
			break
		end
	end

	local newAnimation = self.animations[name]
	if not newAnimation then
		warn("Warning: Animation '" .. name .. "' does not exist.")
		return self
	end

	self.currentFrame = self:getStartFrame(newAnimation, nextContinuity)
	self.currentAnimation = newAnimation
	self.currentName = name

	if not nextContinuity then
		self:resetAnimationStart()  -- Reset animation cycle if no continuity
	else
		self.frameTick = 0  -- Reset frame tick counter
	end

	return self
end

-- ! Animation Speed
function RoxyAnimation:getSpeed()
	local currentAnimation = self.currentAnimation
	if currentAnimation and currentAnimation.speed then
		return currentAnimation.speed  -- Return the speed of the current animation
	else
		warn("Warning: No current animation or animation has no speed set.")
		return nil
	end
end

function RoxyAnimation:setSpeed(speed, currentOnly)
	speed = math.max(speed or 1, 0)  -- Ensure speed is at least 0
	
	if speed <= 0 then
		warn("Warning: Speed is set to 0 or less, which will halt the animation.")
	end

	if not currentOnly then
		for _, animation in pairs(self.animations) do
			animation.speed = speed  -- Set speed for all animations
		end
	elseif self.currentAnimation then
		self.currentAnimation.speed = speed  -- Set speed for the current animation only
	end

	return self
end

-- ! Frame Duration
function RoxyAnimation:getFrameDuration()
	local currentAnimation = self.currentAnimation
	if currentAnimation and currentAnimation.frameDuration then
		return currentAnimation.frameDuration  -- Return the frame duration of the current animation
	else
		warn("Warning: No current animation or animation has no frame duration set.")
		return nil
	end
end

function RoxyAnimation:setFrameDuration(frameDuration, currentOnly)
	if frameDuration < 1 then
		warn("Warning: Frame duration cannot be less than 1. The value has been adjusted to 1 to prevent unintended animation behavior.")
	end
	frameDuration = math.max(frameDuration or 1, 1)  -- Ensure frame duration is at least 1

	if not currentOnly then
		for _, animation in pairs(self.animations) do
			animation.frameDuration = frameDuration  -- Set frame duration for all animations
		end
	elseif self.currentAnimation then
		self.currentAnimation.frameDuration = frameDuration  -- Set frame duration for the current animation only
	end
	
	return self
end

-- ! Animation Controls
function RoxyAnimation:startWithDelay(millisecondsDelay, animationName)
	if millisecondsDelay > 0 and self.animations[animationName] then
		-- Start the animation after a specified delay
		pd.timer.performAfterDelay(millisecondsDelay, function()
			self:setAnimation(animationName)
		end)
	end

	return self
end

function RoxyAnimation:jumpToSpecificFrame(frame)
	local currentAnimation = self.currentAnimation
	if not currentAnimation then return self end

	-- Jump to a specific frame within the current animation
	self.currentFrame = math.max(currentAnimation.startFrame, math.min(frame, currentAnimation.endFrame))

	return self
end

function RoxyAnimation:stepFrame(direction)
	if not self.currentAnimation then return self end
	
	-- Determine the step direction
	local step = 1
	if direction == -1 or direction == "back" then step = -1 end
	
	self.currentFrame += step  -- Adjust the current frame by the step

	return self
end

function RoxyAnimation:stop()
	self.currentAnimation = nil  -- Stop the current animation
	return self
end

function RoxyAnimation:reverse()
	self.isReversed = not self.isReversed  -- Toggle the reverse state of the animation
	return self
end

-- ! Update Animation
function RoxyAnimation:updateFrame(framesToSkip)
	framesToSkip = framesToSkip or 1
	local currentAnimation = self.currentAnimation

	if self.isReversed then
		self.currentFrame = self.currentFrame - framesToSkip
		if self.currentFrame < currentAnimation.startFrame then
			if currentAnimation.loop then
				-- If looping, reset to the end frame
				self.currentFrame = currentAnimation.endFrame
			elseif currentAnimation.next then
				-- If transitioning to the next animation
				self:setAnimation(currentAnimation.next, currentAnimation.nextContinuity)
				return
			else
				-- If no loop and no next animation, clamp to start frame
				self.currentFrame = currentAnimation.startFrame
				if currentAnimation.onCompleteCallback then
					currentAnimation.onCompleteCallback()
				end
			end
		end
	else
		self.currentFrame = self.currentFrame + framesToSkip
		if self.currentFrame > currentAnimation.endFrame then
			if currentAnimation.loop then
				-- If looping, reset to the start frame
				self.currentFrame = currentAnimation.startFrame
			elseif currentAnimation.next then
				-- If transitioning to the next animation
				self:setAnimation(currentAnimation.next, currentAnimation.nextContinuity)
				return
			else
				-- If no loop and no next animation, clamp to end frame
				self.currentFrame = currentAnimation.endFrame
				if currentAnimation.onCompleteCallback then
					currentAnimation.onCompleteCallback()
				end
			end
		end
	end
end

function RoxyAnimation:update()
	local currentAnimation = self.currentAnimation
	if not currentAnimation then return end

	local speed = currentAnimation.speed or 1
	local frameDuration = currentAnimation.frameDuration or 1 -- Default to 1 game tick per frame
	local ticksPerFrame = frameDuration / speed
	local framesToSkip = math.max(1, math.floor(speed) - 1)

	if self.isFirstCycle then
		self.currentFrame = currentAnimation.startFrame
		self.frameTick = 0
		self.isFirstCycle = false
		return
	end

	self.frameTick = self.frameTick + 1

	if self.frameTick >= ticksPerFrame then
		self.frameTick = 0
		self:updateFrame(framesToSkip)
	end
end

-- ! Draw Animation
function RoxyAnimation:draw(flip)
	if not self.currentAnimation then warn("Warning: No animation set.") return end
	
	flip = flip or Graphics.kImageUnflipped
	local frame = self.currentFrame
	
	-- Ensure the frame is within the valid range
	frame = math.max(self.currentAnimation.startFrame, math.min(frame, self.currentAnimation.endFrame))
	self.currentFrame = frame
	
	self.imagetable:drawImage(frame, 0, 0, flip)  -- Draw the current frame of the animation
end
