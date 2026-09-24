    // Startup for the Spike harness (see README.md); the FROST CoreMark build
    // uses sw/common/crt0.S. Spike enters at the ELF entry with
    // mstatus.FS = Off, so floating point must be enabled here or the first FP
    // instruction traps as illegal.
    .section .text.init
    .globl _start
_start:
    li      t0, 0x6000            // mstatus.FS = Dirty
    csrs    mstatus, t0
    la      sp, _stack_top
.option push
.option norelax
    la      gp, __global_pointer$
.option pop
    la      t0, __bss_start
    la      t1, __bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:  call    main
    // HTIF: a nonzero tohost with bit 0 set exits Spike. Two sw stores cover
    // the 8-byte field at either XLEN.
    la      t0, tohost
    li      t1, 1
    sw      t1, 0(t0)
    sw      zero, 4(t0)
3:  j       3b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .8byte 0
    .align 6
    .globl fromhost
fromhost:
    .8byte 0
