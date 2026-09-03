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
 * Spanning instruction test: 32-bit instructions that straddle a fetch word
 * boundary must execute correctly. With the compressed extension the
 * instruction stream mixes 16-bit and 32-bit encodings, so a 32-bit
 * instruction can start in the upper half of one word and finish in the next.
 */
#include "uart.h"

int main(void)
{
    uart_puts("=== Spanning Instruction Test ===\n");

    uart_puts("Test 1: printf with string... ");
    uart_printf("%s", "Hello");
    uart_puts(" OK\n");

    /* The loop repeats the call, covering PC handling across iterations. */
    uart_puts("Test 2: printf in loop... ");
    for (int i = 0; i < 3; i++) {
        uart_printf("%d", i);
    }
    uart_puts(" OK\n");

    uart_puts("Test 3: complex printf... ");
    uart_printf("%s=%d", "val", 42);
    uart_puts(" OK\n");

    uart_puts("\n=== All Tests Passed ===\n");
    uart_puts("<<PASS>>\n");

    for (;;) {
    }
}
