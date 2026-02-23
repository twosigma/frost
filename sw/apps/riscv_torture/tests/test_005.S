// Generated RV32IMAFDC torture test for Frost (seed=46)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xe3658966
    li x4, 0x66660879
    li x5, 0x84060c46
    li x6, 0x083d0a2f
    li x7, 0xd3393b0f
    li x8, 0xd7d8a6c3
    li x9, 0xeb66f988
    li x10, 0x871be443
    li x11, 0x17c9b326
    li x12, 0x7a8efdeb
    li x13, 0x27f6e649
    li x14, 0x13069e53
    li x15, 0x1c0072e5
    li x16, 0x39f2a8a7
    li x17, 0x81aeb810
    li x18, 0x466af77f
    li x19, 0x55e8dc40
    li x20, 0xdf312a07
    li x21, 0x2f09e298
    li x22, 0x4d3e6fc3
    li x23, 0xad3e63e2
    li x24, 0x1da45e02
    li x25, 0x8f62cb88
    li x26, 0x8ae86eff
    li x27, 0x10d971d8
    li x28, 0xdbb6cdef
    li x29, 0x4d040862
    li x30, 0x08f81be3
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
    li x1, 0xc65f96c6

    xor x23, x8, x7
    bltu x27, x30, _br_taken_0
    sra x29, x26, x24
    j _br_done_0
_br_taken_0:
    xor x29, x15, x25
_br_done_0:
    addi x7, x31, 776
    amominu.w x24, x12, (x7)
    sub x15, x29, x13
    sltiu x13, x4, 1272
    or x18, x12, x12
    srai x1, x22, 21
    div x26, x4, x22
    remu x4, x25, x27
    add x30, x29, x5
    sltu x22, x25, x9
    sra x8, x24, x1
    xori x5, x22, -164
    slli x22, x14, 0
    sll x9, x4, x13
    bgeu x18, x11, _br_taken_1
    sll x15, x12, x6
    j _br_done_1
_br_taken_1:
    sll x15, x13, x10
_br_done_1:
    and x21, x26, x30
    slli x18, x22, 30
    lhu x22, 488(x31)
    sh x16, 488(x31)
    mulhsu x30, x25, x21
    mulh x10, x16, x7
    or x4, x13, x28
    slli x9, x22, 20
    slt x4, x7, x28
    lhu x14, 568(x31)
    sh x18, 568(x31)
    bge x7, x10, _br_taken_2
    sra x13, x16, x13
    j _br_done_2
_br_taken_2:
    and x13, x14, x9
_br_done_2:
    srai x24, x27, 30
    srli x13, x5, 8
    add x7, x27, x29
    sll x30, x9, x30
    ori x6, x1, -104
    sltu x15, x19, x23
    sltu x14, x13, x30
    fnmsub.s f10, f6, f5, f11
    fmax.d f18, f22, f24
    andi x5, x4, -994
    or x1, x4, x26
    sltiu x9, x11, 1035
    rem x12, x18, x22
    div x11, x4, x15
    srli x13, x30, 3
    add x14, x16, x9
    addi x13, x24, 603
    xori x23, x14, 1278
    addi x29, x31, 336
    amomaxu.w x14, x20, (x29)
    bgeu x24, x23, _br_taken_3
    and x6, x28, x13
    j _br_done_3
_br_taken_3:
    slt x6, x26, x8
_br_done_3:
    srli x7, x13, 9
    ori x28, x20, 1795
    sltiu x16, x9, -891
    slti x22, x14, 1217
    lhu x6, 572(x31)
    sh x28, 572(x31)
    or x6, x21, x16
    slli x21, x7, 14
    addi x29, x31, 860
    amominu.w x18, x21, (x29)
    srli x30, x10, 11
    srai x30, x15, 12
    srli x17, x6, 31
    bge x26, x8, _br_taken_4
    or x21, x11, x9
    j _br_done_4
_br_taken_4:
    and x21, x13, x28
_br_done_4:
    bne x12, x30, _br_taken_5
    srl x19, x27, x7
    j _br_done_5
_br_taken_5:
    sll x19, x25, x18
_br_done_5:
    addi x19, x17, 562
    and x29, x9, x27
    sll x27, x18, x18
    lhu x28, 328(x31)
    sh x18, 328(x31)
    srl x1, x30, x15
    sub x27, x14, x27
    sltiu x26, x14, 332
    add x27, x7, x18
    srl x18, x20, x9
    sltiu x16, x14, -1850
    bgeu x6, x19, _br_taken_6
    sll x12, x10, x28
    j _br_done_6
_br_taken_6:
    sra x12, x6, x6
_br_done_6:
    beq x8, x4, _br_taken_7
    add x22, x23, x16
    j _br_done_7
_br_taken_7:
    slt x22, x6, x22
_br_done_7:
    srl x29, x26, x25
    ori x10, x15, -189
    slli x18, x1, 15
    addi x22, x31, 812
    amoadd.w x5, x5, (x22)
    ori x9, x1, -973
    srli x29, x5, 0
    or x19, x26, x8
    or x29, x26, x8
    and x22, x15, x16
    rem x24, x11, x23
    xori x28, x8, -922
    fmadd.d f17, f26, f21, f8
    fmadd.d f13, f6, f25, f20
    beq x29, x9, _br_taken_8
    sra x9, x4, x17
    j _br_done_8
_br_taken_8:
    add x9, x14, x25
_br_done_8:
    ori x24, x21, 84
    srl x29, x7, x13
    slti x28, x13, -1815
    lw x13, 784(x31)
    sw x25, 784(x31)
    srl x17, x29, x11
    srai x13, x18, 7
    sltiu x18, x26, 496
    xori x27, x5, -999
    ori x7, x22, 932
    sra x7, x21, x14
    slt x26, x15, x10
    sll x12, x4, x15
    andi x20, x28, -1961
    xori x11, x4, 775
    srai x17, x6, 26
    srai x13, x26, 6
    xor x20, x7, x24
    bge x28, x8, _br_taken_9
    and x9, x1, x15
    j _br_done_9
_br_taken_9:
    sll x9, x13, x15
_br_done_9:
    lh x22, 496(x31)
    sh x4, 496(x31)
    srai x15, x19, 8
    slt x6, x5, x15
    xori x17, x29, 699
    srli x25, x4, 9
    sltu x23, x25, x9
    srli x27, x1, 20
    slti x14, x23, -1877
    srl x4, x28, x17
    addi x30, x31, 580
    amoswap.w x17, x1, (x30)
    blt x4, x24, _br_taken_10
    sra x24, x20, x1
    j _br_done_10
_br_taken_10:
    srl x24, x22, x12
_br_done_10:
    lhu x15, 856(x31)
    sh x18, 856(x31)
    fnmsub.s f29, f4, f30, f29
    fmin.d f25, f26, f27
    bgeu x17, x12, _br_taken_11
    slt x28, x11, x13
    j _br_done_11
_br_taken_11:
    or x28, x4, x5
_br_done_11:
    lw x17, 688(x31)
    sw x18, 688(x31)
    bge x7, x25, _br_taken_12
    sub x6, x15, x27
    j _br_done_12
_br_taken_12:
    srl x6, x28, x9
_br_done_12:
    or x8, x11, x5
    sub x11, x14, x9
    addi x22, x31, 100
    amomax.w x16, x23, (x22)
    srl x5, x30, x10
    srli x11, x25, 10
    sll x6, x14, x16
    sll x10, x21, x17
    slli x21, x10, 18
    addi x1, x30, 734
    sltiu x22, x17, 1179
    addi x23, x18, -735
    addi x8, x31, 352
    amominu.w x28, x20, (x8)
    fmsub.s f23, f6, f24, f26
    fmul.s f11, f24, f13
    fadd.s f26, f31, f18
    mul x4, x8, x4
    srli x12, x6, 12
    and x22, x27, x10
    andi x19, x22, 263
    remu x24, x4, x17
    rem x27, x15, x25
    srl x25, x19, x1
    or x8, x11, x17
    slt x15, x11, x8
    ori x26, x24, -1020
    ori x7, x20, -1092
    slli x18, x18, 14
    slli x28, x10, 28
    sub x13, x9, x14
    ori x23, x23, -1028
    slt x20, x18, x11
    xori x7, x25, 321
    sub x18, x1, x12
    sra x12, x30, x30
    slti x18, x25, 739
    bltu x10, x8, _br_taken_13
    srl x24, x7, x30
    j _br_done_13
_br_taken_13:
    slt x24, x15, x4
_br_done_13:
    srai x12, x16, 20
    sll x28, x8, x21
    fmin.d f4, f4, f16
    srai x20, x26, 10
    slt x17, x30, x25
    srli x9, x17, 8
    sltiu x8, x24, -708
    xori x22, x8, -275
    sltu x13, x21, x4
    srai x27, x29, 5
    sub x9, x8, x16
    beq x24, x15, _br_taken_14
    and x12, x14, x16
    j _br_done_14
_br_taken_14:
    sll x12, x20, x21
_br_done_14:
    and x16, x24, x4
    and x11, x28, x8
    sra x9, x14, x20
    addi x20, x9, -1691
    and x15, x6, x19
    andi x26, x27, -987
    xori x12, x27, 2026
    xor x9, x26, x26
    bgeu x9, x22, _br_taken_15
    add x6, x23, x17
    j _br_done_15
_br_taken_15:
    sll x6, x24, x20
_br_done_15:
    srl x30, x14, x5
    srli x12, x10, 8
    srai x28, x12, 0
    slt x29, x18, x20
    xori x7, x24, 627
    sll x19, x13, x16
    addi x9, x21, -1360
    srl x1, x15, x16
    slli x25, x16, 16
    lw x4, 600(x31)
    sw x13, 600(x31)
    andi x5, x26, 1072
    srai x15, x13, 28
    add x16, x21, x30
    sll x9, x15, x4
    srl x24, x9, x21
    bne x19, x29, _br_taken_16
    add x1, x6, x4
    j _br_done_16
_br_taken_16:
    sll x1, x27, x24
_br_done_16:
    lb x29, 508(x31)
    sb x18, 508(x31)
    srli x18, x30, 24
    srl x27, x27, x14
    ori x12, x5, 1646
    sra x26, x25, x28
    sltiu x24, x22, -1877
    bge x30, x26, _br_taken_17
    sltu x19, x5, x5
    j _br_done_17
_br_taken_17:
    sra x19, x10, x25
_br_done_17:
    slt x20, x24, x1
    or x7, x25, x19
    sra x18, x8, x8
    slt x21, x11, x1
    sll x30, x15, x29
    srli x7, x14, 24
    sltu x10, x18, x30
    mulhsu x18, x16, x16
    srli x13, x30, 21
    slli x9, x7, 30
    andi x27, x12, 181
    bne x24, x13, _br_taken_18
    add x1, x23, x14
    j _br_done_18
_br_taken_18:
    slt x1, x26, x1
_br_done_18:
    bge x14, x13, _br_taken_19
    srl x6, x18, x8
    j _br_done_19
_br_taken_19:
    sub x6, x28, x8
_br_done_19:
    sra x23, x18, x8
    and x5, x29, x6
    or x1, x23, x1
    and x4, x29, x19
    add x28, x10, x22
    addi x7, x31, 996
    amomin.w x28, x16, (x7)
    add x4, x15, x8
    srl x5, x27, x10
    xor x11, x20, x4
    addi x15, x31, 972
    amomaxu.w x19, x10, (x15)
    bge x13, x1, _br_taken_20
    slt x29, x26, x20
    j _br_done_20
_br_taken_20:
    srl x29, x21, x13
_br_done_20:
    sra x10, x16, x26
    ori x20, x12, -831
    slt x13, x12, x28
    add x25, x5, x17
    mulhu x20, x9, x10
    mulhsu x7, x27, x10
    fadd.s f14, f4, f6
    lbu x28, 680(x31)
    sb x21, 680(x31)
    slt x27, x9, x4
    or x19, x6, x4
    bltu x20, x23, _br_taken_21
    sll x18, x9, x28
    j _br_done_21
_br_taken_21:
    sltu x18, x22, x1
_br_done_21:
    add x14, x27, x17
    fmadd.d f31, f16, f30, f4
    fdiv.s f16, f7, f18
    slli x10, x22, 31
    andi x20, x10, 693
    srai x14, x15, 14
    slti x12, x19, -758
    addi x24, x31, 136
    amoand.w x18, x19, (x24)
    or x14, x29, x12
    addi x30, x31, 104
    amoor.w x26, x28, (x30)
    ori x8, x9, -795
    xori x19, x6, -1314
    lh x15, 672(x31)
    sh x26, 672(x31)
    slli x10, x24, 21
    sltu x4, x8, x16
    blt x26, x22, _br_taken_22
    sll x25, x28, x4
    j _br_done_22
_br_taken_22:
    sub x25, x21, x29
_br_done_22:
    lb x10, 544(x31)
    sb x9, 544(x31)
    slli x29, x5, 30
    addi x18, x31, 812
    amoswap.w x27, x4, (x18)
    bne x10, x16, _br_taken_23
    slt x7, x30, x23
    j _br_done_23
_br_taken_23:
    and x7, x20, x4
_br_done_23:
    sltu x7, x16, x12
    slti x14, x20, 1690
    sltiu x12, x1, -1948
    rem x20, x10, x10
    sll x15, x28, x15
    srai x28, x17, 5
    sll x26, x1, x23
    srli x23, x1, 7
    sra x13, x6, x30
    lw x10, 532(x31)
    sw x1, 532(x31)
    addi x29, x6, -1330
    xori x25, x13, -1432
    fmax.s f20, f3, f1
    fadd.d f22, f17, f8
    andi x30, x28, 537
    slli x16, x26, 16
    ori x12, x28, -1898
    blt x14, x4, _br_taken_24
    and x6, x20, x20
    j _br_done_24
_br_taken_24:
    slt x6, x7, x27
_br_done_24:
    lbu x4, 268(x31)
    sb x17, 268(x31)
    andi x8, x22, -834
    sltu x18, x8, x29
    srl x21, x19, x22
    blt x16, x19, _br_taken_25
    sra x15, x5, x30
    j _br_done_25
_br_taken_25:
    or x15, x6, x27
_br_done_25:
    sub x17, x4, x20
    bltu x11, x15, _br_taken_26
    add x30, x17, x1
    j _br_done_26
_br_taken_26:
    sll x30, x18, x26
_br_done_26:
    srli x17, x7, 29
    or x28, x25, x27
    sltiu x25, x18, -413
    bge x30, x5, _br_taken_27
    sub x20, x19, x11
    j _br_done_27
_br_taken_27:
    sra x20, x30, x19
_br_done_27:
    andi x4, x16, -296
    add x21, x9, x15
    srl x13, x14, x10
    xori x26, x30, 1375
    sltu x26, x10, x1
    sltiu x30, x28, -1898
    and x19, x27, x11
    and x19, x25, x7
    and x13, x19, x29
    slt x4, x8, x13
    or x7, x14, x27
    beq x5, x12, _br_taken_28
    sra x25, x23, x30
    j _br_done_28
_br_taken_28:
    or x25, x5, x13
_br_done_28:
    fdiv.d f28, f9, f14
    fdiv.d f23, f2, f1
    fmadd.s f5, f18, f2, f13
    sltiu x16, x26, -1330
    addi x18, x31, 680
    amoor.w x9, x1, (x18)
    bltu x8, x23, _br_taken_29
    sub x13, x17, x21
    j _br_done_29
_br_taken_29:
    sltu x13, x12, x7
_br_done_29:
    slti x13, x30, -279
    sll x5, x13, x26
    srli x19, x23, 10
    addi x14, x31, 640
    amoand.w x12, x10, (x14)
    slti x13, x29, -1234
    sltiu x16, x30, -246
    addi x12, x30, -760
    sltu x29, x21, x23
    ori x9, x9, 1903
    or x18, x29, x22
    and x18, x27, x15
    mulhsu x6, x28, x19
    remu x18, x5, x29
    mul x10, x7, x1
    xor x27, x25, x22
    addi x6, x25, 638
    sltu x22, x1, x14
    bgeu x13, x4, _br_taken_30
    sll x8, x7, x11
    j _br_done_30
_br_taken_30:
    sll x8, x27, x16
_br_done_30:
    sll x15, x30, x10
    xori x11, x23, -1839
    or x26, x18, x21
    slt x10, x16, x6
    andi x1, x24, -1501
    srl x6, x25, x20
    lw x4, 880(x31)
    sw x6, 880(x31)
    bltu x28, x21, _br_taken_31
    sub x22, x25, x23
    j _br_done_31
_br_taken_31:
    sra x22, x5, x25
_br_done_31:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x1371f66d3b842c31
    .dword 0x1593251bc620f492
    .dword 0xb846ad12dcb69557
    .dword 0x0a63759a39b824be
    .dword 0x43447800867b4802
    .dword 0xd13d3ff927b25c12
    .dword 0xf71d8768bd6bdf33
    .dword 0x43dbdc8ef44d91d7
    .dword 0xad3f1f1ac67def70
    .dword 0x1a3a17e8bc95c2a2
    .dword 0xebf6f31b5af3f779
    .dword 0x923d38e74857023d
    .dword 0xa4bb9637f370fd70
    .dword 0x18117e9ca12b294d
    .dword 0x75dfbb1190d6d2e7
    .dword 0x2e3e1d630ffa74ef
    .dword 0xe1f4a33e4d9a729d
    .dword 0x0992395193df05f4
    .dword 0xa22c6eedcac2d525
    .dword 0xc851a1b559f854f7
    .dword 0x9fe177de835f1786
    .dword 0x179e14f78cde1cf9
    .dword 0x2075aa7d88f7bb11
    .dword 0x28fd8fc7bd625098
    .dword 0xceb60feac324352f
    .dword 0xfb535d1376a5829e
    .dword 0x6112627ba3065a35
    .dword 0xba74a03be6962a2d
    .dword 0xa72483c05a1a9e62
    .dword 0x7afdd0b75dbb3a55
    .dword 0x200e2a99ccf7c159
    .dword 0x9ec00d45ebb9a19a

    .align 2
_torture_data:
    .word 0x67515bfc
    .word 0x81b61765
    .word 0xad43e915
    .word 0x2058ff24
    .word 0x0635ff21
    .word 0x00421d4c
    .word 0x823928a4
    .word 0xd374d53d
    .word 0x71b979a0
    .word 0x7d2633e0
    .word 0xcc2d63a4
    .word 0x7d211569
    .word 0x934b81aa
    .word 0x252b6f68
    .word 0xfb35264d
    .word 0x7e362651
    .word 0xc9954cae
    .word 0xd6fea141
    .word 0xe0d5ad59
    .word 0x0d8f1d9a
    .word 0x41dffb24
    .word 0x83243353
    .word 0x2373ccbb
    .word 0xfb6dad19
    .word 0x37303f43
    .word 0x828aa81a
    .word 0x5f6154b7
    .word 0xa6c5b794
    .word 0x6e8fa08d
    .word 0x1156810b
    .word 0x0d364fcd
    .word 0x38a570f4
    .word 0x301f6428
    .word 0x41fc82b5
    .word 0x359a6238
    .word 0x17aa6082
    .word 0x245c56ef
    .word 0xa306c4a6
    .word 0xbad20c2f
    .word 0xe5f37d31
    .word 0x8e668495
    .word 0x2b681930
    .word 0x82e3c0f6
    .word 0x8da3b479
    .word 0xa8caaee8
    .word 0x1861767e
    .word 0x86dcf065
    .word 0x3e96b28d
    .word 0x8c1306c9
    .word 0x710d82e2
    .word 0x60f3896a
    .word 0x6e7ba8cd
    .word 0xff93880d
    .word 0x4c083573
    .word 0xe7922ba3
    .word 0x482695f8
    .word 0x81b33b81
    .word 0x59cac2a8
    .word 0x3907aeef
    .word 0x90a3c385
    .word 0xebb29a11
    .word 0xa4b6ae97
    .word 0x03dc2fda
    .word 0x8cde393c
    .word 0x4f46ba5f
    .word 0x4a0c94eb
    .word 0xa8f8ed3d
    .word 0x7b2ae6ed
    .word 0x47729802
    .word 0xbbf2d673
    .word 0xfdc20fed
    .word 0xee7f2a2e
    .word 0x2db3a074
    .word 0x1519f581
    .word 0x83bb4c0d
    .word 0xff1b4af5
    .word 0x4aa0a2ef
    .word 0xdfb1de6f
    .word 0x0b8c6891
    .word 0x2e16d5c2
    .word 0x76e31633
    .word 0xfa9b7e30
    .word 0x8de50a5b
    .word 0x2581c8cd
    .word 0x41077e8a
    .word 0xea430b86
    .word 0x273c4ce3
    .word 0xa3d9c788
    .word 0xccf5fbd2
    .word 0x9f871a9e
    .word 0xc8abc640
    .word 0x797c5aa0
    .word 0x02ba1664
    .word 0xb63236e4
    .word 0x5126008f
    .word 0x524837f5
    .word 0x1c467e4a
    .word 0x425820cf
    .word 0xbd80ced8
    .word 0x45112d15
    .word 0x9e00cee7
    .word 0x7fcabd47
    .word 0xc80bd893
    .word 0xe1c1f6b7
    .word 0xe24304d7
    .word 0x95c7e475
    .word 0xab6c501f
    .word 0x4cafa9f7
    .word 0x9a272af2
    .word 0xdc5e56b9
    .word 0x46bc513c
    .word 0x44ccf0ea
    .word 0x17be4284
    .word 0x362e6ba8
    .word 0xfd1e78cf
    .word 0xf96cbf36
    .word 0x6ae6fdb6
    .word 0x366e3291
    .word 0x09867ca8
    .word 0x07ae4733
    .word 0x6199b7d0
    .word 0x127145d2
    .word 0x0bc4ad6e
    .word 0xf3911b85
    .word 0xe5f5a831
    .word 0x6603d221
    .word 0x3aab419b
    .word 0x02ce34cf
    .word 0xf037b123
    .word 0x9be14de3
    .word 0x2b1a0390
    .word 0xdb654f0c
    .word 0x5ee63a3b
    .word 0xc06133f3
    .word 0xad2062a8
    .word 0x32871497
    .word 0x8f394667
    .word 0xd93ed848
    .word 0xb495ff38
    .word 0x9d2d53ec
    .word 0x2ec3b3e5
    .word 0x010e54e8
    .word 0xdfef2716
    .word 0x95a095af
    .word 0x78f3f1b4
    .word 0xd4d708f6
    .word 0xd5dec1d5
    .word 0xd4c84a04
    .word 0x5a586835
    .word 0x243be2e7
    .word 0x8618153b
    .word 0x672220fd
    .word 0x9eded0f8
    .word 0x6bc5824b
    .word 0xa93e1ada
    .word 0x22833663
    .word 0x38c5b440
    .word 0x598e9de1
    .word 0x2212c8fc
    .word 0xb8df0abc
    .word 0xb7d35d78
    .word 0xd4556bae
    .word 0x976fc454
    .word 0x56a5cf5f
    .word 0x9c6a6da4
    .word 0x16fda328
    .word 0xb440596a
    .word 0x8b4d31f5
    .word 0xeafecb7b
    .word 0xe14f621a
    .word 0xd569e8ea
    .word 0xb594a183
    .word 0x7e625b5e
    .word 0xdfd8e3cd
    .word 0xef7d55d7
    .word 0x6db2ec67
    .word 0x2b0163cd
    .word 0x19706d99
    .word 0xc623ca7f
    .word 0x35cc266f
    .word 0x117e5c84
    .word 0xe7ae023f
    .word 0xce88542a
    .word 0x68b15119
    .word 0x892e9990
    .word 0x1431f170
    .word 0x50f0006b
    .word 0x97bde92b
    .word 0x4097ffb1
    .word 0x2f3486b3
    .word 0xfb3051ff
    .word 0x00ebe963
    .word 0xa5462eb6
    .word 0x6ffc7d61
    .word 0x4dc9b5aa
    .word 0x9ae298d2
    .word 0xc653f797
    .word 0x62048275
    .word 0x27400ffa
    .word 0x9cfeed94
    .word 0x908bba7e
    .word 0x9c8a7ed2
    .word 0x2897f1f1
    .word 0x7c350ad7
    .word 0xd241172b
    .word 0xe06a8632
    .word 0x8a5b19be
    .word 0xe40e8a17
    .word 0xd2137b83
    .word 0x43eb2c0f
    .word 0x4221524f
    .word 0x49e66d37
    .word 0x0e7b43f0
    .word 0xac0fbe59
    .word 0x2e8d3996
    .word 0xf0d1a506
    .word 0xf3f39966
    .word 0xc0d84adc
    .word 0xbb3dc2d2
    .word 0xf470b658
    .word 0x56699ca0
    .word 0x640f2a8b
    .word 0x7b066e93
    .word 0xdf5fa962
    .word 0xf9c0c487
    .word 0x591a5689
    .word 0x9792c12c
    .word 0x0cdf736d
    .word 0x79817638
    .word 0x8c751af7
    .word 0x1667ea40
    .word 0x49da0eb6
    .word 0xabf0c67e
    .word 0xac670b7d
    .word 0x5cea32d3
    .word 0x9dc2d2ad
    .word 0x0ed48fde
    .word 0xbb5871fa
    .word 0x59b066f5
    .word 0xf24f02e4
    .word 0xd5dda1ef
    .word 0x08d081b4
    .word 0x22d49b07
    .word 0xd86d3b85
    .word 0x2a5b7775
    .word 0x4fd71be2
    .word 0xc46e57ca
    .word 0xc77f8594
    .word 0x9aaac6d4
    .word 0xa520c5b8
    .word 0xe5c8055e
    .word 0xd8aabff6
    .word 0x193773f6
    .word 0x3d09e6ad
    .word 0xcf023d6d
    .word 0x77a1d975

#include "frost_footer.S"
