// Generated RV64IMAFDC torture test for Frost (seed=20260821)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xe996431cfcb2185a
    li x4, 0xfe78ea20e41b66d4
    li x5, 0xeb067fc8473acd2f
    li x6, 0xa990119943a93ec0
    li x7, 0x455e5317b7d30fef
    li x8, 0x54a76d00b919d776
    li x9, 0xc4faa3601b063952
    li x10, 0x59e62b32fe4d718c
    li x11, 0xc563e1f2d5f9895a
    li x12, 0xea711cad977e6caa
    li x13, 0xc9082f1cd3531c8e
    li x14, 0x14738dc20f8c4445
    li x15, 0x1dd1f1dc8edbf6d2
    li x16, 0x84a5c03edfd03e69
    li x17, 0x7cf7154365249394
    li x18, 0xabb4a90795c76696
    li x19, 0x112b4e694740f443
    li x20, 0x3eda3b68586326ba
    li x21, 0x32e8905b056acb91
    li x22, 0x2f165debc5543a76
    li x23, 0x3ddf72574f5a01a6
    li x24, 0x52e46c336207ae7d
    li x25, 0x1a56cfa20b69f83a
    li x26, 0x291255b7799687a4
    li x27, 0xdf889851f7366a68
    li x28, 0x4a96149fa827a496
    li x29, 0x8d1f35308027cf9c
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
    li x1, 0x0ecd2e12a8b6a4f9

    bne x8, x1, _br_taken_0
    sltu x7, x22, x29
    j _br_done_0
_br_taken_0:
    and x7, x6, x8
_br_done_0:
    addiw x25, x19, 1453
    slti x19, x23, -437
    srliw x15, x25, 10
    div x22, x8, x14
    add x5, x12, x21
    bge x12, x27, _br_taken_1
    sll x14, x1, x17
    j _br_done_1
_br_taken_1:
    sll x14, x16, x29
_br_done_1:
    srli x14, x27, 33
    bne x13, x18, _br_taken_2
    slt x1, x11, x16
    j _br_done_2
_br_taken_2:
    sub x1, x13, x13
_br_done_2:
    sub x7, x4, x23
    srai x4, x6, 50
    sraw x4, x28, x22
    and x22, x20, x25
    addiw x24, x19, -933
    addi x29, x8, 1277
    fmadd.d f26, f24, f29, f31
    addi x30, x31, 688
    amomin.d x22, x26, (x30)
    slli x15, x16, 16
    sll x4, x8, x28
    lh x10, 168(x31)
    sh x1, 168(x31)
    fadd.s f27, f4, f9
    fadd.s f12, f9, f21
    blt x19, x19, _br_taken_3
    sra x17, x25, x22
    j _br_done_3
_br_taken_3:
    xor x17, x8, x7
_br_done_3:
    slti x20, x23, 284
    bge x8, x6, _br_taken_4
    sub x21, x21, x20
    j _br_done_4
_br_taken_4:
    sltu x21, x6, x21
_br_done_4:
    sraw x10, x20, x29
    subw x8, x18, x8
    srliw x8, x17, 13
    fmadd.d f17, f6, f16, f16
    fadd.s f10, f4, f3
    addiw x16, x9, -494
    srli x28, x5, 13
    sltu x18, x29, x9
    srli x11, x25, 49
    addi x30, x31, 212
    amoor.w x22, x28, (x30)
    srl x4, x19, x25
    bne x24, x17, _br_taken_5
    sra x26, x25, x6
    j _br_done_5
_br_taken_5:
    and x26, x17, x20
_br_done_5:
    sra x17, x4, x18
    bgeu x5, x19, _br_taken_6
    sub x16, x22, x17
    j _br_done_6
_br_taken_6:
    xor x16, x5, x23
_br_done_6:
    srliw x23, x9, 13
    sltiu x6, x11, 1013
    beq x16, x8, _br_taken_7
    sub x6, x18, x29
    j _br_done_7
_br_taken_7:
    add x6, x15, x28
_br_done_7:
    fmul.s f31, f1, f7
    bge x6, x22, _br_taken_8
    slt x22, x28, x28
    j _br_done_8
_br_taken_8:
    srl x22, x24, x9
_br_done_8:
    bgeu x4, x11, _br_taken_9
    sub x15, x27, x9
    j _br_done_9
_br_taken_9:
    srl x15, x26, x17
_br_done_9:
    srai x7, x20, 4
    slti x11, x27, -622
    srli x4, x16, 53
    and x4, x29, x12
    sltiu x1, x7, -1671
    subw x23, x5, x24
    sltiu x26, x17, -456
    andi x27, x6, -847
    bgeu x7, x15, _br_taken_10
    or x9, x27, x24
    j _br_done_10
_br_taken_10:
    sra x9, x1, x9
_br_done_10:
    or x26, x1, x15
    slti x1, x20, -638
    bltu x23, x6, _br_taken_11
    or x19, x27, x17
    j _br_done_11
_br_taken_11:
    or x19, x28, x21
_br_done_11:
    srliw x24, x14, 10
    sraw x4, x18, x4
    slti x19, x9, -76
    slt x13, x14, x28
    srliw x23, x20, 1
    ld x7, 168(x31)
    sd x9, 168(x31)
    blt x16, x20, _br_taken_12
    sltu x15, x21, x19
    j _br_done_12
_br_taken_12:
    sltu x15, x22, x10
_br_done_12:
    ori x26, x15, 1770
    addw x11, x22, x4
    beq x22, x4, _br_taken_13
    sltu x9, x13, x5
    j _br_done_13
_br_taken_13:
    add x9, x10, x1
_br_done_13:
    slt x6, x7, x20
    subw x24, x6, x27
    subw x17, x29, x11
    addi x30, x31, 160
    amominu.d x8, x27, (x30)
    sllw x25, x26, x5
    and x11, x27, x1
    blt x5, x19, _br_taken_14
    srl x7, x4, x1
    j _br_done_14
_br_taken_14:
    sltu x7, x21, x19
_br_done_14:
    fadd.d f13, f13, f11
    sra x14, x21, x10
    srai x8, x11, 7
    bne x10, x25, _br_taken_15
    or x15, x15, x7
    j _br_done_15
_br_taken_15:
    or x15, x13, x15
_br_done_15:
    fadd.d f13, f15, f13
    fadd.d f6, f1, f16
    blt x25, x4, _br_taken_16
    or x11, x19, x26
    j _br_done_16
_br_taken_16:
    sltu x11, x8, x11
_br_done_16:
    xori x7, x17, 738
    addw x24, x22, x11
    srliw x1, x11, 7
    divuw x10, x12, x28
    ori x23, x18, -1263
    srai x27, x24, 30
    sraw x24, x4, x10
    addw x27, x20, x21
    addiw x7, x18, -405
    sraiw x28, x25, 7
    remw x5, x7, x7
    slt x9, x10, x1
    or x29, x7, x25
    lb x19, 0(x31)
    sb x10, 0(x31)
    srai x29, x6, 16
    sltiu x4, x16, 1040
    sltiu x12, x7, -1841
    addi x30, x31, 640
    amoand.d x12, x9, (x30)
    sllw x12, x7, x8
    sltiu x25, x26, -1268
    srl x16, x18, x23
    lwu x4, 324(x31)
    sw x12, 324(x31)
    srlw x13, x25, x1
    slti x14, x12, 432
    xori x9, x14, 1524
    lw x10, 556(x31)
    sw x22, 556(x31)
    sraiw x23, x11, 29
    addiw x20, x27, -321
    beq x23, x22, _br_taken_17
    or x24, x13, x14
    j _br_done_17
_br_taken_17:
    sltu x24, x16, x11
_br_done_17:
    bltu x24, x25, _br_taken_18
    sltu x16, x4, x27
    j _br_done_18
_br_taken_18:
    slt x16, x12, x22
_br_done_18:
    or x10, x4, x8
    sra x17, x6, x16
    slt x8, x12, x12
    bgeu x1, x12, _br_taken_19
    sub x24, x10, x28
    j _br_done_19
_br_taken_19:
    sll x24, x9, x4
_br_done_19:
    fnmsub.d f5, f15, f9, f22
    fnmadd.d f18, f9, f15, f20
    andi x26, x19, 341
    addi x16, x19, 1516
    lw x4, 596(x31)
    sw x27, 596(x31)
    fdiv.s f12, f8, f9
    slli x17, x9, 3
    slli x9, x26, 8
    bgeu x21, x6, _br_taken_20
    and x24, x28, x24
    j _br_done_20
_br_taken_20:
    sub x24, x21, x24
_br_done_20:
    bne x28, x18, _br_taken_21
    slt x5, x21, x28
    j _br_done_21
_br_taken_21:
    sll x5, x12, x14
_br_done_21:
    or x23, x23, x6
    fmin.s f3, f14, f26
    lw x5, 680(x31)
    sw x15, 680(x31)
    addi x30, x31, 900
    amominu.w x6, x6, (x30)
    slliw x20, x4, 11
    sltiu x12, x15, -1118
    slti x14, x29, -1960
    remw x10, x22, x16
    and x13, x12, x29
    sllw x29, x29, x17
    slti x18, x20, -1563
    slli x22, x12, 17
    addi x30, x31, 972
    amomin.w x29, x20, (x30)
    lwu x7, 748(x31)
    sw x26, 748(x31)
    bltu x14, x20, _br_taken_22
    srl x24, x18, x22
    j _br_done_22
_br_taken_22:
    sltu x24, x24, x26
_br_done_22:
    sltiu x8, x24, 1549
    sltu x16, x4, x19
    sltu x25, x9, x19
    srai x25, x16, 6
    blt x5, x25, _br_taken_23
    and x6, x25, x28
    j _br_done_23
_br_taken_23:
    srl x6, x25, x29
_br_done_23:
    remu x24, x29, x5
    mulhsu x22, x9, x20
    addiw x21, x25, -1200
    sltiu x14, x11, 485
    srlw x22, x11, x27
    sra x18, x27, x6
    srai x29, x1, 42
    addi x6, x23, 251
    blt x25, x4, _br_taken_24
    slt x12, x10, x14
    j _br_done_24
_br_taken_24:
    sltu x12, x11, x9
_br_done_24:
    fmsub.d f9, f28, f10, f15
    fdiv.d f3, f2, f11
    bltu x13, x13, _br_taken_25
    xor x23, x26, x5
    j _br_done_25
_br_taken_25:
    sub x23, x26, x16
_br_done_25:
    sltu x19, x20, x10
    sraw x24, x16, x20
    sraw x22, x22, x23
    add x14, x27, x21
    lwu x11, 396(x31)
    sw x28, 396(x31)
    mul x16, x25, x19
    addw x23, x16, x6
    sllw x18, x28, x26
    sltiu x22, x27, -1548
    addi x30, x31, 140
    amomin.w x24, x24, (x30)
    fsub.s f26, f21, f26
    fadd.d f26, f21, f28
    fmul.d f31, f14, f8
    fdiv.s f23, f27, f3
    sllw x28, x6, x14
    sllw x24, x28, x1
    xor x22, x10, x11
    sllw x9, x4, x20
    srliw x29, x23, 14
    fmax.d f15, f13, f19
    fmin.d f6, f23, f25
    fnmsub.s f9, f16, f4, f18
    subw x22, x25, x25
    slli x26, x22, 46
    addi x9, x6, 1772
    sraiw x27, x24, 29
    slli x27, x14, 36
    bgeu x14, x5, _br_taken_26
    or x7, x28, x26
    j _br_done_26
_br_taken_26:
    add x7, x26, x15
_br_done_26:
    srai x19, x8, 31
    srlw x10, x19, x14
    bgeu x1, x8, _br_taken_27
    sub x4, x11, x14
    j _br_done_27
_br_taken_27:
    and x4, x6, x7
_br_done_27:
    sraw x20, x4, x6
    slt x20, x22, x12
    fmax.s f5, f28, f12
    fmul.d f16, f15, f0
    fdiv.s f0, f21, f24
    addi x30, x31, 628
    amomax.w x29, x22, (x30)
    remw x28, x23, x1
    mulhu x9, x13, x23
    srlw x14, x13, x12
    addi x30, x31, 392
    amoswap.d x24, x7, (x30)
    bltu x9, x1, _br_taken_28
    and x20, x17, x27
    j _br_done_28
_br_taken_28:
    sltu x20, x15, x12
_br_done_28:
    subw x17, x28, x11
    sraw x22, x21, x12
    addi x16, x27, -1317
    blt x1, x12, _br_taken_29
    or x12, x7, x14
    j _br_done_29
_br_taken_29:
    sltu x12, x7, x25
_br_done_29:
    beq x5, x25, _br_taken_30
    sltu x18, x29, x5
    j _br_done_30
_br_taken_30:
    slt x18, x13, x15
_br_done_30:
    or x13, x17, x7
    add x8, x9, x19
    srai x14, x29, 56
    addw x29, x29, x15
    addi x30, x31, 476
    amoswap.w x27, x11, (x30)
    slli x1, x1, 40
    xor x13, x20, x28
    slti x20, x11, 1146
    sraiw x10, x5, 9
    addi x14, x12, 239
    srli x29, x14, 59
    addw x28, x5, x4
    sltiu x9, x11, -1582
    fmax.d f26, f23, f19
    fmul.d f25, f17, f31
    fmin.d f12, f11, f31
    fmin.d f20, f21, f9
    or x6, x18, x25
    sltiu x14, x14, -1296
    srli x4, x6, 49
    sllw x12, x28, x1
    sraiw x10, x23, 12
    srliw x10, x5, 16
    addw x18, x1, x8
    sraiw x19, x22, 8
    srai x19, x27, 21
    fadd.d f16, f5, f29
    fdiv.s f11, f0, f6
    fmsub.s f4, f8, f19, f14
    remuw x7, x1, x6
    mulhsu x21, x17, x24
    srliw x13, x16, 12
    blt x15, x8, _br_taken_31
    sra x19, x6, x27
    j _br_done_31
_br_taken_31:
    add x19, x17, x17
_br_done_31:
    sltu x14, x23, x29
    addiw x29, x28, -72
    blt x5, x10, _br_taken_32
    and x5, x14, x4
    j _br_done_32
_br_taken_32:
    slt x5, x1, x7
_br_done_32:
    andi x14, x12, -1105
    slti x7, x23, 3
    sllw x18, x5, x12
    sltiu x18, x5, -587
    srliw x27, x13, 24
    xori x10, x27, -99
    slli x23, x9, 14
    slti x20, x7, -1272
    sra x28, x19, x25
    bgeu x9, x17, _br_taken_33
    and x24, x11, x12
    j _br_done_33
_br_taken_33:
    sltu x24, x12, x20
_br_done_33:
    fmadd.s f12, f30, f22, f7
    fnmadd.d f26, f30, f28, f9
    srl x1, x9, x18
    addiw x29, x1, -1681
    srli x12, x17, 4
    mulh x6, x14, x25
    lh x7, 800(x31)
    sh x15, 800(x31)
    addi x30, x31, 12
    amomaxu.w x22, x26, (x30)
    divu x18, x8, x5
    addi x9, x19, -898
    rem x4, x20, x17
    lwu x15, 124(x31)
    sw x20, 124(x31)
    sltu x13, x12, x12
    or x9, x20, x24
    xori x4, x8, -1462
    sraiw x29, x10, 16
    bne x13, x28, _br_taken_34
    slt x18, x23, x22
    j _br_done_34
_br_taken_34:
    sra x18, x5, x21
_br_done_34:
    bltu x26, x5, _br_taken_35
    and x1, x12, x14
    j _br_done_35
_br_taken_35:
    or x1, x21, x25
_br_done_35:
    lwu x13, 204(x31)
    sw x18, 204(x31)
    lb x29, 88(x31)
    sb x29, 88(x31)
    beq x1, x15, _br_taken_36
    add x26, x23, x5
    j _br_done_36
_br_taken_36:
    sra x26, x17, x4
_br_done_36:
    bne x21, x11, _br_taken_37
    sub x24, x25, x18
    j _br_done_37
_br_taken_37:
    sltu x24, x8, x18
_br_done_37:
    beq x14, x27, _br_taken_38
    sra x18, x4, x15
    j _br_done_38
_br_taken_38:
    slt x18, x26, x12
_br_done_38:
    add x6, x5, x15
    ori x17, x26, -779
    addi x22, x17, 557
    sra x23, x25, x19
    srlw x7, x24, x28
    ori x16, x1, -509
    slliw x24, x26, 0
    srl x24, x25, x18
    sraiw x16, x25, 8
    add x23, x4, x20
    srl x13, x24, x19
    beq x4, x29, _br_taken_39
    slt x23, x19, x26
    j _br_done_39
_br_taken_39:
    add x23, x20, x23
_br_done_39:
    bgeu x13, x9, _br_taken_40
    and x26, x13, x14
    j _br_done_40
_br_taken_40:
    srl x26, x18, x6
_br_done_40:
    sltiu x9, x5, -73
    ori x15, x9, -625
    and x8, x19, x19
    bge x5, x13, _br_taken_41
    and x16, x21, x26
    j _br_done_41
_br_taken_41:
    sltu x16, x18, x8
_br_done_41:
    slliw x23, x19, 15
    sraiw x25, x15, 11
    srl x28, x17, x4
    blt x22, x17, _br_taken_42
    sub x28, x11, x4
    j _br_done_42
_br_taken_42:
    or x28, x11, x1
_br_done_42:
    mulh x23, x13, x19
    mulhsu x4, x18, x7
    srliw x16, x27, 3
    sll x25, x18, x20
    addiw x10, x18, -484
    fmadd.d f21, f11, f27, f7
    fmsub.s f17, f25, f0, f1
    sraw x15, x22, x6
    sll x4, x17, x21
    sllw x18, x28, x15
    or x18, x20, x4
    xor x19, x5, x29
    srl x17, x29, x24

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x04833c72d4ca18dc
    .dword 0x2b775a7550cd608e
    .dword 0x30d53456ea43c9ae
    .dword 0xf26f4761d49ff5b1
    .dword 0xe8045f9ff5bb01c9
    .dword 0xf7f183d7cac6773f
    .dword 0xaee5443d29258536
    .dword 0xc6fda4dafa130517
    .dword 0xbf9afcc4b4dd1ca2
    .dword 0xe445d185c2edd1c1
    .dword 0x8eabe9ef78079799
    .dword 0x91b37bd4f31f138d
    .dword 0x8a3f6f3bfcdf5a92
    .dword 0xe9944df30a264b76
    .dword 0xc24c8a9a5c81ab46
    .dword 0xb452e55d6ffdebc3
    .dword 0x0f6776e2e56d670c
    .dword 0xf3859d626486b9ba
    .dword 0x82a277db5a140ffe
    .dword 0xd3ab6112cd53ca2b
    .dword 0x3acc0a28f3d5aa0c
    .dword 0x1847d6b97de531b1
    .dword 0xe0829c726ff6ee6e
    .dword 0x68654cd66604c93e
    .dword 0xcb175f38be8a71ae
    .dword 0x09799e0d09f73f22
    .dword 0xee36401cc8a69779
    .dword 0xadc9fd2288c8cf1e
    .dword 0xf8fbe97d05ea594b
    .dword 0xf64109a584d9f94d
    .dword 0xf4b66613986d623c
    .dword 0xf1f33bb5c7396a0d

    .align 2
_torture_data:
    .word 0xb55dca34
    .word 0xc09a8ba7
    .word 0x0775fe3f
    .word 0x2c7de094
    .word 0xaa0adced
    .word 0x6cec8691
    .word 0xda93d72f
    .word 0x4c4fddb7
    .word 0xadfce270
    .word 0x971dd2c9
    .word 0x2b3110ad
    .word 0x2ff998c5
    .word 0xb379a127
    .word 0x05359fd2
    .word 0xf8b249b9
    .word 0x05ab81bf
    .word 0xdef5b71a
    .word 0xf0cc6727
    .word 0x2bf3fc9e
    .word 0x0107e68e
    .word 0x44ff2057
    .word 0x4b954ba0
    .word 0x39e26feb
    .word 0x1bedc2c5
    .word 0xa907ce53
    .word 0x5f1e2974
    .word 0xa5f8dd60
    .word 0xed1745cd
    .word 0x150464d8
    .word 0x5bb553a0
    .word 0xc2c3b7b1
    .word 0xe407ca15
    .word 0x02c93686
    .word 0x28d1ce99
    .word 0x937cc364
    .word 0xad523580
    .word 0x93c02c77
    .word 0xf69da2a4
    .word 0x89224217
    .word 0xc4e4e575
    .word 0x33780acc
    .word 0xe70c4d03
    .word 0xed7a4705
    .word 0xcf82eb68
    .word 0xadd40370
    .word 0x8e1ed604
    .word 0x32bcdbe0
    .word 0xec78d462
    .word 0xe5dd2b9b
    .word 0xf70d62e8
    .word 0x1c8c10fd
    .word 0x74854afe
    .word 0x2d37efff
    .word 0x0dfe6631
    .word 0x148360ee
    .word 0x4dedc3e3
    .word 0xf15ee274
    .word 0xbd61e4b8
    .word 0x304f8caa
    .word 0x254d53dc
    .word 0x10dca101
    .word 0x8fe02f78
    .word 0x6e3ae2d2
    .word 0x2977c214
    .word 0xc9d91a18
    .word 0xfda72ce4
    .word 0x3f3629f4
    .word 0xb880e5ef
    .word 0xf5c713fb
    .word 0xf16ca87d
    .word 0x9af47bf6
    .word 0xffe5f2f6
    .word 0x4f5ad7c8
    .word 0x7c331ba1
    .word 0xb31f9cc2
    .word 0x7bdb6669
    .word 0x970775e8
    .word 0x6be6b9c7
    .word 0x95369224
    .word 0x338cefb5
    .word 0x5d49238b
    .word 0xe9592cb7
    .word 0xe583624e
    .word 0xb2477ee7
    .word 0x1f9c4f55
    .word 0x42f95164
    .word 0x531e283d
    .word 0xd6d831e5
    .word 0xe4732d6f
    .word 0x895cbefc
    .word 0x4c17a13f
    .word 0xd24833c6
    .word 0xdd006882
    .word 0x6a3a6244
    .word 0x979beab8
    .word 0x88cab849
    .word 0x86fe5bda
    .word 0xad70a547
    .word 0xd643d2fd
    .word 0x1b86b59f
    .word 0xdeb92a3d
    .word 0x804be8a6
    .word 0x446c297c
    .word 0xf330aab9
    .word 0xb6877440
    .word 0x285d91c9
    .word 0x3acc88b0
    .word 0x71c07c66
    .word 0x70dd0d3c
    .word 0x37e53333
    .word 0xd7f15cb3
    .word 0x715153a2
    .word 0xcbba5ee7
    .word 0xc9c1d0b8
    .word 0x67373c84
    .word 0x5a407c2b
    .word 0xb280c269
    .word 0xd1075f01
    .word 0x3dd65941
    .word 0xf493fbd3
    .word 0x2a39cb35
    .word 0x218938ed
    .word 0x9f6b673f
    .word 0x9556c532
    .word 0xb90ef653
    .word 0x2195c61d
    .word 0x8c436ec2
    .word 0x699e8660
    .word 0xfa5db191
    .word 0x21938006
    .word 0xf761bb09
    .word 0x3f155cf5
    .word 0x350c7780
    .word 0xf61b05a8
    .word 0x3d97d879
    .word 0xf07f2918
    .word 0x8183d66c
    .word 0x4a27f825
    .word 0xa3d43e2e
    .word 0x350feeaf
    .word 0x622fcbce
    .word 0x39e848c9
    .word 0x90c928dc
    .word 0x66934577
    .word 0x29a67fe2
    .word 0x05030f1c
    .word 0x57471f9b
    .word 0xad681406
    .word 0x3809f582
    .word 0x00f6927e
    .word 0x85799d61
    .word 0xfe1f7c4d
    .word 0x216c567f
    .word 0xd49e5e0e
    .word 0xe9e56ed1
    .word 0x8d1be6fe
    .word 0x469623ff
    .word 0x904194be
    .word 0x9c250605
    .word 0x4ae0ba0e
    .word 0x2725d59a
    .word 0x463f5d52
    .word 0xf58be01c
    .word 0x38437462
    .word 0x13212d96
    .word 0x7929d50b
    .word 0x128ab88f
    .word 0x40a45198
    .word 0xdc1a3f58
    .word 0x12358f5d
    .word 0xeb2f8219
    .word 0xfa601dc6
    .word 0x3b07ad70
    .word 0x1248d669
    .word 0x5c14ae36
    .word 0x50885707
    .word 0xe083e532
    .word 0x4b3abc5a
    .word 0x30127ece
    .word 0x3659e1d7
    .word 0x5085a134
    .word 0x80f57dbe
    .word 0xa06d36b9
    .word 0xe3e4c0db
    .word 0x67d2f599
    .word 0x1b009e60
    .word 0x85eea5be
    .word 0xdd49affa
    .word 0x3bbb407d
    .word 0xfc4c7305
    .word 0xfdfd82d3
    .word 0xafdde4d7
    .word 0x78beca78
    .word 0xd23bb896
    .word 0x30f06259
    .word 0xe4c7ad76
    .word 0xca1f1258
    .word 0x9f18b0c3
    .word 0x40863700
    .word 0x04a52e8f
    .word 0x895fc760
    .word 0xe93130f6
    .word 0xbe1d1dce
    .word 0x8efa4f66
    .word 0x6aebc4d9
    .word 0xd6dd7d41
    .word 0x524db451
    .word 0x67a167a2
    .word 0xb45ffefa
    .word 0x9f0cee22
    .word 0xf4d82af8
    .word 0x37eb9c5c
    .word 0xdde03cf8
    .word 0x21ba4a76
    .word 0x6a255486
    .word 0x060017bc
    .word 0x9d7d3af2
    .word 0x66daa15e
    .word 0xa485b656
    .word 0x2c95102c
    .word 0xd7d5d411
    .word 0x20241e87
    .word 0x929bc6de
    .word 0x1d8a1bea
    .word 0x8e658f51
    .word 0x7102199d
    .word 0xad8bb938
    .word 0x5251390d
    .word 0x0547ffb0
    .word 0x4104418f
    .word 0x63bfbf40
    .word 0xfe0af053
    .word 0x7edd04c5
    .word 0x7513b584
    .word 0xf2578e4b
    .word 0x59c09b2b
    .word 0x04b51506
    .word 0x7d9920a7
    .word 0xfeee1468
    .word 0x9c167f83
    .word 0x5e9afa13
    .word 0xbd77fcd8
    .word 0x836a1f28
    .word 0x20c9e4d8
    .word 0xd173413c
    .word 0xfb83138f
    .word 0x6f4829ee
    .word 0xfe6cd2b1
    .word 0xda89eed1
    .word 0x8e235cf4
    .word 0x8d7661e6
    .word 0xd6eec7d3
    .word 0xc7097b91
    .word 0x7229b760
    .word 0x6184e792
    .word 0x48ec5463

#include "frost_footer.S"
