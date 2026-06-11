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
 * Cached-region (DDR) tier test
 *
 * Exercises the high-address cached memory region (CACHED_BASE = 0x8000_0000,
 * 1 GiB), which is served by the write-back cache hierarchy (L1 BRAM, plus
 * URAM L2 in the X3 shape) over main memory. Code, data and the stack all
 * live in the low BRAM range; the cached region is reached purely through
 * absolute-address volatile pointers, so this also confirms the per-tier
 * address routing.
 *
 * What it checks:
 *   - Word stores + variable-latency loads at low, mid and far addresses
 *     spanning 8 MiB -- far beyond L1 (128 KiB) and L2 (2 MiB), so misses,
 *     fills and dirty writebacks all happen along the way.
 *   - That the cached tier is independent of the low BRAM (a cached store
 *     must not alias into BRAM word 0; the low-BRAM canary catches a wrong
 *     BRAM write mask).
 *   - Sub-word (byte) stores via the line byte strobes.
 *   - An L1-index-aliasing sweep (stride = L1 size) that forces continuous
 *     eviction/fill round trips, then verifies every line survived.
 *
 * Prints "<<PASS>>" if every check matches, otherwise "<<FAIL>>".
 */

#include <stdint.h>

#include "uart.h"

#define CACHED_BASE 0x80000000u
#define TEST_WINDOW 0x00800000u /* exercise the first 8 MiB of the region */

/* Word offsets (in 32-bit words) covering low, two mid points, and far. */
#define OFF_LOW 0u
#define OFF_LOW2 1u
#define OFF_MID_A (0x00040000u / 4u)       /* 256 KiB in (beyond L1) */
#define OFF_MID_B (0x00400000u / 4u)       /* 4 MiB in (beyond L2)   */
#define OFF_TOP ((TEST_WINDOW - 16u) / 4u) /* near the window top    */

static volatile uint32_t *const ddr = (volatile uint32_t *) CACHED_BASE;

/* Canary in low BRAM: catches a cached store that incorrectly aliases into
 * the BRAM (cached byte address truncates into the low range). */
static volatile uint32_t bram_canary = 0xC0FFEE11u;

struct word_case {
    uint32_t off;
    uint32_t val;
};

static const struct word_case word_cases[] = {
    {OFF_LOW, 0xDEADBEEFu},
    {OFF_LOW2, 0x12345678u},
    {OFF_MID_A, 0xA5A5A5A5u},
    {OFF_MID_B, 0x5A5A5A5Au},
    {OFF_TOP, 0xCAFEF00Du},
};

#define NUM_WORD_CASES (sizeof(word_cases) / sizeof(word_cases[0]))

int main(void)
{
    int failures = 0;

    uart_printf("Cached-region (DDR) tier test\n");
    uart_printf("=============================\n");
    uart_printf("CACHED_BASE=0x%08lx window=0x%08lx\n",
                (unsigned long) CACHED_BASE,
                (unsigned long) TEST_WINDOW);

    /* --- Phase 1: word store/load across the region. ---------------------- */
    /* Write every pattern first... */
    for (uint32_t i = 0; i < NUM_WORD_CASES; i++) {
        ddr[word_cases[i].off] = word_cases[i].val;
    }
    /* ...then read every pattern back (cache hits or fresh fills). */
    for (uint32_t i = 0; i < NUM_WORD_CASES; i++) {
        uint32_t got = ddr[word_cases[i].off];
        uint32_t want = word_cases[i].val;
        if (got != want) {
            uart_printf("WORD off=0x%08lx want=0x%08lx got=0x%08lx FAIL\n",
                        (unsigned long) word_cases[i].off,
                        (unsigned long) want,
                        (unsigned long) got);
            failures++;
        } else {
            uart_printf("WORD off=0x%08lx = 0x%08lx OK\n",
                        (unsigned long) word_cases[i].off,
                        (unsigned long) got);
        }
    }

    /* --- Phase 2: byte (sub-word) stores via the line byte strobes. ------- */
    /* Seed a known word, then overwrite individual bytes and read the word. */
    volatile uint8_t *const ddr_b = (volatile uint8_t *) CACHED_BASE;
    const uint32_t byte_word_off = OFF_MID_A + 1u; /* distinct from phase 1 */
    ddr[byte_word_off] = 0x00000000u;
    ddr_b[byte_word_off * 4u + 0u] = 0x11u;
    ddr_b[byte_word_off * 4u + 1u] = 0x22u;
    ddr_b[byte_word_off * 4u + 2u] = 0x33u;
    ddr_b[byte_word_off * 4u + 3u] = 0x44u;
    {
        uint32_t got = ddr[byte_word_off];
        uint32_t want = 0x44332211u; /* little-endian assembly of the bytes */
        if (got != want) {
            uart_printf(
                "BYTE want=0x%08lx got=0x%08lx FAIL\n", (unsigned long) want, (unsigned long) got);
            failures++;
        } else {
            uart_printf("BYTE word = 0x%08lx OK\n", (unsigned long) got);
        }
    }

    /* Partial byte overwrite: change only byte 2, leave the rest. */
    ddr_b[byte_word_off * 4u + 2u] = 0xAAu;
    {
        uint32_t got = ddr[byte_word_off];
        uint32_t want = 0x44AA2211u;
        if (got != want) {
            uart_printf(
                "BYTE2 want=0x%08lx got=0x%08lx FAIL\n", (unsigned long) want, (unsigned long) got);
            failures++;
        } else {
            uart_printf("BYTE2 word = 0x%08lx OK\n", (unsigned long) got);
        }
    }

    /* --- Phase 3: BRAM canary must be untouched by the cached stores. ----- */
    if (bram_canary != 0xC0FFEE11u) {
        uart_printf("CANARY corrupted: 0x%08lx FAIL\n", (unsigned long) bram_canary);
        failures++;
    } else {
        uart_printf("CANARY intact OK\n");
    }

    /* --- Phase 4: re-read phase-1 low words to confirm persistence. ------- */
    if (ddr[OFF_LOW] != 0xDEADBEEFu || ddr[OFF_LOW2] != 0x12345678u) {
        uart_printf("PERSIST low words changed FAIL\n");
        failures++;
    } else {
        uart_printf("PERSIST low words OK\n");
    }

    /* --- Phase 5: tight store->load RAW to the same cached word. ----------- */
    /* Each iteration stores a word then immediately loads it back from the
     * same address -- the store->load ordering the handshake write-done must
     * keep correct. Vary the address and value so neither an L0 line nor a
     * constant can mask a stale read. */
    {
        const uint32_t raw_base = OFF_MID_A + 64u; /* distinct in-bounds region */
        int raw_fail = 0;
        for (uint32_t i = 0; i < 256u; i++) {
            uint32_t off = raw_base + i * 3u; /* stride varies line/word select */
            uint32_t val = 0xB0000000u ^ (i * 0x9E3779B1u);
            ddr[off] = val;
            uint32_t got = ddr[off];
            if (got != val) {
                uart_printf("RAW i=%lu off=0x%08lx want=0x%08lx got=0x%08lx FAIL\n",
                            (unsigned long) i,
                            (unsigned long) off,
                            (unsigned long) val,
                            (unsigned long) got);
                failures++;
                raw_fail = 1;
                break;
            }
        }
        if (!raw_fail) {
            uart_printf("RAW store->load (256 iters) OK\n");
        }
    }

    /* --- Phase 6: L1-index-aliasing eviction sweep. ------------------------ */
    /* Stride by the L1 size so every address lands on the same L1 index with a
     * different tag: each access past the first evicts a dirty line (writeback
     * through L2/DDR) and later re-reads must fill it back. */
    {
        const uint32_t l1_stride_words = (128u * 1024u) / 4u; /* L1_CACHE_BYTES */
        const uint32_t lines = 24u;
        int evict_fail = 0;
        for (uint32_t i = 0; i < lines; i++) {
            ddr[i * l1_stride_words + 7u] = 0xE0000000u ^ (i * 0x01010101u);
        }
        for (uint32_t i = 0; i < lines; i++) {
            uint32_t got = ddr[i * l1_stride_words + 7u];
            uint32_t want = 0xE0000000u ^ (i * 0x01010101u);
            if (got != want) {
                uart_printf("EVICT i=%lu want=0x%08lx got=0x%08lx FAIL\n",
                            (unsigned long) i,
                            (unsigned long) want,
                            (unsigned long) got);
                failures++;
                evict_fail = 1;
                break;
            }
        }
        if (!evict_fail) {
            uart_printf("EVICT sweep (%lu aliasing lines) OK\n", (unsigned long) lines);
        }
    }

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("%d check(s) failed\n", failures);
        uart_printf("<<FAIL>>\n");
    }

    /* Halt */
    for (;;) {
    }
}
