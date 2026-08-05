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
 * tick_torture -- Linux-faithful CLINT tick re-arm under heavy cached-DDR
 * traffic, hunting the flaky linux_boot silent hang (tick death).
 *
 * The no-MMU Linux boot dies when the periodic machine-timer tick stops:
 * jiffies freeze and the boot sleeps forever at its next timer-dependent
 * wait. The death concentrates in the heaviest DDR phase (initramfs
 * unpack), where the kernel's 250 Hz re-arm (3 MMIO stores: hi=-1, lo,
 * hi) and torn-read mtime loop (3 MMIO loads) constantly interleave with
 * write-back cache evictions/fills. This test compresses that regime:
 * a foreground thread thrashes a multi-MB DDR working set while a
 * Linux-style timer handler re-arms mtimecmp at a much higher rate than
 * the kernel's, with detectors the kernel lacks:
 *
 *   D1 re-arm readback: mtimecmp read back right after the 3-write
 *      sequence must equal the value written (catches dropped or
 *      mispaired MMIO stores).
 *   D2 lost tick watchdog: with the timer armed, an IRQ must arrive
 *      within WATCHDOG_PERIODS periods (catches dead delivery: MTIP
 *      never raised, or raised and never dispatched). Dumps mip/mie/
 *      mstatus + a fresh mtimecmp readback to tell the two apart.
 *   D3 WFI wake: a bounded WFI idle phase must observe tick progress
 *      (catches lost WFI wake-ups).
 *
 * All Linux-critical structure is preserved: DDR-resident code/data/stack,
 * the csrrw tp,mscratch,tp naked trap entry with full 144-byte frame, the
 * sc.w x0 stale-LR breaker before mret, absolute-next re-arm with
 * catch-up (tick_handle_periodic style).
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

/* XLEN split: the kernel-mirror trap frame holds XLEN-wide registers; sw/lw
 * at 4-byte stride truncates live 64-bit state at rv64 and the mcause
 * compare needs the interrupt bit at XLEN-1. XB is a string so gas evaluates
 * the "n*" XB offsets; rv32 expands to the original instructions unchanged.
 */
#if __riscv_xlen == 64
#define XS "sd  "
#define XL "ld  "
#define XSC "sc.d"
#define XB "8"
typedef uint64_t frame_word_t;
#else
#define XS "sw  "
#define XL "lw  "
#define XSC "sc.w"
#define XB "4"
typedef uint32_t frame_word_t;
#endif

#define CLINT_MTIMECMP_LO (*(volatile uint32_t *) 0x40014000u)
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *) 0x40014004u)
#define CLINT_MTIME_LO (*(volatile uint32_t *) 0x4001BFF8u)
#define CLINT_MTIME_HI (*(volatile uint32_t *) 0x4001BFFCu)

/* Tick period in mtime units (cycles). Linux uses 533,333 (4 ms at 133 MHz);
 * 8192 (~61 us) compresses ~65 boots' worth of re-arms into each second.
 * Both knobs are overridable (EXTRA_CFLAGS=-DTARGET_TICKS=...) so simulation
 * can run a shrunk sweep; the defaults are hardware-scale (~2.1B cycles). */
#ifndef PERIOD_CYCLES
#define PERIOD_CYCLES 8192u
#endif
#ifndef TARGET_TICKS
#define TARGET_TICKS 262144u /* ~16 s of armed time at 133 MHz */
#endif
#define WATCHDOG_PERIODS 64u
#define WFI_PHASE_EVERY 64u /* thrash sweeps between WFI idle phases */
#define DDR_STACK_SIZE 4096u
#ifndef WORKSET_WORDS
#define WORKSET_WORDS (512u * 1024u) /* 2 MiB working set, >> 128 KiB L1 */
#endif

/* Failure codes (g_fail_code). */
#define FAIL_READBACK 1u
#define FAIL_WATCHDOG 2u
#define FAIL_WFI_STUCK 3u
#define FAIL_BAD_CAUSE 4u

volatile uint32_t g_ticks;
volatile uint32_t g_fail_seen;
volatile uint32_t g_fail_code;
volatile uint32_t g_next_lo, g_next_hi; /* value the handler armed */
volatile uint32_t g_rb_lo, g_rb_hi;     /* readback at failure */
volatile uint32_t g_fail_mtime_lo, g_fail_mtime_hi;
volatile uint32_t g_catchups; /* re-arms that had to jump to now+period */

static uint32_t g_workset[WORKSET_WORDS] __attribute__((aligned(32)));
static uint8_t g_ddr_stack[DDR_STACK_SIZE] __attribute__((aligned(16)));

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

/* Linux drivers/clocksource/timer-clint.c write order: hi=-1, lo, hi. */
static void clint_set_timer_cmp(uint64_t cmp)
{
    CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    CLINT_MTIMECMP_LO = (uint32_t) cmp;
    CLINT_MTIMECMP_HI = (uint32_t) (cmp >> 32);
}

static void record_failure(uint32_t code)
{
    if (!g_fail_seen) {
        g_fail_code = code;
        g_fail_seen = 1u;
    }
}

__attribute__((noinline, used)) void tick_irq_c(frame_word_t *frame)
{
    frame_word_t cause = frame[34]; /* mcause slot of the 36-word frame */

    if (cause != (MCAUSE_INTERRUPT_BIT | INT_MTI)) {
        record_failure(FAIL_BAD_CAUSE);
    }

    /* tick_handle_periodic-style absolute re-arm with catch-up. */
    uint64_t next = (((uint64_t) g_next_hi << 32) | g_next_lo) + PERIOD_CYCLES;
    uint64_t now = clint_rdmtime();
    if (next <= now) {
        next = now + PERIOD_CYCLES;
        g_catchups = g_catchups + 1u;
    }
    g_next_lo = (uint32_t) next;
    g_next_hi = (uint32_t) (next >> 32);
    clint_set_timer_cmp(next);

    /* D1: the arm must be readable back verbatim. */
    uint32_t rb_lo = CLINT_MTIMECMP_LO;
    uint32_t rb_hi = CLINT_MTIMECMP_HI;
    if (rb_lo != (uint32_t) next || rb_hi != (uint32_t) (next >> 32)) {
        g_rb_lo = rb_lo;
        g_rb_hi = rb_hi;
        uint64_t t = clint_rdmtime();
        g_fail_mtime_lo = (uint32_t) t;
        g_fail_mtime_hi = (uint32_t) (t >> 32);
        record_failure(FAIL_READBACK);
    }

    g_ticks = g_ticks + 1u;
}

__attribute__((naked, aligned(4))) static void tick_irq_entry(void)
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
        " t4, 29*" XB "(sp)\n" XS " t5, 30*" XB "(sp)\n" XS " t6, 31*" XB "(sp)\n"
        "addi t0, sp, 36*" XB "\n" XS " t0, 2*" XB "(sp)\n"
        "csrr t0, mepc\n" XS " t0, 0*" XB "(sp)\n"
        "csrr t0, mstatus\n" XS " t0, 32*" XB "(sp)\n"
        "csrr t0, mtval\n" XS " t0, 33*" XB "(sp)\n"
        "csrr t0, mcause\n" XS " t0, 34*" XB "(sp)\n"
        "csrr t0, mscratch\n" XS " t0, 4*" XB "(sp)\n"
        "csrw mscratch, x0\n"
        "mv   a0, sp\n"
        "call tick_irq_c\n" XL " a0, 32*" XB "(sp)\n" XL " a2, 0*" XB "(sp)\n" XSC
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

/* One streaming sweep over the working set: line-stride stores force
 * continuous write-allocate fills + evictions; the xor-reduce read pass
 * keeps the read port busy too. Returns a value so nothing is elided. */
__attribute__((noinline)) static uint32_t thrash_sweep(uint32_t salt)
{
    uint32_t acc = salt;
    for (uint32_t i = 0; i < WORKSET_WORDS; i += 8u) {
        g_workset[i] = acc ^ (i << 3);
        g_workset[i + 7u] = acc + i;
        acc = (acc << 1) | (acc >> 31);
    }
    for (uint32_t i = 0; i < WORKSET_WORDS; i += 8u) {
        acc ^= g_workset[i] + g_workset[i + 7u];
    }
    return acc;
}

/* Snapshot handler-shared state with IRQs briefly masked. */
static void snapshot(uint32_t *ticks, uint64_t *armed)
{
    disable_interrupts();
    *ticks = g_ticks;
    *armed = ((uint64_t) g_next_hi << 32) | g_next_lo;
    enable_interrupts();
}

static void dump_death_state(const char *tag)
{
    disable_interrupts();
    uint64_t now = clint_rdmtime();
    uint32_t rb_lo = CLINT_MTIMECMP_LO;
    uint32_t rb_hi = CLINT_MTIMECMP_HI;
    uart_printf("%s: mtime=%08x_%08x mtimecmp_rb=%08x_%08x armed=%08x_%08x\n",
                tag,
                (uint32_t) (now >> 32),
                (uint32_t) now,
                rb_hi,
                rb_lo,
                g_next_hi,
                g_next_lo);
    uart_printf("%s: mip=%08x mie=%08x mstatus=%08x ticks=%u catchups=%u\n",
                tag,
                (uint32_t) csr_read(mip),
                (uint32_t) csr_read(mie),
                (uint32_t) csr_read(mstatus),
                g_ticks,
                g_catchups);
    enable_interrupts();
}

__attribute__((noreturn, noinline, used)) void main_on_ddr_stack(void)
{
    uint32_t sweeps = 0;
    uint32_t acc = 0x2468ACE0u;

    uart_printf("\n=== tick_torture: CLINT re-arm under DDR thrash ===\n");
    uart_printf("period=%u ticks_target=%u workset=%u KiB\n",
                PERIOD_CYCLES,
                TARGET_TICKS,
                (WORKSET_WORDS * 4u) >> 10);

    set_trap_handler(&tick_irq_entry);
    disable_interrupts();
    enable_timer_interrupt();

    uint64_t first = clint_rdmtime() + PERIOD_CYCLES;
    g_next_lo = (uint32_t) first;
    g_next_hi = (uint32_t) (first >> 32);
    clint_set_timer_cmp(first);
    enable_interrupts();

    while (!g_fail_seen && g_ticks < TARGET_TICKS) {
        acc ^= thrash_sweep(acc ^ sweeps);
        sweeps++;

        /* D2: armed + quiet for WATCHDOG_PERIODS periods = tick death. */
        uint32_t t0;
        uint64_t armed;
        snapshot(&t0, &armed);
        uint64_t now = clint_rdmtime();
        if (now > armed + (uint64_t) WATCHDOG_PERIODS * PERIOD_CYCLES) {
            uint32_t t1 = g_ticks;
            if (t1 == t0) {
                dump_death_state("WATCHDOG");
                record_failure(FAIL_WATCHDOG);
                break;
            }
        }

        /* D3: periodic Linux-like WFI idle phase, bounded. */
        if ((sweeps % WFI_PHASE_EVERY) == 0u) {
            uint32_t before = g_ticks;
            uint64_t deadline = clint_rdmtime() + (uint64_t) WATCHDOG_PERIODS * PERIOD_CYCLES;
            while (g_ticks == before && !g_fail_seen) {
                __asm__ volatile("wfi" ::: "memory");
                if (clint_rdmtime() > deadline) {
                    dump_death_state("WFI_STUCK");
                    record_failure(FAIL_WFI_STUCK);
                    break;
                }
            }
        }
    }

    disable_timer_interrupt();
    disable_interrupts();
    clint_set_timer_cmp(0xFFFFFFFFFFFFFFFFull);

    if (!g_fail_seen && acc != 0x600DBEEFu) { /* acc consumed, never taken */
        uart_printf("ticks=%u sweeps=%u catchups=%u acc=%08x\n", g_ticks, sweeps, g_catchups, acc);
        uart_printf("<<PASS>>\n");
    } else {
        if (g_fail_code == FAIL_READBACK) {
            uart_printf("READBACK: armed=%08x_%08x rb=%08x_%08x mtime=%08x_%08x\n",
                        g_next_hi,
                        g_next_lo,
                        g_rb_hi,
                        g_rb_lo,
                        g_fail_mtime_hi,
                        g_fail_mtime_lo);
        }
        uart_printf("FAIL code=%u ticks=%u sweeps=%u catchups=%u\n",
                    g_fail_code,
                    g_ticks,
                    sweeps,
                    g_catchups);
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
