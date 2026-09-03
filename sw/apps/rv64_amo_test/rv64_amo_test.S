# RV64 A-extension directed test (Phase 1 plan M6)
#
# Exercises the doubleword atomics end-to-end through the OoO core's AMO
# path. rv64_smoke's M2-minimum slice has no A at all, and the arch and
# riscv-tests suites cover the ops one at a time. Each test here checks both
# the returned old value and the resulting memory word, with full-64-bit
# patterns chosen so any 32-bit datapath truncation or W-style
# sign-extension in the AMO ALU shows up.
#
# Coverage:
#   1. AMOSWAP.D: old value returned, new value stored
#   2. AMOADD.D: carry propagates across bit 31, so it is not a W add
#   3. AMOAND.D / AMOOR.D / AMOXOR.D: bit patterns across all 64 bits
#   4. AMOMIN.D / AMOMAX.D: signed compares with 64-bit negatives
#   5. AMOMINU.D / AMOMAXU.D: unsigned compares with top-bit-set operands
#   6. LR.D / SC.D success pair: SC writes and returns 0
#   7. SC.D without a reservation: fails with a nonzero rc, memory intact
#   8. AMOADD.W on a dword cell: returns sext32(old low word) and leaves
#      the upper word untouched, since word AMOs are 32-bit windows at rv64
#
# print_string clobbers t1/t2, so values that must survive a print live in
# s-registers: s0 = UART base, s1 = &amo_cell.

    .section .init
    .option push
    .option norelax
    .globl _start

_start:
    # UART base for print_string
    lui     s0, 0x40000

    la      a0, msg_header
    jal     ra, print_string

    la      s1, amo_cell

    # =========================================================
    # Test 1: AMOSWAP.D returns old, stores new
    # =========================================================
    li      t3, 0x1122334455667788
    sd      t3, 0(s1)
    li      t4, 0x99aabbccddeeff00
    amoswap.d t5, t4, (s1)
    li      t6, 0x1122334455667788
    bne     t5, t6, fail        # old value returned
    ld      t5, 0(s1)
    bne     t5, t4, fail        # new value stored
    la      a0, msg_ok1
    jal     ra, print_string

    # =========================================================
    # Test 2: AMOADD.D, 64-bit carry across bit 31
    # =========================================================
    li      t3, 0x00000000FFFFFFFF
    sd      t3, 0(s1)
    li      t4, 1
    amoadd.d t5, t4, (s1)
    bne     t5, t3, fail        # old value
    ld      t5, 0(s1)
    li      t6, 0x0000000100000000  # a W add would sext32-wrap to 0
    bne     t5, t6, fail
    la      a0, msg_ok2
    jal     ra, print_string

    # =========================================================
    # Test 3: AMOAND.D / AMOOR.D / AMOXOR.D across all 64 bits
    # =========================================================
    li      t3, 0xF0F0F0F0F0F0F0F0
    sd      t3, 0(s1)
    li      t4, 0xFF00FF00FF00FF00
    amoand.d t5, t4, (s1)
    bne     t5, t3, fail
    ld      t5, 0(s1)
    li      t6, 0xF000F000F000F000
    bne     t5, t6, fail
    li      t4, 0x0F0F0F0F0F0F0F0F
    amoor.d t5, t4, (s1)
    bne     t5, t6, fail
    ld      t5, 0(s1)
    li      t6, 0xFF0FFF0FFF0FFF0F
    bne     t5, t6, fail
    li      t4, -1
    amoxor.d t5, t4, (s1)
    bne     t5, t6, fail
    ld      t5, 0(s1)
    li      t6, 0x00F000F000F000F0
    bne     t5, t6, fail
    la      a0, msg_ok3
    jal     ra, print_string

    # =========================================================
    # Test 4: AMOMIN.D / AMOMAX.D, signed compares with 64-bit negatives
    # =========================================================
    li      t3, -5              # 0xFFFF...FFFB
    sd      t3, 0(s1)
    li      t4, 3
    amomin.d t5, t4, (s1)       # min(-5, 3) = -5 stays
    bne     t5, t3, fail
    ld      t5, 0(s1)
    bne     t5, t3, fail
    amomax.d t5, t4, (s1)       # max(-5, 3) = 3 stored
    bne     t5, t3, fail        # old = -5
    ld      t5, 0(s1)
    bne     t5, t4, fail
    la      a0, msg_ok4
    jal     ra, print_string

    # =========================================================
    # Test 5: AMOMINU.D / AMOMAXU.D, unsigned with the top bit set
    # =========================================================
    li      t3, 0x8000000000000001  # huge unsigned
    sd      t3, 0(s1)
    li      t4, 7
    amominu.d t5, t4, (s1)      # unsigned min = 7 stored
    bne     t5, t3, fail
    ld      t5, 0(s1)
    bne     t5, t4, fail
    li      t4, 0xFFFFFFFF00000000
    amomaxu.d t5, t4, (s1)      # unsigned max = 0xFFFF...0000 stored
    li      t6, 7
    bne     t5, t6, fail
    ld      t5, 0(s1)
    bne     t5, t4, fail
    la      a0, msg_ok5
    jal     ra, print_string

    # =========================================================
    # Test 6: LR.D / SC.D success pair
    # =========================================================
    li      t3, 0x5A5A5A5A5A5A5A5A
    sd      t3, 0(s1)
    lr.d    t5, (s1)
    bne     t5, t3, fail
    li      t4, 0xA5A5A5A5A5A5A5A5
    sc.d    t6, t4, (s1)
    bnez    t6, fail            # success -> rc 0
    ld      t5, 0(s1)
    bne     t5, t4, fail
    la      a0, msg_ok6
    jal     ra, print_string

    # =========================================================
    # Test 7: SC.D without a reservation must fail
    # =========================================================
    li      t3, 0x0123456789ABCDEF
    sd      t3, 0(s1)
    li      t4, 0xDEADDEADDEADDEAD
    sc.d    t6, t4, (s1)        # no LR before this
    beqz    t6, fail            # must report failure
    ld      t5, 0(s1)
    bne     t5, t3, fail        # memory untouched
    la      a0, msg_ok7
    jal     ra, print_string

    # =========================================================
    # Test 8: AMOADD.W window semantics on a dword cell
    # =========================================================
    li      t3, 0x11111111FFFFFFFF
    sd      t3, 0(s1)
    li      t4, 1
    amoadd.w t5, t4, (s1)       # old low word 0xFFFFFFFF -> sext32 = -1
    li      t6, -1
    bne     t5, t6, fail
    ld      t5, 0(s1)
    li      t6, 0x1111111100000000  # low word wrapped, high word untouched
    bne     t5, t6, fail
    la      a0, msg_ok8
    jal     ra, print_string

    # =========================================================
    # All tests passed
    # =========================================================
    la      a0, msg_pass
    jal     ra, print_string
done:
    j       done

fail:
    la      a0, msg_fail
    jal     ra, print_string
fail_loop:
    j       fail_loop

# =========================================================
# Helper: print NUL-terminated string (clobbers t1/t2)
# =========================================================
print_string:
    mv      t2, a0
1:  lb      t1, 0(t2)
    beqz    t1, 2f
    sb      t1, 0(s0)
    addi    t2, t2, 1
    j       1b
2:  ret

    .option pop

    .section .rodata
msg_header:
    .asciz "RV64 AMO: "
msg_ok1:
    .asciz "ok1 "
msg_ok2:
    .asciz "ok2 "
msg_ok3:
    .asciz "ok3 "
msg_ok4:
    .asciz "ok4 "
msg_ok5:
    .asciz "ok5 "
msg_ok6:
    .asciz "ok6 "
msg_ok7:
    .asciz "ok7 "
msg_ok8:
    .asciz "ok8 "
msg_pass:
    .asciz "\n<<PASS>>\n"
msg_fail:
    .asciz "\n<<FAIL>>\n"

    .section .data
    .align 3
amo_cell:
    .dword 0
