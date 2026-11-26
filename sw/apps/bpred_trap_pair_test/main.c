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
 * Directed test for fetch pairing and branch prediction around instructions
 * that unconditionally trap or return from a trap:
 *   - ebreak, ecall, and c.ebreak
 *   - mret, sret, and dret
 *   - wfi where it traps (S-mode with mstatus.TW=1, and U-mode)
 *   - reserved compressed encodings (0x8002, 0x0000, C.ADDIW x0, C.ADDI16SP 0,
 *     C.LWSP x0, and Zcb reserved unary encodings)
 *   - reserved 32-bit control/system encodings (OPC_BRANCH funct3=010/011,
 *     OPC_JALR funct3!=000, and reserved SYSTEM funct12)
 *
 * Exercises both halfword start positions, both instruction orders, static
 * predecoded instruction memory as well as L1I-refilled code pages, and both
 * cold and warm entries in the primary BTB, backing BTB, ITTAGE, and TAGE
 * tables. Any spurious fetch or pre-decode redirect targets an uncached ITLB
 * page and is caught through hardware ITLB walk and slot-2 prediction counters
 * alongside exact trap cause, epc, tval, and dead-slot retirement checks.
 */

#include "csr.h"
#include "trap.h"
#include "uart.h"

#include <stdint.h>

/* Physical pages in cached RAM used for page tables and dynamic code stubs. */
#define PT_TRAIN_ROOT 0x81200000ul
#define PT_PROBE_ROOT 0x81203000ul

#define PA_PROBE 0x81210000ul
#define PA_TRAIN 0x81211000ul
#define PA_TGT_A 0x81212000ul
#define PA_TGT_B 0x81213000ul
#define PA_UTEST 0x81214000ul
#define PA_STATIC_TRAIN 0x81215000ul

/* Canonical Sv39 virtual pages in VPN[2] = 3 (0xC0000000..0xC0008FFF). */
#define VA_PROBE 0xC0001000ul
#define VA_TGT_A 0xC0002000ul
#define VA_TGT_B 0xC0003000ul
#define VA_UTEST 0xC0004000ul
#define VA_STATIC 0xC0005000ul
#define VA_STATIC_TGT_A 0xC0006000ul
#define VA_STATIC_TGT_B 0xC0007000ul
#define VA_UTEST_TGT_A 0xC0008000ul

#define PTE_V 0x001ul
#define PTE_R 0x002ul
#define PTE_W 0x004ul
#define PTE_X 0x008ul
#define PTE_U 0x010ul
#define PTE_G 0x020ul
#define PTE_A 0x040ul
#define PTE_D 0x080ul
#define PTE_PPN(pa) (((pa) >> 12) << 10)

#define SATP_SV39(asid, root) ((8ul << 60) | ((uint64_t) (asid) << 44) | ((root) >> 12))

#define PRIV_U 0ul
#define PRIV_S 1ul
#define PRIV_M 3ul

#define MSTATUS_TW (1ul << 21)
#define MSTATUS_TSR (1ul << 22)

#define CAUSE_ILLEGAL 2ul
#define CAUSE_BREAKPOINT 3ul
#define CAUSE_ECALL_U 8ul
#define CAUSE_ECALL_S 9ul

/* 16-bit compressed encodings. */
#define C_NOP 0x0001u
#define C_ADDI_A0_1 0x0505u
#define C_ADDI_S11_1 0x0DB5u
#define C_EBREAK 0x9002u
#define C_JR_X0_RES 0x8002u
#define C_ADDI4SPN_0_RES 0x0000u
#define C_ADDIW_X0_RES 0x2001u
#define C_ADDI16SP_0_RES 0x6101u
#define C_LWSP_X0_RES 0x4002u
#define C_ZCB_RES 0x9C79u
#define C_JALR_T1 0x9302u
#define C_JR_RA 0x8082u

/* 32-bit native encodings. */
#define INSN_NOP 0x00000013u
#define INSN_ADDI_A0_1 0x00150513u
#define INSN_ADDI_S11_1 0x001D8D93u
#define INSN_EBREAK 0x00100073u
#define INSN_ECALL 0x00000073u
#define INSN_MRET 0x30200073u
#define INSN_SRET 0x10200073u
#define INSN_DRET 0x7B200073u
#define INSN_WFI 0x10500073u
#define INSN_SYS_RES 0x7FF00073u
#define INSN_JALR_T1 0x000300E7u
#define INSN_JALR_RES 0x000310E7u
#define INSN_RET 0x00008067u

#define MAX_FAIL_LOGS 8u
#define SPEC_BATCH 7u

extern char static_probe_page[];
extern void trap_pair_handler(void);
extern void probe_m_return_pad(void);
extern uint64_t run_priv_probe(uint64_t entry_va,
                               uint64_t arg_t1,
                               uint64_t arg_a0,
                               uint64_t priv_mpp,
                               uint64_t satp_val,
                               uint64_t mstatus_or,
                               uint64_t flush_va_a,
                               uint64_t flush_va_b);

volatile uint64_t g_trap_scratch[4];
volatile uint64_t g_host_save[16];
volatile uint64_t g_resume_pc;
volatile uint64_t g_sret_epc;
volatile uint64_t g_trap_count;
volatile uint64_t g_last_cause;
volatile uint64_t g_last_epc;
volatile uint64_t g_last_tval;
volatile uint64_t g_before_walks;
volatile uint64_t g_after_walks;
volatile uint64_t g_before_s2_pred;
volatile uint64_t g_after_s2_pred;
volatile uint64_t g_after_canary;

volatile uint32_t g_has_mperf;
static uint32_t g_total_checks;
static uint32_t g_failed_checks;

static uint32_t enc_jal(uint32_t rd, int32_t offset)
{
    uint32_t u = (uint32_t) offset;
    uint32_t imm20 = (u >> 20) & 1u;
    uint32_t imm10_1 = (u >> 1) & 0x3FFu;
    uint32_t imm11 = (u >> 11) & 1u;
    uint32_t imm19_12 = (u >> 12) & 0xFFu;
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | (imm19_12 << 12) | (rd << 7) | 0x6Fu;
}

static uint32_t enc_branch(uint32_t funct3, uint32_t rs1, uint32_t rs2, int32_t offset)
{
    uint32_t u = (uint32_t) offset;
    uint32_t imm12 = (u >> 12) & 1u;
    uint32_t imm11 = (u >> 11) & 1u;
    uint32_t imm10_5 = (u >> 5) & 0x3Fu;
    uint32_t imm4_1 = (u >> 1) & 0xFu;
    return (imm12 << 31) | (imm10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) |
           (imm4_1 << 8) | (imm11 << 7) | 0x63u;
}

static uint16_t enc_c_j(int32_t offset)
{
    uint32_t u = (uint32_t) offset;
    uint32_t b11 = (u >> 11) & 1u;
    uint32_t b4 = (u >> 4) & 1u;
    uint32_t b9_8 = (u >> 8) & 3u;
    uint32_t b10 = (u >> 10) & 1u;
    uint32_t b6 = (u >> 6) & 1u;
    uint32_t b7 = (u >> 7) & 1u;
    uint32_t b3_1 = (u >> 1) & 7u;
    uint32_t b5 = (u >> 5) & 1u;
    return (uint16_t) ((0x5u << 13) | (b11 << 12) | (b4 << 11) | (b9_8 << 9) | (b10 << 8) |
                       (b6 << 7) | (b7 << 6) | (b3_1 << 3) | (b5 << 2) | 0x1u);
}

static uint16_t enc_c_bnez_a0(int32_t offset)
{
    uint32_t u = (uint32_t) offset;
    uint32_t b8 = (u >> 8) & 1u;
    uint32_t b4_3 = (u >> 3) & 3u;
    uint32_t b7_6 = (u >> 6) & 3u;
    uint32_t b2_1 = (u >> 1) & 3u;
    uint32_t b5 = (u >> 5) & 1u;
    return (uint16_t) ((0x7u << 13) | (b8 << 12) | (b4_3 << 10) | (0x2u << 7) | (b7_6 << 5) |
                       (b2_1 << 3) | (b5 << 2) | 0x1u);
}

static void put16(uint64_t page_pa, uint32_t off, uint16_t val)
{
    volatile uint16_t *p = (volatile uint16_t *) (uintptr_t) (page_pa + off);
    *p = val;
}

static void put32(uint64_t page_pa, uint32_t off, uint32_t val)
{
    put16(page_pa, off, (uint16_t) (val & 0xFFFFu));
    put16(page_pa, off + 2u, (uint16_t) (val >> 16));
}

static void fill_nops(uint64_t page_pa, uint32_t start_off, uint32_t end_off)
{
    const uint32_t c_nop_pair = ((uint32_t) C_NOP << 16) | C_NOP;
    for (uint32_t w = start_off; w < end_off; w += 4u) {
        *(volatile uint32_t *) (uintptr_t) (page_pa + w) = c_nop_pair;
    }
}

/* Write a 16-trip history-priming loop at [primer_off, primer_off + 16)
 * inside page_pa that jumps to site_off. */
static void write_primer_a(uint64_t page_pa, uint32_t primer_off, uint32_t site_off)
{
    put32(page_pa, primer_off + 0u, (16u << 20) | (28u << 7) | 0x13u);
    put32(page_pa, primer_off + 4u, (0xFFFu << 20) | (28u << 15) | (28u << 7) | 0x13u);
    put32(page_pa, primer_off + 8u, enc_branch(1u, 28u, 0u, -4));
    put32(
        page_pa, primer_off + 12u, enc_jal(0u, (int32_t) site_off - (int32_t) (primer_off + 12u)));
}

/* Alternate history primer so ITTAGE/TAGE entries trained under primer A stay
 * distinct from BTB overwrites under primer B. */
static void write_primer_b(uint64_t page_pa, uint32_t primer_off, uint32_t site_off)
{
    put32(page_pa, primer_off + 0u, (16u << 20) | (28u << 7) | 0x13u);
    put32(page_pa, primer_off + 4u, (0xFFFu << 20) | (28u << 15) | (28u << 7) | 0x13u);
    put32(page_pa, primer_off + 8u, enc_branch(0u, 0u, 0u, 4));
    put32(page_pa, primer_off + 12u, enc_branch(1u, 28u, 0u, -8));
    put32(
        page_pa, primer_off + 16u, enc_jal(0u, (int32_t) site_off - (int32_t) (primer_off + 16u)));
}

/* Write a direct-mapped fast-BTB evictor at (branch_off ^ 0x400) inside page_pa. */
static uint32_t write_btb_evictor(uint64_t page_pa, uint32_t branch_off)
{
    uint32_t ev_off = (branch_off ^ 0x400u) & 0xFFEu;
    put32(page_pa, ev_off, enc_jal(0u, 4));
    put32(page_pa, ev_off + 4u, INSN_ECALL);
    return ev_off;
}

static void init_target_pages(void)
{
    static const uint64_t code_pages[] = {
        PA_PROBE,
        PA_TRAIN,
        PA_TGT_A,
        PA_TGT_B,
        PA_UTEST,
        PA_STATIC_TRAIN,
    };
    for (uint32_t i = 0; i < (uint32_t) (sizeof(code_pages) / sizeof(code_pages[0])); i++) {
        fill_nops(code_pages[i], 0u, 0x1000u);
    }

    put32(PA_PROBE, 0u, INSN_ECALL);
    put32(PA_PROBE, 0x040u, INSN_ECALL);
    put32(PA_TRAIN, 0u, INSN_ECALL);
    put32(PA_TRAIN, 0x040u, INSN_ECALL);
    put32(PA_UTEST, 0u, INSN_ECALL);
    put32(PA_UTEST, 0x040u, INSN_ECALL);

    put32(PA_TGT_A, 0u, (0x21u << 20) | (10u << 15) | (10u << 7) | 0x13u);
    put32(PA_TGT_A, 4u, INSN_RET);
    put32(PA_TGT_A, 0x40u, INSN_ECALL);

    put32(PA_TGT_B, 0u, (0x37u << 20) | (10u << 15) | (10u << 7) | 0x13u);
    put32(PA_TGT_B, 4u, INSN_RET);
    put32(PA_TGT_B, 0x40u, INSN_ECALL);
    __asm__ volatile("fence rw, rw\n fence.i\n" ::: "memory");
}

static void
build_address_space(uint64_t root_pa, uint64_t probe_pa, uint64_t utest_pa, uint64_t static_pa)
{
    volatile uint64_t *r = (volatile uint64_t *) (uintptr_t) root_pa;
    volatile uint64_t *l1 = (volatile uint64_t *) (uintptr_t) (root_pa + 0x1000ul);
    volatile uint64_t *l0 = (volatile uint64_t *) (uintptr_t) (root_pa + 0x2000ul);

    for (uint32_t i = 0; i < 512u; i++) {
        r[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    r[0] = PTE_PPN(0x00000000ul) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_G | PTE_A | PTE_D;
    r[1] = PTE_PPN(0x40000000ul) | PTE_V | PTE_R | PTE_W | PTE_G | PTE_A | PTE_D;
    r[2] = PTE_PPN(0x80000000ul) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_G | PTE_A | PTE_D;
    r[3] = PTE_PPN(root_pa + 0x1000ul) | PTE_V;
    l1[0] = PTE_PPN(root_pa + 0x2000ul) | PTE_V;

    l0[1] = PTE_PPN(probe_pa) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    l0[2] = PTE_PPN(PA_TGT_A) | PTE_V | PTE_R | PTE_X | PTE_A;
    l0[3] = PTE_PPN(PA_TGT_B) | PTE_V | PTE_R | PTE_X | PTE_A;
    l0[4] = PTE_PPN(utest_pa) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D;
    l0[5] = PTE_PPN(static_pa) | PTE_V | PTE_R | PTE_X | PTE_A;
    l0[6] = PTE_PPN(PA_TGT_A) | PTE_V | PTE_R | PTE_X | PTE_A;
    l0[7] = PTE_PPN(PA_TGT_B) | PTE_V | PTE_R | PTE_X | PTE_A;
    l0[8] = PTE_PPN(PA_TGT_A) | PTE_V | PTE_R | PTE_X | PTE_U | PTE_A;
}

static uint64_t g_satp_train;
static uint64_t g_satp_probe;

static void warm_page(uint64_t va, uint64_t priv, uint64_t satp_val)
{
    run_priv_probe(va, 0, 0, priv, satp_val, 0, 0, 0);
}

static void record_check(const char *name,
                         int expect_trap,
                         uint64_t want_cause,
                         uint64_t want_epc,
                         uint64_t want_tval,
                         int walk_mode, /* 0 = ignore, 1 = require 0, 2 = require >= 1 */
                         int check_s2_pred)
{
    uint64_t walks = g_after_walks - g_before_walks;
    uint64_t s2_pred = g_has_mperf ? (g_after_s2_pred - g_before_s2_pred) : 0ul;
    int arch_ok;
    if (expect_trap) {
        arch_ok = (g_trap_count == 1ul) && (g_last_cause == want_cause) &&
                  (g_last_epc == want_epc) && (g_last_tval == want_tval) && (g_after_canary == 0ul);
    } else {
        arch_ok = (g_trap_count == 0ul) && (g_after_canary == 0ul);
    }

    int pred_ok = 1;
    if (walk_mode == 1) {
        pred_ok = (walks == 0ul) && (!check_s2_pred || (s2_pred == 0ul));
    } else if (walk_mode == 2) {
        pred_ok = (walks >= 1ul);
    }

    g_total_checks++;
    if (!arch_ok || !pred_ok) {
        g_failed_checks++;
        if (g_failed_checks <= MAX_FAIL_LOGS) {
            uart_printf("[FAIL] %s arch=%d(cnt=%lu cause=%lu/%lu epc=0x%lx/0x%lx "
                        "tval=0x%lx/0x%lx canary=%lu) walks=%lu s2_pred=%lu\n",
                        name,
                        arch_ok,
                        (unsigned long) g_trap_count,
                        (unsigned long) g_last_cause,
                        (unsigned long) want_cause,
                        (unsigned long) g_last_epc,
                        (unsigned long) want_epc,
                        (unsigned long) g_last_tval,
                        (unsigned long) want_tval,
                        (unsigned long) g_after_canary,
                        (unsigned long) walks,
                        (unsigned long) s2_pred);
        }
    }
}

/*
 * Section 1: Static .text page mapped at VA_STATIC (0xC0005000).
 * Tests predecoded low-memory pairing and reserved 32-bit branch filtering
 * across fast BTB, backing BTB, ITTAGE, and TAGE, plus positive controls.
 */
static void run_static_page_checks(void)
{
    put32(PA_STATIC_TRAIN, 0u, INSN_ECALL);
    put32(PA_STATIC_TRAIN, 0x040u, INSN_ECALL);

    write_primer_a(PA_STATIC_TRAIN, 0x080u, 0x100u);
    write_primer_b(PA_STATIC_TRAIN, 0x0A0u, 0x100u);
    write_primer_a(PA_STATIC_TRAIN, 0x0C0u, 0x122u);
    write_primer_b(PA_STATIC_TRAIN, 0x0E0u, 0x122u);

    uint32_t pair_offs[4] = {0x100u, 0x122u, 0x140u, 0x162u};
    for (int i = 0; i < 4; i++) {
        uint32_t off = pair_offs[i];
        if (off & 2u) {
            put16(PA_STATIC_TRAIN, off - 2u, C_NOP);
        }
        put16(PA_STATIC_TRAIN, off, C_NOP);
        put16(PA_STATIC_TRAIN, off + 2u, C_JALR_T1);
        put32(PA_STATIC_TRAIN, off + 4u, INSN_ECALL);
    }

    write_primer_a(PA_STATIC_TRAIN, 0xEA0u, 0xF80u);
    write_primer_a(PA_STATIC_TRAIN, 0xEC0u, 0xFA0u);
    write_primer_a(PA_STATIC_TRAIN, 0xEE0u, 0xFC0u);

    put32(PA_STATIC_TRAIN, 0xF80u, enc_branch(1u, 10u, 0u, 0x80));
    put32(PA_STATIC_TRAIN, 0xF84u, INSN_ECALL);

    put16(PA_STATIC_TRAIN, 0xFA0u, C_ADDI_A0_1);
    put32(PA_STATIC_TRAIN, 0xFA2u, enc_branch(1u, 10u, 0u, 0x5E));
    put16(PA_STATIC_TRAIN, 0xFA6u, C_NOP);
    put32(PA_STATIC_TRAIN, 0xFA8u, INSN_ECALL);

    put32(PA_STATIC_TRAIN, 0xFC0u, INSN_ADDI_A0_1);
    put32(PA_STATIC_TRAIN, 0xFC4u, enc_branch(1u, 10u, 0u, 0x3C));
    put32(PA_STATIC_TRAIN, 0xFC8u, INSN_ECALL);

    uint32_t ev_102 = write_btb_evictor(PA_STATIC_TRAIN, 0x102u);
    uint32_t ev_124 = write_btb_evictor(PA_STATIC_TRAIN, 0x124u);
    uint32_t ev_164 = write_btb_evictor(PA_STATIC_TRAIN, 0x164u);
    uint32_t ev_f80 = write_btb_evictor(PA_STATIC_TRAIN, 0xF80u);
    uint32_t ev_fa2 = write_btb_evictor(PA_STATIC_TRAIN, 0xFA2u);
    uint32_t ev_fc4 = write_btb_evictor(PA_STATIC_TRAIN, 0xFC4u);
    __asm__ volatile("fence.i" ::: "memory");

    g_sret_epc = VA_STATIC + 0x000ul;

    /* 1a. static c.ebreak lo (+0x100): cold, warm Fast+Backing BTB, Backing-only, ITTAGE. */
    warm_page(VA_STATIC, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x100ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_probe, 0, VA_STATIC_TGT_A, 0);
    record_check("static_c_ebreak_lo_cold",
                 1,
                 CAUSE_BREAKPOINT,
                 VA_STATIC + 0x100ul,
                 VA_STATIC + 0x100ul,
                 1,
                 1);

    for (int i = 0; i < 3; i++) {
        run_priv_probe(VA_STATIC + 0x100ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    warm_page(VA_STATIC, PRIV_S, g_satp_train);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x100ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_train, 0, VA_STATIC_TGT_A, 0);
    record_check("pos_c_nop_c_jalr_lo_backing", 1, CAUSE_ECALL_S, VA_STATIC + 0x104ul, 0ul, 2, 0);

    warm_page(VA_STATIC, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x100ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_probe, 0, VA_STATIC_TGT_A, 0);
    record_check("static_c_ebreak_lo_fast",
                 1,
                 CAUSE_BREAKPOINT,
                 VA_STATIC + 0x100ul,
                 VA_STATIC + 0x100ul,
                 1,
                 1);

    run_priv_probe(VA_STATIC + ev_102, 0, 0, PRIV_S, g_satp_train, 0, 0, 0);
    warm_page(VA_STATIC, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x100ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_probe, 0, VA_STATIC_TGT_A, 0);
    record_check("static_c_ebreak_lo_backing",
                 1,
                 CAUSE_BREAKPOINT,
                 VA_STATIC + 0x100ul,
                 VA_STATIC + 0x100ul,
                 1,
                 1);

    for (int i = 0; i < 2; i++) {
        run_priv_probe(VA_STATIC + 0x080ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    for (int i = 0; i < 6; i++) {
        run_priv_probe(VA_STATIC + 0x080ul, VA_STATIC_TGT_B, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    for (int i = 0; i < 2; i++) {
        run_priv_probe(VA_STATIC + 0x0A0ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    warm_page(VA_STATIC, PRIV_S, g_satp_probe);
    warm_page(VA_STATIC_TGT_A, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x080ul, VA_STATIC_TGT_B, 0, PRIV_S, g_satp_probe, 0, VA_STATIC_TGT_B, 0);
    record_check("static_c_ebreak_lo_ittage",
                 1,
                 CAUSE_BREAKPOINT,
                 VA_STATIC + 0x100ul,
                 VA_STATIC + 0x100ul,
                 1,
                 0);

    /* 1b. static c.ebreak hi (+0x122): Fast+Backing BTB, Backing-only, and ITTAGE. */
    for (int i = 0; i < 3; i++) {
        run_priv_probe(VA_STATIC + 0x122ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    warm_page(VA_STATIC, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x122ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_probe, 0, VA_STATIC_TGT_A, 0);
    record_check("static_c_ebreak_hi_fast",
                 1,
                 CAUSE_BREAKPOINT,
                 VA_STATIC + 0x122ul,
                 VA_STATIC + 0x122ul,
                 1,
                 1);

    run_priv_probe(VA_STATIC + ev_124, 0, 0, PRIV_S, g_satp_train, 0, 0, 0);
    warm_page(VA_STATIC, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x122ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_probe, 0, VA_STATIC_TGT_A, 0);
    record_check("static_c_ebreak_hi_backing",
                 1,
                 CAUSE_BREAKPOINT,
                 VA_STATIC + 0x122ul,
                 VA_STATIC + 0x122ul,
                 1,
                 1);

    for (int i = 0; i < 2; i++) {
        run_priv_probe(VA_STATIC + 0x0C0ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    for (int i = 0; i < 6; i++) {
        run_priv_probe(VA_STATIC + 0x0C0ul, VA_STATIC_TGT_B, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    for (int i = 0; i < 2; i++) {
        run_priv_probe(VA_STATIC + 0x0E0ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    warm_page(VA_STATIC, PRIV_S, g_satp_probe);
    warm_page(VA_STATIC_TGT_A, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x0C0ul, VA_STATIC_TGT_B, 0, PRIV_S, g_satp_probe, 0, VA_STATIC_TGT_B, 0);
    record_check("static_c_ebreak_hi_ittage",
                 1,
                 CAUSE_BREAKPOINT,
                 VA_STATIC + 0x122ul,
                 VA_STATIC + 0x122ul,
                 1,
                 0);

    /* 1c. static reserved RVC lo (+0x140 = 0x0000) and hi (+0x162 = 0x8002). */
    for (int i = 0; i < 3; i++) {
        run_priv_probe(VA_STATIC + 0x140ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    warm_page(VA_STATIC, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x140ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_probe, 0, VA_STATIC_TGT_A, 0);
    record_check("static_rvc_res0000_lo", 1, CAUSE_ILLEGAL, VA_STATIC + 0x140ul, 0x0000ul, 1, 1);

    for (int i = 0; i < 3; i++) {
        run_priv_probe(VA_STATIC + 0x162ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    run_priv_probe(VA_STATIC + ev_164, 0, 0, PRIV_S, g_satp_train, 0, 0, 0);
    warm_page(VA_STATIC, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(
        VA_STATIC + 0x162ul, VA_STATIC_TGT_A, 0, PRIV_S, g_satp_probe, 0, VA_STATIC_TGT_A, 0);
    record_check(
        "static_rvc_res8002_hi_backing", 1, CAUSE_ILLEGAL, VA_STATIC + 0x162ul, 0x8002ul, 1, 1);

    /* 1d. static reserved 32-bit OPC_BRANCH in Slot 1 (+0xF80), Slot 2 cur_hi
     * (+0xFA2), and Slot 2 next_lo (+0xFC4) with warm TAGE taken entries,
     * paired with positive controls on legal branches at the same PCs. */
    put32(PA_TGT_A, 0u, INSN_ECALL);
    __asm__ volatile("fence.i" ::: "memory");

    struct {
        const char *pos_name;
        const char *name;
        uint32_t primer_off;
        uint32_t epc_off;
        uint32_t ev_off;
        uint32_t want_insn;
    } br_cases[3] = {
        {"pos_branch_slot1", "static_res_branch_slot1", 0xEA0u, 0xF80u, ev_f80, 0x08002063u},
        {"pos_branch_cur_hi",
         "static_res_branch_slot2_cur_hi",
         0xEC0u,
         0xFA2u,
         ev_fa2,
         0x04003F63u},
        {"pos_branch_next_lo",
         "static_res_branch_slot2_next_lo",
         0xEE0u,
         0xFC4u,
         ev_fc4,
         0x02002E63u},
    };

    for (int c = 0; c < 3; c++) {
        for (int i = 0; i < 2; i++) {
            run_priv_probe(
                VA_STATIC + br_cases[c].primer_off, 0, 0ul, PRIV_S, g_satp_train, 0, 0, 0);
        }
        for (int i = 0; i < 8; i++) {
            run_priv_probe(
                VA_STATIC + br_cases[c].primer_off, 0, 1ul, PRIV_S, g_satp_train, 0, 0, 0);
        }
        run_priv_probe(VA_STATIC + br_cases[c].ev_off, 0, 0, PRIV_S, g_satp_train, 0, 0, 0);

        warm_page(VA_STATIC, PRIV_S, g_satp_train);
        g_trap_count = 0;
        run_priv_probe(VA_STATIC + br_cases[c].primer_off,
                       0,
                       1ul,
                       PRIV_S,
                       g_satp_train,
                       0,
                       VA_STATIC_TGT_A,
                       0);
        record_check(br_cases[c].pos_name, 1, CAUSE_ECALL_S, VA_STATIC_TGT_A, 0ul, 2, 0);

        warm_page(VA_STATIC, PRIV_S, g_satp_probe);
        g_trap_count = 0;
        run_priv_probe(VA_STATIC + br_cases[c].primer_off,
                       0,
                       1ul,
                       PRIV_S,
                       g_satp_probe,
                       0,
                       VA_STATIC_TGT_A,
                       0);
        record_check(br_cases[c].name,
                     1,
                     CAUSE_ILLEGAL,
                     VA_STATIC + br_cases[c].epc_off,
                     br_cases[c].want_insn,
                     1,
                     0);
    }

    init_target_pages();
}

/*
 * Section 2: Batched matrix over every always-trapping or always-redirecting
 * instruction in both halfword starts (lo and hi), both slots and both orders,
 * and both without and with a hit in the backing BTB (plus ITTAGE).
 *
 * Non-overlapping page regions per batch of up to 7 specs (14 halfword slots):
 *   0x000, 0x040      : ecall landing pads
 *   0x100 .. 0x24F    : Case A [spec, c.jalr]         (evictors at 0x500..0x64F)
 *   0x260 .. 0x33F    : Case B [spec, nop] self-hit   (evictors at 0x660..0x73F)
 *   0x800 .. 0x94F    : Case C/D [addi/jump, spec]    (evictors at 0xC00..0xD4F)
 *   0x980 .. 0xBEF    : ITTAGE primers A & B
 */
typedef struct {
    const char *tag;
    int is_compressed;
    int test_ittage;
    uint32_t encoding;
    uint64_t priv;
    uint64_t mstatus_or;
    int traps;
    uint64_t want_cause;
    int tval_is_epc;
    uint64_t want_tval;
} older_spec_t;

static void run_spec_batch(const older_spec_t *batch, uint32_t count)
{
    fill_nops(PA_TRAIN, 0x0F8u, 0x350u);
    fill_nops(PA_PROBE, 0x0F8u, 0x350u);
    fill_nops(PA_UTEST, 0x0F8u, 0x350u);
    fill_nops(PA_TRAIN, 0x7F8u, 0x960u);
    fill_nops(PA_PROBE, 0x7F8u, 0x960u);
    fill_nops(PA_UTEST, 0x7F8u, 0x960u);

    uint32_t ev_a[SPEC_BATCH][2];
    uint32_t ev_b[SPEC_BATCH][2];
    uint32_t ev_c[SPEC_BATCH][2];

    for (uint32_t b = 0; b < count; b++) {
        const older_spec_t *spec = &batch[b];
        uint64_t probe_pa = (spec->priv == PRIV_U) ? PA_UTEST : PA_PROBE;
        uint32_t step = spec->is_compressed ? 2u : 4u;

        for (int hi = 0; hi <= 1; hi++) {
            uint32_t slot = 2u * b + (uint32_t) hi;
            uint32_t off_a = 0x100u + slot * 0x18u + (hi ? 2u : 0u);
            uint32_t y_off = off_a + step;
            uint32_t off_b = 0x260u + slot * 0x10u + (hi ? 2u : 0u);
            uint32_t s1_off = 0x800u + slot * 0x18u;
            uint32_t s2_off = s1_off + (hi ? 2u : 4u);

            if (spec->is_compressed) {
                put16(PA_TRAIN, off_a, C_NOP);
                put16(probe_pa, off_a, (uint16_t) spec->encoding);
            } else {
                put32(PA_TRAIN, off_a, INSN_NOP);
                put32(probe_pa, off_a, spec->encoding);
            }
            put16(PA_TRAIN, y_off, C_JALR_T1);
            put32(PA_TRAIN, y_off + 2u, INSN_ECALL);
            put16(probe_pa, y_off, C_JALR_T1);
            put16(probe_pa, y_off + 2u, C_ADDI_S11_1);
            put32(probe_pa, y_off + 4u, INSN_ECALL);
            ev_a[b][hi] = write_btb_evictor(PA_TRAIN, y_off);

            if (spec->test_ittage) {
                uint32_t pa_off = 0x980u + slot * 0x14u;
                uint32_t pb_off = 0xAA0u + slot * 0x18u;
                write_primer_a(PA_TRAIN, pa_off, off_a);
                write_primer_b(PA_TRAIN, pb_off, off_a);
                write_primer_a(probe_pa, pa_off, off_a);
            }

            if (spec->is_compressed) {
                put16(PA_TRAIN, off_b, C_JALR_T1);
                put32(PA_TRAIN, off_b + 2u, INSN_ECALL);
                put16(probe_pa, off_b, (uint16_t) spec->encoding);
                put16(probe_pa, off_b + 2u, C_ADDI_S11_1);
                put32(probe_pa, off_b + 4u, INSN_ECALL);
            } else {
                put32(PA_TRAIN, off_b, INSN_JALR_T1);
                put32(PA_TRAIN, off_b + 4u, INSN_ECALL);
                put32(probe_pa, off_b, spec->encoding);
                put32(probe_pa, off_b + 4u, INSN_ADDI_S11_1);
                put32(probe_pa, off_b + 8u, INSN_ECALL);
            }
            ev_b[b][hi] = write_btb_evictor(PA_TRAIN, off_b);

            if (hi) {
                put16(PA_TRAIN, s1_off, C_ADDI_A0_1);
                put16(probe_pa, s1_off, C_ADDI_A0_1);
            } else {
                put32(PA_TRAIN, s1_off, INSN_ADDI_A0_1);
                put32(probe_pa, s1_off, INSN_ADDI_A0_1);
            }
            if (spec->is_compressed) {
                put16(PA_TRAIN, s2_off, C_JALR_T1);
                put32(PA_TRAIN, s2_off + 2u, INSN_ECALL);
                put16(probe_pa, s2_off, (uint16_t) spec->encoding);
                put16(probe_pa, s2_off + 2u, C_ADDI_S11_1);
                put32(probe_pa, s2_off + 4u, INSN_ECALL);
            } else {
                put32(PA_TRAIN, s2_off, INSN_JALR_T1);
                put32(PA_TRAIN, s2_off + 4u, INSN_ECALL);
                put32(probe_pa, s2_off, spec->encoding);
                put32(probe_pa, s2_off + 4u, INSN_ADDI_S11_1);
                put32(probe_pa, s2_off + 8u, INSN_ECALL);
            }
            ev_c[b][hi] = write_btb_evictor(PA_TRAIN, s2_off);
        }
    }
    __asm__ volatile("fence.i" ::: "memory");

    for (uint32_t b = 0; b < count; b++) {
        const older_spec_t *spec = &batch[b];
        uint64_t base_va = (spec->priv == PRIV_U) ? VA_UTEST : VA_PROBE;
        uint64_t tgt_a_va = (spec->priv == PRIV_U) ? VA_UTEST_TGT_A : VA_TGT_A;
        uint64_t close_cause = (spec->priv == PRIV_U) ? CAUSE_ECALL_U : CAUSE_ECALL_S;
        uint64_t cause = spec->traps ? spec->want_cause : close_cause;
        int pair_walk_mode = spec->is_compressed ? 1 : 0;
        g_sret_epc = base_va + 0x040ul;

        for (int hi = 0; hi <= 1; hi++) {
            uint32_t slot = 2u * b + (uint32_t) hi;
            uint32_t off_a = 0x100u + slot * 0x18u + (hi ? 2u : 0u);
            uint32_t off_b = 0x260u + slot * 0x10u + (hi ? 2u : 0u);
            uint32_t s1_off = 0x800u + slot * 0x18u;
            uint32_t s2_off = s1_off + (hi ? 2u : 4u);

            uint64_t epc_a = spec->traps ? (base_va + off_a) : (base_va + 0x040ul);
            uint64_t tval_a = spec->traps ? (spec->tval_is_epc ? epc_a : spec->want_tval) : 0ul;

            /* A1: Cold [spec, c.jalr] (without Backing BTB hit). */
            warm_page(base_va, spec->priv, g_satp_probe);
            g_trap_count = 0;
            run_priv_probe(base_va + off_a,
                           tgt_a_va,
                           0,
                           spec->priv,
                           g_satp_probe,
                           spec->mstatus_or,
                           tgt_a_va,
                           0);
            record_check(spec->tag, 1, cause, epc_a, tval_a, pair_walk_mode, pair_walk_mode);

            /* A2: Warm Backing BTB on younger c.jalr, Fast BTB evicted. */
            for (int i = 0; i < 2; i++) {
                run_priv_probe(base_va + off_a, tgt_a_va, 0, spec->priv, g_satp_train, 0, 0, 0);
            }
            run_priv_probe(base_va + ev_a[b][hi], 0, 0, spec->priv, g_satp_train, 0, 0, 0);
            warm_page(base_va, spec->priv, g_satp_probe);
            g_trap_count = 0;
            run_priv_probe(base_va + off_a,
                           tgt_a_va,
                           0,
                           spec->priv,
                           g_satp_probe,
                           spec->mstatus_or,
                           tgt_a_va,
                           0);
            record_check(spec->tag, 1, cause, epc_a, tval_a, pair_walk_mode, pair_walk_mode);

            /* A3: Warm ITTAGE override on younger c.jalr -> VA_TGT_B. */
            if (spec->test_ittage) {
                uint32_t pa_off = 0x980u + slot * 0x14u;
                uint32_t pb_off = 0xAA0u + slot * 0x18u;
                for (int i = 0; i < 2; i++) {
                    run_priv_probe(VA_PROBE + pa_off, VA_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
                }
                for (int i = 0; i < 6; i++) {
                    run_priv_probe(VA_PROBE + pa_off, VA_TGT_B, 0, PRIV_S, g_satp_train, 0, 0, 0);
                }
                for (int i = 0; i < 2; i++) {
                    run_priv_probe(VA_PROBE + pb_off, VA_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
                }
                warm_page(VA_PROBE, PRIV_S, g_satp_probe);
                warm_page(VA_TGT_A, PRIV_S, g_satp_probe);
                g_trap_count = 0;
                run_priv_probe(VA_PROBE + pa_off,
                               VA_TGT_B,
                               0,
                               PRIV_S,
                               g_satp_probe,
                               spec->mstatus_or,
                               VA_TGT_B,
                               0);
                record_check(spec->tag, 1, cause, epc_a, tval_a, 1, 0);
            }

            /* B: Slot-1 [spec, nop] with stale Backing BTB hit at spec's own PC. */
            uint64_t epc_b = spec->traps ? (base_va + off_b) : (base_va + 0x040ul);
            uint64_t tval_b = spec->traps ? (spec->tval_is_epc ? epc_b : spec->want_tval) : 0ul;
            for (int i = 0; i < 2; i++) {
                run_priv_probe(base_va + off_b, tgt_a_va, 0, spec->priv, g_satp_train, 0, 0, 0);
            }
            run_priv_probe(base_va + ev_b[b][hi], 0, 0, spec->priv, g_satp_train, 0, 0, 0);
            warm_page(base_va, spec->priv, g_satp_probe);
            g_trap_count = 0;
            run_priv_probe(base_va + off_b,
                           tgt_a_va,
                           0,
                           spec->priv,
                           g_satp_probe,
                           spec->mstatus_or,
                           tgt_a_va,
                           0);
            record_check(spec->tag, 1, cause, epc_b, tval_b, 1, 1);

            /* C1 & C2: Slot-2 [addi, spec] cold and with stale Backing BTB hit at s2_off. */
            uint64_t epc_c = spec->traps ? (base_va + s2_off) : (base_va + 0x040ul);
            uint64_t tval_c = spec->traps ? (spec->tval_is_epc ? epc_c : spec->want_tval) : 0ul;
            warm_page(base_va, spec->priv, g_satp_probe);
            g_trap_count = 0;
            run_priv_probe(base_va + s1_off,
                           tgt_a_va,
                           0,
                           spec->priv,
                           g_satp_probe,
                           spec->mstatus_or,
                           tgt_a_va,
                           0);
            record_check(spec->tag, 1, cause, epc_c, tval_c, 1, 1);

            for (int i = 0; i < 2; i++) {
                run_priv_probe(base_va + s1_off, tgt_a_va, 0, spec->priv, g_satp_train, 0, 0, 0);
            }
            run_priv_probe(base_va + ev_c[b][hi], 0, 0, spec->priv, g_satp_train, 0, 0, 0);
            warm_page(base_va, spec->priv, g_satp_probe);
            g_trap_count = 0;
            run_priv_probe(base_va + s1_off,
                           tgt_a_va,
                           0,
                           spec->priv,
                           g_satp_probe,
                           spec->mstatus_or,
                           tgt_a_va,
                           0);
            record_check(spec->tag, 1, cause, epc_c, tval_c, 1, 1);
        }
    }

    /* Case D across whole batch with one fence.i: [jump +12, spec] skips younger spec. */
    for (uint32_t b = 0; b < count; b++) {
        const older_spec_t *spec = &batch[b];
        uint64_t probe_pa = (spec->priv == PRIV_U) ? PA_UTEST : PA_PROBE;
        for (int hi = 0; hi <= 1; hi++) {
            uint32_t slot = 2u * b + (uint32_t) hi;
            uint32_t s1_off = 0x800u + slot * 0x18u;
            if (hi) {
                put16(probe_pa, s1_off, enc_c_j(12));
            } else {
                put32(probe_pa, s1_off, enc_jal(0u, 12));
            }
            put32(probe_pa, s1_off + 12u, INSN_ECALL);
        }
    }
    __asm__ volatile("fence.i" ::: "memory");

    for (uint32_t b = 0; b < count; b++) {
        const older_spec_t *spec = &batch[b];
        uint64_t base_va = (spec->priv == PRIV_U) ? VA_UTEST : VA_PROBE;
        uint64_t tgt_a_va = (spec->priv == PRIV_U) ? VA_UTEST_TGT_A : VA_TGT_A;
        uint64_t close_cause = (spec->priv == PRIV_U) ? CAUSE_ECALL_U : CAUSE_ECALL_S;
        g_sret_epc = base_va + 0x040ul;
        for (int hi = 0; hi <= 1; hi++) {
            uint32_t slot = 2u * b + (uint32_t) hi;
            uint32_t s1_off = 0x800u + slot * 0x18u;
            warm_page(base_va, spec->priv, g_satp_probe);
            g_trap_count = 0;
            run_priv_probe(base_va + s1_off,
                           tgt_a_va,
                           0,
                           spec->priv,
                           g_satp_probe,
                           spec->mstatus_or,
                           tgt_a_va,
                           0);
            record_check(spec->tag, 1, close_cause, base_va + s1_off + 12ul, 0ul, 1, 1);
        }
    }
}

/* M-mode mret redirect check in both halfword starts: [mret, c.jalr] and [addi, mret]. */
static void check_mmode_mret(void)
{
    fill_nops(PA_PROBE, 0x280u, 0x360u);
    for (int hi = 0; hi <= 1; hi++) {
        uint32_t off = hi ? 0x302u : 0x300u;
        uint32_t s1_off = hi ? 0x340u : 0x320u;
        uint32_t s2_off = s1_off + (hi ? 2u : 4u);

        if (hi) {
            put16(PA_PROBE, off - 2u, C_NOP);
        }
        put32(PA_PROBE, off, INSN_NOP);
        put16(PA_PROBE, off + 4u, C_JALR_T1);
        put32(PA_PROBE, off + 6u, (29u << 15) | 0x67u);           /* jr t4 */
        put32(PA_PROBE, 0x280u, (1u << 15) | (29u << 7) | 0x13u); /* mv t4, ra */
        put32(PA_PROBE, 0x284u, enc_jal(0u, (int32_t) off - 0x284));
        __asm__ volatile("fence.i" ::: "memory");

        for (int i = 0; i < 2; i++) {
            run_priv_probe(PA_PROBE + 0x280ul, PA_TGT_A, 0, PRIV_M, 0, 0, 0, 0);
        }

        /* Replace nop at off with mret and set MPP = 3 before mret executes. */
        put32(PA_PROBE, off, INSN_MRET);
        put16(PA_PROBE, off + 4u, C_JALR_T1);
        put16(PA_PROBE, off + 6u, C_ADDI_S11_1);
        put32(PA_PROBE, 0x280u, 0x000022B7u);
        put32(PA_PROBE, 0x284u, 0x80028293u);
        put32(PA_PROBE, 0x288u, 0x3002A073u);
        put32(PA_PROBE, 0x28Cu, (0x341u << 20) | (1u << 15) | (1u << 12) | 0x73u);
        put32(PA_PROBE, 0x290u, enc_jal(0u, (int32_t) off - 0x290));

        if (hi) {
            put16(PA_PROBE, s1_off, C_ADDI_A0_1);
        } else {
            put32(PA_PROBE, s1_off, INSN_ADDI_A0_1);
        }
        put32(PA_PROBE, s2_off, INSN_MRET);
        put32(PA_PROBE, s2_off + 4u, INSN_ADDI_S11_1);
        put32(PA_PROBE, 0x2A0u, 0x000022B7u);
        put32(PA_PROBE, 0x2A4u, 0x80028293u);
        put32(PA_PROBE, 0x2A8u, 0x3002A073u);
        put32(PA_PROBE, 0x2ACu, (0x341u << 20) | (1u << 15) | (1u << 12) | 0x73u);
        put32(PA_PROBE, 0x2B0u, enc_jal(0u, (int32_t) s1_off - 0x2B0));
        __asm__ volatile("fence.i" ::: "memory");

        g_trap_count = 0;
        run_priv_probe(PA_PROBE + 0x280ul, PA_TGT_A, 0, PRIV_M, 0, 0, 0, 0);
        record_check("mmode_mret_older", 0, 0, 0, 0, 0, 0);

        g_trap_count = 0;
        run_priv_probe(PA_PROBE + 0x2A0ul, PA_TGT_A, 0, PRIV_M, 0, 0, 0, 0);
        record_check("mmode_mret_younger", 0, 0, 0, 0, 1, 1);
    }
    init_target_pages();
}

/*
 * Section 3: L1I-refilled dynamic checks for:
 *   - [c.ebreak, c.bnez] under a TAGE hit
 *   - [c.ebreak, c.jr ra] under a Backing BTB return hit
 *   - reserved 32-bit OPC_BRANCH (funct3 = 010 and 011) in Slot 1 (lo and hi),
 *     Slot 2 cur_hi, and Slot 2 next_lo (after compressed hi), paired with
 *     legal BLT (funct3=100) and BGEU (funct3=111) positive controls.
 */
static void check_dynamic_branch_and_return_pairs(void)
{
    fill_nops(PA_TRAIN, 0x2C0u, 0x320u);
    fill_nops(PA_PROBE, 0x2C0u, 0x320u);
    fill_nops(PA_TRAIN, 0xE60u, 0x1000u);
    fill_nops(PA_PROBE, 0xE60u, 0x1000u);
    put32(PA_TRAIN, 0u, INSN_ECALL);
    put32(PA_PROBE, 0u, INSN_ECALL);
    put32(PA_TGT_A, 0u, INSN_ECALL);

    /* 1. [c.ebreak, c.bnez a0, VA_TGT_A] at 0xF80 with TAGE warm. */
    write_primer_a(PA_TRAIN, 0xE60u, 0xF80u);
    write_primer_a(PA_PROBE, 0xE60u, 0xF80u);
    put16(PA_TRAIN, 0xF80u, C_NOP);
    put16(PA_TRAIN, 0xF82u, enc_c_bnez_a0(0x7E));
    put32(PA_TRAIN, 0xF84u, INSN_ECALL);

    put16(PA_PROBE, 0xF80u, C_EBREAK);
    put16(PA_PROBE, 0xF82u, enc_c_bnez_a0(0x7E));
    put16(PA_PROBE, 0xF84u, C_ADDI_S11_1);
    put32(PA_PROBE, 0xF86u, INSN_ECALL);
    uint32_t ev_f82 = write_btb_evictor(PA_TRAIN, 0xF82u);

    /* 2. [c.ebreak, c.jr ra] at 0x300 with Backing BTB return entry warm. */
    put32(PA_TRAIN, 0x2C0u, (6u << 15) | (1u << 7) | 0x13u);
    put32(PA_TRAIN, 0x2C4u, enc_jal(0u, 0x300 - 0x2C4));
    put16(PA_TRAIN, 0x300u, C_NOP);
    put16(PA_TRAIN, 0x302u, C_JR_RA);
    put32(PA_TRAIN, 0x304u, INSN_ECALL);

    put32(PA_PROBE, 0x2C0u, (6u << 15) | (1u << 7) | 0x13u);
    put32(PA_PROBE, 0x2C4u, enc_jal(0u, 0x300 - 0x2C4));
    put16(PA_PROBE, 0x300u, C_EBREAK);
    put16(PA_PROBE, 0x302u, C_JR_RA);
    put16(PA_PROBE, 0x304u, C_ADDI_S11_1);
    put32(PA_PROBE, 0x306u, INSN_ECALL);
    uint32_t ev_302 = write_btb_evictor(PA_TRAIN, 0x302u);

    /* 3a: Slot 1 aligned (0xF90, funct3=011, trained with BLT funct3=100). */
    write_primer_a(PA_TRAIN, 0xE80u, 0xF90u);
    write_primer_a(PA_PROBE, 0xE80u, 0xF90u);
    put32(PA_TRAIN, 0xF90u, enc_branch(4u, 10u, 0u, 0x70));
    put32(PA_TRAIN, 0xF94u, INSN_ECALL);
    uint32_t res_s1_lo = enc_branch(3u, 10u, 0u, 0x70);
    put32(PA_PROBE, 0xF90u, res_s1_lo);
    put32(PA_PROBE, 0xF94u, INSN_ADDI_S11_1);
    put32(PA_PROBE, 0xF98u, INSN_ECALL);
    uint32_t ev_f90 = write_btb_evictor(PA_TRAIN, 0xF90u);

    /* 3b: Slot 1 spanning hi (0xFA2, funct3=010, trained with BGEU a0, t1). */
    write_primer_a(PA_TRAIN, 0xEA0u, 0xFA2u);
    write_primer_a(PA_PROBE, 0xEA0u, 0xFA2u);
    put16(PA_TRAIN, 0xFA0u, C_NOP);
    put32(PA_TRAIN, 0xFA2u, enc_branch(7u, 10u, 6u, 0x5E));
    put16(PA_TRAIN, 0xFA6u, C_NOP);
    put32(PA_TRAIN, 0xFA8u, INSN_ECALL);
    put16(PA_PROBE, 0xFA0u, C_NOP);
    uint32_t res_s1_hi = enc_branch(2u, 10u, 0u, 0x5E);
    put32(PA_PROBE, 0xFA2u, res_s1_hi);
    put16(PA_PROBE, 0xFA6u, C_ADDI_S11_1);
    put32(PA_PROBE, 0xFA8u, INSN_ECALL);
    uint32_t ev_fa2 = write_btb_evictor(PA_TRAIN, 0xFA2u);

    /* 3c: Slot 2 cur_hi spanning (0xFB2 after c.nop at 0xFB0, funct3=010). */
    write_primer_a(PA_TRAIN, 0xEC0u, 0xFB0u);
    write_primer_a(PA_PROBE, 0xEC0u, 0xFB0u);
    put16(PA_TRAIN, 0xFB0u, C_NOP);
    put32(PA_TRAIN, 0xFB2u, enc_branch(4u, 10u, 0u, 0x4E));
    put16(PA_TRAIN, 0xFB6u, C_NOP);
    put32(PA_TRAIN, 0xFB8u, INSN_ECALL);
    put16(PA_PROBE, 0xFB0u, C_NOP);
    uint32_t res_s2_cur_hi = enc_branch(2u, 10u, 0u, 0x4E);
    put32(PA_PROBE, 0xFB2u, res_s2_cur_hi);
    put16(PA_PROBE, 0xFB6u, C_ADDI_S11_1);
    put32(PA_PROBE, 0xFB8u, INSN_ECALL);
    uint32_t ev_fb2 = write_btb_evictor(PA_TRAIN, 0xFB2u);

    /* 3d: Slot 2 next_lo after compressed hi (0xFC4 after c.nop at 0xFC2, funct3=011). */
    write_primer_a(PA_TRAIN, 0xEE0u, 0xFC2u);
    write_primer_a(PA_PROBE, 0xEE0u, 0xFC2u);
    put16(PA_TRAIN, 0xFC0u, C_NOP);
    put16(PA_TRAIN, 0xFC2u, C_NOP);
    put32(PA_TRAIN, 0xFC4u, enc_branch(7u, 10u, 6u, 0x3C));
    put32(PA_TRAIN, 0xFC8u, INSN_ECALL);
    put16(PA_PROBE, 0xFC0u, C_NOP);
    put16(PA_PROBE, 0xFC2u, C_NOP);
    uint32_t res_s2_next_lo = enc_branch(3u, 10u, 0u, 0x3C);
    put32(PA_PROBE, 0xFC4u, res_s2_next_lo);
    put32(PA_PROBE, 0xFC8u, INSN_ADDI_S11_1);
    put32(PA_PROBE, 0xFCCu, INSN_ECALL);
    uint32_t ev_fc4 = write_btb_evictor(PA_TRAIN, 0xFC4u);
    __asm__ volatile("fence.i" ::: "memory");

    for (int i = 0; i < 2; i++) {
        run_priv_probe(VA_PROBE + 0xE60ul, 0, 0ul, PRIV_S, g_satp_train, 0, 0, 0);
    }
    for (int i = 0; i < 8; i++) {
        run_priv_probe(VA_PROBE + 0xE60ul, 0, 1ul, PRIV_S, g_satp_train, 0, 0, 0);
    }
    run_priv_probe(VA_PROBE + ev_f82, 0, 0, PRIV_S, g_satp_train, 0, 0, 0);
    warm_page(VA_PROBE, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(VA_PROBE + 0xE60ul, 0, 1ul, PRIV_S, g_satp_probe, 0, VA_TGT_A, 0);
    record_check("ddr_c_ebreak_before_c_bnez",
                 1,
                 CAUSE_BREAKPOINT,
                 VA_PROBE + 0xF80ul,
                 VA_PROBE + 0xF80ul,
                 1,
                 0);

    for (int i = 0; i < 3; i++) {
        run_priv_probe(VA_PROBE + 0x2C0ul, VA_TGT_A, 0, PRIV_S, g_satp_train, 0, 0, 0);
    }
    run_priv_probe(VA_PROBE + ev_302, 0, 0, PRIV_S, g_satp_train, 0, 0, 0);
    warm_page(VA_PROBE, PRIV_S, g_satp_probe);
    g_trap_count = 0;
    run_priv_probe(VA_PROBE + 0x2C0ul, VA_TGT_A, 0, PRIV_S, g_satp_probe, 0, VA_TGT_A, 0);
    record_check("ddr_c_ebreak_before_c_jr_ra",
                 1,
                 CAUSE_BREAKPOINT,
                 VA_PROBE + 0x300ul,
                 VA_PROBE + 0x300ul,
                 1,
                 1);

    struct {
        const char *pos_name;
        const char *name;
        uint32_t primer_off;
        uint32_t epc_off;
        uint32_t ev_off;
        uint64_t untaken_a0;
        uint64_t taken_a0;
        uint32_t want_insn;
    } ddr_br[4] = {
        {"pos_blt_slot1_lo",
         "ddr_res_branch_slot1_lo",
         0xE80u,
         0xF90u,
         ev_f90,
         0ul,
         ~0ul,
         res_s1_lo},
        {"pos_bgeu_slot1_hi",
         "ddr_res_branch_slot1_hi",
         0xEA0u,
         0xFA2u,
         ev_fa2,
         1ul,
         3ul,
         res_s1_hi},
        {"pos_blt_cur_hi",
         "ddr_res_branch_cur_hi",
         0xEC0u,
         0xFB2u,
         ev_fb2,
         0ul,
         ~0ul,
         res_s2_cur_hi},
        {"pos_bgeu_next_lo",
         "ddr_res_branch_next_lo",
         0xEE0u,
         0xFC4u,
         ev_fc4,
         1ul,
         3ul,
         res_s2_next_lo},
    };

    for (int c = 0; c < 4; c++) {
        for (int i = 0; i < 2; i++) {
            run_priv_probe(VA_PROBE + ddr_br[c].primer_off,
                           2ul,
                           ddr_br[c].untaken_a0,
                           PRIV_S,
                           g_satp_train,
                           0,
                           0,
                           0);
        }
        for (int i = 0; i < 8; i++) {
            run_priv_probe(VA_PROBE + ddr_br[c].primer_off,
                           2ul,
                           ddr_br[c].taken_a0,
                           PRIV_S,
                           g_satp_train,
                           0,
                           0,
                           0);
        }
        run_priv_probe(VA_PROBE + ddr_br[c].ev_off, 0, 0, PRIV_S, g_satp_train, 0, 0, 0);

        warm_page(VA_PROBE, PRIV_S, g_satp_train);
        g_trap_count = 0;
        run_priv_probe(VA_PROBE + ddr_br[c].primer_off,
                       2ul,
                       ddr_br[c].taken_a0,
                       PRIV_S,
                       g_satp_train,
                       0,
                       VA_TGT_A,
                       0);
        record_check(ddr_br[c].pos_name, 1, CAUSE_ECALL_S, VA_TGT_A, 0ul, 2, 0);

        warm_page(VA_PROBE, PRIV_S, g_satp_probe);
        g_trap_count = 0;
        run_priv_probe(VA_PROBE + ddr_br[c].primer_off,
                       2ul,
                       ddr_br[c].taken_a0,
                       PRIV_S,
                       g_satp_probe,
                       0,
                       VA_TGT_A,
                       0);
        record_check(ddr_br[c].name,
                     1,
                     CAUSE_ILLEGAL,
                     VA_PROBE + ddr_br[c].epc_off,
                     ddr_br[c].want_insn,
                     1,
                     0);
    }

    init_target_pages();
}

int main(void)
{
    csr_write_imm(0x302, 0ul);
    csr_write_imm(0x303, 0ul);
    csr_write_imm(0x324, 4ul);
    csr_write_imm(0x325, 5ul);
    csr_write_imm(0x306, 0x1FFul);
    csr_write_imm(0x320, 0ul);

    g_has_mperf = (csr_read_imm(CSR_MPERFCOUNT) > 33ul) ? 1u : 0u;
    set_trap_handler(&trap_pair_handler);

    init_target_pages();
    build_address_space(PT_TRAIN_ROOT, PA_TRAIN, PA_TRAIN, PA_STATIC_TRAIN);
    build_address_space(
        PT_PROBE_ROOT, PA_PROBE, PA_UTEST, (uint64_t) (uintptr_t) static_probe_page);
    g_satp_train = SATP_SV39(1u, PT_TRAIN_ROOT);
    g_satp_probe = SATP_SV39(2u, PT_PROBE_ROOT);
    __asm__ volatile("fence rw, rw\n sfence.vma\n" ::: "memory");

    uart_printf("bpred_trap_pair_test: starting\n");

    run_static_page_checks();

    static const older_spec_t specs[] = {
        {"c_ebreak", 1, 1, C_EBREAK, PRIV_S, 0, 1, CAUSE_BREAKPOINT, 1, 0},
        {"ebreak_32", 0, 0, INSN_EBREAK, PRIV_S, 0, 1, CAUSE_BREAKPOINT, 1, 0},
        {"ecall_s", 0, 0, INSN_ECALL, PRIV_S, 0, 1, CAUSE_ECALL_S, 0, 0},
        {"ecall_u", 0, 0, INSN_ECALL, PRIV_U, 0, 1, CAUSE_ECALL_U, 0, 0},
        {"sret_redirect", 0, 0, INSN_SRET, PRIV_S, 0, 0, 0, 0, 0},
        {"sret_tsr_trap", 0, 0, INSN_SRET, PRIV_S, MSTATUS_TSR, 1, CAUSE_ILLEGAL, 0, INSN_SRET},
        {"sret_umode_trap", 0, 0, INSN_SRET, PRIV_U, 0, 1, CAUSE_ILLEGAL, 0, INSN_SRET},
        {"mret_smode_trap", 0, 0, INSN_MRET, PRIV_S, 0, 1, CAUSE_ILLEGAL, 0, INSN_MRET},
        {"dret_trap", 0, 0, INSN_DRET, PRIV_S, 0, 1, CAUSE_ILLEGAL, 0, INSN_DRET},
        {"wfi_tw_smode_trap", 0, 0, INSN_WFI, PRIV_S, MSTATUS_TW, 1, CAUSE_ILLEGAL, 0, INSN_WFI},
        {"wfi_umode_trap", 0, 0, INSN_WFI, PRIV_U, 0, 1, CAUSE_ILLEGAL, 0, INSN_WFI},
        {"rvc_res_8002", 1, 1, C_JR_X0_RES, PRIV_S, 0, 1, CAUSE_ILLEGAL, 0, C_JR_X0_RES},
        {"rvc_res_0000", 1, 0, C_ADDI4SPN_0_RES, PRIV_S, 0, 1, CAUSE_ILLEGAL, 0, C_ADDI4SPN_0_RES},
        {"rvc_res_addiw_x0", 1, 0, C_ADDIW_X0_RES, PRIV_S, 0, 1, CAUSE_ILLEGAL, 0, C_ADDIW_X0_RES},
        {"rvc_res_addi16sp_0",
         1,
         0,
         C_ADDI16SP_0_RES,
         PRIV_S,
         0,
         1,
         CAUSE_ILLEGAL,
         0,
         C_ADDI16SP_0_RES},
        {"rvc_res_lwsp_x0", 1, 0, C_LWSP_X0_RES, PRIV_S, 0, 1, CAUSE_ILLEGAL, 0, C_LWSP_X0_RES},
        {"rvc_res_zcb", 1, 0, C_ZCB_RES, PRIV_S, 0, 1, CAUSE_ILLEGAL, 0, C_ZCB_RES},
        {"jalr_res_f3_1", 0, 0, INSN_JALR_RES, PRIV_S, 0, 1, CAUSE_ILLEGAL, 0, INSN_JALR_RES},
        {"system_res", 0, 0, INSN_SYS_RES, PRIV_S, 0, 1, CAUSE_ILLEGAL, 0, INSN_SYS_RES},
    };
    const uint32_t total_specs = (uint32_t) (sizeof(specs) / sizeof(specs[0]));
    for (uint32_t base = 0; base < total_specs; base += SPEC_BATCH) {
        uint32_t n = (total_specs - base > SPEC_BATCH) ? SPEC_BATCH : (total_specs - base);
        run_spec_batch(&specs[base], n);
    }

    check_mmode_mret();
    check_dynamic_branch_and_return_pairs();

    uart_printf("bpred_trap_pair_test: checks=%u failed=%u\n",
                (unsigned) g_total_checks,
                (unsigned) g_failed_checks);
    uart_printf((g_failed_checks == 0u) ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
}
