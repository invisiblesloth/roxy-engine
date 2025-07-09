// source/libraries/roxy/roxy.c

#include "pd_api.h"
#include "utilities/roxy_math.h"
#include "utilities/roxy_ease.h"
#include "core/modules/roxy_input.h"
#include "core/transitions/roxy_transition.h"
#include "core/sequences/roxy_sequence.h"
#include "core/animations/roxy_animation.h"
#include "core/sprites/roxy_particles.h"

static PlaydateAPI* pd = NULL;
static uint32_t previousTime = 0;

#define MIN_DELTA_TIME 0.001f
#define MAX_DELTA_TIME 0.1f
#define MS_TO_SECONDS_DIVISOR 1000.0f

static int getDeltaTime_l(lua_State* L);
static float clampDeltaTime(float deltaTime, float min, float max);

// ----------------------------------------
// Public API
// ----------------------------------------

#ifdef _WINDLL
__declspec(dllexport)
#endif
int eventHandler(PlaydateAPI* playdate, PDSystemEvent event, uint32_t arg)
{
    (void)arg;

    if (event != kEventInitLua) {
        return 0;
    }

    pd = playdate;

    const char* error = NULL;

    srand(pd->system->getSecondsSinceEpoch(NULL));

    // Initialize timing state
    previousTime = pd->system->getCurrentTimeMilliseconds();

    // ! Register Get Delta Time
    if (!pd->lua->addFunction(getDeltaTime_l, "roxy.getDeltaTime", &error)) {
        pd->system->logToConsole("roxy: Failed to register getDeltaTime function: %s", error);
        return -1;
    }

    // ! Register Math Functions
    roxy_math_setPlaydateAPI(pd);
    const char* mathFunctions[] = {
        "roxy.Math.truncateDecimal",
        "roxy.Math.round",
        "roxy.Math.roundInt",
        "roxy.Math.roundDown",
        "roxy.Math.roundUp",
        "roxy.Math.hypot",
        "roxy.Math.clamp",
        "roxy.Math.clampi",
        "roxy.Math.lerp",
        "roxy.Math.map"
    };
    int (*mathFuncs[])(lua_State*) = {
        roxy_math_truncateDecimal_l,
        roxy_math_round_l,
        roxy_math_roundInt_l,
        roxy_math_roundDown_l,
        roxy_math_roundUp_l,
        roxy_math_hypot_l,
        roxy_math_clamp_l,
        roxy_math_clampi_l,
        roxy_math_lerp_l,
        roxy_math_map_l
    };
    for (int i = 0; i < sizeof(mathFunctions) / sizeof(mathFunctions[0]); ++i) {
        if (!pd->lua->addFunction(mathFuncs[i], mathFunctions[i], &error)) {
            pd->system->logToConsole("%s:%i: addFunction failed, %s", __FILE__, __LINE__, error);
            return -1;
        }
    }

    // ! Register Easing Functions
    roxy_easingFunctions_setPlaydateAPI(pd);
    const char* easingFunctions[] = {
        "roxy.EasingFunctions.flat",
        "roxy.EasingFunctions.linear",
        "roxy.EasingFunctions.inQuad",
        "roxy.EasingFunctions.outQuad",
        "roxy.EasingFunctions.inOutQuad",
        "roxy.EasingFunctions.outInQuad",
        "roxy.EasingFunctions.inCubic",
        "roxy.EasingFunctions.outCubic",
        "roxy.EasingFunctions.inOutCubic",
        "roxy.EasingFunctions.outInCubic",
        "roxy.EasingFunctions.inQuart",
        "roxy.EasingFunctions.outQuart",
        "roxy.EasingFunctions.inOutQuart",
        "roxy.EasingFunctions.outInQuart",
        "roxy.EasingFunctions.inQuint",
        "roxy.EasingFunctions.outQuint",
        "roxy.EasingFunctions.inOutQuint",
        "roxy.EasingFunctions.outInQuint",
        "roxy.EasingFunctions.inSine",
        "roxy.EasingFunctions.outSine",
        "roxy.EasingFunctions.inOutSine",
        "roxy.EasingFunctions.outInSine",
        "roxy.EasingFunctions.inExpo",
        "roxy.EasingFunctions.outExpo",
        "roxy.EasingFunctions.inOutExpo",
        "roxy.EasingFunctions.outInExpo",
        "roxy.EasingFunctions.inCirc",
        "roxy.EasingFunctions.outCirc",
        "roxy.EasingFunctions.inOutCirc",
        "roxy.EasingFunctions.outInCirc",
        "roxy.EasingFunctions.inElastic",
        "roxy.EasingFunctions.outElastic",
        "roxy.EasingFunctions.inOutElastic",
        "roxy.EasingFunctions.outInElastic",
        "roxy.EasingFunctions.inBack",
        "roxy.EasingFunctions.outBack",
        "roxy.EasingFunctions.inOutBack",
        "roxy.EasingFunctions.outInBack",
        "roxy.EasingFunctions.outBounce",
        "roxy.EasingFunctions.inBounce",
        "roxy.EasingFunctions.inOutBounce",
        "roxy.EasingFunctions.outInBounce"
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

    // ! Register Input Functions
    roxy_input_setPlaydateAPI(pd);
    const char* inputFunctions[] = {
        "roxy.Input.setButtonHoldBufferAmount",
        "roxy.Input.processAllButtons"
    };
    int (*inputFuncs[])(lua_State*) = {
        roxy_input_setButtonHoldBufferAmount_l,
        roxy_input_processAllButtons_l
    };
    for (int i = 0; i < sizeof(inputFunctions) / sizeof(inputFunctions[0]); ++i) {
        if (!pd->lua->addFunction(inputFuncs[i], inputFunctions[i], &error)) {
            pd->system->logToConsole("%s:%i: addFunction failed, %s", __FILE__, __LINE__, error);
            return -1;
        }
    }

    // ! Register Transition Functions
    roxy_transition_setPlaydateAPI(pd);
    const char* transitionFunctions[] = {
        "roxy.Transition.crossDissolveDrawFrame"
    };
    int (*transitionFuncs[])(lua_State*) = {
        roxy_transition_crossDissolveDrawFrame_l
    };
    for (int i = 0; i < sizeof(transitionFunctions) / sizeof(transitionFunctions[0]); ++i) {
        if (!pd->lua->addFunction(transitionFuncs[i], transitionFunctions[i], &error)) {
            pd->system->logToConsole("%s:%i: addFunction failed, %s", __FILE__, __LINE__, error);
            return -1;
        }
    }

    // ! Register Animation Functions
    roxy_animation_setPlaydateAPI(pd);
    const char* animationFunctions[] = {
        "roxy.Animation.update"
    };
    int (*animationFuncs[])(lua_State*) = {
        roxy_animation_update_l
    };
    for (int i = 0; i < sizeof(animationFunctions) / sizeof(animationFunctions[0]); ++i) {
        if (!pd->lua->addFunction(animationFuncs[i], animationFunctions[i], &error)) {
            pd->system->logToConsole("%s:%i: addFunction failed, %s", __FILE__, __LINE__, error);
            return -1;
        }
    }

    // ! Register RoxySequenceC Class
    registerRoxySequenceC(pd);

    // ! Register RoxyParticlesC Class
    registerRoxyParticlesC(pd);

    return 0;
}

// ----------------------------------------
// Lua-Exposed Functions
// ----------------------------------------

//
// ! Get Delta Time
//
// Lua Function: roxy.getDeltaTime()
// Returns: number - Time elapsed since last call in seconds
//
// Usage in Lua:
//   local dt = roxy.getDeltaTime()
//   player.x = player.x + (player.speed * dt)
//
static int getDeltaTime_l(lua_State* L)
{
    if (pd == NULL) {
        return 0;
    }

    uint32_t currentTime = pd->system->getCurrentTimeMilliseconds();
    float deltaTime = 0.0f;

    // Compute deltaTime in seconds
    deltaTime = (currentTime - previousTime) / MS_TO_SECONDS_DIVISOR;

    // Clamp deltaTime to avoid issues during large frame gaps
    deltaTime = roxy_math_clamp(deltaTime, MIN_DELTA_TIME, MAX_DELTA_TIME);

    // Update previousTime for the next frame
    previousTime = currentTime;

    // Push the deltaTime to Lua
    pd->lua->pushFloat(deltaTime);
    return 1;
}
