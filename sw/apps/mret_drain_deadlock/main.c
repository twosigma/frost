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
 * MRET-drain deadlock directed test (deterministic).
 *
 * Reproduces the residual flaky HANG seen booting no-MMU Linux on Genesys2:
 * the kernel intermittently wedges at the first idle/clocksource machine-timer
 * activity. Proven root cause (FROST RTL):
 *
 *   o_mret_start (reorder_buffer.sv) is a strict ONE-CYCLE pulse asserted only
 *   on the SERIAL_IDLE->SERIAL_MRET_EXEC cycle (unlike o_trap_pending, it has no
 *   SERIAL_*_WAIT sustaining term). trap_unit.sv take_mret requires
 *   i_sq_committed_empty IN THAT SAME CYCLE and has no retry. So if a committed
 *   store is still draining when an MRET reaches the ROB head, take_mret misses
 *   its only shot: mret_taken/mret_done never assert and the serializer wedges
 *   in SERIAL_MRET_EXEC forever (commit_stall=1 freezes the core). There is no
 *   escape -- the stuck MRET never restores MIE, so no later interrupt can flush
 *   the pipeline back to SERIAL_IDLE.
 *
 * Why the existing tests miss it: mtimer_stress / wfi_mepc_test /
 * mret_timer_resume_test all keep the handler stack in low BRAM (drains in ~1
 * cycle, so sq_committed_empty is already 1 when the MRET arrives) and never
 * create the "MRET reaches head while a committed CACHED/DDR store is mid-drain"
 * window. The real kernel saves/restores its trap frame on the cached DDR kernel
 * stack and idles (WFI) so the ROB empties and the restore MRET reaches head
 * almost immediately -- exactly this window.
 *
 * This test makes the window DETERMINISTIC and timer-independent: an M-mode loop
 * commits a backlog of distinct-line stores into the cached/DDR region (slow,
 * serialized write-back drains => sq_committed_empty held 0 for many cycles),
 * then immediately executes an MRET back to the loop top. On buggy RTL the very
 * first MRET wedges in SERIAL_MRET_EXEC and the loop never prints <<PASS>> (the
 * cocotb harness times out, and the optional FROST_MRET_DEADLOCK_PROBE asserts
 * on serial_state stuck in SERIAL_MRET_EXEC). On fixed RTL every MRET waits out
 * the drain, completes, and the loop prints <<PASS>>.
 *
 * The cocotb registration bakes in the Genesys2 cached shape (-GCACHED_HAS_L2=0,
 * L1 -> DDR direct), which is where the bug manifests on hardware and where a
 * cold cached-store write-back actually drains in sim, so the standard flow just
 * works:
 *   cd frost/tests; make clean; ./test_run_cocotb.py mret_drain_deadlock
 * BEFORE the cpu_ooo/reorder_buffer o_mret_start fix: the first MRET wedges in
 * SERIAL_MRET_EXEC and the harness times out. AFTER the fix: <<PASS>>.
 */

#include <stdint.h>

#include "trap.h"

/* Store buffer in the cached/DDR region (CACHED_BASE = 0x8000_0000). Placed in
 * a loaded .ddr_data section (like ddr_atomic_test): it lives in the behavioral
 * DDR model and -- unlike .bss -- is NOT touched by crt0, so the loop's first
 * stores to it MISS the L1 and take the full ~DDR_MODEL_LATENCY write-back drain
 * (fill from valid DDR, then write), reliably holding sq_committed_empty low
 * while the MRET reaches the ROB head. Non-zero initializer forces it loaded. */
__attribute__((section(".ddr_data"), aligned(64))) static volatile uint32_t g_ddr_buf[256] = {1};

static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}
static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}
static void uart_hex(uint32_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

/*
 * Unexpected-trap canary. Nothing in this test should trap (no interrupts are
 * enabled and every access is legal); if one does (e.g. an unexpected fault),
 * spin emitting 'T' so the failure is visible over UART instead of a silent
 * wild jump. Naked: entered as a raw trap handler.
 */
__attribute__((naked, aligned(4))) static void trap_canary(void)
{
    __asm__ volatile("li   t0, 0x40000000\n" /* UART_TX */
                     "li   t1, 'T'\n"
                     "1:\n"
                     "sb   t1, 0(t0)\n"
                     "j    1b\n");
}

/*
 * Commit a backlog of distinct-line cached/DDR stores, then MRET back to the top
 * of the loop -- `iters` times. The MRET is the loop back-edge, reached a handful
 * of cycles after the youngest store commits, while that store (and the rest of
 * the backlog) is still draining => the one-shot o_mret_start pulse coincides
 * with sq_committed_empty==0.
 *
 * a0 = cached/DDR buffer base, a1 = iteration count. Naked: hand-written control
 * flow (the MRET is the loop branch). Uses only caller-saved temporaries, so the
 * final `ret` returns to C with ra intact.
 */
__attribute__((naked)) static void mret_drain_loop(volatile uint32_t *ddr, uint32_t iters)
{
    (void) ddr;
    (void) iters;
    __asm__ volatile(
        /* MRET return target = loop top. Constant, so set mepc ONCE; MRET reads
         * mepc but never writes it. */
        "la   t1, 1f\n"
        "csrw mepc, t1\n"
        "li   t2, 0x1800\n" /* mstatus.MPP = M (0b11 << 11) mask */
        "1:\n"
        "beqz a1, 3f\n" /* done after `iters` MRETs */
        "addi a1, a1, -1\n"
        /* MPP=M re-set here (BEFORE the backlog), since MRET pops MPP to U. Kept
         * off the youngest-store->MRET critical path so NO instruction sits
         * between the last store and the MRET. */
        "csrs mstatus, t2\n"
        /* A few stores to distinct 32 B lines (64 B apart). Enough that the
         * youngest committed store is still in its (cached/DDR) write-back drain
         * when the MRET reaches the ROB head, but few enough not to overflow the
         * store queue (which would wedge on backpressure, not on the MRET). */
        "sw   a1, 0(a0)\n"
        "sw   a1, 64(a0)\n"
        "sw   a1, 128(a0)\n"
        "sw   a1, 192(a0)\n" /* youngest committed store; still draining at MRET */
        /* MRET immediately follows the youngest store: it reaches the ROB head a
         * couple cycles later, while that store (and the backlog) is still
         * draining => the one-shot o_mret_start pulse coincides with
         * sq_committed_empty==0. */
        "mret\n"
        "3:\n"
        "ret\n" ::
            : "t0", "t1", "t2", "a0", "a1", "memory");
}

int main(void)
{
    uart_puts("\r\n=== MRET drain-deadlock repro ===\r\n");

    /* Any unexpected trap becomes visible rather than a silent wild jump. */
    set_trap_handler(&trap_canary);

    /* No interrupts: this deadlock is purely the MRET<->store-drain handshake. */
    (void) disable_interrupts();

    uart_puts("running MRET/drain loop...\r\n");
    mret_drain_loop(g_ddr_buf, 16u);

    /* Only reached if every MRET completed (fixed RTL). On buggy RTL the first
     * MRET wedges the serializer and we never get here. */
    uart_puts("survived all MRETs: iters=");
    uart_hex(16u);
    uart_puts("\r\n<<PASS>>\r\n");
    for (;;) {
    }
    return 0;
}
