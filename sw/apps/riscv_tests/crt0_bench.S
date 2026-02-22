// Frost startup for riscv-tests benchmarks
//
// Benchmarks are C programs that use _init() as their entry point
// (defined in syscalls_frost.c). This crt0:
// 1. Zeroes all integer registers
// 2. Enables the FPU (mstatus.FS) and initializes FP registers
// 3. Sets up trap vector, stack pointer, global pointer
// 4. Copies .data from ROM to RAM, zeros BSS
// 5. Calls _init(cid=0, nc=1)

#include "encoding.h"

    .section .text.init
    .globl _start
_start:
    // Zero all integer registers
    li x1, 0
    li x2, 0
    li x3, 0
    li x4, 0
    li x5, 0
    li x6, 0
    li x7, 0
    li x8, 0
    li x9, 0
    li x10, 0
    li x11, 0
    li x12, 0
    li x13, 0
    li x14, 0
    li x15, 0
    li x16, 0
    li x17, 0
    li x18, 0
    li x19, 0
    li x20, 0
    li x21, 0
    li x22, 0
    li x23, 0
    li x24, 0
    li x25, 0
    li x26, 0
    li x27, 0
    li x28, 0
    li x29, 0
    li x30, 0
    li x31, 0

    // Enable FPU (set mstatus.FS to Initial)
    li t0, MSTATUS_FS
    csrs mstatus, t0

    // Initialize FP registers to zero (with mtvec guard for no-FPU case)
    la t0, 1f
    csrw mtvec, t0
    fssr x0
    fmv.s.x f0, x0
    fmv.s.x f1, x0
    fmv.s.x f2, x0
    fmv.s.x f3, x0
    fmv.s.x f4, x0
    fmv.s.x f5, x0
    fmv.s.x f6, x0
    fmv.s.x f7, x0
    fmv.s.x f8, x0
    fmv.s.x f9, x0
    fmv.s.x f10, x0
    fmv.s.x f11, x0
    fmv.s.x f12, x0
    fmv.s.x f13, x0
    fmv.s.x f14, x0
    fmv.s.x f15, x0
    fmv.s.x f16, x0
    fmv.s.x f17, x0
    fmv.s.x f18, x0
    fmv.s.x f19, x0
    fmv.s.x f20, x0
    fmv.s.x f21, x0
    fmv.s.x f22, x0
    fmv.s.x f23, x0
    fmv.s.x f24, x0
    fmv.s.x f25, x0
    fmv.s.x f26, x0
    fmv.s.x f27, x0
    fmv.s.x f28, x0
    fmv.s.x f29, x0
    fmv.s.x f30, x0
    fmv.s.x f31, x0
1:

    // Set up trap handler
    la t0, _frost_bench_trap
    csrw mtvec, t0

    // Initialize global pointer
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    // Initialize stack pointer
    la sp, _stack_top

    // Copy .data/.sdata from ROM to RAM
    la t0, __data_load_start
    la t1, __data_start
    la t2, __data_end
2:  beq t1, t2, 3f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 2b

    // Zero .sbss
3:  la t0, __sbss_start
    la t1, __sbss_end
4:  beq t0, t1, 5f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 4b

    // Zero .bss
5:  la t0, __bss_start
    la t1, __bss_end
6:  beq t0, t1, 7f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 6b

    // Call _init(cid=0, nc=1)
7:  li a0, 0
    li a1, 1
    call _init

    // If _init returns (shouldn't), halt
8:  j 8b

    // ---------------------------------------------------------------
    // Simple trap handler: saves context, calls handle_trap, restores
    // ---------------------------------------------------------------
    .align 2
_frost_bench_trap:
    addi sp, sp, -128

    sw x1,   4(sp)
    sw x5,  20(sp)
    sw x6,  24(sp)
    sw x7,  28(sp)
    sw x10, 40(sp)
    sw x11, 44(sp)
    sw x12, 48(sp)
    sw x13, 52(sp)
    sw x14, 56(sp)
    sw x15, 60(sp)
    sw x16, 64(sp)
    sw x17, 68(sp)
    sw x28, 112(sp)
    sw x29, 116(sp)
    sw x30, 120(sp)
    sw x31, 124(sp)

    csrr a0, mcause
    csrr a1, mepc
    mv a2, sp
    jal handle_trap
    csrw mepc, a0

    lw x1,   4(sp)
    lw x5,  20(sp)
    lw x6,  24(sp)
    lw x7,  28(sp)
    lw x10, 40(sp)
    lw x11, 44(sp)
    lw x12, 48(sp)
    lw x13, 52(sp)
    lw x14, 56(sp)
    lw x15, 60(sp)
    lw x16, 64(sp)
    lw x17, 68(sp)
    lw x28, 112(sp)
    lw x29, 116(sp)
    lw x30, 120(sp)
    lw x31, 124(sp)

    addi sp, sp, 128
    mret
