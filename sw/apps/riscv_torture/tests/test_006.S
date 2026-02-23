// Generated RV32IMAFDC torture test for Frost (seed=47)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x5a1298a1
    li x4, 0x57eda214
    li x5, 0x832f8dd1
    li x6, 0x1a3a8bee
    li x7, 0x8bf3baeb
    li x8, 0xe613b789
    li x9, 0x914c2672
    li x10, 0x3ae45b70
    li x11, 0x5becce23
    li x12, 0xf52fff01
    li x13, 0xb006a47f
    li x14, 0x99d9898d
    li x15, 0xc30bc4be
    li x16, 0x09080a3a
    li x17, 0x557c4f42
    li x18, 0x40b9c361
    li x19, 0xe190892f
    li x20, 0xd87aeb24
    li x21, 0x37f32628
    li x22, 0xbe828386
    li x23, 0xc5e83911
    li x24, 0x9acaae63
    li x25, 0x42f78aa5
    li x26, 0x0a44a2d0
    li x27, 0xc79814d5
    li x28, 0xccb38b89
    li x29, 0x9b396a65
    li x30, 0x35039b58
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
    li x1, 0x7c43186c

    addi x8, x31, 28
    amomaxu.w x7, x17, (x8)
    lbu x5, 168(x31)
    sb x11, 168(x31)
    bge x14, x27, _br_taken_0
    sltu x4, x11, x23
    j _br_done_0
_br_taken_0:
    sltu x4, x19, x24
_br_done_0:
    mul x21, x10, x9
    divu x16, x30, x25
    srli x6, x7, 22
    slli x11, x17, 0
    bge x5, x14, _br_taken_1
    sra x1, x4, x7
    j _br_done_1
_br_taken_1:
    sll x1, x26, x19
_br_done_1:
    fmin.s f29, f0, f4
    ori x23, x30, -1666
    fadd.s f5, f19, f3
    fmin.d f9, f17, f5
    fadd.s f7, f26, f26
    slti x22, x7, -1528
    slli x17, x23, 29
    fadd.s f18, f31, f7
    fmul.s f10, f29, f1
    lb x17, 940(x31)
    sb x11, 940(x31)
    addi x4, x31, 584
    amoor.w x29, x24, (x4)
    bltu x18, x15, _br_taken_2
    sub x5, x19, x25
    j _br_done_2
_br_taken_2:
    sltu x5, x22, x18
_br_done_2:
    lh x21, 740(x31)
    sh x12, 740(x31)
    beq x6, x19, _br_taken_3
    sra x28, x15, x13
    j _br_done_3
_br_taken_3:
    slt x28, x29, x14
_br_done_3:
    fmul.s f3, f22, f3
    div x9, x12, x9
    remu x30, x24, x29
    fmul.s f3, f9, f30
    fdiv.d f28, f16, f18
    xori x13, x18, 1441
    addi x13, x31, 536
    amomaxu.w x21, x19, (x13)
    lbu x30, 776(x31)
    sb x22, 776(x31)
    bne x24, x25, _br_taken_4
    add x15, x8, x22
    j _br_done_4
_br_taken_4:
    sll x15, x22, x5
_br_done_4:
    sll x22, x15, x1
    bgeu x5, x20, _br_taken_5
    add x15, x15, x18
    j _br_done_5
_br_taken_5:
    xor x15, x23, x14
_br_done_5:
    bltu x15, x6, _br_taken_6
    or x5, x16, x20
    j _br_done_6
_br_taken_6:
    sub x5, x30, x22
_br_done_6:
    xor x22, x29, x5
    slt x13, x16, x26
    ori x15, x30, -1437
    ori x23, x23, -1190
    sub x14, x1, x15
    slli x22, x10, 13
    lw x19, 624(x31)
    sw x22, 624(x31)
    div x26, x8, x18
    bge x22, x18, _br_taken_7
    sltu x1, x30, x15
    j _br_done_7
_br_taken_7:
    sltu x1, x10, x23
_br_done_7:
    addi x13, x31, 216
    amomin.w x28, x28, (x13)
    sll x5, x7, x19
    sll x5, x5, x7
    ori x6, x16, 367
    lw x24, 448(x31)
    sw x14, 448(x31)
    beq x4, x9, _br_taken_8
    slt x28, x7, x13
    j _br_done_8
_br_taken_8:
    sub x28, x29, x13
_br_done_8:
    bgeu x16, x19, _br_taken_9
    sltu x20, x27, x27
    j _br_done_9
_br_taken_9:
    and x20, x28, x19
_br_done_9:
    lhu x16, 896(x31)
    sh x24, 896(x31)
    or x6, x17, x27
    slli x30, x13, 27
    beq x13, x28, _br_taken_10
    sll x27, x29, x24
    j _br_done_10
_br_taken_10:
    or x27, x18, x26
_br_done_10:
    mulh x10, x9, x23
    mul x20, x18, x13
    div x5, x4, x26
    fmax.d f0, f16, f22
    fmul.s f23, f8, f12
    fmax.s f19, f19, f26
    xor x11, x4, x26
    slti x10, x11, 1274
    or x14, x19, x5
    ori x17, x30, -1493
    slli x18, x11, 4
    srai x10, x16, 30
    blt x1, x6, _br_taken_11
    sltu x22, x29, x1
    j _br_done_11
_br_taken_11:
    sra x22, x20, x9
_br_done_11:
    lh x9, 964(x31)
    sh x13, 964(x31)
    bltu x16, x13, _br_taken_12
    slt x28, x14, x1
    j _br_done_12
_br_taken_12:
    sub x28, x1, x12
_br_done_12:
    bltu x9, x29, _br_taken_13
    slt x29, x30, x22
    j _br_done_13
_br_taken_13:
    add x29, x4, x30
_br_done_13:
    lh x15, 100(x31)
    sh x27, 100(x31)
    xori x19, x14, -1739
    andi x22, x25, 501
    and x26, x5, x11
    xori x14, x6, 1043
    sltu x24, x21, x28
    srai x7, x20, 14
    or x21, x26, x7
    or x20, x23, x17
    add x21, x10, x29
    srli x5, x1, 8
    sll x22, x30, x12
    lh x20, 856(x31)
    sh x26, 856(x31)
    srli x10, x30, 7
    sra x22, x18, x28
    slti x29, x30, 485
    addi x16, x28, 1944
    or x13, x14, x20
    or x4, x22, x27
    srli x17, x15, 6
    fnmadd.d f9, f0, f16, f22
    fdiv.d f30, f20, f9
    fdiv.d f7, f13, f11
    bne x12, x24, _br_taken_14
    xor x10, x25, x27
    j _br_done_14
_br_taken_14:
    slt x10, x13, x7
_br_done_14:
    mulh x7, x8, x21
    mulhu x20, x30, x21
    blt x23, x28, _br_taken_15
    slt x23, x9, x28
    j _br_done_15
_br_taken_15:
    srl x23, x4, x14
_br_done_15:
    remu x22, x26, x26
    add x18, x13, x20
    div x6, x7, x30
    bltu x26, x21, _br_taken_16
    srl x24, x11, x22
    j _br_done_16
_br_taken_16:
    or x24, x30, x6
_br_done_16:
    and x23, x20, x10
    sltu x24, x25, x23
    srai x12, x17, 20
    bne x21, x8, _br_taken_17
    sra x30, x13, x11
    j _br_done_17
_br_taken_17:
    sub x30, x12, x9
_br_done_17:
    srai x9, x24, 31
    or x23, x1, x23
    bltu x7, x6, _br_taken_18
    sra x16, x10, x30
    j _br_done_18
_br_taken_18:
    or x16, x27, x9
_br_done_18:
    srai x20, x5, 26
    and x6, x5, x25
    srl x27, x6, x23
    sltu x25, x18, x28
    add x13, x12, x28
    xori x11, x27, -1562
    sltiu x19, x18, 273
    slt x10, x22, x24
    fsub.s f11, f12, f15
    fnmadd.s f18, f12, f21, f21
    fmul.s f23, f11, f10
    bge x5, x4, _br_taken_19
    xor x15, x25, x17
    j _br_done_19
_br_taken_19:
    sra x15, x22, x6
_br_done_19:
    bgeu x18, x28, _br_taken_20
    sra x23, x13, x12
    j _br_done_20
_br_taken_20:
    srl x23, x29, x29
_br_done_20:
    mulh x11, x22, x15
    divu x17, x12, x8
    sra x4, x9, x25
    addi x14, x1, 281
    srai x17, x17, 3
    slli x26, x7, 25
    xor x20, x19, x6
    lb x20, 916(x31)
    sb x18, 916(x31)
    addi x9, x31, 652
    amoor.w x11, x24, (x9)
    lbu x19, 1008(x31)
    sb x28, 1008(x31)
    srai x27, x11, 14
    sll x10, x25, x26
    fadd.s f20, f13, f20
    fnmadd.s f10, f17, f23, f8
    fmsub.s f3, f11, f6, f18
    xor x11, x6, x12
    xor x22, x26, x7
    bne x10, x25, _br_taken_21
    srl x20, x22, x12
    j _br_done_21
_br_taken_21:
    sra x20, x24, x26
_br_done_21:
    fsub.s f1, f27, f11
    fsub.d f28, f0, f23
    bge x19, x8, _br_taken_22
    sll x28, x8, x22
    j _br_done_22
_br_taken_22:
    add x28, x9, x13
_br_done_22:
    bgeu x12, x26, _br_taken_23
    sub x11, x12, x10
    j _br_done_23
_br_taken_23:
    add x11, x20, x18
_br_done_23:
    mulhu x12, x29, x17
    mulhsu x8, x20, x12
    blt x12, x22, _br_taken_24
    add x26, x29, x12
    j _br_done_24
_br_taken_24:
    add x26, x24, x30
_br_done_24:
    slt x16, x7, x15
    slt x10, x19, x20
    xor x20, x29, x8
    slli x15, x16, 8
    or x10, x10, x1
    xori x30, x20, 433
    addi x10, x31, 100
    amoor.w x11, x5, (x10)
    xor x11, x11, x27
    srai x29, x4, 16
    sra x8, x15, x11
    srai x19, x11, 10
    sll x11, x18, x6
    srl x10, x28, x27
    slli x12, x19, 9
    addi x6, x31, 64
    amomax.w x27, x12, (x6)
    fsub.s f31, f24, f19
    fnmadd.s f23, f26, f6, f5
    fmin.s f14, f8, f15
    bge x20, x25, _br_taken_25
    srl x23, x27, x4
    j _br_done_25
_br_taken_25:
    sll x23, x1, x21
_br_done_25:
    fsub.d f15, f31, f23
    fdiv.d f11, f29, f14
    srl x16, x27, x1
    slt x5, x18, x9
    xor x19, x1, x29
    andi x18, x13, 462
    sltiu x25, x25, 1028
    bgeu x4, x9, _br_taken_26
    xor x9, x21, x17
    j _br_done_26
_br_taken_26:
    xor x9, x30, x15
_br_done_26:
    lw x16, 284(x31)
    sw x14, 284(x31)
    blt x20, x26, _br_taken_27
    sltu x6, x14, x29
    j _br_done_27
_br_taken_27:
    slt x6, x30, x15
_br_done_27:
    addi x9, x4, 96
    bne x14, x22, _br_taken_28
    srl x14, x21, x21
    j _br_done_28
_br_taken_28:
    slt x14, x28, x30
_br_done_28:
    mulh x7, x14, x30
    xori x27, x29, 168
    sltiu x7, x10, 591
    slt x26, x25, x11
    slt x11, x20, x11
    sltu x17, x7, x14
    add x15, x18, x9
    bltu x24, x21, _br_taken_29
    and x8, x4, x20
    j _br_done_29
_br_taken_29:
    sll x8, x20, x10
_br_done_29:
    xor x25, x25, x30
    srai x19, x21, 20
    lw x26, 792(x31)
    sw x17, 792(x31)
    bne x9, x28, _br_taken_30
    add x13, x21, x19
    j _br_done_30
_br_taken_30:
    srl x13, x20, x30
_br_done_30:
    xori x23, x18, 1524
    addi x8, x21, 1459
    addi x22, x25, -1214
    addi x28, x20, -1064
    sub x27, x26, x24
    xor x1, x11, x21
    sra x14, x17, x4
    addi x16, x23, -1377
    bgeu x9, x14, _br_taken_31
    srl x9, x26, x21
    j _br_done_31
_br_taken_31:
    sll x9, x9, x18
_br_done_31:
    lb x12, 216(x31)
    sb x27, 216(x31)
    bge x9, x4, _br_taken_32
    slt x7, x27, x11
    j _br_done_32
_br_taken_32:
    sll x7, x11, x14
_br_done_32:
    sltiu x14, x7, -874
    xori x21, x28, 553
    bltu x29, x27, _br_taken_33
    add x15, x6, x16
    j _br_done_33
_br_taken_33:
    sll x15, x24, x30
_br_done_33:
    sub x28, x30, x9
    slli x5, x29, 30
    beq x6, x8, _br_taken_34
    sll x13, x25, x7
    j _br_done_34
_br_taken_34:
    sra x13, x10, x7
_br_done_34:
    slt x1, x5, x10
    bltu x16, x19, _br_taken_35
    sltu x23, x5, x27
    j _br_done_35
_br_taken_35:
    and x23, x10, x14
_br_done_35:
    add x8, x4, x19
    ori x4, x14, 13
    srli x19, x28, 10
    slti x10, x28, 78
    addi x13, x22, 1286
    sra x13, x25, x6
    slti x15, x21, 704
    sra x24, x17, x10
    srl x4, x13, x4
    srai x5, x6, 17
    xor x17, x27, x7
    bgeu x1, x21, _br_taken_36
    sra x13, x21, x4
    j _br_done_36
_br_taken_36:
    sra x13, x14, x29
_br_done_36:
    slli x26, x11, 5
    addi x22, x31, 696
    amomaxu.w x19, x17, (x22)
    or x21, x24, x11
    srl x28, x27, x4
    xori x18, x10, -312
    andi x28, x21, -306
    lh x11, 656(x31)
    sh x7, 656(x31)
    srli x22, x6, 25
    add x25, x28, x25
    andi x26, x8, -1978
    bltu x12, x30, _br_taken_37
    sra x21, x24, x16
    j _br_done_37
_br_taken_37:
    sltu x21, x21, x14
_br_done_37:
    and x15, x29, x28
    ori x24, x26, -315
    addi x17, x7, 834
    slli x5, x5, 26
    fsub.s f10, f28, f4
    fdiv.d f12, f31, f4
    fadd.s f1, f20, f12
    xori x14, x10, -1157
    xor x28, x26, x28
    xori x16, x18, -1766
    sltu x27, x26, x20
    fadd.s f8, f11, f11
    srl x1, x19, x30
    add x26, x13, x26
    or x30, x28, x26
    fmax.s f10, f27, f0
    fmsub.d f26, f23, f1, f0
    lw x12, 416(x31)
    sw x29, 416(x31)
    xori x8, x30, 583
    ori x28, x20, -223
    srai x22, x17, 28
    fmax.s f6, f25, f3
    add x6, x11, x13
    ori x30, x1, 789
    srl x8, x13, x10
    srli x28, x22, 26
    xor x21, x8, x27
    sltu x19, x29, x20
    slt x23, x20, x20
    or x27, x26, x4
    slti x10, x28, -377
    or x21, x9, x18
    sltu x19, x29, x30
    addi x19, x21, 690
    ori x14, x23, 1716
    beq x21, x22, _br_taken_38
    sub x8, x9, x5
    j _br_done_38
_br_taken_38:
    sra x8, x21, x11
_br_done_38:
    sub x19, x19, x27
    xori x11, x27, 846
    srli x18, x27, 8
    bltu x20, x7, _br_taken_39
    sra x12, x4, x22
    j _br_done_39
_br_taken_39:
    or x12, x14, x20
_br_done_39:
    addi x20, x31, 900
    amominu.w x25, x22, (x20)
    fmul.d f24, f10, f12
    fdiv.s f29, f3, f18
    fmax.s f19, f23, f15
    fnmadd.s f20, f26, f5, f13
    mulhu x13, x6, x20
    mulhu x28, x27, x18
    bne x5, x18, _br_taken_40
    srl x4, x30, x5
    j _br_done_40
_br_taken_40:
    and x4, x4, x17
_br_done_40:
    slli x18, x28, 13
    sll x5, x30, x9
    sltu x28, x26, x24
    fdiv.s f2, f10, f12
    fmax.s f21, f5, f17
    lw x30, 908(x31)
    sw x16, 908(x31)
    srli x24, x27, 24
    sltu x8, x26, x21
    fmin.d f12, f12, f5
    fsub.s f0, f9, f15
    bge x5, x19, _br_taken_41
    slt x27, x4, x28
    j _br_done_41
_br_taken_41:
    sltu x27, x22, x28
_br_done_41:
    and x12, x29, x15
    sra x12, x12, x18
    slli x29, x26, 20
    fadd.d f0, f1, f31
    fmul.s f27, f21, f8
    fmax.s f6, f23, f13
    andi x22, x14, 537
    srl x30, x8, x30
    remu x14, x22, x12
    xori x6, x29, -1081
    add x1, x9, x15
    slti x6, x4, -105
    addi x9, x5, 1442
    srl x10, x21, x29
    sub x8, x28, x12
    or x24, x21, x28
    slt x8, x7, x24
    sub x7, x20, x24
    slli x10, x22, 19
    sll x23, x19, x17
    beq x8, x25, _br_taken_42
    slt x26, x4, x7
    j _br_done_42
_br_taken_42:
    xor x26, x28, x22
_br_done_42:
    xori x17, x19, 1309
    sltiu x16, x19, -163
    andi x8, x16, -1132
    srl x15, x25, x29
    addi x7, x5, -573
    divu x23, x16, x12
    mul x17, x16, x30
    bgeu x26, x27, _br_taken_43
    add x20, x1, x25
    j _br_done_43
_br_taken_43:
    add x20, x22, x6
_br_done_43:
    sltiu x10, x1, -874
    slt x18, x1, x5
    sltiu x22, x28, 127
    mulhsu x9, x9, x28
    divu x30, x25, x27
    slti x6, x1, 1772
    addi x4, x18, 1715
    sub x21, x15, x13
    srli x30, x12, 26
    slti x21, x10, 376
    ori x28, x15, 510

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x00ca066f71668839
    .dword 0x5bc02ff09d15a2b0
    .dword 0x1e626a13dae6b127
    .dword 0x7bc773efb1d04175
    .dword 0xfd4893ad19719b59
    .dword 0x65b4b5ff00e3ee47
    .dword 0x86f5bcdbc4979205
    .dword 0x3f3471218a39bbdf
    .dword 0x0efb38b00843374e
    .dword 0x9bc5f16f20710375
    .dword 0x197d44f24cb9cd22
    .dword 0x1cdd683b6b36b6e2
    .dword 0x643ff220a04f2f25
    .dword 0x2f42cc7acc1b04e1
    .dword 0xfed4afc4c7a18ab1
    .dword 0x49824efaaf6830fa
    .dword 0xe1f6774308420a66
    .dword 0x0630f7685705ab52
    .dword 0xaac09b6cec0dcdab
    .dword 0xab0a877a2d1a6b46
    .dword 0x017377c897a017d0
    .dword 0xbb7159715f9c1432
    .dword 0x910c83e3336b5a68
    .dword 0xaa0fac1fbdc8786f
    .dword 0x5f455d5666158b1a
    .dword 0xe4700f76f264c681
    .dword 0x2b15ee396500df20
    .dword 0x9e74d9e9f99a2d6b
    .dword 0x89f5e23662f6a5d7
    .dword 0x0940aa1f5327df54
    .dword 0x622fb435c7eaa9ec
    .dword 0x6336859839eb55d5

    .align 2
_torture_data:
    .word 0x5ec250bc
    .word 0x1ff53ab0
    .word 0xd6c4c0ba
    .word 0x6592058f
    .word 0x5e8c5b9f
    .word 0x5d221c4e
    .word 0xf019d1a1
    .word 0xaf596b2f
    .word 0x804a99c3
    .word 0x070528ad
    .word 0xf7c2a8ec
    .word 0x7c5cdee8
    .word 0x9db3c196
    .word 0xdc64b63c
    .word 0xc18d7b59
    .word 0x6d8bc09a
    .word 0xec0d7b23
    .word 0xd2c7bbbf
    .word 0x6141f09e
    .word 0x3f65f38d
    .word 0xb777053a
    .word 0x61378e28
    .word 0x5e8565ce
    .word 0xb4919690
    .word 0x3bf0b871
    .word 0x1d6307bf
    .word 0x552dc309
    .word 0xbaa461b8
    .word 0x9137f166
    .word 0x47f9cec3
    .word 0xff7a1ccf
    .word 0x5ce48799
    .word 0xd79fa3fc
    .word 0xefc981bd
    .word 0x3bfc5735
    .word 0x423014ab
    .word 0xb9f7af57
    .word 0x8d0f1afc
    .word 0xe9791e44
    .word 0x650e4b58
    .word 0x4545bf56
    .word 0x1c232b16
    .word 0xfdfe030f
    .word 0x26797a96
    .word 0x2bd963f8
    .word 0xdba5e722
    .word 0xaf61d07b
    .word 0x509a3199
    .word 0x39307fdb
    .word 0x4b4b4044
    .word 0xef310961
    .word 0x26e55380
    .word 0xad205497
    .word 0xe9b4e8c7
    .word 0xac2c5989
    .word 0xe17cd1ff
    .word 0xf5d01204
    .word 0x60de9b40
    .word 0xdc62a6ea
    .word 0x03bea518
    .word 0xcf35c890
    .word 0x1279a4b6
    .word 0xc01d9d00
    .word 0x2befe5ea
    .word 0xb3a52d6f
    .word 0x71348f6b
    .word 0x62944b59
    .word 0xd7c024ed
    .word 0x4859621d
    .word 0xa68e9a3c
    .word 0x7fd5aade
    .word 0x33f482d2
    .word 0x6faaaab1
    .word 0xa7d09902
    .word 0x71763295
    .word 0x51749b7d
    .word 0xcd3e1fc7
    .word 0x8d048cf2
    .word 0x42dd9b04
    .word 0xc100ad98
    .word 0x66728913
    .word 0x808046f9
    .word 0xc2c025f3
    .word 0x9a6c3eed
    .word 0x92007eb7
    .word 0xf6217be9
    .word 0x51beba8f
    .word 0x729ab14e
    .word 0xe138c5b4
    .word 0x4507a576
    .word 0xb399c55c
    .word 0xaea8e6fa
    .word 0x8c8174a6
    .word 0xd3fdde28
    .word 0xf34978d3
    .word 0xf1226ceb
    .word 0xa2a3ad0f
    .word 0x71556f3a
    .word 0xe7339b68
    .word 0xffd2330f
    .word 0x72c5f45d
    .word 0x3a5bae31
    .word 0x840dd71b
    .word 0x4b8f0c51
    .word 0x2f774dfc
    .word 0xb0b6b045
    .word 0xb5d5b557
    .word 0xc37de538
    .word 0xa7b9651b
    .word 0x3df5be7d
    .word 0xa8440d0e
    .word 0x52ff6477
    .word 0x993e2b7f
    .word 0x73d66c57
    .word 0x873bd21c
    .word 0xfd5b4536
    .word 0x1f15b430
    .word 0x22d0b058
    .word 0x1326aa2e
    .word 0xf7a47f37
    .word 0x216256d3
    .word 0x3d831a55
    .word 0x5d9d9b74
    .word 0xf61d7e5d
    .word 0x677338fe
    .word 0x33bdab7d
    .word 0x66b17ae5
    .word 0x23d41273
    .word 0xa34119f5
    .word 0x7ca6df62
    .word 0x2c89ecfe
    .word 0x0566041c
    .word 0x30481dc5
    .word 0xbd12ebd5
    .word 0x66372362
    .word 0xcee1c203
    .word 0x1cbe16b3
    .word 0x58632147
    .word 0x16c8abf6
    .word 0x61720809
    .word 0xbb278823
    .word 0xf3597538
    .word 0xbf5b5e9f
    .word 0x8c30fac7
    .word 0x899bfe62
    .word 0x9e20889e
    .word 0x4c35de1e
    .word 0xb04bc77e
    .word 0x0159ff8e
    .word 0x4cbff532
    .word 0x2577b1d2
    .word 0xd3f1ffef
    .word 0x5465a9ed
    .word 0x7326968d
    .word 0x547ea44a
    .word 0xade7bcde
    .word 0x19cf8d30
    .word 0x575565fd
    .word 0xf14934c6
    .word 0xa2bb93a3
    .word 0x9ed74604
    .word 0x7a61abf0
    .word 0x8ba4e738
    .word 0x2b8ff3d5
    .word 0x541857c2
    .word 0xe78c26ec
    .word 0x34636ad7
    .word 0x73b2bc04
    .word 0xe871296d
    .word 0x8befd42d
    .word 0x02134eae
    .word 0x19d92a1d
    .word 0x4e1d1cc2
    .word 0x8547df65
    .word 0x6d3b7c9c
    .word 0xc0c9cc4b
    .word 0x9b56724b
    .word 0xbd6901f1
    .word 0x12007299
    .word 0x1343ab35
    .word 0x4f59b4ce
    .word 0xcb16c211
    .word 0x520aa10d
    .word 0x746e7641
    .word 0xbfc6f3ea
    .word 0x2ba2adb5
    .word 0x0f9863e0
    .word 0x28334dc2
    .word 0x91cf91b5
    .word 0x3cdce329
    .word 0xe7382382
    .word 0xaddd1ea3
    .word 0x925b1551
    .word 0xc21d6839
    .word 0xa2d1966a
    .word 0xcfa51bf1
    .word 0x774cbdea
    .word 0xe2db98e3
    .word 0x0db86c42
    .word 0x820c4f90
    .word 0x0ea83aa7
    .word 0x01bd8b1a
    .word 0x818abfb3
    .word 0xa69528f4
    .word 0x3ca21c36
    .word 0xc9b076de
    .word 0x47928e9f
    .word 0x410bd434
    .word 0xaa47a25d
    .word 0xa4e7e623
    .word 0xf49dbbc4
    .word 0xea6d787d
    .word 0xe2a44d9c
    .word 0xc85f129b
    .word 0xbcefdbe0
    .word 0x4a0c64fd
    .word 0xaebee578
    .word 0x3b827c85
    .word 0xb5aa3320
    .word 0xcc605044
    .word 0x446f484d
    .word 0xf611e609
    .word 0x13553f08
    .word 0x8224f058
    .word 0x6ef0b357
    .word 0xfa8ff4c9
    .word 0xe2c1cf22
    .word 0xe74b2cc0
    .word 0x1a652157
    .word 0x7ffc7479
    .word 0xfead9737
    .word 0x9f0b4e4a
    .word 0x3a5fa2c2
    .word 0xbf22832c
    .word 0xb18ffba6
    .word 0xef6a7649
    .word 0x76449692
    .word 0x333b87a6
    .word 0x5086aee4
    .word 0x173c3100
    .word 0x97f8dcd1
    .word 0x8f789a8c
    .word 0x414cd99b
    .word 0x73062d60
    .word 0x8d5d3e7d
    .word 0xa04b955d
    .word 0xdc1e2426
    .word 0xf4cc2df6
    .word 0x9ec0ced2
    .word 0x78789e2a
    .word 0x5a24642b
    .word 0x4af4ecc5
    .word 0xdf087bf3
    .word 0x94ac713a
    .word 0xf0a9ef06
    .word 0xbe4700c5

#include "frost_footer.S"
