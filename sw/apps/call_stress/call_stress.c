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
 * Compressed JAL/JALR carry their own encodings and PC-relative offset
 * fields, so this runs loops of calls and returns up to three frames deep
 * and prints the total call count at the end. The printf loops add calls
 * into the UART library on top of the local ones.
 */

#include "uart.h"

volatile int call_count = 0;

void simple_func(void)
{
    call_count++;
}

void nested_func(void)
{
    call_count++;
    simple_func();
}

void multi_nested(void)
{
    call_count++;
    simple_func();
    nested_func();
}

int main(void)
{
    uart_puts("Call stress test starting...\n");

    uart_puts("Test 1: 10 simple calls...");
    for (int i = 0; i < 10; i++) {
        simple_func();
    }
    uart_puts("OK\n");

    uart_puts("Test 2: 10 nested calls...");
    for (int i = 0; i < 10; i++) {
        nested_func();
    }
    uart_puts("OK\n");

    uart_puts("Test 3: 10 multi-nested calls...");
    for (int i = 0; i < 10; i++) {
        multi_nested();
    }
    uart_puts("OK\n");

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
    uart_puts("\n*** ALL TESTS PASSED ***\n");
    uart_puts("<<PASS>>\n");

    for (;;)
        ;
    return 0;
}
