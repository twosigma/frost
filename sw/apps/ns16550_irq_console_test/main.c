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
 * ns16550 interrupt-driven console test. THRE drives PLIC source 1. Each
 * handler invocation claims, sends one byte and completes; the asserted
 * level triggers the next invocation. After the message, one final claim
 * disables IER. Main then disables interrupts, checks the byte and claim
 * counts, and reports through the native UART TX register.
 */

#include <stdint.h>

#include "trap.h"

static void uart_putc(char c)
{
    while (!(UART_TX_STATUS & 1u))
        ;
    UART_TX = (uint8_t) c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

#define REG32(a) (*(volatile uint32_t *) (a))
#define PLIC_BASE 0x44000000UL
#define PLIC_PRIO1 REG32(PLIC_BASE + 4ul)
#define PLIC_EN_M REG32(PLIC_BASE + 0x2000ul)
#define PLIC_THR_M REG32(PLIC_BASE + 0x200000ul)
#define PLIC_CLAIM_M REG32(PLIC_BASE + 0x200004ul)
#define NS16550_THR REG32(0x40001000UL)
#define NS16550_IER REG32(0x40001004UL)

/* Referenced only from the naked handler's asm, so it needs the used attribute. */
static const char g_msg[] __attribute__((used)) =
    "irq-console: the quick brown fox jumps over the lazy dog\r\n";
static volatile uint32_t g_sent;
static volatile uint32_t g_claims;
static volatile uint32_t g_bad_claim;

/* Send one byte per claim while THRE indicates FIFO space. At the end of
 * the message, disable IER before completing to stop further interrupts. */
__attribute__((naked, aligned(4))) static void m_irq_handler(void)
{
    __asm__ volatile("addi sp, sp, -32\n"
                     "sd   t0, 0(sp)\n"
                     "sd   t1, 8(sp)\n"
                     "sd   t2, 16(sp)\n"
                     "sd   t3, 24(sp)\n"
                     "li   t1, 0x44200004\n"
                     "lw   t0, 0(t1)\n" /* claim */
                     "la   t2, g_claims\n"
                     "lw   t3, 0(t2)\n"
                     "addiw t3, t3, 1\n"
                     "sw   t3, 0(t2)\n"
                     "li   t3, 1\n"
                     "beq  t0, t3, 1f\n"
                     "la   t2, g_bad_claim\n" /* claim != 1: record and bail */
                     "sw   t0, 0(t2)\n"
                     "j    2f\n"
                     "1:\n"
                     "la   t2, g_sent\n"
                     "lw   t3, 0(t2)\n"
                     "la   t2, g_msg\n"
                     "add  t2, t2, t3\n"
                     "lbu  t2, 0(t2)\n"
                     "beqz t2, 3f\n" /* end of message: silence IER */
                     "li   t3, 0x40001000\n"
                     "sw   t2, 0(t3)\n" /* THR <- byte, sent from the handler */
                     "la   t2, g_sent\n"
                     "lw   t3, 0(t2)\n"
                     "addiw t3, t3, 1\n"
                     "sw   t3, 0(t2)\n"
                     "j    2f\n"
                     "3:\n"
                     "li   t3, 0x40001004\n"
                     "sw   zero, 0(t3)\n" /* IER = 0: drop the level for good */
                     "2:\n"
                     "sw   t0, 0(t1)\n" /* complete */
                     "ld   t0, 0(sp)\n"
                     "ld   t1, 8(sp)\n"
                     "ld   t2, 16(sp)\n"
                     "ld   t3, 24(sp)\n"
                     "addi sp, sp, 32\n"
                     "mret\n");
}

int main(void)
{
    const uint32_t msg_len = (uint32_t) (sizeof(g_msg) - 1);

    set_trap_handler(&m_irq_handler);
    g_sent = 0;
    g_claims = 0;
    g_bad_claim = 0;

    PLIC_PRIO1 = 1;
    PLIC_THR_M = 0;
    PLIC_EN_M = 0x2;   /* source 1 in context M */
    NS16550_IER = 0x2; /* THRE interrupt: raised while the TX FIFO has room */
    enable_external_interrupt();
    enable_interrupts();

    /* Wait for the handler to finish the message and disable IER. */
    for (int i = 0; i < 4000000 && (g_sent < msg_len || NS16550_IER != 0); i++)
        __asm__ volatile("nop");

    disable_interrupts();
    disable_external_interrupt();
    PLIC_EN_M = 0;

    /* One claim per byte plus the final silencing claim. */
    int ok = (g_sent == msg_len) && (g_bad_claim == 0) && (g_claims == msg_len + 1);
    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
