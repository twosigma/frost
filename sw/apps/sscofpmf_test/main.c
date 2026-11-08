/*
 *    Copyright (c) 2026 John Goodacre.
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
 * Sscofpmf directed test (privileged spec, "Count Overflow and Mode-Based
 * Filtering"; AIA for the mtopi/stopi priority of interrupt 13).
 *
 *   A  mhpmevent WARL: OF/MINH/SINH/UINH writable, VSINH/VUINH/WPRI zero,
 *      the event field selects only its counter's event.
 *   B  mideleg/mie bit 13 writable, mvip bit 13 zero, scountovf exists.
 *   C  A wrap sets OF and LCOFIP; scountovf shadows OF; a wrap with OF set
 *      raises nothing; a counter write never overflows.
 *   D  LCOFI taken in M with mcause 13 (and mtopi = 13 while it waits).
 *   E  LCOFI delegated to S: scause 13, S reads scountovf and clears
 *      sip.LCOFIP.
 *   F  scountovf below M is masked by mcounteren; U access is illegal.
 *   G  MINH/SINH/UINH stop retired-instruction and cycle counting only in
 *      their own privilege.
 *
 * Counter 10 counts retired instructions and counter 9 cycles. CSRs are
 * accessed by number so the test needs no Sscofpmf-aware assembler.
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

static void uart_hex(unsigned long v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = (int) (sizeof(unsigned long) * 8) - 4; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

#define OF (1ul << 63)
#define MINH (1ul << 62)
#define SINH (1ul << 61)
#define UINH (1ul << 60)
#define LCOF (1ul << 13)
#define INT_LCOF (0x8000000000000000ul | 13ul)
#define PRIV_U 0
#define PRIV_S 1

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

/* Retire a fixed run of instructions. */
static void spin(int n)
{
    for (volatile int i = 0; i < n; i++)
        ;
}

/* ---- trap state ---- */
static volatile unsigned long g_cause;     /* exception that ended a case */
static volatile unsigned long g_int_cause; /* last M interrupt cause */
static volatile unsigned long g_int_count; /* M interrupts taken */
static volatile unsigned long g_s_cause;   /* S handler: scause */
static volatile unsigned long g_s_ovf;     /* S handler: scountovf */
static volatile unsigned long g_s_value;   /* S body result */

/*
 * M handler. An interrupt (only LCOFI is enabled in this test) is counted,
 * clears mip.LCOFIP, and returns to the interrupted code with its registers
 * restored. An exception records mcause once and returns to M at the mscratch
 * continuation.
 */
__attribute__((naked, aligned(4))) static void m_trap_handler(void)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "sd   t2, 16(sp)\n"
                     "sd   t3, 24(sp)\n"
                     "csrr t0, mcause\n"
                     "bgez t0, 1f\n"
                     "la   t1, g_int_cause\n"
                     "sd   t0, 0(t1)\n"
                     "la   t1, g_int_count\n"
                     "ld   t2, 0(t1)\n"
                     "addi t2, t2, 1\n"
                     "sd   t2, 0(t1)\n"
                     "li   t1, 0x2000\n"
                     "csrc mip, t1\n"
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "ld   t2, 16(sp)\n"
                     "ld   t3, 24(sp)\n"
                     "addi sp, sp, 32\n"
                     "mret\n"
                     "1:\n"
                     "addi sp, sp, 32\n"
                     "la   t1, g_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/*
 * S handler for the delegated LCOFI: records scause and scountovf (read from
 * S, so mcounteren filters it), clears sip.LCOFIP, and ecalls out to M.
 */
__attribute__((naked, aligned(4))) static void s_trap_handler(void)
{
    __asm__ volatile("csrr t0, scause\n"
                     "la   t1, g_s_cause\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, 0xDA0\n"
                     "la   t1, g_s_ovf\n"
                     "sd   t0, 0(t1)\n"
                     "li   t0, 0x2000\n"
                     "csrc sip, t0\n"
                     "ecall\n"
                     "j    .\n");
}

/* Run fn at priv through MRET; the M handler returns here on its exception. */
static unsigned long run_at(void (*fn)(void), int priv)
{
    g_cause = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "slli t0, %1, 11\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(fn), "r"((unsigned long) priv)
                     : "t0", "t1", "t2", "t3", "memory");
    return g_cause;
}

/* ---- lower-privilege bodies ---- */
__attribute__((naked)) static void b_spin_ecall(void)
{
    __asm__ volatile("li t0, 200\n"
                     "1: addi t0, t0, -1\n"
                     "bnez t0, 1b\n"
                     "ecall\n"
                     "j .");
}

__attribute__((naked)) static void b_read_scountovf(void)
{
    __asm__ volatile("csrr t0, 0xDA0\n"
                     "la   t1, g_s_value\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j .");
}

__attribute__((naked)) static void b_wait_lcofi(void)
{
    __asm__ volatile("1: j 1b");
}

/* Arm counter 10 (instret) `before` instructions from a wrap, with OF clear. */
static void arm_instret(unsigned long inh, unsigned long before)
{
    csr_write_num(0x32A, 0);
    csr_write_num(0xB0A, (unsigned long) 0 - before);
    csr_write_num(0x32A, inh | 10);
}

int main(void)
{
    int ok = 1;
    unsigned long v, cause;

    uart_puts("\r\n=== Sscofpmf test ===\r\n");
    set_trap_handler(&m_trap_handler);
    csr_write_num(0x306, 0x7FF); /* mcounteren */

    /* A: mhpmevent fields. */
    csr_write_num(0x323, ~0ul);
    ok &= report("A all-ones-keeps-of-inh", csr_read_num(0x323), OF | MINH | SINH | UINH);
    csr_write_num(0x323, (0xFul << 56) | 3);
    ok &= report("A vsinh-vuinh-wpri-zero", csr_read_num(0x323), 3);
    csr_write_num(0x323, (1ul << 40) | 3);
    ok &= report("A wide-selector-is-not-3", csr_read_num(0x323), 0);
    csr_write_num(0x32A, OF | UINH | 10);
    ok &= report("A mhpmevent10-rw", csr_read_num(0x32A), OF | UINH | 10);
    csr_write_num(0x32A, 0);
    csr_write_num(0x323, 0);

    /* B: interrupt 13 CSR bits. */
    csr_write(mideleg, ~0ul);
    ok &= report("B mideleg-warl", csr_read(mideleg), 0x2222);
    csr_write(mideleg, 0);
    csr_write(mie, LCOF);
    ok &= report("B mie-lcofie", csr_read(mie), LCOF);
    csr_write(mie, 0);
    ok &= report("B mvip-bit13-zero", csr_read_num(0x309) & LCOF, 0);
    ok &= report("B scountovf-reset", csr_read_num(0xDA0), 0);

    /* C: wrap, OF, LCOFIP, scountovf. MIE=0 so nothing is taken. */
    csr_clear(mip, LCOF);
    arm_instret(0, 40);
    spin(20);
    ok &= report("C of-set", csr_read_num(0x32A) & OF, OF);
    ok &= report("C lcofip-set", csr_read(mip) & LCOF, LCOF);
    ok &= report("C scountovf", csr_read_num(0xDA0), 1ul << 10);
    v = csr_read_num(0xB0A);
    ok &= report("C counter-wrapped-and-runs", v > 0 && v < 4096, 1);
    csr_clear(mip, LCOF);
    ok &= report("C lcofip-sw-clear", csr_read(mip) & LCOF, 0);
    /* Second wrap with OF still set: no new request. */
    csr_write_num(0xB0A, (unsigned long) 0 - 40);
    spin(20);
    ok &= report("C of-set-no-request", csr_read(mip) & LCOF, 0);
    /* Counter writes never overflow. */
    csr_write_num(0x32A, MINH | 10); /* OF clear, not counting in M */
    csr_write_num(0xB0A, ~0ul);
    csr_write_num(0xB0A, 0);
    ok &= report("C write-no-overflow-of", csr_read_num(0x32A), MINH | 10);
    ok &= report("C write-no-overflow-lcofip", csr_read(mip) & LCOF, 0);
    /* Counter 9 counts cycles. */
    csr_write_num(0xB09, (unsigned long) 0 - 64);
    csr_write_num(0x329, 9);
    spin(40);
    ok &= report("C cycles-of", csr_read_num(0x329), OF | 9);
    csr_write_num(0x329, 0);
    csr_clear(mip, LCOF);

    /* D: LCOFI in M. mtopi reports 13 while the request waits with MIE=0. */
    g_int_count = 0;
    csr_write(mie, LCOF);
    arm_instret(0, 40);
    spin(20);
    ok &= report("D mtopi-13", csr_read_num(0xFB0), 0x000D0001ul);
    csr_set(mstatus, 1ul << 3);
    spin(4);
    csr_clear(mstatus, 1ul << 3);
    ok &= report("D taken-once", g_int_count, 1);
    ok &= report("D mcause-13", g_int_cause, INT_LCOF);
    ok &= report("D handler-cleared-lcofip", csr_read(mip) & LCOF, 0);
    csr_write(mie, 0);

    /* E: LCOFI delegated to S. The counter counts S only (MINH), as OpenSBI
     * programs it. The S handler sees scause 13 and scountovf bit 10. */
    g_s_cause = 0;
    g_s_ovf = 0;
    csr_write(mideleg, LCOF);
    csr_write(stvec, (unsigned long) &s_trap_handler);
    csr_write(sie, LCOF);
    ok &= report("E sie-alias", csr_read(mie) & LCOF, LCOF);
    csr_set(mstatus, 1ul << 1); /* SIE */
    arm_instret(MINH, 100);
    cause = run_at(&b_wait_lcofi, PRIV_S);
    ok &= report("E s-take-ends", cause, 9);
    ok &= report("E scause-13", g_s_cause, INT_LCOF);
    ok &= report("E s-scountovf", g_s_ovf, 1ul << 10);
    ok &= report("E sip-cleared", csr_read(mip) & LCOF, 0);
    ok &= report("E stopi-idle", csr_read_num(0xDB0), 0);
    csr_clear(mstatus, 1ul << 1);
    csr_write(sie, 0);
    csr_write(mideleg, 0);
    csr_write_num(0x32A, 0);

    /* F: scountovf from S is masked by mcounteren; from U it is illegal. */
    csr_write_num(0x32A, OF | MINH | SINH | UINH | 10); /* OF set, not counting */
    csr_write_num(0x326, OF | 6);
    csr_write_num(0x306, 0x7FF & ~(1ul << 6));
    run_at(&b_read_scountovf, PRIV_S);
    ok &= report("F s-masked", g_s_value, 1ul << 10);
    csr_write_num(0x306, 0x7FF);
    run_at(&b_read_scountovf, PRIV_S);
    ok &= report("F s-unmasked", g_s_value, (1ul << 10) | (1ul << 6));
    ok &= report("F m-all", csr_read_num(0xDA0), (1ul << 10) | (1ul << 6));
    cause = run_at(&b_read_scountovf, PRIV_U);
    ok &= report("F u-illegal", cause, 2);
    csr_write_num(0x326, 0);
    csr_write_num(0x32A, 0);

    /* G: mode filtering. Each row runs a 200-iteration body in S or U and
     * reads counter 10 from M before and after; MINH keeps M code out. */
    struct {
        const char *name;
        int priv;
        unsigned long inh;
        int counts;
    } rows[] = {
        {"G s-sinh-stops", PRIV_S, MINH | SINH, 0},
        {"G s-uinh-counts", PRIV_S, MINH | UINH, 1},
        {"G u-uinh-stops", PRIV_U, MINH | UINH, 0},
        {"G u-sinh-counts", PRIV_U, MINH | SINH, 1},
    };
    for (unsigned i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        csr_write_num(0x32A, 0);
        csr_write_num(0xB0A, 0);
        csr_write_num(0x32A, rows[i].inh | 10);
        run_at(&b_spin_ecall, rows[i].priv);
        csr_write_num(0x32A, MINH | SINH | UINH | 10);
        v = csr_read_num(0xB0A);
        ok &= report(rows[i].name, rows[i].counts ? (v >= 400 && v < 1000) : v, rows[i].counts);
    }
    /* MINH stops cycles and instructions in M; UINH alone does not. */
    csr_write_num(0xB09, 0);
    csr_write_num(0x329, MINH | 9);
    spin(20);
    ok &= report("G m-minh-cycles", csr_read_num(0xB09), 0);
    csr_write_num(0x329, UINH | 9);
    spin(20);
    ok &= report("G m-uinh-cycles-count", csr_read_num(0xB09) > 20, 1);
    csr_write_num(0x329, 0);
    csr_write_num(0xB0A, 0);
    csr_write_num(0x32A, MINH | 10);
    spin(20);
    ok &= report("G m-minh-instret", csr_read_num(0xB0A), 0);
    csr_write_num(0x32A, 0);

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
