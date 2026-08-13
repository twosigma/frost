# Directed reproducer for the RV64 "skipped fall-through fetch window" bug.
#
# Hardware-observed (genesys2 rv64, coremark_pro_zip): a loop-back branch that
# the front end has trained TAKEN resolves NOT-taken on loop exit; the early
# misprediction recovery redirects to the fall-through PC, but the front end
# skips exactly one aligned 8-byte fetch window -- the fall-through window --
# and executes the NEXT window instead. In the wild the skipped window held
# {c.ld s0,24(sp); <4B op>; c.ld s1,16(sp)} (callee-saved restores) and the
# executed one {c.addi16sp sp,32; ret} (position-independent), so execution
# continued cleanly with STALE s0/s1.
#
# This app machine-faithfully rebuilds that shape as a victim function:
#
#   prologue (rvc):  c.addi16sp sp,-32 ; save s0/s1 to 24(sp)/16(sp)
#   poison       :   li s0,0x80 ; li s1,0xB1   (mimics nice_match=128 in the wild)
#   loop (norvc, 8-byte-aligned entry, body EXACTLY 16 bytes so the loop-back
#         branch sits at loop+12 = +4 of its window, like the wild bltu@0x1754):
#            +0  ld  t1,0(a1)          (load walks an ascending array; delays
#            +4  addi a1,a1,8           branch resolution)
#            +8  xor t3,t3,t3          (4B non-compressible filler)
#            +12 bltu t1,a0,loop       (TAKEN while value<limit; falls through
#                                       when value>=limit == loop exit)
#   restore window (rvc, the FALL-THROUGH window, EXACTLY 8 bytes = loop+16):
#            c.ld  s0,24(sp) ; xor t3,t3,t4 (4B, t-regs don't compress) ; c.ld s1,16(sp)
#   next window (rvc): c.addi16sp sp,32 ; c.jr ra
#
# One call = one dice roll: the branch trains taken over N iterations then
# mispredicts on exit. If the bug fires, the restore window is skipped, s0/s1
# stay poisoned, and the caller shim catches s0!=good / s1!=good and prints
# <<FAIL>>. A sim assertion (if_stage.sv p_bram_served_window_covers_pc_reg)
# fires on the same event. Normally every call restores cleanly -> <<PASS>>.
#
# Subtests (each >=2000 calls, exit iteration N swept 8..64):
#   A  BRAM array  : fast 1-cycle loads (baseline)
#   B  DDR array   : cached-region loads at 0x80100000 (load-latency delays
#                    resolution; start block swept across 8 KiB for cache churn)
#   C  BRAM array  : divu dropped into the loop body (FU-backpressure variant)
#
# Dual-XLEN (test-parity standard): one source, .if FROST_RV64_ASM arms. At
# rv32 the doubleword compressed forms become word forms (c.sw/c.lw + 4-byte
# stride, keeping the 32-byte frame and the exact window sizes).

    .section .init
    .option push
    .option norelax
    .option norvc
    .globl _start

# Good canary values the caller entrusts to the victim across the call.
    .equ GOOD_S0, 0x000600D0
    .equ GOOD_S1, 0x000600D1
    .equ N_CALLS, 2000              # calls per subtest (>= 2000 spec floor)
    .equ DDR_BLOCKS, 8              # 8 * 1024 B = 8 KiB swept for subtest B

# ---------------------------------------------------------------------------
# SHIM (macro, expanded inline so it adds no call frame): entrust the good
# canaries to s0/s1, call the current victim, and verify the victim restored
# them. \@ makes the local labels unique per expansion. Defined before first
# use (gas requires macro definition to precede invocation).
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
# _start / driver
#   Persistent state lives in s2..s11 ONLY: the victim clobbers s0/s1 (poison
#   +restore) but never touches s2..s11, and the print helpers use a/t regs
#   only, so driver state survives both calls and prints.
#     s2  = current victim function pointer (victim / victim_div)
#     s3  = call index i within the subtest
#     s4  = N_CALLS
#     s5  = BRAM array base
#     s6  = DDR array base (0x80100000)
#     s7  = subtest character 'A'/'B'/'C'
#     s9  = offending loaded value (set on failure)
#     s10 = failing-register character '0'/'1' (set on failure)
# ---------------------------------------------------------------------------
_start:
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)

    la      a0, msg_header
    jal     ra, print_string

    li      s4, N_CALLS

    # ---- fill the BRAM array: array[k] = k, k = 0..127 (values ascend so
    # the branch is taken until the loaded value reaches the limit a0) ----
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

    # ---- fill the DDR array at 0x80100000 with an ascending-mod-128 pattern
    # over a full 8 KiB (each 1024-byte block restarts 0,1,2,... so any block
    # start is a valid ascending run for the loop) ----
    li      s6, 0x801
    slli    s6, s6, 20             # s6 = 0x80100000 (XLEN-safe, no sign wrap)
    mv      t3, s6
    li      t0, 0                  # element index
    li      t4, 0                  # byte offset
    li      t5, 8192
2:
    andi    t2, t0, 127            # value = k mod 128
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

    # ================= Subtest A: BRAM array (fast loads) =================
    la      s2, victim
    li      s7, 'A'
    li      s3, 0
subA_loop:
    li      t1, 57
    remu    t2, s3, t1
    addi    a0, t2, 8              # N = 8 + (i mod 57) in [8,64]
    mv      a1, s5                 # fixed BRAM base
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
    andi    t2, s3, (DDR_BLOCKS - 1)   # block = i mod 8
    slli    t2, t2, 10                 # * 1024 bytes
    add     a1, s6, t2                 # sweep the start across the 8 KiB
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

# ---------------------------------------------------------------------------
# victim: subtests A/B. See the file header for the exact window layout; the
# .balign 8 at victim_loop is the load-bearing invariant (loop entry 8-aligned
# => 16-byte body puts bltu at +12 and the fall-through restore window at +16).
# ---------------------------------------------------------------------------
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
    li      s0, 0x80               # poison (mimics nice_match=128)
    li      s1, 0xB1
    .option rvc
    .balign 8                      # c.nop fill; loop entry lands 8-aligned
    .option norvc
victim_loop:
.if FROST_RV64_ASM
    ld      t1, 0(a1)
    addi    a1, a1, 8
.else
    lw      t1, 0(a1)
    addi    a1, a1, 4
.endif
    xor     t3, t3, t3             # 4B filler (t-regs: never compresses)
    bltu    t1, a0, victim_loop    # loop+12; TAKEN while value < limit
    .option rvc
.if FROST_RV64_ASM
    c.ldsp  s0, 24(sp)             # --- fall-through restore window (loop+16) ---
    xor     t3, t3, t4             # 4B (t-regs don't compress)
    c.ldsp  s1, 16(sp)
.else
    c.lwsp  s0, 24(sp)
    xor     t3, t3, t4
    c.lwsp  s1, 16(sp)
.endif
    c.addi16sp sp, 32              # --- next window (loop+24): position-independent ---
    c.jr    ra
    .option norvc

# ---------------------------------------------------------------------------
# victim_div: identical shape, but the 4-byte filler is a divu (M-extension
# backpressure). Same 16-byte body / +12 branch / 8-byte restore window.
# ---------------------------------------------------------------------------
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
    li      t6, 0x12345            # nonzero dividend for the divu
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

# ---------------------------------------------------------------------------
# UART helpers: poll TX-ready (0x40000028 bit 0) then write (0x40000000).
# All use a/t regs only, so driver s-registers survive across prints.
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
    # print a0[31:0] as 8 hex nibbles
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
    .asciz "=== window_skip_repro (trained-taken loop-exit fall-through) ===\n"
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
# BRAM array in low BRAM. standalone-asm apps have no crt0, so .data/.bss are
# not initialized at load -- both arrays are written at runtime before use.
    .section .bss
    .balign 8
bram_array:
    .space 128 * 8                 # 128 elements (dword-sized headroom); >= 65 used
