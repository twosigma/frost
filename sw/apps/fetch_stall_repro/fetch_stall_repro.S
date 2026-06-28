# Directed cached-fetch PC-step repro (executes from .ddr_text through the L1I)
#
# Reproduces the HW front-end defect where the core steps PC +2 instead of +4 on
# a 32-bit instruction (mis-decoding it as compressed), landing mid-instruction.
# On genesys2 this fires at workqueue_init_early (epc=0x8038d7fa, 2 bytes into a
# 32-bit `sw zero,4(s1)`), deterministically.
#
# The defect needs the cached L1I fetch path: a fetch stall (!fetch_progress ->
# sel_nop) from a 32-byte line-fill coinciding with a 32-bit instruction near a
# line boundary. A BRAM fetch-fuzz run did NOT trigger it, so this version runs
# the stream from cached DDR (.ddr_text) COLD, so every line is a miss -> a
# regular line-fill stall, like the boot.
#
# Stream = [compressed-nop run][32-bit nops] blocks; compressed run length 3..6
# sweeps the 32-bit nops across every alignment vs the line boundaries. A 32-bit
# nop is 0x00000013 (UPPER half 0x0000 = illegal compressed). Any +2 mis-step
# onto one fetches 0x0000 -> illegal-instruction trap; the handler prints mepc
# (the mid-instruction PC) and <<FAIL>>. Clean run -> <<PASS>>.

    .section .init
    .option push
    .option norelax
    .globl _start

.macro CRUN n
    .option rvc
    .rept \n
    c.nop
    .endr
    .option norvc
.endm

_start:
    .option norvc
    la      t0, trap_handler
    csrw    mtvec, t0
    lui     sp, %hi(_stack_top)
    addi    sp, sp, %lo(_stack_top)
    lui     s0, 0x40000             # UART base
    la      a0, msg_header
    jal     ra, print_string
    # Call the cached-DDR fetch-stall stream (absolute address; .ddr_text @ DDR).
    lui     t0, %hi(ddr_pattern)
    addi    t0, t0, %lo(ddr_pattern)
    jalr    ra, t0
    la      a0, msg_pass            # survived clean -> PASS
    jal     ra, print_string
done:
    .option rvc
    c.j     done
    .option norvc

    .balign 4
trap_handler:
    csrr    s1, mepc                # faulting PC (mid-instruction if +2 bug)
    la      a0, msg_trap
    jal     ra, print_string
    mv      a0, s1
    jal     ra, print_hex
    la      a0, msg_fail
    jal     ra, print_string
trap_done:
    .option rvc
    c.j     trap_done
    .option norvc

    .balign 4
print_string:
    mv      t2, a0
1:  lb      t1, 0(t2)
    beqz    t1, 2f
    sb      t1, 0(s0)
    addi    t2, t2, 1
    j       1b
2:  ret

    .balign 4
print_hex:
    mv      t2, a0
    li      t4, 28
1:  srl     t1, t2, t4
    andi    t1, t1, 0xf
    li      t5, 10
    blt     t1, t5, 2f
    addi    t1, t1, 0x57            # 'a'-10
    j       3f
2:  addi    t1, t1, 0x30            # '0'
3:  sb      t1, 0(s0)
    addi    t4, t4, -4
    bgez    t4, 1b
    ret

    .option pop

# ===== cached-DDR fetch-stall stream (fetched through the L1I) =====
    .section .ddr_text, "ax"
    .option push
    .option norelax
    .balign 32
ddr_pattern:
    .rept 300
    CRUN 3
    nop ; nop ; nop ; nop
    CRUN 4
    nop ; nop ; nop ; nop
    CRUN 5
    nop ; nop ; nop ; nop
    CRUN 6
    nop ; nop ; nop ; nop
    .endr
    .option norvc
    ret
    .option pop

    .section .rodata
msg_header: .asciz "=== fetch_stall_repro (ddr) ===\n"
msg_pass:   .asciz "\n<<PASS>>\n"
msg_trap:   .asciz "\nILLEGAL TRAP mepc="
msg_fail:   .asciz " <<FAIL>>\n"

    .section .bss
    .align 4
stack_bottom:
    .space 512
_stack_top:
