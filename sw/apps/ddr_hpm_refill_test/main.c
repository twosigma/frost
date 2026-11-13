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
 * Cache refill HPM events on the full SoC: mhpmevent3=19 counts L1I refills,
 * mhpmevent6=20 the home's demand line reads from memory (L2 demand misses)
 * and mhpmevent5=21 its prefetch line reads (L2 prefetch misses).
 *
 *   L  Cold L1I loops. Two straight-line bodies in cached DDR span 8 and 24
 *      32-byte lines. After fence.i each run refills its lines plus the same
 *      fetch tail (the fetch provider's next-line prefetch), so the long
 *      body refills exactly 16 lines more than the short one. Running a body
 *      three times after one fence.i refills as many lines as running it
 *      once, and MINH stops the count in M.
 *   D  L2-missing scattered reads: one load in each of 32 untouched 4 KiB
 *      pages reads exactly 32 lines from memory on demand, with no prefetch
 *      (the prefetchers stay within a page and need a stream). Reading the
 *      same lines again reads none.
 *   S  L2-missing stream: one load per 64-byte line over two untouched pages
 *      reads each of their 128 lines from memory exactly once, on demand or
 *      by a prefetch, and the L2 prefetcher takes part.
 *   O  Sscofpmf: the demand event wraps a preset counter 6, sets OF,
 *      mip.LCOFIP and the scountovf bit, and keeps counting past the wrap.
 *
 * The program, its stack and its counter reads stay in low BRAM, so only
 * the bodies and the data regions use the cached tier. A run count in
 * .ddr_data, which a reset keeps, gives each run its own untouched lines.
 * CSRs are accessed by number.
 */

#include <stdint.h>

#include "uart.h"

#define csr_read_num(num)                                                                          \
    ({                                                                                             \
        unsigned long v_;                                                                          \
        __asm__ volatile("csrr %0, " #num : "=r"(v_)::"memory");                                   \
        v_;                                                                                        \
    })
#define csr_write_num(num, val)                                                                    \
    do {                                                                                           \
        unsigned long v_ = (val);                                                                  \
        __asm__ volatile("csrw " #num ", %0" : : "r"(v_) : "memory");                              \
    } while (0)

#define OF (1ul << 63)
#define MINH (1ul << 62)
#define LCOF (1ul << 13)

#define CACHED_BASE 0x80000000ul

#define SEL_L1I_REFILL 19ul
#define SEL_L2_DEMAND 20ul
#define SEL_L2_PREFETCH 21ul

#define SHORT_LINES 8ul
#define LONG_LINES 24ul
#define SCATTER_PAGES 32ul
#define STREAM_LINES 128ul /* two 4 KiB pages of 64-byte lines */

/* Straight-line bodies, 64-byte aligned, without compressed instructions: a
 * body of N 32-byte lines holds 8N - 1 addi and a ret. A 128-byte gap of
 * zeros follows each one, so both bodies see the same fetch tail. */
__asm__(".pushsection .ddr_text, \"ax\", @progbits\n"
        ".option push\n"
        ".option norvc\n"
        ".balign 64\n"
        ".globl hpm_body_short\n"
        "hpm_body_short:\n"
        ".rept 8 * 8 - 1\n"
        "addi a0, a0, 1\n"
        ".endr\n"
        "ret\n"
        ".fill 32, 4, 0\n"
        ".balign 64\n"
        ".globl hpm_body_long\n"
        "hpm_body_long:\n"
        ".rept 8 * 24 - 1\n"
        "addi a0, a0, 1\n"
        ".endr\n"
        "ret\n"
        ".fill 32, 4, 0\n"
        ".option pop\n"
        ".popsection\n");

extern unsigned long hpm_body_short(unsigned long);
extern unsigned long hpm_body_long(unsigned long);
typedef unsigned long (*body_fn)(unsigned long);

static volatile unsigned long run_count __attribute__((section(".ddr_data"))) = 0;
static uintptr_t run_offset;

static int ok = 1;

static void report(const char *name, unsigned long got, unsigned long want, int pass)
{
    uart_printf("%s %s got=%lu want=%lu\r\n", pass ? "[PASS]" : "[FAIL]", name, got, want);
    ok &= pass;
}

static void expect_eq(const char *name, unsigned long got, unsigned long want)
{
    report(name, got, want, got == want);
}

/* Let late events reach the counters (two registered stages) and the
 * prefetches still in flight complete. */
static void settle(int n)
{
    for (volatile int i = 0; i < n; i++)
        ;
}

static void fence_i(void)
{
    __asm__ volatile("fence\n fence.i" ::: "memory");
}

/* L1I refills over `runs` runs of a body after fence.i. */
static unsigned long l1i_refills(body_fn body, int runs, unsigned long *sum)
{
    fence_i();
    settle(64);
    unsigned long before = csr_read_num(0xB03);
    for (int r = 0; r < runs; r++)
        *sum += body(*sum);
    settle(64);
    return csr_read_num(0xB03) - before;
}

/* Untouched cached memory: 16 MiB into DDR, above the program's .ddr_*
 * sections and inside the simulation's DDR model. */
static uintptr_t region(uintptr_t offset)
{
    return CACHED_BASE + 0x1000000 + run_offset + offset;
}

/* One load in each of `pages` pages, at a different line in each. */
static uint64_t scatter(uintptr_t base, unsigned long pages)
{
    uint64_t s = 0;
    for (unsigned long i = 0; i < pages; i++)
        s += *(volatile uint64_t *) (base + i * 4096 + ((i * 7) % 64) * 64);
    return s;
}

int main(void)
{
    volatile body_fn short_body = hpm_body_short;
    volatile body_fn long_body = hpm_body_long;
    unsigned long sum = 0;
    unsigned long run = run_count;

    run_count = run + 1;
    run_offset = (uintptr_t) (run % 4) * 0x400000;
    uart_printf("run %lu: HPM refill events L1I=%lu L2-demand=%lu L2-prefetch=%lu\r\n",
                run,
                SEL_L1I_REFILL,
                SEL_L2_DEMAND,
                SEL_L2_PREFETCH);
    csr_write_num(0x320, 0); /* mcountinhibit: count everything */
    csr_write_num(0x323, SEL_L1I_REFILL);
    csr_write_num(0x326, SEL_L2_DEMAND);
    csr_write_num(0x325, SEL_L2_PREFETCH);
    expect_eq("selector-3", csr_read_num(0x323), SEL_L1I_REFILL);
    expect_eq("selector-6", csr_read_num(0x326), SEL_L2_DEMAND);
    expect_eq("selector-5", csr_read_num(0x325), SEL_L2_PREFETCH);

    /* L: cold L1I loops. A first pass brings both bodies into the L2. */
    (void) l1i_refills(short_body, 1, &sum);
    (void) l1i_refills(long_body, 1, &sum);
    unsigned long r_short = l1i_refills(short_body, 1, &sum);
    unsigned long r_long = l1i_refills(long_body, 1, &sum);
    unsigned long r_long3 = l1i_refills(long_body, 3, &sum);
    uart_printf("L1I refills: short=%lu long=%lu long_x3=%lu\r\n", r_short, r_long, r_long3);
    report("L short-covers-its-lines",
           r_short,
           SHORT_LINES,
           r_short >= SHORT_LINES && r_short <= SHORT_LINES + 2);
    expect_eq("L long-minus-short", r_long - r_short, LONG_LINES - SHORT_LINES);
    expect_eq("L warm-reruns-refill-nothing", r_long3, r_long);
    csr_write_num(0x323, MINH | SEL_L1I_REFILL);
    expect_eq("L minh-stops-m", l1i_refills(long_body, 1, &sum), 0);
    csr_write_num(0x323, SEL_L1I_REFILL);

    /* D: one demand read per untouched page, then none for the same lines. */
    uintptr_t scatter_base = region(0x10000);
    settle(64);
    unsigned long d0 = csr_read_num(0xB06), p0 = csr_read_num(0xB05);
    sum += scatter(scatter_base, SCATTER_PAGES);
    settle(2000);
    unsigned long d_scatter = csr_read_num(0xB06) - d0;
    unsigned long p_scatter = csr_read_num(0xB05) - p0;
    uart_printf("L2 scatter: demand=%lu prefetch=%lu\r\n", d_scatter, p_scatter);
    expect_eq("D scatter-demand", d_scatter, SCATTER_PAGES);
    expect_eq("D scatter-prefetch", p_scatter, 0);
    d0 = csr_read_num(0xB06);
    sum += scatter(scatter_base, SCATTER_PAGES);
    settle(64);
    expect_eq("D warm-scatter-demand", csr_read_num(0xB06) - d0, 0);

    /* S: a stream over two untouched pages reads each line once. */
    uintptr_t stream_base = region(0x100000);
    settle(64);
    d0 = csr_read_num(0xB06);
    p0 = csr_read_num(0xB05);
    for (unsigned long i = 0; i < STREAM_LINES; i++)
        sum += *(volatile uint64_t *) (stream_base + i * 64);
    settle(2000);
    unsigned long d_stream = csr_read_num(0xB06) - d0;
    unsigned long p_stream = csr_read_num(0xB05) - p0;
    uart_printf("L2 stream: demand=%lu prefetch=%lu\r\n", d_stream, p_stream);
    expect_eq("S stream-lines-read-once", d_stream + p_stream, STREAM_LINES);
    report("S stream-prefetches", p_stream, 1, p_stream >= 1);

    /* O: the demand event wraps counter 6 and raises LCOFIP. */
    csr_write_num(0x344, csr_read_num(0x344) & ~LCOF);
    csr_write_num(0xB06, 0ul - 4);
    sum += scatter(region(0x200000), SCATTER_PAGES);
    settle(2000);
    expect_eq("O wrapped-count", csr_read_num(0xB06), SCATTER_PAGES - 4);
    expect_eq("O of-set", csr_read_num(0x326), OF | SEL_L2_DEMAND);
    expect_eq("O lcofip-set", csr_read_num(0x344) & LCOF, LCOF);
    expect_eq("O scountovf", csr_read_num(0xDA0) & (1ul << 6), 1ul << 6);
    csr_write_num(0x326, 0);
    csr_write_num(0x344, csr_read_num(0x344) & ~LCOF);
    csr_write_num(0x323, 0);
    csr_write_num(0x325, 0);

    uart_printf("sum=%lu\r\n", sum);
    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
