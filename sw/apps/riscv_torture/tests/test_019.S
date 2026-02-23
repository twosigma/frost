// Generated RV32IMAFDC torture test for Frost (seed=60)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x4ecc6c7f
    li x4, 0x93f50c2c
    li x5, 0x43ff8b2b
    li x6, 0xced24692
    li x7, 0xe591941f
    li x8, 0xdc0fa4ba
    li x9, 0x2f7a4b6b
    li x10, 0x63d25b1a
    li x11, 0x0259e3c8
    li x12, 0x2ab1db36
    li x13, 0xacc73385
    li x14, 0x96c14117
    li x15, 0x4d476a53
    li x16, 0x9119f378
    li x17, 0x4642cd2b
    li x18, 0xf0f65fcd
    li x19, 0xe6e5efdd
    li x20, 0x7e69eb30
    li x21, 0x605d1b20
    li x22, 0xa583dd1d
    li x23, 0x0894f0d4
    li x24, 0x175ee475
    li x25, 0x8e5f0ec2
    li x26, 0xc7816d0a
    li x27, 0x2b30aa12
    li x28, 0xb744b677
    li x29, 0xf8bc1c60
    li x30, 0xf1244d85
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
    li x1, 0x623ad1f4

    srl x16, x20, x5
    addi x19, x18, -1917
    sub x4, x21, x23
    bgeu x24, x9, _br_taken_0
    sll x5, x14, x24
    j _br_done_0
_br_taken_0:
    or x5, x29, x18
_br_done_0:
    addi x18, x13, -34
    sra x18, x27, x13
    srl x12, x13, x10
    bltu x23, x23, _br_taken_1
    slt x8, x14, x11
    j _br_done_1
_br_taken_1:
    add x8, x8, x30
_br_done_1:
    srai x19, x6, 7
    bne x5, x1, _br_taken_2
    xor x20, x25, x6
    j _br_done_2
_br_taken_2:
    srl x20, x20, x29
_br_done_2:
    lbu x9, 860(x31)
    sb x29, 860(x31)
    lw x1, 628(x31)
    sw x12, 628(x31)
    lhu x27, 764(x31)
    sh x17, 764(x31)
    xori x22, x30, 1518
    sra x17, x19, x6
    sltu x21, x19, x24
    add x26, x7, x29
    ori x6, x1, -723
    srli x9, x8, 28
    sltu x10, x19, x26
    slli x20, x24, 27
    srai x1, x27, 16
    beq x21, x4, _br_taken_3
    sll x26, x16, x7
    j _br_done_3
_br_taken_3:
    srl x26, x20, x21
_br_done_3:
    lb x20, 348(x31)
    sb x12, 348(x31)
    srai x11, x9, 8
    sub x1, x6, x27
    lb x12, 360(x31)
    sb x24, 360(x31)
    sll x11, x8, x6
    sltiu x17, x20, 1984
    ori x10, x23, -1541
    or x15, x1, x23
    slt x15, x5, x29
    slti x21, x20, -215
    srai x20, x6, 17
    bgeu x24, x14, _br_taken_4
    sub x4, x9, x28
    j _br_done_4
_br_taken_4:
    and x4, x13, x24
_br_done_4:
    lw x21, 256(x31)
    sw x12, 256(x31)
    bltu x17, x28, _br_taken_5
    srl x6, x9, x1
    j _br_done_5
_br_taken_5:
    xor x6, x6, x8
_br_done_5:
    bge x9, x8, _br_taken_6
    sra x9, x22, x11
    j _br_done_6
_br_taken_6:
    add x9, x21, x6
_br_done_6:
    sltu x27, x19, x5
    ori x28, x26, 769
    xor x17, x30, x23
    add x11, x4, x6
    slt x28, x13, x24
    sltu x5, x5, x20
    addi x25, x5, 595
    slti x7, x27, 813
    sltiu x8, x5, -882
    addi x7, x19, -1911
    bltu x11, x6, _br_taken_7
    sra x14, x18, x16
    j _br_done_7
_br_taken_7:
    slt x14, x7, x18
_br_done_7:
    srl x14, x26, x13
    slt x24, x13, x21
    sra x18, x13, x25
    addi x24, x1, -1087
    sltiu x10, x26, -1800
    slt x9, x19, x30
    fdiv.s f14, f21, f14
    bne x11, x30, _br_taken_8
    and x8, x11, x28
    j _br_done_8
_br_taken_8:
    sra x8, x10, x12
_br_done_8:
    addi x15, x31, 200
    amoxor.w x28, x14, (x15)
    bgeu x18, x11, _br_taken_9
    and x30, x19, x11
    j _br_done_9
_br_taken_9:
    and x30, x14, x29
_br_done_9:
    lw x30, 784(x31)
    sw x11, 784(x31)
    beq x19, x29, _br_taken_10
    and x17, x22, x8
    j _br_done_10
_br_taken_10:
    srl x17, x5, x17
_br_done_10:
    sub x11, x25, x23
    and x18, x19, x30
    and x30, x13, x12
    bne x11, x11, _br_taken_11
    srl x13, x27, x26
    j _br_done_11
_br_taken_11:
    xor x13, x30, x8
_br_done_11:
    lb x14, 588(x31)
    sb x29, 588(x31)
    sltiu x22, x11, 882
    fsub.d f26, f9, f24
    fnmsub.d f4, f10, f10, f3
    fmax.d f6, f30, f7
    or x28, x27, x23
    srl x15, x8, x6
    xor x11, x21, x25
    add x10, x29, x1
    fsub.d f23, f4, f28
    fdiv.s f4, f0, f26
    fnmadd.d f11, f24, f23, f30
    and x27, x21, x15
    slt x15, x7, x20
    beq x26, x23, _br_taken_12
    sra x22, x25, x11
    j _br_done_12
_br_taken_12:
    sra x22, x10, x4
_br_done_12:
    sltiu x23, x18, 935
    ori x16, x1, 1904
    ori x10, x28, -1333
    or x29, x20, x13
    fmin.s f15, f25, f29
    fmul.s f29, f28, f31
    sltu x4, x12, x29
    or x26, x25, x27
    sra x25, x20, x16
    sra x23, x28, x18
    fnmadd.d f13, f17, f19, f6
    fmadd.d f0, f25, f28, f7
    srai x24, x22, 12
    andi x11, x14, 1169
    srai x30, x28, 10
    sll x7, x20, x18
    srai x1, x16, 24
    xori x5, x8, -2001
    bge x28, x4, _br_taken_13
    sll x13, x30, x22
    j _br_done_13
_br_taken_13:
    add x13, x9, x17
_br_done_13:
    srli x26, x14, 11
    addi x8, x27, 1799
    addi x27, x1, -955
    sltu x8, x27, x11
    bgeu x15, x1, _br_taken_14
    sltu x9, x22, x13
    j _br_done_14
_br_taken_14:
    add x9, x12, x15
_br_done_14:
    blt x16, x9, _br_taken_15
    or x24, x24, x9
    j _br_done_15
_br_taken_15:
    xor x24, x17, x20
_br_done_15:
    andi x22, x24, 1035
    xor x8, x22, x9
    and x8, x1, x25
    slli x19, x15, 25
    sltu x4, x25, x28
    addi x24, x13, -955
    sra x26, x22, x25
    remu x11, x26, x6
    divu x19, x29, x14
    lw x28, 380(x31)
    sw x20, 380(x31)
    xori x17, x6, -1342
    and x4, x1, x20
    slt x30, x9, x17
    lbu x1, 96(x31)
    sb x8, 96(x31)
    bne x24, x12, _br_taken_16
    sub x15, x17, x24
    j _br_done_16
_br_taken_16:
    xor x15, x9, x13
_br_done_16:
    sra x13, x16, x24
    lbu x10, 408(x31)
    sb x22, 408(x31)
    bne x21, x15, _br_taken_17
    slt x21, x23, x5
    j _br_done_17
_br_taken_17:
    sltu x21, x24, x29
_br_done_17:
    fdiv.d f12, f17, f5
    lw x10, 308(x31)
    sw x22, 308(x31)
    andi x6, x23, -1340
    slti x26, x23, -1141
    lw x27, 684(x31)
    sw x19, 684(x31)
    bltu x15, x7, _br_taken_18
    xor x10, x24, x26
    j _br_done_18
_br_taken_18:
    sra x10, x1, x7
_br_done_18:
    slli x9, x28, 21
    xori x5, x26, -365
    andi x7, x10, 659
    srai x4, x4, 20
    add x23, x18, x12
    fnmadd.s f21, f20, f2, f29
    fmax.s f11, f9, f8
    and x19, x21, x9
    and x11, x7, x12
    slt x25, x10, x18
    xori x26, x8, 1303
    xori x24, x28, -1287
    and x29, x8, x22
    xori x12, x24, -1649
    srai x25, x25, 26
    slti x27, x30, -1726
    sub x30, x5, x30
    fmin.s f14, f22, f25
    sltu x7, x13, x27
    sll x19, x5, x13
    slt x29, x30, x11
    srl x21, x24, x22
    or x15, x14, x30
    and x16, x1, x1
    sra x9, x16, x26
    lh x21, 812(x31)
    sh x12, 812(x31)
    xori x29, x25, 1393
    sll x8, x19, x21
    bgeu x13, x24, _br_taken_19
    or x18, x25, x28
    j _br_done_19
_br_taken_19:
    sra x18, x24, x7
_br_done_19:
    addi x10, x31, 840
    amoor.w x9, x21, (x10)
    add x11, x26, x14
    ori x14, x4, 1833
    slli x9, x6, 4
    sltiu x18, x10, -156
    sll x29, x6, x20
    sltiu x20, x19, -940
    slti x29, x7, -1342
    slti x27, x11, 1302
    addi x23, x28, -952
    or x6, x12, x6
    sra x30, x10, x24
    fmsub.d f19, f27, f23, f17
    fsub.s f23, f31, f26
    fadd.d f21, f7, f8
    mulhu x6, x6, x21
    remu x18, x4, x6
    add x8, x8, x22
    sltiu x6, x18, 1313
    slt x19, x4, x1
    beq x17, x13, _br_taken_20
    slt x18, x25, x20
    j _br_done_20
_br_taken_20:
    sub x18, x26, x27
_br_done_20:
    bge x16, x14, _br_taken_21
    sltu x1, x30, x4
    j _br_done_21
_br_taken_21:
    xor x1, x17, x29
_br_done_21:
    bltu x26, x10, _br_taken_22
    sra x5, x20, x25
    j _br_done_22
_br_taken_22:
    add x5, x8, x6
_br_done_22:
    fmin.s f2, f11, f23
    sra x17, x21, x22
    sltiu x21, x6, 231
    srli x24, x28, 26
    ori x28, x1, 741
    slli x29, x13, 5
    addi x20, x31, 264
    amomin.w x17, x16, (x20)
    beq x22, x17, _br_taken_23
    and x20, x30, x30
    j _br_done_23
_br_taken_23:
    and x20, x22, x4
_br_done_23:
    beq x25, x27, _br_taken_24
    sltu x10, x25, x24
    j _br_done_24
_br_taken_24:
    srl x10, x11, x11
_br_done_24:
    bne x7, x5, _br_taken_25
    slt x8, x17, x19
    j _br_done_25
_br_taken_25:
    sltu x8, x22, x28
_br_done_25:
    addi x26, x31, 608
    amoadd.w x6, x20, (x26)
    fdiv.d f10, f15, f18
    andi x19, x25, -616
    slli x13, x29, 16
    srl x27, x4, x26
    lhu x8, 492(x31)
    sh x10, 492(x31)
    addi x24, x31, 748
    amoswap.w x4, x29, (x24)
    fmsub.d f5, f15, f6, f24
    fmax.d f4, f24, f21
    fdiv.s f16, f25, f30
    sub x11, x25, x18
    xor x17, x4, x10
    ori x15, x7, 679
    fdiv.d f25, f21, f9
    lw x30, 732(x31)
    sw x20, 732(x31)
    addi x5, x9, -922
    srl x30, x17, x14
    srl x18, x30, x17
    sltiu x25, x25, 1288
    sll x30, x19, x18
    bgeu x7, x15, _br_taken_26
    xor x24, x10, x25
    j _br_done_26
_br_taken_26:
    sltu x24, x19, x28
_br_done_26:
    andi x5, x23, 788
    slti x6, x8, 1827
    srai x26, x25, 1
    sub x29, x17, x11
    slli x24, x6, 30
    sub x15, x27, x14
    addi x16, x31, 752
    amominu.w x20, x1, (x16)
    beq x14, x17, _br_taken_27
    srl x27, x6, x25
    j _br_done_27
_br_taken_27:
    sltu x27, x25, x5
_br_done_27:
    ori x17, x26, -1807
    sra x12, x17, x5
    xori x9, x9, -1255
    xori x27, x30, 1203
    xor x11, x17, x26
    lb x25, 340(x31)
    sb x19, 340(x31)
    lh x29, 48(x31)
    sh x7, 48(x31)
    slli x20, x1, 17
    lb x8, 524(x31)
    sb x25, 524(x31)
    slti x4, x18, -691
    srli x30, x4, 12
    add x20, x18, x30
    divu x4, x4, x18
    rem x6, x18, x24
    srl x24, x26, x9
    ori x19, x20, 64
    bne x22, x19, _br_taken_28
    or x17, x7, x6
    j _br_done_28
_br_taken_28:
    sll x17, x10, x19
_br_done_28:
    srli x30, x18, 20
    addi x4, x17, 256
    xori x15, x22, -111
    bltu x20, x17, _br_taken_29
    sra x11, x27, x8
    j _br_done_29
_br_taken_29:
    sra x11, x15, x15
_br_done_29:
    addi x26, x31, 572
    amoand.w x10, x16, (x26)
    blt x19, x20, _br_taken_30
    sub x28, x16, x8
    j _br_done_30
_br_taken_30:
    slt x28, x16, x26
_br_done_30:
    srl x21, x4, x10
    sra x7, x20, x30
    fmul.d f30, f6, f29
    fmin.d f20, f8, f25
    fmul.s f1, f25, f10
    fmin.d f1, f19, f30
    fmul.s f18, f29, f24
    xor x7, x16, x17
    sll x16, x27, x4
    xori x9, x5, -1698
    andi x26, x11, 1056
    bge x5, x20, _br_taken_31
    add x1, x17, x12
    j _br_done_31
_br_taken_31:
    slt x1, x12, x22
_br_done_31:
    sub x18, x30, x25
    sll x12, x9, x12
    sra x16, x9, x1
    andi x1, x29, 1087
    sub x4, x30, x21
    addi x24, x30, -324
    srl x23, x30, x12
    slt x25, x1, x24
    remu x7, x19, x21
    rem x4, x15, x22
    bne x16, x8, _br_taken_32
    srl x4, x17, x1
    j _br_done_32
_br_taken_32:
    and x4, x13, x21
_br_done_32:
    slli x13, x5, 12
    andi x7, x9, 1565
    beq x10, x14, _br_taken_33
    sra x14, x30, x24
    j _br_done_33
_br_taken_33:
    and x14, x25, x6
_br_done_33:
    lh x16, 528(x31)
    sh x6, 528(x31)
    beq x21, x22, _br_taken_34
    sll x20, x16, x26
    j _br_done_34
_br_taken_34:
    sub x20, x14, x26
_br_done_34:
    bltu x8, x14, _br_taken_35
    srl x22, x17, x18
    j _br_done_35
_br_taken_35:
    sltu x22, x9, x26
_br_done_35:
    bge x19, x24, _br_taken_36
    sll x1, x9, x8
    j _br_done_36
_br_taken_36:
    add x1, x10, x9
_br_done_36:
    sltiu x7, x9, 1411
    sltiu x22, x24, 827
    fmul.d f23, f27, f20
    xori x18, x4, -847
    xor x6, x27, x28
    srli x12, x1, 28
    srai x30, x10, 23
    slt x6, x13, x5
    srai x20, x11, 11
    sub x11, x12, x21
    sltiu x12, x25, -1962
    mulh x22, x5, x19
    sll x18, x23, x10
    srai x5, x7, 25
    xori x12, x18, -1042
    slli x8, x15, 13
    slti x26, x12, 1324
    srli x26, x30, 7
    mul x17, x4, x24
    or x12, x24, x25
    sub x7, x13, x19
    andi x18, x17, 309
    ori x26, x8, 45
    sll x16, x7, x9
    slt x23, x30, x16
    slti x13, x14, -1138
    lbu x16, 996(x31)
    sb x30, 996(x31)
    fmul.s f13, f3, f29
    fmax.s f24, f28, f16
    fadd.s f16, f4, f23
    sra x9, x12, x17
    slt x18, x19, x17
    srli x20, x14, 18
    lhu x21, 936(x31)
    sh x28, 936(x31)
    rem x17, x19, x14
    div x7, x6, x10
    bge x14, x30, _br_taken_37
    add x10, x10, x23
    j _br_done_37
_br_taken_37:
    sltu x10, x15, x30
_br_done_37:
    srl x7, x21, x5
    andi x26, x26, 1056
    andi x29, x5, 1106
    srl x17, x17, x18
    sltu x7, x9, x18
    slli x25, x13, 19
    add x20, x8, x12
    sltu x25, x7, x17
    slti x4, x26, -1973
    sra x29, x23, x15
    sltu x20, x7, x17
    sltu x19, x30, x8
    andi x24, x6, 151
    sltiu x21, x8, 1531
    or x27, x5, x11
    bgeu x22, x30, _br_taken_38
    and x21, x30, x16
    j _br_done_38
_br_taken_38:
    sub x21, x4, x10
_br_done_38:
    lw x17, 468(x31)
    sw x29, 468(x31)
    srli x4, x27, 30
    slt x30, x13, x14
    sra x28, x23, x14
    ori x25, x19, 80
    fadd.s f21, f10, f28
    fmul.d f14, f18, f27
    addi x17, x24, -1226
    and x27, x22, x16
    and x11, x14, x23
    fsub.d f24, f27, f29

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x5e0c9e5821b9cf2f
    .dword 0x8eec55a159527e0a
    .dword 0x2e9ec3f9020f42c2
    .dword 0x2ce018824a235365
    .dword 0x2edbabf0da3e5642
    .dword 0xacf30ac324ca0350
    .dword 0x8abbb63957730a70
    .dword 0xef161c689d0b6eae
    .dword 0x39bdebef5473b80d
    .dword 0x4ef4caa0d1edcaae
    .dword 0x3eba9dd5f817f8ad
    .dword 0x0abca286cd5aac72
    .dword 0xa2be4a7d5cc846e1
    .dword 0x32602ecb5627eb11
    .dword 0xda87378adff14627
    .dword 0x50ff311868dfa536
    .dword 0x30475163286d2d41
    .dword 0xada0cd4283b9a587
    .dword 0xaa26738e220e676e
    .dword 0x458789289a69d4ab
    .dword 0xd4bc0389f9685a97
    .dword 0xe2f003e70c496fb1
    .dword 0x3a77d2dae84552eb
    .dword 0xad45773bfd0578d5
    .dword 0xbf51b366f9e02d45
    .dword 0xe89d5c4aeb353ff9
    .dword 0x4c4888ba68dcca02
    .dword 0xba1c4fad3a5d9202
    .dword 0x7caa92f8c5323ba0
    .dword 0x8b08d2f43d236045
    .dword 0x9ccf66c428e8311f
    .dword 0xdd8b0d48bf6c2f01

    .align 2
_torture_data:
    .word 0x4e1bad67
    .word 0xb63426c0
    .word 0x6371b152
    .word 0xa9c47f3a
    .word 0xd746bbb0
    .word 0x22e4f85e
    .word 0xbb619b4b
    .word 0x05a8b37c
    .word 0xf8ef1ef3
    .word 0x05bf9f95
    .word 0x029bd555
    .word 0x0a9e2f94
    .word 0xefe949bb
    .word 0x08ea5744
    .word 0x5a0f2fa4
    .word 0x7ab41186
    .word 0xf1171227
    .word 0x25ea72ce
    .word 0x3a6ef607
    .word 0xda5e7580
    .word 0x566b523c
    .word 0x6485cf09
    .word 0x436cf3e6
    .word 0x7c6ccd1b
    .word 0x5d7c8dbd
    .word 0x344ad1a5
    .word 0x1636f4df
    .word 0x96518dd1
    .word 0x2f0257c5
    .word 0xc047e831
    .word 0x6846fe62
    .word 0x4c78d5d2
    .word 0x38eb74a2
    .word 0xbebd0e86
    .word 0xdb27c6bd
    .word 0x049958d9
    .word 0xef7f9519
    .word 0x5717c882
    .word 0x62ae3226
    .word 0xfbe3c613
    .word 0xdae91c54
    .word 0x13a9c599
    .word 0x1375e8c8
    .word 0xdee99daa
    .word 0xa05c0cc9
    .word 0x25f8b075
    .word 0xdd7b0fb3
    .word 0x1dfe3afc
    .word 0x5f40c35e
    .word 0xd4c77e98
    .word 0x5446bba1
    .word 0x36ebb25d
    .word 0xb9b85335
    .word 0xa9f8440b
    .word 0x648b55aa
    .word 0x7fa12340
    .word 0xcb1eb227
    .word 0xe0bd62ea
    .word 0x3568ca07
    .word 0x8dbf63df
    .word 0xeb2ec712
    .word 0x251f4f2e
    .word 0x2492ecae
    .word 0x6d70959f
    .word 0xed02ad65
    .word 0x2dccd1d9
    .word 0x61c8cf4a
    .word 0x2e025d0e
    .word 0x7358f8a6
    .word 0x77b2a0e1
    .word 0x599f7888
    .word 0xccb887b5
    .word 0xedc526a8
    .word 0x9515fa84
    .word 0x9c01ba65
    .word 0x4904f17e
    .word 0xc097fff9
    .word 0x6af59954
    .word 0xbf88c205
    .word 0xbd58eafb
    .word 0xede11301
    .word 0x1f4130fe
    .word 0xe805874b
    .word 0x1b5dc7df
    .word 0x9ff961bb
    .word 0x1a75cdb5
    .word 0x1489981a
    .word 0x542671e8
    .word 0x518bd584
    .word 0xbeb61d95
    .word 0x5a4cf399
    .word 0x0529f323
    .word 0x0fd6c286
    .word 0xfc7b4438
    .word 0x9c9786ec
    .word 0x1da6a9a0
    .word 0x04ec1297
    .word 0xd11865dd
    .word 0x435c449f
    .word 0x13dda376
    .word 0x63c586fb
    .word 0x78ea8e36
    .word 0x0722a0d4
    .word 0xbf002c72
    .word 0x8f19f4dc
    .word 0x7ed14723
    .word 0x6329cc8e
    .word 0x1bcd15d3
    .word 0xb6e55012
    .word 0xac0a564f
    .word 0x9f344a45
    .word 0xfa99eb06
    .word 0xfce87a42
    .word 0x89617b66
    .word 0x8fd599aa
    .word 0x8e30b2de
    .word 0x8f97b41e
    .word 0x12e1813e
    .word 0x6d3ce1b9
    .word 0x8a8998ee
    .word 0x3aa03ae8
    .word 0xaabbe43d
    .word 0x2556d36f
    .word 0xe86a243e
    .word 0xed9fcc0f
    .word 0x09b2c3e2
    .word 0x066bfa22
    .word 0x5b05b645
    .word 0xcb5713ed
    .word 0xb68e2c06
    .word 0xc461e119
    .word 0x2cd89aed
    .word 0xb56d0486
    .word 0x731ac84a
    .word 0xf288c1cb
    .word 0xfd494a49
    .word 0x73db3e7d
    .word 0x06b48c20
    .word 0x6982ee91
    .word 0x3a95400b
    .word 0xf657871c
    .word 0xffc45202
    .word 0x60c1ca45
    .word 0x61d4062d
    .word 0x3c592cbb
    .word 0xff92a525
    .word 0x7c93710b
    .word 0x35c338ed
    .word 0x48252570
    .word 0x40ec0289
    .word 0x74c3fa5c
    .word 0x454b5f24
    .word 0xd7f1ec5a
    .word 0xb8489536
    .word 0x95c4dc48
    .word 0x3cc849cd
    .word 0xbcaa12f2
    .word 0x173f1fc3
    .word 0xceb5b96d
    .word 0xfc34a79a
    .word 0x82b6f0e8
    .word 0xfca914ff
    .word 0x6c4c7fae
    .word 0xd127f381
    .word 0x4774f9b4
    .word 0x29dfcae7
    .word 0x3bf1e701
    .word 0x65b0381d
    .word 0x7636d4e7
    .word 0xe4ee63eb
    .word 0xac1b838f
    .word 0x740463c8
    .word 0x1ee31ef7
    .word 0x33ca1972
    .word 0xba88dc90
    .word 0x66b778a1
    .word 0x3dfbc4e3
    .word 0x4898314a
    .word 0x0d80f45a
    .word 0x0918372a
    .word 0x040810ee
    .word 0x85557b97
    .word 0xb49116e7
    .word 0xa6966310
    .word 0x7bb87561
    .word 0xec01f0b0
    .word 0xb85ca7e5
    .word 0x6f7282f5
    .word 0x7c71a94f
    .word 0x987e617b
    .word 0xd4afac7d
    .word 0x04fb2f4f
    .word 0x59914654
    .word 0x729030ba
    .word 0x9d7cb3bf
    .word 0x3a9c35c8
    .word 0x85c1d468
    .word 0x27ffd745
    .word 0xa9060160
    .word 0x7668611e
    .word 0xe24c310c
    .word 0x8214ab5e
    .word 0x6677628c
    .word 0x09e3fe4a
    .word 0xef6f1cdf
    .word 0xc838a612
    .word 0x7b800d55
    .word 0x14c62638
    .word 0x5549c8e0
    .word 0x10b3d4da
    .word 0x771df23a
    .word 0x192568dd
    .word 0x5cf77a3c
    .word 0xefbd38a3
    .word 0xaf4b6d2a
    .word 0x9ccfa74b
    .word 0xee4529e4
    .word 0xe1d8c844
    .word 0x4ca2d104
    .word 0xc446085d
    .word 0x7dc931ec
    .word 0xa220799a
    .word 0x44ae3b91
    .word 0x9c22008e
    .word 0xd9dcd8b2
    .word 0x861b0985
    .word 0x415a4bc5
    .word 0xec155b8d
    .word 0x51037bd6
    .word 0x4897623d
    .word 0xd7a4fa0e
    .word 0x71b6e078
    .word 0x43000a76
    .word 0xc84dc2f7
    .word 0xe3945d07
    .word 0x5aa42297
    .word 0xa3ef6cc4
    .word 0x876cbc53
    .word 0x65ee185c
    .word 0xd5929cd1
    .word 0x5706bc98
    .word 0x10d99b93
    .word 0x6cb66f20
    .word 0xa9f491a1
    .word 0x83f162e7
    .word 0x07a8c232
    .word 0xa206ca18
    .word 0xb73cc374
    .word 0xdccb5c3b
    .word 0xbf870e22
    .word 0xa9778aa8
    .word 0x5d1f0a90
    .word 0x5c17a793
    .word 0x06b46c82
    .word 0x425e8bae
    .word 0x566cc9dc

#include "frost_footer.S"
