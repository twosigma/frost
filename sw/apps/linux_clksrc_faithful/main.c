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
 * Faithful Linux clocksource-switch timer stressor (M-mode, DDR-resident).
 *
 * Mirrors what no-MMU Linux actually does at/after "Switched to clocksource
 * clint_clocksource", which the existing linux_irq_*_ddr tests do NOT:
 *
 *   - clint_clock_next_event() ORDER: csr_set(MTIE) is done FIRST, THEN
 *     mtimecmp is armed with a non-disabling 2-write lo-then-hi writeq
 *     (io-64-nonatomic-lo-hi). So MTIE is enabled while the OLD (just-fired)
 *     mtimecmp is still <= mtime, and the new deadline is written through a
 *     torn {old_hi,new_lo} transient.
 *   - clint_timer_interrupt() RE-ARMS: it acks with csr_clear(MTIE), then the
 *     event_handler re-arms via clint_clock_next_event(). It never leaves the
 *     timer disabled, so a tick taken "early" cannot strand a later wfi (the
 *     failure mode of the other tests, which is a test artifact, not Linux).
 *   - arch_cpu_idle() is a BARE wfi with mstatus.MIE left enabled throughout;
 *     MTIE is what gets toggled, by the handler.
 *   - concurrent cached-DDR churn so a machine-timer IRQ frequently lands while
 *     cached (long-latency) loads/stores are still outstanding.
 *
 * Run at hardware-realistic DDR latency (DDR_MODEL_LATENCY>=70, CACHED_HAS_L2=0).
 * PASS prints <<PASS>>; a frame-integrity violation prints <<FAIL>> with a code;
 * a true deadlock is caught by the RTL no-retire watchdog.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

#define CLINT_MTIMECMP_LO (*(volatile uint32_t *) 0x40014000u)
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *) 0x40014004u)
#define CLINT_MTIME_LO (*(volatile uint32_t *) 0x4001BFF8u)
#define CLINT_MTIME_HI (*(volatile uint32_t *) 0x4001BFFCu)

#define TARGET_TICKS 64u
#define DDR_STACK_SIZE 4096u
#define CHURN_WORDS 4096 /* 16 KiB > L1: each idle sweep sustains DDR misses */

struct linux_pt_regs {
    uint32_t epc, ra, sp, gp, tp;
    uint32_t t0, t1, t2, s0, s1;
    uint32_t a0, a1, a2, a3, a4, a5, a6, a7;
    uint32_t s2, s3, s4, s5, s6, s7, s8, s9, s10, s11;
    uint32_t t3, t4, t5, t6;
    uint32_t status, badaddr, cause, orig_a0;
};

struct fake_current {
    uint32_t kernel_sp;
    uint32_t user_sp;
    uint32_t marker;
};

volatile struct fake_current g_fake_current = {0u, 0u, 0x5441534Bu};
volatile uint32_t g_ticks;
volatile uint32_t g_fail_code;
volatile uint32_t g_fail_seen;
volatile uint32_t g_last_mepc;
volatile uint32_t g_last_ra;
volatile uint32_t g_last_sp;
volatile uint32_t g_last_tp;
volatile uint32_t g_last_mscratch;
volatile uint32_t g_churn[CHURN_WORDS];

static uint8_t g_ddr_stack[DDR_STACK_SIZE] __attribute__((aligned(16)));

static inline uint32_t read_tp(void)
{
    uint32_t v;
    __asm__ volatile("mv %0, tp" : "=r"(v));
    return v;
}

static inline void write_tp(uint32_t v)
{
    __asm__ volatile("mv tp, %0" : : "r"(v) : "memory");
}

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

/* Linux clint_clock_next_event(): enable MTIE FIRST, then non-disabling
 * lo-then-hi writeq of the new deadline (io-64-nonatomic-lo-hi). */
static void clint_clock_next_event(uint64_t cmp)
{
    csr_set(mie, MIE_MTIE);
    CLINT_MTIMECMP_LO = (uint32_t) cmp;
    CLINT_MTIMECMP_HI = (uint32_t) (cmp >> 32);
}

static uint32_t churn_ddr(uint32_t seed)
{
    uint32_t acc = seed;
    for (int i = 0; i < CHURN_WORDS; i++) {
        uint32_t v = g_churn[i];
        acc ^= v + ((uint32_t) i << 3);
        acc = (acc << 5) | (acc >> 27);
        g_churn[i] = v ^ acc ^ (0x9E3779B9u + (uint32_t) i);
    }
    return acc;
}

/* Linux clint_timer_interrupt(): ack by clearing MTIE, then RE-ARM via the
 * event_handler -> clint_clock_next_event() path. */
__attribute__((noinline, used)) void faithful_irq_c(struct linux_pt_regs *frame)
{
    csr_clear(mie, MIE_MTIE);

    g_last_mepc = frame->epc;
    g_last_ra = frame->ra;
    g_last_sp = frame->sp;
    g_last_tp = frame->tp;
    g_last_mscratch = csr_read(mscratch);

    if (frame->cause != (MCAUSE_INTERRUPT_BIT | INT_MTI)) {
        record_failure(1u);
    }
    /* Corrupted/garbage return PC is the hardware symptom (ra==epc==0xCC0). */
    if (frame->epc < 0x80000000u || frame->epc == 0x00000CC0u) {
        record_failure(2u);
    }
    if (frame->ra < 0x80000000u || frame->ra == 0x00000CC0u) {
        record_failure(3u);
    }
    if (frame->sp < (uint32_t) &g_ddr_stack[0] ||
        frame->sp > (uint32_t) &g_ddr_stack[DDR_STACK_SIZE]) {
        record_failure(4u);
    }
    if (frame->tp != (uint32_t) &g_fake_current) {
        record_failure(5u);
    }
    if (g_last_mscratch != 0u) {
        record_failure(6u);
    }

    /* Light handler-side cached touch (rotating window) so the handler stays
     * short; the sustained DDR traffic comes from the idle-loop sweep. */
    {
        uint32_t base = (g_ticks << 4) & (CHURN_WORDS - 1u);
        uint32_t acc = frame->epc ^ frame->ra ^ g_ticks;
        for (int i = 0; i < 8; i++) {
            uint32_t idx = (base + (uint32_t) i) & (CHURN_WORDS - 1u);
            acc ^= g_churn[idx];
            g_churn[idx] = acc + (uint32_t) i;
        }
    }
    g_ticks = g_ticks + 1u;

    /* event_handler -> clint_clock_next_event(now + delta). Vary the delta so
     * the IRQ phase relative to the idle churn/wfi sweeps across alignments. */
    clint_clock_next_event(clint_rdmtime() + 256u + ((uint64_t) (g_ticks & 63u) << 3));
}

/* Linux-style naked trap entry: save/restore the GPR frame on the current
 * (DDR) stack, csrrw tp,mscratch,tp swap idiom, sc.w in the return path. */
__attribute__((naked, aligned(4))) static void faithful_irq_entry(void)
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
                     "sw   a0, 140(sp)\n"
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
                     "call faithful_irq_c\n"
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

__attribute__((noreturn, noinline, used)) void main_on_ddr_stack(void)
{
    uart_printf("\n=== Linux faithful clocksource-switch timer test ===\n");

    for (int i = 0; i < CHURN_WORDS; i++) {
        g_churn[i] = 0x80000000u ^ ((uint32_t) i * 0x10204081u);
    }
    g_fake_current.kernel_sp = (uint32_t) &g_ddr_stack[DDR_STACK_SIZE];
    g_fake_current.user_sp = 0u;

    write_tp((uint32_t) &g_fake_current);
    csr_write(mscratch, 0u);
    set_trap_handler(&faithful_irq_entry);

    /* Start the clockevent (clint_timer_starting_cpu -> first next_event), then
     * enable MIE once and leave it on, exactly like the kernel after boot. */
    clint_clock_next_event(clint_rdmtime() + 384u);
    enable_interrupts();

    /* arch_cpu_idle(): bare wfi with MIE on, interleaved with concurrent
     * cached-DDR work so IRQs land while cached ops are outstanding. */
    uint32_t spin = 0x2468ACE0u;
    while (g_ticks < TARGET_TICKS && !g_fail_seen) {
        spin = churn_ddr(spin ^ g_ticks);
        __asm__ volatile("wfi" ::: "memory");
    }

    disable_timer_interrupt();
    disable_interrupts();

    if (!g_fail_seen && g_ticks >= TARGET_TICKS && spin != 0u) {
        uart_printf("ticks=%u spin=%08x last_mepc=%08x last_ra=%08x\n",
                    g_ticks,
                    spin,
                    g_last_mepc,
                    g_last_ra);
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("FAIL code=%u ticks=%u mepc=%08x ra=%08x sp=%08x tp=%08x mscratch=%08x\n",
                    g_fail_code,
                    g_ticks,
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
    uint32_t stack_top = ((uint32_t) &g_ddr_stack[DDR_STACK_SIZE]) & ~0xFu;
    __asm__ volatile("mv sp, %0\n"
                     "j  main_on_ddr_stack\n"
                     :
                     : "r"(stack_top)
                     : "memory");
    __builtin_unreachable();
}
