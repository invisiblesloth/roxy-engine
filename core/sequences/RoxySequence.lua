--
-- Adapted from 
-- Nic Magnier's Sequence library (https://github.com/NicMagnier/PlaydateSequence)
--

local sequenceManager <const> = SequenceManager.getInstance()

local pd <const> = playdate
local Object <const> = pd.object
local Ease <const> = roxy.easingFunctions
local Sequence <const> = roxy.sequence

class("RoxySequence").extends()

function RoxySequence:init()
	RoxySequence.super.init(self)
	
	-- Initialize runtime values
	self.time = 0				-- The current time in the sequence's progression
	self.cachedResultTimestamp = nil  -- Cached timestamp to optimize repeated calculations
	self.cachedResult = 0		-- Cached result of the sequence value
	self.previousUpdateEasingIndex = nil  -- Index of the last easing updated to avoid redundant searches
	self.isRunning = false		-- Indicates whether the sequence is currently running
	self.previousUpdateTime = nil  -- Previous time used to calculate deltaTime

	-- Initialize sequence configuration
	self.duration = 0			-- Total duration of the sequence
	self.pacing = 1				-- Pacing multiplier to speed up or slow down the sequence
	self.loopType = false		-- Type of looping behavior (e.g., loop, ping-pong)
	self.easings = {}			-- List of easing functions applied in the sequence
	self.easingCount = 0		-- Number of easings in the sequence
	self.callbacks = {}			-- List of callback functions to be triggered at specific times
end

-- ! Clear
function RoxySequence:clear(clearEasings)
	self:stop()  -- Stop the sequence
	self.time = 0
	self.cachedResultTimestamp = nil
	self.cachedResult = 0
	self.previousUpdateEasingIndex = nil
	self.previousUpdateTime = nil
	self.duration = 0
	self.loopType = false
	self.easingCount = 0
	self.callbacks = {}

	if clearEasings then
		self.easings = {}  -- Clear all easings if specified
	end
end

-- ! Add and Remove
function RoxySequence:add()
	if self.easingCount == 0 then return end
	
	sequenceManager:add(self)  -- Add the sequence to the manager to start updating it
	self.isRunning = true
end

function RoxySequence:remove()
	sequenceManager:remove(self)  -- Remove the sequence from the manager to stop updating it
	self.isRunning = false
end

-- ! Get and Set Pacing 
function RoxySequence:getPacing()
	return self.pacing
end

function RoxySequence:setPacing(pacing)
	pacing = pacing or 1
	self.pacing = pacing  -- Set the pacing multiplier
	return self
end

-- ! Loop and Ping-Pong
function RoxySequence:loop()
	self.loopType = "loop"  -- Set sequence to loop continuously
	return self
end

function RoxySequence:pingPong()
	self.loopType = "ping-pong"  -- Set sequence to alternate direction after each completion
	return self
end

-- ! Set Previous Update Time
function RoxySequence:setPreviousUpdateTime(currentTime)
	currentTime = currentTime or pd.getCurrentTimeMilliseconds()
	self.previousUpdateTime = currentTime  -- Store the time for calculating deltaTime
end

-- ! Add Easing
function RoxySequence:addEasing(timestamp, from, to, duration, easeFunction)
	self.easingCount += 1
	local easing = {
		timestamp = timestamp,	-- Timestamp: The starting time of the easing
		from = from,			-- From: The initial value of the easing
		to = to,				-- To: The final value of the easing
		duration = duration,	-- Duration: The duration of the easing
		easeFunction = easeFunction  -- Easing function: The easing function to use
	}
	self.easings[self.easingCount] = easing  -- Store the easing in the sequence
end

--! From
function RoxySequence:from(from)
	from = from or 0

	self:clear()  -- Clear previous easings and configurations
	self:addEasing(
		0,						-- Timestamp
		from,					-- From
		from,					-- To
		0,						-- Duration
		Ease.flat				-- Easing function
	)

	return self
end

-- ! To
function RoxySequence:to(to, duration, easeFunction)
	if self.easingCount == 0 then return self end
	
	to = to or 0
	duration = duration or 0.3
	easeFunction = easeFunction or Ease.inOutQuad

	local lastEasing = self.easings[self.easingCount]
	self:addEasing(
		lastEasing.timestamp + lastEasing.duration,  -- Timestamp
		lastEasing.to,			-- From
		to,						-- To
		duration,				-- Duration
		easeFunction			-- Easing function
	)

	self.duration += duration  -- Update total sequence duration
	
	return self
end

-- ! Set
function RoxySequence:set(value)
	print(value)
	
	if self.easingCount == 0 then return self end
	
	local lastEasing = self.easings[self.easingCount]
	self:addEasing(
		lastEasing.timestamp + lastEasing.duration,  -- Timestamp
		value,					-- From
		value,					-- To
		0,						-- Duration
		Ease.flat				-- Easing function
	)
	
	return self
end

-- ! Again
function RoxySequence:again(repeatCount, pingPong)
	if self.easingCount == 0 then return self end
	
	repeatCount = repeatCount or 1
	local previousEasing = self.easings[self.easingCount]

	for i = 1, repeatCount do
		local from, to = previousEasing.from, previousEasing.to
		if pingPong then
			from, to = to, from  -- Swap the values for ping-pong behavior
		end
		local newEasing = self:addEasing(
			previousEasing.timestamp + previousEasing.duration,  -- Timestamp
			from,               -- From
			to,                 -- To
			previousEasing.duration,  -- Duration
			previousEasing.easeFunction  -- Easing function
		)
		self.duration += previousEasing.duration  -- Update total sequence duration
		previousEasing = newEasing
	end

	return self
end

-- ! Sleep
function RoxySequence:sleep(duration)
	if self.easingCount == 0 or duration == 0 then return self end
	
	duration = duration or 0.5

	local lastEasing = self.easings[self.easingCount]
	self:addEasing(
		lastEasing.timestamp + lastEasing.duration,  -- Timestamp
		lastEasing.to,			-- From
		lastEasing.to,			-- To
		duration,				-- Duration
		Ease.flat				-- Easing function
	)
	
	self.duration += duration  -- Update total sequence duration
	
	return self
end

-- ! Callback
function RoxySequence:callback(callbackFunction, timeOffset)
	if self.easingCount == 0 or not callbackFunction then return self end
	
	timeOffset = timeOffset or 0

	local lastEasing = self.easings[self.easingCount]
	local callbackObject = {
		callbackFunction = callbackFunction,
		timestamp = lastEasing.timestamp + lastEasing.duration + timeOffset
	}
	table.insert(self.callbacks, callbackObject)  -- Register the callback

	return self
end

-- ! Reverse
function RoxySequence:reverse()
	if self.easingCount == 0 then return self end
	
	local reversedEasings = {}
	local duration = self.duration

	for i = #self.easings, 1, -1 do
		local easing = self.easings[i]
		table.insert(reversedEasings, {
			timestamp = duration - (easing.timestamp + easing.duration),
			from = easing.to,
			to = easing.from,
			duration = easing.duration,
			easeFunction = easing.easeFunction,
			params = easing.params
		})
	end

	self.easings = reversedEasings  -- Replace with reversed easings
	self.previousUpdateEasingIndex = nil  -- Reset index for next update

	return self
end

-- ! Start
function RoxySequence:start()
	if self.easingCount == 0 then return self end
	
	if not self.isRunning then
		self:add()  -- Add to the sequence manager if not already running
	end
	
	return self
end

-- ! Stop
function RoxySequence:stop()
	self:remove()  -- Stop and remove from the sequence manager
	self.time = 0
	self.cachedResultTimestamp = nil
	self.previousUpdateEasingIndex = nil
	return self
end

-- ! Pause
function RoxySequence:pause()
	self:remove()  -- Temporarily stop the sequence without resetting its state
	return self
end

-- ! Restart
function RoxySequence:restart()
	if self.easingCount == 0 then return self end
	
	self.time = 0  -- Reset sequence time
	self.cachedResultTimestamp = nil
	self.previousUpdateEasingIndex = nil
	self:start()
	
	return self
end

-- ! Is Done
function RoxySequence:isDone()
	return self.time >= self.duration and not self.loopType  -- Check if sequence has completed
end

-- ! Get Easing by Time
function RoxySequence:getEasingByTime(clampedTime)
	if self.easingCount == 0 then
		warn("Warning: Empty sequence animation.")
		return nil
	end

	local startIndex = self.previousUpdateEasingIndex or 1
	local endIndex = self.easingCount

	while startIndex <= endIndex do
		local middleIndex = math.floor((startIndex + endIndex) / 2)
		local easing = self.easings[middleIndex]

		if clampedTime < easing.timestamp then
			endIndex = middleIndex - 1
		elseif clampedTime > (easing.timestamp + easing.duration) then
			startIndex = middleIndex + 1
		else
			self.previousUpdateEasingIndex = middleIndex
			return easing
		end
	end

	warn("Warning: Sequence part not found: 'clampedTime' is likely out of bounds.", clampedTime, self.duration)
	return self.easings[1]  -- Default to the first easing if not found
end

-- ! Get Clamped Time
function RoxySequence:getClampedTime(time)
	time = time or self.time
	return Sequence.getClampedTime(time, self.duration, self.loopType)  -- Runs in C (roxy_sequence.c) for optimized performance

end

-- ! Update Callbacks
function RoxySequence:updateCallbacks(deltaTime)
	if self.easingCount == 0 then return end
	
	local duration = self.duration
	local loopType = self.loopType
	local clampedTime, isForward = Sequence.getClampedTime(self.time, duration, loopType)  -- Runs in C (roxy_sequence.c) for optimized performance

	local endTime = isForward and clampedTime + deltaTime or clampedTime - deltaTime
	local clampedEndTime, _ = Sequence.getClampedTime(endTime, duration, loopType)  -- Runs in C (roxy_sequence.c) for optimized performance

		
	-- Call the callbacks within a specified time range
	local function invokeCallbacksInRange(clampedStart, clampedEnd)
		if clampedStart > clampedEnd then
			clampedStart, clampedEnd = clampedEnd, clampedStart
		end
		
		for i = 1, #self.callbacks do
			local callbackObject = self.callbacks[i]
			if callbackObject.timestamp >= clampedStart and callbackObject.timestamp <= clampedEnd then
				if type(callbackObject.callbackFunction) == "function" then
					callbackObject.callbackFunction()  -- Execute the callback
				end
			end
		end
	end
	
	-- Handle no loop scenario
	if not loopType then
		invokeCallbacksInRange(clampedTime, clampedTime + deltaTime)
		return
	end
	
	-- Handle loop scenarios
	if deltaTime > duration then
		invokeCallbacksInRange(0, duration)
	end
	
	if endTime < 0 then
		invokeCallbacksInRange(0, math.max(clampedTime, clampedEndTime))
	elseif endTime > duration then
		if loopType == "loop" then
			invokeCallbacksInRange(clampedTime, duration)
			invokeCallbacksInRange(0, clampedEndTime)
		else
			invokeCallbacksInRange(math.min(clampedTime, clampedEndTime), duration)
		end
	else
		invokeCallbacksInRange(clampedTime, endTime)
	end
end

-- ! Update Loop
function RoxySequence:update(deltaTime)
	local pacing = self.pacing
	deltaTime = deltaTime * pacing
	
	-- Adjust deltaTime based on the previous update time, if set
	if self.previousUpdateTime then
		local currentTime = playdate.getCurrentTimeMilliseconds()
		deltaTime = (currentTime - self.previousUpdateTime) / 1000 * pacing
		self.previousUpdateTime = currentTime
	end
	
	self:updateCallbacks(deltaTime)
	self.time += deltaTime  -- Increment the sequence time
	self.cachedResultTimestamp = nil  -- Invalidate cached result to ensure recalculation
end

-- ! Get Value (Value Calculation/Progress)
function RoxySequence:getValue(defaultValue, time)
	if self.easingCount == 0 then return 0 end

	defaultValue = defaultValue or 0
	time = time or self.time

	if self.cachedResultTimestamp == time then
		return self.cachedResult  -- Return cached result if available
	end

	local clampedTime = Sequence.getClampedTime(time, self.duration, self.loopType)  -- Runs in C (roxy_sequence.c) for optimized performance

	local easing = self:getEasingByTime(clampedTime)
	
	local result = easing.easeFunction(
		clampedTime - easing.timestamp,  -- Current time in the easing
		easing.from,			-- Starting value
		easing.to - easing.from,  -- Change in value
		easing.duration			-- Duration of the easing
	)
	
	-- Check for NaN on result
	if result ~= result then
		result = defaultValue  -- Fallback to default if result is NaN
	end

	self.cachedResultTimestamp = clampedTime
	self.cachedResult = result

	return result
end

-- ! Has Easings
function RoxySequence:hasEasings()
	return self.easingCount > 0
end

-- ! Get and Set isRunning
function RoxySequence:getIsRunning()
	return self.isRunning
end

function RoxySequence:setIsRunning(_isRunning)
	if type(_isRunning) == "boolean" then
		self.isRunning = _isRunning
	else
		warn("Warning: Expected a boolean for '_isRunning', but got " .. type(_isRunning))
	end
end
