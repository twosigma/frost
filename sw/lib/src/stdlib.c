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
 * Standard Library Functions (stdlib.c)
 *
 * Minimal implementation of standard C library functions for bare-metal use.
 * Provides string-to-number conversion with full base support and overflow
 * detection.
 */

#include "stdlib.h"
#include "ctype.h"
#include "limits.h"

/* Convert string to long integer */
long strtol(const char *s, char **endptr, int base)
{
    const char *p = s;
    long result = 0;
    int negative = 0;
    int overflow = 0;
    long cutoff;
    int cutlim;

    /* Skip leading whitespace */
    while (isspace(*p))
        p++;

    /* Handle sign */
    if (*p == '-') {
        negative = 1;
        p++;
    } else if (*p == '+') {
        p++;
    }

    /* Auto-detect base if base is 0 */
    if (base == 0) {
        if (*p == '0') {
            p++;
            if (*p == 'x' || *p == 'X') {
                base = 16;
                p++;
            } else {
                base = 8;
            }
        } else {
            base = 10;
        }
    } else if (base == 16) {
        /* Skip optional 0x/0X prefix for hex */
        if (*p == '0' && (*(p + 1) == 'x' || *(p + 1) == 'X'))
            p += 2;
    }

    /* Set up overflow detection */
    cutoff = negative ? -(LONG_MIN / base) : LONG_MAX / base;
    cutlim = negative ? -(int) (LONG_MIN % base) : (int) (LONG_MAX % base);

    /* Parse digits */
    while (*p) {
        int digit;

        if (isdigit(*p))
            digit = *p - '0';
        else if (isalpha(*p))
            digit = tolower(*p) - 'a' + 10;
        else
            break;

        if (digit >= base)
            break;

        /* Check for overflow */
        if (result > cutoff || (result == cutoff && digit > cutlim)) {
            overflow = 1;
        } else {
            result = result * base + digit;
        }
        p++;
    }

    /* Set endptr if provided */
    if (endptr)
        *endptr = (char *) p;

    /* Handle overflow */
    if (overflow)
        return negative ? LONG_MIN : LONG_MAX;

    return negative ? -result : result;
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
