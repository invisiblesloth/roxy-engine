#include "pd_api.h"
#include "utilities/roxy_math.h"
#include "utilities/roxy_ease.h"
#include "core/managers/roxy_input.h"
#include "core/sequences/roxy_sequence.h"

static PlaydateAPI* pd = NULL;  // Pointer to Playdate API, initialized during Lua event

static float deltaTime = 0.0f;  // Time difference between frames, in seconds
static uint32_t previousTime = 0;  // Last recorded time in milliseconds

static int updateDeltaTime_l(lua_State* L);  // Lua function to update deltaTime

#ifdef _WINDLL
__declspec(dllexport)
#endif
int eventHandler(PlaydateAPI* playdate, PDSystemEvent event, uint32_t arg) {
	(void)arg;

	if (event == kEventInitLua) {
		pd = playdate;  // Initialize Playdate API pointer
		
		const char* error;
		
		// ! Register Update Delta Time Function
		if (!pd->lua->addFunction(updateDeltaTime_l, "roxy.updateDeltaTime", &error)) {
			pd->system->logToConsole("%s:%i: addFunction failed, %s", __FILE__, __LINE__, error);
			return -1;
		}
		
		roxy_math_setPlaydateAPI(pd);
		
		// ! Register Math Functions
		const char* mathFunctions[] = {
			"roxy.math.truncateDecimal",
			"roxy.math.round",
			"roxy.math.roundDown",
			"roxy.math.roundUp",
			"roxy.math.hypot",
			"roxy.math.clamp",
			"roxy.math.lerp",
			"roxy.math.map"
		};
		int (*mathFuncs[])(lua_State*) = {
			roxy_math_truncateDecimal_l,
			roxy_math_round_l,
			roxy_math_roundDown_l,
			roxy_math_roundUp_l,
			roxy_math_hypot_l,
			roxy_math_clamp_l,
			roxy_math_lerp_l,
			roxy_math_map_l
		};
		for (int i = 0; i < sizeof(mathFunctions) / sizeof(mathFunctions[0]); ++i) {
			if (!pd->lua->addFunction(mathFuncs[i], mathFunctions[i], &error)) {
				pd->system->logToConsole("%s:%i: addFunction failed, %s", __FILE__, __LINE__, error);
				return -1;
			}
		}
		
		roxy_easingFunctions_setPlaydateAPI(pd);
		
		// ! Register Easing Functions
		const char* easingFunctions[] = {
			"roxy.easingFunctions.flat",
			"roxy.easingFunctions.linear",
			"roxy.easingFunctions.inQuad",
			"roxy.easingFunctions.outQuad",
			"roxy.easingFunctions.inOutQuad",
			"roxy.easingFunctions.outInQuad",
			"roxy.easingFunctions.inCubic",
			"roxy.easingFunctions.outCubic",
			"roxy.easingFunctions.inOutCubic",
			"roxy.easingFunctions.outInCubic",
			"roxy.easingFunctions.inQuart",
			"roxy.easingFunctions.outQuart",
			"roxy.easingFunctions.inOutQuart",
			"roxy.easingFunctions.outInQuart",
			"roxy.easingFunctions.inQuint",
			"roxy.easingFunctions.outQuint",
			"roxy.easingFunctions.inOutQuint",
			"roxy.easingFunctions.outInQuint",
			"roxy.easingFunctions.inSine",
			"roxy.easingFunctions.outSine",
			"roxy.easingFunctions.inOutSine",
			"roxy.easingFunctions.outInSine",
			"roxy.easingFunctions.inExpo",
			"roxy.easingFunctions.outExpo",
			"roxy.easingFunctions.inOutExpo",
			"roxy.easingFunctions.outInExpo",
			"roxy.easingFunctions.inCirc",
			"roxy.easingFunctions.outCirc",
			"roxy.easingFunctions.inOutCirc",
			"roxy.easingFunctions.outInCirc",
			"roxy.easingFunctions.inElastic",
			"roxy.easingFunctions.outElastic",
			"roxy.easingFunctions.inOutElastic",
			"roxy.easingFunctions.outInElastic",
			"roxy.easingFunctions.inBack",
			"roxy.easingFunctions.outBack",
			"roxy.easingFunctions.inOutBack",
			"roxy.easingFunctions.outInBack",
			"roxy.easingFunctions.outBounce",
			"roxy.easingFunctions.inBounce",
			"roxy.easingFunctions.inOutBounce",
			"roxy.easingFunctions.outInBounce"
		};
		int (*easingFuncs[])(lua_State*) = {
			roxy_ease_flat_l,
			roxy_ease_linear_l,
			roxy_ease_in_quad_l,
			roxy_ease_out_quad_l,
			roxy_ease_in_out_quad_l,
			roxy_ease_out_in_quad_l,
			roxy_ease_in_cubic_l,
			roxy_ease_out_cubic_l,
			roxy_ease_in_out_cubic_l,
			roxy_ease_out_in_cubic_l,
			roxy_ease_in_quart_l,
			roxy_ease_out_quart_l,
			roxy_ease_in_out_quart_l,
			roxy_ease_out_in_quart_l,
			roxy_ease_in_quint_l,
			roxy_ease_out_quint_l,
			roxy_ease_in_out_quint_l,
			roxy_ease_out_in_quint_l,
			roxy_ease_in_sine_l,
			roxy_ease_out_sine_l,
			roxy_ease_in_out_sine_l,
			roxy_ease_out_in_sine_l,
			roxy_ease_in_expo_l,
			roxy_ease_out_expo_l,
			roxy_ease_in_out_expo_l,
			roxy_ease_out_in_expo_l,
			roxy_ease_in_circ_l,
			roxy_ease_out_circ_l,
			roxy_ease_in_out_circ_l,
			roxy_ease_out_in_circ_l,
			roxy_ease_in_elastic_l,
			roxy_ease_out_elastic_l,
			roxy_ease_in_out_elastic_l,
			roxy_ease_out_in_elastic_l,
			roxy_ease_in_back_l,
			roxy_ease_out_back_l,
			roxy_ease_in_out_back_l,
			roxy_ease_out_in_back_l,
			roxy_ease_out_bounce_l,
			roxy_ease_in_bounce_l,
			roxy_ease_in_out_bounce_l,
			roxy_ease_out_in_bounce_l
		};
		for (int i = 0; i < sizeof(easingFunctions) / sizeof(easingFunctions[0]); ++i) {
			if (!pd->lua->addFunction(easingFuncs[i], easingFunctions[i], &error)) {
				pd->system->logToConsole("%s:%i: addFunction failed, %s", __FILE__, __LINE__, error);
				return -1;
			}
		}
		
		roxy_input_setPlaydateAPI(pd);
		
		// ! Register Input Functions
		const char* inputFunctions[] = {
			"roxy.input.setCustomHoldThreshold",
			"roxy.input.setButtonHoldBufferAmount",
			"roxy.input.processButtonA",
			"roxy.input.processButtonB",
			"roxy.input.processButtonUp",
			"roxy.input.processButtonDown",
			"roxy.input.processButtonLeft",
			"roxy.input.processButtonRight"
		};
		int (*inputFuncs[])(lua_State*) = {
			roxy_input_setCustomHoldThreshold_l,
			roxy_input_setButtonHoldBufferAmount_l,
			roxy_input_processButtonA_l,
			roxy_input_processButtonB_l,
			roxy_input_processButtonUp_l,
			roxy_input_processButtonDown_l,
			roxy_input_processButtonLeft_l,
			roxy_input_processButtonRight_l
		};
		for (int i = 0; i < sizeof(inputFunctions) / sizeof(inputFunctions[0]); ++i) {
			if (!pd->lua->addFunction(inputFuncs[i], inputFunctions[i], &error)) {
				pd->system->logToConsole("%s:%i: addFunction failed, %s", __FILE__, __LINE__, error);
				return -1;
			}
		}
		
		roxy_sequence_setPlaydateAPI(pd);
		
		// ! Register Sequence Functions
		const char* sequenceFunctions[] = {
			"roxy.sequence.getClampedTime",
		};
		int (*sequenceFuncs[])(lua_State*) = {
			roxy_sequence_getClampedTime_l,
		};
		for (int i = 0; i < sizeof(sequenceFunctions) / sizeof(sequenceFunctions[0]); ++i) {
			if (!pd->lua->addFunction(sequenceFuncs[i], sequenceFunctions[i], &error)) {
				pd->system->logToConsole("%s:%i: addFunction failed, %s", __FILE__, __LINE__, error);
				return -1;
			}
		}
	}
	return 0;
}

// Calculates the time difference between frames and updates deltaTime for 
// use in Lua scripts
static int updateDeltaTime_l(lua_State* L) {
	(void)L;
	
	if (pd == NULL) {
		return 0;
	}
	
	uint32_t currentTime = pd->system->getCurrentTimeMilliseconds();
	
	if (previousTime == 0) {
		previousTime = currentTime;  // Initialize previousTime on first call
	}
	
	deltaTime = (currentTime - previousTime) / 1000.0f;
	previousTime = currentTime;
	
	pd->lua->pushFloat(deltaTime);
	return 1;
}
