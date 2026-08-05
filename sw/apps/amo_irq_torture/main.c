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
 * amo_irq_torture -- machine-timer interrupts swept across cached-DDR AMO
 * bursts, counting every atomic side effect.
 *
 * Directed reproducer for the AMO-vs-interrupt-flush race behind the flaky
 * no-MMU Linux boot hang: an interrupt taken while an AMO's memory write is
 * anywhere in [launch, commit] used to orphan the write (the full flush
 * cleared the LQ's AMO_WRITE_ACTIVE state, the cached write completed with
 * no owner, and mepc re-executed the AMO). Each such event applies one
 * architectural amoadd TWICE -- so the final sum of the counter array
 * exceeds the number of architecturally executed increments -- or, when the
 * orphan collides with a later store in the cached-tier adapter, wedges the
 * store queue and hangs the burst (no <<PASS>>, harness timeout).
 *
 * Structure: for each iteration, arm mtimecmp = now + K (K swept over a
 * range so the interrupt lands at every alignment within the burst), then
 * run a burst of amoadd.w +1 across a DDR-resident counter array whose
 * stride and footprint force the AMO's line out of L1 between touches --
 * an L1-miss AMO write maximizes the vulnerable in-flight window. The
 * handler counts ticks and disarms. After the sweep the array sum must
 * equal exactly ITERS * BURST_AMOS.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

/* XLEN split: this entry mirrors the kernel trap frame. At rv64 the frame
 * slots are 8 bytes and every save/restore is full-width (sw/lw would
 * truncate live 64-bit registers of the interrupted context), and the
 * kernel-mirror reservation-clear SC is sc.d. XB is a string macro so gas
 * evaluates the "n*" XB "(sp)" offset arithmetic; rv32 expands to the
 * original instructions unchanged.
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

#define DDR_STACK_SIZE 4096u

/* Counter array: 2048 word-counters spread one per 32-byte line across a
 * 64 KiB footprint... with a 128 KiB L1D that alone would eventually fit,
 * so the burst also streams a 256 KiB eviction array between AMO touches
 * to keep every AMO write an L1 miss (maximal in-flight window). */
#define COUNTERS 2048u
#define COUNTER_STRIDE_WORDS 8u   /* one counter per 32 B line */
#define EVICT_WORDS (64u * 1024u) /* 256 KiB */
#define EVICT_TOUCH_STRIDE 8u

/* Iteration count: overridable for simulation, where wall-clock per cycle
 * is ~5 orders of magnitude slower (EXTRA_CFLAGS=-DAMO_TORTURE_ITERS=...).
 * Simulation also wants SIM_TIMER_SPEEDUP=1 so the K sweep below lands the
 * interrupt inside the burst rather than firing instantly. */
#ifndef AMO_TORTURE_ITERS
#define AMO_TORTURE_ITERS 24000u
#endif
#define ITERS ((uint32_t) AMO_TORTURE_ITERS)
#define BURST_AMOS 64u
/* Interrupt-arm offset sweep: covers the whole burst duration at fine and
 * coarse alignments (cycles, since mtime ticks at core clock on hardware). */
#define K_MIN 64u
#define K_SPAN 8192u
#define K_STEP 37u /* co-prime-ish with burst structure for dense coverage */

volatile uint32_t g_ticks;
volatile uint32_t g_spurious;

static uint32_t g_counters[COUNTERS * COUNTER_STRIDE_WORDS] __attribute__((aligned(32)));
static uint32_t g_evict[EVICT_WORDS] __attribute__((aligned(32)));
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

/* Linux timer-clint.c write order: hi=-1, lo, hi. */
static void clint_set_timer_cmp(uint64_t cmp)
{
    CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    CLINT_MTIMECMP_LO = (uint32_t) cmp;
    CLINT_MTIMECMP_HI = (uint32_t) (cmp >> 32);
}

__attribute__((noinline, used)) void amo_irq_c(frame_word_t *frame)
{
    frame_word_t cause = frame[34];

    if (cause == (MCAUSE_INTERRUPT_BIT | INT_MTI)) {
        g_ticks = g_ticks + 1u;
        clint_set_timer_cmp(0xFFFFFFFFFFFFFFFFull); /* disarm until next iter */
    } else {
        g_spurious = g_spurious + 1u;
    }
}

__attribute__((naked, aligned(4))) static void amo_irq_entry(void)
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
        "call amo_irq_c\n" XL " a0, 32*" XB "(sp)\n" XL " a2, 0*" XB "(sp)\n" XSC " x0, a2, 0(sp)\n"
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

static inline void amo_add1(volatile uint32_t *addr)
{
    uint32_t old;
    __asm__ volatile("amoadd.w %0, %2, (%1)" : "=r"(old) : "r"(addr), "r"(1u) : "memory");
    (void) old;
}

__attribute__((noreturn, noinline, used)) void main_on_ddr_stack(void)
{
    uart_printf("\n=== amo_irq_torture: IRQ swept across cached AMO bursts ===\n");
    uart_printf("iters=%u burst=%u counters=%u k=[%u..%u/%u]\n",
                ITERS,
                BURST_AMOS,
                COUNTERS,
                K_MIN,
                K_MIN + K_SPAN,
                K_STEP);

    for (uint32_t i = 0; i < COUNTERS * COUNTER_STRIDE_WORDS; i++) {
        g_counters[i] = 0u;
    }

    set_trap_handler(&amo_irq_entry);
    disable_interrupts();
    enable_timer_interrupt();
    clint_set_timer_cmp(0xFFFFFFFFFFFFFFFFull);
    enable_interrupts();

    uint32_t k = K_MIN;
    uint32_t counter_idx = 0;
    uint32_t evict_idx = 0;

    for (uint32_t iter = 0; iter < ITERS; iter++) {
        /* Arm the interrupt to land somewhere inside this burst. */
        clint_set_timer_cmp(clint_rdmtime() + k);
        k += K_STEP;
        if (k > K_MIN + K_SPAN) {
            k = K_MIN;
        }

        for (uint32_t b = 0; b < BURST_AMOS; b++) {
            amo_add1(&g_counters[counter_idx * COUNTER_STRIDE_WORDS]);
            counter_idx = (counter_idx + 1u) % COUNTERS;
            /* Stream a couple of lines through L1 so the next AMO's line is
             * evicted -> its write misses -> widest in-flight window. */
            g_evict[evict_idx] ^= iter + b;
            g_evict[evict_idx + EVICT_TOUCH_STRIDE] ^= iter ^ b;
            evict_idx = (evict_idx + 2u * EVICT_TOUCH_STRIDE) % EVICT_WORDS;
        }

        if ((iter & 0x0FFFu) == 0u) {
            uart_printf("iter=%u ticks=%u\n", iter, g_ticks);
        }
    }

    disable_timer_interrupt();
    disable_interrupts();
    clint_set_timer_cmp(0xFFFFFFFFFFFFFFFFull);

    uint64_t sum = 0;
    for (uint32_t c = 0; c < COUNTERS; c++) {
        sum += g_counters[c * COUNTER_STRIDE_WORDS];
    }
    uint64_t expected = (uint64_t) ITERS * BURST_AMOS;

    uart_printf("sum=%08x%08x expected=%08x%08x ticks=%u spurious=%u\n",
                (uint32_t) (sum >> 32),
                (uint32_t) sum,
                (uint32_t) (expected >> 32),
                (uint32_t) expected,
                g_ticks,
                g_spurious);

    if (sum == expected && g_spurious == 0u && g_ticks > 0u) {
        uart_printf("<<PASS>>\n");
    } else {
        if (sum > expected) {
            uart_printf("DOUBLE-APPLIED AMOs: +%u atomic(s) applied twice "
                        "(interrupt orphaned an in-flight AMO write)\n",
                        (uint32_t) (sum - expected));
        } else if (sum < expected) {
            uart_printf("LOST AMOs: -%u atomic update(s) missing\n", (uint32_t) (expected - sum));
        }
        if (g_ticks == 0u) {
            uart_printf("NO TICKS: timer interrupt never delivered\n");
        }
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
