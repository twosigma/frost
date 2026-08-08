// Frost ROM boot stub for the cocotb real-program DDR memory config.
//
// With MEM_CONFIG=ddr, common.mk (and the per-app Makefiles) link the whole
// program -- crt0.S's _start, or a custom app's own _start, plus code and data
// -- into the cached DDR region.  The core resets at PC=0 in the low
// instruction BRAM, so this minimal stub is the only code in ROM: it far-jumps
// to the DDR-resident _start (beyond JAL range, hence the register jump).  The
// bram config does not link this stub -- there, _start already sits at 0x0.

    .section .boot, "ax", @progbits
    .globl _frost_ddr_boot
_frost_ddr_boot:
#if __riscv_xlen == 64
    // lp64 + medany cannot reach the DDR-resident _start from this low-BRAM
    // stub (R_RISCV_PCREL_HI20 tops out ~2 GiB short), so materialize the DDR
    // origin as a constant instead: link_ddr.ld ASSERTs _start sits exactly at
    // ORIGIN(DDR) = 0x8000_0000. lui+slli builds it as a positive 64-bit value
    // (no lui sign-extension hazard), and .option norvc keeps the tiny ROM
    // image all-4-byte -- the proven shape from the riscv_tests DDR stub.
    .option push
    .option norvc
    lui  t0, 0x40000
    slli t0, t0, 1
    jr   t0
    .option pop
#else
    la   t0, _start
    jr   t0
#endif
