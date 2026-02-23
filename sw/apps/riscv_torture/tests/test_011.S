// Generated RV32IMAFDC torture test for Frost (seed=52)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xfa7576c5
    li x4, 0xf114c653
    li x5, 0x68279da5
    li x6, 0xeb53825f
    li x7, 0x5899f364
    li x8, 0xa17bd6ac
    li x9, 0x631e7da6
    li x10, 0x02d7a7da
    li x11, 0x11c2214e
    li x12, 0x2b9862d7
    li x13, 0x463ca801
    li x14, 0xc73434d0
    li x15, 0x6a7f0748
    li x16, 0xdb810d0c
    li x17, 0xe52c69bf
    li x18, 0xf29ae758
    li x19, 0x936bf8f4
    li x20, 0xe1aa46f2
    li x21, 0x8b303638
    li x22, 0x246cdcf5
    li x23, 0x2dfd948d
    li x24, 0x17bbef0c
    li x25, 0xb288e39f
    li x26, 0x0748d9bb
    li x27, 0x0118db4b
    li x28, 0x8795220e
    li x29, 0x74e95b1c
    li x30, 0x2e15db35
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
    li x1, 0x9972acd0

    slli x20, x8, 13
    srl x29, x21, x17
    srli x28, x10, 24
    lb x5, 412(x31)
    sb x24, 412(x31)
    ori x11, x5, 1276
    slt x7, x6, x26
    xori x19, x30, -2005
    srli x20, x7, 9
    srl x13, x23, x9
    slli x27, x27, 16
    srai x10, x20, 20
    sll x24, x15, x11
    srl x29, x25, x4
    andi x11, x14, 1485
    bltu x18, x23, _br_taken_0
    sltu x1, x29, x22
    j _br_done_0
_br_taken_0:
    xor x1, x11, x23
_br_done_0:
    slli x18, x17, 13
    addi x22, x31, 528
    amoswap.w x25, x26, (x22)
    div x29, x19, x8
    mul x13, x19, x10
    sub x10, x25, x14
    addi x5, x19, -951
    srai x11, x27, 18
    lw x5, 876(x31)
    sw x17, 876(x31)
    lb x21, 712(x31)
    sb x27, 712(x31)
    srai x1, x8, 7
    bge x16, x25, _br_taken_1
    sll x7, x16, x13
    j _br_done_1
_br_taken_1:
    srl x7, x5, x30
_br_done_1:
    xor x27, x25, x5
    slti x25, x15, -244
    beq x16, x5, _br_taken_2
    sltu x12, x12, x25
    j _br_done_2
_br_taken_2:
    slt x12, x30, x20
_br_done_2:
    or x28, x29, x23
    sll x23, x20, x19
    andi x26, x28, -2027
    bne x30, x18, _br_taken_3
    sll x17, x13, x9
    j _br_done_3
_br_taken_3:
    or x17, x29, x28
_br_done_3:
    bgeu x18, x20, _br_taken_4
    sra x20, x18, x6
    j _br_done_4
_br_taken_4:
    sub x20, x28, x13
_br_done_4:
    xori x12, x7, 1569
    slli x12, x16, 0
    or x9, x20, x4
    srai x30, x6, 6
    bltu x4, x7, _br_taken_5
    or x16, x19, x15
    j _br_done_5
_br_taken_5:
    sll x16, x7, x25
_br_done_5:
    blt x19, x12, _br_taken_6
    and x6, x28, x23
    j _br_done_6
_br_taken_6:
    sltu x6, x13, x16
_br_done_6:
    beq x21, x10, _br_taken_7
    slt x12, x28, x20
    j _br_done_7
_br_taken_7:
    add x12, x4, x21
_br_done_7:
    slt x12, x11, x15
    or x29, x23, x1
    srai x23, x13, 9
    blt x15, x26, _br_taken_8
    add x19, x5, x8
    j _br_done_8
_br_taken_8:
    add x19, x15, x16
_br_done_8:
    bge x19, x6, _br_taken_9
    sll x18, x8, x8
    j _br_done_9
_br_taken_9:
    sll x18, x12, x4
_br_done_9:
    sltu x17, x13, x14
    ori x24, x17, 1688
    addi x28, x27, -1616
    addi x26, x1, 427
    or x17, x9, x1
    slti x13, x20, -1116
    ori x8, x13, 26
    sub x23, x8, x18
    slti x11, x21, 621
    srl x7, x1, x26
    or x14, x8, x29
    lw x13, 480(x31)
    sw x26, 480(x31)
    sll x28, x20, x23
    slti x29, x19, -659
    bgeu x30, x5, _br_taken_10
    srl x19, x11, x19
    j _br_done_10
_br_taken_10:
    sra x19, x18, x16
_br_done_10:
    sra x24, x27, x24
    slt x17, x24, x30
    sra x8, x15, x25
    xori x25, x19, -436
    sra x8, x15, x4
    sltiu x27, x23, 1186
    or x10, x29, x26
    ori x27, x24, -1649
    ori x6, x7, -154
    sll x10, x29, x12
    srai x21, x29, 23
    xori x12, x5, 394
    slli x13, x25, 27
    sra x11, x25, x10
    fmin.d f29, f10, f8
    fmsub.s f29, f24, f5, f31
    bge x16, x15, _br_taken_11
    srl x16, x28, x23
    j _br_done_11
_br_taken_11:
    slt x16, x27, x23
_br_done_11:
    beq x25, x4, _br_taken_12
    slt x23, x23, x1
    j _br_done_12
_br_taken_12:
    sub x23, x15, x4
_br_done_12:
    bltu x7, x22, _br_taken_13
    sub x28, x7, x13
    j _br_done_13
_br_taken_13:
    sub x28, x12, x16
_br_done_13:
    srli x15, x20, 0
    ori x30, x16, -1984
    srai x14, x19, 28
    add x15, x29, x6
    sra x22, x24, x13
    slli x6, x17, 13
    ori x18, x22, -1841
    remu x7, x30, x21
    div x16, x29, x7
    bne x28, x16, _br_taken_14
    and x6, x29, x27
    j _br_done_14
_br_taken_14:
    slt x6, x7, x19
_br_done_14:
    srli x13, x14, 29
    fadd.s f1, f11, f28
    ori x11, x9, -775
    slti x22, x17, -1790
    and x12, x10, x6
    add x6, x6, x6
    add x4, x1, x23
    srl x22, x19, x12
    lh x7, 184(x31)
    sh x4, 184(x31)
    and x17, x13, x11
    sub x1, x27, x6
    sra x7, x15, x24
    slt x24, x5, x9
    xor x30, x29, x18
    mulh x16, x20, x12
    sra x25, x7, x10
    srli x7, x22, 25
    sltu x25, x27, x6
    slli x23, x14, 26
    sltu x17, x8, x15
    mulh x1, x27, x24
    addi x21, x21, -21
    slt x23, x29, x7
    lw x4, 284(x31)
    sw x1, 284(x31)
    slti x29, x23, -450
    xori x21, x27, 1724
    sll x25, x17, x29
    sra x17, x7, x11
    xori x29, x19, -1253
    andi x26, x16, 883
    bltu x14, x16, _br_taken_15
    xor x21, x15, x20
    j _br_done_15
_br_taken_15:
    sll x21, x30, x27
_br_done_15:
    mulh x1, x4, x23
    slti x15, x25, 1000
    addi x1, x6, 1283
    andi x30, x25, 181
    sra x28, x4, x1
    slli x21, x24, 4
    xori x11, x23, -428
    slli x20, x19, 22
    srai x15, x1, 4
    andi x18, x1, -297
    xori x21, x27, 1611
    addi x12, x10, -1137
    and x8, x23, x28
    andi x4, x16, 134
    bne x30, x8, _br_taken_16
    srl x8, x8, x10
    j _br_done_16
_br_taken_16:
    add x8, x22, x11
_br_done_16:
    add x24, x23, x15
    xori x16, x29, -1440
    ori x22, x17, -698
    addi x21, x31, 960
    amoswap.w x11, x20, (x21)
    sltiu x12, x23, 626
    slt x22, x18, x27
    add x22, x27, x4
    sra x1, x8, x8
    mul x18, x18, x13
    mulhu x22, x8, x14
    remu x7, x14, x21
    srl x6, x1, x21
    sub x30, x16, x7
    lhu x18, 100(x31)
    sh x15, 100(x31)
    addi x14, x31, 128
    amomax.w x20, x9, (x14)
    sra x9, x24, x15
    lhu x14, 608(x31)
    sh x6, 608(x31)
    or x20, x16, x21
    srl x18, x12, x11
    xori x1, x26, -802
    add x4, x5, x24
    sltiu x5, x14, 1934
    lw x26, 444(x31)
    sw x26, 444(x31)
    fsub.d f18, f23, f22
    sltiu x18, x8, 1082
    or x16, x7, x24
    srli x26, x30, 1
    sll x7, x10, x22
    or x18, x28, x20
    sltu x15, x25, x17
    bltu x15, x9, _br_taken_17
    slt x11, x13, x10
    j _br_done_17
_br_taken_17:
    and x11, x8, x10
_br_done_17:
    sll x7, x24, x6
    addi x30, x31, 716
    amoadd.w x26, x4, (x30)
    sltu x20, x4, x12
    and x5, x15, x29
    lbu x25, 312(x31)
    sb x1, 312(x31)
    lhu x6, 464(x31)
    sh x12, 464(x31)
    bne x19, x28, _br_taken_18
    sll x16, x16, x7
    j _br_done_18
_br_taken_18:
    add x16, x22, x21
_br_done_18:
    srai x10, x11, 6
    lhu x26, 496(x31)
    sh x16, 496(x31)
    fsub.s f25, f15, f14
    fdiv.s f10, f2, f15
    addi x27, x8, 1606
    add x26, x28, x19
    sltiu x20, x25, -1996
    bltu x6, x1, _br_taken_19
    and x30, x22, x17
    j _br_done_19
_br_taken_19:
    slt x30, x23, x16
_br_done_19:
    slt x5, x26, x21
    or x15, x17, x30
    beq x15, x9, _br_taken_20
    or x20, x14, x11
    j _br_done_20
_br_taken_20:
    xor x20, x30, x23
_br_done_20:
    and x24, x20, x1
    sltiu x7, x1, -1523
    addi x4, x31, 272
    amoand.w x15, x22, (x4)
    fdiv.s f6, f1, f0
    fmin.s f7, f8, f26
    andi x7, x9, -1059
    bge x9, x4, _br_taken_21
    sra x16, x14, x29
    j _br_done_21
_br_taken_21:
    srl x16, x6, x4
_br_done_21:
    bgeu x19, x7, _br_taken_22
    slt x9, x16, x12
    j _br_done_22
_br_taken_22:
    srl x9, x4, x15
_br_done_22:
    slti x12, x22, -1862
    fmul.s f4, f27, f6
    fmadd.d f20, f20, f4, f7
    fadd.s f14, f17, f21
    fnmadd.d f26, f17, f13, f13
    slti x24, x6, 212
    slli x6, x12, 20
    addi x18, x6, 1962
    srai x19, x7, 5
    ori x19, x10, -1409
    and x25, x30, x8
    fdiv.s f3, f26, f10
    fmin.d f16, f29, f4
    fmsub.d f20, f5, f27, f20
    slti x25, x20, -1688
    addi x23, x31, 960
    amomaxu.w x5, x16, (x23)
    mulh x23, x7, x23
    srl x27, x9, x11
    slli x29, x19, 4
    sll x4, x15, x9
    bge x5, x19, _br_taken_23
    xor x10, x18, x12
    j _br_done_23
_br_taken_23:
    and x10, x23, x8
_br_done_23:
    bgeu x22, x10, _br_taken_24
    xor x16, x19, x15
    j _br_done_24
_br_taken_24:
    sltu x16, x11, x6
_br_done_24:
    or x17, x14, x17
    fadd.d f30, f23, f18
    or x20, x16, x4
    sltu x15, x13, x24
    srli x8, x12, 21
    sltiu x29, x18, -694
    ori x30, x25, 726
    addi x4, x27, 622
    add x8, x6, x30
    lw x19, 144(x31)
    sw x26, 144(x31)
    bge x23, x16, _br_taken_25
    and x24, x26, x1
    j _br_done_25
_br_taken_25:
    slt x24, x7, x28
_br_done_25:
    sll x21, x7, x15
    srl x5, x16, x8
    xori x10, x11, -1966
    slt x8, x17, x14
    slt x28, x25, x19
    sub x7, x16, x17
    remu x14, x8, x9
    srli x25, x1, 0
    bge x26, x13, _br_taken_26
    sra x11, x16, x20
    j _br_done_26
_br_taken_26:
    slt x11, x10, x13
_br_done_26:
    or x30, x26, x25
    ori x12, x18, -1959
    sltiu x28, x6, 277
    slt x9, x21, x14
    add x25, x6, x29
    slt x21, x12, x26
    srli x28, x8, 12
    xori x26, x12, 127
    bltu x22, x30, _br_taken_27
    srl x22, x14, x11
    j _br_done_27
_br_taken_27:
    add x22, x13, x20
_br_done_27:
    remu x24, x19, x12
    mul x27, x19, x14
    beq x13, x13, _br_taken_28
    and x30, x23, x6
    j _br_done_28
_br_taken_28:
    sub x30, x8, x27
_br_done_28:
    lhu x18, 0(x31)
    sh x17, 0(x31)
    beq x11, x19, _br_taken_29
    sra x5, x22, x13
    j _br_done_29
_br_taken_29:
    sub x5, x11, x26
_br_done_29:
    blt x11, x25, _br_taken_30
    sltu x16, x11, x16
    j _br_done_30
_br_taken_30:
    or x16, x12, x4
_br_done_30:
    lbu x27, 940(x31)
    sb x5, 940(x31)
    ori x29, x18, 506
    sra x16, x24, x30
    slt x28, x21, x29
    lh x15, 824(x31)
    sh x12, 824(x31)
    ori x11, x26, -1416
    sll x23, x22, x10
    bltu x8, x10, _br_taken_31
    sll x6, x29, x12
    j _br_done_31
_br_taken_31:
    sll x6, x23, x9
_br_done_31:
    sltu x27, x19, x6
    sub x11, x20, x19
    sub x5, x19, x13
    andi x9, x24, -218
    add x4, x22, x25
    bltu x24, x4, _br_taken_32
    slt x28, x1, x4
    j _br_done_32
_br_taken_32:
    sub x28, x10, x15
_br_done_32:
    sltiu x13, x21, -696
    sra x18, x21, x12
    ori x14, x7, 1562
    and x16, x18, x24
    beq x25, x20, _br_taken_33
    sub x8, x15, x8
    j _br_done_33
_br_taken_33:
    sll x8, x8, x17
_br_done_33:
    srai x9, x11, 3
    sub x19, x21, x19
    ori x13, x20, 588
    addi x21, x31, 652
    amoadd.w x16, x13, (x21)
    andi x10, x19, -591
    and x22, x29, x15
    addi x13, x31, 32
    amoor.w x22, x27, (x13)
    and x22, x28, x28
    sltiu x22, x22, 254
    xori x22, x25, -808
    rem x17, x13, x9
    andi x26, x8, -249
    sltu x15, x28, x4
    and x20, x18, x6
    and x27, x28, x27
    srli x11, x7, 6
    bne x11, x30, _br_taken_34
    slt x29, x26, x1
    j _br_done_34
_br_taken_34:
    add x29, x1, x25
_br_done_34:
    bgeu x11, x19, _br_taken_35
    add x6, x27, x13
    j _br_done_35
_br_taken_35:
    srl x6, x9, x15
_br_done_35:
    ori x20, x15, 256
    andi x23, x12, -1298
    sub x24, x16, x4
    lw x11, 788(x31)
    sw x28, 788(x31)
    fdiv.s f25, f30, f28
    fmin.s f25, f4, f18
    fmax.d f21, f3, f2
    blt x22, x13, _br_taken_36
    srl x18, x17, x20
    j _br_done_36
_br_taken_36:
    slt x18, x28, x22
_br_done_36:
    bne x9, x16, _br_taken_37
    sub x7, x5, x23
    j _br_done_37
_br_taken_37:
    sub x7, x13, x26
_br_done_37:
    lb x27, 1008(x31)
    sb x9, 1008(x31)
    srai x15, x20, 6
    sub x24, x10, x18
    bltu x21, x24, _br_taken_38
    xor x4, x21, x20
    j _br_done_38
_br_taken_38:
    sll x4, x25, x21
_br_done_38:
    slt x22, x24, x27
    sll x15, x9, x29
    sltiu x18, x29, -62
    xori x7, x14, 288
    fdiv.d f30, f26, f29
    xori x21, x21, 69
    fnmadd.s f9, f16, f7, f8
    bge x26, x8, _br_taken_39
    xor x23, x8, x23
    j _br_done_39
_br_taken_39:
    sltu x23, x11, x20
_br_done_39:
    bgeu x1, x30, _br_taken_40
    slt x25, x22, x15
    j _br_done_40
_br_taken_40:
    sra x25, x27, x18
_br_done_40:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xebec4d2d50e7987b
    .dword 0xc6f66742e95a0f52
    .dword 0x4dd474bc98ee1b70
    .dword 0xa19f3a94cb8ad0d3
    .dword 0xcce779c8109e3eee
    .dword 0x1ea4b0b7fe6c6219
    .dword 0xcdbc49feccce446d
    .dword 0x3487e7fa7c732a5a
    .dword 0x2c498d5dcd2a1970
    .dword 0x4cc33f91d70dce1b
    .dword 0x9164dd49ac7ba6cb
    .dword 0x8ec92b95d4b18a29
    .dword 0xfc82e051a16ff12d
    .dword 0x9e8d0b698ebd926d
    .dword 0xb9bc398a3aa6073e
    .dword 0x62d72ac723a85d10
    .dword 0xe7aa20f1055981a2
    .dword 0x1bcbe227ca08aef6
    .dword 0x11a74a4c95d614b6
    .dword 0xfce9addc2b35e1fe
    .dword 0x858a5c307ac0abc2
    .dword 0xaeb0677b726ae8c8
    .dword 0x202024ca54abbd62
    .dword 0xed852e1edc68791f
    .dword 0xf06c26d0ed85f1a9
    .dword 0xc557a3aad46d03e8
    .dword 0xf8878121a560009b
    .dword 0xcdf30dd6d956bfab
    .dword 0x48e4e55d5b0eeb1e
    .dword 0x9a264ba43cc7f9e1
    .dword 0x6b6a79b93bd12e07
    .dword 0x1299a793f9eec18f

    .align 2
_torture_data:
    .word 0x59877056
    .word 0x9a902b1f
    .word 0x40223142
    .word 0x2b02f351
    .word 0xb55629ba
    .word 0xd8851746
    .word 0xe7539f09
    .word 0xb60105b5
    .word 0x7a7d3640
    .word 0xa7330e16
    .word 0x6f3d17c0
    .word 0x246f6536
    .word 0x676520bc
    .word 0x08c539df
    .word 0x9e8248f2
    .word 0xba1effe1
    .word 0xff12ed57
    .word 0x5184d496
    .word 0xf41088bb
    .word 0x347afd6c
    .word 0xbfd43757
    .word 0x7ffc6f17
    .word 0x349dabc4
    .word 0x90f9aca7
    .word 0xe89df78a
    .word 0x1393bcc8
    .word 0x89660881
    .word 0xceb11385
    .word 0x66487f09
    .word 0x1cf1fb2b
    .word 0x58084795
    .word 0x7539bfaf
    .word 0xba017665
    .word 0x54a4b1aa
    .word 0xd54101db
    .word 0x6f08534c
    .word 0x59c78ce4
    .word 0x9d2d0cdb
    .word 0x461360db
    .word 0x71cc66d8
    .word 0xc68f2121
    .word 0xe4878497
    .word 0x3cbcf48a
    .word 0xf4d36154
    .word 0xec4e2805
    .word 0x45dd9bf5
    .word 0x0c41174e
    .word 0xc8813cc5
    .word 0x61d59dd3
    .word 0x9d6c1251
    .word 0xc14597a2
    .word 0x2cfa19f6
    .word 0x3d5c72e3
    .word 0x9a0327f9
    .word 0xd6ed8858
    .word 0x38347566
    .word 0x6011bacc
    .word 0x5d050b92
    .word 0x420cf2f6
    .word 0x41f7eae6
    .word 0x605d1afe
    .word 0xb6ebf9cb
    .word 0xe2142095
    .word 0xc0ae3bfd
    .word 0xbd464627
    .word 0xbc8f5640
    .word 0x83551794
    .word 0x7f338d4a
    .word 0x588f14ce
    .word 0x0f511d89
    .word 0x6208d10f
    .word 0x3e9c5fe7
    .word 0xd43faf36
    .word 0xcb188a21
    .word 0xe6e5ea27
    .word 0xaa6f7c94
    .word 0x0ebd3101
    .word 0xecfa2f1e
    .word 0x8e54ef6e
    .word 0xeedcbcb9
    .word 0x60153c33
    .word 0xc88649fe
    .word 0xd24eb1a0
    .word 0xdd129522
    .word 0x2f2bf880
    .word 0xe357b3f3
    .word 0x4653bc41
    .word 0xe58a493e
    .word 0x02f7768d
    .word 0x060642ff
    .word 0x37d5de72
    .word 0xf6c90b8a
    .word 0xd28b441b
    .word 0xa815b450
    .word 0x5ec7b66f
    .word 0x178194cc
    .word 0xb3836f7a
    .word 0x6b11152b
    .word 0x2b993317
    .word 0x153c534f
    .word 0xc5b73195
    .word 0x25cb685c
    .word 0xcfe90873
    .word 0xcf316333
    .word 0xb09465f8
    .word 0xb0bb3e7a
    .word 0xa1a8dcca
    .word 0xf564c334
    .word 0x6e94729e
    .word 0x0ea17e7d
    .word 0x13fb0f4b
    .word 0x550f4e3c
    .word 0x6d0e85c1
    .word 0xea70069a
    .word 0xe28b8482
    .word 0xc42835c6
    .word 0x230ed123
    .word 0xd9b6de31
    .word 0x7cbb7b45
    .word 0xb479ad82
    .word 0xf2fcdd1b
    .word 0x439f8693
    .word 0xcf7e0cee
    .word 0xe72e757c
    .word 0xeb5f29a6
    .word 0xb2b17eb8
    .word 0xe34dc720
    .word 0x2053aa4f
    .word 0xbd38fa40
    .word 0x4e5e7ec4
    .word 0x771b2bf3
    .word 0x3ff6c845
    .word 0xcb28d1bd
    .word 0xf2932893
    .word 0x8b8580c2
    .word 0x23ac3cd5
    .word 0x0abf5209
    .word 0xad19c5e7
    .word 0x8d50b038
    .word 0xd1cf5500
    .word 0xdb7a29f6
    .word 0xfe9849da
    .word 0xfeeb4d45
    .word 0xa093f370
    .word 0xf7911032
    .word 0xfe6f81eb
    .word 0x7e1554ea
    .word 0x6372f96c
    .word 0xdf0a42ac
    .word 0x09870b18
    .word 0xf34af834
    .word 0xc99fedb6
    .word 0xd7b909fc
    .word 0x06708759
    .word 0x39c7cc30
    .word 0x44ead7bd
    .word 0x1b78045c
    .word 0xa82c0349
    .word 0x847be831
    .word 0x308f2b1c
    .word 0x0f164c80
    .word 0x4a1eabf9
    .word 0x6989631a
    .word 0x8be35ccc
    .word 0xdcf2e07a
    .word 0x4c1f6073
    .word 0x28d6cb12
    .word 0xba8afd42
    .word 0xf7f714f8
    .word 0x2344beb6
    .word 0xb250cc5a
    .word 0x9d193768
    .word 0xab476c1d
    .word 0xc4c64501
    .word 0x050a63ac
    .word 0x482bfdf1
    .word 0x236f30ac
    .word 0x5104c550
    .word 0x57db7066
    .word 0x34784643
    .word 0xee63bd95
    .word 0x83c151b7
    .word 0xa0cb970a
    .word 0x27be6b1c
    .word 0x43e229e2
    .word 0x5fa8c3b2
    .word 0x8414fbfb
    .word 0x7c613627
    .word 0xcc7f0374
    .word 0xe2a8e77e
    .word 0x4b45d0fc
    .word 0xa2c0be5e
    .word 0x12b89923
    .word 0x1f3acba5
    .word 0x7b40df21
    .word 0x48545879
    .word 0xeb098ed1
    .word 0xc6780cc2
    .word 0xbe42dff2
    .word 0x7a83dc38
    .word 0x844245aa
    .word 0x92d7af22
    .word 0x056e2597
    .word 0x9d775628
    .word 0xb9f04f5f
    .word 0xc3d7c223
    .word 0xd366fff6
    .word 0x3c3e51a3
    .word 0x45d3c14d
    .word 0x4fa0e193
    .word 0x347d1437
    .word 0x27efed2e
    .word 0x23f95e4e
    .word 0xba320bf8
    .word 0xf9abb837
    .word 0xdcdcb452
    .word 0x76dd72cd
    .word 0x1ef3f4fb
    .word 0x9a7ca8df
    .word 0x4b1a35e8
    .word 0x63611e9e
    .word 0xaa867ab8
    .word 0xb1e4d439
    .word 0x8b306449
    .word 0x3abf5da7
    .word 0x26d8c1c7
    .word 0x8ca5e4df
    .word 0x1a0ea706
    .word 0xecfed3a8
    .word 0x6c43b315
    .word 0x3a6fbd5e
    .word 0x579e6902
    .word 0xd6dbf7d4
    .word 0xf62103c6
    .word 0xa7befff7
    .word 0xf55a6105
    .word 0xbd72073f
    .word 0xe889093a
    .word 0xb4b3884b
    .word 0xcbcadcda
    .word 0x14997b2a
    .word 0x3e45e771
    .word 0xd011c965
    .word 0x3b8365e7
    .word 0xc3ea82f7
    .word 0x9474e338
    .word 0x512a4652
    .word 0xc8b33640
    .word 0x9de2dc7b
    .word 0x3886d272
    .word 0xa007a3ff
    .word 0xd2b2be97
    .word 0x75f4870e
    .word 0xb92e2c22
    .word 0x9711d655
    .word 0xb92e82c5

#include "frost_footer.S"
