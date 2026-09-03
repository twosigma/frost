// Frost minimal startup for riscv-arch-test (dev branch)
//
// On the dev branch, RVMODEL_BOOT is commented out in arch_test.h.
// _start lives in the .init section, the only code in the low BRAM ROM; the
// test itself lives in the cached DDR region. The DDR image loads in place
// (LMA == VMA), so there is no data copy: the stub zeroes .sbss/.bss and
// far-jumps to the framework's rvtest_init entry point, which is beyond JAL
// range, hence the register jump.
//
// Under lp64 the DDR-resident symbols sit ~2 GiB above this stub, beyond
// both PCREL_HI20 reach (la) and medlow's absolute lui range, so the stub
// takes their absolute addresses from a local literal pool (R_RISCV_64
// relocations always resolve).

    .section .init
    .globl _start
_start:
    // Zero .sbss
    la   t2, 9f
    ld   t0, 0(t2)          // __sbss_start
    ld   t1, 8(t2)          // __sbss_end
1:  beq  t0, t1, 2f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    1b

    // Zero .bss
2:  ld   t0, 16(t2)         // __bss_start
    ld   t1, 24(t2)         // __bss_end
3:  beq  t0, t1, 4f
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    3b

    // Far jump to the DDR-resident framework entry point
4:  ld   t0, 32(t2)         // rvtest_init
    jr   t0

    .balign 8
9:  .dword __sbss_start
    .dword __sbss_end
    .dword __bss_start
    .dword __bss_end
    .dword rvtest_init
