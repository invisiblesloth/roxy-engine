// core/sprites/roxy_particles.h

#ifndef ROXY_PARTICLES_H
#define ROXY_PARTICLES_H

#include "pd_api.h"

// Frame animation modes for particles
typedef enum {
    FRAME_SEQUENTIAL = 0,   // Play frames 0, 1, 2... in order
    FRAME_REVERSE    = 1,   // Play frames backwards (n-1, n-2, ... 0)
    FRAME_RANDOM     = 2,   // Pick random frame each step
    FRAME_STATIC     = 3    // Use only the staticFrame
} FrameMode;

// Individual particle data
typedef struct {
    float x, y;         // Position
    float vx, vy;       // Velocity
    float size;         // Particle size
    float age;          // Current age
    float lifetime;     // Total lifetime
    int alive;          // Whether particle is active
    int frame;          // Current animation frame (0-based)
    float frameRate;    // Animation frame rate (fps)
    float frameTimer;   // Animation timing accumulator
} RoxyParticle;

// Particle system container
typedef struct {
    RoxyParticle* pool;         // Particle pool array
    int maxCount;               // Maximum number of particles
    int activeCount;            // Number of active particles
    LCDBitmapTable* imageTable; // Optional image table for sprite particles
    int cachedFrameW;           // Cached bitmap width
    int cachedFrameH;           // Cached bitmap height
    int frameCount;             // Number of frames in imageTable
    FrameMode frameMode;        // Animation mode
    int staticFrame;            // Frame to use for FRAME_STATIC mode (0-based)
    int shouldLoop;             // Whether animations should loop
    float frameRate;            // Default frame rate for new particles
    int hasPattern;             // Whether a fill pattern is set
    uint8_t pattern[16];        // Fill pattern data (8 bytes fill + 8 bytes mask)
} RoxyParticlesC;

// Function prototypes for external use and better modularity

// Core lifecycle functions
RoxyParticlesC* roxy_particles_new(int maxCount, LCDBitmapTable* tbl, FrameMode frameMode,
                                   int staticFrame, int shouldLoop, float initFrameRate);
void roxy_particles_free_pool(RoxyParticlesC* ps);

// Lua constructor and destructor
int roxy_particles_newobject(lua_State* L);
int roxy_particles_gc(lua_State* L);

// Lua-exposed methods
int roxy_particles_setPattern_l(lua_State* L);
int roxy_particles_setFrameRate_l(lua_State* L);
int roxy_particles_setImageTable_l(lua_State* L);
int roxy_particles_spawn_l(lua_State* L);
int roxy_particles_spawnMultiple_l(lua_State* L);
int roxy_particles_update_l(lua_State* L);
int roxy_particles_draw_l(lua_State* L);
int roxy_particles_computeAABB_l(lua_State* L);
int roxy_particles_resizePool_l(lua_State* L);
int roxy_particles_clear_l(lua_State* L);
int roxy_particles_destroy_l(lua_State* L);

// Registration function
void registerRoxyParticlesC(PlaydateAPI* playdate);

#endif // ROXY_PARTICLES_H
