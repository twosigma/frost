// Frost ROM boot stub for the riscv-tests DDR memory config.
//
// In the ddr config the test image -- an ISA test's RVTEST_CODE_BEGIN _start
// (or a benchmark's crt0_bench _start) plus code and data -- is linked into
// the cached DDR region.  The core resets at PC=0 in the low instruction BRAM,
// so this minimal stub is the only code in ROM: it far-jumps to the
// DDR-resident _start (beyond JAL range, hence the register jump).  The bram
// config does not link this stub -- there, _start already sits at 0x0.
//
// Under lp64 the DDR-resident _start sits ~2 GiB above this stub -- beyond
// PCREL_HI20 reach (la) and medlow's absolute lui range.  _start is the
// DDR region base itself (linker ORIGIN 0x8000_0000), so the RV64 build
// materializes it as a constant: gas's li emits an exact positive 64-bit
// sequence, needing no relocation and no data-side load from the boot
// ROM.  The RV32 path is bit-identical.

    .section .boot, "ax", @progbits
    .globl _frost_riscv_tests_boot
_frost_riscv_tests_boot:
#if __riscv_xlen == 64
    // All-native-width encodings, no loads: lui 0x40000 = 0x4000_0000
    // (positive), shifted left once = 0x8000_0000 with no
    // sign-extension. norvc is load-bearing: compressed instructions in
    // this tiny boot image wedge rv64 fetch (a fetch-seam edge under
    // investigation with the M5 width work); native-width encodings
    // sidestep it and are what a boot ROM wants anyway.
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
