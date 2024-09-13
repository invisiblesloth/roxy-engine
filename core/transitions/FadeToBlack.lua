-- FadeToBlack is a transition effect that gradually covers the 
-- current scene with a black panel before gradually revealing the new scene.

local configurationManager <const> = ConfigurationManager.getInstance()
local transitionManager <const> = TransitionManager.getInstance()

local pd <const> = playdate
local Object <const> = pd.object
local Graphics <const> = pd.graphics
local Ease <const> = roxy.easingFunctions

local displayWidth, displayHeight, displayCenterX, displayCenterY = roxy.graphics.getDisplaySize()

class("FadeToBlack").extends(RoxyCoverTransition)
local transition = FadeToBlack

local defaultProperties = {
	-- General properties
	name = "Fade to Black",
	
	-- Timing properties
	duration = configurationManager:getConfig().defaultTransitionDuration or 1.5,
	holdTime = configurationManager:getConfig().defaultTransitionHoldTime or 0.25,
	
	-- Easing properties
	ease = Ease.outInQuad,
	
	-- Graphics properties
	dither = 
		transitionManager:getDither("bayer8x8") or 
		Graphics.image.kDitherTypebayer8x8,  -- Fallback dither type
	panelImage = 
		transitionManager:getImage("panelImageBlack") or 
		Graphics.image.new(displayWidth, displayHeight, Graphics.kColorBlack)  -- Fallback black panel
}

function transition:init(duration, holdTime, properties)
	properties = properties or {}
	properties.duration = duration or properties.duration or defaultProperties.duration
	properties.holdTime = holdTime or properties.holdTime or defaultProperties.holdTime
	
	-- Merge provided properties with default properties 
	-- ensuring all necessary settings are included
	local mergedProperties = roxy.table.mergeImmutable(defaultProperties, properties)
	
	transition.super.init(self, properties.duration, properties.holdTime, mergedProperties)
end

function transition:cleanup()
	transition.super.cleanup(self)
	-- Recycle the panel image back to the transition manager for reuse
	transitionManager:recycleImage("panelImageBlack", self.panelImage)
end