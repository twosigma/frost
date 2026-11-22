# Indexed vector loads and stores in cached DDR.
.noshrink
# Enable VS and select cached DDR source and destination buffers.
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x40008437  # lui s0, 0x40008
.4byte 0x00141413  # slli s0, s0, 1
.4byte 0x10040413  # addi s0, s0, 256
.4byte 0x20040493  # addi s1, s0, 512
.4byte 0xc2202e73  # csrr t3, vlenb
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0

# Unmasked unordered and ordered indexed EEW 8 vl=3 indices=[132, 0, 128].
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x08400313  # addi t1, zero, 132
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x03100313  # addi t1, zero, 49
.4byte 0x08640223  # sb t1, 132(s0)
.4byte 0x08200313  # addi t1, zero, 130
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x05700313  # addi t1, zero, 87
.4byte 0x08640023  # sb t1, 128(s0)
.4byte 0x0ee00313  # addi t1, zero, 238
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x0ed00313  # addi t1, zero, 237
.4byte 0x086400a3  # sb t1, 129(s0)
.4byte 0x0cc00313  # addi t1, zero, 204
.4byte 0xf8640223  # sb t1, -124(s0)
.4byte 0x0cd00313  # addi t1, zero, 205
.4byte 0xf8640023  # sb t1, -128(s0)
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0a500313  # addi t1, zero, 165
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x07040407  # vluxei8.v v8, (s0), v16
.assert trap == 0 "vluxei8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 ux lane 0 writes x10"
.assert rd_wdata == 0x31 "e8 ux lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 ux lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff82 "e8 ux lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 ux lane 2 writes x10"
.assert rd_wdata == 0x57 "e8 ux lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 ux tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "e8 ux tail lane 3"
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x08648223  # sb t1, 132(s1)
.4byte 0x01200313  # addi t1, zero, 18
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x01300313  # addi t1, zero, 19
.4byte 0x08648023  # sb t1, 128(s1)
.4byte 0x01a00313  # addi t1, zero, 26
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x01b00313  # addi t1, zero, 27
.4byte 0x086480a3  # sb t1, 129(s1)
.4byte 0x07048427  # vsuxei8.v v8, (s1), v16
.assert trap == 0 "vsuxei8.v retires"
.4byte 0x0844c503  # lbu a0, 132(s1)
.assert rd_addr == 10 "e8 ux store at offset 132 writes x10"
.assert rd_wdata == 0x31 "e8 ux store at offset 132"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 ux store at offset 0 writes x10"
.assert rd_wdata == 0x82 "e8 ux store at offset 0"
.4byte 0x0804c503  # lbu a0, 128(s1)
.assert rd_addr == 10 "e8 ux store at offset 128 writes x10"
.assert rd_wdata == 0x57 "e8 ux store at offset 128"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "e8 ux store at offset 1 writes x10"
.assert rd_wdata == 0x1a "e8 ux store at offset 1"
.4byte 0x0814c503  # lbu a0, 129(s1)
.assert rd_addr == 10 "e8 ux store at offset 129 writes x10"
.assert rd_wdata == 0x1b "e8 ux store at offset 129"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0a500313  # addi t1, zero, 165
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x0f040407  # vloxei8.v v8, (s0), v16
.assert trap == 0 "vloxei8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 ox lane 0 writes x10"
.assert rd_wdata == 0x31 "e8 ox lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 ox lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff82 "e8 ox lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 ox lane 2 writes x10"
.assert rd_wdata == 0x57 "e8 ox lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 ox tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "e8 ox tail lane 3"
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x08648223  # sb t1, 132(s1)
.4byte 0x01200313  # addi t1, zero, 18
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x01300313  # addi t1, zero, 19
.4byte 0x08648023  # sb t1, 128(s1)
.4byte 0x01a00313  # addi t1, zero, 26
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x01b00313  # addi t1, zero, 27
.4byte 0x086480a3  # sb t1, 129(s1)
.4byte 0x0f048427  # vsoxei8.v v8, (s1), v16
.assert trap == 0 "vsoxei8.v retires"
.4byte 0x0844c503  # lbu a0, 132(s1)
.assert rd_addr == 10 "e8 ox store at offset 132 writes x10"
.assert rd_wdata == 0x31 "e8 ox store at offset 132"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 ox store at offset 0 writes x10"
.assert rd_wdata == 0x82 "e8 ox store at offset 0"
.4byte 0x0804c503  # lbu a0, 128(s1)
.assert rd_addr == 10 "e8 ox store at offset 128 writes x10"
.assert rd_wdata == 0x57 "e8 ox store at offset 128"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "e8 ox store at offset 1 writes x10"
.assert rd_wdata == 0x1a "e8 ox store at offset 1"
.4byte 0x0814c503  # lbu a0, 129(s1)
.assert rd_addr == 10 "e8 ox store at offset 129 writes x10"
.assert rd_wdata == 0x1b "e8 ox store at offset 129"

# Unmasked unordered and ordered indexed EEW 16 vl=3 indices=[14, 0, 6].
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00600313  # addi t1, zero, 6
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x00e00313  # addi t1, zero, 14
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x23430313  # addi t1, t1, 564
.4byte 0x00641723  # sh t1, 14(s0)
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0xa5b30313  # addi t1, t1, -1445
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x00005337  # lui t1, 0x5
.4byte 0xc3d30313  # addi t1, t1, -963
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x0000e337  # lui t1, 0xe
.4byte 0xddd30313  # addi t1, t1, -547
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x55a30313  # addi t1, t1, 1370
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x07045407  # vluxei16.v v8, (s0), v16
.assert trap == 0 "vluxei16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 ux lane 0 writes x10"
.assert rd_wdata == 0x1234 "e16 ux lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 ux lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff9a5b "e16 ux lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 ux lane 2 writes x10"
.assert rd_wdata == 0x4c3d "e16 ux lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 ux tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffa55a "e16 ux tail lane 3"
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649723  # sh t1, 14(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x00649423  # sh t1, 8(s1)
.4byte 0x0704d427  # vsuxei16.v v8, (s1), v16
.assert trap == 0 "vsuxei16.v retires"
.4byte 0x00e4d503  # lhu a0, 14(s1)
.assert rd_addr == 10 "e16 ux store at offset 14 writes x10"
.assert rd_wdata == 0x1234 "e16 ux store at offset 14"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 ux store at offset 0 writes x10"
.assert rd_wdata == 0x9a5b "e16 ux store at offset 0"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "e16 ux store at offset 6 writes x10"
.assert rd_wdata == 0x4c3d "e16 ux store at offset 6"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 ux store at offset 2 writes x10"
.assert rd_wdata == 0x2aaa "e16 ux store at offset 2"
.4byte 0x0084d503  # lhu a0, 8(s1)
.assert rd_addr == 10 "e16 ux store at offset 8 writes x10"
.assert rd_wdata == 0x2bbb "e16 ux store at offset 8"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x55a30313  # addi t1, t1, 1370
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x0f045407  # vloxei16.v v8, (s0), v16
.assert trap == 0 "vloxei16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 ox lane 0 writes x10"
.assert rd_wdata == 0x1234 "e16 ox lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 ox lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff9a5b "e16 ox lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 ox lane 2 writes x10"
.assert rd_wdata == 0x4c3d "e16 ox lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 ox tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffa55a "e16 ox tail lane 3"
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649723  # sh t1, 14(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x00649423  # sh t1, 8(s1)
.4byte 0x0f04d427  # vsoxei16.v v8, (s1), v16
.assert trap == 0 "vsoxei16.v retires"
.4byte 0x00e4d503  # lhu a0, 14(s1)
.assert rd_addr == 10 "e16 ox store at offset 14 writes x10"
.assert rd_wdata == 0x1234 "e16 ox store at offset 14"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 ox store at offset 0 writes x10"
.assert rd_wdata == 0x9a5b "e16 ox store at offset 0"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "e16 ox store at offset 6 writes x10"
.assert rd_wdata == 0x4c3d "e16 ox store at offset 6"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 ox store at offset 2 writes x10"
.assert rd_wdata == 0x2aaa "e16 ox store at offset 2"
.4byte 0x0084d503  # lhu a0, 8(s1)
.assert rd_addr == 10 "e16 ox store at offset 8 writes x10"
.assert rd_wdata == 0x2bbb "e16 ox store at offset 8"

# Unmasked unordered and ordered indexed EEW 32 vl=2 indices=[20, 4].
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00400313  # addi t1, zero, 4
.4byte 0x5e034c57  # vmv.v.x v24, t1
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x31416337  # lui t1, 0x31416
.4byte 0x92630313  # addi t1, t1, -1754
.4byte 0x00642a23  # sw t1, 20(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9e378fb7  # lui t6, 0x9e378
.4byte 0x9b9f8f93  # addi t6, t6, -1607
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xddddefb7  # lui t6, 0xdddde
.4byte 0xdddf8f93  # addi t6, t6, -547
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034e57  # vmv.v.x v28, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x07046e07  # vluxei32.v v28, (s0), v16
.assert trap == 0 "vluxei32.v retires"
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "e32 ux lane 0 writes x10"
.assert rd_wdata == 0x31415926 "e32 ux lane 0"
.4byte 0x3fc0bc57  # vslidedown.vi v24, v28, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 ux lane 1 writes x10"
.assert rd_wdata == 0xffffffff9e3779b9 "e32 ux lane 1"
.4byte 0x3fc13c57  # vslidedown.vi v24, v28, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 ux tail lane 2 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "e32 ux tail lane 2"
.4byte 0x31111337  # lui t1, 0x31111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x0064aa23  # sw t1, 20(s1)
.4byte 0x32222337  # lui t1, 0x32222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x3aaab337  # lui t1, 0x3aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x3bbbc337  # lui t1, 0x3bbbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x0704ee27  # vsuxei32.v v28, (s1), v16
.assert trap == 0 "vsuxei32.v retires"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "e32 ux store at offset 20 writes x10"
.assert rd_wdata == 0x31415926 "e32 ux store at offset 20"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 ux store at offset 4 writes x10"
.assert rd_wdata == 0x9e3779b9 "e32 ux store at offset 4"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 ux store at offset 0 writes x10"
.assert rd_wdata == 0x3aaaaaaa "e32 ux store at offset 0"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "e32 ux store at offset 8 writes x10"
.assert rd_wdata == 0x3bbbbbbb "e32 ux store at offset 8"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x0f046407  # vloxei32.v v8, (s0), v16
.assert trap == 0 "vloxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 ox lane 0 writes x10"
.assert rd_wdata == 0x31415926 "e32 ox lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 ox lane 1 writes x10"
.assert rd_wdata == 0xffffffff9e3779b9 "e32 ox lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 ox tail lane 2 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "e32 ox tail lane 2"
.4byte 0x31111337  # lui t1, 0x31111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x0064aa23  # sw t1, 20(s1)
.4byte 0x32222337  # lui t1, 0x32222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x3aaab337  # lui t1, 0x3aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x3bbbc337  # lui t1, 0x3bbbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x0f04e427  # vsoxei32.v v8, (s1), v16
.assert trap == 0 "vsoxei32.v retires"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "e32 ox store at offset 20 writes x10"
.assert rd_wdata == 0x31415926 "e32 ox store at offset 20"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 ox store at offset 4 writes x10"
.assert rd_wdata == 0x9e3779b9 "e32 ox store at offset 4"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 ox store at offset 0 writes x10"
.assert rd_wdata == 0x3aaaaaaa "e32 ox store at offset 0"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "e32 ox store at offset 8 writes x10"
.assert rd_wdata == 0x3bbbbbbb "e32 ox store at offset 8"

# Unmasked unordered and ordered indexed EEW 64 vl=1 indices=[16].
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x92345337  # lui t1, 0x92345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x23456fb7  # lui t6, 0x23456
.4byte 0x789f8f93  # addi t6, t6, 1929
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0xeeeef337  # lui t1, 0xeeeef
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0xdddde337  # lui t1, 0xdddde
.4byte 0xddd30313  # addi t1, t1, -547
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xddddefb7  # lui t6, 0xdddde
.4byte 0xdddf8f93  # addi t6, t6, -547
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
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
.4byte 0x07047407  # vluxei64.v v8, (s0), v16
.assert trap == 0 "vluxei64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 ux lane 0 writes x10"
.assert rd_wdata == 0x9234567823456789 "e64 ux lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 ux tail lane 1 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "e64 ux tail lane 1"
.4byte 0x41111337  # lui t1, 0x41111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x4aaab337  # lui t1, 0x4aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x4bbbc337  # lui t1, 0x4bbbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xbbbbcfb7  # lui t6, 0xbbbbc
.4byte 0xbbbf8f93  # addi t6, t6, -1093
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0704f427  # vsuxei64.v v8, (s1), v16
.assert trap == 0 "vsuxei64.v retires"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 ux store at offset 16 writes x10"
.assert rd_wdata == 0x9234567823456789 "e64 ux store at offset 16"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 ux store at offset 0 writes x10"
.assert rd_wdata == 0x4aaaaaaaaaaaaaaa "e64 ux store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 ux store at offset 8 writes x10"
.assert rd_wdata == 0x4bbbbbbbbbbbbbbb "e64 ux store at offset 8"
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
.4byte 0x0f047407  # vloxei64.v v8, (s0), v16
.assert trap == 0 "vloxei64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 ox lane 0 writes x10"
.assert rd_wdata == 0x9234567823456789 "e64 ox lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 ox tail lane 1 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "e64 ox tail lane 1"
.4byte 0x41111337  # lui t1, 0x41111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x4aaab337  # lui t1, 0x4aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x4bbbc337  # lui t1, 0x4bbbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xbbbbcfb7  # lui t6, 0xbbbbc
.4byte 0xbbbf8f93  # addi t6, t6, -1093
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0f04f427  # vsoxei64.v v8, (s1), v16
.assert trap == 0 "vsoxei64.v retires"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 ox store at offset 16 writes x10"
.assert rd_wdata == 0x9234567823456789 "e64 ox store at offset 16"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 ox store at offset 0 writes x10"
.assert rd_wdata == 0x4aaaaaaaaaaaaaaa "e64 ox store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 ox store at offset 8 writes x10"
.assert rd_wdata == 0x4bbbbbbbbbbbbbbb "e64 ox store at offset 8"

# Unmasked unordered and ordered indexed EEW 64 vl=2 indices=[24, 8].
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x5e034c57  # vmv.v.x v24, t1
.4byte 0x01800313  # addi t1, zero, 24
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x55667fb7  # lui t6, 0x55667
.4byte 0x788f8f93  # addi t6, t6, 1928
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643c23  # sd t1, 24(s0)
.4byte 0x99aac337  # lui t1, 0x99aac
.4byte 0xbcc30313  # addi t1, t1, -1076
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xddef0fb7  # lui t6, 0xddef0
.4byte 0xf00f8f93  # addi t6, t6, -256
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0xeeeef337  # lui t1, 0xeeeef
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x4a4a5337  # lui t1, 0x4a4a5
.4byte 0xa4a30313  # addi t1, t1, -1462
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa4a4afb7  # lui t6, 0xa4a4a
.4byte 0x4a4f8f93  # addi t6, t6, 1188
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x07047407  # vluxei64.v v8, (s0), v16
.assert trap == 0 "vluxei64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 ux lane 0 writes x10"
.assert rd_wdata == 0x1122334455667788 "e64 ux lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 ux lane 1 writes x10"
.assert rd_wdata == 0x99aabbccddeeff00 "e64 ux lane 1"
.4byte 0x42111337  # lui t1, 0x42111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x42222337  # lui t1, 0x42222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x42aab337  # lui t1, 0x42aab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x42bbc337  # lui t1, 0x42bbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xbbbbcfb7  # lui t6, 0xbbbbc
.4byte 0xbbbf8f93  # addi t6, t6, -1093
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0704f427  # vsuxei64.v v8, (s1), v16
.assert trap == 0 "vsuxei64.v retires"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e64 ux store at offset 24 writes x10"
.assert rd_wdata == 0x1122334455667788 "e64 ux store at offset 24"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 ux store at offset 8 writes x10"
.assert rd_wdata == 0x99aabbccddeeff00 "e64 ux store at offset 8"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 ux store at offset 0 writes x10"
.assert rd_wdata == 0x42aaaaaaaaaaaaaa "e64 ux store at offset 0"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 ux store at offset 16 writes x10"
.assert rd_wdata == 0x42bbbbbbbbbbbbbb "e64 ux store at offset 16"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x4a4a5337  # lui t1, 0x4a4a5
.4byte 0xa4a30313  # addi t1, t1, -1462
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa4a4afb7  # lui t6, 0xa4a4a
.4byte 0x4a4f8f93  # addi t6, t6, 1188
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x0f047407  # vloxei64.v v8, (s0), v16
.assert trap == 0 "vloxei64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 ox lane 0 writes x10"
.assert rd_wdata == 0x1122334455667788 "e64 ox lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 ox lane 1 writes x10"
.assert rd_wdata == 0x99aabbccddeeff00 "e64 ox lane 1"
.4byte 0x42111337  # lui t1, 0x42111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x42222337  # lui t1, 0x42222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x42aab337  # lui t1, 0x42aab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x42bbc337  # lui t1, 0x42bbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xbbbbcfb7  # lui t6, 0xbbbbc
.4byte 0xbbbf8f93  # addi t6, t6, -1093
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0f04f427  # vsoxei64.v v8, (s1), v16
.assert trap == 0 "vsoxei64.v retires"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e64 ox store at offset 24 writes x10"
.assert rd_wdata == 0x1122334455667788 "e64 ox store at offset 24"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 ox store at offset 8 writes x10"
.assert rd_wdata == 0x99aabbccddeeff00 "e64 ox store at offset 8"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 ox store at offset 0 writes x10"
.assert rd_wdata == 0x42aaaaaaaaaaaaaa "e64 ox store at offset 0"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 ox store at offset 16 writes x10"
.assert rd_wdata == 0x42bbbbbbbbbbbbbb "e64 ox store at offset 16"

# Masked unordered and ordered indexed EEW 8 m1 vl=3 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00400313  # addi t1, zero, 4
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x08400313  # addi t1, zero, 132
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x01500313  # addi t1, zero, 21
.4byte 0x08640223  # sb t1, 132(s0)
.4byte 0x02600313  # addi t1, zero, 38
.4byte 0x00640223  # sb t1, 4(s0)
.4byte 0x09700313  # addi t1, zero, 151
.4byte 0x08640023  # sb t1, 128(s0)
.4byte 0x0ee00313  # addi t1, zero, 238
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0c300313  # addi t1, zero, 195
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x05040407  # vluxei8.v v8, (s0), v16, v0.t
.assert trap == 0 "vluxei8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 m1 ux enabled lane 0 writes x10"
.assert rd_wdata == 0x15 "e8 m1 ux enabled lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 m1 ux masked-off lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "e8 m1 ux masked-off lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 m1 ux enabled lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff97 "e8 m1 ux enabled lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 m1 ux tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "e8 m1 ux tail lane 3"
.4byte 0x05100313  # addi t1, zero, 81
.4byte 0x08648223  # sb t1, 132(s1)
.4byte 0x05200313  # addi t1, zero, 82
.4byte 0x00648223  # sb t1, 4(s1)
.4byte 0x05300313  # addi t1, zero, 83
.4byte 0x08648023  # sb t1, 128(s1)
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x05048427  # vsuxei8.v v8, (s1), v16, v0.t
.assert trap == 0 "vsuxei8.v retires"
.4byte 0x0844c503  # lbu a0, 132(s1)
.assert rd_addr == 10 "e8 m1 masked ux store at offset 132 writes x10"
.assert rd_wdata == 0x15 "e8 m1 masked ux store at offset 132"
.4byte 0x0044c503  # lbu a0, 4(s1)
.assert rd_addr == 10 "e8 m1 masked ux store at offset 4 writes x10"
.assert rd_wdata == 0x52 "e8 m1 masked ux store at offset 4"
.4byte 0x0804c503  # lbu a0, 128(s1)
.assert rd_addr == 10 "e8 m1 masked ux store at offset 128 writes x10"
.assert rd_wdata == 0x97 "e8 m1 masked ux store at offset 128"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 m1 masked ux store at offset 0 writes x10"
.assert rd_wdata == 0x5a "e8 m1 masked ux store at offset 0"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0c300313  # addi t1, zero, 195
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x0d040407  # vloxei8.v v8, (s0), v16, v0.t
.assert trap == 0 "vloxei8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 m1 ox enabled lane 0 writes x10"
.assert rd_wdata == 0x15 "e8 m1 ox enabled lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 m1 ox masked-off lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "e8 m1 ox masked-off lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 m1 ox enabled lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff97 "e8 m1 ox enabled lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 m1 ox tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "e8 m1 ox tail lane 3"
.4byte 0x05100313  # addi t1, zero, 81
.4byte 0x08648223  # sb t1, 132(s1)
.4byte 0x05200313  # addi t1, zero, 82
.4byte 0x00648223  # sb t1, 4(s1)
.4byte 0x05300313  # addi t1, zero, 83
.4byte 0x08648023  # sb t1, 128(s1)
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x0d048427  # vsoxei8.v v8, (s1), v16, v0.t
.assert trap == 0 "vsoxei8.v retires"
.4byte 0x0844c503  # lbu a0, 132(s1)
.assert rd_addr == 10 "e8 m1 masked ox store at offset 132 writes x10"
.assert rd_wdata == 0x15 "e8 m1 masked ox store at offset 132"
.4byte 0x0044c503  # lbu a0, 4(s1)
.assert rd_addr == 10 "e8 m1 masked ox store at offset 4 writes x10"
.assert rd_wdata == 0x52 "e8 m1 masked ox store at offset 4"
.4byte 0x0804c503  # lbu a0, 128(s1)
.assert rd_addr == 10 "e8 m1 masked ox store at offset 128 writes x10"
.assert rd_wdata == 0x97 "e8 m1 masked ox store at offset 128"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 m1 masked ox store at offset 0 writes x10"
.assert rd_wdata == 0x5a "e8 m1 masked ox store at offset 0"

# Masked unordered and ordered indexed EEW 16 m1 vl=3 mask=0b10 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00600313  # addi t1, zero, 6
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x00e00313  # addi t1, zero, 14
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00641723  # sh t1, 14(s0)
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00004337  # lui t1, 0x4
.4byte 0xc3c30313  # addi t1, t1, -964
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x05045407  # vluxei16.v v8, (s0), v16, v0.t
.assert trap == 0 "vluxei16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 m1 ux masked-off lane 0 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 ux masked-off lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 m1 ux enabled lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8222 "e16 m1 ux enabled lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 m1 ux masked-off lane 2 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 ux masked-off lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 m1 ux tail lane 3 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 ux tail lane 3"
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649723  # sh t1, 14(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00007337  # lui t1, 0x7
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x0504d427  # vsuxei16.v v8, (s1), v16, v0.t
.assert trap == 0 "vsuxei16.v retires"
.4byte 0x00e4d503  # lhu a0, 14(s1)
.assert rd_addr == 10 "e16 m1 masked ux store at offset 14 writes x10"
.assert rd_wdata == 0x6111 "e16 m1 masked ux store at offset 14"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "e16 m1 masked ux store at offset 6 writes x10"
.assert rd_wdata == 0x8222 "e16 m1 masked ux store at offset 6"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 m1 masked ux store at offset 0 writes x10"
.assert rd_wdata == 0x6333 "e16 m1 masked ux store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 m1 masked ux store at offset 2 writes x10"
.assert rd_wdata == 0x6aaa "e16 m1 masked ux store at offset 2"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00004337  # lui t1, 0x4
.4byte 0xc3c30313  # addi t1, t1, -964
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x0d045407  # vloxei16.v v8, (s0), v16, v0.t
.assert trap == 0 "vloxei16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 m1 ox masked-off lane 0 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 ox masked-off lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 m1 ox enabled lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8222 "e16 m1 ox enabled lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 m1 ox masked-off lane 2 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 ox masked-off lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 m1 ox tail lane 3 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 ox tail lane 3"
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649723  # sh t1, 14(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00007337  # lui t1, 0x7
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x0d04d427  # vsoxei16.v v8, (s1), v16, v0.t
.assert trap == 0 "vsoxei16.v retires"
.4byte 0x00e4d503  # lhu a0, 14(s1)
.assert rd_addr == 10 "e16 m1 masked ox store at offset 14 writes x10"
.assert rd_wdata == 0x6111 "e16 m1 masked ox store at offset 14"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "e16 m1 masked ox store at offset 6 writes x10"
.assert rd_wdata == 0x8222 "e16 m1 masked ox store at offset 6"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 m1 masked ox store at offset 0 writes x10"
.assert rd_wdata == 0x6333 "e16 m1 masked ox store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 m1 masked ox store at offset 2 writes x10"
.assert rd_wdata == 0x6aaa "e16 m1 masked ox store at offset 2"

# Masked unordered and ordered indexed EEW 32 m1 vl=3 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00400313  # addi t1, zero, 4
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00c00313  # addi t1, zero, 12
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x01800313  # addi t1, zero, 24
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x00642c23  # sw t1, 24(s0)
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
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x33445337  # lui t1, 0x33445
.4byte 0x56630313  # addi t1, t1, 1382
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x05046407  # vluxei32.v v8, (s0), v16, v0.t
.assert trap == 0 "vluxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 m1 ux enabled lane 0 writes x10"
.assert rd_wdata == 0x11223344 "e32 m1 ux enabled lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 m1 ux masked-off lane 1 writes x10"
.assert rd_wdata == 0x33445566 "e32 m1 ux masked-off lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 m1 ux enabled lane 2 writes x10"
.assert rd_wdata == 0xffffffff99aabbcc "e32 m1 ux enabled lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 m1 ux tail lane 3 writes x10"
.assert rd_wdata == 0x33445566 "e32 m1 ux tail lane 3"
.4byte 0x71000337  # lui t1, 0x71000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x72000337  # lui t1, 0x72000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x73000337  # lui t1, 0x73000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x7aaab337  # lui t1, 0x7aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x0504e427  # vsuxei32.v v8, (s1), v16, v0.t
.assert trap == 0 "vsuxei32.v retires"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "e32 m1 masked ux store at offset 24 writes x10"
.assert rd_wdata == 0x11223344 "e32 m1 masked ux store at offset 24"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "e32 m1 masked ux store at offset 12 writes x10"
.assert rd_wdata == 0x72000002 "e32 m1 masked ux store at offset 12"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 m1 masked ux store at offset 4 writes x10"
.assert rd_wdata == 0x99aabbcc "e32 m1 masked ux store at offset 4"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 m1 masked ux store at offset 0 writes x10"
.assert rd_wdata == 0x7aaaaaaa "e32 m1 masked ux store at offset 0"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x33445337  # lui t1, 0x33445
.4byte 0x56630313  # addi t1, t1, 1382
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x0d046407  # vloxei32.v v8, (s0), v16, v0.t
.assert trap == 0 "vloxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 m1 ox enabled lane 0 writes x10"
.assert rd_wdata == 0x11223344 "e32 m1 ox enabled lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 m1 ox masked-off lane 1 writes x10"
.assert rd_wdata == 0x33445566 "e32 m1 ox masked-off lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 m1 ox enabled lane 2 writes x10"
.assert rd_wdata == 0xffffffff99aabbcc "e32 m1 ox enabled lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 m1 ox tail lane 3 writes x10"
.assert rd_wdata == 0x33445566 "e32 m1 ox tail lane 3"
.4byte 0x71000337  # lui t1, 0x71000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x72000337  # lui t1, 0x72000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x73000337  # lui t1, 0x73000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x7aaab337  # lui t1, 0x7aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x0d04e427  # vsoxei32.v v8, (s1), v16, v0.t
.assert trap == 0 "vsoxei32.v retires"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "e32 m1 masked ox store at offset 24 writes x10"
.assert rd_wdata == 0x11223344 "e32 m1 masked ox store at offset 24"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "e32 m1 masked ox store at offset 12 writes x10"
.assert rd_wdata == 0x72000002 "e32 m1 masked ox store at offset 12"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 m1 masked ox store at offset 4 writes x10"
.assert rd_wdata == 0x99aabbcc "e32 m1 masked ox store at offset 4"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 m1 masked ox store at offset 0 writes x10"
.assert rd_wdata == 0x7aaaaaaa "e32 m1 masked ox store at offset 0"

# Masked unordered and ordered indexed EEW 64 m2 vl=3 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x02000313  # addi t1, zero, 32
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x21222337  # lui t1, 0x21222
.4byte 0x32430313  # addi t1, t1, 804
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x25262fb7  # lui t6, 0x25262
.4byte 0x728f8f93  # addi t6, t6, 1832
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643023  # sd t1, 32(s0)
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
.4byte 0x05047407  # vluxei64.v v8, (s0), v16, v0.t
.assert trap == 0 "vluxei64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 m2 ux enabled lane 0 writes x10"
.assert rd_wdata == 0x2122232425262728 "e64 m2 ux enabled lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 m2 ux masked-off lane 1 writes x10"
.assert rd_wdata == 0x1f2e3d4c5b6a7988 "e64 m2 ux masked-off lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 m2 ux enabled lane 2 writes x10"
.assert rd_wdata == 0xa1a2a3a4a5a6a7a8 "e64 m2 ux enabled lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 m2 ux tail lane 3 writes x10"
.assert rd_wdata == 0x1f2e3d4c5b6a7988 "e64 m2 ux tail lane 3"
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00200f93  # addi t6, zero, 2
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x63000337  # lui t1, 0x63000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00300f93  # addi t6, zero, 3
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x6aaab337  # lui t1, 0x6aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0504f427  # vsuxei64.v v8, (s1), v16, v0.t
.assert trap == 0 "vsuxei64.v retires"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e64 m2 masked ux store at offset 32 writes x10"
.assert rd_wdata == 0x2122232425262728 "e64 m2 masked ux store at offset 32"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 m2 masked ux store at offset 16 writes x10"
.assert rd_wdata == 0x6200000000000002 "e64 m2 masked ux store at offset 16"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 m2 masked ux store at offset 0 writes x10"
.assert rd_wdata == 0xa1a2a3a4a5a6a7a8 "e64 m2 masked ux store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 m2 masked ux store at offset 8 writes x10"
.assert rd_wdata == 0x6aaaaaaaaaaaaaaa "e64 m2 masked ux store at offset 8"
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
.4byte 0x0d047407  # vloxei64.v v8, (s0), v16, v0.t
.assert trap == 0 "vloxei64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 m2 ox enabled lane 0 writes x10"
.assert rd_wdata == 0x2122232425262728 "e64 m2 ox enabled lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 m2 ox masked-off lane 1 writes x10"
.assert rd_wdata == 0x1f2e3d4c5b6a7988 "e64 m2 ox masked-off lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 m2 ox enabled lane 2 writes x10"
.assert rd_wdata == 0xa1a2a3a4a5a6a7a8 "e64 m2 ox enabled lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 m2 ox tail lane 3 writes x10"
.assert rd_wdata == 0x1f2e3d4c5b6a7988 "e64 m2 ox tail lane 3"
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00200f93  # addi t6, zero, 2
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x63000337  # lui t1, 0x63000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00300f93  # addi t6, zero, 3
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x6aaab337  # lui t1, 0x6aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0d04f427  # vsoxei64.v v8, (s1), v16, v0.t
.assert trap == 0 "vsoxei64.v retires"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e64 m2 masked ox store at offset 32 writes x10"
.assert rd_wdata == 0x2122232425262728 "e64 m2 masked ox store at offset 32"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 m2 masked ox store at offset 16 writes x10"
.assert rd_wdata == 0x6200000000000002 "e64 m2 masked ox store at offset 16"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 m2 masked ox store at offset 0 writes x10"
.assert rd_wdata == 0xa1a2a3a4a5a6a7a8 "e64 m2 masked ox store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 m2 masked ox store at offset 8 writes x10"
.assert rd_wdata == 0x6aaaaaaaaaaaaaaa "e64 m2 masked ox store at offset 8"

# Cross-width indexed SEW=64 index_EEW=8 (ux) vl=2.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x5e034c57  # vmv.v.x v24, t1
.4byte 0x01800313  # addi t1, zero, 24
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x2b2b3337  # lui t1, 0x2b2b3
.4byte 0xb2b30313  # addi t1, t1, -1237
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x2b2b3fb7  # lui t6, 0x2b2b3
.4byte 0xb2bf8f93  # addi t6, t6, -1237
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x01234337  # lui t1, 0x1234
.4byte 0x56730313  # addi t1, t1, 1383
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x89abdfb7  # lui t6, 0x89abd
.4byte 0xdeff8f93  # addi t6, t6, -529
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643c23  # sd t1, 24(s0)
.4byte 0xfedcc337  # lui t1, 0xfedcc
.4byte 0xa9830313  # addi t1, t1, -1384
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x76543fb7  # lui t6, 0x76543
.4byte 0x210f8f93  # addi t6, t6, 528
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0xeeeef337  # lui t1, 0xeeeef
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x07040407  # vluxei8.v v8, (s0), v16
.assert trap == 0 "vluxei8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "cross e64/ei8 lane 0 writes x10"
.assert rd_wdata == 0x123456789abcdef "cross e64/ei8 lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e64/ei8 lane 1 writes x10"
.assert rd_wdata == 0xfedcba9876543210 "cross e64/ei8 lane 1"
.4byte 0x51111337  # lui t1, 0x51111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x52222337  # lui t1, 0x52222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x5aaab337  # lui t1, 0x5aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x07048427  # vsuxei8.v v8, (s1), v16
.assert trap == 0 "vsuxei8.v retires"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "cross e64/ei8 store at offset 24 writes x10"
.assert rd_wdata == 0x123456789abcdef "cross e64/ei8 store at offset 24"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "cross e64/ei8 store at offset 8 writes x10"
.assert rd_wdata == 0xfedcba9876543210 "cross e64/ei8 store at offset 8"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "cross e64/ei8 store at offset 0 writes x10"
.assert rd_wdata == 0x5aaaaaaaaaaaaaaa "cross e64/ei8 store at offset 0"

# Cross-width indexed SEW=32 index_EEW=16 (ox) vl=3.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00c00313  # addi t1, zero, 12
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00400313  # addi t1, zero, 4
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x2c2c3337  # lui t1, 0x2c2c3
.4byte 0xc2c30313  # addi t1, t1, -980
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x10203337  # lui t1, 0x10203
.4byte 0x04030313  # addi t1, t1, 64
.4byte 0x00642a23  # sw t1, 20(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x8090afb7  # lui t6, 0x8090a
.4byte 0x0b0f8f93  # addi t6, t6, 176
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x50607337  # lui t1, 0x50607
.4byte 0x08030313  # addi t1, t1, 128
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xeeeeffb7  # lui t6, 0xeeeef
.4byte 0xeeef8f93  # addi t6, t6, -274
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x0f045407  # vloxei16.v v8, (s0), v16
.assert trap == 0 "vloxei16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "cross e32/ei16 lane 0 writes x10"
.assert rd_wdata == 0x10203040 "cross e32/ei16 lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e32/ei16 lane 1 writes x10"
.assert rd_wdata == 0xffffffff8090a0b0 "cross e32/ei16 lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e32/ei16 lane 2 writes x10"
.assert rd_wdata == 0x50607080 "cross e32/ei16 lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e32/ei16 tail lane 3 writes x10"
.assert rd_wdata == 0x2c2c2c2c "cross e32/ei16 tail lane 3"
.4byte 0x61111337  # lui t1, 0x61111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x0064aa23  # sw t1, 20(s1)
.4byte 0x62222337  # lui t1, 0x62222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x63333337  # lui t1, 0x63333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x6aaab337  # lui t1, 0x6aaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x0f04d427  # vsoxei16.v v8, (s1), v16
.assert trap == 0 "vsoxei16.v retires"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "cross e32/ei16 store at offset 20 writes x10"
.assert rd_wdata == 0x10203040 "cross e32/ei16 store at offset 20"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "cross e32/ei16 store at offset 4 writes x10"
.assert rd_wdata == 0x8090a0b0 "cross e32/ei16 store at offset 4"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "cross e32/ei16 store at offset 12 writes x10"
.assert rd_wdata == 0x50607080 "cross e32/ei16 store at offset 12"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "cross e32/ei16 store at offset 0 writes x10"
.assert rd_wdata == 0x6aaaaaaa "cross e32/ei16 store at offset 0"

# Cross-width indexed SEW=16 index_EEW=32 (ux) vl=3.
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x00a00313  # addi t1, zero, 10
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x01200313  # addi t1, zero, 18
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00003337  # lui t1, 0x3
.4byte 0xd2d30313  # addi t1, t1, -723
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x35730313  # addi t1, t1, 855
.4byte 0x00641923  # sh t1, 18(s0)
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0xbdf30313  # addi t1, t1, -1057
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x00641523  # sh t1, 10(s0)
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0xeee30313  # addi t1, t1, -274
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x07046407  # vluxei32.v v8, (s0), v16
.assert trap == 0 "vluxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "cross e16/ei32 lane 0 writes x10"
.assert rd_wdata == 0x1357 "cross e16/ei32 lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e16/ei32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff9bdf "cross e16/ei32 lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e16/ei32 lane 2 writes x10"
.assert rd_wdata == 0x2468 "cross e16/ei32 lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e16/ei32 tail lane 3 writes x10"
.assert rd_wdata == 0x2d2d "cross e16/ei32 tail lane 3"
.4byte 0x00007337  # lui t1, 0x7
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649923  # sh t1, 18(s1)
.4byte 0x00007337  # lui t1, 0x7
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x00007337  # lui t1, 0x7
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649523  # sh t1, 10(s1)
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x0704e427  # vsuxei32.v v8, (s1), v16
.assert trap == 0 "vsuxei32.v retires"
.4byte 0x0124d503  # lhu a0, 18(s1)
.assert rd_addr == 10 "cross e16/ei32 store at offset 18 writes x10"
.assert rd_wdata == 0x1357 "cross e16/ei32 store at offset 18"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "cross e16/ei32 store at offset 2 writes x10"
.assert rd_wdata == 0x9bdf "cross e16/ei32 store at offset 2"
.4byte 0x00a4d503  # lhu a0, 10(s1)
.assert rd_addr == 10 "cross e16/ei32 store at offset 10 writes x10"
.assert rd_wdata == 0x2468 "cross e16/ei32 store at offset 10"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "cross e16/ei32 store at offset 0 writes x10"
.assert rd_wdata == 0x7aaa "cross e16/ei32 store at offset 0"

# Cross-width indexed SEW=8 index_EEW=64 (ox) vl=3.
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x00700313  # addi t1, zero, 7
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x00d00313  # addi t1, zero, 13
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x02e00313  # addi t1, zero, 46
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x03900313  # addi t1, zero, 57
.4byte 0x006406a3  # sb t1, 13(s0)
.4byte 0x0a400313  # addi t1, zero, 164
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x06b00313  # addi t1, zero, 107
.4byte 0x006403a3  # sb t1, 7(s0)
.4byte 0x0ee00313  # addi t1, zero, 238
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x0f047407  # vloxei64.v v8, (s0), v16
.assert trap == 0 "vloxei64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "cross e8/ei64 lane 0 writes x10"
.assert rd_wdata == 0x39 "cross e8/ei64 lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e8/ei64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffa4 "cross e8/ei64 lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e8/ei64 lane 2 writes x10"
.assert rd_wdata == 0x6b "cross e8/ei64 lane 2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "cross e8/ei64 tail lane 3 writes x10"
.assert rd_wdata == 0x2e "cross e8/ei64 tail lane 3"
.4byte 0x08100313  # addi t1, zero, 129
.4byte 0x006486a3  # sb t1, 13(s1)
.4byte 0x08200313  # addi t1, zero, 130
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x08300313  # addi t1, zero, 131
.4byte 0x006483a3  # sb t1, 7(s1)
.4byte 0x08a00313  # addi t1, zero, 138
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x0f04f427  # vsoxei64.v v8, (s1), v16
.assert trap == 0 "vsoxei64.v retires"
.4byte 0x00d4c503  # lbu a0, 13(s1)
.assert rd_addr == 10 "cross e8/ei64 store at offset 13 writes x10"
.assert rd_wdata == 0x39 "cross e8/ei64 store at offset 13"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "cross e8/ei64 store at offset 1 writes x10"
.assert rd_wdata == 0xa4 "cross e8/ei64 store at offset 1"
.4byte 0x0074c503  # lbu a0, 7(s1)
.assert rd_addr == 10 "cross e8/ei64 store at offset 7 writes x10"
.assert rd_wdata == 0x6b "cross e8/ei64 store at offset 7"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "cross e8/ei64 store at offset 0 writes x10"
.assert rd_wdata == 0x8a "cross e8/ei64 store at offset 0"

# Duplicate-index gather and ordered duplicate-index store overwrite order.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00c00313  # addi t1, zero, 12
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x00c00313  # addi t1, zero, 12
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x55667337  # lui t1, 0x55667
.4byte 0x78830313  # addi t1, t1, 1928
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x11112337  # lui t1, 0x11112
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x8888afb7  # lui t6, 0x8888a
.4byte 0x999f8f93  # addi t6, t6, -1639
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x07046407  # vluxei32.v v8, (s0), v16
.assert trap == 0 "vluxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "dup-index gather lane 0 writes x10"
.assert rd_wdata == 0xffffffff88889999 "dup-index gather lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "dup-index gather lane 1 writes x10"
.assert rd_wdata == 0x11112222 "dup-index gather lane 1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "dup-index gather lane 2 writes x10"
.assert rd_wdata == 0xffffffff88889999 "dup-index gather lane 2"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x33330337  # lui t1, 0x33330
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x22220337  # lui t1, 0x22220
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836c57  # vslide1up.vx v24, v8, t1
.4byte 0x11110337  # lui t1, 0x11110
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b836457  # vslide1up.vx v8, v24, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x99990fb7  # lui t6, 0x99990
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x99990fb7  # lui t6, 0x99990
.4byte 0x008f8f93  # addi t6, t6, 8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x0f04e427  # vsoxei32.v v8, (s1), v16
.assert trap == 0 "vsoxei32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "ordered dup-index store at offset 0 writes x10"
.assert rd_wdata == 0x33330003 "ordered dup-index store at offset 0"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "ordered dup-index store at offset 8 writes x10"
.assert rd_wdata == 0x22220002 "ordered dup-index store at offset 8"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xcccc0fb7  # lui t6, 0xcccc0
.4byte 0x003f8f93  # addi t6, t6, 3
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xbbbb0fb7  # lui t6, 0xbbbb0
.4byte 0x002f8f93  # addi t6, t6, 2
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3a836c57  # vslide1up.vx v24, v8, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaa0fb7  # lui t6, 0xaaaa0
.4byte 0x001f8f93  # addi t6, t6, 1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3b836457  # vslide1up.vx v8, v24, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x77770337  # lui t1, 0x77770
.4byte 0x00830313  # addi t1, t1, 8
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x0d04e427  # vsoxei32.v v8, (s1), v16, v0.t
.assert trap == 0 "vsoxei32.v retires"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "masked ordered dup-index store at offset 8 writes x10"
.assert rd_wdata == 0xbbbb0002 "masked ordered dup-index store at offset 8"

# Unsigned MSB-set ei16, ei32 and upper-half ei64 index checks.
.4byte 0x00000a13  # addi s4, zero, 0
.4byte 0x020a1a13  # slli s4, s4, 32
.4byte 0x80018fb7  # lui t6, 0x80018
.4byte 0x100f8f93  # addi t6, t6, 256
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01fa6a33  # or s4, s4, t6
.4byte 0x00000a93  # addi s5, zero, 0
.4byte 0x020a9a93  # slli s5, s5, 32
.4byte 0x80008fb7  # lui t6, 0x80008
.4byte 0x100f8f93  # addi t6, t6, 256
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01faeab3  # or s5, s5, t6
.4byte 0x1234b337  # lui t1, 0x1234b
.4byte 0xbcd30313  # addi t1, t1, -1075
.4byte 0x006a2023  # sw t1, 0(s4)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xdead0fb7  # lui t6, 0xdead0
.4byte 0x001f8f93  # addi t6, t6, 1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x006aa023  # sw t1, 0(s5)
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034c57  # vmv.v.x v24, t1
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x51515337  # lui t1, 0x51515
.4byte 0x15130313  # addi t1, t1, 337
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x45670337  # lui t1, 0x45670
.4byte 0x12330313  # addi t1, t1, 291
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x07045407  # vluxei16.v v8, (s0), v16
.assert trap == 0 "vluxei16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "unsigned ei16 0x8000 index lane 0 writes x10"
.assert rd_wdata == 0x1234abcd "unsigned ei16 0x8000 index lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "unsigned ei16 0x0000 index lane 1 writes x10"
.assert rd_wdata == 0x45670123 "unsigned ei16 0x0000 index lane 1"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80010fb7  # lui t6, 0x80010
.4byte 0x104f8f93  # addi t6, t6, 260
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034c57  # vmv.v.x v24, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80010fb7  # lui t6, 0x80010
.4byte 0x100f8f93  # addi t6, t6, 256
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x52525337  # lui t1, 0x52525
.4byte 0x25230313  # addi t1, t1, 594
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x23456337  # lui t1, 0x23456
.4byte 0x78930313  # addi t1, t1, 1929
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x89abdfb7  # lui t6, 0x89abd
.4byte 0xdeff8f93  # addi t6, t6, -529
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x0f006407  # vloxei32.v v8, (zero), v16
.assert trap == 0 "vloxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "unsigned ei32 MSB=1 lane 0 writes x10"
.assert rd_wdata == 0x23456789 "unsigned ei32 MSB=1 lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "unsigned ei32 MSB=1 lane 1 writes x10"
.assert rd_wdata == 0xffffffff89abcdef "unsigned ei32 MSB=1 lane 1"
.4byte 0x80000a37  # lui s4, 0x80000
.4byte 0x020a1a13  # slli s4, s4, 32
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80010fb7  # lui t6, 0x80010
.4byte 0x100f8f93  # addi t6, t6, 256
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x53535337  # lui t1, 0x53535
.4byte 0x35330313  # addi t1, t1, 851
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x53535fb7  # lui t6, 0x53535
.4byte 0x353f8f93  # addi t6, t6, 851
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x1 "e64 m1 active vector length"
.4byte 0x0f1e3337  # lui t1, 0xf1e3
.4byte 0xd3c30313  # addi t1, t1, -708
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x4b5a7fb7  # lui t6, 0x4b5a7
.4byte 0x978f8f93  # addi t6, t6, -1672
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x070a7407  # vluxei64.v v8, (s4), v16
.assert trap == 0 "vluxei64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "full 64-bit ei64 upper-half index writes x10"
.assert rd_wdata == 0xf1e2d3c4b5a6978 "full 64-bit ei64 upper-half index"

# Legal in-place gather (vd == vs2 at SEW == index_EEW) and ta, ma load.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x01c00313  # addi t1, zero, 28
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x00400313  # addi t1, zero, 4
.4byte 0x3b036c57  # vslide1up.vx v24, v16, t1
.4byte 0x00c00313  # addi t1, zero, 12
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x76543337  # lui t1, 0x76543
.4byte 0x21030313  # addi t1, t1, 528
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x89abdfb7  # lui t6, 0x89abd
.4byte 0xdeff8f93  # addi t6, t6, -529
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x07046807  # vluxei32.v v16, (s0), v16
.assert trap == 0 "vluxei32.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "in-place gather lane 0 writes x10"
.assert rd_wdata == 0xffffffff89abcdef "in-place gather lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "in-place gather lane 1 writes x10"
.assert rd_wdata == 0x76543210 "in-place gather lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "in-place gather tail lane 2 undisturbed writes x10"
.assert rd_wdata == 0x1c "in-place gather tail lane 2 undisturbed"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034c57  # vmv.v.x v24, t1
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0xcd017657  # vsetivli a2, 2, e32, m1, ta, ma
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x1357a337  # lui t1, 0x1357a
.4byte 0xbdf30313  # addi t1, t1, -1057
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x2468b337  # lui t1, 0x2468b
.4byte 0xce030313  # addi t1, t1, -800
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x0d046407  # vloxei32.v v8, (s0), v16, v0.t
.assert trap == 0 "vloxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "ta, ma indexed enabled lane 0 writes x10"
.assert rd_wdata == 0x2468ace0 "ta, ma indexed enabled lane 0"

# Full-VLMAX indexed transfers across all four widths and VLENs.
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

# Full-VLMAX ux indexed EEW 8 permuted load and store.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0a100313  # addi t1, zero, 161
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00007657  # vsetvli a2, zero, e8, m1, tu, mu
.4byte 0x5208a857  # vid.v v16
.4byte 0x2f00b857  # vxor.vi v16, v16, 1
.4byte 0x9700b857  # vsll.vi v16, v16, 1
.4byte 0x07040407  # vluxei8.v v8, (s0), v16
.assert trap == 0 "vluxei8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 VLMAX indexed lane 0 writes x10"
.assert rd_wdata == 0x12 "e8 VLMAX indexed lane 0"
.4byte 0xfffe0393  # addi t2, t3, -1
.4byte 0x3e83cc57  # vslidedown.vx v24, v8, t2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e8 VLMAX indexed last lane writes x10"
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
.4byte 0x07048427  # vsuxei8.v v8, (s1), v16
.assert trap == 0 "vsuxei8.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e8 VLMAX indexed stored dw 0 writes x10"
.assert rd_wdata == 0xf116f114f112f110 "e8 VLMAX indexed stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e8 VLMAX indexed stored dw 1 writes x10"
.assert rd_wdata == 0xf11ef11cf11af118 "e8 VLMAX indexed stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e8 VLMAX indexed stored dw 2 writes x10"
.assert rd_wdata == 0xf126f124f122f120 "e8 VLMAX indexed stored dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e8 VLMAX indexed stored dw 3 writes x10"
.assert rd_wdata == 0xf12ef12cf12af128 "e8 VLMAX indexed stored dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "e8 VLMAX indexed readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "e8 VLMAX indexed untouched guard dw writes x10"
.assert rd_wdata == 0xf1f1f1f1f1f1f1f1 "e8 VLMAX indexed untouched guard dw"

# Full-VLMAX ox indexed EEW 16 permuted load and store.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x2a230313  # addi t1, t1, 674
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00807657  # vsetvli a2, zero, e16, m1, tu, mu
.4byte 0x5208a857  # vid.v v16
.4byte 0x2f00b857  # vxor.vi v16, v16, 1
.4byte 0x97013857  # vsll.vi v16, v16, 2
.4byte 0x0f045407  # vloxei16.v v8, (s0), v16
.assert trap == 0 "vloxei16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 VLMAX indexed lane 0 writes x10"
.assert rd_wdata == 0x1514 "e16 VLMAX indexed lane 0"
.4byte 0x001e5393  # srli t2, t3, 1
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83cc57  # vslidedown.vx v24, v8, t2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e16 VLMAX indexed last lane writes x10"
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
.4byte 0x0f04d427  # vsoxei16.v v8, (s1), v16
.assert trap == 0 "vsoxei16.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e16 VLMAX indexed stored dw 0 writes x10"
.assert rd_wdata == 0xf2f21514f2f21110 "e16 VLMAX indexed stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e16 VLMAX indexed stored dw 1 writes x10"
.assert rd_wdata == 0xf2f21d1cf2f21918 "e16 VLMAX indexed stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e16 VLMAX indexed stored dw 2 writes x10"
.assert rd_wdata == 0xf2f22524f2f22120 "e16 VLMAX indexed stored dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e16 VLMAX indexed stored dw 3 writes x10"
.assert rd_wdata == 0xf2f22d2cf2f22928 "e16 VLMAX indexed stored dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "e16 VLMAX indexed readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "e16 VLMAX indexed untouched guard dw writes x10"
.assert rd_wdata == 0xf2f2f2f2f2f2f2f2 "e16 VLMAX indexed untouched guard dw"

# Full-VLMAX ux indexed EEW 32 permuted load and store.
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
.4byte 0x5208a857  # vid.v v16
.4byte 0x2f00b857  # vxor.vi v16, v16, 1
.4byte 0x9701b857  # vsll.vi v16, v16, 3
.4byte 0x07046407  # vluxei32.v v8, (s0), v16
.assert trap == 0 "vluxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 VLMAX indexed lane 0 writes x10"
.assert rd_wdata == 0x1b1a1918 "e32 VLMAX indexed lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83cc57  # vslidedown.vx v24, v8, t2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e32 VLMAX indexed last lane writes x10"
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
.4byte 0x0704e427  # vsuxei32.v v8, (s1), v16
.assert trap == 0 "vsuxei32.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e32 VLMAX indexed stored dw 0 writes x10"
.assert rd_wdata == 0xf3f3f3f313121110 "e32 VLMAX indexed stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e32 VLMAX indexed stored dw 1 writes x10"
.assert rd_wdata == 0xf3f3f3f31b1a1918 "e32 VLMAX indexed stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e32 VLMAX indexed stored dw 2 writes x10"
.assert rd_wdata == 0xf3f3f3f323222120 "e32 VLMAX indexed stored dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e32 VLMAX indexed stored dw 3 writes x10"
.assert rd_wdata == 0xf3f3f3f32b2a2928 "e32 VLMAX indexed stored dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "e32 VLMAX indexed readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "e32 VLMAX indexed untouched guard dw writes x10"
.assert rd_wdata == 0xf3f3f3f3f3f3f3f3 "e32 VLMAX indexed untouched guard dw"

# Full-VLMAX ox indexed EEW 64 permuted load and store.
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
.4byte 0x5208a857  # vid.v v16
.4byte 0x2f00b857  # vxor.vi v16, v16, 1
.4byte 0x97023857  # vsll.vi v16, v16, 4
.4byte 0x0f047407  # vloxei64.v v8, (s0), v16
.assert trap == 0 "vloxei64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 VLMAX indexed lane 0 writes x10"
.assert rd_wdata == 0x2726252423222120 "e64 VLMAX indexed lane 0"
.4byte 0x003e5393  # srli t2, t3, 3
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83cc57  # vslidedown.vx v24, v8, t2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "e64 VLMAX indexed last lane writes x10"
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
.4byte 0x0f04f427  # vsoxei64.v v8, (s1), v16
.assert trap == 0 "vsoxei64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 VLMAX indexed stored dw 0 writes x10"
.assert rd_wdata == 0x1716151413121110 "e64 VLMAX indexed stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 VLMAX indexed stored dw 1 writes x10"
.assert rd_wdata == 0xf4f4f4f4f4f4f4f4 "e64 VLMAX indexed stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 VLMAX indexed stored dw 2 writes x10"
.assert rd_wdata == 0x2726252423222120 "e64 VLMAX indexed stored dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e64 VLMAX indexed stored dw 3 writes x10"
.assert rd_wdata == 0xf4f4f4f4f4f4f4f4 "e64 VLMAX indexed stored dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "e64 VLMAX indexed readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "e64 VLMAX indexed untouched guard dw writes x10"
.assert rd_wdata == 0xf4f4f4f4f4f4f4f4 "e64 VLMAX indexed untouched guard dw"

# Full-VLMAX masked indexed EEW 32 permuted load and store.
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
.4byte 0x5208a857  # vid.v v16
.4byte 0x2f00b857  # vxor.vi v16, v16, 1
.4byte 0x9701b857  # vsll.vi v16, v16, 3
.4byte 0x05046407  # vluxei32.v v8, (s0), v16, v0.t
.assert trap == 0 "vluxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX masked indexed e32 disabled lane 0 writes x10"
.assert rd_wdata == 0x55aa55aa "VLMAX masked indexed e32 disabled lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX masked indexed e32 enabled lane 1 writes x10"
.assert rd_wdata == 0x13121110 "VLMAX masked indexed e32 enabled lane 1"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83cc57  # vslidedown.vx v24, v8, t2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX masked indexed e32 last lane writes x10"
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
.4byte 0x0504e427  # vsuxei32.v v8, (s1), v16, v0.t
.assert trap == 0 "vsuxei32.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 enabled dw 0 writes x10"
.assert rd_wdata == 0xf5f5f5f513121110 "VLMAX masked indexed e32 enabled dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 disabled dw 1 writes x10"
.assert rd_wdata == 0xf5f5f5f5f5f5f5f5 "VLMAX masked indexed e32 disabled dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 enabled dw 2 writes x10"
.assert rd_wdata == 0xf5f5f5f523222120 "VLMAX masked indexed e32 enabled dw 2"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 disabled dw 3 writes x10"
.assert rd_wdata == 0xf5f5f5f5f5f5f5f5 "VLMAX masked indexed e32 disabled dw 3"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 8 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 9 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 10 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 11 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 12 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 13 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 14 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 readback dw 15 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "VLMAX masked indexed e32 untouched guard dw writes x10"
.assert rd_wdata == 0xf5f5f5f5f5f5f5f5 "VLMAX masked indexed e32 untouched guard dw"

# Zero-length and all-masked-off indexed transfers leave state intact.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034c57  # vmv.v.x v24, t1
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x0badc337  # lui t1, 0xbadc
.4byte 0x0de30313  # addi t1, t1, 222
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x66666337  # lui t1, 0x66666
.4byte 0x66630313  # addi t1, t1, 1638
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x66666337  # lui t1, 0x66666
.4byte 0x66830313  # addi t1, t1, 1640
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x0 "e32 m1 active vector length"
.4byte 0x07046407  # vluxei32.v v8, (s0), v16
.assert trap == 0 "vluxei32.v retires"
.4byte 0x0704e427  # vsuxei32.v v8, (s1), v16
.assert trap == 0 "vsuxei32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vl=0 indexed store leaves memory intact at offset 0 writes x10"
.assert rd_wdata == 0x66666666 "vl=0 indexed store leaves memory intact at offset 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x1 "e32 m1 active vector length"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl=0 indexed load leaves vector intact writes x10"
.assert rd_wdata == 0xbadc0de "vl=0 indexed load leaves vector intact"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x0feee337  # lui t1, 0xfeee
.4byte 0xace30313  # addi t1, t1, -1330
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x0d046407  # vloxei32.v v8, (s0), v16, v0.t
.assert trap == 0 "vloxei32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "all-masked indexed load lane 0 undisturbed writes x10"
.assert rd_wdata == 0xfeedace "all-masked indexed load lane 0 undisturbed"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "all-masked indexed load lane 1 undisturbed writes x10"
.assert rd_wdata == 0xfeedace "all-masked indexed load lane 1 undisturbed"
.4byte 0x55551337  # lui t1, 0x55551
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x55552337  # lui t1, 0x55552
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x0d04e427  # vsoxei32.v v8, (s1), v16, v0.t
.assert trap == 0 "vsoxei32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "all-masked indexed store intact at offset 0 writes x10"
.assert rd_wdata == 0x55551111 "all-masked indexed store intact at offset 0"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "all-masked indexed store intact at offset 8 writes x10"
.assert rd_wdata == 0x55552222 "all-masked indexed store intact at offset 8"

# Cached DDR indexed transfer across a 4 KiB page boundary.
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
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034c57  # vmv.v.x v24, t1
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x3b836857  # vslide1up.vx v16, v24, t1
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
.4byte 0x0f095407  # vloxei16.v v8, (s2), v16
.assert trap == 0 "vloxei16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "page-crossing indexed load lane 0 writes x10"
.assert rd_wdata == 0x898a8b8c8d8e8f90 "page-crossing indexed load lane 0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "page-crossing indexed load lane 1 writes x10"
.assert rd_wdata == 0x102030405060708 "page-crossing indexed load lane 1"
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
.4byte 0x0f09d427  # vsoxei16.v v8, (s3), v16
.assert trap == 0 "vsoxei16.v retires"
.4byte 0x0009b503  # ld a0, 0(s3)
.assert rd_addr == 10 "page-crossing indexed store at offset 0 writes x10"
.assert rd_wdata == 0x102030405060708 "page-crossing indexed store at offset 0"
.4byte 0x0089b503  # ld a0, 8(s3)
.assert rd_addr == 10 "page-crossing indexed store at offset 8 writes x10"
.assert rd_wdata == 0x4444444444444444 "page-crossing indexed store at offset 8"
.4byte 0x0109b503  # ld a0, 16(s3)
.assert rd_addr == 10 "page-crossing indexed store at offset 16 writes x10"
.assert rd_wdata == 0x898a8b8c8d8e8f90 "page-crossing indexed store at offset 16"
