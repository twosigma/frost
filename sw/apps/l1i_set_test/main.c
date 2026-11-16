/*
 *    Copyright (c) 2026 John Goodacre.
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
 * L1I set coverage: every set of a 32 KiB L1I (four ways of 256 sets of
 * 32-byte lines, set = PA[12:5]) is filled, hit, patched and cleared.
 *
 *   R  Regions 0..2, each 8 KiB of one-line functions { addi a0, x0, imm;
 *      ret; six rets }. Lines i and i+128 of a region differ only in PA[12]
 *      (one set at 16 KiB, two at 32 KiB); line i of each region shares a
 *      set at both sizes (8 KiB apart). Each round patches every line's
 *      immediate, executes fence.i, calls every line cold and then warm
 *      through one out-of-line pass that reads the counter around its calls,
 *      and checks that each call returns the round's value. The cold count
 *      runs from just before fence.i to the end of the cold pass, the warm
 *      count across the warm pass's calls. Cold and warm L1I refills/misses
 *      over the 24 KiB are checked via mhpmevent3 = 19 when supported or
 *      profiling counter 108 (L1I_MISS) when present, and an unfenced D-side
 *      overwrite checks directly that all 768 lines remain resident in a
 *      32 KiB L1I (three lines per set in four ways) while a 16 KiB L1I
 *      evicts and refetches at least a third of them.
 *   W  Set 133 (an upper set, PA[12] = 1): line 133 of regions 0..4, five
 *      lines in four ways, patched and called twice per round.
 *   V  Sv39 from S-mode: VA page 0x400000 (VA[12] = 0) maps to a code page
 *      with PA[12] = 1 and VA page 0x401000 (VA[12] = 1) to one with
 *      PA[12] = 0. Code at VA 0x400FF8 runs across the page boundary to an
 *      ecall; the patched immediates on both pages must arrive. A second
 *      Sv39 check primes VA 0x400540 (VA[12:5] = 42, PA[12:5] = 170),
 *      patches memory without fence.i, flushes the fetch provider with an
 *      unrelated set to confirm L1I residence, then evicts physical set 170
 *      from M-mode and verifies S-mode refetches the patched line rather
 *      than hitting a virtual-set alias at set 42.
 *
 * The code regions, page tables and S-mode pages are at fixed DDR
 * addresses, and the stack is in low BRAM. In the BRAM build the rest of
 * the program is also in low BRAM, and the first statement of main calls a
 * .ddr_text function, so the first cached fetch after reset follows the L1I
 * reset sweep (256 sets with SIM_FAST_MAINT=0). In the DDR build the whole
 * program runs from cached DDR behind the low BRAM boot stub: the fetch of
 * _start is the first cached fetch after reset and follows that sweep, and
 * the program's own instruction lines share the L1I with the regions.
 */

#include <stdint.h>

#include "csr.h"
#include "tomasulo_profile.h"
#include "trap.h"
#include "uart.h"

#ifndef L1I_TEST_BYTES
#define L1I_TEST_BYTES 16384
#endif

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

#define CODE_BASE 0x81200000ul /* seven 8 KiB regions (0..6) below SV_PAGES */
#define REGION_BYTES 0x2000ul
#define LINES 256ul
#define SV_PAGES 0x81210000ul /* three 4 KiB pages: PA[12] = 0, 1, 0 */
#define PT_ROOT 0x81220000ul
#define PT_L1 0x81221000ul
#define PT_L0 0x81222000ul
#define VA_P0 0x00400000ul /* VA[12] = 0 */
#define UPPER_LINE 133ul
#define VA_ALIAS_OFF 0x540ul /* line 42: VA[12:5] = 42, q1 PA[12:5] = 170 */
#define FLUSH_LINE_A 6ul     /* PA[5] = 0, disjoint from sets 42 and 170 */
#define FLUSH_LINE_B 8ul     /* PA[5] = 0, disjoint from sets 42 and 170 */
#define ALIAS_PHYS_LINE 170ul

#define SEL_L1I_REFILL 19ul
#define L1I_COUNT_NONE 0
#define L1I_COUNT_HPM3 1
#define L1I_COUNT_MPERF 2
#define INSN_RET 0x00008067u
#define INSN_ECALL 0x00000073u
#define SATP_SV39 (8ul << 60)
#define PTE_V (1ul << 0)
#define PTE_X (1ul << 3)
#define PTE_A (1ul << 6)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)

typedef unsigned long (*line_fn)(void);

/* addi rd, x0, imm (imm in 0..2047) */
static uint32_t addi(unsigned rd, unsigned long imm)
{
    return 0x00000013u | (rd << 7) | ((uint32_t) (imm & 0xFFF) << 20);
}

static inline void fence_i(void)
{
    __asm__ volatile("fence.i" ::: "memory");
}

static int ok = 1;

static void expect(const char *name, unsigned long got, unsigned long want)
{
    if (got != want) {
        uart_printf("[FAIL] %s got=%lu want=%lu\r\n", name, got, want);
        ok = 0;
    }
}

static int detect_l1i_counter(void)
{
    csr_write_num(0x320, 0); /* mcountinhibit: count everything */
    csr_write_num(0x323, SEL_L1I_REFILL);
    if ((csr_read_num(0x323) & 0xFFul) == SEL_L1I_REFILL)
        return L1I_COUNT_HPM3;
    if (csr_read_imm(CSR_MPERFCOUNT) > TOMASULO_PERF_L1I_MISS)
        return L1I_COUNT_MPERF;
    return L1I_COUNT_NONE;
}

static unsigned long read_l1i_counter(int mode)
{
    if (mode == L1I_COUNT_HPM3)
        return csr_read_num(0xB03);
    if (mode == L1I_COUNT_MPERF) {
        csr_write_imm(CSR_MPERFCTL, 1U);
        csr_write_imm(CSR_MPERFSEL, TOMASULO_PERF_L1I_MISS);
        return (unsigned long) tomasulo_profile_read_selected_counter64();
    }
    return 0;
}

/* In the BRAM build, the first cached fetch after reset; the DDR build has
 * fetched _start through the L1I before it. main calls it through an
 * address table, which BRAM text needs: the medany code model cannot reach
 * DDR symbols from low BRAM. */
__asm__(".pushsection .ddr_text, \"ax\", @progbits\n"
        ".option push\n"
        ".option norvc\n"
        ".balign 32\n"
        ".globl l1i_first_fetch\n"
        "l1i_first_fetch:\n"
        "addi a0, x0, 0x5A\n"
        "ret\n"
        ".option pop\n"
        ".popsection\n");
extern char l1i_first_fetch[];
static const volatile uintptr_t first_fetch_addr = (uintptr_t) l1i_first_fetch;

static volatile uint32_t *line_at(unsigned long region, unsigned long line)
{
    return (volatile uint32_t *) (CODE_BASE + region * REGION_BYTES + line * 32);
}

static unsigned long value(unsigned long round, unsigned long region, unsigned long line)
{
    return ((region * LINES + line) ^ (round * 0x555ul)) & 0x7FF;
}

static void write_line(unsigned long round, unsigned long region, unsigned long line)
{
    volatile uint32_t *w = line_at(region, line);
    w[0] = addi(10, value(round, region, line));
    for (int k = 1; k < 8; k++)
        w[k] = INSN_RET;
}

static unsigned long call_line(unsigned long region, unsigned long line)
{
    return ((line_fn) (uintptr_t) line_at(region, line))();
}

/* The L1I counter read just before a pass's first call and just after its
 * last one. */
struct l1i_window {
    unsigned long start;
    unsigned long end;
};

/* Call every line of regions 0..2; returns the number of wrong values and
 * records the L1I counter around the calls in *w. The cold and the warm pass
 * run this one body, counter reads included: noipa keeps the compiler from
 * inlining or cloning it per call. When the program itself runs from cached
 * DDR, sharing the body avoids the compulsory misses that a separate warm
 * copy of the loop would take on the architectural path (every call
 * returning its value): the cold pass fetches each line of that path after
 * the round's fence.i. Speculative fetches and next-line prefetches can
 * allocate lines the path never executes, such as the reads of an unused
 * counter mode, and the 32 KiB warm bound of 16 leaves room for them. */
__attribute__((noipa)) static unsigned long
pass(unsigned long round, const char *name, int mode, struct l1i_window *w)
{
    unsigned long bad = 0;
    w->start = read_l1i_counter(mode);
    for (unsigned long r = 0; r < 3; r++)
        for (unsigned long i = 0; i < LINES; i++) {
            unsigned long got = call_line(r, i);
            if (got != value(round, r, i)) {
                if (bad < 4)
                    uart_printf("[FAIL] %s round %lu region %lu line %lu got=%lu want=%lu\r\n",
                                name,
                                round,
                                r,
                                i,
                                got,
                                value(round, r, i));
                bad++;
            }
        }
    w->end = read_l1i_counter(mode);
    return bad;
}

/* Overwrite all 768 warm lines in L1D without fence.i and call them again.
 * A 32 KiB L1I keeps all 768 cached (three ways of 256 sets); a 16 KiB L1I
 * plus the 8-line fetch buffer holds at most 520 lines and refetches >= 248. */
static void check_residence(unsigned long round, unsigned long target_bytes)
{
    unsigned long refetched = 0;
    unsigned long bad = 0;

    for (unsigned long r = 0; r < 3; r++)
        for (unsigned long i = 0; i < LINES; i++) {
            volatile uint32_t *w = line_at(r, i);
            w[0] = addi(10, value(round, r, i) ^ 0x400ul);
        }
    __asm__ volatile("fence rw, rw" ::: "memory");

    for (unsigned long r = 0; r < 3; r++)
        for (unsigned long i = 0; i < LINES; i++) {
            unsigned long cached = value(round, r, i);
            unsigned long patched = cached ^ 0x400ul;
            unsigned long got = call_line(r, i);
            if (got == patched)
                refetched++;
            else if (got != cached)
                bad++;
        }
    expect("R unfenced overwrite unexpected values", bad, 0);
    uart_printf(
        "R round %lu: unfenced 24 KiB re-call refetched %lu/768 lines\r\n", round, refetched);
    if (target_bytes >= 32768ul) {
        if (refetched > 16) {
            uart_printf("[FAIL] R unfenced refetched %lu > 16 with a 32 KiB L1I\r\n", refetched);
            ok = 0;
        }
    } else if (refetched < 248) {
        uart_printf("[FAIL] R unfenced refetched %lu < 248 with a 16 KiB L1I\r\n", refetched);
        ok = 0;
    }
}

/* --- V: Sv39 page crossing and PA[12] != VA[12] set indexing ------------ */

volatile unsigned long g_v_cause, g_v_a0, g_v_a1;

/* Records mcause, a0 and a1, then returns to run_s's continuation in M. */
__attribute__((naked, aligned(4))) static void v_trap_handler(void)
{
    __asm__ volatile("la   t1, g_v_cause\n"
                     "csrr t0, mcause\n"
                     "sd   t0, 0(t1)\n"
                     "la   t1, g_v_a0\n"
                     "sd   a0, 0(t1)\n"
                     "la   t1, g_v_a1\n"
                     "sd   a1, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* Enter S-mode at `target`; its ecall returns here. */
static void run_s(unsigned long target)
{
    g_v_cause = ~0ul;
    g_v_a0 = ~0ul;
    g_v_a1 = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %0\n"
                     "li   a0, 0\n"
                     "li   a1, 0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(target)
                     : "t0", "t1", "t2", "t3", "a0", "a1", "ra", "memory");
}

static void v_case(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    unsigned long q1 = SV_PAGES + 0x1000; /* PA[12] = 1 */
    unsigned long q2 = SV_PAGES + 0x2000; /* PA[12] = 0 */
    volatile uint32_t *pa_alias = (volatile uint32_t *) (q1 + VA_ALIAS_OFF);

    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[2] = PTE_PPN(PT_L0) | PTE_V; /* VA 0x400000 .. 0x5FFFFF */
    l0[0] = PTE_PPN(q1) | PTE_V | PTE_X | PTE_A;
    l0[1] = PTE_PPN(q2) | PTE_V | PTE_X | PTE_A;

    set_trap_handler(&v_trap_handler);
    __asm__ volatile("sfence.vma" ::: "memory");
    csr_write_num(satp, SATP_SV39 | (PT_ROOT >> 12));

    for (unsigned long round = 0; round < 3; round++) {
        unsigned long a = 0x100 + round * 0x123, b = 0x200 + round * 0x0F1;
        volatile uint32_t *p1 = (volatile uint32_t *) (q1 + 0xFF8);
        volatile uint32_t *p2 = (volatile uint32_t *) q2;
        p1[0] = addi(10, a); /* VA 0x400FF8: addi a0, x0, a */
        p1[1] = addi(0, 0);  /* VA 0x400FFC: nop */
        p2[0] = addi(11, b); /* VA 0x401000: addi a1, x0, b */
        p2[1] = INSN_ECALL;  /* VA 0x401004 */
        fence_i();
        for (int k = 0; k < 2; k++) {
            __asm__ volatile("sfence.vma" ::: "memory");
            run_s(VA_P0 + 0xFF8);
            expect("V cause (ecall from S)", g_v_cause, 9);
            expect("V a0 from the PA[12]=1 page", g_v_a0, a);
            expect("V a1 from the PA[12]=0 page", g_v_a1, b);
        }
        uart_printf("V round %lu: a0=%lu a1=%lu cause=%lu\r\n", round, g_v_a0, g_v_a1, g_v_cause);
    }

    /* Prime VA 0x400540 (VA[12:5] = 42 -> PA[12:5] = 170), patch memory without
     * fence.i, displace the fetch provider via sets 6 and 8 to prove L1I
     * residence, then evict physical set 170 from M-mode and confirm refetch. */
    for (unsigned long r = 0; r < 5; r++) {
        write_line(0, r, FLUSH_LINE_A);
        write_line(0, r, FLUSH_LINE_B);
    }
    for (unsigned long r = 0; r < 7; r++)
        write_line(0, r, ALIAS_PHYS_LINE);
    pa_alias[0] = addi(10, 0x155);
    pa_alias[1] = INSN_ECALL;
    fence_i();
    __asm__ volatile("sfence.vma" ::: "memory");

    run_s(VA_P0 + VA_ALIAS_OFF);
    expect("V alias prime cause", g_v_cause, 9);
    expect("V alias prime a0", g_v_a0, 0x155);

    pa_alias[0] = addi(10, 0x2AA);
    __asm__ volatile("fence rw, rw" ::: "memory");
    for (unsigned long r = 0; r < 5; r++) {
        (void) call_line(r, FLUSH_LINE_A);
        (void) call_line(r, FLUSH_LINE_B);
    }
    run_s(VA_P0 + VA_ALIAS_OFF);
    expect("V alias L1I hit cause", g_v_cause, 9);
    expect("V alias hits L1I before set-170 eviction", g_v_a0, 0x155);

    for (int k = 0; k < 2; k++)
        for (unsigned long r = 0; r < 7; r++)
            (void) call_line(r, ALIAS_PHYS_LINE);
    run_s(VA_P0 + VA_ALIAS_OFF);
    expect("V alias post-evict cause", g_v_cause, 9);
    expect("V alias refetches after PA[12:5] eviction", g_v_a0, 0x2AA);

    csr_write_num(satp, 0);
    __asm__ volatile("sfence.vma" ::: "memory");
}

int main(void)
{
    unsigned long first = ((line_fn) first_fetch_addr)();
    unsigned long target_bytes = L1I_TEST_BYTES;
    int counter_mode = detect_l1i_counter();

    uart_printf(
        "L1I set test (L1I_TEST_BYTES=%lu, counter_mode=%d)\r\n", target_bytes, counter_mode);
    expect("first cached fetch after reset", first, 0x5A);

    for (unsigned long round = 0; round < 3; round++) {
        for (unsigned long r = 0; r < 3; r++)
            for (unsigned long i = 0; i < LINES; i++)
                write_line(round, r, i);
        /* The cold count opens before fence.i, so that it holds every refill
         * after the invalidation: a counter read executes at commit, and the
         * front end can fetch a predicted call target (a region line) and its
         * next line before the pass reads the counter. */
        unsigned long before_fence = read_l1i_counter(counter_mode);
        fence_i();

        struct l1i_window cold;
        struct l1i_window warm;
        unsigned long bad_cold = pass(round, "R cold", counter_mode, &cold);
        unsigned long bad_warm = pass(round, "R warm", counter_mode, &warm);
        unsigned long cold_misses = cold.end - before_fence;
        unsigned long warm_misses = warm.end - warm.start;
        expect("R cold wrong values", bad_cold, 0);
        expect("R warm wrong values", bad_warm, 0);
        if (counter_mode != L1I_COUNT_NONE) {
            uart_printf("R round %lu: cold=%lu warm=%lu L1I misses/refills\r\n",
                        round,
                        cold_misses,
                        warm_misses);
            if (cold_misses < 3 * LINES) {
                uart_printf(
                    "[FAIL] R cold misses %lu < %lu\r\n", cold_misses, (unsigned long) (3 * LINES));
                ok = 0;
            }
            if (target_bytes >= 32768ul) {
                if (warm_misses > 16) {
                    uart_printf("[FAIL] R warm misses %lu > 16 with a 32 KiB L1I\r\n", warm_misses);
                    ok = 0;
                }
            } else if (warm_misses < 248) {
                uart_printf("[FAIL] R warm misses %lu < 248 with a 16 KiB L1I\r\n", warm_misses);
                ok = 0;
            }
        }
        check_residence(round, target_bytes);

        for (unsigned long r = 0; r < 5; r++)
            write_line(round, r, UPPER_LINE);
        fence_i();
        for (int k = 0; k < 2; k++)
            for (unsigned long r = 0; r < 5; r++)
                expect("W set-133 line", call_line(r, UPPER_LINE), value(round, r, UPPER_LINE));
    }

    v_case();

    uart_printf("%s", ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    while (1) {
    }
    return 0;
}
