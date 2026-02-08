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

#ifndef MEMORY_H
#define MEMORY_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    char *const start;
    uint32_t pos;
    uint32_t capacity;
} arena_t;

/* Create a new arena on the heap. */
arena_t arena_alloc(uint32_t size);
/* Release the arena. No-op on this bare-metal platform (see memory.c for details). */
void arena_release(arena_t *arena);

/* Allocate `size` bytes on arena. 8 byte aligned. Returns NULL if out of space. */
void *arena_push(arena_t *arena, uint32_t size);
/* Allocate `size` bytes on arena and zero the data. 8 byte aligned. */
void *arena_push_zero(arena_t *arena, uint32_t size);
/* Push to arena with `align` byte alignment of the returned pointer. `align` must be a power of 2.
 */
char *arena_push_align(arena_t *arena, uint32_t size, uint8_t align);

/* Pop `size` bytes from the end of an arena. */
void arena_pop(arena_t *arena, uint32_t size);
/* Clear all bytes from arena. */
void arena_clear(arena_t *arena);

void *malloc(size_t size);
void free(void *ptr);

#endif /* MEMORY_H */
