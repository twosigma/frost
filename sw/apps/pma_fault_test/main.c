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
 * PMA access-fault directed test (Phase 3 M2).
 *
 * Before M2, out-of-map physical addresses aliased onto the map because bits
 * [63:32] were masked at every producer. Now they raise precise access faults
 * with exact mepc/mtval. This test pins the whole matrix, self-checking over
 * UART (<<PASS>>/<<FAIL>>):
 *
 *   Physical map: BRAM [0, 256 KiB) fetch+data; device quadrant
 *   [0x4000_0000, 0x8000_0000) data-only; cached DDR [0x8000_0000,
 *   0xC000_0000) fetch+data. Everything else faults.
 *
 *   A. Load from a wild 64-bit address        -> cause 5, mtval exact.
 *   B. Load from the BRAM hole (0x0010_0000)  -> cause 5.
 *   C. Load from above cached DDR (0xC000_0000) -> cause 5.
 *   D. Load from [63:32]-aliased BRAM address -> cause 5 (the pre-M2
 *      aliasing case: 0x1_0000_1000 must fault, not read BRAM+0x1000).
 *   E. Store to a wild address                -> cause 7, mtval exact.
 *   F. AMO to the BRAM hole                   -> cause 7 (store/AMO access
 *      fault outranks the load-side classification for AMOs).
 *   G. LR from a wild address                 -> cause 5.
 *   H. Misaligned load in-map                 -> cause 4 still (baseline);
 *      misaligned and out-of-map              -> cause 5 (access fault
 *      outranks misalignment per the privileged spec).
 *   I. JALR to a wild 64-bit target           -> cause 1, mepc = mtval =
 *      the exact wild target (the jump itself must not fault; the fetch
 *      does).
 *   J. JALR into the BRAM hole                -> cause 1.
 *   K. JALR into the device quadrant          -> cause 1 (no fetch from
 *      MMIO).
 *   L. Device-quadrant data access still works (UART status read) and a
 *      DDR load/store round-trip still works: the in-map behavior is
 *      unchanged.
 *
 * The mechanism is umode_test's M-mode bounce. The mtvec handler records
 * mcause/mepc/mtval once per case, then returns to the continuation stashed
 * in mscratch. Every trigger sits behind a trapping instruction, so a
 * missing fault fails on the recorded sentinel values instead of hanging,
 * and a regression to aliasing shows up as the trailing ecall's cause 11.
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

#define LREG "ld"
#define SREG "sd"

/* M-mode bounce handler: record mcause/mepc/mtval once per case, return to
 * the mscratch continuation in M-mode. */
__attribute__((naked, aligned(4))) static void pma_trap_handler(void)
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

/* Run one trigger: reset the records, point the continuation past the
 * trigger, execute it. Each trigger is a naked body ending in ecall (the
 * no-fault fallback: cause 11 from M). */
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
                         : "t0", "t1", "t2", "memory");                                            \
    } while (0)

static int report3(const char *name,
                   unsigned long want_cause,
                   unsigned long want_epc,
                   unsigned long want_tval,
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

static volatile uint64_t g_ddr_word __attribute__((section(".data")));

int main(void)
{
    int all_ok = 1;

    uart_puts("\r\n=== PMA access-fault test ===\r\n");
    set_trap_handler(&pma_trap_handler);

    /* A: load from a wild 64-bit address. */
    unsigned long wild = 0x100003008ul; /* [63:32] != 0 */
    RUN_CASE("mv   t1, %0\n"
             "ld   t2, 0(t1)",
             "r"(wild));
    all_ok &= report3("A wild-load", 5u, 0, wild, 0);

    /* B: load from the BRAM hole. */
    unsigned long hole = 0x00100000ul;
    RUN_CASE("mv   t1, %0\n"
             "lw   t2, 0(t1)",
             "r"(hole));
    all_ok &= report3("B hole-load", 5u, 0, hole, 0);

    /* C: load from above cached DDR. */
    unsigned long above = 0xC0000000ul;
    RUN_CASE("mv   t1, %0\n"
             "lw   t2, 0(t1)",
             "r"(above));
    all_ok &= report3("C above-ddr-load", 5u, 0, above, 0);

    /* D: the pre-M2 aliasing shape: BRAM+0x1000 with bit 32 set must fault
     * with the exact 64-bit address in mtval, not read the alias. */
    unsigned long alias = 0x100001000ul;
    RUN_CASE("mv   t1, %0\n"
             "ld   t2, 0(t1)",
             "r"(alias));
    all_ok &= report3("D aliased-bram-load", 5u, 0, alias, 0);

    /* E: store to a wild address. */
    unsigned long wild_st = 0x700000010ul; /* [63:32]!=0 */
    RUN_CASE("mv   t1, %0\n"
             "sd   t1, 0(t1)",
             "r"(wild_st));
    all_ok &= report3("E wild-store", 7u, 0, wild_st, 0);

    /* F: AMO to the BRAM hole -> store/AMO access fault. */
    RUN_CASE("mv   t1, %0\n"
             "li   t2, 1\n"
             "amoadd.w t2, t2, (t1)",
             "r"(hole));
    all_ok &= report3("F hole-amo", 7u, 0, hole, 0);

    /* G: LR from a wild address -> load access fault. */
    RUN_CASE("mv   t1, %0\n"
             "lr.d t2, (t1)",
             "r"(wild));
    all_ok &= report3("G wild-lr", 5u, 0, wild, 0);

    /* H1: in-map misaligned load still raises cause 4 with the address. */
    unsigned long mis = (unsigned long) &g_ddr_word + 1u;
    RUN_CASE("mv   t1, %0\n"
             "lw   t2, 0(t1)",
             "r"(mis));
    all_ok &= report3("H1 in-map-misaligned", 4u, 0, mis, 0);

    /* H2: misaligned and out-of-map -> the access fault wins. */
    unsigned long mis_wild = wild + 1u;
    RUN_CASE("mv   t1, %0\n"
             "lw   t2, 0(t1)",
             "r"(mis_wild));
    all_ok &= report3("H2 wild-misaligned", 5u, 0, mis_wild, 0);

    /* I: JALR to a wild target: the fetch faults, and mepc and mtval are the
     * exact wild target. The link register gives the handler nothing to
     * return to. The bounce continuation recovers. */
    unsigned long wild_jump = 0x140000200ul;
    RUN_CASE("mv   t1, %0\n"
             "jalr x0, t1, 0",
             "r"(wild_jump));
    all_ok &= report3("I wild-jump", 1u, wild_jump, wild_jump, 1);

    /* J: JALR into the BRAM hole. */
    unsigned long hole_jump = 0x00200000ul;
    RUN_CASE("mv   t1, %0\n"
             "jalr x0, t1, 0",
             "r"(hole_jump));
    all_ok &= report3("J hole-jump", 1u, hole_jump, hole_jump, 1);

    /* K: JALR into the device quadrant: no fetch from MMIO. */
    unsigned long mmio_jump = 0x40000000ul;
    RUN_CASE("mv   t1, %0\n"
             "jalr x0, t1, 0",
             "r"(mmio_jump));
    all_ok &= report3("K mmio-jump", 1u, mmio_jump, mmio_jump, 1);

    /* L: in-map behavior unchanged. A device-quadrant data read and a DDR
     * round-trip complete without traps; the case ends on the ecall. */
    g_ddr_word = 0xA5A50FF012345678ull;
    RUN_CASE("li   t1, 0x40000028\n" /* UART TX status: data-valid read */
             "lw   t2, 0(t1)\n"
             "mv   t1, %0\n"
             "ld   t2, 0(t1)\n"
             "addi t2, t2, 1\n"
             "sd   t2, 0(t1)",
             "r"((unsigned long) &g_ddr_word));
    int l_ok = (g_cause == 11u) && (g_ddr_word == 0xA5A50FF012345679ull);
    uart_puts(l_ok ? "[PASS] " : "[FAIL] ");
    uart_puts("L in-map-unchanged cause=");
    uart_hex(g_cause);
    uart_puts(" ddr=");
    uart_hex(g_ddr_word);
    uart_puts("\r\n");
    all_ok &= l_ok;

    uart_puts(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
