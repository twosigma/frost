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
 * Memory-mapped I/O addresses for the on-chip peripherals.
 *
 * The addresses come from the linker script (common/link.ld) and have to match
 * the decode in cpu_and_mem.sv.
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
extern const unsigned long UART_TX_STATUS_ADDR;
extern const unsigned long FIFO0_ADDR;
extern const unsigned long FIFO1_ADDR;
extern volatile uint32_t MTIME_LO_ADDR;
extern volatile uint32_t MTIME_HI_ADDR;
extern volatile uint32_t MTIMECMP_LO_ADDR;
extern volatile uint32_t MTIMECMP_HI_ADDR;
extern volatile uint32_t MSIP_ADDR;

/* Only each symbol's ADDRESS matters -- the linker PROVIDEs it as the absolute
 * register address -- so the 32-bit registers above are read back through a
 * narrower lvalue than the `unsigned long` they are declared as. That is a
 * type-punned access: -fno-strict-aliasing (common.mk) makes it harmless, but
 * an app may override that (coremark does), and then GCC would both warn
 * (-Wstrict-aliasing) and be entitled to assume the two lvalues cannot alias.
 * may_alias is GCC's supported opt-out and keeps the punned accesses correct
 * under either setting; it widens nothing when -fno-strict-aliasing is in
 * effect, so every app's codegen is unchanged. uint8_t needs no such marker --
 * a character type may already alias anything.
 */
typedef uint32_t __attribute__((may_alias)) mmio_u32_t;

/* ========================================================================== */
/* UART (0x40000000)                                                          */
/* ========================================================================== */

#define UART_TX (*(volatile uint8_t *) &UART_ADDR)
#define UART_RX_DATA (*(volatile uint8_t *) &UART_RX_DATA_ADDR)
#define UART_RX_STATUS (*(volatile mmio_u32_t *) &UART_RX_STATUS_ADDR)
#define UART_TX_STATUS (*(volatile mmio_u32_t *) &UART_TX_STATUS_ADDR)

/* ========================================================================== */
/* FIFOs (0x40000008, 0x4000000C)                                             */
/* ========================================================================== */

#define FIFO0 (*(volatile mmio_u32_t *) &FIFO0_ADDR)
#define FIFO1 (*(volatile mmio_u32_t *) &FIFO1_ADDR)

/* ========================================================================== */
/* CLINT-compatible Timer Registers (0x40000010-0x40000020)                   */
/* ========================================================================== */

#define MTIME_LO (*(volatile uint32_t *) &MTIME_LO_ADDR)
#define MTIME_HI (*(volatile uint32_t *) &MTIME_HI_ADDR)
#define MTIMECMP_LO (*(volatile uint32_t *) &MTIMECMP_LO_ADDR)
#define MTIMECMP_HI (*(volatile uint32_t *) &MTIMECMP_HI_ADDR)
#define MSIP (*(volatile uint32_t *) &MSIP_ADDR)

#endif /* MMIO_H */
