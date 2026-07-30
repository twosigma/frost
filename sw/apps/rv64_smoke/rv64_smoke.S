# RV64 smoke test (Phase 1 milestone M2 — docs/rv64/phase1_plan.md)
#
# The smallest end-to-end rv64 program: proves the M2-minimum decode/ALU/
# load-unit slice retires real 64-bit results through the OoO core and the
# M1 data tier. Built -march=rv64i (no compressed code — the C-table recode
# is M4; no M/A/F — those land in M3).
#
# Coverage, each self-checked against constants built from independent ops:
#   1. LUI/ADDIW sign semantics (sext32 results, 0x7FFFFFFF+1 wrap)
#   2. ADDW/SUBW 32-bit wrap + sign extension
#   3. 64-bit base shifts with 6-bit shamts (slli/srli/srai by 32..63)
#   4. SLLIW/SRLIW/SRAIW (5-bit shamts, sext32 results)
#   5. SLLW/SRLW/SRAW (register shamt masks to [4:0])
#   6. 64-bit ADD carries across bit 31 (no 32-bit wrap in the base ALU)
#   7. SD/LD round trip through the 64-bit data tier
#   8. LW sign-extension vs LWU zero-extension from a stored dword
#   9. LBU/LHU byte/half extraction across the beat's addr[2] boundary
#
# Register discipline: print_string clobbers t1/t2 (t1 exits holding the NUL
# terminator!), so values that must survive a print live in s-registers:
#   s0 = UART base            s4 = 0xFFFFFFFF_80000000 (sext 0x80000000)
#   s3 = SD/LD test pattern   s5 = 0x00000000_7FFFFFFF
# t-registers never carry state across a print call.

    .section .init
    .option push
    .option norelax
    .globl _start

_start:
    # No stack: everything runs in registers + one .data dword buffer.

    # UART base for print_string
    lui     s0, 0x40000

    # Shared reference constants (never clobbered)
    lui     s4, 0x80000         # rv64: sext -> 0xFFFFFFFF_80000000
    addiw   s5, s4, -1          # sext32(0x7FFFFFFF) = 0x00000000_7FFFFFFF

    la      a0, msg_header
    jal     ra, print_string

    # =========================================================
    # Test 1: LUI sign-extension + ADDIW wrap semantics
    # =========================================================
    srai    t2, s5, 62          # 0x7FFF... >> 62 (arith) = 0 (positive)
    bnez    t2, fail
    srai    t2, s4, 63          # sign bit replicates: -1
    li      t3, -1
    bne     t2, t3, fail
    addiw   t2, s5, 1           # sext32(0x80000000) = s4
    bne     t2, s4, fail
    la      a0, msg_ok1
    jal     ra, print_string

    # =========================================================
    # Test 2: ADDW/SUBW wrap + sign extension
    # =========================================================
    addw    t3, s5, s5          # sext32(0xFFFFFFFE) = -2
    li      t4, -2
    bne     t3, t4, fail
    subw    t3, x0, s4          # sext32(0 - 0x80000000) = sext32(0x80000000) = s4
    bne     t3, s4, fail
    la      a0, msg_ok2
    jal     ra, print_string

    # =========================================================
    # Test 3: 64-bit base shifts with shamt >= 32
    # =========================================================
    li      t3, 1
    slli    t3, t3, 63          # 0x8000000000000000
    srai    t4, t3, 63          # arithmetic: all ones
    li      t5, -1
    bne     t4, t5, fail
    srli    t4, t3, 63          # logical: 1
    li      t5, 1
    bne     t4, t5, fail
    li      t3, 1
    slli    t3, t3, 32          # 0x1_00000000
    addi    t3, t3, -1          # 0x0_FFFFFFFF
    srli    t4, t3, 32          # 0
    bnez    t4, fail
    la      a0, msg_ok3
    jal     ra, print_string

    # =========================================================
    # Test 4: W-form immediate shifts (sext32 results)
    # =========================================================
    li      t3, 1
    slliw   t4, t3, 31          # sext32(0x80000000) = s4
    bne     t4, s4, fail
    sraiw   t5, t4, 31          # sext32(0xFFFFFFFF) = -1
    li      t6, -1
    bne     t5, t6, fail
    srliw   t5, t4, 31          # sext32(0x00000001) = 1
    li      t6, 1
    bne     t5, t6, fail
    la      a0, msg_ok4
    jal     ra, print_string

    # =========================================================
    # Test 5: W-form register shifts (shamt masks to [4:0])
    # =========================================================
    li      t3, 1
    li      t6, 63              # W shifts read rs2[4:0] -> 31
    sllw    t4, t3, t6          # sext32(1 << 31) = s4
    bne     t4, s4, fail
    sraw    t5, t4, t6          # sext32(0x80000000 >>> 31) = -1
    li      t3, -1
    bne     t5, t3, fail
    srlw    t5, t4, t6          # sext32(1) = 1
    li      t3, 1
    bne     t5, t3, fail
    la      a0, msg_ok5
    jal     ra, print_string

    # =========================================================
    # Test 6: 64-bit ADD carries across bit 31
    # =========================================================
    li      t3, 1
    slli    t3, t3, 32
    addi    t3, t3, -1          # 0x0_FFFFFFFF
    addi    t4, t3, 1           # 0x1_00000000 (would be 0 on rv32)
    srli    t5, t4, 32
    li      t6, 1
    bne     t5, t6, fail
    la      a0, msg_ok6
    jal     ra, print_string

    # =========================================================
    # Test 7: SD/LD round trip (pattern 0xDEADBEEF_CAFEF00D)
    # =========================================================
    lui     t3, 0xDEADC
    addiw   t3, t3, -273        # sext32(0xDEADBEEF)
    slli    t3, t3, 32          # 0xDEADBEEF_00000000
    lui     t4, 0xCAFEF
    addiw   t4, t4, 0x00D       # sext32(0xCAFEF00D) = 0xFFFFFFFF_CAFEF00D
    slli    t4, t4, 32
    srli    t4, t4, 32          # 0x00000000_CAFEF00D
    or      s3, t3, t4          # s3 = the pattern (survives prints)
    la      a1, buf
    sd      s3, 0(a1)
    ld      t5, 0(a1)
    bne     t5, s3, fail
    la      a0, msg_ok7
    jal     ra, print_string

    # =========================================================
    # Test 8: LW sign-extends, LWU zero-extends
    # =========================================================
    la      a1, buf
    lw      t5, 0(a1)           # sext32(0xCAFEF00D) = 0xFFFFFFFF_CAFEF00D
    lui     t6, 0xCAFEF
    addiw   t6, t6, 0x00D
    bne     t5, t6, fail
    lwu     t5, 0(a1)           # 0x00000000_CAFEF00D
    slli    t6, t6, 32
    srli    t6, t6, 32
    bne     t5, t6, fail
    lw      t5, 4(a1)           # sext32(0xDEADBEEF)
    lui     t6, 0xDEADC
    addiw   t6, t6, -273
    bne     t5, t6, fail
    la      a0, msg_ok8
    jal     ra, print_string

    # =========================================================
    # Test 9: sub-word extraction across the beat boundary
    # =========================================================
    la      a1, buf
    lbu     t5, 5(a1)           # byte 5 of the pattern = 0xBE
    srli    t6, s3, 40
    andi    t6, t6, 0xFF
    bne     t5, t6, fail
    lhu     t5, 6(a1)           # half 3 of the pattern = 0xDEAD
    srli    t6, s3, 48
    bne     t5, t6, fail
    lb      t5, 3(a1)           # sext8(0xCA) = -54
    li      t6, -54
    bne     t5, t6, fail
    la      a0, msg_ok9
    jal     ra, print_string

    # All tests passed
    la      a0, msg_pass
    jal     ra, print_string
    j       done

fail:
    la      a0, msg_fail
    jal     ra, print_string

done:
    j       done

# --- UART print helper (byte stores to the UART TX register) ---------------
# Clobbers t1 (exits holding the NUL terminator = 0) and t2.
print_string:
    mv      t2, a0
1:  lb      t1, 0(t2)
    beqz    t1, 2f
    sb      t1, 0(s0)
    addi    t2, t2, 1
    j       1b
2:  ret

msg_header:
    .asciz "RV64 smoke: "
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
msg_ok9:
    .asciz "ok9 "
msg_pass:
    .asciz "<<PASS>>\n"
msg_fail:
    .asciz "<<FAIL>>\n"

    .option pop

    .section .data
    .align  3
buf:
    .dword  0
