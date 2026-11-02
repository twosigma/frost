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

/* DDR instruction refills and translation-invalidating recovery. */
#include <stdint.h>

#include "csr.h"
#include "trap.h"
#include "uart.h"

#define ROOT 0x81400000ul
#define TABLE 0x81401000ul
#define FRAME 0x81800000ul
#define BAD_VA 0x08000018ul
#define GOOD_VA 0x08200018ul
#define VALUE 0x55AA1234ul
#define QUOTIENT 0x1111111111111111ul

static volatile unsigned long faults;

__attribute__((naked, aligned(4))) static void fault_entry(void)
{
    __asm__ volatile("li t0, 0x20000\n csrc mstatus, t0\n"
                     "la t1, faults\n ld t0, 0(t1)\n addi t0, t0, 1\n sd t0, 0(t1)\n"
                     "csrr t0, mscratch\n csrw mepc, t0\n"
                     "li t0, 0x1800\n csrs mstatus, t0\n mret\n");
}

#define PROBE(delay, discard)                                                                      \
    __asm__ volatile(".option push\n.option norvc\n"                                               \
                     "li %0, -1\n la t0, 3f\n csrw mscratch, t0\n"                                 \
                     "li t0, 0x1800\n csrc mstatus, t0\n"                                          \
                     "li t0, 0x20800\n csrs mstatus, t0\n"                                         \
                     "mv t0, %4\n li t1, 3\n div t0, t0, t1\n"                                     \
                     "mv t2, t0\n.rept " #delay "\n mul t2, t2, t1\n.endr\n"                       \
                     "bnez t2, 1f\n sub t1, t0, %3\n add t1, t1, %1\n ld %0, 0(t1)\n"              \
                     "1:\n" discard "ld %0, 0(%2)\n"                                               \
                     "li t0, 0x20000\n csrc mstatus, t0\n"                                         \
                     "3:\n.option pop\n"                                                           \
                     : "=&r"(value)                                                                \
                     : "r"(train ? GOOD_VA : BAD_VA),                                              \
                       "r"(GOOD_VA),                                                               \
                       "r"(train ? 0ul : QUOTIENT),                                                \
                       "r"(train ? 0ul : 0x3333333333333333ul)                                     \
                     : "t0", "t1", "t2", "memory")

#define PHASE(n)                                                                                   \
    case n:                                                                                        \
        if (discard) {                                                                             \
            PROBE(n, "sfence.vma\n");                                                              \
        } else {                                                                                   \
            PROBE(n, "");                                                                          \
        }                                                                                          \
        break

/* Training and faulting passes use the same branch instruction addresses. */
__attribute__((noinline, noclone)) static unsigned long
probe(unsigned int delay, int discard, int train)
{
    unsigned long value;
    switch (delay) {
        PHASE(0);
        PHASE(4);
        PHASE(8);
        PHASE(12);
        PHASE(16);
        PHASE(20);
        PHASE(24);
        PHASE(28);
        default:
            return 0;
    }
    return value;
}

static int exercise_walk_recovery(void)
{
    volatile uint64_t *root = (volatile uint64_t *) ROOT;
    volatile uint64_t *table = (volatile uint64_t *) TABLE;
    int ok = 1;
    set_trap_handler(fault_entry);
    csr_write(mie, 0);
    root[0] = (TABLE >> 2) | 1ul;
    table[64] = 0;
    table[65] = (FRAME >> 2) | 0xCFul;
    *(volatile uint64_t *) (FRAME + 24) = VALUE;
    csr_write(satp, (8ul << 60) | (ROOT >> 12));
    for (int discard = 0; discard < 2; discard++) {
        for (unsigned int delay = 0; delay < 32; delay += 4) {
            __asm__ volatile("sfence.vma" ::: "memory");
            ok &= probe(delay, discard, 1) == VALUE;
            __asm__ volatile("sfence.vma" ::: "memory");
            ok &= probe(delay, discard, 0) == VALUE;
        }
    }
    csr_write(satp, 0);
    ok &= faults == 0;
    return ok;
}

__attribute__((section(".ddr_data"), aligned(64))) static volatile uint32_t code[32];
static volatile uint32_t *volatile code_address = code;
typedef unsigned long (*code_fn_t)(void);

static int exercise_code(void)
{
    volatile uint32_t *p = code_address;
    for (int n = 0; n < 32; n++)
        p[n] = 0x00000013;
    p[8] = 0x00150513; /* addi a0,a0,1 */
    p[9] = 0x00008067; /* ret */
    for (unsigned long value = 1; value <= 8; value++) {
        p[0] = (uint32_t) (value << 20) | 0x00000513;
        __asm__ volatile("fence.i" ::: "memory");
        if (((code_fn_t) (uintptr_t) p)() != value + 1)
            return 0;
    }
    return 1;
}

static int exercise_translated_code(void)
{
    volatile uint64_t *root = (volatile uint64_t *) ROOT;
    volatile uint32_t *p = code_address;
    root[2] = (0x80000000ul >> 2) | 0xCFul;
    p[0] = 0x02A00513; /* addi a0,x0,42 */
    p[9] = 0x00000073; /* ecall */
    csr_write(satp, (8ul << 60) | (ROOT >> 12));
    __asm__ volatile("sfence.vma\n fence.i" ::: "memory");
    unsigned long result;
    __asm__ volatile("la t0, 1f\n csrw mscratch, t0\n csrw mepc, %1\n"
                     "li t0, 0x1800\n csrc mstatus, t0\n"
                     "li t0, 0x800\n csrs mstatus, t0\n mret\n"
                     "1: mv %0, a0\n"
                     : "=r"(result)
                     : "r"(p)
                     : "t0", "t1", "a0", "memory");
    csr_write(satp, 0);
    return result == 43 && csr_read(mcause) == 9;
}

static int fence_with_prefetch(void)
{
    volatile uint32_t *p = (volatile uint32_t *) 0x83000020ul;
    p[0] = 0x0000100F; /* fence.i */
    p[1] = 0x00700513; /* addi a0,x0,7 */
    p[2] = 0x00008067; /* ret */
    __asm__ volatile("fence.i" ::: "memory");
    return ((code_fn_t) (uintptr_t) p)() == 7;
}

int main(void)
{
    int ok = fence_with_prefetch();
    ok &= exercise_code();
    ok &= exercise_walk_recovery();
    ok &= exercise_translated_code();
    uart_puts(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    return 0;
}
