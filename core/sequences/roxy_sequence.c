//
// Adapted from
// Nic Magnier's Sequence library (https://github.com/NicMagnier/PlaydateSequence)
//

#include "roxy_sequence.h"
#include "../../utilities/roxy_math.h"
#include <math.h>

// Global variable to hold the Playdate API reference, used throughout this file.
static PlaydateAPI* pd = NULL;

// Sets the Playdate API reference for use within the sequence functions.
void roxy_sequence_setPlaydateAPI(PlaydateAPI* playdate) {
	pd = playdate;
}

// Lua binding for getting the clamped time based on the sequence's duration and loop type.
// Handles three types of sequences: none (clamps the time), loop, and ping-pong.
int roxy_sequence_getClampedTime_l(lua_State* L) {
	float time = pd->lua->getArgFloat(1);		// The current time in the sequence.
	float duration = pd->lua->getArgFloat(2);	// The total duration of the sequence.
	const char* loopType = pd->lua->getArgString(3);  // The loop type: can be NULL, "loop", or "ping-pong".

	float result;		// The clamped or modified time result.
	int isForward = 1;	// Direction flag for ping-pong sequences, indicates if the time is moving forward or backward.

	// If no loop type is specified, clamp the time between 0 and the duration.
	if (loopType == NULL) {
		result = roxy_math_clamp(time, 0.0f, duration);
	} 
	// For loop type, wrap the time around using modulo operation.
	else if (strcmp(loopType, "loop") == 0) {
		result = fmodf(time, duration);
	} 
	// For ping-pong type, reverse the time after each full cycle to create a back-and-forth effect.
	else if (strcmp(loopType, "ping-pong") == 0) {
		float doubleDuration = duration * 2.0f;
		time = fmodf(time, doubleDuration);
		if (time > duration) {
			isForward = 0;  // Indicate that the time is moving in reverse.
			time = doubleDuration - time;
		}
		result = time;
	} 
	// Default behavior: clamp the time if an unknown loop type is provided.
	else {
		result = roxy_math_clamp(time, 0.0f, duration);
	}

	// Push the result time and direction flag onto the Lua stack.
	pd->lua->pushFloat(result);
	pd->lua->pushBool(isForward);
	return 2;  // Return two values: the clamped time and the direction flag.
}
