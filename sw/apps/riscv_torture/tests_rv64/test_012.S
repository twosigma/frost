// Generated RV64IMAFDC torture test for Frost (seed=20260814)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0x92e5a7c8a419e4d1
    li x4, 0x95a0433dccd7d999
    li x5, 0x845eb320b23cbb1c
    li x6, 0xfe9c8f20420e0a01
    li x7, 0x04153ed7e5a5a925
    li x8, 0xf2518d719cbf6229
    li x9, 0x5e56004c8210a77e
    li x10, 0x22677c8a9711927f
    li x11, 0x1719229ddd90797d
    li x12, 0x0bc797880e3a9f68
    li x13, 0x1aafd836188fb78a
    li x14, 0x500d92247040e9d9
    li x15, 0xe7cccd495205e578
    li x16, 0x9c45b5a89d037c61
    li x17, 0xd0b1ec7238f79244
    li x18, 0xdb617e74fb3b98d6
    li x19, 0x76b999e1e8f5990a
    li x20, 0x7e3507dd89110491
    li x21, 0x67f72b172dda948b
    li x22, 0xeb867a185c0df17c
    li x23, 0xd07acfa613251067
    li x24, 0x5a3cd3d53a0998ca
    li x25, 0x4b00c488cbf5e69f
    li x26, 0x96b138298df3bc53
    li x27, 0x35739e654b387408
    li x28, 0x0662fea62339a565
    li x29, 0x453d6c2718e7ece3
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
    li x1, 0x5d346bde7496a5e9

    sub x6, x21, x20
    bltu x7, x7, _br_taken_0
    slt x1, x25, x10
    j _br_done_0
_br_taken_0:
    and x1, x23, x11
_br_done_0:
    addi x27, x15, -589
    bgeu x25, x8, _br_taken_1
    sra x16, x11, x20
    j _br_done_1
_br_taken_1:
    srl x16, x27, x9
_br_done_1:
    addi x30, x31, 720
    amoor.d x19, x10, (x30)
    divu x4, x21, x27
    bltu x6, x21, _br_taken_2
    sra x6, x20, x7
    j _br_done_2
_br_taken_2:
    sltu x6, x26, x15
_br_done_2:
    addi x20, x17, -1998
    subw x27, x17, x29
    sltiu x14, x6, 492
    sraiw x19, x14, 13
    ori x13, x6, 748
    xor x13, x7, x18
    blt x22, x17, _br_taken_3
    sll x20, x23, x14
    j _br_done_3
_br_taken_3:
    sll x20, x8, x19
_br_done_3:
    srliw x5, x1, 30
    srli x7, x20, 24
    beq x10, x8, _br_taken_4
    sub x9, x17, x14
    j _br_done_4
_br_taken_4:
    slt x9, x22, x26
_br_done_4:
    fnmadd.s f19, f8, f10, f18
    fmin.s f28, f27, f19
    addi x11, x7, 953
    srlw x7, x20, x16
    sltiu x1, x18, 2014
    sll x7, x28, x4
    srl x13, x26, x20
    slt x16, x26, x27
    slliw x14, x19, 18
    xor x25, x6, x15
    addi x30, x31, 508
    amomaxu.w x16, x6, (x30)
    bgeu x26, x27, _br_taken_5
    add x23, x16, x18
    j _br_done_5
_br_taken_5:
    slt x23, x22, x10
_br_done_5:
    div x11, x21, x13
    ld x24, 296(x31)
    sd x22, 296(x31)
    srli x1, x13, 19
    lwu x6, 824(x31)
    sw x11, 824(x31)
    bge x19, x28, _br_taken_6
    add x21, x18, x17
    j _br_done_6
_br_taken_6:
    sra x21, x9, x8
_br_done_6:
    fmsub.s f16, f1, f25, f7
    fdiv.d f25, f11, f30
    addi x30, x31, 640
    amoand.d x23, x22, (x30)
    sraiw x6, x16, 26
    fmin.s f11, f26, f18
    bne x4, x13, _br_taken_7
    sra x15, x13, x5
    j _br_done_7
_br_taken_7:
    sub x15, x9, x12
_br_done_7:
    srlw x12, x25, x21
    sll x18, x19, x20
    subw x15, x14, x11
    addiw x19, x26, 377
    sltiu x24, x19, 1710
    xor x9, x25, x19
    sll x19, x25, x12
    xori x9, x4, 587
    andi x26, x23, -1512
    sraw x15, x7, x27
    bgeu x8, x26, _br_taken_8
    sltu x12, x27, x11
    j _br_done_8
_br_taken_8:
    xor x12, x28, x12
_br_done_8:
    lw x14, 120(x31)
    sw x23, 120(x31)
    addiw x22, x28, 968
    lw x19, 752(x31)
    sw x11, 752(x31)
    sub x11, x19, x18
    srliw x5, x8, 8
    xor x20, x28, x8
    fnmadd.s f20, f27, f1, f0
    fmax.s f4, f30, f13
    fmul.d f30, f14, f25
    fmin.s f16, f16, f11
    sra x20, x7, x8
    ori x27, x5, -1649
    slt x20, x25, x14
    srliw x18, x29, 24
    srai x9, x4, 53
    bge x11, x28, _br_taken_9
    xor x10, x16, x24
    j _br_done_9
_br_taken_9:
    or x10, x29, x15
_br_done_9:
    mulw x24, x1, x20
    addi x30, x31, 480
    amomax.w x1, x16, (x30)
    fsub.d f26, f1, f20
    fmax.s f30, f24, f8
    fadd.s f22, f30, f12
    sub x22, x20, x13
    sltu x4, x18, x7
    sltiu x22, x22, -895
    lh x23, 716(x31)
    sh x27, 716(x31)
    sllw x4, x12, x17
    sraw x6, x11, x26
    slli x28, x19, 54
    srliw x10, x20, 5
    sraw x21, x17, x7
    addi x1, x19, 1287
    or x24, x28, x18
    sllw x28, x19, x25
    and x23, x19, x22
    srai x11, x14, 55
    addi x30, x31, 520
    amomaxu.d x18, x5, (x30)
    bgeu x16, x18, _br_taken_10
    add x22, x29, x26
    j _br_done_10
_br_taken_10:
    xor x22, x9, x5
_br_done_10:
    sll x7, x27, x19
    addw x15, x28, x8
    beq x28, x11, _br_taken_11
    sll x10, x17, x4
    j _br_done_11
_br_taken_11:
    add x10, x4, x12
_br_done_11:
    bne x22, x5, _br_taken_12
    srl x10, x22, x14
    j _br_done_12
_br_taken_12:
    sll x10, x28, x27
_br_done_12:
    srli x1, x20, 5
    lwu x9, 980(x31)
    sw x22, 980(x31)
    slti x13, x17, -1114
    andi x14, x10, 811
    addi x5, x26, 653
    add x29, x28, x1
    srai x16, x22, 40
    xor x19, x28, x18
    slli x27, x28, 8
    fdiv.s f29, f3, f0
    sltu x27, x11, x26
    srai x6, x6, 50
    xori x24, x7, 834
    and x22, x24, x7
    subw x18, x11, x28
    ld x23, 88(x31)
    sd x17, 88(x31)
    beq x19, x25, _br_taken_13
    or x27, x14, x16
    j _br_done_13
_br_taken_13:
    and x27, x20, x24
_br_done_13:
    lwu x14, 756(x31)
    sw x28, 756(x31)
    blt x13, x10, _br_taken_14
    sltu x5, x22, x17
    j _br_done_14
_br_taken_14:
    slt x5, x23, x19
_br_done_14:
    sltiu x8, x27, 202
    bltu x21, x29, _br_taken_15
    srl x5, x21, x17
    j _br_done_15
_br_taken_15:
    srl x5, x24, x14
_br_done_15:
    fsub.s f18, f18, f20
    fmul.s f21, f28, f17
    fdiv.d f15, f4, f27
    addw x4, x7, x27
    srai x29, x15, 44
    fmin.d f5, f1, f14
    fdiv.s f9, f24, f24
    fadd.s f19, f16, f3
    or x22, x6, x14
    srli x16, x15, 44
    div x11, x11, x28
    fnmadd.d f8, f20, f28, f19
    fmsub.s f5, f6, f11, f3
    fdiv.s f4, f16, f26
    fmax.s f19, f23, f27
    fmadd.d f4, f6, f30, f17
    addw x13, x21, x16
    srl x27, x13, x27
    ori x11, x13, 552
    srai x1, x17, 36
    srl x22, x29, x24
    xor x11, x23, x17
    sltu x26, x28, x1
    fmin.d f22, f7, f29
    fmax.s f24, f2, f29
    addi x30, x31, 104
    amoor.w x14, x12, (x30)
    and x15, x19, x6
    or x5, x11, x26
    addi x30, x31, 576
    amomax.d x22, x26, (x30)
    addiw x4, x8, -1513
    addi x6, x28, 467
    bltu x27, x9, _br_taken_16
    sll x28, x5, x5
    j _br_done_16
_br_taken_16:
    add x28, x26, x25
_br_done_16:
    xor x19, x17, x12
    xori x5, x14, -217
    fadd.d f16, f12, f30
    fmul.s f23, f7, f30
    lwu x28, 252(x31)
    sw x4, 252(x31)
    srli x16, x24, 30
    slli x5, x12, 18
    xor x11, x1, x16
    ld x25, 256(x31)
    sd x24, 256(x31)
    fnmadd.d f27, f27, f13, f17
    fadd.d f8, f20, f24
    blt x12, x24, _br_taken_17
    sub x22, x18, x7
    j _br_done_17
_br_taken_17:
    sll x22, x23, x14
_br_done_17:
    srlw x17, x13, x20
    srai x23, x8, 5
    srliw x15, x7, 15
    bge x22, x14, _br_taken_18
    sltu x7, x24, x16
    j _br_done_18
_br_taken_18:
    sra x7, x7, x23
_br_done_18:
    srl x23, x23, x24
    sra x7, x20, x20
    slliw x16, x23, 15
    remuw x25, x11, x10
    lwu x18, 692(x31)
    sw x5, 692(x31)
    bgeu x17, x24, _br_taken_19
    or x11, x1, x28
    j _br_done_19
_br_taken_19:
    or x11, x14, x12
_br_done_19:
    bge x1, x4, _br_taken_20
    sll x12, x28, x19
    j _br_done_20
_br_taken_20:
    sltu x12, x13, x4
_br_done_20:
    blt x20, x29, _br_taken_21
    sltu x9, x4, x8
    j _br_done_21
_br_taken_21:
    or x9, x17, x6
_br_done_21:
    lwu x18, 840(x31)
    sw x24, 840(x31)
    slliw x16, x4, 20
    sraiw x23, x18, 7
    bgeu x23, x26, _br_taken_22
    sltu x18, x18, x12
    j _br_done_22
_br_taken_22:
    slt x18, x8, x1
_br_done_22:
    xor x29, x21, x21
    slli x10, x21, 32
    srliw x5, x19, 3
    sraiw x22, x11, 22
    lbu x17, 852(x31)
    sb x12, 852(x31)
    blt x14, x14, _br_taken_23
    sub x10, x18, x9
    j _br_done_23
_br_taken_23:
    sra x10, x8, x28
_br_done_23:
    bne x11, x8, _br_taken_24
    slt x22, x25, x15
    j _br_done_24
_br_taken_24:
    srl x22, x9, x20
_br_done_24:
    rem x22, x12, x28
    or x29, x18, x28
    sraw x17, x7, x15
    srai x22, x25, 60
    srai x7, x27, 27
    sra x28, x23, x24
    blt x6, x24, _br_taken_25
    sub x5, x11, x1
    j _br_done_25
_br_taken_25:
    or x5, x22, x4
_br_done_25:
    srliw x16, x28, 19
    sltu x10, x9, x11
    and x18, x15, x28
    xor x18, x21, x18
    sra x14, x1, x23
    and x22, x23, x24
    sll x14, x9, x23
    srliw x23, x12, 19
    srliw x14, x24, 11
    sll x15, x26, x5
    sra x4, x13, x20
    bgeu x9, x25, _br_taken_26
    and x24, x25, x14
    j _br_done_26
_br_taken_26:
    slt x24, x16, x12
_br_done_26:
    sraiw x16, x25, 0
    srliw x26, x19, 31
    lb x29, 900(x31)
    sb x27, 900(x31)
    sltu x25, x8, x28
    srai x13, x8, 12
    srliw x12, x8, 25
    bne x24, x26, _br_taken_27
    sll x18, x8, x7
    j _br_done_27
_br_taken_27:
    sub x18, x6, x20
_br_done_27:
    beq x7, x23, _br_taken_28
    sub x25, x19, x23
    j _br_done_28
_br_taken_28:
    xor x25, x12, x9
_br_done_28:
    fdiv.s f21, f9, f3
    addw x15, x14, x10
    sltu x27, x22, x16
    lb x25, 736(x31)
    sb x17, 736(x31)
    lbu x1, 416(x31)
    sb x23, 416(x31)
    bltu x25, x7, _br_taken_29
    or x15, x20, x28
    j _br_done_29
_br_taken_29:
    and x15, x11, x8
_br_done_29:
    sltiu x29, x10, -930
    beq x5, x20, _br_taken_30
    and x8, x4, x6
    j _br_done_30
_br_taken_30:
    or x8, x28, x27
_br_done_30:
    slti x1, x6, 124
    xori x20, x11, 585
    srliw x5, x20, 29
    sltu x19, x1, x26
    blt x5, x23, _br_taken_31
    xor x1, x28, x1
    j _br_done_31
_br_taken_31:
    add x1, x1, x22
_br_done_31:
    fmadd.s f11, f19, f31, f10
    sllw x18, x27, x22
    srl x20, x10, x18
    sra x7, x13, x13
    sltiu x6, x9, -1710
    sraw x11, x4, x6
    andi x20, x10, 876
    srlw x9, x26, x1
    mulhu x29, x26, x14
    bgeu x27, x17, _br_taken_32
    srl x15, x19, x6
    j _br_done_32
_br_taken_32:
    sub x15, x19, x22
_br_done_32:
    addi x30, x31, 608
    amomaxu.d x6, x26, (x30)
    sraw x5, x15, x21
    srli x1, x14, 49
    slli x16, x12, 32
    xor x5, x23, x18
    and x18, x20, x18
    subw x9, x13, x20
    slti x22, x5, -1091
    subw x8, x20, x14
    ori x11, x15, -87
    addi x30, x31, 304
    amomax.d x11, x19, (x30)
    srli x13, x4, 17
    addw x7, x26, x17
    addiw x9, x19, 1221
    addi x17, x14, 960
    sub x29, x27, x8
    addi x30, x31, 440
    amomax.w x1, x16, (x30)
    srliw x25, x29, 22
    slli x5, x9, 33
    xori x28, x28, -932
    subw x20, x25, x24
    bltu x7, x9, _br_taken_33
    add x27, x6, x20
    j _br_done_33
_br_taken_33:
    add x27, x4, x11
_br_done_33:
    sub x23, x21, x24
    addiw x1, x20, -1067
    slti x17, x10, -1048
    addw x15, x28, x26
    lw x12, 440(x31)
    sw x21, 440(x31)
    subw x17, x9, x21
    xori x15, x23, -1010
    xori x26, x25, 940
    sraw x29, x17, x7
    lwu x12, 156(x31)
    sw x4, 156(x31)
    fadd.d f19, f28, f12
    sraiw x14, x12, 4
    sltu x9, x21, x17
    sra x4, x12, x17
    lh x29, 324(x31)
    sh x22, 324(x31)
    xor x25, x6, x25
    and x21, x13, x18
    srl x14, x21, x26
    lb x25, 612(x31)
    sb x21, 612(x31)
    addi x5, x4, 1727
    sltu x26, x8, x15
    bltu x14, x12, _br_taken_34
    and x17, x7, x6
    j _br_done_34
_br_taken_34:
    or x17, x25, x14
_br_done_34:
    bgeu x21, x29, _br_taken_35
    xor x18, x27, x25
    j _br_done_35
_br_taken_35:
    sra x18, x18, x15
_br_done_35:
    srliw x7, x5, 12
    srliw x7, x1, 29
    xori x21, x14, -1097
    beq x14, x4, _br_taken_36
    add x9, x17, x28
    j _br_done_36
_br_taken_36:
    or x9, x15, x24
_br_done_36:
    srlw x9, x28, x5
    srliw x21, x28, 19
    xori x21, x4, 1030
    subw x29, x1, x11
    srl x4, x16, x10
    sll x25, x22, x28
    lhu x23, 608(x31)
    sh x8, 608(x31)
    beq x8, x23, _br_taken_37
    sltu x13, x24, x8
    j _br_done_37
_br_taken_37:
    and x13, x5, x15
_br_done_37:
    mulhu x15, x15, x12
    mul x24, x4, x14
    mulw x19, x25, x29
    fnmadd.s f8, f6, f17, f8
    fmul.d f22, f11, f23
    fmul.s f0, f8, f12
    srlw x25, x27, x24
    bne x14, x17, _br_taken_38
    or x7, x28, x9
    j _br_done_38
_br_taken_38:
    and x7, x14, x19
_br_done_38:
    addiw x11, x8, -765
    slti x23, x29, -168
    mulhu x6, x6, x12
    sraw x20, x17, x13
    sllw x26, x6, x11
    slt x4, x15, x10
    bne x17, x12, _br_taken_39
    and x9, x24, x24
    j _br_done_39
_br_taken_39:
    sll x9, x6, x21
_br_done_39:
    add x14, x6, x19
    sraw x10, x6, x6
    sltu x12, x19, x19
    fmul.d f31, f20, f2
    fmsub.d f26, f31, f11, f29
    beq x11, x23, _br_taken_40
    sll x19, x8, x26
    j _br_done_40
_br_taken_40:
    sra x19, x18, x21
_br_done_40:
    add x16, x29, x10
    srli x6, x17, 63
    sraiw x7, x24, 8
    subw x1, x28, x20
    bgeu x22, x18, _br_taken_41
    sll x21, x5, x23
    j _br_done_41
_br_taken_41:
    sra x21, x4, x27
_br_done_41:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0x2af1436478575841
    .dword 0x9e3cd07aafb14d8f
    .dword 0xd885efd04ad7d108
    .dword 0x2d3538297ab3b12e
    .dword 0xcf957a84a40b459e
    .dword 0xe0406925a97994fa
    .dword 0x7e0b95750a323340
    .dword 0xb69969b3e9a80add
    .dword 0x8eb081dd4736695a
    .dword 0x899118861989bc0e
    .dword 0x54031029afe7266e
    .dword 0x28d8008d131f0898
    .dword 0x621aa6e0a435d816
    .dword 0x61f6a193e43687c1
    .dword 0x2f783d234959a995
    .dword 0x61e284a484925e97
    .dword 0xd1076b32ea1faceb
    .dword 0xe4a7656e15535044
    .dword 0x048e4fe374b4dd62
    .dword 0x4533200d4f4d39ab
    .dword 0x2f10e336068db48c
    .dword 0xa648f29b8a12550c
    .dword 0x8bddf3a498d8aa45
    .dword 0x665f661963a8f181
    .dword 0x7785e50862bd124b
    .dword 0xbd19ba281608ec1a
    .dword 0x12273850f2c87654
    .dword 0xe17dc9b6dfbdff4b
    .dword 0x39d69c147741ee84
    .dword 0xe88fdd6e69b985e0
    .dword 0x1183e068374343ae
    .dword 0x31fb484ce6a26fc5

    .align 2
_torture_data:
    .word 0xb1d4570f
    .word 0x60fc4bdc
    .word 0x5264e06d
    .word 0xead4e832
    .word 0xbd76d4f4
    .word 0xc317dfb4
    .word 0x5d8124c7
    .word 0x2793a3a4
    .word 0xbc2beb95
    .word 0xb924e824
    .word 0x04bf0e8a
    .word 0x0e566526
    .word 0x1eaa0417
    .word 0xaf8b8ea7
    .word 0x91f8f291
    .word 0x9eba0412
    .word 0xa6e228a1
    .word 0x5452e975
    .word 0x4bd75433
    .word 0xefec69fa
    .word 0xc0b437fb
    .word 0xf3d072b2
    .word 0x5fe1184d
    .word 0x08da8db9
    .word 0xcd5e41fb
    .word 0x4cc0f9e6
    .word 0xbc8666cb
    .word 0xc71fe11e
    .word 0xea21f2af
    .word 0x6399729a
    .word 0x6f8baaab
    .word 0xd8e1998d
    .word 0xe6e98f27
    .word 0x88ac3583
    .word 0x3a01c47b
    .word 0xc1f30c62
    .word 0x4685c629
    .word 0xc8e35ab7
    .word 0xa2807372
    .word 0xb908a8c4
    .word 0x47b09f62
    .word 0xd36f5bc5
    .word 0xddb6c38d
    .word 0x89b7365b
    .word 0x1f29834f
    .word 0x468700f6
    .word 0x867bd01d
    .word 0x714b6b6b
    .word 0x36489982
    .word 0xa04892f4
    .word 0xe1ffdb86
    .word 0xe783ddea
    .word 0x97199037
    .word 0x57fb145d
    .word 0x843a4501
    .word 0xe8509a1a
    .word 0xeed5a3d7
    .word 0x18624e40
    .word 0xb682757a
    .word 0x0b3c5d30
    .word 0xaa821bdd
    .word 0x1adf1ee3
    .word 0x3217f036
    .word 0x5b57aa18
    .word 0xd0622777
    .word 0x752db944
    .word 0x449c464e
    .word 0xa5d57f42
    .word 0x776e10b6
    .word 0x92ee9e90
    .word 0x91fa7e84
    .word 0x9bab1763
    .word 0xab49ef66
    .word 0x4705ab11
    .word 0x8de0be82
    .word 0x81dac261
    .word 0xb0e26531
    .word 0x37415c8e
    .word 0x9602b36a
    .word 0x27e27a8f
    .word 0x8530bfa9
    .word 0xe0a3339b
    .word 0xd490e5d8
    .word 0xe06c420d
    .word 0x77bd92fc
    .word 0xa3fe2c3b
    .word 0x134feab0
    .word 0x1839294c
    .word 0x5045882b
    .word 0x2d067e3a
    .word 0x19ed0c56
    .word 0xaab61cf3
    .word 0xb3ac1377
    .word 0xd21068dd
    .word 0x9c3fa8a5
    .word 0x0943de8d
    .word 0xe87a825f
    .word 0x1cb18a9f
    .word 0xeabb4345
    .word 0x29d83136
    .word 0xf77e1dc2
    .word 0x3d1a9713
    .word 0x7e725fc5
    .word 0x7748198c
    .word 0x3180bb37
    .word 0x6fd1609b
    .word 0x49552ae9
    .word 0x01a09192
    .word 0x1ee89f9e
    .word 0xc59818d5
    .word 0xce6338da
    .word 0xa721d12f
    .word 0x9b3df470
    .word 0x21af94fb
    .word 0xdc8612b1
    .word 0x2a5d360a
    .word 0xae21a68d
    .word 0x6dc84240
    .word 0xe273c318
    .word 0x42ff84c2
    .word 0x48505c4c
    .word 0x3064efab
    .word 0x3892da95
    .word 0xdb93788a
    .word 0x5033110e
    .word 0x5a5b791f
    .word 0x0fffddb6
    .word 0xf561a3e1
    .word 0x68a3148c
    .word 0x368a7c52
    .word 0x08238105
    .word 0xb5522bf5
    .word 0x6e74c271
    .word 0x2adf5983
    .word 0x515048e0
    .word 0xa8a3ccf7
    .word 0xfbff64b3
    .word 0x3da95774
    .word 0x0b6b4339
    .word 0x9f72aa6f
    .word 0x8121220e
    .word 0x2d44af60
    .word 0xc8e3549d
    .word 0xf4357202
    .word 0x73e029c2
    .word 0x0dbbb61d
    .word 0x45abdcc1
    .word 0xfe50e699
    .word 0xcebc702f
    .word 0x7e20813b
    .word 0xe9df2566
    .word 0x292a0148
    .word 0xf1252df2
    .word 0x7ff70dc9
    .word 0x60ebdceb
    .word 0x15ae07f7
    .word 0x046591a1
    .word 0x8e3bb2e3
    .word 0x2e2d8a4d
    .word 0x1401ee59
    .word 0x8f1634ce
    .word 0xc4ccffb7
    .word 0x5f1c334e
    .word 0xb3055295
    .word 0x40c1b782
    .word 0x44947003
    .word 0x76468520
    .word 0x459ba615
    .word 0x8117f1a4
    .word 0x2e60c72b
    .word 0xc2f9d181
    .word 0x057c3da0
    .word 0x6ed13ffb
    .word 0x89d63f11
    .word 0x0f9cb483
    .word 0x9b2ce0e0
    .word 0x6fc1e02c
    .word 0xb76a6e26
    .word 0x5fe2c8de
    .word 0xe81b9992
    .word 0x284dc673
    .word 0xdf97d1f3
    .word 0x053f4a4f
    .word 0xa12ed000
    .word 0x011be7f8
    .word 0x3bd936ad
    .word 0x8a167655
    .word 0x95190ba0
    .word 0x8d36102f
    .word 0x3eaa26b1
    .word 0x7f10046e
    .word 0xe44883c8
    .word 0xe6ff83a8
    .word 0x8d69f40f
    .word 0x4a250b17
    .word 0xecaae3a1
    .word 0xfec2029f
    .word 0xd0d372be
    .word 0xdf8b3790
    .word 0xafd9a4ca
    .word 0xaa71eb8c
    .word 0x6b63f646
    .word 0xbe7c57cc
    .word 0x707997ea
    .word 0xf4eb9261
    .word 0xb83547a5
    .word 0xb61abb59
    .word 0x69c325d6
    .word 0x8bc2dc8a
    .word 0xa2d053f6
    .word 0x7859ec90
    .word 0x39ee154f
    .word 0x075ceeac
    .word 0x44ffec3d
    .word 0x5e52d376
    .word 0x42a069f1
    .word 0xd6ea1978
    .word 0x61030cff
    .word 0x3e25bcac
    .word 0x173ff72f
    .word 0xebf7ca7b
    .word 0x2c3eb2f0
    .word 0x141eee44
    .word 0x15eb2081
    .word 0xe2c4424a
    .word 0xa94e1f36
    .word 0x74f40299
    .word 0xba90114b
    .word 0x843b473b
    .word 0xb7287403
    .word 0x3beb43d5
    .word 0x649f9df1
    .word 0xc294beb3
    .word 0xd92ce213
    .word 0xfb4dd2bc
    .word 0xf4edaade
    .word 0x7bcf54af
    .word 0x91e83935
    .word 0xcf760937
    .word 0xded7f4d7
    .word 0xcc5cdbeb
    .word 0xad669139
    .word 0x528e0d70
    .word 0x02c932dd
    .word 0x7d9344ce
    .word 0xa8235e7d
    .word 0x53a0dd5d
    .word 0x1418ea51
    .word 0xc15eae38
    .word 0x948f2e68
    .word 0xdf00de22
    .word 0x379e428d
    .word 0xf35e6efe
    .word 0x4b12540a
    .word 0xebffb572
    .word 0x9ffc1b55

#include "frost_footer.S"
