// libraries/roxy/utilities/roxy_ease.c

// Adapted from
// Tweener's easing functions (Penner's Easing Equations)
// and http://code.google.com/p/tweener/ (jstweener javascript version)

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
 
// For all easing functions:
// t = elapsed time
// b = begin
// c = change == ending - beginning
// d = duration (total time)

#include "roxy_ease.h"
#include <math.h>

static PlaydateAPI* pd = NULL;

void roxy_easingFunctions_setPlaydateAPI(PlaydateAPI* playdate) {
	pd = playdate;
}

// Flat easing function
float roxy_ease_flat(float t, float b, float c, float d) {
	return b;
}

// Lua wrapper for roxy_ease_flat
int roxy_ease_flat_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_flat(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// Linear easing function
float roxy_ease_linear(float t, float b, float c, float d) {
	return c * t / d + b;
}

// Lua wrapper for roxy_ease_linear
int roxy_ease_linear_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_linear(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InQuad easing function
float roxy_ease_in_quad(float t, float b, float c, float d) {
	t = t / d;
	return c * t * t + b;
}

// Lua wrapper for roxy_ease_in_quad
int roxy_ease_in_quad_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_quad(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutQuad easing function
float roxy_ease_out_quad(float t, float b, float c, float d) {
	t = t / d;
	return -c * t * (t - 2) + b;
}

// Lua wrapper for roxy_ease_out_quad
int roxy_ease_out_quad_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_quad(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutQuad easing function
float roxy_ease_in_out_quad(float t, float b, float c, float d) {
	t = t / d * 2;
	if (t < 1) {
		return c / 2 * t * t + b;
	} else {
		t = t - 1;
		return -c / 2 * (t * (t - 2) - 1) + b;
	}
}

// Lua wrapper for roxy_ease_in_out_quad
int roxy_ease_in_out_quad_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_out_quad(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInQuad easing function
float roxy_ease_out_in_quad(float t, float b, float c, float d) {
	if (t < d / 2) {
		return roxy_ease_out_quad(t * 2, b, c / 2, d);
	} else {
		return roxy_ease_in_quad((t * 2) - d, b + c / 2, c / 2, d);
	}
}

// Lua wrapper for roxy_ease_out_in_quad
int roxy_ease_out_in_quad_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_in_quad(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InCubic easing function
float roxy_ease_in_cubic(float t, float b, float c, float d) {
	t = t / d;
	return c * t * t * t + b;
}

// Lua wrapper for roxy_ease_in_cubic
int roxy_ease_in_cubic_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_cubic(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutCubic easing function
float roxy_ease_out_cubic(float t, float b, float c, float d) {
	t = t / d - 1;
	return c * (t * t * t + 1) + b;
}

// Lua wrapper for roxy_ease_out_cubic
int roxy_ease_out_cubic_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_cubic(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutCubic easing function
float roxy_ease_in_out_cubic(float t, float b, float c, float d) {
	t = t / d * 2;
	if (t < 1) {
		return c / 2 * t * t * t + b;
	} else {
		t = t - 2;
		return c / 2 * (t * t * t + 2) + b;
	}
}

// Lua wrapper for roxy_ease_in_out_cubic
int roxy_ease_in_out_cubic_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_out_cubic(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInCubic easing function
float roxy_ease_out_in_cubic(float t, float b, float c, float d) {
	if (t < d / 2) {
		return roxy_ease_out_cubic(t * 2, b, c / 2, d);
	} else {
		return roxy_ease_in_cubic((t * 2) - d, b + c / 2, c / 2, d);
	}
}

// Lua wrapper for roxy_ease_out_in_cubic
int roxy_ease_out_in_cubic_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_in_cubic(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InQuart easing function
float roxy_ease_in_quart(float t, float b, float c, float d) {
	t = t / d;
	return c * t * t * t * t + b;
}

// Lua wrapper for roxy_ease_in_quart
int roxy_ease_in_quart_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_quart(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutQuart easing function
float roxy_ease_out_quart(float t, float b, float c, float d) {
	t = t / d - 1;
	return -c * (t * t * t * t - 1) + b;
}

// Lua wrapper for roxy_ease_out_quart
int roxy_ease_out_quart_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_quart(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutQuart easing function
float roxy_ease_in_out_quart(float t, float b, float c, float d) {
	t = t / d * 2;
	if (t < 1) {
		return c / 2 * t * t * t * t + b;
	} else {
		t = t - 2;
		return -c / 2 * (t * t * t * t - 2) + b;
	}
}

// Lua wrapper for roxy_ease_in_out_quart
int roxy_ease_in_out_quart_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_out_quart(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInQuart easing function
float roxy_ease_out_in_quart(float t, float b, float c, float d) {
	if (t < d / 2) {
		return roxy_ease_out_quart(t * 2, b, c / 2, d);
	} else {
		return roxy_ease_in_quart((t * 2) - d, b + c / 2, c / 2, d);
	}
}

// Lua wrapper for roxy_ease_out_in_quart
int roxy_ease_out_in_quart_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_in_quart(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InQuint easing function
float roxy_ease_in_quint(float t, float b, float c, float d) {
	t = t / d;
	return c * t * t * t * t * t + b;
}

// Lua wrapper for roxy_ease_in_quint
int roxy_ease_in_quint_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_quint(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutQuint easing function
float roxy_ease_out_quint(float t, float b, float c, float d) {
	t = t / d - 1;
	return c * (t * t * t * t * t + 1) + b;
}

// Lua wrapper for roxy_ease_out_quint
int roxy_ease_out_quint_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_quint(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutQuint easing function
float roxy_ease_in_out_quint(float t, float b, float c, float d) {
	t = t / d * 2;
	if (t < 1) {
		return c / 2 * t * t * t * t * t + b;
	} else {
		t = t - 2;
		return c / 2 * (t * t * t * t * t + 2) + b;
	}
}

// Lua wrapper for roxy_ease_in_out_quint
int roxy_ease_in_out_quint_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_out_quint(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInQuint easing function
float roxy_ease_out_in_quint(float t, float b, float c, float d) {
	if (t < d / 2) {
		return roxy_ease_out_quint(t * 2, b, c / 2, d);
	} else {
		return roxy_ease_in_quint((t * 2) - d, b + c / 2, c / 2, d);
	}
}

// Lua wrapper for roxy_ease_out_in_quint
int roxy_ease_out_in_quint_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_in_quint(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InSine easing function
float roxy_ease_in_sine(float t, float b, float c, float d) {
	return -c * cosf(t / d * ((float)M_PI / 2)) + c + b;
}

// Lua wrapper for roxy_ease_in_sine
int roxy_ease_in_sine_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_sine(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutSine easing function
float roxy_ease_out_sine(float t, float b, float c, float d) {
	return c * sinf(t / d * ((float)M_PI / 2)) + b;
}

// Lua wrapper for roxy_ease_out_sine
int roxy_ease_out_sine_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_sine(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutSine easing function
float roxy_ease_in_out_sine(float t, float b, float c, float d) {
	return -c / 2 * (cosf((float)M_PI * t / d) - 1) + b;
}

// Lua wrapper for roxy_ease_in_out_sine
int roxy_ease_in_out_sine_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_out_sine(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInSine easing function
float roxy_ease_out_in_sine(float t, float b, float c, float d) {
	if (t < d / 2) {
		return roxy_ease_out_sine(t * 2, b, c / 2, d);
	} else {
		return roxy_ease_in_sine((t * 2) - d, b + c / 2, c / 2, d);
	}
}

// Lua wrapper for roxy_ease_out_in_sine
int roxy_ease_out_in_sine_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_in_sine(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InExpo easing function
float roxy_ease_in_expo(float t, float b, float c, float d) {
	if (t == 0) return b;
	return c * powf(2, 10 * (t / d - 1)) + b - c * 0.001f;
}

// Lua wrapper for roxy_ease_in_expo
int roxy_ease_in_expo_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_expo(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutExpo easing function
float roxy_ease_out_expo(float t, float b, float c, float d) {
	if (t == d) return b + c;
	return c * 1.001f * (1 - powf(2, -10 * t / d)) + b;
}

// Lua wrapper for roxy_ease_out_expo
int roxy_ease_out_expo_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_expo(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutExpo easing function
float roxy_ease_in_out_expo(float t, float b, float c, float d) {
	if (t == 0) return b;
	if (t == d) return b + c;
	t = t / d * 2;
	if (t < 1) {
		return c / 2 * powf(2, 10 * (t - 1)) + b - c * 0.0005f;
	} else {
		t = t - 1;
		return c / 2 * 1.0005f * (2 - powf(2, -10 * t)) + b;
	}
}

// Lua wrapper for roxy_ease_in_out_expo
int roxy_ease_in_out_expo_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_out_expo(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInExpo easing function
float roxy_ease_out_in_expo(float t, float b, float c, float d) {
	if (t < d / 2) {
		return roxy_ease_out_expo(t * 2, b, c / 2, d);
	} else {
		return roxy_ease_in_expo((t * 2) - d, b + c / 2, c / 2, d);
	}
}

// Lua wrapper for roxy_ease_out_in_expo
int roxy_ease_out_in_expo_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_in_expo(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InCirc easing function
float roxy_ease_in_circ(float t, float b, float c, float d) {
	t = t / d;
	return -c * (sqrtf(1 - t * t) - 1) + b;
}

// Lua wrapper for roxy_ease_in_circ
int roxy_ease_in_circ_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_circ(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutCirc easing function
float roxy_ease_out_circ(float t, float b, float c, float d) {
	t = t / d - 1;
	return c * sqrtf(1 - t * t) + b;
}

// Lua wrapper for roxy_ease_out_circ
int roxy_ease_out_circ_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_circ(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutCirc easing function
float roxy_ease_in_out_circ(float t, float b, float c, float d) {
	t = t / d * 2;
	if (t < 1) {
		return -c / 2 * (sqrtf(1 - t * t) - 1) + b;
	} else {
		t = t - 2;
		return c / 2 * (sqrtf(1 - t * t) + 1) + b;
	}
}

// Lua wrapper for roxy_ease_in_out_circ
int roxy_ease_in_out_circ_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_out_circ(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInCirc easing function
float roxy_ease_out_in_circ(float t, float b, float c, float d) {
	if (t < d / 2) {
		return roxy_ease_out_circ(t * 2, b, c / 2, d);
	} else {
		return roxy_ease_in_circ((t * 2) - d, b + c / 2, c / 2, d);
	}
}

// Lua wrapper for roxy_ease_out_in_circ
int roxy_ease_out_in_circ_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_in_circ(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InElastic easing function
float roxy_ease_in_elastic(float t, float b, float c, float d, float a, float p) {
	if (t == 0) return b;
	t = t / d;
	if (t == 1) return b + c;
	if (!p) p = d * 0.3f;
	float s;
	if (!a || a < fabsf(c)) {
		a = c;
		s = p / 4;
	} else {
		s = p / (2 * (float)M_PI) * asinf(c / a);
	}
	t = t - 1;
	return -(a * powf(2, 10 * t) * sinf((t * d - s) * (2 * (float)M_PI) / p)) + b;
}

// Lua wrapper for roxy_ease_in_elastic
int roxy_ease_in_elastic_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float a = (pd->lua->getArgCount() > 4) ? pd->lua->getArgFloat(5) : 1.0f;
	float p = (pd->lua->getArgCount() > 5) ? pd->lua->getArgFloat(6) : 0.3f;
	float result = roxy_ease_in_elastic(t, b, c, d, a, p);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutElastic easing function
float roxy_ease_out_elastic(float t, float b, float c, float d, float a, float p) {
	if (t == 0) return b;
	t = t / d;
	if (t == 1) return b + c;
	if (!p) p = d * 0.3f;
	float s;
	if (!a || a < fabsf(c)) {
		a = c;
		s = p / 4;
	} else {
		s = p / (2 * (float)M_PI) * asinf(c / a);
	}
	return a * powf(2, -10 * t) * sinf((t * d - s) * (2 * (float)M_PI) / p) + c + b;
}

// Lua wrapper for roxy_ease_out_elastic
int roxy_ease_out_elastic_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float a = (pd->lua->getArgCount() > 4) ? pd->lua->getArgFloat(5) : 1.0f;
	float p = (pd->lua->getArgCount() > 5) ? pd->lua->getArgFloat(6) : 0.3f;
	float result = roxy_ease_out_elastic(t, b, c, d, a, p);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutElastic easing function
float roxy_ease_in_out_elastic(float t, float b, float c, float d, float a, float p) {
	if (t == 0) return b;
	t = t / d * 2;
	if (t == 2) return b + c;
	if (!p) p = d * (0.3f * 1.5f);
	if (!a) a = 0;
	float s;
	if (!a || a < fabsf(c)) {
		a = c;
		s = p / 4;
	} else {
		s = p / (2 * (float)M_PI) * asinf(c / a);
	}
	if (t < 1) {
		t = t - 1;
		return -0.5f * (a * powf(2, 10 * t) * sinf((t * d - s) * (2 * (float)M_PI) / p)) + b;
	} else {
		t = t - 1;
		return a * powf(2, -10 * t) * sinf((t * d - s) * (2 * (float)M_PI) / p) * 0.5f + c + b;
	}
}

// Lua wrapper for roxy_ease_in_out_elastic
int roxy_ease_in_out_elastic_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float a = (pd->lua->getArgCount() > 4) ? pd->lua->getArgFloat(5) : 1.0f;
	float p = (pd->lua->getArgCount() > 5) ? pd->lua->getArgFloat(6) : 0.3f;
	float result = roxy_ease_in_out_elastic(t, b, c, d, a, p);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInElastic easing function
float roxy_ease_out_in_elastic(float t, float b, float c, float d, float a, float p) {
	if (t < d / 2) {
		return roxy_ease_out_elastic(t * 2, b, c / 2, d, a, p);
	} else {
		return roxy_ease_in_elastic((t * 2) - d, b + c / 2, c / 2, d, a, p);
	}
}

// Lua wrapper for roxy_ease_out_in_elastic
int roxy_ease_out_in_elastic_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float a = (pd->lua->getArgCount() > 4) ? pd->lua->getArgFloat(5) : 1.0f;
	float p = (pd->lua->getArgCount() > 5) ? pd->lua->getArgFloat(6) : 0.3f;
	float result = roxy_ease_out_in_elastic(t, b, c, d, a, p);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InBack easing function
float roxy_ease_in_back(float t, float b, float c, float d, float s) {
	if (!s) s = 1.70158f;
	t = t / d;
	return c * t * t * ((s + 1) * t - s) + b;
}

// Lua wrapper for roxy_ease_in_back
int roxy_ease_in_back_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float s = (pd->lua->getArgCount() > 4) ? pd->lua->getArgFloat(5) : 1.70158f;
	float result = roxy_ease_in_back(t, b, c, d, s);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutBack easing function
float roxy_ease_out_back(float t, float b, float c, float d, float s) {
	if (!s) s = 1.70158f;
	t = t / d - 1;
	return c * (t * t * ((s + 1) * t + s) + 1) + b;
}

// Lua wrapper for roxy_ease_out_back
int roxy_ease_out_back_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float s = (pd->lua->getArgCount() > 4) ? pd->lua->getArgFloat(5) : 1.70158f;
	float result = roxy_ease_out_back(t, b, c, d, s);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutBack easing function
float roxy_ease_in_out_back(float t, float b, float c, float d, float s) {
	if (!s) s = 1.70158f;
	s = s * 1.525f;
	t = t / d * 2;
	if (t < 1) {
		return c / 2 * (t * t * ((s + 1) * t - s)) + b;
	} else {
		t = t - 2;
		return c / 2 * (t * t * ((s + 1) * t + s) + 2) + b;
	}
}

// Lua wrapper for roxy_ease_in_out_back
int roxy_ease_in_out_back_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float s = (pd->lua->getArgCount() > 4) ? pd->lua->getArgFloat(5) : 1.70158f;
	float result = roxy_ease_in_out_back(t, b, c, d, s);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInBack easing function
float roxy_ease_out_in_back(float t, float b, float c, float d, float s) {
	if (t < d / 2) {
		return roxy_ease_out_back(t * 2, b, c / 2, d, s);
	} else {
		return roxy_ease_in_back((t * 2) - d, b + c / 2, c / 2, d, s);
	}
}

// Lua wrapper for roxy_ease_out_in_back
int roxy_ease_out_in_back_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float s = (pd->lua->getArgCount() > 4) ? pd->lua->getArgFloat(5) : 1.70158f;
	float result = roxy_ease_out_in_back(t, b, c, d, s);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutBounce easing function
float roxy_ease_out_bounce(float t, float b, float c, float d) {
	t = t / d;
	if (t < 1 / 2.75f) {
		return c * (7.5625f * t * t) + b;
	} else if (t < 2 / 2.75f) {
		t = t - (1.5f / 2.75f);
		return c * (7.5625f * t * t + 0.75f) + b;
	} else if (t < 2.5f / 2.75f) {
		t = t - (2.25f / 2.75f);
		return c * (7.5625f * t * t + 0.9375f) + b;
	} else {
		t = t - (2.625f / 2.75f);
		return c * (7.5625f * t * t + 0.984375f) + b;
	}
}

// Lua wrapper for roxy_ease_out_bounce
int roxy_ease_out_bounce_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_bounce(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InBounce easing function
float roxy_ease_in_bounce(float t, float b, float c, float d) {
	return c - roxy_ease_out_bounce(d - t, 0, c, d) + b;
}

// Lua wrapper for roxy_ease_in_bounce
int roxy_ease_in_bounce_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_bounce(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// InOutBounce easing function
float roxy_ease_in_out_bounce(float t, float b, float c, float d) {
	if (t < d / 2) {
		return roxy_ease_in_bounce(t * 2, 0, c, d) * 0.5f + b;
	} else {
		return roxy_ease_out_bounce(t * 2 - d, 0, c, d) * 0.5f + c * 0.5f + b;
	}
}

// Lua wrapper for roxy_ease_in_out_bounce
int roxy_ease_in_out_bounce_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_in_out_bounce(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}

// OutInBounce easing function
float roxy_ease_out_in_bounce(float t, float b, float c, float d) {
	if (t < d / 2) {
		return roxy_ease_out_bounce(t * 2, b, c / 2, d);
	} else {
		return roxy_ease_in_bounce((t * 2) - d, b + c / 2, c / 2, d);
	}
}

// Lua wrapper for roxy_ease_out_in_bounce
int roxy_ease_out_in_bounce_l(lua_State* L) {
	(void)L;
	
	float t = pd->lua->getArgFloat(1);
	float b = pd->lua->getArgFloat(2);
	float c = pd->lua->getArgFloat(3);
	float d = pd->lua->getArgFloat(4);
	float result = roxy_ease_out_in_bounce(t, b, c, d);
	
	pd->lua->pushFloat(result);
	return 1;
}
