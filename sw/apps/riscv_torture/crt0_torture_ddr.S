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
#if __riscv_xlen == 64
    // lp64: la (auipc) cannot reach the 0x8xxx_xxxx DDR _start from ROM-at-0
    // (the displacement exceeds PCREL_HI20's reach), so load the absolute
    // address from a local literal pool. norvc keeps the tiny boot image
    // all-native-width per the rv64 boot-stub policy (crt0_riscv_tests_ddr).
    .option push
    .option norvc
    ld   t0, _frost_torture_boot_target
    jr   t0
    .align 3
_frost_torture_boot_target:
    .dword _start
    .option pop
#else
    la   t0, _start
    jr   t0
#endif
