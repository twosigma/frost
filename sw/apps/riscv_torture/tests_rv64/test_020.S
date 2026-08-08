// Generated RV64IMAFDC torture test for Frost (seed=20260822)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x1b6990928701ce93
    li x4, 0x2458e54024e466e5
    li x5, 0x3abffd79d002e921
    li x6, 0x9b8d41e8ad451b7d
    li x7, 0xa4da142c606ae61e
    li x8, 0x1a53025457f02a8d
    li x9, 0xcd55d1cb82fa8ae4
    li x10, 0x9f48758c53ae9d68
    li x11, 0xa2eedd242b04a772
    li x12, 0x89271325db3205fc
    li x13, 0x6cea60100d6c34f4
    li x14, 0xe096d90363eb9418
    li x15, 0x5668373b40a0cd58
    li x16, 0xd3746f1e298fdc62
    li x17, 0x9d8b863041025353
    li x18, 0x529688fe12cfde66
    li x19, 0xa16c368fe3e8d1ec
    li x20, 0x0cfb7b4dea20b0b0
    li x21, 0x6fdca490a9f5c390
    li x22, 0xbf5b3018b6eb4646
    li x23, 0x5508d33c966e508f
    li x24, 0x96fd35eae3dbeba9
    li x25, 0x9f2f7ae3524888ad
    li x26, 0x87ae5bec96ae0226
    li x27, 0x6b46a7fa57378095
    li x28, 0xc8c553419b6c993f
    li x29, 0xab97c3230008e98e
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
    li x1, 0xf790ac8b808dbd63

    bge x7, x17, _br_taken_0
    add x15, x18, x8
    j _br_done_0
_br_taken_0:
    sll x15, x6, x28
_br_done_0:
    addi x30, x31, 808
    amoor.w x8, x4, (x30)
    sltu x22, x12, x9
    sltu x8, x24, x29
    sll x18, x29, x9
    fdiv.d f16, f14, f31
    fmul.d f10, f31, f7
    sll x19, x1, x29
    sllw x21, x11, x10
    xori x29, x11, 991
    andi x27, x25, -1361
    bne x15, x7, _br_taken_1
    sub x13, x22, x27
    j _br_done_1
_br_taken_1:
    xor x13, x27, x24
_br_done_1:
    mulh x22, x18, x5
    sltu x19, x26, x29
    add x8, x21, x8
    slliw x13, x28, 4
    and x4, x1, x1
    blt x29, x24, _br_taken_2
    add x7, x1, x24
    j _br_done_2
_br_taken_2:
    sra x7, x21, x29
_br_done_2:
    bne x28, x15, _br_taken_3
    sra x13, x12, x5
    j _br_done_3
_br_taken_3:
    sll x13, x4, x9
_br_done_3:
    andi x26, x12, 785
    addi x15, x27, -1710
    sraw x1, x1, x26
    slli x14, x25, 0
    xori x23, x11, 854
    srli x25, x24, 28
    ori x23, x14, 541
    srlw x13, x12, x1
    sll x13, x28, x26
    fdiv.d f29, f23, f28
    bge x25, x22, _br_taken_4
    sub x21, x25, x20
    j _br_done_4
_br_taken_4:
    xor x21, x27, x13
_br_done_4:
    sraw x19, x24, x7
    srli x29, x29, 34
    lwu x4, 440(x31)
    sw x25, 440(x31)
    andi x23, x4, -1690
    slt x27, x19, x24
    bltu x22, x17, _br_taken_5
    slt x9, x22, x29
    j _br_done_5
_br_taken_5:
    xor x9, x12, x15
_br_done_5:
    slti x26, x24, 1590
    subw x29, x18, x21
    sraiw x12, x4, 26
    and x19, x20, x5
    bgeu x11, x27, _br_taken_6
    and x23, x26, x13
    j _br_done_6
_br_taken_6:
    xor x23, x7, x28
_br_done_6:
    divu x10, x9, x21
    remuw x7, x22, x22
    slti x28, x21, -107
    sltiu x22, x12, -1778
    addiw x15, x26, 243
    fmadd.s f29, f26, f17, f1
    fmul.s f19, f18, f9
    fmsub.s f18, f10, f29, f19
    remw x22, x18, x16
    mulhu x15, x23, x28
    fnmsub.s f23, f19, f19, f11
    fmin.d f3, f25, f25
    fadd.s f6, f13, f23
    bge x24, x19, _br_taken_7
    or x12, x28, x11
    j _br_done_7
_br_taken_7:
    slt x12, x8, x14
_br_done_7:
    slliw x16, x6, 26
    srlw x6, x25, x22
    srliw x17, x18, 22
    srlw x27, x13, x12
    andi x6, x12, -1576
    slt x28, x20, x19
    lh x7, 920(x31)
    sh x11, 920(x31)
    sraw x28, x19, x18
    sll x11, x29, x1
    add x19, x21, x9
    sltiu x17, x6, -1436
    sub x17, x17, x11
    sra x25, x4, x10
    sub x13, x10, x12
    sllw x6, x11, x20
    fdiv.d f26, f10, f22
    fmax.s f29, f16, f5
    sltiu x20, x16, -1750
    andi x11, x4, -319
    srai x4, x10, 17
    sll x27, x26, x7
    fadd.s f2, f28, f19
    fnmsub.s f14, f28, f16, f8
    bge x4, x11, _br_taken_8
    slt x28, x24, x15
    j _br_done_8
_br_taken_8:
    srl x28, x8, x23
_br_done_8:
    bltu x17, x23, _br_taken_9
    add x17, x4, x6
    j _br_done_9
_br_taken_9:
    slt x17, x8, x28
_br_done_9:
    sltu x12, x21, x11
    addw x27, x6, x10
    rem x24, x20, x26
    ori x24, x24, 1907
    bltu x17, x16, _br_taken_10
    add x24, x20, x26
    j _br_done_10
_br_taken_10:
    sub x24, x20, x17
_br_done_10:
    slti x1, x5, -416
    sraw x18, x16, x16
    andi x8, x25, -1764
    beq x25, x25, _br_taken_11
    sltu x18, x28, x22
    j _br_done_11
_br_taken_11:
    xor x18, x28, x11
_br_done_11:
    or x25, x15, x11
    slt x18, x29, x12
    srli x22, x19, 11
    addi x30, x31, 128
    amoswap.d x22, x26, (x30)
    srai x23, x23, 53
    srl x14, x4, x13
    fmax.d f24, f17, f31
    fsub.s f30, f9, f9
    fmul.d f22, f6, f10
    mul x28, x9, x24
    mul x1, x20, x21
    srlw x13, x24, x28
    addiw x20, x25, -1942
    andi x29, x18, -1318
    bge x17, x11, _br_taken_12
    xor x1, x10, x29
    j _br_done_12
_br_taken_12:
    xor x1, x7, x18
_br_done_12:
    lw x14, 368(x31)
    sw x20, 368(x31)
    blt x16, x18, _br_taken_13
    slt x20, x20, x28
    j _br_done_13
_br_taken_13:
    sltu x20, x23, x11
_br_done_13:
    addi x30, x31, 128
    amoand.w x12, x9, (x30)
    sraw x11, x7, x13
    slliw x13, x26, 13
    add x5, x18, x15
    slliw x18, x22, 4
    beq x5, x11, _br_taken_14
    and x6, x6, x29
    j _br_done_14
_br_taken_14:
    add x6, x23, x23
_br_done_14:
    sra x12, x28, x14
    sraiw x8, x20, 4
    xor x11, x12, x1
    slli x7, x24, 55
    sltiu x1, x12, -60
    or x11, x1, x16
    sraiw x19, x19, 5
    remw x12, x23, x9
    mulhsu x28, x6, x29
    srli x18, x27, 15
    sub x21, x29, x1
    srai x27, x14, 2
    bge x26, x14, _br_taken_15
    srl x28, x22, x29
    j _br_done_15
_br_taken_15:
    xor x28, x1, x28
_br_done_15:
    sll x27, x20, x15
    slt x4, x9, x19
    srlw x4, x27, x14
    sll x23, x29, x6
    slli x8, x14, 38
    add x25, x5, x9
    sraiw x10, x29, 13
    andi x8, x19, 1150
    slli x16, x26, 48
    sraw x8, x17, x21
    sltu x14, x21, x20
    slt x15, x17, x1
    or x24, x15, x13
    sraw x21, x4, x7
    bge x25, x15, _br_taken_16
    or x5, x8, x13
    j _br_done_16
_br_taken_16:
    or x5, x18, x6
_br_done_16:
    blt x26, x22, _br_taken_17
    srl x13, x7, x9
    j _br_done_17
_br_taken_17:
    or x13, x17, x28
_br_done_17:
    bltu x26, x22, _br_taken_18
    sub x18, x12, x12
    j _br_done_18
_br_taken_18:
    slt x18, x16, x24
_br_done_18:
    fnmadd.d f30, f26, f1, f30
    slli x26, x28, 36
    subw x6, x9, x12
    fmadd.d f4, f20, f28, f15
    fmin.d f19, f22, f3
    fdiv.d f24, f7, f15
    or x8, x10, x5
    addi x30, x31, 884
    amoswap.w x9, x20, (x30)
    lb x13, 692(x31)
    sb x1, 692(x31)
    addi x30, x31, 628
    amoswap.w x17, x13, (x30)
    fdiv.d f11, f25, f24
    fmul.s f29, f15, f21
    fmadd.d f11, f16, f3, f12
    xori x6, x8, -128
    srl x26, x9, x8
    sll x18, x29, x10
    lh x25, 580(x31)
    sh x29, 580(x31)
    sllw x24, x21, x29
    srliw x1, x20, 4
    slt x20, x18, x14
    slti x29, x26, 282
    addi x15, x20, -785
    and x11, x11, x25
    bne x4, x28, _br_taken_19
    sll x29, x5, x4
    j _br_done_19
_br_taken_19:
    slt x29, x13, x11
_br_done_19:
    and x17, x14, x13
    divuw x23, x14, x6
    lbu x16, 920(x31)
    sb x7, 920(x31)
    xor x23, x13, x17
    srai x14, x1, 17
    lw x5, 308(x31)
    sw x9, 308(x31)
    bgeu x25, x25, _br_taken_20
    or x28, x19, x4
    j _br_done_20
_br_taken_20:
    sltu x28, x23, x17
_br_done_20:
    subw x9, x23, x6
    ori x4, x22, -1013
    srliw x8, x4, 4
    srai x27, x17, 5
    fsub.d f21, f3, f2
    sraiw x22, x11, 3
    srai x10, x8, 33
    or x10, x4, x28
    sub x7, x27, x25
    slli x18, x24, 29
    sraiw x22, x23, 18
    slli x1, x23, 24
    ori x22, x22, -787
    andi x21, x20, -1475
    slt x21, x4, x10
    slt x17, x27, x12
    slliw x9, x27, 11
    sltiu x21, x19, 448
    addi x20, x12, -2025
    blt x7, x16, _br_taken_21
    srl x29, x10, x24
    j _br_done_21
_br_taken_21:
    sra x29, x10, x15
_br_done_21:
    fnmadd.s f30, f5, f20, f8
    fmax.s f4, f0, f21
    fsub.s f7, f16, f23
    slliw x22, x16, 2
    sraw x10, x8, x9
    slti x14, x21, 1754
    sub x7, x7, x5
    srlw x24, x11, x14
    sraiw x20, x16, 19
    lh x13, 1004(x31)
    sh x26, 1004(x31)
    blt x7, x29, _br_taken_22
    sltu x16, x17, x17
    j _br_done_22
_br_taken_22:
    or x16, x13, x10
_br_done_22:
    slt x1, x28, x25
    beq x5, x1, _br_taken_23
    slt x5, x5, x1
    j _br_done_23
_br_taken_23:
    sltu x5, x26, x24
_br_done_23:
    addw x4, x26, x13
    sllw x14, x13, x13
    slt x12, x9, x1
    slli x23, x1, 4
    add x27, x23, x6
    srli x14, x20, 5
    fmul.d f3, f14, f29
    sraiw x21, x18, 29
    xori x16, x29, 1341
    sraw x26, x27, x23
    and x26, x25, x13
    xori x4, x23, -729
    sraiw x17, x12, 25
    andi x18, x7, 200
    fdiv.s f7, f3, f20
    fmul.s f11, f26, f22
    bne x19, x9, _br_taken_24
    srl x9, x25, x9
    j _br_done_24
_br_taken_24:
    or x9, x27, x8
_br_done_24:
    sraiw x20, x18, 14
    slli x8, x15, 16
    slli x20, x13, 34
    blt x16, x11, _br_taken_25
    sltu x17, x26, x23
    j _br_done_25
_br_taken_25:
    or x17, x13, x8
_br_done_25:
    slt x17, x11, x13
    srai x21, x26, 23
    beq x14, x23, _br_taken_26
    slt x14, x10, x24
    j _br_done_26
_br_taken_26:
    or x14, x20, x8
_br_done_26:
    subw x28, x23, x22
    slt x26, x5, x25
    bge x8, x18, _br_taken_27
    and x14, x7, x12
    j _br_done_27
_br_taken_27:
    sra x14, x18, x20
_br_done_27:
    mul x21, x28, x1
    bgeu x24, x24, _br_taken_28
    xor x5, x17, x4
    j _br_done_28
_br_taken_28:
    and x5, x18, x19
_br_done_28:
    lw x16, 60(x31)
    sw x28, 60(x31)
    sub x6, x17, x22
    and x21, x4, x16
    bne x1, x25, _br_taken_29
    sra x14, x6, x8
    j _br_done_29
_br_taken_29:
    sub x14, x28, x13
_br_done_29:
    lw x29, 1008(x31)
    sw x10, 1008(x31)
    lwu x15, 648(x31)
    sw x20, 648(x31)
    sltu x22, x24, x29
    slliw x20, x7, 0
    sraiw x9, x10, 8
    srai x11, x7, 2
    slliw x21, x1, 2
    or x12, x11, x6
    xori x22, x5, -1372
    srai x10, x28, 19
    fmin.d f4, f10, f9
    fsub.s f12, f6, f9
    fdiv.d f26, f16, f24
    beq x13, x15, _br_taken_30
    srl x25, x17, x27
    j _br_done_30
_br_taken_30:
    sll x25, x18, x4
_br_done_30:
    addi x30, x31, 696
    amoor.w x6, x29, (x30)
    fdiv.d f10, f0, f23
    fmin.d f26, f10, f25
    fmax.s f8, f16, f17
    fnmsub.s f4, f14, f6, f30
    lw x10, 724(x31)
    sw x7, 724(x31)
    srlw x5, x27, x21
    sra x28, x12, x28
    srliw x14, x25, 25
    sub x11, x20, x4
    subw x14, x18, x24
    xor x14, x15, x12
    srlw x22, x6, x4
    blt x5, x20, _br_taken_31
    and x27, x14, x29
    j _br_done_31
_br_taken_31:
    or x27, x13, x21
_br_done_31:
    addw x21, x10, x4
    addiw x21, x23, 1244
    blt x19, x19, _br_taken_32
    and x14, x12, x20
    j _br_done_32
_br_taken_32:
    xor x14, x14, x8
_br_done_32:
    fmin.s f20, f7, f23
    xor x8, x14, x9
    andi x9, x17, -1347
    sraiw x9, x6, 5
    srl x22, x28, x24
    add x25, x18, x29
    sltu x27, x22, x8
    or x29, x29, x22
    ori x21, x14, -570
    sllw x28, x13, x10
    bge x8, x17, _br_taken_33
    sra x22, x4, x17
    j _br_done_33
_br_taken_33:
    xor x22, x8, x4
_br_done_33:
    addi x30, x31, 904
    amomin.w x12, x25, (x30)
    sraiw x7, x14, 24
    slt x22, x28, x26
    sub x13, x28, x27
    sraiw x12, x27, 27
    slti x23, x28, 1162
    or x10, x10, x28
    divu x10, x24, x15
    mulw x1, x27, x18
    lh x6, 204(x31)
    sh x28, 204(x31)
    addw x8, x1, x29
    fsub.d f2, f22, f7
    or x13, x14, x24
    srliw x24, x26, 11
    srliw x16, x22, 25
    sll x17, x28, x4
    blt x25, x15, _br_taken_34
    slt x23, x19, x23
    j _br_done_34
_br_taken_34:
    sltu x23, x27, x20
_br_done_34:
    blt x29, x14, _br_taken_35
    sub x28, x16, x27
    j _br_done_35
_br_taken_35:
    srl x28, x5, x22
_br_done_35:
    sra x7, x17, x19
    sub x1, x16, x24
    xori x26, x24, 14
    subw x6, x29, x26
    sltiu x17, x6, -1267
    sra x1, x18, x11
    lbu x18, 268(x31)
    sb x13, 268(x31)
    fadd.s f13, f9, f0
    slti x15, x8, -619
    sraiw x25, x22, 3
    lw x14, 968(x31)
    sw x25, 968(x31)
    or x9, x26, x27
    sub x12, x26, x12
    lw x19, 672(x31)
    sw x27, 672(x31)
    xori x24, x15, -284
    sraw x16, x9, x22
    sraw x20, x24, x14
    sub x27, x19, x12
    addiw x23, x4, -1320
    sraw x6, x15, x19
    fsub.s f29, f22, f5
    fdiv.s f25, f2, f17
    bltu x21, x11, _br_taken_36
    slt x14, x22, x14
    j _br_done_36
_br_taken_36:
    xor x14, x10, x7
_br_done_36:
    sraw x18, x25, x12
    sraiw x1, x27, 22
    lwu x21, 848(x31)
    sw x5, 848(x31)
    lbu x15, 236(x31)
    sb x24, 236(x31)
    lw x11, 788(x31)
    sw x29, 788(x31)
    remw x14, x10, x15
    slti x12, x29, 1153
    blt x4, x25, _br_taken_37
    xor x28, x22, x22
    j _br_done_37
_br_taken_37:
    sltu x28, x10, x24
_br_done_37:
    sraw x11, x28, x28
    sltiu x19, x17, 1267
    slliw x15, x17, 1

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x784a18de09f33022
    .dword 0xf18bac4a6e9a5ae2
    .dword 0x7abc46baab32d3dc
    .dword 0x8744f90822ec5c5e
    .dword 0xa01983b5cd901350
    .dword 0x06f0f8a18e77a783
    .dword 0x45dd7cc4035433e3
    .dword 0xb817f8ea5662eaf1
    .dword 0x98ad717fa7092ef6
    .dword 0x2fb25cdcea16853f
    .dword 0xbd7f8dcd7b3806ca
    .dword 0x4393ea9c6f476267
    .dword 0x7c74d17abb8d76bd
    .dword 0xea0ae2300eeade14
    .dword 0x418ae4aff26c591e
    .dword 0x743c938f028f0a04
    .dword 0xaa0fcc40bc482d9d
    .dword 0xa7d51a7e35c0d9d1
    .dword 0xe716045a22cbf514
    .dword 0xdf98f3d03ee9d3db
    .dword 0xd070e4939419c33c
    .dword 0xd09177260a4ff33e
    .dword 0xa3f69a2df657b14b
    .dword 0x6b2c637b88824cba
    .dword 0xb3a9c4f056dff029
    .dword 0x78b50d885627ec51
    .dword 0xfce399929a397169
    .dword 0x17a855fa795f53a0
    .dword 0x5639c2970853feb0
    .dword 0x5885471e1d97d2d6
    .dword 0x82c7a85a825a7618
    .dword 0xf4c8e5de9416380a

    .align 2
_torture_data:
    .word 0x27532f9a
    .word 0xffd8b326
    .word 0xcc255d9c
    .word 0x69ea7ffc
    .word 0xf3139b63
    .word 0x0edf246f
    .word 0x95dfbd76
    .word 0xa1f47256
    .word 0x17dddce1
    .word 0xf80b5c4d
    .word 0x7579da09
    .word 0x1eafbc12
    .word 0x51c25fc9
    .word 0x546533a4
    .word 0x5734eaab
    .word 0x43f8818d
    .word 0xa4d6c07d
    .word 0xda542ab5
    .word 0xa25b05e1
    .word 0x5735541b
    .word 0x09d94115
    .word 0xdf170ccf
    .word 0xa304eaf6
    .word 0x6f4937a6
    .word 0x797390f9
    .word 0x33514222
    .word 0x1905e815
    .word 0x02db9aef
    .word 0x69470419
    .word 0x2bf0baa3
    .word 0x8c2a2cc3
    .word 0x9d82cad7
    .word 0x76904691
    .word 0xf360904a
    .word 0x2cf51001
    .word 0xc433e1ba
    .word 0xc27210f6
    .word 0x2458a28a
    .word 0x277a3545
    .word 0x74acb48b
    .word 0x2a9fbea8
    .word 0x3e33e625
    .word 0x16296f8b
    .word 0x1f27616d
    .word 0xab1f4ed8
    .word 0xbd925599
    .word 0xc9e9a2ac
    .word 0x5c174904
    .word 0xe8ef58d3
    .word 0x4e5bec2f
    .word 0x2d99ebfa
    .word 0xa78c4fa3
    .word 0xbc0374bc
    .word 0x8d2ed645
    .word 0x1d93fd70
    .word 0x9708c6b8
    .word 0x01e3552d
    .word 0x25f909c4
    .word 0xab1dfb6c
    .word 0xbe2ec02f
    .word 0x17d5b0f1
    .word 0xa96194ff
    .word 0xc9841f2b
    .word 0xbcb90473
    .word 0xee87ca6d
    .word 0x099f52f7
    .word 0x0793ebb3
    .word 0x8598874a
    .word 0xf70339bb
    .word 0xf39d10c3
    .word 0xc723e4ae
    .word 0xfd6e9936
    .word 0xe6c8f23c
    .word 0xb53dc074
    .word 0x2bbdbbad
    .word 0x0b4b6be4
    .word 0x28435f82
    .word 0x92cdd501
    .word 0x0af69040
    .word 0x6fa1528d
    .word 0x578ae9cd
    .word 0x9b5e9fa1
    .word 0x2c48d8fb
    .word 0x30e3c561
    .word 0x5bb04669
    .word 0x35b8a0bf
    .word 0xba204d05
    .word 0x66d844a4
    .word 0x73bdc6d8
    .word 0x0e5b2ce0
    .word 0xde85432a
    .word 0x2c2c0850
    .word 0xe725e3d6
    .word 0x9c506684
    .word 0x43ce1695
    .word 0x78f4bfdf
    .word 0x39a0ba99
    .word 0x79e07627
    .word 0xdb409126
    .word 0x3501f4bb
    .word 0x7e4ba974
    .word 0x790cefb2
    .word 0x52909c62
    .word 0x7207c6b6
    .word 0xdff793b7
    .word 0x01175946
    .word 0x159a660f
    .word 0x2d7d31bb
    .word 0xdf44002c
    .word 0x06faefcd
    .word 0xfcdcbbb6
    .word 0x3a3b7d13
    .word 0x46ece4d0
    .word 0xc9fb30fb
    .word 0x81dc1295
    .word 0x627e5542
    .word 0x67778078
    .word 0xfa0c0a6a
    .word 0x744274e2
    .word 0xefbadd27
    .word 0xb6f89726
    .word 0xfbcad9ec
    .word 0xdca0b3a2
    .word 0x59520935
    .word 0xec1152e3
    .word 0xea7dcfbc
    .word 0x7320f52e
    .word 0x19ae52ac
    .word 0xd017e2c4
    .word 0xf283a304
    .word 0x3a92c401
    .word 0x8d21d4c7
    .word 0x69ddba27
    .word 0xecff8471
    .word 0x22bb2ab0
    .word 0x02e324ad
    .word 0xeb59e758
    .word 0x14165a2c
    .word 0xa8d0f8c7
    .word 0xfcf28cf2
    .word 0xdc714e0b
    .word 0x397564c9
    .word 0x9d04b6a0
    .word 0x231fee52
    .word 0x565163c0
    .word 0x1031cee1
    .word 0xcf0cd15f
    .word 0x6ba608bf
    .word 0x061c1093
    .word 0x3fb65dd2
    .word 0x77ed9613
    .word 0xaf7e494a
    .word 0x54daeadd
    .word 0x3dc0ea3f
    .word 0x5eae81fd
    .word 0x6412f859
    .word 0xe93450ab
    .word 0x4e1036c8
    .word 0x225b55cf
    .word 0x940717be
    .word 0xa73cc60c
    .word 0xcabea07b
    .word 0xd0ed9eb9
    .word 0x0e4ca744
    .word 0xded95cb5
    .word 0x1cc20a9f
    .word 0x0cb27aa5
    .word 0x87015905
    .word 0x110941dc
    .word 0xed95ba4b
    .word 0x2aac19bb
    .word 0x6932751b
    .word 0x09f90c0d
    .word 0x8c084de5
    .word 0x87037fed
    .word 0xe10f5beb
    .word 0xaeebb7c9
    .word 0x09e15233
    .word 0x6d9b4615
    .word 0x8fe4f7f4
    .word 0xc3989574
    .word 0x54d66220
    .word 0x1235fed2
    .word 0xc63df7d4
    .word 0x127c7b52
    .word 0x3726c452
    .word 0xbabb42ea
    .word 0xfc90378f
    .word 0x7e0ab48a
    .word 0xb545f171
    .word 0x7c17acf9
    .word 0x5d572eee
    .word 0x48970089
    .word 0xfa89d0c3
    .word 0x751680d7
    .word 0x58474995
    .word 0xda932d80
    .word 0x4d6d3a4c
    .word 0x4d6167fb
    .word 0xf7abf08e
    .word 0x20960be6
    .word 0xa6130c87
    .word 0x93dd8451
    .word 0xf6c16eed
    .word 0x1cbcd614
    .word 0x042005de
    .word 0x5e4189fe
    .word 0x33933b3a
    .word 0xa48a0b0f
    .word 0x90ab6600
    .word 0x668df2ac
    .word 0x14ead265
    .word 0x0c8d239b
    .word 0xb31a9c8e
    .word 0xcfdd98a8
    .word 0xddd26e44
    .word 0x46833d51
    .word 0xc3631410
    .word 0x5610e3ac
    .word 0x8dbf699f
    .word 0xb5662e9e
    .word 0x7f3e42b8
    .word 0x1a3bc99b
    .word 0x3c23cf09
    .word 0x47ae2fa3
    .word 0xac064b46
    .word 0x7f20d92f
    .word 0xba6c6080
    .word 0x5eb89a6b
    .word 0x062079b6
    .word 0xc7a9990d
    .word 0x2fce912c
    .word 0x147db2f5
    .word 0x955239d2
    .word 0x89ad61a3
    .word 0x28590ec7
    .word 0xffa8fceb
    .word 0xbb7e54c1
    .word 0x6bfab394
    .word 0x848f94e1
    .word 0x35d74c63
    .word 0xa877e50b
    .word 0xd28b25b4
    .word 0x239b45b8
    .word 0x88749e7a
    .word 0xe71efbd9
    .word 0x68b420d3
    .word 0x5d453413
    .word 0x988527b8
    .word 0xdf90768c
    .word 0xccf0060e
    .word 0x99433e19
    .word 0xf69af298
    .word 0x854bf4d6
    .word 0x1e496e02
    .word 0x67fd0b5d

#include "frost_footer.S"
