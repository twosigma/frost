// Frost minimal startup for riscv-tests ISA tests
//
// Provides _start in the .init section (placed first by the linker)
// which copies .data from ROM to RAM, zeros .bss, and jumps to the
// test's rvtest_entry_point (which is _start in .text.init, renamed
// by our build to avoid collision).
//
// This file is NOT used by ISA tests — they define their own _start
// via RVTEST_CODE_BEGIN. Instead, this startup is available for
// benchmark tests that need a C runtime.

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

    // Set up stack pointer and global pointer
    .option push
    .option norelax
    la   sp, _stack_top
    la   gp, __global_pointer$
    .option pop

    // Jump to main (for C benchmarks)
6:  call main

    // If main returns, halt
7:  j    7b
