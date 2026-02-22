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
 * Benchmarks:
 *   1. Dependent ADD chain      (worst-case ILP: serialized)
 *   2. Independent ADD chains   (best-case ILP: fully parallel)
 *   3. Dependent MUL chain      (long-latency serialized)
 *   4. Independent MUL chains   (long-latency parallel)
 *   5. Mixed MUL + ADD          (latency hiding)
 *   6. Load-store throughput    (memory subsystem)
 *   7. Branch-heavy loop        (branch prediction + OOO)
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
    /* Summary                                                               */
    /* ===================================================================== */
    uart_printf("\n============================================================\n");
    uart_printf("  Performance measurement complete.\n");
    uart_printf("  Compare Bench 1 vs 2 (ADD) and Bench 3 vs 4 (MUL)\n");
    uart_printf("  to see the IPC benefit of out-of-order execution.\n");
    uart_printf("============================================================\n\n");

    uart_printf("<<PASS>>\n");

    return 0;
}
