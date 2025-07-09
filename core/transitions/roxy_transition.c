// core/transitions/roxy_transition.c

#include "roxy_transition.h"

static PlaydateAPI* pd = NULL;

void roxy_transition_setPlaydateAPI(PlaydateAPI* playdate)
{
    pd = playdate;
}

int roxy_transition_crossDissolveDrawFrame_l(lua_State* L)
{
    if (!pd) { return 0; }
    
    // 1: full-screen snapshot
    LCDBitmap* screenshot = pd->lua->getBitmap(1);
    // 2: 16×16 dither pattern image (one of your self.patterns[])
    LCDBitmap* pattern    = pd->lua->getBitmap(2);

    if (!screenshot || !pattern) {
        pd->system->logToConsole("roxy ERROR: bad image or pattern");
        return 0;
    }

    // Tile the 16×16 pattern over the entire display as a stencil
    pd->graphics->setStencilImage(pattern, 1);
    // Draw the screenshot, but only where the stencil bits are “on”
    pd->graphics->drawBitmap(screenshot, 0, 0, kBitmapUnflipped);
    // Clear the stencil so we don’t affect other drawing
    pd->graphics->setStencilImage(NULL, 0);

    return 0;  // no return values
}
