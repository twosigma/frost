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
 * Linux clocksource-switch timer stressor (M-mode, DDR-resident).
 *
 * Unlike the linux_irq_* tests, this one mirrors no-MMU Linux after the
 * switch to clint_clocksource:
 *
 *   - clint_clock_next_event() enables MTIE before an
 *     io-64-nonatomic-lo-hi mtimecmp write, exposing the old deadline and a
 *     torn {old_hi,new_lo} value.
 *   - clint_timer_interrupt() clears MTIE, then the event handler re-arms it.
 *   - arch_cpu_idle() uses bare wfi while mstatus.MIE remains enabled.
 *   - before each wfi the idle loop churns one to four cached-DDR lines, each
 *     fetched from DDR (see CHURN_BASE), so ticks land both during these
 *     bursts, when misses can be in flight, and at the wfi. The handler
 *     counts ticks taken during a burst and ticks taken outside one.
 *
 * The registered simulation uses a deliberately small L2 and
 * DDR_MODEL_LATENCY>=70, so the misses go to DDR. Frame violations report a
 * failure code. So does a run in which fewer than MIN_TICKS_EACH ticks land
 * during the bursts or outside them (code 7): the timing no longer covers
 * both cases, and the burst lengths need retuning. A deadlock fails the run
 * when the simulation cycle budget runs out.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

/* Kernel-mirror rv64 frame: full-width slots and mcause bit 63. XB is a string
 * so gas evaluates "n*" XB offsets. */
#define XS "sd  "
#define XL "ld  "
#define XSC "sc.d"
#define XB "8"

#define CLINT_MTIMECMP_LO (*(volatile uint32_t *) 0x40014000u)
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *) 0x40014004u)
#define CLINT_MTIME_LO (*(volatile uint32_t *) 0x4001BFF8u)
#define CLINT_MTIME_HI (*(volatile uint32_t *) 0x4001BFFCu)

#define TARGET_TICKS 128u
#define MIN_TICKS_EACH (TARGET_TICKS / 8u)
#define DDR_STACK_SIZE 4096u

/* The idle loop churns CHURN_WORDS words (8 KiB) in CHURN_SLICES slices
 * placed CHURN_STRIDE apart in DDR past the program image, and the handler
 * touches HANDLER_LINES, a slice-sized region one stride above the last
 * slice; nothing else uses either. The caches are direct-mapped and the stride
 * is a multiple of their sizes (the 128 KiB L1D, the registered simulation's
 * 4 KiB L2), so the lines at one offset in every slice and in HANDLER_LINES
 * map to the same line of each cache. The idle loop walks the slices in turn,
 * so by the time it churns a line the other slices have evicted it, and the
 * line comes from DDR. */
#define CHURN_BASE 0x80800000u
#define CHURN_STRIDE 0x00100000u /* 1 MiB */
#define CHURN_SLICES 8u
#define CHURN_SLICE_WORDS 256u /* 1 KiB */
#define CHURN_WORDS (CHURN_SLICES * CHURN_SLICE_WORDS)
#define HANDLER_LINES (CHURN_BASE + CHURN_SLICES * CHURN_STRIDE)
#define LINE_WORDS 8u /* 32-byte cache lines */

struct linux_pt_regs {
    unsigned long epc, ra, sp, gp, tp;
    unsigned long t0, t1, t2, s0, s1;
    unsigned long a0, a1, a2, a3, a4, a5, a6, a7;
    unsigned long s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
    unsigned long t3, t4, t5, t6;
    unsigned long status, badaddr, cause, orig_a0;
};

struct fake_current {
    unsigned long kernel_sp;
    unsigned long user_sp;
    unsigned long marker;
};

volatile struct fake_current g_fake_current = {0u, 0u, 0x5441534Bu};
volatile uint32_t g_ticks;
volatile uint32_t g_fail_code;
volatile uint32_t g_fail_seen;
volatile unsigned long g_last_mepc;
volatile unsigned long g_last_ra;
volatile unsigned long g_last_sp;
volatile unsigned long g_last_tp;
volatile unsigned long g_last_mscratch;
volatile uint32_t g_in_churn;    /* set during an idle-loop churn burst */
volatile uint32_t g_ticks_churn; /* ticks taken during a burst */
volatile uint32_t g_ticks_wfi;   /* ticks taken outside a burst */
static uint8_t g_ddr_stack[DDR_STACK_SIZE] __attribute__((aligned(16)));

static inline uintptr_t read_tp(void)
{
    uintptr_t v;
    __asm__ volatile("mv %0, tp" : "=r"(v));
    return v;
}

static inline void write_tp(uintptr_t v)
{
    __asm__ volatile("mv tp, %0" : : "r"(v) : "memory");
}

/* Only the first failure sets the reported code. */
static void record_failure(uint32_t code)
{
    if (!g_fail_seen) {
        g_fail_seen = 1u;
        g_fail_code = code;
    }
}

static uint64_t clint_rdmtime(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi = CLINT_MTIME_HI;
        lo = CLINT_MTIME_LO;
        hi2 = CLINT_MTIME_HI;
    } while (hi != hi2);
    return ((uint64_t) hi << 32) | lo;
}

/* Linux clint_clock_next_event(): enable MTIE, then write lo and hi. */
static void clint_clock_next_event(uint64_t cmp)
{
    csr_set(mie, MIE_MTIE);
    CLINT_MTIMECMP_LO = (uint32_t) cmp;
    CLINT_MTIMECMP_HI = (uint32_t) (cmp >> 32);
}

static inline volatile uint32_t *churn_word(uint32_t i)
{
    return (volatile uint32_t *) (uintptr_t) (CHURN_BASE + (i / CHURN_SLICE_WORDS) * CHURN_STRIDE +
                                              (i % CHURN_SLICE_WORDS) * 4u);
}

/* Read-modify-write words [first, first + count) of the churn, wrapping. */
static uint32_t churn_ddr(uint32_t seed, uint32_t first, uint32_t count)
{
    uint32_t acc = seed;
    for (uint32_t i = first; i < first + count; i++) {
        volatile uint32_t *w = churn_word(i & (CHURN_WORDS - 1u));
        uint32_t v = *w;
        acc ^= v + (i << 3);
        acc = (acc << 5) | (acc >> 27);
        *w = v ^ acc ^ (0x9E3779B9u + i);
    }
    return acc;
}

/* Linux clint_timer_interrupt(): clear MTIE, then re-arm through the handler. */
__attribute__((noinline, used)) void faithful_irq_c(struct linux_pt_regs *frame)
{
    csr_clear(mie, MIE_MTIE);
    if (g_in_churn) {
        g_ticks_churn = g_ticks_churn + 1u;
    } else {
        g_ticks_wfi = g_ticks_wfi + 1u;
    }

    g_last_mepc = frame->epc;
    g_last_ra = frame->ra;
    g_last_sp = frame->sp;
    g_last_tp = frame->tp;
    g_last_mscratch = csr_read(mscratch);

    if (frame->cause != (MCAUSE_INTERRUPT_BIT | INT_MTI)) {
        record_failure(1u);
    }
    /* epc and ra must stay in DDR; ra == epc == 0xCC0 is the failure signature. */
    if (frame->epc < 0x80000000u || frame->epc == 0x00000CC0u) {
        record_failure(2u);
    }
    if (frame->ra < 0x80000000u || frame->ra == 0x00000CC0u) {
        record_failure(3u);
    }
    if (frame->sp < (uintptr_t) &g_ddr_stack[0] ||
        frame->sp > (uintptr_t) &g_ddr_stack[DDR_STACK_SIZE]) {
        record_failure(4u);
    }
    if (frame->tp != (uintptr_t) &g_fake_current) {
        record_failure(5u);
    }
    if (g_last_mscratch != 0u) {
        record_failure(6u);
    }

    /* A light cached touch (one line, rotating through HANDLER_LINES) keeps
     * the handler short; the idle loop does the churning. */
    {
        uint32_t off = (g_ticks * LINE_WORDS * 4u) & (CHURN_SLICE_WORDS * 4u - 1u);
        volatile uint32_t *line = (volatile uint32_t *) (uintptr_t) (HANDLER_LINES + off);
        uint32_t acc = frame->epc ^ frame->ra ^ g_ticks;
        for (uint32_t i = 0; i < LINE_WORDS; i++) {
            acc ^= line[i];
            line[i] = acc + i;
        }
    }
    g_ticks = g_ticks + 1u;

    /* event_handler -> clint_clock_next_event(now + delta). Vary the delta so
     * the IRQ phase relative to the idle churn/wfi sweeps across alignments. */
    clint_clock_next_event(clint_rdmtime() + 256u + ((uint64_t) (g_ticks & 63u) << 3));
}

/* Linux-style naked trap entry: save/restore the GPR frame on the current
 * (DDR) stack, csrrw tp,mscratch,tp swap idiom, sc.d (XSC) in the return
 * path. */
__attribute__((naked, aligned(4))) static void faithful_irq_entry(void)
{
    __asm__ volatile(
        "csrrw tp, mscratch, tp\n"
        "bnez tp, 1f\n"
        "csrr tp, mscratch\n"
        "1:\n"
        "addi sp, sp, -36*" XB "\n" XS " ra, 1*" XB "(sp)\n" XS " gp, 3*" XB "(sp)\n" XS
        " t0, 5*" XB "(sp)\n" XS " t1, 6*" XB "(sp)\n" XS " t2, 7*" XB "(sp)\n" XS " s0, 8*" XB
        "(sp)\n" XS " s1, 9*" XB "(sp)\n" XS " a0, 10*" XB "(sp)\n" XS " a1, 11*" XB "(sp)\n" XS
        " a2, 12*" XB "(sp)\n" XS " a3, 13*" XB "(sp)\n" XS " a4, 14*" XB "(sp)\n" XS " a5, 15*" XB
        "(sp)\n" XS " a6, 16*" XB "(sp)\n" XS " a7, 17*" XB "(sp)\n" XS " s2, 18*" XB "(sp)\n" XS
        " s3, 19*" XB "(sp)\n" XS " s4, 20*" XB "(sp)\n" XS " s5, 21*" XB "(sp)\n" XS " s6, 22*" XB
        "(sp)\n" XS " s7, 23*" XB "(sp)\n" XS " s8, 24*" XB "(sp)\n" XS " s9, 25*" XB "(sp)\n" XS
        " s10, 26*" XB "(sp)\n" XS " s11, 27*" XB "(sp)\n" XS " t3, 28*" XB "(sp)\n" XS
        " t4, 29*" XB "(sp)\n" XS " t5, 30*" XB "(sp)\n" XS " t6, 31*" XB "(sp)\n" XS " a0, 35*" XB
        "(sp)\n"
        "addi t0, sp, 36*" XB "\n" XS " t0, 2*" XB "(sp)\n"
        "csrr t0, mepc\n" XS " t0, 0*" XB "(sp)\n"
        "csrr t0, mstatus\n" XS " t0, 32*" XB "(sp)\n"
        "csrr t0, mtval\n" XS " t0, 33*" XB "(sp)\n"
        "csrr t0, mcause\n" XS " t0, 34*" XB "(sp)\n"
        "csrr t0, mscratch\n" XS " t0, 4*" XB "(sp)\n"
        "csrw mscratch, x0\n"
        "mv   a0, sp\n"
        "call faithful_irq_c\n" XL " a0, 32*" XB "(sp)\n" XL " a2, 0*" XB "(sp)\n" XSC
        " x0, a2, 0(sp)\n"
        "csrw mstatus, a0\n"
        "csrw mepc, a2\n" XL " ra, 1*" XB "(sp)\n" XL " gp, 3*" XB "(sp)\n" XL " tp, 4*" XB
        "(sp)\n" XL " t0, 5*" XB "(sp)\n" XL " t1, 6*" XB "(sp)\n" XL " t2, 7*" XB "(sp)\n" XL
        " s0, 8*" XB "(sp)\n" XL " s1, 9*" XB "(sp)\n" XL " a0, 10*" XB "(sp)\n" XL " a1, 11*" XB
        "(sp)\n" XL " a2, 12*" XB "(sp)\n" XL " a3, 13*" XB "(sp)\n" XL " a4, 14*" XB "(sp)\n" XL
        " a5, 15*" XB "(sp)\n" XL " a6, 16*" XB "(sp)\n" XL " a7, 17*" XB "(sp)\n" XL " s2, 18*" XB
        "(sp)\n" XL " s3, 19*" XB "(sp)\n" XL " s4, 20*" XB "(sp)\n" XL " s5, 21*" XB "(sp)\n" XL
        " s6, 22*" XB "(sp)\n" XL " s7, 23*" XB "(sp)\n" XL " s8, 24*" XB "(sp)\n" XL " s9, 25*" XB
        "(sp)\n" XL " s10, 26*" XB "(sp)\n" XL " s11, 27*" XB "(sp)\n" XL " t3, 28*" XB "(sp)\n" XL
        " t4, 29*" XB "(sp)\n" XL " t5, 30*" XB "(sp)\n" XL " t6, 31*" XB "(sp)\n" XL " sp, 2*" XB
        "(sp)\n"
        "mret\n");
}

__attribute__((noreturn, noinline, used)) void main_on_ddr_stack(void)
{
    uart_printf("\n=== Linux faithful clocksource-switch timer test ===\n");

    for (uint32_t i = 0; i < CHURN_WORDS; i++) {
        *churn_word(i) = 0x80000000u ^ (i * 0x10204081u);
    }
    g_fake_current.kernel_sp = (uintptr_t) &g_ddr_stack[DDR_STACK_SIZE];
    g_fake_current.user_sp = 0u;

    write_tp((uintptr_t) &g_fake_current);
    csr_write(mscratch, 0u);
    set_trap_handler(&faithful_irq_entry);

    /* Start the clockevent (clint_timer_starting_cpu -> first next_event), then
     * enable MIE once and leave it on, exactly like the kernel after boot. */
    clint_clock_next_event(clint_rdmtime() + 384u);
    enable_interrupts();

    /* arch_cpu_idle(): bare wfi with MIE on. Each iteration first churns the
     * next one to four lines. The burst length varies so that some bursts end
     * before the next tick and some do not, and with the handler's varying
     * delta this puts ticks both in the churn and at the wfi. */
    uint32_t spin = 0x2468ACE0u;
    uint32_t next = 0u;
    for (uint32_t iter = 0u; g_ticks < TARGET_TICKS && !g_fail_seen; iter++) {
        uint32_t count = LINE_WORDS * (1u + (iter & 3u));
        g_in_churn = 1u;
        spin = churn_ddr(spin ^ g_ticks, next, count);
        g_in_churn = 0u;
        next = (next + count) & (CHURN_WORDS - 1u);
        __asm__ volatile("wfi" ::: "memory");
    }

    disable_timer_interrupt();
    disable_interrupts();

    if (g_ticks_churn < MIN_TICKS_EACH || g_ticks_wfi < MIN_TICKS_EACH) {
        record_failure(7u);
    }

    if (!g_fail_seen && g_ticks >= TARGET_TICKS && spin != 0u) {
        uart_printf("ticks=%u churn=%u wfi=%u spin=%08x last_mepc=%016lx last_ra=%016lx\n",
                    g_ticks,
                    g_ticks_churn,
                    g_ticks_wfi,
                    spin,
                    g_last_mepc,
                    g_last_ra);
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("FAIL code=%u ticks=%u churn=%u wfi=%u mepc=%016lx ra=%016lx sp=%016lx "
                    "tp=%016lx mscratch=%016lx\n",
                    g_fail_code,
                    g_ticks,
                    g_ticks_churn,
                    g_ticks_wfi,
                    g_last_mepc,
                    g_last_ra,
                    g_last_sp,
                    g_last_tp,
                    g_last_mscratch);
        uart_printf("<<FAIL>>\n");
    }

    for (;;) {
    }
}

int main(void)
{
    uintptr_t stack_top = ((uintptr_t) &g_ddr_stack[DDR_STACK_SIZE]) & ~(uintptr_t) 0xFu;
    __asm__ volatile("mv sp, %0\n"
                     "j  main_on_ddr_stack\n"
                     :
                     : "r"(stack_top)
                     : "memory");
    __builtin_unreachable();
}
