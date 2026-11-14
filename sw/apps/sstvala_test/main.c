/*
 *    Copyright (c) 2026 John Goodacre
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
 * Sstvala directed test. An illegal-instruction exception writes the faulting
 * instruction's bits to mtval, or to stval when medeleg delegates it: the 32
 * bits of a native instruction, or the 16 bits of a compressed one
 * zero-extended (the next halfword never leaks into bits 31:16).
 *
 * Every FROST illegal-instruction source is a case: reserved native and
 * compressed encodings (decode and the RVC predecode), SYSTEM funct3=100
 * neighbours of Zimop, FP with mstatus.FS=Off (native and compressed), a
 * reserved dynamic rounding mode, a missing CSR, a write to a read-only CSR,
 * M-level CSRs and xRETs below M, SRET with TSR, WFI and wrs.nto with TW,
 * SFENCE.VMA and satp with TVM, Zicbom/Zicboz with the menvcfg enables clear,
 * counters gated by mcounteren, and S-level instructions in U. Each case
 * checks the cause, xepc and xtval; the delegated cases check scause, sepc
 * and stval and that mtval is untouched.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

#define CAUSE_ILLEGAL 2ul
#define CAUSE_ECALL_U 8ul
#define CAUSE_ECALL_S 9ul
#define CAUSE_ECALL_M 11ul

#define MSTATUS_FS (3ul << 13)
#define MSTATUS_TVM (1ul << 20)
#define MSTATUS_TW (1ul << 21)
#define MSTATUS_TSR (1ul << 22)

#define MODE_U 0ul
#define MODE_S 1ul
#define MODE_M 3ul

static volatile unsigned long g_mcause, g_mtval, g_mepc;
static volatile unsigned long g_scause, g_stval, g_sepc;

/* M handler: record mcause/mtval/mepc, return to M at mscratch. */
__attribute__((naked, aligned(4))) static void m_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_mcause\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_mtval\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_mepc\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* S handler for delegated traps: record scause/stval/sepc, then ecall to M. */
__attribute__((naked, aligned(4))) static void s_handler(void)
{
    __asm__ volatile("csrr t0, scause\n"
                     "la   t1, g_scause\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, stval\n"
                     "la   t1, g_stval\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, sepc\n"
                     "la   t1, g_sepc\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j .\n");
}

/* Each body's first instruction is the case; a body that does not trap
 * reaches its ecall. The halfword or word after a compressed case is
 * nonzero, so a leak into tval[31:16] shows. */
#define BODY(name, insn)                                                                           \
    extern char name[];                                                                            \
    __asm__(".text\n.balign 4\n.global " #name "\n" #name ":\n" insn "\n"                          \
            ".option push\n.option norvc\nlui t6, 0xfffff\necall\nj .\n.option pop\n");

/* Reserved native and compressed encodings. custom-0 with every field set. */
BODY(b_custom0, ".word 0xfedcba8b")
/* c.addi4spn with a zero immediate (rd' = 7). */
BODY(b_c_addi4spn0, ".half 0x001c")
/* Quadrant 0 funct3=100 with bit 12 set (no Zcb form). */
BODY(b_c_q0_res, ".half 0x9ffc")
/* Zcb c.sh slot with bit 6 set. */
BODY(b_c_sh_res, ".half 0x8cc4")
/* Zcb unary selector 111. */
BODY(b_c_unary_res, ".half 0x9c7d")
/* c.lui x4, 0 (not a C.MOP: rd even). */
BODY(b_c_lui0, ".half 0x6201")
/* hlv.b x10, (x11): SYSTEM funct3=100 without H. */
BODY(b_hlv, ".word 0x6005c573")
/* mop.r.0 x10, x11 with bit 28 set. */
BODY(b_mop_near, ".word 0x91c5c573")
/* FP with mstatus.FS=Off: fadd.d f1, f2, f3 and c.fld f9, 8(s0). */
BODY(b_fadd, ".word 0x023170d3")
BODY(b_c_fld, ".half 0x2404")
/* fadd.d f1, f2, f3 with rm=dyn (frm set to 5). */
BODY(b_fadd_dyn, ".word 0x023170d3")
/* csrrs a5, 0x0ff, x0: no such CSR. */
BODY(b_csr_missing, ".word 0x0ff027f3")
/* csrrw x0, mvendorid, t0: read-only CSR. */
BODY(b_csr_ro, ".word 0xf1129073")
/* csrrs a5, mscratch, x0 below M. */
BODY(b_mscratch, ".word 0x340027f3")
/* mret, sret, wfi, sfence.vma a0, a1. */
BODY(b_mret, ".word 0x30200073")
BODY(b_sret, ".word 0x10200073")
BODY(b_wfi, ".word 0x10500073")
BODY(b_sfence, ".word 0x12b50073")
/* csrrs a5, satp, x0 (TVM). */
BODY(b_satp, ".word 0x180027f3")
/* cbo.zero (a0), cbo.clean (a0), cbo.inval (a0). */
BODY(b_cbo_zero, ".word 0x0045200f")
BODY(b_cbo_clean, ".word 0x0015200f")
BODY(b_cbo_inval, ".word 0x0005200f")
/* wrs.nto (TW). */
BODY(b_wrs_nto, ".word 0x00d00073")
/* rdcycle a5 with mcounteren.CY clear; csrrs a5, sstatus, x0 in U;
 * sfence.w.inval in U. */
BODY(b_rdcycle, ".word 0xc00027f3")
BODY(b_sstatus, ".word 0x100027f3")
BODY(b_sfence_w_inval, ".word 0x18000073")

static void run_mode(unsigned long mpp, const void *body)
{
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "slli t0, %0, 11\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %1\n"
                     "auipc s0, 0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(mpp), "r"((unsigned long) body)
                     : "t0", "t1", "t2", "t3", "t6", "a0", "a1", "a5", "s0", "memory");
}

static unsigned long insn_bits_at(const void *pc)
{
    unsigned long lo = *(const volatile uint16_t *) pc;
    if ((lo & 3u) != 3u)
        return lo;
    return lo | ((unsigned long) *(const volatile uint16_t *) ((const char *) pc + 2) << 16);
}

static const char *const mode_name[4] = {"U", "S", "?", "M"};

/* Run one case in mode and check the M-mode (or, delegated, the S-mode) trap. */
static int run_case(const char *name, unsigned long mode, const void *body, int delegated)
{
    unsigned long want = insn_bits_at(body);
    int ok;
    g_mcause = g_mtval = g_mepc = ~0ul;
    g_scause = g_stval = g_sepc = ~0ul;
    run_mode(mode, body);
    if (delegated) {
        ok = g_scause == CAUSE_ILLEGAL && g_stval == want && g_sepc == (unsigned long) body &&
             g_mcause == CAUSE_ECALL_S && g_mtval == 0;
        uart_puts(ok ? "[PASS] " : "[FAIL] ");
        uart_printf("%s mode=%s delegated scause=%lu stval=0x%lx sepc=0x%lx want=0x%lx "
                    "mcause=%lu mtval=0x%lx\r\n",
                    name,
                    mode_name[mode],
                    g_scause,
                    g_stval,
                    g_sepc,
                    want,
                    g_mcause,
                    g_mtval);
    } else {
        ok = g_mcause == CAUSE_ILLEGAL && g_mtval == want && g_mepc == (unsigned long) body;
        uart_puts(ok ? "[PASS] " : "[FAIL] ");
        uart_printf("%s mode=%s mcause=%lu mtval=0x%lx mepc=0x%lx want=0x%lx\r\n",
                    name,
                    mode_name[mode],
                    g_mcause,
                    g_mtval,
                    g_mepc,
                    want);
    }
    return ok;
}

int main(void)
{
    int ok = 1;
    static const struct {
        const char *name;
        const void *body;
    } reserved[] = {
        {"custom-0", b_custom0},
        {"c.addi4spn imm=0", b_c_addi4spn0},
        {"c q0 funct3=100 bit12", b_c_q0_res},
        {"c.sh bit6", b_c_sh_res},
        {"zcb unary 111", b_c_unary_res},
        {"c.lui x4,0", b_c_lui0},
        {"hlv.b", b_hlv},
        {"mop.r near miss", b_mop_near},
        {"csr missing", b_csr_missing},
        {"csr read-only write", b_csr_ro},
    };

    uart_puts("\r\n=== Sstvala test ===\r\n");
    set_trap_handler(&m_handler);
    csr_write(stvec, (unsigned long) &s_handler);
    csr_write(medeleg, 0);
    csr_write(mcounteren, 0);
    csr_write(menvcfg, 0);
    csr_write(satp, 0);

    /* Reserved encodings in M, S and U. */
    for (unsigned i = 0; i < sizeof(reserved) / sizeof(reserved[0]); i++)
        for (unsigned long mode = 0; mode < 4; mode++)
            if (mode != 2)
                ok &= run_case(reserved[i].name, mode, reserved[i].body, 0);

    /* FP with FS=Off, native and compressed, in M and U. */
    csr_clear(mstatus, MSTATUS_FS);
    ok &= run_case("fadd.d FS=Off", MODE_M, b_fadd, 0);
    ok &= run_case("c.fld FS=Off", MODE_M, b_c_fld, 0);
    ok &= run_case("fadd.d FS=Off", MODE_U, b_fadd, 0);
    ok &= run_case("c.fld FS=Off", MODE_U, b_c_fld, 0);
    csr_set(mstatus, MSTATUS_FS);
    /* Reserved dynamic rounding mode. */
    csr_write(frm, 5);
    ok &= run_case("fadd.d frm=5", MODE_M, b_fadd_dyn, 0);
    csr_write(frm, 0);

    /* M-level CSR and xRETs below M. */
    ok &= run_case("csrr mscratch", MODE_S, b_mscratch, 0);
    ok &= run_case("csrr mscratch", MODE_U, b_mscratch, 0);
    ok &= run_case("mret", MODE_S, b_mret, 0);
    ok &= run_case("mret", MODE_U, b_mret, 0);
    ok &= run_case("sret", MODE_U, b_sret, 0);
    ok &= run_case("sfence.vma", MODE_U, b_sfence, 0);
    ok &= run_case("sfence.w.inval", MODE_U, b_sfence_w_inval, 0);
    ok &= run_case("csrr sstatus", MODE_U, b_sstatus, 0);
    ok &= run_case("wfi", MODE_U, b_wfi, 0);

    /* TSR, TW, TVM in S. */
    csr_set(mstatus, MSTATUS_TSR);
    ok &= run_case("sret TSR", MODE_S, b_sret, 0);
    csr_clear(mstatus, MSTATUS_TSR);
    csr_set(mstatus, MSTATUS_TW);
    ok &= run_case("wfi TW", MODE_S, b_wfi, 0);
    ok &= run_case("wrs.nto TW", MODE_S, b_wrs_nto, 0);
    csr_clear(mstatus, MSTATUS_TW);
    csr_set(mstatus, MSTATUS_TVM);
    ok &= run_case("sfence.vma TVM", MODE_S, b_sfence, 0);
    ok &= run_case("csrr satp TVM", MODE_S, b_satp, 0);
    csr_clear(mstatus, MSTATUS_TVM);

    /* Zicboz / Zicbom with menvcfg CBZE, CBCFE and CBIE clear. */
    ok &= run_case("cbo.zero CBZE=0", MODE_S, b_cbo_zero, 0);
    ok &= run_case("cbo.clean CBCFE=0", MODE_S, b_cbo_clean, 0);
    ok &= run_case("cbo.inval CBIE=0", MODE_S, b_cbo_inval, 0);
    ok &= run_case("cbo.zero CBZE=0", MODE_U, b_cbo_zero, 0);

    /* Counter gated by mcounteren. */
    ok &= run_case("rdcycle CY=0", MODE_S, b_rdcycle, 0);
    ok &= run_case("rdcycle CY=0", MODE_U, b_rdcycle, 0);

    /* Delegated to S: stval gets the bits, mtval is untouched. */
    csr_write(medeleg, 1ul << CAUSE_ILLEGAL);
    ok &= run_case("csrr mscratch", MODE_S, b_mscratch, 1);
    ok &= run_case("custom-0", MODE_U, b_custom0, 1);
    ok &= run_case("c.addi4spn imm=0", MODE_U, b_c_addi4spn0, 1);
    ok &= run_case("c.sh bit6", MODE_S, b_c_sh_res, 1);
    ok &= run_case("mret", MODE_S, b_mret, 1);
    csr_set(mstatus, MSTATUS_TVM);
    ok &= run_case("sfence.vma TVM", MODE_S, b_sfence, 1);
    csr_clear(mstatus, MSTATUS_TVM);
    csr_write(medeleg, 0);

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
