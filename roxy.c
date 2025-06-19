// source/libraries/roxy/roxy.c

#include "pd_api.h"
#include "utilities/roxy_math.h"

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
int eventHandler(PlaydateAPI* playdate, PDSystemEvent event, uint32_t arg) {
    (void)arg;

    if (event != kEventInitLua) {
        return 0;
    }

    pd = playdate;

    const char* error = NULL;

    // Initialize timing state
    previousTime = pd->system->getCurrentTimeMilliseconds();

    // ! Register Get Delta Time
    if (!pd->lua->addFunction(getDeltaTime_l, "roxy.getDeltaTime", &error)) {
        pd->system->logToConsole("roxy: Failed to register getDeltaTime function: %s", error);
        return -1;
    }

    roxy_math_setPlaydateAPI(pd);

    // ! Register Math Functions
    const char* mathFunctions[] = {
        "roxy.Math.truncateDecimal",
        "roxy.Math.round",
        "roxy.Math.roundDown",
        "roxy.Math.roundUp",
        "roxy.Math.hypot",
        "roxy.Math.clamp",
        "roxy.Math.lerp",
        "roxy.Math.map"
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
static int getDeltaTime_l(lua_State* L) {
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
