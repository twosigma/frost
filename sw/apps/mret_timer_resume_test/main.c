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
 * MRET-to-U-mode + already-pending machine timer: interrupt-resume-PC (mepc)
 * directed test.
 *
 * Reproduces the Linux no-MMU boot panic where a U-mode context illegally
 * executes the kernel's M-mode MRET (ret_from_exception). Root cause under
 * test: when an MRET returns to U-mode it retires via the trap/MRET full
 * flush, NOT via the normal commit path, so the core's `interrupt_resume_pc`
 * register is never updated to the MRET target. It keeps holding the
 * architectural next-PC of the instruction before the MRET -- i.e. the MRET
 * instruction's own PC. The trap unit only inhibits interrupts for the two
 * cycles around the MRET (i_mret_start, mret_taken_prev). If a machine timer
 * is pending, it becomes eligible the moment privilege drops below M and is
 * taken a few cycles later, BEFORE the first U-mode instruction commits and
 * refreshes interrupt_resume_pc. The trap therefore saves
 *   mepc = interrupt_resume_pc = <MRET instruction PC>.
 * Linux later restores that trap frame and MRETs to the kernel MRET PC while
 * in U-mode -> illegal instruction (signal 4) -> "Attempted to kill init".
 *
 * Test shape (mirrors umode_test's timer-preempts-U case, but with the timer
 * ALREADY pending at MRET time so it fires in the vulnerable post-MRET
 * window):
 *
 *   1. M-mode installs a naked handler at mtvec that records, for the FIRST
 *      trap only, mcause, mepc (the saved resume PC) and mstatus.MPP.
 *   2. Make the machine timer permanently pending (mtimecmp = 0) while in
 *      M-mode with MIE=0 (so it cannot fire in M-mode).
 *   3. MRET into a tiny U-mode spin (`u_spin: j .`). Machine interrupts are
 *      taken below M regardless of MIE, so the pending timer preempts U
 *      immediately.
 *   4. The handler runs; we then assert the saved resume PC points at u_spin
 *      (the MRET target) and is NOT the MRET instruction's own PC.
 *
 * PASS: mcause == 0x8000_0007 (machine timer), trapped-from-priv == U, and
 *       mepc == &u_spin.
 * FAIL (the bug): mepc == <MRET PC in run_in_umode_pending_timer> != &u_spin.
 */

#include <stdint.h>

#include "trap.h"

/* ---- minimal UART (UART_TX is provided by mmio.h via trap.h) ---- */
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

/* ---- trap state shared with the naked handler ---- */
static volatile uint32_t g_cause;
static volatile uint32_t g_mepc;      /* saved resume PC of the FIRST trap     */
static volatile uint32_t g_from_priv; /* mstatus.MPP at trap entry = prev priv */

/*
 * Naked M-mode trap handler. For the first trap only, records mcause, mepc and
 * the trapping privilege (mstatus.MPP). Then pushes mtimecmp to max (acks the
 * timer so it cannot refire), and returns to M-mode at the continuation
 * address stashed in mscratch with MPP=M. Bouncing to a fixed continuation
 * (rather than resuming U-mode) means clobbering temporaries here is safe.
 */
__attribute__((naked, aligned(4))) static void mret_timer_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "lui  t1, %hi(g_cause)\n"
                     "lw   t2, %lo(g_cause)(t1)\n"
                     "li   t3, -1\n" /* sentinel: only the FIRST trap records */
                     "bne  t2, t3, 2f\n"
                     "sw   t0, %lo(g_cause)(t1)\n"
                     "csrr t0, mepc\n" /* saved resume PC of this trap */
                     "lui  t1, %hi(g_mepc)\n"
                     "sw   t0, %lo(g_mepc)(t1)\n"
                     "csrr t0, mstatus\n"
                     "srli t0, t0, 11\n"
                     "andi t0, t0, 0x3\n" /* mstatus.MPP */
                     "lui  t1, %hi(g_from_priv)\n"
                     "sw   t0, %lo(g_from_priv)(t1)\n"
                     "2:\n"
                     "li   t1, 0x4000001C\n" /* MTIMECMP_HI: push compare to max to ack timer */
                     "li   t0, -1\n"
                     "sw   t0, 0(t1)\n"
                     "csrr t0, mscratch\n" /* M-mode continuation set by run_in_umode */
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n" /* MPP = M (0b11 << 11) */
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/*
 * Enter U-mode at ufn with the machine timer ALREADY pending; the handler
 * returns control to the instruction after the MRET. The MRET here is the
 * instruction whose PC must NOT leak into the timer trap's mepc.
 */
static uint32_t run_in_umode_pending_timer(void (*ufn)(void))
{
    g_cause = 0xFFFFFFFFu;
    g_mepc = 0u;
    g_from_priv = 0xFFFFFFFFu;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n" /* where the handler returns */
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n" /* MPP = U (00) */
                     "csrw mepc, %0\n"
                     "mret\n" /* -> U-mode at ufn; pending timer preempts here */
                     "1:\n"
                     :
                     : "r"(ufn)
                     : "t0", "t1", "t2", "memory");
    return g_cause;
}

/* U-mode body: spin in place. naked so its first (and only) instruction is the
 * jump, making the architectural resume PC of any preempting interrupt exactly
 * &u_spin. */
__attribute__((naked)) static void u_spin(void)
{
    __asm__ volatile("j .");
}

int main(void)
{
    uart_puts("\r\n=== MRET->U timer-resume mepc test ===\r\n");
    set_trap_handler(&mret_timer_trap_handler);

    /* Machine interrupts off in M (MIE=0), and MPIE=0 so U also runs with
     * MIE=0. The machine timer still preempts U-mode (priv != M). */
    (void) disable_interrupts();
    csr_clear(mstatus, MSTATUS_MPIE);
    enable_timer_interrupt(); /* mie.MTIE = 1 */

    /* Make the machine timer permanently pending BEFORE the MRET-to-U so it
     * preempts at the first eligible cycle after privilege drops to U -- the
     * window in which interrupt_resume_pc may still hold the MRET's own PC. */
    set_timer_cmp(0); /* mtime >= 0 always => MTIP asserted */

    uint32_t cause = run_in_umode_pending_timer(&u_spin);
    disable_timer_interrupt();

    uint32_t mepc = g_mepc;
    uint32_t want_pc = (uint32_t) &u_spin;
    int ok = (cause == 0x80000007u) && (g_from_priv == 0u) && (mepc == want_pc);

    uart_puts("cause=");
    uart_hex(cause);
    uart_puts(" from_priv=");
    uart_hex(g_from_priv);
    uart_puts(" resume_mepc=");
    uart_hex(mepc);
    uart_puts(" want_pc(u_spin)=");
    uart_hex(want_pc);
    uart_puts("\r\n");

    if (!ok) {
        uart_puts("[FAIL] timer trap saved a wrong resume PC "
                  "(stale interrupt_resume_pc around MRET-to-U)\r\n");
    } else {
        uart_puts("[PASS] timer trap resumed at the U-mode target\r\n");
    }

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
