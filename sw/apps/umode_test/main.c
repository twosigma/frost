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
 * U-mode privilege and counter-access tests.
 *
 * Enter naked U-mode bodies through MRET. The M handler records the first
 * trap's mcause and MPP, postpones the timer, and returns to an mscratch
 * continuation with MPP=M. Counter tests leave scounteren at its reset
 * value, 0x7, so mcounteren alone controls U-mode access.
 */

#include <stdint.h>

#include "trap.h"

/* ---- UART ---- */
static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_hex(unsigned long v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = (int) (sizeof(unsigned long) * 8) - 4; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

/* ---- trap state shared with the naked handler ---- */
/* XLEN-wide: mcause carries the interrupt bit at bit XLEN-1, and the naked
 * handler records it with an XLEN-wide store (LREG/SREG below). */
static volatile unsigned long g_cause;
static volatile uint32_t g_from_priv; /* mstatus.MPP at trap entry = prev priv */

/* XLEN-natural load/store mnemonics for the naked-handler asm. */
#define LREG "ld"
#define SREG "sd"

/*
 * Record the first trap, postpone the timer and return to run_in_umode's
 * mscratch continuation with MPP=M. Temporary registers may be clobbered
 * because the handler resumes at that fixed continuation.
 */
__attribute__((naked, aligned(4))) static void umode_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     /* PC-relative la reaches DDR; RV64 lui sign-extends
                      * addresses in the 0x8xxx_xxxx range. */
                     "la   t1, g_cause\n" LREG " t2, 0(t1)\n"
                     "li   t3, -1\n" /* sentinel: only the first trap of each test records */
                     "bne  t2, t3, 2f\n" SREG " t0, 0(t1)\n"
                     "csrr t0, mstatus\n"
                     "srli t0, t0, 11\n"
                     "andi t0, t0, 0x3\n" /* mstatus.MPP */
                     "la   t1, g_from_priv\n"
                     "sw   t0, 0(t1)\n"
                     "2:\n"
                     "li   t1, 0x4000001C\n" /* MTIMECMP_HI: postpone the timer */
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
static unsigned long run_in_umode(void (*ufn)(void))
{
    g_cause = ~0ul; /* all-ones sentinel (handler compares -1) */
    g_from_priv = 0xFFFFFFFFu;
    /* Clobbers cover every temporary the U-mode bodies and the trap handler
     * may leave dirty at the continuation. The handler writes t0-t3 and never
     * restores them; u_read_counters uses t0-t5. */
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
    /* csrr of an M-CSR is illegal from U (cause 2). The ecall is the cause-8
     * fallback, so a missing check fails the test rather than hanging it. */
    __asm__ volatile("csrr t0, mstatus\n ecall\n j .");
}

__attribute__((naked)) static void u_mret_umode(void)
{
    /* MRET is illegal in U (cause 2). The trailing ecall is a fallback. */
    __asm__ volatile("mret\n ecall\n j .");
}

__attribute__((naked)) static void u_read_counters(void)
{
    /* RV64 counters use full-width CSRs. Their RV32 high-half addresses
     * are illegal regardless of mcounteren. */
    __asm__ volatile("csrr t0, cycle\n"
                     "csrr t2, time\n"
                     "csrr t4, instret\n"
                     "ecall\n j .");
}

/* With scounteren enabled, a clear mcounteren bit makes the U read illegal
 * (cause 2); a set bit lets it reach the trailing ecall (cause 8). */
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

static int report(const char *name, unsigned long got, unsigned long want, uint32_t from_priv)
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
    unsigned long cause;

    uart_puts("\r\n=== U-mode privilege test ===\r\n");
    set_trap_handler(&umode_trap_handler);

    /* A: ECALL from U-mode -> mcause 8 */
    cause = run_in_umode(&u_ecall);
    all_ok &= report("A ecall-from-U (want mcause=8)", cause, 8u, g_from_priv);

    /* B: timer preempts U-mode with MIE=0 -> mcause = interrupt bit | MTI
     * (bit 63: MCAUSE_INTERRUPT_BIT sits at XLEN-1) */
    (void) disable_interrupts();      /* MIE = 0 */
    csr_clear(mstatus, MSTATUS_MPIE); /* so U runs with MIE=0 as well */
    enable_timer_interrupt();         /* mie.MTIE = 1 */
    set_timer_cmp(rdmtime() + 300);
    cause = run_in_umode(&u_spin);
    all_ok &= report("B timer-preempts-U (want mcause=INT|MTI)",
                     cause,
                     MCAUSE_INTERRUPT_BIT | INT_MTI,
                     g_from_priv);
    disable_timer_interrupt();

    /* C: M-mode CSR read from U -> illegal (mcause 2) */
    cause = run_in_umode(&u_read_mcsr);
    all_ok &= report("C M-CSR-from-U (want mcause=2)", cause, 2u, g_from_priv);

    /* D: MRET from U -> illegal (mcause 2) */
    cause = run_in_umode(&u_mret_umode);
    all_ok &= report("D mret-from-U (want mcause=2)", cause, 2u, g_from_priv);

    /* E: mcounteren=0x7 (the reset value, written back here): the three
     * counter CSRs are U-readable, so the first trap is the trailing ecall */
    csr_write(mcounteren, 0x7u);
    cause = run_in_umode(&u_read_counters);
    all_ok &= report("E counters-enabled-from-U (want mcause=8)", cause, 8u, g_from_priv);

    /* F: mcounteren=0: rdcycle from U -> illegal */
    csr_write(mcounteren, 0x0u);
    cause = run_in_umode(&u_read_cycle);
    all_ok &= report("F cycle-gated-from-U (want mcause=2)", cause, 2u, g_from_priv);

    /* G: TM only (0x2): rdtime from U succeeds, so the gate is per bit */
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

    /* K (RV64): cycleh does not exist. It traps illegal at any privilege even
     * with every mcounteren bit set, which separates the unconditional *h
     * illegal from the gating that test F covers. */
    csr_write(mcounteren, 0x7u);
    cause = run_in_umode(&u_read_cycleh);
    all_ok &= report("K cycleh-illegal-at-rv64 (want mcause=2)", cause, 2u, g_from_priv);

    /* L: mcounteren is WARL. Only CY/TM/IR exist, so all-ones reads back as
     * 0x7. The csrs exercises the RMW current-value path. */
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
    g_cause = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n" /* trap (if any) bounces to 1f */
                     "csrr t0, cycle\n"
                     "csrr t0, time\n"
                     "csrr t0, instret\n"
                     "1:\n" ::
                         : "t0", "memory");
    int m_ok = (g_cause == ~0ul);
    uart_puts(m_ok ? "[PASS] " : "[FAIL] ");
    uart_puts("M M-reads-ungated mcause=");
    uart_hex(g_cause);
    uart_puts(" (want no trap)\r\n");
    all_ok &= m_ok;

    /* Restore the reset value for whatever runs next. */
    csr_write(mcounteren, 0x7u);

    uart_puts(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
