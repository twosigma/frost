# Strided vector loads and stores in cached DDR.
.noshrink
# Enable VS and select cached DDR source and destination buffers.
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x40008437  # lui s0, 0x40008
.4byte 0x00141413  # slli s0, s0, 1
.4byte 0x20040493  # addi s1, s0, 512
.4byte 0xc2202e73  # csrr t3, vlenb
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0x5e003ad7  # vmv.v.i v21, 0
.4byte 0x5e003dd7  # vmv.v.i v27, 0

# Unmasked positive-stride EEW 8 vl=3 stride=3 under tu, mu.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0a500313  # addi t1, zero, 165
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x03100313  # addi t1, zero, 49
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x0ee00313  # addi t1, zero, 238
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x0ed00313  # addi t1, zero, 237
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x08200313  # addi t1, zero, 130
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x0ec00313  # addi t1, zero, 236
.4byte 0x00640223  # sb t1, 4(s0)
.4byte 0x0eb00313  # addi t1, zero, 235
.4byte 0x006402a3  # sb t1, 5(s0)
.4byte 0x05700313  # addi t1, zero, 87
.4byte 0x00640323  # sb t1, 6(s0)
.4byte 0x07e00313  # addi t1, zero, 126
.4byte 0x006404a3  # sb t1, 9(s0)
.4byte 0x00300e93  # addi t4, zero, 3
.4byte 0x0bd40407  # vlse8.v v8, (s0), t4
.assert trap == 0 "vlse8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 pos-stride lane 0 writes x10"
.assert rd_wdata == 0x31 "e8 pos-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 pos-stride lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff82 "e8 pos-stride lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 pos-stride lane 2 writes x10"
.assert rd_wdata == 0x57 "e8 pos-stride lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 pos-stride tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "e8 pos-stride tail lane 3"
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x01a00313  # addi t1, zero, 26
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x01200313  # addi t1, zero, 18
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x01b00313  # addi t1, zero, 27
.4byte 0x00648223  # sb t1, 4(s1)
.4byte 0x01300313  # addi t1, zero, 19
.4byte 0x00648323  # sb t1, 6(s1)
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x006484a3  # sb t1, 9(s1)
.4byte 0x0bd48427  # vsse8.v v8, (s1), t4
.assert trap == 0 "vsse8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 pos-stride store at offset 0 writes x10"
.assert rd_wdata == 0x31 "e8 pos-stride store at offset 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "e8 pos-stride store at offset 1 writes x10"
.assert rd_wdata == 0x1a "e8 pos-stride store at offset 1"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "e8 pos-stride store at offset 3 writes x10"
.assert rd_wdata == 0x82 "e8 pos-stride store at offset 3"
.4byte 0x0044c503  # lbu a0, 4(s1)
.assert rd_addr == 10 "e8 pos-stride store at offset 4 writes x10"
.assert rd_wdata == 0x1b "e8 pos-stride store at offset 4"
.4byte 0x0064c503  # lbu a0, 6(s1)
.assert rd_addr == 10 "e8 pos-stride store at offset 6 writes x10"
.assert rd_wdata == 0x57 "e8 pos-stride store at offset 6"
.4byte 0x0094c503  # lbu a0, 9(s1)
.assert rd_addr == 10 "e8 pos-stride store at offset 9 writes x10"
.assert rd_wdata == 0x14 "e8 pos-stride store at offset 9"

# Unmasked positive-stride EEW 16 vl=3 stride=6 under tu, mu.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x55a30313  # addi t1, t1, 1370
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x23430313  # addi t1, t1, 564
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x0000e337  # lui t1, 0xe
.4byte 0xddd30313  # addi t1, t1, -547
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0xa5b30313  # addi t1, t1, -1445
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x0000d337  # lui t1, 0xd
.4byte 0xccc30313  # addi t1, t1, -820
.4byte 0x00641423  # sh t1, 8(s0)
.4byte 0x00005337  # lui t1, 0x5
.4byte 0xc3d30313  # addi t1, t1, -963
.4byte 0x00641623  # sh t1, 12(s0)
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xe6f30313  # addi t1, t1, -401
.4byte 0x00641923  # sh t1, 18(s0)
.4byte 0x00600e93  # addi t4, zero, 6
.4byte 0x0bd45407  # vlse16.v v8, (s0), t4
.assert trap == 0 "vlse16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 pos-stride lane 0 writes x10"
.assert rd_wdata == 0x1234 "e16 pos-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 pos-stride lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff9a5b "e16 pos-stride lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 pos-stride lane 2 writes x10"
.assert rd_wdata == 0x4c3d "e16 pos-stride lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 pos-stride tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffa55a "e16 pos-stride tail lane 3"
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x00649423  # sh t1, 8(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649623  # sh t1, 12(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x00649923  # sh t1, 18(s1)
.4byte 0x0bd4d427  # vsse16.v v8, (s1), t4
.assert trap == 0 "vsse16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 pos-stride store at offset 0 writes x10"
.assert rd_wdata == 0x1234 "e16 pos-stride store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 pos-stride store at offset 2 writes x10"
.assert rd_wdata == 0x2aaa "e16 pos-stride store at offset 2"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "e16 pos-stride store at offset 6 writes x10"
.assert rd_wdata == 0x9a5b "e16 pos-stride store at offset 6"
.4byte 0x0084d503  # lhu a0, 8(s1)
.assert rd_addr == 10 "e16 pos-stride store at offset 8 writes x10"
.assert rd_wdata == 0x2bbb "e16 pos-stride store at offset 8"
.4byte 0x00c4d503  # lhu a0, 12(s1)
.assert rd_addr == 10 "e16 pos-stride store at offset 12 writes x10"
.assert rd_wdata == 0x4c3d "e16 pos-stride store at offset 12"
.4byte 0x0124d503  # lhu a0, 18(s1)
.assert rd_addr == 10 "e16 pos-stride store at offset 18 writes x10"
.assert rd_wdata == 0x2444 "e16 pos-stride store at offset 18"

# Unmasked positive-stride EEW 32 vl=2 stride=12 under tu, mu.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034dd7  # vmv.v.x v27, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x24681337  # lui t1, 0x24681
.4byte 0x35630313  # addi t1, t1, 854
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xddddefb7  # lui t6, 0xdddde
.4byte 0xdddf8f93  # addi t6, t6, -547
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9b5a5fb7  # lui t6, 0x9b5a5
.4byte 0xc3df8f93  # addi t6, t6, -963
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x7e6f6337  # lui t1, 0x7e6f6
.4byte 0xd4c30313  # addi t1, t1, -692
.4byte 0x00642c23  # sw t1, 24(s0)
.4byte 0x00c00e93  # addi t4, zero, 12
.4byte 0x0bd46d87  # vlse32.v v27, (s0), t4
.assert trap == 0 "vlse32.v retires"
.4byte 0x43b02557  # vmv.x.s a0, v27
.assert rd_addr == 10 "e32 pos-stride lane 0 writes x10"
.assert rd_wdata == 0x24681356 "e32 pos-stride lane 0"
.4byte 0x3fb0ba57  # vslidedown.vi v20, v27, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 pos-stride lane 1 writes x10"
.assert rd_wdata == 0xffffffff9b5a4c3d "e32 pos-stride lane 1"
.4byte 0x3fb13a57  # vslidedown.vi v20, v27, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 pos-stride tail lane 2 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "e32 pos-stride tail lane 2"
.4byte 0x31111337  # lui t1, 0x31111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x3aaab337  # lui t1, 0x3aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x3bbbc337  # lui t1, 0x3bbbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x32222337  # lui t1, 0x32222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x33333337  # lui t1, 0x33333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x0bd4eda7  # vsse32.v v27, (s1), t4
.assert trap == 0 "vsse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 pos-stride store at offset 0 writes x10"
.assert rd_wdata == 0x24681356 "e32 pos-stride store at offset 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 pos-stride store at offset 4 writes x10"
.assert rd_wdata == 0x3aaaaaaa "e32 pos-stride store at offset 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "e32 pos-stride store at offset 8 writes x10"
.assert rd_wdata == 0x3bbbbbbb "e32 pos-stride store at offset 8"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "e32 pos-stride store at offset 12 writes x10"
.assert rd_wdata == 0x9b5a4c3d "e32 pos-stride store at offset 12"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "e32 pos-stride store at offset 24 writes x10"
.assert rd_wdata == 0x33333333 "e32 pos-stride store at offset 24"

# Unmasked positive-stride EEW 64 vl=1 stride=16 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa5a5afb7  # lui t6, 0xa5a5a
.4byte 0x5a5f8f93  # addi t6, t6, 1445
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x1 "e64 m1 active vector length"
.4byte 0x92345337  # lui t1, 0x92345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x23456fb7  # lui t6, 0x23456
.4byte 0x789f8f93  # addi t6, t6, 1929
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0xeeeef337  # lui t1, 0xeeeef
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x6a5b5337  # lui t1, 0x6a5b5
.4byte 0xc3d30313  # addi t1, t1, -963
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x34568fb7  # lui t6, 0x34568
.4byte 0x89af8f93  # addi t6, t6, -1894
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x0bd47407  # vlse64.v v8, (s0), t4
.assert trap == 0 "vlse64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 pos-stride lane 0 writes x10"
.assert rd_wdata == 0x9234567823456789 "e64 pos-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 pos-stride tail lane 1 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "e64 pos-stride tail lane 1"
.4byte 0x41111337  # lui t1, 0x41111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x4aaab337  # lui t1, 0x4aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x42222337  # lui t1, 0x42222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0bd4f427  # vsse64.v v8, (s1), t4
.assert trap == 0 "vsse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 pos-stride store at offset 0 writes x10"
.assert rd_wdata == 0x9234567823456789 "e64 pos-stride store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 pos-stride store at offset 8 writes x10"
.assert rd_wdata == 0x4aaaaaaaaaaaaaaa "e64 pos-stride store at offset 8"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 pos-stride store at offset 16 writes x10"
.assert rd_wdata == 0x4222222222222222 "e64 pos-stride store at offset 16"

# Masked positive-stride EEW 8 m1 vl=3 stride=3 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0c300313  # addi t1, zero, 195
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x01500313  # addi t1, zero, 21
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x0ee00313  # addi t1, zero, 238
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x02600313  # addi t1, zero, 38
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x09700313  # addi t1, zero, 151
.4byte 0x00640323  # sb t1, 6(s0)
.4byte 0x04800313  # addi t1, zero, 72
.4byte 0x006404a3  # sb t1, 9(s0)
.4byte 0x00300e93  # addi t4, zero, 3
.4byte 0x09d40407  # vlse8.v v8, (s0), t4, v0.t
.assert trap == 0 "vlse8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 m1 masked enabled lane 0 writes x10"
.assert rd_wdata == 0x15 "e8 m1 masked enabled lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 m1 masked masked-off lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "e8 m1 masked masked-off lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 m1 masked enabled lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff97 "e8 m1 masked enabled lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 m1 masked tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "e8 m1 masked tail lane 3"
.4byte 0x05100313  # addi t1, zero, 81
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x05200313  # addi t1, zero, 82
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x05300313  # addi t1, zero, 83
.4byte 0x00648323  # sb t1, 6(s1)
.4byte 0x05400313  # addi t1, zero, 84
.4byte 0x006484a3  # sb t1, 9(s1)
.4byte 0x09d48427  # vsse8.v v8, (s1), t4, v0.t
.assert trap == 0 "vsse8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 m1 masked strided store at offset 0 writes x10"
.assert rd_wdata == 0x15 "e8 m1 masked strided store at offset 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "e8 m1 masked strided store at offset 1 writes x10"
.assert rd_wdata == 0x5a "e8 m1 masked strided store at offset 1"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "e8 m1 masked strided store at offset 3 writes x10"
.assert rd_wdata == 0x52 "e8 m1 masked strided store at offset 3"
.4byte 0x0064c503  # lbu a0, 6(s1)
.assert rd_addr == 10 "e8 m1 masked strided store at offset 6 writes x10"
.assert rd_wdata == 0x97 "e8 m1 masked strided store at offset 6"
.4byte 0x0094c503  # lbu a0, 9(s1)
.assert rd_addr == 10 "e8 m1 masked strided store at offset 9 writes x10"
.assert rd_wdata == 0x54 "e8 m1 masked strided store at offset 9"

# Masked positive-stride EEW 16 m1 vl=3 stride=6 mask=0b10 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00004337  # lui t1, 0x4
.4byte 0xc3c30313  # addi t1, t1, -964
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00641623  # sh t1, 12(s0)
.4byte 0x00004337  # lui t1, 0x4
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x00641923  # sh t1, 18(s0)
.4byte 0x00600e93  # addi t4, zero, 6
.4byte 0x09d45407  # vlse16.v v8, (s0), t4, v0.t
.assert trap == 0 "vlse16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 m1 masked masked-off lane 0 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 masked masked-off lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 m1 masked enabled lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8222 "e16 m1 masked enabled lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 m1 masked masked-off lane 2 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 masked masked-off lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 m1 masked tail lane 3 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 masked tail lane 3"
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00007337  # lui t1, 0x7
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649623  # sh t1, 12(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x00649923  # sh t1, 18(s1)
.4byte 0x09d4d427  # vsse16.v v8, (s1), t4, v0.t
.assert trap == 0 "vsse16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 m1 masked strided store at offset 0 writes x10"
.assert rd_wdata == 0x6111 "e16 m1 masked strided store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 m1 masked strided store at offset 2 writes x10"
.assert rd_wdata == 0x6aaa "e16 m1 masked strided store at offset 2"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "e16 m1 masked strided store at offset 6 writes x10"
.assert rd_wdata == 0x8222 "e16 m1 masked strided store at offset 6"
.4byte 0x00c4d503  # lhu a0, 12(s1)
.assert rd_addr == 10 "e16 m1 masked strided store at offset 12 writes x10"
.assert rd_wdata == 0x6333 "e16 m1 masked strided store at offset 12"
.4byte 0x0124d503  # lhu a0, 18(s1)
.assert rd_addr == 10 "e16 m1 masked strided store at offset 18 writes x10"
.assert rd_wdata == 0x6444 "e16 m1 masked strided store at offset 18"

# Masked positive-stride EEW 32 m1 vl=3 stride=12 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x33445337  # lui t1, 0x33445
.4byte 0x56630313  # addi t1, t1, 1382
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x22334337  # lui t1, 0x22334
.4byte 0x45530313  # addi t1, t1, 1109
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x99aacfb7  # lui t6, 0x99aac
.4byte 0xbccf8f93  # addi t6, t6, -1076
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642c23  # sw t1, 24(s0)
.4byte 0x44556337  # lui t1, 0x44556
.4byte 0x67730313  # addi t1, t1, 1655
.4byte 0x02642223  # sw t1, 36(s0)
.4byte 0x00c00e93  # addi t4, zero, 12
.4byte 0x09d46407  # vlse32.v v8, (s0), t4, v0.t
.assert trap == 0 "vlse32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 m1 masked enabled lane 0 writes x10"
.assert rd_wdata == 0x11223344 "e32 m1 masked enabled lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 m1 masked masked-off lane 1 writes x10"
.assert rd_wdata == 0x33445566 "e32 m1 masked masked-off lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 m1 masked enabled lane 2 writes x10"
.assert rd_wdata == 0xffffffff99aabbcc "e32 m1 masked enabled lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 m1 masked tail lane 3 writes x10"
.assert rd_wdata == 0x33445566 "e32 m1 masked tail lane 3"
.4byte 0x71000337  # lui t1, 0x71000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x7aaab337  # lui t1, 0x7aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x72000337  # lui t1, 0x72000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x73000337  # lui t1, 0x73000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x74000337  # lui t1, 0x74000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0264a223  # sw t1, 36(s1)
.4byte 0x09d4e427  # vsse32.v v8, (s1), t4, v0.t
.assert trap == 0 "vsse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 m1 masked strided store at offset 0 writes x10"
.assert rd_wdata == 0x11223344 "e32 m1 masked strided store at offset 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 m1 masked strided store at offset 4 writes x10"
.assert rd_wdata == 0x7aaaaaaa "e32 m1 masked strided store at offset 4"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "e32 m1 masked strided store at offset 12 writes x10"
.assert rd_wdata == 0x72000002 "e32 m1 masked strided store at offset 12"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "e32 m1 masked strided store at offset 24 writes x10"
.assert rd_wdata == 0x99aabbcc "e32 m1 masked strided store at offset 24"
.4byte 0x0244e503  # lwu a0, 36(s1)
.assert rd_addr == 10 "e32 m1 masked strided store at offset 36 writes x10"
.assert rd_wdata == 0x74000004 "e32 m1 masked strided store at offset 36"

# Masked positive-stride EEW 64 m1 vl=2 stride=16 mask=0b10 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x0f1e3337  # lui t1, 0xf1e3
.4byte 0xd3c30313  # addi t1, t1, -708
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x4b5a7fb7  # lui t6, 0x4b5a7
.4byte 0x978f8f93  # addi t6, t6, -1672
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x11112337  # lui t1, 0x11112
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33334fb7  # lui t6, 0x33334
.4byte 0x444f8f93  # addi t6, t6, 1092
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0xeeeef337  # lui t1, 0xeeeef
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x88887337  # lui t1, 0x88887
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x66665fb7  # lui t6, 0x66665
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x09d47407  # vlse64.v v8, (s0), t4, v0.t
.assert trap == 0 "vlse64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 m1 masked masked-off lane 0 writes x10"
.assert rd_wdata == 0xf1e2d3c4b5a6978 "e64 m1 masked masked-off lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m1 masked enabled lane 1 writes x10"
.assert rd_wdata == 0x8888777766665555 "e64 m1 masked enabled lane 1"
.4byte 0x71111337  # lui t1, 0x71111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x7aaab337  # lui t1, 0x7aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x72222337  # lui t1, 0x72222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x73333337  # lui t1, 0x73333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33333fb7  # lui t6, 0x33333
.4byte 0x333f8f93  # addi t6, t6, 819
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x09d4f427  # vsse64.v v8, (s1), t4, v0.t
.assert trap == 0 "vsse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 m1 masked strided store at offset 0 writes x10"
.assert rd_wdata == 0x7111111111111111 "e64 m1 masked strided store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 m1 masked strided store at offset 8 writes x10"
.assert rd_wdata == 0x7aaaaaaaaaaaaaaa "e64 m1 masked strided store at offset 8"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 m1 masked strided store at offset 16 writes x10"
.assert rd_wdata == 0x8888777766665555 "e64 m1 masked strided store at offset 16"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e64 m1 masked strided store at offset 32 writes x10"
.assert rd_wdata == 0x7333333333333333 "e64 m1 masked strided store at offset 32"

# Masked positive-stride EEW 64 m2 vl=3 stride=16 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x1f2e4337  # lui t1, 0x1f2e4
.4byte 0xd4c30313  # addi t1, t1, -692
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5b6a8fb7  # lui t6, 0x5b6a8
.4byte 0x988f8f93  # addi t6, t6, -1656
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.assert rd_addr == 12 "e64 m2 active vector length writes x12"
.assert rd_wdata == 0x3 "e64 m2 active vector length"
.4byte 0x21222337  # lui t1, 0x21222
.4byte 0x32430313  # addi t1, t1, 804
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x25262fb7  # lui t6, 0x25262
.4byte 0x728f8f93  # addi t6, t6, 1832
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x31323337  # lui t1, 0x31323
.4byte 0x33430313  # addi t1, t1, 820
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x35363fb7  # lui t6, 0x35363
.4byte 0x738f8f93  # addi t6, t6, 1848
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0xa1a2a337  # lui t1, 0xa1a2a
.4byte 0x3a430313  # addi t1, t1, 932
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa5a6afb7  # lui t6, 0xa5a6a
.4byte 0x7a8f8f93  # addi t6, t6, 1960
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643023  # sd t1, 32(s0)
.4byte 0x41424337  # lui t1, 0x41424
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x45464fb7  # lui t6, 0x45464
.4byte 0x748f8f93  # addi t6, t6, 1864
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643823  # sd t1, 48(s0)
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x09d47407  # vlse64.v v8, (s0), t4, v0.t
.assert trap == 0 "vlse64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 m2 masked enabled lane 0 writes x10"
.assert rd_wdata == 0x2122232425262728 "e64 m2 masked enabled lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m2 masked masked-off lane 1 writes x10"
.assert rd_wdata == 0x1f2e3d4c5b6a7988 "e64 m2 masked masked-off lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m2 masked enabled lane 2 writes x10"
.assert rd_wdata == 0xa1a2a3a4a5a6a7a8 "e64 m2 masked enabled lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m2 masked tail lane 3 writes x10"
.assert rd_wdata == 0x1f2e3d4c5b6a7988 "e64 m2 masked tail lane 3"
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00200f93  # addi t6, zero, 2
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x63000337  # lui t1, 0x63000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00300f93  # addi t6, zero, 3
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x64000337  # lui t1, 0x64000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00400f93  # addi t6, zero, 4
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x09d4f427  # vsse64.v v8, (s1), t4, v0.t
.assert trap == 0 "vsse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 m2 masked strided store at offset 0 writes x10"
.assert rd_wdata == 0x2122232425262728 "e64 m2 masked strided store at offset 0"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 m2 masked strided store at offset 16 writes x10"
.assert rd_wdata == 0x6200000000000002 "e64 m2 masked strided store at offset 16"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e64 m2 masked strided store at offset 32 writes x10"
.assert rd_wdata == 0xa1a2a3a4a5a6a7a8 "e64 m2 masked strided store at offset 32"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e64 m2 masked strided store at offset 48 writes x10"
.assert rd_wdata == 0x6400000000000004 "e64 m2 masked strided store at offset 48"

# Negative strides walk downward in cached DDR across all four widths.
.4byte 0x04040913  # addi s2, s0, 64
.4byte 0x04048993  # addi s3, s1, 64

# Unmasked negative-stride EEW 8 vl=3 stride=-3.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0b400313  # addi t1, zero, 180
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x04100313  # addi t1, zero, 65
.4byte 0x00690023  # sb t1, 0(s2)
.4byte 0x09200313  # addi t1, zero, 146
.4byte 0xfe690ea3  # sb t1, -3(s2)
.4byte 0x06300313  # addi t1, zero, 99
.4byte 0xfe690d23  # sb t1, -6(s2)
.4byte 0x07400313  # addi t1, zero, 116
.4byte 0xfe690ba3  # sb t1, -9(s2)
.4byte 0x0ee00313  # addi t1, zero, 238
.4byte 0xfe690fa3  # sb t1, -1(s2)
.4byte 0x02500313  # addi t1, zero, 37
.4byte 0x006901a3  # sb t1, 3(s2)
.4byte 0x02600313  # addi t1, zero, 38
.4byte 0x00690323  # sb t1, 6(s2)
.4byte 0xffd00e93  # addi t4, zero, -3
.4byte 0x0bd90407  # vlse8.v v8, (s2), t4
.assert trap == 0 "vlse8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 neg-stride lane 0 writes x10"
.assert rd_wdata == 0x41 "e8 neg-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 neg-stride lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff92 "e8 neg-stride lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 neg-stride lane 2 writes x10"
.assert rd_wdata == 0x63 "e8 neg-stride lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 neg-stride lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffb4 "e8 neg-stride lane 3"
.4byte 0x08100313  # addi t1, zero, 129
.4byte 0x00698023  # sb t1, 0(s3)
.4byte 0x08200313  # addi t1, zero, 130
.4byte 0xfe698ea3  # sb t1, -3(s3)
.4byte 0x08300313  # addi t1, zero, 131
.4byte 0xfe698d23  # sb t1, -6(s3)
.4byte 0x08400313  # addi t1, zero, 132
.4byte 0xfe698ba3  # sb t1, -9(s3)
.4byte 0x08a00313  # addi t1, zero, 138
.4byte 0xfe698fa3  # sb t1, -1(s3)
.4byte 0x08b00313  # addi t1, zero, 139
.4byte 0x006981a3  # sb t1, 3(s3)
.4byte 0x0bd98427  # vsse8.v v8, (s3), t4
.assert trap == 0 "vsse8.v retires"
.4byte 0x0009c503  # lbu a0, 0(s3)
.assert rd_addr == 10 "e8 neg-stride store at offset 0 writes x10"
.assert rd_wdata == 0x41 "e8 neg-stride store at offset 0"
.4byte 0xffd9c503  # lbu a0, -3(s3)
.assert rd_addr == 10 "e8 neg-stride store at offset -3 writes x10"
.assert rd_wdata == 0x92 "e8 neg-stride store at offset -3"
.4byte 0xffa9c503  # lbu a0, -6(s3)
.assert rd_addr == 10 "e8 neg-stride store at offset -6 writes x10"
.assert rd_wdata == 0x63 "e8 neg-stride store at offset -6"
.4byte 0xff79c503  # lbu a0, -9(s3)
.assert rd_addr == 10 "e8 neg-stride store at offset -9 writes x10"
.assert rd_wdata == 0x84 "e8 neg-stride store at offset -9"
.4byte 0xfff9c503  # lbu a0, -1(s3)
.assert rd_addr == 10 "e8 neg-stride store at offset -1 writes x10"
.assert rd_wdata == 0x8a "e8 neg-stride store at offset -1"
.4byte 0x0039c503  # lbu a0, 3(s3)
.assert rd_addr == 10 "e8 neg-stride store at offset 3 writes x10"
.assert rd_wdata == 0x8b "e8 neg-stride store at offset 3"

# Unmasked negative-stride EEW 16 vl=3 stride=-6.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x44b30313  # addi t1, t1, 1099
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x34530313  # addi t1, t1, 837
.4byte 0x00691023  # sh t1, 0(s2)
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x87630313  # addi t1, t1, -1930
.4byte 0xfe691d23  # sh t1, -6(s2)
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x43230313  # addi t1, t1, 1074
.4byte 0xfe691a23  # sh t1, -12(s2)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x78930313  # addi t1, t1, 1929
.4byte 0xfe691723  # sh t1, -18(s2)
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0xfe691f23  # sh t1, -2(s2)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0xa1a30313  # addi t1, t1, -1510
.4byte 0x00691323  # sh t1, 6(s2)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0xb2b30313  # addi t1, t1, -1237
.4byte 0x00691623  # sh t1, 12(s2)
.4byte 0xffa00e93  # addi t4, zero, -6
.4byte 0x0bd95407  # vlse16.v v8, (s2), t4
.assert trap == 0 "vlse16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 neg-stride lane 0 writes x10"
.assert rd_wdata == 0x2345 "e16 neg-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 neg-stride lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff9876 "e16 neg-stride lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 neg-stride lane 2 writes x10"
.assert rd_wdata == 0x5432 "e16 neg-stride lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 neg-stride lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffb44b "e16 neg-stride lane 3"
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00699023  # sh t1, 0(s3)
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0xfe699d23  # sh t1, -6(s3)
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0xfe699a23  # sh t1, -12(s3)
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0xfe699723  # sh t1, -18(s3)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0xfe699f23  # sh t1, -2(s3)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x00699323  # sh t1, 6(s3)
.4byte 0x0bd9d427  # vsse16.v v8, (s3), t4
.assert trap == 0 "vsse16.v retires"
.4byte 0x0009d503  # lhu a0, 0(s3)
.assert rd_addr == 10 "e16 neg-stride store at offset 0 writes x10"
.assert rd_wdata == 0x2345 "e16 neg-stride store at offset 0"
.4byte 0xffa9d503  # lhu a0, -6(s3)
.assert rd_addr == 10 "e16 neg-stride store at offset -6 writes x10"
.assert rd_wdata == 0x9876 "e16 neg-stride store at offset -6"
.4byte 0xff49d503  # lhu a0, -12(s3)
.assert rd_addr == 10 "e16 neg-stride store at offset -12 writes x10"
.assert rd_wdata == 0x5432 "e16 neg-stride store at offset -12"
.4byte 0xfee9d503  # lhu a0, -18(s3)
.assert rd_addr == 10 "e16 neg-stride store at offset -18 writes x10"
.assert rd_wdata == 0x5444 "e16 neg-stride store at offset -18"
.4byte 0xffe9d503  # lhu a0, -2(s3)
.assert rd_addr == 10 "e16 neg-stride store at offset -2 writes x10"
.assert rd_wdata == 0x5aaa "e16 neg-stride store at offset -2"
.4byte 0x0069d503  # lhu a0, 6(s3)
.assert rd_addr == 10 "e16 neg-stride store at offset 6 writes x10"
.assert rd_wdata == 0x5bbb "e16 neg-stride store at offset 6"

# Masked negative-stride EEW 32 vl=3 stride=-12.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x44556337  # lui t1, 0x44556
.4byte 0x67730313  # addi t1, t1, 1655
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x13572337  # lui t1, 0x13572
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x00692023  # sw t1, 0(s2)
.4byte 0x24681337  # lui t1, 0x24681
.4byte 0x35730313  # addi t1, t1, 855
.4byte 0xfe692a23  # sw t1, -12(s2)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9abcefb7  # lui t6, 0x9abce
.4byte 0xef0f8f93  # addi t6, t6, -272
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0xfe692423  # sw t1, -24(s2)
.4byte 0x33334337  # lui t1, 0x33334
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0xfc692e23  # sw t1, -36(s2)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0xfe692e23  # sw t1, -4(s2)
.4byte 0x55556337  # lui t1, 0x55556
.4byte 0x66630313  # addi t1, t1, 1638
.4byte 0x00692623  # sw t1, 12(s2)
.4byte 0x77779337  # lui t1, 0x77779
.4byte 0x88830313  # addi t1, t1, -1912
.4byte 0x00692c23  # sw t1, 24(s2)
.4byte 0xff400e93  # addi t4, zero, -12
.4byte 0x09d96407  # vlse32.v v8, (s2), t4, v0.t
.assert trap == 0 "vlse32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 neg-stride lane 0 writes x10"
.assert rd_wdata == 0x13572468 "e32 neg-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 neg-stride lane 1 writes x10"
.assert rd_wdata == 0x44556677 "e32 neg-stride lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 neg-stride lane 2 writes x10"
.assert rd_wdata == 0xffffffff9abcdef0 "e32 neg-stride lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 neg-stride lane 3 writes x10"
.assert rd_wdata == 0x44556677 "e32 neg-stride lane 3"
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x0069a023  # sw t1, 0(s3)
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0xfe69aa23  # sw t1, -12(s3)
.4byte 0x63000337  # lui t1, 0x63000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0xfe69a423  # sw t1, -24(s3)
.4byte 0x64000337  # lui t1, 0x64000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0xfc69ae23  # sw t1, -36(s3)
.4byte 0x6aaab337  # lui t1, 0x6aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0xfe69ae23  # sw t1, -4(s3)
.4byte 0x6bbbc337  # lui t1, 0x6bbbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x0069a623  # sw t1, 12(s3)
.4byte 0x09d9e427  # vsse32.v v8, (s3), t4, v0.t
.assert trap == 0 "vsse32.v retires"
.4byte 0x0009e503  # lwu a0, 0(s3)
.assert rd_addr == 10 "e32 neg-stride store at offset 0 writes x10"
.assert rd_wdata == 0x13572468 "e32 neg-stride store at offset 0"
.4byte 0xff49e503  # lwu a0, -12(s3)
.assert rd_addr == 10 "e32 neg-stride store at offset -12 writes x10"
.assert rd_wdata == 0x62000002 "e32 neg-stride store at offset -12"
.4byte 0xfe89e503  # lwu a0, -24(s3)
.assert rd_addr == 10 "e32 neg-stride store at offset -24 writes x10"
.assert rd_wdata == 0x9abcdef0 "e32 neg-stride store at offset -24"
.4byte 0xfdc9e503  # lwu a0, -36(s3)
.assert rd_addr == 10 "e32 neg-stride store at offset -36 writes x10"
.assert rd_wdata == 0x64000004 "e32 neg-stride store at offset -36"
.4byte 0xffc9e503  # lwu a0, -4(s3)
.assert rd_addr == 10 "e32 neg-stride store at offset -4 writes x10"
.assert rd_wdata == 0x6aaaaaaa "e32 neg-stride store at offset -4"
.4byte 0x00c9e503  # lwu a0, 12(s3)
.assert rd_addr == 10 "e32 neg-stride store at offset 12 writes x10"
.assert rd_wdata == 0x6bbbbbbb "e32 neg-stride store at offset 12"

# Unmasked negative-stride EEW 64 vl=2 stride=-16.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x4a5b7337  # lui t1, 0x4a5b7
.4byte 0xc7d30313  # addi t1, t1, -899
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x8e9fafb7  # lui t6, 0x8e9fa
.4byte 0x0b1f8f93  # addi t6, t6, 177
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x55667fb7  # lui t6, 0x55667
.4byte 0x788f8f93  # addi t6, t6, 1928
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693023  # sd t1, 0(s2)
.4byte 0x99aac337  # lui t1, 0x99aac
.4byte 0xbcc30313  # addi t1, t1, -1076
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xddef0fb7  # lui t6, 0xddef0
.4byte 0xf00f8f93  # addi t6, t6, -256
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0xfe693823  # sd t1, -16(s2)
.4byte 0x10102337  # lui t1, 0x10102
.4byte 0x02030313  # addi t1, t1, 32
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x30304fb7  # lui t6, 0x30304
.4byte 0x040f8f93  # addi t6, t6, 64
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0xfe693023  # sd t1, -32(s2)
.4byte 0xeeeef337  # lui t1, 0xeeeef
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0xfe693c23  # sd t1, -8(s2)
.4byte 0x50506337  # lui t1, 0x50506
.4byte 0x06030313  # addi t1, t1, 96
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x70708fb7  # lui t6, 0x70708
.4byte 0x080f8f93  # addi t6, t6, 128
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693823  # sd t1, 16(s2)
.4byte 0xff000e93  # addi t4, zero, -16
.4byte 0x0bd97407  # vlse64.v v8, (s2), t4
.assert trap == 0 "vlse64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 neg-stride lane 0 writes x10"
.assert rd_wdata == 0x1122334455667788 "e64 neg-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 neg-stride lane 1 writes x10"
.assert rd_wdata == 0x99aabbccddeeff00 "e64 neg-stride lane 1"
.4byte 0x31111337  # lui t1, 0x31111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b023  # sd t1, 0(s3)
.4byte 0x32222337  # lui t1, 0x32222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0xfe69b823  # sd t1, -16(s3)
.4byte 0x33333337  # lui t1, 0x33333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33333fb7  # lui t6, 0x33333
.4byte 0x333f8f93  # addi t6, t6, 819
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0xfe69b023  # sd t1, -32(s3)
.4byte 0x3aaab337  # lui t1, 0x3aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0xfe69bc23  # sd t1, -8(s3)
.4byte 0x3bbbc337  # lui t1, 0x3bbbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xbbbbcfb7  # lui t6, 0xbbbbc
.4byte 0xbbbf8f93  # addi t6, t6, -1093
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b823  # sd t1, 16(s3)
.4byte 0x0bd9f427  # vsse64.v v8, (s3), t4
.assert trap == 0 "vsse64.v retires"
.4byte 0x0009b503  # ld a0, 0(s3)
.assert rd_addr == 10 "e64 neg-stride store at offset 0 writes x10"
.assert rd_wdata == 0x1122334455667788 "e64 neg-stride store at offset 0"
.4byte 0xff09b503  # ld a0, -16(s3)
.assert rd_addr == 10 "e64 neg-stride store at offset -16 writes x10"
.assert rd_wdata == 0x99aabbccddeeff00 "e64 neg-stride store at offset -16"
.4byte 0xfe09b503  # ld a0, -32(s3)
.assert rd_addr == 10 "e64 neg-stride store at offset -32 writes x10"
.assert rd_wdata == 0x3333333333333333 "e64 neg-stride store at offset -32"
.4byte 0xff89b503  # ld a0, -8(s3)
.assert rd_addr == 10 "e64 neg-stride store at offset -8 writes x10"
.assert rd_wdata == 0x3aaaaaaaaaaaaaaa "e64 neg-stride store at offset -8"
.4byte 0x0109b503  # ld a0, 16(s3)
.assert rd_addr == 10 "e64 neg-stride store at offset 16 writes x10"
.assert rd_wdata == 0x3bbbbbbbbbbbbbbb "e64 neg-stride store at offset 16"

# Zero stride via rs2=zero repeats element zero across active lanes.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0d500313  # addi t1, zero, 213
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x09900313  # addi t1, zero, 153
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x0a040407  # vlse8.v v8, (s0), zero
.assert trap == 0 "vlse8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 zero-stride(x0) lane 0 writes x10"
.assert rd_wdata == 0x42 "e8 zero-stride(x0) lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 zero-stride(x0) lane 1 writes x10"
.assert rd_wdata == 0x42 "e8 zero-stride(x0) lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 zero-stride(x0) lane 2 writes x10"
.assert rd_wdata == 0x42 "e8 zero-stride(x0) lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 zero-stride(x0) tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffd5 "e8 zero-stride(x0) tail lane 3"
.4byte 0x0e100313  # addi t1, zero, 225
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x0e200313  # addi t1, zero, 226
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x0a048427  # vsse8.v v8, (s1), zero
.assert trap == 0 "vsse8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 zero-stride(x0) store at offset 0 writes x10"
.assert rd_wdata == 0x42 "e8 zero-stride(x0) store at offset 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "e8 zero-stride(x0) store at offset 1 writes x10"
.assert rd_wdata == 0xe2 "e8 zero-stride(x0) store at offset 1"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x87654fb7  # lui t6, 0x87654
.4byte 0x321f8f93  # addi t6, t6, 801
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x11111337  # lui t1, 0x11111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x0a046407  # vlse32.v v8, (s0), zero
.assert trap == 0 "vlse32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 zero-stride(x0) lane 0 writes x10"
.assert rd_wdata == 0xffffffff87654321 "e32 zero-stride(x0) lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 zero-stride(x0) lane 1 writes x10"
.assert rd_wdata == 0xffffffff87654321 "e32 zero-stride(x0) lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 zero-stride(x0) lane 2 writes x10"
.assert rd_wdata == 0xffffffff87654321 "e32 zero-stride(x0) lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 zero-stride(x0) tail lane 3 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "e32 zero-stride(x0) tail lane 3"
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x0a04e427  # vsse32.v v8, (s1), zero
.assert trap == 0 "vsse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 zero-stride(x0) store at offset 0 writes x10"
.assert rd_wdata == 0x87654321 "e32 zero-stride(x0) store at offset 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 zero-stride(x0) store at offset 4 writes x10"
.assert rd_wdata == 0x70000002 "e32 zero-stride(x0) store at offset 4"

# Zero stride via register t4=0 repeats element zero across active lanes.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00004337  # lui t1, 0x4
.4byte 0xa3a30313  # addi t1, t1, -1478
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0xbc230313  # addi t1, t1, -1086
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x23430313  # addi t1, t1, 564
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x00000e93  # addi t4, zero, 0
.4byte 0x0bd45407  # vlse16.v v8, (s0), t4
.assert trap == 0 "vlse16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 zero-stride(t4) lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff9bc2 "e16 zero-stride(t4) lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 zero-stride(t4) lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff9bc2 "e16 zero-stride(t4) lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 zero-stride(t4) lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff9bc2 "e16 zero-stride(t4) lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 zero-stride(t4) tail lane 3 writes x10"
.assert rd_wdata == 0x3a3a "e16 zero-stride(t4) tail lane 3"
.4byte 0x00004337  # lui t1, 0x4
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x0bd4d427  # vsse16.v v8, (s1), t4
.assert trap == 0 "vsse16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 zero-stride(t4) store at offset 0 writes x10"
.assert rd_wdata == 0x9bc2 "e16 zero-stride(t4) store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 zero-stride(t4) store at offset 2 writes x10"
.assert rd_wdata == 0x5555 "e16 zero-stride(t4) store at offset 2"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x55667fb7  # lui t6, 0x55667
.4byte 0x788f8f93  # addi t6, t6, 1928
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0xa1b2c337  # lui t1, 0xa1b2c
.4byte 0x3d430313  # addi t1, t1, 980
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xe5f60fb7  # lui t6, 0xe5f60
.4byte 0x718f8f93  # addi t6, t6, 1816
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x09091337  # lui t1, 0x9091
.4byte 0x90930313  # addi t1, t1, -1783
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x09091fb7  # lui t6, 0x9091
.4byte 0x909f8f93  # addi t6, t6, -1783
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x00000e93  # addi t4, zero, 0
.4byte 0x0bd47407  # vlse64.v v8, (s0), t4
.assert trap == 0 "vlse64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 zero-stride(t4) lane 0 writes x10"
.assert rd_wdata == 0xa1b2c3d4e5f60718 "e64 zero-stride(t4) lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 zero-stride(t4) lane 1 writes x10"
.assert rd_wdata == 0xa1b2c3d4e5f60718 "e64 zero-stride(t4) lane 1"
.4byte 0x22222337  # lui t1, 0x22222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x33333337  # lui t1, 0x33333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33333fb7  # lui t6, 0x33333
.4byte 0x333f8f93  # addi t6, t6, 819
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0bd4f427  # vsse64.v v8, (s1), t4
.assert trap == 0 "vsse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 zero-stride(t4) store at offset 0 writes x10"
.assert rd_wdata == 0xa1b2c3d4e5f60718 "e64 zero-stride(t4) store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 zero-stride(t4) store at offset 8 writes x10"
.assert rd_wdata == 0x3333333333333333 "e64 zero-stride(t4) store at offset 8"

# Masked zero stride with lane zero disabled writes only enabled lane one.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x6b6b7337  # lui t1, 0x6b6b7
.4byte 0xb6b30313  # addi t1, t1, -1173
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x13572337  # lui t1, 0x13572
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9999afb7  # lui t6, 0x9999a
.4byte 0x999f8f93  # addi t6, t6, -1639
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x08046407  # vlse32.v v8, (s0), zero, v0.t
.assert trap == 0 "vlse32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked zero-stride disabled lane 0 writes x10"
.assert rd_wdata == 0x6b6b6b6b "masked zero-stride disabled lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "masked zero-stride enabled lane 1 writes x10"
.assert rd_wdata == 0x13572468 "masked zero-stride enabled lane 1"
.4byte 0x77777337  # lui t1, 0x77777
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x88889fb7  # lui t6, 0x88889
.4byte 0x888f8f93  # addi t6, t6, -1912
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x0804e427  # vsse32.v v8, (s1), zero, v0.t
.assert trap == 0 "vsse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "masked zero-stride store at offset 0 writes x10"
.assert rd_wdata == 0x13572468 "masked zero-stride store at offset 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "masked zero-stride store at offset 4 writes x10"
.assert rd_wdata == 0x88888888 "masked zero-stride store at offset 4"

# Stride equal to element size across all four element widths.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x07a00313  # addi t1, zero, 122
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x02100313  # addi t1, zero, 33
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x08300313  # addi t1, zero, 131
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x04500313  # addi t1, zero, 69
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x06700313  # addi t1, zero, 103
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x00100e93  # addi t4, zero, 1
.4byte 0x0bd40407  # vlse8.v v8, (s0), t4
.assert trap == 0 "vlse8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 eq-stride lane 0 writes x10"
.assert rd_wdata == 0x21 "e8 eq-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 eq-stride lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff83 "e8 eq-stride lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 eq-stride lane 2 writes x10"
.assert rd_wdata == 0x45 "e8 eq-stride lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 eq-stride tail lane 3 writes x10"
.assert rd_wdata == 0x7a "e8 eq-stride tail lane 3"
.4byte 0x0a100313  # addi t1, zero, 161
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x0a200313  # addi t1, zero, 162
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x0a300313  # addi t1, zero, 163
.4byte 0x00648123  # sb t1, 2(s1)
.4byte 0x0a400313  # addi t1, zero, 164
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x0bd48427  # vsse8.v v8, (s1), t4
.assert trap == 0 "vsse8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 eq-stride store at offset 0 writes x10"
.assert rd_wdata == 0x21 "e8 eq-stride store at offset 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "e8 eq-stride store at offset 1 writes x10"
.assert rd_wdata == 0x83 "e8 eq-stride store at offset 1"
.4byte 0x0024c503  # lbu a0, 2(s1)
.assert rd_addr == 10 "e8 eq-stride store at offset 2 writes x10"
.assert rd_wdata == 0x45 "e8 eq-stride store at offset 2"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "e8 eq-stride store at offset 3 writes x10"
.assert rd_wdata == 0xa4 "e8 eq-stride store at offset 3"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xa7a30313  # addi t1, t1, -1414
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x34130313  # addi t1, t1, 833
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x00009337  # lui t1, 0x9
.4byte 0x9ab30313  # addi t1, t1, -1621
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x00004337  # lui t1, 0x4
.4byte 0x56730313  # addi t1, t1, 1383
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x00200e93  # addi t4, zero, 2
.4byte 0x0bd45407  # vlse16.v v8, (s0), t4
.assert trap == 0 "vlse16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 eq-stride lane 0 writes x10"
.assert rd_wdata == 0x2341 "e16 eq-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 eq-stride lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff89ab "e16 eq-stride lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 eq-stride lane 2 writes x10"
.assert rd_wdata == 0x4567 "e16 eq-stride lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 eq-stride tail lane 3 writes x10"
.assert rd_wdata == 0x7a7a "e16 eq-stride tail lane 3"
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x0bd4d427  # vsse16.v v8, (s1), t4
.assert trap == 0 "vsse16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 eq-stride store at offset 0 writes x10"
.assert rd_wdata == 0x2341 "e16 eq-stride store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 eq-stride store at offset 2 writes x10"
.assert rd_wdata == 0x89ab "e16 eq-stride store at offset 2"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "e16 eq-stride store at offset 4 writes x10"
.assert rd_wdata == 0x4567 "e16 eq-stride store at offset 4"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "e16 eq-stride store at offset 6 writes x10"
.assert rd_wdata == 0xb444 "e16 eq-stride store at offset 6"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x7a7a8337  # lui t1, 0x7a7a8
.4byte 0xa7a30313  # addi t1, t1, -1414
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x88776fb7  # lui t6, 0x88776
.4byte 0x655f8f93  # addi t6, t6, 1621
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x55443337  # lui t1, 0x55443
.4byte 0x32230313  # addi t1, t1, 802
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x00400e93  # addi t4, zero, 4
.4byte 0x0bd46407  # vlse32.v v8, (s0), t4
.assert trap == 0 "vlse32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 eq-stride lane 0 writes x10"
.assert rd_wdata == 0x11223344 "e32 eq-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 eq-stride lane 1 writes x10"
.assert rd_wdata == 0xffffffff88776655 "e32 eq-stride lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 eq-stride tail lane 2 writes x10"
.assert rd_wdata == 0x7a7a7a7a "e32 eq-stride tail lane 2"
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xc1111fb7  # lui t6, 0xc1111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xc2222fb7  # lui t6, 0xc2222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xc3333fb7  # lui t6, 0xc3333
.4byte 0x333f8f93  # addi t6, t6, 819
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x0bd4e427  # vsse32.v v8, (s1), t4
.assert trap == 0 "vsse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 eq-stride store at offset 0 writes x10"
.assert rd_wdata == 0x11223344 "e32 eq-stride store at offset 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 eq-stride store at offset 4 writes x10"
.assert rd_wdata == 0x88776655 "e32 eq-stride store at offset 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "e32 eq-stride store at offset 8 writes x10"
.assert rd_wdata == 0xc3333333 "e32 eq-stride store at offset 8"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x7a7a8337  # lui t1, 0x7a7a8
.4byte 0xa7a30313  # addi t1, t1, -1414
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x7a7a8fb7  # lui t6, 0x7a7a8
.4byte 0xa7af8f93  # addi t6, t6, -1414
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x12340337  # lui t1, 0x12340
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x56780fb7  # lui t6, 0x56780
.4byte 0x001f8f93  # addi t6, t6, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x87650337  # lui t1, 0x87650
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x43210fb7  # lui t6, 0x43210
.4byte 0x002f8f93  # addi t6, t6, 2
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x00800e93  # addi t4, zero, 8
.4byte 0x0bd47407  # vlse64.v v8, (s0), t4
.assert trap == 0 "vlse64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 eq-stride lane 0 writes x10"
.assert rd_wdata == 0x1234000056780001 "e64 eq-stride lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 eq-stride lane 1 writes x10"
.assert rd_wdata == 0x8765000043210002 "e64 eq-stride lane 1"
.4byte 0xd1111337  # lui t1, 0xd1111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0xd2222337  # lui t1, 0xd2222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0xd3333337  # lui t1, 0xd3333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33333fb7  # lui t6, 0x33333
.4byte 0x333f8f93  # addi t6, t6, 819
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0bd4f427  # vsse64.v v8, (s1), t4
.assert trap == 0 "vsse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 eq-stride store at offset 0 writes x10"
.assert rd_wdata == 0x1234000056780001 "e64 eq-stride store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 eq-stride store at offset 8 writes x10"
.assert rd_wdata == 0x8765000043210002 "e64 eq-stride store at offset 8"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 eq-stride store at offset 16 writes x10"
.assert rd_wdata == 0xd333333333333333 "e64 eq-stride store at offset 16"

# Masked strided load under ta, ma observes only the enabled element.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0xcd017657  # vsetivli a2, 2, e32, m1, ta, ma
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x3579c337  # lui t1, 0x3579c
.4byte 0xdf130313  # addi t1, t1, -527
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x2468b337  # lui t1, 0x2468b
.4byte 0xce030313  # addi t1, t1, -800
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x00800e93  # addi t4, zero, 8
.4byte 0x09d46407  # vlse32.v v8, (s0), t4, v0.t
.assert trap == 0 "vlse32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "ta, ma enabled element zero writes x10"
.assert rd_wdata == 0x3579bdf1 "ta, ma enabled element zero"

# Full-VLMAX strided transfers across all four widths and VLENs.
.4byte 0x17161337  # lui t1, 0x17161
.4byte 0x51430313  # addi t1, t1, 1300
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x13121fb7  # lui t6, 0x13121
.4byte 0x110f8f93  # addi t6, t6, 272
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x1f1e2337  # lui t1, 0x1f1e2
.4byte 0xd1c30313  # addi t1, t1, -740
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x1b1a2fb7  # lui t6, 0x1b1a2
.4byte 0x918f8f93  # addi t6, t6, -1768
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x27262337  # lui t1, 0x27262
.4byte 0x52430313  # addi t1, t1, 1316
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x23222fb7  # lui t6, 0x23222
.4byte 0x120f8f93  # addi t6, t6, 288
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0x2f2e3337  # lui t1, 0x2f2e3
.4byte 0xd2c30313  # addi t1, t1, -724
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x2b2a3fb7  # lui t6, 0x2b2a3
.4byte 0x928f8f93  # addi t6, t6, -1752
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643c23  # sd t1, 24(s0)
.4byte 0x37363337  # lui t1, 0x37363
.4byte 0x53430313  # addi t1, t1, 1332
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33323fb7  # lui t6, 0x33323
.4byte 0x130f8f93  # addi t6, t6, 304
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643023  # sd t1, 32(s0)
.4byte 0x3f3e4337  # lui t1, 0x3f3e4
.4byte 0xd3c30313  # addi t1, t1, -708
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3b3a4fb7  # lui t6, 0x3b3a4
.4byte 0x938f8f93  # addi t6, t6, -1736
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643423  # sd t1, 40(s0)
.4byte 0x47464337  # lui t1, 0x47464
.4byte 0x54430313  # addi t1, t1, 1348
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x43424fb7  # lui t6, 0x43424
.4byte 0x140f8f93  # addi t6, t6, 320
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643823  # sd t1, 48(s0)
.4byte 0x4f4e5337  # lui t1, 0x4f4e5
.4byte 0xd4c30313  # addi t1, t1, -692
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x4b4a5fb7  # lui t6, 0x4b4a5
.4byte 0x948f8f93  # addi t6, t6, -1720
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643c23  # sd t1, 56(s0)
.4byte 0x57565337  # lui t1, 0x57565
.4byte 0x55430313  # addi t1, t1, 1364
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x53525fb7  # lui t6, 0x53525
.4byte 0x150f8f93  # addi t6, t6, 336
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x04643023  # sd t1, 64(s0)
.4byte 0x5f5e6337  # lui t1, 0x5f5e6
.4byte 0xd5c30313  # addi t1, t1, -676
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5b5a6fb7  # lui t6, 0x5b5a6
.4byte 0x958f8f93  # addi t6, t6, -1704
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x04643423  # sd t1, 72(s0)
.4byte 0x67666337  # lui t1, 0x67666
.4byte 0x56430313  # addi t1, t1, 1380
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x63626fb7  # lui t6, 0x63626
.4byte 0x160f8f93  # addi t6, t6, 352
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x04643823  # sd t1, 80(s0)
.4byte 0x6f6e7337  # lui t1, 0x6f6e7
.4byte 0xd6c30313  # addi t1, t1, -660
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x6b6a7fb7  # lui t6, 0x6b6a7
.4byte 0x968f8f93  # addi t6, t6, -1688
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x04643c23  # sd t1, 88(s0)
.4byte 0x77767337  # lui t1, 0x77767
.4byte 0x57430313  # addi t1, t1, 1396
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x73727fb7  # lui t6, 0x73727
.4byte 0x170f8f93  # addi t6, t6, 368
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x06643023  # sd t1, 96(s0)
.4byte 0x7f7e8337  # lui t1, 0x7f7e8
.4byte 0xd7c30313  # addi t1, t1, -644
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x7b7a8fb7  # lui t6, 0x7b7a8
.4byte 0x978f8f93  # addi t6, t6, -1672
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x06643423  # sd t1, 104(s0)
.4byte 0x87868337  # lui t1, 0x87868
.4byte 0x58430313  # addi t1, t1, 1412
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x83828fb7  # lui t6, 0x83828
.4byte 0x180f8f93  # addi t6, t6, 384
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x06643823  # sd t1, 112(s0)
.4byte 0x8f8e9337  # lui t1, 0x8f8e9
.4byte 0xd8c30313  # addi t1, t1, -628
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x8b8a9fb7  # lui t6, 0x8b8a9
.4byte 0x988f8f93  # addi t6, t6, -1656
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x06643c23  # sd t1, 120(s0)

# Full-VLMAX unmasked strided EEW 8 stride=2 load and store.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0a100313  # addi t1, zero, 161
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00007657  # vsetvli a2, zero, e8, m1, tu, mu
.4byte 0x00200e93  # addi t4, zero, 2
.4byte 0x0bd40407  # vlse8.v v8, (s0), t4
.assert trap == 0 "vlse8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 VLMAX strided lane 0 writes x10"
.assert rd_wdata == 0x10 "e8 VLMAX strided lane 0"
.4byte 0xfffe0393  # addi t2, t3, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 VLMAX strided last lane writes x10"
.4byte 0xf1f1f337  # lui t1, 0xf1f1f
.4byte 0x1f130313  # addi t1, t1, 497
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf1f1ffb7  # lui t6, 0xf1f1f
.4byte 0x1f1f8f93  # addi t6, t6, 497
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x0264b423  # sd t1, 40(s1)
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x0264bc23  # sd t1, 56(s1)
.4byte 0x0464b023  # sd t1, 64(s1)
.4byte 0x0464b423  # sd t1, 72(s1)
.4byte 0x0464b823  # sd t1, 80(s1)
.4byte 0x0464bc23  # sd t1, 88(s1)
.4byte 0x0664b023  # sd t1, 96(s1)
.4byte 0x0664b423  # sd t1, 104(s1)
.4byte 0x0664b823  # sd t1, 112(s1)
.4byte 0x0664bc23  # sd t1, 120(s1)
.4byte 0x0864b023  # sd t1, 128(s1)
.4byte 0x0bd48427  # vsse8.v v8, (s1), t4
.assert trap == 0 "vsse8.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e8 VLMAX strided stored dw 0 writes x10"
.assert rd_wdata == 0xf116f114f112f110 "e8 VLMAX strided stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e8 VLMAX strided stored dw 1 writes x10"
.assert rd_wdata == 0xf11ef11cf11af118 "e8 VLMAX strided stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e8 VLMAX strided stored dw 2 writes x10"
.assert rd_wdata == 0xf126f124f122f120 "e8 VLMAX strided stored dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e8 VLMAX strided stored dw 3 writes x10"
.assert rd_wdata == 0xf12ef12cf12af128 "e8 VLMAX strided stored dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "e8 VLMAX strided readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "e8 VLMAX strided untouched guard dw writes x10"
.assert rd_wdata == 0xf1f1f1f1f1f1f1f1 "e8 VLMAX strided untouched guard dw"

# Full-VLMAX unmasked strided EEW 16 stride=4 load and store.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x2a230313  # addi t1, t1, 674
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00807657  # vsetvli a2, zero, e16, m1, tu, mu
.4byte 0x00400e93  # addi t4, zero, 4
.4byte 0x0bd45407  # vlse16.v v8, (s0), t4
.assert trap == 0 "vlse16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 VLMAX strided lane 0 writes x10"
.assert rd_wdata == 0x1110 "e16 VLMAX strided lane 0"
.4byte 0x001e5393  # srli t2, t3, 1
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 VLMAX strided last lane writes x10"
.4byte 0xf2f2f337  # lui t1, 0xf2f2f
.4byte 0x2f230313  # addi t1, t1, 754
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf2f2ffb7  # lui t6, 0xf2f2f
.4byte 0x2f2f8f93  # addi t6, t6, 754
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x0264b423  # sd t1, 40(s1)
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x0264bc23  # sd t1, 56(s1)
.4byte 0x0464b023  # sd t1, 64(s1)
.4byte 0x0464b423  # sd t1, 72(s1)
.4byte 0x0464b823  # sd t1, 80(s1)
.4byte 0x0464bc23  # sd t1, 88(s1)
.4byte 0x0664b023  # sd t1, 96(s1)
.4byte 0x0664b423  # sd t1, 104(s1)
.4byte 0x0664b823  # sd t1, 112(s1)
.4byte 0x0664bc23  # sd t1, 120(s1)
.4byte 0x0864b023  # sd t1, 128(s1)
.4byte 0x0bd4d427  # vsse16.v v8, (s1), t4
.assert trap == 0 "vsse16.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e16 VLMAX strided stored dw 0 writes x10"
.assert rd_wdata == 0xf2f21514f2f21110 "e16 VLMAX strided stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e16 VLMAX strided stored dw 1 writes x10"
.assert rd_wdata == 0xf2f21d1cf2f21918 "e16 VLMAX strided stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e16 VLMAX strided stored dw 2 writes x10"
.assert rd_wdata == 0xf2f22524f2f22120 "e16 VLMAX strided stored dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e16 VLMAX strided stored dw 3 writes x10"
.assert rd_wdata == 0xf2f22d2cf2f22928 "e16 VLMAX strided stored dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "e16 VLMAX strided readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "e16 VLMAX strided untouched guard dw writes x10"
.assert rd_wdata == 0xf2f2f2f2f2f2f2f2 "e16 VLMAX strided untouched guard dw"

# Full-VLMAX unmasked strided EEW 32 stride=8 load and store.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa3a3afb7  # lui t6, 0xa3a3a
.4byte 0x3a3f8f93  # addi t6, t6, 931
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x00800e93  # addi t4, zero, 8
.4byte 0x0bd46407  # vlse32.v v8, (s0), t4
.assert trap == 0 "vlse32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 VLMAX strided lane 0 writes x10"
.assert rd_wdata == 0x13121110 "e32 VLMAX strided lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 VLMAX strided last lane writes x10"
.4byte 0xf3f3f337  # lui t1, 0xf3f3f
.4byte 0x3f330313  # addi t1, t1, 1011
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf3f3ffb7  # lui t6, 0xf3f3f
.4byte 0x3f3f8f93  # addi t6, t6, 1011
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x0264b423  # sd t1, 40(s1)
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x0264bc23  # sd t1, 56(s1)
.4byte 0x0464b023  # sd t1, 64(s1)
.4byte 0x0464b423  # sd t1, 72(s1)
.4byte 0x0464b823  # sd t1, 80(s1)
.4byte 0x0464bc23  # sd t1, 88(s1)
.4byte 0x0664b023  # sd t1, 96(s1)
.4byte 0x0664b423  # sd t1, 104(s1)
.4byte 0x0664b823  # sd t1, 112(s1)
.4byte 0x0664bc23  # sd t1, 120(s1)
.4byte 0x0864b023  # sd t1, 128(s1)
.4byte 0x0bd4e427  # vsse32.v v8, (s1), t4
.assert trap == 0 "vsse32.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e32 VLMAX strided stored dw 0 writes x10"
.assert rd_wdata == 0xf3f3f3f313121110 "e32 VLMAX strided stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e32 VLMAX strided stored dw 1 writes x10"
.assert rd_wdata == 0xf3f3f3f31b1a1918 "e32 VLMAX strided stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e32 VLMAX strided stored dw 2 writes x10"
.assert rd_wdata == 0xf3f3f3f323222120 "e32 VLMAX strided stored dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e32 VLMAX strided stored dw 3 writes x10"
.assert rd_wdata == 0xf3f3f3f32b2a2928 "e32 VLMAX strided stored dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "e32 VLMAX strided readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "e32 VLMAX strided untouched guard dw writes x10"
.assert rd_wdata == 0xf3f3f3f3f3f3f3f3 "e32 VLMAX strided untouched guard dw"

# Full-VLMAX unmasked strided EEW 64 stride=16 load and store.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0xa4a4a337  # lui t1, 0xa4a4a
.4byte 0x4a430313  # addi t1, t1, 1188
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa4a4afb7  # lui t6, 0xa4a4a
.4byte 0x4a4f8f93  # addi t6, t6, 1188
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x0bd47407  # vlse64.v v8, (s0), t4
.assert trap == 0 "vlse64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 VLMAX strided lane 0 writes x10"
.assert rd_wdata == 0x1716151413121110 "e64 VLMAX strided lane 0"
.4byte 0x003e5393  # srli t2, t3, 3
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 VLMAX strided last lane writes x10"
.4byte 0xf4f4f337  # lui t1, 0xf4f4f
.4byte 0x4f430313  # addi t1, t1, 1268
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf4f4ffb7  # lui t6, 0xf4f4f
.4byte 0x4f4f8f93  # addi t6, t6, 1268
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x0264b423  # sd t1, 40(s1)
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x0264bc23  # sd t1, 56(s1)
.4byte 0x0464b023  # sd t1, 64(s1)
.4byte 0x0464b423  # sd t1, 72(s1)
.4byte 0x0464b823  # sd t1, 80(s1)
.4byte 0x0464bc23  # sd t1, 88(s1)
.4byte 0x0664b023  # sd t1, 96(s1)
.4byte 0x0664b423  # sd t1, 104(s1)
.4byte 0x0664b823  # sd t1, 112(s1)
.4byte 0x0664bc23  # sd t1, 120(s1)
.4byte 0x0864b023  # sd t1, 128(s1)
.4byte 0x0bd4f427  # vsse64.v v8, (s1), t4
.assert trap == 0 "vsse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 VLMAX strided stored dw 0 writes x10"
.assert rd_wdata == 0x1716151413121110 "e64 VLMAX strided stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 VLMAX strided stored dw 1 writes x10"
.assert rd_wdata == 0xf4f4f4f4f4f4f4f4 "e64 VLMAX strided stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 VLMAX strided stored dw 2 writes x10"
.assert rd_wdata == 0x2726252423222120 "e64 VLMAX strided stored dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e64 VLMAX strided stored dw 3 writes x10"
.assert rd_wdata == 0xf4f4f4f4f4f4f4f4 "e64 VLMAX strided stored dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "e64 VLMAX strided readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "e64 VLMAX strided untouched guard dw writes x10"
.assert rd_wdata == 0xf4f4f4f4f4f4f4f4 "e64 VLMAX strided untouched guard dw"

# Full-VLMAX masked strided EEW 32 stride=8 load and store.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x0000a2b7  # lui t0, 0xa
.4byte 0x55a28293  # addi t0, t0, 1370
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x55aa5337  # lui t1, 0x55aa5
.4byte 0x5aa30313  # addi t1, t1, 1450
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x00800e93  # addi t4, zero, 8
.4byte 0x09d46407  # vlse32.v v8, (s0), t4, v0.t
.assert trap == 0 "vlse32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX masked strided e32 disabled lane 0 writes x10"
.assert rd_wdata == 0x55aa55aa "VLMAX masked strided e32 disabled lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX masked strided e32 enabled lane 1 writes x10"
.assert rd_wdata == 0x1b1a1918 "VLMAX masked strided e32 enabled lane 1"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX masked strided e32 last lane writes x10"
.4byte 0xf5f5f337  # lui t1, 0xf5f5f
.4byte 0x5f530313  # addi t1, t1, 1525
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf5f5ffb7  # lui t6, 0xf5f5f
.4byte 0x5f5f8f93  # addi t6, t6, 1525
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x0264b423  # sd t1, 40(s1)
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x0264bc23  # sd t1, 56(s1)
.4byte 0x0464b023  # sd t1, 64(s1)
.4byte 0x0464b423  # sd t1, 72(s1)
.4byte 0x0464b823  # sd t1, 80(s1)
.4byte 0x0464bc23  # sd t1, 88(s1)
.4byte 0x0664b023  # sd t1, 96(s1)
.4byte 0x0664b423  # sd t1, 104(s1)
.4byte 0x0664b823  # sd t1, 112(s1)
.4byte 0x0664bc23  # sd t1, 120(s1)
.4byte 0x0864b023  # sd t1, 128(s1)
.4byte 0x09d4e427  # vsse32.v v8, (s1), t4, v0.t
.assert trap == 0 "vsse32.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 disabled dw 0 writes x10"
.assert rd_wdata == 0xf5f5f5f5f5f5f5f5 "VLMAX masked strided e32 disabled dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 enabled dw 1 writes x10"
.assert rd_wdata == 0xf5f5f5f51b1a1918 "VLMAX masked strided e32 enabled dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 disabled dw 2 writes x10"
.assert rd_wdata == 0xf5f5f5f5f5f5f5f5 "VLMAX masked strided e32 disabled dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 enabled dw 3 writes x10"
.assert rd_wdata == 0xf5f5f5f52b2a2928 "VLMAX masked strided e32 enabled dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "VLMAX masked strided e32 untouched guard dw writes x10"
.assert rd_wdata == 0xf5f5f5f5f5f5f5f5 "VLMAX masked strided e32 untouched guard dw"

# Full-VLMAX negative-stride EEW 64 stride=-16 load and store.
.4byte 0x07040913  # addi s2, s0, 112
.4byte 0x07048993  # addi s3, s1, 112
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0xa6a6a337  # lui t1, 0xa6a6a
.4byte 0x6a630313  # addi t1, t1, 1702
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa6a6afb7  # lui t6, 0xa6a6a
.4byte 0x6a6f8f93  # addi t6, t6, 1702
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0xff000e93  # addi t4, zero, -16
.4byte 0x0bd97407  # vlse64.v v8, (s2), t4
.assert trap == 0 "vlse64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX neg-stride e64 lane 0 writes x10"
.assert rd_wdata == 0x8786858483828180 "VLMAX neg-stride e64 lane 0"
.4byte 0x003e5393  # srli t2, t3, 3
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX neg-stride e64 last lane writes x10"
.4byte 0xf6f6f337  # lui t1, 0xf6f6f
.4byte 0x6f630313  # addi t1, t1, 1782
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf6f6ffb7  # lui t6, 0xf6f6f
.4byte 0x6f6f8f93  # addi t6, t6, 1782
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x0264b423  # sd t1, 40(s1)
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x0264bc23  # sd t1, 56(s1)
.4byte 0x0464b023  # sd t1, 64(s1)
.4byte 0x0464b423  # sd t1, 72(s1)
.4byte 0x0464b823  # sd t1, 80(s1)
.4byte 0x0464bc23  # sd t1, 88(s1)
.4byte 0x0664b023  # sd t1, 96(s1)
.4byte 0x0664b423  # sd t1, 104(s1)
.4byte 0x0664b823  # sd t1, 112(s1)
.4byte 0x0664bc23  # sd t1, 120(s1)
.4byte 0x0864b023  # sd t1, 128(s1)
.4byte 0x0bd9f427  # vsse64.v v8, (s3), t4
.assert trap == 0 "vsse64.v retires"
.4byte 0x0009b503  # ld a0, 0(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 stored elem 0 writes x10"
.assert rd_wdata == 0x8786858483828180 "VLMAX neg-stride e64 stored elem 0"
.4byte 0xff09b503  # ld a0, -16(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 stored elem 1 writes x10"
.assert rd_wdata == 0x7776757473727170 "VLMAX neg-stride e64 stored elem 1"
.4byte 0xfe09b503  # ld a0, -32(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 readback elem 2 writes x10"
.4byte 0xfd09b503  # ld a0, -48(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 readback elem 3 writes x10"
.4byte 0xfc09b503  # ld a0, -64(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 readback elem 4 writes x10"
.4byte 0xfb09b503  # ld a0, -80(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 readback elem 5 writes x10"
.4byte 0xfa09b503  # ld a0, -96(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 readback elem 6 writes x10"
.4byte 0xf909b503  # ld a0, -112(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 readback elem 7 writes x10"
.4byte 0xff89b503  # ld a0, -8(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 untouched gap dw writes x10"
.assert rd_wdata == 0xf6f6f6f6f6f6f6f6 "VLMAX neg-stride e64 untouched gap dw"
.4byte 0x0109b503  # ld a0, 16(s3)
.assert rd_addr == 10 "VLMAX neg-stride e64 untouched above-base guard dw writes x10"
.assert rd_wdata == 0xf6f6f6f6f6f6f6f6 "VLMAX neg-stride e64 untouched above-base guard dw"

# Strided EEW 16 with SEW 32 and LMUL 1 (EMUL=1/2).
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xcafecfb7  # lui t6, 0xcafec
.4byte 0xabef8f93  # addi t6, t6, -1346
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x35730313  # addi t1, t1, 855
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x99930313  # addi t1, t1, -1639
.4byte 0x00641623  # sh t1, 12(s0)
.4byte 0x00600e93  # addi t4, zero, 6
.4byte 0x0bd45407  # vlse16.v v8, (s0), t4
.assert trap == 0 "vlse16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "EMUL=1/2 strided packed halfwords writes x10"
.assert rd_wdata == 0x24681357 "EMUL=1/2 strided packed halfwords"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "EMUL=1/2 strided tail-undisturbed upper word writes x10"
.assert rd_wdata == 0xffffffffcafebabe "EMUL=1/2 strided tail-undisturbed upper word"
.4byte 0x0000d337  # lui t1, 0xd
.4byte 0x1d130313  # addi t1, t1, 465
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x0000e337  # lui t1, 0xe
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x0000d337  # lui t1, 0xd
.4byte 0x2d230313  # addi t1, t1, 722
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x0000d337  # lui t1, 0xd
.4byte 0x3d330313  # addi t1, t1, 979
.4byte 0x00649623  # sh t1, 12(s1)
.4byte 0x0bd4d427  # vsse16.v v8, (s1), t4
.assert trap == 0 "vsse16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "EMUL=1/2 strided store at offset 0 writes x10"
.assert rd_wdata == 0x1357 "EMUL=1/2 strided store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "EMUL=1/2 strided store at offset 2 writes x10"
.assert rd_wdata == 0xdaaa "EMUL=1/2 strided store at offset 2"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "EMUL=1/2 strided store at offset 6 writes x10"
.assert rd_wdata == 0x2468 "EMUL=1/2 strided store at offset 6"
.4byte 0x00c4d503  # lhu a0, 12(s1)
.assert rd_addr == 10 "EMUL=1/2 strided store at offset 12 writes x10"
.assert rd_wdata == 0xd3d3 "EMUL=1/2 strided store at offset 12"

# Zero-length and all-masked-off strided transfers leave state intact.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x0badc337  # lui t1, 0xbadc
.4byte 0x0de30313  # addi t1, t1, 222
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x77777337  # lui t1, 0x77777
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x66666337  # lui t1, 0x66666
.4byte 0x66630313  # addi t1, t1, 1638
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x0 "e32 m1 active vector length"
.4byte 0x00800e93  # addi t4, zero, 8
.4byte 0x0bd46407  # vlse32.v v8, (s0), t4
.assert trap == 0 "vlse32.v retires"
.4byte 0x0bd4e427  # vsse32.v v8, (s1), t4
.assert trap == 0 "vsse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vl=0 strided store leaves memory intact at offset 0 writes x10"
.assert rd_wdata == 0x66666666 "vl=0 strided store leaves memory intact at offset 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x1 "e32 m1 active vector length"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl=0 strided load leaves vector intact writes x10"
.assert rd_wdata == 0xbadc0de "vl=0 strided load leaves vector intact"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x0feee337  # lui t1, 0xfeee
.4byte 0xace30313  # addi t1, t1, -1330
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x77777337  # lui t1, 0x77777
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x88889fb7  # lui t6, 0x88889
.4byte 0x888f8f93  # addi t6, t6, -1912
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x00800e93  # addi t4, zero, 8
.4byte 0x09d46407  # vlse32.v v8, (s0), t4, v0.t
.assert trap == 0 "vlse32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "all-masked strided load lane 0 undisturbed writes x10"
.assert rd_wdata == 0xfeedace "all-masked strided load lane 0 undisturbed"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "all-masked strided load lane 1 undisturbed writes x10"
.assert rd_wdata == 0xfeedace "all-masked strided load lane 1 undisturbed"
.4byte 0x55551337  # lui t1, 0x55551
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x55552337  # lui t1, 0x55552
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x09d4e427  # vsse32.v v8, (s1), t4, v0.t
.assert trap == 0 "vsse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "all-masked strided store intact at offset 0 writes x10"
.assert rd_wdata == 0x55551111 "all-masked strided store intact at offset 0"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "all-masked strided store intact at offset 8 writes x10"
.assert rd_wdata == 0x55552222 "all-masked strided store intact at offset 8"

# Cached DDR strided transfer across a 4 KiB page boundary.
.4byte 0x00000913  # addi s2, zero, 0
.4byte 0x02091913  # slli s2, s2, 32
.4byte 0x80011fb7  # lui t6, 0x80011
.4byte 0xff8f8f93  # addi t6, t6, -8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f96933  # or s2, s2, t6
.4byte 0x00000993  # addi s3, zero, 0
.4byte 0x02099993  # slli s3, s3, 32
.4byte 0x80012fb7  # lui t6, 0x80012
.4byte 0xff8f8f93  # addi t6, t6, -8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f9e9b3  # or s3, s3, t6
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x10203337  # lui t1, 0x10203
.4byte 0x04030313  # addi t1, t1, 64
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x50607fb7  # lui t6, 0x50607
.4byte 0x080f8f93  # addi t6, t6, 128
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x01020337  # lui t1, 0x1020
.4byte 0x30430313  # addi t1, t1, 772
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x05060fb7  # lui t6, 0x5060
.4byte 0x708f8f93  # addi t6, t6, 1800
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693023  # sd t1, 0(s2)
.4byte 0xeeeef337  # lui t1, 0xeeeef
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693423  # sd t1, 8(s2)
.4byte 0x898a9337  # lui t1, 0x898a9
.4byte 0xb8c30313  # addi t1, t1, -1140
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x8d8e9fb7  # lui t6, 0x8d8e9
.4byte 0xf90f8f93  # addi t6, t6, -112
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693823  # sd t1, 16(s2)
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x0bd97407  # vlse64.v v8, (s2), t4
.assert trap == 0 "vlse64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "page-crossing strided load lane 0 writes x10"
.assert rd_wdata == 0x102030405060708 "page-crossing strided load lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing strided load lane 1 writes x10"
.assert rd_wdata == 0x898a8b8c8d8e8f90 "page-crossing strided load lane 1"
.4byte 0x22222337  # lui t1, 0x22222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b023  # sd t1, 0(s3)
.4byte 0x44444337  # lui t1, 0x44444
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x44444fb7  # lui t6, 0x44444
.4byte 0x444f8f93  # addi t6, t6, 1092
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b423  # sd t1, 8(s3)
.4byte 0x33333337  # lui t1, 0x33333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33333fb7  # lui t6, 0x33333
.4byte 0x333f8f93  # addi t6, t6, 819
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b823  # sd t1, 16(s3)
.4byte 0x0bd9f427  # vsse64.v v8, (s3), t4
.assert trap == 0 "vsse64.v retires"
.4byte 0x0009b503  # ld a0, 0(s3)
.assert rd_addr == 10 "page-crossing strided store at offset 0 writes x10"
.assert rd_wdata == 0x102030405060708 "page-crossing strided store at offset 0"
.4byte 0x0089b503  # ld a0, 8(s3)
.assert rd_addr == 10 "page-crossing strided store at offset 8 writes x10"
.assert rd_wdata == 0x4444444444444444 "page-crossing strided store at offset 8"
.4byte 0x0109b503  # ld a0, 16(s3)
.assert rd_addr == 10 "page-crossing strided store at offset 16 writes x10"
.assert rd_wdata == 0x898a8b8c8d8e8f90 "page-crossing strided store at offset 16"
