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
 * Sv39 data-translation directed test. Phase 3 M4 (plan D15).
 *
 * The fetch side is untranslated until M5, so every translated access runs
 * through an MPRV window: M-mode sets mstatus.MPP to S or U and MPRV=1,
 * performs exactly the accesses under test, and drops MPRV. Code fetch and
 * the checker stay physical throughout. All traps come to M (medeleg=0) and
 * are recorded by the pma_fault_test-style bounce handler. The first fault
 * in a case wins; a case that does not fault falls through to an ecall,
 * which records cause 11. A trap inside a window is benign: the trap sets
 * MPP=M, so the handler and the continuation run untranslated even with
 * MPRV still up, and the case epilogue clears MPRV.
 *
 * Page tables live in cached DDR. The walker reads through the shared level,
 * never the L1D, so table stores become visible only through SFENCE.VMA's
 * L1D writeback-all. The test builds every table up front and publishes them
 * with one sfence, which is the software contract. Case K rewrites a PTE
 * mid-test and issues its own sfence. Data seeds need no publishing:
 * translated loads and stores use the same PA-indexed L1D that the M-mode
 * seeds dirtied.
 *
 * Matrix (fault cases check cause and mtval; loads also check the value):
 *   Q. M-mode accesses stay untranslated while satp holds Sv39 (MPRV=0).
 *   A. 4 KiB non-identity R/W page: translated store/load round-trip, with
 *      the backing frame verified physically. The VA sits in the
 *      BRAM-to-device hole, so untranslated leakage would PMA-fault.
 *   B. 2 MiB superpage round-trip through a level-1 leaf.
 *   C. 1 GiB identity leaf over DDR.
 *   D. Permissions: store to R-only -> 15; load from R-only ok; U-page
 *      from S with SUM=0 -> 13, SUM=1 -> ok; U-page from U -> ok; S-page
 *      from U -> 13.
 *   E. MXR: X-only page load with MXR=0 -> 13, MXR=1 -> value.
 *   F. Svade: A=0 load -> 13; D=0 load ok, D=0 store -> 15.
 *   G. Malformed PTEs: V=0 -> 13; W&!R -> 13; reserved high bit -> 13;
 *      misaligned 2 MiB superpage -> 13; non-leaf at level 0 -> 13.
 *   H. Out-of-map leaf PPN -> access fault (5 load / 7 store).
 *   I. Walker PMA: interior pointer PTE aimed at BRAM -> access fault of
 *      the original access type (page tables must live in cached DDR).
 *   J. Non-canonical VA -> 13 without walking, mtval = the full VA.
 *   K. sfence.vma visibility: PTE rewritten to a new frame, sfence, next
 *      access sees the new frame (the dirty-PTE writeback-all property).
 *   L. satp switch (D10): writing satp to a second pre-built root
 *      retargets the same VA with no explicit sfence.
 *   W. Wrong-path loads and stores under translation: a loop that walks a
 *      NULL-terminated pointer list (the kernel's zonelist shape) exits on a
 *      mispredicted branch, so the squashed iteration's loads/stores from
 *      NULL+offset miss the DTLB and start walks that refuse. Neither a
 *      fault nor a stale address may reach the correct-path accesses that
 *      reuse the squashed ROB tags (the M7 Linux boot died here: a memory
 *      op that issued in the flush cycle survived in the translation stage).
 *   M. LR/SC translated: LR+SC round-trip on R/W succeeds (rd=0); a bare
 *      SC to an R-only page -> 15 (SC must translate and fault; the
 *      may-fail-for-any-reason allowance never suppresses exceptions).
 *   N. AMO translated: amoadd round-trip on R/W; AMO to R-only -> 15.
 *   O. Device page: mtime readable through a mapped device-quadrant page.
 *   P. Bare-domain compliance (translation off, M-mode): misaligned SC ->
 *      6 (was silent failure) and misaligned AMO -> 6 (was 4), mtval
 *      exact.
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
static volatile unsigned long g_val;

#define LREG "ld"
#define SREG "sd"

/* M-mode bounce handler (pma_fault_test shape): record mcause/mepc/mtval
 * once per case, force MPP=M, return to the mscratch continuation. */
__attribute__((naked, aligned(4))) static void vm_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n" LREG " t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n" SREG " t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_epc\n" SREG " t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la   t1, g_tval\n" SREG " t0, 0(t1)\n"
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/* Run one trigger body; a fault mid-body skips the rest of the body (the
 * continuation is past the trailing ecall). MPRV is force-cleared after
 * every case, faulting or not. */
#define RUN_CASE(body_asm, ...)                                                                    \
    do {                                                                                           \
        g_cause = ~0ul;                                                                            \
        g_epc = ~0ul;                                                                              \
        g_tval = ~0ul;                                                                             \
        __asm__ volatile("la   t0, 1f\n"                                                           \
                         "csrw mscratch, t0\n" body_asm "\n"                                       \
                         "ecall\n"                                                                 \
                         "1:\n"                                                                    \
                         :                                                                         \
                         : __VA_ARGS__                                                             \
                         : "t0", "t1", "t2", "t3", "t4", "memory");                                \
        __asm__ volatile("li t0, 0x20000\n csrc mstatus, t0" ::: "t0");                            \
    } while (0)

/* Window preambles: set MPP (S = 01, U = 00) then MPRV. WIN_END drops MPRV
 * on the in-body no-fault path. The trailing ecall would run physical
 * either way, since ecall from M keeps the privilege at M; dropping MPRV
 * bounds the window to the accesses under test. */
#define WIN_S                                                                                      \
    "li   t4, 0x1800\n"                                                                            \
    "csrc mstatus, t4\n"                                                                           \
    "li   t4, 0x0800\n"                                                                            \
    "csrs mstatus, t4\n"                                                                           \
    "li   t4, 0x20000\n"                                                                           \
    "csrs mstatus, t4\n"
#define WIN_U                                                                                      \
    "li   t4, 0x1800\n"                                                                            \
    "csrc mstatus, t4\n"                                                                           \
    "li   t4, 0x20000\n"                                                                           \
    "csrs mstatus, t4\n"
#define WIN_END                                                                                    \
    "li   t4, 0x20000\n"                                                                           \
    "csrc mstatus, t4\n"

#define MSTATUS_SUM (1ul << 18)
#define MSTATUS_MXR (1ul << 19)

static inline void mstatus_set(unsigned long bits)
{
    __asm__ volatile("csrs mstatus, %0" : : "r"(bits));
}

static inline void mstatus_clear(unsigned long bits)
{
    __asm__ volatile("csrc mstatus, %0" : : "r"(bits));
}

static int report3(const char *name,
                   unsigned long want_cause,
                   unsigned long want_tval,
                   unsigned long want_epc,
                   int check_epc)
{
    int ok = (g_cause == want_cause) && (g_tval == want_tval) && (!check_epc || g_epc == want_epc);
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

static int report_val(const char *name, unsigned long got, unsigned long want)
{
    int ok = (got == want) && (g_cause == 11ul);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" val=");
    uart_hex(got);
    uart_puts(" cause=");
    uart_hex(g_cause);
    uart_puts("\r\n");
    return ok;
}

/* --------------------------------------------------------------------------
 * Physical layout (cached DDR, 64 MiB model, clear of any program image):
 *   root A   0x8100_0000   root B  0x8100_1000
 *   L1 A     0x8100_2000   L0 A    0x8100_3000
 *   L1 B     0x8100_4000   L0 B    0x8100_5000
 *   4K frames 0x8110_0000 + n*4K   2M frame 0x8120_0000
 *   1G-case touch offset 0x8300_0000 (inside the identity leaf)
 * Virtual layout: 4 KiB pages at 0x0040_0000 + n*4K (vpn2=0, vpn1=2,
 * vpn0=n); 2 MiB leaves at vpn1=16/17 (VA 0x0200_0000 / 0x0220_0000); the
 * 1 GiB identity leaf at vpn2=2 (VA 0x8000_0000); the bad-pointer subtree
 * at vpn2=1 (VA 0x4000_0000).
 * -------------------------------------------------------------------------- */
#define PT_ROOT_A 0x81000000ul
#define PT_ROOT_B 0x81001000ul
#define PT_L1_A 0x81002000ul
#define PT_L0_A 0x81003000ul
#define PT_L1_B 0x81004000ul
#define PT_L0_B 0x81005000ul
#define FRAME(n) (0x81100000ul + ((unsigned long) (n) << 12))
#define FRAME_2M 0x81200000ul

#define VA_4K(n) (0x00400000ul + ((unsigned long) (n) << 12))
#define VA_2M 0x02000000ul
#define VA_2M_MISALIGNED 0x02200000ul
#define VA_1G_TOUCH 0x83000000ul
#define VA_BADPTR 0x40000000ul

#define PTE_V (1ul << 0)
#define PTE_R (1ul << 1)
#define PTE_W (1ul << 2)
#define PTE_X (1ul << 3)
#define PTE_U (1ul << 4)
#define PTE_A (1ul << 6)
#define PTE_D (1ul << 7)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)

#define SATP_SV39 (8ul << 60)

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

    for (int i = 0; i < 512; i++) {
        root_a[i] = 0;
        root_b[i] = 0;
        l1_a[i] = 0;
        l0_a[i] = 0;
        l1_b[i] = 0;
        l0_b[i] = 0;
    }

    /* Root A: [0] -> L1 A; [1] -> pointer aimed at BRAM (walker PMA
     * refusal: page tables must live in cached DDR); [2] -> 1 GiB DDR
     * identity leaf. */
    root_a[0] = PTE_PPN(PT_L1_A) | PTE_V;
    root_a[1] = PTE_PPN(0x0ul) | PTE_V;
    root_a[2] = PTE_PPN(0x80000000ul) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;

    /* L1 A: [2] -> L0 A (the VA_4K window); [16] -> 2 MiB leaf; [17] ->
     * misaligned 2 MiB leaf (its PPN low bits are nonzero). */
    l1_a[2] = PTE_PPN(PT_L0_A) | PTE_V;
    l1_a[16] = PTE_PPN(FRAME_2M) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    l1_a[17] = PTE_PPN(FRAME(0)) | PTE_V | PTE_R | PTE_A;

    /* L0 A permission flavors: VA_4K(n) -> FRAME(n). */
    l0_a[0] = PTE_PPN(FRAME(0)) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    l0_a[1] = PTE_PPN(FRAME(1)) | PTE_V | PTE_R | PTE_A;                         /* R-only */
    l0_a[2] = PTE_PPN(FRAME(2)) | PTE_V | PTE_R | PTE_W | PTE_A;                 /* D=0 */
    l0_a[3] = PTE_PPN(FRAME(3)) | PTE_V | PTE_R | PTE_W | PTE_U | PTE_A | PTE_D; /* U */
    l0_a[4] = PTE_PPN(FRAME(4)) | PTE_V | PTE_X | PTE_A;                         /* X-only */
    l0_a[5] = PTE_PPN(FRAME(5)) | PTE_V | PTE_R | PTE_W | PTE_D;                 /* A=0 */
    l0_a[6] = 0;                                                                 /* V=0 */
    l0_a[7] = PTE_PPN(FRAME(7)) | PTE_V | PTE_W | PTE_A | PTE_D;                 /* W&!R */
    l0_a[8] = PTE_PPN(FRAME(8)) | (1ul << 60) | PTE_V | PTE_R | PTE_A;           /* rsvd */
    l0_a[9] = PTE_PPN(0x100000000ul) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;    /* >4G */
    l0_a[10] = PTE_PPN(PT_L0_A) | PTE_V;                                         /* nonleaf */
    l0_a[11] = PTE_PPN(0x40000000ul) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;    /* device */
    l0_a[12] = PTE_PPN(FRAME(12)) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;       /* K rewrite */
    l0_a[13] = PTE_PPN(FRAME(13)) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;       /* LR/SC ok */

    /* Root B: same VA_4K(0) window backed by FRAME(14) (satp-switch). */
    root_b[0] = PTE_PPN(PT_L1_B) | PTE_V;
    l1_b[2] = PTE_PPN(PT_L0_B) | PTE_V;
    l0_b[0] = PTE_PPN(FRAME(14)) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
}

int main(void)
{
    int all_ok = 1;

    uart_puts("VM test (Sv39 data side, MPRV windows)\r\n");

    set_trap_handler(&vm_trap_handler);

    build_tables();

    /* Seed frames physically. */
    *(volatile unsigned long *) FRAME(0) = 0;
    *(volatile unsigned long *) FRAME(1) = 0x1111111111111111ul;
    *(volatile unsigned long *) FRAME(2) = 0x2222222222222222ul;
    *(volatile unsigned long *) FRAME(3) = 0x3333333333333333ul;
    *(volatile unsigned long *) FRAME(4) = 0x4444444444444444ul;
    *(volatile unsigned long *) FRAME(12) = 0xAAAAAAAAAAAAAAAAul;
    *(volatile unsigned long *) FRAME(13) = 0x5150515051505150ul;
    *(volatile unsigned long *) FRAME(14) = 0xBBBBBBBBBBBBBBBBul;
    *(volatile unsigned long *) (FRAME_2M + 0x12340ul) = 0;
    *(volatile unsigned long *) VA_1G_TOUCH = 0x1919191919191919ul;
    /* W: a zone object at VA_4K(0)+0x800 (fields at the kernel's offsets)
     * and a NULL-terminated zoneref list at VA_4K(0)+0x100, both RW/S. */
    for (int i = 0; i < 0x90 / 8; i++)
        ((volatile unsigned long *) (FRAME(0) + 0x800))[i] =
            0x2000000000000000ul + (unsigned long) i;

    /* Publish the tables to the shared level, then enable Sv39. */
    sfence_vma();
    write_satp(SATP_SV39 | (PT_ROOT_A >> 12));

    /* Q: M-mode (MPRV=0) stays untranslated with satp live. The address is a
     * literal in the asm text because an "i" operand sign-extends 0x81100000
     * to a wild 64-bit address. */
    RUN_CASE("li  t1, 0x81100000\n" LREG " t2, 0(t1)\n"
             "la  t1, g_val\n" SREG " t2, 0(t1)");
    all_ok &= report_val("Q m-mode-untranslated", g_val, 0);

    /* A: 4K non-identity R/W round-trip through a VA in the hole. */
    RUN_CASE(WIN_S "li  t1, 0x00400000\n"
                   "li  t2, 0xD0D0D0D0D0D0D0D\n" SREG " t2, 0(t1)\n"
                   "mv  t2, zero\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("A 4k-rw-roundtrip", g_val, 0xD0D0D0D0D0D0D0Dul);
    if (*(volatile unsigned long *) FRAME(0) != 0xD0D0D0D0D0D0D0Dul) {
        uart_puts("[FAIL] A backing-frame\r\n");
        all_ok = 0;
    }

    /* B: 2 MiB superpage round-trip at an interior offset. */
    RUN_CASE(WIN_S "li  t1, 0x02012340\n"
                   "li  t2, 0x2A2A2A2A2A2A2A2A\n" SREG " t2, 0(t1)\n"
                   "mv  t2, zero\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("B 2m-roundtrip", g_val, 0x2A2A2A2A2A2A2A2Aul);
    if (*(volatile unsigned long *) (FRAME_2M + 0x12340ul) != 0x2A2A2A2A2A2A2A2Aul) {
        uart_puts("[FAIL] B backing-frame\r\n");
        all_ok = 0;
    }

    /* C: 1 GiB identity leaf over DDR. */
    RUN_CASE(WIN_S "li  t1, 0x83000000\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("C 1g-identity-load", g_val, 0x1919191919191919ul);

    /* D1: store to R-only -> 15, mtval = VA. */
    RUN_CASE(WIN_S "li t1, 0x00401000\n" SREG " t2, 0(t1)");
    all_ok &= report3("D1 store-r-only", 15, VA_4K(1), 0, 0);

    /* D2: load from R-only ok. */
    RUN_CASE(WIN_S "li t1, 0x00401000\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("D2 load-r-only", g_val, 0x1111111111111111ul);

    /* D3: U-page from S, SUM=0 -> 13. */
    RUN_CASE(WIN_S "li t1, 0x00403000\n" LREG " t2, 0(t1)");
    all_ok &= report3("D3 s-to-u-no-sum", 13, VA_4K(3), 0, 0);

    /* D4: U-page from S, SUM=1 -> value. */
    mstatus_set(MSTATUS_SUM);
    RUN_CASE(WIN_S "li t1, 0x00403000\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("D4 s-to-u-sum", g_val, 0x3333333333333333ul);
    mstatus_clear(MSTATUS_SUM);

    /* D5: U-page from U -> value. */
    RUN_CASE(WIN_U "li t1, 0x00403000\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("D5 u-to-u", g_val, 0x3333333333333333ul);

    /* D6: S-page from U -> 13. */
    RUN_CASE(WIN_U "li t1, 0x00400000\n" LREG " t2, 0(t1)");
    all_ok &= report3("D6 u-to-s-page", 13, VA_4K(0), 0, 0);

    /* E1: X-only load, MXR=0 -> 13. */
    RUN_CASE(WIN_S "li t1, 0x00404000\n" LREG " t2, 0(t1)");
    all_ok &= report3("E1 xonly-no-mxr", 13, VA_4K(4), 0, 0);

    /* E2: X-only load, MXR=1 -> value. */
    mstatus_set(MSTATUS_MXR);
    RUN_CASE(WIN_S "li t1, 0x00404000\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("E2 xonly-mxr", g_val, 0x4444444444444444ul);
    mstatus_clear(MSTATUS_MXR);

    /* F1: A=0 load -> 13 (Svade). */
    RUN_CASE(WIN_S "li t1, 0x00405000\n" LREG " t2, 0(t1)");
    all_ok &= report3("F1 a0-load", 13, VA_4K(5), 0, 0);

    /* F2: D=0 load ok. */
    RUN_CASE(WIN_S "li t1, 0x00402000\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("F2 d0-load", g_val, 0x2222222222222222ul);

    /* F3: D=0 store -> 15 (Svade). */
    RUN_CASE(WIN_S "li t1, 0x00402000\n" SREG " t2, 0(t1)");
    all_ok &= report3("F3 d0-store", 15, VA_4K(2), 0, 0);

    /* G1: V=0 -> 13. */
    RUN_CASE(WIN_S "li t1, 0x00406000\n" LREG " t2, 0(t1)");
    all_ok &= report3("G1 v0", 13, VA_4K(6), 0, 0);

    /* G2: W&!R -> 13. */
    RUN_CASE(WIN_S "li t1, 0x00407000\n" LREG " t2, 0(t1)");
    all_ok &= report3("G2 w-not-r", 13, VA_4K(7), 0, 0);

    /* G3: reserved high bit -> 13. */
    RUN_CASE(WIN_S "li t1, 0x00408000\n" LREG " t2, 0(t1)");
    all_ok &= report3("G3 reserved-bit", 13, VA_4K(8), 0, 0);

    /* G4: misaligned 2 MiB superpage -> 13. */
    RUN_CASE(WIN_S "li t1, 0x02200000\n" LREG " t2, 0(t1)");
    all_ok &= report3("G4 misaligned-superpage", 13, VA_2M_MISALIGNED, 0, 0);

    /* G5: non-leaf at level 0 -> 13. */
    RUN_CASE(WIN_S "li t1, 0x0040A000\n" LREG " t2, 0(t1)");
    all_ok &= report3("G5 nonleaf-l0", 13, VA_4K(10), 0, 0);

    /* H1: out-of-map leaf, load -> 5. */
    RUN_CASE(WIN_S "li t1, 0x00409000\n" LREG " t2, 0(t1)");
    all_ok &= report3("H1 leaf-above-map-load", 5, VA_4K(9), 0, 0);

    /* H2: out-of-map leaf, store -> 7. */
    RUN_CASE(WIN_S "li t1, 0x00409000\n" SREG " t2, 0(t1)");
    all_ok &= report3("H2 leaf-above-map-store", 7, VA_4K(9), 0, 0);

    /* I1: bad interior pointer (BRAM), load -> 5. */
    RUN_CASE(WIN_S "li t1, 0x40000000\n" LREG " t2, 0(t1)");
    all_ok &= report3("I1 walker-pma-load", 5, VA_BADPTR, 0, 0);

    /* I2: bad interior pointer, store -> 7. */
    RUN_CASE(WIN_S "li t1, 0x40000000\n" SREG " t2, 0(t1)");
    all_ok &= report3("I2 walker-pma-store", 7, VA_BADPTR, 0, 0);

    /* J: non-canonical VA -> 13, mtval = the full VA (no walk). */
    RUN_CASE(WIN_S "li t1, 0x0100000000000000\n" LREG " t2, 0(t1)");
    all_ok &= report3("J non-canonical", 13, 0x0100000000000000ul, 0, 0);

    /* K: sfence visibility. Rewrite L0[12] to FRAME(14), sfence, then read. */
    *(volatile unsigned long *) (PT_L0_A + 12 * 8) =
        PTE_PPN(FRAME(14)) | PTE_V | PTE_R | PTE_W | PTE_A | PTE_D;
    sfence_vma();
    RUN_CASE(WIN_S "li t1, 0x0040C000\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("K sfence-visibility", g_val, 0xBBBBBBBBBBBBBBBBul);

    /* L: satp switch to root B retargets VA_4K(0) with no sfence. */
    write_satp(SATP_SV39 | (PT_ROOT_B >> 12));
    RUN_CASE(WIN_S "li t1, 0x00400000\n" LREG " t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG
                   " t2, 0(t1)");
    all_ok &= report_val("L satp-switch", g_val, 0xBBBBBBBBBBBBBBBBul);
    write_satp(SATP_SV39 | (PT_ROOT_A >> 12));

    /* M1: translated LR/SC round-trip on an R/W page. SC must succeed. */
    RUN_CASE(WIN_S "li  t1, 0x0040D000\n"
                   "lr.d t2, (t1)\n"
                   "addi t2, t2, 1\n"
                   "sc.d t3, t2, (t1)\n" WIN_END "la  t1, g_val\n" SREG " t3, 0(t1)");
    all_ok &= report_val("M1 lrsc-success", g_val, 0);
    if (*(volatile unsigned long *) FRAME(13) != 0x5150515051505151ul) {
        uart_puts("[FAIL] M1 backing-frame\r\n");
        all_ok = 0;
    }

    /* M2: bare SC to an R-only page -> 15 (SC translates and faults). */
    RUN_CASE(WIN_S "li t1, 0x00401000\n"
                   "sc.d t3, t2, (t1)");
    all_ok &= report3("M2 sc-page-fault", 15, VA_4K(1), 0, 0);

    /* N1: AMO round-trip on R/W. */
    RUN_CASE(WIN_S "li  t1, 0x00400000\n"
                   "li  t2, 5\n"
                   "amoadd.d t3, t2, (t1)\n" WIN_END "la  t1, g_val\n" SREG " t3, 0(t1)");
    all_ok &= report_val("N1 amo-roundtrip", g_val, 0xD0D0D0D0D0D0D0Dul);
    if (*(volatile unsigned long *) FRAME(0) != 0xD0D0D0D0D0D0D12ul) {
        uart_puts("[FAIL] N1 backing-frame\r\n");
        all_ok = 0;
    }

    /* N2: AMO to R-only -> 15. */
    RUN_CASE(WIN_S "li t1, 0x00401000\n"
                   "amoadd.d t3, t2, (t1)");
    all_ok &= report3("N2 amo-page-fault", 15, VA_4K(1), 0, 0);

    /* O: device page through translation. Reads mtime via VA_4K(11)+0x10. */
    RUN_CASE(WIN_S "li t1, 0x0040B010\n"
                   "lw  t2, 0(t1)\n" WIN_END "la  t1, g_val\n" SREG " t2, 0(t1)");
    {
        int o_ok = (g_cause == 11ul);
        uart_puts(o_ok ? "[PASS] " : "[FAIL] ");
        uart_puts("O device-page cause=");
        uart_hex(g_cause);
        uart_puts(" mtime=");
        uart_hex(g_val);
        uart_puts("\r\n");
        all_ok &= o_ok;
    }

    /* P1: misaligned SC (translation off) -> 6, mtval exact. */
    RUN_CASE("li  t1, 0x81103002\n"
             "sc.w t3, t2, (t1)");
    all_ok &= report3("P1 misaligned-sc", 6, 0x81103002ul, 0, 0);

    /* P2: misaligned AMO (translation off) -> 6 (was 4), mtval exact. */
    RUN_CASE("li  t1, 0x81103002\n"
             "amoadd.w t3, t2, (t1)");
    all_ok &= report3("P2 misaligned-amo", 6, 0x81103002ul, 0, 0);

    /* W: wrong-path NULL-pointer loads/stores under translation. The list
     * has n live zonerefs then a NULL; the exit branch is mispredicted taken
     * on the last iteration after n iterations trained it. The squashed
     * iteration's loads at 16/32/136(NULL) (store variant: a store at
     * 16(NULL)) miss the DTLB (VA 0 is unmapped in root A) and start walks
     * that refuse. The correct path continues with loads (stores) that take
     * the very ROB tags the squashed accesses held, with their base register
     * set before the loop so no other instruction sits between the branch
     * and them; they must complete unfaulted with their own addresses and
     * data. Several list lengths and repeats vary the issue timing against
     * the recovery flush. Expected cause: 11 (the trailing ecall). A capped
     * walk (64 steps) records its cursor in g_val instead of running away. */
    for (int n = 1; n <= 6; n++) {
        for (int rep = 0; rep < 3; rep++) {
            volatile unsigned long *zl = (volatile unsigned long *) (FRAME(0) + 0x100);
            unsigned long end_va = VA_4K(0) + 0x100 + 16ul * (unsigned long) n;
            for (int i = 0; i < n; i++) {
                zl[2 * i] = VA_4K(0) + 0x800; /* zone VA */
                zl[2 * i + 1] = (unsigned long) i;
            }
            zl[2 * n] = 0;
            zl[2 * n + 1] = 0;
            g_val = 0;
            RUN_CASE(WIN_S "li   t0, 0x00400100\n"
                           "li   t3, 0x00400800\n"
                           "li   t4, 64\n"
                           "ld   t1, 0(t0)\n"
                           "beqz t1, 6f\n"
                           "5:\n"
                           "ld   t2, 16(t1)\n"
                           "ld   t2, 32(t1)\n"
                           "ld   t2, 136(t1)\n"
                           "addi t0, t0, 16\n"
                           "addi t4, t4, -1\n"
                           "beqz t4, 7f\n"
                           "ld   t1, 0(t0)\n"
                           "bnez t1, 5b\n"
                           "6:\n"
                           "ld   t2, 0(t3)\n"
                           "ld   t2, 8(t3)\n"
                           "ld   t2, 16(t3)\n"
                           "ld   t2, 24(t3)\n" WIN_END "j    8f\n"
                           "7:\n" WIN_END "la   t1, g_val\n"
                           "sd   t0, 0(t1)\n"
                           "8:\n");
            {
                int w_ok = (g_cause == 11ul) && (g_val == 0);
                if (!w_ok) {
                    uart_puts("[FAIL] W load n=");
                    uart_hex((unsigned long) n);
                    uart_puts(" rep=");
                    uart_hex((unsigned long) rep);
                    uart_puts(" cause=");
                    uart_hex(g_cause);
                    uart_puts(" mtval=");
                    uart_hex(g_tval);
                    uart_puts(" mepc=");
                    uart_hex(g_epc);
                    uart_puts(" runaway_cursor=");
                    uart_hex(g_val);
                    uart_puts("\r\n");
                }
                all_ok &= w_ok;
            }
            /* Store variant. The squashed iteration's accesses are a load
             * from 16(NULL), which occupies the translation stage with its
             * walk, then a store to 32(NULL), which issues in the recovery
             * cycle and was the phantom. The correct path's second
             * instruction after the branch is a store on that same tag: the
             * cursor to VA_4K(13)+0x108 (a load from +0x100 takes the first
             * tag), then t1 (0 at exit) to +0x110. The early store ports
             * would prefill the correct-path store's address from a DTLB hit
             * two cycles after dispatch, ahead of the squashed store's
             * refused walk, so the target page is one the loop never touches
             * and the DTLB is flushed first: the prefill drops, the issue
             * port translates the store behind the squashed one, and the
             * squashed store's fault reached the correct-path store on the
             * unfixed RTL (cause 15, mtval 0x20). */
            g_val = 0;
            *(volatile unsigned long *) (FRAME(13) + 0x100) = 0x0D0D0D0D0D0D0D0Dul;
            *(volatile unsigned long *) (FRAME(13) + 0x108) = 0;
            *(volatile unsigned long *) (FRAME(13) + 0x110) = 0x0E0E0E0E0E0E0E0Eul;
            RUN_CASE("sfence.vma\n" WIN_S "li   t0, 0x00400100\n"
                     "li   t3, 0x0040D100\n"
                     "li   t2, 0x5a5a\n"
                     "li   t4, 64\n"
                     "ld   t1, 0(t0)\n"
                     "beqz t1, 6f\n"
                     "5:\n"
                     "ld   zero, 16(t1)\n"
                     "sd   t2, 32(t1)\n"
                     "addi t0, t0, 16\n"
                     "addi t4, t4, -1\n"
                     "beqz t4, 7f\n"
                     "ld   t1, 0(t0)\n"
                     "bnez t1, 5b\n"
                     "6:\n"
                     "ld   t4, 0(t3)\n"
                     "sd   t0, 8(t3)\n"
                     "sd   t1, 16(t3)\n"
                     "ld   t2, 8(t3)\n" WIN_END "j    8f\n"
                     "7:\n" WIN_END "la   t1, g_val\n"
                     "sd   t0, 0(t1)\n"
                     "8:\n");
            {
                unsigned long s0v = *(volatile unsigned long *) (FRAME(13) + 0x108);
                unsigned long s1v = *(volatile unsigned long *) (FRAME(13) + 0x110);
                int w_ok = (g_cause == 11ul) && (g_val == 0) && (s0v == end_va) && (s1v == 0);
                if (!w_ok) {
                    uart_puts("[FAIL] W store n=");
                    uart_hex((unsigned long) n);
                    uart_puts(" rep=");
                    uart_hex((unsigned long) rep);
                    uart_puts(" cause=");
                    uart_hex(g_cause);
                    uart_puts(" mtval=");
                    uart_hex(g_tval);
                    uart_puts(" mepc=");
                    uart_hex(g_epc);
                    uart_puts(" mem=");
                    uart_hex(s0v);
                    uart_putc(' ');
                    uart_hex(s1v);
                    uart_puts(" want=");
                    uart_hex(end_va);
                    uart_puts("\r\n");
                }
                all_ok &= w_ok;
            }
        }
    }
    uart_puts(all_ok ? "[PASS] W wrong-path translated loads/stores\r\n"
                     : "[FAIL] W wrong-path translated loads/stores (see above)\r\n");

    /* Turn translation off before the exit path. */
    write_satp(0);

    uart_puts(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
