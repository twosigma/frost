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

#ifndef CSR_H
#define CSR_H

#include <stdint.h>

/**
 * Control and Status Register (CSR) access for RISC-V
 *
 * This header provides access to RISC-V CSRs:
 *
 * Zicntr extension (read-only counters):
 *   - cycle/cycleh: Clock cycle counter (64-bit, split into low/high)
 *   - time/timeh: Wall-clock time counter (aliased to cycle on Frost)
 *   - instret/instreth: Instructions retired counter (64-bit, split into low/high)
 *
 * Machine-mode CSRs (for RTOS support):
 *   - mstatus: Global interrupt enable and privilege state
 *   - mie/mip: Interrupt enable and pending bits
 *   - mtvec: Trap vector base address
 *   - mepc: Exception program counter (saved PC on trap)
 *   - mcause: Trap cause (interrupt bit + cause code)
 *   - mtval: Trap value (faulting address or instruction)
 *   - mscratch: Scratch register for trap handlers
 *
 * Usage:
 *   uint64_t start = rdcycle64();
 *   // ... code to benchmark ...
 *   uint64_t elapsed_cycles = rdcycle64() - start;
 *
 *   // Set up trap handler
 *   csr_write(mtvec, (uint32_t)&trap_handler);
 *   csr_set(mstatus, MSTATUS_MIE);  // Enable interrupts
 */

/* ========================================================================== */
/* Zicntr CSR addresses (read-only counters)                                  */
/* ========================================================================== */
#define CSR_CYCLE 0xC00
#define CSR_TIME 0xC01
#define CSR_INSTRET 0xC02
#define CSR_CYCLEH 0xC80
#define CSR_TIMEH 0xC81
#define CSR_INSTRETH 0xC82

/* ========================================================================== */
/* Machine-mode CSR addresses                                                 */
/* ========================================================================== */
#define CSR_MSTATUS 0x300   /* Machine status register */
#define CSR_MISA 0x301      /* ISA and extensions (read-only) */
#define CSR_MIE 0x304       /* Machine interrupt enable */
#define CSR_MTVEC 0x305     /* Machine trap vector base */
#define CSR_MSCRATCH 0x340  /* Machine scratch register */
#define CSR_MEPC 0x341      /* Machine exception program counter */
#define CSR_MCAUSE 0x342    /* Machine trap cause */
#define CSR_MTVAL 0x343     /* Machine trap value */
#define CSR_MIP 0x344       /* Machine interrupt pending (read-only) */
#define CSR_MVENDORID 0xF11 /* Vendor ID (read-only) */
#define CSR_MARCHID 0xF12   /* Architecture ID (read-only) */
#define CSR_MIMPID 0xF13    /* Implementation ID (read-only) */
#define CSR_MHARTID 0xF14   /* Hardware thread ID (read-only) */

/* ========================================================================== */
/* mstatus bit definitions                                                    */
/* ========================================================================== */
#define MSTATUS_MIE (1U << 3)  /* Machine Interrupt Enable */
#define MSTATUS_MPIE (1U << 7) /* Machine Previous Interrupt Enable */
#define MSTATUS_MPP (3U << 11) /* Machine Previous Privilege (2 bits) */

/* ========================================================================== */
/* mie/mip bit definitions (interrupt enable/pending)                         */
/* ========================================================================== */
#define MIP_MSIP (1U << 3)  /* Machine Software Interrupt Pending */
#define MIP_MTIP (1U << 7)  /* Machine Timer Interrupt Pending */
#define MIP_MEIP (1U << 11) /* Machine External Interrupt Pending */

#define MIE_MSIE (1U << 3)  /* Machine Software Interrupt Enable */
#define MIE_MTIE (1U << 7)  /* Machine Timer Interrupt Enable */
#define MIE_MEIE (1U << 11) /* Machine External Interrupt Enable */

/* ========================================================================== */
/* mcause values                                                              */
/* ========================================================================== */
#define MCAUSE_INTERRUPT_BIT (1U << 31) /* Bit 31 set = interrupt, clear = exception */

/* Exception codes (mcause[30:0] when interrupt bit is 0) */
#define EXC_INSN_MISALIGN 0  /* Instruction address misaligned */
#define EXC_INSN_ACCESS 1    /* Instruction access fault */
#define EXC_ILLEGAL_INSN 2   /* Illegal instruction */
#define EXC_BREAKPOINT 3     /* Breakpoint (EBREAK) */
#define EXC_LOAD_MISALIGN 4  /* Load address misaligned */
#define EXC_LOAD_ACCESS 5    /* Load access fault */
#define EXC_STORE_MISALIGN 6 /* Store/AMO address misaligned */
#define EXC_STORE_ACCESS 7   /* Store/AMO access fault */
#define EXC_ECALL_U 8        /* Environment call from U-mode */
#define EXC_ECALL_S 9        /* Environment call from S-mode */
#define EXC_ECALL_M 11       /* Environment call from M-mode */

/* Interrupt codes (mcause[30:0] when interrupt bit is 1) */
#define INT_MSI 3  /* Machine software interrupt */
#define INT_MTI 7  /* Machine timer interrupt */
#define INT_MEI 11 /* Machine external interrupt */

/* ========================================================================== */
/* CSR access macros                                                          */
/* ========================================================================== */

/**
 * Read a CSR by name
 *
 * Uses the CSRRS instruction with rs1=x0, which reads the CSR without
 * modifying it (the CSRR pseudo-instruction).
 */
#define csr_read(csr)                                                                              \
    ({                                                                                             \
        uint32_t __val;                                                                            \
        __asm__ volatile("csrr %0, " #csr : "=r"(__val) : :);                                      \
        __val;                                                                                     \
    })

/**
 * Write a value to a CSR
 *
 * Uses the CSRRW instruction with rd=x0 (the CSRW pseudo-instruction).
 */
#define csr_write(csr, val)                                                                        \
    do {                                                                                           \
        __asm__ volatile("csrw " #csr ", %0" : : "r"(val) :);                                      \
    } while (0)

/**
 * Set bits in a CSR (read-modify-write: CSR |= val)
 *
 * Uses the CSRRS instruction to atomically set bits.
 */
#define csr_set(csr, val)                                                                          \
    do {                                                                                           \
        __asm__ volatile("csrs " #csr ", %0" : : "r"(val) :);                                      \
    } while (0)

/**
 * Clear bits in a CSR (read-modify-write: CSR &= ~val)
 *
 * Uses the CSRRC instruction to atomically clear bits.
 */
#define csr_clear(csr, val)                                                                        \
    do {                                                                                           \
        __asm__ volatile("csrc " #csr ", %0" : : "r"(val) :);                                      \
    } while (0)

/**
 * Swap CSR value (write new value, return old value)
 *
 * Uses the CSRRW instruction.
 */
#define csr_swap(csr, val)                                                                         \
    ({                                                                                             \
        uint32_t __val = (val);                                                                    \
        __asm__ volatile("csrrw %0, " #csr ", %1" : "=r"(__val) : "r"(__val) :);                   \
        __val;                                                                                     \
    })

/**
 * rdcycle - Read low 32 bits of cycle counter
 *
 * Returns the number of clock cycles executed since reset (low 32 bits).
 * Wraps approximately every 14 seconds at 300 MHz.
 */
static inline __attribute__((always_inline)) uint32_t rdcycle(void)
{
    return csr_read(cycle);
}

/**
 * rdcycleh - Read high 32 bits of cycle counter
 *
 * Returns the upper 32 bits of the 64-bit cycle counter.
 * Combined with rdcycle(), provides the full 64-bit count.
 */
static inline __attribute__((always_inline)) uint32_t rdcycleh(void)
{
    return csr_read(cycleh);
}

/**
 * rdcycle64 - Read full 64-bit cycle counter atomically
 *
 * Reads both halves of the cycle counter, handling the case where
 * the low word wraps between reads. This ensures a consistent 64-bit value.
 */
static inline __attribute__((always_inline)) uint64_t rdcycle64(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi = rdcycleh();
        lo = rdcycle();
        hi2 = rdcycleh();
    } while (hi != hi2);
    return ((uint64_t) hi << 32) | lo;
}

/**
 * rdtime - Read low 32 bits of time counter
 *
 * On Frost, time is aliased to cycle (same counter).
 * On systems with a real-time clock, this would be wall-clock time.
 */
static inline __attribute__((always_inline)) uint32_t rdtime(void)
{
    return csr_read(time);
}

/**
 * rdtimeh - Read high 32 bits of time counter
 */
static inline __attribute__((always_inline)) uint32_t rdtimeh(void)
{
    return csr_read(timeh);
}

/**
 * rdtime64 - Read full 64-bit time counter atomically
 */
static inline __attribute__((always_inline)) uint64_t rdtime64(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi = rdtimeh();
        lo = rdtime();
        hi2 = rdtimeh();
    } while (hi != hi2);
    return ((uint64_t) hi << 32) | lo;
}

/**
 * rdinstret - Read low 32 bits of instructions retired counter
 *
 * Returns the number of instructions that have completed execution
 * since reset (low 32 bits).
 */
static inline __attribute__((always_inline)) uint32_t rdinstret(void)
{
    return csr_read(instret);
}

/**
 * rdinstreth - Read high 32 bits of instructions retired counter
 */
static inline __attribute__((always_inline)) uint32_t rdinstreth(void)
{
    return csr_read(instreth);
}

/**
 * rdinstret64 - Read full 64-bit instructions retired counter atomically
 */
static inline __attribute__((always_inline)) uint64_t rdinstret64(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi = rdinstreth();
        lo = rdinstret();
        hi2 = rdinstreth();
    } while (hi != hi2);
    return ((uint64_t) hi << 32) | lo;
}

#endif /* CSR_H */
