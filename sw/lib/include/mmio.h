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

#ifndef MMIO_H
#define MMIO_H

/**
 * Memory-Mapped I/O Addresses (mmio.h)
 *
 * Centralized definitions for all MMIO peripheral addresses.
 * These addresses are provided by the linker script (common/link.ld) and must
 * match the hardware configuration in cpu_and_mem.sv.
 *
 * Usage:
 *   #include "mmio.h"
 *   UART_TX = 'A';              // Write to UART
 *   uint32_t t = MTIME_LO;      // Read timer
 */

#include <stdint.h>

/* ========================================================================== */
/* Linker-provided symbols (defined in common/link.ld)                        */
/* ========================================================================== */

extern const unsigned long UART_ADDR;
extern const unsigned long UART_RX_DATA_ADDR;
extern const unsigned long UART_RX_STATUS_ADDR;
extern const unsigned long FIFO0_ADDR;
extern const unsigned long FIFO1_ADDR;
extern volatile uint32_t MTIME_LO_ADDR;
extern volatile uint32_t MTIME_HI_ADDR;
extern volatile uint32_t MTIMECMP_LO_ADDR;
extern volatile uint32_t MTIMECMP_HI_ADDR;
extern volatile uint32_t MSIP_ADDR;

/* ========================================================================== */
/* UART (0x40000000)                                                          */
/* ========================================================================== */

#define UART_TX (*(volatile uint8_t *) &UART_ADDR)
#define UART_RX_DATA (*(volatile uint8_t *) &UART_RX_DATA_ADDR)
#define UART_RX_STATUS (*(volatile uint32_t *) &UART_RX_STATUS_ADDR)

/* ========================================================================== */
/* FIFOs (0x40000008, 0x4000000C)                                             */
/* ========================================================================== */

#define FIFO0 (*(volatile uint32_t *) &FIFO0_ADDR)
#define FIFO1 (*(volatile uint32_t *) &FIFO1_ADDR)

/* ========================================================================== */
/* CLINT-compatible Timer Registers (0x40000010-0x40000020)                   */
/* ========================================================================== */

#define MTIME_LO (*(volatile uint32_t *) &MTIME_LO_ADDR)
#define MTIME_HI (*(volatile uint32_t *) &MTIME_HI_ADDR)
#define MTIMECMP_LO (*(volatile uint32_t *) &MTIMECMP_LO_ADDR)
#define MTIMECMP_HI (*(volatile uint32_t *) &MTIMECMP_HI_ADDR)
#define MSIP (*(volatile uint32_t *) &MSIP_ADDR)

#endif /* MMIO_H */
