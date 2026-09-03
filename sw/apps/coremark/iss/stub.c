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

/* Freestanding support for the Spike harness: a printf sink plus the handful
 * of libc entry points GCC may synthesize calls to.  CoreMark's timed region
 * calls none of these; they exist so the link succeeds without newlib. */

#include <stddef.h>

int uart_printf(const char *format, ...)
{
    (void) format;
    return 0;
}

void *memcpy(void *destination, const void *source, size_t count)
{
    unsigned char *out = destination;
    const unsigned char *in = source;
    while (count--)
        *out++ = *in++;
    return destination;
}

void *memset(void *destination, int value, size_t count)
{
    unsigned char *out = destination;
    while (count--)
        *out++ = (unsigned char) value;
    return destination;
}

void *memmove(void *destination, const void *source, size_t count)
{
    unsigned char *out = destination;
    const unsigned char *in = source;
    if (out < in) {
        while (count--)
            *out++ = *in++;
    } else {
        out += count;
        in += count;
        while (count--)
            *--out = *--in;
    }
    return destination;
}

size_t strlen(const char *text)
{
    const char *cursor = text;
    while (*cursor)
        cursor++;
    return (size_t) (cursor - text);
}

char *strcpy(char *destination, const char *source)
{
    char *result = destination;
    while ((*destination++ = *source++))
        ;
    return result;
}

int strcmp(const char *left, const char *right)
{
    while (*left && *left == *right) {
        left++;
        right++;
    }
    return (int) (unsigned char) *left - (int) (unsigned char) *right;
}
