    // C runtime startup: sets sp and gp, copies the .data/.sdata load image
    // from ROM to RAM, zeros the BSS sections, then calls main(). The linker
    // scripts KEEP .init first in .text, so _start heads the program image.
    .section .init
    .option  push
    .option  norelax          // la gp must stay absolute; relaxation rewrites it gp-relative
    .globl  _start
_start:
    // sp starts at the top of the stack and grows down. gp is set 0x800 above
    // .sdata, so gp-relative accesses cover the small-data sections.
    la      sp, _stack_top
    la      gp, __global_pointer$

    // Copy the .data/.sdata load image from its ROM address to its RAM address.
    la      t0, __data_load_start
    la      t1, __data_start
    la      t2, __data_end
1:  beq     t1, t2, 2f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       1b

    // Zero .sbss, then .bss. C requires uninitialized globals to read as zero.
2:  la      t0, __sbss_start
    la      t1, __sbss_end
3:  beq     t0, t1, 4f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       3b

4:  la      t0, __bss_start
    la      t1, __bss_end
5:  beq     t0, t1, 6f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       5b

    // Zero the cached-region BSS (.ddr_bss). Unless the linker script places
    // zero-init sections in the DDR-backed cached region, the two bounds are
    // equal and the loop does not run; the freertos scripts instead PROVIDE
    // both symbols as 0.
    // lp64: la (auipc+addi) cannot reach the 0x8xxx_xxxx cached region from
    // the low-BRAM .init, because the displacement exceeds PCREL_HI20's +2 GiB
    // reach. Load the bounds from a local literal pool of absolute dwords
    // instead. Same class as the arch_test/riscv_tests boot stubs.
6:  ld      t0, ddr_bss_bounds
    ld      t1, ddr_bss_bounds+8
8:  bgeu    t0, t1, 9f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       8b

9:  call    main

    // main() is not expected to return; spin here if it does.
7:  j       7b

    .align  3
ddr_bss_bounds:
    .dword  __ddr_bss_start
    .dword  __ddr_bss_end

    .option  pop
