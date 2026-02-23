// Generated RV32IMAFDC torture test for Frost (seed=50)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x4423f60d
    li x4, 0xf867f338
    li x5, 0x513fbea0
    li x6, 0x273fd14b
    li x7, 0xd34525ba
    li x8, 0xfacf1de9
    li x9, 0x51c02d66
    li x10, 0x3060458c
    li x11, 0x9b84bd80
    li x12, 0xa28e9f8b
    li x13, 0xf663558e
    li x14, 0xd32ce3dd
    li x15, 0x6e27a042
    li x16, 0x3a2b2995
    li x17, 0xee159bab
    li x18, 0x1b156412
    li x19, 0xe92afe7b
    li x20, 0x75c20cd9
    li x21, 0x943e4ae8
    li x22, 0xd1c6d908
    li x23, 0x7f00bba3
    li x24, 0x2007275d
    li x25, 0x843f529f
    li x26, 0x84487563
    li x27, 0x01b9f3be
    li x28, 0x6934053a
    li x29, 0x3964218a
    li x30, 0x23090e38
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
    li x1, 0x3ee97d30

    sub x23, x10, x24
    sltiu x16, x17, 1378
    xori x18, x5, 1254
    addi x5, x17, -1976
    sltiu x18, x5, 421
    srl x6, x24, x5
    sll x1, x12, x24
    blt x1, x8, _br_taken_0
    add x19, x10, x21
    j _br_done_0
_br_taken_0:
    sra x19, x25, x21
_br_done_0:
    and x20, x7, x10
    sltiu x22, x12, 699
    mul x7, x20, x29
    remu x12, x7, x28
    andi x19, x20, -1044
    sub x1, x6, x12
    bge x11, x12, _br_taken_1
    sltu x28, x10, x28
    j _br_done_1
_br_taken_1:
    sra x28, x29, x10
_br_done_1:
    lw x10, 404(x31)
    sw x12, 404(x31)
    srl x6, x25, x11
    addi x26, x12, -1226
    xori x10, x18, 1153
    beq x19, x12, _br_taken_2
    sub x18, x8, x8
    j _br_done_2
_br_taken_2:
    and x18, x19, x9
_br_done_2:
    andi x25, x24, 1790
    bltu x29, x20, _br_taken_3
    srl x6, x4, x14
    j _br_done_3
_br_taken_3:
    add x6, x9, x30
_br_done_3:
    xor x6, x11, x26
    or x22, x4, x6
    rem x22, x30, x1
    mul x15, x18, x22
    slti x10, x17, -1057
    beq x10, x24, _br_taken_4
    slt x7, x1, x18
    j _br_done_4
_br_taken_4:
    sra x7, x28, x12
_br_done_4:
    lbu x26, 792(x31)
    sb x20, 792(x31)
    lw x4, 280(x31)
    sw x19, 280(x31)
    and x13, x12, x14
    xor x29, x7, x30
    sltiu x13, x20, 1478
    slt x1, x16, x9
    sltu x27, x28, x12
    fmsub.s f10, f15, f22, f0
    fsub.s f6, f25, f27
    ori x17, x12, 1606
    srai x30, x8, 27
    xori x27, x17, 645
    xori x23, x4, 1308
    srl x6, x4, x20
    xor x4, x14, x23
    lhu x11, 360(x31)
    sh x16, 360(x31)
    addi x24, x31, 176
    amoadd.w x12, x22, (x24)
    ori x30, x4, 959
    sltu x12, x15, x25
    sll x18, x24, x16
    srai x12, x1, 3
    or x27, x16, x19
    srl x1, x8, x25
    div x11, x25, x24
    blt x26, x23, _br_taken_5
    sltu x10, x17, x22
    j _br_done_5
_br_taken_5:
    xor x10, x30, x15
_br_done_5:
    andi x15, x21, 831
    srai x26, x29, 11
    lw x22, 572(x31)
    sw x20, 572(x31)
    sltiu x6, x11, -1177
    rem x10, x12, x6
    divu x28, x6, x14
    addi x10, x1, -1345
    lh x13, 908(x31)
    sh x20, 908(x31)
    fmax.s f23, f3, f31
    fmax.s f1, f0, f19
    fmax.s f24, f11, f25
    addi x26, x31, 136
    amomax.w x13, x28, (x26)
    slt x6, x18, x29
    slli x24, x9, 10
    bne x22, x17, _br_taken_6
    sltu x4, x27, x27
    j _br_done_6
_br_taken_6:
    and x4, x7, x26
_br_done_6:
    lhu x20, 84(x31)
    sh x25, 84(x31)
    sltiu x15, x17, 693
    slt x7, x11, x4
    xor x9, x18, x20
    fdiv.d f25, f7, f6
    fmin.d f11, f2, f11
    fmin.s f21, f19, f19
    bne x11, x20, _br_taken_7
    xor x14, x26, x18
    j _br_done_7
_br_taken_7:
    add x14, x11, x17
_br_done_7:
    andi x18, x21, -578
    srl x21, x17, x7
    srai x18, x1, 23
    sll x1, x15, x1
    xori x8, x21, -1542
    lbu x16, 172(x31)
    sb x17, 172(x31)
    addi x17, x31, 496
    amominu.w x28, x8, (x17)
    lh x28, 216(x31)
    sh x19, 216(x31)
    addi x27, x31, 240
    amomaxu.w x23, x7, (x27)
    srai x12, x28, 18
    xor x26, x25, x27
    lb x22, 500(x31)
    sb x13, 500(x31)
    sub x11, x26, x11
    lbu x4, 472(x31)
    sb x16, 472(x31)
    sll x30, x16, x20
    or x5, x19, x12
    add x15, x26, x27
    add x4, x5, x19
    srli x29, x20, 24
    xori x10, x25, 1445
    bne x9, x21, _br_taken_8
    sll x14, x21, x16
    j _br_done_8
_br_taken_8:
    or x14, x19, x9
_br_done_8:
    srli x18, x23, 16
    ori x27, x19, 1021
    xori x26, x15, -123
    bltu x29, x27, _br_taken_9
    add x24, x9, x22
    j _br_done_9
_br_taken_9:
    sub x24, x18, x16
_br_done_9:
    bne x9, x29, _br_taken_10
    and x12, x4, x29
    j _br_done_10
_br_taken_10:
    and x12, x22, x22
_br_done_10:
    sra x15, x13, x20
    ori x15, x24, 1091
    or x13, x28, x22
    addi x19, x31, 800
    amomax.w x11, x17, (x19)
    srl x28, x16, x5
    fmul.d f25, f31, f6
    fnmsub.s f29, f27, f3, f5
    fnmsub.s f28, f5, f21, f8
    fmin.s f10, f10, f27
    beq x14, x10, _br_taken_11
    or x16, x10, x18
    j _br_done_11
_br_taken_11:
    sra x16, x19, x9
_br_done_11:
    slli x25, x17, 21
    slti x29, x17, 971
    sltiu x7, x19, -144
    fmadd.d f25, f12, f27, f29
    fmul.d f22, f14, f1
    fmin.d f27, f23, f6
    beq x16, x29, _br_taken_12
    slt x17, x29, x11
    j _br_done_12
_br_taken_12:
    add x17, x6, x10
_br_done_12:
    bgeu x22, x29, _br_taken_13
    sub x7, x21, x20
    j _br_done_13
_br_taken_13:
    add x7, x6, x14
_br_done_13:
    srai x14, x10, 10
    lb x15, 520(x31)
    sb x6, 520(x31)
    add x13, x21, x22
    sub x19, x5, x18
    andi x20, x6, -475
    srl x12, x5, x12
    fmul.s f24, f23, f17
    fmin.s f10, f17, f0
    fmul.s f2, f4, f3
    fnmsub.s f20, f11, f15, f11
    or x7, x8, x20
    or x24, x18, x1
    sltiu x29, x22, 795
    xori x4, x25, 250
    slt x21, x5, x5
    fmax.s f12, f25, f6
    fsub.s f22, f3, f25
    fmax.s f14, f14, f31
    lbu x9, 656(x31)
    sb x7, 656(x31)
    xor x13, x20, x18
    add x29, x7, x11
    and x1, x12, x12
    xori x16, x27, 1991
    lw x30, 8(x31)
    sw x27, 8(x31)
    bge x27, x16, _br_taken_14
    add x23, x24, x20
    j _br_done_14
_br_taken_14:
    xor x23, x30, x25
_br_done_14:
    bge x9, x4, _br_taken_15
    sll x15, x9, x6
    j _br_done_15
_br_taken_15:
    xor x15, x4, x26
_br_done_15:
    sltu x27, x23, x16
    and x29, x14, x15
    ori x28, x5, -1841
    slt x19, x5, x16
    srai x19, x29, 13
    sltiu x21, x30, -13
    addi x27, x22, 777
    srl x26, x20, x16
    srai x19, x16, 1
    add x30, x25, x8
    sra x26, x23, x11
    fsub.s f6, f27, f28
    bgeu x16, x6, _br_taken_16
    add x12, x13, x24
    j _br_done_16
_br_taken_16:
    srl x12, x21, x19
_br_done_16:
    fmin.s f13, f18, f19
    fdiv.s f20, f25, f29
    fdiv.d f1, f29, f7
    lbu x27, 196(x31)
    sb x17, 196(x31)
    sub x10, x30, x4
    ori x16, x16, -1260
    slti x8, x5, -476
    or x30, x26, x29
    xori x11, x26, 1101
    bge x20, x5, _br_taken_17
    and x14, x28, x14
    j _br_done_17
_br_taken_17:
    or x14, x13, x1
_br_done_17:
    fmin.d f3, f6, f5
    fdiv.d f7, f30, f8
    fmin.s f1, f25, f20
    sll x8, x5, x5
    xori x10, x20, 1145
    ori x26, x23, 525
    sltu x18, x14, x30
    fmadd.s f18, f15, f21, f7
    fmin.s f7, f24, f11
    lw x20, 260(x31)
    sw x25, 260(x31)
    div x29, x12, x6
    divu x21, x7, x22
    fmax.d f4, f17, f2
    fdiv.d f1, f27, f17
    lbu x22, 348(x31)
    sb x21, 348(x31)
    srl x24, x15, x22
    ori x16, x17, 252
    bge x5, x6, _br_taken_18
    and x18, x18, x24
    j _br_done_18
_br_taken_18:
    sra x18, x7, x27
_br_done_18:
    fadd.s f3, f11, f11
    and x13, x8, x5
    slli x1, x10, 5
    xor x11, x6, x20
    lbu x30, 524(x31)
    sb x19, 524(x31)
    lh x26, 380(x31)
    sh x17, 380(x31)
    slti x9, x8, 417
    slti x15, x9, 647
    and x11, x7, x27
    srli x1, x5, 30
    sltu x16, x17, x4
    bge x25, x17, _br_taken_19
    add x27, x15, x23
    j _br_done_19
_br_taken_19:
    sll x27, x4, x6
_br_done_19:
    blt x30, x27, _br_taken_20
    and x10, x20, x18
    j _br_done_20
_br_taken_20:
    sub x10, x13, x8
_br_done_20:
    blt x7, x11, _br_taken_21
    sll x12, x26, x1
    j _br_done_21
_br_taken_21:
    sltu x12, x4, x17
_br_done_21:
    bltu x7, x12, _br_taken_22
    and x18, x6, x9
    j _br_done_22
_br_taken_22:
    srl x18, x29, x30
_br_done_22:
    bne x4, x26, _br_taken_23
    sll x19, x30, x9
    j _br_done_23
_br_taken_23:
    slt x19, x11, x16
_br_done_23:
    slli x12, x27, 24
    sltu x14, x27, x20
    andi x30, x12, -876
    slli x17, x11, 17
    lw x20, 788(x31)
    sw x24, 788(x31)
    srl x1, x8, x7
    slti x23, x8, 518
    slt x23, x11, x23
    rem x15, x24, x1
    rem x22, x7, x5
    bne x27, x18, _br_taken_24
    xor x15, x13, x24
    j _br_done_24
_br_taken_24:
    srl x15, x22, x1
_br_done_24:
    slti x21, x7, 1615
    slt x20, x21, x11
    andi x27, x16, 1670
    lh x18, 348(x31)
    sh x26, 348(x31)
    lhu x9, 972(x31)
    sh x16, 972(x31)
    ori x16, x26, 1161
    srai x7, x28, 10
    srl x17, x6, x17
    slt x12, x26, x14
    bltu x29, x7, _br_taken_25
    or x1, x22, x9
    j _br_done_25
_br_taken_25:
    srl x1, x16, x6
_br_done_25:
    lbu x9, 684(x31)
    sb x17, 684(x31)
    bne x28, x14, _br_taken_26
    and x13, x26, x19
    j _br_done_26
_br_taken_26:
    srl x13, x23, x11
_br_done_26:
    sll x27, x19, x27
    slli x22, x13, 16
    sub x7, x25, x5
    bgeu x23, x21, _br_taken_27
    sub x9, x22, x23
    j _br_done_27
_br_taken_27:
    sltu x9, x4, x18
_br_done_27:
    sra x6, x27, x16
    slli x26, x29, 18
    srai x22, x22, 17
    sll x1, x18, x8
    andi x18, x16, 254
    sltu x16, x11, x26
    srl x17, x19, x19
    beq x9, x22, _br_taken_28
    sltu x17, x30, x8
    j _br_done_28
_br_taken_28:
    xor x17, x16, x6
_br_done_28:
    blt x10, x12, _br_taken_29
    add x15, x18, x30
    j _br_done_29
_br_taken_29:
    xor x15, x15, x11
_br_done_29:
    sub x17, x9, x14
    xori x15, x30, -1547
    addi x5, x28, -1323
    bltu x21, x14, _br_taken_30
    xor x24, x27, x28
    j _br_done_30
_br_taken_30:
    slt x24, x30, x7
_br_done_30:
    xor x19, x24, x25
    slt x26, x30, x9
    sltu x21, x17, x11
    bge x9, x26, _br_taken_31
    sra x1, x1, x25
    j _br_done_31
_br_taken_31:
    sra x1, x5, x5
_br_done_31:
    lhu x15, 900(x31)
    sh x14, 900(x31)
    blt x30, x27, _br_taken_32
    xor x25, x9, x1
    j _br_done_32
_br_taken_32:
    sra x25, x11, x12
_br_done_32:
    srli x21, x19, 31
    andi x27, x22, -107
    and x7, x22, x5
    addi x9, x16, -853
    beq x29, x30, _br_taken_33
    or x4, x4, x28
    j _br_done_33
_br_taken_33:
    sub x4, x12, x28
_br_done_33:
    blt x29, x28, _br_taken_34
    and x10, x28, x18
    j _br_done_34
_br_taken_34:
    or x10, x29, x22
_br_done_34:
    sra x7, x19, x23
    srli x30, x17, 23
    or x23, x16, x18
    slti x19, x8, 1779
    xori x25, x1, 1699
    xori x26, x13, 1906
    sub x20, x13, x14
    slli x27, x8, 19
    xor x12, x9, x8
    bne x29, x28, _br_taken_35
    xor x20, x25, x6
    j _br_done_35
_br_taken_35:
    or x20, x26, x7
_br_done_35:
    sub x14, x17, x30
    sra x11, x1, x6
    mulh x15, x9, x19
    addi x18, x31, 856
    amoswap.w x7, x7, (x18)
    lhu x26, 992(x31)
    sh x20, 992(x31)
    sltu x22, x12, x29
    sltu x12, x30, x23
    slli x8, x25, 22
    sltu x9, x16, x1
    sltiu x24, x29, 1267
    xori x7, x7, -634
    bne x23, x18, _br_taken_36
    sra x10, x14, x27
    j _br_done_36
_br_taken_36:
    sub x10, x6, x14
_br_done_36:
    fmul.s f15, f31, f1
    fnmadd.d f11, f28, f4, f27
    and x12, x15, x12
    andi x11, x7, -858
    bgeu x24, x23, _br_taken_37
    sll x6, x27, x10
    j _br_done_37
_br_taken_37:
    sub x6, x5, x11
_br_done_37:
    bge x30, x17, _br_taken_38
    sub x28, x22, x23
    j _br_done_38
_br_taken_38:
    slt x28, x15, x13
_br_done_38:
    srai x15, x6, 6
    bltu x24, x10, _br_taken_39
    slt x16, x28, x28
    j _br_done_39
_br_taken_39:
    sub x16, x9, x8
_br_done_39:
    lw x16, 132(x31)
    sw x7, 132(x31)
    sltu x23, x9, x22
    srl x7, x26, x18
    sub x9, x28, x26
    slli x12, x28, 16
    slti x1, x11, 2005
    andi x19, x8, 1665
    bge x28, x22, _br_taken_40
    xor x28, x20, x20
    j _br_done_40
_br_taken_40:
    sltu x28, x24, x22
_br_done_40:
    lw x16, 620(x31)
    sw x25, 620(x31)
    sll x14, x20, x18
    add x12, x22, x24
    bge x14, x13, _br_taken_41
    or x11, x9, x11
    j _br_done_41
_br_taken_41:
    srl x11, x13, x22
_br_done_41:
    sra x11, x9, x27
    divu x1, x16, x1
    div x18, x30, x11
    divu x27, x4, x7
    sltiu x18, x24, -1515
    xor x25, x25, x14
    slli x18, x8, 16
    slt x20, x20, x29
    xori x18, x28, -489
    and x24, x10, x23
    srai x18, x20, 30
    slli x24, x14, 0
    sltiu x4, x22, 1109
    fadd.d f23, f18, f22
    sltiu x27, x1, -2007
    add x27, x25, x5
    srai x18, x21, 18
    bltu x24, x26, _br_taken_42
    and x27, x5, x5
    j _br_done_42
_br_taken_42:
    sub x27, x12, x26
_br_done_42:
    srai x27, x17, 25
    fmul.s f6, f12, f25
    fmin.d f16, f0, f3
    fdiv.s f17, f19, f16
    fadd.s f2, f24, f5

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x2dbc21664408deb1
    .dword 0x2b3202652a2c7e41
    .dword 0x2be4d4d31bac09fc
    .dword 0x5b0b505c0340fcca
    .dword 0x47209c4d3ca439d1
    .dword 0x9f72fd8958e4693f
    .dword 0x9a8720f84a864457
    .dword 0x1bf6f662251d8aec
    .dword 0x0808811dc3dfb0c2
    .dword 0xbf2212367c13689a
    .dword 0x1031020dabb8a778
    .dword 0x91d354169ab3e4c2
    .dword 0xc528ce19478bcf73
    .dword 0x547a06e7059ba054
    .dword 0x2fb26363f55d7790
    .dword 0x0b8390a193d92a3a
    .dword 0xa974f6cdc120e975
    .dword 0x600cd9d5922d7dc1
    .dword 0x8ff8904dfd4d0d9d
    .dword 0xe8bc836d3c9931fe
    .dword 0x2996241c71930f2f
    .dword 0xdc7d27a8e9129125
    .dword 0x7b5dc4aa350e6b4e
    .dword 0xe1eef9fd9a02dd1f
    .dword 0xeaa8ff999042063c
    .dword 0x1aa6e139aa189524
    .dword 0x5555e30f2c160de3
    .dword 0x34a7f3d8ec7cc143
    .dword 0x77769b62f4f7babf
    .dword 0x68da1f3cdf53e8d7
    .dword 0xc1a36590eb25dd90
    .dword 0xcf3816f18001db50

    .align 2
_torture_data:
    .word 0x303037f4
    .word 0x21691fc9
    .word 0xc896481e
    .word 0x67474208
    .word 0x23ef41d6
    .word 0x48035be7
    .word 0x280ebb1a
    .word 0x2201b71e
    .word 0x7b6c6926
    .word 0xa21588e2
    .word 0xd9086627
    .word 0x8031f67b
    .word 0x879a1d6d
    .word 0xb67d92a6
    .word 0x95ad40b5
    .word 0xf3e94205
    .word 0x1840d279
    .word 0x8e5c17ec
    .word 0xfd926a1d
    .word 0x5a268c9c
    .word 0xfe07dbfd
    .word 0x272d62f9
    .word 0x6abc1fd0
    .word 0x19b56852
    .word 0xa50f2982
    .word 0xbd654f98
    .word 0xcfca472b
    .word 0x194c480e
    .word 0xa1b90019
    .word 0x9e6bf9f1
    .word 0x4e348fdc
    .word 0x6abff6a6
    .word 0xd6efaeb9
    .word 0xe555cd20
    .word 0x2ba42b4d
    .word 0xeb786c54
    .word 0xb4fd3f9f
    .word 0xf9ef5c18
    .word 0x15c51dc1
    .word 0xf52bc8d5
    .word 0x0dc66925
    .word 0xbe6fda28
    .word 0x4b1804fd
    .word 0x6b7686d3
    .word 0x6a0edc7c
    .word 0x4e18210b
    .word 0xa97a0eeb
    .word 0x7811bfd5
    .word 0xcd49ff5d
    .word 0xca812bba
    .word 0x18bea735
    .word 0x7ef1d81e
    .word 0x69e622e5
    .word 0x0e56ca40
    .word 0x73062c8f
    .word 0x540652d4
    .word 0x7de6ca49
    .word 0xa62da636
    .word 0xf71da808
    .word 0x338870e2
    .word 0x94fffdab
    .word 0xa66a6fde
    .word 0x24d1ac4f
    .word 0x651a8f85
    .word 0xc18a3b54
    .word 0x10889cdd
    .word 0xf35696f9
    .word 0xb8a2326a
    .word 0x352ac65a
    .word 0x8a5ec279
    .word 0x91a11854
    .word 0x31a45c7a
    .word 0x958d8622
    .word 0x4637f196
    .word 0x043e4237
    .word 0x3b61d21b
    .word 0xcd7d87d9
    .word 0x08c289d9
    .word 0x608dac90
    .word 0xe23dad23
    .word 0x7d3b8307
    .word 0x79eb4da6
    .word 0xa2ba388e
    .word 0xbcd22805
    .word 0x09b5debe
    .word 0x80c806fa
    .word 0x6b415cbb
    .word 0x0eafe93f
    .word 0x20dcbd2d
    .word 0xa06be00c
    .word 0xf396c38d
    .word 0x14230c22
    .word 0xd9000366
    .word 0xa2dc4a02
    .word 0xd56a1cb9
    .word 0x6b6ee856
    .word 0xc08a8ff4
    .word 0x656143f8
    .word 0x82070e29
    .word 0xbea36771
    .word 0xe9607602
    .word 0xeac75b3b
    .word 0xdac8ce4e
    .word 0xa2e358e3
    .word 0x36fc3863
    .word 0x05c2f88b
    .word 0xbfb98e44
    .word 0xd82d9a40
    .word 0xc6a39c94
    .word 0xbb647f75
    .word 0xbc7520b5
    .word 0x84191e69
    .word 0x0685ec3e
    .word 0x219a3d5a
    .word 0x8288c8c1
    .word 0xcb1f18b5
    .word 0xb8c0d9eb
    .word 0xa41026bf
    .word 0x211f1e50
    .word 0xc968b8c4
    .word 0x2a9cb3a7
    .word 0xd07fc656
    .word 0x2cbea6ce
    .word 0xff8c62a8
    .word 0x988ae1a8
    .word 0x73be4622
    .word 0x84f80ed2
    .word 0x447d16be
    .word 0xbbf787e7
    .word 0x3334a248
    .word 0x92325674
    .word 0xcf1f297c
    .word 0x18fcbfdb
    .word 0x77530a33
    .word 0xd491e954
    .word 0xa7289f5c
    .word 0x2b20256a
    .word 0x1ee3531c
    .word 0x508b03b9
    .word 0x21b2bffc
    .word 0x01f19712
    .word 0x4787abaa
    .word 0xcd5c2ba5
    .word 0x22e3605a
    .word 0x149d40ee
    .word 0xb9df24f3
    .word 0x2f45a938
    .word 0x6f1c80a7
    .word 0x9dfb2e67
    .word 0xa7b4997c
    .word 0x7ca5103a
    .word 0xe29fab01
    .word 0xf046c103
    .word 0x6f1ac389
    .word 0x927d5195
    .word 0xbeee5978
    .word 0xff723d1e
    .word 0x8f373543
    .word 0x6086a124
    .word 0xafe9f7cc
    .word 0x94dceef4
    .word 0x4aea338d
    .word 0x71eb5134
    .word 0xcaaee7d9
    .word 0x1369af3b
    .word 0x64662a67
    .word 0xb906726f
    .word 0x6999874a
    .word 0x4aaed858
    .word 0x25e8874d
    .word 0xb923a1b1
    .word 0x7f20fb72
    .word 0x649bd883
    .word 0xf982e52a
    .word 0x969e667d
    .word 0x0a1501ae
    .word 0x873b5d3e
    .word 0xb0dfeb4f
    .word 0x594764bd
    .word 0x7e4bd783
    .word 0xd10bc810
    .word 0x71c9b69e
    .word 0x84abed92
    .word 0x508d2040
    .word 0x2041d020
    .word 0x906d7c90
    .word 0x3380209f
    .word 0xbaa80a13
    .word 0xd9fe1db7
    .word 0x1c141751
    .word 0x2551e995
    .word 0xe825edf2
    .word 0x07720972
    .word 0x1a39936d
    .word 0x4a16ec46
    .word 0x8be92f90
    .word 0x91309203
    .word 0x67a56e9b
    .word 0xd854afe2
    .word 0x2bee9e6d
    .word 0x19f9f8ed
    .word 0x4eb84a2a
    .word 0xba29dd98
    .word 0xa4afcb60
    .word 0x1af878f9
    .word 0x48b6fef4
    .word 0xddfd35d1
    .word 0x7914a289
    .word 0x5aa24cb6
    .word 0x85db25c0
    .word 0x57dbd44f
    .word 0xaab26e28
    .word 0x469fba2e
    .word 0x76ac47b9
    .word 0xf2a76cba
    .word 0xc7854cb8
    .word 0x2e8d9fae
    .word 0x59b8378b
    .word 0x6de42b50
    .word 0x242dd511
    .word 0x2be09cf0
    .word 0xdecc111d
    .word 0xf1086ae5
    .word 0x5eb5448a
    .word 0xe74ce430
    .word 0x88729b1b
    .word 0x24288bf5
    .word 0x25a11a23
    .word 0x6803d8d8
    .word 0xfd382b52
    .word 0x37406449
    .word 0x6870dbfb
    .word 0xedd45373
    .word 0x6126a6f3
    .word 0xc522d47f
    .word 0x0551d3fc
    .word 0x9728a759
    .word 0x7b438b80
    .word 0x9394721b
    .word 0x1ba1fc2f
    .word 0xffeef2ad
    .word 0xb40df2e8
    .word 0x65b5db1a
    .word 0xfed4f61a
    .word 0xf0508bb4
    .word 0x60589bb9
    .word 0x4006d3bc
    .word 0x8972c6cb
    .word 0x9ca1a50e
    .word 0x27a8a9cd
    .word 0x5c9507d9
    .word 0x27f64d7a
    .word 0x8f1a637b
    .word 0x5d03280f
    .word 0x004f96d6
    .word 0x5d1c5447

#include "frost_footer.S"
