#    Copyright 2026 Two Sigma Open Source, LLC
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

# Directed probe for the rv64 Linux exec ETXTBSY storm (X3 hardware:
# first exec of an inode succeeds, every later exec of the SAME inode
# fails "Text file busy").  deny_write_access is
# atomic_dec_unless_positive(&inode->i_writecount): the riscv kernel asm
#     0: lr.w p, (c); bgtz p, 1f; addi rc, p, -1; sc.w.rl rc, rc, (c);
#        bnez rc, 0b; fence rw, rw; 1:
# Root cause (fixed in dispatch.sv mem_signed): LR.W wrote back
# ZERO-extended at rv64 -- mem_signed keyed on is_load_instruction
# (opcode==OPC_LOAD), which excludes LR (OPC_AMO), so the LQ entry's
# sign_ext was 0.  The zero-extended -1 reads positive to the raw 64-bit
# bgtz, the loop skips its decrement while the C tail still reports
# success, and the leaked deny counts (over-released by the exit path's
# amoadd.w) drift i_writecount permanently positive under overlapping
# exec/exit interleavings -- after which every exec of the inode fails.
#
# This probe replays that exact scene and its neighborhood, word-exact
# (same opcodes incl. sc.w.rl + trailing fence), on both dword lanes,
# with a distinctive POSITIVE pattern in the neighboring word so a
# wrong-lane read is distinguishable from a mis-extension (check 2
# failed pre-fix with val=0x00000000ffffffff = the mis-extension).  Each
# numbered check prints its number + the loaded value on failure;
# <<PASS>> iff all pass.
#
# rv32 note: the same sequence assembles at rv32 (word extension is the
# identity there), so the rv32 twin is a sanity lane -- the hardware
# failure was rv64-only (genesys2 rv32 Linux boots getty cleanly).

.equ NEIGHBOR, 0x7A7A7A7A     # positive, distinctive wrong-lane tell
.equ LAPS, 8

    .section .text
    .globl _start
    .option push
    .option norvc
_start:
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)

    la      a0, msg_banner
    jal     ra, print_string

    li      s11, 0               # lap counter
lap_top:

# --- check 1: lw of a plain-sw -1 sign-extends (baseline) -------------
    li      s0, 1
    la      s1, cell_lo          # dword+0 lane
    li      t0, -1
    sw      t0, 0(s1)
    li      t1, NEIGHBOR
    sw      t1, 4(s1)            # neighbor word (dword+4)
    fence   rw, rw
    lw      t2, 0(s1)
    mv      s4, t2
    li      t3, -1
    bne     t2, t3, fail

# --- check 2: lr.w of a plain-sw -1, both lanes ------------------------
    li      s0, 2
    lr.w    t2, (s1)
    mv      s4, t2
    bne     t2, t3, fail
    la      s2, cell_hi          # dword+4 lane (neighbor at dword+0)
    li      t0, -1
    sw      t0, 4(s2)
    li      t1, NEIGHBOR
    sw      t1, 0(s2)
    fence   rw, rw
    addi    s3, s2, 4
    lr.w    t2, (s3)
    mv      s4, t2
    bne     t2, t3, fail

# --- check 3: kernel deny loop on cell==0 (the FIRST exec) ------------
    li      s0, 3
    sw      zero, 0(s1)
    fence   rw, rw
0:  lr.w    t2, (s1)             # kernel shape, word-exact
    bgtz    t2, deny3_fail
    addi    t4, t2, -1
    sc.w.rl t4, t4, (s1)
    bnez    t4, 0b
    fence   rw, rw
    mv      s4, t2
    bnez    t2, fail             # prev must have been 0
    lw      t5, 0(s1)
    mv      s4, t5
    li      t6, -1
    bne     t5, t6, fail         # cell must now be -1
    j       check4
deny3_fail:
    mv      s4, t2
    j       fail

# --- check 4: kernel deny loop on cell==-1 (the SECOND exec) ----------
# THE hardware failure: lr.w of the -1 written by check 3's sc.w.rl must
# read -1 (not >0); the loop must decrement to -2.
check4:
    li      s0, 4
0:  lr.w    t2, (s1)
    bgtz    t2, deny4_fail       # taking this branch IS the ETXTBSY bug
    addi    t4, t2, -1
    sc.w.rl t4, t4, (s1)
    bnez    t4, 0b
    fence   rw, rw
    mv      s4, t2
    li      t3, -1
    bne     t2, t3, fail         # prev must have been exactly -1
    lw      t5, 0(s1)
    mv      s4, t5
    li      t6, -2
    bne     t5, t6, fail         # cell must now be -2
    j       check5
deny4_fail:
    mv      s4, t2
    j       fail

# --- check 5: allow path (amoadd.w +1) twice, old values checked ------
check5:
    li      s0, 5
    li      t0, 1
    amoadd.w t2, t0, (s1)        # -2 -> -1, old = -2
    li      t3, -2
    bne     t2, t3, fail
    amoadd.w t2, t0, (s1)        # -1 -> 0, old = -1
    li      t3, -1
    bne     t2, t3, fail
    lw      t5, 0(s1)
    bnez    t5, fail

# --- check 6: lr.w immediately after sc.w.rl, no fence between --------
    li      s0, 6
    li      t0, -1
0:  lr.w    t2, (s1)
    addi    t4, t0, 0
    sc.w.rl t4, t4, (s1)         # store -1
    bnez    t4, 0b
    lr.w    t2, (s1)             # read it straight back
    li      t3, -1
    bne     t2, t3, fail
    lw      t5, 4(s1)            # neighbor untouched
    li      t6, NEIGHBOR
    bne     t5, t6, fail

# --- check 7: checks 3+4 on the dword+4 lane --------------------------
    li      s0, 7
    sw      zero, 4(s2)
    fence   rw, rw
0:  lr.w    t2, (s3)
    bgtz    t2, deny7_fail
    addi    t4, t2, -1
    sc.w.rl t4, t4, (s3)
    bnez    t4, 0b
    fence   rw, rw
    mv      s4, t2
    bnez    t2, fail
1:  lr.w    t2, (s3)
    bgtz    t2, deny7_fail
    addi    t4, t2, -1
    sc.w.rl t4, t4, (s3)
    bnez    t4, 1b
    fence   rw, rw
    mv      s4, t2
    li      t3, -1
    bne     t2, t3, fail
    lw      t5, 4(s2)
    li      t6, -2
    bne     t5, t6, fail
    lw      t5, 0(s2)            # neighbor untouched
    li      t6, NEIGHBOR
    bne     t5, t6, fail
    j       check8
deny7_fail:
    mv      s4, t2
    j       fail

# --- check 8: exec1 ... exec2 with line pressure between --------------
# The hardware execs are far apart: touch a stride of other lines so the
# cell's L0/L1 state is disturbed between the two deny loops.
check8:
    li      s0, 8
    sw      zero, 0(s1)
    fence   rw, rw
0:  lr.w    t2, (s1)             # exec1 deny: 0 -> -1
    bgtz    t2, deny8_fail
    addi    t4, t2, -1
    sc.w.rl t4, t4, (s1)
    bnez    t4, 0b
    fence   rw, rw
    la      t0, scratch_arena    # pressure: walk 64 lines rw (lw/sw is
    li      t1, 64               # XLEN-portable; width is irrelevant here)
2:  lw      t2, 0(t0)
    addi    t2, t2, 1
    sw      t2, 0(t0)
    addi    t0, t0, 64
    addi    t1, t1, -1
    bnez    t1, 2b
    fence   rw, rw
1:  lr.w    t2, (s1)             # exec2 deny: -1 -> -2
    bgtz    t2, deny8_fail
    addi    t4, t2, -1
    sc.w.rl t4, t4, (s1)
    bnez    t4, 1b
    fence   rw, rw
    mv      s4, t2
    li      t3, -1
    bne     t2, t3, fail
    lw      t5, 0(s1)
    mv      s4, t5
    li      t6, -2
    bne     t5, t6, fail
    j       lap_bottom
deny8_fail:
    mv      s4, t2
    j       fail

lap_bottom:
    addi    s11, s11, 1
    li      t0, LAPS
    blt     s11, t0, lap_top

    la      a0, msg_pass
    jal     ra, print_string
halt:
    j       halt

fail:
    la      a0, msg_failing_check
    jal     ra, print_string
    mv      a0, s0               # failing check number as ascii digit
    addi    a0, a0, 48
    la      t0, digit_buf
    sb      a0, 0(t0)
    la      a0, digit_buf
    jal     ra, print_string
    la      a0, msg_val
    jal     ra, print_string
    mv      a0, s4               # the offending loaded value
    jal     ra, print_hex64
    la      a0, msg_nl
    jal     ra, print_string
    la      a0, msg_fail         # marker LAST: the harness stops on it
    jal     ra, print_string
    j       halt

# print a0 as 16 hex nibbles (works at rv32 too: prints high word as 0)
print_hex64:
    mv      t4, ra
    li      a2, 60               # shift amount
1:  srl     a1, a0, a2
    andi    a1, a1, 0xF
    li      a3, 10
    blt     a1, a3, 2f
    addi    a1, a1, 39           # 'a' - '0' - 10
2:  addi    a1, a1, 48
3:  lui     t6, 0x40000
    lw      t3, 0x28(t6)
    andi    t3, t3, 1
    beqz    t3, 3b
    sw      a1, 0(t6)
    addi    a2, a2, -4
    bgez    a2, 1b
    mv      ra, t4
    ret

print_string:
    mv      t4, a0
1:  lbu     t5, 0(t4)
    beqz    t5, 2f
3:  lui     t6, 0x40000
    lw      t3, 0x28(t6)
    andi    t3, t3, 1
    beqz    t3, 3b
    sw      t5, 0(t6)
    addi    t4, t4, 1
    j       1b
2:  ret
    .option pop

    .section .data
    .balign 64
cell_lo:                         # dword+0 lane; neighbor at +4
    .word 0
    .word 0
    .balign 64
cell_hi:                         # neighbor at +0; cell at dword+4
    .word 0
    .word 0
    .balign 64
scratch_arena:
    .fill 1024, 8, 0
digit_buf:
    .byte 0, 0

    # Strings live in .rodata: at MEM_CONFIG=bram, .data is a crt0-copied
    # section (VMA in RAM, LMA in ROM) and standalone-asm apps have no
    # crt0, so .data initializers read as zeros there.  .rodata is
    # execute-in-place in both tiers.  The cells above are fine in .data:
    # every one is written at runtime before it is read.  The .balign
    # keeps the section's load address word-aligned for objcopy's
    # verilog writer.
    .section .rodata
    .balign 4
msg_banner:
    .asciz "writecount_probe: deny_write_access lr.w/sc.w scene\n"
msg_pass:
    .asciz "<<PASS>>\n"
msg_val:
    .asciz " val=0x"
msg_failing_check:
    .asciz "failing check "
msg_fail:
    .asciz "<<FAIL>>\n"
msg_nl:
    .asciz "\n"
