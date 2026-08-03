// Generated RV64IMAFDC torture test for Frost (seed=20260819)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x9e96b311ef270541
    li x4, 0xac6952ec50e54b79
    li x5, 0xb2d770d7c9b72cec
    li x6, 0x13dc4fc6600db12e
    li x7, 0x0a3562d6cfd51f8e
    li x8, 0xf0978eef97384d38
    li x9, 0x924c350fe4a388d8
    li x10, 0x55309d6432336848
    li x11, 0x4b98ec0c91001f75
    li x12, 0x203f06404347d3be
    li x13, 0x75ffaf1416d1caf7
    li x14, 0x731ea7a5589fc551
    li x15, 0x16bd3fa100605865
    li x16, 0x897e52933a011fe2
    li x17, 0xcfe49962df4c35ac
    li x18, 0x48181d3157518db4
    li x19, 0xbb7436222984d996
    li x20, 0x518dba3f7df2be95
    li x21, 0xe806770916080d52
    li x22, 0xcbc47cf18f9c941e
    li x23, 0x78fb46ec1b9e1717
    li x24, 0x5537fbc4134b2593
    li x25, 0x5c0f1e86fd383ff7
    li x26, 0xa46402bded62e5e3
    li x27, 0xfdc1b25017667379
    li x28, 0x1983502c8fd129a9
    li x29, 0xd65ef529f8cc273b
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
    li x1, 0xaedbe2fa4f160e9c

    slliw x20, x13, 21
    addi x20, x26, 1725
    addi x28, x23, 1757
    srai x20, x12, 4
    beq x13, x19, _br_taken_0
    add x5, x7, x13
    j _br_done_0
_br_taken_0:
    add x5, x27, x9
_br_done_0:
    srliw x23, x10, 21
    andi x26, x20, -1730
    srli x13, x4, 40
    fmax.d f1, f3, f21
    fmul.s f27, f8, f29
    fmin.s f21, f11, f20
    xor x13, x25, x21
    sraw x20, x9, x11
    sltiu x16, x26, 1941
    sllw x29, x6, x27
    addw x20, x4, x7
    mulh x22, x25, x15
    bne x28, x14, _br_taken_1
    sub x6, x8, x13
    j _br_done_1
_br_taken_1:
    add x6, x1, x13
_br_done_1:
    bltu x26, x10, _br_taken_2
    sltu x25, x20, x13
    j _br_done_2
_br_taken_2:
    or x25, x7, x28
_br_done_2:
    addiw x21, x26, 1762
    bltu x1, x19, _br_taken_3
    sll x20, x17, x7
    j _br_done_3
_br_taken_3:
    sll x20, x8, x22
_br_done_3:
    sub x17, x9, x5
    slti x11, x28, 1831
    sraw x23, x29, x14
    mulhsu x8, x7, x15
    remu x13, x6, x21
    xori x27, x15, -1217
    sra x23, x8, x28
    and x24, x7, x14
    bltu x1, x22, _br_taken_4
    add x6, x4, x24
    j _br_done_4
_br_taken_4:
    slt x6, x9, x19
_br_done_4:
    srliw x22, x26, 14
    ori x14, x29, -1590
    sll x16, x7, x13
    bgeu x19, x1, _br_taken_5
    sra x1, x13, x29
    j _br_done_5
_br_taken_5:
    xor x1, x19, x4
_br_done_5:
    addi x30, x31, 88
    amoxor.d x28, x22, (x30)
    xori x19, x6, 1861
    blt x18, x12, _br_taken_6
    sltu x4, x23, x11
    j _br_done_6
_br_taken_6:
    sra x4, x24, x22
_br_done_6:
    lwu x15, 552(x31)
    sw x5, 552(x31)
    sraw x28, x11, x22
    remuw x26, x29, x15
    mulhu x8, x13, x29
    bltu x11, x24, _br_taken_7
    slt x14, x22, x13
    j _br_done_7
_br_taken_7:
    sra x14, x25, x29
_br_done_7:
    fmax.d f24, f31, f20
    fdiv.s f17, f26, f16
    fmadd.s f19, f18, f11, f30
    div x9, x1, x18
    divw x29, x20, x29
    addiw x22, x13, -1453
    slliw x21, x23, 7
    subw x7, x17, x19
    addi x24, x10, 1914
    xori x26, x24, 1012
    and x19, x4, x8
    subw x10, x25, x11
    srli x5, x9, 19
    andi x4, x4, 939
    sll x24, x19, x10
    srlw x8, x28, x23
    srai x5, x29, 30
    fmul.s f26, f31, f23
    srai x19, x27, 57
    sra x27, x13, x12
    remw x21, x17, x19
    remu x9, x26, x4
    sllw x14, x22, x27
    slt x19, x24, x14
    sltu x28, x5, x9
    fsub.d f3, f7, f31
    fmin.s f14, f15, f13
    fmul.s f21, f25, f1
    lwu x10, 496(x31)
    sw x23, 496(x31)
    bge x10, x7, _br_taken_8
    and x16, x24, x14
    j _br_done_8
_br_taken_8:
    add x16, x24, x14
_br_done_8:
    addi x30, x31, 828
    amoand.w x24, x20, (x30)
    srliw x19, x20, 2
    sub x15, x10, x9
    andi x17, x9, -1937
    sllw x13, x25, x4
    subw x21, x4, x7
    xori x28, x16, -423
    lhu x16, 184(x31)
    sh x9, 184(x31)
    div x22, x19, x1
    divuw x21, x7, x26
    fmadd.d f5, f2, f5, f24
    addw x22, x6, x13
    slli x22, x18, 44
    and x22, x25, x15
    fmsub.d f1, f16, f23, f12
    ori x28, x24, -1292
    srai x17, x15, 63
    bge x12, x9, _br_taken_9
    sll x26, x4, x21
    j _br_done_9
_br_taken_9:
    sra x26, x14, x15
_br_done_9:
    lh x12, 568(x31)
    sh x4, 568(x31)
    lw x16, 212(x31)
    sw x29, 212(x31)
    addi x30, x31, 84
    amoand.w x15, x16, (x30)
    div x15, x16, x9
    bne x10, x10, _br_taken_10
    sltu x1, x15, x17
    j _br_done_10
_br_taken_10:
    sll x1, x26, x24
_br_done_10:
    bltu x26, x16, _br_taken_11
    sra x11, x6, x12
    j _br_done_11
_br_taken_11:
    or x11, x26, x19
_br_done_11:
    addw x12, x4, x25
    subw x17, x24, x6
    srlw x10, x16, x16
    bge x18, x4, _br_taken_12
    sra x8, x4, x8
    j _br_done_12
_br_taken_12:
    slt x8, x15, x9
_br_done_12:
    sra x17, x12, x26
    addi x12, x21, 1901
    sltu x20, x6, x21
    lhu x17, 160(x31)
    sh x13, 160(x31)
    slli x10, x15, 4
    addi x30, x31, 952
    amomax.w x20, x24, (x30)
    slti x22, x10, -1687
    sra x16, x1, x21
    srliw x13, x29, 1
    fadd.s f16, f8, f17
    fmul.s f26, f30, f0
    fmul.s f17, f31, f9
    sllw x12, x7, x19
    srliw x29, x12, 23
    sllw x12, x28, x5
    bne x19, x9, _br_taken_13
    sra x20, x8, x9
    j _br_done_13
_br_taken_13:
    or x20, x24, x12
_br_done_13:
    sltu x22, x23, x26
    xor x24, x14, x13
    andi x7, x29, -957
    lw x5, 980(x31)
    sw x25, 980(x31)
    addw x16, x16, x11
    srli x8, x5, 3
    bne x7, x6, _br_taken_14
    sra x25, x11, x13
    j _br_done_14
_br_taken_14:
    and x25, x21, x29
_br_done_14:
    bgeu x14, x12, _br_taken_15
    sltu x16, x25, x4
    j _br_done_15
_br_taken_15:
    slt x16, x27, x11
_br_done_15:
    sllw x18, x6, x11
    srliw x22, x18, 23
    slliw x13, x12, 14
    xori x4, x29, -626
    addw x29, x26, x10
    srliw x28, x23, 10
    xori x12, x19, -1835
    beq x15, x10, _br_taken_16
    sll x19, x9, x29
    j _br_done_16
_br_taken_16:
    and x19, x1, x9
_br_done_16:
    bge x28, x11, _br_taken_17
    slt x1, x20, x9
    j _br_done_17
_br_taken_17:
    slt x1, x25, x11
_br_done_17:
    sll x11, x21, x26
    slliw x23, x24, 16
    addi x25, x13, 386
    lw x9, 156(x31)
    sw x6, 156(x31)
    fmin.s f3, f17, f17
    add x8, x17, x29
    add x27, x11, x18
    sltiu x18, x12, 1083
    sraiw x27, x18, 17
    bne x22, x10, _br_taken_18
    and x9, x14, x9
    j _br_done_18
_br_taken_18:
    slt x9, x17, x20
_br_done_18:
    lb x23, 480(x31)
    sb x7, 480(x31)
    subw x20, x12, x27
    sltu x26, x10, x7
    srl x6, x26, x5
    sltu x15, x17, x5
    srl x17, x26, x16
    addi x30, x31, 544
    amoand.w x17, x6, (x30)
    sra x1, x28, x23
    xor x28, x4, x28
    sraiw x8, x16, 19
    addi x30, x31, 364
    amominu.w x14, x10, (x30)
    addw x7, x18, x5
    slt x21, x14, x13
    bltu x29, x20, _br_taken_19
    slt x7, x20, x27
    j _br_done_19
_br_taken_19:
    add x7, x14, x21
_br_done_19:
    subw x28, x21, x29
    ori x13, x11, 250
    sltu x11, x11, x18
    slliw x15, x11, 22
    mulh x20, x4, x21
    srliw x28, x20, 6
    subw x28, x25, x22
    addi x30, x31, 856
    amomin.d x6, x1, (x30)
    bltu x15, x24, _br_taken_20
    sltu x5, x18, x17
    j _br_done_20
_br_taken_20:
    srl x5, x14, x15
_br_done_20:
    slti x8, x15, -841
    srli x11, x13, 28
    add x21, x17, x14
    sltiu x6, x11, 940
    blt x18, x21, _br_taken_21
    sra x5, x7, x18
    j _br_done_21
_br_taken_21:
    or x5, x25, x19
_br_done_21:
    and x28, x26, x24
    srliw x6, x14, 20
    sltu x20, x15, x18
    addw x29, x25, x25
    addi x20, x13, -296
    ori x24, x8, -1546
    sllw x29, x29, x12
    sll x28, x12, x12
    addiw x14, x10, 1157
    slt x27, x24, x22
    lwu x17, 800(x31)
    sw x29, 800(x31)
    lw x12, 304(x31)
    sw x23, 304(x31)
    bne x1, x17, _br_taken_22
    sll x21, x22, x17
    j _br_done_22
_br_taken_22:
    add x21, x14, x25
_br_done_22:
    bne x25, x15, _br_taken_23
    sll x25, x15, x27
    j _br_done_23
_br_taken_23:
    srl x25, x15, x25
_br_done_23:
    remuw x21, x19, x12
    mulhsu x16, x1, x14
    divuw x19, x18, x9
    divuw x1, x14, x6
    divw x10, x23, x29
    sub x9, x10, x17
    andi x23, x20, 1786
    addiw x25, x17, -1500
    slli x29, x17, 63
    lw x6, 896(x31)
    sw x27, 896(x31)
    fsub.s f2, f26, f27
    fnmsub.d f6, f13, f26, f0
    and x5, x5, x24
    add x23, x8, x11
    sltiu x13, x9, -673
    sub x7, x24, x9
    addi x19, x23, 427
    srlw x19, x12, x12
    sraw x12, x7, x29
    sll x29, x15, x12
    srl x5, x28, x5
    srlw x9, x9, x8
    bne x19, x15, _br_taken_24
    sll x4, x9, x20
    j _br_done_24
_br_taken_24:
    sub x4, x28, x13
_br_done_24:
    addw x24, x18, x16
    xor x15, x9, x20
    beq x20, x14, _br_taken_25
    sra x20, x27, x8
    j _br_done_25
_br_taken_25:
    or x20, x9, x25
_br_done_25:
    mul x15, x8, x22
    srl x4, x22, x5
    sll x12, x15, x8
    blt x13, x27, _br_taken_26
    add x23, x21, x10
    j _br_done_26
_br_taken_26:
    sub x23, x27, x8
_br_done_26:
    sltu x26, x10, x8
    addw x1, x4, x13
    sraiw x19, x22, 14
    bgeu x12, x21, _br_taken_27
    srl x23, x4, x6
    j _br_done_27
_br_taken_27:
    or x23, x28, x5
_br_done_27:
    bltu x12, x26, _br_taken_28
    slt x23, x28, x25
    j _br_done_28
_br_taken_28:
    slt x23, x16, x12
_br_done_28:
    bltu x7, x18, _br_taken_29
    add x4, x11, x25
    j _br_done_29
_br_taken_29:
    and x4, x28, x27
_br_done_29:
    bge x15, x19, _br_taken_30
    slt x9, x6, x22
    j _br_done_30
_br_taken_30:
    or x9, x22, x1
_br_done_30:
    andi x8, x7, 1576
    slli x18, x1, 24
    addiw x25, x6, -1315
    subw x8, x23, x26
    srli x1, x7, 36
    remuw x26, x27, x27
    mulh x18, x23, x5
    fmadd.s f4, f28, f22, f30
    xori x12, x4, -1825
    slliw x20, x4, 26
    srliw x25, x5, 19
    lwu x18, 972(x31)
    sw x4, 972(x31)
    addw x1, x8, x28
    sltu x15, x10, x21
    add x1, x22, x12
    blt x9, x10, _br_taken_31
    sub x24, x29, x6
    j _br_done_31
_br_taken_31:
    and x24, x17, x28
_br_done_31:
    slliw x25, x25, 23
    addi x19, x12, 1356
    bne x14, x8, _br_taken_32
    and x12, x5, x11
    j _br_done_32
_br_taken_32:
    or x12, x28, x15
_br_done_32:
    beq x23, x1, _br_taken_33
    srl x28, x29, x9
    j _br_done_33
_br_taken_33:
    or x28, x6, x20
_br_done_33:
    srliw x1, x5, 14
    sltiu x11, x13, -505
    xor x12, x19, x5
    srl x12, x29, x7
    sllw x22, x6, x27
    beq x13, x17, _br_taken_34
    sra x27, x12, x18
    j _br_done_34
_br_taken_34:
    xor x27, x19, x9
_br_done_34:
    ld x23, 712(x31)
    sd x4, 712(x31)
    sllw x14, x22, x22
    addw x19, x13, x8
    lb x20, 192(x31)
    sb x21, 192(x31)
    or x7, x8, x5
    sra x17, x27, x20
    addi x30, x31, 188
    amoand.w x29, x8, (x30)
    addi x30, x31, 556
    amoxor.w x10, x24, (x30)
    beq x21, x20, _br_taken_35
    sra x7, x25, x22
    j _br_done_35
_br_taken_35:
    slt x7, x8, x15
_br_done_35:
    addi x30, x31, 144
    amomax.d x8, x25, (x30)
    blt x18, x11, _br_taken_36
    sll x25, x28, x28
    j _br_done_36
_br_taken_36:
    slt x25, x29, x6
_br_done_36:
    addw x5, x14, x21
    addw x22, x17, x5
    slliw x23, x18, 13
    srai x6, x15, 21
    andi x10, x17, 563
    subw x22, x27, x29
    slli x26, x9, 0
    sub x5, x1, x7
    sltiu x25, x19, 288
    slti x1, x8, 1037
    bge x7, x7, _br_taken_37
    slt x25, x19, x14
    j _br_done_37
_br_taken_37:
    sltu x25, x5, x9
_br_done_37:
    lbu x9, 108(x31)
    sb x28, 108(x31)
    slli x21, x14, 0
    or x5, x18, x18
    slliw x29, x11, 25
    fmin.s f13, f6, f20
    fmax.s f23, f7, f21
    fmax.s f30, f21, f6
    sraiw x24, x20, 29
    addi x20, x12, 958
    slti x22, x15, 137
    lhu x15, 692(x31)
    sh x23, 692(x31)
    addi x30, x31, 916
    amoswap.w x25, x5, (x30)
    lb x28, 336(x31)
    sb x5, 336(x31)
    fadd.s f8, f19, f10
    fmul.s f3, f25, f0
    slli x22, x25, 49
    slti x8, x25, -1709
    addw x1, x8, x17
    bgeu x14, x1, _br_taken_38
    sltu x13, x17, x7
    j _br_done_38
_br_taken_38:
    srl x13, x16, x12
_br_done_38:
    srli x14, x29, 40
    sra x20, x16, x8
    sltu x29, x24, x6
    srlw x13, x6, x17
    lw x25, 372(x31)
    sw x23, 372(x31)
    fmax.s f9, f1, f13
    subw x23, x10, x18
    sllw x22, x29, x29
    sltiu x21, x5, 117
    fmax.s f27, f10, f19
    fmax.s f21, f16, f3
    sra x23, x26, x8
    slliw x9, x19, 1
    sltu x26, x5, x10
    mulhu x24, x10, x13
    div x22, x8, x8
    beq x22, x27, _br_taken_39
    add x6, x8, x10
    j _br_done_39
_br_taken_39:
    sll x6, x5, x14
_br_done_39:
    bge x26, x23, _br_taken_40
    add x10, x15, x15
    j _br_done_40
_br_taken_40:
    xor x10, x5, x28
_br_done_40:
    subw x9, x29, x16
    srli x20, x9, 9
    sltiu x12, x18, -1213
    divw x10, x9, x14
    bltu x10, x10, _br_taken_41
    sra x19, x13, x11
    j _br_done_41
_br_taken_41:
    sltu x19, x12, x23
_br_done_41:
    bge x13, x26, _br_taken_42
    or x20, x27, x11
    j _br_done_42
_br_taken_42:
    sltu x20, x14, x23
_br_done_42:
    addw x23, x21, x5
    and x11, x17, x15
    or x26, x13, x28
    bltu x6, x25, _br_taken_43
    srl x29, x17, x13
    j _br_done_43
_br_taken_43:
    xor x29, x9, x16
_br_done_43:
    fmul.d f17, f20, f10
    fsub.d f9, f23, f25
    fdiv.s f16, f14, f1
    add x11, x6, x1
    add x17, x18, x24
    divu x9, x17, x16
    mulw x24, x19, x6
    subw x22, x29, x25
    xor x27, x6, x20
    srlw x14, x10, x15
    andi x10, x5, -146
    sra x5, x6, x22
    sub x14, x24, x29

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x78d365908cd2097c
    .dword 0xfa37853c2540cd49
    .dword 0x41cd5746a0ba93ef
    .dword 0x855137fabe46d1ea
    .dword 0x660171c6f711ea40
    .dword 0x1785837a96ebda23
    .dword 0x3dccecd76a7cc424
    .dword 0x308e3c46d6310065
    .dword 0xc9d2518c6f971752
    .dword 0x5b949082215953a7
    .dword 0xa820921a48eacf8b
    .dword 0x9b0087d64e329a4e
    .dword 0x56bc4193a740de9c
    .dword 0x384f7d164b41d1c2
    .dword 0xf7b626f47545fae5
    .dword 0x67495f9e1a17f353
    .dword 0x0b3a9112fd1f77a0
    .dword 0xf6e7bd41948fea59
    .dword 0xd22968ba010815df
    .dword 0x157e6c0abb6788e0
    .dword 0x50036d5869930e93
    .dword 0xed7c8cff285f4dd5
    .dword 0xc4b02b17e449cbae
    .dword 0xf7a5e4a2d1c842ea
    .dword 0xc3beaa5b8aabf36f
    .dword 0xce55a515b187ac83
    .dword 0x588baa42a7c63914
    .dword 0x831508f19a2fe586
    .dword 0xd94ea5b720a87720
    .dword 0x39f223ad24d6820e
    .dword 0x19014784c99ca242
    .dword 0x6204158404ca2e76

    .align 2
_torture_data:
    .word 0x827b4bfe
    .word 0x9b80fd67
    .word 0xc4b53dee
    .word 0x78b24a06
    .word 0x4973de38
    .word 0x8d190b54
    .word 0xd0748afb
    .word 0x05c73985
    .word 0x29851dad
    .word 0x4e6de82d
    .word 0xac455672
    .word 0xd669119e
    .word 0x2c58df37
    .word 0xed84cf17
    .word 0xce30a958
    .word 0x7fa3d58f
    .word 0x2f5c70e3
    .word 0xfebfe9c8
    .word 0xe1b21d83
    .word 0x2f3928ee
    .word 0x96e4e8fc
    .word 0x08086f7e
    .word 0x369fc432
    .word 0x6ee1bed7
    .word 0x992a3813
    .word 0xc626873c
    .word 0xf37d1dad
    .word 0xf5105fb0
    .word 0x35f77307
    .word 0x50b27f36
    .word 0x4fadff94
    .word 0x53fd7e2b
    .word 0x9333f2b4
    .word 0xcee2570d
    .word 0x28d5df63
    .word 0x440e5c7d
    .word 0x00aa418e
    .word 0xaa97ac3a
    .word 0xe5ff8d13
    .word 0x0dc90c24
    .word 0x6aa13ed5
    .word 0x9bc45f15
    .word 0x18c6b75e
    .word 0xc4dfe84a
    .word 0x1e22919c
    .word 0x1e5bcf01
    .word 0xc4c1f229
    .word 0x77910e1b
    .word 0xc82d0204
    .word 0xaf2065ba
    .word 0x6dc0cea2
    .word 0x1edcb233
    .word 0xdc65159b
    .word 0x04e9d795
    .word 0xf40af10a
    .word 0x0aded07e
    .word 0xfbc7ab74
    .word 0x8af51b1c
    .word 0x46de1867
    .word 0xdadc41c2
    .word 0x52c5926d
    .word 0xd19aa9b7
    .word 0x4b0dabf8
    .word 0x975c45f1
    .word 0xcd1eabde
    .word 0xd52c89fd
    .word 0x9b5a889f
    .word 0x4ca9afbc
    .word 0x2681f71b
    .word 0x0e92fb89
    .word 0x1bbf20d4
    .word 0x338950e7
    .word 0xe2e44faf
    .word 0x7b3e651c
    .word 0x34d08487
    .word 0xd2173554
    .word 0xb30a4998
    .word 0x7bd82754
    .word 0xaa5b9638
    .word 0xd21f8034
    .word 0x0ddfbb33
    .word 0x0eba8d62
    .word 0x98506930
    .word 0x08f698f0
    .word 0xc06cbb25
    .word 0x8e46803f
    .word 0x2b459008
    .word 0x87576f9f
    .word 0x84f1f81c
    .word 0xb00903a8
    .word 0xd47434fb
    .word 0x44a272f5
    .word 0x109c37c1
    .word 0xd0018cbb
    .word 0xec34b125
    .word 0xe77ef87b
    .word 0x4f5d111e
    .word 0xde3851c0
    .word 0x32a12694
    .word 0x5410790b
    .word 0x0cdb6872
    .word 0x568b3b53
    .word 0xb839aac0
    .word 0xce2f0d9e
    .word 0x22b3f914
    .word 0x725fd9c3
    .word 0x6e6613b9
    .word 0xc3a37500
    .word 0x511f5a24
    .word 0x768a0826
    .word 0xb4098391
    .word 0xe01ce8f5
    .word 0xd94d8f99
    .word 0x359611a3
    .word 0x6ee68ce8
    .word 0x3d78affc
    .word 0x0a0fd7f8
    .word 0x4de70925
    .word 0xa6d795b8
    .word 0xd7ea2d12
    .word 0x04acad61
    .word 0x17af0e65
    .word 0xec15f13a
    .word 0x4e6f3643
    .word 0x0c961c8a
    .word 0x6ed8501c
    .word 0x84f303b3
    .word 0x3d697bd2
    .word 0x2db737a5
    .word 0xeb481ec2
    .word 0x6c36cc42
    .word 0x19f0372a
    .word 0xdbd05175
    .word 0x9e7a924f
    .word 0x737395b6
    .word 0x5a3fdb8d
    .word 0x04122cdb
    .word 0x1087d5b0
    .word 0xea335e19
    .word 0xfb3ad8d5
    .word 0x7ce097b6
    .word 0x61f22b82
    .word 0x54823cd9
    .word 0xe9d8154c
    .word 0xd7862f2e
    .word 0xfdfd9cf6
    .word 0x92835dfe
    .word 0x432315da
    .word 0xff596d0a
    .word 0x7ba0afae
    .word 0x3c1badb4
    .word 0x5ac80248
    .word 0x210ecb2b
    .word 0xc6664722
    .word 0xad772257
    .word 0xf6d85851
    .word 0x4821334a
    .word 0x596e0bdb
    .word 0x3186c931
    .word 0x9b6e7dc2
    .word 0x444a93ab
    .word 0x7f112239
    .word 0x642263ed
    .word 0x2dacd7d2
    .word 0x647fa08b
    .word 0x950da44a
    .word 0xabdc40a8
    .word 0x68831a4e
    .word 0x92bbf60a
    .word 0xeb3858d3
    .word 0xfff9d533
    .word 0x5d63c7ae
    .word 0x65e0c44c
    .word 0x4494b849
    .word 0x32180183
    .word 0xa6d68d4e
    .word 0xcc65b746
    .word 0xa4c747b1
    .word 0x6488ba47
    .word 0xb821c7f3
    .word 0xfb181abb
    .word 0xbfcf6733
    .word 0x77c314e2
    .word 0x9e5c48e1
    .word 0xf4df2c04
    .word 0x47bae175
    .word 0x51243d96
    .word 0x2bcfff43
    .word 0x057554c5
    .word 0x85760282
    .word 0x8cdca12f
    .word 0xf12e5b84
    .word 0x25c8a2cf
    .word 0x947fc997
    .word 0x8ac8edd0
    .word 0xb28e27de
    .word 0xc6d480e1
    .word 0x89bf0c3c
    .word 0x1cf8a6a7
    .word 0x20b059ba
    .word 0xfc373f1b
    .word 0x0879ad6a
    .word 0xcb8998c5
    .word 0xd90cb7e5
    .word 0xf87d8fe9
    .word 0x301ecaaa
    .word 0xfaec79f2
    .word 0xce66ede2
    .word 0x010b3b57
    .word 0xc7b62c71
    .word 0x07982bcc
    .word 0x7c91bfb1
    .word 0xd726d8ef
    .word 0x71ff4210
    .word 0xea8e2dc4
    .word 0xea138ac9
    .word 0x55e5c052
    .word 0xbe987910
    .word 0xc9ec8e2e
    .word 0xbf04bec9
    .word 0x789058cb
    .word 0x1c727baa
    .word 0x399d04d4
    .word 0x0167539c
    .word 0xf1c01969
    .word 0xf5648a68
    .word 0x65a824e7
    .word 0x421262cf
    .word 0xe8ac84ac
    .word 0x4fb25b81
    .word 0x1316ff97
    .word 0x1c6fe0e7
    .word 0x61a97f90
    .word 0xc4f72f81
    .word 0xc588f097
    .word 0x0a3fd3d8
    .word 0xdbfc0f04
    .word 0x249aa814
    .word 0xa159f101
    .word 0x89953a96
    .word 0xd58efccc
    .word 0xbd5a5744
    .word 0x9e5a2918
    .word 0x9acf2187
    .word 0x16be1d36
    .word 0xf14dd3ca
    .word 0x9d766872
    .word 0xc1c10909
    .word 0xaeb50d48
    .word 0x91689be3
    .word 0x98f97e93
    .word 0xb41192f7
    .word 0xd8523a9e
    .word 0x350a8297
    .word 0x117e07d4
    .word 0x70e5e366

#include "frost_footer.S"
