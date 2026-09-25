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
 * Measures Zicntr cycle/instret IPC across dependent and independent chains.
 * The comparison shows out-of-order latency hiding and available ILP. IPC is
 * reported as IPC*100 (150 means 1.50).
 *
 * Benchmarks (integer):
 *   1. Dependent ADD chain      (worst-case ILP: serialized)
 *   2. Independent ADD chains   (best-case ILP: fully parallel)
 *   3. Dependent MUL chain      (long-latency serialized)
 *   4. Independent MUL chains   (long-latency parallel)
 *   5. Mixed MUL + ADD          (latency hiding)
 *   6. Load-store throughput    (memory subsystem)
 *   7. Branch-heavy loop        (branch prediction + OOO)
 *
 * Benchmarks (floating-point, double-precision):
 *   8. Dependent FADD.D chain   (FP ALU serialized)
 *   9. Independent FADD.D chains (FP ALU parallel)
 *  10. Dependent FMUL.D chain   (FP MUL serialized)
 *  11. Independent FMUL.D chains (FP MUL parallel)
 *  12. Dependent FMADD.D chain  (fused multiply-add serialized)
 *  13. Mixed FP + INT           (cross-unit parallelism)
 *
 * Benchmarks (atomics):
 *  14. Load + younger AMOADD.W  (head-load wait with an AMO in flight)
 *
 * With TOMASULO_PERF_ENABLE_PROFILE=1 and the counters present, each report
 * also checks that the head-load wait split adds up (counters 90, 92 and 93
 * sum to 86; 102, 103 and 105 sum to 93) and that the reserved counters 89,
 * 91 and 104 read 0. A failed check ends the run with <<FAIL>>.
 */

#include "csr.h"
#include "tomasulo_profile.h"
#include "uart.h"
#include <stdint.h>

/* 1 prints a brief profiling-counter report after each benchmark. */
#ifndef TOMASULO_PERF_ENABLE_PROFILE
#define TOMASULO_PERF_ENABLE_PROFILE 0
#endif

#if TOMASULO_PERF_ENABLE_PROFILE
static uint64_t bench_profile_start_cache[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];
static uint64_t bench_profile_end_cache[TOMASULO_PROFILE_CACHE_COUNTER_COUNT];
static tomasulo_profile_snapshot_t bench_profile_start;
static tomasulo_profile_snapshot_t bench_profile_end;

static uint32_t bench_profile_failures;

/* Wrapper counters with no source; they must read 0 (perf README). */
static const uint32_t bench_profile_reserved[] = {89U, 91U, 104U};

/*
 * Print the head-load wait split and check that it adds up and that the
 * reserved counters read 0 in both snapshots.
 */
static void bench_profile_check(const char *label)
{
    const tomasulo_profile_snapshot_t *s = &bench_profile_start;
    const tomasulo_profile_snapshot_t *e = &bench_profile_end;
    uint64_t bus_blocked = tomasulo_profile_delta(s, e, TOMASULO_PERF_HEAD_LOAD_BUS_BLOCKED);
    uint64_t bus_busy = tomasulo_profile_delta(s, e, TOMASULO_PERF_HEAD_LOAD_BB_BUS_BUSY);
    uint64_t sq_wait = tomasulo_profile_delta(s, e, TOMASULO_PERF_HEAD_LOAD_BB_SQ_WAIT);
    uint64_t staging = tomasulo_profile_delta(s, e, TOMASULO_PERF_HEAD_LOAD_BB_STAGING);
    uint64_t other = tomasulo_profile_delta(s, e, TOMASULO_PERF_HEAD_LOAD_BBS_OTHER_IN_STAGING);
    uint64_t gated = tomasulo_profile_delta(s, e, TOMASULO_PERF_HEAD_LOAD_BBS_LAUNCH_GATED);
    uint64_t capture = tomasulo_profile_delta(s, e, TOMASULO_PERF_HEAD_LOAD_BBS_CAPTURE_GAP);
    uint64_t reserved = 0;
    uint32_t i;

    if (s->counter_count == 0 || e->counter_count == 0) {
        return;
    }
    for (i = 0; i < sizeof(bench_profile_reserved) / sizeof(bench_profile_reserved[0]); i++) {
        reserved |= s->counters[bench_profile_reserved[i]] | e->counters[bench_profile_reserved[i]];
    }
    uart_printf("  Head-load bus-blocked %llu: bus_busy %llu + sq_wait %llu + staging %llu "
                "(other %llu + gated %llu + capture %llu)\n",
                (unsigned long long) bus_blocked,
                (unsigned long long) bus_busy,
                (unsigned long long) sq_wait,
                (unsigned long long) staging,
                (unsigned long long) other,
                (unsigned long long) gated,
                (unsigned long long) capture);
    if (bus_busy + sq_wait + staging != bus_blocked || other + gated + capture != staging ||
        reserved != 0) {
        uart_printf("  Profile check FAILED for %s: split does not add up or a reserved counter "
                    "is nonzero (0x%llx)\n",
                    label,
                    (unsigned long long) reserved);
        bench_profile_failures++;
    }
}

#define BENCH_PROFILE_BEGIN() tomasulo_profile_take_snapshot(&bench_profile_start)
#define BENCH_PROFILE_END(label)                                                                   \
    do {                                                                                           \
        tomasulo_profile_take_snapshot(&bench_profile_end);                                        \
        tomasulo_profile_read_cache_pair(&bench_profile_start, &bench_profile_end);                \
        tomasulo_profile_print_brief_report((label), &bench_profile_start, &bench_profile_end);    \
        bench_profile_check(label);                                                                \
    } while (0)
#else
#define BENCH_PROFILE_BEGIN()                                                                      \
    do {                                                                                           \
    } while (0)
#define BENCH_PROFILE_END(label)                                                                   \
    do {                                                                                           \
        (void) (label);                                                                            \
    } while (0)
#endif

static void print_result(uint32_t cycles, uint32_t instrs)
{
    uint32_t ipc_x100 = cycles ? (instrs * 100) / cycles : 0;
    uart_printf("  Cycles: %lu  Instrs: %lu  IPC*100: %lu\n",
                (unsigned long) cycles,
                (unsigned long) instrs,
                (unsigned long) ipc_x100);
}

int main(void)
{
    uint32_t c0, c1, i0, i1;

#if TOMASULO_PERF_ENABLE_PROFILE
    tomasulo_profile_bind_cache_counters(&bench_profile_start, bench_profile_start_cache);
    tomasulo_profile_bind_cache_counters(&bench_profile_end, bench_profile_end_cache);
#endif

    uart_printf("\n");
    uart_printf("============================================================\n");
    uart_printf("     TOMASULO PERFORMANCE MEASUREMENT\n");
    uart_printf("============================================================\n");
    uart_printf("  IPC*100: 100 = 1.0 IPC, 150 = 1.5 IPC, etc.\n\n");

    /* ===================================================================== */
    /* Benchmark 1: Dependent ADD chain (100 instructions)                   */
    /* Each ADD reads the result of the previous one, so there is no ILP.    */
    /* This is the baseline case: OOO execution cannot help.                 */
    /* ===================================================================== */
    uart_printf("Bench 1: Dependent ADD chain (100 instrs)\n");
    BENCH_PROFILE_BEGIN();
    c0 = rdcycle();
    i0 = rdinstret();
    __asm__ volatile("addi t0, zero, 1\n"
                     ".rept 100\n"
                     "add  t0, t0, t0\n"
                     ".endr\n"
                     :
                     :
                     : "t0");
    c1 = rdcycle();
    i1 = rdinstret();
    BENCH_PROFILE_END("Bench 1: Dependent ADD chain");
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 2: Independent ADD chains (4 x 25 = 100 instructions)       */
    /* 4 chains with no cross-dependencies, ideal for OOO execution.         */
    /* IPC should be higher than Bench 1 if OOO is working.                  */
    /* ===================================================================== */
    uart_printf("Bench 2: Independent ADD chains (4x25 = 100 instrs)\n");
    BENCH_PROFILE_BEGIN();
    c0 = rdcycle();
    i0 = rdinstret();
    __asm__ volatile("addi t0, zero, 1\n"
                     "addi t1, zero, 2\n"
                     "addi t2, zero, 3\n"
                     "addi t3, zero, 4\n"
                     ".rept 25\n"
                     "add  t0, t0, t0\n"
                     "add  t1, t1, t1\n"
                     "add  t2, t2, t2\n"
                     "add  t3, t3, t3\n"
                     ".endr\n"
                     :
                     :
                     : "t0", "t1", "t2", "t3");
    c1 = rdcycle();
    i1 = rdinstret();
    BENCH_PROFILE_END("Bench 2: Independent ADD chains");
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 3: Dependent MUL chain (50 instructions)                    */
    /* MUL has multi-cycle latency, so a dependent chain is very slow.       */
    /* Multiply by 1 to keep the value stable (avoids overflow).             */
    /* ===================================================================== */
    uart_printf("Bench 3: Dependent MUL chain (50 instrs)\n");
    BENCH_PROFILE_BEGIN();
    c0 = rdcycle();
    i0 = rdinstret();
    __asm__ volatile("addi t0, zero, 3\n"
                     "addi t1, zero, 1\n"
                     ".rept 50\n"
                     "mul  t0, t0, t1\n"
                     ".endr\n"
                     :
                     :
                     : "t0", "t1");
    c1 = rdcycle();
    i1 = rdinstret();
    BENCH_PROFILE_END("Bench 3: Dependent MUL chain");
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 4: Independent MUL chains (4 x 12 = 48 instructions)        */
    /* 4 independent MUL chains. The multiplier is pipelined, so these can   */
    /* overlap.                                                              */
    /* ===================================================================== */
    uart_printf("Bench 4: Independent MUL chains (4x12 = 48 instrs)\n");
    BENCH_PROFILE_BEGIN();
    c0 = rdcycle();
    i0 = rdinstret();
    __asm__ volatile("addi t0, zero, 2\n"
                     "addi t1, zero, 3\n"
                     "addi t2, zero, 5\n"
                     "addi t3, zero, 7\n"
                     "addi t4, zero, 1\n"
                     ".rept 12\n"
                     "mul  t0, t0, t4\n"
                     "mul  t1, t1, t4\n"
                     "mul  t2, t2, t4\n"
                     "mul  t3, t3, t4\n"
                     ".endr\n"
                     :
                     :
                     : "t0", "t1", "t2", "t3", "t4");
    c1 = rdcycle();
    i1 = rdinstret();
    BENCH_PROFILE_END("Bench 4: Independent MUL chains");
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 5: Mixed MUL + independent ADD (50 pairs = 100 instrs)      */
    /* Tests whether short-latency ADDs can execute while MUL is in flight.  */
    /* An OOO machine should overlap the ADD with the MUL stall.             */
    /* ===================================================================== */
    uart_printf("Bench 5: Mixed MUL+ADD (50 pairs = 100 instrs)\n");
    BENCH_PROFILE_BEGIN();
    c0 = rdcycle();
    i0 = rdinstret();
    __asm__ volatile("addi t0, zero, 1\n"
                     "addi t1, zero, 1\n"
                     "addi t2, zero, 0\n"
                     "addi t3, zero, 1\n"
                     ".rept 50\n"
                     "mul  t0, t0, t1\n" /* Long latency (dependent chain) */
                     "add  t2, t2, t3\n" /* Short latency (independent of MUL) */
                     ".endr\n"
                     :
                     :
                     : "t0", "t1", "t2", "t3");
    c1 = rdcycle();
    i1 = rdinstret();
    BENCH_PROFILE_END("Bench 5: Mixed MUL+ADD");
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 6: Load-store throughput (50 store-load pairs)              */
    /* Alternating store and load to the same address.                       */
    /* Tests store-load forwarding and memory subsystem throughput.          */
    /* ===================================================================== */
    uart_printf("Bench 6: Load-store pairs (50 pairs = 100 instrs)\n");
    {
        volatile uint32_t mem_area[4];
        BENCH_PROFILE_BEGIN();
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile("addi t0, zero, 1\n"
                         ".rept 50\n"
                         "sw   t0, 0(%[addr])\n"
                         "lw   t0, 0(%[addr])\n"
                         ".endr\n"
                         :
                         : [addr] "r"(mem_area)
                         : "t0", "memory");
        c1 = rdcycle();
        i1 = rdinstret();
        BENCH_PROFILE_END("Bench 6: Load-store pairs");
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 7: Branch-heavy loop (200 iterations, 3 instrs/iter)        */
    /* Tests branch prediction integration with OOO pipeline.                */
    /* Good prediction allows the loop body to overlap across iterations.    */
    /* ===================================================================== */
    uart_printf("Bench 7: Branch loop (200 iters, 3 instrs/iter)\n");
    BENCH_PROFILE_BEGIN();
    c0 = rdcycle();
    i0 = rdinstret();
    __asm__ volatile("addi t0, zero, 200\n"
                     "addi t1, zero, 0\n"
                     "1:\n"
                     "addi t1, t1, 1\n"
                     "addi t0, t0, -1\n"
                     "bne  t0, zero, 1b\n"
                     :
                     :
                     : "t0", "t1");
    c1 = rdcycle();
    i1 = rdinstret();
    BENCH_PROFILE_END("Bench 7: Branch loop");
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Floating-Point Benchmarks                                             */
    /* ===================================================================== */
    uart_printf("\n--- Floating-Point Benchmarks (double-precision) ---\n\n");

    /* ===================================================================== */
    /* Benchmark 8: Dependent FADD.D chain (100 instructions)                */
    /* Each FADD.D reads the result of the previous one, so there is no ILP. */
    /* FP analogue of Bench 1.                                               */
    /* ===================================================================== */
    uart_printf("Bench 8: Dependent FADD.D chain (100 instrs)\n");
    {
        double accum = 1.0, incr = 0.5;
        BENCH_PROFILE_BEGIN();
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile(".rept 100\n"
                         "fadd.d %[a], %[a], %[i]\n"
                         ".endr\n"
                         : [a] "+f"(accum)
                         : [i] "f"(incr));
        c1 = rdcycle();
        i1 = rdinstret();
        BENCH_PROFILE_END("Bench 8: Dependent FADD.D chain");
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 9: Independent FADD.D chains (4 x 25 = 100 instructions)    */
    /* 4 chains with no cross-dependencies, ideal for OOO execution.         */
    /* FP analogue of Bench 2. fp_add_shim has one operation in flight at    */
    /* a time, so the chains cannot overlap in the FP adder.                 */
    /* ===================================================================== */
    uart_printf("Bench 9: Independent FADD.D chains (4x25 = 100 instrs)\n");
    {
        double a0 = 1.0, a1 = 2.0, a2 = 3.0, a3 = 4.0;
        double inc = 0.5;
        BENCH_PROFILE_BEGIN();
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile(".rept 25\n"
                         "fadd.d %[a0], %[a0], %[inc]\n"
                         "fadd.d %[a1], %[a1], %[inc]\n"
                         "fadd.d %[a2], %[a2], %[inc]\n"
                         "fadd.d %[a3], %[a3], %[inc]\n"
                         ".endr\n"
                         : [a0] "+f"(a0), [a1] "+f"(a1), [a2] "+f"(a2), [a3] "+f"(a3)
                         : [inc] "f"(inc));
        c1 = rdcycle();
        i1 = rdinstret();
        BENCH_PROFILE_END("Bench 9: Independent FADD.D chains");
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 10: Dependent FMUL.D chain (50 instructions)                */
    /* FMUL.D has multi-cycle latency, so a dependent chain is very slow.    */
    /* Multiply by 1.0 to keep the value stable. FP analogue of Bench 3.     */
    /* ===================================================================== */
    uart_printf("Bench 10: Dependent FMUL.D chain (50 instrs)\n");
    {
        double accum = 2.0, factor = 1.0;
        BENCH_PROFILE_BEGIN();
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile(".rept 50\n"
                         "fmul.d %[a], %[a], %[f]\n"
                         ".endr\n"
                         : [a] "+f"(accum)
                         : [f] "f"(factor));
        c1 = rdcycle();
        i1 = rdinstret();
        BENCH_PROFILE_END("Bench 10: Dependent FMUL.D chain");
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 11: Independent FMUL.D chains (4 x 12 = 48 instructions)    */
    /* 4 independent FMUL.D chains. FP analogue of Bench 4.                  */
    /* ===================================================================== */
    uart_printf("Bench 11: Independent FMUL.D chains (4x12 = 48 instrs)\n");
    {
        double m0 = 1.0, m1 = 2.0, m2 = 3.0, m3 = 4.0;
        double factor = 1.0;
        BENCH_PROFILE_BEGIN();
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile(".rept 12\n"
                         "fmul.d %[m0], %[m0], %[f]\n"
                         "fmul.d %[m1], %[m1], %[f]\n"
                         "fmul.d %[m2], %[m2], %[f]\n"
                         "fmul.d %[m3], %[m3], %[f]\n"
                         ".endr\n"
                         : [m0] "+f"(m0), [m1] "+f"(m1), [m2] "+f"(m2), [m3] "+f"(m3)
                         : [f] "f"(factor));
        c1 = rdcycle();
        i1 = rdinstret();
        BENCH_PROFILE_END("Bench 11: Independent FMUL.D chains");
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 12: Dependent FMADD.D chain (50 instructions)               */
    /* Fused multiply-add: accum = accum * 1.0 + 0.5, serialized.            */
    /* ===================================================================== */
    uart_printf("Bench 12: Dependent FMADD.D chain (50 instrs)\n");
    {
        double accum = 0.0, mul_one = 1.0, add_half = 0.5;
        BENCH_PROFILE_BEGIN();
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile(".rept 50\n"
                         "fmadd.d %[a], %[a], %[m], %[c]\n"
                         ".endr\n"
                         : [a] "+f"(accum)
                         : [m] "f"(mul_one), [c] "f"(add_half));
        c1 = rdcycle();
        i1 = rdinstret();
        BENCH_PROFILE_END("Bench 12: Dependent FMADD.D chain");
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 13: Mixed FP + INT (50 pairs = 100 instructions)            */
    /* Tests cross-unit parallelism: FP and INT units should work in         */
    /* parallel since there are no data dependencies between them.           */
    /* ===================================================================== */
    uart_printf("Bench 13: Mixed FP+INT (50 pairs = 100 instrs)\n");
    {
        double fp_acc = 1.0, fp_inc = 0.5;
        BENCH_PROFILE_BEGIN();
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile("addi t0, zero, 0\n"
                         "addi t1, zero, 1\n"
                         ".rept 50\n"
                         "fadd.d %[fa], %[fa], %[fi]\n"
                         "add    t0, t0, t1\n"
                         ".endr\n"
                         : [fa] "+f"(fp_acc)
                         : [fi] "f"(fp_inc)
                         : "t0", "t1");
        c1 = rdcycle();
        i1 = rdinstret();
        BENCH_PROFILE_END("Bench 13: Mixed FP+INT");
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Atomics                                                               */
    /* ===================================================================== */
    uart_printf("\n--- Atomics ---\n\n");

    /* ===================================================================== */
    /* Benchmark 14: Load + younger AMOADD.W (50 iters, 6 instrs/iter)       */
    /* The load's address depends on the previous AMO's result, so the load  */
    /* reaches the ROB head before it can issue and waits there while the    */
    /* AMO behind it is pending in the load queue: the head-load wait split  */
    /* runs with an AMO in flight. The two words sit in different dwords.    */
    /* ===================================================================== */
    uart_printf("Bench 14: Load + younger AMOADD.W (50 iters, 6 instrs/iter)\n");
    {
        volatile uint32_t amo_area[4] = {1U, 0U, 0U, 0U};
        BENCH_PROFILE_BEGIN();
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile("addi t0, zero, 50\n"
                         "addi t2, zero, 1\n"
                         "addi t3, zero, 0\n"
                         "1:\n"
                         "and  t4, t3, zero\n" /* 0, available with the previous AMO */
                         "add  t4, t4, %[ld]\n"
                         "lw   t1, 0(t4)\n"
                         "amoadd.w t3, t2, (%[amo])\n"
                         "addi t0, t0, -1\n"
                         "bne  t0, zero, 1b\n"
                         :
                         : [ld] "r"(&amo_area[0]), [amo] "r"(&amo_area[2])
                         : "t0", "t1", "t2", "t3", "t4", "memory");
        c1 = rdcycle();
        i1 = rdinstret();
        BENCH_PROFILE_END("Bench 14: Load + younger AMOADD.W");
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Summary                                                               */
    /* ===================================================================== */
    uart_printf("\n============================================================\n");
    uart_printf("  Performance measurement complete.\n");
    uart_printf("  INT: Compare Bench 1 vs 2 (ADD) and Bench 3 vs 4 (MUL)\n");
    uart_printf("  FP:  Compare Bench 8 vs 9 (FADD) and Bench 10 vs 11 (FMUL)\n");
    uart_printf("  to see the IPC benefit of out-of-order execution.\n");
    uart_printf("============================================================\n\n");

#if TOMASULO_PERF_ENABLE_PROFILE
    if (bench_profile_failures != 0) {
        uart_printf("<<FAIL>>\n");
        return 1;
    }
#endif
    uart_printf("<<PASS>>\n");

    return 0;
}
