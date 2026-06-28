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
 * The no-MMU Linux hardware failure is an illegal-instruction panic with
 * ra == epc == 0x00000cc0 after the first machine timer interrupt from idle.
 * This test keeps the loop much smaller than Linux while preserving the risky
 * ingredients: DDR-resident code/data, an explicit DDR stack, WFI idle,
 * active-code machine-timer IRQs, a Linux-style naked trap entry that
 * saves/restores GPRs on the current stack, and the csrrw tp,mscratch,tp swap
 * idiom. The active phase repeatedly creates a low-value temporary-register
 * poison while nested call/return traffic is in flight; ra should remain a
 * high DDR return address at every interrupt boundary.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

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
    uint32_t epc;
    uint32_t ra;
    uint32_t sp;
    uint32_t gp;
    uint32_t tp;
    uint32_t t0;
    uint32_t t1;
    uint32_t t2;
    uint32_t s0;
    uint32_t s1;
    uint32_t a0;
    uint32_t a1;
    uint32_t a2;
    uint32_t a3;
    uint32_t a4;
    uint32_t a5;
    uint32_t a6;
    uint32_t a7;
    uint32_t s2;
    uint32_t s3;
    uint32_t s4;
    uint32_t s5;
    uint32_t s6;
    uint32_t s7;
    uint32_t s8;
    uint32_t s9;
    uint32_t s10;
    uint32_t s11;
    uint32_t t3;
    uint32_t t4;
    uint32_t t5;
    uint32_t t6;
    uint32_t status;
    uint32_t badaddr;
    uint32_t cause;
    uint32_t orig_a0;
};

struct fake_current {
    uint32_t kernel_sp;
    uint32_t user_sp;
    uint32_t marker;
};

volatile uint32_t g_expected_mepc;
volatile uint32_t g_expected_ra;
volatile uint32_t g_expected_sp;
volatile uint32_t g_expected_tp;
volatile uint32_t g_exact_frame_check;
volatile struct fake_current g_fake_current = {0u, 0u, 0x5441534Bu};
volatile uint32_t g_ticks;
volatile uint32_t g_fail_code;
volatile uint32_t g_fail_seen;
volatile uint32_t g_bad_cause;
volatile uint32_t g_bad_epc;
volatile uint32_t g_bad_ra;
volatile uint32_t g_last_mepc;
volatile uint32_t g_last_ra;
volatile uint32_t g_last_sp;
volatile uint32_t g_last_tp;
volatile uint32_t g_last_mscratch_in_handler;
volatile uint32_t g_context_checksum;
volatile uint32_t g_context_words[64];
volatile uint32_t g_frame_snapshots[IRQ_COUNT][FRAME_WORDS];
volatile uint32_t g_frame_check_mask[FRAME_WORDS];
volatile uint32_t g_expected_frame[FRAME_WORDS];
volatile uint32_t g_bad_frame_index;
volatile uint32_t g_bad_expected;
volatile uint32_t g_bad_actual;
volatile uint32_t g_bad_tick;

static uint8_t g_ddr_stack[DDR_STACK_SIZE] __attribute__((aligned(16)));

static inline uint32_t read_tp(void)
{
    uint32_t value;
    __asm__ volatile("mv %0, tp" : "=r"(value));
    return value;
}

static inline void write_tp(uint32_t value)
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
record_frame_failure(uint32_t code, uint32_t index, uint32_t expected, uint32_t actual)
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
    volatile uint32_t *words = (volatile uint32_t *) frame;

    for (uint32_t i = 0; i < FRAME_WORDS; i++) {
        uint32_t mask = g_frame_check_mask[i];
        uint32_t actual;
        uint32_t expected;

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

    write_tp((uint32_t) &g_fake_current);
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
    if (read_tp() != (uint32_t) &g_fake_current) {
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
    expect_frame_word(FRAME_TP, (uint32_t) &g_fake_current);
    expect_frame_word(FRAME_S0, SENTINEL_S0);
    expect_frame_word(FRAME_S1, SENTINEL_S1);
    expect_frame_word(FRAME_S2, (uint32_t) &g_fake_current);
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
    __asm__ volatile("addi sp, sp, -64\n"
                     "sw   ra, 0(sp)\n"
                     "sw   s0, 4(sp)\n"
                     "sw   s1, 8(sp)\n"
                     "sw   s2, 12(sp)\n"
                     "sw   s3, 16(sp)\n"
                     "sw   s4, 20(sp)\n"
                     "sw   s5, 24(sp)\n"
                     "sw   s6, 28(sp)\n"
                     "sw   s7, 32(sp)\n"
                     "sw   s8, 36(sp)\n"
                     "sw   s9, 40(sp)\n"
                     "sw   s10, 44(sp)\n"
                     "sw   s11, 48(sp)\n"
                     "sw   a0, 52(sp)\n"
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
                     "1:\n"
                     "lw   a0, 52(sp)\n"
                     "call name_to_int_shape_asm\n"
                     "la   t0, g_fail_seen\n"
                     "lw   t1, 0(t0)\n"
                     "bnez t1, 2f\n"
                     "la   t0, g_ticks\n"
                     "lw   t1, 0(t0)\n"
                     "lw   t2, 52(sp)\n"
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
                     "15:\n"
                     "lw   ra, 0(sp)\n"
                     "lw   s0, 4(sp)\n"
                     "lw   s1, 8(sp)\n"
                     "lw   s2, 12(sp)\n"
                     "lw   s3, 16(sp)\n"
                     "lw   s4, 20(sp)\n"
                     "lw   s5, 24(sp)\n"
                     "lw   s6, 28(sp)\n"
                     "lw   s7, 32(sp)\n"
                     "lw   s8, 36(sp)\n"
                     "lw   s9, 40(sp)\n"
                     "lw   s10, 44(sp)\n"
                     "lw   s11, 48(sp)\n"
                     "addi sp, sp, 64\n"
                     "ret\n");
}

__attribute__((noinline)) static uint32_t sentinel_until_irq(uint32_t iter)
{
    uint32_t before = g_ticks;

    write_tp((uint32_t) &g_fake_current);
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
    if (read_tp() != (uint32_t) &g_fake_current) {
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
            g_frame_snapshots[tick][i] = ((volatile uint32_t *) frame)[i];
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
        if (frame->tp != (uint32_t) &g_fake_current) {
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
                     "call linux_like_irq_c\n"
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

__attribute__((noinline)) static uint32_t idle_once(uint32_t iter)
{
    uint32_t before = g_ticks;

    write_tp((uint32_t) &g_fake_current);
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
    if (read_tp() != (uint32_t) &g_fake_current) {
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

    write_tp((uint32_t) &g_fake_current);
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
    if (read_tp() != (uint32_t) &g_fake_current) {
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
    g_fake_current.kernel_sp = (uint32_t) &g_ddr_stack[DDR_STACK_SIZE];
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
    uint32_t stack_top = ((uint32_t) &g_ddr_stack[DDR_STACK_SIZE]) & ~0xFu;

    __asm__ volatile("mv sp, %0\n"
                     "j  main_on_ddr_stack\n"
                     :
                     : "r"(stack_top)
                     : "memory");
    __builtin_unreachable();
}
