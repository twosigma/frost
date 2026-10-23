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
 * A program whose cache profiling counters a debugger reads
 * (verif/cocotb_tests/debug/test_cache_counters_openocd.py, through
 * fpga/debug/cache_counters.py).
 *
 * Its workload stores twice to each line of a cached-DDR region, so the lines
 * are dirty and recently used in the L1D, reads a larger region once, which
 * the L2 does not hold together with the dirty lines, and then reads each line
 * of a third region twice, which moves the dirty lines out of the L1D. Their
 * writebacks find their L2 lines gone and fetch them (L2 write fills) when the
 * caches are as small as the bench builds them (4 KiB each).
 *
 * The program runs the workload, waits for the last writebacks and prefetches
 * to finish, takes a profiling-counter snapshot, prints the cache counters
 * from it, and says it is ready. When a byte arrives on the UART it runs the
 * workload again on regions of its own, has the DMA test engine fill a fresh
 * region and write a status word, as a NIC's receive path does, waits again,
 * and says it is done, without a snapshot. Every 32-byte DMA write covers half
 * an L2 line, so each fresh line's first write is an L2 write fill. When
 * another byte arrives, the program says it has resumed. Otherwise it sleeps
 * in wfi, as an idle Linux does, waking on the machine timer with interrupts
 * disabled to check the UART, and it runs from low BRAM and touches no cache,
 * so a debugger's snapshots around the second run see only that run's events.
 */

#include <stdint.h>

#include "dma_engine.h"
#include "tomasulo_profile.h"
#include "trap.h"
#include "uart.h"

#define LINE_DWORDS 4u /* 32-byte lines */
#define DIRTY_LINES 32u
#define STREAM_LINES 2048u /* 64 KiB */
#define EVICT_LINES 512u   /* 16 KiB */
#define SETTLE_CYCLES 20000u
#define WAKE_CYCLES 2000u
/* Each run's three regions, the second run's 8 MiB above the first's. */
#define DIRTY_BASE 0x80100000u
#define STREAM_BASE 0x80200000u
#define EVICT_BASE 0x80400000u
#define RUN_STRIDE 0x00800000u
/* The second run's DMA fill and status word, in lines nothing else touches. */
#define DMA_FILL_BASE 0x80D00000u
#define DMA_FILL_BYTES 4096u
#define DMA_STATUS_ADDR 0x80D10000u

static volatile uint64_t sink;

static void run_workload(uint32_t offset)
{
    volatile uint64_t *const dirty = (volatile uint64_t *) (uintptr_t) (DIRTY_BASE + offset);
    volatile uint64_t *const stream = (volatile uint64_t *) (uintptr_t) (STREAM_BASE + offset);
    volatile uint64_t *const evict = (volatile uint64_t *) (uintptr_t) (EVICT_BASE + offset);
    uint64_t sum = 0;
    uint32_t i;

    for (i = 0; i < DIRTY_LINES; i++) {
        dirty[i * LINE_DWORDS] = i;
        dirty[i * LINE_DWORDS + 1u] = i;
    }
    for (i = 0; i < STREAM_LINES; i++) {
        sum += stream[i * LINE_DWORDS];
    }
    for (i = 0; i < EVICT_LINES; i++) {
        sum += evict[i * LINE_DWORDS];
        sum += evict[i * LINE_DWORDS];
    }
    sink = sum;
}

static void settle(void)
{
    for (uint64_t start = rdcycle64(); rdcycle64() - start < SETTLE_CYCLES;) {
    }
}

/* Fill the DMA region and write the status word; returns the engine status. */
static uint32_t dma_fill(void)
{
    dma_engine_setup(0u,
                     DMA_FILL_BASE,
                     DMA_FILL_BYTES,
                     DMA_ENGINE_MODE_FILL | DMA_ENGINE_MODE_STATUS,
                     0x5A5A0000u,
                     DMA_STATUS_ADDR,
                     1u);
    dma_engine_start();
    return dma_engine_wait();
}

/* Sleep until a byte arrives on the UART, and return it. */
static char wait_for_uart(void)
{
    enable_timer_interrupt();
    while (!uart_rx_available()) {
        set_timer_cmp(rdmtime() + WAKE_CYCLES);
        wfi();
    }
    disable_timer_interrupt();
    return uart_getchar();
}

int main(void)
{
    uint32_t count;
    uint32_t status;
    uint32_t i;

    uart_printf("cache_counter_target: start\n");
    run_workload(0u);
    settle();

    csr_write_imm(CSR_MPERFCTL, 1U);
    count = (uint32_t) csr_read_imm(CSR_MPERFCOUNT);
    uart_printf("cache_counter_target: snapshot");
    for (i = TOMASULO_PROFILE_LEGACY_COUNTER_COUNT; i < count; i++) {
        csr_write_imm(CSR_MPERFSEL, i);
        uart_printf(" %u=%llu",
                    (unsigned) i,
                    (unsigned long long) tomasulo_profile_read_selected_counter64());
    }
    uart_printf("\ncache_counter_target: ready\n");

    (void) wait_for_uart();
    run_workload(RUN_STRIDE);
    status = dma_fill();
    settle();
    if (!(status & DMA_ENGINE_STATUS_DONE) || (status & DMA_ENGINE_STATUS_ERROR)) {
        uart_printf("cache_counter_target: DMA status 0x%x\n", (unsigned) status);
    } else {
        uart_printf("cache_counter_target: done\n");
    }
    (void) wait_for_uart();
    uart_printf("cache_counter_target: resumed\n");
    for (;;) {
        wfi();
    }
}
