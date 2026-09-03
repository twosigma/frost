// Frost minimal C-runtime startup for riscv-tests
//
// _start in the .init section (placed first by the linker script) copies
// .data from ROM to RAM, zeros .sbss and .bss, sets sp and gp, and calls
// main.
//
// Neither Makefile nor Makefile.bench references this file: ISA tests define
// their own _start via RVTEST_CODE_BEGIN, and benchmarks build crt0_bench.S,
// which calls _init instead of main.

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

    // Call main
6:  call main

    // If main returns, halt
7:  j    7b
