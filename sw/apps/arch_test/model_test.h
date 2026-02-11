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

// Frost RISC-V target model_test.h for riscv-arch-test (dev branch)
//
// Defines RVMODEL_* macros required by the riscv-arch-test framework.
// UART output at 0x40000000, MSIP at 0x40000020.
//
// NOTE: On the dev branch, RVMODEL_BOOT is commented out in arch_test.h.
// Startup code (data copy, bss zero) is in crt0_arch_test.S instead.
// The framework's own RVTEST_TRAP_PROLOG handles mtvec setup.

#ifndef _FROST_MODEL_TEST_H
#define _FROST_MODEL_TEST_H

#define XLEN 32
#define FLEN 64

//-----------------------------------------------------------------------
// RVMODEL_BOOT: empty — startup is handled by crt0_arch_test.S
// (The dev branch arch_test.h has RVMODEL_BOOT commented out anyway.)
//-----------------------------------------------------------------------
#define RVMODEL_BOOT

//-----------------------------------------------------------------------
// RVMODEL_HALT: dump signature via UART, then print <<PASS>> and loop.
//
// Iterates from begin_signature to end_signature, printing each 32-bit
// word as 8 lowercase hex characters followed by a newline.
// After the signature, prints "<<PASS>>" so the cocotb test_real_program
// harness terminates the simulation.
//-----------------------------------------------------------------------
#define RVMODEL_HALT                                                                               \
    la a0, begin_signature;                                                                        \
    la a1, end_signature;                                                                          \
    li a2, 0x40000000; /* UART TX address */                                                       \
    _frost_sig_loop:                                                                               \
    bgeu a0, a1, _frost_sig_done;                                                                  \
    lw a3, 0(a0);                                                                                  \
    /* Print 32-bit word as 8 lowercase hex chars (MSB first) */                                   \
    li a4, 28; /* shift amount, starts at 28 for MSB nibble */                                     \
    _frost_hex_loop:                                                                               \
    srl a5, a3, a4;                                                                                \
    andi a5, a5, 0xf;                                                                              \
    li a6, 10;                                                                                     \
    blt a5, a6, _frost_hex_digit;                                                                  \
    addi a5, a5, ('a' - 10);                                                                       \
    j _frost_hex_out;                                                                              \
    _frost_hex_digit:                                                                              \
    addi a5, a5, '0';                                                                              \
    _frost_hex_out:                                                                                \
    sb a5, 0(a2);                                                                                  \
    addi a4, a4, -4;                                                                               \
    bge a4, zero, _frost_hex_loop;                                                                 \
    /* Newline after each word */                                                                  \
    li a5, '\n';                                                                                   \
    sb a5, 0(a2);                                                                                  \
    addi a0, a0, 4;                                                                                \
    j _frost_sig_loop;                                                                             \
    _frost_sig_done:                                                                               \
    /* Print <<PASS>> marker for cocotb test harness */                                            \
    li a5, '<';                                                                                    \
    sb a5, 0(a2);                                                                                  \
    li a5, '<';                                                                                    \
    sb a5, 0(a2);                                                                                  \
    li a5, 'P';                                                                                    \
    sb a5, 0(a2);                                                                                  \
    li a5, 'A';                                                                                    \
    sb a5, 0(a2);                                                                                  \
    li a5, 'S';                                                                                    \
    sb a5, 0(a2);                                                                                  \
    li a5, 'S';                                                                                    \
    sb a5, 0(a2);                                                                                  \
    li a5, '>';                                                                                    \
    sb a5, 0(a2);                                                                                  \
    li a5, '>';                                                                                    \
    sb a5, 0(a2);                                                                                  \
    li a5, '\n';                                                                                   \
    sb a5, 0(a2);                                                                                  \
    _frost_halt_loop:                                                                              \
    j _frost_halt_loop;

//-----------------------------------------------------------------------
// RVMODEL_DATA_BEGIN / RVMODEL_DATA_END: signature area markers
//-----------------------------------------------------------------------
#define RVMODEL_DATA_BEGIN                                                                         \
    .align 2; /* 4-byte alignment (2^2), must match spike reference */                             \
    .global begin_signature;                                                                       \
    begin_signature:

#define RVMODEL_DATA_END                                                                           \
    .align 2; /* 4-byte alignment (2^2), must match spike reference */                             \
    .global end_signature;                                                                         \
    end_signature:

//-----------------------------------------------------------------------
// I/O macros (optional debug hooks — no-ops for Frost)
//-----------------------------------------------------------------------
#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

//-----------------------------------------------------------------------
// Interrupt control macros
// MSIP is memory-mapped at 0x40000020 on Frost.
//-----------------------------------------------------------------------
#define RVMODEL_SET_MSW_INT                                                                        \
    li t0, 0x40000020;                                                                             \
    li t1, 1;                                                                                      \
    sw t1, 0(t0);

#define RVMODEL_CLEAR_MSW_INT                                                                      \
    li t0, 0x40000020;                                                                             \
    sw zero, 0(t0);

#define RVMODEL_CLEAR_MTIMER_INT                                                                   \
    li t0, 0x40000018; /* MTIMECMP_LO */                                                           \
    li t1, -1;                                                                                     \
    sw t1, 0(t0);

#define RVMODEL_CLEAR_MEXT_INT

#endif // _FROST_MODEL_TEST_H
