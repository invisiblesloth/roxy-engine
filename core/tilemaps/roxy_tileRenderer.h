#ifndef ROXY_TILERENDERER_H
#define ROXY_TILERENDERER_H

#include "pd_api.h"
#include <stdint.h>

typedef struct {
    // Projection / stagger configuration
    int isIsometric;            // 1 = isometric, 0 = staggered-y
    int staggerIndexOdd;        // staggered-y: 1 if "odd", 0 if "even"
    int staggerDirectionRight;  // staggered-y: 1 if "right", 0 if "left"

    // Map / layer geometry
    int mapWidth, mapHeight;            // Tiles
    int tileWidth, tileHeight;          // Pixels
    int halfTileWidth, halfTileHeight;  // Pixels
    int maxImageHeight;                 // Pixels (for tall art overdraw)

    // Assets
    LCDBitmapTable* imageTable;
    LuaUDObject*    imageTableUserData; // Retained UD to keep it alive
    int             imageCount;

    // Precomputed per-index offsets (1-based)
    int16_t* offsetX; // [imageCount + 1]
    int16_t* offsetY; // [imageCount + 1]

    // Tiles: copied into C memory for speed (row-major, 0-based)
    int32_t* tiles;           // Length = mapWidth*mapHeight
    int      tilesCountBytes; // Original byte size, for sanity/debug

    // Lifetime guard
    int alive;
} RoxyTileRendererC;

void registerRoxyTileRendererC(PlaydateAPI* playdate);

#endif /* ROXY_TILERENDERER_H */