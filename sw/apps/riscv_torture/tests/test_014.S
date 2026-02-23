// Generated RV32IMAFDC torture test for Frost (seed=55)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xf35cb8a9
    li x4, 0xbd47607b
    li x5, 0xd75ba979
    li x6, 0xbf445e19
    li x7, 0x4d4bc856
    li x8, 0xa9a1f92b
    li x9, 0x8a6387ba
    li x10, 0x67de8f74
    li x11, 0xa185d98a
    li x12, 0xa1ecbdec
    li x13, 0xb4aca4b3
    li x14, 0x920258be
    li x15, 0xd6810b83
    li x16, 0x0d6fbdd7
    li x17, 0x3b52a5dd
    li x18, 0xbf3af4a9
    li x19, 0x31f15bdf
    li x20, 0xc3be45ac
    li x21, 0x690ffe25
    li x22, 0x4e3ffa3b
    li x23, 0xd4571b4c
    li x24, 0xef0c9415
    li x25, 0x4f7e8949
    li x26, 0x33fce249
    li x27, 0x77cdf3a2
    li x28, 0xd79f5825
    li x29, 0x3897d542
    li x30, 0x8dd48ad3
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
    li x1, 0x70b283a8

    xori x29, x18, -1172
    andi x4, x29, 87
    sra x7, x5, x22
    xor x18, x18, x5
    sra x10, x15, x20
    sltu x8, x23, x11
    srl x28, x23, x26
    addi x20, x31, 720
    amominu.w x13, x25, (x20)
    mul x14, x25, x24
    sra x19, x15, x11
    srai x24, x30, 15
    ori x17, x21, 1955
    sltiu x11, x8, 1884
    sub x16, x9, x12
    srai x28, x19, 1
    srai x18, x28, 30
    bne x28, x16, _br_taken_0
    and x1, x17, x11
    j _br_done_0
_br_taken_0:
    sub x1, x16, x14
_br_done_0:
    ori x5, x4, -931
    add x5, x27, x20
    bgeu x28, x29, _br_taken_1
    sra x25, x26, x29
    j _br_done_1
_br_taken_1:
    and x25, x4, x30
_br_done_1:
    bgeu x20, x5, _br_taken_2
    slt x16, x26, x10
    j _br_done_2
_br_taken_2:
    add x16, x19, x17
_br_done_2:
    add x29, x16, x19
    srai x11, x7, 8
    fmax.s f17, f4, f25
    fmadd.s f6, f2, f19, f4
    fmadd.d f30, f28, f16, f1
    slt x7, x28, x18
    and x28, x16, x26
    add x5, x21, x22
    fmax.d f18, f13, f25
    fsub.s f21, f30, f22
    fmul.s f30, f21, f6
    bltu x28, x22, _br_taken_3
    and x30, x24, x17
    j _br_done_3
_br_taken_3:
    sra x30, x11, x21
_br_done_3:
    addi x30, x31, 716
    amomax.w x6, x24, (x30)
    beq x26, x22, _br_taken_4
    sll x6, x13, x1
    j _br_done_4
_br_taken_4:
    xor x6, x15, x19
_br_done_4:
    lw x23, 348(x31)
    sw x16, 348(x31)
    blt x29, x29, _br_taken_5
    sub x27, x19, x10
    j _br_done_5
_br_taken_5:
    add x27, x4, x23
_br_done_5:
    slti x4, x13, -365
    slt x9, x14, x18
    lb x19, 672(x31)
    sb x5, 672(x31)
    srai x1, x25, 19
    sra x1, x15, x11
    srli x12, x29, 22
    sll x5, x12, x1
    slt x7, x15, x12
    fsub.s f26, f24, f16
    sra x15, x6, x30
    andi x11, x6, 647
    ori x30, x28, -684
    bgeu x12, x12, _br_taken_6
    and x26, x10, x9
    j _br_done_6
_br_taken_6:
    sra x26, x14, x19
_br_done_6:
    srai x16, x7, 16
    sltu x25, x11, x13
    xori x28, x27, 1728
    sra x15, x29, x27
    ori x5, x24, -273
    sra x17, x24, x18
    lw x22, 100(x31)
    sw x10, 100(x31)
    slli x8, x11, 13
    blt x19, x25, _br_taken_7
    sll x20, x21, x22
    j _br_done_7
_br_taken_7:
    slt x20, x30, x11
_br_done_7:
    bne x27, x15, _br_taken_8
    sra x14, x6, x12
    j _br_done_8
_br_taken_8:
    sltu x14, x8, x10
_br_done_8:
    srai x27, x21, 21
    srai x23, x16, 0
    and x23, x29, x8
    bge x11, x15, _br_taken_9
    sra x13, x9, x23
    j _br_done_9
_br_taken_9:
    or x13, x12, x8
_br_done_9:
    beq x14, x13, _br_taken_10
    and x22, x18, x29
    j _br_done_10
_br_taken_10:
    add x22, x8, x12
_br_done_10:
    srai x5, x20, 24
    and x23, x12, x29
    sltu x9, x7, x10
    or x19, x9, x6
    bge x22, x10, _br_taken_11
    sltu x30, x27, x24
    j _br_done_11
_br_taken_11:
    add x30, x8, x11
_br_done_11:
    slti x27, x17, -1313
    sub x10, x8, x17
    sub x18, x14, x29
    srli x1, x24, 3
    lb x23, 560(x31)
    sb x10, 560(x31)
    sltu x22, x8, x13
    ori x24, x1, 1895
    sll x16, x4, x17
    slli x4, x27, 18
    srai x29, x10, 16
    or x14, x24, x5
    xor x1, x18, x17
    slli x25, x29, 24
    blt x26, x6, _br_taken_12
    or x25, x7, x15
    j _br_done_12
_br_taken_12:
    srl x25, x30, x11
_br_done_12:
    srai x23, x13, 10
    and x12, x13, x6
    srli x26, x19, 12
    sltu x8, x14, x18
    ori x19, x20, 59
    sltu x1, x30, x27
    slti x6, x16, 913
    fmax.s f29, f1, f6
    fadd.s f30, f12, f21
    fmin.s f6, f20, f20
    sltiu x27, x1, -386
    xor x29, x16, x27
    andi x9, x26, 1677
    sltiu x19, x9, -762
    srai x25, x11, 29
    andi x22, x8, -303
    sub x20, x4, x11
    sll x16, x6, x10
    srl x24, x14, x8
    xor x8, x22, x5
    sltiu x12, x29, -363
    lh x26, 664(x31)
    sh x20, 664(x31)
    lbu x9, 448(x31)
    sb x11, 448(x31)
    fadd.s f5, f24, f8
    divu x13, x14, x27
    slli x18, x9, 16
    xori x4, x9, -218
    srl x15, x11, x29
    rem x26, x5, x1
    rem x14, x9, x28
    addi x30, x31, 912
    amomaxu.w x10, x9, (x30)
    bne x11, x16, _br_taken_13
    sltu x6, x11, x21
    j _br_done_13
_br_taken_13:
    slt x6, x4, x27
_br_done_13:
    rem x9, x21, x20
    remu x10, x23, x23
    fmsub.d f7, f11, f26, f31
    fmin.s f27, f14, f29
    fsub.s f21, f8, f3
    xori x19, x4, 1129
    addi x5, x31, 796
    amoswap.w x30, x9, (x5)
    fsub.s f30, f19, f31
    fnmsub.d f30, f17, f23, f4
    fmin.s f23, f11, f30
    andi x25, x7, -1085
    andi x20, x18, 691
    andi x5, x24, 1382
    ori x27, x22, -1278
    srai x4, x9, 30
    slti x18, x20, -1421
    blt x14, x15, _br_taken_14
    xor x29, x8, x19
    j _br_done_14
_br_taken_14:
    sub x29, x12, x24
_br_done_14:
    lb x10, 64(x31)
    sb x11, 64(x31)
    beq x18, x28, _br_taken_15
    srl x26, x17, x6
    j _br_done_15
_br_taken_15:
    sll x26, x1, x4
_br_done_15:
    srai x25, x28, 23
    xor x6, x9, x28
    slti x22, x16, -1475
    srl x28, x11, x24
    sll x26, x14, x7
    slt x18, x13, x7
    andi x30, x17, -2031
    add x9, x6, x4
    srli x1, x15, 15
    xori x6, x18, -1587
    lw x21, 956(x31)
    sw x1, 956(x31)
    addi x28, x31, 440
    amoswap.w x16, x9, (x28)
    sub x14, x7, x12
    sra x8, x18, x24
    sltiu x18, x18, 1050
    ori x9, x27, 1906
    sra x28, x16, x4
    srai x15, x10, 3
    fnmsub.d f19, f19, f25, f25
    fadd.s f15, f3, f6
    fsub.d f25, f0, f20
    lb x7, 256(x31)
    sb x27, 256(x31)
    mulhu x11, x22, x10
    divu x26, x25, x30
    addi x12, x31, 508
    amoadd.w x1, x15, (x12)
    bge x5, x23, _br_taken_16
    slt x18, x18, x26
    j _br_done_16
_br_taken_16:
    xor x18, x29, x25
_br_done_16:
    fdiv.d f4, f12, f31
    xor x22, x22, x26
    srl x29, x17, x21
    srai x6, x8, 0
    xor x14, x11, x1
    srai x13, x21, 18
    slti x28, x12, -140
    slli x13, x11, 25
    sra x4, x22, x28
    and x12, x19, x14
    sra x29, x29, x28
    or x27, x11, x11
    sra x21, x5, x11
    ori x26, x1, -1825
    beq x5, x17, _br_taken_17
    slt x9, x21, x16
    j _br_done_17
_br_taken_17:
    sll x9, x23, x27
_br_done_17:
    fdiv.s f24, f24, f4
    fsub.d f11, f19, f11
    sub x26, x15, x28
    fmax.s f25, f21, f3
    beq x5, x15, _br_taken_18
    sll x24, x4, x28
    j _br_done_18
_br_taken_18:
    add x24, x6, x8
_br_done_18:
    and x7, x13, x11
    sra x7, x9, x1
    slli x14, x19, 28
    and x25, x15, x5
    srli x11, x7, 29
    andi x4, x7, -312
    andi x28, x20, 283
    bltu x24, x12, _br_taken_19
    sll x26, x11, x29
    j _br_done_19
_br_taken_19:
    sra x26, x29, x17
_br_done_19:
    sll x26, x14, x19
    xor x25, x8, x22
    sub x27, x30, x27
    lb x27, 816(x31)
    sb x27, 816(x31)
    beq x10, x21, _br_taken_20
    add x4, x14, x8
    j _br_done_20
_br_taken_20:
    sra x4, x6, x21
_br_done_20:
    and x6, x23, x28
    sll x27, x19, x14
    xori x14, x14, 868
    srai x16, x4, 5
    or x21, x27, x23
    xor x12, x16, x16
    lbu x1, 420(x31)
    sb x28, 420(x31)
    srli x28, x27, 10
    slti x24, x22, -1989
    addi x25, x13, -1763
    and x26, x7, x1
    fnmadd.s f6, f21, f10, f8
    fsub.s f12, f28, f17
    fmax.s f30, f13, f12
    srai x11, x13, 11
    srli x26, x5, 20
    sltu x19, x29, x9
    bge x24, x28, _br_taken_21
    srl x21, x6, x8
    j _br_done_21
_br_taken_21:
    add x21, x26, x17
_br_done_21:
    srli x26, x16, 18
    fsub.s f29, f25, f9
    fadd.d f21, f4, f3
    slli x25, x18, 23
    srai x9, x11, 30
    addi x17, x17, 442
    sltiu x8, x24, 1415
    ori x5, x16, 1660
    sltiu x16, x11, -1306
    div x18, x12, x9
    divu x18, x13, x6
    rem x23, x26, x5
    rem x21, x12, x19
    slt x13, x1, x4
    slli x19, x26, 26
    or x14, x22, x10
    xori x9, x17, -665
    ori x23, x22, 646
    slt x29, x22, x7
    slt x9, x10, x11
    xor x9, x19, x18
    lb x29, 124(x31)
    sb x29, 124(x31)
    sltu x6, x7, x26
    fmin.d f31, f3, f17
    bge x12, x17, _br_taken_22
    xor x10, x16, x19
    j _br_done_22
_br_taken_22:
    sra x10, x15, x26
_br_done_22:
    srli x24, x29, 1
    addi x22, x31, 208
    amoor.w x25, x26, (x22)
    mulh x20, x25, x20
    or x24, x14, x11
    beq x1, x6, _br_taken_23
    xor x27, x21, x28
    j _br_done_23
_br_taken_23:
    and x27, x15, x19
_br_done_23:
    lhu x14, 1004(x31)
    sh x30, 1004(x31)
    add x20, x23, x24
    xor x28, x25, x21
    fdiv.s f18, f24, f11
    fmax.d f29, f29, f20
    bgeu x20, x11, _br_taken_24
    sra x12, x5, x17
    j _br_done_24
_br_taken_24:
    sltu x12, x27, x11
_br_done_24:
    slt x24, x26, x12
    xor x26, x8, x17
    add x26, x10, x12
    bgeu x24, x7, _br_taken_25
    sll x5, x15, x29
    j _br_done_25
_br_taken_25:
    slt x5, x24, x22
_br_done_25:
    lh x20, 856(x31)
    sh x20, 856(x31)
    add x27, x1, x11
    or x22, x22, x23
    sll x1, x16, x24
    addi x5, x23, 1119
    and x16, x4, x12
    addi x22, x8, -1099
    blt x15, x27, _br_taken_26
    sra x25, x9, x19
    j _br_done_26
_br_taken_26:
    or x25, x16, x15
_br_done_26:
    blt x1, x10, _br_taken_27
    srl x10, x24, x26
    j _br_done_27
_br_taken_27:
    srl x10, x9, x9
_br_done_27:
    beq x22, x27, _br_taken_28
    slt x1, x29, x7
    j _br_done_28
_br_taken_28:
    sra x1, x11, x18
_br_done_28:
    fnmsub.s f23, f29, f6, f10
    fnmsub.s f11, f0, f3, f12
    sltu x13, x27, x29
    slt x17, x4, x27
    sra x5, x17, x21
    slti x1, x18, -1440
    srai x6, x11, 7
    sub x21, x15, x10
    slli x10, x7, 10
    bne x11, x12, _br_taken_29
    sll x5, x24, x26
    j _br_done_29
_br_taken_29:
    xor x5, x15, x24
_br_done_29:
    srli x18, x7, 21
    slti x29, x6, 608
    or x26, x16, x15
    xor x16, x30, x23
    sub x29, x20, x22
    fsub.d f8, f26, f17
    fadd.d f24, f4, f2
    fmsub.s f17, f25, f19, f28
    xori x24, x6, 1746
    slli x19, x14, 11
    and x21, x11, x29
    bne x22, x23, _br_taken_30
    slt x5, x17, x7
    j _br_done_30
_br_taken_30:
    sub x5, x30, x4
_br_done_30:
    sltu x13, x20, x24
    sub x24, x18, x9
    ori x4, x27, -111
    lh x10, 256(x31)
    sh x20, 256(x31)
    sltiu x22, x26, -1445
    xor x18, x1, x4
    slli x23, x14, 20
    sltu x17, x6, x23
    xori x4, x12, 1120
    sll x20, x22, x9
    beq x27, x10, _br_taken_31
    srl x9, x10, x1
    j _br_done_31
_br_taken_31:
    and x9, x4, x20
_br_done_31:
    mulhu x7, x17, x18
    mulhu x27, x27, x6
    ori x30, x11, -285
    sll x11, x12, x6
    xori x19, x11, 906
    beq x1, x6, _br_taken_32
    and x14, x17, x4
    j _br_done_32
_br_taken_32:
    slt x14, x30, x12
_br_done_32:
    sra x28, x12, x17
    or x9, x7, x4
    mulh x24, x12, x6
    mulhsu x11, x7, x7
    sub x20, x19, x28
    mul x13, x8, x24
    mulh x19, x28, x8
    ori x19, x25, 1883
    fmul.s f9, f5, f6
    fnmsub.d f29, f25, f28, f26
    sltiu x10, x24, 1797
    bne x29, x19, _br_taken_33
    sll x27, x19, x8
    j _br_done_33
_br_taken_33:
    or x27, x26, x20
_br_done_33:
    bgeu x20, x1, _br_taken_34
    srl x12, x12, x10
    j _br_done_34
_br_taken_34:
    sub x12, x22, x12
_br_done_34:
    divu x8, x25, x13
    mulhsu x20, x18, x9
    bltu x28, x26, _br_taken_35
    srl x22, x7, x29
    j _br_done_35
_br_taken_35:
    sltu x22, x5, x18
_br_done_35:
    divu x30, x11, x21
    fmax.d f24, f17, f24
    fmul.d f15, f1, f29
    addi x19, x31, 304
    amoand.w x16, x1, (x19)
    addi x7, x31, 760
    amomaxu.w x5, x5, (x7)
    andi x10, x8, -1926
    fmin.d f5, f16, f7
    fadd.d f17, f24, f16
    srl x18, x23, x19
    slt x6, x21, x27
    addi x10, x18, 847
    slli x1, x30, 27
    xor x9, x12, x10
    srli x12, x1, 5
    andi x20, x15, -46
    blt x5, x25, _br_taken_36
    or x24, x18, x23
    j _br_done_36
_br_taken_36:
    srl x24, x20, x28
_br_done_36:
    bltu x28, x30, _br_taken_37
    add x29, x21, x14
    j _br_done_37
_br_taken_37:
    add x29, x9, x21
_br_done_37:
    beq x20, x23, _br_taken_38
    slt x22, x28, x27
    j _br_done_38
_br_taken_38:
    and x22, x26, x25
_br_done_38:
    xor x16, x6, x7
    xor x26, x10, x29
    xor x8, x19, x22
    slli x18, x12, 7
    andi x25, x6, -1751
    sltiu x9, x21, 606
    srli x7, x16, 17
    addi x6, x31, 808
    amomax.w x13, x18, (x6)

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x0879444cc7d3bdf1
    .dword 0xc1f17adece1f89c5
    .dword 0x89fe113e56462a89
    .dword 0x74b761df09b6f55b
    .dword 0x5094ce8e572d7804
    .dword 0xed0e015bbe672a10
    .dword 0x1d1317450898c43b
    .dword 0x43ceeefc2f69acda
    .dword 0xbb2212ec8b927d99
    .dword 0x703910c3cf52ff5e
    .dword 0x13bc962082f07e5f
    .dword 0x10887a7242f78fe1
    .dword 0xe08d8e6a3e8c0107
    .dword 0xa65abd456a2a5a7a
    .dword 0xbee3a2acd3eb933d
    .dword 0xac4699ff897088cc
    .dword 0x8544de9956afe7fb
    .dword 0x4b061e20960fb5e6
    .dword 0x8c41c6b27c15b088
    .dword 0x5d64d2b8b72ec399
    .dword 0x9fdc8983ac05b1b1
    .dword 0x79c5cb82ff107b2a
    .dword 0x5fece0caebac6b20
    .dword 0x0ab155c857904fd4
    .dword 0xdf2ba1711bc82b97
    .dword 0xdb79f8498eacf65e
    .dword 0xf08b244cd17226e8
    .dword 0x5914cab5883fd85b
    .dword 0x1aa87135819a4c54
    .dword 0x74b597f97e501292
    .dword 0x7c3a008e45da9162
    .dword 0x99b92796b376d740

    .align 2
_torture_data:
    .word 0xccf7a520
    .word 0x6cacb31f
    .word 0x0809cde1
    .word 0xf4c1aace
    .word 0x56d2a6b8
    .word 0x79dce4c2
    .word 0x2891e346
    .word 0xaecebbf3
    .word 0xeed4925b
    .word 0xc04cb655
    .word 0x34d96b68
    .word 0x63446210
    .word 0xd962ffec
    .word 0xc4784924
    .word 0x032801b1
    .word 0xd7acce10
    .word 0x9bf4a07e
    .word 0x86393d8c
    .word 0xe92efd76
    .word 0xa498fc9b
    .word 0xfd6a93c6
    .word 0x0b851b7e
    .word 0xad746e65
    .word 0x1891bdf9
    .word 0xeef2af60
    .word 0x156600c9
    .word 0x8f5af48a
    .word 0x66431df2
    .word 0x873101b0
    .word 0xf8086686
    .word 0x0e0a8bb5
    .word 0xa83a5dd2
    .word 0xf5394bde
    .word 0xecdb32c4
    .word 0xeb54cdc6
    .word 0xc3b737ba
    .word 0xd69fcb4a
    .word 0xc4af36c7
    .word 0x94c4a93b
    .word 0x4e6cb19e
    .word 0x17adca42
    .word 0x43d894a5
    .word 0x52c4b683
    .word 0xe2200eb9
    .word 0x8a889812
    .word 0x49d04f47
    .word 0x3ec75bb1
    .word 0xc8ca8571
    .word 0xb522fbe4
    .word 0x226afb35
    .word 0xa1c25af2
    .word 0x91c3182a
    .word 0x601e3084
    .word 0x3ee85f3d
    .word 0xed16f69d
    .word 0x3dd79053
    .word 0xdfc7523e
    .word 0x62eaf3ef
    .word 0xd3cf7584
    .word 0x481204a4
    .word 0xbf45afa6
    .word 0x98817c85
    .word 0x6367f2ce
    .word 0x22660226
    .word 0xc81938d5
    .word 0x39750080
    .word 0x59f6b8d5
    .word 0x424b2371
    .word 0x96632c4f
    .word 0x0359be61
    .word 0x9d4994e4
    .word 0x98c898f7
    .word 0x82c72959
    .word 0x631d7778
    .word 0x2422de94
    .word 0x2904c70c
    .word 0x6e7fe1dc
    .word 0x17745b29
    .word 0xc743badd
    .word 0x936aa1dc
    .word 0x037aad5c
    .word 0x8286384d
    .word 0x9bb13257
    .word 0x25fa8b88
    .word 0xabfd2846
    .word 0x0d872926
    .word 0x28e92b73
    .word 0x8c205f34
    .word 0x7473a8c2
    .word 0x7c4b6797
    .word 0xb1ef13bc
    .word 0xf05b9ed8
    .word 0xc8e8eab0
    .word 0x25c2a400
    .word 0x1468732c
    .word 0xc953549d
    .word 0xff8bf80b
    .word 0x943401e1
    .word 0xf9528a7a
    .word 0xd51a273c
    .word 0x751d5966
    .word 0x1cb60543
    .word 0xc48ee5d5
    .word 0x13cc5a60
    .word 0x05f87e02
    .word 0x2873ea31
    .word 0x6a7e65f3
    .word 0xe9d9f028
    .word 0x85aaddf1
    .word 0x181bd16d
    .word 0xae6d1d73
    .word 0x7782cce2
    .word 0xc69275ea
    .word 0x7b05d308
    .word 0x3e578c43
    .word 0x30219544
    .word 0x1cde73bc
    .word 0x4335ec62
    .word 0x46e72978
    .word 0x413f18a6
    .word 0xc8346ba0
    .word 0xe0a3d3cb
    .word 0x9b1319a5
    .word 0x6302e490
    .word 0xb622a185
    .word 0x86df2d59
    .word 0xb2689e3e
    .word 0x7b6b649f
    .word 0x43d8d3e2
    .word 0x34f23c33
    .word 0x2268c47e
    .word 0x48d3c39b
    .word 0x765f0bd4
    .word 0xbb9dea59
    .word 0x3bc701aa
    .word 0x27ef79f5
    .word 0x9abb852f
    .word 0xce862ab8
    .word 0xe630482a
    .word 0x070ec3c7
    .word 0x086b71cf
    .word 0x508393ab
    .word 0x13cbf6d6
    .word 0xcd622b3d
    .word 0xa874c569
    .word 0x4eec0466
    .word 0xc23fcfc5
    .word 0xc068c127
    .word 0x481fc4e7
    .word 0x4d326899
    .word 0x3ed54355
    .word 0x6fe72351
    .word 0x8a943fdc
    .word 0xc074cb68
    .word 0x615bfbd5
    .word 0x5af9c4e3
    .word 0x68e26b29
    .word 0x3006484f
    .word 0x270895f0
    .word 0xec92887b
    .word 0x2a603e89
    .word 0x85ec7362
    .word 0x9787ccf5
    .word 0x67bbb9cb
    .word 0x820bf4bb
    .word 0x8e7d59a0
    .word 0x10ce07c8
    .word 0x8f4711ec
    .word 0xace8faca
    .word 0x7e3248f1
    .word 0xbf14e1f3
    .word 0xf04ebbdc
    .word 0x97729dfe
    .word 0x63726c6c
    .word 0x48aee7a2
    .word 0xe26554bd
    .word 0x92771cb3
    .word 0x35818cce
    .word 0x66d2e9fc
    .word 0x944c8a3d
    .word 0xd14209cd
    .word 0xcb002141
    .word 0xc8b31e88
    .word 0x2ec571bd
    .word 0x8adf8d28
    .word 0xa05fdf65
    .word 0x9fd0e94b
    .word 0x87fdf808
    .word 0xcb81709d
    .word 0x931c3f37
    .word 0x79b408f9
    .word 0x5c2f4568
    .word 0x13e2f23c
    .word 0xf71fc6c4
    .word 0x8945ea82
    .word 0x43e533e2
    .word 0x28917e4d
    .word 0x806e3106
    .word 0x425555a3
    .word 0xb089a21e
    .word 0x260fecff
    .word 0xca132e74
    .word 0xd7ca1459
    .word 0xfc6f78d1
    .word 0x284fbf54
    .word 0x226fa87b
    .word 0x00206ceb
    .word 0x6e4409c1
    .word 0xa61821a2
    .word 0x44ddf709
    .word 0x3d5e5008
    .word 0xceb62691
    .word 0xf1fafcbf
    .word 0x38847298
    .word 0xa30958b8
    .word 0x6e7ab4f4
    .word 0xb1454791
    .word 0x22bdabd4
    .word 0x1412b183
    .word 0xd0690e40
    .word 0xdb3ffcf6
    .word 0xf992fae2
    .word 0xa2b82233
    .word 0x53deb994
    .word 0x568571c1
    .word 0xf38abd3a
    .word 0x16f2f233
    .word 0x389499fb
    .word 0x95d6d7d8
    .word 0x2d6bb23c
    .word 0x6a6107ab
    .word 0x7693ffcf
    .word 0x49b101e6
    .word 0x1461576c
    .word 0x61822149
    .word 0x35c8d32b
    .word 0x65e171fa
    .word 0x797fa64b
    .word 0x2dd94946
    .word 0xc604bb65
    .word 0x42485bce
    .word 0x5e250fd2
    .word 0x63dfa915
    .word 0xf09b7602
    .word 0xc7cd6fc4
    .word 0xe9a54d77
    .word 0xb04d7644
    .word 0x2656963b
    .word 0xe9dcc27d
    .word 0x412331d1
    .word 0x673702ea
    .word 0x98951d2d
    .word 0xd74c2a50
    .word 0xb4c34803
    .word 0x43c7ed26
    .word 0x0c7764ec

#include "frost_footer.S"
