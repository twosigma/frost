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

# BTB Benchmark: Measure performance impact of BTB set-associativity and capacity
#
# In a direct-mapped BTB (256 entries, indexed by PC[9:2]), two branch instructions
# whose PCs map to the same set index ping-pong and evict each other continuously.
# Each eviction causes a BTB miss on the next execution, forcing the processor
# to incur frontend resteer and pipeline flush recovery penalties.
#
# In a 2-way set-associative BTB (512 sets x 2 ways = 1024 entries), two aliasing
# branches co-exist in Way 0 and Way 1 of their set, completely eliminating ping-pong
# evictions and pipeline flush recovery cycles.
#
# This benchmark measures:
#   Test 1 (Control): Two non-aliasing branches with independent set indices.
#   Test 2 (Conditional Branch Alias, 0x800): Two branches mapping to the same
#          set index (differing by 2048B = 0x800). Their targets are outside the
#          fetch bundle.
#   Test 3 (Capacity Index Spread, 0x400): Two branches differing by 1024B.
#          They collide in 256-set direct-mapped, but separate into distinct sets
#          in 512-set BTB.

    .equ ITERATIONS, 200
    .equ CSR_MPERFSEL, 0x7C0
    .equ CSR_MPERFCTL, 0x7C1
    .equ CSR_MPERFDATA, 0xFC0
    .equ CSR_MPERFCOUNT, 0xFC2
    .equ PERF_FLUSH_RECOVERY, 3

    # Snapshot flush-recovery cycles into \flushes and cycle count into \cycles.
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
    lui     s0, 0x40000             # UART base

    la      a0, msg_header
    jal     ra, print_string

    csrr    t0, CSR_MPERFCOUNT
    bnez    t0, have_counters
    la      a0, msg_no_counters
    jal     ra, print_string
    j       finish

have_counters:
    # =========================================================================
    # Test 1: Control - Independent non-aliasing conditional branches
    # =========================================================================
    li      s1, ITERATIONS
    li      a0, 1
    READ_COUNTERS s7, s4
test1_loop:
    jal     ra, test1_fn_a
    jal     ra, test1_fn_b
    addi    s1, s1, -1
    bnez    s1, test1_loop
    READ_COUNTERS s8, s5
    la      a0, msg_t1
    jal     ra, report

    # =========================================================================
    # Test 2: Conditional Branch Aliasing (differ by 0x800 = 2048B)
    # Direct-mapped BTB collides on index 4; 2-way BTB caches both in Way 0 & 1.
    # =========================================================================
    li      s1, ITERATIONS
    li      a0, 1
    READ_COUNTERS s7, s4
test2_loop:
    jal     ra, cond_alias_fn_0
    jal     ra, cond_alias_fn_1
    addi    s1, s1, -1
    bnez    s1, test2_loop
    READ_COUNTERS s8, s5
    la      a0, msg_t2
    jal     ra, report

    # =========================================================================
    # Test 3: Capacity Index Doubling (differ by 0x400 = 1024B)
    # Collides in 256-set BTB; separates in 512-set BTB.
    # =========================================================================
    li      s1, ITERATIONS
    li      a0, 1
    READ_COUNTERS s7, s4
test3_loop:
    jal     ra, cond_alias_fn_0
    jal     ra, cond_half_alias_fn
    addi    s1, s1, -1
    bnez    s1, test3_loop
    READ_COUNTERS s8, s5
    la      a0, msg_t3
    jal     ra, report

finish:
    la      a0, msg_pass_marker
    jal     ra, print_string

hang:
    wfi
    j       hang

# report: print label (a0), cycles delta (s5 - s4), flushes delta (s8 - s7).
report:
    mv      s6, ra
    jal     ra, print_string
    sub     a0, s5, s4
    jal     ra, print_decimal
    la      a0, msg_flushes
    jal     ra, print_string
    sub     a0, s8, s7
    jal     ra, print_decimal
    la      a0, msg_newline
    jal     ra, print_string
    jalr    zero, s6, 0

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
    .option pop

    # =========================================================================
    # Aligned benchmark branch functions
    # Each function has a taken branch targeting a label 64 bytes away (outside bundle)
    # =========================================================================
    .section .text
    .option push
    .option norvc

    # Test 1 control functions (independent indices)
    .balign 64
test1_fn_a:
    bnez    a0, 1f
    nop
    nop
    nop
    .space 64
1:
    ret

    .balign 64
test1_fn_b:
    bnez    a0, 1f
    nop
    nop
    nop
    .space 64
1:
    ret

    # Base alias function at 2048-byte boundary
    # PC of branch is 2048 * K + 0x10 -> index 4
    .balign 2048
cond_alias_fn_0:
    nop
    nop
    nop
    nop
    bnez    a0, 1f
    nop
    nop
    nop
    .space 64
1:
    ret

    # Half alias function (+1024B): index 4 in 256-set; index 260 in 512-set
    # PC of branch is 2048 * K + 0x410 -> index 4 in 256-set
    .balign 1024
cond_half_alias_fn:
    nop
    nop
    nop
    nop
    bnez    a0, 1f
    nop
    nop
    nop
    .space 64
1:
    ret

    # Full alias function (+2048B): index 4 in both 256-set and 512-set
    # PC of branch is 2048 * (K+1) + 0x10 -> index 4
    .balign 2048
cond_alias_fn_1:
    nop
    nop
    nop
    nop
    bnez    a0, 1f
    nop
    nop
    nop
    .space 64
1:
    ret

    .option pop

    .section .rodata
msg_header:
    .string "=== BTB Benchmark ===\n"
msg_no_counters:
    .string "Profiling counters absent: build with PERF_COUNTERS=1\n"
msg_t1:
    .string "Test 1 (Control, no alias):           cycles="
msg_t2:
    .string "Test 2 (Cond branch alias 0x800):     cycles="
msg_t3:
    .string "Test 3 (Capacity spread 0x400):       cycles="
msg_flushes:
    .string " flush_cycles="
msg_newline:
    .string "\n"
msg_pass_marker:
    .string "<<PASS>>\n"
