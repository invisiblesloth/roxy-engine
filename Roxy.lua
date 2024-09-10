-- Roxy Game Engine
-- version: 0.5.0
-- License: MIT

-- Import Playdate SDK core libraries
import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/sprites"
import "CoreLibs/crank"
import "CoreLibs/animation"
import "CoreLibs/animator"
import "CoreLibs/easing"
import "CoreLibs/timer"
import "CoreLibs/frameTimer"
import "CoreLibs/ui/crankIndicator"
import "CoreLibs/ui/gridview"

-- Import Roxy utility libraries
import "libraries/roxy/utilities/roxyTables"
import "libraries/roxy/utilities/roxyMath"
import "libraries/roxy/utilities/roxyJson"
import "libraries/roxy/utilities/roxyGraphics"
import "libraries/roxy/utilities/roxyText"
import "libraries/roxy/utilities/roxyEase"

-- Import Roxy managers
import "libraries/roxy/core/managers/ConfigurationManager"
import "libraries/roxy/core/managers/SettingsManager"
import "libraries/roxy/core/managers/GameDataManager"
import "libraries/roxy/core/managers/SequenceManager"
import "libraries/roxy/core/managers/SceneManager"
import "libraries/roxy/core/managers/InputManager"
import "libraries/roxy/core/managers/TransitionManager"

-- Import Roxy core components
import "libraries/roxy/core/sequences/RoxySequence"
import "libraries/roxy/core/sprites/RoxySprite"
import "libraries/roxy/core/animations/RoxyAnimation"
import "libraries/roxy/core/scenes/RoxyScene"
import "libraries/roxy/core/ui/RoxyMenu"

-- Singleton instances for managers
local configurationManager <const> = ConfigurationManager.getInstance()
local settingsManager <const> = SettingsManager.getInstance()
local gameDataManager <const> = GameDataManager.getInstance()
local sequenceManager <const> = SequenceManager.getInstance()
local sceneManager <const> = SceneManager.getInstance()
local inputManager <const> = InputManager.getInstance()
local transitionManager <const> = TransitionManager.getInstance()

-- Import transition types
import "libraries/roxy/core/transitions/RoxyTransition"
import "libraries/roxy/core/transitions/Cut"
import "libraries/roxy/core/transitions/CrossDissolve"
import "libraries/roxy/core/transitions/FadeToBlack"
import "libraries/roxy/core/transitions/FadeToWhite"
import "libraries/roxy/core/transitions/Imagetable"

-- Aliases for performance
local pd <const> = playdate
local Object <const> = pd.object
local InputHandlers <const> = pd.inputHandlers
local Display <const> = pd.display
local Graphics <const> = pd.graphics
local Sprite <const> = Graphics.sprite
local Timer <const> = pd.timer
local FrameTimer <const> = pd.frameTimer
local Ease <const> = pd.easingFunctions
local Geometry <const> = pd.geometry
local UI <const> = pd.ui

-- Get display dimensions and center coordinates
local displayWidth, displayHeight, displayCenterX, displayCenterY = roxy.graphics.getDisplaySize()

class("Roxy").extends()

-- ! Initialize Roxy
function Roxy:init()
	self.engineInitialized = false
	self.showFPS = false
	self.fpsPosition = "bottomRight" -- Default FPS position
	self:setFpsXY()
end

-- Set FPS display coordinates based on current fpsPosition
function Roxy:setFpsXY()
	local positions = {
		topRight = {x = displayWidth - 15, y = 0},
		bottomLeft = {x = 0, y = displayHeight - 12},
		bottomRight = {x = displayWidth - 15, y = displayHeight - 12}
	}

	local position = positions[self.fpsPosition] or {x = 0, y = 0}  -- Default to (0, 0) if position is not recognized
	self.fpsX = position.x
	self.fpsY = position.y
end

-- Update FPS display position based on a new setting
function Roxy:updateFpsPosition(newPosition)
	self.fpsPosition = newPosition
	self:setFpsXY()
end

-- ! Roxy Configuration
-- Get the current configuration settings from the configuration manager
function Roxy:getConfig()
	return configurationManager:getConfig()
end

-- Set new configuration parameters through the configuration manager
function Roxy:setConfig(config)
	configurationManager:setConfig(config)
end

-- Reset the configuration to default values using the configuration manager
function Roxy:resetConfig()
	configurationManager:resetConfig()
end

-- Register scenes with the scene manager
function Roxy:registerScenes(...)
	local args = {...}
	sceneManager:registerScenes(table.unpack(args))
end

-- ! Start a New Game
function Roxy:new(startingSceneClass, startingTransitionName, startingTransitionDuration, startingTransitionHoldTime, startingTransitionProperties, configuration)
	if self.engineInitialized then
		error("ERROR: You can only run 'Roxy:new()' once.")  -- Ensure the game is only initialized once
	end
	
	math.randomseed(pd.getSecondsSinceEpoch())
	
	-- Configure the game engine settings, either from the provided configuration or default
	if configuration then
		self:setConfig(configuration)
	else
		self:resetConfig()
	end
	local config = self:getConfig()
	
	-- Load predefined transitions into the transition manager
	local transitions = {
		Cut = Cut,
		CrossDissolve = CrossDissolve,
		FadeToBlack = FadeToBlack,
		FadeToWhite = FadeToWhite,
		Imagetable = Imagetable
	}
	transitionManager:loadTransitions(transitions)
	
	-- Set the scene's background drawing callback
	sceneManager:setUpBackgroundDrawing()
	
	-- Set default transition parameters if they are not provided
	startingTransitionDuration = startingTransitionDuration or config.defaultTransitionDuration
	startingTransitionProperties = startingTransitionProperties or {}
	
	-- Set up the game menu
	local menu = pd.getSystemMenu()
	local menuItem, error = menu:addMenuItem("Game Menu", function()
		transitionManager:transitionToScene(MainMenu)
	end)
	if error then
		error("ERROR: Problem adding menu item: " .. error)
	end
	
	-- Configure FPS display settings from the current configuration
	self.showFPS = config.showFPS
	self:updateFpsPosition(config.fpsPosition or self.fpsPosition)
	
	Graphics.setBackgroundColor(Graphics.kColorWhite)
	
	-- Initialize the game engine and start the game
	self.engineInitialized = true
	transitionManager:transitionToScene(startingSceneClass, startingTransitionName, startingTransitionDuration, startingTransitionHoldTime, startingTransitionProperties)
	self:setUpGameLoop()
end

-- ! Set Up Game Settings
-- Configure game settings with optional saving and updating features
function Roxy:settingsSetup(settings, saveToDisk, updateSettingsIfChanged, retainOldKeys)
	if settingsManager and settingsManager.setup then
		settingsManager:setup(settings, saveToDisk, updateSettingsIfChanged, retainOldKeys)
	end
end

-- ! Set Up Game Data
-- Configure game data with optional slot management and saving features
function Roxy:gameDataSetup(gameData, numberOfSlots, saveToDisk, modifyExistingData)
	if gameDataManager and gameDataManager.setup then
		gameDataManager:setup(gameData, numberOfSlots, saveToDisk, modifyExistingData)
	end
end

-- Toggle FPS display on or off
function Roxy:setShowFPS(show)
	self.showFPS = show
end

-- ! Main Update Loop
function Roxy:update()
	local deltaTime = roxy.updateDeltaTime()  -- Calculate delta time for the current frame
	
	local isTransitioning = transitionManager:getIsTransitioning()
	local currentTransition = transitionManager.currentTransition
	
	-- Handle user input through the input manager
	inputManager:handleInput()
	
	-- Update all active animation sequences
	sequenceManager:update(deltaTime)
	
	-- Capture transition screenshots if required
	if isTransitioning and currentTransition:getCaptureScreenshotsDuringTransition() then
		transitionManager:prepareTransitionScreenshot()
	end
	
	-- Update sprites and manage background layers
	Sprite.update()
	
	-- Update the current scene if it is not paused
	local currentScene = sceneManager:getCurrentScene()
	if currentScene and not currentScene.isPaused then
		currentScene:update()
	end
	
	-- Execute transition drawing logic
	transitionManager:executeTransitionDrawing()
	
	-- Draw the crank indicator if it is enabled and necessary
	local crankIndicator = inputManager:getCrankIndicator()
	if crankIndicator and (pd.isCrankDocked() or inputManager:getCrankIndicatorForced()) then
		UI.crankIndicator:draw()
	end
	
	-- Display FPS if it is enabled
	if self.showFPS then
		pd.drawFPS(self.fpsX, self.fpsY)
	end
	
	-- Update all SDK timers
	Timer.updateTimers()
	FrameTimer.updateTimers()
end

-- Set up the main update loop for the game
function Roxy:setUpGameLoop()
	pd.update = function()
		self:update()
	end
end

-- ! Pause and Resume
-- Handle game pause by invoking the pause method on the current scene if it exists
function Roxy:gameWillPause()
	if sceneManager:getCurrentScene() and sceneManager:getCurrentScene().pause then
		sceneManager:getCurrentScene():pause()
	end
end

-- Handle game resume by invoking the resume method on the current scene if it exists
function Roxy:gameWillResume()
	if sceneManager:getCurrentScene() and sceneManager:getCurrentScene().resume then
		sceneManager:getCurrentScene():resume()
	end
end
