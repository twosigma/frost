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
 * Svinval directed test: sinval.vma, sfence.w.inval, and sfence.inval.ir.
 *
 * Checks:
 *   - Every (rs1, rs2) form of sinval.vma invalidates the same DTLB and ITLB
 *     entries as sfence.vma with the same operands and spares unrelated pages,
 *     other ASIDs, and global pages as ratified;
 *   - Batched PTE updates bracketed by sfence.w.inval ... sinval.vma ...
 *     sfence.inval.ir take effect for both data and instruction translations
 *     while sparing untouched entries;
 *   - All three instructions execute legally in M-mode (with mstatus.TVM clear
 *     or set) and in S-mode with mstatus.TVM clear;
 *   - With mstatus.TVM = 1 in S-mode, sinval.vma raises illegal-instruction
 *     (leaving resident TLB entries intact), while sfence.w.inval and
 *     sfence.inval.ir do not trap;
 *   - In U-mode, all three raise illegal-instruction (taken in M-mode or
 *     delegated to S-mode) with the faulting instruction word in xtval;
 *   - Nonzero rd on sinval.vma, nonzero rs1 or rd on sfence.w.inval or
 *     sfence.inval.ir, and unallocated rs2 values in funct7 = 0x0C raise
 *     illegal-instruction in every privilege mode.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

#define PT_RA 0x81200000ul
#define PT_RB 0x81203000ul
#define PT_RC 0x81206000ul
#define PA_XA 0x81210000ul
#define PA_XB 0x81211000ul
#define PA_XC 0x81212000ul
#define PA_XA2 0x81213000ul
#define PA_G 0x81214000ul
#define PA_CA 0x81215000ul
#define PA_CB 0x81216000ul
#define PA_CA2 0x81217000ul
#define PA_YA 0x81218000ul
#define PA_YA2 0x81219000ul

#define VA_X 0xC0000000ul
#define VA_G 0xC0001000ul
#define VA_CODE 0xC0002000ul
#define VA_Y 0xC0003000ul

#define PTE_V 0x001ul
#define PTE_R 0x002ul
#define PTE_W 0x004ul
#define PTE_X 0x008ul
#define PTE_G 0x020ul
#define PTE_A 0x040ul
#define PTE_D 0x080ul
#define PTE_PPN(pa) (((pa) >> 12) << 10)

#define SATP(asid, root) ((8ul << 60) | ((unsigned long) (asid) << 44) | ((root) >> 12))

#define CAUSE_ILLEGAL 2ul
#define CAUSE_ECALL_U 8ul
#define CAUSE_ECALL_S 9ul
#define CAUSE_ECALL_M 11ul

#define MSTATUS_TVM (1ul << 20)

/* Exact 32-bit Svinval encodings so the test builds with any -march.
 * Register numbers used in the assembly bodies:
 *   x0 = 0, s0 = 8, a6 = 16, a7 = 17, s2 = 18, s3 = 19, s10 = 26. */
#define SINVAL_ALL_BITS 0x16000073ul
#define SINVAL_ASID_A6_BITS 0x17000073ul
#define SINVAL_ASID_A7_BITS 0x17100073ul
#define SINVAL_S0_X0_BITS 0x16040073ul
#define SINVAL_S0_A6_BITS 0x17040073ul
#define SINVAL_S0_A7_BITS 0x17140073ul
#define SINVAL_S2_X0_BITS 0x16090073ul
#define SINVAL_S2_A6_BITS 0x17090073ul
#define SINVAL_S3_A6_BITS 0x17098073ul
#define SINVAL_S10_A6_BITS 0x170D0073ul
#define SFENCE_W_INVAL_BITS 0x18000073ul
#define SFENCE_INVAL_IR_BITS 0x18100073ul

#define SINVAL_BAD_RD_BITS 0x160000F3ul
#define SFENCE_W_BAD_RS1_BITS 0x18008073ul
#define SFENCE_W_BAD_RD_BITS 0x180000F3ul
#define SFENCE_IR_BAD_RS1_BITS 0x18108073ul
#define SFENCE_IR_BAD_RD_BITS 0x181000F3ul
#define SFENCE_INVAL_RS2_2_BITS 0x18200073ul

#define STR1(x) #x
#define STR(x) STR1(x)
#define WORD_INSN(bits) "    .word " STR(bits) "\n"

#define NRES 80

volatile unsigned long g_res[NRES];
volatile unsigned long g_bad_cause;
volatile unsigned long g_msave[14];
volatile unsigned long g_satp[6];

static volatile unsigned long g_trap_cause;
static volatile unsigned long g_trap_tval;
static volatile unsigned long g_trap_from_s;

void svinval_s_body(void);
void run_s_body(void);
void svinval_vm_trap_handler(void);
void svinval_priv_m_handler(void);
void svinval_priv_s_handler(void);

/* M-mode handler for the selective-TLB phase: S-mode ecall (cause 9) returns to
 * the M continuation in mscratch; any unexpected fault records mcause first. */
__asm__(".section .text\n"
        ".balign 4\n"
        ".global svinval_vm_trap_handler\n"
        "svinval_vm_trap_handler:\n"
        "    csrr t0, mcause\n"
        "    li   t1, 9\n"
        "    beq  t0, t1, 2f\n"
        "    la   t1, g_bad_cause\n"
        "    sd   t0, 0(t1)\n"
        "2:  csrr t0, mscratch\n"
        "    csrw mepc, t0\n"
        "    li   t0, 0x1800\n"
        "    csrs mstatus, t0\n"
        "    mret\n");

/* Enter svinval_s_body in S-mode with registers preloaded; return on ecall. */
__asm__(".section .text\n"
        ".balign 4\n"
        ".global run_s_body\n"
        "run_s_body:\n"
        "    la   t0, g_msave\n"
        "    sd   ra, 0(t0)\n"
        "    sd   sp, 8(t0)\n"
        "    sd   s0, 16(t0)\n"
        "    sd   s1, 24(t0)\n"
        "    sd   s2, 32(t0)\n"
        "    sd   s3, 40(t0)\n"
        "    sd   s4, 48(t0)\n"
        "    sd   s5, 56(t0)\n"
        "    sd   s6, 64(t0)\n"
        "    sd   s7, 72(t0)\n"
        "    sd   s8, 80(t0)\n"
        "    sd   s9, 88(t0)\n"
        "    sd   s10, 96(t0)\n"
        "    sd   s11, 104(t0)\n"
        "    la   t0, 9f\n"
        "    csrw mscratch, t0\n"
        "    la   t0, svinval_s_body\n"
        "    csrw mepc, t0\n"
        "    li   t0, 0x1800\n"
        "    csrc mstatus, t0\n"
        "    li   t0, 0x0800\n"
        "    csrs mstatus, t0\n"
        "    li   s0, 0xC0000000\n"
        "    la   s1, g_res\n"
        "    li   s2, 0xC0001000\n"
        "    li   s3, 0xC0002000\n"
        "    li   s10, 0xC0003000\n"
        "    la   t0, g_satp\n"
        "    ld   s4, 0(t0)\n"
        "    ld   s5, 8(t0)\n"
        "    ld   s8, 32(t0)\n"
        "    ld   s9, 40(t0)\n"
        "    mret\n"
        "9:  la   t0, g_msave\n"
        "    ld   ra, 0(t0)\n"
        "    ld   sp, 8(t0)\n"
        "    ld   s0, 16(t0)\n"
        "    ld   s1, 24(t0)\n"
        "    ld   s2, 32(t0)\n"
        "    ld   s3, 40(t0)\n"
        "    ld   s4, 48(t0)\n"
        "    ld   s5, 56(t0)\n"
        "    ld   s6, 64(t0)\n"
        "    ld   s7, 72(t0)\n"
        "    ld   s8, 80(t0)\n"
        "    ld   s9, 88(t0)\n"
        "    ld   s10, 96(t0)\n"
        "    ld   s11, 104(t0)\n"
        "    ret\n");

#define LD(base, v, w)                                                                             \
    "    csrr t0, 0xC06\n"                                                                         \
    "    ld   a0, 0(" base ")\n"                                                                   \
    "    csrr t1, 0xC06\n"                                                                         \
    "    sub  t1, t1, t0\n"                                                                        \
    "    sd   a0, " #v "*8(s1)\n"                                                                  \
    "    sd   t1, " #w "*8(s1)\n"

#define CALL(v, w)                                                                                 \
    "    csrr t0, 0xC05\n"                                                                         \
    "    jalr t6, 0(s3)\n"                                                                         \
    "    csrr t1, 0xC05\n"                                                                         \
    "    sub  t1, t1, t0\n"                                                                        \
    "    sd   a0, " #v "*8(s1)\n"                                                                  \
    "    sd   t1, " #w "*8(s1)\n"

/* clang-format off */
__asm__(".section .text\n"
        ".balign 4\n"
        ".global svinval_s_body\n"
        ".option push\n"
        ".option norvc\n"
        "svinval_s_body:\n"
        "    li   a6, 1\n"
        "    li   a7, 2\n"
        /* Populate A (ASID 1: VA_X, VA_G, VA_Y) and B (ASID 2: VA_X). */
        "    csrw satp, s4\n"
        WORD_INSN(SINVAL_ALL_BITS)
        LD("s0", 0, 1)
        LD("s2", 2, 3)
        LD("s10", 4, 5)
        "    csrw satp, s5\n"
        LD("s0", 6, 7)
        LD("s2", 8, 9)
        /* 1. sinval.vma x0, a7 (ASID 2 only): spares A's VA_X, A's VA_Y, and
         *    global VA_G; flushes B's VA_X. */
        "    csrw satp, s4\n"
        WORD_INSN(SINVAL_ASID_A7_BITS)
        LD("s0", 10, 11)
        LD("s10", 12, 13)
        LD("s2", 14, 15)
        "    csrw satp, s5\n"
        LD("s0", 16, 17)
        /* 2. sinval.vma s0, a7 (VA_X in ASID 2): spares A's VA_X, A's VA_Y, and
         *    global VA_G; flushes B's VA_X. */
        "    csrw satp, s4\n"
        WORD_INSN(SINVAL_S0_A7_BITS)
        LD("s0", 18, 19)
        LD("s10", 20, 21)
        LD("s2", 22, 23)
        "    csrw satp, s5\n"
        LD("s0", 24, 25)
        /* 3. sinval.vma s0, a6 (VA_X in ASID 1): flushes A's VA_X while sparing
         *    A's other page VA_Y, B's VA_X, and global VA_G. */
        "    csrw satp, s4\n"
        WORD_INSN(SINVAL_S0_A6_BITS)
        LD("s10", 26, 27)
        LD("s2", 28, 29)
        "    csrw satp, s5\n"
        LD("s0", 30, 31)
        "    csrw satp, s4\n"
        LD("s0", 32, 33)
        /* 4. sinval.vma s0, x0 (VA_X in all ASIDs): flushes VA_X in both A and
         *    B while sparing A's VA_Y and global VA_G. */
        WORD_INSN(SINVAL_S0_X0_BITS)
        LD("s10", 34, 35)
        LD("s2", 36, 37)
        LD("s0", 38, 39)
        "    csrw satp, s5\n"
        LD("s0", 40, 41)
        /* 5. Global page: sinval.vma s2, a6 spares VA_G; sinval.vma s2, x0
         *    flushes VA_G. */
        "    csrw satp, s4\n"
        WORD_INSN(SINVAL_S2_A6_BITS)
        LD("s2", 42, 43)
        WORD_INSN(SINVAL_S2_X0_BITS)
        LD("s2", 44, 45)
        /* 6. Batched PTE update in A: rewrite l0[0] (VA_X -> PA_XA2) and l0[3]
         *    (VA_Y -> PA_YA2), bracketed by sfence.w.inval ... sinval.vma ...
         *    sfence.inval.ir. B's VA_X and global VA_G remain resident. */
        "    li   t2, 0x20484CC7\n" /* PTE_PPN(PA_XA2) | V R W A D */
        "    sd   t2, 0(s9)\n"
        "    li   t2, 0x204864C7\n" /* PTE_PPN(PA_YA2) | V R W A D */
        "    sd   t2, 24(s9)\n"
        WORD_INSN(SFENCE_W_INVAL_BITS)
        WORD_INSN(SINVAL_S0_A6_BITS)
        WORD_INSN(SINVAL_S10_A6_BITS)
        WORD_INSN(SFENCE_INVAL_IR_BITS)
        LD("s2", 46, 47)
        "    csrw satp, s5\n"
        LD("s0", 48, 49)
        "    csrw satp, s4\n"
        LD("s0", 50, 51)
        LD("s10", 52, 53)
        /* 7. ASID 0x1FF (top of 9-bit ASID): populate C, switch back to A, then
         *    invalidate C with sinval.vma x0, t3 (t3 = 0x1FF). */
        "    csrw satp, s8\n"
        LD("s0", 54, 55)
        "    csrw satp, s4\n"
        LD("s0", 56, 57)
        "    li   t3, 0x1FF\n"
        "    .word 0x17C00073\n" /* sinval.vma x0, t3 (x28 = 28 -> 0x17C00073) */
        LD("s0", 58, 59)
        "    csrw satp, s8\n"
        LD("s0", 60, 61)
        /* 8. ITLB selective invalidation and batched code-PTE update: populate
         *    VA_CODE in A and B, rewrite A's l0[2] -> PA_CA2, bracket with
         *    sfence.w.inval + sinval.vma s3, a6 + sfence.inval.ir; B's code
         *    entry stays resident while A walks and fetches the new code page. */
        "    csrw satp, s4\n"
        WORD_INSN(SINVAL_ALL_BITS)
        CALL(62, 63)
        "    csrw satp, s5\n"
        CALL(64, 65)
        "    csrw satp, s4\n"
        CALL(66, 67)
        "    li   t2, 0x20485C4B\n" /* PTE_PPN(PA_CA2) | V R X A */
        "    sd   t2, 16(s9)\n"
        WORD_INSN(SFENCE_W_INVAL_BITS)
        WORD_INSN(SINVAL_S3_A6_BITS)
        WORD_INSN(SFENCE_INVAL_IR_BITS)
        "    csrw satp, s5\n"
        CALL(68, 69)
        "    csrw satp, s4\n"
        CALL(70, 71)
        /* 9. sinval.vma x0, x0 flushes all resident entries (A, B, global).
         *    Warm VA_X and VA_G first (step 8 started with sinval.vma x0, x0). */
        "    ld   t0, 0(s0)\n"
        "    ld   t0, 0(s2)\n"
        LD("s0", 72, 73)
        LD("s2", 74, 75)
        WORD_INSN(SINVAL_ALL_BITS)
        LD("s0", 76, 77)
        LD("s2", 78, 79)
        "    ecall\n"
        ".option pop\n");
/* clang-format on */

/* Trap handlers for the privilege, TVM, delegation, and reserved-field phase.
 * M-mode handler returns directly to the M continuation in mscratch.
 * Delegated S-mode handler records scause/stval and ecalls back to M-mode. */
__asm__(".section .text\n"
        ".balign 4\n"
        ".global svinval_priv_m_handler\n"
        "svinval_priv_m_handler:\n"
        "    csrr t0, mcause\n"
        "    li   t1, 9\n"
        "    la   t2, g_trap_from_s\n"
        "    ld   t3, 0(t2)\n"
        "    bnez t3, 1f\n"
        "    la   t2, g_trap_cause\n"
        "    sd   t0, 0(t2)\n"
        "    csrr t0, mtval\n"
        "    la   t2, g_trap_tval\n"
        "    sd   t0, 0(t2)\n"
        "1:  csrr t0, mscratch\n"
        "    csrw mepc, t0\n"
        "    li   t0, 0x1800\n"
        "    csrs mstatus, t0\n"
        "    mret\n"

        ".balign 4\n"
        ".global svinval_priv_s_handler\n"
        "svinval_priv_s_handler:\n"
        "    csrr t0, scause\n"
        "    la   t1, g_trap_cause\n"
        "    sd   t0, 0(t1)\n"
        "    csrr t0, stval\n"
        "    la   t1, g_trap_tval\n"
        "    sd   t0, 0(t1)\n"
        "    li   t0, 1\n"
        "    la   t1, g_trap_from_s\n"
        "    sd   t0, 0(t1)\n"
        "    ecall\n");

#define PROBE_BODY(name, word_bits)                                                                \
    __attribute__((naked, aligned(4))) static void name(void)                                      \
    {                                                                                              \
        __asm__ volatile(".option push\n"                                                          \
                         ".option norvc\n" WORD_INSN(word_bits) "    ecall\n"                      \
                                                                "    j .\n"                        \
                                                                ".option pop\n");                  \
    }

PROBE_BODY(probe_sinval_all, SINVAL_ALL_BITS)
PROBE_BODY(probe_sinval_s0_a6, SINVAL_S0_A6_BITS)
PROBE_BODY(probe_sfence_w_inval, SFENCE_W_INVAL_BITS)
PROBE_BODY(probe_sfence_inval_ir, SFENCE_INVAL_IR_BITS)
PROBE_BODY(probe_sinval_bad_rd, SINVAL_BAD_RD_BITS)
PROBE_BODY(probe_sfence_w_bad_rs1, SFENCE_W_BAD_RS1_BITS)
PROBE_BODY(probe_sfence_w_bad_rd, SFENCE_W_BAD_RD_BITS)
PROBE_BODY(probe_sfence_ir_bad_rs1, SFENCE_IR_BAD_RS1_BITS)
PROBE_BODY(probe_sfence_ir_bad_rd, SFENCE_IR_BAD_RD_BITS)
PROBE_BODY(probe_sfence_inval_rs2_2, SFENCE_INVAL_RS2_2_BITS)

/* In S-mode with satp active and VA_X already resident: run probe under TVM = 1
 * (delegated to S-mode, where stvec skips the trapping 4-byte instruction) or
 * directly, then measure DTLB walks for a load of VA_X. Used to confirm that a
 * trapped sinval.vma under TVM = 1 leaves the TLB untouched while
 * sfence.w.inval and sfence.inval.ir retire cleanly under TVM = 1. */
static volatile unsigned long g_tvm_walks;
static volatile unsigned long g_tvm_val;

void svinval_s_skip_handler(void);
void svinval_tvm_s_probe(void);

__asm__(".section .text\n"
        ".balign 4\n"
        ".global svinval_s_skip_handler\n"
        "svinval_s_skip_handler:\n"
        "    csrr t0, scause\n"
        "    la   t1, g_trap_cause\n"
        "    sd   t0, 0(t1)\n"
        "    csrr t0, stval\n"
        "    la   t1, g_trap_tval\n"
        "    sd   t0, 0(t1)\n"
        "    csrr t0, sepc\n"
        "    addi t0, t0, 4\n"
        "    csrw sepc, t0\n"
        "    sret\n"

        ".balign 4\n"
        ".global svinval_tvm_s_probe\n"
        ".option push\n"
        ".option norvc\n"
        "svinval_tvm_s_probe:\n"
        /* Warm VA_X while TVM is still 1 (satp was loaded in M-mode). */
        "    li   s0, 0xC0000000\n"
        "    ld   t0, 0(s0)\n"
        /* Attempt sinval.vma x0, x0 under TVM = 1: traps to S-mode skip handler,
         * which advances sepc without flushing the TLB. */
        WORD_INSN(SINVAL_ALL_BITS)
        /* sfence.w.inval and sfence.inval.ir must NOT trap under TVM = 1. */
        WORD_INSN(SFENCE_W_INVAL_BITS) WORD_INSN(SFENCE_INVAL_IR_BITS)
        /* Reload VA_X and count DTLB walks: must still hit with 0 walks. */
        "    csrr t0, 0xC06\n"
        "    ld   t2, 0(s0)\n"
        "    csrr t1, 0xC06\n"
        "    sub  t1, t1, t0\n"
        "    la   t0, g_tvm_walks\n"
        "    sd   t1, 0(t0)\n"
        "    la   t0, g_tvm_val\n"
        "    sd   t2, 0(t0)\n"
        "    ecall\n"
        ".option pop\n");

static unsigned long run_probe(unsigned long mpp, int tvm, int deleg_illegal, void (*body)(void))
{
    g_trap_cause = ~0ul;
    g_trap_tval = ~0ul;
    g_trap_from_s = 0;

    csr_write(medeleg, deleg_illegal ? (1ul << CAUSE_ILLEGAL) : 0ul);
    csr_write(stvec, (unsigned long) &svinval_priv_s_handler);
    if (tvm)
        csr_set(mstatus, MSTATUS_TVM);
    else
        csr_clear(mstatus, MSTATUS_TVM);

    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "slli t0, %0, 11\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %1\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(mpp), "r"((unsigned long) body)
                     : "t0", "t1", "t2", "t3", "memory");

    csr_clear(mstatus, MSTATUS_TVM);
    csr_write(medeleg, 0);
    return g_trap_cause;
}

static unsigned long g_checks_run;

static int check(const char *name, unsigned long got, unsigned long want)
{
    int ok = got == want;
    g_checks_run++;
    if (!ok)
        uart_printf("[FAIL] %s got=0x%lx want=0x%lx\n", name, got, want);
    return ok;
}

static int walked(const char *name, unsigned long walks, int expect_walk)
{
    int ok = expect_walk ? walks >= 1 : walks == 0;
    g_checks_run++;
    if (!ok)
        uart_printf("[FAIL] %s walks=%lu expected %s\n", name, walks, expect_walk ? ">= 1" : "0");
    return ok;
}

static int check_probe(const char *name,
                       unsigned long mpp,
                       int tvm,
                       int deleg,
                       void (*body)(void),
                       unsigned long want_cause,
                       unsigned long want_tval,
                       unsigned long want_from_s)
{
    unsigned long cause = run_probe(mpp, tvm, deleg, body);
    int ok = (cause == want_cause) && (g_trap_from_s == want_from_s);
    if (want_cause == CAUSE_ILLEGAL)
        ok = ok && (g_trap_tval == want_tval);
    g_checks_run++;
    if (!ok)
        uart_printf(
            "[FAIL] %s cause=%lu(want %lu) tval=0x%lx(want 0x%lx) s_handler=%lu(want %lu)\n",
            name,
            cause,
            want_cause,
            g_trap_tval,
            want_tval,
            g_trap_from_s,
            want_from_s);
    return ok;
}

/* Identity gigapages (global, executable/readable/writable for M/S, plus U on
 * bare runs; U-mode probes below run with satp = 0), plus VA_X, VA_G, VA_CODE,
 * and VA_Y under 0xC0000000. */
static void
build_space(unsigned long root, unsigned long x_pa, unsigned long y_pa, unsigned long code_pa)
{
    volatile unsigned long *r = (volatile unsigned long *) root;
    volatile unsigned long *l1 = (volatile unsigned long *) (root + 0x1000);
    volatile unsigned long *l0 = (volatile unsigned long *) (root + 0x2000);

    for (int i = 0; i < 512; i++) {
        r[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    r[0] = PTE_PPN(0x00000000ul) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_G | PTE_A | PTE_D;
    r[1] = PTE_PPN(0x40000000ul) | PTE_V | PTE_R | PTE_W | PTE_G | PTE_A | PTE_D;
    r[2] = PTE_PPN(0x80000000ul) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_G | PTE_A | PTE_D;
    r[3] = PTE_PPN(root + 0x1000) | PTE_V;
    l1[0] = PTE_PPN(root + 0x2000) | PTE_V;
    l0[0] = PTE_PPN(x_pa) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    l0[1] = PTE_PPN(PA_G) | PTE_V | PTE_R | PTE_W | PTE_G | PTE_A | PTE_D;
    if (code_pa)
        l0[2] = PTE_PPN(code_pa) | PTE_V | PTE_R | PTE_X | PTE_A;
    if (y_pa)
        l0[3] = PTE_PPN(y_pa) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
}

int main(void)
{
    int ok = 1;
    g_checks_run = 0;

    g_satp[0] = SATP(1, PT_RA);
    g_satp[1] = SATP(2, PT_RB);
    g_satp[4] = SATP(0x1FF, PT_RC);
    g_satp[5] = PT_RA + 0x2000;

    build_space(PT_RA, PA_XA, PA_YA, PA_CA);
    build_space(PT_RB, PA_XB, 0, PA_CB);
    build_space(PT_RC, PA_XC, 0, 0);

    *(volatile unsigned long *) PA_XA = 0xA1;
    *(volatile unsigned long *) PA_XB = 0xB2;
    *(volatile unsigned long *) PA_XC = 0xC4;
    *(volatile unsigned long *) PA_XA2 = 0xA3;
    *(volatile unsigned long *) PA_G = 0x6C;
    *(volatile unsigned long *) PA_YA = 0xD5;
    *(volatile unsigned long *) PA_YA2 = 0xD9;
    /* li a0, <imm> ; jr t6 */
    ((volatile uint32_t *) PA_CA)[0] = 0x01100513;
    ((volatile uint32_t *) PA_CA)[1] = 0x000F8067;
    ((volatile uint32_t *) PA_CB)[0] = 0x02200513;
    ((volatile uint32_t *) PA_CB)[1] = 0x000F8067;
    ((volatile uint32_t *) PA_CA2)[0] = 0x03300513;
    ((volatile uint32_t *) PA_CA2)[1] = 0x000F8067;
    __asm__ volatile("fence rw, rw\n fence.i\n" ::: "memory");

    /* Enable ITLB walk (HPM5) and DTLB walk (HPM6) counters for S-mode reads. */
    csr_write_imm(0x325, 5);
    csr_write_imm(0x326, 6);
    csr_write_imm(0x320, 0);
    csr_write_imm(0x306, 0x7f);
    csr_write(medeleg, 0);
    g_bad_cause = 0;
    set_trap_handler(&svinval_vm_trap_handler);

    run_s_body();
    csr_write(satp, 0);

    ok &= check("vm-unexpected-trap", g_bad_cause, 0);
    ok &= check("0 A-x-cold-val", g_res[0], 0xA1);
    ok &= walked("1 A-x-cold-walk", g_res[1], 1);
    ok &= check("2 A-g-cold-val", g_res[2], 0x6C);
    ok &= walked("3 A-g-cold-walk", g_res[3], 1);
    ok &= check("4 A-y-cold-val", g_res[4], 0xD5);
    ok &= walked("5 A-y-cold-walk", g_res[5], 1);
    ok &= check("6 B-x-cold-val", g_res[6], 0xB2);
    ok &= walked("7 B-x-cold-walk", g_res[7], 1);
    ok &= check("8 B-g-shared-val", g_res[8], 0x6C);
    ok &= walked("9 B-g-shared-no-walk", g_res[9], 0);

    /* 1. sinval.vma x0, a7 (ASID 2) */
    ok &= check("10 sinval-asid2-A-x", g_res[10], 0xA1);
    ok &= walked("11 sinval-asid2-spares-A-x", g_res[11], 0);
    ok &= check("12 sinval-asid2-A-y", g_res[12], 0xD5);
    ok &= walked("13 sinval-asid2-spares-A-y", g_res[13], 0);
    ok &= check("14 sinval-asid2-g", g_res[14], 0x6C);
    ok &= walked("15 sinval-asid2-spares-global", g_res[15], 0);
    ok &= check("16 sinval-asid2-B-x", g_res[16], 0xB2);
    ok &= walked("17 sinval-asid2-flushes-B-x", g_res[17], 1);

    /* 2. sinval.vma s0, a7 (VA_X, ASID 2) */
    ok &= check("18 sinval-va-asid2-A-x", g_res[18], 0xA1);
    ok &= walked("19 sinval-va-asid2-spares-A-x", g_res[19], 0);
    ok &= check("20 sinval-va-asid2-A-y", g_res[20], 0xD5);
    ok &= walked("21 sinval-va-asid2-spares-A-y", g_res[21], 0);
    ok &= check("22 sinval-va-asid2-g", g_res[22], 0x6C);
    ok &= walked("23 sinval-va-asid2-spares-global", g_res[23], 0);
    ok &= check("24 sinval-va-asid2-B-x", g_res[24], 0xB2);
    ok &= walked("25 sinval-va-asid2-flushes-B-x", g_res[25], 1);

    /* 3. sinval.vma s0, a6 (VA_X, ASID 1): spares VA_Y in ASID 1, B's VA_X, VA_G */
    ok &= check("26 sinval-va-asid1-A-y", g_res[26], 0xD5);
    ok &= walked("27 sinval-va-asid1-spares-same-asid-other-va", g_res[27], 0);
    ok &= check("28 sinval-va-asid1-g", g_res[28], 0x6C);
    ok &= walked("29 sinval-va-asid1-spares-global", g_res[29], 0);
    ok &= check("30 sinval-va-asid1-B-x", g_res[30], 0xB2);
    ok &= walked("31 sinval-va-asid1-spares-B-x", g_res[31], 0);
    ok &= check("32 sinval-va-asid1-A-x", g_res[32], 0xA1);
    ok &= walked("33 sinval-va-asid1-flushes-A-x", g_res[33], 1);

    /* 4. sinval.vma s0, x0 (VA_X, all ASIDs) */
    ok &= check("34 sinval-va-all-A-y", g_res[34], 0xD5);
    ok &= walked("35 sinval-va-all-spares-other-va", g_res[35], 0);
    ok &= check("36 sinval-va-all-g", g_res[36], 0x6C);
    ok &= walked("37 sinval-va-all-spares-global-other-va", g_res[37], 0);
    ok &= check("38 sinval-va-all-A-x", g_res[38], 0xA1);
    ok &= walked("39 sinval-va-all-flushes-A-x", g_res[39], 1);
    ok &= check("40 sinval-va-all-B-x", g_res[40], 0xB2);
    ok &= walked("41 sinval-va-all-flushes-B-x", g_res[41], 1);

    /* 5. Global page with and without ASID */
    ok &= check("42 sinval-g-asid1-val", g_res[42], 0x6C);
    ok &= walked("43 sinval-g-asid1-spares-global", g_res[43], 0);
    ok &= check("44 sinval-g-all-val", g_res[44], 0x6C);
    ok &= walked("45 sinval-g-all-flushes-global", g_res[45], 1);

    /* 6. Batched PTE update with sfence.w.inval ... sinval.vma ... sfence.inval.ir */
    ok &= check("46 batch-g-val", g_res[46], 0x6C);
    ok &= walked("47 batch-spares-global", g_res[47], 0);
    ok &= check("48 batch-B-x-val", g_res[48], 0xB2);
    ok &= walked("49 batch-spares-B-x", g_res[49], 0);
    ok &= check("50 batch-A-x-updated", g_res[50], 0xA3);
    ok &= walked("51 batch-A-x-walked", g_res[51], 1);
    ok &= check("52 batch-A-y-updated", g_res[52], 0xD9);
    ok &= walked("53 batch-A-y-walked", g_res[53], 1);

    /* 7. ASID 0x1FF */
    ok &= check("54 C-x-cold", g_res[54], 0xC4);
    ok &= walked("55 C-x-cold-walk", g_res[55], 1);
    ok &= check("56 A-x-kept-across-C", g_res[56], 0xA3);
    ok &= walked("57 A-x-kept-no-walk", g_res[57], 0);
    ok &= check("58 A-x-spared-by-sinval-1ff", g_res[58], 0xA3);
    ok &= walked("59 A-x-spared-no-walk", g_res[59], 0);
    ok &= check("60 C-x-after-sinval-1ff", g_res[60], 0xC4);
    ok &= walked("61 C-x-flushed-by-sinval-1ff", g_res[61], 1);

    /* 8. ITLB selective invalidation and batched code PTE update */
    ok &= check("62 itlb-A-cold", g_res[62], 0x11);
    ok &= walked("63 itlb-A-cold-walk", g_res[63], 1);
    ok &= check("64 itlb-B-cold", g_res[64], 0x22);
    ok &= walked("65 itlb-B-cold-walk", g_res[65], 1);
    ok &= check("66 itlb-A-resident", g_res[66], 0x11);
    ok &= walked("67 itlb-A-resident-no-walk", g_res[67], 0);
    ok &= check("68 itlb-B-spared-by-A-batch", g_res[68], 0x22);
    ok &= walked("69 itlb-B-spared-no-walk", g_res[69], 0);
    ok &= check("70 itlb-A-updated", g_res[70], 0x33);
    ok &= walked("71 itlb-A-updated-walk", g_res[71], 1);

    /* 9. sinval.vma x0, x0 flushes all entries */
    ok &= check("72 pre-all-A-x", g_res[72], 0xA3);
    ok &= walked("73 pre-all-A-x-resident", g_res[73], 0);
    ok &= check("74 pre-all-g", g_res[74], 0x6C);
    ok &= walked("75 pre-all-g-resident", g_res[75], 0);
    ok &= check("76 post-all-A-x", g_res[76], 0xA3);
    ok &= walked("77 post-all-A-x-walk", g_res[77], 1);
    ok &= check("78 post-all-g", g_res[78], 0x6C);
    ok &= walked("79 post-all-g-walk", g_res[79], 1);

    /* 10. TVM = 1 in S-mode with live Sv39 translation: sinval.vma traps
     *     without flushing resident TLB entries, while sfence.w.inval and
     *     sfence.inval.ir retire cleanly under TVM = 1. */
    g_trap_cause = ~0ul;
    g_trap_tval = ~0ul;
    g_tvm_walks = ~0ul;
    g_tvm_val = ~0ul;
    set_trap_handler(&svinval_vm_trap_handler);
    csr_write(medeleg, 1ul << CAUSE_ILLEGAL);
    csr_write(stvec, (unsigned long) &svinval_s_skip_handler);
    csr_write(satp, SATP(1, PT_RA));
    csr_set(mstatus, MSTATUS_TVM);
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n"
                     "la   t0, svinval_tvm_s_probe\n"
                     "csrw mepc, t0\n"
                     "mret\n"
                     "1:\n" ::
                         : "t0", "t1", "t2", "s0", "memory");
    csr_clear(mstatus, MSTATUS_TVM);
    csr_write(satp, 0);
    csr_write(medeleg, 0);
    ok &= check("s-tvm-live-trap-cause", g_trap_cause, CAUSE_ILLEGAL);
    ok &= check("s-tvm-live-trap-stval", g_trap_tval, SINVAL_ALL_BITS);
    ok &= check("s-tvm-live-val", g_tvm_val, 0xA3);
    ok &= walked("s-tvm-trapped-sinval-keeps-tlb", g_tvm_walks, 0);

    /* 11. Privilege, TVM, delegation, and reserved-field matrix (satp = 0). */
    set_trap_handler(&svinval_priv_m_handler);

    /* M-mode: all three legal with TVM = 0 and TVM = 1. */
    for (int tvm = 0; tvm <= 1; tvm++) {
        ok &= check_probe(tvm ? "M-tvm1-sinval-all" : "M-tvm0-sinval-all",
                          3,
                          tvm,
                          0,
                          probe_sinval_all,
                          CAUSE_ECALL_M,
                          0,
                          0);
        ok &= check_probe(tvm ? "M-tvm1-sinval-va-asid" : "M-tvm0-sinval-va-asid",
                          3,
                          tvm,
                          0,
                          probe_sinval_s0_a6,
                          CAUSE_ECALL_M,
                          0,
                          0);
        ok &= check_probe(tvm ? "M-tvm1-sfence-w-inval" : "M-tvm0-sfence-w-inval",
                          3,
                          tvm,
                          0,
                          probe_sfence_w_inval,
                          CAUSE_ECALL_M,
                          0,
                          0);
        ok &= check_probe(tvm ? "M-tvm1-sfence-inval-ir" : "M-tvm0-sfence-inval-ir",
                          3,
                          tvm,
                          0,
                          probe_sfence_inval_ir,
                          CAUSE_ECALL_M,
                          0,
                          0);
    }

    /* S-mode, TVM = 0: all three legal. */
    ok &= check_probe("S-tvm0-sinval-all", 1, 0, 0, probe_sinval_all, CAUSE_ECALL_S, 0, 0);
    ok &= check_probe("S-tvm0-sinval-va-asid", 1, 0, 0, probe_sinval_s0_a6, CAUSE_ECALL_S, 0, 0);
    ok &= check_probe("S-tvm0-sfence-w-inval", 1, 0, 0, probe_sfence_w_inval, CAUSE_ECALL_S, 0, 0);
    ok &=
        check_probe("S-tvm0-sfence-inval-ir", 1, 0, 0, probe_sfence_inval_ir, CAUSE_ECALL_S, 0, 0);

    /* S-mode, TVM = 1: sinval.vma traps (undelegated and delegated); the two
     * fence forms still retire without trapping! */
    ok &= check_probe(
        "S-tvm1-sinval-all-m", 1, 1, 0, probe_sinval_all, CAUSE_ILLEGAL, SINVAL_ALL_BITS, 0);
    ok &= check_probe("S-tvm1-sinval-va-asid-s",
                      1,
                      1,
                      1,
                      probe_sinval_s0_a6,
                      CAUSE_ILLEGAL,
                      SINVAL_S0_A6_BITS,
                      1);
    ok &= check_probe(
        "S-tvm1-sfence-w-inval-legal", 1, 1, 0, probe_sfence_w_inval, CAUSE_ECALL_S, 0, 0);
    ok &= check_probe(
        "S-tvm1-sfence-inval-ir-legal", 1, 1, 0, probe_sfence_inval_ir, CAUSE_ECALL_S, 0, 0);

    /* U-mode: all three trap illegal-instruction (taken in M or delegated to S). */
    for (int deleg = 0; deleg <= 1; deleg++) {
        ok &= check_probe(deleg ? "U-deleg-sinval-all" : "U-m-sinval-all",
                          0,
                          0,
                          deleg,
                          probe_sinval_all,
                          CAUSE_ILLEGAL,
                          SINVAL_ALL_BITS,
                          (unsigned long) deleg);
        ok &= check_probe(deleg ? "U-deleg-sinval-va-asid" : "U-m-sinval-va-asid",
                          0,
                          0,
                          deleg,
                          probe_sinval_s0_a6,
                          CAUSE_ILLEGAL,
                          SINVAL_S0_A6_BITS,
                          (unsigned long) deleg);
        ok &= check_probe(deleg ? "U-deleg-sfence-w-inval" : "U-m-sfence-w-inval",
                          0,
                          0,
                          deleg,
                          probe_sfence_w_inval,
                          CAUSE_ILLEGAL,
                          SFENCE_W_INVAL_BITS,
                          (unsigned long) deleg);
        ok &= check_probe(deleg ? "U-deleg-sfence-inval-ir" : "U-m-sfence-inval-ir",
                          0,
                          0,
                          deleg,
                          probe_sfence_inval_ir,
                          CAUSE_ILLEGAL,
                          SFENCE_INVAL_IR_BITS,
                          (unsigned long) deleg);
    }

    /* Reserved register fields trap in every privilege mode (M=3, S=1, U=0). */
    static const unsigned long modes[3] = {3, 1, 0};
    for (int i = 0; i < 3; i++) {
        unsigned long mpp = modes[i];
        ok &= check_probe("reserved-sinval-rd",
                          mpp,
                          0,
                          0,
                          probe_sinval_bad_rd,
                          CAUSE_ILLEGAL,
                          SINVAL_BAD_RD_BITS,
                          0);
        ok &= check_probe("reserved-sfence-w-rs1",
                          mpp,
                          0,
                          0,
                          probe_sfence_w_bad_rs1,
                          CAUSE_ILLEGAL,
                          SFENCE_W_BAD_RS1_BITS,
                          0);
        ok &= check_probe("reserved-sfence-w-rd",
                          mpp,
                          0,
                          0,
                          probe_sfence_w_bad_rd,
                          CAUSE_ILLEGAL,
                          SFENCE_W_BAD_RD_BITS,
                          0);
        ok &= check_probe("reserved-sfence-ir-rs1",
                          mpp,
                          0,
                          0,
                          probe_sfence_ir_bad_rs1,
                          CAUSE_ILLEGAL,
                          SFENCE_IR_BAD_RS1_BITS,
                          0);
        ok &= check_probe("reserved-sfence-ir-rd",
                          mpp,
                          0,
                          0,
                          probe_sfence_ir_bad_rd,
                          CAUSE_ILLEGAL,
                          SFENCE_IR_BAD_RD_BITS,
                          0);
        ok &= check_probe("reserved-funct7-0c-rs2-2",
                          mpp,
                          0,
                          0,
                          probe_sfence_inval_rs2_2,
                          CAUSE_ILLEGAL,
                          SFENCE_INVAL_RS2_2_BITS,
                          0);
    }

    uart_printf("SVINVAL checks=%lu\n", g_checks_run);
    uart_puts(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    return ok ? 0 : 1;
}
