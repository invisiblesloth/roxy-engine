local sceneManager <const> = SceneManager.getInstance()

local pd <const> = playdate
local Object <const> = pd.object
local Graphics <const> = pd.graphics
local Sprite <const> = Graphics.sprite

class("RoxySprite").extends(Sprite)

function RoxySprite:init(view, viewIsSpritesheet, singleAnimation, singleAnimationLoop, name)
	RoxySprite.super.init(self)
	
	self.name = name or self.className
	self.isRoxySprite = true  -- Custom flag to identify RoxySprite instances
	self.isPaused = true  -- Start the sprite in a paused state
	self.animation = nil  -- Placeholder for the animation object
	self.flip = Graphics.kImageUnflipped  -- Default to no flipping

	-- Determine if the animation should loop; 
	-- defaults to true unless explicitly set to false
	self.singleAnimationLoop = singleAnimationLoop ~= false
	
	-- If a view is provided, set it up
	if view then
		self:setView(view, viewIsSpritesheet, singleAnimation, self.singleAnimationLoop)
	end
end

-- ! Sprite Set Up Methods
-- These methods override the Playdate API calls and return 'self' to enable method chaining
function RoxySprite:setZIndex(zIndex)
	RoxySprite.super.setZIndex(self, zIndex)
	return self
end

function RoxySprite:setSize(width, height)
	RoxySprite.super.setSize(self, width, height)
	return self
end

function RoxySprite:setCenter(x, y)
	RoxySprite.super.setCenter(self, x, y)
	return self
end

function RoxySprite:moveTo(x, y)
	RoxySprite.super.moveTo(self, x, y)
	return self
end

-- ! Set View
-- Sets the view for the sprite, either as an image or a spritesheet
function RoxySprite:setView(view, viewIsSpritesheet, singleAnimation, singleAnimationLoop)
	-- Handle case where no view is provided
	if not view then
		self:setVisible(false)
		return self
	end
	
	self:setVisible(true)
	
	if type(view) == "string" then
		-- Handle as a path to an image or spritesheet
		if viewIsSpritesheet then
			self.animation = RoxyAnimation(view)
			
			-- Ensure the animation was loaded correctly
			if not self.animation or not self.animation.imagetable then
				error("ERROR: Failed to load spritesheet for RoxySprite")
			end
			
			if singleAnimation then
				local endFrame = self.animation.imagetable:getLength()
				self.animation:addAnimation("default", 1, endFrame, singleAnimationLoop)
				self.animation:setAnimation("default")
			end
		else
			self:setImage(Graphics.image.new(view))
		end
	elseif type(view) == "table" then
		-- Handle as already-loaded animation
		self.animation = view
	elseif type(view) == "userdata" then
		-- Handle as already-loaded image object
		self:setImage(view)
	else
		error("Unsupported view type for RoxySprite: " .. type(view))
	end
	
	return self
end

-- ! Flip Methods
-- Resets the sprite to its default unflipped state
function RoxySprite:unflip()
	self.flip = Graphics.kImageUnflipped
	if self.isPaused then
		self:markDirty()  -- Mark the sprite as needing to be redrawn
	end
	return self
end

-- Flips the sprite horizontally (along the X axis)
function RoxySprite:flipX()
	self.flip = Graphics.kImageFlippedX
	if self.isPaused then
		self:markDirty()
	end
	return self
end

-- Flips the sprite vertically (along the Y axis)
function RoxySprite:flipY()
	self.flip = Graphics.kImageFlippedY
	if self.isPaused then
		self:markDirty()
	end
	return self
end

-- Flips the sprite both horizontally and vertically
function RoxySprite:flipXY()
	self.flip = Graphics.kImageFlippedXY
	if self.isPaused then
		self:markDirty()
	end
	return self
end

-- Returns the current orientation (flipped state) of the sprite
function RoxySprite:getOrientation()
	return self.flip
end

-- ! Animations
-- Adds an animation to the sprite's animation object
function RoxySprite:addAnimation(name, startFrame, endFrame, loop, next, onCompleteCallback, frameDuration, speed)
	self.animation:addAnimation(name, startFrame, endFrame, loop, next, onCompleteCallback, frameDuration, speed)
	return self
end

-- Sets the current animation by name
function RoxySprite:setAnimation(name, nextContinuity, unlessThisAnimation)
	self.animation:setAnimation(name, nextContinuity, unlessThisAnimation)
	return self
end

-- ! Update and Draw Sprites
-- Updates the sprite's animation state and marks it as needing to be redrawn if the frame has changed
function RoxySprite:update()
	if self.animation and not self.isPaused then
		local previousFrame = self.animation.currentFrame
		self.animation:update()
		if self.animation.currentFrame ~= previousFrame then
			self:markDirty()
		end
	end
end

-- Draws the sprite, taking into account any current animation or flipping
function RoxySprite:draw()
	if self.animation then
		self.animation:draw(self.flip)
	else
		local image = self:getImage()
		if image then
			image:draw(self:getX(), self:getY(), self.flip)
		end
	end
end

-- ! Animation Playback Methods
-- Returns whether the sprite's animation is currently paused
function RoxySprite:getIsPaused()
	return self.isPaused
end

-- Sets the paused state of the sprite's animation
function RoxySprite:setIsPaused(isPaused)
	if type(isPaused) == "boolean" then
		self.isPaused = isPaused
	else
		warn("Warning: Expected a boolean for 'isPaused', but got " .. type(isPaused))
	end
end

-- Starts or resumes the sprite's animation from the beginning
function RoxySprite:play()
	if self.animation then
		self.isPaused = false
		self.animation:resetAnimationStart()
		self:setUpdatesEnabled(true)
	end
	return self
end

-- Starts the sprite's animation after a delay, optionally setting a specific animation
function RoxySprite:playWithDelay(delay, animationName)
	if self.animation and delay > 0 then
		-- Convert delay from seconds to milliseconds
		local millisecondsDelay = delay * 1000
		pd.timer.performAfterDelay(millisecondsDelay, function()
			self:setAnimation(animationName)
			self:play()
		end)
		self:setUpdatesEnabled(true)
	end
	return self
end

-- Pauses the sprite's animation
function RoxySprite:pause()
	if self.animation then
		self.isPaused = true
		self:setUpdatesEnabled(false)
	end
	return self
end

-- Toggles the play/pause state of the sprite's animation
function RoxySprite:togglePlayPause()
	if self.isPaused then
		self:play()
	else
		self:pause()
	end
	return self
end

-- Replays the sprite's animation from the start
function RoxySprite:replay()
	if self.animation then
		self.isPaused = false
		self.animation:resetAnimationStart()
		self.animation.currentFrame = self.animation.currentAnimation.startFrame
		self:setUpdatesEnabled(true)
	end
	return self
end

-- Stops the sprite's animation and resets it to the first frame
function RoxySprite:stop()
	if self.animation then
		self.isPaused = true
		self.animation:resetAnimationStart()
		self.animation.currentFrame = self.animation.currentAnimation.startFrame
		self:markDirty()
		self:setUpdatesEnabled(false)
	end
	return self
end

-- Reverses the direction of the sprite's animation
function RoxySprite:reverse()
	if self.animation then
		self.animation:reverse()
	else
		warn("Warning: Sprite is not animated.")
	end
	return self
end

-- ! Change Animation Speed
-- Returns the current speed of the sprite's animation
function RoxySprite:getSpeed()
	if self.animation then
		return self.animation:getSpeed()
	else
		warn("Warning: Sprite is not animated.")
		return nil
	end
end

-- Sets the speed of the sprite's animation, optionally affecting only the current animation
function RoxySprite:setSpeed(speed, currentOnly)
	if self.animation then
		self.animation:setSpeed(speed, currentOnly)
	else
		warn("Warning: Sprite is not animated.")
	end
	return self
end

-- ! Get and Set Animation Frame Duration
-- Returns the current frame duration of the sprite's animation
function RoxySprite:getFrameDuration()
	if self.animation then
		return self.animation:getFrameDuration()
	else
		warn("Warning: Sprite is not animated.")
		return nil
	end
end

-- Sets the frame duration of the sprite's animation, 
-- optionally affecting only the current animation
function RoxySprite:setFrameDuration(frameDuration, currentOnly)
	if self.animation then
		self.animation:setFrameDuration(frameDuration, currentOnly)
	else
		warn("Warning: Sprite is not animated.")
	end
	return self
end

-- ! Draw Specific Frame
-- Draws a specific frame of the sprite's animation, 
-- optionally pausing the animation
function RoxySprite:drawSpecificFrame(frame, andPause)
	if self.animation then
		if andPause then
			self:pause()
		end
		self.animation:jumpToSpecificFrame(frame)
		if self.isPaused then
			self:markDirty()
		end
	end
	return self
end

-- ! Step Frame
-- Steps the animation forward or backward by one frame
function RoxySprite:stepFrame(direction)
	if self.animation then
		self:pause()
		self.animation:stepFrame(direction)
		self:markDirty()
	end
	return self
end

-- ! Add and Remove Sprites
-- Adds the sprite to the scene
function RoxySprite:add()
	RoxySprite.super.add(self)
end

-- Stops animations and removes the sprite from the scene
function RoxySprite:remove()
	if self.isRoxySprite and self.animation then
		self:stop()
		self:setUpdatesEnabled(true)  -- Reset to default state
		self.animation = nil  -- Clear the animation reference
	end
	RoxySprite.super.remove(self)
end
