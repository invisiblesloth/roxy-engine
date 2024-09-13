local sequenceManager <const> = SequenceManager.getInstance()
local inputManager <const> = InputManager.getInstance()

local pd <const> = playdate
local Object <const> = pd.object
local Graphics <const> = pd.graphics
local Sprite <const> = Graphics.sprite

local displayWidth, displayHeight, displayCenterX, displayCenterY = roxy.graphics.getDisplaySize()

class("RoxyScene").extends()

function RoxyScene:init(background)
	self.name = self.className
	self.backgroundColor = nil
	self.backgroundImage = nil
	self.sprites = {}  -- Table to hold sprites associated with this scene
	self.sequences = {}  -- Table to hold sequences associated with this scene
	self.inputHandler = {}  -- Input handler for managing user inputs specific to this scene
	self.isPaused = false
	
	-- Set the background if provided, otherwise disable background drawing
	if background then
		self.shouldDrawBackground = true
		self:setBackground(background)
	else
		self.shouldDrawBackground = false  -- Disable background drawing if no background is provided
	end
end

-- ! Enter Scene (onMidpoint)
function RoxyScene:enter()
	self:setInputHandler()  -- Set up input handling when entering the scene
end

-- Set Background Color or Image
function RoxyScene:setBackground(background)
	if type(background) == "number" then
		-- Set background as a color
		self.backgroundColor = background
		self.backgroundImage = nil
	elseif type(background) == "userdata" then
		-- Set background as an image
		self.backgroundImage = background
		self.backgroundColor = nil
	else
		warn("Invalid background type: must be a number (color) or userdata (image). Background not set.")
		return
	end
	Sprite.redrawBackground()  -- Force the background to redraw
	self.shouldDrawBackground = true  -- Enable background drawing
end

function RoxyScene:setInputHandler()
	if inputManager and self.inputHandler then
		-- Assign the scene-specific input handler to the input manager
		inputManager:setHandler(self.inputHandler)
	end
end

-- ! Start Scene (onComplete)
function RoxyScene:start()
	-- Placeholder: Implement specific logic when starting the scene in derived classes
end

-- ! Pause and Resume Scene
function RoxyScene:pause()
	self.isPaused = true  -- Mark the scene as paused
	for i = #self.sprites, 1, -1 do
		local sprite = self.sprites[i]
		-- Pause all sprites and disable their updates and collisions
		sprite:pause()
		sprite:setUpdatesEnabled(false)
		sprite:setCollisionsEnabled(false)
	end
end

function RoxyScene:resume()
	self.isPaused = false  -- Mark the scene as active
	for i = #self.sprites, 1, -1 do
		local sprite = self.sprites[i]
		-- Resume all sprites and enable their updates and collisions
		sprite:play()
		sprite:setUpdatesEnabled(true)
		sprite:setCollisionsEnabled(true)
	end
end

-- ! Exit Scene (onStart)
function RoxyScene:exit()
	-- Placeholder: Implement specific logic when exiting the scene in derived classes
end

-- ! Clean Up Scene (onMidpoint)
function RoxyScene:cleanup()
	for i = #self.sprites, 1, -1 do
		local sprite = self.sprites[i]
		-- Pause and disable all sprites before removal
		sprite:pause()
		sprite:setUpdatesEnabled(false)
		sprite:setCollisionsEnabled(false)
	end
	self:removeAllSprites()  -- Remove all sprites from the scene
	self:removeAllSequence()  -- Remove all the sequences from the scene
	self:clearScreen()  -- Clear the screen
	self:resetDrawOffset()  -- Reset the drawing offset
end

-- ! Draw Background
function RoxyScene:drawBackground(x, y, width, height)
	if self.shouldDrawBackground then
		if self.backgroundImage then
			-- Draw the background image at the specified coordinates
			x = x or 0
			y = y or 0
			self.backgroundImage:draw(x, y)
		else
			-- Clear the screen with the background color
			Graphics.clear(self.backgroundColor)
		end
	end
end

-- ! Update Scene
function RoxyScene:update()
	-- Placeholder: Implement specific logic to update the scene in derived classes
end

-- ! Add and Remove Sprites
function RoxyScene:addSprite(sprite)
	sprite:add()  -- Add the sprite to the scene's sprite list

	-- Add the sprite to the internal list if it's not already present
	if not table.indexOfElement(self.sprites, sprite) then
		table.insert(self.sprites, sprite)
	end
end

function RoxyScene:removeSprite(sprite)
	sprite:remove()  -- Remove the sprite from the scene's sprite list

	-- Find and remove the sprite from the internal list
	local index = table.indexOfElement(self.sprites, sprite)
	if index then
		table.remove(self.sprites, index)
	end
end

function RoxyScene:removeAllSprites()
	-- Iterate in reverse to safely remove all sprites
	for i = #self.sprites, 1, -1 do
		self:removeSprite(self.sprites[i])
	end
end

-- ! Add and Remove Sequences
function RoxyScene:addSequence(sequence)
	if sequence and not table.indexOfElement(self.sequences, sequence) then
		sequence:start()
		-- Add the sequence to the internal list if it's not already present
		table.insert(self.sequences, sequence)
	end
end

function RoxyScene:removeSequence(sequence)
	local index = table.indexOfElement(self.sequences, sequence)
	if index then
		sequence:stop()
		table.remove(self.sequences, index)
	end
end

function RoxyScene:removeAllSequence()
	-- Iterate in reverse to safely remove all sequences
	for i = #self.sequences, 1, -1 do
		self:removeSequence(self.sequences[i])
	end
end

function RoxyScene:resetDrawOffset()
	-- Reset the draw offset to the default (0, 0)
	Graphics.setDrawOffset(0, 0)
end

function RoxyScene:clearScreen()
	-- Clear the screen
	Graphics.clear(Graphics.kColorWhite)
end