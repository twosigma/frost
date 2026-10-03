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
 * F/D instructions while mstatus.FS is Off.
 *
 * With FS Off every F/D instruction raises illegal-instruction (mcause 2,
 * mtval 0) before it touches memory: an FP load reads no device register, and
 * no address fault takes the place of the illegal-instruction cause. A write
 * to mstatus.FS applies from the next instruction on. Self-checks over UART
 * (<<PASS>>/<<FAIL>>), all with mtvec set:
 *
 *   A. FLD from an unmapped address: cause 2, not the access fault (5).
 *   B. Misaligned FSD: cause 2, not the misaligned-store fault (6); memory is
 *      unchanged.
 *   C. FADD.S: cause 2.
 *   D. FLW right after an integer instruction (so it can be the second
 *      instruction of a fetch pair): cause 2 at the FLW.
 *   E. FLW from MMIO FIFO0 holding two words: cause 2, and the FIFO still
 *      returns both words in order.
 *   F. `csrs mstatus` setting FS directly followed by FLD: no trap, and the
 *      load returns the data.
 *   G. `csrc mstatus` clearing FS directly followed by FLW: cause 2.
 *   H. FLW from UART RX data (0x4000_0004) with a byte waiting: cause 2, and
 *      the byte is still there afterwards. The cocotb bench sends the byte.
 *   I. `csrs sstatus` setting FS directly followed by FLD: no trap, and the
 *      load returns the data.
 *   J. `csrc sstatus` clearing FS directly followed by FLW: cause 2.
 *
 * Each case uses the M-mode bounce from pma_fault_test: the handler records
 * mcause, mepc and mtval for the case's first trap and returns to the
 * continuation in mscratch. Every trigger is followed by an ecall, so a
 * trigger that does not trap records cause 11. The FS=Off window opens and
 * closes inside each case's asm block, so no compiled code runs with FS Off.
 */

#include <stdint.h>

#include "csr.h"
#include "mmio.h"
#include "trap.h"
#include "uart.h"

#define UART_RX_DATA_PA 0x40000004ul
#define FIFO0_PA 0x40000008ul
#define UNMAPPED_PA 0x00100000ul /* the hole above the 256 KiB BRAM */
#define RX_BYTE 0x5A             /* what the cocotb bench sends */
#define RX_WAIT_CYCLES 200000    /* well inside the cocotb run budget */

static int g_ok = 1;
static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_tval;
static volatile uint64_t g_data[2] __attribute__((aligned(16)));

/* Trigger instructions, labeled inside the asm blocks below. */
extern char trig_a[], trig_b[], trig_c[], trig_d[], trig_e[], trig_g[], trig_h[], trig_j[];

/* M-mode bounce handler: record mcause/mepc/mtval once per case, return to
 * the mscratch continuation in M-mode. It uses no FP state. */
__attribute__((naked, aligned(4))) static void fs_trap_handler(void)
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
                     "2:\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

static void reset_records(void)
{
    g_cause = ~0ul;
    g_epc = ~0ul;
    g_tval = ~0ul;
}

/* Run a trigger with FS Off: clear FS, run it, and set FS back to Dirty at
 * the continuation. The body labels its trigger instruction (trig_*), and the
 * ecall after it is the no-trap fallback. */
#define RUN_FS_OFF_CASE(body_asm, ...)                                                             \
    do {                                                                                           \
        reset_records();                                                                           \
        __asm__ volatile("la   t0, 1f\n"                                                           \
                         "csrw mscratch, t0\n"                                                     \
                         "li   t0, 0x6000\n"                                                       \
                         "csrc mstatus, t0\n" body_asm "\n"                                        \
                         "ecall\n"                                                                 \
                         "1:\n"                                                                    \
                         "li   t0, 0x6000\n"                                                       \
                         "csrs mstatus, t0\n"                                                      \
                         :                                                                         \
                         : __VA_ARGS__                                                             \
                         : "t0", "t1", "t2", "t3", "ft0", "memory");                               \
    } while (0)

static void report(const char *name, int ok)
{
    if (!ok)
        g_ok = 0;
    uart_printf("%s %s cause=%lx epc=%lx tval=%lx\n",
                ok ? "[PASS]" : "[FAIL]",
                name,
                g_cause,
                g_epc,
                g_tval);
}

/* The trigger raised illegal-instruction at its own PC with mtval 0. */
static int illegal_at(const char *trigger)
{
    return g_cause == 2u && g_epc == (unsigned long) trigger && g_tval == 0u;
}

int main(void)
{
    uart_printf("\n=== FS=Off FP instruction test ===\n");
    set_trap_handler(&fs_trap_handler);

    /* A: an unmapped address must not turn the trap into an access fault. */
    RUN_FS_OFF_CASE(".globl trig_a\ntrig_a:\nfld ft0, 0(%0)", "r"(UNMAPPED_PA));
    report("A unmapped FLD", illegal_at(trig_a));

    /* B: a misaligned FSD must not turn the trap into a misaligned fault. */
    g_data[0] = 0x0123456789ABCDEFull;
    g_data[1] = 0xFEDCBA9876543210ull;
    RUN_FS_OFF_CASE(".globl trig_b\ntrig_b:\nfsd ft0, 1(%0)", "r"((unsigned long) &g_data[0]));
    report("B misaligned FSD",
           illegal_at(trig_b) && g_data[0] == 0x0123456789ABCDEFull &&
               g_data[1] == 0xFEDCBA9876543210ull);

    /* C: an FP compute instruction. */
    RUN_FS_OFF_CASE(".globl trig_c\ntrig_c:\nfadd.s ft0, ft0, ft0", "r"(0));
    report("C FADD.S", illegal_at(trig_c));

    /* D: FLW behind an integer instruction, where it can pair as slot 2. */
    RUN_FS_OFF_CASE("addi t1, zero, 7\n.globl trig_d\ntrig_d:\nflw ft0, 0(%0)",
                    "r"((unsigned long) &g_data[0]));
    report("D FLW in a pair", illegal_at(trig_d));

    /* E: a trapping FLW must not pop the FIFO. */
    FIFO0 = 0x11111111u;
    FIFO0 = 0x22222222u;
    RUN_FS_OFF_CASE(".globl trig_e\ntrig_e:\nflw ft0, 0(%0)", "r"(FIFO0_PA));
    uint32_t first = FIFO0;
    uint32_t second = FIFO0;
    uart_printf("FIFO0 after the FLW: %x %x\n", first, second);
    report("E FIFO0 FLW", illegal_at(trig_e) && first == 0x11111111u && second == 0x22222222u);

    /* F: setting FS takes effect for the very next instruction. */
    uint64_t loaded;
    g_data[0] = 0x4045000000000000ull; /* 42.0 */
    reset_records();
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x6000\n"
                     "csrc mstatus, t0\n"
                     "csrs mstatus, t0\n"
                     "fld  ft0, 0(%1)\n"
                     "ecall\n"
                     "1:\n"
                     "li   t0, 0x6000\n"
                     "csrs mstatus, t0\n"
                     "fmv.x.d %0, ft0\n"
                     : "=r"(loaded)
                     : "r"((unsigned long) &g_data[0])
                     : "t0", "t1", "t2", "t3", "ft0", "memory");
    report("F csrs FS then FLD", g_cause == 11u && loaded == 0x4045000000000000ull);

    /* G: clearing FS takes effect for the very next instruction. */
    reset_records();
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x6000\n"
                     "csrs mstatus, t0\n"
                     "csrc mstatus, t0\n"
                     ".globl trig_g\n"
                     "trig_g:\n"
                     "flw  ft0, 0(%0)\n"
                     "ecall\n"
                     "1:\n"
                     "li   t0, 0x6000\n"
                     "csrs mstatus, t0\n"
                     :
                     : "r"((unsigned long) &g_data[0])
                     : "t0", "t1", "t2", "t3", "ft0", "memory");
    report("G csrc FS then FLW", illegal_at(trig_g));

    /* H: a trapping FLW must not consume a waiting UART RX byte. The wait for
     * the bench's byte is bounded, so a missing byte fails H rather than
     * running the simulation out of cycles. */
    uint64_t wait_start = rdcycle64();
    while (!uart_rx_available() && rdcycle64() - wait_start < RX_WAIT_CYCLES) {
    }
    if (!uart_rx_available()) {
        uart_printf("[FAIL] H no UART RX byte arrived (the cocotb bench sends one)\n");
        g_ok = 0;
    } else {
        RUN_FS_OFF_CASE(".globl trig_h\ntrig_h:\nflw ft0, 0(%0)", "r"(UART_RX_DATA_PA));
        int still_there = uart_rx_available();
        int byte = still_there ? (int) (uint8_t) UART_RX_DATA : -1;
        uart_printf("UART RX after the FLW: available=%d byte=%x\n", still_there, byte);
        report("H UART RX FLW", illegal_at(trig_h) && byte == RX_BYTE);
    }

    /* I and J: FS written through sstatus takes effect for the very next
     * instruction too. I loads a value F did not, so a stale ft0 cannot pass. */
    g_data[0] = 0x4059000000000000ull; /* 100.0 */
    reset_records();
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x6000\n"
                     "csrc sstatus, t0\n"
                     "csrs sstatus, t0\n"
                     "fld  ft0, 0(%1)\n"
                     "ecall\n"
                     "1:\n"
                     "li   t0, 0x6000\n"
                     "csrs mstatus, t0\n"
                     "fmv.x.d %0, ft0\n"
                     : "=r"(loaded)
                     : "r"((unsigned long) &g_data[0])
                     : "t0", "t1", "t2", "t3", "ft0", "memory");
    report("I csrs sstatus FS then FLD", g_cause == 11u && loaded == 0x4059000000000000ull);

    reset_records();
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x6000\n"
                     "csrs sstatus, t0\n"
                     "csrc sstatus, t0\n"
                     ".globl trig_j\n"
                     "trig_j:\n"
                     "flw  ft0, 0(%0)\n"
                     "ecall\n"
                     "1:\n"
                     "li   t0, 0x6000\n"
                     "csrs mstatus, t0\n"
                     :
                     : "r"((unsigned long) &g_data[0])
                     : "t0", "t1", "t2", "t3", "ft0", "memory");
    report("J csrc sstatus FS then FLW", illegal_at(trig_j));

    uart_printf(g_ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
