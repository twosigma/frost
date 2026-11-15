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
 * Address-space IDs, global pages and the SFENCE.VMA forms.
 *
 * satp.ASID is nine bits wide (Linux finds ASIDLEN by writing all ones to the
 * field and counting the bits that read back). Each TLB entry carries the ASID
 * it was installed under and the leaf's global bit; a lookup hits an entry of
 * its own ASID, or a global entry under any ASID. A satp write that changes the
 * ASID keeps every entry, so a context switch between two address spaces costs
 * no walks when each one's pages are resident. A write that changes the root
 * under the same ASID flushes everything, for software that never assigns
 * ASIDs.
 *
 * The S-mode body below maps one virtual page to different physical pages in
 * three address spaces (A, B, C), shares a global page between them, and puts
 * a one-instruction function at a fourth virtual page that differs per space.
 * It counts DTLB and ITLB walks around each access and checks:
 *   - two address spaces keep separate entries for the same VA, and switching
 *     back finds the first one's entry with no walk;
 *   - the global page loads with no walk under an ASID that never installed it;
 *   - the same root under a new ASID walks and then keeps both entries;
 *   - a new root under the same ASID flushes everything;
 *   - SFENCE.VMA with rs2 spares global entries and other ASIDs, with rs1 flushes
 *     the page in every ASID (global included), with both flushes one page of
 *     one ASID, with neither flushes everything;
 *   - a changed PTE is seen after the page's SFENCE.VMA;
 *   - ASID 0x1FF (the top of the range) works and satp reads it back;
 *   - the ITLB follows the same rules (a per-ASID code page).
 * Faults trap to M, which records the cause and returns to the M continuation.
 * The test's S code is uncompressed.
 */

#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

#define PT_RA 0x81200000ul /* root, level 1, level 0 of each space */
#define PT_RB 0x81203000ul
#define PT_RC 0x81206000ul
#define PA_XA 0x81210000ul
#define PA_XB 0x81211000ul
#define PA_XC 0x81212000ul
#define PA_XA2 0x81213000ul
#define PA_G 0x81214000ul
#define PA_CA 0x81215000ul
#define PA_CB 0x81216000ul

#define VA_X 0xC0000000ul
#define VA_G 0xC0001000ul
#define VA_CODE 0xC0002000ul
#define VA_BIG 0xC0008000ul /* 32 pages per space, for the context-switch timing */
#define PA_BIG_A 0x81220000ul
#define PA_BIG_B 0x81240000ul

#define PTE_V 0x001ul
#define PTE_R 0x002ul
#define PTE_W 0x004ul
#define PTE_X 0x008ul
#define PTE_G 0x020ul
#define PTE_A 0x040ul
#define PTE_D 0x080ul
#define PTE_PPN(pa) (((pa) >> 12) << 10)

#define SATP(asid, root) ((8ul << 60) | ((unsigned long) (asid) << 44) | ((root) >> 12))

#define NRES 60

volatile unsigned long g_res[NRES];
volatile unsigned long g_bad_cause;
volatile unsigned long g_msave[14];
volatile unsigned long g_satp[6];

void asid_trap_handler(void);
void asid_s_body(void);
void run_s_body(void);

/* M-mode handler. The body's closing ecall (cause 9) returns to the M
 * continuation in mscratch; any other cause is recorded and does the same. */
__asm__(".section .text\n"
        ".balign 4\n"
        ".global asid_trap_handler\n"
        "asid_trap_handler:\n"
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

/* Enter the S body with its registers loaded; return when it ecalls. */
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
        "    la   t0, asid_s_body\n"
        "    csrw mepc, t0\n"
        "    li   t0, 0x1800\n"
        "    csrc mstatus, t0\n"
        "    li   t0, 0x0800\n"
        "    csrs mstatus, t0\n"
        "    li   s0, 0xC0000000\n"
        "    la   s1, g_res\n"
        "    li   s2, 0xC0001000\n"
        "    li   s3, 0xC0002000\n"
        /* satp for A (ASID 1), B (ASID 2), A under ASID 3, B under ASID 1,
         * C (ASID 0x1FF), then the level-0 table of A. */
        "    la   t0, g_satp\n"
        "    ld   s4, 0(t0)\n"
        "    ld   s5, 8(t0)\n"
        "    ld   s6, 16(t0)\n"
        "    ld   s7, 24(t0)\n"
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

/* LD(base, value index, walk index): load a dword through base, store the value
 * at s1 + 8 * value index and the number of DTLB walks the load caused at
 * s1 + 8 * walk index. The walk counter (hpmcounter6) is read at commit, so the
 * two reads bracket exactly this load. */
#define LD(base, v, w)                                                                             \
    "    csrr t0, 0xC06\n"                                                                         \
    "    ld   a0, 0(" base ")\n"                                                                   \
    "    csrr t1, 0xC06\n"                                                                         \
    "    sub  t1, t1, t0\n"                                                                        \
    "    sd   a0, " #v "*8(s1)\n"                                                                  \
    "    sd   t1, " #w "*8(s1)\n"

/* CALL(v, w): call the code page at s3 (a0 = its constant) and store the value
 * and the ITLB walks (hpmcounter5) the call caused. */
#define CALL(v, w)                                                                                 \
    "    csrr t0, 0xC05\n"                                                                         \
    "    jalr t6, 0(s3)\n"                                                                         \
    "    csrr t1, 0xC05\n"                                                                         \
    "    sub  t1, t1, t0\n"                                                                        \
    "    sd   a0, " #v "*8(s1)\n"                                                                  \
    "    sd   t1, " #w "*8(s1)\n"

/* TOUCH32: load one dword from each of the 32 pages at s10 (a5 = 4096). The label 8
 * is local to each use. */
#define TOUCH32                                                                                    \
    "    mv   a3, s10\n"                                                                           \
    "    li   a2, 32\n"                                                                            \
    "8:  ld   a4, 0(a3)\n"                                                                         \
    "    add  a3, a3, a5\n"                                                                        \
    "    addi a2, a2, -1\n"                                                                        \
    "    bnez a2, 8b\n"

/* The S-mode body. a6 = 1 and a7 = 2 are the ASIDs of A and B. */
/* clang-format off */
__asm__(".section .text\n"
        ".balign 4\n"
        ".global asid_s_body\n"
        ".option push\n"
        ".option norvc\n"
        "asid_s_body:\n"
        "    li   a6, 1\n"
        "    li   a7, 2\n"
        /* A: cold loads walk. */
        "    csrw satp, s4\n"
        "    sfence.vma\n"
        LD("s0", 0, 1)
        LD("s2", 2, 3)
        /* B, a new ASID and root: X walks, the global page does not. */
        "    csrw satp, s5\n"
        LD("s0", 4, 5)
        LD("s2", 6, 7)
        /* Back to A: its entry is still resident. */
        "    csrw satp, s4\n"
        LD("s0", 8, 9)
        /* The same root under ASID 3 walks; A's entry stays resident. */
        "    csrw satp, s6\n"
        LD("s0", 10, 11)
        "    csrw satp, s4\n"
        LD("s0", 12, 13)
        /* A new root under the same ASID flushes everything. */
        "    csrw satp, s7\n"
        LD("s0", 14, 15)
        "    csrw satp, s4\n"
        LD("s0", 16, 17)
        /* Reload B and the global page, then flush ASID 2 only: A and the global
         * page are spared. */
        "    csrw satp, s5\n"
        LD("s0", 54, 55)
        "    csrw satp, s4\n"
        LD("s2", 56, 57)
        "    sfence.vma zero, a7\n"
        LD("s0", 18, 19)
        LD("s2", 20, 21)
        "    csrw satp, s5\n"
        LD("s0", 22, 23)
        /* One page of ASID 2 (B's X is resident again): A's entry survives. */
        "    csrw satp, s4\n"
        "    sfence.vma s0, a7\n"
        LD("s0", 24, 25)
        "    csrw satp, s5\n"
        LD("s0", 26, 27)
        /* One page in every ASID: X goes, the global page stays. */
        "    csrw satp, s4\n"
        "    sfence.vma s0, zero\n"
        LD("s0", 28, 29)
        LD("s2", 30, 31)
        /* An ASID flush at the global page's address spares the global entry. */
        "    sfence.vma s2, a6\n"
        LD("s2", 32, 33)
        /* The address alone flushes the global entry. */
        "    sfence.vma s2, zero\n"
        LD("s2", 34, 35)
        /* A changed PTE shows after the page's SFENCE.VMA by ASID and address. */
        "    li   t2, 0x20484CC7\n" /* (PA_XA2 >> 12) << 10 | V R W A D */
        "    sd   t2, 0(s9)\n"
        "    fence rw, rw\n"
        "    sfence.vma s0, a6\n"
        LD("s0", 36, 37)
        /* ASID 0x1FF, the top of the range, with its own root. */
        "    csrw satp, s8\n"
        LD("s0", 38, 39)
        "    csrw satp, s4\n"
        LD("s0", 40, 41)
        "    csrw satp, s8\n"
        LD("s0", 42, 43)
        "    csrr a0, satp\n"
        "    slli a0, a0, 4\n"
        "    srli a0, a0, 48\n"
        "    sd   a0, 44*8(s1)\n"
        /* The ITLB follows the same rules: a per-ASID code page. */
        "    csrw satp, s4\n"
        "    sfence.vma\n"
        CALL(45, 46)
        "    csrw satp, s5\n"
        CALL(47, 48)
        "    csrw satp, s4\n"
        CALL(49, 50)
        "    sfence.vma zero, a6\n"
        CALL(51, 52)
        /* Context switches: two address spaces of 32 pages each, entered by ASID
         * alone, then with the SFENCE.VMA an ASID-less kernel would run. */
        "    li   s10, 0xC0008000\n"
        "    li   a5, 4096\n"
        "    csrw satp, s4\n"
        "    sfence.vma\n"
        "    li   s7, 16\n"
        "    rdcycle t4\n"
        "7:  csrw satp, s4\n"
        TOUCH32
        "    csrw satp, s5\n"
        TOUCH32
        "    addi s7, s7, -1\n"
        "    bnez s7, 7b\n"
        "    rdcycle t5\n"
        "    sub  a0, t5, t4\n"
        "    sd   a0, 58*8(s1)\n"
        "    li   s7, 16\n"
        "    rdcycle t4\n"
        "7:  csrw satp, s4\n"
        "    sfence.vma\n"
        TOUCH32
        "    csrw satp, s5\n"
        "    sfence.vma\n"
        TOUCH32
        "    addi s7, s7, -1\n"
        "    bnez s7, 7b\n"
        "    rdcycle t5\n"
        "    sub  a0, t5, t4\n"
        "    sd   a0, 59*8(s1)\n"
        "    ecall\n"
        ".option pop\n");
/* clang-format on */

static int check(const char *name, unsigned long got, unsigned long want)
{
    int ok = got == want;
    uart_printf("%s %s got=0x%lx want=0x%lx\n", ok ? "[PASS]" : "[FAIL]", name, got, want);
    return ok;
}

static int walked(const char *name, unsigned long walks, int expect_walk)
{
    int ok = expect_walk ? walks >= 1 : walks == 0;
    uart_printf("%s %s walks=%lu expected %s\n",
                ok ? "[PASS]" : "[FAIL]",
                name,
                walks,
                expect_walk ? ">= 1" : "0");
    return ok;
}

/* One address space: identity gigapages (global, shared by every space), then
 * X mapped to x_pa, the global page, and the code page. */
static void
build_space(unsigned long root, unsigned long x_pa, unsigned long code_pa, unsigned long big_pa)
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
    for (unsigned long i = 0; i < 32; i++)
        l0[8 + i] = PTE_PPN(big_pa + i * 4096) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    if (code_pa)
        l0[2] = PTE_PPN(code_pa) | PTE_V | PTE_R | PTE_X | PTE_A;
}

int main(void)
{
    int ok = 1;

    /* Linux's probe for ASIDLEN: write ones to the ASID field, read it back. */
    csr_write(satp, 0xFFFFul << 44);
    unsigned long probe = csr_read(satp);
    csr_write(satp, 0);
    unsigned long asidlen = 0;
    for (unsigned long v = probe >> 44; v; v >>= 1)
        asidlen++;

    g_satp[0] = SATP(1, PT_RA);
    g_satp[1] = SATP(2, PT_RB);
    g_satp[2] = SATP(3, PT_RA);
    g_satp[3] = SATP(1, PT_RB);
    g_satp[4] = SATP(0x1FF, PT_RC);
    g_satp[5] = PT_RA + 0x2000;
    build_space(PT_RA, PA_XA, PA_CA, PA_BIG_A);
    build_space(PT_RB, PA_XB, PA_CB, PA_BIG_B);
    build_space(PT_RC, PA_XC, 0, PA_BIG_A);
    *(volatile unsigned long *) PA_XA = 0xA1;
    *(volatile unsigned long *) PA_XB = 0xB2;
    *(volatile unsigned long *) PA_XC = 0xC4;
    *(volatile unsigned long *) PA_XA2 = 0xA3;
    *(volatile unsigned long *) PA_G = 0x6C;
    /* li a0, 0x11 ; jr t6   and   li a0, 0x22 ; jr t6 */
    ((volatile uint32_t *) PA_CA)[0] = 0x01100513;
    ((volatile uint32_t *) PA_CA)[1] = 0x000F8067;
    ((volatile uint32_t *) PA_CB)[0] = 0x02200513;
    ((volatile uint32_t *) PA_CB)[1] = 0x000F8067;
    __asm__ volatile("fence rw, rw\n fence.i\n" ::: "memory");

    /* ITLB walks, DTLB walks and walker busy cycles; all modes may read them. */
    csr_write_imm(0x325, 5);
    csr_write_imm(0x326, 6);
    csr_write_imm(0x328, 16); /* HPM8 = page-walker busy cycles */
    csr_write_imm(0x320, 0);
    csr_write_imm(0x306, 0x1ff);
    csr_write(medeleg, 0);
    g_bad_cause = 0;
    set_trap_handler(&asid_trap_handler);

    run_s_body();
    csr_write(satp, 0);

    ok &= check("unexpected-trap", g_bad_cause, 0);
    ok &= check("asidlen", asidlen, 9);
    ok &= check("0 A-x", g_res[0], 0xA1);
    ok &= walked("1 A-x-cold", g_res[1], 1);
    ok &= check("2 A-g", g_res[2], 0x6C);
    ok &= walked("3 A-g-cold", g_res[3], 1);
    ok &= check("4 B-x", g_res[4], 0xB2);
    ok &= walked("5 B-x-new-asid", g_res[5], 1);
    ok &= check("6 B-g", g_res[6], 0x6C);
    ok &= walked("7 B-g-shared-global", g_res[7], 0);
    ok &= check("8 A-x-again", g_res[8], 0xA1);
    ok &= walked("9 A-x-kept-across-B", g_res[9], 0);
    ok &= check("10 A3-x", g_res[10], 0xA1);
    ok &= walked("11 A3-x-new-asid-same-root", g_res[11], 1);
    ok &= check("12 A-x-after-A3", g_res[12], 0xA1);
    ok &= walked("13 A-x-kept-across-A3", g_res[13], 0);
    ok &= check("14 B1-x", g_res[14], 0xB2);
    ok &= walked("15 B1-x-root-switch-same-asid", g_res[15], 1);
    ok &= check("16 A-x-after-B1", g_res[16], 0xA1);
    ok &= walked("17 A-x-root-switch-flushes", g_res[17], 1);
    ok &= check("54 B-x-reload", g_res[54], 0xB2);
    ok &= check("18 sfence-asid2-A-x", g_res[18], 0xA1);
    ok &= walked("19 sfence-asid2-spares-A", g_res[19], 0);
    ok &= check("20 sfence-asid2-g", g_res[20], 0x6C);
    ok &= walked("21 sfence-asid2-spares-global", g_res[21], 0);
    ok &= check("22 sfence-asid2-B-x", g_res[22], 0xB2);
    ok &= walked("23 sfence-asid2-flushes-B", g_res[23], 1);
    ok &= check("24 sfence-page-asid2-A-x", g_res[24], 0xA1);
    ok &= walked("25 sfence-page-asid2-spares-A", g_res[25], 0);
    ok &= check("26 sfence-page-asid2-B-x", g_res[26], 0xB2);
    ok &= walked("27 sfence-page-asid2-flushes-B", g_res[27], 1);
    ok &= check("28 sfence-page-A-x", g_res[28], 0xA1);
    ok &= walked("29 sfence-page-all-asids-flushes-A", g_res[29], 1);
    ok &= check("30 sfence-page-g", g_res[30], 0x6C);
    ok &= walked("31 sfence-page-spares-other-page", g_res[31], 0);
    ok &= check("32 sfence-g-asid1", g_res[32], 0x6C);
    ok &= walked("33 sfence-asid-spares-global-page", g_res[33], 0);
    ok &= check("34 sfence-g-page", g_res[34], 0x6C);
    ok &= walked("35 sfence-page-flushes-global", g_res[35], 1);
    ok &= check("36 pte-change-seen", g_res[36], 0xA3);
    ok &= walked("37 pte-change-walked", g_res[37], 1);
    ok &= check("38 C-x", g_res[38], 0xC4);
    ok &= walked("39 C-x-asid-1ff", g_res[39], 1);
    ok &= check("40 A-x-after-C", g_res[40], 0xA3);
    ok &= walked("41 A-x-kept-across-C", g_res[41], 0);
    ok &= check("42 C-x-again", g_res[42], 0xC4);
    ok &= walked("43 C-x-kept", g_res[43], 0);
    ok &= check("44 satp-asid-readback", g_res[44], 0x1FF);
    ok &= check("45 A-code", g_res[45], 0x11);
    ok &= walked("46 A-code-cold", g_res[46], 1);
    ok &= check("47 B-code", g_res[47], 0x22);
    ok &= walked("48 B-code-new-asid", g_res[48], 1);
    ok &= check("49 A-code-again", g_res[49], 0x11);
    ok &= walked("50 A-code-kept-across-B", g_res[50], 0);
    ok &= check("51 A-code-after-sfence", g_res[51], 0x11);
    ok &= walked("52 A-code-sfence-asid1-flushes", g_res[52], 1);
    uart_printf("ASIDTEST asidlen=%lu satp_probe=0x%lx\n", asidlen, probe);
    uart_printf("ASIDTEST ctxswitch switches=32 pages_per_switch=32 asid_cycles=%lu "
                "sfence_cycles=%lu per_switch_asid=%lu per_switch_sfence=%lu\n",
                g_res[58],
                g_res[59],
                g_res[58] / 32,
                g_res[59] / 32);
    uart_puts(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    return ok ? 0 : 1;
}
