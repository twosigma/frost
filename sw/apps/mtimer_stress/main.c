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
 * Machine-timer/MRET deadlock stress for the no-MMU Linux boot hang.
 *
 * A frequently preempted M-mode loop and real MRET return reduce linux_boot to
 * its trap/flush core. Re-arming at mtime + 512..575 sweeps timer phase across
 * the loop and MRET. A deadlock stops progress and the harness times out before
 * <<PASS>>.
 */

#include <stdint.h>

#include "trap.h"

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

volatile uint32_t g_irq;  /* timer-interrupt count (also drives the phase sweep) */
volatile uint32_t g_loop; /* loop progress marker */
static volatile uint32_t buf[64];

/*
 * Re-arm for 512 + (g_irq & 0x3f) cycles, increment g_irq, and MRET. Trap entry
 * clears MIE and MRET restores it from MPIE. Only touched registers are saved.
 *
 * The period must exceed the ~90-cycle trap round trip. An earlier 24..87 range
 * kept the timer overdue and starved main despite continued retirement. 512
 * preserves foreground progress while sweeping phase.
 */
__attribute__((naked, aligned(4))) static void mtimer_handler(void)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "sd   t2, 16(sp)\n"
                     /* la (auipc-based under medany): absolute lui %hi cannot
                      * materialize the ddr build's 0x8xxx_xxxx data addresses
                      * at lp64. */
                     "la   t0, g_irq\n"
                     "lw   t1, 0(t0)\n"
                     "andi t2, t1, 0x3f\n"
                     "addi t2, t2, 512\n" /* period = 512 + (g_irq & 0x3f) */
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n"      /* g_irq++ */
                     "li   t0, 0x40000010\n" /* MTIME_LO */
                     "lw   t1, 0(t0)\n"
                     "add  t1, t1, t2\n"
                     "li   t0, 0x40000018\n" /* MTIMECMP_LO (HI stays 0, set in main) */
                     "sw   t1, 0(t0)\n"
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "ld   t2, 16(sp)\n"
                     "addi sp, sp, 32\n"
                     "mret\n");
}

int main(void)
{
    uart_puts("\r\n=== mtimer MRET deadlock stress ===\r\n");
    set_trap_handler(&mtimer_handler);
    for (int i = 0; i < 64; i++)
        buf[i] = (uint32_t) i;

    /* Arm a frequent machine timer. The handler re-arms it each tick, which is
     * what sweeps the phase. */
    MTIMECMP_HI = 0;
    MTIMECMP_LO = (uint32_t) rdmtime() + 40;
    enable_timer_interrupt(); /* mie.MTIE */
    enable_interrupts();      /* mstatus.MIE */

    /* Loop with loads/stores/ALU so the timer preempts varied pipeline state
     * (in-flight memory ops, branches) at every swept phase. */
    uint32_t acc = 0;
    for (uint32_t i = 0; i < 20000u; i++) {
        g_loop = i;
        uint32_t k = i & 63u;
        acc += buf[k];
        acc ^= (acc << 1) | (acc >> 3);
        buf[k] = acc + i;
    }

    disable_timer_interrupt();
    uart_puts("survived: loop=");
    uart_hex(g_loop);
    uart_puts(" irqs=");
    uart_hex(g_irq);
    uart_puts(" acc=");
    uart_hex(acc);
    uart_puts("\r\n<<PASS>>\r\n");
    for (;;) {
    }
    return 0;
}
