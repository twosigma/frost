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
 *   page_c   six entries (0x000, 0x040, 0x080, 0x0C0, 0x100, 0xE00): auipc ra, 1;
 *            addi ra, ra, off; jalr x0, 0(ra) -- an indirect jump into the
 *            NEXT virtual page at 0x000, 0x008, 0x010, 0x020, 0x040, 0xFF8
 *   page_t   at each of those offsets: a0 = 0xD0 + k; ecall, nop-filled
 *            between them, so a skipped first instruction reports a0 = 0
 *            and a skipped window reports the next pair's marker
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

    .section .text.itlb_page_c, "ax", @progbits
    .balign 4096
    .globl itlb_page_c
itlb_page_c:
    .org 0x000
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0x00008093            /* addi ra, ra, 0x0 -> page_t + 0x000 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x040
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0xFC808093            /* addi ra, ra, -0x38 -> page_t + 0x008 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x080
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0xF9008093            /* addi ra, ra, -0x70 -> page_t + 0x010 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x0C0
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0xF6008093            /* addi ra, ra, -0xa0 -> page_t + 0x020 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x100
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0xF4008093            /* addi ra, ra, -0xc0 -> page_t + 0x040 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0xE00
    .word 0x00001097            /* auipc ra, 1: the next virtual page */
    .word 0x1F808093            /* addi ra, ra, 0x1f8 -> page_t + 0xFF8 */
    .word 0x00008067            /* jalr x0, 0(ra) */
    .org 0x1000 - 4
    .word 0x00000013

    .section .text.itlb_page_t, "ax", @progbits
    .balign 4096
    .globl itlb_page_t
itlb_page_t:
    .word 0x0D000513            /* addi a0, zero, 0xD0 (offset 0x000) */
    .word 0x00000073            /* ecall */
    .fill (0x008 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D100513            /* addi a0, zero, 0xD1 (offset 0x008) */
    .word 0x00000073            /* ecall */
    .fill (0x010 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D200513            /* addi a0, zero, 0xD2 (offset 0x010) */
    .word 0x00000073            /* ecall */
    .fill (0x020 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D300513            /* addi a0, zero, 0xD3 (offset 0x020) */
    .word 0x00000073            /* ecall */
    .fill (0x040 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D400513            /* addi a0, zero, 0xD4 (offset 0x040) */
    .word 0x00000073            /* ecall */
    .fill (0xFF8 - (. - itlb_page_t)) / 4, 4, 0x00000013
    .word 0x0D500513            /* addi a0, zero, 0xD5 (offset 0xFF8) */
    .word 0x00000073            /* ecall */
