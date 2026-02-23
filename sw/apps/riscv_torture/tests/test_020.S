// Generated RV32IMAFDC torture test for Frost (seed=61)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x7e96ba87
    li x4, 0x8e835961
    li x5, 0x5213dcb1
    li x6, 0xb17361da
    li x7, 0x7c7573a5
    li x8, 0x5bfe0688
    li x9, 0x67ced9d2
    li x10, 0x2ae710d8
    li x11, 0xa1bd7574
    li x12, 0xb0561658
    li x13, 0xa280ebee
    li x14, 0x5669810a
    li x15, 0x24e83219
    li x16, 0xba8dbfdc
    li x17, 0x57206ffc
    li x18, 0xfa8da3e5
    li x19, 0x9e327ac8
    li x20, 0x423eb1cb
    li x21, 0x685f9b58
    li x22, 0x216638cb
    li x23, 0x5e18f99d
    li x24, 0x629d58d8
    li x25, 0xd9a2d18b
    li x26, 0xff9cd37e
    li x27, 0x6c453d41
    li x28, 0x1b9f293a
    li x29, 0x10531751
    li x30, 0x37ad8824
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
    li x1, 0x9f104b12

    beq x29, x18, _br_taken_0
    or x11, x15, x9
    j _br_done_0
_br_taken_0:
    sll x11, x5, x15
_br_done_0:
    xor x23, x16, x1
    ori x26, x9, 1010
    srli x29, x27, 29
    mulh x25, x9, x28
    fsub.s f13, f16, f29
    srl x8, x6, x8
    sll x13, x7, x21
    srli x14, x6, 8
    sub x16, x11, x16
    xor x23, x24, x21
    slli x27, x4, 8
    ori x27, x18, -414
    addi x4, x18, 771
    addi x18, x31, 572
    amomin.w x27, x29, (x18)
    bne x20, x29, _br_taken_1
    slt x11, x22, x24
    j _br_done_1
_br_taken_1:
    sll x11, x23, x14
_br_done_1:
    srli x11, x21, 26
    srli x19, x27, 9
    sra x26, x27, x17
    slli x22, x15, 30
    srl x14, x29, x25
    sra x23, x21, x29
    beq x17, x17, _br_taken_2
    slt x7, x4, x9
    j _br_done_2
_br_taken_2:
    sub x7, x20, x20
_br_done_2:
    lh x7, 568(x31)
    sh x17, 568(x31)
    ori x9, x22, 1879
    xori x1, x29, 495
    sra x21, x13, x17
    bltu x19, x24, _br_taken_3
    and x9, x8, x4
    j _br_done_3
_br_taken_3:
    sltu x9, x4, x13
_br_done_3:
    sltu x21, x15, x26
    addi x20, x31, 432
    amomin.w x9, x22, (x20)
    bge x5, x8, _br_taken_4
    xor x5, x13, x13
    j _br_done_4
_br_taken_4:
    sll x5, x10, x15
_br_done_4:
    mul x5, x28, x9
    mulhsu x9, x23, x5
    srl x20, x10, x23
    sub x29, x21, x27
    addi x29, x29, -1849
    lb x29, 472(x31)
    sb x7, 472(x31)
    bltu x18, x29, _br_taken_5
    add x19, x12, x1
    j _br_done_5
_br_taken_5:
    sll x19, x6, x10
_br_done_5:
    srai x1, x29, 0
    lb x22, 408(x31)
    sb x19, 408(x31)
    srl x1, x21, x9
    fdiv.s f16, f16, f14
    fsub.s f27, f30, f14
    fsub.d f6, f9, f25
    slti x30, x18, -1505
    ori x6, x18, 85
    bne x23, x14, _br_taken_6
    and x30, x29, x27
    j _br_done_6
_br_taken_6:
    add x30, x13, x5
_br_done_6:
    blt x9, x11, _br_taken_7
    srl x14, x19, x12
    j _br_done_7
_br_taken_7:
    slt x14, x27, x28
_br_done_7:
    bne x6, x21, _br_taken_8
    xor x18, x20, x26
    j _br_done_8
_br_taken_8:
    sra x18, x25, x10
_br_done_8:
    bge x5, x4, _br_taken_9
    sra x21, x27, x12
    j _br_done_9
_br_taken_9:
    and x21, x6, x21
_br_done_9:
    sltu x16, x11, x15
    srai x26, x24, 14
    srli x15, x18, 28
    xori x21, x18, -19
    or x26, x23, x5
    beq x8, x29, _br_taken_10
    xor x25, x20, x13
    j _br_done_10
_br_taken_10:
    or x25, x21, x8
_br_done_10:
    lw x1, 28(x31)
    sw x16, 28(x31)
    fadd.s f13, f13, f9
    srl x16, x10, x16
    andi x11, x16, -1816
    xori x25, x16, -129
    and x22, x24, x24
    srai x6, x1, 23
    mulhsu x1, x23, x16
    divu x23, x27, x29
    lb x13, 656(x31)
    sb x17, 656(x31)
    slt x10, x22, x4
    fmsub.s f8, f14, f12, f10
    fmul.s f23, f20, f11
    sll x18, x25, x24
    or x22, x17, x22
    srli x26, x20, 13
    or x22, x12, x5
    srl x26, x26, x12
    sub x24, x6, x15
    bne x12, x21, _br_taken_11
    sltu x19, x5, x27
    j _br_done_11
_br_taken_11:
    and x19, x11, x22
_br_done_11:
    lb x10, 648(x31)
    sb x28, 648(x31)
    lh x21, 964(x31)
    sh x22, 964(x31)
    srl x12, x16, x15
    sltiu x12, x30, 1106
    sra x18, x30, x20
    slti x14, x4, -512
    ori x29, x10, -606
    bge x17, x14, _br_taken_12
    xor x18, x29, x18
    j _br_done_12
_br_taken_12:
    add x18, x1, x24
_br_done_12:
    slt x1, x26, x22
    srai x4, x11, 6
    or x10, x17, x8
    addi x18, x31, 460
    amoor.w x16, x14, (x18)
    blt x4, x30, _br_taken_13
    sub x12, x6, x18
    j _br_done_13
_br_taken_13:
    and x12, x10, x24
_br_done_13:
    or x4, x19, x12
    sub x20, x10, x19
    srli x5, x6, 1
    slli x28, x16, 12
    slti x28, x29, -1048
    srli x10, x4, 24
    and x1, x26, x26
    srl x7, x4, x10
    addi x13, x28, -1422
    sll x29, x9, x30
    sra x18, x20, x4
    srai x1, x22, 11
    andi x12, x14, 1860
    sltu x17, x12, x18
    addi x10, x18, -887
    bgeu x29, x1, _br_taken_14
    sub x11, x21, x11
    j _br_done_14
_br_taken_14:
    slt x11, x17, x25
_br_done_14:
    bge x18, x9, _br_taken_15
    or x16, x8, x11
    j _br_done_15
_br_taken_15:
    sra x16, x4, x29
_br_done_15:
    slli x9, x7, 27
    sll x24, x6, x25
    lbu x27, 916(x31)
    sb x25, 916(x31)
    bltu x10, x15, _br_taken_16
    sll x13, x22, x14
    j _br_done_16
_br_taken_16:
    and x13, x19, x4
_br_done_16:
    lw x6, 400(x31)
    sw x4, 400(x31)
    fdiv.s f0, f1, f3
    sltiu x22, x14, 1653
    add x23, x7, x27
    slli x18, x18, 13
    slli x5, x16, 10
    and x29, x6, x6
    slli x23, x5, 3
    sra x19, x5, x23
    fdiv.s f24, f18, f7
    fmax.s f23, f24, f29
    beq x24, x18, _br_taken_17
    and x18, x20, x11
    j _br_done_17
_br_taken_17:
    slt x18, x22, x10
_br_done_17:
    bne x12, x11, _br_taken_18
    srl x7, x13, x24
    j _br_done_18
_br_taken_18:
    sub x7, x9, x18
_br_done_18:
    fmin.s f27, f24, f5
    add x22, x5, x14
    andi x20, x30, 542
    bgeu x29, x30, _br_taken_19
    sll x30, x25, x9
    j _br_done_19
_br_taken_19:
    sll x30, x20, x29
_br_done_19:
    sltu x26, x28, x25
    sll x15, x1, x7
    sll x12, x1, x16
    ori x12, x21, -1616
    srai x23, x17, 9
    srai x13, x26, 7
    xor x6, x15, x20
    slli x21, x23, 1
    srli x18, x12, 6
    xor x5, x28, x22
    xori x11, x25, -477
    slli x12, x23, 20
    sltiu x10, x7, -271
    beq x24, x11, _br_taken_20
    sll x20, x7, x20
    j _br_done_20
_br_taken_20:
    srl x20, x11, x21
_br_done_20:
    addi x29, x31, 728
    amomax.w x15, x14, (x29)
    slti x20, x20, 6
    slti x14, x21, -1612
    or x21, x26, x12
    fmul.s f5, f22, f17
    addi x17, x31, 784
    amoor.w x22, x26, (x17)
    sub x20, x17, x21
    fsub.s f2, f12, f4
    fmin.d f19, f28, f11
    fdiv.d f29, f8, f30
    fmul.s f5, f6, f6
    bgeu x15, x24, _br_taken_21
    add x23, x7, x21
    j _br_done_21
_br_taken_21:
    srl x23, x1, x20
_br_done_21:
    and x21, x22, x24
    srai x25, x22, 23
    and x13, x21, x12
    slli x20, x7, 6
    add x4, x16, x19
    sll x21, x20, x9
    sra x24, x15, x21
    ori x19, x9, -335
    srl x7, x10, x27
    add x7, x29, x20
    beq x7, x19, _br_taken_22
    slt x23, x10, x9
    j _br_done_22
_br_taken_22:
    sub x23, x30, x13
_br_done_22:
    srl x1, x26, x12
    sltu x18, x19, x30
    andi x20, x29, 1227
    divu x7, x24, x9
    mulh x9, x5, x28
    sltiu x23, x10, -2033
    xori x28, x9, -152
    lw x9, 28(x31)
    sw x19, 28(x31)
    lb x21, 0(x31)
    sb x14, 0(x31)
    srai x9, x30, 11
    bltu x11, x7, _br_taken_23
    sra x12, x4, x30
    j _br_done_23
_br_taken_23:
    add x12, x18, x28
_br_done_23:
    and x6, x22, x22
    blt x8, x21, _br_taken_24
    slt x17, x28, x7
    j _br_done_24
_br_taken_24:
    slt x17, x28, x14
_br_done_24:
    beq x24, x5, _br_taken_25
    and x28, x29, x10
    j _br_done_25
_br_taken_25:
    xor x28, x19, x27
_br_done_25:
    fsub.d f28, f4, f21
    fmin.s f24, f1, f22
    fdiv.d f18, f24, f24
    slli x8, x5, 29
    or x20, x29, x8
    sltu x8, x6, x27
    bltu x15, x25, _br_taken_26
    add x4, x21, x7
    j _br_done_26
_br_taken_26:
    sra x4, x18, x13
_br_done_26:
    lhu x9, 392(x31)
    sh x15, 392(x31)
    fdiv.s f17, f18, f30
    fdiv.d f5, f13, f13
    addi x18, x6, 1258
    ori x11, x7, 1165
    xor x24, x23, x30
    or x18, x25, x11
    srli x26, x8, 9
    xori x29, x11, -1299
    xor x28, x12, x22
    fnmadd.s f28, f28, f24, f30
    fnmsub.d f26, f3, f4, f1
    fmsub.d f23, f14, f27, f9
    bne x5, x22, _br_taken_27
    sll x26, x26, x8
    j _br_done_27
_br_taken_27:
    sra x26, x21, x25
_br_done_27:
    srai x1, x9, 9
    fsub.d f1, f27, f6
    bge x11, x16, _br_taken_28
    and x1, x26, x30
    j _br_done_28
_br_taken_28:
    or x1, x13, x15
_br_done_28:
    bgeu x10, x6, _br_taken_29
    sra x23, x28, x26
    j _br_done_29
_br_taken_29:
    sll x23, x17, x10
_br_done_29:
    lhu x9, 912(x31)
    sh x20, 912(x31)
    fdiv.s f30, f1, f15
    fmax.d f28, f31, f17
    fadd.d f3, f18, f21
    bge x26, x10, _br_taken_30
    add x28, x22, x24
    j _br_done_30
_br_taken_30:
    add x28, x1, x27
_br_done_30:
    addi x20, x24, 524
    bge x27, x18, _br_taken_31
    srl x15, x11, x4
    j _br_done_31
_br_taken_31:
    srl x15, x4, x23
_br_done_31:
    and x12, x20, x9
    xor x12, x17, x4
    sub x24, x1, x10
    sll x24, x19, x14
    bgeu x13, x19, _br_taken_32
    or x11, x28, x9
    j _br_done_32
_br_taken_32:
    sub x11, x25, x17
_br_done_32:
    sra x8, x15, x26
    and x7, x30, x20
    xori x25, x24, -1789
    rem x10, x19, x11
    sub x15, x19, x29
    sltiu x9, x16, -1452
    srli x5, x23, 3
    xor x28, x1, x23
    srli x5, x30, 8
    beq x22, x6, _br_taken_33
    sll x15, x26, x22
    j _br_done_33
_br_taken_33:
    sra x15, x13, x13
_br_done_33:
    slli x21, x6, 15
    srl x29, x23, x19
    bltu x4, x27, _br_taken_34
    srl x8, x19, x22
    j _br_done_34
_br_taken_34:
    slt x8, x16, x29
_br_done_34:
    fmin.d f0, f4, f12
    fnmsub.d f16, f6, f26, f1
    or x29, x29, x25
    addi x12, x31, 832
    amomin.w x14, x9, (x12)
    blt x16, x16, _br_taken_35
    or x13, x10, x7
    j _br_done_35
_br_taken_35:
    sub x13, x16, x5
_br_done_35:
    srai x10, x26, 0
    sub x19, x26, x5
    srai x13, x29, 7
    and x7, x16, x13
    addi x25, x31, 400
    amoand.w x1, x28, (x25)
    addi x14, x31, 592
    amoor.w x22, x22, (x14)
    addi x17, x31, 560
    amoor.w x20, x10, (x17)
    bgeu x12, x29, _br_taken_36
    sra x1, x25, x7
    j _br_done_36
_br_taken_36:
    sll x1, x10, x17
_br_done_36:
    srl x19, x5, x29
    xori x23, x23, 1922
    srai x10, x19, 13
    slli x23, x14, 23
    andi x12, x26, -1035
    slt x16, x22, x21
    sltiu x16, x15, -1024
    bne x17, x1, _br_taken_37
    sra x25, x5, x22
    j _br_done_37
_br_taken_37:
    sltu x25, x7, x26
_br_done_37:
    srli x23, x20, 16
    xor x26, x7, x29
    and x8, x26, x21
    srli x4, x19, 30
    or x27, x4, x26
    andi x18, x8, -936
    sll x5, x25, x21
    or x5, x19, x18
    blt x5, x16, _br_taken_38
    sub x10, x24, x27
    j _br_done_38
_br_taken_38:
    xor x10, x7, x8
_br_done_38:
    and x17, x1, x28
    sltu x10, x24, x4
    fadd.s f24, f23, f31
    slt x10, x21, x7
    sub x16, x17, x22
    ori x10, x8, -1562
    ori x1, x14, -1724
    andi x8, x11, 1390
    bgeu x1, x16, _br_taken_39
    xor x18, x27, x17
    j _br_done_39
_br_taken_39:
    sltu x18, x26, x12
_br_done_39:
    bltu x19, x20, _br_taken_40
    sub x26, x27, x27
    j _br_done_40
_br_taken_40:
    and x26, x6, x13
_br_done_40:
    addi x29, x31, 80
    amoadd.w x30, x1, (x29)
    fadd.d f29, f12, f25
    lbu x9, 816(x31)
    sb x1, 816(x31)
    fnmsub.d f1, f27, f28, f6
    fadd.d f1, f23, f28
    slli x5, x21, 30
    sra x13, x5, x22
    addi x7, x17, 1162
    sll x1, x18, x14
    sra x19, x16, x8
    bge x19, x7, _br_taken_41
    and x6, x4, x8
    j _br_done_41
_br_taken_41:
    srl x6, x19, x8
_br_done_41:
    lhu x13, 420(x31)
    sh x18, 420(x31)
    lhu x6, 932(x31)
    sh x10, 932(x31)
    blt x24, x29, _br_taken_42
    and x27, x7, x25
    j _br_done_42
_br_taken_42:
    sll x27, x16, x6
_br_done_42:
    fmadd.s f5, f18, f27, f26
    fnmadd.s f29, f15, f18, f31
    sub x10, x30, x10
    sub x20, x15, x23
    ori x4, x19, -159
    addi x5, x31, 184
    amoxor.w x17, x6, (x5)
    sll x22, x12, x6
    sltu x8, x22, x7
    sub x28, x29, x17
    sra x28, x29, x1
    srai x15, x11, 1
    andi x24, x26, 1520
    add x21, x27, x10
    fmul.d f21, f4, f4
    fmsub.s f16, f15, f23, f23
    sltu x30, x28, x9
    xori x22, x9, -1368
    addi x14, x31, 836
    amomaxu.w x21, x8, (x14)
    sra x11, x9, x27
    xor x11, x13, x15
    add x22, x10, x1
    sra x19, x27, x26
    addi x6, x9, -1177
    andi x16, x28, 1296
    slti x28, x21, -444
    andi x18, x21, 1026
    or x22, x5, x19
    bgeu x30, x13, _br_taken_43
    add x10, x11, x14
    j _br_done_43
_br_taken_43:
    and x10, x27, x28
_br_done_43:
    xori x9, x1, -852
    srai x21, x20, 10
    srai x22, x25, 12
    srl x16, x28, x25
    slt x12, x27, x24
    div x11, x23, x30
    rem x28, x29, x18
    bge x5, x18, _br_taken_44
    or x30, x10, x24
    j _br_done_44
_br_taken_44:
    sll x30, x20, x15
_br_done_44:
    addi x7, x11, 1300
    sub x19, x30, x29
    blt x21, x10, _br_taken_45
    sll x13, x8, x26
    j _br_done_45
_br_taken_45:
    slt x13, x17, x20
_br_done_45:
    add x13, x24, x1
    and x9, x13, x18
    srai x13, x12, 18

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xed0663baca743c87
    .dword 0x7a146fffc4b3146d
    .dword 0x537f21a9fd7b7b1b
    .dword 0x08f5329c336d052e
    .dword 0x3775c7d13721ecd9
    .dword 0xddc2c563e9fbf411
    .dword 0xd1798d7b84e20076
    .dword 0xfe3d93a242ebea3e
    .dword 0x61b6fc5a6d19e5fe
    .dword 0x733a4d8ff5d7391f
    .dword 0x56e4e4b13c004a9c
    .dword 0x5537afd7a658bb56
    .dword 0xfcb4aedad25f0e0b
    .dword 0x8e7bb6aada2a15b2
    .dword 0xc00b9274215ef1a5
    .dword 0x9c33baf6cc5690d1
    .dword 0xf586e38943919ace
    .dword 0xede9ce3362dd4a4a
    .dword 0x7f0da77930ad49e7
    .dword 0x9835619b8e62f903
    .dword 0x059cd1df0d13403b
    .dword 0x8b4d340cc0cbb58c
    .dword 0xacd36caa6be5b464
    .dword 0xa4db97b3b834c898
    .dword 0xf0ca6fa90416f063
    .dword 0x3b4e9495a941ca7b
    .dword 0x38b2af90cb30cbef
    .dword 0x00cb0b6ada88ad57
    .dword 0xf5a360f03d566123
    .dword 0x2693ec6acc10fdc7
    .dword 0x6057477f99c02e7c
    .dword 0xa58dc1e013ea9b03

    .align 2
_torture_data:
    .word 0x47e30904
    .word 0xf598d836
    .word 0xfa019802
    .word 0x7653ac70
    .word 0x8431730d
    .word 0x59a8b889
    .word 0x68298870
    .word 0x5e74f976
    .word 0xa9c9d500
    .word 0xd07d4f14
    .word 0x350543d8
    .word 0xda633432
    .word 0xf7f187e4
    .word 0xa6b97fae
    .word 0x6c6684ad
    .word 0x42173c5e
    .word 0x6bd781d2
    .word 0x4f42d353
    .word 0x783a0b4d
    .word 0x8b4eef78
    .word 0x3dafa2a2
    .word 0xa7524929
    .word 0xa77911f7
    .word 0xbd4adb32
    .word 0x11535770
    .word 0x6b024eb8
    .word 0x6e35dbd0
    .word 0xa3c40178
    .word 0xc7be1336
    .word 0x3f9887a8
    .word 0x750f2458
    .word 0x65af1af3
    .word 0xefec6cba
    .word 0xb311a8f0
    .word 0xb70202e4
    .word 0x81c30c0f
    .word 0x03e6dc36
    .word 0x97f1c23e
    .word 0x8154cdf5
    .word 0x8a343a86
    .word 0x27959379
    .word 0xbc5d7ffe
    .word 0x55a72a9d
    .word 0x78cefede
    .word 0xdfb4597b
    .word 0x92ff075d
    .word 0x8ef10985
    .word 0x2e677232
    .word 0xe9bcf9c7
    .word 0x6e27e962
    .word 0xf00ca11e
    .word 0x9e0ae84b
    .word 0xa7b5615c
    .word 0xe0d3a5b7
    .word 0x43574e67
    .word 0x83c79a8f
    .word 0xaced7a9c
    .word 0x58f1aa8c
    .word 0x5448b8d2
    .word 0x2d647a25
    .word 0x6581779f
    .word 0xfea208d0
    .word 0x3c3e2eb1
    .word 0xe704db76
    .word 0xb1871179
    .word 0x5479ed50
    .word 0x750989f5
    .word 0x0646a028
    .word 0xa9fcc700
    .word 0x32bfe029
    .word 0x14d4f9eb
    .word 0xb98af3f1
    .word 0xab713e4e
    .word 0xefc617f9
    .word 0x22c2ac1d
    .word 0x68b93e66
    .word 0xe95d657e
    .word 0x4afd14c6
    .word 0x34902770
    .word 0xab45df98
    .word 0x0d075f7a
    .word 0x054956a4
    .word 0x55d6b2c4
    .word 0x622e7cad
    .word 0x5bd05460
    .word 0xebecf69a
    .word 0x45b5883e
    .word 0x9f677eca
    .word 0xef53eac6
    .word 0x23fb4959
    .word 0xf06b6393
    .word 0xc1191a07
    .word 0x3221ac86
    .word 0xc347eaec
    .word 0x7df481af
    .word 0xda6c8d5c
    .word 0xc9ff2305
    .word 0x6b45ce27
    .word 0xd8665545
    .word 0xf736b840
    .word 0x9d1f4e10
    .word 0xef097b97
    .word 0x60d39f11
    .word 0x83ffd2fb
    .word 0x83e11aad
    .word 0x066f376e
    .word 0x2fa7e242
    .word 0x3245ba24
    .word 0x1cafa017
    .word 0x6cd9b414
    .word 0x2419166e
    .word 0xc008cd20
    .word 0x42d1a43b
    .word 0x9825a796
    .word 0x63765e9c
    .word 0xbd1bb62c
    .word 0x6284b2af
    .word 0xebace5f6
    .word 0x5b4f7ec6
    .word 0x2bb4a691
    .word 0x2deeafc3
    .word 0xe10a37f5
    .word 0x2037bb64
    .word 0xc54756a7
    .word 0x6b98e38d
    .word 0x6eab5b95
    .word 0xdb65b2b2
    .word 0xb6df8c73
    .word 0x392700fe
    .word 0x219b8cd1
    .word 0xd28dde91
    .word 0xa1279aa3
    .word 0x973e95e1
    .word 0x39ffec8e
    .word 0x6dfea2cb
    .word 0x8422a6ef
    .word 0x0e307145
    .word 0x0c14f302
    .word 0xe30ad551
    .word 0x611983cd
    .word 0x27f4b67c
    .word 0x0246099d
    .word 0xd150d97f
    .word 0x1e75ced0
    .word 0x7f715b6d
    .word 0x418870ee
    .word 0xd71ca9ce
    .word 0x7522b3c8
    .word 0xcc1a6743
    .word 0x1bd69977
    .word 0xcd8356f7
    .word 0xb3cf1111
    .word 0xedfddda5
    .word 0x2d841462
    .word 0xb6ca8167
    .word 0xfefc11b1
    .word 0x9c96c3b9
    .word 0x55ac857c
    .word 0x929c31cf
    .word 0x36de6ae5
    .word 0xb5a0331b
    .word 0xdc84ea9e
    .word 0x919d74db
    .word 0xbdcfe72d
    .word 0x521edc66
    .word 0x9546e8dc
    .word 0x661dcb1c
    .word 0x78faf39f
    .word 0x57113b9f
    .word 0xf0ca0862
    .word 0xe2779f0d
    .word 0xc0997e91
    .word 0x737ab1cc
    .word 0xa27bd173
    .word 0x3d68d266
    .word 0xf6c8690c
    .word 0xb97fa47a
    .word 0xd9ee1598
    .word 0x9d8242b5
    .word 0x1737be9b
    .word 0xa080cfed
    .word 0x3f3bec9d
    .word 0x8802959a
    .word 0xeaa6f012
    .word 0x3a5d558e
    .word 0x7bb1c855
    .word 0xa5e61666
    .word 0x7e6b25eb
    .word 0x324bebde
    .word 0x4dcf2d63
    .word 0x793c6d32
    .word 0x7df6efce
    .word 0x464938a7
    .word 0x6617d2a7
    .word 0x585d2231
    .word 0x96b54f2c
    .word 0xea5ddad0
    .word 0x5f6f7b35
    .word 0x1ec9add7
    .word 0x743a2b1c
    .word 0x5bffa434
    .word 0x062e554c
    .word 0x7576a42f
    .word 0x4e1accdd
    .word 0x08cdb995
    .word 0x8e506c29
    .word 0xfc41296b
    .word 0x351bcad3
    .word 0xc18aecaa
    .word 0x6fcd0426
    .word 0xbed8c14d
    .word 0x984232ca
    .word 0x4351fa01
    .word 0xf0447f65
    .word 0xfd43a911
    .word 0xc7f300a4
    .word 0xf0ae37b4
    .word 0x775ff848
    .word 0xeb74ab27
    .word 0x900381b4
    .word 0x68c917d9
    .word 0x5de74544
    .word 0x6f95ca21
    .word 0xfb5076a2
    .word 0x93de5faf
    .word 0x38d458f5
    .word 0xf52d0ba6
    .word 0x86283583
    .word 0x9a76978c
    .word 0xc8d2352e
    .word 0xb6b50116
    .word 0x5e7f32b4
    .word 0x2e8cf070
    .word 0x6398ecda
    .word 0x1392eccc
    .word 0xcc064792
    .word 0xd8a44ebb
    .word 0xba10775f
    .word 0x64d9716b
    .word 0xd9acd5ac
    .word 0x9eb0fe37
    .word 0xdd7ceaef
    .word 0x3f251a8b
    .word 0x2708345a
    .word 0x1739bbfd
    .word 0xfe307a34
    .word 0x472b5259
    .word 0xb6fd4e47
    .word 0x67d9ad8f
    .word 0xa37ee739
    .word 0x440e250c
    .word 0x9c9bfe64
    .word 0xa98a5120
    .word 0x1f954183
    .word 0xf2a8224c
    .word 0xa77c032f

#include "frost_footer.S"
