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
 * Linux-like active-code timer IRQ test, linked and executed from cached DDR.
 *
 * The no-MMU Linux hardware failure was an illegal-instruction panic with
 * ra == epc == 0x00000cc0 after the first machine timer interrupt from idle.
 * This test keeps the ingredients of that scene: DDR code, data and stack,
 * wfi idle, timer IRQs landing in active code, a Linux-style trap frame on
 * the current stack, and the csrrw tp,mscratch,tp swap.
 *
 * Four phases run in order: wfi idle with exact epc/ra/sp/tp frame checks,
 * wfi idle followed by a transient ra poison of 0xcc0, nested active calls
 * that keep loading 0xcc0 into t5 until the IRQ lands, and a sentinel window
 * with the s-registers pinned to known values so their frame slots can be
 * checked. ra must remain a DDR address at every interrupt boundary.
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
#define ACTIVE_IRQ_COUNT 8u
#define SENTINEL_IRQ_COUNT 32u
#define IRQ_COUNT (NORMAL_IRQ_COUNT + POISON_IRQ_COUNT + ACTIVE_IRQ_COUNT + SENTINEL_IRQ_COUNT)
#define FRAME_WORDS 36u
#define DDR_STACK_SIZE 4096u

#define FRAME_EPC 0u
#define FRAME_RA 1u
#define FRAME_SP 2u
#define FRAME_GP 3u
#define FRAME_TP 4u
#define FRAME_T0 5u
#define FRAME_T1 6u
#define FRAME_T2 7u
#define FRAME_S0 8u
#define FRAME_S1 9u
#define FRAME_A0 10u
#define FRAME_A1 11u
#define FRAME_A2 12u
#define FRAME_A3 13u
#define FRAME_A4 14u
#define FRAME_A5 15u
#define FRAME_A6 16u
#define FRAME_A7 17u
#define FRAME_S2 18u
#define FRAME_S3 19u
#define FRAME_S4 20u
#define FRAME_S5 21u
#define FRAME_S6 22u
#define FRAME_S7 23u
#define FRAME_S8 24u
#define FRAME_S9 25u
#define FRAME_S10 26u
#define FRAME_S11 27u

#define SENTINEL_S0 0x51000000u
#define SENTINEL_S1 0x51000001u
#define SENTINEL_S3 0x51000003u
#define SENTINEL_S4 0x51000004u
#define SENTINEL_S5 0x51000005u
#define SENTINEL_S6 0x51000006u
#define SENTINEL_S7 0x51000007u
#define SENTINEL_S8 0x51000008u
#define SENTINEL_S9 0x51000009u
#define SENTINEL_S10 0x5100000Au
#define SENTINEL_S11 0x5100000Bu

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
volatile uint32_t g_exact_frame_check;
volatile struct fake_current g_fake_current = {0u, 0u, 0x5441534Bu};
volatile uint32_t g_ticks;
volatile uint32_t g_fail_code;
volatile uint32_t g_fail_seen;
volatile unsigned long g_bad_cause;
volatile unsigned long g_bad_epc;
volatile unsigned long g_bad_ra;
volatile unsigned long g_last_mepc;
volatile unsigned long g_last_ra;
volatile unsigned long g_last_sp;
volatile unsigned long g_last_tp;
volatile unsigned long g_last_mscratch_in_handler;
volatile uint32_t g_context_checksum;
volatile uint32_t g_context_words[64];
volatile unsigned long g_frame_snapshots[IRQ_COUNT][FRAME_WORDS];
volatile unsigned long g_frame_check_mask[FRAME_WORDS];
volatile unsigned long g_expected_frame[FRAME_WORDS];
volatile uint32_t g_bad_frame_index;
volatile unsigned long g_bad_expected;
volatile unsigned long g_bad_actual;
volatile uint32_t g_bad_tick;

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
        g_bad_cause = csr_read(mcause);
    }
}

__attribute__((noinline, used)) void
record_frame_failure(uint32_t code, uint32_t index, unsigned long expected, unsigned long actual)
{
    if (!g_fail_seen) {
        g_bad_frame_index = index;
        g_bad_expected = expected;
        g_bad_actual = actual;
        g_bad_tick = g_ticks;
        record_failure(code);
    }
}

static void clear_frame_checks(void)
{
    for (uint32_t i = 0; i < FRAME_WORDS; i++) {
        g_frame_check_mask[i] = 0u;
        g_expected_frame[i] = 0u;
    }
}

static void expect_frame_word(uint32_t index, uint32_t value)
{
    g_expected_frame[index] = value;
    g_frame_check_mask[index] = 0xFFFFFFFFu;
}

static void check_frame_masked(struct linux_pt_regs *frame)
{
    volatile unsigned long *words = (volatile unsigned long *) frame;

    for (uint32_t i = 0; i < FRAME_WORDS; i++) {
        unsigned long mask = g_frame_check_mask[i];
        unsigned long actual;
        unsigned long expected;

        if (!mask) {
            continue;
        }
        actual = words[i];
        expected = g_expected_frame[i];
        if (((actual ^ expected) & mask) != 0u) {
            record_frame_failure(30u, i, expected, actual);
            break;
        }
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

__attribute__((noinline)) static uint32_t active_poison_window(uint32_t value)
{
    uint32_t out;

    __asm__ volatile("lui  t5, 0x1\n"
                     "addi t5, t5, -832\n"
                     "xor  %[out], %[in], t5\n"
                     "addi %[out], %[out], 37\n"
                     : [out] "=&r"(out)
                     : [in] "r"(value)
                     : "t5", "memory");

    return out;
}

__attribute__((noinline)) static uint32_t active_leaf(uint32_t seed)
{
    volatile uint32_t local[12];
    uint32_t acc = seed ^ g_context_checksum;

    for (uint32_t i = 0; i < ARRAY_LEN(local); i++) {
        local[i] = active_poison_window(acc + i);
        acc ^= local[i] + (i << 8);
    }

    return active_poison_window(acc);
}

__attribute__((noinline)) static uint32_t active_mid3(uint32_t seed)
{
    return active_leaf(seed + 0x11111111u) ^ active_leaf(seed + 0x22222222u);
}

__attribute__((noinline)) static uint32_t active_mid2(uint32_t seed)
{
    uint32_t a = active_mid3(seed ^ 0x33333333u);
    uint32_t b = active_poison_window(seed ^ a);

    return active_mid3(b) ^ a;
}

__attribute__((noinline)) static uint32_t active_mid1(uint32_t seed)
{
    return active_mid2(seed + 0x44444444u) ^ active_poison_window(seed);
}

__attribute__((noinline)) static uint32_t active_until_irq(uint32_t iter)
{
    uint32_t before = g_ticks;
    uint32_t acc = iter ^ 0xA5A50000u;
    uint32_t guard = 0;

    write_tp((uintptr_t) &g_fake_current);
    csr_write(mscratch, 0u);
    g_exact_frame_check = 0u;
    clear_frame_checks();
    clint_set_timer_cmp(clint_rdmtime() + 700u + (iter & 63u));
    enable_interrupts();

    while (g_ticks == before && !g_fail_seen) {
        acc ^= active_mid1(acc + guard);
        guard++;
        if (guard > 20000u) {
            record_failure(19u);
            break;
        }
    }

    disable_interrupts();

    if (g_ticks != before + 1u) {
        record_failure(20u);
    }
    if (read_tp() != (uintptr_t) &g_fake_current) {
        record_failure(21u);
    }
    if (csr_read(mscratch) != 0u) {
        record_failure(22u);
    }

    return churn_context(acc ^ g_ticks);
}

static void setup_sentinel_frame_checks(void)
{
    clear_frame_checks();
    expect_frame_word(FRAME_TP, (uintptr_t) &g_fake_current);
    expect_frame_word(FRAME_S0, SENTINEL_S0);
    expect_frame_word(FRAME_S1, SENTINEL_S1);
    expect_frame_word(FRAME_S2, (uintptr_t) &g_fake_current);
    expect_frame_word(FRAME_S3, SENTINEL_S3);
    expect_frame_word(FRAME_S4, SENTINEL_S4);
    expect_frame_word(FRAME_S5, SENTINEL_S5);
    expect_frame_word(FRAME_S6, SENTINEL_S6);
    expect_frame_word(FRAME_S7, SENTINEL_S7);
    expect_frame_word(FRAME_S8, SENTINEL_S8);
    expect_frame_word(FRAME_S9, SENTINEL_S9);
    expect_frame_word(FRAME_S10, SENTINEL_S10);
    expect_frame_word(FRAME_S11, SENTINEL_S11);
}

__attribute__((naked, noinline, used)) static uint32_t name_to_int_shape_asm(uint32_t seed)
{
    __asm__ volatile("li   a5, 0x19999998\n"
                     "addi a4, a5, 9\n"
                     "xor  a0, a0, a5\n"
                     "add  a0, a0, a4\n"
                     "ret\n");
}

__attribute__((naked, noinline, used)) static uint32_t sentinel_irq_window(uint32_t before)
{
    __asm__ volatile(
        "addi sp, sp, -16*" XB "\n" XS " ra, 0*" XB "(sp)\n" XS " s0, 1*" XB "(sp)\n" XS
        " s1, 2*" XB "(sp)\n" XS " s2, 3*" XB "(sp)\n" XS " s3, 4*" XB "(sp)\n" XS " s4, 5*" XB
        "(sp)\n" XS " s5, 6*" XB "(sp)\n" XS " s6, 7*" XB "(sp)\n" XS " s7, 8*" XB "(sp)\n" XS
        " s8, 9*" XB "(sp)\n" XS " s9, 10*" XB "(sp)\n" XS " s10, 11*" XB "(sp)\n" XS " s11, 12*" XB
        "(sp)\n" XS " a0, 13*" XB "(sp)\n"
        "li   s0, 0x51000000\n"
        "li   s1, 0x51000001\n"
        "la   s2, g_fake_current\n"
        "li   s3, 0x51000003\n"
        "li   s4, 0x51000004\n"
        "li   s5, 0x51000005\n"
        "li   s6, 0x51000006\n"
        "li   s7, 0x51000007\n"
        "li   s8, 0x51000008\n"
        "li   s9, 0x51000009\n"
        "li   s10, 0x5100000a\n"
        "li   s11, 0x5100000b\n"
        "li   t0, 8\n"
        "csrs mstatus, t0\n"
        "li   t6, 0\n"
        "1:\n" XL " a0, 13*" XB "(sp)\n"
        "call name_to_int_shape_asm\n"
        "la   t0, g_fail_seen\n"
        "lw   t1, 0(t0)\n"
        "bnez t1, 2f\n"
        "la   t0, g_ticks\n"
        "lw   t1, 0(t0)\n" XL " t2, 13*" XB "(sp)\n"
        "bne  t1, t2, 2f\n"
        "addi t6, t6, 1\n"
        "li   t3, 30000\n"
        "bltu t6, t3, 1b\n"
        "li   t0, 8\n"
        "csrc mstatus, t0\n"
        "li   a0, 41\n"
        "li   a1, 0xffffffff\n"
        "li   a2, 0\n"
        "mv   a3, t6\n"
        "call record_frame_failure\n"
        "j    3f\n"
        "2:\n"
        "li   t0, 8\n"
        "csrc mstatus, t0\n"
        "3:\n"
        "li   t0, 0x51000000\n"
        "beq  s0, t0, 4f\n"
        "li   a0, 31\n"
        "li   a1, 8\n"
        "li   a2, 0x51000000\n"
        "mv   a3, s0\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "4:\n"
        "li   t0, 0x51000001\n"
        "beq  s1, t0, 5f\n"
        "li   a0, 31\n"
        "li   a1, 9\n"
        "li   a2, 0x51000001\n"
        "mv   a3, s1\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "5:\n"
        "la   t0, g_fake_current\n"
        "beq  s2, t0, 6f\n"
        "li   a0, 31\n"
        "li   a1, 18\n"
        "la   a2, g_fake_current\n"
        "mv   a3, s2\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "6:\n"
        "li   t0, 0x51000003\n"
        "beq  s3, t0, 7f\n"
        "li   a0, 31\n"
        "li   a1, 19\n"
        "li   a2, 0x51000003\n"
        "mv   a3, s3\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "7:\n"
        "li   t0, 0x51000004\n"
        "beq  s4, t0, 8f\n"
        "li   a0, 31\n"
        "li   a1, 20\n"
        "li   a2, 0x51000004\n"
        "mv   a3, s4\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "8:\n"
        "li   t0, 0x51000005\n"
        "beq  s5, t0, 9f\n"
        "li   a0, 31\n"
        "li   a1, 21\n"
        "li   a2, 0x51000005\n"
        "mv   a3, s5\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "9:\n"
        "li   t0, 0x51000006\n"
        "beq  s6, t0, 10f\n"
        "li   a0, 31\n"
        "li   a1, 22\n"
        "li   a2, 0x51000006\n"
        "mv   a3, s6\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "10:\n"
        "li   t0, 0x51000007\n"
        "beq  s7, t0, 11f\n"
        "li   a0, 31\n"
        "li   a1, 23\n"
        "li   a2, 0x51000007\n"
        "mv   a3, s7\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "11:\n"
        "li   t0, 0x51000008\n"
        "beq  s8, t0, 12f\n"
        "li   a0, 31\n"
        "li   a1, 24\n"
        "li   a2, 0x51000008\n"
        "mv   a3, s8\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "12:\n"
        "li   t0, 0x51000009\n"
        "beq  s9, t0, 13f\n"
        "li   a0, 31\n"
        "li   a1, 25\n"
        "li   a2, 0x51000009\n"
        "mv   a3, s9\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "13:\n"
        "li   t0, 0x5100000a\n"
        "beq  s10, t0, 14f\n"
        "li   a0, 31\n"
        "li   a1, 26\n"
        "li   a2, 0x5100000a\n"
        "mv   a3, s10\n"
        "call record_frame_failure\n"
        "j    15f\n"
        "14:\n"
        "li   t0, 0x5100000b\n"
        "beq  s11, t0, 15f\n"
        "li   a0, 31\n"
        "li   a1, 27\n"
        "li   a2, 0x5100000b\n"
        "mv   a3, s11\n"
        "call record_frame_failure\n"
        "15:\n" XL " ra, 0*" XB "(sp)\n" XL " s0, 1*" XB "(sp)\n" XL " s1, 2*" XB "(sp)\n" XL
        " s2, 3*" XB "(sp)\n" XL " s3, 4*" XB "(sp)\n" XL " s4, 5*" XB "(sp)\n" XL " s5, 6*" XB
        "(sp)\n" XL " s6, 7*" XB "(sp)\n" XL " s7, 8*" XB "(sp)\n" XL " s8, 9*" XB "(sp)\n" XL
        " s9, 10*" XB "(sp)\n" XL " s10, 11*" XB "(sp)\n" XL " s11, 12*" XB "(sp)\n"
        "addi sp, sp, 16*" XB "\n"
        "ret\n");
}

__attribute__((noinline)) static uint32_t sentinel_until_irq(uint32_t iter)
{
    uint32_t before = g_ticks;

    write_tp((uintptr_t) &g_fake_current);
    csr_write(mscratch, 0u);
    g_exact_frame_check = 0u;
    setup_sentinel_frame_checks();
    clint_set_timer_cmp(clint_rdmtime() + 180u + ((iter * 37u) & 255u));
    sentinel_irq_window(before);
    disable_interrupts();
    clear_frame_checks();

    if (g_ticks != before + 1u) {
        record_failure(32u);
    }
    if (read_tp() != (uintptr_t) &g_fake_current) {
        record_failure(33u);
    }
    if (csr_read(mscratch) != 0u) {
        record_failure(34u);
    }

    return churn_context(0x19999998u ^ iter ^ g_ticks);
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
        g_bad_epc = frame->epc;
        g_bad_ra = frame->ra;
        record_failure(1u);
        uart_printf("FAIL code=%u ticks=%u cause=%08x mepc=%08x ra=%08x\n",
                    g_fail_code,
                    g_ticks,
                    frame->cause,
                    frame->epc,
                    frame->ra);
        uart_printf("<<FAIL>>\n");
        for (;;) {
        }
    }
    check_frame_masked(frame);
    if (g_exact_frame_check) {
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
    } else {
        if (frame->epc < 0x80000000u || frame->epc == 0x00000CC0u) {
            record_failure(15u);
        }
        if (frame->ra < 0x80000000u || frame->ra == 0x00000CC0u) {
            record_failure(16u);
        }
        if (frame->sp < 0x80000000u) {
            record_failure(17u);
        }
        if (frame->tp != (uintptr_t) &g_fake_current) {
            record_failure(18u);
        }
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
    g_exact_frame_check = 1u;
    clear_frame_checks();
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
    g_exact_frame_check = 1u;
    clear_frame_checks();
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

    uart_printf("\n=== Linux-like active DDR timer IRQ test ===\n");
    fill_context();
    clear_frame_checks();
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
    for (uint32_t i = 0; i < ACTIVE_IRQ_COUNT && !g_fail_seen; i++) {
        aggregate ^= active_until_irq(i);
    }
    for (uint32_t i = 0; i < SENTINEL_IRQ_COUNT && !g_fail_seen; i++) {
        aggregate ^= sentinel_until_irq(i);
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
        uart_printf(
            "FAIL code=%u ticks=%u cause=%08x mepc=%08x ra=%08x sp=%08x tp=%08x mscratch=%08x\n",
            g_fail_code,
            g_ticks,
            g_bad_cause,
            g_last_mepc,
            g_last_ra,
            g_last_sp,
            g_last_tp,
            g_last_mscratch_in_handler);
        uart_printf("bad_frame idx=%u tick=%u expected=%08x actual=%08x\n",
                    g_bad_frame_index,
                    g_bad_tick,
                    g_bad_expected,
                    g_bad_actual);
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
