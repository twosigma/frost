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
 * Timer-at-WFI mepc regression.
 *
 * WFI drains the ROB. The bug sourced mepc from head_pc without head_valid, so
 * an idle-loop timer could save stale state instead of the post-WFI PC. Fire a
 * timer in WFI and require mepc to equal the following instruction.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

static volatile uint32_t g_mepc;
static volatile uint32_t g_taken;

/*
 * Record mepc, disarm the timer, and resume at the continuation stashed in
 * mscratch instead of at mepc, which is the value under test. The resume point
 * is fixed, so the handler can clobber t0 and t1 without saving them.
 */
__attribute__((naked, aligned(4))) static void wfi_trap_handler(void)
{
    __asm__ volatile("csrr t0, mepc\n"
                     /* la (auipc-based under medany): absolute lui %hi cannot
                      * materialize the ddr build's 0x8xxx_xxxx data addresses
                      * at lp64. */
                     "la   t1, g_mepc\n"
                     "sw   t0, 0(t1)\n"
                     "li   t0, 1\n"
                     "la   t1, g_taken\n"
                     "sw   t0, 0(t1)\n"
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
                     /* The timer interrupt fires during the wfi and the naked
                      * handler clobbers t0 and t1: it uses t1 to address
                      * g_mepc/g_taken and then to ack MTIMECMP_HI. Both are
                      * listed so the compiler cannot keep a live value pinned in
                      * t1 across the wfi, such as g_taken's base. If it does, the
                      * post-wfi `while(!g_taken)` reads a stale clobbered address
                      * (DDR layout: 2008(t1=0x4000001C)=0x400007f4) and spins. */
                     : "t0", "t1", "memory");

    while (!g_taken) {
    }

    uart_printf("mepc=%08x  expected(after WFI)=%08x  taken=%u\n", g_mepc, resume_pc, g_taken);
    if (g_mepc == resume_pc) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf(
            "<<FAIL>> interrupt-from-empty-ROB saved a stale mepc (not the WFI resume PC)\n");
    }
    for (;;) {
    }
    return 0;
}
