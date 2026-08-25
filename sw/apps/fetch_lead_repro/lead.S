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
 * Line-aligned DDR-resident targets: a {32-bit, RVC} bundle (advance 6)
 * followed by a 32-bit instruction at the upper halfword of the window's
 * second word, i.e. an instruction whose second half lives in the word
 * AFTER the served window. Reached by a call into a cold L1I line (first
 * call) and a warm one (second call). Fixed encodings (no relaxation).
 */
    .option norelax
    .section .ddr_text, "ax", @progbits
    .balign 32
    .globl lead_target_a
lead_target_a:
    .word 0x01100593            /* addi a1, zero, 0x11 */
    .half 0x0001                /* c.nop */
    .word 0x02200513            /* addi a0, zero, 0x22 (at +6: spans words 1 and 2) */
    .half 0x8082                /* c.ret */
    .balign 32
    .globl lead_target_b
lead_target_b:
    .half 0x0001                /* c.nop */
    .word 0x03300593            /* addi a1, zero, 0x33 (at +2: spans words 0 and 1) */
    .word 0x04400513            /* addi a0, zero, 0x44 (at +6: spans words 1 and 2) */
    .half 0x8082                /* c.ret */
