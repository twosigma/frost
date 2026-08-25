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

// Frost riscv_test.h for the riscv-tests VIRTUAL environment (the -v
// variants): the upstream env/v header with its physical-environment
// include redirected to Frost's own p override (UART pass/fail, no HTIF).
// Every test runs as demand-paged Sv39 user code under a supervisor kernel
// (env_v/vm.c + entry.S): fetch and data translated, page faults delegated
// to S, the A/D bits managed by the kernel's fault handler (Svade).

#ifndef _FROST_ENV_VIRTUAL_SINGLE_CORE_H
#define _FROST_ENV_VIRTUAL_SINGLE_CORE_H

#include "../riscv_test.h"

//-----------------------------------------------------------------------
// Begin Macro
//-----------------------------------------------------------------------

#undef RVTEST_FP_ENABLE
#define RVTEST_FP_ENABLE fssr x0

#undef RVTEST_CODE_BEGIN
#define RVTEST_CODE_BEGIN                                                                          \
    .text;                                                                                         \
    .global extra_boot;                                                                            \
    extra_boot:                                                                                    \
    EXTRA_INIT                                                                                     \
    ret;                                                                                           \
    .global trap_filter;                                                                           \
    trap_filter:                                                                                   \
    FILTER_TRAP                                                                                    \
    li a0, 0;                                                                                      \
    ret;                                                                                           \
    .global pf_filter;                                                                             \
    pf_filter:                                                                                     \
    FILTER_PAGE_FAULT                                                                              \
    li a0, 0;                                                                                      \
    ret;                                                                                           \
    .global userstart;                                                                             \
    userstart:                                                                                     \
    init

//-----------------------------------------------------------------------
// Pass/Fail Macro: a user ecall the kernel turns into the UART marker
//-----------------------------------------------------------------------

#undef RVTEST_PASS
#define RVTEST_PASS li a0, 1; scall

#undef RVTEST_FAIL
#define RVTEST_FAIL sll a0, TESTNUM, 1; 1:beqz a0, 1b; or a0, a0, 1; scall;

//-----------------------------------------------------------------------
// Data Section Macro
//-----------------------------------------------------------------------

#undef RVTEST_DATA_END
#define RVTEST_DATA_END

//-----------------------------------------------------------------------
// Supervisor mode definitions and macros (upstream env/v)
//-----------------------------------------------------------------------

#ifndef LFSR_BITS
#define LFSR_BITS 6
#endif

#define MAX_TEST_PAGES ((1 << LFSR_BITS) - 1)  // this must be the period of the LFSR below
#define LFSR_NEXT(x) (((((x) ^ ((x) >> 1)) & 1) << (LFSR_BITS - 1)) | ((x) >> 1))

#define PGSHIFT 12
#define PGSIZE (1UL << PGSHIFT)

#define SIZEOF_TRAPFRAME_T ((__riscv_xlen / 8) * 36)

#ifndef __ASSEMBLER__

typedef unsigned long pte_t;
#define LEVELS (sizeof(pte_t) == sizeof(uint64_t) ? 3 : 2)
#define PTIDXBITS (PGSHIFT - (sizeof(pte_t) == 8 ? 3 : 2))
#define VPN_BITS (PTIDXBITS * LEVELS)
#define VA_BITS (VPN_BITS + PGSHIFT)
#define PTES_PER_PT (1UL << RISCV_PGLEVEL_BITS)
#define MEGAPAGE_SIZE (PTES_PER_PT * PGSIZE)

typedef struct {
    long gpr[32];
    long sr;
    long epc;
    long badvaddr;
    long cause;
} trapframe_t;
#endif

#endif
