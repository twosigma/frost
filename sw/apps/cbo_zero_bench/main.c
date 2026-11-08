/*
 *    Copyright (c) 2026 John Goodacre
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
 * Clear-memory benchmark: cycles to zero 64 KiB and 1 MiB of cached DDR with
 * an unrolled sd loop (eight sd per 64-byte block) and with one cbo.zero per
 * block, each on a region not touched since reset (cold) and again on the
 * same region (warm). Each timed clear ends with a fence, so the count
 * includes draining the store queue into the L1D. The program checks that
 * each cleared region reads back as zero (every dword of its first and last
 * 4 KiB and three dwords of every block).
 *
 * Output lines: "FROST_CBO_BENCH <method> <size> <cold|warm> cycles=<n>".
 * The regions sit above the program image in DDR; set CBO_BENCH_BASE to
 * move them. Each size runs the sd loop first; CBO_BENCH_CBO_FIRST runs
 * cbo.zero first, so comparing both builds separates each method from the
 * dirty lines that the method before it leaves in the caches.
 */

#include <stdint.h>

#include "csr.h"
#include "uart.h"

#ifndef CBO_BENCH_BASE
#define CBO_BENCH_BASE 0x82000000ul
#endif
#ifndef CBO_BENCH_SMALL
#define CBO_BENCH_SMALL (64ul << 10)
#endif
#ifndef CBO_BENCH_LARGE
#define CBO_BENCH_LARGE (1ul << 20)
#endif

#define BLOCK 64ul

static inline unsigned long rdcycle_now(void)
{
    unsigned long c;
    __asm__ volatile("rdcycle %0" : "=r"(c));
    return c;
}

static void clear_sd(unsigned long base, unsigned long bytes)
{
    unsigned long end = base + bytes;
    __asm__ volatile("1:\n"
                     "sd   zero, 0(%0)\n"
                     "sd   zero, 8(%0)\n"
                     "sd   zero, 16(%0)\n"
                     "sd   zero, 24(%0)\n"
                     "sd   zero, 32(%0)\n"
                     "sd   zero, 40(%0)\n"
                     "sd   zero, 48(%0)\n"
                     "sd   zero, 56(%0)\n"
                     "addi %0, %0, 64\n"
                     "bltu %0, %1, 1b\n"
                     "fence rw, rw\n"
                     : "+r"(base)
                     : "r"(end)
                     : "memory");
}

static void clear_cbo(unsigned long base, unsigned long bytes)
{
    unsigned long end = base + bytes;
    __asm__ volatile("1:\n"
                     ".insn i 0x0F, 2, x0, %0, 4\n" /* cbo.zero (base) */
                     "addi %0, %0, 64\n"
                     "bltu %0, %1, 1b\n"
                     "fence rw, rw\n"
                     : "+r"(base)
                     : "r"(end)
                     : "memory");
}

/* One nonzero dword per block makes every line dirty again. */
static void fill_pattern(unsigned long base, unsigned long bytes)
{
    for (unsigned long a = base; a < base + bytes; a += BLOCK)
        *(volatile uint64_t *) (a + 24) = a ^ 0x5A5A5A5A5A5A5A5Aul;
}

/* Every dword of the first and last 4 KiB, and three dwords of every block. */
static int check_zero(unsigned long base, unsigned long bytes)
{
    uint64_t any = 0;
    for (unsigned long a = base; a < base + 4096; a += 8)
        any |= *(volatile uint64_t *) a | *(volatile uint64_t *) (a + bytes - 4096);
    for (unsigned long a = base; a < base + bytes; a += BLOCK)
        any |= *(volatile uint64_t *) a | *(volatile uint64_t *) (a + 24) |
               *(volatile uint64_t *) (a + 56);
    return any == 0;
}

static int run(const char *method,
               void (*clear)(unsigned long, unsigned long),
               unsigned long base,
               unsigned long bytes)
{
    int ok = 1;
    for (int pass = 0; pass < 2; pass++) {
        if (pass == 1)
            fill_pattern(base, bytes);
        unsigned long start = rdcycle_now();
        clear(base, bytes);
        unsigned long cycles = rdcycle_now() - start;
        int zero = check_zero(base, bytes);
        ok &= zero;
        uart_printf("FROST_CBO_BENCH %s %lu %s cycles=%lu%s\r\n",
                    method,
                    bytes,
                    pass ? "warm" : "cold",
                    cycles,
                    zero ? "" : " NONZERO");
    }
    return ok;
}

int main(void)
{
    int ok = 1;
    unsigned long base = CBO_BENCH_BASE;

    uart_puts("\r\n=== cbo.zero clear benchmark ===\r\n");
    /* Each method and size gets its own never-touched region, so the cold
     * pass misses in the L1D and L2. The warm pass refills the region with
     * a pattern first, so both passes overwrite nonzero data. */
    static const unsigned long sizes[2] = {CBO_BENCH_SMALL, CBO_BENCH_LARGE};
    for (int size = 0; size < 2; size++) {
        for (int order = 0; order < 2; order++) {
#ifdef CBO_BENCH_CBO_FIRST
            int cbo = order == 0;
#else
            int cbo = order != 0;
#endif
            ok &= run(cbo ? "cbo" : "sd", cbo ? clear_cbo : clear_sd, base, sizes[size]);
            base += sizes[size];
        }
    }

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
