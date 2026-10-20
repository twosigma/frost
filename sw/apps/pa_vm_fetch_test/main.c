/*
 *    Copyright (c) 2026 John Goodacre
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

/* Execute an Sv39 4 KiB leaf backed by the final physical DDR page. Keep
 * the page tables low, so a failure isolates translation/fetch of the high
 * code address. The sparse DDR model supplies the configured raw capacity;
 * this is not a product DMC or board test. */
#include <stdint.h>

#include "trap.h"
#include "uart.h"

#ifndef FROST_DDR_CAPACITY_LOG2_BYTES
#error FROST_DDR_CAPACITY_LOG2_BYTES must match the RTL build
#endif
#if FROST_DDR_CAPACITY_LOG2_BYTES < 30 || FROST_DDR_CAPACITY_LOG2_BYTES > 37
#error DDR aperture must be one of 1..128 GiB
#endif

#define DDR_BASE 0x80000000ul
#define DDR_END (DDR_BASE + (1ul << FROST_DDR_CAPACITY_LOG2_BYTES))
#define PT_ROOT 0x81000000ul
#define PT_L1 0x81001000ul
#define PT_L0 0x81002000ul
#define TEST_VA 0x00400000ul
#define PTE_V (1ul << 0)
#define PTE_X (1ul << 3)
#define PTE_A (1ul << 6)
#define PTE_PPN(pa) ((((unsigned long) (pa)) >> 12) << 10)
#define SATP_SV39 (8ul << 60)

static volatile unsigned long g_cause;
static volatile unsigned long g_epc;
static volatile unsigned long g_a0;

__attribute__((naked, aligned(4))) static void fetch_trap_handler(void)
{
    __asm__ volatile("csrr t0, mcause\n"
                     "la   t1, g_cause\n"
                     "sd   t0, 0(t1)\n"
                     "csrr t0, mepc\n"
                     "la   t1, g_epc\n"
                     "sd   t0, 0(t1)\n"
                     "la   t1, g_a0\n"
                     "sd   a0, 0(t1)\n"
                     "csrr t0, mscratch\n"
                     "csrw mepc, t0\n"
                     "li   t0, 0x1800\n"
                     "csrs mstatus, t0\n"
                     "mret\n");
}

static void run_at(unsigned long target)
{
    g_cause = ~0ul;
    g_epc = ~0ul;
    g_a0 = ~0ul;
    __asm__ volatile("la   t0, 1f\n"
                     "csrw mscratch, t0\n"
                     "li   t0, 0x1800\n"
                     "csrc mstatus, t0\n"
                     "li   t0, 0x800\n"
                     "csrs mstatus, t0\n"
                     "csrw mepc, %0\n"
                     "li   a0, 0\n"
                     "mret\n"
                     "1:\n"
                     :
                     : "r"(target)
                     : "t0", "t1", "t2", "t3", "a0", "ra", "memory");
}

static int check_run(unsigned long marker, const char *name)
{
    int ok = (g_cause == 9ul) && (g_epc == TEST_VA + 4ul) && (g_a0 == marker);
    if (!ok)
        uart_printf("Sv39 %s fetch failed: cause=%lx epc=%lx a0=%lx\n", name, g_cause, g_epc, g_a0);
    return ok;
}

int main(void)
{
    volatile unsigned long *root = (volatile unsigned long *) PT_ROOT;
    volatile unsigned long *l1 = (volatile unsigned long *) PT_L1;
    volatile unsigned long *l0 = (volatile unsigned long *) PT_L0;
    const unsigned long code_pa[2] = {DDR_BASE + 0x2000ul, DDR_END - 4096ul};
    const unsigned long marker[2] = {0x61ul, 0xb7ul};
    int failures = 0;

    set_trap_handler(&fetch_trap_handler);
    for (unsigned i = 0; i < 512; ++i) {
        root[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    root[0] = PTE_PPN(PT_L1) | PTE_V;
    l1[2] = PTE_PPN(PT_L0) | PTE_V;

    for (unsigned i = 0; i < 2; ++i) {
        volatile uint32_t *code = (volatile uint32_t *) code_pa[i];
        code[0] = (uint32_t) ((marker[i] << 20) | 0x00000513ul); /* addi a0,x0,marker */
        code[1] = 0x00000073u;                                   /* ecall */
        l0[0] = PTE_PPN(code_pa[i]) | PTE_V | PTE_X | PTE_A;
        __asm__ volatile("fence rw,rw\nfence.i\nsfence.vma" ::: "memory");
        __asm__ volatile("csrw satp, %0" : : "r"(SATP_SV39 | (PT_ROOT >> 12)) : "memory");
        __asm__ volatile("sfence.vma" ::: "memory");
        run_at(TEST_VA);
        failures += !check_run(marker[i], i ? "high" : "low");
    }
    __asm__ volatile("csrw satp, zero\nsfence.vma" ::: "memory");

    uart_printf(failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
}
