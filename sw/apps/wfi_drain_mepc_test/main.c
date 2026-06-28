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
 * Directed test for the *drain-gated* WFI mepc spec deviation.
 *
 * wfi_mepc_test covers the simple case (timer IRQ at a WFI with an empty ROB ->
 * mepc must be the post-WFI PC). This test targets a narrower, analysis-derived
 * window: a machine-timer interrupt that becomes eligible while a WFI is at the
 * ROB head AND a committed CACHED (DDR) store is still draining.
 *
 * Mechanism under test (cpu_ooo.sv interrupt_resume_pc / trap_unit.sv take_trap
 * gated on sq_committed_empty / the *registered* trap_mret_commit_hold_q): when
 * the store drain finishes, take_trap fires combinationally that cycle while
 * commit_hold still lags one cycle, so the WFI is flushed before it commits and
 * mepc is saved as the WFI's own PC instead of wfi_pc+4. RISC-V priv spec: an
 * interrupt taken at WFI resumes at the *following* instruction (mepc=wfi_pc+4).
 *
 * Construction: DDR-resident (MEM_CONFIG=ddr); immediately before the WFI, store
 * to a FRESH cold DDR cache line (a different line each margin, in a region the
 * program never otherwise touches) so the store reliably misses and drains the
 * full DDR latency -- regardless of L1 write policy / warmth. Sweep the timer
 * margin so the IRQ lands at every offset across that drain window.
 *
 * Robustness fixes vs the first cut:
 *  - mscratch (the handler's fixed continuation) is armed BEFORE interrupts are
 *    enabled, inside the asm, so a tiny margin cannot take the trap with a stale
 *    mscratch and crash. Enable/disable MIE is done in-asm around the WFI.
 *  - The handler is register-preserving and resumes via mscratch (never the
 *    recorded mepc), so a wrong mepc is detected, not fatal.
 *
 * PASS iff no margin ever produces mepc==wfi_pc. Run at DDR_MODEL_LATENCY>=70.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define MARGIN_MIN 0u
#define MARGIN_MAX 200u

/* Cold DDR region the program never otherwise touches (well inside the 64 MiB
 * model, far from the app's own code/data/stack). Each margin stores to its own
 * 64 B line here, so every pre-WFI store is a cold miss -> full DDR-latency drain. */
#define DRAIN_BASE 0x82000000u
#define DRAIN_LINE 64u

static volatile uint32_t g_mepc;  /* mepc the trap saved, last fire */
static volatile uint32_t g_taken; /* running count of timer traps taken */

/*
 * Naked M-mode timer handler. Register-preserving (saves/restores t0,t1 on the
 * current stack) so the WFI/resume addresses the caller holds in registers across
 * the WFI are not corrupted. Records the saved mepc, counts the trap, disarms the
 * timer (mtimecmp_hi := -1) so it cannot refire, then resumes at the fixed
 * continuation in mscratch -- never at the recorded mepc, so a wrong mepc cannot
 * send us back into the WFI and hang.
 */
__attribute__((naked, aligned(4))) static void wfi_drain_trap_handler(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sw   t0, 0(sp)\n"
                     "sw   t1, 4(sp)\n"
                     "csrr t0, mepc\n"
                     "lui  t1, %hi(g_mepc)\n"
                     "sw   t0, %lo(g_mepc)(t1)\n"
                     "lui  t1, %hi(g_taken)\n"
                     "lw   t0, %lo(g_taken)(t1)\n"
                     "addi t0, t0, 1\n"
                     "sw   t0, %lo(g_taken)(t1)\n"
                     "li   t1, 0x4000001C\n" /* MTIMECMP_HI: disarm */
                     "li   t0, -1\n"
                     "sw   t0, 0(t1)\n"
                     "csrr t0, mscratch\n" /* fixed continuation after the WFI */
                     "csrw mepc, t0\n"
                     "lw   t0, 0(sp)\n"
                     "lw   t1, 4(sp)\n"
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
         * Arm mscratch (handler continuation) BEFORE enabling interrupts, then
         * enable MIE in-asm; capture the WFI/resume PCs; issue one cold-miss DDR
         * store IMMEDIATELY before the WFI (the committed entry that must still be
         * draining when the IRQ is taken); WFI; then disable MIE. The handler
         * bounces us to label 2 regardless of mepc.
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
