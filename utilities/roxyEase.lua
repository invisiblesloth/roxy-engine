local pd <const> = playdate
local Ease <const> = roxy.easingFunctions

-- Maps `inOut` and `outIn` easing functions to their component parts for entering and exiting phases.
-- These tables allow easy access to the individual "enter" and "exit" functions for complex easing types.
local componentFunctions = {
	[Ease.inOutQuad]	= {		enter = Ease.inQuad,		exit = Ease.outQuad		},
	[Ease.inOutCubic]	= {		enter = Ease.inCubic,		exit = Ease.outCubic	},
	[Ease.inOutQuart]	= {		enter = Ease.inQuart,		exit = Ease.outQuart	},
	[Ease.inOutQuint]	= {		enter = Ease.inQuint,		exit = Ease.outQuint	},
	[Ease.inOutSine]	= {		enter = Ease.inSine,		exit = Ease.outSine		},
	[Ease.inOutExpo]	= {		enter = Ease.inExpo,		exit = Ease.outExpo		},
	[Ease.inOutCirc]	= {		enter = Ease.inCirc,		exit = Ease.outCirc		},
	[Ease.inOutElastic]	= {		enter = Ease.inElastic,		exit = Ease.outElastic	},
	[Ease.inOutBack]	= {		enter = Ease.inBack,		exit = Ease.outBack		},
	[Ease.inOutBounce]	= {		enter = Ease.inBounce,		exit = Ease.outBounce	},
	[Ease.outInQuad]	= {		enter = Ease.outQuad,		exit = Ease.inQuad		},
	[Ease.outInCubic]	= {		enter = Ease.outCubic,		exit = Ease.inCubic		},
	[Ease.outInQuart]	= {		enter = Ease.outQuart,		exit = Ease.inQuart		},
	[Ease.outInQuint]	= {		enter = Ease.outQuint,		exit = Ease.inQuint		},
	[Ease.outInSine]	= {		enter = Ease.outSine,		exit = Ease.inSine		},
	[Ease.outInExpo]	= {		enter = Ease.outExpo,		exit = Ease.inExpo		},
	[Ease.outInCirc]	= {		enter = Ease.outCirc,		exit = Ease.inCirc		},
	[Ease.outInElastic]	= {		enter = Ease.outElastic,	exit = Ease.inElastic	},
	[Ease.outInBack]	= {		enter = Ease.outBack,		exit = Ease.inBack		},
	[Ease.outInBounce]	= {		enter = Ease.outBounce,		exit = Ease.inBounce	},
	[Ease.linear]		= {		enter = Ease.linear,		exit = Ease.linear		}
}

-- Maps each `in` easing function to its corresponding `out` easing function, and vice versa.
-- This allows quick access to the reverse of a given easing function.
local reverseFunctions = {
	[Ease.inQuad]		= Ease.outQuad,
	[Ease.inCubic]		= Ease.outCubic,
	[Ease.inQuart]		= Ease.outQuart,
	[Ease.inQuint]		= Ease.outQuint,
	[Ease.inSine]		= Ease.outSine,
	[Ease.inExpo]		= Ease.outExpo,
	[Ease.inCirc]		= Ease.outCirc,
	[Ease.inElastic]	= Ease.outElastic,
	[Ease.inBack]		= Ease.outBack,
	[Ease.inBounce]		= Ease.outBounce,
	[Ease.outQuad]		= Ease.inQuad,
	[Ease.outCubic]		= Ease.inCubic,
	[Ease.outQuart]		= Ease.inQuart,
	[Ease.outQuint]		= Ease.inQuint,
	[Ease.outSine]		= Ease.inSine,
	[Ease.outExpo]		= Ease.inExpo,
	[Ease.outCirc]		= Ease.inCirc,
	[Ease.outElastic]	= Ease.inElastic,
	[Ease.outBack]		= Ease.inBack,
	[Ease.outBounce]	= Ease.inBounce,
	[Ease.linear]		= Ease.linear
}

-- Returns the first half of an `inOut` or `outIn` easing function, which is the "enter" phase.
-- If the easing function is not in the form of `Ease.inOutXxxx` or `Ease.outInXxxx`, or if it is not in the table, returns `nil`.
-- For `Ease.linear`, it returns itself as it doesn't have distinct phases.
function roxy.easingFunctions.enter(easingFunction)
	if componentFunctions[easingFunction] == nil then return nil end
	return componentFunctions[easingFunction].enter
end

-- Returns the second half of an `inOut` or `outIn` easing function, which is the "exit" phase.
-- If the easing function is not in the form of `Ease.inOutXxxx` or `Ease.outInXxxx`, or if it is not in the table, returns `nil`.
-- For `Ease.linear`, it returns itself as it doesn't have distinct phases.
function roxy.easingFunctions.exit(easingFunction)
	if componentFunctions[easingFunction] == nil then return nil end
	return componentFunctions[easingFunction].exit
end

-- Returns the reverse function of the provided easing function.
-- If the easing function is not in the form of `Ease.inXxxx` or `Ease.outXxxx`, or if it is not in the table, returns `nil`.
-- For `Ease.linear`, it returns itself since the reverse is the same.
function roxy.easingFunctions.reverse(easingFunction)
	if reverseFunctions[easingFunction] == nil then return nil end
	return reverseFunctions[easingFunction]
end
