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
 * uint64_t span_chain(uint64_t x, uint64_t *scratch)
 *
 * After the leading c.nop every instruction is 32-bit and starts at PC[1]=1,
 * so each one spans a word boundary, and every other one also ends in the next
 * 8-byte fetch window. The sequence covers register and immediate ALU forms,
 * lui, mul, a store and load through scratch, a taken and a not-taken branch,
 * a jump, and the return; the result depends on the reloaded value and on
 * every branch and jump outcome. main.c's span_chain_ref is the same
 * computation.
 */
    .option push
    .option norelax
    .section .text.span_chain, "ax", @progbits
    .globl span_chain
    .balign 4
span_chain:
    .option rvc
    c.nop
    .option norvc
    addi    t0, a0, 0x123       /* t0 = x + 0x123 */
    xori    t1, t0, 0x5a5       /* t1 = t0 ^ 0x5a5 */
    slli    t2, t1, 7
    add     t0, t2, a0          /* t0 = (t1 << 7) + x */
    sub     t1, t0, t1          /* t1 = t0 - t1 */
    lui     t2, 0x12345
    xor     t0, t1, t2          /* t0 = t1 ^ 0x12345000 */
    mul     t1, t0, a0          /* t1 = t0 * x */
    sd      t1, 0(a1)
    ld      t2, 0(a1)           /* t2 = t1 */
    bne     t2, t1, 2f          /* not taken */
    addi    t0, t0, 0x7ff       /* t0 = t0 + 0x7ff */
    beq     t2, t1, 1f          /* taken */
    addi    t0, t0, 0x100       /* skipped */
1:
    srli    t1, t2, 3           /* t1 = t2 >> 3 */
    j       3f
2:
    li      t1, 0               /* reached only after a wrong reload */
3:
    add     a0, t0, t1          /* return t0 + t1 */
    ret
    .option pop
