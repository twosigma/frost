// Generated RV64IMAFDC torture test for Frost (seed=20260818)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xe61155bb72bc6ebf
    li x4, 0xc85e29709c7eaf4e
    li x5, 0x8fbc4d893bc14c23
    li x6, 0x9f057a6a3ffeea59
    li x7, 0xb530da3d1c7a7c4d
    li x8, 0x9cf3923036726e78
    li x9, 0xaba1c54f7954bed6
    li x10, 0xa8ba12233ae803c8
    li x11, 0x3a53f2710726a1c8
    li x12, 0xcde3936f690cd2bd
    li x13, 0xe423e57deb0b7ee8
    li x14, 0x765438823ae5289e
    li x15, 0xc4674ca9bcd1f0c1
    li x16, 0xf487ccded63f8b1c
    li x17, 0xa166785c08be49ae
    li x18, 0xf02c83685cf14e04
    li x19, 0xf8082520112ac838
    li x20, 0xf65611648d44edd9
    li x21, 0xbe20c9418740f106
    li x22, 0xe2e2b897bc8d408f
    li x23, 0x5ad327073cbe8d2a
    li x24, 0xf868f6f6b5599efc
    li x25, 0x1840c9f3627a23cc
    li x26, 0x8c301056f93cde61
    li x27, 0x78fb884eb7211a36
    li x28, 0x7cbdbdab7543283a
    li x29, 0x2fd0a5619ebbc3d0
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
    li x1, 0x28298ec1aa5a06a7

    or x28, x1, x12
    addiw x17, x12, 240
    fmax.s f23, f23, f12
    fmax.s f10, f15, f4
    slli x1, x18, 46
    addw x29, x22, x18
    xor x9, x29, x10
    slli x17, x20, 30
    fdiv.d f8, f7, f18
    fmin.d f24, f4, f22
    fmax.d f13, f4, f6
    fmin.d f25, f9, f24
    fmsub.d f18, f3, f6, f0
    addiw x28, x17, 1917
    andi x20, x8, -1500
    addiw x14, x21, 542
    bne x15, x20, _br_taken_0
    sra x4, x28, x6
    j _br_done_0
_br_taken_0:
    or x4, x17, x1
_br_done_0:
    addw x15, x12, x23
    addiw x15, x19, -873
    or x8, x25, x15
    srliw x21, x23, 16
    lh x5, 944(x31)
    sh x25, 944(x31)
    sllw x13, x6, x16
    xori x4, x14, 12
    slti x4, x8, -1244
    addiw x25, x13, 391
    bgeu x27, x23, _br_taken_1
    sll x9, x16, x16
    j _br_done_1
_br_taken_1:
    srl x9, x22, x28
_br_done_1:
    ld x17, 856(x31)
    sd x21, 856(x31)
    sllw x5, x21, x6
    fsub.s f5, f19, f17
    fnmadd.d f11, f31, f2, f8
    sll x26, x5, x20
    srliw x9, x24, 15
    srli x7, x7, 2
    ld x16, 656(x31)
    sd x19, 656(x31)
    sraiw x8, x15, 0
    sra x4, x27, x22
    add x6, x27, x29
    mulh x4, x5, x19
    rem x19, x16, x15
    slt x23, x17, x24
    addw x9, x18, x15
    slti x4, x26, 634
    andi x8, x26, 1126
    fsub.s f22, f31, f31
    fmax.s f29, f4, f7
    sltu x22, x27, x26
    srli x27, x10, 23
    sraiw x18, x9, 22
    xori x26, x29, 606
    fmul.s f12, f7, f18
    fsub.s f13, f30, f8
    fadd.d f4, f26, f1
    ori x5, x14, -1931
    srai x22, x27, 39
    bge x12, x28, _br_taken_2
    sra x11, x5, x13
    j _br_done_2
_br_taken_2:
    and x11, x7, x24
_br_done_2:
    bgeu x10, x11, _br_taken_3
    srl x24, x10, x7
    j _br_done_3
_br_taken_3:
    sub x24, x23, x12
_br_done_3:
    srlw x21, x20, x25
    sllw x17, x4, x14
    sltu x8, x6, x1
    fmin.d f17, f18, f8
    fmax.d f14, f15, f17
    fnmsub.s f4, f25, f0, f17
    srlw x5, x21, x21
    xor x20, x1, x17
    mul x17, x19, x24
    xori x20, x26, 292
    srai x20, x13, 14
    xori x20, x1, 1771
    addiw x16, x5, -1043
    sllw x10, x1, x9
    bltu x11, x8, _br_taken_4
    sll x5, x29, x6
    j _br_done_4
_br_taken_4:
    sltu x5, x19, x27
_br_done_4:
    lbu x14, 392(x31)
    sb x13, 392(x31)
    lb x1, 880(x31)
    sb x13, 880(x31)
    ld x18, 944(x31)
    sd x21, 944(x31)
    bge x27, x7, _br_taken_5
    or x25, x28, x29
    j _br_done_5
_br_taken_5:
    sll x25, x11, x20
_br_done_5:
    sll x19, x11, x25
    sub x27, x1, x1
    addi x8, x27, -1845
    fsub.s f5, f27, f12
    subw x10, x8, x22
    sll x20, x21, x29
    subw x28, x27, x27
    addi x30, x31, 576
    amomax.w x7, x24, (x30)
    xor x9, x1, x9
    sub x13, x26, x21
    blt x1, x9, _br_taken_6
    slt x26, x24, x1
    j _br_done_6
_br_taken_6:
    and x26, x24, x19
_br_done_6:
    bne x5, x18, _br_taken_7
    sub x25, x11, x5
    j _br_done_7
_br_taken_7:
    xor x25, x24, x12
_br_done_7:
    sraiw x12, x17, 20
    srai x21, x6, 37
    sub x18, x29, x19
    slliw x19, x14, 1
    lwu x23, 708(x31)
    sw x21, 708(x31)
    lbu x5, 476(x31)
    sb x5, 476(x31)
    slt x22, x22, x8
    sraiw x19, x15, 7
    slt x21, x20, x9
    sllw x27, x21, x29
    sltiu x9, x6, -1926
    sub x12, x27, x21
    lwu x25, 148(x31)
    sw x7, 148(x31)
    lb x14, 152(x31)
    sb x5, 152(x31)
    add x22, x13, x12
    srliw x8, x9, 13
    sub x29, x27, x11
    addi x30, x31, 876
    amoadd.w x25, x1, (x30)
    bne x4, x26, _br_taken_8
    xor x20, x7, x10
    j _br_done_8
_br_taken_8:
    sra x20, x7, x25
_br_done_8:
    addi x30, x31, 16
    amoswap.d x23, x14, (x30)
    sll x11, x7, x1
    andi x1, x22, -445
    andi x11, x6, 912
    slliw x6, x29, 29
    slti x28, x4, -586
    slliw x8, x9, 21
    xor x7, x28, x29
    fmul.s f9, f13, f8
    fmul.s f6, f7, f15
    addiw x20, x26, 1813
    sllw x20, x25, x8
    bne x4, x7, _br_taken_9
    and x6, x21, x27
    j _br_done_9
_br_taken_9:
    add x6, x24, x18
_br_done_9:
    bne x15, x8, _br_taken_10
    or x1, x8, x14
    j _br_done_10
_br_taken_10:
    and x1, x29, x29
_br_done_10:
    sll x18, x24, x7
    sraw x6, x19, x18
    bltu x6, x15, _br_taken_11
    xor x24, x23, x28
    j _br_done_11
_br_taken_11:
    xor x24, x18, x29
_br_done_11:
    srai x27, x27, 23
    andi x1, x23, 1346
    bge x8, x29, _br_taken_12
    sra x22, x21, x4
    j _br_done_12
_br_taken_12:
    sltu x22, x7, x27
_br_done_12:
    sra x19, x10, x22
    srli x6, x11, 42
    sllw x5, x16, x24
    rem x12, x21, x11
    fadd.s f7, f9, f30
    sraiw x22, x26, 21
    sltiu x7, x8, 1657
    blt x7, x24, _br_taken_13
    or x4, x10, x1
    j _br_done_13
_br_taken_13:
    and x4, x19, x27
_br_done_13:
    sltu x20, x7, x12
    xor x12, x19, x17
    and x11, x4, x14
    fmax.s f10, f19, f23
    sub x12, x7, x28
    slti x14, x17, -1292
    andi x29, x11, 739
    divw x12, x19, x14
    mulhu x17, x6, x29
    lwu x13, 1004(x31)
    sw x22, 1004(x31)
    lw x27, 356(x31)
    sw x18, 356(x31)
    ld x14, 632(x31)
    sd x1, 632(x31)
    slli x6, x21, 20
    bltu x4, x13, _br_taken_14
    sltu x11, x12, x5
    j _br_done_14
_br_taken_14:
    sra x11, x21, x17
_br_done_14:
    addi x30, x31, 124
    amoor.w x19, x24, (x30)
    fsub.d f22, f3, f6
    fmin.s f14, f25, f4
    bltu x1, x12, _br_taken_15
    add x10, x8, x15
    j _br_done_15
_br_taken_15:
    sub x10, x7, x28
_br_done_15:
    lw x12, 500(x31)
    sw x10, 500(x31)
    srliw x7, x23, 15
    fmsub.d f22, f19, f9, f9
    fmul.d f30, f4, f27
    slliw x21, x8, 29
    xori x18, x6, 1312
    srliw x14, x22, 21
    srli x13, x19, 25
    srliw x20, x22, 7
    fmul.s f27, f25, f17
    fmin.d f6, f24, f2
    fadd.s f2, f8, f15
    ori x23, x15, -1380
    subw x23, x26, x4
    addi x30, x31, 640
    amominu.w x25, x9, (x30)
    sraiw x21, x22, 19
    lw x21, 956(x31)
    sw x26, 956(x31)
    bgeu x7, x9, _br_taken_16
    sub x27, x11, x14
    j _br_done_16
_br_taken_16:
    slt x27, x29, x19
_br_done_16:
    addiw x11, x29, -1155
    addiw x11, x10, -1658
    sraw x19, x23, x10
    bgeu x26, x12, _br_taken_17
    or x1, x16, x15
    j _br_done_17
_br_taken_17:
    srl x1, x13, x18
_br_done_17:
    ori x21, x25, -635
    slti x10, x7, -1314
    bltu x8, x14, _br_taken_18
    or x7, x5, x12
    j _br_done_18
_br_taken_18:
    xor x7, x23, x25
_br_done_18:
    addw x4, x6, x7
    bgeu x17, x4, _br_taken_19
    slt x1, x6, x14
    j _br_done_19
_br_taken_19:
    srl x1, x1, x20
_br_done_19:
    and x7, x26, x5
    lwu x6, 516(x31)
    sw x12, 516(x31)
    fdiv.d f26, f7, f8
    fmadd.d f6, f8, f31, f2
    fdiv.s f2, f30, f25
    srai x8, x11, 1
    slt x19, x26, x26
    fmul.s f12, f2, f16
    fmul.d f1, f12, f22
    fmin.d f26, f6, f14
    fdiv.s f14, f17, f26
    fadd.d f17, f1, f0
    sub x13, x9, x8
    addw x17, x12, x18
    addw x29, x13, x20
    lw x4, 412(x31)
    sw x27, 412(x31)
    sltiu x6, x15, -847
    srl x1, x28, x17
    xor x10, x21, x24
    addi x30, x31, 20
    amomax.w x13, x28, (x30)
    fnmadd.s f7, f16, f13, f27
    sraiw x11, x9, 22
    slti x21, x27, 1304
    fmul.d f25, f6, f0
    beq x1, x29, _br_taken_20
    srl x21, x24, x22
    j _br_done_20
_br_taken_20:
    slt x21, x7, x14
_br_done_20:
    and x25, x17, x8
    slti x21, x29, 477
    slli x23, x15, 59
    blt x7, x7, _br_taken_21
    sub x29, x19, x20
    j _br_done_21
_br_taken_21:
    srl x29, x1, x5
_br_done_21:
    srl x10, x1, x25
    srlw x18, x6, x18
    add x28, x6, x6
    addi x30, x31, 144
    amominu.d x1, x12, (x30)
    blt x5, x12, _br_taken_22
    or x10, x18, x10
    j _br_done_22
_br_taken_22:
    sltu x10, x7, x25
_br_done_22:
    fsub.d f17, f12, f12
    fmin.s f8, f24, f10
    fmin.d f19, f31, f11
    andi x15, x15, 552
    bltu x22, x1, _br_taken_23
    xor x23, x24, x12
    j _br_done_23
_br_taken_23:
    xor x23, x27, x20
_br_done_23:
    addw x27, x15, x8
    sraiw x19, x25, 22
    sraiw x12, x29, 26
    lwu x22, 452(x31)
    sw x4, 452(x31)
    bgeu x28, x5, _br_taken_24
    and x11, x16, x24
    j _br_done_24
_br_taken_24:
    sra x11, x7, x24
_br_done_24:
    sraiw x29, x29, 15
    add x12, x1, x26
    or x29, x5, x5
    bge x14, x11, _br_taken_25
    or x8, x27, x17
    j _br_done_25
_br_taken_25:
    or x8, x27, x1
_br_done_25:
    sraiw x7, x7, 21
    sltiu x12, x13, -1584
    slti x18, x10, -464
    xor x4, x19, x22
    sll x19, x7, x6
    lh x13, 644(x31)
    sh x5, 644(x31)
    bne x27, x6, _br_taken_26
    sra x16, x9, x20
    j _br_done_26
_br_taken_26:
    sll x16, x15, x21
_br_done_26:
    lh x4, 428(x31)
    sh x4, 428(x31)
    add x14, x12, x5
    and x14, x22, x14
    slti x10, x14, -1039
    remw x1, x12, x24
    beq x23, x22, _br_taken_27
    sub x5, x21, x10
    j _br_done_27
_br_taken_27:
    sra x5, x17, x24
_br_done_27:
    srli x16, x11, 2
    sltu x20, x28, x12
    bne x22, x6, _br_taken_28
    sltu x16, x8, x6
    j _br_done_28
_br_taken_28:
    or x16, x13, x29
_br_done_28:
    bltu x28, x6, _br_taken_29
    sra x9, x25, x1
    j _br_done_29
_br_taken_29:
    and x9, x11, x21
_br_done_29:
    lw x7, 236(x31)
    sw x22, 236(x31)
    beq x16, x7, _br_taken_30
    sra x16, x12, x8
    j _br_done_30
_br_taken_30:
    sub x16, x27, x13
_br_done_30:
    slliw x4, x24, 0
    sll x16, x13, x22
    addw x24, x13, x22
    slt x11, x4, x18
    addiw x7, x27, 1002
    blt x7, x1, _br_taken_31
    sra x6, x8, x4
    j _br_done_31
_br_taken_31:
    add x6, x19, x26
_br_done_31:
    andi x13, x4, -455
    slt x28, x10, x4
    addiw x22, x11, 563
    bge x9, x10, _br_taken_32
    sll x22, x10, x20
    j _br_done_32
_br_taken_32:
    xor x22, x29, x17
_br_done_32:
    sltiu x15, x18, 1352
    sraiw x10, x13, 6
    ld x17, 592(x31)
    sd x28, 592(x31)
    mulh x23, x17, x4
    bne x14, x21, _br_taken_33
    or x11, x17, x4
    j _br_done_33
_br_taken_33:
    sll x11, x9, x28
_br_done_33:
    bgeu x11, x17, _br_taken_34
    sll x8, x28, x16
    j _br_done_34
_br_taken_34:
    and x8, x16, x20
_br_done_34:
    fadd.s f2, f4, f7
    srliw x6, x16, 28
    subw x25, x15, x19
    sltu x24, x6, x1
    or x24, x16, x1
    add x26, x23, x17
    sltiu x18, x1, 1370
    mulhsu x7, x9, x7
    sll x18, x25, x28
    slliw x23, x29, 3
    addi x30, x31, 404
    amoadd.w x24, x1, (x30)
    bgeu x26, x5, _br_taken_35
    slt x21, x6, x17
    j _br_done_35
_br_taken_35:
    and x21, x19, x8
_br_done_35:
    srl x11, x28, x18
    sllw x24, x25, x1
    xor x5, x10, x9
    slliw x13, x14, 4
    addi x30, x31, 924
    amomax.w x11, x19, (x30)
    fsub.s f14, f31, f0
    fadd.s f15, f6, f4
    rem x17, x28, x15
    divw x23, x13, x14
    bne x6, x7, _br_taken_36
    srl x18, x7, x23
    j _br_done_36
_br_taken_36:
    srl x18, x1, x17
_br_done_36:
    ori x25, x9, 1173
    srli x23, x21, 25
    sltiu x1, x19, -1922
    ld x17, 592(x31)
    sd x10, 592(x31)
    ld x17, 816(x31)
    sd x10, 816(x31)
    add x17, x11, x7
    addw x6, x14, x13
    andi x27, x25, -1914
    slliw x10, x6, 29
    bge x24, x15, _br_taken_37
    srl x13, x22, x20
    j _br_done_37
_br_taken_37:
    xor x13, x9, x24
_br_done_37:
    xori x8, x18, 1289
    add x16, x14, x22
    srliw x11, x17, 7
    srli x23, x11, 30
    sltu x5, x6, x29
    sll x6, x9, x17
    bge x10, x25, _br_taken_38
    add x18, x5, x29
    j _br_done_38
_br_taken_38:
    sra x18, x26, x1
_br_done_38:
    srliw x9, x1, 0
    add x18, x9, x15
    slti x8, x25, 486
    xor x17, x1, x9
    beq x25, x21, _br_taken_39
    xor x5, x11, x14
    j _br_done_39
_br_taken_39:
    srl x5, x19, x18
_br_done_39:
    ld x26, 896(x31)
    sd x26, 896(x31)
    srl x9, x9, x15
    sraw x19, x13, x19
    slliw x29, x15, 23
    bge x14, x16, _br_taken_40
    xor x9, x8, x28
    j _br_done_40
_br_taken_40:
    sll x9, x15, x25
_br_done_40:
    subw x1, x13, x11
    and x18, x24, x22
    sub x8, x13, x16
    addi x30, x31, 1008
    amomax.d x25, x9, (x30)
    remuw x9, x14, x24

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xb6494f7d0380ffaa
    .dword 0xd0927c97c632af37
    .dword 0xf68d58b382429841
    .dword 0x7ac7efa266a7f8a5
    .dword 0x4000039d4fd54cdc
    .dword 0x574fdec3d1d69369
    .dword 0x336155ff55e17228
    .dword 0x22e2011933e5ad02
    .dword 0x07084f76cf9d2878
    .dword 0x128128babdc2e71d
    .dword 0xbf2659d49cee0d5f
    .dword 0xf02fcbd77aa37cd8
    .dword 0xb6fa0592763e1969
    .dword 0x177bd83c041d4c8d
    .dword 0x9ac9e4d077e5053f
    .dword 0x77f39f99c864ae28
    .dword 0x14faefb7b3846632
    .dword 0x470730589e121c65
    .dword 0x3836a9974e6d1805
    .dword 0xe5971cf97d5d9eb2
    .dword 0x52a09963c86710f0
    .dword 0x8eb32a7d2f981b4f
    .dword 0x753e284ebb4ee86a
    .dword 0xa2ac25ccb8d9c65e
    .dword 0xaef396d90427112b
    .dword 0x47c1a1b8d26f740d
    .dword 0x98eed5b36f92a60c
    .dword 0xd6682d6c528988b7
    .dword 0xdebf67acbe13d8d3
    .dword 0x6661e977bdf3ce54
    .dword 0xd1f5ce6699bb98a5
    .dword 0xa828699d70c32b67

    .align 2
_torture_data:
    .word 0x9f2f8257
    .word 0x01608e88
    .word 0x1da85b23
    .word 0xb03ad20b
    .word 0x21aaf538
    .word 0x2c1866c1
    .word 0x8d65100c
    .word 0xf8b66d36
    .word 0x0a1bd6eb
    .word 0xcbacca89
    .word 0x69b8fcd9
    .word 0x7c8523d3
    .word 0xe0351c91
    .word 0xd3824840
    .word 0x49398e34
    .word 0xf3993ef0
    .word 0xd9248a84
    .word 0xb8cb5003
    .word 0x916f757d
    .word 0x7a5a5a4f
    .word 0x26cac110
    .word 0xe1e09126
    .word 0xaa4a0787
    .word 0x7ef1ccc7
    .word 0x77bb37d3
    .word 0x37a313a9
    .word 0x37ab1839
    .word 0x7bec043b
    .word 0x39d90bb8
    .word 0x80fa5490
    .word 0x8211829b
    .word 0x423c5fff
    .word 0x8af5861f
    .word 0x4b1fb4fc
    .word 0x56fc9927
    .word 0xe08d30cc
    .word 0x13a5948e
    .word 0x8a054cc0
    .word 0x97a71cc8
    .word 0xa40270c2
    .word 0x9a124da4
    .word 0xbdc615aa
    .word 0xe7ec42a8
    .word 0x8c655461
    .word 0x772c5be8
    .word 0x433c23da
    .word 0xba5b8370
    .word 0xde190844
    .word 0xd25970f6
    .word 0xcaaf736e
    .word 0x8a44c4fb
    .word 0xbcafcf85
    .word 0x4c93909b
    .word 0x199a518d
    .word 0x86240cf1
    .word 0x290cf155
    .word 0x8c53e765
    .word 0x34e3d77a
    .word 0x604a4b03
    .word 0x96b3e735
    .word 0xdb2cf017
    .word 0x6f8ada1f
    .word 0x5ac08109
    .word 0x5b79ebb3
    .word 0xd4ea5f3a
    .word 0xb24856b8
    .word 0x64ed57b4
    .word 0x2c63c5a1
    .word 0x78ed91bf
    .word 0x616c2fd4
    .word 0xbb0e828b
    .word 0x283bfc2b
    .word 0x224f5ccf
    .word 0xd2af075d
    .word 0xbba8e9b4
    .word 0xd1124b30
    .word 0xd3567f17
    .word 0x84fb612b
    .word 0xa45066a2
    .word 0x4a180e8c
    .word 0xce441b15
    .word 0x2a5917c6
    .word 0x3e3e4c9c
    .word 0xbf4e3bb6
    .word 0x22b62f0b
    .word 0xd453dcc7
    .word 0x7801339d
    .word 0x9779c2d3
    .word 0x3629bb84
    .word 0x75085367
    .word 0x204bdfaa
    .word 0xbe118307
    .word 0x45070001
    .word 0xe7100b4d
    .word 0x6447c851
    .word 0xe9cef1a6
    .word 0x2293b200
    .word 0x64d79a1c
    .word 0xe8a723ef
    .word 0x49f766df
    .word 0x804dda23
    .word 0x2146d5f2
    .word 0xf9792776
    .word 0x2faab6db
    .word 0x0815b84b
    .word 0x97c5832f
    .word 0x4c02b261
    .word 0xb6635e5c
    .word 0x1a2878ba
    .word 0x44cb7cc5
    .word 0xa3e51a17
    .word 0x188f8488
    .word 0x917b4aa5
    .word 0xa7d2c33a
    .word 0x433ac1b6
    .word 0x4941219a
    .word 0x0e4fe026
    .word 0x6230e66a
    .word 0x43fc2dd6
    .word 0x6c44eda1
    .word 0x698f0d36
    .word 0x14bf9528
    .word 0x5f4600f3
    .word 0x8082a10d
    .word 0xdd11bd87
    .word 0x9a5f7fb2
    .word 0xffb735f2
    .word 0x40dbf768
    .word 0xb45501d7
    .word 0x7127da37
    .word 0x056b21ef
    .word 0x386fe453
    .word 0x54e1fb52
    .word 0x3cecd13e
    .word 0xdc541123
    .word 0x012c0871
    .word 0x86dc7d1a
    .word 0xf575e3bd
    .word 0x29131c97
    .word 0xf6217161
    .word 0x42e2521f
    .word 0x5968f498
    .word 0xba4f93da
    .word 0x83b0546a
    .word 0x0481f8ec
    .word 0x9c3404cc
    .word 0x0d48ecd7
    .word 0x170d4408
    .word 0xacb57bad
    .word 0x8e1b2dcb
    .word 0x88643f0b
    .word 0x39cf036d
    .word 0xd4aa3185
    .word 0x1a80ec06
    .word 0x72b54991
    .word 0xee279a0e
    .word 0x9f815d74
    .word 0x2beb5ee4
    .word 0x0e2730f6
    .word 0x47501066
    .word 0xf3c0566b
    .word 0x57671d69
    .word 0x1dcf972c
    .word 0x6e7d25a6
    .word 0x279ce76a
    .word 0xe40f2c18
    .word 0xd89d1632
    .word 0x3c552846
    .word 0x04407cec
    .word 0xab524d02
    .word 0xed313d95
    .word 0x246d0826
    .word 0x6465faac
    .word 0xe5ce90cf
    .word 0x785e0a14
    .word 0xb5551d08
    .word 0x9e2ebe4d
    .word 0xbd40022c
    .word 0xb51caf1e
    .word 0xb006a903
    .word 0x3781c6ca
    .word 0x3439ba03
    .word 0xd8f318ac
    .word 0x4cdedccb
    .word 0xe27fd15b
    .word 0x9667a102
    .word 0x8083da9d
    .word 0xc696cac0
    .word 0x65b2d31e
    .word 0x076a28bc
    .word 0xf33060ad
    .word 0x03390ab4
    .word 0xb1dca05a
    .word 0xc3f648de
    .word 0x59be0a39
    .word 0x6ed4a290
    .word 0x85f01256
    .word 0xd8816647
    .word 0x338bddc0
    .word 0x2d397093
    .word 0xb890014c
    .word 0x6e92e0b6
    .word 0x980ac454
    .word 0xd7a17eeb
    .word 0x47d29e82
    .word 0x4bc491de
    .word 0x5d940234
    .word 0x27cb1046
    .word 0x0e3f9a7f
    .word 0x1acdffe9
    .word 0x43de3473
    .word 0xb1679d3e
    .word 0x77a8d0c9
    .word 0x4886f51d
    .word 0xe2ad921e
    .word 0xae594671
    .word 0x37ddd01f
    .word 0x9f540e24
    .word 0x054ea4c1
    .word 0x1126ab7e
    .word 0xe66c9174
    .word 0x51443334
    .word 0x819ab401
    .word 0xb3417f4a
    .word 0x8d4f81fd
    .word 0x75f2652e
    .word 0xdf11484d
    .word 0x62c19f87
    .word 0xdb9b34e5
    .word 0xd74ecb93
    .word 0x586019b5
    .word 0x0aa74df9
    .word 0x1d40ab83
    .word 0x833ddd93
    .word 0x399e7a9f
    .word 0x5189e7cf
    .word 0x5b2aace7
    .word 0xc196df6a
    .word 0x13fdf9c1
    .word 0x357371d1
    .word 0x370a238b
    .word 0x20194acf
    .word 0x619216c6
    .word 0x223c3609
    .word 0xb4e446ad
    .word 0x59051d5b
    .word 0x6829aec1
    .word 0x9f414814
    .word 0x6362fcbc
    .word 0x5c15fee9
    .word 0x65d6dbf7
    .word 0x36eec44f
    .word 0xad7b2ad8
    .word 0x5c0e0e5f
    .word 0x4aa3b8f3
    .word 0xee91a2b5

#include "frost_footer.S"
