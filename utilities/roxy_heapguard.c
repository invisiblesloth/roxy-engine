// utilities/roxy_heapguard.c

/**
 * Roxy Heap Guard implementation
 *
 * Debug mode adds canaries + red-zone around each allocation, tracks blocks in
 * a linked list, verifies integrity, and can dump all live allocations.
 * Release mode compiles these functions as thin forwards or no-ops so that
 * header macros can expand directly to the Playdate allocator with zero overhead.
 */

#include "roxy_heapguard.h"

#include <string.h>
#include <stdio.h>

/*******************************************//**
 *  Configuration and Constants (Debug Path)
 ***********************************************/

#ifndef ROXY_HG_HEAD
#define ROXY_HG_HEAD 0xC0DEF00Du
#endif
#ifndef ROXY_HG_TAIL
#define ROXY_HG_TAIL 0xDEADC0DEu
#endif
#ifndef ROXY_HG_POISON
#define ROXY_HG_POISON 0xA5
#endif

#define ROXY_HG_TAILBYTES 4u
#define ROXY_HG_POISON_BYTES (ROXY_HG_REDZONE - ROXY_HG_TAILBYTES)

#if ROXY_HEAP_GUARD
_Static_assert(ROXY_HG_REDZONE >= ROXY_HG_TAILBYTES, "ROXY_HG_REDZONE must be >= 4");
_Static_assert((ROXY_HG_REDZONE % ROXY_HG_TAILBYTES) == 0, "ROXY_HG_REDZONE must be multiple of 4");
#endif

/*******************************************//**
 *  Internal State
 ***********************************************/

typedef struct RoxyHgHeader {
    uint32_t headCanary;
    uint32_t size;      // User allocation size
    const char* label;  // Optional label (not owned)
    const char* file;   // Allocation site
    uint32_t line;      // Allocation site
    struct RoxyHgHeader* prev;
    struct RoxyHgHeader* next;
} RoxyHgHeader;

static const struct PlaydateAPI* s_pd = NULL;

#if ROXY_HEAP_GUARD
static RoxyHgHeader* s_head = NULL; // Intrusive list head
static size_t s_total_allocated = 0;
static size_t s_peak_allocated  = 0;
#endif

/******************************************//**
 *   Small Helpers
 ***********************************************/

#if ROXY_HEAP_GUARD
static inline uint8_t* roxy_hg_user(RoxyHgHeader* h) {
    return (uint8_t*)h + sizeof(RoxyHgHeader);
}
static inline uint32_t* roxy_hg_tailp(RoxyHgHeader* h) {
    return (uint32_t*)(roxy_hg_user(h) + h->size + ROXY_HG_POISON_BYTES);
}
static inline void roxy_hg_link(RoxyHgHeader* h) {
    h->prev = NULL;
    h->next = s_head;
    if (s_head) s_head->prev = h;
    s_head = h;
}
static inline void roxy_hg_unlink(RoxyHgHeader* h) {
    if (h->prev) h->prev->next = h->next;
    else s_head = h->next;
    if (h->next) h->next->prev = h->prev;
}
static void roxy_hg_fail(const char* reason, RoxyHgHeader* h) {
    if (!s_pd || !s_pd->system) return;
    s_pd->system->error(
        "HeapGuard: %s (size=%u, site=%s:%u%s%s)",
        reason,
        (unsigned)h->size,
        h->file ? h->file : "?",
        (unsigned)h->line,
        h->label ? ", label=" : "",
        h->label ? h->label : ""
    );
}
static void roxy_hg_check(RoxyHgHeader* h) {
    if (h->headCanary != ROXY_HG_HEAD) roxy_hg_fail("Head canary clobbered", h);
    if (ROXY_HG_POISON_BYTES) {
        uint8_t* rz = roxy_hg_user(h) + h->size;
        for (uint32_t i = 0; i < ROXY_HG_POISON_BYTES; ++i) {
            if (rz[i] != ROXY_HG_POISON) roxy_hg_fail("Red zone overwritten", h);
        }
    }
    if (*roxy_hg_tailp(h) != ROXY_HG_TAIL) roxy_hg_fail("Tail canary clobbered", h);
}
#endif // ROXY_HEAP_GUARD

/*******************************************//**
 *  Public API
 ***********************************************/

// ! Initialize
void roxy_heapguard_init(const struct PlaydateAPI* playdate) {
    s_pd = playdate;
#if ROXY_HEAP_GUARD
    // Reset debug state (useful on hot reloads)
    s_head = NULL;
    s_total_allocated = 0;
    s_peak_allocated  = 0;
#endif
}

// ! Verify All
void roxy_heapguard_verify_all(void) {
#if ROXY_HEAP_GUARD
    for (RoxyHgHeader* h = s_head; h; h = h->next) roxy_hg_check(h);
#endif
}

// ! Dump Active
void roxy_heapguard_dump_active(void) {
    if (!s_pd || !s_pd->system) return;
#if ROXY_HEAP_GUARD
    s_pd->system->logToConsole("=== Roxy HeapGuard active allocations ===");
    for (RoxyHgHeader* h = s_head; h; h = h->next) {
        uintptr_t start = (uintptr_t)roxy_hg_user(h);
        uintptr_t end   = start + h->size - 1;
        uintptr_t rz_s  = end + 1;
        uintptr_t rz_e  = rz_s + ROXY_HG_POISON_BYTES + 4 - 1; // +tail
        if (h->label) {
            s_pd->system->logToConsole(
                " %08x..%08x size=%u label=%s (site %s:%u) rz=%08x..%08x",
                (unsigned)start, (unsigned)end, (unsigned)h->size,
                h->label, h->file ? h->file : "?", (unsigned)h->line,
                (unsigned)rz_s, (unsigned)rz_e
            );
        } else {
            s_pd->system->logToConsole(
                " %08x..%08x size=%u from %s:%u rz=%08x..%08x",
                (unsigned)start, (unsigned)end, (unsigned)h->size,
                h->file ? h->file : "?", (unsigned)h->line,
                (unsigned)rz_s, (unsigned)rz_e
            );
        }
    }
    s_pd->system->logToConsole(
        "Total allocated: %u bytes, Peak: %u bytes",
        (unsigned)s_total_allocated, (unsigned)s_peak_allocated
    );
#else
    s_pd->system->logToConsole("HeapGuard: dump_active (release): no tracking (ROXY_HEAP_GUARD=0)");
#endif
}

// ! Label
void roxy_heapguard_label(void* user, const char* label) {
#if ROXY_HEAP_GUARD
    if (!user) return;
    RoxyHgHeader* h = (RoxyHgHeader*)((uint8_t*)user - sizeof(RoxyHgHeader));
    h->label = label;
#else
    (void)user; (void)label;
#endif
}

/*******************************************//**
 *  Allocation Wrappers
 ***********************************************/

// ! malloc
void* roxy_malloc_site(size_t size, const char* file, uint32_t line) {
#if ROXY_HEAP_GUARD
    if (!s_pd || !s_pd->system) return NULL;
    size_t total = sizeof(RoxyHgHeader) + size + ROXY_HG_REDZONE;
    RoxyHgHeader* h = (RoxyHgHeader*)s_pd->system->realloc(NULL, total);
    if (!h) return NULL;
    h->headCanary = ROXY_HG_HEAD;
    h->size       = (uint32_t)size;
    h->label      = NULL;
    h->file       = file;
    h->line       = line;
    roxy_hg_link(h);
    uint8_t* user = (uint8_t*)h + sizeof(RoxyHgHeader);
    if (ROXY_HG_POISON_BYTES) memset(user + h->size, ROXY_HG_POISON, ROXY_HG_POISON_BYTES);
    *roxy_hg_tailp(h) = ROXY_HG_TAIL;
    s_total_allocated += size;
    if (s_total_allocated > s_peak_allocated) s_peak_allocated = s_total_allocated;
    return user;
#else
    (void)file; (void)line;
    return (s_pd && s_pd->system) ? s_pd->system->realloc(NULL, size) : NULL;
#endif
}

// ! Label (alloc)
void* roxy_alloc_label_site(size_t size, const char* label, const char* file, uint32_t line) {
#if ROXY_HEAP_GUARD
    void* p = roxy_malloc_site(size, file, line);
    if (p) roxy_heapguard_label(p, label);
    return p;
#else
    (void)label; (void)file; (void)line;
    return (s_pd && s_pd->system) ? s_pd->system->realloc(NULL, size) : NULL;
#endif
}

// ! calloc
void* roxy_calloc_site(size_t count, size_t size, const char* file, uint32_t line) {
    size_t bytes = count * size;
    void* p = roxy_malloc_site(bytes, file, line);
    if (p) memset(p, 0, bytes);
    return p;
}

// ! realloc
void* roxy_realloc_site(void* user, size_t newSize, const char* file, uint32_t line) {
#if ROXY_HEAP_GUARD
    if (!s_pd || !s_pd->system) return NULL;
    if (!user) return roxy_malloc_site(newSize, file, line);
    RoxyHgHeader* h = (RoxyHgHeader*)((uint8_t*)user - sizeof(RoxyHgHeader));
    roxy_hg_check(h);

    size_t oldSize  = h->size;
    size_t totalNew = sizeof(RoxyHgHeader) + newSize + ROXY_HG_REDZONE;
    RoxyHgHeader* hNew = (RoxyHgHeader*)s_pd->system->realloc(h, totalNew);
    if (!hNew) return NULL;

    // Fix intrusive list pointers if block moved
    if (hNew != h) {
        if (hNew->prev) hNew->prev->next = hNew; else s_head = hNew;
        if (hNew->next) hNew->next->prev = hNew;
    }

    hNew->size = (uint32_t)newSize;
    hNew->file = file;
    hNew->line = line;

    uint8_t* userNew = (uint8_t*)hNew + sizeof(RoxyHgHeader);
    if (ROXY_HG_POISON_BYTES) memset(userNew + newSize, ROXY_HG_POISON, ROXY_HG_POISON_BYTES);
    *roxy_hg_tailp(hNew) = ROXY_HG_TAIL;

    if (newSize >= oldSize) {
        s_total_allocated += (newSize - oldSize);
        if (s_total_allocated > s_peak_allocated) s_peak_allocated = s_total_allocated;
    } else {
        s_total_allocated -= (oldSize - newSize);
    }

    return userNew;
#else
    (void)file; (void)line;
    return (s_pd && s_pd->system) ? s_pd->system->realloc(user, newSize) : NULL;
#endif
}

// ! Free
void roxy_free_site(void* user, const char* file, uint32_t line) {
#if ROXY_HEAP_GUARD
    (void)file; (void)line;
    if (!s_pd || !s_pd->system || !user) return;
    // Find header: defense-in-depth to ensure it's one of ours.
    RoxyHgHeader* h = (RoxyHgHeader*)((uint8_t*)user - sizeof(RoxyHgHeader));
    // Basic header sanity before list operations:
    if (h->headCanary != ROXY_HG_HEAD) {
        s_pd->system->error("HeapGuard: free of untracked pointer %p", user);
        return;
    }
    roxy_hg_check(h);
    memset(user, ROXY_HG_POISON, h->size); // catch UAF reads
    s_total_allocated -= h->size;
    roxy_hg_unlink(h);
    s_pd->system->realloc(h, 0);
#else
    (void)file; (void)line;
    if (s_pd && s_pd->system && user) s_pd->system->realloc(user, 0);
#endif
}

/*******************************************//**
 *  Bounds-Aware memcpy/memset (Debug Only)
 ***********************************************/

#if ROXY_HEAP_GUARD
// ! Heap Guard Span Okay
static int roxy_hg_span_ok(void* dst, size_t n) {
    uint8_t* p = (uint8_t*)dst;
    for (RoxyHgHeader* h = s_head; h; h = h->next) {
        uint8_t* u = (uint8_t*)h + sizeof(RoxyHgHeader);
        if (p >= u && p < u + h->size) {
            size_t used = (size_t)(p - u) + n;
            return used <= h->size;
        }
    }
    return 0;
}
#endif

// ! memcpy
void* roxy_memcpy_site(void* dst, const void* src, size_t n, const char* file, uint32_t line) {
#if ROXY_HEAP_GUARD
    if (!roxy_hg_span_ok(dst, n)) {
        if (s_pd && s_pd->system) {
            s_pd->system->logToConsole("roxy_memcpy overflow at %s:%u (n=%u)", file, (unsigned)line, (unsigned)n);
            s_pd->system->error("roxy_memcpy overflow");
        }
    }
#else
    (void)file; (void)line;
#endif
    return memcpy(dst, src, n);
}

// ! memset
void* roxy_memset_site(void* dst, int v, size_t n, const char* file, uint32_t line) {
#if ROXY_HEAP_GUARD
    if (!roxy_hg_span_ok(dst, n)) {
        if (s_pd && s_pd->system) {
            s_pd->system->logToConsole("roxy_memset overflow at %s:%u (n=%u)", file, (unsigned)line, (unsigned)n);
            s_pd->system->error("roxy_memset overflow");
        }
    }
#else
    (void)file; (void)line;
#endif
    return memset(dst, v, n);
}

// ! Bounds
void roxy_bounds_site(void* dst, size_t n, const char* file, uint32_t line) {
#if ROXY_HEAP_GUARD
    uint8_t* p = (uint8_t*)dst;
    int ok = 0;
    for (RoxyHgHeader* h = s_head; h; h = h->next) {
        uint8_t* u = (uint8_t*)h + sizeof(RoxyHgHeader);
        if (p >= u && p < u + h->size) {
            size_t used = (size_t)(p - u) + n;
            ok = (used <= h->size);
            if (!ok) {
                if (s_pd && s_pd->system) {
                    s_pd->system->logToConsole("roxy_bounds overflow at %s:%u (n=%u)", file, (unsigned)line, (unsigned)n);
                }
                roxy_hg_fail("Bounds assertion failed", h);
            }
            break;
        }
    }
    if (!ok) {
        if (s_pd && s_pd->system) {
            s_pd->system->error("roxy_bounds: pointer not tracked (at %s:%u)", file, (unsigned)line);
        }
    }
#else
    (void)dst; (void)n; (void)file; (void)line;
#endif
}

/*******************************************//**
 *  Lua bindings & registration
 ***********************************************/

#if ROXY_HEAP_GUARD
static uint32_t s_snap = 0;

static int roxy_heapguard_verify_all_l(lua_State* L) {
    (void)L;
    roxy_heapguard_verify_all();
    return 0;
}

static int roxy_heapguard_dump_active_l(lua_State* L) {
    (void)L;
    roxy_heapguard_dump_active();
    return 0;
}

static int roxy_heapguard_snap_l(lua_State* L) {
    if (!s_pd) return 0;
    const char* tag = s_pd->lua->getArgString(1);
    roxy_heapguard_verify_all();
    s_pd->system->logToConsole("HG SNAPSHOT %u BEGIN [%s]", ++s_snap, tag ? tag : "?");
    roxy_heapguard_dump_active();
    s_pd->system->logToConsole("HG SNAPSHOT %u END", s_snap);
    return 0;
}
#endif

int roxy_heapguard_register_lua(struct PlaydateAPI* playdate) {
#if ROXY_HEAP_GUARD
    if (!playdate || !playdate->lua || !playdate->system) return -1;

    const char* error = NULL;

    struct Reg { const char* name; int (*fn)(lua_State*); } regs[] = {
        { "roxy.heapGuardVerifyAll", roxy_heapguard_verify_all_l },
        { "roxy.heapGuardDumpActive", roxy_heapguard_dump_active_l },
        { "roxy.heapGuardSnap",       roxy_heapguard_snap_l      },
    };

    for (size_t i = 0; i < sizeof(regs)/sizeof(regs[0]); ++i) {
        if (!playdate->lua->addFunction(regs[i].fn, regs[i].name, &error)) {
            playdate->system->logToConsole("heapguard register failed: %s (%s)", regs[i].name, error ? error : "?");
            return -1;
        }
    }
    return 0;
#else
    (void)playdate;
    return 0; // noop in release
#endif
}
