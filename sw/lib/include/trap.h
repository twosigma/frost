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

#ifndef TRAP_H
#define TRAP_H

#include "csr.h"
#include "mmio.h"
#include <stdint.h>

/**
 * Machine-mode trap handling utilities for RISC-V
 *
 * This header provides functions for:
 *   - Interrupt enable/disable
 *   - Trap handler setup
 *   - Privileged instructions (WFI, ECALL, EBREAK)
 *   - Timer interrupt configuration
 *
 * Frost implements Machine (M) and User (U) privilege modes (no S-mode).
 * Traps from both M and U are taken in M-mode: they jump to the address in
 * mtvec, saving the return address in mepc and the cause in mcause.
 *
 * Usage:
 *   // Set up trap handler
 *   set_trap_handler(&my_trap_handler);
 *
 *   // Enable timer interrupt
 *   enable_timer_interrupt();
 *   set_timer_cmp(rdmtime() + 1000000);  // 1M cycles from now
 *
 *   // Enable global interrupts
 *   enable_interrupts();
 *
 *   // Wait for interrupt (low-power idle)
 *   wfi();
 */

/* Timer register macros (MTIME_LO, MTIME_HI, MTIMECMP_LO, MTIMECMP_HI, MSIP)
 * are provided by mmio.h */

/* ========================================================================== */
/* Privileged instructions                                                    */
/* ========================================================================== */

/**
 * WFI - Wait For Interrupt
 *
 * Stalls the processor until an interrupt is pending and enabled.
 * Useful for low-power idle loops in RTOS or bare-metal code.
 *
 * Note: If an interrupt is already pending when WFI executes, the processor
 * will not stall and will immediately continue (or take the interrupt if
 * interrupts are enabled globally).
 */
static inline __attribute__((always_inline)) void wfi(void)
{
    __asm__ volatile("wfi" ::: "memory");
}

/**
 * ECALL - Environment Call
 *
 * Generates a synchronous exception (mcause = 8 from U-mode, 11 from M-mode).
 * Used for system calls in OS environments.
 */
static inline __attribute__((always_inline)) void ecall(void)
{
    __asm__ volatile("ecall" ::: "memory");
}

/**
 * EBREAK - Breakpoint
 *
 * Generates a breakpoint exception (mcause = 3).
 * Used for debugging.
 */
static inline __attribute__((always_inline)) void ebreak(void)
{
    __asm__ volatile("ebreak" ::: "memory");
}

/* ========================================================================== */
/* Interrupt control                                                          */
/* ========================================================================== */

/**
 * Enable global interrupts (set mstatus.MIE)
 */
static inline __attribute__((always_inline)) void enable_interrupts(void)
{
    csr_set(mstatus, MSTATUS_MIE);
}

/**
 * Disable global interrupts (clear mstatus.MIE)
 *
 * Returns the previous mstatus value so it can be restored later.
 */
static inline __attribute__((always_inline)) uint32_t disable_interrupts(void)
{
    uint32_t prev = csr_read(mstatus);
    csr_clear(mstatus, MSTATUS_MIE);
    return prev;
}

/**
 * Restore interrupt state from a previous disable_interrupts() call
 */
static inline __attribute__((always_inline)) void restore_interrupts(uint32_t mstatus_val)
{
    if (mstatus_val & MSTATUS_MIE) {
        csr_set(mstatus, MSTATUS_MIE);
    }
}

/**
 * Enable machine timer interrupt
 */
static inline __attribute__((always_inline)) void enable_timer_interrupt(void)
{
    csr_set(mie, MIE_MTIE);
}

/**
 * Disable machine timer interrupt
 */
static inline __attribute__((always_inline)) void disable_timer_interrupt(void)
{
    csr_clear(mie, MIE_MTIE);
}

/**
 * Enable machine software interrupt
 */
static inline __attribute__((always_inline)) void enable_software_interrupt(void)
{
    csr_set(mie, MIE_MSIE);
}

/**
 * Disable machine software interrupt
 */
static inline __attribute__((always_inline)) void disable_software_interrupt(void)
{
    csr_clear(mie, MIE_MSIE);
}

/**
 * Enable machine external interrupt
 */
static inline __attribute__((always_inline)) void enable_external_interrupt(void)
{
    csr_set(mie, MIE_MEIE);
}

/**
 * Disable machine external interrupt
 */
static inline __attribute__((always_inline)) void disable_external_interrupt(void)
{
    csr_clear(mie, MIE_MEIE);
}

/* ========================================================================== */
/* Trap handler setup                                                         */
/* ========================================================================== */

/**
 * Set the trap handler address
 *
 * The trap handler is called when an exception or interrupt occurs.
 * It must be aligned to 4 bytes (direct mode, which is what Frost uses).
 *
 * @param handler  Function pointer to the trap handler
 *
 * Note: The trap handler should be written in assembly to properly save/restore
 * registers and use MRET to return. C functions can be called from assembly.
 */
static inline void set_trap_handler(void (*handler)(void))
{
    csr_write(mtvec, (uint32_t) handler);
}

/**
 * Get the current trap handler address
 */
static inline uint32_t get_trap_handler(void)
{
    return csr_read(mtvec);
}

/* ========================================================================== */
/* Timer functions (using CLINT-compatible memory-mapped registers)           */
/* ========================================================================== */

/**
 * Read the 64-bit machine timer (mtime)
 *
 * This timer increments every clock cycle and is used for RTOS scheduling.
 * Reading is done atomically by checking for wrap-around.
 */
static inline uint64_t rdmtime(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi = MTIME_HI;
        lo = MTIME_LO;
        hi2 = MTIME_HI;
    } while (hi != hi2);
    return ((uint64_t) hi << 32) | lo;
}

/**
 * Set the timer compare value (mtimecmp)
 *
 * When mtime >= mtimecmp, the timer interrupt (MTIP) is asserted.
 * To acknowledge the interrupt, write a new compare value > mtime.
 *
 * To avoid spurious interrupts, write the high word first (set to max),
 * then the low word, then the real high word.
 */
static inline void set_timer_cmp(uint64_t cmp)
{
    /* Disable timer interrupt during update to avoid spurious interrupt */
    MTIMECMP_HI = 0xFFFFFFFF; /* Set high to max first */
    MTIMECMP_LO = (uint32_t) cmp;
    MTIMECMP_HI = (uint32_t) (cmp >> 32);
}

/**
 * Trigger a software interrupt
 *
 * Sets the MSIP bit, which causes a software interrupt (if enabled).
 * The handler must clear this by writing 0 to MSIP.
 */
static inline void trigger_software_interrupt(void)
{
    MSIP = 1;
}

/**
 * Clear the software interrupt pending bit
 */
static inline void clear_software_interrupt(void)
{
    MSIP = 0;
}

#endif /* TRAP_H */
