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

/* Full-top software -> 64-bit MMIO -> coherent DMA -> high DDR test. The
 * FROST_WIDE_DDR_TEST sparse model provides raw capacity; this is not a
 * physical DMC/DDR or protected-public-boundary test. */
#include <stdint.h>

#include "dma_engine.h"
#include "uart.h"

#ifndef FROST_DDR_CAPACITY_LOG2_BYTES
#error FROST_DDR_CAPACITY_LOG2_BYTES must match the RTL build
#endif
#if FROST_DDR_CAPACITY_LOG2_BYTES < 30 || FROST_DDR_CAPACITY_LOG2_BYTES > 37
#error DDR aperture must be one of 1..128 GiB
#endif

#define DDR_BASE 0x80000000ul
#define DDR_END (DDR_BASE + (1ul << FROST_DDR_CAPACITY_LOG2_BYTES))
#define SRC_ADDR (DDR_END - 0x3000ul)
#define DST_ADDR (DDR_END - 0x2000ul)
#define STATUS_ADDR (DDR_END - 0x1000ul)
#define LOW_SENTINEL (DDR_BASE + 0x2000ul)
#define WORDS 8u

static uint32_t run(uint64_t src, uint64_t dst, uint32_t len, uint64_t status_addr)
{
    dma_engine_ack();
    dma_engine_setup64(src, dst, len, DMA_ENGINE_MODE_COPY | DMA_ENGINE_MODE_STATUS,
                       0, status_addr, 0x12345678u);
    __asm__ volatile("fence rw,rw" ::: "memory");
    dma_engine_start();
    return dma_engine_wait();
}

int main(void)
{
    volatile uint64_t *src = (volatile uint64_t *) SRC_ADDR;
    volatile uint64_t *dst = (volatile uint64_t *) DST_ADDR;
    volatile uint32_t *status_word = (volatile uint32_t *) STATUS_ADDR;
    volatile uint64_t *sentinel = (volatile uint64_t *) LOW_SENTINEL;
    int failures = 0;

    for (unsigned i = 0; i < WORDS; ++i) {
        src[i] = 0x0123456789abcdefull ^ ((uint64_t) i << 36);
        dst[i] = 0xdeadbeefcafebabeull;
    }
    *status_word = 0;
    *sentinel = 0x554433221100ffeeull;
    __asm__ volatile("fence rw,rw" ::: "memory");

    if (dma_engine_read(DMA_ENGINE_ABI_CTRL) != DMA_ENGINE_ABI_WIDE_SUPPORTED) {
        uart_printf("PA DMA wide ABI unavailable\n");
        failures++;
    }
    dma_engine_select_wide();
    if (dma_engine_read(DMA_ENGINE_ABI_CTRL) !=
        (DMA_ENGINE_ABI_WIDE | DMA_ENGINE_ABI_WIDE_SUPPORTED)) {
        uart_printf("PA DMA wide ABI switch failed\n");
        failures++;
    }

    uint32_t ctrl = run(SRC_ADDR, DST_ADDR, WORDS * 8u, STATUS_ADDR);
    if (!(ctrl & DMA_ENGINE_STATUS_DONE) || (ctrl & DMA_ENGINE_STATUS_ERROR)) {
        uint64_t got_src = *(volatile uint64_t *) (DMA_ENGINE_BASE + DMA_ENGINE_SRC64);
        uint64_t got_dst = *(volatile uint64_t *) (DMA_ENGINE_BASE + DMA_ENGINE_DST64);
        uint64_t got_status =
            *(volatile uint64_t *) (DMA_ENGINE_BASE + DMA_ENGINE_STATUS_ADDR64);
        uart_printf("PA DMA high copy status=%x abi=%x len=%x mode=%x src=%lx dst=%lx status_addr=%lx\n",
                    ctrl, dma_engine_read(DMA_ENGINE_ABI_CTRL),
                    dma_engine_read(DMA_ENGINE_LEN), dma_engine_read(DMA_ENGINE_MODE),
                    got_src, got_dst, got_status);
        failures++;
    }
    __asm__ volatile("fence rw,rw" ::: "memory");
    for (unsigned i = 0; i < WORDS; ++i) {
        if (dst[i] != src[i]) {
            uart_printf("PA DMA high copy word %u failed\n", i);
            failures++;
        }
    }
    if (*status_word != 0x12345678u || *sentinel != 0x554433221100ffeeull) {
        uart_printf("PA DMA high status/sentinel failed\n");
        failures++;
    }

    /* Both invalid addresses must error before a low-width cast. The second
     * one shares the valid sentinel's bits below the physical port width. */
    ctrl = run(SRC_ADDR, DDR_END, 32u, STATUS_ADDR);
    if (!(ctrl & DMA_ENGINE_STATUS_ERROR) || (ctrl & DMA_ENGINE_STATUS_DONE)) {
        uart_printf("PA DMA raw-end rejection failed: %x\n", ctrl);
        failures++;
    }
    unsigned phys_bits = 64u - (unsigned) __builtin_clzl(DDR_END - 1ul);
    uint64_t invalid_alias = (1ul << phys_bits) | LOW_SENTINEL;
    ctrl = run(SRC_ADDR, invalid_alias, 32u, STATUS_ADDR);
    if (!(ctrl & DMA_ENGINE_STATUS_ERROR) || (ctrl & DMA_ENGINE_STATUS_DONE) ||
        *sentinel != 0x554433221100ffeeull) {
        uart_printf("PA DMA high/low alias rejection failed: %x\n", ctrl);
        failures++;
    }

    uart_printf(failures ? "<<FAIL>>\n" : "<<PASS>>\n");
    for (;;) {
    }
}
