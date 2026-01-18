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

/* Fill memory region with specified byte value */
void *memset(void *dst, int c, size_t n)
{
    unsigned char *p = dst;
    while (n--) {
        *p++ = (unsigned char) c;
    }
    return dst;
}

/* Copy memory from source to destination */
void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) {
        *d++ = *s++;
    }
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
    if (n == 0) {
        return dst;
    }
    
    size_t i;
    for (i = 0; i < n && src[i] != '\0'; i++) {
        dst[i] = src[i];
    }
    
    /* Pad remaining bytes with null characters */
    for (; i < n; i++) {
        dst[i] = '\0';
    }
    
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
