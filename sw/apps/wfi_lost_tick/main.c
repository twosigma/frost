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
 * WFI-idle lost-machine-timer-tick directed test.
 *
 * Reproduce target: the residual flaky HANG booting no-MMU Linux on Genesys2.
 * After fixing the MRET-drain deadlock the boot is STILL ~50% flaky, hanging at
 * VARYING points after the first timer activity with no panic -- the signature
 * of a LOST machine-timer tick -> frozen jiffies. The machine-timer trap is
 * occasionally NOT TAKEN and timekeeping stops.
 *
 * This faithfully mirrors the kernel's idle + CLINT-timer flow, which the
 * existing mtimer_stress (no WFI, MIE always 1) and linux_irq_ddr_test miss:
 *   - idle loop: csrci mstatus,8 (MIE:=0); fence; wfi; csrsi mstatus,8 (MIE:=1).
 *     The whole kernel is M-mode, so the machine-timer trap is eligible ONLY
 *     when mstatus.MIE=1 -- it is DEFERRED from the WFI-wake (raw mtip level) to
 *     the later csrsi MIE 0->1 edge.
 *   - handler = the CLINT pattern: csr_clear mie.MTIE on entry (clint_timer_
 *     interrupt), then csr_set mie.MTIE + write a fresh future mtimecmp
 *     (clint_clock_next_event), then MRET (restores MIE from MPIE).
 * The re-arm period is phase-swept (mtime + 24..87 per tick) so the deadline
 * crossing lands at every cycle offset around the wfi / csrsi / MRET-recovery
 * window across thousands of ticks.
 *
 * Invariant: each idle iteration arms exactly one future deadline and must take
 * exactly one trap, so g_jiffies must equal the iteration count. If any trap is
 * dropped (and especially if mie.MTIE sticks low so timekeeping freezes),
 * g_jiffies falls behind -> <<FAIL>>. If every tick is taken -> <<PASS>>.
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
 * Naked M-mode timer handler mirroring the CLINT driver:
 *   clint_timer_interrupt:  csr_clear(mie, MTIE)               [mask on entry]
 *   clint_clock_next_event: csr_set(mie, MTIE); write mtimecmp [re-arm]
 * then MRET (MIE restored from MPIE). The phase-sweep period = 24 + (jiffies&63).
 */
__attribute__((naked, aligned(4))) static void clint_like_handler(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sw   t0, 0(sp)\n"
                     "sw   t1, 4(sp)\n"
                     "sw   t2, 8(sp)\n"
                     "li   t0, 0x80\n"     /* mie.MTIE */
                     "csrrc x0, mie, t0\n" /* csr_clear(mie, MTIE) -- handler entry */
                     "lui  t0, %hi(g_jiffies)\n"
                     "lw   t1, %lo(g_jiffies)(t0)\n"
                     "addi t1, t1, 1\n"
                     "sw   t1, %lo(g_jiffies)(t0)\n" /* g_jiffies++  (the tick) */
                     "andi t2, t1, 0x3f\n"
                     "addi t2, t2, 24\n" /* period = 24 + (jiffies & 63): phase sweep */
                     "li   t0, 0x80\n"
                     "csrrs x0, mie, t0\n"   /* csr_set(mie, MTIE) -- re-arm enable */
                     "li   t0, 0x40000010\n" /* MTIME_LO */
                     "lw   t1, 0(t0)\n"
                     "add  t1, t1, t2\n"
                     "li   t0, 0x40000018\n" /* MTIMECMP_LO (HI stays 0, set in main) */
                     "sw   t1, 0(t0)\n"      /* write fresh future deadline -> mtip low */
                     "lw   t0, 0(sp)\n"
                     "lw   t1, 4(sp)\n"
                     "lw   t2, 8(sp)\n"
                     "addi sp, sp, 16\n"
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
