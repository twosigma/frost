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
 * Code pages for the Sv39 fetch-translation test (Phase 3 M5).
 *
 * Each page is 4 KiB-aligned and position-independent: it holds constants and
 * ecall only, and the page-crossing jump is a raw relative JAL. The driver can
 * therefore map any of them at any virtual page. Every page has a head marker,
 * so a direct entry reports which page ran. Encodings are written as raw words
 * where the halfword placement matters.
 *
 *   page_a   head: a0 = 0xA1; ecall
 *            tail: 0xFF8 addi a1, zero, 0xA4 | 0xFFC c.nop |
 *                  0xFFE low half of "addi a0, zero, 0xA3" (straddles into
 *                  the next page's word 0)
 *   page_b   head: 0x000 high half of that addi | 0x002 ecall
 *   page_a2  head: a0 = 0xA5; ecall
 *            tail: 0xFFC c.nop | 0xFFE c.nop (a compressed pair whose
 *                  successor is the next page's word 0)
 *   page_b2  head: a0 = 0xB1; ecall
 *   page_j   head: jal x0, +4096 (falls into the next virtual page)
 *   page_e   head: a0 = 0xCC; ecall
 */

    /* No linker relaxation: with it, .balign emits maximal NOP padding
     * that the linker later shrinks, which moves the location counter past
     * the .org offsets below. Every instruction here is a fixed encoding. */
    .option norelax

    .section .text.itlb_page_a, "ax", @progbits
    .balign 4096
    .globl itlb_page_a
itlb_page_a:
    .word 0x0A100513            /* addi a0, zero, 0xA1 */
    .word 0x00000073            /* ecall */
    .org 0xFF8
    .word 0x0A400593            /* addi a1, zero, 0xA4 */
    .half 0x0001                /* c.nop */
    .half 0x0513                /* addi a0, zero, 0xA3: low half */

    .section .text.itlb_page_b, "ax", @progbits
    .balign 4096
    .globl itlb_page_b
itlb_page_b:
    .half 0x0A30                /* addi a0, zero, 0xA3: high half */
    .word 0x00000073            /* ecall (at offset 2) */
    .org 0x1000 - 4
    .word 0x00000013            /* keep the page fully populated */

    .section .text.itlb_page_a2, "ax", @progbits
    .balign 4096
    .globl itlb_page_a2
itlb_page_a2:
    .word 0x0A500513            /* addi a0, zero, 0xA5 */
    .word 0x00000073            /* ecall */
    .org 0xFFC
    .half 0x0001                /* c.nop */
    .half 0x0001                /* c.nop */

    .section .text.itlb_page_b2, "ax", @progbits
    .balign 4096
    .globl itlb_page_b2
itlb_page_b2:
    .word 0x0B100513            /* addi a0, zero, 0xB1 */
    .word 0x00000073            /* ecall */
    .org 0x1000 - 4
    .word 0x00000013

    .section .text.itlb_page_j, "ax", @progbits
    .balign 4096
    .globl itlb_page_j
itlb_page_j:
    .word 0x0000106F            /* jal x0, +4096 */
    .org 0x1000 - 4
    .word 0x00000013

    .section .text.itlb_page_e, "ax", @progbits
    .balign 4096
    .globl itlb_page_e
itlb_page_e:
    .word 0x0CC00513            /* addi a0, zero, 0xCC */
    .word 0x00000073            /* ecall */
    .org 0x1000 - 4
    .word 0x00000013
