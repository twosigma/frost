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

#ifndef LIMITS_H
#define LIMITS_H

/**
 * Integer limits for LP64: int is 32-bit, long is 64-bit.
 *
 * INT_MIN and LONG_MIN are written as (-MAX - 1) because the positive literals
 * 2147483648 and 9223372036854775808 do not fit in int and long.
 */

/* Limits for 32-bit signed/unsigned int */
#define INT_MIN (-2147483647 - 1)
#define INT_MAX 2147483647
#define UINT_MAX 4294967295U

/* Limits for 64-bit signed/unsigned long */
#define LONG_MIN (-9223372036854775807L - 1L)
#define LONG_MAX 9223372036854775807L
#define ULONG_MAX 18446744073709551615UL

#endif /* LIMITS_H */
