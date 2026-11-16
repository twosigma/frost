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
 * Test stimecmp, menvcfg.STCE, and mcounteren.TM across M, S, and U modes:
 *   - Reset values of menvcfg, senvcfg, stimecmp, mcounteren, scounteren, and
 *     mip.STIP, and WARL masks of menvcfg (including PBMTE) and senvcfg.
 *   - M-mode read/write of stimecmp under every (STCE, mcounteren.TM) pair, and
 *     retention of stimecmp writes performed while STCE=0.
 *   - mip.STIP, mvip.STIP, and sip.STIP source and writability under STCE=0
 *     (software latch writable via mip/mvip, read-only via sip) and STCE=1
 *     (hardware compare mtime >= stimecmp drives STIP; mip/mvip writes ignored
 *     without altering the underlying software latch).
 *   - S-mode stimecmp read and write legality across all four (STCE, TM) pairs,
 *     independence from scounteren.TM, and U-mode illegality even with STCE=1
 *     and both TM bits set.
 *   - Delegated S-mode timer interrupt delivery through stimecmp.
 *
 * Use numeric CSR addresses (stimecmp=0x14D, menvcfg=0x30A, senvcfg=0x10A,
 * mvip=0x309) so the test does not need Sstc/Smaia-aware binutils.
 */

#include <stdint.h>

#include "trap.h"

/* ---- UART ---- */
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

#define MIP_STIP (1ul << 5)
#define MENVCFG_STCE (1ul << 63)
#define MENVCFG_PBMTE (1ul << 62)
#define ENVCFG_CBZE (1ul << 7)
#define ENVCFG_CBCFE (1ul << 6)
#define ENVCFG_CBIE (3ul << 4)
#define ENVCFG_FIOM (1ul << 0)
#define SENVCFG_PMM (3ul << 32) /* Ssnpm: 11 (PMLEN 16) is a legal value */
#define COUNTEREN_ALL 0x7FFul
#define COUNTEREN_TM (1ul << 1)

/* Exact 32-bit encodings used in the S/U bodies so Sstvala checks mtval. */
#define INSN_CSRR_T0_STIMECMP 0x14d022f3ul    /* csrrs  t0, 0x14D, x0   */
#define INSN_CSRW_STIMECMP_T0 0x14d29073ul    /* csrrw  x0, 0x14D, t0   */
#define INSN_CSRRSI0_T0_STIMECMP 0x14d062f3ul /* csrrsi t0, 0x14D, 0    */
#define INSN_CSRRCI0_T0_STIMECMP 0x14d072f3ul /* csrrci t0, 0x14D, 0    */
#define INSN_CSRRWI_T0_STIMECMP 0x14dad2f3ul  /* csrrwi t0, 0x14D, 0x15 */
#define INSN_CSRRSI_T0_STIMECMP 0x14d562f3ul  /* csrrsi t0, 0x14D, 0x0A */
#define INSN_CSRRCI_T0_STIMECMP 0x14d2f2f3ul  /* csrrci t0, 0x14D, 0x05 */

#define csr_read_num(num)                                                                          \
    ({                                                                                             \
        unsigned long v_;                                                                          \
        __asm__ volatile("csrr %0, " #num : "=r"(v_));                                             \
        v_;                                                                                        \
    })
#define csr_write_num(num, val)                                                                    \
    do {                                                                                           \
        unsigned long v_ = (val);                                                                  \
        __asm__ volatile("csrw " #num ", %0" : : "r"(v_));                                         \
    } while (0)

static int report(const char *name, unsigned long got, unsigned long want)
{
    uart_puts(got == want ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" got=");
    uart_hex(got);
    uart_puts(" want=");
    uart_hex(want);
    uart_puts("\r\n");
    return got == want;
}

static int check_quiet(const char *name, unsigned long got, unsigned long want)
{
    if (got != want)
        return report(name, got, want);
    return 1;
}

static unsigned long poll_mip(unsigned long mask, unsigned long want)
{
    for (int i = 0; i < 4000; i++) {
        if ((csr_read(mip) & mask) == want)
            return want;
    }
    return csr_read(mip) & mask;
}

/* ---- trap state shared with the naked handlers (smode_test shape) ---- */
static volatile unsigned long g_cause;   /* M handler: mcause */
static volatile unsigned long g_tval;    /* M handler: mtval */
static volatile unsigned long g_s_cause; /* S handler: scause */
static volatile unsigned long g_s_read;  /* Value read from stimecmp in S-mode */

/*
 * Naked M-mode trap handler: records mcause and mtval once per case (g_cause is
 * seeded with ~0). Only silences stimecmp when taking an interrupt (mcause < 0)
 * so synchronous illegal-instruction checks can verify stimecmp is untouched.
 */
__attribute__((naked, aligned(4))) static void m_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t2, mtval\n"
                     "la   t1, g_tval\n"
                     "sd   t2, 0(t1)\n"
                     "2:\n"
                     "bgez t0, 3f\n"
                     "li   t0, -1\n" /* interrupt: silence stimecmp */
                     "csrw 0x14D, t0\n"
                     "3:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n" /* MPP = M */
                     "csrs mstatus, t0\n"
                     "mret\n");
}

/*
 * Naked S-mode trap handler: records scause once per case, silences the timer
 * by writing stimecmp = max, and ecalls out to M (cause 9 ends the case).
 */
__attribute__((naked, aligned(4))) static void s_trap_handler(void)
{
    __asm__ volatile("csrr t0, scause\n"
                     "la   t1, g_s_cause\n"
                     "ld   t2, 0(t1)\n"
                     "li   t3, -1\n"
                     "bne  t2, t3, 2f\n"
                     "sd   t0, 0(t1)\n"
                     "2:\n"
                     "li   t0, -1\n"
                     "csrw 0x14D, t0\n"
                     "ecall\n"
                     "j    .\n");
}

/* Enter S (mpp=0x0800) or U (mpp=0x0000) at fn via MRET; the M handler returns
 * control to label 1:. Returns the mcause that ended the case. */
static unsigned long run_at_mpp(void (*fn)(void), unsigned long mpp_bits)
{
    g_cause = ~0ul;
    g_tval = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "csrs mstatus, %1\n"
                     "csrw mepc, %0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(fn), "r"(mpp_bits)
                     : "t0", "t1", "t2", "t3", "memory");
    return g_cause;
}

static unsigned long run_in_s(void (*fn)(void))
{
    return run_at_mpp(fn, 0x0800ul);
}

static unsigned long run_in_u(void (*fn)(void))
{
    return run_at_mpp(fn, 0x0000ul);
}

/* ---- S/U bodies ---- */
__attribute__((naked)) static void su_read_stimecmp(void)
{
    __asm__ volatile(".4byte 0x14d022f3\n" /* csrr t0, 0x14D */
                     "la   t1, g_s_read\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void su_write_stimecmp(void)
{
    __asm__ volatile("li   t0, 0x6000111122223333\n"
                     ".4byte 0x14d29073\n" /* csrw 0x14D, t0 */
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void su_csrrsi0_stimecmp(void)
{
    __asm__ volatile(".4byte 0x14d062f3\n" /* csrrsi t0, 0x14D, 0 */
                     "la   t1, g_s_read\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void su_csrrci0_stimecmp(void)
{
    __asm__ volatile(".4byte 0x14d072f3\n" /* csrrci t0, 0x14D, 0 */
                     "la   t1, g_s_read\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void su_csrrwi_stimecmp(void)
{
    __asm__ volatile(".4byte 0x14dad2f3\n" /* csrrwi t0, 0x14D, 0x15 */
                     "la   t1, g_s_read\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void su_csrrsi_stimecmp(void)
{
    __asm__ volatile(".4byte 0x14d562f3\n" /* csrrsi t0, 0x14D, 0x0A */
                     "la   t1, g_s_read\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void su_csrrci_stimecmp(void)
{
    __asm__ volatile(".4byte 0x14d2f2f3\n" /* csrrci t0, 0x14D, 0x05 */
                     "la   t1, g_s_read\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void s_set_sip_stip(void)
{
    __asm__ volatile("li   t0, 0x20\n"
                     "csrs sip, t0\n"
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void s_clear_sip_stip(void)
{
    __asm__ volatile("li   t0, 0x20\n"
                     "csrc sip, t0\n"
                     "csrr t0, sip\n"
                     "la   t1, g_s_read\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void s_read_sip(void)
{
    __asm__ volatile("csrr t0, sip\n"
                     "la   t1, g_s_read\n"
                     "sd   t0, 0(t1)\n"
                     "ecall\n"
                     "j    .\n");
}

__attribute__((naked)) static void s_spin(void)
{
    __asm__ volatile("1: wfi\n j 1b");
}

int main(void)
{
    int ok = 1;
    unsigned long cause;

    uart_puts("\r\n=== Sstc test ===\r\n");
    set_trap_handler(&m_trap_handler);

    /* A: Reset values and WARL masks. menvcfg and senvcfg reset to 0.
     * menvcfg implements FIOM, CBIE, CBCFE, CBZE, PBMTE and STCE;
     * senvcfg implements FIOM, CBIE, CBCFE, CBZE and PMM. */
    ok &= report("A menvcfg-reset", csr_read_num(0x30A), 0);
    ok &= report("A senvcfg-reset", csr_read_num(0x10A), 0);
    ok &= report("A stimecmp-reset", csr_read_num(0x14D), ~0ul);
    ok &= report("A mcounteren-reset", csr_read(mcounteren), COUNTEREN_ALL);
    ok &= report("A scounteren-reset", csr_read_num(0x106), COUNTEREN_ALL);
    ok &= report("A mip-stip-reset", csr_read(mip) & MIP_STIP, 0);

    csr_write_num(0x30A, ~0ul);
    ok &= report("A menvcfg-warl",
                 csr_read_num(0x30A),
                 MENVCFG_STCE | MENVCFG_PBMTE | ENVCFG_CBZE | ENVCFG_CBCFE | ENVCFG_CBIE |
                     ENVCFG_FIOM);
    csr_write_num(0x30A, 0);
    ok &= report("A menvcfg-clear", csr_read_num(0x30A), 0);
    csr_write_num(0x10A, ~0ul);
    ok &= report("A senvcfg-warl",
                 csr_read_num(0x10A),
                 SENVCFG_PMM | ENVCFG_CBZE | ENVCFG_CBCFE | ENVCFG_CBIE | ENVCFG_FIOM);
    csr_write_num(0x10A, 0);
    ok &= report("A senvcfg-clear", csr_read_num(0x10A), 0);

    /* B: stimecmp is M-accessible under every (STCE, mcounteren.TM) pair. */
    csr_write_num(0x30A, 0);
    csr_write(mcounteren, COUNTEREN_ALL);
    csr_write_num(0x14D, 0x4111222233334444ul);
    ok &= report("B m-stce0-tm1", csr_read_num(0x14D), 0x4111222233334444ul);

    csr_write(mcounteren, COUNTEREN_ALL & ~COUNTEREN_TM);
    csr_write_num(0x14D, 0x4222333344445555ul);
    ok &= report("B m-stce0-tm0", csr_read_num(0x14D), 0x4222333344445555ul);

    csr_write_num(0x30A, MENVCFG_STCE);
    csr_write(mcounteren, COUNTEREN_ALL);
    csr_write_num(0x14D, 0x4333444455556666ul);
    ok &= report("B m-stce1-tm1", csr_read_num(0x14D), 0x4333444455556666ul);

    csr_write(mcounteren, COUNTEREN_ALL & ~COUNTEREN_TM);
    csr_write_num(0x14D, 0x4444555566667777ul);
    ok &= report("B m-stce1-tm0", csr_read_num(0x14D), 0x4444555566667777ul);

    csr_write_num(0x30A, 0);
    csr_write(mcounteren, COUNTEREN_ALL);
    csr_write_num(0x14D, ~0ul);

    /* C: STCE=0: software controls mip.STIP (and mvip.STIP); sip.STIP is
     * read-only in S-mode; writing stimecmp below mtime while STCE=0 retains
     * the value without raising STIP until STCE is set to 1. */
    csr_set(mip, MIP_STIP);
    ok &= report("C sw-stip-set", csr_read(mip) & MIP_STIP, MIP_STIP);
    ok &= report("C mvip-reflects", csr_read_num(0x309) & MIP_STIP, MIP_STIP);
    csr_clear(mip, MIP_STIP);
    ok &= report("C sw-stip-clear", csr_read(mip) & MIP_STIP, 0);

    csr_write_num(0x309, MIP_STIP);
    ok &= report("C mvip-sets-stip", csr_read(mip) & MIP_STIP, MIP_STIP);
    csr_write_num(0x309, 0);
    ok &= report("C mvip-clears-stip", csr_read(mip) & MIP_STIP, 0);

    csr_write(medeleg, 0);
    csr_write(mideleg, MIP_STIP);
    cause = run_in_s(&s_set_sip_stip);
    ok &= report("C sip-stip-ro-ecall", cause, 9);
    ok &= report("C sip-stip-ro-val", csr_read(mip) & MIP_STIP, 0);
    csr_write(mideleg, 0);

    unsigned long past_cmp = rdmtime() + 100;
    csr_write_num(0x14D, past_cmp);
    while (rdmtime() <= past_cmp + 100) {
    }
    ok &= report("C stce0-cmp-silent", csr_read(mip) & MIP_STIP, 0);
    ok &= report("C stce0-cmp-retained", csr_read_num(0x14D), past_cmp);
    csr_write_num(0x30A, MENVCFG_STCE);
    ok &= report("C stce1-activates-cmp", poll_mip(MIP_STIP, MIP_STIP), MIP_STIP);
    csr_write_num(0x14D, ~0ul);
    ok &= report("C stce1-clears-cmp", poll_mip(MIP_STIP, 0), 0);
    csr_write_num(0x30A, 0);

    /* D: S-mode and U-mode stimecmp legality across (STCE, mcounteren.TM). */
    const unsigned long sentinel = 0x55AA55AA55AA55AAul;
    csr_write_num(0x14D, sentinel);

    /* D1: S-mode with STCE=0, TM=1 -> read and write trap illegal. */
    csr_write_num(0x30A, 0);
    csr_write(mcounteren, COUNTEREN_ALL);
    csr_write_num(0x106, COUNTEREN_ALL);
    cause = run_in_s(&su_read_stimecmp);
    ok &= report("D1 s-stce0-tm1-rd-cause", cause, 2);
    ok &= report("D1 s-stce0-tm1-rd-tval", g_tval, INSN_CSRR_T0_STIMECMP);
    cause = run_in_s(&su_write_stimecmp);
    ok &= report("D1 s-stce0-tm1-wr-cause", cause, 2);
    ok &= report("D1 s-stce0-tm1-wr-tval", g_tval, INSN_CSRW_STIMECMP_T0);
    ok &= report("D1 s-stce0-tm1-unchanged", csr_read_num(0x14D), sentinel);

    /* D2: S-mode with STCE=1, TM=0 -> read and write trap illegal! */
    csr_write_num(0x30A, MENVCFG_STCE);
    csr_write(mcounteren, COUNTEREN_ALL & ~COUNTEREN_TM);
    cause = run_in_s(&su_read_stimecmp);
    ok &= report("D2 s-stce1-tm0-rd-cause", cause, 2);
    ok &= report("D2 s-stce1-tm0-rd-tval", g_tval, INSN_CSRR_T0_STIMECMP);
    cause = run_in_s(&su_write_stimecmp);
    ok &= report("D2 s-stce1-tm0-wr-cause", cause, 2);
    ok &= report("D2 s-stce1-tm0-wr-tval", g_tval, INSN_CSRW_STIMECMP_T0);
    ok &= report("D2 s-stce1-tm0-unchanged", csr_read_num(0x14D), sentinel);

    /* D3: S-mode with STCE=0, TM=0 -> read and write trap illegal. */
    csr_write_num(0x30A, 0);
    csr_write(mcounteren, COUNTEREN_ALL & ~COUNTEREN_TM);
    cause = run_in_s(&su_read_stimecmp);
    ok &= report("D3 s-stce0-tm0-rd-cause", cause, 2);
    cause = run_in_s(&su_write_stimecmp);
    ok &= report("D3 s-stce0-tm0-wr-cause", cause, 2);
    ok &= report("D3 s-stce0-tm0-unchanged", csr_read_num(0x14D), sentinel);

    /* D4: S-mode with STCE=1, TM=1, scounteren=0 -> read and write succeed. */
    csr_write_num(0x30A, MENVCFG_STCE);
    csr_write(mcounteren, COUNTEREN_ALL);
    csr_write_num(0x106, 0);
    g_s_read = 0;
    cause = run_in_s(&su_write_stimecmp);
    ok &= report("D4 s-stce1-tm1-wr-legal", cause, 9);
    ok &= report("D4 s-stce1-tm1-wr-val", csr_read_num(0x14D), 0x6000111122223333ul);
    cause = run_in_s(&su_read_stimecmp);
    ok &= report("D4 s-stce1-tm1-rd-legal", cause, 9);
    ok &= report("D4 s-stce1-tm1-rd-val", g_s_read, 0x6000111122223333ul);

    /* D5: U-mode with STCE=1, mcounteren=all, scounteren=all -> illegal. */
    csr_write_num(0x14D, sentinel);
    csr_write_num(0x106, COUNTEREN_ALL);
    cause = run_in_u(&su_read_stimecmp);
    ok &= report("D5 u-rd-illegal", cause, 2);
    ok &= report("D5 u-rd-tval", g_tval, INSN_CSRR_T0_STIMECMP);
    cause = run_in_u(&su_write_stimecmp);
    ok &= report("D5 u-wr-illegal", cause, 2);
    ok &= report("D5 u-wr-tval", g_tval, INSN_CSRW_STIMECMP_T0);
    ok &= report("D5 u-unchanged", csr_read_num(0x14D), sentinel);

    /* D6: Immediate CSR forms (csrrwi, csrrsi uimm=0/!=0, csrrci uimm=0/!=0)
     * obey the exact same legality rule across M, S, and U. */
    {
        int imm_ok = 1;
        unsigned long old_v = 0;

        /* M-mode with STCE=0, TM=0: all immediate forms succeed. */
        csr_write_num(0x30A, 0);
        csr_write(mcounteren, 0);
        csr_write_num(0x14D, sentinel);
        __asm__ volatile("mv t0, zero\n .4byte 0x14dad2f3\n mv %0, t0" : "=r"(old_v) : : "t0");
        imm_ok &= check_quiet("D6 m-csrrwi-old", old_v, sentinel);
        imm_ok &= check_quiet("D6 m-csrrwi-new", csr_read_num(0x14D), 0x15ul);
        __asm__ volatile("mv t0, zero\n .4byte 0x14d562f3\n mv %0, t0" : "=r"(old_v) : : "t0");
        imm_ok &= check_quiet("D6 m-csrrsi-old", old_v, 0x15ul);
        imm_ok &= check_quiet("D6 m-csrrsi-new", csr_read_num(0x14D), 0x1Ful);
        __asm__ volatile("mv t0, zero\n .4byte 0x14d2f2f3\n mv %0, t0" : "=r"(old_v) : : "t0");
        imm_ok &= check_quiet("D6 m-csrrci-old", old_v, 0x1Ful);
        imm_ok &= check_quiet("D6 m-csrrci-new", csr_read_num(0x14D), 0x1Aul);
        __asm__ volatile("mv t0, zero\n .4byte 0x14d062f3\n mv %0, t0" : "=r"(old_v) : : "t0");
        imm_ok &= check_quiet("D6 m-csrrsi0", old_v, 0x1Aul);
        __asm__ volatile("mv t0, zero\n .4byte 0x14d072f3\n mv %0, t0" : "=r"(old_v) : : "t0");
        imm_ok &= check_quiet("D6 m-csrrci0", old_v, 0x1Aul);

        static void (*const imm_fns[5])(void) = {
            &su_csrrsi0_stimecmp,
            &su_csrrci0_stimecmp,
            &su_csrrwi_stimecmp,
            &su_csrrsi_stimecmp,
            &su_csrrci_stimecmp,
        };
        static const unsigned long imm_words[5] = {
            INSN_CSRRSI0_T0_STIMECMP,
            INSN_CSRRCI0_T0_STIMECMP,
            INSN_CSRRWI_T0_STIMECMP,
            INSN_CSRRSI_T0_STIMECMP,
            INSN_CSRRCI_T0_STIMECMP,
        };

        /* S-mode illegal pairs: (STCE=0,TM=1), (STCE=1,TM=0), (STCE=0,TM=0). */
        static const unsigned long s_bad_menvcfg[3] = {0, MENVCFG_STCE, 0};
        static const unsigned long s_bad_mcounteren[3] = {
            COUNTEREN_ALL, COUNTEREN_ALL & ~COUNTEREN_TM, COUNTEREN_ALL & ~COUNTEREN_TM};
        csr_write_num(0x14D, sentinel);
        csr_write_num(0x106, COUNTEREN_ALL);
        for (int p = 0; p < 3; p++) {
            csr_write_num(0x30A, s_bad_menvcfg[p]);
            csr_write(mcounteren, s_bad_mcounteren[p]);
            for (int k = 0; k < 5; k++) {
                cause = run_in_s(imm_fns[k]);
                imm_ok &= check_quiet("D6 s-imm-bad-cause", cause, 2);
                imm_ok &= check_quiet("D6 s-imm-bad-tval", g_tval, imm_words[k]);
                imm_ok &= check_quiet("D6 s-imm-bad-unchanged", csr_read_num(0x14D), sentinel);
            }
        }

        /* S-mode legal pair: STCE=1, TM=1, scounteren=0 (sie=0 so small compare
         * values do not take an interrupt). */
        csr_write(sie, 0);
        csr_write_num(0x30A, MENVCFG_STCE);
        csr_write(mcounteren, COUNTEREN_ALL);
        csr_write_num(0x106, 0);
        csr_write_num(0x14D, sentinel);
        cause = run_in_s(&su_csrrwi_stimecmp);
        imm_ok &= check_quiet("D6 s-csrrwi-cause", cause, 9);
        imm_ok &= check_quiet("D6 s-csrrwi-old", g_s_read, sentinel);
        imm_ok &= check_quiet("D6 s-csrrwi-new", csr_read_num(0x14D), 0x15ul);
        cause = run_in_s(&su_csrrsi_stimecmp);
        imm_ok &= check_quiet("D6 s-csrrsi-cause", cause, 9);
        imm_ok &= check_quiet("D6 s-csrrsi-old", g_s_read, 0x15ul);
        imm_ok &= check_quiet("D6 s-csrrsi-new", csr_read_num(0x14D), 0x1Ful);
        cause = run_in_s(&su_csrrci_stimecmp);
        imm_ok &= check_quiet("D6 s-csrrci-cause", cause, 9);
        imm_ok &= check_quiet("D6 s-csrrci-old", g_s_read, 0x1Ful);
        imm_ok &= check_quiet("D6 s-csrrci-new", csr_read_num(0x14D), 0x1Aul);
        cause = run_in_s(&su_csrrsi0_stimecmp);
        imm_ok &= check_quiet("D6 s-csrrsi0-cause", cause, 9);
        imm_ok &= check_quiet("D6 s-csrrsi0-val", g_s_read, 0x1Aul);
        cause = run_in_s(&su_csrrci0_stimecmp);
        imm_ok &= check_quiet("D6 s-csrrci0-cause", cause, 9);
        imm_ok &= check_quiet("D6 s-csrrci0-val", g_s_read, 0x1Aul);

        /* U-mode with STCE=1, mcounteren=all, scounteren=all: all trap illegal. */
        csr_write_num(0x14D, sentinel);
        csr_write_num(0x106, COUNTEREN_ALL);
        for (int k = 0; k < 5; k++) {
            cause = run_in_u(imm_fns[k]);
            imm_ok &= check_quiet("D6 u-imm-cause", cause, 2);
            imm_ok &= check_quiet("D6 u-imm-tval", g_tval, imm_words[k]);
            imm_ok &= check_quiet("D6 u-imm-unchanged", csr_read_num(0x14D), sentinel);
        }

        ok &= report("D6 imm-forms-all", (unsigned long) imm_ok, 1ul);
    }
    csr_write_num(0x14D, ~0ul);

    /* E: STCE=1 makes mip.STIP and mvip.STIP read-only in M-mode without
     * overwriting the underlying software STIP latch. */
    csr_write_num(0x30A, 0);
    csr_clear(mip, MIP_STIP);
    csr_write_num(0x30A, MENVCFG_STCE);
    csr_write_num(0x14D, rdmtime() + 200);
    ok &= report("E stip-fires", poll_mip(MIP_STIP, MIP_STIP), MIP_STIP);
    csr_set(mip, MIP_STIP);
    csr_write_num(0x309, MIP_STIP);
    csr_write_num(0x14D, ~0ul);
    ok &= report("E stip-clears", poll_mip(MIP_STIP, 0), 0);
    csr_write_num(0x30A, 0);
    ok &= report("E sw-latch-stays-0", csr_read(mip) & MIP_STIP, 0);

    /* Now seed the software STIP latch to 1 under STCE=0, verify STCE=1 hides
     * it and ignores clear attempts via mip and mvip, and verify STCE=0
     * exposes the preserved 1 again. */
    csr_set(mip, MIP_STIP);
    ok &= report("E2 sw-latch-seeded-1", csr_read(mip) & MIP_STIP, MIP_STIP);
    csr_write_num(0x30A, MENVCFG_STCE);
    ok &= report("E2 stce1-reads-cmp-0", csr_read(mip) & MIP_STIP, 0);
    ok &= report("E2 stce1-mvip-0", csr_read_num(0x309) & MIP_STIP, 0);
    csr_clear(mip, MIP_STIP);
    csr_write_num(0x309, 0);
    csr_write_num(0x30A, 0);
    ok &= report("E2 sw-latch-preserved-1", csr_read(mip) & MIP_STIP, MIP_STIP);
    csr_clear(mip, MIP_STIP);
    ok &= report("E2 sw-latch-cleared", csr_read(mip) & MIP_STIP, 0);

    /* F: S-mode sip read of compare-driven STIP with menvcfg.STCE = 1 (SIE = 0
     * and sie = 0 so S-mode reads sip directly without taking an interrupt). */
    csr_clear(mstatus, 1ul << 1);
    csr_write(sie, 0);
    csr_write_num(0x30A, MENVCFG_STCE);
    csr_write(mcounteren, COUNTEREN_ALL);
    csr_write(mideleg, MIP_STIP);
    csr_write_num(0x14D, 0ul);
    ok &= report("F cmp-active-mip", poll_mip(MIP_STIP, MIP_STIP), MIP_STIP);
    g_s_read = 0;
    cause = run_in_s(&s_read_sip);
    ok &= report("F s-sip-deleg-stip-1-ecall", cause, 9);
    ok &= report("F s-sip-deleg-stip-1", g_s_read & MIP_STIP, MIP_STIP);
    g_s_read = 0;
    cause = run_in_s(&s_clear_sip_stip);
    ok &= report("F s-sip-ro-clear-ignored", g_s_read & MIP_STIP, MIP_STIP);

    csr_write_num(0x14D, ~0ul);
    ok &= report("F cmp-cleared-mip", poll_mip(MIP_STIP, 0), 0);
    g_s_read = ~0ul;
    cause = run_in_s(&s_read_sip);
    ok &= report("F s-sip-deleg-stip-0", g_s_read & MIP_STIP, 0);

    csr_write(mideleg, 0);
    csr_write_num(0x14D, 0ul);
    ok &= report("F cmp-undeleg-mip-1", poll_mip(MIP_STIP, MIP_STIP), MIP_STIP);
    g_s_read = ~0ul;
    cause = run_in_s(&s_read_sip);
    ok &= report("F s-sip-undeleg-masked", g_s_read & MIP_STIP, 0);
    csr_write_num(0x14D, ~0ul);
    csr_write_num(0x30A, 0);

    /* G: delegated S timer interrupt through stimecmp: the S handler sees
     * scause = S-timer, silences stimecmp, and ecalls out (cause 9). */
    g_s_cause = ~0ul;
    csr_write_num(0x30A, MENVCFG_STCE);
    csr_write(mideleg, MIP_STIP);
    csr_write(stvec, (unsigned long) &s_trap_handler);
    csr_write(sie, MIP_STIP);
    /* Set SIE directly: MRET does not restore it from SPIE. SIE gates
     * S-level interrupts in S-mode and has no effect while in M-mode. */
    csr_set(mstatus, 1ul << 1);
    csr_write_num(0x14D, rdmtime() + 300);
    cause = run_in_s(&s_spin);
    ok &= report("G s-take-ends", cause, 9);
    ok &= report("G scause", g_s_cause, 0x8000000000000000ul | 5ul);
    csr_write(mideleg, 0);
    csr_write(sie, 0);
    csr_write_num(0x30A, 0);

    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
