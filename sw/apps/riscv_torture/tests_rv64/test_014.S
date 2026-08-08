// Generated RV64IMAFDC torture test for Frost (seed=20260816)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x958c12e1de458f5a
    li x4, 0x77587cc7db755ff9
    li x5, 0xbe2e5c9b02706662
    li x6, 0x5bd94284d3aa31fb
    li x7, 0x76f655d3cada1717
    li x8, 0x0ff4b6623240b816
    li x9, 0x610ba00221134801
    li x10, 0xf4582de8586c6551
    li x11, 0xeea60bad95d84b0f
    li x12, 0x24fe25af1c0a0aa3
    li x13, 0x28acf6e2aba3a93e
    li x14, 0x9f86da4d0b63fb33
    li x15, 0xf92914911100a903
    li x16, 0x6b5e4df03759a49d
    li x17, 0x8497aa1e8fd9ad9d
    li x18, 0x5cb8732aa7c28b3e
    li x19, 0xcc85266716b10b50
    li x20, 0xcc343650bfea9594
    li x21, 0x15ae7c20270e9482
    li x22, 0x36ee4ea19211f679
    li x23, 0x637da8dcda4d0187
    li x24, 0x3dc8500d84654c03
    li x25, 0x5fef120a0a27deb6
    li x26, 0xf8391ea3e4f99cb1
    li x27, 0x9f1de50a43ce4947
    li x28, 0xd909aaf5c0d0d522
    li x29, 0x9732f7c7cae84f86
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
    li x1, 0x4a6dc80bb6f797d0

    addiw x8, x19, 1208
    fmax.d f19, f16, f9
    lw x12, 832(x31)
    sw x6, 832(x31)
    srliw x19, x20, 17
    slli x19, x29, 41
    bgeu x10, x20, _br_taken_0
    srl x11, x15, x14
    j _br_done_0
_br_taken_0:
    and x11, x20, x13
_br_done_0:
    blt x26, x13, _br_taken_1
    xor x1, x12, x27
    j _br_done_1
_br_taken_1:
    srl x1, x13, x26
_br_done_1:
    addw x24, x29, x5
    sll x7, x18, x15
    srliw x1, x29, 3
    addi x29, x27, 989
    blt x22, x17, _br_taken_2
    slt x16, x4, x14
    j _br_done_2
_br_taken_2:
    sub x16, x28, x25
_br_done_2:
    fsub.s f30, f2, f8
    fdiv.d f27, f19, f25
    and x11, x15, x14
    xori x26, x25, -213
    fsub.s f7, f16, f16
    sltu x12, x21, x6
    subw x13, x19, x1
    sraw x28, x14, x10
    sraiw x5, x12, 1
    ld x28, 280(x31)
    sd x16, 280(x31)
    blt x5, x8, _br_taken_3
    slt x14, x18, x10
    j _br_done_3
_br_taken_3:
    or x14, x29, x6
_br_done_3:
    addi x30, x31, 624
    amominu.d x17, x21, (x30)
    fsub.d f25, f29, f3
    and x10, x28, x28
    sltiu x25, x7, 314
    sll x9, x18, x19
    xori x28, x29, -1506
    srlw x14, x19, x21
    subw x18, x8, x10
    fsub.d f23, f2, f7
    sllw x1, x22, x22
    and x5, x23, x24
    srai x23, x4, 22
    bge x6, x1, _br_taken_4
    add x21, x24, x13
    j _br_done_4
_br_taken_4:
    and x21, x14, x26
_br_done_4:
    sltiu x29, x24, 1866
    and x22, x28, x18
    bgeu x6, x13, _br_taken_5
    xor x16, x28, x18
    j _br_done_5
_br_taken_5:
    sltu x16, x15, x10
_br_done_5:
    ld x17, 624(x31)
    sd x4, 624(x31)
    addw x28, x15, x21
    slt x22, x28, x20
    or x19, x13, x20
    addiw x14, x14, -2007
    bne x5, x7, _br_taken_6
    add x27, x15, x24
    j _br_done_6
_br_taken_6:
    slt x27, x27, x10
_br_done_6:
    slliw x29, x16, 2
    sraw x15, x1, x15
    slti x20, x20, 1693
    addi x30, x31, 464
    amoor.d x28, x13, (x30)
    fsub.s f14, f26, f3
    fdiv.s f23, f26, f1
    fmsub.s f14, f17, f14, f0
    add x28, x19, x24
    sra x27, x21, x18
    addi x18, x9, -1397
    srliw x25, x7, 30
    sltiu x21, x1, -763
    srlw x16, x18, x10
    sraw x26, x15, x21
    fadd.s f0, f20, f4
    fmin.s f30, f24, f10
    bltu x9, x19, _br_taken_7
    sll x22, x20, x20
    j _br_done_7
_br_taken_7:
    sra x22, x19, x16
_br_done_7:
    sltiu x15, x19, 1638
    sltiu x16, x25, 223
    srai x4, x14, 9
    bgeu x28, x13, _br_taken_8
    sltu x16, x7, x15
    j _br_done_8
_br_taken_8:
    sll x16, x6, x15
_br_done_8:
    bgeu x14, x15, _br_taken_9
    srl x10, x23, x12
    j _br_done_9
_br_taken_9:
    add x10, x17, x4
_br_done_9:
    addiw x21, x6, 734
    sltu x17, x1, x24
    fmul.s f5, f29, f12
    bne x21, x7, _br_taken_10
    sra x24, x21, x22
    j _br_done_10
_br_taken_10:
    add x24, x24, x9
_br_done_10:
    bne x28, x13, _br_taken_11
    sra x27, x25, x29
    j _br_done_11
_br_taken_11:
    slt x27, x21, x14
_br_done_11:
    sraw x27, x1, x19
    xor x10, x7, x24
    slti x18, x21, 1344
    addiw x25, x9, 1845
    addw x9, x4, x4
    srliw x19, x13, 29
    sub x7, x17, x26
    xori x26, x22, 1805
    srliw x10, x10, 22
    srli x20, x1, 42
    andi x14, x8, 2013
    srli x18, x21, 47
    sll x20, x21, x12
    lw x5, 152(x31)
    sw x16, 152(x31)
    sllw x21, x4, x23
    sra x12, x1, x20
    divu x22, x10, x11
    addiw x7, x14, -1656
    srl x16, x17, x27
    addi x8, x24, 785
    bne x16, x11, _br_taken_12
    add x13, x1, x7
    j _br_done_12
_br_taken_12:
    xor x13, x21, x28
_br_done_12:
    sub x14, x26, x14
    slti x29, x7, -1746
    lhu x9, 36(x31)
    sh x27, 36(x31)
    bltu x19, x23, _br_taken_13
    xor x5, x11, x7
    j _br_done_13
_br_taken_13:
    sub x5, x8, x28
_br_done_13:
    sltiu x23, x8, -62
    xor x4, x25, x1
    slliw x12, x14, 6
    fmin.s f3, f1, f21
    fnmsub.s f12, f15, f15, f0
    srli x7, x7, 3
    subw x11, x18, x25
    fmul.d f29, f14, f26
    mulw x19, x13, x15
    divu x9, x18, x12
    bne x14, x6, _br_taken_14
    and x20, x9, x11
    j _br_done_14
_br_taken_14:
    sub x20, x20, x24
_br_done_14:
    lw x7, 292(x31)
    sw x16, 292(x31)
    bgeu x15, x19, _br_taken_15
    sra x6, x1, x5
    j _br_done_15
_br_taken_15:
    and x6, x11, x19
_br_done_15:
    bne x20, x7, _br_taken_16
    sltu x17, x14, x17
    j _br_done_16
_br_taken_16:
    add x17, x18, x24
_br_done_16:
    addiw x9, x24, -694
    xor x17, x5, x20
    ori x17, x5, 162
    bgeu x26, x9, _br_taken_17
    sll x12, x12, x18
    j _br_done_17
_br_taken_17:
    or x12, x14, x25
_br_done_17:
    add x6, x29, x26
    slliw x11, x19, 3
    sraw x23, x12, x23
    xor x18, x8, x1
    fmin.d f4, f15, f5
    fmax.d f28, f10, f10
    fnmadd.s f27, f24, f7, f28
    sraw x22, x14, x9
    sra x14, x12, x19
    srliw x22, x14, 0
    sub x7, x8, x17
    bltu x18, x17, _br_taken_18
    add x13, x27, x20
    j _br_done_18
_br_taken_18:
    sltu x13, x26, x6
_br_done_18:
    fmsub.d f0, f2, f4, f24
    fmin.s f12, f14, f17
    srliw x22, x5, 24
    sraw x22, x20, x25
    slliw x5, x20, 11
    addi x15, x29, -1127
    mulw x23, x14, x4
    mulh x12, x18, x19
    fadd.s f16, f22, f27
    fmul.s f23, f3, f29
    sra x26, x7, x11
    slli x17, x5, 16
    blt x16, x21, _br_taken_19
    and x17, x29, x7
    j _br_done_19
_br_taken_19:
    sra x17, x15, x1
_br_done_19:
    srli x20, x18, 39
    slti x28, x7, -1714
    xor x16, x22, x10
    slli x16, x27, 2
    xori x5, x4, -1388
    sra x21, x19, x18
    or x5, x24, x24
    srai x16, x6, 35
    ori x11, x6, -1998
    sra x9, x22, x26
    bne x14, x25, _br_taken_20
    sll x4, x11, x10
    j _br_done_20
_br_taken_20:
    slt x4, x28, x20
_br_done_20:
    ld x6, 1000(x31)
    sd x13, 1000(x31)
    bge x23, x7, _br_taken_21
    and x26, x14, x29
    j _br_done_21
_br_taken_21:
    xor x26, x22, x7
_br_done_21:
    lbu x1, 1000(x31)
    sb x28, 1000(x31)
    fmin.s f28, f20, f26
    rem x11, x20, x7
    mulh x21, x14, x23
    bgeu x25, x13, _br_taken_22
    slt x23, x13, x19
    j _br_done_22
_br_taken_22:
    and x23, x29, x8
_br_done_22:
    mulhu x15, x24, x4
    mul x10, x13, x8
    srliw x19, x26, 27
    remuw x21, x10, x13
    remw x14, x6, x17
    or x1, x9, x14
    subw x29, x14, x5
    sraiw x29, x26, 2
    lb x21, 248(x31)
    sb x17, 248(x31)
    srl x22, x4, x23
    srai x16, x8, 53
    fsub.s f20, f14, f20
    addi x30, x31, 684
    amoswap.w x9, x15, (x30)
    lwu x12, 840(x31)
    sw x28, 840(x31)
    ld x8, 472(x31)
    sd x17, 472(x31)
    addi x30, x31, 888
    amoadd.d x20, x22, (x30)
    sra x22, x14, x28
    mulw x4, x10, x29
    bge x11, x10, _br_taken_23
    sll x4, x9, x15
    j _br_done_23
_br_taken_23:
    sll x4, x19, x26
_br_done_23:
    fdiv.s f12, f16, f11
    fadd.s f9, f26, f28
    sltiu x27, x8, -263
    sll x13, x28, x17
    sll x18, x1, x17
    xor x21, x19, x22
    slliw x7, x9, 13
    slli x10, x7, 42
    sraiw x13, x27, 20
    srli x18, x14, 9
    slli x23, x15, 20
    addiw x13, x6, -1834
    bne x23, x29, _br_taken_24
    srl x16, x16, x12
    j _br_done_24
_br_taken_24:
    sll x16, x15, x13
_br_done_24:
    sllw x28, x20, x6
    slli x16, x23, 15
    slt x17, x19, x25
    or x8, x4, x9
    sraw x11, x9, x19
    div x27, x7, x6
    div x1, x20, x17
    bne x11, x11, _br_taken_25
    srl x16, x22, x22
    j _br_done_25
_br_taken_25:
    sub x16, x15, x29
_br_done_25:
    lbu x22, 648(x31)
    sb x5, 648(x31)
    lwu x14, 756(x31)
    sw x8, 756(x31)
    addi x21, x11, 673
    sraiw x19, x4, 18
    srlw x25, x28, x7
    addw x12, x23, x4
    sll x26, x5, x19
    andi x23, x13, 549
    andi x15, x7, -1018
    andi x20, x6, -999
    beq x16, x11, _br_taken_26
    sub x14, x29, x15
    j _br_done_26
_br_taken_26:
    and x14, x12, x25
_br_done_26:
    fsub.s f24, f3, f22
    fdiv.s f2, f18, f4
    fadd.s f15, f0, f31
    lhu x4, 444(x31)
    sh x1, 444(x31)
    sraw x15, x14, x19
    add x21, x22, x9
    or x1, x17, x25
    addi x30, x31, 644
    amoor.w x24, x16, (x30)
    sub x24, x29, x11
    srl x29, x9, x28
    sraiw x5, x5, 5
    lw x23, 908(x31)
    sw x22, 908(x31)
    slliw x1, x26, 20
    andi x26, x4, -1614
    or x8, x19, x16
    srl x24, x1, x1
    add x24, x16, x5
    sltiu x4, x15, 1907
    slti x17, x15, 1930
    addiw x27, x25, -491
    addi x30, x31, 16
    amoadd.w x19, x5, (x30)
    sub x13, x9, x12
    slt x11, x10, x12
    fmul.s f28, f19, f7
    sraiw x5, x1, 4
    addiw x26, x21, 1058
    xor x27, x25, x25
    xor x11, x10, x18
    mulh x26, x11, x9
    sll x26, x8, x28
    bgeu x17, x17, _br_taken_27
    srl x5, x11, x24
    j _br_done_27
_br_taken_27:
    add x5, x28, x12
_br_done_27:
    xori x11, x9, -362
    sltu x27, x7, x4
    srl x1, x6, x1
    addi x16, x26, -637
    srai x1, x26, 16
    sraw x18, x25, x15
    bge x1, x6, _br_taken_28
    sub x29, x29, x24
    j _br_done_28
_br_taken_28:
    add x29, x16, x25
_br_done_28:
    srli x24, x20, 27
    addi x30, x31, 320
    amomin.d x9, x21, (x30)
    ld x8, 112(x31)
    sd x28, 112(x31)
    fmul.d f19, f14, f14
    sub x15, x10, x17
    fadd.s f25, f15, f11
    fadd.s f2, f5, f20
    fnmsub.d f16, f8, f22, f18
    fmin.s f15, f10, f10
    fdiv.d f12, f9, f26
    fsub.d f18, f28, f26
    andi x25, x26, 1348
    lwu x16, 148(x31)
    sw x6, 148(x31)
    slliw x6, x1, 28
    subw x21, x15, x20
    blt x15, x20, _br_taken_29
    slt x28, x19, x6
    j _br_done_29
_br_taken_29:
    sll x28, x20, x14
_br_done_29:
    blt x21, x29, _br_taken_30
    sll x17, x23, x11
    j _br_done_30
_br_taken_30:
    and x17, x23, x27
_br_done_30:
    remu x26, x12, x14
    divu x20, x9, x16
    addi x19, x9, -773
    xor x12, x10, x1
    srai x6, x17, 43
    remw x26, x8, x20
    srai x18, x12, 8
    sll x28, x20, x19
    addw x29, x23, x15
    sraiw x23, x11, 1
    srl x12, x29, x21
    mulhsu x13, x8, x15
    slli x25, x14, 24
    bgeu x11, x8, _br_taken_31
    slt x27, x24, x21
    j _br_done_31
_br_taken_31:
    xor x27, x10, x1
_br_done_31:
    beq x28, x18, _br_taken_32
    add x12, x18, x15
    j _br_done_32
_br_taken_32:
    sltu x12, x5, x12
_br_done_32:
    xor x10, x20, x7
    srliw x27, x26, 11
    sltu x25, x5, x13
    addi x30, x31, 756
    amoswap.w x6, x29, (x30)
    bge x12, x5, _br_taken_33
    and x23, x8, x1
    j _br_done_33
_br_taken_33:
    sra x23, x18, x25
_br_done_33:
    srliw x8, x20, 23
    xor x6, x22, x10
    addiw x16, x8, -963
    lb x26, 244(x31)
    sb x17, 244(x31)
    addi x30, x31, 264
    amomin.d x24, x17, (x30)
    andi x8, x16, -1592
    fdiv.s f2, f7, f15
    fnmadd.s f7, f6, f3, f11
    sltu x6, x21, x13
    and x16, x21, x25
    ori x26, x12, -98
    xor x13, x15, x17
    andi x20, x16, -1967
    slliw x27, x12, 25
    ori x19, x22, 203
    sraiw x10, x9, 6
    srl x28, x13, x14
    remu x5, x23, x25
    andi x12, x10, 1431
    slliw x12, x14, 15
    slliw x29, x18, 16
    sraiw x8, x9, 21
    ld x14, 640(x31)
    sd x15, 640(x31)
    sltu x18, x28, x20
    srliw x10, x29, 24

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xbd8240f2570d6880
    .dword 0xf2943c17f49d5e78
    .dword 0xbebb98f06c99872b
    .dword 0xafcc8c009e35d701
    .dword 0x2ab7eb32e821a2e4
    .dword 0x086a1fe05db2c693
    .dword 0x46723bf9cf07c4b3
    .dword 0xc01f56c4f73af9a2
    .dword 0xd1e972c6039610f5
    .dword 0x3d905f8d6ba223c0
    .dword 0xcc58fd3ec433e3e5
    .dword 0xf0cfd18bff427614
    .dword 0x5ef6a3ba533c25a1
    .dword 0xf45c92a12e08fbd5
    .dword 0x60910e8c19ad1843
    .dword 0x727beab73c5eebda
    .dword 0x89ee7367766429ec
    .dword 0x3f1227721551fda1
    .dword 0x57d087fed1c478b3
    .dword 0xa3704f46e9113d47
    .dword 0x89d7102ef2cc31d9
    .dword 0xf4ae8fcbad13b2d5
    .dword 0x0540a384b4e75cce
    .dword 0x4526dc8e5cee9ac1
    .dword 0xf95e7d66add10e31
    .dword 0x8c1a2da00e39f388
    .dword 0xf6b81f37405aeabc
    .dword 0x41f8f5b2cf37c96f
    .dword 0x2488cc10935cca70
    .dword 0x908d2d136950b16c
    .dword 0x7f754200c5cf692c
    .dword 0x7167203169700edf

    .align 2
_torture_data:
    .word 0x7e9eb715
    .word 0x14939209
    .word 0xb2a69c9f
    .word 0x802f300f
    .word 0xea980928
    .word 0x8577c567
    .word 0xbf29fcda
    .word 0x85701d48
    .word 0x2ad85bd5
    .word 0xd673c30e
    .word 0x2c20e2ab
    .word 0x4194a73b
    .word 0x19e36b5c
    .word 0x830b46c0
    .word 0x48496f53
    .word 0x4f9e4dbc
    .word 0x7e6f1210
    .word 0xe9e7d6d2
    .word 0x978dec49
    .word 0x453f46ee
    .word 0x7711ebc0
    .word 0x5e1198c1
    .word 0xaedb06bc
    .word 0x2ccd04cd
    .word 0xccf3053d
    .word 0x85678a67
    .word 0xff18a09e
    .word 0x1d4360c0
    .word 0xd7fc88eb
    .word 0x208a446b
    .word 0x481ef3d5
    .word 0x447cea2c
    .word 0xf441318d
    .word 0x7db3a7dc
    .word 0xd9a844b5
    .word 0xae12dbee
    .word 0xb347414f
    .word 0x1260ecd4
    .word 0x8983d703
    .word 0x89be2860
    .word 0xdfef0cb9
    .word 0x9631288b
    .word 0x3ea4472f
    .word 0xea0a3023
    .word 0xaf8c0c29
    .word 0x2e2482f9
    .word 0x4ef26e0c
    .word 0xd86fd566
    .word 0x9c355c0d
    .word 0xbb14e4a0
    .word 0x656ee404
    .word 0x63c1fa42
    .word 0x3ee82ade
    .word 0x3ffe925c
    .word 0xa9ca627a
    .word 0xf6422af3
    .word 0xbd972163
    .word 0xc9b31814
    .word 0x006afaa0
    .word 0xdaab196f
    .word 0xde58e533
    .word 0xd59bc756
    .word 0xd242db22
    .word 0x59a64c26
    .word 0xb28da4b8
    .word 0xe5037b54
    .word 0xa880fabe
    .word 0xb595cfe3
    .word 0x2fae5c6f
    .word 0x10df875a
    .word 0xbaec5030
    .word 0xdf821949
    .word 0x185e694b
    .word 0x736d4098
    .word 0x2abba37f
    .word 0x49d1b34d
    .word 0x3b3ecc62
    .word 0xea94424c
    .word 0x644ee10d
    .word 0x0eb2a8df
    .word 0x8616e772
    .word 0x6007547e
    .word 0xd55fb721
    .word 0xd502f8c0
    .word 0x8d4e29c1
    .word 0xda07bd4d
    .word 0xd5a79682
    .word 0xa8bb8718
    .word 0x2e289b85
    .word 0xa1dc90c2
    .word 0xc5ebe34f
    .word 0x9b20c597
    .word 0x272acf36
    .word 0xf0b93ad0
    .word 0xe91b0470
    .word 0x6b5d6519
    .word 0xed2ff9af
    .word 0xd6574cdf
    .word 0x57a34adf
    .word 0x2af21b6f
    .word 0x7a04728e
    .word 0x3842cc28
    .word 0x16a55ae9
    .word 0x0e3d0ff9
    .word 0x34a5e814
    .word 0x2cafd691
    .word 0x90c0115f
    .word 0x470deb8a
    .word 0x647213f7
    .word 0x43a8591e
    .word 0xf963ee9b
    .word 0x0cdd6c96
    .word 0xc8e26f0a
    .word 0x041e13c5
    .word 0xb53c2e0c
    .word 0x10a4da8f
    .word 0xb894b2b4
    .word 0x534d88cc
    .word 0x9bd62f3d
    .word 0x51acc83e
    .word 0x549d1219
    .word 0x30c5e300
    .word 0xcf62da56
    .word 0x7e9c488f
    .word 0xa94efc93
    .word 0x28533e0a
    .word 0xa3e0e0b4
    .word 0x11413c65
    .word 0x8b2b067d
    .word 0xa3b6d3bc
    .word 0x2357d3d7
    .word 0x8e053df1
    .word 0xef67dbbe
    .word 0xc76b3074
    .word 0xa4480595
    .word 0x9fefaf4d
    .word 0x61b42fef
    .word 0x4f5af6c9
    .word 0xba40cbdf
    .word 0xdfe6993b
    .word 0x08d9f1d0
    .word 0x4656da49
    .word 0x3f9ca9e7
    .word 0x0db64efa
    .word 0x993c7aee
    .word 0x171e1517
    .word 0x680e141d
    .word 0xcf0924b3
    .word 0xfd8ba520
    .word 0xa2271e57
    .word 0x0a12fcb1
    .word 0x1cc25dd9
    .word 0x5ee692b2
    .word 0x0c310ce4
    .word 0x2a9a0081
    .word 0xdb97bb84
    .word 0xf8a118fe
    .word 0x97aa05fa
    .word 0xceb2239d
    .word 0x3e55b800
    .word 0xa4cecd32
    .word 0x364a5fcd
    .word 0x675b26dd
    .word 0xa3aae7f7
    .word 0x34432230
    .word 0x37afb412
    .word 0x6c46de53
    .word 0x6918db15
    .word 0x20432fd8
    .word 0xfc981d7d
    .word 0xcf33b23b
    .word 0xb220bd00
    .word 0x40b6cec1
    .word 0xa75291da
    .word 0x189f416d
    .word 0x065bfa83
    .word 0x6df00c36
    .word 0x4c4327d7
    .word 0x25fe97db
    .word 0x229a8cc2
    .word 0x1c838a79
    .word 0x416a514b
    .word 0xbf86415f
    .word 0xc5ffa236
    .word 0xbb14775b
    .word 0x7e683901
    .word 0xec3c2093
    .word 0xb0257953
    .word 0x5502dfbf
    .word 0x7bb91b56
    .word 0xd6702228
    .word 0xea022415
    .word 0x12eae103
    .word 0x06232868
    .word 0x438d12c9
    .word 0x8e119d95
    .word 0xd9d01d61
    .word 0xeb76f11e
    .word 0xc4ea8ab6
    .word 0x1cb49e16
    .word 0xca6ebb80
    .word 0x1956b2e8
    .word 0x27491b0d
    .word 0xde6575f1
    .word 0xe1ffe9f6
    .word 0x10d025a9
    .word 0xf131f006
    .word 0x9185eda4
    .word 0xeb02ea21
    .word 0x53eb0174
    .word 0x33bce4cd
    .word 0x37ad5c27
    .word 0x6b214d14
    .word 0xcfd7dd86
    .word 0x78fe8687
    .word 0x7caf6564
    .word 0x1b7fa0c0
    .word 0xf9eb0d50
    .word 0x44789fef
    .word 0x31fef54a
    .word 0xbd7f0ed7
    .word 0x828add36
    .word 0x91373e1a
    .word 0xbf0210e9
    .word 0x4e6bd80e
    .word 0xdaa713d5
    .word 0x1afee467
    .word 0xbb983ac0
    .word 0xbdf8639c
    .word 0xbc06704f
    .word 0xd0a425e1
    .word 0x0d77f2ad
    .word 0x383628f4
    .word 0x42d925c4
    .word 0xa861983f
    .word 0x396f9236
    .word 0x253e31c6
    .word 0x3596cfa5
    .word 0x3cf2dbe3
    .word 0x5f11c82c
    .word 0x0b22f943
    .word 0xf5de6ae0
    .word 0x70d619e9
    .word 0x19c22f02
    .word 0xc4e91775
    .word 0x9175851c
    .word 0x2d70445c
    .word 0xec5d64ba
    .word 0xe6f20791
    .word 0x818c5bc4
    .word 0x24fda59f
    .word 0xa9a90492
    .word 0x7e3cd1f0
    .word 0x742812f2
    .word 0xd6ca2654
    .word 0xf2990625

#include "frost_footer.S"
