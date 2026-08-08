// Generated RV64IMAFDC torture test for Frost (seed=20260806)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x4775124d5d88d23e
    li x4, 0xac505b8b0963f6fc
    li x5, 0x6c46439945dfb00d
    li x6, 0xb75295cf87597c15
    li x7, 0x0b209e9ed9a27303
    li x8, 0x6023cee42ace600f
    li x9, 0xba13ab858956348d
    li x10, 0xc2b3be0f1dc0bd4b
    li x11, 0xcca8ef100c03c345
    li x12, 0x364abcbdf5aeae5c
    li x13, 0xb31e8699396ab454
    li x14, 0x71efcefa25d5900e
    li x15, 0x2c97ab7d2146e2fb
    li x16, 0x7e490f54d9adaba5
    li x17, 0x5e2d1b661198b979
    li x18, 0xa522abb1c249af91
    li x19, 0x29fae4e12fe4441a
    li x20, 0xcd07dfa83600c672
    li x21, 0xdcf3ccf5f8375670
    li x22, 0x809635dd363d01d2
    li x23, 0x00cecbace752c7d4
    li x24, 0x8a1dea3678e0e81f
    li x25, 0x24484d77b405afcd
    li x26, 0x52e7e7b4427a1c03
    li x27, 0x85da486accc431d1
    li x28, 0x362c9917cab1780a
    li x29, 0x4c7f0eb371eb0c08
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
    li x1, 0xf3f9fecc1e4b41d9

    bgeu x17, x6, _br_taken_0
    sltu x27, x12, x14
    j _br_done_0
_br_taken_0:
    and x27, x23, x16
_br_done_0:
    srli x13, x17, 26
    addi x1, x24, -1537
    ori x25, x10, -4
    bltu x5, x14, _br_taken_1
    add x23, x24, x6
    j _br_done_1
_br_taken_1:
    add x23, x10, x18
_br_done_1:
    fadd.s f28, f20, f17
    andi x29, x7, 411
    srl x26, x1, x29
    subw x27, x21, x27
    or x26, x7, x1
    lbu x20, 840(x31)
    sb x28, 840(x31)
    ori x18, x1, -430
    sraw x14, x18, x11
    mulh x26, x16, x26
    divw x15, x20, x15
    addi x30, x31, 832
    amoand.d x22, x10, (x30)
    srai x13, x12, 7
    xor x7, x22, x4
    slliw x7, x13, 26
    lh x21, 540(x31)
    sh x27, 540(x31)
    srli x6, x23, 49
    slliw x7, x29, 17
    sraiw x28, x7, 2
    mulh x26, x9, x8
    addw x4, x10, x10
    srliw x5, x26, 21
    bgeu x14, x4, _br_taken_2
    sra x5, x27, x25
    j _br_done_2
_br_taken_2:
    sub x5, x22, x23
_br_done_2:
    slti x20, x20, -105
    addi x5, x24, -758
    ori x11, x9, -273
    bge x17, x15, _br_taken_3
    sltu x20, x16, x28
    j _br_done_3
_br_taken_3:
    sub x20, x19, x6
_br_done_3:
    ld x28, 656(x31)
    sd x27, 656(x31)
    bgeu x15, x8, _br_taken_4
    xor x17, x11, x12
    j _br_done_4
_br_taken_4:
    srl x17, x25, x4
_br_done_4:
    addiw x25, x26, 563
    srliw x21, x4, 29
    sraiw x14, x18, 2
    ld x21, 112(x31)
    sd x9, 112(x31)
    srai x13, x25, 59
    srl x29, x11, x13
    addiw x17, x22, 1363
    addiw x17, x15, 1830
    beq x14, x17, _br_taken_5
    slt x23, x23, x27
    j _br_done_5
_br_taken_5:
    sltu x23, x16, x28
_br_done_5:
    or x11, x17, x6
    slli x27, x5, 19
    fmax.d f7, f3, f31
    fmsub.s f6, f3, f3, f30
    fmul.d f14, f6, f6
    bge x4, x7, _br_taken_6
    sub x28, x1, x26
    j _br_done_6
_br_taken_6:
    sltu x28, x19, x14
_br_done_6:
    bltu x27, x1, _br_taken_7
    srl x9, x23, x5
    j _br_done_7
_br_taken_7:
    srl x9, x28, x8
_br_done_7:
    divw x28, x13, x26
    divuw x4, x25, x22
    ld x10, 456(x31)
    sd x4, 456(x31)
    lwu x25, 340(x31)
    sw x8, 340(x31)
    srl x28, x22, x5
    slti x23, x29, -105
    sub x19, x26, x17
    sltiu x21, x8, -377
    blt x14, x10, _br_taken_8
    srl x17, x28, x20
    j _br_done_8
_br_taken_8:
    xor x17, x21, x16
_br_done_8:
    bne x21, x10, _br_taken_9
    srl x13, x16, x11
    j _br_done_9
_br_taken_9:
    add x13, x12, x9
_br_done_9:
    sll x29, x17, x25
    bltu x18, x22, _br_taken_10
    and x20, x25, x7
    j _br_done_10
_br_taken_10:
    sub x20, x23, x1
_br_done_10:
    sllw x11, x7, x22
    srli x27, x11, 59
    srl x28, x18, x9
    fmsub.d f10, f12, f27, f27
    fmin.d f17, f12, f10
    fmax.s f23, f19, f27
    beq x17, x28, _br_taken_11
    sub x5, x13, x28
    j _br_done_11
_br_taken_11:
    slt x5, x9, x25
_br_done_11:
    beq x16, x22, _br_taken_12
    or x26, x4, x5
    j _br_done_12
_br_taken_12:
    srl x26, x14, x10
_br_done_12:
    mulhu x22, x5, x19
    remw x27, x21, x12
    slt x1, x27, x10
    andi x6, x26, 1248
    beq x11, x5, _br_taken_13
    add x7, x6, x6
    j _br_done_13
_br_taken_13:
    xor x7, x12, x10
_br_done_13:
    srlw x13, x12, x19
    addi x30, x31, 464
    amomaxu.d x16, x12, (x30)
    sltu x26, x6, x22
    ld x27, 0(x31)
    sd x23, 0(x31)
    lw x19, 412(x31)
    sw x15, 412(x31)
    slti x13, x7, -909
    subw x1, x4, x1
    sra x9, x6, x7
    xor x27, x14, x23
    divw x13, x17, x1
    rem x5, x24, x29
    or x4, x7, x8
    bge x25, x9, _br_taken_14
    xor x7, x10, x10
    j _br_done_14
_br_taken_14:
    xor x7, x24, x16
_br_done_14:
    fsub.s f19, f29, f23
    fsub.s f31, f19, f30
    addi x13, x12, -13
    bne x12, x21, _br_taken_15
    srl x21, x20, x19
    j _br_done_15
_br_taken_15:
    xor x21, x11, x21
_br_done_15:
    fsub.s f20, f25, f23
    fdiv.d f12, f22, f4
    fsub.s f24, f18, f30
    lw x7, 124(x31)
    sw x9, 124(x31)
    and x13, x27, x13
    blt x22, x17, _br_taken_16
    xor x24, x13, x10
    j _br_done_16
_br_taken_16:
    srl x24, x17, x7
_br_done_16:
    fmul.d f8, f7, f18
    fmul.d f5, f8, f17
    subw x6, x11, x1
    srlw x25, x4, x22
    lwu x13, 56(x31)
    sw x1, 56(x31)
    slliw x26, x10, 29
    bge x26, x4, _br_taken_17
    and x15, x17, x11
    j _br_done_17
_br_taken_17:
    sll x15, x12, x16
_br_done_17:
    addi x30, x31, 536
    amomin.d x15, x21, (x30)
    fadd.s f20, f4, f23
    fsub.s f27, f2, f27
    fadd.d f4, f8, f2
    sll x23, x15, x8
    ori x21, x10, 56
    addi x7, x21, -1990
    fmax.d f20, f0, f30
    fmin.d f20, f25, f20
    sub x25, x5, x23
    sub x29, x7, x16
    srai x20, x5, 30
    bgeu x6, x16, _br_taken_18
    srl x4, x14, x1
    j _br_done_18
_br_taken_18:
    or x4, x22, x1
_br_done_18:
    srliw x4, x12, 9
    bltu x14, x29, _br_taken_19
    and x1, x10, x17
    j _br_done_19
_br_taken_19:
    srl x1, x22, x1
_br_done_19:
    slli x25, x1, 53
    srlw x12, x19, x20
    srli x21, x19, 3
    lwu x29, 388(x31)
    sw x1, 388(x31)
    fmul.d f14, f3, f11
    fmadd.s f25, f26, f24, f30
    fmadd.s f12, f4, f3, f29
    srlw x26, x28, x7
    addi x11, x27, -1710
    sub x9, x1, x14
    and x16, x9, x27
    srlw x19, x24, x26
    sllw x24, x12, x24
    sll x22, x14, x14
    slti x26, x5, 514
    addi x7, x12, -648
    ori x25, x15, 1792
    fmsub.d f21, f17, f5, f0
    fnmsub.s f13, f1, f20, f14
    fdiv.s f1, f30, f22
    sll x7, x17, x9
    ori x21, x28, 931
    sraw x9, x22, x4
    ld x9, 408(x31)
    sd x6, 408(x31)
    rem x14, x5, x17
    remuw x28, x25, x17
    xori x9, x18, -1177
    sra x26, x5, x5
    srliw x1, x4, 1
    fmin.s f6, f5, f14
    fmin.s f14, f7, f5
    fdiv.s f23, f18, f15
    sraiw x1, x28, 12
    or x10, x8, x20
    subw x24, x16, x9
    sltiu x8, x26, -529
    sltiu x24, x27, 1808
    ori x11, x27, 1834
    lh x14, 856(x31)
    sh x23, 856(x31)
    blt x20, x15, _br_taken_20
    sub x18, x29, x21
    j _br_done_20
_br_taken_20:
    sll x18, x24, x17
_br_done_20:
    addi x19, x17, 1750
    lw x14, 944(x31)
    sw x7, 944(x31)
    srl x22, x29, x24
    addi x30, x31, 640
    amomin.w x19, x22, (x30)
    addi x15, x9, -1330
    sra x14, x29, x26
    sraiw x17, x1, 18
    slti x26, x9, 282
    srl x26, x17, x6
    sll x5, x19, x21
    lw x20, 736(x31)
    sw x11, 736(x31)
    addi x30, x31, 136
    amoand.w x16, x21, (x30)
    blt x16, x19, _br_taken_21
    sll x13, x15, x25
    j _br_done_21
_br_taken_21:
    and x13, x17, x1
_br_done_21:
    fmadd.s f26, f16, f17, f12
    fsub.s f26, f14, f16
    fadd.d f6, f17, f16
    addi x30, x31, 108
    amoxor.w x9, x16, (x30)
    slli x11, x29, 41
    slli x5, x4, 53
    srliw x8, x24, 13
    bltu x24, x28, _br_taken_22
    add x20, x12, x9
    j _br_done_22
_br_taken_22:
    slt x20, x4, x26
_br_done_22:
    sll x17, x6, x28
    sraiw x12, x23, 21
    subw x5, x7, x1
    mulh x6, x12, x13
    rem x29, x9, x6
    bltu x5, x27, _br_taken_23
    slt x14, x29, x25
    j _br_done_23
_br_taken_23:
    sll x14, x16, x4
_br_done_23:
    srl x18, x21, x17
    andi x27, x27, -22
    fmsub.s f8, f8, f6, f18
    fmin.d f27, f7, f29
    fadd.d f2, f18, f17
    sllw x4, x16, x12
    srai x22, x19, 4
    slti x13, x28, -776
    ori x19, x7, 1084
    slti x22, x6, 1077
    beq x16, x6, _br_taken_24
    sll x29, x8, x25
    j _br_done_24
_br_taken_24:
    sltu x29, x14, x16
_br_done_24:
    add x14, x28, x27
    slti x8, x13, -1144
    srl x19, x21, x13
    andi x12, x25, -890
    slli x9, x17, 32
    addiw x8, x25, -1997
    addiw x17, x11, 1153
    ld x18, 624(x31)
    sd x27, 624(x31)
    addw x23, x28, x20
    div x10, x21, x6
    mulh x24, x11, x9
    beq x5, x7, _br_taken_25
    srl x17, x22, x13
    j _br_done_25
_br_taken_25:
    or x17, x14, x18
_br_done_25:
    srliw x20, x27, 7
    sllw x25, x24, x29
    lw x10, 552(x31)
    sw x20, 552(x31)
    xor x18, x29, x20
    srl x8, x21, x17
    add x29, x15, x25
    lb x16, 488(x31)
    sb x8, 488(x31)
    bltu x25, x25, _br_taken_26
    add x6, x28, x5
    j _br_done_26
_br_taken_26:
    sltu x6, x13, x4
_br_done_26:
    xor x20, x19, x20
    ori x9, x27, 1944
    srli x9, x29, 53
    subw x5, x12, x11
    srliw x21, x11, 28
    addi x30, x31, 492
    amomin.w x23, x19, (x30)
    fmadd.d f10, f30, f24, f5
    fsub.s f5, f30, f18
    sll x23, x5, x23
    fmin.s f0, f11, f23
    fadd.d f5, f26, f26
    bltu x20, x28, _br_taken_27
    add x5, x19, x26
    j _br_done_27
_br_taken_27:
    add x5, x4, x28
_br_done_27:
    sra x5, x14, x10
    sltiu x6, x21, 1994
    add x23, x14, x17
    or x22, x6, x6
    addi x30, x31, 632
    amoadd.w x22, x19, (x30)
    blt x21, x12, _br_taken_28
    sltu x11, x18, x29
    j _br_done_28
_br_taken_28:
    and x11, x1, x14
_br_done_28:
    xori x1, x1, -1391
    addiw x29, x25, -549
    sraw x12, x15, x7
    slt x8, x19, x1
    fmsub.s f18, f21, f12, f23
    sra x23, x7, x7
    sub x12, x26, x16
    lwu x12, 560(x31)
    sw x18, 560(x31)
    fsub.d f25, f17, f2
    srliw x19, x26, 4
    sllw x20, x6, x14
    slti x13, x4, -1665
    fnmadd.d f10, f22, f5, f19
    fadd.d f8, f16, f26
    fmax.s f15, f30, f24
    addi x30, x31, 852
    amoand.w x10, x25, (x30)
    srl x25, x25, x10
    xor x11, x16, x4
    srli x13, x22, 1
    lbu x6, 764(x31)
    sb x4, 764(x31)
    slt x18, x5, x24
    addiw x4, x11, -1378
    srl x12, x20, x7
    slt x23, x10, x28
    addi x28, x25, -297
    srai x15, x6, 57
    bne x28, x19, _br_taken_29
    slt x16, x9, x1
    j _br_done_29
_br_taken_29:
    and x16, x12, x16
_br_done_29:
    subw x21, x11, x24
    slt x26, x9, x12
    fmadd.d f27, f14, f31, f31
    xor x29, x9, x17
    subw x5, x11, x28
    xor x8, x29, x20
    lwu x4, 788(x31)
    sw x16, 788(x31)
    xor x1, x11, x23
    rem x16, x27, x11
    mulhsu x12, x25, x11
    sub x13, x28, x12
    subw x5, x13, x14
    srliw x21, x9, 27
    beq x19, x6, _br_taken_30
    srl x27, x25, x9
    j _br_done_30
_br_taken_30:
    add x27, x6, x25
_br_done_30:
    xori x6, x4, -1320
    sra x22, x16, x21
    addi x15, x18, 1986
    addi x18, x15, -906
    mul x18, x11, x29
    mulw x20, x8, x11
    addw x19, x22, x7
    slli x8, x20, 19
    sra x6, x27, x10
    sllw x25, x25, x25
    sltu x7, x14, x5
    or x21, x11, x12
    addw x23, x24, x25
    andi x27, x23, 285
    fdiv.d f10, f19, f10
    fadd.s f11, f11, f5
    fadd.s f26, f19, f27
    addi x30, x31, 256
    amominu.w x13, x21, (x30)
    mulhu x23, x6, x26
    lb x24, 836(x31)
    sb x15, 836(x31)
    or x8, x1, x13
    sltiu x11, x15, -952
    lb x5, 940(x31)
    sb x27, 940(x31)
    fdiv.d f24, f22, f3
    fmadd.d f24, f4, f25, f21
    lwu x21, 1016(x31)
    sw x12, 1016(x31)
    addi x30, x31, 868
    amomaxu.w x19, x14, (x30)
    xori x17, x27, -1735
    xori x16, x16, 1354
    fmadd.s f25, f4, f17, f23
    fmin.s f14, f27, f31
    fmax.d f12, f14, f6
    srliw x20, x4, 30
    srl x24, x23, x28
    sra x6, x23, x23
    addi x24, x1, -558
    beq x12, x7, _br_taken_31
    slt x25, x7, x26
    j _br_done_31
_br_taken_31:
    sll x25, x15, x29
_br_done_31:
    srli x19, x29, 25
    srai x18, x17, 10
    beq x26, x12, _br_taken_32
    slt x15, x11, x16
    j _br_done_32
_br_taken_32:
    srl x15, x13, x7
_br_done_32:
    addi x30, x31, 264
    amomin.d x25, x16, (x30)

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xbced892dd8001684
    .dword 0xb663cc7f90851f88
    .dword 0x81f622ba37f5bfb9
    .dword 0x3a6895e4c79577f7
    .dword 0x9634ca503666329b
    .dword 0x1d079e6c485cbbe1
    .dword 0xfbcac3b207b4b0e4
    .dword 0x7ddc1b84278468c2
    .dword 0x7737ea7d6ab889a0
    .dword 0x3d65ef38a7d6e940
    .dword 0xdbd478746c2a2039
    .dword 0xc7651287a013be58
    .dword 0xb60e886fb8c695aa
    .dword 0x8fd927296f99fb01
    .dword 0xcb5c9ce4e98b9727
    .dword 0xb53457cd182775fc
    .dword 0x5a878c2addb83780
    .dword 0x447dc37642e97311
    .dword 0xa4bc8497403881cf
    .dword 0x75a827e5803ff958
    .dword 0x70ae858748ebd3f2
    .dword 0x35795aca5ba73725
    .dword 0xdad94e0f1a9045cd
    .dword 0x1940eae6196e8af9
    .dword 0x8d14918a094203e3
    .dword 0xcd2b4bcb791535f5
    .dword 0x974cd947fe04bd98
    .dword 0x46ab222519e03d6e
    .dword 0xba7f5f6800b10347
    .dword 0x62f951e2e8eae722
    .dword 0x94cb5ef169380133
    .dword 0x8d26eb4396e59c57

    .align 2
_torture_data:
    .word 0xe3ae0d82
    .word 0x72ee0a4d
    .word 0x8563c62a
    .word 0x79ad7215
    .word 0xec04f551
    .word 0xb2630e60
    .word 0xb0bed99c
    .word 0x0c7f1f44
    .word 0x14b68e99
    .word 0x0b2eaf98
    .word 0x36e0ecb8
    .word 0xb9cdc1df
    .word 0xb5dbbb88
    .word 0xbed8fcf8
    .word 0xa72fab31
    .word 0x968596b3
    .word 0x3d7612dd
    .word 0xb1f418d1
    .word 0xe8db30cd
    .word 0xd8e10161
    .word 0xfb9f0a75
    .word 0x715f739f
    .word 0xba9bcb93
    .word 0x528435c7
    .word 0xb9b1c848
    .word 0xab56f2b6
    .word 0x8cd7c194
    .word 0xb06190f5
    .word 0x68c96a38
    .word 0x5dd72d9c
    .word 0xf9d85e22
    .word 0xc5d0e22d
    .word 0x349acb8d
    .word 0x099a5101
    .word 0x952e52ce
    .word 0x990149d9
    .word 0x508977a1
    .word 0xe4b42c1b
    .word 0xfd318d49
    .word 0x6bf6b66f
    .word 0x16235b52
    .word 0x6b2514a7
    .word 0x110953d9
    .word 0x8e523100
    .word 0xfb695e56
    .word 0x5c342583
    .word 0x4afdbb8c
    .word 0x71b3e1c3
    .word 0x1e776686
    .word 0x57ecb4b1
    .word 0x0bc6bd72
    .word 0xee96537a
    .word 0x01e0e127
    .word 0x6c1eff41
    .word 0xb7aa3367
    .word 0xf31a944e
    .word 0x4d03ded7
    .word 0x3391deb6
    .word 0x7a216b57
    .word 0x5a6c403b
    .word 0x69832401
    .word 0xc2d1f369
    .word 0x5963d87f
    .word 0x41157118
    .word 0xdbdbb9c1
    .word 0x339da564
    .word 0x286a247e
    .word 0x697445e6
    .word 0xb31f41e6
    .word 0xb43831bd
    .word 0xe593d00e
    .word 0x99767e27
    .word 0x4827e937
    .word 0x5060ece6
    .word 0x8dcb7bb2
    .word 0x563183e8
    .word 0xdb44aedf
    .word 0x8082a879
    .word 0x693827e7
    .word 0x3259bc40
    .word 0x2390d7e4
    .word 0xb6de13c9
    .word 0x7c66a688
    .word 0xadc3b8d2
    .word 0x5120884b
    .word 0x9434c1b3
    .word 0xeb82b53c
    .word 0xc6b690d1
    .word 0x9ed10d56
    .word 0xad390572
    .word 0x2f5fcfd7
    .word 0x52d8b21e
    .word 0x3b317950
    .word 0x955713bc
    .word 0x87676b3a
    .word 0x6c78c090
    .word 0x2c0cde5c
    .word 0x77e50df1
    .word 0x5b9aa00f
    .word 0x69cc6a5d
    .word 0x77b19bda
    .word 0xdd3f1ffa
    .word 0x019e394b
    .word 0x0656e602
    .word 0x1dd6a99c
    .word 0xa511cd50
    .word 0x288f7f52
    .word 0xe6e4749f
    .word 0x69390b38
    .word 0x322f4404
    .word 0xe0595027
    .word 0x2ce54257
    .word 0xd6ec32b5
    .word 0x833fe8ab
    .word 0xd97df749
    .word 0xd69eaa72
    .word 0xb5aea17e
    .word 0x3d054b10
    .word 0x46d50e28
    .word 0xb7c208e3
    .word 0xbf3396b5
    .word 0x6b11a1f6
    .word 0x1dde6e24
    .word 0x6dcfcf78
    .word 0xe8afb6cf
    .word 0x5b2d6ad4
    .word 0xe055f477
    .word 0xad674cf8
    .word 0x9ecb3ece
    .word 0x9379b3f2
    .word 0xfd07f6be
    .word 0x2e59b367
    .word 0x1e4be983
    .word 0xdc1f5d8f
    .word 0x0a57ae7f
    .word 0xc7764362
    .word 0xb32a6e39
    .word 0xaedbb476
    .word 0x6948ae6a
    .word 0xf76f335a
    .word 0xd6f88362
    .word 0xb5ac0cfa
    .word 0xc9ea2839
    .word 0x4d887658
    .word 0xda8bfaee
    .word 0x4e853343
    .word 0x814ad6c9
    .word 0xece19ecc
    .word 0x34fb435e
    .word 0x61873101
    .word 0x4aa27a7f
    .word 0x63311805
    .word 0xce8a0190
    .word 0x53a39ab9
    .word 0x8aa55dfc
    .word 0x334ff30a
    .word 0x29c724f3
    .word 0xb675de60
    .word 0x390d47e9
    .word 0x10b97588
    .word 0xcf5dd5b3
    .word 0x736f4f4e
    .word 0x3125f636
    .word 0x1da60460
    .word 0x84cd428d
    .word 0xf5dc8d1d
    .word 0xbeabe3bb
    .word 0x58030250
    .word 0xcd86c351
    .word 0xb919cb03
    .word 0xaae7f118
    .word 0x9fee253f
    .word 0xf03bb5cc
    .word 0xb6f5bdda
    .word 0x023e7647
    .word 0x6ade1f8b
    .word 0xd059cbfa
    .word 0x2f0f95e0
    .word 0x9837030e
    .word 0x357a886e
    .word 0xb0195248
    .word 0x21e9bc96
    .word 0x77b4bae5
    .word 0x3c128814
    .word 0x6e95c381
    .word 0x805b0f66
    .word 0x977dda85
    .word 0x31577c90
    .word 0x94048dd4
    .word 0xdd7ba636
    .word 0xb3526c31
    .word 0xaf7d1e4c
    .word 0xf313cfe3
    .word 0xa60713cf
    .word 0x60439168
    .word 0x640f5d71
    .word 0xedec3002
    .word 0x10991e7b
    .word 0xd0b7c2ed
    .word 0x502a316a
    .word 0x7cefbc4d
    .word 0x8fbb6054
    .word 0x63872ced
    .word 0xbe06e713
    .word 0xf901ad19
    .word 0xd33d99f1
    .word 0xdece6808
    .word 0xb17a10c5
    .word 0x8a6822db
    .word 0x7196b609
    .word 0x32b2c20e
    .word 0xd1851553
    .word 0x33b39e81
    .word 0x7ec324ea
    .word 0x5b83b00d
    .word 0x762173c5
    .word 0x421a2532
    .word 0x272e979f
    .word 0xb3755cab
    .word 0x3d5e8218
    .word 0x525edfcb
    .word 0xda9525a0
    .word 0xb93f0442
    .word 0x96025287
    .word 0x601f10dd
    .word 0x5c3e571f
    .word 0xccc5b70d
    .word 0x2b8c3941
    .word 0x03073cf8
    .word 0x3d2b97bf
    .word 0x816ae15c
    .word 0x6456b44c
    .word 0x6b590f6d
    .word 0x743080f4
    .word 0xc4a37fb7
    .word 0xad10c8ca
    .word 0xc25c935e
    .word 0x4468342e
    .word 0xbc6eb9d1
    .word 0xec15e970
    .word 0x3ce66081
    .word 0x372f16f7
    .word 0x87bddc56
    .word 0x5d6d5363
    .word 0x2a587350
    .word 0x409a22aa
    .word 0x8f9dbb45
    .word 0x50faaf82
    .word 0x57367350
    .word 0xdfb5a96b
    .word 0x54cf2a5f
    .word 0x956e2567
    .word 0x7eb41ef4
    .word 0x3d93a4ba
    .word 0xe1e551e5
    .word 0x9d927def

#include "frost_footer.S"
