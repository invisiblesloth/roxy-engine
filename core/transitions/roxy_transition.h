#ifndef ROXY_TRANSITION_H
#define ROXY_TRANSITION_H

#include "pd_api.h"

void roxy_transition_setPlaydateAPI(PlaydateAPI* playdate);

int roxy_transition_crossDissolveDrawFrame_l(lua_State* L);

#endif /* ROXY_TRANSITION_H */
