#ifndef ROXY_INPUT_H
#define ROXY_INPUT_H

#include "pd_api.h"

void roxy_input_setPlaydateAPI(PlaydateAPI* playdate);

// Set the hold buffer amount (frames before continuous hold event)
int roxy_input_setButtonHoldBufferAmount_l(lua_State* L);

// Processes all button events in one batch, 
// returning a Lua table of triggered callbacks
int roxy_input_processAllButtons_l(lua_State* L);

#endif /* ROXY_INPUT_H */
