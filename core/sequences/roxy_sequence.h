// core/sequences/roxy_sequence.h

/**
 *
 * Adapted from Nic Magnier's Sequence library.
 * (https://github.com/NicMagnier/PlaydateSequence)
 *
 */

#ifndef ROXY_SEQUENCE_H
#define ROXY_SEQUENCE_H

#include "pd_api.h"

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
    int loopType;           // 0=none,1=loop,2=pingpong
    float loopCount;        // Number of loops; 0.0f = infinite (supports fractions)
    float travelAccum;      // Total forward "path" distance consumed (seconds)
    int loopCounter;
    int pingPongHalfCycles;
    int isForward;          // 1 = forward, 0 = backward
    int isSorted;           // 1 = timestamps non-decreasing
} EasingArray;

typedef void (*LoopHandler)(EasingArray*, float*, float);

void registerRoxySequenceC(PlaydateAPI* pd);

#endif /* ROXY_SEQUENCE_H */
