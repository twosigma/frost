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
 * PMA access-fault directed test. Out-of-map physical addresses, including
 * any with bits [63:32] set, must raise precise access faults with exact
 * mepc/mtval instead of aliasing onto the map. Self-checks over UART
 * (<<PASS>>/<<FAIL>>):
 *
 *   Physical map: BRAM [0, 256 KiB) and cached DDR [0x8000_0000,
 *   0xC000_0000) take fetch, loads, stores and atomics. The device windows,
 *   the MMIO registers [0x4000_0000, 0x4003_1000) and the PLIC
 *   [0x4400_0000, 0x4440_0000), take loads and stores only. Everything
 *   else faults, including the rest of the device quadrant [0x4000_0000,
 *   0x8000_0000).
 *
 *   A. Load from a wild 64-bit address        -> cause 5, mtval exact.
 *   B. Load from the BRAM hole (0x0010_0000)  -> cause 5.
 *   C. Load from above cached DDR (0xC000_0000) -> cause 5.
 *   D. Load from [63:32]-aliased BRAM address -> cause 5 (0x1_0000_1000
 *      must fault, not read BRAM+0x1000).
 *   E. Store to a wild address                -> cause 7, mtval exact.
 *   F. AMO to the BRAM hole                   -> cause 7 (an AMO reports
 *      the store/AMO access fault).
 *   G. LR from a wild address                 -> cause 5.
 *   H. Misaligned load in-map                 -> cause 4;
 *      misaligned and out-of-map              -> cause 5 (the access fault
 *      takes priority over misalignment).
 *   I. JALR to a wild 64-bit target           -> cause 1, mepc = mtval =
 *      the exact wild target (the jump itself must not fault; the fetch
 *      does).
 *   J. JALR into the BRAM hole                -> cause 1.
 *   K. JALR into the device quadrant          -> cause 1 (no fetch from
 *      MMIO).
 *   L. In-map accesses do not trap: device reads (UART status, a PLIC
 *      priority, the last dwords of the MMIO and PLIC windows) and a
 *      load/store round trip on a cached-DDR word.
 *   M. Atomics to a device register fault before any device access: AMO
 *      -> cause 7, LR -> cause 5, SC -> cause 7 (also while a reservation
 *      on RAM is held), mtval exact, and the ns16550 scratch register keeps
 *      its value. An AMO to an unserved device address that aliases a
 *      low-BRAM word -> cause 7, and the word is unchanged.
 *   N. Plain accesses to unserved device addresses fault: lw/ld -> cause 5
 *      and sw/sd -> cause 7 at the address that aliases the low-BRAM word
 *      (unchanged), a store whose immediate carries it past the end of the
 *      MMIO window -> cause 7, and loads just past the MMIO window, on both
 *      sides of the PLIC, and at the top of the quadrant -> cause 5.
 *
 * Each case uses the M-mode bounce from umode_test: the mtvec handler records
 * mcause/mepc/mtval for the first trap of the case, then returns to the
 * continuation stashed in mscratch. Every trigger is followed by an ecall, so
 * a data access that does not fault records cause 11. The JALR triggers jump
 * away from it, so they have no such fallback.
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
 * trigger, execute it. The ecall after the trigger is the no-fault fallback
 * (cause 11 from M). The clobbers include every register the handler
 * writes. */
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
                         : "t0", "t1", "t2", "t3", "memory");                                      \
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

static int check_value(const char *name, unsigned long got, unsigned long want)
{
    int ok = (got == want);
    uart_puts(ok ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" got=");
    uart_hex(got);
    uart_puts(" want=");
    uart_hex(want);
    uart_puts("\r\n");
    return ok;
}

/* In .ddr_data, so case L reaches the cached tier in both memory tiers. */
static volatile uint64_t g_ddr_word __attribute__((section(".ddr_data")));

/* The ns16550 scratch register: a read/write device register with no side
 * effects. */
#define NS16550_SCR 0x4000101Cul

/* Unserved device-quadrant addresses the N loads probe: just past the MMIO
 * window, on both sides of the PLIC, and the top of the quadrant. */
static const unsigned long k_unserved_loads[] = {
    0x40031000ul,
    0x43FFFFFCul,
    0x44400000ul,
    0x7FFFFFFCul,
};

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

    /* D: BRAM+0x1000 with bit 32 set must fault with the exact 64-bit
     * address in mtval, not read the alias. */
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

    /* H1: an in-map misaligned load raises cause 4 with the address. */
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
     * exact wild target. */
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

    /* L: device reads and a load/store round trip on g_ddr_word complete
     * without traps; the case ends on the ecall. */
    g_ddr_word = 0xA5A50FF012345678ull;
    RUN_CASE("li   t1, 0x40000028\n" /* UART TX status */
             "lw   t2, 0(t1)\n"
             "li   t1, 0x40030FF8\n" /* last dword of the MMIO window (NIC) */
             "ld   t2, 0(t1)\n"
             "li   t1, 0x44000004\n" /* PLIC source 1 priority */
             "lw   t2, 0(t1)\n"
             "li   t1, 0x443FFFF8\n" /* last dword of the PLIC window */
             "ld   t2, 0(t1)\n"
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

    /* M1-M4: the device windows support no AMOs and no LR/SC, so each
     * faults before the device sees a read or a write. */
    volatile uint32_t *scr = (volatile uint32_t *) NS16550_SCR;
    *scr = 0x5Au;
    RUN_CASE("mv   t1, %0\n"
             "li   t2, 0xA5\n"
             "amoswap.w t2, t2, (t1)",
             "r"(NS16550_SCR));
    all_ok &= report3("M1 device-amo", 7u, 0, NS16550_SCR, 0);
    all_ok &= check_value("M1 scr-unchanged", *scr, 0x5Au);

    RUN_CASE("mv   t1, %0\n"
             "lr.w t2, (t1)",
             "r"(NS16550_SCR));
    all_ok &= report3("M2 device-lr", 5u, 0, NS16550_SCR, 0);

    *scr = 0x5Au;
    RUN_CASE("mv   t1, %0\n"
             "li   t2, 0x33\n"
             "sc.w t2, t2, (t1)",
             "r"(NS16550_SCR));
    all_ok &= report3("M3 device-sc", 7u, 0, NS16550_SCR, 0);
    all_ok &= check_value("M3 scr-unchanged", *scr, 0x5Au);

    /* M4: the lr.w on g_ddr_word holds a reservation; the SC still faults. */
    *scr = 0x5Au;
    RUN_CASE("mv   t0, %1\n"
             "lr.w t2, (t0)\n"
             "mv   t1, %0\n"
             "li   t2, 0x33\n"
             "sc.w t2, t2, (t1)",
             "r"(NS16550_SCR),
             "r"((unsigned long) &g_ddr_word));
    all_ok &= report3("M4 device-sc-reserved", 7u, 0, NS16550_SCR, 0);
    all_ok &= check_value("M4 scr-unchanged", *scr, 0x5Au);

    /* M5: an AMO to an unserved device address. The low BRAM decodes only
     * the address bits below its size, so without the fault the address
     * would reach bram_word, which is on the stack (low BRAM in both memory
     * tiers). */
    volatile uint64_t bram_word = 0x0123456789ABCDEFull;
    unsigned long unserved = 0x40100000ul + ((unsigned long) &bram_word & 0x3FFFFul);
    RUN_CASE("mv   t1, %0\n"
             "li   t2, 1\n"
             "amoadd.w t2, t2, (t1)",
             "r"(unserved));
    all_ok &= report3("M5 unserved-amo", 7u, 0, unserved, 0);
    all_ok &= check_value("M5 bram-unchanged", bram_word, 0x0123456789ABCDEFull);

    /* N1-N4: plain loads and stores to the same unserved address. */
    RUN_CASE("mv   t1, %0\n"
             "lw   t2, 0(t1)",
             "r"(unserved));
    all_ok &= report3("N1 unserved-lw", 5u, 0, unserved, 0);
    RUN_CASE("mv   t1, %0\n"
             "ld   t2, 0(t1)",
             "r"(unserved));
    all_ok &= report3("N2 unserved-ld", 5u, 0, unserved, 0);
    RUN_CASE("mv   t1, %0\n"
             "li   t2, -1\n"
             "sw   t2, 0(t1)",
             "r"(unserved));
    all_ok &= report3("N3 unserved-sw", 7u, 0, unserved, 0);
    RUN_CASE("mv   t1, %0\n"
             "li   t2, -1\n"
             "sd   t2, 0(t1)",
             "r"(unserved));
    all_ok &= report3("N4 unserved-sd", 7u, 0, unserved, 0);
    all_ok &= check_value("N4 bram-unchanged", bram_word, 0x0123456789ABCDEFull);

    /* N5: the base is in the MMIO window's last page and the immediate
     * carries the store into the first unserved page. */
    RUN_CASE("mv   t1, %0\n"
             "sw   t2, 8(t1)",
             "r"(0x40030FF8ul));
    all_ok &= report3("N5 store-carries-past-mmio", 7u, 0, 0x40031000ul, 0);

    /* N6: loads at the edges of the served windows. */
    for (unsigned i = 0; i < sizeof(k_unserved_loads) / sizeof(k_unserved_loads[0]); i++) {
        RUN_CASE("mv   t1, %0\n"
                 "lw   t2, 0(t1)",
                 "r"(k_unserved_loads[i]));
        all_ok &= report3("N6 unserved-edge-lw", 5u, 0, k_unserved_loads[i], 0);
    }

    uart_puts(all_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
