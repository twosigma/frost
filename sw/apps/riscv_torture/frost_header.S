// Frost header for riscv-torture tests
//
// Included at the top of each adapted torture test.
// Provides _start in .text.init that:
//   1. Copies .data from ROM to RAM
//   2. Zeros BSS
//   3. Sets up stack pointer and global pointer
//   4. Enables FPU (mstatus.FS)
//   5. Sets up trap vector
//   6. Falls through to the torture test code

#include "encoding.h"

    .section .text.init
    .globl _start
_start:
    // Set up stack pointer and global pointer
    .option push
    .option norelax
    la sp, _stack_top
    la gp, __global_pointer$
    .option pop

    // Copy .data/.sdata from ROM to RAM
    la t0, __data_load_start
    la t1, __data_start
    la t2, __data_end
1:  beq t1, t2, 2f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b

    // Zero .sbss
2:  la t0, __sbss_start
    la t1, __sbss_end
3:  beq t0, t1, 4f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 3b

    // Zero .bss
4:  la t0, __bss_start
    la t1, __bss_end
5:  beq t0, t1, 6f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 5b

    // Enable FPU (mstatus.FS = Initial)
6:  li t0, MSTATUS_FS
    csrs mstatus, t0
    csrwi fcsr, 0

    // Set up trap vector (unhandled traps -> fail)
    la t0, _frost_torture_trap
    csrw mtvec, t0

    // Jump to torture test entry point
    j _torture_test_begin

    // Trap handler: print mcause/mepc diagnostics, then <<FAIL>> TRAP
    .align 2
_frost_torture_trap:
    li t0, 0x40000000

    // Print "mc=<mcause_hex> mepc=<mepc_hex>\n"
    li t1, 'm'
    sb t1, 0(t0)
    li t1, 'c'
    sb t1, 0(t0)
    li t1, '='
    sb t1, 0(t0)
    csrr t2, mcause
    li t3, 28
_trap_hex_mcause:
    srl t1, t2, t3
    andi t1, t1, 0xf
    li t4, 10
    blt t1, t4, _trap_mcause_digit
    addi t1, t1, ('a' - 10)
    j _trap_mcause_out
_trap_mcause_digit:
    addi t1, t1, '0'
_trap_mcause_out:
    sb t1, 0(t0)
    addi t3, t3, -4
    bge t3, zero, _trap_hex_mcause
    li t1, ' '
    sb t1, 0(t0)
    li t1, 'm'
    sb t1, 0(t0)
    li t1, 'e'
    sb t1, 0(t0)
    li t1, 'p'
    sb t1, 0(t0)
    li t1, 'c'
    sb t1, 0(t0)
    li t1, '='
    sb t1, 0(t0)
    csrr t2, mepc
    li t3, 28
_trap_hex_mepc:
    srl t1, t2, t3
    andi t1, t1, 0xf
    li t4, 10
    blt t1, t4, _trap_mepc_digit
    addi t1, t1, ('a' - 10)
    j _trap_mepc_out
_trap_mepc_digit:
    addi t1, t1, '0'
_trap_mepc_out:
    sb t1, 0(t0)
    addi t3, t3, -4
    bge t3, zero, _trap_hex_mepc
    li t1, '\n'
    sb t1, 0(t0)

    // Print <<FAIL>> TRAP
    li t1, '<'
    sb t1, 0(t0)
    li t1, '<'
    sb t1, 0(t0)
    li t1, 'F'
    sb t1, 0(t0)
    li t1, 'A'
    sb t1, 0(t0)
    li t1, 'I'
    sb t1, 0(t0)
    li t1, 'L'
    sb t1, 0(t0)
    li t1, '>'
    sb t1, 0(t0)
    li t1, '>'
    sb t1, 0(t0)
    li t1, '\n'
    sb t1, 0(t0)
_frost_torture_trap_halt:
    j _frost_torture_trap_halt
