// Frost ROM boot stub for the cocotb real-program DDR memory config.
//
// With MEM_CONFIG=ddr, common.mk and the per-app Makefiles link the whole
// program into the cached DDR region: crt0.S's _start, or a custom app's own
// _start, plus code and data.  The core resets at PC=0 in the low instruction
// BRAM, so this stub is the only code in ROM.  It jumps to the DDR-resident
// _start, which is out of JAL range and so needs a register jump.  The bram
// config does not link this stub; there _start already sits at 0x0.

    .section .boot, "ax", @progbits
    .globl _frost_ddr_boot
_frost_ddr_boot:
    // lp64 + medany cannot reach the DDR-resident _start from this low-BRAM
    // stub: R_RISCV_PCREL_HI20 tops out ~2 GiB short. Materialize the DDR
    // origin as a constant instead. link_ddr.ld ASSERTs that _start sits at
    // ORIGIN(DDR) = 0x8000_0000. lui+slli builds the address as a positive
    // 64-bit value, so there is no lui sign-extension hazard, and .option
    // norvc keeps the small ROM image all-4-byte. Same shape as the
    // riscv_tests DDR stub.
    .option push
    .option norvc
    lui  t0, 0x40000
    slli t0, t0, 1
    jr   t0
    .option pop
