-- source/libraries/roxy/roxy.lua

--
-- Roxy Game Engine
-- MIT License
--

-- ! Imports

-- Playdate SDK
import "CoreLibs/object"
import "CoreLibs/graphics"
import 'CoreLibs/nineslice'
import "CoreLibs/sprites"
import "CoreLibs/crank"
import "CoreLibs/animation"
import "CoreLibs/animator"
import "CoreLibs/timer"
import "CoreLibs/ui/crankIndicator"
import "CoreLibs/ui/gridview"

-- ! Constants

local DEFAULT_FPS_X <const> = 385 --#DEBUG
local DEFAULT_FPS_Y <const> = 228 --#DEBUG

-- ! Aliases

local pd            <const> = playdate
local getDeltaTime  <const> = roxy.getDeltaTime

-- ! Global State

-- Create global Roxy table if it does not already exist
roxy = roxy or {}

-- ! Local State

local engineInitialized = false

-- ----------------------------------------
-- ! Public API
-- ----------------------------------------

-- ! Core Engine Functions

-- Initializes the engine and transitions to the first scene
function roxy.new()

end

-- ! System Callbacks

function roxy.gameWillPause()

end

function roxy.gameWillResume()

end

-- ----------------------------------------
-- ! Implementation
-- ----------------------------------------

-- ! Main Loop

function pd.update()
  local dt = getDeltaTime()
  roxy.deltaTime = dt
  print(dt)
end
