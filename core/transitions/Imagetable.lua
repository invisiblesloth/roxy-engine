-- Imagetable is a transition effect that uses an imagetable to create 
-- a transition animation between scenes, with various transformation options.

local configurationManager <const> = ConfigurationManager.getInstance()
local transitionManager <const> = TransitionManager.getInstance()

local pd <const> = playdate
local Graphics <const> = pd.graphics
local Ease <const> = roxy.easingFunctions

class("Imagetable").extends(RoxyImagetableTransition)
local transition = Imagetable

local defaultProperties = {
	-- General properties
	name = "Imagetable",
	
	-- Timing properties
	duration = configurationManager:getConfig().defaultTransitionDuration or 1.5,
	holdTime = 0.0,  -- No hold time for this transition
	
	-- Image table properties
	imagetableEnter = 
		transitionManager:getImagetable("imagetableEnter") or 
		Graphics.imagetable.new("libraries/roxy/assets/images/SLOTHUniversalLeaderEnter"),
	imagetableExit = 
		transitionManager:getImagetable("imagetableExit") or 
		Graphics.imagetable.new("libraries/roxy/assets/images/SLOTHUniversalLeaderExit"),
	
	-- Transformation properties
	reverse = false,
	reverseEnter = false,
	reverseExit = false,
	flipX = false,
	flipY = false,
	flipXEnter = false,
	flipYEnter = false,
	flipXExit = false,
	flipYExit = false,
	rotate = false,
	rotateEnter = false,
	rotateExit = false,
}

function transition:init(duration, holdTime, properties)
	properties = properties or {}
	properties.duration = duration or properties.duration or defaultProperties.duration
	properties.holdTime = 0.0
	
	-- Merge provided properties with default properties 
	-- ensuring all necessary settings are included
	local mergedProperties = roxy.table.mergeImmutable(defaultProperties, properties)

	transition.super.init(self, properties.duration, properties.holdTime, mergedProperties)
end
