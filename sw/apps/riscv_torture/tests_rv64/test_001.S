// Generated RV64IMAFDC torture test for Frost (seed=20260803)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x245a75bbdde5c48c
    li x4, 0xa17e50c587f27014
    li x5, 0xcd6aa6521048a8c3
    li x6, 0xa7e72fb8c199a09d
    li x7, 0x47437270c7d6842f
    li x8, 0x24c0a6e312303c8c
    li x9, 0xe8ccb5623b20d7e5
    li x10, 0x6ed4a6d00a52e5fc
    li x11, 0xe6c77eab32ca64fc
    li x12, 0xdd8cf7ee4012a0e5
    li x13, 0x142144fa7e765da5
    li x14, 0x8293700f138174a2
    li x15, 0x3cb6b1a202f7f1d7
    li x16, 0x7adad9b8f4f5d81f
    li x17, 0x0e39e0b8dc5c20f4
    li x18, 0xa798bc16134fe8c1
    li x19, 0x5fb72a2179e9d409
    li x20, 0xe782137ef71002dc
    li x21, 0x26c57307aa270c49
    li x22, 0x8a5263033d099619
    li x23, 0xdfd8f09aa831afb1
    li x24, 0x747666dc15b96821
    li x25, 0x82fbf9189810c99d
    li x26, 0x28d4565e778c46cd
    li x27, 0xeb3a4b41a8e2ad47
    li x28, 0x3e2b120b7a7386d5
    li x29, 0x0b33acfea608721a
    la x31, _torture_data

    // Initialize FP registers from data section
    la x1, _torture_fp_init
    fld f0, 0(x1)
    fld f1, 8(x1)
    fld f2, 16(x1)
    fld f3, 24(x1)
    fld f4, 32(x1)
    fld f5, 40(x1)
    fld f6, 48(x1)
    fld f7, 56(x1)
    fld f8, 64(x1)
    fld f9, 72(x1)
    fld f10, 80(x1)
    fld f11, 88(x1)
    fld f12, 96(x1)
    fld f13, 104(x1)
    fld f14, 112(x1)
    fld f15, 120(x1)
    fld f16, 128(x1)
    fld f17, 136(x1)
    fld f18, 144(x1)
    fld f19, 152(x1)
    fld f20, 160(x1)
    fld f21, 168(x1)
    fld f22, 176(x1)
    fld f23, 184(x1)
    fld f24, 192(x1)
    fld f25, 200(x1)
    fld f26, 208(x1)
    fld f27, 216(x1)
    fld f28, 224(x1)
    fld f29, 232(x1)
    fld f30, 240(x1)
    fld f31, 248(x1)
    li x1, 0xb1c669cc21d28ca0

    fmin.d f15, f7, f31
    fnmadd.s f9, f13, f9, f7
    slliw x22, x12, 13
    add x5, x27, x10
    bgeu x22, x18, _br_taken_0
    sra x29, x20, x5
    j _br_done_0
_br_taken_0:
    sub x29, x21, x13
_br_done_0:
    bltu x13, x29, _br_taken_1
    sub x19, x6, x20
    j _br_done_1
_br_taken_1:
    srl x19, x5, x14
_br_done_1:
    bltu x23, x26, _br_taken_2
    add x5, x12, x4
    j _br_done_2
_br_taken_2:
    or x5, x10, x6
_br_done_2:
    addi x30, x31, 224
    amomaxu.w x12, x6, (x30)
    srl x29, x16, x16
    addiw x22, x17, 1400
    sraiw x13, x18, 21
    ld x22, 512(x31)
    sd x20, 512(x31)
    sltu x8, x6, x29
    srli x1, x5, 13
    addw x8, x24, x11
    mulw x18, x5, x29
    mul x26, x11, x28
    sra x6, x23, x10
    srai x18, x8, 15
    or x5, x11, x13
    ori x19, x24, 1931
    lwu x12, 128(x31)
    sw x18, 128(x31)
    bgeu x1, x4, _br_taken_3
    or x10, x25, x21
    j _br_done_3
_br_taken_3:
    slt x10, x7, x9
_br_done_3:
    srai x27, x25, 0
    divuw x18, x15, x4
    mulw x24, x24, x19
    sraiw x11, x24, 13
    srai x24, x22, 1
    xori x15, x13, 576
    slti x14, x12, -1810
    bne x10, x11, _br_taken_4
    sub x4, x17, x24
    j _br_done_4
_br_taken_4:
    srl x4, x12, x14
_br_done_4:
    bgeu x16, x1, _br_taken_5
    sra x17, x4, x1
    j _br_done_5
_br_taken_5:
    sltu x17, x14, x23
_br_done_5:
    srli x17, x15, 43
    sltiu x26, x22, -1274
    sllw x21, x10, x11
    srai x15, x7, 27
    beq x1, x22, _br_taken_6
    srl x16, x16, x26
    j _br_done_6
_br_taken_6:
    sll x16, x26, x27
_br_done_6:
    sub x10, x16, x27
    sraiw x7, x21, 20
    srli x10, x5, 63
    fmax.s f15, f7, f30
    fmul.s f18, f27, f15
    fmadd.d f2, f15, f3, f27
    ori x21, x1, -1137
    and x24, x9, x7
    sllw x4, x26, x6
    srlw x20, x25, x16
    or x20, x19, x5
    slt x5, x11, x8
    srai x10, x20, 30
    and x9, x24, x9
    sra x8, x17, x10
    andi x14, x12, 399
    lw x6, 104(x31)
    sw x13, 104(x31)
    slli x14, x23, 54
    bne x9, x12, _br_taken_7
    add x28, x11, x27
    j _br_done_7
_br_taken_7:
    and x28, x25, x25
_br_done_7:
    ori x13, x10, -926
    srai x5, x9, 51
    addi x12, x24, 1827
    lh x13, 80(x31)
    sh x7, 80(x31)
    lbu x22, 308(x31)
    sb x19, 308(x31)
    addiw x5, x9, -448
    ori x19, x27, -1934
    fmsub.s f8, f17, f17, f30
    fadd.d f1, f4, f1
    fadd.s f21, f27, f3
    addiw x20, x25, -268
    sraiw x17, x17, 7
    addi x30, x31, 200
    amoadd.w x13, x25, (x30)
    addi x30, x31, 68
    amomin.w x17, x17, (x30)
    sraiw x27, x27, 16
    subw x12, x11, x15
    beq x15, x27, _br_taken_8
    sll x21, x16, x19
    j _br_done_8
_br_taken_8:
    add x21, x29, x28
_br_done_8:
    sltu x27, x27, x27
    fsub.d f7, f24, f7
    lhu x13, 48(x31)
    sh x14, 48(x31)
    ori x7, x22, 1227
    srli x12, x10, 19
    add x27, x17, x29
    lh x24, 364(x31)
    sh x18, 364(x31)
    addiw x20, x6, 159
    sltu x24, x6, x18
    and x23, x26, x5
    andi x24, x11, -781
    or x6, x17, x1
    xor x21, x9, x10
    xori x28, x9, 1228
    sraw x17, x17, x28
    subw x15, x12, x22
    bltu x17, x19, _br_taken_9
    sub x8, x1, x17
    j _br_done_9
_br_taken_9:
    sra x8, x19, x9
_br_done_9:
    fdiv.s f10, f29, f4
    fmin.d f15, f31, f13
    fnmsub.d f30, f27, f6, f24
    blt x10, x27, _br_taken_10
    sra x14, x22, x14
    j _br_done_10
_br_taken_10:
    add x14, x10, x8
_br_done_10:
    addi x30, x31, 384
    amoadd.d x19, x25, (x30)
    sraiw x19, x1, 6
    lw x23, 388(x31)
    sw x12, 388(x31)
    fmadd.s f24, f21, f19, f26
    fmax.d f23, f2, f20
    and x19, x27, x7
    addiw x9, x28, -115
    slt x28, x22, x18
    sll x25, x28, x24
    and x16, x4, x13
    andi x19, x11, -981
    andi x9, x5, 1571
    sltu x22, x4, x16
    and x21, x12, x14
    lwu x17, 784(x31)
    sw x4, 784(x31)
    fmin.d f4, f7, f23
    ori x7, x9, 1960
    sraiw x5, x17, 29
    bgeu x9, x26, _br_taken_11
    and x23, x10, x7
    j _br_done_11
_br_taken_11:
    add x23, x13, x14
_br_done_11:
    bltu x19, x29, _br_taken_12
    add x24, x24, x19
    j _br_done_12
_br_taken_12:
    or x24, x10, x28
_br_done_12:
    bne x21, x28, _br_taken_13
    sra x9, x28, x11
    j _br_done_13
_br_taken_13:
    sra x9, x23, x26
_br_done_13:
    sltiu x8, x9, -540
    addw x19, x8, x27
    bltu x15, x15, _br_taken_14
    and x7, x24, x22
    j _br_done_14
_br_taken_14:
    srl x7, x16, x16
_br_done_14:
    and x8, x19, x25
    sllw x13, x15, x24
    sltu x8, x11, x4
    bgeu x26, x14, _br_taken_15
    srl x8, x26, x27
    j _br_done_15
_br_taken_15:
    sra x8, x9, x25
_br_done_15:
    fnmsub.s f16, f7, f6, f14
    fmax.d f26, f17, f10
    xor x11, x18, x27
    sltiu x20, x13, 1154
    add x4, x18, x4
    or x22, x8, x8
    addi x23, x7, -1742
    srliw x15, x17, 26
    add x12, x20, x29
    blt x20, x7, _br_taken_16
    or x11, x11, x24
    j _br_done_16
_br_taken_16:
    sub x11, x29, x11
_br_done_16:
    mul x6, x4, x21
    mulw x11, x20, x25
    and x26, x26, x24
    srliw x27, x14, 11
    and x25, x21, x21
    blt x12, x6, _br_taken_17
    sub x1, x19, x19
    j _br_done_17
_br_taken_17:
    or x1, x17, x17
_br_done_17:
    sraw x19, x23, x8
    bgeu x13, x16, _br_taken_18
    sll x21, x9, x7
    j _br_done_18
_br_taken_18:
    sltu x21, x28, x24
_br_done_18:
    bltu x15, x12, _br_taken_19
    slt x5, x21, x6
    j _br_done_19
_br_taken_19:
    slt x5, x9, x15
_br_done_19:
    fmin.d f18, f1, f9
    bge x13, x19, _br_taken_20
    sra x17, x9, x10
    j _br_done_20
_br_taken_20:
    and x17, x12, x24
_br_done_20:
    bne x9, x21, _br_taken_21
    add x26, x4, x1
    j _br_done_21
_br_taken_21:
    xor x26, x25, x20
_br_done_21:
    xor x26, x19, x22
    slti x11, x7, -762
    addw x15, x12, x20
    srliw x11, x18, 9
    addi x22, x18, 401
    srli x26, x23, 3
    srl x23, x4, x29
    srlw x26, x17, x15
    slliw x9, x4, 22
    and x12, x13, x17
    sraw x13, x4, x24
    addw x1, x24, x22
    add x13, x7, x13
    bgeu x12, x24, _br_taken_22
    sltu x20, x15, x8
    j _br_done_22
_br_taken_22:
    slt x20, x29, x10
_br_done_22:
    addw x1, x28, x9
    srli x14, x11, 38
    srliw x23, x8, 18
    bltu x1, x5, _br_taken_23
    add x4, x13, x13
    j _br_done_23
_br_taken_23:
    srl x4, x20, x19
_br_done_23:
    xor x20, x11, x6
    sraw x27, x15, x15
    srai x15, x10, 54
    fnmadd.s f16, f14, f4, f14
    xor x12, x11, x23
    sltu x9, x15, x28
    slliw x20, x22, 28
    or x19, x16, x29
    xori x16, x28, 1828
    sub x11, x9, x13
    xori x8, x24, 1775
    addw x26, x17, x14
    srlw x17, x9, x23
    slti x5, x4, 735
    fsub.s f14, f13, f2
    fmax.d f7, f25, f10
    fmin.d f9, f31, f2
    fadd.d f31, f31, f14
    fmadd.d f28, f23, f10, f15
    blt x6, x29, _br_taken_24
    slt x23, x6, x23
    j _br_done_24
_br_taken_24:
    sra x23, x26, x28
_br_done_24:
    remuw x8, x6, x10
    sraiw x15, x19, 10
    andi x4, x29, 1114
    srli x22, x19, 44
    fmax.s f25, f19, f23
    lw x8, 580(x31)
    sw x25, 580(x31)
    addi x30, x31, 560
    amomin.d x23, x15, (x30)
    andi x11, x23, 1935
    srlw x24, x24, x23
    fnmadd.s f11, f5, f13, f15
    addw x7, x7, x29
    sll x1, x28, x26
    sra x18, x23, x7
    bgeu x16, x13, _br_taken_25
    slt x12, x23, x13
    j _br_done_25
_br_taken_25:
    xor x12, x28, x4
_br_done_25:
    sllw x17, x13, x11
    bge x8, x12, _br_taken_26
    sltu x12, x21, x23
    j _br_done_26
_br_taken_26:
    srl x12, x21, x24
_br_done_26:
    srli x8, x10, 7
    beq x23, x21, _br_taken_27
    sll x4, x19, x10
    j _br_done_27
_br_taken_27:
    sub x4, x13, x20
_br_done_27:
    slliw x17, x25, 24
    subw x29, x27, x5
    and x19, x5, x23
    addi x30, x31, 376
    amoand.w x11, x12, (x30)
    bne x25, x1, _br_taken_28
    slt x6, x7, x28
    j _br_done_28
_br_taken_28:
    slt x6, x28, x4
_br_done_28:
    remw x22, x13, x20
    sraw x16, x8, x10
    srai x4, x19, 22
    fdiv.s f0, f27, f17
    sllw x6, x5, x25
    slli x14, x6, 20
    addw x19, x27, x9
    beq x19, x29, _br_taken_29
    slt x9, x22, x29
    j _br_done_29
_br_taken_29:
    srl x9, x7, x27
_br_done_29:
    slt x28, x1, x18
    xor x24, x20, x16
    slli x26, x25, 15
    sraiw x17, x23, 19
    srl x18, x1, x6
    and x9, x1, x19
    add x12, x4, x17
    srliw x13, x22, 25
    blt x18, x26, _br_taken_30
    or x29, x14, x14
    j _br_done_30
_br_taken_30:
    sll x29, x11, x19
_br_done_30:
    ori x6, x19, 811
    sraw x6, x17, x13
    bne x4, x21, _br_taken_31
    and x25, x29, x29
    j _br_done_31
_br_taken_31:
    or x25, x7, x23
_br_done_31:
    fmin.s f6, f0, f17
    fmax.d f11, f1, f28
    fdiv.s f21, f30, f25
    bge x6, x16, _br_taken_32
    sll x19, x13, x10
    j _br_done_32
_br_taken_32:
    sub x19, x14, x27
_br_done_32:
    xori x9, x4, 1272
    addi x16, x29, -2005
    lb x19, 828(x31)
    sb x10, 828(x31)
    sraiw x9, x9, 27
    srl x15, x29, x20
    sll x24, x4, x29
    srlw x14, x23, x20
    slliw x29, x16, 31
    slti x1, x23, -2045
    addiw x19, x19, 1376
    or x24, x28, x5
    slt x20, x6, x6
    srliw x16, x21, 17
    xori x20, x7, 1290
    bltu x11, x24, _br_taken_33
    add x11, x8, x18
    j _br_done_33
_br_taken_33:
    add x11, x26, x8
_br_done_33:
    addi x24, x21, 225
    slt x16, x4, x4
    and x5, x5, x1
    blt x10, x29, _br_taken_34
    srl x29, x16, x28
    j _br_done_34
_br_taken_34:
    slt x29, x9, x21
_br_done_34:
    addi x30, x31, 532
    amoswap.w x26, x29, (x30)
    beq x19, x18, _br_taken_35
    and x17, x19, x9
    j _br_done_35
_br_taken_35:
    and x17, x11, x15
_br_done_35:
    slti x14, x27, -610
    or x5, x29, x8
    sltu x24, x26, x11
    srliw x16, x5, 13
    addi x13, x27, -935
    sub x23, x19, x15
    addi x17, x25, -1950
    and x13, x15, x1
    bne x6, x11, _br_taken_36
    add x12, x20, x9
    j _br_done_36
_br_taken_36:
    or x12, x7, x24
_br_done_36:
    mulhu x24, x16, x26
    div x22, x19, x4
    bgeu x26, x28, _br_taken_37
    xor x14, x26, x10
    j _br_done_37
_br_taken_37:
    or x14, x20, x16
_br_done_37:
    lw x7, 740(x31)
    sw x20, 740(x31)
    bne x23, x28, _br_taken_38
    srl x20, x28, x10
    j _br_done_38
_br_taken_38:
    sra x20, x18, x20
_br_done_38:
    xori x11, x10, 461
    add x20, x21, x7
    srai x16, x5, 3
    srliw x11, x23, 8
    slliw x19, x11, 20
    bne x10, x23, _br_taken_39
    sll x8, x18, x21
    j _br_done_39
_br_taken_39:
    srl x8, x29, x6
_br_done_39:
    or x8, x1, x16
    addw x12, x12, x8
    sltiu x9, x21, -1284
    bltu x5, x19, _br_taken_40
    sub x7, x17, x11
    j _br_done_40
_br_taken_40:
    sra x7, x25, x19
_br_done_40:
    bge x16, x24, _br_taken_41
    or x18, x14, x13
    j _br_done_41
_br_taken_41:
    add x18, x4, x29
_br_done_41:
    lw x29, 796(x31)
    sw x20, 796(x31)
    addi x30, x31, 604
    amomin.w x11, x25, (x30)
    sraiw x5, x18, 12
    lw x18, 180(x31)
    sw x24, 180(x31)
    beq x18, x11, _br_taken_42
    srl x16, x8, x4
    j _br_done_42
_br_taken_42:
    and x16, x5, x24
_br_done_42:
    bgeu x22, x15, _br_taken_43
    slt x19, x13, x16
    j _br_done_43
_br_taken_43:
    sll x19, x17, x8
_br_done_43:
    lwu x20, 500(x31)
    sw x21, 500(x31)
    fmadd.s f29, f7, f4, f29
    and x14, x21, x23
    or x15, x10, x10
    srai x24, x19, 46
    slti x9, x24, 1522
    sra x6, x9, x5
    slt x11, x22, x1
    srl x12, x29, x29
    lh x12, 608(x31)
    sh x12, 608(x31)
    add x4, x11, x1
    and x23, x13, x24
    bge x5, x15, _br_taken_44
    sra x24, x10, x15
    j _br_done_44
_br_taken_44:
    sub x24, x20, x16
_br_done_44:
    fdiv.s f15, f5, f14
    fmin.s f2, f31, f4
    fmax.d f7, f18, f0
    fmin.s f24, f0, f22
    srai x7, x28, 13
    subw x14, x22, x7
    or x28, x18, x12
    slti x9, x5, -1987
    ori x24, x8, -1952
    slti x21, x6, -320
    addw x24, x4, x1
    slti x12, x23, -307
    addi x30, x31, 796
    amomax.w x18, x4, (x30)
    lbu x20, 872(x31)
    sb x8, 872(x31)
    add x23, x7, x12
    srliw x19, x9, 12
    srl x28, x20, x6
    addi x28, x8, 201
    add x29, x9, x24
    fmin.s f15, f5, f8
    fmul.s f4, f11, f5
    srli x20, x9, 22
    fnmsub.s f29, f20, f27, f6
    fmin.s f21, f4, f4
    ld x27, 520(x31)
    sd x16, 520(x31)
    fdiv.s f28, f27, f14
    fnmsub.d f1, f20, f22, f21
    fmax.d f21, f15, f16
    ld x24, 640(x31)
    sd x4, 640(x31)
    bge x8, x25, _br_taken_45
    sub x5, x20, x7
    j _br_done_45
_br_taken_45:
    add x5, x20, x11
_br_done_45:
    srliw x5, x12, 0
    srliw x28, x23, 29

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x2eaec0bf60dc42b4
    .dword 0xd1a0c4030c8a16d3
    .dword 0x48e4671b069cf59d
    .dword 0x8b79636357ac8420
    .dword 0x7f15576cd434ce51
    .dword 0x87e9d7de5d6b06db
    .dword 0xc1ae67a0b7c16a67
    .dword 0xbf4ceda76897b5a2
    .dword 0xc5a9e8dd59c33cc8
    .dword 0x8a9e36ee57194211
    .dword 0x87a8c967b16ad558
    .dword 0x87e88997fe34f788
    .dword 0xc422015d64648415
    .dword 0x1a713b4f88172080
    .dword 0xe89ab834fa0614af
    .dword 0x2310bcbabdb358a6
    .dword 0xfaf7849175fcd468
    .dword 0x5aa3caf850736802
    .dword 0x58c8b915de520051
    .dword 0x275e01ab615c6346
    .dword 0x4cd64c8f7b4cfd6c
    .dword 0xd7100aa75f295c8a
    .dword 0xf2c9efd0ad7f127a
    .dword 0x70770adadc5279d8
    .dword 0xe4f2523eefb15bff
    .dword 0xa2955238b91f442f
    .dword 0xb9164825c8f4abd4
    .dword 0x8e1b66c7d4a76c22
    .dword 0xa3a429a76e556c5a
    .dword 0x2c891a0b740ddcfc
    .dword 0xa2f2b37ed4f99177
    .dword 0x874cb9c62a11487d

    .align 2
_torture_data:
    .word 0x27dac8f0
    .word 0xf74734cc
    .word 0xc5a18135
    .word 0xd5d8f513
    .word 0x91d4bfb3
    .word 0x41f0d2c5
    .word 0x4dbe8f65
    .word 0x43595194
    .word 0x304457d3
    .word 0xecba6bce
    .word 0x05cb665a
    .word 0x47bd0684
    .word 0xa462eb1e
    .word 0x259247e0
    .word 0x39404d91
    .word 0x3c0cd9b3
    .word 0xb64acdc7
    .word 0xbb2f35dc
    .word 0xd651e4e8
    .word 0x37fcf597
    .word 0x617a54b3
    .word 0x691f7719
    .word 0x42356103
    .word 0x537a6657
    .word 0xcaab6b23
    .word 0x8ed1a53a
    .word 0xf648c6bf
    .word 0x5c02081c
    .word 0xb2b62040
    .word 0xfb9518d0
    .word 0x543e1658
    .word 0x556fb3e3
    .word 0xd5839d93
    .word 0xca7afb85
    .word 0x22b3077d
    .word 0x88763cd5
    .word 0x52db2650
    .word 0x0b063c5a
    .word 0x663868f2
    .word 0xba6abb14
    .word 0x280d8f77
    .word 0xdf28510d
    .word 0x3ecc17ea
    .word 0xfe38ac2a
    .word 0x643bcb19
    .word 0x1d3ef66b
    .word 0xbc822402
    .word 0x7103ce8a
    .word 0x480ba536
    .word 0x2f778e12
    .word 0xb9597cc9
    .word 0x40554972
    .word 0x98a20072
    .word 0x4fc91e33
    .word 0xf93fad02
    .word 0x50f920ea
    .word 0xdf40d748
    .word 0x752e0db2
    .word 0x92593a28
    .word 0x246f0b01
    .word 0x9d65a57e
    .word 0x7f4770ba
    .word 0x2322724c
    .word 0xbb18d278
    .word 0x8e206717
    .word 0x3e6fc983
    .word 0xdda8b7b0
    .word 0x927ba7b1
    .word 0x83bb5027
    .word 0x03d226c8
    .word 0x7961baf4
    .word 0x10f5ce69
    .word 0xe6005648
    .word 0x817cdfb7
    .word 0xcf6bde71
    .word 0xfac9bb3d
    .word 0x12a938a3
    .word 0xb2e840ad
    .word 0x1378ee95
    .word 0x06441ecc
    .word 0xcb11960d
    .word 0x364ab737
    .word 0xd76a8b47
    .word 0xe8cdf6cc
    .word 0x342371c4
    .word 0x12128732
    .word 0x68b04681
    .word 0x19766f3d
    .word 0xae4279b7
    .word 0xa0d3b1b2
    .word 0x5c87efe2
    .word 0xf0b027cf
    .word 0x54d95b64
    .word 0x22320e89
    .word 0x3fcab83b
    .word 0x8bf4c2e6
    .word 0x519f1b58
    .word 0xd0693155
    .word 0x47e9fc4d
    .word 0xbb0efa9b
    .word 0x832b2c2c
    .word 0x833e2639
    .word 0xffea1748
    .word 0x7beb0e20
    .word 0x0ab4f5e4
    .word 0x816ecdcf
    .word 0x161d66ee
    .word 0x60839d55
    .word 0xd0a08727
    .word 0x7e0cc764
    .word 0xd2d26e05
    .word 0x1c480b7d
    .word 0x1451b409
    .word 0x7a13614d
    .word 0x43031637
    .word 0x56123e6d
    .word 0xe07d800f
    .word 0xf7a80d8f
    .word 0x33407b64
    .word 0xbea50333
    .word 0x5e5da9d8
    .word 0x6825a97d
    .word 0xc4ff234e
    .word 0x84bcc3f2
    .word 0x739f1d83
    .word 0x8a3dcd64
    .word 0x85ec50be
    .word 0xb85f3ed0
    .word 0x0622d559
    .word 0x55ebc944
    .word 0x1c451fa3
    .word 0xfc281e4d
    .word 0xb99a796f
    .word 0x88be4107
    .word 0xe6248070
    .word 0xdda306ad
    .word 0xf948dafb
    .word 0x6c3196f1
    .word 0x7fd86779
    .word 0x7fc7fdde
    .word 0x4bca3dd6
    .word 0xe620e77f
    .word 0x28aed64c
    .word 0x5e1a6666
    .word 0xeb131e96
    .word 0x9b35f65f
    .word 0xe45709e1
    .word 0x7176e1f7
    .word 0xa8ab127a
    .word 0x2684bd3a
    .word 0xd3ced076
    .word 0x0e1926db
    .word 0x86d731c4
    .word 0x8618aedb
    .word 0xb8b8cc88
    .word 0xd1dd557a
    .word 0x78b121ee
    .word 0x2907da0d
    .word 0xba01718e
    .word 0x48f72aea
    .word 0x91e97695
    .word 0x13807fd2
    .word 0xf29ba276
    .word 0xf0263e80
    .word 0x9d93cc94
    .word 0xf2c3feaa
    .word 0xeceb6a36
    .word 0x0f58fbb4
    .word 0x2558867b
    .word 0xe1de77d4
    .word 0x821453e4
    .word 0x4539b539
    .word 0xe45f95a7
    .word 0xd99957b8
    .word 0xbd4acbd4
    .word 0x8339e6ae
    .word 0xa75df937
    .word 0x410f0e02
    .word 0xd22bed4a
    .word 0xedf70cfd
    .word 0x2e71a1d5
    .word 0xa65c9b35
    .word 0x542eb19a
    .word 0x6dec6b13
    .word 0x658fe9fb
    .word 0x39e467e8
    .word 0xf3de48b5
    .word 0xc5e7ad9b
    .word 0xb4ba8c20
    .word 0x808dcca1
    .word 0x9fff94ca
    .word 0xb8905d56
    .word 0xcbb7e3f3
    .word 0x529785df
    .word 0x087256e2
    .word 0x349da2fb
    .word 0xe14ede2b
    .word 0x57292198
    .word 0xa4e689eb
    .word 0x615ef20e
    .word 0x0216657c
    .word 0xbc8150ca
    .word 0x0abca030
    .word 0xa50c6522
    .word 0x1d46ccdc
    .word 0x6b06a628
    .word 0x1792ce1d
    .word 0xc0a989fa
    .word 0x8e1e506a
    .word 0x1955a315
    .word 0x1afae086
    .word 0x732feef0
    .word 0x3bc8cf00
    .word 0x36c89572
    .word 0x36760187
    .word 0x5504c410
    .word 0x06daff4b
    .word 0xc3779553
    .word 0x4dc5c509
    .word 0x26ccd074
    .word 0x333de54e
    .word 0x8416ee5f
    .word 0x6071f4ba
    .word 0x933057ee
    .word 0x92b9ab93
    .word 0x434309d6
    .word 0x20a54fbb
    .word 0x1741a39b
    .word 0x899d1d52
    .word 0xd529b0bc
    .word 0x88ba7894
    .word 0x4aea2b59
    .word 0xd3078716
    .word 0x46e17853
    .word 0x467740e9
    .word 0x3040f65e
    .word 0xd9307d5f
    .word 0x2b3a51c1
    .word 0xbfe07271
    .word 0xe2f9047f
    .word 0xee60b483
    .word 0x75e98a72
    .word 0x1a01c041
    .word 0xeb0c2bd2
    .word 0x354f9d71
    .word 0x6975f9b3
    .word 0x884986c4
    .word 0x4fd5f37f
    .word 0xe1bbc0d5
    .word 0xa0eac4c7
    .word 0xe4fa0ae9
    .word 0xbe46dc77
    .word 0x7f8aba6c
    .word 0xbcb20865
    .word 0x21f4ef01
    .word 0x9df34381

#include "frost_footer.S"
