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

/* Run only with FROST_WIDE_DDR_TEST's sparse simulation DDR, or a controller
 * with the selected amount of installed memory. This is a CPU-path test, not
 * a substitute for physical-controller or board validation. */
#include <stdint.h>
#include "uart.h"

#ifndef FROST_DDR_CAPACITY_LOG2_BYTES
#error FROST_DDR_CAPACITY_LOG2_BYTES must match the RTL build
#endif
#if FROST_DDR_CAPACITY_LOG2_BYTES < 30 || FROST_DDR_CAPACITY_LOG2_BYTES > 37
#error DDR aperture must be one of 1..128 GiB
#endif

#define DDR_BASE ((uintptr_t) 0x80000000ul)
#define DDR_BYTES ((uintptr_t) 1ul << FROST_DDR_CAPACITY_LOG2_BYTES)
#define DDR_END (DDR_BASE + DDR_BYTES)

int main(void)
{
    static const uint64_t patterns[3] = {
        0x0123456789abcdefull, 0xfedcba9876543210ull, 0x5a5aa5a5c3c33c3cull
    };
    const uintptr_t address[3] = {
        DDR_BASE + 0x2000ul,
        DDR_BASE + (DDR_BYTES >> 1) + 0x2000ul,
        DDR_END - 64ul
    };
    int failures = 0;

    for (unsigned i = 0; i < 3; ++i)
        *(volatile uint64_t *) address[i] = patterns[i];
    __asm__ volatile("fence rw,rw" ::: "memory");
    for (unsigned i = 0; i < 3; ++i) {
        uint64_t got = *(volatile uint64_t *) address[i];
        if (got != patterns[i]) {
            uart_printf("PA width load/store %u at 0x%lx failed\n",
                        i, (unsigned long) address[i]);
            failures++;
        }
    }

    /* Byte strobes at the final legal line must not alter another granule. */
    volatile uint8_t *last = (volatile uint8_t *) address[2];
    last[7] = 0x96u;
    uint64_t want = (patterns[2] & 0x00ffffffffffffffull) | 0x9600000000000000ull;
    if (*(volatile uint64_t *) address[2] != want) {
        uart_printf("PA width byte store at 0x%lx failed\n", (unsigned long) address[2]);
        failures++;
    }
    if (*(volatile uint64_t *) address[0] != patterns[0]) {
        uart_printf("PA width low-address alias failed\n");
        failures++;
    }

    /* AMO transport and writeback must retain all address bits. */
    uint64_t old;
    __asm__ volatile("amoadd.d %0, %2, (%1)" : "=r"(old)
                     : "r"(address[2]), "r"((uint64_t) 1) : "memory");
    if (old != want || *(volatile uint64_t *) address[2] != want + 1) {
        uart_printf("PA width AMO at 0x%lx failed\n", (unsigned long) address[2]);
        failures++;
    }

    uart_printf(failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
}
