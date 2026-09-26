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

# Served-window resteer under the fetch-latency fuzz
#
# if_stage squashes a packet whose fetch window cannot hold pc_reg's bytes and
# resteers fetch to pc_reg's word (window_cannot_serve_pc_reg). With
# fixed-latency fetch no program reaches that. Built with FETCH_VALID_FUZZ=1
# (the served_window_resteer_fetch_fuzz test), this loop reaches it in about
# half its iterations:
#   - The two never-taken `bnez x0` end their bundles, so the loop branch is
#     slot 1 of a bundle of its own and the BTB predicts it from its own
#     lookup, while pc_reg still holds the branch before it.
#   - The loop head is a compressed instruction in the upper half of a word.
#     The first window at that target arrives in the lead-restoring bubble
#     after the redirect and is dropped, so the provider must serve the
#     target's word again.
#   - When a fuzz gap holds that response, fetch moves on to the next word,
#     which cancels it, and the window that arrives is the next word's. It
#     cannot hold pc_reg's packet, so IF resteers.
# The bench (test_real_program) counts the resteers and fails the run if there
# are none. The loop keeps a count and a sum, which a packet decoded from the
# wrong word would corrupt, and prints <<PASS>> only if both are right.

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
