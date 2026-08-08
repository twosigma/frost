// Generated RV64IMAFDC torture test for Frost (seed=20260817)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x56f6f73308873a2c
    li x4, 0x8cde735321c2f599
    li x5, 0x9109ff25e6993778
    li x6, 0xf6798843ed8ec6d0
    li x7, 0x1991da227d85de6e
    li x8, 0x4b10cbb2984f4fe3
    li x9, 0x1601d4e9e31f5d8a
    li x10, 0x4195b33b15412b1c
    li x11, 0x2c4f5d03c6f300b1
    li x12, 0x9c98ca8669da6c55
    li x13, 0x73251342eedd29ca
    li x14, 0xc5b41cf9344d632d
    li x15, 0x4968346f7c0f6980
    li x16, 0x7ce1ea12eeab7a24
    li x17, 0xccff4d99554b8756
    li x18, 0x202d4ef906c19b6c
    li x19, 0xc84885d06a79bc31
    li x20, 0xa738ad92a02794c5
    li x21, 0xc7076ca08098ac14
    li x22, 0x80963413b42c492e
    li x23, 0xcfea3b5eb462ac57
    li x24, 0x5c292fe8c9f3b817
    li x25, 0x7e139beff69d8121
    li x26, 0x8ad8ed3a67cae0b9
    li x27, 0xf11ba6f88ab482e4
    li x28, 0xdff41f2f4e315a07
    li x29, 0xa266c6d6b29b9e21
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
    li x1, 0x648a1b835a039597

    lwu x21, 496(x31)
    sw x5, 496(x31)
    bge x26, x9, _br_taken_0
    slt x27, x25, x15
    j _br_done_0
_br_taken_0:
    sll x27, x18, x4
_br_done_0:
    fdiv.d f20, f24, f7
    fmsub.d f21, f11, f3, f26
    andi x11, x5, -1650
    sltu x28, x27, x6
    subw x24, x25, x20
    andi x12, x19, 319
    sraiw x29, x7, 14
    sltu x22, x4, x8
    sraw x26, x8, x18
    and x8, x9, x18
    sllw x16, x27, x1
    sraw x19, x16, x6
    slliw x25, x12, 28
    bltu x11, x22, _br_taken_1
    add x25, x18, x21
    j _br_done_1
_br_taken_1:
    sub x25, x17, x18
_br_done_1:
    srli x1, x24, 7
    xori x14, x7, 840
    ori x8, x16, 976
    fmax.s f16, f7, f31
    fmadd.s f25, f5, f30, f14
    fsub.s f14, f31, f15
    beq x24, x18, _br_taken_2
    add x9, x13, x22
    j _br_done_2
_br_taken_2:
    srl x9, x9, x8
_br_done_2:
    lw x23, 276(x31)
    sw x7, 276(x31)
    srai x4, x10, 19
    or x14, x26, x4
    addw x28, x22, x13
    addi x4, x8, 2004
    sub x8, x28, x23
    bge x12, x5, _br_taken_3
    sub x11, x15, x4
    j _br_done_3
_br_taken_3:
    and x11, x13, x15
_br_done_3:
    lw x22, 524(x31)
    sw x5, 524(x31)
    bne x15, x18, _br_taken_4
    xor x4, x9, x7
    j _br_done_4
_br_taken_4:
    sltu x4, x15, x13
_br_done_4:
    srli x16, x18, 43
    addiw x28, x26, -1055
    addiw x28, x24, 1509
    sraw x18, x5, x19
    fnmadd.d f8, f19, f23, f1
    fmsub.d f24, f26, f20, f8
    sllw x13, x25, x23
    srliw x28, x7, 6
    blt x16, x4, _br_taken_5
    sra x28, x21, x13
    j _br_done_5
_br_taken_5:
    add x28, x29, x25
_br_done_5:
    lw x25, 0(x31)
    sw x6, 0(x31)
    subw x16, x21, x1
    slti x11, x5, -116
    sllw x16, x16, x23
    blt x23, x11, _br_taken_6
    or x16, x5, x18
    j _br_done_6
_br_taken_6:
    sra x16, x28, x11
_br_done_6:
    bltu x11, x10, _br_taken_7
    and x5, x24, x5
    j _br_done_7
_br_taken_7:
    sub x5, x27, x5
_br_done_7:
    ori x21, x12, 1344
    ori x17, x29, -957
    fadd.d f4, f6, f19
    fmul.s f4, f27, f6
    fmsub.s f16, f13, f27, f22
    srli x1, x25, 32
    slt x15, x20, x29
    xor x22, x28, x19
    sub x14, x28, x19
    or x17, x23, x17
    sll x4, x9, x27
    beq x8, x22, _br_taken_8
    and x7, x4, x10
    j _br_done_8
_br_taken_8:
    slt x7, x24, x4
_br_done_8:
    addi x30, x31, 560
    amomaxu.d x10, x7, (x30)
    srlw x23, x5, x20
    srlw x6, x13, x11
    srlw x22, x10, x18
    srlw x5, x19, x18
    sra x24, x4, x23
    addw x12, x25, x1
    sraiw x26, x13, 8
    bge x8, x16, _br_taken_9
    sra x5, x7, x19
    j _br_done_9
_br_taken_9:
    sub x5, x8, x16
_br_done_9:
    srlw x12, x14, x13
    or x18, x4, x21
    div x1, x29, x9
    div x26, x5, x29
    srlw x21, x7, x20
    sraw x20, x20, x17
    ld x9, 688(x31)
    sd x24, 688(x31)
    bge x16, x14, _br_taken_10
    sll x13, x18, x16
    j _br_done_10
_br_taken_10:
    and x13, x15, x15
_br_done_10:
    sltiu x17, x15, -889
    addi x14, x24, -458
    slli x5, x25, 53
    blt x10, x16, _br_taken_11
    xor x14, x19, x14
    j _br_done_11
_br_taken_11:
    sltu x14, x21, x19
_br_done_11:
    add x22, x12, x12
    xori x8, x4, -476
    sll x22, x19, x29
    beq x1, x5, _br_taken_12
    and x19, x28, x27
    j _br_done_12
_br_taken_12:
    xor x19, x6, x11
_br_done_12:
    bgeu x1, x29, _br_taken_13
    sltu x23, x29, x4
    j _br_done_13
_br_taken_13:
    add x23, x7, x16
_br_done_13:
    bgeu x25, x26, _br_taken_14
    xor x25, x23, x17
    j _br_done_14
_br_taken_14:
    add x25, x4, x19
_br_done_14:
    beq x9, x24, _br_taken_15
    xor x21, x7, x26
    j _br_done_15
_br_taken_15:
    sltu x21, x20, x13
_br_done_15:
    add x20, x27, x28
    ori x21, x29, -1309
    slt x19, x4, x24
    sraiw x19, x5, 29
    sll x7, x17, x23
    subw x24, x15, x15
    fsub.s f23, f13, f25
    srliw x6, x4, 9
    subw x25, x18, x7
    srai x14, x10, 40
    slli x9, x12, 34
    sraw x12, x20, x1
    addiw x5, x1, -167
    fmin.s f24, f21, f3
    fdiv.s f31, f19, f22
    fmax.s f23, f0, f4
    sub x8, x13, x22
    ori x10, x16, -1090
    slti x21, x16, 363
    addw x16, x18, x8
    addw x7, x23, x17
    bgeu x7, x6, _br_taken_16
    srl x5, x26, x25
    j _br_done_16
_br_taken_16:
    and x5, x14, x6
_br_done_16:
    xor x27, x21, x15
    beq x14, x12, _br_taken_17
    slt x28, x6, x18
    j _br_done_17
_br_taken_17:
    slt x28, x11, x18
_br_done_17:
    fsub.d f11, f23, f28
    fdiv.s f29, f27, f30
    fmax.s f27, f11, f16
    blt x25, x19, _br_taken_18
    sltu x11, x15, x23
    j _br_done_18
_br_taken_18:
    sltu x11, x19, x27
_br_done_18:
    bgeu x19, x11, _br_taken_19
    sltu x28, x7, x18
    j _br_done_19
_br_taken_19:
    sltu x28, x20, x24
_br_done_19:
    fsub.d f24, f2, f0
    fmadd.s f25, f3, f1, f15
    fdiv.s f7, f14, f14
    beq x26, x11, _br_taken_20
    xor x12, x29, x16
    j _br_done_20
_br_taken_20:
    and x12, x12, x27
_br_done_20:
    divw x22, x4, x14
    fmsub.d f22, f9, f12, f4
    fsub.d f8, f13, f28
    fmax.d f11, f16, f20
    slt x17, x19, x25
    xor x16, x11, x18
    addi x9, x16, 935
    sltiu x8, x17, 1541
    srli x14, x18, 61
    add x28, x1, x19
    and x24, x1, x1
    slti x26, x25, -386
    srli x17, x12, 0
    bge x10, x17, _br_taken_21
    sltu x9, x12, x19
    j _br_done_21
_br_taken_21:
    sltu x9, x18, x26
_br_done_21:
    divw x19, x10, x27
    mulh x23, x1, x16
    divuw x5, x16, x18
    addi x30, x31, 204
    amomaxu.w x24, x14, (x30)
    ori x7, x27, -1882
    sra x13, x14, x1
    srlw x9, x25, x24
    srlw x17, x16, x12
    xor x4, x4, x19
    addiw x24, x17, -1274
    addiw x26, x22, -1805
    and x25, x27, x21
    beq x23, x22, _br_taken_22
    srl x15, x1, x10
    j _br_done_22
_br_taken_22:
    add x15, x29, x8
_br_done_22:
    ld x9, 192(x31)
    sd x28, 192(x31)
    ori x25, x28, 1943
    slliw x7, x17, 27
    addi x30, x31, 672
    amoor.d x25, x25, (x30)
    bne x10, x1, _br_taken_23
    srl x6, x25, x14
    j _br_done_23
_br_taken_23:
    sub x6, x28, x28
_br_done_23:
    fmin.d f25, f1, f13
    fnmsub.s f21, f7, f26, f18
    fmin.s f16, f19, f21
    fmax.s f11, f16, f23
    srliw x24, x11, 24
    sraiw x21, x27, 24
    subw x29, x22, x6
    bne x9, x10, _br_taken_24
    srl x14, x1, x1
    j _br_done_24
_br_taken_24:
    or x14, x19, x12
_br_done_24:
    sltu x17, x6, x10
    ori x29, x8, -1154
    bltu x21, x6, _br_taken_25
    srl x10, x11, x26
    j _br_done_25
_br_taken_25:
    or x10, x9, x4
_br_done_25:
    fdiv.s f22, f13, f25
    fsub.d f27, f18, f23
    xori x29, x8, 1690
    addi x30, x31, 624
    amoadd.d x19, x27, (x30)
    bne x15, x28, _br_taken_26
    and x25, x4, x14
    j _br_done_26
_br_taken_26:
    slt x25, x27, x19
_br_done_26:
    bgeu x4, x4, _br_taken_27
    slt x25, x4, x17
    j _br_done_27
_br_taken_27:
    srl x25, x27, x11
_br_done_27:
    remw x21, x15, x25
    remu x18, x25, x28
    sltiu x21, x6, 1994
    and x21, x29, x8
    slliw x29, x19, 8
    sll x22, x15, x23
    and x13, x20, x20
    and x5, x1, x4
    addw x18, x27, x6
    lwu x11, 992(x31)
    sw x24, 992(x31)
    fadd.d f6, f27, f11
    fsub.d f4, f24, f13
    fsub.s f16, f12, f5
    ori x22, x28, -1878
    bgeu x17, x16, _br_taken_28
    slt x16, x5, x28
    j _br_done_28
_br_taken_28:
    sltu x16, x18, x29
_br_done_28:
    sltiu x9, x28, -1626
    sllw x8, x7, x13
    ori x21, x16, -1401
    fmin.s f12, f2, f16
    fmsub.s f2, f6, f26, f0
    slliw x18, x19, 14
    sltiu x10, x7, 1021
    or x18, x10, x13
    subw x18, x8, x16
    sub x24, x23, x12
    fmul.d f16, f8, f9
    bgeu x10, x6, _br_taken_29
    sll x29, x20, x7
    j _br_done_29
_br_taken_29:
    or x29, x24, x1
_br_done_29:
    sraiw x24, x1, 31
    lhu x28, 988(x31)
    sh x22, 988(x31)
    fmsub.s f31, f4, f8, f27
    addw x4, x9, x19
    sltu x1, x4, x1
    and x27, x28, x10
    xori x11, x10, -1874
    sltu x18, x22, x24
    lh x14, 568(x31)
    sh x20, 568(x31)
    addw x18, x12, x8
    xori x28, x17, -669
    fmax.s f4, f26, f4
    ld x23, 736(x31)
    sd x7, 736(x31)
    bge x17, x15, _br_taken_30
    srl x27, x22, x26
    j _br_done_30
_br_taken_30:
    and x27, x5, x18
_br_done_30:
    and x12, x26, x7
    rem x10, x12, x7
    blt x29, x19, _br_taken_31
    srl x17, x23, x7
    j _br_done_31
_br_taken_31:
    xor x17, x9, x7
_br_done_31:
    fmin.s f13, f13, f15
    fmin.d f24, f23, f6
    fmin.s f14, f3, f24
    sllw x8, x12, x7
    sll x29, x25, x8
    ori x20, x13, 1203
    sub x27, x17, x7
    bltu x11, x1, _br_taken_32
    and x8, x1, x1
    j _br_done_32
_br_taken_32:
    slt x8, x28, x17
_br_done_32:
    blt x24, x26, _br_taken_33
    add x9, x19, x18
    j _br_done_33
_br_taken_33:
    add x9, x5, x14
_br_done_33:
    addw x16, x10, x19
    xor x15, x27, x28
    srl x27, x26, x4
    sraiw x12, x12, 5
    sll x24, x25, x6
    blt x26, x9, _br_taken_34
    and x9, x22, x5
    j _br_done_34
_br_taken_34:
    sltu x9, x14, x1
_br_done_34:
    bltu x14, x22, _br_taken_35
    sltu x28, x28, x23
    j _br_done_35
_br_taken_35:
    and x28, x4, x25
_br_done_35:
    xor x28, x14, x29
    addi x30, x31, 536
    amomin.w x17, x23, (x30)
    addi x30, x31, 480
    amomaxu.d x4, x22, (x30)
    sraw x20, x9, x24
    sll x16, x11, x16
    sltiu x13, x23, -327
    bne x8, x25, _br_taken_36
    sub x17, x17, x22
    j _br_done_36
_br_taken_36:
    and x17, x26, x14
_br_done_36:
    bgeu x9, x5, _br_taken_37
    sub x27, x4, x8
    j _br_done_37
_br_taken_37:
    xor x27, x28, x12
_br_done_37:
    bltu x1, x12, _br_taken_38
    and x23, x10, x1
    j _br_done_38
_br_taken_38:
    sub x23, x21, x17
_br_done_38:
    remu x1, x23, x29
    ld x15, 32(x31)
    sd x11, 32(x31)
    slti x21, x13, 1021
    subw x25, x22, x8
    addw x17, x17, x8
    lhu x19, 468(x31)
    sh x6, 468(x31)
    bne x14, x27, _br_taken_39
    sub x16, x27, x13
    j _br_done_39
_br_taken_39:
    sra x16, x23, x21
_br_done_39:
    bltu x1, x21, _br_taken_40
    srl x25, x18, x7
    j _br_done_40
_br_taken_40:
    sll x25, x13, x19
_br_done_40:
    bne x24, x15, _br_taken_41
    sll x24, x6, x4
    j _br_done_41
_br_taken_41:
    sltu x24, x26, x20
_br_done_41:
    ld x22, 184(x31)
    sd x29, 184(x31)
    lbu x21, 220(x31)
    sb x9, 220(x31)
    blt x15, x29, _br_taken_42
    sll x18, x25, x29
    j _br_done_42
_br_taken_42:
    sltu x18, x4, x17
_br_done_42:
    sllw x8, x22, x17
    bltu x12, x20, _br_taken_43
    sub x9, x29, x20
    j _br_done_43
_br_taken_43:
    xor x9, x19, x9
_br_done_43:
    ori x25, x1, 989
    sub x22, x14, x10
    xori x27, x11, 1448
    lwu x9, 200(x31)
    sw x11, 200(x31)
    fnmsub.d f16, f13, f26, f29
    fmsub.s f16, f9, f15, f24
    fdiv.d f14, f20, f18
    lwu x14, 840(x31)
    sw x24, 840(x31)
    remw x14, x15, x19
    add x1, x7, x18
    lbu x21, 812(x31)
    sb x9, 812(x31)
    srlw x6, x17, x25
    sllw x28, x5, x14
    srlw x15, x12, x16
    xori x17, x5, -1301
    sltiu x13, x13, -718
    srliw x14, x15, 16
    div x12, x14, x20
    lw x15, 824(x31)
    sw x17, 824(x31)
    slli x23, x28, 0
    srliw x5, x15, 0
    slliw x12, x22, 30
    subw x5, x27, x5
    xor x20, x6, x26
    add x5, x1, x28
    sra x27, x16, x26
    xor x9, x4, x1
    sraw x15, x6, x15
    sra x24, x29, x6
    sub x20, x29, x18
    andi x4, x14, 315
    sub x27, x10, x6
    lbu x6, 360(x31)
    sb x19, 360(x31)
    lw x23, 260(x31)
    sw x28, 260(x31)
    bne x18, x9, _br_taken_44
    sll x25, x25, x6
    j _br_done_44
_br_taken_44:
    or x25, x9, x22
_br_done_44:
    mulhsu x5, x13, x15
    srai x15, x25, 41
    sll x1, x27, x18
    sltiu x24, x23, 7
    fsub.s f5, f19, f9
    fnmsub.s f10, f13, f10, f28
    fmin.d f26, f16, f3
    slti x24, x19, 1533
    addi x11, x28, 815
    lbu x9, 580(x31)
    sb x24, 580(x31)
    add x27, x15, x14
    ori x10, x27, -1741
    xor x1, x24, x25
    bgeu x26, x17, _br_taken_45
    slt x12, x18, x16
    j _br_done_45
_br_taken_45:
    srl x12, x14, x27
_br_done_45:
    sllw x8, x10, x19
    sllw x24, x7, x4
    bltu x4, x25, _br_taken_46
    and x28, x4, x6
    j _br_done_46
_br_taken_46:
    srl x28, x15, x15
_br_done_46:
    bgeu x6, x26, _br_taken_47
    sll x10, x26, x9
    j _br_done_47
_br_taken_47:
    slt x10, x25, x22
_br_done_47:
    ld x27, 104(x31)
    sd x14, 104(x31)
    bgeu x9, x11, _br_taken_48
    sltu x5, x5, x1
    j _br_done_48
_br_taken_48:
    sltu x5, x20, x15
_br_done_48:
    and x17, x29, x20
    slti x22, x7, -1356
    beq x8, x28, _br_taken_49
    sra x16, x26, x19
    j _br_done_49
_br_taken_49:
    and x16, x6, x1
_br_done_49:
    and x22, x1, x14
    bne x1, x13, _br_taken_50
    add x1, x5, x22
    j _br_done_50
_br_taken_50:
    srl x1, x27, x15
_br_done_50:
    div x23, x18, x18
    fmax.s f18, f29, f27
    bgeu x26, x22, _br_taken_51
    sll x15, x1, x5
    j _br_done_51
_br_taken_51:
    and x15, x18, x28
_br_done_51:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x2603bb7fdde64bc0
    .dword 0xcb0210b4496eb892
    .dword 0x080e4d5f3516fa70
    .dword 0xca0484563b567ce5
    .dword 0x709f2afea0ec9607
    .dword 0xe06b691ea9fcddf1
    .dword 0x922cef6793dc200f
    .dword 0xbd3a89aad8353df4
    .dword 0x20539620f5981398
    .dword 0xd40a9ee4c35d7f95
    .dword 0xda732ae3562892ec
    .dword 0x16cb81feb2392268
    .dword 0xd4a82bbcad65388c
    .dword 0x72814bdcf6a4f224
    .dword 0x28f1327de5ef4d17
    .dword 0x82582f0190a056fb
    .dword 0xe824249a5130e6dc
    .dword 0x987a46b435ec2f50
    .dword 0x847fff7a49a1055a
    .dword 0x0c828ff1e8996d4e
    .dword 0x3e72e28f64584c29
    .dword 0x561e66c901bd60ed
    .dword 0x5df4ddf91bfad217
    .dword 0x3257fabd3374aedb
    .dword 0x2859f6c2349e8cce
    .dword 0xe810288ab3dd3a61
    .dword 0xa202b5a617e7e380
    .dword 0xfc42ddb63eae2e87
    .dword 0x34263569cb3ad790
    .dword 0x8341019fe5a107f8
    .dword 0x2b5414d23e20a96c
    .dword 0xd272ccc613c41494

    .align 2
_torture_data:
    .word 0xaaf50917
    .word 0x8d7d34d8
    .word 0x6ee517fe
    .word 0x1a086e6a
    .word 0x5153def5
    .word 0x91ac641f
    .word 0xd0475e8b
    .word 0x107427da
    .word 0x0e080b76
    .word 0x71d86431
    .word 0x85b052c4
    .word 0x1587323c
    .word 0xeabf8f9b
    .word 0x8ae09df0
    .word 0xfd62c33d
    .word 0x554478a5
    .word 0x09f3a7e6
    .word 0x0846859d
    .word 0xafc76851
    .word 0x9f3db353
    .word 0x441ee5cc
    .word 0x97db225b
    .word 0x197d6cd7
    .word 0xc80e7bd8
    .word 0x7007fed1
    .word 0x7c9bb561
    .word 0x12def9b6
    .word 0x10d6c47a
    .word 0x820cc09e
    .word 0xccaaf539
    .word 0x1f9f8ba8
    .word 0xa20b6641
    .word 0x5fc09eb3
    .word 0xae9bd936
    .word 0x6df19330
    .word 0x157f919c
    .word 0x116c9c74
    .word 0x6f1559c8
    .word 0x8ecbeff0
    .word 0xa4d06751
    .word 0x8f91b345
    .word 0x8294cc8f
    .word 0x58ea708e
    .word 0x80b4768b
    .word 0x6e358af9
    .word 0xd142b261
    .word 0x0c54e3c8
    .word 0x0448a226
    .word 0x3c2bf677
    .word 0x6150c529
    .word 0xed37ab39
    .word 0x09be2f3a
    .word 0xdb42e5ea
    .word 0xb16f05f4
    .word 0x8e926379
    .word 0xafb5334b
    .word 0x17f33ddb
    .word 0x69f5f379
    .word 0xb5fedd37
    .word 0xd6afe001
    .word 0x0e1898fe
    .word 0xc511b14e
    .word 0xcc3dc738
    .word 0xe03ed6ec
    .word 0xffeed59e
    .word 0xcd4eba55
    .word 0xc8aa897d
    .word 0x5483e616
    .word 0xda140bb8
    .word 0xfd19170b
    .word 0x229f4dee
    .word 0xda5c9ea1
    .word 0x7214bea2
    .word 0x01b55a0b
    .word 0x69451db4
    .word 0x4859aee9
    .word 0x32686cc8
    .word 0x929b1b37
    .word 0x1cdeee8a
    .word 0xf5baf00c
    .word 0x041a5f5a
    .word 0x88b01241
    .word 0xa8c58638
    .word 0x81b9731c
    .word 0xe38f3e34
    .word 0x7f371b4b
    .word 0x17199f56
    .word 0x1921b169
    .word 0xc32b164e
    .word 0x4f4d3048
    .word 0xdfae94d3
    .word 0x19cc1f73
    .word 0x6374d4d9
    .word 0x4ff3e151
    .word 0x34ada6ad
    .word 0x75817210
    .word 0x8086ee64
    .word 0x2b828431
    .word 0xbd6862b2
    .word 0xe4237988
    .word 0x3dffd6b3
    .word 0xa1e240f6
    .word 0x4f7bfe81
    .word 0x15c1da0d
    .word 0x9b72d7ba
    .word 0x4b318ad2
    .word 0x9a6dab59
    .word 0xbb116510
    .word 0xa88997a3
    .word 0x00c9193b
    .word 0x36d6e544
    .word 0x0aa5f8e9
    .word 0x32d1b339
    .word 0xfeb67253
    .word 0xa319bbff
    .word 0x531446e8
    .word 0xa58322e5
    .word 0x1caddf77
    .word 0xac88c6fe
    .word 0x0825b525
    .word 0x855c0a26
    .word 0xb016e583
    .word 0xc087f144
    .word 0xc25a943f
    .word 0xdc0527a5
    .word 0xb4fbd9b8
    .word 0x82dc1661
    .word 0xe377c20a
    .word 0xad4da354
    .word 0x60e0904b
    .word 0xe7c3cbcb
    .word 0x20b61fef
    .word 0xae4f3ab4
    .word 0xf618e826
    .word 0x5ec17181
    .word 0x86072e8a
    .word 0xf3bec836
    .word 0x11c39edb
    .word 0xe7df1c56
    .word 0x6890722b
    .word 0x166d5f07
    .word 0x35fe1cb9
    .word 0xc0e4e56d
    .word 0x7a7d97bf
    .word 0xeecc9905
    .word 0x0f6b6393
    .word 0xa68b1662
    .word 0xf314b6c7
    .word 0x428e914d
    .word 0x3ed859b9
    .word 0x5a7958d1
    .word 0x5d88fabd
    .word 0x021777e0
    .word 0x384f2e2e
    .word 0x30b8ebcc
    .word 0xa6cf65bf
    .word 0xf8088c37
    .word 0x63603cbd
    .word 0x1fbb4c49
    .word 0xf6abc27d
    .word 0x78401a58
    .word 0x807116d5
    .word 0x84bac450
    .word 0x67971008
    .word 0xdc11d950
    .word 0x1fdfe14b
    .word 0x482b89f0
    .word 0xe2418878
    .word 0x98913d3e
    .word 0x6d116458
    .word 0xe6481596
    .word 0xdb88c7bf
    .word 0xbb5fc613
    .word 0x305f7e61
    .word 0xb0206e52
    .word 0x834fb28a
    .word 0x688aecfc
    .word 0x6fe5c967
    .word 0x85bbba50
    .word 0xaa77d412
    .word 0x095f4872
    .word 0x6cfdac14
    .word 0xad0c57c7
    .word 0x557c39fa
    .word 0x3bf40c60
    .word 0x1f6047d6
    .word 0x0ff2e04c
    .word 0x831fc48a
    .word 0x4694e646
    .word 0x009734a6
    .word 0x57623ef4
    .word 0x0cbb2b82
    .word 0x55d03f94
    .word 0xc3b99403
    .word 0x457c5b40
    .word 0x10a86987
    .word 0xe18face0
    .word 0x57567919
    .word 0x95631a93
    .word 0x1b74ece9
    .word 0x638a9ee2
    .word 0xe6e3d045
    .word 0x3eec4867
    .word 0x421eea91
    .word 0xc63527f0
    .word 0x69b9b309
    .word 0x08a0a1a0
    .word 0x305a82f9
    .word 0xe38158ed
    .word 0x37c0652e
    .word 0x118e10b1
    .word 0x5b357686
    .word 0xea9aac45
    .word 0x06d7f2e6
    .word 0x91d72419
    .word 0xe8b18fcd
    .word 0x54f34d79
    .word 0x5a3742fd
    .word 0x31dc1cf0
    .word 0xd31f2a82
    .word 0x3fdf2ff9
    .word 0xbfc2d3d6
    .word 0x5453e87e
    .word 0x41813b92
    .word 0x94e479ea
    .word 0x22aa3aa8
    .word 0x278fc2fc
    .word 0xfe46d41b
    .word 0xb396bd92
    .word 0xa79068f8
    .word 0xd920b3dd
    .word 0x00b28e42
    .word 0x0155922a
    .word 0x3f0de373
    .word 0x299e7aad
    .word 0x909e51f7
    .word 0x85c1b919
    .word 0x77fbb0eb
    .word 0x6da388b1
    .word 0xda916b72
    .word 0xec480d26
    .word 0xfed706d4
    .word 0xd02ba9b2
    .word 0xc3c22d56
    .word 0xb57f0b8d
    .word 0x1745ce13
    .word 0x2edc6e37
    .word 0x157b3a78
    .word 0x9432fed1
    .word 0xa1303446
    .word 0x0576ca87
    .word 0x8f9b64c6
    .word 0x3a85df06
    .word 0x16dd9752
    .word 0xf051df3a
    .word 0x7091577b

#include "frost_footer.S"
