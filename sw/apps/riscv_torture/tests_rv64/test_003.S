// Generated RV64IMAFDC torture test for Frost (seed=20260805)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xbec38fccef069dd4
    li x4, 0xb363b4422c2964ac
    li x5, 0xc579189093d8c1dd
    li x6, 0xf0a7d024cfcc7afa
    li x7, 0xb6634bc49c3a33a2
    li x8, 0xaa800345e26ebc0c
    li x9, 0x50be3970af79f582
    li x10, 0xe8eb5b3daf86411e
    li x11, 0xfbaec1e706e92067
    li x12, 0x098379b7c03258a0
    li x13, 0x753a5d25993e9559
    li x14, 0x90bbdd34d4358b3d
    li x15, 0xf884ef221a469c77
    li x16, 0xa9dbff56684aa328
    li x17, 0x9e52b30bd051f5f5
    li x18, 0xc77f60996f961de3
    li x19, 0x0bf890bc926a8dc6
    li x20, 0xb051549602391568
    li x21, 0xad3cdb163f488815
    li x22, 0x5ffd17fe66ad64ce
    li x23, 0x060f1eb7ed16a3e2
    li x24, 0x1e7eaf50a43b3e8a
    li x25, 0xab39bc99d7d304c5
    li x26, 0x3734e124e2bab27f
    li x27, 0x43d8185d2bc57b13
    li x28, 0x5b206f577da68ef0
    li x29, 0x9330288877d6b8ca
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
    li x1, 0x71d7131761bb7b66

    fdiv.d f11, f19, f3
    fsub.s f14, f8, f7
    fmul.s f23, f20, f25
    andi x1, x20, 349
    slti x10, x16, 213
    slliw x26, x4, 21
    addi x30, x31, 24
    amoand.w x24, x26, (x30)
    bgeu x8, x27, _br_taken_0
    xor x8, x19, x24
    j _br_done_0
_br_taken_0:
    or x8, x25, x26
_br_done_0:
    srliw x28, x25, 29
    slli x8, x27, 21
    lwu x22, 760(x31)
    sw x28, 760(x31)
    sraw x10, x10, x16
    slti x5, x15, -132
    rem x9, x11, x28
    remuw x19, x1, x12
    addi x18, x11, 1250
    sltu x18, x8, x7
    sraiw x15, x17, 28
    sltiu x16, x18, 1071
    srliw x19, x26, 20
    bgeu x19, x13, _br_taken_1
    and x29, x5, x18
    j _br_done_1
_br_taken_1:
    srl x29, x6, x24
_br_done_1:
    and x8, x7, x20
    bltu x8, x29, _br_taken_2
    sltu x5, x23, x26
    j _br_done_2
_br_taken_2:
    slt x5, x9, x11
_br_done_2:
    bne x4, x5, _br_taken_3
    and x15, x23, x22
    j _br_done_3
_br_taken_3:
    sra x15, x16, x26
_br_done_3:
    divuw x22, x15, x8
    addi x30, x31, 80
    amoswap.d x26, x11, (x30)
    srli x12, x6, 28
    addw x15, x22, x16
    slti x8, x15, 1454
    or x16, x22, x25
    lh x1, 140(x31)
    sh x16, 140(x31)
    addi x30, x31, 88
    amominu.d x27, x9, (x30)
    lw x24, 896(x31)
    sw x20, 896(x31)
    sll x7, x14, x6
    sra x8, x11, x11
    lwu x4, 336(x31)
    sw x18, 336(x31)
    subw x22, x7, x23
    sra x6, x8, x19
    slti x4, x20, -189
    bgeu x9, x18, _br_taken_4
    sll x24, x21, x10
    j _br_done_4
_br_taken_4:
    slt x24, x27, x26
_br_done_4:
    sllw x27, x25, x23
    bltu x4, x14, _br_taken_5
    sll x1, x11, x8
    j _br_done_5
_br_taken_5:
    sra x1, x19, x26
_br_done_5:
    srliw x17, x21, 29
    addw x21, x19, x16
    addi x9, x8, 325
    slliw x16, x23, 24
    sub x22, x28, x11
    lhu x25, 932(x31)
    sh x5, 932(x31)
    addi x6, x17, 189
    sltiu x16, x5, -1332
    srl x16, x27, x1
    divuw x9, x20, x23
    srl x8, x17, x23
    slti x5, x6, 1150
    slli x7, x21, 24
    sltiu x6, x17, 662
    slli x9, x9, 37
    fmul.d f23, f8, f10
    addi x30, x31, 556
    amomax.w x10, x8, (x30)
    bgeu x13, x19, _br_taken_6
    srl x19, x5, x28
    j _br_done_6
_br_taken_6:
    add x19, x5, x16
_br_done_6:
    add x21, x13, x17
    sltiu x20, x13, 899
    addi x30, x31, 496
    amoxor.w x16, x25, (x30)
    addw x5, x8, x7
    sll x28, x20, x5
    slliw x8, x10, 20
    ld x16, 200(x31)
    sd x1, 200(x31)
    sll x7, x18, x20
    srl x24, x6, x19
    ori x6, x24, -498
    srl x1, x22, x14
    slli x9, x24, 24
    slli x13, x21, 2
    slti x27, x7, 400
    remuw x22, x13, x11
    mulhsu x23, x18, x8
    fdiv.s f11, f1, f23
    fdiv.d f10, f25, f30
    fmax.d f19, f21, f16
    fmax.s f15, f27, f13
    fdiv.s f19, f23, f25
    fmul.d f0, f24, f28
    beq x10, x5, _br_taken_7
    srl x22, x10, x15
    j _br_done_7
_br_taken_7:
    sll x22, x9, x25
_br_done_7:
    addi x30, x31, 292
    amomaxu.w x29, x10, (x30)
    lbu x11, 808(x31)
    sb x10, 808(x31)
    srliw x10, x1, 16
    srlw x17, x12, x16
    sltu x12, x10, x5
    fadd.d f0, f27, f17
    fadd.d f11, f21, f30
    fadd.d f12, f5, f20
    sllw x6, x26, x8
    xor x13, x15, x1
    add x25, x17, x15
    ori x12, x16, 429
    srliw x26, x21, 1
    ld x17, 400(x31)
    sd x21, 400(x31)
    sraiw x15, x13, 4
    bge x27, x14, _br_taken_8
    sra x16, x27, x21
    j _br_done_8
_br_taken_8:
    and x16, x8, x8
_br_done_8:
    lw x21, 916(x31)
    sw x11, 916(x31)
    subw x6, x23, x5
    sraiw x7, x24, 19
    beq x9, x8, _br_taken_9
    or x8, x12, x17
    j _br_done_9
_br_taken_9:
    sub x8, x11, x11
_br_done_9:
    sra x8, x6, x4
    xori x16, x11, -2020
    srli x19, x29, 50
    bltu x10, x22, _br_taken_10
    xor x20, x9, x15
    j _br_done_10
_br_taken_10:
    sll x20, x27, x14
_br_done_10:
    addw x1, x8, x1
    addiw x6, x14, 1743
    addiw x15, x27, -1141
    srli x19, x1, 17
    addi x27, x1, -1682
    bne x1, x19, _br_taken_11
    add x6, x28, x11
    j _br_done_11
_br_taken_11:
    and x6, x26, x7
_br_done_11:
    subw x27, x6, x25
    add x10, x15, x1
    blt x21, x8, _br_taken_12
    xor x26, x29, x28
    j _br_done_12
_br_taken_12:
    srl x26, x11, x5
_br_done_12:
    srliw x28, x5, 11
    slli x8, x9, 40
    srai x24, x17, 56
    slliw x21, x23, 29
    sllw x19, x29, x5
    or x11, x17, x5
    bge x23, x13, _br_taken_13
    xor x17, x7, x17
    j _br_done_13
_br_taken_13:
    and x17, x12, x20
_br_done_13:
    divu x9, x14, x15
    ld x20, 248(x31)
    sd x26, 248(x31)
    addi x30, x31, 336
    amomax.d x11, x12, (x30)
    mulh x11, x24, x22
    rem x22, x20, x19
    lwu x18, 204(x31)
    sw x23, 204(x31)
    slli x24, x24, 40
    sra x5, x5, x19
    mulh x8, x22, x10
    mulw x10, x13, x21
    srli x5, x8, 24
    slliw x22, x27, 0
    addi x14, x12, -1721
    xori x17, x25, 912
    subw x10, x16, x26
    addiw x28, x26, -550
    blt x24, x9, _br_taken_14
    xor x22, x28, x14
    j _br_done_14
_br_taken_14:
    add x22, x24, x10
_br_done_14:
    ld x6, 496(x31)
    sd x17, 496(x31)
    xor x20, x25, x10
    xori x9, x11, 1014
    srai x8, x12, 48
    sraw x17, x10, x22
    sltu x10, x17, x19
    sll x27, x26, x25
    sltiu x18, x25, -1247
    slli x22, x6, 15
    slliw x18, x6, 6
    addiw x17, x5, 573
    srlw x8, x20, x1
    slli x9, x9, 62
    bgeu x4, x6, _br_taken_15
    xor x23, x20, x12
    j _br_done_15
_br_taken_15:
    add x23, x28, x11
_br_done_15:
    slliw x4, x11, 31
    sltu x16, x7, x13
    fadd.s f6, f13, f29
    beq x14, x6, _br_taken_16
    sltu x1, x7, x26
    j _br_done_16
_br_taken_16:
    sltu x1, x18, x25
_br_done_16:
    srai x22, x9, 23
    bltu x16, x25, _br_taken_17
    sltu x19, x19, x9
    j _br_done_17
_br_taken_17:
    and x19, x22, x13
_br_done_17:
    xor x23, x17, x15
    xori x20, x14, 1690
    addiw x29, x5, -1814
    sra x28, x7, x1
    sraw x16, x25, x25
    div x14, x28, x29
    mul x4, x11, x16
    sll x13, x21, x28
    andi x27, x20, -163
    xori x24, x13, 624
    slliw x14, x12, 29
    fmul.d f4, f5, f31
    fnmsub.s f30, f8, f20, f18
    sra x25, x28, x29
    addiw x24, x21, 1956
    addw x24, x26, x28
    ori x12, x20, 606
    srl x8, x27, x14
    sra x9, x15, x13
    srlw x20, x27, x9
    bge x17, x13, _br_taken_18
    sll x22, x28, x13
    j _br_done_18
_br_taken_18:
    add x22, x25, x10
_br_done_18:
    slli x1, x19, 61
    slt x18, x22, x20
    lb x15, 80(x31)
    sb x15, 80(x31)
    add x7, x29, x7
    xori x13, x8, 1048
    sraw x6, x4, x17
    xor x22, x18, x23
    srl x27, x12, x5
    subw x4, x14, x29
    andi x17, x11, 1048
    slliw x20, x6, 14
    andi x1, x26, 685
    srl x17, x29, x22
    srliw x22, x16, 0
    mulhsu x16, x23, x16
    mulhsu x29, x9, x29
    sltu x8, x25, x20
    sub x19, x19, x10
    slt x28, x27, x25
    addiw x14, x17, -81
    subw x5, x11, x11
    addw x7, x15, x4
    srl x14, x17, x23
    sltiu x24, x11, 1268
    xori x27, x4, -852
    lw x15, 668(x31)
    sw x11, 668(x31)
    lb x10, 472(x31)
    sb x8, 472(x31)
    sra x23, x20, x6
    and x8, x26, x6
    slli x27, x19, 11
    xor x11, x10, x23
    addi x30, x31, 856
    amoand.w x5, x16, (x30)
    blt x23, x21, _br_taken_19
    sltu x15, x19, x11
    j _br_done_19
_br_taken_19:
    or x15, x23, x17
_br_done_19:
    blt x6, x27, _br_taken_20
    sub x29, x12, x11
    j _br_done_20
_br_taken_20:
    srl x29, x20, x25
_br_done_20:
    srli x14, x21, 37
    lwu x7, 184(x31)
    sw x8, 184(x31)
    fsub.d f29, f30, f5
    fmax.s f26, f27, f23
    fmax.s f28, f31, f11
    addi x30, x31, 752
    amoswap.d x7, x20, (x30)
    fnmsub.s f6, f19, f6, f12
    fadd.s f29, f6, f22
    sltu x28, x26, x13
    add x23, x23, x27
    srl x25, x26, x26
    lbu x21, 208(x31)
    sb x15, 208(x31)
    addi x30, x31, 380
    amominu.w x19, x16, (x30)
    fmax.d f15, f21, f30
    fsub.d f18, f31, f12
    fadd.s f7, f20, f17
    addw x7, x26, x17
    sraw x21, x19, x22
    and x21, x9, x22
    or x16, x22, x27
    srl x1, x20, x24
    or x8, x12, x18
    xor x13, x29, x16
    addw x26, x14, x1
    srl x25, x7, x26
    srliw x4, x17, 28
    srli x26, x9, 33
    sll x11, x4, x14
    sraw x20, x8, x21
    andi x15, x22, 70
    sltu x11, x24, x25
    addiw x16, x20, -1659
    slliw x6, x22, 23
    sltiu x21, x11, -1451
    bltu x13, x11, _br_taken_21
    or x11, x10, x17
    j _br_done_21
_br_taken_21:
    or x11, x23, x5
_br_done_21:
    fsub.s f26, f5, f17
    fadd.d f9, f16, f2
    addi x19, x7, -395
    srai x14, x7, 26
    sraw x5, x14, x26
    fmax.s f15, f21, f16
    fmax.d f24, f1, f17
    fmul.d f11, f8, f24
    srli x29, x15, 9
    sraiw x19, x6, 11
    sra x15, x9, x19
    addw x20, x21, x22
    srli x25, x12, 60
    addi x15, x1, -1833
    remu x22, x28, x21
    mulh x14, x7, x8
    bltu x24, x17, _br_taken_22
    sll x15, x7, x24
    j _br_done_22
_br_taken_22:
    sra x15, x24, x8
_br_done_22:
    xor x15, x23, x16
    addi x19, x15, 528
    add x21, x8, x26
    lb x5, 252(x31)
    sb x27, 252(x31)
    addi x30, x31, 728
    amomin.w x4, x23, (x30)
    bltu x14, x11, _br_taken_23
    sll x5, x5, x21
    j _br_done_23
_br_taken_23:
    add x5, x26, x1
_br_done_23:
    bne x11, x5, _br_taken_24
    add x14, x9, x9
    j _br_done_24
_br_taken_24:
    srl x14, x16, x28
_br_done_24:
    add x25, x29, x7
    or x10, x13, x7
    lbu x1, 836(x31)
    sb x29, 836(x31)
    div x23, x21, x11
    bltu x24, x24, _br_taken_25
    sub x28, x24, x25
    j _br_done_25
_br_taken_25:
    or x28, x16, x11
_br_done_25:
    bgeu x5, x15, _br_taken_26
    xor x17, x16, x12
    j _br_done_26
_br_taken_26:
    slt x17, x25, x17
_br_done_26:
    fmax.s f20, f30, f9
    beq x29, x25, _br_taken_27
    add x13, x13, x17
    j _br_done_27
_br_taken_27:
    sll x13, x19, x18
_br_done_27:
    beq x4, x22, _br_taken_28
    or x15, x1, x27
    j _br_done_28
_br_taken_28:
    add x15, x10, x17
_br_done_28:
    srai x13, x4, 18
    sll x8, x11, x17
    sltu x28, x6, x18
    srai x16, x22, 42
    ori x18, x14, -1511
    lhu x16, 528(x31)
    sh x29, 528(x31)
    srli x9, x24, 24
    sltu x12, x27, x7
    sraw x28, x4, x6
    srlw x23, x20, x7
    slliw x10, x17, 23
    srli x21, x29, 26
    sltiu x5, x10, 2026
    sltiu x29, x25, 1311
    lw x20, 716(x31)
    sw x18, 716(x31)
    fmul.s f20, f4, f9
    fnmsub.d f20, f26, f24, f17
    fdiv.s f12, f19, f26
    xori x10, x21, 1647
    and x25, x11, x26
    sllw x7, x12, x28
    bge x13, x6, _br_taken_29
    sltu x26, x12, x16
    j _br_done_29
_br_taken_29:
    and x26, x24, x6
_br_done_29:
    bgeu x20, x13, _br_taken_30
    add x19, x25, x27
    j _br_done_30
_br_taken_30:
    sra x19, x28, x24
_br_done_30:
    bgeu x22, x17, _br_taken_31
    sltu x6, x26, x7
    j _br_done_31
_br_taken_31:
    srl x6, x22, x12
_br_done_31:
    slti x16, x23, -1891
    fdiv.s f18, f31, f13
    fmul.s f24, f3, f3
    fmax.d f2, f5, f0
    srlw x13, x6, x23
    slli x12, x12, 39
    addiw x17, x27, -652
    andi x17, x1, -1287
    beq x19, x10, _br_taken_32
    sltu x4, x25, x21
    j _br_done_32
_br_taken_32:
    xor x4, x22, x22
_br_done_32:
    addi x30, x31, 336
    amomax.d x12, x8, (x30)
    beq x24, x26, _br_taken_33
    sll x20, x22, x23
    j _br_done_33
_br_taken_33:
    add x20, x8, x19
_br_done_33:
    sltiu x5, x1, -57
    subw x26, x8, x22
    srai x22, x7, 14
    add x13, x11, x15
    ori x19, x21, -1884
    srai x13, x5, 26
    bge x26, x8, _br_taken_34
    srl x19, x24, x27
    j _br_done_34
_br_taken_34:
    srl x19, x19, x4
_br_done_34:
    and x6, x10, x10
    sllw x11, x17, x18
    srliw x18, x26, 31

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xe7ade49a80a5153f
    .dword 0x0713412c1fc10df6
    .dword 0x51e9ba13f060ccb2
    .dword 0x69d3386e32ec9823
    .dword 0x808251d3651092a1
    .dword 0x8bb6bc167823ab9d
    .dword 0x5bb21264b829bdf3
    .dword 0x31c0c99711042950
    .dword 0x53eeb8df42e214e0
    .dword 0xacae04de1e5d2b4f
    .dword 0x4bb17af665b65b65
    .dword 0x4b7d219ee3f8c38b
    .dword 0x79fcb9459c882687
    .dword 0x00aa8857a6d8966f
    .dword 0xbba1b0c873154f49
    .dword 0xba6faba51c534048
    .dword 0x5dbc6e405f152f4b
    .dword 0x5394bb2567b8bbff
    .dword 0xbe79ff04a5821673
    .dword 0x1b76042259723760
    .dword 0xb9b69c4a06a091aa
    .dword 0x8cafa1d06ecbf20e
    .dword 0xf86822e1ab901c16
    .dword 0xd4b9b32b4edbcf59
    .dword 0x672821837bd069a6
    .dword 0xb40f761f84a551be
    .dword 0x3172d910bbc6abcb
    .dword 0x1023ed5d89945561
    .dword 0xd5c3119ce9a4a0e1
    .dword 0x23c4ebef97518781
    .dword 0x6c7ffea6fd6d4b1e
    .dword 0x1e9db349e97a5922

    .align 2
_torture_data:
    .word 0xc3215bbd
    .word 0xb380c882
    .word 0x206105ec
    .word 0xfd8c4505
    .word 0x63f7980c
    .word 0x063296b8
    .word 0xd89464ff
    .word 0x4af245a6
    .word 0x53b61269
    .word 0x1a0422f5
    .word 0x71e61f4e
    .word 0x49e03001
    .word 0x1b65deb4
    .word 0xba01294f
    .word 0x53808b64
    .word 0x07cc5cf6
    .word 0xeabc9d44
    .word 0x9d9d694f
    .word 0x57d52b52
    .word 0xfe2761a3
    .word 0xa8f095c8
    .word 0xbc484c72
    .word 0x7b7244a2
    .word 0x48442129
    .word 0x737bd9ca
    .word 0x0ddb009c
    .word 0x0039ce98
    .word 0x98d3042e
    .word 0xf06a49c7
    .word 0xe46590c3
    .word 0xabc91b05
    .word 0xae108d94
    .word 0xb3c4a54e
    .word 0x7789a087
    .word 0x2ff6dc5a
    .word 0x042d3868
    .word 0x39308c59
    .word 0xfdec101e
    .word 0xb7bc44a1
    .word 0x04cd9410
    .word 0x569179c5
    .word 0x30def308
    .word 0x6809864f
    .word 0xad019dcb
    .word 0x04dda6b4
    .word 0xf2f922dd
    .word 0xd00ff12f
    .word 0x37f8f2e4
    .word 0x98d2ec68
    .word 0x77169233
    .word 0xff4dbd43
    .word 0xb35c56f3
    .word 0x4fc15606
    .word 0x0244725d
    .word 0x2269b00a
    .word 0xb0c386fc
    .word 0x81a28b30
    .word 0xf9e33abe
    .word 0xbaada90a
    .word 0xa4acf22f
    .word 0x00a39507
    .word 0x8280202e
    .word 0xc44a7b7f
    .word 0x893833d9
    .word 0xc98d07c1
    .word 0x2e9f52db
    .word 0x2734f186
    .word 0x670c1a12
    .word 0x384ff2b2
    .word 0xaae77e5f
    .word 0x167945f6
    .word 0x15b8eed7
    .word 0x8d4b308e
    .word 0x2721be0b
    .word 0xd82b187b
    .word 0x58907d70
    .word 0xc71f9b2a
    .word 0xfd4a1159
    .word 0xd9ae17bd
    .word 0x47151e44
    .word 0x115f77a4
    .word 0xcacffc88
    .word 0x6da56eaa
    .word 0x7186c3e6
    .word 0x51863177
    .word 0xb663adba
    .word 0xd26d5d16
    .word 0xf3e1b3ef
    .word 0x6938f375
    .word 0x3ec582f9
    .word 0x2ccb7511
    .word 0xb3c92e81
    .word 0x9fe3578d
    .word 0x462fd5e7
    .word 0xabad88da
    .word 0x5717a6e5
    .word 0x9cfd2e96
    .word 0x38f01335
    .word 0x6c227339
    .word 0xf7ea6e32
    .word 0xc73b246f
    .word 0x86d53fa9
    .word 0xae66e698
    .word 0xc5b378b2
    .word 0x9f333394
    .word 0xee12cb9a
    .word 0x8ce3462b
    .word 0x097cbeb2
    .word 0x0ee3f9db
    .word 0xda009e2a
    .word 0xd71165ad
    .word 0x2ccbf462
    .word 0xb786d326
    .word 0xf7da828c
    .word 0x08c04c7e
    .word 0x5691cfce
    .word 0x973a6999
    .word 0x5ca6582f
    .word 0x80d2e11b
    .word 0xc7eb56ac
    .word 0xd7da6f98
    .word 0xdfed012f
    .word 0x22e42bd9
    .word 0x8cfd9e59
    .word 0x072eabbf
    .word 0x4582a254
    .word 0x8f600501
    .word 0x86125e9e
    .word 0x4ece2a4f
    .word 0xf9e0fdee
    .word 0x37d761e0
    .word 0xf1a9dc12
    .word 0x3fedbcf0
    .word 0x747a49e3
    .word 0x7956dd2d
    .word 0x237140c1
    .word 0xf2309178
    .word 0x02fe54bf
    .word 0xef122388
    .word 0x8f80c698
    .word 0x96fbc7bf
    .word 0x366867e4
    .word 0x13c8b7ae
    .word 0x60d05dd1
    .word 0x8821773f
    .word 0x62a0f9f3
    .word 0x6c835317
    .word 0x73a05b1d
    .word 0x63d57797
    .word 0xf55af631
    .word 0xc3a0823e
    .word 0x703102df
    .word 0x2d6f1bca
    .word 0xf918641a
    .word 0x1d263753
    .word 0x6d42c652
    .word 0xad8f4a07
    .word 0x7c8ec0c5
    .word 0xe05d9b00
    .word 0xdbc23851
    .word 0x36f52bc8
    .word 0x4dd389f4
    .word 0x390956ce
    .word 0x852e42e5
    .word 0xd9107195
    .word 0x8bacd413
    .word 0x98708df2
    .word 0x0c84c196
    .word 0xee5344db
    .word 0x63e69f76
    .word 0xef36cd61
    .word 0x81afa3d3
    .word 0x20c218fc
    .word 0x45feee13
    .word 0xa04892d0
    .word 0xb6b3c480
    .word 0x9fc97bc5
    .word 0x3b7fd033
    .word 0x3217783d
    .word 0x2604024a
    .word 0x5b16b23c
    .word 0x1f5aabbd
    .word 0x402de928
    .word 0xd7eaa0ac
    .word 0xb5bbbb57
    .word 0x23c05506
    .word 0xb8aeaa96
    .word 0xc36bb46b
    .word 0x2d7b1351
    .word 0x27d307d3
    .word 0x35a5b26e
    .word 0xdd47c35f
    .word 0x697dce71
    .word 0x1f724b5b
    .word 0x5eeefb44
    .word 0x6c04c9bc
    .word 0x93cdac87
    .word 0x3c863e01
    .word 0x46b0f0e5
    .word 0x7e0cd23d
    .word 0xb6a97728
    .word 0x8650dce5
    .word 0x394c802b
    .word 0x3f2830e8
    .word 0xc1fd30a5
    .word 0x0a8bb7ff
    .word 0x2ff7fae9
    .word 0x20334930
    .word 0x54353fe1
    .word 0x5817ffcd
    .word 0x4479a56a
    .word 0xfbd4a3c9
    .word 0xbafc4847
    .word 0xe09b0dcc
    .word 0xc2380b5b
    .word 0x18365b0a
    .word 0xffb497f6
    .word 0x82d7bf8d
    .word 0x6b770d67
    .word 0xcc359a95
    .word 0x15cb7ffa
    .word 0x1c6ef4f1
    .word 0x35609fb7
    .word 0x7d1fe5bb
    .word 0x88125183
    .word 0x0e28fabc
    .word 0x78251a65
    .word 0xf5b6d0d0
    .word 0x00577129
    .word 0x5e0b3cd0
    .word 0x825bba83
    .word 0x75150213
    .word 0xcc59e717
    .word 0x848a3926
    .word 0x472ca2f1
    .word 0x6e8ee6e4
    .word 0x2c08a2d9
    .word 0xd9dc0bc8
    .word 0xc641e8f7
    .word 0xec08e1d0
    .word 0xe6fc0199
    .word 0xdb89b992
    .word 0x888e3e6d
    .word 0x5385c95e
    .word 0x4f371adc
    .word 0xffb13022
    .word 0x88f696ab
    .word 0xb831b81e
    .word 0x217cefde
    .word 0xcb47fee7
    .word 0x41b561ea
    .word 0xbd5cbe3c
    .word 0x1838ce06
    .word 0x091cc989
    .word 0xc3bb4acc
    .word 0x919da942

#include "frost_footer.S"
