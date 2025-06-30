/*
 *
 * Adapted from Nic Magnier's Sequence library.
 * (https://github.com/NicMagnier/PlaydateSequence)
 *
 */

#include "roxy_sequence.h"
#include "../../utilities/roxy_ease.h"
#include "../../utilities/roxy_math.h"
#include <math.h>

static PlaydateAPI* pd                = NULL;
static const struct playdate_lua* lua = NULL;
static const struct playdate_sys* sys = NULL;

#define INITIAL_CAPACITY 8

static const float DEFAULT_DURATION    = 0.04f;
static const int DEFAULT_EASE_FUNCTION = 1; // Linear
static const int DEFAULT_REPEAT_COUNT  = 1;

// ! Easing Segment Struct
typedef struct
{
    float timestamp;
    float from;
    float to;
    float duration;
    float endTime;
    int easeFunction;
} EasingSegment;

// ! Easing Array Struct
typedef struct
{
    const char* name;
    int count;
    int capacity;
    EasingSegment* segments;
    float currentTime;
    int completed;          // 1 = finished, 0 = running
    float totalDuration;
    int loopType;
    float loopCount;
    float loopCounter;
    int pingPongHalfCycles; // Tracks half-cycles (forward or backward flip)
    int isForward;          // 1 = moving forward, 0 = moving backward
} EasingArray;

typedef void (*LoopHandler)(EasingArray*, float*, float);

// ----------------------------------------
// Helpers
// ----------------------------------------

// ! Add Segment Helper Macro
//  Allocate and initialize a new EasingSegment in the array.
#define ADD_SEGMENT(ea, ts, fr, t, dur, ef) \
do { \
    EasingSegment* seg = ensureCapacityAndInsert(ea); \
    if (!seg) { \
        sys->logToConsole("Roxy ERROR: [ADD_SEGMENT] Memory allocation failed resizing EasingArray."); \
        lua->pushObject(ea, "RoxySequenceC", 0); \
        return 1; \
    } \
    seg->timestamp = (ts); \
    seg->from = (fr); \
    seg->to = (t); \
    seg->duration = (dur); \
    seg->endTime = (ts) + (dur); \
    seg->easeFunction = (ef); \
} while (0)

// ! Ensure Capacity and Insert
static EasingSegment* ensureCapacityAndInsert(EasingArray* ea)
{
    if (ea->count == ea->capacity) {
        int newCap = ea->capacity * 2;
        EasingSegment* newPtr = sys->realloc(ea->segments, newCap * sizeof(EasingSegment));
        if (!newPtr) return NULL;
        ea->segments = newPtr;
        ea->capacity = newCap;
    }
    // Return pointer to the next slot, but also increment
    EasingSegment* seg = &ea->segments[ea->count];
    ea->count++;
    return seg;
}

// ! No Loop
static void noLoop(EasingArray* ea, float* newTime, float step)
{
    *newTime += step;
    if (*newTime >= ea->totalDuration) {
        *newTime = ea->totalDuration;
        ea->completed = 1;
    } else if (*newTime < 0.0f) {
        *newTime = 0.0f;
    }
}

// ! Normal Loop
static void normalLoop(EasingArray* ea, float* newTime, float step)
{
    *newTime += step;
    if (*newTime >= ea->totalDuration) {
        ea->loopCounter++;
        if (ea->loopCount > 0 && ea->loopCounter >= ea->loopCount) {
            *newTime = ea->totalDuration;
            ea->completed = 1;
        } else {
            while (*newTime >= ea->totalDuration) *newTime -= ea->totalDuration;
        }
    } else if (*newTime < 0.0f) {
        while (*newTime < 0.0f) *newTime += ea->totalDuration;
    }
}

// ! Ping Pong Loop
static void pingPongLoop(EasingArray* ea, float* newTime, float step)
{
    float dt = step;
    if (ea->isForward) *newTime += dt;
    else *newTime -= dt;
    if (*newTime > ea->totalDuration) {
        float overshoot = *newTime - ea->totalDuration;
        *newTime = ea->totalDuration - overshoot;
        ea->isForward = 0;
        ea->pingPongHalfCycles++;
    } else if (*newTime < 0.0f) {
        float overshoot = -*newTime;
        *newTime = overshoot;
        ea->isForward = 1;
        ea->pingPongHalfCycles++;
    }
    if (ea->loopCount > 0) {
        int totalHalfCycles = (int)(ea->loopCount * 2 + 0.5f); // Round up for safety
        if (ea->pingPongHalfCycles >= totalHalfCycles) {
            *newTime = (totalHalfCycles & 1) ? ea->totalDuration : 0.0f; // Bitwise odd/even
            ea->completed = 1;
        }
    }
}

// ! Loop Handler
static const LoopHandler handlers[] = { noLoop, normalLoop, pingPongLoop };

// ----------------------------------------
//  Object Lifecycle
// ----------------------------------------

// ! New Easing Array
static int easingArray_newobject(lua_State* L)
{
    EasingArray* ea = sys->realloc(NULL, sizeof(EasingArray));
    if (!ea) {
        sys->logToConsole("Roxy ERROR: [easingArray_newobject] Memory allocation failed for EasingArray.");
        return 0;
    }

    ea->count     = 0;
    ea->capacity  = INITIAL_CAPACITY;
    ea->segments  = sys->realloc(NULL, sizeof(EasingSegment) * ea->capacity);

    if (!ea->segments) {
        sys->logToConsole("Roxy ERROR: [easingArray_newobject] Memory allocation failed for EasingArray segments.");
        sys->realloc(ea, 0);
        return 0;
    }

    ea->currentTime         = 0.0f;
    ea->completed           = 0;
    ea->totalDuration       = 0.0f;
    ea->loopType            = 0;
    ea->loopCount           = 0;
    ea->loopCounter         = 0;
    ea->pingPongHalfCycles  = 0;
    ea->isForward           = 1;

    lua->pushObject(ea, "RoxySequenceC", 0);
    return 1;
}

// ! Garbage Collection
static int easingArray_gc(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (ea) {
        if (ea->segments)
            sys->realloc(ea->segments, 0);
        sys->realloc(ea, 0);
    }
    return 0;
}

// ----------------------------------------
// Metamethod
// ----------------------------------------

// ! Easing Array Index
static int easingArray_index(lua_State* L)
{
    // If this is an index into the class's table, return the result
    if (lua->indexMetatable())
        return 1;

    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    int idx = lua->getArgInt(2);
    if (ea && idx > 0 && idx <= ea->count) {
        EasingSegment* seg = &ea->segments[idx - 1];
        lua->pushFloat(seg->timestamp);
        lua->pushFloat(seg->from);
        lua->pushFloat(seg->to);
        lua->pushFloat(seg->duration);
        lua->pushFloat(seg->endTime);
        lua->pushInt(seg->easeFunction);
        return 6;
    }
    return 0;
}

// ! Easing Array New Index
static int easingArray_newindex(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    int idx = lua->getArgInt(2);
    if (!ea || idx <= 0 || idx > ea->count)
        return 0;

    EasingSegment* seg = &ea->segments[idx - 1];
    seg->timestamp    = lua->getArgFloat(3);
    seg->from         = lua->getArgFloat(4);
    seg->to           = lua->getArgFloat(5);
    seg->duration     = lua->getArgFloat(6);
    seg->endTime      = seg->timestamp + seg->duration;
    seg->easeFunction = lua->getArgInt(7);
    return 0;
}

// ! Easing Array Length
static int easingArray_len(lua_State* L)
{
    // Local caches
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (ea) {
        lua->pushInt(ea->count);
        return 1;
    }
    return 0;
}

// ----------------------------------------
// Lua-Exposed Methods
// ----------------------------------------

// ! Set name
static int easingArray_setName(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) {
        lua->pushNil();
        return 1;
    }

    ea->name = lua->getArgString(2);

    lua->pushBool(1);
    return 1;
}

// ! Add easing
static int easingArray_addEasing(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) {
        lua->pushNil();
        return 1;
    }

    float timestamp   = lua->getArgFloat(2);
    float from        = lua->getArgFloat(3);
    float to          = lua->getArgFloat(4);
    float duration    = lua->getArgFloat(5);
    int easeFunction  = lua->getArgInt(6);
    int lastIdx       = ea->count;

    ADD_SEGMENT(ea, timestamp, from, to, duration, easeFunction);
    if (ea->segments[lastIdx].endTime > ea->totalDuration) {
        ea->completed = 0;
        ea->totalDuration = ea->segments[lastIdx].endTime;
    }

    lua->pushBool(1);
    return 1;
}

// ! From
// Clear everything and add a "from" segment at time=0
static int easingArray_from(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) {
        lua->pushNil();
        return 1;
    }

    // Clear everything
    ea->count         = 0;
    ea->currentTime   = 0;
    ea->completed     = 0;
    ea->totalDuration = 0;

    float fromVal = lua->getArgFloat(2); // default is 0.0
    ADD_SEGMENT(ea, 0.0f, fromVal, fromVal, 0.0f, 0);

    lua->pushObject(ea, "RoxySequenceC", 0);
    return 1;
}

// ! To
// Append a new segment starting at the end of the last segment
static int easingArray_to(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) {
        lua->pushNil();
        return 1;
    }

    float newTo       = lua->getArgFloat(2);
    float duration    = lua->getArgFloat(3) ?: DEFAULT_DURATION;
    int easeFunction  = lua->getArgInt(4) ?: DEFAULT_EASE_FUNCTION;
    int lastIdx       = ea->count - 1;
    EasingSegment* lastSeg = &ea->segments[lastIdx];

    lastIdx = ea->count; // Point to new slot
    ADD_SEGMENT(ea, lastSeg->endTime, lastSeg->to, newTo, duration, easeFunction);
    ea->completed = 0;
    ea->totalDuration = ea->segments[lastIdx].endTime;

    lua->pushObject(ea, "RoxySequenceC", 0);
    return 1;
}

// ! Set
static int easingArray_set(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) {
        lua->pushNil();
        return 1;
    }

    float value = lua->getArgFloat(2);
    float newTimestamp = 0.0f;
    if (ea->count > 0) {
        EasingSegment* lastSeg = &ea->segments[ea->count - 1];
        newTimestamp = lastSeg->endTime;
    }

    int lastIdx = ea->count;
    ADD_SEGMENT(ea, newTimestamp, value, value, 0, 0);
    ea->completed = 0;
    ea->totalDuration = ea->segments[lastIdx].endTime;

    lua->pushObject(ea, "RoxySequenceC", 0);
    return 1;
}

// ! Sleep
static int easingArray_sleep(lua_State* L) {
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) {
        lua->pushNil();
        return 1;
    }

    float duration          = lua->getArgFloat(2);
    int lastIdx             = ea->count - 1;
    EasingSegment* lastSeg  = &ea->segments[lastIdx];

    lastIdx = ea->count;
    ADD_SEGMENT(ea, lastSeg->endTime, lastSeg->to, lastSeg->to, duration, 0);
    ea->completed = 0;
    ea->totalDuration = ea->segments[lastIdx].endTime;

    lua->pushObject(ea, "RoxySequenceC", 0);
    return 1;
}

// ! Set loop
static int easingArray_setLoopType(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) {
        lua->pushNil();
        return 1;
    }

    int loopType = lua->getArgInt(2);  // 0,1,2
    float loopCount = lua->getArgFloat(3); // 0=infinite

    ea->loopType    = loopType;
    ea->loopCount   = loopCount;
    ea->loopCounter = 0;
    ea->isForward   = 1;  // always start forward

    lua->pushBool(1);
    return 1;
}

// ! Again
static int easingArray_again(lua_State* L) {
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) {
        lua->pushNil();
        return 1;
    }

    int repeatCount = lua->getArgInt(2);
    if (repeatCount <= 0) repeatCount = DEFAULT_REPEAT_COUNT;

    int needed = ea->count + repeatCount;
    if (needed > ea->capacity) {
        int newCap = ea->capacity * 2;
        while (newCap < needed) newCap *= 2;
        EasingSegment* newPtr = sys->realloc(ea->segments, newCap * sizeof(EasingSegment));
        if (!newPtr) {
            lua->pushObject(ea, "RoxySequenceC", 0);
            return 1;
        }
        ea->segments = newPtr;
        ea->capacity = newCap;
    }

    int lastIdx = ea->count - 1;
    EasingSegment* lastSeg = &ea->segments[lastIdx];
    float newTimestamp  = lastSeg->endTime;
    float newFrom       = lastSeg->from;
    float newTo         = lastSeg->to;
    float newDuration   = lastSeg->duration;
    int newEaseFunction = lastSeg->easeFunction;

    for (int r = 0; r < repeatCount; r++) {
        lastIdx = ea->count;
        ADD_SEGMENT(ea, newTimestamp, newFrom, newTo, newDuration, newEaseFunction);
        newTimestamp = ea->segments[lastIdx].endTime;
    }
    ea->completed = 0;
    ea->totalDuration = ea->segments[ea->count - 1].endTime;

    lua->pushObject(ea, "RoxySequenceC", 0);
    return 1;
}

// ! Reverse (Modify or Append Reversed Segment)
static int easingArray_reverse(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) {
        lua->pushNil();
        return 1;
    }

    int appendNew           = lua->getArgBool(2);
    int lastIdx             = ea->count - 1;
    EasingSegment* lastSeg  = &ea->segments[lastIdx];

    if (!appendNew) {
        float elapsed = ea->currentTime - lastSeg->timestamp;
        float temp    = lastSeg->from;
        lastSeg->from = lastSeg->to;
        lastSeg->to   = temp;

        // Mirror time inside the segment
        ea->currentTime = lastSeg->timestamp + (lastSeg->duration - elapsed);
        lua->pushObject(ea, "RoxySequenceC", 0);
        return 1;
    }

    lastIdx = ea->count;
    ADD_SEGMENT(ea, lastSeg->endTime, lastSeg->to, lastSeg->from, lastSeg->duration, lastSeg->easeFunction);
    ea->completed = 0;
    ea->totalDuration = ea->segments[lastIdx].endTime;

    lua->pushObject(ea, "RoxySequenceC", 0);
    return 1;
}

// ----------------------------------------
// Lua-Exposed Methods: Query and Control
// ----------------------------------------

// ! Get easing data
static int easingArray_getEasingData(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    int idx = lua->getArgInt(2);
    if (ea && idx > 0 && idx <= ea->count) {
        EasingSegment* seg = &ea->segments[idx - 1];
        lua->pushFloat(seg->timestamp);
        lua->pushFloat(seg->from);
        lua->pushFloat(seg->to);
        lua->pushFloat(seg->duration);
        lua->pushFloat(seg->endTime);
        lua->pushInt(seg->easeFunction);
        return 6;
    }
    return 0;
}

// ! Get current time
static int easingArray_getCurrentTime(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) {
        lua->pushNil();
        return 1;
    }
    lua->pushFloat(ea->currentTime);
    return 1;
}

// ! Get total duration
static int easingArray_getTotalDuration(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) {
        lua->pushNil();
        return 1;
    }
    lua->pushFloat(ea->totalDuration);
    return 1;
}

// ! Update and Get Value
static int easingArray_updateAndGetValue(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) {
        lua->pushFloat(0.0f); // oldTime
        lua->pushFloat(0.0f); // newTime
        lua->pushFloat(0.0f); // newValue
        lua->pushBool(1);     // completed
        return 4;
    }
    int lastIdx = ea->count - 1;
    float oldTime = ea->currentTime;
    if (ea->completed) {
        lua->pushFloat(oldTime);                  // oldTime
        lua->pushFloat(oldTime);                  // newTime
        lua->pushFloat(ea->segments[lastIdx].to); // newValue
        lua->pushBool(1);                         // completed
        return 4;
    }

    float step    = lua->getArgFloat(2);
    float newTime = ea->currentTime;

    // (1) Adjust newTime based on loopType
    if (ea->loopType >= 0 && ea->loopType <= 2) {
        handlers[ea->loopType](ea, &newTime, step);
    }

    // (2) Update our time
    ea->currentTime = newTime;

    // (3) Find the segment for this time
    EasingSegment* easing = NULL;
    if (ea->count <= 4) { // Threshold tuned for Playdate
        for (int i = 0; i < ea->count; i++) {
            EasingSegment* seg = &ea->segments[i];
            if (ea->currentTime >= seg->timestamp && ea->currentTime <= seg->endTime) {
                easing = seg;
                break;
            }
        }
    } else {
        int left = 0, right = lastIdx;
        while (left <= right) {
            int mid = left + (right - left) / 2;
            EasingSegment* seg = &ea->segments[mid];
            if (ea->currentTime >= seg->timestamp && ea->currentTime <= seg->endTime) {
                easing = seg;
                break;
            }
            if (ea->currentTime < seg->timestamp) right = mid - 1;
            else left = mid + 1;
        }
    }
    if (!easing) {
        easing = (ea->currentTime < ea->segments[0].timestamp) ? &ea->segments[0] : &ea->segments[lastIdx];
    }

    // (4) Calculate the “elapsedTime” within that segment
    float elapsedTime = ea->currentTime - easing->timestamp;
    if (ea->loopType == 2 && !ea->isForward) {
        elapsedTime = easing->duration - elapsedTime;
    }

    // (5) Evaluate the easing
    float newValue = (easing->easeFunction == 1) ? (ea->isForward ? easing->from + (easing->to - easing->from) * (elapsedTime / easing->duration) : easing->to + (easing->from - easing->to) * (elapsedTime / easing->duration)) : roxy_ease_evaluate(easing->easeFunction, elapsedTime, ea->isForward ? easing->from : easing->to, ea->isForward ? (easing->to - easing->from) : (easing->from - easing->to), easing->duration, 0.0f, 0.0f);

    lua->pushFloat(oldTime);          // Old time
    lua->pushFloat(ea->currentTime);  // New time
    lua->pushFloat(newValue);         // New Value
    lua->pushBool(ea->completed);     // Completed
    return 4;
}

// ! Get value
static int easingArray_getValue(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) {
        lua->pushFloat(0.0f);
        return 1;
    }

    float time = lua->getArgFloat(2);
    float clampedTime = roxy_math_clamp(time, 0.0f, ea->totalDuration);
    int lastIdx = ea->count - 1;

    if (clampedTime >= ea->segments[lastIdx].endTime) {
        lua->pushFloat(ea->segments[lastIdx].to);
        return 1;
    }

    EasingSegment* easing = NULL;
    if (ea->count <= 4) { // Threshold tuned for Playdate
        for (int i = 0; i < ea->count; i++) {
            EasingSegment* seg = &ea->segments[i];
            if (clampedTime >= seg->timestamp && clampedTime <= seg->endTime) {
                easing = seg;
                break;
            }
        }
    } else {
        int left = 0, right = lastIdx;
        while (left <= right) {
            int mid = left + (right - left) / 2;
            EasingSegment* seg = &ea->segments[mid];
            if (clampedTime >= seg->timestamp && clampedTime <= seg->endTime) {
                easing = seg;
                break;
            }
            if (clampedTime < seg->timestamp) right = mid - 1;
            else left = mid + 1;
        }
    }
    if (!easing) {
        easing = (clampedTime < ea->segments[0].timestamp) ? &ea->segments[0] : &ea->segments[lastIdx];
    }

    float timeOffset = clampedTime - easing->timestamp;
    float value = roxy_ease_evaluate(
        easing->easeFunction,
        timeOffset,
        easing->from,
        (easing->to - easing->from),
        easing->duration,
        0.0f,
        0.0f
    );

    lua->pushFloat(value);
    return 1;
}

// ! Is done
static int easingArray_isDone(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) return 0;

    lua->pushBool(ea->completed);
    return 1;
}

// ! Reset
static int easingArray_reset(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) return 0;

    ea->currentTime         = 0.0f;
    ea->completed           = 0;
    ea->loopCounter         = 0;
    ea->pingPongHalfCycles  = 0;
    ea->isForward           = 1;  // Start moving forward

    lua->pushBool(1);
    return 1;
}


// ! Clear Easing Array
static int easingArray_clear(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) return 0;

    ea->count               = 0;
    ea->currentTime         = 0.0f;
    ea->completed           = 0;
    ea->totalDuration       = 0.0f;
    ea->loopType            = 0;
    ea->loopCount           = 0;
    ea->loopCounter         = 0;
    ea->pingPongHalfCycles  = 0;
    ea->isForward           = 1;  // Default to forward

    lua->pushBool(1);
    return 1;
}


// ----------------------------------------
// ! Class Registration
// ----------------------------------------

static const lua_reg easingArrayLib[] =
{
    { "new",                easingArray_newobject         },
    { "__gc",               easingArray_gc                },
    { "__index",            easingArray_index             },
    { "__newindex",         easingArray_newindex          },
    { "__len",              easingArray_len               },
    { "setName",            easingArray_setName           },
    { "addEasing",          easingArray_addEasing         },
    { "from",               easingArray_from              },
    { "to",                 easingArray_to                },
    { "set",                easingArray_set               },
    { "sleep",              easingArray_sleep             },
    { "setLoopType",        easingArray_setLoopType       },
    { "again",              easingArray_again             },
    { "reverse",            easingArray_reverse           },
    { "getEasingData",      easingArray_getEasingData     },
    { "getCurrentTime",     easingArray_getCurrentTime    },
    { "getTotalDuration",   easingArray_getTotalDuration  },
    { "updateAndGetValue",  easingArray_updateAndGetValue },
    { "getValue",           easingArray_getValue          },
    { "isDone",             easingArray_isDone            },
    { "reset",              easingArray_reset             },
    { "clear",              easingArray_clear             },
    { NULL, NULL }
};

void registerRoxySequenceC(PlaydateAPI* playdate)
{
    pd = playdate;
    lua = playdate->lua;
    sys = playdate->system;

    const char* err;
    if (!lua->registerClass("RoxySequenceC", easingArrayLib, NULL, 0, &err)) {
        sys->logToConsole("%s:%i: registerClass failed, %s", __FILE__, __LINE__, err);
    }
}
