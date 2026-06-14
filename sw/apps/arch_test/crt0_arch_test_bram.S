// Frost minimal startup for riscv-arch-test (dev branch)
//
// On the dev branch, RVMODEL_BOOT is commented out in arch_test.h.
// This file provides _start in the .init section (placed first by
// the linker) which copies .data from ROM to RAM, zeros .bss, and
// jumps to the framework's rvtest_init entry point.

    .section .init
    .globl _start
_start:
    // Copy .data/.sdata from ROM to RAM
    la   t0, __data_load_start
    la   t1, __data_start
    la   t2, __data_end
1:  beq  t1, t2, 2f
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j    1b

    // Zero .sbss
2:  la   t0, __sbss_start
    la   t1, __sbss_end
3:  beq  t0, t1, 4f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    3b

    // Zero .bss
4:  la   t0, __bss_start
    la   t1, __bss_end
5:  beq  t0, t1, 6f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    5b

    // Jump to framework entry point
6:  j    rvtest_init
