// Generated RV32IMAFDC torture test for Frost (seed=54)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x2331c265
    li x4, 0x8e5a9cc0
    li x5, 0xf57fbd8c
    li x6, 0x6161390b
    li x7, 0x724dd9d9
    li x8, 0xe0e91a95
    li x9, 0xb946f5d8
    li x10, 0x0e567a4d
    li x11, 0x8c84a316
    li x12, 0x99021e19
    li x13, 0x8ac826f6
    li x14, 0x84087681
    li x15, 0xee430e5b
    li x16, 0x247546c9
    li x17, 0xe5ca950f
    li x18, 0x033c1b9c
    li x19, 0x440bc4e8
    li x20, 0x05442af1
    li x21, 0x22ed4412
    li x22, 0xfb0b3226
    li x23, 0xb3509ac9
    li x24, 0x72660430
    li x25, 0x9441c34b
    li x26, 0xfb9e806d
    li x27, 0x3d357d66
    li x28, 0x64b041f7
    li x29, 0x6d55104e
    li x30, 0xd65829a6
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
    li x1, 0xd7c20c34

    sra x5, x4, x23
    srai x19, x17, 10
    divu x19, x12, x13
    div x27, x28, x28
    mulh x22, x13, x15
    and x13, x18, x16
    slli x7, x20, 21
    srli x16, x13, 17
    srli x27, x19, 18
    beq x17, x28, _br_taken_0
    srl x6, x21, x6
    j _br_done_0
_br_taken_0:
    sll x6, x8, x25
_br_done_0:
    srl x23, x26, x13
    srl x8, x28, x16
    addi x1, x1, -537
    and x17, x13, x29
    add x19, x15, x18
    fmin.d f3, f24, f15
    srl x15, x1, x16
    slt x16, x1, x5
    add x6, x8, x28
    andi x29, x20, -1747
    sub x27, x21, x24
    bge x1, x22, _br_taken_1
    and x11, x18, x4
    j _br_done_1
_br_taken_1:
    or x11, x27, x27
_br_done_1:
    bltu x8, x13, _br_taken_2
    and x17, x8, x29
    j _br_done_2
_br_taken_2:
    sltu x17, x25, x20
_br_done_2:
    slli x15, x4, 30
    srai x14, x19, 24
    xori x25, x12, 854
    ori x13, x15, 406
    sra x14, x19, x8
    sll x6, x15, x6
    sltu x26, x5, x18
    addi x5, x31, 320
    amoswap.w x20, x21, (x5)
    divu x19, x4, x4
    bltu x8, x16, _br_taken_3
    and x20, x23, x5
    j _br_done_3
_br_taken_3:
    sra x20, x21, x28
_br_done_3:
    xor x5, x28, x24
    addi x23, x31, 960
    amoadd.w x9, x9, (x23)
    srli x16, x18, 2
    srl x17, x26, x9
    fmul.s f21, f27, f5
    fnmadd.d f25, f8, f15, f10
    fdiv.s f19, f18, f18
    sub x26, x1, x30
    or x6, x8, x22
    and x27, x28, x11
    xori x6, x23, -1935
    add x10, x5, x10
    lw x18, 976(x31)
    sw x10, 976(x31)
    ori x4, x4, -18
    slti x5, x24, -1168
    sll x23, x21, x4
    addi x22, x31, 532
    amoadd.w x1, x12, (x22)
    bne x21, x9, _br_taken_4
    sltu x4, x29, x27
    j _br_done_4
_br_taken_4:
    and x4, x16, x29
_br_done_4:
    slli x13, x26, 15
    srli x30, x27, 12
    srl x23, x21, x9
    xor x12, x26, x12
    bgeu x4, x29, _br_taken_5
    add x17, x29, x15
    j _br_done_5
_br_taken_5:
    sll x17, x19, x30
_br_done_5:
    lw x7, 340(x31)
    sw x16, 340(x31)
    bgeu x23, x29, _br_taken_6
    slt x1, x23, x14
    j _br_done_6
_br_taken_6:
    add x1, x29, x30
_br_done_6:
    addi x12, x31, 572
    amomaxu.w x29, x22, (x12)
    lb x14, 88(x31)
    sb x18, 88(x31)
    fmul.s f22, f25, f4
    fmsub.d f25, f28, f23, f20
    fnmadd.s f3, f10, f22, f30
    sltiu x28, x29, 1337
    sltiu x8, x16, -736
    blt x5, x8, _br_taken_7
    sltu x26, x30, x18
    j _br_done_7
_br_taken_7:
    slt x26, x9, x15
_br_done_7:
    bgeu x24, x13, _br_taken_8
    sra x15, x26, x20
    j _br_done_8
_br_taken_8:
    sltu x15, x18, x26
_br_done_8:
    sltiu x29, x11, -1805
    slti x27, x5, -1822
    andi x9, x30, 188
    andi x25, x14, 341
    ori x28, x25, -698
    remu x13, x9, x17
    mulhu x10, x12, x16
    sub x9, x26, x22
    xor x18, x11, x26
    or x21, x1, x23
    sltu x8, x20, x16
    bne x12, x5, _br_taken_9
    slt x28, x8, x25
    j _br_done_9
_br_taken_9:
    add x28, x21, x13
_br_done_9:
    addi x28, x5, 1178
    sra x27, x18, x7
    sra x7, x16, x23
    andi x19, x25, -1936
    sub x4, x14, x12
    fsub.d f28, f19, f30
    fnmsub.s f28, f25, f10, f26
    fsub.d f26, f15, f28
    remu x13, x29, x22
    divu x15, x11, x15
    lw x15, 36(x31)
    sw x4, 36(x31)
    fmul.d f5, f15, f9
    sll x11, x13, x26
    xori x6, x26, 989
    sltiu x13, x8, -1672
    sub x8, x11, x27
    addi x15, x29, 1651
    srl x17, x25, x26
    slli x27, x12, 30
    fmin.d f30, f0, f30
    srai x12, x22, 12
    add x28, x12, x26
    ori x12, x8, 1112
    sra x9, x24, x24
    sra x27, x1, x23
    addi x5, x31, 272
    amoor.w x14, x12, (x5)
    sub x18, x21, x27
    slli x27, x29, 6
    slt x17, x4, x20
    sltu x11, x10, x28
    fsub.d f9, f19, f8
    fadd.d f7, f18, f20
    bltu x14, x28, _br_taken_10
    xor x13, x19, x10
    j _br_done_10
_br_taken_10:
    sll x13, x22, x27
_br_done_10:
    lw x27, 904(x31)
    sw x22, 904(x31)
    ori x19, x28, -1238
    slli x12, x25, 26
    or x17, x14, x29
    bltu x15, x1, _br_taken_11
    and x17, x25, x30
    j _br_done_11
_br_taken_11:
    sra x17, x12, x4
_br_done_11:
    fsub.d f29, f26, f27
    fmadd.s f6, f11, f11, f25
    bge x5, x7, _br_taken_12
    sll x25, x6, x6
    j _br_done_12
_br_taken_12:
    add x25, x5, x8
_br_done_12:
    bge x18, x13, _br_taken_13
    xor x23, x10, x14
    j _br_done_13
_br_taken_13:
    sltu x23, x17, x18
_br_done_13:
    bne x21, x1, _br_taken_14
    and x19, x23, x5
    j _br_done_14
_br_taken_14:
    slt x19, x30, x21
_br_done_14:
    ori x14, x7, -1396
    slli x14, x1, 3
    bgeu x8, x5, _br_taken_15
    xor x14, x8, x16
    j _br_done_15
_br_taken_15:
    srl x14, x9, x21
_br_done_15:
    or x8, x4, x11
    add x1, x15, x15
    add x4, x27, x8
    xor x26, x23, x11
    add x4, x24, x5
    srai x1, x1, 11
    srai x28, x4, 4
    add x11, x28, x19
    slli x6, x9, 3
    addi x28, x27, 350
    srli x9, x7, 7
    slti x15, x30, -2029
    mulhu x21, x1, x28
    fsub.s f4, f12, f12
    fdiv.d f21, f7, f21
    fmul.s f6, f0, f2
    fsub.s f18, f15, f20
    fmul.d f11, f4, f11
    or x5, x17, x8
    xori x25, x27, -727
    and x27, x25, x7
    lhu x14, 928(x31)
    sh x1, 928(x31)
    lb x23, 388(x31)
    sb x4, 388(x31)
    sltiu x10, x14, -1673
    or x8, x24, x14
    sltu x29, x4, x12
    or x16, x15, x29
    xori x7, x7, -322
    sltiu x10, x6, -1930
    fmul.d f26, f12, f10
    fmin.d f6, f29, f27
    lb x4, 976(x31)
    sb x18, 976(x31)
    fmax.s f2, f15, f17
    bne x12, x25, _br_taken_16
    add x4, x10, x16
    j _br_done_16
_br_taken_16:
    and x4, x30, x7
_br_done_16:
    lw x10, 688(x31)
    sw x12, 688(x31)
    bne x4, x12, _br_taken_17
    add x14, x20, x9
    j _br_done_17
_br_taken_17:
    xor x14, x26, x30
_br_done_17:
    lb x12, 772(x31)
    sb x5, 772(x31)
    andi x24, x10, -1704
    sra x11, x10, x14
    slti x24, x15, -1480
    bge x4, x12, _br_taken_18
    slt x17, x9, x12
    j _br_done_18
_br_taken_18:
    sll x17, x27, x29
_br_done_18:
    sltu x28, x9, x11
    sltiu x5, x20, 976
    lbu x8, 708(x31)
    sb x23, 708(x31)
    slti x15, x18, -1811
    sub x14, x4, x23
    sltu x28, x1, x9
    sltiu x19, x26, 1580
    slt x18, x12, x1
    addi x14, x31, 756
    amoxor.w x22, x22, (x14)
    beq x19, x22, _br_taken_19
    sltu x21, x10, x24
    j _br_done_19
_br_taken_19:
    slt x21, x24, x17
_br_done_19:
    xori x25, x4, -1850
    slt x15, x15, x30
    remu x16, x7, x7
    rem x13, x19, x29
    bne x22, x24, _br_taken_20
    sltu x8, x14, x30
    j _br_done_20
_br_taken_20:
    and x8, x4, x21
_br_done_20:
    sltiu x8, x20, 1021
    and x27, x21, x24
    sll x24, x13, x11
    blt x19, x20, _br_taken_21
    add x9, x16, x9
    j _br_done_21
_br_taken_21:
    slt x9, x6, x14
_br_done_21:
    slt x12, x21, x13
    xori x17, x18, -907
    srai x12, x16, 11
    slti x24, x12, 1424
    fmin.d f20, f16, f5
    srli x13, x10, 2
    slti x28, x12, -1275
    and x19, x6, x19
    srl x13, x27, x18
    srli x22, x11, 12
    sltiu x20, x27, 1425
    bltu x6, x1, _br_taken_22
    slt x29, x5, x17
    j _br_done_22
_br_taken_22:
    sll x29, x7, x30
_br_done_22:
    blt x12, x30, _br_taken_23
    sub x20, x4, x15
    j _br_done_23
_br_taken_23:
    add x20, x20, x11
_br_done_23:
    rem x4, x17, x20
    srai x12, x28, 31
    sltiu x27, x15, -88
    slli x28, x27, 4
    srai x6, x18, 7
    addi x16, x1, -788
    remu x4, x11, x30
    fmul.s f8, f15, f29
    fadd.s f14, f26, f30
    bne x16, x26, _br_taken_24
    and x24, x30, x25
    j _br_done_24
_br_taken_24:
    sll x24, x30, x17
_br_done_24:
    sub x18, x6, x30
    addi x1, x31, 672
    amoadd.w x14, x25, (x1)
    srai x13, x4, 23
    lw x26, 224(x31)
    sw x30, 224(x31)
    beq x15, x23, _br_taken_25
    slt x11, x18, x16
    j _br_done_25
_br_taken_25:
    or x11, x8, x8
_br_done_25:
    srl x27, x27, x6
    srl x26, x7, x16
    bgeu x7, x22, _br_taken_26
    sll x29, x6, x20
    j _br_done_26
_br_taken_26:
    sra x29, x9, x9
_br_done_26:
    sltu x4, x6, x16
    and x24, x5, x1
    mulhu x27, x30, x18
    div x28, x27, x14
    bne x9, x8, _br_taken_27
    and x9, x27, x13
    j _br_done_27
_br_taken_27:
    and x9, x8, x28
_br_done_27:
    bgeu x13, x27, _br_taken_28
    and x13, x4, x27
    j _br_done_28
_br_taken_28:
    srl x13, x22, x9
_br_done_28:
    bge x9, x5, _br_taken_29
    sll x25, x1, x25
    j _br_done_29
_br_taken_29:
    or x25, x21, x25
_br_done_29:
    lb x14, 436(x31)
    sb x20, 436(x31)
    bltu x20, x17, _br_taken_30
    xor x10, x11, x13
    j _br_done_30
_br_taken_30:
    add x10, x23, x7
_br_done_30:
    or x21, x27, x11
    andi x23, x19, 748
    fnmadd.d f30, f11, f10, f18
    fmsub.d f26, f8, f24, f2
    fnmsub.s f12, f22, f25, f23
    bltu x28, x21, _br_taken_31
    sltu x11, x30, x22
    j _br_done_31
_br_taken_31:
    slt x11, x15, x4
_br_done_31:
    blt x17, x24, _br_taken_32
    sra x24, x10, x12
    j _br_done_32
_br_taken_32:
    sll x24, x29, x9
_br_done_32:
    lb x20, 468(x31)
    sb x19, 468(x31)
    srli x22, x13, 21
    xori x29, x29, 202
    slt x8, x30, x21
    srli x15, x30, 23
    sub x6, x13, x9
    or x14, x12, x25
    addi x10, x31, 988
    amoxor.w x8, x9, (x10)
    and x1, x29, x22
    xor x6, x30, x7
    srai x12, x19, 6
    or x23, x23, x7
    or x17, x23, x12
    blt x21, x16, _br_taken_33
    or x16, x22, x8
    j _br_done_33
_br_taken_33:
    xor x16, x16, x13
_br_done_33:
    srai x10, x27, 5
    add x6, x8, x8
    xori x8, x26, 784
    bne x24, x16, _br_taken_34
    and x30, x18, x30
    j _br_done_34
_br_taken_34:
    or x30, x19, x14
_br_done_34:
    xor x5, x5, x14
    sltu x1, x30, x18
    or x1, x28, x25
    sltiu x30, x17, 887
    xori x29, x14, 2008
    sltiu x20, x13, -1579
    slli x4, x9, 29
    xori x14, x25, -331
    ori x28, x27, 1133
    sub x28, x11, x28
    addi x23, x28, -1396
    slti x20, x20, -1994
    srli x26, x17, 30
    bge x18, x25, _br_taken_35
    sll x23, x14, x13
    j _br_done_35
_br_taken_35:
    sra x23, x21, x17
_br_done_35:
    srai x8, x7, 13
    ori x21, x1, -795
    sltiu x9, x22, -1422
    fmin.s f12, f25, f9
    fmul.s f6, f23, f7
    fmsub.d f13, f9, f9, f7
    fmadd.d f17, f22, f24, f4
    sltu x21, x21, x15
    sltiu x19, x17, 38
    xori x12, x27, 866
    xor x25, x15, x12
    slti x16, x20, 31
    xori x11, x24, -366
    mul x29, x17, x23
    div x27, x6, x27
    bne x17, x8, _br_taken_36
    slt x27, x15, x28
    j _br_done_36
_br_taken_36:
    srl x27, x22, x17
_br_done_36:
    fmul.s f15, f17, f5
    fdiv.s f13, f3, f6
    slti x7, x26, 1810
    srai x30, x10, 25
    blt x13, x8, _br_taken_37
    srl x26, x11, x11
    j _br_done_37
_br_taken_37:
    sub x26, x25, x18
_br_done_37:
    sltiu x14, x12, 551
    sltiu x27, x20, -468
    and x1, x11, x28
    ori x21, x18, 114
    or x12, x4, x9
    slli x5, x11, 3
    slt x1, x29, x21
    sll x11, x1, x25
    srai x17, x17, 28
    sub x5, x8, x11
    or x10, x22, x19
    xor x18, x22, x29
    slti x20, x13, -1988
    lw x30, 248(x31)
    sw x1, 248(x31)
    lw x21, 472(x31)
    sw x20, 472(x31)
    xori x15, x12, -1390
    srli x10, x13, 21
    srl x22, x22, x20
    lhu x22, 36(x31)
    sh x26, 36(x31)
    lhu x1, 708(x31)
    sh x9, 708(x31)
    srai x11, x8, 8
    slti x24, x13, -961
    srli x23, x6, 0
    srai x16, x7, 1
    and x24, x20, x16
    addi x26, x25, -115
    blt x26, x6, _br_taken_38
    add x26, x10, x27
    j _br_done_38
_br_taken_38:
    sub x26, x9, x5
_br_done_38:
    andi x27, x22, 1556
    addi x15, x7, 758
    srl x28, x20, x27
    sra x11, x24, x9
    srl x22, x26, x26
    blt x22, x18, _br_taken_39
    sltu x12, x12, x11
    j _br_done_39
_br_taken_39:
    or x12, x17, x8
_br_done_39:
    bltu x17, x26, _br_taken_40
    sub x8, x8, x22
    j _br_done_40
_br_taken_40:
    slt x8, x5, x10
_br_done_40:
    beq x1, x22, _br_taken_41
    slt x20, x24, x18
    j _br_done_41
_br_taken_41:
    and x20, x11, x11
_br_done_41:
    slli x6, x4, 30
    sll x16, x25, x18
    xori x21, x16, 1405
    sub x6, x14, x22
    addi x22, x24, -945
    lw x7, 700(x31)
    sw x13, 700(x31)
    xor x15, x11, x12
    slti x17, x19, 1727
    srli x9, x17, 11
    lb x26, 612(x31)
    sb x25, 612(x31)
    addi x7, x31, 448
    amominu.w x30, x29, (x7)
    addi x22, x23, -682

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x04de79518bd2191e
    .dword 0x1dac6cc9f50b63e4
    .dword 0x57da85eeb9462a5a
    .dword 0x82b8698b7eef4992
    .dword 0x84f8b06c4ce71539
    .dword 0xc33fb457e33e989f
    .dword 0x56e2aecdb36e6c1f
    .dword 0x1aec5638245794cf
    .dword 0x9ee9f2f9c3779504
    .dword 0x1b82afca086b5ed9
    .dword 0x54c5109b2ab06219
    .dword 0xd6965e5212b07f88
    .dword 0xb5dcf372687b39f0
    .dword 0xa078a3ba92b4d8be
    .dword 0x33084049e9de5ef8
    .dword 0x1ea167b06cb6d573
    .dword 0xa20c3c576a8e58d6
    .dword 0xc68d5df8f3125fa2
    .dword 0xd8b90827f255f600
    .dword 0x96c31454f017b790
    .dword 0x16fb8c54aa1c2dca
    .dword 0xb1841194c5b0ce11
    .dword 0x12bd0ac32ec150ce
    .dword 0xf6bd4865920edd74
    .dword 0xeb0d1490c7bb667c
    .dword 0xdc10b36e2fcb2367
    .dword 0x1c0a551bcae60e78
    .dword 0xc6bf2f7f1a519103
    .dword 0xa4bcf17ea785348f
    .dword 0x9cec3d18a9d102c8
    .dword 0x340cac63e9a49d3b
    .dword 0x5b876732bc28ba3f

    .align 2
_torture_data:
    .word 0xe74eb142
    .word 0xc67e3a31
    .word 0x2c77df23
    .word 0xa8ac5348
    .word 0x3d74e427
    .word 0xfbe6afb5
    .word 0xfa616da8
    .word 0x6d9b2d50
    .word 0xb9a74e1f
    .word 0xc3888879
    .word 0xeff3422c
    .word 0xf78a30d4
    .word 0x86c3b38e
    .word 0x5f114c3b
    .word 0x4fdcb72e
    .word 0x806d5077
    .word 0x0f542b31
    .word 0xab4c9551
    .word 0x1a6bdd48
    .word 0xba57a28c
    .word 0x157e6cf3
    .word 0xb4507ad9
    .word 0x26bb2ccb
    .word 0x4a471391
    .word 0xd81c65d5
    .word 0x568b916c
    .word 0x1872a1df
    .word 0x3a72e8b3
    .word 0x6a590288
    .word 0xf5a8561e
    .word 0x8c4625a6
    .word 0x02c1aecb
    .word 0x89148cbf
    .word 0x260a7a2c
    .word 0x5c47f704
    .word 0x40210906
    .word 0xc9a54f17
    .word 0xa6b9abb6
    .word 0x34f2274c
    .word 0xabd67248
    .word 0xad29ebb9
    .word 0xe3166d8b
    .word 0x3f485878
    .word 0x9a69e4e9
    .word 0x3bca96e8
    .word 0xb9530653
    .word 0xbc3adefa
    .word 0x01e50dc8
    .word 0xacebb876
    .word 0xf176ba6d
    .word 0x556a88ba
    .word 0x8d613070
    .word 0xe2109f64
    .word 0xef213e9f
    .word 0xa0d33231
    .word 0x6df08925
    .word 0xd0280f27
    .word 0xb20fa487
    .word 0x46785d58
    .word 0x28f593a3
    .word 0x885c4f9d
    .word 0x4339cdc4
    .word 0xf35084b7
    .word 0x22baa912
    .word 0xfba6c1f2
    .word 0xca829c86
    .word 0x23854367
    .word 0xb1d78cbe
    .word 0x41f3cc8a
    .word 0x8900dfbe
    .word 0xe67061d3
    .word 0xd5183bc7
    .word 0xff41c56d
    .word 0xbe020e6c
    .word 0x1ade182a
    .word 0x487815d6
    .word 0xfc37c675
    .word 0xb56c1c7d
    .word 0xc0c86359
    .word 0x6136f45d
    .word 0x983fb05b
    .word 0xfce81366
    .word 0xdbceb4e3
    .word 0x85b6476c
    .word 0x7f43641d
    .word 0x077cc70f
    .word 0xa986fcfb
    .word 0xf5d9ca12
    .word 0xd2711fb8
    .word 0xf747c319
    .word 0x681549a8
    .word 0x2e1e6f09
    .word 0xe2b469a8
    .word 0xa0046436
    .word 0x829d1a89
    .word 0x99a277a4
    .word 0xa9324d21
    .word 0xde892355
    .word 0x6ca1c477
    .word 0xb1a9f367
    .word 0x8384eeef
    .word 0x2997b27d
    .word 0x987ce736
    .word 0xb7ec85e1
    .word 0x23976ae5
    .word 0x59ee9223
    .word 0x8ca58dd5
    .word 0xb2ddb101
    .word 0x34780502
    .word 0x02d875bd
    .word 0x9abcc779
    .word 0xefce6905
    .word 0xe10750fd
    .word 0x3e849287
    .word 0x9db29b97
    .word 0x9bfec6ff
    .word 0x3f25e24d
    .word 0x96291dd0
    .word 0xede8dc71
    .word 0x51d2f029
    .word 0x1cfc332a
    .word 0x9bc681fa
    .word 0x8ee084f9
    .word 0x5696af39
    .word 0xdd96f43d
    .word 0xb2408dd2
    .word 0xaf8903e8
    .word 0x71da2fbd
    .word 0x3199ef53
    .word 0x6ffa5f16
    .word 0xe8c6c32c
    .word 0xcb2da7c3
    .word 0x1511b8c7
    .word 0x5de08b3e
    .word 0x440ab5a0
    .word 0xb84d9d87
    .word 0x04b5dc40
    .word 0x36189ff3
    .word 0xa9f8fab4
    .word 0x39af7c59
    .word 0xdca65184
    .word 0x84f53f61
    .word 0x6ff66d02
    .word 0x9c22759a
    .word 0x9901265e
    .word 0x110c85fb
    .word 0x6fe209a4
    .word 0x1290b7c5
    .word 0x930c5882
    .word 0xc685818c
    .word 0x91bebfef
    .word 0xc5731c81
    .word 0x1c18a08c
    .word 0xbc13a666
    .word 0xd1d66e99
    .word 0x1268004a
    .word 0xb803e4c3
    .word 0xd766f66f
    .word 0xefb680ca
    .word 0xfec9eea7
    .word 0x1e5001d0
    .word 0x551f7227
    .word 0x97c2e38c
    .word 0xfcd6d7e2
    .word 0x7f9263ea
    .word 0x65c7a002
    .word 0xee937264
    .word 0x37f4c407
    .word 0xeebdadc7
    .word 0x1e34d802
    .word 0x4bf697e7
    .word 0x51b3ade9
    .word 0xac23104c
    .word 0x4a43d14a
    .word 0xa5948340
    .word 0x28ba4e40
    .word 0x4548d858
    .word 0xd8855cff
    .word 0xa8c1b0c3
    .word 0x2674d920
    .word 0x702438fe
    .word 0x7fa63d9d
    .word 0x3c74f3be
    .word 0x7e232162
    .word 0x3772705d
    .word 0x7942a036
    .word 0xa28bc278
    .word 0xc36ae5a6
    .word 0x86f2176d
    .word 0x5b3eedb2
    .word 0x94bda6db
    .word 0x8dc605c6
    .word 0x2c705141
    .word 0x28cd17b0
    .word 0xfe754486
    .word 0x54c9a643
    .word 0x67f2b485
    .word 0x21cdd34b
    .word 0x1e2ec824
    .word 0x9af70384
    .word 0x0cabfaab
    .word 0x8f15e1e5
    .word 0xd749ce73
    .word 0x05a75ab9
    .word 0xe27d9b20
    .word 0xab2aba67
    .word 0xd01ebbf4
    .word 0x5529e4c2
    .word 0xf563f2d7
    .word 0x5bc87924
    .word 0x6f980905
    .word 0xd432f0a8
    .word 0x2fd237a0
    .word 0x16b9aeb6
    .word 0x43d649e6
    .word 0xb47ccdf3
    .word 0x9f7731a9
    .word 0x8b4f55d7
    .word 0xd2c3e6a4
    .word 0x0093323f
    .word 0xc98cb909
    .word 0xecba7384
    .word 0x1ced828d
    .word 0xe647245d
    .word 0xc8d337b8
    .word 0xe2d11598
    .word 0x9b2614e3
    .word 0x0282c137
    .word 0x45193c46
    .word 0x046eadde
    .word 0x1494f56f
    .word 0x80609a96
    .word 0x5b03b03a
    .word 0xc717d14f
    .word 0x8f0b3189
    .word 0xebc4473f
    .word 0xcc12bd08
    .word 0x7f38f010
    .word 0x95dced2b
    .word 0x683adbfe
    .word 0xbdb0a099
    .word 0x706e2293
    .word 0x696520fa
    .word 0x61f2ce7d
    .word 0x06f9722d
    .word 0x1866e10b
    .word 0xb581f99c
    .word 0x30617b73
    .word 0x8a94cce9
    .word 0xe8cb851a
    .word 0xd4af4c28
    .word 0xdbe05c17
    .word 0x5a376ef2
    .word 0xb6e118af
    .word 0xc70377aa
    .word 0x94fa0055

#include "frost_footer.S"
