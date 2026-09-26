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
 * A wrong-path WFI at the ROB head while commit-time recovery is pending.
 *
 * `jr t0` is a JALR that neither the BTB nor the return address stack
 * predicts, so it always mispredicts and recovers when it commits. Its target
 * comes out of a divide, so it resolves late and the front end dispatches the
 * WFIs after it, on the wrong path. When the jump retires, the first of them
 * is the ROB head in the cycle recovery is pending. cpu_ooo must not seed the
 * interrupt resume PC from that WFI: an interrupt taken before the first
 * target instruction retires would return past a WFI that never ran, onto
 * the wrong path. The bench (test_real_program, app wfi_seed_recovery)
 * watches for that head and checks the resume PC; this program only makes the
 * case happen, with and without a second divide in flight.
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
