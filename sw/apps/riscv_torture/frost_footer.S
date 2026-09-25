// FROST footer for riscv-torture tests
//
// Included at the end of each torture test, where it:
//   1. Dumps all integer registers (x0-x31) to the signature area
//   2. Dumps all FP registers (f0-f31) to the signature area
//   3. Prints the signature over the UART as hex, one word per line
//   4. Prints the <<PASS>> marker
//   5. Writes tohost, which ends the Spike run, and halts
//
// Integer registers dump at their natural width (sd, 8 bytes). FP registers
// are 64-bit fsd (FLEN=64). The UART dump loop is width-agnostic: it walks
// 32-bit words to the end label.

#define XSTORE sd
#define XB 8

// Send the byte in \reg once the TX FIFO has room (UART_TX_STATUS, 0x28 past
// the UART base in a2, bit 0). Clobbers t6, whose value is already in the
// signature by then.
.macro frost_torture_putc reg
1:
    lw t6, 0x28(a2)
    andi t6, t6, 1
    beqz t6, 1b
    sb \reg, 0(a2)
.endm

    .text
    .globl _torture_test_end
_torture_test_end:
    // Store all integer registers to signature area.
    // Layout: 32 integer regs * XB bytes, then 32 FP regs * 8 bytes
    // (256 + 256 = 512 bytes). FP block starts at 32*XB (8-byte aligned).
    la t0, _frost_torture_signature

    // Store x0-x31 (x0 is always zero, x5/t0 is clobbered by la above)
    XSTORE x0,  (0*XB)(t0)
    XSTORE x1,  (1*XB)(t0)
    XSTORE x2,  (2*XB)(t0)
    XSTORE x3,  (3*XB)(t0)
    XSTORE x4,  (4*XB)(t0)
    // x5 (t0) saved below as 0 placeholder
    XSTORE x6,  (6*XB)(t0)
    XSTORE x7,  (7*XB)(t0)
    XSTORE x8,  (8*XB)(t0)
    XSTORE x9,  (9*XB)(t0)
    XSTORE x10, (10*XB)(t0)
    XSTORE x11, (11*XB)(t0)
    XSTORE x12, (12*XB)(t0)
    XSTORE x13, (13*XB)(t0)
    XSTORE x14, (14*XB)(t0)
    XSTORE x15, (15*XB)(t0)
    XSTORE x16, (16*XB)(t0)
    XSTORE x17, (17*XB)(t0)
    XSTORE x18, (18*XB)(t0)
    XSTORE x19, (19*XB)(t0)
    XSTORE x20, (20*XB)(t0)
    XSTORE x21, (21*XB)(t0)
    XSTORE x22, (22*XB)(t0)
    XSTORE x23, (23*XB)(t0)
    XSTORE x24, (24*XB)(t0)
    XSTORE x25, (25*XB)(t0)
    XSTORE x26, (26*XB)(t0)
    XSTORE x27, (27*XB)(t0)
    XSTORE x28, (28*XB)(t0)
    XSTORE x29, (29*XB)(t0)
    XSTORE x30, (30*XB)(t0)
    XSTORE x31, (31*XB)(t0)

    // x5 (t0) now holds the signature base, so its original value is gone.
    // Store 0 in its slot as a placeholder.
    XSTORE zero, (5*XB)(t0)

    // Store FP registers (as 64-bit doubles via fsd, 8 bytes each),
    // starting right after the integer block.
    fsd f0,  (32*XB + 0)(t0)
    fsd f1,  (32*XB + 8)(t0)
    fsd f2,  (32*XB + 16)(t0)
    fsd f3,  (32*XB + 24)(t0)
    fsd f4,  (32*XB + 32)(t0)
    fsd f5,  (32*XB + 40)(t0)
    fsd f6,  (32*XB + 48)(t0)
    fsd f7,  (32*XB + 56)(t0)
    fsd f8,  (32*XB + 64)(t0)
    fsd f9,  (32*XB + 72)(t0)
    fsd f10, (32*XB + 80)(t0)
    fsd f11, (32*XB + 88)(t0)
    fsd f12, (32*XB + 96)(t0)
    fsd f13, (32*XB + 104)(t0)
    fsd f14, (32*XB + 112)(t0)
    fsd f15, (32*XB + 120)(t0)
    fsd f16, (32*XB + 128)(t0)
    fsd f17, (32*XB + 136)(t0)
    fsd f18, (32*XB + 144)(t0)
    fsd f19, (32*XB + 152)(t0)
    fsd f20, (32*XB + 160)(t0)
    fsd f21, (32*XB + 168)(t0)
    fsd f22, (32*XB + 176)(t0)
    fsd f23, (32*XB + 184)(t0)
    fsd f24, (32*XB + 192)(t0)
    fsd f25, (32*XB + 200)(t0)
    fsd f26, (32*XB + 208)(t0)
    fsd f27, (32*XB + 216)(t0)
    fsd f28, (32*XB + 224)(t0)
    fsd f29, (32*XB + 232)(t0)
    fsd f30, (32*XB + 240)(t0)
    fsd f31, (32*XB + 248)(t0)

    // Dump the signature over the UART
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
    frost_torture_putc a5
    addi a4, a4, -4
    bge a4, zero, _frost_torture_hex_loop

    // Newline after each word
    li a5, '\n'
    frost_torture_putc a5
    addi a0, a0, 4
    j _frost_torture_sig_loop

_frost_torture_sig_done:
    // Print <<PASS>> marker
    li a2, 0x40000000
    li a5, '<'
    frost_torture_putc a5
    li a5, '<'
    frost_torture_putc a5
    li a5, 'P'
    frost_torture_putc a5
    li a5, 'A'
    frost_torture_putc a5
    li a5, 'S'
    frost_torture_putc a5
    li a5, 'S'
    frost_torture_putc a5
    li a5, '>'
    frost_torture_putc a5
    li a5, '>'
    frost_torture_putc a5
    li a5, '\n'
    frost_torture_putc a5

    // Signal completion via tohost (for Spike reference generation).
    // FROST does not monitor tohost, so on FROST this is a harmless store.
    la a0, tohost
    li a1, 1
    XSTORE a1, 0(a0)

_frost_torture_halt:
    j _frost_torture_halt

    // tohost/fromhost for Spike. The cells are XLEN-wide, and tohost is
    // written with sd, because HTIF polls at XLEN width.
    .section .tohost, "aw", @progbits
    .align 3
    .globl tohost
tohost:     .dword 0
    .globl fromhost
fromhost:   .dword 0

    // Signature area: 32 integer regs * XB bytes + 32 FP regs * 8 bytes
    // (512 bytes)
    .section .data
    .align 3
    .globl _frost_torture_signature
    .globl begin_signature
begin_signature:
_frost_torture_signature:
    .space (32*XB) + 256
    .globl _frost_torture_signature_end
    .globl end_signature
_frost_torture_signature_end:
end_signature:
