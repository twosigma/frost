// Frost ROM boot stub for the riscv-tests DDR memory config.
//
// In the ddr config the test image -- an ISA test's RVTEST_CODE_BEGIN _start
// (or a benchmark's crt0_bench _start) plus code and data -- is linked into
// the cached DDR region.  The core resets at PC=0 in the low instruction BRAM,
// so this minimal stub is the only code in ROM: it far-jumps to the
// DDR-resident _start (beyond JAL range, hence the register jump).  The bram
// config does not link this stub -- there, _start already sits at 0x0.

    .section .boot, "ax", @progbits
    .globl _frost_riscv_tests_boot
_frost_riscv_tests_boot:
    la   t0, _start
    jr   t0
