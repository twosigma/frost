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
 * Directed repro for the Linux timer-IRQ failure where _find_next_zero_bit()
 * returned through ra == 0x00000cc0 after an IRQ.  The test poisons the exact
 * future callee save slot with 0xcc0, enters a callee whose prologue matches:
 *
 *     addi sp, sp, -16
 *     sw   s0, 8(sp)
 *     sw   ra, 12(sp)
 *     addi s0, sp, 16
 *
 * It takes a Linux-like machine timer IRQ while the callee is active, then
 * checks the later load from 12(sp) before using it as a return address.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

/* XLEN split: the Linux-mirror trap frame and the stack-slot callee both
 * hold XLEN-wide registers. The callee keeps its 16-byte frame at both
 * widths, packed the way the kernel packs it (ra in the top slot): ra at
 * 16-XB, s0 at 16-2*XB, so the handler-side slot address is sp+16-XB.
 * XB is a string so gas evaluates the offset arithmetic; rv32 expands to
 * the original instructions unchanged.
 */
#if __riscv_xlen == 64
#define XS "sd  "
#define XL "ld  "
#define XSC "sc.d"
#define XB "8"
#else
#define XS "sw  "
#define XL "lw  "
#define XSC "sc.w"
#define XB "4"
#endif
/* C-side view of the callee's saved-ra slot offset. */
#define RA_SLOT_OFF (16u - (unsigned) sizeof(unsigned long))

#define CLINT_MTIMECMP_LO (*(volatile uint32_t *) 0x40014000u)
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *) 0x40014004u)
#define CLINT_MTIME_LO (*(volatile uint32_t *) 0x4001BFF8u)
#define CLINT_MTIME_HI (*(volatile uint32_t *) 0x4001BFFCu)
#define DDR_STACK_SIZE 4096u
#define NONINTRUSIVE_ITERATIONS 24u
#define INTRUSIVE_ITERATIONS 8u
#define TOTAL_ITERATIONS (NONINTRUSIVE_ITERATIONS + INTRUSIVE_ITERATIONS)
#define POISON_RA 0x00000CC0u

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

volatile struct fake_current g_fake_current = {0u, 0u, 0x5354414Bu};
volatile uint32_t g_ticks;
volatile uint32_t g_target_tick;
volatile uint32_t g_current_iter;
volatile uint32_t g_read_slot_in_handler;

volatile uint32_t g_fail_seen;
volatile uint32_t g_fail_code;
volatile unsigned long g_bad_cause;
volatile unsigned long g_bad_epc;
volatile unsigned long g_bad_ra;

volatile unsigned long g_expected_slot_addr;
volatile unsigned long g_expected_saved_ra;
volatile unsigned long g_poison_readback;
volatile unsigned long g_callee_sp;
volatile unsigned long g_callee_ra_saved;
volatile unsigned long g_slot_during_irq;
volatile unsigned long g_slot_before_return;

volatile uint32_t g_irq_in_callee;
volatile unsigned long g_last_mepc;
volatile unsigned long g_last_ra;
volatile unsigned long g_last_sp;
volatile unsigned long g_last_tp;
volatile unsigned long g_last_mscratch_in_handler;
volatile unsigned long g_last_slot_addr;

static uint8_t g_ddr_stack[DDR_STACK_SIZE] __attribute__((aligned(16)));

__attribute__((naked, aligned(4), noinline, used)) void irq_stack_slot_callee(void);
__attribute__((naked, aligned(4), noinline, used)) uint32_t run_stack_slot_call_window(void);
__attribute__((noreturn, noinline, used)) void stack_slot_bad_return(unsigned long observed);
__attribute__((noreturn, noinline, used)) void stack_slot_timeout(uint32_t code);

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

static void record_failure(uint32_t code)
{
    if (!g_fail_seen) {
        g_fail_seen = 1u;
        g_fail_code = code;
        g_bad_cause = csr_read(mcause);
        g_bad_epc = csr_read(mepc);
        g_bad_ra = g_last_ra;
    }
}

__attribute__((noreturn, noinline)) static void finish_fail(const char *tag)
{
    disable_timer_interrupt();
    disable_external_interrupt();
    disable_interrupts();
    clint_ack_timer();

    uart_printf("FAIL %s code=%u iter=%u ticks=%u target=%u cause=%08x\n",
                tag,
                g_fail_code,
                g_current_iter,
                g_ticks,
                g_target_tick,
                g_bad_cause);
    uart_printf("pc epc=%08x ra=%08x sp=%08x tp=%08x mscratch=%08x\n",
                g_last_mepc,
                g_last_ra,
                g_last_sp,
                g_last_tp,
                g_last_mscratch_in_handler);
    uart_printf("slot addr=%08x irq_addr=%08x poison=%08x irq_slot=%08x before_ret=%08x\n",
                g_expected_slot_addr,
                g_last_slot_addr,
                g_poison_readback,
                g_slot_during_irq,
                g_slot_before_return);
    uart_printf("expected_ra=%08x callee_ra=%08x callee_sp=%08x bad_epc=%08x bad_ra=%08x\n",
                g_expected_saved_ra,
                g_callee_ra_saved,
                g_callee_sp,
                g_bad_epc,
                g_bad_ra);
    uart_printf("<<FAIL>>\n");

    for (;;) {
    }
}

__attribute__((noreturn, noinline, used)) void stack_slot_bad_return(unsigned long observed)
{
    g_slot_before_return = observed;
    record_failure(30u);
    finish_fail("bad_return_slot");
}

__attribute__((noreturn, noinline, used)) void stack_slot_timeout(uint32_t code)
{
    record_failure(code);
    finish_fail("callee_timeout");
}

__attribute__((noinline, used)) void linux_like_irq_c(struct linux_pt_regs *frame)
{
    uint32_t tick = g_ticks;

    g_last_mepc = frame->epc;
    g_last_ra = frame->ra;
    g_last_sp = frame->sp;
    g_last_tp = frame->tp;
    g_last_mscratch_in_handler = csr_read(mscratch);

    uint32_t cause_code = frame->cause & ~MCAUSE_INTERRUPT_BIT;
    if ((frame->cause & MCAUSE_INTERRUPT_BIT) == 0u ||
        (cause_code != INT_MTI && cause_code != INT_MEI)) {
        g_bad_epc = frame->epc;
        g_bad_ra = frame->ra;
        record_failure(1u);
        finish_fail("unexpected_trap");
    }

    if (g_callee_sp != 0u && frame->sp == g_callee_sp) {
        g_irq_in_callee = 1u;
        g_last_slot_addr = frame->sp + RA_SLOT_OFF;
        if (g_read_slot_in_handler) {
            g_slot_during_irq = *(volatile unsigned long *) (frame->sp + RA_SLOT_OFF);
        }
    } else {
        record_failure(2u);
    }

    if (frame->ra < 0x80000000u || frame->ra == POISON_RA) {
        record_failure(3u);
    }
    if (frame->tp != (uintptr_t) &g_fake_current) {
        record_failure(4u);
    }
    if (g_last_mscratch_in_handler != 0u) {
        record_failure(5u);
    }

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

__attribute__((naked, aligned(4), noinline, used)) void irq_stack_slot_callee(void)
{
    __asm__ volatile(".option push\n"
                     ".option rvc\n"
                     "addi sp, sp, -16\n" XS " s0, 16-2*" XB "(sp)\n" XS " ra, 16-1*" XB "(sp)\n"
                     "addi s0, sp, 16\n"
                     "la   t0, g_callee_sp\n" XS " sp, 0(t0)\n"
                     "la   t0, g_callee_ra_saved\n" XS " ra, 0(t0)\n"
                     "li   t4, 200000\n"
                     "1:\n"
                     "la   t0, g_ticks\n"
                     "lw   t1, 0(t0)\n"
                     "la   t0, g_target_tick\n"
                     "lw   t2, 0(t0)\n"
                     "beq  t1, t2, 3f\n"
                     "la   t0, g_fail_seen\n"
                     "lw   t1, 0(t0)\n"
                     "bnez t1, 3f\n"
                     "addi t4, t4, -1\n"
                     "bnez t4, 1b\n"
                     "li   a0, 31\n" XL " s0, 16-2*" XB "(sp)\n"
                     "addi sp, sp, 16\n"
                     "j    stack_slot_timeout\n"
                     "3:\n" XL " ra, 16-1*" XB "(sp)\n"
                     "la   t0, g_slot_before_return\n" XS " ra, 0(t0)\n"
                     "li   t2, 0x80000000\n"
                     "bltu ra, t2, 2f\n" XL " s0, 16-2*" XB "(sp)\n"
                     "addi sp, sp, 16\n"
                     "ret\n"
                     "2:\n"
                     "mv   a0, ra\n" XL " s0, 16-2*" XB "(sp)\n"
                     "addi sp, sp, 16\n"
                     "j    stack_slot_bad_return\n"
                     ".option pop\n");
}

__attribute__((naked, aligned(4), noinline, used)) uint32_t run_stack_slot_call_window(void)
{
    __asm__ volatile(".option push\n"
                     ".option rvc\n"
                     "addi sp, sp, -16\n" XS " ra, 0(sp)\n"
                     "addi t0, sp, -1*" XB "\n"
                     "la   t1, g_expected_slot_addr\n" XS " t0, 0(t1)\n"
                     "li   t2, 0x00000cc0\n" XS " t2, 0(t0)\n" XL " t3, 0(t0)\n"
                     "la   t1, g_poison_readback\n" XS " t3, 0(t1)\n"
                     "la   t1, 1f\n"
                     "la   t0, g_expected_saved_ra\n" XS " t1, 0(t0)\n"
                     "call irq_stack_slot_callee\n"
                     "1:\n"
                     "li   a0, 1\n" XL " ra, 0(sp)\n"
                     "addi sp, sp, 16\n"
                     "ret\n"
                     ".option pop\n");
}

static void prepare_window(uint32_t iter, uint32_t read_slot_in_handler)
{
    disable_interrupts();
    clint_ack_timer();

    g_current_iter = iter;
    g_target_tick = g_ticks + 1u;
    g_read_slot_in_handler = read_slot_in_handler;
    g_expected_slot_addr = 0u;
    g_expected_saved_ra = 0u;
    g_poison_readback = 0u;
    g_callee_sp = 0u;
    g_callee_ra_saved = 0u;
    g_slot_during_irq = 0xFFFFFFFFu;
    g_slot_before_return = 0u;
    g_irq_in_callee = 0u;
    g_last_slot_addr = 0u;

    write_tp((uintptr_t) &g_fake_current);
    csr_write(mscratch, 0u);
    clint_set_timer_cmp(clint_rdmtime() + 3000u + ((iter * 211u) & 1023u));
    enable_interrupts();
}

static uint32_t run_one_window(uint32_t iter, uint32_t read_slot_in_handler)
{
    uint32_t returned;
    uint32_t checksum;

    prepare_window(iter, read_slot_in_handler);
    returned = run_stack_slot_call_window();
    disable_interrupts();
    clint_ack_timer();

    if (returned != 1u) {
        record_failure(40u);
    }
    if (g_ticks != g_target_tick) {
        record_failure(41u);
    }
    if (!g_irq_in_callee) {
        record_failure(42u);
    }
    if (g_callee_sp == 0u || g_expected_slot_addr != g_callee_sp + RA_SLOT_OFF) {
        record_failure(43u);
    }
    if (g_poison_readback != POISON_RA) {
        record_failure(44u);
    }
    if (g_expected_saved_ra < 0x80000000u || g_expected_saved_ra == POISON_RA) {
        record_failure(45u);
    }
    if (g_callee_ra_saved != g_expected_saved_ra) {
        record_failure(46u);
    }
    if (g_slot_before_return != g_expected_saved_ra) {
        record_failure(47u);
    }
    if (read_slot_in_handler && g_slot_during_irq != g_expected_saved_ra) {
        record_failure(48u);
    }
    if (read_tp() != (uintptr_t) &g_fake_current) {
        record_failure(49u);
    }
    if (csr_read(mscratch) != 0u) {
        record_failure(50u);
    }

    checksum = g_slot_before_return ^ g_expected_slot_addr ^ g_last_mepc;
    checksum ^= (g_current_iter << 16) ^ g_ticks ^ (read_slot_in_handler << 31);
    return checksum;
}

__attribute__((noreturn, noinline, used)) void main_on_ddr_stack(void)
{
    uint32_t checksum = 0xA51C05E0u;

    uart_printf("\n=== Linux IRQ stack-slot DDR test ===\n");

    g_fake_current.kernel_sp = (uintptr_t) &g_ddr_stack[DDR_STACK_SIZE];
    g_fake_current.user_sp = 0u;
    set_trap_handler(&linux_like_irq_entry);
    disable_interrupts();
    clint_ack_timer();
    enable_timer_interrupt();
    enable_external_interrupt();

    for (uint32_t i = 0; i < NONINTRUSIVE_ITERATIONS && !g_fail_seen; i++) {
        checksum ^= run_one_window(i, 0u);
    }
    for (uint32_t i = 0; i < INTRUSIVE_ITERATIONS && !g_fail_seen; i++) {
        checksum ^= run_one_window(NONINTRUSIVE_ITERATIONS + i, 1u);
    }

    disable_timer_interrupt();
    disable_external_interrupt();
    disable_interrupts();
    clint_ack_timer();

    if (g_fail_seen) {
        finish_fail("post_check");
    }

    if (g_ticks == TOTAL_ITERATIONS && checksum != 0u) {
        uart_printf("ticks=%u checksum=%08x last_mepc=%08x last_ra=%08x slot=%08x\n",
                    g_ticks,
                    checksum,
                    g_last_mepc,
                    g_last_ra,
                    g_slot_before_return);
        uart_printf("<<PASS>>\n");
    } else {
        record_failure(60u);
        finish_fail("final_count");
    }

    for (;;) {
    }
}

int main(void)
{
    uintptr_t stack_top = ((uintptr_t) &g_ddr_stack[DDR_STACK_SIZE]) & ~0xFu;

    __asm__ volatile("mv sp, %0\n"
                     "j  main_on_ddr_stack\n"
                     :
                     : "r"(stack_top)
                     : "memory");
    __builtin_unreachable();
}
