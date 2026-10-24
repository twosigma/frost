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

/* The registry injects a DDR read error at ERROR_TABLE. Valid parent PTEs
 * direct load and store walks there at levels 1 and 0. The exception must
 * name the original operation and VA, and a repaired mapping must work.
 */
#include <stdint.h>

#include "csr.h"
#include "trap.h"

#define ROOT 0x81000000ul
#define TABLE 0x81001000ul
#define ERROR_TABLE 0x83000000ul
#define FRAME 0x81200000ul
#define VA 0x00400018ul
#define VALUE 0x12345678ul
#define PTE_POINTER(pa) (((pa) >> 2) | 1ul)
#define PTE_LEAF(pa) (((pa) >> 2) | 0xCFul)

static volatile unsigned long cause, tval, epc, expected_pc, value, faults;

static void puts_uart(const char *s)
{
    while (*s)
        UART_TX = (uint8_t) *s++;
}

__attribute__((naked, aligned(4))) static void fault_entry(void)
{
    __asm__ volatile("li t0, 0x20000\n"
                     "csrc mstatus, t0\n"
                     "csrr t0, mcause\n"
                     "la t1, cause\n sd t0, 0(t1)\n"
                     "csrr t0, mtval\n"
                     "la t1, tval\n sd t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la t1, epc\n sd t0, 0(t1)\n"
                     "la t1, faults\n ld t0, 0(t1)\n addi t0, t0, 1\n sd t0, 0(t1)\n"
                     "csrr t0, mscratch\n csrw mepc, t0\n"
                     "li t0, 0x1800\n csrs mstatus, t0\n"
                     "mret\n");
}

/* Only the tested instruction uses translated data. A fault returns past
 * the result store, leaving value unchanged. The handler uses t0 and t1.
 */
#define PROBE_AT(instruction, address)                                                             \
    do {                                                                                           \
        cause = ~0ul;                                                                              \
        tval = ~0ul;                                                                               \
        epc = ~0ul;                                                                                \
        value = ~0ul;                                                                              \
        faults = 0;                                                                                \
        __asm__ volatile(".option push\n.option norvc\n"                                           \
                         "la t0, 1f\n csrw mscratch, t0\n"                                         \
                         "la t0, 2f\n la t1, expected_pc\n sd t0, 0(t1)\n"                         \
                         "li t0, 0x1800\n csrc mstatus, t0\n"                                      \
                         "li t0, 0x20800\n csrs mstatus, t0\n"                                     \
                         "li t3, 0x12345678\n"                                                     \
                         "2:\n" instruction "li t0, 0x20000\n csrc mstatus, t0\n"                  \
                         "la t1, value\n sd t3, 0(t1)\n"                                           \
                         "1:\n.option pop\n"                                                       \
                         :                                                                         \
                         : "r"(address)                                                            \
                         : "t0", "t1", "t3", "memory");                                            \
    } while (0)

#define PROBE(instruction) PROBE_AT(instruction, VA)

static int fault_matches(unsigned long wanted)
{
    return cause == wanted && tval == VA && epc == expected_pc && value == ~0ul && faults == 1;
}

int main(void)
{
    volatile unsigned long *root = (volatile unsigned long *) ROOT;
    volatile unsigned long *table = (volatile unsigned long *) TABLE;
    volatile unsigned long *data = (volatile unsigned long *) (FRAME + 24);
    int ok = 1;

    puts_uart("PTW bus fault test\r\n");
    set_trap_handler(fault_entry);
    csr_write(mie, 0);

    /* Two L1D sectors share one failed L2 fill. The older load traps and
     * the younger response drains without faulting another instruction.
     */
    PROBE_AT("ld t3, 0(%0)\n ld t3, 32(%0)\n", ERROR_TABLE);
    ok &= cause == 5 && tval == 0 && epc == expected_pc && faults == 1;
    csr_write(satp, (8ul << 60) | (ROOT >> 12));

    for (int level = 1; level >= 0; level--) {
        /* ERROR_TABLE is never written or cached before its failing walk. */
        root[0] = PTE_POINTER(level ? ERROR_TABLE : TABLE);
        table[2] = PTE_POINTER(ERROR_TABLE);
        *data = 0x55AA;
        __asm__ volatile("sfence.vma" ::: "memory");
        PROBE("ld t3, 0(%0)\n");
        ok &= fault_matches(5);
        PROBE("sd t3, 0(%0)\n");
        ok &= fault_matches(7);
        ok &= *data == 0x55AA;

        root[0] = PTE_POINTER(TABLE);
        table[2] = PTE_LEAF(FRAME);
        __asm__ volatile("sfence.vma" ::: "memory");
        PROBE("ld t3, 0(%0)\n");
        ok &= cause == ~0ul && value == 0x55AA;
        PROBE("sd t3, 0(%0)\n");
        ok &= cause == ~0ul;
        PROBE("ld t3, 0(%0)\n");
        ok &= cause == ~0ul && value == VALUE;
        ok &= *data == VALUE;
    }
    csr_write(satp, 0);
    puts_uart(ok ? "<<PASS>>\r\n" : "<<FAIL>>\r\n");
    return 0;
}
