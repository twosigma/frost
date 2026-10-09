#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# Served-window resteer with FETCH_VALID_FUZZ=1
#
# IF must discard a fetch window that cannot serve pc_reg and request the
# correct word again (window_cannot_serve_pc_reg). This loop creates the
# condition by delaying fetch responses:
#   - Two never-taken bnez x0 branches give the loop branch its own bundle
#     and BTB lookup while pc_reg still holds the preceding branch.
#   - The target is a compressed instruction in the upper half of a word.
#     Its first window arrives in the post-redirect lead-restoring bubble
#     and is dropped, requiring the provider to serve that word again.
#   - A fuzz gap delays the response until fetch advances and cancels it.
#     The next word's window cannot serve pc_reg, requiring a resteer.
# The harness requires at least one resteer. Count and sum checks detect
# instructions decoded from the wrong word.

    .equ ITERATIONS, 2000
    .equ UART_TX, 0x40000000

    .section .init
    .option push
    .option norelax
    .globl _start

_start:
    li      s0, UART_TX
    li      a0, 0                   # iterations counted at the loop head
    li      a3, 0                   # sum of a0 over the iterations
    li      a1, ITERATIONS          # remaining iterations
    li      a4, 7
    .option norvc
    j       loop_entry

    # Put the loop head at 6 mod 8, in the upper half of its word.
    .balign 8
    .option rvc
    c.nop
    c.nop
    c.nop
loop:
    c.addi  a0, 1
    .option norvc
    beq     a1, a4, 1f
1:
    add     a3, a3, a0
    addi    a1, a1, -1
    bnez    x0, fail
    bnez    x0, fail
    .option rvc
loop_entry:
    c.bnez  a1, loop
    .option norvc

    li      t0, ITERATIONS
    bne     a0, t0, fail
    li      t0, ITERATIONS * (ITERATIONS + 1) / 2
    bne     a3, t0, fail
    la      a0, msg_pass
    j       print
fail:
    la      a0, msg_fail
print:
    lbu     t1, 0(a0)
    beqz    t1, done
    sb      t1, 0(s0)
    addi    a0, a0, 1
    j       print
done:
    j       done
    .option pop

    .section .rodata
msg_pass:
    .string "<<PASS>>\n"
msg_fail:
    .string "<<FAIL>>\n"
