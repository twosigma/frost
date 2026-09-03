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
 * Sstc directed test (Phase 3 M6, plan D12). Covers menvcfg.STCE, the only
 * implemented menvcfg field, and the stimecmp CSR. While STCE=1 the registered
 * mtime >= stimecmp compare drives the STIP readback and the software STIP bit
 * is dormant. With STCE=0 an S-mode stimecmp access takes an illegal-instruction
 * trap. The last case delivers a delegated S-mode timer interrupt through
 * stimecmp. Self-checks over UART (<<PASS>> / <<FAIL>>).
 *
 * stimecmp (0x14D) and menvcfg (0x30A) are addressed numerically so the
 * test does not depend on Sstc-aware binutils. The privilege scaffolding
 * (naked M/S handlers with an mscratch continuation, run_in_s) follows
 * smode_test's run_at_priv.
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

static void uart_hex(unsigned long v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = (int) (sizeof(unsigned long) * 8) - 4; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

#define MIP_STIP (1ul << 5)
#define MENVCFG_STCE (1ul << 63)

#define csr_read_num(num)                                                                          \
    ({                                                                                             \
        unsigned long v_;                                                                          \
        __asm__ volatile("csrr %0, " #num : "=r"(v_));                                             \
        v_;                                                                                        \
    })
#define csr_write_num(num, val)                                                                    \
    do {                                                                                           \
        unsigned long v_ = (val);                                                                  \
        __asm__ volatile("csrw " #num ", %0" : : "r"(v_));                                         \
    } while (0)

static int report(const char *name, unsigned long got, unsigned long want)
{
    uart_puts(got == want ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" got=");
    uart_hex(got);
    uart_puts(" want=");
    uart_hex(want);
    uart_puts("\r\n");
    return got == want;
}

static unsigned long poll_mip(unsigned long mask, unsigned long want)
{
    for (int i = 0; i < 4000; i++) {
        if ((csr_read(mip) & mask) == want)
            return want;
    }
    return csr_read(mip) & mask;
}

/* ---- trap state shared with the naked handlers (smode_test shape) ---- */
static volatile unsigned long g_cause;   /* M handler: mcause */
static volatile unsigned long g_s_cause; /* S handler: scause */

/*
 * Naked M-mode trap handler: records mcause once per case (g_cause is seeded
 * with ~0), silences a firing stimecmp by raising it to max, and returns to M
 * at the mscratch continuation. Raising stimecmp is the only way to clear STIP
 * on the STCE path, where the software STIP bit is dormant.
 */
__attribute__((naked, aligned(4))) static void m_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "2:\n"
                     "li   t0, -1\n" /* stimecmp = max: silence the compare */
                     "csrw 0x14D, t0\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n" /* MPP = M */
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/*
 * Naked S-mode trap handler: records scause once per case, silences the timer
 * by writing stimecmp = max, and ecalls out to M (cause 9 ends the case). The
 * stimecmp write is legal from S only with STCE=1, and that is the only
 * configuration that routes an S timer interrupt through stimecmp.
 */
__attribute__((naked, aligned(4))) static void s_trap_handler(void)
{
    __asm__ volatile("csrr t0, scause\n"
                     "la   t1, g_s_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "2:\n"
                     "li   t0, -1\n"
                     "csrw 0x14D, t0\n"
                     "ecall\n"
                     "j    .\n");
}

/* Enter S at fn via MRET; the M handler returns control to the point after
 * the MRET. Returns the mcause that ended the case. */
static unsigned long run_in_s(void (*fn)(void))
{
    g_cause = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n" /* MPP = S */
                     "csrw mepc, %0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(fn)
                     : "t0", "t1", "t2", "t3", "memory");
    return g_cause;
}

/* ---- S bodies ---- */
__attribute__((naked)) static void s_read_stimecmp(void)
{
    __asm__ volatile("csrr t0, 0x14D\n ecall\n j .");
}

__attribute__((naked)) static void s_spin(void)
{
    __asm__ volatile("1: wfi\n j 1b");
}

int main(void)
{
    int ok = 1;
    unsigned long cause;

    uart_puts("\r\n=== Sstc test ===\r\n");
    set_trap_handler(&m_trap_handler);

    /* A: menvcfg resets to 0; STCE is the only writable bit. */
    ok &= report("A menvcfg-reset", csr_read_num(0x30A), 0);
    csr_write_num(0x30A, ~0ul);
    ok &= report("A menvcfg-warl", csr_read_num(0x30A), MENVCFG_STCE);
    csr_write_num(0x30A, 0);

    /* B: stimecmp is M-accessible regardless of STCE. */
    csr_write_num(0x14D, 0x1122334455667788ul);
    ok &= report("B stimecmp-rw", csr_read_num(0x14D), 0x1122334455667788ul);
    csr_write_num(0x14D, ~0ul);

    /* C: with STCE=0, software STIP injection behaves pre-Sstc. */
    csr_set(mip, MIP_STIP);
    ok &= report("C sw-stip", csr_read(mip) & MIP_STIP, MIP_STIP);
    csr_clear(mip, MIP_STIP);
    ok &= report("C sw-stip-clear", csr_read(mip) & MIP_STIP, 0);

    /* D: S-mode stimecmp access with STCE=0 is illegal. medeleg is clear, so
     * the trap is taken in M. The MRET entry itself proves the S round-trip. */
    csr_write(medeleg, 0);
    cause = run_in_s(&s_read_stimecmp);
    ok &= report("D s-stce0-illegal", cause, 2);

    /* E: STCE=1: the registered compare drives STIP; a software STIP
     * write is dormant while it does. */
    csr_write_num(0x30A, MENVCFG_STCE);
    csr_write_num(0x14D, rdmtime() + 200);
    ok &= report("E stip-fires", poll_mip(MIP_STIP, MIP_STIP), MIP_STIP);
    csr_set(mip, MIP_STIP); /* dormant: must not hold STIP up... */
    csr_write_num(0x14D, ~0ul);
    ok &= report("E stip-clears", poll_mip(MIP_STIP, 0), 0); /* ...here */
    csr_clear(mip, MIP_STIP);

    /* F: S-mode stimecmp access with STCE=1 is legal (reaches the ecall). */
    cause = run_in_s(&s_read_stimecmp);
    ok &= report("F s-stce1-legal", cause, 9);

    /* G: delegated S timer interrupt through stimecmp: the S handler sees
     * scause = S-timer, silences stimecmp, and ecalls out (cause 9). */
    g_s_cause = ~0ul;
    csr_write(mideleg, 1ul << 5);
    csr_write(stvec, (unsigned long) &s_trap_handler);
    csr_write(sie, 1ul << 5);
    /* mstatus.SIE gates S-level takes while in S. MRET does not restore SIE
     * from SPIE (SRET does that), so set SIE directly. In M it has no effect on
     * M execution. */
    csr_set(mstatus, 1ul << 1);
    csr_write_num(0x14D, rdmtime() + 300);
    cause = run_in_s(&s_spin);
    ok &= report("G s-take-ends", cause, 9);
    ok &= report("G scause", g_s_cause, 0x8000000000000000ul | 5ul);
    csr_write(mideleg, 0);
    csr_write(sie, 0);
    csr_write_num(0x30A, 0);

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
