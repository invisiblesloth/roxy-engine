local configurationManager <const> = ConfigurationManager.getInstance()
local sequenceManager <const> = SequenceManager.getInstance()
local sceneManager <const> = SceneManager.getInstance()
local inputManager <const> = InputManager.getInstance()

local pd <const> = playdate
local Object <const> = pd.object
local Graphics <const> = pd.graphics
local Timer <const> = pd.timer

local displayWidth, displayHeight, displayCenterX, displayCenterY = roxy.graphics.getDisplaySize()

class("TransitionManager").extends()

-- Singleton instance for managing transitions globally
local instance = nil

function TransitionManager:init()
	self.transitions = {}
	self.currentTransition = nil
	self.isTransitioning = false
	self.pools = {  -- Object pools to optimize resource management
		imagetables = {
			imagetable = {},
			imagetableEnter = {},
			imagetableExit = {}
		},
		images = {
			panelImageBlack = {},
			panelImageWhite = {}
		},
		ditherPatterns = {
			bayer8x8 = {}
		},
		sequences = {}
	}
	self:populatePools(3)  -- Initialize pools with default size
end

function TransitionManager:populatePools(poolSize)
	-- Preload objects into the pools to optimize performance and reduce load times
	for i = 1, poolSize or 1 do
		self:recycleImagetable("imagetable", Graphics.imagetable.new("libraries/roxy/assets/images/SLOTHUniversalLeaderEnter"))
		self:recycleImagetable("imagetableEnter", Graphics.imagetable.new("libraries/roxy/assets/images/SLOTHUniversalLeaderEnter"))
		self:recycleImagetable("imagetableExit", Graphics.imagetable.new("libraries/roxy/assets/images/SLOTHUniversalLeaderExit"))
		self:recycleImage("panelImageBlack", Graphics.image.new(displayWidth, displayHeight, Graphics.kColorBlack))
		self:recycleImage("panelImageWhite", Graphics.image.new(displayWidth, displayHeight, Graphics.kColorWhite))
		self:recycleDither("bayer8x8", Graphics.image.kDitherTypeBayer8x8)
		self:recycleSequence(RoxySequence())
	end
end

-- ! Load Transitions
function TransitionManager:loadTransitions(transitionsTable)
	-- Load and validate a table of transitions for use in scene changes
	if type(transitionsTable) ~= "table" then
		error("ERROR: transitionsTable must be a table.")
	end
	
	for key, value in pairs(transitionsTable) do
		if type(key) ~= "string" then
			error("ERROR: Transition key must be a string.")
		end
		if type(value) ~= "table" or not value.__index then
			error("ERROR: Transition value must be a valid class.")
		end
	end
	
	self.transitions = transitionsTable  -- Store the transitions for later use
end

-- ! Transition to Scene
function TransitionManager:transitionToScene(newSceneClass, transitionName, duration, holdTime, properties)
	if self.isTransitioning then
		warn("Warning: Transition already in progress.")
		return
	end
	
	self.isTransitioning = true
	
	local newScene = newSceneClass()
	-- Validate the new scene object
	if not newScene then
		error("ERROR: newScene is not properly instantiated or missing methods.")
	end
	
	local currentScene = sceneManager:getCurrentScene() or nil
	
	-- Retrieve the transition class using the transition name; 
	-- use the default if unspecified or not found
	local transition = self.transitions[transitionName] or self.transitions[configurationManager:getConfig().defaultTransition]
	if not transition then
		error("ERROR: Transition type '" .. tostring(transitionName) .. "' is not defined.")
	end
	
	-- Create the transition instance and execute it
	self.currentTransition = transition(duration, holdTime, properties)
	self.currentTransition:execute(newScene, currentScene)
end

-- Prepares the transition screenshot if needed
function TransitionManager:prepareTransitionScreenshot()
	if not self.currentTransition then
		return
	end
	
	self.currentTransition.newSceneScreenshot = Graphics.image.new(displayWidth, displayHeight)
	Graphics.pushContext(self.currentTransition.newSceneScreenshot)  -- Push context for capturing the screenshot
end

-- ! Draw the Transition
function TransitionManager:executeTransitionDrawing()
	-- Execute the drawing logic for the current transition
	if not self.isTransitioning or not self.currentTransition then
		return
	end

	local currentTransition = self.currentTransition
	if currentTransition.captureScreenshotsDuringTransition then
		Graphics.popContext()  -- Pop context after capturing the screenshot
	end
	
	local drawMode = currentTransition.drawMode or Graphics.kDrawModeCopy  -- Ensure drawMode is valid
	Graphics.setImageDrawMode(drawMode)
	currentTransition:draw()
	Graphics.setImageDrawMode(Graphics.kDrawModeCopy)  -- Reset image draw mode to default
end

-- ! Get and Set isTransitioning
function TransitionManager:getIsTransitioning()
	return self.isTransitioning  -- Return the transition state
end

function TransitionManager:setIsTransitioning(_isTransitioning)
	-- Set the transition state if the provided value is a boolean
	if type(_isTransitioning) == "boolean" then
		self.isTransitioning = _isTransitioning
	else
		warn("Warning: Expected a boolean for '_isTransitioning', but got " .. type(_isTransitioning))
	end
end

-- ! Object Pool Methods

-- Image tables
function TransitionManager:getImagetable(type)
	-- Retrieve an imagetable from the pool based on its type
	local imagetablePool = self.pools.imagetables
	if type == "imagetable" and #imagetablePool.imagetable > 0 then
		return table.remove(imagetablePool.imagetable)
	elseif type == "imagetableEnter" and #imagetablePool.imagetableEnter > 0 then
		return table.remove(imagetablePool.imagetableEnter)
	elseif type == "imagetableExit" and #imagetablePool.imagetableExit > 0 then
		return table.remove(imagetablePool.imagetableExit)
	else
		warn("Warning: No imagetable available for type: " .. tostring(type))
		return nil
	end
end

function TransitionManager:recycleImagetable(type, imagetable)
	-- Return an imagetable to the appropriate pool for reuse
	local imagetablePool = self.pools.imagetables
	if type == "imagetable" then
		table.insert(imagetablePool.imagetable, imagetable)
	elseif type == "imagetableEnter" then
		table.insert(imagetablePool.imagetableEnter, imagetable)
	elseif type == "imagetableExit" then
		table.insert(imagetablePool.imagetableExit, imagetable)
	else
		warn("Invalid imagetable type: " .. tostring(type))
	end
end

-- Images
function TransitionManager:getImage(type)
	-- Retrieve an image from the pool based on its type
	local imagePool = self.pools.images
	if type == "panelImageBlack" and #imagePool.panelImageBlack > 0 then
		return table.remove(imagePool.panelImageBlack)
	elseif type == "panelImageWhite" and #imagePool.panelImageWhite > 0 then
		return table.remove(imagePool.panelImageWhite)
	else
		warn("Warning: No image available for type: " .. tostring(type))
		return nil
	end
end

function TransitionManager:recycleImage(type, image)
	-- Return an image to the appropriate pool for reuse
	local imagePool = self.pools.images
	if type == "panelImageBlack" then
		table.insert(imagePool.panelImageBlack, image)
	elseif type == "panelImageWhite" then
		table.insert(imagePool.panelImageWhite, image)
	else
		warn("Warning: Invalid image type: " .. tostring(type))
	end
end

-- Dither patterns
function TransitionManager:getDither(type)
	-- Retrieve a dither pattern from the pool based on its type
	local ditherPool = self.pools.ditherPatterns
	if type == "bayer8x8" and #ditherPool.bayer8x8 > 0 then
		return table.remove(ditherPool.bayer8x8)
	else
		warn("Warning: No dither pattern available for type: " .. tostring(type))
		return nil
	end
end

function TransitionManager:recycleDither(type, ditherPattern)
	-- Return a dither pattern to the appropriate pool for reuse
	local ditherPool = self.pools.ditherPatterns
	if type == "bayer8x8" then
		table.insert(ditherPool.bayer8x8, ditherPattern)
	else
		warn("Warning: Invalid dither pattern type: " .. tostring(type))
	end
end

-- Sequences
function TransitionManager:getSequence()
	-- Retrieve a sequence from the pool, or create a new one if the pool is empty
	local sequencePool = self.pools.sequences
	if #sequencePool > 0 then
		return table.remove(sequencePool)
	else
		return RoxySequence()
	end
end

function TransitionManager:recycleSequence(sequence)
	-- Reset and return a sequence to the pool for reuse
	sequence:clear()
	table.insert(self.pools.sequences, sequence)
end

-- Singleton access method to get the instance of TransitionManager
-- @return The singleton instance of TransitionManager
function TransitionManager.getInstance()
	if not instance then
		instance = TransitionManager()  -- Create the instance if it doesn't exist
	end
	return instance
end
