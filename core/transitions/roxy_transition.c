// core/transitions/roxy_transition.c

#include "roxy_transition.h"
#include "../../utilities/roxy_math.h"
#include <math.h>

static PlaydateAPI* pd = NULL;

void roxy_transition_setPlaydateAPI(PlaydateAPI* playdate)
{
    pd = playdate;
}

// ! Fade to Color Draw Frame
// Tiles the provided pattern bitmap across the entire screen.
//
// Lua signature:
//   Transition.FadeToColorDrawFrame(
//     pattern : LCDBitmap - The pattern/color bitmap to tile across the screen
//   )
int roxy_transition_fadeToColorDrawFrame_l(lua_State* L)
{
    if (!pd) return 0;

    // Must have at least 1 argument
    int argc = pd->lua->getArgCount();
    if (argc < 1) {
        pd->system->logToConsole("Roxy ERROR: FadeToColorDrawFrame requires 1 argument, got %d", argc);
        return 0;
    }

    // Get the pattern bitmap from Lua
    LCDBitmap* pattern = pd->lua->getBitmap(1);
    if (!pattern) {
        pd->system->logToConsole("Roxy ERROR: FadeToColorDrawFrame - invalid or null pattern bitmap");
        return 0;
    }

    // Get screen dimensions
    int width  = pd->display->getWidth();
    int height = pd->display->getHeight();

    // Tile the pattern across the entire screen
    pd->graphics->tileBitmap(pattern, 0, 0, width, height, kBitmapUnflipped);

    return 0;
}

// ! Cross Dissolve Draw Frame
// Performs a cross-dissolve effect by using a pattern as a stencil mask.
//
// Lua signature:
//   Transition.CrossDissolveDrawFrame(
//     screenshot : LCDBitmap, - The background screenshot to draw
//     pattern    : LCDBitmap  - The stencil pattern controlling the dissolve
//   )
int roxy_transition_crossDissolveDrawFrame_l(lua_State* L)
{
    if (!pd) return 0;

    // Must have at least 2 arguments
    int argc = pd->lua->getArgCount();
    if (argc < 2) {
        pd->system->logToConsole("Roxy ERROR: CrossDissolveDrawFrame requires 2 arguments, got %d", argc);
        return 0;
    }

    // Get bitmaps from Lua
    LCDBitmap* screenshot = pd->lua->getBitmap(1);
    LCDBitmap* pattern    = pd->lua->getBitmap(2);

    // Validate both bitmaps
    if (!screenshot) {
        pd->system->logToConsole("Roxy ERROR: CrossDissolveDrawFrame - invalid or null screenshot bitmap");
        return 0;
    }
    if (!pattern) {
        pd->system->logToConsole("Roxy ERROR: CrossDissolveDrawFrame - invalid or null pattern bitmap");
        return 0;
    }

    // Apply stencil pattern and draw screenshot through it
    pd->graphics->setStencilImage(pattern, 1);
    pd->graphics->drawBitmap(screenshot, 0, 0, kBitmapUnflipped);

    // Critical: Clear stencil to prevent affecting subsequent draws
    pd->graphics->setStencilImage(NULL, 0);

    return 0;
}

// ! Image Table Draw Frame
// Renders animated transitions using image tables. Switches between enter and exit
// animations based on the state flags. Progress determines which frame to display
// within the active animation sequence.
//
// Lua signature:
//   Transition.ImageTableDrawFrame(
//     imagetableEnter : LCDBitmapTable, - Animation table for enter phase
//     frameCountEnter : int,            - Number of frames in enter table
//     flipEnter       : int,            - Flip mode for enter animation (LCDBitmapFlip)
//     imagetableExit  : LCDBitmapTable, - Animation table for exit phase
//     frameCountExit  : int,            - Number of frames in exit table
//     flipExit        : int,            - Flip mode for exit animation (LCDBitmapFlip)
//     progress        : float,          - Animation progress [0.0 - 1.0]
//     state           : int             - State bitflags (STATE_HOLD_ELAPSED indicates exit phase)
//   )
int roxy_transition_imageTableDrawFrame_l(lua_State* L)
{
    if (!pd) return 0;

    // Must have exactly 8 arguments
    int argc = pd->lua->getArgCount();
    if (argc < 8) {
        pd->system->logToConsole("Roxy ERROR: ImageTableDrawFrame requires 8 arguments, got %d", argc);
        return 0;
    }

    // (1) Enter table
    LuaUDObject* udEnter = NULL;
    LCDBitmapTable* tableEnter = pd->lua->getArgObject(1, "playdate.graphics.imagetable", &udEnter);

    // (2) Enter frame count
    int countEnter = pd->lua->getArgInt(2);

    // (3) Enter flip mode
    LCDBitmapFlip flipEnter = (LCDBitmapFlip)pd->lua->getArgInt(3);

    // (4) Exit table
    LuaUDObject* udExit = NULL;
    LCDBitmapTable* tableExit = pd->lua->getArgObject(4, "playdate.graphics.imagetable", &udExit);

    // (5) Exit frame count
    int countExit = pd->lua->getArgInt(5);

    // (6) Exit flip mode
    LCDBitmapFlip flipExit = (LCDBitmapFlip)pd->lua->getArgInt(6);

    // (7) Progress [0.0 - 1.0]
    float progress = pd->lua->getArgFloat(7);

    // (8) State bitflags
    int state = pd->lua->getArgInt(8);

    // Validate progress range
    if (progress < 0.0f || progress > 1.0f) {
        pd->system->logToConsole("Roxy ERROR: ImageTableDrawFrame - progress must be in range [0.0, 1.0], got %f", progress);
        return 0;
    }

    // Enter or exit?
    const int STATE_HOLD_ELAPSED = 2;
    bool exitPhase = (state & STATE_HOLD_ELAPSED) != 0;

    // Select appropriate table and parameters for current phase
    LCDBitmapTable* table = exitPhase ? tableExit : tableEnter;
    int frameCount = exitPhase ? countExit : countEnter;
    LCDBitmapFlip flipValue = exitPhase ? flipExit : flipEnter;

    // Validate selected table and frame count
    if (!table) {
        pd->system->logToConsole("Roxy ERROR: ImageTableDrawFrame - null image table for %s phase", exitPhase ? "exit" : "enter");
        return 0;
    }

    if (frameCount <= 0) {
        pd->system->logToConsole("Roxy ERROR: ImageTableDrawFrame - invalid frame count %d for %s phase", frameCount, exitPhase ? "exit" : "enter");
        return 0;
    }

    // Calculate frame index: progress * frameCount, clamped to [1, frameCount]
    int idx = roxy_math_clampi((int)floorf(progress * frameCount) + 1, 1, frameCount);

    // Bounds check for extra safety
    if (idx < 1 || idx > frameCount) {
        pd->system->logToConsole("Roxy ERROR: ImageTableDrawFrame - frame index %d out of bounds [1, %d]", idx, frameCount);
        return 0;
    }

    // Get bitmap from table (convert to zero-based indexing for C API)
    LCDBitmap* cell = pd->graphics->getTableBitmap(table, idx - 1);
    if (!cell) {
        pd->system->logToConsole("Roxy ERROR: ImageTableDrawFrame - failed to get bitmap at index %d from %s phase table", idx - 1, exitPhase ? "exit" : "enter");
        return 0;
    }

    // Draw the selected frame at screen origin
    pd->graphics->drawBitmap(cell, 0, 0, flipValue);

    return 0;
}
