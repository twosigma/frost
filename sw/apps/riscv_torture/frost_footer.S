// Frost footer for riscv-torture tests
//
// Included at the end of each adapted torture test.
// Provides the register dump and signature output mechanism:
//   1. Dumps all integer registers (x0-x31) to the signature area
//   2. Dumps all FP registers (f0-f31) to the signature area
//   3. Prints signature via UART as hex (like arch_test RVMODEL_HALT)
//   4. Prints <<PASS>> marker
//   5. Halts

    .text
    .globl _torture_test_end
_torture_test_end:
    // Store all integer registers to signature area
    // Layout: 32 integer regs * 4 bytes = 128 bytes, then 32 FP regs * 8 bytes = 256 bytes
    // Total: 384 bytes. FP starts at offset 128 (8-byte aligned for fsd).
    la t0, _frost_torture_signature

    // Store x0-x31 (x0 is always zero, x5/t0 is clobbered by la above)
    sw x0,   0(t0)
    sw x1,   4(t0)
    sw x2,   8(t0)
    sw x3,  12(t0)
    sw x4,  16(t0)
    // x5 (t0) saved below as 0 placeholder
    sw x6,  24(t0)
    sw x7,  28(t0)
    sw x8,  32(t0)
    sw x9,  36(t0)
    sw x10, 40(t0)
    sw x11, 44(t0)
    sw x12, 48(t0)
    sw x13, 52(t0)
    sw x14, 56(t0)
    sw x15, 60(t0)
    sw x16, 64(t0)
    sw x17, 68(t0)
    sw x18, 72(t0)
    sw x19, 76(t0)
    sw x20, 80(t0)
    sw x21, 84(t0)
    sw x22, 88(t0)
    sw x23, 92(t0)
    sw x24, 96(t0)
    sw x25, 100(t0)
    sw x26, 104(t0)
    sw x27, 108(t0)
    sw x28, 112(t0)
    sw x29, 116(t0)
    sw x30, 120(t0)
    sw x31, 124(t0)

    // Save x5 (t0) — we stored the signature base in t0, but x5's original
    // value was clobbered. For torture tests, we save 0 as a placeholder.
    sw zero, 20(t0)

    // Store FP registers (as 64-bit doubles via fsd, 8 bytes each)
    // Offset starts at 128 (32 integer regs * 4 bytes), 8-byte aligned
    fsd f0,  128(t0)
    fsd f1,  136(t0)
    fsd f2,  144(t0)
    fsd f3,  152(t0)
    fsd f4,  160(t0)
    fsd f5,  168(t0)
    fsd f6,  176(t0)
    fsd f7,  184(t0)
    fsd f8,  192(t0)
    fsd f9,  200(t0)
    fsd f10, 208(t0)
    fsd f11, 216(t0)
    fsd f12, 224(t0)
    fsd f13, 232(t0)
    fsd f14, 240(t0)
    fsd f15, 248(t0)
    fsd f16, 256(t0)
    fsd f17, 264(t0)
    fsd f18, 272(t0)
    fsd f19, 280(t0)
    fsd f20, 288(t0)
    fsd f21, 296(t0)
    fsd f22, 304(t0)
    fsd f23, 312(t0)
    fsd f24, 320(t0)
    fsd f25, 328(t0)
    fsd f26, 336(t0)
    fsd f27, 344(t0)
    fsd f28, 352(t0)
    fsd f29, 360(t0)
    fsd f30, 368(t0)
    fsd f31, 376(t0)

    // Now dump the signature via UART (same pattern as arch_test RVMODEL_HALT)
    la a0, _frost_torture_signature
    la a1, _frost_torture_signature_end
    li a2, 0x40000000

_frost_torture_sig_loop:
    bgeu a0, a1, _frost_torture_sig_done
    lw a3, 0(a0)

    // Print 32-bit word as 8 lowercase hex chars
    li a4, 28
_frost_torture_hex_loop:
    srl a5, a3, a4
    andi a5, a5, 0xf
    li a6, 10
    blt a5, a6, _frost_torture_hex_digit
    addi a5, a5, ('a' - 10)
    j _frost_torture_hex_out
_frost_torture_hex_digit:
    addi a5, a5, '0'
_frost_torture_hex_out:
    sb a5, 0(a2)
    addi a4, a4, -4
    bge a4, zero, _frost_torture_hex_loop

    // Newline after each word
    li a5, '\n'
    sb a5, 0(a2)
    addi a0, a0, 4
    j _frost_torture_sig_loop

_frost_torture_sig_done:
    // Print <<PASS>> marker
    li a2, 0x40000000
    li a5, '<'
    sb a5, 0(a2)
    li a5, '<'
    sb a5, 0(a2)
    li a5, 'P'
    sb a5, 0(a2)
    li a5, 'A'
    sb a5, 0(a2)
    li a5, 'S'
    sb a5, 0(a2)
    li a5, 'S'
    sb a5, 0(a2)
    li a5, '>'
    sb a5, 0(a2)
    li a5, '>'
    sb a5, 0(a2)
    li a5, '\n'
    sb a5, 0(a2)

    // Signal completion via tohost (for Spike reference generation).
    // On Frost hardware, tohost is not monitored so this is a harmless store.
    la a0, tohost
    li a1, 1
    sw a1, 0(a0)

_frost_torture_halt:
    j _frost_torture_halt

    // tohost/fromhost for Spike
    .section .tohost, "aw", @progbits
    .align 2
    .globl tohost
tohost:     .word 0
    .globl fromhost
fromhost:   .word 0

    // Signature area: 32 integer regs * 4 bytes + 32 FP regs * 8 bytes = 384 bytes
    .section .data
    .align 3
    .globl _frost_torture_signature
    .globl begin_signature
begin_signature:
_frost_torture_signature:
    .space 384
    .globl _frost_torture_signature_end
    .globl end_signature
_frost_torture_signature_end:
end_signature:
