// source/libraries/roxy/roxy.c

// ! Includes

#include "pd_api.h"

// ! Pointers

static PlaydateAPI* pd = NULL;
static uint32_t previousTime = 0;   // Last recorded time in milliseconds

// ! Constants

// Delta time constraints for stability
#define MIN_DELTA_TIME 0.001f
#define MAX_DELTA_TIME 0.1f
#define MS_TO_SECONDS_DIVISOR 1000.0f

// ! Forward Declarations

static int getDeltaTime_l(lua_State* L);
static float clampDeltaTime(float deltaTime, float min, float max);

// ----------------------------------------
// ! Public API
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

    // Initialize timing state
    previousTime = pd->system->getCurrentTimeMilliseconds();

    // Register Delta Time
    const char* error = NULL;
    if (!pd->lua->addFunction(getDeltaTime_l, "roxy.getDeltaTime", &error)) {
        pd->system->logToConsole("roxy: Failed to register getDeltaTime function: %s", error);
        return -1;
    }

    return 0;
}

// ----------------------------------------
// ! Lua-Exposed Functions
// ----------------------------------------

//
// Get Delta Time
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
    deltaTime = clampDeltaTime(deltaTime, MIN_DELTA_TIME, MAX_DELTA_TIME);

    // Update previousTime for the next frame
    previousTime = currentTime;

    // Push the deltaTime to Lua
    pd->lua->pushFloat(deltaTime);
    return 1;
}

// ----------------------------------------
// ! Utilities
// ----------------------------------------

// Clamp Delta Time
// Utility function to clamp delta time within reasonable bounds
static float clampDeltaTime(float deltaTime, float min, float max) {
    if (deltaTime < min) {
        return min;
    } else if (deltaTime > max) {
        return max;
    }
    return deltaTime;
}
