/*
 *    Copyright 2026 Two Sigma Open Source, LLC
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

# Compressed FP (C.F/C.D) Extension Test
#
# Tests:
#   1. C.FLW / C.FSW using compressed registers (f8-f15, x8-x15 base)
#   2. C.FLWSP / C.FSWSP using stack-pointer base
#   3. C.FLD / C.FSD using compressed registers (f8-f15, x8-x15 base)
#   4. C.FLDSP / C.FSDSP using stack-pointer base
#
# Prints <<PASS>> on success.

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

    # Load data base into s1 (x9, compressed register)
    la      s1, data_base
    # Initialize scratch data (no crt0 copy for .data in this test)
    li      t0, 0x00000001
    sw      t0, 0(s1)
    sw      x0, 4(s1)

    # Print header
    la      a0, msg_header
    jal     ra, print_string

    # =========================================
    # Test 1: C.FLW / C.FSW (compressed regs)
    # =========================================
    la      a0, msg_test1
    jal     ra, print_string
    .option rvc
    c.flw   fs0, 0(s1)       # f8 from [s1 + 0]
    c.fsw   fs0, 4(s1)       # store to [s1 + 4]
    .option norvc
    lw      t0, 4(s1)
    li      t1, 0x00000001
    bne     t0, t1, fail_test1
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 2: C.FLWSP / C.FSWSP (sp base)
    # =========================================
    la      a0, msg_test2
    jal     ra, print_string
    addi    sp, sp, -16
    li      t0, 0x00000001
    sw      t0, 0(sp)
    .option rvc
    c.flwsp fs1, 0(sp)       # f9 from [sp + 0]
    c.fswsp fs1, 4(sp)       # store to [sp + 4]
    .option norvc
    lw      t1, 4(sp)
    addi    sp, sp, 16
    bne     t1, t0, fail_test2
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 3: C.FLD / C.FSD (compressed regs)
    # =========================================
    la      a0, msg_test3
    jal     ra, print_string
    # Initialize 64-bit pattern at data_base + 8
    li      t0, 0x89ABCDEF
    sw      t0, 8(s1)        # low word
    li      t1, 0x01234567
    sw      t1, 12(s1)       # high word
    .option rvc
    c.fld   fs0, 8(s1)       # f8 from [s1 + 8]
    c.fsd   fs0, 16(s1)      # store to [s1 + 16]
    .option norvc
    lw      t2, 16(s1)
    lw      t3, 20(s1)
    li      t4, 0x89ABCDEF
    bne     t2, t4, fail_test3
    li      t5, 0x01234567
    bne     t3, t5, fail_test3
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # Test 4: C.FLDSP / C.FSDSP (sp base)
    # =========================================
    la      a0, msg_test4
    jal     ra, print_string
    addi    sp, sp, -32
    li      t0, 0xA5A5A5A5
    sw      t0, 0(sp)        # low word
    li      t1, 0x5A5A5A5A
    sw      t1, 4(sp)        # high word
    .option rvc
    c.fldsp fs1, 0(sp)       # f9 from [sp + 0]
    c.fsdsp fs1, 8(sp)       # store to [sp + 8]
    .option norvc
    lw      t2, 8(sp)
    lw      t3, 12(sp)
    addi    sp, sp, 32
    li      t4, 0xA5A5A5A5
    bne     t2, t4, fail_test4
    li      t5, 0x5A5A5A5A
    bne     t3, t5, fail_test4
    la      a0, msg_ok
    jal     ra, print_string

    # =========================================
    # All tests passed
    # =========================================
    la      a0, msg_pass
    jal     ra, print_string
    la      a0, msg_marker
    jal     ra, print_string

done:
    .option rvc
    c.j     done

fail_test1:
    .option norvc
    la      a0, msg_fail1
    jal     ra, print_string
    j       done

fail_test2:
    la      a0, msg_fail2
    jal     ra, print_string
    j       done

fail_test3:
    la      a0, msg_fail3
    jal     ra, print_string
    j       done

fail_test4:
    la      a0, msg_fail4
    jal     ra, print_string
    j       done

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
    .asciz "=== C.F Extension Test ===\n"
msg_test1:
    .asciz "Test 1: C.FLW/C.FSW... "
msg_test2:
    .asciz "Test 2: C.FLWSP/C.FSWSP... "
msg_test3:
    .asciz "Test 3: C.FLD/C.FSD... "
msg_test4:
    .asciz "Test 4: C.FLDSP/C.FSDSP... "
msg_ok:
    .asciz "OK\n"
msg_fail1:
    .asciz "FAIL (C.FLW/C.FSW)\n"
msg_fail2:
    .asciz "FAIL (C.FLWSP/C.FSWSP)\n"
msg_fail3:
    .asciz "FAIL (C.FLD/C.FSD)\n"
msg_fail4:
    .asciz "FAIL (C.FLDSP/C.FSDSP)\n"
msg_pass:
    .asciz "\n=== All Tests Passed ===\n"
msg_marker:
    .asciz "<<PASS>>\n"

# =========================================
# Test data
# =========================================
    .section .bss
    .align 4
data_base:
    .space 24

# =========================================
# Stack
# =========================================
    .section .bss
    .align 4
stack_bottom:
    .space 512
_stack_top:
