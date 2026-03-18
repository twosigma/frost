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
 * sprintf_test.c
 *
 * Bare-metal test suite for sprintf / snprintf.
 *
 * Rules:
 *   - NO calls to system printf/sprintf/snprintf for validation.
 *   - Expected values are compile-time string/integer constants.
 *   - Output via uart_puts / uart_putchar only.
 *   - Emits <<PASS>> / <<FAIL>> markers for cocotb test harness.
 */

#include <sprintf.h>
#include <uart.h>

#include <stdbool.h>
#include <stdint.h>
#include <string.h> /* strcmp, strlen, memset, memcmp */

/* ──────────────────────────────────────────────────────────────────────────
 * Tiny report helpers – uses UART, avoids sprintf for reporting
 * ────────────────────────────────────────────────────────────────────────── */

static int g_pass = 0;
static int g_fail = 0;

/* Correct decimal printer (avoids using sprintf for test infrastructure) */
static void print_int(int n)
{
    char tmp[24];
    int i = 23;
    tmp[i] = '\0';
    bool neg = n < 0;
    unsigned u = neg ? (unsigned) (-(n + 1)) + 1 : (unsigned) n;
    if (u == 0) {
        tmp[--i] = '0';
    } else {
        while (u) {
            tmp[--i] = (char) ('0' + u % 10);
            u /= 10;
        }
    }
    if (neg)
        tmp[--i] = '-';
    uart_puts(&tmp[i]);
}

static void print_str_escaped(const char *s)
{
    uart_putchar('[');
    for (; *s; s++) {
        if (*s == '\n') {
            uart_putchar('\\');
            uart_putchar('n');
        } else if (*s == '\t') {
            uart_putchar('\\');
            uart_putchar('t');
        } else
            uart_putchar(*s);
    }
    uart_putchar(']');
}

/* ──────────────────────────────────────────────────────────────────────────
 * Core check function
 * ────────────────────────────────────────────────────────────────────────── */

static void check(
    const char *name, const char *expected_str, int expected_ret, const char *got_str, int got_ret)
{
    bool str_ok = (strcmp(expected_str, got_str) == 0);
    bool ret_ok = (expected_ret == got_ret);

    if (str_ok && ret_ok) {
        g_pass++;
        return;
    }
    g_fail++;
    uart_puts("FAIL  ");
    uart_puts(name);
    uart_putchar('\n');
    if (!str_ok) {
        uart_puts("      expected : ");
        print_str_escaped(expected_str);
        uart_puts("  (ret ");
        print_int(expected_ret);
        uart_puts(")\n");
        uart_puts("      got      : ");
        print_str_escaped(got_str);
        uart_puts("  (ret ");
        print_int(got_ret);
        uart_puts(")\n");
    } else {
        uart_puts("      strings match but return values differ: expected=");
        print_int(expected_ret);
        uart_puts(" got=");
        print_int(got_ret);
        uart_putchar('\n');
    }
}

/* Floating-point: accept +/-1 ULP in the last printed digit */
static void check_fp(
    const char *name, const char *expected_str, int expected_ret, const char *got_str, int got_ret)
{
    if (strcmp(expected_str, got_str) == 0 && expected_ret == got_ret) {
        g_pass++;
        return;
    }
    size_t el = strlen(expected_str), gl = strlen(got_str);
    if (el == gl && expected_ret == got_ret) {
        int ndiff = 0;
        bool ok = true;
        for (size_t i = 0; i < el; i++) {
            if (expected_str[i] != got_str[i]) {
                ndiff++;
                int delta = expected_str[i] - got_str[i];
                if (delta < -1 || delta > 1) {
                    ok = false;
                    break;
                }
            }
        }
        if (ok && ndiff <= 1) {
            g_pass++;
            return;
        }
    }
    g_fail++;
    uart_puts("FAIL  ");
    uart_puts(name);
    uart_putchar('\n');
    uart_puts("      expected : ");
    print_str_escaped(expected_str);
    uart_puts("  (ret ");
    print_int(expected_ret);
    uart_puts(")\n");
    uart_puts("      got      : ");
    print_str_escaped(got_str);
    uart_puts("  (ret ");
    print_int(got_ret);
    uart_puts(")\n");
}

/* Convenience macros */
#define BUF 256

#define T(name, expected_str, expected_ret, fmt, ...)                                              \
    do {                                                                                           \
        char _got[BUF];                                                                            \
        int _gr = snprintf(_got, BUF, fmt, ##__VA_ARGS__);                                         \
        check((name), (expected_str), (expected_ret), _got, _gr);                                  \
    } while (0)

#define TFP(name, expected_str, expected_ret, fmt, ...)                                            \
    do {                                                                                           \
        char _got[BUF];                                                                            \
        int _gr = snprintf(_got, BUF, fmt, ##__VA_ARGS__);                                         \
        check_fp((name), (expected_str), (expected_ret), _got, _gr);                               \
    } while (0)

/* section header */
static void section(const char *s)
{
    uart_puts("\n=== ");
    uart_puts(s);
    uart_puts(" ===\n");
}

/* ══════════════════════════════════════════════════════════════════════════
 * Test groups
 * ══════════════════════════════════════════════════════════════════════════ */

/* ── Literals / %% ───────────────────────────────────────────────────────── */
static void test_literal(void)
{
    section("Literal / %%");
    T("empty string", "", 0, "");
    T("plain text", "hello, world", 12, "hello, world");
    T("percent literal", "100%", 4, "100%%");
    T("percent mid", "50% off today", 13, "50%% off today");
    T("just percent", "%", 1, "%%");
    T("two percents", "%%", 2, "%%%%");
    T("percent between", "a%b", 3, "a%%b");
}

/* ── %c ──────────────────────────────────────────────────────────────────── */
static void test_char(void)
{
    section("%c");
    T("char A", "A", 1, "%c", 'A');
    T("char z", "z", 1, "%c", 'z');
    T("char digit", "7", 1, "%c", '7');
    T("char space", " ", 1, "%c", ' ');
    T("char width right", "    x", 5, "%5c", 'x');
    T("char width left", "x    |", 6, "%-5c|", 'x');
    T("char width=1", "A", 1, "%1c", 'A');
    T("char in string", "char=Q", 6, "char=%c", 'Q');
}

/* ── %s ──────────────────────────────────────────────────────────────────── */
static void test_string(void)
{
    section("%s");
    T("str basic", "hello", 5, "%s", "hello");
    T("str empty", "", 0, "%s", "");
    T("str null", "(null)", 6, "%s", (char *) NULL);
    T("str width right", "        hi", 10, "%10s", "hi");
    T("str width left", "hi        |", 11, "%-10s|", "hi");
    T("str precision 3", "hel", 3, "%.3s", "hello");
    T("str prec+width", "       hel", 10, "%10.3s", "hello");
    T("str prec=0", "", 0, "%.0s", "hello");
    T("str prec > len", "tiny", 4, "%.20s", "tiny");
    T("str multi", "one two three", 13, "%s %s %s", "one", "two", "three");
    T("str width=exact", "hi", 2, "%2s", "hi");
    T("str no trunc", "hello", 5, "%3s", "hello"); /* no truncation without prec */
    T("str prec=1", "h", 1, "%.1s", "hello");
    T("str lj prec", "he   |", 6, "%-5.2s|", "hello");
}

/* ── %d / %i ─────────────────────────────────────────────────────────────── */
static void test_int_d(void)
{
    section("%d / %i");
    T("d zero", "0", 1, "%d", 0);
    T("d positive", "42", 2, "%d", 42);
    T("d negative", "-42", 3, "%d", -42);
    T("d one", "1", 1, "%d", 1);
    T("d minus one", "-1", 2, "%d", -1);
    T("d INT_MAX", "2147483647", 10, "%d", 2147483647);
    T("d INT_MIN", "-2147483648", 11, "%d", (int) -2147483648);
    T("d width rj", "        42", 10, "%10d", 42);
    T("d width lj", "42        |", 11, "%-10d|", 42);
    T("d zero-pad", "0000000042", 10, "%010d", 42);
    T("d zero-pad neg", "-000000042", 10, "%010d", -42);
    T("d plus pos", "+42", 3, "%+d", 42);
    T("d plus neg", "-42", 3, "%+d", -42);
    T("d space pos", " 42", 3, "% d", 42);
    T("d space neg", "-42", 3, "% d", -42);
    T("d precision 5", "00042", 5, "%.5d", 42);
    T("d prec 0 nonzero", "42", 2, "%.0d", 42);
    T("d prec 0 zero", "", 0, "%.0d", 0);
    T("d width+prec", "     00042", 10, "%10.5d", 42);
    T("i synonym", "-7", 2, "%i", -7);
    T("d long", "1234567890", 10, "%ld", 1234567890L);
    T("d long long max", "9223372036854775807", 19, "%lld", 9223372036854775807LL);
    T("d long long min", "-9223372036854775808", 20, "%lld", -9223372036854775807LL - 1);
    T("d hh signed", "-1", 2, "%hhd", (signed char) -1);
    T("d h signed", "-32768", 6, "%hd", (short) -32768);
    T("d neg zero-pad5", "  -42", 5, "%5d", -42);
    T("d neg zero-pad05", "-0042", 5, "%05d", -42);
    T("d star width", "      42", 8, "%*d", 8, 42);
    T("d neg star width", "42      |", 9, "%*d|", -8, 42);
}

/* ── %u ──────────────────────────────────────────────────────────────────── */
static void test_uint(void)
{
    section("%u");
    T("u zero", "0", 1, "%u", 0u);
    T("u basic", "42", 2, "%u", 42u);
    T("u UINT_MAX", "4294967295", 10, "%u", 4294967295u);
    T("u width", "        99", 10, "%10u", 99u);
    T("u left", "99        |", 11, "%-10u|", 99u);
    T("u zero-pad", "00000099", 8, "%08u", 99u);
    T("u llu", "18446744073709551615", 20, "%llu", 18446744073709551615ULL);
    T("u lu", "4294967295", 10, "%lu", 4294967295UL);
    T("u hhu", "255", 3, "%hhu", (unsigned char) 255);
    T("u hu", "65535", 5, "%hu", (unsigned short) 65535);
    T("u zu", "1024", 4, "%zu", (size_t) 1024);
    T("u precision", "00042", 5, "%.5u", 42u);
    T("u prec 0 zero", "", 0, "%.0u", 0u);
}

/* ── %o ──────────────────────────────────────────────────────────────────── */
static void test_octal(void)
{
    section("%o");
    T("o zero", "0", 1, "%o", 0);
    T("o basic", "377", 3, "%o", 255);
    T("o large", "17777777777", 11, "%o", 2147483647);
    T("o hash nonzero", "0377", 4, "%#o", 255);
    T("o hash zero", "0", 1, "%#o", 0);
    T("o width", "       377", 10, "%10o", 255);
    T("o zero-pad", "00000377", 8, "%08o", 255);
    T("o left", "377       |", 11, "%-10o|", 255);
    T("o lu", "37777777777", 11, "%lo", 4294967295UL);
    T("o precision", "000377", 6, "%.6o", 255);
    T("o prec 0 zero", "", 0, "%.0o", 0);
}

/* ── %x / %X ─────────────────────────────────────────────────────────────── */
static void test_hex(void)
{
    section("%x / %X");
    T("x zero", "0", 1, "%x", 0);
    T("x basic", "ff", 2, "%x", 255);
    T("x upper", "FF", 2, "%X", 255);
    T("x hash lower", "0xff", 4, "%#x", 255);
    T("x hash upper", "0XFF", 4, "%#X", 255);
    T("x hash zero", "0", 1, "%#x", 0);
    T("x hash zero upper", "0", 1, "%#X", 0);
    T("x width", "        ff", 10, "%10x", 255);
    T("x zero-pad", "000000ff", 8, "%08x", 255);
    T("x left", "ff        |", 11, "%-10x|", 255);
    T("x deadbeef lo", "deadbeef", 8, "%x", 0xdeadbeef);
    T("x deadbeef up", "DEADBEEF", 8, "%X", 0xdeadbeef);
    T("x llx", "deadbeefcafe", 12, "%llx", 0xdeadbeefcafeull);
    T("x precision 8", "000000ff", 8, "%.8x", 255);
    T("x prec 0 zero", "", 0, "%.0x", 0);
    T("x hash+width", "      0xff", 10, "%#10x", 255);
    T("x hash+zeropad", "0x000000ff", 10, "%#010x", 255);
    T("x lx", "ffffffff", 8, "%lx", 4294967295UL);
}

/* ── %f ──────────────────────────────────────────────────────────────────── */
static void test_float_f(void)
{
    section("%f");
    TFP("f zero", "0.000000", 8, "%f", 0.0);
    TFP("f one", "1.000000", 8, "%f", 1.0);
    TFP("f neg one", "-1.000000", 9, "%f", -1.0);
    TFP("f pi", "3.141593", 8, "%f", 3.14159265358979);
    TFP("f neg", "-2.718282", 9, "%f", -2.718281828);
    TFP("f large int", "1234567.890000", 14, "%f", 1234567.89);
    TFP("f small", "0.000123", 8, "%f", 0.000123);
    TFP("f 0.1", "0.100000", 8, "%f", 0.1);
    TFP("f 0.5", "0.500000", 8, "%f", 0.5);
    TFP("f 100.0", "100.000000", 10, "%f", 100.0);
    TFP("f 999.999", "999.999000", 10, "%f", 999.999);
    TFP("f prec 0", "4", 1, "%.0f", 3.7);
    TFP("f prec 0 half", "0", 1, "%.0f", 0.4999);
    TFP("f prec 2", "3.14", 4, "%.2f", 3.14159);
    TFP("f prec 2b", "2.72", 4, "%.2f", 2.71828);
    TFP("f prec 10", "0.3333333333", 12, "%.10f", 1.0 / 3.0);
    TFP("f width rj", "        3.14", 12, "%12.2f", 3.14);
    TFP("f width lj", "3.14        |", 13, "%-12.2f|", 3.14);
    TFP("f zero-pad", "000003.1400", 11, "%011.4f", 3.14);
    TFP("f plus pos", "+3.14", 5, "%+.2f", 3.14);
    TFP("f plus neg", "-3.14", 5, "%+.2f", -3.14);
    TFP("f space pos", " 3.14", 5, "% .2f", 3.14);
    TFP("f space neg", "-3.14", 5, "% .2f", -3.14);
    TFP("f neg small", "-0.001230", 9, "%f", -0.00123);
    TFP("f 1e-5", "0.000010", 8, "%f", 0.00001);
    TFP("f exact half", "0.500000", 8, "%f", 0.5);
    TFP("f prec 4", "3.1416", 6, "%.4f", 3.14159265);
    TFP("f prec 3 round", "1000.000", 8, "%.3f", 999.9995);
    TFP("f neg zero", "-0.000000", 9, "%f", -0.0);
}

/* ── %e / %E ─────────────────────────────────────────────────────────────── */
static void test_float_e(void)
{
    section("%e / %E");
    TFP("e basic", "1.234568e+04", 12, "%e", 12345.6789);
    TFP("e zero", "0.000000e+00", 12, "%e", 0.0);
    TFP("e one", "1.000000e+00", 12, "%e", 1.0);
    TFP("e neg small", "-1.230000e-03", 13, "%e", -0.00123);
    TFP("e upper", "1.234568E+04", 12, "%E", 12345.6789);
    TFP("e prec 0", "1e+04", 5, "%.0e", 12345.6789);
    TFP("e prec 2", "1.23e+04", 8, "%.2e", 12345.6789);
    TFP("e width", "   1.000000e+00", 15, "%15e", 1.0);
    TFP("e plus", "+1.50e+00", 9, "%+.2e", 1.5);
    TFP("e space", " 1.50e+00", 9, "% .2e", 1.5);
    TFP("e small", "1.230000e-10", 12, "%e", 1.23e-10);
    TFP("e large", "1.230000e+15", 12, "%e", 1.23e15);
    TFP("e neg zero", "-0.000000e+00", 13, "%e", -0.0);
    TFP("e prec 4 up", "1.2346E+04", 10, "%.4E", 12345.6789);
    TFP("e 0.1", "1.000000e-01", 12, "%e", 0.1);
    TFP("e 9.99e-5", "9.990000e-05", 12, "%e", 9.99e-5);
}

/* ── %g / %G ─────────────────────────────────────────────────────────────── */
static void test_float_g(void)
{
    section("%g / %G");
    TFP("g one", "1", 1, "%g", 1.0);
    TFP("g pi", "3.14159", 7, "%g", 3.14159265358979);
    TFP("g basic", "12345.7", 7, "%g", 12345.6789);
    TFP("g large", "1.23457e+06", 11, "%g", 1234567.0);
    TFP("g small", "0.000123", 8, "%g", 0.000123);
    TFP("g very small", "1.23e-05", 8, "%g", 1.23e-5);
    TFP("g upper", "12345.7", 7, "%G", 12345.6789);
    TFP("g upper large", "1.23457E+06", 11, "%G", 1234567.0);
    TFP("g prec 3", "3.14", 4, "%.3g", 3.14159);
    TFP("g prec 1", "3", 1, "%.1g", 3.14159);
    TFP("g prec 2", "3.1", 3, "%.2g", 3.14159);
    TFP("g width", "           3.14", 15, "%15.3g", 3.14);
    TFP("g lj width", "3.14           |", 16, "%-15.3g|", 3.14);
    TFP("g zero", "0", 1, "%g", 0.0);
    TFP("g 100", "100", 3, "%g", 100.0);
    TFP("g 0.0001", "0.0001", 6, "%g", 0.0001);
    TFP("g 0.00001", "1e-05", 5, "%g", 0.00001);
    TFP("g neg", "-3.14", 5, "%g", -3.14);
    TFP("g prec 6 exact", "1.5", 3, "%g", 1.5);
    TFP("g plus", "+3.14", 5, "%+.3g", 3.14);
}

/* ── Mixed ───────────────────────────────────────────────────────────────── */
static void test_mixed(void)
{
    section("Mixed");
    T("d+s", "val=42 name=foo", 15, "val=%d name=%s", 42, "foo");
    T("hex+str", "0x0000cafe (cafe)", 17, "0x%08x (%s)", 0xcafe, "cafe");
    TFP("fp+int", "pi~3.1416 n=100", 15, "pi~%.4f n=%d", 3.14159265, 100);
    T("widths", "|    7|7    |00007|", 19, "|%5d|%-5d|%05d|", 7, 7, 7);
    T("repeated %%", "%d=99%", 6, "%%d=%d%%", 99);
    T("signs", "+1 -1", 5, "%+d %+d", 1, -1);
    T("s+d+s", "name: Alice, age: 30", 20, "name: %s, age: %d", "Alice", 30);
    T("hex upper+d", "0XFF = 255", 10, "%#X = %d", 255, 255);
    T("zero-pad+left", "000077    |", 11, "%05d%-5d|", 7, 7);
    T("char+str", "A=65", 4, "%c=%d", 'A', 65);
    T("three strings", "foo/bar/baz", 11, "%s/%s/%s", "foo", "bar", "baz");
    TFP("money", "$1234567.89", 11, "$%.2f", 1234567.89);
    T("neg hex", "    -1", 6, "%6d", -1); /* plain -1 */
    T("multi width", "   1  22 333", 12, "%4d%4d%4d", 1, 22, 333);
}

/* ── snprintf truncation / return-value semantics ────────────────────────── */
static void test_snprintf_trunc(void)
{
    section("snprintf truncation / return value");

    /* Truncation: "hello world" -> buf size 5 -> "hell\0", ret=11 */
    {
        char got[5];
        int r = snprintf(got, 5, "%s", "hello world");
        check("trunc string ret=11", "hell", 11, got, r);
    }

    /* size=1: only the NUL, ret = would-be length */
    {
        char got[1] = {'X'};
        int r = snprintf(got, 1, "%d", 42);
        check("size=1 nul only", "", 2, got, r);
    }

    /* size=0: must not write, ret = would-be length */
    {
        char got[4] = {'X', 'X', 'X', 'X'};
        int r = snprintf(got, 0, "%d", 42);
        bool ok = (r == 2) && (got[0] == 'X');
        if (ok)
            g_pass++;
        else {
            g_fail++;
            uart_puts("FAIL  size=0 no-write\n");
            uart_puts("      ret=");
            print_int(r);
            uart_puts(" got[0]='");
            uart_putchar(got[0]);
            uart_puts("'\n");
        }
    }

    /* Exact fit: size == strlen+1 */
    {
        char got[6];
        int r = snprintf(got, 6, "%s", "hello");
        check("exact fit", "hello", 5, got, r);
    }

    /* Integer truncation */
    {
        char got[4];
        int r = snprintf(got, 4, "%d", 123456);
        check("int trunc ret=6", "123", 6, got, r);
    }

    /* Truncation of float */
    {
        char got[5];
        int r = snprintf(got, 5, "%.2f", 3.14);
        check("float trunc ret=4", "3.14", 4, got, r);
    }

    /* sprintf return value */
    {
        char got[BUF];
        int r = sprintf(got, "hello %s, you are %d", "Alice", 30);
        check("sprintf ret val", "hello Alice, you are 30", 23, got, r);
    }

    /* Multiple conversions, would-be > buf */
    {
        char got[8];
        int r = snprintf(got, 8, "%d + %d = %d", 100, 200, 300);
        /* "100 + 200 = 300" = 15 chars */
        check("multi trunc ret=15", "100 + 2", 15, got, r);
    }
}

/* ── Flags edge cases ────────────────────────────────────────────────────── */
static void test_flags(void)
{
    section("Flags edge cases");
    T("minus overrides zero", "42        ", 10, "%-010d", 42);
    T("plus+zero neg", "-000000042", 10, "%+010d", -42);
    T("space+zero", " 000000042", 10, "% 010d", 42);
    T("plus beats space", "+42", 3, "%+ d", 42); /* + takes precedence */
    T("hash oct 1", "01", 2, "%#o", 1);
    T("hash oct large", "017777777777", 12, "%#o", 2147483647);
    T("hash hex+width", "      0xff", 10, "%#10x", 255);
    T("hash hex+zeropad", "0x000000ff", 10, "%#010x", 255);
    T("hash HEX+zeropad", "0X000000FF", 10, "%#010X", 255);
    T("zero flag with prec", "   00042", 8, "%8.5d", 42); /* prec wins over zero */
    T("width smaller", "12345", 5, "%3d", 12345);         /* no truncation */
    T("prec 0 nonzero", "7", 1, "%.0d", 7);
    T("prec 0 neg", "-7", 2, "%.0d", -7);
    T("prec 0 zero blank", "", 0, "%.0d", 0);
    T("prec 0 uint", "7", 1, "%.0u", 7u);
    T("prec 0 uint zero", "", 0, "%.0u", 0u);
}

/* ── Length modifiers ────────────────────────────────────────────────────── */
static void test_length_mods(void)
{
    section("Length modifiers");
    T("hh signed max", "127", 3, "%hhd", (signed char) 127);
    T("hh signed min", "-128", 4, "%hhd", (signed char) -128);
    T("hh unsigned", "255", 3, "%hhu", (unsigned char) 255);
    T("h signed max", "32767", 5, "%hd", (short) 32767);
    T("h signed min", "-32768", 6, "%hd", (short) -32768);
    T("h unsigned max", "65535", 5, "%hu", (unsigned short) 65535);
    T("l signed", "2147483647", 10, "%ld", 2147483647L);
    T("l unsigned", "4294967295", 10, "%lu", 4294967295UL);
    T("ll signed max", "9223372036854775807", 19, "%lld", 9223372036854775807LL);
    T("ll signed min", "-9223372036854775808", 20, "%lld", -9223372036854775807LL - 1);
    T("ll unsigned max", "18446744073709551615", 20, "%llu", 18446744073709551615ULL);
    T("z size_t", "65536", 5, "%zu", (size_t) 65536);
    T("z size_t large", "4294967295", 10, "%zu", (size_t) 4294967295UL);
    T("lx", "ffffffffffffffff", 16, "%llx", 18446744073709551615ULL);
    T("lX", "FFFFFFFFFFFFFFFF", 16, "%llX", 18446744073709551615ULL);
}

/* ── Pointer %p ──────────────────────────────────────────────────────────── */
static void test_pointer(void)
{
    section("%p");
    /* We can't hardcode pointer values, so we check structural properties. */
    {
        void *ptr = (void *) 0x0;
        char got[BUF];
        int r = snprintf(got, BUF, "%p", ptr);
        bool ok = (got[0] == '0' && got[1] == 'x') && (r >= 3);
        if (ok)
            g_pass++;
        else {
            g_fail++;
            uart_puts("FAIL  p NULL has 0x prefix\n");
        }
    }
    {
        void *ptr = (void *) 0xDEAD;
        char got[BUF];
        snprintf(got, BUF, "%p", ptr);
        bool ok = (got[0] == '0' && got[1] == 'x');
        if (ok)
            g_pass++;
        else {
            g_fail++;
            uart_puts("FAIL  p 0xDEAD has 0x prefix\n");
        }
    }
    {
        /* Width pads with spaces */
        void *ptr = (void *) 0x1;
        char got[BUF];
        int r = snprintf(got, BUF, "%20p", ptr);
        bool ok = (r == 20) && (got[0] == ' ');
        if (ok)
            g_pass++;
        else {
            g_fail++;
            uart_puts("FAIL  p width=20: ");
            print_str_escaped(got);
            uart_puts(" ret=");
            print_int(r);
            uart_putchar('\n');
        }
    }
}

/* ── Precision on integers ───────────────────────────────────────────────── */
static void test_int_precision(void)
{
    section("Integer precision");
    T("d prec > digits", "000042", 6, "%.6d", 42);
    T("d prec = digits", "42", 2, "%.2d", 42);
    T("d prec < digits", "12345", 5, "%.3d", 12345);
    T("d neg prec", "-000042", 7, "%.6d", -42);
    T("x prec", "0000ff", 6, "%.6x", 255);
    T("o prec", "000377", 6, "%.6o", 255);
    T("u prec leading0", "00000001", 8, "%.8u", 1u);
    T("d w+p both", "      00042", 11, "%11.5d", 42);
    T("d w+p left", "00042      |", 12, "%-11.5d|", 42);
}

/* ── Star width / precision ──────────────────────────────────────────────── */
static void test_star(void)
{
    section("Star width / precision");
    T("d star w", "      42", 8, "%*d", 8, 42);
    T("d neg star lj", "42      |", 9, "%*d|", -8, 42);
    T("s star w", "        hi", 10, "%*s", 10, "hi");
    T("s star prec", "hel", 3, "%.*s", 3, "hello");
    T("f star prec", "3.14", 4, "%.*f", 2, 3.14159);
    T("d star w+p", "     00042", 10, "%*.*d", 10, 5, 42);
    T("star w=0", "42", 2, "%*d", 0, 42);
}

/* ── %n ──────────────────────────────────────────────────────────────────── */
static void test_n(void)
{
    section("%n");
    {
        char got[BUF];
        int pos = -1;
        snprintf(got, BUF, "hello%n world", &pos);
        bool ok = (pos == 5);
        if (ok)
            g_pass++;
        else {
            g_fail++;
            uart_puts("FAIL  %n pos: expected 5 got ");
            print_int(pos);
            uart_putchar('\n');
        }
    }
    {
        char got[BUF];
        int pos = -1;
        snprintf(got, BUF, "%d%n", 12345, &pos);
        bool ok = (pos == 5);
        if (ok)
            g_pass++;
        else {
            g_fail++;
            uart_puts("FAIL  %n after %d: expected 5 got ");
            print_int(pos);
            uart_putchar('\n');
        }
    }
}

/* ── Exotic / regression ─────────────────────────────────────────────────── */
static void test_regression(void)
{
    section("Regression / exotic");
    /* NUL byte via %c */
    {
        char got[4] = {'A', 'B', 'C', 'D'};
        snprintf(got, 4, "%c%c", 'X', '\0');
        bool ok = (got[0] == 'X' && got[1] == '\0');
        if (ok)
            g_pass++;
        else {
            g_fail++;
            uart_puts("FAIL  NUL via %c\n");
        }
    }
    T("d 10 digits", "1000000000", 10, "%d", 1000000000);
    T("d neg 10 digits", "-1000000000", 11, "%d", -1000000000);
    T("u 10 digits", "3000000000", 10, "%u", 3000000000u);
    T("x long value", "cafebabe", 8, "%x", 0xcafebabe);
    T("X long value", "CAFEBABE", 8, "%X", 0xcafebabe);
    TFP("f 0.001", "0.001000", 8, "%f", 0.001);
    TFP("f 0.0001", "0.000100", 8, "%f", 0.0001);
    TFP("f 0.00001", "0.000010", 8, "%f", 0.00001);
    TFP("f large round", "1000000.000000", 14, "%f", 999999.9999995);
    TFP("e 1e-4", "1.000000e-04", 12, "%e", 1e-4);
    TFP("e 1e+10", "1.000000e+10", 12, "%e", 1e10);
    TFP("e 1e-10", "1.000000e-10", 12, "%e", 1e-10);
    TFP("g strips zeros", "1.5", 3, "%g", 1.5);
    TFP("g strips zeros 2", "1.25", 4, "%g", 1.25);
    TFP("g integer-like", "100", 3, "%g", 100.0);
    TFP("g 1e4 boundary", "10000", 5, "%g", 10000.0);
    TFP("g 1e5 use e", "100000", 6, "%g", 100000.0);
    TFP("g 1e6 use e", "1e+06", 5, "%g", 1000000.0);
    T("s null explicit", "(null)", 6, "%s", (char *) NULL);
    T("s empty prec 0", "", 0, "%.0s", "anything");
    T("d INT_MAX width", "  2147483647", 12, "%12d", 2147483647);
    T("alternating fmt", "1a2b3c", 6, "%d%c%d%c%d%c", 1, 'a', 2, 'b', 3, 'c');
    T("all zeros fmt", "000/000/0000", 12, "%03d/%03d/%04d", 0, 0, 0);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * main
 * ══════════════════════════════════════════════════════════════════════════ */

int main(void)
{
    uart_puts("sprintf/snprintf Test Suite\n");
    uart_puts("==========================\n");

    test_literal();
    test_char();
    test_string();
    test_int_d();
    test_uint();
    test_octal();
    test_hex();
    test_float_f();
    test_float_e();
    test_float_g();
    test_mixed();
    test_snprintf_trunc();
    test_flags();
    test_length_mods();
    test_pointer();
    test_int_precision();
    test_star();
    test_n();
    test_regression();

    uart_puts("\n==========================\n");
    uart_puts("Results: ");
    print_int(g_pass);
    uart_puts(" passed, ");
    print_int(g_fail);
    uart_puts(" failed (total ");
    print_int(g_pass + g_fail);
    uart_puts(")\n");

    if (g_fail == 0) {
        uart_puts("ALL TESTS PASSED\n");
        uart_puts("<<PASS>>\n");
    } else {
        uart_puts("SOME TESTS FAILED\n");
        uart_puts("<<FAIL>>\n");
    }

    /* Halt */
    for (;;) {
    }
}
