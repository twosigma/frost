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
 * Memory error unit readback, for the X3: the DDR4 controller's ECC reader
 * (boards/x3/x3_ecc_reader.sv) is active and keeps polling, and nothing
 * reports a memory error while the test writes and reads back DDR_BYTES of
 * DDR, twice the L2, so the traffic reaches the controller. The hardware
 * regression runs it; its closing ddr_ecc stage checks the controller's own
 * registers over JTAG.
 *
 * In simulation the bench plays the reader (test_real_program.py,
 * EccReportDriver) and the registry passes a smaller DDR_BYTES.
 */

#include <stdint.h>

#include "memory_error.h"

#ifndef DDR_BYTES
#define DDR_BYTES (4ul << 20)
#endif
#define DDR_BUFFER 0x81000000ul
/* Polls to wait for; the X3 reader polls about every millisecond. */
#define POLLS_TO_SEE 3u
#define WAIT_LOOPS 20000000

static void uart_puts(const char *s)
{
    while (*s)
        UART_TX = (uint8_t) *s++;
}

static void uart_hex(unsigned long v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_puts("0x");
    for (int i = (int) (sizeof(unsigned long) * 8) - 4; i >= 0; i -= 4)
        UART_TX = (uint8_t) hex[(v >> i) & 0xF];
}

static int g_ok = 1;

static void check(const char *name, unsigned long got, unsigned long want)
{
    uart_puts(got == want ? "[PASS] " : "[FAIL] ");
    uart_puts(name);
    uart_puts(" got=");
    uart_hex(got);
    uart_puts(" want=");
    uart_hex(want);
    uart_puts("\r\n");
    if (got != want)
        g_ok = 0;
}

static unsigned long pattern(unsigned long i)
{
    return (i * 0x9E3779B97F4A7C15ul) ^ (i << 7);
}

int main(void)
{
    uart_puts("\r\n=== Memory error unit readback ===\r\n");

    uint32_t caps = memory_error_read32(MEMORY_ERROR_CAPS);
    check("caps-version", MEMORY_ERROR_CAPS_VERSION(caps), 1);
    check("ecc-reader-active", caps & MEMORY_ERROR_CAPS_ECC, MEMORY_ERROR_CAPS_ECC);
    uint32_t polls_before = memory_error_read32(MEMORY_ERROR_ECC_POLLS);

    volatile unsigned long *buffer = (volatile unsigned long *) DDR_BUFFER;
    unsigned long words = DDR_BYTES / sizeof(unsigned long);
    for (unsigned long i = 0; i < words; i++)
        buffer[i] = pattern(i);
    unsigned long mismatches = 0;
    for (unsigned long i = 0; i < words; i++) {
        if (buffer[i] != pattern(i))
            mismatches++;
    }
    check("ddr-readback-mismatches", mismatches, 0);

    uint32_t polls = polls_before;
    for (int i = 0; i < WAIT_LOOPS && polls - polls_before < POLLS_TO_SEE; i++)
        polls = memory_error_read32(MEMORY_ERROR_ECC_POLLS);
    check("reader-polling", polls - polls_before >= POLLS_TO_SEE, 1);

    check("status", memory_error_read32(MEMORY_ERROR_STATUS), 0);
    check("ce-count", memory_error_read32(MEMORY_ERROR_CE_COUNT), 0);
    check("ue-count", memory_error_read32(MEMORY_ERROR_UE_COUNT), 0);
    check("axi-read-errors", memory_error_read32(MEMORY_ERROR_AXI_RD_ERRS), 0);
    check("axi-write-errors", memory_error_read32(MEMORY_ERROR_AXI_WR_ERRS), 0);
    uart_puts("ECC polls during the test: ");
    uart_hex(polls - polls_before);
    uart_puts("\r\n");

    uart_puts(g_ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
    return 0;
}
