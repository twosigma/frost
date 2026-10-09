// DDR reset stub. Jump from low-BRAM PC=0 to frost_header.S's _start in
// cached DDR. The BRAM configuration starts at _start without this stub.

    .section .boot, "ax", @progbits
    .globl _frost_torture_boot
_frost_torture_boot:
    // RV64 PCREL_HI20 cannot reach DDR from PC=0. Load the address from a
    // local literal pool. norvc keeps the stub's encodings 4 bytes wide.
    .option push
    .option norvc
    ld   t0, _frost_torture_boot_target
    jr   t0
    .align 3
_frost_torture_boot_target:
    .dword _start
    .option pop
