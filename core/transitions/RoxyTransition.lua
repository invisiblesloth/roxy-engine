local configurationManager <const> = ConfigurationManager.getInstance()
local sequenceManager <const> = SequenceManager.getInstance()
local sceneManager <const> = SceneManager.getInstance()
local inputManager <const> = InputManager.getInstance()
local transitionManager <const> = TransitionManager.getInstance()

local pd <const> = playdate
local Object <const> = pd.object
local Graphics <const> = pd.graphics
local Ease <const> = roxy.easingFunctions

local displayWidth, displayHeight, displayCenterX, displayCenterY = roxy.graphics.getDisplaySize()

-- ! BASE TRANSITION
-- Base class for all transitions, providing common properties and methods.
class("RoxyTransition").extends()

function RoxyTransition:init(duration, holdTime, properties)
	properties = properties or {}
	
	-- General properties
	self.name = properties.name or "Base"
	self.type = properties.type or "Cut"
	
	-- Positioning properties
	self.x = properties.x or 0
	self.y = properties.y or 0
	
	-- Timing properties
	self.duration = duration or properties.duration or 1.5
	self.holdTime = holdTime or properties.holdTime or 0.25
	
	-- Adjust total duration based on the configuration setting
	if configurationManager:getConfig().holdTimeAddsToDuration then
		self.duration = self.duration + self.holdTime
	end
	
	self.durationEnter = properties.durationEnter or self.duration / 2
	self.durationExit = properties.durationExit or self.durationEnter
	
	-- Screenshot capturing properties
	self.captureScreenshotsDuringTransition = properties.captureScreenshotsDuringTransition or false  -- Whether to capture screenshots during the transition
	self.newSceneScreenshot = nil  -- Placeholder for the new scene screenshot
	
	-- State properties
	self.midpointReached = false
	self.holdTimeElapsed = false
	
	-- Sequence properties
	self.sequence = nil
end

-- ! Execute the Transition
-- Executes the transition by managing the lifecycle of the current and new scenes.
function RoxyTransition:execute(newScene, currentScene)
	self.midpointReached = false  -- Ensure the transition always starts with midpointReached set to false
	
	local onStart = function()
		inputManager:clearHandler()  -- Reset input handler
		
		if currentScene then 
			currentScene:exit()  -- Exit the current scene
		end
	end

	local onMidpoint = function()
		self.midpointReached = true
		
		if currentScene then
			currentScene:cleanup()  -- Clean up the current scene
			currentScene = nil
		end
		
		sceneManager:setCurrentScene(newScene)  -- Set the new scene
		
		newScene:resetDrawOffset()
		newScene:enter()  -- Enter the new scene
	end

	local onHoldTimeElapsed = function()
		self.holdTimeElapsed = true
	end

	local onComplete = function()
		newScene:start()  -- Start the new scene
		
		transitionManager:setIsTransitioning(false)  -- Mark transition as complete
		transitionManager.currentTransition:cleanup()  -- Cleanup the current transition
		transitionManager.currentTransition = nil  -- Reset the transition
	end
	
	-- Set up the transition sequence
	self:setUpSequence(onStart, onMidpoint, onHoldTimeElapsed, onComplete)
end

-- Placeholder methods to be implemented in derived classes
function RoxyTransition:setUpSequence(onStart, onMidpoint, onHoldTimeElapsed, onComplete)
	-- Implement sequence setup logic in derived classes
end

function RoxyTransition:draw()
	-- Implement draw logic in derived classes
end

-- Determines if a screenshot is needed for the transition
function RoxyTransition:getCaptureScreenshotsDuringTransition()
	return self.captureScreenshotsDuringTransition
end

function RoxyTransition:cleanup()
	-- Implement cleanup logic in derived classes
end

-- ! CUT TRANSITION
-- A transition that instantly switches from the current scene to the new scene.
class("RoxyCutTransition").extends(RoxyTransition)

function RoxyCutTransition:init(duration, holdTime, properties)
	properties = properties or {}
	properties.name = properties.name or "Cut"
	properties.type = properties.type or "Cut"
	properties.duration = duration or properties.duration or 0  -- Duration is typically 0 for a cut
	properties.holdTime = holdTime or properties.holdTime or 0  -- No hold time for a cut

	RoxyCutTransition.super.init(self, properties.duration, properties.holdTime, properties)
end

-- ! Set Up Cut Transition Sequence
-- A cut transition is instantaneous, so all steps occur immediately.
function RoxyCutTransition:setUpSequence(onStart, onMidpoint, onHoldTimeElapsed, onComplete)
	onStart()
	onMidpoint()
	onHoldTimeElapsed()
	onComplete()
end

-- ! COVER TRANSITION
-- A transition that "covers" the current scene with a panel image 
-- before revealing the new scene.
class("RoxyCoverTransition").extends(RoxyTransition)

function RoxyCoverTransition:init(duration, holdTime, properties)
	properties = properties or {}
	properties.name = properties.name or "Cover"
	properties.type = properties.type or "Cover"
	properties.duration = duration or properties.duration or 1.5
	properties.holdTime = holdTime or properties.holdTime or 0.25
	
	-- Easing properties
	self.ease = properties.ease or Ease.linear
	self.easeEnter = Ease.enter(self.ease) or self.ease
	self.easeExit = Ease.exit(self.ease) or self.ease
	
	-- Graphics properties
	self.drawMode = properties.drawMode or Graphics.kDrawModeCopy
	self.dither = 
		properties.dither or 
		transitionManager:getDither("bayer8x8") or 
		Graphics.image.kDitherTypebayer8x8  -- Fallback dither type
	self.panelImage = 
		properties.panelImage or 
		transitionManager:getImage("panelImage") or 
		Graphics.image.new(displayWidth, displayHeight, Graphics.kColorBlack)  -- Fallback to a black panel
	
	-- Sequence properties
	self.sequenceStartValue = properties.sequenceStartValue or 0
	self.sequenceMidpointValue = properties.sequenceMidpointValue or 1
	self.sequenceResumeValue = properties.sequenceResumeValue or 1
	self.sequenceCompleteValue = properties.sequenceCompleteValue or 0
	
	RoxyCoverTransition.super.init(self, properties.duration, properties.holdTime, properties)
end

-- ! Set Up Cover Transition Sequence
-- Sets up the sequence of actions that occur during the cover transition.
function RoxyCoverTransition:setUpSequence(onStart, onMidpoint, onHoldTimeElapsed, onComplete)
	self.sequence = transitionManager:getSequence()
		:from(self.sequenceStartValue)
		:to(self.sequenceMidpointValue, self.durationEnter - (self.holdTime / 2), self.easeEnter)
		:callback(onMidpoint)
		:sleep(self.holdTime)
		:callback(onHoldTimeElapsed)
		:to(self.sequenceResumeValue, 0)
		:to(self.sequenceCompleteValue, self.durationExit - (self.holdTime / 2), self.easeExit)
		:callback(onComplete)
	
	onStart()
	self.sequence:start()
end

function RoxyCoverTransition:draw()
	-- Draw the panel image with fading effect
	self.panelImage:drawFaded(self.x, self.y, self.sequence:getValue(), self.dither)
end

function RoxyCoverTransition:cleanup()
	transitionManager:recycleDither("bayer8x8", self.dither)  -- Recycle the dither pattern
	transitionManager:recycleSequence(self.sequence)  -- Recycle the sequence
	self.sequence = nil  -- Remove the transition sequencer
end

-- ! IMAGE TABLE TRANSITION
-- A transition that uses an image table to create an animation effect between scenes.
class("RoxyImagetableTransition").extends(RoxyTransition)

function RoxyImagetableTransition:init(duration, holdTime, properties)
	properties = properties or {}
	properties.name = properties.name or "Imagetable"
	properties.type = properties.type or "Imagetable"
	properties.duration = duration or properties.duration or 1.5
	properties.holdTime = holdTime or properties.holdTime or 0
	
	-- Easing properties
	self.ease = Ease.linear  -- Imagetable transitions always use linear easing
	if properties.ease ~= nil or properties.easeEnter ~= nil or properties.easeExit ~= nil then
		warn("Warning: 'Imagetable' type transitions alwyas only use linear easing.")
	end
	
	-- Graphics properties
	self.drawMode = properties.drawMode or Graphics.kDrawModeCopy
	
	-- Image table properties
	self.imagetable = properties.imagetable or nil  -- Optional imagetable for the entire transition
	self.imagetableEnter =  -- Imagetable for entering the scene
		properties.imagetableEnter or 
		transitionManager:getImagetable("imagetableEnter") or 
		Graphics.imagetable.new("libraries/roxy/assets/images/SLOTHUniversalLeaderEnter")
	self.imagetableExit =  -- Imagetable for exiting the scene
		properties.imagetableExit or 
		transitionManager:getImagetable("imagetableExit") or 
		Graphics.imagetable.new("libraries/roxy/assets/images/SLOTHUniversalLeaderExit")
	
	if not self.imagetable and (not self.imagetableEnter or not self.imagetableExit) then
		warn("Warning: Either 'imagetable' or both 'imagetableEnter' and 'imagetableExit' must be provided for Imagetable transitions.")
	end
	
	-- Transformation properties
	self.reverse = properties.reverse or false
	self.reverseEnter = properties.reverseEnter or false
	self.reverseExit = properties.reverseExit or false
	self.flipX = properties.flipX or false
	self.flipY = properties.flipY or false
	self.flipXEnter = properties.flipXEnter or false
	self.flipYEnter = properties.flipYEnter or false
	self.flipXExit = properties.flipXExit or false
	self.flipYExit = properties.flipYExit or false
	self.rotate = properties.rotate or false
	self.rotateEnter = properties.rotateEnter or false
	self.rotateExit = properties.rotateExit or false
	
	-- Calculated transformation values
	self.flipValueEnter = self:getFlipValue(self.rotateEnter, self.flipXEnter, self.flipYEnter)  -- Flip value for entering the scene
	self.flipValueExit = self:getFlipValue(self.rotateExit, self.flipXExit, self.flipYExit)  -- Flip value for exiting the scene
	
	-- Frame count properties
	self.frameCountEnter = self.imagetableEnter and #self.imagetableEnter or 0  -- Frame count for entering the scene
	self.frameCountExit = self.imagetableExit and #self.imagetableExit or 0  -- Frame count for exiting the scene
	
	-- Sequence properties
	local sequence0 = not self.reverseEnter and 0 or 1
	local sequence1 = not self.reverseEnter and 1 or 0
	local sequenceExit0 = not self.reverseExit and 0 or 1
	local sequenceExit1 = not self.reverseExit and 1 or 0
	if self.imagetableEnter == self.imagetableExit then
		self.sequenceStartValue = sequence0
		self.sequenceMidpointValue = sequence1
		self.sequenceResumeValue = sequence1
		self.sequenceCompleteValue = sequence0
	else
		self.sequenceStartValue = sequence0
		self.sequenceMidpointValue = sequence1
		self.sequenceResumeValue = sequenceExit0
		self.sequenceCompleteValue = sequenceExit1
	end
	
	RoxyImagetableTransition.super.init(self, properties.duration, properties.holdTime, properties)
end

-- ! Set Up Image Table Transition Sequence
-- Sets up the sequence of actions that occur during the imagetable transition.
function RoxyImagetableTransition:setUpSequence(onStart, onMidpoint, onHoldTimeElapsed, onComplete)
	self.sequence = transitionManager:getSequence()
		:from(self.sequenceStartValue)
		:to(self.sequenceMidpointValue, self.durationEnter - (self.holdTime / 2), self.ease)
		:callback(onMidpoint)
		:sleep(self.holdTime)
		:callback(onHoldTimeElapsed)
		:to(self.sequenceResumeValue, 0)
		:to(self.sequenceCompleteValue, self.durationExit - (self.holdTime / 2), self.ease)
		:callback(onComplete)
	
	onStart()
	self.sequence:start()
end

function RoxyImagetableTransition:draw()
	local progress = self.sequence:getValue()
	
	local imagetable
	local frameCount
	local flipValue
	if not self.holdTimeElapsed then
		imagetable = self.imagetableEnter
		frameCount = self.frameCountEnter
		flipValue = self.flipValueEnter
	else
		imagetable = self.imagetableExit
		frameCount = self.frameCountExit
		flipValue = self.flipValueExit
	end
	local index = roxy.math.clamp((progress * frameCount) // 1, 1, frameCount)  -- Calculate the frame index based on the progress
	imagetable[index]:draw(0, 0, flipValue)
end

-- Gets the flip value for the imagetable
function RoxyImagetableTransition:getFlipValue(rotate, flipX, flipY)
	if rotate or (flipX and flipY) then
		return Graphics.kImageFlippedXY
	else
		if flipX then
			return Graphics.kImageFlippedX
		elseif flipY then
			return Graphics.kImageFlippedY
		end
	end
	return Graphics.kImageUnflipped
end

function RoxyImagetableTransition:cleanup()
	if self.imagetable then
		transitionManager:recycleImagetable("imagetable", self.imagetable)  -- Recycle the imagetable if it was used
	end
	transitionManager:recycleImagetable("imagetableEnter", self.imagetableEnter)  -- Recycle the imagetable for entering the scene
	transitionManager:recycleImagetable("imagetableExit", self.imagetableExit)  -- Recycle the imagetable for exiting the scene
	transitionManager:recycleSequence(self.sequence)  -- Recycle the sequence
	self.sequence = nil  -- Remove the transition sequencer
end

-- ! MIX TRANSITION
-- A transition that blends the current scene into the new scene using a screenshot.
class("RoxyMixTransition").extends(RoxyTransition)

function RoxyMixTransition:init(duration, holdTime, properties)
	properties = properties or {}
	properties.name = properties.name or "Mix"
	properties.type = properties.type or "Mix"
	
	-- Adjust the duration based on the configuration setting
	if not configurationManager:getConfig().useFullDurationForMixTransitions then
		duration = (duration or properties.duration or 1.5) / 2
	else
		duration = duration or properties.duration or 1.5
	end
	
	properties.duration = duration or properties.duration or 1.5
	properties.holdTime = holdTime or properties.holdTime or 0.25
	
	-- Easing properties
	self.ease = properties.ease or Ease.linear  -- Default easing function
	if properties.easeEnter ~= nil or properties.easeExit ~= nil then
		warn("Warning: 'easeEnter' and 'easeExit' are ignored for 'Mix' type. Use 'ease' instead.")
	end
	
	-- Graphics properties
	self.drawMode = properties.drawMode or Graphics.kDrawModeCopy
	self.dither = 
		properties.dither or 
		transitionManager:getDither("bayer8x8") or 
		Graphics.image.kDitherTypebayer8x8  -- Fallback dither type
	
	self.currentSceneScreenshot = Graphics.getDisplayImage()  -- Capture screenshot for transition effect
	
	-- Sequence properties
	self.sequenceStartValue = properties.sequenceStartValue or 0
	self.sequenceCompleteValue = properties.sequenceCompleteValue or 1

	RoxyMixTransition.super.init(self, properties.duration, properties.holdTime, properties)
end

-- ! Set Up Mix Transition Sequence
-- Sets up the sequence of actions that occur during the mix transition.
function RoxyMixTransition:setUpSequence(onStart, onMidpoint, onHoldTimeElapsed, onComplete)
	self.sequence = transitionManager:getSequence()
		:from(self.sequenceStartValue)
		:to(self.sequenceCompleteValue, self.duration, self.ease)
		:callback(onComplete)
	
	onStart()
	onMidpoint()
	onHoldTimeElapsed()
	self.sequence:start()
end

function RoxyMixTransition:draw()
	local currentSceneScreenshot = self.currentSceneScreenshot
	if currentSceneScreenshot then
		currentSceneScreenshot:drawFaded(0, 0, 1 - self.sequence:getValue(), self.dither)  -- Draw the screenshot with a fading effect
	end
end

function RoxyMixTransition:cleanup()
	transitionManager:recycleDither("bayer8x8", self.dither)  -- Recycle the dither pattern
	transitionManager:recycleSequence(self.sequence)  -- Recycle the sequence
	self.sequence = nil  -- Remove the transition sequencer
end
