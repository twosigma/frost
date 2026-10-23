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
 * Memory error unit register interface (hw/rtl/cpu_and_mem/memory_error_unit.sv).
 *
 * The unit counts the DDR controller's corrected (CE) and uncorrectable (UE)
 * ECC errors, which a board's reader reports (the X3's polls the controller
 * about every millisecond), and the error responses the cache hierarchy's
 * AXI bridge receives from DDR. Its 256-byte window at MEMORY_ERROR_BASE
 * holds 32-bit registers; the 64-bit address registers also read with one
 * 64-bit load. STATUS bits are cleared by writing ones, and the unit's
 * interrupt (APLIC source 5) is STATUS & IRQ_EN. STATUS also flags a new
 * CE_ADDR or UE_ADDR, so software can tell a report with an address from one
 * without.
 *
 * Counts start at reset. CE_ADDR and UE_ADDR hold the physical address of
 * the 64-byte line of the latest report of each kind that had one. On the X3
 * the controller captures one corrected-error address per poll interval and
 * one uncorrectable-error address until its UE status is cleared over JTAG,
 * and a capture that a clear overlapped leaves its error without an address;
 * every uncorrectable read the CPU makes also returns an AXI error, counted
 * in AXI_RD_ERRS. A read that ends in an AXI error still delivers its data.
 * ECC_POLLS stops advancing when the reader stops.
 */
#ifndef MEMORY_ERROR_H
#define MEMORY_ERROR_H

#include <stdint.h>

#include "mmio.h"

#define MEMORY_ERROR_CAPS 0x00u
#define MEMORY_ERROR_STATUS 0x04u
#define MEMORY_ERROR_IRQ_EN 0x08u
#define MEMORY_ERROR_CE_COUNT 0x10u
#define MEMORY_ERROR_UE_COUNT 0x14u
#define MEMORY_ERROR_AXI_RD_ERRS 0x18u
#define MEMORY_ERROR_AXI_WR_ERRS 0x1Cu
#define MEMORY_ERROR_CE_ADDR 0x20u
#define MEMORY_ERROR_UE_ADDR 0x28u
#define MEMORY_ERROR_AXI_ERR 0x30u
#define MEMORY_ERROR_ECC_POLLS 0x38u

/* CAPS */
#define MEMORY_ERROR_CAPS_ECC (1u << 0) /* an ECC reader is active */
#define MEMORY_ERROR_CAPS_VERSION(caps) (((caps) >> 8) & 0xFFu)

/* STATUS and IRQ_EN */
#define MEMORY_ERROR_CE (1u << 0)
#define MEMORY_ERROR_UE (1u << 1)
#define MEMORY_ERROR_AXI_RD (1u << 2)
#define MEMORY_ERROR_AXI_WR (1u << 3)
#define MEMORY_ERROR_CE_ADDR_NEW (1u << 4)
#define MEMORY_ERROR_UE_ADDR_NEW (1u << 5)
#define MEMORY_ERROR_ALL 0x3Fu

/* AXI_ERR: the latest AXI error response */
#define MEMORY_ERROR_AXI_ERR_WRITE(v) ((v) & 1u)
#define MEMORY_ERROR_AXI_ERR_RESP(v) (((v) >> 1) & 3u)
#define MEMORY_ERROR_AXI_ERR_ID(v) (((v) >> 8) & 0xFFu)

#define MEMORY_ERROR_APLIC_SOURCE 5u

static inline uint32_t memory_error_read32(uint32_t offset)
{
    return *(volatile uint32_t *) (MEMORY_ERROR_BASE + offset);
}

static inline uint64_t memory_error_read64(uint32_t offset)
{
    return *(volatile uint64_t *) (MEMORY_ERROR_BASE + offset);
}

static inline void memory_error_write32(uint32_t offset, uint32_t value)
{
    *(volatile uint32_t *) (MEMORY_ERROR_BASE + offset) = value;
}

#endif /* MEMORY_ERROR_H */
