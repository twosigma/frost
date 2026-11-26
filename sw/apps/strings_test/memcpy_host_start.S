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

/**
 * Host-side harness: runs the exhaustive memcpy/memset checks on the in-tree
 * string.c (symbols renamed to frost_memcpy / frost_memset at link time) under
 * Spike, including a 1,048,113-byte copy that does not fit the simulated
 * memories. Exits with 0 on success. Driven by tests/test_libc_memcpy.py.
 */

/* Bare-metal entry for the Spike-hosted memcpy harness: run main, then report
 * its return value through the HTIF tohost word. */

    .section .text.init, "ax"
    .globl _start
_start:
    la sp, stack_top
    call main
    slli a0, a0, 1
    ori a0, a0, 1
    la t0, tohost
    sd a0, 0(t0)
1:
    j 1b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
    .globl fromhost
fromhost:
    .dword 0

    .section .bss
    .align 4
    .space 4096
stack_top:
