// Generated RV64IMAFDC torture test for Frost (seed=20260804)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x9332ccdbad44bce9
    li x4, 0x1a0311190568e414
    li x5, 0xfb78c7fcf9dd5432
    li x6, 0x1bc9c0192575e412
    li x7, 0xa7ef0e5bad27a207
    li x8, 0x61d20408c56c9428
    li x9, 0x0d3438c2ebf4a401
    li x10, 0x7a5642d219cf038d
    li x11, 0xa1195d50c46df894
    li x12, 0x7518a3c54b295b71
    li x13, 0x2e0ffd8be52e8ad7
    li x14, 0x2eaf0c8bc50e6934
    li x15, 0xe0f61a2d28826d8c
    li x16, 0x2f4c6a9ac11e7b44
    li x17, 0x6db17ddf80f7bc12
    li x18, 0x7ef7cf2e4a4b6f1f
    li x19, 0x0de15febdf26d0ec
    li x20, 0x7071881faeb8641b
    li x21, 0x2eda13a2aaf6a454
    li x22, 0x33d5a52dd2105d50
    li x23, 0x502de61fd0d2e348
    li x24, 0xb76cc7c58d0ec68a
    li x25, 0x852c5d567d60db2e
    li x26, 0x5b8093006fa89af0
    li x27, 0x75002b735483098e
    li x28, 0xc8b4159976493cdd
    li x29, 0x287e97d77cd57182
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
    li x1, 0xce2d3c8dd87590c7

    slliw x29, x20, 30
    sllw x5, x13, x5
    fmin.d f7, f20, f0
    fnmsub.d f4, f17, f18, f19
    bgeu x24, x16, _br_taken_0
    or x18, x23, x22
    j _br_done_0
_br_taken_0:
    srl x18, x7, x12
_br_done_0:
    ld x22, 976(x31)
    sd x12, 976(x31)
    slliw x29, x29, 18
    xor x8, x10, x10
    sraiw x24, x1, 10
    sllw x23, x8, x11
    ori x6, x16, -986
    blt x9, x26, _br_taken_1
    sltu x13, x19, x11
    j _br_done_1
_br_taken_1:
    sub x13, x7, x18
_br_done_1:
    bgeu x21, x13, _br_taken_2
    or x23, x22, x24
    j _br_done_2
_br_taken_2:
    sltu x23, x29, x20
_br_done_2:
    addi x30, x31, 896
    amoand.d x19, x27, (x30)
    sll x9, x7, x25
    xor x22, x25, x20
    sraiw x21, x13, 31
    sub x21, x6, x6
    bne x28, x22, _br_taken_3
    sub x8, x5, x17
    j _br_done_3
_br_taken_3:
    xor x8, x1, x13
_br_done_3:
    remu x21, x12, x23
    remuw x5, x8, x10
    bgeu x29, x9, _br_taken_4
    sll x11, x12, x19
    j _br_done_4
_br_taken_4:
    sub x11, x1, x7
_br_done_4:
    srlw x29, x15, x24
    addiw x28, x14, -847
    lb x8, 140(x31)
    sb x1, 140(x31)
    slt x21, x26, x5
    slt x26, x28, x25
    bge x9, x26, _br_taken_5
    and x26, x19, x6
    j _br_done_5
_br_taken_5:
    add x26, x26, x17
_br_done_5:
    srlw x28, x1, x15
    sltiu x9, x10, 1312
    and x24, x28, x24
    slliw x14, x17, 21
    srai x22, x6, 23
    bne x14, x8, _br_taken_6
    sltu x24, x6, x26
    j _br_done_6
_br_taken_6:
    sra x24, x11, x5
_br_done_6:
    subw x11, x28, x21
    addi x24, x10, -325
    sllw x1, x11, x11
    slliw x8, x26, 2
    or x25, x29, x10
    xori x14, x16, -232
    fsub.s f3, f4, f5
    sllw x4, x16, x16
    sra x17, x24, x22
    bltu x29, x29, _br_taken_7
    add x24, x16, x29
    j _br_done_7
_br_taken_7:
    add x24, x4, x26
_br_done_7:
    slliw x26, x10, 18
    ld x14, 176(x31)
    sd x24, 176(x31)
    subw x7, x18, x14
    srl x27, x23, x18
    or x22, x1, x9
    bge x28, x23, _br_taken_8
    sra x19, x23, x22
    j _br_done_8
_br_taken_8:
    srl x19, x1, x15
_br_done_8:
    slliw x7, x5, 4
    srli x20, x10, 54
    and x17, x18, x29
    addw x13, x9, x9
    remu x6, x4, x1
    srliw x24, x10, 7
    slt x17, x7, x27
    sraiw x12, x11, 19
    sraw x1, x18, x23
    addi x30, x31, 120
    amomax.w x12, x17, (x30)
    srlw x14, x24, x15
    blt x21, x7, _br_taken_9
    sll x9, x23, x13
    j _br_done_9
_br_taken_9:
    add x9, x25, x13
_br_done_9:
    addw x5, x13, x20
    sub x28, x26, x14
    ori x28, x5, 1809
    slt x29, x26, x7
    srl x23, x6, x25
    sll x25, x13, x10
    addi x30, x31, 300
    amominu.w x22, x11, (x30)
    srlw x11, x25, x9
    addiw x29, x10, -937
    sllw x26, x11, x8
    beq x7, x23, _br_taken_10
    or x29, x21, x16
    j _br_done_10
_br_taken_10:
    sll x29, x17, x7
_br_done_10:
    ori x17, x29, -1058
    andi x6, x17, 359
    div x14, x21, x7
    mulhsu x10, x5, x7
    addiw x16, x18, 1971
    add x4, x8, x17
    sub x14, x16, x17
    xor x8, x19, x28
    sll x8, x7, x26
    bltu x22, x13, _br_taken_11
    sll x20, x27, x10
    j _br_done_11
_br_taken_11:
    and x20, x4, x15
_br_done_11:
    or x28, x26, x14
    srai x1, x24, 24
    sll x25, x11, x1
    and x10, x22, x22
    slli x1, x5, 5
    bge x9, x22, _br_taken_12
    sltu x12, x12, x11
    j _br_done_12
_br_taken_12:
    add x12, x7, x7
_br_done_12:
    bne x22, x15, _br_taken_13
    sll x5, x28, x7
    j _br_done_13
_br_taken_13:
    sll x5, x4, x10
_br_done_13:
    sub x14, x28, x22
    div x8, x8, x28
    fadd.s f1, f23, f23
    and x28, x9, x9
    bltu x7, x23, _br_taken_14
    sub x21, x20, x10
    j _br_done_14
_br_taken_14:
    sll x21, x8, x7
_br_done_14:
    andi x11, x9, 1730
    beq x11, x22, _br_taken_15
    and x15, x1, x13
    j _br_done_15
_br_taken_15:
    sra x15, x10, x11
_br_done_15:
    addi x30, x31, 408
    amoxor.w x26, x29, (x30)
    slt x21, x29, x6
    addiw x4, x27, -365
    fmadd.s f5, f4, f15, f10
    fadd.s f0, f21, f8
    fmax.s f31, f30, f26
    sltiu x12, x8, -1742
    bgeu x22, x18, _br_taken_16
    and x7, x26, x23
    j _br_done_16
_br_taken_16:
    and x7, x4, x9
_br_done_16:
    bltu x6, x21, _br_taken_17
    xor x21, x21, x25
    j _br_done_17
_br_taken_17:
    sra x21, x24, x5
_br_done_17:
    ld x11, 576(x31)
    sd x6, 576(x31)
    sltu x11, x8, x26
    bne x7, x9, _br_taken_18
    or x24, x29, x26
    j _br_done_18
_br_taken_18:
    sll x24, x28, x23
_br_done_18:
    ori x28, x18, 1167
    addi x8, x25, 1809
    bne x5, x17, _br_taken_19
    sub x13, x27, x20
    j _br_done_19
_br_taken_19:
    or x13, x28, x12
_br_done_19:
    blt x13, x21, _br_taken_20
    sltu x27, x15, x16
    j _br_done_20
_br_taken_20:
    sltu x27, x27, x28
_br_done_20:
    blt x10, x14, _br_taken_21
    sll x13, x4, x27
    j _br_done_21
_br_taken_21:
    srl x13, x19, x12
_br_done_21:
    lb x7, 680(x31)
    sb x7, 680(x31)
    sub x25, x24, x25
    sraw x25, x16, x6
    bge x29, x17, _br_taken_22
    sll x11, x24, x18
    j _br_done_22
_br_taken_22:
    sub x11, x17, x24
_br_done_22:
    sll x11, x7, x19
    bge x14, x15, _br_taken_23
    add x29, x8, x18
    j _br_done_23
_br_taken_23:
    add x29, x24, x20
_br_done_23:
    sra x26, x7, x15
    lhu x24, 308(x31)
    sh x4, 308(x31)
    srli x16, x18, 38
    slliw x17, x7, 25
    and x4, x26, x7
    bgeu x17, x25, _br_taken_24
    sub x18, x23, x13
    j _br_done_24
_br_taken_24:
    sra x18, x17, x15
_br_done_24:
    srlw x21, x17, x14
    sub x17, x28, x10
    lw x6, 180(x31)
    sw x17, 180(x31)
    bne x11, x4, _br_taken_25
    and x29, x9, x15
    j _br_done_25
_br_taken_25:
    sub x29, x8, x20
_br_done_25:
    slliw x11, x16, 25
    subw x12, x17, x14
    addi x30, x31, 664
    amoswap.w x6, x25, (x30)
    fmul.d f28, f16, f3
    lwu x14, 504(x31)
    sw x15, 504(x31)
    beq x22, x9, _br_taken_26
    xor x28, x6, x12
    j _br_done_26
_br_taken_26:
    sub x28, x17, x21
_br_done_26:
    sraiw x21, x12, 2
    addi x5, x25, 1104
    lh x26, 80(x31)
    sh x6, 80(x31)
    fmax.d f10, f20, f10
    fmul.d f11, f18, f16
    fdiv.s f24, f19, f2
    sltu x12, x5, x23
    slli x1, x18, 23
    srl x11, x23, x27
    slt x26, x22, x6
    srliw x6, x28, 3
    sraw x29, x11, x20
    bge x1, x18, _br_taken_27
    xor x10, x19, x7
    j _br_done_27
_br_taken_27:
    sll x10, x27, x21
_br_done_27:
    sub x22, x23, x23
    fmin.d f8, f15, f15
    bltu x13, x4, _br_taken_28
    sltu x9, x29, x17
    j _br_done_28
_br_taken_28:
    xor x9, x9, x5
_br_done_28:
    ld x25, 376(x31)
    sd x9, 376(x31)
    rem x29, x1, x18
    divu x5, x6, x5
    fdiv.d f0, f2, f31
    bge x23, x28, _br_taken_29
    xor x26, x24, x28
    j _br_done_29
_br_taken_29:
    xor x26, x7, x6
_br_done_29:
    srai x19, x6, 25
    mulhu x7, x10, x8
    mulhsu x29, x14, x11
    sltu x8, x8, x13
    sltiu x9, x19, -157
    slti x7, x27, 1090
    beq x26, x6, _br_taken_30
    sltu x13, x7, x24
    j _br_done_30
_br_taken_30:
    srl x13, x1, x24
_br_done_30:
    addi x30, x31, 352
    amomax.w x6, x28, (x30)
    sll x16, x16, x28
    sraw x7, x19, x24
    slliw x8, x27, 16
    slliw x18, x16, 22
    sraiw x19, x14, 3
    sraiw x10, x21, 2
    bltu x11, x6, _br_taken_31
    sltu x28, x28, x25
    j _br_done_31
_br_taken_31:
    sll x28, x1, x16
_br_done_31:
    bne x27, x12, _br_taken_32
    srl x18, x7, x27
    j _br_done_32
_br_taken_32:
    sltu x18, x10, x7
_br_done_32:
    sraw x24, x7, x27
    xor x24, x27, x27
    sltu x20, x12, x11
    add x28, x9, x14
    srli x9, x16, 38
    addiw x15, x4, 159
    sltu x15, x15, x11
    andi x28, x23, 1108
    lwu x4, 332(x31)
    sw x24, 332(x31)
    blt x1, x1, _br_taken_33
    or x14, x7, x12
    j _br_done_33
_br_taken_33:
    sltu x14, x6, x26
_br_done_33:
    slti x11, x22, 1470
    xori x29, x20, -1185
    add x25, x23, x29
    sll x16, x1, x6
    srlw x7, x20, x7
    lb x12, 320(x31)
    sb x6, 320(x31)
    srlw x6, x25, x17
    srai x11, x13, 32
    fdiv.s f26, f26, f11
    fmul.d f30, f0, f29
    sraiw x21, x28, 10
    addi x1, x12, -1568
    beq x28, x13, _br_taken_34
    and x15, x18, x18
    j _br_done_34
_br_taken_34:
    sltu x15, x17, x6
_br_done_34:
    srliw x28, x29, 22
    or x25, x17, x5
    sraiw x17, x11, 30
    xori x14, x21, -768
    or x6, x4, x16
    fmul.s f4, f31, f18
    fsub.d f27, f28, f13
    fnmadd.d f10, f21, f14, f12
    fmax.s f12, f17, f3
    fmadd.s f19, f21, f29, f19
    fnmadd.s f6, f31, f4, f13
    sraw x15, x25, x20
    sra x25, x10, x14
    xori x27, x21, 2009
    lb x16, 232(x31)
    sb x17, 232(x31)
    rem x16, x5, x17
    mulh x10, x24, x27
    bltu x17, x8, _br_taken_35
    srl x10, x7, x29
    j _br_done_35
_br_taken_35:
    and x10, x15, x8
_br_done_35:
    ld x12, 480(x31)
    sd x4, 480(x31)
    divuw x4, x1, x7
    fmul.s f25, f28, f5
    fdiv.s f6, f31, f3
    fsub.s f26, f29, f0
    lw x21, 936(x31)
    sw x23, 936(x31)
    sraw x5, x5, x13
    subw x12, x21, x29
    ori x29, x16, 276
    addiw x18, x22, 1201
    sllw x26, x28, x10
    slt x8, x6, x17
    bgeu x8, x8, _br_taken_36
    add x20, x9, x20
    j _br_done_36
_br_taken_36:
    sltu x20, x6, x17
_br_done_36:
    fdiv.d f0, f17, f18
    fadd.d f26, f25, f4
    fdiv.s f12, f3, f12
    ori x9, x7, 917
    ori x4, x21, -458
    sltiu x19, x19, -1696
    addi x30, x31, 852
    amominu.w x6, x19, (x30)
    addiw x4, x14, 328
    sra x22, x7, x1
    lhu x24, 28(x31)
    sh x1, 28(x31)
    bge x14, x25, _br_taken_37
    add x5, x16, x28
    j _br_done_37
_br_taken_37:
    add x5, x27, x18
_br_done_37:
    and x19, x24, x12
    fmax.s f22, f20, f12
    fadd.d f8, f17, f29
    fdiv.d f3, f30, f8
    subw x19, x11, x11
    ori x1, x28, -179
    sraw x21, x6, x9
    srai x8, x8, 25
    addiw x27, x19, 1744
    sll x10, x23, x24
    slliw x23, x22, 28
    sllw x26, x4, x13
    beq x21, x24, _br_taken_38
    add x11, x11, x21
    j _br_done_38
_br_taken_38:
    sll x11, x26, x28
_br_done_38:
    bne x1, x18, _br_taken_39
    sltu x7, x18, x21
    j _br_done_39
_br_taken_39:
    srl x7, x23, x23
_br_done_39:
    addi x27, x14, 427
    or x5, x28, x10
    addiw x9, x9, -1656
    addiw x27, x21, -771
    mulhsu x26, x13, x1
    remu x18, x19, x25
    ori x20, x18, -1151
    srliw x26, x27, 4
    fmin.s f17, f26, f12
    fmin.s f16, f14, f5
    srai x7, x27, 27
    slti x7, x4, -257
    xori x12, x21, -92
    srl x11, x29, x11
    lwu x6, 740(x31)
    sw x16, 740(x31)
    sltiu x16, x12, 1397
    sra x8, x29, x5
    xor x27, x9, x1
    bltu x23, x18, _br_taken_40
    slt x10, x12, x15
    j _br_done_40
_br_taken_40:
    sra x10, x19, x19
_br_done_40:
    addi x30, x31, 184
    amoxor.w x22, x25, (x30)
    add x27, x1, x20
    xor x22, x18, x13
    beq x19, x8, _br_taken_41
    sltu x8, x21, x4
    j _br_done_41
_br_taken_41:
    xor x8, x4, x23
_br_done_41:
    addw x29, x27, x18
    srl x15, x28, x4
    bne x27, x13, _br_taken_42
    sra x28, x22, x17
    j _br_done_42
_br_taken_42:
    or x28, x21, x14
_br_done_42:
    sltiu x9, x26, -1741
    sll x23, x4, x13
    addi x30, x31, 392
    amoadd.w x7, x23, (x30)
    sraw x27, x9, x25
    add x20, x24, x10
    sraw x19, x8, x18
    bgeu x9, x28, _br_taken_43
    add x26, x28, x5
    j _br_done_43
_br_taken_43:
    or x26, x12, x11
_br_done_43:
    srli x23, x23, 27
    subw x10, x25, x14
    ori x10, x9, 997
    sra x28, x23, x22
    sllw x12, x14, x24
    addw x13, x23, x8
    blt x8, x18, _br_taken_44
    and x19, x22, x29
    j _br_done_44
_br_taken_44:
    sra x19, x6, x26
_br_done_44:
    fadd.s f20, f3, f6
    fmin.d f1, f29, f22
    fsub.d f31, f28, f2
    ld x19, 808(x31)
    sd x10, 808(x31)
    addi x30, x31, 136
    amomax.w x11, x9, (x30)
    lw x15, 900(x31)
    sw x9, 900(x31)
    srliw x10, x12, 16
    sllw x4, x9, x20
    bne x27, x18, _br_taken_45
    sltu x16, x11, x15
    j _br_done_45
_br_taken_45:
    or x16, x17, x15
_br_done_45:
    slli x16, x4, 54
    xori x18, x22, 972
    sraw x19, x12, x7
    srliw x8, x23, 28
    srli x22, x1, 16

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xee3d7d4337c55d41
    .dword 0x3447a18ff76d558f
    .dword 0x985b631185139995
    .dword 0x14eed6747bf4c196
    .dword 0x35d4db8f51a1e946
    .dword 0x25b4f8b503033715
    .dword 0x1d05f0a2248018e6
    .dword 0x39a16b2afb3ee745
    .dword 0xac808031c62260d4
    .dword 0x711d580a0519986b
    .dword 0x1543f5ee1a8f70be
    .dword 0xdf81a0d6ad40e60d
    .dword 0x014d3cad937910c6
    .dword 0x348d75df0fe2dbf8
    .dword 0x9b06ea7f35fae28d
    .dword 0x4218b4ee813ebd74
    .dword 0xfde7052f6a436da5
    .dword 0xdb0dccb35a6eb447
    .dword 0x47a22f0054877fcc
    .dword 0x537dff7554b77135
    .dword 0x060f8532ad6aab36
    .dword 0x4f47e03eeb515066
    .dword 0x40c365bb0aea88de
    .dword 0xe787f6db4e2379bf
    .dword 0x486f5dfda0366100
    .dword 0xca4f4ee0a74e4793
    .dword 0xd3ab6586230b3bcd
    .dword 0x5fa2f2ed75e8b8e5
    .dword 0x340bc12def6bbf94
    .dword 0xfab12809012dfdfb
    .dword 0xfa85ccb7e00beeea
    .dword 0x8165513f37da4837

    .align 2
_torture_data:
    .word 0x84da9ff8
    .word 0xbdd75aa4
    .word 0xe3083e97
    .word 0xf5e39242
    .word 0xb2f14533
    .word 0xa6cbfe69
    .word 0x3bcb82cb
    .word 0x0c08a106
    .word 0x74173b8b
    .word 0x6c885427
    .word 0xa40599ef
    .word 0x23332724
    .word 0x54d3d332
    .word 0x21200025
    .word 0x3f884b37
    .word 0x3eb621f8
    .word 0x04ad9131
    .word 0xde7932ee
    .word 0x463f3001
    .word 0x7c118737
    .word 0x467789ca
    .word 0x2c9015eb
    .word 0xd6f4d86b
    .word 0xe3ea0c19
    .word 0xfd5abc2f
    .word 0x5f5ccba5
    .word 0x73549aa7
    .word 0x8b3ba2d6
    .word 0x67f77662
    .word 0xf8cdf35b
    .word 0x1ab2e18f
    .word 0x8d6eb81a
    .word 0x1b73ce3e
    .word 0x7f5ccc65
    .word 0x19048207
    .word 0xca0d0f61
    .word 0x9ec64318
    .word 0xc4b859da
    .word 0x6fe7ac58
    .word 0x13802e6d
    .word 0x98c450ea
    .word 0x602c8a7e
    .word 0x70c57dc3
    .word 0x3286be30
    .word 0x95f9d0c3
    .word 0x2b63f396
    .word 0x41937c0f
    .word 0xe3ad43c6
    .word 0x89cd40af
    .word 0xea324529
    .word 0x751b0838
    .word 0xb839ea4c
    .word 0x34462fa6
    .word 0xb658e94a
    .word 0xe0d21924
    .word 0x103c0c93
    .word 0x5b278281
    .word 0xfd2784ea
    .word 0x27f8c8f6
    .word 0x215c9795
    .word 0x7bf5d677
    .word 0x27002a19
    .word 0x27c40156
    .word 0x38d5af55
    .word 0x134eee82
    .word 0x7dc19584
    .word 0xdff55746
    .word 0xf07a93e6
    .word 0x64d88157
    .word 0x1cb5f4f3
    .word 0x3bc89ae6
    .word 0x3f87bf88
    .word 0xda9e37a9
    .word 0x111fd272
    .word 0x06895a73
    .word 0x5a92479c
    .word 0x7e8441b4
    .word 0x64995c36
    .word 0x5b549c16
    .word 0x2cd8460b
    .word 0x933273ee
    .word 0x2198bdd8
    .word 0x887d8b60
    .word 0x462d6028
    .word 0x3f3e89cc
    .word 0xb4c974d6
    .word 0xee7b0e92
    .word 0xc11725a8
    .word 0x976d63b8
    .word 0x9eed0623
    .word 0x7cb2c146
    .word 0x339156f5
    .word 0x9fbea439
    .word 0x6c6745ef
    .word 0x22f974d6
    .word 0xc2e6abc0
    .word 0x617b20b1
    .word 0xc82e8cec
    .word 0x0202735c
    .word 0x8acd5a3a
    .word 0xf3d744bc
    .word 0x8a31e656
    .word 0x8c9aa1c9
    .word 0x43a23d0f
    .word 0xfffe17ba
    .word 0x01087e13
    .word 0xf2a05ffe
    .word 0xc766e56b
    .word 0x5b8a9176
    .word 0x3c34f4a1
    .word 0xba6c83cf
    .word 0x5b9bf2f3
    .word 0x198f87ce
    .word 0x3d1a8774
    .word 0x02b6646b
    .word 0x37d7d7f5
    .word 0x15d6e49a
    .word 0x04661558
    .word 0x1d5c931a
    .word 0x82345290
    .word 0xae67f6ec
    .word 0xf12a2010
    .word 0x2d1a5ab5
    .word 0x9f15b9dc
    .word 0xa019a0ac
    .word 0xc14e2ed2
    .word 0x2e348d25
    .word 0x285d4610
    .word 0xc1273bfe
    .word 0x5235ac33
    .word 0x550e2a8d
    .word 0xa8096ebb
    .word 0x6bd098cc
    .word 0x39157ccd
    .word 0x57508171
    .word 0x18d7c826
    .word 0xd604bbd3
    .word 0xaca4adf0
    .word 0x139a8edc
    .word 0x37d28fb9
    .word 0x0a946df8
    .word 0x93568ff8
    .word 0x0ef6925d
    .word 0xb731a695
    .word 0x11f00af5
    .word 0x77c2ec3b
    .word 0x9c9359e1
    .word 0x5f079e92
    .word 0xca90773d
    .word 0xa1ce104c
    .word 0x9991cbc3
    .word 0xbdb0e708
    .word 0xdcc633ad
    .word 0x86b15b19
    .word 0x997d02dd
    .word 0x7cf234d8
    .word 0x11c951d7
    .word 0x37261500
    .word 0xbeb179a6
    .word 0xf7a1278c
    .word 0x73c54326
    .word 0xfa578f6c
    .word 0xad974a85
    .word 0x5b3f8140
    .word 0x961d7c7b
    .word 0x9f63dcfa
    .word 0x8307a29a
    .word 0xb4c97d22
    .word 0xb7e5234d
    .word 0xf9fcffe9
    .word 0xde392af4
    .word 0xdd2735fc
    .word 0x75528e19
    .word 0x3d113979
    .word 0x8145f032
    .word 0x29a3cb05
    .word 0x54b2cdf8
    .word 0xc9df2683
    .word 0x27627f2d
    .word 0x1aa2f9cb
    .word 0x50193a42
    .word 0x23e66451
    .word 0xc9796d16
    .word 0xbf4ef5d1
    .word 0xb39251b9
    .word 0xa86b93da
    .word 0x4fbf9f79
    .word 0xb849472d
    .word 0x04610f2e
    .word 0x1c3fd889
    .word 0xe299955b
    .word 0xe4b5cdca
    .word 0x04119c2d
    .word 0x2dc6f183
    .word 0xeaee62a4
    .word 0x8d33987e
    .word 0x63977d9f
    .word 0xfdcca439
    .word 0xfaf619be
    .word 0x14a8fb6f
    .word 0x0f3c741d
    .word 0xc57340a8
    .word 0xc07fb5f4
    .word 0xfd19b857
    .word 0x43883a93
    .word 0x98dc5a89
    .word 0x74ddd09a
    .word 0xd967327a
    .word 0x05420865
    .word 0xc942d441
    .word 0x77c4a334
    .word 0x556c51fa
    .word 0x83198bf9
    .word 0x6065cc66
    .word 0x500ff1b3
    .word 0x5f6bbce4
    .word 0xf63bd962
    .word 0xda60e9ed
    .word 0x5fcc6e9a
    .word 0xe1b5518f
    .word 0x6cace3f2
    .word 0x89281932
    .word 0x12b4c021
    .word 0xc03f279b
    .word 0x6fa46451
    .word 0x71926543
    .word 0xbb619743
    .word 0x8b706eaf
    .word 0x0cf96b69
    .word 0xb00b6baa
    .word 0x8b20c256
    .word 0x555303c0
    .word 0xb53c0bab
    .word 0x443c6f99
    .word 0x0e459a9f
    .word 0x09103314
    .word 0x199fed5f
    .word 0x47ff3a4d
    .word 0xd9a8c539
    .word 0x7576a741
    .word 0x980c7939
    .word 0x29249f03
    .word 0x933f79af
    .word 0xf06b766b
    .word 0x3ceab09a
    .word 0x4344571e
    .word 0x001b851b
    .word 0xda204126
    .word 0x3b3f11b7
    .word 0x9bcd6cf9
    .word 0xea372e6c
    .word 0x42ff61a5
    .word 0x9dbd009e
    .word 0x7f4d88a3
    .word 0xaace7569
    .word 0x2cfeff6b

#include "frost_footer.S"
