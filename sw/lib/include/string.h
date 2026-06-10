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

#ifndef STRING_H
#define STRING_H

#include <stddef.h>

/* Minimal string and memory manipulation functions for bare-metal C programs */

/* Fill memory region with specified byte value */
void *memset(void *dst, int c, size_t n);

/* Copy memory from source to destination */
void *memcpy(void *dst, const void *src, size_t n);

/* Copy memory with overlap handling (safe for overlapping regions) */
void *memmove(void *dst, const void *src, size_t n);

/* Compare two memory regions byte-by-byte */
int memcmp(const void *s1, const void *s2, size_t n);

/* Calculate length of null-terminated string */
size_t strlen(const char *s);

/* Copy string with length limit, padding with nulls if needed */
char *strncpy(char *dst, const char *src, size_t n);

/* Compare two strings lexicographically */
int strcmp(const char *s1, const char *s2);

/* Compare up to n characters of two strings lexicographically */
int strncmp(const char *s1, const char *s2, size_t n);

/* Find first occurrence of character in string */
char *strchr(const char *s, int c);

/* Find first occurrence of needle in haystack */
char *strstr(const char *haystack, const char *needle);

/* Calculate length of string, examining at most n bytes */
size_t strnlen(const char *s, size_t n);

/* Copy null-terminated string including terminator */
char *strcpy(char *dst, const char *src);

/* Append src to the end of dst */
char *strcat(char *dst, const char *src);

/* Find last occurrence of character in string */
char *strrchr(const char *s, int c);

/* Length of initial span of s consisting only of bytes in accept */
size_t strspn(const char *s, const char *accept);

/* Length of initial span of s consisting of bytes not in reject */
size_t strcspn(const char *s, const char *reject);

/* Find first occurrence in s of any byte from accept */
char *strpbrk(const char *s, const char *accept);

/* Duplicate a string into a freshly malloc'd buffer (caller frees) */
char *strdup(const char *s);

#endif /* STRING_H */
