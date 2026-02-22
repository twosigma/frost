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

// Frost replacement for riscv-tests/benchmarks/common/syscalls.c
//
// Replaces the tohost/fromhost proxy syscall mechanism with direct
// UART output at 0x40000000. Provides the same API surface so
// benchmark source files compile unchanged.

#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>

#define UART_TX (*(volatile uint8_t *) 0x40000000)

// util.h references (must match riscv-tests/benchmarks/common/util.h)
#include "encoding.h"

// Forward declarations
int sprintf(char *str, const char *fmt, ...);

// -----------------------------------------------------------------------
// UART output primitives
// -----------------------------------------------------------------------

static void uart_putchar_raw(char c)
{
    if (c == '\n')
        UART_TX = (uint8_t) '\r';
    UART_TX = (uint8_t) c;
}

void printstr(const char *s)
{
    while (*s)
        uart_putchar_raw(*s++);
}

#undef putchar
int putchar(int ch)
{
    uart_putchar_raw((char) ch);
    return ch;
}

// -----------------------------------------------------------------------
// Performance counters (setStats)
// -----------------------------------------------------------------------

#define NUM_COUNTERS 2
static uintptr_t counters[NUM_COUNTERS];
static char *counter_names[NUM_COUNTERS];

void setStats(int enable)
{
    int i = 0;
#define READ_CTR(name)                                                                             \
    do {                                                                                           \
        while (i >= NUM_COUNTERS)                                                                  \
            ;                                                                                      \
        uintptr_t csr = read_csr(name);                                                            \
        if (!enable) {                                                                             \
            csr -= counters[i];                                                                    \
            counter_names[i] = #name;                                                              \
        }                                                                                          \
        counters[i++] = csr;                                                                       \
    } while (0)

    READ_CTR(cycle);
    READ_CTR(instret);

#undef READ_CTR
}

// -----------------------------------------------------------------------
// Exit: print <<PASS>> (code==0) or <<FAIL>> (code!=0) via UART
// -----------------------------------------------------------------------

void __attribute__((noreturn)) exit(int code)
{
    if (code == 0) {
        printstr("<<PASS>>\n");
    } else {
        printstr("<<FAIL>>\n");
    }
    while (1)
        ;
}

void abort(void)
{
    exit(128);
}

// -----------------------------------------------------------------------
// Trap handler (weak default — just fails)
// -----------------------------------------------------------------------

uintptr_t __attribute__((weak)) handle_trap(uintptr_t cause, uintptr_t epc, uintptr_t regs[32])
{
    (void) cause;
    (void) epc;
    (void) regs;
    exit(1337);
}

// -----------------------------------------------------------------------
// Thread entry (weak default — single-threaded: only core 0 proceeds)
// -----------------------------------------------------------------------

void __attribute__((weak)) thread_entry(int cid, int nc)
{
    (void) nc;
    while (cid != 0)
        ;
}

// -----------------------------------------------------------------------
// main (weak default — benchmarks override this)
// -----------------------------------------------------------------------

int __attribute__((weak)) main(int argc, char **argv)
{
    (void) argc;
    (void) argv;
    printstr("Implement main(), foo!\n");
    return -1;
}

// -----------------------------------------------------------------------
// _init: called by crt0, orchestrates benchmark execution
// -----------------------------------------------------------------------

void _init(int cid, int nc)
{
    thread_entry(cid, nc);

    // Only single-threaded programs reach here
    int ret = main(0, 0);

    // Print performance counter stats
    char buf[NUM_COUNTERS * 32] __attribute__((aligned(64)));
    char *pbuf = buf;
    for (int i = 0; i < NUM_COUNTERS; i++)
        if (counters[i])
            pbuf += sprintf(pbuf, "%s = %lu\n", counter_names[i], (unsigned long) counters[i]);
    if (pbuf != buf)
        printstr(buf);

    exit(ret);
}

// -----------------------------------------------------------------------
// Barrier (for multi-threaded benchmarks — trivial for single-core Frost)
// -----------------------------------------------------------------------

static void __attribute__((noinline)) barrier(int ncores)
{
    (void) ncores;
    // Single-core: no synchronization needed
}

// -----------------------------------------------------------------------
// Printf implementation (ported from upstream syscalls.c)
// -----------------------------------------------------------------------

void printhex(uint64_t x)
{
    char str[17];
    int i;
    for (i = 0; i < 16; i++) {
        str[15 - i] = (x & 0xF) + ((x & 0xF) < 10 ? '0' : 'a' - 10);
        x >>= 4;
    }
    str[16] = 0;
    printstr(str);
}

static inline void printnum(void (*putch)(int, void **),
                            void **putdat,
                            unsigned long long num,
                            unsigned base,
                            int width,
                            int padc)
{
    unsigned digs[sizeof(num) * CHAR_BIT];
    int pos = 0;

    while (1) {
        digs[pos++] = num % base;
        if (num < base)
            break;
        num /= base;
    }

    while (width-- > pos)
        putch(padc, putdat);

    while (pos-- > 0)
        putch(digs[pos] + (digs[pos] >= 10 ? 'a' - 10 : '0'), putdat);
}

static unsigned long long getuint(va_list *ap, int lflag)
{
    if (lflag >= 2)
        return va_arg(*ap, unsigned long long);
    else if (lflag)
        return va_arg(*ap, unsigned long);
    else
        return va_arg(*ap, unsigned int);
}

static long long getint(va_list *ap, int lflag)
{
    if (lflag >= 2)
        return va_arg(*ap, long long);
    else if (lflag)
        return va_arg(*ap, long);
    else
        return va_arg(*ap, int);
}

static void vprintfmt(void (*putch)(int, void **), void **putdat, const char *fmt, va_list ap)
{
    const char *p;
    const char *last_fmt;
    int ch;
    unsigned long long num;
    int base, lflag, width, precision, altflag;
    char padc;

    while (1) {
        while ((ch = *(unsigned char *) fmt) != '%') {
            if (ch == '\0')
                return;
            fmt++;
            putch(ch, putdat);
        }
        fmt++;

        last_fmt = fmt;
        padc = ' ';
        width = -1;
        precision = -1;
        lflag = 0;
        altflag = 0;
    reswitch:
        switch (ch = *(unsigned char *) fmt++) {
            case '-':
                padc = '-';
                goto reswitch;
            case '0':
                padc = '0';
                goto reswitch;
            case '1':
            case '2':
            case '3':
            case '4':
            case '5':
            case '6':
            case '7':
            case '8':
            case '9':
                for (precision = 0;; ++fmt) {
                    precision = precision * 10 + ch - '0';
                    ch = *fmt;
                    if (ch < '0' || ch > '9')
                        break;
                }
                goto process_precision;
            case '*':
                precision = va_arg(ap, int);
                goto process_precision;
            case '.':
                if (width < 0)
                    width = 0;
                goto reswitch;
            case '#':
                altflag = 1;
                goto reswitch;
            process_precision:
                if (width < 0)
                    width = precision, precision = -1;
                goto reswitch;
            case 'l':
                lflag++;
                goto reswitch;
            case 'c':
                putch(va_arg(ap, int), putdat);
                break;
            case 's':
                if ((p = va_arg(ap, char *)) == NULL)
                    p = "(null)";
                if (width > 0 && padc != '-')
                    for (width -= strnlen(p, precision); width > 0; width--)
                        putch(padc, putdat);
                for (; (ch = *p) != '\0' && (precision < 0 || --precision >= 0); width--) {
                    putch(ch, putdat);
                    p++;
                }
                for (; width > 0; width--)
                    putch(' ', putdat);
                break;
            case 'd':
                num = getint(&ap, lflag);
                if ((long long) num < 0) {
                    putch('-', putdat);
                    num = -(long long) num;
                }
                base = 10;
                goto signed_number;
            case 'u':
                base = 10;
                goto unsigned_number;
            case 'o':
                base = 8;
                goto unsigned_number;
            case 'p':
                lflag = 1;
                putch('0', putdat);
                putch('x', putdat);
                /* fall through */
            case 'x':
                base = 16;
            unsigned_number:
                num = getuint(&ap, lflag);
            signed_number:
                printnum(putch, putdat, num, base, width, padc);
                break;
            case '%':
                putch(ch, putdat);
                break;
            default:
                putch('%', putdat);
                fmt = last_fmt;
                break;
        }
    }
}

static void printf_putch(int ch, void **data)
{
    (void) data;
    uart_putchar_raw((char) ch);
}

int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintfmt(printf_putch, 0, fmt, ap);
    va_end(ap);
    return 0;
}

int sprintf(char *str, const char *fmt, ...)
{
    va_list ap;
    char *str0 = str;
    va_start(ap, fmt);

    void sprintf_putch(int ch, void **data)
    {
        char **pstr = (char **) data;
        **pstr = ch;
        (*pstr)++;
    }

    vprintfmt(sprintf_putch, (void **) &str, fmt, ap);
    *str = 0;

    va_end(ap);
    return str - str0;
}

// -----------------------------------------------------------------------
// Standard library replacements (bare-metal, no libc)
// -----------------------------------------------------------------------

void *memcpy(void *dest, const void *src, size_t len)
{
    if ((((uintptr_t) dest | (uintptr_t) src | len) & (sizeof(uintptr_t) - 1)) == 0) {
        const uintptr_t *s = src;
        uintptr_t *d = dest;
        uintptr_t *end = dest + len;
        while (d + 8 < end) {
            uintptr_t reg[8] = {s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]};
            d[0] = reg[0];
            d[1] = reg[1];
            d[2] = reg[2];
            d[3] = reg[3];
            d[4] = reg[4];
            d[5] = reg[5];
            d[6] = reg[6];
            d[7] = reg[7];
            d += 8;
            s += 8;
        }
        while (d < end)
            *d++ = *s++;
    } else {
        const char *s = src;
        char *d = dest;
        while (d < (char *) (dest + len))
            *d++ = *s++;
    }
    return dest;
}

void *memset(void *dest, int byte, size_t len)
{
    if ((((uintptr_t) dest | len) & (sizeof(uintptr_t) - 1)) == 0) {
        uintptr_t word = byte & 0xFF;
        word |= word << 8;
        word |= word << 16;

        uintptr_t *d = dest;
        while (d < (uintptr_t *) (dest + len))
            *d++ = word;
    } else {
        char *d = dest;
        while (d < (char *) (dest + len))
            *d++ = byte;
    }
    return dest;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return p - s;
}

size_t strnlen(const char *s, size_t n)
{
    const char *p = s;
    while (n-- && *p)
        p++;
    return p - s;
}

int strcmp(const char *s1, const char *s2)
{
    unsigned char c1, c2;
    do {
        c1 = *s1++;
        c2 = *s2++;
    } while (c1 != 0 && c1 == c2);
    return c1 - c2;
}

char *strcpy(char *dest, const char *src)
{
    char *d = dest;
    while ((*d++ = *src++))
        ;
    return dest;
}

// -----------------------------------------------------------------------
// Minimal malloc/free (bump allocator for TLS emulation in libgcc)
// -----------------------------------------------------------------------

extern char _heap_start, _heap_end;
static char *_brk = &_heap_start;

void *malloc(size_t size)
{
    // Align to 8 bytes
    size = (size + 7) & ~(size_t) 7;
    char *p = _brk;
    if (p + size > &_heap_end)
        return (void *) 0;
    _brk = p + size;
    return p;
}

void free(void *ptr)
{
    (void) ptr;
    // Bump allocator: no-op free
}

void *calloc(size_t nmemb, size_t size)
{
    size_t total = nmemb * size;
    void *p = malloc(total);
    if (p)
        memset(p, 0, total);
    return p;
}

void *realloc(void *ptr, size_t size)
{
    void *newp = malloc(size);
    if (newp && ptr)
        memcpy(newp, ptr, size); // Over-copies, but safe for bump allocator
    return newp;
}

long atol(const char *str)
{
    long res = 0;
    int sign = 0;

    while (*str == ' ')
        str++;

    if (*str == '-' || *str == '+') {
        sign = *str == '-';
        str++;
    }

    while (*str) {
        res *= 10;
        res += *str++ - '0';
    }

    return sign ? -res : res;
}
