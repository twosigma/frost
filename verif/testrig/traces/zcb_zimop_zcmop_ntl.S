# Zcb, Zcmop, Zimop and Zihintntl in M: every new encoding, compared with Sail
# with those extensions enabled in sail_frost.json, plus reserved neighbours
# that stay illegal. Compressed parcels ride in the low halfword.
# x9 = 0x8000_0000 (cached DDR); x10 = a 64-bit pattern stored at 0(x9), 8(x9).
.4byte 0x00100493 # addi x9, x0, 1
.4byte 0x01f49493 # slli x9, x9, 31
.4byte 0x8badf537 # lui x10, 0x8badf
.4byte 0x0ed50513 # addi x10, x10, 237
.4byte 0x01451613 # slli x12, x10, 20
.4byte 0x00c56533 # or x10, x10, x12
.4byte 0x00a4b023 # sd x10, 0(x9)
.4byte 0x00a4b423 # sd x10, 8(x9)
.4byte 0x00848413 # addi x8, x9, 8
# Zcb loads (x9 = s1 is rs1' 001; rd' 010..101 = x10..x13)
.4byte 0x0000808c # c.lbu x11, 0(x9)
.4byte 0x000080cc # c.lbu x11, 1(x9)
.4byte 0x000080ac # c.lbu x11, 2(x9)
.4byte 0x000080ec # c.lbu x11, 3(x9)
.4byte 0x00008490 # c.lhu x12, 0(x9)
.4byte 0x000084d4 # c.lh x13, 0(x9)
.4byte 0x000084b0 # c.lhu x12, 2(x9)
.4byte 0x000084f4 # c.lh x13, 2(x9)
# Zcb stores into 8(x9) through x8 = s0 (rs1' 000), then read back
.4byte 0xfff00713 # addi x14, x0, -1
.4byte 0x00e43023 # sd x14, 0(x8)
.4byte 0x00008808 # c.sb x10, 0(x8)
.4byte 0x0000884c # c.sb x11, 1(x8)
.4byte 0x00008830 # c.sb x12, 2(x8)
.4byte 0x00008874 # c.sb x13, 3(x8)
.4byte 0x00008c14 # c.sh x13, 0(x8)
.4byte 0x00008c2c # c.sh x11, 2(x8)
.4byte 0x00043783 # ld x15, 0(x8)
# Zcb unary forms and C.MUL, each on a copy of x10
.4byte 0x00050593 # addi x11, x10, 0
.4byte 0x00009de1 # c.zext.b x11
.4byte 0x00050613 # addi x12, x10, 0
.4byte 0x00009e65 # c.sext.b x12
.4byte 0x00050693 # addi x13, x10, 0
.4byte 0x00009ee9 # c.zext.h x13
.4byte 0x00050713 # addi x14, x10, 0
.4byte 0x00009f6d # c.sext.h x14
.4byte 0x00050793 # addi x15, x10, 0
.4byte 0x00009ff1 # c.zext.w x15
.4byte 0x00050513 # addi x10, x10, 0
.4byte 0x00009d75 # c.not x10
.4byte 0xffb50593 # addi x11, x10, -5
.4byte 0x00700613 # addi x12, x0, 7
.4byte 0x00009dd1 # c.mul x11, x12
.4byte 0x00009e51 # c.mul x12, x12
# Zcmop: c.mop.n writes no register; x1..x15 hold nonzero values
.4byte 0x06500093 # addi x1, x0, 101
.4byte 0x00006081 # c.mop.1
.4byte 0x06700193 # addi x3, x0, 103
.4byte 0x00006181 # c.mop.3
.4byte 0x06900293 # addi x5, x0, 105
.4byte 0x00006281 # c.mop.5
.4byte 0x06b00393 # addi x7, x0, 107
.4byte 0x00006381 # c.mop.7
.4byte 0x06d00493 # addi x9, x0, 109
.4byte 0x00006481 # c.mop.9
.4byte 0x06f00593 # addi x11, x0, 111
.4byte 0x00006581 # c.mop.11
.4byte 0x07100693 # addi x13, x0, 113
.4byte 0x00006681 # c.mop.13
.4byte 0x07300793 # addi x15, x0, 115
.4byte 0x00006781 # c.mop.15
.4byte 0x00f08833 # add x16, x1, x15
# Zimop: every mop.r.n and mop.rr.n writes zero to rd
.4byte 0x3e800893 # addi x17, x0, 1000
.4byte 0x81c548f3 # mop.r.0 x17, x10
.4byte 0x3e900913 # addi x18, x0, 1001
.4byte 0x81d54973 # mop.r.1 x18, x10
.4byte 0x3ea00993 # addi x19, x0, 1002
.4byte 0x81e549f3 # mop.r.2 x19, x10
.4byte 0x3eb00a13 # addi x20, x0, 1003
.4byte 0x81f54a73 # mop.r.3 x20, x10
.4byte 0x3ec00a93 # addi x21, x0, 1004
.4byte 0x85c54af3 # mop.r.4 x21, x10
.4byte 0x3ed00b13 # addi x22, x0, 1005
.4byte 0x85d54b73 # mop.r.5 x22, x10
.4byte 0x3ee00b93 # addi x23, x0, 1006
.4byte 0x85e54bf3 # mop.r.6 x23, x10
.4byte 0x3ef00c13 # addi x24, x0, 1007
.4byte 0x85f54c73 # mop.r.7 x24, x10
.4byte 0x3f000c93 # addi x25, x0, 1008
.4byte 0x89c54cf3 # mop.r.8 x25, x10
.4byte 0x3f100d13 # addi x26, x0, 1009
.4byte 0x89d54d73 # mop.r.9 x26, x10
.4byte 0x3f200d93 # addi x27, x0, 1010
.4byte 0x89e54df3 # mop.r.10 x27, x10
.4byte 0x3f300e13 # addi x28, x0, 1011
.4byte 0x89f54e73 # mop.r.11 x28, x10
.4byte 0x3f400e93 # addi x29, x0, 1012
.4byte 0x8dc54ef3 # mop.r.12 x29, x10
.4byte 0x3f500f13 # addi x30, x0, 1013
.4byte 0x8dd54f73 # mop.r.13 x30, x10
.4byte 0x3f600893 # addi x17, x0, 1014
.4byte 0x8de548f3 # mop.r.14 x17, x10
.4byte 0x3f700913 # addi x18, x0, 1015
.4byte 0x8df54973 # mop.r.15 x18, x10
.4byte 0x3f800993 # addi x19, x0, 1016
.4byte 0xc1c549f3 # mop.r.16 x19, x10
.4byte 0x3f900a13 # addi x20, x0, 1017
.4byte 0xc1d54a73 # mop.r.17 x20, x10
.4byte 0x3fa00a93 # addi x21, x0, 1018
.4byte 0xc1e54af3 # mop.r.18 x21, x10
.4byte 0x3fb00b13 # addi x22, x0, 1019
.4byte 0xc1f54b73 # mop.r.19 x22, x10
.4byte 0x3fc00b93 # addi x23, x0, 1020
.4byte 0xc5c54bf3 # mop.r.20 x23, x10
.4byte 0x3fd00c13 # addi x24, x0, 1021
.4byte 0xc5d54c73 # mop.r.21 x24, x10
.4byte 0x3fe00c93 # addi x25, x0, 1022
.4byte 0xc5e54cf3 # mop.r.22 x25, x10
.4byte 0x3ff00d13 # addi x26, x0, 1023
.4byte 0xc5f54d73 # mop.r.23 x26, x10
.4byte 0x40000d93 # addi x27, x0, 1024
.4byte 0xc9c54df3 # mop.r.24 x27, x10
.4byte 0x40100e13 # addi x28, x0, 1025
.4byte 0xc9d54e73 # mop.r.25 x28, x10
.4byte 0x40200e93 # addi x29, x0, 1026
.4byte 0xc9e54ef3 # mop.r.26 x29, x10
.4byte 0x40300f13 # addi x30, x0, 1027
.4byte 0xc9f54f73 # mop.r.27 x30, x10
.4byte 0x40400893 # addi x17, x0, 1028
.4byte 0xcdc548f3 # mop.r.28 x17, x10
.4byte 0x40500913 # addi x18, x0, 1029
.4byte 0xcdd54973 # mop.r.29 x18, x10
.4byte 0x40600993 # addi x19, x0, 1030
.4byte 0xcde549f3 # mop.r.30 x19, x10
.4byte 0x40700a13 # addi x20, x0, 1031
.4byte 0xcdf54a73 # mop.r.31 x20, x10
.4byte 0xfff00893 # addi x17, x0, -1
.4byte 0x82b548f3 # mop.rr.0 x17, x10, x11
.4byte 0xffe00913 # addi x18, x0, -2
.4byte 0x86b54973 # mop.rr.1 x18, x10, x11
.4byte 0xffd00993 # addi x19, x0, -3
.4byte 0x8ab549f3 # mop.rr.2 x19, x10, x11
.4byte 0xffc00a13 # addi x20, x0, -4
.4byte 0x8eb54a73 # mop.rr.3 x20, x10, x11
.4byte 0xffb00a93 # addi x21, x0, -5
.4byte 0xc2b54af3 # mop.rr.4 x21, x10, x11
.4byte 0xffa00b13 # addi x22, x0, -6
.4byte 0xc6b54b73 # mop.rr.5 x22, x10, x11
.4byte 0xff900b93 # addi x23, x0, -7
.4byte 0xcab54bf3 # mop.rr.6 x23, x10, x11
.4byte 0xff800c13 # addi x24, x0, -8
.4byte 0xceb54c73 # mop.rr.7 x24, x10, x11
.4byte 0x81c54073 # mop.r.0 x0, x10
.4byte 0xce94c4f3 # mop.rr.7 x9, x9, x9
.4byte 0xff840493 # addi x9, x8, -8
# Zihintntl: ntl.p1/pall/s1/all and c.ntl.*, each before a load
.4byte 0x00200033 # ntl.p1
.4byte 0x0004ba03 # ld x20, 0(x9)
.4byte 0x0000900a # c.ntl.p1
.4byte 0x0084ba83 # ld x21, 8(x9)
.4byte 0x00300033 # ntl.pall
.4byte 0x0004ba03 # ld x20, 0(x9)
.4byte 0x0000900e # c.ntl.pall
.4byte 0x0084ba83 # ld x21, 8(x9)
.4byte 0x00400033 # ntl.s1
.4byte 0x0004ba03 # ld x20, 0(x9)
.4byte 0x00009012 # c.ntl.s1
.4byte 0x0084ba83 # ld x21, 8(x9)
.4byte 0x00500033 # ntl.all
.4byte 0x0004ba03 # ld x20, 0(x9)
.4byte 0x00009016 # c.ntl.all
.4byte 0x0084ba83 # ld x21, 8(x9)
# Reserved neighbours trap as illegal instructions
.4byte 0x00008cc4 # c.sh slot with bit 6 set
.4byte 0x00009000 # quadrant 0 funct3=100 with bit 12 set
.4byte 0x00009c00 # quadrant 0 funct3=100 [12:10]=111
.4byte 0x00009c79 # zcb unary selector 110
.4byte 0x00009c7d # zcb unary selector 111
.4byte 0x00006201 # c.lui x4, 0
.4byte 0x00006801 # c.lui x16, 0
.4byte 0x00006881 # c.lui x17, 0
.4byte 0x00006001 # c.lui x0, 0
.4byte 0x6005c573 # hlv.b x10, (x11): SYSTEM funct3=100, no H
.4byte 0x91c5c573 # mop.r.0 with bit 28 set
.4byte 0x8185c573 # mop.r.0 with bits 25:22 = 0110
.4byte 0x02c5c573 # mop.rr.0 with bit 31 clear
# Machine state after the traps
.4byte 0x342020f3 # csrr x1, mcause
