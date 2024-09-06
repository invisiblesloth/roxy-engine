local configurationManager <const> = ConfigurationManager.getInstance()
local sceneManager <const> = SceneManager.getInstance()

local pd <const> = playdate
local Object <const> = pd.object
local InputHandlers <const> = pd.inputHandlers
local UI <const> = pd.ui
local Input <const> = roxy.input

class("InputManager").extends()

-- Singleton instance for managing inputs globally
local instance = nil

function InputManager:init()
	self.currentHandler = nil
	self.isEnabled = true  -- InputManager starts in an enabled state
	self.buttonHoldBufferAmount = 3  -- Adjusts sensitivity of hold detection with number of frames
	self.buttonHoldCounts = {}
	self.customHoldThreshold = configurationManager:getConfig().customHoldThreshold or 20  -- Sets the frame count threshold for triggering custom hold actions for buttons
	self.crankIndicatorActive = false
	self.crankIndicatorForced = false
	self.defaultCrankDirection = configurationManager:getConfig().crankDirection or 1
	self.crankDirection = self.defaultCrankDirection
	
	self.counter = 0

	-- Set the button hold buffer amount and custom hold threshold in C
	Input.setButtonHoldBufferAmount(self.buttonHoldBufferAmount)
	Input.setCustomHoldThreshold(self.customHoldThreshold)
end

-- ! Set, Get, and Reset Handler
function InputManager:setHandler(handler)
	if self.currentHandler then
		InputHandlers.pop()
	end
	self.currentHandler = handler
	self:resetInputState()  -- Ensures the input state is fresh when changing handlers.
	if handler then
		InputHandlers.push(handler)
	end
end

function InputManager:getHandler()
	if self.currentHandler then
		return self.currentHandler
	end
end

function InputManager:resetInputState()
	self.buttonHoldCounts = {}  -- Resets the count of how long each button has been held.
end

-- ! Saving, Clearing, and Restoring Input Handlers
function InputManager:saveAndSetHandler(handler)
	self.previousHandler = self.currentHandler
	if handler then
		self:setHandler(handler)
	end
end

function InputManager:restoreHandler()
	if self.previousHandler then
		self:setHandler(self.previousHandler)
		self.previousHandler = nil
	end
end

function InputManager:clearHandler()
	if self.currentHandler then
		InputHandlers.pop()
		self.currentHandler = nil
	end
	self:resetInputState()
end

-- ! Crank Indicator
function InputManager:getCrankIndicatorStatus()
	return self.crankIndicatorActive, self.crankIndicatorForced
end

function InputManager:setCrankIndicatorStatus(active, evenWhenUndocked)
	self.crankIndicatorActive = active
	self.crankIndicatorForced = evenWhenUndocked or false
end

function InputManager:getCrankIndicator()
	return self.crankIndicatorActive
end

function InputManager:getCrankIndicatorForced()
	return self.crankIndicatorForced
end

function InputManager:resetCrankIndicatorAnimation()
	if UI.crankIndicator then
		UI.crankIndicator:resetAnimation()
	end
end

-- ! Crank Direction
function InputManager:getCrankDirection()
	return self.crankDirection
end

function InputManager:setCrankDirection(direction)
	if direction == 1 or direction == -1 then
		self.crankDirection = direction
	elseif direction == nil then
		-- Toggle the crank direction
		self.crankDirection = (self.crankDirection == 1) and -1 or 1
	else
		warn("Invalid crank direction: " .. tostring(direction) .. ". Direction must be either 1 or -1. crankDirection remains: " .. tostring(self.crankDirection))
	end
end

function InputManager:resetCrankDirection()
	print("resetting the crank direction back to :", self.defaultCrankDirection)
	self.crankDirection = self.defaultCrankDirection
end

-- ! Crank Docked
function InputManager:crankDocked()
	if self.isEnabled and self.currentHandler and self.currentHandler.crankDocked then
		self.currentHandler.crankDocked()
	end
end

function InputManager:crankUndocked()
	if self.isEnabled and self.currentHandler and self.currentHandler.crankUndocked then
		self.currentHandler.crankUndocked()
	end
end

-- ! Handle Input
-- Processes all button inputs and handles their state changes and hold actions
function InputManager:handleInput()
	-- Checks if there is a current handler and if the input manager is enabled
	if not self.currentHandler or not self.isEnabled then return end

	-- Define a list of button-specific processing functions
	local buttonFunctions = {
		Input.processButtonA,
		Input.processButtonB,
		Input.processButtonUp,
		Input.processButtonDown,
		Input.processButtonLeft,
		Input.processButtonRight
	}

	-- Iterate through each button-specific function and process the callback
	for i = 1, #buttonFunctions do
		local callback = buttonFunctions[i]()

		-- Call the appropriate function on the current handler if it exists
		if callback and callback ~= "" and self.currentHandler and self.currentHandler[callback] then
			self.currentHandler[callback]()
		end
	end
end

-- ! Get and Set isEnabled
function InputManager:getIsEnabled()
	return self.isEnabled
end

function InputManager:setIsEnabled(_isEnabled)
	if type(_isEnabled) == "boolean" then
		self.isEnabled = _isEnabled
	else
		warn("Warning: Expected a boolean for '_isEnabled', but got " .. type(_isEnabled))
	end
end

-- Singleton access method to get the instance of InputManager
-- @return The singleton instance of InputManager
function InputManager.getInstance()
	if not instance then
		instance = InputManager()
	end
	return instance
end