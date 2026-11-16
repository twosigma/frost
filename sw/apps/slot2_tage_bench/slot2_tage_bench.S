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

# Slot-2 tagged conditional direction overrides in both directions
#
# One 16-byte-aligned loop places an ALU mask in slot 1 (+0x00) and a
# conditional branch `bnez t2, slot2_taken` in slot 2 (+0x04), jumping to
# +0x1c (target[3:2] == 2'b11) when taken while the loop back-edge targets
# +0x00 (target[3:2] == 2'b00). Every step of a 4-iteration period therefore
# produces a distinct path-history word in the tagged predictor:
#
#   Phase A (pattern 0b0111: T, T, T, NT)
#     The fast BTB's 2-bit counter stays in {3, 2} (always predicts taken),
#     so each 4th iteration (64 times in 256 measured iterations) requires a
#     PD not-taken veto from the tagged predictor.
#
#   Phase B (pattern 0b1000: NT, NT, NT, T)
#     The fast BTB's 2-bit counter stays in {0, 1} (always predicts
#     not-taken), so each 4th iteration (64 times in 256 measured iterations)
#     requires a PD taken redirect from the tagged predictor.
#
# Architectural HPM counter 3 (retired branches) and counter 4 (retired
# branch mispredictions) are enabled through mhpmevent3/4 and mcountinhibit
# and checked independently around each 256-iteration measured window after a
# 256-iteration warm-up: retired branches must reach at least 2 * MEASURED
# and retired mispredictions must stay at or below MISPRED_LIMIT.

    .equ WARMUP_ITERS, 256
    .equ MEASURED_ITERS, 256
    .equ MIN_BRANCHES, 2 * MEASURED_ITERS
    .equ MISPRED_LIMIT, 8

    .equ CSR_MCOUNTINHIBIT, 0x320
    .equ CSR_MHPMEVENT3,    0x323
    .equ CSR_MHPMEVENT4,    0x324
    .equ CSR_MHPMCOUNTER3,  0xB03
    .equ CSR_MHPMCOUNTER4,  0xB04

    .section .init
    .option push
    .option norelax
    .option norvc
    .globl _start

_start:
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)
    lui     s0, 0x40000             # UART
    li      s9, 0                   # Failure counter

    la      a0, msg_header
    jal     ra, print_string

    # Enable architectural HPM counters 3 (retired branches) and 4
    # (retired mispredictions).
    li      t0, 3
    csrw    CSR_MHPMEVENT3, t0
    li      t0, 4
    csrw    CSR_MHPMEVENT4, t0
    csrw    CSR_MCOUNTINHIBIT, zero

    # -----------------------------------------------------------------
    # Phase A: (T, T, T, NT) -> PD slot-2 not-taken veto
    # -----------------------------------------------------------------
    li      s7, 0x7                 # Pattern bits [3:0] = 0b0111
    li      t6, 1
    li      s4, 0                   # Total iterations
    li      s5, 0                   # Not-taken iterations
    li      s3, WARMUP_ITERS
    jal     ra, run_slot2_loop

    csrr    s1, CSR_MHPMCOUNTER3
    csrr    s2, CSR_MHPMCOUNTER4
    li      s3, MEASURED_ITERS
    jal     ra, run_slot2_loop
    csrr    s6, CSR_MHPMCOUNTER3
    csrr    s8, CSR_MHPMCOUNTER4

    # Check Phase A architectural counts: 512 total, 128 not-taken.
    li      t0, WARMUP_ITERS + MEASURED_ITERS
    bne     s4, t0, count_mismatch_a
    li      t0, (WARMUP_ITERS + MEASURED_ITERS) / 4
    bne     s5, t0, count_mismatch_a
    j       report_a
count_mismatch_a:
    addi    s9, s9, 1
report_a:
    sub     s6, s6, s1              # Retired branches in measured window
    sub     s8, s8, s2              # Retired mispredictions in measured window
    la      a0, msg_phase_a
    jal     ra, report_phase

    # -----------------------------------------------------------------
    # Phase B: (NT, NT, NT, T) -> PD slot-2 taken redirect
    # -----------------------------------------------------------------
    li      s7, 0x8                 # Pattern bits [3:0] = 0b1000
    li      t6, 1
    li      s4, 0                   # Total iterations
    li      s5, 0                   # Not-taken iterations
    li      s3, WARMUP_ITERS
    jal     ra, run_slot2_loop

    csrr    s1, CSR_MHPMCOUNTER3
    csrr    s2, CSR_MHPMCOUNTER4
    li      s3, MEASURED_ITERS
    jal     ra, run_slot2_loop
    csrr    s6, CSR_MHPMCOUNTER3
    csrr    s8, CSR_MHPMCOUNTER4

    # Check Phase B architectural counts: 512 total, 384 not-taken.
    li      t0, WARMUP_ITERS + MEASURED_ITERS
    bne     s4, t0, count_mismatch_b
    li      t0, 3 * (WARMUP_ITERS + MEASURED_ITERS) / 4
    bne     s5, t0, count_mismatch_b
    j       report_b
count_mismatch_b:
    addi    s9, s9, 1
report_b:
    sub     s6, s6, s1
    sub     s8, s8, s2
    la      a0, msg_phase_b
    jal     ra, report_phase

    # Restore HPM selectors to disabled before finishing.
    csrw    CSR_MHPMEVENT3, zero
    csrw    CSR_MHPMEVENT4, zero

    la      a0, msg_pass_marker
    beqz    s9, finish_print
    la      a0, msg_fail_marker
finish_print:
    jal     ra, print_string
done:
    j       done

    # -----------------------------------------------------------------
    # Aligned loop with slot-2 conditional branch
    # -----------------------------------------------------------------
    .balign 16
run_slot2_loop:
slot2_loop:                         # +0x00: PC[3:2] == 2'b00
    and     t2, t6, s7              # +0x00 (slot 1): select current pattern bit
    bnez    t2, slot2_taken         # +0x04 (slot 2): conditional branch under test
    addi    s5, s5, 1               # +0x08: fall-through counts not-taken steps
    nop                             # +0x0c
    nop                             # +0x10
    nop                             # +0x14
    nop                             # +0x18
slot2_taken:                        # +0x1c: PC[3:2] == 2'b11
    addi    s4, s4, 1               # +0x1c: count every iteration
    srli    t3, t6, 3               # +0x20: rotate 4-bit one-hot mask left
    slli    t6, t6, 1               # +0x24
    or      t6, t6, t3              # +0x28
    andi    t6, t6, 15              # +0x2c
    addi    s3, s3, -1              # +0x30
    nop                             # +0x34
    bnez    s3, slot2_loop          # +0x38: loop back-edge
    ret

# report_phase: print label in a0, s6 (branches) and s8 (mispredicts), and
# increment s9 if branches < MIN_BRANCHES or mispredicts > MISPRED_LIMIT.
report_phase:
    mv      s10, ra
    jal     ra, print_string
    la      a0, msg_branches
    jal     ra, print_string
    mv      a0, s6
    jal     ra, print_decimal
    la      a0, msg_mispredicts
    jal     ra, print_string
    mv      a0, s8
    jal     ra, print_decimal

    li      t0, MIN_BRANCHES
    bltu    s6, t0, phase_bad
    li      t0, MISPRED_LIMIT + 1
    bgeu    s8, t0, phase_bad
    j       phase_newline
phase_bad:
    addi    s9, s9, 1
    la      a0, msg_over_limit
    jal     ra, print_string
phase_newline:
    la      a0, msg_newline
    jal     ra, print_string
    jalr    zero, s10, 0

print_string:
    mv      t4, a0
print_string_loop:
    lbu     t5, 0(t4)
    beqz    t5, print_string_done
    sb      t5, 0(s0)
    addi    t4, t4, 1
    j       print_string_loop
print_string_done:
    ret

print_decimal:
    li      t4, 10
    li      t5, 0
    addi    sp, sp, -32
    bnez    a0, print_decimal_digits
    li      a1, '0'
    sb      a1, 0(s0)
    j       print_decimal_done
print_decimal_digits:
    beqz    a0, print_decimal_emit
    remu    a1, a0, t4
    divu    a0, a0, t4
    addi    a1, a1, '0'
    add     a2, sp, t5
    sb      a1, 0(a2)
    addi    t5, t5, 1
    j       print_decimal_digits
print_decimal_emit:
    beqz    t5, print_decimal_done
    addi    t5, t5, -1
    add     a2, sp, t5
    lbu     a1, 0(a2)
    sb      a1, 0(s0)
    j       print_decimal_emit
print_decimal_done:
    addi    sp, sp, 32
    ret
    .option pop

    .section .rodata
msg_header:
    .string "=== Slot-2 TAGE override bench ===\n"
msg_phase_a:
    .string "A, (T,T,T,NT) slot-2 not-taken veto: "
msg_phase_b:
    .string "B, (NT,NT,NT,T) slot-2 taken redirect: "
msg_branches:
    .string "branches="
msg_mispredicts:
    .string " mispredicts="
msg_over_limit:
    .string " (FAIL)"
msg_newline:
    .string "\n"
msg_pass_marker:
    .string "<<PASS>>\n"
msg_fail_marker:
    .string "<<FAIL>>\n"
