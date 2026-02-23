// Generated RV32IMAFDC torture test for Frost (seed=45)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x4599a084
    li x4, 0x7cef6aa3
    li x5, 0x14f60b7a
    li x6, 0x56b73cfe
    li x7, 0x12847494
    li x8, 0x02d34789
    li x9, 0x9ffbe863
    li x10, 0x2290176e
    li x11, 0xbca9e904
    li x12, 0xb7a115ef
    li x13, 0x687b4c7a
    li x14, 0xb350c341
    li x15, 0xec46fde3
    li x16, 0x2c160877
    li x17, 0x407a17c2
    li x18, 0xf671b124
    li x19, 0x18004d45
    li x20, 0x16fefc7a
    li x21, 0xc04d4ade
    li x22, 0xa4ac1410
    li x23, 0x0f5350fb
    li x24, 0xe8dc4e64
    li x25, 0xe96963c4
    li x26, 0x59f1a611
    li x27, 0x04537ef1
    li x28, 0x9f9565c0
    li x29, 0x4b3572ba
    li x30, 0x6a1c79ff
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
    li x1, 0xd5df8ca5

    sltiu x15, x4, -1811
    sltiu x24, x23, 315
    sltu x11, x4, x15
    mul x22, x21, x25
    srl x13, x11, x10
    sltiu x24, x10, 1997
    andi x30, x18, -1270
    slli x5, x25, 8
    addi x30, x31, 912
    amoand.w x5, x24, (x30)
    fdiv.s f24, f10, f1
    fmax.d f26, f14, f20
    or x19, x20, x25
    or x21, x4, x30
    slti x23, x28, -1584
    srl x4, x4, x5
    ori x21, x23, 263
    slti x28, x19, 1073
    lbu x24, 828(x31)
    sb x17, 828(x31)
    lh x10, 788(x31)
    sh x29, 788(x31)
    slt x7, x15, x13
    or x13, x26, x7
    xori x22, x21, -1234
    fsub.s f5, f0, f8
    fmax.s f9, f21, f25
    fdiv.s f14, f1, f13
    xor x4, x22, x16
    ori x17, x23, 121
    add x28, x16, x14
    sub x28, x8, x24
    sltiu x27, x30, 1767
    slli x21, x19, 26
    sll x16, x6, x27
    sltiu x18, x23, -791
    xori x9, x15, -595
    fadd.s f15, f31, f28
    fmul.d f18, f12, f10
    fnmsub.s f11, f21, f18, f27
    xori x15, x26, 233
    or x14, x27, x27
    xor x15, x22, x19
    xori x7, x18, -1272
    sra x5, x12, x11
    sltiu x8, x23, 278
    mulh x25, x26, x1
    srli x19, x19, 17
    add x12, x9, x29
    slli x23, x22, 10
    ori x14, x25, 1023
    andi x29, x10, -934
    srli x1, x7, 28
    addi x30, x31, 720
    amoxor.w x18, x24, (x30)
    ori x13, x23, 1623
    srl x21, x16, x19
    andi x11, x24, 388
    mul x18, x24, x19
    mul x8, x24, x17
    lbu x9, 696(x31)
    sb x30, 696(x31)
    fdiv.s f13, f29, f14
    fmax.s f11, f14, f10
    lw x23, 1020(x31)
    sw x30, 1020(x31)
    slti x18, x17, 1044
    sltu x16, x16, x10
    addi x20, x31, 908
    amominu.w x11, x1, (x20)
    lh x23, 972(x31)
    sh x4, 972(x31)
    sltiu x28, x19, 1990
    sll x26, x14, x16
    ori x10, x26, -1796
    slt x1, x25, x29
    andi x23, x22, 1064
    andi x20, x19, 1799
    srl x7, x26, x24
    mulh x11, x13, x13
    sra x7, x6, x21
    slti x26, x6, 153
    sltiu x21, x24, -76
    srai x5, x7, 2
    ori x7, x25, -933
    srli x22, x23, 24
    sll x23, x17, x13
    sltiu x14, x18, 1149
    lh x8, 688(x31)
    sh x19, 688(x31)
    fdiv.s f11, f19, f14
    fmul.s f12, f0, f29
    fnmadd.s f1, f7, f18, f12
    sltiu x11, x29, 1040
    add x29, x26, x18
    addi x22, x9, 743
    srl x21, x17, x22
    srli x20, x10, 8
    xori x24, x25, -1363
    fmul.s f6, f11, f30
    bgeu x8, x17, _br_taken_0
    slt x10, x7, x9
    j _br_done_0
_br_taken_0:
    slt x10, x4, x13
_br_done_0:
    bge x18, x28, _br_taken_1
    sll x24, x11, x24
    j _br_done_1
_br_taken_1:
    xor x24, x20, x7
_br_done_1:
    bge x27, x17, _br_taken_2
    xor x29, x26, x7
    j _br_done_2
_br_taken_2:
    slt x29, x17, x10
_br_done_2:
    sll x6, x25, x15
    xor x4, x15, x29
    addi x25, x29, -1533
    addi x1, x10, 1748
    bltu x4, x21, _br_taken_3
    srl x21, x10, x1
    j _br_done_3
_br_taken_3:
    and x21, x12, x1
_br_done_3:
    sll x9, x28, x19
    add x21, x7, x10
    slli x18, x23, 4
    sll x9, x4, x15
    sra x21, x9, x29
    slti x13, x10, -299
    sltiu x17, x8, 1354
    slli x8, x29, 15
    fmax.d f0, f22, f11
    srai x5, x21, 3
    and x7, x6, x8
    bne x1, x19, _br_taken_4
    or x29, x4, x10
    j _br_done_4
_br_taken_4:
    srl x29, x10, x5
_br_done_4:
    sll x29, x15, x6
    sra x28, x4, x30
    bne x12, x19, _br_taken_5
    and x22, x16, x19
    j _br_done_5
_br_taken_5:
    sltu x22, x25, x28
_br_done_5:
    bltu x6, x19, _br_taken_6
    xor x6, x13, x9
    j _br_done_6
_br_taken_6:
    srl x6, x25, x19
_br_done_6:
    add x27, x15, x24
    srl x27, x27, x16
    xor x1, x16, x20
    xori x21, x14, 496
    srl x9, x20, x22
    addi x17, x4, 1417
    srl x5, x5, x28
    slt x25, x25, x20
    srai x20, x30, 18
    ori x7, x22, -1649
    srai x26, x15, 5
    slt x12, x11, x5
    srli x23, x17, 14
    sll x28, x14, x15
    lb x13, 1016(x31)
    sb x11, 1016(x31)
    lbu x29, 224(x31)
    sb x11, 224(x31)
    blt x11, x30, _br_taken_7
    srl x8, x15, x22
    j _br_done_7
_br_taken_7:
    sub x8, x25, x9
_br_done_7:
    bne x12, x9, _br_taken_8
    or x26, x4, x19
    j _br_done_8
_br_taken_8:
    or x26, x21, x25
_br_done_8:
    srai x28, x4, 31
    xor x7, x19, x5
    andi x16, x19, 1872
    bne x5, x12, _br_taken_9
    and x28, x13, x17
    j _br_done_9
_br_taken_9:
    add x28, x17, x26
_br_done_9:
    bltu x30, x12, _br_taken_10
    sra x16, x6, x5
    j _br_done_10
_br_taken_10:
    sub x16, x22, x29
_br_done_10:
    slli x22, x20, 2
    srli x23, x22, 21
    addi x5, x31, 748
    amomax.w x6, x7, (x5)
    lw x22, 836(x31)
    sw x24, 836(x31)
    xor x25, x12, x12
    bltu x23, x18, _br_taken_11
    add x11, x29, x18
    j _br_done_11
_br_taken_11:
    xor x11, x21, x16
_br_done_11:
    srli x26, x18, 4
    add x19, x11, x19
    slt x7, x8, x7
    andi x25, x29, -1520
    sub x26, x22, x28
    srai x8, x29, 11
    ori x14, x8, -648
    sra x16, x9, x7
    addi x26, x31, 388
    amoand.w x5, x30, (x26)
    slti x22, x4, 648
    srl x14, x19, x22
    bltu x29, x28, _br_taken_12
    sra x5, x19, x22
    j _br_done_12
_br_taken_12:
    sub x5, x18, x17
_br_done_12:
    xori x27, x21, 226
    slli x20, x11, 8
    srli x28, x18, 30
    or x15, x29, x22
    srl x23, x11, x24
    andi x24, x4, -1338
    bgeu x29, x13, _br_taken_13
    add x12, x13, x26
    j _br_done_13
_br_taken_13:
    slt x12, x15, x9
_br_done_13:
    bltu x21, x27, _br_taken_14
    xor x30, x17, x22
    j _br_done_14
_br_taken_14:
    sltu x30, x17, x25
_br_done_14:
    lbu x28, 936(x31)
    sb x16, 936(x31)
    bltu x7, x16, _br_taken_15
    sra x10, x16, x24
    j _br_done_15
_br_taken_15:
    and x10, x4, x1
_br_done_15:
    srl x10, x11, x25
    fnmsub.s f31, f17, f12, f19
    fnmsub.s f1, f1, f15, f14
    srli x11, x11, 22
    slt x30, x25, x8
    xor x12, x5, x18
    sub x4, x24, x8
    addi x20, x31, 796
    amomaxu.w x1, x8, (x20)
    slt x19, x25, x24
    srai x24, x16, 9
    srl x9, x7, x15
    lhu x14, 440(x31)
    sh x21, 440(x31)
    srai x26, x13, 30
    sltu x5, x21, x6
    xori x1, x7, -1774
    add x29, x28, x30
    srai x11, x22, 13
    divu x17, x7, x28
    ori x13, x22, -1222
    andi x28, x6, -1864
    srl x4, x7, x9
    bne x15, x5, _br_taken_16
    add x19, x20, x13
    j _br_done_16
_br_taken_16:
    sra x19, x6, x23
_br_done_16:
    fmin.d f22, f15, f13
    fdiv.s f18, f13, f10
    fnmadd.s f3, f19, f22, f3
    fadd.d f23, f0, f15
    fnmadd.s f2, f10, f19, f6
    sra x4, x7, x17
    fmin.d f21, f23, f2
    slt x21, x5, x30
    andi x26, x25, -1329
    and x20, x4, x4
    or x28, x13, x14
    sll x8, x22, x29
    addi x19, x18, -1429
    slt x7, x22, x23
    addi x5, x31, 420
    amoswap.w x10, x11, (x5)
    bge x23, x26, _br_taken_17
    sll x11, x15, x19
    j _br_done_17
_br_taken_17:
    sltu x11, x30, x10
_br_done_17:
    add x17, x15, x4
    slli x4, x15, 6
    sltiu x25, x18, 1666
    srli x27, x14, 18
    remu x6, x19, x12
    rem x8, x22, x20
    div x9, x16, x14
    remu x12, x10, x16
    srai x4, x28, 18
    mulhsu x23, x6, x4
    sra x18, x6, x1
    sra x6, x20, x13
    slt x7, x25, x25
    addi x11, x31, 736
    amoor.w x17, x18, (x11)
    slti x5, x16, 726
    sub x25, x10, x28
    ori x14, x9, 836
    sra x12, x17, x1
    srl x15, x9, x16
    sub x24, x19, x28
    fmul.d f2, f23, f13
    bltu x5, x22, _br_taken_18
    and x21, x13, x11
    j _br_done_18
_br_taken_18:
    add x21, x1, x15
_br_done_18:
    bne x8, x22, _br_taken_19
    sll x7, x1, x22
    j _br_done_19
_br_taken_19:
    sub x7, x12, x27
_br_done_19:
    sra x9, x18, x19
    fsub.d f4, f26, f16
    fnmsub.s f12, f30, f30, f10
    fmsub.d f18, f29, f3, f19
    sltu x10, x23, x9
    slli x19, x26, 10
    bgeu x12, x7, _br_taken_20
    sub x16, x5, x26
    j _br_done_20
_br_taken_20:
    sll x16, x30, x8
_br_done_20:
    and x13, x28, x21
    sll x28, x22, x20
    add x28, x19, x17
    slti x28, x23, -629
    slli x16, x9, 18
    slli x11, x15, 13
    sltu x5, x24, x12
    sll x23, x26, x27
    lw x14, 860(x31)
    sw x19, 860(x31)
    beq x13, x12, _br_taken_21
    slt x11, x22, x17
    j _br_done_21
_br_taken_21:
    sll x11, x23, x30
_br_done_21:
    addi x23, x27, -945
    bgeu x8, x9, _br_taken_22
    sra x4, x8, x26
    j _br_done_22
_br_taken_22:
    sltu x4, x14, x21
_br_done_22:
    bgeu x7, x21, _br_taken_23
    sll x25, x19, x15
    j _br_done_23
_br_taken_23:
    sra x25, x9, x7
_br_done_23:
    srl x17, x13, x17
    sra x30, x18, x9
    add x20, x20, x15
    lw x19, 392(x31)
    sw x29, 392(x31)
    bgeu x24, x8, _br_taken_24
    sra x4, x27, x12
    j _br_done_24
_br_taken_24:
    srl x4, x10, x15
_br_done_24:
    fmin.s f30, f28, f27
    fadd.d f3, f0, f9
    fsub.s f14, f8, f20
    fnmadd.d f17, f22, f3, f17
    lh x21, 276(x31)
    sh x5, 276(x31)
    beq x25, x4, _br_taken_25
    and x22, x15, x13
    j _br_done_25
_br_taken_25:
    and x22, x11, x30
_br_done_25:
    bgeu x26, x27, _br_taken_26
    slt x29, x1, x9
    j _br_done_26
_br_taken_26:
    sub x29, x19, x16
_br_done_26:
    slli x6, x19, 10
    slli x26, x30, 15
    slti x11, x26, 18
    srli x14, x29, 12
    fmin.s f29, f16, f11
    fnmsub.s f13, f1, f17, f10
    fnmsub.d f21, f17, f6, f26
    xori x13, x17, -1838
    addi x26, x14, -61
    andi x24, x23, -966
    bltu x12, x4, _br_taken_27
    xor x18, x12, x5
    j _br_done_27
_br_taken_27:
    slt x18, x22, x22
_br_done_27:
    sltu x24, x9, x29
    and x29, x4, x11
    fmul.d f26, f23, f0
    fsub.d f20, f21, f21
    fmax.d f20, f12, f23
    sltu x6, x5, x14
    fmin.s f29, f19, f0
    fnmsub.d f8, f17, f3, f26
    ori x24, x24, 1471
    and x20, x4, x9
    blt x19, x6, _br_taken_28
    sub x1, x11, x16
    j _br_done_28
_br_taken_28:
    sltu x1, x24, x14
_br_done_28:
    bltu x25, x20, _br_taken_29
    sll x26, x7, x29
    j _br_done_29
_br_taken_29:
    sub x26, x24, x11
_br_done_29:
    lbu x17, 452(x31)
    sb x1, 452(x31)
    sll x27, x7, x5
    srli x28, x25, 9
    add x13, x19, x5
    beq x10, x19, _br_taken_30
    sltu x27, x23, x11
    j _br_done_30
_br_taken_30:
    sll x27, x20, x26
_br_done_30:
    bgeu x26, x23, _br_taken_31
    srl x24, x9, x6
    j _br_done_31
_br_taken_31:
    slt x24, x9, x25
_br_done_31:
    andi x26, x29, 1665
    srai x25, x6, 10
    add x25, x11, x16
    sll x18, x11, x15
    bgeu x6, x7, _br_taken_32
    sra x24, x8, x28
    j _br_done_32
_br_taken_32:
    and x24, x26, x11
_br_done_32:
    and x8, x7, x16
    add x8, x30, x16
    xor x29, x5, x12
    mulh x24, x1, x7
    remu x28, x18, x16
    bne x20, x25, _br_taken_33
    slt x27, x25, x21
    j _br_done_33
_br_taken_33:
    xor x27, x7, x4
_br_done_33:
    lb x8, 1004(x31)
    sb x28, 1004(x31)
    lhu x28, 680(x31)
    sh x8, 680(x31)
    fsub.d f20, f22, f19
    fadd.s f14, f23, f30
    fmadd.s f12, f11, f18, f24
    blt x6, x12, _br_taken_34
    and x6, x22, x15
    j _br_done_34
_br_taken_34:
    sub x6, x28, x6
_br_done_34:
    addi x26, x5, 1765
    sll x30, x27, x12
    slt x21, x28, x9
    srl x15, x10, x16
    slli x27, x18, 1
    addi x18, x31, 1004
    amoadd.w x15, x29, (x18)
    lw x13, 296(x31)
    sw x18, 296(x31)
    lw x13, 1016(x31)
    sw x18, 1016(x31)
    ori x19, x8, -382
    andi x26, x15, -479
    slt x18, x20, x8
    blt x20, x13, _br_taken_35
    sll x6, x4, x27
    j _br_done_35
_br_taken_35:
    sub x6, x29, x17
_br_done_35:
    srai x15, x15, 19
    lhu x7, 968(x31)
    sh x9, 968(x31)
    bgeu x7, x25, _br_taken_36
    sll x15, x18, x11
    j _br_done_36
_br_taken_36:
    sra x15, x20, x25
_br_done_36:
    sra x10, x7, x23
    sub x13, x10, x5
    bgeu x26, x29, _br_taken_37
    slt x1, x10, x12
    j _br_done_37
_br_taken_37:
    srl x1, x30, x12
_br_done_37:
    ori x14, x7, -963
    addi x11, x31, 404
    amomin.w x10, x8, (x11)
    slti x29, x28, 1943
    or x9, x12, x25
    blt x8, x22, _br_taken_38
    srl x29, x12, x15
    j _br_done_38
_br_taken_38:
    xor x29, x9, x10
_br_done_38:
    or x17, x18, x11
    slt x28, x25, x1
    slli x24, x14, 14

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x63580267a4c864ee
    .dword 0x76ca662afd817eab
    .dword 0x1e371a95b3e28ef4
    .dword 0x1c5f0dad7963f962
    .dword 0x1aaf0ac168dc1e80
    .dword 0x86992e6605324e9c
    .dword 0x96c08543d345586b
    .dword 0x8256af7746cd6ec6
    .dword 0xb13587b1eea70c3d
    .dword 0x5b35ebf5f55a6afd
    .dword 0xd0d283368d075830
    .dword 0x3e4aa775a09fdbd7
    .dword 0x16f0cdecb5650360
    .dword 0x6b07d073094a7e27
    .dword 0x8739a91e06b4feb6
    .dword 0x97b1c74d3d62329c
    .dword 0xbc3efcac6d792482
    .dword 0x265afc9ef203613f
    .dword 0x810a2802b8dc9a03
    .dword 0x55b6d026a5757779
    .dword 0x71345590bbcfdc7e
    .dword 0xe463544af610981e
    .dword 0x018d6742e7ca1720
    .dword 0x8ea723c45c9c8e08
    .dword 0xa534a8a57b178b2f
    .dword 0x7aefdb54b0850810
    .dword 0xad84bd53d2bc9af1
    .dword 0xed88f46ab844a239
    .dword 0x105e70b764e7b23a
    .dword 0xc7866b157bb697f3
    .dword 0xb7bdec8219ffb90f
    .dword 0x16bd92f28383dfc9

    .align 2
_torture_data:
    .word 0x7e33a297
    .word 0x979b5ed0
    .word 0x60f5fd04
    .word 0x0ed8cbba
    .word 0x806c5c36
    .word 0xd50ad14d
    .word 0x6d8ed335
    .word 0x7244fcbe
    .word 0xfd012942
    .word 0x600122e7
    .word 0x4951fee4
    .word 0xa86ac465
    .word 0x95f211dc
    .word 0x89f467c4
    .word 0xa135f869
    .word 0x7a688df4
    .word 0x008def30
    .word 0xf788c76c
    .word 0x2cf2d330
    .word 0xaff513cc
    .word 0x8ab7dd3a
    .word 0x105936dd
    .word 0x5436c638
    .word 0x0abffbe4
    .word 0xfb7edbf1
    .word 0x85096635
    .word 0x54a9fa07
    .word 0x41dd3ff3
    .word 0x4c601b90
    .word 0xd4375958
    .word 0x88c34585
    .word 0xc44cd3d1
    .word 0xb05cda6e
    .word 0xd5090939
    .word 0x21dc1296
    .word 0x6ebd558c
    .word 0x976bc2a0
    .word 0x95fbb07a
    .word 0x26c97f19
    .word 0x01be4c98
    .word 0x8638266c
    .word 0x9ac8b264
    .word 0xbe8bb48a
    .word 0xc2d97a44
    .word 0x5d252360
    .word 0xb4c95bc5
    .word 0x133805bc
    .word 0xa4291ff8
    .word 0x4113edd1
    .word 0x2b82b6ac
    .word 0x2fd08188
    .word 0x69994857
    .word 0x5b38c2d7
    .word 0xb2e3f919
    .word 0x6acd939b
    .word 0x8930c919
    .word 0x9c91c172
    .word 0x0c9508e3
    .word 0xdb02a1b2
    .word 0xd83ce790
    .word 0x5fa2936b
    .word 0xf32a8db1
    .word 0x9719ac18
    .word 0x54d3d641
    .word 0xdd35ffbc
    .word 0x6c632409
    .word 0x664e649a
    .word 0xd71b6544
    .word 0xa86bfa92
    .word 0x2e8cc070
    .word 0xe947f1ac
    .word 0x7b9f0e3e
    .word 0x431565d5
    .word 0x15515cc4
    .word 0xeffd8842
    .word 0xd42a3cb2
    .word 0xad85cf2b
    .word 0xe4334410
    .word 0xb57a17a7
    .word 0x2ea8f78f
    .word 0x0913d2e4
    .word 0xcdeb00f6
    .word 0xaa98617d
    .word 0xbcf75737
    .word 0x599e4f88
    .word 0x6822a994
    .word 0x36beb516
    .word 0x28852006
    .word 0x78ca1086
    .word 0xa05117a1
    .word 0xf3bb7985
    .word 0x5c1b67ec
    .word 0x4f17ed0c
    .word 0x8d884bae
    .word 0x1a2fbd6d
    .word 0xafdd1769
    .word 0xc62ef5e6
    .word 0xb47e047b
    .word 0x93ab7a1e
    .word 0xb8b2b9a2
    .word 0x3c7d5e3a
    .word 0x7df4ac92
    .word 0xeacf2df4
    .word 0x58e6dc2c
    .word 0xadd566ba
    .word 0xa221e9e6
    .word 0x370c88a5
    .word 0x2bbde401
    .word 0xad32dd6c
    .word 0xab5dd36f
    .word 0xe3818e92
    .word 0xbfa9e6dd
    .word 0xe6406b1e
    .word 0x41da95a2
    .word 0x23b2439b
    .word 0x7095c4c5
    .word 0x50a145ec
    .word 0x58dae576
    .word 0xe95103ce
    .word 0x14143834
    .word 0x4aee38b3
    .word 0x5b4bc499
    .word 0x53d631a6
    .word 0xf62be855
    .word 0x7a61d0a9
    .word 0x302acd8d
    .word 0x3f586a2d
    .word 0x3d275d8a
    .word 0xbed1604f
    .word 0x907d0e17
    .word 0xf92d91ea
    .word 0xf60473fb
    .word 0x9a5ee4ff
    .word 0xde215c3a
    .word 0x911ae60a
    .word 0xdfa6b6f0
    .word 0x0711c3a1
    .word 0xc1cdc554
    .word 0x571070a7
    .word 0x1ad7273c
    .word 0x1f4b2bf7
    .word 0xe03a27ea
    .word 0x24440e4b
    .word 0xb6d0db8e
    .word 0xe544b48e
    .word 0x3453e3d2
    .word 0x0f2719d7
    .word 0x8e192447
    .word 0xb2eafa80
    .word 0x3f810b22
    .word 0x370e34ed
    .word 0x66384a86
    .word 0x72d4be34
    .word 0xfe628796
    .word 0xedb4a0c3
    .word 0x308a695e
    .word 0xa58d9e1c
    .word 0xf14f1626
    .word 0x16bc0556
    .word 0xef876a99
    .word 0x4b12b1f2
    .word 0xdeea6884
    .word 0x650f01d3
    .word 0x272b9bd2
    .word 0x1584703e
    .word 0x8ad667c6
    .word 0x5ff2f601
    .word 0xc0fdb792
    .word 0x91bad1fa
    .word 0xbb7b5049
    .word 0x9e2f759b
    .word 0x63d9d879
    .word 0xbd3f8a84
    .word 0x06bef4ab
    .word 0x1c554461
    .word 0xc4ed32b6
    .word 0x4c7a2b6f
    .word 0x2177ce6a
    .word 0x23a3256d
    .word 0x550fb757
    .word 0x79b21f23
    .word 0x15769959
    .word 0xa4386dd0
    .word 0x7415508a
    .word 0xb52e766f
    .word 0xf025cfe7
    .word 0x1f036198
    .word 0x7488baaf
    .word 0x107aa114
    .word 0xbd23f8d9
    .word 0x41b752b2
    .word 0x4287d4a2
    .word 0x0140545e
    .word 0x4668832d
    .word 0x0585c054
    .word 0x4bf28e93
    .word 0xc9a6f67b
    .word 0x216f0411
    .word 0xf3b742f2
    .word 0x39ceb6e2
    .word 0x3f319ce3
    .word 0x8f15a435
    .word 0x1e0ad88c
    .word 0xbf1d76b5
    .word 0xe033a59e
    .word 0xa608c60b
    .word 0x8f738e34
    .word 0xe157672b
    .word 0x98df4984
    .word 0x78900015
    .word 0x7a53e918
    .word 0xf0e4f9f4
    .word 0xe604f509
    .word 0x6d4ec0a5
    .word 0xf424735d
    .word 0xcf3f1afb
    .word 0x4cfef0ea
    .word 0xdcc30084
    .word 0x80e0af57
    .word 0x11332a33
    .word 0xafbdd1fb
    .word 0xe3b7ec83
    .word 0xcc2c82ae
    .word 0x94c039b5
    .word 0x54fc9cf4
    .word 0xfbb77d6d
    .word 0x845efb36
    .word 0x11a1add8
    .word 0xdca41b58
    .word 0x66e050ab
    .word 0x605a8db0
    .word 0x7815a74e
    .word 0x1c214120
    .word 0x6f48087e
    .word 0x575c5620
    .word 0x3c3e8c18
    .word 0x0125a1a1
    .word 0x66fcc04d
    .word 0x3394b386
    .word 0xe186e3ce
    .word 0x427796d7
    .word 0xa11b2f7f
    .word 0x86899429
    .word 0x73e458ac
    .word 0xf350e92a
    .word 0xdd0c99e8
    .word 0x52e43f3b
    .word 0x7c323846
    .word 0x7c417ad9
    .word 0x168df1dd
    .word 0xeca6afdc
    .word 0x0e10d1e1
    .word 0xfa42e6c5
    .word 0x5c7b4eec
    .word 0x50e560e3
    .word 0x57bca99c

#include "frost_footer.S"
