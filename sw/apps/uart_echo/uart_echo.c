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

/**
 * UART Echo - Demonstrates UART receive functionality
 *
 * This program exercises the UART RX hardware by:
 *   1. Echoing each character as it's typed
 *   2. Reading complete lines and printing them back
 *   3. Demonstrating non-blocking character reception
 *
 * Use a serial terminal (e.g., minicom, screen, picocom) at 115200 baud
 * to interact with this program.
 */

#include <stdint.h>

#include "string.h"
#include "uart.h"

int main(void)
{
    char line_buffer[128];

    /* Print welcome banner */
    uart_puts("\n");
    uart_puts("========================================\n");
    uart_puts("  FROST RISC-V UART Echo Demo\n");
    uart_puts("========================================\n");
    uart_puts("\n");
    uart_puts("This program demonstrates UART RX functionality.\n");
    uart_puts("Type characters and they will be echoed back.\n");
    uart_puts("Press Enter to submit a line.\n");
    uart_puts("Type 'help' for available commands.\n");
    uart_puts("\n");

    /* Main command loop */
    for (;;) {
        uart_puts("frost> ");

        /* Read a line of input (with echo and backspace support) */
        size_t len = uart_getline(line_buffer, sizeof(line_buffer));

        if (len == 0) {
            /* Empty line - just print a new prompt */
            continue;
        }

        /* Process commands */
        if (strcmp(line_buffer, "help") == 0) {
            uart_puts("\nAvailable commands:\n");
            uart_puts("  help     - Show this help message\n");
            uart_puts("  echo     - Enter character echo mode (Ctrl+C to exit)\n");
            uart_puts("  hex      - Enter hex dump mode (Ctrl+C to exit)\n");
            uart_puts("  count    - Count received characters for 10 seconds\n");
            uart_puts("  info     - Show UART status information\n");
            uart_puts("\n");
        } else if (strcmp(line_buffer, "echo") == 0) {
            uart_puts("\nEcho mode: Type characters to see them echoed.\n");
            uart_puts("Press Ctrl+C (0x03) to exit.\n\n");

            for (;;) {
                char c = uart_getchar();
                if (c == 0x03) { /* Ctrl+C */
                    uart_puts("\n[Exiting echo mode]\n\n");
                    break;
                }
                /* Echo the character */
                uart_putchar(c);
                /* Also show newline after carriage return for readability */
                if (c == '\r')
                    uart_putchar('\n');
            }
        } else if (strcmp(line_buffer, "hex") == 0) {
            uart_puts("\nHex dump mode: Shows hex value of each character.\n");
            uart_puts("Press Ctrl+C (0x03) to exit.\n\n");

            for (;;) {
                char c = uart_getchar();
                if (c == 0x03) { /* Ctrl+C */
                    uart_puts("\n[Exiting hex mode]\n\n");
                    break;
                }
                /* Print character and its hex value */
                uart_printf("'%c' = 0x%02x\n",
                            (c >= 32 && c < 127) ? c : '.',
                            (unsigned int) (unsigned char) c);
            }
        } else if (strcmp(line_buffer, "count") == 0) {
            uart_puts("\nCounting mode: Type as fast as you can!\n");
            uart_puts("Counting characters for approximately 10 seconds...\n\n");

            uint32_t count = 0;
            uint32_t loops = 0;
            const uint32_t max_loops = 100000000; /* Approximate 10 seconds */

            while (loops < max_loops) {
                int c = uart_getchar_nonblocking();
                if (c >= 0) {
                    count++;
                    if (c == 0x03) { /* Ctrl+C - exit early */
                        break;
                    }
                }
                loops++;
            }

            uart_printf("\nReceived %u characters.\n\n", count);
        } else if (strcmp(line_buffer, "info") == 0) {
            uart_puts("\nUART Status:\n");
            uart_printf("  RX data available: %s\n", uart_rx_available() ? "yes" : "no");
            uart_puts("  Baud rate: 115200\n");
            uart_puts("  Format: 8N1 (8 data bits, no parity, 1 stop bit)\n");
            uart_puts("\n");
        } else {
            uart_printf("\nYou typed: \"%s\" (%u chars)\n\n", line_buffer, (unsigned int) len);
        }
    }
}
