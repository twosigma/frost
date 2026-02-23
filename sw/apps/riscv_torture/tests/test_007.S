// Generated RV32IMAFDC torture test for Frost (seed=48)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x8c541241
    li x4, 0xc3117314
    li x5, 0x2a677c0b
    li x6, 0x1b8666f7
    li x7, 0xa6399a75
    li x8, 0x27a88c33
    li x9, 0x37942916
    li x10, 0x12c4ff1d
    li x11, 0x1041dfb6
    li x12, 0x20fb877b
    li x13, 0x5676dc9c
    li x14, 0xd7748e5e
    li x15, 0x459c3ae4
    li x16, 0xa5e70e1e
    li x17, 0x23600926
    li x18, 0xa71d5d7a
    li x19, 0x2cf53508
    li x20, 0x46fa25c8
    li x21, 0x5dc8ff95
    li x22, 0x1d77445a
    li x23, 0x54789acc
    li x24, 0x6e2dbcc0
    li x25, 0xc6180d89
    li x26, 0xc815bf93
    li x27, 0x6c1c1d62
    li x28, 0xe2ed5448
    li x29, 0x67cce8a5
    li x30, 0x423d8963
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
    li x1, 0xc423ed11

    srai x29, x23, 10
    sll x11, x29, x23
    xori x21, x19, 1161
    lh x17, 24(x31)
    sh x19, 24(x31)
    beq x1, x26, _br_taken_0
    and x1, x14, x5
    j _br_done_0
_br_taken_0:
    sltu x1, x17, x19
_br_done_0:
    fmin.d f5, f30, f10
    fmax.d f12, f15, f22
    sra x22, x1, x26
    or x24, x16, x5
    slti x13, x30, -1028
    beq x9, x30, _br_taken_1
    srl x7, x21, x6
    j _br_done_1
_br_taken_1:
    sll x7, x10, x11
_br_done_1:
    xori x27, x4, -1453
    lb x15, 176(x31)
    sb x29, 176(x31)
    bgeu x22, x7, _br_taken_2
    sub x29, x7, x29
    j _br_done_2
_br_taken_2:
    sub x29, x6, x27
_br_done_2:
    and x17, x15, x24
    sra x18, x9, x7
    xor x16, x10, x21
    or x6, x13, x30
    divu x20, x26, x22
    sll x19, x27, x20
    add x4, x17, x7
    ori x6, x4, -197
    srai x15, x6, 2
    slli x6, x24, 19
    slt x30, x10, x16
    and x24, x5, x21
    fmul.d f26, f25, f21
    fsub.d f10, f31, f5
    bgeu x22, x8, _br_taken_3
    sra x30, x16, x29
    j _br_done_3
_br_taken_3:
    sub x30, x10, x28
_br_done_3:
    slt x28, x11, x17
    or x6, x12, x22
    addi x28, x31, 720
    amoadd.w x15, x29, (x28)
    ori x30, x24, -582
    xori x30, x5, -1561
    mulh x26, x29, x13
    sra x12, x16, x8
    sll x13, x13, x18
    add x22, x10, x20
    bge x13, x20, _br_taken_4
    sltu x25, x30, x22
    j _br_done_4
_br_taken_4:
    sra x25, x25, x16
_br_done_4:
    blt x8, x20, _br_taken_5
    xor x4, x16, x29
    j _br_done_5
_br_taken_5:
    sltu x4, x24, x10
_br_done_5:
    fmul.d f14, f13, f1
    xor x22, x26, x25
    and x5, x8, x8
    beq x21, x1, _br_taken_6
    and x29, x6, x22
    j _br_done_6
_br_taken_6:
    srl x29, x18, x27
_br_done_6:
    xor x19, x9, x17
    slli x13, x18, 26
    fnmsub.s f9, f20, f30, f0
    fmsub.d f7, f16, f29, f5
    fsub.s f15, f17, f17
    fmin.s f22, f8, f28
    fadd.d f7, f5, f23
    addi x8, x5, 264
    xori x8, x30, -2024
    srli x4, x1, 15
    fmsub.s f7, f1, f27, f8
    fmin.s f23, f12, f25
    fmax.s f6, f7, f5
    fmax.s f7, f18, f19
    fsub.s f25, f19, f22
    srli x19, x28, 25
    srl x11, x9, x12
    fmax.s f17, f25, f23
    fadd.s f29, f21, f29
    fsub.d f25, f24, f9
    sltiu x15, x29, 805
    slli x24, x7, 6
    addi x12, x10, 1141
    fmadd.s f14, f3, f25, f19
    xor x20, x6, x20
    xor x26, x27, x26
    lhu x12, 800(x31)
    sh x26, 800(x31)
    addi x29, x31, 312
    amoor.w x22, x7, (x29)
    blt x28, x11, _br_taken_7
    or x21, x17, x14
    j _br_done_7
_br_taken_7:
    sra x21, x1, x4
_br_done_7:
    xori x15, x18, 1930
    slti x17, x22, 1970
    or x25, x5, x5
    srli x23, x10, 13
    fmul.d f30, f18, f30
    addi x30, x31, 352
    amoand.w x27, x10, (x30)
    slti x8, x5, -94
    slti x16, x7, -704
    srli x20, x22, 21
    slti x4, x7, 1966
    bltu x11, x11, _br_taken_8
    sltu x21, x4, x16
    j _br_done_8
_br_taken_8:
    sub x21, x27, x17
_br_done_8:
    bne x11, x16, _br_taken_9
    and x30, x8, x14
    j _br_done_9
_br_taken_9:
    srl x30, x22, x21
_br_done_9:
    bne x23, x5, _br_taken_10
    add x10, x5, x28
    j _br_done_10
_br_taken_10:
    add x10, x16, x22
_br_done_10:
    and x27, x23, x13
    slti x29, x15, 273
    slli x8, x18, 19
    sll x13, x19, x7
    bgeu x19, x19, _br_taken_11
    xor x25, x10, x12
    j _br_done_11
_br_taken_11:
    sub x25, x28, x7
_br_done_11:
    xor x27, x10, x14
    sltiu x7, x12, -1154
    sll x6, x26, x9
    mulhu x12, x21, x22
    remu x28, x7, x28
    lw x6, 176(x31)
    sw x5, 176(x31)
    xori x9, x9, 1543
    sltu x9, x10, x18
    andi x23, x14, -1652
    lh x15, 392(x31)
    sh x19, 392(x31)
    addi x28, x31, 880
    amominu.w x4, x21, (x28)
    lw x28, 740(x31)
    sw x27, 740(x31)
    slt x20, x21, x28
    lbu x29, 464(x31)
    sb x27, 464(x31)
    add x29, x20, x4
    and x4, x5, x27
    fadd.d f4, f29, f14
    fmax.d f11, f3, f6
    lw x6, 820(x31)
    sw x17, 820(x31)
    xor x19, x30, x23
    sltiu x16, x23, -311
    sll x1, x6, x5
    bgeu x4, x7, _br_taken_12
    slt x1, x5, x14
    j _br_done_12
_br_taken_12:
    srl x1, x1, x21
_br_done_12:
    sub x9, x10, x17
    ori x25, x17, -805
    andi x23, x20, -588
    bgeu x27, x16, _br_taken_13
    xor x21, x27, x24
    j _br_done_13
_br_taken_13:
    slt x21, x28, x13
_br_done_13:
    fmul.s f7, f3, f14
    sll x20, x15, x23
    andi x21, x11, 1100
    slli x27, x4, 29
    bgeu x27, x20, _br_taken_14
    or x27, x11, x9
    j _br_done_14
_br_taken_14:
    xor x27, x9, x14
_br_done_14:
    addi x4, x29, 1252
    addi x21, x31, 856
    amoxor.w x10, x7, (x21)
    sltu x9, x29, x26
    bne x16, x8, _br_taken_15
    sll x17, x22, x4
    j _br_done_15
_br_taken_15:
    sltu x17, x22, x11
_br_done_15:
    add x14, x8, x22
    sltiu x20, x21, -900
    slt x7, x13, x14
    and x29, x13, x1
    blt x29, x7, _br_taken_16
    slt x6, x23, x14
    j _br_done_16
_br_taken_16:
    sll x6, x4, x26
_br_done_16:
    addi x24, x31, 588
    amoswap.w x21, x26, (x24)
    bge x1, x18, _br_taken_17
    sub x13, x18, x13
    j _br_done_17
_br_taken_17:
    add x13, x28, x12
_br_done_17:
    lhu x14, 984(x31)
    sh x14, 984(x31)
    bltu x14, x16, _br_taken_18
    add x14, x22, x22
    j _br_done_18
_br_taken_18:
    slt x14, x17, x23
_br_done_18:
    fdiv.s f0, f14, f16
    beq x4, x10, _br_taken_19
    sra x24, x4, x26
    j _br_done_19
_br_taken_19:
    sub x24, x11, x6
_br_done_19:
    lw x10, 328(x31)
    sw x8, 328(x31)
    lhu x11, 28(x31)
    sh x27, 28(x31)
    fmul.s f5, f1, f28
    fnmadd.d f11, f27, f24, f21
    lh x14, 980(x31)
    sh x25, 980(x31)
    or x22, x8, x17
    slti x30, x30, -446
    or x18, x24, x6
    srai x28, x18, 17
    xor x7, x8, x5
    srli x8, x12, 2
    srli x26, x29, 6
    andi x25, x13, 526
    xor x20, x12, x8
    mulhu x5, x15, x30
    srai x17, x26, 10
    lbu x10, 44(x31)
    sb x5, 44(x31)
    sra x29, x8, x16
    sub x23, x12, x7
    lh x18, 288(x31)
    sh x12, 288(x31)
    blt x6, x18, _br_taken_20
    xor x21, x22, x22
    j _br_done_20
_br_taken_20:
    xor x21, x9, x22
_br_done_20:
    bltu x30, x24, _br_taken_21
    sltu x29, x11, x10
    j _br_done_21
_br_taken_21:
    slt x29, x18, x5
_br_done_21:
    sub x21, x14, x30
    andi x6, x22, 338
    or x4, x7, x7
    srli x30, x10, 21
    and x11, x21, x21
    sltu x7, x10, x18
    beq x24, x8, _br_taken_22
    xor x21, x6, x21
    j _br_done_22
_br_taken_22:
    slt x21, x13, x8
_br_done_22:
    fdiv.d f19, f22, f4
    fsub.s f6, f8, f2
    fmax.s f23, f19, f19
    fdiv.d f11, f29, f17
    fdiv.s f30, f3, f22
    slti x14, x17, 780
    bltu x17, x22, _br_taken_23
    add x24, x21, x6
    j _br_done_23
_br_taken_23:
    slt x24, x8, x14
_br_done_23:
    ori x1, x21, -1895
    sltiu x1, x14, 1010
    srl x18, x17, x6
    andi x12, x18, -975
    slti x1, x13, 1507
    add x23, x28, x14
    sltu x29, x28, x29
    mulhsu x24, x13, x8
    mulhu x26, x8, x16
    ori x17, x4, -437
    fmin.d f6, f14, f10
    fsub.s f5, f5, f19
    sll x28, x27, x26
    srl x8, x13, x30
    xor x6, x16, x6
    bgeu x9, x17, _br_taken_24
    sra x12, x1, x27
    j _br_done_24
_br_taken_24:
    sll x12, x13, x11
_br_done_24:
    fmax.d f26, f21, f28
    fadd.s f29, f28, f2
    addi x17, x30, 480
    xor x25, x22, x7
    slli x18, x13, 20
    addi x15, x31, 184
    amoor.w x11, x9, (x15)
    fmul.s f15, f30, f1
    lbu x11, 852(x31)
    sb x24, 852(x31)
    mulhsu x12, x15, x24
    lbu x5, 16(x31)
    sb x27, 16(x31)
    and x21, x25, x20
    sub x16, x18, x25
    add x10, x25, x30
    bltu x18, x27, _br_taken_25
    srl x19, x12, x25
    j _br_done_25
_br_taken_25:
    sub x19, x24, x11
_br_done_25:
    srli x30, x20, 22
    add x24, x8, x15
    bltu x4, x5, _br_taken_26
    sll x25, x6, x25
    j _br_done_26
_br_taken_26:
    slt x25, x4, x30
_br_done_26:
    sltiu x13, x1, 1250
    srli x10, x29, 12
    lhu x16, 640(x31)
    sh x29, 640(x31)
    fmul.d f31, f31, f3
    fmax.s f13, f21, f15
    fadd.s f21, f15, f25
    remu x1, x16, x1
    bgeu x12, x9, _br_taken_27
    add x16, x25, x15
    j _br_done_27
_br_taken_27:
    xor x16, x30, x24
_br_done_27:
    bgeu x10, x1, _br_taken_28
    sub x25, x15, x12
    j _br_done_28
_br_taken_28:
    xor x25, x30, x14
_br_done_28:
    bltu x8, x6, _br_taken_29
    and x29, x22, x1
    j _br_done_29
_br_taken_29:
    add x29, x23, x11
_br_done_29:
    slt x21, x21, x29
    srai x12, x13, 15
    remu x23, x8, x30
    mulhsu x18, x29, x9
    xor x24, x8, x20
    add x30, x13, x12
    and x17, x26, x24
    slli x19, x7, 3
    sll x13, x4, x13
    addi x8, x13, -1319
    srai x11, x30, 16
    addi x22, x31, 876
    amoswap.w x30, x12, (x22)
    lw x14, 1016(x31)
    sw x28, 1016(x31)
    bne x7, x1, _br_taken_30
    srl x20, x4, x23
    j _br_done_30
_br_taken_30:
    or x20, x18, x22
_br_done_30:
    xori x24, x23, -760
    andi x23, x17, 432
    sub x12, x25, x10
    addi x22, x9, 295
    or x4, x25, x4
    bge x29, x6, _br_taken_31
    sll x30, x21, x25
    j _br_done_31
_br_taken_31:
    add x30, x12, x15
_br_done_31:
    mulhu x1, x10, x28
    srai x12, x10, 15
    fnmadd.d f4, f29, f15, f16
    fmsub.s f17, f8, f23, f12
    fadd.s f22, f28, f2
    lhu x9, 164(x31)
    sh x4, 164(x31)
    and x16, x25, x20
    sltiu x6, x30, -1826
    addi x21, x31, 248
    amominu.w x28, x10, (x21)
    bgeu x7, x16, _br_taken_32
    srl x18, x7, x29
    j _br_done_32
_br_taken_32:
    xor x18, x30, x25
_br_done_32:
    bge x30, x9, _br_taken_33
    xor x25, x30, x21
    j _br_done_33
_br_taken_33:
    add x25, x21, x25
_br_done_33:
    xor x17, x1, x20
    add x24, x13, x16
    srai x12, x27, 18
    sub x26, x28, x22
    slli x30, x1, 16
    fmax.s f6, f10, f29
    or x9, x14, x9
    bge x25, x15, _br_taken_34
    srl x9, x12, x9
    j _br_done_34
_br_taken_34:
    or x9, x9, x1
_br_done_34:
    fsub.s f15, f23, f17
    fmin.s f22, f23, f22
    fmax.d f26, f20, f28
    and x22, x11, x23
    xor x27, x10, x5
    or x17, x7, x11
    bltu x21, x21, _br_taken_35
    and x8, x7, x10
    j _br_done_35
_br_taken_35:
    sra x8, x4, x8
_br_done_35:
    lb x20, 108(x31)
    sb x26, 108(x31)
    and x27, x8, x17
    srli x20, x17, 5
    lhu x13, 964(x31)
    sh x1, 964(x31)
    lbu x24, 408(x31)
    sb x13, 408(x31)
    fadd.d f19, f19, f26
    fmin.d f14, f14, f3
    fmul.s f9, f2, f29
    fmsub.s f16, f22, f19, f27
    fmax.d f12, f27, f5
    bltu x30, x5, _br_taken_36
    srl x20, x17, x22
    j _br_done_36
_br_taken_36:
    srl x20, x19, x18
_br_done_36:
    blt x11, x7, _br_taken_37
    or x25, x15, x25
    j _br_done_37
_br_taken_37:
    sltu x25, x24, x27
_br_done_37:
    beq x27, x28, _br_taken_38
    sll x14, x13, x30
    j _br_done_38
_br_taken_38:
    slt x14, x7, x1
_br_done_38:
    fmax.d f14, f8, f2
    fmax.s f10, f28, f0
    fdiv.s f29, f25, f5
    fadd.d f23, f17, f18
    fmax.s f9, f6, f23
    beq x21, x7, _br_taken_39
    or x18, x28, x27
    j _br_done_39
_br_taken_39:
    add x18, x19, x17
_br_done_39:
    srli x21, x26, 10
    blt x19, x19, _br_taken_40
    or x21, x22, x14
    j _br_done_40
_br_taken_40:
    and x21, x8, x1
_br_done_40:
    srl x21, x18, x15
    xor x6, x13, x1
    ori x22, x23, -1565
    sltiu x16, x22, -1816
    slt x24, x26, x26
    fmax.s f2, f24, f10
    fmax.d f11, f5, f12
    fdiv.s f10, f23, f31
    fsub.s f1, f11, f18
    addi x28, x31, 360
    amoand.w x1, x10, (x28)
    srli x24, x7, 28
    sll x28, x9, x26
    bge x26, x13, _br_taken_41
    xor x24, x21, x18
    j _br_done_41
_br_taken_41:
    sra x24, x18, x7
_br_done_41:
    lh x25, 1016(x31)
    sh x24, 1016(x31)
    srai x24, x24, 4
    slt x22, x21, x16
    ori x7, x6, 224
    fsub.s f26, f4, f3
    fsub.d f31, f22, f18
    lb x18, 280(x31)
    sb x24, 280(x31)
    slt x21, x17, x21
    xor x9, x11, x10
    addi x21, x11, 1088
    srli x30, x25, 15
    sltu x23, x13, x29
    bge x19, x20, _br_taken_42
    sltu x29, x12, x4
    j _br_done_42
_br_taken_42:
    and x29, x28, x20
_br_done_42:
    lhu x24, 560(x31)
    sh x17, 560(x31)
    slt x4, x13, x18
    slli x8, x25, 23
    sltiu x6, x24, -1711
    slt x7, x24, x4

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xda8d363c878ac3f8
    .dword 0x0b78c533f7461db8
    .dword 0xfb280a0c8e4bdd62
    .dword 0x259cb9408891a9f2
    .dword 0x4ef3483a1dfe2bb3
    .dword 0xb067e7888a99a8b0
    .dword 0xf8d0bf9bc9c15c10
    .dword 0x79eaeb94ee9466aa
    .dword 0x2baffde56b631c84
    .dword 0xa021f2c71fc2d855
    .dword 0x72492d1f2c5ed50d
    .dword 0x22a2701fcf7723c5
    .dword 0x5f9d4f90233c94e4
    .dword 0x4ee01ad1ed6f32a0
    .dword 0x7f03b8670db3e109
    .dword 0xf39baa35122e7da4
    .dword 0xe12a9c2153a4fe73
    .dword 0x4b88592b3186fae8
    .dword 0xb778bedb40cf108a
    .dword 0x5646adf5254cb496
    .dword 0xd2d96827362b6dd3
    .dword 0x793719146bffdc53
    .dword 0xa24f0ea7cc700f69
    .dword 0x6c77cabd9f92984a
    .dword 0x7efa338d0268417c
    .dword 0x3686e140ae19bf18
    .dword 0x965333bcaadbdd44
    .dword 0x482b6e6c675d09fd
    .dword 0x916513b4cba2864c
    .dword 0xcef608be2c0af3e3
    .dword 0xa67363333e204e23
    .dword 0xc545c69a39780484

    .align 2
_torture_data:
    .word 0xd1ad3b28
    .word 0x0249c1e7
    .word 0x00ba6334
    .word 0x430857af
    .word 0xe45525ae
    .word 0x678c6005
    .word 0x251d0f47
    .word 0x95fea863
    .word 0xf87acbe9
    .word 0x7a12ccfe
    .word 0x4c3620b9
    .word 0x2e31f9f7
    .word 0x14e68d17
    .word 0xd2bc97c4
    .word 0x35a3341f
    .word 0x18726b06
    .word 0xb3b0da6a
    .word 0xfe5da250
    .word 0x4d26df7b
    .word 0x93af2783
    .word 0x51ea5dcb
    .word 0xe944b9be
    .word 0xa7269b3e
    .word 0xd5a00ca8
    .word 0x99aa0b5c
    .word 0x4b648534
    .word 0xf4f9f49e
    .word 0xc6b808e1
    .word 0xc6bbc6a4
    .word 0xc29bedff
    .word 0x395299f3
    .word 0xa4afa0ad
    .word 0xffaba70e
    .word 0x5ccd174c
    .word 0x4242e72d
    .word 0x3f3ab890
    .word 0x072345e9
    .word 0xb28497a4
    .word 0xce8c0eee
    .word 0x2a23a1c8
    .word 0xc1f1dbe3
    .word 0xb0a01492
    .word 0xe3ccdb64
    .word 0xb60e5194
    .word 0x4f10765b
    .word 0x79b1981c
    .word 0x7bdb9389
    .word 0xb2b946c5
    .word 0x417f0e24
    .word 0xcf86e95b
    .word 0xed865ea8
    .word 0x3e9ef3f1
    .word 0xfcd011f0
    .word 0x4b3b0f82
    .word 0x5fd77dae
    .word 0x45af6e88
    .word 0xdb37318f
    .word 0xa365b93b
    .word 0x23f55471
    .word 0xf40f64ba
    .word 0x60f42b1f
    .word 0xf52fa195
    .word 0x9a864b3b
    .word 0xc347bbc9
    .word 0xa2548517
    .word 0x5ef02891
    .word 0xdfaf2de9
    .word 0x7295aea9
    .word 0x980c4ebe
    .word 0x08da7ee2
    .word 0xbccf18c3
    .word 0x61a2f418
    .word 0xf23cdc51
    .word 0xfa5cdc58
    .word 0xbb938e99
    .word 0xfdf3a89e
    .word 0x5b92786c
    .word 0x2656964c
    .word 0xb0a53a56
    .word 0x91e8694d
    .word 0x9767856a
    .word 0x43344901
    .word 0x586541e2
    .word 0xe7c6c8aa
    .word 0x0f2eefb3
    .word 0xaf78ef1a
    .word 0x1b6ee1a7
    .word 0x372e4c53
    .word 0x6bff3c13
    .word 0x70e7b158
    .word 0x3d9bd9bd
    .word 0xa452ac83
    .word 0xafaeda83
    .word 0x1973fa74
    .word 0xcfed7bb2
    .word 0xb465607a
    .word 0xb8cd0d09
    .word 0x229838b6
    .word 0xdc9a2fe7
    .word 0x41a137b3
    .word 0xd975e028
    .word 0x22958765
    .word 0x090c4792
    .word 0x05ffac21
    .word 0xc628c41e
    .word 0xb3004be4
    .word 0x1b69c032
    .word 0xc039278a
    .word 0x06397d87
    .word 0xd9a5963d
    .word 0x83600b34
    .word 0x4648fef0
    .word 0x4e7a8fe6
    .word 0x07ab3d93
    .word 0xa3a8e2b7
    .word 0xc0c7a07c
    .word 0x74a9aeda
    .word 0xefa33620
    .word 0x321b44d1
    .word 0x78ef3f0c
    .word 0x98d1352f
    .word 0xa3c100c9
    .word 0x6049880a
    .word 0x71cebfe4
    .word 0x9d2e2c38
    .word 0x7a8966ce
    .word 0x6ace11d3
    .word 0x3520f762
    .word 0xa4fd4724
    .word 0xacde529a
    .word 0x7d26af2d
    .word 0x749838de
    .word 0x3b1996fd
    .word 0x619c5df7
    .word 0x24a03b6d
    .word 0x65d756ac
    .word 0x98809e53
    .word 0xfd039fd9
    .word 0x968b413b
    .word 0x09347aa5
    .word 0xfceb30dc
    .word 0x2718d475
    .word 0x29a1e95d
    .word 0xdcbb719d
    .word 0xf38f43fb
    .word 0x199f4932
    .word 0x1dc16ad1
    .word 0x470a61d4
    .word 0xebaedcd9
    .word 0x3ac6ec2f
    .word 0x309ad45a
    .word 0xe5856c2c
    .word 0x549e5b52
    .word 0x033bec08
    .word 0x5b3dad64
    .word 0xb5de1195
    .word 0x1b58115a
    .word 0x2cac3f81
    .word 0x0c43e0fc
    .word 0xdb27be31
    .word 0x8dec5eb8
    .word 0xe9197077
    .word 0x653382bf
    .word 0xbdd10a92
    .word 0x442947be
    .word 0x985e8fd3
    .word 0x83a9d9d8
    .word 0xa1b24b09
    .word 0xc834677e
    .word 0x9b0ad223
    .word 0x69370f91
    .word 0xde5551cc
    .word 0xb2c29ce2
    .word 0x105ea171
    .word 0x251af084
    .word 0x3b5e77ef
    .word 0x7d71f782
    .word 0x25794857
    .word 0x166c3559
    .word 0x691d7a0c
    .word 0x054542ed
    .word 0x403bc7aa
    .word 0x4f99c654
    .word 0x701221b1
    .word 0x935e279e
    .word 0xaf033a64
    .word 0x04c762f2
    .word 0xe95b5609
    .word 0x16d74453
    .word 0xcbc335cf
    .word 0xee530d05
    .word 0xeb6f22a6
    .word 0x4b149ce9
    .word 0x46346639
    .word 0x33b6851e
    .word 0x3d202a3a
    .word 0xfa330b67
    .word 0x3b1e8075
    .word 0xdda0609a
    .word 0x3d4a2ebd
    .word 0xf0b4bb26
    .word 0xc86efab7
    .word 0xf547311a
    .word 0xa4978dc6
    .word 0xcb726b04
    .word 0xc8f837de
    .word 0x50903482
    .word 0x434ce671
    .word 0x6e0a3546
    .word 0xf408235b
    .word 0x4b191660
    .word 0xfa0a3540
    .word 0x5153561d
    .word 0x8ae77e5a
    .word 0xd98dd37c
    .word 0xe7b58f87
    .word 0x3827851d
    .word 0x007168a0
    .word 0xd01474b5
    .word 0x6cf2f084
    .word 0x261cc757
    .word 0x3e15e00a
    .word 0x3f0e3ea9
    .word 0x2c9a6065
    .word 0xbcbfd8e8
    .word 0x053dcae4
    .word 0x80efa9a5
    .word 0x0e3db863
    .word 0x288fedb2
    .word 0x3d63a633
    .word 0x7c451fe2
    .word 0xf1038007
    .word 0x14639c7b
    .word 0x213a67f9
    .word 0xbbb5532a
    .word 0x14be5d1d
    .word 0xc6adce3f
    .word 0xb20bf2bb
    .word 0xd9c10e90
    .word 0x5f6d3d34
    .word 0x4e2dabcf
    .word 0x3e74292c
    .word 0x6380bb33
    .word 0x2148dcac
    .word 0x28ab3b85
    .word 0xc4f6e635
    .word 0x3911111f
    .word 0x585073b8
    .word 0x4dc0192e
    .word 0x748fffbd
    .word 0x9de971e3
    .word 0xdbb4b6ca
    .word 0x4bebd5f5
    .word 0xb9d27e30
    .word 0x5b1e1554
    .word 0xd2b22f44

#include "frost_footer.S"
