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

__attribute__((noinline, used)) void amo_irq_c(uint32_t *frame)
{
    uint32_t cause = frame[34];

    if (cause == (MCAUSE_INTERRUPT_BIT | INT_MTI)) {
        g_ticks = g_ticks + 1u;
        clint_set_timer_cmp(0xFFFFFFFFFFFFFFFFull); /* disarm until next iter */
    } else {
        g_spurious = g_spurious + 1u;
    }
}

__attribute__((naked, aligned(4))) static void amo_irq_entry(void)
{
    __asm__ volatile("csrrw tp, mscratch, tp\n"
                     "bnez tp, 1f\n"
                     "csrr tp, mscratch\n"
                     "1:\n"
                     "addi sp, sp, -144\n"
                     "sw   ra, 4(sp)\n"
                     "sw   gp, 12(sp)\n"
                     "sw   t0, 20(sp)\n"
                     "sw   t1, 24(sp)\n"
                     "sw   t2, 28(sp)\n"
                     "sw   s0, 32(sp)\n"
                     "sw   s1, 36(sp)\n"
                     "sw   a0, 40(sp)\n"
                     "sw   a1, 44(sp)\n"
                     "sw   a2, 48(sp)\n"
                     "sw   a3, 52(sp)\n"
                     "sw   a4, 56(sp)\n"
                     "sw   a5, 60(sp)\n"
                     "sw   a6, 64(sp)\n"
                     "sw   a7, 68(sp)\n"
                     "sw   s2, 72(sp)\n"
                     "sw   s3, 76(sp)\n"
                     "sw   s4, 80(sp)\n"
                     "sw   s5, 84(sp)\n"
                     "sw   s6, 88(sp)\n"
                     "sw   s7, 92(sp)\n"
                     "sw   s8, 96(sp)\n"
                     "sw   s9, 100(sp)\n"
                     "sw   s10, 104(sp)\n"
                     "sw   s11, 108(sp)\n"
                     "sw   t3, 112(sp)\n"
                     "sw   t4, 116(sp)\n"
                     "sw   t5, 120(sp)\n"
                     "sw   t6, 124(sp)\n"
                     "addi t0, sp, 144\n"
                     "sw   t0, 8(sp)\n"
                     "csrr t0, mepc\n"
                     "sw   t0, 0(sp)\n"
                     "csrr t0, mstatus\n"
                     "sw   t0, 128(sp)\n"
                     "csrr t0, mtval\n"
                     "sw   t0, 132(sp)\n"
                     "csrr t0, mcause\n"
                     "sw   t0, 136(sp)\n"
                     "csrr t0, mscratch\n"
                     "sw   t0, 16(sp)\n"
                     "csrw mscratch, x0\n"
                     "mv   a0, sp\n"
                     "call amo_irq_c\n"
                     "lw   a0, 128(sp)\n"
                     "lw   a2, 0(sp)\n"
                     "sc.w x0, a2, 0(sp)\n"
                     "csrw mstatus, a0\n"
                     "csrw mepc, a2\n"
                     "lw   ra, 4(sp)\n"
                     "lw   gp, 12(sp)\n"
                     "lw   tp, 16(sp)\n"
                     "lw   t0, 20(sp)\n"
                     "lw   t1, 24(sp)\n"
                     "lw   t2, 28(sp)\n"
                     "lw   s0, 32(sp)\n"
                     "lw   s1, 36(sp)\n"
                     "lw   a0, 40(sp)\n"
                     "lw   a1, 44(sp)\n"
                     "lw   a2, 48(sp)\n"
                     "lw   a3, 52(sp)\n"
                     "lw   a4, 56(sp)\n"
                     "lw   a5, 60(sp)\n"
                     "lw   a6, 64(sp)\n"
                     "lw   a7, 68(sp)\n"
                     "lw   s2, 72(sp)\n"
                     "lw   s3, 76(sp)\n"
                     "lw   s4, 80(sp)\n"
                     "lw   s5, 84(sp)\n"
                     "lw   s6, 88(sp)\n"
                     "lw   s7, 92(sp)\n"
                     "lw   s8, 96(sp)\n"
                     "lw   s9, 100(sp)\n"
                     "lw   s10, 104(sp)\n"
                     "lw   s11, 108(sp)\n"
                     "lw   t3, 112(sp)\n"
                     "lw   t4, 116(sp)\n"
                     "lw   t5, 120(sp)\n"
                     "lw   t6, 124(sp)\n"
                     "lw   sp, 8(sp)\n"
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
    uint32_t stack_top = ((uint32_t) &g_ddr_stack[DDR_STACK_SIZE]) & ~0xFu;

    __asm__ volatile("mv sp, %0\n"
                     "j  main_on_ddr_stack\n"
                     :
                     : "r"(stack_top)
                     : "memory");
    __builtin_unreachable();
}
