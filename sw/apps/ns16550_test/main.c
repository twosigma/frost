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
 * Test the 16550 register interface at 0x4000_1000. Its word stride matches
 * DTB reg-shift=2 and reg-io-width=4 for the Linux 8250 driver. Registers
 * alias the native UART TX/RX. Run console initialization, check readback
 * and transmit a banner. TEMT must stay low from a THR write until the byte
 * has been sent; THRE indicates FIFO space. Report through the native UART.
 */

#include <stdint.h>

#include "csr.h"

/* One UART bit time in CPU cycles (115200 baud). */
#define UART_BIT_CYCLES (FPGA_CPU_CLK_FREQ / 115200u)

/* Native UART for the PASS/FAIL marker. */
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

/* ns16550a registers, with word stride. */
#define NS(off) (*(volatile uint32_t *) (uintptr_t) (0x40001000u + (off)))
#define NS_THR NS(0x00)
#define NS_IER NS(0x04)
#define NS_IIR NS(0x08)
#define NS_FCR NS(0x08)
#define NS_LCR NS(0x0C)
#define NS_MCR NS(0x10)
#define NS_LSR NS(0x14)
#define NS_SCR NS(0x1C)
#define LSR_THRE 0x20u
#define LSR_TEMT 0x40u

static void ns_init(void)
{
    NS_IER = 0x00u; /* IRQs off: this test uses polled I/O */
    NS_LCR = 0x80u; /* DLAB = 1 */
    NS_THR = 0x01u; /* DLL (baud divisor low, ignored by FROST) */
    NS_IER = 0x00u; /* DLM (baud divisor high) */
    NS_LCR = 0x03u; /* DLAB = 0, 8N1 */
    NS_FCR = 0x07u; /* enable + clear RX/TX FIFOs */
    NS_MCR = 0x03u; /* DTR | RTS */
}
static void ns_putc(char c)
{
    while (!(NS_LSR & LSR_THRE)) {
    }
    NS_THR = (uint8_t) c;
}

/* Poll until the transmitter is empty. A frame is ten bit times, far below
 * the poll bound. */
static uint32_t wait_temt(void)
{
    uint32_t lsr = NS_LSR;
    for (int i = 0; i < 200000 && !(lsr & LSR_TEMT); i++)
        lsr = NS_LSR;
    return lsr;
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
    ok &= ((NS_LSR & 0x60u) == 0x60u); /* THRE | TEMT: nothing sent yet */
    ok &= ((NS_IIR & 0x01u) == 0x01u); /* no interrupt pending */

    /* TEMT covers the byte from the THR write until its stop bit has been
     * sent, at least nine bit times later; THRE stays set, since the FIFO
     * has room. */
    uint64_t t0 = rdcycle64();
    NS_THR = (uint8_t) '[';
    ok &= ((NS_LSR & 0x60u) == LSR_THRE);
    ok &= ((wait_temt() & 0x60u) == 0x60u);
    ok &= ((rdcycle64() - t0) >= 9u * UART_BIT_CYCLES);

    NS_SCR = 0xA5u; /* scratch register is read/write */
    ok &= ((NS_SCR & 0xFFu) == 0xA5u);
    NS_SCR = 0x5Au;
    ok &= ((NS_SCR & 0xFFu) == 0x5Au);

    /* Transmit the rest of the banner through the 16550 interface. */
    ns_puts("ns16550 face: TX path OK]\r\n");

    n_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
