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
 * Trap-frame store visibility under L1D eviction.
 *
 * The observed Linux failure restored s2=0x19999998 instead of its pointer
 * after a timer IRQ. This test checks whether a trap-frame store can leave the
 * SQ before reaching L1D, allowing eviction to write stale data to DDR.
 *
 * Under MEM_CONFIG=ddr, a Linux-style rv64 entry saves pt_regs (288 bytes,
 * 8-byte REG_S/REG_L slots) at fixed FRAME_BASE, with s2 last at offset 144.
 * The slot is pre-poisoned with the observed bad value. A cold drain store
 * precedes the IRQ. The handler then evicts s2's line through same-set
 * addresses (128 KiB direct-mapped L1D, 32-byte lines, alias stride 0x20000)
 * and reads it back.
 *
 * The rv32-era 4-byte-slot version of this test died with the Phase 3 M2
 * aliasing retirement: sw/lw round-trips of bit-31 pointers sign-extend and
 * PMA-fault, while rv64 sd/ld round-trips are exact.
 *
 * Failure codes distinguish:
 *   29: incoming architectural s2 was already corrupt.
 *   30: the saved value was wrong before eviction.
 *   31: it was correct before eviction and wrong afterward (the target bug).
 *
 * Timer margin 0..255 and a 0..15 post-store gap sweep the drain/eviction
 * window. A fixed continuation keeps a bad mepc reportable. The registered
 * simulation uses a deliberately small L2 and DDR_MODEL_LATENCY>=70 to keep
 * writeback pressure high. Failures print the code, margin, expected value,
 * and actual value.
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

/* 128 KiB direct-mapped L1D with 32-byte lines. */
#define L1D_STRIDE 0x00020000u /* 128 KiB: A and A+stride share one set */
#define N_EVICT 6u             /* conflicting lines touched per eviction */

/* Line-aligned cached-DDR trap frame. */
#define FRAME_BASE 0x82000000u
#define FRAME_TOP (FRAME_BASE + 288u)    /* rv64 pt_regs is 288 bytes; sp on entry */
#define S2_LINE_BASE (FRAME_BASE + 128u) /* 32 B line holding s2@144 (128..159) */

/* Cold drain region in L1D sets 2048+, clear of the frame's sets 0..8. */
#define DRAIN_BASE 0x83010000u
#define DRAIN_LINE 64u

#define MARGIN_MIN 0u
#define MARGIN_MAX 255u

#define POISON_S2 0x19999998u /* the real name_to_int value */

/* Globals referenced by name from the naked asm (kept non-static, used). */
uint32_t g_s2_target; /* &g_s2_target (full 64-bit address) is the correct s2 value */

volatile uint32_t g_ticks;
volatile uint32_t g_irq_count;
volatile uint64_t g_expected_s2;
volatile uint32_t g_gap;
volatile uint32_t g_timer_margin;
volatile uint64_t g_drain_addr;
volatile uint64_t g_cont;       /* fixed continuation PC for the handler */
volatile uint64_t g_cret;       /* irq_window() return address into C */
volatile uint64_t g_csp;        /* irq_window() caller stack pointer */
volatile uint64_t g_save_s[12]; /* main's callee-saved s0..s11 spill */

volatile uint32_t g_last_code;
volatile uint32_t g_last_reg;
volatile uint64_t g_last_expected;
volatile uint64_t g_last_actual;

/*
 * Naked M-mode timer trap entry. Saves and restores an rv64 Linux-style
 * pt_regs frame (sd/ld, 8-byte slots) on a cached-DDR "kernel stack"
 * (sp == FRAME_TOP, set by irq_window). s2 is saved last, immediately before
 * the handler evicts its line from the direct-mapped L1D. Records the
 * discriminator codes and resumes through the fixed continuation in g_cont,
 * so a wrong mepc cannot wedge the sweep.
 */
__attribute__((naked, used, aligned(4))) static void trapframe_irq_entry(void)
{
    __asm__ volatile("addi sp, sp, -288\n"
                     /* ---- save the frame, every register except s2 ---- */
                     "sd   ra, 8(sp)\n"
                     "sd   gp, 24(sp)\n"
                     "sd   tp, 32(sp)\n"
                     "sd   t0, 40(sp)\n"
                     "sd   t1, 48(sp)\n"
                     "sd   t2, 56(sp)\n"
                     "sd   s0, 64(sp)\n"
                     "sd   s1, 72(sp)\n"
                     "sd   a0, 80(sp)\n"
                     "sd   a1, 88(sp)\n"
                     "sd   a2, 96(sp)\n"
                     "sd   a3, 104(sp)\n"
                     "sd   a4, 112(sp)\n"
                     "sd   a5, 120(sp)\n"
                     "sd   a6, 128(sp)\n"
                     "sd   a7, 136(sp)\n"
                     "sd   s3, 152(sp)\n"
                     "sd   s4, 160(sp)\n"
                     "sd   s5, 168(sp)\n"
                     "sd   s6, 176(sp)\n"
                     "sd   s7, 184(sp)\n"
                     "sd   s8, 192(sp)\n"
                     "sd   s9, 200(sp)\n"
                     "sd   s10, 208(sp)\n"
                     "sd   s11, 216(sp)\n"
                     "sd   t3, 224(sp)\n"
                     "sd   t4, 232(sp)\n"
                     "sd   t5, 240(sp)\n"
                     "sd   t6, 248(sp)\n"
                     "csrr t0, mepc\n"
                     "sd   t0, 0(sp)\n"
                     "csrr t0, mstatus\n"
                     "sd   t0, 256(sp)\n"
                     /* preload the gap count into a saved scratch (t4) so the s2-store ->
                      * eviction distance is ALU-only and not perturbed by a memory read */
                     "la   t4, g_gap\n"
                     "lw   t4, 0(t4)\n"
                     /* ---- code=29: incoming architectural s2 vs expected (precise state) */
                     "la   t0, g_expected_s2\n"
                     "ld   t0, 0(t0)\n"
                     "beq  s2, t0, 1f\n"
                     "la   t1, g_last_code\n"
                     "lw   t2, 0(t1)\n"
                     "bnez t2, 1f\n"
                     "li   t2, 29\n"
                     "sw   t2, 0(t1)\n"
                     "la   t1, g_last_reg\n"
                     "li   t2, 2\n"
                     "sw   t2, 0(t1)\n"
                     "la   t1, g_last_expected\n"
                     "sd   t0, 0(t1)\n"
                     "la   t1, g_last_actual\n"
                     "sd   s2, 0(t1)\n"
                     "1:\n"
                     /* ================= STORE UNDER TEST: sd s2, 144(sp) ================= */
                     "sd   s2, 144(sp)\n"
                     /* ---- tunable gap (ALU only) ---- */
                     "2:\n"
                     "beqz t4, 3f\n"
                     "addi t4, t4, -1\n"
                     "j    2b\n"
                     "3:\n"
                     /* ---- code=30: saved value before eviction (forwards from the SQ if
                      * the store is still in flight; reads L1D otherwise) ---- */
                     "ld   t0, 144(sp)\n"
                     "la   t1, g_expected_s2\n"
                     "ld   t1, 0(t1)\n"
                     "beq  t0, t1, 4f\n"
                     "la   t2, g_last_code\n"
                     "lw   t3, 0(t2)\n"
                     "bnez t3, 4f\n"
                     "li   t3, 30\n"
                     "sw   t3, 0(t2)\n"
                     "la   t2, g_last_reg\n"
                     "li   t3, 2\n"
                     "sw   t3, 0(t2)\n"
                     "la   t2, g_last_expected\n"
                     "sd   t1, 0(t2)\n"
                     "la   t2, g_last_actual\n"
                     "sd   t0, 0(t2)\n"
                     "4:\n"
                     /* ---- evict the saved s2 line: stride by the L1D size so every access
                      * maps to the same set with a different tag (direct-mapped), evicting
                      * and writing back the just-stored dirty frame line. The base is built
                      * from a positive constant because li of a bit-31 constant
                      * sign-extends. ---- */
                     "li   t1, 0x8200008\n"
                     "slli t1, t1, 4\n"   /* S2_LINE_BASE = 0x82000080 */
                     "li   t2, 0x20000\n" /* L1D_STRIDE  */
                     "li   t3, 6\n"       /* N_EVICT     */
                     "5:\n"
                     "ld   t5, 0(t1)\n"
                     "add  t1, t1, t2\n"
                     "addi t3, t3, -1\n"
                     "bnez t3, 5b\n"
                     /* ============ LOAD UNDER TEST: ld s2, 144(sp) (post-evict) =========
                      * The line was evicted, so this load misses, refills from DDR, and sees
                      * whatever the eviction wrote back. code=31 if it differs (the
                      * targeted bug). */
                     "ld   t0, 144(sp)\n"
                     "la   t1, g_expected_s2\n"
                     "ld   t1, 0(t1)\n"
                     "beq  t0, t1, 6f\n"
                     "la   t2, g_last_code\n"
                     "lw   t3, 0(t2)\n"
                     "bnez t3, 6f\n"
                     "li   t3, 31\n"
                     "sw   t3, 0(t2)\n"
                     "la   t2, g_last_reg\n"
                     "li   t3, 2\n"
                     "sw   t3, 0(t2)\n"
                     "la   t2, g_last_expected\n"
                     "sd   t1, 0(t2)\n"
                     "la   t2, g_last_actual\n"
                     "sd   t0, 0(t2)\n"
                     "6:\n"
                     /* ---- witnesses: s3@152 shares s2's line, s4@160 sits in the next
                      * line as a plain visibility check ---- */
                     "ld   t0, 152(sp)\n"
                     "li   t1, 0x51000003\n"
                     "beq  t0, t1, 7f\n"
                     "la   t2, g_last_code\n"
                     "lw   t3, 0(t2)\n"
                     "bnez t3, 7f\n"
                     "li   t3, 31\n"
                     "sw   t3, 0(t2)\n"
                     "la   t2, g_last_reg\n"
                     "li   t3, 3\n"
                     "sw   t3, 0(t2)\n"
                     "la   t2, g_last_expected\n"
                     "sd   t1, 0(t2)\n"
                     "la   t2, g_last_actual\n"
                     "sd   t0, 0(t2)\n"
                     "7:\n"
                     "ld   t0, 160(sp)\n"
                     "li   t1, 0x51000004\n"
                     "beq  t0, t1, 8f\n"
                     "la   t2, g_last_code\n"
                     "lw   t3, 0(t2)\n"
                     "bnez t3, 8f\n"
                     "li   t3, 31\n"
                     "sw   t3, 0(t2)\n"
                     "la   t2, g_last_reg\n"
                     "li   t3, 4\n"
                     "sw   t3, 0(t2)\n"
                     "la   t2, g_last_expected\n"
                     "sd   t1, 0(t2)\n"
                     "la   t2, g_last_actual\n"
                     "sd   t0, 0(t2)\n"
                     "8:\n"
                     /* ---- side effects (scratch t0..t2, restored below) ---- */
                     "li   t1, 0x4000001C\n" /* MTIMECMP_HI := -1 : disarm so no refire */
                     "li   t0, -1\n"
                     "sw   t0, 0(t1)\n"
                     "la   t1, g_ticks\n"
                     "li   t0, 1\n"
                     "sw   t0, 0(t1)\n"
                     "la   t1, g_irq_count\n"
                     "lw   t0, 0(t1)\n"
                     "addi t0, t0, 1\n"
                     "sw   t0, 0(t1)\n"
                     "la   t1, g_cont\n" /* fixed continuation: a bad mepc cannot wedge the sweep */
                     "ld   t0, 0(t1)\n"
                     "csrw mepc, t0\n"
                     "ld   t0, 256(sp)\n"
                     "csrw mstatus, t0\n"
                     /* ---- restore the frame (full trap exit) ---- */
                     "ld   ra, 8(sp)\n"
                     "ld   gp, 24(sp)\n"
                     "ld   tp, 32(sp)\n"
                     "ld   s0, 64(sp)\n"
                     "ld   s1, 72(sp)\n"
                     "ld   a0, 80(sp)\n"
                     "ld   a1, 88(sp)\n"
                     "ld   a2, 96(sp)\n"
                     "ld   a3, 104(sp)\n"
                     "ld   a4, 112(sp)\n"
                     "ld   a5, 120(sp)\n"
                     "ld   a6, 128(sp)\n"
                     "ld   a7, 136(sp)\n"
                     "ld   s2, 144(sp)\n"
                     "ld   s3, 152(sp)\n"
                     "ld   s4, 160(sp)\n"
                     "ld   s5, 168(sp)\n"
                     "ld   s6, 176(sp)\n"
                     "ld   s7, 184(sp)\n"
                     "ld   s8, 192(sp)\n"
                     "ld   s9, 200(sp)\n"
                     "ld   s10, 208(sp)\n"
                     "ld   s11, 216(sp)\n"
                     "ld   t3, 224(sp)\n"
                     "ld   t4, 232(sp)\n"
                     "ld   t5, 240(sp)\n"
                     "ld   t6, 248(sp)\n"
                     "ld   t0, 40(sp)\n"
                     "ld   t1, 48(sp)\n"
                     "ld   t2, 56(sp)\n"
                     "addi sp, sp, 288\n"
                     "mret\n");
}

/*
 * Naked per-margin window. Preserves main's callee-saved registers, sets up the
 * cached-DDR frame stack + poison + drain store, arms the timer, loads the s0..
 * s11 sentinels, enables MIE, and spins until the handler fires. The handler
 * redirects mepc to label 9 (the fixed continuation). Reads its per-margin
 * inputs (g_timer_margin, g_gap, g_drain_addr, g_expected_s2) from globals set
 * by C before the call.
 */
__attribute__((naked, used, noinline)) static void irq_window(void)
{
    __asm__ volatile(
        /* preserve main's callee-saved s0..s11; the sentinels below clobber them */
        "la   t0, g_save_s\n"
        "sd   s0, 0(t0)\n"
        "sd   s1, 8(t0)\n"
        "sd   s2, 16(t0)\n"
        "sd   s3, 24(t0)\n"
        "sd   s4, 32(t0)\n"
        "sd   s5, 40(t0)\n"
        "sd   s6, 48(t0)\n"
        "sd   s7, 56(t0)\n"
        "sd   s8, 64(t0)\n"
        "sd   s9, 72(t0)\n"
        "sd   s10, 80(t0)\n"
        "sd   s11, 88(t0)\n"
        "la   t0, g_csp\n"
        "sd   sp, 0(t0)\n"
        "la   t0, g_cret\n"
        "sd   ra, 0(t0)\n"
        /* fixed continuation for the handler's mepc redirect */
        "la   t0, g_cont\n"
        "la   t1, 9f\n"
        "sd   t1, 0(t0)\n"
        "la   t0, g_ticks\n"
        "sw   x0, 0(t0)\n"
        /* kernel stack pointer: the handler does sd s2, 144(sp). Built from a
         * positive constant because li of a bit-31 constant sign-extends,
         * which is the rv32-ism the M2 PMA retirement faults. */
        "li   sp, 0x8200012\n"
        "slli sp, sp, 4\n" /* FRAME_TOP = 0x82000120 */
        /* pre-poison the frame's s2 line so a save that never lands reads a
         * stale value; the s2 slot gets 0x19999998 (the real name_to_int value). */
        "li   t0, 0x820\n"
        "slli t0, t0, 20\n" /* FRAME_BASE = 0x82000000 */
        "li   t1, 0x19999998\n"
        "sd   t1, 144(t0)\n"
        "li   t1, 0x19999993\n"
        "sd   t1, 152(t0)\n"
        "li   t1, 0x19999994\n"
        "sd   t1, 160(t0)\n"
        "li   t1, 0x19999995\n"
        "sd   t1, 168(t0)\n"
        "li   t1, 0x19999996\n"
        "sd   t1, 176(t0)\n"
        "li   t1, 0x19999997\n"
        "sd   t1, 184(t0)\n"
        /* cold-miss drain store: a fresh DDR line, still in flight when the IRQ hits */
        "la   t0, g_drain_addr\n"
        "ld   t0, 0(t0)\n"
        "li   t1, 0xD2A14000\n"
        "sw   t1, 0(t0)\n"
        /* arm the timer: mtimecmp = mtime + margin */
        "la   t0, g_timer_margin\n"
        "lw   t0, 0(t0)\n"
        "li   t2, 0x40000010\n" /* MTIME_LO base */
        "lw   t3, 4(t2)\n"      /* mtime hi (0x14) */
        "lw   t4, 0(t2)\n"      /* mtime lo (0x10) */
        "add  t4, t4, t0\n"
        "li   t1, 0x40000018\n" /* MTIMECMP_LO base */
        "li   t5, -1\n"
        "sw   t5, 4(t1)\n" /* MTIMECMP_HI = max (0x1C) */
        "sw   t4, 0(t1)\n" /* MTIMECMP_LO (0x18)      */
        "sw   t3, 4(t1)\n" /* MTIMECMP_HI = hi (0x1C) */
        /* sentinels into s0..s11, loaded last; s2 gets the pointer-like expected
         * value. At rv64 the frame round-trips through sd/ld, so the reference
         * is the full 64-bit address with no sign-extension pinning. */
        "li   s0, 0x51000000\n"
        "li   s1, 0x51000001\n"
        "la   s2, g_s2_target\n"
        "li   s3, 0x51000003\n"
        "li   s4, 0x51000004\n"
        "li   s5, 0x51000005\n"
        "li   s6, 0x51000006\n"
        "li   s7, 0x51000007\n"
        "li   s8, 0x51000008\n"
        "li   s9, 0x51000009\n"
        "li   s10, 0x5100000a\n"
        "li   s11, 0x5100000b\n"
        "csrsi mstatus, 8\n" /* enable MIE -> armed timer fires into handler */
        "li   t0, 0\n"
        "10:\n"
        "la   t1, g_ticks\n"
        "lw   t1, 0(t1)\n"
        "bnez t1, 9f\n"
        "la   t1, g_last_code\n"
        "lw   t1, 0(t1)\n"
        "bnez t1, 9f\n"
        "addi t0, t0, 1\n"
        "li   t1, 200000\n"
        "bltu t0, t1, 10b\n"
        "9:\n" /* continuation (handler redirects mepc here) */
        "csrci mstatus, 8\n"
        /* restore main's s0..s11 */
        "la   t0, g_save_s\n"
        "ld   s0, 0(t0)\n"
        "ld   s1, 8(t0)\n"
        "ld   s2, 16(t0)\n"
        "ld   s3, 24(t0)\n"
        "ld   s4, 32(t0)\n"
        "ld   s5, 40(t0)\n"
        "ld   s6, 48(t0)\n"
        "ld   s7, 56(t0)\n"
        "ld   s8, 64(t0)\n"
        "ld   s9, 72(t0)\n"
        "ld   s10, 80(t0)\n"
        "ld   s11, 88(t0)\n"
        "la   t0, g_csp\n"
        "ld   sp, 0(t0)\n"
        "la   t0, g_cret\n"
        "ld   ra, 0(t0)\n"
        "ret\n");
}

int main(void)
{
    uint32_t n29 = 0, n30 = 0, n31 = 0, fired = 0, nofire = 0;
    uint32_t first_margin = 0xFFFFFFFFu;
    uint32_t first_code = 0, first_reg = 0;
    uint64_t first_exp = 0, first_act = 0;

    uart_printf("\n=== drain trap-frame eviction test (Bug B @ pt_regs s2) ===\n");
    uart_printf("L1D=128KiB direct-mapped 32B lines; evict stride=0x%08x; frame@0x%08x s2@144\n",
                L1D_STRIDE,
                FRAME_BASE);

    g_expected_s2 = (uintptr_t) &g_s2_target;
    set_trap_handler(&trapframe_irq_entry);
    csr_set(mie, MIE_MTIE);
    disable_interrupts();

    for (uint32_t margin = MARGIN_MIN; margin <= MARGIN_MAX; margin++) {
        g_timer_margin = margin;
        g_gap = margin & 15u;
        g_drain_addr = DRAIN_BASE + margin * DRAIN_LINE;
        g_expected_s2 = (uintptr_t) &g_s2_target;
        g_last_code = 0;
        g_last_reg = 0;
        g_last_expected = 0;
        g_last_actual = 0;
        g_ticks = 0;

        irq_window();

        if (g_ticks == 0u) {
            nofire++;
            continue;
        }
        fired++;
        if (g_last_code == 29u) {
            n29++;
        } else if (g_last_code == 30u) {
            n30++;
        } else if (g_last_code == 31u) {
            n31++;
        }
        if (g_last_code != 0u && first_margin == 0xFFFFFFFFu) {
            first_margin = margin;
            first_code = g_last_code;
            first_reg = g_last_reg;
            first_exp = g_last_expected;
            first_act = g_last_actual;
        }
    }

    disable_timer_interrupt();
    disable_interrupts();

    uart_printf(
        "sweep: fired=%u nofire=%u code29=%u code30=%u code31=%u\n", fired, nofire, n29, n30, n31);
    uart_printf("expected_s2=%lx irq_count=%u\n", (unsigned long) g_expected_s2, g_irq_count);

    if (n29 == 0u && n30 == 0u && n31 == 0u && fired > 0u) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("FAIL first_margin=%u code=%u reg=s%u expected=%lx actual=%lx\n",
                    first_margin,
                    first_code,
                    first_reg,
                    (unsigned long) first_exp,
                    (unsigned long) first_act);
        uart_printf("codes: 29=precise-state 30=save-not-visible 31=eviction/visibility\n");
        uart_printf("<<FAIL>>\n");
    }

    for (;;) {
    }
    return 0;
}
