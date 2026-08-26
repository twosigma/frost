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
 * Debug-module target program (Phase 3 M3). A debuggee with known landmarks:
 *
 *   - phase M: an M-mode loop that bumps `counter` and calls `bp_target`
 *     (target.S: a 32-bit instruction followed by two c.nop, the software
 *     breakpoint and single-step site) until the debugger writes flag = 1;
 *   - phase U: drops to U-mode (target.S `u_loop`: bump `counter`, ecall,
 *     repeat). The M-mode ecall handler counts the ecalls, and once the
 *     debugger has written flag = 2 it prints the pass marker and parks in a
 *     wfi loop (the halt-during-WFI site).
 *
 * The benches find `counter`, `flag`, `table`, `ecall_count` and the
 * target.S labels through the ELF symbol table; nothing here depends on the
 * debugger except the two flag writes, so the program also runs to the same
 * banners on its own (the debugger-free runs print the phase banners and
 * then wait forever in phase M, which is the expected shape without a
 * debugger).
 */

#include <stdint.h>

#include "csr.h"
#include "uart.h"

/* target.S */
extern void trap_entry(void);
extern void bp_target(void);
extern void u_loop(void);

volatile uint64_t counter = 0;
volatile uint64_t flag = 0;
volatile uint64_t ecall_count = 0;
volatile uint64_t table[8] = {0x1000000000000001ULL,
                              0x1000000000000002ULL,
                              0x1000000000000003ULL,
                              0x1000000000000004ULL,
                              0x1000000000000005ULL,
                              0x1000000000000006ULL,
                              0x1000000000000007ULL,
                              0x1000000000000008ULL};

static void park_forever(void)
{
    for (;;) {
        __asm__ volatile("wfi");
    }
}

/* Called from trap_entry (target.S) with a0 = mcause, a1 = mepc; returns the
 * mepc to resume at. Only ecall from U (8) and M (11) are expected; anything
 * else is a test failure. */
uint64_t trap_dispatch(uint64_t mcause, uint64_t mepc)
{
    if (mcause == 8 || mcause == 11) {
        ecall_count++;
        if (flag == 2) {
            uart_puts("debug_target: <<PASS>>\n");
            park_forever();
        }
        return mepc + 4;
    }
    uart_printf("debug_target: unexpected trap mcause=%lx mepc=%lx\n",
                (unsigned long) mcause,
                (unsigned long) mepc);
    uart_puts("<<FAIL>>\n");
    park_forever();
    return mepc;
}

int main(void)
{
    csr_write(mtvec, (uintptr_t) trap_entry);
    /* A volatile read keeps `table` referenced (gc-sections would otherwise
     * drop the section only the debugger reads). */
    counter = table[0] & 0;
    uart_puts("debug_target: start\n");

    /* Phase M: loop until the debugger asks for phase U. */
    while (flag != 1) {
        counter++;
        bp_target();
    }
    uart_puts("debug_target: phase U\n");

    /* Phase U: mret into the user-mode loop (MPP = U); never returns. */
    uint64_t mstatus = csr_read(mstatus);
    mstatus &= ~(3ULL << 11); /* MPP = U */
    csr_write(mstatus, mstatus);
    csr_write(mepc, (uintptr_t) u_loop);
    __asm__ volatile("mret");
    park_forever();
    return 0;
}
