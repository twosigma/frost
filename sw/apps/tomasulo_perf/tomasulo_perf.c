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
 * Tomasulo Performance Measurement
 *
 * Measures Instructions Per Cycle (IPC) across different workloads to
 * quantify the benefit of out-of-order execution via Tomasulo's algorithm.
 *
 * Key comparison: dependent vs independent instruction chains.
 *   - Dependent chains serialize on data hazards (IPC limited to ~1.0)
 *   - Independent chains can exploit ILP (IPC scales with issue width)
 *   - The ratio between them shows the OOO execution benefit
 *
 * Uses hardware cycle and instret counters (Zicntr CSRs) for measurement.
 * IPC is reported as IPC*100 (integer, so 150 means IPC = 1.50).
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
 *  12. Dependent FMADD.D chain  (fused multiply-add, key for numerics)
 *  13. Mixed FP + INT           (cross-unit parallelism)
 */

#include "csr.h"
#include "uart.h"
#include <stdint.h>

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

    uart_printf("\n");
    uart_printf("============================================================\n");
    uart_printf("     TOMASULO PERFORMANCE MEASUREMENT\n");
    uart_printf("============================================================\n");
    uart_printf("  IPC*100: 100 = 1.0 IPC, 150 = 1.5 IPC, etc.\n\n");

    /* ===================================================================== */
    /* Benchmark 1: Dependent ADD chain (100 instructions)                   */
    /* Each ADD reads the result of the previous one - no ILP possible.      */
    /* Baseline for comparison: OOO cannot help here.                        */
    /* ===================================================================== */
    uart_printf("Bench 1: Dependent ADD chain (100 instrs)\n");
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
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 2: Independent ADD chains (4 x 25 = 100 instructions)       */
    /* 4 chains with no cross-dependencies - ideal for OOO execution.        */
    /* IPC should be higher than Bench 1 if OOO is working.                  */
    /* ===================================================================== */
    uart_printf("Bench 2: Independent ADD chains (4x25 = 100 instrs)\n");
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
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 3: Dependent MUL chain (50 instructions)                    */
    /* MUL has multi-cycle latency, so a dependent chain is very slow.       */
    /* Multiply by 1 to keep the value stable (avoids overflow).             */
    /* ===================================================================== */
    uart_printf("Bench 3: Dependent MUL chain (50 instrs)\n");
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
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 4: Independent MUL chains (4 x 12 = 48 instructions)        */
    /* 4 independent MUL chains. If the MUL unit is pipelined or there are   */
    /* multiple MUL reservation stations, these can overlap.                  */
    /* ===================================================================== */
    uart_printf("Bench 4: Independent MUL chains (4x12 = 48 instrs)\n");
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
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 5: Mixed MUL + independent ADD (100 instruction pairs)      */
    /* Tests whether short-latency ADDs can execute while MUL is in flight.  */
    /* An OOO machine should overlap the ADD with the MUL stall.             */
    /* ===================================================================== */
    uart_printf("Bench 5: Mixed MUL+ADD (50 pairs = 100 instrs)\n");
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
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Benchmark 6: Load-store throughput (50 store-load pairs)              */
    /* Alternating store and load to the same address.                        */
    /* Tests store-load forwarding and memory subsystem throughput.           */
    /* ===================================================================== */
    uart_printf("Bench 6: Load-store pairs (50 pairs = 100 instrs)\n");
    {
        volatile uint32_t mem_area[4];
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
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 7: Branch-heavy loop (200 iterations, 3 instrs/iter)        */
    /* Tests branch prediction integration with OOO pipeline.                */
    /* Good prediction allows the loop body to overlap across iterations.    */
    /* ===================================================================== */
    uart_printf("Bench 7: Branch loop (200 iters, 3 instrs/iter)\n");
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
    print_result(c1 - c0, i1 - i0);

    /* ===================================================================== */
    /* Floating-Point Benchmarks                                             */
    /* ===================================================================== */
    uart_printf("\n--- Floating-Point Benchmarks (double-precision) ---\n\n");

    /* ===================================================================== */
    /* Benchmark 8: Dependent FADD.D chain (100 instructions)                */
    /* Each FADD.D reads the result of the previous one - no ILP possible.   */
    /* FP analogue of Bench 1.                                               */
    /* ===================================================================== */
    uart_printf("Bench 8: Dependent FADD.D chain (100 instrs)\n");
    {
        double accum = 1.0, incr = 0.5;
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile(".rept 100\n"
                         "fadd.d %[a], %[a], %[i]\n"
                         ".endr\n"
                         : [a] "+f"(accum)
                         : [i] "f"(incr));
        c1 = rdcycle();
        i1 = rdinstret();
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 9: Independent FADD.D chains (4 x 25 = 100 instructions)    */
    /* 4 chains with no cross-dependencies - ideal for OOO execution.        */
    /* FP analogue of Bench 2.                                               */
    /* ===================================================================== */
    uart_printf("Bench 9: Independent FADD.D chains (4x25 = 100 instrs)\n");
    {
        double a0 = 1.0, a1 = 2.0, a2 = 3.0, a3 = 4.0;
        double inc = 0.5;
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
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 10: Dependent FMUL.D chain (50 instructions)                */
    /* FMUL.D has multi-cycle latency; dependent chain is very slow.         */
    /* Multiply by 1.0 to keep value stable. FP analogue of Bench 3.        */
    /* ===================================================================== */
    uart_printf("Bench 10: Dependent FMUL.D chain (50 instrs)\n");
    {
        double accum = 2.0, factor = 1.0;
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile(".rept 50\n"
                         "fmul.d %[a], %[a], %[f]\n"
                         ".endr\n"
                         : [a] "+f"(accum)
                         : [f] "f"(factor));
        c1 = rdcycle();
        i1 = rdinstret();
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 11: Independent FMUL.D chains (4 x 12 = 48 instructions)   */
    /* 4 independent FMUL.D chains. FP analogue of Bench 4.                 */
    /* ===================================================================== */
    uart_printf("Bench 11: Independent FMUL.D chains (4x12 = 48 instrs)\n");
    {
        double m0 = 1.0, m1 = 2.0, m2 = 3.0, m3 = 4.0;
        double factor = 1.0;
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
        print_result(c1 - c0, i1 - i0);
    }

    /* ===================================================================== */
    /* Benchmark 12: Dependent FMADD.D chain (50 instructions)               */
    /* Fused multiply-add: accum = accum * 1.0 + 0.5, serialized.           */
    /* Key for numerical workloads (BLAS, FFT, etc.).                        */
    /* ===================================================================== */
    uart_printf("Bench 12: Dependent FMADD.D chain (50 instrs)\n");
    {
        double accum = 0.0, mul_one = 1.0, add_half = 0.5;
        c0 = rdcycle();
        i0 = rdinstret();
        __asm__ volatile(".rept 50\n"
                         "fmadd.d %[a], %[a], %[m], %[c]\n"
                         ".endr\n"
                         : [a] "+f"(accum)
                         : [m] "f"(mul_one), [c] "f"(add_half));
        c1 = rdcycle();
        i1 = rdinstret();
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

    uart_printf("<<PASS>>\n");

    return 0;
}
