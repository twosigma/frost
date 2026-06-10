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
 * URAM tier test
 *
 * Exercises the high-address UltraRAM memory tier (URAM_BASE = 0x0100_0000,
 * 2 MiB -> [0x0100_0000, 0x0120_0000)). Code, data and the stack all live in
 * the low BRAM range; the URAM region is reached purely through absolute-address
 * volatile pointers, so this also confirms the per-tier address routing.
 *
 * What it checks:
 *   - Word stores + N-cycle loads at low, mid and near-top URAM addresses.
 *   - That the URAM tier is independent of the low BRAM (a URAM store must not
 *     alias into BRAM word 0; if the BRAM write mask were wrong, the canary in
 *     low BRAM would be clobbered).
 *   - Sub-word (byte) stores via the URAM byte-write enables.
 *
 * Pattern: every URAM word is written first, then all read back, so each read
 * is a fresh URAM access (the store invalidated any L0 line, so the read misses
 * L0 and pays the URAM read latency instead of being served by forwarding).
 *
 * Prints "<<PASS>>" if every check matches, otherwise "<<FAIL>>".
 */

#include <stdint.h>

#include "uart.h"

#define URAM_BASE 0x01000000u
#define URAM_SIZE 0x00200000u /* 2 MiB */

/* Word offsets (in 32-bit words) covering low, two mid points, and near-top. */
#define OFF_LOW 0u
#define OFF_LOW2 1u
#define OFF_MID_A (0x00040000u / 4u)     /* 256 KiB in */
#define OFF_MID_B (0x00100000u / 4u)     /* 1 MiB in   */
#define OFF_TOP ((URAM_SIZE - 16u) / 4u) /* last usable word region */

static volatile uint32_t *const uram = (volatile uint32_t *) URAM_BASE;

/* Canary in low BRAM: catches a URAM store that incorrectly aliases into the
 * BRAM (URAM byte address 0x0100_0000 truncates to BRAM word 0). */
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

    uart_printf("URAM tier test\n");
    uart_printf("==============\n");
    uart_printf(
        "URAM_BASE=0x%08lx size=0x%08lx\n", (unsigned long) URAM_BASE, (unsigned long) URAM_SIZE);

    /* --- Phase 1: word store/load across the tier. ----------------------- */
    /* Write every pattern first... */
    for (uint32_t i = 0; i < NUM_WORD_CASES; i++) {
        uram[word_cases[i].off] = word_cases[i].val;
    }
    /* ...then read every pattern back (fresh URAM loads). */
    for (uint32_t i = 0; i < NUM_WORD_CASES; i++) {
        uint32_t got = uram[word_cases[i].off];
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

    /* --- Phase 2: byte (sub-word) stores via URAM byte-write enables. ----- */
    /* Seed a known word, then overwrite individual bytes and read the word. */
    volatile uint8_t *const uram_b = (volatile uint8_t *) URAM_BASE;
    const uint32_t byte_word_off = OFF_MID_A + 1u; /* distinct from phase 1 */
    uram[byte_word_off] = 0x00000000u;
    uram_b[byte_word_off * 4u + 0u] = 0x11u;
    uram_b[byte_word_off * 4u + 1u] = 0x22u;
    uram_b[byte_word_off * 4u + 2u] = 0x33u;
    uram_b[byte_word_off * 4u + 3u] = 0x44u;
    {
        uint32_t got = uram[byte_word_off];
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
    uram_b[byte_word_off * 4u + 2u] = 0xAAu;
    {
        uint32_t got = uram[byte_word_off];
        uint32_t want = 0x44AA2211u;
        if (got != want) {
            uart_printf(
                "BYTE2 want=0x%08lx got=0x%08lx FAIL\n", (unsigned long) want, (unsigned long) got);
            failures++;
        } else {
            uart_printf("BYTE2 word = 0x%08lx OK\n", (unsigned long) got);
        }
    }

    /* --- Phase 3: BRAM canary must be untouched by the URAM stores. ------- */
    if (bram_canary != 0xC0FFEE11u) {
        uart_printf("CANARY corrupted: 0x%08lx FAIL\n", (unsigned long) bram_canary);
        failures++;
    } else {
        uart_printf("CANARY intact OK\n");
    }

    /* --- Phase 4: re-read phase-1 low words to confirm persistence. ------- */
    if (uram[OFF_LOW] != 0xDEADBEEFu || uram[OFF_LOW2] != 0x12345678u) {
        uart_printf("PERSIST low words changed FAIL\n");
        failures++;
    } else {
        uart_printf("PERSIST low words OK\n");
    }

    /* --- Phase 5: tight store->load RAW to the same URAM word. ------------- */
    /* Each iteration stores a word then immediately loads it back from the same
     * address -- the store->load case the +1 URAM write latency must keep
     * correct (covered by SQ forwarding and the held URAM store-done). Vary the
     * address and value so neither an L0 line nor a constant can mask a stale
     * read. */
    {
        const uint32_t raw_base = OFF_MID_A + 64u; /* distinct in-bounds region */
        int raw_fail = 0;
        for (uint32_t i = 0; i < 256u; i++) {
            uint32_t off = raw_base + i * 3u; /* stride varies row/word select */
            uint32_t val = 0xB0000000u ^ (i * 0x9E3779B1u);
            uram[off] = val;
            uint32_t got = uram[off];
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
