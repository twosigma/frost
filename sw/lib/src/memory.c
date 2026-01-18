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
#include <stdint.h>
#define NULL 0x0

/* NOLINTNEXTLINE(bugprone-reserved-identifier) */
extern char _heap_start;
/* NOLINTNEXTLINE(bugprone-reserved-identifier) */
extern char _heap_end;

static char *heap_mark = &_heap_start;
char *_sbrk(int incr)
{
    if (incr <= 0) {
        return NULL;  /* Reject negative or zero increments */
    }
    
    char *prev_heap = heap_mark;
    char *new_heap = heap_mark + incr;
    
    /* Check for overflow in pointer arithmetic */
    if (new_heap < heap_mark) {
        return NULL;  /* Pointer overflow */
    }
    
    if (new_heap > &_heap_end) {
        return NULL;  /* Exceeds heap boundary */
    }
    
    heap_mark = new_heap;
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

char *arena_push_align(arena_t *arena, uint32_t size, uint8_t align)
{
    if (arena == NULL || arena->start == NULL || align == 0) {
        return NULL;
    }
    
    /* Ensure alignment is power of two */
    if ((align & (align - 1)) != 0) {
        return NULL;
    }
    
    /* Align the actual pointer address, not just the position within the arena */
    char *p = (char *) ALIGN((uintptr_t) (arena->start + arena->pos), align);
    uint32_t new_pos = (uint32_t) (p - arena->start) + size;

    /* Check for overflow in size calculation */
    if (size > UINT32_MAX - (p - arena->start)) {
        return NULL;
    }
    
    /* Bounds check: ensure allocation fits within arena capacity */
    if (arena->pos > UINT32_MAX - (new_pos - arena->pos) || 
        new_pos > arena->capacity) {
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
    char *p = arena_push(arena, size);
    for (uint32_t i = 0; i < size; i++) {
        p[i] = 0;
    }
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
    // Intentionally a no-op: This bare-metal allocator uses a simple bump-pointer
    // heap (_sbrk), which cannot reclaim memory from the middle. Arenas are designed
    // for long-lived allocations (e.g., entire program lifetime) or bulk deallocation
    // via arena_clear(). For short-lived allocations that need true deallocation,
    // use malloc/free instead.
}

/// MALLOC ///

struct free_slot {
    struct free_slot *next;
    uint32_t size;
};

_Static_assert(sizeof(struct free_slot) == DEFAULT_ALIGN,
               "Can't fit a free slot int he minimum space that malloc aligns to");

static struct free_slot *freelist = NULL;

struct metadata {
    uint32_t size;
};

void *malloc(uint32_t size)
{
    if (size == 0) {
        return NULL;
    }

    // allocate using a first-fit algorithm
    struct free_slot **p = &freelist;
    uint32_t block_size =
        ALIGN(size, DEFAULT_ALIGN) + ALIGN(sizeof(struct metadata), DEFAULT_ALIGN);

    char *result = NULL;
    while (*p != NULL) {
        struct free_slot *slot = *p;

        if (block_size <= slot->size) {
            // shrink down free slot
            slot->size -= block_size;
            result = (char *) slot + slot->size + ALIGN(sizeof(struct metadata), DEFAULT_ALIGN);

            if (slot->size == 0) {
                // delete this node from the freelist
                *p = slot->next;
            }
            break;
        }

        p = &(*p)->next;
    }

    if (result == NULL) {
        result = ((void *) ALIGN((uintptr_t) _sbrk(block_size + ALIGN_PADDING((uintptr_t) heap_mark,
                                                                              DEFAULT_ALIGN)),
                                 DEFAULT_ALIGN)) +
                 ALIGN(sizeof(struct metadata), DEFAULT_ALIGN);
    }

    // write metadata
    struct metadata *md = (struct metadata *) result - 1;
    *md = (struct metadata) {.size = block_size};

    return result;
}

void free(void *ptr)
{
    struct free_slot *slot = ptr - ALIGN(sizeof(struct metadata), DEFAULT_ALIGN);
    slot->next = freelist;
    struct metadata *md = ptr;
    slot->size = (md - 1)->size;
    freelist = slot;
}
