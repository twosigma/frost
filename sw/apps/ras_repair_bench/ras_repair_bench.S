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

# Return address stack repair after a misprediction
#
# Both phases run ITERATIONS iterations that call f_slow and then g_short.
# f_slow's conditional branch waits on a divide and alternates direction, so
# it mispredicts often, and fetch runs down the wrong path past it while the
# divide runs: it predicts f_slow's return, which pops the stack, and goes on
# to what the caller does next.
#   Control: the caller runs FILLER ALU instructions before it calls g_short,
#            so the wrong path pops but does not push.
#   Repair:  the caller calls g_short right away, so the wrong path's push
#            writes g_short's link address over the entry that f_slow's
#            correct-path return needs.
# Recovery restores the stack pointer and count from the branch's checkpoint
# and writes back the entry that was on top when the branch was fetched.
# Without that write-back, f_slow's correct-path return predicts g_short's
# link address and mispredicts. The phases run the same instructions in a
# different order, so <<PASS>> needs the repair phase's flush-recovery cycles
# to stay within FLUSH_MARGIN of the control phase's.
#
# Each call and return follows two never-taken `bnez x0` branches. A branch
# ends its fetch bundle, so the second one always starts a bundle of its own,
# whatever the pairing before it, and the call or return after it gets its
# own slot-1 prediction. The flush-recovery count (global counter 3,
# TOMASULO_PERF_FLUSH_RECOVERY in sw/lib/include/tomasulo_profile.h) needs a
# build with the profiling counters (PERF_COUNTERS=1); without them the
# program prints <<FAIL>>.

    .equ ITERATIONS, 200
    .equ FLUSH_MARGIN, ITERATIONS / 8
    # Fetch runs at most about 45 instructions past the stalled divide (32
    # reorder buffer entries, the decoded bundle queue, and the PD and ID
    # registers). FILLER keeps the control phase's wrong path from reaching
    # its call to g_short, and the repair phase's from reaching the next call
    # to f_slow, which would push the overwritten entry's value back.
    .equ FILLER, 48
    .equ CSR_MPERFSEL, 0x7C0
    .equ CSR_MPERFCTL, 0x7C1
    .equ CSR_MPERFDATA, 0xFC0
    .equ CSR_MPERFCOUNT, 0xFC2
    .equ PERF_FLUSH_RECOVERY, 3

    # Snapshot the counters, then read the low 32 bits of the flush-recovery
    # count into \flushes and the cycle count into \cycles. The macro makes no
    # call, so the measured window contains only the phase's own loop.
    .macro READ_COUNTERS flushes, cycles
    li      t0, 1
    csrw    CSR_MPERFCTL, t0
    li      t0, PERF_FLUSH_RECOVERY
    csrw    CSR_MPERFSEL, t0
    csrr    \flushes, CSR_MPERFDATA
    rdcycle \cycles
    .endm

    # Independent ALU instructions: the two ALUs keep up with dispatch, so
    # the filler never backs up into fetch. A fetch stall drops the lookup
    # in flight, which could cost a call or return its prediction.
    .macro FILL count
    .rept \count
    addi    t3, zero, 1
    .endr
    .endm

    # Two never-taken branches, so the next instruction starts a bundle.
    .macro BUNDLE_BREAK
    bnez    x0, never
    bnez    x0, never
    .endm

    .section .init
    .option push
    .option norelax
    .option norvc
    .globl _start

_start:
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)
    lui     s0, 0x40000             # UART
    li      s9, 0                   # Failed checks

    la      a0, msg_header
    jal     ra, print_string

    csrr    t0, CSR_MPERFCOUNT
    bnez    t0, have_counters
    la      a0, msg_no_counters
    jal     ra, print_string
    li      s9, 1
    j       finish

have_counters:
    li      s3, 1                   # f_slow's divisor

    # Control: the filler separates f_slow's return from the call to g_short.
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
control_loop:
    BUNDLE_BREAK
    jal     ra, f_slow
    FILL    FILLER
    BUNDLE_BREAK
    jal     ra, g_short
    addi    s1, s1, -1
    bnez    s1, control_loop
    READ_COUNTERS s8, s5
    la      a0, msg_control
    jal     ra, report
    mv      s11, s10
    la      a0, msg_newline
    jal     ra, print_string

    # Repair: g_short is called right after f_slow returns.
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
repair_loop:
    BUNDLE_BREAK
    jal     ra, f_slow
    BUNDLE_BREAK
    jal     ra, g_short
    FILL    FILLER
    addi    s1, s1, -1
    bnez    s1, repair_loop
    READ_COUNTERS s8, s5
    la      a0, msg_repair
    jal     ra, report
    addi    t0, s11, FLUSH_MARGIN
    bleu    s10, t0, repair_within_margin
    addi    s9, s9, 1
    la      a0, msg_over_margin
    jal     ra, print_string
repair_within_margin:
    la      a0, msg_newline
    jal     ra, print_string

finish:
    la      a0, msg_pass_marker
    beqz    s9, finish_print
    la      a0, msg_fail_marker
finish_print:
    jal     ra, print_string
done:
    j       done
never:
    j       never

# f_slow: a branch on the loop counter's low bit, through a divide, so it
# resolves late and changes direction every iteration. Both directions reach
# the return within a few instructions, which fetch reaches well before the
# divide finishes.
f_slow:
    andi    t2, s1, 1
    div     t0, t2, s3
    beqz    t0, f_slow_join
    addi    t1, t1, 1
f_slow_join:
    BUNDLE_BREAK
    jalr    zero, ra, 0

g_short:
    BUNDLE_BREAK
    jalr    zero, ra, 0

# report: print a0's label, then the last phase's cycles (s5 - s4) and
# flush-recovery cycles (s8 - s7, modulo 2^32), which it leaves in s10. The
# caller ends the line.
report:
    mv      s6, ra
    jal     ra, print_string
    la      a0, msg_cycles
    jal     ra, print_string
    sub     a0, s5, s4
    jal     ra, print_decimal
    la      a0, msg_flushes
    jal     ra, print_string
    sub     s10, s8, s7
    slli    s10, s10, 32
    srli    s10, s10, 32
    mv      a0, s10
    jal     ra, print_decimal
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
    .string "=== RAS repair bench ===\n"
msg_no_counters:
    .string "Profiling counters absent: build with PERF_COUNTERS=1\n"
msg_control:
    .string "Control, no push on the wrong path: "
msg_repair:
    .string "Repair, wrong path pops then pushes: "
msg_cycles:
    .string "cycles="
msg_flushes:
    .string " flush_cycles="
msg_over_margin:
    .string " (over the control phase's by more than the margin)"
msg_newline:
    .string "\n"
msg_pass_marker:
    .string "<<PASS>>\n"
msg_fail_marker:
    .string "<<FAIL>>\n"
