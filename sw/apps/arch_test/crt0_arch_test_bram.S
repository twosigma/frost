// FROST startup for riscv-arch-test, bram config
//
// The pinned arch_test.h never invokes RVMODEL_BOOT, so this stub does the
// startup work. _start lives in .init, which the linker places first. It
// copies .data/.sdata from ROM to RAM, zeroes .sbss/.bss, and jumps to the
// framework's rvtest_init entry point.
//
// A large .data load image can run past the ROM into RAM and overlap its
// destination (see link_arch_test_bram.ld). Copy backward so the startup
// behaves like memmove when dest > src.

    .section .init
    .globl _start
_start:
    // Copy .data/.sdata from ROM to RAM, backward-safe for overlapping ranges.
    la   t0, __data_load_start
    la   t1, __data_start
    la   t2, __data_end
    beq  t1, t2, 2f
    sub  t3, t2, t1
    add  t0, t0, t3
    mv   t4, t1
    mv   t1, t2
1:  addi t0, t0, -4
    addi t1, t1, -4
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    bne  t1, t4, 1b

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
