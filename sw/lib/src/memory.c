/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/**
 * Memory Allocator (memory.c)
 *
 * Dynamic memory allocation for bare-metal use. Provides two allocation
 * strategies:
 *
 * 1. Arena Allocator - Fast bump-pointer allocation with bulk deallocation.
 *    Best for allocations with uniform lifetime (e.g., per-frame or per-request).
 *
 * 2. malloc/free - Traditional freelist allocator with first-fit strategy.
 *    Best for allocations with varied lifetimes.
 *
 * Both allocators use _sbrk() to request memory from a simple heap that grows
 * from _heap_start toward _heap_end (defined in the linker script).
 */

#include "memory.h"
#include "string.h"

#include <stddef.h>
#include <stdint.h>

#ifndef FROST_MALLOC_DISABLE_FREE
#define FROST_MALLOC_DISABLE_FREE 0
#endif
#ifndef FROST_MALLOC_GUARD_FREE
#define FROST_MALLOC_GUARD_FREE 0
#endif
#ifndef FROST_MALLOC_EVICT_FREE
#define FROST_MALLOC_EVICT_FREE 0
#endif

/* NOLINTNEXTLINE(bugprone-reserved-identifier) */
extern char _heap_start;
/* NOLINTNEXTLINE(bugprone-reserved-identifier) */
extern char _heap_end;

static char *heap_mark = &_heap_start;
char *_sbrk(int incr)
{
    char *prev_heap = heap_mark;
    if (heap_mark + incr > &_heap_end) {
        return NULL;
    }
    heap_mark += incr;
    return prev_heap;
}


arena_t arena_alloc(uint32_t size)
{
    return (arena_t) {
        .start = _sbrk((int) size),
        .pos = 0,
        .capacity = size,
    };
}

#define DEFAULT_ALIGN sizeof(long long)
#define ALIGN(ptr, align) (((ptr) + ((align) - 1)) & ~((align) - 1))
#define ALIGN_PADDING(ptr, align) (ALIGN(ptr, align) - (ptr))

#if FROST_MALLOC_EVICT_FREE
static void evict_l0_words_for_range(uintptr_t start, uint32_t size)
{
    volatile uint32_t sink = 0;
    uintptr_t end = start + size;
    start &= ~(uintptr_t) (sizeof(uint32_t) - 1);

    /*
     * FROST's load-queue L0 is direct-mapped and indexed by address bits [8:2].
     * Toggling bit 9 preserves the index and changes the tag, forcing the word
     * entry out without needing hardware support for explicit cache management.
     */
    for (uintptr_t addr = start; addr < end; addr += sizeof(uint32_t)) {
        sink ^= *(volatile uint32_t *) (addr ^ 0x200u);
    }

    __asm__ volatile("" : : "r"(sink) : "memory");
}
#endif

char *arena_push_align(arena_t *arena, uint32_t size, uint8_t align)
{
    /* Align the actual pointer address, not just the position within the arena */
    char *p = (char *) ALIGN((uintptr_t) (arena->start + arena->pos), align);
    uint32_t new_pos = (uint32_t) (p - arena->start) + size;

    /* Bounds check: ensure allocation fits within arena capacity */
    if (new_pos > arena->capacity) {
        return NULL;
    }

    arena->pos = new_pos;
    return p;
}

void *arena_push(arena_t *arena, uint32_t size)
{
    void *p = arena_push_align(arena, size, DEFAULT_ALIGN);
    return p;
}

void *arena_push_zero(arena_t *arena, uint32_t size)
{
    void *p = arena_push(arena, size);
    if (p != NULL)
        memset(p, 0, size);
    return p;
}

void arena_pop(arena_t *arena, uint32_t size)
{
    arena->pos = arena->pos >= size ? arena->pos - size : 0;
}

void arena_clear(arena_t *arena)
{
    arena->pos = 0;
}

void arena_release(arena_t *arena)
{
    (void) arena;
    /* Intentionally a no-op: This bare-metal allocator uses a simple bump-pointer
     * heap (_sbrk), which cannot reclaim memory from the middle. Arenas are designed
     * for long-lived allocations (e.g., entire program lifetime) or bulk deallocation
     * via arena_clear(). For short-lived allocations that need true deallocation,
     * use malloc/free instead. */
}

/* ========================================================================== */
/* malloc / free                                                              */
/* ========================================================================== */

struct free_slot {
    struct free_slot *next;
    uint32_t size;
};

_Static_assert(sizeof(struct free_slot) == DEFAULT_ALIGN,
               "Can't fit a free slot in the minimum space that malloc aligns to");

static struct free_slot *freelist = NULL;

struct metadata {
    uint32_t size;
};

void *malloc(size_t size)
{
    if (size == 0) {
        return NULL;
    }

    /* Allocate using a first-fit algorithm */
    struct free_slot **p = &freelist;
    uint32_t block_size =
        ALIGN(size, DEFAULT_ALIGN) + ALIGN(sizeof(struct metadata), DEFAULT_ALIGN);

    char *result = NULL;
    while (*p != NULL) {
        struct free_slot *slot = *p;

        if (block_size <= slot->size) {
            /* Shrink down free slot */
            slot->size -= block_size;
            result = (char *) slot + slot->size + ALIGN(sizeof(struct metadata), DEFAULT_ALIGN);

            if (slot->size == 0) {
                /* Delete this node from the freelist */
                *p = slot->next;
            }
            break;
        }

        p = &(*p)->next;
    }

    if (result == NULL) {
        char *raw = _sbrk(block_size + ALIGN_PADDING((uintptr_t) heap_mark, DEFAULT_ALIGN));
        if (raw == NULL)
            return NULL;
        result = (char *) ALIGN((uintptr_t) raw, DEFAULT_ALIGN) +
                 ALIGN(sizeof(struct metadata), DEFAULT_ALIGN);
    }

    /* Write metadata */
    struct metadata *md = (struct metadata *) result - 1;
    *md = (struct metadata) {.size = block_size};

    return result;
}

void free(void *ptr)
{
    if (ptr == NULL)
        return;
#if FROST_MALLOC_DISABLE_FREE
    /*
     * Diagnostic mode for one-shot heap-heavy bare-metal workloads.  Leaking
     * freed blocks avoids allocator reuse while leaving malloc/realloc call
     * sites intact, which helps isolate stale-cache/reuse corruption.
     */
    (void) ptr;
#else
    uintptr_t header_size = ALIGN(sizeof(struct metadata), DEFAULT_ALIGN);
#if FROST_MALLOC_GUARD_FREE
    uintptr_t payload = (uintptr_t) ptr;
    uintptr_t heap_start = (uintptr_t) &_heap_start;
    uintptr_t heap_limit = (uintptr_t) heap_mark;

    if ((payload & (DEFAULT_ALIGN - 1)) != 0 || payload < heap_start + header_size ||
        payload > heap_limit) {
        return;
    }

    struct metadata *guard_md = (struct metadata *) ptr - 1;
    uint32_t guarded_size = guard_md->size;
    if ((guarded_size & (DEFAULT_ALIGN - 1)) != 0 || guarded_size < header_size ||
        guarded_size > heap_limit - (payload - header_size)) {
        return;
    }
#endif
    struct metadata *md = (struct metadata *) ptr - 1;
    uint32_t block_size = md->size;

#if FROST_MALLOC_EVICT_FREE
    evict_l0_words_for_range((uintptr_t) ptr - header_size, block_size);
#endif

    struct free_slot *slot = ptr - header_size;
    slot->next = freelist;
    slot->size = block_size;
    freelist = slot;
#endif
}

/* Allocate and zero an array of nmemb elements of `size` bytes each. */
void *calloc(size_t nmemb, size_t size)
{
    size_t total = nmemb * size;
    /* Reject multiplication overflow. */
    if (nmemb != 0 && total / nmemb != size)
        return NULL;
    void *p = malloc(total);
    if (p != NULL)
        memset(p, 0, total);
    return p;
}

/* Resize a previously malloc'd block, preserving its existing contents. */
void *realloc(void *ptr, size_t size)
{
    if (ptr == NULL)
        return malloc(size);
    if (size == 0) {
        free(ptr);
        return NULL;
    }

    /* Recover the old payload size from the metadata malloc wrote ahead of the
     * block, so we copy exactly the still-live bytes (never past the old end). */
    struct metadata *md = (struct metadata *) ptr - 1;
    uint32_t old_payload = md->size - ALIGN(sizeof(struct metadata), DEFAULT_ALIGN);

    if (size <= old_payload)
        return ptr;

    size_t new_size = size;
    if (old_payload <= (SIZE_MAX / 2u) && (size_t) old_payload * 2u > new_size)
        new_size = (size_t) old_payload * 2u;

    void *newp = malloc(new_size);
    if (newp == NULL)
        return NULL;

    memcpy(newp, ptr, old_payload);
    free(ptr);
    return newp;
}
