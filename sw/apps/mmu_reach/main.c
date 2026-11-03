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

/* Sv39 TLB capacity, walk depth, and address space switch timing. */
#include "uart.h"
#include <stdint.h>

#define ROOT 0x82000000ul
#define DATA 0x81000000ul
#define CODE 0x81800000ul
#define DVA 0x10000000ul
#define IVA 0x20000000ul
#define SV39 (8ul << 60)
#define RW 0xc7ul
#define RX 0xcbul

struct result {
    unsigned long cycles, signature;
};
extern struct result data_chain(unsigned long, unsigned long, unsigned long, unsigned long);
extern struct result context_chain(
    unsigned long, unsigned long, unsigned long, unsigned long, unsigned long, unsigned long);
extern unsigned long instruction_chain(unsigned long, unsigned long, unsigned long);
extern unsigned long validate_chain(unsigned long, unsigned long, unsigned long, unsigned long);

static unsigned long pte(unsigned long pa, unsigned long flags)
{
    return ((pa >> 12) << 10) | flags;
}

static void clear_tables(unsigned long root)
{
    volatile unsigned long *l2 = (void *) root;
    volatile unsigned long *l1 = (void *) (root + 4096);
    volatile unsigned long *l0 = (void *) (root + 8192);
    /* Clear the reachable slots and a guard beyond the longest ring. */
    for (unsigned i = 0; i < 66; i++) {
        l2[i] = 0;
        l1[(DVA >> 21) + i] = 0;
        l0[i] = 0;
    }
    l1[IVA >> 21] = 0;
}

static void activate(unsigned long root)
{
    unsigned long s = SV39 | (root >> 12);
    __asm__ volatile("fence rw,rw; csrw satp, %0; sfence.vma" : : "r"(s) : "memory");
}

static unsigned long data_va(unsigned level, unsigned i)
{
    if (level == 2)
        return ((unsigned long) (i + 1) << 30) + (DATA - 0x80000000ul) + i * 16;
    return DVA + ((unsigned long) i << (12 + 9 * level)) + i * 16;
}

static void make_data(unsigned long root, unsigned level, unsigned pages, unsigned context)
{
    clear_tables(root);
    volatile unsigned long *l2 = (void *) root;
    volatile unsigned long *l1 = (void *) (root + 4096);
    volatile unsigned long *l0 = (void *) (root + 8192);
    l2[0] = pte(root + 4096, 1);
    l1[DVA >> 21] = pte(root + 8192, 1);
    for (unsigned i = 0; i < pages; i++) {
        unsigned long pa = DATA + context * 0x100000ul;
        if (level == 0) {
            pa += i * 4096;
            l0[i] = pte(pa, RW);
        } else if (level == 1) {
            l1[(DVA >> 21) + i] = pte(pa, RW);
        } else {
            l2[i + 1] = pte(0x80000000ul, RW);
        }
        volatile unsigned long *node = (void *) (pa + i * 16);
        node[0] = data_va(level, (i + 1) % pages);
        node[1] = (context + 1) * 256 + i;
    }
}

static uint32_t jal(long offset)
{
    uint32_t v = (uint32_t) offset;
    return ((v >> 20) & 1) << 31 | ((v >> 1) & 1023) << 21 | ((v >> 11) & 1) << 20 |
           ((v >> 12) & 255) << 12 | 0x6f;
}

static void make_code(unsigned pages)
{
    clear_tables(ROOT);
    volatile unsigned long *l2 = (void *) ROOT;
    volatile unsigned long *l1 = (void *) (ROOT + 4096);
    volatile unsigned long *l0 = (void *) (ROOT + 8192);
    l2[0] = pte(ROOT + 4096, 1);
    l1[IVA >> 21] = pte(ROOT + 8192, 1);
    for (unsigned i = 0; i < pages; i++) {
        unsigned long va = IVA + i * 4096 + i * 32;
        unsigned long next = IVA + ((i + 1) % pages) * (4096 + 32);
        volatile uint32_t *code = (void *) (CODE + i * 4096 + i * 32);
        l0[i] = pte(CODE + i * 4096, RX);
        code[0] = 0xfffe0e13; /* addi t3,t3,-1 */
        code[1] = 0x000e0463; /* beq t3,zero,+8 */
        code[2] = jal((long) next - (long) (va + 8));
        code[3] = 0xc0002f73; /* rdcycle t5 */
        code[4] = 0x41df0533; /* sub a0,t5,t4 */
        code[5] = 0x00000073; /* ecall */
    }
    __asm__ volatile("fence rw,rw; fence.i" ::: "memory");
    activate(ROOT);
}

int main(void)
{
    const unsigned counts[] = {1, 4, 16, 20, 32, 64};
    uart_puts("MMUREACH begin\n");
    for (unsigned level = 0; level < 3; level++) {
        for (unsigned c = 0; c < 6; c++) {
            unsigned n = counts[c];
            make_data(ROOT, level, n, 0);
            activate(ROOT);
            if (!validate_chain(data_va(level, 0), (1ul << (12 + 9 * level)) + 16, n, 256)) {
                uart_puts("<<FAIL>> data contents\n");
                return 1;
            }
            unsigned long id = 0x10000 + level * 256 + n;
            unsigned groups = n < 16 ? 32 : n;
            struct result r = data_chain(data_va(level, 0), n * 4, groups, id);
            if (r.signature != data_va(level, 0)) {
                uart_puts("<<FAIL>> data chain\n");
                return 1;
            }
            uart_printf("MMUREACH D level=%u pages=%u loads=%u cycles=%lu\n",
                        level,
                        n,
                        groups * 8,
                        r.cycles);
        }
    }
    for (unsigned c = 0; c < 6; c++) {
        unsigned n = counts[c];
        make_code(n);
        unsigned long warm = instruction_chain(IVA, n * 2, 0x50000 + n);
        unsigned long short_run = instruction_chain(IVA, n * 4, 0x20000 + n);
        unsigned long long_run = instruction_chain(IVA, n * 12, 0x30000 + n);
        if (warm == ~0ul || short_run == ~0ul || long_run == ~0ul) {
            uart_puts("<<FAIL>> instruction trap\n");
            return 1;
        }
        uart_printf("MMUREACH I pages=%u visits=%u short=%lu long=%lu delta=%lu\n",
                    n,
                    n * 8,
                    short_run,
                    long_run,
                    long_run - short_run);
    }
    for (unsigned c = 0; c < 6; c++) {
        unsigned n = counts[c];
        make_data(ROOT, 0, n, 0);
        for (unsigned i = 0; i < n; i++) {
            *(volatile unsigned long *) (DATA + i * 4096) = DVA + ((i + 1) % n) * 4096;
            *(volatile unsigned long *) (DATA + i * 4096 + 8) = 256 + i;
        }
        activate(ROOT);
        if (!validate_chain(DVA, 4096, n, 256)) {
            uart_puts("<<FAIL>> fixed-offset contents\n");
            return 1;
        }
        unsigned groups = n < 16 ? 32 : n;
        struct result r = data_chain(DVA, n * 4, groups, 0x60000 + n);
        if (r.signature != DVA) {
            uart_puts("<<FAIL>> fixed-offset chain\n");
            return 1;
        }
        uart_printf("MMUREACH F pages=%u loads=%u cycles=%lu\n", n, groups * 8, r.cycles);
    }
    for (unsigned c = 0; c < 7; c++) {
        unsigned n = c == 6 ? 0 : counts[c];
        make_data(ROOT, 0, n, 0);
        make_data(ROOT + 0x4000, 0, n, 1);
        for (unsigned context = 0; context < 2 && n; context++) {
            activate(ROOT + context * 0x4000);
            if (!validate_chain(DVA, 4096 + 16, n, (context + 1) * 256)) {
                uart_puts("<<FAIL>> context contents\n");
                return 1;
            }
        }
        activate(ROOT);
        struct result r = context_chain(
            SV39 | (ROOT >> 12), SV39 | ((ROOT + 0x4000) >> 12), DVA, n, 16, 0x40000 + n);
        if (r.signature != (n ? 6144ul : 0ul)) {
            uart_puts("<<FAIL>> context signature\n");
            return 1;
        }
        uart_printf(
            "MMUREACH C pages=%u switches=16 cycles=%lu signature=%lu\n", n, r.cycles, r.signature);
    }
    uart_puts("MMUREACH <<PASS>>\n");
    return 0;
}
