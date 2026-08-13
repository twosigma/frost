# Directed reproducer for the RV64 "skipped fall-through fetch window" bug (v2).
#
# Hardware-observed (genesys2 rv64, coremark_pro_zip / zlib longest_match): a
# loop-back branch that the front end has trained TAKEN resolves NOT-taken on
# loop exit; the early misprediction recovery redirects to the fall-through PC,
# but the front end skips exactly one aligned 8-byte fetch window -- the
# fall-through window -- and executes the NEXT window instead. In the wild the
# skipped window held {c.ld s0,24(sp); minu a0,a7,s1; c.ld s1,16(sp)}
# (callee-saved restores) and the executed one {c.addi16sp sp,32; ret}
# (position-independent), so execution continued cleanly with STALE s0/s1
# (s0 == nice_match == 128 at the failure).
#
# The canary mechanism (all victims): the caller entrusts good values in
# s0/s1; the victim's prologue saves them, the body overwrites them (poison),
# the epilogue's one-window restore puts them back. If that restore window is
# skipped, the caller sees stale s0/s1 -> a distinctive <<FAIL>> line. The sim
# assertion if_stage.sv p_bram_served_window_covers_pc_reg fires on the same
# event (all victim code is fetched from low BRAM, where that assertion is
# armed). Normally every call restores cleanly -> <<PASS>>.
#
# Victims / subtests (each sweeps exit iteration N over 8..64):
#   A  victim       BRAM array, fast 1-cycle loads (baseline)
#   B  victim       DDR array @0x80100000, load-latency delays resolution
#                   (start block swept across 8 KiB for cache churn)
#   C  victim_div   BRAM array + divu backpressure in the loop body
#   D  victim_t4    loop-back TARGET at window+4 (not window-aligned, like the
#                   wild head 0x167c); bltu still at its window+4, one-window
#                   restore epilogue unchanged -- changes the aligner/fetch
#                   state on every taken iteration and at the final redirect
#   E  victim_t2    loop-back TARGET at window+2 with an rvc-mixed head
#                   (halfword-aligned compressed target every taken iteration)
#   F  victim_span  loop body is an rvc/32-bit MIX with a 32-bit op (the
#                   pointer-advance addi) SPANNING an 8-byte window boundary
#                   each iteration -- exercises the served_eq_pc_word_p1 &&
#                   use_instr_buffer (instruction-buffer) covers arm that the
#                   norvc loops never touch; bltu at window+4, same restore
#   G  victim_real  rv64-only: the zlib longest_match inner-loop reload tail +
#                   epilogue (zip ELF 0x1738-0x1762) lifted BYTE-FOR-BYTE with
#                   the loop-back bltu@window+4 targeting the 0x167c-equivalent
#                   head@window+4; driven by a synthetic prev[] hash chain so
#                   the bltu takes N times then falls through. rv32 skips it
#                   (prints a note). Deviations noted at victim_real.
#
# Dual-XLEN (test-parity standard): one source, .if FROST_RV64_ASM arms. At
# rv32 the doubleword compressed forms become word forms (c.sw/c.lw + 4-byte
# stride, keeping the 32-byte frame and the exact window sizes); the real-bytes
# variant (Zba/Zbb, doubleword) is rv64-only.

    .section .init
    .option push
    .option norelax
    .option norvc
    .globl _start

    .equ GOOD_S0, 0x000600D0
    .equ GOOD_S1, 0x000600D1
    .equ V1_CALLS, 1200            # calls per v1 subtest (A/B/C); trimmed from
                                   # 2000 to make cycle room for the v2 variants
    .equ V2_CALLS, 800             # calls per v2 subtest (D/E/F/G); >=600 rolls
    .equ DDR_BLOCKS, 8             # 8 * 1024 B = 8 KiB swept for subtest B

# ---------------------------------------------------------------------------
# SHIM (macro, inline, no call frame): entrust the good canaries to s0/s1,
# call the current victim (s2), verify the victim restored them. Works for
# every victim (all share the save/poison/restore canary shape). \@ makes the
# local labels unique per expansion. Defined before first use.
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
# _start / driver. Persistent state lives in s2..s11 ONLY (victims clobber only
# s0/s1/s2, all saved+restored; print helpers use a/t regs), so driver state
# survives calls and prints.
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
.if FROST_RV64_ASM
    sd      t0, 0(t3)
    addi    t3, t3, 8
.else
    sw      t0, 0(t3)
    addi    t3, t3, 4
.endif
    addi    t0, t0, 1
    blt     t0, t2, 1b

    # ---- fill the DDR array @0x80100000: ascending-mod-128 over 8 KiB ----
    li      s6, 0x801
    slli    s6, s6, 20             # s6 = 0x80100000 (XLEN-safe, no sign wrap)
    mv      t3, s6
    li      t0, 0
    li      t4, 0
    li      t5, 8192
2:
    andi    t2, t0, 127
.if FROST_RV64_ASM
    sd      t2, 0(t3)
    addi    t3, t3, 8
    addi    t4, t4, 8
.else
    sw      t2, 0(t3)
    addi    t3, t3, 4
    addi    t4, t4, 4
.endif
    addi    t0, t0, 1
    blt     t4, t5, 2b

.if FROST_RV64_ASM
    # ---- fill prev_array[k] = k-1 (u16) for the real-bytes hash chain ----
    la      t3, prev_array
    li      t0, 0
    li      t2, 128
3:
    addi    t4, t0, -1
    sh      t4, 0(t3)
    addi    t3, t3, 2
    addi    t0, t0, 1
    blt     t0, t2, 3b
.endif

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

    # ========= Subtest D: loop-back TARGET at window+4 (victim_t4) ========
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

    # ===== Subtest E: loop-back TARGET at window+2, rvc head (victim_t2) ===
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

    # ========= Subtest G: real-bytes longest_match lift (rv64-only) =======
.if FROST_RV64_ASM
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
.else
    la      a0, msg_skip_rv32_real
    jal     ra, print_string
.endif

    la      a0, msg_pass
    jal     ra, print_string
done:
    j       done

# ---------------------------------------------------------------------------
# report_fail: distinctive line + <<FAIL>> (harness stops on the marker).
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
# VICTIMS. Shared shape: rvc prologue saves s0/s1; norvc poisons them; a loop
# whose loop-back bltu sits at its window+4 trains taken then exits; the rvc
# fall-through restore window (EXACTLY 8 bytes) restores s0/s1; the next window
# pops the frame and returns. The .balign 8 at each loop head is the load-
# bearing invariant. Layouts verified by objdump (see the task report).
# ===========================================================================

# --- victim: subtests A/B. Loop head window-aligned (v1 baseline). ----------
    .balign 8
victim:
    .option rvc
    c.addi16sp sp, -32
.if FROST_RV64_ASM
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
.else
    c.swsp  s0, 24(sp)
    c.swsp  s1, 16(sp)
.endif
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    .option rvc
    .balign 8
    .option norvc
victim_loop:
.if FROST_RV64_ASM
    ld      t1, 0(a1)
    addi    a1, a1, 8
.else
    lw      t1, 0(a1)
    addi    a1, a1, 4
.endif
    xor     t3, t3, t3             # 4B filler (loop+8)
    bltu    t1, a0, victim_loop    # loop+12 = window+4
    .option rvc
.if FROST_RV64_ASM
    c.ldsp  s0, 24(sp)             # --- fall-through restore window (loop+16) ---
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
.else
    c.lwsp  s0, 24(sp)
    xor     t3, t3, t4
    c.lwsp  s1, 16(sp)
.endif
    c.addi16sp sp, 32              # --- next window ---
    c.jr    ra
    .option norvc

# --- victim_div: subtest C. divu backpressure replaces the filler. ----------
    .balign 8
victim_div:
    .option rvc
    c.addi16sp sp, -32
.if FROST_RV64_ASM
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
.else
    c.swsp  s0, 24(sp)
    c.swsp  s1, 16(sp)
.endif
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    li      t6, 0x12345            # nonzero dividend
    .option rvc
    .balign 8
    .option norvc
victim_div_loop:
.if FROST_RV64_ASM
    ld      t1, 0(a1)
    addi    a1, a1, 8
.else
    lw      t1, 0(a1)
    addi    a1, a1, 4
.endif
    divu    t5, t6, a0             # 4B backpressure op (a0 = limit, nonzero)
    bltu    t1, a0, victim_div_loop
    .option rvc
.if FROST_RV64_ASM
    c.ldsp  s0, 24(sp)
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
.else
    c.lwsp  s0, 24(sp)
    xor     t3, t3, t4
    c.lwsp  s1, 16(sp)
.endif
    c.addi16sp sp, 32
    c.jr    ra
    .option norvc

# --- victim_t4: subtest D. Loop-back TARGET at window+4. ---------------------
# .balign 8 + a 4B nop places the head (the ld, the branch target) at window+4;
# the 12-byte body then puts bltu at the next window+4 and the fall-through at
# a window boundary (restore window). The nop runs once on entry only.
    .balign 8
victim_t4:
    .option rvc
    c.addi16sp sp, -32
.if FROST_RV64_ASM
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
.else
    c.swsp  s0, 24(sp)
    c.swsp  s1, 16(sp)
.endif
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    .balign 8
    nop                            # 4B filler -> head at window+4
victim_t4_head:
.if FROST_RV64_ASM
    ld      t1, 0(a1)              # window+4 (loop-back TARGET)
    addi    a1, a1, 8              # window+8
.else
    lw      t1, 0(a1)
    addi    a1, a1, 4
.endif
    bltu    t1, a0, victim_t4_head # window+4 (loop-back branch)
    .option rvc
.if FROST_RV64_ASM
    c.ldsp  s0, 24(sp)             # --- restore window (window-aligned) ---
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
.else
    c.lwsp  s0, 24(sp)
    xor     t3, t3, t4
    c.lwsp  s1, 16(sp)
.endif
    c.addi16sp sp, 32
    c.jr    ra
    .option norvc

# --- victim_t2: subtest E. Loop-back TARGET at window+2, rvc-mixed head. -----
    .balign 8
victim_t2:
    .option rvc
    c.addi16sp sp, -32
.if FROST_RV64_ASM
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
.else
    c.swsp  s0, 24(sp)
    c.swsp  s1, 16(sp)
.endif
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    .option rvc
    .balign 8
    c.nop                          # 2B filler -> head at window+2
victim_t2_head:
    c.nop                          # rvc head at window+2 (loop-back TARGET)
    .option norvc
.if FROST_RV64_ASM
    ld      t1, 0(a1)              # window+4
    addi    a1, a1, 8              # window+8
.else
    lw      t1, 0(a1)
    addi    a1, a1, 4
.endif
    bltu    t1, a0, victim_t2_head # window+4
    .option rvc
.if FROST_RV64_ASM
    c.ldsp  s0, 24(sp)
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
.else
    c.lwsp  s0, 24(sp)
    xor     t3, t3, t4
    c.lwsp  s1, 16(sp)
.endif
    c.addi16sp sp, 32
    c.jr    ra
    .option norvc

# --- victim_span: subtest F. A 32-bit op spans an 8-byte window boundary. ----
# Head window-aligned; c.nop pushes the pointer-advance addi to window+6 so its
# 4 bytes cross window+8 (spanning). bltu at window+4; same restore epilogue.
    .balign 8
victim_span:
    .option rvc
    c.addi16sp sp, -32
.if FROST_RV64_ASM
    c.sdsp  s0, 24(sp)
    c.sdsp  s1, 16(sp)
.else
    c.swsp  s0, 24(sp)
    c.swsp  s1, 16(sp)
.endif
    .option norvc
    li      s0, 0x80
    li      s1, 0xB1
    .option rvc
    .balign 8
    .option norvc
victim_span_head:                  # window+0 (loop-back TARGET)
.if FROST_RV64_ASM
    ld      t1, 0(a1)              # window+0 (4B)
.else
    lw      t1, 0(a1)
.endif
    .option rvc
    c.nop                          # window+4 (2B)
    .option norvc
.if FROST_RV64_ASM
    addi    a1, a1, 8              # window+6 (4B) SPANS window+8
.else
    addi    a1, a1, 4
.endif
    .option rvc
    c.nop                          # window+10 (2B)
    .option norvc
    bltu    t1, a0, victim_span_head   # window+12 = window+4
    .option rvc
.if FROST_RV64_ASM
    c.ldsp  s0, 24(sp)
    xor     t3, t3, t4
    c.ldsp  s1, 16(sp)
.else
    c.lwsp  s0, 24(sp)
    xor     t3, t3, t4
    c.lwsp  s1, 16(sp)
.endif
    c.addi16sp sp, 32
    c.jr    ra
    .option norvc

.if FROST_RV64_ASM
# --- victim_real: subtest G (rv64-only). ------------------------------------
# Byte-for-byte lift of the zlib longest_match inner-loop reload tail + epilogue
# (zip ELF 0x1738-0x1762) with the loop-back bltu@window+4 targeting the
# 0x167c-equivalent head@window+4. Driven by a synthetic prev[] hash chain: a1
# walks prev[a1]=a1-1 down from N+2 to the threshold t1=2, so the bltu takes ~N
# times then falls through (the bug event = the fall-through skipping the
# restore window). s0=128 mimics the wild nice_match poison.
#
# DEVIATIONS from a whole-function lift (fetch geometry preserved, all noted):
#   - the byte-scan middle (0x1680-0x1736) is elided: the head's beqz falls
#     straight through to the reload tail, so head and tail are adjacent (their
#     window ALIGNMENTS match the wild; the inter-window DISTANCE is smaller).
#   - s2 is saved at prologue (wild saves it mid-scan at 0x16b0) so the tail's
#     byte-exact `ld s2,8(sp)` reads a valid slot.
#   - branch/jump immediates differ (targets are local); opcodes+regs identical.
#   - the lbu reload addresses point at a dead scratch buffer (their loaded
#     values feed the elided scan); they still add real load traffic.
    .balign 8
victim_real:
    .option rvc
    c.addi16sp sp, -32             # 1101   (wild 0x1604) byte-faithful
    c.sdsp  s0, 24(sp)             # ec22   (0x1606)
    c.sdsp  s1, 16(sp)             # e826   (0x1608)
    c.sdsp  s2, 8(sp)              # slot for the tail's ld s2,8(sp) (see note)
    .option norvc
    li      s0, 128                # nice_match poison (wild lw s0,192(a0)+minu)
    li      s1, 0                  # wild lw s1,164(a0)
    li      t1, 2                  # best_len threshold (wild li t1,0 / subw)
    li      t5, 0xFFFF             # hash mask
    la      t4, prev_array         # prev[] base
    la      t0, scan_buffer        # dead scan buffer for the lbu reloads
    li      a5, 8                  # match offset (drives add a4,t0,a5)
    addi    a1, a0, 2              # chain start = N + 2
    li      a3, 4096               # chain-length safety (bltu exits first)
    .balign 8
    nop                            # 4B filler -> head at window+4
    .option rvc                    # head/reload/epilogue are byte-faithful RVC
victim_real_head:
    addiw   a3, a3, -1             # 36fd   (0x167c) rvc  window+4 (bltu TARGET)
    beqz    a3, victim_real_exit   # cee9   (0x167e) rvc  chain-exhausted exit
victim_real_reload:                # window-aligned; reproduces wild 0x1738..
    and     a1, a1, t5             # 01e5f5b3 (0x1738) 4B (t5 blocks compress)
    sh1add.uw a1, a1, t4           # 21d5a5bb (0x173c) 4B
    lhu     a1, 0(a1)              # 0005d583 (0x1740) 4B  a1 = prev[a1]
    add     a4, t0, a5             # 00f28733 (0x1744) 4B
    lbu     t6, -1(a4)             # fff74f83 (0x1748) 4B
    lbu     t3, 0(a4)              # 00074e03 (0x174c) 4B
    c.ldsp  s2, 8(sp)              # 6922     (0x1750) window+0
    c.mv    a7, a5                 # 88be     (0x1752) window+2
    bltu    t1, a1, victim_real_head   # (0x1754) window+4, targets head
victim_real_exit:
    c.ldsp  s0, 24(sp)             # 6462     (0x1758) window+0 (restore window)
    minu    a0, a7, s1             # 0a98d533 (0x175a) the real 4B op
    c.ldsp  s1, 16(sp)             # 64c2     (0x175e)
    c.addi16sp sp, 32              # 6105     (0x1760) next window
    c.jr    ra                     # 8082     (0x1762)
    .option norvc
.endif

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
msg_skip_rv32_real:
    .asciz "note: subtest G (longest_match real-bytes lift) is rv64-only; skipped at rv32\n"
msg_pass:
    .asciz "<<PASS>>\n"
msg_fail:
    .asciz "<<FAIL>>\n"

# ---------------------------------------------------------------------------
# Arrays in low BRAM. No crt0 -> .bss is not load-initialized; every array is
# written at runtime before use.
    .section .bss
    .balign 8
bram_array:
    .space 128 * 8                 # ascending values, >= 65 elements used
.if FROST_RV64_ASM
    .balign 8
prev_array:
    .space 128 * 2                 # u16 hash chain prev[k]=k-1 (victim_real)
    .balign 8
scan_buffer:
    .space 64                      # dead read target for victim_real's lbu
.endif
