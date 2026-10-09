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
 * Delay an indirect jump's target through a divide so wrong-path WFIs can
 * dispatch behind it. When the jump retires with recovery pending, a WFI
 * may reach the ROB head. It must not seed the interrupt resume PC: a trap
 * before the target's first retirement would otherwise resume on the wrong
 * path. A second divide runs at the target.
 *
 * This program supplies the sequence; verif/cocotb_tests/test_real_program.py
 * checks the WFI head and resume PC.
 */

#include <stdint.h>

#include "uart.h"

#define ITERATIONS 64u

int main(void)
{
    uint64_t one = 1;

    uart_printf("\n=== wrong-path WFI recovery test ===\n");
    for (uint32_t i = 0; i < ITERATIONS; i++) {
        uint64_t target = 0;
        uint64_t scratch = 0;
        __asm__ volatile(".option push\n.option norvc\n"
                         "la    %[tgt], 1f\n"
                         "div   %[tgt], %[tgt], %[one]\n"
                         "jr    %[tgt]\n"
                         "wfi\n"
                         "wfi\n"
                         "wfi\n"
                         "1:\n"
                         "div   %[scr], %[tgt], %[one]\n"
                         ".option pop\n"
                         : [tgt] "=&r"(target), [scr] "=&r"(scratch)
                         : [one] "r"(one)
                         : "memory");
        (void) scratch;
    }
    uart_printf("jumps: %u\n<<PASS>>\n", ITERATIONS);
    for (;;) {
    }
    return 0;
}
