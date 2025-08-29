// utilities/roxy_heapguard.h

/**
 * Roxy Heap Guard (debug-only allocator instrumentation)
 *
 *  - When ROXY_HEAP_GUARD == 1, allocations get canaries + a red zone,
 *    are tracked in a list, and can be verified/dumped.
 *  - When ROXY_HEAP_GUARD == 0, the macros below expand directly to
 *    Playdate's allocator / standard C functions with *no* overhead.
 *
 * Usage:
 *  // In a TU that has a PlaydateAPI* (usually named `pd`):
 *  #define ROXY_HEAP_GUARD 1 // Enable instrumentation in debug
 *  #include "utilities/roxy_heapguard.h"
 *
 *  // Allocate:
 *  MyStruct* s = (MyStruct*)roxy_malloc(sizeof(MyStruct));
 *  ROXY_LABEL(s, "MyStruct");
 *
 *  // Or typed helpers (label optional):
 *  MyStruct* t = ROXY_NEW(MyStruct);                   // sizeof(MyStruct)
 *  MyStruct* u = ROXY_NEW_LABEL(MyStruct, "Player");   // + label
 *
 *  // Bytes helpers:
 *  void* buf = ROXY_ALLOC_BYTES(1024);
 *  void* str = ROXY_ALLOC_BYTES_LABEL(len+1, "name");
 *
 *  // Realloc/Free:
 *  p = roxy_realloc(p, newBytes);
 *  roxy_free(p);
 *
 *  // Optional bounds assertions (debug only):
 *  ROXY_BOUNDS(dst, n);
 *
 *  // Lua side (only if ROXY_HEAP_GUARD==1):
 *  roxy.heapGuardVerifyAll()
 *  roxy.heapGuardDumpActive()
 *
 * If your PlaydateAPI* is not named `pd`, define ROXY_PD_SYMBOL before include:
 *  #define ROXY_PD_SYMBOL playdate
 *  #include "utilities/roxy_heapguard.h"
 */

#ifndef ROXY_HEAP_GUARD_H
#define ROXY_HEAP_GUARD_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include "pd_api.h"

/*******************************************//**
 *  Configuration
 ***********************************************/

// Default OFF unless explicitly enabled by build flags or before-include define
#ifndef ROXY_HEAP_GUARD
#define ROXY_HEAP_GUARD 0
#endif

// Which symbol names your PlaydateAPI* in this translation unit?
#ifndef ROXY_PD_SYMBOL
#define ROXY_PD_SYMBOL pd
#endif

// Red-zone size (bytes) when guard is on; multiple of 4, >= 4
#ifndef ROXY_HG_REDZONE
#define ROXY_HG_REDZONE 256u
#endif

/*******************************************//**
 *  Public API
 ***********************************************/

struct PlaydateAPI;

// Call exactly once at init. Safe to call when ROXY_HEAP_GUARD==0.
void roxy_heapguard_init(const struct PlaydateAPI* playdate);

// Verify all tracked blocks (debug only; no-op in release)
void roxy_heapguard_verify_all(void);

// Dump all active blocks (debug only; no-op in release)
void roxy_heapguard_dump_active(void);

// Label an allocation for nicer dumps (debug only; no-op in release)
void roxy_heapguard_label(void* user, const char* label);

// Site-aware functions (normally use the macros below instead)
void* roxy_malloc_site(size_t size, const char* file, uint32_t line);
void* roxy_calloc_site(size_t count, size_t size, const char* file, uint32_t line);
void* roxy_realloc_site(void* user, size_t newSize, const char* file, uint32_t line);
void  roxy_free_site(void* user, const char* file, uint32_t line);

void* roxy_memcpy_site(void* dst, const void* src, size_t n, const char* file, uint32_t line);
void* roxy_memset_site(void* dst, int v, size_t n, const char* file, uint32_t line);

void  roxy_bounds_site(void* dst, size_t n, const char* file, uint32_t line);

// Helper used only when guard is ON: allocate and label in one call
void* roxy_alloc_label_site(size_t size, const char* label, const char* file, uint32_t line);

// Register heap-guard Lua functions (debug only; no-op in release).
// Returns 0 on success, -1 on failure.
int roxy_heapguard_register_lua(struct PlaydateAPI* playdate);

/*******************************************//**
 *  Convenience Macros
 ***********************************************/

#if ROXY_HEAP_GUARD

    // Debug: record site, add guards, track blocks
    #define roxy_malloc(sz)         roxy_malloc_site((sz), __FILE__, (uint32_t)__LINE__)
    #define roxy_calloc(cnt, sz)    roxy_calloc_site((cnt), (sz), __FILE__, (uint32_t)__LINE__)
    #define roxy_realloc(ptr, sz)   roxy_realloc_site((ptr), (sz), __FILE__, (uint32_t)__LINE__)
    #define roxy_free(ptr)          roxy_free_site((ptr), __FILE__, (uint32_t)__LINE__)
    #define roxy_memcpy(dst,src,n)  roxy_memcpy_site((dst),(src),(n), __FILE__, (uint32_t)__LINE__)
    #define roxy_memset(dst,v,n)    roxy_memset_site((dst),(v),(n), __FILE__, (uint32_t)__LINE__)
    #define ROXY_BOUNDS(dst, n)     roxy_bounds_site((dst),(n), __FILE__, (uint32_t)__LINE__)
    #define ROXY_LABEL(ptr, label)  roxy_heapguard_label((ptr), (label))

    // Typed helpers
    #define ROXY_NEW(type)               ( (type*)roxy_malloc_site(sizeof(type), __FILE__, (uint32_t)__LINE__) )
    #define ROXY_NEW_LABEL(type, label)  ( (type*)roxy_alloc_label_site(sizeof(type), (label), __FILE__, (uint32_t)__LINE__) )

    // Byte helpers
    #define ROXY_ALLOC_BYTES(n)              roxy_malloc_site((n), __FILE__, (uint32_t)__LINE__)
    #define ROXY_ALLOC_BYTES_LABEL(n,label)  roxy_alloc_label_site((n), (label), __FILE__, (uint32_t)__LINE__)

    // Optional one-liners for quick checks from C (vanish in release)
    #define ROXY_HG_VERIFY()  roxy_heapguard_verify_all()
    #define ROXY_HG_DUMP()    roxy_heapguard_dump_active()

#else

    // Release: expand to Playdate allocator + libc. No extra calls or checks.
    // Assumes a PlaydateAPI* named by ROXY_PD_SYMBOL is in scope.
    #define roxy_malloc(sz) (ROXY_PD_SYMBOL->system->realloc(NULL, (sz)))
    // calloc: inline helper for zero-init (likely inlined by compiler)
    #define roxy_calloc(cnt, sz) ({ \
        void* __p = ROXY_PD_SYMBOL->system->realloc(NULL, (cnt)*(sz)); \
        if (__p) memset(__p, 0, (cnt)*(sz)); \
        __p; \
    })
    #define roxy_realloc(ptr, sz)   (ROXY_PD_SYMBOL->system->realloc((ptr), (sz)))
    #define roxy_free(ptr)          do { if ((ptr)) ROXY_PD_SYMBOL->system->realloc((ptr), 0); } while (0)
    #define roxy_memcpy(dst,src,n)  memcpy((dst),(src),(n))
    #define roxy_memset(dst,v,n)    memset((dst),(v),(n))
    #define ROXY_BOUNDS(dst, n)     ((void)0)
    #define ROXY_LABEL(ptr, label)  ((void)0)

    #define ROXY_NEW(type)               ( (type*)ROXY_PD_SYMBOL->system->realloc(NULL, sizeof(type)) )
    #define ROXY_NEW_LABEL(type, label)  ( (type*)ROXY_PD_SYMBOL->system->realloc(NULL, sizeof(type)) )

    #define ROXY_ALLOC_BYTES(n)              (ROXY_PD_SYMBOL->system->realloc(NULL, (n)))
    #define ROXY_ALLOC_BYTES_LABEL(n,label)  (ROXY_PD_SYMBOL->system->realloc(NULL, (n)))

    #define ROXY_HG_VERIFY() ((void)0)
    #define ROXY_HG_DUMP()   ((void)0)

#endif

#endif /* ROXY_HEAP_GUARD_H */
