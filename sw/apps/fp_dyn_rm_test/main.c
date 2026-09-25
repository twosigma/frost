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
 * Dynamic rounding mode directed test. An FP instruction whose rm field is
 * DYN (111) reads frm, and frm values 5 to 7 are reserved: FROST raises
 * illegal-instruction for such an instruction, as it does for the reserved
 * static modes. Self-checks over UART (<<PASS>>/<<FAIL>>):
 *
 *   A-F, K, L. With frm = 5, 6 or 7, a DYN add, double multiply, square
 *      root, FMA, float-to-int and int-to-float conversion, divide, and
 *      widening conversion each trap with mcause 2, mepc at the instruction
 *      and mtval 0. The destination keeps its old value and fflags stay
 *      clear (the divide would otherwise raise DZ).
 *   G. Static rounding modes ignore frm: with frm = 5, fadd.s rne rounds to
 *      nearest, and with frm = 7, fadd.s rup rounds up.
 *   H. Instructions without an rm field (fsgnj.s, feq.s, fmin.s) do not
 *      trap with frm = 7.
 *   I, J, M. With a valid frm, DYN uses it: fadd.s rounds up under RUP and
 *      to nearest under RMM, and fcvt.w.s of 2.5 gives 3 under RUP.
 *
 * Each case uses the M-mode bounce from pma_fault_test: the mtvec handler
 * records mcause/mepc/mtval for the first trap of the case and returns to the
 * continuation stashed in mscratch. An ecall follows the instruction under
 * test, so an instruction that does not trap records cause 11.
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

static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_tval;
/* Written by the asm in RUN_FP; read back after it. */
volatile unsigned long g_insn_pc;
volatile unsigned long g_ft0;
volatile unsigned long g_t4;
volatile unsigned long g_fflags;

/* M-mode bounce handler: record mcause/mepc/mtval once per case, return to
 * the mscratch continuation in M-mode. */
__attribute__((naked, aligned(4))) static void fp_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_epc\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_tval\n"
                     "sd   t0, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* Raw bit patterns. Single-precision operands are NaN-boxed. */
#define ONE_S 0xFFFFFFFF3F800000ul
#define ONE_S_UP 0xFFFFFFFF3F800001ul /* 1.0f + 1 ulp */
#define TINY_S 0xFFFFFFFF30800000ul   /* 2^-30 */
#define ZERO_S 0xFFFFFFFF00000000ul
#define TWO_HALF_S 0xFFFFFFFF40200000ul /* 2.5f */
#define ONE_D 0x3FF0000000000000ul
#define TWO_D 0x4000000000000000ul
#define SENTINEL 0x0123456789ABCDEFul
#define FFLAGS_NX 0x1ul

#define FRM_RUP 3ul
#define FRM_RMM 4ul

/* Run one case: set frm, clear fflags, load ft1 = a, ft2 = ft3 = b, seed ft0
 * and t4 with sentinels, record the address of the instruction under test,
 * run it, then fall into the ecall. Both paths reach label 1, which records
 * ft0, t4 and fflags and restores frm to RNE. The handler clobbers t0-t3. */
#define RUN_FP(frm, insn_asm, a, b)                                                                \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_epc = ~0ul;                                                                              \
        g_tval = ~0ul;                                                                             \
        __asm__ volatile("la   t0, 1f\n"                                                           \
                         "csrw mscratch, t0\n"                                                     \
                         "fsrm %0\n"                                                               \
                         "fsflags zero\n"                                                          \
                         "fmv.d.x ft0, %3\n"                                                       \
                         "fmv.d.x ft1, %1\n"                                                       \
                         "fmv.d.x ft2, %2\n"                                                       \
                         "fmv.d.x ft3, %2\n"                                                       \
                         "mv   t4, %3\n"                                                           \
                         "la   t0, g_insn_pc\n"                                                    \
                         "la   t1, 2f\n"                                                           \
                         "sd   t1, 0(t0)\n"                                                        \
                         "2:\n" insn_asm "\n"                                                      \
                         "ecall\n"                                                                 \
                         "1:\n"                                                                    \
                         "la   t0, g_ft0\n"                                                        \
                         "fsd  ft0, 0(t0)\n"                                                       \
                         "la   t0, g_t4\n"                                                         \
                         "sd   t4, 0(t0)\n"                                                        \
                         "frflags t1\n"                                                            \
                         "la   t0, g_fflags\n"                                                     \
                         "sd   t1, 0(t0)\n"                                                        \
                         "fsrmi 0\n"                                                               \
                         :                                                                         \
                         : "r"(frm), "r"(a), "r"(b), "r"(SENTINEL)                                 \
                         : "t0", "t1", "t2", "t3", "t4", "ft0", "ft1", "ft2", "ft3", "memory");    \
    } while (0)

static void report_values(void)
{
    uart_puts(" cause=");
    uart_hex(g_cause);
    uart_puts(" epc=");
    uart_hex(g_epc);
    uart_puts(" tval=");
    uart_hex(g_tval);
    uart_puts(" ft0=");
    uart_hex(g_ft0);
    uart_puts(" t4=");
    uart_hex(g_t4);
    uart_puts(" fflags=");
    uart_hex(g_fflags);
    uart_puts("\r\n");
}

/* The instruction trapped as illegal, at its own PC, and wrote nothing. */
static int expect_illegal(const char *name)
{
    int ok = (g_cause == 2u) && (g_epc == g_insn_pc) && (g_tval == 0u) && (g_ft0 == SENTINEL) &&
             (g_t4 == SENTINEL) && (g_fflags == 0u);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    report_values();
    return ok;
}

/* The instruction ran (only the ecall trapped) with the given results. */
static int expect_ran(const char *name,
                      unsigned long want_ft0,
                      unsigned long want_t4,
                      unsigned long want_fflags)
{
    int ok =
        (g_cause == 11u) && (g_ft0 == want_ft0) && (g_t4 == want_t4) && (g_fflags == want_fflags);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    report_values();
    return ok;
}

int main(void)
{
    int all_ok = 1;

    uart_puts("\r\n=== Dynamic rounding mode with reserved frm test ===\r\n");
    set_trap_handler(&fp_trap_handler);

    RUN_FP(5ul, "fadd.s ft0, ft1, ft2, dyn", ONE_S, TINY_S);
    all_ok &= expect_illegal("A frm=5 fadd.s dyn");

    RUN_FP(6ul, "fmul.d ft0, ft1, ft2, dyn", ONE_D, TWO_D);
    all_ok &= expect_illegal("B frm=6 fmul.d dyn");

    RUN_FP(7ul, "fsqrt.s ft0, ft1, dyn", ONE_S, ONE_S);
    all_ok &= expect_illegal("C frm=7 fsqrt.s dyn");

    RUN_FP(5ul, "fmadd.s ft0, ft1, ft2, ft3, dyn", ONE_S, ONE_S);
    all_ok &= expect_illegal("D frm=5 fmadd.s dyn");

    RUN_FP(6ul, "fcvt.w.s t4, ft1, dyn", TWO_HALF_S, ONE_S);
    all_ok &= expect_illegal("E frm=6 fcvt.w.s dyn");

    RUN_FP(7ul, "fdiv.s ft0, ft1, ft2, dyn", ONE_S, ZERO_S);
    all_ok &= expect_illegal("F frm=7 fdiv.s dyn by zero");

    /* FCVT.D.S (funct7 0100001, rs2 0) with rm = DYN. The widening
     * conversion is exact, but its rm field still decodes as usual. */
    RUN_FP(5ul, ".insn r 0x53, 7, 0x21, ft0, ft1, f0", ONE_S, ONE_S);
    all_ok &= expect_illegal("K frm=5 fcvt.d.s dyn");

    RUN_FP(6ul, "fcvt.s.w ft0, zero, dyn", ONE_S, ONE_S);
    all_ok &= expect_illegal("L frm=6 fcvt.s.w dyn");

    RUN_FP(5ul, "fadd.s ft0, ft1, ft2, rne", ONE_S, TINY_S);
    all_ok &= expect_ran("G1 frm=5 fadd.s rne", ONE_S, SENTINEL, FFLAGS_NX);

    RUN_FP(7ul, "fadd.s ft0, ft1, ft2, rup", ONE_S, TINY_S);
    all_ok &= expect_ran("G2 frm=7 fadd.s rup", ONE_S_UP, SENTINEL, FFLAGS_NX);

    RUN_FP(7ul,
           "fsgnj.s ft0, ft1, ft2\n"
           "feq.s t4, ft1, ft2\n"
           "fmin.s ft0, ft0, ft1",
           ONE_S,
           TINY_S);
    all_ok &= expect_ran("H frm=7 fsgnj.s/feq.s/fmin.s", ONE_S, 0u, 0u);

    RUN_FP(FRM_RUP, "fadd.s ft0, ft1, ft2, dyn", ONE_S, TINY_S);
    all_ok &= expect_ran("I frm=RUP fadd.s dyn", ONE_S_UP, SENTINEL, FFLAGS_NX);

    RUN_FP(FRM_RMM, "fadd.s ft0, ft1, ft2, dyn", ONE_S, TINY_S);
    all_ok &= expect_ran("J frm=RMM fadd.s dyn", ONE_S, SENTINEL, FFLAGS_NX);

    RUN_FP(FRM_RUP, "fcvt.w.s t4, ft1, dyn", TWO_HALF_S, ONE_S);
    all_ok &= expect_ran("M frm=RUP fcvt.w.s dyn", SENTINEL, 3u, FFLAGS_NX);

    uart_puts(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
