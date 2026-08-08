// Generated RV64IMAFDC torture test for Frost (seed=20260811)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xffcbc3bc090b81d4
    li x4, 0xbc890e154eabeb35
    li x5, 0x1571cd46aa270c95
    li x6, 0x51af6b436fdec5a8
    li x7, 0xdfe2d65ff86dcf58
    li x8, 0x452c02c08d69c21f
    li x9, 0x45c1019c69e15f6f
    li x10, 0xb1e94bf141a92f64
    li x11, 0x48c00df8581468fb
    li x12, 0xb252cc15c270df8e
    li x13, 0xfb686c16fe3db5e0
    li x14, 0xa65af3b67ef43ef4
    li x15, 0xee3b7ca7d8ca71f1
    li x16, 0xc07e41d7e11e3deb
    li x17, 0x0f042f7d93157a7f
    li x18, 0xede939983e53e5cd
    li x19, 0x91e63c2cc59cd8c0
    li x20, 0x7fad7b7be79577fb
    li x21, 0x2313ac5d2e412255
    li x22, 0x4495302aa3b2a743
    li x23, 0x2cacb8dbceee0ee7
    li x24, 0x147828c9b3e22f66
    li x25, 0xce23e9bb58a099cd
    li x26, 0x4ab0bea63ee12a75
    li x27, 0x1c955919136bb7f2
    li x28, 0x0c5d1190eb5852f7
    li x29, 0x48f93a7a45937a05
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
    li x1, 0xa73bbbc48c3e0dc9

    blt x5, x14, _br_taken_0
    sub x21, x7, x11
    j _br_done_0
_br_taken_0:
    sltu x21, x23, x13
_br_done_0:
    addi x30, x31, 968
    amoand.d x15, x18, (x30)
    srai x28, x20, 17
    sll x11, x15, x16
    xor x4, x13, x27
    lh x9, 1004(x31)
    sh x15, 1004(x31)
    sllw x20, x15, x7
    addiw x26, x4, 1453
    fnmadd.s f23, f26, f7, f19
    fdiv.s f14, f13, f4
    sub x27, x6, x26
    bne x15, x23, _br_taken_1
    add x12, x23, x11
    j _br_done_1
_br_taken_1:
    and x12, x16, x21
_br_done_1:
    bge x28, x21, _br_taken_2
    sra x1, x6, x4
    j _br_done_2
_br_taken_2:
    slt x1, x26, x26
_br_done_2:
    fadd.d f25, f29, f14
    slli x8, x25, 63
    andi x8, x9, 858
    xor x8, x7, x22
    xori x23, x6, -1602
    subw x10, x26, x14
    subw x10, x29, x7
    sllw x17, x13, x26
    srai x24, x6, 10
    srliw x17, x13, 27
    sraw x9, x24, x23
    sub x6, x5, x28
    and x13, x18, x4
    bltu x16, x6, _br_taken_3
    sltu x10, x12, x17
    j _br_done_3
_br_taken_3:
    and x10, x20, x26
_br_done_3:
    beq x24, x18, _br_taken_4
    sub x22, x20, x27
    j _br_done_4
_br_taken_4:
    slt x22, x21, x5
_br_done_4:
    lbu x11, 72(x31)
    sb x5, 72(x31)
    remu x6, x18, x16
    remuw x11, x15, x22
    fadd.s f18, f21, f15
    addi x30, x31, 704
    amoadd.d x17, x19, (x30)
    addi x30, x31, 304
    amomin.w x17, x24, (x30)
    mulhsu x26, x27, x27
    mulhsu x28, x21, x14
    blt x9, x22, _br_taken_5
    srl x5, x27, x13
    j _br_done_5
_br_taken_5:
    or x5, x26, x12
_br_done_5:
    sllw x21, x14, x27
    addw x20, x4, x9
    slt x24, x15, x12
    sra x26, x13, x15
    bgeu x28, x5, _br_taken_6
    sltu x18, x4, x14
    j _br_done_6
_br_taken_6:
    sltu x18, x7, x21
_br_done_6:
    sraw x12, x22, x7
    bne x19, x19, _br_taken_7
    add x12, x13, x13
    j _br_done_7
_br_taken_7:
    slt x12, x15, x16
_br_done_7:
    bgeu x21, x25, _br_taken_8
    xor x26, x10, x28
    j _br_done_8
_br_taken_8:
    sltu x26, x23, x11
_br_done_8:
    addw x16, x11, x8
    srliw x24, x7, 0
    lwu x4, 140(x31)
    sw x10, 140(x31)
    addw x24, x18, x1
    xori x15, x11, 844
    fmin.s f2, f31, f27
    fadd.d f10, f21, f29
    fmul.d f8, f20, f13
    bgeu x16, x20, _br_taken_9
    sra x6, x12, x9
    j _br_done_9
_br_taken_9:
    sll x6, x25, x18
_br_done_9:
    slti x16, x9, -1366
    sll x26, x25, x17
    lbu x23, 424(x31)
    sb x28, 424(x31)
    sra x25, x27, x26
    srl x6, x10, x11
    or x12, x7, x7
    fadd.d f10, f30, f4
    srlw x20, x1, x10
    sraiw x21, x9, 17
    lw x27, 840(x31)
    sw x7, 840(x31)
    slli x6, x16, 29
    fadd.d f24, f20, f14
    lw x7, 168(x31)
    sw x16, 168(x31)
    and x11, x11, x21
    srliw x21, x20, 16
    mulhu x6, x16, x25
    addi x30, x31, 764
    amomin.w x24, x1, (x30)
    add x22, x9, x1
    slliw x22, x12, 17
    slt x19, x8, x27
    srliw x22, x23, 10
    blt x29, x11, _br_taken_10
    sll x20, x16, x13
    j _br_done_10
_br_taken_10:
    xor x20, x12, x7
_br_done_10:
    sll x19, x12, x6
    xor x9, x14, x15
    sra x24, x1, x25
    blt x1, x4, _br_taken_11
    xor x6, x22, x5
    j _br_done_11
_br_taken_11:
    xor x6, x22, x16
_br_done_11:
    slt x12, x23, x23
    add x21, x22, x23
    fnmsub.s f1, f7, f0, f7
    bne x1, x9, _br_taken_12
    slt x19, x25, x9
    j _br_done_12
_br_taken_12:
    xor x19, x11, x24
_br_done_12:
    fmul.s f26, f2, f30
    andi x1, x1, -568
    sraw x28, x14, x4
    addi x30, x31, 72
    amoor.d x25, x11, (x30)
    sub x18, x23, x29
    xori x20, x17, 253
    bge x18, x1, _br_taken_13
    sra x24, x15, x21
    j _br_done_13
_br_taken_13:
    and x24, x12, x15
_br_done_13:
    addw x8, x14, x18
    sllw x19, x17, x6
    sltu x8, x14, x23
    sra x7, x15, x22
    srliw x1, x19, 10
    fadd.s f17, f17, f17
    lhu x11, 860(x31)
    sh x5, 860(x31)
    slli x6, x16, 55
    xori x17, x18, 1343
    sll x6, x8, x9
    sltiu x1, x28, 1678
    slli x17, x27, 9
    addi x30, x31, 736
    amomax.d x4, x27, (x30)
    srliw x21, x28, 30
    srliw x19, x24, 9
    slti x12, x5, -1293
    sra x21, x1, x21
    slt x21, x14, x15
    sub x29, x28, x20
    andi x11, x27, 301
    srlw x25, x12, x23
    slt x9, x9, x11
    addiw x23, x18, -285
    sraiw x25, x18, 5
    xor x6, x14, x16
    srai x27, x24, 1
    sllw x13, x24, x7
    subw x27, x23, x6
    andi x29, x22, 1206
    andi x29, x5, 1522
    remw x1, x21, x5
    sra x10, x6, x29
    addw x15, x19, x26
    fnmsub.d f30, f21, f26, f31
    fadd.s f27, f12, f23
    ld x26, 936(x31)
    sd x25, 936(x31)
    bge x22, x15, _br_taken_14
    slt x22, x8, x7
    j _br_done_14
_br_taken_14:
    and x22, x8, x10
_br_done_14:
    sra x8, x22, x8
    slliw x4, x17, 6
    srai x5, x4, 62
    sllw x1, x22, x13
    slli x29, x28, 47
    sltiu x10, x29, -788
    srli x13, x28, 56
    slt x10, x10, x19
    lwu x6, 948(x31)
    sw x27, 948(x31)
    lh x14, 468(x31)
    sh x7, 468(x31)
    addi x30, x31, 680
    amoand.d x23, x10, (x30)
    addiw x14, x6, -1818
    and x9, x9, x15
    sltu x16, x22, x10
    blt x10, x10, _br_taken_15
    and x18, x20, x29
    j _br_done_15
_br_taken_15:
    xor x18, x5, x4
_br_done_15:
    fmul.d f26, f26, f19
    fnmadd.s f3, f7, f1, f5
    fdiv.s f11, f25, f30
    lbu x17, 448(x31)
    sb x22, 448(x31)
    srli x11, x26, 42
    andi x24, x8, -357
    fdiv.s f7, f19, f15
    fmsub.s f8, f20, f3, f20
    fsub.s f26, f7, f19
    addw x5, x10, x13
    lw x7, 256(x31)
    sw x6, 256(x31)
    srl x27, x28, x12
    srai x21, x9, 31
    addw x18, x13, x23
    ori x13, x15, 558
    sll x8, x28, x9
    bgeu x9, x18, _br_taken_16
    sltu x7, x5, x8
    j _br_done_16
_br_taken_16:
    slt x7, x29, x9
_br_done_16:
    srl x19, x24, x19
    bge x8, x20, _br_taken_17
    srl x17, x14, x10
    j _br_done_17
_br_taken_17:
    srl x17, x27, x17
_br_done_17:
    fadd.d f12, f4, f31
    fmsub.s f10, f12, f6, f19
    addi x30, x31, 240
    amomaxu.d x29, x8, (x30)
    srl x27, x26, x19
    sraiw x9, x24, 25
    sraiw x27, x16, 17
    sraw x24, x9, x14
    sub x13, x7, x14
    lbu x27, 376(x31)
    sb x12, 376(x31)
    xori x17, x24, -1600
    blt x23, x13, _br_taken_18
    or x14, x13, x19
    j _br_done_18
_br_taken_18:
    sll x14, x24, x9
_br_done_18:
    blt x6, x10, _br_taken_19
    sra x28, x29, x27
    j _br_done_19
_br_taken_19:
    sub x28, x8, x14
_br_done_19:
    fmin.s f20, f14, f8
    fmadd.d f7, f15, f11, f2
    fmul.s f11, f29, f12
    addi x30, x31, 436
    amoswap.w x7, x12, (x30)
    lwu x6, 816(x31)
    sw x15, 816(x31)
    sltu x1, x8, x8
    lhu x6, 320(x31)
    sh x1, 320(x31)
    ld x25, 808(x31)
    sd x1, 808(x31)
    addiw x5, x23, 452
    sltu x27, x13, x10
    sub x5, x14, x15
    srliw x17, x19, 18
    addi x30, x31, 212
    amoadd.w x16, x12, (x30)
    addi x25, x24, -55
    ori x25, x1, 448
    addiw x9, x24, 1464
    bltu x18, x5, _br_taken_20
    add x26, x11, x10
    j _br_done_20
_br_taken_20:
    xor x26, x12, x5
_br_done_20:
    fadd.s f2, f18, f12
    fsub.s f20, f3, f2
    bne x28, x16, _br_taken_21
    or x12, x24, x10
    j _br_done_21
_br_taken_21:
    sll x12, x26, x15
_br_done_21:
    lwu x29, 552(x31)
    sw x17, 552(x31)
    bgeu x5, x13, _br_taken_22
    and x22, x18, x19
    j _br_done_22
_br_taken_22:
    slt x22, x1, x18
_br_done_22:
    addw x17, x25, x1
    xori x26, x11, 646
    srli x26, x20, 9
    xori x11, x10, 630
    divuw x27, x17, x6
    srli x28, x13, 51
    srai x25, x18, 26
    fsub.d f9, f23, f23
    add x19, x10, x5
    xori x27, x25, -844
    fadd.s f15, f31, f11
    fsub.s f18, f7, f31
    addi x11, x27, -336
    subw x1, x21, x4
    slliw x25, x21, 0
    fmax.s f12, f13, f3
    bltu x16, x8, _br_taken_23
    or x23, x14, x16
    j _br_done_23
_br_taken_23:
    or x23, x20, x28
_br_done_23:
    addw x28, x1, x26
    and x18, x21, x6
    slliw x4, x4, 9
    fdiv.d f26, f10, f11
    fmax.s f20, f17, f4
    fmax.s f23, f3, f4
    sllw x18, x6, x10
    srli x22, x29, 63
    blt x29, x22, _br_taken_24
    sra x18, x22, x20
    j _br_done_24
_br_taken_24:
    and x18, x5, x23
_br_done_24:
    xori x21, x24, 1703
    slli x11, x8, 21
    slti x12, x1, 548
    ld x8, 704(x31)
    sd x28, 704(x31)
    addi x30, x31, 232
    amoor.w x27, x1, (x30)
    ld x4, 392(x31)
    sd x10, 392(x31)
    fmax.s f16, f4, f0
    bge x21, x15, _br_taken_25
    sltu x19, x10, x14
    j _br_done_25
_br_taken_25:
    sltu x19, x4, x18
_br_done_25:
    sra x14, x27, x18
    sra x14, x4, x12
    sra x27, x4, x5
    div x5, x13, x14
    beq x12, x10, _br_taken_26
    sltu x13, x18, x9
    j _br_done_26
_br_taken_26:
    sra x13, x13, x1
_br_done_26:
    or x28, x21, x25
    srli x7, x9, 8
    sub x23, x22, x23
    subw x6, x1, x16
    fmax.d f31, f6, f16
    fmin.d f19, f24, f6
    fadd.s f13, f19, f2
    andi x12, x19, 778
    sub x22, x5, x17
    sub x17, x22, x12
    blt x11, x28, _br_taken_27
    slt x20, x21, x11
    j _br_done_27
_br_taken_27:
    or x20, x8, x17
_br_done_27:
    ori x29, x9, 1278
    sra x1, x26, x16
    and x4, x14, x29
    fmsub.s f1, f17, f21, f22
    fsub.d f19, f2, f12
    fnmsub.d f19, f12, f27, f11
    sra x20, x4, x4
    sltiu x27, x13, 121
    sraiw x13, x7, 26
    lh x15, 492(x31)
    sh x23, 492(x31)
    slliw x11, x25, 24
    addw x28, x8, x9
    fmsub.d f0, f29, f16, f6
    fdiv.s f25, f27, f23
    fadd.s f2, f5, f2
    sll x9, x25, x5
    sltiu x1, x8, -769
    sll x13, x6, x14
    addw x20, x17, x25
    andi x7, x12, -1818
    lh x29, 216(x31)
    sh x27, 216(x31)
    beq x8, x11, _br_taken_28
    sub x6, x4, x12
    j _br_done_28
_br_taken_28:
    xor x6, x11, x17
_br_done_28:
    fnmadd.s f6, f12, f10, f0
    sraiw x15, x8, 13
    subw x13, x29, x11
    andi x9, x5, 55
    slli x7, x7, 38
    xor x20, x29, x15
    addiw x9, x8, 1206
    slti x27, x15, -1611
    xori x20, x11, -1525
    slt x22, x7, x6
    ori x27, x24, 1568
    slliw x10, x23, 18
    andi x1, x10, 960
    andi x23, x11, 1463
    lw x17, 260(x31)
    sw x26, 260(x31)
    and x21, x29, x20
    slt x16, x12, x12
    sltiu x15, x7, 1441
    andi x14, x13, -1047
    bne x28, x23, _br_taken_29
    or x26, x19, x12
    j _br_done_29
_br_taken_29:
    and x26, x15, x21
_br_done_29:
    remw x24, x4, x1
    remu x17, x23, x13
    lb x7, 56(x31)
    sb x9, 56(x31)
    sltu x21, x25, x20
    slli x29, x7, 1
    slli x18, x25, 44
    sll x22, x12, x13
    addi x1, x18, -10
    sra x29, x14, x10
    add x9, x22, x23
    bgeu x26, x25, _br_taken_30
    add x24, x8, x29
    j _br_done_30
_br_taken_30:
    sll x24, x25, x25
_br_done_30:
    addi x30, x31, 380
    amoor.w x27, x8, (x30)
    srlw x26, x13, x27
    lh x19, 548(x31)
    sh x6, 548(x31)
    bltu x17, x6, _br_taken_31
    slt x12, x26, x28
    j _br_done_31
_br_taken_31:
    slt x12, x25, x23
_br_done_31:
    srliw x14, x10, 17
    xori x18, x6, 788
    sraiw x4, x10, 23
    sraiw x20, x11, 26
    sub x13, x9, x23
    sltiu x1, x7, 1276
    fmsub.d f6, f29, f11, f13
    blt x25, x15, _br_taken_32
    srl x16, x4, x26
    j _br_done_32
_br_taken_32:
    and x16, x7, x24
_br_done_32:
    srai x13, x16, 13
    srl x22, x14, x15
    blt x11, x26, _br_taken_33
    and x26, x23, x21
    j _br_done_33
_br_taken_33:
    and x26, x24, x5
_br_done_33:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x27ae9d9efbe56cff
    .dword 0x97f78a7fb13c4799
    .dword 0xd02be5fff4a91a0b
    .dword 0x74dd20648fcb3b46
    .dword 0x432753e99783488f
    .dword 0x2733b22d724f4399
    .dword 0xa45566ba988ab007
    .dword 0x233ace8f21c5cca7
    .dword 0xc5038546ab447652
    .dword 0x8f04097c02a13ed5
    .dword 0x23ed0853ba6a69aa
    .dword 0xcbc96c422e319dab
    .dword 0xd264f9af2f918ac3
    .dword 0x98dc3035674cb020
    .dword 0x0ef9660ea18476ca
    .dword 0x02084f6943473554
    .dword 0x582738e7ebfbd012
    .dword 0x8360347333ede884
    .dword 0x8787dad97cb4b3ac
    .dword 0x41197463ca6f93b9
    .dword 0xc3c84dce38cbef62
    .dword 0xb4f4107708aea4c4
    .dword 0x7b4986c55b0210ad
    .dword 0x8356758345464e8d
    .dword 0x81eec307f7ba9a6e
    .dword 0x42b2fd004e0c27ee
    .dword 0x21bb8eb182044b42
    .dword 0x521dd88c463979eb
    .dword 0x3d33bdf061e626d7
    .dword 0x4466e24c25394b5f
    .dword 0xf878cf8eded7150e
    .dword 0xc53b992aebe06ee2

    .align 2
_torture_data:
    .word 0x0df21856
    .word 0xa3ac6d31
    .word 0xff886197
    .word 0xb1018cf5
    .word 0x5a352b81
    .word 0xbf3670cf
    .word 0xc7023099
    .word 0x0bea7649
    .word 0x6b2ea9f6
    .word 0xee801ead
    .word 0x29b07aac
    .word 0xedc5df2f
    .word 0x6c80ef04
    .word 0xbeb76d97
    .word 0xcd6ef62f
    .word 0x79554277
    .word 0xf34bea56
    .word 0x138d8451
    .word 0x617c732c
    .word 0x18db82fd
    .word 0xac121d9d
    .word 0x932a8cba
    .word 0x8aa01041
    .word 0xdcfbb5c5
    .word 0x4e0f3fd6
    .word 0x5db69fa6
    .word 0x942132ff
    .word 0x09acced0
    .word 0x9151a566
    .word 0xa4887b4f
    .word 0xbbb98093
    .word 0xb0e459f4
    .word 0x0dc9ae5f
    .word 0x13fa199b
    .word 0xf5321041
    .word 0xaf7f83c5
    .word 0x266cf2de
    .word 0xf9e20151
    .word 0x46f5f2ed
    .word 0x1f958047
    .word 0x38b91ab0
    .word 0x54e589e6
    .word 0xa82a15c1
    .word 0xd1b4b8c1
    .word 0xdb142011
    .word 0xd562924a
    .word 0xdec41ef3
    .word 0x22538e99
    .word 0xbe4fa2bd
    .word 0x62a0687e
    .word 0xcc3b5bd1
    .word 0xaab8e76a
    .word 0x09546212
    .word 0x0a878410
    .word 0xe29b3c55
    .word 0x18ff7031
    .word 0x5ce10d6d
    .word 0x1a4cdf3d
    .word 0xdfc73185
    .word 0xdae66749
    .word 0xa57a02d7
    .word 0x2730eff9
    .word 0x928d5f72
    .word 0x627d9b19
    .word 0xed9ed890
    .word 0xf2bd1492
    .word 0xfbd82726
    .word 0x45253f2d
    .word 0x29e01a1f
    .word 0x70d1bb50
    .word 0x51579b4f
    .word 0x98da377d
    .word 0xec2e3633
    .word 0x05fab494
    .word 0x9ec71f39
    .word 0x17889cf9
    .word 0x83a117c5
    .word 0x46083d17
    .word 0x5d7075e6
    .word 0x2501f5c8
    .word 0xee4c33a6
    .word 0xca5ffcd0
    .word 0x68830b8b
    .word 0x36e94b76
    .word 0xdaa8ecf5
    .word 0xa43dca27
    .word 0x14e86343
    .word 0x9c783ba5
    .word 0x29c5fc98
    .word 0xe42a231c
    .word 0xb48f4572
    .word 0xc7f0e857
    .word 0xfeb76bc4
    .word 0xb7126ddb
    .word 0xa1fdcdea
    .word 0x66f6b819
    .word 0x94a9e6d6
    .word 0x11c3b299
    .word 0x5061e4f3
    .word 0x98ab6f8a
    .word 0xa5e4e71f
    .word 0xbb0582cf
    .word 0x20ce0676
    .word 0x0d6bb8f8
    .word 0x4ab38c13
    .word 0x4586625b
    .word 0x04f4206d
    .word 0x8471b9a5
    .word 0x4f86060a
    .word 0xa584fec0
    .word 0x43e196fe
    .word 0xc6a707de
    .word 0x0fbec747
    .word 0xbbe22442
    .word 0x6e641448
    .word 0x8a93b67f
    .word 0xb4538e74
    .word 0x7543362c
    .word 0xe1b54886
    .word 0xf7b53777
    .word 0xb529d535
    .word 0xbdfca1cd
    .word 0x2d3f1bca
    .word 0x69151e9d
    .word 0xafbbb2a6
    .word 0xa31ba0ad
    .word 0x76992506
    .word 0x068849a3
    .word 0x0c2808c8
    .word 0x52035c90
    .word 0xa0ddbf64
    .word 0x32c6a389
    .word 0xd48757a6
    .word 0x46156f88
    .word 0x6fe301ab
    .word 0x4fa5161f
    .word 0xd15739ac
    .word 0x37adcde2
    .word 0xdf0891a8
    .word 0x96921c62
    .word 0xaa8a11bd
    .word 0x5b37a924
    .word 0xe06af091
    .word 0xd34b0518
    .word 0xd7fb4770
    .word 0x53e9f401
    .word 0xc7833f85
    .word 0x847665df
    .word 0x7d4cd7b8
    .word 0x6c7f54a3
    .word 0xcb1c4975
    .word 0xe09388ef
    .word 0x23e35603
    .word 0x997f15fc
    .word 0xfab5968e
    .word 0x2c57ce63
    .word 0xf642fee8
    .word 0x42d8c98f
    .word 0x99daeced
    .word 0xb7263b8c
    .word 0x5c0644d5
    .word 0xb67a8ac4
    .word 0x6bfc44c2
    .word 0x0b2c7248
    .word 0xb5fa28fc
    .word 0x92445a99
    .word 0x46ad1be3
    .word 0xf4ccf592
    .word 0x7755e312
    .word 0xc5a23606
    .word 0x832014d1
    .word 0xb3068210
    .word 0x9b4373cd
    .word 0x79cd7cfb
    .word 0xb8834eb1
    .word 0x4242ff94
    .word 0x1c6fd8fd
    .word 0x569826c5
    .word 0x471a42ec
    .word 0x6af17cc7
    .word 0xe5c7fc07
    .word 0xdcabf591
    .word 0xc1b47a46
    .word 0x556da7de
    .word 0xc5525b16
    .word 0x6a3ec098
    .word 0x4d75677b
    .word 0x41ebbedf
    .word 0x8d055b56
    .word 0x39fecf97
    .word 0x6821676e
    .word 0x59874975
    .word 0x84aadee6
    .word 0xafc93ad7
    .word 0xce510823
    .word 0xe05a2953
    .word 0xc135d4fb
    .word 0xd8b5713c
    .word 0x3140f088
    .word 0x413857d2
    .word 0x4a555099
    .word 0x8c6c16e3
    .word 0x9536fd3d
    .word 0xb1224e68
    .word 0xefd6bd0c
    .word 0x21b6d3ec
    .word 0x681bc415
    .word 0x119b64d8
    .word 0xce3c5720
    .word 0x12b7391e
    .word 0xe4ff5cad
    .word 0xf738b670
    .word 0x2c9480ae
    .word 0x959a8592
    .word 0xb75aa09a
    .word 0xea8dc5ae
    .word 0xe53ea9b4
    .word 0x723652b7
    .word 0x94f604a7
    .word 0x0bd45103
    .word 0x95b8427c
    .word 0xed5167c0
    .word 0x7e07a329
    .word 0xd03a9fa8
    .word 0x07636b76
    .word 0xa3a10716
    .word 0xefbb09e6
    .word 0x949570d7
    .word 0xbf7a5a89
    .word 0x2e85f5f5
    .word 0xac57328f
    .word 0x8f29c058
    .word 0xb7eedbb4
    .word 0x83019480
    .word 0xdeb4836d
    .word 0xf019e6d1
    .word 0xab8d9bf7
    .word 0x53e1a393
    .word 0x6229c161
    .word 0x5fd2a79a
    .word 0xae12e65b
    .word 0x634feac0
    .word 0x35123413
    .word 0x1a487689
    .word 0x5322c2c9
    .word 0x41eb8745
    .word 0x42a1b805
    .word 0x0757e463
    .word 0xc04235f4
    .word 0x7c1284fb
    .word 0x1ff5257a
    .word 0xb0cdae89
    .word 0x24aa6cf5
    .word 0x33fab4a6
    .word 0x1958205f
    .word 0x4624afa0

#include "frost_footer.S"
