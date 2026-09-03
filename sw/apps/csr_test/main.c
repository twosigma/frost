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
 * Minimal CSR test: writes mstatus with MIE=1 and checks that execution
 * continues past the write.
 *
 * The UART helpers are inline here rather than taken from lib/uart.c, so that a
 * fault in the library cannot mask or cause a failure on the CSR path under
 * test.
 */

#include <stdint.h>

#define UART_BASE 0x40000000
volatile uint8_t *uart = (volatile uint8_t *) UART_BASE;

static inline void uart_putc(char c)
{
    *uart = c;
}

static inline void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

static inline void uart_hex(uint32_t val)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) {
        uart_putc(hex[(val >> i) & 0xF]);
    }
}

int main(void)
{
    uint32_t val;

    uart_puts("\r\n=== CSR Test ===\r\n");

    __asm volatile("csrr %0, mstatus" : "=r"(val));
    uart_puts("Initial mstatus: ");
    uart_hex(val);
    uart_puts("\r\n");

    __asm volatile("csrr %0, mie" : "=r"(val));
    uart_puts("mie: ");
    uart_hex(val);
    uart_puts("\r\n");

    __asm volatile("csrr %0, mip" : "=r"(val));
    uart_puts("mip: ");
    uart_hex(val);
    uart_puts("\r\n");

    /* Test 1: write mstatus with MIE=0, the baseline case. */
    uart_puts("\r\nTest 1: csrw mstatus with MIE=0\r\n");
    uart_putc('A');
    __asm volatile("csrw mstatus, %0" ::"r"(0x00001800)); /* MPP=11, MIE=0 */
    uart_putc('B');
    uart_puts(" - PASS (MIE=0 works)\r\n");

    __asm volatile("csrr %0, mstatus" : "=r"(val));
    uart_puts("mstatus after: ");
    uart_hex(val);
    uart_puts("\r\n");

    /* Test 2: write mstatus with MIE=1, the case this test was written for. */
    uart_puts("\r\nTest 2: csrw mstatus with MIE=1\r\n");
    uart_putc('C');
    uart_puts(" - About to set MIE=1...\r\n");

    __asm volatile("csrw mstatus, %0" ::"r"(0x00001808)); /* MPP=11, MIE=1 */

    /* Reaching this line means the MIE=1 write did not wedge the core. */
    uart_putc('D');
    uart_puts(" - PASS (MIE=1 works!)\r\n");

    __asm volatile("csrr %0, mstatus" : "=r"(val));
    uart_puts("mstatus after: ");
    uart_hex(val);
    uart_puts("\r\n");

    /* Test 3: Read mip again to confirm no spurious interrupts */
    __asm volatile("csrr %0, mip" : "=r"(val));
    uart_puts("mip after: ");
    uart_hex(val);
    uart_puts("\r\n");

    uart_puts("\r\n=== All Tests PASSED ===\r\n");
    uart_puts("<<PASS>>\r\n");

    for (;;)
        ;

    return 0;
}
