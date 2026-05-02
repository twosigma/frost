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

#ifndef UART_H
#define UART_H

#include <stddef.h>
#include <stdint.h>

/* UART (Universal Asynchronous Receiver/Transmitter) driver for console I/O */

#ifndef UART_PRINTF_ENABLE_FLOAT
#define UART_PRINTF_ENABLE_FLOAT 0
#endif

/* ========================================================================= */
/* UART Transmit Functions                                                   */
/* ========================================================================= */

/* Transmit a single character over UART */
void uart_putchar(char c);

/* Check whether the UART transmitter can accept a byte */
int uart_tx_ready(void);

/* Transmit a null-terminated string over UART */
void uart_puts(const char *s);

/* Minimal printf-style formatter for UART output
 * Supported format specifiers:
 *   %c - character
 *   %s - string
 *   %d, %ld, %lld - signed decimal
 *   %u, %lu, %llu - unsigned decimal
 *   %x, %X - hexadecimal (lowercase/uppercase)
 *   %f - floating point (default precision 6, supports %.Nf) when enabled
 *   %% - literal percent sign
 * Supports field width (e.g., %8d) and zero-padding (e.g., %04x)
 */
void uart_printf(const char *fmt, ...);

/* ========================================================================= */
/* UART Receive Functions                                                    */
/* ========================================================================= */

/* Check if received data is available in the RX buffer
 * Returns: 1 if data available, 0 if buffer empty */
int uart_rx_available(void);

/* Receive a single character from UART (blocking)
 * Waits until data is available, then returns the received byte */
char uart_getchar(void);

/* Receive a single character from UART (non-blocking)
 * Returns: received byte if available, -1 if no data available */
int uart_getchar_nonblocking(void);

/* Read a line from UART into buffer (blocking)
 * Reads characters until newline ('\n' or '\r') or buffer is full.
 * The newline character is NOT included in the buffer.
 * Buffer is always null-terminated.
 * Echoes characters back to UART as they are typed.
 * Supports backspace for editing.
 * Parameters:
 *   buf - destination buffer
 *   maxlen - maximum number of characters to read (including null terminator)
 * Returns: number of characters read (not including null terminator) */
size_t uart_getline(char *buf, size_t maxlen);

#endif /* UART_H */
