# Reproduce a skipped fall-through fetch window after a trained-taken loop
# exits. Skipping the aligned 8-byte restore window leaves stale s0/s1 while
# the next window pops the frame and returns.
#
# The caller seeds s0/s1 with canaries. Each victim saves them, poisons the
# registers, and restores them in one fetch window. A skipped restore prints
# <<WINDOW-SKIP>> and <<FAIL>>; all successful restores produce <<PASS>>.
#
# Each subtest sweeps exit iteration N over 8..64. The victims use compressed
# doubleword saves and restores with 32-byte frames. A through F use an 8-byte
# array stride. G walks 16-bit prev entries and uses Zba and Zbb to follow the
# zlib longest_match reload tail (coremark_pro_zip).

    .section .init
    .option push
    .option norelax
    .option norvc
    .globl _start

    .equ GOOD_S0, 0x000600D0
    .equ GOOD_S1, 0x000600D1
    .equ V1_CALLS, 1200            # Calls per subtest A/B.
    .equ DIV_CALLS, 400            # C: limit calls because divides serialize.
    .equ V2_CALLS, 800             # Calls per subtest D/E/F/G.
    .equ DDR_BLOCKS, 8             # 8 * 1024 B = 8 KiB swept for subtest B

# ---------------------------------------------------------------------------
# SHIM: seed s0/s1, call the victim at s2, and check the restored canaries.
# \@ makes the local labels unique per expansion.
# ---------------------------------------------------------------------------
    .macro SHIM
    li      s0, GOOD_S0
    li      s1, GOOD_S1
    jalr    ra, s2, 0
    li      t0, GOOD_S0
    bne     s0, t0, .Lfail_s0\@
    li      t0, GOOD_S1
    bne     s1, t0, .Lfail_s1\@
    j       .Lok\@
.Lfail_s0\@:
    mv      s9, s0                 # stale value
    li      s10, '0'
    j       report_fail
.Lfail_s1\@:
    mv      s9, s1
    li      s10, '1'
    j       report_fail
.Lok\@:
    .endm

# ---------------------------------------------------------------------------
# Driver state lives in s2..s11. Victims restore the s-registers they write;
# print helpers use only a and t registers.
#     s2 = current victim fn ptr   s3 = call index   s4 = calls this subtest
#     s5 = BRAM array base         s6 = DDR array base (0x80100000)
#     s7 = subtest char            s9 = stale value    s10 = failing-reg char
# ---------------------------------------------------------------------------
_start:
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)

    la      a0, msg_header
    jal     ra, print_string

    # ---- fill the BRAM array: array[k] = k, k = 0..127 ----
    la      s5, bram_array
    mv      t3, s5
    li      t0, 0
    li      t2, 128
1:
    sd      t0, 0(t3)
    addi    t3, t3, 8
    addi    t0, t0, 1
    blt     t0, t2, 1b

    # ---- fill the DDR array @0x80100000: ascending-mod-128 over 8 KiB ----
    li      s6, 0x801
    slli    s6, s6, 20             # s6 = 0x80100000 (no lui sign extension)
    mv      t3, s6
    li      t0, 0
    li      t4, 0
    li      t5, 8192
2:
    andi    t2, t0, 127
    sd      t2, 0(t3)
    addi    t3, t3, 8
    addi    t4, t4, 8
    addi    t0, t0, 1
    blt     t4, t5, 2b

    # ---- Fill prev_array[k] = k-1 (u16) for victim_real's hash chain. ----
    la      t3, prev_array
    li      t0, 0
    li      t2, 128
3:
    addi    t4, t0, -1
    sh      t4, 0(t3)
    addi    t3, t3, 2
    addi    t0, t0, 1
    blt     t0, t2, 3b

    # ================= Subtest A: BRAM array (fast loads) =================
    li      s4, V1_CALLS
    la      s2, victim
    li      s7, 'A'
    li      s3, 0
subA_loop:
    li      t1, 57
    remu    t2, s3, t1
    addi    a0, t2, 8              # N = 8 + (i mod 57) in [8,64]
    mv      a1, s5
    SHIM
    addi    s3, s3, 1
    blt     s3, s4, subA_loop

    # ============ Subtest B: DDR array (load-latency delayed) =============
    la      s2, victim
    li      s7, 'B'
    li      s3, 0
subB_loop:
    li      t1, 57
    remu    t2, s3, t1
    addi    a0, t2, 8
    andi    t2, s3, (DDR_BLOCKS - 1)
    slli    t2, t2, 10
    add     a1, s6, t2
    SHIM
    addi    s3, s3, 1
    blt     s3, s4, subB_loop

    # ============ Subtest C: BRAM array + divu backpressure ===============
    li      s4, DIV_CALLS
    la      s2, victim_div
    li      s7, 'C'
    li      s3, 0
subC_loop:
    li      t1, 57
    remu    t2, s3, t1
    addi    a0, t2, 8
    mv      a1, s5
    SHIM
    addi    s3, s3, 1
    blt     s3, s4, subC_loop

    # ========= Subtest D: loop-back target at window+4 (victim_t4) ========
    li      s4, V2_CALLS
    la      s2, victim_t4
    li      s7, 'D'
    li      s3, 0
subD_loop:
    li      t1, 57
    remu    t2, s3, t1
    addi    a0, t2, 8
    mv      a1, s5
    SHIM
    addi    s3, s3, 1
    blt     s3, s4, subD_loop

    # ===== Subtest E: loop-back target at window+2, rvc head (victim_t2) ===
    la      s2, victim_t2
    li      s7, 'E'
    li      s3, 0
subE_loop:
    li      t1, 57
    remu    t2, s3, t1
    addi    a0, t2, 8
    mv      a1, s5
    SHIM
    addi    s3, s3, 1
    blt     s3, s4, subE_loop

    # ===== Subtest F: spanning 32-bit op crossing a window (victim_span) ===
    la      s2, victim_span
    li      s7, 'F'
    li      s3, 0
subF_loop:
    li      t1, 57
    remu    t2, s3, t1
    addi    a0, t2, 8
    mv      a1, s5
    SHIM
    addi    s3, s3, 1
    blt     s3, s4, subF_loop

    # ========= Subtest G: longest_match reload tail (victim_real) ========
    la      s2, victim_real
    li      s7, 'G'
    li      s3, 0
subG_loop:
    li      t1, 57
    remu    t2, s3, t1
    addi    a0, t2, 8              # N = exit iteration; victim sets chain start
    mv      a1, s5                 # (ignored by victim_real; kept for shape)
    SHIM
    addi    s3, s3, 1
    blt     s3, s4, subG_loop

    la      a0, msg_pass
    jal     ra, print_string
done:
    j       done

# ---------------------------------------------------------------------------
# report_fail: a <<WINDOW-SKIP>> line, then <<FAIL>> (the harness stops on
# the marker).
# ---------------------------------------------------------------------------
report_fail:
    la      a0, msg_ws
    jal     ra, print_string
    la      a0, msg_sub
    jal     ra, print_string
    mv      a0, s7
    jal     ra, print_char
    la      a0, msg_reg
    jal     ra, print_string
    mv      a0, s10
    jal     ra, print_char
    la      a0, msg_iter
    jal     ra, print_string
    mv      a0, s3
    jal     ra, print_hex
    la      a0, msg_got
    jal     ra, print_string
    mv      a0, s9
    jal     ra, print_hex
    la      a0, msg_nl
    jal     ra, print_string
    la      a0, msg_fail
    jal     ra, print_string
fail_halt:
    j       fail_halt

# ===========================================================================
# VICTIMS. Each bltu sits at window+4, trains taken, then falls through to an
# 8-byte window that restores s0/s1. The next window pops the frame and returns.
# These layouts depend on the .balign 8 before each loop head.
# ===========================================================================

# --- victim: subtests A/B. Loop head window-aligned (baseline). -------------
    .balign 8
victim:
    .option rvc
    c.addi16sp sp, -32
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    .option rvc
    .balign 8
    .option norvc
victim_loop:
    ld      t1, 0(a1)
    addi    a1, a1, 8
    xor     t3, t3, t3             # 4B filler (loop+8)
    bltu    t1, a0, victim_loop    # loop+12 = window+4
    .option rvc
    c.ldsp  s0, 24(sp)             # --- fall-through restore window (loop+16) ---
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
    c.addi16sp sp, 32              # --- next window ---
    c.jr    ra
    .option norvc

# --- victim_div: subtest C. divu backpressure replaces the filler. ----------
    .balign 8
victim_div:
    .option rvc
    c.addi16sp sp, -32
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    li      t6, 0x12345            # nonzero dividend
    .option rvc
    .balign 8
    .option norvc
victim_div_loop:
    ld      t1, 0(a1)
    addi    a1, a1, 8
    divu    t5, t6, a0             # 4B backpressure op (a0 = limit, nonzero)
    bltu    t1, a0, victim_div_loop
    .option rvc
    c.ldsp  s0, 24(sp)
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
    c.addi16sp sp, 32
    c.jr    ra
    .option norvc

# --- victim_t4: subtest D. Loop-back target at window+4. ---------------------
# .balign 8 + a 4B nop places the head (the ld, the branch target) at window+4;
# the 12-byte body then puts bltu at the next window+4 and the fall-through at
# a window boundary (restore window). The nop runs once on entry only.
    .balign 8
victim_t4:
    .option rvc
    c.addi16sp sp, -32
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    .balign 8
    nop                            # 4B filler -> head at window+4
victim_t4_head:
    ld      t1, 0(a1)              # window+4 (loop-back target)
    addi    a1, a1, 8              # window+8
    bltu    t1, a0, victim_t4_head # window+4 (loop-back branch)
    .option rvc
    c.ldsp  s0, 24(sp)             # --- restore window (window-aligned) ---
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
    c.addi16sp sp, 32
    c.jr    ra
    .option norvc

# --- victim_t2: subtest E. Loop-back target at window+2, rvc-mixed head. -----
    .balign 8
victim_t2:
    .option rvc
    c.addi16sp sp, -32
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    .option rvc
    .balign 8
    c.nop                          # 2B filler -> head at window+2
victim_t2_head:
    c.nop                          # rvc head at window+2 (loop-back target)
    .option norvc
    ld      t1, 0(a1)              # window+4
    addi    a1, a1, 8              # window+8
    bltu    t1, a0, victim_t2_head # window+4
    .option rvc
    c.ldsp  s0, 24(sp)
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
    c.addi16sp sp, 32
    c.jr    ra
    .option norvc

# --- victim_span: subtest F. A 32-bit op spans an 8-byte window boundary. ----
# c.nop places addi at window+6; bltu sits at window+4. The spanning addi uses
# if_stage's instruction buffer and served_eq_pc_word_p1 window check.
    .balign 8
victim_span:
    .option rvc
    c.addi16sp sp, -32
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    .option rvc
    .balign 8
    .option norvc
victim_span_head:                  # window+0 (loop-back target)
    ld      t1, 0(a1)              # window+0 (4B)
    .option rvc
    c.nop                          # window+4 (2B)
    .option norvc
    addi    a1, a1, 8              # window+6 (4B) spans window+8
    .option rvc
    c.nop                          # window+10 (2B)
    .option norvc
    bltu    t1, a0, victim_span_head   # window+12 = window+4
    .option rvc
    c.ldsp  s0, 24(sp)
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
    c.addi16sp sp, 32
    c.jr    ra
    .option norvc

# --- victim_real: subtest G. ------------------------------------------------
# Reproduce the zlib longest_match reload tail and epilogue (coremark_pro_zip).
# The bltu and its loop-head target both sit at window+4. A synthetic prev[]
# chain walks a1 from N+2 down to t1=2, then bltu falls through to the restore.
#
# The byte-scan middle is omitted, leaving the head and reload tail adjacent.
# Their window offsets, opcodes and registers match the compiled function;
# branch immediates use local targets. Save s2 in the prologue so the tail's
# ld s2,8(sp) reads a valid slot. The lbu loads use a scratch buffer because
# only the omitted scan needs their values. Hex comments give the encodings.
    .balign 8
victim_real:
    .option rvc
    c.addi16sp sp, -32
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
    c.sdsp  s2, 8(sp)              # Valid slot for the tail's ld s2,8(sp).
    .option norvc
    li      s0, 128                # poison (nice_match = 128 in the original)
    li      s1, 0                  # poison
    li      t1, 2                  # threshold: bltu falls through once a1 <= 2
    li      t5, 0xFFFF             # hash mask
    la      t4, prev_array         # prev[] base
    la      t0, scan_buffer        # dead scan buffer for the lbu reloads
    li      a5, 8                  # match offset (drives add a4,t0,a5)
    addi    a1, a0, 2              # chain start = N + 2
    li      a3, 4096               # chain-length safety (bltu exits first)
    .balign 8
    nop                            # 4B filler -> head at window+4
    .option rvc                    # Preserve compressed instruction widths.
victim_real_head:
    addiw   a3, a3, -1             # 36fd     window+4 (bltu target)
    beqz    a3, victim_real_exit   # rvc      window+6, chain-exhausted exit
victim_real_reload:                # window-aligned
    and     a1, a1, t5             # 01e5f5b3 window+0 (t5 blocks compression)
    sh1add.uw a1, a1, t4           # 21d5a5bb window+4
    lhu     a1, 0(a1)              # 0005d583 window+0, a1 = prev[a1]
    add     a4, t0, a5             # 00f28733 window+4
    lbu     t6, -1(a4)             # fff74f83 window+0
    lbu     t3, 0(a4)              # 00074e03 window+4
    c.ldsp  s2, 8(sp)              # 6922     window+0
    c.mv    a7, a5                 # 88be     window+2
    bltu    t1, a1, victim_real_head   # window+4, targets head
victim_real_exit:
    c.ldsp  s0, 24(sp)             # 6462     window+0 (restore window)
    minu    a0, a7, s1             # 0a98d533 window+2
    c.ldsp  s1, 16(sp)             # 64c2     window+6
    c.addi16sp sp, 32              # 6105     window+0 (next window)
    c.jr    ra                     # 8082     window+2
    .option norvc

# ---------------------------------------------------------------------------
# UART helpers: poll TX-ready (0x40000028 bit 0) then write (0x40000000).
# a/t regs only, so driver s-registers survive across prints.
# ---------------------------------------------------------------------------
    .balign 4
print_char:
    lui     t6, 0x40000
1:  lw      t5, 0x28(t6)
    andi    t5, t5, 1
    beqz    t5, 1b
    sw      a0, 0(t6)
    ret

    .balign 4
print_string:
    mv      a2, a0
1:  lbu     a1, 0(a2)
    beqz    a1, 2f
    lui     t6, 0x40000
3:  lw      t5, 0x28(t6)
    andi    t5, t5, 1
    beqz    t5, 3b
    sw      a1, 0(t6)
    addi    a2, a2, 1
    j       1b
2:  ret

    .balign 4
print_hex:
    li      a3, 28
1:  srl     a1, a0, a3
    andi    a1, a1, 0xf
    li      t5, 10
    blt     a1, t5, 2f
    addi    a1, a1, 0x57           # 'a' - 10
    j       3f
2:  addi    a1, a1, 0x30           # '0'
3:  lui     t6, 0x40000
4:  lw      t5, 0x28(t6)
    andi    t5, t5, 1
    beqz    t5, 4b
    sw      a1, 0(t6)
    addi    a3, a3, -4
    bgez    a3, 1b
    ret

    .option pop

# ---------------------------------------------------------------------------
    .section .rodata
    .balign 4
msg_header:
    .asciz "=== window_skip_repro v2 (trained-taken loop-exit fall-through) ===\n"
msg_ws:
    .asciz "\n<<WINDOW-SKIP>> stale callee-saved after loop-exit fall-through: "
msg_sub:
    .asciz "subtest="
msg_reg:
    .asciz " reg=s"
msg_iter:
    .asciz " iter=0x"
msg_got:
    .asciz " got=0x"
msg_nl:
    .asciz "\n"
msg_pass:
    .asciz "<<PASS>>\n"
msg_fail:
    .asciz "<<FAIL>>\n"

# ---------------------------------------------------------------------------
# Arrays (in low BRAM in the default BRAM build). There is no crt0, so .bss is
# not zeroed: _start fills bram_array and prev_array, and the values loaded
# from scan_buffer are never used.
    .section .bss
    .balign 8
bram_array:
    .space 128 * 8                 # ascending values, >= 65 elements used
    .balign 8
prev_array:
    .space 128 * 2                 # u16 hash chain prev[k]=k-1 (victim_real)
    .balign 8
scan_buffer:
    .space 64                      # dead read target for victim_real's lbu
