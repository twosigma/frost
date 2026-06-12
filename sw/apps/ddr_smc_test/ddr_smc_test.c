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
 * Self-modifying code / fence.i test
 *
 * Stores instruction words into a DDR buffer and executes them, with a
 * fence.i between write and call. This is the full fence.i contract
 * end-to-end:
 *
 *   stores -> SQ -> L1D (dirty)              ... the new code is invisible
 *   fence.i: SQ drain -> L1D writeback-all   ... pushed below the arbiter
 *            -> L1I invalidate-all           ... stale lines dropped
 *            -> fetch-buffer invalidate      ... stale window dropped
 *   call    -> L1I miss -> fill returns the freshly written code
 *
 * Each round rewrites the SAME buffer with a different constant and calls
 * it twice (a post-fence cold fetch, then a warm L1I hit). Rounds 2+ are
 * the real test: by then the buffer's line is hot in the L1I and the fetch
 * buffer, and only a correct sync chain makes the call return the new
 * constant instead of the cached old code.
 *
 * Prints "<<PASS>>" if every call returns its round's constant.
 */

#include <stdint.h>

#include "../../lib/include/uart.h"

/* Writable buffer in the cached DDR region (the L1I steers by address, so
 * code in .ddr_data fetches exactly like .ddr_text). Line-aligned so each
 * round dirties a single, known L1D line. */
__attribute__((section(".ddr_data"), aligned(32))) static volatile uint32_t ddr_code[8];

typedef int (*const_fn_t)(void);

/* Emit { addi a0, x0, imm; jalr x0, 0(ra) } into the buffer and sync.
 * imm must fit addi's signed 12-bit immediate. */
static void write_const_fn(uint32_t imm)
{
    ddr_code[0] = 0x00000513u | (imm << 20); /* addi a0, x0, imm */
    ddr_code[1] = 0x00008067u;               /* ret */
    __asm__ volatile("fence.i" ::: "memory");
}

int main(void)
{
    static const uint32_t constants[] = {11, 0x2A, 0x355};
    int failures = 0;

    for (int round = 0; round < 3; round++) {
        uint32_t want = constants[round];
        write_const_fn(want);

        const_fn_t fn = (const_fn_t) (uintptr_t) &ddr_code[0];
        int cold = fn();
        if (cold != (int) want) {
            uart_printf("FAIL: round %d cold call got %d want %d\n", round, cold, (int) want);
            failures++;
        }

        int warm = fn(); /* second call fetches from a warm L1I */
        if (warm != (int) want) {
            uart_printf("FAIL: round %d warm call got %d want %d\n", round, warm, (int) want);
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
