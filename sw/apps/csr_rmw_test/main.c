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

/*
 * Directed CSR read-modify-write test.
 *
 * No-MMU M-mode Linux panics on the FIRST machine-timer interrupt with
 * epc==ra==garbage (a `ret` through a clobbered return address). The kernel's
 * trap entry swaps the thread pointer with `csrrw tp, mscratch, tp`, while the
 * PASSING paths (umode_test, FreeRTOS) only ever use separate csrr/csrw -- so
 * FROST's CSR read-modify-write instructions are an untested differentiator.
 *
 * This isolates whether csrrw/csrrs/csrrc correctly (a) return the OLD CSR
 * value into rd AND (b) write the new value -- including the same-register swap
 * idiom (`csrrw t0, mscratch, t0`) the kernel depends on. Self-checks over UART
 * with <<PASS>> / <<FAIL>>.
 */

#include <stdint.h>

#include "uart.h"

static int g_ok = 1;

static void check(const char *name, uint32_t got, uint32_t want)
{
    int ok = (got == want);
    if (!ok)
        g_ok = 0;
    uart_printf("%s %s: got=%08x want=%08x\n", ok ? "[PASS]" : "[FAIL]", name, got, want);
}

static inline uint32_t rd_scratch(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, mscratch" : "=r"(v));
    return v;
}

static inline void wr_scratch(uint32_t v)
{
    __asm__ volatile("csrw mscratch, %0" : : "r"(v));
}

int main(void)
{
    uint32_t old, cur, swapped;

    uart_printf("\n=== CSR read-modify-write directed test ===\n");

    /* csrrw: rd <- old(CSR); CSR <- rs1 */
    wr_scratch(0xAAAA1111u);
    __asm__ volatile("li t0, 0xBBBB2222\n\tcsrrw %0, mscratch, t0" : "=r"(old) : : "t0");
    cur = rd_scratch();
    check("csrrw returns old", old, 0xAAAA1111u);
    check("csrrw writes new", cur, 0xBBBB2222u);

    /* csrrs: rd <- old; CSR <- old | rs1 */
    wr_scratch(0xF0F0F0F0u);
    __asm__ volatile("li t0, 0x0F0F0F0F\n\tcsrrs %0, mscratch, t0" : "=r"(old) : : "t0");
    cur = rd_scratch();
    check("csrrs returns old", old, 0xF0F0F0F0u);
    check("csrrs sets bits", cur, 0xFFFFFFFFu);

    /* csrrc: rd <- old; CSR <- old & ~rs1 */
    wr_scratch(0xFFFFFFFFu);
    __asm__ volatile("li t0, 0x0F0F0F0F\n\tcsrrc %0, mscratch, t0" : "=r"(old) : : "t0");
    cur = rd_scratch();
    check("csrrc returns old", old, 0xFFFFFFFFu);
    check("csrrc clears bits", cur, 0xF0F0F0F0u);

    /* csrrw with x0 destination must STILL write the CSR (== csrw). */
    wr_scratch(0x12345678u);
    __asm__ volatile("li t0, 0x9ABCDEF0\n\tcsrrw x0, mscratch, t0" : : : "t0");
    cur = rd_scratch();
    check("csrrw x0-dest still writes", cur, 0x9ABCDEF0u);

    /* THE KERNEL PATTERN: `csrrw t0, mscratch, t0` (same reg as rd and rs1 =
     * atomic swap). After: t0 <- old(CSR), CSR <- old(t0). */
    wr_scratch(0xCAFEBABEu);
    __asm__ volatile("li t0, 0xDEADBEEF\n\tcsrrw t0, mscratch, t0\n\tmv %0, t0"
                     : "=r"(swapped)
                     :
                     : "t0");
    cur = rd_scratch();
    check("csrrw swap: reg<-old", swapped, 0xCAFEBABEu);
    check("csrrw swap: CSR<-reg", cur, 0xDEADBEEFu);

    uart_printf(g_ok ? "\n<<PASS>>\n" : "\n<<FAIL>>\n");
    for (;;) {
    }
    return 0;
}
