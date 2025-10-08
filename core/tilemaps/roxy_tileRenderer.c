// core/tilemaps/roxy_tileRenderer.c

#include "roxy_tileRenderer.h"
#include "../../utilities/roxy_math.h"
#include "../../utilities/roxy_heapguard.h"
#include <string.h>
#include <math.h>
#include <limits.h>

#define ROXY_MAGIC 0xA1B2C3D4

static PlaydateAPI* pd = NULL;

void roxy_tileRenderer_setPlaydateAPI(PlaydateAPI* playdate)
{
    pd = playdate;
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

// Site-aware pd_alloc / pd_free that preserve the caller's file:line
static inline void* pd_alloc_site(size_t sz, const char* file, uint32_t line) {
    (void)file; (void)line;
    if (!pd || !pd->system) return NULL;
    return roxy_realloc_site(NULL, sz, file, line);
}
static inline void pd_free_site(void* p, const char* file, uint32_t line) {
    (void)file; (void)line;
    if (!pd || !pd->system) return;
    roxy_free_site(p, file, line);
}
#ifdef pd_alloc
#undef pd_alloc
#endif
#ifdef pd_free
#undef pd_free
#endif
#define pd_alloc(sz) pd_alloc_site((sz), __FILE__, (uint32_t)__LINE__)
#define pd_free(p) pd_free_site((p), __FILE__, (uint32_t)__LINE__)

static inline int roxy_valid(const RoxyTileRendererC* tileRenderer) {
    return tileRenderer && tileRenderer->magic == ROXY_MAGIC && tileRenderer->alive;
}

static inline int indexFromRowColumn(const RoxyTileRendererC* tileRenderer, int columnZeroBased, int rowZeroBased)
{
    // 0-based row/column
    return rowZeroBased * tileRenderer->mapWidth + columnZeroBased;
}

static inline int16_t safeOffsetX(const RoxyTileRendererC* tileRenderer, int tileIndex)
{
    // Guard null offset array
    if (!tileRenderer->offsetX || tileIndex < 1 || tileIndex > tileRenderer->imageCount) return 0;
    return tileRenderer->offsetX[tileIndex];
}

static inline int16_t safeOffsetY(const RoxyTileRendererC* tileRenderer, int tileIndex)
{
    // Guard null offset array
    if (!tileRenderer->offsetY || tileIndex < 1 || tileIndex > tileRenderer->imageCount) return 0;
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
// Lifetime
// -----------------------------------------------------------------------------

// ! Free Renderer
static void roxy_tileRenderer_free(RoxyTileRendererC* tileRenderer)
{
    if (!tileRenderer || !tileRenderer->alive) return;
    tileRenderer->alive = 0;

    if (tileRenderer->magic == ROXY_MAGIC) {
        tileRenderer->magic = 0; // Poison the magic cookie
    }

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
    // Validate subsystem pointers up front
    if (!pd || !pd->lua || !pd->graphics || !pd->system) return 0;

    const int argumentCount = pd->lua->getArgCount();
    if (argumentCount < 12) {
        pd->system->logToConsole("RoxyTileRendererC.new: expected >= 12 args, got %d", argumentCount);
        return 0;
    }

    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd_alloc(sizeof(RoxyTileRendererC));
    if (!tileRenderer) return 0; // Do not call roxy_valid before initialization
    roxy_memset(tileRenderer, 0, sizeof(*tileRenderer));
    ROXY_LABEL(tileRenderer, "RoxyTileRendererC");
    tileRenderer->magic = ROXY_MAGIC; // Initialize magic cookie
    tileRenderer->alive = 1;          // Mark as alive

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

    // Validate map size to avoid overflow on multiplication
    const int mw = tileRenderer->mapWidth;
    const int mh = tileRenderer->mapHeight;
    if (mw <= 0 || mh <= 0 || mw > INT_MAX / mh) {
        pd->system->logToConsole("RoxyTileRendererC.new: invalid map size %d x %d", mw, mh);
        pd_free(tileRenderer);
        return 0;
    }

    // Validate tile dimensions to prevent division-by-zero
    if (tileRenderer->tileWidth <= 0 || tileRenderer->tileHeight <= 0 ||
        tileRenderer->halfTileWidth <= 0 || tileRenderer->halfTileHeight <= 0) {
        pd->system->logToConsole("RoxyTileRendererC.new: invalid tile dimensions (tileWidth=%d, tileHeight=%d, halfTileWidth=%d, halfTileHeight=%d)",
                                 tileRenderer->tileWidth, tileRenderer->tileHeight,
                                 tileRenderer->halfTileWidth, tileRenderer->halfTileHeight);
        pd_free(tileRenderer);
        return 0;
    }

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
    if (tileRenderer->imageCount < 0) tileRenderer->imageCount = 0; // Sanitize

    // Precompute draw offsets with overflow guard
    if (tileRenderer->imageCount < 0) tileRenderer->imageCount = 0;
    size_t countWithZero = (size_t)tileRenderer->imageCount + 1;
    if (countWithZero > SIZE_MAX / sizeof(int16_t)) {
        pd->system->logToConsole("RoxyTileRendererC.new: offset array size overflow");
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }

    tileRenderer->offsetX = (int16_t*)pd_alloc(countWithZero * sizeof(int16_t));
    if (tileRenderer->offsetX) ROXY_LABEL(tileRenderer->offsetX, "RoxyTileRendererC.offsetX");

    tileRenderer->offsetY = (int16_t*)pd_alloc(countWithZero * sizeof(int16_t));
    if (tileRenderer->offsetY) ROXY_LABEL(tileRenderer->offsetY, "RoxyTileRendererC.offsetY");

    if (!tileRenderer->offsetX || !tileRenderer->offsetY) {
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }

    tileRenderer->offsetX[0] = 0;
    tileRenderer->offsetY[0] = 0;

    for (int i = 1; i <= tileRenderer->imageCount; ++i) {
        // Convert 1-based tile index to 0-based bitmap table index
        const int bitmapIndex = i - 1;
        LCDBitmap* cell = pd->graphics->getTableBitmap(tileRenderer->imageTable, bitmapIndex);
        if (!cell) {
            tileRenderer->offsetX[i] = 0;
            tileRenderer->offsetY[i] = 0;
            continue;
        }
        int imageWidth = 0, imageHeight = 0;
        pd->graphics->getBitmapData(cell, &imageWidth, &imageHeight, NULL, NULL, NULL);
        const int16_t offsetX = (int16_t)((tileRenderer->tileWidth  - imageWidth) / 2);
        const int16_t offsetY = (int16_t)((tileRenderer->tileHeight - imageHeight));
        tileRenderer->offsetX[i] = offsetX;
        tileRenderer->offsetY[i] = offsetY;
    }

    // Tiles blob (optional) with overflow guard
    const int tilesCount = mw * mh;
    if ((size_t)tilesCount > SIZE_MAX / sizeof(int32_t)) {
        pd->system->logToConsole("RoxyTileRendererC.new: tiles size overflow");
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }
    tileRenderer->tiles = (int32_t*)pd_alloc(sizeof(int32_t) * tilesCount);
    if (!tileRenderer->tiles) {
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }
    roxy_memset(tileRenderer->tiles, 0, sizeof(int32_t) * tilesCount);
    ROXY_LABEL(tileRenderer->tiles, "RoxyTileRendererC.tiles");

    if (argumentCount >= 13 && !pd->lua->argIsNil(13)) {
        size_t bytesLength = 0;
        const char* bytes = pd->lua->getArgBytes(13, &bytesLength);
        if (bytes && bytesLength > 0) {
            if ((int)bytesLength == tilesCount * 2) {
                for (int i = 0; i < tilesCount; ++i) {
                    uint16_t value = ((const uint8_t*)bytes)[2*i] | (((const uint8_t*)bytes)[2*i + 1] << 8);
                    int v = (int)value;
                    // Sanitize tile value to avoid out-of-range imagetable lookups
                    if (v < 0 || v > tileRenderer->imageCount) v = 0;
                    tileRenderer->tiles[i] = v;
                }
                tileRenderer->tilesCountBytes = (int)bytesLength;
            } else if ((int)bytesLength == tilesCount * 4) {
                for (int i = 0; i < tilesCount; ++i) {
                    const uint8_t* p = (const uint8_t*)bytes + 4*i;
                    int v = (int)(p[0] | (p[1]<<8) | (p[2]<<16) | (p[3]<<24));
                    // Sanitize tile value
                    if (v < 0 || v > tileRenderer->imageCount) v = 0;
                    tileRenderer->tiles[i] = v;
                }
                tileRenderer->tilesCountBytes = (int)bytesLength;
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
    // Correct condition; free only if non-null
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
    if (!roxy_valid(tileRenderer)) return 0;

    size_t bytesLength = 0;
    const char* bytes = pd->lua->getArgBytes(2, &bytesLength);
    if (!bytes || bytesLength == 0) return 0;

    const int tilesCount = tileRenderer->mapWidth * tileRenderer->mapHeight;
    if ((int)bytesLength != tilesCount * 2 && (int)bytesLength != tilesCount * 4) {
        pd->system->logToConsole("RoxyTileRendererC.updateTilesBytes: bad size %d (expected %d or %d)",
                                 (int)bytesLength, tilesCount*2, tilesCount*4);
        return 0;
    }

    if (!tileRenderer->tiles) {
        if ((size_t)tilesCount > SIZE_MAX / sizeof(int32_t)) {
            pd->system->logToConsole("RoxyTileRendererC.updateTilesBytes: tiles size overflow");
            return 0;
        }
        tileRenderer->tiles = (int32_t*)pd_alloc(sizeof(int32_t) * tilesCount);
        if (!tileRenderer->tiles) return 0;
        ROXY_LABEL(tileRenderer->tiles, "RoxyTileRendererC.tiles");
    }

    if ((int)bytesLength == tilesCount * 2) {
        for (int i = 0; i < tilesCount; ++i) {
            uint16_t value = ((const uint8_t*)bytes)[2*i] | (((const uint8_t*)bytes)[2*i + 1] << 8);
            int v = (int)value;
            // Sanitize tile value
            if (v < 0 || v > tileRenderer->imageCount) v = 0;
            tileRenderer->tiles[i] = v;
        }
        tileRenderer->tilesCountBytes = (int)bytesLength;
    } else {
        for (int i = 0; i < tilesCount; ++i) {
            const uint8_t* p = (const uint8_t*)bytes + 4*i;
            int v = (int)(p[0] | (p[1]<<8) | (p[2]<<16) | (p[3]<<24));
            // Sanitize tile value
            if (v < 0 || v > tileRenderer->imageCount) v = 0;
            tileRenderer->tiles[i] = v;
        }
        tileRenderer->tilesCountBytes = (int)bytesLength;
    }
    return 0;
}

// ! Set Tile At
// lua: self:setTileAt(x, y, tileIndex) -- 1-based x/y like Lua
static int roxy_tileRenderer_setTileAt(lua_State* L)
{
    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd->lua->getArgObject(1, "RoxyTileRendererC", NULL);
    if (!roxy_valid(tileRenderer) || !tileRenderer->tiles) return 0;

    int x = pd->lua->getArgInt(2);
    int y = pd->lua->getArgInt(3);
    int tileIndex = pd->lua->getArgInt(4);

    x = roxy_math_clampi(x, 1, tileRenderer->mapWidth);
    y = roxy_math_clampi(y, 1, tileRenderer->mapHeight);

    // Sanitize tileIndex to prevent OOB imagetable lookups
    if (tileIndex < 0 || tileIndex > tileRenderer->imageCount) tileIndex = 0;

    tileRenderer->tiles[indexFromRowColumn(tileRenderer, x-1, y-1)] = tileIndex;
    return 0;
}

// ! Draw Cell
// core draw for a single tile (shared)
static inline void drawCell(const RoxyTileRendererC* tileRenderer, int tileIndex, int sx, int sy)
{
    // Guard tileRenderer and validate tileIndex range
    if (!tileRenderer || tileIndex <= 0 || tileIndex > tileRenderer->imageCount) return;
    // Extra safety
    if (!pd || !pd->graphics || !tileRenderer->imageTable) return;

    // Convert 1-based tile index to 0-based bitmap table index
    const int bitmapIndex = tileIndex - 1;
    LCDBitmap* cell = pd->graphics->getTableBitmap(tileRenderer->imageTable, bitmapIndex);
    if (!cell) return;

    const int dx = sx + safeOffsetX(tileRenderer, tileIndex);
    const int dy = sy + safeOffsetY(tileRenderer, tileIndex);

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
    if (!roxy_valid(tileRenderer) || !tileRenderer->tiles) return 0;
    if (!pd || !pd->graphics) return 0;

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
    if (!roxy_valid(tileRenderer) || !tileRenderer->tiles) return 0;
    if (!pd || !pd->graphics) return 0;

    LCDBitmap* targetBitmap = pd->lua->getBitmap(2); // May be NULL
    const int offsetX = pd->lua->getArgInt(3);
    const int offsetY = pd->lua->getArgInt(4);
    const int bufferWidth = pd->lua->getArgInt(5);
    const int bufferHeight = pd->lua->getArgInt(6);
    if (bufferWidth <= 0 || bufferHeight <= 0) return 0;

    // Defensive check to prevent division-by-zero
    if (tileRenderer->tileWidth <= 0 || tileRenderer->halfTileHeight <= 0 ||
        tileRenderer->halfTileWidth <= 0) {
        pd->system->logToConsole("RoxyTileRendererC.renderToBuffer: invalid tile dimensions, cannot render");
        return 0;
    }

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
            if (minColumnZeroBased > maxColumnZeroBased) continue; // Handle negative-length window

            int drawX = baseX + minColumnZeroBased * tileRenderer->tileWidth;
            int tileIndex = rowZeroBased * tileRenderer->mapWidth + minColumnZeroBased;
            for (int columnZeroBased = minColumnZeroBased; columnZeroBased <= maxColumnZeroBased; ++columnZeroBased, ++tileIndex) {
                const int currentTileIndex = tileRenderer->tiles[tileIndex];
                if (currentTileIndex > 0) {
                    // Ensure index is within imagetable range before touching graphics
                    if (currentTileIndex <= tileRenderer->imageCount) {
                        const int dx = drawX + safeOffsetX(tileRenderer, currentTileIndex);
                        const int dy = baseY + safeOffsetY(tileRenderer, currentTileIndex);
                        if (dx < bufferWidth && dy < bufferHeight && dx > -tileRenderer->tileWidth && dy > -tileRenderer->tileHeight) {
                            // Convert 1-based tile index to 0-based bitmap table index
                            const int bitmapIndex = currentTileIndex - 1;
                            LCDBitmap* cell = pd->graphics->getTableBitmap(tileRenderer->imageTable, bitmapIndex);
                            if (cell) pd->graphics->drawBitmap(cell, dx, dy, kBitmapUnflipped);
                        }
                    }
                }
                drawX += tileRenderer->tileWidth;
            }
        }
    } else {
        // Isometric
        // Conservative world bounds - these are broad but safe for a stub
        const int overdrawRows = (int)ceilf(fmaxf(0.f, (float)(tileRenderer->maxImageHeight - tileRenderer->tileHeight)) / fmaxf(1.f, (float)tileRenderer->halfTileHeight)) + 1;

        const int minColumnZeroBased = roxy_math_clampi(-(bufferWidth / tileRenderer->halfTileWidth) - overdrawRows, 0, tileRenderer->mapWidth  - 1);
        const int maxColumnZeroBased = roxy_math_clampi((bufferWidth / tileRenderer->halfTileWidth) + overdrawRows, 0, tileRenderer->mapWidth  - 1);
        const int minRowZeroBased    = roxy_math_clampi(-(bufferHeight / tileRenderer->halfTileHeight) - overdrawRows, 0, tileRenderer->mapHeight - 1);
        const int maxRowZeroBased    = roxy_math_clampi((bufferHeight / tileRenderer->halfTileHeight) + overdrawRows, 0, tileRenderer->mapHeight - 1);

        for (int rowZeroBased = minRowZeroBased; rowZeroBased <= maxRowZeroBased; ++rowZeroBased) {
            for (int columnZeroBased = minColumnZeroBased; columnZeroBased <= maxColumnZeroBased; ++columnZeroBased) {
                const int tileIndex = indexFromRowColumn(tileRenderer, columnZeroBased, rowZeroBased);
                const int currentTileIndex = tileRenderer->tiles[tileIndex];
                if (currentTileIndex > 0 && currentTileIndex <= tileRenderer->imageCount) {
                    const float worldX = (float)columnZeroBased;
                    const float worldY = (float)rowZeroBased;
                    const int screenX = roxy_math_roundInt((worldX - worldY) * tileRenderer->halfTileWidth  + offsetX);
                    const int screenY = roxy_math_roundInt((worldX + worldY) * tileRenderer->halfTileHeight + offsetY);

                    const int drawX = screenX + safeOffsetX(tileRenderer, currentTileIndex);
                    const int drawY = screenY + safeOffsetY(tileRenderer, currentTileIndex);
                    if (drawX < bufferWidth && drawY < bufferHeight && drawX > -tileRenderer->tileWidth && drawY > -tileRenderer->tileHeight) {
                        // Convert 1-based tile index to 0-based bitmap table index
                        const int bitmapIndex = currentTileIndex - 1;
                        LCDBitmap* cell = pd->graphics->getTableBitmap(tileRenderer->imageTable, bitmapIndex);
                        if (cell) pd->graphics->drawBitmap(cell, drawX, drawY, kBitmapUnflipped);
                    }
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
    // Allow idempotent destroy; free only if non-null
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
