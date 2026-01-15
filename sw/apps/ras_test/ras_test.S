# RAS (Return Address Stack) Comprehensive Test Suite
#
# This test suite thoroughly verifies RAS functionality with many test scenarios.
# For each test, we verify correctness and provide diagnostic output.
#
# CRITICAL DIAGNOSTIC: If RAS is not predicting, returns will cause 3-cycle
# misprediction penalties. With working RAS, returns predict correctly.
#
# Test Categories:
#   A. Basic functionality (simple call/return)
#   B. Stack depth tests (nested calls, overflow)
#   C. Instruction encoding tests (32-bit, compressed, mixed)
#   D. Address alignment tests (word-aligned, halfword-aligned)
#   E. Edge cases (underflow, coroutines, tight loops)
#   F. Stress tests (rapid call/return patterns)

    .section .init
    .option push
    .option norelax
    .globl _start

_start:
    # Initialize stack pointer
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)

    # Load UART address into s0 (callee-saved)
    lui     s0, 0x40000

    # Initialize counters
    li      s1, 0           # Test pass counter
    li      s2, 0           # Test fail counter
    li      s3, 0           # Test number

    # Print header
    la      a0, msg_header
    jal     ra, print_string

    # =========================================================================
    # TEST A1: Basic 32-bit JAL call and JALR return
    # =========================================================================
    addi    s3, s3, 1
    la      a0, msg_test_a1
    jal     ra, print_string

    li      t0, 0           # Will be set to 1 by callee

    .option norvc
    jal     ra, func_set_t0_to_1
    .option rvc

    # Verify t0 was set
    li      t1, 1
    bne     t0, t1, test_a1_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_a2_start

test_a1_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 1
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST A2: Basic compressed C.JAL call and C.JR return (RV32 only)
    # =========================================================================
test_a2_start:
    addi    s3, s3, 1
    la      a0, msg_test_a2
    jal     ra, print_string

    li      t0, 0

    .option rvc
    jal     ra, func_set_t0_to_2_compressed  # May compress to C.JAL

    li      t1, 2
    bne     t0, t1, test_a2_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_a3_start

test_a2_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 2
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST A3: Multiple sequential calls to same function
    # =========================================================================
test_a3_start:
    addi    s3, s3, 1
    la      a0, msg_test_a3
    jal     ra, print_string

    li      t0, 0

    .option norvc
    jal     ra, func_increment_t0
    jal     ra, func_increment_t0
    jal     ra, func_increment_t0
    jal     ra, func_increment_t0
    jal     ra, func_increment_t0
    .option rvc

    li      t1, 5
    bne     t0, t1, test_a3_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_b1_start

test_a3_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 5
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST B1: Nested calls - 2 levels
    # =========================================================================
test_b1_start:
    addi    s3, s3, 1
    la      a0, msg_test_b1
    jal     ra, print_string

    li      t0, 0

    .option norvc
    jal     ra, func_nested_2_level1
    .option rvc

    # level1 adds 1, level2 adds 10 = 11
    li      t1, 11
    bne     t0, t1, test_b1_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_b2_start

test_b1_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 11
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST B2: Nested calls - 4 levels
    # =========================================================================
test_b2_start:
    addi    s3, s3, 1
    la      a0, msg_test_b2
    jal     ra, print_string

    li      t0, 0

    .option norvc
    jal     ra, func_nested_4_level1
    .option rvc

    # level1=1, level2=10, level3=100, level4=1000 = 1111
    li      t1, 1111
    bne     t0, t1, test_b2_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_b3_start

test_b2_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 1111
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST B3: Nested calls - 8 levels (RAS depth limit)
    # =========================================================================
test_b3_start:
    addi    s3, s3, 1
    la      a0, msg_test_b3
    jal     ra, print_string

    li      t0, 0

    .option norvc
    jal     ra, func_nested_8_level1
    .option rvc

    # Sum: 1+2+4+8+16+32+64+128 = 255
    li      t1, 255
    bne     t0, t1, test_b3_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_b4_start

test_b3_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 255
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST B4: Nested calls - 10 levels (exceeds RAS depth, tests overflow)
    # =========================================================================
test_b4_start:
    addi    s3, s3, 1
    la      a0, msg_test_b4
    jal     ra, print_string

    li      t0, 0

    .option norvc
    jal     ra, func_nested_10_level1
    .option rvc

    # Sum: 1+2+4+8+16+32+64+128+256+512 = 1023
    li      t1, 1023
    bne     t0, t1, test_b4_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_c1_start

test_b4_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 1023
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST C1: Mixed 32-bit call with compressed return (C.JR)
    # =========================================================================
test_c1_start:
    addi    s3, s3, 1
    la      a0, msg_test_c1
    jal     ra, print_string

    li      t0, 0

    .option norvc
    jal     ra, func_32bit_call_compressed_ret
    .option rvc

    li      t1, 0x42
    bne     t0, t1, test_c1_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_c2_start

test_c1_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 0x42
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST C2: Alternating compressed and 32-bit returns
    # =========================================================================
test_c2_start:
    addi    s3, s3, 1
    la      a0, msg_test_c2
    jal     ra, print_string

    li      t0, 0

    jal     ra, func_alt_ret_1    # Uses C.JR
    jal     ra, func_alt_ret_2    # Uses 32-bit JALR
    jal     ra, func_alt_ret_1    # Uses C.JR
    jal     ra, func_alt_ret_2    # Uses 32-bit JALR

    li      t1, 30   # 1+10+1+10 = 22, wait that's wrong... 1+2+1+2=6? Let me recalc: 5+10+5+10=30
    bne     t0, t1, test_c2_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_d1_start

test_c2_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 30
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST D1: Return to halfword-aligned address
    # This is critical - tests RAS prediction at non-word-aligned PC
    # =========================================================================
test_d1_start:
    addi    s3, s3, 1
    la      a0, msg_test_d1
    jal     ra, print_string

    li      t0, 0

    # Use a compressed instruction before the call to align return to halfword
    .option rvc
    c.nop                       # 2 bytes - now at PC+2
    jal     ra, func_increment_t0  # Return will be to halfword address

    li      t1, 1
    bne     t0, t1, test_d1_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_d2_start

test_d1_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 1
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST D2: Multiple returns to halfword-aligned addresses
    # =========================================================================
test_d2_start:
    addi    s3, s3, 1
    la      a0, msg_test_d2
    jal     ra, print_string

    li      t0, 0

    .option rvc
    c.nop
    jal     ra, func_increment_t0
    c.nop
    jal     ra, func_increment_t0
    c.nop
    jal     ra, func_increment_t0

    li      t1, 3
    bne     t0, t1, test_d2_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_e1_start

test_d2_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 3
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST E1: Call in tight loop (stresses RAS with repeated patterns)
    # =========================================================================
test_e1_start:
    addi    s3, s3, 1
    la      a0, msg_test_e1
    jal     ra, print_string

    li      t0, 0
    li      t1, 20          # Loop count

test_e1_loop:
    jal     ra, func_increment_t0
    addi    t1, t1, -1
    bnez    t1, test_e1_loop

    li      t1, 20
    bne     t0, t1, test_e1_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_e2_start

test_e1_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 20
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST E2: Back-to-back calls (no instructions between return and next call)
    # =========================================================================
test_e2_start:
    addi    s3, s3, 1
    la      a0, msg_test_e2
    jal     ra, print_string

    li      t0, 0

    # Create a sequence where returns are immediately followed by calls
    jal     ra, func_increment_t0  # Return here, immediately call again
    jal     ra, func_increment_t0  # Return here, immediately call again
    jal     ra, func_increment_t0  # Return here, immediately call again
    jal     ra, func_increment_t0  # Return here, immediately call again
    jal     ra, func_increment_t0  # Final return

    li      t1, 5
    bne     t0, t1, test_e2_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_e3_start

test_e2_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 5
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST E3: JALR with x5 (t0) as link register (alternate link reg)
    # =========================================================================
test_e3_start:
    addi    s3, s3, 1
    la      a0, msg_test_e3
    jal     ra, print_string

    li      t0, 0

    # Call using x5 as link register
    .option norvc
    jal     t0, func_using_t0_link
    .option rvc

    # func_using_t0_link sets t1 to 0x55 and returns via x5
    li      t2, 0x55
    bne     t1, t2, test_e3_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_e4_start

test_e3_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 0x55
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t1
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST E4: Nested calls with mixed x1/x5 link registers
    # Uses s4 as counter to avoid conflict with x5 as link register
    # =========================================================================
test_e4_start:
    addi    s3, s3, 1
    la      a0, msg_test_e4
    jal     ra, print_string

    li      s4, 0           # Use s4 as counter (callee-saved)

    .option norvc
    jal     ra, func_nested_mixed_link
    .option rvc

    # Should be 100 + 200 = 300
    li      t1, 300
    bne     s4, t1, test_e4_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_f1_start

test_e4_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 300
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, s4
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST F1: Stress test - many rapid calls
    # =========================================================================
test_f1_start:
    addi    s3, s3, 1
    la      a0, msg_test_f1
    jal     ra, print_string

    li      t0, 0
    li      t1, 100         # Loop count

test_f1_loop:
    jal     ra, func_increment_t0
    addi    t1, t1, -1
    bnez    t1, test_f1_loop

    li      t1, 100
    bne     t0, t1, test_f1_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test_f2_start

test_f1_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 100
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # TEST F2: Stress test - alternating call depths
    # =========================================================================
test_f2_start:
    addi    s3, s3, 1
    la      a0, msg_test_f2
    jal     ra, print_string

    li      t0, 0

    # Alternate between different nesting depths
    jal     ra, func_increment_t0           # Depth 1
    jal     ra, func_nested_2_level1        # Depth 2 (adds 11)
    jal     ra, func_increment_t0           # Depth 1
    jal     ra, func_nested_4_level1        # Depth 4 (adds 1111)
    jal     ra, func_increment_t0           # Depth 1

    # 1 + 11 + 1 + 1111 + 1 = 1125
    li      t1, 1125
    bne     t0, t1, test_f2_fail

    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       tests_done

test_f2_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    la      a0, msg_expected
    jal     ra, print_string
    li      a0, 1125
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, t0
    jal     ra, print_hex
    la      a0, msg_newline
    jal     ra, print_string

    # =========================================================================
    # All tests complete - print summary
    # =========================================================================
tests_done:
    la      a0, msg_summary
    jal     ra, print_string

    # Print pass count
    la      a0, msg_passed
    jal     ra, print_string
    mv      a0, s1
    jal     ra, print_decimal
    la      a0, msg_newline
    jal     ra, print_string

    # Print fail count
    la      a0, msg_failed
    jal     ra, print_string
    mv      a0, s2
    jal     ra, print_decimal
    la      a0, msg_newline
    jal     ra, print_string

    # Print total tests
    la      a0, msg_total
    jal     ra, print_string
    mv      a0, s3
    jal     ra, print_decimal
    la      a0, msg_newline
    jal     ra, print_string

    # Print final status
    bnez    s2, final_fail

    la      a0, msg_pass_marker
    jal     ra, print_string
    j       done

final_fail:
    la      a0, msg_fail_marker
    jal     ra, print_string

done:
    # Infinite loop
    j       done

# =============================================================================
# Test Functions - Category A (Basic)
# =============================================================================

    .align 2
func_set_t0_to_1:
    li      t0, 1
    .option norvc
    jalr    zero, ra, 0     # 32-bit return
    .option rvc

    .align 2
func_set_t0_to_2_compressed:
    li      t0, 2
    .option rvc
    c.jr    ra              # Compressed return

    .align 2
func_increment_t0:
    addi    t0, t0, 1
    .option norvc
    jalr    zero, ra, 0
    .option rvc

# =============================================================================
# Test Functions - Category B (Nested)
# =============================================================================

    .align 2
func_nested_2_level1:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 1
    .option norvc
    jal     ra, func_nested_2_level2
    .option rvc
    lw      ra, 0(sp)
    addi    sp, sp, 4
    .option norvc
    jalr    zero, ra, 0
    .option rvc

    .align 2
func_nested_2_level2:
    addi    t0, t0, 10
    .option norvc
    jalr    zero, ra, 0
    .option rvc

    .align 2
func_nested_4_level1:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 1
    .option norvc
    jal     ra, func_nested_4_level2
    .option rvc
    lw      ra, 0(sp)
    addi    sp, sp, 4
    .option norvc
    jalr    zero, ra, 0
    .option rvc

    .align 2
func_nested_4_level2:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 10
    .option norvc
    jal     ra, func_nested_4_level3
    .option rvc
    lw      ra, 0(sp)
    addi    sp, sp, 4
    .option norvc
    jalr    zero, ra, 0
    .option rvc

    .align 2
func_nested_4_level3:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 100
    .option norvc
    jal     ra, func_nested_4_level4
    .option rvc
    lw      ra, 0(sp)
    addi    sp, sp, 4
    .option norvc
    jalr    zero, ra, 0
    .option rvc

    .align 2
func_nested_4_level4:
    addi    t0, t0, 1000
    .option norvc
    jalr    zero, ra, 0
    .option rvc

# 8-level nesting (adds powers of 2)
    .align 2
func_nested_8_level1:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 1
    jal     ra, func_nested_8_level2
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_8_level2:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 2
    jal     ra, func_nested_8_level3
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_8_level3:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 4
    jal     ra, func_nested_8_level4
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_8_level4:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 8
    jal     ra, func_nested_8_level5
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_8_level5:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 16
    jal     ra, func_nested_8_level6
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_8_level6:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 32
    jal     ra, func_nested_8_level7
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_8_level7:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 64
    jal     ra, func_nested_8_level8
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_8_level8:
    addi    t0, t0, 128
    ret

# 10-level nesting (exceeds RAS depth of 8)
    .align 2
func_nested_10_level1:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 1
    jal     ra, func_nested_10_level2
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_10_level2:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 2
    jal     ra, func_nested_10_level3
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_10_level3:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 4
    jal     ra, func_nested_10_level4
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_10_level4:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 8
    jal     ra, func_nested_10_level5
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_10_level5:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 16
    jal     ra, func_nested_10_level6
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_10_level6:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 32
    jal     ra, func_nested_10_level7
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_10_level7:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 64
    jal     ra, func_nested_10_level8
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_10_level8:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 128
    jal     ra, func_nested_10_level9
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_10_level9:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 256
    jal     ra, func_nested_10_level10
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

    .align 2
func_nested_10_level10:
    addi    t0, t0, 512
    ret

# =============================================================================
# Test Functions - Category C (Mixed encoding)
# =============================================================================

    .align 2
func_32bit_call_compressed_ret:
    li      t0, 0x42
    .option rvc
    c.jr    ra              # Compressed return from 32-bit call

    .align 2
func_alt_ret_1:
    addi    t0, t0, 5
    .option rvc
    c.jr    ra              # Compressed return

    .align 2
func_alt_ret_2:
    addi    t0, t0, 10
    .option norvc
    jalr    zero, ra, 0     # 32-bit return
    .option rvc

# =============================================================================
# Test Functions - Category E (Edge cases)
# =============================================================================

    .align 2
func_using_t0_link:
    # This function is called with x5 (t0) as link register
    # Must return via x5
    li      t1, 0x55
    .option norvc
    jalr    zero, t0, 0     # Return via x5 (t0)
    .option rvc

    .align 2
func_nested_mixed_link:
    # Uses x1 (ra) for outer call, x5 (t0) for inner call
    # Counter is in s4 (caller's responsibility to save if needed)
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    s4, s4, 100
    .option norvc
    jal     t0, func_inner_via_t0
    .option rvc
    lw      ra, 0(sp)
    addi    sp, sp, 4
    .option norvc
    jalr    zero, ra, 0
    .option rvc

    .align 2
func_inner_via_t0:
    # Called via x5 (t0), increments s4, returns via t0
    addi    s4, s4, 200
    .option norvc
    jalr    zero, t0, 0     # Return via x5
    .option rvc

# =============================================================================
# Utility functions
# =============================================================================

print_string:
    mv      t5, a0
print_string_loop:
    lb      t6, 0(t5)
    beqz    t6, print_string_done
    sb      t6, 0(s0)
    addi    t5, t5, 1
    j       print_string_loop
print_string_done:
    ret

print_decimal:
    li      t5, 10
    li      t6, 0
    addi    sp, sp, -40

    beqz    a0, print_decimal_zero

print_decimal_loop:
    beqz    a0, print_decimal_print
    remu    a1, a0, t5
    divu    a0, a0, t5
    addi    a1, a1, '0'
    sb      a1, 0(sp)
    addi    sp, sp, 1
    addi    t6, t6, 1
    j       print_decimal_loop

print_decimal_print:
    beqz    t6, print_decimal_done
    addi    sp, sp, -1
    lb      a1, 0(sp)
    sb      a1, 0(s0)
    addi    t6, t6, -1
    j       print_decimal_print

print_decimal_zero:
    li      a1, '0'
    sb      a1, 0(s0)

print_decimal_done:
    addi    sp, sp, 40
    ret

print_hex:
    li      t5, 8
    li      t6, 28

print_hex_loop:
    beqz    t5, print_hex_done
    srl     a1, a0, t6
    andi    a1, a1, 0xF
    li      a2, 10
    blt     a1, a2, print_hex_digit
    addi    a1, a1, ('A' - 10)
    j       print_hex_out
print_hex_digit:
    addi    a1, a1, '0'
print_hex_out:
    sb      a1, 0(s0)
    addi    t6, t6, -4
    addi    t5, t5, -1
    j       print_hex_loop

print_hex_done:
    ret

# =============================================================================
# String constants
# =============================================================================
    .section .rodata

msg_header:
    .string "=== RAS Comprehensive Test Suite ===\n"

msg_test_a1:
    .string "A1: Basic 32-bit JAL/JALR... "
msg_test_a2:
    .string "A2: Compressed C.JAL/C.JR... "
msg_test_a3:
    .string "A3: Sequential calls (5x)... "

msg_test_b1:
    .string "B1: Nested 2 levels... "
msg_test_b2:
    .string "B2: Nested 4 levels... "
msg_test_b3:
    .string "B3: Nested 8 levels (RAS limit)... "
msg_test_b4:
    .string "B4: Nested 10 levels (overflow)... "

msg_test_c1:
    .string "C1: 32-bit call, compressed ret... "
msg_test_c2:
    .string "C2: Alternating ret encoding... "

msg_test_d1:
    .string "D1: Return to halfword addr... "
msg_test_d2:
    .string "D2: Multiple halfword returns... "

msg_test_e1:
    .string "E1: Loop with calls (20x)... "
msg_test_e2:
    .string "E2: Back-to-back calls... "
msg_test_e3:
    .string "E3: x5 (t0) as link reg... "
msg_test_e4:
    .string "E4: Nested with x5 link... "

msg_test_f1:
    .string "F1: Stress 100 calls... "
msg_test_f2:
    .string "F2: Alternating depths... "

msg_ok:
    .string "OK\n"
msg_fail:
    .string "FAIL\n"
msg_expected:
    .string "  Expected: 0x"
msg_got:
    .string "  Got: 0x"
msg_newline:
    .string "\n"

msg_summary:
    .string "\n=== Summary ===\n"
msg_passed:
    .string "Passed: "
msg_failed:
    .string "Failed: "
msg_total:
    .string "Total:  "

msg_pass_marker:
    .string "<<PASS>>\n"
msg_fail_marker:
    .string "<<FAIL>>\n"
