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

#ifndef LIB_SPRINTF_H
#define LIB_SPRINTF_H

/*
 * sprintf.h
 * Custom implementation of sprintf / snprintf
 *
 * Supported conversions:
 *   %d / %i   signed decimal integer
 *   %u        unsigned decimal integer
 *   %o        unsigned octal integer
 *   %x / %X  unsigned hex integer (lower / upper)
 *   %f        decimal floating-point  ([-]ddd.dddddd)
 *   %e / %E  scientific notation     ([-]d.ddde±dd)
 *   %g / %G  shorter of %f / %e
 *   %c        character
 *   %s        NUL-terminated string
 *   %p        pointer (0x…)
 *   %%        literal '%'
 *
 * Flags:   - + space 0 #
 * Width:   decimal integer or *
 * Precision: .decimal integer or .*
 * Length modifiers: h  hh  l  ll  z  t
 */

#include <stdarg.h>
#include <stddef.h>

/**
 * sprintf  – format into an unbounded buffer (caller must ensure space).
 * Returns the number of characters written (excluding the NUL terminator),
 * or a negative value on error.
 */
int sprintf(char *buf, const char *fmt, ...);

/**
 * snprintf – format into at most (size-1) characters + NUL.
 * Always NUL-terminates when size > 0.
 * Returns the number of characters that *would* have been written had the
 * buffer been large enough (excluding NUL), matching C99 semantics.
 */
int snprintf(char *buf, size_t size, const char *fmt, ...);

/* va_list variants for layering */
int vsprintf(char *buf, const char *fmt, va_list ap);
int vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);

#endif /* LIB_SPRINTF_H */
