// core/tilemaps/roxy_tileRenderer.c

#include "roxy_tileRenderer.h"
#include "../../utilities/roxy_math.h"
#include <string.h>
#include <math.h>

static PlaydateAPI* pd = NULL;

void roxy_tileRenderer_setPlaydateAPI(PlaydateAPI* playdate)
{
    pd = playdate;
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

static void* pd_alloc(size_t sz)
{
    return pd->system->realloc(NULL, sz);
}

static void pd_free(void* p)
{
    pd->system->realloc(p, 0);
}

static inline int indexFromRowColumn(const RoxyTileRendererC* tileRenderer, int columnZeroBased, int rowZeroBased)
{
    // 0-based row/column
    return rowZeroBased * tileRenderer->mapWidth + columnZeroBased;
}

static inline int16_t safeOffsetX(const RoxyTileRendererC* tileRenderer, int tileIndex)
{
    if (tileIndex < 1 || tileIndex > tileRenderer->imageCount) return 0;
    return tileRenderer->offsetX[tileIndex];
}

static inline int16_t safeOffsetY(const RoxyTileRendererC* tileRenderer, int tileIndex)
{
    if (tileIndex < 1 || tileIndex > tileRenderer->imageCount) return 0;
    return tileRenderer->offsetY[tileIndex];
}

// Only for staggered-y
static inline int rowShiftX_for_row0(const RoxyTileRendererC* tileRenderer, int rowZeroBased)
{
    if (tileRenderer->isIsometric) return 0;

    int rowIsOdd = (rowZeroBased & 1);
    int shouldShift = tileRenderer->staggerIndexOdd ? rowIsOdd : !rowIsOdd;

    if (!shouldShift) return 0;

    return tileRenderer->staggerDirectionRight ? tileRenderer->halfTileWidth : -tileRenderer->halfTileWidth;
}

// -----------------------------------------------------------------------------
// lifetime
// -----------------------------------------------------------------------------

// ! Free Renderer
static void roxy_tileRenderer_free(RoxyTileRendererC* tileRenderer)
{
    if (!tileRenderer || !tileRenderer->alive) return;
    tileRenderer->alive = 0;

    if (tileRenderer->imageTableUserData) {
        pd->lua->releaseObject(tileRenderer->imageTableUserData);
        tileRenderer->imageTableUserData = NULL;
    }

    if (tileRenderer->offsetX) {
        pd_free(tileRenderer->offsetX);
        tileRenderer->offsetX = NULL;
    }

    if (tileRenderer->offsetY) {
        pd_free(tileRenderer->offsetY);
        tileRenderer->offsetY = NULL;
    }

    if (tileRenderer->tiles) {
        pd_free(tileRenderer->tiles);
        tileRenderer->tiles = NULL;
    }
}

// ! New Tile Renderer
static int roxy_tileRenderer_newobject(lua_State* L)
{
    if (!pd) return 0;

    const int argumentCount = pd->lua->getArgCount();
    if (argumentCount < 12) {
        pd->system->logToConsole("RoxyTileRendererC.new: expected >= 12 args, got %d", argumentCount);
        return 0;
    }

    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd_alloc(sizeof(RoxyTileRendererC));
    if (!tileRenderer) return 0;
    memset(tileRenderer, 0, sizeof(*tileRenderer));
    tileRenderer->alive = 1;

    tileRenderer->isIsometric           = pd->lua->getArgInt(1);
    tileRenderer->staggerIndexOdd       = pd->lua->getArgInt(2);
    tileRenderer->staggerDirectionRight = pd->lua->getArgInt(3);
    tileRenderer->mapWidth              = pd->lua->getArgInt(4);
    tileRenderer->mapHeight             = pd->lua->getArgInt(5);
    tileRenderer->tileWidth             = pd->lua->getArgInt(6);
    tileRenderer->tileHeight            = pd->lua->getArgInt(7);
    tileRenderer->halfTileWidth         = pd->lua->getArgInt(8);
    tileRenderer->halfTileHeight        = pd->lua->getArgInt(9);
    tileRenderer->maxImageHeight        = pd->lua->getArgInt(10);

    // Imagetable
    LuaUDObject* userDataObject = NULL;
    tileRenderer->imageTable = pd->lua->getArgObject(11, "playdate.graphics.imagetable", &userDataObject);
    if (!tileRenderer->imageTable || !userDataObject) {
        pd->system->logToConsole("RoxyTileRendererC.new: imagetable is nil/invalid");
        pd_free(tileRenderer);
        return 0;
    }
    tileRenderer->imageTableUserData = pd->lua->retainObject(userDataObject);
    tileRenderer->imageCount = pd->lua->getArgInt(12);

    // Precompute draw offsets
    tileRenderer->offsetX = (int16_t*)pd_alloc(sizeof(int16_t) * (tileRenderer->imageCount + 1));
    tileRenderer->offsetY = (int16_t*)pd_alloc(sizeof(int16_t) * (tileRenderer->imageCount + 1));
    if (!tileRenderer->offsetX || !tileRenderer->offsetY) {
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }
    tileRenderer->offsetX[0] = tileRenderer->offsetY[0] = 0;

    for (int i = 1; i <= tileRenderer->imageCount; ++i) {
        LCDBitmap* cell = pd->graphics->getTableBitmap(tileRenderer->imageTable, i - 1);
        if (!cell) { tileRenderer->offsetX[i] = 0; tileRenderer->offsetY[i] = 0; continue; }
        int imageWidth = 0, imageHeight = 0;
        pd->graphics->getBitmapData(cell, &imageWidth, &imageHeight, NULL, NULL, NULL);
        const int16_t offsetX = (int16_t)((tileRenderer->tileWidth  - imageWidth) / 2);
        const int16_t offsetY = (int16_t)((tileRenderer->tileHeight - imageHeight));
        tileRenderer->offsetX[i] = offsetX;
        tileRenderer->offsetY[i] = offsetY;
    }

    // Tiles blob (optional)
    const int tilesCount = tileRenderer->mapWidth * tileRenderer->mapHeight;
    tileRenderer->tiles = (int32_t*)pd_alloc(sizeof(int32_t) * tilesCount);
    if (!tileRenderer->tiles) {
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }
    memset(tileRenderer->tiles, 0, sizeof(int32_t) * tilesCount);

    if (argumentCount >= 13 && !pd->lua->argIsNil(13)) {
        size_t bytesLength = 0;
        const char* bytes = pd->lua->getArgBytes(13, &bytesLength);
        tileRenderer->tilesCountBytes = (int)bytesLength;
        if (bytes && bytesLength > 0) {
            if ((int)bytesLength == tilesCount * 2) {
                // 16-bit packed
                for (int i = 0; i < tilesCount; ++i) {
                    uint16_t value = ((const uint8_t*)bytes)[2*i] | (((const uint8_t*)bytes)[2*i + 1] << 8);
                    tileRenderer->tiles[i] = (int32_t)value;
                }
            } else if ((int)bytesLength == tilesCount * 4) {
                // 32-bit little endian
                for (int i = 0; i < tilesCount; ++i) {
                    const uint8_t* pointer = (const uint8_t*)bytes + 4*i;
                    tileRenderer->tiles[i] = (int32_t)(pointer[0] | (pointer[1]<<8) | (pointer[2]<<16) | (pointer[3]<<24));
                }
            } else {
                pd->system->logToConsole("RoxyTileRendererC.new: tiles blob size %d doesn't match 2*%d or 4*%d",
                                       (int)bytesLength, tilesCount, tilesCount);
            }
        }
    }

    pd->lua->pushObject(tileRenderer, "RoxyTileRendererC", 0);
    return 1;
}

// ! Garbage Collection (__gc)
static int roxy_tileRenderer_gc(lua_State* L)
{
    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd->lua->getArgObject(1, "RoxyTileRendererC", NULL);
    if (tileRenderer) {
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
    }
    return 0;
}

// ! Update Tiles Bytes
// lua: self:updateTilesBytes(bytes)
// bytes length must be mapWidth*mapHeight*(2 or 4)
static int roxy_tileRenderer_updateTilesBytes(lua_State* L)
{
    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd->lua->getArgObject(1, "RoxyTileRendererC", NULL);
    if (!tileRenderer || !tileRenderer->alive) return 0;

    size_t bytesLength = 0;
    const char* bytes = pd->lua->getArgBytes(2, &bytesLength);
    if (!bytes || bytesLength == 0) return 0;

    const int tilesCount = tileRenderer->mapWidth * tileRenderer->mapHeight;
    if ((int)bytesLength != tilesCount * 2 && (int)bytesLength != tilesCount * 4) {
        pd->system->logToConsole("updateTilesBytes: bad size %d (expected %d or %d)",
                                 (int)bytesLength, tilesCount*2, tilesCount*4);
        return 0;
    }

    if (!tileRenderer->tiles) {
        tileRenderer->tiles = (int32_t*)pd_alloc(sizeof(int32_t) * tilesCount);
        if (!tileRenderer->tiles) return 0;
    }

    tileRenderer->tilesCountBytes = (int)bytesLength;
    if ((int)bytesLength == tilesCount * 2) {
        for (int i = 0; i < tilesCount; ++i) {
            uint16_t value = ((const uint8_t*)bytes)[2*i] | (((const uint8_t*)bytes)[2*i + 1] << 8);
            tileRenderer->tiles[i] = (int32_t)value;
        }
    } else {
        for (int i = 0; i < tilesCount; ++i) {
            const uint8_t* pointer = (const uint8_t*)bytes + 4*i;
            tileRenderer->tiles[i] = (int32_t)(pointer[0] | (pointer[1]<<8) | (pointer[2]<<16) | (pointer[3]<<24));
        }
    }
    return 0;
}

// ! Set Tile At
// lua: self:setTileAt(x, y, tileIndex) -- 1-based x/y like Lua
static int roxy_tileRenderer_setTileAt(lua_State* L)
{
    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd->lua->getArgObject(1, "RoxyTileRendererC", NULL);
    if (!tileRenderer || !tileRenderer->alive || !tileRenderer->tiles) return 0;

    int x = pd->lua->getArgInt(2);
    int y = pd->lua->getArgInt(3);
    int tileIndex = pd->lua->getArgInt(4);

    x = roxy_math_clampi(x, 1, tileRenderer->mapWidth);
    y = roxy_math_clampi(y, 1, tileRenderer->mapHeight);

    tileRenderer->tiles[indexFromRowColumn(tileRenderer, x-1, y-1)] = tileIndex;

    return 0;
}

// ! Draw Cell
// core draw for a single tile (shared)
static inline void drawCell(const RoxyTileRendererC* tr, int tileIndex, int sx, int sy)
{
    if (tileIndex <= 0 || tileIndex > tr->imageCount) return;
    LCDBitmap* cell = pd->graphics->getTableBitmap(tr->imageTable, tileIndex - 1);
    if (!cell) return;

    const int dx = sx + safeOffsetX(tr, tileIndex);
    const int dy = sy + safeOffsetY(tr, tileIndex);

    pd->graphics->drawBitmap(cell, dx, dy, kBitmapUnflipped);
}

// ! Draw Rows
// lua: self:drawRows(minRow, maxRow, minCol, maxCol,
//                    originX, originY,
//                    parallaxX, parallaxY,
//                    parallaxOriginX, parallaxOriginY,
//                    cameraX, cameraY)
static int roxy_tileRenderer_drawRows(lua_State* L)
{
    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd->lua->getArgObject(1, "RoxyTileRendererC", NULL);
    if (!tileRenderer || !tileRenderer->alive || !tileRenderer->tiles) return 0;

    int minRow = pd->lua->getArgInt(2);
    int maxRow = pd->lua->getArgInt(3);
    int minColumn = pd->lua->getArgInt(4);
    int maxColumn = pd->lua->getArgInt(5);

    int originX = pd->lua->getArgInt(6);
    int originY = pd->lua->getArgInt(7);

    float parallaxX = pd->lua->getArgFloat(8);
    float parallaxY = pd->lua->getArgFloat(9);

    int parallaxOriginX = pd->lua->getArgInt(10);
    int parallaxOriginY = pd->lua->getArgInt(11);

    int cameraX = pd->lua->getArgInt(12);
    int cameraY = pd->lua->getArgInt(13);

    minRow = roxy_math_clampi(minRow, 1, tileRenderer->mapHeight);
    maxRow = roxy_math_clampi(maxRow, 1, tileRenderer->mapHeight);
    minColumn = roxy_math_clampi(minColumn, 1, tileRenderer->mapWidth);
    maxColumn = roxy_math_clampi(maxColumn, 1, tileRenderer->mapWidth);
    if (minRow > maxRow || minColumn > maxColumn) return 0;

    const float pivotAdjustX = parallaxOriginX * (1.f - parallaxX);
    const float pivotAdjustY = parallaxOriginY * (1.f - parallaxY);

    if (!tileRenderer->isIsometric) {
        // staggered-y (rows step by halfTileHeight, X steps full tileWidth + row shift)
        for (int tileY = minRow; tileY <= maxRow; ++tileY) {
            const int rowZeroBased = tileY - 1;
            const int rowShift = rowShiftX_for_row0(tileRenderer, rowZeroBased);

            const int baseX = roxy_math_roundInt(originX + rowShift + pivotAdjustX - cameraX * parallaxX);
            const int baseY = roxy_math_roundInt(originY + rowZeroBased * tileRenderer->halfTileHeight + pivotAdjustY - cameraY * parallaxY);

            int screenX = baseX + (minColumn - 1) * tileRenderer->tileWidth;
            const int rowIndexBase = rowZeroBased * tileRenderer->mapWidth + (minColumn - 1);

            for (int tileX = minColumn, tileIndex = rowIndexBase; tileX <= maxColumn; ++tileX, ++tileIndex) {
                const int currentTileIndex = tileRenderer->tiles[tileIndex];
                if (currentTileIndex > 0) drawCell(tileRenderer, currentTileIndex, screenX, baseY);
                screenX += tileRenderer->tileWidth;
            }
        }
    } else {
        // Isometric
        for (int tileY = minRow; tileY <= maxRow; ++tileY) {
            const int rowZeroBased = tileY - 1;
            const int rowIndexBase = rowZeroBased * tileRenderer->mapWidth + (minColumn - 1);
            for (int tileX = minColumn, tileIndex = rowIndexBase; tileX <= maxColumn; ++tileX, ++tileIndex) {
                const int columnZeroBased = tileX - 1;
                const float worldX = (float)columnZeroBased;
                const float worldY = (float)rowZeroBased;

                const int isoX = roxy_math_roundInt(originX + (worldX - worldY) * tileRenderer->halfTileWidth + pivotAdjustX - cameraX * parallaxX);
                const int isoY = roxy_math_roundInt(originY + (worldX + worldY) * tileRenderer->halfTileHeight + pivotAdjustY - cameraY * parallaxY);

                const int currentTileIndex = tileRenderer->tiles[tileIndex];
                if (currentTileIndex > 0) drawCell(tileRenderer, currentTileIndex, isoX, isoY);
            }
        }
    }
    return 0;
}

// ! Render to Buffer
// lua: self:renderToBuffer(targetBitmap, offsetX, offsetY, bufferWidth, bufferHeight)
// Draws the layer in layer-local coords into target bitmap. If target is nil,
// draws into the current context.
static int roxy_tileRenderer_renderToBuffer(lua_State* L)
{
    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd->lua->getArgObject(1, "RoxyTileRendererC", NULL);
    if (!tileRenderer || !tileRenderer->alive || !tileRenderer->tiles) return 0;

    LCDBitmap* targetBitmap = pd->lua->getBitmap(2);  // May be NULL
    const int offsetX = pd->lua->getArgInt(3);
    const int offsetY = pd->lua->getArgInt(4);
    const int bufferWidth = pd->lua->getArgInt(5);
    const int bufferHeight = pd->lua->getArgInt(6);

    int contextPushed = 0;
    if (targetBitmap) {
        pd->graphics->pushContext(targetBitmap);
        contextPushed = 1;
    }

    // Compute conservative row/column bounds
    if (!tileRenderer->isIsometric) {
        // staggered-y
        const int overdrawRows = (int)ceilf(fmaxf(0.f, (float)(tileRenderer->maxImageHeight - tileRenderer->tileHeight)) /
                                          fmaxf(1.f, (float)tileRenderer->halfTileHeight)) + 1;

        int minRowZeroBased = (int)floorf((float)(-offsetY - tileRenderer->maxImageHeight) /
                                        (float)tileRenderer->halfTileHeight) - 1 - overdrawRows;
        int maxRowZeroBased = (int)ceilf ((float)(bufferHeight - offsetY) /
                                        (float)tileRenderer->halfTileHeight) + 1 + overdrawRows;
        minRowZeroBased = roxy_math_clampi(minRowZeroBased, 0, tileRenderer->mapHeight - 1);
        maxRowZeroBased = roxy_math_clampi(maxRowZeroBased, 0, tileRenderer->mapHeight - 1);

        for (int rowZeroBased = minRowZeroBased; rowZeroBased <= maxRowZeroBased; ++rowZeroBased) {
            const int baseX = rowShiftX_for_row0(tileRenderer, rowZeroBased) + offsetX;
            const int baseY = rowZeroBased * tileRenderer->halfTileHeight + offsetY;

            int minColumnZeroBased = (int)floorf((float)(-tileRenderer->tileWidth - baseX) / (float)tileRenderer->tileWidth) - 1;
            int maxColumnZeroBased = (int)floorf((float)(bufferWidth - 1 - baseX) / (float)tileRenderer->tileWidth) + 1;
            minColumnZeroBased = roxy_math_clampi(minColumnZeroBased, 0, tileRenderer->mapWidth - 1);
            maxColumnZeroBased = roxy_math_clampi(maxColumnZeroBased, 0, tileRenderer->mapWidth - 1);

            int drawX = baseX + minColumnZeroBased * tileRenderer->tileWidth;
            int tileIndex = rowZeroBased * tileRenderer->mapWidth + minColumnZeroBased;
            for (int columnZeroBased = minColumnZeroBased; columnZeroBased <= maxColumnZeroBased; ++columnZeroBased, ++tileIndex) {
                const int currentTileIndex = tileRenderer->tiles[tileIndex];
                if (currentTileIndex > 0) {
                    const int dx = drawX + safeOffsetX(tileRenderer, currentTileIndex);
                    const int dy = baseY + safeOffsetY(tileRenderer, currentTileIndex);
                    if (dx < bufferWidth && dy < bufferHeight && dx > -tileRenderer->tileWidth && dy > -tileRenderer->tileHeight) {
                        LCDBitmap* cell = pd->graphics->getTableBitmap(tileRenderer->imageTable, currentTileIndex - 1);
                        if (cell) pd->graphics->drawBitmap(cell, dx, dy, kBitmapUnflipped);
                    }
                }
                drawX += tileRenderer->tileWidth;
            }
        }
    } else {
        // Isometric
        // Conservative world bounds — these are broad but safe for a stub
        const int overdrawRows = (int)ceilf(fmaxf(0.f, (float)(tileRenderer->maxImageHeight - tileRenderer->tileHeight)) / fmaxf(1.f, (float)tileRenderer->halfTileHeight)) + 1;

        const int minColumnZeroBased = roxy_math_clampi(-(bufferWidth / tileRenderer->halfTileWidth) - overdrawRows, 0, tileRenderer->mapWidth  - 1);
        const int maxColumnZeroBased = roxy_math_clampi((bufferWidth / tileRenderer->halfTileWidth) + overdrawRows, 0, tileRenderer->mapWidth  - 1);
        const int minRowZeroBased = roxy_math_clampi(-(bufferHeight / tileRenderer->halfTileHeight) - overdrawRows, 0, tileRenderer->mapHeight - 1);
        const int maxRowZeroBased = roxy_math_clampi((bufferHeight / tileRenderer->halfTileHeight) + overdrawRows, 0, tileRenderer->mapHeight - 1);

        for (int rowZeroBased = minRowZeroBased; rowZeroBased <= maxRowZeroBased; ++rowZeroBased) {
            for (int columnZeroBased = minColumnZeroBased; columnZeroBased <= maxColumnZeroBased; ++columnZeroBased) {
                const int tileIndex = indexFromRowColumn(tileRenderer, columnZeroBased, rowZeroBased);
                const int currentTileIndex = tileRenderer->tiles[tileIndex];
                if (currentTileIndex <= 0) continue;

                const float worldX = (float)columnZeroBased;
                const float worldY = (float)rowZeroBased;
                const int screenX = roxy_math_roundInt((worldX - worldY) * tileRenderer->halfTileWidth  + offsetX);
                const int screenY = roxy_math_roundInt((worldX + worldY) * tileRenderer->halfTileHeight + offsetY);

                const int drawX = screenX + safeOffsetX(tileRenderer, currentTileIndex);
                const int drawY = screenY + safeOffsetY(tileRenderer, currentTileIndex);
                if (drawX < bufferWidth && drawY < bufferHeight && drawX > -tileRenderer->tileWidth && drawY > -tileRenderer->tileHeight) {
                    LCDBitmap* cell = pd->graphics->getTableBitmap(tileRenderer->imageTable, currentTileIndex - 1);
                    if (cell) pd->graphics->drawBitmap(cell, drawX, drawY, kBitmapUnflipped);
                }
            }
        }
    }

    if (contextPushed) pd->graphics->popContext();
    return 0;
}

// ! Destroy
static int roxy_tileRenderer_destroy(lua_State* L)
{
    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd->lua->getArgObject(1, "RoxyTileRendererC", NULL);
    if (tileRenderer) roxy_tileRenderer_free(tileRenderer);
    return 0;
}

static const lua_reg roxyTileRendererLib[] = {
    {    "new",                     roxy_tileRenderer_newobject               },
    {    "__gc",                    roxy_tileRenderer_gc                      },
    {    "updateTilesBytes",        roxy_tileRenderer_updateTilesBytes        },
    {    "setTileAt",               roxy_tileRenderer_setTileAt               },
    {    "drawRows",                roxy_tileRenderer_drawRows                },
    {    "renderToBuffer",          roxy_tileRenderer_renderToBuffer          },
    {    "destroy",                 roxy_tileRenderer_destroy                 },
    {    NULL, NULL    }
};

void registerRoxyTileRendererC(PlaydateAPI* playdate)
{
    pd = playdate;

    const char* err = NULL;
    if (!pd->lua->registerClass("RoxyTileRendererC", roxyTileRendererLib, NULL, 0, &err)) {
        pd->system->logToConsole("%s:%i: registerClass failed, %s", __FILE__, __LINE__, err);
    }
}
