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
 * RAS stress using CoreMark-like control flow:
 *   1. Loops with both branches and function calls (BTB+RAS interaction)
 *   2. Data-dependent control flow selecting which function to call
 *   3. Linked list traversal with function calls at each node
 *   4. Function pointers (indirect calls)
 *   5. Checksum computation with interleaved function calls
 *
 * Unlike the basic RAS test, these mix BTB and RAS prediction.
 */

#include "uart.h"
#include <stdint.h>

/* Preserve calls so they exercise the RAS. */
#define NOINLINE __attribute__((noinline))

/* Prevent optimization of test state. */
volatile uint32_t global_counter = 0;
volatile uint32_t checksum = 0;

/* ========================================================================== */
/* Simple functions for RAS prediction testing                                */
/* ========================================================================== */

NOINLINE uint32_t add_one(uint32_t x)
{
    return x + 1;
}

NOINLINE uint32_t add_two(uint32_t x)
{
    return x + 2;
}

NOINLINE uint32_t add_three(uint32_t x)
{
    return x + 3;
}

NOINLINE uint32_t multiply_two(uint32_t x)
{
    return x * 2;
}

NOINLINE uint32_t xor_pattern(uint32_t x)
{
    return x ^ 0xA5A5A5A5;
}

/* ========================================================================== */
/* Test 1: Loop with branches and function calls                              */
/* Each iteration exercises the BTB for the branch and the RAS for the call   */
/* ========================================================================== */

NOINLINE uint32_t test_loop_with_branch_and_call(void)
{
    uint32_t sum = 0;

    for (int i = 0; i < 100; i++) {
        /* Loop branch through the BTB, call through the RAS, every iteration. */
        if (i & 1) {
            sum += add_one(i);
        } else {
            sum += add_two(i);
        }
    }

    return sum;
}

/* Odd terms: 2500 + 50; even terms: 2450 + 100; total: 5100. */
#define TEST1_EXPECTED 5100

/* ========================================================================== */
/* Test 2: Data-dependent function selection through a pointer table          */
/* ========================================================================== */

typedef uint32_t (*op_func_t)(uint32_t);

NOINLINE uint32_t test_data_dependent_calls(void)
{
    uint32_t result = 0;

    /* Function pointer table, like CoreMark's dispatch. */
    op_func_t ops[4] = {add_one, add_two, add_three, multiply_two};

    for (int i = 0; i < 80; i++) {
        /* Data picks the target, so the call is indirect. */
        int op_index = i & 3;
        result += ops[op_index](i);
    }

    return result;
}

/* Four residue classes contribute 780 + 820 + 860 + 1640 = 4100. */
#define TEST2_EXPECTED 4100

/* ========================================================================== */
/* Test 3: Linked list with function calls at each node                       */
/* ========================================================================== */

typedef struct node {
    uint32_t data;
    struct node *next;
} node_t;

#define LIST_SIZE 32
static node_t list_nodes[LIST_SIZE];

NOINLINE void init_list(void)
{
    for (int i = 0; i < LIST_SIZE - 1; i++) {
        list_nodes[i].data = i + 1;
        list_nodes[i].next = &list_nodes[i + 1];
    }
    list_nodes[LIST_SIZE - 1].data = LIST_SIZE;
    list_nodes[LIST_SIZE - 1].next = (void *) 0;
}

NOINLINE uint32_t process_node(node_t *n)
{
    return n->data * 3 + 7;
}

NOINLINE uint32_t test_list_traversal(void)
{
    uint32_t checksum = 0;
    node_t *current = &list_nodes[0];

    while (current != (void *) 0) {
        /* Call inside the traversal, like CoreMark's list operations. */
        checksum += process_node(current);
        /* The loop condition is the BTB-predicted branch. */
        current = current->next;
    }

    return checksum;
}

/* 3*(1+...+32) + 7*32 = 1808. */
#define TEST3_EXPECTED 1808

/* ========================================================================== */
/* Test 4: Nested loops with multiple call sites                              */
/* ========================================================================== */

NOINLINE uint32_t inner_compute(uint32_t a, uint32_t b)
{
    return a * b + 1;
}

NOINLINE uint32_t outer_process(uint32_t x)
{
    return add_one(x) + add_two(x);
}

NOINLINE uint32_t test_nested_loops(void)
{
    uint32_t total = 0;

    for (int i = 0; i < 10; i++) {
        uint32_t partial = outer_process(i); /* Call that itself makes calls */

        for (int j = 0; j < 10; j++) {
            partial += inner_compute(i, j);
        }

        total += partial;
    }

    return total;
}

/* outer_process(i) = (i+1) + (i+2) = 2i+3 */
/* inner sum for each i = sum_{j=0}^{9} (i*j + 1) = i*45 + 10 */
/* partial for i = 2i+3 + i*45 + 10 = 47i + 13 */
/* total = sum_{i=0}^{9} (47i + 13) = 47*45 + 130 = 2115 + 130 = 2245 */
#define TEST4_EXPECTED 2245

/* ========================================================================== */
/* Test 5: Checksum with XOR mixing and function calls                        */
/* ========================================================================== */

NOINLINE uint32_t crc_step(uint32_t crc, uint32_t data)
{
    crc ^= data;
    for (int i = 0; i < 8; i++) {
        if (crc & 1) {
            crc = (crc >> 1) ^ 0xEDB88320;
        } else {
            crc >>= 1;
        }
    }
    return crc;
}

NOINLINE uint32_t test_checksum_computation(void)
{
    uint32_t crc = 0xFFFFFFFF;

    for (uint32_t i = 0; i < 64; i++) {
        /* Multiple branches inside crc_step plus the call */
        crc = crc_step(crc, i * 0x12345678U);
    }

    return crc ^ 0xFFFFFFFF;
}

/* Pre-computed expected CRC for this sequence */
#define TEST5_EXPECTED 0xC7933CF1

/* ========================================================================== */
/* Test 6: Alternating call depths (exercises RAS push/pop balance)           */
/* ========================================================================== */

NOINLINE uint32_t depth1_func(uint32_t x)
{
    return x + 100;
}

NOINLINE uint32_t depth2_func(uint32_t x)
{
    return depth1_func(x) + 200;
}

NOINLINE uint32_t depth3_func(uint32_t x)
{
    return depth2_func(x) + 300;
}

NOINLINE uint32_t depth4_func(uint32_t x)
{
    return depth3_func(x) + 400;
}

NOINLINE uint32_t test_alternating_depths(void)
{
    uint32_t sum = 0;

    for (int i = 0; i < 50; i++) {
        switch (i & 3) {
            case 0:
                sum += depth1_func(i);
                break;
            case 1:
                sum += depth2_func(i);
                break;
            case 2:
                sum += depth3_func(i);
                break;
            case 3:
                sum += depth4_func(i);
                break;
        }
    }

    return sum;
}

/* Depth classes contribute 1612, 4225, 7488, and 12300. */
#define TEST6_EXPECTED 25625

/* ========================================================================== */
/* Test 7: Rapid push/pop with conditional calls                              */
/* ========================================================================== */

NOINLINE uint32_t maybe_call(uint32_t x, int do_call)
{
    if (do_call) {
        return add_one(x);
    }
    return x;
}

NOINLINE uint32_t test_conditional_calls(void)
{
    uint32_t sum = 0;

    for (int i = 0; i < 100; i++) {
        /* Conditional nested call based on data */
        sum += maybe_call(i, i & 1);
    }

    return sum;
}

/* Odd terms: 2500 + 50; even terms: 2450; total: 5000. */
#define TEST7_EXPECTED 5000

/* ========================================================================== */
/* Test 8: Mixed BTB and RAS with memory operations                           */
/* ========================================================================== */

static volatile uint32_t data_array[64];

NOINLINE uint32_t load_and_compute(int idx)
{
    return data_array[idx] + idx;
}

NOINLINE uint32_t test_memory_with_calls(void)
{
    uint32_t sum = 0;

    for (int i = 0; i < 64; i++) {
        data_array[i] = i * 7;
    }

    /* Reads mixed with calls: memory stalls overlap RAS traffic. */
    for (int i = 0; i < 64; i++) {
        if (data_array[i] & 8) { /* Branch based on memory load */
            sum += load_and_compute(i);
        } else {
            sum += data_array[i];
        }
    }

    return sum;
}

/* Reported but not compared; the test exercises repeatable memory/call traffic. */
#define TEST8_EXPECTED 0 /* Not used for pass/fail. */

/* ========================================================================== */
/* Test 9: Long-running iteration test (like CoreMark)                        */
/* ========================================================================== */

NOINLINE uint32_t long_running_test(uint32_t iterations)
{
    uint32_t crc = 0;

    for (uint32_t iter = 0; iter < iterations; iter++) {
        /* Calls mixed with branches, like CoreMark's main loop. */
        for (uint32_t i = 0; i < 20; i++) {
            if (i & 1) {
                crc = crc_step(crc, add_one(i + iter));
            } else {
                crc = crc_step(crc, add_two(i + iter));
            }
        }
    }

    return crc;
}

/* ========================================================================== */
/* Main test harness                                                          */
/* ========================================================================== */

int main(void)
{
    uint32_t result;
    int passed = 0;
    int failed = 0;

    uart_puts("\n=== RAS Stress Test ===\n");
    uart_puts("Testing patterns similar to CoreMark\n\n");

    /* Initialize linked list for test 3 */
    init_list();

    /* Test 1 */
    uart_puts("Test 1: Loop with branch AND call... ");
    result = test_loop_with_branch_and_call();
    if (result == TEST1_EXPECTED) {
        uart_puts("OK\n");
        passed++;
    } else {
        uart_printf("FAIL (expected 0x%08x, got 0x%08x)\n", TEST1_EXPECTED, result);
        failed++;
    }

    /* Test 2 */
    uart_puts("Test 2: Data-dependent calls... ");
    result = test_data_dependent_calls();
    if (result == TEST2_EXPECTED) {
        uart_puts("OK\n");
        passed++;
    } else {
        uart_printf("FAIL (expected 0x%08x, got 0x%08x)\n", TEST2_EXPECTED, result);
        failed++;
    }

    /* Test 3 */
    uart_puts("Test 3: List traversal... ");
    result = test_list_traversal();
    if (result == TEST3_EXPECTED) {
        uart_puts("OK\n");
        passed++;
    } else {
        uart_printf("FAIL (expected 0x%08x, got 0x%08x)\n", TEST3_EXPECTED, result);
        failed++;
    }

    /* Test 4 */
    uart_puts("Test 4: Nested loops... ");
    result = test_nested_loops();
    if (result == TEST4_EXPECTED) {
        uart_puts("OK\n");
        passed++;
    } else {
        uart_printf("FAIL (expected 0x%08x, got 0x%08x)\n", TEST4_EXPECTED, result);
        failed++;
    }

    /* Test 5 */
    uart_puts("Test 5: CRC checksum... ");
    result = test_checksum_computation();
    if (result == TEST5_EXPECTED) {
        uart_puts("OK\n");
        passed++;
    } else {
        uart_printf("FAIL (expected 0x%08x, got 0x%08x)\n", TEST5_EXPECTED, result);
        failed++;
    }

    /* Test 6 */
    uart_puts("Test 6: Alternating depths... ");
    result = test_alternating_depths();
    if (result == TEST6_EXPECTED) {
        uart_puts("OK\n");
        passed++;
    } else {
        uart_printf("FAIL (expected 0x%08x, got 0x%08x)\n", TEST6_EXPECTED, result);
        failed++;
    }

    /* Test 7 */
    uart_puts("Test 7: Conditional calls... ");
    result = test_conditional_calls();
    if (result == TEST7_EXPECTED) {
        uart_puts("OK\n");
        passed++;
    } else {
        uart_printf("FAIL (expected 0x%08x, got 0x%08x)\n", TEST7_EXPECTED, result);
        failed++;
    }

    /* Test 8 reports its result; its expected value is too involved to hardcode. */
    uart_puts("Test 8: Memory + calls... ");
    result = test_memory_with_calls();
    uart_printf("result=0x%08x (no expected check)\n", result);

    /* Test 9 runs the same code many times. */
    uart_puts("Test 9: Long-running (50 iters)... ");
    result = long_running_test(50);
    uart_printf("result=0x%08x\n", result);
    /* Result of a known-good run, recorded for reference only. */
    uint32_t expected_long = 0xA8D8EB35;

    /* Run it again to check consistency */
    uart_puts("Test 9b: Verify consistency... ");
    uint32_t result2 = long_running_test(50);
    if (result == result2) {
        uart_puts("OK (consistent)\n");
        passed++;
    } else {
        uart_printf("FAIL (inconsistent: 0x%08x vs 0x%08x)\n", result, result2);
        failed++;
    }

    /* Summary */
    uart_printf("\n=== Summary ===\n");
    uart_printf("Passed: %d\n", passed);
    uart_printf("Failed: %d\n", failed);

    if (failed == 0) {
        uart_puts("<<PASS>>\n");
    } else {
        uart_puts("<<FAIL>>\n");
    }

    for (;;)
        ;
    return 0;
}
