#ifndef ROXY_PARTICLES_H
#define ROXY_PARTICLES_H

#include "pd_api.h"

typedef enum {
    FRAME_STATIC = 0,
    FRAME_SEQUENTIAL = 1,
    FRAME_REVERSE = 2,
    FRAME_RANDOM = 3
} FrameMode;

typedef struct {
    float x, y;
    float vx, vy;
    float age, lifetime;
    float size;
    int   frame;
    float frameTimer;
    float frameRate;
    int   alive;
} RoxyParticle;

typedef struct {
    int maxCount;
    RoxyParticle *pool;
    LCDBitmapTable* imageTable;
    int frameCount;
    FrameMode frameMode;
    int staticFrame;
    int shouldLoop;
    float frameRate;
    uint8_t pattern[16];
    bool hasPattern;
} RoxyParticlesC;

void registerRoxyParticlesC(PlaydateAPI* pd);

#endif /* ROXY_PARTICLES_H */
