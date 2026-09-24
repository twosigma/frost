// FROST ROM boot stub for the riscv-tests DDR memory config.
//
// In the ddr config the test image is linked into the cached DDR region: the
// _start from RVTEST_CODE_BEGIN, env_v/entry.S (ENV=v), or crt0_bench.S, plus
// the code and data. This stub is the only code left in ROM, where the core
// resets at PC=0. It far-jumps to the DDR-resident _start, which is beyond JAL
// range, hence the register jump. The bram config does not link this stub;
// there, _start already sits at 0x0.
//
// Under lp64 the DDR-resident _start sits about 2 GiB above this stub, beyond
// PCREL_HI20 reach (la) and medlow's absolute lui range. _start is the DDR
// region base itself (linker ORIGIN 0x8000_0000), so the stub builds it as a
// constant with lui and slli, needing no relocation and no data-side load from
// the boot ROM.

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
