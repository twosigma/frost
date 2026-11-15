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
 *      32-byte lines, each in its own page and followed by eight stub lines
 *      that hold a ret. After fence.i the other body and both bodies' stubs
 *      run first. Allocation requests can precede the opening counter read,
 *      so cold windows have bounds, not an exact body-size count. Four
 *      alternating pairs check the long/short difference, a separate warm
 *      second pass refills nothing, and MINH stops the count in M. The code
 *      pages are already in L2; L1D misses and both L2 refill counters must
 *      stay zero in these instruction-only windows. The cache/home benches
 *      and formal properties check exact request-to-pulse accounting.
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
 * the bodies and the data regions use the cached tier. A run count in DDR,
 * which a reset keeps, gives each run its own untouched lines.
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

#define STUB_LINES 8ul

/* Before the opening sample, a predicted entry can request the body's
 * leading line and the fetch provider's next-line partner. This fixture
 * primes the other body and all return stubs, but deliberately permits
 * those two leading allocations to precede the sample. The body itself
 * must finish before the closing sample; settle() drains its registered
 * events. A trailing next-line request can finish after the return or
 * closing sample, but targets an already primed stub, so adds no refill.
 * Thus a cold N-line body contributes [N - 2, N] and a warm pass zero.
 * These are allocation-window bounds, not expected counts inferred from
 * one run. Exact allocation/read accounting belongs in the cache benches. */
#define LEADING_LINES 2ul

/* Straight-line bodies, each at the start of its own 4 KiB page, without
 * compressed instructions: a body of N 32-byte lines holds 8N - 1 addi and a
 * ret. STUB_LINES lines follow it, each a ret and seven nops, then zeros to
 * the page end, so a wrong-path fetch from a stale jump target in one body's
 * page (a stub of an earlier run) never reaches the other body. */
#define REFILL_BODY(name, lines)                                                                   \
    ".balign 4096\n"                                                                               \
    ".globl " #name "\n" #name ":\n"                                                               \
    ".rept 8 * " #lines " - 1\n"                                                                   \
    "addi a0, a0, 1\n"                                                                             \
    ".endr\n"                                                                                      \
    "ret\n"                                                                                        \
    ".rept 8\n"                                                                                    \
    "ret\n"                                                                                        \
    ".rept 7\n"                                                                                    \
    "nop\n"                                                                                        \
    ".endr\n"                                                                                      \
    ".endr\n"
__asm__(".pushsection .ddr_text, \"ax\", @progbits\n"
        ".option push\n"
        ".option norvc\n" REFILL_BODY(hpm_body_short, 8)
            REFILL_BODY(hpm_body_long, 24) ".option pop\n"
                                           ".popsection\n");

typedef unsigned long (*body_fn)(unsigned long);

/* Low BRAM text reaches the bodies through a table of their addresses (the
 * medany code model cannot reach DDR symbols PC-relative); the table's
 * references also keep the bodies through --gc-sections. */
extern char hpm_body_short[], hpm_body_long[];
static const volatile uintptr_t body_addr[2] = {(uintptr_t) hpm_body_short,
                                                (uintptr_t) hpm_body_long};
#define BODY_SHORT ((body_fn) body_addr[0])
#define BODY_LONG ((body_fn) body_addr[1])
#define INSN_ADDI 0x00150513u /* addi a0, a0, 1 */
#define INSN_RET 0x00008067u  /* jalr x0, 0(ra) */

/* The run count: a DDR word a reset keeps, read and written through its address
 * (the medany code model cannot reach DDR symbols from low BRAM text). */
#define RUN_COUNT (*(volatile unsigned long *) (CACHED_BASE + 0xF00000))
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

static void expect_range(const char *name, unsigned long got, unsigned long low, unsigned long high)
{
    int pass = low <= got && got <= high;
    uart_printf(
        "%s %s got=%lu range=[%lu,%lu]\r\n", pass ? "[PASS]" : "[FAIL]", name, got, low, high);
    ok &= pass;
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

/* Each body has its own call site, so no indirect jump in the window names
 * the other body. */
__attribute__((noipa)) static unsigned long call_short(unsigned long x)
{
    volatile body_fn f = BODY_SHORT;
    return f(x);
}

__attribute__((noipa)) static unsigned long call_long(unsigned long x)
{
    volatile body_fn f = BODY_LONG;
    return f(x);
}

static const struct {
    body_fn call;
    uintptr_t base;
    unsigned long lines;
} bodies[2] = {{call_short, 0, SHORT_LINES}, {call_long, 1, LONG_LINES}};

/* Run a body's stub lines. */
static void run_stubs(int which, unsigned long *sum)
{
    uintptr_t base = body_addr[bodies[which].base];
    for (unsigned long i = 0; i < STUB_LINES; i++) {
        volatile body_fn stub = (body_fn) (base + (bodies[which].lines + i) * 32);
        *sum += stub(*sum);
    }
}

struct refill_counts {
    unsigned long l1i, l1d, demand, prefetch;
};

/* The BRAM driver and stack do not access the cached data path. Warming
 * both complete code pages also covers next-line and speculative requests
 * within them, so instruction execution cannot require an L2 memory read. */
static void warm_code_pages(unsigned long *sum)
{
    for (int which = 0; which < 2; which++) {
        uintptr_t page = body_addr[which] & ~4095ul;
        for (unsigned long offset = 0; offset < 4096; offset += 64)
            *sum += *(volatile uint64_t *) (page + offset);
    }
    settle(2000);
}

static struct refill_counts measure_body(int which, unsigned long *sum)
{
    unsigned long l1d = csr_read_num(0xB07);
    unsigned long demand = csr_read_num(0xB06);
    unsigned long prefetch = csr_read_num(0xB05);
    unsigned long l1i = csr_read_num(0xB03);
    *sum += bodies[which].call(*sum);
    settle(64);
    struct refill_counts counts;
    counts.l1i = csr_read_num(0xB03) - l1i;
    counts.l1d = csr_read_num(0xB07) - l1d;
    counts.demand = csr_read_num(0xB06) - demand;
    counts.prefetch = csr_read_num(0xB05) - prefetch;
    return counts;
}

/* Prime wrong-path targets without executing the measured body. The
 * LEADING_LINES allowance covers an early request to its predicted entry. */
static struct refill_counts l1i_refills(int which, unsigned long *sum)
{
    fence_i();
    *sum += bodies[!which].call(*sum);
    run_stubs(!which, sum);
    run_stubs(which, sum);
    settle(256);
    return measure_body(which, sum);
}

static void expect_instruction_only(struct refill_counts counts)
{
    expect_eq("L no-data-misses", counts.l1d, 0);
    expect_eq("L no-L2-demand", counts.demand, 0);
    expect_eq("L no-L2-prefetch", counts.prefetch, 0);
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
    unsigned long sum = 0;
    unsigned long run = RUN_COUNT;

    RUN_COUNT = run + 1;
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
    csr_write_num(0x327, 7); /* fixed L1D permission misses */
    expect_eq("selector-3", csr_read_num(0x323), SEL_L1I_REFILL);
    expect_eq("selector-6", csr_read_num(0x326), SEL_L2_DEMAND);
    expect_eq("selector-5", csr_read_num(0x325), SEL_L2_PREFETCH);

    /* L: bounded cold windows, a zero warm window, and distinct sources. */
    const volatile uint32_t *ws = (const volatile uint32_t *) BODY_SHORT;
    const volatile uint32_t *wl = (const volatile uint32_t *) BODY_LONG;
    expect_eq("L short-body-placed", ws[0] == INSN_ADDI && ws[8 * SHORT_LINES - 1] == INSN_RET, 1);
    expect_eq("L long-body-placed", wl[0] == INSN_ADDI && wl[8 * LONG_LINES - 1] == INSN_RET, 1);
    warm_code_pages(&sum);
    (void) l1i_refills(0, &sum);
    (void) l1i_refills(1, &sum);
    for (int k = 0; k < 4; k++) {
        struct refill_counts cold_short = l1i_refills(0, &sum);
        struct refill_counts warm_short = measure_body(0, &sum);
        struct refill_counts cold_long = l1i_refills(1, &sum);
        struct refill_counts warm_long = measure_body(1, &sum);
        uart_printf("L1I refills %d: short=%lu long=%lu warm-short=%lu warm-long=%lu\r\n",
                    k,
                    cold_short.l1i,
                    cold_long.l1i,
                    warm_short.l1i,
                    warm_long.l1i);
        expect_range("L short-window", cold_short.l1i, SHORT_LINES - LEADING_LINES, SHORT_LINES);
        expect_range("L long-window", cold_long.l1i, LONG_LINES - LEADING_LINES, LONG_LINES);
        /* Each window can independently lose zero to LEADING_LINES early
         * requests. Subtracting them gives a difference allowance of +/-
         * LEADING_LINES, not twice that, around the body-size difference. */
        expect_range("L long-minus-short",
                     cold_long.l1i - cold_short.l1i,
                     LONG_LINES - SHORT_LINES - LEADING_LINES,
                     LONG_LINES - SHORT_LINES + LEADING_LINES);
        expect_eq("L warm-short", warm_short.l1i, 0);
        expect_eq("L warm-long", warm_long.l1i, 0);
        expect_instruction_only(cold_short);
        expect_instruction_only(cold_long);
        expect_instruction_only(warm_short);
        expect_instruction_only(warm_long);
    }
    csr_write_num(0x323, MINH | SEL_L1I_REFILL);
    expect_eq("L minh-stops-m", l1i_refills(1, &sum).l1i, 0);
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
    csr_write_num(0x327, 0);

    uart_printf("sum=%lu\r\n", sum);
    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
