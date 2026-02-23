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

// Frost-specific riscv_test.h for riscv-tests ISA tests
//
// Replaces riscv-tests/env/p/riscv_test.h.
// Uses UART at 0x40000000 for <<PASS>>/<<FAIL>> output instead of tohost.
// Frost is M-mode only, single core.

#ifndef _FROST_RISCV_TEST_H
#define _FROST_RISCV_TEST_H

#include "encoding.h"

//-----------------------------------------------------------------------
// TESTNUM register — same as upstream (gp / x3)
//-----------------------------------------------------------------------
#define TESTNUM gp

//-----------------------------------------------------------------------
// Begin/End macros for RV32/RV64 variants
// These define an `init` assembly macro that RVTEST_CODE_BEGIN invokes.
//-----------------------------------------------------------------------

#define RVTEST_RV32U                                                                               \
    .macro init;                                                                                   \
    .endm

#define RVTEST_RV64U                                                                               \
    .macro init;                                                                                   \
    .endm

#define RVTEST_RV32UF                                                                              \
    .macro init;                                                                                   \
    RVTEST_FP_ENABLE;                                                                              \
    .endm

#define RVTEST_RV64UF                                                                              \
    .macro init;                                                                                   \
    RVTEST_FP_ENABLE;                                                                              \
    .endm

#define RVTEST_RV32M                                                                               \
    .macro init;                                                                                   \
    RVTEST_ENABLE_MACHINE;                                                                         \
    .endm

#define RVTEST_RV64M                                                                               \
    .macro init;                                                                                   \
    RVTEST_ENABLE_MACHINE;                                                                         \
    .endm

//-----------------------------------------------------------------------
// Helper macros
//-----------------------------------------------------------------------

#define RVTEST_ENABLE_MACHINE                                                                      \
    li a0, MSTATUS_MPP;                                                                            \
    csrs mstatus, a0;

#define RVTEST_FP_ENABLE                                                                           \
    li a0, MSTATUS_FS &(MSTATUS_FS >> 1);                                                          \
    csrs mstatus, a0;                                                                              \
    csrwi fcsr, 0

#define INIT_XREG                                                                                  \
    li x1, 0;                                                                                      \
    li x2, 0;                                                                                      \
    li x3, 0;                                                                                      \
    li x4, 0;                                                                                      \
    li x5, 0;                                                                                      \
    li x6, 0;                                                                                      \
    li x7, 0;                                                                                      \
    li x8, 0;                                                                                      \
    li x9, 0;                                                                                      \
    li x10, 0;                                                                                     \
    li x11, 0;                                                                                     \
    li x12, 0;                                                                                     \
    li x13, 0;                                                                                     \
    li x14, 0;                                                                                     \
    li x15, 0;                                                                                     \
    li x16, 0;                                                                                     \
    li x17, 0;                                                                                     \
    li x18, 0;                                                                                     \
    li x19, 0;                                                                                     \
    li x20, 0;                                                                                     \
    li x21, 0;                                                                                     \
    li x22, 0;                                                                                     \
    li x23, 0;                                                                                     \
    li x24, 0;                                                                                     \
    li x25, 0;                                                                                     \
    li x26, 0;                                                                                     \
    li x27, 0;                                                                                     \
    li x28, 0;                                                                                     \
    li x29, 0;                                                                                     \
    li x30, 0;                                                                                     \
    li x31, 0;

#if __riscv_xlen == 64
#define CHECK_XLEN                                                                                 \
    li a0, 1;                                                                                      \
    slli a0, a0, 31;                                                                               \
    bgez a0, 1f;                                                                                   \
    RVTEST_PASS;                                                                                   \
    1:
#else
#define CHECK_XLEN                                                                                 \
    li a0, 1;                                                                                      \
    slli a0, a0, 31;                                                                               \
    bltz a0, 1f;                                                                                   \
    RVTEST_PASS;                                                                                   \
    1:
#endif

#define EXTRA_TVEC_USER
#define EXTRA_TVEC_MACHINE
#define EXTRA_INIT
#define EXTRA_INIT_TIMER
#define FILTER_TRAP
#define FILTER_PAGE_FAULT

#define INTERRUPT_HANDLER j other_exception /* No interrupts should occur */

//-----------------------------------------------------------------------
// RVTEST_CODE_BEGIN
//
// Provides _start, trap vector, and reset vector.
// The trap handler catches ecall (from RVTEST_PASS/FAIL) and routes to
// _frost_uart_pass or _frost_uart_fail based on a0.
// For all other traps, jumps to mtvec_handler if defined, else fails.
//-----------------------------------------------------------------------

#define RVTEST_CODE_BEGIN                                                                          \
    .section .text.init;                                                                           \
    .align 6;                                                                                      \
    .weak stvec_handler;                                                                           \
    .weak mtvec_handler;                                                                           \
    .globl _start;                                                                                 \
    _start:                                                                                        \
    /* reset vector */                                                                             \
    j reset_vector;                                                                                \
    .align 2;                                                                                      \
    trap_vector:                                                                                   \
    /* test whether the trap came from pass/fail ecall */                                          \
    csrr t5, mcause;                                                                               \
    li t6, CAUSE_USER_ECALL;                                                                       \
    beq t5, t6, _frost_ecall_handler;                                                              \
    li t6, CAUSE_SUPERVISOR_ECALL;                                                                 \
    beq t5, t6, _frost_ecall_handler;                                                              \
    li t6, CAUSE_MACHINE_ECALL;                                                                    \
    beq t5, t6, _frost_ecall_handler;                                                              \
    /* if an mtvec_handler is defined, jump to it */                                               \
    la t5, mtvec_handler;                                                                          \
    beqz t5, 1f;                                                                                   \
    jr t5;                                                                                         \
    /* was it an interrupt or an exception? */                                                     \
    1 : csrr t5, mcause;                                                                           \
    bgez t5, handle_exception;                                                                     \
    INTERRUPT_HANDLER;                                                                             \
    handle_exception:                                                                              \
    other_exception:                                                                               \
    /* unhandled exception — mark as fail */                                                       \
    ori TESTNUM, TESTNUM, 1337;                                                                    \
    j _frost_uart_fail;                                                                            \
    _frost_ecall_handler:                                                                          \
    /* ecall from RVTEST_PASS sets a0=0; RVTEST_FAIL sets a0!=0 */                                 \
    beqz a0, _frost_uart_pass;                                                                     \
    j _frost_uart_fail;                                                                            \
                                                                                                   \
    _frost_uart_pass:                                                                              \
    li t0, 0x40000000;                                                                             \
    li t1, '<';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, '<';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, 'P';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, 'A';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, 'S';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, 'S';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, '>';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, '>';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, '\n';                                                                                   \
    sb t1, 0(t0);                                                                                  \
    _frost_pass_halt:                                                                              \
    j _frost_pass_halt;                                                                            \
                                                                                                   \
    _frost_uart_fail:                                                                              \
    li t0, 0x40000000;                                                                             \
    /* Print TESTNUM (gp) as hex BEFORE <<FAIL>> so sim captures */                                \
    li t1, '#';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    mv t2, gp;                                                                                     \
    li t3, 28;                                                                                     \
    _frost_fail_pre_hex:                                                                           \
    srl t4, t2, t3;                                                                                \
    andi t4, t4, 0xf;                                                                              \
    li t5, 10;                                                                                     \
    blt t4, t5, _frost_fail_pre_digit;                                                             \
    addi t4, t4, ('a' - 10);                                                                       \
    j _frost_fail_pre_hexout;                                                                      \
    _frost_fail_pre_digit:                                                                         \
    addi t4, t4, '0';                                                                              \
    _frost_fail_pre_hexout:                                                                        \
    sb t4, 0(t0);                                                                                  \
    addi t3, t3, -4;                                                                               \
    bge t3, zero, _frost_fail_pre_hex;                                                             \
    li t1, ' ';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    /* Now print <<FAIL>> marker */                                                                \
    li t1, '<';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, '<';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, 'F';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, 'A';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, 'I';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, 'L';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, '>';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, '>';                                                                                    \
    sb t1, 0(t0);                                                                                  \
    li t1, '\n';                                                                                   \
    sb t1, 0(t0);                                                                                  \
    _frost_fail_halt:                                                                              \
    j _frost_fail_halt;                                                                            \
                                                                                                   \
    reset_vector:                                                                                  \
    INIT_XREG;                                                                                     \
    /* Copy .data from ROM (LMA) to RAM (VMA) */                                                   \
    la t0, __data_load_start;                                                                      \
    la t1, __data_start;                                                                           \
    la t2, __data_end;                                                                             \
    _frost_copy_data:                                                                              \
    beq t1, t2, _frost_copy_done;                                                                  \
    lw t3, 0(t0);                                                                                  \
    sw t3, 0(t1);                                                                                  \
    addi t0, t0, 4;                                                                                \
    addi t1, t1, 4;                                                                                \
    j _frost_copy_data;                                                                            \
    _frost_copy_done:                                                                              \
    li TESTNUM, 0;                                                                                 \
    la t0, trap_vector;                                                                            \
    csrw mtvec, t0;                                                                                \
    CHECK_XLEN;                                                                                    \
    csrwi mstatus, 0;                                                                              \
    init;                                                                                          \
    EXTRA_INIT;                                                                                    \
    EXTRA_INIT_TIMER;                                                                              \
    la t0, 1f;                                                                                     \
    csrw mepc, t0;                                                                                 \
    csrr a0, mhartid;                                                                              \
    mret;                                                                                          \
    1:

//-----------------------------------------------------------------------
// End Macro
//-----------------------------------------------------------------------

#define RVTEST_CODE_END unimp

//-----------------------------------------------------------------------
// Pass/Fail Macro
//
// Same as upstream: ecall with a0=0 (pass) or a0=TESTNUM (fail).
// Our trap handler above routes ecall to UART output.
//-----------------------------------------------------------------------

#define RVTEST_PASS                                                                                \
    fence;                                                                                         \
    li TESTNUM, 1;                                                                                 \
    li a7, 93;                                                                                     \
    li a0, 0;                                                                                      \
    ecall

#define RVTEST_FAIL                                                                                \
    fence;                                                                                         \
    1 : beqz TESTNUM, 1b;                                                                          \
    sll TESTNUM, TESTNUM, 1;                                                                       \
    or TESTNUM, TESTNUM, 1;                                                                        \
    li a7, 93;                                                                                     \
    addi a0, TESTNUM, 0;                                                                           \
    ecall

//-----------------------------------------------------------------------
// Data Section Macro
//-----------------------------------------------------------------------

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN                                                                          \
    EXTRA_DATA                                                                                     \
    .align 4;                                                                                      \
    .global begin_signature;                                                                       \
    begin_signature:

#define RVTEST_DATA_END                                                                            \
    .align 4;                                                                                      \
    .global end_signature;                                                                         \
    end_signature:

#endif // _FROST_RISCV_TEST_H
