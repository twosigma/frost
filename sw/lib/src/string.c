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
 * string.c: the subset of the C library's memory and string functions this
 * bare-metal build needs.
 *
 * The string functions are byte-by-byte loops, written for code size rather
 * than speed. memset and memcpy copy whole words in the aligned middle of the
 * region, whatever its length, with byte head and tail; memmove is always
 * byte-wise.
 */

#include "string.h"

#include "memory.h"

#include <stdint.h>

/* A machine word that may alias any object, so the word accesses below stay
 * correct whatever the strict-aliasing flags are. */
typedef uintptr_t __attribute__((may_alias)) frost_word_t;

/* Diagnostic build switch: FROST_MEMORY_FENCE_WRITES=1 adds a fence rw, rw at
 * the end of every function here that writes memory. */
#ifndef FROST_MEMORY_FENCE_WRITES
#define FROST_MEMORY_FENCE_WRITES 0
#endif

#if FROST_MEMORY_FENCE_WRITES
static inline void frost_memory_write_fence(void)
{
    __asm__ volatile("fence rw, rw" ::: "memory");
}
#else
static inline void frost_memory_write_fence(void) {}
#endif

/* Fill memory region with specified byte value.
 * Head bytes up to the first word boundary, then whole words, then the tail
 * bytes, so a length that is not a multiple of the word size still takes the
 * word path. */
void *memset(void *dst, int c, size_t n)
{
    unsigned char *p = (unsigned char *) dst;
    while (n != 0 && ((uintptr_t) p & (sizeof(uintptr_t) - 1)) != 0) {
        *p++ = (unsigned char) c;
        n--;
    }
    uintptr_t word = (unsigned char) c;
    word |= word << 8;
    word |= word << 16;
#if UINTPTR_MAX > 0xffffffffU
    word |= word << 32;
#endif
    frost_word_t *d = (frost_word_t *) p;
    size_t words = n / sizeof(uintptr_t);
    while (words--)
        *d++ = word;
    p = (unsigned char *) d;
    n &= sizeof(uintptr_t) - 1;
    while (n--)
        *p++ = (unsigned char) c;
    frost_memory_write_fence();
    return dst;
}

/* Copy memory from source to destination.
 * When source and destination are congruent modulo the word size, copy head
 * bytes up to the first word boundary, then machine words in 8-word unrolled
 * blocks, then the tail bytes. The length does not matter: an odd length still
 * takes the word path. Copies whose pointers differ in word phase are
 * byte-wise. Does not handle overlap (use memmove for that). */
void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *) dst;
    const unsigned char *s = (const unsigned char *) src;
    if ((((uintptr_t) d ^ (uintptr_t) s) & (sizeof(uintptr_t) - 1)) == 0) {
        while (n != 0 && ((uintptr_t) d & (sizeof(uintptr_t) - 1)) != 0) {
            *d++ = *s++;
            n--;
        }
        frost_word_t *dw = (frost_word_t *) d;
        const frost_word_t *sw = (const frost_word_t *) s;
        size_t words = n / sizeof(uintptr_t);
        for (; words >= 8; words -= 8) {
            uintptr_t reg[8] = {sw[0], sw[1], sw[2], sw[3], sw[4], sw[5], sw[6], sw[7]};
            dw[0] = reg[0];
            dw[1] = reg[1];
            dw[2] = reg[2];
            dw[3] = reg[3];
            dw[4] = reg[4];
            dw[5] = reg[5];
            dw[6] = reg[6];
            dw[7] = reg[7];
            dw += 8;
            sw += 8;
        }
        while (words--)
            *dw++ = *sw++;
        d = (unsigned char *) dw;
        s = (const unsigned char *) sw;
        n &= sizeof(uintptr_t) - 1;
    }
    while (n--)
        *d++ = *s++;
    frost_memory_write_fence();
    return dst;
}

/* Copy memory between regions that may overlap. If dst < src, copy forward;
 * if dst > src, copy backward so no source byte is overwritten before it is
 * read. */
void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;

    if (d < s) {
        while (n--) {
            *d++ = *s++;
        }
    } else if (d > s) {
        d += n;
        s += n;
        while (n--) {
            *--d = *--s;
        }
    }
    frost_memory_write_fence();
    return dst;
}

/* Compare two memory regions byte-by-byte
 * Returns: 0 if equal, <0 if s1 < s2, >0 if s1 > s2
 */
int memcmp(const void *s1, const void *s2, size_t n)
{
    const unsigned char *p1 = s1;
    const unsigned char *p2 = s2;

    while (n--) {
        if (*p1 != *p2) {
            return *p1 - *p2;
        }
        p1++;
        p2++;
    }
    return 0;
}

size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return p - s;
}

/* Copy at most n bytes from src, padding with nulls after an in-range
 * terminator. The source only needs to be readable through the first n bytes;
 * in particular, do not use an unbounded strlen() to choose the copy length. */
char *strncpy(char *dst, const char *src, size_t n)
{
    size_t i = 0;

    while (i < n && src[i] != '\0') {
        dst[i] = src[i];
        i++;
    }
    while (i < n)
        dst[i++] = '\0';

    frost_memory_write_fence();
    return dst;
}

int strcmp(const char *s1, const char *s2)
{
    while (*s1 != '\0' && *s1 == *s2) {
        s1++;
        s2++;
    }
    return (*(unsigned char *) s1 - *(unsigned char *) s2);
}

int strncmp(const char *s1, const char *s2, size_t n)
{
    while (n > 0 && *s1 != '\0' && *s1 == *s2) {
        s1++;
        s2++;
        n--;
    }
    if (n == 0)
        return 0;
    return (*(unsigned char *) s1 - *(unsigned char *) s2);
}

char *strchr(const char *s, int c)
{
    while (*s != '\0') {
        if (*s == (char) c)
            return (char *) s;
        s++;
    }
    return (c == '\0') ? (char *) s : NULL;
}

char *strstr(const char *haystack, const char *needle)
{
    const size_t nlen = strlen(needle);
    const char *p = haystack;

    if (!nlen)
        return (char *) haystack;

    while ((p = strchr(p, *needle)) != NULL) {
        if (strncmp(p, needle, nlen) == 0)
            return (char *) p;
        p++;
    }
    return NULL;
}

size_t strnlen(const char *s, size_t n)
{
    const char *p = s;
    while (n-- && *p)
        p++;
    return (size_t) (p - s);
}

char *strcpy(char *dst, const char *src)
{
    char *d = dst;
    while ((*d++ = *src++))
        ;
    frost_memory_write_fence();
    return dst;
}

char *strcat(char *dst, const char *src)
{
    char *d = dst;
    while (*d)
        d++;
    while ((*d++ = *src++))
        ;
    frost_memory_write_fence();
    return dst;
}

char *strrchr(const char *s, int c)
{
    const char *last = NULL;
    do {
        if (*s == (char) c)
            last = s;
    } while (*s++);
    return (char *) last;
}

size_t strspn(const char *s, const char *accept)
{
    const char *p = s;
    while (*p && strchr(accept, *p) != NULL)
        p++;
    return (size_t) (p - s);
}

size_t strcspn(const char *s, const char *reject)
{
    const char *p = s;
    while (*p && strchr(reject, *p) == NULL)
        p++;
    return (size_t) (p - s);
}

char *strpbrk(const char *s, const char *accept)
{
    for (; *s; s++)
        if (strchr(accept, *s) != NULL)
            return (char *) s;
    return NULL;
}

char *strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p != NULL)
        memcpy(p, s, n);
    return p;
}
