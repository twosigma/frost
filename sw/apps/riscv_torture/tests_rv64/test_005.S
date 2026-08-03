// Generated RV64IMAFDC torture test for Frost (seed=20260807)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x5c934eb0ef4a70d5
    li x4, 0x502d7ab70ebf0d08
    li x5, 0x79e3d4a0d35510ab
    li x6, 0xe4481dfa13d53823
    li x7, 0x80f651d1b8f4c2e5
    li x8, 0x86aa0709e9a1dcde
    li x9, 0x04796692e0b335ca
    li x10, 0xb4b55dc01dcb6cf0
    li x11, 0x57a84ec928c26106
    li x12, 0x96495d031ff4ab3d
    li x13, 0x11be58f228bd9eb9
    li x14, 0x8b17e9aba9b36f3a
    li x15, 0xbf2f916dd3ffb85b
    li x16, 0x69310b5eb08546e7
    li x17, 0x7ce0a3aed64a3e99
    li x18, 0xdb26d8364746b3b8
    li x19, 0x35c33d4132293494
    li x20, 0x235abdcfeb85e28c
    li x21, 0x12c40c601be1ab01
    li x22, 0x952e1fae4551b6fa
    li x23, 0xc070fee87143944f
    li x24, 0x714a986b5706f21c
    li x25, 0x97043a1fe1dda8e5
    li x26, 0xe9e24e24fd0dc961
    li x27, 0x8cd1a20f84143437
    li x28, 0x1d148f43154e2121
    li x29, 0x797850c98635ba4d
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
    li x1, 0x8f48e96988cc9afa

    bltu x10, x26, _br_taken_0
    and x18, x10, x16
    j _br_done_0
_br_taken_0:
    add x18, x9, x17
_br_done_0:
    bge x7, x22, _br_taken_1
    and x29, x12, x8
    j _br_done_1
_br_taken_1:
    xor x29, x21, x8
_br_done_1:
    xor x26, x25, x15
    divuw x29, x29, x12
    or x5, x24, x9
    sraiw x11, x20, 25
    addi x24, x16, -1176
    sltu x4, x4, x24
    addw x24, x19, x27
    lwu x18, 36(x31)
    sw x19, 36(x31)
    lwu x16, 348(x31)
    sw x17, 348(x31)
    sll x5, x8, x6
    srlw x24, x12, x17
    srlw x14, x18, x4
    slliw x13, x11, 10
    srai x19, x7, 35
    slliw x25, x9, 11
    sraiw x18, x10, 21
    sllw x21, x12, x19
    mulhsu x27, x24, x4
    mulw x13, x25, x10
    bge x9, x19, _br_taken_2
    sll x15, x24, x20
    j _br_done_2
_br_taken_2:
    slt x15, x23, x14
_br_done_2:
    addi x30, x31, 568
    amoor.w x15, x18, (x30)
    fmadd.s f27, f25, f9, f6
    fnmsub.s f25, f9, f6, f2
    add x19, x5, x24
    sraw x1, x20, x7
    srliw x20, x9, 19
    srliw x6, x12, 10
    sraiw x11, x28, 15
    xor x21, x19, x26
    bltu x8, x12, _br_taken_3
    slt x1, x22, x4
    j _br_done_3
_br_taken_3:
    srl x1, x29, x15
_br_done_3:
    sllw x14, x29, x1
    xori x19, x21, 1441
    bgeu x28, x5, _br_taken_4
    and x17, x20, x29
    j _br_done_4
_br_taken_4:
    or x17, x16, x18
_br_done_4:
    mulhsu x11, x7, x29
    addi x30, x31, 444
    amoor.w x24, x18, (x30)
    fmul.s f2, f26, f31
    fmax.d f18, f6, f27
    fmul.d f16, f18, f10
    ld x20, 528(x31)
    sd x25, 528(x31)
    ld x21, 88(x31)
    sd x10, 88(x31)
    srlw x12, x9, x17
    fmin.s f7, f14, f19
    fadd.d f23, f17, f21
    fmul.s f13, f17, f1
    fmax.d f30, f5, f6
    fnmadd.d f18, f20, f21, f20
    srai x19, x25, 50
    sraiw x9, x9, 5
    addw x26, x4, x5
    srli x22, x1, 5
    slti x23, x15, 1520
    bge x7, x1, _br_taken_5
    and x18, x13, x12
    j _br_done_5
_br_taken_5:
    sub x18, x17, x9
_br_done_5:
    slti x13, x29, 1444
    bltu x22, x28, _br_taken_6
    srl x8, x4, x22
    j _br_done_6
_br_taken_6:
    add x8, x15, x5
_br_done_6:
    subw x27, x26, x4
    srliw x5, x20, 9
    subw x10, x7, x17
    andi x7, x23, -1443
    slli x10, x23, 60
    fnmsub.s f24, f14, f27, f6
    fsub.s f12, f31, f15
    fsub.d f21, f23, f0
    slli x13, x12, 4
    sub x28, x21, x23
    bne x24, x1, _br_taken_7
    sra x23, x28, x12
    j _br_done_7
_br_taken_7:
    sll x23, x9, x26
_br_done_7:
    addi x30, x31, 520
    amoswap.d x16, x7, (x30)
    slliw x28, x4, 7
    addiw x10, x18, 1982
    or x25, x26, x21
    fmin.s f18, f23, f1
    bne x21, x8, _br_taken_8
    slt x27, x20, x4
    j _br_done_8
_br_taken_8:
    and x27, x15, x14
_br_done_8:
    sraiw x7, x21, 1
    srai x1, x19, 49
    srai x7, x4, 37
    addi x30, x31, 504
    amoswap.w x13, x26, (x30)
    sra x23, x9, x16
    lbu x21, 284(x31)
    sb x13, 284(x31)
    srli x1, x10, 54
    slti x18, x16, -1671
    srli x21, x27, 59
    lb x22, 692(x31)
    sb x11, 692(x31)
    sraiw x6, x12, 5
    sraw x22, x6, x18
    and x22, x13, x23
    srl x6, x9, x4
    subw x14, x23, x7
    sll x23, x24, x1
    blt x21, x19, _br_taken_9
    sltu x16, x11, x17
    j _br_done_9
_br_taken_9:
    sltu x16, x5, x21
_br_done_9:
    sra x24, x27, x16
    srli x26, x27, 5
    fdiv.s f1, f0, f30
    bge x23, x5, _br_taken_10
    add x1, x19, x1
    j _br_done_10
_br_taken_10:
    slt x1, x17, x20
_br_done_10:
    bgeu x23, x17, _br_taken_11
    xor x21, x20, x19
    j _br_done_11
_br_taken_11:
    add x21, x12, x22
_br_done_11:
    div x9, x6, x7
    bne x14, x1, _br_taken_12
    add x4, x20, x4
    j _br_done_12
_br_taken_12:
    and x4, x18, x28
_br_done_12:
    srai x5, x19, 10
    srliw x5, x18, 23
    sllw x12, x24, x21
    fmul.s f10, f2, f13
    fmsub.d f31, f10, f8, f12
    bne x13, x17, _br_taken_13
    sra x21, x4, x22
    j _br_done_13
_br_taken_13:
    sll x21, x20, x12
_br_done_13:
    srl x17, x26, x14
    slti x18, x15, 682
    xori x29, x12, -388
    srl x20, x21, x23
    or x14, x10, x9
    lb x20, 428(x31)
    sb x22, 428(x31)
    andi x15, x9, -162
    sltu x15, x27, x25
    srl x22, x1, x18
    or x25, x18, x27
    ori x1, x1, 165
    bne x10, x9, _br_taken_14
    sra x5, x11, x21
    j _br_done_14
_br_taken_14:
    or x5, x1, x29
_br_done_14:
    bltu x14, x15, _br_taken_15
    sll x19, x13, x21
    j _br_done_15
_br_taken_15:
    sub x19, x23, x17
_br_done_15:
    srliw x20, x12, 27
    addiw x11, x21, -853
    slli x6, x27, 3
    lwu x18, 68(x31)
    sw x28, 68(x31)
    srliw x11, x13, 29
    srli x18, x18, 31
    sraw x23, x14, x7
    addw x19, x1, x18
    lh x8, 988(x31)
    sh x21, 988(x31)
    fmin.s f12, f0, f29
    fmax.d f12, f26, f11
    addi x30, x31, 376
    amoswap.d x25, x8, (x30)
    sltiu x24, x11, -1441
    bge x15, x28, _br_taken_16
    xor x4, x20, x5
    j _br_done_16
_br_taken_16:
    or x4, x13, x14
_br_done_16:
    blt x12, x13, _br_taken_17
    and x5, x7, x26
    j _br_done_17
_br_taken_17:
    sra x5, x25, x11
_br_done_17:
    lhu x27, 252(x31)
    sh x10, 252(x31)
    srliw x22, x5, 1
    xor x24, x17, x18
    slliw x22, x14, 26
    bltu x22, x4, _br_taken_18
    sltu x26, x19, x4
    j _br_done_18
_br_taken_18:
    srl x26, x12, x10
_br_done_18:
    mulw x4, x1, x25
    mulh x17, x8, x1
    sltiu x5, x14, -286
    srliw x4, x21, 18
    ori x13, x21, -1187
    srl x21, x14, x19
    sll x28, x24, x22
    addiw x29, x13, -1200
    sub x14, x15, x15
    or x11, x14, x13
    andi x17, x29, -1512
    xori x17, x8, 1237
    srliw x14, x1, 16
    xor x25, x24, x17
    fdiv.s f25, f4, f9
    fmax.d f17, f20, f24
    fadd.s f20, f16, f0
    sraw x26, x26, x17
    sra x7, x5, x25
    sraiw x28, x14, 31
    fsub.s f31, f30, f11
    fmadd.s f6, f17, f13, f28
    srli x22, x20, 56
    xori x18, x13, -657
    sraiw x14, x20, 9
    bgeu x9, x29, _br_taken_19
    and x12, x29, x1
    j _br_done_19
_br_taken_19:
    add x12, x24, x4
_br_done_19:
    addw x17, x29, x14
    slti x29, x4, 1202
    and x15, x24, x11
    sraiw x18, x4, 29
    srai x25, x9, 4
    remu x4, x12, x22
    mulh x11, x17, x21
    sraiw x20, x10, 1
    divw x10, x23, x18
    blt x26, x29, _br_taken_20
    or x4, x22, x14
    j _br_done_20
_br_taken_20:
    sub x4, x8, x21
_br_done_20:
    fdiv.s f9, f0, f26
    beq x17, x4, _br_taken_21
    sra x17, x20, x7
    j _br_done_21
_br_taken_21:
    srl x17, x9, x7
_br_done_21:
    addiw x23, x13, -1214
    srai x29, x12, 25
    srlw x27, x6, x18
    slti x18, x7, 1912
    ori x20, x10, -1055
    xor x10, x26, x13
    subw x20, x25, x11
    fmin.d f8, f27, f15
    fmul.d f4, f16, f2
    addi x30, x31, 608
    amoor.d x14, x7, (x30)
    addw x10, x19, x11
    xor x23, x27, x19
    subw x7, x25, x25
    sll x13, x1, x23
    slliw x15, x11, 29
    slliw x18, x23, 3
    remuw x21, x13, x6
    bne x29, x23, _br_taken_22
    or x25, x21, x26
    j _br_done_22
_br_taken_22:
    srl x25, x11, x6
_br_done_22:
    sraiw x26, x8, 22
    addi x14, x28, 1701
    subw x6, x10, x24
    bgeu x16, x22, _br_taken_23
    and x18, x21, x25
    j _br_done_23
_br_taken_23:
    and x18, x21, x5
_br_done_23:
    bge x16, x24, _br_taken_24
    add x5, x9, x24
    j _br_done_24
_br_taken_24:
    sub x5, x18, x20
_br_done_24:
    fmul.d f24, f12, f26
    bgeu x1, x23, _br_taken_25
    sll x7, x17, x28
    j _br_done_25
_br_taken_25:
    sltu x7, x19, x26
_br_done_25:
    srliw x7, x11, 19
    xor x10, x8, x13
    bge x27, x26, _br_taken_26
    sra x27, x13, x7
    j _br_done_26
_br_taken_26:
    xor x27, x9, x6
_br_done_26:
    bge x14, x17, _br_taken_27
    sub x19, x23, x12
    j _br_done_27
_br_taken_27:
    sltu x19, x16, x14
_br_done_27:
    mulhu x23, x25, x23
    sllw x17, x19, x10
    addiw x17, x25, 360
    slli x12, x10, 59
    addw x6, x13, x28
    remw x19, x15, x26
    divu x17, x21, x20
    sltiu x18, x26, 952
    xori x14, x13, 1740
    addw x1, x6, x29
    slt x13, x26, x27
    fadd.s f8, f30, f6
    fdiv.s f17, f2, f28
    fadd.s f28, f19, f20
    addi x30, x31, 920
    amomax.d x15, x15, (x30)
    bgeu x16, x25, _br_taken_28
    xor x25, x16, x16
    j _br_done_28
_br_taken_28:
    sltu x25, x13, x28
_br_done_28:
    sraiw x20, x17, 16
    srli x1, x22, 26
    srlw x25, x27, x18
    addw x25, x10, x29
    addi x7, x12, 12
    sraiw x6, x27, 21
    bltu x21, x11, _br_taken_29
    sll x6, x24, x20
    j _br_done_29
_br_taken_29:
    add x6, x27, x1
_br_done_29:
    srl x17, x21, x13
    sll x28, x18, x15
    or x21, x24, x5
    slli x9, x28, 21
    srai x4, x13, 42
    srli x11, x21, 16
    sraw x13, x18, x27
    subw x23, x12, x12
    sra x24, x20, x6
    ori x28, x15, 2047
    fmax.s f27, f26, f3
    fnmsub.d f1, f13, f2, f14
    fmin.d f14, f29, f11
    lw x17, 100(x31)
    sw x1, 100(x31)
    sub x29, x13, x20
    sraiw x4, x18, 30
    ori x17, x1, 1060
    mulh x28, x22, x27
    srliw x12, x6, 15
    sltiu x21, x7, -1020
    srli x26, x18, 46
    sra x10, x23, x27
    and x1, x8, x25
    sltiu x25, x25, -1281
    bgeu x13, x17, _br_taken_30
    slt x20, x22, x29
    j _br_done_30
_br_taken_30:
    or x20, x6, x28
_br_done_30:
    slti x29, x4, -600
    sraiw x20, x5, 4
    addi x30, x31, 168
    amoor.w x12, x28, (x30)
    sltiu x21, x16, 1973
    sraw x8, x9, x15
    sraiw x17, x10, 11
    bne x11, x1, _br_taken_31
    sub x24, x18, x20
    j _br_done_31
_br_taken_31:
    sltu x24, x1, x24
_br_done_31:
    subw x26, x1, x17
    sllw x14, x28, x1
    addi x24, x19, 1894
    xori x24, x4, 829
    sltiu x25, x10, -1445
    xori x12, x22, -850
    bge x1, x13, _br_taken_32
    sra x5, x5, x11
    j _br_done_32
_br_taken_32:
    and x5, x7, x12
_br_done_32:
    sra x16, x19, x12
    lwu x9, 844(x31)
    sw x11, 844(x31)
    lwu x9, 196(x31)
    sw x24, 196(x31)
    slli x8, x9, 25
    xor x4, x17, x12
    bne x21, x1, _br_taken_33
    and x1, x7, x8
    j _br_done_33
_br_taken_33:
    srl x1, x13, x19
_br_done_33:
    bge x25, x27, _br_taken_34
    xor x7, x4, x10
    j _br_done_34
_br_taken_34:
    slt x7, x1, x1
_br_done_34:
    fdiv.s f25, f30, f17
    fmadd.d f16, f13, f17, f27
    slliw x24, x12, 21
    beq x16, x12, _br_taken_35
    sltu x20, x5, x16
    j _br_done_35
_br_taken_35:
    and x20, x5, x11
_br_done_35:
    addiw x24, x11, -1481
    slti x27, x1, 1494
    or x22, x8, x9
    sub x21, x6, x27
    sra x8, x29, x19
    blt x4, x29, _br_taken_36
    sll x12, x17, x23
    j _br_done_36
_br_taken_36:
    sub x12, x8, x9
_br_done_36:
    ori x15, x17, 1218
    srliw x24, x15, 23
    xori x22, x11, 326
    sltiu x8, x5, -1460
    sraw x21, x15, x20
    slliw x14, x17, 21
    addi x30, x31, 496
    amoswap.w x15, x4, (x30)
    fmax.d f8, f31, f12
    ori x11, x13, 666
    sraiw x5, x10, 5
    sraw x28, x24, x5
    ori x11, x22, 917
    bgeu x25, x18, _br_taken_37
    srl x6, x13, x28
    j _br_done_37
_br_taken_37:
    slt x6, x25, x9
_br_done_37:
    slliw x16, x25, 2
    beq x11, x26, _br_taken_38
    or x14, x24, x27
    j _br_done_38
_br_taken_38:
    or x14, x4, x18
_br_done_38:
    srli x22, x27, 11
    sra x13, x28, x14
    sra x16, x21, x7
    srl x23, x26, x21
    bne x13, x24, _br_taken_39
    sub x8, x20, x15
    j _br_done_39
_br_taken_39:
    sra x8, x19, x9
_br_done_39:
    addw x22, x23, x18
    srai x7, x26, 26
    slti x5, x5, 1811
    srlw x29, x27, x13
    addiw x29, x16, -1088
    addiw x11, x27, -493
    slli x8, x22, 46
    sltiu x27, x18, -1202
    mulhsu x21, x4, x7
    or x12, x14, x12
    sra x21, x22, x16
    sllw x14, x18, x5
    andi x24, x25, -836
    slliw x14, x22, 18
    rem x20, x13, x24
    remuw x13, x4, x19
    sra x6, x5, x20
    andi x20, x1, -1673
    fnmadd.d f14, f0, f18, f9
    fnmsub.d f22, f19, f22, f27
    addi x11, x17, -93
    sraiw x6, x17, 28
    xor x24, x5, x28
    beq x7, x18, _br_taken_40
    xor x18, x11, x13
    j _br_done_40
_br_taken_40:
    sub x18, x5, x15
_br_done_40:
    sllw x6, x18, x25
    srliw x12, x19, 10
    bltu x15, x1, _br_taken_41
    xor x23, x17, x25
    j _br_done_41
_br_taken_41:
    add x23, x10, x28
_br_done_41:
    sraw x19, x9, x23
    srli x1, x18, 42
    xori x23, x29, -1532
    remuw x22, x23, x13
    mulhu x1, x23, x18
    fdiv.s f13, f26, f3
    bgeu x15, x23, _br_taken_42
    xor x9, x27, x20
    j _br_done_42
_br_taken_42:
    slt x9, x10, x20
_br_done_42:
    bge x27, x9, _br_taken_43
    sra x16, x7, x4
    j _br_done_43
_br_taken_43:
    sltu x16, x17, x20
_br_done_43:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xc8ee5b7078e00aea
    .dword 0x7f851d3fceeb44bc
    .dword 0x96092daa1f505c1e
    .dword 0x06d56682912701a3
    .dword 0xa121cc372ed456d9
    .dword 0xfa8f2c6909f565a0
    .dword 0x7c33f8a80cfa00d4
    .dword 0xa525e09f229f9011
    .dword 0xdceb525560c99d42
    .dword 0x590f6dcafacf7ea2
    .dword 0x9fc5e2e10f973b34
    .dword 0x2beaa93a9b6d4627
    .dword 0x121ebdd394097675
    .dword 0xe9aa767f41ead31d
    .dword 0x4a3c858aa3a7c051
    .dword 0x484ec80b2f5155a1
    .dword 0x3678cfe410e1f3c7
    .dword 0xb7817c9179ff145a
    .dword 0x8f84a0f596486415
    .dword 0x99691c73a45002c8
    .dword 0x6b5092d09cf76b91
    .dword 0x5151ca7f6ebaf4e7
    .dword 0x395ba8a951133a55
    .dword 0x1fa873a947bfaa86
    .dword 0xbe072b31589ce3d1
    .dword 0x5ebda2b6cdca5b8d
    .dword 0xd640d72ea66089d9
    .dword 0xd8372fc9650b5b94
    .dword 0x0844f4e5bcddc5d7
    .dword 0x20230f1411b988f0
    .dword 0x71052f88de9b1460
    .dword 0x0b21db079f4ace6e

    .align 2
_torture_data:
    .word 0xf01d492b
    .word 0x1dee6198
    .word 0x7c89706e
    .word 0xa5db30ee
    .word 0x91bdb2d6
    .word 0x2e4e1a96
    .word 0xe972dbea
    .word 0x7652808f
    .word 0xdb965f11
    .word 0x722446f4
    .word 0x7d16afbb
    .word 0x6b8adc3d
    .word 0x09e52530
    .word 0xd13ac63f
    .word 0xa2f54c11
    .word 0x2955f42f
    .word 0xba7e1028
    .word 0xe5387fa3
    .word 0x574a97dc
    .word 0x79852be4
    .word 0x9e24a64a
    .word 0x0a10c6ab
    .word 0x1db920b8
    .word 0xd9f074af
    .word 0x78240195
    .word 0xb0814387
    .word 0x6cb48dd0
    .word 0xb27ccfe0
    .word 0xbf87d55c
    .word 0xb413d040
    .word 0x1d449755
    .word 0xe88be2b6
    .word 0xb71459fe
    .word 0x3cceb0cd
    .word 0xf8457d97
    .word 0x16f08240
    .word 0xca1253c3
    .word 0xbd3ef538
    .word 0x422ebf43
    .word 0x85fe2c40
    .word 0xec68e904
    .word 0x7aedcdef
    .word 0x3dc21568
    .word 0x2b703609
    .word 0x23ba4e3f
    .word 0x73eabf83
    .word 0x3613b150
    .word 0x571690b3
    .word 0xd55a3f95
    .word 0x5e7b8e27
    .word 0xdee06521
    .word 0x00c0cd53
    .word 0x5a7e156a
    .word 0x1c205d06
    .word 0xfcff7142
    .word 0xf854432a
    .word 0xc80c9742
    .word 0xcac8adf7
    .word 0xa11ab215
    .word 0x09614ef4
    .word 0x9c3b9999
    .word 0xb79b0bc8
    .word 0x4fd96e17
    .word 0x528d3e03
    .word 0x84fdc86b
    .word 0x870474a0
    .word 0x5e7c2b99
    .word 0x9bfbe5be
    .word 0x2480b02e
    .word 0x2abd2059
    .word 0xfefb3017
    .word 0xed01edef
    .word 0x2e893dfe
    .word 0x15c6cef2
    .word 0x46f93367
    .word 0x052f6e20
    .word 0xc270f2f0
    .word 0x9505507c
    .word 0x5e281af6
    .word 0xbf78aa66
    .word 0x3eae41ee
    .word 0x485760ad
    .word 0x199091df
    .word 0xc7dec896
    .word 0xa06ab902
    .word 0x07db1c3c
    .word 0x74e0148a
    .word 0x07fa15ef
    .word 0xcfa4f588
    .word 0xbadb545e
    .word 0xdb098111
    .word 0x44b00841
    .word 0xfb3f0b6f
    .word 0xa691bf56
    .word 0xb0034213
    .word 0xd49ea601
    .word 0x2ca53aac
    .word 0x6d33287b
    .word 0x86eb5f02
    .word 0xf4f5e4a5
    .word 0x8569db81
    .word 0x69610078
    .word 0x9ba840b8
    .word 0x24536732
    .word 0x27742668
    .word 0x8347b556
    .word 0xd81a65d1
    .word 0x4e146e8a
    .word 0x30c7c237
    .word 0xab06af82
    .word 0xebe4496d
    .word 0xee9174fe
    .word 0x45d350c5
    .word 0x8c1f1640
    .word 0xa7f8af5b
    .word 0x8ceb8281
    .word 0xfc68036b
    .word 0x48d5c9da
    .word 0x2572b9cd
    .word 0xf49bf65a
    .word 0x6b131ba7
    .word 0xb86fcf78
    .word 0x77a04688
    .word 0x8dbff72c
    .word 0xd6365cd6
    .word 0xc129b4c3
    .word 0xda96da26
    .word 0x70e1bd6a
    .word 0x2dedf3eb
    .word 0xfda1b34d
    .word 0xebfebeac
    .word 0xab52d449
    .word 0xc7d99ab9
    .word 0xc406189e
    .word 0x5a08d0dc
    .word 0xc15625b7
    .word 0xfcd007bd
    .word 0x307a2c71
    .word 0x1afbfbe2
    .word 0x5c11ed67
    .word 0xa5d34b27
    .word 0xb195ac97
    .word 0x928c0459
    .word 0xb09cd008
    .word 0x7291f71f
    .word 0xc91dd452
    .word 0xb7a8fa9c
    .word 0x9b6826b5
    .word 0x86110636
    .word 0x8ef4a94f
    .word 0x018edefe
    .word 0x04d4baab
    .word 0xa7888357
    .word 0x6952f266
    .word 0x627049a5
    .word 0x841aa3b6
    .word 0x5836fe1a
    .word 0x05a84953
    .word 0x2aab102b
    .word 0x22653dbf
    .word 0x452aafdc
    .word 0x5d77d08c
    .word 0xcfc490db
    .word 0xf55dda5a
    .word 0x818e75f5
    .word 0xe4eb8563
    .word 0x6fd84918
    .word 0xfffb1164
    .word 0xde3a3b67
    .word 0x874eebc5
    .word 0x937c5f57
    .word 0x65d0552c
    .word 0x9b4366ac
    .word 0x1906ae31
    .word 0x1a4ed38b
    .word 0x98e26a57
    .word 0xc851752c
    .word 0x1abf9547
    .word 0xba63aa1c
    .word 0x49c7bd62
    .word 0xa495e20c
    .word 0xb27d894c
    .word 0x7c277481
    .word 0x7c8627d9
    .word 0x58f4d652
    .word 0x4d63e094
    .word 0xc1a06022
    .word 0xb3674b7b
    .word 0x356a2b87
    .word 0x49a2a8fc
    .word 0xfe983c2f
    .word 0xb80a4bc9
    .word 0xdafa3b2c
    .word 0xd601a6ee
    .word 0xca97096c
    .word 0xc1fbc15b
    .word 0x332e3031
    .word 0x4325424f
    .word 0x6cce5613
    .word 0xa3508808
    .word 0xd0bbb312
    .word 0x4ddd3bae
    .word 0xf8bfde6a
    .word 0xd851af5a
    .word 0x05d41e1b
    .word 0x04ed8513
    .word 0x45fa2122
    .word 0xc2fb14ee
    .word 0x3dd09348
    .word 0x41d74abb
    .word 0xcd6b973a
    .word 0x8bfb3323
    .word 0x6cad901d
    .word 0x453597e4
    .word 0x0486035b
    .word 0xa4d714b7
    .word 0xecc9f8aa
    .word 0x45fbd01e
    .word 0x07c4659b
    .word 0x9bea1e7a
    .word 0x6e00ac50
    .word 0x18cfc3ad
    .word 0x69d45ceb
    .word 0x39a82928
    .word 0x1427b5cd
    .word 0xb9dfd50c
    .word 0x45581d5e
    .word 0x899dea84
    .word 0x4b645beb
    .word 0x4cb133aa
    .word 0x90796b1c
    .word 0xe538b10f
    .word 0x1e4924bf
    .word 0xfab99959
    .word 0x168c97b6
    .word 0x12897bfb
    .word 0xf420b9ff
    .word 0xa87e4923
    .word 0x0794c28d
    .word 0x8c6bd99d
    .word 0xedfffda8
    .word 0x4ee36cee
    .word 0xd56e35df
    .word 0xd5c6ee26
    .word 0xe1464149
    .word 0xa72ed2e9
    .word 0xd4b70abb
    .word 0x858730ca
    .word 0xce7115d6
    .word 0x291ae2a0
    .word 0xa0e81baf
    .word 0x7702af3d
    .word 0xdd35abce
    .word 0xb3bb2c66
    .word 0x88795005
    .word 0x42a5ebc1

#include "frost_footer.S"
