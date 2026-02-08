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
 * UART Driver (uart.c)
 *
 * Serial console output driver with printf-style formatting for bare-metal use.
 * Provides single-character, string, and formatted output over a memory-mapped
 * UART transmit register.
 *
 * Features:
 *   - Automatic CR+LF line ending conversion
 *   - Printf format specifiers: %c, %s, %d, %u, %x, %X, %ld, %lu, %lld, %llu, %f
 *   - Field width and zero-padding support (e.g., %08x, %4d)
 */

#include "uart.h"
#include "mmio.h"

#include <stdarg.h>

/* ------------------------------------------------------------------------- */
/* basic helpers                                                             */
/* ------------------------------------------------------------------------- */

void uart_putchar(char c)
{
    /* Terminals that expect CR+LF line endings need CR (carriage return) before LF (line feed) */
    if (c == '\n')
        UART_TX = (uint8_t) '\r';
    UART_TX = (uint8_t) c;
}

void uart_puts(const char *s)
{
    /* Transmit each character until null terminator */
    while (*s)
        uart_putchar(*s++);
}

/* Generic unsigned decimal printer - works for all unsigned integer types */
static void uart_put_unsigned_decimal(unsigned long long val, int max_digits)
{
    char buf[20]; /* Buffer fits max value: 18,446,744,073,709,551,615 */
    int count = 0;

    if (val == 0) {
        uart_putchar('0');
        return;
    }

    /* Extract digits in reverse order (least significant first) */
    while (val && count < max_digits && count < (int) sizeof(buf)) {
        buf[count++] = (char) ('0' + (val % 10));
        val /= 10;
    }

    /* Print digits in forward order (most significant first) */
    while (--count >= 0)
        uart_putchar(buf[count]);
}

/* Wrapper functions for specific unsigned integer types */
static inline void uart_put_uint(unsigned int value)
{
    uart_put_unsigned_decimal(value, 10); /* Maximum 10 digits for 32-bit unsigned */
}

static inline void uart_put_ulong(unsigned long value)
{
    uart_put_unsigned_decimal(value, 20); /* Maximum 20 digits for 64-bit unsigned */
}

static inline void uart_put_ulonglong(unsigned long long value)
{
    uart_put_unsigned_decimal(value, 20); /* Maximum 20 digits for 64-bit unsigned */
}

/* Print hexadecimal value with specified number of digits */
static void uart_put_hex(unsigned int val, int ndigits, int uppercase)
{
    char buf[8];
    int i = 0;

    /* Extract hex digits in reverse order (least significant first) */
    do {
        unsigned d = val & 0xF;
        buf[i++] = (d < 10) ? ('0' + d) : (uppercase ? 'A' : 'a') + d - 10;
        val >>= 4;
    } while (val && i < 8);

    /* Pad with zeros to reach requested number of digits */
    while (i < ndigits)
        buf[i++] = '0';

    /* Print digits in forward order (most significant first) */
    while (i--)
        uart_putchar(buf[i]);
}

/* Generic signed decimal printer - handles negative values */
static void uart_put_signed_decimal(long long val, int max_digits)
{
    if (val < 0) {
        uart_putchar('-');
        uart_put_unsigned_decimal((unsigned long long) (-(val + 1LL)) + 1ULL, max_digits);
        return;
    }
    uart_put_unsigned_decimal((unsigned long long) val, max_digits);
}

static inline void uart_put_int(int value)
{
    uart_put_signed_decimal(value, 10); /* Maximum 10 digits for 32-bit signed */
}

static inline void uart_put_longlong(long long value)
{
    uart_put_signed_decimal(value, 20); /* Maximum 20 digits for 64-bit signed */
}

#if UART_PRINTF_ENABLE_FLOAT
static void uart_put_float(double value, int precision)
{
    float fval = (float) value;
    if (fval != fval) {
        uart_puts("nan");
        return;
    }
    if (fval > 3.4028235e38f) {
        uart_puts("inf");
        return;
    }
    if (fval < -3.4028235e38f) {
        uart_puts("-inf");
        return;
    }

    if (precision < 0)
        precision = 6;

    if (fval < 0.0f) {
        uart_putchar('-');
        fval = -fval;
    }

    unsigned long long int_part = (unsigned long long) fval;
    uart_put_unsigned_decimal(int_part, 20);

    if (precision == 0)
        return;

    uart_putchar('.');
    float frac = fval - (float) int_part;
    if (frac < 0.0f)
        frac = 0.0f;
    for (int i = 0; i < precision; ++i) {
        frac *= 10.0f;
        int digit = (int) frac;
        uart_putchar((char) ('0' + digit));
        frac -= (float) digit;
    }
}
#endif

/* ------------------------------------------------------------------------- */
/* very small printf (now understands %f)                                    */
/* ------------------------------------------------------------------------- */
void uart_printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);

    /* Process format string character by character */
    for (const char *p = fmt; *p; ++p) {
        if (*p != '%') {
            /* Not a format specifier - print literal character */
            uart_putchar(*p);
            continue;
        }

        /* Parse format specifier flags and width */
        int zero_pad = 0, width = 0;
        int precision = -1;

        if (*++p == '0') {
            /* Leading '0' flag - pad with zeros instead of spaces */
            zero_pad = 1;
            ++p;
        }

        /* Parse field width (e.g., %8d, %04x) */
        while (*p >= '0' && *p <= '9') {
            width = width * 10 + (*p - '0');
            ++p;
        }

        /* Parse optional precision (e.g., %.3f) */
        if (*p == '.') {
            precision = 0;
            ++p;
            while (*p >= '0' && *p <= '9') {
                precision = precision * 10 + (*p - '0');
                ++p;
            }
        }

        /* Limit field width to 8 digits maximum.
           This matches the buffer size in uart_put_hex() and is sufficient
           for 32-bit values (0xFFFFFFFF = 8 hex digits). Larger widths would require
           larger stack buffers and aren't needed for this embedded printf. */
        if (width > 8)
            width = 8;
        if (width == 0)
            width = 1;

        /* Parse optional length modifiers ('l' for long, 'll' for long long) */
        int is_long = 0;
        int is_longlong = 0;
        if (*p == 'l') {
            /* %lu / %ld / %lx / %lX */
            is_long = 1;
            ++p;
            if (*p == 'l') {
                /* %llu / %lld - long long variant */
                is_longlong = 1;
                is_long = 0;
                ++p;
            }
        }

        /* Process conversion specifier */
        switch (*p) {
            case 'c': {
                /* %c - print single character */
                char ch = (char) va_arg(args, int);
                uart_putchar(ch);
                break;
            }

            case 's': {
                /* %s - print null-terminated string */
                uart_puts(va_arg(args, const char *));
                break;
            }

            case 'd': {
                /* %d / %ld / %lld - signed decimal integer */
                if (is_longlong)
                    uart_put_longlong(va_arg(args, long long));
                else if (is_long)
                    uart_put_int((int) va_arg(args, long));
                else
                    uart_put_int(va_arg(args, int));
                break;
            }

            case 'u': {
                /* %u / %lu / %llu - unsigned decimal integer */
                if (is_longlong)
                    uart_put_ulonglong(va_arg(args, unsigned long long));
                else if (is_long)
                    uart_put_ulong(va_arg(args, unsigned long));
                else
                    uart_put_uint(va_arg(args, unsigned int));
                break;
            }

            case 'x': /* %x / %X - hexadecimal (32-bit only) */
            case 'X': {
                unsigned int hexval = va_arg(args, unsigned int);

                /* Determine minimum number of hex digits needed for this value */
                unsigned tmp = hexval;
                int ndigits = 1;
                while (tmp >>= 4)
                    ++ndigits;

                /* Use field width if larger than needed digits */
                if (width < ndigits)
                    width = ndigits;
                int padding = width - ndigits;

                /* Print padding (zeros or spaces depending on flag) */
                for (int j = 0; j < padding; ++j)
                    uart_putchar(zero_pad ? '0' : ' ');

                /* Print actual hex value (uppercase if %X, lowercase if %x) */
                uart_put_hex(hexval, ndigits, *p == 'X');
                break;
            }

            case 'f': {
#if UART_PRINTF_ENABLE_FLOAT
                /* %f - floating point (double promoted) */
                uart_put_float(va_arg(args, double), precision);
#else
                uart_putchar('%');
                uart_putchar('f');
#endif
                break;
            }

            case '%': {
                /* %% - print literal percent sign */
                uart_putchar('%');
                break;
            }

            default: {
                /* Unknown format specifier - print it literally */
                uart_putchar('%');
                uart_putchar(*p);
                break;
            }
        }
    }
    va_end(args);
}

/* ------------------------------------------------------------------------- */
/* UART Receive Functions                                                    */
/* ------------------------------------------------------------------------- */

int uart_rx_available(void)
{
    /* Status register bit 0 indicates data available */
    return (UART_RX_STATUS & 1) != 0;
}

char uart_getchar(void)
{
    /* Wait until data is available */
    while (!uart_rx_available())
        ;
    /* Reading the data register consumes the byte from the FIFO */
    return (char) UART_RX_DATA;
}

int uart_getchar_nonblocking(void)
{
    if (!uart_rx_available())
        return -1;
    return (int) UART_RX_DATA;
}

size_t uart_getline(char *buf, size_t maxlen)
{
    size_t pos = 0;

    if (maxlen == 0)
        return 0;

    /* Reserve space for null terminator */
    size_t max_chars = maxlen - 1;

    while (pos < max_chars) {
        char c = uart_getchar();

        /* Check for end of line */
        if (c == '\n' || c == '\r') {
            uart_putchar('\n'); /* Echo newline */
            break;
        }

        /* Handle backspace (ASCII 8 or 127) */
        if (c == '\b' || c == 127) {
            if (pos > 0) {
                --pos;
                /* Erase character on terminal: backspace, space, backspace */
                uart_putchar('\b');
                uart_putchar(' ');
                uart_putchar('\b');
            }
            continue;
        }

        /* Ignore non-printable characters (except those handled above) */
        if (c < 32)
            continue;

        /* Store and echo the character */
        buf[pos++] = c;
        uart_putchar(c);
    }

    buf[pos] = '\0';
    return pos;
}
