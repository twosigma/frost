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

# Compressed Double-Precision FP (Zcd) Extension Test
#
# Zcf (C.FLW/C.FSW and the SP forms) is rv32-only. At rv64 those encodings
# are C.LD/C.SD (+SP forms), which c_ext_test covers, so there is nothing
# left for Zcf here and this app tests only Zcd. The old Zcf subtests 1 and
# 2 are gone. The remaining Zcd subtests keep their original numbering:
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

    la      sp, _stack_top

    # UART base in s0: callee-saved, so it survives the calls below.
    lui     s0, 0x40000

    # Data base in s1 = x9, inside the register range the compressed
    # loads and stores can encode.
    la      s1, data_base
    # Seed the scratch words: data_base is in .bss and nothing zeroes it here.
    li      t0, 0x00000001
    sw      t0, 0(s1)
    sw      x0, 4(s1)

    la      a0, msg_header
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
    # lw sign-extends at rv64; the compare constant must match (bit 31 set).
    li      t4, 0xFFFFFFFF89ABCDEF
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
    # lw sign-extends at rv64; the compare constant must match (bit 31 set).
    li      t4, 0xFFFFFFFFA5A5A5A5
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

fail_test3:
    .option norvc
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
msg_test3:
    .asciz "Test 3: C.FLD/C.FSD... "
msg_test4:
    .asciz "Test 4: C.FLDSP/C.FSDSP... "
msg_ok:
    .asciz "OK\n"
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
