#include "roxy_input.h"
#include <stdio.h>

static PlaydateAPI* pd = NULL;

void roxy_input_setPlaydateAPI(PlaydateAPI* playdate) {
	pd = playdate;
}

// Structure to map button names to their corresponding PDButtons enum values
typedef struct {
	const char* name;
	PDButtons button;
} ButtonMapping;

// Button mappings for Playdate buttons
static const ButtonMapping buttons[] = {
	{ "A", kButtonA },
	{ "B", kButtonB },
	{ "up", kButtonUp },
	{ "down", kButtonDown },
	{ "left", kButtonLeft },
	{ "right", kButtonRight },
};

#define NUM_BUTTONS (sizeof(buttons) / sizeof(buttons[0]))  // Number of buttons mapped

static int buttonHoldCounts[NUM_BUTTONS] = {0};  // Track how long each button is held
static int buttonHoldBufferAmount = 3;  // Buffer before recognizing continuous press
static int customHoldThreshold = 20;  // Threshold for custom hold duration

// Process a button event, identified by its index in the buttons array
static int roxy_input_processButtonEvent(lua_State* L, int buttonIndex);

int roxy_input_setCustomHoldThreshold_l(lua_State* L) {
	customHoldThreshold = pd->lua->getArgInt(1);  // Set custom hold threshold from Lua
	return 0;
}

int roxy_input_setButtonHoldBufferAmount_l(lua_State* L) {
	buttonHoldBufferAmount = pd->lua->getArgInt(1);  // Set hold buffer amount from Lua
	return 0;
}

// Handle A button press event
int roxy_input_processButtonA_l(lua_State* L) {
	return roxy_input_processButtonEvent(L, 0);
}

// Handle B button press event
int roxy_input_processButtonB_l(lua_State* L) {
	return roxy_input_processButtonEvent(L, 1);
}

// Handle Up button press event
int roxy_input_processButtonUp_l(lua_State* L) {
	return roxy_input_processButtonEvent(L, 2);
}

// Handle Down button press event
int roxy_input_processButtonDown_l(lua_State* L) {
	return roxy_input_processButtonEvent(L, 3);
}

// Handle Left button press event
int roxy_input_processButtonLeft_l(lua_State* L) {
	return roxy_input_processButtonEvent(L, 4);
}

// Handle Right button press event
int roxy_input_processButtonRight_l(lua_State* L) {
	return roxy_input_processButtonEvent(L, 5);
}

// ! Process Button Event
// Determine the state of the button and trigger appropriate Lua callbacks
static int roxy_input_processButtonEvent(lua_State* L, int buttonIndex) {
	(void)L;  // Unused parameter

	PDButtons current, pushed, released;
	pd->system->getButtonState(&current, &pushed, &released);  // Get current button states

	const char* button = buttons[buttonIndex].name;
	PDButtons buttonState = buttons[buttonIndex].button;
	int holdCount = buttonHoldCounts[buttonIndex];

	static char callback[32];
	callback[0] = '\0';

	// Determine which callback to trigger based on button state
	if (pushed & buttonState) {
		snprintf(callback, sizeof(callback), "%sButtonPressed", button);
		buttonHoldCounts[buttonIndex] = 1;  // Start hold count on button press
	} else if (released & buttonState) {
		snprintf(callback, sizeof(callback), "%sButtonReleased", button);
		buttonHoldCounts[buttonIndex] = 0;  // Reset hold count on release
	} else if (current & buttonState) {
		holdCount++;
		buttonHoldCounts[buttonIndex] = holdCount;

		// Trigger custom hold callback if threshold is met
		if (holdCount == customHoldThreshold) {
			snprintf(callback, sizeof(callback), "%sButtonCustomHeld", button);
		} else if (holdCount >= buttonHoldBufferAmount) {
			// Trigger continuous press callback if buffer amount is met
			snprintf(callback, sizeof(callback), "%sButtonPressedContinuously", button);
		}
	}
	
	pd->lua->pushString(callback);  // Push the callback string to Lua
	return 1;  // Return 1 value to Lua
}
