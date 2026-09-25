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

/*
 * Cached-DDR cold-vs-warm read divergence probe. A read of either 32-bit half
 * of a dword must return the same data from an L1D hit as from a miss served
 * by the refill.
 *
 * Each round fills a buffer, dirties its direct-mapped aliases to evict it,
 * records cold reads, rereads warm, and compares both with expected.
 * Shapes include ascending and descending 32-bit reads, odd-half-first reads,
 * 64-bit reads, and a cold half-store followed by both half-loads. A mismatch
 * reports shape, address, and the values read with their expected values: the
 * cold and warm reads, or the stored half and its neighbor.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#ifndef N_ROUNDS
#define N_ROUNDS 64u
#endif

/* Clear of restore_window_stress frames; +0x20000 aliases in the 128 KiB L1D. */
#define BUF_BASE 0x82900000u
#define ALIAS_XOR 0x20000u
#define WORDS 512u /* 2 KiB, DTB-sized */
#define LINE_BYTES 32u

static volatile uint32_t *const buf = (volatile uint32_t *) BUF_BASE;
static volatile uint32_t *const alias = (volatile uint32_t *) (BUF_BASE ^ ALIAS_XOR);

/* In the default BRAM tier the captures live in low BRAM, away from the DDR
 * lines under test. */
static uint32_t cold_val[WORDS];
static uint32_t warm_val[WORDS];

static uint32_t g_fail;

static uint32_t expect_word(uint32_t i, uint32_t round)
{
    uint32_t x = (i + 1u) * 0x9E3779B9u + round * 0x85EBCA6Bu;
    x ^= x >> 15;
    return x;
}

static void fill_pattern(uint32_t round)
{
    for (uint32_t i = 0; i < WORDS; i++)
        buf[i] = expect_word(i, round);
    __asm__ volatile("fence" ::: "memory");
}

static void evict_buffer(uint32_t round)
{
    /* Dirty every alias line so each buffer line is evicted (write-back +
     * replace in the direct-mapped L1D), making the next reads true misses. */
    for (uint32_t i = 0; i < WORDS; i += LINE_BYTES / 4u)
        alias[i] = i ^ round;
    __asm__ volatile("fence" ::: "memory");
}

static void
report_mismatch(const char *shape, uint32_t i, uint32_t got_cold, uint32_t got_warm, uint32_t want)
{
    if (g_fail < 10u) {
        uart_printf("DIVERGE shape=%s word=%u addr=%x cold=%x warm=%x want=%x\n",
                    shape,
                    (unsigned) i,
                    (unsigned) (BUF_BASE + 4u * i),
                    (unsigned) got_cold,
                    (unsigned) got_warm,
                    (unsigned) want);
    }
    g_fail++;
}

/* Store-forward shape: the stored half and its neighbor, each with its own
 * expected value. */
static void
report_stfwd(uint32_t si, uint32_t got_s, uint32_t want_s, uint32_t got_n, uint32_t want_n)
{
    if (g_fail < 10u) {
        uart_printf("DIVERGE shape=stfwd word=%u addr=%x stored=%x want=%x neighbor=%x want=%x\n",
                    (unsigned) si,
                    (unsigned) (BUF_BASE + 4u * si),
                    (unsigned) got_s,
                    (unsigned) want_s,
                    (unsigned) got_n,
                    (unsigned) want_n);
    }
    g_fail++;
}

static void check_round(const char *shape, uint32_t round)
{
    for (uint32_t i = 0; i < WORDS; i++) {
        uint32_t want = expect_word(i, round);
        if (cold_val[i] != want || warm_val[i] != want)
            report_mismatch(shape, i, cold_val[i], warm_val[i], want);
    }
}

static void shape_asc32(uint32_t round)
{
    fill_pattern(round);
    evict_buffer(round);
    for (uint32_t i = 0; i < WORDS; i++)
        cold_val[i] = buf[i];
    for (uint32_t i = 0; i < WORDS; i++)
        warm_val[i] = buf[i];
    check_round("asc32", round);
}

static void shape_desc32(uint32_t round)
{
    fill_pattern(round);
    evict_buffer(round);
    for (uint32_t i = WORDS; i-- > 0u;)
        cold_val[i] = buf[i];
    for (uint32_t i = WORDS; i-- > 0u;)
        warm_val[i] = buf[i];
    check_round("desc32", round);
}

static void shape_oddfirst(uint32_t round)
{
    /* Read the %8==4 half of every dword before its %8==0 half: the cold miss
     * is triggered by the high half, the low half then hits the fresh fill. */
    fill_pattern(round);
    evict_buffer(round);
    for (uint32_t i = 1; i < WORDS; i += 2u)
        cold_val[i] = buf[i];
    for (uint32_t i = 0; i < WORDS; i += 2u)
        cold_val[i] = buf[i];
    for (uint32_t i = 1; i < WORDS; i += 2u)
        warm_val[i] = buf[i];
    for (uint32_t i = 0; i < WORDS; i += 2u)
        warm_val[i] = buf[i];
    check_round("oddfirst", round);
}

static void shape_dword(uint32_t round)
{
    fill_pattern(round);
    evict_buffer(round);
    volatile uint64_t *const buf64 = (volatile uint64_t *) BUF_BASE;
    for (uint32_t i = 0; i < WORDS / 2u; i++) {
        uint64_t v = buf64[i];
        cold_val[2u * i] = (uint32_t) v;
        cold_val[2u * i + 1u] = (uint32_t) (v >> 32);
    }
    for (uint32_t i = 0; i < WORDS / 2u; i++) {
        uint64_t v = buf64[i];
        warm_val[2u * i] = (uint32_t) v;
        warm_val[2u * i + 1u] = (uint32_t) (v >> 32);
    }
    check_round("dword", round);
}

static void shape_store_forward(uint32_t round)
{
    /* Store one half of each dword of the evicted buffer, then immediately
     * load both halves: the stored half must read back the new value and the
     * neighbor half the refilled one. The stored half alternates within each
     * line, and the dword that opens a line stores its low half in even lines
     * and its high half in odd lines. */
    fill_pattern(round);
    evict_buffer(round);
    for (uint32_t i = 0; i < WORDS; i += 2u) {
        uint32_t line = i / (LINE_BYTES / 4u);
        uint32_t hi_first = ((i >> 1) ^ line) & 1u;
        uint32_t si = i + (hi_first ? 1u : 0u);
        uint32_t ni = i + (hi_first ? 0u : 1u);
        uint32_t sv = expect_word(si, round) ^ 0xA5A5A5A5u;
        uint32_t nv = expect_word(ni, round);
        buf[si] = sv;
        uint32_t got_s = buf[si];
        uint32_t got_n = buf[ni];
        if (got_s != sv || got_n != nv) {
            report_stfwd(si, got_s, sv, got_n, nv);
        }
    }
}

int main(void)
{
    uart_printf("=== mem divergence probe: %u rounds, %u words ===\n",
                (unsigned) N_ROUNDS,
                (unsigned) WORDS);

    for (uint32_t r = 0; r < N_ROUNDS; r++) {
        shape_asc32(r);
        shape_desc32(r);
        shape_oddfirst(r);
        shape_dword(r);
        shape_store_forward(r);
        if ((r & 15u) == 15u)
            uart_printf("round %u done, diverge=%u\n", (unsigned) (r + 1u), (unsigned) g_fail);
    }

    uart_printf("total divergences: %u\n", (unsigned) g_fail);
    if (g_fail == 0u) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>>\n");
    }
    for (;;) {
    }
    return 0;
}
