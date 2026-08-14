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
 * Integer Limits (limits.h)
 *
 * Defines minimum and maximum values for integer types on this platform:
 * int is 32-bit; long is 64-bit at lp64.
 *
 * Note: INT_MIN is defined as (-INT_MAX - 1) to avoid overflow issues
 * in the constant expression itself.
 */

/* Limits for 32-bit signed/unsigned int (both ABIs) */
#define INT_MIN (-2147483647 - 1)
#define INT_MAX 2147483647
#define UINT_MAX 4294967295U

/* Limits for long: ABI-width (lp64: 64-bit) */
#define LONG_MIN (-9223372036854775807L - 1L)
#define LONG_MAX 9223372036854775807L
#define ULONG_MAX 18446744073709551615UL

#endif /* LIMITS_H */
