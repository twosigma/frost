// Frost footer for riscv-torture tests
//
// Included at the end of each adapted torture test.
// Provides the register dump and signature output mechanism:
//   1. Dumps all integer registers (x0-x31) to the signature area
//   2. Dumps all FP registers (f0-f31) to the signature area
//   3. Prints signature via UART as hex (like arch_test RVMODEL_HALT)
//   4. Prints <<PASS>> marker
//   5. Halts
//
// Integer registers dump at their natural width (sd/8B — D11's 64-bit
// signature layout), FP registers are 64-bit fsd (FLEN=64), and the UART
// dump loop is width-agnostic (32-bit words to the end label). Spike's
// tohost cell is HTIF-read at XLEN width, so it is dword-sized and
// sd-written.

#define XSTORE sd
#define XB 8

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

    // Save x5 (t0) — we stored the signature base in t0, but x5's original
    // value was clobbered. For torture tests, we save 0 as a placeholder.
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
    // HTIF reads the cell at XLEN width, so use the natural-width store.
    la a0, tohost
    li a1, 1
    XSTORE a1, 0(a0)

_frost_torture_halt:
    j _frost_torture_halt

    // tohost/fromhost for Spike (XLEN-wide cells; HTIF polls at XLEN
    // width). Layout must stay bit-exact: the committed references embed
    // _torture_data's address (x31 is dumped), so any layout drift would
    // invalidate the whole corpus.
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
