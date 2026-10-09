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

/*
 * Pages for the slot-2 fetch-fault test. Each is 4 KiB-aligned and holds no
 * absolute addresses, so main.c can map it at any virtual page.
 *
 *   s2f_code_native  0xFFC: addi a1, zero, 0xA7, a 32-bit instruction in the
 *                    page's last word; its fetch pair partner is word 0 of
 *                    the next virtual page
 *   s2f_code_rvc     0xFFC: c.li a1, 7 | 0xFFE: 0x0013, the low half of a
 *                    32-bit instruction that straddles into the next page
 *   s2f_nops         addi x0, x0, 0 (NOP) words
 *   s2f_zeros        zero words; after the 0x0013 low half above, the
 *                    straddling instruction reads as a NOP
 */

    /* Fixed encodings at fixed offsets: no relaxation. */
    .option norelax

    .section .text.s2f_code_native, "ax", @progbits
    .balign 4096
    .globl s2f_code_native
s2f_code_native:
    .word 0x00000073            /* ecall (not reached) */
    .org 0xFFC
    .word 0x0A700593            /* addi a1, zero, 0xA7 */

    .section .text.s2f_code_rvc, "ax", @progbits
    .balign 4096
    .globl s2f_code_rvc
s2f_code_rvc:
    .word 0x00000073            /* ecall (not reached) */
    .org 0xFFC
    .half 0x459D                /* c.li a1, 7 */
    .half 0x0013                /* low half of a NOP; the high half is next page */

    .section .text.s2f_nops, "ax", @progbits
    .balign 4096
    .globl s2f_nops
s2f_nops:
    .rept 1024
    .word 0x00000013
    .endr

    .section .text.s2f_zeros, "ax", @progbits
    .balign 4096
    .globl s2f_zeros
s2f_zeros:
    .rept 1024
    .word 0x00000000
    .endr
