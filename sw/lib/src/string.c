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
 * String Functions (string.c)
 *
 * Minimal implementation of standard C string and memory functions for
 * bare-metal use. Provides memory operations (memset, memcpy) and string
 * operations (strlen, strncpy, strcmp, strncmp, strchr, strstr).
 *
 * These implementations prioritize correctness and code size over speed,
 * using simple byte-by-byte operations rather than word-sized optimizations.
 */

#include "string.h"

#include "memory.h"

#include <stdint.h>

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
 * Fast path writes one machine word at a time when the destination and length
 * are word-aligned; otherwise falls back to a byte fill. */
void *memset(void *dst, int c, size_t n)
{
    if ((((uintptr_t) dst | n) & (sizeof(uintptr_t) - 1)) == 0) {
        uintptr_t word = (unsigned char) c;
        word |= word << 8;
        word |= word << 16;
#if UINTPTR_MAX > 0xffffffffU
        word |= word << 32;
#endif
        uintptr_t *d = (uintptr_t *) dst;
        uintptr_t *end = (uintptr_t *) ((char *) dst + n);
        while (d < end)
            *d++ = word;
    } else {
        unsigned char *p = (unsigned char *) dst;
        while (n--)
            *p++ = (unsigned char) c;
    }
    frost_memory_write_fence();
    return dst;
}

/* Copy memory from source to destination.
 * Fast path copies machine words (8-word unrolled blocks) at a time when the
 * source, destination, and length are all word-aligned; otherwise falls back to
 * a byte copy. Roughly 4x fewer loads/stores than byte-wise for aligned bulk
 * copies. Does not handle overlap (use memmove for that). */
void *memcpy(void *dst, const void *src, size_t n)
{
    if ((((uintptr_t) dst | (uintptr_t) src | n) & (sizeof(uintptr_t) - 1)) == 0) {
        uintptr_t *d = (uintptr_t *) dst;
        const uintptr_t *s = (const uintptr_t *) src;
        uintptr_t *end = (uintptr_t *) ((char *) dst + n);
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
        unsigned char *d = (unsigned char *) dst;
        const unsigned char *s = (const unsigned char *) src;
        while (n--)
            *d++ = *s++;
    }
    frost_memory_write_fence();
    return dst;
}

/* Copy memory with overlap handling (safe for overlapping regions)
 * Unlike memcpy, memmove correctly handles cases where src and dst overlap.
 * If dst < src, copy forward; if dst > src, copy backward to avoid corruption.
 */
void *memmove(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;

    if (d < s) {
        /* Forward copy (same as memcpy) */
        while (n--) {
            *d++ = *s++;
        }
    } else if (d > s) {
        /* Backward copy to handle overlap */
        d += n;
        s += n;
        while (n--) {
            *--d = *--s;
        }
    }
    /* If d == s, no copy needed */
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

/* Calculate length of null-terminated string */
size_t strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return p - s; /* Pointer difference gives length */
}

/* Copy string with length limit, padding with nulls if needed */
char *strncpy(char *dst, const char *src, size_t n)
{
    size_t srclen = strlen(src);

    if (srclen < n) {
        /* Source is shorter: copy all of source, then pad with null bytes */
        memcpy(dst, src, srclen + 1);
        memset(dst + srclen + 1, '\0', n - srclen - 1);
    } else {
        /* Source is longer or equal: copy only n bytes (no null terminator) */
        memcpy(dst, src, n);
    }

    frost_memory_write_fence();
    return dst;
}

/* Compare two strings lexicographically */
int strcmp(const char *s1, const char *s2)
{
    while (*s1 != '\0' && *s1 == *s2) {
        s1++;
        s2++;
    }
    return (*(unsigned char *) s1 - *(unsigned char *) s2);
}

/* Compare up to n characters of two strings lexicographically */
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

/* Find first occurrence of character in string */
char *strchr(const char *s, int c)
{
    while (*s != '\0') {
        if (*s == (char) c)
            return (char *) s;
        s++;
    }
    return (c == '\0') ? (char *) s : NULL;
}

/* Find first occurrence of needle in haystack */
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

/* Calculate length of string, examining at most n bytes */
size_t strnlen(const char *s, size_t n)
{
    const char *p = s;
    while (n-- && *p)
        p++;
    return (size_t) (p - s);
}

/* Copy null-terminated string including terminator */
char *strcpy(char *dst, const char *src)
{
    char *d = dst;
    while ((*d++ = *src++))
        ;
    frost_memory_write_fence();
    return dst;
}

/* Append src to the end of dst */
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

/* Find last occurrence of character in string */
char *strrchr(const char *s, int c)
{
    const char *last = NULL;
    do {
        if (*s == (char) c)
            last = s;
    } while (*s++);
    return (char *) last;
}

/* Length of initial span of s consisting only of bytes in accept */
size_t strspn(const char *s, const char *accept)
{
    const char *p = s;
    while (*p && strchr(accept, *p) != NULL)
        p++;
    return (size_t) (p - s);
}

/* Length of initial span of s consisting of bytes not in reject */
size_t strcspn(const char *s, const char *reject)
{
    const char *p = s;
    while (*p && strchr(reject, *p) == NULL)
        p++;
    return (size_t) (p - s);
}

/* Find first occurrence in s of any byte from accept */
char *strpbrk(const char *s, const char *accept)
{
    for (; *s; s++)
        if (strchr(accept, *s) != NULL)
            return (char *) s;
    return NULL;
}

/* Duplicate a string into a freshly malloc'd buffer (caller frees) */
char *strdup(const char *s)
{
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p != NULL)
        memcpy(p, s, n);
    return p;
}
