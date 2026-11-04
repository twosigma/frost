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


#include <stdint.h>

#include "csr.h"
#include "uart.h"

#define cells ((volatile uint64_t *) (uintptr_t) 0x81080000)
volatile uint64_t traps;

__attribute__((naked, aligned(4))) static void store_trap(void)
{
    __asm__ volatile("addi sp, sp, -16\n"
                     "sd t0, 0(sp)\n"
                     "sd t1, 8(sp)\n"
                     "la t0, traps\n"
                     "ld t1, 0(t0)\n"
                     "addi t1, t1, 1\n"
                     "sd t1, 0(t0)\n"
                     "csrr t0, mepc\n"
                     "addi t0, t0, 4\n"
                     "csrw mepc, t0\n"
                     "ld t0, 0(sp)\n"
                     "ld t1, 8(sp)\n"
                     "addi sp, sp, 16\n"
                     "mret\n");
}

int main(void)
{
    csr_write(mtvec, (uintptr_t) store_trap);
    traps = 0;
    for (unsigned i = 0; i < 64; i++)
        cells[i] = i;
    __asm__ volatile("fence rw, rw" ::: "memory");
    int fail = cells[0] != 0;
    for (uint64_t value = 1; value <= 16; value++) {
        uint64_t merged;
        __asm__ volatile("sd %[v], 0(%[p])\n"
                         "sb %[v], 1(%[p])\n"
                         "sh %[v], 2(%[p])\n"
                         "ld %[r], 0(%[p])\n"
                         : [r] "=r"(merged)
                         : [p] "r"(cells), [v] "r"(value)
                         : "memory");
        fail |= merged != (value | (value << 8) | (value << 16));
        /* Each sequence leaves several committed stores for the drain gate. */
        __asm__ volatile("sd %[v], 0(%[p])\n"
                         "sd %[v], 8(%[p])\n"
                         "sd %[v], 32(%[p])\n"
                         "sd %[v], 40(%[p])\n"
                         "sb %[v], 1(%[p])\n"
                         "sh %[v], 2(%[p])\n"
                         "fence.i\n" ::[p] "r"(cells),
                         [v] "r"(value)
                         : "memory");
        fail |= cells[0] != (value | (value << 8) | (value << 16));
        fail |= cells[1] != value || cells[4] != value || cells[5] != value;
        __asm__ volatile("sd %[v], 0(%[p])\n"
                         "sd %[v], 8(%[p])\n"
                         "sd %[v], 32(%[p])\n"
                         "sd %[v], 40(%[p])\n"
                         "ecall\n" ::[p] "r"(cells),
                         [v] "r"(value)
                         : "memory");
        fail |= cells[0] != value || cells[5] != value;
        uint64_t old, status;
        __asm__ volatile("sd %[v], 0(%[p])\n"
                         "sd %[v], 8(%[p])\n"
                         "sd %[v], 32(%[p])\n"
                         "lr.d %[old], (%[p])\n"
                         "sc.d %[status], %[v], (%[p])\n"
                         : [old] "=&r"(old), [status] "=&r"(status)
                         : [p] "r"(cells), [v] "r"(value)
                         : "memory");
        fail |= old != value || status != 0;
        __asm__ volatile("sd %[v], 0(%[p])\n"
                         "sd %[v], 8(%[p])\n"
                         "sd %[v], 32(%[p])\n"
                         "amoadd.d %[old], %[v], (%[p])\n"
                         : [old] "=&r"(old)
                         : [p] "r"(cells), [v] "r"(value)
                         : "memory");
        fail |= old != value || cells[0] != 2 * value;
    }
    fail |= traps != 16;
    uart_puts(fail ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
    return 0;
}
