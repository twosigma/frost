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
 * Drain-gated WFI mepc regression.
 *
 * A timer becomes eligible with WFI at the ROB head while a committed cached
 * store drains. When the drain ended, take_trap could precede the registered
 * commit hold by one cycle, flushing WFI before commit and saving wfi_pc
 * instead of the required wfi_pc+4.
 *
 * Under MEM_CONFIG=ddr, each timer margin stores to a fresh cold line before
 * WFI, forcing a full-latency drain. mscratch is armed before MIE is enabled,
 * and the register-preserving handler returns through mscratch, so a bad mepc
 * survives to be reported. The test passes when no margin produces
 * mepc==wfi_pc. Run with DDR_MODEL_LATENCY>=70.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define MARGIN_MIN 0u
#define MARGIN_MAX 200u

/* Unused DDR region within the 64 MiB model; one cold line per margin. */
#define DRAIN_BASE 0x82000000u
#define DRAIN_LINE 64u

static volatile uint32_t g_mepc;  /* mepc the trap saved, last fire */
static volatile uint32_t g_taken; /* running count of timer traps taken */

/*
 * Preserve t0/t1, record mepc, disarm the timer, and resume at the fixed
 * mscratch continuation rather than the value under test.
 */
__attribute__((naked, aligned(4))) static void wfi_drain_trap_handler(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "csrr t0, mepc\n"
                     /* la (auipc-based under medany): absolute lui cannot
                      * materialize this DDR-resident image's 0x8xxx_xxxx
                      * data addresses at lp64. */
                     "la   t1, g_mepc\n"
                     "sw   t0, 0(t1)\n"
                     "la   t1, g_taken\n"
                     "lw   t0, 0(t1)\n"
                     "addi t0, t0, 1\n"
                     "sw   t0, 0(t1)\n"
                     "li   t1, 0x4000001C\n" /* MTIMECMP_HI: disarm */
                     "li   t0, -1\n"
                     "sw   t0, 0(t1)\n"
                     "csrr t0, mscratch\n" /* fixed continuation after the WFI */
                     "csrw mepc, t0\n"
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "addi sp, sp, 16\n"
                     "mret\n");
}

int main(void)
{
    uint32_t bug = 0, correct = 0, early = 0, nofire = 0;
    uint32_t bug_margin = 0, bug_mepc = 0, bug_wfi = 0;

    uart_printf("\n=== drain-gated WFI mepc test ===\n");
    set_trap_handler(&wfi_drain_trap_handler);
    enable_timer_interrupt();

    for (uint32_t margin = MARGIN_MIN; margin <= MARGIN_MAX; margin++) {
        volatile uint32_t *sink = (volatile uint32_t *) (DRAIN_BASE + margin * DRAIN_LINE);
        uint32_t wfi_addr = 0;
        uint32_t resume_addr = 0;
        uint32_t before = g_taken;

        g_mepc = 0;
        set_timer_cmp(rdmtime() + margin); /* armed; MIE still 0 until the asm */

        /*
         * Arm mscratch (the handler continuation) before enabling interrupts,
         * then enable MIE in the asm block. Capture the WFI and resume PCs, then
         * issue one cold-miss DDR store directly before the WFI: that committed
         * entry must still be draining when the IRQ is taken. Execute the WFI,
         * then disable MIE. The handler returns to label 2 whatever mepc holds.
         */
        __asm__ volatile("la    %[res], 2f\n"
                         "csrw  mscratch, %[res]\n"
                         "csrsi mstatus, 8\n" /* enable MIE (interrupts) after mscratch is valid */
                         "la    %[wfi], 1f\n"
                         "sw    %[res], 0(%[sink])\n"
                         "1:\n"
                         "wfi\n"
                         "2:\n"
                         "csrci mstatus, 8\n" /* disable MIE */
                         : [res] "=&r"(resume_addr), [wfi] "=&r"(wfi_addr)
                         : [sink] "r"(sink)
                         : "memory");

        if (g_taken == before) {
            nofire++;
            continue;
        }
        if (g_mepc == wfi_addr) {
            bug++;
            bug_margin = margin;
            bug_mepc = g_mepc;
            bug_wfi = wfi_addr;
        } else if (g_mepc == resume_addr) {
            correct++;
        } else {
            early++;
        }
    }

    disable_timer_interrupt();
    disable_interrupts();

    uart_printf("sweep: bug=%u correct=%u early=%u nofire=%u\n", bug, correct, early, nofire);
    if (bug) {
        uart_printf("drain-gated WFI saved mepc==wfi_pc: margin=%u mepc=%08x wfi=%08x\n",
                    bug_margin,
                    bug_mepc,
                    bug_wfi);
        uart_printf("<<FAIL>>\n");
    } else {
        uart_printf("<<PASS>>\n");
    }

    for (;;) {
    }
    return 0;
}
