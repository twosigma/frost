// FROST ROM boot stub for MEM_CONFIG=ddr builds.
//
// The core resets at PC=0 in low BRAM. This stub uses a register jump to
// reach _start in DDR, beyond JAL range. BRAM builds put _start at 0 and
// omit the stub.

    .section .boot, "ax", @progbits
    .globl _frost_ddr_boot
_frost_ddr_boot:
    // lp64 + medany cannot reach the DDR-resident _start from this low-BRAM
    // stub: R_RISCV_PCREL_HI20 reaches just under +2 GiB, short of
    // 0x8000_0000. Materialize the DDR origin as a constant instead.
    // link_ddr.ld and freertos_demo's link_freertos_ddr.ld ASSERT that _start
    // sits at ORIGIN(DDR) = 0x8000_0000.
    // lui+slli forms a positive 64-bit address; .option norvc keeps every
    // instruction four bytes wide.
    .option push
    .option norvc
    lui  t0, 0x40000
    slli t0, t0, 1
    jr   t0
    .option pop
