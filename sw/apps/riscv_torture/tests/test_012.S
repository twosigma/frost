// Generated RV32IMAFDC torture test for Frost (seed=53)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xe3e01eda
    li x4, 0xb61e9f56
    li x5, 0x854368b8
    li x6, 0xbbdcf311
    li x7, 0xba605569
    li x8, 0xff39cf90
    li x9, 0xbf2e6b3f
    li x10, 0xbe10bc56
    li x11, 0x2b531ee0
    li x12, 0x5c388004
    li x13, 0x70dfe477
    li x14, 0x3a939b12
    li x15, 0x2360f9cb
    li x16, 0xa9078204
    li x17, 0x0e1a1471
    li x18, 0x47406491
    li x19, 0x699fc1c3
    li x20, 0xc6eac098
    li x21, 0xc247bcbb
    li x22, 0xd32eb077
    li x23, 0x24de43a3
    li x24, 0xac1d1aca
    li x25, 0x53eef1d1
    li x26, 0x3c220a6c
    li x27, 0x626542c6
    li x28, 0xebfaed98
    li x29, 0x89012a2e
    li x30, 0xa40c2766
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
    li x1, 0xa84d4525

    and x8, x18, x9
    slli x26, x23, 27
    or x5, x12, x7
    mulhu x29, x17, x22
    mulhu x12, x10, x9
    bltu x18, x18, _br_taken_0
    srl x16, x8, x29
    j _br_done_0
_br_taken_0:
    srl x16, x20, x13
_br_done_0:
    xor x13, x26, x16
    fmax.d f24, f23, f16
    slti x28, x30, 688
    srli x8, x29, 22
    xori x27, x30, -1882
    xori x20, x17, 1884
    or x24, x30, x9
    blt x4, x10, _br_taken_1
    or x11, x20, x27
    j _br_done_1
_br_taken_1:
    add x11, x19, x22
_br_done_1:
    addi x30, x31, 164
    amoadd.w x13, x11, (x30)
    addi x4, x19, 1156
    addi x24, x18, -984
    sub x15, x27, x16
    beq x27, x21, _br_taken_2
    or x4, x20, x16
    j _br_done_2
_br_taken_2:
    srl x4, x19, x23
_br_done_2:
    lh x15, 116(x31)
    sh x11, 116(x31)
    srl x18, x6, x22
    or x28, x4, x19
    xori x12, x7, -329
    srl x17, x16, x7
    slti x8, x20, -1208
    srai x7, x8, 17
    and x8, x21, x5
    xori x15, x5, -1278
    fmul.d f1, f23, f27
    fsub.d f7, f4, f29
    fmin.s f17, f11, f22
    fsub.s f6, f4, f21
    fmax.d f2, f1, f8
    xor x17, x15, x22
    sltiu x24, x17, 1166
    slli x14, x22, 2
    xor x25, x24, x27
    sll x5, x14, x14
    srli x18, x8, 29
    xor x16, x9, x14
    sll x4, x5, x30
    beq x14, x8, _br_taken_3
    slt x9, x21, x30
    j _br_done_3
_br_taken_3:
    sll x9, x13, x6
_br_done_3:
    and x6, x10, x13
    fadd.d f8, f23, f29
    fsub.s f23, f31, f17
    fmsub.s f16, f28, f1, f10
    blt x7, x6, _br_taken_4
    sll x24, x21, x19
    j _br_done_4
_br_taken_4:
    sll x24, x30, x12
_br_done_4:
    lbu x24, 104(x31)
    sb x16, 104(x31)
    fsub.d f7, f24, f28
    srai x26, x4, 22
    slli x14, x19, 8
    sltiu x29, x8, -570
    xori x12, x25, 1484
    sltu x5, x18, x13
    addi x16, x29, 1081
    sll x12, x26, x21
    sub x13, x29, x1
    xor x19, x20, x22
    sltiu x25, x24, -210
    mulhsu x27, x6, x11
    mulh x24, x1, x22
    srli x7, x6, 16
    addi x13, x31, 476
    amoswap.w x8, x15, (x13)
    blt x6, x9, _br_taken_5
    srl x9, x16, x4
    j _br_done_5
_br_taken_5:
    sub x9, x27, x14
_br_done_5:
    xori x6, x8, -453
    and x20, x29, x22
    sub x17, x8, x4
    xor x4, x13, x21
    ori x25, x4, 505
    add x14, x19, x21
    slli x18, x1, 25
    sll x18, x25, x15
    lb x12, 88(x31)
    sb x22, 88(x31)
    xor x5, x11, x22
    srai x5, x25, 22
    add x1, x24, x27
    lh x24, 532(x31)
    sh x9, 532(x31)
    lw x15, 408(x31)
    sw x9, 408(x31)
    or x13, x4, x28
    sltiu x5, x9, 1932
    sll x29, x27, x9
    beq x12, x11, _br_taken_6
    add x17, x21, x23
    j _br_done_6
_br_taken_6:
    add x17, x24, x5
_br_done_6:
    ori x14, x9, 662
    addi x28, x20, 1897
    sltiu x21, x22, 162
    addi x29, x26, -87
    xori x26, x19, 226
    addi x1, x31, 368
    amomax.w x28, x26, (x1)
    addi x21, x31, 780
    amoswap.w x26, x9, (x21)
    sltu x7, x8, x5
    blt x12, x19, _br_taken_7
    srl x14, x28, x22
    j _br_done_7
_br_taken_7:
    sra x14, x9, x4
_br_done_7:
    beq x22, x20, _br_taken_8
    slt x20, x5, x11
    j _br_done_8
_br_taken_8:
    srl x20, x5, x7
_br_done_8:
    or x6, x18, x21
    add x1, x20, x24
    and x19, x4, x18
    sub x9, x6, x16
    sltiu x29, x22, -344
    ori x19, x23, -1270
    srli x26, x11, 1
    srli x27, x24, 17
    bgeu x11, x27, _br_taken_9
    or x9, x8, x28
    j _br_done_9
_br_taken_9:
    add x9, x7, x28
_br_done_9:
    and x18, x25, x18
    sub x4, x14, x12
    ori x20, x7, -1360
    slt x10, x6, x7
    bge x13, x28, _br_taken_10
    sll x7, x19, x18
    j _br_done_10
_br_taken_10:
    and x7, x25, x22
_br_done_10:
    fsub.d f27, f29, f8
    fmin.s f2, f11, f28
    fmadd.s f29, f5, f24, f6
    fdiv.s f25, f18, f5
    bgeu x10, x15, _br_taken_11
    sltu x6, x15, x9
    j _br_done_11
_br_taken_11:
    sltu x6, x30, x11
_br_done_11:
    fmsub.d f26, f20, f7, f27
    fdiv.d f27, f9, f7
    bgeu x4, x1, _br_taken_12
    sra x16, x21, x25
    j _br_done_12
_br_taken_12:
    sltu x16, x9, x22
_br_done_12:
    sltiu x7, x24, 1827
    xor x22, x16, x27
    or x4, x13, x4
    lb x8, 784(x31)
    sb x26, 784(x31)
    xor x19, x17, x18
    addi x22, x5, -512
    slti x7, x13, 527
    and x29, x28, x13
    slt x10, x5, x18
    andi x7, x10, -230
    sltu x7, x8, x26
    remu x14, x10, x26
    xori x1, x8, -1319
    add x23, x23, x18
    xor x1, x24, x30
    bltu x1, x4, _br_taken_13
    slt x25, x30, x28
    j _br_done_13
_br_taken_13:
    xor x25, x28, x22
_br_done_13:
    mulhu x14, x25, x21
    sltu x13, x4, x30
    slt x27, x27, x5
    sltiu x8, x28, -1794
    sltu x12, x15, x12
    srai x17, x6, 5
    slt x11, x11, x1
    fmul.s f3, f4, f6
    fsub.s f24, f13, f29
    xor x6, x12, x18
    slli x4, x25, 8
    slti x18, x23, 271
    slli x8, x15, 25
    andi x8, x28, 294
    and x16, x11, x29
    bge x26, x12, _br_taken_14
    sub x23, x6, x11
    j _br_done_14
_br_taken_14:
    srl x23, x27, x22
_br_done_14:
    ori x28, x20, 1648
    slli x19, x5, 10
    fsub.d f24, f11, f14
    fmin.s f27, f7, f5
    bltu x13, x28, _br_taken_15
    slt x20, x23, x14
    j _br_done_15
_br_taken_15:
    sra x20, x29, x5
_br_done_15:
    lb x14, 244(x31)
    sb x29, 244(x31)
    sub x6, x6, x14
    xori x16, x1, -1558
    add x24, x30, x11
    ori x24, x18, -764
    srai x11, x21, 23
    slti x29, x15, -1212
    sub x10, x7, x22
    lhu x27, 628(x31)
    sh x5, 628(x31)
    bne x19, x5, _br_taken_16
    sra x6, x1, x24
    j _br_done_16
_br_taken_16:
    srl x6, x11, x18
_br_done_16:
    addi x5, x23, -1963
    andi x10, x17, 989
    sltu x24, x29, x17
    addi x18, x4, -1598
    sltiu x25, x11, 1290
    add x23, x10, x1
    beq x7, x28, _br_taken_17
    sltu x16, x11, x26
    j _br_done_17
_br_taken_17:
    sra x16, x17, x29
_br_done_17:
    beq x16, x23, _br_taken_18
    slt x4, x12, x6
    j _br_done_18
_br_taken_18:
    srl x4, x10, x16
_br_done_18:
    add x17, x6, x22
    slti x30, x18, 335
    and x4, x18, x29
    andi x19, x17, 1227
    sra x29, x22, x6
    srl x10, x15, x22
    srli x14, x29, 21
    sltu x23, x25, x21
    fmin.s f28, f10, f20
    sltu x24, x25, x27
    add x6, x4, x12
    slli x4, x12, 27
    bge x30, x12, _br_taken_19
    and x18, x16, x30
    j _br_done_19
_br_taken_19:
    srl x18, x5, x11
_br_done_19:
    sra x21, x7, x14
    srli x16, x25, 8
    or x16, x5, x15
    xori x26, x18, -1010
    lbu x15, 164(x31)
    sb x20, 164(x31)
    bltu x14, x4, _br_taken_20
    sub x4, x5, x28
    j _br_done_20
_br_taken_20:
    xor x4, x17, x14
_br_done_20:
    addi x29, x31, 516
    amominu.w x24, x30, (x29)
    srli x14, x24, 25
    sltu x22, x6, x25
    lh x29, 32(x31)
    sh x29, 32(x31)
    divu x11, x26, x6
    rem x4, x23, x23
    lw x7, 100(x31)
    sw x13, 100(x31)
    lw x16, 268(x31)
    sw x10, 268(x31)
    fmax.s f8, f0, f27
    fadd.s f24, f11, f19
    fmin.s f25, f3, f23
    bge x8, x18, _br_taken_21
    xor x12, x22, x17
    j _br_done_21
_br_taken_21:
    add x12, x25, x13
_br_done_21:
    and x29, x21, x30
    sltu x23, x20, x15
    sltu x14, x8, x26
    slli x9, x20, 16
    bgeu x16, x29, _br_taken_22
    sra x5, x12, x14
    j _br_done_22
_br_taken_22:
    sltu x5, x8, x13
_br_done_22:
    bgeu x25, x16, _br_taken_23
    sltu x11, x24, x26
    j _br_done_23
_br_taken_23:
    or x11, x23, x16
_br_done_23:
    sltiu x25, x25, -737
    ori x28, x17, -1591
    andi x22, x12, -836
    xori x15, x1, 314
    sra x21, x9, x25
    ori x8, x10, 739
    slti x30, x21, 790
    xor x17, x30, x5
    beq x24, x15, _br_taken_24
    sub x6, x5, x12
    j _br_done_24
_br_taken_24:
    sra x6, x27, x8
_br_done_24:
    blt x18, x30, _br_taken_25
    add x22, x12, x21
    j _br_done_25
_br_taken_25:
    add x22, x26, x17
_br_done_25:
    addi x18, x31, 896
    amoadd.w x8, x9, (x18)
    addi x6, x31, 648
    amoswap.w x5, x22, (x6)
    bge x30, x8, _br_taken_26
    sra x9, x15, x11
    j _br_done_26
_br_taken_26:
    sra x9, x10, x11
_br_done_26:
    bge x7, x18, _br_taken_27
    sub x10, x12, x14
    j _br_done_27
_br_taken_27:
    or x10, x4, x19
_br_done_27:
    and x4, x24, x18
    or x21, x17, x6
    fnmadd.s f17, f2, f16, f9
    lw x21, 980(x31)
    sw x13, 980(x31)
    sltu x20, x16, x10
    add x1, x7, x20
    remu x8, x8, x26
    mulhsu x28, x18, x17
    sltu x21, x28, x6
    bge x14, x17, _br_taken_28
    or x26, x26, x27
    j _br_done_28
_br_taken_28:
    and x26, x23, x13
_br_done_28:
    bne x5, x24, _br_taken_29
    srl x6, x21, x26
    j _br_done_29
_br_taken_29:
    srl x6, x17, x9
_br_done_29:
    xor x28, x11, x30
    beq x12, x13, _br_taken_30
    add x29, x29, x1
    j _br_done_30
_br_taken_30:
    add x29, x18, x13
_br_done_30:
    srli x15, x18, 4
    sll x13, x8, x15
    blt x28, x4, _br_taken_31
    sltu x14, x11, x26
    j _br_done_31
_br_taken_31:
    sltu x14, x8, x30
_br_done_31:
    blt x19, x26, _br_taken_32
    srl x20, x13, x26
    j _br_done_32
_br_taken_32:
    and x20, x26, x25
_br_done_32:
    beq x20, x19, _br_taken_33
    sub x17, x4, x10
    j _br_done_33
_br_taken_33:
    and x17, x12, x7
_br_done_33:
    slti x16, x15, 922
    andi x15, x16, 1556
    beq x25, x8, _br_taken_34
    srl x12, x29, x15
    j _br_done_34
_br_taken_34:
    add x12, x26, x21
_br_done_34:
    srl x10, x19, x5
    sub x23, x17, x23
    ori x15, x27, 494
    or x18, x10, x20
    xor x29, x27, x7
    bne x25, x26, _br_taken_35
    sub x30, x23, x30
    j _br_done_35
_br_taken_35:
    xor x30, x30, x18
_br_done_35:
    lbu x29, 752(x31)
    sb x28, 752(x31)
    xori x20, x11, -959
    sll x8, x13, x6
    add x13, x10, x20
    fsub.s f13, f3, f27
    srai x29, x21, 11
    ori x13, x22, 1636
    andi x4, x18, -614
    slti x5, x26, 160
    srai x21, x10, 1
    xori x28, x18, -1209
    fmax.s f2, f19, f10
    fdiv.s f31, f2, f20
    fmadd.s f13, f12, f13, f23
    addi x17, x31, 176
    amoand.w x30, x20, (x17)
    ori x17, x22, -1046
    addi x19, x17, 796
    xor x4, x1, x5
    bgeu x22, x26, _br_taken_36
    xor x29, x18, x1
    j _br_done_36
_br_taken_36:
    sra x29, x18, x11
_br_done_36:
    mul x22, x7, x25
    mul x24, x24, x23
    andi x20, x21, 1546
    fmin.s f18, f25, f3
    fdiv.d f9, f22, f27
    bge x21, x9, _br_taken_37
    or x8, x19, x30
    j _br_done_37
_br_taken_37:
    sra x8, x11, x17
_br_done_37:
    bgeu x16, x22, _br_taken_38
    and x26, x19, x29
    j _br_done_38
_br_taken_38:
    slt x26, x25, x25
_br_done_38:
    andi x4, x7, -363
    addi x11, x31, 636
    amoand.w x1, x10, (x11)
    bltu x11, x25, _br_taken_39
    and x17, x29, x16
    j _br_done_39
_br_taken_39:
    slt x17, x30, x29
_br_done_39:
    blt x6, x13, _br_taken_40
    slt x18, x8, x11
    j _br_done_40
_br_taken_40:
    and x18, x4, x6
_br_done_40:
    slt x19, x10, x15
    or x20, x26, x15
    fmul.s f30, f19, f3
    fadd.s f28, f5, f8
    addi x22, x9, 1266
    sub x27, x12, x1
    mulhsu x19, x8, x14
    mulhsu x18, x30, x14
    mulhu x5, x14, x25
    div x16, x14, x29
    and x8, x23, x28
    xori x9, x21, 1214
    bltu x25, x1, _br_taken_41
    sltu x13, x14, x10
    j _br_done_41
_br_taken_41:
    and x13, x27, x7
_br_done_41:
    addi x29, x31, 272
    amomin.w x13, x21, (x29)
    slt x1, x17, x24
    ori x21, x10, 1024
    bltu x18, x14, _br_taken_42
    or x14, x28, x10
    j _br_done_42
_br_taken_42:
    and x14, x12, x14
_br_done_42:
    slti x25, x21, 1967
    sll x5, x12, x11
    bltu x9, x27, _br_taken_43
    sltu x30, x4, x4
    j _br_done_43
_br_taken_43:
    sra x30, x22, x23
_br_done_43:
    ori x22, x24, 278
    ori x8, x19, -1554
    and x18, x20, x29
    xori x22, x15, -55
    slti x12, x25, 1688
    sltiu x13, x4, -474
    lbu x16, 728(x31)
    sb x29, 728(x31)
    addi x6, x31, 928
    amomax.w x4, x17, (x6)
    slli x24, x12, 3
    sll x1, x24, x28
    xori x14, x23, -1927
    fmsub.s f10, f19, f15, f1
    fmax.s f26, f22, f15
    fmax.s f7, f29, f25
    sub x10, x9, x10
    xori x14, x19, -1487
    sll x8, x14, x19
    andi x25, x4, -545
    and x12, x22, x29
    slt x6, x23, x12
    or x10, x28, x11
    slt x12, x20, x26
    xor x6, x22, x15
    sltu x19, x4, x18
    or x27, x22, x4
    sltiu x9, x14, -1156
    add x17, x10, x10
    lhu x22, 88(x31)
    sh x6, 88(x31)
    or x6, x11, x14
    remu x24, x21, x12
    mulhu x22, x9, x5
    and x5, x30, x7
    and x29, x15, x27
    sll x6, x25, x21
    slli x14, x25, 12
    fdiv.s f24, f12, f10
    fsub.d f19, f0, f20
    xori x8, x22, -1475
    slti x9, x16, -477
    slti x27, x14, -880

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xe2ff7664526b5498
    .dword 0x04d123cc5cb11127
    .dword 0x81c96f1f5e89580a
    .dword 0x1a03190f6e15462f
    .dword 0x2a7abea15d44fe7c
    .dword 0xe00a46012bff8453
    .dword 0x99fc5ae20893c052
    .dword 0xc9480d5ed80f9f90
    .dword 0x8547a0ef1d833070
    .dword 0x6fa68b6686a5ecaf
    .dword 0xa92d06843ad18710
    .dword 0x31a609343c97dda5
    .dword 0x15b30388cadf10ad
    .dword 0xf67626126ccadadb
    .dword 0x1fabcee68052466e
    .dword 0x5f726d4120d97f3e
    .dword 0xf01e5dcce377bd76
    .dword 0x2ae08fec6084e408
    .dword 0x44019add12d26bd5
    .dword 0x8d8bc140b627ff84
    .dword 0xf929a47b97dfce02
    .dword 0x116f652c3b52f48c
    .dword 0x9083da7521533b90
    .dword 0x87939ae89cbf8daf
    .dword 0x18e2bd68228c9c5d
    .dword 0x82e1114444069f01
    .dword 0xaae5583e4deab004
    .dword 0x2dbee284e13c06b3
    .dword 0x8ea8567a54193c02
    .dword 0x69526284f64052a1
    .dword 0x0e34842db8678de3
    .dword 0x4b3fb9649f175971

    .align 2
_torture_data:
    .word 0x756e76e9
    .word 0x5b95ac46
    .word 0xdd2229f7
    .word 0xe1ef3637
    .word 0xbf00f77e
    .word 0x964bd071
    .word 0xbd325a6d
    .word 0xa92e5caf
    .word 0x47dc3333
    .word 0x95a778ac
    .word 0x8b1fa91b
    .word 0x57b7c97c
    .word 0xf140586e
    .word 0x72137d28
    .word 0x12b2ebac
    .word 0x4a024492
    .word 0x12c9df56
    .word 0x4ba3ebe3
    .word 0xc651130d
    .word 0x8e852461
    .word 0x0ea9c29e
    .word 0xa06005eb
    .word 0x1780b3f1
    .word 0xa5fa96cc
    .word 0x56e829bd
    .word 0x7bfc8b6e
    .word 0x32ea64ca
    .word 0x5a37ad12
    .word 0x55307f9b
    .word 0x93293943
    .word 0x506a4d7f
    .word 0x6c547528
    .word 0x60351079
    .word 0x24b6ec0b
    .word 0xb98b993c
    .word 0x32ffda35
    .word 0x2cf9feda
    .word 0x6ab2cb45
    .word 0x8a162241
    .word 0x732ab505
    .word 0xae76e99e
    .word 0x3846e9e0
    .word 0xce4fc39c
    .word 0x049480f7
    .word 0x9a397d63
    .word 0x8c1b1cb3
    .word 0x75809a36
    .word 0x9be494a0
    .word 0x965752eb
    .word 0x077e3b41
    .word 0xf027e0d0
    .word 0x649a99e5
    .word 0xbfb98f64
    .word 0x4bc9a07d
    .word 0x0d80fdd4
    .word 0x5c7e177d
    .word 0xf3d3a922
    .word 0x2536f777
    .word 0xbdcd7cee
    .word 0x75acf4ad
    .word 0xe04de94f
    .word 0x81380ec5
    .word 0x5c21f8fe
    .word 0x322a0662
    .word 0x78be8629
    .word 0x5a959854
    .word 0x66719891
    .word 0x4c230e84
    .word 0x474fa208
    .word 0xef60c9b4
    .word 0x35d53127
    .word 0x2ff40213
    .word 0x472cebb3
    .word 0x5a558d2c
    .word 0x82f3083f
    .word 0x79dbc92e
    .word 0xfa2230ed
    .word 0x95024aff
    .word 0x01aa5a44
    .word 0x49a623b0
    .word 0x10065393
    .word 0xef157d11
    .word 0x1451610b
    .word 0xba70c5e6
    .word 0xc053f431
    .word 0x66c4adeb
    .word 0x0bb285a7
    .word 0x892ce123
    .word 0xf3d69826
    .word 0x3ab4a03a
    .word 0x00ba9fc2
    .word 0xb32f85c5
    .word 0x370229d3
    .word 0x4fe4e919
    .word 0xa9b8b18b
    .word 0xaad2b842
    .word 0x4d395c9d
    .word 0xa73ed58c
    .word 0xe3ff4926
    .word 0x504e267c
    .word 0x9fe6bee6
    .word 0xc452d67e
    .word 0x1c11e706
    .word 0xdf8490e5
    .word 0x442fdbe9
    .word 0xeba2343c
    .word 0xb6d812b0
    .word 0x7e48ec15
    .word 0x70e5c6a9
    .word 0x5c9b31d2
    .word 0x2065acfa
    .word 0x37c058fa
    .word 0x3e07d267
    .word 0x741a97df
    .word 0x8a815245
    .word 0x250ec41e
    .word 0xc53511df
    .word 0x347537d4
    .word 0x3d91317e
    .word 0x93215796
    .word 0x4ad5a52e
    .word 0xb911d5d0
    .word 0x39eb5b37
    .word 0x82b97f29
    .word 0x67eec94e
    .word 0xf4d79791
    .word 0xe5171255
    .word 0xd8c157d9
    .word 0xe68efe9d
    .word 0x426c3cb3
    .word 0x03e49704
    .word 0xddac4d83
    .word 0x3e17cfa4
    .word 0xe990a5be
    .word 0x623370d0
    .word 0xaee62474
    .word 0x55c366c3
    .word 0x45fe7864
    .word 0x24d83c57
    .word 0x5fe14535
    .word 0xc00bf6df
    .word 0xa9f6b606
    .word 0x2575e6b4
    .word 0xb1cc9a5f
    .word 0x7dcc618a
    .word 0xe4d65a43
    .word 0x670701cb
    .word 0x69991683
    .word 0xac9298bd
    .word 0x6f9d779b
    .word 0x93423df9
    .word 0x118a0849
    .word 0x856f6e4e
    .word 0xee769ff6
    .word 0x420032d2
    .word 0xdb98b994
    .word 0x43af9428
    .word 0x0333eef8
    .word 0x4a4e5fa1
    .word 0xff993b34
    .word 0xe0e9624d
    .word 0xf66e6eb4
    .word 0xb7ef7345
    .word 0x41a61e7c
    .word 0x58ed4fde
    .word 0xe795818e
    .word 0x7339c480
    .word 0x3d245150
    .word 0x117032aa
    .word 0xe7ecf39f
    .word 0xd5bb9b30
    .word 0x50c09ec1
    .word 0xcbbd8da3
    .word 0xd55b0de1
    .word 0x60c73194
    .word 0x102bdf10
    .word 0xe4bcf444
    .word 0xad3debc7
    .word 0xbd6e280c
    .word 0xf80c7dd7
    .word 0xadb503e7
    .word 0x60c104d4
    .word 0x91257edb
    .word 0x586404f5
    .word 0xda07416d
    .word 0x3f94e5ce
    .word 0x225f79c9
    .word 0xdad975ba
    .word 0xe9a722ba
    .word 0xc68958e8
    .word 0x2af1ed74
    .word 0x3ea11aaf
    .word 0x6331d810
    .word 0x48fa1fb4
    .word 0x18b07602
    .word 0xe9eb8c6f
    .word 0xe0cd4b2e
    .word 0x35129b62
    .word 0xe519bf6e
    .word 0x6a166a40
    .word 0x398720c0
    .word 0x102a6d68
    .word 0xc55914f8
    .word 0x4a90a220
    .word 0x3d21d7c7
    .word 0x8bdd38d3
    .word 0x95be9732
    .word 0xa913902c
    .word 0x5c556f68
    .word 0x210e277e
    .word 0xd5ab5d40
    .word 0x6ff64fa8
    .word 0x71ec15cf
    .word 0xb4222632
    .word 0x05de325e
    .word 0x821a23a7
    .word 0x5f758f4c
    .word 0x8c56b1b9
    .word 0x3b4a43d3
    .word 0x4da36b5a
    .word 0x8f240375
    .word 0x48146f41
    .word 0xdecc7830
    .word 0xec463cb4
    .word 0xc3cc34ca
    .word 0x31bb9258
    .word 0xe1ac38e8
    .word 0xabb20fc0
    .word 0xf975d389
    .word 0x44788c77
    .word 0xf3fb0c90
    .word 0xc68d5bbc
    .word 0xadacd180
    .word 0xe4b22e7c
    .word 0x32efc49e
    .word 0x0592e89a
    .word 0x754df1f1
    .word 0x77bae590
    .word 0x7caf423a
    .word 0x881d50c1
    .word 0xf608c24b
    .word 0x55401fa2
    .word 0xd3c1e6d9
    .word 0xdc5142b3
    .word 0xd0f8cbc7
    .word 0xc6582e3c
    .word 0x4b4b4424
    .word 0xd7b26714
    .word 0x09ca3f4e
    .word 0x737745a4
    .word 0x0b709875
    .word 0x0221dee2
    .word 0x11340ff0
    .word 0x5c0faa46
    .word 0x0f27adc1
    .word 0x64e9d806

#include "frost_footer.S"
