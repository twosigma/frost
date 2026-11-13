// Startup for the Spike reference run: enable the vector and FP units, set
// the stack, zero BSS, call main and report its return value over HTIF.
    .section .text.init
    .globl _start
_start:
    li      t0, (3 << 9) | (3 << 13)    // mstatus.VS and FS = Dirty
    csrs    mstatus, t0
    csrwi   fcsr, 0
    .option push
    .option norelax
    la      gp, __global_pointer$
    la      sp, _stack_top
    .option pop
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:  call    main
    slli    a0, a0, 1
    ori     a0, a0, 1
    la      t0, tohost
    sd      a0, 0(t0)
3:  j       3b

    .section .tohost,"aw",@progbits
    .balign 64
    .globl  tohost
tohost:   .dword 0
    .globl  fromhost
fromhost: .dword 0
