// core/sprites/roxy_particles.c

#include "roxy_particles.h"
#include "../../utilities/roxy_math.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static PlaydateAPI* pd = NULL;

void roxy_particles_setPlaydateAPI(PlaydateAPI* playdate)
{
    pd = playdate;
}

// ----------------------------------------
// Helpers
// ----------------------------------------

static inline float rnd01(void)
{
    return ((float)rand()) / (float)RAND_MAX;
}

static inline float rand_range(float lo, float hi)
{
    return lo == hi ? lo : lo + rnd01() * (hi - lo);
}

static inline float deg_to_rad(float d)
{
    return d * (float)M_PI / 180.0f;
}

static void* pd_alloc(size_t sz)
{
    return pd->system->realloc(NULL, sz);
}

static void pd_free(void* ptr)
{
    pd->system->realloc(ptr, 0);
}

// ! Normalize Range
// Normalizes an angle range to determine min, max, and if it spans a full circle
static void normalizeRange(float a, float b, float* outA, float* outB, int* fullCircle)
{
    // Normalize angles to [0, 360)
    a = fmodf(a, 360.0f);
    if (a < 0) a += 360.0f;
    b = fmodf(b, 360.0f);
    if (b < 0) b += 360.0f;

    // Calculate the clockwise span from a to b
    float span;
    if (b >= a) {
        span = b - a;
    } else {
        span = b - a + 360.0f;
    }

    // Check if this represents a full circle (or nearly full circle)
    if (span >= 359.0f || fabsf(span - 360.0f) < 0.001f) {
        *outA = 0.0f;
        *outB = 360.0f;
        *fullCircle = 1;
        return;
    }

    *outA = a;
    *outB = b;
    *fullCircle = 0;
}

// ! Angle in Sweep
// Checks if an angle is within a sweep defined by min, max, and full circle flag
static int angle_in_sweep(float deg, float angMin, float angMax, int fullCircle)
{
    if (fullCircle) return 1;

    // Normalize the test angle to [0, 360)
    deg = fmodf(deg, 360.0f);
    if (deg < 0) deg += 360.0f;

    // Check if the range crosses the 0 deg boundary
    if (angMax < angMin) {
        // Range crosses 0 deg (e.g., angMin=180.5, angMax=179.5)
        // Angle is in range if it's >= angMin OR <= angMax
        return (deg >= angMin || deg <= angMax);
    } else {
        // Normal range (e.g., angMin=45, angMax=135)
        // Angle is in range if it's between angMin and angMax
        return (deg >= angMin && deg <= angMax);
    }
}

// ----------------------------------------
//  Object Lifecycle
// ----------------------------------------

// ! New Particles Pool
// Creates a new particle system with a specified maximum particle count
RoxyParticlesC* roxy_particles_new(int maxCount, LCDBitmapTable* tbl, int frameCount, FrameMode frameMode, int staticFrame, int shouldLoop, float initFrameRate)

{
    if (!pd) return NULL;
    if (maxCount <= 0) maxCount = 1;

    RoxyParticlesC* ps = (RoxyParticlesC*)pd_alloc(sizeof(RoxyParticlesC));
    if (!ps) return NULL;
    memset(ps, 0, sizeof(RoxyParticlesC));

    ps->maxCount = maxCount;
    ps->pool = (RoxyParticle*)pd_alloc(sizeof(RoxyParticle) * (size_t)maxCount);
    if (!ps->pool) {
        pd_free(ps);
        return NULL;
    }
    memset(ps->pool, 0, sizeof(RoxyParticle) * (size_t)maxCount);
    if (tbl) {
        ps->imageTable  = tbl;
        ps->frameCount  = frameCount;
        ps->frameMode   = frameMode;
        ps->staticFrame = staticFrame;
        ps->shouldLoop  = shouldLoop;
        ps->frameRate   = initFrameRate;
    } else {
        ps->imageTable  = NULL;
        ps->frameCount  = 1;
        ps->frameMode   = FRAME_SEQUENTIAL;
        ps->staticFrame = 0;
        ps->shouldLoop  = 0;
        ps->frameRate   = initFrameRate;
    }

    return ps;
}

// ! Free Pool
// Frees the particle pool and sets the pointer to NULL to prevent double-free
static void roxy_particles_free_pool(RoxyParticlesC* ps)
{
    if (ps == NULL || ps->pool == NULL) // Already freed --> nothing to do
        return;

    void *pool = ps->pool;
    ps->pool = NULL; // Mark as gone

    pd_free(pool);
}

// ----------------------------------------
// Lua Class Methods
// ----------------------------------------

// ! New Object
// Lua constructor: Creates a new particle system object
int roxy_particles_newobject(lua_State* L)
{
    int maxCount        = pd->lua->getArgInt(1);
    LCDBitmapTable* tbl = pd->lua->getArgObject(2, "playdate.graphics.imagetable", NULL);
    int frameCount      = pd->lua->getArgInt(3);
    FrameMode frameMode = pd->lua->getArgInt(4);
    int staticFrame     = pd->lua->getArgInt(5);
    int shouldLoop      = pd->lua->getArgInt(6);
    float initFrameRate = pd->lua->getArgFloat(7);

    // Pass all six into roxy_particles_new
    RoxyParticlesC* ps = roxy_particles_new(
        maxCount,
        tbl,
        frameCount,
        frameMode,
        staticFrame,
        shouldLoop,
        initFrameRate
    );
    if (!ps) {
        pd->lua->pushNil();
        return 1;
    }

    pd->lua->pushObject(ps, "RoxyParticlesC", 1);
    return 1;
}

// ! Garbage Collection (__gc)
// Lua garbage collector: Cleans up the particle system
int roxy_particles_gc(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (ps) {
        roxy_particles_free_pool(ps);
        pd_free(ps);
    }
    return 0;
}

// ----------------------------------------
// Lua-Exposed Methods
// ----------------------------------------

// ! Set Pattern
// Args: 1 = ps, 2 = Lua string of length 8 or 16 (raw bytes)
int roxy_particles_setPattern_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps) return 0;

    size_t len = 0;
    const char* bytes = pd->lua->getArgBytes(2, &len);
    if (!bytes || (len != 8 && len != 16)) {
        ps->hasPattern = false;
        return 0;
    }

    // Copy fill & mask (mask defaults to opaque if only 8 bytes)
    memcpy(ps->pattern, bytes, len);
    if (len == 8) {
        memset(ps->pattern + 8, 0xFF, 8);
    }

    ps->hasPattern = true;
    return 0;
}

// ! Set Frame Rate
int roxy_particles_setFrameRate_l(lua_State* L)
{
  RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
  if (!ps) return 0;

  ps->frameRate = fmaxf(0.0f, pd->lua->getArgFloat(2));
  return 0;
}

// ! Set Image Table
// Sets the image table for particle rendering
// Args: 1=ps, 2=table or nil, 3=mode, 4=staticFrame (1-based), 5=loop flag
int roxy_particles_setImageTable_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps || !ps->pool) return 0;

    LCDBitmapTable* tbl = pd->lua->getArgObject(2, "playdate.graphics.imagetable", NULL);
    ps->imageTable = tbl;

    if (tbl) {
        // count frames (Lua imagetable is 1-based!)
        int count = 0;
        while (pd->graphics->getTableBitmap(tbl, count + 1)) ++count;
        ps->frameCount = count;

        // frameMode (already validated in Lua)
        ps->frameMode   = (FrameMode)pd->lua->getArgInt(3);

        // staticFrame: convert from Lua’s 1-based to C’s 0-based
        ps->staticFrame = pd->lua->getArgInt(4) - 1;

        // loop flag
        ps->shouldLoop  = pd->lua->getArgBool(5);
    }
    else {
        ps->frameCount  = 0;
        ps->frameMode   = FRAME_SEQUENTIAL;
        ps->staticFrame = 0;
        ps->shouldLoop  = false;
    }

    return 0;
}

// ! Spawn
// Spawns a new particle with specified properties
int roxy_particles_spawn_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps || !ps->pool) {
        pd->lua->pushBool(0);
        return 1;
    }

    float lifeMin = fmaxf(0.0f, pd->lua->getArgFloat(2));
    float lifeMax = fmaxf(0.0f, pd->lua->getArgFloat(3));
    float speedMin = pd->lua->getArgFloat(4);
    float speedMax = pd->lua->getArgFloat(5);
    float sizeMin = fmaxf(0.0f, pd->lua->getArgFloat(6));
    float sizeMax = fmaxf(0.0f, pd->lua->getArgFloat(7));
    float angMin = pd->lua->getArgFloat(8);
    float angMax = pd->lua->getArgFloat(9);
    float ex = pd->lua->getArgFloat(10);
    float ey = pd->lua->getArgFloat(11);

    int fullCircle = 0;
    float nAngMin, nAngMax;
    normalizeRange(angMin, angMax, &nAngMin, &nAngMax, &fullCircle);

    if (lifeMax <= 0.0f || sizeMax <= 0.0f) {
        pd->lua->pushBool(0);
        return 1;
    }

    // Find free slot
    int slot = -1;
    for (int i = 0; i < ps->maxCount; ++i) {
        if (!ps->pool[i].alive) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        pd->lua->pushBool(0);
        return 1;
    }

    // Grab & zero a fresh particle
    RoxyParticle* p = &ps->pool[slot];
    memset(p, 0, sizeof(RoxyParticle));
    p->alive    = 1;
    p->age      = 0.0f;
    p->lifetime = rand_range(lifeMin, lifeMax);

    if (ps->imageTable) {
        p->frameRate  = ps->frameRate;
        p->frameTimer = 0.0f;

        // Pick the starting frame based on mode
        switch (ps->frameMode) {
          case FRAME_STATIC:
            // StaticFrame is already 0-based
            p->frame = ps->staticFrame;
            break;
          case FRAME_REVERSE:
            p->frame = ps->frameCount - 1;
            break;
          case FRAME_RANDOM:
            p->frame = rand() % ps->frameCount;
            break;
          case FRAME_SEQUENTIAL:
          default:
            p->frame = 0;
            break;
        }
    }
    else {
        p->frame      = 0;
        p->frameRate  = 0.0f;
        p->frameTimer = 0.0f;
    }

    float theta;
    if (fullCircle) {
        theta = deg_to_rad(rnd01() * 360.0f);
    } else {
        theta = deg_to_rad(rand_range(nAngMin, nAngMax));
    }
    float speed = rand_range(speedMin, speedMax);

    p->vx   = speed * cosf(theta);
    p->vy   = speed * sinf(theta);
    p->x    = ex;
    p->y    = ey;
    p->size = rand_range(sizeMin, sizeMax);

    pd->lua->pushBool(1);
    return 1;
}

// ! Spawn Multiple
int roxy_particles_spawnMultiple_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps || !ps->pool) {
        pd->lua->pushBool(0);
        return 1;
    }

    int count = pd->lua->getArgInt(2);  // Missing count parameter!
    if (count <= 0) {
        pd->lua->pushBool(0);
        return 1;
    }

    float lifeMin = fmaxf(0.0f, pd->lua->getArgFloat(3));   // Shifted indices
    float lifeMax = fmaxf(0.0f, pd->lua->getArgFloat(4));
    float speedMin = pd->lua->getArgFloat(5);
    float speedMax = pd->lua->getArgFloat(6);
    float sizeMin = fmaxf(0.0f, pd->lua->getArgFloat(7));
    float sizeMax = fmaxf(0.0f, pd->lua->getArgFloat(8));
    float angMin = pd->lua->getArgFloat(9);
    float angMax = pd->lua->getArgFloat(10);
    float ex = pd->lua->getArgFloat(11);
    float ey = pd->lua->getArgFloat(12);

    // Handle the angle normalization
    int fullCircle = 0;
    float nAngMin, nAngMax;
    normalizeRange(angMin, angMax, &nAngMin, &nAngMax, &fullCircle);

    if (lifeMax <= 0.0f || sizeMax <= 0.0f) {
        pd->lua->pushInt(0);
        return 1;
    }

    // Pre-calculate ranges for efficiency
    float lifeRange = lifeMax - lifeMin;
    float speedRange = speedMax - speedMin;
    float sizeRange = sizeMax - sizeMin;
    float angleRange = nAngMax - nAngMin;  // Use normalized angles

    int spawned = 0;

    for (int i = 0; i < count; i++) {
        // Find free slot
        int slot = -1;
        for (int j = 0; j < ps->maxCount; ++j) {
            if (!ps->pool[j].alive) {
                slot = j;
                break;
            }
        }
        if (slot < 0) {
            break;  // No more free slots
        }

        // Initialize particle (same logic as original spawn)
        RoxyParticle* p = &ps->pool[slot];
        memset(p, 0, sizeof(RoxyParticle));
        p->alive = 1;
        p->age = 0.0f;
        p->lifetime = lifeMin + rnd01() * lifeRange;

        // Frame initialization (same logic as original spawn)
        if (ps->imageTable) {
            p->frameRate = ps->frameRate;
            p->frameTimer = 0.0f;

            switch (ps->frameMode) {
              case FRAME_STATIC:
                p->frame = ps->staticFrame;
                break;
              case FRAME_REVERSE:
                p->frame = ps->frameCount - 1;
                break;
              case FRAME_RANDOM:
                p->frame = rand() % ps->frameCount;
                break;
              case FRAME_SEQUENTIAL:
              default:
                p->frame = 0;
                break;
            }
        } else {
            p->frame = 0;
            p->frameRate = 0.0f;
            p->frameTimer = 0.0f;
        }

        // Angle and velocity calculation
        float theta;
        if (fullCircle) {
            theta = deg_to_rad(rnd01() * 360.0f);
        } else {
            theta = deg_to_rad(nAngMin + rnd01() * angleRange);
        }
        float speed = speedMin + rnd01() * speedRange;

        p->vx = speed * cosf(theta);
        p->vy = speed * sinf(theta);
        p->x = ex;
        p->y = ey;
        p->size = sizeMin + rnd01() * sizeRange;

        spawned++;
    }

    pd->lua->pushInt(spawned);
    return 1;
}

// ! Update
// Updates all active particles
int roxy_particles_update_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps || !ps->pool) {
        pd->lua->pushBool(0);
        return 1;
    }

    float dt = pd->lua->getArgFloat(2);
    if (dt <= 0.0f) {
        pd->lua->pushBool(0);
        return 1;
    }
    float ax = pd->lua->getArgFloat(3);
    float ay = pd->lua->getArgFloat(4);

    float axdt = ax * dt;
    float aydt = ay * dt;

    int hasActiveParticles = 0;
    for (int i = 0; i < ps->maxCount; ++i) {
        RoxyParticle* p = &ps->pool[i];
        if (!p->alive) continue;
        hasActiveParticles = 1;
        p->age += dt;
        if (p->age >= p->lifetime) {
            p->alive = 0;
            p->age = 0.0f;
            continue;
        }
        p->vx += axdt;
        p->vy += aydt;
        p->x += p->vx * dt;
        p->y += p->vy * dt;

        if (p->frameRate > 0.0f) {
            p->frameTimer += dt;
            float frameStep = 1.0f / p->frameRate;
            while (p->frameTimer >= frameStep) {
                p->frameTimer -= frameStep;

                // Advance (or pick) the next frame
                switch (ps->frameMode) {
                  case FRAME_SEQUENTIAL:
                    p->frame++;
                    if (p->frame >= ps->frameCount) {
                      if (ps->shouldLoop)        p->frame = 0;
                      else /* Clamp at last */   p->frame = ps->frameCount - 1;
                    }
                    break;
                  case FRAME_REVERSE:
                    p->frame--;
                    if (p->frame < 0) {
                      if (ps->shouldLoop)        p->frame = ps->frameCount - 1;
                      else /* Clamp at first */  p->frame = 0;
                    }
                    break;
                  case FRAME_RANDOM:
                    p->frame = rand() % ps->frameCount;
                    break;
                  case FRAME_STATIC:
                  default:
                    // No change
                    break;
                }
            }
        }
    }
    pd->lua->pushBool(hasActiveParticles);
    return 1;
}

// ! Draw
// Draws all active particles
int roxy_particles_draw_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps || !ps->pool) return 0;

    int color = pd->lua->getArgInt(2); // kColorBlack or kColorWhite
    int shapeID = pd->lua->getArgInt(3); // 0 = filled circle, etc
    shapeID = roxy_math_clampi(shapeID, 0, 3);

    if (ps->imageTable) {
        int frameW = 0, frameH = 0;
        LCDBitmap *first = pd->graphics->getTableBitmap(ps->imageTable, 1);
        if (first) pd->graphics->getBitmapData(first, &frameW, &frameH, NULL, NULL, NULL);

        for (int i = 0; i < ps->maxCount; ++i) {
            RoxyParticle* p = &ps->pool[i];
            if (!p->alive) continue;
            int frame = p->frame;
            if(frame < 0) frame = 0; // Guard against negatives
            if (frame >= ps->frameCount) frame = ps->frameCount - 1;
            LCDBitmap* bmp = pd->graphics->getTableBitmap(ps->imageTable, frame);
            if (bmp)
                pd->graphics->drawBitmap(bmp, (int)(p->x - frameW/2), (int)(p->y - frameH/2), kBitmapUnflipped);
        }
        return 0;
    }

    // Decide once: for filled shapes use pattern ptr or solid color
    // The C‐API fillEllipse/fillRect draw functions take an LCDColor last arg,
    // which can be a solid‐color enum or a pointer to an 8/16-byte pattern.
    void* fillColorPtr;
    if (ps->hasPattern && (shapeID == 0 || shapeID == 2)) {
        fillColorPtr = ps->pattern; // pointer to your 8/16 pattern bytes
    } else {
        fillColorPtr = (void*)(intptr_t)color; // pass solid‐color as integer
    }

    for (int i = 0; i < ps->maxCount; ++i) {
        RoxyParticle* p = &ps->pool[i];
        if (!p->alive) continue;

        int x = (int)(p->x);
        int y = (int)(p->y);
        int size = (int)(p->size + 0.5f);

        switch (shapeID) {
            case 0: // Filled circle
                pd->graphics->fillEllipse(x - size/2, y - size/2, size, size, 0, 360, (LCDColor)fillColorPtr);
                break;
            case 1: // Outlined circle
                // outlines don’t support patterns—always solid
                pd->graphics->drawEllipse(x - size/2, y - size/2, size, size, 1, 0, 360, (LCDColor)(intptr_t)color);
                break;
            case 2: // Filled square
                pd->graphics->fillRect(x - size/2, y - size/2, size, size, (LCDColor)fillColorPtr);
                break;
            case 3: // Outlined square
                pd->graphics->drawRect(x - size/2, y - size/2, size, size, (LCDColor)(intptr_t)color);
                break;
            default: // Fallback to filled circle
                pd->graphics->fillEllipse(x - size/2, y - size/2, size, size, 0, 360, (LCDColor)fillColorPtr);
                break;
        }
    }
    return 0;
}

// ! Compute AABB
// Computes the axis-aligned bounding box for particle spread
int roxy_particles_computeAABB_l(lua_State* L)
{
    if (!pd) return 0;

    // Read and sanitize arguments
    float lifeMin   = fmaxf(0.0f, pd->lua->getArgFloat(1));
    float lifeMax   = fmaxf(0.0f, pd->lua->getArgFloat(2));
    float speedMin  = pd->lua->getArgFloat(3);
    float speedMax  = pd->lua->getArgFloat(4);
    float sizeMin   = fmaxf(0.0f, pd->lua->getArgFloat(5));
    float sizeMax   = fmaxf(0.0f, pd->lua->getArgFloat(6));
    float ax        = pd->lua->getArgFloat(7);
    float ay        = pd->lua->getArgFloat(8);
    float angRawA   = pd->lua->getArgFloat(9);
    float angRawB   = pd->lua->getArgFloat(10);
    float frameW    = fmaxf(0.0f, pd->lua->getArgFloat(11));
    float frameH    = fmaxf(0.0f, pd->lua->getArgFloat(12));

    // Normalize angle range
    float angMin, angMax;
    int fullCircle;
    normalizeRange(angRawA, angRawB, &angMin, &angMax, &fullCircle);

    // Start with a zero-origin bounding box
    float left=0.0f, right=0.0f, top=0.0f, bottom=0.0f;

    // Collect candidate angles
    float cand[8];
    int candCnt = 0;

    if (fullCircle) {
        // For full circle, test all cardinal directions
        cand[candCnt++] = 0.0f;    // Right
        cand[candCnt++] = 90.0f;   // Down
        cand[candCnt++] = 180.0f;  // Left
        cand[candCnt++] = 270.0f;  // Up
    } else {
        // For partial ranges, test endpoints and any cardinal directions within range
        cand[candCnt++] = angMin;
        cand[candCnt++] = angMax;
        if (angle_in_sweep(0.0f,   angMin, angMax, fullCircle)) cand[candCnt++] = 0.0f;
        if (angle_in_sweep(90.0f,  angMin, angMax, fullCircle)) cand[candCnt++] = 90.0f;
        if (angle_in_sweep(180.0f, angMin, angMax, fullCircle)) cand[candCnt++] = 180.0f;
        if (angle_in_sweep(270.0f, angMin, angMax, fullCircle)) cand[candCnt++] = 270.0f;
    }

    // Convenience arrays
    float lifeVals[2]  = { lifeMin,  lifeMax };
    float speedVals[2] = { speedMin, speedMax };

    // Macro to expand the AABB
    #define AABB_ADD(dx, dy) \
    do { \
        if ((dx) < left)   left   = (dx); \
        if ((dx) > right)  right  = (dx); \
        if ((dy) < top)    top    = (dy); \
        if ((dy) > bottom) bottom = (dy); \
    } while (0)

    // Include the origin
    AABB_ADD(0.0f, 0.0f);

    // Test all combinations of angle, speed, lifetime
    for (int i = 0; i < candCnt; ++i) {
        float deg = cand[i];
        float rad = deg_to_rad(deg);
        float c = cosf(rad);
        float s = sinf(rad);
        for (int sv = 0; sv < 2; ++sv) {
            float v = speedVals[sv];
            for (int lt = 0; lt < 2; ++lt) {
                float t = lifeVals[lt];
                float vx0 = v * c, vy0 = v * s;
                AABB_ADD(vx0 * t + 0.5f * ax * t * t,
                         vy0 * t + 0.5f * ay * t * t);
                // Check turning points if accel nonzero
                if (ax != 0.0f) {
                    float tx = -vx0 / ax;
                    if (tx > 0.0f && tx < t) AABB_ADD(vx0 * tx + 0.5f * ax * tx * tx,
                                                      vy0 * tx + 0.5f * ay * tx * tx);
                }
                if (ay != 0.0f) {
                    float ty = -vy0/ay;
                    if (ty > 0.0f && ty < t) AABB_ADD(vx0 * ty + 0.5f * ax * ty * ty,
                                                      vy0 * ty + 0.5f * ay * ty * ty);
                }
            }
        }
    }

    // Account for both particle size and frame dimensions
    float maxParticleDim = sizeMax;
    float maxFrameDim = fmaxf(frameW, frameH);
    float pad = ceilf(fmaxf(maxParticleDim, maxFrameDim) * 0.5f);

    // Expand and floor/ceil the bounds
    left   = floorf(left   - pad);
    right  = ceilf (right  + pad);
    top    = floorf(top    - pad);
    bottom = ceilf (bottom + pad);

    // Compute width & height
    int boxW = (int)fmaxf(1.0f, right - left);
    int boxH = (int)fmaxf(1.0f, bottom - top);

    // Return six integers: left, right, top, bottom, width, height
    pd->lua->pushInt((int)left);
    pd->lua->pushInt((int)right);
    pd->lua->pushInt((int)top);
    pd->lua->pushInt((int)bottom);
    pd->lua->pushInt(boxW);
    pd->lua->pushInt(boxH);
    return 6;
}

// ! Clear
// Clears all particles by marking them as inactive
int roxy_particles_clear_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps || !ps->pool) {
        pd->lua->pushBool(0); // Indicate no particles active
        return 1;
    }

    for (int i = 0; i < ps->maxCount; ++i) {
        ps->pool[i].alive = 0;
        ps->pool[i].age = 0.0f; // Reset age for safety
    }

    pd->lua->pushBool(0); // Indicate no particles active
    return 1;
}

// ! Destroy
// Alias for free (called from Lua)
int roxy_particles_destroy_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (ps) {
        roxy_particles_free_pool(ps);
    }
    return 0;
}

// ----------------------------------------
// ! Class Registration for RoxyParticlesC
// ----------------------------------------

static const lua_reg roxyParticlesLib[] = {
    {   "new",              roxy_particles_newobject        },
    {   "__gc",             roxy_particles_gc               },
    {   "setPattern",       roxy_particles_setPattern_l     },
    {   "setFrameRate",     roxy_particles_setFrameRate_l   },
    {   "setImageTable",    roxy_particles_setImageTable_l  },
    {   "spawn",            roxy_particles_spawn_l          },
    {   "spawnMultiple",    roxy_particles_spawnMultiple_l  },
    {   "update",           roxy_particles_update_l         },
    {   "draw",             roxy_particles_draw_l           },
    {   "clear",            roxy_particles_clear_l          },
    {   "destroy",          roxy_particles_destroy_l        },
    {   "computeAABB",      roxy_particles_computeAABB_l    },
    {   NULL, NULL}
};

void registerRoxyParticlesC(PlaydateAPI* playdate)
{
    pd = playdate;

    const char* err = NULL;
    if (!playdate->lua->registerClass("RoxyParticlesC", roxyParticlesLib, NULL, 0, &err)) {
        playdate->system->logToConsole("%s:%i: registerClass failed, %s", __FILE__, __LINE__, err);
    }
}
