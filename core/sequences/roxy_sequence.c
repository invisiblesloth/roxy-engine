// core/sequences/roxy_sequence.c

/**
 *
 * Adapted from Nic Magnier's Sequence library.
 * (https://github.com/NicMagnier/PlaydateSequence)
 *
 */

#include "roxy_sequence.h"
#include "../../utilities/roxy_ease.h"
#include "../../utilities/roxy_math.h"
#include "../../utilities/roxy_heapguard.h"
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include <math.h>

static PlaydateAPI* pd = NULL;
static const struct playdate_lua* lua = NULL;
static const struct playdate_sys* sys = NULL;

static float boundaryTimeForCompletion(const EasingArray* ea);

#define INITIAL_CAPACITY 8

static const float DEFAULT_DURATION    = 0.04f;
static const int DEFAULT_EASE_FUNCTION = 1; // Linear
static const int DEFAULT_REPEAT_COUNT  = 1;

/*******************************************//**
 *  Helpers
 ***********************************************/

static float durationOrDefault(float duration)
{
    return (!isfinite(duration) || duration <= 0.0f) ? DEFAULT_DURATION : duration;
}

static float durationOrZero(float duration)
{
    return (!isfinite(duration) || duration < 0.0f) ? 0.0f : duration;
}

static void resetPlaybackState(EasingArray* ea)
{
    ea->currentTime = 0.0f;
    ea->completed   = 0;
    ea->travelAccum = 0.0f;
    ea->isForward   = 1;
}

static void resetLoopConfiguration(EasingArray* ea)
{
    ea->loopType  = 0;
    ea->loopCount = 0.0f;
    resetPlaybackState(ea);
}

static void recomputeTimelineMetadata(EasingArray* ea)
{
    ea->isSorted = 1;
    float maxEnd = 0.0f;
    for (int i = 0; i < ea->count; ++i) {
        if (i > 0 && ea->segments[i].timestamp < ea->segments[i - 1].timestamp) ea->isSorted = 0;
        if (ea->segments[i].endTime > maxEnd) maxEnd = ea->segments[i].endTime;
    }
    ea->totalDuration = maxEnd;
}

static int ensureCapacity(EasingArray* ea, size_t needed)
{
    if (!ea || !ea->segments) return 0;
    if (needed > (SIZE_MAX / sizeof(EasingSegment)) || needed > (size_t)INT_MAX) return 0;

    int newCap = ea->capacity;
    if (newCap <= 0) return 0;
    if (needed <= (size_t)newCap) return 1;

    while ((size_t)newCap < needed) {
        if (newCap > INT_MAX / 2) return 0;
        newCap *= 2;
    }

    EasingSegment* newPtr = (EasingSegment*)roxy_realloc(
        ea->segments, (size_t)newCap * sizeof(EasingSegment));
    if (!newPtr) return 0;

    ea->segments = newPtr;
    ea->capacity = newCap;
    ROXY_LABEL(ea->segments, "RoxySequenceC.segments");
    return 1;
}

// ! Ensure Capacity and Insert
static EasingSegment* ensureCapacityAndInsert(EasingArray* ea)
{
    if (!ea || ea->count < 0 || ea->count >= INT_MAX) return NULL;
    if (!ensureCapacity(ea, (size_t)ea->count + 1)) return NULL;

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
    ea->completed = 0;
    if (ea->totalDuration <= 0.0f) { *newTime = 0.0f; ea->completed = 1; return; }

    // Clip the positive step so we exactly consume the remaining budget.
    float applied = step;
    if (step > 0.0f && ea->loopCount > 0.0f) {
        float maxDist = ea->loopCount * ea->totalDuration;
        float remain  = maxDist - ea->travelAccum;
        if (remain <= 0.0f) { *newTime = boundaryTimeForCompletion(ea); ea->completed = 1; return; }
        if (applied > remain) applied = remain;
    }

    // Apply wrapped motion
    float t = *newTime + applied;
    if (t >= ea->totalDuration) {
        t = fmodf(t, ea->totalDuration);
    } else if (t < 0.0f) {
        float q = fmodf(-t, ea->totalDuration);
        t = (q == 0.0f) ? 0.0f : (ea->totalDuration - q);
    }
    *newTime = t;

    if (step > 0.0f) ea->travelAccum += applied;
    if (ea->loopCount > 0.0f && ea->travelAccum >= ea->loopCount * ea->totalDuration - 1e-6f) {
        *newTime = boundaryTimeForCompletion(ea);
        ea->completed = 1;
    }
}

// ! Ping Pong Loop
static void pingPongLoop(EasingArray* ea, float* newTime, float step)
{
    if (ea->totalDuration <= 0.0f) { *newTime = 0.0f; ea->completed = 1; return; }

    float D = ea->totalDuration;
    float period = 2.0f * D;

    // Clip the positive step so we exactly consume the remaining ping-pong budget.
    float applied = step;
    if (step > 0.0f && ea->loopCount > 0.0f) {
        float maxDist = ea->loopCount * period; // Distance along the ping-pong path
        float remain  = maxDist - ea->travelAccum;
        if (remain <= 0.0f) { *newTime = boundaryTimeForCompletion(ea); ea->completed = 1; return; }
        if (applied > remain) applied = remain;
    }

    // Unfold current state into a linear "phase" s in [0, 2D)
    float s = ea->isForward ? *newTime : (period - *newTime);
    s += applied; // Positive step always advances along the path; negative rewinds

    // Wrap s into [0, 2D)
    s = fmodf(s, period);
    if (s < 0.0f) s += period;

    // Fold back to [0, D] and update direction bit
    if (s <= D) { *newTime = s; ea->isForward = 1; }
    else        { *newTime = period - s; ea->isForward = 0; }

    if (step > 0.0f) ea->travelAccum += applied;
    if (ea->loopCount > 0.0f && ea->travelAccum >= ea->loopCount * period - 1e-6f) {
        *newTime = boundaryTimeForCompletion(ea);
        ea->completed = 1;
    }
}

// ! Loop Handler
static const LoopHandler handlers[] = { noLoop, normalLoop, pingPongLoop };

// ! Duplicate String
// Safe String Duplication Helper
static char* duplicateString(const char* source)
{
    if (!source) return NULL;

    size_t len = strlen(source);
    char* copy = (char*)roxy_malloc(len + 1);
    if (!copy) {
        sys->logToConsole("Roxy ERROR: [duplicateString] Memory allocation failed for string copy.");
        return NULL;
    }

    roxy_memcpy(copy, source, len + 1); // Includes NULL
    ROXY_LABEL(copy, "RoxySequenceC.name");
    return copy;
}

// ! Evaluate At Time
static const EasingSegment* findSegmentForTime(const EasingArray* ea, float t, float* clampedOut)
{
    if (!ea || ea->count == 0) return NULL;

    float clamped = roxy_math_clamp(t, 0.0f, ea->totalDuration);
    if (clampedOut) *clampedOut = clamped;

    int last = ea->count - 1;
    if (ea->isSorted && clamped >= ea->segments[last].endTime) return &ea->segments[last];

    const EasingSegment* easing = NULL;

    if (!ea->isSorted) {
        for (int i = 0; i < ea->count; ++i) {
            const EasingSegment* seg = &ea->segments[i];
            if (clamped >= seg->timestamp && clamped <= seg->endTime) { easing = seg; break; }
        }
    } else if (ea->count <= 4) {
        for (int i = 0; i < ea->count; ++i) {
            const EasingSegment* seg = &ea->segments[i];
            if (clamped >= seg->timestamp && clamped <= seg->endTime) { easing = seg; break; }
        }
    } else {
        int left = 0, right = last;
        while (left <= right) {
            int mid = left + (right - left) / 2;
            const EasingSegment* seg = &ea->segments[mid];
            if (clamped >= seg->timestamp && clamped <= seg->endTime) { easing = seg; break; }
            if (clamped < seg->timestamp) right = mid - 1; else left = mid + 1;
        }
    }

    if (!easing)
        easing = (clamped < ea->segments[0].timestamp) ? &ea->segments[0] : &ea->segments[last];

    return easing;
}

static float evaluateSegmentAtTime(const EasingArray* ea, const EasingSegment* easing, float clamped)
{
    if (!ea || !easing) return 0.0f;
    if (easing->duration <= 0.0f) return easing->to;

    float timeOffset = clamped - easing->timestamp;

    // Direction-aware evaluation for ping-pong:
    if (ea->loopType == 2 && !ea->isForward) {
        float reverseTimeOffset = easing->duration - timeOffset; // Reverse time
        return roxy_ease_evaluate(
            easing->easeFunction,
            reverseTimeOffset,
            easing->to,                   // Swap endpoints
            (easing->from - easing->to),
            easing->duration,
            0.0f, 0.0f
        );
    }

    // Forward (or normal loop/no loop) evaluation
    return roxy_ease_evaluate(
        easing->easeFunction,
        timeOffset,
        easing->from,
        (easing->to - easing->from),
        easing->duration,
        0.0f, 0.0f
    );
}

// Evaluate value at an absolute time (uses same search logic as getValue)
static float evalAtTime(const EasingArray* ea, float t)
{
    float clamped = 0.0f;
    const EasingSegment* easing = findSegmentForTime(ea, t, &clamped);
    return evaluateSegmentAtTime(ea, easing, clamped);
}

// Compute the correct boundary time when the sequence is completed.
// For ping-pong we map fractional half-cycles onto [0, D] <-> [D, 0].
// For normal loops we finish at frac(loopCount) * D. For "no loop" clamp to end.
static float boundaryTimeForCompletion(const EasingArray* ea)
{
    if (ea->loopType == 2 && ea->loopCount > 0.0f) {
        float D = ea->totalDuration;
        float H = ea->loopCount * 2.0f;     // Half-cycles
        float hf = H - floorf(H);           // Fractional half-cycle
        int parity = ((int)floorf(H)) & 1;  // 0=fwd, 1=back
        return (parity == 0) ? (hf * D) : (D - hf * D);
    }
    if (ea->loopType == 1 && ea->loopCount > 0.0f && ea->totalDuration > 0.0f) {
        float D = ea->totalDuration;
        float loops = ea->loopCount;
        float whole;
        float frac = modff(loops, &whole);  // Split into integer + fractional part
        if (frac <= 1e-6f) return D;        // Exact (or near-exact) integer --> end at D
        return frac * D;                    // Fractional loops --> partial progress
    }
    // No-loop or infinite loops: clamp to end
    return ea->totalDuration;
}

/*******************************************//**
 *  Object Lifecycle
 ***********************************************/

// ! New Easing Array
static int easingArray_newobject(lua_State* L)
{
    EasingArray* ea = (EasingArray*)roxy_malloc(sizeof(EasingArray));
    if (!ea) {
        sys->logToConsole("Roxy ERROR: [easingArray_newobject] Allocation failed for EasingArray.");
        return 0;
    }
    ROXY_LABEL(ea, "RoxySequenceC");

    ea->count     = 0;
    ea->capacity  = INITIAL_CAPACITY;

    // Overflow guard
    if ((size_t)ea->capacity > (SIZE_MAX / sizeof(EasingSegment))) {
        roxy_free(ea);
        sys->logToConsole("Roxy ERROR: [easingArray_newobject] Capacity overflow.");
        return 0;
    }

    ea->segments  = (EasingSegment*)roxy_malloc((size_t)ea->capacity * sizeof(EasingSegment));
    if (!ea->segments) {
        sys->logToConsole("Roxy ERROR: [easingArray_newobject] Allocation failed for EasingArray segments.");
        roxy_free(ea);
        return 0;
    }
    ROXY_LABEL(ea->segments, "RoxySequenceC.segments");
    roxy_memset(ea->segments, 0, (size_t)ea->capacity * sizeof(EasingSegment));

    ea->name                = NULL; // Initialize to NULL
    ea->currentTime         = 0.0f;
    ea->completed           = 0;
    ea->totalDuration       = 0.0f;
    ea->loopType            = 0;
    ea->loopCount           = 0.0f;
    ea->travelAccum         = 0.0f;
    ea->isForward           = 1;
    ea->isSorted            = 1;

    lua->pushObject(ea, "RoxySequenceC", 0);
    return 1;
}

// ! Garbage Collection
static int easingArray_gc(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (ea) {
        if (ea->segments) roxy_free(ea->segments);
        if (ea->name)     roxy_free((void*)ea->name);
        roxy_free(ea);
    }
    return 0;
}

/*******************************************//**
 *  Metamethod
 ***********************************************/

// ! Easing Array Index
static int easingArray_index(lua_State* L)
{
    if (lua->indexMetatable()) return 1;

    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    int idx = lua->getArgInt(2);
    if (!ea || idx <= 0 || idx > ea->count) { lua->pushNil(); return 1; }

    EasingSegment* seg = &ea->segments[idx - 1];
    lua->pushFloat(seg->timestamp);
    lua->pushFloat(seg->from);
    lua->pushFloat(seg->to);
    lua->pushFloat(seg->duration);
    lua->pushFloat(seg->endTime);
    lua->pushInt(seg->easeFunction);
    return 6;
}

// ! Easing Array Length
static int easingArray_len(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (ea) {
        lua->pushInt(ea->count);
        return 1;
    }
    return 0;
}

// ! Set Easing At
// obj:setEasingAt(idx, ts, from, to, dur, ease)
static int easingArray_setEasingAt(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    int idx = lua->getArgInt(2);
    if (!ea || idx <= 0 || idx > ea->count) {
        lua->pushNil();
        lua->pushString("invalid index");
        return 2;
    }

    // NOTE: Modifying a segment in the middle can result in overlapping or
    // out-of-order segments. It is the user's responsibility to maintain
    // non-overlapping, ordered segments for consistent results.

    EasingSegment* seg = &ea->segments[idx - 1];
    seg->timestamp    = lua->getArgFloat(3);
    seg->from         = lua->getArgFloat(4);
    seg->to           = lua->getArgFloat(5);
    seg->duration     = durationOrZero(lua->getArgFloat(6));
    seg->endTime      = seg->timestamp + seg->duration;
    seg->easeFunction = lua->getArgInt(7);

    // Re-evaluate sortedness and totalDuration
    recomputeTimelineMetadata(ea);
    resetPlaybackState(ea);

    lua->pushBool(1);
    return 1;
}

/*******************************************//**
 *  Lua-Exposed Methods
 ***********************************************/

// ! Set name
static int easingArray_setName(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) {
        lua->pushNil();
        return 1;
    }

    const char* newName = lua->getArgString(2);

    if (ea->name) {
        roxy_free((void*)ea->name);
        ea->name = NULL;
    }

    // Duplicate the new name
    if (newName) {
        ea->name = duplicateString(newName);
        if (!ea->name) {
            sys->logToConsole("Roxy ERROR: [easingArray_setName] Failed to duplicate name string.");
            lua->pushBool(0);
            return 1;
        }
    }

    lua->pushBool(1);
    return 1;
}

// ! Get Name
static int easingArray_getName(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || !ea->name) {
        lua->pushNil();
        return 1;
    }
    lua->pushString(ea->name);
    return 1;
}

// ! Add easing
static int easingArray_addEasing(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) { lua->pushNil(); return 1; }

    float timestamp   = lua->getArgFloat(2);
    float from        = lua->getArgFloat(3);
    float to          = lua->getArgFloat(4);
    float duration    = lua->getArgFloat(5);
    int easeFunction  = lua->getArgInt(6);

    duration = durationOrZero(duration);

    // NOTE: For best performance, add easings in increasing timestamp order.
    //       Segments should be non-overlapping and in increasing order.
    //       If you add out-of-order or overlapping segments, lookup falls back
    //       to linear scan and results may be unpredictable if two segments
    //       cover the same time.
    //       It is the caller's responsibility to avoid overlaps for
    //       consistent animation.

    EasingSegment* seg = ensureCapacityAndInsert(ea);
    if (!seg) { lua->pushNil(); lua->pushString("oom"); return 2; }

    seg->timestamp    = timestamp;
    seg->from         = from;
    seg->to           = to;
    seg->duration     = duration;
    seg->endTime      = timestamp + duration;
    seg->easeFunction = easeFunction;

    ea->isSorted &= (ea->count <= 1 || ea->segments[ea->count-1].timestamp >= ea->segments[ea->count-2].timestamp);

    if (seg->endTime > ea->totalDuration) ea->totalDuration = seg->endTime;
    resetPlaybackState(ea);

    lua->pushBool(1);
    return 1;
}

// ! From
static int easingArray_from(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) { lua->pushNil(); return 1; }

    ea->count         = 0;
    ea->totalDuration = 0.0f;
    ea->isSorted      = 1;
    resetPlaybackState(ea);

    float fromVal = lua->getArgFloat(2);

    EasingSegment* seg = ensureCapacityAndInsert(ea);
    if (!seg) { lua->pushNil(); lua->pushString("oom"); return 2; }

    seg->timestamp    = 0.0f;
    seg->from         = fromVal;
    seg->to           = fromVal;
    seg->duration     = 0.0f;
    seg->endTime      = 0.0f;
    seg->easeFunction = 0;

    lua->pushBool(1);
    return 1;
}

// ! To
static int easingArray_to(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) { lua->pushNil(); return 1; }

    int argc            = lua->getArgCount();
    float newTo         = lua->getArgFloat(2);
    float duration      = (argc >= 3) ? lua->getArgFloat(3) : DEFAULT_DURATION;
    int easeFunction    = (argc >= 4) ? lua->getArgInt(4) : DEFAULT_EASE_FUNCTION;

    duration = durationOrDefault(duration);
    if (easeFunction <= 0) easeFunction = DEFAULT_EASE_FUNCTION;

    int lastIdx = ea->count - 1;
    float lastEnd = ea->segments[lastIdx].endTime;
    float lastTo  = ea->segments[lastIdx].to;

    // Append new segment
    EasingSegment* seg = ensureCapacityAndInsert(ea);
    if (!seg) { lua->pushNil(); lua->pushString("oom"); return 2; }

    seg->timestamp    = lastEnd;
    seg->from         = lastTo;
    seg->to           = newTo;
    seg->duration     = duration;
    seg->endTime      = seg->timestamp + seg->duration;
    seg->easeFunction = easeFunction;

    // Appended at end keeps sorted
    // (timestamp >= previous endTime)
    ea->isSorted &= (ea->count <= 1 || ea->segments[ea->count-1].timestamp >= ea->segments[ea->count-2].timestamp);

    if (seg->endTime > ea->totalDuration) ea->totalDuration = seg->endTime;
    resetPlaybackState(ea);

    lua->pushBool(1);
    return 1;
}

// ! Set
static int easingArray_set(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) { lua->pushNil(); return 1; }

    float value = lua->getArgFloat(2);
    float newTimestamp = 0.0f;
    if (ea->count > 0) newTimestamp = ea->segments[ea->count - 1].endTime;

    EasingSegment* seg = ensureCapacityAndInsert(ea);
    if (!seg) { lua->pushNil(); lua->pushString("oom"); return 2; }

    seg->timestamp    = newTimestamp;
    seg->from         = value;
    seg->to           = value;
    seg->duration     = 0.0f;
    seg->endTime      = newTimestamp;
    seg->easeFunction = 0;

    if (seg->endTime > ea->totalDuration) ea->totalDuration = seg->endTime;
    ea->isSorted &= (ea->count <= 1 || ea->segments[ea->count-1].timestamp >= ea->segments[ea->count-2].timestamp);
    resetPlaybackState(ea);

    lua->pushBool(1);
    return 1;
}

// ! Sleep
static int easingArray_sleep(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) { lua->pushNil(); return 1; }

    float duration = durationOrZero(lua->getArgFloat(2));
    int lastIdx = ea->count - 1;
    float lastEnd = ea->segments[lastIdx].endTime;
    float lastTo  = ea->segments[lastIdx].to;

    EasingSegment* seg = ensureCapacityAndInsert(ea);
    if (!seg) { lua->pushNil(); lua->pushString("oom"); return 2; }

    seg->timestamp    = lastEnd;
    seg->from         = lastTo;
    seg->to           = lastTo;
    seg->duration     = duration;
    seg->endTime      = seg->timestamp + seg->duration;
    seg->easeFunction = 0;

    if (seg->endTime > ea->totalDuration) ea->totalDuration = seg->endTime;
    ea->isSorted &= (ea->count <= 1 || ea->segments[ea->count-1].timestamp >= ea->segments[ea->count-2].timestamp);
    resetPlaybackState(ea);

    lua->pushBool(1);
    return 1;
}

// ! Set loop
static int easingArray_setLoopType(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) { lua->pushNil(); return 1; }

    int argc = lua->getArgCount();
    int loopType  = (argc >= 2) ? lua->getArgInt(2) : 0;  // 0,1,2
    float loopCount = (argc >= 3) ? lua->getArgFloat(3) : 0.0f;  // 0.0f=infinite

    // Clamp loopType to [0,2]
    if (loopType < 0) loopType = 0;
    if (loopType > 2) loopType = 2;
    ea->loopType    = loopType;
    ea->loopCount   = (!isfinite(loopCount) || loopCount < 0.0f) ? 0.0f : loopCount;
    resetPlaybackState(ea);

    lua->pushBool(1);
    return 1;
}

// ! Again
static int easingArray_again(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) { lua->pushNil(); return 1; }

    long long rc = (long long)lua->getArgInt(2);
    if (rc <= 0) rc = DEFAULT_REPEAT_COUNT;
    if (rc > INT_MAX) { lua->pushNil(); lua->pushString("repeat overflow"); return 2; }
    int repeatCount = (int)rc;

    // Needed elements (count + rc) may overflow int; use size_t
    size_t needed = (size_t)ea->count + (size_t)repeatCount;
    if (needed < (size_t)ea->count) { // overflow wrap
        lua->pushNil(); lua->pushString("repeat overflow"); return 2;
    }

    if (needed > (size_t)INT_MAX) { lua->pushNil(); lua->pushString("capacity overflow"); return 2; }
    if (!ensureCapacity(ea, needed)) { lua->pushNil(); lua->pushString("oom"); return 2; }

    int lastIdx = ea->count - 1;
    EasingSegment* lastSeg = &ea->segments[lastIdx];
    float newTimestamp  = lastSeg->endTime;
    float newFrom       = lastSeg->from;
    float newTo         = lastSeg->to;
    float newDuration   = lastSeg->duration;
    int newEaseFunction = lastSeg->easeFunction;

    for (int r = 0; r < repeatCount; r++) {
        EasingSegment* seg = ensureCapacityAndInsert(ea);
        if (!seg) { lua->pushNil(); lua->pushString("oom"); return 2; }

        seg->timestamp    = newTimestamp;
        seg->from         = newFrom;
        seg->to           = newTo;
        seg->duration     = newDuration;
        seg->endTime      = seg->timestamp + seg->duration;
        seg->easeFunction = newEaseFunction;

        newTimestamp = seg->endTime;
        if (seg->endTime > ea->totalDuration) ea->totalDuration = seg->endTime;
    }

    ea->isSorted = 1; // Appends preserve order
    resetPlaybackState(ea);

    lua->pushBool(1);
    return 1;
}

// ! Reverse
static int easingArray_reverse(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) { lua->pushNil(); return 1; }

    int appendNew          = lua->getArgBool(2);
    int lastIdx            = ea->count - 1;
    EasingSegment* lastSeg = &ea->segments[lastIdx];

    if (!appendNew) {
        float temp    = lastSeg->from;
        lastSeg->from = lastSeg->to;
        lastSeg->to   = temp;
        resetPlaybackState(ea);
        lua->pushBool(1);
        return 1;
    }

    float lastEnd      = lastSeg->endTime;
    float lastFrom     = lastSeg->from;
    float lastTo       = lastSeg->to;
    float lastDuration = lastSeg->duration;
    int lastEase       = lastSeg->easeFunction;

    EasingSegment* seg = ensureCapacityAndInsert(ea);
    if (!seg) { lua->pushNil(); lua->pushString("oom"); return 2; }

    seg->timestamp    = lastEnd;
    seg->from         = lastTo;
    seg->to           = lastFrom;
    seg->duration     = lastDuration;
    seg->endTime      = seg->timestamp + seg->duration;
    seg->easeFunction = lastEase;

    if (seg->endTime > ea->totalDuration) ea->totalDuration = seg->endTime;
    ea->isSorted &= (ea->count <= 1 || ea->segments[ea->count-1].timestamp >= ea->segments[ea->count-2].timestamp);
    resetPlaybackState(ea);

    lua->pushBool(1);
    return 1;
}

/*******************************************//**
 *  Lua-Exposed Methods: Query and Control
 ***********************************************/

// ! Get easing data
static int easingArray_getEasingData(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    int idx = lua->getArgInt(2);
    if (!ea || idx <= 0 || idx > ea->count) { lua->pushNil(); return 1; }

    EasingSegment* seg = &ea->segments[idx - 1];
    lua->pushFloat(seg->timestamp);
    lua->pushFloat(seg->from);
    lua->pushFloat(seg->to);
    lua->pushFloat(seg->duration);
    lua->pushFloat(seg->endTime);
    lua->pushInt(seg->easeFunction);
    return 6;
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
        lua->pushFloat(0.0f); lua->pushFloat(0.0f); lua->pushFloat(0.0f); lua->pushBool(1);
        return 4;
    }

    float oldTime = ea->currentTime;

    // If already completed, return boundary-correct value (handles fractional loop counts).
    if (ea->completed) {
        float boundaryTime = boundaryTimeForCompletion(ea);
        float val = evalAtTime(ea, boundaryTime);
        lua->pushFloat(oldTime);
        lua->pushFloat(oldTime);
        lua->pushFloat(val);
        lua->pushBool(1);
        return 4;
    }

    float step = lua->getArgFloat(2);
    float newTime = ea->currentTime;

    if (ea->loopType >= 0 && ea->loopType <= 2) {
        handlers[ea->loopType](ea, &newTime, step);
    }

    ea->currentTime = newTime;

    // If we just completed, also return the boundary-correct value (fraction-aware)
    if (ea->completed) {
        float boundaryTime = boundaryTimeForCompletion(ea);
        float val = evalAtTime(ea, boundaryTime);
        lua->pushFloat(oldTime);
        lua->pushFloat(ea->currentTime);
        lua->pushFloat(val);
        lua->pushBool(1);
        return 4;
    }

    float clamped = 0.0f;
    const EasingSegment* easing = findSegmentForTime(ea, ea->currentTime, &clamped);

    if (easing->duration <= 0.0f) {
        lua->pushFloat(oldTime);
        lua->pushFloat(ea->currentTime);
        lua->pushFloat(easing->to);
        lua->pushBool(0);
        return 4;
    }

    lua->pushFloat(oldTime);
    lua->pushFloat(ea->currentTime);
    lua->pushFloat(evaluateSegmentAtTime(ea, easing, clamped));
    lua->pushBool(0);
    return 4;
}

static int easingArray_getValue(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea || ea->count == 0) { lua->pushFloat(0.0f); return 1; }

    float time = lua->getArgFloat(2);
    lua->pushFloat(evalAtTime(ea, time));
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

    resetPlaybackState(ea);

    lua->pushBool(1);
    return 1;
}

// ! Clear Easing Array
static int easingArray_clear(lua_State* L)
{
    EasingArray* ea = lua->getArgObject(1, "RoxySequenceC", NULL);
    if (!ea) return 0;

    ea->count               = 0;
    ea->totalDuration       = 0.0f;
    ea->isSorted            = 1;
    resetLoopConfiguration(ea);

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
    { "__len",              easingArray_len               },
    { "setName",            easingArray_setName           },
    { "getName",            easingArray_getName           },
    { "addEasing",          easingArray_addEasing         },
    { "setEasingAt",        easingArray_setEasingAt       },
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
