// Frost minimal startup for riscv-arch-test (dev branch)
//
// On the dev branch, RVMODEL_BOOT is commented out in arch_test.h.
// This file provides _start in the .init section -- the only code in the
// low BRAM ROM; the test itself lives in the cached DDR region. The DDR
// image loads in place (LMA == VMA), so there is no data copy: just zero
// .sbss/.bss and far-jump to the framework's rvtest_init entry point
// (beyond JAL range, hence the register jump).

    .section .init
    .globl _start
_start:
    // Zero .sbss
    la   t0, __sbss_start
    la   t1, __sbss_end
1:  beq  t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b

    // Zero .bss
2:  la   t0, __bss_start
    la   t1, __bss_end
3:  beq  t0, t1, 4f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    3b

    // Far jump to the DDR-resident framework entry point
4:  la   t0, rvtest_init
    jr   t0
