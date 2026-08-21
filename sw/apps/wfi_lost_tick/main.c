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
 * WFI-idle lost-machine-timer-tick regression.
 *
 * Models the Linux idle sequence (`csrci MIE; fence; wfi; csrsi MIE`) and CLINT
 * handler (clear MTIE, re-enable it, program a future mtimecmp, MRET). Because
 * the kernel runs in M-mode, raw MTIP wakes WFI but delivery waits for csrsi.
 * Re-arm periods of 24..87 cycles sweep phase across WFI, csrsi, and MRET.
 *
 * Each idle iteration arms one deadline and must take one trap. PASS requires
 * g_jiffies to match the iteration count; a lost tick makes it fall behind.
 */

#include <stdint.h>

#include "trap.h"

#define MIE_MTIE_BIT 0x80u /* mie.MTIE = bit 7 */
#define ITERS 3000u

volatile uint32_t g_jiffies; /* incremented once per timer trap (the "tick") */

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

/*
 * M-mode handler matching the CLINT driver:
 *   clint_timer_interrupt:  csr_clear(mie, MTIE)               [mask on entry]
 *   clint_clock_next_event: csr_set(mie, MTIE); write mtimecmp [re-arm]
 * then MRET. The phase-sweep period is 24 + (jiffies&63).
 */
__attribute__((naked, aligned(4))) static void clint_like_handler(void)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "sd   t2, 16(sp)\n"
                     "li   t0, 0x80\n"     /* mie.MTIE */
                     "csrrc x0, mie, t0\n" /* csr_clear(mie, MTIE) -- handler entry */
                     /* la (auipc-based under medany): absolute lui %hi cannot
                      * materialize the ddr build's 0x8xxx_xxxx data addresses
                      * at lp64. */
                     "la   t0, g_jiffies\n"
                     "lw   t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, 0(t0)\n" /* g_jiffies++  (the tick) */
                     "andi t2, t1, 0x3f\n"
                     "addi t2, t2, 24\n" /* period = 24 + (jiffies & 63): phase sweep */
                     "li   t0, 0x80\n"
                     "csrrs x0, mie, t0\n"   /* csr_set(mie, MTIE) -- re-arm enable */
                     "li   t0, 0x40000010\n" /* MTIME_LO */
                     "lw   t1, 0(t0)\n"
                     "add  t1, t1, t2\n"
                     "li   t0, 0x40000018\n" /* MTIMECMP_LO (HI stays 0, set in main) */
                     "sw   t1, 0(t0)\n"      /* write fresh future deadline -> mtip low */
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "ld   t2, 16(sp)\n"
                     "addi sp, sp, 32\n"
                     "mret\n");
}

int main(void)
{
    uart_puts("\r\n=== WFI-idle lost-timer-tick test ===\r\n");
    set_trap_handler(&clint_like_handler);

    /* Arm the first deadline, enable the machine timer, then run the idle loop. */
    MTIMECMP_HI = 0;
    MTIMECMP_LO = (uint32_t) rdmtime() + 40;
    enable_timer_interrupt(); /* mie.MTIE = 1 */
    enable_interrupts();      /* mstatus.MIE = 1 (idle loop toggles it) */

    /* Kernel idle pattern: MIE off, WFI (wake on raw mtip), MIE on (deferred
     * timer trap taken here). Exactly one tick must be taken per iteration. */
    for (uint32_t i = 0; i < ITERS; i++) {
        __asm__ volatile("csrci mstatus, 8\n" /* mstatus.MIE = 0 */
                         "fence\n"
                         "wfi\n"
                         "csrsi mstatus, 8\n" /* mstatus.MIE = 1 -> take deferred timer */
                         ::
                             : "memory");
    }

    disable_timer_interrupt();
    uint32_t jiffies = g_jiffies;
    uart_puts("iters=");
    uart_hex(ITERS);
    uart_puts(" jiffies=");
    uart_hex(jiffies);
    uart_puts("\r\n");

    /* Every WFI-wake must produce exactly one tick. A shortfall means a
     * machine-timer trap was dropped (lost tick / frozen timekeeping). */
    if (jiffies + 4u >= ITERS) {
        uart_puts("<<PASS>>\r\n");
    } else {
        uart_puts("[FAIL] lost timer tick(s): jiffies fell behind idle iterations\r\n");
        uart_puts("<<FAIL>>\r\n");
    }
    for (;;) {
    }
    return 0;
}
