# C Extension (Compressed Instructions) Test
#
# Tests function calls and returns using both 32-bit and 16-bit compressed
# instructions to verify correct PC handling and instruction decompression.
#
# RV64C reinterprets several RV32C encodings: C.JAL's slot becomes
# C.ADDIW, and C.FLW/C.FSW (+SP forms) become C.LD/C.SD (+SP forms), with
# C.SUBW/C.ADDW joining — exactly the RV64C decompressor surface. The
# reinterpreted encodings get value self-checks (a wrong result prints
# <<FAIL>> and halts) plus the C.JALR/C.J flow tests.
#
# Tests:
#   1. 32-bit JAL to function
#   2. C.ADDIW (sext32 add check)
#   3. Nested calls, mixed sizes
#   4. C.LD/C.SD + C.LDSP/C.SDSP roundtrip
#   5. C.JALR (indirect call)
#   6. C.SUBW/C.ADDW (sext32 arith checks)

    .section .init
    .option push
    .option norelax
    .globl _start

_start:
    .option norvc           # Force 32-bit for setup

    # Initialize stack pointer
    la      sp, _stack_top

    # Load UART address into s0 (callee-saved, persists across calls)
    lui     s0, 0x40000

    # Print header
    la      a0, msg_header
    jal     ra, print_string

    # =========================================
    # Test 1: Basic 32-bit JAL
    # =========================================
    la      a0, msg_test1
    jal     ra, print_string
    jal     ra, simple_func     # 32-bit JAL
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 2 (rv64): C.ADDIW — the C.JAL encoding slot
    # =========================================
    la      a0, msg_test2
    jal     ra, print_string
    li      a1, 0x7fffffff      # +imm wraps into the sign bit
    .option rvc
    c.addiw a1, 1               # sext32(0x7fffffff + 1) = 0xffffffff80000000
    .option norvc
    li      a2, -0x80000000     # sign-extended 64-bit expectation
    bne     a1, a2, test_fail
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 3 (rv64): Nested calls with mixed sizes
    # =========================================
    la      a0, msg_test3
    jal     ra, print_string
    jal     ra, nested_func
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 4 (rv64): C.LD/C.SD and C.LDSP/C.SDSP roundtrip
    # =========================================
    la      a0, msg_test4
    jal     ra, print_string
    la      a1, scratch64       # a1 -> x8-15 range reg for C.LD/C.SD (a1=x11)
    li      a2, 0xdeadbeefcafe0123
    .option rvc
    c.sd    a2, 0(a1)           # compressed store double
    c.ld    a3, 0(a1)           # compressed load double
    .option norvc
    bne     a3, a2, test_fail
    addi    sp, sp, -16
    li      a4, 0x0123456789abcdef
    .option rvc
    c.sdsp  a4, 8(sp)           # stack-pointer-relative compressed store
    c.ldsp  a5, 8(sp)           # stack-pointer-relative compressed load
    .option norvc
    addi    sp, sp, 16
    bne     a5, a4, test_fail
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 5 (rv64): C.JALR (compressed indirect)
    # =========================================
    la      a0, msg_test5
    jal     ra, print_string
    la      a1, simple_func     # Load function address
    .option rvc
    c.jalr  a1                  # Compressed indirect call
    .option norvc
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 6 (rv64): C.SUBW / C.ADDW
    # =========================================
    la      a0, msg_test6
    jal     ra, print_string
    li      a1, 0x100000001     # high bits must be ignored by the W ops
    li      a2, 2
    .option rvc
    c.addw  a1, a2              # sext32(1 + 2) = 3
    .option norvc
    li      a3, 3
    bne     a1, a3, test_fail
    li      a1, 0x200000000     # low word 0
    li      a2, 1
    .option rvc
    c.subw  a1, a2              # sext32(0 - 1) = -1 (all-ones)
    .option norvc
    li      a3, -1
    bne     a1, a3, test_fail
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # All tests passed
    # =========================================
    la      a0, msg_pass
    jal     ra, print_string
    la      a0, msg_marker
    jal     ra, print_string

    .option rvc
done:
    c.j     done
    .option norvc

# =========================================
# Failure sink: print <<FAIL>> and halt
# =========================================
    .balign 4
test_fail:
    la      a0, msg_fail
    jal     ra, print_string
fail_loop:
    j       fail_loop

# =========================================
# Helper: Print null-terminated string
# Input: a0 = pointer to string
# =========================================
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

# =========================================
# Simple function (just returns)
# =========================================
    .balign 4
simple_func:
    .option rvc
    c.jr    ra
    .option norvc

# =========================================
# Nested function (calls simple_func twice; both calls are plain
# 32-bit JALs — C.JAL does not exist at rv64)
# =========================================
    .balign 4
nested_func:
    addi    sp, sp, -16
    sd      ra, 8(sp)

    # Call with 32-bit JAL
    jal     ra, simple_func

    jal     ra, simple_func

    ld      ra, 8(sp)
    addi    sp, sp, 16
    .option rvc
    c.jr    ra
    .option norvc

    .option pop

# =========================================
# String data
# =========================================
    .section .rodata
msg_header:
    .asciz "=== C Extension Test ===\n"
msg_test1:
    .asciz "Test 1: 32-bit JAL... "
msg_test2:
    .asciz "Test 2: C.ADDIW... "
msg_test3:
    .asciz "Test 3: Nested calls... "
msg_test4:
    .asciz "Test 4: C.LD/C.SD (+SP)... "
msg_test5:
    .asciz "Test 5: C.JALR... "
msg_test6:
    .asciz "Test 6: C.SUBW/C.ADDW... "
msg_ok:
    .asciz "OK\n"
msg_pass:
    .asciz "\n=== All Tests Passed ===\n"
msg_fail:
    .asciz "\n<<FAIL>>\n"
msg_marker:
    .asciz "<<PASS>>\n"

# =========================================
# Scratch + stack
# =========================================
    .section .data
    .align 3
scratch64:
    .dword 0

    .section .bss
    .align 4
stack_bottom:
    .space 512
_stack_top:
