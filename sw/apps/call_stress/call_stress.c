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
 * Call stress: repeated and nested calls, built with the C extension.
 *
 * The source loops over calls up to three frames deep, checks the call count
 * after each loop, and makes printf calls into the UART library. noinline
 * keeps the local functions real calls at -O3, and each one counts itself
 * after its inner calls, so none of those calls becomes a tail call.
 */

#include "uart.h"

volatile int call_count = 0;
static int failures = 0;

__attribute__((noinline)) void simple_func(void)
{
    call_count++;
}

__attribute__((noinline)) void nested_func(void)
{
    simple_func();
    call_count++;
}

__attribute__((noinline)) void multi_nested(void)
{
    simple_func();
    nested_func();
    call_count++;
}

static void check_count(int want)
{
    if (call_count == want) {
        uart_puts("OK\n");
    } else {
        uart_printf("FAIL (count %d, want %d)\n", call_count, want);
        failures++;
    }
}

int main(void)
{
    uart_puts("Call stress test starting...\n");

    uart_puts("Test 1: 10 simple calls...");
    for (int i = 0; i < 10; i++) {
        simple_func();
    }
    check_count(10);

    uart_puts("Test 2: 10 nested calls...");
    for (int i = 0; i < 10; i++) {
        nested_func();
    }
    check_count(10 + 10 * 2);

    uart_puts("Test 3: 10 multi-nested calls...");
    for (int i = 0; i < 10; i++) {
        multi_nested();
    }
    check_count(10 + 10 * 2 + 10 * 4);

    uart_puts("Test 4: printf calls...\n");
    for (int i = 0; i < 5; i++) {
        uart_printf("  iteration %d\n", i);
    }
    uart_puts("OK\n");

    uart_puts("Test 5: format specifiers...\n");
    uart_printf("  int: %d\n", 12345);
    uart_printf("  hex: 0x%08x\n", 0xDEADBEEF);
    uart_printf("  str: %s\n", "hello");
    uart_puts("OK\n");

    uart_printf("\nTotal calls: %d\n", call_count);
    if (failures == 0) {
        uart_puts("\n*** ALL TESTS PASSED ***\n");
        uart_puts("<<PASS>>\n");
    } else {
        uart_puts("<<FAIL>>\n");
    }

    for (;;)
        ;
    return 0;
}
