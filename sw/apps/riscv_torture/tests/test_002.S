// Generated RV32IMAFDC torture test for Frost (seed=43)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x09de8895
    li x4, 0x76688387
    li x5, 0xcafedacf
    li x6, 0x6f1f16f1
    li x7, 0x2d1aa9ea
    li x8, 0xd9d2f5ed
    li x9, 0xd1f9effa
    li x10, 0x60383fa0
    li x11, 0x18829eed
    li x12, 0x7ef85d5b
    li x13, 0xc5b58496
    li x14, 0x81b584eb
    li x15, 0x933d9d81
    li x16, 0x607e2b46
    li x17, 0x0fab80c5
    li x18, 0xf120986b
    li x19, 0xd6cf23c0
    li x20, 0x4bd120b4
    li x21, 0xe38544f3
    li x22, 0xade3702d
    li x23, 0x9f6c6415
    li x24, 0x54ce7017
    li x25, 0xb37ee754
    li x26, 0x2ab49ae1
    li x27, 0xd92e1a26
    li x28, 0xc7e6c971
    li x29, 0x97668966
    li x30, 0x9abf39b8
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
    li x1, 0x1d0159fd

    xori x4, x18, 1351
    slli x14, x7, 5
    srli x21, x28, 19
    sltu x4, x7, x1
    sub x7, x26, x1
    ori x6, x25, 2032
    and x30, x15, x5
    slli x25, x9, 25
    sltu x15, x11, x22
    lw x15, 668(x31)
    sw x14, 668(x31)
    srai x25, x26, 3
    blt x10, x14, _br_taken_0
    srl x9, x15, x29
    j _br_done_0
_br_taken_0:
    or x9, x10, x4
_br_done_0:
    add x20, x30, x22
    fmin.s f22, f16, f14
    fsub.d f15, f0, f6
    fnmsub.s f12, f24, f27, f6
    and x11, x20, x7
    srli x25, x10, 12
    sra x29, x23, x28
    and x10, x1, x26
    sll x12, x21, x24
    xor x17, x12, x27
    bge x30, x20, _br_taken_1
    or x22, x26, x16
    j _br_done_1
_br_taken_1:
    slt x22, x29, x21
_br_done_1:
    srli x22, x26, 1
    slli x27, x23, 14
    srl x22, x28, x26
    fdiv.d f26, f19, f4
    slti x7, x6, 584
    and x6, x28, x15
    bge x13, x12, _br_taken_2
    srl x29, x10, x28
    j _br_done_2
_br_taken_2:
    xor x29, x8, x14
_br_done_2:
    sltu x12, x19, x23
    sll x12, x7, x28
    sltu x19, x25, x25
    remu x15, x19, x8
    div x29, x6, x29
    blt x7, x6, _br_taken_3
    or x29, x12, x19
    j _br_done_3
_br_taken_3:
    sra x29, x6, x7
_br_done_3:
    lbu x4, 804(x31)
    sb x15, 804(x31)
    bltu x18, x20, _br_taken_4
    sub x23, x1, x24
    j _br_done_4
_br_taken_4:
    xor x23, x18, x29
_br_done_4:
    srai x17, x25, 5
    bltu x16, x18, _br_taken_5
    sll x7, x14, x1
    j _br_done_5
_br_taken_5:
    sub x7, x11, x13
_br_done_5:
    divu x8, x1, x23
    xori x17, x4, -1955
    slli x10, x6, 12
    bne x4, x27, _br_taken_6
    add x15, x6, x6
    j _br_done_6
_br_taken_6:
    sra x15, x1, x5
_br_done_6:
    bltu x24, x30, _br_taken_7
    srl x28, x11, x11
    j _br_done_7
_br_taken_7:
    or x28, x22, x8
_br_done_7:
    bgeu x25, x13, _br_taken_8
    sltu x18, x16, x23
    j _br_done_8
_br_taken_8:
    or x18, x24, x13
_br_done_8:
    slti x16, x23, 1924
    sltiu x29, x29, -782
    sltu x8, x27, x30
    sub x6, x1, x23
    sltiu x29, x19, 1183
    and x6, x15, x5
    slli x30, x16, 2
    srai x26, x24, 6
    xori x28, x19, -1865
    sra x24, x16, x20
    sub x1, x22, x1
    or x11, x11, x30
    mul x14, x17, x12
    mul x6, x23, x15
    slli x14, x4, 13
    xori x13, x14, 1626
    slt x8, x6, x17
    sltu x26, x11, x11
    or x6, x13, x13
    slti x27, x20, 1898
    xori x27, x15, -1759
    add x8, x12, x9
    bltu x23, x13, _br_taken_9
    slt x7, x22, x19
    j _br_done_9
_br_taken_9:
    xor x7, x16, x21
_br_done_9:
    and x12, x22, x26
    sltiu x30, x8, -1552
    sll x6, x17, x26
    addi x24, x28, -1299
    sltiu x30, x4, -681
    srli x19, x29, 23
    slli x14, x22, 28
    beq x24, x18, _br_taken_10
    sub x21, x27, x6
    j _br_done_10
_br_taken_10:
    sll x21, x7, x18
_br_done_10:
    or x7, x23, x17
    ori x13, x29, -1890
    ori x5, x26, 1594
    beq x15, x13, _br_taken_11
    slt x12, x8, x10
    j _br_done_11
_br_taken_11:
    srl x12, x16, x20
_br_done_11:
    lb x13, 768(x31)
    sb x10, 768(x31)
    andi x13, x6, 1900
    slli x15, x4, 1
    add x15, x21, x30
    sltu x13, x30, x4
    srai x24, x7, 3
    xori x28, x14, -1377
    addi x1, x31, 564
    amoor.w x6, x28, (x1)
    xor x22, x16, x29
    lw x24, 720(x31)
    sw x14, 720(x31)
    and x22, x16, x18
    slli x27, x29, 3
    or x17, x28, x28
    sltu x19, x27, x5
    fmax.d f1, f20, f25
    fsub.d f29, f3, f7
    fadd.s f26, f0, f18
    lh x11, 908(x31)
    sh x7, 908(x31)
    ori x26, x19, 1102
    sra x14, x23, x7
    sltiu x22, x29, -1933
    srli x24, x1, 27
    sub x24, x8, x19
    srl x15, x17, x19
    srli x22, x17, 13
    slli x5, x8, 19
    add x17, x14, x4
    sub x1, x29, x12
    bgeu x21, x10, _br_taken_12
    sltu x11, x1, x24
    j _br_done_12
_br_taken_12:
    sra x11, x26, x16
_br_done_12:
    mul x6, x9, x13
    fnmadd.s f21, f2, f17, f5
    fnmadd.s f13, f17, f25, f24
    fadd.s f19, f28, f16
    addi x17, x16, 542
    srl x15, x16, x29
    sll x26, x27, x24
    bltu x26, x21, _br_taken_13
    and x28, x15, x9
    j _br_done_13
_br_taken_13:
    sll x28, x1, x10
_br_done_13:
    add x21, x1, x17
    bgeu x28, x14, _br_taken_14
    sll x24, x26, x25
    j _br_done_14
_br_taken_14:
    srl x24, x12, x6
_br_done_14:
    and x10, x25, x29
    bne x23, x11, _br_taken_15
    srl x23, x27, x17
    j _br_done_15
_br_taken_15:
    add x23, x1, x11
_br_done_15:
    sltu x24, x9, x30
    sltiu x30, x1, 261
    slli x19, x15, 30
    sub x26, x12, x29
    ori x18, x28, 1513
    addi x24, x7, 1979
    ori x27, x30, 1092
    or x12, x4, x19
    add x21, x26, x16
    lw x6, 112(x31)
    sw x1, 112(x31)
    srai x9, x5, 22
    sub x24, x22, x28
    slti x14, x15, -705
    bltu x24, x8, _br_taken_16
    and x27, x29, x1
    j _br_done_16
_br_taken_16:
    add x27, x1, x6
_br_done_16:
    slli x27, x5, 17
    sltiu x29, x8, -1214
    fmul.s f3, f21, f17
    fdiv.s f9, f0, f1
    fdiv.s f10, f7, f5
    lb x30, 936(x31)
    sb x5, 936(x31)
    beq x1, x4, _br_taken_17
    xor x20, x8, x4
    j _br_done_17
_br_taken_17:
    sra x20, x23, x8
_br_done_17:
    sub x16, x28, x10
    sltiu x11, x29, -715
    sltiu x10, x15, 1039
    sltu x10, x15, x11
    xori x25, x15, 226
    xor x14, x4, x6
    slti x21, x29, -1789
    slti x14, x4, 663
    lh x9, 696(x31)
    sh x28, 696(x31)
    lbu x13, 80(x31)
    sb x14, 80(x31)
    addi x1, x31, 264
    amoadd.w x9, x21, (x1)
    lb x13, 872(x31)
    sb x18, 872(x31)
    sub x22, x1, x4
    bltu x8, x17, _br_taken_18
    xor x1, x16, x9
    j _br_done_18
_br_taken_18:
    add x1, x11, x21
_br_done_18:
    fmax.d f13, f2, f28
    fmadd.d f18, f5, f27, f19
    slti x17, x21, 4
    sub x30, x23, x22
    lbu x13, 264(x31)
    sb x26, 264(x31)
    mul x16, x10, x10
    mulhsu x27, x8, x15
    fdiv.d f3, f7, f6
    fdiv.d f11, f16, f7
    fadd.s f16, f23, f1
    ori x28, x10, -282
    sltu x15, x20, x22
    lhu x16, 1012(x31)
    sh x22, 1012(x31)
    sltiu x18, x1, -2027
    sra x13, x6, x10
    sra x29, x28, x18
    sub x24, x10, x26
    xor x13, x26, x17
    addi x5, x18, 1294
    andi x1, x27, -1495
    slli x7, x20, 0
    rem x4, x29, x22
    mulh x18, x5, x25
    srli x12, x12, 23
    blt x13, x24, _br_taken_19
    slt x15, x9, x7
    j _br_done_19
_br_taken_19:
    slt x15, x9, x23
_br_done_19:
    fadd.d f2, f1, f6
    fsub.s f5, f5, f15
    fdiv.s f19, f22, f9
    bltu x17, x24, _br_taken_20
    sll x22, x13, x13
    j _br_done_20
_br_taken_20:
    xor x22, x21, x26
_br_done_20:
    fnmsub.s f31, f29, f26, f26
    fmul.s f22, f27, f0
    fnmsub.s f2, f24, f3, f22
    and x26, x27, x24
    sltu x29, x11, x17
    andi x30, x15, 1140
    addi x10, x6, -621
    slti x9, x28, -1600
    ori x13, x19, 179
    srli x18, x20, 17
    slti x24, x5, 528
    sltiu x21, x14, -1381
    ori x5, x5, 82
    bne x19, x14, _br_taken_21
    sra x20, x6, x15
    j _br_done_21
_br_taken_21:
    sltu x20, x24, x13
_br_done_21:
    lhu x4, 892(x31)
    sh x9, 892(x31)
    lb x24, 152(x31)
    sb x14, 152(x31)
    andi x27, x29, -1644
    xori x13, x30, 364
    sltu x9, x9, x26
    sltiu x6, x19, 1698
    sll x7, x29, x25
    bne x4, x16, _br_taken_22
    sub x17, x24, x11
    j _br_done_22
_br_taken_22:
    or x17, x25, x1
_br_done_22:
    ori x19, x18, 856
    fmadd.s f31, f12, f6, f29
    andi x24, x6, -1007
    sltu x4, x4, x20
    mulhsu x27, x25, x10
    bne x19, x1, _br_taken_23
    srl x6, x28, x8
    j _br_done_23
_br_taken_23:
    sll x6, x5, x10
_br_done_23:
    xor x26, x23, x14
    slli x20, x22, 12
    slt x9, x26, x17
    srai x23, x15, 10
    ori x17, x27, -1983
    sltiu x25, x19, -1898
    bne x23, x26, _br_taken_24
    sltu x16, x10, x15
    j _br_done_24
_br_taken_24:
    xor x16, x26, x22
_br_done_24:
    sltiu x25, x18, 528
    sltiu x29, x23, -1185
    xori x21, x20, 1716
    sra x6, x11, x15
    sltu x9, x12, x12
    srl x1, x18, x8
    and x29, x27, x10
    fmul.s f2, f16, f24
    fdiv.s f26, f8, f17
    sll x15, x11, x17
    bne x9, x20, _br_taken_25
    slt x12, x24, x25
    j _br_done_25
_br_taken_25:
    sll x12, x7, x18
_br_done_25:
    fadd.s f25, f30, f7
    fdiv.s f30, f29, f25
    fdiv.d f10, f5, f17
    bge x8, x18, _br_taken_26
    sltu x7, x13, x19
    j _br_done_26
_br_taken_26:
    xor x7, x30, x30
_br_done_26:
    ori x27, x6, 718
    srl x27, x21, x5
    lw x6, 440(x31)
    sw x30, 440(x31)
    or x18, x10, x18
    xor x18, x17, x10
    slli x5, x30, 25
    sub x8, x5, x27
    sub x13, x16, x29
    fmin.d f13, f7, f1
    fmin.s f21, f1, f17
    xori x26, x20, -700
    slti x8, x9, 1746
    div x29, x25, x17
    mul x24, x28, x14
    mul x7, x14, x27
    mul x20, x12, x29
    srai x30, x30, 19
    andi x27, x13, -999
    fdiv.s f14, f23, f2
    fmax.s f11, f25, f23
    fadd.s f15, f14, f24
    lh x21, 160(x31)
    sh x24, 160(x31)
    bltu x24, x9, _br_taken_27
    sll x23, x26, x13
    j _br_done_27
_br_taken_27:
    or x23, x25, x11
_br_done_27:
    sll x13, x29, x11
    sll x16, x9, x13
    add x1, x28, x25
    addi x7, x18, -280
    bgeu x9, x13, _br_taken_28
    srl x4, x14, x17
    j _br_done_28
_br_taken_28:
    sll x4, x7, x30
_br_done_28:
    srai x16, x10, 26
    slli x8, x13, 30
    srl x22, x11, x15
    fdiv.d f29, f14, f6
    fdiv.s f11, f20, f24
    fdiv.d f8, f15, f8
    add x10, x16, x10
    xor x25, x18, x9
    slli x27, x13, 2
    fsub.d f17, f12, f17
    fadd.d f18, f27, f22
    srai x24, x19, 26
    sltu x13, x1, x26
    srl x29, x8, x27
    ori x8, x5, 1118
    srai x18, x22, 24
    ori x14, x19, -343
    sll x20, x18, x13
    srli x5, x15, 7
    lb x28, 424(x31)
    sb x11, 424(x31)
    lb x22, 608(x31)
    sb x5, 608(x31)
    fmax.s f20, f17, f5
    fmsub.s f25, f20, f12, f16
    lw x18, 148(x31)
    sw x10, 148(x31)
    slti x19, x21, 1776
    lw x11, 688(x31)
    sw x13, 688(x31)
    fmin.s f5, f30, f13
    fmin.d f14, f31, f10
    fmul.s f25, f24, f25
    slti x4, x25, 1577
    sll x17, x20, x14
    sll x26, x6, x7
    sll x13, x4, x27
    sra x12, x24, x21
    mulhsu x17, x1, x21
    bne x18, x22, _br_taken_29
    or x20, x6, x7
    j _br_done_29
_br_taken_29:
    slt x20, x18, x25
_br_done_29:
    bge x15, x5, _br_taken_30
    srl x13, x5, x8
    j _br_done_30
_br_taken_30:
    sltu x13, x8, x18
_br_done_30:
    fmul.d f5, f9, f21
    fmul.d f17, f19, f3
    fdiv.d f24, f5, f1
    fmadd.d f12, f7, f3, f5
    ori x4, x29, -957
    sra x18, x20, x4
    andi x4, x13, 1677
    ori x5, x13, -834
    fnmsub.d f13, f30, f13, f12
    div x19, x9, x22
    bge x10, x23, _br_taken_31
    sub x16, x4, x15
    j _br_done_31
_br_taken_31:
    or x16, x27, x11
_br_done_31:
    divu x20, x18, x21
    div x13, x16, x21
    xor x23, x1, x11
    slti x28, x20, -1131
    bge x13, x11, _br_taken_32
    srl x21, x16, x24
    j _br_done_32
_br_taken_32:
    sub x21, x12, x17
_br_done_32:
    bge x27, x15, _br_taken_33
    and x1, x25, x24
    j _br_done_33
_br_taken_33:
    and x1, x25, x8
_br_done_33:
    andi x30, x12, 460
    slt x27, x12, x26
    or x29, x15, x5
    bltu x4, x29, _br_taken_34
    sra x22, x28, x27
    j _br_done_34
_br_taken_34:
    and x22, x16, x4
_br_done_34:
    blt x6, x6, _br_taken_35
    and x8, x25, x24
    j _br_done_35
_br_taken_35:
    slt x8, x12, x25
_br_done_35:
    sub x22, x17, x14
    or x26, x13, x21
    div x27, x10, x30
    mulh x19, x10, x13
    xor x7, x7, x21
    srli x5, x8, 11
    bgeu x14, x14, _br_taken_36
    slt x6, x10, x20
    j _br_done_36
_br_taken_36:
    sub x6, x24, x7
_br_done_36:
    sltiu x17, x19, 1761
    or x11, x11, x19
    or x23, x5, x29
    addi x28, x31, 768
    amoxor.w x11, x23, (x28)

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x1c358e5ace931134
    .dword 0x8b0d861d61e543c4
    .dword 0x7f357dfb5ce7af18
    .dword 0x49a7e339cfadcf74
    .dword 0xe7ef1337c85b5954
    .dword 0x637c049908e70afa
    .dword 0x44056e91531bde37
    .dword 0xdd992c22bb9b798f
    .dword 0x608755d0e2811406
    .dword 0xc5d9f2aaa81420d8
    .dword 0xd8e3e977567406fe
    .dword 0xa028aa0f21831dc3
    .dword 0xa721a2cbdc32906b
    .dword 0x00f9632df90eb348
    .dword 0x4f5f55b66abaf745
    .dword 0xfbb0421e2a3b6298
    .dword 0x47975da9723633b8
    .dword 0xa73d09b4184a7acc
    .dword 0x9b63c28fa5e9eafb
    .dword 0x8aff5680d28be54b
    .dword 0xbbea0674d0a8aaa3
    .dword 0x0303c41190e859aa
    .dword 0x699e1a4eab49de65
    .dword 0xde2b0bc8b8a86cd4
    .dword 0x765920ee7b61b29f
    .dword 0xeec5ad079bab3b3c
    .dword 0xba53146cd0100ce8
    .dword 0x57b4a11b57bd577d
    .dword 0x0afc98dc79291bbf
    .dword 0xe587e8626dc547c6
    .dword 0x0cf1adb57315e0b4
    .dword 0x8175c9f4275c7f95

    .align 2
_torture_data:
    .word 0x92196624
    .word 0xb69fffb5
    .word 0x1860f6c6
    .word 0x5805f35c
    .word 0x7f18c6b0
    .word 0xd6f5eb3b
    .word 0xeead6424
    .word 0x29041273
    .word 0xff72835b
    .word 0x8b708c98
    .word 0x6624e746
    .word 0xdd84d931
    .word 0xa3ee50c7
    .word 0x0e95a9ca
    .word 0xfbbc2feb
    .word 0x956b6d3b
    .word 0xa08dc17e
    .word 0x385a3cad
    .word 0xf63acdfa
    .word 0x5a8e0409
    .word 0xc95b5a4b
    .word 0xb0bee137
    .word 0x3e45fb56
    .word 0x683a1a5e
    .word 0x70cd622d
    .word 0xf3ecae0a
    .word 0x9588ab33
    .word 0x589eb18d
    .word 0x98dbf122
    .word 0x52ba6517
    .word 0x2028d0c9
    .word 0xa2f4f723
    .word 0x826929d3
    .word 0x3f883fda
    .word 0xa3d817de
    .word 0x4e9485df
    .word 0x3653311c
    .word 0x50a5aa39
    .word 0xd7127f9a
    .word 0x6ef752fc
    .word 0x488060b9
    .word 0xa0860933
    .word 0xd32719e3
    .word 0x866b3fe7
    .word 0x2f79e8ab
    .word 0xac21c7bb
    .word 0xad91174e
    .word 0xf1aea921
    .word 0x02992946
    .word 0xc41b4116
    .word 0x687f2348
    .word 0xc5dea269
    .word 0x8fd9378f
    .word 0xcf2efbdc
    .word 0x875f01df
    .word 0x020e1656
    .word 0x6cc60c9b
    .word 0xbc7ec9a1
    .word 0x2b44f68c
    .word 0x69c5469f
    .word 0xf6569c07
    .word 0x97ae0fd6
    .word 0xc50bf8ac
    .word 0xabde58c2
    .word 0x7648bf2b
    .word 0x5fa439ff
    .word 0xb028764e
    .word 0xb0010668
    .word 0xcbaa0561
    .word 0x5ffa8849
    .word 0x5c4e69a0
    .word 0xca88541b
    .word 0xdece759a
    .word 0xc5f8a730
    .word 0xb1058400
    .word 0x63fd5fa6
    .word 0x6b5b2371
    .word 0xe1e15853
    .word 0x639efcde
    .word 0x8294aff2
    .word 0x912ae631
    .word 0x4cfc8c45
    .word 0xaa205c3d
    .word 0x74948913
    .word 0x5c7609e0
    .word 0x6e16321f
    .word 0x94967764
    .word 0xfc4215e8
    .word 0x5dbb15ee
    .word 0xfa9d27a4
    .word 0xd19277ef
    .word 0x835970be
    .word 0x486e9473
    .word 0xc8d91326
    .word 0x23ac8c65
    .word 0x680d4915
    .word 0xf94a8968
    .word 0xd28eaea9
    .word 0x896ab377
    .word 0x7c100817
    .word 0x6d01c7bb
    .word 0xfbf4f9fc
    .word 0x27693e9f
    .word 0xc3e95653
    .word 0xfbb0a2ee
    .word 0x729c02b9
    .word 0x6f76bcd1
    .word 0xd4495b18
    .word 0x77db16be
    .word 0xc9ec3d15
    .word 0x8fe2f829
    .word 0x117f336d
    .word 0x83065fac
    .word 0xb01676b5
    .word 0xbbd62590
    .word 0xba6d75f8
    .word 0x616ada83
    .word 0x066d1e8d
    .word 0x5efc0f29
    .word 0x08bc36c8
    .word 0xf38360d0
    .word 0x55343adc
    .word 0x4086533d
    .word 0xe927dd4e
    .word 0xe42ded73
    .word 0x7ecfdd2e
    .word 0xeb250326
    .word 0x6b12256d
    .word 0x1c320f1a
    .word 0xd114e8f6
    .word 0x409ad393
    .word 0xbbd99e5d
    .word 0x9bed6c4f
    .word 0x5e47f9bd
    .word 0x4a1c4e46
    .word 0x85d02ddc
    .word 0x192da707
    .word 0x679f93ca
    .word 0xf5bd1865
    .word 0xa4525626
    .word 0xedf0e1be
    .word 0x15c60084
    .word 0xb49b9051
    .word 0xfad328af
    .word 0xe4527fa7
    .word 0x174a039f
    .word 0xf3d0a45b
    .word 0xa597eadb
    .word 0xf0bbebc2
    .word 0x28906dd7
    .word 0x87ec433a
    .word 0xa6d65089
    .word 0x85d48cf5
    .word 0x58ac6326
    .word 0x04b09c01
    .word 0x79075c00
    .word 0x1594585f
    .word 0x13c525f1
    .word 0x5ee11d22
    .word 0x7ac4c7a3
    .word 0x043e4959
    .word 0xb854a166
    .word 0x8cfef904
    .word 0x6a912777
    .word 0xb34e8fbf
    .word 0x228f9ddb
    .word 0x2a983b67
    .word 0x3b758ac2
    .word 0x9caad85e
    .word 0xf1a8e8c4
    .word 0x98378355
    .word 0x74af0a47
    .word 0x9a067c3f
    .word 0xf239f050
    .word 0x7baf1831
    .word 0x26aac1a3
    .word 0x82e43a26
    .word 0xf3be5c8c
    .word 0x03662ea0
    .word 0x6a7b8d5e
    .word 0xed0a646d
    .word 0xc514e50e
    .word 0xdba92d7d
    .word 0x323aae1a
    .word 0x0803af57
    .word 0xa9475c11
    .word 0x21df4e52
    .word 0x9c9f4608
    .word 0x65cc9811
    .word 0xd684f1dd
    .word 0x372164f9
    .word 0x11b7a192
    .word 0x3488ecc8
    .word 0x2a7828c9
    .word 0x92efc534
    .word 0x0ef658fd
    .word 0xa750881c
    .word 0x94371da0
    .word 0x2b94b514
    .word 0xfbde27aa
    .word 0x4afb09ce
    .word 0x93600055
    .word 0x6dcac322
    .word 0x54355cc2
    .word 0x798d16f3
    .word 0x3f29851d
    .word 0xe0857433
    .word 0x0d84da01
    .word 0x1c3df659
    .word 0xf8e24b08
    .word 0x1b2273b5
    .word 0x12b7aa6c
    .word 0x932cdcf2
    .word 0x54c6fa75
    .word 0x571c94dc
    .word 0xc21981d1
    .word 0x80e3364a
    .word 0x5c021993
    .word 0x30315085
    .word 0xf64d621b
    .word 0xb2dbf4bc
    .word 0x156547f1
    .word 0x588a27f2
    .word 0x9dff8d13
    .word 0xeae6b3ed
    .word 0xbda99833
    .word 0xf6c323fa
    .word 0xa912ebcb
    .word 0x8cf9c4db
    .word 0x524e0d6f
    .word 0x85b35805
    .word 0xb228c918
    .word 0xa80b48cf
    .word 0xa1ab3ad3
    .word 0x1ba20b61
    .word 0x80e51c33
    .word 0x6169cec2
    .word 0xaff4f12d
    .word 0xcf4ce615
    .word 0xd29568d6
    .word 0x8510aa38
    .word 0x3c2508f9
    .word 0xb134e001
    .word 0xaa5a2d9c
    .word 0x10f5fab1
    .word 0x4e4c997e
    .word 0xb52e379d
    .word 0xc7d1dc14
    .word 0x830c41d4
    .word 0x127e3f22
    .word 0x77033cf6
    .word 0xc353f5ae
    .word 0xf15e4afe
    .word 0x149592ad
    .word 0xe2c09c50
    .word 0x242e0f75

#include "frost_footer.S"
