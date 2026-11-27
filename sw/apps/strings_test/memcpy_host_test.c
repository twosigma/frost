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
 * Host-side harness: runs the exhaustive memcpy/memset checks on the in-tree
 * string.c (symbols renamed to frost_memcpy / frost_memset at link time) under
 * Spike, including a 1,048,113-byte copy that does not fit the simulated
 * memories. Exits with 0 on success. Driven by tests/test_libc_memcpy.py.
 */

#include "memcpy_check.h"

void *frost_memcpy(void *, const void *, size_t);
void *frost_memset(void *, int, size_t);

#define BIG_LEN 1048113u
#define BUF_BYTES (BIG_LEN + 2 * MEMCPY_CHECK_GUARD + 8)

static unsigned char src_buf[BUF_BYTES] __attribute__((aligned(16)));
static unsigned char dst_buf[BUF_BYTES] __attribute__((aligned(16)));

int main(void)
{
    uint32_t bad = 0;
    uint32_t cases = 0;
    for (size_t n = 0; n <= 80; n++) {
        bad += memcpy_check_one(frost_memcpy, src_buf, dst_buf, n);
        bad += memset_check_one(frost_memset, dst_buf, n);
        cases += 64 + 8;
    }
    bad += memcpy_check_one(frost_memcpy, src_buf, dst_buf, BIG_LEN);
    bad += memset_check_one(frost_memset, dst_buf, BIG_LEN);
    cases += 64 + 8;
    (void) cases;
    return bad != 0;
}
