// utilities/roxy_ease.c

/*
 * Adapted from
 * Tweener's easing functions (Penner's Easing Equations)
 * and http://code.google.com/p/tweener/ (jstweener javascript version)
 */

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
 *
 */

/*
 * The flat easing function is adapted from Nic Magnier's Playdate Sequence library
 * (https://github.com/NicMagnier/PlaydateSequence), which is under the MIT license.
 */

// For all easing functions:
// t = elapsed time
// b = begin
// c = change == ending - beginning
// d = duration (total time)

#include "roxy_ease.h"
#include <math.h>

static PlaydateAPI* pd = NULL;

static EaseFunction s_easingFunctions[] = {
    roxy_ease_flat,                 //  0
    roxy_ease_linear,               //  1
    roxy_ease_in_quad,              //  2
    roxy_ease_out_quad,             //  3
    roxy_ease_in_out_quad,          //  4
    roxy_ease_out_in_quad,          //  5
    roxy_ease_in_cubic,             //  6
    roxy_ease_out_cubic,            //  7
    roxy_ease_in_out_cubic,         //  8
    roxy_ease_out_in_cubic,         //  9
    roxy_ease_in_quart,             // 10
    roxy_ease_out_quart,            // 11
    roxy_ease_in_out_quart,         // 12
    roxy_ease_out_in_quart,         // 13
    roxy_ease_in_quint,             // 14
    roxy_ease_out_quint,            // 15
    roxy_ease_in_out_quint,         // 16
    roxy_ease_out_in_quint,         // 17
    roxy_ease_in_sine,              // 18
    roxy_ease_out_sine,             // 19
    roxy_ease_in_out_sine,          // 20
    roxy_ease_out_in_sine,          // 21
    roxy_ease_in_expo,              // 22
    roxy_ease_out_expo,             // 23
    roxy_ease_in_out_expo,          // 24
    roxy_ease_out_in_expo,          // 25
    roxy_ease_in_circ,              // 26
    roxy_ease_out_circ,             // 27
    roxy_ease_in_out_circ,          // 28
    roxy_ease_out_in_circ,          // 29
    roxy_ease_out_bounce,           // 38
    roxy_ease_in_bounce,            // 39
    roxy_ease_in_out_bounce,        // 40
    roxy_ease_out_in_bounce         // 41
};

static ElasticEaseFunction s_elasticFunctions[] = {
    roxy_ease_in_elastic,           // 30
    roxy_ease_out_elastic,          // 31
    roxy_ease_in_out_elastic,       // 32
    roxy_ease_out_in_elastic        // 33
};

static BackEaseFunction s_backFunctions[] = {
    roxy_ease_in_back,              // 34
    roxy_ease_out_back,             // 35
    roxy_ease_in_out_back,          // 36
    roxy_ease_out_in_back           // 37
};

// Index mapping is:
//   0-29, 38-41 => normal
//   30-33 => elastic
//   34-37 => back

static int s_normalCount = 30 + 4;

void roxy_easingFunctions_setPlaydateAPI(PlaydateAPI* playdate)
{
    pd = playdate;
}

// ! Roxy Ease Evaluate
// The one “public” function that decides which pointer array to call
float roxy_ease_evaluate(
    int index,
    float t,
    float b,
    float c,
    float d,
    float paramA,
    float paramB
){
    // (1) total counts
    int normalCount   = sizeof(s_easingFunctions) / sizeof(s_easingFunctions[0]); // e.g. 34
    int elasticCount  = sizeof(s_elasticFunctions) / sizeof(s_elasticFunctions[0]); // 4
    int backCount     = sizeof(s_backFunctions) / sizeof(s_backFunctions[0]);       // 4
    int maxIndex      = normalCount + elasticCount + backCount - 1; // e.g. 41

    // (2) clamp index
    if (index < 0 || index > maxIndex) {
        index = 1; // default to linear
    }

    // (3) pick which array
    // normal range e.g. 0..29 and 38..41
    if ((index < 30) || (index >= 38 && index <= 41)) {
        // Normal
        EaseFunction fn = s_easingFunctions[index];
        return fn(t, b, c, d);
    }
    else if (index >= 30 && index <= 33) {
        // Elastic
        ElasticEaseFunction fn = s_elasticFunctions[index - 30];
        return fn(t, b, c, d, paramA, paramB);
    }
    else {
        // Back (34..37)
        BackEaseFunction fn = s_backFunctions[index - 34];
        return fn(t, b, c, d, paramA);
    }
}

// ----------------------------------------
// Public API
// ----------------------------------------

// ! Flat
float roxy_ease_flat(float t, float b, float c, float d)
{
    return b;
}

// ! Linear
float roxy_ease_linear(float t, float b, float c, float d)
{
    return c * t / d + b;
}

// ! InQuad
float roxy_ease_in_quad(float t, float b, float c, float d)
{
    t = t / d;
    return c * t * t + b;
}

// ! OutQuad
float roxy_ease_out_quad(float t, float b, float c, float d)
{
    t = t / d;
    return -c * t * (t - 2) + b;
}

// ! InOutQuad
float roxy_ease_in_out_quad(float t, float b, float c, float d)
{
    t = t / d * 2;
    if (t < 1) {
        return c / 2 * t * t + b;
    } else {
        t = t - 1;
        return -c / 2 * (t * (t - 2) - 1) + b;
    }
}

// ! OutInQuad
float roxy_ease_out_in_quad(float t, float b, float c, float d)
{
    if (t < d / 2) {
        return roxy_ease_out_quad(t * 2, b, c / 2, d);
    } else {
        return roxy_ease_in_quad((t * 2) - d, b + c / 2, c / 2, d);
    }
}

// ! InCubic
float roxy_ease_in_cubic(float t, float b, float c, float d)
{
    t = t / d;
    return c * t * t * t + b;
}

// ! OutCubic
float roxy_ease_out_cubic(float t, float b, float c, float d)
{
    t = t / d - 1;
    return c * (t * t * t + 1) + b;
}

// ! InOutCubic
float roxy_ease_in_out_cubic(float t, float b, float c, float d)
{
    t = t / d * 2;
    if (t < 1) {
        return c / 2 * t * t * t + b;
    } else {
        t = t - 2;
        return c / 2 * (t * t * t + 2) + b;
    }
}

// ! OutInCubic
float roxy_ease_out_in_cubic(float t, float b, float c, float d)
{
    if (t < d / 2) {
        return roxy_ease_out_cubic(t * 2, b, c / 2, d);
    } else {
        return roxy_ease_in_cubic((t * 2) - d, b + c / 2, c / 2, d);
    }
}

// ! InQuart
float roxy_ease_in_quart(float t, float b, float c, float d)
{
    t = t / d;
    return c * t * t * t * t + b;
}

// ! OutQuart
float roxy_ease_out_quart(float t, float b, float c, float d)
{
    t = t / d - 1;
    return -c * (t * t * t * t - 1) + b;
}

// ! InOutQuart
float roxy_ease_in_out_quart(float t, float b, float c, float d)
{
    t = t / d * 2;
    if (t < 1) {
        return c / 2 * t * t * t * t + b;
    } else {
        t = t - 2;
        return -c / 2 * (t * t * t * t - 2) + b;
    }
}

// ! OutInQuart
float roxy_ease_out_in_quart(float t, float b, float c, float d)
{
    if (t < d / 2) {
        return roxy_ease_out_quart(t * 2, b, c / 2, d);
    } else {
        return roxy_ease_in_quart((t * 2) - d, b + c / 2, c / 2, d);
    }
}

// ! InQuint
float roxy_ease_in_quint(float t, float b, float c, float d)
{
    t = t / d;
    return c * t * t * t * t * t + b;
}

// ! OutQuint
float roxy_ease_out_quint(float t, float b, float c, float d)
{
    t = t / d - 1;
    return c * (t * t * t * t * t + 1) + b;
}

// ! InOutQuint
float roxy_ease_in_out_quint(float t, float b, float c, float d)
{
    t = t / d * 2;
    if (t < 1) {
        return c / 2 * t * t * t * t * t + b;
    } else {
        t = t - 2;
        return c / 2 * (t * t * t * t * t + 2) + b;
    }
}

// ! OutInQuint
float roxy_ease_out_in_quint(float t, float b, float c, float d)
{
    if (t < d / 2) {
        return roxy_ease_out_quint(t * 2, b, c / 2, d);
    } else {
        return roxy_ease_in_quint((t * 2) - d, b + c / 2, c / 2, d);
    }
}

// ! InSine
float roxy_ease_in_sine(float t, float b, float c, float d)
{
    return -c * cosf(t / d * ((float)M_PI / 2)) + c + b;
}

// ! OutSine
float roxy_ease_out_sine(float t, float b, float c, float d)
{
    return c * sinf(t / d * ((float)M_PI / 2)) + b;
}

// ! InOutSine
float roxy_ease_in_out_sine(float t, float b, float c, float d)
{
    return -c / 2 * (cosf((float)M_PI * t / d) - 1) + b;
}

// ! OutInSine
float roxy_ease_out_in_sine(float t, float b, float c, float d)
{
    if (t < d / 2) {
        return roxy_ease_out_sine(t * 2, b, c / 2, d);
    } else {
        return roxy_ease_in_sine((t * 2) - d, b + c / 2, c / 2, d);
    }
}

// ! InExpo
float roxy_ease_in_expo(float t, float b, float c, float d)
{
    if (t == 0) return b;
    return c * powf(2, 10 * (t / d - 1)) + b - c * 0.001f;
}

// ! OutExpo
float roxy_ease_out_expo(float t, float b, float c, float d)
{
    if (t == d) return b + c;
    return c * 1.001f * (1 - powf(2, -10 * t / d)) + b;
}

// ! InOutExpo
float roxy_ease_in_out_expo(float t, float b, float c, float d)
{
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

// ! OutInExpo
float roxy_ease_out_in_expo(float t, float b, float c, float d)
{
    if (t < d / 2) {
        return roxy_ease_out_expo(t * 2, b, c / 2, d);
    } else {
        return roxy_ease_in_expo((t * 2) - d, b + c / 2, c / 2, d);
    }
}

// ! InCirc
float roxy_ease_in_circ(float t, float b, float c, float d)
{
    t = t / d;
    return -c * (sqrtf(1 - t * t) - 1) + b;
}

// ! OutCirc
float roxy_ease_out_circ(float t, float b, float c, float d)
{
    t = t / d - 1;
    return c * sqrtf(1 - t * t) + b;
}

// ! InOutCirc
float roxy_ease_in_out_circ(float t, float b, float c, float d)
{
    t = t / d * 2;
    if (t < 1) {
        return -c / 2 * (sqrtf(1 - t * t) - 1) + b;
    } else {
        t = t - 2;
        return c / 2 * (sqrtf(1 - t * t) + 1) + b;
    }
}

// ! OutInCirc
float roxy_ease_out_in_circ(float t, float b, float c, float d)
{
    if (t < d / 2) {
        return roxy_ease_out_circ(t * 2, b, c / 2, d);
    } else {
        return roxy_ease_in_circ((t * 2) - d, b + c / 2, c / 2, d);
    }
}

// ! InElastic
float roxy_ease_in_elastic(float t, float b, float c, float d, float a, float p)
{
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

// ! OutElastic
float roxy_ease_out_elastic(float t, float b, float c, float d, float a, float p)
{
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

// ! InOutElastic
float roxy_ease_in_out_elastic(float t, float b, float c, float d, float a, float p)
{
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

// ! OutInElastic
float roxy_ease_out_in_elastic(float t, float b, float c, float d, float a, float p)
{
    if (t < d / 2) {
        return roxy_ease_out_elastic(t * 2, b, c / 2, d, a, p);
    } else {
        return roxy_ease_in_elastic((t * 2) - d, b + c / 2, c / 2, d, a, p);
    }
}

// ! InBack
float roxy_ease_in_back(float t, float b, float c, float d, float s)
{
    if (!s) s = 1.70158f;
    t = t / d;
    return c * t * t * ((s + 1) * t - s) + b;
}

// ! OutBack
float roxy_ease_out_back(float t, float b, float c, float d, float s)
{
    if (!s) s = 1.70158f;
    t = t / d - 1;
    return c * (t * t * ((s + 1) * t + s) + 1) + b;
}

// ! InOutBack
float roxy_ease_in_out_back(float t, float b, float c, float d, float s)
{
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

// ! OutInBack
float roxy_ease_out_in_back(float t, float b, float c, float d, float s)
{
    if (t < d / 2) {
        return roxy_ease_out_back(t * 2, b, c / 2, d, s);
    } else {
        return roxy_ease_in_back((t * 2) - d, b + c / 2, c / 2, d, s);
    }
}

// ! OutBounce
float roxy_ease_out_bounce(float t, float b, float c, float d)
{
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

// ! InBounce
float roxy_ease_in_bounce(float t, float b, float c, float d)
{
    return c - roxy_ease_out_bounce(d - t, 0, c, d) + b;
}

// ! InOutBounce
float roxy_ease_in_out_bounce(float t, float b, float c, float d)
{
    if (t < d / 2) {
        return roxy_ease_in_bounce(t * 2, 0, c, d) * 0.5f + b;
    } else {
        return roxy_ease_out_bounce(t * 2 - d, 0, c, d) * 0.5f + c * 0.5f + b;
    }
}

// ! OutInBounce
float roxy_ease_out_in_bounce(float t, float b, float c, float d)
{
    if (t < d / 2) {
        return roxy_ease_out_bounce(t * 2, b, c / 2, d);
    } else {
        return roxy_ease_in_bounce((t * 2) - d, b + c / 2, c / 2, d);
    }
}

// ----------------------------------------
// ! Lua-Exposed Functions
// ----------------------------------------

// Lua wrapper for roxy_ease_flat
int roxy_ease_flat_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_flat(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_linear
int roxy_ease_linear_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_linear(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_quad
int roxy_ease_in_quad_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_quad(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_quad
int roxy_ease_out_quad_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_quad(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_out_quad
int roxy_ease_in_out_quad_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_out_quad(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_in_quad
int roxy_ease_out_in_quad_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_in_quad(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_cubic
int roxy_ease_in_cubic_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_cubic(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_cubic
int roxy_ease_out_cubic_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_cubic(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_out_cubic
int roxy_ease_in_out_cubic_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_out_cubic(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_in_cubic
int roxy_ease_out_in_cubic_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_in_cubic(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_quart
int roxy_ease_in_quart_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_quart(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_quart
int roxy_ease_out_quart_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_quart(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_out_quart
int roxy_ease_in_out_quart_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_out_quart(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_in_quart
int roxy_ease_out_in_quart_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_in_quart(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_quint
int roxy_ease_in_quint_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_quint(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_quint
int roxy_ease_out_quint_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_quint(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_out_quint
int roxy_ease_in_out_quint_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_out_quint(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_in_quint
int roxy_ease_out_in_quint_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_in_quint(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_sine
int roxy_ease_in_sine_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_sine(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_sine
int roxy_ease_out_sine_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_sine(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_out_sine
int roxy_ease_in_out_sine_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_out_sine(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_in_sine
int roxy_ease_out_in_sine_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_in_sine(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_expo
int roxy_ease_in_expo_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_expo(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_expo
int roxy_ease_out_expo_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_expo(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_out_expo
int roxy_ease_in_out_expo_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_out_expo(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_in_expo
int roxy_ease_out_in_expo_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_in_expo(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_circ
int roxy_ease_in_circ_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_circ(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_circ
int roxy_ease_out_circ_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_circ(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_out_circ
int roxy_ease_in_out_circ_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_out_circ(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_in_circ
int roxy_ease_out_in_circ_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_in_circ(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_elastic
int roxy_ease_in_elastic_l(lua_State* L)
{
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

// Lua wrapper for roxy_ease_out_elastic
int roxy_ease_out_elastic_l(lua_State* L)
{
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

// Lua wrapper for roxy_ease_in_out_elastic
int roxy_ease_in_out_elastic_l(lua_State* L)
{
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

// Lua wrapper for roxy_ease_out_in_elastic
int roxy_ease_out_in_elastic_l(lua_State* L)
{
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

// Lua wrapper for roxy_ease_in_back
int roxy_ease_in_back_l(lua_State* L)
{
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

// Lua wrapper for roxy_ease_out_back
int roxy_ease_out_back_l(lua_State* L)
{
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

// Lua wrapper for roxy_ease_in_out_back
int roxy_ease_in_out_back_l(lua_State* L)
{
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

// Lua wrapper for roxy_ease_out_in_back
int roxy_ease_out_in_back_l(lua_State* L)
{
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

// Lua wrapper for roxy_ease_out_bounce
int roxy_ease_out_bounce_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_bounce(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_bounce
int roxy_ease_in_bounce_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_bounce(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_in_out_bounce
int roxy_ease_in_out_bounce_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_in_out_bounce(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}

// Lua wrapper for roxy_ease_out_in_bounce
int roxy_ease_out_in_bounce_l(lua_State* L)
{
    (void)L;

    float t = pd->lua->getArgFloat(1);
    float b = pd->lua->getArgFloat(2);
    float c = pd->lua->getArgFloat(3);
    float d = pd->lua->getArgFloat(4);
    float result = roxy_ease_out_in_bounce(t, b, c, d);

    pd->lua->pushFloat(result);
    return 1;
}
