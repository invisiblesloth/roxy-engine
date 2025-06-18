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

-- ! Global State

-- Create global Roxy table if it does not already exist
roxy = roxy or {}

-- ! Local State

local engineInitialized = false

-- ! Aliases

-- SDK & Module
local pd  <const> = playdate
local r   <const> = roxy

--Performance
local getDeltaTime  <const> = r.getDeltaTime

-- ----------------------------------------
-- ! Public API
-- ----------------------------------------

-- ! Core Engine Functions

-- Initializes the engine and transitions to the first scene
function r.new()

end

-- ! System Callbacks

function r.gameWillPause()

end

function r.gameWillResume()

end

-- ----------------------------------------
-- ! Implementation
-- ----------------------------------------

-- ! Main Loop

function pd.update()
  local dt = getDeltaTime()
  r.deltaTime = dt
  print(dt)
end
