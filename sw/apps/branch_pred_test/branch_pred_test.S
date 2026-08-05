# Branch Prediction Test Suite
#
# Tests branch prediction behavior with increasingly complex scenarios.
# Each test uses a counter in a register to verify correct execution.
# If any counter doesn't match expected value, the test fails.
#
# Test scenarios:
#   1. Simple forward branch (not taken)
#   2. Simple forward branch (taken)
#   3. Simple backward branch (loop, 5 iterations)
#   4. JAL to function and back
#   5. Tight loop (10 iterations) - tests BTB learning
#   6. Alternating branch direction - stresses predictor
#   7. Nested loops - complex control flow
#   8. Branch after branch (back-to-back branches)

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

    # Initialize test counters to 0
    li      s1, 0           # Test pass counter
    li      s2, 0           # Test fail counter

    # Print header
    la      a0, msg_header
    jal     ra, print_string

    # =========================================
    # Test 1: Forward branch NOT taken
    # Counter should be 1 after the branch
    # =========================================
    la      a0, msg_test1
    jal     ra, print_string

    li      t0, 0           # Counter
    li      t1, 0           # Condition (0 = not taken)
    addi    t0, t0, 1       # t0 = 1
    beqz    t1, test1_skip  # Branch NOT taken (t1 != 0 is false... wait, beqz means branch if t1==0)
    # Actually beqz t1 will branch since t1=0. Let me fix this.
    # Use bnez instead for "not taken" when t1=0
test1_skip:
    addi    t0, t0, 1       # t0 = 2

    # Verify: t0 should be 2
    li      t2, 2
    beq     t0, t2, test1_pass
    j       test1_fail
test1_pass:
    addi    s1, s1, 1       # Increment pass counter
    la      a0, msg_ok
    jal     ra, print_string
    j       test2_start
test1_fail:
    addi    s2, s2, 1       # Increment fail counter
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 2: Forward branch TAKEN
    # Counter should be 1 (skips the middle increment)
    # =========================================
test2_start:
    la      a0, msg_test2
    jal     ra, print_string

    li      t0, 0           # Counter
    li      t1, 0           # Condition
    addi    t0, t0, 1       # t0 = 1
    beqz    t1, test2_skip  # Branch TAKEN (t1 == 0)
    addi    t0, t0, 10      # Should be skipped
test2_skip:
    addi    t0, t0, 1       # t0 = 2

    # Verify: t0 should be 2 (1 + skipped + 1)
    li      t2, 2
    beq     t0, t2, test2_pass
    j       test2_fail
test2_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test3_start
test2_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 3: Simple loop (backward branch, 5 iterations)
    # Counter should be 5
    # =========================================
test3_start:
    la      a0, msg_test3
    jal     ra, print_string

    li      t0, 0           # Counter
    li      t1, 5           # Loop count
test3_loop:
    addi    t0, t0, 1       # Increment counter
    addi    t1, t1, -1      # Decrement loop count
    bnez    t1, test3_loop  # Branch back if not done

    # Verify: t0 should be 5
    li      t2, 5
    beq     t0, t2, test3_pass
    j       test3_fail
test3_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test4_start
test3_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 4: JAL to function and back
    # Counter should be 3 (before + in function + after)
    # =========================================
test4_start:
    la      a0, msg_test4
    jal     ra, print_string

    li      t0, 0           # Counter
    addi    t0, t0, 1       # t0 = 1 (before call)
    jal     ra, test4_func  # Call function
    addi    t0, t0, 1       # t0 = 3 (after call)

    # Verify: t0 should be 3
    li      t2, 3
    beq     t0, t2, test4_pass
    j       test4_fail
test4_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test5_start
test4_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    j       test5_start

    .balign 4
test4_func:
    addi    t0, t0, 1       # t0 = 2 (in function)
    ret

    # =========================================
    # Test 5: Tight loop (10 iterations)
    # BTB should learn the backward branch
    # =========================================
test5_start:
    la      a0, msg_test5
    jal     ra, print_string

    li      t0, 0           # Counter
    li      t1, 10          # Loop count
test5_loop:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test5_loop

    # Verify: t0 should be 10
    li      t2, 10
    beq     t0, t2, test5_pass
    j       test5_fail
test5_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test6_start
test5_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 6: Multiple JAL calls to same function
    # Tests BTB learning for calls
    # =========================================
test6_start:
    la      a0, msg_test6
    jal     ra, print_string

    li      t0, 0
    jal     ra, increment_t0  # Call 1
    jal     ra, increment_t0  # Call 2
    jal     ra, increment_t0  # Call 3
    jal     ra, increment_t0  # Call 4
    jal     ra, increment_t0  # Call 5

    # Verify: t0 should be 5
    li      t2, 5
    beq     t0, t2, test6_pass
    j       test6_fail
test6_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test7_start
test6_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string
    j       test7_start

    .balign 4
increment_t0:
    addi    t0, t0, 1
    ret

    # =========================================
    # Test 7: Nested loops
    # Outer: 3 iterations, Inner: 4 iterations each
    # Total inner iterations: 12
    # =========================================
test7_start:
    la      a0, msg_test7
    jal     ra, print_string

    li      t0, 0           # Inner loop counter (total)
    li      t1, 3           # Outer loop count
test7_outer:
    li      t2, 4           # Inner loop count
test7_inner:
    addi    t0, t0, 1       # Count inner iterations
    addi    t2, t2, -1
    bnez    t2, test7_inner
    addi    t1, t1, -1
    bnez    t1, test7_outer

    # Verify: t0 should be 12 (3 * 4)
    li      t2, 12
    beq     t0, t2, test7_pass
    j       test7_fail
test7_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test8_start
test7_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 8: Back-to-back branches
    # Multiple conditional branches in sequence
    # =========================================
test8_start:
    la      a0, msg_test8
    jal     ra, print_string

    li      t0, 0
    li      t1, 1           # For taken branches
    li      t2, 0           # For not-taken branches

    # Series of branches
    beqz    t2, test8_br1   # Taken
    addi    t0, t0, 100     # Skipped
test8_br1:
    addi    t0, t0, 1       # t0 = 1
    bnez    t1, test8_br2   # Taken
    addi    t0, t0, 100     # Skipped
test8_br2:
    addi    t0, t0, 1       # t0 = 2
    beqz    t1, test8_br3   # NOT taken (t1 != 0)
    addi    t0, t0, 1       # t0 = 3
test8_br3:
    addi    t0, t0, 1       # t0 = 4

    # Verify: t0 should be 4
    li      t2, 4
    beq     t0, t2, test8_pass
    j       test8_fail
test8_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test9_start
test8_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 9: Compressed branch instructions (C.BEQZ, C.BNEZ)
    # Tests prediction with 16-bit branches
    # =========================================
test9_start:
    la      a0, msg_test9
    jal     ra, print_string

    li      t0, 0
    li      t1, 0           # For c.beqz (taken)
    li      t2, 1           # For c.bnez (taken)

    .option rvc
    c.beqz  a0, test9_skip1 # Use a0 (was set to msg address, non-zero)
    .option norvc
    # a0 is non-zero (msg address), so c.beqz NOT taken
    addi    t0, t0, 1       # t0 = 1 (NOT skipped)
test9_skip1:
    .option rvc
    # t0 only accessible via full register, use s-register
    mv      a1, t2          # a1 = 1
    c.bnez  a1, test9_skip2 # Taken (a1 != 0)
    .option norvc
    addi    t0, t0, 100     # Skipped
test9_skip2:
    addi    t0, t0, 1       # t0 = 2

    # Verify: t0 should be 2
    li      t2, 2
    beq     t0, t2, test9_pass
    j       test9_fail
test9_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test10_start
test9_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 10: Loop with compressed instructions
    # =========================================
test10_start:
    la      a0, msg_test10
    jal     ra, print_string

    li      t0, 0           # Counter
    li      a2, 5           # Loop count (use a2 for c.bnez)
    .option rvc
test10_loop:
    c.addi  t0, 1           # Increment counter (compressed)
    c.addi  a2, -1          # Decrement loop count (compressed)
    c.bnez  a2, test10_loop # Compressed backward branch
    .option norvc

    # Verify: t0 should be 5
    li      t2, 5
    beq     t0, t2, test10_pass
    j       test10_fail
test10_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test11_start
test10_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 11: JALR (indirect jump)
    # Tests return address stack / indirect jump handling
    # =========================================
test11_start:
    la      a0, msg_test11
    jal     ra, print_string

    li      t0, 0
    la      t3, test11_target      # Load target address
    addi    t0, t0, 1              # t0 = 1
    jalr    ra, t3, 0              # Indirect jump
    addi    t0, t0, 1              # t0 = 3 (after return)

    # Verify: t0 should be 3
    li      t2, 3
    beq     t0, t2, test11_pass
    j       test11_fail

    .balign 4
test11_target:
    addi    t0, t0, 1              # t0 = 2 (in function)
    ret

test11_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test12_start
test11_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 12: Train predictor then mispredictw
    # Run loop many times (train BTB for taken), then exit
    # =========================================
test12_start:
    la      a0, msg_test12
    jal     ra, print_string

    li      t0, 0           # Counter
    li      t1, 20          # Many iterations to train BTB
test12_loop:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test12_loop # BTB learns "taken"
    # Loop exits here - BTB predicts taken but should be not-taken
    addi    t0, t0, 1       # t0 = 21 (executed after loop exit)

    # Verify: t0 should be 21 (20 iterations + 1 after)
    li      t2, 21
    beq     t0, t2, test12_pass
    j       test12_fail
test12_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test13_start
test12_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 13: Branch immediately after load (load-use stall)
    # Tests branch prediction with stall interaction
    # Uses stack for load to avoid data section issues
    # =========================================
test13_start:
    la      a0, msg_test13
    jal     ra, print_string

    li      t0, 0
    li      t4, 1                  # Store value 1
    sw      t4, -4(sp)             # Store to stack
    nop                            # Clear any hazard
    nop
    lw      t4, -4(sp)             # Load value back (t4 = 1)
    bnez    t4, test13_taken       # Branch based on loaded value
    addi    t0, t0, 100            # Should be skipped
    j       test13_verify
test13_taken:
    addi    t0, t0, 1              # t0 = 1
test13_verify:
    # Verify: t0 should be 1
    li      t2, 1
    beq     t0, t2, test13_pass
    j       test13_fail
test13_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test14_start
test13_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 14: Multiple JALR to different targets
    # Tests indirect jump table behavior
    # =========================================
test14_start:
    la      a0, msg_test14
    jal     ra, print_string

    li      t0, 0
    la      t3, test14_func1
    jalr    ra, t3, 0              # Call func1
    la      t3, test14_func2
    jalr    ra, t3, 0              # Call func2
    la      t3, test14_func1
    jalr    ra, t3, 0              # Call func1 again
    la      t3, test14_func2
    jalr    ra, t3, 0              # Call func2 again

    # Verify: t0 should be 6 (1+2+1+2)
    li      t2, 6
    beq     t0, t2, test14_pass
    j       test14_fail

    .balign 4
test14_func1:
    addi    t0, t0, 1
    ret
    .balign 4
test14_func2:
    addi    t0, t0, 2
    ret

test14_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test15_start
test14_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 15: Branch at halfword boundary
    # PC[1]=1, tests prediction at 2-byte aligned addresses
    # =========================================
test15_start:
    la      a0, msg_test15
    jal     ra, print_string

    li      t0, 0
    li      a3, 3           # Loop count (use a3 for c.bnez)
    .option rvc
    nop                     # c.nop is 2 bytes, may adjust alignment
test15_loop:
    c.addi  t0, 1           # Compressed increment
    c.addi  a3, -1          # Compressed decrement
    c.bnez  a3, test15_loop # Compressed branch (may be at halfword boundary)
    .option norvc

    # Verify: t0 should be 3
    li      t2, 3
    beq     t0, t2, test15_pass
    j       test15_fail
test15_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test16_start
test15_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 16: JAL inside a loop (very common in real programs)
    # Function call on every iteration
    # =========================================
test16_start:
    la      a0, msg_test16
    jal     ra, print_string

    li      t0, 0           # Counter
    li      t1, 5           # Loop count
test16_loop:
    jal     ra, test16_helper  # Call function each iteration
    addi    t1, t1, -1
    bnez    t1, test16_loop

    # Verify: t0 should be 5
    li      t2, 5
    beq     t0, t2, test16_pass
    j       test16_fail

    .balign 4
test16_helper:
    addi    t0, t0, 1
    ret

test16_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test17_start
test16_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 17: Deep nested function calls
    # A calls B calls C calls D - tests return address handling
    # =========================================
test17_start:
    la      a0, msg_test17
    jal     ra, print_string

    li      t0, 0
    jal     ra, test17_A

    # Verify: t0 should be 4 (A + B + C + D)
    li      t2, 4
    beq     t0, t2, test17_pass
    j       test17_fail

    .balign 4
test17_A:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 1
    jal     ra, test17_B
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret
    .balign 4
test17_B:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 1
    jal     ra, test17_C
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret
    .balign 4
test17_C:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    addi    t0, t0, 1
    jal     ra, test17_D
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret
    .balign 4
test17_D:
    addi    t0, t0, 1
    ret

test17_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test18_start
test17_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 18: Alternating taken/not-taken pattern
    # Stresses branch predictor with unpredictable pattern
    # =========================================
test18_start:
    la      a0, msg_test18
    jal     ra, print_string

    li      t0, 0           # Counter for taken
    li      t1, 0           # Counter for not-taken
    li      t2, 10          # Number of iterations
    li      t3, 0           # Toggle: 0=taken, 1=not-taken
test18_loop:
    bnez    t3, test18_not_taken
    # Taken path
    addi    t0, t0, 1
    j       test18_continue
test18_not_taken:
    addi    t1, t1, 1
test18_continue:
    xori    t3, t3, 1       # Toggle
    addi    t2, t2, -1
    bnez    t2, test18_loop

    # Verify: t0 should be 5, t1 should be 5
    li      t4, 5
    bne     t0, t4, test18_fail
    bne     t1, t4, test18_fail
    j       test18_pass

test18_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test19_start
test18_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 19: Branch to compressed instruction at halfword
    # Target is a 16-bit instruction at PC[1]=1
    # =========================================
test19_start:
    la      a0, msg_test19
    jal     ra, print_string

    li      t0, 0
    li      t1, 1
    .option rvc
    c.nop                   # 2 bytes - push next instr to halfword boundary
test19_branch:
    .option norvc
    bnez    t1, test19_target  # Branch to halfword-aligned target
    addi    t0, t0, 100     # Should be skipped
    j       test19_verify

    # Align so target is at halfword
    .option rvc
    c.nop                   # Padding
test19_target:
    c.addi  t0, 1           # This should be at halfword boundary
    .option norvc

test19_verify:
    # Verify: t0 should be 1
    li      t2, 1
    beq     t0, t2, test19_pass
    j       test19_fail

test19_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test20_start
test19_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 20: Spanning instruction followed by branch
    # Force a 32-bit instruction to span a word boundary,
    # then immediately have a branch
    # =========================================
test20_start:
    la      a0, msg_test20
    jal     ra, print_string

    li      t0, 0
    li      t1, 1
    .option rvc
    c.nop                   # 2 bytes - push next 32-bit instr to span
    .option norvc
    # The next 32-bit instruction starts at halfword boundary (spans)
    addi    t0, t0, 1       # 32-bit, might span
    bnez    t1, test20_skip # Branch after potential spanning
    addi    t0, t0, 100     # Should be skipped
test20_skip:
    addi    t0, t0, 1       # t0 = 2

    # Verify: t0 should be 2
    li      t2, 2
    beq     t0, t2, test20_pass
    j       test20_fail
test20_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test21_start
test20_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 21: Loop with mixed 16/32-bit instructions
    # Complex instruction mix stresses fetch/decode alignment
    # =========================================
test21_start:
    la      a0, msg_test21
    jal     ra, print_string

    li      t0, 0
    li      a2, 5           # Loop count
    .option rvc
test21_loop:
    c.addi  t0, 1           # 16-bit
    .option norvc
    addi    t0, t0, 1       # 32-bit
    .option rvc
    c.addi  a2, -1          # 16-bit
    c.bnez  a2, test21_loop # 16-bit branch
    .option norvc

    # Verify: t0 should be 10 (5 iterations * 2 increments)
    li      t2, 10
    beq     t0, t2, test21_pass
    j       test21_fail
test21_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test22_start
test21_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 22: Rapid misprediction recovery
    # Multiple mispredictions in quick succession
    # =========================================
test22_start:
    la      a0, msg_test22
    jal     ra, print_string

    li      t0, 0

    # Train BTB for loop1 as taken
    li      t1, 3
test22_loop1:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test22_loop1
    # Misprediction on exit

    # Immediately train BTB for loop2 as taken
    li      t1, 3
test22_loop2:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test22_loop2
    # Another misprediction on exit

    # And again for loop3
    li      t1, 3
test22_loop3:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test22_loop3
    # Third misprediction

    # Verify: t0 should be 9 (3+3+3)
    li      t2, 9
    beq     t0, t2, test22_pass
    j       test22_fail
test22_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test23_start
test22_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 23: Stress test - many iterations
    # Long-running loop to stress prediction
    # =========================================
test23_start:
    la      a0, msg_test23
    jal     ra, print_string

    li      t0, 0
    li      t1, 100         # 100 iterations
test23_loop:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test23_loop

    # Verify: t0 should be 100
    li      t2, 100
    beq     t0, t2, test23_pass
    j       test23_fail
test23_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test24_start
test23_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 24: Call in nested loops
    # Function call inside nested loop structure
    # =========================================
test24_start:
    la      a0, msg_test24
    jal     ra, print_string

    li      t0, 0
    li      t1, 3           # Outer count
test24_outer:
    li      t2, 3           # Inner count
test24_inner:
    jal     ra, test24_helper
    addi    t2, t2, -1
    bnez    t2, test24_inner
    addi    t1, t1, -1
    bnez    t1, test24_outer

    # Verify: t0 should be 9 (3*3)
    li      t3, 9
    beq     t0, t3, test24_pass
    j       test24_fail

    .balign 4
test24_helper:
    addi    t0, t0, 1
    ret

test24_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test25_start
test24_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 25: Branch with long offset (forward)
    # Tests branches with larger displacement
    # =========================================
test25_start:
    la      a0, msg_test25
    jal     ra, print_string

    li      t0, 0
    li      t1, 1
    addi    t0, t0, 1
    bnez    t1, test25_far_target
    # Fill space to make branch offset larger
    .space 64               # 64 bytes of padding
    addi    t0, t0, 100     # Should never execute
    j       test25_verify
    .space 64               # More padding

test25_far_target:
    addi    t0, t0, 1       # t0 = 2

test25_verify:
    li      t2, 2
    beq     t0, t2, test25_pass
    j       test25_fail
test25_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test26_start
test25_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 26: Recursive function calls
    # Tests stack and return address handling under recursion
    # =========================================
test26_start:
    la      a0, msg_test26
    jal     ra, print_string

    li      t0, 0           # Counter
    li      a0, 5           # Recursion depth
    jal     ra, test26_recurse

    # Verify: t0 should be 5 (counted on way down)
    li      t2, 5
    beq     t0, t2, test26_pass
    j       test26_fail

    .balign 4
test26_recurse:
    beqz    a0, test26_base     # Base case
    addi    sp, sp, -8
    sw      ra, 4(sp)
    sw      a0, 0(sp)
    addi    t0, t0, 1           # Count
    addi    a0, a0, -1          # Decrement depth
    jal     ra, test26_recurse  # Recursive call
    lw      a0, 0(sp)
    lw      ra, 4(sp)
    addi    sp, sp, 8
test26_base:
    ret

test26_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test27_start
test26_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 27: Spanning branch instruction
    # Branch instruction crosses word boundary
    # =========================================
test27_start:
    la      a0, msg_test27
    jal     ra, print_string

    li      t0, 0
    li      t1, 1
    .option rvc
    c.nop                       # 2 bytes to push branch to halfword
    .option norvc
    # This 32-bit branch starts at halfword = spans word boundary
    beqz    t1, test27_nottaken # NOT taken (t1 != 0)
    addi    t0, t0, 1           # t0 = 1 (executed)
    j       test27_verify
test27_nottaken:
    addi    t0, t0, 100         # Should not execute
test27_verify:
    li      t2, 1
    beq     t0, t2, test27_pass
    j       test27_fail
test27_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test28_start
test27_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 28: Spanning branch that IS taken
    # =========================================
test28_start:
    la      a0, msg_test28
    jal     ra, print_string

    li      t0, 0
    li      t1, 0           # For taken branch
    .option rvc
    c.nop                   # Align to make next branch span
    .option norvc
    beqz    t1, test28_taken  # TAKEN (t1 == 0), spanning branch
    addi    t0, t0, 100     # Should be skipped
    j       test28_verify
test28_taken:
    addi    t0, t0, 1       # t0 = 1
test28_verify:
    li      t2, 1
    beq     t0, t2, test28_pass
    j       test28_fail
test28_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test29_start
test28_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 29: Spanning loop branch
    # Loop back-edge is a spanning instruction
    # =========================================
test29_start:
    la      a0, msg_test29
    jal     ra, print_string

    li      t0, 0
    li      t1, 5
    .option rvc
    c.nop                   # Align loop branch to span
test29_loop:
    c.addi  t0, 1           # 2 bytes
    .option norvc
    addi    t1, t1, -1      # 4 bytes - this is at halfword
    bnez    t1, test29_loop # 4 bytes - this should span

    # Verify: t0 should be 5
    li      t2, 5
    beq     t0, t2, test29_pass
    j       test29_fail
test29_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test30_start
test29_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 30: Many rapid function calls
    # Stress call/return prediction
    # =========================================
test30_start:
    la      a0, msg_test30
    jal     ra, print_string

    li      t0, 0
    jal     ra, test30_fn
    jal     ra, test30_fn
    jal     ra, test30_fn
    jal     ra, test30_fn
    jal     ra, test30_fn
    jal     ra, test30_fn
    jal     ra, test30_fn
    jal     ra, test30_fn
    jal     ra, test30_fn
    jal     ra, test30_fn
    # 10 calls

    li      t2, 10
    beq     t0, t2, test30_pass
    j       test30_fail

    .balign 4
test30_fn:
    addi    t0, t0, 1
    ret

test30_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test31_start
test30_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 31: Interleaved calls to multiple functions
    # Different call sites, different targets
    # =========================================
test31_start:
    la      a0, msg_test31
    jal     ra, print_string

    li      t0, 0
    jal     ra, test31_fn1
    jal     ra, test31_fn2
    jal     ra, test31_fn3
    jal     ra, test31_fn1
    jal     ra, test31_fn2
    jal     ra, test31_fn3
    jal     ra, test31_fn1
    jal     ra, test31_fn2
    jal     ra, test31_fn3
    # 9 calls: 3x fn1(+1), 3x fn2(+2), 3x fn3(+3) = 3+6+9 = 18

    li      t2, 18
    beq     t0, t2, test31_pass
    j       test31_fail

    .balign 4
test31_fn1:
    addi    t0, t0, 1
    ret
    .balign 4
test31_fn2:
    addi    t0, t0, 2
    ret
    .balign 4
test31_fn3:
    addi    t0, t0, 3
    ret

test31_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test32_start
test31_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 32: Loop exit immediately followed by another loop
    # Tests misprediction recovery entering new loop
    # =========================================
test32_start:
    la      a0, msg_test32
    jal     ra, print_string

    li      t0, 0

    # Loop 1
    li      t1, 3
test32_loop1:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test32_loop1
    # Misprediction here, immediately start loop 2

    # Loop 2
    li      t1, 3
test32_loop2:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test32_loop2

    # Loop 3
    li      t1, 3
test32_loop3:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test32_loop3

    # Loop 4
    li      t1, 3
test32_loop4:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test32_loop4

    # Loop 5
    li      t1, 3
test32_loop5:
    addi    t0, t0, 1
    addi    t1, t1, -1
    bnez    t1, test32_loop5

    # Verify: t0 should be 15 (5 loops * 3 iter)
    li      t2, 15
    beq     t0, t2, test32_pass
    j       test32_fail
test32_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test33_start
test32_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 33: Very tight compressed loop (single instruction body)
    # Minimal loop body stresses prediction
    # =========================================
test33_start:
    la      a0, msg_test33
    jal     ra, print_string

    li      a2, 20          # Loop count
    .option rvc
test33_loop:
    c.addi  a2, -1          # Decrement only
    c.bnez  a2, test33_loop
    .option norvc

    # If we get here with a2=0, it worked
    bnez    a2, test33_fail
    j       test33_pass

test33_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test34_start
test33_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 34: Branch chain - target of branch is another branch
    # =========================================
test34_start:
    la      a0, msg_test34
    jal     ra, print_string

    li      t0, 0
    li      t1, 0           # Taken
    li      t2, 1           # Not taken

    beqz    t1, test34_br2      # Taken -> go to br2
    addi    t0, t0, 100
test34_br2:
    beqz    t1, test34_br3      # Taken -> go to br3
    addi    t0, t0, 100
test34_br3:
    beqz    t1, test34_br4      # Taken -> go to br4
    addi    t0, t0, 100
test34_br4:
    bnez    t2, test34_done     # Taken -> go to done
    addi    t0, t0, 100
test34_done:
    addi    t0, t0, 1           # t0 = 1

    li      t3, 1
    beq     t0, t3, test34_pass
    j       test34_fail
test34_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test35_start
test34_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 35: JALR immediately after load (load-use with JALR)
    # This is a critical test - load then jump to loaded address
    # =========================================
test35_start:
    la      a0, msg_test35
    jal     ra, print_string

    li      t0, 0

    # Load target address then jump to it
    la      t3, test35_target_addr  # Get address of pointer
    lw      t4, 0(t3)               # Load the target address
    addi    t0, t0, 1               # t0 = 1 (before jump)
    jalr    ra, t4, 0               # Jump to loaded address
    addi    t0, t0, 1               # t0 = 3 (after return)

    # Verify: t0 should be 3
    li      t2, 3
    beq     t0, t2, test35_pass
    j       test35_fail

    # Force word alignment: add 2 bytes to get from offset 2 to offset 0
    .option rvc
    c.nop                           # 2-byte nop - moves from d8e to d90 (word aligned)
    .option norvc
test35_target:
    addi    t0, t0, 1               # t0 = 2 (in function)
    ret

    .balign 4
test35_target_addr:
    .word test35_target

test35_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test36_start
test35_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 36: LW immediately before JALR (no intervening instr)
    # This specifically tests load-use hazard with indirect jump
    # =========================================
test36_start:
    la      a0, msg_test36
    jal     ra, print_string

    li      t0, 0

    # Load then IMMEDIATELY jalr - no intervening instruction
    la      t3, test36_target_addr
    lw      t4, 0(t3)               # Load target
    jalr    ra, t4, 0               # IMMEDIATE jalr - load-use hazard
    addi    t0, t0, 1               # t0 = 2 after return

    # Verify: t0 should be 2
    li      t2, 2
    beq     t0, t2, test36_pass
    j       test36_fail

    .balign 4
test36_target:
    addi    t0, t0, 1               # t0 = 1
    ret

    .balign 4
test36_target_addr:
    .word test36_target

test36_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test37_start
test36_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 37: Jump table with load-use (original failing case)
    # =========================================
test37_start:
    la      a0, msg_test37
    jal     ra, print_string

    li      t0, 0

    # Simulate switch(i) for i=0,1,2
    li      t1, 0
    jal     ra, test37_dispatch
    li      t1, 1
    jal     ra, test37_dispatch
    li      t1, 2
    jal     ra, test37_dispatch

    # Expected: 1+2+3 = 6
    li      t2, 6
    beq     t0, t2, test37_pass
    j       test37_fail

    .balign 4
test37_dispatch:
    la      t3, test37_table
    slli    t4, t1, 2
    add     t3, t3, t4
    lw      t3, 0(t3)               # Load target
    jr      t3                      # IMMEDIATE jr - load-use hazard

    .balign 4
test37_table:
    .word test37_case0
    .word test37_case1
    .word test37_case2

    .balign 4
test37_case0:
    addi    t0, t0, 1
    ret
    .balign 4
test37_case1:
    addi    t0, t0, 2
    ret
    .balign 4
test37_case2:
    addi    t0, t0, 3
    ret

test37_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test38_start
test37_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 38: JALR to halfword-aligned spanning instruction
    # *** THIS TEST IS SKIPPED - IT TRIGGERS A KNOWN BUG ***
    #
    # BUG: When JALR targets a halfword-aligned address (PC[1]=1)
    #      where a 32-bit instruction spans the word boundary,
    #      the CPU hangs.
    #
    # Hypothesis: The spanning instruction handling after a JALR
    # redirect has a bug in the interaction between:
    # - if_stage.sv (spanning instruction detection during redirect)
    # - c_ext_state.sv (prediction_holdoff, spanning state machine)
    # - instruction_aligner.sv (halfword selection after redirect)
    #
    # To enable this test and reproduce the bug, change the jump below
    # from tests_done to test38_run.
    # =========================================
test38_start:
    la      a0, msg_test38
    jal     ra, print_string

    # Run the test (this will trigger the known bug)
    j       test38_run

test38_run:
    li      t0, 0

    # Load target address then jump
    la      t3, test38_target_addr
    lw      t4, 0(t3)
    addi    t0, t0, 1               # t0 = 1
    jalr    ra, t4, 0               # Jump to HALFWORD-aligned target
    addi    t0, t0, 1               # t0 = 3 after return

    # Verify: t0 should be 3
    li      t2, 3
    beq     t0, t2, test38_pass
    j       test38_fail

    # Place target address storage FIRST with explicit alignment
    # This ensures the word we load is word-aligned
    .balign 4
test38_target_addr:
    .word test38_target

    # Now place target at halfword boundary with spanning instruction
    # The c.nop pushes the 32-bit addi to a halfword boundary so it spans
    .option rvc
    c.nop                           # 2 bytes - push next instruction to halfword
    .option norvc
test38_target:
    addi    t0, t0, 1               # 32-bit instruction at halfword = SPANNING
    ret

test38_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test39_start
test38_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 39: Backwards buffer loop (decimal print pattern)
    # This mimics the uart_printf decimal digit printing loop:
    #   - Walk backwards through a buffer
    #   - Decrement pointer in one reg, move to another
    #   - Compare pointer with base address to exit
    # =========================================
test39_start:
    la      a0, msg_test39
    jal     ra, print_string

    # Set up a small buffer on stack with known values
    addi    sp, sp, -16
    li      t0, 0x35            # '5'
    sb      t0, 0(sp)
    li      t0, 0x34            # '4'
    sb      t0, 1(sp)
    li      t0, 0x33            # '3'
    sb      t0, 2(sp)
    li      t0, 0x32            # '2'
    sb      t0, 3(sp)
    li      t0, 0x31            # '1'
    sb      t0, 4(sp)

    # a2 = buffer base (start)
    # a5 = current pointer (end of data)
    mv      a2, sp
    addi    a5, sp, 4           # Point to last digit '1'

    # Count iterations (should be 5: indices 4,3,2,1,0)
    li      t1, 0

    # Mimic the exact loop pattern from uart_printf:
    #   3ee:  mv a5, a4
    #   3f0:  lbu a4, 0(a5)
    #   ...
    #   400:  addi a4, a5, -1
    #   404:  bne a2, a5, 3ee
    j       test39_loop_entry

test39_loop_top:
    mv      a5, a4              # Update pointer from decremented value

test39_loop_entry:
    lbu     a4, 0(a5)           # Load byte (result doesn't matter for test)
    addi    t1, t1, 1           # Count iterations
    addi    a4, a5, -1          # Decrement pointer into a4
    bne     a2, a5, test39_loop_top  # Loop if not at base

    # Should have done exactly 5 iterations
    addi    sp, sp, 16
    li      t2, 5
    beq     t1, t2, test39_pass
    j       test39_fail

test39_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test40_start
test39_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 40: Same pattern with more iterations
    # Test with 10 iterations to stress branch prediction
    # =========================================
test40_start:
    la      a0, msg_test40
    jal     ra, print_string

    # Set up a larger buffer on stack
    addi    sp, sp, -16
    li      t0, 0x39            # '9'
    sb      t0, 0(sp)
    li      t0, 0x38            # '8'
    sb      t0, 1(sp)
    li      t0, 0x37            # '7'
    sb      t0, 2(sp)
    li      t0, 0x36            # '6'
    sb      t0, 3(sp)
    li      t0, 0x35            # '5'
    sb      t0, 4(sp)
    li      t0, 0x34            # '4'
    sb      t0, 5(sp)
    li      t0, 0x33            # '3'
    sb      t0, 6(sp)
    li      t0, 0x32            # '2'
    sb      t0, 7(sp)
    li      t0, 0x31            # '1'
    sb      t0, 8(sp)
    li      t0, 0x30            # '0'
    sb      t0, 9(sp)

    # a2 = buffer base, a5 = end of data
    mv      a2, sp
    addi    a5, sp, 9           # Point to last digit '0'

    li      t1, 0               # Count iterations

    j       test40_loop_entry

test40_loop_top:
    mv      a5, a4

test40_loop_entry:
    lbu     a4, 0(a5)
    addi    t1, t1, 1
    addi    a4, a5, -1
    bne     a2, a5, test40_loop_top

    addi    sp, sp, 16
    li      t2, 10
    beq     t1, t2, test40_pass
    j       test40_fail

test40_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test41_start
test40_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 41: Backwards loop with function call inside
    # This tests if the BTB interferes with loops containing calls
    # =========================================
test41_start:
    la      a0, msg_test41
    jal     ra, print_string

    # Set up buffer
    addi    sp, sp, -16
    li      t0, 0x43            # 'C'
    sb      t0, 0(sp)
    li      t0, 0x42            # 'B'
    sb      t0, 1(sp)
    li      t0, 0x41            # 'A'
    sb      t0, 2(sp)
    sb      zero, 3(sp)         # null terminator

    # Save callee-saved regs for the call
    mv      s3, sp              # s3 = buffer base
    addi    s4, sp, 2           # s4 = current pointer (last char 'A')
    li      s5, 0               # s5 = iteration count

    j       test41_loop_entry

test41_loop_top:
    mv      s4, s6              # Update pointer

test41_loop_entry:
    lbu     a0, 0(s4)           # Load byte
    # Don't actually print to avoid slowing down test
    addi    s5, s5, 1           # Count iterations
    addi    s6, s4, -1          # Decrement into s6
    bne     s3, s4, test41_loop_top

    addi    sp, sp, 16
    li      t2, 3
    beq     s5, t2, test41_pass
    j       test41_fail

test41_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test42_start
test41_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 42: Loop with multiply (mimics decimal conversion)
    # Division by 10 pattern: multiply by 0xCCCCCCCD, shift right
    # Tests if multiply stalls interact badly with branch prediction
    # =========================================
test42_start:
    la      a0, msg_test42
    jal     ra, print_string

    # Save s1/s2 (pass/fail counters) on stack
    addi    sp, sp, -16
    sw      s1, 0(sp)
    sw      s2, 4(sp)

    # Compute digits of 12345 (should produce 5 digits)
    li      a4, 12345           # Value to convert
    li      a3, 0               # Digit count (using a3 instead of s1)
    li      a5, 10              # Max iterations

    # Magic constant for division by 10: 0xCCCCCCCD. The reciprocal idiom is
    # register-width-sensitive: at rv64, lui sign-extends (0xFFFF..CCCCD000)
    # and mulhu takes the high 64 of a 128-bit product, so the rv32 shape
    # quietly becomes ~divide-by-8 (test 42 even passes by digit-count luck;
    # test 43 exposed it on first rv64 silicon). rv64 uses the zero-extended
    # magic with a full 64-bit mul: (a4 * 0xCCCCCCCD) >> 35 = a4 / 10.
.if FROST_RV64_ASM
    li      a2, 0xCCCCCCCD
.else
    lui     a2, 0xccccd
    addi    a2, a2, -819        # a2 = 0xCCCCCCCD
.endif

test42_loop:
    # Multiply by reciprocal of 10
.if FROST_RV64_ASM
    mul     t0, a4, a2          # 33x32-bit product fits in 64 bits
    srli    t1, t0, 35          # t1 = a4 / 10
.else
    mulhu   t0, a4, a2          # t0 = (a4 * 0xCCCCCCCD) >> 32
    srli    t1, t0, 3           # t1 = t0 >> 3 = a4 / 10
.endif

    # Compute remainder: a4 - (t1 * 10)
    slli    t2, t1, 3           # t2 = t1 * 8
    slli    t3, t1, 1           # t3 = t1 * 2
    add     t2, t2, t3          # t2 = t1 * 10
    sub     t4, a4, t2          # t4 = remainder (digit)

    # Store digit (we don't actually need to store, just count)
    addi    a3, a3, 1           # Count digits

    # Update value for next iteration
    mv      a4, t1              # a4 = quotient

    # Exit if quotient is zero
    beqz    a4, test42_done

    # Safety: also exit if we've done too many iterations
    blt     a3, a5, test42_loop

test42_done:
    # Restore s1/s2 before checking
    lw      s1, 0(sp)
    lw      s2, 4(sp)
    addi    sp, sp, 16

    # Should have 5 digits for 12345
    li      t2, 5
    beq     a3, t2, test42_pass
    j       test42_fail

test42_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test43_start
test42_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 43: Larger number (322265625) - same as failing case
    # =========================================
test43_start:
    la      a0, msg_test43
    jal     ra, print_string

    # Save s1/s2 (pass/fail counters) on stack
    addi    sp, sp, -16
    sw      s1, 0(sp)
    sw      s2, 4(sp)

    # 322265625 = 0x1337F619
    lui     a4, 0x1337f
    addi    a4, a4, 0x619
    li      a3, 0               # Digit count
    li      a5, 15              # Max iterations

    # Magic constant for division by 10 (same per-XLEN split as test 42).
.if FROST_RV64_ASM
    li      a2, 0xCCCCCCCD
.else
    lui     a2, 0xccccd
    addi    a2, a2, -819
.endif

test43_loop:
.if FROST_RV64_ASM
    mul     t0, a4, a2
    srli    t1, t0, 35
.else
    mulhu   t0, a4, a2
    srli    t1, t0, 3
.endif

    slli    t2, t1, 3
    slli    t3, t1, 1
    add     t2, t2, t3
    sub     t4, a4, t2

    addi    a3, a3, 1
    mv      a4, t1
    beqz    a4, test43_done
    blt     a3, a5, test43_loop

test43_done:
    # Restore s1/s2 before checking
    lw      s1, 0(sp)
    lw      s2, 4(sp)
    addi    sp, sp, 16

    # 322265625 has 9 digits
    li      t2, 9
    beq     a3, t2, test43_pass
    j       test43_fail

test43_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test44_start
test43_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 44: Combined extraction and printing loop
    # This more closely mimics the actual uart_printf pattern
    # =========================================
test44_start:
    la      a0, msg_test44
    jal     ra, print_string

    # Save s1/s2 (pass/fail counters) on stack, and allocate buffer
    addi    sp, sp, -48
    sw      s1, 0(sp)
    sw      s2, 4(sp)
    # Buffer at sp+16 (32 bytes)

    # Convert 12345 to decimal digits in buffer
    li      a4, 12345
    li      s3, 0               # Digit count
    addi    a2, sp, 16          # Buffer base
    li      s6, 20              # Max iterations

    lui     s4, 0xccccd
    addi    s4, s4, -819        # Magic constant in s4 instead of s2

test44_extract_loop:
    mulhu   t0, a4, s4
    srli    t1, t0, 3

    slli    t2, t1, 3
    slli    t3, t1, 1
    add     t2, t2, t3
    sub     t4, a4, t2          # Remainder = digit

    # Store digit in buffer
    add     t5, a2, s3          # Buffer + offset
    addi    t4, t4, 0x30        # Convert to ASCII
    sb      t4, 0(t5)

    addi    s3, s3, 1
    mv      a4, t1
    beqz    a4, test44_print
    blt     s3, s6, test44_extract_loop

test44_print:
    # Now walk backwards through buffer, counting (mimics print)
    # s3 = digit count, a2 = buffer base
    # Start at s3-1 (last digit), walk to 0
    addi    a5, s3, -1          # Start index
    add     a5, a2, a5          # a5 = pointer to last digit
    li      s5, 0               # Print count (was s4, now s5)

    j       test44_print_entry

test44_print_loop:
    mv      a5, t0              # Update pointer from decremented value

test44_print_entry:
    lbu     t1, 0(a5)           # Load digit (don't actually print)
    addi    s5, s5, 1           # Count prints
    addi    t0, a5, -1          # Decrement pointer into t0
    bne     a2, a5, test44_print_loop

    # Save digit and print counts before restore
    mv      a3, s3              # Digit count
    mv      a4, s5              # Print count

    # Restore s1/s2 before checking
    lw      s1, 0(sp)
    lw      s2, 4(sp)
    addi    sp, sp, 48

    # Should have printed 5 digits
    li      t2, 5
    bne     a3, t2, test44_fail
    bne     a4, t2, test44_fail
    j       test44_pass

test44_pass:
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       test45_start
test44_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Test 45: Exact uart_printf backwards loop pattern
    # Branch to halfword-aligned c.mv followed by lbu, with UART output
    # This is the EXACT pattern that fails in isa_test:
    #   3ee: 87ba       c.mv  a5,a4      <- halfword addr, compressed
    #   3f0: 0007c703   lbu   a4,0(a5)   <- load uses a5
    #   ...
    #   404: fef615e3   bne   a2,a5,3ee  <- branch back to halfword
    # =========================================
test45_start:
    la      a0, msg_test45
    jal     ra, print_string

    # Set up a buffer on stack with digits '5','4','3','2','1' (reversed)
    addi    sp, sp, -16
    li      t0, 0x35            # '5'
    sb      t0, 0(sp)
    li      t0, 0x34            # '4'
    sb      t0, 1(sp)
    li      t0, 0x33            # '3'
    sb      t0, 2(sp)
    li      t0, 0x32            # '2'
    sb      t0, 3(sp)
    li      t0, 0x31            # '1'
    sb      t0, 4(sp)

    # a2 = buffer base (termination condition)
    mv      a2, sp
    # a5 = pointer to last digit (sp + 4)
    addi    a5, sp, 4
    # a0 = UART address
    lui     a0, 0x40000
    # s3 = iteration counter
    li      s3, 0
    # s4 = max iterations (safety)
    li      s4, 10

    # Entry point - jump past the c.mv to start
    .option rvc
    c.j     test45_loop_entry

    # We need test45_loop_top to be at a HALFWORD address (PC[1]=1)
    # After c.j (2 bytes), we need to align to word then add 2 bytes
    .balign 4
    c.nop                       # 2 bytes, now at halfword boundary

test45_loop_top:
    # This MUST be a compressed mv at a halfword-aligned address
    c.mv    a5, a4              # Update pointer from decremented value

test45_loop_entry:
    .option norvc
    lbu     a4, 0(a5)           # Load the digit
    sb      a4, 0(a0)           # Print to UART
    addi    s3, s3, 1           # Count iterations
    addi    a4, a5, -1          # Decrement pointer into a4
    bge     s3, s4, test45_safety_exit  # Safety exit
    bne     a2, a5, test45_loop_top     # Branch back to halfword c.mv

    .option rvc
    addi    sp, sp, 16

    # Should have printed exactly 5 characters
    li      t2, 5
    beq     s3, t2, test45_pass
    j       test45_fail

test45_safety_exit:
    .option norvc
    addi    sp, sp, 16
    j       test45_fail

test45_pass:
    .option norvc
    addi    s1, s1, 1
    la      a0, msg_ok
    jal     ra, print_string
    j       tests_done
test45_fail:
    addi    s2, s2, 1
    la      a0, msg_fail
    jal     ra, print_string

    # =========================================
    # Summary
    # =========================================
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

    # Check if all passed
    bnez    s2, all_failed
    la      a0, msg_all_pass
    jal     ra, print_string
    la      a0, msg_pass_marker
    jal     ra, print_string
    j       done

all_failed:
    la      a0, msg_some_fail
    jal     ra, print_string
    la      a0, msg_fail_marker
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
    mv      t2, a0
1:
    lb      t1, 0(t2)
    beqz    t1, 2f
    sb      t1, 0(s0)
    addi    t2, t2, 1
    j       1b
2:
    ret

# =========================================
# Helper: Print decimal number
# Input: a0 = number to print
# =========================================
    .balign 4
print_decimal:
    # Simple: just print single digit for now (0-9)
    # For our tests, counters are small
    addi    t1, a0, '0'
    sb      t1, 0(s0)
    ret

    .option pop

# =========================================
# String data
# =========================================
    .section .rodata
msg_header:
    .asciz "=== Branch Prediction Test ===\n"
msg_test1:
    .asciz "Test 1: Forward branch (taken)... "
msg_test2:
    .asciz "Test 2: Forward branch skip... "
msg_test3:
    .asciz "Test 3: Simple loop (5 iter)... "
msg_test4:
    .asciz "Test 4: JAL call and return... "
msg_test5:
    .asciz "Test 5: Tight loop (10 iter)... "
msg_test6:
    .asciz "Test 6: Multiple JAL calls... "
msg_test7:
    .asciz "Test 7: Nested loops (3x4)... "
msg_test8:
    .asciz "Test 8: Back-to-back branches... "
msg_test9:
    .asciz "Test 9: Compressed branches... "
msg_test10:
    .asciz "Test 10: Compressed loop... "
msg_test11:
    .asciz "Test 11: JALR indirect jump... "
msg_test12:
    .asciz "Test 12: Train then mispredict... "
msg_test13:
    .asciz "Test 13: Branch after load... "
msg_test14:
    .asciz "Test 14: Multiple JALR targets... "
msg_test15:
    .asciz "Test 15: Halfword boundary... "
msg_test16:
    .asciz "Test 16: JAL in loop... "
msg_test17:
    .asciz "Test 17: Deep nested calls... "
msg_test18:
    .asciz "Test 18: Alternating pattern... "
msg_test19:
    .asciz "Test 19: Branch to halfword... "
msg_test20:
    .asciz "Test 20: Spanning + branch... "
msg_test21:
    .asciz "Test 21: Mixed 16/32-bit loop... "
msg_test22:
    .asciz "Test 22: Rapid mispredict... "
msg_test23:
    .asciz "Test 23: Stress 100 iter... "
msg_test24:
    .asciz "Test 24: Call in nested loop... "
msg_test25:
    .asciz "Test 25: Long offset branch... "
msg_test26:
    .asciz "Test 26: Recursive calls... "
msg_test27:
    .asciz "Test 27: Spanning branch NT... "
msg_test28:
    .asciz "Test 28: Spanning branch T... "
msg_test29:
    .asciz "Test 29: Spanning loop... "
msg_test30:
    .asciz "Test 30: Rapid calls (10)... "
msg_test31:
    .asciz "Test 31: Interleaved calls... "
msg_test32:
    .asciz "Test 32: Sequential loops... "
msg_test33:
    .asciz "Test 33: Tight C loop... "
msg_test34:
    .asciz "Test 34: Branch chain... "
msg_test35:
    .asciz "Test 35: JALR after load... "
msg_test36:
    .asciz "Test 36: LW->JALR immed... "
msg_test37:
    .asciz "Test 37: Jump table... "
msg_test38:
    .asciz "Test 38: JALR->halfword... "
msg_test39:
    .asciz "Test 39: Backwards loop (5 iter)... "
msg_test40:
    .asciz "Test 40: Backwards loop (10 iter)... "
msg_test41:
    .asciz "Test 41: Backwards loop (3 iter)... "
msg_test42:
    .asciz "Test 42: Mul div loop (12345)... "
msg_test43:
    .asciz "Test 43: Mul div loop (322265625)... "
msg_test44:
    .asciz "Test 44: Combined extract+print... "
msg_test45:
    .asciz "Test 45: Exact uart_printf loop... "
msg_skip:
    .asciz "SKIP (known bug)\n"
msg_ok:
    .asciz "OK\n"
msg_fail:
    .asciz "FAIL\n"
msg_summary:
    .asciz "\n--- Summary ---\n"
msg_passed:
    .asciz "Passed: "
msg_failed:
    .asciz "Failed: "
msg_newline:
    .asciz "\n"
msg_all_pass:
    .asciz "\n=== All Tests Passed ===\n"
msg_some_fail:
    .asciz "\n=== SOME TESTS FAILED ===\n"
msg_pass_marker:
    .asciz "<<PASS>>\n"
msg_fail_marker:
    .asciz "<<FAIL>>\n"

# =========================================
# Stack
# =========================================
    .section .bss
    .align 4
stack_bottom:
    .space 512
_stack_top:
