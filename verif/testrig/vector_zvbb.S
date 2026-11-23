# Vector Zvbb (and Zvkb subset) bit-manipulation directed trace.
# Covers all 16 mnemonics / 17 encoding slots across every legal SEW, masks, tails, LMUL, and traps.
.noshrink
# Preamble: enable VS and zero v0..v31.
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0x60028293  # addi x5, x5, 1536
.4byte 0x3002a073  # csrs mstatus, x5
.4byte 0x01b07fd7  # vsetvli x31, x0, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0

# Section 1: Control vandn.vv into v2 with unique vmv.x.s x10, v2 (0x42202557).
.4byte 0xc1017657  # vsetivli x12, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli e32 m1 vl=2 writes x12"
.assert rd_wdata == 0x2 "vsetivli e32 m1 vl=2"
.4byte 0xaa5532b7  # lui x5, 0xaa553
.4byte 0x3cc28293  # addi x5, x5, 972
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xf0ca12b7  # lui x5, 0xf0ca1
.4byte 0x23428293  # addi x5, x5, 564
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0f0f52b7  # lui x5, 0xf0f5
.4byte 0x5aa28293  # addi x5, x5, 1450
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x0ff012b7  # lui x5, 0xff01
.4byte 0xf0f28293  # addi x5, x5, -241
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x06860157  # vandn.vv v2, v8, v12
.assert trap == 0 "control vandn.vv retires"
.4byte 0x42202557  # vmv.x.s x10, v2
.assert rd_addr == 10 "control vandn.vv lane 0 writes x10"
.assert rd_wdata == 0xfffffffff00a1030 "control vandn.vv lane 0"
.4byte 0x3e20bc57  # vslidedown.vi v24, v2, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vandn.vv lane 1 writes x10"
.assert rd_wdata == 0xffffffffa0502244 "control vandn.vv lane 1"

# Section 2.8: Single-width Zvbb ops at SEW=8, m1, vl=6.
.4byte 0xc0037657  # vsetivli x12, 6, e8, m1, tu, mu
.assert rd_addr == 12 "vsetivli e8 m1 vl=6 writes x12"
.assert rd_wdata == 0x6 "vsetivli e8 m1 vl=6"
.4byte 0x01e00293  # addi x5, x0, 30
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x0a500293  # addi x5, x0, 165
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x08000293  # addi x5, x0, 128
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0ff00293  # addi x5, x0, 255
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0f000293  # addi x5, x0, 240
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x05a00293  # addi x5, x0, 90
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x08100293  # addi x5, x0, 129
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x03c00293  # addi x5, x0, 60
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00f00293  # addi x5, x0, 15
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x05500293  # addi x5, x0, 85
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x01300293  # addi x5, x0, 19
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00300293  # addi x5, x0, 3
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00b00293  # addi x5, x0, 11
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00700293  # addi x5, x0, 7
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x06860a57  # vandn.vv v20, v8, v12
.assert trap == 0 "vandn.vv e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vandn.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vandn.vv e8 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffff0 "vandn.vv e8 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vandn.vv e8 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e8 lane 3 writes x10"
.assert rd_wdata == 0x0 "vandn.vv e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e8 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "vandn.vv e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e8 lane 5 writes x10"
.assert rd_wdata == 0xe "vandn.vv e8 lane 5"
.4byte 0x03c00393  # addi x7, x0, 60
.4byte 0x0683ca57  # vandn.vx v20, v8, x7
.assert trap == 0 "vandn.vx e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vandn.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vandn.vx e8 lane 0"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vandn.vx e8 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e8 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffff81 "vandn.vx e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e8 lane 5 writes x10"
.assert rd_wdata == 0x2 "vandn.vx e8 lane 5"
.4byte 0x4a842a57  # vbrev8.v v20, v8
.assert trap == 0 "vbrev8.v e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vbrev8.v e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vbrev8.v e8 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vbrev8.v e8 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vbrev8.v e8 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e8 lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vbrev8.v e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e8 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "vbrev8.v e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e8 lane 5 writes x10"
.assert rd_wdata == 0x78 "vbrev8.v e8 lane 5"
.4byte 0x4a84aa57  # vrev8.v v20, v8
.assert trap == 0 "vrev8.v e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vrev8.v e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vrev8.v e8 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vrev8.v e8 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vrev8.v e8 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e8 lane 3 writes x10"
.assert rd_wdata == 0x1 "vrev8.v e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e8 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "vrev8.v e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e8 lane 5 writes x10"
.assert rd_wdata == 0x1e "vrev8.v e8 lane 5"
.4byte 0x4a852a57  # vbrev.v v20, v8
.assert trap == 0 "vbrev.v e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vbrev.v e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vbrev.v e8 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vbrev.v e8 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vbrev.v e8 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e8 lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vbrev.v e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e8 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "vbrev.v e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e8 lane 5 writes x10"
.assert rd_wdata == 0x78 "vbrev.v e8 lane 5"
.4byte 0x4a862a57  # vclz.v v20, v8
.assert trap == 0 "vclz.v e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vclz.v e8 lane 0 writes x10"
.assert rd_wdata == 0x8 "vclz.v e8 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vclz.v e8 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e8 lane 2 writes x10"
.assert rd_wdata == 0x0 "vclz.v e8 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e8 lane 3 writes x10"
.assert rd_wdata == 0x7 "vclz.v e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e8 lane 4 writes x10"
.assert rd_wdata == 0x0 "vclz.v e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e8 lane 5 writes x10"
.assert rd_wdata == 0x3 "vclz.v e8 lane 5"
.4byte 0x4a86aa57  # vctz.v v20, v8
.assert trap == 0 "vctz.v e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vctz.v e8 lane 0 writes x10"
.assert rd_wdata == 0x8 "vctz.v e8 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vctz.v e8 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e8 lane 2 writes x10"
.assert rd_wdata == 0x7 "vctz.v e8 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e8 lane 3 writes x10"
.assert rd_wdata == 0x0 "vctz.v e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e8 lane 4 writes x10"
.assert rd_wdata == 0x0 "vctz.v e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e8 lane 5 writes x10"
.assert rd_wdata == 0x1 "vctz.v e8 lane 5"
.4byte 0x4a872a57  # vcpop.v v20, v8
.assert trap == 0 "vcpop.v e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vcpop.v e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vcpop.v e8 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e8 lane 1 writes x10"
.assert rd_wdata == 0x8 "vcpop.v e8 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vcpop.v e8 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e8 lane 3 writes x10"
.assert rd_wdata == 0x1 "vcpop.v e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e8 lane 4 writes x10"
.assert rd_wdata == 0x4 "vcpop.v e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e8 lane 5 writes x10"
.assert rd_wdata == 0x4 "vcpop.v e8 lane 5"
.4byte 0x56880a57  # vrol.vv v20, v8, v16
.assert trap == 0 "vrol.vv e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vrol.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vrol.vv e8 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vrol.vv e8 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x40 "vrol.vv e8 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e8 lane 3 writes x10"
.assert rd_wdata == 0x8 "vrol.vv e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e8 lane 4 writes x10"
.assert rd_wdata == 0x2d "vrol.vv e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e8 lane 5 writes x10"
.assert rd_wdata == 0xfffffffffffffff0 "vrol.vv e8 lane 5"
.4byte 0x00b00393  # addi x7, x0, 11
.4byte 0x5683ca57  # vrol.vx v20, v8, x7
.assert trap == 0 "vrol.vx e8 retires"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x4 "vrol.vx e8 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e8 lane 4 writes x10"
.assert rd_wdata == 0x2d "vrol.vx e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e8 lane 5 writes x10"
.assert rd_wdata == 0xfffffffffffffff0 "vrol.vx e8 lane 5"
.4byte 0x52880a57  # vror.vv v20, v8, v16
.assert trap == 0 "vror.vv e8 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vror.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vror.vv e8 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vror.vv e8 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vror.vv e8 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e8 lane 3 writes x10"
.assert rd_wdata == 0x20 "vror.vv e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e8 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffffb4 "vror.vv e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e8 lane 5 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "vror.vv e8 lane 5"
.4byte 0x5283ca57  # vror.vx v20, v8, x7
.assert trap == 0 "vror.vx e8 retires"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x10 "vror.vx e8 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e8 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffffb4 "vror.vx e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e8 lane 5 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "vror.vx e8 lane 5"
.4byte 0x5281ba57  # vror.vi v20, v8, 3
.assert trap == 0 "vror.vi imm5=0 e8 retires"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e8 lane 3 writes x10"
.assert rd_wdata == 0x20 "vror.vi lo e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e8 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffffb4 "vror.vi lo e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e8 lane 5 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "vror.vi lo e8 lane 5"
.4byte 0x5681ba57  # vror.vi v20, v8, 35
.assert trap == 0 "vror.vi imm5=1 e8 retires"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e8 lane 3 writes x10"
.assert rd_wdata == 0x20 "vror.vi hi e8 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e8 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffffb4 "vror.vi hi e8 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e8 lane 5 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "vror.vi hi e8 lane 5"

# Section 2.16: Single-width Zvbb ops at SEW=16, m1, vl=6.
.4byte 0xc0837657  # vsetivli x12, 6, e16, m1, tu, mu
.assert rd_addr == 12 "vsetivli e16 m1 vl=6 writes x12"
.assert rd_wdata == 0x6 "vsetivli e16 m1 vl=6"
.4byte 0x0000a2b7  # lui x5, 0xa
.4byte 0x50e28293  # addi x5, x5, 1294
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x23428293  # addi x5, x5, 564
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xfff28293  # addi x5, x5, -1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x0f000293  # addi x5, x0, 240
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xf0028293  # addi x5, x5, -256
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x0ff28293  # addi x5, x5, 255
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0xf0f28293  # addi x5, x5, -241
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0ff00293  # addi x5, x0, 255
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x02500293  # addi x5, x0, 37
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00500293  # addi x5, x0, 5
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x01300293  # addi x5, x0, 19
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00f00293  # addi x5, x0, 15
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x06860a57  # vandn.vv v20, v8, v12
.assert trap == 0 "vandn.vv e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vandn.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vandn.vv e16 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffff0f0 "vandn.vv e16 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e16 lane 2 writes x10"
.assert rd_wdata == 0x0 "vandn.vv e16 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e16 lane 3 writes x10"
.assert rd_wdata == 0x1 "vandn.vv e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e16 lane 4 writes x10"
.assert rd_wdata == 0x1204 "vandn.vv e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e16 lane 5 writes x10"
.assert rd_wdata == 0xffffffffffffa504 "vandn.vv e16 lane 5"
.4byte 0x000013b7  # lui x7, 0x1
.4byte 0xf5538393  # addi x7, x7, -171
.4byte 0x0683ca57  # vandn.vx v20, v8, x7
.assert trap == 0 "vandn.vx e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vandn.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vandn.vx e16 lane 0"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vandn.vx e16 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e16 lane 4 writes x10"
.assert rd_wdata == 0x1020 "vandn.vx e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e16 lane 5 writes x10"
.assert rd_wdata == 0xffffffffffffa00a "vandn.vx e16 lane 5"
.4byte 0x4a842a57  # vbrev8.v v20, v8
.assert trap == 0 "vbrev8.v e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vbrev8.v e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vbrev8.v e16 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vbrev8.v e16 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e16 lane 2 writes x10"
.assert rd_wdata == 0x100 "vbrev8.v e16 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e16 lane 3 writes x10"
.assert rd_wdata == 0x80 "vbrev8.v e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e16 lane 4 writes x10"
.assert rd_wdata == 0x482c "vbrev8.v e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e16 lane 5 writes x10"
.assert rd_wdata == 0xffffffffffffa570 "vbrev8.v e16 lane 5"
.4byte 0x4a84aa57  # vrev8.v v20, v8
.assert trap == 0 "vrev8.v e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vrev8.v e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vrev8.v e16 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vrev8.v e16 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e16 lane 2 writes x10"
.assert rd_wdata == 0x80 "vrev8.v e16 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e16 lane 3 writes x10"
.assert rd_wdata == 0x100 "vrev8.v e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e16 lane 4 writes x10"
.assert rd_wdata == 0x3412 "vrev8.v e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e16 lane 5 writes x10"
.assert rd_wdata == 0xea5 "vrev8.v e16 lane 5"
.4byte 0x4a852a57  # vbrev.v v20, v8
.assert trap == 0 "vbrev.v e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vbrev.v e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vbrev.v e16 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vbrev.v e16 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e16 lane 2 writes x10"
.assert rd_wdata == 0x1 "vbrev.v e16 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e16 lane 3 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vbrev.v e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e16 lane 4 writes x10"
.assert rd_wdata == 0x2c48 "vbrev.v e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e16 lane 5 writes x10"
.assert rd_wdata == 0x70a5 "vbrev.v e16 lane 5"
.4byte 0x4a862a57  # vclz.v v20, v8
.assert trap == 0 "vclz.v e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vclz.v e16 lane 0 writes x10"
.assert rd_wdata == 0x10 "vclz.v e16 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e16 lane 1 writes x10"
.assert rd_wdata == 0x0 "vclz.v e16 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e16 lane 2 writes x10"
.assert rd_wdata == 0x0 "vclz.v e16 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e16 lane 3 writes x10"
.assert rd_wdata == 0xf "vclz.v e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e16 lane 4 writes x10"
.assert rd_wdata == 0x3 "vclz.v e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e16 lane 5 writes x10"
.assert rd_wdata == 0x0 "vclz.v e16 lane 5"
.4byte 0x4a86aa57  # vctz.v v20, v8
.assert trap == 0 "vctz.v e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vctz.v e16 lane 0 writes x10"
.assert rd_wdata == 0x10 "vctz.v e16 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e16 lane 1 writes x10"
.assert rd_wdata == 0x0 "vctz.v e16 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e16 lane 2 writes x10"
.assert rd_wdata == 0xf "vctz.v e16 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e16 lane 3 writes x10"
.assert rd_wdata == 0x0 "vctz.v e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e16 lane 4 writes x10"
.assert rd_wdata == 0x2 "vctz.v e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e16 lane 5 writes x10"
.assert rd_wdata == 0x1 "vctz.v e16 lane 5"
.4byte 0x4a872a57  # vcpop.v v20, v8
.assert trap == 0 "vcpop.v e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vcpop.v e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vcpop.v e16 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e16 lane 1 writes x10"
.assert rd_wdata == 0x10 "vcpop.v e16 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e16 lane 2 writes x10"
.assert rd_wdata == 0x1 "vcpop.v e16 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e16 lane 3 writes x10"
.assert rd_wdata == 0x1 "vcpop.v e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e16 lane 4 writes x10"
.assert rd_wdata == 0x5 "vcpop.v e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e16 lane 5 writes x10"
.assert rd_wdata == 0x7 "vcpop.v e16 lane 5"
.4byte 0x56880a57  # vrol.vv v20, v8, v16
.assert trap == 0 "vrol.vv e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vrol.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vrol.vv e16 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vrol.vv e16 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e16 lane 2 writes x10"
.assert rd_wdata == 0x4000 "vrol.vv e16 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e16 lane 3 writes x10"
.assert rd_wdata == 0x8 "vrol.vv e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e16 lane 4 writes x10"
.assert rd_wdata == 0x4682 "vrol.vv e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e16 lane 5 writes x10"
.assert rd_wdata == 0xffffffffffffa1d4 "vrol.vv e16 lane 5"
.4byte 0x01500393  # addi x7, x0, 21
.4byte 0x5683ca57  # vrol.vx v20, v8, x7
.assert trap == 0 "vrol.vx e16 retires"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e16 lane 2 writes x10"
.assert rd_wdata == 0x10 "vrol.vx e16 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e16 lane 4 writes x10"
.assert rd_wdata == 0x4682 "vrol.vx e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e16 lane 5 writes x10"
.assert rd_wdata == 0xffffffffffffa1d4 "vrol.vx e16 lane 5"
.4byte 0x52880a57  # vror.vv v20, v8, v16
.assert trap == 0 "vror.vv e16 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vror.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vror.vv e16 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vror.vv e16 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e16 lane 2 writes x10"
.assert rd_wdata == 0x1 "vror.vv e16 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e16 lane 3 writes x10"
.assert rd_wdata == 0x2000 "vror.vv e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e16 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffa091 "vror.vv e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e16 lane 5 writes x10"
.assert rd_wdata == 0x7528 "vror.vv e16 lane 5"
.4byte 0x5283ca57  # vror.vx v20, v8, x7
.assert trap == 0 "vror.vx e16 retires"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e16 lane 2 writes x10"
.assert rd_wdata == 0x400 "vror.vx e16 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e16 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffa091 "vror.vx e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e16 lane 5 writes x10"
.assert rd_wdata == 0x7528 "vror.vx e16 lane 5"
.4byte 0x5282ba57  # vror.vi v20, v8, 5
.assert trap == 0 "vror.vi imm5=0 e16 retires"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e16 lane 3 writes x10"
.assert rd_wdata == 0x800 "vror.vi lo e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e16 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffa091 "vror.vi lo e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e16 lane 5 writes x10"
.assert rd_wdata == 0x7528 "vror.vi lo e16 lane 5"
.4byte 0x5682ba57  # vror.vi v20, v8, 37
.assert trap == 0 "vror.vi imm5=1 e16 retires"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e16 lane 3 writes x10"
.assert rd_wdata == 0x800 "vror.vi hi e16 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e16 lane 4 writes x10"
.assert rd_wdata == 0xffffffffffffa091 "vror.vi hi e16 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e16 lane 5 writes x10"
.assert rd_wdata == 0x7528 "vror.vi hi e16 lane 5"

# Section 2.32: Single-width Zvbb ops at SEW=32, m2, vl=6.
.4byte 0xc1137657  # vsetivli x12, 6, e32, m2, tu, mu
.assert rd_addr == 12 "vsetivli e32 m2 vl=6 writes x12"
.assert rd_wdata == 0x6 "vsetivli e32 m2 vl=6"
.4byte 0xa55a12b7  # lui x5, 0xa55a1
.4byte 0xf1e28293  # addi x5, x5, -226
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x123452b7  # lui x5, 0x12345
.4byte 0x67828293  # addi x5, x5, 1656
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xfff00293  # addi x5, x0, -1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x5a5a32b7  # lui x5, 0x5a5a3
.4byte 0x3cc28293  # addi x5, x5, 972
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x00f0f2b7  # lui x5, 0xf0f
.4byte 0x00f28293  # addi x5, x5, 15
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xff0102b7  # lui x5, 0xff010
.4byte 0xf0028293  # addi x5, x5, -256
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x0ff28293  # addi x5, x5, 255
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0f0f12b7  # lui x5, 0xf0f1
.4byte 0xf0f28293  # addi x5, x5, -241
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00ff02b7  # lui x5, 0xff0
.4byte 0x0ff28293  # addi x5, x5, 255
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x04700293  # addi x5, x0, 71
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00700293  # addi x5, x0, 7
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x02300293  # addi x5, x0, 35
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x01f00293  # addi x5, x0, 31
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x06860a57  # vandn.vv v20, v8, v12
.assert trap == 0 "vandn.vv e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vandn.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vandn.vv e32 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xfffffffff0f0f0f0 "vandn.vv e32 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x0 "vandn.vv e32 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e32 lane 3 writes x10"
.assert rd_wdata == 0x1 "vandn.vv e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e32 lane 4 writes x10"
.assert rd_wdata == 0x12040670 "vandn.vv e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e32 lane 5 writes x10"
.assert rd_wdata == 0xffffffffa5000c12 "vandn.vv e32 lane 5"
.4byte 0x0f0f53b7  # lui x7, 0xf0f5
.4byte 0x5aa38393  # addi x7, x7, 1450
.4byte 0x0683ca57  # vandn.vx v20, v8, x7
.assert trap == 0 "vandn.vx e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vandn.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vandn.vx e32 lane 0"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vandn.vx e32 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e32 lane 4 writes x10"
.assert rd_wdata == 0x10300250 "vandn.vx e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e32 lane 5 writes x10"
.assert rd_wdata == 0xffffffffa0500a14 "vandn.vx e32 lane 5"
.4byte 0x4a842a57  # vbrev8.v v20, v8
.assert trap == 0 "vbrev8.v e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vbrev8.v e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vbrev8.v e32 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vbrev8.v e32 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e32 lane 2 writes x10"
.assert rd_wdata == 0x1000000 "vbrev8.v e32 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e32 lane 3 writes x10"
.assert rd_wdata == 0x80 "vbrev8.v e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e32 lane 4 writes x10"
.assert rd_wdata == 0x482c6a1e "vbrev8.v e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e32 lane 5 writes x10"
.assert rd_wdata == 0xffffffffa55af078 "vbrev8.v e32 lane 5"
.4byte 0x4a84aa57  # vrev8.v v20, v8
.assert trap == 0 "vrev8.v e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vrev8.v e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vrev8.v e32 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vrev8.v e32 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e32 lane 2 writes x10"
.assert rd_wdata == 0x80 "vrev8.v e32 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e32 lane 3 writes x10"
.assert rd_wdata == 0x1000000 "vrev8.v e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e32 lane 4 writes x10"
.assert rd_wdata == 0x78563412 "vrev8.v e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e32 lane 5 writes x10"
.assert rd_wdata == 0x1e0f5aa5 "vrev8.v e32 lane 5"
.4byte 0x4a852a57  # vbrev.v v20, v8
.assert trap == 0 "vbrev.v e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vbrev.v e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vbrev.v e32 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vbrev.v e32 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e32 lane 2 writes x10"
.assert rd_wdata == 0x1 "vbrev.v e32 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e32 lane 3 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vbrev.v e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e32 lane 4 writes x10"
.assert rd_wdata == 0x1e6a2c48 "vbrev.v e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e32 lane 5 writes x10"
.assert rd_wdata == 0x78f05aa5 "vbrev.v e32 lane 5"
.4byte 0x4a862a57  # vclz.v v20, v8
.assert trap == 0 "vclz.v e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vclz.v e32 lane 0 writes x10"
.assert rd_wdata == 0x20 "vclz.v e32 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e32 lane 1 writes x10"
.assert rd_wdata == 0x0 "vclz.v e32 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e32 lane 2 writes x10"
.assert rd_wdata == 0x0 "vclz.v e32 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e32 lane 3 writes x10"
.assert rd_wdata == 0x1f "vclz.v e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e32 lane 4 writes x10"
.assert rd_wdata == 0x3 "vclz.v e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e32 lane 5 writes x10"
.assert rd_wdata == 0x0 "vclz.v e32 lane 5"
.4byte 0x4a86aa57  # vctz.v v20, v8
.assert trap == 0 "vctz.v e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vctz.v e32 lane 0 writes x10"
.assert rd_wdata == 0x20 "vctz.v e32 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e32 lane 1 writes x10"
.assert rd_wdata == 0x0 "vctz.v e32 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e32 lane 2 writes x10"
.assert rd_wdata == 0x1f "vctz.v e32 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e32 lane 3 writes x10"
.assert rd_wdata == 0x0 "vctz.v e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e32 lane 4 writes x10"
.assert rd_wdata == 0x3 "vctz.v e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e32 lane 5 writes x10"
.assert rd_wdata == 0x1 "vctz.v e32 lane 5"
.4byte 0x4a872a57  # vcpop.v v20, v8
.assert trap == 0 "vcpop.v e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vcpop.v e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vcpop.v e32 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e32 lane 1 writes x10"
.assert rd_wdata == 0x20 "vcpop.v e32 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e32 lane 2 writes x10"
.assert rd_wdata == 0x1 "vcpop.v e32 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e32 lane 3 writes x10"
.assert rd_wdata == 0x1 "vcpop.v e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e32 lane 4 writes x10"
.assert rd_wdata == 0xd "vcpop.v e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e32 lane 5 writes x10"
.assert rd_wdata == 0x10 "vcpop.v e32 lane 5"
.4byte 0x56880a57  # vrol.vv v20, v8, v16
.assert trap == 0 "vrol.vv e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vrol.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vrol.vv e32 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vrol.vv e32 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x40000000 "vrol.vv e32 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e32 lane 3 writes x10"
.assert rd_wdata == 0x8 "vrol.vv e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e32 lane 4 writes x10"
.assert rd_wdata == 0x1a2b3c09 "vrol.vv e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e32 lane 5 writes x10"
.assert rd_wdata == 0xffffffffad078f52 "vrol.vv e32 lane 5"
.4byte 0x02700393  # addi x7, x0, 39
.4byte 0x5683ca57  # vrol.vx v20, v8, x7
.assert trap == 0 "vrol.vx e32 retires"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x40 "vrol.vx e32 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e32 lane 4 writes x10"
.assert rd_wdata == 0x1a2b3c09 "vrol.vx e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e32 lane 5 writes x10"
.assert rd_wdata == 0xffffffffad078f52 "vrol.vx e32 lane 5"
.4byte 0x52880a57  # vror.vv v20, v8, v16
.assert trap == 0 "vror.vv e32 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vror.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vror.vv e32 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vror.vv e32 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x1 "vror.vv e32 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e32 lane 3 writes x10"
.assert rd_wdata == 0x20000000 "vror.vv e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e32 lane 4 writes x10"
.assert rd_wdata == 0xfffffffff02468ac "vror.vv e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e32 lane 5 writes x10"
.assert rd_wdata == 0x3d4ab41e "vror.vv e32 lane 5"
.4byte 0x5283ca57  # vror.vx v20, v8, x7
.assert trap == 0 "vror.vx e32 retires"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x1000000 "vror.vx e32 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e32 lane 4 writes x10"
.assert rd_wdata == 0xfffffffff02468ac "vror.vx e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e32 lane 5 writes x10"
.assert rd_wdata == 0x3d4ab41e "vror.vx e32 lane 5"
.4byte 0x5283ba57  # vror.vi v20, v8, 7
.assert trap == 0 "vror.vi imm5=0 e32 retires"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e32 lane 3 writes x10"
.assert rd_wdata == 0x2000000 "vror.vi lo e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e32 lane 4 writes x10"
.assert rd_wdata == 0xfffffffff02468ac "vror.vi lo e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e32 lane 5 writes x10"
.assert rd_wdata == 0x3d4ab41e "vror.vi lo e32 lane 5"
.4byte 0x5683ba57  # vror.vi v20, v8, 39
.assert trap == 0 "vror.vi imm5=1 e32 retires"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e32 lane 3 writes x10"
.assert rd_wdata == 0x2000000 "vror.vi hi e32 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e32 lane 4 writes x10"
.assert rd_wdata == 0xfffffffff02468ac "vror.vi hi e32 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e32 lane 5 writes x10"
.assert rd_wdata == 0x3d4ab41e "vror.vi hi e32 lane 5"

# Section 2.64: Single-width Zvbb ops at SEW=64, m4, vl=6.
.4byte 0xc1a37657  # vsetivli x12, 6, e64, m4, tu, mu
.assert rd_addr == 12 "vsetivli e64 m4 vl=6 writes x12"
.assert rd_wdata == 0x6 "vsetivli e64 m4 vl=6"
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x00100313  # addi x6, x0, 1
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x012342b7  # lui x5, 0x1234
.4byte 0x56728293  # addi x5, x5, 1383
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x89abd337  # lui x6, 0x89abd
.4byte 0xdef30313  # addi x6, x6, -529
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x40000293  # addi x5, x0, 1024
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x008002b7  # lui x5, 0x800
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xfff00293  # addi x5, x0, -1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x0f0f02b7  # lui x5, 0xf0f0
.4byte 0x0ff28293  # addi x5, x5, 255
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x00ff1337  # lui x6, 0xff1
.4byte 0xf0f30313  # addi x6, x6, -241
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xfff28293  # addi x5, x5, -1
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x00010337  # lui x6, 0x10
.4byte 0xfff30313  # addi x6, x6, -1
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xffff02b7  # lui x5, 0xffff0
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x00010337  # lui x6, 0x10
.4byte 0xfff30313  # addi x6, x6, -1
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0f0f12b7  # lui x5, 0xf0f1
.4byte 0xf0f28293  # addi x5, x5, -241
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x0f0f1337  # lui x6, 0xf0f1
.4byte 0xf0f30313  # addi x6, x6, -241
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00ff02b7  # lui x5, 0xff0
.4byte 0x0ff28293  # addi x5, x5, 255
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x00ff0337  # lui x6, 0xff0
.4byte 0x0ff30313  # addi x6, x6, 255
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x02000293  # addi x5, x0, 32
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x04500293  # addi x5, x0, 69
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x02300293  # addi x5, x0, 35
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x03f00293  # addi x5, x0, 63
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x06860a57  # vandn.vv v20, v8, v12
.assert trap == 0 "vandn.vv e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vandn.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vandn.vv e64 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e64 lane 1 writes x10"
.assert rd_wdata == 0xf0f0f0f0f0f0f0f0 "vandn.vv e64 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e64 lane 2 writes x10"
.assert rd_wdata == 0x800000 "vandn.vv e64 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e64 lane 3 writes x10"
.assert rd_wdata == 0x0 "vandn.vv e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e64 lane 4 writes x10"
.assert rd_wdata == 0x2045008900c0e0 "vandn.vv e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vv e64 lane 5 writes x10"
.assert rd_wdata == 0x1 "vandn.vv e64 lane 5"
.4byte 0x0f0f53b7  # lui x7, 0xf0f5
.4byte 0x5aa38393  # addi x7, x7, 1450
.4byte 0x02039393  # slli x7, x7, 32
.4byte 0x33cc1337  # lui x6, 0x33cc1
.4byte 0x12230313  # addi x6, x6, 290
.4byte 0x0063e3b3  # or x7, x7, x6
.4byte 0x0683ca57  # vandn.vx v20, v8, x7
.assert trap == 0 "vandn.vx e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vandn.vx e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vandn.vx e64 lane 0"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e64 lane 2 writes x10"
.assert rd_wdata == 0x0 "vandn.vx e64 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e64 lane 4 writes x10"
.assert rd_wdata == 0x2000458823cccd "vandn.vx e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vandn.vx e64 lane 5 writes x10"
.assert rd_wdata == 0x8000000000000001 "vandn.vx e64 lane 5"
.4byte 0x4a842a57  # vbrev8.v v20, v8
.assert trap == 0 "vbrev8.v e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vbrev8.v e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vbrev8.v e64 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vbrev8.v e64 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e64 lane 2 writes x10"
.assert rd_wdata == 0x10000 "vbrev8.v e64 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e64 lane 3 writes x10"
.assert rd_wdata == 0x200000000000 "vbrev8.v e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e64 lane 4 writes x10"
.assert rd_wdata == 0x80c4a2e691d5b3f7 "vbrev8.v e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev8.v e64 lane 5 writes x10"
.assert rd_wdata == 0x100000000000080 "vbrev8.v e64 lane 5"
.4byte 0x4a84aa57  # vrev8.v v20, v8
.assert trap == 0 "vrev8.v e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vrev8.v e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vrev8.v e64 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vrev8.v e64 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e64 lane 2 writes x10"
.assert rd_wdata == 0x800000000000 "vrev8.v e64 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e64 lane 3 writes x10"
.assert rd_wdata == 0x40000 "vrev8.v e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e64 lane 4 writes x10"
.assert rd_wdata == 0xefcdab8967452301 "vrev8.v e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrev8.v e64 lane 5 writes x10"
.assert rd_wdata == 0x100000000000080 "vrev8.v e64 lane 5"
.4byte 0x4a852a57  # vbrev.v v20, v8
.assert trap == 0 "vbrev.v e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vbrev.v e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vbrev.v e64 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vbrev.v e64 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e64 lane 2 writes x10"
.assert rd_wdata == 0x10000000000 "vbrev.v e64 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e64 lane 3 writes x10"
.assert rd_wdata == 0x200000 "vbrev.v e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e64 lane 4 writes x10"
.assert rd_wdata == 0xf7b3d591e6a2c480 "vbrev.v e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vbrev.v e64 lane 5 writes x10"
.assert rd_wdata == 0x8000000000000001 "vbrev.v e64 lane 5"
.4byte 0x4a862a57  # vclz.v v20, v8
.assert trap == 0 "vclz.v e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vclz.v e64 lane 0 writes x10"
.assert rd_wdata == 0x40 "vclz.v e64 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e64 lane 1 writes x10"
.assert rd_wdata == 0x0 "vclz.v e64 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e64 lane 2 writes x10"
.assert rd_wdata == 0x28 "vclz.v e64 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e64 lane 3 writes x10"
.assert rd_wdata == 0x15 "vclz.v e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e64 lane 4 writes x10"
.assert rd_wdata == 0x7 "vclz.v e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclz.v e64 lane 5 writes x10"
.assert rd_wdata == 0x0 "vclz.v e64 lane 5"
.4byte 0x4a86aa57  # vctz.v v20, v8
.assert trap == 0 "vctz.v e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vctz.v e64 lane 0 writes x10"
.assert rd_wdata == 0x40 "vctz.v e64 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e64 lane 1 writes x10"
.assert rd_wdata == 0x0 "vctz.v e64 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e64 lane 2 writes x10"
.assert rd_wdata == 0x17 "vctz.v e64 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e64 lane 3 writes x10"
.assert rd_wdata == 0x2a "vctz.v e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e64 lane 4 writes x10"
.assert rd_wdata == 0x0 "vctz.v e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vctz.v e64 lane 5 writes x10"
.assert rd_wdata == 0x0 "vctz.v e64 lane 5"
.4byte 0x4a872a57  # vcpop.v v20, v8
.assert trap == 0 "vcpop.v e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vcpop.v e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vcpop.v e64 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e64 lane 1 writes x10"
.assert rd_wdata == 0x40 "vcpop.v e64 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e64 lane 2 writes x10"
.assert rd_wdata == 0x1 "vcpop.v e64 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e64 lane 3 writes x10"
.assert rd_wdata == 0x1 "vcpop.v e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e64 lane 4 writes x10"
.assert rd_wdata == 0x20 "vcpop.v e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vcpop.v e64 lane 5 writes x10"
.assert rd_wdata == 0x2 "vcpop.v e64 lane 5"
.4byte 0x56880a57  # vrol.vv v20, v8, v16
.assert trap == 0 "vrol.vv e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vrol.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vrol.vv e64 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vrol.vv e64 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e64 lane 2 writes x10"
.assert rd_wdata == 0x400000 "vrol.vv e64 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e64 lane 3 writes x10"
.assert rd_wdata == 0x2000 "vrol.vv e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e64 lane 4 writes x10"
.assert rd_wdata == 0x2468acf13579bde0 "vrol.vv e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vv e64 lane 5 writes x10"
.assert rd_wdata == 0x180000000 "vrol.vv e64 lane 5"
.4byte 0x02500393  # addi x7, x0, 37
.4byte 0x5683ca57  # vrol.vx v20, v8, x7
.assert trap == 0 "vrol.vx e64 retires"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e64 lane 2 writes x10"
.assert rd_wdata == 0x1000000000000000 "vrol.vx e64 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e64 lane 4 writes x10"
.assert rd_wdata == 0x3579bde02468acf1 "vrol.vx e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vrol.vx e64 lane 5 writes x10"
.assert rd_wdata == 0x3000000000 "vrol.vx e64 lane 5"
.4byte 0x52880a57  # vror.vv v20, v8, v16
.assert trap == 0 "vror.vv e64 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vror.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vror.vv e64 lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vror.vv e64 lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e64 lane 2 writes x10"
.assert rd_wdata == 0x1000000 "vror.vv e64 lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e64 lane 3 writes x10"
.assert rd_wdata == 0x80 "vror.vv e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e64 lane 4 writes x10"
.assert rd_wdata == 0x78091a2b3c4d5e6f "vror.vv e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vv e64 lane 5 writes x10"
.assert rd_wdata == 0x180000000 "vror.vv e64 lane 5"
.4byte 0x5283ca57  # vror.vx v20, v8, x7
.assert trap == 0 "vror.vx e64 retires"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e64 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000 "vror.vx e64 lane 2"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e64 lane 4 writes x10"
.assert rd_wdata == 0x3c4d5e6f78091a2b "vror.vx e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vx e64 lane 5 writes x10"
.assert rd_wdata == 0xc000000 "vror.vx e64 lane 5"
.4byte 0x5282ba57  # vror.vi v20, v8, 5
.assert trap == 0 "vror.vi imm5=0 e64 retires"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e64 lane 3 writes x10"
.assert rd_wdata == 0x2000000000 "vror.vi lo e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e64 lane 4 writes x10"
.assert rd_wdata == 0x78091a2b3c4d5e6f "vror.vi lo e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi lo e64 lane 5 writes x10"
.assert rd_wdata == 0xc00000000000000 "vror.vi lo e64 lane 5"
.4byte 0x5682ba57  # vror.vi v20, v8, 37
.assert trap == 0 "vror.vi imm5=1 e64 retires"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e64 lane 3 writes x10"
.assert rd_wdata == 0x20 "vror.vi hi e64 lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e64 lane 4 writes x10"
.assert rd_wdata == 0x3c4d5e6f78091a2b "vror.vi hi e64 lane 4"
.4byte 0x3f42bc57  # vslidedown.vi v24, v20, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vror.vi hi e64 lane 5 writes x10"
.assert rd_wdata == 0xc000000 "vror.vi hi e64 lane 5"

# Section 3.8: vwsll.vv/.vx/.vi at SEW=8 -> EEW=16 (m1->m2).
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x05a00293  # addi x5, x0, 90
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0ff00293  # addi x5, x0, 255
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x08100293  # addi x5, x0, 129
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x01300293  # addi x5, x0, 19
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x00800293  # addi x5, x0, 8
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00700293  # addi x5, x0, 7
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xd6860857  # vwsll.vv v16, v8, v12
.assert trap == 0 "vwsll.vv e8 retires"
.4byte 0xc0927657  # vsetivli x12, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x81 "vwsll.vv e8 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x7f80 "vwsll.vv e8 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x5a00 "vwsll.vv e8 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vv e8 lane 3 writes x10"
.assert rd_wdata == 0x8 "vwsll.vv e8 lane 3"
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0x01900393  # addi x7, x0, 25
.4byte 0xd683c857  # vwsll.vx v16, v8, x7
.assert trap == 0 "vwsll.vx e8 retires"
.4byte 0xc0927657  # vsetivli x12, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x200 "vwsll.vx e8 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffe00 "vwsll.vx e8 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffb400 "vwsll.vx e8 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vx e8 lane 3 writes x10"
.assert rd_wdata == 0x200 "vwsll.vx e8 lane 3"
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0xd687b857  # vwsll.vi v16, v8, 15
.assert trap == 0 "vwsll.vi e8 retires"
.4byte 0xc0927657  # vsetivli x12, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vi e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vwsll.vi e8 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vwsll.vi e8 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi e8 lane 2 writes x10"
.assert rd_wdata == 0x0 "vwsll.vi e8 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi e8 lane 3 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vwsll.vi e8 lane 3"
# Section 3.16: vwsll.vv/.vx/.vi at SEW=16 -> EEW=32 (m1->m2).
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x0000a2b7  # lui x5, 0xa
.4byte 0x55a28293  # addi x5, x5, 1370
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x23428293  # addi x5, x5, 564
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xfff28293  # addi x5, x5, -1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x02300293  # addi x5, x0, 35
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x01000293  # addi x5, x0, 16
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00f00293  # addi x5, x0, 15
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xd6860857  # vwsll.vv v16, v8, v12
.assert trap == 0 "vwsll.vv e16 retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x8001 "vwsll.vv e16 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x7fff8000 "vwsll.vv e16 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vv e16 lane 2 writes x10"
.assert rd_wdata == 0x12340000 "vwsll.vv e16 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vv e16 lane 3 writes x10"
.assert rd_wdata == 0x52ad0 "vwsll.vv e16 lane 3"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x03100393  # addi x7, x0, 49
.4byte 0xd683c857  # vwsll.vx v16, v8, x7
.assert trap == 0 "vwsll.vx e16 retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x20000 "vwsll.vx e16 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vx e16 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffe0000 "vwsll.vx e16 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vx e16 lane 2 writes x10"
.assert rd_wdata == 0x24680000 "vwsll.vx e16 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vx e16 lane 3 writes x10"
.assert rd_wdata == 0x4ab40000 "vwsll.vx e16 lane 3"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xd68fb857  # vwsll.vi v16, v8, 31
.assert trap == 0 "vwsll.vi e16 retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vi e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vwsll.vi e16 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vwsll.vi e16 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi e16 lane 2 writes x10"
.assert rd_wdata == 0x0 "vwsll.vi e16 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi e16 lane 3 writes x10"
.assert rd_wdata == 0x0 "vwsll.vi e16 lane 3"
# Section 3.32: vwsll.vv/.vx/.vi at SEW=32 -> EEW=64 (m1->m2).
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0xa55a12b7  # lui x5, 0xa55a1
.4byte 0xf1e28293  # addi x5, x5, -226
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x123452b7  # lui x5, 0x12345
.4byte 0x67828293  # addi x5, x5, 1656
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xfff00293  # addi x5, x0, -1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x04300293  # addi x5, x0, 67
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x02000293  # addi x5, x0, 32
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x01f00293  # addi x5, x0, 31
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xd6860857  # vwsll.vv v16, v8, v12
.assert trap == 0 "vwsll.vv e32 retires"
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x80000001 "vwsll.vv e32 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff80000000 "vwsll.vv e32 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x1234567800000000 "vwsll.vv e32 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vv e32 lane 3 writes x10"
.assert rd_wdata == 0x52ad078f0 "vwsll.vv e32 lane 3"
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0x06300393  # addi x7, x0, 99
.4byte 0xd683c857  # vwsll.vx v16, v8, x7
.assert trap == 0 "vwsll.vx e32 retires"
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x800000000 "vwsll.vx e32 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vx e32 lane 1 writes x10"
.assert rd_wdata == 0xfffffff800000000 "vwsll.vx e32 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x91a2b3c000000000 "vwsll.vx e32 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vx e32 lane 3 writes x10"
.assert rd_wdata == 0x2ad078f000000000 "vwsll.vx e32 lane 3"
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0xd68fb857  # vwsll.vi v16, v8, 31
.assert trap == 0 "vwsll.vi e32 retires"
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vi e32 lane 0 writes x10"
.assert rd_wdata == 0x4000000080000000 "vwsll.vi e32 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff80000000 "vwsll.vi e32 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi e32 lane 2 writes x10"
.assert rd_wdata == 0x91a2b3c00000000 "vwsll.vi e32 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi e32 lane 3 writes x10"
.assert rd_wdata == 0x52ad078f00000000 "vwsll.vi e32 lane 3"

# Section 4: Masked tu/mu and ta/ma, tails, vl=0, VLMAX mf8..m8, legal overlaps.
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x00500293  # addi x5, x0, 5
.4byte 0x5e02c057  # vmv.v.x v0, x5
.4byte 0x01107fd7  # vsetvli x31, x0, e32, m2, tu, mu
.4byte 0x55aa12b7  # lui x5, 0x55aa1
.4byte 0x23428293  # addi x5, x5, 564
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0xdead12b7  # lui x5, 0xdead1
.4byte 0x0cc28293  # addi x5, x5, 204
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xcafec2b7  # lui x5, 0xcafec
.4byte 0xabe28293  # addi x5, x5, -1346
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x9abce2b7  # lui x5, 0x9abce
.4byte 0xef028293  # addi x5, x5, -272
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x123452b7  # lui x5, 0x12345
.4byte 0x67828293  # addi x5, x5, 1656
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xfff00293  # addi x5, x0, -1
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x00ff02b7  # lui x5, 0xff0
.4byte 0x0ff28293  # addi x5, x5, 255
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xfff00293  # addi x5, x0, -1
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0f0f12b7  # lui x5, 0xf0f1
.4byte 0xf0f28293  # addi x5, x5, -241
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x04860a57  # vandn.vv v20, v8, v12, v0.t
.assert trap == 0 "masked vandn.vv tu/mu retires"
.4byte 0xc112f657  # vsetivli x12, 5, e32, m2, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "masked vandn.vv active lane 0 writes x10"
.assert rd_wdata == 0x10305070 "masked vandn.vv active lane 0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vandn.vv mu inactive lane 1 writes x10"
.assert rd_wdata == 0x55aa1234 "masked vandn.vv mu inactive lane 1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vandn.vv active lane 2 writes x10"
.assert rd_wdata == 0xffffffffca00ba00 "masked vandn.vv active lane 2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vandn.vv mu inactive lane 3 writes x10"
.assert rd_wdata == 0x55aa1234 "masked vandn.vv mu inactive lane 3"
.4byte 0x3f423c57  # vslidedown.vi v24, v20, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vandn.vv tu tail lane 4 writes x10"
.assert rd_wdata == 0x55aa1234 "masked vandn.vv tu tail lane 4"
.4byte 0xcd127657  # vsetivli x12, 4, e32, m2, ta, ma
.4byte 0x4884aa57  # vrev8.v v20, v8, v0.t
.assert trap == 0 "masked vrev8.v ta/ma retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "masked vrev8.v ta/ma active lane 0 writes x10"
.assert rd_wdata == 0x78563412 "masked vrev8.v ta/ma active lane 0"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vrev8.v ta/ma active lane 2 writes x10"
.assert rd_wdata == 0xffffffffbebafeca "masked vrev8.v ta/ma active lane 2"
.4byte 0x01107fd7  # vsetvli x31, x0, e32, m2, tu, mu
.4byte 0x3366a2b7  # lui x5, 0x3366a
.4byte 0x9cc28293  # addi x5, x5, -1588
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000052b7  # lui x5, 0x5
.4byte 0x67828293  # addi x5, x5, 1656
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x23428293  # addi x5, x5, 564
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xfff28293  # addi x5, x5, -1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x01000293  # addi x5, x0, 16
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x00c00293  # addi x5, x0, 12
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00800293  # addi x5, x0, 8
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00400293  # addi x5, x0, 4
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xd4860857  # vwsll.vv v16, v8, v12, v0.t
.assert trap == 0 "masked vwsll.vv tu/mu retires"
.4byte 0xc112f657  # vsetivli x12, 5, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "masked vwsll.vv active lane 0 writes x10"
.assert rd_wdata == 0x80010 "masked vwsll.vv active lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vwsll.vv mu inactive lane 1 writes x10"
.assert rd_wdata == 0x336699cc "masked vwsll.vv mu inactive lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vwsll.vv active lane 2 writes x10"
.assert rd_wdata == 0x1234000 "masked vwsll.vv active lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vwsll.vv mu inactive lane 3 writes x10"
.assert rd_wdata == 0x336699cc "masked vwsll.vv mu inactive lane 3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vwsll.vv tu tail lane 4 writes x10"
.assert rd_wdata == 0x336699cc "masked vwsll.vv tu tail lane 4"
.4byte 0xcc807657  # vsetivli x12, 0, e16, m1, ta, ma
.assert rd_addr == 12 "vl=0 writes x12"
.assert rd_wdata == 0x0 "vl=0"
.4byte 0x06860857  # vandn.vv v16, v8, v12
.assert trap == 0 "vandn.vv vl=0 retires"
.4byte 0x4a852857  # vbrev.v v16, v8
.assert trap == 0 "vbrev.v vl=0 retires"
.4byte 0x5682b857  # vror.vi v16, v8, 37
.assert trap == 0 "vror.vi vl=0 retires"
.4byte 0xd6860857  # vwsll.vv v16, v8, v12
.assert trap == 0 "vwsll.vv vl=0 retires"
.4byte 0xc110f657  # vsetivli x12, 1, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vl=0 leaves v16 unchanged writes x10"
.assert rd_wdata == 0x80010 "vl=0 leaves v16 unchanged"
# Portable VLMAX sweeps across mf8..m8 (single-width) and mf8..m4 (vwsll).
.4byte 0x00507fd7  # vsetvli x31, x0, e8, mf8, tu, mu
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x35728293  # addi x5, x5, 855
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x4a84a857  # vrev8.v v16, v8
.assert trap == 0 "vrev8.v VLMAX e8 mf8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vrev8.v VLMAX e8 mf8 lane 0 writes x10"
.assert rd_wdata == 0x57 "vrev8.v VLMAX e8 mf8 lane 0"
.4byte 0x00607fd7  # vsetvli x31, x0, e8, mf4, tu, mu
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x35728293  # addi x5, x5, 855
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x4a84a857  # vrev8.v v16, v8
.assert trap == 0 "vrev8.v VLMAX e8 mf4 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vrev8.v VLMAX e8 mf4 lane 0 writes x10"
.assert rd_wdata == 0x57 "vrev8.v VLMAX e8 mf4 lane 0"
.4byte 0x00f07fd7  # vsetvli x31, x0, e16, mf2, tu, mu
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x35728293  # addi x5, x5, 855
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x4a84a857  # vrev8.v v16, v8
.assert trap == 0 "vrev8.v VLMAX e16 mf2 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vrev8.v VLMAX e16 mf2 lane 0 writes x10"
.assert rd_wdata == 0x5713 "vrev8.v VLMAX e16 mf2 lane 0"
.4byte 0x01007fd7  # vsetvli x31, x0, e32, m1, tu, mu
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x35728293  # addi x5, x5, 855
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x4a84a857  # vrev8.v v16, v8
.assert trap == 0 "vrev8.v VLMAX e32 m1 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vrev8.v VLMAX e32 m1 lane 0 writes x10"
.assert rd_wdata == 0x57130000 "vrev8.v VLMAX e32 m1 lane 0"
.4byte 0x01107fd7  # vsetvli x31, x0, e32, m2, tu, mu
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x35728293  # addi x5, x5, 855
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x4a84a857  # vrev8.v v16, v8
.assert trap == 0 "vrev8.v VLMAX e32 m2 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vrev8.v VLMAX e32 m2 lane 0 writes x10"
.assert rd_wdata == 0x57130000 "vrev8.v VLMAX e32 m2 lane 0"
.4byte 0x01207fd7  # vsetvli x31, x0, e32, m4, tu, mu
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x35728293  # addi x5, x5, 855
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x4a84a857  # vrev8.v v16, v8
.assert trap == 0 "vrev8.v VLMAX e32 m4 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vrev8.v VLMAX e32 m4 lane 0 writes x10"
.assert rd_wdata == 0x57130000 "vrev8.v VLMAX e32 m4 lane 0"
.4byte 0x01b07fd7  # vsetvli x31, x0, e64, m8, tu, mu
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x35728293  # addi x5, x5, 855
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x4a84a857  # vrev8.v v16, v8
.assert trap == 0 "vrev8.v VLMAX e64 m8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vrev8.v VLMAX e64 m8 lane 0 writes x10"
.assert rd_wdata == 0x5713000000000000 "vrev8.v VLMAX e64 m8 lane 0"
.4byte 0x00507fd7  # vsetvli x31, x0, e8, mf8, tu, mu
.4byte 0x02b00293  # addi x5, x0, 43
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xd682b857  # vwsll.vi v16, v8, 5
.assert trap == 0 "vwsll.vi VLMAX e8 mf8 retires"
.4byte 0xc080f657  # vsetivli x12, 1, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vi VLMAX e8 mf8 lane 0 writes x10"
.assert rd_wdata == 0x560 "vwsll.vi VLMAX e8 mf8 lane 0"
.4byte 0x00607fd7  # vsetvli x31, x0, e8, mf4, tu, mu
.4byte 0x02b00293  # addi x5, x0, 43
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xd682b857  # vwsll.vi v16, v8, 5
.assert trap == 0 "vwsll.vi VLMAX e8 mf4 retires"
.4byte 0xc080f657  # vsetivli x12, 1, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vi VLMAX e8 mf4 lane 0 writes x10"
.assert rd_wdata == 0x560 "vwsll.vi VLMAX e8 mf4 lane 0"
.4byte 0x00f07fd7  # vsetvli x31, x0, e16, mf2, tu, mu
.4byte 0x02b00293  # addi x5, x0, 43
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xd682b857  # vwsll.vi v16, v8, 5
.assert trap == 0 "vwsll.vi VLMAX e16 mf2 retires"
.4byte 0xc100f657  # vsetivli x12, 1, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vi VLMAX e16 mf2 lane 0 writes x10"
.assert rd_wdata == 0x560 "vwsll.vi VLMAX e16 mf2 lane 0"
.4byte 0x01207fd7  # vsetvli x31, x0, e32, m4, tu, mu
.4byte 0x02b00293  # addi x5, x0, 43
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xd682b857  # vwsll.vi v16, v8, 5
.assert trap == 0 "vwsll.vi VLMAX e32 m4 retires"
.4byte 0xc180f657  # vsetivli x12, 1, e64, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vi VLMAX e32 m4 lane 0 writes x10"
.assert rd_wdata == 0x560 "vwsll.vi VLMAX e32 m4 lane 0"
# Legal overlaps: in-place vrev8.v/vrol.vv and vwsll.vi upper-half overlap v16<-v17.
.4byte 0xc1017657  # vsetivli x12, 2, e32, m1, tu, mu
.4byte 0x556672b7  # lui x5, 0x55667
.4byte 0x78828293  # addi x5, x5, 1928
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0x112232b7  # lui x5, 0x11223
.4byte 0x34428293  # addi x5, x5, 836
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x4b44aa57  # vrev8.v v20, v20
.assert trap == 0 "in-place vrev8.v v20, v20 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "in-place vrev8.v lane 0 writes x10"
.assert rd_wdata == 0x44332211 "in-place vrev8.v lane 0"
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x0000b2b7  # lui x5, 0xb
.4byte 0xbcd28293  # addi x5, x5, -1075
.4byte 0x5e02c8d7  # vmv.v.x v17, x5
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x23428293  # addi x5, x5, 564
.4byte 0x3b12ee57  # vslide1up.vx v28, v17, x5
.4byte 0x5e0e08d7  # vmv.v.v v17, v28
.4byte 0xd7123857  # vwsll.vi v16, v17, 4
.assert trap == 0 "legal upper-half overlap vwsll.vi v16, v17, 4 retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vwsll.vi upper-half overlap lane 0 writes x10"
.assert rd_wdata == 0x12340 "vwsll.vi upper-half overlap lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vwsll.vi upper-half overlap lane 1 writes x10"
.assert rd_wdata == 0xabcd0 "vwsll.vi upper-half overlap lane 1"

# Section 5: Illegal Zvbb traps (vwsll SEW=64/EMUL=16/overlaps, masked v0, align, vill).
.4byte 0xc1817657  # vsetivli x12, 2, e64, m1, tu, mu
.4byte 0xd6860857  # vwsll.vv v16, v8, v12
.assert trap == 1 "vwsll.vv at e64 traps"
.4byte 0xd682c857  # vwsll.vx v16, v8, x5
.assert trap == 1 "vwsll.vx at e64 traps"
.4byte 0xd680b857  # vwsll.vi v16, v8, 1
.assert trap == 1 "vwsll.vi at e64 traps"
.4byte 0xc1327657  # vsetivli x12, 4, e32, m8, tu, mu
.4byte 0xd68c0857  # vwsll.vv v16, v8, v24
.assert trap == 1 "vwsll.vv at m8 traps"
.4byte 0xd680b857  # vwsll.vi v16, v8, 1
.assert trap == 1 "vwsll.vi at m8 traps"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xd68608d7  # vwsll.vv v17, v8, v12
.assert trap == 1 "vwsll.vv odd vd at m1->m2 traps"
.4byte 0xd7060857  # vwsll.vv v16, v16, v12
.assert trap == 1 "vwsll.vv lower-half overlap vd==vs2 traps"
.4byte 0xd6880857  # vwsll.vv v16, v8, v16
.assert trap == 1 "vwsll.vv lower-half overlap vd==vs1 traps"
.4byte 0xc0717657  # vsetivli x12, 2, e8, mf2, tu, mu
.4byte 0xd700b857  # vwsll.vi v16, v16, 1
.assert trap == 1 "vwsll.vi fractional overlap vd==vs2 traps"
.4byte 0xc1017657  # vsetivli x12, 2, e32, m1, tu, mu
.4byte 0x04860057  # vandn.vv v0, v8, v12, v0.t
.assert trap == 1 "masked vandn.vv vd==v0 traps"
.4byte 0x4884a057  # vrev8.v v0, v8, v0.t
.assert trap == 1 "masked vrev8.v vd==v0 traps"
.4byte 0x5001b457  # vror.vi v8, v0, 3, v0.t
.assert trap == 1 "masked vror.vi vs2==v0 traps"
.4byte 0xd4860057  # vwsll.vv v0, v8, v12, v0.t
.assert trap == 1 "masked vwsll.vv vd==v0 traps"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x068601d7  # vandn.vv v3, v8, v12
.assert trap == 1 "vandn.vv misaligned vd at m2 traps"
.4byte 0x4a952457  # vbrev.v v8, v9
.assert trap == 1 "vbrev.v misaligned vs2 at m2 traps"
.4byte 0x56c68457  # vrol.vv v8, v12, v13
.assert trap == 1 "vrol.vv misaligned vs1 at m2 traps"
.4byte 0xc2027657  # vsetivli x12, 4, reserved_sew4 (sets vill)
.4byte 0x06c80457  # vandn.vv v8, v12, v16
.assert trap == 1 "vandn.vv under vill traps"
.4byte 0x4ac4a457  # vrev8.v v8, v12
.assert trap == 1 "vrev8.v under vill traps"
.4byte 0x56c0b457  # vror.vi v8, v12, 33
.assert trap == 1 "vror.vi under vill traps"
.4byte 0xd6860857  # vwsll.vv v16, v8, v12
.assert trap == 1 "vwsll.vv under vill traps"
