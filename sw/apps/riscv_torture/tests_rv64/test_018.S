// Generated RV64IMAFDC torture test for Frost (seed=20260820)
// nseqs=200 memsize=1024

#include "frost_header.S"

    .globl _torture_test_begin
_torture_test_begin:

    // Initialize integer registers
    li x1, 0xefc12798ea05112e
    li x4, 0xaf88dcae93c9da93
    li x5, 0xb4191885f8363ccd
    li x6, 0xc0fed8d7c099a3f6
    li x7, 0xf4ce248aa92afbd8
    li x8, 0x7ac3bf2755597217
    li x9, 0x8d98502085c1bb19
    li x10, 0x6e7ebe808bad1f35
    li x11, 0x86120359a481b293
    li x12, 0x497fb9e64f7c463a
    li x13, 0x0c4a9a23d6ec0366
    li x14, 0x6fd5c517456ce091
    li x15, 0x2f8e4f3035d869b1
    li x16, 0xea53d74726fdd168
    li x17, 0xc654c06e4a45f73f
    li x18, 0x1e143db568a81244
    li x19, 0x02f5658751f65dc2
    li x20, 0xc86483160c013ee6
    li x21, 0xc02ab5e6acd0bb60
    li x22, 0xb8b5ce807e8f811c
    li x23, 0xc96232df058c0eed
    li x24, 0xb25c78308c61ac18
    li x25, 0x7928690569802bef
    li x26, 0xe610f19ada45c102
    li x27, 0xb11f16cdb8e56016
    li x28, 0xacd89674c40abd63
    li x29, 0xd9e38d1cb1d485cc
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
    li x1, 0xca6b8ca0beb244f5

    blt x8, x24, _br_taken_0
    sltu x17, x9, x8
    j _br_done_0
_br_taken_0:
    or x17, x8, x5
_br_done_0:
    bgeu x26, x22, _br_taken_1
    add x16, x7, x8
    j _br_done_1
_br_taken_1:
    sra x16, x5, x28
_br_done_1:
    fdiv.d f3, f24, f28
    fsub.s f2, f27, f12
    ori x10, x1, -324
    sraiw x10, x16, 20
    ori x4, x9, -1275
    andi x4, x24, 326
    srl x5, x21, x21
    srliw x10, x9, 19
    slti x24, x20, 1081
    sraiw x11, x7, 1
    and x8, x28, x17
    sllw x19, x5, x13
    srlw x1, x19, x15
    xor x13, x25, x9
    sra x15, x19, x12
    xori x16, x17, -683
    bne x28, x26, _br_taken_2
    sub x6, x25, x16
    j _br_done_2
_br_taken_2:
    xor x6, x25, x22
_br_done_2:
    bne x27, x17, _br_taken_3
    sll x25, x19, x21
    j _br_done_3
_br_taken_3:
    srl x25, x12, x26
_br_done_3:
    slliw x21, x6, 7
    addiw x26, x4, -727
    addw x13, x11, x21
    and x7, x29, x13
    slti x9, x28, -1688
    addiw x24, x29, 1160
    slliw x7, x9, 27
    sraiw x4, x27, 25
    slli x20, x23, 19
    blt x10, x13, _br_taken_4
    xor x29, x28, x1
    j _br_done_4
_br_taken_4:
    slt x29, x18, x12
_br_done_4:
    bge x7, x28, _br_taken_5
    slt x7, x24, x6
    j _br_done_5
_br_taken_5:
    xor x7, x27, x15
_br_done_5:
    addiw x6, x12, 1933
    srli x4, x8, 51
    add x25, x6, x9
    subw x26, x19, x19
    fmax.d f26, f10, f12
    fmadd.s f17, f1, f8, f0
    fnmsub.d f23, f20, f24, f3
    slt x11, x24, x27
    xori x24, x17, -433
    sub x18, x27, x20
    fdiv.d f11, f3, f0
    addiw x14, x1, -61
    slliw x10, x28, 3
    slliw x19, x12, 4
    sltiu x28, x13, 1887
    sub x21, x10, x27
    fmul.s f30, f10, f8
    ori x7, x18, 1934
    sra x18, x24, x23
    and x9, x20, x14
    fnmsub.s f30, f13, f4, f0
    fmin.s f21, f12, f21
    fmul.d f20, f17, f16
    srl x17, x14, x16
    addiw x8, x19, -1455
    addiw x7, x4, 1911
    bge x17, x17, _br_taken_6
    srl x27, x9, x23
    j _br_done_6
_br_taken_6:
    sra x27, x12, x11
_br_done_6:
    bge x5, x18, _br_taken_7
    xor x10, x6, x4
    j _br_done_7
_br_taken_7:
    sub x10, x6, x25
_br_done_7:
    fadd.d f2, f17, f28
    srli x17, x20, 52
    srai x5, x29, 27
    srlw x24, x22, x14
    slliw x6, x25, 24
    slliw x10, x16, 7
    xor x16, x22, x19
    sltu x20, x24, x6
    sllw x17, x29, x14
    xor x27, x26, x11
    sraw x25, x23, x14
    srl x15, x11, x21
    slli x27, x17, 1
    sltu x17, x28, x8
    addiw x6, x25, 437
    addiw x16, x23, 545
    add x21, x5, x27
    andi x22, x7, 60
    lh x8, 440(x31)
    sh x21, 440(x31)
    slt x24, x11, x20
    srai x23, x17, 21
    ori x9, x15, 1263
    addw x23, x23, x6
    addi x30, x31, 752
    amomax.w x4, x10, (x30)
    srai x23, x5, 58
    bltu x28, x17, _br_taken_8
    srl x25, x24, x5
    j _br_done_8
_br_taken_8:
    slt x25, x7, x16
_br_done_8:
    and x26, x16, x8
    andi x24, x17, -897
    srli x24, x6, 32
    slti x1, x16, -241
    andi x28, x21, -2022
    sraiw x14, x15, 4
    srli x1, x1, 15
    sltu x15, x14, x10
    slli x11, x26, 14
    srliw x7, x14, 22
    slti x14, x7, -1245
    addw x12, x12, x10
    addi x18, x1, -193
    bgeu x23, x22, _br_taken_9
    sll x21, x29, x11
    j _br_done_9
_br_taken_9:
    add x21, x21, x5
_br_done_9:
    div x8, x9, x5
    div x22, x4, x6
    bne x13, x7, _br_taken_10
    sra x15, x20, x4
    j _br_done_10
_br_taken_10:
    xor x15, x4, x26
_br_done_10:
    lw x5, 892(x31)
    sw x17, 892(x31)
    addi x30, x31, 988
    amoswap.w x1, x21, (x30)
    addi x30, x31, 8
    amomaxu.w x28, x9, (x30)
    lh x22, 656(x31)
    sh x6, 656(x31)
    beq x16, x4, _br_taken_11
    add x5, x9, x17
    j _br_done_11
_br_taken_11:
    sra x5, x15, x14
_br_done_11:
    addi x5, x8, 1531
    addiw x13, x14, -1740
    and x14, x23, x16
    subw x9, x16, x20
    sraw x4, x5, x18
    slti x23, x4, -916
    and x10, x10, x13
    ld x27, 976(x31)
    sd x12, 976(x31)
    bltu x11, x27, _br_taken_12
    and x17, x13, x21
    j _br_done_12
_br_taken_12:
    srl x17, x10, x1
_br_done_12:
    bltu x27, x18, _br_taken_13
    sra x29, x26, x14
    j _br_done_13
_br_taken_13:
    sltu x29, x25, x1
_br_done_13:
    lhu x14, 728(x31)
    sh x17, 728(x31)
    xor x21, x5, x16
    addiw x26, x17, -770
    srai x21, x10, 14
    sraw x12, x20, x27
    bne x16, x13, _br_taken_14
    and x8, x24, x14
    j _br_done_14
_br_taken_14:
    srl x8, x13, x6
_br_done_14:
    bgeu x23, x5, _br_taken_15
    sll x13, x19, x6
    j _br_done_15
_br_taken_15:
    xor x13, x18, x16
_br_done_15:
    add x8, x21, x10
    xor x20, x13, x15
    bltu x20, x8, _br_taken_16
    and x4, x9, x15
    j _br_done_16
_br_taken_16:
    sub x4, x20, x6
_br_done_16:
    sraw x6, x5, x10
    sltu x4, x7, x25
    sraw x7, x25, x25
    slliw x13, x8, 1
    fmin.s f29, f12, f16
    fmul.s f9, f12, f22
    fadd.d f22, f28, f23
    addi x30, x31, 832
    amoswap.w x24, x7, (x30)
    fadd.s f26, f9, f14
    fmin.s f17, f2, f8
    fadd.s f17, f13, f16
    srl x22, x15, x21
    divw x25, x29, x27
    srai x22, x21, 57
    srai x13, x21, 3
    fsub.d f7, f17, f19
    fnmadd.d f17, f0, f1, f4
    fmul.s f24, f10, f31
    lbu x15, 544(x31)
    sb x26, 544(x31)
    lhu x5, 768(x31)
    sh x7, 768(x31)
    sub x8, x6, x29
    slti x9, x13, -1090
    sltu x16, x21, x16
    slt x8, x29, x18
    slt x18, x25, x13
    addw x21, x4, x22
    andi x28, x4, 1506
    fadd.d f1, f5, f22
    fmul.s f17, f20, f3
    fdiv.d f19, f12, f24
    sltiu x26, x19, -899
    srliw x8, x23, 5
    and x7, x1, x18
    bltu x8, x11, _br_taken_17
    xor x25, x5, x9
    j _br_done_17
_br_taken_17:
    and x25, x17, x12
_br_done_17:
    bltu x6, x27, _br_taken_18
    sub x4, x23, x9
    j _br_done_18
_br_taken_18:
    or x4, x4, x5
_br_done_18:
    sraw x7, x16, x14
    addiw x7, x8, 1013
    divu x20, x9, x20
    fdiv.s f23, f2, f10
    sltu x26, x15, x1
    srliw x13, x21, 29
    sraw x18, x29, x18
    xor x9, x28, x10
    sraiw x28, x14, 30
    fmin.s f18, f17, f26
    fsub.d f29, f25, f5
    fnmadd.s f19, f6, f7, f6
    bltu x11, x8, _br_taken_19
    add x17, x16, x13
    j _br_done_19
_br_taken_19:
    and x17, x21, x14
_br_done_19:
    sllw x6, x21, x16
    blt x20, x24, _br_taken_20
    sltu x24, x13, x22
    j _br_done_20
_br_taken_20:
    sra x24, x29, x13
_br_done_20:
    addi x30, x31, 284
    amoand.w x27, x19, (x30)
    xor x23, x28, x10
    slt x29, x16, x29
    add x4, x18, x15
    andi x5, x9, 228
    or x20, x18, x10
    blt x23, x5, _br_taken_21
    srl x13, x14, x6
    j _br_done_21
_br_taken_21:
    sltu x13, x18, x5
_br_done_21:
    lwu x12, 332(x31)
    sw x28, 332(x31)
    sub x15, x23, x12
    xor x11, x24, x24
    ori x10, x23, -1778
    slti x4, x15, -636
    srlw x16, x25, x1
    sltiu x28, x28, 896
    srliw x4, x26, 17
    addiw x5, x27, 1819
    slliw x8, x14, 1
    sltu x17, x27, x7
    fmin.d f29, f30, f15
    bltu x17, x8, _br_taken_22
    srl x13, x4, x26
    j _br_done_22
_br_taken_22:
    sra x13, x6, x7
_br_done_22:
    lw x28, 968(x31)
    sw x1, 968(x31)
    add x12, x24, x13
    sltiu x13, x24, 299
    bgeu x8, x19, _br_taken_23
    sltu x27, x12, x21
    j _br_done_23
_br_taken_23:
    sltu x27, x14, x25
_br_done_23:
    and x6, x15, x16
    ori x24, x29, -961
    sra x15, x16, x7
    blt x15, x19, _br_taken_24
    xor x24, x16, x11
    j _br_done_24
_br_taken_24:
    srl x24, x26, x28
_br_done_24:
    sllw x15, x14, x28
    slti x14, x16, 1924
    srli x17, x4, 23
    add x10, x5, x15
    sltu x1, x28, x18
    srliw x10, x6, 28
    addi x18, x17, -1499
    srli x11, x7, 49
    or x12, x22, x10
    addw x21, x10, x15
    sltu x16, x17, x12
    mul x23, x15, x11
    mulh x9, x29, x19
    slti x27, x17, -1744
    slli x17, x26, 60
    lh x22, 344(x31)
    sh x28, 344(x31)
    xor x27, x17, x23
    srliw x20, x28, 24
    slti x10, x10, -469
    xori x7, x21, 69
    xor x4, x14, x8
    sltu x19, x6, x10
    bne x16, x4, _br_taken_25
    and x14, x16, x21
    j _br_done_25
_br_taken_25:
    srl x14, x6, x7
_br_done_25:
    bltu x4, x15, _br_taken_26
    or x4, x18, x28
    j _br_done_26
_br_taken_26:
    srl x4, x25, x18
_br_done_26:
    andi x6, x6, 667
    slt x22, x5, x14
    slti x25, x22, -881
    sllw x1, x13, x13
    addw x28, x10, x23
    sra x7, x26, x13
    fadd.s f9, f24, f21
    slt x15, x11, x12
    andi x5, x27, -1583
    addiw x21, x26, 1063
    fadd.s f15, f9, f9
    sub x24, x14, x29
    ld x25, 544(x31)
    sd x28, 544(x31)
    bne x13, x17, _br_taken_27
    slt x11, x16, x17
    j _br_done_27
_br_taken_27:
    and x11, x25, x23
_br_done_27:
    bgeu x13, x13, _br_taken_28
    sub x26, x1, x12
    j _br_done_28
_br_taken_28:
    sltu x26, x18, x14
_br_done_28:
    sltu x23, x6, x5
    and x4, x22, x24
    srli x7, x25, 7
    sll x10, x13, x11
    sraiw x8, x7, 3
    srli x6, x19, 32
    sltiu x28, x5, 1263
    slti x26, x27, -492
    addw x25, x17, x15
    subw x27, x10, x7
    subw x12, x9, x22
    srl x28, x16, x10
    slti x18, x4, 1662
    sltiu x21, x6, 590
    or x1, x24, x21
    srliw x28, x25, 0
    slliw x15, x19, 27
    subw x17, x29, x11
    srliw x7, x8, 22
    mulhsu x29, x7, x13
    andi x24, x11, 225
    addiw x24, x27, -1934
    slti x5, x12, 1627
    or x11, x1, x11
    slti x1, x17, 719
    sll x16, x24, x29
    srai x4, x13, 53
    addiw x19, x25, -268
    addi x30, x31, 48
    amomaxu.d x23, x1, (x30)
    bltu x8, x19, _br_taken_29
    sra x14, x4, x26
    j _br_done_29
_br_taken_29:
    add x14, x12, x20
_br_done_29:
    mulh x6, x4, x17
    mulhsu x11, x25, x6
    srl x6, x6, x1
    andi x19, x23, -883
    sltu x22, x16, x22
    addw x20, x14, x27
    srliw x21, x1, 17
    srl x14, x15, x29
    or x21, x9, x20
    slt x18, x21, x15
    or x14, x21, x20
    bgeu x4, x5, _br_taken_30
    slt x6, x28, x4
    j _br_done_30
_br_taken_30:
    sll x6, x21, x10
_br_done_30:
    sraiw x17, x27, 0
    xori x6, x14, -1413
    srliw x4, x22, 10
    fmadd.s f21, f17, f15, f31
    lh x24, 964(x31)
    sh x27, 964(x31)
    sraw x17, x23, x8
    srl x25, x5, x6
    blt x23, x29, _br_taken_31
    or x7, x27, x10
    j _br_done_31
_br_taken_31:
    srl x7, x10, x15
_br_done_31:
    ld x26, 40(x31)
    sd x1, 40(x31)
    fmin.d f8, f14, f8
    srliw x9, x7, 31
    ori x7, x7, -1223
    srliw x15, x19, 25
    sll x28, x11, x18
    addi x15, x16, 142
    slt x9, x7, x28
    sraiw x22, x12, 13
    srliw x23, x23, 10
    srai x7, x7, 21
    srai x29, x20, 32
    subw x4, x19, x10
    sraw x7, x11, x12
    lh x29, 220(x31)
    sh x25, 220(x31)
    lh x1, 220(x31)
    sh x1, 220(x31)
    fadd.s f23, f22, f2
    fmax.d f23, f23, f13
    addi x30, x31, 868
    amoxor.w x9, x21, (x30)
    srl x19, x23, x15
    sltu x11, x10, x8
    fmin.s f0, f14, f31
    fmin.d f14, f26, f23
    fadd.s f25, f13, f10
    fmax.s f19, f5, f27
    sllw x25, x1, x14
    addw x11, x23, x26
    srai x22, x12, 0
    addiw x5, x12, 1181
    addiw x8, x24, -312
    addiw x27, x8, -797
    subw x5, x15, x8
    fmax.d f16, f25, f19
    blt x19, x27, _br_taken_32
    xor x16, x1, x23
    j _br_done_32
_br_taken_32:
    xor x16, x11, x16
_br_done_32:
    mulh x18, x28, x8
    blt x19, x24, _br_taken_33
    sll x14, x14, x6
    j _br_done_33
_br_taken_33:
    slt x14, x1, x22
_br_done_33:

    j _torture_test_end

    .data
    .align 3
_torture_fp_init:
    .dword 0xf9f459009c0f5ae4
    .dword 0x41c7ae90649619b6
    .dword 0x5fae505d6edc0dad
    .dword 0x1fad9e2c60e16c7c
    .dword 0xe5a8561925d77b28
    .dword 0x2c2d2fa6797f539f
    .dword 0xa536efee034bf447
    .dword 0xbd9519920d544743
    .dword 0x5def583e9336ef6e
    .dword 0x32783894f1148fca
    .dword 0x570e7b71b0f48799
    .dword 0x5b416bc2f9cdfa1d
    .dword 0xd556a372fe039870
    .dword 0x97726b609b7ddd1a
    .dword 0x62e258c62ceb3331
    .dword 0x94159d5831921a10
    .dword 0xe750b74e831f9f6e
    .dword 0x31452a642f5e0645
    .dword 0xae18e13c7ce04c10
    .dword 0x77f203725991326b
    .dword 0x76bacdc357c6db07
    .dword 0xb72b058a349cc008
    .dword 0xa9dfa504520d2ea3
    .dword 0xe229e2be94842f6d
    .dword 0x1480de20cac829eb
    .dword 0x3d0d6234e0e752cd
    .dword 0xfe67b489808d7720
    .dword 0xf377464fe96b2bf7
    .dword 0xab39b2758f7ec704
    .dword 0x597f2aeb2555244b
    .dword 0xd63964652d7c12b5
    .dword 0x6675e353ea71e839

    .align 2
_torture_data:
    .word 0x92b91888
    .word 0x9856943e
    .word 0xc838426f
    .word 0xc8c3cb24
    .word 0xb3b89cae
    .word 0xf30c334d
    .word 0x5769ea58
    .word 0x6df91d3d
    .word 0xd7d2316d
    .word 0xe9083921
    .word 0xa5cd1d7e
    .word 0xbe86d9f6
    .word 0xd2d0dd96
    .word 0xc24d23ae
    .word 0xdabb7eea
    .word 0x7ad99780
    .word 0xe22f93c1
    .word 0x4b3f078e
    .word 0x7f81f512
    .word 0xd442f07d
    .word 0xee13e664
    .word 0x31ca841d
    .word 0x4f4e7d3d
    .word 0x2d02b540
    .word 0xdf1a1061
    .word 0x9fa654d2
    .word 0x9c97c2b7
    .word 0x9cad1836
    .word 0xe8331828
    .word 0x6b2cdcc1
    .word 0x3f48400d
    .word 0xe34fd284
    .word 0xa9f457e1
    .word 0xf65fe29e
    .word 0xfcf4bf60
    .word 0x4daf39e9
    .word 0x23f37f32
    .word 0x35dd614d
    .word 0x650bc4c8
    .word 0x0073162a
    .word 0x6b5deb0d
    .word 0xb1930cca
    .word 0x56b064d5
    .word 0x8e26b11d
    .word 0xee88eb51
    .word 0xf1bd7abd
    .word 0xcee5758d
    .word 0x77122f96
    .word 0x2132eb0e
    .word 0xc9b42c3c
    .word 0xde0df67f
    .word 0xcfd43258
    .word 0x6268ac59
    .word 0x7026e659
    .word 0x9024493e
    .word 0x65e48caf
    .word 0xf2655a0f
    .word 0x8f01e21a
    .word 0x0068086e
    .word 0xa353dc36
    .word 0xf5720dae
    .word 0x77415d86
    .word 0x823ae0ab
    .word 0x3d6ec01d
    .word 0xbf7c4d81
    .word 0xf0b847d4
    .word 0x891ffccb
    .word 0xba80cbaa
    .word 0xa1a77fbe
    .word 0x8410c0a4
    .word 0xedb7016f
    .word 0x6fc738b8
    .word 0x2185d172
    .word 0xfb707469
    .word 0xf0f26466
    .word 0xc3aec50c
    .word 0x16caee5d
    .word 0xd7607778
    .word 0x4ddffeef
    .word 0x794168b4
    .word 0x53310ab0
    .word 0x9694faaa
    .word 0x866ea1e0
    .word 0x5d5086be
    .word 0xc58e1bcd
    .word 0xfedfcb0c
    .word 0x9d433270
    .word 0xbcf956c8
    .word 0xfac14d72
    .word 0x0a4e4892
    .word 0x98103835
    .word 0x15c3dcc1
    .word 0x74721022
    .word 0xd594d7a2
    .word 0x9e242dcb
    .word 0xbcd216f9
    .word 0x26767c24
    .word 0x010b10c2
    .word 0x233ae4bf
    .word 0x2b821b96
    .word 0x2de8dc55
    .word 0x7c7556f1
    .word 0xb0e88671
    .word 0xc6335aa4
    .word 0xbca12240
    .word 0xfcc24e14
    .word 0xd692e50b
    .word 0x441c6f46
    .word 0x35df0010
    .word 0x947318cc
    .word 0x30ae3adb
    .word 0x800411a0
    .word 0xe161e797
    .word 0x18dceed0
    .word 0x41e36de4
    .word 0x599b9515
    .word 0xeb002b01
    .word 0x8d065f24
    .word 0x4b902171
    .word 0x9089b294
    .word 0x1871b068
    .word 0x387145b8
    .word 0x041feb64
    .word 0x9e606c8b
    .word 0x00cc089d
    .word 0xd1fcc2c6
    .word 0xfe28d7d3
    .word 0x7ed26e27
    .word 0x98ea3db5
    .word 0xf1596600
    .word 0x33449c84
    .word 0xd9e09add
    .word 0x4524a416
    .word 0xe26c1dae
    .word 0xab80cf07
    .word 0x08541ee1
    .word 0x4cd814e0
    .word 0xdc987c42
    .word 0x030e814e
    .word 0xf873390e
    .word 0xf211684f
    .word 0x8fb386db
    .word 0x03ecdfb0
    .word 0x8c8e5db2
    .word 0x0a803b82
    .word 0x1b315bf8
    .word 0xade59284
    .word 0x4fee0bd5
    .word 0x30483f12
    .word 0xdbdc57de
    .word 0xfb244105
    .word 0xa8e05ed2
    .word 0x5def157a
    .word 0x1a5a6117
    .word 0x89bd1f2c
    .word 0x4c8c0245
    .word 0xe4701db7
    .word 0x206c5102
    .word 0x85ef162b
    .word 0x0cdec05e
    .word 0x94ef4977
    .word 0xddbd02b3
    .word 0xd7e81c98
    .word 0xe2b3685c
    .word 0x2d4256b2
    .word 0x115a5905
    .word 0x1ce51052
    .word 0x58dc6b76
    .word 0x3a37b8e9
    .word 0x2ee06395
    .word 0xa4231379
    .word 0x25a4b2c8
    .word 0x79216c01
    .word 0x81a4466a
    .word 0x55bb8015
    .word 0x96f94fb4
    .word 0x4be55e08
    .word 0xd95065b1
    .word 0x373d4ba9
    .word 0x8365d372
    .word 0xb0146ffb
    .word 0x905321e2
    .word 0x30fb6d20
    .word 0x19138b9b
    .word 0x5296f2bb
    .word 0x26671813
    .word 0x5575b51c
    .word 0x650df52a
    .word 0xd8c351be
    .word 0xc1b633d5
    .word 0xb9c76404
    .word 0xd9fc06e8
    .word 0xbafd1162
    .word 0x88f77099
    .word 0xbd2d6750
    .word 0x132b8141
    .word 0x8d533981
    .word 0x65b18bef
    .word 0x726eb3b2
    .word 0x157066d8
    .word 0x6aed3d9b
    .word 0xea6188b7
    .word 0xbf11fa02
    .word 0x7452c8ed
    .word 0x167144b7
    .word 0x2749bb62
    .word 0xa75419fa
    .word 0x5bdd9e0a
    .word 0x9d7ecef4
    .word 0x00b29c34
    .word 0x4dae1caa
    .word 0xf91f0ec9
    .word 0xbbf91bc3
    .word 0x1fb445cd
    .word 0x5c283b09
    .word 0xa0833b41
    .word 0x74780621
    .word 0x5df1c8cd
    .word 0x878bf23c
    .word 0xb55ec5f3
    .word 0x703fb85f
    .word 0xab0769e9
    .word 0xca44cf51
    .word 0x5dd335ec
    .word 0x1d2d8b08
    .word 0x42b4f1bf
    .word 0xc4a764ba
    .word 0x7758371f
    .word 0xc81ac097
    .word 0x64999815
    .word 0x3ae542c6
    .word 0x95544368
    .word 0xea4afb2c
    .word 0x5dd47632
    .word 0x7fd0be82
    .word 0x0e03555d
    .word 0x9726280d
    .word 0x88ff9349
    .word 0x3c798ced
    .word 0x70d7221d
    .word 0xfc84ab6a
    .word 0x5c72a3aa
    .word 0xdcd24cf6
    .word 0x11cb999e
    .word 0xce42f7af
    .word 0x90d81164
    .word 0x1e5e8485
    .word 0x66115d92
    .word 0x2a4c31dc
    .word 0xf145112f
    .word 0x75deb397
    .word 0xc8fb98c4
    .word 0x8e3c1afb
    .word 0xe3344625
    .word 0x14f33d48
    .word 0x379f00df

#include "frost_footer.S"
