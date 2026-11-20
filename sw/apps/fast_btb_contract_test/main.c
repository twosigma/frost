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
 * Full-core verification of the fast-BTB and backing-BTB training contract
 * (paired with FastBtbContractCoverage reach assertions in test_real_program.py):
 *   1. Same-side M->M load-fault trap and mret after a flushed speculative JALR:
 *      the entry survives and changes only cycles (retired-PC check armed).
 *   2. Same-side mstatus write keeps a flushed JALR entry; recovery preserves
 *      exact architectural state.
 *   3. Flushed wrong-path JALR training the odd interior halfword P of a 32-bit
 *      LUI with a same-word covering phantom target (P + 4 inside a 32-bit addi
 *      at P + 2) is walked past cleanly on the architectural path.
 *   4. Sv39 SFENCE.VMA (without FENCE.I or satp write) and satp write (ASID
 *      switch without FENCE.I or SFENCE.VMA) each clear the fast BTB.
 *   5. The backing BTB has no clear-all: after FENCE.I clears the fast BTB,
 *      PD vetoes a stale backing entry on a rewritten addi, and execution
 *      recovers cleanly when a rewritten JALR takes a new target.
 */

#include <stdint.h>

#include "../../lib/include/trap.h"
#include "../../lib/include/uart.h"

#define PT_ROOT_A 0x81100000ul
#define PT_L1_A 0x81101000ul
#define PT_L0_A 0x81102000ul
#define PT_ROOT_B 0x81103000ul
#define PT_L1_B 0x81104000ul
#define PT_L0_B 0x81105000ul

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define PTE_IDENTITY (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
#define PTE_CODE_S (PTE_V | PTE_X | PTE_A)
#define SATP_SV39 (8ul << 60)
#define SATP_ASID(id) (((unsigned long) (id)) << 44)

#define CAUSE_LOAD_ACCESS_FAULT 5ul
#define CAUSE_ECALL_S 9ul
#define RESULT_BRANCH 39ul
#define RESULT_ALU 127ul

#define INSN_ADDI_A0_1 0x00150513u
#define INSN_ADDI_A0_7 0x00750513u
#define INSN_ADDI_A0_100 0x06450513u
#define INSN_AUIPC_T0 0x00000297u
#define INSN_JALR_T0_8 0x00828067u
#define INSN_JALR_T0_12 0x00c28067u
#define INSN_RET 0x00008067u

struct fbc_m_trap_out {
    unsigned long cause;
    unsigned long epc;
    unsigned long expected_epc;
    unsigned long a2;
    unsigned long t2;
    unsigned long ra_got;
    unsigned long expected_ra;
    unsigned long cycles;
};

extern void fbc_m_trap_case(unsigned long pre_use_stale, struct fbc_m_trap_out *out);
extern unsigned long fbc_mstatus_keep_case(void);
extern unsigned long fbc_flushed_interior_case(void);
extern char fbc_page_branch[], fbc_page_alu[];
extern void fbc_sv39_m_trap_handler(void);
extern void fbc_sv39_s_entry(void);

volatile unsigned long g_fbc_m_cause;
volatile unsigned long g_fbc_sfence_train;
volatile unsigned long g_fbc_sfence_after;
volatile unsigned long g_fbc_satp_train;
volatile unsigned long g_fbc_satp_after;

__attribute__((section(".ddr_bss"), aligned(64))) volatile uint32_t fbc_ddr_buf[16];
static volatile uint32_t *volatile const fbc_ddr_code = fbc_ddr_buf;

typedef long (*ddr_fn_t)(long);

static int build_sv39_tables(unsigned long pa_branch, unsigned long pa_alu)
{
    volatile unsigned long *root_a = (volatile unsigned long *) PT_ROOT_A;
    volatile unsigned long *l1_a = (volatile unsigned long *) PT_L1_A;
    volatile unsigned long *l0_a = (volatile unsigned long *) PT_L0_A;
    volatile unsigned long *root_b = (volatile unsigned long *) PT_ROOT_B;
    volatile unsigned long *l1_b = (volatile unsigned long *) PT_L1_B;
    volatile unsigned long *l0_b = (volatile unsigned long *) PT_L0_B;

    unsigned long region_1g = pa_branch & ~((1ul << 30) - 1);
    unsigned long region_2m = pa_branch & ~((1ul << 21) - 1);
    if ((pa_alu >> 21) != (pa_branch >> 21) || pa_branch >= (4ul << 30)) {
        return 0;
    }
    for (unsigned long i = 0; i < 512; i++) {
        unsigned long g = i < 4 ? (PTE_PPN(i << 30) | PTE_IDENTITY) : 0;
        unsigned long m = PTE_PPN(region_1g + (i << 21)) | PTE_IDENTITY;
        unsigned long p = PTE_PPN(region_2m + (i << 12)) | PTE_IDENTITY;
        root_a[i] = g;
        l1_a[i] = m;
        l0_a[i] = p;
        root_b[i] = g;
        l1_b[i] = m;
        l0_b[i] = p;
    }
    root_a[pa_branch >> 30] = PTE_PPN(PT_L1_A) | PTE_V;
    l1_a[(pa_branch >> 21) & 0x1ff] = PTE_PPN(PT_L0_A) | PTE_V;
    l0_a[(pa_alu >> 12) & 0x1ff] = PTE_PPN(pa_branch) | PTE_CODE_S;

    root_b[pa_branch >> 30] = PTE_PPN(PT_L1_B) | PTE_V;
    l1_b[(pa_branch >> 21) & 0x1ff] = PTE_PPN(PT_L0_B) | PTE_V;
    l0_b[(pa_alu >> 12) & 0x1ff] = PTE_PPN(pa_alu) | PTE_CODE_S;
    return 1;
}

static int run_sv39_cases(void)
{
    unsigned long pa_branch = (unsigned long) fbc_page_branch;
    unsigned long pa_alu = (unsigned long) fbc_page_alu;
    if (!build_sv39_tables(pa_branch, pa_alu)) {
        uart_printf("[FAIL] sv39 table layout\n");
        return 0;
    }

    unsigned long satp_a = SATP_SV39 | SATP_ASID(1) | (PT_ROOT_A >> 12);
    unsigned long satp_b = SATP_SV39 | SATP_ASID(2) | (PT_ROOT_B >> 12);
    unsigned long l0_entry_addr = PT_L0_A + (((pa_alu >> 12) & 0x1ff) * 8ul);
    unsigned long pte_alu = PTE_PPN(pa_alu) | PTE_CODE_S;
    unsigned long pte_branch = PTE_PPN(pa_branch) | PTE_CODE_S;

    g_fbc_m_cause = ~0ul;
    g_fbc_sfence_train = 0;
    g_fbc_sfence_after = 0;
    g_fbc_satp_train = 0;
    g_fbc_satp_after = 0;

    unsigned long old_mtvec = csr_read(mtvec);
    set_trap_handler(fbc_sv39_m_trap_handler);
    __asm__ volatile("sfence.vma" ::: "memory");
    csr_write(satp, satp_a);
    __asm__ volatile("sfence.vma" ::: "memory");

    register unsigned long r_s0 __asm__("s0") = pa_alu;
    register unsigned long r_s2 __asm__("s2") = l0_entry_addr;
    register unsigned long r_s3 __asm__("s3") = pte_alu;
    register unsigned long r_s4 __asm__("s4") = pte_branch;
    register unsigned long r_s5 __asm__("s5") = satp_b;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(fbc_sv39_s_entry), "r"(r_s0), "r"(r_s2), "r"(r_s3), "r"(r_s4), "r"(r_s5)
                     : "t0", "t1", "a0", "ra", "s1", "memory");

    csr_write(satp, 0ul);
    __asm__ volatile("sfence.vma" ::: "memory");
    csr_write(mtvec, old_mtvec);

    int ok_sfence = (g_fbc_m_cause == CAUSE_ECALL_S) && (g_fbc_sfence_train == RESULT_BRANCH) &&
                    (g_fbc_sfence_after == RESULT_ALU);
    int ok_satp = (g_fbc_m_cause == CAUSE_ECALL_S) && (g_fbc_satp_train == RESULT_BRANCH) &&
                  (g_fbc_satp_after == RESULT_ALU);

    uart_printf("%s sv39 sfence.vma: train %lu after %lu\n",
                ok_sfence ? "[PASS]" : "[FAIL]",
                g_fbc_sfence_train,
                g_fbc_sfence_after);
    uart_printf("%s sv39 satp write: train %lu after %lu\n",
                ok_satp ? "[PASS]" : "[FAIL]",
                g_fbc_satp_train,
                g_fbc_satp_after);
    return ok_sfence && ok_satp;
}

static void load_ddr_buf(const uint32_t *insns, unsigned n)
{
    volatile uint32_t *dst = fbc_ddr_code;
    for (unsigned i = 0; i < n; i++) {
        dst[i] = insns[i];
    }
    __asm__ volatile("fence.i" ::: "memory");
}

static int run_backing_btb_no_clear_case(void)
{
    static const uint32_t body_jalr_skip[] = {
        INSN_AUIPC_T0, INSN_JALR_T0_12, INSN_ADDI_A0_100, INSN_RET};
    static const uint32_t body_alu[] = {INSN_ADDI_A0_1, INSN_ADDI_A0_1, INSN_ADDI_A0_1, INSN_RET};
    static const uint32_t body_jalr_new_tgt[] = {
        INSN_AUIPC_T0, INSN_JALR_T0_8, INSN_ADDI_A0_7, INSN_RET};

    ddr_fn_t fn = (ddr_fn_t) (uintptr_t) fbc_ddr_code;
    int ok = 1;

    /* Train backing BTB + fast BTB on indirect jump targeting +12. */
    load_ddr_buf(body_jalr_skip, 4);
    for (long i = 0; i < 16; i++) {
        if (fn(i) != i)
            ok = 0;
    }

    /* Rewrite to non-jump addi + fence.i: backing BTB keeps its entry, PD vetoes it. */
    load_ddr_buf(body_alu, 4);
    for (long i = 0; i < 8; i++) {
        if (fn(i) != i + 3)
            ok = 0;
    }

    /* Re-train +12, then rewrite to a JALR targeting +8 + fence.i: fast BTB is
     * cleared while stale backing BTB targets +12; branch resolution recovers. */
    load_ddr_buf(body_jalr_skip, 4);
    for (long i = 0; i < 16; i++) {
        if (fn(i) != i)
            ok = 0;
    }
    load_ddr_buf(body_jalr_new_tgt, 4);
    for (long i = 0; i < 8; i++) {
        if (fn(i) != i + 7)
            ok = 0;
    }

    uart_printf("%s backing_btb no clear-all (addi veto + jalr target recovery)\n",
                ok ? "[PASS]" : "[FAIL]");
    return ok;
}

int main(void)
{
    int ok = 1;
    struct fbc_m_trap_out hit_out, miss_out;

    fbc_m_trap_case(0, &hit_out);
    fbc_m_trap_case(1, &miss_out);
    int ok_m_trap =
        (hit_out.cause == CAUSE_LOAD_ACCESS_FAULT) && (miss_out.cause == CAUSE_LOAD_ACCESS_FAULT) &&
        (hit_out.epc == hit_out.expected_epc) && (miss_out.epc == miss_out.expected_epc) &&
        (hit_out.a2 == 7) && (miss_out.a2 == 7) && (hit_out.t2 == 40) && (miss_out.t2 == 40) &&
        (hit_out.ra_got == hit_out.expected_ra) && (miss_out.ra_got == miss_out.expected_ra) &&
        (miss_out.cycles > hit_out.cycles);
    uart_printf("%s M->M trap+mret same-side survival: hit_cyc=%lu miss_cyc=%lu\n",
                ok_m_trap ? "[PASS]" : "[FAIL]",
                hit_out.cycles,
                miss_out.cycles);
    ok &= ok_m_trap;

    int ok_mstatus = (fbc_mstatus_keep_case() == 1);
    uart_printf("%s mstatus write keeps flushed JALR entry cleanly\n",
                ok_mstatus ? "[PASS]" : "[FAIL]");
    ok &= ok_mstatus;

    int ok_interior = (fbc_flushed_interior_case() == 1);
    uart_printf("%s flushed interior halfword walk-past\n", ok_interior ? "[PASS]" : "[FAIL]");
    ok &= ok_interior;

    ok &= run_sv39_cases();
    ok &= run_backing_btb_no_clear_case();

    uart_printf(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
