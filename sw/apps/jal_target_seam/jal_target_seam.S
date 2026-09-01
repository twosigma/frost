# Directed reproducer: a 4-byte JAL entered as a taken-branch target at
# dword offset 4 (isolated from the rv64 M7 Linux boot: of_core_init's
# __of_find_all_nodes call site at 0x802c69ac; the shape is XLEN-independent
# and this repro fails identically at rv32 pre-fix).
#
# Kernel shape being mirrored -- one aligned dword holding
#   +0: compressed conditional branch, target = +4 (same dword)
#   +2: one compressed instruction (skipped when the branch takes)
#   +4: 4-byte jal (the branch target)
# First lap reaches the jal SEQUENTIALLY (branch not taken -- this is how
# the kernel's first of_core_init lap trained the predictor); every later
# lap enters it VIA THE TAKEN BRANCH. Failure mode under test: the jal
# retires and writes ra, but fetch falls through and the callee never
# executes.
#
# Root cause (fixed in prediction_metadata_tracker/pc_controller): the
# branch's own BTB hit lands in a redirect-bubble holdoff, so it emits
# unpredicted; the jal's BTB prediction then consumes with the pending
# pc_reg handoff armed; the PD redirect for the unpredicted branch kills
# that pending fetch state, but the tracker's pending-saved metadata
# survived the kill and replayed onto the re-fetched jal -- the ROB saw a
# "correctly predicted" jal (own target) and never recovered the lost
# redirect. Needs the variable-latency L1I fetch path to arm the pending
# walk: this program fits in the always-ready low-BRAM metadata overlay, which
# never pends and passes.
#
# PASS iff the callee ran once per lap. Prints counts on FAIL.

.equ LOOPS, 64

    .section .text
    .globl _start
_start:
    .option push
    .option norvc
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)

    li      s1, 0            # lap counter
    li      s2, LOOPS
    li      a5, 0            # branch arm: 0 = sequential first lap
    la      t0, callee_count # re-runnable: the harness reruns the program
    sw      zero, 0(t0)      # in-sim without reloading memory
    la      a0, msg_banner
    jal     ra, print_string
    .option pop

    # Match the kernel scene: the victim jal lived at 0x802c69ac, i.e. at
    # byte 0x2c of its 64-byte I-cache line. Pad so seam_jal lands at the
    # same line offset (loop_head at +0x28, jal at +0x2c).
    .balign 64
    .option push
    .option norvc
    nop; nop; nop; nop; nop; nop; nop; nop; nop; nop
    .option pop
    .option push
    .option rvc
loop_head:
    bnez    a5, seam_jal     # +0: c.bnez (a5 is compressed-eligible)
    c.nop                    # +2: stands in for the kernel's skipped c.sd
seam_jal:
    jal     ra, seam_callee  # +4: the shape under test
    .option pop
    .option push
    .option norvc
    addi    s1, s1, 1
    li      a5, 1            # arm the branch for laps 2+
    blt     s1, s2, loop_head

    # Verdict
    la      t0, callee_count
    lw      t1, 0(t0)
    beq     t1, s2, pass
    la      a0, msg_fail
    jal     ra, print_string
    j       halt
pass:
    la      a0, msg_pass
    jal     ra, print_string
halt:
    j       halt

    .balign 8
seam_callee:
    la      t0, callee_count
    lw      t1, 0(t0)
    addi    t1, t1, 1
    sw      t1, 0(t0)
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
callee_count:
    .word 0

    # Strings live in .rodata: at MEM_CONFIG=bram, .data is a crt0-copied
    # section (VMA in RAM, LMA in ROM) and standalone-asm apps have no
    # crt0, so .data initializers read as zeros there.  .rodata is
    # execute-in-place in both tiers.  The .balign keeps the section's
    # load address word-aligned (this .text ends on a halfword and
    # objcopy's verilog writer rejects unaligned section starts).
    .section .rodata
    .balign 4
msg_banner:
    .asciz "jal_target_seam: branch->jal@dword+4\n"
msg_pass:
    .asciz "<<PASS>>\n"
msg_fail:
    .asciz "<<FAIL>> callee count mismatch\n"
