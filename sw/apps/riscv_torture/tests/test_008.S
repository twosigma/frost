// Generated RV32IMAFDC torture test for Frost (seed=49)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x111f4efd
    li x4, 0x1c4a09ca
    li x5, 0xbc66323a
    li x6, 0x27837704
    li x7, 0xbbd6b49e
    li x8, 0x81187003
    li x9, 0x9a4130c7
    li x10, 0x92c780ae
    li x11, 0x666b98e8
    li x12, 0x23532e62
    li x13, 0x604585c6
    li x14, 0xc5bfe2c6
    li x15, 0x9ecb1d5f
    li x16, 0xa94834c3
    li x17, 0x5185875c
    li x18, 0x38e29ed0
    li x19, 0x9cae9beb
    li x20, 0x6109cbdf
    li x21, 0x8c49a2ec
    li x22, 0x26134dff
    li x23, 0xd41d9a67
    li x24, 0x101ba88a
    li x25, 0xa9f8c7cf
    li x26, 0x12f413c9
    li x27, 0x6d2a02b9
    li x28, 0xb7958a59
    li x29, 0x288d298c
    li x30, 0x70932e5d
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
    li x1, 0xf7731453

    xor x23, x5, x24
    srai x10, x16, 21
    lhu x24, 16(x31)
    sh x8, 16(x31)
    fnmadd.s f27, f5, f16, f23
    fmin.s f8, f29, f7
    fmin.s f8, f24, f1
    sltu x13, x16, x26
    bltu x30, x20, _br_taken_0
    srl x26, x1, x10
    j _br_done_0
_br_taken_0:
    add x26, x13, x5
_br_done_0:
    sltiu x1, x16, 70
    slti x10, x30, -1803
    fsub.s f17, f14, f10
    fmul.s f22, f13, f2
    fmadd.d f5, f5, f27, f12
    lhu x11, 568(x31)
    sh x9, 568(x31)
    blt x13, x26, _br_taken_1
    add x30, x12, x24
    j _br_done_1
_br_taken_1:
    srl x30, x29, x7
_br_done_1:
    bgeu x27, x13, _br_taken_2
    sub x10, x4, x6
    j _br_done_2
_br_taken_2:
    and x10, x6, x22
_br_done_2:
    addi x14, x31, 468
    amoor.w x4, x30, (x14)
    lbu x27, 168(x31)
    sb x7, 168(x31)
    fmadd.s f30, f5, f15, f15
    srl x12, x20, x4
    sra x17, x5, x28
    sll x1, x25, x23
    slt x1, x26, x12
    bne x15, x6, _br_taken_3
    sll x21, x8, x30
    j _br_done_3
_br_taken_3:
    and x21, x9, x1
_br_done_3:
    sra x10, x22, x23
    add x9, x22, x18
    lhu x18, 32(x31)
    sh x8, 32(x31)
    addi x9, x15, 1345
    add x22, x8, x7
    mul x8, x5, x12
    sltu x19, x23, x18
    slti x5, x11, -549
    add x18, x23, x16
    sra x10, x20, x27
    sra x5, x12, x25
    xori x21, x10, -1933
    bgeu x20, x1, _br_taken_4
    slt x26, x14, x9
    j _br_done_4
_br_taken_4:
    add x26, x9, x1
_br_done_4:
    sub x14, x25, x26
    xor x26, x17, x8
    sltiu x27, x10, 364
    srli x20, x1, 16
    addi x13, x31, 268
    amoswap.w x27, x12, (x13)
    addi x5, x31, 732
    amoor.w x14, x27, (x5)
    srli x25, x28, 24
    xor x10, x22, x14
    blt x27, x25, _br_taken_5
    xor x13, x20, x1
    j _br_done_5
_br_taken_5:
    slt x13, x22, x25
_br_done_5:
    lbu x28, 616(x31)
    sb x21, 616(x31)
    or x5, x29, x13
    sub x19, x7, x16
    or x25, x14, x5
    blt x18, x17, _br_taken_6
    slt x6, x25, x22
    j _br_done_6
_br_taken_6:
    slt x6, x13, x11
_br_done_6:
    ori x20, x27, 1807
    fsub.s f27, f26, f22
    sub x28, x27, x7
    fadd.s f2, f22, f11
    fsub.s f15, f23, f30
    addi x5, x20, -984
    bgeu x24, x19, _br_taken_7
    sll x4, x9, x22
    j _br_done_7
_br_taken_7:
    sra x4, x13, x7
_br_done_7:
    slli x19, x23, 8
    lb x11, 180(x31)
    sb x13, 180(x31)
    bgeu x28, x29, _br_taken_8
    xor x19, x21, x11
    j _br_done_8
_br_taken_8:
    sll x19, x10, x27
_br_done_8:
    fsub.d f13, f8, f4
    fmin.s f23, f18, f3
    fmin.d f24, f26, f11
    fmadd.s f19, f5, f25, f10
    fadd.d f9, f3, f13
    sub x12, x11, x20
    srl x24, x8, x4
    slli x4, x1, 3
    srl x16, x16, x11
    and x11, x9, x29
    srli x13, x23, 11
    bge x28, x25, _br_taken_9
    sll x16, x25, x20
    j _br_done_9
_br_taken_9:
    slt x16, x4, x23
_br_done_9:
    xori x10, x8, -1304
    slti x12, x21, 1576
    fmin.s f8, f19, f13
    fsub.d f4, f24, f13
    fmax.s f25, f29, f10
    bltu x20, x26, _br_taken_10
    slt x15, x20, x1
    j _br_done_10
_br_taken_10:
    sll x15, x12, x10
_br_done_10:
    sra x14, x20, x29
    xor x25, x13, x24
    fmin.s f18, f1, f31
    fmin.d f10, f6, f24
    fmadd.d f6, f1, f14, f17
    lbu x18, 408(x31)
    sb x9, 408(x31)
    or x26, x21, x5
    sub x28, x20, x7
    ori x30, x9, 312
    slt x25, x10, x19
    sra x9, x1, x18
    bgeu x5, x19, _br_taken_11
    srl x28, x17, x14
    j _br_done_11
_br_taken_11:
    sub x28, x17, x1
_br_done_11:
    lh x21, 156(x31)
    sh x20, 156(x31)
    xori x26, x15, -313
    rem x29, x15, x27
    sltu x10, x13, x30
    ori x23, x8, -2006
    sltiu x8, x29, -1251
    sltiu x27, x26, -577
    addi x11, x31, 480
    amoxor.w x20, x12, (x11)
    slti x17, x23, -1394
    sltu x8, x20, x29
    blt x17, x18, _br_taken_12
    slt x22, x20, x8
    j _br_done_12
_br_taken_12:
    sll x22, x10, x4
_br_done_12:
    sltu x1, x17, x23
    mulhsu x24, x18, x10
    bne x10, x19, _br_taken_13
    sltu x15, x18, x13
    j _br_done_13
_br_taken_13:
    srl x15, x6, x6
_br_done_13:
    srai x24, x13, 29
    srai x14, x9, 28
    xor x20, x7, x9
    and x19, x30, x10
    or x12, x17, x26
    slli x16, x25, 11
    sll x7, x1, x16
    or x13, x7, x16
    andi x23, x8, 1297
    slti x27, x15, -967
    lw x19, 952(x31)
    sw x11, 952(x31)
    fmsub.d f3, f16, f9, f26
    slti x13, x27, -507
    addi x21, x31, 272
    amoadd.w x25, x28, (x21)
    sll x7, x16, x28
    andi x10, x25, -1489
    xor x30, x15, x27
    sra x26, x18, x11
    sltiu x19, x13, 269
    fsub.s f21, f0, f4
    fmax.s f4, f14, f11
    fadd.s f15, f9, f21
    lhu x14, 52(x31)
    sh x9, 52(x31)
    xori x14, x26, -1368
    lh x16, 84(x31)
    sh x12, 84(x31)
    rem x7, x25, x28
    add x16, x1, x4
    ori x13, x25, 1428
    ori x14, x28, -1802
    sll x21, x1, x12
    slli x18, x4, 18
    sra x22, x17, x19
    sll x6, x15, x17
    sra x30, x27, x13
    add x1, x21, x25
    add x12, x17, x14
    srl x12, x9, x11
    and x24, x26, x16
    slti x24, x12, 263
    fmul.d f12, f12, f9
    fmsub.d f20, f7, f3, f9
    mul x29, x20, x27
    andi x25, x6, 1299
    ori x30, x29, -10
    fadd.s f22, f25, f12
    fnmadd.s f22, f25, f28, f6
    fmsub.s f25, f12, f18, f14
    andi x15, x12, -1331
    sub x9, x1, x9
    slli x12, x24, 30
    mulh x16, x6, x26
    divu x14, x20, x10
    mul x6, x19, x23
    fmul.s f9, f30, f24
    fadd.d f5, f1, f21
    fmul.s f9, f3, f11
    bgeu x4, x21, _br_taken_14
    and x7, x29, x11
    j _br_done_14
_br_taken_14:
    add x7, x4, x12
_br_done_14:
    sltiu x1, x15, -1248
    srli x20, x10, 29
    andi x9, x6, -1639
    andi x4, x7, 1468
    bgeu x5, x15, _br_taken_15
    srl x21, x23, x10
    j _br_done_15
_br_taken_15:
    sra x21, x26, x14
_br_done_15:
    xori x10, x7, 640
    sub x20, x29, x23
    add x4, x16, x1
    srai x12, x22, 29
    sra x5, x17, x18
    xori x6, x14, -328
    bne x23, x6, _br_taken_16
    sub x1, x25, x8
    j _br_done_16
_br_taken_16:
    slt x1, x13, x30
_br_done_16:
    beq x20, x7, _br_taken_17
    and x21, x8, x29
    j _br_done_17
_br_taken_17:
    xor x21, x18, x30
_br_done_17:
    bge x7, x25, _br_taken_18
    sra x5, x17, x30
    j _br_done_18
_br_taken_18:
    add x5, x27, x10
_br_done_18:
    add x12, x27, x24
    slli x21, x15, 4
    addi x8, x16, 2044
    add x24, x16, x8
    or x20, x28, x16
    xor x15, x27, x14
    addi x9, x31, 300
    amoor.w x6, x8, (x9)
    slli x6, x16, 11
    srli x7, x14, 29
    blt x16, x18, _br_taken_19
    xor x7, x8, x29
    j _br_done_19
_br_taken_19:
    add x7, x24, x19
_br_done_19:
    bne x10, x7, _br_taken_20
    sll x19, x5, x14
    j _br_done_20
_br_taken_20:
    sub x19, x30, x12
_br_done_20:
    sra x10, x9, x30
    fmul.s f8, f29, f7
    fadd.d f21, f17, f3
    sub x6, x8, x6
    addi x26, x23, -606
    slt x17, x27, x16
    lh x18, 480(x31)
    sh x29, 480(x31)
    div x14, x5, x15
    fmax.s f15, f8, f10
    lhu x19, 1016(x31)
    sh x12, 1016(x31)
    bge x16, x23, _br_taken_21
    sra x19, x13, x26
    j _br_done_21
_br_taken_21:
    sub x19, x5, x22
_br_done_21:
    srai x30, x12, 10
    sltiu x18, x1, 1790
    sltu x16, x10, x22
    srai x30, x30, 7
    slli x26, x24, 2
    xori x28, x6, -390
    slli x24, x29, 25
    slt x19, x26, x9
    blt x13, x19, _br_taken_22
    sltu x22, x13, x7
    j _br_done_22
_br_taken_22:
    slt x22, x26, x15
_br_done_22:
    blt x29, x20, _br_taken_23
    sub x20, x17, x19
    j _br_done_23
_br_taken_23:
    sra x20, x25, x1
_br_done_23:
    lhu x18, 1020(x31)
    sh x30, 1020(x31)
    remu x12, x17, x18
    srl x26, x14, x8
    add x18, x27, x24
    add x27, x29, x7
    add x28, x6, x15
    srai x5, x16, 29
    and x12, x13, x16
    slli x29, x20, 17
    sub x18, x18, x4
    bgeu x17, x10, _br_taken_24
    and x15, x19, x29
    j _br_done_24
_br_taken_24:
    or x15, x24, x22
_br_done_24:
    sub x24, x6, x14
    srai x1, x16, 26
    sll x19, x14, x13
    or x10, x20, x18
    xor x1, x14, x17
    add x24, x8, x21
    add x26, x18, x11
    slli x28, x23, 13
    sll x4, x26, x21
    or x23, x22, x30
    sltiu x24, x21, -23
    fmax.d f4, f27, f17
    fmax.s f3, f7, f21
    fmin.s f30, f18, f19
    sub x5, x15, x20
    beq x24, x6, _br_taken_25
    srl x22, x4, x9
    j _br_done_25
_br_taken_25:
    srl x22, x4, x15
_br_done_25:
    slt x12, x29, x20
    sll x21, x12, x18
    slti x23, x27, -1346
    sub x25, x9, x19
    andi x18, x26, -1782
    sltu x23, x30, x12
    addi x21, x1, -381
    ori x1, x26, -545
    srli x12, x1, 14
    andi x18, x21, 1288
    xor x15, x27, x17
    bne x5, x23, _br_taken_26
    slt x17, x24, x27
    j _br_done_26
_br_taken_26:
    sltu x17, x20, x15
_br_done_26:
    bltu x24, x5, _br_taken_27
    srl x7, x18, x23
    j _br_done_27
_br_taken_27:
    sltu x7, x7, x21
_br_done_27:
    bne x25, x8, _br_taken_28
    xor x22, x29, x12
    j _br_done_28
_br_taken_28:
    xor x22, x24, x19
_br_done_28:
    fdiv.d f5, f11, f2
    fmin.s f21, f6, f23
    slli x12, x24, 1
    addi x24, x9, 1135
    bne x9, x13, _br_taken_29
    sll x19, x29, x27
    j _br_done_29
_br_taken_29:
    srl x19, x10, x30
_br_done_29:
    lw x22, 304(x31)
    sw x28, 304(x31)
    andi x21, x17, 851
    srai x30, x26, 13
    sltiu x30, x25, -1905
    slt x27, x30, x13
    srai x1, x10, 6
    srli x24, x24, 31
    or x15, x8, x18
    lb x10, 192(x31)
    sb x7, 192(x31)
    sltiu x27, x6, 1484
    addi x5, x19, -1134
    sub x20, x20, x18
    and x18, x16, x12
    or x21, x23, x11
    srl x15, x26, x24
    sll x26, x17, x5
    xori x6, x9, -1741
    beq x9, x25, _br_taken_30
    slt x24, x10, x30
    j _br_done_30
_br_taken_30:
    sub x24, x1, x16
_br_done_30:
    xori x17, x1, 1821
    and x16, x25, x26
    addi x18, x31, 784
    amoor.w x6, x29, (x18)
    sub x5, x27, x22
    xori x20, x20, -1588
    slt x6, x29, x24
    sltiu x6, x4, -215
    srl x29, x16, x13
    or x14, x14, x18
    bgeu x9, x20, _br_taken_31
    and x15, x10, x12
    j _br_done_31
_br_taken_31:
    sra x15, x25, x12
_br_done_31:
    bge x6, x13, _br_taken_32
    or x9, x30, x1
    j _br_done_32
_br_taken_32:
    or x9, x18, x5
_br_done_32:
    addi x27, x31, 224
    amomin.w x13, x20, (x27)
    sltu x26, x21, x26
    sll x9, x8, x12
    blt x24, x27, _br_taken_33
    add x15, x8, x28
    j _br_done_33
_br_taken_33:
    srl x15, x9, x13
_br_done_33:
    slli x30, x17, 18
    sltu x8, x16, x20
    andi x15, x25, -1173
    bne x15, x20, _br_taken_34
    add x18, x15, x21
    j _br_done_34
_br_taken_34:
    sub x18, x19, x9
_br_done_34:
    fdiv.s f9, f4, f28
    fdiv.d f10, f9, f25
    fsub.s f16, f26, f9
    addi x23, x31, 508
    amoswap.w x16, x6, (x23)
    lw x28, 16(x31)
    sw x10, 16(x31)
    blt x25, x25, _br_taken_35
    srl x16, x11, x21
    j _br_done_35
_br_taken_35:
    and x16, x25, x21
_br_done_35:
    ori x1, x15, 736
    srai x20, x5, 31
    lhu x26, 68(x31)
    sh x6, 68(x31)
    slli x21, x24, 23
    srli x15, x10, 11
    sltu x25, x23, x9
    and x24, x7, x23
    beq x10, x27, _br_taken_36
    xor x24, x21, x17
    j _br_done_36
_br_taken_36:
    sra x24, x29, x14
_br_done_36:
    lb x20, 224(x31)
    sb x27, 224(x31)
    sub x23, x23, x11
    srli x22, x11, 20
    remu x16, x21, x7
    mulhsu x13, x14, x12
    fmsub.s f19, f18, f6, f16
    bne x18, x14, _br_taken_37
    and x28, x24, x16
    j _br_done_37
_br_taken_37:
    sub x28, x13, x27
_br_done_37:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x747f15b96653e0b0
    .dword 0xbda030ef5d1bd900
    .dword 0x92f54d35128cbd02
    .dword 0xc5b09bf9e94631db
    .dword 0xa4b4aa3aff8f1ef1
    .dword 0xe10d5a53ae1771e3
    .dword 0x3ba9fa581e7fc6e9
    .dword 0xd7b83494b396c0e8
    .dword 0x351833db2b2c2df7
    .dword 0x0ccfae144569189b
    .dword 0xc09e5b9e722c8913
    .dword 0xef38eeec56a866b8
    .dword 0x084ae9c2f0846779
    .dword 0x4c6b82719d0cd5f3
    .dword 0xf94f0d176e0522d8
    .dword 0x24e9cbfc2b922943
    .dword 0x9332a57ba8833ec0
    .dword 0x6890b778f7dcc529
    .dword 0xd4f80b4f9db9aaf0
    .dword 0x4c9480b166680666
    .dword 0x4d50f9bdd780c3f6
    .dword 0xfd3a893559e4a441
    .dword 0xd757e3597cdaea9b
    .dword 0x115f9da44bf84b0d
    .dword 0xf8e9768f7ea4901c
    .dword 0x8ae7415149545a0c
    .dword 0x45820ea6060d67fd
    .dword 0xf4510bd040e3feec
    .dword 0xcc951f4fe681d8d0
    .dword 0x8013f12ba5c22ad2
    .dword 0xbc6e988ab6be1b28
    .dword 0x4d4578c59ab327ba

    .align 2
_torture_data:
    .word 0x0faed443
    .word 0xd782c39e
    .word 0x163da292
    .word 0x28b39ec9
    .word 0x8b989ca5
    .word 0x5cdc3589
    .word 0x759b137b
    .word 0xd4c4250a
    .word 0xd0819f71
    .word 0xaaa4757b
    .word 0xe9d079a1
    .word 0x9e8abbc2
    .word 0x7976f6de
    .word 0x89cd5ec0
    .word 0x185c85aa
    .word 0x6168396b
    .word 0x4859d498
    .word 0xa466e075
    .word 0xebf411f3
    .word 0xff26838e
    .word 0xedb6914f
    .word 0x21a49a36
    .word 0x06efb303
    .word 0x268de81a
    .word 0xeaa8a7d9
    .word 0x96e74ae8
    .word 0xe8f2ad5a
    .word 0x95bdca69
    .word 0x6fbe91df
    .word 0x8d442176
    .word 0xb2f084a6
    .word 0x54767ed4
    .word 0x96d405de
    .word 0xb5d08d9e
    .word 0xac6cdf23
    .word 0x0d81ab31
    .word 0xc21a5141
    .word 0xb186d60e
    .word 0x2c5617ef
    .word 0x22216490
    .word 0x5c167866
    .word 0xa2b1da94
    .word 0x55e57607
    .word 0xadccb44b
    .word 0x2eabe057
    .word 0x218956ed
    .word 0xcb91d929
    .word 0x5e640596
    .word 0xe6b4a0be
    .word 0x1bb5ea87
    .word 0xc474a71e
    .word 0xddbbb539
    .word 0x783ee91e
    .word 0xfe6a3ddc
    .word 0x1c1ad028
    .word 0xec5a4e41
    .word 0x21920afd
    .word 0x4edd7035
    .word 0x1e44d0b9
    .word 0x10657aae
    .word 0x245bcc22
    .word 0xf3ebc01d
    .word 0x81cac697
    .word 0x7fb9b0bb
    .word 0x65a4dead
    .word 0x54762d7f
    .word 0x6432e6bc
    .word 0xc10c5713
    .word 0xc5826827
    .word 0x977e36ae
    .word 0xe5399dd0
    .word 0xaaf967b6
    .word 0xaf6ff4a4
    .word 0x31c66625
    .word 0x0051c21f
    .word 0x5de1d461
    .word 0x95a23cc7
    .word 0x1e249679
    .word 0x4d18c48b
    .word 0x5cedc75b
    .word 0x42c01cf2
    .word 0x766be05c
    .word 0x046cb67b
    .word 0x2c9355a5
    .word 0xf56acf13
    .word 0x02a62124
    .word 0xb0f4e9a3
    .word 0xe2ae5ada
    .word 0x556165d8
    .word 0xc856f1e2
    .word 0xddc2c425
    .word 0x229e30c9
    .word 0xd9eb9ff3
    .word 0x108a259d
    .word 0x985e1c4a
    .word 0xc9137e8a
    .word 0x7dce4878
    .word 0x346bcba6
    .word 0x56bf211c
    .word 0xdf9b4fdd
    .word 0x345689ee
    .word 0x99e91013
    .word 0x6f8ee7c9
    .word 0xea8e8d56
    .word 0x3bb72b49
    .word 0xedb3c700
    .word 0x4b220a5a
    .word 0x7df4c3f2
    .word 0x5cc2c9df
    .word 0x31d1fe0c
    .word 0x851523ed
    .word 0x15e4cf0c
    .word 0x50bf291b
    .word 0x24f89fa7
    .word 0x6505307c
    .word 0xdc932e59
    .word 0xbc65ba53
    .word 0xad19aff1
    .word 0x58d4e3e9
    .word 0xe2d5b19e
    .word 0x576c1522
    .word 0x8857e7c2
    .word 0x3324848a
    .word 0xec6aeff8
    .word 0x6e2667e3
    .word 0x7f4c0134
    .word 0xfc654f01
    .word 0x2cc34597
    .word 0x98f8009c
    .word 0x3e5f38d6
    .word 0x418ef96e
    .word 0xb3f0ec70
    .word 0x7df2bade
    .word 0xc2287ee1
    .word 0xe2f992de
    .word 0x89bca180
    .word 0x45f87755
    .word 0x099b643b
    .word 0x9e8e2093
    .word 0xbf8d612a
    .word 0x156ce530
    .word 0x2d5e90e5
    .word 0x1b588841
    .word 0x04f9430f
    .word 0x17477383
    .word 0xa69f6fb0
    .word 0x65567f47
    .word 0x72f72964
    .word 0xf461e108
    .word 0x7a13f356
    .word 0x8f81e7b9
    .word 0xb1c40f8d
    .word 0xcc4667d3
    .word 0x206e8101
    .word 0xfd099893
    .word 0x4b49a0fd
    .word 0x698e6cb1
    .word 0x5da5948f
    .word 0x91df2701
    .word 0x2c35770a
    .word 0xcde41024
    .word 0x02ce9d1d
    .word 0x2283d34b
    .word 0x2c178fc4
    .word 0xc0f55643
    .word 0x268527e2
    .word 0xc9d51f4f
    .word 0xd6f074d3
    .word 0x9a650a8f
    .word 0xfd02edfe
    .word 0x52082063
    .word 0x0ed03a10
    .word 0x999e578c
    .word 0x0249f232
    .word 0xdbc1dc1b
    .word 0xe81fdaff
    .word 0xbfd8251c
    .word 0x989a63ec
    .word 0x43d032da
    .word 0x10fe5060
    .word 0xa00d39d9
    .word 0xccd35694
    .word 0x97c608f5
    .word 0xfb89f0dd
    .word 0x4cf08b1d
    .word 0x1c4b960c
    .word 0x6f2cebce
    .word 0xa2e5717b
    .word 0xbf819963
    .word 0x8956a853
    .word 0x170e4f5c
    .word 0x39728a50
    .word 0xdfed0d6c
    .word 0xe8e74b1e
    .word 0x10cfea24
    .word 0x81a9d34e
    .word 0xc48c4d88
    .word 0xbf501bad
    .word 0x3ca1743b
    .word 0xd9696b4a
    .word 0x72a5a698
    .word 0xbcc0618b
    .word 0xac4c1121
    .word 0x0601806d
    .word 0x4851671e
    .word 0xcbcd354e
    .word 0xe28eda79
    .word 0x8bc44841
    .word 0xd0488974
    .word 0x09bbfffd
    .word 0x530859a1
    .word 0x97e17e2c
    .word 0x6e8046a7
    .word 0x3a6a45e1
    .word 0x0612c8b5
    .word 0x1ecebdf1
    .word 0xe1953a3f
    .word 0xe95f0ef8
    .word 0xc18f43bd
    .word 0x9639c813
    .word 0xb1c8ae4d
    .word 0x46a8c225
    .word 0x0d3bb295
    .word 0x6fbe7e96
    .word 0xea540acc
    .word 0x793c2a69
    .word 0xcb829828
    .word 0xb406d2a2
    .word 0x5a7ed37d
    .word 0x838b2ace
    .word 0x124b38fa
    .word 0xfe575e17
    .word 0xeb503f4b
    .word 0x47fff664
    .word 0xcbfaaa9a
    .word 0x27f40a74
    .word 0x1f7097df
    .word 0x428c6a5f
    .word 0x6a55219f
    .word 0xbf43f40a
    .word 0x8c267b63
    .word 0xb10651cd
    .word 0x463c6938
    .word 0xe3e20e12
    .word 0x7c518940
    .word 0x0df39c8e
    .word 0xd37968c4
    .word 0x30b7d430
    .word 0x9eaf6b7f
    .word 0x9b32105c
    .word 0xe7ed8172
    .word 0xeb3cdb4b
    .word 0x3835bc5f
    .word 0xfc1a5ab1
    .word 0xade91654
    .word 0xe061d059

#include "frost_footer.S"
