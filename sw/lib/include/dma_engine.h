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

/**
 * DMA test engine register interface (hw/rtl/cpu_and_mem/dma_test_engine.sv).
 *
 * The engine is a DMA master on the cache hierarchy's coherent DMA port,
 * driven from a 256-byte window of 32-bit registers at DMA_ENGINE_BASE. A
 * transfer moves [SRC, SRC+LEN) to [DST, DST+LEN) (SRC and DST must share
 * their offset within a 32-byte line) or fills [DST, DST+LEN), writing
 * PATTERN + i to its i-th 32-bit word (the word holding DST is word 0). It
 * optionally writes STATUS_VALUE to STATUS_ADDR after every data write has
 * completed, and optionally interrupts (APLIC source 3) once the transfer and
 * any status write have completed (or after an ABORT has drained, with ERROR
 * set). START snapshots the registers, so they may be reprogrammed while BUSY
 * for the next transfer. Addresses must lie in cached DDR.
 */
#ifndef DMA_ENGINE_H
#define DMA_ENGINE_H

#include <stdint.h>

#include "mmio.h"

#define DMA_ENGINE_CTRL 0x00u
#define DMA_ENGINE_ACK 0x04u
#define DMA_ENGINE_SRC 0x08u
#define DMA_ENGINE_DST 0x0Cu
#define DMA_ENGINE_LEN 0x10u
#define DMA_ENGINE_MODE 0x14u
#define DMA_ENGINE_PATTERN 0x18u
#define DMA_ENGINE_STATUS_ADDR 0x1Cu
#define DMA_ENGINE_STATUS_VALUE 0x20u
#define DMA_ENGINE_LINES 0x24u
#define DMA_ENGINE_ABI_CTRL 0x28u
#define DMA_ENGINE_SRC64 0x40u
#define DMA_ENGINE_DST64 0x48u
#define DMA_ENGINE_STATUS_ADDR64 0x50u
#define DMA_ENGINE_ABI_WIDE (1u << 0)
#define DMA_ENGINE_ABI_WIDE_SUPPORTED (1u << 1)

#define DMA_ENGINE_CTRL_START (1u << 0)
#define DMA_ENGINE_CTRL_ABORT (1u << 2)
#define DMA_ENGINE_STATUS_BUSY (1u << 0)
#define DMA_ENGINE_STATUS_DONE (1u << 1)
#define DMA_ENGINE_STATUS_ERROR (1u << 2)
#define DMA_ENGINE_STATUS_IRQ (1u << 3)

#define DMA_ENGINE_MODE_COPY 0u
#define DMA_ENGINE_MODE_FILL (1u << 0)
#define DMA_ENGINE_MODE_STATUS (1u << 1)
#define DMA_ENGINE_MODE_IRQ (1u << 2)

#define DMA_ENGINE_APLIC_SOURCE 3u

static inline volatile mmio_u32_t *dma_engine_reg(uint32_t offset)
{
    return (volatile mmio_u32_t *) (DMA_ENGINE_BASE + offset);
}

static inline void dma_engine_write(uint32_t offset, uint32_t value)
{
    *dma_engine_reg(offset) = value;
}

static inline uint32_t dma_engine_read(uint32_t offset)
{
    return *dma_engine_reg(offset);
}

/** The extended bank requires one aligned RV64 store, never two word stores. */
static inline void dma_engine_write64(uint32_t offset, uint64_t value)
{
    *(volatile uint64_t *) (DMA_ENGINE_BASE + offset) = value;
}

/** Select only while idle; the hardware clears all address registers. */
static inline void dma_engine_select_wide(void)
{
    dma_engine_write(DMA_ENGINE_ABI_CTRL, DMA_ENGINE_ABI_WIDE);
}

static inline void dma_engine_setup64(uint64_t src,
                                      uint64_t dst,
                                      uint32_t len,
                                      uint32_t mode,
                                      uint32_t pattern,
                                      uint64_t status_addr,
                                      uint32_t status_value)
{
    dma_engine_write64(DMA_ENGINE_SRC64, src);
    dma_engine_write64(DMA_ENGINE_DST64, dst);
    dma_engine_write(DMA_ENGINE_LEN, len);
    dma_engine_write(DMA_ENGINE_MODE, mode);
    dma_engine_write(DMA_ENGINE_PATTERN, pattern);
    dma_engine_write64(DMA_ENGINE_STATUS_ADDR64, status_addr);
    dma_engine_write(DMA_ENGINE_STATUS_VALUE, status_value);
}

/** Program a transfer without starting it. */
static inline void dma_engine_setup(uint32_t src,
                                    uint32_t dst,
                                    uint32_t len,
                                    uint32_t mode,
                                    uint32_t pattern,
                                    uint32_t status_addr,
                                    uint32_t status_value)
{
    dma_engine_write(DMA_ENGINE_SRC, src);
    dma_engine_write(DMA_ENGINE_DST, dst);
    dma_engine_write(DMA_ENGINE_LEN, len);
    dma_engine_write(DMA_ENGINE_MODE, mode);
    dma_engine_write(DMA_ENGINE_PATTERN, pattern);
    dma_engine_write(DMA_ENGINE_STATUS_ADDR, status_addr);
    dma_engine_write(DMA_ENGINE_STATUS_VALUE, status_value);
}

static inline void dma_engine_start(void)
{
    dma_engine_write(DMA_ENGINE_CTRL, DMA_ENGINE_CTRL_START);
}

static inline uint32_t dma_engine_status(void)
{
    return dma_engine_read(DMA_ENGINE_CTRL);
}

/** Spin until the engine is idle; returns the final status word. */
static inline uint32_t dma_engine_wait(void)
{
    uint32_t status;
    do {
        status = dma_engine_status();
    } while (status & DMA_ENGINE_STATUS_BUSY);
    return status;
}

static inline void dma_engine_ack(void)
{
    dma_engine_write(DMA_ENGINE_ACK, 1u);
}

#endif /* DMA_ENGINE_H */
