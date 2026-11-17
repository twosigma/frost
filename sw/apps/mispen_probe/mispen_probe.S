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

# Branch misprediction penalty probe, one kernel per control-flow class:
#   COND  conditional branch on a register bit (operand ready early)
#   JR    indirect jump that is not a return (jr through a computed target)
#   CALL  indirect call (jalr ra) through a computed target
#   RET   return whose link register the callee moves past the call site
#   BTB   direct jumps that miss both BTBs (eight jumps on one set)
# CONDL, JRL, CALLL and RETL are the same kernels with two multiplies of an
# independent chain before every branch: older work holds the reorder buffer
# head while the branch resolves, so a recovery at commit waits for it.
# COND, JR, CALL and RET run one instruction stream twice: with the outcome
# mask zero (P, predictable) and all ones (R, a xorshift bit per branch, so
# about half the branches mispredict). BTB runs eight jumps on eight distinct
# BTB sets (P) and eight jumps that share one set in both BTBs (R). Each run
# reports retired mispredictions (mhpmcounter4), cycles and instructions; the
# penalty per misprediction is (cycles R - cycles P) / (mispredicts R -
# mispredicts P). A first P run of every kernel trains the predictors and is
# reported as W.

    .equ ITERATIONS, 128
    .equ BTB_ITERATIONS, 64
    .equ CSR_MCOUNTINHIBIT, 0x320
    .equ CSR_MHPMEVENT3, 0x323
    .equ CSR_MHPMEVENT4, 0x324
    .equ CSR_MHPMCOUNTER4, 0xB04
    .equ SEED, 0x2545F4914F6CDD1D

    .option norvc

    # Advance the xorshift state in s3 and put the outcome word in t2.
    .macro NEXT_WORD
    slli    t1, s3, 13
    xor     s3, s3, t1
    srli    t1, s3, 7
    xor     s3, s3, t1
    slli    t1, s3, 17
    xor     s3, s3, t1
    and     t2, s3, s2
    .endm

    # Conditional branch on bit k of t2; both paths run three instructions.
    .macro COND_BIT k
    srli    t0, t2, \k
    andi    t0, t0, 1
    beqz    t0, 9f
    addi    s4, s4, 1
    j       7f
9:
    addi    s4, s4, 2
    nop
7:
    .endm

    # Indirect jump to one of two 16-byte-apart targets, by bit k of t2.
    .macro JR_BIT k
    srli    t0, t2, \k
    andi    t0, t0, 1
    slli    t0, t0, 4
    la      t3, 2f
    add     t0, t0, t3
    jr      t0
    .balign 16
2:
    addi    s4, s4, 1
    j       3f
    .balign 16
    addi    s4, s4, 2
    j       3f
3:
    .endm

    # Indirect call to one of two functions, by bit k of t2.
    .macro CALL_BIT k
    srli    t0, t2, \k
    andi    t0, t0, 1
    slli    t0, t0, 4
    la      t3, call_targets
    add     t0, t0, t3
    jalr    ra, t0, 0
    .endm

    # Call ret_skip, which returns 8 bytes past the call site when bit k of
    # t2 is set (the return stack predicts the call site). Both return paths
    # run two instructions.
    .macro RET_BIT k
    srli    t0, t2, \k
    andi    t0, t0, 1
    slli    t0, t0, 3
    jal     ra, ret_skip
    addi    s4, s4, 1
    j       8f
    addi    s4, s4, 2
    nop
8:
    .endm

    # Two multiplies of a chain carried across bits (a5 = 1): older
    # instructions that hold the reorder buffer head while the branch
    # resolves, as in code with work in flight.
    .macro LOADED_BIT m, k
    mul     a3, a3, a5
    mul     a3, a3, a5
    \m \k
    .endm
    .macro COND_BIT_L k
    LOADED_BIT COND_BIT, \k
    .endm
    .macro JR_BIT_L k
    LOADED_BIT JR_BIT, \k
    .endm
    .macro CALL_BIT_L k
    LOADED_BIT CALL_BIT, \k
    .endm
    .macro RET_BIT_L k
    LOADED_BIT RET_BIT, \k
    .endm

    .macro EIGHT m
    \m 0
    \m 1
    \m 2
    \m 3
    \m 4
    \m 5
    \m 6
    \m 7
    .endm

    # Run kernel \kern with outcome mask \mask and report it under \msg.
    .macro MEASURE msg, mask, kern
    la      a0, \msg
    li      a1, \mask
    la      a2, \kern
    jal     ra, measure
    .endm

    .section .init
    .globl _start

_start:
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)
    lui     s0, 0x40000             # UART
    li      t0, 3
    csrw    CSR_MHPMEVENT3, t0
    li      t0, 4
    csrw    CSR_MHPMEVENT4, t0
    csrw    CSR_MCOUNTINHIBIT, zero

    la      a0, msg_header
    jal     ra, print_string

    MEASURE msg_cond_w, 0, kern_cond
    MEASURE msg_cond_p, 0, kern_cond
    MEASURE msg_cond_r, -1, kern_cond
    MEASURE msg_jr_w, 0, kern_jr
    MEASURE msg_jr_p, 0, kern_jr
    MEASURE msg_jr_r, -1, kern_jr
    MEASURE msg_call_w, 0, kern_call
    MEASURE msg_call_p, 0, kern_call
    MEASURE msg_call_r, -1, kern_call
    MEASURE msg_ret_w, 0, kern_ret
    MEASURE msg_ret_p, 0, kern_ret
    MEASURE msg_ret_r, -1, kern_ret
    MEASURE msg_condl_w, 0, kern_cond_l
    MEASURE msg_condl_p, 0, kern_cond_l
    MEASURE msg_condl_r, -1, kern_cond_l
    MEASURE msg_jrl_w, 0, kern_jr_l
    MEASURE msg_jrl_p, 0, kern_jr_l
    MEASURE msg_jrl_r, -1, kern_jr_l
    MEASURE msg_calll_w, 0, kern_call_l
    MEASURE msg_calll_p, 0, kern_call_l
    MEASURE msg_calll_r, -1, kern_call_l
    MEASURE msg_retl_w, 0, kern_ret_l
    MEASURE msg_retl_p, 0, kern_ret_l
    MEASURE msg_retl_r, -1, kern_ret_l
    MEASURE msg_btb_w, 0, kern_btb_spread
    MEASURE msg_btb_p, 0, kern_btb_spread
    MEASURE msg_btb_r, 0, kern_btb_alias

    la      a0, msg_pass_marker
    jal     ra, print_string
1:
    j       1b

# measure: a0 label, a1 outcome mask, a2 kernel. Seeds the outcome generator,
# runs the kernel between two counter snapshots and prints the differences.
measure:
    mv      s5, ra
    mv      s11, a0
    mv      s2, a1
    li      s3, SEED
    li      s4, 0
    csrr    s7, CSR_MHPMCOUNTER4
    rdcycle s9
    rdinstret s10
    jalr    ra, a2, 0
    csrr    t4, CSR_MHPMCOUNTER4
    rdcycle s8
    rdinstret t6
    sub     s7, t4, s7
    sub     s9, s8, s9
    sub     s10, t6, s10
    mv      a0, s11
    jal     ra, print_string
    la      a0, msg_mp
    jal     ra, print_string
    mv      a0, s7
    jal     ra, print_decimal
    la      a0, msg_cycles
    jal     ra, print_string
    mv      a0, s9
    jal     ra, print_decimal
    la      a0, msg_ins
    jal     ra, print_string
    mv      a0, s10
    jal     ra, print_decimal
    la      a0, msg_newline
    jal     ra, print_string
    jalr    zero, s5, 0

    # Kernel NAME: ITERATIONS outcome words, eight BIT expansions each.
    .macro KERNEL name, bit, saves_ra
    .balign 64
\name:
    .if \saves_ra
    mv      s6, ra
    .endif
    li      s1, ITERATIONS
    li      a3, 3
    li      a5, 1
1:
    NEXT_WORD
    EIGHT   \bit
    addi    s1, s1, -1
    bnez    s1, 1b
    .if \saves_ra
    jalr    zero, s6, 0
    .else
    ret
    .endif
    .endm

    KERNEL kern_cond, COND_BIT, 0
    KERNEL kern_jr, JR_BIT, 0
    KERNEL kern_call, CALL_BIT, 1
    KERNEL kern_ret, RET_BIT, 1
    KERNEL kern_cond_l, COND_BIT_L, 0
    KERNEL kern_jr_l, JR_BIT_L, 0
    KERNEL kern_call_l, CALL_BIT_L, 1
    KERNEL kern_ret_l, RET_BIT_L, 1

    .balign 16
call_targets:
    addi    s4, s4, 1
    ret
    .balign 16
    addi    s4, s4, 2
    ret

    .balign 16
ret_skip:
    add     ra, ra, t0
    ret

    .balign 64
kern_btb_spread:
    li      s1, BTB_ITERATIONS
1:
    j       btb_b0
btb_b_done:
    addi    s1, s1, -1
    bnez    s1, 1b
    ret

    .balign 64
kern_btb_alias:
    li      s1, BTB_ITERATIONS
1:
    j       btb_a0
btb_a_done:
    addi    s1, s1, -1
    bnez    s1, 1b
    ret

# report helpers
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

# BTB kernels: eight 4 KiB pages of NOPs. Jump btb_a<p> sits at page offset
# 0x100 of page p, so all eight index one fast-BTB set (PC[9:2]) and one
# backing-BTB set (PC[10:2]); jump btb_b<p> sits at 0x200 + 0x40 * p, eight
# distinct sets.
    .macro BTB_PAGE p, next_a, next_b
    .balignl 4096, 0x00000013
    .fill   0x100 / 4, 4, 0x00000013
btb_a\p:
    j       \next_a
    .fill   (0x100 + 0x40 * \p - 4) / 4, 4, 0x00000013
btb_b\p:
    j       \next_b
    .endm

    BTB_PAGE 0, btb_a1, btb_b1
    BTB_PAGE 1, btb_a2, btb_b2
    BTB_PAGE 2, btb_a3, btb_b3
    BTB_PAGE 3, btb_a4, btb_b4
    BTB_PAGE 4, btb_a5, btb_b5
    BTB_PAGE 5, btb_a6, btb_b6
    BTB_PAGE 6, btb_a7, btb_b7
    BTB_PAGE 7, btb_a_done, btb_b_done
    .fill   16, 4, 0x00000013

    .section .rodata
msg_header:
    .string "=== Misprediction penalty probe ===\n"
msg_cond_w:
    .string "MISPEN COND W"
msg_cond_p:
    .string "MISPEN COND P"
msg_cond_r:
    .string "MISPEN COND R"
msg_jr_w:
    .string "MISPEN JR W"
msg_jr_p:
    .string "MISPEN JR P"
msg_jr_r:
    .string "MISPEN JR R"
msg_call_w:
    .string "MISPEN CALL W"
msg_call_p:
    .string "MISPEN CALL P"
msg_call_r:
    .string "MISPEN CALL R"
msg_ret_w:
    .string "MISPEN RET W"
msg_ret_p:
    .string "MISPEN RET P"
msg_ret_r:
    .string "MISPEN RET R"
msg_condl_w:
    .string "MISPEN CONDL W"
msg_condl_p:
    .string "MISPEN CONDL P"
msg_condl_r:
    .string "MISPEN CONDL R"
msg_jrl_w:
    .string "MISPEN JRL W"
msg_jrl_p:
    .string "MISPEN JRL P"
msg_jrl_r:
    .string "MISPEN JRL R"
msg_calll_w:
    .string "MISPEN CALLL W"
msg_calll_p:
    .string "MISPEN CALLL P"
msg_calll_r:
    .string "MISPEN CALLL R"
msg_retl_w:
    .string "MISPEN RETL W"
msg_retl_p:
    .string "MISPEN RETL P"
msg_retl_r:
    .string "MISPEN RETL R"
msg_btb_w:
    .string "MISPEN BTB W"
msg_btb_p:
    .string "MISPEN BTB P"
msg_btb_r:
    .string "MISPEN BTB R"
msg_mp:
    .string " mispredicts="
msg_cycles:
    .string " cycles="
msg_ins:
    .string " instret="
msg_newline:
    .string "\n"
msg_pass_marker:
    .string "<<PASS>>\n"
