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
 * S-mode SUM and MXR toggles against live TLB entries.
 *
 * Linux sets sstatus.SUM before every user copy and clears it afterwards.
 * SUM and MXR change permission checks, not translations, so the TLBs keep
 * their entries across the change, and every lookup applies the live bits.
 * This test runs in S-mode under Sv39 with the page tables in cached DDR:
 *   - a U page loaded from S-mode faults with SUM=0 and succeeds with SUM=1,
 *     in every order, including while the entry is resident (no stale
 *     permission in either direction), for loads and stores;
 *   - an execute-only S page loads only with MXR=1, in both directions;
 *   - a loop that toggles SUM around nine resident pages walks no page table
 *     (HPM DTLB and ITLB walk counters), and a satp access still invalidates.
 * It also reports the cycle cost of a SUM toggle pair against the same loop
 * with sstatus writes that leave SUM unchanged. Faults trap to M (medeleg=0),
 * which counts them and resumes at the next instruction; the test's S code
 * is uncompressed, so the next instruction is mepc + 4.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

#define PT_ROOT 0x81200000ul
#define PT_L1 0x81201000ul
#define PT_L0 0x81202000ul
#define PA_U 0x81210000ul
#define PA_XO 0x81211000ul
#define PA_S 0x81212000ul /* eight S pages follow */

#define VA_U 0xC0000000ul
#define VA_XO 0xC0001000ul
#define VA_S 0xC0002000ul

#define PTE_V 0x001ul
#define PTE_R 0x002ul
#define PTE_W 0x004ul
#define PTE_X 0x008ul
#define PTE_U 0x010ul
#define PTE_A 0x040ul
#define PTE_D 0x080ul
#define PTE_PPN(pa) (((pa) >> 12) << 10)

#define SATP_SV39 (8ul << 60)

#define U_SEED 0x5555555555555555ul
#define XO_SEED 0xAAAAAAAAAAAAAAAAul
#define LOOPS 64

volatile unsigned long g_res[20];
volatile unsigned long g_faults;
volatile unsigned long g_last_cause;
volatile unsigned long g_bad_cause;
volatile unsigned long g_msave[14];

void sum_trap_handler(void);
void sum_s_body(void);
void run_s_body(void);

/* M-mode handler. A load or store page fault from the S body is counted and
 * skipped (MPP is S from the trap). The body's closing ecall, or any other
 * cause, returns to the M continuation in mscratch. Clobbers t0-t2 only. */
__asm__(".section .text\n"
        ".balign 4\n"
        ".global sum_trap_handler\n"
        "sum_trap_handler:\n"
        "    csrr t0, mcause\n"
        "    li   t1, 13\n"
        "    beq  t0, t1, 1f\n"
        "    li   t1, 15\n"
        "    beq  t0, t1, 1f\n"
        "    li   t1, 9\n"
        "    beq  t0, t1, 2f\n"
        "    la   t1, g_bad_cause\n"
        "    sd   t0, 0(t1)\n"
        "    j    2f\n"
        "1:  la   t1, g_faults\n"
        "    ld   t2, 0(t1)\n"
        "    addi t2, t2, 1\n"
        "    sd   t2, 0(t1)\n"
        "    la   t1, g_last_cause\n"
        "    sd   t0, 0(t1)\n"
        "    csrr t0, mepc\n"
        "    addi t0, t0, 4\n"
        "    csrw mepc, t0\n"
        "    mret\n"
        "2:  csrr t0, mscratch\n"
        "    csrw mepc, t0\n"
        "    li   t0, 0x1800\n"
        "    csrs mstatus, t0\n"
        "    mret\n");

/* Enter the S body with its address registers loaded; return when it ecalls.
 * The body uses s0-s11, so save the callee-saved state around it. */
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
        "    la   t0, sum_s_body\n"
        "    csrw mepc, t0\n"
        "    li   t0, 0x1800\n"
        "    csrc mstatus, t0\n"
        "    li   t0, 0x0800\n"
        "    csrs mstatus, t0\n"
        "    li   s0, 0xC0000000\n"
        "    la   s1, g_res\n"
        "    li   s2, 0xC0001000\n"
        "    li   s3, 0xC0002000\n"
        "    la   s6, g_faults\n"
        "    la   s9, g_last_cause\n"
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

/* Eight loads, one from each S page: a6 = base, a7 = 4096. */
#define S_PAGES                                                                                    \
    "    mv   a6, s3\n"                                                                            \
    "    ld   a2, 0(a6)\n    add  a6, a6, a7\n"                                                    \
    "    ld   a2, 0(a6)\n    add  a6, a6, a7\n"                                                    \
    "    ld   a2, 0(a6)\n    add  a6, a6, a7\n"                                                    \
    "    ld   a2, 0(a6)\n    add  a6, a6, a7\n"                                                    \
    "    ld   a2, 0(a6)\n    add  a6, a6, a7\n"                                                    \
    "    ld   a2, 0(a6)\n    add  a6, a6, a7\n"                                                    \
    "    ld   a2, 0(a6)\n    add  a6, a6, a7\n"                                                    \
    "    ld   a2, 0(a6)\n"

/* The S-mode body. s0 = U page, s1 = results, s2 = execute-only S page,
 * s3 = first S page, s6 = &g_faults, s9 = &g_last_cause. Results are stored
 * at s1 + 8 * index; the comments name the expected value. */
__asm__(".section .text\n"
        ".balign 4\n"
        ".global sum_s_body\n"
        ".option push\n"
        ".option norvc\n"
        "sum_s_body:\n"
        "    li   s4, 0x40000\n" /* SUM */
        "    li   s5, 0x80000\n" /* MXR */
        "    li   a7, 4096\n"
        "    csrc sstatus, s4\n"
        "    csrc sstatus, s5\n"
        /* 0: SUM=0, a U page from S faults. */
        "    ld   a0, 0(s0)\n"
        "    ld   a1, 0(s6)\n    sd   a1, 0(s1)\n" /* [0] 1 */
        /* 1: SUM=1, the same page loads. */
        "    csrs sstatus, s4\n"
        "    ld   a0, 0(s0)\n    sd   a0, 8(s1)\n"  /* [1] U seed */
        "    ld   a1, 0(s6)\n    sd   a1, 16(s1)\n" /* [2] 1 */
        /* 2: SUM=0 again with the entry resident: both loads fault. */
        "    csrc sstatus, s4\n"
        "    ld   a2, 0(s0)\n"
        "    ld   a1, 0(s6)\n    sd   a1, 24(s1)\n" /* [3] 2 */
        "    ld   a2, 8(s0)\n"
        "    ld   a1, 0(s6)\n    sd   a1, 32(s1)\n" /* [4] 3 */
        /* 3: a store with SUM=0 faults (store page fault). */
        "    sd   a0, 0(s0)\n"
        "    ld   a1, 0(s6)\n    sd   a1, 40(s1)\n" /* [5] 4 */
        "    ld   a1, 0(s9)\n    sd   a1, 48(s1)\n" /* [6] 15 */
        /* 4: SUM=1, store and load back. */
        "    csrs sstatus, s4\n"
        "    li   a2, 0x77\n"
        "    sd   a2, 0(s0)\n"
        "    ld   a3, 0(s0)\n    sd   a3, 56(s1)\n" /* [7] 0x77 */
        "    ld   a1, 0(s6)\n    sd   a1, 64(s1)\n" /* [8] 4 */
        /* 5: an execute-only S page loads only with MXR=1. */
        "    ld   a4, 0(s2)\n"
        "    csrs sstatus, s5\n"
        "    ld   a4, 0(s2)\n    sd   a4, 72(s1)\n" /* [9] XO seed */
        "    csrc sstatus, s5\n"
        "    ld   a4, 0(s2)\n"
        "    ld   a1, 0(s6)\n    sd   a1, 80(s1)\n" /* [10] 6 */
        /* 6: eight toggles against the resident U entry. */
        "    li   s7, 8\n"
        "    li   a5, 0\n"
        "1:  csrc sstatus, s4\n"
        "    ld   a2, 0(s0)\n"
        "    csrs sstatus, s4\n"
        "    ld   a2, 0(s0)\n"
        "    add  a5, a5, a2\n"
        "    addi s7, s7, -1\n"
        "    bnez s7, 1b\n"
        "    ld   a1, 0(s6)\n    sd   a1, 88(s1)\n" /* [11] 14 */
        "    sd   a5, 96(s1)\n"                     /* [12] 8 * 0x77 */
        /* 7: warm nine pages, then toggle SUM around them, as a syscall with
         * one user copy does. Nothing walks. */
        "    csrs sstatus, s4\n"
        "    ld   a2, 0(s0)\n" S_PAGES "    csrr s8, 0xC06\n"
        "    csrr s10, 0xC05\n"
        "    csrr s11, 0xC08\n"
        "    rdcycle t4\n"
        "    li   s7, 64\n"
        "3:  csrs sstatus, s4\n"
        "    ld   a2, 0(s0)\n"
        "    csrc sstatus, s4\n" S_PAGES "    addi s7, s7, -1\n"
        "    bnez s7, 3b\n"
        "    rdcycle t5\n"
        "    csrr a0, 0xC06\n    sub  a0, a0, s8\n    sd   a0, 104(s1)\n"  /* [13] 0 */
        "    csrr a0, 0xC05\n    sub  a0, a0, s10\n    sd   a0, 112(s1)\n" /* [14] 0 */
        "    sub  a0, t5, t4\n    sd   a0, 120(s1)\n"                      /* [15] cycles */
        "    csrr a0, 0xC08\n    sub  a0, a0, s11\n    sd   a0, 128(s1)\n" /* [16] busy */
        /* 8: the same loop with sstatus writes that keep SUM set. */
        "    csrs sstatus, s4\n"
        "    csrr s8, 0xC06\n"
        "    rdcycle t4\n"
        "    li   s7, 64\n"
        "4:  csrs sstatus, s4\n"
        "    ld   a2, 0(s0)\n"
        "    csrs sstatus, s4\n" S_PAGES "    addi s7, s7, -1\n"
        "    bnez s7, 4b\n"
        "    rdcycle t5\n"
        "    sub  a0, t5, t4\n    sd   a0, 136(s1)\n"                     /* [17] cycles */
        "    csrr a0, 0xC06\n    sub  a0, a0, s8\n    sd   a0, 144(s1)\n" /* [18] 0 */
        /* 9: a satp access still invalidates: the next U load walks. */
        "    csrr s8, 0xC06\n"
        "    csrr a0, satp\n"
        "    csrw satp, a0\n"
        "    ld   a2, 0(s0)\n"
        "    csrr a1, 0xC06\n    sub  a1, a1, s8\n    sd   a1, 152(s1)\n" /* [19] >= 1 */
        "    ecall\n"
        ".option pop\n");

static int check(const char *name, unsigned long got, unsigned long want)
{
    int ok = got == want;
    uart_printf("%s %s got=0x%lx want=0x%lx\n", ok ? "[PASS]" : "[FAIL]", name, got, want);
    return ok;
}

int main(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    int ok = 1;

    for (int i = 0; i < 512; i++) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    /* Identity gigapages: low BRAM code, data and stack; MMIO; cached DDR. */
    root[0] = PTE_PPN(0x00000000ul) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    root[1] = PTE_PPN(0x40000000ul) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    root[2] = PTE_PPN(0x80000000ul) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    /* VA 3 GiB: 4 KiB pages. */
    root[3] = PTE_PPN(PT_L1) | PTE_V;
    l1[0] = PTE_PPN(PT_L0) | PTE_V;
    l0[0] = PTE_PPN(PA_U) | PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D;
    l0[1] = PTE_PPN(PA_XO) | PTE_V | PTE_X | PTE_A;
    for (unsigned long i = 0; i < 8; i++) {
        l0[2 + i] = PTE_PPN(PA_S + i * 4096) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
        *(volatile unsigned long *) (PA_S + i * 4096) = i;
    }
    *(volatile unsigned long *) PA_U = U_SEED;
    *(volatile unsigned long *) (PA_U + 8) = U_SEED;
    *(volatile unsigned long *) PA_XO = XO_SEED;

    /* DTLB walks, ITLB walks and walker busy cycles; all modes may read them. */
    csr_write_imm(0x325, 5);
    csr_write_imm(0x326, 6);
    csr_write_imm(0x328, 10);
    csr_write_imm(0x320, 0);
    csr_write_imm(0x306, 0x1ff);
    csr_write(medeleg, 0);
    g_faults = 0;
    g_bad_cause = 0;
    set_trap_handler(&sum_trap_handler);
    __asm__ volatile("fence rw, rw\n"
                     "csrw satp, %0\n"
                     "sfence.vma\n"
                     :
                     : "r"(SATP_SV39 | (PT_ROOT >> 12))
                     : "memory");

    run_s_body();
    csr_write(satp, 0);

    ok &= check("unexpected-trap", g_bad_cause, 0);
    ok &= check("0 sum0-load-faults", g_res[0], 1);
    ok &= check("1 sum1-load-value", g_res[1], U_SEED);
    ok &= check("2 sum1-load-no-fault", g_res[2], 1);
    ok &= check("3 sum0-resident-load-faults", g_res[3], 2);
    ok &= check("4 sum0-second-load-faults", g_res[4], 3);
    ok &= check("5 sum0-store-faults", g_res[5], 4);
    ok &= check("6 sum0-store-cause", g_res[6], 15);
    ok &= check("7 sum1-store-load-back", g_res[7], 0x77);
    ok &= check("8 sum1-store-no-fault", g_res[8], 4);
    ok &= check("9 mxr1-xo-load-value", g_res[9], XO_SEED);
    ok &= check("10 mxr-toggle-faults", g_res[10], 6);
    ok &= check("11 sum-toggle-loop-faults", g_res[11], 14);
    ok &= check("12 sum-toggle-loop-values", g_res[12], 8 * 0x77);
    ok &= check("13 sum-toggles-keep-dtlb", g_res[13], 0);
    ok &= check("14 sum-toggles-keep-itlb", g_res[14], 0);
    ok &= check("18 unchanged-sum-keep-dtlb", g_res[18], 0);
    if (g_res[19] == 0) {
        uart_printf("[FAIL] 19 satp-access-invalidates walks=0\n");
        ok = 0;
    } else {
        uart_printf("[PASS] 19 satp-access-invalidates walks=%lu\n", g_res[19]);
    }
    uart_printf("SUMTOGGLE loops=%d toggle_cycles=%lu steady_cycles=%lu "
                "per_iter_toggle=%lu per_iter_steady=%lu dtlb_walks=%lu itlb_walks=%lu "
                "walk_busy=%lu\n",
                LOOPS,
                g_res[15],
                g_res[17],
                g_res[15] / LOOPS,
                g_res[17] / LOOPS,
                g_res[13],
                g_res[14],
                g_res[16]);
    uart_puts(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    return ok ? 0 : 1;
}
