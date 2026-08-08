// Generated RV64IMAFDC torture test for Frost (seed=20260813)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x2f8a7ebcfdb269b9
    li x4, 0x0de1c82473e9b050
    li x5, 0x971eb149d1f2fa87
    li x6, 0xf310a5ac8bcbed56
    li x7, 0x4fbdfe69fbea1203
    li x8, 0x6656b50fb06f059e
    li x9, 0xe2e6e94a0cb4a3f8
    li x10, 0xeb3942374f7d43db
    li x11, 0x71de3e76a9ad4128
    li x12, 0xf8b96ad3b67195db
    li x13, 0x73acb1ff4f39d179
    li x14, 0x7b66f60ded0546d5
    li x15, 0x97c8b103c1121eff
    li x16, 0x3b6ba34811c39475
    li x17, 0x89ea531d5dbf3b8d
    li x18, 0xdbdfb6c705f94054
    li x19, 0xb2b70c2b5ebe740c
    li x20, 0xe3dfe7afe95d5d52
    li x21, 0x4a8ba7a84fcff810
    li x22, 0xf388822ed6793397
    li x23, 0x5e64047e1a354c3f
    li x24, 0x17b9a769d6c29a75
    li x25, 0x453d6c0796a49bdb
    li x26, 0x38c60782a5991543
    li x27, 0xacb7c8c5981e4167
    li x28, 0x3edb5762469c8165
    li x29, 0xd7fa1ab1a85f69bf
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
    li x1, 0xa2a95a8328f007ae

    and x1, x16, x29
    sltu x4, x24, x26
    srai x5, x1, 60
    bgeu x15, x5, _br_taken_0
    srl x25, x11, x4
    j _br_done_0
_br_taken_0:
    sltu x25, x24, x17
_br_done_0:
    addw x27, x10, x1
    slti x19, x8, 1516
    srli x6, x17, 47
    slti x21, x5, -1456
    fmul.s f27, f7, f30
    andi x26, x25, 1338
    sub x8, x12, x23
    sra x14, x17, x12
    bge x7, x22, _br_taken_1
    or x23, x14, x8
    j _br_done_1
_br_taken_1:
    or x23, x1, x27
_br_done_1:
    slt x18, x18, x13
    sra x23, x19, x25
    addw x9, x5, x25
    addi x30, x31, 368
    amoxor.d x5, x29, (x30)
    xori x11, x23, -11
    sllw x26, x22, x15
    xori x15, x4, -1385
    sltu x6, x26, x18
    remw x7, x9, x7
    mulh x10, x22, x4
    mul x24, x24, x8
    xori x26, x17, 1529
    ori x7, x28, -1410
    xor x21, x28, x25
    fadd.d f21, f30, f31
    bge x26, x1, _br_taken_2
    and x11, x18, x22
    j _br_done_2
_br_taken_2:
    and x11, x7, x6
_br_done_2:
    fmul.d f11, f27, f18
    fadd.d f7, f4, f1
    addi x17, x27, -843
    ld x24, 696(x31)
    sd x23, 696(x31)
    bltu x15, x7, _br_taken_3
    or x24, x11, x28
    j _br_done_3
_br_taken_3:
    add x24, x17, x19
_br_done_3:
    blt x4, x13, _br_taken_4
    add x14, x25, x5
    j _br_done_4
_br_taken_4:
    sra x14, x26, x5
_br_done_4:
    fnmadd.s f18, f2, f9, f13
    addiw x23, x13, 1608
    xor x16, x1, x23
    mulh x26, x29, x20
    or x14, x29, x11
    addw x11, x5, x18
    srlw x15, x27, x23
    srai x9, x15, 53
    mul x18, x25, x25
    divw x7, x1, x28
    sltu x25, x18, x23
    addw x9, x6, x17
    srlw x7, x18, x16
    slt x18, x8, x5
    xor x11, x17, x8
    bgeu x22, x4, _br_taken_5
    add x5, x25, x14
    j _br_done_5
_br_taken_5:
    add x5, x22, x6
_br_done_5:
    lbu x15, 88(x31)
    sb x1, 88(x31)
    srli x1, x11, 25
    slliw x27, x11, 28
    addw x13, x23, x11
    remw x10, x28, x12
    remuw x11, x14, x16
    addi x30, x31, 56
    amoxor.d x5, x19, (x30)
    mulh x25, x28, x10
    srlw x17, x17, x11
    xor x21, x16, x12
    fadd.d f18, f7, f18
    fsub.s f29, f14, f22
    fmin.s f2, f9, f20
    fmax.d f10, f3, f7
    fsub.d f12, f15, f25
    beq x20, x8, _br_taken_6
    sltu x11, x13, x14
    j _br_done_6
_br_taken_6:
    sra x11, x23, x26
_br_done_6:
    sra x15, x14, x24
    addw x17, x18, x22
    andi x17, x4, -19
    addi x30, x31, 236
    amoor.w x5, x7, (x30)
    bltu x8, x13, _br_taken_7
    and x20, x23, x12
    j _br_done_7
_br_taken_7:
    sltu x20, x14, x10
_br_done_7:
    fmul.s f7, f26, f24
    xori x19, x26, 1014
    sllw x24, x15, x7
    srliw x22, x13, 4
    ld x28, 832(x31)
    sd x18, 832(x31)
    srai x8, x17, 8
    bltu x17, x19, _br_taken_8
    sll x19, x26, x4
    j _br_done_8
_br_taken_8:
    sra x19, x8, x20
_br_done_8:
    bltu x20, x13, _br_taken_9
    or x21, x18, x21
    j _br_done_9
_br_taken_9:
    sltu x21, x10, x17
_br_done_9:
    bltu x6, x26, _br_taken_10
    sub x5, x27, x9
    j _br_done_10
_br_taken_10:
    xor x5, x15, x11
_br_done_10:
    fmul.s f12, f8, f17
    fsub.s f3, f19, f22
    sraw x7, x8, x16
    sll x10, x1, x22
    mulhsu x1, x11, x17
    remuw x11, x21, x15
    xor x12, x21, x9
    sraiw x1, x27, 11
    or x6, x13, x19
    slli x25, x8, 3
    add x16, x7, x15
    xor x22, x4, x22
    fsub.s f26, f10, f23
    fdiv.s f8, f22, f14
    addi x30, x31, 52
    amoor.w x8, x29, (x30)
    lbu x12, 536(x31)
    sb x14, 536(x31)
    srl x20, x26, x23
    bne x26, x27, _br_taken_11
    add x9, x6, x6
    j _br_done_11
_br_taken_11:
    srl x9, x5, x6
_br_done_11:
    slti x15, x20, 1491
    subw x7, x16, x18
    blt x16, x23, _br_taken_12
    sll x24, x18, x7
    j _br_done_12
_br_taken_12:
    or x24, x19, x26
_br_done_12:
    ori x29, x20, 112
    sraiw x18, x1, 5
    xor x28, x11, x1
    bne x7, x26, _br_taken_13
    or x14, x8, x16
    j _br_done_13
_br_taken_13:
    sltu x14, x19, x9
_br_done_13:
    and x27, x15, x5
    addi x30, x31, 136
    amomax.d x24, x29, (x30)
    bgeu x21, x14, _br_taken_14
    xor x24, x16, x29
    j _br_done_14
_br_taken_14:
    sub x24, x13, x27
_br_done_14:
    sraiw x6, x6, 7
    sll x1, x23, x1
    srli x7, x23, 7
    blt x13, x25, _br_taken_15
    slt x15, x4, x8
    j _br_done_15
_br_taken_15:
    sltu x15, x27, x25
_br_done_15:
    beq x25, x24, _br_taken_16
    sra x4, x6, x28
    j _br_done_16
_br_taken_16:
    sll x4, x15, x18
_br_done_16:
    beq x8, x18, _br_taken_17
    xor x4, x6, x16
    j _br_done_17
_br_taken_17:
    sub x4, x5, x27
_br_done_17:
    srli x27, x5, 46
    sltiu x10, x1, -263
    sraiw x10, x28, 25
    slti x13, x11, 1632
    slliw x6, x15, 23
    slli x27, x22, 36
    addiw x25, x4, -158
    srlw x22, x1, x24
    srlw x16, x26, x28
    slliw x12, x23, 26
    slti x1, x11, -1492
    srliw x11, x4, 5
    addiw x17, x11, 54
    addw x20, x7, x23
    fmin.s f30, f9, f23
    fdiv.s f4, f18, f26
    addi x30, x31, 232
    amominu.d x28, x22, (x30)
    bltu x8, x20, _br_taken_18
    srl x10, x13, x17
    j _br_done_18
_br_taken_18:
    add x10, x18, x7
_br_done_18:
    addiw x28, x27, -988
    fsub.s f3, f10, f28
    fdiv.s f18, f22, f11
    fnmadd.s f23, f25, f1, f2
    lh x28, 880(x31)
    sh x7, 880(x31)
    sllw x20, x17, x29
    slliw x24, x9, 29
    sll x19, x22, x29
    sll x20, x12, x4
    addiw x28, x23, -536
    srliw x23, x28, 21
    addw x22, x10, x18
    add x19, x5, x18
    bgeu x19, x27, _br_taken_19
    xor x11, x17, x17
    j _br_done_19
_br_taken_19:
    and x11, x26, x22
_br_done_19:
    sraw x27, x8, x15
    sll x9, x26, x9
    srlw x12, x11, x8
    fmax.s f14, f10, f4
    fmul.d f30, f6, f6
    blt x6, x10, _br_taken_20
    or x21, x4, x21
    j _br_done_20
_br_taken_20:
    sra x21, x17, x9
_br_done_20:
    bgeu x17, x1, _br_taken_21
    srl x1, x12, x6
    j _br_done_21
_br_taken_21:
    sll x1, x12, x25
_br_done_21:
    sub x10, x6, x15
    bltu x8, x29, _br_taken_22
    sra x9, x25, x27
    j _br_done_22
_br_taken_22:
    add x9, x21, x15
_br_done_22:
    bgeu x10, x22, _br_taken_23
    and x9, x11, x17
    j _br_done_23
_br_taken_23:
    add x9, x29, x22
_br_done_23:
    beq x20, x26, _br_taken_24
    add x15, x23, x4
    j _br_done_24
_br_taken_24:
    sll x15, x19, x9
_br_done_24:
    add x15, x8, x10
    addi x11, x7, -59
    addiw x7, x7, -1734
    slliw x12, x28, 10
    xori x27, x1, -489
    slti x12, x17, -707
    addw x27, x17, x1
    slliw x28, x14, 26
    addw x29, x1, x19
    lwu x15, 476(x31)
    sw x16, 476(x31)
    andi x10, x7, 712
    srai x20, x18, 57
    slti x9, x4, 425
    slli x26, x9, 11
    sraw x12, x4, x27
    blt x24, x27, _br_taken_25
    sub x12, x25, x1
    j _br_done_25
_br_taken_25:
    slt x12, x8, x25
_br_done_25:
    addi x11, x5, -874
    sub x20, x18, x1
    add x19, x22, x29
    addiw x22, x23, -1455
    srai x16, x8, 34
    andi x12, x14, 433
    subw x12, x29, x26
    sltu x12, x29, x11
    slli x26, x24, 14
    lh x20, 216(x31)
    sh x9, 216(x31)
    blt x29, x24, _br_taken_26
    xor x27, x21, x18
    j _br_done_26
_br_taken_26:
    and x27, x18, x6
_br_done_26:
    bge x6, x5, _br_taken_27
    xor x10, x13, x1
    j _br_done_27
_br_taken_27:
    sll x10, x27, x15
_br_done_27:
    remu x5, x26, x14
    div x27, x13, x14
    lh x1, 20(x31)
    sh x7, 20(x31)
    slliw x27, x7, 10
    andi x8, x17, -1060
    sraiw x19, x4, 18
    slliw x19, x24, 7
    slli x22, x6, 53
    xori x23, x10, -176
    srl x27, x1, x22
    remw x21, x25, x15
    lhu x20, 308(x31)
    sh x9, 308(x31)
    blt x18, x15, _br_taken_28
    sltu x25, x14, x18
    j _br_done_28
_br_taken_28:
    add x25, x29, x12
_br_done_28:
    slli x24, x8, 8
    sra x10, x11, x7
    or x10, x29, x20
    bltu x16, x17, _br_taken_29
    or x16, x5, x29
    j _br_done_29
_br_taken_29:
    and x16, x5, x16
_br_done_29:
    fmin.s f27, f8, f14
    fmsub.s f7, f8, f0, f17
    fsub.d f26, f6, f16
    sll x5, x21, x28
    sub x8, x1, x4
    addi x30, x31, 184
    amomaxu.w x21, x8, (x30)
    mulhu x25, x11, x10
    mulhu x7, x19, x16
    bgeu x11, x5, _br_taken_30
    sra x6, x24, x22
    j _br_done_30
_br_taken_30:
    xor x6, x19, x23
_br_done_30:
    bltu x8, x12, _br_taken_31
    srl x9, x22, x25
    j _br_done_31
_br_taken_31:
    xor x9, x1, x25
_br_done_31:
    fmax.s f2, f24, f28
    fmax.d f2, f3, f16
    fsub.d f20, f12, f28
    bgeu x25, x17, _br_taken_32
    and x14, x19, x26
    j _br_done_32
_br_taken_32:
    sub x14, x1, x4
_br_done_32:
    beq x1, x22, _br_taken_33
    xor x20, x22, x4
    j _br_done_33
_br_taken_33:
    add x20, x14, x11
_br_done_33:
    bltu x25, x19, _br_taken_34
    slt x27, x19, x27
    j _br_done_34
_br_taken_34:
    sub x27, x26, x27
_br_done_34:
    slt x5, x21, x9
    or x26, x1, x23
    sll x9, x4, x23
    slli x23, x27, 14
    sraiw x13, x28, 27
    addi x15, x10, -1791
    lb x26, 448(x31)
    sb x13, 448(x31)
    srliw x5, x7, 24
    fadd.s f24, f23, f19
    fdiv.s f16, f1, f7
    addi x30, x31, 644
    amoxor.w x29, x20, (x30)
    beq x25, x19, _br_taken_35
    add x26, x15, x6
    j _br_done_35
_br_taken_35:
    srl x26, x6, x10
_br_done_35:
    addi x30, x31, 892
    amoor.w x25, x23, (x30)
    fmin.s f17, f12, f16
    slliw x12, x22, 24
    xor x24, x11, x8
    slti x8, x10, 1570
    srlw x18, x20, x29
    fmax.d f22, f6, f13
    fmax.s f10, f5, f8
    fmax.s f3, f23, f21
    bltu x18, x20, _br_taken_36
    slt x27, x28, x9
    j _br_done_36
_br_taken_36:
    srl x27, x29, x9
_br_done_36:
    remuw x25, x6, x19
    divuw x24, x23, x1
    srl x24, x4, x25
    and x12, x9, x1
    sraiw x13, x12, 4
    addi x30, x31, 368
    amoswap.w x25, x21, (x30)
    add x20, x15, x26
    bge x10, x10, _br_taken_37
    sll x7, x4, x8
    j _br_done_37
_br_taken_37:
    slt x7, x26, x22
_br_done_37:
    sll x29, x29, x27
    xor x12, x16, x17
    remu x13, x5, x7
    remuw x5, x9, x28
    and x22, x23, x9
    sub x10, x13, x20
    sraw x14, x17, x15
    divuw x20, x6, x18
    divuw x14, x21, x25
    sra x28, x21, x28
    lw x4, 764(x31)
    sw x21, 764(x31)
    lh x20, 572(x31)
    sh x19, 572(x31)
    beq x1, x13, _br_taken_38
    and x25, x9, x28
    j _br_done_38
_br_taken_38:
    sub x25, x20, x16
_br_done_38:
    ori x10, x6, 1088
    and x26, x29, x16
    xor x20, x12, x10
    sraw x22, x20, x25
    bltu x9, x10, _br_taken_39
    slt x26, x23, x25
    j _br_done_39
_br_taken_39:
    and x26, x19, x1
_br_done_39:
    fnmsub.s f10, f3, f11, f15
    fdiv.s f13, f3, f29
    fmin.d f23, f24, f29
    addiw x9, x19, -387
    srai x14, x21, 46
    addiw x6, x21, -836
    or x18, x13, x25
    srli x5, x4, 21
    sltu x4, x15, x5
    xori x26, x11, -214
    fmul.s f23, f11, f5
    fadd.s f6, f28, f7
    fadd.d f7, f7, f18
    fdiv.d f14, f4, f18
    fmul.d f24, f15, f12
    fmsub.s f18, f19, f20, f30
    fmin.d f20, f17, f0
    fmax.s f24, f18, f8
    fmin.d f3, f2, f31
    srl x18, x29, x4
    blt x21, x4, _br_taken_40
    sltu x29, x25, x7
    j _br_done_40
_br_taken_40:
    sra x29, x12, x9
_br_done_40:
    bgeu x6, x15, _br_taken_41
    and x19, x7, x16
    j _br_done_41
_br_taken_41:
    sll x19, x13, x29
_br_done_41:
    bgeu x16, x19, _br_taken_42
    and x29, x13, x8
    j _br_done_42
_br_taken_42:
    srl x29, x9, x11
_br_done_42:
    slt x28, x19, x22
    addw x29, x4, x5
    sltu x23, x1, x25
    bge x20, x18, _br_taken_43
    or x11, x28, x23
    j _br_done_43
_br_taken_43:
    sltu x11, x12, x18
_br_done_43:
    fdiv.d f8, f3, f8
    fnmadd.d f26, f25, f16, f6
    slli x24, x4, 58
    bge x26, x17, _br_taken_44
    srl x27, x1, x5
    j _br_done_44
_br_taken_44:
    srl x27, x4, x1
_br_done_44:
    sraiw x25, x10, 18
    fsub.s f6, f11, f8
    fdiv.d f11, f12, f30
    addi x30, x31, 772
    amominu.w x1, x7, (x30)
    sltiu x8, x15, -1940
    sraw x19, x1, x20
    sltu x5, x26, x24
    fmul.d f9, f26, f3
    fsub.s f30, f16, f20
    slti x29, x13, -1854
    or x15, x11, x19
    or x19, x26, x27
    addi x30, x31, 80
    amominu.w x15, x18, (x30)
    srliw x25, x23, 5
    ori x13, x19, 341
    sra x22, x14, x5
    addiw x11, x26, -386
    xori x10, x5, 1602
    slt x21, x25, x24
    bge x7, x15, _br_taken_45
    slt x19, x23, x20
    j _br_done_45
_br_taken_45:
    xor x19, x8, x21
_br_done_45:
    addiw x1, x1, -312
    srliw x15, x18, 4
    and x5, x15, x26
    sraw x18, x24, x18
    srai x29, x1, 38
    srai x12, x1, 61
    beq x8, x12, _br_taken_46
    or x22, x17, x4
    j _br_done_46
_br_taken_46:
    sub x22, x4, x25
_br_done_46:
    lw x1, 372(x31)
    sw x14, 372(x31)
    addiw x29, x20, 219
    subw x17, x21, x25
    bgeu x17, x18, _br_taken_47
    add x6, x12, x19
    j _br_done_47
_br_taken_47:
    xor x6, x29, x23
_br_done_47:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xbc665b10db258b0c
    .dword 0x22de011f0d911fe2
    .dword 0xe53c676399c1c803
    .dword 0x387c8f596fb016c6
    .dword 0x886b35d0882b80be
    .dword 0xd7ca5a59a1d16f73
    .dword 0x1727a5a8cbfbeca9
    .dword 0x54e232cb649cb648
    .dword 0xa6cde1e895d74d25
    .dword 0xe253baca648e8d74
    .dword 0x659082f8d866ea8c
    .dword 0x26c7f236053824d8
    .dword 0x234eaba9ea44f9c8
    .dword 0x0426e3d8962f97e2
    .dword 0x880db8841a505bcd
    .dword 0xacac90a6fcec5d21
    .dword 0xdad254d754ab96d0
    .dword 0xaf1b0fa2f33a6252
    .dword 0x91f7c6edf0f3aa96
    .dword 0x7d3d60fc94264ebb
    .dword 0xa062f015894623b8
    .dword 0x77a8a40db693d717
    .dword 0xdcc9e56209ee91dd
    .dword 0x50d9c15b798ce603
    .dword 0xd136ed364e5c9808
    .dword 0x89e142cc3b019847
    .dword 0xeb33eb4a2ac851ba
    .dword 0x042dc73f4c5be6ad
    .dword 0x9e53a2eb6f78d0ba
    .dword 0xa5609faa1ff29627
    .dword 0x63cae8df4eb6ce48
    .dword 0xa64ad91c937eda61

    .align 2
_torture_data:
    .word 0x9a61ae04
    .word 0xca27ce75
    .word 0xcb415632
    .word 0x0563b4a4
    .word 0xfe94c2e1
    .word 0x27afcfbf
    .word 0xba6a9912
    .word 0xff16e4ca
    .word 0x71fee896
    .word 0xca4f49b5
    .word 0xe85f831d
    .word 0xc4e89c74
    .word 0xda3cd0d6
    .word 0x4696a78f
    .word 0x8b0fe1cc
    .word 0xff592a09
    .word 0x72f4af12
    .word 0xd16dfb0e
    .word 0x9a861965
    .word 0x38b1c47e
    .word 0x67f5aecf
    .word 0xf2b36820
    .word 0x072e78d2
    .word 0x8f9c803b
    .word 0x0c149d37
    .word 0x25405204
    .word 0x4fc08072
    .word 0x49b76596
    .word 0x6e245c16
    .word 0xc6bde134
    .word 0x993c6e49
    .word 0x4fb58939
    .word 0x634a8588
    .word 0xdbf32752
    .word 0x88a40681
    .word 0xfc6d3e43
    .word 0x7adeddad
    .word 0xa50d54a8
    .word 0x218fa0ec
    .word 0x9148fefb
    .word 0xa2fe506a
    .word 0xb7152e3c
    .word 0x6a9979d8
    .word 0xf3457d55
    .word 0xf9eb6308
    .word 0xc5c16ec7
    .word 0x6a37aa8e
    .word 0xb4ad4fde
    .word 0xef345d70
    .word 0x4f47c5d0
    .word 0x7c8a8db3
    .word 0x3479a7de
    .word 0x925be391
    .word 0x20bcd918
    .word 0xffbc002c
    .word 0xfa008782
    .word 0x579507c3
    .word 0x84ac5315
    .word 0x390104b7
    .word 0xd0f00847
    .word 0x79ae77e3
    .word 0xafb40810
    .word 0x2fa7b777
    .word 0x8cf4e6d9
    .word 0xf0959566
    .word 0x11e4e466
    .word 0xbeb9c9d2
    .word 0x205ffda0
    .word 0x45c66646
    .word 0xb8dff97a
    .word 0xedb65823
    .word 0xa3e9e2d0
    .word 0x2299b66e
    .word 0x87b930eb
    .word 0xe7a9fb75
    .word 0x98ffdddb
    .word 0x549e19eb
    .word 0xab8003fa
    .word 0x41cca449
    .word 0x2a237664
    .word 0x89d8c02e
    .word 0xef7c45c2
    .word 0x257f820e
    .word 0x60ba9bc9
    .word 0x21fc5241
    .word 0x47cc38c4
    .word 0x9f26bba9
    .word 0xc2c2107e
    .word 0x081c40e7
    .word 0x2c913be8
    .word 0x9a288afd
    .word 0x5da17d98
    .word 0x4e916437
    .word 0x85c36b7f
    .word 0xc76a5960
    .word 0xc221eb49
    .word 0xf7521135
    .word 0x48430b87
    .word 0xdd2106bb
    .word 0x7bdd03ea
    .word 0x60ca1b8c
    .word 0x1befdb5a
    .word 0x9890ecd5
    .word 0xe393f7c0
    .word 0xe9001740
    .word 0xe927343d
    .word 0x2dde6504
    .word 0x402dda77
    .word 0x63cbf705
    .word 0xb0d60173
    .word 0x054ca237
    .word 0xb4b30fc2
    .word 0x0336583c
    .word 0x90e56a8f
    .word 0x0cbfa3d3
    .word 0xe07f4393
    .word 0x453108bb
    .word 0x1534fde3
    .word 0x76ac77b4
    .word 0xd1540246
    .word 0xdd6524d9
    .word 0x8fab2331
    .word 0x39181552
    .word 0x6606cc67
    .word 0x7ab5f9f2
    .word 0x40deb699
    .word 0x40ffe69c
    .word 0xf4a984cb
    .word 0xc27587c8
    .word 0xcdc184a4
    .word 0x5defc508
    .word 0x901b1273
    .word 0x4aab4da8
    .word 0xf8395631
    .word 0xefc3e1fc
    .word 0x0bb19914
    .word 0x9bfb8031
    .word 0x8c3332d7
    .word 0xf0eb8e1e
    .word 0x8c24496a
    .word 0x317ecf6d
    .word 0x89511c85
    .word 0x8e1e300a
    .word 0x76db7bdf
    .word 0xf8320a0a
    .word 0xdcd695b9
    .word 0x340973ac
    .word 0xe0fa697a
    .word 0x16cef587
    .word 0x605a453b
    .word 0x700de3c7
    .word 0x2126638b
    .word 0xbe84f63b
    .word 0xf60be9db
    .word 0xad6bf59d
    .word 0xb0a9fcad
    .word 0x118fedb1
    .word 0x749e2ec2
    .word 0xbda59949
    .word 0x053117dc
    .word 0x15064a85
    .word 0x65bc0ec8
    .word 0x3ae096ad
    .word 0xa089122e
    .word 0xf1a4bbe7
    .word 0x8d8dae94
    .word 0x2d506c4d
    .word 0xfd64dca9
    .word 0xb2b417ec
    .word 0x95efcd0d
    .word 0x744b5fe3
    .word 0x55b1cca1
    .word 0xb15b4850
    .word 0x9db0c070
    .word 0x8dac86de
    .word 0xa4149722
    .word 0x37fddab1
    .word 0x8a4486e1
    .word 0xe11e8697
    .word 0x9a8d530f
    .word 0x1eed36e6
    .word 0xd7935f76
    .word 0x814c24f0
    .word 0x16777f83
    .word 0x58d046f1
    .word 0x7cb2c2c2
    .word 0xd506d986
    .word 0x69d54827
    .word 0x663b22c7
    .word 0x22e4136e
    .word 0xeebf51f6
    .word 0x0bce9d09
    .word 0x62569f49
    .word 0xf162ffd0
    .word 0xcee8d700
    .word 0xfa3b1170
    .word 0x57b3d0db
    .word 0xc6a72209
    .word 0xe408c68d
    .word 0x7f53d201
    .word 0x006f919a
    .word 0x4c625df6
    .word 0xc7a4f7b6
    .word 0x6da97079
    .word 0x85135783
    .word 0x13206b72
    .word 0x5c6353d7
    .word 0x8e20a335
    .word 0x891f3f5b
    .word 0x1aade0bd
    .word 0x554e1ff3
    .word 0x5d08ce3a
    .word 0x6fb37b8c
    .word 0x6254f151
    .word 0xe72e6868
    .word 0xda1488a9
    .word 0xba4b792d
    .word 0x1cb8b4f1
    .word 0xa23e3cf6
    .word 0x94de5b7c
    .word 0x9a373e9f
    .word 0xa14292fb
    .word 0x0565d869
    .word 0x297d1c81
    .word 0x886ec8de
    .word 0x56a7ea27
    .word 0xe5fd8d99
    .word 0x4c3b2cb7
    .word 0xc044e4df
    .word 0x86a70385
    .word 0xc5ec2041
    .word 0x826488a9
    .word 0xbcfab122
    .word 0x4818552e
    .word 0x5b017779
    .word 0x728aa92b
    .word 0xa7da36b9
    .word 0xfd826f53
    .word 0x514f4a68
    .word 0xe7d9240a
    .word 0x169eb772
    .word 0xa004dd7a
    .word 0xf3208fc6
    .word 0xf22bd456
    .word 0xc6203463
    .word 0x0b2644a0
    .word 0x75d6b5e7
    .word 0x2652bc1e
    .word 0x627e5d1b
    .word 0xad7b17be
    .word 0x5727cb3f
    .word 0x0781ac5d
    .word 0xda0b4d5b
    .word 0xc905e226
    .word 0x7c431415
    .word 0x9760273e

#include "frost_footer.S"
