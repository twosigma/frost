// Generated RV32IMAFDC torture test for Frost (seed=56)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x8f4c29e7
    li x4, 0x85f5a4d1
    li x5, 0x3b1ea24d
    li x6, 0x11549f10
    li x7, 0xa4aa0f71
    li x8, 0x350c2974
    li x9, 0x35fe3633
    li x10, 0x8e9699bf
    li x11, 0x27d77cb7
    li x12, 0xe6e4b3f4
    li x13, 0x2fc27517
    li x14, 0x9d6ae87a
    li x15, 0x8f049254
    li x16, 0x71b2760f
    li x17, 0xb6abf75d
    li x18, 0xacd6bc95
    li x19, 0x30a90768
    li x20, 0xa3d87ef6
    li x21, 0xacb46500
    li x22, 0x955731d8
    li x23, 0x8df0eb4a
    li x24, 0x9c2e1e62
    li x25, 0x5c0c2f80
    li x26, 0xcb0641d1
    li x27, 0xe6207ae4
    li x28, 0x2e40f8a6
    li x29, 0x77b0bad6
    li x30, 0x0277ad31
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
    li x1, 0x4d7724d2

    lw x1, 944(x31)
    sw x7, 944(x31)
    blt x30, x19, _br_taken_0
    slt x8, x5, x4
    j _br_done_0
_br_taken_0:
    sltu x8, x30, x25
_br_done_0:
    fadd.s f30, f19, f13
    fdiv.d f8, f10, f9
    fadd.s f2, f2, f31
    sra x28, x25, x7
    slli x15, x26, 14
    sub x27, x13, x7
    lbu x10, 228(x31)
    sb x16, 228(x31)
    bne x27, x10, _br_taken_1
    sub x12, x30, x22
    j _br_done_1
_br_taken_1:
    sub x12, x9, x6
_br_done_1:
    andi x22, x27, -878
    sltiu x15, x15, -53
    bltu x17, x13, _br_taken_2
    or x27, x6, x14
    j _br_done_2
_br_taken_2:
    or x27, x21, x12
_br_done_2:
    sltu x14, x17, x12
    sltu x30, x1, x25
    addi x11, x31, 588
    amoswap.w x16, x1, (x11)
    bne x4, x16, _br_taken_3
    sll x30, x9, x15
    j _br_done_3
_br_taken_3:
    and x30, x20, x28
_br_done_3:
    andi x4, x17, -232
    add x17, x8, x16
    slli x28, x8, 22
    sll x20, x30, x21
    add x30, x16, x9
    xor x18, x25, x6
    srl x22, x15, x13
    and x10, x29, x12
    sltu x5, x4, x6
    slt x14, x24, x24
    ori x11, x9, -518
    sll x27, x20, x10
    xori x27, x18, 1067
    bge x29, x30, _br_taken_4
    sltu x12, x20, x1
    j _br_done_4
_br_taken_4:
    sll x12, x7, x13
_br_done_4:
    sra x29, x16, x9
    and x1, x19, x26
    lbu x8, 736(x31)
    sb x16, 736(x31)
    fadd.s f10, f16, f4
    addi x25, x31, 688
    amoand.w x28, x21, (x25)
    sll x29, x7, x27
    beq x23, x5, _br_taken_5
    add x28, x12, x28
    j _br_done_5
_br_taken_5:
    sll x28, x7, x8
_br_done_5:
    bge x10, x16, _br_taken_6
    xor x15, x24, x22
    j _br_done_6
_br_taken_6:
    slt x15, x1, x11
_br_done_6:
    blt x27, x16, _br_taken_7
    sub x30, x4, x9
    j _br_done_7
_br_taken_7:
    sll x30, x17, x23
_br_done_7:
    fmax.s f1, f11, f12
    beq x16, x20, _br_taken_8
    sll x23, x19, x22
    j _br_done_8
_br_taken_8:
    sll x23, x10, x30
_br_done_8:
    sll x19, x30, x25
    xor x18, x4, x28
    and x30, x16, x4
    add x20, x19, x16
    fmin.s f7, f9, f17
    addi x11, x31, 8
    amoswap.w x13, x1, (x11)
    lw x14, 92(x31)
    sw x22, 92(x31)
    ori x16, x21, -1809
    beq x24, x23, _br_taken_9
    sub x27, x30, x10
    j _br_done_9
_br_taken_9:
    sra x27, x1, x13
_br_done_9:
    addi x17, x31, 408
    amominu.w x30, x22, (x17)
    lw x27, 532(x31)
    sw x28, 532(x31)
    addi x26, x31, 840
    amoadd.w x5, x12, (x26)
    xor x12, x30, x29
    slt x26, x28, x10
    slti x12, x29, -872
    srli x26, x17, 30
    andi x22, x16, 446
    lh x21, 196(x31)
    sh x10, 196(x31)
    slti x6, x26, 733
    bltu x20, x30, _br_taken_10
    add x26, x29, x18
    j _br_done_10
_br_taken_10:
    sra x26, x19, x30
_br_done_10:
    addi x22, x7, 1893
    sltiu x7, x1, -1427
    fadd.d f27, f20, f10
    fmul.s f30, f13, f16
    fmul.s f1, f4, f15
    remu x11, x6, x11
    mulh x15, x24, x26
    addi x20, x31, 556
    amomin.w x4, x26, (x20)
    bgeu x10, x29, _br_taken_11
    or x13, x15, x5
    j _br_done_11
_br_taken_11:
    and x13, x15, x25
_br_done_11:
    andi x12, x26, 520
    bne x23, x5, _br_taken_12
    sra x27, x24, x19
    j _br_done_12
_br_taken_12:
    or x27, x17, x24
_br_done_12:
    or x28, x27, x8
    bge x29, x18, _br_taken_13
    or x15, x19, x29
    j _br_done_13
_br_taken_13:
    xor x15, x19, x14
_br_done_13:
    blt x13, x4, _br_taken_14
    xor x13, x26, x15
    j _br_done_14
_br_taken_14:
    srl x13, x23, x9
_br_done_14:
    fadd.s f27, f4, f12
    fdiv.d f9, f24, f28
    addi x6, x23, 1549
    andi x27, x6, 696
    slti x12, x28, 2028
    fmax.d f19, f14, f18
    add x19, x21, x8
    xori x26, x7, -880
    bne x7, x24, _br_taken_15
    slt x15, x12, x7
    j _br_done_15
_br_taken_15:
    and x15, x24, x11
_br_done_15:
    blt x14, x4, _br_taken_16
    and x8, x14, x7
    j _br_done_16
_br_taken_16:
    and x8, x4, x10
_br_done_16:
    fmin.s f21, f13, f11
    fmin.d f5, f0, f10
    fdiv.s f5, f0, f26
    div x22, x23, x22
    slli x13, x24, 17
    sra x8, x14, x4
    srai x26, x8, 2
    addi x25, x27, -1058
    sra x28, x27, x8
    sra x10, x19, x28
    fmul.d f24, f21, f5
    fsub.d f10, f28, f22
    fadd.s f9, f5, f18
    and x21, x9, x24
    sra x11, x24, x11
    srli x9, x23, 15
    srli x23, x5, 7
    slti x8, x13, 1948
    bltu x1, x1, _br_taken_17
    sltu x5, x20, x4
    j _br_done_17
_br_taken_17:
    srl x5, x11, x23
_br_done_17:
    sub x25, x8, x9
    mulhu x18, x30, x5
    and x23, x11, x17
    sll x17, x16, x4
    slti x16, x20, -1186
    slt x28, x26, x26
    ori x5, x7, 1885
    and x11, x28, x5
    or x22, x20, x20
    sub x15, x28, x26
    srli x6, x12, 27
    sll x11, x29, x6
    div x16, x6, x26
    srai x27, x14, 11
    sltu x19, x30, x19
    addi x6, x31, 564
    amoxor.w x26, x21, (x6)
    lbu x11, 168(x31)
    sb x5, 168(x31)
    andi x5, x11, 1589
    andi x30, x30, 2024
    slli x22, x24, 30
    sub x10, x6, x21
    bne x21, x5, _br_taken_18
    xor x22, x1, x4
    j _br_done_18
_br_taken_18:
    slt x22, x13, x28
_br_done_18:
    beq x7, x12, _br_taken_19
    add x13, x15, x9
    j _br_done_19
_br_taken_19:
    sltu x13, x19, x9
_br_done_19:
    slti x1, x29, -567
    andi x11, x26, -1800
    slli x7, x24, 22
    srli x15, x1, 15
    xor x29, x6, x5
    add x4, x7, x18
    sltu x11, x25, x10
    bltu x22, x8, _br_taken_20
    and x27, x22, x21
    j _br_done_20
_br_taken_20:
    add x27, x8, x13
_br_done_20:
    sub x23, x13, x9
    ori x12, x27, 2015
    addi x9, x31, 712
    amoxor.w x13, x28, (x9)
    bltu x1, x13, _br_taken_21
    xor x21, x24, x5
    j _br_done_21
_br_taken_21:
    and x21, x6, x10
_br_done_21:
    sltiu x13, x20, 276
    slli x26, x17, 25
    sra x28, x26, x30
    beq x13, x24, _br_taken_22
    xor x9, x12, x11
    j _br_done_22
_br_taken_22:
    and x9, x25, x7
_br_done_22:
    divu x22, x18, x28
    sub x5, x8, x22
    sub x29, x11, x7
    ori x17, x19, -1289
    sra x12, x26, x12
    srli x23, x30, 0
    addi x15, x31, 816
    amominu.w x29, x27, (x15)
    sltiu x4, x20, -38
    srai x13, x10, 1
    srli x20, x1, 0
    srai x23, x29, 15
    ori x30, x28, -1939
    sll x14, x26, x17
    slti x1, x8, -1507
    or x1, x16, x6
    andi x14, x25, -407
    blt x10, x16, _br_taken_23
    and x10, x12, x20
    j _br_done_23
_br_taken_23:
    slt x10, x17, x29
_br_done_23:
    addi x27, x31, 56
    amominu.w x26, x12, (x27)
    bgeu x23, x8, _br_taken_24
    srl x17, x24, x11
    j _br_done_24
_br_taken_24:
    add x17, x5, x1
_br_done_24:
    fadd.s f22, f1, f13
    lbu x15, 1008(x31)
    sb x15, 1008(x31)
    lb x9, 404(x31)
    sb x4, 404(x31)
    srai x11, x11, 23
    addi x5, x28, 1583
    addi x27, x21, -438
    slli x8, x11, 2
    or x9, x19, x26
    addi x16, x31, 468
    amoadd.w x27, x30, (x16)
    mulhu x22, x11, x19
    mulhsu x16, x20, x25
    andi x25, x30, -233
    rem x8, x19, x30
    slti x1, x22, -423
    srli x20, x13, 20
    srai x29, x26, 24
    blt x25, x16, _br_taken_25
    sub x18, x28, x8
    j _br_done_25
_br_taken_25:
    xor x18, x23, x6
_br_done_25:
    lhu x26, 140(x31)
    sh x1, 140(x31)
    and x10, x19, x19
    srli x25, x8, 26
    srl x26, x12, x19
    addi x14, x31, 900
    amoadd.w x9, x10, (x14)
    andi x10, x9, 1108
    srai x23, x7, 31
    bgeu x1, x23, _br_taken_26
    sltu x25, x25, x15
    j _br_done_26
_br_taken_26:
    xor x25, x10, x11
_br_done_26:
    sub x20, x29, x20
    fsub.d f13, f2, f21
    slt x9, x7, x25
    add x24, x23, x30
    slti x14, x1, -1909
    blt x16, x15, _br_taken_27
    sll x21, x16, x26
    j _br_done_27
_br_taken_27:
    sltu x21, x14, x18
_br_done_27:
    beq x28, x8, _br_taken_28
    and x15, x20, x28
    j _br_done_28
_br_taken_28:
    and x15, x11, x26
_br_done_28:
    srli x11, x18, 29
    sltiu x9, x21, -387
    slti x18, x18, 1956
    sltiu x5, x23, 1818
    fdiv.d f15, f1, f11
    fdiv.d f4, f4, f2
    lhu x13, 128(x31)
    sh x5, 128(x31)
    sra x24, x18, x18
    slti x4, x1, -195
    add x4, x6, x11
    sub x1, x25, x19
    sll x5, x1, x12
    srai x15, x17, 20
    xor x11, x21, x28
    srai x15, x18, 20
    bgeu x21, x24, _br_taken_29
    add x15, x8, x24
    j _br_done_29
_br_taken_29:
    xor x15, x18, x24
_br_done_29:
    ori x11, x17, -1796
    sltu x22, x6, x1
    bne x6, x19, _br_taken_30
    or x30, x12, x28
    j _br_done_30
_br_taken_30:
    and x30, x4, x25
_br_done_30:
    xori x16, x8, -277
    andi x15, x30, -941
    slli x13, x10, 28
    srai x10, x26, 14
    lb x6, 692(x31)
    sb x17, 692(x31)
    addi x20, x29, 1591
    addi x1, x15, -1374
    addi x21, x17, 1976
    slli x12, x29, 13
    slti x21, x15, -1883
    lw x1, 252(x31)
    sw x27, 252(x31)
    blt x29, x28, _br_taken_31
    sub x11, x25, x30
    j _br_done_31
_br_taken_31:
    sra x11, x17, x16
_br_done_31:
    or x26, x15, x8
    slli x23, x22, 31
    andi x23, x27, -1901
    ori x20, x22, -1361
    or x7, x24, x29
    and x22, x11, x18
    lh x4, 948(x31)
    sh x30, 948(x31)
    fmul.d f31, f29, f11
    srl x25, x5, x21
    slli x8, x7, 3
    srli x29, x20, 26
    ori x18, x12, -1044
    andi x10, x18, 1310
    srl x8, x14, x22
    slti x23, x16, -985
    addi x14, x31, 164
    amomin.w x24, x17, (x14)
    sltu x29, x16, x11
    and x30, x14, x25
    xori x23, x8, 1152
    srli x25, x24, 29
    ori x29, x26, -312
    ori x18, x27, -176
    and x16, x1, x15
    add x21, x23, x25
    sll x4, x16, x22
    or x18, x4, x21
    lb x6, 484(x31)
    sb x18, 484(x31)
    srai x20, x22, 2
    addi x8, x4, -1657
    slti x15, x19, 207
    slti x5, x15, 1443
    ori x16, x5, -1914
    srli x25, x8, 20
    sll x6, x20, x5
    sltu x22, x15, x11
    beq x8, x21, _br_taken_32
    xor x9, x25, x27
    j _br_done_32
_br_taken_32:
    xor x9, x27, x1
_br_done_32:
    srl x6, x17, x8
    addi x7, x9, 949
    or x4, x6, x26
    sltu x4, x12, x8
    mulhu x13, x30, x13
    div x19, x14, x17
    srli x17, x24, 16
    blt x12, x10, _br_taken_33
    and x13, x22, x23
    j _br_done_33
_br_taken_33:
    and x13, x17, x27
_br_done_33:
    xori x23, x17, 2037
    xori x22, x19, -1148
    rem x30, x14, x30
    mul x15, x18, x11
    rem x28, x8, x18
    beq x10, x9, _br_taken_34
    sltu x15, x10, x27
    j _br_done_34
_br_taken_34:
    srl x15, x5, x23
_br_done_34:
    lbu x12, 780(x31)
    sb x22, 780(x31)
    lh x11, 756(x31)
    sh x6, 756(x31)
    slti x18, x17, -369
    sltu x15, x5, x28
    fadd.s f22, f0, f26
    andi x27, x18, -1318
    lb x4, 860(x31)
    sb x8, 860(x31)
    addi x23, x6, 13
    sll x22, x5, x28
    sltiu x5, x30, -695
    xor x12, x7, x13
    addi x28, x8, 315
    srli x29, x1, 6
    slli x25, x22, 25
    xori x22, x20, 1159
    srli x29, x6, 7
    addi x12, x26, -536
    slti x21, x22, 1735
    fadd.s f23, f8, f3
    fmax.s f4, f18, f21
    blt x10, x4, _br_taken_35
    slt x15, x6, x5
    j _br_done_35
_br_taken_35:
    sub x15, x6, x10
_br_done_35:
    srli x21, x11, 10
    srl x10, x8, x25
    ori x5, x5, 649
    ori x30, x19, 1473
    addi x13, x31, 96
    amoswap.w x30, x26, (x13)
    xori x6, x25, -1484
    or x22, x25, x6
    sltu x11, x15, x30
    ori x17, x30, 810
    bne x29, x22, _br_taken_36
    sub x21, x8, x14
    j _br_done_36
_br_taken_36:
    or x21, x10, x17
_br_done_36:
    lbu x21, 588(x31)
    sb x22, 588(x31)
    srai x7, x22, 9
    andi x14, x8, -1266
    sltiu x30, x15, 739
    andi x30, x1, -803
    ori x17, x28, -866
    slli x1, x1, 6

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x92d63f2e64a9944b
    .dword 0x796b1746159a2a09
    .dword 0x7364f78228c35ec2
    .dword 0xd7e652bbac8a28e7
    .dword 0x900ddd405d8abbc1
    .dword 0x36f4950d97887a0c
    .dword 0x2099dffe02b38da7
    .dword 0xbacf5b258f970141
    .dword 0x9fe8cff2488c057d
    .dword 0xd39de862ffb0c77c
    .dword 0x194874e1168dfa7b
    .dword 0xe5b8663346d26dd1
    .dword 0x753a8ab312f9940c
    .dword 0xf73327b6b271833e
    .dword 0x698e690ba7c9135f
    .dword 0x379adecf3273a2c7
    .dword 0x8eb84f27fc3e208e
    .dword 0x18a3fa8740385567
    .dword 0xa91895187cd80792
    .dword 0x68b4876fd4ac944e
    .dword 0x303b027679ba8f95
    .dword 0x6a08d75b955b40b3
    .dword 0xad9e60ba4db011d7
    .dword 0x669a5808e226a87d
    .dword 0x1b95dc7c1bc2ed1e
    .dword 0xdca2eb31e1489763
    .dword 0xa1cb2d8da02c2f62
    .dword 0x6c0adc50b6e36ee4
    .dword 0xcf4a13496133c8f7
    .dword 0x555263a2bf315c68
    .dword 0xbf91d6d4a17850d8
    .dword 0xa9060d499369f865

    .align 2
_torture_data:
    .word 0x1c48dcab
    .word 0x6e9a6629
    .word 0x56552a3e
    .word 0xc2c90451
    .word 0x62861238
    .word 0xffc4e982
    .word 0xede72250
    .word 0x5af355d8
    .word 0x560cfcd5
    .word 0x05901908
    .word 0x8b87c245
    .word 0x26bc0362
    .word 0xc45302c7
    .word 0xa7d39241
    .word 0xe581b6fc
    .word 0x0eff82ae
    .word 0x46e9dc1c
    .word 0x6c950329
    .word 0xb2c4d00d
    .word 0xe7c1f2d3
    .word 0x9d035383
    .word 0x6f0d4d4d
    .word 0x2eda9edc
    .word 0x1c5b3351
    .word 0x952bb806
    .word 0x90a6414d
    .word 0xea9586f1
    .word 0x47146a70
    .word 0xdde890f1
    .word 0x8739db87
    .word 0xdce7dcb8
    .word 0x944b4a86
    .word 0x89979a98
    .word 0xd723c194
    .word 0xe4cc9172
    .word 0x60945752
    .word 0x59d3cb0e
    .word 0xa5ec40b3
    .word 0xc1a64a7e
    .word 0xf73d61fb
    .word 0x989aae57
    .word 0xdb6c9962
    .word 0x38df32ce
    .word 0x71270989
    .word 0x58b6481e
    .word 0x5bac9dbf
    .word 0x8ecf6196
    .word 0x36598936
    .word 0x9614d879
    .word 0xe8e3114c
    .word 0xe053c25f
    .word 0xa5129386
    .word 0x7ec0c239
    .word 0x3ed90ed9
    .word 0x18df1e0e
    .word 0x5042a077
    .word 0x14b84ea2
    .word 0x9e00dfdf
    .word 0x16be0046
    .word 0xfa181736
    .word 0x8537afaa
    .word 0xd5a54bee
    .word 0xb89c9640
    .word 0x267fbc52
    .word 0xb27d7f75
    .word 0x9bb5004a
    .word 0x6109f434
    .word 0x3d9e39fe
    .word 0x70e185f4
    .word 0x87e4800d
    .word 0x2425144e
    .word 0xda4cb0ba
    .word 0x12a998e1
    .word 0x5eb9868e
    .word 0x34822156
    .word 0xfabaf4a9
    .word 0x3fddd8f0
    .word 0x765eff68
    .word 0x756a4d0a
    .word 0x90b98887
    .word 0x48c2a998
    .word 0x31e16b9a
    .word 0x7e77ae8d
    .word 0x26670b90
    .word 0xc0a9b355
    .word 0xde946a32
    .word 0xdf458a28
    .word 0x893354e0
    .word 0xfaf22ac7
    .word 0x6fa95211
    .word 0x9984a12b
    .word 0xf8ca37f4
    .word 0x8f07d915
    .word 0xd8247a81
    .word 0x638aaa36
    .word 0x23316f0b
    .word 0x3aa82e32
    .word 0xd94a8275
    .word 0xf104aae7
    .word 0x35c190ff
    .word 0x83f27d9b
    .word 0x9088b635
    .word 0x0336970f
    .word 0x69f6c329
    .word 0x6a8c7024
    .word 0x2c3ebd6b
    .word 0xc4079fa3
    .word 0x0fc4bc5e
    .word 0x50910810
    .word 0x8cd2b2ec
    .word 0x28c98a76
    .word 0x45fa33de
    .word 0x42143085
    .word 0xeffcbb51
    .word 0xd410c60d
    .word 0x2c9e6f52
    .word 0x935733bf
    .word 0x35f4e890
    .word 0x72034f81
    .word 0x60f403a2
    .word 0x9b864015
    .word 0x2396241c
    .word 0x90751531
    .word 0xde9de3ad
    .word 0xed062b87
    .word 0x82084c40
    .word 0x68b0729d
    .word 0x8e983d5e
    .word 0x7ad8ea44
    .word 0xac6272e9
    .word 0x09fe0c06
    .word 0xdce1700d
    .word 0xf8f6d5da
    .word 0x631294ab
    .word 0xf62e05d1
    .word 0x1d40d455
    .word 0xcb4092dc
    .word 0x5e751def
    .word 0x9be23b17
    .word 0xbc4d650b
    .word 0xe1e21b68
    .word 0xab56f3be
    .word 0x2e5d427a
    .word 0xb5b0a6d6
    .word 0x037c1bed
    .word 0xebc4accc
    .word 0x5e9f3a8b
    .word 0xd537ad2b
    .word 0xe383422c
    .word 0xf79655cd
    .word 0xce10063f
    .word 0xb7c32f65
    .word 0xe30a4069
    .word 0xf026ade1
    .word 0xd8cca666
    .word 0x7390ea18
    .word 0xb1dd986c
    .word 0x8268fe40
    .word 0xf15064db
    .word 0x92982784
    .word 0x6d7233d0
    .word 0xe8a2bf74
    .word 0x9dcce538
    .word 0x6e65f7cb
    .word 0xfd7bf105
    .word 0x5501a94c
    .word 0xa17f60f2
    .word 0xe05a7c4e
    .word 0x985ed940
    .word 0x4dd59912
    .word 0xaa9137b0
    .word 0x8ea9d7dc
    .word 0xff1d743d
    .word 0x0de00140
    .word 0x987823ad
    .word 0xdfd155f2
    .word 0x6d2ec313
    .word 0x160ef9ba
    .word 0x84e0b19c
    .word 0x6e7db698
    .word 0x4401815f
    .word 0x19fc36eb
    .word 0xb41291fd
    .word 0x8483d36b
    .word 0xecef55f1
    .word 0xa11eca98
    .word 0x8da65a1f
    .word 0xb62c4492
    .word 0xf8cce7f2
    .word 0xe7cd2b2b
    .word 0xb122c3ac
    .word 0xe372b089
    .word 0x192c9c98
    .word 0x4286a638
    .word 0xa681f728
    .word 0x06358bf7
    .word 0x480520e8
    .word 0x3a514da8
    .word 0x83dc8913
    .word 0xb3e62ef8
    .word 0x18531b12
    .word 0x72410517
    .word 0x442d4f2f
    .word 0xd26b5791
    .word 0x4a73cbbe
    .word 0xee1fdb6c
    .word 0xc1a530df
    .word 0x29221eef
    .word 0x763c1f29
    .word 0xbcf35afd
    .word 0x59a34ab8
    .word 0xa78fa21c
    .word 0xf9bce458
    .word 0x7b35416d
    .word 0x81201e1b
    .word 0x885e7a3d
    .word 0xfa2392ab
    .word 0x1627d153
    .word 0x859a33c1
    .word 0xfb0fe28e
    .word 0x1915b395
    .word 0x368c5510
    .word 0xbfb203fd
    .word 0xe860f1d2
    .word 0x108d0fd9
    .word 0x400693cf
    .word 0x8cf2b910
    .word 0x886f5c78
    .word 0xe3d93eb8
    .word 0xf7d84045
    .word 0xbd9ecd89
    .word 0xa5ddfcad
    .word 0x48caef48
    .word 0xe8c3b8fb
    .word 0x6112b9f3
    .word 0x8ac48558
    .word 0xdf6aaf34
    .word 0x1e75cc21
    .word 0x20c32eec
    .word 0xb29ba8d5
    .word 0xd4f5e60d
    .word 0x4fbcf5f6
    .word 0x70c73e16
    .word 0xfc2cbcc5
    .word 0xd1ee4b60
    .word 0xe918b66d
    .word 0xa2707b81
    .word 0x5d4e3882
    .word 0xcfe59a73
    .word 0x7c6271ab
    .word 0x49c82acd
    .word 0xfe4704e5
    .word 0xd5b7d69a
    .word 0xb8b42fde
    .word 0xad255557
    .word 0xabfd5c2f

#include "frost_footer.S"
