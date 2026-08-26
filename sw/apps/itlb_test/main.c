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
 * Sv39 fetch-translation directed test -- Phase 3 M5 (plan D15 itlb_test).
 *
 * The driver runs in M-mode (fetch untranslated) and enters S- or U-mode
 * per case with MPP + mret at a virtual target; every case ends in a trap
 * back to M (the page's ecall, or the fetch fault under test), recorded
 * once by the bounce handler with the marker registers a0/a1 the page set.
 * Page tables live in cached DDR; the code pages (pages.S) are static,
 * 4 KiB-aligned and position-independent, so each case is just a mapping.
 * Every case starts with sfence.vma, so its first fetch misses the ITLB
 * and walks; the chain case then fills more pages than the ITLB holds.
 *
 * Matrix (faults check cause, epc AND tval; hits check the markers):
 *   A. 4 KiB non-identity code page, S-mode: page head runs, ecall (9).
 *   B. 2 MiB (bram) / 1 GiB (ddr) identity superpage: a .text snippet runs
 *      at its own address under translation.
 *   C. Page-crossing window: entry at page_a+0xFF8 executes the tail
 *      markers, the 32-bit instruction straddling into page_b, then
 *      page_b's ecall (a1 = 0xA4, a0 = 0xA3, epc = page_b + 2).
 *   D. Straddle into an UNMAPPED page: instruction page fault with
 *      epc = the straddling instruction (page_a' + 0xFFE) and tval = the
 *      second page's base (the faulting portion).
 *   E. Compressed pair at the page end, next page mapped: page_b2's head
 *      runs (a0 = 0xB1).
 *   F. Same pair, next page unmapped: fault with epc = tval = next page.
 *   G. U-mode page from U: runs, ecall from U (8). Same page from S: 12.
 *   H. S page from U: 12.  I. X=0 page: 12.  J. A=0 page (Svade): 12.
 *   K. Leaf into the device quadrant: access fault 1 (fetch PMA).
 *   L. Leaf above the 4 GiB map: 1.  M. Interior pointer into BRAM
 *      (page tables must live in cached DDR): 1.
 *   N. V=0: 12.  O. W&!R: 12.  P. Reserved PTE bit: 12.
 *   Q. Misaligned 2 MiB superpage: 12.  R. Non-leaf at level 0: 12.
 *   S. Non-canonical target VA: 12 with epc = tval = the VA, no walk.
 *   T. Chain through 12 consecutive virtual pages (11 relative jumps into
 *      the next page + the end marker): ITLB replacement + back-to-back
 *      misses; run twice (second pass warm).
 *   U. sfence.vma visibility: a code page remapped to another frame runs
 *      the new frame's marker after sfence.
 *   V. satp switch (D10): a second root maps the same VA elsewhere; the
 *      satp write alone retargets fetch (no sfence).
 *   W. Bare after satp := 0: the driver's own code keeps running (implicit
 *      throughout), and a wild PC still raises M2's access fault.
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
static volatile unsigned long g_a0;
static volatile unsigned long g_a1;

extern char itlb_page_a[], itlb_page_b[], itlb_page_a2[], itlb_page_b2[];
extern char itlb_page_j[], itlb_page_e[];

/* The identity-superpage snippet: lives in .text like the driver. */
__attribute__((naked, aligned(4))) static void snippet_identity(void)
{
    __asm__ volatile("li a0, 0xC1\n"
                     "ecall\n");
}

/* M-mode bounce handler: record mcause/mepc/mtval and the page's marker
 * registers once per case, force MPP=M, return to the mscratch
 * continuation. */
__attribute__((naked, aligned(4))) static void itlb_trap_handler(void)
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
                     "la   t1, g_a0\n"
                     "sd   a0, 0(t1)\n"
                     "la   t1, g_a1\n"
                     "sd   a1, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

#define MSTATUS_MPP_MASK 0x1800ul
#define MPP_S 0x0800ul
#define MPP_U 0x0000ul

/* Enter mode `mpp` at `target` (mret); the case's trap returns here. */
#define RUN_AT(target, mpp)                                                                        \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_epc = ~0ul;                                                                              \
        g_tval = ~0ul;                                                                             \
        g_a0 = ~0ul;                                                                               \
        g_a1 = ~0ul;                                                                               \
        __asm__ volatile("la   t0, 1f\n"                                                           \
                         "csrw mscratch, t0\n"                                                     \
                         "li   t0, %2\n"                                                           \
                         "csrc mstatus, t0\n"                                                      \
                         "csrs mstatus, %1\n"                                                      \
                         "csrw mepc, %0\n"                                                         \
                         "li   a0, 0\n"                                                            \
                         "li   a1, 0\n"                                                            \
                         "mret\n"                                                                  \
                         "1:\n"                                                                    \
                         :                                                                         \
                         : "r"(target), "r"(mpp), "i"(MSTATUS_MPP_MASK)                            \
                         : "t0", "a0", "a1", "memory");                                            \
    } while (0)

static int report_fault(const char *name,
                        unsigned long want_cause,
                        unsigned long want_epc,
                        unsigned long want_tval)
{
    int ok = (g_cause == want_cause) && (g_epc == want_epc) && (g_tval == want_tval);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" cause=");
    uart_hex(g_cause);
    uart_puts(" epc=");
    uart_hex(g_epc);
    uart_puts(" tval=");
    uart_hex(g_tval);
    uart_puts("\r\n");
    return ok;
}

static int report_run(const char *name,
                      unsigned long want_cause,
                      unsigned long want_epc,
                      unsigned long want_a0,
                      unsigned long want_a1)
{
    int ok =
        (g_cause == want_cause) && (g_epc == want_epc) && (g_a0 == want_a0) && (g_a1 == want_a1);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" cause=");
    uart_hex(g_cause);
    uart_puts(" epc=");
    uart_hex(g_epc);
    uart_puts(" a0=");
    uart_hex(g_a0);
    uart_puts(" a1=");
    uart_hex(g_a1);
    uart_puts("\r\n");
    return ok;
}

/* --------------------------------------------------------------------------
 * Physical layout (cached DDR, clear of any program image):
 *   root A 0x8100_0000  L1 A 0x8100_2000  L0 A 0x8100_3000
 *   root B 0x8100_1000  L1 B 0x8100_4000  L0 B 0x8100_5000
 * Virtual layout: 4 KiB pages at 0x0040_0000 + n*4K (vpn2=0, vpn1=2,
 * vpn0=n); the misaligned 2 MiB leaf at VA 0x0220_0000 (vpn1=17); the
 * bad-pointer subtree at vpn2=1 (VA 0x4000_0000); identity superpages:
 * 2 MiB over PA 0 (the BRAM program, vpn1=0) and 1 GiB over PA
 * 0x8000_0000 (the DDR program, vpn2=2).
 * -------------------------------------------------------------------------- */
#define PT_ROOT_A 0x81000000ul
#define PT_ROOT_B 0x81001000ul
#define PT_L1_A 0x81002000ul
#define PT_L0_A 0x81003000ul
#define PT_L1_B 0x81004000ul
#define PT_L0_B 0x81005000ul

#define VA_4K(n) (0x00400000ul + ((unsigned long) (n) << 12))
#define VA_2M_MISALIGNED 0x02200000ul
#define VA_BADPTR 0x40000000ul
#define VA_NONCANONICAL 0x0100000000000000ul

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define PTE_CODE (PTE_V | PTE_X | PTE_A)
#define PTE_CODE_U (PTE_V | PTE_X | PTE_U | PTE_A)

#define SATP_SV39 (8ul << 60)

/* Virtual page numbers (VA_4K(n)) per case. */
enum {
    VP_A = 0,          /* A: page_a */
    VP_B = 1,          /* C: page_b (straddle target) */
    VP_A_STRADDLE = 2, /* D: page_a again, next page unmapped */
    VP_UNMAPPED_3 = 3,
    VP_A2 = 4,      /* E: page_a2 */
    VP_B2 = 5,      /* E: page_b2 */
    VP_A2_PAIR = 6, /* F: page_a2 again, next page unmapped */
    VP_UNMAPPED_7 = 7,
    VP_U = 8,          /* G: page_a with U=1 */
    VP_NX = 9,         /* I: page_a without X */
    VP_A0 = 10,        /* J: page_a with A=0 */
    VP_DEVICE = 11,    /* K: leaf into the device quadrant */
    VP_ABOVE_MAP = 12, /* L: leaf above 4 GiB */
    VP_V0 = 13,        /* N */
    VP_WNR = 14,       /* O */
    VP_RSVD = 15,      /* P */
    VP_REMAP = 16,     /* U/V: page_a, remapped to page_a2 */
    VP_CHAIN = 17,     /* T: 11 x page_j, then page_e (17..28) */
    VP_CHAIN_END = 28,
    VP_NONLEAF = 29 /* R */
};

static inline void write_satp(unsigned long v)
{
    __asm__ volatile("csrw satp, %0" : : "r"(v));
}

static inline void sfence_vma(void)
{
    __asm__ volatile("sfence.vma");
}

static void build_tables(void)
{
    volatile unsigned long *root_a = (volatile unsigned long *) PT_ROOT_A;
    volatile unsigned long *root_b = (volatile unsigned long *) PT_ROOT_B;
    volatile unsigned long *l1_a = (volatile unsigned long *) PT_L1_A;
    volatile unsigned long *l0_a = (volatile unsigned long *) PT_L0_A;
    volatile unsigned long *l1_b = (volatile unsigned long *) PT_L1_B;
    volatile unsigned long *l0_b = (volatile unsigned long *) PT_L0_B;
    unsigned long pa_a = (unsigned long) itlb_page_a;
    unsigned long pa_b = (unsigned long) itlb_page_b;
    unsigned long pa_a2 = (unsigned long) itlb_page_a2;
    unsigned long pa_b2 = (unsigned long) itlb_page_b2;
    unsigned long pa_j = (unsigned long) itlb_page_j;
    unsigned long pa_e = (unsigned long) itlb_page_e;

    for (int i = 0; i < 512; i++) {
        root_a[i] = 0;
        root_b[i] = 0;
        l1_a[i] = 0;
        l0_a[i] = 0;
        l1_b[i] = 0;
        l0_b[i] = 0;
    }

    /* Root A: [0] -> L1 A; [1] -> pointer into BRAM (walker PMA refusal);
     * [2] -> 1 GiB identity leaf over DDR (the ddr-config program image and
     * the page tables' own frames). */
    root_a[0] = PTE_PPN(PT_L1_A) | PTE_V;
    root_a[1] = PTE_PPN(0x0ul) | PTE_V;
    root_a[2] = PTE_PPN(0x80000000ul) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;

    /* L1 A: [0] -> 2 MiB identity leaf over the low BRAM (the bram-config
     * program image); [2] -> L0 A (the VA_4K window); [17] -> misaligned
     * 2 MiB leaf. */
    l1_a[0] = PTE_PPN(0x0ul) | PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D;
    l1_a[2] = PTE_PPN(PT_L0_A) | PTE_V;
    l1_a[17] = PTE_PPN(pa_a) | PTE_CODE;

    l0_a[VP_A] = PTE_PPN(pa_a) | PTE_CODE;
    l0_a[VP_B] = PTE_PPN(pa_b) | PTE_CODE;
    l0_a[VP_A_STRADDLE] = PTE_PPN(pa_a) | PTE_CODE;
    l0_a[VP_UNMAPPED_3] = 0;
    l0_a[VP_A2] = PTE_PPN(pa_a2) | PTE_CODE;
    l0_a[VP_B2] = PTE_PPN(pa_b2) | PTE_CODE;
    l0_a[VP_A2_PAIR] = PTE_PPN(pa_a2) | PTE_CODE;
    l0_a[VP_UNMAPPED_7] = 0;
    l0_a[VP_U] = PTE_PPN(pa_a) | PTE_CODE_U;
    l0_a[VP_NX] = PTE_PPN(pa_a) | PTE_V | PTE_R | PTE_A;
    l0_a[VP_A0] = PTE_PPN(pa_a) | PTE_V | PTE_X;
    l0_a[VP_DEVICE] = PTE_PPN(0x40000000ul) | PTE_CODE;
    l0_a[VP_ABOVE_MAP] = PTE_PPN(0x100000000ul) | PTE_CODE;
    l0_a[VP_V0] = 0;
    l0_a[VP_WNR] = PTE_PPN(pa_a) | PTE_V | PTE_W | PTE_X | PTE_A;
    l0_a[VP_RSVD] = PTE_PPN(pa_a) | (1ul << 60) | PTE_CODE;
    l0_a[VP_REMAP] = PTE_PPN(pa_a) | PTE_CODE;
    for (int n = VP_CHAIN; n < VP_CHAIN_END; n++)
        l0_a[n] = PTE_PPN(pa_j) | PTE_CODE;
    l0_a[VP_CHAIN_END] = PTE_PPN(pa_e) | PTE_CODE;
    l0_a[VP_NONLEAF] = PTE_PPN(PT_L0_A) | PTE_V;

    /* Root B: only VA_4K(VP_REMAP), backed by page_a2 (satp switch). */
    root_b[0] = PTE_PPN(PT_L1_B) | PTE_V;
    l1_b[2] = PTE_PPN(PT_L0_B) | PTE_V;
    l0_b[VP_REMAP] = PTE_PPN(pa_a2) | PTE_CODE;
}

int main(void)
{
    int all_ok = 1;

    uart_puts("ITLB test (Sv39 fetch side)\r\n");

    set_trap_handler(&itlb_trap_handler);
    build_tables();

    /* Publish the tables, then turn Sv39 on (M-mode fetch stays physical). */
    sfence_vma();
    write_satp(SATP_SV39 | (PT_ROOT_A >> 12));

    /* A: 4 KiB non-identity code page from S. */
    sfence_vma();
    RUN_AT(VA_4K(VP_A), MPP_S);
    all_ok &= report_run("A 4k-page-s", 9, VA_4K(VP_A) + 4, 0xA1, 0);

    /* B: identity superpage (2 MiB bram / 1 GiB ddr). */
    sfence_vma();
    RUN_AT((unsigned long) snippet_identity, MPP_S);
    all_ok &= report_run("B identity-superpage", 9, (unsigned long) snippet_identity + 4, 0xC1, 0);

    /* C: page-crossing window with a straddling 32-bit instruction. */
    sfence_vma();
    RUN_AT(VA_4K(VP_A) + 0xFF8, MPP_S);
    all_ok &= report_run("C straddle-hit", 9, VA_4K(VP_B) + 2, 0xA3, 0xA4);

    /* D: straddle into an unmapped page -> 12, epc = the instruction,
     * tval = the second page (the faulting portion). */
    sfence_vma();
    RUN_AT(VA_4K(VP_A_STRADDLE) + 0xFF8, MPP_S);
    all_ok &=
        report_fault("D straddle-fault", 12, VA_4K(VP_A_STRADDLE) + 0xFFE, VA_4K(VP_UNMAPPED_3));

    /* E: compressed pair at the page end, next page mapped. */
    sfence_vma();
    RUN_AT(VA_4K(VP_A2) + 0xFFC, MPP_S);
    all_ok &= report_run("E pair-then-next-page", 9, VA_4K(VP_B2) + 4, 0xB1, 0);

    /* F: same pair, next page unmapped -> 12 at the next page base. */
    sfence_vma();
    RUN_AT(VA_4K(VP_A2_PAIR) + 0xFFC, MPP_S);
    all_ok &= report_fault("F pair-then-fault", 12, VA_4K(VP_UNMAPPED_7), VA_4K(VP_UNMAPPED_7));

    /* G: U page from U runs (ecall 8); the same page from S faults. */
    sfence_vma();
    RUN_AT(VA_4K(VP_U), MPP_U);
    all_ok &= report_run("G1 u-page-from-u", 8, VA_4K(VP_U) + 4, 0xA1, 0);
    sfence_vma();
    RUN_AT(VA_4K(VP_U), MPP_S);
    all_ok &= report_fault("G2 u-page-from-s", 12, VA_4K(VP_U), VA_4K(VP_U));

    /* H: S page from U -> 12. */
    sfence_vma();
    RUN_AT(VA_4K(VP_A), MPP_U);
    all_ok &= report_fault("H s-page-from-u", 12, VA_4K(VP_A), VA_4K(VP_A));

    /* I: X=0 -> 12. */
    sfence_vma();
    RUN_AT(VA_4K(VP_NX), MPP_S);
    all_ok &= report_fault("I no-x", 12, VA_4K(VP_NX), VA_4K(VP_NX));

    /* J: A=0 -> 12 (Svade). */
    sfence_vma();
    RUN_AT(VA_4K(VP_A0), MPP_S);
    all_ok &= report_fault("J a0", 12, VA_4K(VP_A0), VA_4K(VP_A0));

    /* K: leaf into the device quadrant -> access fault 1. */
    sfence_vma();
    RUN_AT(VA_4K(VP_DEVICE), MPP_S);
    all_ok &= report_fault("K device-leaf", 1, VA_4K(VP_DEVICE), VA_4K(VP_DEVICE));

    /* L: leaf above the map -> 1. */
    sfence_vma();
    RUN_AT(VA_4K(VP_ABOVE_MAP), MPP_S);
    all_ok &= report_fault("L leaf-above-map", 1, VA_4K(VP_ABOVE_MAP), VA_4K(VP_ABOVE_MAP));

    /* M: interior pointer into BRAM -> walker PMA refusal, 1. */
    sfence_vma();
    RUN_AT(VA_BADPTR, MPP_S);
    all_ok &= report_fault("M walker-pma", 1, VA_BADPTR, VA_BADPTR);

    /* N/O/P: malformed PTEs -> 12. */
    sfence_vma();
    RUN_AT(VA_4K(VP_V0), MPP_S);
    all_ok &= report_fault("N v0", 12, VA_4K(VP_V0), VA_4K(VP_V0));
    sfence_vma();
    RUN_AT(VA_4K(VP_WNR), MPP_S);
    all_ok &= report_fault("O w-not-r", 12, VA_4K(VP_WNR), VA_4K(VP_WNR));
    sfence_vma();
    RUN_AT(VA_4K(VP_RSVD), MPP_S);
    all_ok &= report_fault("P reserved-bit", 12, VA_4K(VP_RSVD), VA_4K(VP_RSVD));

    /* Q: misaligned 2 MiB superpage -> 12. */
    sfence_vma();
    RUN_AT(VA_2M_MISALIGNED, MPP_S);
    all_ok &= report_fault("Q misaligned-superpage", 12, VA_2M_MISALIGNED, VA_2M_MISALIGNED);

    /* R: non-leaf at level 0 -> 12. */
    sfence_vma();
    RUN_AT(VA_4K(VP_NONLEAF), MPP_S);
    all_ok &= report_fault("R nonleaf-l0", 12, VA_4K(VP_NONLEAF), VA_4K(VP_NONLEAF));

    /* S: non-canonical VA -> 12, no walk. */
    sfence_vma();
    RUN_AT(VA_NONCANONICAL, MPP_S);
    all_ok &= report_fault("S non-canonical", 12, VA_NONCANONICAL, VA_NONCANONICAL);

    /* T: 12-page chain (ITLB replacement), cold then warm. */
    sfence_vma();
    RUN_AT(VA_4K(VP_CHAIN), MPP_S);
    all_ok &= report_run("T1 chain-cold", 9, VA_4K(VP_CHAIN_END) + 4, 0xCC, 0);
    RUN_AT(VA_4K(VP_CHAIN), MPP_S);
    all_ok &= report_run("T2 chain-warm", 9, VA_4K(VP_CHAIN_END) + 4, 0xCC, 0);

    /* U: sfence visibility -- VP_REMAP: page_a, then page_a2 after a
     * rewrite + sfence. */
    sfence_vma();
    RUN_AT(VA_4K(VP_REMAP), MPP_S);
    all_ok &= report_run("U1 remap-before", 9, VA_4K(VP_REMAP) + 4, 0xA1, 0);
    *(volatile unsigned long *) (PT_L0_A + VP_REMAP * 8) =
        PTE_PPN((unsigned long) itlb_page_a2) | PTE_CODE;
    sfence_vma();
    RUN_AT(VA_4K(VP_REMAP), MPP_S);
    all_ok &= report_run("U2 remap-after", 9, VA_4K(VP_REMAP) + 4, 0xA5, 0);

    /* V: satp switch to root B retargets VP_REMAP (page_a2) with no sfence
     * (D10); back to root A afterwards. Root A now maps it to page_a2 as
     * well, so restore page_a first to make the switch observable. */
    *(volatile unsigned long *) (PT_L0_A + VP_REMAP * 8) =
        PTE_PPN((unsigned long) itlb_page_a) | PTE_CODE;
    sfence_vma();
    RUN_AT(VA_4K(VP_REMAP), MPP_S);
    all_ok &= report_run("V1 root-a", 9, VA_4K(VP_REMAP) + 4, 0xA1, 0);
    write_satp(SATP_SV39 | (PT_ROOT_B >> 12));
    RUN_AT(VA_4K(VP_REMAP), MPP_S);
    all_ok &= report_run("V2 root-b-switch", 9, VA_4K(VP_REMAP) + 4, 0xA5, 0);
    write_satp(SATP_SV39 | (PT_ROOT_A >> 12));
    RUN_AT(VA_4K(VP_REMAP), MPP_S);
    all_ok &= report_run("V3 root-a-switch", 9, VA_4K(VP_REMAP) + 4, 0xA1, 0);

    /* W: translation off again -- a wild PC is M2's access fault. */
    write_satp(0);
    RUN_AT(0x0000000100000000ul, MPP_S);
    all_ok &= report_fault("W bare-wild-pc", 1, 0x0000000100000000ul, 0x0000000100000000ul);

    uart_puts(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
