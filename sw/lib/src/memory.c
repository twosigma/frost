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
 * memory.c: heap allocation for bare-metal use, two ways.
 *
 * 1. Arena: bump-pointer allocation, reset in bulk with arena_clear(), for
 *    allocations that share a lifetime (per frame, per request).
 *
 * 2. malloc/free: first-fit freelist allocator that coalesces adjacent free
 *    blocks, for allocations with mixed lifetimes.
 *
 * Both draw from one bounds-checked bump-pointer heap that grows from
 * _heap_start toward _heap_end (both defined in the linker script). _sbrk()
 * exposes the same heap to bare-metal callers. It never shrinks the heap and
 * returns NULL, not (char *) -1, on failure.
 */

#include "memory.h"
#include "string.h"

#include <stddef.h>
#include <stdint.h>

/* Diagnostic build switches for free(), all off by default. */
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

/* The heap bounds can live in the DDR region while this library's text sits
 * in low BRAM. At rv64 neither PC-relative (medany) nor absolute-HI20 (medlow)
 * address materialization spans that gap, so the bounds are held as link-time
 * R_RISCV_64 pointer values, which have no reach limit. The volatile qualifier
 * stops -O3 from folding them back into direct symbol references. */
static char *volatile heap_start_p = &_heap_start;
static char *volatile heap_end_p = &_heap_end;

static char *heap_mark = &_heap_start;

static char *heap_grow(size_t increment)
{
    uintptr_t mark = (uintptr_t) heap_mark;
    uintptr_t end = (uintptr_t) heap_end_p;

    if (mark > end || increment > end - mark) {
        return NULL;
    }

    char *prev_heap = heap_mark;
    heap_mark = (char *) (mark + increment);
    return prev_heap;
}

char *_sbrk(int incr)
{
    if (incr < 0)
        return NULL;
    return heap_grow((size_t) incr);
}

arena_t arena_alloc(uint32_t size)
{
    char *start = heap_grow(size);
    return (arena_t){.start = start, .pos = 0, .capacity = start != NULL ? size : 0};
}

/* Malloc alignment granule. It must hold a struct free_slot (pointer + size),
 * so it scales with the pointer width: 16 at lp64, which is also the lp64d ABI
 * maximum alignment. */
#define DEFAULT_ALIGN ((size_t) (2 * sizeof(void *)))
#define ALIGNED_METADATA_SIZE DEFAULT_ALIGN

static int align_size_up(size_t value, size_t align, size_t *result)
{
    if (value > SIZE_MAX - (align - 1U))
        return 0;
    *result = (value + align - 1U) & ~(align - 1U);
    return 1;
}

#if FROST_MALLOC_EVICT_FREE
/* Entries in the load queue's direct-mapped L0 (riscv_pkg::LqL0Depth, frost's
 * L0_CACHE_DEPTH); this must not be below the hardware's depth. An entry
 * holds one aligned dword, so address bits [3, 3 + log2(depth)) index it and
 * the bits above are its tag. */
#ifndef FROST_MALLOC_EVICT_L0_DEPTH
#define FROST_MALLOC_EVICT_L0_DEPTH 128
#endif
_Static_assert(FROST_MALLOC_EVICT_L0_DEPTH >= 8 &&
                   (FROST_MALLOC_EVICT_L0_DEPTH & (FROST_MALLOC_EVICT_L0_DEPTH - 1)) == 0,
               "the L0 depth is a power of two of at least 8");
#define L0_BYTES ((uintptr_t) 8 * FROST_MALLOC_EVICT_L0_DEPTH)
/* The heap lies in the 1 GiB DDR region, which is aligned to its size, so an
 * address with one bit below 30 flipped stays inside it. */
#define L0_ALIAS_LIMIT ((uintptr_t) 1 << 29)

/*
 * Evict the dwords of [start, start + size) from the L0 without a
 * cache-management instruction: load an alias of each dword that differs in
 * one tag bit, so it indexes the same entry and its fill replaces the freed
 * dword. The flipped bit is worth at least the range's span, counted from the
 * dword that holds start, which puts every alias outside the range, so no load
 * here reinstalls a freed dword (for spans up to L0_ALIAS_LIMIT). A range
 * longer than the L0 needs one load per entry.
 * Best effort: a load answered by store forwarding, or whose fill a store or
 * DMA write suppresses, leaves its entry in place.
 */
static void evict_l0_dwords_for_range(uintptr_t start, uint32_t size)
{
    volatile uint32_t sink = 0;
    uintptr_t first = start & ~(uintptr_t) 7;
    uintptr_t span = start + size - first;
    uintptr_t alias = L0_BYTES;
    uintptr_t count = span < L0_BYTES ? (span + 7) / 8 : FROST_MALLOC_EVICT_L0_DEPTH;

    while (alias < span && alias < L0_ALIAS_LIMIT)
        alias <<= 1;
    for (uintptr_t i = 0; i < count; i++) {
        sink ^= *(volatile uint32_t *) ((first + 8 * i) ^ alias);
    }

    __asm__ volatile("" : : "r"(sink) : "memory");
}
#endif

char *arena_push_align(arena_t *arena, uint32_t size, uint8_t align)
{
    if (arena == NULL || arena->start == NULL || arena->pos > arena->capacity || align == 0 ||
        (align & (align - 1U)) != 0) {
        return NULL;
    }

    uintptr_t start = (uintptr_t) arena->start;
    if (arena->pos > UINTPTR_MAX - start)
        return NULL;

    uintptr_t current = start + arena->pos;
    uintptr_t padding = (-(uintptr_t) current) & ((uintptr_t) align - 1U);
    uint32_t remaining = arena->capacity - arena->pos;
    if (padding > remaining || size > remaining - (uint32_t) padding)
        return NULL;

    arena->pos += (uint32_t) padding + size;
    return (char *) (current + padding);
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
    /* No-op. The heap is a bump pointer (heap_grow/_sbrk) and cannot reclaim a
     * region from the middle. Arenas suit allocations that last the whole program
     * or are reset in bulk with arena_clear(); use malloc/free when individual
     * blocks must be returned. */
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

    size_t aligned_payload;
    if (!align_size_up(size, DEFAULT_ALIGN, &aligned_payload) ||
        aligned_payload > UINT32_MAX - ALIGNED_METADATA_SIZE) {
        return NULL;
    }

    /* Allocate using a first-fit algorithm. Block sizes include the aligned
     * metadata prefix and always fit in the uint32_t stored in that prefix. */
    struct free_slot **p = &freelist;
    uint32_t block_size = (uint32_t) (aligned_payload + ALIGNED_METADATA_SIZE);

    char *result = NULL;
    while (*p != NULL) {
        struct free_slot *slot = *p;

        if (block_size <= slot->size) {
            /* Carve the block from the end of the slot so the slot's header stays
             * in place. Block and slot sizes are multiples of DEFAULT_ALIGN, so a
             * nonzero remainder still holds a struct free_slot. */
            slot->size -= block_size;
            result = (char *) slot + slot->size + ALIGNED_METADATA_SIZE;

            if (slot->size == 0) {
                /* Delete this node from the freelist */
                *p = slot->next;
            }
            break;
        }

        p = &(*p)->next;
    }

    if (result == NULL) {
        size_t padding = (-(uintptr_t) heap_mark) & (DEFAULT_ALIGN - 1U);
        if (block_size > SIZE_MAX - padding)
            return NULL;
        char *raw = heap_grow((size_t) block_size + padding);
        if (raw == NULL)
            return NULL;
        result = raw + padding + ALIGNED_METADATA_SIZE;
    }

    struct metadata *md = (struct metadata *) result - 1;
    *md = (struct metadata){.size = block_size};

    return result;
}

static void freelist_insert_and_coalesce(struct free_slot *slot)
{
    struct free_slot *previous = NULL;
    struct free_slot **link = &freelist;
    uintptr_t slot_address = (uintptr_t) slot;

    while (*link != NULL && (uintptr_t) *link < slot_address) {
        previous = *link;
        link = &(*link)->next;
    }

    slot->next = *link;
    *link = slot;

    if (slot->next != NULL && slot_address + slot->size == (uintptr_t) slot->next) {
        slot->size += slot->next->size;
        slot->next = slot->next->next;
    }

    if (previous != NULL && (uintptr_t) previous + previous->size == slot_address) {
        previous->size += slot->size;
        previous->next = slot->next;
    }
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
    uintptr_t header_size = ALIGNED_METADATA_SIZE;
#if FROST_MALLOC_GUARD_FREE
    /* Diagnostic mode: silently ignore a pointer that is misaligned or outside
     * the allocated heap, or whose size header is misaligned, smaller than the
     * header, or runs past heap_mark. */
    uintptr_t payload = (uintptr_t) ptr;
    uintptr_t heap_start = (uintptr_t) heap_start_p;
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
    evict_l0_dwords_for_range((uintptr_t) ptr - header_size, block_size);
#endif

    struct free_slot *slot = ptr - header_size;
    slot->size = block_size;
    freelist_insert_and_coalesce(slot);
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
     * block, so the copy covers exactly the old payload and never reads past
     * its end. */
    struct metadata *md = (struct metadata *) ptr - 1;
    uint32_t old_payload = md->size - ALIGNED_METADATA_SIZE;

    if (size <= old_payload)
        return ptr;

    /* Grow to twice the old payload when that fits, else to exactly size. With
     * a 32-bit size_t the doubling can wrap, which leaves it below old_payload. */
    size_t new_size = size;
    size_t doubled = (size_t) old_payload * 2u;
    if (doubled >= old_payload && doubled > new_size)
        new_size = doubled;

    void *newp = malloc(new_size);
    if (newp == NULL && new_size != size)
        newp = malloc(size);
    if (newp == NULL)
        return NULL;

    memcpy(newp, ptr, old_payload);
    free(ptr);
    return newp;
}
