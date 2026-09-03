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

#if __riscv_xlen == 64
#define LREG ld
#define SREG sd
#define REGBYTES 8
#else
#error "Frost benchmark startup requires RV64"
#endif

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
    // Trap handler: saves the caller-saved registers in handle_trap's
    // XLEN-wide uintptr_t regs[32] layout, calls it, and restores them.
    // ---------------------------------------------------------------
    .align 2
_frost_bench_trap:
    addi sp, sp, -32*REGBYTES

    SREG x1,   1*REGBYTES(sp)
    SREG x5,   5*REGBYTES(sp)
    SREG x6,   6*REGBYTES(sp)
    SREG x7,   7*REGBYTES(sp)
    SREG x10, 10*REGBYTES(sp)
    SREG x11, 11*REGBYTES(sp)
    SREG x12, 12*REGBYTES(sp)
    SREG x13, 13*REGBYTES(sp)
    SREG x14, 14*REGBYTES(sp)
    SREG x15, 15*REGBYTES(sp)
    SREG x16, 16*REGBYTES(sp)
    SREG x17, 17*REGBYTES(sp)
    SREG x28, 28*REGBYTES(sp)
    SREG x29, 29*REGBYTES(sp)
    SREG x30, 30*REGBYTES(sp)
    SREG x31, 31*REGBYTES(sp)

    csrr a0, mcause
    csrr a1, mepc
    mv a2, sp
    jal handle_trap
    csrw mepc, a0

    LREG x1,   1*REGBYTES(sp)
    LREG x5,   5*REGBYTES(sp)
    LREG x6,   6*REGBYTES(sp)
    LREG x7,   7*REGBYTES(sp)
    LREG x10, 10*REGBYTES(sp)
    LREG x11, 11*REGBYTES(sp)
    LREG x12, 12*REGBYTES(sp)
    LREG x13, 13*REGBYTES(sp)
    LREG x14, 14*REGBYTES(sp)
    LREG x15, 15*REGBYTES(sp)
    LREG x16, 16*REGBYTES(sp)
    LREG x17, 17*REGBYTES(sp)
    LREG x28, 28*REGBYTES(sp)
    LREG x29, 29*REGBYTES(sp)
    LREG x30, 30*REGBYTES(sp)
    LREG x31, 31*REGBYTES(sp)

    addi sp, sp, 32*REGBYTES
    mret
