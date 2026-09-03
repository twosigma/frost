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
 * stdlib.c: strtol for bases 2-36, plus base 0 for prefix detection (0x is
 * hex, a leading 0 is octal), with out-of-range results clamped to
 * LONG_MIN/LONG_MAX. Also its atoi/atol wrappers and abs().
 */

#include "stdlib.h"
#include "ctype.h"
#include "limits.h"

static int digit_value(unsigned char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'z')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z')
        return c - 'A' + 10;
    return -1;
}

/* Convert string to long integer. Invalid bases and strings containing no
 * digits return zero and leave endptr pointing at the original string. */
long strtol(const char *s, char **endptr, int base)
{
    const char *p = s;
    unsigned long result = 0;
    int negative = 0;
    int overflow = 0;
    int any_digits = 0;

    if (base != 0 && (base < 2 || base > 36)) {
        if (endptr != NULL)
            *endptr = (char *) s;
        return 0;
    }

    while (isspace(*p))
        p++;

    if (*p == '-') {
        negative = 1;
        p++;
    } else if (*p == '+') {
        p++;
    }

    /* A hexadecimal prefix is consumed only when at least one hexadecimal
     * digit follows it. This leaves "0x" parsed as the single digit zero. */
    if ((base == 0 || base == 16) && p[0] == '0' && (p[1] == 'x' || p[1] == 'X') &&
        digit_value((unsigned char) p[2]) >= 0 && digit_value((unsigned char) p[2]) < 16) {
        base = 16;
        p += 2;
    } else if (base == 0) {
        base = (*p == '0') ? 8 : 10;
    }

    /* Accumulate the magnitude in unsigned long. LONG_MIN has a magnitude one
     * greater than LONG_MAX, so a signed accumulator cannot represent it. */
    const unsigned long limit =
        negative ? (unsigned long) LONG_MAX + 1UL : (unsigned long) LONG_MAX;
    const unsigned long cutoff = limit / (unsigned int) base;
    const unsigned int cutlim = (unsigned int) (limit % (unsigned int) base);

    while (*p) {
        int digit = digit_value((unsigned char) *p);
        if (digit >= base)
            break;
        if (digit < 0)
            break;

        any_digits = 1;

        if (result > cutoff || (result == cutoff && (unsigned int) digit > cutlim)) {
            overflow = 1;
        } else {
            result = result * (unsigned int) base + (unsigned int) digit;
        }
        p++;
    }

    if (!any_digits) {
        if (endptr != NULL)
            *endptr = (char *) s;
        return 0;
    }

    if (endptr != NULL)
        *endptr = (char *) p;

    if (overflow)
        return negative ? LONG_MIN : LONG_MAX;

    if (!negative)
        return (long) result;
    if (result == (unsigned long) LONG_MAX + 1UL)
        return LONG_MIN;
    return -(long) result;
}

/* Convert string to integer */
int atoi(const char *s)
{
    return (int) strtol(s, NULL, 10);
}

/* Convert string to long */
long atol(const char *s)
{
    return strtol(s, NULL, 10);
}

/* Absolute value of an integer */
int abs(int n)
{
    return n < 0 ? -n : n;
}
