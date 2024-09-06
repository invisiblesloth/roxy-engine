#ifndef ROXY_INPUT_H
#define ROXY_INPUT_H

#include "pd_api.h"

void roxy_input_setPlaydateAPI(PlaydateAPI* playdate);

// Sets the buffer amount for detecting a continuous button hold, called from Lua.
int roxy_input_setButtonHoldBufferAmount_l(lua_State* L);

// Sets the custom threshold for detecting a custom button hold duration, called from Lua.
int roxy_input_setCustomHoldThreshold_l(lua_State* L);

// ! Process Button Events
// Handles input processing for button A, determining its state and invoking the corresponding Lua callback.
int roxy_input_processButtonA_l(lua_State* L);

// Handles input processing for button B, determining its state and invoking the corresponding Lua callback.
int roxy_input_processButtonB_l(lua_State* L);

// Handles input processing for the Up button, determining its state and invoking the corresponding Lua callback.
int roxy_input_processButtonUp_l(lua_State* L);

// Handles input processing for the Down button, determining its state and invoking the corresponding Lua callback.
int roxy_input_processButtonDown_l(lua_State* L);

// Handles input processing for the Left button, determining its state and invoking the corresponding Lua callback.
int roxy_input_processButtonLeft_l(lua_State* L);

// Handles input processing for the Right button, determining its state and invoking the corresponding Lua callback.
int roxy_input_processButtonRight_l(lua_State* L);

#endif /* ROXY_INPUT_H */
