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
 * Tomasulo Algorithm Correctness Test Suite
 *
 * Validates that the processor correctly handles all hazard types and
 * out-of-order execution scenarios that a Tomasulo implementation must
 * support. Each test uses inline assembly to emit exact instruction
 * sequences creating specific hazard patterns. The hardware must produce
 * correct results regardless of internal execution ordering.
 *
 * Tests:
 *   1. RAW (Read After Write) - true data dependency through CDB
 *   2. WAR (Write After Read) - anti-dependency via register renaming
 *   3. WAW (Write After Write) - output dependency via register renaming
 *   4. Independent instructions - parallel execution in functional units
 *   5. Long-latency bypass - MUL vs ADD latency differences
 *   6. Reservation station saturation - long dependency chains
 *   7. Load/store dependencies - memory disambiguation
 *   8. Complex mixed dependency chains
 *   9. Branch with loop - speculative execution / branch prediction
 *  10. CDB contention - multiple simultaneous completions
 *  11. FP hazards - RAW/WAR/WAW/crossover with double-precision FP
 */

#include "uart.h"
#include <stdint.h>

/* ========================================================================== */
/* Test Framework                                                             */
/* ========================================================================== */

static uint32_t tests_passed;
static uint32_t tests_failed;

#define TEST(name, got, expected)                                                                  \
    do {                                                                                           \
        uint32_t _g = (uint32_t) (got);                                                            \
        uint32_t _e = (uint32_t) (expected);                                                       \
        if (_g == _e) {                                                                            \
            tests_passed++;                                                                        \
        } else {                                                                                   \
            tests_failed++;                                                                        \
            uart_printf("  [FAIL] %s: got 0x%08X, expected 0x%08X\n", (name), _g, _e);             \
        }                                                                                          \
    } while (0)

/* Convert double-precision FP result to int32 (truncate toward zero) and     */
/* compare using the existing TEST macro. Avoids needing FP printf support.   */
#define TEST_FP(name, fp_result, expected_int)                                                     \
    do {                                                                                           \
        int32_t _iv;                                                                               \
        double _fr = (fp_result);                                                                  \
        __asm__ volatile("fcvt.w.d %0, %1, rtz" : "=r"(_iv) : "f"(_fr));                           \
        TEST(name, (uint32_t) _iv, (uint32_t) (expected_int));                                     \
    } while (0)

/* ========================================================================== */
/* Test 1: RAW (Read After Write) Hazard                                      */
/* Tests: Data forwarding through CDB, reservation station waiting            */
/* ========================================================================== */

static void test_raw_hazard(void)
{
    uart_printf("Test 1:  RAW hazard...");

    /* 3-deep dependency chain: each ADD reads the previous result */
    uint32_t r1, r2, r3;
    __asm__ volatile("add  %[r1], %[a], %[b]\n"  /* r1 = 10 + 20 = 30 */
                     "add  %[r2], %[r1], %[c]\n" /* r2 = r1 + 30 = 60  (RAW on r1) */
                     "add  %[r3], %[r2], %[d]\n" /* r3 = r2 + 40 = 100 (RAW on r2) */
                     : [r1] "=&r"(r1), [r2] "=&r"(r2), [r3] "=&r"(r3)
                     : [a] "r"((uint32_t) 10),
                       [b] "r"((uint32_t) 20),
                       [c] "r"((uint32_t) 30),
                       [d] "r"((uint32_t) 40));
    TEST("RAW chain r1", r1, 30);
    TEST("RAW chain r2", r2, 60);
    TEST("RAW chain r3", r3, 100);

    /* RAW through MUL (longer latency producer) */
    uint32_t product, sum;
    __asm__ volatile("mul  %[p], %[a], %[b]\n" /* product = 7 * 8 = 56 */
                     "add  %[s], %[p], %[c]\n" /* sum = product + 10 = 66 (RAW on MUL) */
                     : [p] "=&r"(product), [s] "=&r"(sum)
                     : [a] "r"((uint32_t) 7), [b] "r"((uint32_t) 8), [c] "r"((uint32_t) 10));
    TEST("RAW mul-add product", product, 56);
    TEST("RAW mul-add sum", sum, 66);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 2: WAR (Write After Read) Hazard                                      */
/* Tests: Register renaming eliminates false dependency                        */
/* ========================================================================== */

static void test_war_hazard(void)
{
    uart_printf("Test 2:  WAR hazard...");

    /* Read s1 and s2, then overwrite them. The ADD must see the original values. */
    uint32_t result;
    uint32_t s1 = 100, s2 = 200;
    __asm__ volatile("add  %[res], %[s1], %[s2]\n" /* result = 100 + 200 = 300 */
                     "addi %[s1], zero, 999\n"     /* WAR: overwrite s1 */
                     "addi %[s2], zero, 888\n"     /* WAR: overwrite s2 */
                     : [res] "=&r"(result), [s1] "+r"(s1), [s2] "+r"(s2));
    TEST("WAR result (must be 300)", result, 300);
    TEST("WAR s1 overwritten", s1, 999);
    TEST("WAR s2 overwritten", s2, 888);

    /* WAR with intervening independent instruction */
    uint32_t res2, independent;
    uint32_t src = 42;
    __asm__ volatile("add  %[res], %[src], %[src]\n" /* res = 42 + 42 = 84 (reads src) */
                     "add  %[ind], %[v1], %[v2]\n"   /* independent: 5 + 6 = 11 */
                     "addi %[src], zero, 0\n"        /* WAR: overwrite src */
                     : [res] "=&r"(res2), [ind] "=&r"(independent), [src] "+r"(src)
                     : [v1] "r"((uint32_t) 5), [v2] "r"((uint32_t) 6));
    TEST("WAR with independent", res2, 84);
    TEST("WAR independent val", independent, 11);
    TEST("WAR src overwritten", src, 0);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 3: WAW (Write After Write) Hazard                                     */
/* Tests: Register renaming, only final write architecturally visible          */
/* ========================================================================== */

static void test_waw_hazard(void)
{
    uart_printf("Test 3:  WAW hazard...");

    /* Three writes to the same register: only the last value should survive */
    uint32_t r;
    __asm__ volatile("addi %[r], zero, 111\n" /* First write */
                     "addi %[r], zero, 222\n" /* WAW: second write */
                     "addi %[r], zero, 333\n" /* WAW: third write */
                     : [r] "=r"(r));
    TEST("WAW final value", r, 333);

    /* WAW followed by a dependent reader */
    uint32_t w, reader;
    __asm__ volatile("addi %[w], zero, 10\n"    /* First write */
                     "addi %[w], zero, 20\n"    /* WAW */
                     "addi %[w], zero, 30\n"    /* WAW: final */
                     "add  %[rd], %[w], zero\n" /* Read: must see 30 */
                     : [w] "=&r"(w), [rd] "=&r"(reader));
    TEST("WAW+read final", w, 30);
    TEST("WAW+read value", reader, 30);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 4: Independent Instructions (Out-of-Order Execution)                  */
/* Tests: Parallel execution in multiple functional units                      */
/* ========================================================================== */

static void test_independent_ooo(void)
{
    uart_printf("Test 4:  Independent OOO...");

    /* 4 fully independent ADDs - all can execute in parallel */
    uint32_t a, b, c, d;
    __asm__ volatile("add  %[a], %[r1], %[r2]\n" /* a = 10 + 20 = 30 */
                     "add  %[b], %[r3], %[r4]\n" /* b = 30 + 40 = 70 */
                     "add  %[c], %[r5], %[r1]\n" /* c = 50 + 10 = 60 */
                     "add  %[d], %[r2], %[r3]\n" /* d = 20 + 30 = 50 */
                     : [a] "=&r"(a), [b] "=&r"(b), [c] "=&r"(c), [d] "=&r"(d)
                     : [r1] "r"((uint32_t) 10),
                       [r2] "r"((uint32_t) 20),
                       [r3] "r"((uint32_t) 30),
                       [r4] "r"((uint32_t) 40),
                       [r5] "r"((uint32_t) 50));
    TEST("OOO a", a, 30);
    TEST("OOO b", b, 70);
    TEST("OOO c", c, 60);
    TEST("OOO d", d, 50);

    /* 4 independent MULs */
    uint32_t m1, m2, m3, m4;
    __asm__ volatile("mul  %[m1], %[a1], %[b1]\n" /* m1 = 3 * 4  = 12 */
                     "mul  %[m2], %[a2], %[b2]\n" /* m2 = 5 * 6  = 30 */
                     "mul  %[m3], %[a3], %[b3]\n" /* m3 = 7 * 8  = 56 */
                     "mul  %[m4], %[a4], %[b4]\n" /* m4 = 9 * 10 = 90 */
                     : [m1] "=&r"(m1), [m2] "=&r"(m2), [m3] "=&r"(m3), [m4] "=&r"(m4)
                     : [a1] "r"((uint32_t) 3),
                       [b1] "r"((uint32_t) 4),
                       [a2] "r"((uint32_t) 5),
                       [b2] "r"((uint32_t) 6),
                       [a3] "r"((uint32_t) 7),
                       [b3] "r"((uint32_t) 8),
                       [a4] "r"((uint32_t) 9),
                       [b4] "r"((uint32_t) 10));
    TEST("OOO mul1", m1, 12);
    TEST("OOO mul2", m2, 30);
    TEST("OOO mul3", m3, 56);
    TEST("OOO mul4", m4, 90);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 5: Long Latency Operation Bypass                                      */
/* Tests: Short operations can complete before longer ones                     */
/* ========================================================================== */

static void test_latency_bypass(void)
{
    uart_printf("Test 5:  Latency bypass...");

    /* MUL (long latency) issued first, then independent ADDs (short latency).
     * All must produce correct results regardless of completion order. */
    uint32_t mul_res, add_res1, add_res2;
    __asm__ volatile("mul  %[m], %[a], %[b]\n"  /* Long latency: 5 * 6 = 30 */
                     "add  %[a1], %[c], %[d]\n" /* Short latency: 7 + 8 = 15 */
                     "add  %[a2], %[e], %[f]\n" /* Short latency: 10 + 20 = 30 */
                     : [m] "=&r"(mul_res), [a1] "=&r"(add_res1), [a2] "=&r"(add_res2)
                     : [a] "r"((uint32_t) 5),
                       [b] "r"((uint32_t) 6),
                       [c] "r"((uint32_t) 7),
                       [d] "r"((uint32_t) 8),
                       [e] "r"((uint32_t) 10),
                       [f] "r"((uint32_t) 20));
    TEST("Bypass MUL result", mul_res, 30);
    TEST("Bypass ADD1 result", add_res1, 15);
    TEST("Bypass ADD2 result", add_res2, 30);

    /* Back-to-back MULs with dependent chain */
    uint32_t p1, p2;
    __asm__ volatile("mul  %[p1], %[a], %[b]\n"  /* p1 = 11 * 13 = 143 */
                     "mul  %[p2], %[p1], %[c]\n" /* p2 = 143 * 2 = 286  (RAW across MULs) */
                     : [p1] "=&r"(p1), [p2] "=&r"(p2)
                     : [a] "r"((uint32_t) 11), [b] "r"((uint32_t) 13), [c] "r"((uint32_t) 2));
    TEST("MUL chain p1", p1, 143);
    TEST("MUL chain p2", p2, 286);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 6: Reservation Station Saturation                                     */
/* Tests: Instruction issue stalls when RS entries are full                    */
/* ========================================================================== */

static void test_rs_saturation(void)
{
    uart_printf("Test 6:  RS saturation...");

    /* 8-deep dependent doubling chain: each add depends on the previous */
    uint32_t r;
    __asm__ volatile("addi %[r], zero, 1\n"
                     "add  %[r], %[r], %[r]\n" /* 2 */
                     "add  %[r], %[r], %[r]\n" /* 4 */
                     "add  %[r], %[r], %[r]\n" /* 8 */
                     "add  %[r], %[r], %[r]\n" /* 16 */
                     "add  %[r], %[r], %[r]\n" /* 32 */
                     "add  %[r], %[r], %[r]\n" /* 64 */
                     "add  %[r], %[r], %[r]\n" /* 128 */
                     : [r] "=r"(r));
    TEST("RS chain 8-deep", r, 128);

    /* 16-deep dependent chain to further stress RS capacity */
    uint32_t r2;
    __asm__ volatile("addi %[r], zero, 1\n"
                     "add  %[r], %[r], %[r]\n" /* 2 */
                     "add  %[r], %[r], %[r]\n" /* 4 */
                     "add  %[r], %[r], %[r]\n" /* 8 */
                     "add  %[r], %[r], %[r]\n" /* 16 */
                     "add  %[r], %[r], %[r]\n" /* 32 */
                     "add  %[r], %[r], %[r]\n" /* 64 */
                     "add  %[r], %[r], %[r]\n" /* 128 */
                     "add  %[r], %[r], %[r]\n" /* 256 */
                     "add  %[r], %[r], %[r]\n" /* 512 */
                     "add  %[r], %[r], %[r]\n" /* 1024 */
                     "add  %[r], %[r], %[r]\n" /* 2048 */
                     "add  %[r], %[r], %[r]\n" /* 4096 */
                     "add  %[r], %[r], %[r]\n" /* 8192 */
                     "add  %[r], %[r], %[r]\n" /* 16384 */
                     "add  %[r], %[r], %[r]\n" /* 32768 */
                     : [r] "=r"(r2));
    TEST("RS chain 16-deep", r2, 32768);

    /* Accumulating chain (not just doubling): sum 1+2+3+...+10 */
    uint32_t acc;
    __asm__ volatile("addi %[a], zero, 0\n"
                     "addi t0, zero, 1\n"
                     "add  %[a], %[a], t0\n" /* 1 */
                     "addi t0, zero, 2\n"
                     "add  %[a], %[a], t0\n" /* 3 */
                     "addi t0, zero, 3\n"
                     "add  %[a], %[a], t0\n" /* 6 */
                     "addi t0, zero, 4\n"
                     "add  %[a], %[a], t0\n" /* 10 */
                     "addi t0, zero, 5\n"
                     "add  %[a], %[a], t0\n" /* 15 */
                     "addi t0, zero, 6\n"
                     "add  %[a], %[a], t0\n" /* 21 */
                     "addi t0, zero, 7\n"
                     "add  %[a], %[a], t0\n" /* 28 */
                     "addi t0, zero, 8\n"
                     "add  %[a], %[a], t0\n" /* 36 */
                     "addi t0, zero, 9\n"
                     "add  %[a], %[a], t0\n" /* 45 */
                     "addi t0, zero, 10\n"
                     "add  %[a], %[a], t0\n" /* 55 */
                     : [a] "=&r"(acc)
                     : /* no inputs */
                     : "t0");
    TEST("RS accumulate 1..10", acc, 55);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 7: Load/Store with Dependencies                                       */
/* Tests: Memory disambiguation, load/store ordering                          */
/* ========================================================================== */

static void test_memory_deps(void)
{
    uart_printf("Test 7:  Memory deps...");

    volatile uint32_t data[4] = {0, 0, 0, 0};

    /* Store then load from same address (RAW through memory) */
    uint32_t load_val, final_val;
    __asm__ volatile("li   t0, 42\n"
                     "sw   t0, 0(%[addr])\n"    /* Store 42 */
                     "lw   %[lv], 0(%[addr])\n" /* Load (depends on store) */
                     "addi %[fv], %[lv], 1\n"   /* RAW on load: 42 + 1 = 43 */
                     : [lv] "=&r"(load_val), [fv] "=&r"(final_val)
                     : [addr] "r"(data)
                     : "t0", "memory");
    TEST("Store-load", load_val, 42);
    TEST("Load-use", final_val, 43);

    /* Stores to different addresses, then loads back */
    uint32_t v1, v2;
    __asm__ volatile("li   t0, 100\n"
                     "li   t1, 200\n"
                     "sw   t0, 0(%[addr])\n"
                     "sw   t1, 4(%[addr])\n"
                     "lw   %[v1], 0(%[addr])\n"
                     "lw   %[v2], 4(%[addr])\n"
                     : [v1] "=&r"(v1), [v2] "=&r"(v2)
                     : [addr] "r"(data)
                     : "t0", "t1", "memory");
    TEST("Multi-store v1", v1, 100);
    TEST("Multi-store v2", v2, 200);

    /* Two stores to same address, then load (must see the second store) */
    uint32_t overwrite_val;
    __asm__ volatile("li   t0, 111\n"
                     "sw   t0, 0(%[addr])\n"
                     "li   t0, 222\n"
                     "sw   t0, 0(%[addr])\n"    /* Overwrite same address */
                     "lw   %[ov], 0(%[addr])\n" /* Must see 222 */
                     : [ov] "=&r"(overwrite_val)
                     : [addr] "r"(data)
                     : "t0", "memory");
    TEST("Store-overwrite-load", overwrite_val, 222);

    /* Load from address, store to different address, load from first again */
    data[0] = 500;
    data[1] = 0;
    uint32_t ld1, ld2;
    __asm__ volatile("lw   %[ld1], 0(%[addr])\n" /* Load from [0]: 500 */
                     "li   t0, 600\n"
                     "sw   t0, 4(%[addr])\n"     /* Store to [1]: 600 */
                     "lw   %[ld2], 4(%[addr])\n" /* Load from [1]: must see 600 */
                     : [ld1] "=&r"(ld1), [ld2] "=&r"(ld2)
                     : [addr] "r"(data)
                     : "t0", "memory");
    TEST("Load-store-load ld1", ld1, 500);
    TEST("Load-store-load ld2", ld2, 600);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 8: Complex Mixed Dependency Chain                                     */
/* Tests: Multiple hazard types combined in one sequence                       */
/* ========================================================================== */

static void test_complex_deps(void)
{
    uart_printf("Test 8:  Complex deps...");

    /* Chain: ADD -> SUB(RAW) -> ADD(RAW+WAR) -> MUL(RAW) -> ADD(RAW) */
    uint32_t t2, t3, t0_new, t4, t5;
    __asm__ volatile(
        "add  %[t2], %[v10], %[v20]\n" /* t2 = 10 + 20 = 30 */
        "sub  %[t3], %[t2], %[v10]\n"  /* RAW on t2: t3 = 30 - 10 = 20 */
        "add  %[t0n], %[t3], %[v20]\n" /* RAW on t3: t0n = 20 + 20 = 40 */
        "mul  %[t4], %[t0n], %[t2]\n"  /* RAW on t0n and t2: t4 = 40 * 30 = 1200 */
        "add  %[t5], %[t4], %[t3]\n"   /* RAW on t4 and t3: t5 = 1200 + 20 = 1220 */
        : [t2] "=&r"(t2), [t3] "=&r"(t3), [t0n] "=&r"(t0_new), [t4] "=&r"(t4), [t5] "=&r"(t5)
        : [v10] "r"((uint32_t) 10), [v20] "r"((uint32_t) 20));
    TEST("Complex t2", t2, 30);
    TEST("Complex t3", t3, 20);
    TEST("Complex t0_new", t0_new, 40);
    TEST("Complex t4", t4, 1200);
    TEST("Complex t5", t5, 1220);

    /* Mixed independent and dependent: some can execute OOO, some must wait */
    uint32_t dep1, dep2, ind1, ind2;
    __asm__ volatile(
        "add  %[dep1], %[a], %[b]\n"    /* dep1 = 3 + 7 = 10 */
        "add  %[ind1], %[c], %[d]\n"    /* ind1 = 11 + 13 = 24 (independent) */
        "mul  %[dep2], %[dep1], %[e]\n" /* dep2 = 10 * 5 = 50 (RAW on dep1) */
        "add  %[ind2], %[d], %[e]\n"    /* ind2 = 13 + 5 = 18 (independent) */
        : [dep1] "=&r"(dep1), [dep2] "=&r"(dep2), [ind1] "=&r"(ind1), [ind2] "=&r"(ind2)
        : [a] "r"((uint32_t) 3),
          [b] "r"((uint32_t) 7),
          [c] "r"((uint32_t) 11),
          [d] "r"((uint32_t) 13),
          [e] "r"((uint32_t) 5));
    TEST("Mixed dep1", dep1, 10);
    TEST("Mixed ind1", ind1, 24);
    TEST("Mixed dep2", dep2, 50);
    TEST("Mixed ind2", ind2, 18);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 9: Branch with Loop                                                   */
/* Tests: Speculative execution, branch misprediction recovery                */
/* ========================================================================== */

static void test_branch_loop(void)
{
    uart_printf("Test 9:  Branch loop...");

    /* Simple countdown loop */
    uint32_t counter, loop_reg;
    __asm__ volatile("addi %[cnt], zero, 0\n"
                     "addi %[lr], zero, 5\n"
                     "1:\n"
                     "addi %[cnt], %[cnt], 1\n"
                     "addi %[lr], %[lr], -1\n"
                     "bne  %[lr], zero, 1b\n"
                     : [cnt] "=&r"(counter), [lr] "=&r"(loop_reg));
    TEST("Branch counter", counter, 5);
    TEST("Branch loop_reg", loop_reg, 0);

    /* Loop with accumulation: sum = 10 + 9 + 8 + ... + 1 = 55 */
    uint32_t sum, i;
    __asm__ volatile("addi %[sum], zero, 0\n"
                     "addi %[i], zero, 10\n"
                     "1:\n"
                     "add  %[sum], %[sum], %[i]\n"
                     "addi %[i], %[i], -1\n"
                     "bne  %[i], zero, 1b\n"
                     : [sum] "=&r"(sum), [i] "=&r"(i));
    TEST("Branch sum 1..10", sum, 55);
    TEST("Branch i final", i, 0);

    /* Nested-style: outer counter controls inner work */
    uint32_t total, outer;
    __asm__ volatile("addi %[total], zero, 0\n"
                     "addi %[outer], zero, 4\n"
                     "1:\n"
                     "add  %[total], %[total], %[outer]\n" /* total += outer */
                     "add  %[total], %[total], %[outer]\n" /* total += outer (2x per iter) */
                     "addi %[outer], %[outer], -1\n"
                     "bne  %[outer], zero, 1b\n"
                     : [total] "=&r"(total), [outer] "=&r"(outer));
    /* total = 2*(4+3+2+1) = 20 */
    TEST("Branch nested total", total, 20);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 10: CDB Contention                                                    */
/* Tests: Multiple instructions completing simultaneously                     */
/* ========================================================================== */

static void test_cdb_contention(void)
{
    uart_printf("Test 10: CDB contention...");

    /* 4 independent ADDs - may all try to broadcast on CDB same cycle */
    uint32_t a, b, c, d;
    __asm__ volatile("add  %[a], %[s1], %[s2]\n" /* 1 + 2 = 3 */
                     "add  %[b], %[s3], %[s4]\n" /* 3 + 4 = 7 */
                     "sub  %[c], %[s4], %[s1]\n" /* 4 - 1 = 3 */
                     "add  %[d], %[s2], %[s3]\n" /* 2 + 3 = 5 */
                     : [a] "=&r"(a), [b] "=&r"(b), [c] "=&r"(c), [d] "=&r"(d)
                     : [s1] "r"((uint32_t) 1),
                       [s2] "r"((uint32_t) 2),
                       [s3] "r"((uint32_t) 3),
                       [s4] "r"((uint32_t) 4));
    TEST("CDB a", a, 3);
    TEST("CDB b", b, 7);
    TEST("CDB c", c, 3);
    TEST("CDB d", d, 5);

    /* 8 independent operations: maximum CDB pressure */
    uint32_t e, f, g, h;
    __asm__ volatile("add  %[a], %[s1], %[s1]\n" /* 1+1 = 2 */
                     "add  %[b], %[s2], %[s2]\n" /* 2+2 = 4 */
                     "add  %[c], %[s3], %[s3]\n" /* 3+3 = 6 */
                     "add  %[d], %[s4], %[s4]\n" /* 4+4 = 8 */
                     "add  %[e], %[s1], %[s2]\n" /* 1+2 = 3 */
                     "add  %[f], %[s2], %[s3]\n" /* 2+3 = 5 */
                     "add  %[g], %[s3], %[s4]\n" /* 3+4 = 7 */
                     "add  %[h], %[s4], %[s1]\n" /* 4+1 = 5 */
                     : [a] "=&r"(a),
                       [b] "=&r"(b),
                       [c] "=&r"(c),
                       [d] "=&r"(d),
                       [e] "=&r"(e),
                       [f] "=&r"(f),
                       [g] "=&r"(g),
                       [h] "=&r"(h)
                     : [s1] "r"((uint32_t) 1),
                       [s2] "r"((uint32_t) 2),
                       [s3] "r"((uint32_t) 3),
                       [s4] "r"((uint32_t) 4));
    TEST("CDB8 a", a, 2);
    TEST("CDB8 b", b, 4);
    TEST("CDB8 c", c, 6);
    TEST("CDB8 d", d, 8);
    TEST("CDB8 e", e, 3);
    TEST("CDB8 f", f, 5);
    TEST("CDB8 g", g, 7);
    TEST("CDB8 h", h, 5);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Test 11: Floating-Point Hazards (double-precision)                         */
/* Tests: FP RAW/WAR/WAW, FP-INT crossover, FMADD chain, independent FP ops  */
/* ========================================================================== */

static void test_fp_hazards(void)
{
    uart_printf("Test 11: FP hazards...");

    /* FP RAW chain: each FADD.D reads the previous result */
    double fa, fb, fc;
    __asm__ volatile("fadd.d %[fa], %[v1], %[v2]\n" /* fa = 1.0 + 2.0 = 3.0 */
                     "fadd.d %[fb], %[fa], %[v4]\n" /* fb = 3.0 + 4.0 = 7.0  (RAW) */
                     "fadd.d %[fc], %[fb], %[v8]\n" /* fc = 7.0 + 8.0 = 15.0 (RAW) */
                     : [fa] "=&f"(fa), [fb] "=&f"(fb), [fc] "=&f"(fc)
                     : [v1] "f"(1.0), [v2] "f"(2.0), [v4] "f"(4.0), [v8] "f"(8.0));
    TEST_FP("FP RAW fa", fa, 3);
    TEST_FP("FP RAW fb", fb, 7);
    TEST_FP("FP RAW fc", fc, 15);

    /* FP MUL→ADD RAW: FMUL.D produces, FADD.D consumes */
    double fp, fs;
    __asm__ volatile("fmul.d %[p], %[a], %[b]\n" /* fp = 3.0 * 4.0 = 12.0 */
                     "fadd.d %[s], %[p], %[c]\n" /* fs = 12.0 + 1.0 = 13.0 (RAW) */
                     : [p] "=&f"(fp), [s] "=&f"(fs)
                     : [a] "f"(3.0), [b] "f"(4.0), [c] "f"(1.0));
    TEST_FP("FP MUL-ADD product", fp, 12);
    TEST_FP("FP MUL-ADD sum", fs, 13);

    /* FP WAR: read src, then overwrite it */
    double fp_res;
    double fp_src = 5.0;
    __asm__ volatile("fadd.d %[res], %[src], %[src]\n" /* res = 5.0 + 5.0 = 10.0 */
                     "fmul.d %[src], %[z], %[z]\n"     /* WAR: overwrite src = 0*0 = 0 */
                     : [res] "=&f"(fp_res), [src] "+f"(fp_src)
                     : [z] "f"(0.0));
    TEST_FP("FP WAR result", fp_res, 10);
    TEST_FP("FP WAR src overwritten", fp_src, 0);

    /* FP WAW: multiple writes, only final value survives */
    double fw;
    __asm__ volatile("fadd.d %[w], %[v1], %[z]\n" /* 1.0 */
                     "fadd.d %[w], %[v2], %[z]\n" /* WAW: 2.0 */
                     "fadd.d %[w], %[v3], %[z]\n" /* WAW: 3.0 (final) */
                     : [w] "=f"(fw)
                     : [v1] "f"(1.0), [v2] "f"(2.0), [v3] "f"(3.0), [z] "f"(0.0));
    TEST_FP("FP WAW final", fw, 3);

    /* FP-INT crossover: INT produces value, FP consumes via convert */
    uint32_t int_val;
    double fp_from_int;
    __asm__ volatile("addi %[iv], zero, 7\n"             /* INT: iv = 7 */
                     "fcvt.d.w %[fv], %[iv]\n"           /* Convert to FP: 7.0 */
                     "fadd.d   %[fv], %[fv], %[three]\n" /* FP: 7.0 + 3.0 = 10.0 */
                     : [iv] "=&r"(int_val), [fv] "=&f"(fp_from_int)
                     : [three] "f"(3.0));
    TEST("FP-INT crossover int_val", int_val, 7);
    TEST_FP("FP-INT crossover fp result", fp_from_int, 10);

    /* FMADD.D dependent chain: accum = accum * 1.0 + addend */
    double fma_acc;
    __asm__ volatile("fmul.d  %[a], %[z], %[z]\n"          /* accum = 0.0 */
                     "fmadd.d %[a], %[a], %[one], %[v2]\n" /* 0*1+2 = 2.0 */
                     "fmadd.d %[a], %[a], %[one], %[v3]\n" /* 2*1+3 = 5.0 */
                     "fmadd.d %[a], %[a], %[one], %[v4]\n" /* 5*1+4 = 9.0 */
                     : [a] "=&f"(fma_acc)
                     : [z] "f"(0.0), [one] "f"(1.0), [v2] "f"(2.0), [v3] "f"(3.0), [v4] "f"(4.0));
    TEST_FP("FMADD chain", fma_acc, 9);

    /* 4 independent FADD.D ops - all can execute in parallel */
    double ia, ib, ic, id;
    __asm__ volatile("fadd.d %[a], %[v1], %[v2]\n" /* 1+2 = 3 */
                     "fadd.d %[b], %[v3], %[v4]\n" /* 3+4 = 7 */
                     "fadd.d %[c], %[v5], %[v1]\n" /* 5+1 = 6 */
                     "fadd.d %[d], %[v2], %[v3]\n" /* 2+3 = 5 */
                     : [a] "=&f"(ia), [b] "=&f"(ib), [c] "=&f"(ic), [d] "=&f"(id)
                     : [v1] "f"(1.0), [v2] "f"(2.0), [v3] "f"(3.0), [v4] "f"(4.0), [v5] "f"(5.0));
    TEST_FP("FP indep a", ia, 3);
    TEST_FP("FP indep b", ib, 7);
    TEST_FP("FP indep c", ic, 6);
    TEST_FP("FP indep d", id, 5);

    uart_printf(" done\n");
}

/* ========================================================================== */
/* Main Entry Point                                                           */
/* ========================================================================== */

int main(void)
{
    uart_printf("\n");
    uart_printf("============================================================\n");
    uart_printf("     TOMASULO ALGORITHM CORRECTNESS TEST SUITE\n");
    uart_printf("============================================================\n\n");

    test_raw_hazard();
    test_war_hazard();
    test_waw_hazard();
    test_independent_ooo();
    test_latency_bypass();
    test_rs_saturation();
    test_memory_deps();
    test_complex_deps();
    test_branch_loop();
    test_cdb_contention();
    test_fp_hazards();

    uart_printf("\n------------------------------------------------------------\n");
    uart_printf(
        "  PASSED: %lu  FAILED: %lu\n", (unsigned long) tests_passed, (unsigned long) tests_failed);
    uart_printf("------------------------------------------------------------\n\n");

    if (tests_failed == 0) {
        uart_printf("  *** ALL TOMASULO TESTS PASSED ***\n\n");
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("  *** SOME TESTS FAILED - SEE DETAILS ABOVE ***\n\n");
        uart_printf("<<FAIL>>\n");
    }

    return 0;
}
