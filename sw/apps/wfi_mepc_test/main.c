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
 * Timer-interrupt-at-WFI mepc directed test.
 *
 * No-MMU M-mode Linux dies on the FIRST machine-timer interrupt taken from the
 * idle loop (which executes WFI). FROST sources the interrupt resume PC (mepc)
 * from the ROB head_pc UNCONDITIONALLY (reorder_buffer.sv o_trap_pc = head_pc,
 * trap_unit.sv interrupt o_trap_pc = i_exception_pc), with no head_valid check.
 * WFI drains the ROB, so when the timer fires at WFI the ROB is EMPTY and the
 * saved mepc can be a stale head_pc instead of the instruction after the WFI.
 *
 * umode_test's timer-preempt never hit this: its U-code spins (ROB busy) and it
 * never checks mepc. This test fires a timer interrupt while the core is in WFI
 * (empty ROB) and checks that the saved mepc == the resume point after the WFI.
 * Self-checks over UART (<<PASS>>/<<FAIL>>).
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

static volatile uint32_t g_mepc;
static volatile uint32_t g_taken;

/*
 * Naked M-mode handler: record mepc (the saved resume PC) + the taken flag,
 * ack the timer (push mtimecmp_hi to max so it cannot refire), then resume at
 * the safe continuation stashed in mscratch (NOT the recorded mepc -- if mepc
 * is wrong we must still land somewhere valid to report the result). Clobbering
 * temporaries is fine because we bounce to a fixed continuation.
 */
__attribute__((naked, aligned(4))) static void wfi_trap_handler(void)
{
    __asm__ volatile("csrr t0, mepc\n"
                     "lui  t1, %hi(g_mepc)\n"
                     "sw   t0, %lo(g_mepc)(t1)\n"
                     "li   t0, 1\n"
                     "lui  t1, %hi(g_taken)\n"
                     "sw   t0, %lo(g_taken)(t1)\n"
                     "li   t1, 0x4000001C\n" /* MTIMECMP_HI: ack timer */
                     "li   t0, -1\n"
                     "sw   t0, 0(t1)\n"
                     "csrr t0, mscratch\n" /* safe continuation after the WFI */
                     "csrw mepc, t0\n"
                     "mret\n");
}

int main(void)
{
    uint32_t resume_pc;

    uart_printf("\n=== timer-interrupt-at-WFI mepc test ===\n");
    set_trap_handler(&wfi_trap_handler);
    g_mepc = 0;
    g_taken = 0;

    enable_timer_interrupt();
    set_timer_cmp(rdmtime() + 300); /* fire ~300 cycles out: lands during WFI */
    enable_interrupts();

    /* Stash the post-WFI continuation in mscratch, capture its address as the
     * expected resume PC, then WFI (drains the ROB). The timer fires here. */
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "la   %0, 1f\n"
                     "wfi\n"
                     "1:\n"
                     : "=r"(resume_pc)
                     :
                     : "t0", "memory");

    while (!g_taken) {
    }

    uart_printf("mepc=%08x  expected(after WFI)=%08x  taken=%u\n", g_mepc, resume_pc, g_taken);
    if (g_mepc == resume_pc) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>> interrupt-from-empty-ROB saved a stale mepc (not the WFI resume PC)\n");
    }
    for (;;) {
    }
    return 0;
}
