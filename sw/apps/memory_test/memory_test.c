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
 * Memory Library Test Suite
 *
 * Tests the arena allocator and malloc/free implementations:
 *   - arena_alloc: Create arena from heap
 *   - arena_push: Allocate with default alignment
 *   - arena_push_zero: Allocate and zero-initialize
 *   - arena_push_align: Allocate with custom alignment
 *   - arena_pop: Deallocate from arena end
 *   - arena_clear: Reset arena position
 *   - malloc: Dynamic memory allocation
 *   - free: Return memory to freelist
 *   - calloc/realloc: Standard allocation helpers and overflow handling
 */

#include "memory.h"
#include "string.h"
#include "uart.h"
#include <stdint.h>

/* Test result tracking */
static uint32_t tests_passed = 0;
static uint32_t tests_failed = 0;

/* Report test result */
static void check(const char *name, int condition)
{
    if (condition) {
        tests_passed++;
        uart_printf("  PASS: %s\n", name);
    } else {
        tests_failed++;
        uart_printf("  FAIL: %s\n", name);
    }
}

/* Test arena_alloc function */
static void test_arena_alloc(void)
{
    uart_printf("\n=== arena_alloc ===\n");

    arena_t arena = arena_alloc(1024);

    check("arena created", arena.start != 0);
    check("arena position zero", arena.pos == 0);
    check("arena capacity correct", arena.capacity == 1024);

    arena_t too_large = arena_alloc(UINT32_MAX);
    check("oversized arena rejected", too_large.start == NULL);
    check("failed arena has zero capacity", too_large.capacity == 0);
}

/* Test arena_push function */
static void test_arena_push(void)
{
    uart_printf("\n=== arena_push ===\n");

    arena_t arena = arena_alloc(256);

    /* First allocation */
    void *p1 = arena_push(&arena, 16);
    check("first alloc non-null", p1 != 0);
    check("first alloc at start", p1 == arena.start);
    check("position after first", arena.pos == 16);

    /* Second allocation */
    void *p2 = arena_push(&arena, 8);
    check("second alloc non-null", p2 != 0);
    check("second alloc after first", (uintptr_t) p2 == (uintptr_t) p1 + 16);
    check("position after second", arena.pos == 24);

    /* Third allocation. The arena aligns each push to the malloc granule
     * (2*sizeof(void*): 8 on rv32, 16 on lp64), so the position after a
     * 32-byte push from pos 24 is granule-dependent. */
    void *p3 = arena_push(&arena, 32);
    check("third alloc non-null", p3 != 0);
    {
        uintptr_t granule = 2 * sizeof(void *);
        uintptr_t aligned24 = (24u + granule - 1u) & ~(granule - 1u);
        check("position after third", arena.pos == aligned24 + 32u);
    }

    /* Check 8-byte alignment */
    check("p1 aligned to 8", ((uintptr_t) p1 % 8) == 0);
    check("p2 aligned to 8", ((uintptr_t) p2 % 8) == 0);
    check("p3 aligned to 8", ((uintptr_t) p3 % 8) == 0);
}

/* Test arena_push_zero function */
static void test_arena_push_zero(void)
{
    uart_printf("\n=== arena_push_zero ===\n");

    arena_t arena = arena_alloc(256);

    /* Allocate and zero 16 bytes */
    char *p = arena_push_zero(&arena, 16);
    check("alloc non-null", p != 0);
    check("position correct", arena.pos == 16);

    /* Verify all bytes are zero */
    int all_zero = 1;
    for (int i = 0; i < 16; i++) {
        if (p[i] != 0) {
            all_zero = 0;
            break;
        }
    }
    check("memory zeroed", all_zero);

    /* Allocate larger block */
    char *p2 = arena_push_zero(&arena, 64);
    check("large alloc non-null", p2 != 0);

    all_zero = 1;
    for (int i = 0; i < 64; i++) {
        if (p2[i] != 0) {
            all_zero = 0;
            break;
        }
    }
    check("large block zeroed", all_zero);
}

/* Test arena_push_align function */
static void test_arena_push_align(void)
{
    uart_printf("\n=== arena_push_align ===\n");

    arena_t arena = arena_alloc(256);

    /* Allocate with 16-byte alignment */
    char *p1 = arena_push_align(&arena, 8, 16);
    check("16-align non-null", p1 != 0);
    check("16-align correct", ((uintptr_t) p1 % 16) == 0);

    /* Allocate with 32-byte alignment */
    char *p2 = arena_push_align(&arena, 8, 32);
    check("32-align non-null", p2 != 0);
    check("32-align correct", ((uintptr_t) p2 % 32) == 0);

    /* Allocate with 4-byte alignment */
    char *p3 = arena_push_align(&arena, 8, 4);
    check("4-align non-null", p3 != 0);
    check("4-align correct", ((uintptr_t) p3 % 4) == 0);

    uint32_t position = arena.pos;
    check("zero alignment rejected", arena_push_align(&arena, 8, 0) == NULL);
    check("non-power-of-two rejected", arena_push_align(&arena, 8, 3) == NULL);
    check("invalid alignment preserves position", arena.pos == position);
    check("out-of-space rejected", arena_push_align(&arena, 256, 8) == NULL);
    check("out-of-space preserves position", arena.pos == position);
}

/* Test arena_pop function */
static void test_arena_pop(void)
{
    uart_printf("\n=== arena_pop ===\n");

    arena_t arena = arena_alloc(256);

    /* Push some data */
    arena_push(&arena, 32);
    arena_push(&arena, 16);
    check("position after pushes", arena.pos == 48);

    /* Pop 16 bytes */
    arena_pop(&arena, 16);
    check("position after pop 16", arena.pos == 32);

    /* Pop 16 more bytes */
    arena_pop(&arena, 16);
    check("position after pop 32", arena.pos == 16);

    /* Pop remaining */
    arena_pop(&arena, 16);
    check("position after pop all", arena.pos == 0);
}

/* Test arena_clear function */
static void test_arena_clear(void)
{
    uart_printf("\n=== arena_clear ===\n");

    arena_t arena = arena_alloc(256);

    /* Push some data */
    arena_push(&arena, 64);
    arena_push(&arena, 32);
    check("position before clear", arena.pos == 96);

    /* Clear arena */
    arena_clear(&arena);
    check("position after clear", arena.pos == 0);
    check("capacity unchanged", arena.capacity == 256);
    check("start unchanged", arena.start != 0);
}

/* Test malloc function */
static void test_malloc(void)
{
    uart_printf("\n=== malloc ===\n");

    /* Basic allocation */
    void *p1 = malloc(16);
    check("malloc(16) non-null", p1 != 0);
    check("malloc(16) aligned", ((uintptr_t) p1 % 8) == 0);

    /* Another allocation */
    void *p2 = malloc(32);
    check("malloc(32) non-null", p2 != 0);
    check("malloc(32) aligned", ((uintptr_t) p2 % 8) == 0);
    check("allocations different", p1 != p2);

    /* Small allocation */
    void *p3 = malloc(1);
    check("malloc(1) non-null", p3 != 0);
    check("malloc(1) aligned", ((uintptr_t) p3 % 8) == 0);

    /* Zero allocation returns NULL */
    void *p4 = malloc(0);
    check("malloc(0) returns null", p4 == 0);

    /* Write to allocated memory */
    memset(p1, 0xAA, 16);
    memset(p2, 0xBB, 32);
    check("can write to p1", ((char *) p1)[0] == (char) 0xAA);
    check("can write to p2", ((char *) p2)[0] == (char) 0xBB);

    /* Rounding the request and adding metadata must not wrap on RV32. */
    check("malloc(SIZE_MAX) rejected", malloc(SIZE_MAX) == NULL);
    check("malloc near SIZE_MAX rejected", malloc(SIZE_MAX - 3U) == NULL);
}

/* Test a two-sided free-block merge. These allocations come from the fresh
 * heap because this runs before any successful free. */
static void test_malloc_coalescing(void)
{
    uart_printf("\n=== malloc coalescing ===\n");

    void *left = malloc(16);
    void *middle = malloc(16);
    void *right = malloc(16);
    void *canary = malloc(16);
    int allocated = left != NULL && middle != NULL && right != NULL && canary != NULL;
    check("coalesce blocks allocated", allocated);
    if (!allocated) {
        free(left);
        free(middle);
        free(right);
        free(canary);
        return;
    }

    memset(canary, 0x5A, 16);
    free(left);
    free(right);
    free(middle);

    /* Three 16-byte payloads plus their metadata coalesce into one free
     * region; request the payload that refills it exactly (the metadata
     * slot is the malloc granule, 2*sizeof(void*), so the exact-refit size
     * is width-dependent: 64 on rv32, 80 on lp64). */
    size_t granule = 2 * sizeof(void *);
    void *combined = malloc(3u * (granule + 16u) - granule);
    check("both neighbors combined", combined == left);
    check("neighbor remains intact", ((unsigned char *) canary)[0] == 0x5A);

    free(combined);
    free(canary);
}

/* Test free function */
static void test_free(void)
{
    uart_printf("\n=== free ===\n");

    /* Allocate some memory */
    void *p1 = malloc(16);
    void *p2 = malloc(16);
    check("p1 allocated", p1 != 0);
    check("p2 allocated", p2 != 0);

    /* Free first allocation */
    free(p1);
    check("p1 freed", 1); /* No crash means success */

    /* Allocate again - should reuse freed memory */
    void *p3 = malloc(16);
    check("p3 allocated", p3 != 0);

    /* Free remaining */
    free(p2);
    free(p3);
    check("all freed", 1);
}

/* Test malloc/free reuse */
static void test_malloc_reuse(void)
{
    uart_printf("\n=== malloc reuse ===\n");

    /* Allocate and free several blocks */
    void *blocks[4];
    for (int i = 0; i < 4; i++) {
        blocks[i] = malloc(8);
        check("block allocated", blocks[i] != 0);
    }

    /* Free all blocks */
    for (int i = 0; i < 4; i++) {
        free(blocks[i]);
    }

    /* Allocate again - should reuse freed memory */
    void *new_blocks[4];
    for (int i = 0; i < 4; i++) {
        new_blocks[i] = malloc(8);
        check("realloc non-null", new_blocks[i] != 0);
    }

    /* Clean up */
    for (int i = 0; i < 4; i++) {
        free(new_blocks[i]);
    }
}

static void test_calloc_realloc(void)
{
    uart_printf("\n=== calloc/realloc ===\n");

    unsigned char *zeroed = calloc(8, 4);
    check("calloc allocated", zeroed != NULL);
    check("calloc overflow rejected", calloc(SIZE_MAX / 2U + 1U, 2) == NULL);
    if (zeroed == NULL)
        return;

    int all_zero = 1;
    for (int i = 0; i < 32; i++) {
        if (zeroed[i] != 0) {
            all_zero = 0;
            break;
        }
    }
    check("calloc zeroed", all_zero);

    for (int i = 0; i < 32; i++)
        zeroed[i] = (unsigned char) i;
    unsigned char *grown = realloc(zeroed, 80);
    check("realloc grow allocated", grown != NULL);
    if (grown == NULL) {
        free(zeroed);
        return;
    }
    check("realloc grow preserves data", grown[0] == 0 && grown[31] == 31);

    void *failed = realloc(grown, SIZE_MAX);
    check("realloc overflow rejected", failed == NULL);
    if (failed != NULL) {
        free(failed);
        return;
    }
    check("failed realloc preserves original", grown[1] == 1 && grown[31] == 31);
    free(grown);
}

int main(void)
{
    uart_printf("Memory Library Test Suite\n");
    uart_printf("=========================\n");

    test_arena_alloc();
    test_arena_push();
    test_arena_push_zero();
    test_arena_push_align();
    test_arena_pop();
    test_arena_clear();
    test_malloc();
    test_malloc_coalescing();
    test_free();
    test_malloc_reuse();
    test_calloc_realloc();

    uart_printf("\n=========================\n");
    uart_printf("Results: %lu passed, %lu failed\n",
                (unsigned long) tests_passed,
                (unsigned long) tests_failed);

    if (tests_failed == 0) {
        uart_printf("ALL TESTS PASSED\n");
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("SOME TESTS FAILED\n");
        uart_printf("<<FAIL>>\n");
    }

    /* Halt */
    for (;;) {
    }
}
