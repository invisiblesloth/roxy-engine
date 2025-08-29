// core/sprites/roxy_particles.c

#include "roxy_particles.h"
#include "../../utilities/roxy_math.h"
#include "../../utilities/roxy_heapguard.h"
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Absolute hard ceiling, engine will never exceed this
#ifndef ROXY_PARTICLES_MAX_COUNT
#define ROXY_PARTICLES_MAX_COUNT 4096
#endif

// Recommended safe budget; allocations above this are warned
#ifndef ROXY_PARTICLES_SAFE_MAX
#define ROXY_PARTICLES_SAFE_MAX 2048
#endif

static PlaydateAPI* pd = NULL;

/*******************************************//**
 *  Helpers
 ***********************************************/

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

// ! Normalize Range
// Normalizes an angle range to determine min, max, and if it spans a full circle
// Note: Angular ranges are directed - order matters for determining long vs short arcs
// For example: (350, 10) creates a 20° arc crossing 0°, while (10, 350) creates a 340° arc
static void normalizeRange(float a, float b, float* outA, float* outB, int* fullCircle)
{
    // Normalize angles to [0, 360)
    a = fmodf(a, 360.0f);
    if (a < 0) a += 360.0f;
    b = fmodf(b, 360.0f);
    if (b < 0) b += 360.0f;

    // Calculate the directed angular span from a to b
    float span;
    if (b >= a) {
        span = b - a;
    } else {
        span = b - a + 360.0f;
    }

    // Check if this represents a full circle (or nearly full circle)
    if (span >= 359.0f || fabsf(span - 360.0f) < 0.05f) {
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

// ! Initialize Particle Frame
// Helper to set up frame-related properties for a new particle
static void init_particle_frame(RoxyParticle* p, const RoxyParticlesC* ps)
{
    if (ps->imageTable && ps->frameCount > 0) {
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
                if (ps->frameCount > 0) {
                    p->frame = rand() % ps->frameCount;
                } else {
                    p->frame = 0;
                }
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
}

/*******************************************//**
 *  Object Lifecycle
 ***********************************************/

// ! New Particles Pool
// Creates a new particle system with a specified maximum particle count
RoxyParticlesC* roxy_particles_new(int maxCount, LCDBitmapTable* tbl, FrameMode frameMode, int staticFrameLua, int shouldLoop, float initFrameRate)
{
    if (!pd) {
        return NULL;
    }

    if (maxCount <= 0) maxCount = 1;
    if (maxCount > ROXY_PARTICLES_SAFE_MAX) {
        pd->system->logToConsole("roxy_particles_new: maxCount %d exceeds safe limit %d", maxCount, ROXY_PARTICLES_SAFE_MAX);
        maxCount = ROXY_PARTICLES_SAFE_MAX;
    }

    RoxyParticlesC* ps = (RoxyParticlesC*)roxy_malloc(sizeof(RoxyParticlesC));
    if (!ps) {
        pd->system->logToConsole("roxy_particles_new: Failed to allocate particle system");
        return NULL;
    }
    ROXY_LABEL(ps, "RoxyParticlesC");
    roxy_memset(ps, 0, sizeof(RoxyParticlesC));

    ps->maxCount = maxCount;
    ps->activeCount = 0;
    ps->pool = (RoxyParticle*)roxy_malloc(sizeof(RoxyParticle) * (size_t)maxCount);
    if (!ps->pool) {
        pd->system->logToConsole("roxy_particles_new: Failed to allocate particle pool for %d particles", maxCount);
        roxy_free(ps);
        return NULL;
    }
    ROXY_LABEL(ps->pool, "RoxyParticlesC.pool");
    roxy_memset(ps->pool, 0, sizeof(RoxyParticle) * (size_t)maxCount);

    ps->frameRate = initFrameRate;

    // Cache bitmap dimensions for performance
    ps->cachedFrameW = 0;
    ps->cachedFrameH = 0;

    if (tbl) {
        ps->imageTable = tbl;

        // Authoritative, dynamic frame count
        int actualCount = 0;
        while (pd->graphics->getTableBitmap(tbl, actualCount)) {
            actualCount++;
        }

        if (actualCount > 0) {
            ps->frameCount = actualCount;
            ps->frameMode  = frameMode;

            // Convert & clamp static frame (Lua 1-based -> C 0-based)
            int luaStatic = staticFrameLua;
            if (luaStatic < 1) luaStatic = 1;
            luaStatic -= 1; // now 0-based
            if (luaStatic >= ps->frameCount) luaStatic = ps->frameCount - 1;
            ps->staticFrame = luaStatic;
            ps->shouldLoop  = shouldLoop;

            LCDBitmap* first = pd->graphics->getTableBitmap(tbl, 0);
            if (first) {
                pd->graphics->getBitmapData(first, &ps->cachedFrameW, &ps->cachedFrameH, NULL, NULL, NULL);
            }
        } else {
            // Empty table: treat as no imagetable
            ps->imageTable  = NULL;
            ps->frameCount  = 0;
            ps->frameMode   = FRAME_SEQUENTIAL;
            ps->staticFrame = 0;
            ps->shouldLoop  = 0;
        }
    } else {
        // No imagetable
        ps->imageTable  = NULL;
        ps->frameCount  = 0;
        ps->frameMode   = FRAME_SEQUENTIAL;
        ps->staticFrame = 0;
        ps->shouldLoop  = 0;
    }

    return ps;
}

// ! Free Pool
// Frees the particle pool and sets the pointer to NULL to prevent double-free
void roxy_particles_free_pool(RoxyParticlesC* ps)
{
    if (ps == NULL || ps->pool == NULL)
        return;

    void *pool = ps->pool;
    ps->pool = NULL; // Mark as gone

    roxy_free(pool);
}

/*******************************************//**
 *  Lua Class Methods
 ***********************************************/

// ! New Object
// Lua constructor: Creates a new particle system object
int roxy_particles_newobject(lua_State* L)
{
    int maxCount        = pd->lua->getArgInt(1);
    LCDBitmapTable* tbl = pd->lua->getArgObject(2, "playdate.graphics.imagetable", NULL);
    FrameMode frameMode = (FrameMode)pd->lua->getArgInt(3);
    int staticFrameLua  = pd->lua->getArgInt(4);  // 1-based from Lua
    int shouldLoop      = pd->lua->getArgInt(5);
    float initFrameRate = pd->lua->getArgFloat(6);

    RoxyParticlesC* ps = roxy_particles_new(
        maxCount,
        tbl,
        frameMode,
        staticFrameLua,   // pass 1-based; clamp/convert inside roxy_particles_new
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
        roxy_free(ps);
    }
    return 0;
}

/*******************************************//**
 *  Lua-Exposed Methods
 ***********************************************/

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
    if (len > sizeof(ps->pattern)) len = sizeof(ps->pattern);
    roxy_memcpy(ps->pattern, bytes, len);
    if (len == 8) roxy_memset(ps->pattern + 8, 0xFF, 8);
    if (len < 16) roxy_memset(ps->pattern + len, 0, 16 - len);

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
        // Count frames using 0-based indexing
        int count = 0;
        while (pd->graphics->getTableBitmap(tbl, count)) {
            count++;
        }
        ps->frameCount = count;

        LCDBitmap* first = pd->graphics->getTableBitmap(tbl, 0);
        if (first) {
            pd->graphics->getBitmapData(first, &ps->cachedFrameW, &ps->cachedFrameH, NULL, NULL, NULL);
        } else {
            ps->cachedFrameW = 0;
            ps->cachedFrameH = 0;
        }

        // Validate frameCount to prevent division by zero
        if (ps->frameCount <= 0) {
            ps->imageTable = NULL;
            ps->frameCount = 0;
            ps->frameMode = FRAME_SEQUENTIAL;
            ps->staticFrame = 0;
            ps->shouldLoop = false;
            ps->cachedFrameW = 0;
            ps->cachedFrameH = 0;
            return 0;
        }

        // frameMode (already validated in Lua)
        ps->frameMode = (FrameMode)pd->lua->getArgInt(3);

        // staticFrame: convert from Lua's 1-based to C's 0-based, then clamp
        int luaStaticFrame = pd->lua->getArgInt(4);
        ps->staticFrame = luaStaticFrame - 1;
        if (ps->staticFrame < 0) ps->staticFrame = 0;
        if (ps->staticFrame >= ps->frameCount) ps->staticFrame = ps->frameCount - 1;

        // loop flag
        ps->shouldLoop = pd->lua->getArgBool(5);
    }
    else {
        ps->frameCount = 0;
        ps->frameMode = FRAME_SEQUENTIAL;
        ps->staticFrame = 0;
        ps->shouldLoop = false;
        ps->cachedFrameW = 0;
        ps->cachedFrameH = 0;
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

    // O(1) slot allocation: check if we have space
    if (ps->activeCount >= ps->maxCount) {
        pd->lua->pushBool(0);
        return 1;
    }

    // Use the next available slot at activeCount
    int slot = ps->activeCount;
    ps->activeCount++;

    // Initialize particle (only set necessary fields)
    RoxyParticle* p = &ps->pool[slot];
    p->alive = 1;
    p->age = 0.0f;
    p->lifetime = rand_range(lifeMin, lifeMax);

    // Frame initialization
    init_particle_frame(p, ps);

    // Angle and velocity calculation
    float span = fullCircle ? 360.0f : (nAngMax - nAngMin);
    if (!fullCircle && nAngMax < nAngMin) {
        span += 360.0f;
    }
    float angle = nAngMin + rnd01() * span;
    angle = fmodf(angle, 360.0f);
    float theta = deg_to_rad(angle);
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
        pd->lua->pushInt(0);
        return 1;
    }

    int count = pd->lua->getArgInt(2);
    if (count <= 0) {
        pd->lua->pushInt(0);
        return 1;
    }

    float lifeMin = fmaxf(0.0f, pd->lua->getArgFloat(3));
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

    // Calculate how many we can actually spawn (O(1) check)
    int availableSlots = ps->maxCount - ps->activeCount;
    int actualCount = (count < availableSlots) ? count : availableSlots;

    if (actualCount <= 0) {
        pd->lua->pushInt(0);
        return 1;
    }

    // Pre-calculate ranges for efficiency
    float lifeRange = lifeMax - lifeMin;
    float speedRange = speedMax - speedMin;
    float sizeRange = sizeMax - sizeMin;

    // Pre-calculate angle span
    float span = fullCircle ? 360.0f : (nAngMax - nAngMin);
    if (!fullCircle && nAngMax < nAngMin) {
        span += 360.0f;
    }

    // Spawn particles in O(actualCount) time
    for (int i = 0; i < actualCount; i++) {
        int slot = ps->activeCount + i;
        RoxyParticle* p = &ps->pool[slot];

        // Initialize particle
        p->alive = 1;
        p->age = 0.0f;
        p->lifetime = lifeMin + rnd01() * lifeRange;

        // Frame initialization
        init_particle_frame(p, ps);

        // Angle and velocity calculation
        float angle = nAngMin + rnd01() * span;
        angle = fmodf(angle, 360.0f);
        float theta = deg_to_rad(angle);
        float speed = speedMin + rnd01() * speedRange;

        p->vx = speed * cosf(theta);
        p->vy = speed * sinf(theta);
        p->x = ex;
        p->y = ey;
        p->size = sizeMin + rnd01() * sizeRange;
    }

    // Update activeCount once at the end
    ps->activeCount += actualCount;

    pd->lua->pushInt(actualCount);
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

    float frameStep = 0.0f;
    int doAnim = (ps->frameCount > 0);
    if (doAnim) {
        frameStep = 1.0f / fmaxf(ps->frameRate, 1.0f);
    }

    for (int i = ps->activeCount - 1; i >= 0; --i) {
        RoxyParticle* p = &ps->pool[i];

        p->age += dt;
        if (p->age >= p->lifetime) {
            // Kill particle by swapping with the last active particle
            ps->activeCount--;
            if (i < ps->activeCount) *p = ps->pool[ps->activeCount];
            // Mark the now-unused slot as dead
            ps->pool[ps->activeCount].alive = 0;
            ps->pool[ps->activeCount].age = 0.0f;
            continue;
        }

        p->vx += axdt;
        p->vy += aydt;
        p->x += p->vx * dt;
        p->y += p->vy * dt;

        // FrameCount validation for animation
        if (p->frameRate > 0.0f && ps->frameCount > 0) {
            p->frameTimer += dt;
            float thisStep = (p->frameRate > 0.0f) ? (1.0f / p->frameRate) : frameStep;
            while (p->frameTimer >= thisStep) {
                p->frameTimer -= thisStep;

                // Advance (or pick) the next frame
                switch (ps->frameMode) {
                    case FRAME_SEQUENTIAL:
                        p->frame++;
                        if (p->frame >= ps->frameCount) {
                            if (ps->shouldLoop) p->frame = 0;
                            else p->frame = ps->frameCount - 1;
                        }
                        break;
                    case FRAME_REVERSE:
                        p->frame--;
                        if (p->frame < 0) {
                            if (ps->shouldLoop) p->frame = ps->frameCount - 1;
                            else p->frame = 0;
                        }
                        break;
                    case FRAME_RANDOM:
                        if (ps->frameCount > 0) {
                            p->frame = rand() % ps->frameCount;
                        }
                        break;
                    case FRAME_STATIC:
                    default:
                        // No change
                        break;
                }
            }
        }
    }

    pd->lua->pushBool(ps->activeCount > 0);
    return 1;
}

// ! Draw
// Draws all active particles
int roxy_particles_draw_l(lua_State* L)
{
    const RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps || !ps->pool) return 0;

    int color = pd->lua->getArgInt(2); // kColorBlack or kColorWhite
    int shapeID = pd->lua->getArgInt(3); // 0 = filled circle, etc
    shapeID = roxy_math_clampi(shapeID, 0, 3);

    if (ps->imageTable && ps->frameCount > 0) { // FrameCount validation
        int frameW = ps->cachedFrameW;
        int frameH = ps->cachedFrameH;

        // Only loop through active particles
        for (int i = 0; i < ps->activeCount; ++i) {
            const RoxyParticle* p = &ps->pool[i];

            // Clamp frame to valid range
            int frame = p->frame;
            if (frame < 0) frame = 0;
            if (frame >= ps->frameCount) frame = ps->frameCount - 1;

            // Use 0-based indexing for frame access
            LCDBitmap* bmp = pd->graphics->getTableBitmap(ps->imageTable, frame);
            if (bmp)
                pd->graphics->drawBitmap(bmp, (int)(p->x - frameW/2.0f), (int)(p->y - frameH/2.0f), kBitmapUnflipped);

        }
        return 0;
    }

    // Decide once: for filled shapes use pattern ptr or solid color
    void* fillColorPtr;
    if (ps->hasPattern && (shapeID == 0 || shapeID == 2)) {
        fillColorPtr = (void*)(ps->pattern); // Cast is safe for API
    } else {
        fillColorPtr = (void*)(intptr_t)color;
    }

    // Only loop through active particles
    for (int i = 0; i < ps->activeCount; ++i) {
        const RoxyParticle* p = &ps->pool[i];

        int x = (int)(p->x);
        int y = (int)(p->y);
        int size = (int)(p->size + 0.5f);
        if (size < 1) size = 1;
        if (size > 256) size = 256;

        switch (shapeID) {
            case 0: // Filled circle
                pd->graphics->fillEllipse(x - size/2, y - size/2, size, size, 0, 360, (LCDColor)fillColorPtr);
                break;
            case 1: // Outlined circle
                pd->graphics->drawEllipse(x - size/2, y - size/2, size, size, 1, 0, 360, (LCDColor)(intptr_t)color);
                break;
            case 2: // Filled square
                pd->graphics->fillRect(x - size/2, y - size/2, size, size, (LCDColor)fillColorPtr);
                break;
            case 3: // Outlined square
                pd->graphics->drawRect(x - size/2, y - size/2, size, size, (LCDColor)(intptr_t)color);
                break;
            default:
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

// ! Resize Pool
// Grows or shrinks the particle pool in place via realloc
int roxy_particles_resizePool_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    int newMax = pd->lua->getArgInt(2);
    if (!ps || !ps->pool || newMax <= 0 || newMax == ps->maxCount) {
        pd->lua->pushBool(0);
        return 1;
    }

    // Hard cap to avoid runaway allocations on device
    if (newMax > ROXY_PARTICLES_MAX_COUNT) {
        pd->system->logToConsole("RoxyParticlesC.resizePool: newMax=%d exceeds cap=%d",
                                 newMax, ROXY_PARTICLES_MAX_COUNT);
        pd->lua->pushBool(0);
        return 1;
    }

    // Additional safety check for reasonable limits on resource-constrained hardware
    if (newMax > ROXY_PARTICLES_SAFE_MAX) {
        pd->system->logToConsole("RoxyParticlesC.resizePool: newMax=%d exceeds safe limit=%d, consider using multiple smaller systems",
                                 newMax, ROXY_PARTICLES_SAFE_MAX);
    }

    // Overflow guard for multiplication
    if ((size_t)newMax > (SIZE_MAX / sizeof(RoxyParticle))) {
        pd->system->logToConsole("RoxyParticlesC.resizePool: size overflow for newMax=%d", newMax);
        pd->lua->pushBool(0);
        return 1;
    }

    size_t newBytes = sizeof(RoxyParticle) * (size_t)newMax;

    RoxyParticle* newBuf = (RoxyParticle*)roxy_realloc(ps->pool, newBytes);
    if (!newBuf) {
        pd->system->logToConsole("RoxyParticlesC.resizePool: Failed to reallocate pool to %d particles", newMax);
        // On failure, leave the old pool intact
        pd->lua->pushBool(0);
        return 1;
    }

    // If we grew the pool, zero out the new slots
    if (newMax > ps->maxCount) {
        roxy_memset(newBuf + ps->maxCount, 0, sizeof(RoxyParticle) * (size_t)(newMax - ps->maxCount));
    } else if (newMax < ps->maxCount) {
        // If we shrunk the pool, adjust activeCount if necessary
        if (ps->activeCount > newMax) {
            ps->activeCount = newMax;
        }
    }

    // Update our struct and (re)label for nicer heap dumps
    ps->pool = newBuf;
    ROXY_LABEL(ps->pool, "RoxyParticlesC.pool");
    ps->maxCount = newMax;

    pd->lua->pushBool(1);
    return 1;
}

// ! Clear
// Clears all particles by marking them as inactive
int roxy_particles_clear_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps || !ps->pool) {
        pd->lua->pushBool(0);
        return 1;
    }

    for (int i = 0; i < ps->maxCount; ++i) {
        ps->pool[i].alive = 0;
        ps->pool[i].age = 0.0f;
    }
    ps->activeCount = 0;

    pd->lua->pushBool(1);
    return 1;
}

// ! Destroy
// Alias for free (called from Lua)
int roxy_particles_destroy_l(lua_State* L)
{
    RoxyParticlesC* ps = pd->lua->getArgObject(1, "RoxyParticlesC", NULL);
    if (!ps) return 0;

    // Idempotent: safe to call multiple times
    roxy_particles_free_pool(ps);
    ps->activeCount = 0;
    ps->maxCount    = 0;
    ps->imageTable  = NULL;
    ps->frameCount  = 0;
    // __gc will free the struct when Lua releases the userdata

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
    {   "resizePool",       roxy_particles_resizePool_l     },
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
