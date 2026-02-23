// Generated RV32IMAFDC torture test for Frost (seed=44)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xdcae6e9f
    li x4, 0x2d39f5ab
    li x5, 0x39a40dfe
    li x6, 0x0772eaea
    li x7, 0x024115e4
    li x8, 0xfd4f6854
    li x9, 0x537c9792
    li x10, 0x12d465da
    li x11, 0xd76e0b6f
    li x12, 0x9e022098
    li x13, 0x183982d2
    li x14, 0xf57bfe7b
    li x15, 0xf8359314
    li x16, 0x08f5fa74
    li x17, 0x62c8f4c1
    li x18, 0x7a2f15f0
    li x19, 0xeab94480
    li x20, 0x3047a452
    li x21, 0x0c98ae86
    li x22, 0x542297bb
    li x23, 0xd49a72b4
    li x24, 0xa16c4327
    li x25, 0x8a602252
    li x26, 0x3bb70669
    li x27, 0x0b2ae3a0
    li x28, 0x2842cc58
    li x29, 0x8b0f441e
    li x30, 0x32f4bdb0
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
    li x1, 0x1c8c857b

    addi x16, x27, -1655
    bge x6, x7, _br_taken_0
    add x8, x22, x23
    j _br_done_0
_br_taken_0:
    sra x8, x23, x5
_br_done_0:
    sll x25, x19, x23
    beq x11, x18, _br_taken_1
    sub x11, x19, x27
    j _br_done_1
_br_taken_1:
    sltu x11, x13, x20
_br_done_1:
    beq x12, x18, _br_taken_2
    or x12, x15, x12
    j _br_done_2
_br_taken_2:
    slt x12, x17, x5
_br_done_2:
    srli x5, x17, 25
    bge x5, x11, _br_taken_3
    sll x21, x11, x26
    j _br_done_3
_br_taken_3:
    slt x21, x19, x29
_br_done_3:
    sltiu x18, x5, 177
    fmul.d f8, f14, f23
    fmul.s f31, f9, f0
    fmax.d f25, f24, f28
    addi x13, x12, -1935
    lw x22, 432(x31)
    sw x7, 432(x31)
    sub x15, x20, x19
    sra x29, x23, x8
    slli x13, x20, 20
    addi x6, x31, 420
    amoxor.w x1, x4, (x6)
    slt x6, x30, x28
    andi x15, x29, 1021
    sra x7, x12, x11
    bne x24, x8, _br_taken_4
    sll x18, x12, x17
    j _br_done_4
_br_taken_4:
    xor x18, x18, x12
_br_done_4:
    bgeu x21, x17, _br_taken_5
    or x18, x18, x17
    j _br_done_5
_br_taken_5:
    sub x18, x28, x25
_br_done_5:
    srl x18, x23, x27
    or x16, x12, x4
    addi x1, x31, 196
    amomaxu.w x25, x16, (x1)
    sll x27, x23, x9
    ori x24, x25, 734
    add x21, x21, x4
    sltu x13, x29, x24
    and x8, x4, x28
    addi x25, x5, 489
    add x10, x19, x1
    slt x27, x25, x20
    slt x13, x17, x10
    sltiu x18, x1, -1684
    add x29, x26, x20
    beq x28, x22, _br_taken_6
    srl x27, x23, x22
    j _br_done_6
_br_taken_6:
    sltu x27, x20, x16
_br_done_6:
    lb x15, 108(x31)
    sb x18, 108(x31)
    addi x9, x31, 272
    amomaxu.w x15, x6, (x9)
    slt x13, x5, x22
    sltiu x1, x13, -441
    xori x7, x1, 1190
    srl x27, x21, x13
    or x30, x13, x4
    sltiu x11, x21, 956
    add x18, x27, x18
    bgeu x6, x11, _br_taken_7
    srl x12, x26, x27
    j _br_done_7
_br_taken_7:
    sra x12, x21, x22
_br_done_7:
    lb x17, 432(x31)
    sb x1, 432(x31)
    addi x13, x31, 464
    amomax.w x12, x10, (x13)
    sub x16, x18, x20
    mulhu x25, x20, x30
    srli x15, x12, 25
    add x14, x11, x5
    addi x27, x31, 44
    amoswap.w x20, x14, (x27)
    slti x14, x24, -737
    sll x11, x18, x26
    xori x4, x28, 116
    lbu x13, 0(x31)
    sb x15, 0(x31)
    slti x23, x11, -490
    ori x16, x30, 1424
    sra x1, x16, x27
    xor x15, x17, x27
    srai x9, x13, 23
    slt x18, x12, x19
    xori x12, x1, 1477
    sll x22, x17, x24
    sra x6, x19, x4
    sub x4, x8, x7
    and x4, x25, x9
    addi x26, x20, -97
    add x4, x8, x6
    srai x14, x14, 8
    slli x18, x4, 3
    xori x14, x24, 1590
    sltiu x12, x1, 1761
    sll x13, x11, x26
    sub x20, x24, x25
    xori x12, x21, 1280
    beq x15, x7, _br_taken_8
    sub x26, x28, x17
    j _br_done_8
_br_taken_8:
    srl x26, x28, x4
_br_done_8:
    lw x26, 176(x31)
    sw x8, 176(x31)
    addi x11, x4, 1414
    slli x22, x25, 22
    andi x10, x7, -838
    slli x8, x6, 16
    sub x28, x10, x7
    mul x15, x6, x26
    div x30, x10, x22
    sra x15, x25, x21
    srai x10, x27, 10
    add x26, x11, x26
    addi x22, x13, -859
    add x12, x21, x14
    xori x16, x21, 1497
    sltu x22, x15, x14
    bltu x29, x19, _br_taken_9
    add x16, x16, x4
    j _br_done_9
_br_taken_9:
    or x16, x17, x23
_br_done_9:
    or x10, x26, x24
    sll x28, x30, x28
    srli x8, x7, 28
    bgeu x5, x18, _br_taken_10
    sltu x4, x19, x30
    j _br_done_10
_br_taken_10:
    slt x4, x29, x11
_br_done_10:
    lh x28, 792(x31)
    sh x1, 792(x31)
    srli x22, x14, 25
    slti x14, x5, -1858
    slli x8, x28, 18
    sra x9, x26, x10
    and x27, x15, x16
    slli x30, x17, 30
    fmsub.s f20, f4, f30, f1
    sltu x26, x30, x26
    srai x13, x17, 20
    or x13, x9, x24
    slti x15, x4, 344
    or x27, x16, x20
    slli x25, x13, 21
    sltiu x20, x1, -629
    sub x27, x22, x11
    srai x20, x16, 11
    addi x4, x9, 1861
    lw x20, 968(x31)
    sw x14, 968(x31)
    bltu x21, x30, _br_taken_11
    add x9, x23, x14
    j _br_done_11
_br_taken_11:
    add x9, x24, x13
_br_done_11:
    slt x19, x11, x30
    sub x16, x13, x1
    srli x28, x27, 27
    bge x18, x19, _br_taken_12
    and x7, x13, x9
    j _br_done_12
_br_taken_12:
    xor x7, x21, x25
_br_done_12:
    fmul.d f31, f11, f25
    fnmadd.d f1, f31, f0, f29
    fadd.s f20, f20, f10
    bltu x15, x12, _br_taken_13
    sll x27, x29, x12
    j _br_done_13
_br_taken_13:
    xor x27, x26, x6
_br_done_13:
    sub x28, x9, x25
    ori x1, x25, 1309
    addi x9, x27, 1537
    slti x12, x23, -1536
    sll x22, x13, x21
    sltu x27, x1, x10
    srl x8, x21, x11
    srli x21, x14, 24
    ori x1, x6, 202
    addi x25, x27, 788
    srli x27, x19, 17
    sltu x21, x18, x19
    or x12, x6, x11
    or x26, x9, x16
    divu x9, x13, x26
    slt x24, x28, x4
    sra x25, x8, x22
    add x11, x4, x19
    xori x9, x24, -1273
    slli x1, x14, 31
    blt x30, x21, _br_taken_14
    add x15, x24, x25
    j _br_done_14
_br_taken_14:
    sltu x15, x17, x30
_br_done_14:
    add x13, x28, x26
    fnmsub.d f7, f5, f7, f26
    fmul.d f13, f7, f14
    slli x30, x17, 31
    srl x21, x24, x17
    andi x20, x13, -1584
    blt x26, x13, _br_taken_15
    slt x21, x9, x4
    j _br_done_15
_br_taken_15:
    add x21, x23, x18
_br_done_15:
    srl x27, x12, x8
    slli x6, x22, 5
    xori x7, x19, -607
    ori x13, x6, 458
    and x10, x4, x25
    lw x29, 632(x31)
    sw x6, 632(x31)
    mulh x21, x9, x9
    sltu x7, x13, x10
    fadd.d f5, f29, f19
    fmax.s f21, f1, f30
    fmul.d f11, f9, f25
    and x4, x26, x21
    xor x13, x28, x20
    slti x11, x16, 863
    sub x27, x22, x20
    bltu x27, x18, _br_taken_16
    slt x23, x1, x9
    j _br_done_16
_br_taken_16:
    sltu x23, x9, x28
_br_done_16:
    sltiu x27, x23, 1248
    andi x4, x28, -1706
    slli x8, x28, 3
    or x30, x28, x6
    sra x21, x30, x14
    mulhsu x23, x5, x12
    rem x17, x7, x10
    srli x26, x4, 22
    ori x7, x15, -1208
    srli x29, x5, 21
    and x13, x25, x19
    andi x14, x10, 1188
    and x5, x9, x29
    div x4, x1, x11
    div x20, x13, x26
    bltu x9, x6, _br_taken_17
    xor x4, x29, x29
    j _br_done_17
_br_taken_17:
    sub x4, x14, x15
_br_done_17:
    and x1, x16, x13
    slti x25, x18, -592
    srai x16, x7, 27
    srai x24, x11, 15
    rem x21, x13, x17
    mulhu x22, x24, x23
    xori x27, x10, 636
    ori x5, x8, -1097
    ori x22, x19, -423
    andi x30, x27, 1615
    sub x27, x27, x24
    bgeu x7, x5, _br_taken_18
    xor x19, x28, x30
    j _br_done_18
_br_taken_18:
    or x19, x14, x30
_br_done_18:
    addi x20, x31, 608
    amominu.w x27, x12, (x20)
    add x14, x6, x11
    fmax.d f5, f28, f8
    fmul.d f6, f29, f2
    xor x6, x24, x30
    ori x29, x12, 782
    sra x21, x25, x8
    addi x15, x25, -599
    srai x14, x14, 11
    xori x27, x14, -229
    add x15, x25, x21
    addi x16, x31, 636
    amomaxu.w x17, x18, (x16)
    addi x9, x31, 308
    amoadd.w x1, x21, (x9)
    remu x27, x29, x23
    mulhu x4, x20, x9
    and x26, x7, x1
    sra x26, x19, x9
    srl x9, x6, x10
    xori x5, x29, 1219
    lw x30, 856(x31)
    sw x8, 856(x31)
    sltu x30, x26, x19
    sltu x9, x12, x15
    lbu x10, 784(x31)
    sb x8, 784(x31)
    fsub.d f10, f1, f27
    fmul.s f30, f21, f6
    fdiv.s f1, f16, f4
    fnmsub.s f22, f15, f5, f2
    fmax.s f26, f31, f18
    fadd.s f2, f6, f31
    addi x17, x4, -124
    bgeu x9, x8, _br_taken_19
    slt x7, x9, x15
    j _br_done_19
_br_taken_19:
    and x7, x25, x18
_br_done_19:
    lbu x12, 204(x31)
    sb x14, 204(x31)
    bne x26, x9, _br_taken_20
    or x10, x28, x19
    j _br_done_20
_br_taken_20:
    sub x10, x21, x18
_br_done_20:
    sltu x29, x16, x24
    add x12, x13, x12
    lw x30, 704(x31)
    sw x12, 704(x31)
    bltu x30, x21, _br_taken_21
    slt x4, x13, x25
    j _br_done_21
_br_taken_21:
    add x4, x30, x10
_br_done_21:
    and x30, x17, x22
    andi x5, x10, 1708
    mulhsu x30, x17, x26
    andi x16, x16, -2002
    addi x30, x31, 360
    amoor.w x25, x17, (x30)
    fmul.s f26, f8, f25
    fmax.d f13, f2, f1
    bge x25, x28, _br_taken_22
    add x28, x12, x26
    j _br_done_22
_br_taken_22:
    xor x28, x17, x9
_br_done_22:
    addi x18, x5, 234
    sra x10, x20, x14
    xor x29, x24, x15
    addi x9, x30, -713
    sll x8, x18, x6
    xori x29, x20, -1058
    sltu x24, x27, x19
    srai x6, x14, 1
    sra x21, x30, x6
    srli x5, x17, 16
    srli x30, x4, 29
    xor x12, x24, x27
    sltu x8, x12, x15
    bltu x19, x18, _br_taken_23
    srl x9, x29, x7
    j _br_done_23
_br_taken_23:
    sub x9, x1, x19
_br_done_23:
    and x18, x28, x21
    blt x26, x19, _br_taken_24
    xor x19, x12, x30
    j _br_done_24
_br_taken_24:
    sll x19, x11, x14
_br_done_24:
    sll x6, x28, x26
    xori x17, x8, -1914
    xor x24, x13, x1
    bne x20, x10, _br_taken_25
    sub x5, x27, x8
    j _br_done_25
_br_taken_25:
    slt x5, x14, x30
_br_done_25:
    sra x9, x7, x30
    xori x21, x8, 1366
    xor x22, x17, x11
    fdiv.d f24, f3, f16
    fmin.s f11, f23, f25
    fmul.d f27, f2, f13
    xor x7, x16, x13
    srl x17, x12, x19
    bge x28, x29, _br_taken_26
    or x11, x16, x9
    j _br_done_26
_br_taken_26:
    xor x11, x21, x15
_br_done_26:
    fmul.s f5, f23, f23
    fmadd.s f13, f30, f21, f29
    fnmadd.s f18, f18, f4, f14
    srl x8, x24, x4
    xori x19, x14, -360
    lb x11, 500(x31)
    sb x11, 500(x31)
    add x20, x6, x14
    addi x7, x31, 664
    amoor.w x18, x21, (x7)
    andi x18, x22, 174
    addi x18, x31, 900
    amoadd.w x1, x1, (x18)
    xori x25, x24, 935
    slti x6, x5, 1746
    slti x24, x5, 778
    xori x6, x17, -1098
    slli x26, x23, 7
    beq x25, x9, _br_taken_27
    srl x7, x12, x8
    j _br_done_27
_br_taken_27:
    slt x7, x27, x12
_br_done_27:
    ori x26, x25, -1398
    addi x21, x20, 598
    sra x22, x17, x24
    bge x25, x12, _br_taken_28
    xor x21, x20, x13
    j _br_done_28
_br_taken_28:
    srl x21, x23, x10
_br_done_28:
    bltu x14, x13, _br_taken_29
    or x11, x5, x12
    j _br_done_29
_br_taken_29:
    sll x11, x1, x12
_br_done_29:
    lbu x20, 172(x31)
    sb x9, 172(x31)
    beq x22, x28, _br_taken_30
    sra x14, x16, x13
    j _br_done_30
_br_taken_30:
    sra x14, x29, x14
_br_done_30:
    beq x5, x13, _br_taken_31
    slt x10, x29, x20
    j _br_done_31
_br_taken_31:
    or x10, x7, x21
_br_done_31:
    beq x22, x12, _br_taken_32
    and x29, x14, x16
    j _br_done_32
_br_taken_32:
    slt x29, x23, x4
_br_done_32:
    slti x4, x21, -1386
    srli x12, x26, 1
    fdiv.s f27, f26, f27
    add x11, x29, x23
    slt x14, x27, x24
    bgeu x13, x19, _br_taken_33
    add x18, x13, x19
    j _br_done_33
_br_taken_33:
    add x18, x14, x6
_br_done_33:
    sll x9, x7, x12
    and x30, x29, x11
    fdiv.d f18, f19, f7
    fadd.d f18, f15, f9
    bge x24, x9, _br_taken_34
    sra x29, x29, x17
    j _br_done_34
_br_taken_34:
    xor x29, x21, x4
_br_done_34:
    or x1, x13, x6
    xor x22, x15, x18
    or x29, x29, x18
    addi x6, x19, 371
    slti x16, x11, 122
    blt x29, x19, _br_taken_35
    sra x23, x23, x20
    j _br_done_35
_br_taken_35:
    srl x23, x4, x29
_br_done_35:
    ori x29, x7, 838
    sra x5, x23, x15
    slt x27, x30, x30
    add x15, x29, x8
    ori x24, x19, 913
    fadd.s f1, f27, f21
    fdiv.d f31, f5, f24
    and x26, x13, x29
    slti x30, x11, -445
    and x4, x19, x26
    rem x27, x10, x6
    divu x14, x25, x6
    bgeu x1, x20, _br_taken_36
    sll x19, x18, x18
    j _br_done_36
_br_taken_36:
    add x19, x28, x7
_br_done_36:
    fmax.s f24, f5, f14
    divu x20, x28, x9
    sll x4, x24, x29

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x9d8de68f154ad713
    .dword 0x20821300c799e96b
    .dword 0x7203cc60ac7aaa46
    .dword 0x8f86a23f652af371
    .dword 0xcbd09ed20ad042b0
    .dword 0xa5a27c710d266f48
    .dword 0x2eedf951a9223c0e
    .dword 0xd723e9b850fb7ac1
    .dword 0x164741652f4971d9
    .dword 0xa7a3a2728d696f49
    .dword 0x9c4da33833b8d70d
    .dword 0x856157161b5d3ea8
    .dword 0xafff086589c97949
    .dword 0xfd86cf672f3710a3
    .dword 0xbf672da1836207fd
    .dword 0xfc58aa11deb1e5a6
    .dword 0xa979d9117a04d650
    .dword 0xf36e42ea37c7bd6a
    .dword 0x42d11a106f69652e
    .dword 0xfd42ee757e385b06
    .dword 0xf493950288e19a27
    .dword 0xd102c9e4a686cc7f
    .dword 0x93f884dd153cd6fb
    .dword 0xba2a6d04aaa580dc
    .dword 0x59be47aa49062736
    .dword 0x4163ff1c7a11d089
    .dword 0x6d1831e385cb551f
    .dword 0xe0a6e61f1b44e316
    .dword 0x47c3763a92f56d53
    .dword 0xabbea6e1285b2c80
    .dword 0xc57bcde177f00733
    .dword 0x8d5829a11d98508d

    .align 2
_torture_data:
    .word 0x1eece816
    .word 0x0932ec41
    .word 0x5d631a80
    .word 0xa254c1d6
    .word 0xc1cd1334
    .word 0x7606b751
    .word 0xc43a8a40
    .word 0x8b952abc
    .word 0x036bb30c
    .word 0xc3a1a3a6
    .word 0x297c954d
    .word 0x501e4c70
    .word 0xd73d84ea
    .word 0x17eceede
    .word 0xc8e83840
    .word 0xa63b8b31
    .word 0x3ade47ec
    .word 0xb3593ee7
    .word 0x7614e482
    .word 0x2a343930
    .word 0xdc7ebf15
    .word 0x88d57af7
    .word 0xf3274e2a
    .word 0x66db4691
    .word 0x2b6c8e0b
    .word 0x62edfbb2
    .word 0x95315861
    .word 0xc4b5fe81
    .word 0x4abf2efe
    .word 0xf2f19421
    .word 0x73ed0155
    .word 0x1d958d9c
    .word 0xe857ac15
    .word 0x8194f3d1
    .word 0x793cecf2
    .word 0x3b7616db
    .word 0xfcadc364
    .word 0x288b454e
    .word 0xaf07f85b
    .word 0xbaedccb9
    .word 0xb4c82b25
    .word 0x3ca94ed2
    .word 0x298d7ba7
    .word 0xec37e592
    .word 0x72694ea1
    .word 0x0b3616f7
    .word 0xa330d430
    .word 0xf983c9f3
    .word 0xa17e79dd
    .word 0x16ffea70
    .word 0x19b27ba4
    .word 0x46fa1e8e
    .word 0xad17fc5d
    .word 0x19a5ce73
    .word 0x260afd53
    .word 0xff435174
    .word 0x21107030
    .word 0x6b1ff5ed
    .word 0xb9487cdd
    .word 0xa2e9c82e
    .word 0x8c8c1d9e
    .word 0x0f9bb3b8
    .word 0x5f4bba3a
    .word 0x3d10cfc1
    .word 0xb2e8ae4f
    .word 0x5bdccfe0
    .word 0x291001a3
    .word 0x9d935ec3
    .word 0x1d53445b
    .word 0x46c48ebb
    .word 0x0a36f919
    .word 0x18636f59
    .word 0xe78c64cb
    .word 0xdd122539
    .word 0xce047bf1
    .word 0x981385c3
    .word 0x43b0c6f6
    .word 0x9fb09618
    .word 0xff8b5385
    .word 0xc74ff2f5
    .word 0x61ff43d5
    .word 0x7b7790a7
    .word 0x363160ad
    .word 0xf5c068e5
    .word 0xf3cd65d5
    .word 0xaef84be1
    .word 0xae88d3fb
    .word 0x4fe1e54b
    .word 0x6bcdb77b
    .word 0x6505363a
    .word 0x7777092c
    .word 0xfabc7324
    .word 0xba6ed007
    .word 0x0fc2f7df
    .word 0x8c227145
    .word 0xc1a5e803
    .word 0xa5b47def
    .word 0xa8f05e8a
    .word 0x6d79cba6
    .word 0x3d4351cf
    .word 0x858b04af
    .word 0xf6d9958f
    .word 0xeee02a7f
    .word 0x33c6de1a
    .word 0x35238987
    .word 0x9d1beb00
    .word 0x95bfa6f2
    .word 0x50c6c196
    .word 0xf662d2f0
    .word 0xa107c6e9
    .word 0x40a9e40d
    .word 0x7992a419
    .word 0x793b0d64
    .word 0xdd4d9680
    .word 0x52333992
    .word 0xe88d6275
    .word 0x87a3de85
    .word 0xc5c05658
    .word 0x682dd7bc
    .word 0xaccca4f7
    .word 0x1b2cbe68
    .word 0xbdc1bc69
    .word 0x7336aca3
    .word 0x3d4125b2
    .word 0xbd13a6c1
    .word 0x1358f0c7
    .word 0x332f6816
    .word 0x8bdaa5b3
    .word 0xecc0e4d5
    .word 0xac99c273
    .word 0xef80edfd
    .word 0x0d601cde
    .word 0xf3c375d3
    .word 0x5f2e6986
    .word 0xaeb3db9d
    .word 0x2df319f7
    .word 0x4688fa69
    .word 0x302d9666
    .word 0xa5137320
    .word 0x075741ff
    .word 0x5ebf7804
    .word 0x8f8b60ff
    .word 0xecc78f62
    .word 0xefcd9f44
    .word 0x06056011
    .word 0x899226ec
    .word 0xdb71a343
    .word 0x797222ab
    .word 0xfa763be6
    .word 0xca01a96b
    .word 0x06836f0f
    .word 0x86349e74
    .word 0x5f13a612
    .word 0xdf1d2d37
    .word 0xe9e39021
    .word 0x1d0e9a4f
    .word 0xd97253d3
    .word 0x717baac2
    .word 0x5f486231
    .word 0xf3fa0993
    .word 0xa8551b1b
    .word 0xe30e2bf8
    .word 0x84252ede
    .word 0x38850ca1
    .word 0xfbae821e
    .word 0x91a6e186
    .word 0xfdc4f2b8
    .word 0xe95f59e7
    .word 0x891fa69b
    .word 0xab7caf69
    .word 0x70d82e99
    .word 0x2dca726a
    .word 0xba8d803b
    .word 0xd2bdd663
    .word 0xfa9dd028
    .word 0x0b6d8b94
    .word 0x9e705321
    .word 0x595bddd6
    .word 0x897ef32b
    .word 0xe3cf8f73
    .word 0x3eb740c9
    .word 0xc1922a11
    .word 0x1524cb9e
    .word 0x705dc9d1
    .word 0x13ae6662
    .word 0xd852982d
    .word 0x2e9a3e62
    .word 0x3324fd90
    .word 0x8e0c4718
    .word 0x4d4dfcb1
    .word 0xdceab74e
    .word 0x8dd076b4
    .word 0x7a8874af
    .word 0x8a2a7f0d
    .word 0xdeba3018
    .word 0xa207284e
    .word 0x78d00b06
    .word 0x5d1f5cc1
    .word 0xf6f04c60
    .word 0x7ffe0adb
    .word 0x98d5b80a
    .word 0x1fea204c
    .word 0xc4d5ae36
    .word 0x8a991b27
    .word 0x0956837a
    .word 0xee1e4e10
    .word 0xaf25499e
    .word 0xac132269
    .word 0xc67b2212
    .word 0xe57d5f3b
    .word 0x12d5f317
    .word 0x8c3114a0
    .word 0x151430ea
    .word 0xbb2fd8d9
    .word 0xd9a6a6c1
    .word 0x8f7ce558
    .word 0x3c1ae75e
    .word 0xadd19e31
    .word 0xd000c49e
    .word 0x1fbabc1b
    .word 0xa84c6488
    .word 0xa95c73cb
    .word 0x654b03b4
    .word 0xb5a51eeb
    .word 0x82790d6b
    .word 0x1716d67d
    .word 0x83ab9573
    .word 0x6474a9bd
    .word 0xcfe1e6d0
    .word 0x652112e4
    .word 0xe2a77769
    .word 0x4f503ada
    .word 0x5284003b
    .word 0x828da8ea
    .word 0xbf6b9f3f
    .word 0xdd4a81da
    .word 0x8a8beacd
    .word 0x0d1100e9
    .word 0x3991e583
    .word 0xe8fa2055
    .word 0xb72fd682
    .word 0x4cf2cf07
    .word 0xb4d91b20
    .word 0x77e415d4
    .word 0x5441e86f
    .word 0xda8658a6
    .word 0x63ff6380
    .word 0x9caaeccb
    .word 0x21be65fc
    .word 0x655fec37
    .word 0x3f5935b4
    .word 0x2aceecce
    .word 0xa35d5bc6
    .word 0xe68749e5
    .word 0xcd1a61e8
    .word 0x9185b5c2

#include "frost_footer.S"
