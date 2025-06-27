#ifndef ROXY_ANIMATION_H
#define ROXY_ANIMATION_H

#include "pd_api.h"

void roxy_animation_setPlaydateAPI(PlaydateAPI* playdate);

int roxy_animation_update_l(lua_State* L);

#endif /* ROXY_ANIMATION_H */
