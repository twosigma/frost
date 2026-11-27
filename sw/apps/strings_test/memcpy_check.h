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
 * Exhaustive memcpy and memset checks shared by strings_test (run in the RTL
 * simulation) and the host-side harness run under Spike.
 *
 * Every source and destination offset 0 to 7 is tried for each length. The
 * destination sits between guard bytes that must stay untouched, and the result
 * is compared with a plain byte copy (or fill) computed independently.
 */

#ifndef MEMCPY_CHECK_H
#define MEMCPY_CHECK_H

#include <stddef.h>
#include <stdint.h>

#define MEMCPY_CHECK_GUARD 16
#define MEMCPY_CHECK_SENTINEL 0xA5

typedef void *(*memcpy_fn_t)(void *, const void *, size_t);
typedef void *(*memset_fn_t)(void *, int, size_t);

/* Buffers must hold at least n + 2 * MEMCPY_CHECK_GUARD + 8 bytes each and be
 * 8-byte aligned. Returns the number of mismatching cases. */
static inline uint32_t memcpy_check_one(memcpy_fn_t copy,
                                        volatile unsigned char *src_buf,
                                        volatile unsigned char *dst_buf,
                                        size_t n)
{
    uint32_t bad = 0;
    for (unsigned so = 0; so < 8; so++) {
        for (unsigned dof = 0; dof < 8; dof++) {
            size_t span = n + 2 * MEMCPY_CHECK_GUARD + 8;
            for (size_t i = 0; i < span; i++) {
                src_buf[i] = (unsigned char) (i * 7u + 3u);
                dst_buf[i] = MEMCPY_CHECK_SENTINEL;
            }
            volatile unsigned char *s = src_buf + MEMCPY_CHECK_GUARD + so;
            volatile unsigned char *d = dst_buf + MEMCPY_CHECK_GUARD + dof;
            void *ret = copy((void *) d, (const void *) s, n);
            int ok = (ret == (void *) d);
            for (size_t i = 0; i < span && ok; i++) {
                size_t lo = MEMCPY_CHECK_GUARD + dof;
                unsigned char want = MEMCPY_CHECK_SENTINEL;
                if (i >= lo && i < lo + n)
                    want = src_buf[MEMCPY_CHECK_GUARD + so + (i - lo)];
                if (dst_buf[i] != want)
                    ok = 0;
            }
            bad += !ok;
        }
    }
    return bad;
}

static inline uint32_t memset_check_one(memset_fn_t fill, volatile unsigned char *dst_buf, size_t n)
{
    uint32_t bad = 0;
    for (unsigned dof = 0; dof < 8; dof++) {
        size_t span = n + 2 * MEMCPY_CHECK_GUARD + 8;
        for (size_t i = 0; i < span; i++)
            dst_buf[i] = MEMCPY_CHECK_SENTINEL;
        volatile unsigned char *d = dst_buf + MEMCPY_CHECK_GUARD + dof;
        void *ret = fill((void *) d, 0x5A, n);
        int ok = (ret == (void *) d);
        size_t lo = MEMCPY_CHECK_GUARD + dof;
        for (size_t i = 0; i < span && ok; i++) {
            unsigned char want = (i >= lo && i < lo + n) ? 0x5A : MEMCPY_CHECK_SENTINEL;
            if (dst_buf[i] != want)
                ok = 0;
        }
        bad += !ok;
    }
    return bad;
}

#endif /* MEMCPY_CHECK_H */
