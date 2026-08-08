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
 * Cached-DDR cold-vs-warm read divergence probe (rv64 M7 hardware debug).
 *
 * Born from the first rv64 Linux-on-silicon bring-up (2026-08-04): the kernel
 * FDT unflattener reads the device-tree blob twice (size pass, build pass) and
 * behaved as if the two passes saw different bytes (an interrupt-controller
 * sibling storm), and exec's i_writecount accounting behaved as if plain/LR
 * reads of a hot counter diverged from its memory value. Both reproduce on
 * FROST (sim and hardware) but not QEMU, pointing at a load-path anomaly in
 * the 64-bit data tier: a 32-bit beat extracted differently on the L1-hit
 * path vs the miss/refill(-forward) path for one half of a dword row.
 *
 * The probe writes a pattern into a cached-DDR buffer, then for each round:
 *   evict (dirty the direct-mapped L1D alias line so the buffer line is cold)
 *   COLD pass: read every element, record into BRAM (results must not disturb
 *              the DDR cache state under test)
 *   WARM pass: immediately re-read (hits)
 *   compare cold vs warm vs expected.
 * Access shapes swept per round: 32-bit ascending, 32-bit descending,
 * odd-half-first (addr%8==4 before %8==0), 64-bit dword reads, and a
 * store-interleaved shape (store one dword half while the line is cold, then
 * immediately load both halves — SQ-forward against fill).
 * Any divergence prints addr/shape/cold/warm/expected and the test FAILs —
 * failure here IS the reproduction we are hunting.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#ifndef N_ROUNDS
#define N_ROUNDS 64u
#endif

/* Cached-DDR probe buffer; clear of restore_window_stress's 0x82800000 frames.
 * 128 KiB direct-mapped L1D: +0x20000 aliases to the same set. */
#define BUF_BASE 0x82900000u
#define ALIAS_XOR 0x20000u
#define WORDS 512u /* 2 KiB, DTB-sized */
#define LINE_BYTES 64u

static volatile uint32_t *const buf = (volatile uint32_t *) BUF_BASE;
static volatile uint32_t *const alias = (volatile uint32_t *) (BUF_BASE ^ ALIAS_XOR);

/* Result capture lives in BRAM .bss so it cannot perturb the DDR lines. */
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

#if __riscv_xlen == 64
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
#endif

static void shape_store_forward(uint32_t round)
{
    /* Store one half of a cold dword, then immediately load both halves: the
     * load of the stored half must forward/miss-merge, the neighbor half must
     * come from the fill. Alternate which half is stored. */
    fill_pattern(round);
    evict_buffer(round);
    for (uint32_t i = 0; i < WORDS; i += 2u) {
        uint32_t hi_first = (i >> 1) & 1u;
        uint32_t si = i + (hi_first ? 1u : 0u);
        uint32_t ni = i + (hi_first ? 0u : 1u);
        uint32_t sv = expect_word(si, round) ^ 0xA5A5A5A5u;
        buf[si] = sv;
        uint32_t got_s = buf[si];
        uint32_t got_n = buf[ni];
        if (got_s != sv || got_n != expect_word(ni, round)) {
            report_mismatch("stfwd", si, got_s, got_n, sv);
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
#if __riscv_xlen == 64
        shape_dword(r);
#endif
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
