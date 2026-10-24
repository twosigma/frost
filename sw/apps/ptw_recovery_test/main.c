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

/* A taken branch kills a speculative walk while a dependent arithmetic
 * chain varies its resolution edge. Recovery either replaces the data
 * operation directly or discards the walker through SFENCE.VMA.
 */
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
        PHASE(1);
        PHASE(2);
        PHASE(3);
        PHASE(4);
        PHASE(5);
        PHASE(6);
        PHASE(7);
        PHASE(8);
        PHASE(9);
        PHASE(10);
        PHASE(11);
        PHASE(12);
        PHASE(13);
        PHASE(14);
        PHASE(15);
        PHASE(16);
        PHASE(17);
        PHASE(18);
        PHASE(19);
        PHASE(20);
        PHASE(21);
        PHASE(22);
        PHASE(23);
        PHASE(24);
        PHASE(25);
        PHASE(26);
        PHASE(27);
        PHASE(28);
        PHASE(29);
        PHASE(30);
        PHASE(31);
        default:
            return 0;
    }
    return value;
}

int main(void)
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
        for (unsigned int delay = 0; delay < 32; delay++) {
            __asm__ volatile("sfence.vma" ::: "memory");
            ok &= probe(delay, discard, 1) == VALUE;
            __asm__ volatile("sfence.vma" ::: "memory");
            ok &= probe(delay, discard, 0) == VALUE;
        }
    }
    csr_write(satp, 0);
    ok &= faults == 0;
    uart_puts(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    return 0;
}
