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
 * ns16550 interrupt-driven console test (Phase 3 M6, plan D11's console
 * item). The entire message is transmitted from the external-interrupt
 * handler. THRE raises PLIC source 1; the handler claims, writes exactly
 * one byte to the THR, completes, and returns. The next THRE level
 * re-raises through the level gateway for the following byte. Main only
 * arms the machinery and waits, then checks that every byte was sent from
 * the handler and that the claim count matches. The verdict (<<PASS>> /
 * <<FAIL>>) goes out over the native UART TX register after interrupts
 * are off.
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

/* Naked M external-interrupt handler. Claim, and if bytes remain, send one
 * through the THR and complete. The still-idle transmitter re-raises for
 * the next byte. When the message is done, disable IER before completing
 * so the level drops for good. */
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
    NS16550_IER = 0x2; /* THRE interrupt: raises whenever TX is idle */
    enable_external_interrupt();
    enable_interrupts();

    /* The whole message transmits from the handler; wait it out. */
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
