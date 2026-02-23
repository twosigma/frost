// Generated RV32IMAFDC torture test for Frost (seed=51)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x2974bcb6
    li x4, 0x8d6568e2
    li x5, 0xf7c630a4
    li x6, 0xa1011f73
    li x7, 0x5c377356
    li x8, 0xff28e85f
    li x9, 0xfbdd47bb
    li x10, 0xda423ed3
    li x11, 0x42198998
    li x12, 0x2d7942b5
    li x13, 0x9da7ba99
    li x14, 0x5e016f45
    li x15, 0xc2a23b9c
    li x16, 0xd654325f
    li x17, 0x7859eb79
    li x18, 0xe819c861
    li x19, 0xfc75673b
    li x20, 0x9795a6e9
    li x21, 0xf5da4b97
    li x22, 0x1cada484
    li x23, 0x73481bd2
    li x24, 0xc355143c
    li x25, 0xa6ceff16
    li x26, 0xfb782707
    li x27, 0xc93534d2
    li x28, 0xff3554ca
    li x29, 0x8a0d3ffe
    li x30, 0xd058a8a9
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
    li x1, 0xd49c1e83

    fmin.d f26, f17, f14
    remu x9, x28, x20
    mul x13, x17, x12
    lhu x9, 904(x31)
    sh x20, 904(x31)
    xori x28, x8, -1127
    sll x24, x16, x26
    slt x19, x27, x12
    slti x26, x17, 1866
    andi x7, x28, 1233
    or x13, x13, x15
    ori x20, x17, 1300
    lw x18, 664(x31)
    sw x22, 664(x31)
    srl x28, x16, x11
    add x19, x11, x4
    addi x12, x17, -1456
    sltiu x28, x20, -890
    xor x19, x21, x29
    or x8, x26, x28
    beq x21, x23, _br_taken_0
    add x26, x22, x19
    j _br_done_0
_br_taken_0:
    sltu x26, x26, x27
_br_done_0:
    fnmsub.s f26, f13, f31, f3
    fadd.s f2, f7, f18
    fsub.s f4, f12, f28
    sub x18, x20, x9
    or x9, x20, x10
    xor x26, x28, x18
    addi x9, x1, 659
    andi x12, x5, -730
    lw x6, 620(x31)
    sw x7, 620(x31)
    ori x5, x6, 1088
    slt x29, x16, x13
    beq x17, x8, _br_taken_1
    add x4, x12, x18
    j _br_done_1
_br_taken_1:
    and x4, x4, x25
_br_done_1:
    lw x23, 892(x31)
    sw x13, 892(x31)
    blt x18, x27, _br_taken_2
    sltu x6, x27, x16
    j _br_done_2
_br_taken_2:
    xor x6, x4, x12
_br_done_2:
    fmax.d f10, f11, f31
    fadd.s f27, f19, f7
    fmul.d f28, f14, f21
    bgeu x23, x21, _br_taken_3
    add x17, x4, x10
    j _br_done_3
_br_taken_3:
    sub x17, x27, x16
_br_done_3:
    srai x8, x25, 19
    fadd.s f25, f22, f19
    fsub.d f17, f10, f20
    fadd.s f30, f18, f0
    sub x29, x10, x29
    xori x16, x30, -157
    ori x10, x1, 1805
    addi x26, x31, 516
    amoadd.w x4, x11, (x26)
    blt x1, x20, _br_taken_4
    srl x30, x12, x12
    j _br_done_4
_br_taken_4:
    sra x30, x25, x30
_br_done_4:
    addi x13, x20, 1836
    srl x21, x16, x7
    srai x26, x10, 7
    lw x30, 560(x31)
    sw x20, 560(x31)
    blt x30, x25, _br_taken_5
    add x17, x1, x5
    j _br_done_5
_br_taken_5:
    sub x17, x22, x18
_br_done_5:
    bgeu x26, x14, _br_taken_6
    xor x12, x25, x11
    j _br_done_6
_br_taken_6:
    sll x12, x10, x5
_br_done_6:
    div x26, x30, x13
    divu x7, x25, x25
    srai x10, x1, 6
    ori x12, x13, 1342
    ori x8, x26, -103
    lbu x21, 240(x31)
    sb x9, 240(x31)
    fsub.d f20, f14, f20
    fnmadd.d f5, f4, f22, f14
    mulhsu x29, x20, x27
    divu x28, x1, x20
    or x17, x9, x7
    and x1, x22, x17
    addi x13, x15, 209
    addi x19, x20, -198
    fmin.d f27, f1, f14
    fmul.s f15, f16, f1
    addi x10, x31, 52
    amomin.w x18, x17, (x10)
    lbu x10, 352(x31)
    sb x26, 352(x31)
    add x10, x21, x27
    sltiu x24, x21, 1051
    sra x12, x6, x23
    lw x24, 48(x31)
    sw x1, 48(x31)
    mulh x11, x1, x29
    mulh x22, x27, x21
    slli x16, x29, 17
    slt x26, x5, x16
    and x5, x29, x26
    or x19, x22, x29
    mulhsu x6, x9, x4
    xor x13, x13, x30
    or x11, x18, x29
    bgeu x6, x13, _br_taken_7
    sra x22, x16, x30
    j _br_done_7
_br_taken_7:
    sra x22, x1, x15
_br_done_7:
    fdiv.s f5, f31, f26
    andi x16, x25, -478
    andi x21, x23, 1355
    and x11, x23, x15
    and x11, x17, x5
    srai x26, x17, 23
    addi x22, x8, -1922
    sub x28, x25, x25
    bne x29, x8, _br_taken_8
    srl x29, x28, x14
    j _br_done_8
_br_taken_8:
    sll x29, x10, x4
_br_done_8:
    slt x25, x11, x17
    sra x23, x16, x21
    sra x6, x20, x5
    fmin.s f25, f3, f0
    fdiv.s f27, f13, f12
    fmin.d f28, f3, f6
    addi x24, x31, 104
    amomin.w x4, x10, (x24)
    slli x6, x10, 10
    sltu x5, x17, x20
    srai x16, x20, 29
    rem x6, x23, x20
    andi x1, x5, 46
    andi x4, x19, 1312
    add x25, x20, x1
    srli x13, x13, 2
    srl x11, x18, x13
    fsub.s f16, f15, f10
    fdiv.s f26, f6, f15
    beq x5, x4, _br_taken_9
    srl x10, x24, x17
    j _br_done_9
_br_taken_9:
    xor x10, x4, x28
_br_done_9:
    addi x1, x31, 596
    amomaxu.w x28, x10, (x1)
    or x14, x13, x29
    slt x27, x1, x17
    add x27, x30, x1
    bne x25, x28, _br_taken_10
    xor x21, x12, x25
    j _br_done_10
_br_taken_10:
    xor x21, x9, x4
_br_done_10:
    mul x27, x9, x14
    addi x6, x31, 492
    amoxor.w x7, x9, (x6)
    xori x4, x13, -1548
    bltu x18, x8, _br_taken_11
    xor x26, x24, x14
    j _br_done_11
_br_taken_11:
    xor x26, x25, x18
_br_done_11:
    lbu x19, 296(x31)
    sb x11, 296(x31)
    sll x18, x14, x24
    sub x12, x1, x16
    lw x17, 608(x31)
    sw x16, 608(x31)
    slti x26, x22, -631
    slt x25, x14, x25
    rem x1, x24, x14
    bge x4, x18, _br_taken_12
    xor x13, x12, x21
    j _br_done_12
_br_taken_12:
    srl x13, x21, x13
_br_done_12:
    sll x17, x16, x22
    lw x1, 304(x31)
    sw x8, 304(x31)
    slti x18, x12, -1200
    slti x4, x24, 1452
    andi x5, x26, 1234
    xor x11, x7, x6
    xor x5, x16, x1
    srli x17, x16, 28
    add x4, x28, x15
    andi x9, x25, -335
    sll x30, x28, x13
    and x24, x13, x11
    xor x30, x7, x27
    fmax.s f29, f19, f28
    fadd.s f9, f16, f23
    sll x16, x17, x5
    or x1, x15, x16
    andi x16, x26, 683
    sll x29, x5, x10
    sltu x12, x12, x17
    divu x9, x20, x23
    sltu x6, x7, x13
    addi x27, x6, 1441
    fnmsub.s f10, f14, f5, f4
    fnmadd.s f24, f28, f7, f25
    sltiu x29, x5, 907
    srl x19, x9, x20
    sra x30, x19, x29
    bltu x21, x6, _br_taken_13
    sltu x12, x19, x27
    j _br_done_13
_br_taken_13:
    srl x12, x10, x15
_br_done_13:
    or x14, x20, x25
    fdiv.d f22, f7, f24
    lw x18, 948(x31)
    sw x14, 948(x31)
    slti x28, x11, 996
    xori x30, x25, 153
    sll x29, x14, x12
    slt x5, x9, x22
    lbu x17, 20(x31)
    sb x10, 20(x31)
    sll x30, x19, x28
    slti x14, x13, 1162
    srl x28, x12, x10
    slli x13, x25, 25
    bltu x22, x10, _br_taken_14
    sub x8, x10, x26
    j _br_done_14
_br_taken_14:
    add x8, x21, x1
_br_done_14:
    addi x21, x31, 468
    amoand.w x26, x1, (x21)
    fmul.s f27, f0, f21
    fmax.s f31, f3, f5
    or x27, x28, x9
    or x23, x5, x5
    sltiu x24, x19, 2010
    slli x5, x24, 29
    addi x4, x31, 284
    amoor.w x13, x11, (x4)
    fmax.s f17, f27, f15
    fmax.d f26, f16, f0
    fdiv.d f17, f3, f13
    fmax.s f9, f26, f22
    fmsub.d f0, f3, f29, f22
    fadd.s f20, f12, f1
    fmul.d f19, f16, f8
    sll x4, x12, x13
    lb x1, 232(x31)
    sb x19, 232(x31)
    bltu x20, x29, _br_taken_15
    sub x24, x17, x8
    j _br_done_15
_br_taken_15:
    or x24, x11, x25
_br_done_15:
    srli x26, x26, 18
    or x13, x30, x17
    or x7, x21, x20
    fmadd.s f14, f10, f6, f31
    fadd.d f17, f7, f10
    fmax.d f22, f3, f13
    lhu x22, 132(x31)
    sh x21, 132(x31)
    addi x29, x31, 60
    amomax.w x27, x15, (x29)
    sll x21, x22, x15
    xori x29, x19, -634
    or x29, x12, x28
    ori x25, x26, -1894
    addi x23, x4, -300
    andi x8, x19, 1858
    sra x19, x21, x17
    fnmsub.s f14, f18, f13, f17
    sltu x20, x16, x20
    beq x29, x14, _br_taken_16
    sll x14, x12, x11
    j _br_done_16
_br_taken_16:
    xor x14, x17, x20
_br_done_16:
    sub x21, x23, x12
    sltu x29, x8, x5
    srl x27, x16, x14
    srai x22, x5, 9
    srl x13, x22, x8
    sll x30, x30, x22
    addi x6, x22, -1038
    slt x26, x24, x7
    fsub.s f8, f3, f0
    sltiu x25, x14, 1249
    srl x29, x16, x26
    sra x7, x8, x13
    fsub.d f10, f1, f23
    fmax.d f28, f15, f5
    fmul.d f4, f5, f23
    fmin.s f31, f21, f13
    fnmsub.s f18, f24, f14, f18
    fmsub.d f11, f22, f7, f16
    fnmadd.d f2, f23, f1, f1
    blt x1, x24, _br_taken_17
    and x10, x26, x16
    j _br_done_17
_br_taken_17:
    sub x10, x5, x22
_br_done_17:
    xori x24, x28, 427
    slli x30, x12, 20
    xori x29, x10, -644
    slli x19, x12, 27
    srl x4, x18, x23
    bne x29, x29, _br_taken_18
    sra x4, x29, x24
    j _br_done_18
_br_taken_18:
    sra x4, x16, x20
_br_done_18:
    addi x26, x31, 400
    amoswap.w x11, x8, (x26)
    xori x21, x28, 860
    ori x7, x8, -2006
    xori x25, x23, 440
    slli x29, x8, 18
    sltu x24, x11, x10
    fmax.d f10, f14, f13
    fmin.s f30, f9, f13
    fmul.d f4, f22, f12
    add x9, x30, x10
    sll x16, x20, x5
    srai x26, x22, 18
    sra x8, x27, x15
    sll x30, x28, x21
    xori x6, x12, -1027
    srai x22, x29, 0
    srai x9, x18, 11
    xor x19, x24, x28
    bgeu x1, x7, _br_taken_19
    sra x5, x29, x4
    j _br_done_19
_br_taken_19:
    add x5, x28, x27
_br_done_19:
    sub x13, x12, x16
    srl x29, x22, x17
    sll x12, x24, x12
    blt x8, x26, _br_taken_20
    and x15, x20, x14
    j _br_done_20
_br_taken_20:
    sltu x15, x15, x8
_br_done_20:
    xori x23, x14, -1753
    or x24, x19, x25
    sltiu x13, x15, 1301
    slti x26, x28, -115
    add x27, x24, x12
    xori x12, x7, 1018
    ori x28, x23, -1692
    sra x26, x23, x5
    slti x23, x1, 2037
    srl x1, x17, x1
    sub x15, x21, x27
    bgeu x23, x15, _br_taken_21
    sll x11, x15, x8
    j _br_done_21
_br_taken_21:
    sll x11, x6, x10
_br_done_21:
    blt x1, x12, _br_taken_22
    srl x9, x6, x7
    j _br_done_22
_br_taken_22:
    or x9, x22, x5
_br_done_22:
    fsub.d f29, f8, f2
    fmsub.d f31, f11, f6, f1
    lb x19, 468(x31)
    sb x17, 468(x31)
    xori x20, x17, 795
    srli x13, x29, 12
    sltiu x17, x12, 1482
    lbu x8, 620(x31)
    sb x26, 620(x31)
    ori x9, x26, 1821
    slt x12, x7, x8
    sra x25, x23, x16
    slli x16, x13, 5
    xori x12, x28, -1666
    fmax.s f1, f14, f18
    fsub.s f20, f13, f9
    fmin.s f18, f31, f30
    and x20, x17, x14
    or x5, x4, x16
    beq x11, x13, _br_taken_23
    sra x13, x18, x26
    j _br_done_23
_br_taken_23:
    sra x13, x7, x26
_br_done_23:
    ori x4, x29, -240
    slti x30, x22, 681
    xor x6, x20, x23
    sll x9, x12, x21
    slli x6, x8, 14
    srli x6, x18, 24
    andi x29, x16, -355
    srli x13, x19, 13
    fadd.d f10, f27, f16
    lb x8, 932(x31)
    sb x29, 932(x31)
    srai x10, x6, 13
    andi x12, x12, 799
    and x26, x8, x28
    slli x12, x11, 19
    srai x24, x21, 15
    addi x6, x13, 1001
    andi x26, x15, 644
    andi x30, x14, -1312
    srli x21, x29, 9
    bltu x7, x23, _br_taken_24
    sra x10, x15, x23
    j _br_done_24
_br_taken_24:
    add x10, x11, x16
_br_done_24:
    srai x29, x16, 9
    srli x25, x12, 21
    ori x1, x4, 1731
    xor x24, x24, x26
    srai x4, x16, 0
    sub x29, x11, x9
    beq x13, x26, _br_taken_25
    sltu x14, x1, x16
    j _br_done_25
_br_taken_25:
    or x14, x5, x6
_br_done_25:
    and x14, x14, x15
    sub x23, x23, x1
    or x18, x24, x12
    fsub.d f30, f5, f26
    srai x6, x16, 20
    sll x24, x27, x12
    sub x21, x15, x18
    and x12, x22, x20
    fmin.d f13, f22, f0
    fmax.s f14, f14, f3
    fnmsub.s f31, f20, f17, f14
    fmsub.d f3, f30, f11, f10
    beq x23, x8, _br_taken_26
    add x15, x1, x13
    j _br_done_26
_br_taken_26:
    or x15, x1, x27
_br_done_26:
    sll x11, x18, x22
    sltu x19, x24, x19
    or x21, x4, x12
    srli x17, x14, 28
    or x22, x15, x18
    slli x9, x27, 29
    addi x11, x20, 711
    xor x23, x1, x8
    xori x23, x1, -1684
    srl x9, x27, x29
    ori x7, x27, 1261
    slti x19, x11, 1669
    sltu x4, x28, x30
    bltu x6, x24, _br_taken_27
    or x26, x12, x29
    j _br_done_27
_br_taken_27:
    slt x26, x30, x22
_br_done_27:
    slt x1, x22, x24
    sll x30, x28, x9
    sra x30, x19, x27
    sltu x6, x22, x17
    sra x21, x9, x28
    fadd.d f1, f23, f11
    fsub.s f2, f11, f9
    srli x14, x15, 25
    slli x25, x1, 23
    or x18, x14, x25
    beq x13, x18, _br_taken_28
    and x22, x29, x29
    j _br_done_28
_br_taken_28:
    sltu x22, x17, x17
_br_done_28:
    ori x10, x22, 289
    xori x24, x14, -573
    srli x15, x17, 31

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x1bf2d0303dd735f7
    .dword 0x19416c002e1ef78e
    .dword 0xe17b6de9bb1993c5
    .dword 0x6547957b9ac3bfec
    .dword 0xbf016efa2d84a298
    .dword 0x96bc357333464f23
    .dword 0x37b276d7d9262b23
    .dword 0x3bcc0b5a5f40cda9
    .dword 0xdc3daa304066780d
    .dword 0x7d63fe5d53ab7c2a
    .dword 0xa815f6b5a113c194
    .dword 0x1c1c6f58e3f00dc8
    .dword 0x5bee99d56e505021
    .dword 0xec817e5f2d2ad5a4
    .dword 0x90dbe9756e47dd65
    .dword 0xf8a497e0d0d0724c
    .dword 0x6a8939a620b46fac
    .dword 0xdff9dd7078468f7f
    .dword 0x8fc5f244f156425a
    .dword 0x640762bae5b0b330
    .dword 0xd161d5533bff1ec8
    .dword 0x25350d479898a7b7
    .dword 0x31577d05a8ce6bf4
    .dword 0x6def948284588de2
    .dword 0x06fafe19f108d6ca
    .dword 0x9326fbfa217015fa
    .dword 0xef8c57152218a5f6
    .dword 0x62cb7ee8e9c23049
    .dword 0xe4fe6ee79c740f31
    .dword 0xb0109727e8c1c5df
    .dword 0x82779bd6b23ef0de
    .dword 0xaaa891893bf55863

    .align 2
_torture_data:
    .word 0x4ea7d8d1
    .word 0x7e9987b4
    .word 0xcefb32a2
    .word 0xd05057d5
    .word 0x48539a1f
    .word 0xc5a84454
    .word 0x65a75c4f
    .word 0x68a4c0be
    .word 0x24dc8373
    .word 0x1a11729a
    .word 0xa6fdc87c
    .word 0x8d24c7f3
    .word 0x8272c9e7
    .word 0xca5c7714
    .word 0x97b005e0
    .word 0x0fbbb78e
    .word 0x547ae1eb
    .word 0xb9182aff
    .word 0x434a4b78
    .word 0x817ab9c0
    .word 0x0bd11d8c
    .word 0x322ca5db
    .word 0x335d36ce
    .word 0x8317bb72
    .word 0xf4aff125
    .word 0x5735643f
    .word 0x2f8b724f
    .word 0x1ae199cf
    .word 0x71e2d1c1
    .word 0xfb66f94d
    .word 0x8ce68a57
    .word 0x1e4c38d6
    .word 0xd1f5f092
    .word 0xf6c575d2
    .word 0x222474c6
    .word 0x62e820d7
    .word 0xc7dc8145
    .word 0x37aac108
    .word 0xa31ca4c0
    .word 0xda9592cf
    .word 0x4a476c08
    .word 0xc85961da
    .word 0xa1d26825
    .word 0x22684ca4
    .word 0x5d00697d
    .word 0xda678ff9
    .word 0xaf5ac42f
    .word 0x93170386
    .word 0x027e15d7
    .word 0x6f1638ef
    .word 0x6d105b51
    .word 0x204529f5
    .word 0x8bfb0121
    .word 0xcc628aec
    .word 0x5a983b08
    .word 0xb6a4fdaf
    .word 0xd750ed18
    .word 0xdeea0473
    .word 0x1ed894eb
    .word 0xdae61c44
    .word 0x83248c9b
    .word 0xe55d5368
    .word 0x680aae32
    .word 0xc1ec1312
    .word 0xda9afd41
    .word 0x79301cb5
    .word 0x4e9e733c
    .word 0x1618569b
    .word 0xd9114f76
    .word 0x81a930d7
    .word 0x22d15978
    .word 0x6b6800b5
    .word 0xcd612958
    .word 0xac1740f3
    .word 0x0bbe492f
    .word 0x46bade31
    .word 0xd09f0ea7
    .word 0x956fc720
    .word 0x91b95628
    .word 0x89412260
    .word 0x0cbf4f52
    .word 0xba9ede89
    .word 0x00386249
    .word 0x0660a9fe
    .word 0x4ba6062e
    .word 0x791dd1cd
    .word 0x0032bf08
    .word 0x3b3baa3e
    .word 0x787194d5
    .word 0x1e297512
    .word 0xbc208cb0
    .word 0x7a90e155
    .word 0xc76b981f
    .word 0x9bb0f842
    .word 0x24a2c4c4
    .word 0x5b695a33
    .word 0xe6f79012
    .word 0x7696c663
    .word 0x65dfb6d7
    .word 0x7251d74e
    .word 0x69ae189c
    .word 0x3468326a
    .word 0xf5d7ee3b
    .word 0xa247251a
    .word 0x7a6dda0a
    .word 0xe8c72c38
    .word 0xdaf71c77
    .word 0x19b54866
    .word 0x39f5d7a8
    .word 0x3be1124e
    .word 0x20739931
    .word 0xc5e38310
    .word 0x4b02406b
    .word 0xdb9c789a
    .word 0x342a6281
    .word 0x64bf2b77
    .word 0x869e8bb3
    .word 0xdb1a66ba
    .word 0xf7b29004
    .word 0xab8f2969
    .word 0x71f62712
    .word 0xe387cf1b
    .word 0x533b9fd7
    .word 0xe3d32ebe
    .word 0xcdb05ede
    .word 0xc4eade5c
    .word 0xb806f8ed
    .word 0xc2a15aed
    .word 0x9ac8d70d
    .word 0xaca0dd47
    .word 0x53b81cef
    .word 0x6bec1052
    .word 0x9664a62e
    .word 0x768523ae
    .word 0x383f3ba0
    .word 0xf87764e3
    .word 0x0ab7fb3c
    .word 0xd2dbb956
    .word 0x03d348ea
    .word 0x99f26a21
    .word 0x7bd9a989
    .word 0xedd5e911
    .word 0xcbe51442
    .word 0xafe47707
    .word 0x58d27865
    .word 0x2e07b1d0
    .word 0x8252617c
    .word 0x7cc306bb
    .word 0x276e48c1
    .word 0xb0a0c178
    .word 0x1f9cdf48
    .word 0x7376be73
    .word 0x7d381641
    .word 0xfd17178c
    .word 0xf3b864df
    .word 0xa595794d
    .word 0x91fc01c3
    .word 0xe11a925c
    .word 0xbc55f0e2
    .word 0x2116ef23
    .word 0x891c087a
    .word 0x316a85c2
    .word 0xce5b7c98
    .word 0x7e073d1b
    .word 0x2dcf4fdc
    .word 0x1bacec5c
    .word 0xa063fe26
    .word 0x58e69c2c
    .word 0x068db461
    .word 0x6b7d2188
    .word 0x2882eab7
    .word 0xc974f6a8
    .word 0x9031827b
    .word 0x75d3ce61
    .word 0x32e2e7a7
    .word 0xe7faf383
    .word 0x9c0c1af1
    .word 0xd465e6d7
    .word 0x447bbf52
    .word 0xb38afae4
    .word 0xe440663f
    .word 0xec771a01
    .word 0x89207d5e
    .word 0x61c0d4b4
    .word 0xef53150e
    .word 0x2d26f9c2
    .word 0x684a9765
    .word 0xa489acf0
    .word 0x3441c237
    .word 0x0c4b3650
    .word 0xc0cdaf80
    .word 0x931e354c
    .word 0x9c93ffe6
    .word 0xbc051833
    .word 0x9c81d1ca
    .word 0x742a348e
    .word 0x71b6f78f
    .word 0x3eeb5cdc
    .word 0x861913f0
    .word 0xe3f81f54
    .word 0xf842f4d3
    .word 0x89839edd
    .word 0x5f8438f3
    .word 0xd4f1810a
    .word 0x5012173c
    .word 0xb32c5313
    .word 0x72be3be9
    .word 0xcb295ac4
    .word 0xb9491e7b
    .word 0x292291c5
    .word 0xa75053fa
    .word 0xf031166c
    .word 0xf943437d
    .word 0x2b64c80b
    .word 0x7d27c584
    .word 0xed43ac40
    .word 0xca4cd34c
    .word 0xc81750c1
    .word 0x35424938
    .word 0x2dc968d3
    .word 0x8b18eda0
    .word 0xa18bcf81
    .word 0xe63c98ab
    .word 0xe0023771
    .word 0xaf1135d3
    .word 0x290cd23d
    .word 0x78513392
    .word 0xe40db5a1
    .word 0x2d337bde
    .word 0x8e148171
    .word 0x1893ee3f
    .word 0xc62bbd77
    .word 0x1e087b5e
    .word 0x1d395d94
    .word 0x71d74ea2
    .word 0x9e3458a3
    .word 0x8334728a
    .word 0x6db57822
    .word 0x7ea7b224
    .word 0xe8a42406
    .word 0x32123691
    .word 0xcb3e4628
    .word 0x5a0fd0cd
    .word 0xdf551f8c
    .word 0x2929530c
    .word 0x9ef20be7
    .word 0x02a34524
    .word 0xf0a76225
    .word 0xa9182fb2
    .word 0xd11ce8cb
    .word 0xe5f2a1d8
    .word 0xa9257335
    .word 0x4e277402
    .word 0xb859480a
    .word 0xd32b960e
    .word 0xa8035446

#include "frost_footer.S"
