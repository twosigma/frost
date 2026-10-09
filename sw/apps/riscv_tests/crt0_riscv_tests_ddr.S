// Reset stub for the DDR configuration. Jump from PC=0 to _start at
// 0x8000_0000, beyond JAL and RV64 PCREL_HI20 reach. Construct the address
// without a relocation or ROM data load. link_riscv_tests_ddr.ld and
// link_riscv_tests_v.ld assert that _start is at the DDR origin.

    .section .boot, "ax", @progbits
    .globl _frost_riscv_tests_boot
_frost_riscv_tests_boot:
    // lui 0x40000 gives 0x4000_0000 (positive), and one left shift gives
    // 0x8000_0000 with no sign extension; lui 0x80000 would sign-extend on
    // RV64. norvc keeps the stub in 4-byte encodings.
    .option push
    .option norvc
    lui  t0, 0x40000
    slli t0, t0, 1
    jr   t0
    .option pop
