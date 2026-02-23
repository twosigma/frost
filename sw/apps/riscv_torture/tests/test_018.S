// Generated RV32IMAFDC torture test for Frost (seed=59)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x39643825
    li x4, 0xf21c40c5
    li x5, 0x05d38191
    li x6, 0xd8cf8c93
    li x7, 0xb6e1294a
    li x8, 0xd40c3f24
    li x9, 0x60d5c865
    li x10, 0x893ac0cf
    li x11, 0xc2e3f1a8
    li x12, 0xab73a121
    li x13, 0xe851a9fe
    li x14, 0x19e49e2d
    li x15, 0xa401dd6d
    li x16, 0xd8a797e5
    li x17, 0x4e1fe812
    li x18, 0x0b8704d6
    li x19, 0xbf90b65e
    li x20, 0xf736dc15
    li x21, 0x40cdf903
    li x22, 0x67960ec0
    li x23, 0xc743bc4a
    li x24, 0x73d0b872
    li x25, 0x39ebf403
    li x26, 0xb0dbbe74
    li x27, 0x99fd14b1
    li x28, 0x9ae79daf
    li x29, 0x8356b5cc
    li x30, 0x4104ac78
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
    li x1, 0x254b4445

    lw x23, 496(x31)
    sw x18, 496(x31)
    lbu x10, 892(x31)
    sb x23, 892(x31)
    lw x14, 96(x31)
    sw x29, 96(x31)
    or x24, x6, x1
    slli x10, x21, 26
    or x18, x7, x12
    bltu x13, x14, _br_taken_0
    sub x23, x28, x12
    j _br_done_0
_br_taken_0:
    sub x23, x12, x18
_br_done_0:
    beq x18, x8, _br_taken_1
    srl x10, x17, x22
    j _br_done_1
_br_taken_1:
    sub x10, x29, x6
_br_done_1:
    fadd.s f14, f7, f22
    fadd.d f21, f16, f26
    srai x1, x10, 0
    sll x10, x7, x30
    sltiu x22, x20, 465
    xor x23, x26, x26
    xor x26, x1, x17
    or x8, x25, x8
    slti x12, x8, -713
    sltiu x23, x10, -1942
    andi x30, x1, 1942
    srai x15, x24, 10
    sltu x1, x20, x15
    sll x1, x11, x11
    sra x27, x10, x5
    slti x6, x12, -1071
    bgeu x9, x27, _br_taken_2
    and x23, x10, x20
    j _br_done_2
_br_taken_2:
    or x23, x24, x30
_br_done_2:
    remu x30, x4, x13
    slli x18, x20, 28
    mulhu x19, x20, x19
    lh x17, 232(x31)
    sh x15, 232(x31)
    divu x19, x4, x27
    remu x19, x19, x16
    blt x23, x18, _br_taken_3
    sltu x9, x11, x26
    j _br_done_3
_br_taken_3:
    sub x9, x1, x4
_br_done_3:
    sltiu x23, x22, -2033
    sltu x24, x7, x20
    and x8, x14, x8
    bge x23, x17, _br_taken_4
    xor x1, x19, x14
    j _br_done_4
_br_taken_4:
    sll x1, x7, x12
_br_done_4:
    sltu x19, x24, x5
    slli x21, x26, 25
    addi x8, x19, 3
    srli x12, x9, 14
    and x10, x20, x11
    srai x15, x12, 9
    slti x20, x22, -1115
    slli x24, x13, 18
    sltiu x6, x13, -389
    slti x21, x23, -491
    add x28, x6, x10
    sra x16, x18, x28
    sltu x20, x18, x20
    xor x24, x13, x13
    bltu x24, x5, _br_taken_5
    sll x7, x14, x11
    j _br_done_5
_br_taken_5:
    or x7, x17, x15
_br_done_5:
    slli x1, x15, 23
    and x10, x12, x18
    or x15, x11, x4
    add x22, x30, x1
    sltu x7, x9, x7
    sra x30, x6, x11
    srl x20, x1, x20
    slli x22, x18, 5
    xori x10, x4, 1932
    or x4, x28, x16
    srli x13, x12, 17
    slt x16, x7, x18
    slt x17, x17, x14
    or x26, x8, x6
    fmax.s f11, f23, f9
    srl x13, x29, x30
    bne x16, x6, _br_taken_6
    sll x16, x9, x11
    j _br_done_6
_br_taken_6:
    xor x16, x24, x29
_br_done_6:
    xor x17, x13, x17
    or x19, x23, x25
    ori x18, x24, -584
    andi x14, x19, -85
    srli x10, x8, 6
    bge x23, x10, _br_taken_7
    xor x9, x1, x22
    j _br_done_7
_br_taken_7:
    sra x9, x6, x15
_br_done_7:
    sltiu x12, x13, -1576
    slt x23, x17, x30
    add x20, x8, x21
    andi x20, x28, 124
    xor x12, x20, x20
    slti x25, x28, -771
    addi x6, x23, 747
    srl x29, x30, x19
    fmin.s f20, f20, f31
    fsub.d f1, f27, f19
    fdiv.s f28, f14, f22
    xori x22, x19, 1255
    sltiu x18, x27, 896
    sub x6, x7, x22
    sltiu x4, x20, -1592
    slt x27, x8, x8
    slt x5, x22, x14
    srli x1, x11, 4
    srli x24, x29, 22
    srli x4, x1, 22
    sltiu x10, x1, 1412
    bltu x15, x13, _br_taken_8
    sra x19, x18, x25
    j _br_done_8
_br_taken_8:
    sltu x19, x23, x15
_br_done_8:
    add x16, x9, x13
    fsub.d f12, f22, f19
    sltiu x11, x21, 1438
    blt x12, x19, _br_taken_9
    sll x24, x17, x19
    j _br_done_9
_br_taken_9:
    slt x24, x16, x30
_br_done_9:
    xori x6, x27, -1789
    srai x24, x11, 12
    slt x16, x15, x10
    ori x19, x4, 10
    fadd.s f18, f9, f20
    xor x10, x8, x16
    sltu x30, x21, x1
    sub x21, x17, x16
    add x1, x22, x10
    fnmsub.s f2, f25, f16, f5
    fmax.s f15, f6, f11
    bne x7, x6, _br_taken_10
    add x11, x7, x25
    j _br_done_10
_br_taken_10:
    sltu x11, x10, x25
_br_done_10:
    srli x23, x27, 3
    or x8, x27, x23
    andi x1, x13, -340
    slt x11, x16, x5
    sub x5, x25, x15
    xor x1, x15, x4
    sltiu x18, x16, 64
    sltu x27, x28, x26
    mul x27, x8, x4
    blt x23, x27, _br_taken_11
    srl x1, x27, x9
    j _br_done_11
_br_taken_11:
    sub x1, x12, x23
_br_done_11:
    bne x14, x28, _br_taken_12
    xor x27, x5, x23
    j _br_done_12
_br_taken_12:
    or x27, x6, x5
_br_done_12:
    bltu x20, x19, _br_taken_13
    xor x1, x30, x10
    j _br_done_13
_br_taken_13:
    sll x1, x18, x25
_br_done_13:
    sub x24, x27, x21
    andi x7, x10, 728
    blt x29, x26, _br_taken_14
    slt x14, x27, x21
    j _br_done_14
_br_taken_14:
    add x14, x13, x14
_br_done_14:
    srai x7, x28, 10
    slli x26, x28, 11
    add x22, x4, x20
    rem x18, x28, x28
    mulhsu x10, x8, x26
    fmadd.s f30, f8, f23, f6
    fsub.s f19, f23, f30
    fmin.d f3, f26, f20
    fadd.s f21, f22, f12
    fsub.s f26, f19, f24
    fmadd.s f6, f16, f12, f4
    sra x11, x29, x20
    slt x28, x11, x10
    sra x1, x25, x18
    ori x21, x12, -935
    srli x30, x25, 12
    xori x10, x9, 1208
    xor x26, x29, x11
    beq x30, x26, _br_taken_15
    xor x17, x23, x29
    j _br_done_15
_br_taken_15:
    and x17, x1, x13
_br_done_15:
    srli x26, x26, 1
    ori x25, x25, -1246
    sll x14, x8, x20
    ori x8, x30, -153
    srai x5, x12, 0
    xori x28, x20, 1056
    beq x15, x24, _br_taken_16
    slt x15, x11, x9
    j _br_done_16
_br_taken_16:
    sub x15, x28, x9
_br_done_16:
    addi x16, x31, 972
    amoand.w x28, x10, (x16)
    andi x22, x9, 794
    slt x13, x10, x1
    xor x12, x9, x21
    fnmsub.s f20, f13, f10, f29
    fdiv.s f19, f14, f1
    fmul.s f22, f4, f3
    fnmsub.d f17, f5, f0, f28
    fdiv.s f18, f24, f7
    srai x11, x13, 14
    addi x25, x24, -1219
    srai x18, x12, 30
    sub x20, x30, x4
    xori x29, x12, 85
    sll x19, x15, x13
    lw x5, 600(x31)
    sw x23, 600(x31)
    ori x30, x25, -91
    addi x18, x16, 2014
    beq x5, x19, _br_taken_17
    srl x6, x21, x28
    j _br_done_17
_br_taken_17:
    srl x6, x10, x16
_br_done_17:
    srli x7, x8, 27
    srl x19, x20, x6
    sll x21, x30, x5
    xor x10, x11, x23
    srl x28, x7, x19
    slt x4, x6, x25
    mulh x20, x24, x24
    mulh x10, x8, x4
    xori x17, x12, -278
    fmul.s f12, f24, f12
    fnmsub.s f11, f18, f9, f3
    fnmsub.d f12, f8, f4, f4
    sltiu x20, x22, -1149
    sub x7, x12, x26
    slt x1, x29, x23
    and x25, x12, x10
    slli x16, x24, 26
    fmin.s f14, f17, f4
    fmadd.s f10, f29, f27, f1
    fmin.d f8, f18, f20
    sltiu x11, x10, -426
    bltu x6, x14, _br_taken_18
    sltu x1, x19, x20
    j _br_done_18
_br_taken_18:
    or x1, x18, x12
_br_done_18:
    lh x10, 292(x31)
    sh x8, 292(x31)
    addi x28, x31, 956
    amoxor.w x20, x17, (x28)
    bltu x29, x29, _br_taken_19
    or x20, x26, x26
    j _br_done_19
_br_taken_19:
    and x20, x12, x30
_br_done_19:
    sra x24, x4, x21
    add x15, x14, x16
    xori x4, x4, 352
    sub x28, x26, x7
    remu x27, x23, x24
    blt x20, x19, _br_taken_20
    add x24, x13, x14
    j _br_done_20
_br_taken_20:
    or x24, x26, x18
_br_done_20:
    bne x27, x22, _br_taken_21
    or x30, x24, x20
    j _br_done_21
_br_taken_21:
    sltu x30, x7, x18
_br_done_21:
    beq x26, x18, _br_taken_22
    sltu x27, x29, x28
    j _br_done_22
_br_taken_22:
    sub x27, x26, x14
_br_done_22:
    xori x1, x5, 1817
    and x22, x22, x13
    slli x24, x25, 26
    bne x7, x7, _br_taken_23
    add x12, x28, x15
    j _br_done_23
_br_taken_23:
    sll x12, x6, x6
_br_done_23:
    xor x1, x6, x6
    sll x17, x12, x15
    ori x19, x12, 751
    sltu x11, x19, x26
    srl x24, x11, x28
    sll x19, x10, x27
    srl x18, x30, x9
    srai x21, x20, 7
    sub x15, x8, x15
    sll x10, x29, x23
    sub x11, x14, x26
    slt x22, x19, x28
    sll x7, x25, x4
    fmin.s f17, f12, f31
    fmsub.s f13, f2, f13, f25
    fdiv.d f18, f31, f0
    bgeu x25, x5, _br_taken_24
    sra x30, x17, x7
    j _br_done_24
_br_taken_24:
    or x30, x24, x12
_br_done_24:
    fsub.s f22, f23, f28
    fmin.s f23, f26, f18
    fadd.s f29, f0, f28
    and x25, x30, x29
    and x11, x23, x15
    sll x29, x22, x18
    sltu x19, x24, x1
    addi x1, x10, 1938
    fmul.s f26, f30, f4
    fnmadd.d f19, f18, f22, f27
    fnmsub.s f11, f11, f3, f28
    bne x5, x13, _br_taken_25
    xor x16, x13, x30
    j _br_done_25
_br_taken_25:
    xor x16, x11, x19
_br_done_25:
    bltu x12, x14, _br_taken_26
    sll x23, x22, x10
    j _br_done_26
_br_taken_26:
    or x23, x23, x16
_br_done_26:
    bgeu x10, x7, _br_taken_27
    and x11, x9, x12
    j _br_done_27
_br_taken_27:
    sltu x11, x8, x9
_br_done_27:
    blt x21, x11, _br_taken_28
    slt x30, x18, x13
    j _br_done_28
_br_taken_28:
    srl x30, x15, x23
_br_done_28:
    srai x17, x9, 8
    and x1, x22, x4
    addi x13, x31, 316
    amomax.w x8, x22, (x13)
    fnmadd.d f2, f23, f7, f26
    fsub.s f23, f20, f14
    fadd.d f17, f29, f23
    fnmsub.s f4, f1, f17, f18
    addi x5, x31, 720
    amomaxu.w x28, x23, (x5)
    sltu x28, x21, x7
    add x29, x23, x9
    sltiu x15, x14, -1173
    sltu x24, x17, x13
    sltiu x10, x26, -813
    xor x23, x10, x22
    srl x24, x22, x14
    xori x25, x25, -1306
    beq x21, x12, _br_taken_29
    add x28, x10, x4
    j _br_done_29
_br_taken_29:
    sltu x28, x25, x15
_br_done_29:
    blt x21, x9, _br_taken_30
    sra x25, x1, x25
    j _br_done_30
_br_taken_30:
    or x25, x6, x29
_br_done_30:
    and x19, x30, x26
    andi x7, x11, -46
    sll x11, x10, x6
    xori x1, x29, 1969
    slti x6, x5, 88
    xori x5, x21, 1679
    bne x12, x22, _br_taken_31
    sll x24, x9, x4
    j _br_done_31
_br_taken_31:
    srl x24, x16, x22
_br_done_31:
    fmul.d f23, f10, f6
    fnmsub.s f27, f13, f23, f23
    bge x1, x20, _br_taken_32
    sltu x19, x20, x24
    j _br_done_32
_br_taken_32:
    srl x19, x30, x19
_br_done_32:
    lw x6, 924(x31)
    sw x23, 924(x31)
    bgeu x18, x16, _br_taken_33
    sltu x22, x26, x28
    j _br_done_33
_br_taken_33:
    sra x22, x16, x19
_br_done_33:
    and x12, x27, x9
    addi x17, x31, 872
    amoswap.w x13, x28, (x17)
    srli x17, x20, 8
    sltiu x9, x10, -1597
    ori x8, x23, 824
    addi x19, x31, 84
    amomin.w x11, x13, (x19)
    bne x15, x29, _br_taken_34
    add x14, x23, x19
    j _br_done_34
_br_taken_34:
    srl x14, x17, x22
_br_done_34:
    lbu x17, 476(x31)
    sb x25, 476(x31)
    bne x9, x22, _br_taken_35
    or x26, x24, x1
    j _br_done_35
_br_taken_35:
    and x26, x23, x16
_br_done_35:
    slt x8, x22, x29
    sltu x11, x13, x24
    and x9, x1, x29
    srai x27, x25, 7
    addi x18, x7, 34
    sra x18, x29, x5
    lbu x21, 908(x31)
    sb x7, 908(x31)
    or x6, x19, x6
    ori x13, x30, 1442
    bltu x16, x10, _br_taken_36
    srl x17, x29, x11
    j _br_done_36
_br_taken_36:
    slt x17, x29, x25
_br_done_36:
    remu x20, x27, x23
    lhu x9, 1008(x31)
    sh x19, 1008(x31)
    bge x9, x8, _br_taken_37
    sll x19, x23, x16
    j _br_done_37
_br_taken_37:
    sll x19, x20, x10
_br_done_37:
    fdiv.d f8, f29, f24
    fdiv.s f6, f1, f8
    bge x30, x16, _br_taken_38
    xor x8, x23, x30
    j _br_done_38
_br_taken_38:
    sll x8, x5, x6
_br_done_38:
    bge x10, x16, _br_taken_39
    slt x23, x19, x27
    j _br_done_39
_br_taken_39:
    or x23, x14, x12
_br_done_39:
    sltu x5, x8, x22
    xori x24, x24, 1304
    sub x12, x23, x21
    addi x17, x31, 788
    amoswap.w x14, x7, (x17)
    srl x26, x26, x15
    andi x18, x29, -419
    and x27, x13, x4
    fmax.s f23, f19, f0
    slti x23, x16, -994
    and x17, x21, x21
    sll x30, x4, x10
    sub x26, x12, x5
    srai x29, x23, 30
    add x9, x12, x12
    bgeu x24, x11, _br_taken_40
    slt x19, x14, x20
    j _br_done_40
_br_taken_40:
    sub x19, x24, x25
_br_done_40:
    lbu x11, 528(x31)
    sb x25, 528(x31)
    fmin.d f25, f23, f30
    slt x28, x12, x11
    srai x14, x18, 25
    andi x4, x21, -1581
    sltiu x6, x18, -1739
    andi x5, x13, 1875
    bge x28, x28, _br_taken_41
    and x8, x25, x19
    j _br_done_41
_br_taken_41:
    sltu x8, x16, x25
_br_done_41:
    lh x6, 336(x31)
    sh x26, 336(x31)
    slt x7, x10, x10
    slli x18, x19, 8
    slt x1, x21, x6
    addi x28, x31, 880
    amomaxu.w x15, x13, (x28)
    beq x7, x30, _br_taken_42
    sltu x23, x10, x19
    j _br_done_42
_br_taken_42:
    add x23, x5, x12
_br_done_42:
    fsub.s f20, f26, f10
    fmul.s f23, f3, f24
    srl x30, x20, x18
    xori x13, x21, 1384
    and x6, x17, x26
    srai x16, x11, 10
    xori x17, x24, -1107
    addi x12, x17, -1490
    lw x16, 128(x31)
    sw x11, 128(x31)
    fmax.d f15, f10, f25
    fdiv.s f12, f1, f26
    andi x13, x15, 947
    slli x25, x18, 2
    beq x10, x7, _br_taken_43
    sra x30, x25, x25
    j _br_done_43
_br_taken_43:
    srl x30, x25, x8
_br_done_43:
    andi x12, x24, -773
    beq x13, x30, _br_taken_44
    srl x21, x21, x11
    j _br_done_44
_br_taken_44:
    sub x21, x21, x21
_br_done_44:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x03c909dcab6da847
    .dword 0x9d840d7d32df60fb
    .dword 0x2a5075242f06a01d
    .dword 0xbc3c0cfbf477bbf6
    .dword 0x996a170c99c83885
    .dword 0x594da3529e03c6c7
    .dword 0xf3d54a379d0af951
    .dword 0xfa3fe37c4a78b209
    .dword 0xbe80a30095be6d74
    .dword 0x9d1c5bb8b44aaec9
    .dword 0xfa65c40bf16cdfd2
    .dword 0xbd8a52d834771b29
    .dword 0xa168a72c09d692bb
    .dword 0x6e2a45ab0348066d
    .dword 0x22f06eb5b198268e
    .dword 0xba176c241abc2f3b
    .dword 0x2b028b013f5f033c
    .dword 0x6dd5e8a9709263a1
    .dword 0x69722253990e337f
    .dword 0xb46fd675dd7a8974
    .dword 0x935431c99c482ca7
    .dword 0xcecf8eb71cd1c708
    .dword 0x65afadfcf51b58da
    .dword 0x7528f5d66727138f
    .dword 0x89c70699cc6720ef
    .dword 0xc86642bd9e4eb2e0
    .dword 0xacd3dbb0f7d65d43
    .dword 0xa2def327f208d72d
    .dword 0x60f6859147fc83ae
    .dword 0x7c47b10989713a30
    .dword 0x0568d2eef8258696
    .dword 0x1e85421f2e598c31

    .align 2
_torture_data:
    .word 0x8800fc2c
    .word 0x03e4e175
    .word 0xd6135e4d
    .word 0xff199c8c
    .word 0x57e4c5bf
    .word 0x6d629e12
    .word 0x15f005cd
    .word 0xa2f23c72
    .word 0xf705d91e
    .word 0xfdee22ce
    .word 0x360887b4
    .word 0xa71fe14d
    .word 0x8fe477b5
    .word 0x4118ab06
    .word 0x2f60c858
    .word 0x033f610b
    .word 0x50b882b6
    .word 0x18486c5a
    .word 0x0c5bf46d
    .word 0xb4db2d53
    .word 0x734dd1b6
    .word 0x422a6d86
    .word 0x6b091241
    .word 0x0cf18197
    .word 0xa817d4d6
    .word 0x540aada6
    .word 0x353beb58
    .word 0xda660b23
    .word 0xd988255d
    .word 0x751327c3
    .word 0x713ebc3f
    .word 0x01bce00a
    .word 0xf2c224db
    .word 0xf959d8e0
    .word 0x85e750c0
    .word 0xc01f0246
    .word 0x41a31fc5
    .word 0x7e4d1903
    .word 0x492e5a73
    .word 0x6c66adb4
    .word 0x1790bb17
    .word 0xc3abc679
    .word 0xf02bcc76
    .word 0x09bd7586
    .word 0x6c55732b
    .word 0x65293869
    .word 0x995d8bf5
    .word 0x9fbbfb21
    .word 0x87432c41
    .word 0x8a31a881
    .word 0x0184e68d
    .word 0xa71bee6c
    .word 0x196621cf
    .word 0x35a5d9db
    .word 0xc3342ce0
    .word 0x822c669a
    .word 0x4157f986
    .word 0xae868659
    .word 0x3dee7e6c
    .word 0xed7c5f58
    .word 0x1cfff833
    .word 0x5b0278b5
    .word 0x447d1e90
    .word 0x4ede1b81
    .word 0x27da35c8
    .word 0xce5086c3
    .word 0x804472e2
    .word 0xe10cdee3
    .word 0x862357f2
    .word 0x310f15c9
    .word 0x36e815cb
    .word 0x79e9b2fe
    .word 0xc1f7fb4b
    .word 0xcbc27794
    .word 0xf3a2e547
    .word 0x07e405d8
    .word 0xc99b7940
    .word 0xe08baba9
    .word 0x07c33532
    .word 0xb37d8283
    .word 0xea4d51fd
    .word 0x494ce420
    .word 0xf80486b4
    .word 0x6d61b1ae
    .word 0xd556aa2a
    .word 0x5a08c914
    .word 0x33975086
    .word 0xc8822e80
    .word 0x5a82572d
    .word 0x5fdaf672
    .word 0xc375c446
    .word 0x701af8df
    .word 0xeccb7924
    .word 0xfb8df822
    .word 0xfdc75b42
    .word 0xcc93017f
    .word 0x44527ca5
    .word 0xac358ecc
    .word 0xad875fe2
    .word 0x914cfd5c
    .word 0x974a6932
    .word 0x9111ea9c
    .word 0xdbbc1b0f
    .word 0xb6fb701e
    .word 0x8814a48c
    .word 0x945f230c
    .word 0x03d92b59
    .word 0x8724db73
    .word 0x79d6c0a4
    .word 0xb83883f6
    .word 0x29167eed
    .word 0x6cbd03fc
    .word 0xcbcc8e9d
    .word 0x818de274
    .word 0x65f722ad
    .word 0xc3108d85
    .word 0xb34ae80a
    .word 0x62225c63
    .word 0x99968388
    .word 0x6fce64d1
    .word 0x7d7a51c0
    .word 0xf82e5053
    .word 0x45a9cbb7
    .word 0xcbab721b
    .word 0x63faefa1
    .word 0xfcdff89d
    .word 0x016a71e4
    .word 0x6ad88f2f
    .word 0x3ed1566d
    .word 0xcaf73654
    .word 0x4e623c4e
    .word 0xa28c4a23
    .word 0x491b9df0
    .word 0x54cdc48d
    .word 0x0b80c4e3
    .word 0x1b461ef4
    .word 0x731698da
    .word 0xf9fcab14
    .word 0x6e09dce3
    .word 0x5153e7ff
    .word 0x5fac8756
    .word 0x748e7960
    .word 0x73881416
    .word 0x122110e2
    .word 0x71c60a45
    .word 0x8876b839
    .word 0xa15fcae8
    .word 0xf4224783
    .word 0x463cb539
    .word 0xa432e9a0
    .word 0xae64a5ab
    .word 0xecf0412e
    .word 0x0d337fd0
    .word 0xdad5921f
    .word 0x9496ec75
    .word 0x190f35f8
    .word 0xc5efe871
    .word 0x8c5419b4
    .word 0xa635aafa
    .word 0xb3842517
    .word 0x30c0610e
    .word 0x4eaa9820
    .word 0xf2011b01
    .word 0xf3da4b7c
    .word 0xc3fe3fe1
    .word 0xf1e82641
    .word 0x01d222f3
    .word 0x88cafbcf
    .word 0x2ca09052
    .word 0x47426df8
    .word 0xcd42ca60
    .word 0x4e11b4ae
    .word 0xa93d5306
    .word 0xede0d016
    .word 0xf969a7b8
    .word 0xc02cb20c
    .word 0xdd08a4bd
    .word 0x0090d26f
    .word 0x93ecde66
    .word 0x4c61ee6b
    .word 0x62835178
    .word 0x652b1064
    .word 0xcb6d521c
    .word 0x2bd174b2
    .word 0x463fbc5c
    .word 0x36eb2cb6
    .word 0x0bfd4356
    .word 0x5dff75ee
    .word 0xc69f3ceb
    .word 0x43fcfdcf
    .word 0xadd0f028
    .word 0xed78850c
    .word 0x3113094b
    .word 0x1ef1934f
    .word 0xc06ff61f
    .word 0xf8b26dea
    .word 0x7dce8375
    .word 0x56c83bfb
    .word 0x4af2efc1
    .word 0x3d9bedb3
    .word 0xfb149138
    .word 0x8a421e2d
    .word 0xd876fb64
    .word 0x58dd7185
    .word 0x4e74976c
    .word 0xfdd18ed1
    .word 0x32919654
    .word 0x2a690908
    .word 0x1d15ad9a
    .word 0x03c5d537
    .word 0xf1add87c
    .word 0x9beab428
    .word 0x82cd0a11
    .word 0x7c41ddca
    .word 0x1f767fbb
    .word 0xab96ac49
    .word 0xa7cec486
    .word 0x75bb5376
    .word 0x52774966
    .word 0x2cae7181
    .word 0x79554f2e
    .word 0x0da3156c
    .word 0x30a2880a
    .word 0x892fe70b
    .word 0xf4d2f215
    .word 0xafb01d15
    .word 0xf7ff4553
    .word 0x91a53fab
    .word 0xf2bb25e9
    .word 0x7eaddf37
    .word 0x2ce182ee
    .word 0x96d21556
    .word 0x0540c0bd
    .word 0x2387ea3e
    .word 0x5b91e4fe
    .word 0x8f65d467
    .word 0xbf5cde73
    .word 0x560e0dfd
    .word 0x206a8487
    .word 0x49b32b6a
    .word 0xdbee062d
    .word 0xca5ec817
    .word 0x2cb93d77
    .word 0x3358b13f
    .word 0x06b13036
    .word 0x7e51f5d0
    .word 0xffd6368e
    .word 0x7dc428a4
    .word 0x97278238
    .word 0xd33fd417
    .word 0xfebb2faa
    .word 0x48288820
    .word 0x8ffd8522
    .word 0x3f1937ad
    .word 0x3510bbe3
    .word 0x577dc551

#include "frost_footer.S"
