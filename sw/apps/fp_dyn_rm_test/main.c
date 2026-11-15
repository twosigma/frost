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
 * illegal-instruction with mcause 2, mepc at the instruction and mtval the
 * instruction's bits (Sstvala).
 * The destination and fflags must remain unchanged. Static rounding modes
 * and instructions without an rm field ignore frm.
 *
 * A trapping instruction still executes on its FP unit first: frm 5 and 6
 * reach the unit unchanged; frm 7 becomes RNE. Square root and divide test
 * both paths. The int-to-float conversion reads x0 (rs1 = 0).
 *
 * The mtvec handler records the first trap's mcause, mepc and mtval and
 * returns to the continuation in mscratch. An ecall follows the instruction
 * under test, so an instruction that does not trap records cause 11.
 */

#include <stdint.h>

#include "trap.h"

static void uart_putc(char c)
{
    while ((UART_TX_STATUS & 1u) == 0) {
    }
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

/* Sstvala: mtval holds the faulting instruction's bits, a compressed
 * instruction's 16 bits zero-extended. */
static unsigned long insn_bits_at(unsigned long pc)
{
    unsigned long lo = *(volatile unsigned short *) pc;
    if ((lo & 3u) != 3u)
        return lo;
    return lo | ((unsigned long) *(volatile unsigned short *) (pc + 2) << 16);
}

/* The instruction trapped as illegal, at its own PC, and wrote nothing. */
static int expect_illegal(const char *name)
{
    int ok = (g_cause == 2u) && (g_epc == g_insn_pc) && (g_tval == insn_bits_at(g_insn_pc)) &&
             (g_ft0 == SENTINEL) && (g_t4 == SENTINEL) && (g_fflags == 0u);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    if (!ok)
        report_values();
    else
        uart_puts("\r\n");
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
    if (!ok)
        report_values();
    else
        uart_puts("\r\n");
    return ok;
}

/* Exact conversions also decode their rm field. Static modes ignore frm. */
#define EXTENSION_RM(name, funct7, rs2, source, result)                                            \
    do {                                                                                           \
        for (unsigned long mode = 5; mode <= 7; mode++) {                                          \
            RUN_FP(mode, ".insn r 0x53, 7, " #funct7 ", ft0, ft1, " #rs2, source, ONE_S);          \
            all_ok &= expect_illegal(name " reserved dynamic mode");                               \
        }                                                                                          \
        RUN_FP(0ul, ".insn r 0x53, 5, " #funct7 ", ft0, ft1, " #rs2, source, ONE_S);               \
        all_ok &= expect_illegal(name " reserved static mode 5");                                  \
        RUN_FP(0ul, ".insn r 0x53, 6, " #funct7 ", ft0, ft1, " #rs2, source, ONE_S);               \
        all_ok &= expect_illegal(name " reserved static mode 6");                                  \
        RUN_FP(7ul, ".insn r 0x53, 0, " #funct7 ", ft0, ft1, " #rs2, source, ONE_S);               \
        all_ok &= expect_ran(name " static mode ignores frm", result, SENTINEL, 0ul);              \
        for (unsigned long mode = 0; mode <= 4; mode++) {                                          \
            RUN_FP(mode, ".insn r 0x53, 7, " #funct7 ", ft0, ft1, " #rs2, source, ONE_S);          \
            all_ok &= expect_ran(name " legal dynamic mode", result, SENTINEL, 0ul);               \
        }                                                                                          \
    } while (0)

int main(void)
{
    int all_ok = 1;

    uart_puts("\r\n=== Dynamic rounding mode with reserved frm test ===\r\n");
    set_trap_handler(&fp_trap_handler);

    RUN_FP(5ul, "fadd.s ft0, ft1, ft2, dyn", ONE_S, TINY_S);
    all_ok &= expect_illegal("A1 frm=5 fadd.s dyn");

    RUN_FP(6ul, "fadd.s ft0, ft1, ft2, dyn", ONE_S, TINY_S);
    all_ok &= expect_illegal("A2 frm=6 fadd.s dyn");

    RUN_FP(7ul, "fadd.s ft0, ft1, ft2, dyn", ONE_S, TINY_S);
    all_ok &= expect_illegal("A3 frm=7 fadd.s dyn");

    RUN_FP(6ul, "fmul.d ft0, ft1, ft2, dyn", ONE_D, TWO_D);
    all_ok &= expect_illegal("B frm=6 fmul.d dyn");

    RUN_FP(7ul, "fsqrt.s ft0, ft1, dyn", ONE_S, ONE_S);
    all_ok &= expect_illegal("C1 frm=7 fsqrt.s dyn");

    RUN_FP(6ul, "fsqrt.s ft0, ft1, dyn", ONE_S, ONE_S);
    all_ok &= expect_illegal("C2 frm=6 fsqrt.s dyn");

    RUN_FP(5ul, "fmadd.s ft0, ft1, ft2, ft3, dyn", ONE_S, ONE_S);
    all_ok &= expect_illegal("D frm=5 fmadd.s dyn");

    RUN_FP(6ul, "fcvt.w.s t4, ft1, dyn", TWO_HALF_S, ONE_S);
    all_ok &= expect_illegal("E frm=6 fcvt.w.s dyn");

    RUN_FP(7ul, "fdiv.s ft0, ft1, ft2, dyn", ONE_S, ZERO_S);
    all_ok &= expect_illegal("F1 frm=7 fdiv.s dyn by zero");

    RUN_FP(5ul, "fdiv.s ft0, ft1, ft2, dyn", ONE_S, ZERO_S);
    all_ok &= expect_illegal("F2 frm=5 fdiv.s dyn by zero");

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

    /* Zfhmin conversions and Zfa integral rounding all carry rm. */
    EXTENSION_RM("FCVT.S.H", 0x20, f2, 0xFFFFFFFFFFFF3C00ul, ONE_S);
    EXTENSION_RM("FCVT.D.H", 0x21, f2, 0xFFFFFFFFFFFF3C00ul, ONE_D);
    EXTENSION_RM("FCVT.H.S", 0x22, f0, ONE_S, 0xFFFFFFFFFFFF3C00ul);
    EXTENSION_RM("FCVT.H.D", 0x22, f1, ONE_D, 0xFFFFFFFFFFFF3C00ul);
    EXTENSION_RM("FROUND.S", 0x20, f4, ONE_S, ONE_S);
    EXTENSION_RM("FROUNDNX.S", 0x20, f5, ONE_S, ONE_S);
    EXTENSION_RM("FROUND.D", 0x21, f4, ONE_D, ONE_D);
    EXTENSION_RM("FROUNDNX.D", 0x21, f5, ONE_D, ONE_D);

    /* FCVTMOD accepts only RTZ, regardless of frm. */
    RUN_FP(0ul, ".insn r 0x53, 0, 0x61, t4, ft1, f8", ONE_D, ONE_D);
    all_ok &= expect_illegal("FCVTMOD reserved rm 0");
    RUN_FP(0ul, ".insn r 0x53, 2, 0x61, t4, ft1, f8", ONE_D, ONE_D);
    all_ok &= expect_illegal("FCVTMOD reserved rm 2");
    RUN_FP(0ul, ".insn r 0x53, 3, 0x61, t4, ft1, f8", ONE_D, ONE_D);
    all_ok &= expect_illegal("FCVTMOD reserved rm 3");
    RUN_FP(0ul, ".insn r 0x53, 4, 0x61, t4, ft1, f8", ONE_D, ONE_D);
    all_ok &= expect_illegal("FCVTMOD reserved rm 4");
    RUN_FP(0ul, ".insn r 0x53, 5, 0x61, t4, ft1, f8", ONE_D, ONE_D);
    all_ok &= expect_illegal("FCVTMOD reserved rm 5");
    RUN_FP(0ul, ".insn r 0x53, 6, 0x61, t4, ft1, f8", ONE_D, ONE_D);
    all_ok &= expect_illegal("FCVTMOD reserved rm 6");
    RUN_FP(0ul, ".insn r 0x53, 7, 0x61, t4, ft1, f8", ONE_D, ONE_D);
    all_ok &= expect_illegal("FCVTMOD reserved rm 7");
    RUN_FP(7ul, "fcvtmod.w.d t4, ft1, rtz", ONE_D, ONE_D);
    all_ok &= expect_ran("FCVTMOD ignores frm", SENTINEL, 1ul, 0ul);
    RUN_FP(7ul, "fli.s ft0, 1.0", ONE_S, ONE_S);
    all_ok &= expect_ran("fli.s ignores frm", ONE_S, SENTINEL, 0ul);
    RUN_FP(7ul, "fminm.s ft0, ft1, ft2", ONE_S, ONE_S);
    all_ok &= expect_ran("fminm.s ignores frm", ONE_S, SENTINEL, 0ul);
    RUN_FP(7ul, "fmaxm.s ft0, ft1, ft2", ONE_S, ONE_S);
    all_ok &= expect_ran("fmaxm.s ignores frm", ONE_S, SENTINEL, 0ul);
    RUN_FP(7ul, "fleq.s t4, ft1, ft2", ONE_S, ONE_S);
    all_ok &= expect_ran("fleq.s ignores frm", SENTINEL, 1ul, 0ul);
    RUN_FP(7ul, "fltq.s t4, ft1, ft2", ONE_S, ONE_S);
    all_ok &= expect_ran("fltq.s ignores frm", SENTINEL, 0ul, 0ul);
    RUN_FP(7ul, "fli.d ft0, 1.0", ONE_D, ONE_D);
    all_ok &= expect_ran("fli.d ignores frm", ONE_D, SENTINEL, 0ul);
    RUN_FP(7ul, "fminm.d ft0, ft1, ft2", ONE_D, ONE_D);
    all_ok &= expect_ran("fminm.d ignores frm", ONE_D, SENTINEL, 0ul);
    RUN_FP(7ul, "fmaxm.d ft0, ft1, ft2", ONE_D, ONE_D);
    all_ok &= expect_ran("fmaxm.d ignores frm", ONE_D, SENTINEL, 0ul);
    RUN_FP(7ul, "fleq.d t4, ft1, ft2", ONE_D, ONE_D);
    all_ok &= expect_ran("fleq.d ignores frm", SENTINEL, 1ul, 0ul);
    RUN_FP(7ul, "fltq.d t4, ft1, ft2", ONE_D, ONE_D);
    all_ok &= expect_ran("fltq.d ignores frm", SENTINEL, 0ul, 0ul);

    /* Full Zfh, RV32 double moves and Q forms are not implemented. */
    RUN_FP(0ul, ".4byte 0xf4108053", ONE_D, ONE_D);
    all_ok &= expect_illegal("FLI.H unsupported");
    RUN_FP(0ul, ".4byte 0x04208053", ONE_D, ONE_D);
    all_ok &= expect_illegal("FADD.H unsupported");
    RUN_FP(0ul, ".4byte 0xe4009ed3", ONE_D, ONE_D);
    all_ok &= expect_illegal("FCLASS.H unsupported");
    RUN_FP(0ul, ".4byte 0x2c20a053", ONE_D, ONE_D);
    all_ok &= expect_illegal("FMINM.H unsupported");
    RUN_FP(0ul, ".4byte 0x44408053", ONE_D, ONE_D);
    all_ok &= expect_illegal("FROUND.H unsupported");
    RUN_FP(0ul, ".4byte 0x44508053", ONE_D, ONE_D);
    all_ok &= expect_illegal("FROUNDNX.H unsupported");
    RUN_FP(0ul, ".4byte 0xa420ced3", ONE_D, ONE_D);
    all_ok &= expect_illegal("FLEQ.H unsupported");
    RUN_FP(0ul, ".4byte 0xe2108ed3", ONE_D, ONE_D);
    all_ok &= expect_illegal("FMVH.X.D unsupported");
    RUN_FP(0ul, ".4byte 0xb2208053", ONE_D, ONE_D);
    all_ok &= expect_illegal("FMVP.D.X unsupported");
    RUN_FP(0ul, ".4byte 0xe6108ed3", ONE_D, ONE_D);
    all_ok &= expect_illegal("FMVH.X.Q unsupported");
    RUN_FP(0ul, ".4byte 0xb6208053", ONE_D, ONE_D);
    all_ok &= expect_illegal("FMVP.Q.X unsupported");

    uart_puts(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
