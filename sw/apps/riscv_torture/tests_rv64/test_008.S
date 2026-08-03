// Generated RV64IMAFDC torture test for Frost (seed=20260810)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xf0239bc252ad530d
    li x4, 0x0129114e5ade1623
    li x5, 0xf844c4226bcfaf69
    li x6, 0x6aeb572c002e4db5
    li x7, 0xd46ede03624bb3d9
    li x8, 0x0b73c4f3ca6d86dc
    li x9, 0x96379056d62dc78b
    li x10, 0x49f06c9f32da52c7
    li x11, 0x515d8b35edac001c
    li x12, 0x499fd8ab7b372f16
    li x13, 0xcae8db0df65827d7
    li x14, 0x579225bfbfbad93f
    li x15, 0x0b430fb149758e64
    li x16, 0x67f392a2d9d8d7ad
    li x17, 0x6d358c2e9594a0a3
    li x18, 0xabcf322a3d86b56d
    li x19, 0x0efc774df02f81cc
    li x20, 0x97850cfa797061c6
    li x21, 0x6e6346c7b58fc55e
    li x22, 0x4202f3823df312f9
    li x23, 0x2ed5b2a7295991f8
    li x24, 0x18c7880dbd59f47d
    li x25, 0x6fd9e935a2724704
    li x26, 0x1a8953d034cb4b56
    li x27, 0x4ff1143f2361a758
    li x28, 0x69184d1d4902c16c
    li x29, 0xa87e93427a0b7ac5
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
    li x1, 0xfd990f38e770a5dc

    sllw x7, x27, x9
    or x17, x11, x7
    sraiw x14, x9, 29
    addi x30, x31, 596
    amoand.w x27, x27, (x30)
    subw x5, x27, x1
    slt x5, x12, x24
    srliw x10, x26, 11
    and x7, x18, x21
    srli x17, x12, 49
    or x29, x14, x4
    bge x6, x18, _br_taken_0
    or x12, x14, x25
    j _br_done_0
_br_taken_0:
    slt x12, x26, x22
_br_done_0:
    bgeu x7, x29, _br_taken_1
    sltu x20, x7, x18
    j _br_done_1
_br_taken_1:
    sltu x20, x17, x5
_br_done_1:
    andi x22, x9, -1486
    ori x22, x7, -94
    slti x9, x21, 1027
    sraw x9, x9, x29
    slt x4, x9, x13
    ori x23, x16, -549
    srliw x22, x15, 21
    sra x15, x7, x7
    xor x23, x1, x22
    sltiu x10, x18, 838
    sub x14, x5, x16
    or x7, x19, x18
    lw x25, 744(x31)
    sw x24, 744(x31)
    slliw x19, x24, 21
    slliw x23, x13, 18
    sltu x15, x24, x24
    srliw x26, x24, 2
    sraiw x5, x12, 7
    bge x12, x19, _br_taken_2
    sltu x8, x6, x22
    j _br_done_2
_br_taken_2:
    sll x8, x9, x6
_br_done_2:
    bgeu x8, x23, _br_taken_3
    and x7, x24, x23
    j _br_done_3
_br_taken_3:
    sll x7, x29, x28
_br_done_3:
    lw x10, 812(x31)
    sw x12, 812(x31)
    lw x4, 980(x31)
    sw x28, 980(x31)
    blt x13, x23, _br_taken_4
    sltu x28, x27, x29
    j _br_done_4
_br_taken_4:
    srl x28, x16, x8
_br_done_4:
    fmsub.s f15, f26, f10, f27
    fmadd.s f14, f27, f29, f3
    fdiv.d f18, f2, f10
    slli x10, x16, 25
    mulh x23, x28, x14
    mulh x14, x14, x7
    and x1, x26, x20
    sub x5, x21, x19
    ori x25, x24, 295
    fadd.d f1, f6, f11
    fsub.s f2, f23, f18
    fdiv.s f2, f26, f30
    slt x22, x21, x7
    divu x19, x9, x16
    fmul.s f7, f14, f12
    fsub.d f19, f18, f9
    addi x30, x31, 764
    amomin.w x29, x23, (x30)
    bne x13, x8, _br_taken_5
    or x7, x22, x12
    j _br_done_5
_br_taken_5:
    sltu x7, x19, x22
_br_done_5:
    bne x10, x29, _br_taken_6
    sra x1, x6, x17
    j _br_done_6
_br_taken_6:
    and x1, x4, x8
_br_done_6:
    blt x1, x7, _br_taken_7
    sub x4, x5, x16
    j _br_done_7
_br_taken_7:
    and x4, x7, x26
_br_done_7:
    srli x5, x7, 36
    slti x8, x15, -1618
    srliw x26, x12, 18
    sraiw x12, x13, 25
    srlw x20, x8, x19
    blt x29, x19, _br_taken_8
    slt x24, x4, x9
    j _br_done_8
_br_taken_8:
    add x24, x15, x15
_br_done_8:
    fnmsub.s f16, f8, f16, f9
    fmsub.d f28, f26, f28, f10
    fadd.d f3, f28, f31
    fdiv.s f29, f27, f8
    fnmsub.d f6, f29, f18, f11
    bne x5, x29, _br_taken_9
    srl x23, x8, x16
    j _br_done_9
_br_taken_9:
    sra x23, x8, x23
_br_done_9:
    addi x30, x31, 208
    amomin.d x15, x24, (x30)
    slt x13, x17, x29
    blt x5, x23, _br_taken_10
    sra x29, x1, x8
    j _br_done_10
_br_taken_10:
    or x29, x1, x12
_br_done_10:
    xor x6, x11, x7
    addw x23, x22, x20
    srlw x13, x7, x15
    andi x28, x5, 1111
    bgeu x20, x10, _br_taken_11
    srl x19, x13, x1
    j _br_done_11
_br_taken_11:
    xor x19, x15, x17
_br_done_11:
    ld x16, 320(x31)
    sd x25, 320(x31)
    addi x10, x11, 1433
    xor x29, x14, x15
    addi x23, x29, -1705
    div x13, x12, x19
    rem x16, x26, x11
    andi x23, x12, -1667
    addiw x13, x6, 930
    addi x30, x31, 600
    amomax.w x16, x17, (x30)
    fmin.s f11, f18, f30
    fmax.d f13, f8, f30
    ld x10, 776(x31)
    sd x24, 776(x31)
    addi x8, x27, 1372
    sraiw x18, x13, 1
    sub x10, x23, x4
    sltiu x23, x26, -1527
    add x7, x16, x19
    beq x25, x23, _br_taken_12
    sltu x29, x27, x26
    j _br_done_12
_br_taken_12:
    xor x29, x5, x21
_br_done_12:
    bge x22, x28, _br_taken_13
    add x15, x11, x13
    j _br_done_13
_br_taken_13:
    srl x15, x10, x22
_br_done_13:
    sltiu x28, x15, -231
    fnmadd.d f17, f16, f23, f10
    addw x6, x12, x23
    lb x12, 764(x31)
    sb x6, 764(x31)
    fdiv.s f24, f14, f5
    fadd.s f12, f2, f10
    fmin.s f5, f4, f15
    fsub.s f9, f12, f20
    xori x23, x13, 134
    xori x22, x24, 249
    sltiu x16, x24, -1469
    xori x22, x19, 1937
    srlw x4, x5, x5
    slliw x20, x17, 6
    addiw x20, x5, -1052
    sraiw x21, x17, 13
    slliw x8, x18, 3
    srliw x10, x10, 2
    srli x11, x14, 32
    lb x27, 428(x31)
    sb x22, 428(x31)
    fnmsub.s f5, f11, f2, f6
    fnmsub.s f9, f26, f29, f18
    fadd.d f12, f10, f10
    sraiw x19, x26, 30
    add x4, x26, x7
    sub x28, x22, x14
    and x6, x5, x17
    sltu x1, x26, x5
    slli x23, x13, 12
    srl x5, x29, x10
    srl x18, x19, x26
    sraw x10, x10, x25
    sub x28, x7, x10
    fadd.s f30, f4, f30
    fmin.d f0, f30, f28
    sraiw x7, x29, 10
    addiw x23, x5, -642
    mul x28, x25, x28
    fmul.d f0, f13, f31
    fdiv.s f31, f30, f20
    blt x26, x6, _br_taken_14
    sltu x5, x1, x19
    j _br_done_14
_br_taken_14:
    or x5, x19, x17
_br_done_14:
    remu x4, x27, x22
    divu x13, x13, x20
    addi x30, x31, 272
    amoand.w x20, x5, (x30)
    fdiv.s f24, f13, f3
    fmul.s f13, f25, f5
    fsub.s f10, f31, f25
    addw x14, x29, x13
    add x19, x20, x1
    remuw x9, x20, x18
    sub x21, x19, x4
    lwu x7, 808(x31)
    sw x12, 808(x31)
    bgeu x16, x18, _br_taken_15
    sra x10, x28, x28
    j _br_done_15
_br_taken_15:
    srl x10, x12, x25
_br_done_15:
    or x25, x25, x19
    sltu x28, x24, x22
    divw x7, x1, x8
    mulhsu x25, x21, x23
    sub x1, x10, x12
    srl x1, x18, x26
    slli x17, x28, 24
    slliw x11, x26, 8
    addw x29, x26, x12
    slti x11, x1, 1038
    ld x11, 776(x31)
    sd x5, 776(x31)
    bge x10, x12, _br_taken_16
    or x22, x27, x24
    j _br_done_16
_br_taken_16:
    and x22, x17, x27
_br_done_16:
    bge x25, x17, _br_taken_17
    sltu x15, x22, x15
    j _br_done_17
_br_taken_17:
    and x15, x8, x23
_br_done_17:
    xor x25, x19, x28
    bge x27, x17, _br_taken_18
    xor x17, x9, x6
    j _br_done_18
_br_taken_18:
    slt x17, x22, x24
_br_done_18:
    sra x5, x20, x8
    andi x13, x14, -1456
    srli x26, x28, 1
    lhu x10, 648(x31)
    sh x4, 648(x31)
    bgeu x28, x19, _br_taken_19
    sltu x16, x28, x19
    j _br_done_19
_br_taken_19:
    and x16, x22, x20
_br_done_19:
    lbu x5, 940(x31)
    sb x26, 940(x31)
    bgeu x6, x18, _br_taken_20
    sub x19, x11, x14
    j _br_done_20
_br_taken_20:
    sltu x19, x20, x11
_br_done_20:
    ori x9, x13, 358
    sllw x11, x19, x8
    blt x21, x26, _br_taken_21
    sltu x6, x5, x26
    j _br_done_21
_br_taken_21:
    sub x6, x5, x1
_br_done_21:
    fmax.s f1, f15, f30
    fmul.s f2, f23, f2
    fmin.d f23, f18, f19
    fdiv.s f11, f7, f28
    addw x17, x28, x23
    sra x25, x6, x6
    rem x7, x15, x8
    remuw x19, x6, x25
    fmul.d f4, f29, f26
    srliw x6, x13, 20
    andi x8, x17, 1245
    slti x4, x18, 1210
    or x10, x26, x9
    subw x15, x21, x20
    sub x21, x6, x7
    sraw x23, x16, x19
    subw x12, x22, x1
    lbu x28, 240(x31)
    sb x9, 240(x31)
    bge x12, x28, _br_taken_22
    xor x6, x12, x11
    j _br_done_22
_br_taken_22:
    slt x6, x6, x23
_br_done_22:
    srli x22, x4, 38
    remuw x6, x9, x17
    mul x22, x1, x10
    bgeu x24, x4, _br_taken_23
    or x19, x19, x1
    j _br_done_23
_br_taken_23:
    sub x19, x11, x6
_br_done_23:
    addi x6, x10, -1924
    sub x25, x16, x25
    srlw x22, x29, x12
    slti x9, x14, 748
    srlw x16, x28, x24
    mulh x15, x15, x17
    or x25, x17, x28
    sll x6, x17, x22
    bne x5, x4, _br_taken_24
    xor x28, x8, x12
    j _br_done_24
_br_taken_24:
    and x28, x8, x19
_br_done_24:
    andi x13, x9, -668
    srai x17, x16, 56
    slli x27, x18, 51
    sltiu x27, x21, 1493
    xor x19, x6, x13
    slli x26, x18, 20
    addi x25, x21, 573
    addiw x11, x8, -1657
    slti x19, x15, -1721
    xori x1, x27, 2043
    sltiu x5, x10, -709
    subw x28, x7, x25
    mulh x11, x19, x11
    divu x28, x5, x17
    sraiw x10, x23, 26
    subw x18, x17, x20
    ori x17, x9, -1392
    sra x23, x9, x1
    fdiv.d f0, f6, f26
    fadd.s f17, f22, f30
    fmax.d f11, f10, f20
    fsub.d f1, f31, f12
    beq x14, x22, _br_taken_25
    slt x18, x27, x4
    j _br_done_25
_br_taken_25:
    srl x18, x29, x15
_br_done_25:
    addi x23, x17, -858
    sll x4, x11, x10
    divu x25, x9, x24
    divu x8, x17, x23
    srli x9, x25, 23
    sll x5, x24, x21
    div x5, x7, x5
    mulhsu x19, x15, x23
    slli x10, x5, 54
    and x1, x19, x12
    mulhu x1, x16, x4
    subw x17, x18, x6
    fmadd.s f9, f23, f7, f25
    sub x5, x5, x8
    slliw x12, x18, 31
    ld x16, 312(x31)
    sd x14, 312(x31)
    bgeu x7, x7, _br_taken_26
    sub x25, x22, x22
    j _br_done_26
_br_taken_26:
    slt x25, x10, x11
_br_done_26:
    sll x26, x17, x11
    andi x26, x9, 59
    addi x13, x28, 957
    addi x30, x31, 12
    amomin.w x17, x12, (x30)
    srl x22, x8, x21
    lwu x7, 384(x31)
    sw x18, 384(x31)
    slliw x11, x13, 7
    srliw x18, x1, 18
    slti x15, x23, 1142
    srliw x22, x12, 10
    add x14, x14, x19
    slti x13, x23, 1840
    andi x22, x19, 183
    addiw x25, x23, 1757
    lw x28, 584(x31)
    sw x24, 584(x31)
    sllw x17, x22, x17
    subw x12, x18, x26
    bltu x16, x27, _br_taken_27
    or x24, x13, x27
    j _br_done_27
_br_taken_27:
    sltu x24, x6, x26
_br_done_27:
    slti x13, x16, -1569
    srai x27, x10, 18
    addi x14, x22, 1766
    srliw x10, x19, 28
    mul x25, x25, x19
    mul x6, x29, x1
    sltiu x23, x12, 1446
    ori x25, x23, -1495
    xori x10, x9, 951
    mulhsu x27, x24, x28
    mul x13, x25, x25
    fadd.s f27, f2, f1
    fmax.d f3, f27, f2
    fdiv.s f13, f29, f18
    srliw x25, x22, 5
    xori x5, x5, 1318
    addw x29, x12, x23
    sra x18, x24, x18
    slliw x9, x14, 3
    ori x21, x17, 102
    addi x11, x19, -1340
    bgeu x15, x14, _br_taken_28
    sub x10, x8, x5
    j _br_done_28
_br_taken_28:
    sll x10, x27, x28
_br_done_28:
    add x24, x29, x23
    ori x16, x1, 839
    sraiw x10, x10, 29
    slti x4, x18, -1276
    and x22, x18, x14
    xori x4, x8, 1419
    sllw x4, x26, x6
    andi x24, x13, -1925
    xori x19, x1, 618
    srli x5, x7, 43
    slti x17, x4, 349
    addi x10, x16, 696
    sll x7, x15, x16
    addw x10, x29, x8
    srlw x1, x14, x16
    add x14, x15, x18
    sltu x4, x13, x28
    srliw x16, x5, 18
    lb x25, 812(x31)
    sb x1, 812(x31)
    lbu x20, 860(x31)
    sb x14, 860(x31)
    sraw x18, x21, x21
    xor x15, x20, x14
    srl x21, x15, x4
    addiw x17, x1, -264
    srli x12, x24, 48
    fsub.d f10, f19, f27
    fsub.s f0, f2, f9
    srlw x5, x11, x22
    sltu x22, x20, x27
    sraiw x19, x8, 20
    beq x18, x15, _br_taken_29
    sra x19, x5, x25
    j _br_done_29
_br_taken_29:
    sll x19, x26, x7
_br_done_29:
    mulhsu x15, x8, x10
    ori x10, x11, 1963
    sltiu x23, x17, -791
    or x7, x1, x12
    slt x25, x25, x17
    slliw x24, x23, 16
    sltiu x6, x13, -1317
    lbu x9, 488(x31)
    sb x5, 488(x31)
    blt x17, x26, _br_taken_30
    add x1, x11, x7
    j _br_done_30
_br_taken_30:
    sub x1, x25, x22
_br_done_30:
    mulhsu x19, x10, x27
    mulhsu x5, x12, x9
    blt x10, x20, _br_taken_31
    add x26, x24, x25
    j _br_done_31
_br_taken_31:
    add x26, x5, x8
_br_done_31:
    bge x7, x5, _br_taken_32
    or x13, x26, x19
    j _br_done_32
_br_taken_32:
    srl x13, x28, x22
_br_done_32:
    addi x30, x31, 832
    amoand.d x21, x4, (x30)
    or x25, x29, x25
    srli x18, x25, 54
    fmax.s f26, f11, f17
    fdiv.s f10, f21, f12
    fmul.d f12, f1, f8

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xc1a415629eb7cd54
    .dword 0xff62b109a3f855cb
    .dword 0x90cc032d347d16de
    .dword 0xe96cf7a3f34cde3e
    .dword 0x915175eab9f8a220
    .dword 0xcad15741f6b83f89
    .dword 0x1629d267c7b0094c
    .dword 0x5cca8cd5712ec377
    .dword 0xc466126fad03364a
    .dword 0x7b82ba8a4fb421c4
    .dword 0xd1aca10339f45813
    .dword 0x7ba60d142ed04f9d
    .dword 0xbe7f376571acddc1
    .dword 0xb154da7f2afdf0f9
    .dword 0xb7f82dd192da373d
    .dword 0xbfbe7f59026b67d4
    .dword 0xb31a49a54c5c1a50
    .dword 0x53b2be019a2e6ce9
    .dword 0x83ac16dbd4d831af
    .dword 0x299b830bb5a1a660
    .dword 0xecda96f6a99bbb62
    .dword 0xc1d4dbd464d711b5
    .dword 0x9c2126af0c04d3e4
    .dword 0x8d75a18fc9218b3c
    .dword 0x16ecd5e721f63744
    .dword 0x5271f8b8d26f1761
    .dword 0x959d541b1c6fd718
    .dword 0xbe6a3e9ca15f0c83
    .dword 0xf90176e053ffc8e3
    .dword 0x1829dfec49253b3d
    .dword 0x1fdd53104a9a9712
    .dword 0xc540a2cb6b348733

    .align 2
_torture_data:
    .word 0x644100d9
    .word 0x39121fe6
    .word 0x7ab1e5a1
    .word 0x1bb59b95
    .word 0x4dbde164
    .word 0x958bda73
    .word 0xb115726f
    .word 0x5fdbf000
    .word 0xfbc50e51
    .word 0x45cc44c7
    .word 0x55022cbc
    .word 0x298f7b3f
    .word 0xa753a5a6
    .word 0x47023fd3
    .word 0x24f12599
    .word 0xd5a6e026
    .word 0x06421bc9
    .word 0x9e242040
    .word 0xf29b781e
    .word 0x7d6ecf66
    .word 0x117522eb
    .word 0xb4d4f169
    .word 0x51cee894
    .word 0xd7b490c8
    .word 0x62579ed9
    .word 0x062e7e09
    .word 0xc7a304a6
    .word 0x3e0c9dfe
    .word 0x82d0bb1f
    .word 0x87ce3baf
    .word 0x4096908a
    .word 0xd249df8b
    .word 0xc0fd875d
    .word 0x500d74e8
    .word 0x988d99a0
    .word 0x49aeec6c
    .word 0x19e7c12f
    .word 0x7e3055c4
    .word 0x94411419
    .word 0xb08ed55a
    .word 0x12fda240
    .word 0x51ae2bd1
    .word 0x22bc2ed5
    .word 0x3ccc8eda
    .word 0x4280fd88
    .word 0xcf74c5bf
    .word 0x92b07ddd
    .word 0xc4320a59
    .word 0x3c9ff8f4
    .word 0x29eb5788
    .word 0xf6a510ff
    .word 0xf77abe6b
    .word 0x735b2041
    .word 0x6bc0b1c9
    .word 0xd625b230
    .word 0x6c47cd87
    .word 0x170bc9f8
    .word 0xdf1331b9
    .word 0x1aa25d07
    .word 0x155851f7
    .word 0xbd46cd06
    .word 0x754c280e
    .word 0xb36a4fe6
    .word 0xeb713876
    .word 0xa3d05175
    .word 0xe64013f6
    .word 0x9a094c53
    .word 0x18782666
    .word 0x689966d7
    .word 0x27b050bb
    .word 0x22944538
    .word 0x56b3406a
    .word 0x11554abc
    .word 0xac21277f
    .word 0x98e71503
    .word 0x69d89e09
    .word 0xbd75d2eb
    .word 0xb01597b5
    .word 0x71dd8ad1
    .word 0xa25205dc
    .word 0x9885924c
    .word 0xf00bf848
    .word 0xae240e18
    .word 0x26e27c3e
    .word 0xd8bcf71f
    .word 0xe62162a0
    .word 0x65fca179
    .word 0x6b05c70a
    .word 0xfdcf2474
    .word 0x05bb9bcd
    .word 0x2d68a1a3
    .word 0x0f1ebfe1
    .word 0x0b7a654a
    .word 0x30bac7c9
    .word 0x4442116d
    .word 0x47002c8f
    .word 0x25f0602f
    .word 0xd0df9263
    .word 0xbb1d9833
    .word 0xc7d176c4
    .word 0x60790862
    .word 0xe2586b27
    .word 0x0a10a4a9
    .word 0x3129fb02
    .word 0x95161dc4
    .word 0xa95050b9
    .word 0xa9749cb2
    .word 0xd0b7e24b
    .word 0x4c80ea90
    .word 0x4519adf5
    .word 0x3ece5380
    .word 0x9012a858
    .word 0xe16bc77e
    .word 0xccf0a533
    .word 0x08295151
    .word 0x6b7bbaee
    .word 0x048b265a
    .word 0xa3bf7ab4
    .word 0xce4bc9a9
    .word 0xa75ece7f
    .word 0x242e2bd4
    .word 0x1b94094e
    .word 0xfe1d3038
    .word 0xf4bdcf7b
    .word 0xfdfdbfa4
    .word 0xb6250da4
    .word 0xab52e6ac
    .word 0x893d05a0
    .word 0x16cef205
    .word 0xa3250ab9
    .word 0x139eaa78
    .word 0xc3c6079d
    .word 0xa67857a9
    .word 0xb4b6f273
    .word 0xe4e74038
    .word 0x24c51613
    .word 0x6e1b15f6
    .word 0x789cfa3a
    .word 0xe651ccad
    .word 0xf6f6f0ae
    .word 0x5ce7ab6c
    .word 0xad9bb61b
    .word 0x73aee720
    .word 0xd114c2d6
    .word 0xc03b2c1c
    .word 0xf8aa7d97
    .word 0x2ea304ce
    .word 0xf411cd7f
    .word 0xe3b5e10a
    .word 0xe54a9bff
    .word 0x52f1ce3a
    .word 0x193c894c
    .word 0x1a68e3b5
    .word 0x2f1a2468
    .word 0x49925e09
    .word 0xe9fb4a30
    .word 0x853c47b8
    .word 0xdc99a32e
    .word 0x1be81bc8
    .word 0xc6733e2e
    .word 0xbd6cf9e3
    .word 0xc2874640
    .word 0x5a1b7620
    .word 0x7e3744b0
    .word 0xd9e2e6bd
    .word 0x4cef4488
    .word 0x721a7780
    .word 0x278ae466
    .word 0x6fbf433b
    .word 0x1e308dbf
    .word 0x212109a2
    .word 0x0b84b959
    .word 0x95feaa7c
    .word 0xb602a1c4
    .word 0x73810f9d
    .word 0xdd60b211
    .word 0x6c762ce4
    .word 0x748a6435
    .word 0x50e9f3ee
    .word 0x01e0ae6f
    .word 0xd1d7c3f4
    .word 0x6c19b5ba
    .word 0xd6d8914a
    .word 0x51204b1b
    .word 0x95942a8e
    .word 0x6993911e
    .word 0x09142932
    .word 0xd9d4a968
    .word 0x285c3b9f
    .word 0x84a574d4
    .word 0x5b119b0f
    .word 0xa23d8fa1
    .word 0xe4598406
    .word 0xdcee9128
    .word 0x0d73b873
    .word 0xa8f5e0b2
    .word 0x56fe7dec
    .word 0x2905e042
    .word 0xb4f5bd71
    .word 0x939d43d4
    .word 0x561656fb
    .word 0x16bb0879
    .word 0x98f66cbf
    .word 0xc0f9cf06
    .word 0x28356776
    .word 0xf68ec06b
    .word 0xa5aeebfb
    .word 0x57cf7c05
    .word 0x8c2324bb
    .word 0x3606efb3
    .word 0xdebf66eb
    .word 0x2d25dfd2
    .word 0xe55cd35c
    .word 0xc6a2894e
    .word 0x3bdb8c38
    .word 0xcb63f336
    .word 0x250ed779
    .word 0xca109786
    .word 0x95ac328f
    .word 0xc22061e8
    .word 0xbdcf82fc
    .word 0x7f820525
    .word 0xcc378fa9
    .word 0x8c3e0f2b
    .word 0x7062835d
    .word 0xf9012746
    .word 0x90b9c864
    .word 0x04e01ae7
    .word 0xa5fd0edf
    .word 0xa4989c9c
    .word 0x07696bc5
    .word 0x81885665
    .word 0x148227e9
    .word 0x54b0d5f4
    .word 0xfea3edb8
    .word 0x6fd4b689
    .word 0xc51129b9
    .word 0x4aaa3dcc
    .word 0x7df31600
    .word 0xea39fd0b
    .word 0x4c9016f4
    .word 0x737414c4
    .word 0xd2d24a38
    .word 0x8483f13c
    .word 0xb18ce6e1
    .word 0x533087e8
    .word 0x9cc854dc
    .word 0x64f30236
    .word 0x7ff8a1f0
    .word 0x91edd884
    .word 0x53f98bdb
    .word 0xf9b52b4d
    .word 0xc8fb84fb
    .word 0xe3a179c5
    .word 0x1ce57641
    .word 0x04d8eb51

#include "frost_footer.S"
