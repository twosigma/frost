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
 * An MRET that reaches the ROB head while committed cached stores are still
 * draining must wait for the drain and then return. The trap unit takes an
 * xRET only in a cycle where committed stores have drained, so the ROB waits
 * in SERIAL_MRET_EXEC and raises o_mret_start once they have. If o_mret_start
 * could rise only on entry, an MRET that arrived during a drain would never
 * be taken: the serializer would stay in SERIAL_MRET_EXEC with commit stalled
 * and MIE never restored.
 *
 * Stores to low BRAM drain in about one cycle, too fast to open this window.
 * This test needs no timer: it issues cached-DDR stores to distinct lines and
 * MRETs back to the loop top right after the youngest one. A lost MRET wedges
 * the core on the first iteration and the runner times out; otherwise the
 * test prints <<PASS>>.
 *
 * The test registry runs it with a small L2 and slow DDR to lengthen the
 * drains:
 *   ./scripts/frost.py cocotb mret_drain_deadlock
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
 * Unexpected-trap canary. No interrupts are enabled and every access is legal,
 * so nothing here should trap. If something does, spin emitting 'T' so the
 * failure shows on the UART instead of a silent wild jump. Naked: entered as a
 * raw trap handler.
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
 * Commit a backlog of stores to distinct cached/DDR lines, then MRET back to
 * the top of the loop, `iters` times. The MRET is the loop back-edge and
 * reaches the ROB head a few cycles after the youngest store commits, while
 * that store and the rest of the backlog are still draining, so it must wait
 * there with sq_committed_empty low.
 *
 * a0 = cached/DDR buffer base, a1 = iteration count. Naked, because the MRET
 * is the loop branch and the control flow has to stay in assembly. Uses only
 * caller-saved temporaries, so the final `ret` returns to C with ra intact.
 */
__attribute__((naked)) static void mret_drain_loop(volatile uint32_t *ddr __attribute__((unused)),
                                                   uint32_t iters __attribute__((unused)))
{
    __asm__ volatile(
        /* The MRET target is the loop top, a constant. Set mepc once: MRET reads
         * mepc and never writes it. */
        "la   t1, 1f\n"
        "csrw mepc, t1\n"
        "li   t2, 0x1800\n" /* mstatus.MPP = M (0b11 << 11) mask */
        "1:\n"
        "beqz a1, 3f\n" /* done after `iters` MRETs */
        "addi a1, a1, -1\n"
        /* MRET pops MPP to U, so set MPP=M again here, before the backlog. That
         * keeps it off the youngest-store->MRET path: no instruction sits
         * between the last store and the MRET. */
        "csrs mstatus, t2\n"
        /* A few stores to distinct 32 B lines (64 B apart). Enough that the
         * youngest committed store is still in its (cached/DDR) write-back drain
         * when the MRET reaches the ROB head, but few enough not to overflow the
         * store queue (which would stall on backpressure, not at the MRET). */
        "sw   a1, 0(a0)\n"
        "sw   a1, 64(a0)\n"
        "sw   a1, 128(a0)\n"
        "sw   a1, 192(a0)\n" /* youngest committed store; still draining at MRET */
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

    /* Reached only if every MRET completed. A lost MRET wedges the serializer
     * on the first iteration and this line never prints. */
    uart_puts("survived all MRETs: iters=");
    uart_hex(16u);
    uart_puts("\r\n<<PASS>>\r\n");
    for (;;) {
    }
    return 0;
}
