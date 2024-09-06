-- Cut is a transition effect that instantly switches from the 
-- current scene to the new scene without any fade or delay.

class("Cut").extends(RoxyCutTransition)
local transition = Cut

function transition:init(duration, holdTime, properties)
	transition.super.init(self, duration, holdTime, properties)
end