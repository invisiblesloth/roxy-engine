#include "roxy_math.h"
#include <math.h>

static PlaydateAPI* pd = NULL;

void roxy_math_setPlaydateAPI(PlaydateAPI* playdate) {
	pd = playdate;
}

// Truncates the decimal part of a floating-point number
float roxy_math_truncateDecimal(float n) {
	return n - fmodf(n, 1.0f);
}

// Lua binding for truncateDecimal
int roxy_math_truncateDecimal_l(lua_State* L) {
	(void)L;
	
	float n = pd->lua->getArgFloat(1);
	float result = roxy_math_truncateDecimal(n);
	
	pd->lua->pushFloat(result);
	return 1;
}

// Rounds a floating-point number to the nearest integer
float roxy_math_round(float n) {
	return floorf(n + 0.5f);
}

// Lua binding for round
int roxy_math_round_l(lua_State* L) {
	(void)L;
	
	float n = pd->lua->getArgFloat(1);
	float result = roxy_math_round(n);
	
	pd->lua->pushFloat(result);
	return 1;
}

// Rounds a floating-point number down to the nearest integer
float roxy_math_roundDown(float n) {
	return floorf(n);
}

// Lua binding for roundDown
int roxy_math_roundDown_l(lua_State* L) {
	(void)L;
	
	float n = pd->lua->getArgFloat(1);
	float result = roxy_math_roundDown(n);
	
	pd->lua->pushFloat(result);
	return 1;
}

// Rounds a floating-point number up to the nearest integer
float roxy_math_roundUp(float n) {
	return ceilf(n);
}

// Lua binding for roundUp
int roxy_math_roundUp_l(lua_State* L) {
	(void)L;
	
	float n = pd->lua->getArgFloat(1);
	float result = roxy_math_roundUp(n);
	
	pd->lua->pushFloat(result);
	return 1;
}

// Computes the hypotenuse given two sides of a right triangle
float roxy_math_hypot(float x, float y) {
	return sqrtf(x * x + y * y);
}

// Lua binding for hypot
int roxy_math_hypot_l(lua_State* L) {
	(void)L;
	
	float x = pd->lua->getArgFloat(1);
	float y = pd->lua->getArgFloat(2);
	float result = roxy_math_hypot(x, y);
	
	pd->lua->pushFloat(result);
	return 1;
}

// Clamps a value between a lower and upper bound
float roxy_math_clamp(float value, float lower, float upper) {
	if (lower > upper) {
		float temp = lower;
		lower = upper;
		upper = temp;
	}
	return value < lower ? lower : (value > upper ? upper : value);
}

// Lua binding for clamp
int roxy_math_clamp_l(lua_State* L) {
	(void)L;
	
	float value = pd->lua->getArgFloat(1);
	float lower = pd->lua->getArgFloat(2);
	float upper = pd->lua->getArgFloat(3);
	float result = roxy_math_clamp(value, lower, upper);
	
	pd->lua->pushFloat(result);
	return 1;
}

// Performs linear interpolation between two values
float roxy_math_lerp(float a, float b, float t) {
	return a + (b - a) * t;
}

// Lua binding for lerp
int roxy_math_lerp_l(lua_State* L) {
	(void)L;
	
	float a = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float t = pd->lua->getArgFloat(3);
	float result = roxy_math_lerp(a, b, t);
	
	pd->lua->pushFloat(result);
	return 1;
}

// Maps a value from one range to another
float roxy_math_map(float value, float fromLow, float fromHigh, float toLow, float toHigh) {
	return (value - fromLow) / (fromHigh - fromLow) * (toHigh - toLow) + toLow;
}

// Lua binding for map
int roxy_math_map_l(lua_State* L) {
	(void)L;
	
	float value = pd->lua->getArgFloat(1);
	float fromLow = pd->lua->getArgFloat(2);
	float fromHigh = pd->lua->getArgFloat(3);
	float toLow = pd->lua->getArgFloat(4);
	float toHigh = pd->lua->getArgFloat(5);
	float result = roxy_math_map(value, fromLow, fromHigh, toLow, toHigh);
	
	pd->lua->pushFloat(result);
	return 1;
}
