// Generated RV32IMAFDC torture test for Frost (seed=58)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x94ac807a
    li x4, 0xf24cdea7
    li x5, 0x0a8c81db
    li x6, 0x730bda74
    li x7, 0xe07e1ef7
    li x8, 0xf77badff
    li x9, 0x6b4596fd
    li x10, 0x1ac7ad0a
    li x11, 0x7d599072
    li x12, 0x12cd0706
    li x13, 0x5e2a4901
    li x14, 0x227b276d
    li x15, 0x08df1cf5
    li x16, 0xde3cbdbd
    li x17, 0x4f6e3ad7
    li x18, 0xb9d3cee8
    li x19, 0xe9d4f88b
    li x20, 0x28a2a5a8
    li x21, 0x72c46d9d
    li x22, 0x214d823d
    li x23, 0x3a365a26
    li x24, 0xb80505e3
    li x25, 0x96e2e331
    li x26, 0x6661e30f
    li x27, 0x49131c24
    li x28, 0x347a2d37
    li x29, 0xe76556de
    li x30, 0x9c1f053e
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
    li x1, 0x9eb45fca

    sra x13, x25, x17
    sub x7, x4, x19
    sra x4, x4, x9
    slli x4, x18, 3
    lbu x24, 572(x31)
    sb x18, 572(x31)
    ori x5, x28, -982
    and x16, x6, x26
    slti x7, x9, -277
    addi x7, x21, -1586
    xor x5, x23, x26
    add x19, x15, x22
    addi x5, x31, 856
    amominu.w x17, x28, (x5)
    srai x28, x15, 8
    slli x27, x8, 24
    addi x25, x9, -1153
    lbu x12, 484(x31)
    sb x27, 484(x31)
    mul x8, x12, x6
    div x6, x16, x1
    srai x18, x11, 6
    slli x6, x7, 21
    srl x17, x29, x12
    ori x5, x30, 1264
    bgeu x13, x1, _br_taken_0
    and x7, x8, x5
    j _br_done_0
_br_taken_0:
    sltu x7, x13, x19
_br_done_0:
    srl x10, x14, x10
    addi x17, x19, 1812
    slti x8, x30, -1794
    and x22, x30, x28
    sll x9, x17, x24
    ori x16, x19, 1742
    slli x29, x11, 0
    slli x28, x13, 6
    sra x26, x14, x10
    fsub.s f28, f23, f29
    srl x17, x19, x5
    slt x26, x28, x20
    remu x7, x19, x16
    addi x26, x31, 664
    amominu.w x25, x14, (x26)
    bltu x1, x30, _br_taken_1
    add x8, x15, x23
    j _br_done_1
_br_taken_1:
    xor x8, x12, x4
_br_done_1:
    srli x19, x12, 17
    sll x14, x25, x17
    andi x9, x4, -875
    remu x17, x28, x16
    and x6, x24, x4
    srai x6, x16, 11
    slli x15, x11, 23
    sll x13, x8, x15
    bltu x15, x4, _br_taken_2
    sltu x9, x15, x7
    j _br_done_2
_br_taken_2:
    sra x9, x1, x26
_br_done_2:
    fmax.s f30, f3, f12
    fmsub.d f29, f3, f28, f3
    addi x15, x31, 64
    amomin.w x6, x9, (x15)
    beq x20, x13, _br_taken_3
    sra x26, x24, x13
    j _br_done_3
_br_taken_3:
    sll x26, x10, x1
_br_done_3:
    slt x29, x5, x11
    add x6, x19, x25
    slli x29, x6, 24
    bne x14, x16, _br_taken_4
    sra x24, x17, x6
    j _br_done_4
_br_taken_4:
    and x24, x22, x18
_br_done_4:
    lh x16, 768(x31)
    sh x17, 768(x31)
    xori x23, x8, 1758
    srai x7, x27, 12
    bltu x24, x10, _br_taken_5
    slt x9, x10, x1
    j _br_done_5
_br_taken_5:
    sra x9, x26, x7
_br_done_5:
    sltu x16, x25, x30
    xori x18, x7, -156
    fdiv.d f18, f30, f16
    fmsub.d f12, f28, f20, f8
    bge x22, x1, _br_taken_6
    xor x16, x28, x13
    j _br_done_6
_br_taken_6:
    sltu x16, x8, x27
_br_done_6:
    mul x12, x11, x22
    mul x15, x16, x14
    fnmadd.s f27, f18, f24, f12
    fdiv.s f27, f17, f18
    fmax.d f0, f25, f19
    sra x29, x30, x21
    andi x27, x21, -1743
    andi x5, x4, 407
    bgeu x16, x6, _br_taken_7
    sub x21, x19, x9
    j _br_done_7
_br_taken_7:
    xor x21, x13, x23
_br_done_7:
    lw x14, 388(x31)
    sw x27, 388(x31)
    bge x10, x22, _br_taken_8
    sub x5, x13, x15
    j _br_done_8
_br_taken_8:
    xor x5, x8, x22
_br_done_8:
    or x19, x16, x6
    sub x10, x28, x22
    sll x7, x8, x16
    lhu x23, 724(x31)
    sh x26, 724(x31)
    slt x22, x21, x13
    srl x18, x19, x9
    ori x24, x10, -1219
    bgeu x1, x17, _br_taken_9
    srl x23, x15, x13
    j _br_done_9
_br_taken_9:
    sub x23, x19, x28
_br_done_9:
    andi x25, x26, -693
    slti x24, x15, -1244
    and x29, x22, x9
    srli x12, x16, 20
    slt x30, x30, x12
    add x26, x13, x23
    addi x13, x31, 844
    amoxor.w x24, x17, (x13)
    bne x17, x15, _br_taken_10
    sll x20, x25, x25
    j _br_done_10
_br_taken_10:
    slt x20, x7, x26
_br_done_10:
    addi x21, x31, 460
    amomin.w x20, x17, (x21)
    bge x17, x17, _br_taken_11
    and x26, x23, x19
    j _br_done_11
_br_taken_11:
    xor x26, x12, x10
_br_done_11:
    bge x8, x1, _br_taken_12
    sub x11, x20, x27
    j _br_done_12
_br_taken_12:
    slt x11, x24, x12
_br_done_12:
    addi x27, x11, 737
    ori x25, x6, -970
    sll x27, x4, x6
    ori x16, x22, 1243
    or x1, x1, x1
    slt x17, x9, x29
    or x30, x4, x1
    xor x8, x28, x15
    srli x11, x26, 20
    sra x1, x17, x20
    srli x22, x25, 16
    xori x23, x20, 919
    slt x16, x1, x24
    sltiu x26, x28, -97
    slli x1, x29, 10
    slti x15, x10, -1300
    slt x8, x18, x29
    xori x7, x22, -1266
    sltu x14, x14, x30
    sra x23, x6, x21
    sltiu x18, x11, -1495
    sub x21, x9, x18
    srai x7, x19, 3
    lb x9, 528(x31)
    sb x18, 528(x31)
    sra x29, x16, x20
    sub x17, x26, x9
    sll x16, x9, x9
    addi x25, x30, -1256
    sll x7, x19, x23
    fmax.s f10, f14, f21
    fnmsub.s f20, f7, f23, f23
    bne x29, x21, _br_taken_13
    slt x5, x9, x16
    j _br_done_13
_br_taken_13:
    add x5, x26, x4
_br_done_13:
    ori x23, x11, 686
    slti x10, x25, -321
    addi x23, x1, -4
    bgeu x29, x27, _br_taken_14
    add x4, x21, x17
    j _br_done_14
_br_taken_14:
    sltu x4, x23, x25
_br_done_14:
    sltiu x7, x12, -2046
    sra x24, x15, x6
    slt x22, x15, x13
    fmadd.d f18, f29, f6, f15
    fmul.s f5, f18, f27
    fnmadd.d f30, f30, f14, f15
    sltu x11, x8, x27
    srl x29, x23, x21
    srli x10, x10, 3
    rem x23, x19, x26
    remu x14, x14, x5
    srai x14, x11, 23
    slt x20, x18, x30
    fnmadd.s f16, f24, f9, f7
    srli x23, x16, 14
    sll x8, x6, x25
    addi x28, x31, 376
    amoor.w x20, x17, (x28)
    sub x15, x21, x28
    srl x10, x29, x27
    andi x27, x26, 1339
    slti x16, x23, 1060
    bge x28, x26, _br_taken_15
    or x6, x22, x25
    j _br_done_15
_br_taken_15:
    and x6, x13, x8
_br_done_15:
    sltu x30, x24, x9
    ori x11, x25, -616
    or x16, x19, x18
    xori x26, x9, 158
    srai x10, x29, 6
    bgeu x5, x12, _br_taken_16
    and x17, x17, x28
    j _br_done_16
_br_taken_16:
    sltu x17, x5, x15
_br_done_16:
    addi x9, x10, 112
    add x5, x18, x28
    addi x17, x7, -987
    or x7, x12, x21
    or x9, x22, x26
    fmax.s f14, f27, f8
    fmadd.d f27, f4, f0, f23
    fmul.s f15, f26, f18
    bltu x24, x8, _br_taken_17
    xor x18, x20, x17
    j _br_done_17
_br_taken_17:
    sltu x18, x24, x9
_br_done_17:
    sll x4, x17, x9
    sra x8, x21, x15
    and x17, x20, x9
    slti x10, x24, -1488
    slli x22, x18, 4
    srai x16, x6, 20
    lb x21, 404(x31)
    sb x21, 404(x31)
    lbu x26, 360(x31)
    sb x21, 360(x31)
    addi x6, x31, 864
    amominu.w x30, x4, (x6)
    sltiu x1, x11, 780
    sltiu x23, x6, -567
    srli x20, x25, 5
    mulhu x10, x19, x16
    srl x28, x21, x26
    andi x15, x28, 813
    sra x22, x7, x13
    lhu x8, 864(x31)
    sh x30, 864(x31)
    bgeu x13, x10, _br_taken_18
    sltu x13, x30, x26
    j _br_done_18
_br_taken_18:
    sra x13, x20, x7
_br_done_18:
    sll x10, x4, x16
    bge x1, x8, _br_taken_19
    sltu x7, x19, x18
    j _br_done_19
_br_taken_19:
    sltu x7, x15, x19
_br_done_19:
    lw x26, 824(x31)
    sw x7, 824(x31)
    or x21, x26, x24
    andi x9, x21, 1227
    or x8, x24, x6
    sltu x28, x28, x23
    or x24, x6, x18
    srli x11, x10, 11
    bge x5, x9, _br_taken_20
    sll x4, x4, x11
    j _br_done_20
_br_taken_20:
    or x4, x28, x7
_br_done_20:
    addi x4, x26, -1389
    andi x30, x27, 104
    or x21, x23, x1
    sra x21, x30, x15
    xor x30, x14, x21
    addi x21, x5, 1720
    sub x28, x19, x14
    lw x12, 956(x31)
    sw x26, 956(x31)
    and x30, x22, x11
    slti x24, x13, 184
    xor x14, x9, x21
    and x5, x17, x22
    sll x1, x21, x25
    bge x8, x20, _br_taken_21
    sll x4, x29, x30
    j _br_done_21
_br_taken_21:
    slt x4, x27, x14
_br_done_21:
    or x29, x14, x18
    sub x5, x23, x20
    or x9, x17, x1
    or x10, x26, x8
    lw x15, 456(x31)
    sw x9, 456(x31)
    add x23, x25, x19
    srai x17, x26, 7
    ori x19, x18, -278
    or x6, x15, x25
    mulhsu x23, x7, x5
    beq x17, x4, _br_taken_22
    add x22, x24, x10
    j _br_done_22
_br_taken_22:
    add x22, x22, x5
_br_done_22:
    addi x23, x31, 32
    amoxor.w x5, x4, (x23)
    beq x25, x17, _br_taken_23
    xor x23, x30, x27
    j _br_done_23
_br_taken_23:
    sub x23, x1, x16
_br_done_23:
    sll x17, x4, x11
    and x16, x4, x1
    and x27, x9, x7
    slti x15, x20, 1840
    xori x10, x23, 1950
    xori x17, x9, -1580
    addi x5, x27, 736
    slt x12, x9, x10
    mul x25, x30, x15
    mulhsu x17, x27, x15
    sll x23, x21, x27
    srl x15, x22, x10
    bge x4, x26, _br_taken_24
    xor x9, x7, x20
    j _br_done_24
_br_taken_24:
    sll x9, x26, x8
_br_done_24:
    slli x29, x9, 9
    sltiu x25, x11, -337
    ori x11, x25, -1101
    lb x19, 872(x31)
    sb x9, 872(x31)
    bltu x21, x17, _br_taken_25
    add x19, x13, x13
    j _br_done_25
_br_taken_25:
    sll x19, x12, x24
_br_done_25:
    add x15, x30, x5
    bge x10, x23, _br_taken_26
    sra x19, x25, x15
    j _br_done_26
_br_taken_26:
    sub x19, x15, x5
_br_done_26:
    bne x22, x10, _br_taken_27
    xor x10, x8, x9
    j _br_done_27
_br_taken_27:
    or x10, x23, x4
_br_done_27:
    slti x20, x1, 1250
    andi x27, x13, 2030
    addi x27, x29, 455
    sub x27, x30, x18
    sltiu x27, x16, -144
    ori x26, x22, -942
    addi x26, x9, -1294
    lhu x27, 404(x31)
    sh x26, 404(x31)
    fadd.s f31, f11, f18
    fdiv.d f27, f5, f0
    bge x17, x8, _br_taken_28
    sub x12, x18, x16
    j _br_done_28
_br_taken_28:
    slt x12, x17, x26
_br_done_28:
    and x19, x5, x5
    srl x11, x22, x15
    andi x18, x23, -1436
    fmax.s f10, f21, f14
    fmsub.s f25, f22, f8, f10
    blt x23, x12, _br_taken_29
    and x21, x28, x21
    j _br_done_29
_br_taken_29:
    xor x21, x13, x28
_br_done_29:
    fsub.s f18, f0, f8
    fmax.s f17, f23, f12
    fsub.s f28, f11, f27
    lhu x6, 836(x31)
    sh x18, 836(x31)
    and x29, x7, x27
    sltu x29, x14, x19
    lw x12, 192(x31)
    sw x20, 192(x31)
    slt x27, x28, x6
    ori x24, x24, 711
    bne x21, x15, _br_taken_30
    and x30, x23, x27
    j _br_done_30
_br_taken_30:
    or x30, x23, x12
_br_done_30:
    beq x13, x19, _br_taken_31
    sll x1, x15, x24
    j _br_done_31
_br_taken_31:
    and x1, x12, x20
_br_done_31:
    fmax.s f24, f0, f5
    fdiv.s f26, f27, f18
    ori x8, x18, 1330
    or x26, x27, x15
    or x18, x9, x10
    slli x5, x10, 19
    add x25, x27, x25
    srl x15, x26, x29
    sub x23, x7, x9
    blt x1, x7, _br_taken_32
    add x30, x26, x27
    j _br_done_32
_br_taken_32:
    and x30, x14, x17
_br_done_32:
    lw x12, 396(x31)
    sw x18, 396(x31)
    sll x28, x8, x4
    remu x26, x16, x23
    div x19, x28, x5
    sltiu x15, x20, -246
    xor x6, x24, x8
    slti x15, x25, -1609
    xori x30, x1, -1095
    add x6, x4, x21
    sltiu x29, x12, -140
    lw x17, 468(x31)
    sw x30, 468(x31)
    bgeu x22, x23, _br_taken_33
    add x25, x27, x10
    j _br_done_33
_br_taken_33:
    add x25, x14, x21
_br_done_33:
    blt x5, x12, _br_taken_34
    xor x18, x21, x23
    j _br_done_34
_br_taken_34:
    add x18, x23, x21
_br_done_34:
    rem x1, x30, x20
    remu x25, x18, x13
    srl x8, x28, x20
    slli x19, x8, 6
    lbu x8, 404(x31)
    sb x25, 404(x31)
    addi x11, x31, 464
    amoor.w x9, x5, (x11)
    sub x11, x20, x16
    xori x10, x6, 362
    sltiu x24, x10, 294
    fmul.s f25, f17, f5
    fnmadd.s f16, f16, f11, f19
    fmsub.d f3, f6, f8, f21
    addi x14, x31, 644
    amoor.w x12, x30, (x14)
    fmadd.s f19, f13, f24, f9
    fmax.d f7, f13, f22
    fsub.s f20, f30, f14
    add x6, x5, x4
    and x17, x27, x7
    andi x27, x15, -1752
    srl x24, x28, x9
    addi x30, x31, 432
    amoadd.w x12, x9, (x30)
    slli x6, x30, 3
    srai x15, x28, 30
    addi x30, x22, -1706
    andi x15, x15, -1197
    xori x19, x5, 1336
    xori x6, x28, -1862
    xori x17, x16, 1570
    srai x22, x12, 6
    fmin.s f26, f21, f24
    fmax.s f17, f1, f14
    fmul.s f28, f11, f28
    bltu x30, x28, _br_taken_35
    sll x16, x10, x1
    j _br_done_35
_br_taken_35:
    sub x16, x21, x22
_br_done_35:
    andi x30, x13, 1660
    sltiu x6, x26, -264
    sub x24, x5, x29
    add x15, x25, x9
    addi x15, x11, -1415
    srli x16, x5, 10
    add x17, x11, x18
    slli x13, x9, 16
    fmin.s f0, f22, f13
    addi x12, x31, 184
    amoxor.w x25, x29, (x12)
    fnmsub.d f18, f18, f1, f21
    fadd.s f12, f11, f24

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xf6683a650d921093
    .dword 0x3f476f1dcfcb865c
    .dword 0x6db12629b59d8a59
    .dword 0x901ee63e478ba51e
    .dword 0xd81b9142a62c8a8d
    .dword 0x375ec0438fe57c23
    .dword 0x3edeee6182d57955
    .dword 0xa44c807dda002934
    .dword 0x8be4a144e60eb75b
    .dword 0x145b52f539a14ae1
    .dword 0x8e67da491db00c06
    .dword 0x8130079fd1ccd797
    .dword 0x99b4ac0576be4723
    .dword 0x9e044e154db051df
    .dword 0xe6e717c3d48f4359
    .dword 0x157bf4c32cc681fd
    .dword 0xc94e7aec31907370
    .dword 0x9e3ad05ea5ee4a7f
    .dword 0x845fbedcf5b29ab0
    .dword 0xadb92af99bc43025
    .dword 0x559bcbf6ff1631f4
    .dword 0x2e22ecb29f253097
    .dword 0xa502762c841c139c
    .dword 0x0066a582c2b73e01
    .dword 0x20c0f011bb0d60d9
    .dword 0x101ecf16cd850986
    .dword 0xf43f4df425ac471a
    .dword 0x51bc119a5970223b
    .dword 0xc13c458f4f426fd3
    .dword 0x68951beec1720d72
    .dword 0x19d3320a9f209c6f
    .dword 0xc84aa710124274de

    .align 2
_torture_data:
    .word 0x6afbea79
    .word 0x052c75d3
    .word 0xa41903c5
    .word 0x5106531b
    .word 0x1511322c
    .word 0x81273d8e
    .word 0x707bae80
    .word 0x27a3ce89
    .word 0xf4c2da83
    .word 0x57ef90c5
    .word 0x9059d3ac
    .word 0x1e295cc9
    .word 0x0228db0a
    .word 0x38204c40
    .word 0x6713bdf2
    .word 0x5e7515b6
    .word 0xdaa4d7a9
    .word 0xbba01588
    .word 0xe1cd6939
    .word 0x6129c0d1
    .word 0x55a09e1f
    .word 0x3aef8313
    .word 0x4dd1748e
    .word 0xc90a9c1f
    .word 0xea4e2bf5
    .word 0x6dfada4f
    .word 0x9e8ef98e
    .word 0x30476c69
    .word 0xf93274bb
    .word 0x0c59bae3
    .word 0xb21ced3b
    .word 0x7ccbdd67
    .word 0x14458e35
    .word 0xcb702c43
    .word 0xa5f8e066
    .word 0xba6edccb
    .word 0xe44f98f6
    .word 0x5edf0973
    .word 0x5b694666
    .word 0x465ba16e
    .word 0x32f198e3
    .word 0xd468caca
    .word 0x7228a88c
    .word 0x94be813e
    .word 0x76f6f5d5
    .word 0x437b1c88
    .word 0xb8fa0a10
    .word 0x277ca820
    .word 0x14863d2f
    .word 0x6e5dbda5
    .word 0x79e2cdf2
    .word 0x0d1bb632
    .word 0xe0348b94
    .word 0xc8dd46d3
    .word 0x2d56f292
    .word 0x3738d257
    .word 0x2306e0a2
    .word 0x061a81ae
    .word 0x94152bf7
    .word 0xe86c5072
    .word 0x86c77181
    .word 0xeb0a5036
    .word 0x33243e21
    .word 0x7b32631b
    .word 0x8e5474b3
    .word 0x626b0f39
    .word 0x60aed174
    .word 0xc128285f
    .word 0xd9318325
    .word 0x4467d71c
    .word 0xb56b6c66
    .word 0xf9fa10c5
    .word 0x9faee08a
    .word 0xdbad3b3e
    .word 0x6b309fdb
    .word 0x891ba612
    .word 0x6a14603c
    .word 0x5c1b95db
    .word 0x574ad304
    .word 0xa407e6be
    .word 0xec49d6f8
    .word 0xc59d3a7f
    .word 0x9c840571
    .word 0x2737a1e5
    .word 0x5b1c4751
    .word 0x876ec2e2
    .word 0x458c9e38
    .word 0x3af45b40
    .word 0xd23674ec
    .word 0xdd46fccf
    .word 0xc11e4c9f
    .word 0x6acd3c1d
    .word 0xa69c689c
    .word 0x6855fa3b
    .word 0x376b0ea9
    .word 0x49fe27c3
    .word 0x40e827c3
    .word 0xc6f31d98
    .word 0x0d0d484e
    .word 0x4d72c021
    .word 0xe386f2ed
    .word 0xa503c38b
    .word 0x49f8650c
    .word 0x9c14bef7
    .word 0x9d3a6253
    .word 0x971e3690
    .word 0xe353599c
    .word 0xde95426c
    .word 0x4dd39369
    .word 0xef0e50db
    .word 0x10911534
    .word 0x3242e1af
    .word 0x3acc5bb5
    .word 0x27b51415
    .word 0xc2af7c42
    .word 0x3f97918d
    .word 0x3b267b98
    .word 0x3876785f
    .word 0xd269325a
    .word 0x422dc1f9
    .word 0x745f1451
    .word 0xdd3743f5
    .word 0x784f6a0f
    .word 0x07314149
    .word 0xf153bf6b
    .word 0x1b765f02
    .word 0x74e6c4bd
    .word 0xaa4e6c0c
    .word 0x72e5acd7
    .word 0x4ad26e50
    .word 0x481ed9d3
    .word 0xf41a6aed
    .word 0x91fbd130
    .word 0x8a03c47d
    .word 0x2581bf1b
    .word 0x9379903c
    .word 0x63e67069
    .word 0x97f75840
    .word 0x9ead2331
    .word 0x5f467d00
    .word 0x7986088d
    .word 0x78e24467
    .word 0x6c25d052
    .word 0x57890552
    .word 0xa8d84a9e
    .word 0x70019d4e
    .word 0x7f349d08
    .word 0x9bec4643
    .word 0x8688b358
    .word 0xc01c707e
    .word 0x6aaa5f30
    .word 0x2b35d28e
    .word 0xb3d2477d
    .word 0x8715ba85
    .word 0x087ddffd
    .word 0xccaefded
    .word 0x94ab10b7
    .word 0x132d4d22
    .word 0x4152fdf1
    .word 0x21557112
    .word 0x5274cc36
    .word 0x5c1027a0
    .word 0xb476ddbc
    .word 0xb7176ddd
    .word 0x429b6526
    .word 0xe61ea9ce
    .word 0xae473307
    .word 0x93a689a7
    .word 0x8213a304
    .word 0x97a6f147
    .word 0xf654cf2a
    .word 0x0410bc71
    .word 0xc8c982ca
    .word 0xd7fa8bf2
    .word 0xc252e0ca
    .word 0xc1883fb3
    .word 0xf5edfd9f
    .word 0xada01924
    .word 0xa4ece172
    .word 0x1f43eb92
    .word 0x5415a255
    .word 0xc4525304
    .word 0x3f429ec8
    .word 0xba786bdb
    .word 0x2480792f
    .word 0xa647613c
    .word 0xcb4b1991
    .word 0x84c03c24
    .word 0x031347e3
    .word 0xfd037213
    .word 0xbd5bf6ef
    .word 0xb44fbc37
    .word 0x548721dc
    .word 0xab218169
    .word 0x65f5fd3b
    .word 0xc0a3d611
    .word 0x6bd64864
    .word 0x832d46cf
    .word 0x062939d9
    .word 0x42f6d0b2
    .word 0xe0eb46a7
    .word 0xcf2c9443
    .word 0xb49f43ac
    .word 0x77bf686c
    .word 0x9f60660f
    .word 0xe4302907
    .word 0x9db66c72
    .word 0xc0defdf3
    .word 0x6e878db1
    .word 0x938c8b96
    .word 0x4beb240c
    .word 0x341dc654
    .word 0x8a0656c3
    .word 0x7b84ab87
    .word 0x5e805fba
    .word 0x75fe4155
    .word 0x0861c5e8
    .word 0x006f1e98
    .word 0x2808d1cb
    .word 0xc6f97dde
    .word 0xedfc492e
    .word 0x70a4f83a
    .word 0x27afd0f3
    .word 0xf91c5440
    .word 0x9496ddef
    .word 0x248e1a91
    .word 0x87d54474
    .word 0x9a9a596b
    .word 0x3ae747e6
    .word 0x9b6a8ec9
    .word 0x000b2f67
    .word 0xb9bd4224
    .word 0xe2e20048
    .word 0x040e70ba
    .word 0x4b58021a
    .word 0x181edf5d
    .word 0x8f115e87
    .word 0x060efa9b
    .word 0x097b4aca
    .word 0xe0011a83
    .word 0x1b49ede9
    .word 0xd6f9b27e
    .word 0xdedf8456
    .word 0x8ecf7a90
    .word 0xf569fa1d
    .word 0x7aa17c99
    .word 0x4a7d5d67
    .word 0x827ddc30
    .word 0x7135bbed
    .word 0xd7b377ce
    .word 0xf12fff77
    .word 0xd521893f
    .word 0x2c1643a3
    .word 0x0290359c
    .word 0x94b1e464
    .word 0x5620b4fc

#include "frost_footer.S"
