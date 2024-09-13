local pd <const> = playdate
local Object <const> = pd.object
local Graphics <const> = pd.graphics
local Sprite <const> = Graphics.sprite

class("SceneManager").extends()

-- Singleton instance for managing scenes globally
local instance = nil

function SceneManager:init()
	self.scenes = {}
	self.currentScene = nil
	self.pools = {  -- Object pools to optimize resource management
		images = {
			background1 = {},
			background2 = {}
		}
	}
	self:populatePools(4)  -- Initialize object pools with default size
end

function SceneManager:populatePools(poolSize)
	-- Preload images into the object pools to optimize memory usage and reduce load times
	for i = 1, poolSize or 1 do
		self:recycleImage("background1", Graphics.image.new("libraries/roxy/assets/images/background1"))
		self:recycleImage("background2", Graphics.image.new("libraries/roxy/assets/images/background2"))
	end
end

function SceneManager:registerScenes(...)
	local params = {...}
	if #params == 2 and type(params[1]) == "string" and type(params[2]) == "table" then
		-- Single scene registration: 
			-- params[1] is the scene name, 
			-- params[2] is the scene object
		self.scenes[params[1]] = params[2]
	elseif #params == 1 and type(params[1]) == "table" then
		-- Multiple scenes registration: 
			-- params[1] should be a table of scenes
		for name, scene in pairs(params[1]) do
			if type(name) == "string" and type(scene) == "table" then
				self.scenes[name] = scene
			else
				error("ERROR: Invalid scene registration format. Expected a table with scene name keys and scene object values.")
			end
		end
	else
		error("ERROR: Invalid params. Received: " .. tableToString(params) .. " - Use 'SceneManager:registerScenes(sceneName, sceneObject)' or 'SceneManager:registerScenes({sceneName1 = sceneObject1, ...})'")
	end
end

-- ! Set Up Background Drawing Callback
function SceneManager:setUpBackgroundDrawing()
	Sprite.setBackgroundDrawingCallback(
		function (x, y, width, height)
			self.currentScene:drawBackground(x, y, width, height)  -- Delegate background drawing to the current scene
		end
	)
	-- Prevent background drawing callback from being accidentally overwritten
	Sprite.setBackgroundDrawingCallback = function()
		error("ERROR: Direct modification of the background drawing callback is not allowed. Please use scene-specific drawing methods.")
	end
end

-- ! Get and Set Current Scene
function SceneManager:getCurrentScene()
	return self.currentScene
end

function SceneManager:setCurrentScene(scene)
	if type(scene) == "table" then
		self.currentScene = scene  -- Set the current scene if it's a valid scene
	else
		error("ERROR: A valid scene object must be passed to correctly set the current scene. The scene object is either nil or missing required methods.")
	end
end

-- ! Object Pool Methods
function SceneManager:getImage(type)
	local imagePool = self.pools.images
	-- Retrieve an image from the corresponding pool, if available
	if type == "background1" and #imagePool.background1 > 0 then
		return table.remove(imagePool.background1)
	elseif type == "background2" and #imagePool.background2 > 0 then
		return table.remove(imagePool.background2)
	else
		warn("Warning: No image available for type: " .. tostring(type))
		return nil
	end
end

function SceneManager:recycleImage(type, image)
	local imagePool = self.pools.images
	-- Return the image to the appropriate pool for reuse
	if type == "background1" then
		table.insert(imagePool.background1, image)
	elseif type == "background2" then
		table.insert(imagePool.background2, image)
	else
		warn("Warning: Invalid image type: " .. tostring(type))
	end
end

-- Singleton access method to get the instance of SceneManager
-- @return The singleton instance of SceneManager
function SceneManager.getInstance()
	if not instance then
		instance = SceneManager()  -- Create the instance if it doesn't exist
	end
	return instance
end
