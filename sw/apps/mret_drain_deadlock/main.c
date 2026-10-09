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
 * MRET/store-drain deadlock regression.
 *
 * An MRET at the ROB head must wait for committed stores to drain, then
 * return. o_mret_start must be able to rise in SERIAL_MRET_EXEC; a pulse
 * only on entry would leave an MRET stuck if stores were still draining.
 *
 * Cached-DDR stores keep the drain active longer than low-BRAM stores.
 * MRET follows the youngest store and branches back to the loop top.
 * A lost MRET stops progress before <<PASS>>.
 *
 * The registry selects a small L2 and slow DDR to lengthen the drain:
 *   ./scripts/frost.py cocotb mret_drain_deadlock
 */

#include <stdint.h>

#include "trap.h"

/* Loaded .ddr_data leaves the first stores cold in L1D; crt0 would warm a
 * .bss buffer. A nonzero initializer emits the section. */
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
 * No trap is expected: interrupts are disabled and accesses are legal.
 * Emit 'T' repeatedly on an unexpected trap. Naked for direct trap entry.
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
 * Store to distinct cached-DDR lines, then MRET to the loop top, `iters`
 * times. The test requires stores to remain draining when MRET reaches the
 * ROB head, so MRET waits with sq_committed_empty low.
 *
 * a0 is the DDR buffer base; a1 is the iteration count. Naked because MRET
 * controls the loop. Only caller-saved temporaries are used; ra stays intact.
 */
__attribute__((naked)) static void mret_drain_loop(volatile uint32_t *ddr __attribute__((unused)),
                                                   uint32_t iters __attribute__((unused)))
{
    __asm__ volatile(
        /* Set the loop target once; MRET does not write mepc. */
        "la   t1, 1f\n"
        "csrw mepc, t1\n"
        "li   t2, 0x1800\n" /* mstatus.MPP = M (0b11 << 11) mask */
        "1:\n"
        "beqz a1, 3f\n" /* done after `iters` MRETs */
        "addi a1, a1, -1\n"
        /* MRET resets MPP to U. Restore MPP=M before the stores so MRET can
         * immediately follow the youngest store. */
        "csrs mstatus, t2\n"
        /* Use distinct 32-byte lines, 64 bytes apart. Keep the drain active
         * until MRET reaches the head without filling the store queue. */
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

    set_trap_handler(&trap_canary);

    /* Disable interrupts to isolate the MRET/store-drain handshake. */
    (void) disable_interrupts();

    uart_puts("running MRET/drain loop...\r\n");
    mret_drain_loop(g_ddr_buf_p, 16u);

    /* Reaching here requires every MRET to complete. */
    uart_puts("survived all MRETs: iters=");
    uart_hex(16u);
    uart_puts("\r\n<<PASS>>\r\n");
    for (;;) {
    }
    return 0;
}
