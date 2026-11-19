#    Copyright (c) 2026 John Goodacre.
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

# Front-end prediction probe: control flow in the first fetch packet after a
# redirect, a slot-2 conditional branch, an indirect jump through a table,
# and a history-correlated branch. Each phase runs ITERATIONS loop trips and
# reports retired mispredictions (mhpmcounter4) and cycles:
#   F0  indirect call to a function at a halfword address: c.addi; c.ret
#       (the return shares the first packet after the call's redirect)
#   F1  indirect call to a word-aligned function: xori; c.ret
#   F3  as F0 with the function at 2 mod 8 (F0's is at 6 mod 8)
#   F2  direct call to the halfword function
#   J0  direct call to a function whose first instruction is a jump
#   S2  a slot-2 conditional branch that alternates taken and not taken
#   IJ  a switch-style jump through a table with a period-4 index sequence
#   HC  a branch that repeats the outcome of the branch before it
#   HD  as HC with twelve instructions between the two branches
# With BPRED_LIMITS set the phases' misprediction counts are checked against
# the LIMIT_* values below; otherwise the probe only reports.

    .equ ITERATIONS, 256
    .equ CSR_MCOUNTINHIBIT, 0x320
    .equ CSR_MHPMEVENT3, 0x323
    .equ CSR_MHPMEVENT4, 0x324
    .equ CSR_MHPMCOUNTER4, 0xB04
    .equ BPRED_LIMITS, 0
    .equ LIMIT_F0, ITERATIONS
    .equ LIMIT_F1, ITERATIONS
    .equ LIMIT_F2, ITERATIONS
    .equ LIMIT_J0, ITERATIONS
    .equ LIMIT_S2, ITERATIONS
    .equ LIMIT_IJ, ITERATIONS
    .equ LIMIT_HC, ITERATIONS

    # Snapshot mispredictions into \mp and cycles into \cyc.
    .macro READ_COUNTERS mp, cyc
    csrr    \mp, CSR_MHPMCOUNTER4
    rdcycle \cyc
    .endm

    .macro PHASE_REPORT msg, limit
    READ_COUNTERS s8, s5
    la      a0, \msg
    li      a1, \limit
    jal     ra, report
    .endm

    .section .init
    .option push
    .option norelax
    .globl _start

_start:
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)
    lui     s0, 0x40000             # UART
    li      s9, 0                   # Phases over their limit
    li      t0, 3
    csrw    CSR_MHPMEVENT3, t0
    li      t0, 4
    csrw    CSR_MHPMEVENT4, t0
    csrw    CSR_MCOUNTINHIBIT, zero

    la      a0, msg_header
    jal     ra, print_string

    # F0: indirect call to the halfword function.
    la      s3, f0_half
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
f0_loop:
    jalr    ra, s3, 0
    addi    s1, s1, -1
    bnez    s1, f0_loop
    PHASE_REPORT msg_f0, LIMIT_F0

    # F1: indirect call to the word-aligned function.
    la      s3, f1_word
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
f1_loop:
    jalr    ra, s3, 0
    addi    s1, s1, -1
    bnez    s1, f1_loop
    PHASE_REPORT msg_f1, LIMIT_F1

    # F3: indirect call to the halfword function at 2 mod 8.
    la      s3, f3_half
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
f3_loop:
    jalr    ra, s3, 0
    addi    s1, s1, -1
    bnez    s1, f3_loop
    PHASE_REPORT msg_f3, LIMIT_F0

    # F2: direct call to the halfword function.
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
f2_loop:
    jal     ra, f0_half
    addi    s1, s1, -1
    bnez    s1, f2_loop
    PHASE_REPORT msg_f2, LIMIT_F2

    # J0: direct call to a function that starts with a jump.
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
j0_loop:
    jal     ra, j0_entry
    addi    s1, s1, -1
    bnez    s1, j0_loop
    PHASE_REPORT msg_j0, LIMIT_J0

    # S2: a conditional branch in slot 2 (after a 32-bit ALU op in slot 1
    # of an 8-byte-aligned bundle) alternating taken and not taken.
    li      s1, ITERATIONS
    li      s2, 0
    READ_COUNTERS s7, s4
    .balign 8
s2_loop:
    .option push
    .option norvc
    xori    s2, s2, 1
    beqz    s2, s2_skip
    addi    t1, t1, 1
s2_skip:
    addi    s1, s1, -1
    bnez    s1, s2_loop
    .option pop
    PHASE_REPORT msg_s2, LIMIT_S2

    # IJ: a jump through a four-entry table; the index runs 0,1,2,3,...
    li      s1, ITERATIONS
    li      s2, 0
    la      s3, ij_table
    READ_COUNTERS s7, s4
    .balign 8
ij_loop:
    andi    t0, s2, 3
    slli    t0, t0, 3
    add     t0, t0, s3
    ld      t0, 0(t0)
    jr      t0
ij_case0:
    addi    t1, t1, 1
    j       ij_next
ij_case1:
    addi    t1, t1, 2
    j       ij_next
ij_case2:
    addi    t1, t1, 3
    j       ij_next
ij_case3:
    addi    t1, t1, 4
ij_next:
    addi    s2, s2, 1
    addi    s1, s1, -1
    bnez    s1, ij_loop
    PHASE_REPORT msg_ij, LIMIT_IJ

    # HC: branch A follows a pseudo-random bit; branch B repeats A's
    # outcome, so B is predictable only from direction history.
    li      s1, ITERATIONS
    li      s2, 0x2545F491
    READ_COUNTERS s7, s4
    .balign 8
hc_loop:
    slli    t0, s2, 13
    xor     s2, s2, t0
    srli    t0, s2, 7
    xor     s2, s2, t0
    slli    t0, s2, 17
    xor     s2, s2, t0
    andi    t2, s2, 1
    beqz    t2, hc_a
    addi    t1, t1, 1
hc_a:
    addi    t3, t3, 1
    addi    t4, t4, 1
    addi    t5, t5, 1
    beqz    t2, hc_b
    addi    t1, t1, 1
hc_b:
    addi    s1, s1, -1
    bnez    s1, hc_loop
    PHASE_REPORT msg_hc, LIMIT_HC

    # HD: as HC with twelve ALU instructions between the two branches, past
    # the direction history's two-fetch lag.
    li      s1, ITERATIONS
    li      s2, 0x2545F491
    READ_COUNTERS s7, s4
    .balign 8
hd_loop:
    slli    t0, s2, 13
    xor     s2, s2, t0
    srli    t0, s2, 7
    xor     s2, s2, t0
    slli    t0, s2, 17
    xor     s2, s2, t0
    andi    t2, s2, 1
    beqz    t2, hd_a
    addi    t1, t1, 1
hd_a:
    .rept 12
    addi    t3, t3, 1
    .endr
    beqz    t2, hd_b
    addi    t1, t1, 1
hd_b:
    addi    s1, s1, -1
    bnez    s1, hd_loop
    PHASE_REPORT msg_hd, LIMIT_HC

finish:
    la      a0, msg_pass_marker
    beqz    s9, finish_print
    la      a0, msg_fail_marker
finish_print:
    jal     ra, print_string
done:
    j       done

    .balign 8
ij_table:
    .dword  ij_case0, ij_case1, ij_case2, ij_case3

    # c.addi a0, 1 at a halfword address; c.ret at the next word.
    .balign 8
    .option push
    .option norvc
    nop
    .option pop
    c.nop
f0_half:
    c.addi  a0, 1
    c.jr    ra
    .balign 8
    c.nop
f3_half:
    c.addi  a0, 1
    c.jr    ra
    .balign 8
f1_word:
    xori    a0, a0, 3
    c.jr    ra
    .balign 8
    .option push
    .option norvc
    nop
    .option pop
    c.nop
j0_entry:
    c.j     j0_body
    c.nop
    .balign 8
j0_body:
    c.addi  a0, 1
    c.jr    ra

# report: print a0's label, the phase's mispredictions (s8 - s7) and cycles
# (s5 - s4); with BPRED_LIMITS count the phase in s9 when its mispredictions
# exceed a1.
report:
    mv      s6, ra
    mv      s10, a1
    jal     ra, print_string
    la      a0, msg_mp
    jal     ra, print_string
    sub     s11, s8, s7
    mv      a0, s11
    jal     ra, print_decimal
    la      a0, msg_cycles
    jal     ra, print_string
    sub     a0, s5, s4
    jal     ra, print_decimal
    .if BPRED_LIMITS
    bleu    s11, s10, report_newline
    addi    s9, s9, 1
    la      a0, msg_over_limit
    jal     ra, print_string
    .endif
report_newline:
    la      a0, msg_newline
    jal     ra, print_string
    jalr    zero, s6, 0

# print_string: write the NUL-terminated string at a0 to the UART.
print_string:
    mv      t5, a0
print_string_loop:
    lbu     t6, 0(t5)
    beqz    t6, print_string_done
    sb      t6, 0(s0)
    addi    t5, t5, 1
    j       print_string_loop
print_string_done:
    ret

# print_decimal: write a0 as an unsigned decimal number to the UART.
print_decimal:
    li      t5, 10
    li      t6, 0
    addi    sp, sp, -32
    bnez    a0, print_decimal_digits
    li      a1, '0'
    sb      a1, 0(s0)
    j       print_decimal_done
print_decimal_digits:
    beqz    a0, print_decimal_emit
    remu    a1, a0, t5
    divu    a0, a0, t5
    addi    a1, a1, '0'
    add     a2, sp, t6
    sb      a1, 0(a2)
    addi    t6, t6, 1
    j       print_decimal_digits
print_decimal_emit:
    beqz    t6, print_decimal_done
    addi    t6, t6, -1
    add     a2, sp, t6
    lbu     a1, 0(a2)
    sb      a1, 0(s0)
    j       print_decimal_emit
print_decimal_done:
    addi    sp, sp, 32
    ret
    .option pop

    .section .rodata
msg_header:
    .string "=== Branch prediction probe ===\n"
msg_f0:
    .string "F0 indirect call, halfword c.addi;c.ret:"
msg_f3:
    .string "F3 indirect call, halfword at 2 mod 8 c.addi;c.ret:"
msg_f1:
    .string "F1 indirect call, word xori;c.ret:"
msg_f2:
    .string "F2 direct call, halfword c.addi;c.ret:"
msg_j0:
    .string "J0 direct call, first instruction a jump:"
msg_s2:
    .string "S2 slot-2 alternating branch:"
msg_ij:
    .string "IJ jump table, period 4:"
msg_hc:
    .string "HC history-correlated branch:"
msg_hd:
    .string "HD history-correlated branch, 12 apart:"
msg_mp:
    .string " mispredicts="
msg_cycles:
    .string " cycles="
msg_over_limit:
    .string " (over limit)"
msg_newline:
    .string "\n"
msg_pass_marker:
    .string "<<PASS>>\n"
msg_fail_marker:
    .string "<<FAIL>>\n"
