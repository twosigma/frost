// Frost ROM boot stub for the riscv-torture DDR memory config.
//
// In the ddr config the test image is linked into the cached DDR region:
// frost_header's _start, the test body, frost_footer, data and the signature
// area.  The core resets at PC=0 in the low instruction BRAM, so this stub is
// the only code in ROM.  It far-jumps to the DDR-resident _start, which is
// beyond JAL range, hence the register jump.  The bram config does not link
// this stub.  There, frost_header's _start already sits at 0x0.

    .section .boot, "ax", @progbits
    .globl _frost_torture_boot
_frost_torture_boot:
    // Under lp64, la (auipc) cannot reach the 0x8xxx_xxxx DDR _start from
    // ROM-at-0: the displacement exceeds PCREL_HI20's reach. Load the
    // absolute address from a local literal pool instead. norvc keeps the
    // tiny boot image all-native-width, matching crt0_riscv_tests_ddr.
    .option push
    .option norvc
    ld   t0, _frost_torture_boot_target
    jr   t0
    .align 3
_frost_torture_boot_target:
    .dword _start
    .option pop
