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
 * Cached-region (DDR) heap capacity test
 *
 * Proves that the FROST allocator (sw/lib memory.c _sbrk/malloc) can hand out
 * multi-megabyte chunks from the DDR-backed cached region -- allocations far
 * larger than the old 2 MiB URAM tier could ever satisfy -- and that data
 * written across the whole chunk reads back correctly through the cache
 * hierarchy. This is the capacity that unblocks the remaining CoreMark-PRO
 * workloads (loops ~6 MiB and zip ~3.3 MiB heaps).
 *
 * The unified linker script (sw/common/link.ld) places the heap at
 * CACHED_BASE = 0x8000_0000 with ~1 GiB of room; code/data/stack stay in the
 * low BRAM. (The behavioral DDR model in simulation is 64 MiB by default --
 * plenty for the 9 MiB exercised here.)
 *
 * Checks:
 *   1. malloc(8 MiB) succeeds and returns a pointer inside the cached region
 *      (8 MiB = larger than the loops workload's ~6 MiB demand, and 4x the L2).
 *   2. A pattern written sparsely across the whole 8 MiB (one word per 4 KiB,
 *      plus the very last word) reads back correctly -> the full chunk is
 *      backed by distinct, addressable memory (catches address aliasing).
 *   3. A second malloc(1 MiB) also lands in the region, does not overlap the
 *      first, and writing it leaves the first allocation intact.
 *
 * To keep the simulation fast the verification is sparse (~2k points across
 * 8 MiB) rather than touching every word. Prints "<<PASS>>" / "<<FAIL>>".
 */

#include <stddef.h>
#include <stdint.h>

#include "memory.h"
#include "uart.h"

#define CACHED_BASE 0x80000000u
#define CACHED_END 0xC0000000u /* CACHED_BASE + 1 GiB */

#define BIG_BYTES (8u * 1024u * 1024u) /* 8 MiB primary allocation */
#define SECOND_BYTES (1024u * 1024u)   /* 1 MiB secondary allocation */
#define STRIDE_WORDS 1024u             /* verify one word per 4 KiB */

static int in_ddr(const void *p)
{
    uintptr_t a = (uintptr_t) p;
    return (a >= CACHED_BASE) && (a < CACHED_END);
}

/* Distinct value per word index so aliasing across the chunk is detectable. */
static uint32_t pattern(uint32_t word_index)
{
    return 0xA5000000u ^ word_index;
}

int main(void)
{
    int failures = 0;

    uart_printf("DDR heap (malloc) capacity test\n");
    uart_printf("===============================\n");

    /* --- 1: large allocation, must come from the cached region. ----------- */
    volatile uint32_t *p = (volatile uint32_t *) malloc(BIG_BYTES);
    const uint32_t nwords = BIG_BYTES / 4u;

    if (p == NULL) {
        uart_printf("malloc(%lu) returned NULL FAIL\n", (unsigned long) BIG_BYTES);
        failures++;
    } else if (!in_ddr((const void *) p)) {
        uart_printf("malloc(%lu) = 0x%08lx NOT in cached region FAIL\n",
                    (unsigned long) BIG_BYTES,
                    (unsigned long) p);
        failures++;
    } else {
        uart_printf(
            "malloc(%lu) = 0x%08lx (DDR) OK\n", (unsigned long) BIG_BYTES, (unsigned long) p);

        /* --- 2: sparse write then read-back across the whole 8 MiB. -------- */
        for (uint32_t i = 0; i < nwords; i += STRIDE_WORDS) {
            p[i] = pattern(i);
        }
        p[nwords - 1u] = 0xDEADBEEFu; /* boundary word */

        for (uint32_t i = 0; i < nwords; i += STRIDE_WORDS) {
            uint32_t got = p[i];
            if (got != pattern(i)) {
                uart_printf("verify word=%lu want=0x%08lx got=0x%08lx FAIL\n",
                            (unsigned long) i,
                            (unsigned long) pattern(i),
                            (unsigned long) got);
                failures++;
                break;
            }
        }
        if (p[nwords - 1u] != 0xDEADBEEFu) {
            uart_printf("boundary word want=0xdeadbeef got=0x%08lx FAIL\n",
                        (unsigned long) p[nwords - 1u]);
            failures++;
        } else if (failures == 0) {
            uart_printf("sparse verify across %lu MiB OK (last=0x%08lx)\n",
                        (unsigned long) (BIG_BYTES / (1024u * 1024u)),
                        (unsigned long) p[nwords - 1u]);
        }
    }

    /* --- 3: second allocation in the region, non-overlapping, first intact. */
    volatile uint32_t *q = (volatile uint32_t *) malloc(SECOND_BYTES);
    const uint32_t qwords = SECOND_BYTES / 4u;

    if (q == NULL || !in_ddr((const void *) q)) {
        uart_printf("second malloc(%lu) FAIL (q=0x%08lx)\n",
                    (unsigned long) SECOND_BYTES,
                    (unsigned long) q);
        failures++;
    } else if ((uintptr_t) q < (uintptr_t) p + BIG_BYTES) {
        uart_printf("second malloc 0x%08lx overlaps first [0x%08lx,+%lu) FAIL\n",
                    (unsigned long) q,
                    (unsigned long) p,
                    (unsigned long) BIG_BYTES);
        failures++;
    } else {
        q[0] = 0x11223344u;
        q[qwords - 1u] = 0x55667788u;
        if (q[0] != 0x11223344u || q[qwords - 1u] != 0x55667788u) {
            uart_printf("second alloc readback FAIL\n");
            failures++;
        } else {
            uart_printf("second malloc(%lu) = 0x%08lx (DDR, non-overlapping) OK\n",
                        (unsigned long) SECOND_BYTES,
                        (unsigned long) q);
        }
        /* First allocation must be undisturbed by the second's writes. */
        if (p != NULL && in_ddr((const void *) p) && p[0] != pattern(0)) {
            uart_printf("first alloc corrupted by second: p[0]=0x%08lx FAIL\n",
                        (unsigned long) p[0]);
            failures++;
        }
    }

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("%d check(s) failed\n", failures);
        uart_printf("<<FAIL>>\n");
    }

    for (;;) {
    }
}
