// Frost ROM boot stub for the riscv-torture DDR memory config.
//
// In the ddr config the test image (frost_header's _start, the test body,
// frost_footer, data and the signature area) is linked into the cached DDR
// region.  The core resets at PC=0 in the low instruction BRAM, so this
// minimal stub is the only code in ROM: it far-jumps to the DDR-resident
// _start (beyond JAL range, hence the register jump).  The bram config does
// not link this stub -- there, frost_header's _start already sits at 0x0.

    .section .boot, "ax", @progbits
    .globl _frost_torture_boot
_frost_torture_boot:
    la   t0, _start
    jr   t0
