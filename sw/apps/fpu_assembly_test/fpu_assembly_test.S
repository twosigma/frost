# FPU Assembly Test
#
# Directed tests to stress FP hazard corner cases (looped for amplification):
#   1A) FLD squashed by a taken branch should NOT update f1 or forward stale data.
#   1B) FLD squashed by a JAL should NOT update f1 or forward stale data.
#   2A) FP load-use hazard overlapping forward-stall from FSGNJ.D.
#   2B) FP load-use hazard overlapping forward-stall from pipelined FADD.D with deps.

    .section .init
    .option push
    .option norelax
    .globl _start

_start:
    .option norvc           # Force 32-bit for setup

    # Initialize stack pointer
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)

    # Load UART address into s0 (callee-saved, persists across calls)
    lui     s0, 0x40000

    # Enable FP unit: set FS=Dirty in mstatus
    li      t0, (3 << 13)
    csrs    mstatus, t0

    # Initialize test counters
    li      s1, 0           # pass count
    li      s2, 0           # fail count

    # Print header
    la      a0, msg_header
    jal     ra, print_string

    # =========================================
    # Test 1A: Squashed FLD via taken branch
    # =========================================
    la      a0, msg_test1a
    jal     ra, print_string

    li      t6, 256
test1a_loop:
    # Seed f1 = 3.0
    la      t0, data_three
    fld     f1, 0(t0)

    # Prepare address for squashed load (1.0)
    la      t1, data_one

    # Taken branch should squash the following FLD
    beq     x0, x0, test1a_target
    fld     f1, 0(t1)        # SHOULD be squashed
    nop
    nop

test1a_target:
    nop
    nop

    # f2 = f1 + f1, expect 6.0
    fadd.d  f2, f1, f1
    fcvt.w.d t2, f2
    li      t3, 6
    bne     t2, t3, test1a_fail
    addi    t6, t6, -1
    bnez    t6, test1a_loop

test1a_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test1b_start

test1a_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    j       test1b_start

    # =========================================
    # Test 1B: Squashed FLD via JAL
    # =========================================
test1b_start:
    la      a0, msg_test1b
    jal     ra, print_string

    li      t6, 256
test1b_loop:
    # Seed f1 = 3.0
    la      t0, data_three
    fld     f1, 0(t0)

    # Prepare address for squashed load (1.0)
    la      t1, data_one

    # JAL should squash the following FLD
    jal     x0, test1b_target
    fld     f1, 0(t1)        # SHOULD be squashed
    nop
    nop

test1b_target:
    nop
    nop

    # f2 = f1 + f1, expect 6.0
    fadd.d  f2, f1, f1
    fcvt.w.d t2, f2
    li      t3, 6
    bne     t2, t3, test1b_fail
    addi    t6, t6, -1
    bnez    t6, test1b_loop

test1b_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test2a_start

test1b_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    j       test2a_start

    # =========================================
    # Test 2A: Load-use hazard + forward stall (FSGNJ)
    # =========================================
test2a_start:
    la      a0, msg_test2a
    jal     ra, print_string

    li      t6, 256
test2a_loop:
    # Seed f1 with a distinct value (4.0) to detect stale use
    la      t0, data_four
    fld     f1, 0(t0)

    # Values for a single-cycle FP op (FSGNJ.D) to trigger forward stall
    la      t1, data_one_point_five
    fld     f3, 0(t1)
    la      t2, data_minus_two_point_five
    fld     f4, 0(t2)

    # Single-cycle FP op that writes a result (triggers fp_forward pipeline stall)
    fsgnj.d f8, f3, f4

    # Load-use hazard (FLD immediately followed by FADD.D)
    la      t3, data_one
    fld     f1, 0(t3)
    fadd.d  f2, f1, f1

    # Expect 2.0 (1.0 + 1.0)
    fcvt.w.d t4, f2
    li      t5, 2
    bne     t4, t5, test2a_fail
    addi    t6, t6, -1
    bnez    t6, test2a_loop

test2a_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test2b_start

test2a_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    j       test2b_start

    # =========================================
    # Test 2B: Load-use hazard + forward stall (FADD deps)
    # =========================================
test2b_start:
    la      a0, msg_test2b
    jal     ra, print_string

    li      t6, 256
test2b_loop:
    # Seed f1 with a distinct value (4.0) to detect stale use
    la      t0, data_four
    fld     f1, 0(t0)

    # Pipelined FP op with interleaved dependencies
    la      t1, data_one
    fld     f3, 0(t1)
    la      t2, data_two
    fld     f4, 0(t2)

    # f8 = 1.0 + 2.0 = 3.0 (pipelined), f9 = f8 + 1.0 = 4.0
    fadd.d  f8, f3, f4
    fadd.d  f9, f8, f3

    # Verify f9 == 4
    fcvt.w.d t4, f9
    li      t5, 4
    bne     t4, t5, test2b_fail

    # Load-use hazard (FLD immediately followed by FADD.D)
    la      t3, data_one
    fld     f1, 0(t3)
    fadd.d  f2, f1, f1

    # Expect 2.0 (1.0 + 1.0)
    fcvt.w.d t4, f2
    li      t5, 2
    bne     t4, t5, test2b_fail
    addi    t6, t6, -1
    bnez    t6, test2b_loop

test2b_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       tests_done

test2b_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Summary
    # =========================================
tests_done:
    bnez    s2, some_failed
    la      a0, msg_all_pass
    jal     ra, print_string
    la      a0, msg_marker
    jal     ra, print_string
    j       done

some_failed:
    la      a0, msg_some_fail
    jal     ra, print_string

    .option rvc
done:
    c.j     done

# =========================================
# Helper: Print null-terminated string
# Input: a0 = pointer to string
# =========================================
    .option norvc
    .balign 4
print_string:
    mv      t2, a0              # Save string pointer
1:
    lb      t1, 0(t2)           # Load character
    beqz    t1, 2f              # Exit if null
    sb      t1, 0(s0)           # Write to UART
    addi    t2, t2, 1           # Next character
    j       1b
2:
    .option rvc
    c.jr    ra
    .option norvc

    .option pop

# =========================================
# String data
# =========================================
    .section .rodata
msg_header:
    .asciz "=== FPU Assembly Test ===\n"
msg_test1a:
    .asciz "Test 1A: Squashed FLD (branch)... "
msg_test1b:
    .asciz "Test 1B: Squashed FLD (JAL)... "
msg_test2a:
    .asciz "Test 2A: Load-use + forward stall (FSGNJ)... "
msg_test2b:
    .asciz "Test 2B: Load-use + forward stall (FADD deps)... "
msg_ok:
    .asciz "OK\n"
msg_fail:
    .asciz "FAIL\n"
msg_all_pass:
    .asciz "\n=== All Tests Passed ===\n"
msg_some_fail:
    .asciz "\n=== SOME TESTS FAILED ===\n"
msg_marker:
    .asciz "<<PASS>>\n"

    .balign 8
# =========================================
# FP constants (double-precision)
# =========================================
data_one:
    .dword 0x3FF0000000000000    # 1.0

data_two:
    .dword 0x4000000000000000    # 2.0

data_three:
    .dword 0x4008000000000000    # 3.0

data_four:
    .dword 0x4010000000000000    # 4.0

data_one_point_five:
    .dword 0x3FF8000000000000    # 1.5

data_minus_two_point_five:
    .dword 0xC004000000000000    # -2.5

# =========================================
# Stack
# =========================================
    .section .bss
    .align 4
stack_bottom:
    .space 512
_stack_top:
