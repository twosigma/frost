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
 * their offset within a 32-byte line) or fills [DST, DST+LEN) with
 * PATTERN + i per dword, optionally writes STATUS_VALUE to STATUS_ADDR after
 * every data write has completed, and optionally interrupts (PLIC source 3)
 * after the status write has completed (or after an ABORT has drained, with
 * ERROR set). START snapshots the registers, so they may be reprogrammed
 * while BUSY for the next transfer. Addresses must lie in cached DDR.
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

#define DMA_ENGINE_PLIC_SOURCE 3u

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
