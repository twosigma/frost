// Generated RV64IMAFDC torture test for Frost (seed=20260815)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x0ede4b846a3c4ad5
    li x4, 0x88b87c5e8369109c
    li x5, 0xa431d686c906c46e
    li x6, 0x06993b7f6ef39cf3
    li x7, 0x8d68db73e6e01457
    li x8, 0xee4070d703a41c21
    li x9, 0x088c587752223d05
    li x10, 0xcb6cbdff75359f77
    li x11, 0xdd0ce7f1960c5cda
    li x12, 0x176747d90b629f26
    li x13, 0x9ddcb8c16102a0a3
    li x14, 0xc25f5fd7d6ce6fb3
    li x15, 0x051e40ca7bc6a3d1
    li x16, 0xf5ec585dc5a516bb
    li x17, 0x51f307890248e9b7
    li x18, 0xdc3adfb7fc1d9b30
    li x19, 0xe06a48086006069e
    li x20, 0x738122cb7063a2f0
    li x21, 0x897f3348202a294a
    li x22, 0x316dfd3349ea1578
    li x23, 0xea3e8107182b3483
    li x24, 0x5c3e97d5cd73c755
    li x25, 0xaafaac7171cbe9e3
    li x26, 0xdbc9f240cf68111e
    li x27, 0x7f89b44e4b5c9da6
    li x28, 0x6765c721d9279457
    li x29, 0x4d2f1e02b84385cf
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
    li x1, 0x0a53db065ad2db49

    fmax.s f7, f16, f27
    fadd.s f4, f12, f18
    fmul.d f1, f23, f22
    fadd.s f31, f23, f8
    bltu x17, x25, _br_taken_0
    sltu x23, x29, x8
    j _br_done_0
_br_taken_0:
    add x23, x9, x28
_br_done_0:
    fmadd.s f2, f31, f22, f12
    fsub.s f19, f26, f14
    fmadd.d f1, f31, f17, f9
    lw x25, 196(x31)
    sw x1, 196(x31)
    fmin.s f31, f4, f21
    fdiv.d f10, f2, f17
    fnmadd.s f2, f25, f26, f27
    slti x5, x21, -1128
    srlw x11, x13, x20
    addiw x25, x22, 921
    sraw x18, x19, x15
    fdiv.d f23, f25, f20
    fmin.d f9, f26, f12
    fmul.s f16, f6, f19
    lw x19, 500(x31)
    sw x13, 500(x31)
    lw x19, 556(x31)
    sw x22, 556(x31)
    sltu x4, x19, x20
    addiw x24, x6, -1880
    ori x4, x7, -1146
    bltu x4, x24, _br_taken_1
    sub x5, x27, x16
    j _br_done_1
_br_taken_1:
    srl x5, x12, x7
_br_done_1:
    bltu x7, x27, _br_taken_2
    add x26, x19, x17
    j _br_done_2
_br_taken_2:
    and x26, x10, x28
_br_done_2:
    or x1, x22, x15
    andi x27, x22, -1625
    and x22, x10, x5
    ori x9, x11, -27
    srli x1, x27, 8
    slliw x13, x13, 28
    srl x9, x9, x28
    addiw x10, x12, -1362
    sll x29, x7, x7
    fmin.s f0, f29, f12
    fmul.d f5, f29, f12
    fnmsub.s f1, f31, f12, f17
    bltu x11, x22, _br_taken_3
    or x29, x19, x28
    j _br_done_3
_br_taken_3:
    xor x29, x16, x20
_br_done_3:
    addi x30, x31, 376
    amoand.d x24, x20, (x30)
    blt x11, x1, _br_taken_4
    xor x13, x10, x17
    j _br_done_4
_br_taken_4:
    and x13, x29, x15
_br_done_4:
    bge x21, x17, _br_taken_5
    sub x16, x27, x16
    j _br_done_5
_br_taken_5:
    and x16, x16, x11
_br_done_5:
    subw x1, x11, x19
    xori x6, x23, 1043
    slliw x20, x23, 11
    addw x16, x19, x17
    srai x21, x10, 20
    sltu x12, x9, x27
    srli x10, x27, 53
    bge x4, x9, _br_taken_6
    xor x16, x4, x5
    j _br_done_6
_br_taken_6:
    xor x16, x5, x9
_br_done_6:
    lwu x16, 724(x31)
    sw x7, 724(x31)
    or x22, x7, x14
    sraw x14, x14, x26
    ori x1, x13, -1511
    and x23, x15, x19
    ori x28, x15, -859
    sllw x23, x11, x18
    slt x15, x20, x25
    divw x8, x13, x23
    sub x17, x25, x27
    sltiu x27, x13, 1749
    addi x30, x31, 960
    amoand.w x11, x13, (x30)
    addi x30, x31, 120
    amoswap.w x23, x24, (x30)
    divu x28, x8, x25
    mulhu x9, x21, x7
    slti x20, x1, 1110
    sra x15, x18, x15
    sltu x20, x26, x1
    slt x8, x8, x27
    or x29, x14, x6
    lbu x26, 188(x31)
    sb x21, 188(x31)
    addi x30, x31, 384
    amomin.d x25, x9, (x30)
    bgeu x9, x11, _br_taken_7
    sltu x25, x20, x17
    j _br_done_7
_br_taken_7:
    and x25, x4, x7
_br_done_7:
    sraiw x4, x26, 5
    ori x11, x5, 156
    xor x28, x6, x20
    sltu x28, x13, x7
    fmax.s f9, f31, f20
    fdiv.s f9, f19, f21
    blt x13, x5, _br_taken_8
    sub x7, x24, x21
    j _br_done_8
_br_taken_8:
    xor x7, x14, x21
_br_done_8:
    beq x19, x16, _br_taken_9
    srl x7, x25, x21
    j _br_done_9
_br_taken_9:
    sub x7, x17, x4
_br_done_9:
    bgeu x15, x28, _br_taken_10
    sltu x7, x4, x4
    j _br_done_10
_br_taken_10:
    add x7, x17, x10
_br_done_10:
    ori x21, x25, -767
    or x22, x16, x6
    srliw x24, x17, 28
    lbu x26, 840(x31)
    sb x11, 840(x31)
    srai x22, x27, 5
    sub x6, x14, x20
    fmul.s f11, f28, f1
    fdiv.d f4, f30, f31
    fmul.s f15, f25, f24
    fnmsub.s f16, f21, f7, f14
    beq x20, x22, _br_taken_11
    and x23, x6, x4
    j _br_done_11
_br_taken_11:
    and x23, x14, x28
_br_done_11:
    lb x21, 316(x31)
    sb x6, 316(x31)
    ld x8, 656(x31)
    sd x14, 656(x31)
    addi x20, x20, -1142
    sraiw x15, x9, 19
    addiw x17, x8, -1816
    fdiv.d f11, f24, f26
    add x11, x29, x23
    srliw x28, x4, 28
    sltu x24, x20, x14
    sllw x24, x27, x17
    srai x17, x12, 44
    ori x24, x21, 1971
    beq x9, x28, _br_taken_12
    srl x27, x18, x6
    j _br_done_12
_br_taken_12:
    or x27, x26, x9
_br_done_12:
    ori x26, x26, 163
    andi x4, x13, -76
    subw x20, x1, x17
    sllw x25, x19, x21
    addw x9, x26, x16
    addw x4, x16, x8
    sraiw x4, x21, 12
    bge x26, x25, _br_taken_13
    sub x25, x9, x22
    j _br_done_13
_br_taken_13:
    slt x25, x1, x15
_br_done_13:
    addi x30, x31, 848
    amoswap.d x14, x18, (x30)
    bne x22, x1, _br_taken_14
    sub x27, x21, x25
    j _br_done_14
_br_taken_14:
    or x27, x9, x19
_br_done_14:
    bne x5, x23, _br_taken_15
    sll x15, x11, x11
    j _br_done_15
_br_taken_15:
    sra x15, x26, x4
_br_done_15:
    addi x17, x24, -1404
    slli x28, x6, 34
    sra x15, x13, x4
    addw x17, x27, x13
    or x4, x24, x9
    bne x21, x26, _br_taken_16
    sra x23, x10, x19
    j _br_done_16
_br_taken_16:
    slt x23, x23, x12
_br_done_16:
    beq x14, x14, _br_taken_17
    xor x8, x11, x23
    j _br_done_17
_br_taken_17:
    add x8, x22, x24
_br_done_17:
    sra x17, x5, x24
    subw x19, x17, x29
    andi x10, x23, -1058
    srlw x21, x25, x18
    xori x21, x18, -1048
    addi x30, x31, 792
    amominu.d x1, x22, (x30)
    srai x13, x20, 44
    sllw x23, x17, x25
    subw x8, x28, x7
    slti x18, x15, 43
    srli x10, x13, 10
    sraiw x7, x7, 30
    xori x19, x20, 1877
    addi x30, x31, 224
    amoand.w x11, x14, (x30)
    and x6, x11, x4
    xor x9, x20, x6
    sltiu x23, x18, 402
    sll x20, x9, x23
    sltu x1, x25, x5
    bgeu x8, x29, _br_taken_18
    add x28, x12, x12
    j _br_done_18
_br_taken_18:
    and x28, x6, x19
_br_done_18:
    srl x24, x29, x23
    slliw x27, x11, 5
    addw x22, x20, x16
    and x20, x16, x29
    remw x11, x14, x9
    divuw x10, x6, x26
    blt x21, x14, _br_taken_19
    sra x14, x28, x27
    j _br_done_19
_br_taken_19:
    add x14, x10, x10
_br_done_19:
    fmin.s f10, f1, f9
    fmax.d f2, f7, f9
    slliw x5, x20, 19
    add x8, x10, x1
    lhu x25, 588(x31)
    sh x9, 588(x31)
    srai x13, x19, 10
    sra x18, x27, x11
    add x10, x28, x28
    srliw x11, x23, 4
    or x17, x4, x12
    addiw x27, x5, -360
    bne x29, x21, _br_taken_20
    sub x20, x16, x19
    j _br_done_20
_br_taken_20:
    slt x20, x27, x22
_br_done_20:
    srai x16, x25, 14
    sll x14, x29, x6
    sra x6, x23, x12
    addi x28, x29, -223
    add x19, x14, x4
    sraw x29, x11, x24
    srl x21, x19, x28
    sll x6, x11, x28
    xori x24, x27, 1967
    addiw x20, x10, -682
    sub x5, x8, x26
    addi x13, x21, -208
    bne x28, x16, _br_taken_21
    add x22, x7, x29
    j _br_done_21
_br_taken_21:
    and x22, x20, x6
_br_done_21:
    slliw x19, x17, 15
    divu x24, x18, x11
    srai x17, x13, 10
    addiw x12, x25, 1310
    blt x22, x4, _br_taken_22
    xor x1, x27, x29
    j _br_done_22
_br_taken_22:
    and x1, x16, x29
_br_done_22:
    sraw x22, x5, x9
    sll x24, x9, x27
    sllw x18, x10, x17
    fmin.s f28, f29, f25
    fmul.d f10, f3, f10
    sllw x18, x23, x6
    srliw x8, x16, 3
    or x6, x17, x18
    divu x19, x27, x24
    beq x16, x13, _br_taken_23
    xor x17, x15, x25
    j _br_done_23
_br_taken_23:
    xor x17, x18, x27
_br_done_23:
    lwu x22, 532(x31)
    sw x6, 532(x31)
    mulhsu x26, x26, x14
    div x15, x4, x29
    lwu x22, 404(x31)
    sw x15, 404(x31)
    sraw x18, x8, x4
    sltiu x24, x9, 1409
    lbu x8, 468(x31)
    sb x27, 468(x31)
    sraiw x8, x26, 27
    bltu x10, x7, _br_taken_24
    sltu x1, x17, x20
    j _br_done_24
_br_taken_24:
    sra x1, x28, x24
_br_done_24:
    slli x15, x12, 36
    addi x5, x19, -791
    sraw x11, x19, x9
    blt x22, x17, _br_taken_25
    and x6, x24, x28
    j _br_done_25
_br_taken_25:
    sltu x6, x18, x7
_br_done_25:
    and x5, x18, x17
    sltiu x27, x16, 1146
    remu x25, x10, x1
    div x16, x18, x26
    bltu x20, x21, _br_taken_26
    sra x29, x25, x7
    j _br_done_26
_br_taken_26:
    slt x29, x27, x24
_br_done_26:
    sllw x27, x24, x20
    srlw x14, x23, x14
    lw x12, 4(x31)
    sw x24, 4(x31)
    lw x29, 420(x31)
    sw x29, 420(x31)
    fadd.s f26, f25, f9
    fmin.d f0, f20, f22
    sllw x13, x23, x7
    sltu x27, x10, x22
    or x4, x14, x22
    bne x14, x5, _br_taken_27
    slt x29, x22, x20
    j _br_done_27
_br_taken_27:
    sltu x29, x14, x22
_br_done_27:
    mulhu x21, x5, x18
    sllw x22, x27, x12
    srl x13, x27, x1
    blt x7, x12, _br_taken_28
    add x24, x18, x1
    j _br_done_28
_br_taken_28:
    and x24, x16, x27
_br_done_28:
    sltiu x17, x29, 542
    sll x15, x18, x22
    blt x14, x20, _br_taken_29
    sll x18, x27, x4
    j _br_done_29
_br_taken_29:
    slt x18, x28, x12
_br_done_29:
    bgeu x13, x7, _br_taken_30
    xor x1, x17, x12
    j _br_done_30
_br_taken_30:
    slt x1, x15, x13
_br_done_30:
    blt x24, x14, _br_taken_31
    or x7, x5, x25
    j _br_done_31
_br_taken_31:
    sltu x7, x8, x26
_br_done_31:
    sraw x21, x9, x24
    srl x23, x19, x29
    ori x19, x11, 1010
    fmax.d f13, f26, f14
    fadd.s f1, f15, f31
    fmax.s f8, f0, f25
    and x28, x26, x27
    fsub.s f30, f8, f7
    fadd.d f5, f21, f16
    bne x11, x20, _br_taken_32
    sub x13, x4, x5
    j _br_done_32
_br_taken_32:
    sra x13, x8, x19
_br_done_32:
    slli x29, x14, 46
    bge x11, x16, _br_taken_33
    add x19, x8, x29
    j _br_done_33
_br_taken_33:
    slt x19, x1, x17
_br_done_33:
    sll x5, x12, x24
    andi x22, x13, 1199
    addiw x8, x6, -1837
    addi x27, x22, 1956
    mulhu x22, x25, x19
    remuw x13, x23, x1
    fdiv.d f6, f4, f22
    fmax.s f28, f1, f26
    fadd.s f0, f7, f14
    srai x19, x19, 50
    sltu x26, x29, x15
    sltu x23, x26, x24
    srlw x7, x19, x16
    slt x22, x27, x4
    bge x27, x8, _br_taken_34
    sub x13, x21, x14
    j _br_done_34
_br_taken_34:
    add x13, x18, x9
_br_done_34:
    fmax.s f0, f20, f3
    fadd.s f30, f11, f8
    sltu x15, x23, x25
    sllw x11, x27, x15
    lwu x17, 688(x31)
    sw x6, 688(x31)
    ori x6, x7, 1175
    xori x18, x9, 508
    sllw x12, x24, x20
    slti x14, x1, -1142
    bltu x8, x9, _br_taken_35
    slt x7, x25, x24
    j _br_done_35
_br_taken_35:
    and x7, x5, x17
_br_done_35:
    beq x11, x8, _br_taken_36
    and x20, x12, x27
    j _br_done_36
_br_taken_36:
    sltu x20, x20, x28
_br_done_36:
    addi x30, x31, 392
    amoadd.w x15, x17, (x30)
    srai x7, x19, 22
    blt x7, x14, _br_taken_37
    sub x20, x22, x29
    j _br_done_37
_br_taken_37:
    or x20, x26, x7
_br_done_37:
    subw x12, x25, x9
    sllw x7, x25, x8
    addi x30, x31, 660
    amomax.w x4, x11, (x30)
    sraw x6, x4, x4
    and x10, x16, x11
    sraw x29, x28, x19
    fmin.d f7, f10, f30
    fnmadd.s f28, f21, f16, f18
    sll x5, x7, x28
    srliw x29, x23, 24
    srli x7, x13, 17
    bge x5, x6, _br_taken_38
    and x14, x16, x24
    j _br_done_38
_br_taken_38:
    sltu x14, x10, x1
_br_done_38:
    addi x6, x19, -1908
    and x11, x27, x27
    slti x28, x17, -1274
    srl x15, x17, x29
    sub x28, x29, x26
    sraiw x19, x23, 15
    mul x17, x7, x17
    mulhu x23, x27, x13
    srai x11, x4, 10
    sllw x26, x22, x12
    fnmadd.s f4, f10, f0, f22
    fsub.s f18, f28, f28
    fmsub.s f8, f4, f30, f5
    bne x6, x25, _br_taken_39
    sltu x28, x10, x17
    j _br_done_39
_br_taken_39:
    sub x28, x23, x20
_br_done_39:
    andi x22, x18, 410
    slliw x14, x4, 14
    fmul.s f3, f16, f7
    fadd.d f1, f5, f15
    fsub.s f19, f17, f30
    slti x14, x17, 780
    slti x13, x13, -33
    sra x16, x9, x22
    lw x22, 280(x31)
    sw x21, 280(x31)
    addiw x15, x23, -1706
    add x9, x28, x1
    slt x10, x7, x7
    sltu x7, x6, x10
    subw x12, x26, x8
    sraw x13, x5, x19
    beq x24, x10, _br_taken_40
    or x13, x11, x24
    j _br_done_40
_br_taken_40:
    slt x13, x4, x29
_br_done_40:
    addi x4, x21, 768
    addiw x6, x7, -1142
    addi x5, x28, 644
    andi x24, x12, -126
    srliw x7, x28, 10
    srliw x1, x21, 16
    sltu x13, x18, x4
    bgeu x19, x16, _br_taken_41
    xor x12, x17, x15
    j _br_done_41
_br_taken_41:
    xor x12, x7, x19
_br_done_41:
    mulhu x25, x15, x9
    mul x15, x4, x9
    bne x1, x28, _br_taken_42
    slt x13, x4, x4
    j _br_done_42
_br_taken_42:
    slt x13, x6, x21
_br_done_42:
    bltu x15, x13, _br_taken_43
    sltu x26, x14, x26
    j _br_done_43
_br_taken_43:
    sra x26, x4, x8
_br_done_43:
    sllw x16, x15, x5
    xori x16, x16, -815
    addi x30, x31, 808
    amomax.w x17, x28, (x30)
    lhu x12, 460(x31)
    sh x14, 460(x31)
    addi x23, x7, 731
    srlw x26, x8, x14
    slliw x24, x1, 3
    sraiw x20, x27, 4
    slt x10, x28, x7
    sub x14, x21, x23
    addw x28, x1, x14
    addw x15, x9, x1
    sub x15, x20, x28
    slli x4, x14, 14
    addiw x4, x19, -669

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x6195794dc76cdf60
    .dword 0x236044cab5e070ac
    .dword 0xa2c1f22ecb124871
    .dword 0xa9f78f4b0bcac98d
    .dword 0xc413dac8116ef05a
    .dword 0x9f87a746e331533f
    .dword 0x2ba48f4b07752470
    .dword 0x236643c52650bc1d
    .dword 0xbaea150badfcfa5f
    .dword 0x747c121f406b3e62
    .dword 0x70cc637cb5962b42
    .dword 0xf6e6fc1217c0a97b
    .dword 0x5609e15b29d8f48e
    .dword 0xe2ce6b79d8e7e961
    .dword 0xe85136d25f73abbf
    .dword 0xe3e4f487362e6cec
    .dword 0xb08dec9037d5e7c6
    .dword 0x358bbcc8b31a29e0
    .dword 0xba05cafc8492f22a
    .dword 0xf697de5ef6824cc5
    .dword 0x75e9d888c71cc3e4
    .dword 0x2dd8c6d77578ec01
    .dword 0x5a4d6e317b97aed8
    .dword 0xe8e6f540a147051d
    .dword 0x6f6b4794213ad8e5
    .dword 0x17750dbb670a9883
    .dword 0x3d2f3526db19db1f
    .dword 0xe53465dd2765e6e4
    .dword 0x76b11b1d16ca9b55
    .dword 0x11241fd7c68a658e
    .dword 0x12f387a9fb4bbefb
    .dword 0x4e57b004b47190c3

    .align 2
_torture_data:
    .word 0xe2e3bfcf
    .word 0x1cf3c687
    .word 0x8f04418f
    .word 0x8133b88d
    .word 0x6262f299
    .word 0x403c9342
    .word 0x9d242353
    .word 0x9fcc4aff
    .word 0x89532e35
    .word 0x7738e2b2
    .word 0x10885bf8
    .word 0xfc0f8aff
    .word 0x55cc9392
    .word 0x63bbe616
    .word 0x8fb703aa
    .word 0x11bfbe95
    .word 0x9d3f07f3
    .word 0xfa8703e8
    .word 0xad6acfd6
    .word 0xc2cf9975
    .word 0x6937975f
    .word 0xaf2fa431
    .word 0x351055e7
    .word 0x760398d4
    .word 0x17c7587b
    .word 0xee6da36a
    .word 0xd416ee99
    .word 0x5183459a
    .word 0x87d1b872
    .word 0xf6999048
    .word 0x77d4d16d
    .word 0x251c2afd
    .word 0x16ab4334
    .word 0xb3fdfad9
    .word 0xdcbab034
    .word 0x1023fd55
    .word 0xd3384966
    .word 0xf4becc2f
    .word 0x345346b5
    .word 0x19eaccc7
    .word 0x0bfaa5b0
    .word 0x8fd67940
    .word 0x3ddf1b24
    .word 0x79090df9
    .word 0xf4dc031c
    .word 0x50b022fe
    .word 0x209b1d0b
    .word 0xfc2f1b9e
    .word 0xc71dd7db
    .word 0x2b9ddd75
    .word 0xc4fc0c36
    .word 0xa4d5a33f
    .word 0x4b5586ff
    .word 0x907f233b
    .word 0x166b3ac6
    .word 0xf91e4feb
    .word 0x8428489a
    .word 0xaebe2b4d
    .word 0x5a73ed9b
    .word 0x43e385d7
    .word 0xe5db4ce2
    .word 0x52f55ddb
    .word 0x1c1d73ee
    .word 0xa3556d5c
    .word 0xa512ab08
    .word 0xd5a06676
    .word 0x1dad6c08
    .word 0x9309567a
    .word 0xa631cca9
    .word 0x7a3ddb1c
    .word 0x8a3ff670
    .word 0x72888b5e
    .word 0x751d84e3
    .word 0xd671fc85
    .word 0x0c10be45
    .word 0x0d750cd2
    .word 0xacbde01d
    .word 0x7a56779f
    .word 0x44f5676b
    .word 0xb321ee91
    .word 0x9f91e142
    .word 0x8ed58c63
    .word 0xc0ebe6ae
    .word 0xe121a289
    .word 0xda5be289
    .word 0x7704d9a6
    .word 0xec698162
    .word 0xb8ac10f6
    .word 0x3185e42e
    .word 0xa5b0aa36
    .word 0x3d1d1b28
    .word 0x80abba5c
    .word 0x0e73e699
    .word 0xed60dbdb
    .word 0x4d992764
    .word 0x8027a4c4
    .word 0x97e18654
    .word 0x633c2585
    .word 0xf71a7c3d
    .word 0x9db023dc
    .word 0x16c99ec2
    .word 0x40ace61c
    .word 0x3626a745
    .word 0xb7e5304a
    .word 0xc5356b12
    .word 0x4c52204f
    .word 0xedcbcb47
    .word 0x196fa804
    .word 0x93338bd7
    .word 0xb1775ccb
    .word 0xa3372533
    .word 0x88dc8e58
    .word 0x3bd9a3dd
    .word 0x6effe8da
    .word 0xc56e441e
    .word 0xb6c3189d
    .word 0xb4d5e6d7
    .word 0xbd6d2f1a
    .word 0xc352c2e3
    .word 0x72647fb8
    .word 0x90c3c4ce
    .word 0x642b02f5
    .word 0x8ae6c45f
    .word 0x0340466b
    .word 0x0ea066db
    .word 0x93b91787
    .word 0xdc87ee7d
    .word 0x1abfd53e
    .word 0x154155c9
    .word 0xdb6f30a8
    .word 0x5faf969f
    .word 0x435369f6
    .word 0xf83a30b6
    .word 0x3396622c
    .word 0xab8e8565
    .word 0xe85867c0
    .word 0xf25d9d63
    .word 0x47ff5ccc
    .word 0x2016fa62
    .word 0x7a079610
    .word 0x2e2e67b8
    .word 0xc757807e
    .word 0x58f0aeee
    .word 0x22d1e141
    .word 0x9245f5ac
    .word 0x95945026
    .word 0x9d3a3fc4
    .word 0x57c2639f
    .word 0xade32e64
    .word 0x94bad441
    .word 0x9de1dfcd
    .word 0x5be0c49b
    .word 0x2fde9574
    .word 0x389f13ea
    .word 0x8e6772f8
    .word 0x31605000
    .word 0xef8ebc6b
    .word 0x03fd9417
    .word 0x53d59253
    .word 0x297063cd
    .word 0x00c4bf79
    .word 0x95c36a52
    .word 0x1a72a270
    .word 0x39be669e
    .word 0xa47a427a
    .word 0x7ff30450
    .word 0xfe19eaa1
    .word 0x80210498
    .word 0x39aeb72b
    .word 0x8639598a
    .word 0x729a9123
    .word 0x4e6368e9
    .word 0x1be6e9dc
    .word 0x73e0bf11
    .word 0xdc5c582c
    .word 0xc148d8ca
    .word 0x6fc8d6df
    .word 0x501d455e
    .word 0x4a509e01
    .word 0x93c5c80a
    .word 0x4853802b
    .word 0x7c0d3fff
    .word 0xcc647f22
    .word 0x20b6bbaa
    .word 0xe5c1f464
    .word 0xd14a521d
    .word 0x02409f66
    .word 0x74178f9f
    .word 0x0c51a585
    .word 0x39e7428b
    .word 0x459c5906
    .word 0x9552e4c7
    .word 0x353bbde8
    .word 0xc83e07b4
    .word 0x3ee7a039
    .word 0xe5ea3d3b
    .word 0x965710d2
    .word 0xc68ecdf5
    .word 0x0a2476d3
    .word 0x97abb4d0
    .word 0xbb966147
    .word 0x153b4504
    .word 0x91d8bf6e
    .word 0x7ecfeb1a
    .word 0x1de1af21
    .word 0x4c6531d9
    .word 0x817743f6
    .word 0x0951f417
    .word 0x16af63ce
    .word 0x5b5b4676
    .word 0x36c470fa
    .word 0x5f891d81
    .word 0x287a26f8
    .word 0x4858380d
    .word 0x2004233b
    .word 0x8abf197d
    .word 0x86713017
    .word 0x78013373
    .word 0xedd7d05f
    .word 0xe1d1aba7
    .word 0xddcd86a9
    .word 0x33117b39
    .word 0x061bb02c
    .word 0x59292240
    .word 0x31017107
    .word 0xe70c9220
    .word 0xa82921f7
    .word 0x9162e109
    .word 0x142efe13
    .word 0x51fe9b20
    .word 0x0e7017e2
    .word 0xbd109cc9
    .word 0xff69e931
    .word 0xa2930926
    .word 0x212d4a23
    .word 0x9cab646b
    .word 0x8e43db7e
    .word 0xa7b4f55d
    .word 0x57caf2f2
    .word 0xa90e3656
    .word 0x75d3fcaf
    .word 0x26a35fb1
    .word 0x3014d8d5
    .word 0x90a6beb0
    .word 0xc9db69a6
    .word 0xadd2cb31
    .word 0x92c9b636
    .word 0x906a5dea
    .word 0xad95d3a2
    .word 0xcb5cba68
    .word 0x688a597d
    .word 0xb9665882
    .word 0x72041322
    .word 0x2b78452a
    .word 0xc0b4ee32
    .word 0x5e4cf58f

#include "frost_footer.S"
