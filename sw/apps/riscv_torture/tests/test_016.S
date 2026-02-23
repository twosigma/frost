// Generated RV32IMAFDC torture test for Frost (seed=57)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x0ae59635
    li x4, 0x04f18db9
    li x5, 0x839dc54e
    li x6, 0xfa057b26
    li x7, 0xf96678d0
    li x8, 0xe24cfa40
    li x9, 0xbc532a3d
    li x10, 0x9ab664e7
    li x11, 0x60c3454a
    li x12, 0xfa1aed9f
    li x13, 0xaee8a144
    li x14, 0x8bde68de
    li x15, 0x9dc3c7eb
    li x16, 0x90b59369
    li x17, 0x23b14604
    li x18, 0xc3301bc6
    li x19, 0x96e7b86e
    li x20, 0x3840f0cb
    li x21, 0xdafa6f74
    li x22, 0x37b754d1
    li x23, 0x723a1c65
    li x24, 0xa367f655
    li x25, 0x721a0c8e
    li x26, 0xf0f447bc
    li x27, 0x5764cb62
    li x28, 0x92881b9f
    li x29, 0x4dcb932c
    li x30, 0xfe6f59d9
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
    li x1, 0x59690c41

    addi x18, x24, -767
    or x11, x25, x8
    or x10, x7, x21
    bgeu x6, x27, _br_taken_0
    sra x4, x13, x9
    j _br_done_0
_br_taken_0:
    sll x4, x30, x21
_br_done_0:
    srli x1, x6, 10
    bge x20, x8, _br_taken_1
    xor x5, x8, x20
    j _br_done_1
_br_taken_1:
    slt x5, x15, x30
_br_done_1:
    xori x10, x28, 1236
    sub x28, x4, x10
    fdiv.s f7, f1, f16
    bne x14, x25, _br_taken_2
    xor x13, x15, x15
    j _br_done_2
_br_taken_2:
    slt x13, x15, x8
_br_done_2:
    or x9, x16, x24
    slti x19, x16, -1048
    addi x5, x11, -1670
    sub x24, x4, x25
    xor x23, x9, x1
    srli x26, x28, 15
    add x20, x4, x15
    blt x12, x25, _br_taken_3
    slt x21, x30, x18
    j _br_done_3
_br_taken_3:
    sll x21, x11, x4
_br_done_3:
    add x7, x17, x22
    andi x20, x25, 1583
    sll x6, x14, x21
    srai x9, x17, 8
    addi x10, x31, 372
    amoand.w x14, x11, (x10)
    sltiu x12, x10, -591
    slti x10, x26, -669
    srl x28, x24, x29
    srli x18, x23, 24
    ori x23, x1, 1086
    sub x11, x13, x24
    xor x23, x6, x13
    and x13, x30, x12
    and x9, x30, x5
    slti x20, x24, 1333
    srli x25, x10, 15
    bne x24, x26, _br_taken_4
    or x20, x4, x6
    j _br_done_4
_br_taken_4:
    sltu x20, x11, x8
_br_done_4:
    lw x22, 516(x31)
    sw x16, 516(x31)
    lw x20, 696(x31)
    sw x19, 696(x31)
    xor x7, x18, x15
    lw x4, 768(x31)
    sw x8, 768(x31)
    xor x10, x19, x11
    srl x8, x13, x14
    slti x26, x30, -1300
    blt x24, x15, _br_taken_5
    sltu x27, x12, x23
    j _br_done_5
_br_taken_5:
    and x27, x11, x15
_br_done_5:
    add x15, x5, x21
    add x1, x6, x20
    sltu x13, x13, x19
    bgeu x26, x30, _br_taken_6
    or x6, x20, x20
    j _br_done_6
_br_taken_6:
    sub x6, x26, x7
_br_done_6:
    mulhsu x8, x7, x17
    fmsub.s f23, f14, f10, f15
    and x22, x12, x7
    sub x26, x20, x28
    lhu x15, 640(x31)
    sh x1, 640(x31)
    srli x20, x15, 13
    andi x14, x7, 397
    sra x13, x6, x30
    div x27, x20, x30
    and x21, x26, x4
    or x6, x18, x22
    sltu x25, x17, x27
    fadd.d f23, f23, f19
    xor x24, x8, x10
    sltiu x11, x23, -1972
    andi x5, x7, 1530
    addi x17, x31, 864
    amominu.w x11, x20, (x17)
    remu x16, x6, x10
    mul x24, x18, x7
    fmin.d f27, f14, f17
    fsub.s f26, f5, f19
    fnmadd.s f31, f4, f4, f0
    fnmadd.d f23, f29, f14, f23
    fdiv.s f1, f5, f8
    fmin.s f10, f5, f25
    slt x11, x13, x8
    srl x9, x10, x18
    sltiu x24, x29, -867
    slti x14, x24, 1365
    sll x5, x21, x20
    srli x21, x17, 24
    ori x1, x28, 567
    sub x30, x22, x21
    mulhu x13, x13, x23
    div x11, x10, x20
    srl x6, x16, x27
    sra x16, x22, x4
    mulhsu x12, x14, x13
    srai x12, x11, 19
    srl x10, x28, x24
    addi x6, x13, 731
    xori x11, x21, -952
    xor x16, x27, x30
    sub x22, x9, x30
    lw x19, 292(x31)
    sw x26, 292(x31)
    xor x10, x28, x26
    bgeu x6, x28, _br_taken_7
    add x29, x8, x1
    j _br_done_7
_br_taken_7:
    slt x29, x29, x12
_br_done_7:
    remu x28, x1, x11
    div x21, x10, x6
    sub x13, x9, x16
    srl x12, x24, x25
    addi x26, x8, 1915
    srl x18, x30, x26
    sltiu x17, x17, 1223
    sltu x26, x11, x13
    sra x25, x19, x12
    rem x21, x13, x20
    addi x19, x18, -1687
    sll x7, x23, x7
    slti x9, x27, -1904
    fmax.d f4, f21, f24
    fadd.s f10, f28, f26
    slli x16, x5, 10
    andi x24, x13, 726
    slt x17, x15, x30
    addi x9, x27, 171
    ori x28, x28, 873
    lb x11, 544(x31)
    sb x6, 544(x31)
    sltiu x7, x9, -1350
    sltu x5, x23, x17
    slti x13, x24, 983
    sra x8, x30, x28
    add x7, x30, x16
    sub x8, x25, x22
    slli x13, x17, 16
    fsub.d f4, f11, f2
    and x16, x4, x20
    or x13, x15, x6
    andi x29, x28, -1202
    addi x6, x31, 924
    amoswap.w x20, x8, (x6)
    slt x10, x29, x9
    ori x30, x28, 643
    sltiu x5, x25, 883
    beq x21, x23, _br_taken_8
    xor x1, x23, x18
    j _br_done_8
_br_taken_8:
    srl x1, x7, x21
_br_done_8:
    lw x19, 388(x31)
    sw x10, 388(x31)
    sltu x4, x21, x22
    sltiu x12, x18, 486
    slti x15, x26, -857
    srl x25, x21, x5
    srai x30, x17, 3
    slli x7, x18, 13
    andi x22, x21, 798
    sra x30, x28, x28
    srl x14, x26, x11
    beq x16, x17, _br_taken_9
    sub x24, x19, x26
    j _br_done_9
_br_taken_9:
    sll x24, x28, x23
_br_done_9:
    srai x21, x8, 13
    slli x20, x14, 21
    sub x7, x15, x24
    sra x20, x15, x21
    slli x26, x8, 17
    sub x27, x28, x15
    andi x23, x9, -1278
    srl x30, x8, x5
    srl x8, x23, x21
    slti x18, x4, -1546
    mul x25, x5, x9
    div x18, x26, x6
    bltu x16, x6, _br_taken_10
    sll x7, x24, x8
    j _br_done_10
_br_taken_10:
    and x7, x18, x19
_br_done_10:
    lh x12, 292(x31)
    sh x14, 292(x31)
    sra x4, x1, x22
    add x20, x19, x14
    fsub.s f19, f7, f15
    slt x8, x23, x23
    bltu x11, x23, _br_taken_11
    add x14, x27, x15
    j _br_done_11
_br_taken_11:
    srl x14, x1, x4
_br_done_11:
    fsub.d f20, f13, f21
    divu x6, x26, x29
    mulhu x6, x23, x7
    fmin.d f12, f9, f18
    fmax.s f28, f19, f24
    fsub.s f4, f0, f9
    fmul.d f21, f1, f7
    andi x9, x16, -170
    blt x23, x11, _br_taken_12
    and x7, x18, x1
    j _br_done_12
_br_taken_12:
    sltu x7, x19, x13
_br_done_12:
    or x26, x10, x9
    slti x8, x4, -1457
    xori x9, x12, 1139
    bltu x9, x8, _br_taken_13
    sltu x27, x16, x8
    j _br_done_13
_br_taken_13:
    sra x27, x14, x18
_br_done_13:
    addi x4, x31, 324
    amoand.w x22, x24, (x4)
    bge x28, x17, _br_taken_14
    sra x26, x29, x14
    j _br_done_14
_br_taken_14:
    sub x26, x18, x10
_br_done_14:
    beq x25, x27, _br_taken_15
    sltu x14, x21, x7
    j _br_done_15
_br_taken_15:
    sra x14, x21, x8
_br_done_15:
    div x24, x29, x26
    mulhsu x21, x25, x30
    sra x9, x25, x30
    slt x5, x1, x25
    addi x27, x24, 222
    bltu x29, x24, _br_taken_16
    and x19, x19, x10
    j _br_done_16
_br_taken_16:
    slt x19, x24, x8
_br_done_16:
    sll x18, x10, x21
    addi x1, x15, 753
    addi x19, x16, -1300
    andi x7, x20, -1508
    bltu x8, x26, _br_taken_17
    add x22, x7, x27
    j _br_done_17
_br_taken_17:
    sra x22, x28, x18
_br_done_17:
    addi x29, x31, 1016
    amomin.w x30, x11, (x29)
    slli x18, x16, 5
    slli x5, x1, 16
    fmul.s f17, f0, f2
    fmin.s f13, f7, f8
    fmax.d f22, f11, f24
    add x10, x30, x12
    xori x22, x5, -1504
    andi x4, x11, -1081
    srl x21, x25, x4
    addi x18, x31, 640
    amoswap.w x21, x12, (x18)
    and x6, x20, x1
    xor x22, x1, x13
    bltu x6, x18, _br_taken_18
    xor x7, x18, x18
    j _br_done_18
_br_taken_18:
    and x7, x22, x12
_br_done_18:
    bgeu x12, x10, _br_taken_19
    xor x8, x30, x23
    j _br_done_19
_br_taken_19:
    sra x8, x19, x6
_br_done_19:
    add x18, x20, x10
    srli x13, x5, 5
    sra x1, x28, x23
    bne x12, x10, _br_taken_20
    srl x17, x16, x9
    j _br_done_20
_br_taken_20:
    sll x17, x11, x30
_br_done_20:
    fadd.s f19, f5, f14
    fnmsub.s f29, f14, f29, f17
    fsub.d f15, f22, f18
    slt x8, x4, x23
    slt x20, x13, x28
    beq x18, x7, _br_taken_21
    and x13, x5, x7
    j _br_done_21
_br_taken_21:
    sll x13, x30, x5
_br_done_21:
    slli x27, x10, 14
    addi x21, x22, 1078
    bltu x26, x13, _br_taken_22
    sll x30, x27, x21
    j _br_done_22
_br_taken_22:
    sub x30, x1, x4
_br_done_22:
    beq x17, x1, _br_taken_23
    srl x4, x10, x9
    j _br_done_23
_br_taken_23:
    sub x4, x29, x18
_br_done_23:
    beq x14, x28, _br_taken_24
    xor x16, x18, x10
    j _br_done_24
_br_taken_24:
    sll x16, x6, x9
_br_done_24:
    slt x8, x12, x22
    and x20, x22, x8
    sltiu x12, x5, 977
    slti x1, x15, -1755
    lhu x6, 436(x31)
    sh x11, 436(x31)
    bgeu x20, x8, _br_taken_25
    sra x4, x15, x29
    j _br_done_25
_br_taken_25:
    sll x4, x11, x23
_br_done_25:
    addi x18, x22, 496
    slli x9, x21, 25
    srai x27, x25, 9
    addi x27, x31, 224
    amoadd.w x11, x17, (x27)
    slti x27, x17, 545
    slti x30, x13, -1110
    slt x19, x21, x27
    blt x18, x14, _br_taken_26
    sub x23, x29, x17
    j _br_done_26
_br_taken_26:
    or x23, x17, x30
_br_done_26:
    srli x23, x1, 0
    xor x7, x11, x27
    srli x9, x17, 11
    beq x6, x7, _br_taken_27
    or x7, x14, x22
    j _br_done_27
_br_taken_27:
    add x7, x9, x11
_br_done_27:
    xor x18, x15, x30
    and x11, x15, x13
    fmin.s f25, f14, f31
    fdiv.d f10, f2, f21
    fmax.s f5, f3, f3
    addi x1, x31, 484
    amoor.w x6, x15, (x1)
    bgeu x21, x16, _br_taken_28
    and x16, x1, x11
    j _br_done_28
_br_taken_28:
    sltu x16, x26, x6
_br_done_28:
    beq x20, x26, _br_taken_29
    sra x25, x26, x20
    j _br_done_29
_br_taken_29:
    slt x25, x18, x22
_br_done_29:
    bne x9, x1, _br_taken_30
    sra x28, x8, x16
    j _br_done_30
_br_taken_30:
    add x28, x29, x15
_br_done_30:
    bge x17, x30, _br_taken_31
    sub x9, x26, x11
    j _br_done_31
_br_taken_31:
    sub x9, x17, x24
_br_done_31:
    srl x29, x15, x29
    slti x10, x26, 779
    srai x9, x22, 12
    or x10, x10, x19
    bne x14, x22, _br_taken_32
    sub x19, x14, x26
    j _br_done_32
_br_taken_32:
    slt x19, x22, x15
_br_done_32:
    addi x4, x31, 216
    amomin.w x10, x22, (x4)
    lh x11, 28(x31)
    sh x18, 28(x31)
    addi x19, x31, 536
    amoor.w x21, x4, (x19)
    bltu x13, x4, _br_taken_33
    sra x30, x13, x6
    j _br_done_33
_br_taken_33:
    srl x30, x29, x10
_br_done_33:
    fadd.d f22, f2, f1
    fdiv.d f15, f21, f4
    addi x18, x18, 1150
    sub x18, x4, x6
    sub x24, x14, x18
    slti x17, x18, -1164
    sra x17, x12, x23
    fsub.s f17, f29, f21
    fadd.d f24, f19, f4
    fmin.d f17, f18, f5
    ori x6, x11, -1366
    fnmadd.d f18, f31, f10, f6
    fdiv.d f0, f28, f31
    beq x1, x4, _br_taken_34
    add x5, x30, x9
    j _br_done_34
_br_taken_34:
    sltu x5, x11, x14
_br_done_34:
    fsub.d f2, f18, f9
    fnmadd.s f22, f22, f22, f11
    addi x18, x31, 848
    amoswap.w x11, x29, (x18)
    sra x6, x10, x8
    bge x27, x19, _br_taken_35
    xor x23, x26, x17
    j _br_done_35
_br_taken_35:
    sltu x23, x12, x10
_br_done_35:
    srai x27, x30, 4
    lw x1, 548(x31)
    sw x10, 548(x31)
    srai x24, x12, 8
    bne x29, x12, _br_taken_36
    add x12, x29, x13
    j _br_done_36
_br_taken_36:
    sra x12, x25, x4
_br_done_36:
    add x20, x22, x17
    srai x26, x18, 15
    srai x12, x24, 22
    blt x8, x16, _br_taken_37
    sra x25, x24, x20
    j _br_done_37
_br_taken_37:
    add x25, x1, x14
_br_done_37:
    fdiv.s f11, f8, f2
    fmsub.s f2, f31, f18, f24
    addi x21, x31, 88
    amoand.w x20, x27, (x21)
    sltu x4, x20, x14
    srai x15, x4, 30
    or x12, x13, x30
    xori x30, x13, -1492
    blt x10, x28, _br_taken_38
    sltu x20, x8, x14
    j _br_done_38
_br_taken_38:
    or x20, x5, x26
_br_done_38:
    or x29, x16, x10
    addi x20, x27, 222
    lw x22, 856(x31)
    sw x8, 856(x31)
    lw x10, 560(x31)
    sw x9, 560(x31)
    srli x25, x15, 31
    srl x15, x10, x22
    srli x7, x28, 0
    addi x7, x29, 1039
    xori x6, x10, -1150
    sltiu x21, x15, -1986
    slti x23, x30, -1958
    fsub.s f29, f20, f15
    fmul.s f26, f28, f12
    fmin.s f11, f6, f29
    bltu x29, x1, _br_taken_39
    xor x16, x8, x1
    j _br_done_39
_br_taken_39:
    add x16, x29, x12
_br_done_39:
    bltu x17, x30, _br_taken_40
    srl x11, x24, x26
    j _br_done_40
_br_taken_40:
    srl x11, x14, x20
_br_done_40:
    lhu x6, 1012(x31)
    sh x22, 1012(x31)
    blt x24, x10, _br_taken_41
    and x17, x1, x8
    j _br_done_41
_br_taken_41:
    xor x17, x16, x11
_br_done_41:
    slti x1, x16, -707
    srai x21, x1, 24
    bltu x14, x1, _br_taken_42
    sltu x22, x21, x16
    j _br_done_42
_br_taken_42:
    or x22, x29, x29
_br_done_42:
    lb x6, 312(x31)
    sb x15, 312(x31)
    addi x24, x31, 520
    amomax.w x29, x5, (x24)
    srai x29, x20, 19
    slli x17, x12, 9
    fdiv.d f23, f7, f17
    fmin.s f2, f28, f14
    fmul.d f12, f28, f3
    fmax.s f14, f13, f8
    lw x23, 260(x31)
    sw x28, 260(x31)

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x426d2e4501c332fe
    .dword 0xdd39fd38abace2ca
    .dword 0x7f8daf6e68d5e3e6
    .dword 0x1755ba704092c1d6
    .dword 0xd48f1f70929999b1
    .dword 0x1ac564984508ac2a
    .dword 0x30b0081b3f4d1385
    .dword 0xe962bb37166b725b
    .dword 0x0b9919c29d0e6949
    .dword 0x105664ed5af76e50
    .dword 0x74e25a6b1bc4f80e
    .dword 0x9d733cb2c854c492
    .dword 0xfb57d5d97356c110
    .dword 0x73d7eb58c51fa2e4
    .dword 0x5eb515069ebf5213
    .dword 0x8f6e4a56a46a2fc4
    .dword 0x52c366a3afbcf64b
    .dword 0xaebc5427d6b16a25
    .dword 0x3943a37a617e8389
    .dword 0x268be9b46fc16e2a
    .dword 0x1d803d68423fdf8f
    .dword 0x9b79c80f9d852a83
    .dword 0x5a90a6c4329cc294
    .dword 0xa4eb8d378a9f7ced
    .dword 0xd132ba12711790d7
    .dword 0x07a456ba46ab6d80
    .dword 0xc232e79f2f4fc07c
    .dword 0xe0384bab91a8ac80
    .dword 0xeeb2e83e50708cef
    .dword 0x47704485e00a3dd7
    .dword 0xc48e89636ef87013
    .dword 0x97bfdd5bb3d00e43

    .align 2
_torture_data:
    .word 0xabb59ba2
    .word 0x518c6208
    .word 0x5714227b
    .word 0x853ccd2c
    .word 0x2a483f51
    .word 0x1b88a254
    .word 0xb3ef6964
    .word 0xc7b75f94
    .word 0x16638085
    .word 0x99fea1dc
    .word 0x394554a5
    .word 0x69a7e4af
    .word 0x1b434d70
    .word 0xa702f9aa
    .word 0x613ca3af
    .word 0x6bd3af4e
    .word 0xc1cbeaed
    .word 0xd17c328c
    .word 0xd6547580
    .word 0x4dc2ed54
    .word 0xd48bf32e
    .word 0xf92c0cde
    .word 0x13241e72
    .word 0x126007be
    .word 0x09087540
    .word 0x302d5077
    .word 0x5b3b1620
    .word 0xab546f90
    .word 0xc8a5788a
    .word 0x34bae51c
    .word 0xdb308a76
    .word 0xfe615e61
    .word 0x25be1741
    .word 0x360dc28c
    .word 0x3f0b7353
    .word 0xa51a1d93
    .word 0x5d358672
    .word 0xa75a86ea
    .word 0x1d9f45c7
    .word 0xcd0a75b5
    .word 0x3d279110
    .word 0xecb46838
    .word 0xce61ffa0
    .word 0x5d1eba95
    .word 0x9d7db52f
    .word 0x716ba94e
    .word 0xc1764ac3
    .word 0x7d05208e
    .word 0x7509ac71
    .word 0x0922b55a
    .word 0xd83085b4
    .word 0x4e562323
    .word 0xa70adc84
    .word 0x11ed3724
    .word 0xce5d629c
    .word 0x09f250ab
    .word 0xb515ab4b
    .word 0x608f120d
    .word 0x82d42f83
    .word 0xadc60d52
    .word 0x02ded65e
    .word 0xd2dec62a
    .word 0xf906494a
    .word 0xf4413992
    .word 0xc480ed92
    .word 0xf5ddc8de
    .word 0x99b13605
    .word 0x91f44411
    .word 0xedd5a51f
    .word 0x4c648dfc
    .word 0x90413bf5
    .word 0x9159ffb1
    .word 0xa6f4086f
    .word 0x0886f283
    .word 0xf9b170a8
    .word 0x3b8ac397
    .word 0x457858be
    .word 0x93c59a95
    .word 0x73f10645
    .word 0x8d084c75
    .word 0xf1259887
    .word 0x8d747ad3
    .word 0x79f897a6
    .word 0x4e8a2852
    .word 0x6991cba2
    .word 0xe542e2ed
    .word 0x86c8a0da
    .word 0x243ab2e9
    .word 0x2777b05c
    .word 0x7cb15222
    .word 0xedeb05d3
    .word 0xeeb2926a
    .word 0xaa465d4d
    .word 0xc7528906
    .word 0xc87b7c5c
    .word 0x76dd6c05
    .word 0x1f828b6b
    .word 0x7ca28bf4
    .word 0x17ec569d
    .word 0x93cecfc8
    .word 0xc50ad328
    .word 0x093a39d5
    .word 0xfcf829d4
    .word 0x8f48fdbd
    .word 0xf06deeb7
    .word 0xda898a8a
    .word 0xa59052e0
    .word 0x79ad987c
    .word 0x3e5d0ddc
    .word 0x9b574947
    .word 0x6b0354e1
    .word 0xb5c6a409
    .word 0x7232e22f
    .word 0x96ac35f1
    .word 0x7504240b
    .word 0xc4b31d2b
    .word 0x67adda56
    .word 0x10f14c40
    .word 0x8851cd2a
    .word 0xfeed7b5e
    .word 0x72483668
    .word 0x019a78e7
    .word 0xa802b248
    .word 0xb1ce21e2
    .word 0xde8828e5
    .word 0x46bcfd03
    .word 0x0736e474
    .word 0x55ee99ed
    .word 0x29000488
    .word 0xc36a289b
    .word 0xc4762642
    .word 0x6259726c
    .word 0x87964229
    .word 0x9821afdc
    .word 0xda7c9116
    .word 0x61039a45
    .word 0x4c8fb792
    .word 0xdd212514
    .word 0x40e760c0
    .word 0x0a7c1258
    .word 0xfd12206c
    .word 0xb1444467
    .word 0x0710f0f8
    .word 0x9b4c79f8
    .word 0x35188e54
    .word 0x80835df0
    .word 0xc24270ee
    .word 0xa1a2dfc3
    .word 0xddb05d97
    .word 0x0da2f05e
    .word 0xa40239d4
    .word 0x9fb5a424
    .word 0xd4638dd2
    .word 0xab94980e
    .word 0xfef2c536
    .word 0x2e77688f
    .word 0xd527214c
    .word 0x33d00918
    .word 0xbb07990a
    .word 0x6736db23
    .word 0xf9ade1de
    .word 0xa1b90c09
    .word 0xb64def72
    .word 0x10f66051
    .word 0xf87fc5df
    .word 0x5616b056
    .word 0x198f500f
    .word 0x20e0ba35
    .word 0x62e8c0db
    .word 0x2cc7e7ec
    .word 0x30305b82
    .word 0xecc12b6d
    .word 0x452f84f1
    .word 0x52e1eeab
    .word 0x9de9e617
    .word 0x50f8ee9c
    .word 0x6fdf9f50
    .word 0x695907ea
    .word 0xc377212b
    .word 0x04c7c322
    .word 0x0fe62c4e
    .word 0x7603cf05
    .word 0x2015e301
    .word 0x791981e0
    .word 0xb75ce0b8
    .word 0x8f1dc02c
    .word 0xb3db7ddc
    .word 0x10ec8ba8
    .word 0x115830f7
    .word 0x21f856b2
    .word 0xb83767be
    .word 0xa86fb3d0
    .word 0x22a2f386
    .word 0xa71b1e86
    .word 0xa91c6753
    .word 0xcf129d87
    .word 0xe8949127
    .word 0xbff52d3a
    .word 0x1b44adee
    .word 0xcdd4cbae
    .word 0xd72033f9
    .word 0x77b00155
    .word 0xc3ef1d3d
    .word 0x22be7a80
    .word 0xd7432bcd
    .word 0xd0511a25
    .word 0xa81c7ae7
    .word 0x711145d7
    .word 0x2000d09e
    .word 0x6b1161c4
    .word 0xed4c5e80
    .word 0x524bf83a
    .word 0x34ba986c
    .word 0x4712d4ca
    .word 0xfa0a262c
    .word 0x40435ebf
    .word 0x3d1a1b68
    .word 0x1432775b
    .word 0x8c413582
    .word 0x6f32eeb4
    .word 0x0a35baf0
    .word 0xbb77c5b2
    .word 0x32dddfb6
    .word 0x50baa898
    .word 0x316a4c64
    .word 0xd72dfc89
    .word 0x2ad3566e
    .word 0x0a50b6b3
    .word 0x07cc298a
    .word 0xc10996aa
    .word 0xe2df09dd
    .word 0x09ef2b3e
    .word 0x85c40b8b
    .word 0x6c52942c
    .word 0x44d0bbbf
    .word 0x1858b925
    .word 0x01308428
    .word 0xe889d76a
    .word 0x2f4eab93
    .word 0x99cb656f
    .word 0x3abfab10
    .word 0x85cc4ed1
    .word 0xa9777c84
    .word 0xec1a9b22
    .word 0x9f640d97
    .word 0x0338c00e
    .word 0x1514280a
    .word 0xb36a1fab
    .word 0x2ade8988
    .word 0xa2677747
    .word 0x9599b41d
    .word 0xdcc05066
    .word 0x6343f1a3
    .word 0x5c434cce
    .word 0x17cfa3fa
    .word 0xee10f650

#include "frost_footer.S"
