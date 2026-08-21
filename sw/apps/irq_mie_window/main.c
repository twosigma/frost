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
 * Short-MIE-window lost-interrupt regression.
 *
 * The bug sampled an eligible interrupt, then rechecked live MIE one cycle
 * later. An adjacent `csrsi mstatus,8; csrci mstatus,8` could therefore erase an
 * interrupt already eligible at the boundary after csrsi, causing lost Linux
 * timer ticks.
 *
 * Hold mtip pending with mtimecmp=0 and mie.MTIE=1, then pulse mstatus.MIE for
 * one cycle. A correct core traps on the first pulse; PASS requires g_taken>0.
 */

#include <stdint.h>

#include "trap.h"

#define PULSES 256u

volatile uint32_t g_taken; /* timer-trap count */

static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}
static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}
static void uart_hex(uint32_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

/* Naked handler: count the trap, ack the timer (push mtimecmp_hi to max so mtip
 * drops and it cannot re-fire), MRET. */
__attribute__((naked, aligned(4))) static void timer_handler(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     /* la (auipc-based under medany): absolute lui %hi cannot
                      * materialize the ddr build's 0x8xxx_xxxx data addresses
                      * at lp64. */
                     "la   t0, g_taken\n"
                     "lw   t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"
                     "li   t0, 0x4000001C\n" /* MTIMECMP_HI */
                     "li   t1, -1\n"
                     "sw   t1, 0(t0)\n" /* mtimecmp = huge -> mtip low (ack) */
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "addi sp, sp, 16\n"
                     "mret\n");
}

int main(void)
{
    uart_puts("\r\n=== short-MIE-window lost-interrupt test ===\r\n");
    set_trap_handler(&timer_handler);
    g_taken = 0;

    /* Machine timer permanently pending (mtime >= 0 always), MTIE enabled,
     * mstatus.MIE left 0 -- pending but masked. */
    MTIMECMP_HI = 0;
    MTIMECMP_LO = 0;
    enable_timer_interrupt(); /* mie.MTIE = 1 */

    /* Pulse mstatus.MIE high for a single cycle, repeatedly. Each csrsi makes the
     * pending timer eligible at the very next instruction boundary; the adjacent
     * csrci must NOT be able to retroactively cancel it. */
    for (uint32_t i = 0; i < PULSES; i++) {
        __asm__ volatile("csrsi mstatus, 8\n" /* mstatus.MIE = 1 (1-cycle window) */
                         "csrci mstatus, 8\n" /* mstatus.MIE = 0 */
                         ::
                             : "memory");
        if (g_taken)
            break; /* taken once -> correct; acked, no point continuing */
    }

    disable_timer_interrupt();
    uart_puts("taken=");
    uart_hex(g_taken);
    uart_puts("\r\n");
    if (g_taken >= 1u) {
        uart_puts("<<PASS>>\r\n");
    } else {
        uart_puts("[FAIL] eligible machine timer was erased by the adjacent MIE clear "
                  "(never taken)\r\n<<FAIL>>\r\n");
    }
    for (;;) {
    }
    return 0;
}
