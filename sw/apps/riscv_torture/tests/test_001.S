// Generated RV32IMAFDC torture test for Frost (seed=42)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xa3b1799d
    li x4, 0x46685257
    li x5, 0x392456de
    li x6, 0xbc8960a9
    li x7, 0x6c031199
    li x8, 0x07a0ca6e
    li x9, 0x37f8a88b
    li x10, 0x8b8148f6
    li x11, 0x386ecbe0
    li x12, 0x96da1dac
    li x13, 0xce4a2bbd
    li x14, 0xb2b9437a
    li x15, 0x571aa876
    li x16, 0x27cd8130
    li x17, 0x562b0f79
    li x18, 0x17be3111
    li x19, 0x18c26797
    li x20, 0xd8f56413
    li x21, 0x9a8dca03
    li x22, 0xce9ff57f
    li x23, 0xbacfb3d0
    li x24, 0x89463e85
    li x25, 0x60e7a113
    li x26, 0x8d5288f1
    li x27, 0xdc98d2c1
    li x28, 0x93cd59bf
    li x29, 0xb45ed1f0
    li x30, 0x19db3ad0
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
    li x1, 0x47294739

    blt x8, x14, _br_taken_0
    srl x14, x24, x11
    j _br_done_0
_br_taken_0:
    sub x14, x22, x23
_br_done_0:
    xor x15, x11, x23
    srai x24, x13, 3
    add x28, x13, x15
    ori x9, x23, 2041
    sra x7, x10, x26
    andi x26, x21, 1461
    xori x14, x10, -915
    lw x27, 184(x31)
    sw x4, 184(x31)
    xori x22, x5, 1104
    sltiu x30, x1, -1110
    sltiu x27, x11, 738
    add x26, x26, x11
    srli x19, x6, 19
    fmsub.s f0, f20, f31, f1
    fmul.d f15, f3, f15
    fadd.s f31, f4, f8
    srli x11, x19, 27
    sltiu x27, x26, -401
    bge x24, x23, _br_taken_1
    xor x14, x19, x17
    j _br_done_1
_br_taken_1:
    sub x14, x10, x10
_br_done_1:
    srai x21, x10, 0
    sub x4, x30, x13
    srl x11, x24, x18
    sll x26, x21, x21
    srai x6, x6, 27
    or x17, x30, x26
    slli x4, x15, 21
    slli x10, x9, 12
    srli x16, x8, 17
    slt x6, x4, x23
    addi x8, x31, 484
    amoadd.w x5, x27, (x8)
    or x4, x8, x15
    or x11, x28, x28
    sltiu x24, x25, 1938
    sra x9, x4, x21
    beq x26, x13, _br_taken_2
    add x4, x21, x18
    j _br_done_2
_br_taken_2:
    slt x4, x30, x19
_br_done_2:
    sll x5, x22, x5
    srai x15, x6, 15
    addi x22, x5, 1386
    bltu x19, x13, _br_taken_3
    srl x11, x24, x25
    j _br_done_3
_br_taken_3:
    and x11, x10, x11
_br_done_3:
    slti x13, x27, -1454
    sltu x21, x6, x5
    sltiu x11, x7, 811
    fnmadd.d f0, f19, f6, f8
    srli x11, x12, 13
    bne x24, x23, _br_taken_4
    sra x30, x19, x18
    j _br_done_4
_br_taken_4:
    sra x30, x30, x4
_br_done_4:
    addi x1, x13, -977
    andi x8, x26, 1571
    lw x20, 872(x31)
    sw x1, 872(x31)
    sltiu x4, x29, 976
    srli x16, x7, 2
    add x14, x9, x24
    slt x30, x16, x22
    bne x30, x8, _br_taken_5
    sll x28, x16, x1
    j _br_done_5
_br_taken_5:
    sll x28, x26, x13
_br_done_5:
    bge x28, x24, _br_taken_6
    srl x30, x11, x8
    j _br_done_6
_br_taken_6:
    sub x30, x15, x30
_br_done_6:
    xor x14, x12, x29
    srai x10, x1, 12
    andi x14, x23, 1226
    sltiu x13, x1, -1104
    fmul.d f2, f6, f27
    fdiv.d f7, f24, f12
    slt x28, x20, x24
    srai x14, x16, 4
    ori x22, x13, -1028
    blt x19, x12, _br_taken_7
    or x24, x13, x15
    j _br_done_7
_br_taken_7:
    sra x24, x20, x7
_br_done_7:
    srli x22, x21, 19
    add x12, x12, x9
    sltu x22, x23, x13
    sltiu x18, x28, -658
    andi x19, x24, 697
    srai x28, x9, 9
    slli x17, x16, 12
    bge x18, x15, _br_taken_8
    sll x10, x23, x25
    j _br_done_8
_br_taken_8:
    add x10, x27, x30
_br_done_8:
    beq x27, x16, _br_taken_9
    sll x10, x28, x25
    j _br_done_9
_br_taken_9:
    slt x10, x17, x4
_br_done_9:
    lhu x17, 248(x31)
    sh x7, 248(x31)
    addi x20, x31, 872
    amomax.w x22, x29, (x20)
    slti x17, x11, -23
    fmax.s f15, f17, f28
    fmul.d f21, f20, f5
    sll x25, x9, x5
    xori x4, x9, 1393
    sltu x25, x1, x30
    fnmadd.d f19, f24, f26, f14
    fdiv.s f1, f24, f21
    fmax.s f10, f29, f8
    addi x5, x31, 52
    amomaxu.w x1, x15, (x5)
    bne x30, x17, _br_taken_10
    add x8, x11, x15
    j _br_done_10
_br_taken_10:
    and x8, x9, x17
_br_done_10:
    or x11, x29, x5
    slt x4, x14, x10
    bgeu x4, x27, _br_taken_11
    srl x1, x9, x29
    j _br_done_11
_br_taken_11:
    add x1, x22, x7
_br_done_11:
    srai x17, x25, 16
    srli x22, x22, 7
    bne x12, x6, _br_taken_12
    add x21, x12, x21
    j _br_done_12
_br_taken_12:
    or x21, x15, x25
_br_done_12:
    srai x6, x25, 19
    slli x28, x21, 2
    or x24, x14, x5
    lhu x1, 696(x31)
    sh x30, 696(x31)
    slti x25, x7, 1519
    slt x23, x11, x22
    fmax.s f17, f20, f15
    fnmsub.s f15, f29, f24, f21
    fsub.d f31, f13, f22
    blt x11, x22, _br_taken_13
    sra x25, x20, x1
    j _br_done_13
_br_taken_13:
    slt x25, x9, x5
_br_done_13:
    srl x25, x18, x23
    slti x28, x1, -1286
    andi x24, x21, 975
    slt x14, x16, x26
    lhu x25, 720(x31)
    sh x17, 720(x31)
    ori x6, x26, -532
    sltu x27, x19, x22
    sub x29, x9, x12
    sll x12, x1, x25
    lbu x4, 560(x31)
    sb x4, 560(x31)
    bne x23, x30, _br_taken_14
    xor x27, x6, x30
    j _br_done_14
_br_taken_14:
    add x27, x21, x12
_br_done_14:
    add x11, x30, x18
    sub x15, x18, x5
    lbu x7, 108(x31)
    sb x7, 108(x31)
    or x22, x22, x28
    bltu x15, x17, _br_taken_15
    sra x17, x30, x21
    j _br_done_15
_br_taken_15:
    or x17, x12, x21
_br_done_15:
    bltu x26, x6, _br_taken_16
    srl x27, x23, x9
    j _br_done_16
_br_taken_16:
    sra x27, x24, x5
_br_done_16:
    srli x1, x16, 28
    bge x12, x4, _br_taken_17
    sra x10, x25, x12
    j _br_done_17
_br_taken_17:
    xor x10, x5, x24
_br_done_17:
    srai x16, x6, 14
    andi x29, x7, -1464
    andi x17, x6, 1791
    xori x11, x19, 1997
    or x26, x13, x22
    sub x10, x24, x29
    addi x27, x24, 159
    lbu x18, 356(x31)
    sb x19, 356(x31)
    rem x23, x29, x18
    addi x13, x31, 680
    amomax.w x14, x16, (x13)
    bne x13, x16, _br_taken_18
    xor x25, x12, x24
    j _br_done_18
_br_taken_18:
    or x25, x29, x27
_br_done_18:
    lhu x5, 928(x31)
    sh x13, 928(x31)
    addi x24, x30, 1736
    srl x19, x14, x22
    bgeu x17, x27, _br_taken_19
    srl x4, x11, x20
    j _br_done_19
_br_taken_19:
    sll x4, x12, x17
_br_done_19:
    fmin.d f15, f10, f19
    fadd.s f14, f7, f29
    remu x25, x12, x19
    bge x29, x18, _br_taken_20
    srl x18, x17, x20
    j _br_done_20
_br_taken_20:
    sll x18, x15, x9
_br_done_20:
    mulh x11, x27, x28
    fadd.s f18, f19, f31
    fdiv.s f22, f21, f24
    srai x21, x15, 14
    xori x4, x13, 1826
    bge x15, x24, _br_taken_21
    sll x28, x18, x4
    j _br_done_21
_br_taken_21:
    sll x28, x19, x21
_br_done_21:
    slti x6, x19, 1695
    sll x5, x18, x28
    addi x23, x31, 812
    amomin.w x22, x25, (x23)
    sltiu x15, x13, 1949
    addi x22, x5, -125
    blt x10, x26, _br_taken_22
    or x5, x6, x27
    j _br_done_22
_br_taken_22:
    sub x5, x17, x8
_br_done_22:
    beq x4, x13, _br_taken_23
    add x28, x12, x14
    j _br_done_23
_br_taken_23:
    and x28, x16, x7
_br_done_23:
    srli x8, x8, 5
    xori x22, x24, -76
    xor x23, x11, x17
    add x28, x17, x12
    srli x5, x17, 22
    addi x17, x31, 512
    amoxor.w x23, x16, (x17)
    fadd.s f15, f24, f22
    lbu x1, 604(x31)
    sb x29, 604(x31)
    addi x22, x26, 2021
    andi x27, x28, -163
    ori x10, x23, -491
    bgeu x27, x26, _br_taken_24
    sll x27, x23, x6
    j _br_done_24
_br_taken_24:
    add x27, x12, x28
_br_done_24:
    sll x5, x12, x13
    srli x9, x7, 23
    andi x29, x8, 57
    div x26, x30, x13
    mulh x17, x5, x7
    bne x30, x24, _br_taken_25
    or x26, x30, x28
    j _br_done_25
_br_taken_25:
    slt x26, x14, x5
_br_done_25:
    beq x11, x20, _br_taken_26
    xor x6, x14, x24
    j _br_done_26
_br_taken_26:
    sra x6, x21, x15
_br_done_26:
    fadd.d f20, f14, f4
    fmax.s f19, f26, f7
    xor x6, x6, x10
    fmax.d f26, f9, f26
    bge x22, x16, _br_taken_27
    add x11, x25, x14
    j _br_done_27
_br_taken_27:
    srl x11, x17, x17
_br_done_27:
    addi x20, x31, 752
    amomin.w x6, x24, (x20)
    mul x15, x11, x9
    mulh x30, x29, x17
    addi x4, x28, 684
    srai x5, x29, 13
    lw x13, 476(x31)
    sw x27, 476(x31)
    bltu x1, x11, _br_taken_28
    sll x30, x7, x20
    j _br_done_28
_br_taken_28:
    sra x30, x28, x8
_br_done_28:
    and x28, x28, x10
    lw x8, 32(x31)
    sw x11, 32(x31)
    slli x18, x17, 23
    slli x17, x19, 14
    div x17, x23, x1
    xori x24, x6, 1968
    slti x5, x5, 590
    beq x7, x11, _br_taken_29
    sltu x22, x20, x25
    j _br_done_29
_br_taken_29:
    and x22, x15, x22
_br_done_29:
    lh x19, 928(x31)
    sh x22, 928(x31)
    beq x30, x23, _br_taken_30
    slt x23, x26, x30
    j _br_done_30
_br_taken_30:
    srl x23, x16, x17
_br_done_30:
    fdiv.d f6, f20, f27
    fsub.d f30, f4, f5
    fmul.s f8, f3, f21
    bge x14, x30, _br_taken_31
    or x24, x30, x26
    j _br_done_31
_br_taken_31:
    add x24, x12, x22
_br_done_31:
    srai x7, x24, 30
    slt x14, x6, x27
    sltiu x27, x29, -1833
    bgeu x29, x25, _br_taken_32
    add x11, x8, x11
    j _br_done_32
_br_taken_32:
    sra x11, x13, x14
_br_done_32:
    xori x5, x7, -1797
    or x17, x13, x8
    and x27, x21, x22
    add x7, x8, x27
    bgeu x5, x11, _br_taken_33
    or x17, x18, x22
    j _br_done_33
_br_taken_33:
    xor x17, x16, x11
_br_done_33:
    or x6, x12, x24
    slti x19, x24, 478
    or x22, x4, x1
    andi x12, x13, -1066
    sll x15, x20, x25
    slt x29, x24, x28
    or x30, x26, x4
    ori x21, x16, 1265
    xori x12, x6, 1270
    sltu x17, x29, x25
    slli x16, x30, 6
    sub x15, x30, x12
    srai x13, x27, 10
    sub x19, x19, x9
    divu x26, x29, x23
    mulhsu x10, x6, x7
    slli x8, x27, 31
    slti x24, x21, 599
    ori x7, x17, -1489
    sra x28, x11, x21
    xor x17, x4, x4
    sra x5, x23, x30
    slli x22, x22, 24
    addi x17, x28, -506
    xor x19, x7, x4
    and x25, x5, x19
    beq x10, x25, _br_taken_34
    xor x17, x19, x19
    j _br_done_34
_br_taken_34:
    sltu x17, x8, x14
_br_done_34:
    and x24, x22, x4
    ori x5, x13, -1274
    lb x12, 788(x31)
    sb x11, 788(x31)
    ori x12, x23, 1162
    sub x12, x20, x15
    ori x29, x7, -1283
    bge x19, x14, _br_taken_35
    and x1, x12, x8
    j _br_done_35
_br_taken_35:
    srl x1, x13, x27
_br_done_35:
    srli x5, x12, 6
    lb x24, 76(x31)
    sb x13, 76(x31)
    lb x8, 312(x31)
    sb x8, 312(x31)
    beq x16, x14, _br_taken_36
    srl x24, x17, x22
    j _br_done_36
_br_taken_36:
    sra x24, x27, x26
_br_done_36:
    bne x20, x10, _br_taken_37
    xor x12, x29, x9
    j _br_done_37
_br_taken_37:
    and x12, x24, x21
_br_done_37:
    addi x19, x31, 780
    amomax.w x27, x12, (x19)
    lb x29, 328(x31)
    sb x9, 328(x31)
    fmin.s f6, f7, f18
    slt x7, x29, x16
    ori x1, x16, -1612
    sub x14, x10, x1
    sub x29, x25, x23
    sra x29, x18, x25
    fadd.s f1, f16, f13
    fmax.s f27, f7, f18
    fmsub.d f26, f29, f4, f7
    fmsub.s f9, f18, f27, f0
    fdiv.s f11, f5, f23
    sltiu x20, x1, 1150
    addi x23, x15, 1010
    add x14, x28, x5
    slli x27, x21, 21
    and x20, x13, x29
    slti x25, x18, -555
    fadd.s f18, f12, f2
    beq x13, x12, _br_taken_38
    or x19, x29, x20
    j _br_done_38
_br_taken_38:
    xor x19, x11, x4
_br_done_38:
    bne x12, x14, _br_taken_39
    add x30, x30, x23
    j _br_done_39
_br_taken_39:
    and x30, x11, x6
_br_done_39:
    bge x15, x26, _br_taken_40
    or x17, x13, x8
    j _br_done_40
_br_taken_40:
    xor x17, x25, x18
_br_done_40:
    sub x26, x16, x5
    sll x20, x12, x13
    and x24, x12, x12
    xor x14, x17, x4
    ori x22, x16, 201
    addi x5, x24, 1279
    addi x7, x30, 1541
    sub x10, x27, x23
    or x21, x4, x22
    ori x17, x27, -1419
    sltiu x14, x15, 527
    bne x6, x1, _br_taken_41
    sll x26, x18, x19
    j _br_done_41
_br_taken_41:
    or x26, x20, x6
_br_done_41:
    srai x22, x12, 31
    sll x30, x5, x17
    sub x28, x24, x30
    ori x25, x5, 330
    srli x25, x25, 11
    bltu x10, x6, _br_taken_42
    sll x9, x10, x28
    j _br_done_42
_br_taken_42:
    xor x9, x1, x14
_br_done_42:
    lb x17, 752(x31)
    sb x28, 752(x31)
    beq x5, x12, _br_taken_43
    xor x15, x19, x16
    j _br_done_43
_br_taken_43:
    or x15, x29, x21
_br_done_43:
    slti x17, x24, 774
    slt x23, x21, x8
    bne x16, x19, _br_taken_44
    add x30, x29, x6
    j _br_done_44
_br_taken_44:
    slt x30, x7, x12
_br_done_44:
    srai x14, x19, 18
    andi x9, x23, 200
    slli x19, x23, 10
    srli x8, x24, 21
    fadd.d f2, f16, f13
    fmax.s f1, f31, f18
    fsub.s f25, f19, f29
    or x18, x17, x9
    and x26, x30, x14
    addi x13, x31, 216
    amoand.w x27, x14, (x13)
    srl x7, x6, x4
    xori x10, x30, -740
    ori x9, x27, -743
    sra x18, x1, x5
    sltiu x17, x10, -286
    addi x4, x12, 2006
    lw x12, 960(x31)
    sw x20, 960(x31)
    fmul.d f25, f23, f2
    fsub.s f23, f18, f4
    andi x29, x22, -1075
    sub x15, x14, x28
    addi x9, x31, 292
    amomaxu.w x14, x27, (x9)
    bge x19, x4, _br_taken_45
    add x4, x7, x25
    j _br_done_45
_br_taken_45:
    and x4, x28, x18
_br_done_45:
    lw x22, 304(x31)
    sw x19, 304(x31)

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x2999bbef518b2f21
    .dword 0x88476c56827c9f8c
    .dword 0x901bcdefb56ff8ce
    .dword 0xd0d4ea6779928faa
    .dword 0xfada98f51c0f0bdc
    .dword 0xa1173719b023a0ea
    .dword 0x797ebe8798cf1188
    .dword 0x9561c8130d259caa
    .dword 0x61542765d756ba9c
    .dword 0xae441e21d25864f2
    .dword 0x1c221ceab35556a5
    .dword 0x70e7e75604d9145e
    .dword 0x26c432f66b352f85
    .dword 0x34323ec6b0c4a01c
    .dword 0xb4adaf890ff1aa9f
    .dword 0x8685abaa7a768555
    .dword 0xf4e9573450521700
    .dword 0x8bd88fcd57a2be4e
    .dword 0xb17cfb21cdbc2c1c
    .dword 0x7bf33a349c2dfa97
    .dword 0x3f1be0d0f5141058
    .dword 0x4c6a70f48edec44d
    .dword 0xc56bad4c4c3077c4
    .dword 0x7d2f4e58b47a1c5b
    .dword 0x46015028b8beff3d
    .dword 0x257f7595cdfb4db9
    .dword 0x143b45e3b6d1f6bb
    .dword 0xbf51936241a64fed
    .dword 0xb23848498fe069b6
    .dword 0x963a8617bdab07e7
    .dword 0x87f255d6e7ba26ac
    .dword 0x3b9b2d45a35055e4

    .align 2
_torture_data:
    .word 0x19a692c9
    .word 0x78ef7666
    .word 0x23310a28
    .word 0x286ed390
    .word 0x79c773a0
    .word 0xa689b424
    .word 0x4988e418
    .word 0xc4cb294f
    .word 0xebe5841f
    .word 0xd66d4627
    .word 0xd61169a1
    .word 0xc9b7c9bc
    .word 0x0997623a
    .word 0x9a4ffc0c
    .word 0x55c551fc
    .word 0x8639bd41
    .word 0x811414f8
    .word 0x45d8a6ad
    .word 0xcf0e6d2b
    .word 0x54a7b69b
    .word 0xbb2aa146
    .word 0xa5f60735
    .word 0xb7f60cdf
    .word 0x317304b5
    .word 0x53f30073
    .word 0x186b2880
    .word 0xfb4fb88a
    .word 0x7a3a6e96
    .word 0xef9240b6
    .word 0x01bf9e73
    .word 0x6231ee73
    .word 0x546252e7
    .word 0x92a81713
    .word 0x3c7e5368
    .word 0xaaf407f7
    .word 0x77242041
    .word 0x28e333b6
    .word 0xc5144d98
    .word 0xb0b6dedf
    .word 0xf0cd7f05
    .word 0x3889936a
    .word 0xf5159494
    .word 0x7a6a2107
    .word 0x5fa5e0aa
    .word 0xe9ad0e9b
    .word 0xd35ac07a
    .word 0xc3093b6e
    .word 0xc9912032
    .word 0x86879aa9
    .word 0x5c9deee0
    .word 0x1cb9b73a
    .word 0x89628f6e
    .word 0x2a1f1b61
    .word 0x711c7673
    .word 0xae27d432
    .word 0x7d23d479
    .word 0x0e3e25f2
    .word 0x6a5943ce
    .word 0x905c7bdd
    .word 0x8f0d5540
    .word 0x0592bfa5
    .word 0x12b2102d
    .word 0x6c776e95
    .word 0xb34c6c73
    .word 0xe4eb8000
    .word 0x78d9a88a
    .word 0x497ec6d1
    .word 0xf6ba745b
    .word 0xe42e707a
    .word 0x60a399d4
    .word 0xdc3bbdd8
    .word 0x1e5ebe54
    .word 0xfa8dae42
    .word 0xd5b6de85
    .word 0xc194f97f
    .word 0xfa7e5d94
    .word 0x3acb43a3
    .word 0x75eb89c2
    .word 0x27b608dc
    .word 0xc3f725fe
    .word 0xa902b73f
    .word 0xe39836bb
    .word 0x3d9c4e64
    .word 0x1139fa12
    .word 0x980cb95c
    .word 0xdf495037
    .word 0x0b531932
    .word 0x705fddf5
    .word 0x8a2db2e6
    .word 0xc6ac1b04
    .word 0xfe54ee4b
    .word 0x937bf79b
    .word 0xd18183d1
    .word 0x3ca5be29
    .word 0xe0527739
    .word 0x8570b59f
    .word 0x69df14e9
    .word 0x46707cd6
    .word 0xadc29178
    .word 0x8e4c3ab5
    .word 0x86433603
    .word 0xb2414482
    .word 0x6883ac6e
    .word 0x4cc57e0d
    .word 0x89b5aab0
    .word 0x39b02e2a
    .word 0x87ad8b26
    .word 0x636f6e5c
    .word 0x41476506
    .word 0x5efeef4f
    .word 0xd453f867
    .word 0x0d31812e
    .word 0x12a1fe7d
    .word 0x378e6510
    .word 0xe8334da5
    .word 0xe8b3d763
    .word 0xbdd151b0
    .word 0xc11bd1c4
    .word 0xea18d32c
    .word 0xb42a2d93
    .word 0x48769153
    .word 0xa6129a1c
    .word 0x4ef4c34d
    .word 0xe1fff6c0
    .word 0x774c0afa
    .word 0xb8f0188e
    .word 0x340029c3
    .word 0x501ba851
    .word 0xdd34aa18
    .word 0xbdc2b74b
    .word 0x0426fcc9
    .word 0xb852b3cd
    .word 0x4b91b8cb
    .word 0x32399ffb
    .word 0x3ae28023
    .word 0x3ee82983
    .word 0x566a9ce7
    .word 0xbd5609c4
    .word 0x75f8e3a8
    .word 0x5a2837b2
    .word 0x8bea75c1
    .word 0xf50d7a37
    .word 0x862138ad
    .word 0x01a25ed1
    .word 0xa175a9c3
    .word 0x26a9e100
    .word 0x74bd0c93
    .word 0xe9aa144b
    .word 0xa8c6dbc0
    .word 0x0406ff44
    .word 0x694d7b00
    .word 0xb8e19f56
    .word 0x49646b96
    .word 0x2de46e91
    .word 0xeb053fc4
    .word 0x863e1f2a
    .word 0x3db02235
    .word 0x5abca6e5
    .word 0xcb80f288
    .word 0x143a9aff
    .word 0xf5948a54
    .word 0xb27e1442
    .word 0x081c79d4
    .word 0x67c0518b
    .word 0x79db7862
    .word 0xa301ec03
    .word 0xb3eda8f1
    .word 0x152aeaec
    .word 0xd867888b
    .word 0xf94d8fcb
    .word 0xeb4d8f42
    .word 0x3ad1fa33
    .word 0x9118c400
    .word 0x45667c48
    .word 0xec95b3ac
    .word 0xa879d8f8
    .word 0xd9b59f84
    .word 0xd226a8b3
    .word 0xedcabf94
    .word 0x4c9d6907
    .word 0x905f9096
    .word 0xd9750f00
    .word 0x8a624cbd
    .word 0xbd5ff093
    .word 0x588a3f87
    .word 0x1901ef87
    .word 0x1375ee90
    .word 0x9879cf35
    .word 0x538d6b8c
    .word 0xa255e1bb
    .word 0x735741e5
    .word 0x3a67470c
    .word 0x601bfbcb
    .word 0x614c721d
    .word 0x12d15585
    .word 0x4499d0a6
    .word 0x63be441d
    .word 0x5c56d9bc
    .word 0x176de21f
    .word 0xf165d779
    .word 0x71da35b9
    .word 0xc2e79a98
    .word 0x1a2bd69c
    .word 0x16591c89
    .word 0x6e54ac6d
    .word 0x832f52c4
    .word 0x1a7167c7
    .word 0x16f142a2
    .word 0x8de1596c
    .word 0xc8d0f9e5
    .word 0xdd1ca267
    .word 0x0328c136
    .word 0x69ef74e3
    .word 0xc777a07f
    .word 0x85671b58
    .word 0xaf70de70
    .word 0x2b64777c
    .word 0x44d7df9a
    .word 0x44b64ec1
    .word 0x255bfc1c
    .word 0x2ace1aa9
    .word 0x46a56fe8
    .word 0x4cbc9044
    .word 0xc85cd714
    .word 0x5c72aebd
    .word 0xf1b88d65
    .word 0x9dde0188
    .word 0x75366b9f
    .word 0x22af711f
    .word 0x654c11d9
    .word 0xdcb9075e
    .word 0x70b27304
    .word 0x982a2277
    .word 0x4ce953a7
    .word 0xb1fead13
    .word 0x7aa061e9
    .word 0x51b30182
    .word 0xa205e54f
    .word 0xc82f78fd
    .word 0x536d47d7
    .word 0xc92e8c93
    .word 0x5d71a898
    .word 0xba2aa7ba
    .word 0x35ab8466
    .word 0xcc351e4f
    .word 0xcb881c32
    .word 0xac484366
    .word 0x4d8670bd
    .word 0x6082786f
    .word 0x9912316a
    .word 0x950df1a0
    .word 0xf7eae66e
    .word 0xea163354
    .word 0xaa2960fd
    .word 0x9cd8758b
    .word 0xa590fd3c

#include "frost_footer.S"
