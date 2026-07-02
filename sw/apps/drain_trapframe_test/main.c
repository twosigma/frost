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
 * Directed test for "Bug B" relocated to the kernel trap frame (pt_regs):
 * TRAP-FRAME STORE-VISIBILITY UNDER L1D CACHE EVICTION.
 *
 * Real-world failure being reproduced: at a procfs panic the callee-saved
 * register s2 came back as 0x19999998 (a value name_to_int materialises)
 * instead of its proper pointer, after a machine-timer interrupt fired during
 * active kernel code. Suspected mechanism (same class as the fence.i/SMC "store
 * leaves the SQ when sent, not when landed" bug): the naked trap entry saves
 * GPRs to the kernel stack ("sw s2, 72(sp)"); if that committed store is
 * considered drained from the store queue BEFORE its data physically lands in
 * the write-back L1D, and cache pressure during the handler EVICTS that stack
 * line (writing STALE data back to DDR), then the trap exit "lw s2, 72(sp)"
 * refills from DDR and restores s2 WRONG.
 *
 * Construction (full frost SoC, cached/DDR tier, MEM_CONFIG=ddr):
 *   - A faithful Linux-style naked trap entry saves the full pt_regs frame to a
 *     cached-DDR "kernel stack" at a FIXED line-aligned address (FRAME_BASE), so
 *     the exact L1D set holding the saved s2 word is known and can be evicted
 *     deterministically. s2 sits at offset 72, exactly as in the real handler.
 *   - Before each interrupt the frame's s2 cache line is PRE-POISONED with
 *     0x19999998 (the real failing value), so a non-landed save read-back yields
 *     EXACTLY the real-world wrong value.
 *   - A cold-miss DDR drain store is issued just before the IRQ window (like
 *     wfi_drain_mepc_test) so a store is in flight / the memory subsystem is
 *     busy when the trap is taken.
 *   - AFTER saving the frame (s2 stored LAST, immediately before the eviction)
 *     the handler AGGRESSIVELY EVICTS the saved s2 line by striding through
 *     cached-DDR addresses that map to the SAME L1D set. The L1D is 128 KiB
 *     DIRECT-MAPPED with 32-byte lines (hw/rtl/lib/cache/frost_cache.sv,
 *     L1_CACHE_BYTES=128*1024), so address A and A + 0x20000 collide in one set.
 *   - The handler then reads the s2 slot back (the load under test) and checks.
 *
 * Discriminator (the key result):
 *   code=29 : the incoming ARCHITECTURAL s2 was already wrong (precise-state /
 *             rename corruption) -- not the target bug.
 *   code=30 : the SAVED frame value was already wrong BEFORE eviction
 *             (the store never became visible at all).
 *   code=31 : the saved frame was CORRECT before eviction but the post-eviction
 *             read-back is WRONG  ==> the store/eviction memory-visibility bug.
 *             THIS is the targeted reproduction.
 *
 * The timer margin is swept finely (0..255) so the IRQ lands at every offset
 * across the drain+handler window; the per-margin "gap" (filler between the s2
 * store and the eviction) is also swept (0..15) to sample the in-flight window.
 * Resume is via a fixed continuation (the handler redirects mepc), so a wrong
 * mepc is never fatal. Run with CACHED_HAS_L2=0 (Genesys2 / HW-faithful shape,
 * where a cold write-back actually drains) and DDR_MODEL_LATENCY>=70.
 *
 * PASS  -> prints <<PASS>> (no margin ever corrupts a restored register).
 * FAIL  -> prints <<FAIL>> with code + margin + expected/actual (e.g. s2).
 */

#include <stdint.h>

#include "trap.h"
#include "uart.h"

/* ---- L1D geometry (frost_cache.sv: 128 KiB direct-mapped, 32 B lines) ---- */
#define L1D_STRIDE 0x00020000u /* 128 KiB: A and A+stride share one set */
#define N_EVICT 6u             /* conflicting lines touched per eviction */

/* ---- Fixed cached-DDR "kernel stack" for the trap frame (line aligned) ---- */
#define FRAME_BASE 0x82000000u
#define FRAME_TOP (FRAME_BASE + 144u)   /* pt_regs is 144 bytes; sp on entry */
#define S2_LINE_BASE (FRAME_BASE + 64u) /* 32 B line holding s2@72 (64..95) */

/* Cold DDR region for the per-margin in-flight drain store. Chosen so its L1D
 * sets (2048..) never collide with the frame's s2 set (2), and far from the
 * program and the frame. */
#define DRAIN_BASE 0x83010000u
#define DRAIN_LINE 64u

#define MARGIN_MIN 0u
#define MARGIN_MAX 255u

#define POISON_S2 0x19999998u /* the real name_to_int value */

/* Globals referenced by name from the naked asm (kept non-static, used). */
uint32_t g_s2_target; /* &g_s2_target is the pointer-like correct s2 value */

volatile uint32_t g_ticks;
volatile uint32_t g_irq_count;
volatile uint32_t g_expected_s2;
volatile uint32_t g_gap;
volatile uint32_t g_timer_margin;
volatile uint32_t g_drain_addr;
volatile uint32_t g_cont;       /* fixed continuation PC for the handler */
volatile uint32_t g_cret;       /* irq_window() return address into C */
volatile uint32_t g_csp;        /* irq_window() caller stack pointer */
volatile uint32_t g_save_s[12]; /* main's callee-saved s0..s11 spill */

volatile uint32_t g_last_code;
volatile uint32_t g_last_reg;
volatile uint32_t g_last_expected;
volatile uint32_t g_last_actual;

/*
 * Naked M-mode timer trap entry. Faithful Linux-style pt_regs save/restore to a
 * cached-DDR "kernel stack" (sp == FRAME_TOP, set by irq_window), with s2 saved
 * LAST (immediately before the eviction) and the saved s2 line then evicted from
 * the direct-mapped L1D. Records the discriminator codes. Resumes via the fixed
 * continuation in g_cont so a wrong mepc cannot wedge the sweep.
 */
__attribute__((naked, used, aligned(4))) static void trapframe_irq_entry(void)
{
    __asm__ volatile("addi sp, sp, -144\n"
                     /* ---- save the frame (everything EXCEPT s2 first) ---- */
                     "sw   ra, 4(sp)\n"
                     "sw   gp, 12(sp)\n"
                     "sw   tp, 16(sp)\n"
                     "sw   t0, 20(sp)\n"
                     "sw   t1, 24(sp)\n"
                     "sw   t2, 28(sp)\n"
                     "sw   s0, 32(sp)\n"
                     "sw   s1, 36(sp)\n"
                     "sw   a0, 40(sp)\n"
                     "sw   a1, 44(sp)\n"
                     "sw   a2, 48(sp)\n"
                     "sw   a3, 52(sp)\n"
                     "sw   a4, 56(sp)\n"
                     "sw   a5, 60(sp)\n"
                     "sw   a6, 64(sp)\n"
                     "sw   a7, 68(sp)\n"
                     "sw   s3, 76(sp)\n"
                     "sw   s4, 80(sp)\n"
                     "sw   s5, 84(sp)\n"
                     "sw   s6, 88(sp)\n"
                     "sw   s7, 92(sp)\n"
                     "sw   s8, 96(sp)\n"
                     "sw   s9, 100(sp)\n"
                     "sw   s10, 104(sp)\n"
                     "sw   s11, 108(sp)\n"
                     "sw   t3, 112(sp)\n"
                     "sw   t4, 116(sp)\n"
                     "sw   t5, 120(sp)\n"
                     "sw   t6, 124(sp)\n"
                     "csrr t0, mepc\n"
                     "sw   t0, 0(sp)\n"
                     "csrr t0, mstatus\n"
                     "sw   t0, 128(sp)\n"
                     /* preload the gap count into a saved scratch (t4) so the s2-store ->
                      * eviction distance is ALU-only and not perturbed by a memory read */
                     "la   t4, g_gap\n"
                     "lw   t4, 0(t4)\n"
                     /* ---- code=29: incoming architectural s2 vs expected (precise state) */
                     "la   t0, g_expected_s2\n"
                     "lw   t0, 0(t0)\n"
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
                     "sw   t0, 0(t1)\n"
                     "la   t1, g_last_actual\n"
                     "sw   s2, 0(t1)\n"
                     "1:\n"
                     /* ================= STORE UNDER TEST: sw s2, 72(sp) ================= */
                     "sw   s2, 72(sp)\n"
                     /* ---- tunable gap (ALU only) ---- */
                     "2:\n"
                     "beqz t4, 3f\n"
                     "addi t4, t4, -1\n"
                     "j    2b\n"
                     "3:\n"
                     /* ---- code=30: saved value BEFORE eviction (forwards from SQ if the
                      * store is still in flight; reads L1D otherwise) ---- */
                     "lw   t0, 72(sp)\n"
                     "la   t1, g_expected_s2\n"
                     "lw   t1, 0(t1)\n"
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
                     "sw   t1, 0(t2)\n"
                     "la   t2, g_last_actual\n"
                     "sw   t0, 0(t2)\n"
                     "4:\n"
                     /* ---- EVICT the saved s2 line: stride by the L1D size so every access
                      * maps to the SAME set with a different tag (direct-mapped), evicting
                      * and writing back the just-stored dirty frame line ---- */
                     "li   t1, 0x82000040\n" /* S2_LINE_BASE */
                     "li   t2, 0x20000\n"    /* L1D_STRIDE  */
                     "li   t3, 6\n"          /* N_EVICT     */
                     "5:\n"
                     "lw   t5, 0(t1)\n"
                     "add  t1, t1, t2\n"
                     "addi t3, t3, -1\n"
                     "bnez t3, 5b\n"
                     /* ============ LOAD UNDER TEST: lw s2, 72(sp) (post-evict) ==========
                      * line was evicted -> this misses -> refills from DDR -> sees whatever
                      * the eviction wrote back. code=31 if it differs (the targeted bug). */
                     "lw   t0, 72(sp)\n"
                     "la   t1, g_expected_s2\n"
                     "lw   t1, 0(t1)\n"
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
                     "sw   t1, 0(t2)\n"
                     "la   t2, g_last_actual\n"
                     "sw   t0, 0(t2)\n"
                     "6:\n"
                     /* ---- supporting witnesses on the same line: s3@76, s4@80 ---- */
                     "lw   t0, 76(sp)\n"
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
                     "sw   t1, 0(t2)\n"
                     "la   t2, g_last_actual\n"
                     "sw   t0, 0(t2)\n"
                     "7:\n"
                     "lw   t0, 80(sp)\n"
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
                     "sw   t1, 0(t2)\n"
                     "la   t2, g_last_actual\n"
                     "sw   t0, 0(t2)\n"
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
                     "la   t1, g_cont\n" /* fixed continuation -> robust to a bad mepc */
                     "lw   t0, 0(t1)\n"
                     "csrw mepc, t0\n"
                     "lw   t0, 128(sp)\n"
                     "csrw mstatus, t0\n"
                     /* ---- restore the frame (faithful trap exit) ---- */
                     "lw   ra, 4(sp)\n"
                     "lw   gp, 12(sp)\n"
                     "lw   tp, 16(sp)\n"
                     "lw   s0, 32(sp)\n"
                     "lw   s1, 36(sp)\n"
                     "lw   a0, 40(sp)\n"
                     "lw   a1, 44(sp)\n"
                     "lw   a2, 48(sp)\n"
                     "lw   a3, 52(sp)\n"
                     "lw   a4, 56(sp)\n"
                     "lw   a5, 60(sp)\n"
                     "lw   a6, 64(sp)\n"
                     "lw   a7, 68(sp)\n"
                     "lw   s2, 72(sp)\n"
                     "lw   s3, 76(sp)\n"
                     "lw   s4, 80(sp)\n"
                     "lw   s5, 84(sp)\n"
                     "lw   s6, 88(sp)\n"
                     "lw   s7, 92(sp)\n"
                     "lw   s8, 96(sp)\n"
                     "lw   s9, 100(sp)\n"
                     "lw   s10, 104(sp)\n"
                     "lw   s11, 108(sp)\n"
                     "lw   t3, 112(sp)\n"
                     "lw   t4, 116(sp)\n"
                     "lw   t5, 120(sp)\n"
                     "lw   t6, 124(sp)\n"
                     "lw   t0, 20(sp)\n"
                     "lw   t1, 24(sp)\n"
                     "lw   t2, 28(sp)\n"
                     "addi sp, sp, 144\n"
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
        /* preserve main's callee-saved s0..s11 (we clobber them with sentinels) */
        "la   t0, g_save_s\n"
        "sw   s0, 0(t0)\n"
        "sw   s1, 4(t0)\n"
        "sw   s2, 8(t0)\n"
        "sw   s3, 12(t0)\n"
        "sw   s4, 16(t0)\n"
        "sw   s5, 20(t0)\n"
        "sw   s6, 24(t0)\n"
        "sw   s7, 28(t0)\n"
        "sw   s8, 32(t0)\n"
        "sw   s9, 36(t0)\n"
        "sw   s10, 40(t0)\n"
        "sw   s11, 44(t0)\n"
        "la   t0, g_csp\n"
        "sw   sp, 0(t0)\n"
        "la   t0, g_cret\n"
        "sw   ra, 0(t0)\n"
        /* fixed continuation for the handler's mepc redirect */
        "la   t0, g_cont\n"
        "la   t1, 9f\n"
        "sw   t1, 0(t0)\n"
        "la   t0, g_ticks\n"
        "sw   x0, 0(t0)\n"
        /* faithful kernel stack pointer: handler does sw s2, 72(sp) */
        "li   sp, 0x82000090\n" /* FRAME_TOP */
        /* PRE-POISON the frame's s2 line so a non-landed save reads a stale
         * value; s2 slot gets 0x19999998 (the real name_to_int value). */
        "li   t0, 0x82000000\n" /* FRAME_BASE */
        "li   t1, 0x19999998\n"
        "sw   t1, 72(t0)\n"
        "li   t1, 0x19999993\n"
        "sw   t1, 76(t0)\n"
        "li   t1, 0x19999994\n"
        "sw   t1, 80(t0)\n"
        "li   t1, 0x19999995\n"
        "sw   t1, 84(t0)\n"
        "li   t1, 0x19999996\n"
        "sw   t1, 88(t0)\n"
        "li   t1, 0x19999997\n"
        "sw   t1, 92(t0)\n"
        /* COLD-MISS DRAIN STORE: a fresh DDR line, in flight when the IRQ hits */
        "la   t0, g_drain_addr\n"
        "lw   t0, 0(t0)\n"
        "li   t1, 0xD2A14000\n"
        "sw   t1, 0(t0)\n"
        /* ARM the timer: mtimecmp = mtime + margin */
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
        /* sentinels into s0..s11 (s2 = pointer-like expected) -- LAST */
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
        "lw   s0, 0(t0)\n"
        "lw   s1, 4(t0)\n"
        "lw   s2, 8(t0)\n"
        "lw   s3, 12(t0)\n"
        "lw   s4, 16(t0)\n"
        "lw   s5, 20(t0)\n"
        "lw   s6, 24(t0)\n"
        "lw   s7, 28(t0)\n"
        "lw   s8, 32(t0)\n"
        "lw   s9, 36(t0)\n"
        "lw   s10, 40(t0)\n"
        "lw   s11, 44(t0)\n"
        "la   t0, g_csp\n"
        "lw   sp, 0(t0)\n"
        "la   t0, g_cret\n"
        "lw   ra, 0(t0)\n"
        "ret\n");
}

int main(void)
{
    uint32_t n29 = 0, n30 = 0, n31 = 0, fired = 0, nofire = 0;
    uint32_t first_margin = 0xFFFFFFFFu;
    uint32_t first_code = 0, first_reg = 0, first_exp = 0, first_act = 0;

    uart_printf("\n=== drain trap-frame eviction test (Bug B @ pt_regs s2) ===\n");
    uart_printf("L1D=128KiB direct-mapped 32B lines; evict stride=0x%08x; frame@0x%08x s2@72\n",
                L1D_STRIDE,
                FRAME_BASE);

    g_expected_s2 = (uint32_t) &g_s2_target;
    set_trap_handler(&trapframe_irq_entry);
    csr_set(mie, MIE_MTIE);
    disable_interrupts();

    for (uint32_t margin = MARGIN_MIN; margin <= MARGIN_MAX; margin++) {
        g_timer_margin = margin;
        g_gap = margin & 15u;
        g_drain_addr = DRAIN_BASE + margin * DRAIN_LINE;
        g_expected_s2 = (uint32_t) &g_s2_target;
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
    uart_printf("expected_s2=%08x irq_count=%u\n", g_expected_s2, g_irq_count);

    if (n29 == 0u && n30 == 0u && n31 == 0u && fired > 0u) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("FAIL first_margin=%u code=%u reg=s%u expected=%08x actual=%08x\n",
                    first_margin,
                    first_code,
                    first_reg,
                    first_exp,
                    first_act);
        uart_printf("codes: 29=precise-state 30=save-not-visible 31=eviction/visibility\n");
        uart_printf("<<FAIL>>\n");
    }

    for (;;) {
    }
    return 0;
}
