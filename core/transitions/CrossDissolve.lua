-- CrossDissolve is a transition effect that gradually fades out the 
-- current scene while fading in the new scene

local configurationManager <const> = ConfigurationManager.getInstance()
local transitionManager <const> = TransitionManager.getInstance()

local pd <const> = playdate
local Object <const> = pd.object
local Graphics <const> = pd.graphics
local Ease <const> = roxy.easingFunctions

class("CrossDissolve").extends(RoxyMixTransition)
local transition = CrossDissolve

local defaultProperties = {
	-- General properties
	name = "Cross Dissolve",
	
	-- Timing properties
	duration = configurationManager:getConfig().defaultTransitionDuration or 1.5,
	holdTime = 0.0,
	
	-- Easing properties
	ease = Ease.outQuad,
	
	-- Graphics properties
	dither = 
		transitionManager:getDither("bayer8x8") or  
		Graphics.image.kDitherTypebayer8x8  -- Fallback dither type
}

function transition:init(duration, holdTime, properties)
	properties = properties or {}
	properties.duration = duration or properties.duration or defaultProperties.duration
	properties.holdTime = 0.0  -- Hold time is explicitly set to 0 for this transition
	
	-- Merge provided properties with default properties 
	-- ensuring all necessary settings are included
	local mergedProperties = roxy.table.mergeImmutable(defaultProperties, properties)

	transition.super.init(self, properties.duration, properties.holdTime, mergedProperties)
end
