-- utilities/Ease.lua

roxy = roxy or {}
roxy.EasingFunctions = roxy.EasingFunctions or {}
roxy.EasingMap = roxy.EasingMap or {}
local Ease <const> = roxy.EasingFunctions

-- ! Easing Function ID Map
-- Numeric identifiers for easing types (used for lookup and serialization).
roxy.EasingMap = {
  flat          = 0,
  linear        = 1,
  inQuad        = 2,
  outQuad       = 3,
  inOutQuad     = 4,
  outInQuad     = 5,
  inCubic       = 6,
  outCubic      = 7,
  inOutCubic    = 8,
  outInCubic    = 9,
  inQuart       = 10,
  outQuart      = 11,
  inOutQuart    = 12,
  outInQuart    = 13,
  inQuint       = 14,
  outQuint      = 15,
  inOutQuint    = 16,
  outInQuint    = 17,
  inSine        = 18,
  outSine       = 19,
  inOutSine     = 20,
  outInSine     = 21,
  inExpo        = 22,
  outExpo       = 23,
  inOutExpo     = 24,
  outInExpo     = 25,
  inCirc        = 26,
  outCirc       = 27,
  inOutCirc     = 28,
  outInCirc     = 29,
  inElastic     = 30,
  outElastic    = 31,
  inOutElastic  = 32,
  outInElastic  = 33,
  inBack        = 34,
  outBack       = 35,
  inOutBack     = 36,
  outInBack     = 37,
  outBounce     = 38,
  inBounce      = 39,
  inOutBounce   = 40,
  outInBounce   = 41
}

-- ! Component Phase Mappings
-- Maps compound easings (e.g., inOut) to their enter/exit components.
local componentFunctions <const> = {
  [Ease.inOutQuad]    = { enter = Ease.inQuad,      exit = Ease.outQuad     },
  [Ease.inOutCubic]   = { enter = Ease.inCubic,     exit = Ease.outCubic    },
  [Ease.inOutQuart]   = { enter = Ease.inQuart,     exit = Ease.outQuart    },
  [Ease.inOutQuint]   = { enter = Ease.inQuint,     exit = Ease.outQuint    },
  [Ease.inOutSine]    = { enter = Ease.inSine,      exit = Ease.outSine     },
  [Ease.inOutExpo]    = { enter = Ease.inExpo,      exit = Ease.outExpo     },
  [Ease.inOutCirc]    = { enter = Ease.inCirc,      exit = Ease.outCirc     },
  [Ease.inOutElastic] = { enter = Ease.inElastic,   exit = Ease.outElastic  },
  [Ease.inOutBack]    = { enter = Ease.inBack,      exit = Ease.outBack     },
  [Ease.inOutBounce]  = { enter = Ease.inBounce,    exit = Ease.outBounce   },
  [Ease.outInQuad]    = { enter = Ease.outQuad,     exit = Ease.inQuad      },
  [Ease.outInCubic]   = { enter = Ease.outCubic,    exit = Ease.inCubic     },
  [Ease.outInQuart]   = { enter = Ease.outQuart,    exit = Ease.inQuart     },
  [Ease.outInQuint]   = { enter = Ease.outQuint,    exit = Ease.inQuint     },
  [Ease.outInSine]    = { enter = Ease.outSine,     exit = Ease.inSine      },
  [Ease.outInExpo]    = { enter = Ease.outExpo,     exit = Ease.inExpo      },
  [Ease.outInCirc]    = { enter = Ease.outCirc,     exit = Ease.inCirc      },
  [Ease.outInElastic] = { enter = Ease.outElastic,  exit = Ease.inElastic   },
  [Ease.outInBack]    = { enter = Ease.outBack,     exit = Ease.inBack      },
  [Ease.outInBounce]  = { enter = Ease.outBounce,   exit = Ease.inBounce    },
  [Ease.linear]       = { enter = Ease.linear,      exit = Ease.linear      }
}

-- ! Reverse Function Map
-- Maps 'in' <--> 'out' easing variants for reversing direction.
local reverseFunctions <const> = {
  [Ease.inQuad]     = Ease.outQuad,
  [Ease.inCubic]    = Ease.outCubic,
  [Ease.inQuart]    = Ease.outQuart,
  [Ease.inQuint]    = Ease.outQuint,
  [Ease.inSine]     = Ease.outSine,
  [Ease.inExpo]     = Ease.outExpo,
  [Ease.inCirc]     = Ease.outCirc,
  [Ease.inElastic]  = Ease.outElastic,
  [Ease.inBack]     = Ease.outBack,
  [Ease.inBounce]   = Ease.outBounce,
  [Ease.outQuad]    = Ease.inQuad,
  [Ease.outCubic]   = Ease.inCubic,
  [Ease.outQuart]   = Ease.inQuart,
  [Ease.outQuint]   = Ease.inQuint,
  [Ease.outSine]    = Ease.inSine,
  [Ease.outExpo]    = Ease.inExpo,
  [Ease.outCirc]    = Ease.inCirc,
  [Ease.outElastic] = Ease.inElastic,
  [Ease.outBack]    = Ease.inBack,
  [Ease.outBounce]  = Ease.inBounce,
  [Ease.linear]     = Ease.linear
}

-- ! Enter
-- Returns the enter easing for a compound easing function.
function Ease.enter(easingFunction)
  Log.assert(type(easingFunction) == "function", "[Ease.enter] easingFunction must be a function.") --#DEBUG
  return componentFunctions[easingFunction] and componentFunctions[easingFunction].enter or nil
end

-- ! Exit
-- Returns the exit easing for a compound easing function.
function Ease.exit(easingFunction)
  Log.assert(type(easingFunction) == "function", "[Ease.exit] easingFunction must be a function.") --#DEBUG
  return componentFunctions[easingFunction] and componentFunctions[easingFunction].exit or nil
end

-- ! Reverse
-- Returns the reversed version of an easing function, if available.
function Ease.reverse(easingFunction)
  Log.assert(type(easingFunction) == "function", "[Ease.reverse] easingFunction must be a function.") --#DEBUG
  return reverseFunctions[easingFunction] or nil
end
