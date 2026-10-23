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

// FROST target model_test.h for riscv-arch-test
//
// Defines the RVMODEL_* macros the riscv-arch-test framework requires.
// UART output at 0x40000000, MSIP at 0x40000020.
//
// The pinned arch_test.h never invokes RVMODEL_BOOT, so the startup code
// (data copy, bss zero) is in the crt0_arch_test*.S files instead. In tests
// that define rvtest_mtrap_routine, the framework's RVTEST_TRAP_PROLOG sets
// up mtvec; the other tests leave it at 0.

#ifndef _FROST_MODEL_TEST_H
#define _FROST_MODEL_TEST_H

// XLEN/FLEN normally come from the build (-DXLEN=64 in the Makefile); the
// defaults only cover standalone inclusion.
#ifndef XLEN
#define XLEN 64
#endif
#ifndef FLEN
#define FLEN 64
#endif

//-----------------------------------------------------------------------
// RVMODEL_BOOT: empty; the crt0_arch_test*.S startup files do the work.
//-----------------------------------------------------------------------
#define RVMODEL_BOOT

//-----------------------------------------------------------------------
// RVMODEL_HALT: leave the signature in low BRAM, print <<PASS>> and loop.
//
// When "<<PASS>>" appears, the bench reads the signature from the data
// copy of low BRAM at frost_bram_signature, which the linker script
// defines. The bram and icache configs keep the signature in low BRAM, so
// there frost_bram_signature is begin_signature itself. The ddr config
// keeps it in DDR, behind the write-back L1D and L2, so this sequence
// copies it to frost_bram_signature with ordinary loads and stores. The
// fence waits until every earlier store has completed: low-BRAM stores
// write through, and the BRAM acknowledges a store only after writing it.
// lui and addi form the low-BRAM address absolutely, which reaches it from
// DDR code; clang-format would split their %hi and %lo operators.
//-----------------------------------------------------------------------
// clang-format off
#define RVMODEL_HALT                                                                               \
    la a0, begin_signature;                                                                        \
    la a1, end_signature;                                                                          \
    lui a2, %hi(frost_bram_signature);                                                             \
    addi a2, a2, %lo(frost_bram_signature);                                                        \
    beq a0, a2, _frost_sig_done;                                                                   \
    _frost_sig_loop:                                                                               \
    bgeu a0, a1, _frost_sig_done;                                                                  \
    ld a3, 0(a0);                                                                                  \
    sd a3, 0(a2);                                                                                  \
    addi a0, a0, 8;                                                                                \
    addi a2, a2, 8;                                                                                \
    j _frost_sig_loop;                                                                             \
    _frost_sig_done:                                                                               \
    fence;                                                                                         \
    /* Print <<PASS>> marker for cocotb test harness */                                            \
    li a2, 0x40000000; /* UART TX address */                                                       \
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
// clang-format on

//-----------------------------------------------------------------------
// RVMODEL_DATA_BEGIN / RVMODEL_DATA_END: signature area markers
//
// Match the Spike env's 16-byte bounds: the signature includes trailing
// alignment padding. generate_references.py rejects mismatched bounds.
//-----------------------------------------------------------------------
#define FROST_SIG_ALIGN 4

#define RVMODEL_DATA_BEGIN                                                                         \
    .align FROST_SIG_ALIGN;                                                                        \
    .global begin_signature;                                                                       \
    begin_signature:

#define RVMODEL_DATA_END                                                                           \
    .align FROST_SIG_ALIGN;                                                                        \
    .global end_signature;                                                                         \
    end_signature:

//-----------------------------------------------------------------------
// I/O macros (optional debug hooks, no-ops for FROST)
//-----------------------------------------------------------------------
#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

//-----------------------------------------------------------------------
// Interrupt control macros
// MSIP is memory-mapped at 0x40000020 on FROST.
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
