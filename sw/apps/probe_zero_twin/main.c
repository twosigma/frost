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

/*
 * cbo.zero writes its 64-byte block as two 32-byte records in the L1D's
 * store buffer; the upper record (the twin) waits for a free record while
 * the buffer is full. Until it is recorded, no load of either sector may
 * reach the L1D. Here three cold stores fill the buffer ahead of the
 * cbo.zero, and a load of the upper sector follows it after a delay that
 * sweeps the twin's wait, so the load is staged, and probes the store
 * queue, while the twin waits. Each load must read zeros. The L1D's
 * assertions check the order in assertion builds.
 */

#include <stdint.h>

#include "uart.h"

#define PATTERN 0x5A5A3C3CF00F4321ul
/* Untouched cached DDR, apart from the program's own sections. */
#define BLOCKS 0x83000000ul
#define STORES 0x83400000ul
#define CASES 24

int main(void)
{
    int ok = 1;
    for (unsigned long k = 0; k < CASES; k++) {
        volatile uint64_t *block = (volatile uint64_t *) (BLOCKS + k * 0x1000ul);
        unsigned long stores = STORES + k * 0x1000ul;
        unsigned long iters = 4 + 4 * k;
        uint64_t got;
        block[4] = PATTERN;
        __asm__ volatile("fence rw, rw" ::: "memory");
        __asm__ volatile("ld t0, 32(%[b])\n"
                         "fence rw, rw\n"
                         "sd zero, 0(%[s])\n"
                         "sd zero, 64(%[s])\n"
                         "sd zero, 128(%[s])\n"
                         ".insn i 0x0F, 2, x0, %[b], 4\n" /* cbo.zero (%[b]) */
                         "mv t1, %[n]\n"
                         "1: addi t1, t1, -1\n"
                         "bnez t1, 1b\n"
                         "ld %[g], 32(%[b])\n"
                         : [g] "=&r"(got)
                         : [b] "r"(block), [s] "r"(stores), [n] "r"(iters)
                         : "t0", "t1", "memory");
        if (got != 0) {
            uart_printf("case %lu: upper sector read %lx, expected 0\n", k, (unsigned long) got);
            ok = 0;
        }
    }
    uart_puts(ok ? "\r\n<<PASS>>\r\n" : "\r\n<<FAIL>>\r\n");
    for (;;) {
    }
}
