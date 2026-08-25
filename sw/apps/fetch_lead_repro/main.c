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
 * Fetch-lead repro: a redirect into a cold cached line whose first bundle
 * advances by 6 ({32-bit, RVC}) and is followed by a 32-bit instruction at
 * the upper halfword of the served window's second word. If the front end
 * resumes from the line miss with its fetch lead collapsed (the same window
 * presented twice), the second presentation covers the new pc_reg through
 * the S+1 arm and the instruction's second half is taken from the wrong
 * word. Cold and warm calls are both checked.
 */

#include <stdint.h>

#include "mmio.h"

static void uart_putc(char c)
{
    UART_TX = (uint8_t) c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static void uart_puthex(unsigned long v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = (int) (sizeof(unsigned long) * 8) - 4; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

extern unsigned long lead_target_a(void);
extern unsigned long lead_target_b(void);

/* Absolute 64-bit pointers (data-side literals): the targets sit 2 GiB
 * above the BRAM caller, beyond any PC-relative call. */
static unsigned long (*volatile g_target_a)(void) = lead_target_a;
static unsigned long (*volatile g_target_b)(void) = lead_target_b;

int main(void)
{
    int ok = 1;
    for (int pass = 0; pass < 2; pass++) {
        unsigned long a0;
        unsigned long a1;
        __asm__ volatile("jalr ra, %2, 0\n mv %0, a0\n mv %1, a1"
                         : "=r"(a0), "=r"(a1)
                         : "r"(g_target_a)
                         : "a0", "a1", "ra", "memory");
        uart_puts(pass ? "warm A: " : "cold A: ");
        uart_puthex(a0);
        uart_puts(" ");
        uart_puthex(a1);
        uart_puts("\r\n");
        ok &= (a0 == 0x22 && a1 == 0x11);
        __asm__ volatile("jalr ra, %2, 0\n mv %0, a0\n mv %1, a1"
                         : "=r"(a0), "=r"(a1)
                         : "r"(g_target_b)
                         : "a0", "a1", "ra", "memory");
        uart_puts(pass ? "warm B: " : "cold B: ");
        uart_puthex(a0);
        uart_puts(" ");
        uart_puthex(a1);
        uart_puts("\r\n");
        ok &= (a0 == 0x44 && a1 == 0x33);
    }
    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
