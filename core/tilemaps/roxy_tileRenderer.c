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

static int tileCountForRenderer(const RoxyTileRendererC* tileRenderer, size_t* outCount)
{
    if (!roxy_valid(tileRenderer) || !outCount) return 0;
    if (tileRenderer->mapWidth <= 0 || tileRenderer->mapHeight <= 0) return 0;
    if (tileRenderer->mapWidth > INT_MAX / tileRenderer->mapHeight) return 0;

    *outCount = (size_t)tileRenderer->mapWidth * (size_t)tileRenderer->mapHeight;
    return 1;
}

static inline void recordTilesPayloadBytes(RoxyTileRendererC* tileRenderer, size_t bytesLength)
{
    tileRenderer->tilesCountBytes = bytesLength > (size_t)INT_MAX ? INT_MAX : (int)bytesLength;
}

static inline int sanitizeTileValue(const RoxyTileRendererC* tileRenderer, int value)
{
    if (value < 0 || value > tileRenderer->imageCount) return 0;
    return value;
}

static int ensureTilesAllocated(RoxyTileRendererC* tileRenderer, int zeroFill)
{
    if (!roxy_valid(tileRenderer)) return 0;
    if (tileRenderer->tiles) return 1;

    size_t tilesCount = 0;
    if (!tileCountForRenderer(tileRenderer, &tilesCount) || tilesCount > SIZE_MAX / sizeof(int32_t)) {
        pd->system->logToConsole("RoxyTileRendererC: tiles size overflow");
        return 0;
    }

    tileRenderer->tiles = (int32_t*)pd_alloc(sizeof(int32_t) * tilesCount);
    if (!tileRenderer->tiles) return 0;
    ROXY_LABEL(tileRenderer->tiles, "RoxyTileRendererC.tiles");

    if (zeroFill) {
        roxy_memset(tileRenderer->tiles, 0, sizeof(int32_t) * tilesCount);
    }

    return 1;
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

static inline int isoRowNeedsFullProjection(float start, int step, int count)
{
    // Integer-step incremental rounding only differs when a negative .5 row
    // crosses into positive coordinates, because roundf rounds halves away from zero.
    if (count <= 1 || step <= 0) return 0;

    const float end = start + (float)step * (float)(count - 1);
    if (start >= 0.f || end <= 0.f) return 0;

    const float fraction = start - floorf(start);
    return fabsf(fraction - 0.5f) <= 0.000001f;
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

    if (tileRenderer->images) {
        pd_free(tileRenderer->images);
        tileRenderer->images = NULL;
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
    if (!tileRenderer->imageTableUserData) {
        pd->system->logToConsole("RoxyTileRendererC.new: failed to retain imagetable userdata");
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }

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
    if (countWithZero > SIZE_MAX / sizeof(*tileRenderer->images)) {
        pd->system->logToConsole("RoxyTileRendererC.new: image pointer array size overflow");
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }

    tileRenderer->images = (LCDBitmap**)pd_alloc(countWithZero * sizeof(*tileRenderer->images));
    if (tileRenderer->images) ROXY_LABEL(tileRenderer->images, "RoxyTileRendererC.images");

    tileRenderer->offsetX = (int16_t*)pd_alloc(countWithZero * sizeof(int16_t));
    if (tileRenderer->offsetX) ROXY_LABEL(tileRenderer->offsetX, "RoxyTileRendererC.offsetX");

    tileRenderer->offsetY = (int16_t*)pd_alloc(countWithZero * sizeof(int16_t));
    if (tileRenderer->offsetY) ROXY_LABEL(tileRenderer->offsetY, "RoxyTileRendererC.offsetY");

    if (!tileRenderer->images || !tileRenderer->offsetX || !tileRenderer->offsetY) {
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }

    tileRenderer->images[0] = NULL;
    tileRenderer->offsetX[0] = 0;
    tileRenderer->offsetY[0] = 0;

    for (int i = 1; i <= tileRenderer->imageCount; ++i) {
        // Convert 1-based tile index to 0-based bitmap table index
        const int bitmapIndex = i - 1;
        LCDBitmap* cell = pd->graphics->getTableBitmap(tileRenderer->imageTable, bitmapIndex);
        tileRenderer->images[i] = cell;
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

    // Tiles blob (optional) with overflow guard. Without an initial blob, tile
    // memory is allocated lazily by the first native sync.
    const size_t tilesCount = (size_t)mw * (size_t)mh;
    if (tilesCount > SIZE_MAX / sizeof(int32_t)) {
        pd->system->logToConsole("RoxyTileRendererC.new: tiles size overflow");
        roxy_tileRenderer_free(tileRenderer);
        pd_free(tileRenderer);
        return 0;
    }
    const size_t tilesCountBytes16 = tilesCount * 2;
    const size_t tilesCountBytes32 = tilesCount * 4;

    if (argumentCount >= 13 && !pd->lua->argIsNil(13)) {
        size_t bytesLength = 0;
        const char* bytes = pd->lua->getArgBytes(13, &bytesLength);
        if (bytes && bytesLength > 0) {
            if (bytesLength == tilesCountBytes16) {
                if (!ensureTilesAllocated(tileRenderer, 0)) {
                    roxy_tileRenderer_free(tileRenderer);
                    pd_free(tileRenderer);
                    return 0;
                }
                for (size_t i = 0; i < tilesCount; ++i) {
                    uint16_t value = ((const uint8_t*)bytes)[2*i] | (((const uint8_t*)bytes)[2*i + 1] << 8);
                    int v = (int)value;
                    tileRenderer->tiles[i] = sanitizeTileValue(tileRenderer, v);
                }
                recordTilesPayloadBytes(tileRenderer, bytesLength);
            } else if (bytesLength == tilesCountBytes32) {
                if (!ensureTilesAllocated(tileRenderer, 0)) {
                    roxy_tileRenderer_free(tileRenderer);
                    pd_free(tileRenderer);
                    return 0;
                }
                for (size_t i = 0; i < tilesCount; ++i) {
                    const uint8_t* p = (const uint8_t*)bytes + 4*i;
                    uint32_t raw = ((uint32_t)p[0]) | (((uint32_t)p[1]) << 8) | (((uint32_t)p[2]) << 16) | (((uint32_t)p[3]) << 24);
                    int v = (int)raw;
                    tileRenderer->tiles[i] = sanitizeTileValue(tileRenderer, v);
                }
                recordTilesPayloadBytes(tileRenderer, bytesLength);
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

    size_t tilesCount = 0;
    if (!tileCountForRenderer(tileRenderer, &tilesCount) || tilesCount > SIZE_MAX / 4) {
        pd->system->logToConsole("RoxyTileRendererC.updateTilesBytes: tiles size overflow");
        return 0;
    }

    const size_t tilesCountBytes16 = tilesCount * 2;
    const size_t tilesCountBytes32 = tilesCount * 4;
    if (bytesLength != tilesCountBytes16 && bytesLength != tilesCountBytes32) {
        pd->system->logToConsole("RoxyTileRendererC.updateTilesBytes: bad size %lu (expected %lu or %lu)",
                                 (unsigned long)bytesLength,
                                 (unsigned long)tilesCountBytes16,
                                 (unsigned long)tilesCountBytes32);
        return 0;
    }

    if (!ensureTilesAllocated(tileRenderer, 0)) return 0;

    if (bytesLength == tilesCountBytes16) {
        for (size_t i = 0; i < tilesCount; ++i) {
            uint16_t value = ((const uint8_t*)bytes)[2*i] | (((const uint8_t*)bytes)[2*i + 1] << 8);
            int v = (int)value;
            tileRenderer->tiles[i] = sanitizeTileValue(tileRenderer, v);
        }
        recordTilesPayloadBytes(tileRenderer, bytesLength);
    } else {
        for (size_t i = 0; i < tilesCount; ++i) {
            const uint8_t* p = (const uint8_t*)bytes + 4*i;
            uint32_t raw = ((uint32_t)p[0]) | (((uint32_t)p[1]) << 8) | (((uint32_t)p[2]) << 16) | (((uint32_t)p[3]) << 24);
            int v = (int)raw;
            tileRenderer->tiles[i] = sanitizeTileValue(tileRenderer, v);
        }
        recordTilesPayloadBytes(tileRenderer, bytesLength);
    }
    return 0;
}

// ! Update Tiles Bytes Range
// lua: ok = self:updateTilesBytesRange(bytes, startIndex, count)
// startIndex is 1-based row-major. count == 0 is a no-op.
static int roxy_tileRenderer_updateTilesBytesRange(lua_State* L)
{
    RoxyTileRendererC* tileRenderer = (RoxyTileRendererC*)pd->lua->getArgObject(1, "RoxyTileRendererC", NULL);
    if (!roxy_valid(tileRenderer)) {
        pd->lua->pushBool(0);
        return 1;
    }

    size_t tilesCount = 0;
    if (!tileCountForRenderer(tileRenderer, &tilesCount)) {
        pd->lua->pushBool(0);
        return 1;
    }

    const int startIndex = pd->lua->getArgInt(3);
    const int count = pd->lua->getArgInt(4);

    if (count < 0 || startIndex < 1) {
        pd->lua->pushBool(0);
        return 1;
    }

    if (count == 0) {
        pd->lua->pushBool((size_t)startIndex <= tilesCount + 1);
        return 1;
    }

    const size_t totalCells = tilesCount;
    const size_t rangeStart = (size_t)startIndex;
    const size_t rangeCount = (size_t)count;
    if (rangeCount > totalCells || rangeStart > totalCells || rangeCount > totalCells - rangeStart + 1) {
        pd->lua->pushBool(0);
        return 1;
    }

    size_t bytesLength = 0;
    const char* bytes = pd->lua->getArgBytes(2, &bytesLength);
    if (!bytes) {
        pd->lua->pushBool(0);
        return 1;
    }

    if (rangeCount > SIZE_MAX / 4) {
        pd->lua->pushBool(0);
        return 1;
    }
    const size_t bytes16 = rangeCount * 2;
    const size_t bytes32 = rangeCount * 4;
    const int payloadWidth = (bytesLength == bytes16) ? 2 : ((bytesLength == bytes32) ? 4 : 0);
    if (payloadWidth == 0) {
        pd->lua->pushBool(0);
        return 1;
    }

    if (!ensureTilesAllocated(tileRenderer, 1)) {
        pd->lua->pushBool(0);
        return 1;
    }

    const size_t destinationStart = rangeStart - 1;
    if (payloadWidth == 2) {
        for (size_t i = 0; i < rangeCount; ++i) {
            uint16_t value = ((const uint8_t*)bytes)[2*i] | (((const uint8_t*)bytes)[2*i + 1] << 8);
            int v = (int)value;
            tileRenderer->tiles[destinationStart + i] = sanitizeTileValue(tileRenderer, v);
        }
    } else {
        for (size_t i = 0; i < rangeCount; ++i) {
            const uint8_t* p = (const uint8_t*)bytes + 4*i;
            uint32_t raw = ((uint32_t)p[0]) | (((uint32_t)p[1]) << 8) | (((uint32_t)p[2]) << 16) | (((uint32_t)p[3]) << 24);
            int v = (int)raw;
            tileRenderer->tiles[destinationStart + i] = sanitizeTileValue(tileRenderer, v);
        }
    }

    recordTilesPayloadBytes(tileRenderer, bytesLength);
    pd->lua->pushBool(1);
    return 1;
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

    // Sanitize tileIndex to prevent out-of-bounds image table lookups
    if (tileIndex < 0 || tileIndex > tileRenderer->imageCount) tileIndex = 0;

    tileRenderer->tiles[indexFromRowColumn(tileRenderer, x-1, y-1)] = tileIndex;
    return 0;
}

// ! Draw Cell Unchecked
// Core draw for a range-checked tile using cached renderer fields.
static inline void drawCellUnchecked(LCDBitmap* const* images, const int16_t* offsetX, const int16_t* offsetY, int tileIndex, int sx, int sy)
{
    LCDBitmap* cell = images[tileIndex];
    if (!cell) return;

    const int dx = sx + offsetX[tileIndex];
    const int dy = sy + offsetY[tileIndex];

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

    const int mapWidth = tileRenderer->mapWidth;
    const int mapHeight = tileRenderer->mapHeight;
    const int tileWidth = tileRenderer->tileWidth;
    const int halfTileWidth = tileRenderer->halfTileWidth;
    const int halfTileHeight = tileRenderer->halfTileHeight;
    const int imageCount = tileRenderer->imageCount;
    const int32_t* tiles = tileRenderer->tiles;
    LCDBitmap* const* images = tileRenderer->images;
    const int16_t* offsetX = tileRenderer->offsetX;
    const int16_t* offsetY = tileRenderer->offsetY;
    if (!images || !offsetX || !offsetY) return 0;

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

    minRow = roxy_math_clampi(minRow, 1, mapHeight);
    maxRow = roxy_math_clampi(maxRow, 1, mapHeight);
    minColumn = roxy_math_clampi(minColumn, 1, mapWidth);
    maxColumn = roxy_math_clampi(maxColumn, 1, mapWidth);
    if (minRow > maxRow || minColumn > maxColumn) return 0;

    const float pivotAdjustX = parallaxOriginX * (1.f - parallaxX);
    const float pivotAdjustY = parallaxOriginY * (1.f - parallaxY);

    if (!tileRenderer->isIsometric) {
        // staggered-y (rows step by halfTileHeight, X steps full tileWidth + row shift)
        for (int tileY = minRow; tileY <= maxRow; ++tileY) {
            const int rowZeroBased = tileY - 1;
            const int rowShift = rowShiftX_for_row0(tileRenderer, rowZeroBased);

            const int baseX = roxy_math_roundInt(originX + rowShift + pivotAdjustX - cameraX * parallaxX);
            const int baseY = roxy_math_roundInt(originY + rowZeroBased * halfTileHeight + pivotAdjustY - cameraY * parallaxY);

            int screenX = baseX + (minColumn - 1) * tileWidth;
            const int rowIndexBase = rowZeroBased * mapWidth + (minColumn - 1);

            for (int tileX = minColumn, tileIndex = rowIndexBase; tileX <= maxColumn; ++tileX, ++tileIndex) {
                const int currentTileIndex = tiles[tileIndex];
                if (currentTileIndex > 0 && currentTileIndex <= imageCount) {
                    drawCellUnchecked(images, offsetX, offsetY, currentTileIndex, screenX, baseY);
                }
                screenX += tileWidth;
            }
        }
    } else {
        // Isometric
        const int minColumnZeroBased = minColumn - 1;
        const int columnCount = maxColumn - minColumn + 1;
        for (int tileY = minRow; tileY <= maxRow; ++tileY) {
            const int rowZeroBased = tileY - 1;
            const int rowBaseIndex = rowZeroBased * mapWidth + minColumnZeroBased;
            const float worldX = (float)minColumnZeroBased;
            const float worldY = (float)rowZeroBased;

            const float rowStartX = originX + (worldX - worldY) * halfTileWidth + pivotAdjustX - cameraX * parallaxX;
            const float rowStartY = originY + (worldX + worldY) * halfTileHeight + pivotAdjustY - cameraY * parallaxY;

            if (isoRowNeedsFullProjection(rowStartX, halfTileWidth, columnCount) ||
                isoRowNeedsFullProjection(rowStartY, halfTileHeight, columnCount)) {
                for (int tileX = minColumn, tileIndex = rowBaseIndex; tileX <= maxColumn; ++tileX, ++tileIndex) {
                    const int columnZeroBased = tileX - 1;
                    const float currentWorldX = (float)columnZeroBased;
                    const int isoX = roxy_math_roundInt(originX + (currentWorldX - worldY) * halfTileWidth + pivotAdjustX - cameraX * parallaxX);
                    const int isoY = roxy_math_roundInt(originY + (currentWorldX + worldY) * halfTileHeight + pivotAdjustY - cameraY * parallaxY);

                    const int currentTileIndex = tiles[tileIndex];
                    if (currentTileIndex > 0 && currentTileIndex <= imageCount) {
                        drawCellUnchecked(images, offsetX, offsetY, currentTileIndex, isoX, isoY);
                    }
                }
                continue;
            }

            int screenX = roxy_math_roundInt(rowStartX);
            int screenY = roxy_math_roundInt(rowStartY);

            for (int tileX = minColumn, tileIndex = rowBaseIndex; tileX <= maxColumn; ++tileX, ++tileIndex) {
                const int currentTileIndex = tiles[tileIndex];
                if (currentTileIndex > 0 && currentTileIndex <= imageCount) {
                    drawCellUnchecked(images, offsetX, offsetY, currentTileIndex, screenX, screenY);
                }
                screenX += halfTileWidth;
                screenY += halfTileHeight;
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

    const int mapWidth = tileRenderer->mapWidth;
    const int mapHeight = tileRenderer->mapHeight;
    const int tileWidth = tileRenderer->tileWidth;
    const int tileHeight = tileRenderer->tileHeight;
    const int halfTileWidth = tileRenderer->halfTileWidth;
    const int halfTileHeight = tileRenderer->halfTileHeight;
    const int maxImageHeight = tileRenderer->maxImageHeight;
    const int imageCount = tileRenderer->imageCount;
    const int32_t* tiles = tileRenderer->tiles;
    LCDBitmap* const* images = tileRenderer->images;
    const int16_t* offsetXTable = tileRenderer->offsetX;
    const int16_t* offsetYTable = tileRenderer->offsetY;
    if (!images || !offsetXTable || !offsetYTable) return 0;

    LCDBitmap* targetBitmap = pd->lua->getBitmap(2); // May be NULL
    const int offsetX = pd->lua->getArgInt(3);
    const int offsetY = pd->lua->getArgInt(4);
    const int bufferWidth = pd->lua->getArgInt(5);
    const int bufferHeight = pd->lua->getArgInt(6);
    if (bufferWidth <= 0 || bufferHeight <= 0) return 0;

    // Defensive check to prevent division-by-zero
    if (tileWidth <= 0 || halfTileHeight <= 0 || halfTileWidth <= 0) {
        pd->system->logToConsole("RoxyTileRendererC.renderToBuffer: invalid tile dimensions, cannot render");
        return 0;
    }

    const int cullHeight = (maxImageHeight > tileHeight) ? maxImageHeight : tileHeight;

    int contextPushed = 0;
    if (targetBitmap) {
        pd->graphics->pushContext(targetBitmap);
        contextPushed = 1;
    }

    // Compute conservative row/column bounds
    if (!tileRenderer->isIsometric) {
        // staggered-y
        const int overdrawRows = (int)ceilf(fmaxf(0.f, (float)(maxImageHeight - tileHeight)) /
                                          fmaxf(1.f, (float)halfTileHeight)) + 1;

        int minRowZeroBased = (int)floorf((float)(-offsetY - maxImageHeight) /
                                        (float)halfTileHeight) - 1 - overdrawRows;
        int maxRowZeroBased = (int)ceilf ((float)(bufferHeight - offsetY) /
                                        (float)halfTileHeight) + 1 + overdrawRows;
        minRowZeroBased = roxy_math_clampi(minRowZeroBased, 0, mapHeight - 1);
        maxRowZeroBased = roxy_math_clampi(maxRowZeroBased, 0, mapHeight - 1);

        for (int rowZeroBased = minRowZeroBased; rowZeroBased <= maxRowZeroBased; ++rowZeroBased) {
            const int baseX = rowShiftX_for_row0(tileRenderer, rowZeroBased) + offsetX;
            const int baseY = rowZeroBased * halfTileHeight + offsetY;

            int minColumnZeroBased = (int)floorf((float)(-tileWidth - baseX) / (float)tileWidth) - 1;
            int maxColumnZeroBased = (int)floorf((float)(bufferWidth - 1 - baseX) / (float)tileWidth) + 1;
            minColumnZeroBased = roxy_math_clampi(minColumnZeroBased, 0, mapWidth - 1);
            maxColumnZeroBased = roxy_math_clampi(maxColumnZeroBased, 0, mapWidth - 1);
            if (minColumnZeroBased > maxColumnZeroBased) continue; // Handle negative-length window

            int drawX = baseX + minColumnZeroBased * tileWidth;
            int tileIndex = rowZeroBased * mapWidth + minColumnZeroBased;
            for (int columnZeroBased = minColumnZeroBased; columnZeroBased <= maxColumnZeroBased; ++columnZeroBased, ++tileIndex) {
                const int currentTileIndex = tiles[tileIndex];
                if (currentTileIndex > 0) {
                    // Ensure index is within image table range before touching graphics
                    if (currentTileIndex <= imageCount) {
                        const int dx = drawX + offsetXTable[currentTileIndex];
                        const int dy = baseY + offsetYTable[currentTileIndex];
                        if (dx < bufferWidth && dy < bufferHeight && dx > -tileWidth && dy > -cullHeight) {
                            LCDBitmap* cell = images[currentTileIndex];
                            if (cell) pd->graphics->drawBitmap(cell, dx, dy, kBitmapUnflipped);
                        }
                    }
                }
                drawX += tileWidth;
            }
        }
    } else {
        // Isometric
        const float halfWidth = (float)halfTileWidth;
        const float halfHeight = (float)halfTileHeight;
        const float horizontalPadding = (float)tileWidth;
        const float verticalPadding = fmaxf(0.f, (float)(maxImageHeight - tileHeight));

        const float left = (float)(-offsetX) - horizontalPadding;
        const float right = (float)(bufferWidth - offsetX) + horizontalPadding;
        const float top = (float)(-offsetY) - verticalPadding;
        const float bottom = (float)(bufferHeight - offsetY) + verticalPadding;

        float minColumn = INFINITY;
        float maxColumn = -INFINITY;
        float minRow = INFINITY;
        float maxRow = -INFINITY;

        const float xs[4] = { left, right, left, right };
        const float ys[4] = { top, top, bottom, bottom };
        for (int i = 0; i < 4; ++i) {
            const float screenX = xs[i];
            const float screenY = ys[i];
            const float column = ((screenY / halfHeight) + (screenX / halfWidth)) * 0.5f;
            const float row = ((screenY / halfHeight) - (screenX / halfWidth)) * 0.5f;

            if (column < minColumn) minColumn = column;
            if (column > maxColumn) maxColumn = column;
            if (row < minRow) minRow = row;
            if (row > maxRow) maxRow = row;
        }

        const int minColumnZeroBased = roxy_math_clampi((int)floorf(minColumn) - 1, 0, mapWidth  - 1);
        const int maxColumnZeroBased = roxy_math_clampi((int)ceilf(maxColumn)  + 1, 0, mapWidth  - 1);
        const int minRowZeroBased    = roxy_math_clampi((int)floorf(minRow)    - 1, 0, mapHeight - 1);
        const int maxRowZeroBased    = roxy_math_clampi((int)ceilf(maxRow)     + 1, 0, mapHeight - 1);

        for (int rowZeroBased = minRowZeroBased; rowZeroBased <= maxRowZeroBased; ++rowZeroBased) {
            const int rowBaseIndex = rowZeroBased * mapWidth + minColumnZeroBased;
            const float worldX = (float)minColumnZeroBased;
            const float worldY = (float)rowZeroBased;

            int screenX = roxy_math_roundInt((worldX - worldY) * halfTileWidth  + offsetX);
            int screenY = roxy_math_roundInt((worldX + worldY) * halfTileHeight + offsetY);

            int tileIndex = rowBaseIndex;
            for (int columnZeroBased = minColumnZeroBased; columnZeroBased <= maxColumnZeroBased; ++columnZeroBased, ++tileIndex) {
                const int currentTileIndex = tiles[tileIndex];
                if (currentTileIndex > 0 && currentTileIndex <= imageCount) {
                    const int drawX = screenX + offsetXTable[currentTileIndex];
                    const int drawY = screenY + offsetYTable[currentTileIndex];
                    if (drawX < bufferWidth && drawY < bufferHeight && drawX > -tileWidth && drawY > -cullHeight) {
                        LCDBitmap* cell = images[currentTileIndex];
                        if (cell) pd->graphics->drawBitmap(cell, drawX, drawY, kBitmapUnflipped);
                    }
                }
                screenX += halfTileWidth;
                screenY += halfTileHeight;
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
    {    "updateTilesBytesRange",   roxy_tileRenderer_updateTilesBytesRange   },
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
