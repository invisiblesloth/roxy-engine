//
// Adapted from
// Tweener's easing functions (Penner's Easing Equations)
// and http://code.google.com/p/tweener/ (jstweener javascript version)
//

/*
 * Adapted from Robert Penner's Easing Equations.
 * 
 * TERMS OF USE - EASING EQUATIONS
 * 
 * Open source under the BSD License.
 * 
 * Copyright © 2001 Robert Penner
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
 * 
 *     * Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 *     * Neither the name of the author nor the names of contributors may be used to endorse or promote products derived from this software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
 
 // The flat easing function is adapted from Nic Magnier's Playdate Sequence library
 // (https://github.com/NicMagnier/PlaydateSequence), which is under the MIT license.

#ifndef ROXY_EASE_H
#define ROXY_EASE_H

#include "pd_api.h"

void roxy_easingFunctions_setPlaydateAPI(PlaydateAPI* playdate);

// Easing function prototypes

// Linear easing, no acceleration or deceleration
float roxy_ease_flat(float t, float b, float c, float d);  // Flat (constant) easing
float roxy_ease_linear(float t, float b, float c, float d);  // Linear easing

// Quadratic easing functions
float roxy_ease_in_quad(float t, float b, float c, float d);  // Acceleration from zero velocity
float roxy_ease_out_quad(float t, float b, float c, float d);  // Deceleration to zero velocity
float roxy_ease_in_out_quad(float t, float b, float c, float d);  // Acceleration then deceleration
float roxy_ease_out_in_quad(float t, float b, float c, float d);  // Deceleration then acceleration

// Cubic easing functions
float roxy_ease_in_cubic(float t, float b, float c, float d);
float roxy_ease_out_cubic(float t, float b, float c, float d);
float roxy_ease_in_out_cubic(float t, float b, float c, float d);
float roxy_ease_out_in_cubic(float t, float b, float c, float d);

// Quartic easing functions
float roxy_ease_in_quart(float t, float b, float c, float d);
float roxy_ease_out_quart(float t, float b, float c, float d);
float roxy_ease_in_out_quart(float t, float b, float c, float d);
float roxy_ease_out_in_quart(float t, float b, float c, float d);

// Quintic easing functions
float roxy_ease_in_quint(float t, float b, float c, float d);
float roxy_ease_out_quint(float t, float b, float c, float d);
float roxy_ease_in_out_quint(float t, float b, float c, float d);
float roxy_ease_out_in_quint(float t, float b, float c, float d);

// Sine wave easing functions
float roxy_ease_in_sine(float t, float b, float c, float d);
float roxy_ease_out_sine(float t, float b, float c, float d);
float roxy_ease_in_out_sine(float t, float b, float c, float d);
float roxy_ease_out_in_sine(float t, float b, float c, float d);

// Exponential easing functions
float roxy_ease_in_expo(float t, float b, float c, float d);
float roxy_ease_out_expo(float t, float b, float c, float d);
float roxy_ease_in_out_expo(float t, float b, float c, float d);
float roxy_ease_out_in_expo(float t, float b, float c, float d);

// Circular easing functions
float roxy_ease_in_circ(float t, float b, float c, float d);
float roxy_ease_out_circ(float t, float b, float c, float d);
float roxy_ease_in_out_circ(float t, float b, float c, float d);
float roxy_ease_out_in_circ(float t, float b, float c, float d);

// Elastic easing functions (overshooting beyond start/end values)
float roxy_ease_in_elastic(float t, float b, float c, float d, float a, float p);
float roxy_ease_out_elastic(float t, float b, float c, float d, float a, float p);
float roxy_ease_in_out_elastic(float t, float b, float c, float d, float a, float p);
float roxy_ease_out_in_elastic(float t, float b, float c, float d, float a, float p);

// Back easing functions (overshooting slightly before settling)
float roxy_ease_in_back(float t, float b, float c, float d, float s);
float roxy_ease_out_back(float t, float b, float c, float d, float s);
float roxy_ease_in_out_back(float t, float b, float c, float d, float s);
float roxy_ease_out_in_back(float t, float b, float c, float d, float s);

// Bounce easing functions
float roxy_ease_out_bounce(float t, float b, float c, float d);
float roxy_ease_in_bounce(float t, float b, float c, float d);
float roxy_ease_in_out_bounce(float t, float b, float c, float d);
float roxy_ease_out_in_bounce(float t, float b, float c, float d);

// Lua wrapper function prototypes
// (Wrappers for the easing functions, for use within the Lua environment)
int roxy_ease_flat_l(lua_State* L);
int roxy_ease_linear_l(lua_State* L);
int roxy_ease_in_quad_l(lua_State* L);
int roxy_ease_out_quad_l(lua_State* L);
int roxy_ease_in_out_quad_l(lua_State* L);
int roxy_ease_out_in_quad_l(lua_State* L);
int roxy_ease_in_cubic_l(lua_State* L);
int roxy_ease_out_cubic_l(lua_State* L);
int roxy_ease_in_out_cubic_l(lua_State* L);
int roxy_ease_out_in_cubic_l(lua_State* L);
int roxy_ease_in_quart_l(lua_State* L);
int roxy_ease_out_quart_l(lua_State* L);
int roxy_ease_in_out_quart_l(lua_State* L);
int roxy_ease_out_in_quart_l(lua_State* L);
int roxy_ease_in_quint_l(lua_State* L);
int roxy_ease_out_quint_l(lua_State* L);
int roxy_ease_in_out_quint_l(lua_State* L);
int roxy_ease_out_in_quint_l(lua_State* L);
int roxy_ease_in_sine_l(lua_State* L);
int roxy_ease_out_sine_l(lua_State* L);
int roxy_ease_in_out_sine_l(lua_State* L);
int roxy_ease_out_in_sine_l(lua_State* L);
int roxy_ease_in_expo_l(lua_State* L);
int roxy_ease_out_expo_l(lua_State* L);
int roxy_ease_in_out_expo_l(lua_State* L);
int roxy_ease_out_in_expo_l(lua_State* L);
int roxy_ease_in_circ_l(lua_State* L);
int roxy_ease_out_circ_l(lua_State* L);
int roxy_ease_in_out_circ_l(lua_State* L);
int roxy_ease_out_in_circ_l(lua_State* L);
int roxy_ease_in_elastic_l(lua_State* L);
int roxy_ease_out_elastic_l(lua_State* L);
int roxy_ease_in_out_elastic_l(lua_State* L);
int roxy_ease_out_in_elastic_l(lua_State* L);
int roxy_ease_in_back_l(lua_State* L);
int roxy_ease_out_back_l(lua_State* L);
int roxy_ease_in_out_back_l(lua_State* L);
int roxy_ease_out_in_back_l(lua_State* L);
int roxy_ease_out_bounce_l(lua_State* L);
int roxy_ease_in_bounce_l(lua_State* L);
int roxy_ease_in_out_bounce_l(lua_State* L);
int roxy_ease_out_in_bounce_l(lua_State* L);

#endif /* ROXY_EASE_H */
