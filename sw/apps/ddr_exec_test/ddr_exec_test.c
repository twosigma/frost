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
 * Execute-from-DDR test
 *
 * Places functions in the cached region (.ddr_text, at CACHED_BASE =
 * 0x8000_0000) and runs them through the instruction-side path: fetch
 * provider -> two-line fetch buffer -> L1I -> arbiter -> (L2 ->) main
 * memory. Code here is deliberately branchy, call-heavy and loopy so the
 * fetch buffer's straddle/prefetch handling, the BTB/RAS over DDR PCs, and
 * the L1I miss/fill round trips all get exercised; the compiler's usual RVC
 * mix gives halfword-aligned and line-straddling 32-bit instructions for
 * free.
 *
 * What it checks:
 *   - A leaf function in DDR returns correct results (basic fetch path).
 *   - A loopy/branchy DDR function computes a known checksum (sustained
 *     fetch from the buffer, back-edges over DDR PCs).
 *   - Cross-quadrant calls: DDR code calling back into low-BRAM code and
 *     returning (RAS across the quadrant boundary both ways).
 *   - Recursion in DDR (call/return depth through the L1I).
 *   - A function body larger than the two-line fetch buffer (sequential
 *     misses + next-line prefetch over many lines).
 *   - Repeat runs after the working set has been through the L1I once
 *     (hit-path results must match the cold-path results).
 *
 * Prints "<<PASS>>" if every check matches, otherwise "<<FAIL>>".
 */

#include "../../lib/include/uart.h"

#define DDR_TEXT __attribute__((section(".ddr_text"), noinline))

/* Low-BRAM helper called FROM DDR code (cross-quadrant call/return). */
__attribute__((noinline)) static int bram_scale(int x)
{
    return 3 * x + 1;
}

/* Leaf in DDR: basic execute-from-DDR. */
DDR_TEXT static int ddr_add(int a, int b)
{
    return a + b;
}

/* Branchy/loopy checksum in DDR. */
DDR_TEXT static unsigned ddr_checksum(unsigned seed, int rounds)
{
    unsigned acc = seed;
    for (int i = 0; i < rounds; i++) {
        if (acc & 1u) {
            acc = (acc >> 1) ^ 0xEDB88320u;
        } else {
            acc = (acc >> 1) + ((unsigned) i << 3);
        }
        if ((i & 7) == 3) {
            acc += 0x9E3779B9u;
        }
    }
    return acc;
}

/* DDR function that calls back into low BRAM each iteration. */
DDR_TEXT static int ddr_calls_bram(int n)
{
    int total = 0;
    for (int i = 1; i <= n; i++) {
        total += bram_scale(i);
    }
    return total;
}

/* Recursion entirely within DDR (stack stays in low BRAM as always). */
DDR_TEXT static int ddr_fib(int n)
{
    if (n < 2) {
        return n;
    }
    return ddr_fib(n - 1) + ddr_fib(n - 2);
}

/* A body long enough to span many 32-byte lines: sequential fetch misses
 * with next-line prefetch. The unrolled chain keeps the compiler from
 * shrinking it below a few hundred bytes. */
#define STEP(k)                                                                                    \
    do {                                                                                           \
        v = (v ^ (k)) + ((k) * 7);                                                                 \
        v = (v << 1) | (v >> 31);                                                                  \
    } while (0)

DDR_TEXT static unsigned ddr_long_body(unsigned v)
{
    STEP(0x01);
    STEP(0x02);
    STEP(0x03);
    STEP(0x04);
    STEP(0x05);
    STEP(0x06);
    STEP(0x07);
    STEP(0x08);
    STEP(0x09);
    STEP(0x0A);
    STEP(0x0B);
    STEP(0x0C);
    STEP(0x0D);
    STEP(0x0E);
    STEP(0x0F);
    STEP(0x10);
    STEP(0x11);
    STEP(0x12);
    STEP(0x13);
    STEP(0x14);
    STEP(0x15);
    STEP(0x16);
    STEP(0x17);
    STEP(0x18);
    STEP(0x19);
    STEP(0x1A);
    STEP(0x1B);
    STEP(0x1C);
    STEP(0x1D);
    STEP(0x1E);
    STEP(0x1F);
    STEP(0x20);
    STEP(0x21);
    STEP(0x22);
    STEP(0x23);
    STEP(0x24);
    STEP(0x25);
    STEP(0x26);
    STEP(0x27);
    STEP(0x28);
    STEP(0x29);
    STEP(0x2A);
    STEP(0x2B);
    STEP(0x2C);
    STEP(0x2D);
    STEP(0x2E);
    STEP(0x2F);
    STEP(0x30);
    return v;
}

/* Reference computations compiled into LOW-BRAM text: must match the DDR
 * versions exactly. Marked noinline so each is a genuinely separate body. */
__attribute__((noinline)) static unsigned ref_checksum(unsigned seed, int rounds)
{
    unsigned acc = seed;
    for (int i = 0; i < rounds; i++) {
        if (acc & 1u) {
            acc = (acc >> 1) ^ 0xEDB88320u;
        } else {
            acc = (acc >> 1) + ((unsigned) i << 3);
        }
        if ((i & 7) == 3) {
            acc += 0x9E3779B9u;
        }
    }
    return acc;
}

__attribute__((noinline)) static unsigned ref_long_body(unsigned v)
{
    STEP(0x01);
    STEP(0x02);
    STEP(0x03);
    STEP(0x04);
    STEP(0x05);
    STEP(0x06);
    STEP(0x07);
    STEP(0x08);
    STEP(0x09);
    STEP(0x0A);
    STEP(0x0B);
    STEP(0x0C);
    STEP(0x0D);
    STEP(0x0E);
    STEP(0x0F);
    STEP(0x10);
    STEP(0x11);
    STEP(0x12);
    STEP(0x13);
    STEP(0x14);
    STEP(0x15);
    STEP(0x16);
    STEP(0x17);
    STEP(0x18);
    STEP(0x19);
    STEP(0x1A);
    STEP(0x1B);
    STEP(0x1C);
    STEP(0x1D);
    STEP(0x1E);
    STEP(0x1F);
    STEP(0x20);
    STEP(0x21);
    STEP(0x22);
    STEP(0x23);
    STEP(0x24);
    STEP(0x25);
    STEP(0x26);
    STEP(0x27);
    STEP(0x28);
    STEP(0x29);
    STEP(0x2A);
    STEP(0x2B);
    STEP(0x2C);
    STEP(0x2D);
    STEP(0x2E);
    STEP(0x2F);
    STEP(0x30);
    return v;
}

int main(void)
{
    int failures = 0;

    /* Cold pass (L1I misses) and a warm pass (L1I hits) must agree. */
    for (int pass = 0; pass < 2; pass++) {
        if (ddr_add(1234, 4321) != 5555) {
            uart_printf("FAIL: ddr_add pass %d\n", pass);
            failures++;
        }

        unsigned got = ddr_checksum(0xDEADBEEFu, 257);
        unsigned want = ref_checksum(0xDEADBEEFu, 257);
        if (got != want) {
            uart_printf("FAIL: ddr_checksum pass %d got %x want %x\n", pass, got, want);
            failures++;
        }

        /* sum of 3i+1 for i in 1..40 = 3*820 + 40 = 2500 */
        if (ddr_calls_bram(40) != 2500) {
            uart_printf("FAIL: ddr_calls_bram pass %d\n", pass);
            failures++;
        }

        if (ddr_fib(13) != 233) {
            uart_printf("FAIL: ddr_fib pass %d\n", pass);
            failures++;
        }

        unsigned long_got = ddr_long_body(0x13572468u);
        unsigned long_want = ref_long_body(0x13572468u);
        if (long_got != long_want) {
            uart_printf("FAIL: ddr_long_body pass %d got %x want %x\n", pass, long_got, long_want);
            failures++;
        }
    }

    if (failures == 0) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>> (%d failures)\n", failures);
    }

    while (1) {
    }
    return 0;
}
