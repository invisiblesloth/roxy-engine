//
// Adapted from
// Nic Magnier's Sequence library (https://github.com/NicMagnier/PlaydateSequence)
//

#ifndef ROXY_SEQUENCE_H
#define ROXY_SEQUENCE_H

#include "pd_api.h"

void roxy_sequence_setPlaydateAPI(PlaydateAPI* playdate);

// Lua binding for retrieving clamped time in a sequence.
// Runs the implementation in C (see roxy_sequence.c) for performance.
// See RoxySequence.lua for the rest of the sequence logic.
int roxy_sequence_getClampedTime_l(lua_State* L);

#endif /* ROXY_SEQUENCE_H */
