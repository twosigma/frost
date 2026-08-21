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
 * Deterministic MRET/store-drain deadlock regression.
 *
 * The bug occurred when MRET reached the ROB head while a committed cached
 * store was draining. reorder_buffer.sv pulsed o_mret_start only on the
 * SERIAL_IDLE->SERIAL_MRET_EXEC transition, while trap_unit.sv accepted it only
 * if i_sq_committed_empty was high that cycle. There was no retry: mret_done
 * never asserted, SERIAL_MRET_EXEC held commit_stall, and MIE stayed disabled.
 *
 * Low-BRAM trap-stack tests missed this window because their stores drain in
 * about one cycle. This timer-independent test issues distinct-line cached-DDR
 * stores, then immediately MRETs to the loop top. Buggy RTL wedges on the first
 * MRET; fixed RTL waits for the drain and eventually prints <<PASS>>. The
 * optional FROST_MRET_DEADLOCK_PROBE also detects a stuck SERIAL_MRET_EXEC.
 *
 * Run in the registered Genesys2 shape (CACHED_HAS_L2=0), where cold writebacks
 * drain directly to DDR:
 *   ./scripts/frost.py cocotb mret_drain_deadlock
 * Before the fix, the first MRET wedges and the runner times out; afterward,
 * the test prints <<PASS>>.
 */

#include <stdint.h>

#include "trap.h"

/* Loaded .ddr_data, rather than crt0-touched .bss, makes the first stores cold
 * L1 misses with a full DDR writeback drain. The nonzero initializer emits it. */
__attribute__((section(".ddr_data"), aligned(64))) static volatile uint32_t g_ddr_buf[256] = {1};
/* A link-time data relocation reaches DDR where LP64 PCREL_HI20 cannot;
 * volatile prevents -O3 from folding it back. */
static volatile uint32_t *volatile g_ddr_buf_p = &g_ddr_buf[0];

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
 * a0 = cached/DDR buffer base, a1 = iteration count. Naked: explicit assembly
 * control flow (the MRET is the loop branch). Uses only caller-saved temporaries,
 * so the final `ret` returns to C with ra intact.
 */
__attribute__((naked)) static void mret_drain_loop(volatile uint32_t *ddr __attribute__((unused)),
                                                   uint32_t iters __attribute__((unused)))
{
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
    mret_drain_loop(g_ddr_buf_p, 16u);

    /* Only reached if every MRET completed (fixed RTL). On buggy RTL the first
     * MRET wedges the serializer and we never get here. */
    uart_puts("survived all MRETs: iters=");
    uart_hex(16u);
    uart_puts("\r\n<<PASS>>\r\n");
    for (;;) {
    }
    return 0;
}
