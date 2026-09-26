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
 * Directed instret test: minstret counts every retired instruction, including
 * the ones that retire without an ordinary commit.
 *
 * Every measured block is straight-line code of 4-byte instructions, so the
 * number of instructions that retire between two points is their distance
 * divided by 4. A block starts with `csrr start, minstret`, and either ends
 * with a second minstret read or is cut short by an interrupt whose handler
 * reads minstret in its first instruction. In the second case mepc marks the
 * cut, and the count must equal (mepc - block start) / 4 wherever it lands.
 *
 *   1. NOPs: runs of `nop` and `c.nop` fill both slots of a fetch pair and
 *      whole pairs, at two alignments.
 *   2. MRET, FENCE.I and SFENCE.VMA, which each end in a full flush: an
 *      M-to-M return to the next instruction retires the MRET, and each fence
 *      retires once.
 *   3. A WFI that a timer interrupt ends. The timer margin sweeps the take
 *      across the block, and at least one take must find the WFI waiting
 *      (mepc past it: the WFI retired).
 *   4. A software interrupt raised by a store, followed by a device-register
 *      load. The load waits for the store to drain, and its interrupt shield
 *      holds off the take until the load commits, so the take shares its
 *      cycle with the next instruction's commit. At least one take must land
 *      after the load.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define MSIP_REG 0x40000020u
#define UART_TX_STATUS_REG 0x40000028u

#define WFI_MARGINS 96u
#define SHIELD_PADS 4u /* SHIELD_TRIAL variants: 0 to 3 instructions before the load */

static int g_failed;

/* Filled by the trap handler: minstret at its first instruction, mepc, and
 * the number of traps taken. */
static volatile uint64_t g_trap_instret;
static volatile uint64_t g_trap_mepc;
static volatile uint32_t g_trap_count;

static void check(const char *name, int ok)
{
    uart_printf("  %s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok)
        g_failed = 1;
}

/*
 * Read minstret first, record it with mepc, clear both interrupt sources, and
 * resume at the continuation in mscratch. Only t0 and t1 are used, and the
 * measured blocks list both as clobbers.
 */
__attribute__((naked, aligned(4))) static void instret_trap_handler(void)
{
    __asm__ volatile("csrr t0, minstret\n"
                     "la   t1, g_trap_instret\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_trap_mepc\n"
                     "sd   t0, 0(t1)\n"
                     "la   t1, g_trap_count\n"
                     "lw   t0, 0(t1)\n"
                     "addi t0, t0, 1\n"
                     "sw   t0, 0(t1)\n"
                     "li   t1, 0x4000001C\n" /* MTIMECMP_HI: disarm the timer */
                     "li   t0, -1\n"
                     "sw   t0, 0(t1)\n"
                     "li   t1, 0x40000020\n" /* MSIP: clear */
                     "sw   zero, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "mret\n");
}

/* Seven NOPs between two minstret reads: the reads differ by 8, the first
 * read and the seven NOPs. `pad` shifts the block by one instruction. */
static void nop_tests(void)
{
    uint64_t a, b;

    uart_printf("\nTest 1: NOPs retire and count\n");
    __asm__ volatile(".option push\n.option norvc\n"
                     ".balign 8\n"
                     "csrr %0, minstret\n"
                     "nop\nnop\nnop\nnop\nnop\nnop\nnop\n"
                     "csrr %1, minstret\n"
                     ".option pop\n"
                     : "=&r"(a), "=r"(b));
    uart_printf("  nop x7, aligned: %u\n", (unsigned) (b - a));
    check("seven nops count, aligned", b - a == 8);
    __asm__ volatile(".option push\n.option norvc\n"
                     ".balign 8\n"
                     "nop\n"
                     "csrr %0, minstret\n"
                     "nop\nnop\nnop\nnop\nnop\nnop\nnop\n"
                     "csrr %1, minstret\n"
                     ".option pop\n"
                     : "=&r"(a), "=r"(b));
    check("seven nops count, offset by one", b - a == 8);
    __asm__ volatile(".option push\n.option rvc\n"
                     ".balign 8\n"
                     "csrr %0, minstret\n"
                     "c.nop\nc.nop\nc.nop\nc.nop\nc.nop\nc.nop\nc.nop\n"
                     "csrr %1, minstret\n"
                     ".option pop\n"
                     : "=&r"(a), "=r"(b));
    uart_printf("  c.nop x7: %u\n", (unsigned) (b - a));
    check("seven c.nops count", b - a == 8);
}

/* An MRET that returns to the next instruction in M, a FENCE.I and an
 * SFENCE.VMA: each pair of reads differs by 2, the first read and the
 * instruction. MPIE is cleared first so MIE stays 0 after the MRET. */
static void flush_tests(void)
{
    uint64_t a, b;

    uart_printf("\nTest 2: MRET, FENCE.I and SFENCE.VMA retire and count\n");
    __asm__ volatile(".option push\n.option norvc\n"
                     "la   t0, 1f\n"
                     "csrw mepc, t0\n"
                     "li   t0, %2\n"
                     "csrs mstatus, t0\n"
                     "li   t0, %3\n"
                     "csrc mstatus, t0\n"
                     "csrr %0, minstret\n"
                     "mret\n"
                     "1:\n"
                     "csrr %1, minstret\n"
                     ".option pop\n"
                     : "=&r"(a), "=r"(b)
                     : "i"(MSTATUS_MPP), "i"(MSTATUS_MPIE)
                     : "t0", "memory");
    uart_printf("  csrr; mret; csrr: %u\n", (unsigned) (b - a));
    check("mret counts", b - a == 2);
    __asm__ volatile("csrr %0, minstret\n"
                     "fence.i\n"
                     "csrr %1, minstret\n"
                     : "=&r"(a), "=r"(b)
                     :
                     : "memory");
    uart_printf("  csrr; fence.i; csrr: %u\n", (unsigned) (b - a));
    check("fence.i counts", b - a == 2);
    __asm__ volatile("csrr %0, minstret\n"
                     "sfence.vma\n"
                     "csrr %1, minstret\n"
                     : "=&r"(a), "=r"(b)
                     :
                     : "memory");
    uart_printf("  csrr; sfence.vma; csrr: %u\n", (unsigned) (b - a));
    check("sfence.vma counts", b - a == 2);
}

/* Compare the handler's minstret with the instructions from `start_pc` up to
 * mepc. Returns 1 when they agree. */
static int trap_count_exact(uint64_t start, uint64_t start_pc)
{
    uint64_t retired = g_trap_instret - start;
    uint64_t expected = (g_trap_mepc - start_pc) / 4;

    if (retired == expected)
        return 1;
    uart_printf("    mepc=%08x start=%08x retired=%u expected=%u\n",
                (unsigned) g_trap_mepc,
                (unsigned) start_pc,
                (unsigned) retired,
                (unsigned) expected);
    return 0;
}

/* A timer interrupt ends a block that stops at a WFI. */
static void wfi_test(void)
{
    uint32_t mismatches = 0, at_wfi = 0, before_wfi = 0;

    uart_printf("\nTest 3: a WFI that an interrupt ends\n");
    enable_timer_interrupt();
    for (uint32_t margin = 0; margin < WFI_MARGINS; margin++) {
        uint64_t start = 0, start_pc = 0, wfi_pc = 0, resume = 0, scratch = 0;
        uint32_t before = g_trap_count;

        set_timer_cmp(rdmtime() + margin);
        __asm__ volatile(".option push\n.option norvc\n"
                         "la    %[res], 2f\n"
                         "csrw  mscratch, %[res]\n"
                         "la    %[spc], 1f\n"
                         "la    %[wpc], 3f\n"
                         "1:\n"
                         "csrr  %[start], minstret\n"
                         "csrsi mstatus, 8\n"
                         "addi  %[scr], x0, 1\n"
                         "addi  %[scr], x0, 2\n"
                         "addi  %[scr], x0, 3\n"
                         "addi  %[scr], x0, 4\n"
                         "3:\n"
                         "wfi\n"
                         "2:\n"
                         "csrci mstatus, 8\n"
                         ".option pop\n"
                         : [res] "=&r"(resume),
                           [spc] "=&r"(start_pc),
                           [wpc] "=&r"(wfi_pc),
                           [start] "=&r"(start),
                           [scr] "=&r"(scratch)
                         :
                         : "t0", "t1", "memory");
        (void) scratch;
        if (g_trap_count == before) {
            /* The wfi resumed without a take: nothing to compare. */
            continue;
        }
        if (g_trap_mepc == wfi_pc + 4)
            at_wfi++;
        else
            before_wfi++;
        if (!trap_count_exact(start, start_pc))
            mismatches++;
    }
    disable_timer_interrupt();
    uart_printf("  takes: %u past the wfi, %u before it\n", at_wfi, before_wfi);
    check("every take counts exactly the instructions before mepc", mismatches == 0);
    check("some take found the wfi waiting", at_wfi > 0);
}

/*
 * One shield trial: a store raises MSIP, NPAD instructions follow, then a
 * load from the UART TX status register and eight independent instructions.
 * The block ends in a WFI in case the take comes late.
 */
#define SHIELD_TRIAL(NPAD)                                                                         \
    __asm__ volatile(".option push\n.option norvc\n"                                               \
                     "la    %[res], 2f\n"                                                          \
                     "csrw  mscratch, %[res]\n"                                                    \
                     "la    %[spc], 1f\n"                                                          \
                     "la    %[lpc], 5f\n"                                                          \
                     "li    t0, 1\n"                                                               \
                     "li    t1, %[msip]\n"                                                         \
                     "1:\n"                                                                        \
                     "csrr  %[start], minstret\n"                                                  \
                     "csrsi mstatus, 8\n"                                                          \
                     "sw    t0, 0(t1)\n"                                                           \
                     ".rept " #NPAD "\n"                                                           \
                     "addi  t0, x0, 1\n"                                                           \
                     ".endr\n"                                                                     \
                     "li    t1, %[txs]\n"                                                          \
                     "5:\n"                                                                        \
                     "lw    %[scr], 0(t1)\n"                                                       \
                     ".rept 8\n"                                                                   \
                     "addi  t0, x0, 2\n"                                                           \
                     ".endr\n"                                                                     \
                     "wfi\n"                                                                       \
                     "2:\n"                                                                        \
                     "csrci mstatus, 8\n"                                                          \
                     ".option pop\n"                                                               \
                     : [res] "=&r"(resume),                                                        \
                       [lpc] "=&r"(load_pc),                                                       \
                       [spc] "=&r"(start_pc),                                                      \
                       [start] "=&r"(start),                                                       \
                       [scr] "=&r"(scratch)                                                        \
                     : [msip] "i"(MSIP_REG), [txs] "i"(UART_TX_STATUS_REG)                         \
                     : "t0", "t1", "memory")

static void shield_test(void)
{
    uint32_t mismatches = 0, after_load = 0, before_load = 0;

    uart_printf("\nTest 4: an interrupt the device-read shield defers\n");
    enable_software_interrupt();
    for (uint32_t trial = 0; trial < 4 * SHIELD_PADS; trial++) {
        uint64_t start = 0, start_pc = 0, load_pc = 0, resume = 0, scratch = 0;
        uint32_t before = g_trap_count;

        switch (trial % SHIELD_PADS) {
            case 0:
                SHIELD_TRIAL(0);
                break;
            case 1:
                SHIELD_TRIAL(1);
                break;
            case 2:
                SHIELD_TRIAL(2);
                break;
            default:
                SHIELD_TRIAL(3);
                break;
        }
        (void) scratch;
        (void) resume;
        if (g_trap_count == before) {
            uart_printf("    trial %u: no take\n", trial);
            mismatches++;
            continue;
        }
        if (g_trap_mepc > load_pc)
            after_load++;
        else
            before_load++;
        if (!trap_count_exact(start, start_pc))
            mismatches++;
    }
    disable_software_interrupt();
    uart_printf("  takes: %u after the load, %u at or before it\n", after_load, before_load);
    check("every take counts exactly the instructions before mepc", mismatches == 0);
    check("some take followed the shielded load", after_load > 0);
}

int main(void)
{
    uart_printf("\n=== instret test ===\n");
    set_trap_handler(&instret_trap_handler);
    disable_interrupts();

    nop_tests();
    flush_tests();
    wfi_test();
    shield_test();

    if (g_failed) {
        uart_printf("\n=== instret test FAILED ===\n<<FAIL>>\n");
    } else {
        uart_printf("\n=== instret test PASSED ===\n<<PASS>>\n");
    }
    for (;;) {
    }
    return 0;
}
