// Generated RV64IMAFDC torture test for Frost (seed=20260812)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x111e8c530d98db16
    li x4, 0x3d8da9cd4c13bc5e
    li x5, 0x2c8425e95b93dfd2
    li x6, 0x33d6f3fc992c23c4
    li x7, 0xc96cdb6327e109cb
    li x8, 0x8c64620fb3fad379
    li x9, 0xafb7f2e9b96b89a0
    li x10, 0x9e1d16867a2576e8
    li x11, 0xb79e8a8c57383dbd
    li x12, 0x980078f569ef5273
    li x13, 0x5bf078fca209b5ff
    li x14, 0x8b3d8c121cddb6e2
    li x15, 0x5f09b5cb129bea94
    li x16, 0x533b05f2a0cb52d2
    li x17, 0xe553b2edea918937
    li x18, 0x6f5dd6be5fe7280c
    li x19, 0x85aa21898657e2f1
    li x20, 0x60bc8bbd6ef9e8fd
    li x21, 0x8e1c316930109b3d
    li x22, 0x6aa7df0744a1f420
    li x23, 0x2c9961884b0ec241
    li x24, 0xbd1e445171cbb76e
    li x25, 0x2bbc145e2e0bff7e
    li x26, 0x2ba1a657e55017ee
    li x27, 0x7187c6954dbb9349
    li x28, 0x43b50983a0d8c79f
    li x29, 0x82a35d47d8d473f6
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
    li x1, 0xd53ad7be9c28615e

    slti x5, x1, 1090
    sll x28, x6, x19
    xori x25, x4, 788
    sltiu x12, x24, -1028
    sraiw x29, x16, 0
    sub x9, x22, x21
    sltiu x8, x11, -819
    and x8, x13, x21
    lwu x27, 856(x31)
    sw x12, 856(x31)
    bne x1, x5, _br_taken_0
    xor x6, x10, x12
    j _br_done_0
_br_taken_0:
    and x6, x13, x7
_br_done_0:
    lbu x7, 136(x31)
    sb x27, 136(x31)
    bge x6, x12, _br_taken_1
    or x20, x22, x25
    j _br_done_1
_br_taken_1:
    xor x20, x24, x6
_br_done_1:
    srl x17, x27, x14
    srliw x18, x29, 9
    slt x25, x4, x24
    xor x29, x19, x6
    bgeu x29, x28, _br_taken_2
    sra x25, x5, x4
    j _br_done_2
_br_taken_2:
    and x25, x4, x29
_br_done_2:
    slli x4, x21, 9
    sllw x26, x13, x28
    slli x22, x5, 0
    sltiu x8, x23, -1377
    slt x5, x22, x18
    ld x21, 704(x31)
    sd x21, 704(x31)
    lw x15, 1020(x31)
    sw x25, 1020(x31)
    blt x25, x18, _br_taken_3
    add x1, x1, x1
    j _br_done_3
_br_taken_3:
    and x1, x19, x26
_br_done_3:
    or x11, x22, x15
    divw x1, x6, x7
    remu x5, x12, x13
    sltu x19, x23, x20
    slti x19, x20, 373
    srai x6, x23, 52
    andi x6, x22, -646
    slti x15, x19, 848
    sraw x8, x23, x17
    xori x21, x28, 920
    srlw x8, x29, x15
    srl x11, x8, x10
    subw x13, x24, x15
    bge x4, x26, _br_taken_4
    and x8, x24, x15
    j _br_done_4
_br_taken_4:
    xor x8, x23, x17
_br_done_4:
    sra x25, x17, x28
    remw x23, x1, x21
    rem x20, x15, x10
    div x22, x4, x15
    div x16, x12, x17
    fmax.d f30, f22, f6
    fmsub.s f31, f17, f30, f19
    slliw x5, x25, 8
    or x13, x27, x10
    sraw x7, x17, x23
    and x23, x19, x6
    sllw x14, x29, x9
    bne x25, x21, _br_taken_5
    sra x12, x6, x19
    j _br_done_5
_br_taken_5:
    slt x12, x27, x25
_br_done_5:
    srli x6, x6, 10
    subw x18, x24, x21
    fadd.d f2, f21, f11
    fsub.d f17, f17, f4
    fnmsub.s f0, f7, f17, f0
    bge x25, x11, _br_taken_6
    and x29, x25, x22
    j _br_done_6
_br_taken_6:
    sll x29, x28, x13
_br_done_6:
    lbu x28, 196(x31)
    sb x18, 196(x31)
    bgeu x13, x24, _br_taken_7
    xor x9, x8, x8
    j _br_done_7
_br_taken_7:
    add x9, x8, x14
_br_done_7:
    srlw x14, x26, x12
    add x29, x4, x14
    and x10, x4, x10
    lh x5, 620(x31)
    sh x29, 620(x31)
    fadd.d f12, f4, f4
    fadd.d f18, f27, f10
    fnmsub.s f9, f24, f23, f26
    mul x29, x7, x23
    ori x29, x25, -672
    divw x10, x14, x14
    mulh x27, x11, x14
    lw x22, 548(x31)
    sw x12, 548(x31)
    lb x10, 768(x31)
    sb x15, 768(x31)
    srai x22, x22, 24
    srlw x12, x21, x21
    sltu x5, x8, x28
    bgeu x12, x17, _br_taken_8
    srl x14, x11, x4
    j _br_done_8
_br_taken_8:
    srl x14, x13, x29
_br_done_8:
    slli x24, x19, 38
    slli x18, x10, 13
    ori x12, x24, -2011
    addw x4, x21, x14
    slli x27, x25, 53
    slt x5, x18, x24
    srli x18, x18, 53
    sll x27, x13, x21
    addw x22, x13, x20
    ori x6, x14, 1997
    sllw x6, x27, x19
    bne x23, x28, _br_taken_9
    sub x18, x27, x4
    j _br_done_9
_br_taken_9:
    add x18, x27, x28
_br_done_9:
    sltiu x21, x8, -205
    srl x10, x7, x15
    slti x11, x9, 1354
    lwu x25, 808(x31)
    sw x1, 808(x31)
    sraw x17, x11, x20
    subw x11, x12, x20
    sub x18, x13, x17
    bltu x29, x22, _br_taken_10
    and x26, x10, x12
    j _br_done_10
_br_taken_10:
    add x26, x14, x23
_br_done_10:
    lhu x15, 100(x31)
    sh x24, 100(x31)
    blt x28, x21, _br_taken_11
    xor x7, x22, x8
    j _br_done_11
_br_taken_11:
    xor x7, x13, x20
_br_done_11:
    blt x1, x26, _br_taken_12
    sra x26, x18, x12
    j _br_done_12
_br_taken_12:
    srl x26, x22, x20
_br_done_12:
    slt x8, x27, x22
    and x11, x15, x19
    ori x11, x5, 2028
    addiw x14, x18, 988
    srlw x15, x19, x25
    srlw x7, x11, x5
    beq x13, x9, _br_taken_13
    and x4, x13, x13
    j _br_done_13
_br_taken_13:
    sll x4, x26, x14
_br_done_13:
    addiw x21, x15, 1556
    ori x20, x12, -1595
    sltiu x1, x16, -191
    ld x21, 8(x31)
    sd x29, 8(x31)
    slliw x14, x11, 1
    sltiu x24, x29, 1972
    sltu x18, x8, x15
    blt x27, x26, _br_taken_14
    sra x13, x19, x28
    j _br_done_14
_br_taken_14:
    sub x13, x19, x7
_br_done_14:
    addi x25, x8, -777
    addi x5, x15, -808
    sllw x7, x12, x18
    srliw x19, x19, 6
    subw x6, x9, x25
    srliw x6, x4, 30
    slli x25, x21, 25
    srlw x20, x26, x6
    srlw x14, x1, x19
    andi x24, x21, -1795
    lh x25, 588(x31)
    sh x6, 588(x31)
    sraiw x17, x20, 7
    sll x20, x14, x14
    srliw x28, x23, 21
    bgeu x19, x21, _br_taken_15
    sltu x18, x8, x20
    j _br_done_15
_br_taken_15:
    sll x18, x11, x12
_br_done_15:
    addi x30, x31, 792
    amomaxu.d x25, x4, (x30)
    slti x17, x21, 1162
    add x13, x29, x9
    addiw x27, x20, -178
    bltu x11, x25, _br_taken_16
    sub x7, x15, x26
    j _br_done_16
_br_taken_16:
    srl x7, x21, x5
_br_done_16:
    beq x18, x16, _br_taken_17
    sra x24, x10, x14
    j _br_done_17
_br_taken_17:
    sra x24, x23, x17
_br_done_17:
    lbu x23, 244(x31)
    sb x29, 244(x31)
    addi x30, x31, 112
    amomaxu.d x20, x25, (x30)
    fdiv.s f25, f21, f10
    fmul.s f29, f29, f0
    fadd.s f26, f19, f23
    xori x11, x15, 1279
    sraiw x4, x10, 31
    mulhu x29, x23, x6
    bgeu x18, x12, _br_taken_18
    and x27, x7, x20
    j _br_done_18
_br_taken_18:
    sub x27, x8, x27
_br_done_18:
    addi x4, x9, -1701
    srli x29, x28, 37
    subw x19, x19, x13
    sraw x25, x10, x28
    sltiu x13, x12, -1468
    bge x14, x22, _br_taken_19
    sub x21, x17, x23
    j _br_done_19
_br_taken_19:
    xor x21, x27, x7
_br_done_19:
    addi x30, x31, 336
    amoor.w x14, x7, (x30)
    srlw x18, x27, x5
    slli x24, x1, 22
    sub x13, x10, x7
    slt x29, x18, x12
    addi x30, x31, 212
    amomax.w x11, x12, (x30)
    beq x27, x11, _br_taken_20
    xor x23, x21, x20
    j _br_done_20
_br_taken_20:
    sll x23, x12, x18
_br_done_20:
    bge x25, x18, _br_taken_21
    sub x12, x15, x1
    j _br_done_21
_br_taken_21:
    sra x12, x25, x9
_br_done_21:
    bltu x18, x18, _br_taken_22
    srl x20, x23, x8
    j _br_done_22
_br_taken_22:
    sltu x20, x12, x25
_br_done_22:
    add x29, x11, x6
    srliw x15, x9, 21
    srlw x15, x6, x28
    sraiw x18, x25, 14
    addi x17, x5, -1577
    or x8, x10, x19
    bgeu x4, x15, _br_taken_23
    srl x26, x10, x28
    j _br_done_23
_br_taken_23:
    sltu x26, x25, x4
_br_done_23:
    slli x28, x4, 54
    xori x28, x14, 1636
    sltu x4, x5, x1
    add x17, x16, x4
    fsub.s f7, f30, f10
    srai x1, x11, 21
    fmax.d f2, f19, f31
    sll x6, x20, x14
    ori x25, x20, -195
    addiw x16, x17, -783
    addi x30, x31, 544
    amoxor.w x13, x13, (x30)
    bne x16, x15, _br_taken_24
    xor x26, x5, x19
    j _br_done_24
_br_taken_24:
    xor x26, x27, x22
_br_done_24:
    beq x16, x14, _br_taken_25
    and x29, x1, x10
    j _br_done_25
_br_taken_25:
    sub x29, x28, x9
_br_done_25:
    slt x22, x13, x29
    sll x4, x22, x23
    add x8, x22, x7
    addi x30, x31, 760
    amomin.w x27, x28, (x30)
    addiw x21, x5, 1032
    addi x30, x31, 168
    amominu.d x17, x4, (x30)
    addiw x22, x10, -482
    sra x7, x17, x6
    sltiu x23, x27, 1116
    ori x15, x25, -504
    slt x14, x23, x28
    sltiu x29, x9, -574
    blt x19, x21, _br_taken_26
    and x4, x4, x7
    j _br_done_26
_br_taken_26:
    sra x4, x26, x28
_br_done_26:
    bltu x14, x8, _br_taken_27
    srl x18, x24, x10
    j _br_done_27
_br_taken_27:
    xor x18, x25, x13
_br_done_27:
    blt x1, x14, _br_taken_28
    xor x6, x8, x16
    j _br_done_28
_br_taken_28:
    slt x6, x17, x13
_br_done_28:
    bne x7, x4, _br_taken_29
    sll x19, x5, x29
    j _br_done_29
_br_taken_29:
    and x19, x26, x9
_br_done_29:
    subw x6, x29, x15
    srliw x22, x11, 22
    mulh x15, x5, x23
    remuw x1, x5, x7
    blt x4, x26, _br_taken_30
    or x8, x8, x16
    j _br_done_30
_br_taken_30:
    and x8, x8, x25
_br_done_30:
    addw x11, x16, x13
    sllw x22, x22, x10
    srai x29, x11, 4
    fadd.d f23, f23, f13
    fdiv.s f17, f16, f27
    fnmadd.d f30, f19, f22, f1
    addiw x12, x4, 416
    ld x29, 960(x31)
    sd x16, 960(x31)
    beq x19, x15, _br_taken_31
    slt x28, x13, x25
    j _br_done_31
_br_taken_31:
    sra x28, x28, x29
_br_done_31:
    or x6, x4, x28
    slli x26, x17, 32
    sllw x6, x1, x7
    bltu x7, x14, _br_taken_32
    sltu x5, x6, x17
    j _br_done_32
_br_taken_32:
    sltu x5, x4, x4
_br_done_32:
    beq x12, x1, _br_taken_33
    add x12, x26, x16
    j _br_done_33
_br_taken_33:
    slt x12, x21, x20
_br_done_33:
    beq x15, x1, _br_taken_34
    and x25, x1, x4
    j _br_done_34
_br_taken_34:
    add x25, x11, x8
_br_done_34:
    sra x17, x6, x25
    or x21, x15, x23
    srliw x22, x6, 28
    bltu x10, x5, _br_taken_35
    sub x7, x18, x14
    j _br_done_35
_br_taken_35:
    and x7, x19, x26
_br_done_35:
    sub x13, x20, x9
    sraiw x17, x8, 3
    andi x15, x16, 1670
    mulhsu x23, x20, x5
    remuw x18, x22, x18
    xor x4, x5, x25
    srl x25, x6, x18
    add x4, x29, x8
    sltiu x7, x27, -330
    and x12, x29, x11
    lhu x28, 764(x31)
    sh x23, 764(x31)
    slli x23, x20, 43
    sllw x10, x21, x8
    sltu x15, x14, x9
    addi x30, x31, 828
    amoswap.w x22, x11, (x30)
    lwu x13, 568(x31)
    sw x12, 568(x31)
    lbu x7, 272(x31)
    sb x8, 272(x31)
    sra x4, x10, x6
    fmin.d f17, f29, f1
    fmin.d f7, f9, f19
    fmax.s f29, f12, f0
    slt x29, x5, x18
    lhu x27, 956(x31)
    sh x14, 956(x31)
    divuw x16, x11, x27
    divw x25, x4, x11
    lw x17, 172(x31)
    sw x11, 172(x31)
    sll x27, x20, x18
    sub x11, x8, x8
    sraw x8, x1, x21
    sllw x17, x24, x29
    addiw x13, x1, 593
    sltu x12, x22, x6
    mulh x17, x10, x29
    sltiu x13, x15, -307
    andi x19, x1, -302
    bgeu x8, x9, _br_taken_36
    sra x1, x18, x14
    j _br_done_36
_br_taken_36:
    or x1, x9, x20
_br_done_36:
    bgeu x21, x11, _br_taken_37
    and x4, x5, x14
    j _br_done_37
_br_taken_37:
    or x4, x11, x19
_br_done_37:
    srli x13, x7, 18
    srai x29, x11, 46
    or x13, x15, x18
    sub x28, x11, x17
    ori x8, x10, -1987
    fsub.s f22, f8, f5
    fnmsub.d f21, f0, f20, f22
    fmul.s f27, f17, f11
    bgeu x11, x28, _br_taken_38
    sltu x14, x17, x17
    j _br_done_38
_br_taken_38:
    slt x14, x18, x19
_br_done_38:
    bge x12, x19, _br_taken_39
    add x10, x10, x29
    j _br_done_39
_br_taken_39:
    srl x10, x15, x23
_br_done_39:
    fmsub.s f7, f22, f24, f12
    sraiw x7, x19, 17
    lhu x27, 868(x31)
    sh x8, 868(x31)
    addi x30, x31, 344
    amoand.d x11, x5, (x30)
    subw x1, x17, x4
    slli x27, x23, 56
    addi x20, x28, -1897
    fnmadd.d f31, f5, f31, f0
    fmul.s f27, f30, f24
    fnmadd.s f22, f12, f15, f16
    remuw x13, x5, x15
    mul x12, x5, x27
    slliw x20, x27, 21
    or x27, x18, x14
    srai x9, x27, 24
    srli x14, x20, 29
    lbu x23, 368(x31)
    sb x5, 368(x31)
    fnmadd.s f18, f11, f22, f5
    lh x29, 408(x31)
    sh x25, 408(x31)
    lwu x29, 516(x31)
    sw x25, 516(x31)
    subw x17, x29, x11
    srl x25, x21, x29
    ori x15, x20, -765
    bgeu x10, x27, _br_taken_40
    srl x27, x19, x13
    j _br_done_40
_br_taken_40:
    sltu x27, x4, x6
_br_done_40:
    sra x20, x27, x9
    fdiv.d f20, f9, f4
    addi x30, x31, 340
    amominu.w x23, x8, (x30)
    lb x5, 792(x31)
    sb x15, 792(x31)
    andi x24, x17, -422
    sltu x9, x25, x26
    slti x21, x13, -1837
    bgeu x20, x28, _br_taken_41
    sra x19, x6, x27
    j _br_done_41
_br_taken_41:
    sub x19, x5, x15
_br_done_41:
    srliw x25, x16, 3
    srliw x20, x29, 28
    ori x4, x18, 356
    sltu x26, x20, x1
    add x21, x24, x11
    slliw x6, x29, 23
    subw x5, x27, x15
    fsub.d f31, f19, f17
    fmul.d f31, f21, f21
    andi x6, x4, -1280
    mulhsu x7, x26, x1
    bltu x8, x1, _br_taken_42
    srl x26, x12, x15
    j _br_done_42
_br_taken_42:
    sub x26, x16, x19
_br_done_42:
    divuw x18, x27, x5
    remuw x15, x15, x22
    addi x30, x31, 744
    amomin.d x1, x21, (x30)
    slliw x16, x21, 4
    slliw x25, x21, 22
    srl x8, x18, x5
    srliw x24, x22, 11
    bgeu x11, x11, _br_taken_43
    sll x22, x10, x17
    j _br_done_43
_br_taken_43:
    sub x22, x7, x18
_br_done_43:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xd6ae885347a4720e
    .dword 0x418441ecce2bd5ff
    .dword 0x346d772681e890b8
    .dword 0x105965ac9859529f
    .dword 0x2666fe87448ead80
    .dword 0xbd9786a423d5eeea
    .dword 0x88049a4d99481ad0
    .dword 0x37affb6781675d41
    .dword 0x1abfd1eea640cb05
    .dword 0x7e29d039f1f6be1b
    .dword 0xa893983d6dfd2416
    .dword 0x69d649f2627eb2c9
    .dword 0xcbe9c4629014ba7b
    .dword 0x998369789489b3bf
    .dword 0x8f66b94a64ecb074
    .dword 0x8d6ccf7ae5fa3686
    .dword 0x5e870bea805bbe92
    .dword 0xa15aa034c8eb3e54
    .dword 0x39cc987a1c6ab71e
    .dword 0x1e96412d30fbabf5
    .dword 0x3a394e69bd1dd5e6
    .dword 0xb6ecc88beab941d9
    .dword 0x794ef659856e6458
    .dword 0x9f6dd6f6f51956d7
    .dword 0xf896b876f4868e03
    .dword 0x1a3516acc0afc447
    .dword 0xb64493cb38a3ea0c
    .dword 0x053aeb38c5fec1a0
    .dword 0x970ec00b2b227ff4
    .dword 0xf32242f64c7e6498
    .dword 0x4311675465b962c0
    .dword 0x1535d9a9596ce983

    .align 2
_torture_data:
    .word 0x06082803
    .word 0x5a4e717f
    .word 0x7811c235
    .word 0xdb26826d
    .word 0xc310e590
    .word 0x72cfbeb3
    .word 0xd89e4c11
    .word 0x9b83b047
    .word 0xbac07235
    .word 0x8e35d2d8
    .word 0x300f573c
    .word 0xdd2bb42f
    .word 0x173ed460
    .word 0xdd78ddae
    .word 0x1d6241d9
    .word 0xa17b2677
    .word 0x8a151644
    .word 0x0854440a
    .word 0x69a3f05a
    .word 0x3ed47dc3
    .word 0x9076dfc8
    .word 0xfba39b3d
    .word 0x98f47ea9
    .word 0x55ab23f8
    .word 0x382f0b22
    .word 0x43466887
    .word 0xd7e64895
    .word 0x9043b05a
    .word 0xaa11ebeb
    .word 0x5d2961eb
    .word 0x0d70e8dc
    .word 0x52205ba9
    .word 0x876294e2
    .word 0x0ca2c655
    .word 0xc1c7eb0f
    .word 0x08b7877a
    .word 0xabf5f496
    .word 0x039cbe4f
    .word 0x2f4f474b
    .word 0x008b556c
    .word 0xb1d1b0de
    .word 0xa4f30657
    .word 0x150567b8
    .word 0x7f1e14e6
    .word 0x88c9472a
    .word 0x7494624c
    .word 0x5dd043eb
    .word 0x695c37a4
    .word 0x1a52aeff
    .word 0x09fde76d
    .word 0x64bc4005
    .word 0xd3a14b24
    .word 0x36a775ec
    .word 0xb192f45d
    .word 0x22a30e77
    .word 0xaf4e0977
    .word 0x90333095
    .word 0x92d3ff3a
    .word 0x3d6656a1
    .word 0x34caebd9
    .word 0xad1e59c7
    .word 0xec49e259
    .word 0x8c8d5220
    .word 0xebf27298
    .word 0xf472883a
    .word 0x4992dcfe
    .word 0x8e7d70fe
    .word 0xdc00a04b
    .word 0xbef38e6c
    .word 0xdbc3817e
    .word 0x16b6cbbd
    .word 0xf12b1d2a
    .word 0xbf7bdf81
    .word 0x58559898
    .word 0xc500fdc9
    .word 0x1096e036
    .word 0x95616498
    .word 0x5bbecd55
    .word 0xced15a4b
    .word 0x6b83f8d5
    .word 0x01e77970
    .word 0x6153ff52
    .word 0x5966e825
    .word 0x34804be6
    .word 0x803fb93d
    .word 0x14486c40
    .word 0x2dd102d5
    .word 0x101d948f
    .word 0x8986631e
    .word 0xb666f48e
    .word 0x08f896c2
    .word 0xfcd26a6c
    .word 0xb3291912
    .word 0x5da81db4
    .word 0x58152dd5
    .word 0x69513f3d
    .word 0x7b216376
    .word 0xd9bf64c8
    .word 0x276a0b75
    .word 0x912d2623
    .word 0x269777f9
    .word 0x12f249b8
    .word 0xd58e1042
    .word 0xbd5df73f
    .word 0x84054272
    .word 0x744e46ba
    .word 0x0d50819f
    .word 0x03698fee
    .word 0xafdc62b7
    .word 0xa6f9ca32
    .word 0x2aafb73d
    .word 0x3f7c0901
    .word 0x2a8ca989
    .word 0x3bebdf46
    .word 0x5a5f1fef
    .word 0x0d5fbe67
    .word 0x09d47c15
    .word 0xe9ed839f
    .word 0x0325dc68
    .word 0x1b834b26
    .word 0x64c4de35
    .word 0x581eeae0
    .word 0xa1a40c6a
    .word 0x4d951212
    .word 0x8c720231
    .word 0xe2a41517
    .word 0xb1101b2c
    .word 0x08d2ef34
    .word 0xcc5028cf
    .word 0xecea579d
    .word 0x919dc3cd
    .word 0x3c7ad4a0
    .word 0x9391763f
    .word 0x147529df
    .word 0x65c72ee8
    .word 0xb8456495
    .word 0x62e685bc
    .word 0x73b46297
    .word 0x02e29ab6
    .word 0x73bc8865
    .word 0xdaa9598b
    .word 0xfb3aa858
    .word 0xe79e8ab7
    .word 0x12974dc3
    .word 0x0fa3c812
    .word 0x05e84604
    .word 0x7aebdda6
    .word 0xa4639e5e
    .word 0x2e90b033
    .word 0x3a6c4bcf
    .word 0x9f0f1d3b
    .word 0x2c0f636a
    .word 0x70537fdf
    .word 0x2d4ec8eb
    .word 0x704ebbf0
    .word 0xacec4632
    .word 0x40ff7b04
    .word 0xe3991da8
    .word 0x31818da2
    .word 0xdd92c6a3
    .word 0x5c56d7a0
    .word 0xcc6cff78
    .word 0x5b877483
    .word 0xa9a6fa8d
    .word 0xbefe36f1
    .word 0x7f938790
    .word 0xec5f7f7b
    .word 0x78d656d7
    .word 0x72bee88c
    .word 0x78cc2aba
    .word 0x269fcfbf
    .word 0xe2ad46ab
    .word 0x3f80a55b
    .word 0xd5d84aeb
    .word 0xab9d2962
    .word 0xbc1550f6
    .word 0x6f2e5a06
    .word 0x438d6b33
    .word 0xf09105bc
    .word 0xf041c9d8
    .word 0x2d4d1d32
    .word 0x4bbeff2a
    .word 0x6fb2364e
    .word 0xbfed2966
    .word 0x230f9bb7
    .word 0xc3268790
    .word 0x93ec1764
    .word 0x2a81e51d
    .word 0xba3e7725
    .word 0x8d997648
    .word 0xbac57b28
    .word 0x5be6f6a2
    .word 0xeb493706
    .word 0x23827b2d
    .word 0xa266311f
    .word 0x2fa66232
    .word 0x42618fe1
    .word 0xff15c86b
    .word 0xb3a18ddb
    .word 0x47c4fb57
    .word 0x2e5cefd5
    .word 0x553abd01
    .word 0x251c5330
    .word 0x23a555a6
    .word 0x04fe46f8
    .word 0x1a3cfa01
    .word 0x78c8851e
    .word 0x8315e83e
    .word 0x22b3e33c
    .word 0xedd0d01d
    .word 0x6787c205
    .word 0x463f45ab
    .word 0x23ed3cdc
    .word 0xd669992f
    .word 0xa0caafb9
    .word 0x84d451e5
    .word 0x4bbeb778
    .word 0x85e0d79e
    .word 0x85d578a7
    .word 0x4aaff6ab
    .word 0x1f4aea8e
    .word 0xf93b62ce
    .word 0xde5e945a
    .word 0x802fe6da
    .word 0xd0a49583
    .word 0x34bc0cbf
    .word 0x507d52e0
    .word 0xda2588a3
    .word 0x5c77bf35
    .word 0x33b0f08b
    .word 0x784d92d9
    .word 0x685f7179
    .word 0x80c21c46
    .word 0x3b303c10
    .word 0x79b761cf
    .word 0xf7a402b8
    .word 0xb122754d
    .word 0x3416bddb
    .word 0xb8738909
    .word 0xbe8698e5
    .word 0xb1b7b1e6
    .word 0xe99f874b
    .word 0xad4ca4cb
    .word 0x995707bb
    .word 0x0278bc2d
    .word 0x2844eea6
    .word 0xb8933a88
    .word 0x3382a556
    .word 0xef12a1b8
    .word 0xb4e311e0
    .word 0x8293b423
    .word 0xc3a37eda
    .word 0x646ceebe
    .word 0x8e093a71
    .word 0x3910bd93
    .word 0xa04c12aa

#include "frost_footer.S"
