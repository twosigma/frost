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

/* A timer overlaps coherent DMA replay while committed stores drain. */
#include "cache_evict.h"
#include "csr.h"
#include "dma_engine.h"
#include "trap.h"
#include "uart.h"
#include <stdint.h>

static volatile unsigned long irq_count, irq_error;

__attribute__((interrupt("machine"), aligned(4))) static void irq_entry(void)
{
    if (csr_read(mcause) != ((1ul << 63) | 7ul)) {
        irq_error = 1;
        csr_write(mepc, csr_read(mepc) + 4);
    }
    irq_error |= ((csr_read(mstatus) >> 11) & 3ul) != 3ul;
    irq_error |= csr_read(mepc) == 0;
    set_timer_cmp(~0ull);
    irq_count++;
}

int main(void)
{
    volatile uint64_t *target = (volatile uint64_t *) 0x82202018ul;
    int ok = 1;
    set_trap_handler(irq_entry);
    disable_interrupts();
    csr_write(mie, 0);
    csr_write(mideleg, 0);
    set_timer_cmp(~0ull);
    enable_timer_interrupt();
    for (unsigned long round = 1; round <= 32; round++) {
        uintptr_t source = 0x81000018ul + 64 * round;
        uintptr_t stores = 0x82400000ul + 64 * round;
        *(volatile uint64_t *) source = round;
        for (unsigned int line = 1; line <= CACHE_EVICTING_LINES; line++)
            (void) cache_touch_line(source + line * CACHE_L2_WAY_BYTES);
        *target = 0;
        __asm__ volatile("fence rw, rw" ::: "memory");
        ok &= *target == 0;
        dma_engine_setup(source, (uintptr_t) target, 8, DMA_ENGINE_MODE_COPY, 0, 0, 0);
        irq_count = 0;
        csr_write(mcause, 0);
        csr_write(mepc, 0);
        /* Sweep the timer across the replay and store-drain window. */
        set_timer_cmp(rdmtime() + 32 * round);
        enable_interrupts();
        dma_engine_start();
        unsigned long observed;
        /* The divides hold retirement while six stores occupy the eight-entry
         * store queue. The younger load can execute before DMA invalidates it;
         * its replay waits at the head while the committed stores drain. */
        __asm__ volatile(".option push\n.option norvc\n"
                         "li t0, 0x3333333333333333\n li t1, 3\n div t0, t0, t1\n div t0, t0, t1\n"
                         "mv t2, %2\n li t3, 32768\n"
                         ".rept 6\n sd %3, 0(t2)\n add t2, t2, t3\n.endr\n"
                         ".rept 4\n mul t0, t0, t1\n.endr\n"
                         "ld %0, 0(%1)\n.option pop\n"
                         : "=&r"(observed)
                         : "r"(target), "r"(stores), "r"(round)
                         : "t0", "t1", "t2", "t3", "memory");
        for (unsigned int wait = 0; wait < 2000 && !irq_count; wait++)
            __asm__ volatile("nop");
        disable_interrupts();
        uint32_t status = dma_engine_wait();
        int phase_ok = irq_count == 1 && !irq_error && status == DMA_ENGINE_STATUS_DONE;
        /* A load retired before invalidation may see the old value. */
        phase_ok &= observed == 0 || observed == round;
        phase_ok &= *target == round;
        for (unsigned int line = 0; line < 6; line++)
            phase_ok &= *(volatile uint64_t *) (stores + CACHE_L1D_WAY_BYTES * line) == round;
        if (!phase_ok)
            uart_printf("round=%lu irq=%lu error=%lu status=%u value=%lu\n",
                        round,
                        irq_count,
                        irq_error,
                        status,
                        observed);
        ok &= phase_ok;
        dma_engine_ack();
    }
    disable_timer_interrupt();
    uart_puts(ok ? "<<PASS>>\n" : "<<FAIL>>\n");
    return 0;
}
