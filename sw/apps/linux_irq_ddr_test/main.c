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
 * Linux-like timer IRQ test, linked and executed from cached DDR.
 *
 * The no-MMU Linux hardware failure is an illegal-instruction panic with
 * ra == epc == 0x00000cc0 after the first machine timer interrupt from idle.
 * Preserves the relevant ingredients in a smaller loop: DDR code/data/stack,
 * WFI idle, a machine-timer IRQ, a Linux-style naked trap entry that
 * saves/restores GPRs on the current stack, and the csrrw tp,mscratch,tp swap.
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

#define ARRAY_LEN(a) ((int) (sizeof(a) / sizeof((a)[0])))
#define CLINT_MTIMECMP_LO (*(volatile uint32_t *) 0x40014000u)
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *) 0x40014004u)
#define CLINT_MTIME_LO (*(volatile uint32_t *) 0x4001BFF8u)
#define CLINT_MTIME_HI (*(volatile uint32_t *) 0x4001BFFCu)
#define NORMAL_IRQ_COUNT 16u
#define POISON_IRQ_COUNT 16u
#define IRQ_COUNT (NORMAL_IRQ_COUNT + POISON_IRQ_COUNT)
#define FRAME_WORDS 36u
#define DDR_STACK_SIZE 4096u

struct linux_pt_regs {
    unsigned long epc;
    unsigned long ra;
    unsigned long sp;
    unsigned long gp;
    unsigned long tp;
    unsigned long t0;
    unsigned long t1;
    unsigned long t2;
    unsigned long s0;
    unsigned long s1;
    unsigned long a0;
    unsigned long a1;
    unsigned long a2;
    unsigned long a3;
    unsigned long a4;
    unsigned long a5;
    unsigned long a6;
    unsigned long a7;
    unsigned long s2;
    unsigned long s3;
    unsigned long s4;
    unsigned long s5;
    unsigned long s6;
    unsigned long s7;
    unsigned long s8;
    unsigned long s9;
    unsigned long s10;
    unsigned long s11;
    unsigned long t3;
    unsigned long t4;
    unsigned long t5;
    unsigned long t6;
    unsigned long status;
    unsigned long badaddr;
    unsigned long cause;
    unsigned long orig_a0;
};

struct fake_current {
    unsigned long kernel_sp;
    unsigned long user_sp;
    unsigned long marker;
};

volatile unsigned long g_expected_mepc;
volatile unsigned long g_expected_ra;
volatile unsigned long g_expected_sp;
volatile unsigned long g_expected_tp;
volatile struct fake_current g_fake_current = {0u, 0u, 0x5441534Bu};
volatile uint32_t g_ticks;
volatile uint32_t g_fail_code;
volatile uint32_t g_fail_seen;
volatile unsigned long g_last_mepc;
volatile unsigned long g_last_ra;
volatile unsigned long g_last_sp;
volatile unsigned long g_last_tp;
volatile unsigned long g_last_mscratch_in_handler;
volatile uint32_t g_context_checksum;
volatile uint32_t g_context_words[64];
volatile unsigned long g_frame_snapshots[IRQ_COUNT][FRAME_WORDS];

static uint8_t g_ddr_stack[DDR_STACK_SIZE] __attribute__((aligned(16)));

static inline uintptr_t read_tp(void)
{
    uintptr_t value;
    __asm__ volatile("mv %0, tp" : "=r"(value));
    return value;
}

static inline void write_tp(uintptr_t value)
{
    __asm__ volatile("mv tp, %0" : : "r"(value) : "memory");
}

static void record_failure(uint32_t code)
{
    if (!g_fail_seen) {
        g_fail_seen = 1;
        g_fail_code = code;
    }
}

static void fill_context(void)
{
    for (int i = 0; i < ARRAY_LEN(g_context_words); i++) {
        g_context_words[i] = 0x80000000u ^ ((uint32_t) i * 0x10204081u);
    }
    g_context_checksum = 0x13579BDFu;
}

static uint32_t churn_context(uint32_t seed)
{
    uint32_t acc = seed ^ g_context_checksum;

    for (int i = 0; i < ARRAY_LEN(g_context_words); i++) {
        uint32_t value = g_context_words[i];
        acc ^= value + ((uint32_t) i << 16);
        acc = (acc << 5) | (acc >> 27);
        g_context_words[i] = value ^ acc ^ (0x9E3779B9u + (uint32_t) i);
    }

    g_context_checksum = acc;
    return acc;
}

static uint64_t clint_rdmtime(void)
{
    uint32_t hi;
    uint32_t lo;
    uint32_t hi2;

    do {
        hi = CLINT_MTIME_HI;
        lo = CLINT_MTIME_LO;
        hi2 = CLINT_MTIME_HI;
    } while (hi != hi2);

    return ((uint64_t) hi << 32) | lo;
}

static void clint_set_timer_cmp(uint64_t cmp)
{
    CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    CLINT_MTIMECMP_LO = (uint32_t) cmp;
    CLINT_MTIMECMP_HI = (uint32_t) (cmp >> 32);
}

static void clint_ack_timer(void)
{
    CLINT_MTIMECMP_HI = 0xFFFFFFFFu;
    CLINT_MTIMECMP_LO = 0xFFFFFFFFu;
}

__attribute__((noinline, used)) void linux_like_irq_c(struct linux_pt_regs *frame)
{
    uint32_t tick = g_ticks;

    g_last_mepc = frame->epc;
    g_last_ra = frame->ra;
    g_last_sp = frame->sp;
    g_last_tp = frame->tp;
    g_last_mscratch_in_handler = csr_read(mscratch);

    if (tick < IRQ_COUNT) {
        for (uint32_t i = 0; i < FRAME_WORDS; i++) {
            g_frame_snapshots[tick][i] = ((volatile unsigned long *) frame)[i];
        }
    }

    if (frame->cause != (MCAUSE_INTERRUPT_BIT | INT_MTI)) {
        record_failure(1u);
    }
    if (frame->epc != g_expected_mepc) {
        record_failure(2u);
    }
    if (frame->ra != g_expected_ra) {
        record_failure(3u);
    }
    if (frame->ra < 0x80000000u || frame->ra == 0x00000CC0u || frame->ra < 0x00001000u) {
        record_failure(14u);
    }
    if (frame->sp != g_expected_sp) {
        record_failure(4u);
    }
    if (frame->tp != g_expected_tp) {
        record_failure(5u);
    }
    if (g_last_mscratch_in_handler != 0u) {
        record_failure(6u);
    }

    churn_context(frame->epc ^ frame->ra ^ tick);

    clint_ack_timer();
    g_ticks = tick + 1u;
}

__attribute__((naked, aligned(4))) static void linux_like_irq_entry(void)
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
        "call linux_like_irq_c\n" XL " a0, 32*" XB "(sp)\n" XL " a2, 0*" XB "(sp)\n" XSC
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

__attribute__((noinline)) static uint32_t idle_once(uint32_t iter)
{
    uint32_t before = g_ticks;

    write_tp((uintptr_t) &g_fake_current);
    csr_write(mscratch, 0u);
    clint_set_timer_cmp(clint_rdmtime() + 300u + (iter & 31u));
    enable_interrupts();

    __asm__ volatile("mv   t2, ra\n"
                     "mv   t3, sp\n"
                     "mv   t4, tp\n"
                     "la   t0, 1f\n"
                     "la   t1, g_expected_mepc\n"
                     "sw   t0, 0(t1)\n"
                     "la   t1, g_expected_ra\n"
                     "sw   t2, 0(t1)\n"
                     "la   t1, g_expected_sp\n"
                     "sw   t3, 0(t1)\n"
                     "la   t1, g_expected_tp\n"
                     "sw   t4, 0(t1)\n"
                     "wfi\n"
                     "1:\n"
                     :
                     :
                     : "t0", "t1", "t2", "t3", "t4", "memory");

    disable_interrupts();

    if (g_ticks != before + 1u) {
        record_failure(8u);
    }
    if (read_tp() != (uintptr_t) &g_fake_current) {
        record_failure(9u);
    }
    if (csr_read(mscratch) != 0u) {
        record_failure(10u);
    }

    return churn_context(iter ^ g_ticks);
}

__attribute__((noinline)) static uint32_t idle_then_poison_ra_once(uint32_t iter)
{
    uint32_t before = g_ticks;

    write_tp((uintptr_t) &g_fake_current);
    csr_write(mscratch, 0u);
    clint_set_timer_cmp(clint_rdmtime() + 300u + (iter & 31u));
    enable_interrupts();

    __asm__ volatile("mv   t2, ra\n"
                     "mv   t3, sp\n"
                     "mv   t4, tp\n"
                     "la   t0, 1f\n"
                     "la   t1, g_expected_mepc\n"
                     "sw   t0, 0(t1)\n"
                     "la   t1, g_expected_ra\n"
                     "sw   t2, 0(t1)\n"
                     "la   t1, g_expected_sp\n"
                     "sw   t3, 0(t1)\n"
                     "la   t1, g_expected_tp\n"
                     "sw   t4, 0(t1)\n"
                     "wfi\n"
                     "1:\n"
                     "lui  ra, 0x1\n"
                     "addi ra, ra, -832\n"
                     "mv   ra, t2\n"
                     :
                     :
                     : "t0", "t1", "t2", "t3", "t4", "memory");

    disable_interrupts();

    if (g_ticks != before + 1u) {
        record_failure(11u);
    }
    if (read_tp() != (uintptr_t) &g_fake_current) {
        record_failure(12u);
    }
    if (csr_read(mscratch) != 0u) {
        record_failure(13u);
    }

    return churn_context(0xCC0u ^ iter ^ g_ticks);
}

__attribute__((noreturn, noinline, used)) void main_on_ddr_stack(void)
{
    uint32_t aggregate = 0x2468ACE0u;

    uart_printf("\n=== Linux-like DDR timer IRQ test ===\n");
    fill_context();
    g_fake_current.kernel_sp = (uintptr_t) &g_ddr_stack[DDR_STACK_SIZE];
    g_fake_current.user_sp = 0u;
    set_trap_handler(&linux_like_irq_entry);
    disable_interrupts();
    enable_timer_interrupt();

    for (uint32_t i = 0; i < NORMAL_IRQ_COUNT; i++) {
        aggregate ^= idle_once(i);
        if (g_fail_seen) {
            break;
        }
    }
    for (uint32_t i = 0; i < POISON_IRQ_COUNT && !g_fail_seen; i++) {
        aggregate ^= idle_then_poison_ra_once(i);
    }

    disable_timer_interrupt();
    disable_interrupts();
    clint_ack_timer();

    if (!g_fail_seen && g_ticks == IRQ_COUNT && aggregate != 0u) {
        uart_printf("ticks=%u checksum=%08x last_mepc=%08x last_ra=%08x\n",
                    g_ticks,
                    g_context_checksum,
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
                    g_last_mscratch_in_handler);
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
