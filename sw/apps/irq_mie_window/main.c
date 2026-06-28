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
 * Short-MIE-window lost-interrupt directed test.
 *
 * Root cause under test (trap_unit.sv): interrupt_pending is sampled from
 * (mtip && mie.MTIE && mstatus.MIE) into a 1-cycle-late flop, and
 * interrupt_pending_eligible then RE-CHECKS the LIVE mstatus.MIE/mie.MTIE when
 * the sample matures. So a machine interrupt is only taken if the enable is high
 * for TWO consecutive cycles (sample + service). A legal SHORT MIE-enable window
 * -- e.g. `csrsi mstatus,8` immediately followed by `csrci mstatus,8` -- gets
 * its already-qualified interrupt ERASED: the registered pending bit matures one
 * cycle after csrsi, but the csrci's (delayed) side-effect has already driven
 * mstatus.MIE back to 0, so interrupt_pending_eligible=0 and the pending bit is
 * cleared without ever being serviced. Per RISC-V the interrupt MUST be taken at
 * the instruction boundary right after the csrsi (before the csrci), so this is
 * a dropped interrupt. On the real no-MMU kernel this is the lost machine-timer
 * tick -> frozen jiffies -> boot hang (the same drop, usually opened by the trap
 * being delayed a cycle by a draining store rather than a literal adjacent
 * csrci).
 *
 * Setup: make the machine timer permanently pending (mtimecmp=0 => mtip high),
 * enable mie.MTIE, leave mstatus.MIE=0. Then pulse MIE high for one cycle
 * (csrsi; csrci) many times. A correct core takes the timer at the first pulse
 * (the handler acks it); a buggy core erases it every pulse and never traps.
 *
 * PASS: g_taken >= 1 (the eligible timer was taken).
 * FAIL: g_taken == 0 (the timer was eligible at every csrsi but never taken).
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
    __asm__ volatile("addi sp, sp, -8\n"
                     "sw   t0, 0(sp)\n"
                     "sw   t1, 4(sp)\n"
                     "lui  t0, %hi(g_taken)\n"
                     "lw   t1, %lo(g_taken)(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, %lo(g_taken)(t0)\n"
                     "li   t0, 0x4000001C\n" /* MTIMECMP_HI */
                     "li   t1, -1\n"
                     "sw   t1, 0(t0)\n" /* mtimecmp = huge -> mtip low (ack) */
                     "lw   t0, 0(sp)\n"
                     "lw   t1, 4(sp)\n"
                     "addi sp, sp, 8\n"
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
