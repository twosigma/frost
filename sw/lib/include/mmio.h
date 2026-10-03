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
 * The addresses are PROVIDE symbols in the linker scripts (common/link.ld and
 * the others under sw/) and must match the decode in cpu_and_mem.sv.
 *
 * Usage:
 *   #include "mmio.h"
 *   UART_TX = 'A';              // Write to UART
 *   uint32_t t = MTIME_LO;      // Read timer
 */

#include <stdint.h>

/* ========================================================================== */
/* Linker-provided symbols                                                    */
/* ========================================================================== */

/* Every anchor is declared volatile, never const. Only its address is used,
 * but GCC treats loads through the casts below as loads of the declared
 * object, so for a const or plain object it may treat the value as invariant
 * between stores and hoist a status poll's load out of its loop. */
extern volatile unsigned long UART_ADDR;
extern volatile unsigned long UART_RX_DATA_ADDR;
extern volatile unsigned long UART_RX_STATUS_ADDR;
extern volatile unsigned long UART_TX_STATUS_ADDR;
extern volatile unsigned long FIFO0_ADDR;
extern volatile unsigned long FIFO1_ADDR;
extern volatile uint32_t MTIME_LO_ADDR;
extern volatile uint32_t MTIME_HI_ADDR;
extern volatile uint32_t MTIMECMP_LO_ADDR;
extern volatile uint32_t MTIMECMP_HI_ADDR;
extern volatile uint32_t MSIP_ADDR;

/* The 32-bit registers declared `unsigned long` are accessed through a
 * narrower lvalue, which is a type pun. -fno-strict-aliasing (common.mk) makes
 * that harmless, but an app may turn strict aliasing back on (coremark does),
 * and GCC could then warn (-Wstrict-aliasing) and assume the two lvalues do
 * not alias. may_alias keeps the accesses correct under either setting.
 * uint8_t needs no such marker: a character type may alias anything.
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
/* Machine timer and software interrupt (0x40000010-0x40000020)               */
/* ========================================================================== */

#define MTIME_LO (*(volatile uint32_t *) &MTIME_LO_ADDR)
#define MTIME_HI (*(volatile uint32_t *) &MTIME_HI_ADDR)
#define MTIMECMP_LO (*(volatile uint32_t *) &MTIMECMP_LO_ADDR)
#define MTIMECMP_HI (*(volatile uint32_t *) &MTIMECMP_HI_ADDR)
#define MSIP (*(volatile uint32_t *) &MSIP_ADDR)

/* ========================================================================== */
/* DMA test engine (0x40020000; register map in dma_engine.h)                 */
/* ========================================================================== */

extern volatile unsigned long DMA_ENGINE_ADDR;
#define DMA_ENGINE_BASE ((uintptr_t) &DMA_ENGINE_ADDR)

/* ========================================================================== */
/* NIC (0x40030000; register map in nic.h)                                    */
/* ========================================================================== */

extern volatile unsigned long NIC_ADDR;
#define NIC_BASE ((uintptr_t) &NIC_ADDR)

#endif /* MMIO_H */
