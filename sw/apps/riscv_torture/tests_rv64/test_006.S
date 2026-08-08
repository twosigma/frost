// Generated RV64IMAFDC torture test for Frost (seed=20260808)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x8a1418daa3f4a7cd
    li x4, 0x9ebf8617ad08a8ef
    li x5, 0xfff966ec06f1622a
    li x6, 0x5bf0969c7f00746b
    li x7, 0xe382419eae518993
    li x8, 0x74f01c5dbc8882fd
    li x9, 0xa4585e93bbef6071
    li x10, 0xe45bb9442044bf59
    li x11, 0x1d9079c91aa14015
    li x12, 0xa10f9f42e6063fab
    li x13, 0x3cac8bd404780006
    li x14, 0x581bb17a56a0faf4
    li x15, 0x5ae45999fc5c8269
    li x16, 0x4537303121b1a365
    li x17, 0x1e65c036a9fff0d0
    li x18, 0x91c9b34294a438ef
    li x19, 0x5a3cd2c4b38001ed
    li x20, 0xc920f019f900a3d4
    li x21, 0x970209cacd4d79f7
    li x22, 0xee8b7b4222220b49
    li x23, 0xfd6120279e911d44
    li x24, 0xb142e071afa6e248
    li x25, 0x75dc75b863e8045e
    li x26, 0xa22ba6bdd5f59307
    li x27, 0xd09917bc58de88a7
    li x28, 0x1f06a7ff01f5bc8a
    li x29, 0xa30e9d19061125a3
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
    li x1, 0xa9fd6626c93f554b

    sltiu x28, x25, -839
    lbu x23, 672(x31)
    sb x15, 672(x31)
    rem x6, x4, x8
    div x24, x22, x29
    sltiu x14, x13, 307
    and x13, x26, x24
    bge x13, x6, _br_taken_0
    add x12, x25, x16
    j _br_done_0
_br_taken_0:
    sub x12, x13, x5
_br_done_0:
    sraw x14, x9, x10
    sub x10, x4, x22
    srl x22, x16, x17
    lh x4, 556(x31)
    sh x20, 556(x31)
    sub x17, x6, x13
    ld x10, 208(x31)
    sd x22, 208(x31)
    sub x11, x23, x13
    slli x8, x5, 21
    lwu x10, 384(x31)
    sw x20, 384(x31)
    blt x16, x7, _br_taken_1
    sltu x25, x25, x28
    j _br_done_1
_br_taken_1:
    and x25, x6, x15
_br_done_1:
    lbu x22, 428(x31)
    sb x21, 428(x31)
    xor x6, x24, x21
    sraw x11, x4, x13
    ori x22, x20, -272
    xori x7, x28, 970
    beq x28, x25, _br_taken_2
    srl x22, x26, x9
    j _br_done_2
_br_taken_2:
    sra x22, x28, x25
_br_done_2:
    beq x26, x1, _br_taken_3
    sltu x22, x4, x5
    j _br_done_3
_br_taken_3:
    sub x22, x14, x18
_br_done_3:
    slt x20, x20, x6
    add x5, x9, x15
    sll x29, x1, x20
    bne x5, x14, _br_taken_4
    or x8, x27, x1
    j _br_done_4
_br_taken_4:
    sub x8, x17, x26
_br_done_4:
    divuw x7, x27, x20
    divu x6, x6, x22
    fadd.d f29, f11, f3
    sltiu x23, x25, -1120
    sltiu x22, x28, -568
    sltiu x28, x9, -1961
    addi x20, x28, 899
    add x22, x26, x18
    lw x9, 228(x31)
    sw x11, 228(x31)
    lwu x27, 344(x31)
    sw x27, 344(x31)
    or x28, x7, x19
    and x9, x25, x21
    sltiu x13, x24, 1080
    slli x23, x18, 46
    bgeu x25, x25, _br_taken_5
    sra x26, x24, x25
    j _br_done_5
_br_taken_5:
    sra x26, x8, x6
_br_done_5:
    bltu x21, x28, _br_taken_6
    sra x1, x29, x27
    j _br_done_6
_br_taken_6:
    sub x1, x19, x12
_br_done_6:
    slti x23, x20, 1110
    srl x6, x28, x28
    addw x22, x26, x24
    bne x5, x25, _br_taken_7
    add x22, x16, x17
    j _br_done_7
_br_taken_7:
    sltu x22, x26, x11
_br_done_7:
    mulhu x5, x19, x18
    slliw x11, x27, 28
    or x14, x26, x17
    addw x1, x27, x7
    andi x19, x11, 1824
    beq x8, x16, _br_taken_8
    or x20, x8, x28
    j _br_done_8
_br_taken_8:
    and x20, x4, x21
_br_done_8:
    lh x29, 368(x31)
    sh x12, 368(x31)
    fmadd.d f24, f16, f17, f18
    fadd.d f11, f16, f13
    sltu x9, x13, x6
    srai x5, x6, 32
    sltu x5, x23, x25
    or x8, x18, x23
    subw x18, x9, x11
    lbu x19, 892(x31)
    sb x24, 892(x31)
    sraw x16, x9, x24
    slliw x26, x10, 8
    xor x6, x19, x27
    xori x19, x18, -660
    srli x27, x25, 49
    and x23, x26, x24
    ori x14, x26, -1295
    lw x21, 724(x31)
    sw x27, 724(x31)
    addi x30, x31, 768
    amoadd.w x8, x16, (x30)
    fmul.d f6, f14, f10
    fnmadd.s f28, f8, f20, f4
    fadd.d f25, f23, f12
    bltu x4, x19, _br_taken_9
    sltu x14, x11, x1
    j _br_done_9
_br_taken_9:
    xor x14, x28, x25
_br_done_9:
    remu x10, x26, x15
    lh x12, 980(x31)
    sh x27, 980(x31)
    slti x12, x25, -1447
    ori x10, x22, 986
    fmin.s f25, f17, f23
    fdiv.s f21, f13, f19
    fadd.s f13, f13, f18
    bgeu x14, x17, _br_taken_10
    xor x12, x17, x20
    j _br_done_10
_br_taken_10:
    add x12, x28, x1
_br_done_10:
    sub x6, x23, x5
    srl x16, x1, x25
    srli x21, x25, 7
    fmul.s f0, f10, f17
    fdiv.d f3, f29, f2
    sll x5, x29, x25
    slliw x14, x4, 26
    subw x6, x12, x16
    slti x12, x24, 795
    srl x17, x1, x12
    addw x15, x7, x16
    ori x9, x9, 622
    beq x24, x23, _br_taken_11
    sub x9, x29, x29
    j _br_done_11
_br_taken_11:
    slt x9, x26, x1
_br_done_11:
    xori x10, x25, -976
    sub x12, x16, x15
    fmax.d f10, f27, f19
    slli x25, x6, 0
    sltiu x8, x29, 621
    sllw x14, x21, x11
    lbu x23, 36(x31)
    sb x14, 36(x31)
    sra x24, x28, x6
    sllw x22, x4, x13
    sltiu x18, x17, 1016
    addiw x10, x24, 1427
    sra x28, x23, x8
    addw x9, x21, x8
    fmin.s f4, f19, f4
    fmul.d f0, f24, f0
    fmax.s f28, f16, f30
    fmin.d f29, f14, f3
    fmul.s f31, f5, f22
    addw x10, x22, x27
    slliw x15, x5, 4
    lw x18, 460(x31)
    sw x27, 460(x31)
    bltu x17, x9, _br_taken_12
    sub x19, x28, x14
    j _br_done_12
_br_taken_12:
    and x19, x1, x25
_br_done_12:
    sltu x19, x18, x28
    srl x19, x1, x22
    addw x18, x21, x18
    sraiw x15, x16, 5
    addw x12, x8, x7
    sra x21, x19, x1
    bne x17, x25, _br_taken_13
    add x22, x26, x8
    j _br_done_13
_br_taken_13:
    or x22, x14, x4
_br_done_13:
    bgeu x16, x8, _br_taken_14
    sub x22, x26, x22
    j _br_done_14
_br_taken_14:
    sll x22, x24, x13
_br_done_14:
    fnmadd.s f5, f1, f1, f14
    fmul.s f9, f14, f28
    fmul.s f24, f28, f21
    srl x20, x1, x1
    sllw x17, x23, x21
    srai x1, x14, 11
    ld x9, 264(x31)
    sd x21, 264(x31)
    slti x24, x26, 612
    addi x4, x23, 1301
    sltu x27, x1, x24
    subw x28, x1, x20
    srliw x15, x7, 26
    addiw x29, x1, 259
    srli x19, x4, 49
    xor x19, x29, x29
    blt x29, x10, _br_taken_15
    add x25, x11, x4
    j _br_done_15
_br_taken_15:
    add x25, x29, x20
_br_done_15:
    div x28, x27, x14
    mulw x27, x10, x22
    sltiu x19, x10, -1813
    and x24, x6, x25
    subw x25, x27, x5
    fmadd.d f6, f29, f16, f19
    fmsub.d f17, f2, f22, f2
    fmin.s f14, f6, f24
    ori x15, x8, 923
    or x15, x9, x15
    slt x15, x8, x17
    fmul.s f29, f13, f1
    sraw x28, x10, x28
    blt x24, x27, _br_taken_16
    sub x7, x16, x25
    j _br_done_16
_br_taken_16:
    sra x7, x11, x4
_br_done_16:
    srlw x27, x8, x20
    srlw x8, x7, x23
    sltiu x27, x12, 1379
    fmadd.d f17, f12, f29, f8
    fmin.d f31, f27, f4
    fmin.d f21, f25, f11
    slt x27, x26, x29
    sltiu x1, x19, -1809
    slti x4, x6, -648
    xori x8, x16, -2028
    addi x23, x28, 197
    sllw x26, x23, x28
    slti x16, x4, -119
    sraw x8, x15, x29
    addi x30, x31, 452
    amoxor.w x24, x15, (x30)
    sltiu x28, x24, 355
    bltu x13, x26, _br_taken_17
    or x25, x25, x7
    j _br_done_17
_br_taken_17:
    sll x25, x1, x28
_br_done_17:
    bltu x24, x20, _br_taken_18
    slt x12, x1, x8
    j _br_done_18
_br_taken_18:
    sll x12, x19, x25
_br_done_18:
    beq x24, x14, _br_taken_19
    sub x14, x20, x18
    j _br_done_19
_br_taken_19:
    and x14, x16, x20
_br_done_19:
    remu x11, x9, x26
    mulh x29, x29, x24
    beq x13, x26, _br_taken_20
    add x12, x15, x28
    j _br_done_20
_br_taken_20:
    sra x12, x6, x23
_br_done_20:
    bne x16, x18, _br_taken_21
    slt x14, x29, x19
    j _br_done_21
_br_taken_21:
    sra x14, x23, x11
_br_done_21:
    addi x30, x31, 928
    amominu.d x17, x20, (x30)
    bltu x23, x26, _br_taken_22
    and x14, x21, x23
    j _br_done_22
_br_taken_22:
    xor x14, x29, x17
_br_done_22:
    addi x24, x18, 983
    srai x16, x18, 58
    srliw x12, x5, 28
    xor x1, x20, x28
    sllw x4, x19, x16
    and x18, x16, x17
    slti x26, x13, 1714
    slti x14, x11, 762
    bgeu x29, x18, _br_taken_23
    add x1, x13, x16
    j _br_done_23
_br_taken_23:
    sltu x1, x12, x8
_br_done_23:
    beq x17, x17, _br_taken_24
    or x17, x23, x27
    j _br_done_24
_br_taken_24:
    sll x17, x24, x21
_br_done_24:
    fadd.d f24, f6, f13
    fmax.s f20, f2, f10
    ori x8, x21, 418
    ld x10, 568(x31)
    sd x11, 568(x31)
    fdiv.s f2, f23, f16
    fnmsub.s f11, f16, f21, f14
    fmin.d f9, f5, f20
    lwu x11, 28(x31)
    sw x17, 28(x31)
    div x25, x28, x5
    divw x26, x25, x28
    slli x5, x23, 42
    srai x6, x11, 32
    srliw x10, x17, 28
    slt x15, x13, x28
    addi x19, x10, -859
    blt x26, x1, _br_taken_25
    xor x7, x17, x29
    j _br_done_25
_br_taken_25:
    slt x7, x9, x12
_br_done_25:
    addi x30, x31, 816
    amoand.w x28, x12, (x30)
    bltu x9, x12, _br_taken_26
    sra x4, x14, x7
    j _br_done_26
_br_taken_26:
    sltu x4, x1, x8
_br_done_26:
    fmadd.s f22, f8, f22, f12
    addiw x20, x27, -948
    sraiw x4, x15, 22
    srliw x1, x28, 13
    sra x16, x29, x5
    slt x4, x5, x21
    fsub.d f15, f2, f2
    beq x25, x15, _br_taken_27
    sll x4, x28, x6
    j _br_done_27
_br_taken_27:
    sltu x4, x5, x25
_br_done_27:
    sll x28, x15, x21
    srlw x10, x15, x22
    blt x19, x16, _br_taken_28
    sll x15, x9, x29
    j _br_done_28
_br_taken_28:
    or x15, x1, x26
_br_done_28:
    fnmadd.d f17, f4, f11, f6
    fmul.s f27, f18, f1
    fnmsub.s f13, f7, f21, f6
    sub x20, x4, x10
    sraiw x21, x5, 20
    sll x29, x14, x18
    sllw x24, x5, x10
    sltu x27, x4, x8
    sllw x11, x20, x29
    addi x6, x16, -1412
    addi x12, x26, 683
    bgeu x5, x17, _br_taken_29
    add x12, x11, x14
    j _br_done_29
_br_taken_29:
    slt x12, x5, x1
_br_done_29:
    beq x25, x23, _br_taken_30
    xor x5, x4, x9
    j _br_done_30
_br_taken_30:
    and x5, x26, x18
_br_done_30:
    blt x22, x23, _br_taken_31
    add x5, x7, x16
    j _br_done_31
_br_taken_31:
    and x5, x18, x26
_br_done_31:
    ori x20, x20, 1990
    srli x29, x23, 47
    slli x1, x4, 11
    slti x18, x28, 825
    addi x18, x18, -1646
    fnmsub.s f11, f9, f0, f29
    fsub.s f15, f13, f0
    fmsub.s f29, f0, f29, f21
    bgeu x4, x18, _br_taken_32
    slt x16, x7, x22
    j _br_done_32
_br_taken_32:
    xor x16, x6, x7
_br_done_32:
    addw x14, x24, x22
    sltu x12, x28, x19
    subw x18, x6, x7
    srli x23, x13, 41
    and x16, x26, x22
    xori x18, x10, 397
    srl x7, x7, x26
    srli x21, x5, 36
    ori x6, x21, 1730
    bltu x7, x24, _br_taken_33
    sub x24, x10, x27
    j _br_done_33
_br_taken_33:
    xor x24, x12, x1
_br_done_33:
    divu x18, x8, x11
    rem x26, x14, x16
    addi x30, x31, 596
    amomaxu.w x23, x1, (x30)
    srliw x28, x21, 31
    addi x30, x31, 720
    amomaxu.w x23, x25, (x30)
    srai x20, x12, 23
    sltu x8, x13, x29
    srai x15, x5, 39
    bge x18, x5, _br_taken_34
    sub x4, x29, x7
    j _br_done_34
_br_taken_34:
    or x4, x8, x9
_br_done_34:
    add x11, x11, x25
    srl x10, x20, x13
    lw x18, 20(x31)
    sw x29, 20(x31)
    addw x9, x20, x11
    sub x25, x19, x10
    addiw x10, x25, 1782
    sra x6, x14, x21
    srliw x25, x7, 3
    addiw x4, x11, 725
    subw x9, x28, x15
    fmax.s f18, f19, f0
    fmul.s f26, f21, f26
    addi x30, x31, 512
    amoor.d x28, x26, (x30)
    fadd.d f6, f11, f20
    fdiv.s f10, f24, f18
    lh x11, 284(x31)
    sh x18, 284(x31)
    addi x30, x31, 344
    amoand.w x28, x10, (x30)
    addw x21, x14, x25
    sll x28, x13, x19
    sra x16, x26, x11
    fnmsub.s f26, f7, f2, f12
    fadd.s f16, f10, f27
    fmadd.d f4, f11, f16, f25
    mul x11, x1, x12
    divu x11, x20, x11
    fmin.s f4, f11, f22
    fmul.s f6, f6, f21
    addi x22, x28, -721
    lb x15, 444(x31)
    sb x13, 444(x31)
    mul x26, x16, x5
    remuw x13, x9, x21
    bne x14, x15, _br_taken_35
    sub x17, x19, x13
    j _br_done_35
_br_taken_35:
    sra x17, x21, x8
_br_done_35:
    mul x9, x16, x6
    remuw x10, x23, x4
    fmax.d f3, f3, f21
    beq x16, x13, _br_taken_36
    add x20, x7, x17
    j _br_done_36
_br_taken_36:
    sra x20, x14, x26
_br_done_36:
    fmul.s f13, f27, f7
    fdiv.s f2, f29, f15
    sltiu x11, x16, -1981
    sraw x25, x4, x9
    srliw x26, x25, 3
    addiw x22, x7, 391
    addi x18, x1, 1386
    srliw x20, x10, 9
    fmul.s f7, f1, f14
    fadd.s f31, f12, f27
    bgeu x15, x15, _br_taken_37
    add x7, x10, x27
    j _br_done_37
_br_taken_37:
    slt x7, x19, x6
_br_done_37:
    srlw x9, x20, x9
    addiw x15, x8, -292
    sub x11, x4, x12
    add x15, x22, x11
    bne x7, x18, _br_taken_38
    sub x20, x6, x6
    j _br_done_38
_br_taken_38:
    srl x20, x18, x29
_br_done_38:
    bge x10, x1, _br_taken_39
    sltu x20, x10, x10
    j _br_done_39
_br_taken_39:
    slt x20, x4, x19
_br_done_39:
    slliw x12, x18, 17
    sra x4, x15, x12
    sraiw x25, x24, 5
    addiw x19, x17, 1266
    slli x9, x11, 52
    beq x29, x14, _br_taken_40
    add x17, x14, x27
    j _br_done_40
_br_taken_40:
    sub x17, x5, x22
_br_done_40:
    bgeu x4, x16, _br_taken_41
    sltu x14, x12, x24
    j _br_done_41
_br_taken_41:
    slt x14, x6, x15
_br_done_41:
    srli x26, x13, 30
    xor x17, x21, x25
    div x16, x14, x1
    divuw x10, x27, x14
    fdiv.s f28, f27, f21
    slt x19, x17, x25
    addw x26, x15, x20
    sltiu x22, x12, 1136

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x86d8d0ef6f78bcb5
    .dword 0x053334c648f788bd
    .dword 0xaab3a462d0a66e18
    .dword 0xfe3a328511555e8a
    .dword 0x33e7726a63ca6015
    .dword 0x06b62b898aac53de
    .dword 0x521f1f9668e1271f
    .dword 0x56a0570c38a69ea0
    .dword 0x6ce430ba920212f0
    .dword 0x0f835d2d0d16208c
    .dword 0xeff6f369789775ff
    .dword 0xb98956883f7fd9d1
    .dword 0x9b53c5497903a62f
    .dword 0xc900994eb9a7868f
    .dword 0x248d96dc90cb1f5c
    .dword 0x940b7fd7d93fcc93
    .dword 0x8736c69e14c08fd7
    .dword 0x0e9dcaf84b7abfcf
    .dword 0xa0e329222101c9b5
    .dword 0x678aa44803a80b8e
    .dword 0xae84cfdb6c843d19
    .dword 0x2c16ca691a526c37
    .dword 0x27ff7e55dda56953
    .dword 0x9f37b3339da35a25
    .dword 0x7b72f7954e968c60
    .dword 0x23890fdeeb51c824
    .dword 0x8add1c9fd601f866
    .dword 0xa4ff445cdbbf05c2
    .dword 0x952e733c51080e8a
    .dword 0x5f137fc138b2b9d5
    .dword 0x8f4a75b802a9f596
    .dword 0xcd158640ff34c962

    .align 2
_torture_data:
    .word 0x75a18c01
    .word 0xb7ce76a4
    .word 0x4360cc76
    .word 0x5c7f353a
    .word 0xd2a2617b
    .word 0x55d9b64f
    .word 0x72d2aa6c
    .word 0x01fb98f4
    .word 0x9175b59b
    .word 0x92e763f4
    .word 0x378c0b9b
    .word 0x0da2d602
    .word 0x12fadaa5
    .word 0x9ab1c92a
    .word 0x688b0a16
    .word 0x32995d35
    .word 0xeee50704
    .word 0xac1a20bc
    .word 0xe0c57fa9
    .word 0x88594591
    .word 0x8182010b
    .word 0x495af1a7
    .word 0x8afa11d2
    .word 0xb5d0bd01
    .word 0xd9d02198
    .word 0x2d1fd9e2
    .word 0xca04f57b
    .word 0xdf8e9501
    .word 0x1d34d72a
    .word 0x82ff0073
    .word 0x9105a191
    .word 0x27016394
    .word 0xd0ea6496
    .word 0x1cea1e0f
    .word 0xf854672b
    .word 0x6c8f9433
    .word 0xe1c828b2
    .word 0xac2ab250
    .word 0xd553ef0c
    .word 0x9776370b
    .word 0x64ef21e9
    .word 0x02dae9da
    .word 0x79a583bc
    .word 0x690ca640
    .word 0x440ec6db
    .word 0x4000866c
    .word 0x14c858ca
    .word 0x177a7d78
    .word 0x20af6a77
    .word 0xf4865f93
    .word 0x371a3bad
    .word 0xd2d93366
    .word 0x93d9e0dd
    .word 0xf8f6fe48
    .word 0x91ff0f38
    .word 0x4fdad776
    .word 0x5fda762e
    .word 0x6e706137
    .word 0xfe2c2917
    .word 0x6cc3bf47
    .word 0x90a8371f
    .word 0xca1fe205
    .word 0x177d6d6a
    .word 0xf718f657
    .word 0xc9df54d2
    .word 0x225a3983
    .word 0x3bca9c1f
    .word 0xcab5c738
    .word 0xf3df6817
    .word 0x061765ef
    .word 0x5a137c32
    .word 0x0523900c
    .word 0x3d56fda3
    .word 0x390dc975
    .word 0xe0b9d65c
    .word 0x3c353fa4
    .word 0xd5b13a1f
    .word 0x4a4f3e39
    .word 0x5c5bca20
    .word 0x0dc6f72d
    .word 0x4341fd8e
    .word 0xe9eff9f7
    .word 0x2a5620f4
    .word 0xc095d904
    .word 0xdfe3a1e2
    .word 0x31f18521
    .word 0x5215daac
    .word 0x5c9871f0
    .word 0x721398fc
    .word 0xb8e2b6be
    .word 0x7efe165a
    .word 0xb9a242d1
    .word 0x5681d140
    .word 0x8bce91b2
    .word 0xf8f7e2f0
    .word 0x4d560f0d
    .word 0xafcbffb7
    .word 0x75a2384c
    .word 0x5d957dd3
    .word 0xbe5b6b43
    .word 0x501cfe00
    .word 0x14646555
    .word 0xd824d107
    .word 0x192c3781
    .word 0x96c65c69
    .word 0x4f4b36fa
    .word 0x6a126cb6
    .word 0xbfa15f1e
    .word 0xa679c484
    .word 0xaee21148
    .word 0x83ff5401
    .word 0xbfbb80e0
    .word 0xf8de071e
    .word 0xe170970b
    .word 0x20a9feb4
    .word 0x3105fedf
    .word 0x2a4a6dff
    .word 0xd70664b7
    .word 0x4840ae42
    .word 0x643e206d
    .word 0xa65ce948
    .word 0x1e533a3c
    .word 0x38b8e4ab
    .word 0xfc9e15a2
    .word 0xdeb70efb
    .word 0x0f909111
    .word 0x41429aaa
    .word 0x71c862ea
    .word 0xec93c344
    .word 0x4ff81155
    .word 0x88c772b8
    .word 0x9f7f737a
    .word 0xe4e8efbb
    .word 0x0e707f4a
    .word 0x176ac1d5
    .word 0xd9b2f2cb
    .word 0x4d05d0bf
    .word 0xd525c00e
    .word 0x3b256da9
    .word 0x948d31a0
    .word 0x85c7391c
    .word 0xce53d0c0
    .word 0x2791dfab
    .word 0x3ae71998
    .word 0x347ce362
    .word 0x50c59789
    .word 0xe8e24f88
    .word 0x67cc1bd9
    .word 0x2df9b6c8
    .word 0xb4439f42
    .word 0xdef808bb
    .word 0xa0db7cac
    .word 0xc5b78292
    .word 0x5e041876
    .word 0xb8d6024f
    .word 0x12cfb7f5
    .word 0x525ff754
    .word 0x9bcf5a8b
    .word 0x34b95f0f
    .word 0xfc8d8593
    .word 0x1f16fadd
    .word 0x3cfd05df
    .word 0x30ec8877
    .word 0xda6b2859
    .word 0x31d1a0b3
    .word 0x21d3be18
    .word 0x168a7ff1
    .word 0xbe108236
    .word 0x9d03f603
    .word 0x5173c82a
    .word 0xedf39be8
    .word 0xf3da2a7a
    .word 0x2d46f74c
    .word 0xf25a4520
    .word 0x957713d8
    .word 0xc51e412d
    .word 0x6e1f03fe
    .word 0x3edb48d5
    .word 0x62ef52d8
    .word 0x62b345d9
    .word 0x3428fddb
    .word 0xada10f3b
    .word 0xc65df8cd
    .word 0xf82672a0
    .word 0x2d04ea73
    .word 0x4b50e73d
    .word 0xea315dc4
    .word 0x6f3cbd74
    .word 0x360af858
    .word 0x6d0ed1b4
    .word 0xb3babc31
    .word 0x1dc4b0f3
    .word 0xd94f36bf
    .word 0x5e0245f5
    .word 0x96b2ea76
    .word 0x65ddba4b
    .word 0x2cbe7a14
    .word 0x9341d861
    .word 0xf8b3c5e5
    .word 0xfa40b106
    .word 0x7968eece
    .word 0x92193814
    .word 0xf4a1fbdf
    .word 0x35b74032
    .word 0x0cd2c3e4
    .word 0x360c04c6
    .word 0x294a4c85
    .word 0x357326a2
    .word 0x7400b686
    .word 0xeeabe1c3
    .word 0x28c81209
    .word 0x49aa464d
    .word 0x1d45b801
    .word 0x16349181
    .word 0x286880ec
    .word 0x49bf24d0
    .word 0xcc7de6f5
    .word 0x52c1702a
    .word 0x61f0a5c5
    .word 0x9a3b66ac
    .word 0xf037950a
    .word 0xd864c642
    .word 0x8332570e
    .word 0xf7bc1565
    .word 0xf95f5579
    .word 0x45b7da14
    .word 0x62a09f8d
    .word 0xabf50736
    .word 0x78da8833
    .word 0x9a05f2c7
    .word 0xcd2b38a3
    .word 0x320d47fc
    .word 0x147bfaba
    .word 0xacef3028
    .word 0xcc8bcb90
    .word 0xcb9effec
    .word 0x25be159d
    .word 0x80471375
    .word 0xb83df77f
    .word 0x4fd7f0d9
    .word 0x62191f75
    .word 0xbcf070dc
    .word 0x91f5608f
    .word 0xb14b2664
    .word 0xad99ed51
    .word 0xf4ce546b
    .word 0x566e0299
    .word 0xb31e8ce1
    .word 0x94732216
    .word 0xf6b3acfb
    .word 0x18a3e2fb
    .word 0x7a9b2d10
    .word 0x380535e6
    .word 0x712e8de0
    .word 0x181b81e4
    .word 0xac6a0508

#include "frost_footer.S"
