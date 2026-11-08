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
 * Fast-BTB entries across bare M-mode and Sv39 S-mode fetch.
 *
 * M-mode fetches physical addresses even with Sv39 on, so one numeric address
 * can name different code in M-mode and S-mode. The BTB is tagged by that
 * address alone. Sv39 here maps each of two code pages (pages.S), as a
 * virtual address, to the other one: page_branch has an always-taken beq at
 * +0x10 and page_alu an addi there. A taken entry trained in one mode must
 * not redirect the addi in the other, where nothing would correct it.
 *
 *   S to M     S-mode calls virtual page_alu (page_branch's code) to train the
 *              beq, ecalls, and the M-mode handler at once calls physical
 *              page_alu: 39 in S, then 127 in M
 *   M to S     M-mode calls physical page_branch to train it, then mrets to S,
 *              which calls virtual page_branch (page_alu's code): 39, then 127
 *   M to S     the same through an sret executed in M-mode
 *
 * Page tables live in cached DDR, clear of the program image in both memory
 * tiers. The 2 MiB region holding the code pages is mapped with 4 KiB pages,
 * identity except for the swap; the rest of the low 4 GiB is identity mapped
 * with superpages.
 */

#include <stdint.h>

#include "../../lib/include/trap.h"
#include "../../lib/include/uart.h"

#define TRAIN_CALLS 8
/* Cases to run, one bit each in the order above (a case run alone shows its
 * own failure: simulation stops at the first wrong-path retirement). */
#ifndef BTB_ALIAS_CASES
#define BTB_ALIAS_CASES 7
#endif
#define RESULT_BRANCH 39ul
#define RESULT_ALU 127ul
#define CAUSE_ECALL_S 9ul

#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L0 0x81002000ul

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define PTE_IDENTITY (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
#define PTE_CODE (PTE_V | PTE_X | PTE_A)
#define SATP_SV39 (8ul << 60)

extern char btb_alias_page_branch[], btb_alias_page_alu[];
extern void btb_alias_s_stub(void);
extern void btb_alias_trap_handler(void);
extern void btb_alias_m_train_enter(void);

/* Written by the handler and the training routine in pages.S. */
volatile unsigned long g_btb_alias_cause;
volatile unsigned long g_btb_alias_s_result;
volatile unsigned long g_btb_alias_m_result;
volatile unsigned long g_btb_alias_m_call;

static int build_tables(unsigned long pa_branch, unsigned long pa_alu)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    unsigned long region_1g = pa_branch & ~((1ul << 30) - 1);
    unsigned long region_2m = pa_branch & ~((1ul << 21) - 1);

    if ((pa_branch >> 21) != (pa_alu >> 21) || pa_branch >= (4ul << 30))
        return 0;
    for (unsigned long i = 0; i < 512; i++) {
        root[i] = i < 4 ? PTE_PPN(i << 30) | PTE_IDENTITY : 0;
        l1[i] = PTE_PPN(region_1g + (i << 21)) | PTE_IDENTITY;
        l0[i] = PTE_PPN(region_2m + (i << 12)) | PTE_IDENTITY;
    }
    root[pa_branch >> 30] = PTE_PPN(PT_L1) | PTE_V;
    l1[(pa_branch >> 21) & 0x1ff] = PTE_PPN(PT_L0) | PTE_V;
    l0[(pa_branch >> 12) & 0x1ff] = PTE_PPN(pa_alu) | PTE_CODE;
    l0[(pa_alu >> 12) & 0x1ff] = PTE_PPN(pa_branch) | PTE_CODE;
    return 1;
}

static void clear_records(unsigned long m_call)
{
    g_btb_alias_cause = ~0ul;
    g_btb_alias_s_result = ~0ul;
    g_btb_alias_m_result = ~0ul;
    g_btb_alias_m_call = m_call;
}

/* S-mode trains virtual va (page_branch's code); the handler then runs
 * physical page_alu in M-mode. */
static void run_s_to_m(unsigned long va)
{
    clear_records(1);
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x0800\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %0\n"
                     "mv   s2, %1\n"
                     "mv   s1, %2\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(btb_alias_s_stub), "r"(va), "r"((unsigned long) TRAIN_CALLS)
                     : "t0", "t1", "t2", "a0", "ra", "s1", "s2", "memory");
}

/* M-mode trains physical pa (page_branch); S-mode then runs virtual pa
 * (page_alu's code), entered through mret or sret. */
static void run_m_to_s(unsigned long pa, unsigned long use_sret)
{
    clear_records(0);
    __asm__ volatile(
        "la   t0, 1f\n"
        "csrw mscratch, t0\n"
        "mv   a0, %0\n"
        "mv   a1, %1\n"
        "mv   a2, %2\n"
        "mv   a3, %0\n"
        "mv   a4, %3\n"
        "call btb_alias_m_train_enter\n"
        "1:\n"
        :
        : "r"(pa), "r"((unsigned long) TRAIN_CALLS), "r"(btb_alias_s_stub), "r"(use_sret)
        : "t0",
          "t1",
          "t2",
          "a0",
          "a1",
          "a2",
          "a3",
          "a4",
          "ra",
          "s1",
          "s2",
          "s3",
          "s4",
          "s5",
          "s6",
          "memory");
}

static int report(const char *name,
                  unsigned long first,
                  unsigned long want_first,
                  unsigned long second,
                  unsigned long want_second)
{
    int ok = g_btb_alias_cause == CAUSE_ECALL_S && first == want_first && second == want_second;
    uart_printf("%s %s: cause %lu, trained %lu (want %lu), aliased %lu (want %lu)\n",
                ok ? "[PASS]" : "[FAIL]",
                name,
                g_btb_alias_cause,
                first,
                want_first,
                second,
                want_second);
    return ok;
}

int main(void)
{
    unsigned long pa_branch = (unsigned long) btb_alias_page_branch;
    unsigned long pa_alu = (unsigned long) btb_alias_page_alu;
    int ok = 1;

    uart_printf("btb_mode_alias_test: page_branch %lx, page_alu %lx\n", pa_branch, pa_alu);
    set_trap_handler(btb_alias_trap_handler);
    if (!build_tables(pa_branch, pa_alu)) {
        uart_printf("<<FAIL>> code pages outside one 2 MiB region below 4 GiB\n");
        for (;;) {
        }
    }
    __asm__ volatile("sfence.vma" ::: "memory");
    csr_write(satp, SATP_SV39 | (PT_ROOT >> 12));
    __asm__ volatile("sfence.vma" ::: "memory");

    if (BTB_ALIAS_CASES & 1) {
        run_s_to_m(pa_alu);
        ok &=
            report("S to M", g_btb_alias_s_result, RESULT_BRANCH, g_btb_alias_m_result, RESULT_ALU);
    }
    if (BTB_ALIAS_CASES & 2) {
        run_m_to_s(pa_branch, 0);
        ok &= report(
            "M to S, mret", g_btb_alias_m_result, RESULT_BRANCH, g_btb_alias_s_result, RESULT_ALU);
    }
    if (BTB_ALIAS_CASES & 4) {
        run_m_to_s(pa_branch, 1);
        ok &= report(
            "M to S, sret", g_btb_alias_m_result, RESULT_BRANCH, g_btb_alias_s_result, RESULT_ALU);
    }

    csr_write(satp, 0ul);
    __asm__ volatile("sfence.vma" ::: "memory");

    uart_printf(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
