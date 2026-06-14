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
    la   t0, _start
    jr   t0
