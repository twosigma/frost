// Torture-test startup: initialize memory, the FPU and trap handling, then
// enter _torture_test_begin. FROST_PAGED enters S-mode through MRET.

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

    // Enable the FPU (mstatus.FS = Dirty) and clear fcsr
6:  li t0, MSTATUS_FS
    csrs mstatus, t0
    csrwi fcsr, 0

    // Set up trap vector (unhandled traps -> fail)
    la t0, _frost_torture_trap
    csrw mtvec, t0

#ifdef FROST_PAGED
    // Run the body and signature dump in S-mode through Sv39 1 GiB leaves.
    // The root table must be in cached DDR, the only memory the walker reads.
    // Identity-map low memory RWX, devices RW and DDR RWX. Set A and D to
    // avoid Svade faults. medeleg=0 keeps traps in M-mode.
    la t0, _frost_torture_root_pt
    li t1, 0xCF                                   // V|R|W|X|A|D, PPN 0
    sd t1, 0(t0)
    li t1, ((0x40000000 >> 12) << 10) | 0xC7      // V|R|W|A|D (no X)
    sd t1, 8(t0)
    li t1, ((0x80000000 >> 12) << 10) | 0xCF      // V|R|W|X|A|D
    sd t1, 16(t0)
    sfence.vma
    srli t1, t0, 12
    li t2, 8
    slli t2, t2, 60                               // satp.MODE = Sv39
    or t1, t1, t2
    csrw satp, t1
    li t1, 0x1800
    csrc mstatus, t1
    li t1, 0x0800                                 // MPP = S
    csrs mstatus, t1
    la t0, _torture_test_begin
    csrw mepc, t0
    mret
#else
    j _torture_test_begin
#endif

    // Trap handler: print mcause/mepc, then <<FAIL>>, then halt
    .align 2
_frost_torture_trap:
    li t0, 0x40000000

    // Print "mc=<mcause_hex> mepc=<mepc_hex>\n", low 32 bits of each
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

    // Print the <<FAIL>> marker
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

#ifdef FROST_PAGED
    .section .data
    .balign 4096
_frost_torture_root_pt:
    .space 4096
    .text
#endif
