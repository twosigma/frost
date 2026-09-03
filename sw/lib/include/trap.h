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
 * Machine-mode trap handling for RISC-V: interrupt enable/disable, trap
 * handler setup, the WFI/ECALL/EBREAK instructions, and the CLINT timer.
 *
 * Frost implements Machine (M), Supervisor (S), and User (U) privilege
 * modes. These helpers cover the M-mode side: a trap jumps to the address
 * in mtvec, saving the return address in mepc and the cause in mcause.
 * medeleg/mideleg can delegate S/U traps to S-mode instead.
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
 * Stalls the processor until an interrupt is pending. A masked interrupt
 * wakes it too: mie gates whether the trap is then taken, not the wake-up
 * itself. Useful for low-power idle loops in RTOS or bare-metal code.
 *
 * If an interrupt is already pending when WFI executes, the processor does
 * not stall: it continues immediately, or takes the interrupt if interrupts
 * are enabled globally.
 */
static inline __attribute__((always_inline)) void wfi(void)
{
    __asm__ volatile("wfi" ::: "memory");
}

/**
 * ECALL - Environment Call
 *
 * Generates a synchronous exception (mcause = 8 from U-mode, 9 from S-mode,
 * 11 from M-mode). Used for system calls in OS environments.
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
static inline __attribute__((always_inline)) unsigned long disable_interrupts(void)
{
    unsigned long prev = csr_read(mstatus);
    csr_clear(mstatus, MSTATUS_MIE);
    return prev;
}

/**
 * Restore interrupt state from a previous disable_interrupts() call
 */
static inline __attribute__((always_inline)) void restore_interrupts(unsigned long mstatus_val)
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
 * The trap handler is entered on every exception and interrupt. It must be
 * 4-byte aligned: the low two bits of mtvec are the MODE field, and an
 * aligned address selects direct mode, so every trap enters at the handler.
 *
 * @param handler  Function pointer to the trap handler
 *
 * Write the handler in assembly so it can save and restore all registers and
 * return with MRET. It may call C functions.
 */
static inline void set_trap_handler(void (*handler)(void))
{
    /* uintptr_t: a uint32_t cast would truncate the handler address at RV64 */
    csr_write(mtvec, (uintptr_t) handler);
}

/**
 * Get the current trap handler address
 */
static inline uintptr_t get_trap_handler(void)
{
    return csr_read(mtvec);
}

/* ========================================================================== */
/* Timer functions (using CLINT-compatible memory-mapped registers)           */
/* ========================================================================== */

/**
 * Read the 64-bit machine timer (mtime)
 *
 * mtime increments every clock cycle and is used for RTOS scheduling. The
 * high word is read again after the low word, so a carry between the two
 * 32-bit reads is retried rather than returned as a torn value.
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
 * The timer interrupt (MTIP) is asserted while mtime >= mtimecmp. To
 * acknowledge it, write a new compare value greater than mtime.
 *
 * The 64-bit compare is written as three 32-bit stores: high word to
 * 0xFFFFFFFF, then the low word, then the real high word. The intermediate
 * value stays above mtime, so the update cannot fire a spurious interrupt.
 */
static inline void set_timer_cmp(uint64_t cmp)
{
    MTIMECMP_HI = 0xFFFFFFFF;
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
