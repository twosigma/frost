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
 * ns16550a UART face directed test (Increment 1 of the no-MMU Linux glue).
 *
 * FROST presents a word-stride 16550 register face at 0x4000_1000 (DTB
 * reg-shift=2, reg-io-width=4) that aliases the native UART TX/RX, so a stock
 * Linux 8250 console driver can drive it. This test runs the 8250 init dance
 * (DLAB/baud, 8N1, FIFO, MCR), checks the register file and TX-ready status,
 * and transmits a banner THROUGH the face (which must appear on the UART TX
 * line). PASS/FAIL is emitted over the known-good native UART so the verdict
 * is independent of the face under test.
 */

#include <stdint.h>

/* Native FROST UART (known-good) -- used only for the PASS/FAIL marker. */
#define NATIVE_TX (*(volatile uint32_t *) 0x40000000u)
#define NATIVE_TX_ST (*(volatile uint32_t *) 0x40000028u)
static void n_putc(char c)
{
    while (!(NATIVE_TX_ST & 1u)) {
    }
    NATIVE_TX = (uint8_t) c;
}
static void n_puts(const char *s)
{
    while (*s)
        n_putc(*s++);
}

/* ns16550a face @ 0x4000_1000, word stride. */
#define NS(off) (*(volatile uint32_t *) (uintptr_t) (0x40001000u + (off)))
#define NS_THR NS(0x00)
#define NS_IER NS(0x04)
#define NS_IIR NS(0x08)
#define NS_FCR NS(0x08)
#define NS_LCR NS(0x0C)
#define NS_MCR NS(0x10)
#define NS_LSR NS(0x14)
#define NS_SCR NS(0x1C)

static void ns_init(void)
{
    NS_IER = 0x00u; /* polled (no interrupts wired) */
    NS_LCR = 0x80u; /* DLAB = 1 */
    NS_THR = 0x01u; /* DLL (baud divisor low) -- FROST ignores the divisor */
    NS_IER = 0x00u; /* DLM (baud divisor high) */
    NS_LCR = 0x03u; /* DLAB = 0, 8N1 */
    NS_FCR = 0x07u; /* enable + clear RX/TX FIFOs */
    NS_MCR = 0x03u; /* DTR | RTS */
}
static void ns_putc(char c)
{
    while (!(NS_LSR & 0x20u)) { /* wait for THRE */
    }
    NS_THR = (uint8_t) c;
}
static void ns_puts(const char *s)
{
    while (*s)
        ns_putc(*s++);
}

int main(void)
{
    int ok = 1;

    ns_init();
    ok &= ((NS_LCR & 0xFFu) == 0x03u); /* LCR readback: 8N1, DLAB clear */
    ok &= ((NS_LSR & 0x60u) == 0x60u); /* THRE | TEMT set (TX ready) */
    ok &= ((NS_IIR & 0x01u) == 0x01u); /* no interrupt pending */

    NS_SCR = 0xA5u; /* scratch register is read/write */
    ok &= ((NS_SCR & 0xFFu) == 0xA5u);
    NS_SCR = 0x5Au;
    ok &= ((NS_SCR & 0xFFu) == 0x5Au);

    /* Transmit a banner THROUGH the ns16550 face; it must reach the UART TX. */
    ns_puts("[ns16550 face: TX path OK]\r\n");

    n_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
