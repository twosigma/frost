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
 * lq_stale_slot_probe: a load can complete with another load's data.
 *
 * The load queue keeps up to four cached-tier loads in flight in its slots.
 * A partial flush that kills a slot's load marks the slot to drain its
 * response (cs_drop) but keeps the slot busy until that response lands, and
 * the killed load's queue entry is free at once. The slot still carries the
 * dead load's ROB tag and queue index. If a live load is allocated into
 * that entry and launches, and a second partial flush arrives before the
 * dead response, the flush judges the slot by its stale tag: when that tag
 * reads as younger than the flush point, the flush clears the issued bit of
 * the live entry. The live load can then be launched a second time; its first
 * response completes it and frees the entry, and the next load allocated
 * there can receive the second response as its own data and complete with
 * the wrong value under its own ROB tag.
 *
 * Shape (iter.S): B1 resolves behind a divide chain and, on its wrong
 * path, runs three line loads behind a shorter one (drained slots whose
 * responses are still in flight after the recovery) plus five that only
 * hold entries; its correct path loads the -1 marker line N, then B2
 * mispredicts a fixed add chain later while N is in flight, then ten line
 * loads P keep the queue full. Every probed line carries its own signature;
 * a P that reads -1 took N's second response. Both branch directions are
 * random, so every combination is exercised; the hazard needs bit 0 set and
 * both branches mispredicted. The load queue's live-slot identity assertion
 * is the detector that fires first (the cycle after the flush, aborting the
 * run): N's relaunch is to its own line and coalesces with the first
 * request, so the two responses land back to back and the wrong value
 * reaches a P only when an allocation lands in that one-cycle gap.
 *
 * The probe writes its own pool and marker lines and evicts them from the
 * L1D (fence.i writes it back) and the direct-mapped L2 (two alias passes)
 * before the measured loop, so it depends on no prior DRAM contents; every
 * probed line is then loaded exactly once, and each block's line 0 is
 * recorded so a pool that did not hold its signatures is reported.
 */

#include "uart.h"
#include <stdint.h>

#ifndef STALE_ITERS
#define STALE_ITERS 512u
#endif

/* Cached DDR, inside the 64 MiB simulation model: 2 MiB of 4 KiB pool
 * blocks, their two L2 aliases (2 MiB direct-mapped), the marker lines with
 * their two aliases, and the result records; the regions never overlap. */
#define POOL_BASE 0x83000000ul /* aliases at 0x83200000 and 0x83400000 */
#define L2_ALIAS 0x200000ul
#define MARK_BASE 0x83600000ul /* aliases at 0x83800000 and 0x83A00000 */
#define OUT_BASE 0x83C00000ul
#define NPROBE 11u /* N and P1..P10 */
#define SEED 0x9E3779B97F4A7C15ul

void lq_stale_run(unsigned long iters,
                  unsigned long pool,
                  unsigned long markers,
                  unsigned long *out,
                  unsigned long seed);

/* Offsets loaded inside a block: B1's condition, A1..A3, A4..A8, P set 1,
 * P set 2. */
static const unsigned short probed_off[] = {
    0,    64,   128,  192,  256,  320,  384,  448,  512,  1024, 1088, 1152, 1216, 1280, 1344,
    1408, 1472, 1536, 1600, 2048, 2112, 2176, 2240, 2304, 2368, 2432, 2496, 2560, 2624,
};
#define NPROBED (sizeof(probed_off) / sizeof(probed_off[0]))

static inline unsigned long sig(unsigned long blk, unsigned long off)
{
    return 0x5000000000000000ul | (blk << 16) | off;
}

static inline unsigned long xorshift(unsigned long *s)
{
    unsigned long x = *s;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *s = x;
    return x;
}

static inline void sd64(unsigned long addr, unsigned long v)
{
    *(volatile unsigned long *) addr = v;
}

static inline unsigned long ld64(unsigned long addr)
{
    return *(volatile unsigned long *) addr;
}

/* Write every probed line's signature and the -1 markers, then push them
 * out of both cache levels: fence.i writes the L1D back, and two passes
 * over the lines' L2 aliases evict them from the L2 (the first pass can
 * re-allocate a line written back from the L1D; the second cannot). */
static void prepare_pool(void)
{
    for (unsigned long i = 0; i < STALE_ITERS; i++) {
        unsigned long blk = POOL_BASE + i * 4096ul;
        for (unsigned k = 0; k < NPROBED; k++)
            sd64(blk + probed_off[k], sig(i, probed_off[k]));
        sd64(MARK_BASE + i * 64ul, ~0ul);
        for (unsigned k = 0; k < 16; k++)
            sd64(OUT_BASE + i * 128ul + k * 8ul, 0x5A5A000000000000ul | k);
    }
    __asm__ volatile("fence" ::: "memory");
    __asm__ volatile("fence.i" ::: "memory");
    for (unsigned pass = 1; pass <= 2; pass++) {
        unsigned long alias = pass * L2_ALIAS;
        for (unsigned long i = 0; i < STALE_ITERS; i++) {
            unsigned long blk = POOL_BASE + i * 4096ul;
            for (unsigned k = 0; k < NPROBED; k++)
                (void) ld64(blk + probed_off[k] + alias);
            (void) ld64(MARK_BASE + i * 64ul + alias);
        }
    }
    __asm__ volatile("fence" ::: "memory");
}

int main(void)
{
    unsigned long arm_y = 0, fail_iters = 0, fail_values = 0, marker_bad = 0, cond_bad = 0;
    unsigned long reported = 0, rng = SEED;

    uart_printf("\r\nlq_stale_slot_probe: %lu iterations, pool @%lx, markers @%lx\r\n",
                (unsigned long) STALE_ITERS,
                POOL_BASE,
                MARK_BASE);

    prepare_pool();
    lq_stale_run(STALE_ITERS, POOL_BASE, MARK_BASE, (unsigned long *) OUT_BASE, SEED);

    for (unsigned long i = 0; i < STALE_ITERS; i++) {
        unsigned long r = xorshift(&rng);
        const volatile unsigned long *out = (const volatile unsigned long *) (OUT_BASE + i * 128ul);
        unsigned long set_off = (r & 2) ? 2048ul : 1024ul;
        unsigned long bad = 0;

        if (out[11] != sig(i, 0)) {
            cond_bad++;
            if (reported < 8) {
                reported++;
                uart_printf("  iter %lu: line 0 read %lx, expected its signature %lx\r\n",
                            i,
                            out[11],
                            sig(i, 0));
            }
            continue;
        }
        if (!(r & 1))
            continue; /* arm X was the correct path: nothing to check */
        arm_y++;

        if (out[0] != ~0ul) {
            marker_bad++;
            if (reported < 8) {
                reported++;
                uart_printf("  iter %lu: N read %lx, expected -1\r\n", i, out[0]);
            }
        }
        for (unsigned k = 1; k < NPROBE; k++) {
            unsigned long expect = sig(i, set_off + (k - 1) * 64ul);
            unsigned long got = out[k];
            if (got != expect) {
                bad++;
                fail_values++;
                if (reported < 8) {
                    reported++;
                    if (got == ~0ul)
                        uart_printf("  iter %lu rnd=%lx: P%u = -1 (N's data), expected %lx\r\n",
                                    i,
                                    r & 3,
                                    k,
                                    expect);
                    else if ((got >> 60) == 5)
                        uart_printf("  iter %lu rnd=%lx: P%u = %lx (block %lu offset %lu's "
                                    "line), expected %lx\r\n",
                                    i,
                                    r & 3,
                                    k,
                                    got,
                                    (got >> 16) & 0xFFFFFul,
                                    got & 0xFFFFul,
                                    expect);
                    else
                        uart_printf("  iter %lu rnd=%lx: P%u = %lx, expected %lx\r\n",
                                    i,
                                    r & 3,
                                    k,
                                    got,
                                    expect);
                }
            }
        }
        if (bad)
            fail_iters++;
    }

    uart_printf("lq_stale_slot_probe: arm-Y iterations=%lu, iterations with a wrong P=%lu, "
                "wrong P values=%lu, bad markers=%lu, bad line-0 signatures=%lu\r\n",
                arm_y,
                fail_iters,
                fail_values,
                marker_bad,
                cond_bad);
    uart_printf((fail_iters == 0 && marker_bad == 0 && cond_bad == 0) ? "<<PASS>>\r\n"
                                                                      : "<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
