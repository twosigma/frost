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

/* Sv39 timing of 4 KiB working sets that fit the data TLB after superpage
 * traffic has pushed them out of it: a 32 KiB pointer chase, and a linear
 * scan through a superpage that stores each word it reads to a 4 KiB stack
 * page, as a kernel memory patrol does. */
#include "uart.h"
#include <stdint.h>

#define ROOT 0x82000000ul
#define DATA 0x81000000ul     /* 4 KiB pages: chase array, state, stack */
#define SCAN_PA 0x82200000ul  /* 2 MiB scanned through one superpage */
#define TASK_PA 0x82400000ul  /* 2 MiB holding the task and cursor blocks */
#define SWEEP_PA 0x82600000ul /* 2 MiB that every sweep superpage maps */
#define DVA 0x10000000ul
#define SVA 0x20000000ul
#define SV39 (8ul << 60)
#define RW 0xc7ul
#define ENTRIES 4096u /* 32 KiB of dword indices */
#define ARRAY_PAGES (ENTRIES * 8u / 4096u)
#define STATE_VA (DVA + ARRAY_PAGES * 4096ul)
#define STACK_VA (STATE_VA + 4096ul)
#define SCAN_VA SVA
#define TASK_VA (SVA + 0x200000ul)
#define SWEEP_VA (SVA + 0x400000ul)
#define SWEEP_PAGES 16u
#define SCAN_LINES 1024u

/* The last argument of each loop names its timed window in sscratch. */
extern unsigned long resident_chase(
    unsigned long, unsigned long, unsigned long, unsigned long, unsigned long, unsigned long);
extern unsigned long resident_scan(unsigned long,
                                   unsigned long,
                                   unsigned long,
                                   unsigned long,
                                   unsigned long,
                                   unsigned long,
                                   unsigned long,
                                   unsigned long);

static unsigned long pte(unsigned long pa, unsigned long flags)
{
    return ((pa >> 12) << 10) | flags;
}

static void make_tables(void)
{
    volatile unsigned long *l2 = (void *) ROOT;
    volatile unsigned long *l1 = (void *) (ROOT + 4096);
    volatile unsigned long *l0 = (void *) (ROOT + 8192);
    for (unsigned i = 0; i < 512; i++) {
        l2[i] = 0;
        l1[i] = 0;
        l0[i] = 0;
    }
    l2[0] = pte(ROOT + 4096, 1);
    l1[DVA >> 21] = pte(ROOT + 8192, 1);
    /* The chase array, the state page and the stack page. */
    for (unsigned i = 0; i < ARRAY_PAGES + 2; i++)
        l0[i] = pte(DATA + i * 4096ul, RW);
    l1[SCAN_VA >> 21] = pte(SCAN_PA, RW);
    l1[TASK_VA >> 21] = pte(TASK_PA, RW);
    for (unsigned i = 0; i < SWEEP_PAGES; i++)
        l1[(SWEEP_VA >> 21) + i] = pte(SWEEP_PA, RW);
}

static void activate(void)
{
    unsigned long s = SV39 | (ROOT >> 12);
    __asm__ volatile("fence rw,rw; csrw satp, %0; sfence.vma" : : "r"(s) : "memory");
}

/* One cycle through every index (Sattolo's shuffle with a fixed LCG). */
static void make_chase(void)
{
    volatile unsigned long *a = (void *) DATA;
    unsigned long x = 42;
    for (unsigned i = 0; i < ENTRIES; i++)
        a[i] = i;
    for (unsigned i = ENTRIES - 1; i > 0; i--) {
        x = x * 6364136223846793005ul + 1442695040888963407ul;
        unsigned j = (unsigned) ((x >> 33) % i);
        unsigned long t = a[i];
        a[i] = a[j];
        a[j] = t;
    }
    volatile unsigned long *state = (void *) (DATA + ARRAY_PAGES * 4096ul);
    state[0] = DVA;
    state[3] = 0;
}

int main(void)
{
    uart_puts("MMURESIDENT begin\n");
    make_tables();
    make_chase();
    activate();
    volatile unsigned long *state = (void *) (DATA + ARRAY_PAGES * 4096ul);
    const unsigned sweeps[] = {0, SWEEP_PAGES};
    for (unsigned s = 0; s < 2; s++) {
        unsigned long cycles =
            resident_chase(STATE_VA, ENTRIES, ENTRIES, sweeps[s], SWEEP_VA, 0x100 + sweeps[s]);
        if (state[3] != 0) {
            uart_puts("<<FAIL>> chase index\n");
            return 1;
        }
        uart_printf("MMURESIDENT chase sweep=%u hops=%u cycles=%lu\n", sweeps[s], ENTRIES, cycles);
    }
    volatile unsigned long *task = (void *) TASK_PA;
    volatile unsigned long *cursor = (void *) (TASK_PA + 64);
    for (unsigned s = 0; s < 2; s++) {
        task[0] = 0;
        cursor[0] = 0;
        cursor[1] = 0;
        unsigned long first = SCAN_VA + s * 0x100000ul;
        unsigned long cycles = resident_scan(first,
                                             SCAN_LINES,
                                             STACK_VA,
                                             sweeps[s],
                                             SWEEP_VA,
                                             TASK_VA,
                                             TASK_VA + 64,
                                             0x200 + sweeps[s]);
        if (task[0] != 0 || cursor[0] != first + SCAN_LINES * 64ul || cursor[1] != SCAN_LINES) {
            uart_puts("<<FAIL>> scan counters\n");
            return 1;
        }
        uart_printf(
            "MMURESIDENT scan sweep=%u lines=%u cycles=%lu\n", sweeps[s], SCAN_LINES, cycles);
    }
    uart_puts("MMURESIDENT <<PASS>>\n");
    return 0;
}
