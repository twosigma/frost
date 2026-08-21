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
 * MRET-to-U-mode interrupt-resume-PC regression.
 *
 * The bug left interrupt_resume_pc at the MRET instruction because MRET uses a
 * full-flush path rather than normal commit. A timer already pending when
 * privilege dropped to U could trap before the first U instruction committed,
 * save that stale PC in mepc, and later make U-mode execute the kernel's MRET.
 *
 * With MIE clear, set mtimecmp=0 and MRET into `u_spin`. The first trap records
 * mcause, mepc, and MPP. PASS requires mcause=(1<<63)|7, MPP=U, and
 * mepc=&u_spin; the bug records the MRET PC instead.
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
static volatile unsigned long g_cause; /* full XLEN mcause */
static volatile uint32_t g_mepc;       /* saved resume PC of the FIRST trap     */
static volatile uint32_t g_from_priv;  /* mstatus.MPP at trap entry = prev priv */

/*
 * Record the first trap, disarm mtimecmp, and return in M-mode to the mscratch
 * continuation. The fixed continuation permits clobbering temporaries.
 */
__attribute__((naked, aligned(4))) static void mret_timer_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     /* la (auipc-based under medany): absolute lui %hi cannot
                      * materialize the ddr build's 0x8xxx_xxxx data addresses
                      * at lp64. */
                     "la   t1, g_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n" /* sentinel: only the FIRST trap records */
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n" /* saved resume PC of this trap */
                     "la   t1, g_mepc\n"
                     "sw   t0, 0(t1)\n"
                     "csrr t0, mstatus\n"
                     "srli t0, t0, 11\n"
                     "andi t0, t0, 0x3\n" /* mstatus.MPP */
                     "la   t1, g_from_priv\n"
                     "sw   t0, 0(t1)\n"
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
static unsigned long run_in_umode_pending_timer(void (*ufn)(void))
{
    g_cause = ~0ul; /* all-ones sentinel (handler compares -1 at XLEN) */
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
                     /* covers the trap handler's clobbers too: it fires inside
                      * this block and bounces back to the label above */
                     : "t0", "t1", "t2", "t3", "memory");
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

    unsigned long cause = run_in_umode_pending_timer(&u_spin);
    disable_timer_interrupt();

    uint32_t mepc = g_mepc;
    uint32_t want_pc = (uint32_t) &u_spin;
    int ok = (cause == ((1ul << 63) | 7u)) /* MTI: interrupt bit at XLEN-1 */
             && (g_from_priv == 0u) && (mepc == want_pc);

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
