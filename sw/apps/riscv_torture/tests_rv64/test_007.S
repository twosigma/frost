// Generated RV64IMAFDC torture test for Frost (seed=20260809)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xd9aa44681705a622
    li x4, 0x192087a907474c9b
    li x5, 0x349df3ab1ede0533
    li x6, 0x31503fde5b220406
    li x7, 0x1aa19a70c26114cb
    li x8, 0x27c3430cc2ee2ef1
    li x9, 0xcddfc1e485db5d77
    li x10, 0xcf9fa29811dada24
    li x11, 0x53b0d10b3670eeea
    li x12, 0x862aeaf37d94090e
    li x13, 0xf88d9d203726a420
    li x14, 0xd3f67d17086747ff
    li x15, 0xc501c07b3818ad9d
    li x16, 0xe9a52d46ffa371bf
    li x17, 0x2a7584e02fb28e16
    li x18, 0xf2712407b9f21f97
    li x19, 0x30b94de8a1f556b2
    li x20, 0x72a240bf3fe430de
    li x21, 0x800aa0d98efd6041
    li x22, 0x345665d33801130f
    li x23, 0x5238b98839c09f9d
    li x24, 0xb7763271b943cdb3
    li x25, 0xabb34d8bea40fff2
    li x26, 0x37ed5ca7f599e286
    li x27, 0x5335ca7bef1515fc
    li x28, 0x3e7cee6db11e3d95
    li x29, 0xe2efc511c32269a8
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
    li x1, 0x3ec7122c75fe1f90

    fsub.d f17, f1, f3
    addw x26, x15, x9
    slli x13, x16, 32
    slti x23, x6, -355
    srlw x9, x14, x14
    sra x13, x28, x17
    bge x17, x15, _br_taken_0
    sll x25, x5, x24
    j _br_done_0
_br_taken_0:
    sltu x25, x29, x7
_br_done_0:
    slti x13, x14, -647
    slli x24, x13, 46
    srliw x7, x4, 20
    sraw x12, x28, x8
    addi x30, x31, 632
    amomax.d x7, x19, (x30)
    fmin.s f0, f24, f28
    fmax.s f20, f8, f24
    slli x27, x17, 58
    sub x10, x22, x27
    sll x4, x13, x5
    fmax.s f28, f29, f9
    fmsub.d f25, f25, f29, f7
    fnmadd.d f1, f24, f25, f5
    lh x22, 140(x31)
    sh x24, 140(x31)
    lhu x18, 440(x31)
    sh x20, 440(x31)
    and x9, x22, x13
    sraiw x7, x5, 29
    xor x7, x16, x28
    addi x30, x31, 364
    amomax.w x23, x18, (x30)
    sllw x4, x28, x29
    fnmadd.s f14, f5, f26, f6
    fmul.s f18, f24, f1
    lbu x16, 908(x31)
    sb x22, 908(x31)
    lwu x28, 628(x31)
    sw x19, 628(x31)
    slt x27, x18, x17
    sll x16, x13, x7
    sraw x19, x22, x26
    srliw x29, x9, 27
    blt x20, x5, _br_taken_1
    and x28, x24, x17
    j _br_done_1
_br_taken_1:
    xor x28, x14, x4
_br_done_1:
    xor x15, x6, x24
    sraw x23, x6, x9
    sll x24, x4, x4
    xor x15, x18, x13
    slti x25, x24, 1790
    addi x22, x27, 1625
    bgeu x28, x19, _br_taken_2
    sra x6, x11, x23
    j _br_done_2
_br_taken_2:
    sll x6, x18, x9
_br_done_2:
    srli x15, x20, 0
    xori x12, x28, 656
    mulh x10, x10, x15
    blt x5, x17, _br_taken_3
    and x12, x29, x7
    j _br_done_3
_br_taken_3:
    sltu x12, x6, x15
_br_done_3:
    bge x17, x12, _br_taken_4
    add x12, x19, x9
    j _br_done_4
_br_taken_4:
    sra x12, x18, x13
_br_done_4:
    slli x29, x6, 61
    slti x9, x17, 614
    sraiw x14, x13, 14
    divuw x27, x15, x5
    rem x29, x9, x24
    addi x30, x31, 336
    amoxor.d x7, x12, (x30)
    fmax.s f18, f5, f6
    and x12, x27, x21
    bne x8, x8, _br_taken_5
    srl x19, x1, x9
    j _br_done_5
_br_taken_5:
    sltu x19, x29, x21
_br_done_5:
    blt x4, x28, _br_taken_6
    xor x8, x17, x9
    j _br_done_6
_br_taken_6:
    sra x8, x26, x10
_br_done_6:
    subw x7, x28, x29
    srliw x14, x16, 5
    or x9, x19, x1
    slt x10, x23, x8
    srli x29, x29, 21
    addiw x12, x8, -1342
    srlw x12, x14, x22
    xori x15, x24, 98
    slt x1, x27, x12
    srliw x29, x8, 24
    addi x29, x6, -1226
    ld x7, 992(x31)
    sd x15, 992(x31)
    slliw x4, x27, 28
    div x1, x14, x27
    mulhu x16, x7, x12
    or x19, x14, x9
    sra x13, x15, x28
    blt x6, x7, _br_taken_7
    sub x17, x12, x1
    j _br_done_7
_br_taken_7:
    srl x17, x28, x4
_br_done_7:
    bltu x21, x19, _br_taken_8
    xor x29, x18, x11
    j _br_done_8
_br_taken_8:
    sll x29, x4, x22
_br_done_8:
    bne x10, x19, _br_taken_9
    sra x6, x17, x19
    j _br_done_9
_br_taken_9:
    and x6, x29, x22
_br_done_9:
    blt x5, x8, _br_taken_10
    and x12, x10, x27
    j _br_done_10
_br_taken_10:
    sltu x12, x16, x17
_br_done_10:
    addi x30, x31, 820
    amoadd.w x27, x27, (x30)
    ori x19, x11, 1524
    or x13, x1, x23
    andi x1, x13, -448
    srlw x8, x18, x4
    addi x24, x12, -364
    sllw x12, x16, x6
    slliw x18, x17, 29
    addiw x20, x19, -767
    ori x1, x18, -1720
    slliw x17, x8, 23
    fmin.s f18, f10, f4
    fmax.s f4, f8, f2
    fmul.s f18, f2, f24
    sraw x5, x20, x26
    sltiu x29, x27, -1277
    andi x14, x22, -1290
    sub x12, x15, x20
    bgeu x11, x21, _br_taken_11
    sra x28, x23, x25
    j _br_done_11
_br_taken_11:
    sll x28, x29, x7
_br_done_11:
    mulhu x4, x13, x24
    fdiv.s f0, f8, f4
    fadd.d f2, f10, f21
    fmul.s f14, f8, f22
    slli x16, x15, 39
    sraiw x4, x1, 31
    and x23, x9, x20
    ld x15, 696(x31)
    sd x25, 696(x31)
    addi x16, x6, -600
    sraw x4, x9, x4
    or x7, x29, x6
    addi x25, x11, -530
    bltu x10, x28, _br_taken_12
    srl x17, x16, x20
    j _br_done_12
_br_taken_12:
    sltu x17, x16, x25
_br_done_12:
    sll x27, x26, x13
    addi x30, x31, 620
    amomin.w x16, x14, (x30)
    fsub.d f6, f17, f2
    addi x30, x31, 608
    amoxor.w x20, x7, (x30)
    addiw x9, x4, -906
    addw x29, x6, x9
    and x27, x13, x24
    and x9, x21, x7
    srai x24, x14, 50
    addiw x6, x18, -562
    slt x8, x9, x13
    and x13, x10, x7
    subw x23, x17, x18
    addi x30, x31, 880
    amoxor.d x28, x29, (x30)
    addi x16, x21, 1567
    subw x14, x14, x13
    sllw x16, x11, x1
    andi x5, x21, -608
    bltu x16, x12, _br_taken_13
    or x23, x18, x26
    j _br_done_13
_br_taken_13:
    add x23, x19, x28
_br_done_13:
    beq x12, x10, _br_taken_14
    sltu x26, x21, x1
    j _br_done_14
_br_taken_14:
    xor x26, x24, x22
_br_done_14:
    beq x5, x29, _br_taken_15
    sltu x8, x4, x18
    j _br_done_15
_br_taken_15:
    add x8, x24, x18
_br_done_15:
    beq x23, x18, _br_taken_16
    srl x23, x13, x24
    j _br_done_16
_br_taken_16:
    xor x23, x14, x8
_br_done_16:
    rem x18, x21, x1
    xori x20, x8, 400
    addiw x1, x18, 1703
    bne x17, x11, _br_taken_17
    sub x8, x12, x27
    j _br_done_17
_br_taken_17:
    and x8, x27, x19
_br_done_17:
    slli x10, x20, 52
    sltu x20, x9, x20
    fdiv.s f29, f2, f16
    fdiv.d f8, f6, f10
    addiw x21, x21, 357
    xor x16, x18, x17
    sraiw x26, x11, 22
    sra x14, x13, x18
    mulhu x18, x25, x16
    addi x11, x7, -777
    add x15, x20, x19
    fmax.s f7, f7, f7
    fmadd.d f16, f12, f4, f0
    fmin.s f7, f27, f6
    bgeu x24, x22, _br_taken_18
    sll x22, x8, x26
    j _br_done_18
_br_taken_18:
    or x22, x22, x13
_br_done_18:
    ori x5, x17, 1674
    sltiu x17, x28, -1766
    slliw x28, x23, 27
    addi x30, x31, 896
    amoswap.w x5, x28, (x30)
    ori x23, x5, -515
    sraiw x27, x11, 1
    sll x21, x11, x15
    slti x11, x20, 457
    sra x15, x18, x17
    slli x16, x10, 21
    lbu x7, 380(x31)
    sb x24, 380(x31)
    lbu x9, 948(x31)
    sb x24, 948(x31)
    slliw x11, x8, 22
    addiw x6, x9, 251
    sraw x6, x10, x28
    xor x25, x17, x6
    xor x8, x7, x5
    blt x9, x10, _br_taken_19
    sra x8, x15, x21
    j _br_done_19
_br_taken_19:
    sll x8, x9, x6
_br_done_19:
    xor x28, x13, x11
    addi x30, x31, 144
    amoadd.d x16, x29, (x30)
    slli x16, x6, 22
    ori x22, x1, 1788
    srlw x9, x1, x7
    add x10, x17, x26
    addw x27, x7, x6
    ld x25, 304(x31)
    sd x29, 304(x31)
    addw x18, x29, x12
    xor x21, x5, x8
    addi x30, x31, 864
    amominu.d x6, x23, (x30)
    slliw x13, x7, 24
    sra x8, x25, x11
    or x23, x7, x11
    fmax.d f26, f13, f1
    add x14, x19, x25
    slliw x14, x15, 29
    sraw x16, x14, x8
    sub x12, x26, x29
    srli x24, x26, 52
    bge x24, x14, _br_taken_20
    or x14, x29, x5
    j _br_done_20
_br_taken_20:
    sra x14, x25, x16
_br_done_20:
    blt x12, x14, _br_taken_21
    sra x9, x6, x25
    j _br_done_21
_br_taken_21:
    srl x9, x29, x12
_br_done_21:
    bgeu x14, x22, _br_taken_22
    srl x11, x23, x16
    j _br_done_22
_br_taken_22:
    slt x11, x18, x10
_br_done_22:
    sll x13, x16, x26
    sll x19, x15, x14
    addw x9, x25, x9
    ld x25, 40(x31)
    sd x22, 40(x31)
    sra x29, x13, x29
    slt x1, x16, x25
    sra x19, x14, x11
    srliw x17, x8, 19
    blt x26, x27, _br_taken_23
    sub x10, x1, x27
    j _br_done_23
_br_taken_23:
    xor x10, x17, x11
_br_done_23:
    slti x17, x17, 1414
    or x19, x20, x19
    slliw x6, x6, 29
    beq x21, x9, _br_taken_24
    and x27, x27, x18
    j _br_done_24
_br_taken_24:
    srl x27, x22, x5
_br_done_24:
    lw x5, 64(x31)
    sw x14, 64(x31)
    fmin.s f19, f2, f22
    mulh x4, x11, x20
    lhu x22, 804(x31)
    sh x19, 804(x31)
    addiw x10, x19, -975
    sltu x8, x21, x13
    srai x8, x1, 33
    sll x15, x24, x11
    ori x23, x22, 311
    srli x9, x12, 58
    beq x26, x7, _br_taken_25
    slt x9, x10, x28
    j _br_done_25
_br_taken_25:
    srl x9, x21, x10
_br_done_25:
    fmsub.s f6, f18, f31, f8
    fnmsub.s f28, f22, f5, f11
    addi x4, x4, 697
    sra x17, x22, x22
    sraiw x9, x9, 2
    sub x11, x4, x21
    subw x26, x10, x7
    srai x25, x21, 4
    lwu x23, 192(x31)
    sw x15, 192(x31)
    srliw x6, x17, 19
    divuw x16, x8, x20
    xori x22, x8, -1424
    lhu x7, 356(x31)
    sh x17, 356(x31)
    fmax.s f29, f20, f23
    fmsub.s f3, f8, f14, f29
    add x24, x26, x15
    srliw x5, x6, 29
    slliw x26, x15, 27
    srliw x6, x11, 25
    slliw x22, x1, 23
    andi x13, x26, 1010
    srliw x9, x4, 14
    sll x25, x18, x11
    slt x26, x11, x13
    addi x30, x31, 704
    amomin.w x24, x23, (x30)
    fnmadd.s f8, f29, f13, f19
    fdiv.d f25, f24, f4
    fnmsub.d f4, f13, f12, f4
    sraiw x13, x22, 15
    mulh x26, x17, x25
    mul x25, x8, x25
    ori x5, x23, -1148
    sra x29, x27, x12
    addi x30, x31, 728
    amomaxu.w x22, x23, (x30)
    sltu x21, x27, x4
    or x18, x27, x9
    slt x13, x15, x9
    addw x16, x5, x17
    sra x6, x26, x13
    srai x18, x22, 6
    sllw x29, x6, x5
    fmax.d f17, f16, f15
    fmul.d f25, f17, f18
    fsub.s f2, f11, f8
    ori x12, x28, -160
    blt x11, x11, _br_taken_26
    and x8, x6, x27
    j _br_done_26
_br_taken_26:
    sll x8, x25, x13
_br_done_26:
    srliw x28, x17, 6
    addiw x11, x17, 338
    sra x6, x18, x14
    sltu x22, x7, x27
    bltu x7, x15, _br_taken_27
    sltu x26, x10, x6
    j _br_done_27
_br_taken_27:
    xor x26, x24, x5
_br_done_27:
    slli x5, x28, 10
    lw x18, 676(x31)
    sw x21, 676(x31)
    bgeu x14, x12, _br_taken_28
    sll x9, x11, x1
    j _br_done_28
_br_taken_28:
    xor x9, x18, x17
_br_done_28:
    bne x8, x1, _br_taken_29
    add x27, x28, x13
    j _br_done_29
_br_taken_29:
    srl x27, x15, x24
_br_done_29:
    addi x30, x31, 136
    amoswap.w x14, x29, (x30)
    sllw x14, x21, x13
    sllw x15, x24, x13
    srlw x11, x27, x25
    addw x5, x4, x28
    and x19, x21, x10
    sltiu x22, x27, 1997
    or x25, x5, x23
    sltiu x9, x9, -1639
    lb x5, 204(x31)
    sb x8, 204(x31)
    divuw x19, x13, x18
    mulh x27, x7, x5
    fsub.s f5, f8, f26
    fnmadd.d f21, f26, f2, f8
    sub x14, x1, x24
    and x22, x22, x22
    addi x13, x22, 0
    bge x29, x7, _br_taken_30
    slt x11, x12, x11
    j _br_done_30
_br_taken_30:
    slt x11, x21, x10
_br_done_30:
    add x17, x13, x8
    addw x19, x21, x22
    sub x8, x26, x28
    srliw x28, x12, 17
    slti x13, x21, 483
    xori x14, x27, 1268
    srl x16, x12, x6
    addiw x24, x19, 649
    sllw x16, x25, x8
    srl x13, x24, x4
    fsub.d f25, f10, f4
    beq x29, x5, _br_taken_31
    xor x6, x23, x5
    j _br_done_31
_br_taken_31:
    and x6, x12, x22
_br_done_31:
    srlw x4, x18, x7
    slliw x16, x4, 3
    bge x6, x29, _br_taken_32
    or x7, x12, x11
    j _br_done_32
_br_taken_32:
    sra x7, x23, x23
_br_done_32:
    sll x19, x16, x28
    fmul.d f13, f26, f6
    fsub.s f15, f20, f23
    fdiv.s f19, f1, f0
    remuw x4, x15, x27
    remuw x4, x12, x26
    sra x4, x11, x4
    beq x24, x29, _br_taken_33
    sltu x20, x12, x14
    j _br_done_33
_br_taken_33:
    sll x20, x9, x1
_br_done_33:
    subw x20, x27, x18
    slli x18, x16, 46
    add x11, x4, x5
    sraiw x5, x11, 25
    srai x23, x28, 50
    srliw x18, x10, 7
    ld x29, 216(x31)
    sd x11, 216(x31)
    remu x11, x8, x6
    divuw x23, x29, x18
    sraw x10, x9, x17
    slti x15, x29, 867
    sllw x6, x21, x8

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xcecf44e4eab4535d
    .dword 0x7d04755330e8228d
    .dword 0xc32e66c4010a4478
    .dword 0xd321169bdda4e7eb
    .dword 0x8d1054303b43cd63
    .dword 0xc9c53a9b0620f7c5
    .dword 0xbdba24a2e3c26f22
    .dword 0x4b6f50a00bc27dd7
    .dword 0x87c6e22176bd6c15
    .dword 0x0841e27a29e0b6f8
    .dword 0xb7ae6f6e55547723
    .dword 0xca8aeaf6607ddfcd
    .dword 0x1752708848c77605
    .dword 0x18036d9a1c8771ab
    .dword 0x0b52ad53111c4583
    .dword 0x26f41297dd1c24a7
    .dword 0x11c65e348b958593
    .dword 0xf4077b46521fbf72
    .dword 0x2325708123f9efac
    .dword 0xf12582e5a04b3f85
    .dword 0x69eaae9c92ce9e6d
    .dword 0x4feccffc1772173c
    .dword 0x8f1280db2adbbbf5
    .dword 0x4099f96f518be04d
    .dword 0x8cae1fc89de16de9
    .dword 0x4187f6c8d57d12d2
    .dword 0x6c049b6291e6cb86
    .dword 0x3bcfdfa6ed8dc1f9
    .dword 0xada312120601c2fc
    .dword 0x3352026241ad287a
    .dword 0xb6909fba083f8a7c
    .dword 0xfca5588e017ded25

    .align 2
_torture_data:
    .word 0x5a9815a0
    .word 0xd260e9d3
    .word 0x5c150467
    .word 0x309f750f
    .word 0xa4d82273
    .word 0x571c069e
    .word 0xe4d06568
    .word 0xed03c6c2
    .word 0x0fbc3a83
    .word 0x94f96ce6
    .word 0xfe4adfd0
    .word 0x93dbaa59
    .word 0xcf2e04b4
    .word 0xdce7dcdd
    .word 0x99fee3ea
    .word 0x9fb98723
    .word 0xbf8e65f7
    .word 0x9da5f844
    .word 0x4acc4b01
    .word 0x4dd49d44
    .word 0x145520c7
    .word 0x8e4877cb
    .word 0x2bdf112e
    .word 0xbae47daf
    .word 0x4f2072ba
    .word 0xb877f048
    .word 0x8df45c59
    .word 0xd5d842d5
    .word 0x3d9413b1
    .word 0x1c0514ba
    .word 0x576c3061
    .word 0xe878d478
    .word 0x89dcb595
    .word 0x5c4250bd
    .word 0xaf7942b8
    .word 0x76b80ed2
    .word 0x8349eaf4
    .word 0x65bed1a6
    .word 0x1aeb3b60
    .word 0x311fe6b9
    .word 0xa451f865
    .word 0x43c79569
    .word 0x37d79135
    .word 0xb163cb9d
    .word 0xade4dc90
    .word 0x694dc456
    .word 0x33f290be
    .word 0x083ec4ec
    .word 0x48b6a155
    .word 0x48fe42da
    .word 0x9d51d0f3
    .word 0x86f07eda
    .word 0x207973b7
    .word 0x95904667
    .word 0x698994e2
    .word 0xd0a57d6b
    .word 0x185bef2d
    .word 0x34066c05
    .word 0xbcc54cd1
    .word 0xfc8568c5
    .word 0x142f39dd
    .word 0x4a018d63
    .word 0xe70e8427
    .word 0x816ed852
    .word 0xe9b44613
    .word 0xe32b67b0
    .word 0x8d50e555
    .word 0x2ac4b4be
    .word 0xfdf990fd
    .word 0x764dacdb
    .word 0xfb9ed709
    .word 0x21bedff0
    .word 0xd9e3ca05
    .word 0x4aa29838
    .word 0xad78db1b
    .word 0x8a0ff89f
    .word 0x0ef4046e
    .word 0xf61acc5d
    .word 0x48e64443
    .word 0x2d63f2cc
    .word 0x7915251b
    .word 0x8ce6d45e
    .word 0x3aeedbf9
    .word 0x5fd6b8f4
    .word 0x662f9ce6
    .word 0xf59c7656
    .word 0x5d3211e0
    .word 0x0cb18422
    .word 0x9a14a17b
    .word 0xcf0fb9d3
    .word 0xb89e50cd
    .word 0x033620fc
    .word 0xc39a1d0a
    .word 0x00ba747f
    .word 0xdb932d45
    .word 0x0e9d3fa5
    .word 0x02eb630d
    .word 0x26e6fad3
    .word 0x00020e43
    .word 0x720615b5
    .word 0x63dcaa9f
    .word 0x8b5cf0c4
    .word 0x9df34273
    .word 0x48aed963
    .word 0xe38ca449
    .word 0x9411daf1
    .word 0x24e6df84
    .word 0x84e750f5
    .word 0x3dc0abf8
    .word 0x8ce8126d
    .word 0xad17c3e3
    .word 0xd6399366
    .word 0xc6213528
    .word 0x7989494c
    .word 0x30f395a0
    .word 0xecb598ee
    .word 0x2c5f31af
    .word 0x648f3fc0
    .word 0x98b29526
    .word 0x36855a80
    .word 0x6c1fe91f
    .word 0xcc7612d9
    .word 0x100f926f
    .word 0x1ad0410b
    .word 0x032ff795
    .word 0xc901feb9
    .word 0x57f21b10
    .word 0x62c1d284
    .word 0xf3af1fe0
    .word 0x3f069264
    .word 0x9a544c96
    .word 0x9fa9b013
    .word 0xcd63819b
    .word 0x4522819f
    .word 0x7ced673e
    .word 0x0e6965c2
    .word 0xedb4b34e
    .word 0x1f82d935
    .word 0x6d53f7bf
    .word 0x300234da
    .word 0x0ca978a6
    .word 0x6e530b6e
    .word 0x8c403e8f
    .word 0x8cc0be44
    .word 0xe55c44f6
    .word 0x5e06d2ce
    .word 0x56c5709b
    .word 0x44d40a33
    .word 0x0015c553
    .word 0x10a93cc3
    .word 0xfd9eb4f7
    .word 0xfbc2d9e1
    .word 0xa11c0075
    .word 0xae071fdd
    .word 0xfdb20898
    .word 0xf240cc1f
    .word 0x6364bdfd
    .word 0x199ce147
    .word 0x48a1e667
    .word 0x7643520d
    .word 0xc5a9a8fd
    .word 0x69f58fc9
    .word 0x9035547c
    .word 0xf7313f24
    .word 0x13c24bba
    .word 0x35d2b727
    .word 0xbbe3b2f0
    .word 0xd4282810
    .word 0xa3eb7fe8
    .word 0x7c4baf25
    .word 0x60a592dc
    .word 0xfa3e43aa
    .word 0x183b310b
    .word 0x462d51a6
    .word 0x318e4937
    .word 0x08f16bf9
    .word 0x5859a0c1
    .word 0xc886ce4f
    .word 0x31ba20b1
    .word 0xa3eb66e9
    .word 0xdc9c9563
    .word 0xeef52269
    .word 0xe44fb91b
    .word 0x7697d8fd
    .word 0x05d76e81
    .word 0x52eb8dc9
    .word 0x826ed9c0
    .word 0xc1d2bda5
    .word 0x75a31ee1
    .word 0xd1641219
    .word 0x1b8d9d73
    .word 0x13151081
    .word 0xb1cccfba
    .word 0x2b766fb5
    .word 0x08ea4abb
    .word 0x59474f4a
    .word 0xff83ba18
    .word 0x99e1664b
    .word 0xa180a11f
    .word 0xcbd71c1f
    .word 0xe2fc35b2
    .word 0x2470a0e6
    .word 0xcff40ef6
    .word 0x6100e90e
    .word 0x65c96371
    .word 0x4f074894
    .word 0x47498e28
    .word 0xa204492e
    .word 0x238ddebd
    .word 0x5cfec8a0
    .word 0x5390aaa8
    .word 0x3e388d5f
    .word 0x340a30cf
    .word 0xa4021773
    .word 0xcd746708
    .word 0x172ef344
    .word 0x5f5c4f7f
    .word 0x738b4e7a
    .word 0x5e874f12
    .word 0x2f4e1b45
    .word 0xe5b2b03d
    .word 0x924c5c52
    .word 0x0982e369
    .word 0x8457c1c8
    .word 0xbc83b0e1
    .word 0x8ea3ed57
    .word 0x6c54ea4f
    .word 0x667a689f
    .word 0x81041881
    .word 0xcbe93611
    .word 0x114b8538
    .word 0x1fcb4bd7
    .word 0x4d435158
    .word 0xfed1f69c
    .word 0xba04d619
    .word 0x2b00be63
    .word 0x0b511b1e
    .word 0x5e50083f
    .word 0xfcfc95e6
    .word 0xc198f275
    .word 0x73ab29ac
    .word 0x6fab7ff3
    .word 0x639020d8
    .word 0x842c2dc8
    .word 0x5a41f18c
    .word 0xec263c59
    .word 0x20968461
    .word 0x549196a4
    .word 0x5c8b66b8
    .word 0xc0fc4f1e
    .word 0xeccfe8bf
    .word 0x26924506
    .word 0x801c6fe6
    .word 0x51ff70cd
    .word 0xe4458e48
    .word 0x0e63f09a

#include "frost_footer.S"
