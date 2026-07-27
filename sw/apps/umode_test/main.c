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
 * U-mode (User privilege) directed test.
 *
 * Exercises the Machine+User privilege support end-to-end on the real core and
 * self-checks over UART (<<PASS>> / <<FAIL>>):
 *
 *   A. ECALL from U-mode            -> mcause = 8  (ExcEcallUmode; 11 is M-mode)
 *   B. Machine timer interrupt while in U-mode with mstatus.MIE = 0
 *                                   -> trap taken, mcause = 0x8000_0007.
 *      Proves machine interrupts fire while running below M regardless of MIE
 *      (so the timer can preempt user code) AND that the interrupt mcause
 *      carries the interrupt bit + code.
 *   C. Reading an M-mode CSR from U -> illegal instruction (mcause = 2).
 *      Requires the U-mode CSR-permission check. If that check is absent the
 *      trailing ECALL traps instead (mcause = 8), so the test FAILs cleanly
 *      rather than hanging.
 *   D. Executing MRET from U-mode   -> illegal instruction (mcause = 2).
 *      MRET is an M-mode-only instruction; the trailing ECALL is the cause-8
 *      fallback so the test FAILs (not hangs) if the check is absent.
 *   E-K. mcounteren gating of the Zicntr counter CSRs from U-mode, both
 *      polarities and per-bit: with a counter's enable bit set the U-mode
 *      read succeeds (first trap is the trailing ECALL, mcause = 8); with it
 *      clear the read is an illegal instruction (mcause = 2), including the
 *      high-half CSRs (cycleh shares the CY bit). Selectivity is proven by
 *      setting only some bits (TM-only allows time but still blocks cycle;
 *      each of CY/TM/IR is exercised blocked while the others are set).
 *   L. mcounteren is WARL: only CY/TM/IR (bits [2:0]) are implemented; a
 *      write of all-ones reads back as 0x7 (also exercises the csrrs RMW
 *      current-value path).
 *   M. M-mode counter reads are never gated (mcounteren scopes the
 *      next-lower privilege only), even with mcounteren = 0.
 *
 * Mechanism: each case drops to U-mode via MRET (mstatus.MPP = U) into a small
 * naked U-mode function that triggers the trap. A naked M-mode handler records
 * mcause and the privilege the trap came from (mstatus.MPP), pushes mtimecmp to
 * max so a timer interrupt cannot refire, and returns to M-mode at a fixed
 * continuation address stashed in mscratch (forcing MPP=M for its MRET).
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
static volatile uint32_t g_from_priv; /* mstatus.MPP at trap entry = prev priv */

/*
 * Naked M-mode trap handler. Records mcause and the trapping privilege, pushes
 * mtimecmp to max (so a timer interrupt cannot refire), then returns to M-mode
 * at the continuation address run_in_umode stashed in mscratch. Forces MPP=M so
 * the MRET lands back in M-mode. Bouncing to a fixed continuation (rather than
 * resuming the U-mode code) means clobbering temporaries here is safe.
 */
__attribute__((naked, aligned(4))) static void umode_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "lui  t1, %hi(g_cause)\n"
                     "lw   t2, %lo(g_cause)(t1)\n"
                     "li   t3, -1\n" /* sentinel: only the FIRST trap of each test records */
                     "bne  t2, t3, 2f\n"
                     "sw   t0, %lo(g_cause)(t1)\n"
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
 * Enter U-mode at ufn; the handler returns control to the instruction after the
 * MRET. Returns the mcause of the trap that ended U-mode execution.
 */
static uint32_t run_in_umode(void (*ufn)(void))
{
    g_cause = 0xFFFFFFFFu;
    g_from_priv = 0xFFFFFFFFu;
    /* Clobbers cover every temporary the U-mode bodies AND the trap handler
     * may leave dirty at the continuation (the handler writes t0-t3 and never
     * restores; u_read_counters uses t0-t5). */
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n" /* where the handler returns */
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n" /* MPP = U (00) */
                     "csrw mepc, %0\n"
                     "mret\n" /* -> U-mode at ufn */
                     "1:\n"
                     :
                     : "r"(ufn)
                     : "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory");
    return g_cause;
}

/* ---- U-mode test bodies (naked: no prologue, so a mid-loop trap leaves the
 *      M-mode stack frame intact). Each spins after its trapping instruction. */
__attribute__((naked)) static void u_ecall(void)
{
    __asm__ volatile("ecall\n j .");
}

__attribute__((naked)) static void u_spin(void)
{
    __asm__ volatile("j .");
}

__attribute__((naked)) static void u_read_mcsr(void)
{
    /* csrr of an M-CSR is illegal from U (cause 2); the ecall is the
     * cause-8 fallback so the test FAILs (not hangs) if the check is absent. */
    __asm__ volatile("csrr t0, mstatus\n ecall\n j .");
}

__attribute__((naked)) static void u_mret_umode(void)
{
    /* MRET is an M-mode-only instruction; executing it from U is illegal
     * (cause 2). The ecall is the cause-8 fallback so the test FAILs (not
     * hangs) if the check is absent. */
    __asm__ volatile("mret\n ecall\n j .");
}

__attribute__((naked)) static void u_read_counters(void)
{
    /* With all mcounteren bits set these six reads are legal from U, so the
     * first trap is the ecall (cause 8). A cause-2 trap here means the gate
     * fired while enabled. */
    __asm__ volatile("csrr t0, cycle\n"
                     "csrr t1, cycleh\n"
                     "csrr t2, time\n"
                     "csrr t3, timeh\n"
                     "csrr t4, instret\n"
                     "csrr t5, instreth\n"
                     "ecall\n j .");
}

/* Each single-counter body reads one Zicntr CSR: illegal (cause 2) from U
 * when its mcounteren bit is clear, and falls through to the cause-8 ecall
 * when the bit is set — so one body serves both polarities and a missing
 * gate FAILs cleanly rather than hanging. */
__attribute__((naked)) static void u_read_cycle(void)
{
    __asm__ volatile("csrr t0, cycle\n ecall\n j .");
}

__attribute__((naked)) static void u_read_time(void)
{
    __asm__ volatile("csrr t0, time\n ecall\n j .");
}

__attribute__((naked)) static void u_read_instret(void)
{
    __asm__ volatile("csrr t0, instret\n ecall\n j .");
}

__attribute__((naked)) static void u_read_cycleh(void)
{
    __asm__ volatile("csrr t0, cycleh\n ecall\n j .");
}

static int report(const char *name, uint32_t got, uint32_t want, uint32_t from_priv)
{
    int ok = (got == want) && (from_priv == 0u /* U */);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" mcause=");
    uart_hex(got);
    uart_puts(" from_priv=");
    uart_hex(from_priv);
    uart_puts("\r\n");
    return ok;
}

int main(void)
{
    int all_ok = 1;
    uint32_t cause;

    uart_puts("\r\n=== U-mode privilege test ===\r\n");
    set_trap_handler(&umode_trap_handler);

    /* A: ECALL from U-mode -> mcause 8 */
    cause = run_in_umode(&u_ecall);
    all_ok &= report("A ecall-from-U (want mcause=8)", cause, 8u, g_from_priv);

    /* B: timer preempts U-mode with MIE=0 -> mcause 0x8000_0007 */
    (void) disable_interrupts();      /* MIE = 0 */
    csr_clear(mstatus, MSTATUS_MPIE); /* so U runs with MIE=0 as well */
    enable_timer_interrupt();         /* mie.MTIE = 1 */
    set_timer_cmp(rdmtime() + 300);
    cause = run_in_umode(&u_spin);
    all_ok &=
        report("B timer-preempts-U (want mcause=0x80000007)", cause, 0x80000007u, g_from_priv);
    disable_timer_interrupt();

    /* C: M-mode CSR read from U -> illegal (mcause 2) */
    cause = run_in_umode(&u_read_mcsr);
    all_ok &= report("C M-CSR-from-U (want mcause=2)", cause, 2u, g_from_priv);

    /* D: MRET from U -> illegal (mcause 2) */
    cause = run_in_umode(&u_mret_umode);
    all_ok &= report("D mret-from-U (want mcause=2)", cause, 2u, g_from_priv);

    /* E: mcounteren=0x7 (the reset value, written explicitly): all six
     * counter CSRs are U-readable; the first trap is the trailing ecall */
    csr_write(mcounteren, 0x7u);
    cause = run_in_umode(&u_read_counters);
    all_ok &= report("E counters-enabled-from-U (want mcause=8)", cause, 8u, g_from_priv);

    /* F: mcounteren=0: rdcycle from U -> illegal */
    csr_write(mcounteren, 0x0u);
    cause = run_in_umode(&u_read_cycle);
    all_ok &= report("F cycle-gated-from-U (want mcause=2)", cause, 2u, g_from_priv);

    /* G: TM only (0x2): rdtime from U succeeds — per-bit gating, not blanket */
    csr_write(mcounteren, 0x2u);
    cause = run_in_umode(&u_read_time);
    all_ok &= report("G time-enabled-tm-only (want mcause=8)", cause, 8u, g_from_priv);

    /* H: TM only (0x2): rdcycle from U still illegal (CY clear, TM set) */
    cause = run_in_umode(&u_read_cycle);
    all_ok &= report("H cycle-gated-tm-only (want mcause=2)", cause, 2u, g_from_priv);

    /* I: CY|TM (0x3): rdinstret from U -> illegal (IR clear) */
    csr_write(mcounteren, 0x3u);
    cause = run_in_umode(&u_read_instret);
    all_ok &= report("I instret-gated-from-U (want mcause=2)", cause, 2u, g_from_priv);

    /* J: CY|IR (0x5): rdtime from U -> illegal (TM clear) */
    csr_write(mcounteren, 0x5u);
    cause = run_in_umode(&u_read_time);
    all_ok &= report("J time-gated-from-U (want mcause=2)", cause, 2u, g_from_priv);

    /* K: mcounteren=0: cycleh gated by the same CY bit as cycle */
    csr_write(mcounteren, 0x0u);
    cause = run_in_umode(&u_read_cycleh);
    all_ok &= report("K cycleh-gated-from-U (want mcause=2)", cause, 2u, g_from_priv);

    /* L: WARL — only CY/TM/IR exist; all-ones reads back as 0x7. The csrs
     * exercises the RMW current-value path. */
    csr_write(mcounteren, 0xFFFFFFFFu);
    uint32_t warl = csr_read(mcounteren);
    csr_write(mcounteren, 0x0u);
    uint32_t zeroed = csr_read(mcounteren);
    csr_set(mcounteren, 0x1u);
    uint32_t rmw = csr_read(mcounteren);
    int warl_ok = (warl == 0x7u) && (zeroed == 0x0u) && (rmw == 0x1u);
    uart_puts(warl_ok ? "[PASS] " : "[FAIL] ");
    uart_puts("L mcounteren-warl got=");
    uart_hex(warl);
    uart_putc(' ');
    uart_hex(zeroed);
    uart_putc(' ');
    uart_hex(rmw);
    uart_puts(" (want 0x7 0x0 0x1)\r\n");
    all_ok &= warl_ok;

    /* M: M-mode counter reads are never gated, even with mcounteren=0. A
     * trap here would bounce to the label below with g_cause recorded. */
    csr_write(mcounteren, 0x0u);
    g_cause = 0xFFFFFFFFu;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n" /* trap (if any) bounces to 1f */
                     "csrr t0, cycle\n"
                     "csrr t0, time\n"
                     "csrr t0, instret\n"
                     "1:\n" ::
                         : "t0", "memory");
    int m_ok = (g_cause == 0xFFFFFFFFu);
    uart_puts(m_ok ? "[PASS] " : "[FAIL] ");
    uart_puts("M M-reads-ungated mcause=");
    uart_hex(g_cause);
    uart_puts(" (want no trap)\r\n");
    all_ok &= m_ok;

    /* Restore the reset value for whatever runs after us. */
    csr_write(mcounteren, 0x7u);

    uart_puts(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
