# Directed reproducer for the RV64 "skipped fall-through fetch window" bug (v2).
#
# Observed on hardware (genesys2 rv64, coremark_pro_zip / zlib longest_match):
# a loop-back branch that the front end has trained taken resolves not-taken on
# loop exit. The early misprediction recovery redirects to the fall-through PC,
# but the front end skips exactly one aligned 8-byte fetch window, the
# fall-through window, and executes the next window instead. In the wild the
# skipped window held the callee-saved restores {c.ld s0,24(sp); minu a0,a7,s1;
# c.ld s1,16(sp)} and the executed one held {c.addi16sp sp,32; ret}, which is
# position-independent, so execution continued with stale s0/s1 (s0 ==
# nice_match == 128 at the failure).
#
# The canary mechanism is the same in every victim: the caller puts good values
# in s0/s1, the victim's prologue saves them, the body overwrites them with
# poison, and the epilogue's one-window restore puts them back. If that restore
# window is skipped the caller sees stale s0/s1 and prints a distinctive
# <<FAIL>> line. The sim assertion p_bram_served_window_covers_pc_reg in
# if_stage.sv fires on the same event: all victim code is fetched from low
# BRAM, where that assertion is armed. When every call restores, the run ends
# in <<PASS>>.
#
# Victims / subtests (each sweeps exit iteration N over 8..64):
#   A  victim       BRAM array, fast 1-cycle loads (baseline)
#   B  victim       DDR array @0x80100000, load-latency delays resolution
#                   (start block swept across 8 KiB for cache churn)
#   C  victim_div   BRAM array + divu backpressure in the loop body
#   D  victim_t4    loop-back target at window+4, not window-aligned, like the
#                   wild head 0x167c; bltu still at its window+4 and the
#                   one-window restore epilogue unchanged. Changes the
#                   aligner/fetch state on every taken iteration and at the
#                   final redirect.
#   E  victim_t2    loop-back target at window+2 with an rvc-mixed head, so the
#                   target is halfword-aligned on every taken iteration
#   F  victim_span  loop body mixes rvc and 32-bit ops, with the 32-bit
#                   pointer-advance addi spanning an 8-byte window boundary
#                   each iteration. Exercises the served_eq_pc_word_p1 &&
#                   use_instr_buffer covers arm that the norvc loops never
#                   touch; bltu at window+4, same restore.
#   G  victim_real  the zlib longest_match inner-loop reload tail + epilogue
#                   (zip ELF 0x1738-0x1762) lifted byte for byte, with the
#                   loop-back bltu@window+4 targeting the 0x167c-equivalent
#                   head@window+4. A synthetic prev[] hash chain drives it, so
#                   the bltu takes N times then falls through. Deviations are
#                   noted at victim_real.
#
# RV64 shape: doubleword compressed save/restore pairs (c.sdsp/c.ldsp), 8-byte
# array stride, 32-byte frames; the real-bytes variant (subtest G) additionally
# uses Zba/Zbb.

    .section .init
    .option push
    .option norelax
    .option norvc
    .globl _start

    .equ GOOD_S0, 0x000600D0
    .equ GOOD_S1, 0x000600D1
    .equ V1_CALLS, 1200            # calls per v1 subtest (A/B/C); trimmed from
                                   # 2000 to make cycle room for the v2 variants
    .equ V2_CALLS, 800             # calls per v2 subtest (D/E/F/G); the exit
                                   # iteration N sweeps 57 values, so 800 calls
                                   # walk the whole sweep 14 times
    .equ DDR_BLOCKS, 8             # 8 * 1024 B = 8 KiB swept for subtest B

# ---------------------------------------------------------------------------
# SHIM (inline macro, no call frame): put the good canaries in s0/s1, call the
# current victim (s2), and check that the victim restored them. Every victim
# shares the save/poison/restore canary shape, so one shim serves them all.
# \@ makes the local labels unique per expansion. Defined before first use.
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
# _start / driver. Persistent state lives only in s2..s11. The victims write no
# s-registers other than s0/s1/s2 and each restores the ones it writes, and the
# print helpers use only a and t registers, so driver state survives calls and
# prints.
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
    slli    s6, s6, 20             # s6 = 0x80100000 (XLEN-safe, no sign wrap)
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

    # ========= Subtest G: real-bytes longest_match lift (victim_real) =====
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
# VICTIMS. Every victim has the same shape: an rvc prologue saves s0/s1, norvc
# code poisons them, a loop whose loop-back bltu sits at its window+4 trains
# taken and then exits, the rvc fall-through restore window of exactly 8 bytes
# restores s0/s1, and the next window pops the frame and returns. The .balign 8
# at each loop head is the load-bearing invariant. Layouts verified by objdump.
# ===========================================================================

# --- victim: subtests A/B. Loop head window-aligned (v1 baseline). ----------
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
# Head window-aligned; c.nop pushes the pointer-advance addi to window+6 so its
# 4 bytes cross window+8 (spanning). bltu at window+4; same restore epilogue.
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
# Byte-for-byte lift of the zlib longest_match inner-loop reload tail + epilogue
# (zip ELF 0x1738-0x1762) with the loop-back bltu@window+4 targeting the
# 0x167c-equivalent head@window+4. Driven by a synthetic prev[] hash chain: a1
# walks prev[a1]=a1-1 down from N+2 to the threshold t1=2, so the bltu takes ~N
# times then falls through (the bug event = the fall-through skipping the
# restore window). s0=128 mimics the wild nice_match poison.
#
# Deviations from a whole-function lift, all of which keep the fetch geometry:
#   - the byte-scan middle (0x1680-0x1736) is elided: the head's beqz falls
#     straight through to the reload tail, so head and tail are adjacent. Their
#     window alignments match the wild code; only the distance between the two
#     windows is smaller.
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
    addiw   a3, a3, -1             # 36fd   (0x167c) rvc  window+4 (bltu target)
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
# Arrays in low BRAM. No crt0 -> .bss is not load-initialized; every array is
# written at runtime before use.
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
