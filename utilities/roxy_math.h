#ifndef ROXY_MATH_H
#define ROXY_MATH_H

#include "pd_api.h"

// ----------------------------------------
// ! Public API Function Prototypes
// ----------------------------------------

void roxy_math_setPlaydateAPI(PlaydateAPI* playdate);

// Truncates a floating-point number's decimal portion
int roxy_math_truncateDecimal(float n);

// Rounds a floating-point number to the nearest integer
float roxy_math_round(float n);

// Rounds a floating-point number down to the nearest integer
float roxy_math_roundDown(float n);

// Rounds a floating-point number up to the nearest integer
float roxy_math_roundUp(float n);

// Computes the hypotenuse given two sides of a right triangle
float roxy_math_hypot(float x, float y);

// Clamps a value between a lower and upper bound
float roxy_math_clamp(float value, float lower, float upper);

// Linearly interpolates between two values by a given factor
float roxy_math_lerp(float min, float max, float t);

// Maps a value from one range to another
float roxy_math_map(float value, float fromLow, float fromHigh, float toLow, float toHigh);

// ----------------------------------------
// ! Lua-Exposed Function Prototypes
// ----------------------------------------

int roxy_math_truncateDecimal_l(lua_State* L);
int roxy_math_round_l(lua_State* L);
int roxy_math_roundDown_l(lua_State* L);
int roxy_math_roundUp_l(lua_State* L);
int roxy_math_hypot_l(lua_State* L);
int roxy_math_clamp_l(lua_State* L);
int roxy_math_lerp_l(lua_State* L);
int roxy_math_map_l(lua_State* L);

#endif /* ROXY_MATH_H */