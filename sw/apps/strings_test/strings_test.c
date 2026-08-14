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
 * String Library Test Suite
 *
 * Exercises all functions in string.c:
 *   - memset: Fill memory with byte value
 *   - memcpy: Copy memory regions
 *   - memmove: Copy memory with overlap handling
 *   - memcmp: Compare memory regions
 *   - strlen: String length calculation
 *   - strncpy: Bounded string copy
 *   - strcmp: Lexicographic string comparison
 *   - strncmp: Bounded lexicographic comparison
 *   - strchr: Find character in string
 *   - strstr: Find substring in string
 *
 * Exercises all functions in ctype.c:
 *   - isdigit: Check for decimal digit
 *   - isalpha: Check for alphabetic character
 *   - isupper: Check for uppercase letter
 *   - islower: Check for lowercase letter
 *   - toupper: Convert to uppercase
 *   - tolower: Convert to lowercase
 *   - isspace: Check for whitespace
 *
 * Exercises all functions in stdlib.c:
 *   - strtol: Convert string to long with base
 *   - atoi: Convert string to int
 *   - atol: Convert string to long
 */

#include "ctype.h"
#include "stdlib.h"
#include "string.h"
#include "uart.h"
#include <stdint.h>

/* Test result tracking */
static uint32_t tests_passed = 0;
static uint32_t tests_failed = 0;

/* Report test result */
static void check(const char *name, int condition)
{
    if (condition) {
        tests_passed++;
        uart_printf("  PASS: %s\n", name);
    } else {
        tests_failed++;
        uart_printf("  FAIL: %s\n", name);
    }
}

/* Test memset function */
static void test_memset(void)
{
    uart_printf("\n=== memset ===\n");

    char buf[16];

    /* Fill with zeros */
    memset(buf, 0, sizeof(buf));
    check("fill with zeros", buf[0] == 0 && buf[7] == 0 && buf[15] == 0);

    /* Fill with 0xAA pattern */
    memset(buf, 0xAA, sizeof(buf));
    check("fill with 0xAA",
          (unsigned char) buf[0] == 0xAA && (unsigned char) buf[7] == 0xAA &&
              (unsigned char) buf[15] == 0xAA);

    /* Fill partial buffer */
    memset(buf, 0, sizeof(buf));
    memset(buf + 4, 0x55, 4);
    check("partial fill",
          buf[3] == 0 && (unsigned char) buf[4] == 0x55 && (unsigned char) buf[7] == 0x55 &&
              buf[8] == 0);

    /* Return value check */
    char *ret = memset(buf, 'X', 3);
    check("return value", ret == buf);
}

/* Test memcpy function */
static void test_memcpy(void)
{
    uart_printf("\n=== memcpy ===\n");

    char src[16] = "Hello, World!";
    char dst[16];

    /* Basic copy */
    memset(dst, 0, sizeof(dst));
    memcpy(dst, src, 14);
    check("basic copy", dst[0] == 'H' && dst[7] == 'W' && dst[12] == '!');

    /* Partial copy */
    memset(dst, 0, sizeof(dst));
    memcpy(dst, src + 7, 5);
    check("partial copy", dst[0] == 'W' && dst[4] == 'd' && dst[5] == 0);

    /* Copy single byte */
    memset(dst, 0, sizeof(dst));
    memcpy(dst, src, 1);
    check("single byte copy", dst[0] == 'H' && dst[1] == 0);

    /* Return value check */
    char *ret = memcpy(dst, src, 5);
    check("return value", ret == dst);
}

/* Test memmove function */
static void test_memmove(void)
{
    uart_printf("\n=== memmove ===\n");

    char buf[32];

    /* Non-overlapping copy (should work like memcpy) */
    memset(buf, 0, sizeof(buf));
    memcpy(buf, "Hello, World!", 14);
    memmove(buf + 16, buf, 14);
    check("non-overlap copy", buf[16] == 'H' && buf[23] == 'W' && buf[28] == '!');

    /* Overlapping copy: dest > src (copy backward) */
    memset(buf, 0, sizeof(buf));
    memcpy(buf, "ABCDEFGHIJ", 10);
    memmove(buf + 2, buf, 8); /* Move "ABCDEFGH" to position 2 */
    check("overlap dst>src",
          buf[0] == 'A' && buf[1] == 'B' && buf[2] == 'A' && buf[3] == 'B' && buf[9] == 'H');

    /* Overlapping copy: dest < src (copy forward) */
    memset(buf, 0, sizeof(buf));
    memcpy(buf + 4, "ABCDEFGH", 8);
    memmove(buf + 2, buf + 4, 8); /* Move "ABCDEFGH" from position 4 to 2 */
    check("overlap dst<src", buf[2] == 'A' && buf[3] == 'B' && buf[9] == 'H');

    /* Same source and destination (no-op) */
    memset(buf, 0, sizeof(buf));
    memcpy(buf, "Test", 5);
    memmove(buf, buf, 4);
    check("same src/dst", buf[0] == 'T' && buf[3] == 't');

    /* Single byte overlap */
    memset(buf, 0, sizeof(buf));
    memcpy(buf, "XY", 2);
    memmove(buf + 1, buf, 1);
    check("single byte", buf[0] == 'X' && buf[1] == 'X');

    /* Return value check */
    char *ret = memmove(buf, buf + 1, 3);
    check("return value", ret == buf);
}

/* Test memcmp function */
static void test_memcmp(void)
{
    uart_printf("\n=== memcmp ===\n");

    /* Equal memory regions */
    check("equal regions", memcmp("hello", "hello", 5) == 0);
    check("equal partial", memcmp("helloX", "helloY", 5) == 0);
    check("equal empty", memcmp("abc", "xyz", 0) == 0);

    /* First region less than second */
    check("less at byte 0", memcmp("abc", "bbc", 3) < 0);
    check("less at byte 2", memcmp("abc", "abd", 3) < 0);
    check("less unsigned", memcmp("\x00", "\xFF", 1) < 0);

    /* First region greater than second */
    check("greater at byte 0", memcmp("bbc", "abc", 3) > 0);
    check("greater at byte 2", memcmp("abd", "abc", 3) > 0);
    check("greater unsigned", memcmp("\xFF", "\x00", 1) > 0);

    /* Binary data (not null-terminated) */
    char bin1[] = {0x01, 0x02, 0x03, 0x00, 0x05};
    char bin2[] = {0x01, 0x02, 0x03, 0x00, 0x05};
    char bin3[] = {0x01, 0x02, 0x03, 0x00, 0x06};
    check("binary equal", memcmp(bin1, bin2, 5) == 0);
    check("binary diff after null", memcmp(bin1, bin3, 5) < 0);

    /* Single byte comparison */
    check("single equal", memcmp("A", "A", 1) == 0);
    check("single less", memcmp("A", "B", 1) < 0);
    check("single greater", memcmp("B", "A", 1) > 0);
}

/* Test strlen function */
static void test_strlen(void)
{
    uart_printf("\n=== strlen ===\n");

    check("empty string", strlen("") == 0);
    check("single char", strlen("A") == 1);
    check("short string", strlen("Hello") == 5);
    check("longer string", strlen("Hello, World!") == 13);

    /* Embedded data after null */
    char buf[16] = "Test\0Extra";
    check("stops at null", strlen(buf) == 4);
}

/* Test strncpy function */
static void test_strncpy(void)
{
    uart_printf("\n=== strncpy ===\n");

    char dst[16];

    /* Source shorter than n: should copy and pad with nulls */
    memset(dst, 'X', sizeof(dst));
    strncpy(dst, "Hi", 8);
    check("short src copy", dst[0] == 'H' && dst[1] == 'i' && dst[2] == '\0');
    check("short src padding", dst[3] == '\0' && dst[7] == '\0');

    /* Source longer than n: should truncate, no null terminator */
    memset(dst, 'X', sizeof(dst));
    strncpy(dst, "Hello, World!", 5);
    check("long src truncate", dst[0] == 'H' && dst[4] == 'o');
    check("long src no null", dst[5] == 'X');

    /* Source equals n: exact fit, no null */
    memset(dst, 'X', sizeof(dst));
    strncpy(dst, "Test", 4);
    check("exact fit", dst[0] == 'T' && dst[3] == 't' && dst[4] == 'X');

    /* The source is not required to contain a null within the copied range. */
    const char bounded_src[4] = {'A', 'B', 'C', 'D'};
    memset(dst, 'X', sizeof(dst));
    strncpy(dst, bounded_src, sizeof(bounded_src));
    check("non-null bounded src",
          dst[0] == 'A' && dst[1] == 'B' && dst[2] == 'C' && dst[3] == 'D' && dst[4] == 'X');

    /* A zero-length copy performs no source or destination accesses. */
    dst[0] = 'Z';
    strncpy(dst, bounded_src, 0);
    check("zero length no-op", dst[0] == 'Z');

    /* Empty source */
    memset(dst, 'X', sizeof(dst));
    strncpy(dst, "", 4);
    check("empty src", dst[0] == '\0' && dst[1] == '\0' && dst[3] == '\0');

    /* Return value check */
    char *ret = strncpy(dst, "ABC", 5);
    check("return value", ret == dst);
}

/* Test strcmp function */
static void test_strcmp(void)
{
    uart_printf("\n=== strcmp ===\n");

    /* Equal strings */
    check("equal strings", strcmp("hello", "hello") == 0);
    check("empty strings", strcmp("", "") == 0);

    /* First string less than second */
    check("abc < abd", strcmp("abc", "abd") < 0);
    check("abc < abcd", strcmp("abc", "abcd") < 0);
    check("empty < non-empty", strcmp("", "a") < 0);
    check("A < a (case)", strcmp("A", "a") < 0);

    /* First string greater than second */
    check("abd > abc", strcmp("abd", "abc") > 0);
    check("abcd > abc", strcmp("abcd", "abc") > 0);
    check("non-empty > empty", strcmp("a", "") > 0);
    check("b > a", strcmp("b", "a") > 0);

    /* Single characters */
    check("single equal", strcmp("X", "X") == 0);
    check("single less", strcmp("A", "B") < 0);
    check("single greater", strcmp("Z", "Y") > 0);
}

/* Test strncmp function */
static void test_strncmp(void)
{
    uart_printf("\n=== strncmp ===\n");

    /* Equal within n */
    check("equal n=5", strncmp("hello", "hello", 5) == 0);
    check("equal n=3", strncmp("hello", "helXX", 3) == 0);
    check("equal n=0", strncmp("abc", "xyz", 0) == 0);

    /* Different within n */
    check("diff at n=3", strncmp("abc", "abd", 3) < 0);
    check("diff at n=1", strncmp("abc", "bbc", 1) < 0);

    /* n exceeds string length */
    check("n > len equal", strncmp("hi", "hi", 10) == 0);
    check("n > len diff", strncmp("hi", "ho", 10) < 0);

    /* Prefix comparison */
    check("prefix match", strncmp("hello", "help", 3) == 0);
    check("prefix differ", strncmp("hello", "help", 4) < 0);
}

/* Test strchr function */
static void test_strchr(void)
{
    uart_printf("\n=== strchr ===\n");

    const char *str = "Hello, World!";

    /* Find existing characters */
    check("find H", strchr(str, 'H') == str);
    check("find o", strchr(str, 'o') == str + 4);
    check("find W", strchr(str, 'W') == str + 7);
    check("find !", strchr(str, '!') == str + 12);

    /* Find first occurrence */
    check("first l", strchr(str, 'l') == str + 2);

    /* Character not found */
    check("not found", strchr(str, 'z') == NULL);
    check("not found empty", strchr("", 'a') == NULL);

    /* Find null terminator */
    check("find null", strchr(str, '\0') == str + 13);
}

/* Test strstr function */
static void test_strstr(void)
{
    uart_printf("\n=== strstr ===\n");

    const char *str = "Hello, World!";

    /* Find existing substrings */
    check("find Hello", strstr(str, "Hello") == str);
    check("find World", strstr(str, "World") == str + 7);
    check("find lo", strstr(str, "lo") == str + 3);
    check("find !", strstr(str, "!") == str + 12);

    /* Empty needle */
    check("empty needle", strstr(str, "") == str);

    /* Substring not found */
    check("not found", strstr(str, "xyz") == NULL);
    check("partial match", strstr(str, "Hellooo") == NULL);

    /* Single character needle */
    check("single char", strstr(str, "W") == str + 7);

    /* Needle at end */
    check("at end", strstr(str, "ld!") == str + 10);

    /* Entire string as needle */
    check("full match", strstr(str, "Hello, World!") == str);
}

/* Test isdigit function */
static void test_isdigit(void)
{
    uart_printf("\n=== isdigit ===\n");

    /* Digits should return non-zero */
    check("'0' is digit", isdigit('0') != 0);
    check("'5' is digit", isdigit('5') != 0);
    check("'9' is digit", isdigit('9') != 0);

    /* Non-digits should return zero */
    check("'a' not digit", isdigit('a') == 0);
    check("'Z' not digit", isdigit('Z') == 0);
    check("' ' not digit", isdigit(' ') == 0);
    check("'/' not digit", isdigit('/') == 0);
    check("':' not digit", isdigit(':') == 0);
    check("'\\0' not digit", isdigit('\0') == 0);
}

/* Test isalpha function */
static void test_isalpha(void)
{
    uart_printf("\n=== isalpha ===\n");

    /* Lowercase letters */
    check("'a' is alpha", isalpha('a') != 0);
    check("'m' is alpha", isalpha('m') != 0);
    check("'z' is alpha", isalpha('z') != 0);

    /* Uppercase letters */
    check("'A' is alpha", isalpha('A') != 0);
    check("'M' is alpha", isalpha('M') != 0);
    check("'Z' is alpha", isalpha('Z') != 0);

    /* Non-letters should return zero */
    check("'0' not alpha", isalpha('0') == 0);
    check("' ' not alpha", isalpha(' ') == 0);
    check("'@' not alpha", isalpha('@') == 0);
    check("'[' not alpha", isalpha('[') == 0);
    check("'`' not alpha", isalpha('`') == 0);
    check("'{' not alpha", isalpha('{') == 0);
}

/* Test isupper function */
static void test_isupper(void)
{
    uart_printf("\n=== isupper ===\n");

    /* Uppercase letters */
    check("'A' is upper", isupper('A') != 0);
    check("'M' is upper", isupper('M') != 0);
    check("'Z' is upper", isupper('Z') != 0);

    /* Non-uppercase should return zero */
    check("'a' not upper", isupper('a') == 0);
    check("'z' not upper", isupper('z') == 0);
    check("'0' not upper", isupper('0') == 0);
    check("'@' not upper", isupper('@') == 0);
    check("'[' not upper", isupper('[') == 0);
}

/* Test islower function */
static void test_islower(void)
{
    uart_printf("\n=== islower ===\n");

    /* Lowercase letters */
    check("'a' is lower", islower('a') != 0);
    check("'m' is lower", islower('m') != 0);
    check("'z' is lower", islower('z') != 0);

    /* Non-lowercase should return zero */
    check("'A' not lower", islower('A') == 0);
    check("'Z' not lower", islower('Z') == 0);
    check("'0' not lower", islower('0') == 0);
    check("'`' not lower", islower('`') == 0);
    check("'{' not lower", islower('{') == 0);
}

/* Test toupper function */
static void test_toupper(void)
{
    uart_printf("\n=== toupper ===\n");

    /* Lowercase to uppercase */
    check("'a' -> 'A'", toupper('a') == 'A');
    check("'m' -> 'M'", toupper('m') == 'M');
    check("'z' -> 'Z'", toupper('z') == 'Z');

    /* Already uppercase - unchanged */
    check("'A' -> 'A'", toupper('A') == 'A');
    check("'Z' -> 'Z'", toupper('Z') == 'Z');

    /* Non-letters - unchanged */
    check("'0' -> '0'", toupper('0') == '0');
    check("' ' -> ' '", toupper(' ') == ' ');
    check("'@' -> '@'", toupper('@') == '@');
}

/* Test tolower function */
static void test_tolower(void)
{
    uart_printf("\n=== tolower ===\n");

    /* Uppercase to lowercase */
    check("'A' -> 'a'", tolower('A') == 'a');
    check("'M' -> 'm'", tolower('M') == 'm');
    check("'Z' -> 'z'", tolower('Z') == 'z');

    /* Already lowercase - unchanged */
    check("'a' -> 'a'", tolower('a') == 'a');
    check("'z' -> 'z'", tolower('z') == 'z');

    /* Non-letters - unchanged */
    check("'0' -> '0'", tolower('0') == '0');
    check("' ' -> ' '", tolower(' ') == ' ');
    check("'[' -> '['", tolower('[') == '[');
}

/* Test isspace function */
static void test_isspace(void)
{
    uart_printf("\n=== isspace ===\n");

    /* Whitespace characters */
    check("' ' is space", isspace(' ') != 0);
    check("'\\t' is space", isspace('\t') != 0);
    check("'\\n' is space", isspace('\n') != 0);
    check("'\\r' is space", isspace('\r') != 0);

    /* Non-whitespace */
    check("'a' not space", isspace('a') == 0);
    check("'0' not space", isspace('0') == 0);
    check("'\\0' not space", isspace('\0') == 0);
}

/* Test strtol function */
static void test_strtol(void)
{
    uart_printf("\n=== strtol ===\n");

    char *end;
    const char *input;

    /* Basic decimal */
    check("\"123\" base 10", strtol("123", NULL, 10) == 123);
    check("\"-456\" base 10", strtol("-456", NULL, 10) == -456);
    check("\"+789\" base 10", strtol("+789", NULL, 10) == 789);

    /* Leading whitespace */
    check("\"  42\" base 10", strtol("  42", NULL, 10) == 42);
    check("\" \\t-5\" base 10", strtol(" \t-5", NULL, 10) == -5);

    /* Hexadecimal */
    check("\"ff\" base 16", strtol("ff", NULL, 16) == 255);
    check("\"0xff\" base 16", strtol("0xff", NULL, 16) == 255);
    check("\"0XFF\" base 16", strtol("0XFF", NULL, 16) == 255);

    /* Octal */
    check("\"77\" base 8", strtol("77", NULL, 8) == 63);

    /* Binary */
    check("\"1010\" base 2", strtol("1010", NULL, 2) == 10);

    /* Auto-detect base (base 0) */
    check("\"123\" base 0", strtol("123", NULL, 0) == 123);
    check("\"0x1a\" base 0", strtol("0x1a", NULL, 0) == 26);
    check("\"077\" base 0", strtol("077", NULL, 0) == 63);
    check("\"0\" base 0", strtol("0", NULL, 0) == 0);
    check("\"z\" base 36", strtol("z", NULL, 36) == 35);

    /* End pointer */
    strtol("123abc", &end, 10);
    check("endptr at 'a'", *end == 'a');

    strtol("  -42xyz", &end, 10);
    check("endptr at 'x'", *end == 'x');

    input = "0x";
    strtol(input, &end, 0);
    check("incomplete hex parses zero", end == input + 1);

    input = "  -xyz";
    check("no digits returns zero", strtol(input, &end, 10) == 0);
    check("no digits endptr unchanged", end == input);

    input = "+";
    check("sign only returns zero", strtol(input, &end, 10) == 0);
    check("sign only endptr unchanged", end == input);

    input = "123";
    check("invalid base returns zero", strtol(input, &end, 1) == 0);
    check("invalid base endptr unchanged", end == input);

    /* Exact limits and overflow. LONG_MIN must not rely on signed overflow.
     * long is 64-bit on lp64. */
    check("LONG_MAX exact", strtol("9223372036854775807", NULL, 10) == LONG_MAX);
    check("LONG_MIN exact", strtol("-9223372036854775808", NULL, 10) == LONG_MIN);
    check("hex LONG_MIN exact", strtol("-0x8000000000000000", NULL, 0) == LONG_MIN);
    check("overflow pos", strtol("99999999999999999999", NULL, 10) == LONG_MAX);
    check("overflow neg", strtol("-99999999999999999999", NULL, 10) == LONG_MIN);
    check("overflow by one pos", strtol("9223372036854775808", NULL, 10) == LONG_MAX);
    check("overflow by one neg", strtol("-9223372036854775809", NULL, 10) == LONG_MIN);
}

/* Test atoi function */
static void test_atoi(void)
{
    uart_printf("\n=== atoi ===\n");

    check("\"0\"", atoi("0") == 0);
    check("\"42\"", atoi("42") == 42);
    check("\"-123\"", atoi("-123") == -123);
    check("\"  456\"", atoi("  456") == 456);
    check("\"789abc\"", atoi("789abc") == 789);
}

/* Test atol function */
static void test_atol(void)
{
    uart_printf("\n=== atol ===\n");

    check("\"0\"", atol("0") == 0L);
    check("\"42\"", atol("42") == 42L);
    check("\"-123\"", atol("-123") == -123L);
    check("\"  456\"", atol("  456") == 456L);
    check("\"789abc\"", atol("789abc") == 789L);
}

int main(void)
{
    uart_printf("String Library Test Suite\n");
    uart_printf("=========================\n");

    test_memset();
    test_memcpy();
    test_memmove();
    test_memcmp();
    test_strlen();
    test_strncpy();
    test_strcmp();
    test_strncmp();
    test_strchr();
    test_strstr();
    test_isdigit();
    test_isalpha();
    test_isupper();
    test_islower();
    test_toupper();
    test_tolower();
    test_isspace();
    test_strtol();
    test_atoi();
    test_atol();

    uart_printf("\n=========================\n");
    uart_printf("Results: %lu passed, %lu failed\n",
                (unsigned long) tests_passed,
                (unsigned long) tests_failed);

    if (tests_failed == 0) {
        uart_printf("ALL TESTS PASSED\n");
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("SOME TESTS FAILED\n");
        uart_printf("<<FAIL>>\n");
    }

    /* Halt */
    for (;;) {
    }
}
