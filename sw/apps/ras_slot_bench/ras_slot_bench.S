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

# Return prediction for calls and returns in both bundle slots
#
# Four phases each run ITERATIONS call/return pairs, with the call and the
# return placed in slot 1 or slot 2 of their fetch bundle:
#   A  slot-1 call, slot-1 return
#   B  slot-2 call, slot-1 return
#   C  slot-1 call, slot-2 return
#   D  slot-2 call, slot-2 return
# A control phase runs the same loop with a pair of jumps that write no link
# register in place of the call and the return. Every loop and function is
# 8-byte aligned and built from 32-bit instructions, so the 64-bit fetch
# window fixes each instruction's slot: a never-taken `bnez x0` ends its
# bundle, which puts the next instruction in slot 1, and an ALU instruction
# pairs with the call or return after it, which puts that one in slot 2.
#
# Each phase snapshots the profiling counters before and after its loop and
# prints the cycles and the flush-recovery cycles it took (global counter 3,
# TOMASULO_PERF_FLUSH_RECOVERY in sw/lib/include/tomasulo_profile.h). Once the
# predictors are trained, a correctly predicted jump or return causes no
# flush, so <<PASS>> needs every phase to stay under FLUSH_LIMIT flush-recovery
# cycles. The count needs a build with the profiling counters
# (PERF_COUNTERS=1); without them the program prints <<FAIL>>.

    .equ ITERATIONS, 200
    .equ FLUSH_LIMIT, ITERATIONS / 4
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

    .section .init
    .option push
    .option norelax
    .option norvc
    .globl _start

_start:
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)
    lui     s0, 0x40000             # UART
    li      s9, 0                   # Phases over FLUSH_LIMIT

    la      a0, msg_header
    jal     ra, print_string

    csrr    t0, CSR_MPERFCOUNT
    bnez    t0, have_counters
    la      a0, msg_no_counters
    jal     ra, print_string
    li      s9, 1
    j       finish

have_counters:
    # Control: a jump to p0_away and a jump back, neither writing a link
    # register, in the slots phase A uses for its call and return.
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
p0_loop:
    bnez    x0, never
    jal     zero, p0_away
p0_back:
    addi    s1, s1, -1
    bnez    s1, p0_loop
    READ_COUNTERS s8, s5
    la      a0, msg_p0
    jal     ra, report

    # Phase A: slot-1 call, slot-1 return.
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
pa_loop:
    bnez    x0, never
    jal     ra, fa
    addi    s1, s1, -1
    bnez    s1, pa_loop
    READ_COUNTERS s8, s5
    la      a0, msg_pa
    jal     ra, report

    # Phase B: slot-2 call, slot-1 return.
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
pb_loop:
    addi    s2, s2, 1
    jal     ra, fb
    addi    s1, s1, -1
    bnez    s1, pb_loop
    READ_COUNTERS s8, s5
    la      a0, msg_pb
    jal     ra, report

    # Phase C: slot-1 call, slot-2 return.
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
pc_loop:
    bnez    x0, never
    jal     ra, fc
    addi    s1, s1, -1
    bnez    s1, pc_loop
    READ_COUNTERS s8, s5
    la      a0, msg_pc
    jal     ra, report

    # Phase D: slot-2 call, slot-2 return.
    li      s1, ITERATIONS
    READ_COUNTERS s7, s4
    .balign 8
pd_loop:
    addi    s2, s2, 1
    jal     ra, fd
    addi    s1, s1, -1
    bnez    s1, pd_loop
    READ_COUNTERS s8, s5
    la      a0, msg_pd
    jal     ra, report

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

    .balign 8
p0_away:
    bnez    x0, never
    jal     zero, p0_back

    .balign 8
fa:
    bnez    x0, never
    jalr    zero, ra, 0

    .balign 8
fb:
    bnez    x0, never
    jalr    zero, ra, 0

    .balign 8
fc:
    addi    t1, t1, 1
    jalr    zero, ra, 0

    .balign 8
fd:
    addi    t1, t1, 1
    jalr    zero, ra, 0

# report: print a0's label, then the last phase's cycles (s5 - s4) and
# flush-recovery cycles (s8 - s7, modulo 2^32), and count the phase in s9 if
# the flush-recovery cycles reach FLUSH_LIMIT.
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
    li      t0, FLUSH_LIMIT
    bltu    s10, t0, report_newline
    addi    s9, s9, 1
    la      a0, msg_over_limit
    jal     ra, print_string
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
    .string "=== RAS slot bench ===\n"
msg_no_counters:
    .string "Profiling counters absent: build with PERF_COUNTERS=1\n"
msg_p0:
    .string "Control, jumps without link: "
msg_pa:
    .string "A, slot-1 call, slot-1 return: "
msg_pb:
    .string "B, slot-2 call, slot-1 return: "
msg_pc:
    .string "C, slot-1 call, slot-2 return: "
msg_pd:
    .string "D, slot-2 call, slot-2 return: "
msg_cycles:
    .string "cycles="
msg_flushes:
    .string " flush_cycles="
msg_over_limit:
    .string " (over limit)"
msg_newline:
    .string "\n"
msg_pass_marker:
    .string "<<PASS>>\n"
msg_fail_marker:
    .string "<<FAIL>>\n"
