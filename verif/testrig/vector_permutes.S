# Directed TestRIG trace for base-V permute instructions (17 encodings):
# vslideup.{vx,vi}, vslidedown.{vx,vi}, vslide1up.vx, vslide1down.vx,
# vfslide1up.vf, vfslide1down.vf, vrgather.{vv,vx,vi}, vrgatherei16.vv,
# vcompress.vm, and vmv{1,2,4,8}r.v. Run with --vlen 128, 256 or 512.
.noshrink
# Enable FP and vector state, zero v0..v31, clear fflags/frm
.4byte 0x000062b7  # lui t0, 6
.4byte 0x60028293  # addi t0, t0, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x00205073  # csrwi frm, 0

# Section 1: Control anchor (unique vmv.x.s a0, v11 = 0x42b02557)
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e04b257  # vmv.v.i v4, 9
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0x2468b337  # lui t1, 0x2468b
.4byte 0xce030313  # addi t1, t1, -800
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "ctrl vl=4 writes a2"
.assert rd_wdata == 0x4 "ctrl vl=4"
.4byte 0x3a4365d7  # vslide1up.vx v11, v4, t1
.assert trap == 0 "ctrl vslide1up.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "ctrl vslide1up.vx lane 0 writes a0"
.assert rd_wdata == 0x2468ace0 "ctrl vslide1up.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3eb0b657  # vslidedown.vi v12, v11, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "ctrl vslide1up.vx lane 1 writes a0"
.assert rd_wdata == 0x3 "ctrl vslide1up.vx lane 1"

# Section 2: vslideup.{vx,vi} and vslidedown.{vx,vi} across e8/e16/e32/e64
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x3a413457  # vslideup.vi v8, v4, 2
.assert trap == 0 "vslideup.vi e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vi e8 prefix lane 0 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vi e8 prefix lane 0 untouched"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e8 prefix lane 1 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslideup.vi e8 prefix lane 1 untouched"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e8 shifted lane 2 writes a0"
.assert rd_wdata == 0x3 "vslideup.vi e8 shifted lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e8 tail lane 3 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslideup.vi e8 tail lane 3 untouched"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x38434457  # vslideup.vx v8, v4, t1, v0.t
.assert trap == 0 "vslideup.vx e8 masked retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vx e8 masked prefix lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vx e8 masked prefix lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e8 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslideup.vx e8 masked-off lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e8 masked active lane 2 writes a0"
.assert rd_wdata == 0x5 "vslideup.vx e8 masked active lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e8 masked tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslideup.vx e8 masked tail lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x3e40b457  # vslidedown.vi v8, v4, 1
.assert trap == 0 "vslidedown.vi e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vi e8 lane 0 writes a0"
.assert rd_wdata == 0x5 "vslidedown.vi e8 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vi e8 lane 2 writes a0"
.assert rd_wdata == 0xb "vslidedown.vi e8 lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vi e8 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslidedown.vi e8 tail lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x3c434457  # vslidedown.vx v8, v4, t1, v0.t
.assert trap == 0 "vslidedown.vx e8 masked retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vx e8 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vslidedown.vx e8 masked lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx e8 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslidedown.vx e8 masked-off lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx e8 masked tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslidedown.vx e8 masked tail lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x3a413457  # vslideup.vi v8, v4, 2
.assert trap == 0 "vslideup.vi e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vi e16 prefix lane 0 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vi e16 prefix lane 0 untouched"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e16 prefix lane 1 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslideup.vi e16 prefix lane 1 untouched"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e16 shifted lane 2 writes a0"
.assert rd_wdata == 0x3 "vslideup.vi e16 shifted lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e16 tail lane 3 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslideup.vi e16 tail lane 3 untouched"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x38434457  # vslideup.vx v8, v4, t1, v0.t
.assert trap == 0 "vslideup.vx e16 masked retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vx e16 masked prefix lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vx e16 masked prefix lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e16 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslideup.vx e16 masked-off lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e16 masked active lane 2 writes a0"
.assert rd_wdata == 0x5 "vslideup.vx e16 masked active lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e16 masked tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslideup.vx e16 masked tail lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x3e40b457  # vslidedown.vi v8, v4, 1
.assert trap == 0 "vslidedown.vi e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vi e16 lane 0 writes a0"
.assert rd_wdata == 0x5 "vslidedown.vi e16 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vi e16 lane 2 writes a0"
.assert rd_wdata == 0xb "vslidedown.vi e16 lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vi e16 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslidedown.vi e16 tail lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x3c434457  # vslidedown.vx v8, v4, t1, v0.t
.assert trap == 0 "vslidedown.vx e16 masked retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vx e16 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vslidedown.vx e16 masked lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx e16 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslidedown.vx e16 masked-off lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx e16 masked tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslidedown.vx e16 masked tail lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3a413457  # vslideup.vi v8, v4, 2
.assert trap == 0 "vslideup.vi e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vi e32 prefix lane 0 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vi e32 prefix lane 0 untouched"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e32 prefix lane 1 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslideup.vi e32 prefix lane 1 untouched"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e32 shifted lane 2 writes a0"
.assert rd_wdata == 0x3 "vslideup.vi e32 shifted lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e32 tail lane 3 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslideup.vi e32 tail lane 3 untouched"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x38434457  # vslideup.vx v8, v4, t1, v0.t
.assert trap == 0 "vslideup.vx e32 masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vx e32 masked prefix lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vx e32 masked prefix lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e32 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslideup.vx e32 masked-off lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e32 masked active lane 2 writes a0"
.assert rd_wdata == 0x5 "vslideup.vx e32 masked active lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e32 masked tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslideup.vx e32 masked tail lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3e40b457  # vslidedown.vi v8, v4, 1
.assert trap == 0 "vslidedown.vi e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vi e32 lane 0 writes a0"
.assert rd_wdata == 0x5 "vslidedown.vi e32 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vi e32 lane 2 writes a0"
.assert rd_wdata == 0xb "vslidedown.vi e32 lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vi e32 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslidedown.vi e32 tail lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3c434457  # vslidedown.vx v8, v4, t1, v0.t
.assert trap == 0 "vslidedown.vx e32 masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vx e32 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vslidedown.vx e32 masked lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx e32 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslidedown.vx e32 masked-off lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx e32 masked tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslidedown.vx e32 masked tail lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x44000337  # lui t1, 0x44000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00436313  # ori t1, t1, 0x4
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x33000337  # lui t1, 0x33000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00336313  # ori t1, t1, 0x3
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x22000337  # lui t1, 0x22000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00236313  # ori t1, t1, 0x2
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x11000337  # lui t1, 0x11000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00136313  # ori t1, t1, 0x1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x3a413457  # vslideup.vi v8, v4, 2
.assert trap == 0 "vslideup.vi e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vi e64 prefix lane 0 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vi e64 prefix lane 0 untouched"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e64 prefix lane 1 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslideup.vi e64 prefix lane 1 untouched"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e64 shifted lane 2 writes a0"
.assert rd_wdata == 0x1100000000000001 "vslideup.vi e64 shifted lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi e64 tail lane 3 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslideup.vi e64 tail lane 3 untouched"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x38434457  # vslideup.vx v8, v4, t1, v0.t
.assert trap == 0 "vslideup.vx e64 masked retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vx e64 masked prefix lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vx e64 masked prefix lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e64 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslideup.vx e64 masked-off lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e64 masked active lane 2 writes a0"
.assert rd_wdata == 0x2200000000000002 "vslideup.vx e64 masked active lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx e64 masked tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslideup.vx e64 masked tail lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x3e40b457  # vslidedown.vi v8, v4, 1
.assert trap == 0 "vslidedown.vi e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vi e64 lane 0 writes a0"
.assert rd_wdata == 0x2200000000000002 "vslidedown.vi e64 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vi e64 lane 2 writes a0"
.assert rd_wdata == 0x4400000000000004 "vslidedown.vi e64 lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vi e64 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslidedown.vi e64 tail lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x3c434457  # vslidedown.vx v8, v4, t1, v0.t
.assert trap == 0 "vslidedown.vx e64 masked retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vx e64 masked lane 0 writes a0"
.assert rd_wdata == 0x3300000000000003 "vslidedown.vx e64 masked lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx e64 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslidedown.vx e64 masked-off lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx e64 masked tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslidedown.vx e64 masked tail lane 3"
# Section 2b: slide corners (ta prefix, huge offset, 64b wraparound, VLMAX-1/VLMAX, uimm5=16/31, in-place, mf8/mf4, vl=0)
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e043257  # vmv.v.i v4, 8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e013257  # vmv.v.i v4, 2
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0xcd01f657  # vsetivli a2, 3, e32, m1, ta, ma
.4byte 0x3a434457  # vslideup.vx v8, v4, t1
.assert trap == 0 "vslideup.vx ta prefix retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vx ta prefix lane 0 preserved writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vx ta prefix lane 0 preserved"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx ta prefix lane 1 preserved writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vslideup.vx ta prefix lane 1 preserved"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx ta active lane 2 writes a0"
.assert rd_wdata == 0x2 "vslideup.vx ta active lane 2"
.4byte 0xfff00313  # addi t1, zero, -1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3a434457  # vslideup.vx v8, v4, t1
.assert trap == 0 "vslideup.vx huge offset retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vx huge offset lane 0 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslideup.vx huge offset lane 0 untouched"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx huge offset lane 2 untouched writes a0"
.assert rd_wdata == 0x2 "vslideup.vx huge offset lane 2 untouched"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x3a404457  # vslideup.vx v8, v4, zero
.assert trap == 0 "vslideup.vx offset=0 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vx offset=0 lane 0 writes a0"
.assert rd_wdata == 0x2 "vslideup.vx offset=0 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vx offset=0 lane 1 writes a0"
.assert rd_wdata == 0x4 "vslideup.vx offset=0 lane 1"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3e434457  # vslidedown.vx v8, v4, t1
.assert trap == 0 "vslidedown.vx 64b wrap retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vx wrap lane 0 == 0 writes a0"
.assert rd_wdata == 0x0 "vslidedown.vx wrap lane 0 == 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx wrap lane 1 == 0 (no wraparound) writes a0"
.assert rd_wdata == 0x0 "vslidedown.vx wrap lane 1 == 0 (no wraparound)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx wrap tail untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslidedown.vx wrap tail untouched"
.4byte 0x01007357  # vsetvli t1, zero, e32, m1, tu, mu
.4byte 0x5e06b257  # vmv.v.i v4, 13
.4byte 0xfff30393  # addi t2, t1, -1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x3e43c457  # vslidedown.vx v8, v4, t2
.assert trap == 0 "vslidedown.vx VLMAX-1 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vx offset=VLMAX-1 lane 0 writes a0"
.assert rd_wdata == 0xd "vslidedown.vx offset=VLMAX-1 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx offset=VLMAX-1 lane 1 == 0 writes a0"
.assert rd_wdata == 0x0 "vslidedown.vx offset=VLMAX-1 lane 1 == 0"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x3e434457  # vslidedown.vx v8, v4, t1
.assert trap == 0 "vslidedown.vx VLMAX retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vx offset=VLMAX lane 0 == 0 writes a0"
.assert rd_wdata == 0x0 "vslidedown.vx offset=VLMAX lane 0 == 0"
.4byte 0x001072d7  # vsetvli t0, zero, e8, m2, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e483457  # vslidedown.vi v8, v4, 16
.assert trap == 0 "vslidedown.vi uimm5=16 retires"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vi uimm5=16 zero-extended writes a0"
.assert rd_wdata == 0xb "vslidedown.vi uimm5=16 zero-extended"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e4fb457  # vslidedown.vi v8, v4, 31
.assert trap == 0 "vslidedown.vi uimm5=31 retires"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vi uimm5=31 zero-extended writes a0"
.assert rd_wdata == 0xb "vslidedown.vi uimm5=31 zero-extended"
.4byte 0x001072d7  # vsetvli t0, zero, e8, m2, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0xc0197657  # vsetivli a2, 18, e8, m2, tu, mu
.4byte 0x3a483457  # vslideup.vi v8, v4, 16
.assert trap == 0 "vslideup.vi uimm5=16 retires"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e87b657  # vslidedown.vi v12, v8, 15
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi uimm5=16 prefix lane 15 writes a0"
.assert rd_wdata == 0x5 "vslideup.vi uimm5=16 prefix lane 15"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e883657  # vslidedown.vi v12, v8, 16
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi uimm5=16 lane 16 written writes a0"
.assert rd_wdata == 0xb "vslideup.vi uimm5=16 lane 16 written"
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5e033457  # vmv.v.i v8, 6
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e023457  # vmv.v.i v8, 4
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e013457  # vmv.v.i v8, 2
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e00b457  # vmv.v.i v8, 1
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x3e813457  # vslidedown.vi v8, v8, 2
.assert trap == 0 "vslidedown.vi in-place m2 retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vi in-place lane 0 writes a0"
.assert rd_wdata == 0x3 "vslidedown.vi in-place lane 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vi in-place lane 3 (crossed reg) writes a0"
.assert rd_wdata == 0x6 "vslidedown.vi in-place lane 3 (crossed reg)"
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x3e834457  # vslidedown.vx v8, v8, t1
.assert trap == 0 "vslidedown.vx in-place retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslidedown.vx in-place lane 0 writes a0"
.assert rd_wdata == 0x4 "vslidedown.vx in-place lane 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslidedown.vx in-place lane 2 writes a0"
.assert rd_wdata == 0x6 "vslidedown.vx in-place lane 2"
.4byte 0xc0517657  # vsetivli a2, 2, e8, mf8, tu, mu
.4byte 0x5e053257  # vmv.v.i v4, 10
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x5e04b257  # vmv.v.i v4, 9
.4byte 0xc0517657  # vsetivli a2, 2, e8, mf8, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x5e0db457  # vmv.v.i v8, -5
.4byte 0x005072d7  # vsetvli t0, zero, e8, mf8, tu, mu
.4byte 0x3a40b457  # vslideup.vi v8, v4, 1
.assert trap == 0 "vslideup.vi mf8 vlmax retires"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup.vi mf8 vlmax prefix writes a0"
.assert rd_wdata == 0xfffffffffffffffb "vslideup.vi mf8 vlmax prefix"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslideup.vi mf8 vlmax lane 1 writes a0"
.assert rd_wdata == 0x9 "vslideup.vi mf8 vlmax lane 1"
.4byte 0xcce07657  # vsetivli a2, 0, e16, mf4, ta, ma
.assert rd_addr == 12 "slide vl=0 writes a2"
.assert rd_wdata == 0x0 "slide vl=0"
.4byte 0x3e40b457  # vslidedown.vi v8, v4, 1
.assert trap == 0 "vslidedown.vi vl=0 retires"
.4byte 0x3a40b457  # vslideup.vi v8, v4, 1
.assert trap == 0 "vslideup.vi vl=0 retires"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "slide vl=0 leaves v8 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffffb "slide vl=0 leaves v8 untouched"

# Section 3: vslide1{up,down}.vx (e8/e16/e32/e64) and vfslide1{up,down}.vf (e32/e64)
.4byte 0x11223e37  # lui t3, 0x11223
.4byte 0x344e0e13  # addi t3, t3, 836
.4byte 0x020e1e13  # slli t3, t3, 32
.4byte 0x55667fb7  # lui t6, 0x55667
.4byte 0x788f8f93  # addi t6, t6, 1928
.4byte 0x01fe6e33  # or t3, t3, t6
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x3a4e6457  # vslide1up.vx v8, v4, t3
.assert trap == 0 "vslide1up.vx e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1up.vx e8 lane 0 scalar writes a0"
.assert rd_wdata == 0xffffffffffffff88 "vslide1up.vx e8 lane 0 scalar"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx e8 lane 1 writes a0"
.assert rd_wdata == 0x3 "vslide1up.vx e8 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx e8 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslide1up.vx e8 tail lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x3e4e6457  # vslide1down.vx v8, v4, t3
.assert trap == 0 "vslide1down.vx e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1down.vx e8 lane 0 writes a0"
.assert rd_wdata == 0x5 "vslide1down.vx e8 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx e8 lane 2 scalar writes a0"
.assert rd_wdata == 0xffffffffffffff88 "vslide1down.vx e8 lane 2 scalar"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx e8 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslide1down.vx e8 tail lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x3a4e6457  # vslide1up.vx v8, v4, t3
.assert trap == 0 "vslide1up.vx e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1up.vx e16 lane 0 scalar writes a0"
.assert rd_wdata == 0x7788 "vslide1up.vx e16 lane 0 scalar"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx e16 lane 1 writes a0"
.assert rd_wdata == 0x3 "vslide1up.vx e16 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx e16 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslide1up.vx e16 tail lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x3e4e6457  # vslide1down.vx v8, v4, t3
.assert trap == 0 "vslide1down.vx e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1down.vx e16 lane 0 writes a0"
.assert rd_wdata == 0x5 "vslide1down.vx e16 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx e16 lane 2 scalar writes a0"
.assert rd_wdata == 0x7788 "vslide1down.vx e16 lane 2 scalar"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx e16 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslide1down.vx e16 tail lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3a4e6457  # vslide1up.vx v8, v4, t3
.assert trap == 0 "vslide1up.vx e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1up.vx e32 lane 0 scalar writes a0"
.assert rd_wdata == 0x55667788 "vslide1up.vx e32 lane 0 scalar"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx e32 lane 1 writes a0"
.assert rd_wdata == 0x3 "vslide1up.vx e32 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx e32 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslide1up.vx e32 tail lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3e4e6457  # vslide1down.vx v8, v4, t3
.assert trap == 0 "vslide1down.vx e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1down.vx e32 lane 0 writes a0"
.assert rd_wdata == 0x5 "vslide1down.vx e32 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx e32 lane 2 scalar writes a0"
.assert rd_wdata == 0x55667788 "vslide1down.vx e32 lane 2 scalar"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx e32 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslide1down.vx e32 tail lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x3a4e6457  # vslide1up.vx v8, v4, t3
.assert trap == 0 "vslide1up.vx e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1up.vx e64 lane 0 scalar writes a0"
.assert rd_wdata == 0x1122334455667788 "vslide1up.vx e64 lane 0 scalar"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx e64 lane 1 writes a0"
.assert rd_wdata == 0x3 "vslide1up.vx e64 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx e64 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslide1up.vx e64 tail lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x3e4e6457  # vslide1down.vx v8, v4, t3
.assert trap == 0 "vslide1down.vx e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1down.vx e64 lane 0 writes a0"
.assert rd_wdata == 0x5 "vslide1down.vx e64 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx e64 lane 2 scalar writes a0"
.assert rd_wdata == 0x1122334455667788 "vslide1down.vx e64 lane 2 scalar"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx e64 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vslide1down.vx e64 tail lane 3"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e043257  # vmv.v.i v4, 8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e013257  # vmv.v.i v4, 2
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x384e6457  # vslide1up.vx v8, v4, t3, v0.t
.assert trap == 0 "vslide1up.vx masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1up.vx masked-off lane 0 sentinel writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslide1up.vx masked-off lane 0 sentinel"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx masked active lane 1 writes a0"
.assert rd_wdata == 0x2 "vslide1up.vx masked active lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1up.vx masked-off lane 2 sentinel writes a0"
.assert rd_wdata == 0xfffffffffffffff3 "vslide1up.vx masked-off lane 2 sentinel"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3c4e6457  # vslide1down.vx v8, v4, t3, v0.t
.assert trap == 0 "vslide1down.vx masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1down.vx masked-off lane 0 sentinel writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vslide1down.vx masked-off lane 0 sentinel"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx masked active lane 1 writes a0"
.assert rd_wdata == 0x6 "vslide1down.vx masked active lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx masked-off lane vl-1 sentinel writes a0"
.assert rd_wdata == 0xfffffffffffffff3 "vslide1down.vx masked-off lane vl-1 sentinel"
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e023457  # vmv.v.i v8, 4
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e013457  # vmv.v.i v8, 2
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e00b457  # vmv.v.i v8, 1
.4byte 0x06300313  # addi t1, zero, 99
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e836457  # vslide1down.vx v8, v8, t1
.assert trap == 0 "vslide1down.vx vl=1 in-place retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1down.vx vl=1 lane 0 gets scalar writes a0"
.assert rd_wdata == 0x63 "vslide1down.vx vl=1 lane 0 gets scalar"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx vl=1 tail preserved writes a0"
.assert rd_wdata == 0x2 "vslide1down.vx vl=1 tail preserved"
.4byte 0xcd12f657  # vsetivli a2, 5, e32, m2, ta, ma
.4byte 0x3e836457  # vslide1down.vx v8, v8, t1
.assert trap == 0 "vslide1down.vx m2 in-place retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx m2 in-place lane 3 (crossed reg) writes a0"
.assert rd_wdata == 0x5 "vslide1down.vx m2 in-place lane 3 (crossed reg)"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823657  # vslidedown.vi v12, v8, 4
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vslide1down.vx m2 in-place lane 4 scalar writes a0"
.assert rd_wdata == 0x63 "vslide1down.vx m2 in-place lane 4 scalar"
.4byte 0x00f072d7  # vsetvli t0, zero, e16, mf2, tu, mu
.4byte 0x3a436457  # vslide1up.vx v8, v4, t1
.assert trap == 0 "vslide1up.vx mf2 vlmax retires"
.4byte 0xc0f0f657  # vsetivli a2, 1, e16, mf2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1up.vx mf2 vlmax lane 0 writes a0"
.assert rd_wdata == 0x63 "vslide1up.vx mf2 vlmax lane 0"
.4byte 0xc0f07657  # vsetivli a2, 0, e16, mf2, tu, mu
.assert rd_addr == 12 "slide1 int vl=0 writes a2"
.assert rd_wdata == 0x0 "slide1 int vl=0"
.4byte 0x3a4e6457  # vslide1up.vx v8, v4, t3
.assert trap == 0 "vslide1up.vx vl=0 retires"
.4byte 0x3e4e6457  # vslide1down.vx v8, v4, t3
.assert trap == 0 "vslide1down.vx vl=0 retires"
.4byte 0xc0f0f657  # vsetivli a2, 1, e16, mf2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "slide1 int vl=0 leaves v8 untouched writes a0"
.assert rd_wdata == 0x63 "slide1 int vl=0 leaves v8 untouched"
# Section 3b: vfslide1{up,down}.vf (e32/e64, sNaN verbatim, unboxed -> qNaN, masked, in-place m2, mf2, vl=0/VLMAX)
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x40800337  # lui t1, 0x40800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xc0100337  # lui t1, 0xc0100
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3fc00337  # lui t1, 0x3fc00
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0xf00300d3  # fmv.w.x f1, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3a40d457  # vfslide1up.vf v8, v4, f1
.assert trap == 0 "vfslide1up.vf e32 sNaN retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfslide1up.vf e32 sNaN leaves fflags clear) writes a1"
.assert rd_wdata == 0x0 "fflags (vfslide1up.vf e32 sNaN leaves fflags clear)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfslide1up.vf e32 sNaN preserved verbatim writes a0"
.assert rd_wdata == 0x7f800001 "vfslide1up.vf e32 sNaN preserved verbatim"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1up.vf e32 lane 1 writes a0"
.assert rd_wdata == 0x3fc00000 "vfslide1up.vf e32 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1up.vf e32 tail preserved writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vfslide1up.vf e32 tail preserved"
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0xf2030153  # fmv.d.x f2, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3a415457  # vfslide1up.vf v8, v4, f2
.assert trap == 0 "vfslide1up.vf e32 unboxed retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfslide1up.vf e32 unboxed leaves fflags clear) writes a1"
.assert rd_wdata == 0x0 "fflags (vfslide1up.vf e32 unboxed leaves fflags clear)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfslide1up.vf e32 unboxed scalar -> qNaN writes a0"
.assert rd_wdata == 0x7fc00000 "vfslide1up.vf e32 unboxed scalar -> qNaN"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3e415457  # vfslide1down.vf v8, v4, f2
.assert trap == 0 "vfslide1down.vf e32 unboxed retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfslide1down.vf e32 unboxed leaves fflags clear) writes a1"
.assert rd_wdata == 0x0 "fflags (vfslide1down.vf e32 unboxed leaves fflags clear)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfslide1down.vf e32 lane 0 writes a0"
.assert rd_wdata == 0xffffffffc0100000 "vfslide1down.vf e32 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1down.vf e32 -0.0 preserved writes a0"
.assert rd_wdata == 0xffffffff80000000 "vfslide1down.vf e32 -0.0 preserved"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1down.vf e32 unboxed scalar -> qNaN writes a0"
.assert rd_wdata == 0x7fc00000 "vfslide1down.vf e32 unboxed scalar -> qNaN"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1down.vf e32 tail preserved writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vfslide1down.vf e32 tail preserved"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3840d457  # vfslide1up.vf v8, v4, f1, v0.t
.assert trap == 0 "vfslide1up.vf masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfslide1up.vf masked-off lane 0 sentinel writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vfslide1up.vf masked-off lane 0 sentinel"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1up.vf masked active lane 1 writes a0"
.assert rd_wdata == 0x3fc00000 "vfslide1up.vf masked active lane 1"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x3c40d457  # vfslide1down.vf v8, v4, f1, v0.t
.assert trap == 0 "vfslide1down.vf masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1down.vf masked active lane 1 writes a0"
.assert rd_wdata == 0xffffffff80000000 "vfslide1down.vf masked active lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1down.vf masked-off lane vl-1 sentinel writes a0"
.assert rd_wdata == 0xfffffffffffffff3 "vfslide1down.vf masked-off lane vl-1 sentinel"
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x40800337  # lui t1, 0x40800
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xf00301d3  # fmv.w.x f3, t1
.4byte 0xcd12f657  # vsetivli a2, 5, e32, m2, ta, ma
.4byte 0x3e81d457  # vfslide1down.vf v8, v8, f3
.assert trap == 0 "vfslide1down.vf m2 in-place retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1down.vf m2 in-place lane 3 writes a0"
.assert rd_wdata == 0x40a00000 "vfslide1down.vf m2 in-place lane 3"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823657  # vslidedown.vi v12, v8, 4
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1down.vf m2 in-place lane 4 -0.0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "vfslide1down.vf m2 in-place lane 4 -0.0"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x40100337  # lui t1, 0x40100
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0xc00a0337  # lui t1, 0xc00a0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3ff80337  # lui t1, 0x3ff80
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x7ff00337  # lui t1, 0x7ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00136313  # ori t1, t1, 0x1
.4byte 0xf2030253  # fmv.d.x f4, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x3a425457  # vfslide1up.vf v8, v4, f4
.assert trap == 0 "vfslide1up.vf e64 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfslide1up.vf e64 sNaN leaves fflags clear) writes a1"
.assert rd_wdata == 0x0 "fflags (vfslide1up.vf e64 sNaN leaves fflags clear)"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfslide1up.vf e64 sNaN verbatim writes a0"
.assert rd_wdata == 0x7ff0000000000001 "vfslide1up.vf e64 sNaN verbatim"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1up.vf e64 lane 1 writes a0"
.assert rd_wdata == 0x3ff8000000000000 "vfslide1up.vf e64 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1up.vf e64 tail preserved writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vfslide1up.vf e64 tail preserved"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x3e425457  # vfslide1down.vf v8, v4, f4
.assert trap == 0 "vfslide1down.vf e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfslide1down.vf e64 lane 0 writes a0"
.assert rd_wdata == 0xc00a000000000000 "vfslide1down.vf e64 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vfslide1down.vf e64 lane 2 sNaN writes a0"
.assert rd_wdata == 0x7ff0000000000001 "vfslide1down.vf e64 lane 2 sNaN"
.4byte 0x017072d7  # vsetvli t0, zero, e32, mf2, tu, mu
.4byte 0x3a41d457  # vfslide1up.vf v8, v4, f3
.assert trap == 0 "vfslide1up.vf mf2 vlmax retires"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfslide1up.vf mf2 vlmax lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "vfslide1up.vf mf2 vlmax lane 0"
.4byte 0xc1707657  # vsetivli a2, 0, e32, mf2, tu, mu
.assert rd_addr == 12 "vfslide1 vl=0 writes a2"
.assert rd_wdata == 0x0 "vfslide1 vl=0"
.4byte 0x3a40d457  # vfslide1up.vf v8, v4, f1
.assert trap == 0 "vfslide1up.vf vl=0 retires"
.4byte 0x3e40d457  # vfslide1down.vf v8, v4, f1
.assert trap == 0 "vfslide1down.vf vl=0 retires"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfslide1 vl=0 leaves v8 untouched writes a0"
.assert rd_wdata == 0xffffffff80000000 "vfslide1 vl=0 leaves v8 untouched"

# Section 4: vrgather.{vv,vx,vi} and vrgatherei16.vv across e8/e16/e32/e64
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e00b857  # vmv.v.i v16, 1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x07f00313  # addi t1, zero, 127
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b857  # vmv.v.i v16, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x32480457  # vrgather.vv v8, v4, v16
.assert trap == 0 "vrgather.vv e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vv e8 lane 0 writes a0"
.assert rd_wdata == 0xb "vrgather.vv e8 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e8 lane 1 writes a0"
.assert rd_wdata == 0x3 "vrgather.vv e8 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e8 lane 2 oob -> 0 writes a0"
.assert rd_wdata == 0x0 "vrgather.vv e8 lane 2 oob -> 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e8 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vrgather.vv e8 tail lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x30434457  # vrgather.vx v8, v4, t1, v0.t
.assert trap == 0 "vrgather.vx e8 masked retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vx e8 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vrgather.vx e8 masked lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vx e8 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vrgather.vx e8 masked-off lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vx e8 masked lane 2 writes a0"
.assert rd_wdata == 0x7 "vrgather.vx e8 masked lane 2"
.4byte 0xcc017657  # vsetivli a2, 2, e8, m1, ta, ma
.4byte 0x3240b457  # vrgather.vi v8, v4, 1
.assert trap == 0 "vrgather.vi e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vi e8 lane 0 writes a0"
.assert rd_wdata == 0x5 "vrgather.vi e8 lane 0"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x04000313  # addi t1, zero, 64
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e00b857  # vmv.v.i v16, 1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e013857  # vmv.v.i v16, 2
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x32480457  # vrgather.vv v8, v4, v16
.assert trap == 0 "vrgather.vv e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vv e16 lane 0 writes a0"
.assert rd_wdata == 0x7 "vrgather.vv e16 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e16 lane 1 writes a0"
.assert rd_wdata == 0x5 "vrgather.vv e16 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e16 lane 2 oob -> 0 writes a0"
.assert rd_wdata == 0x0 "vrgather.vv e16 lane 2 oob -> 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e16 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vrgather.vv e16 tail lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x30434457  # vrgather.vx v8, v4, t1, v0.t
.assert trap == 0 "vrgather.vx e16 masked retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vx e16 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vrgather.vx e16 masked lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vx e16 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vrgather.vx e16 masked-off lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vx e16 masked lane 2 writes a0"
.assert rd_wdata == 0x7 "vrgather.vx e16 masked lane 2"
.4byte 0xcc817657  # vsetivli a2, 2, e16, m1, ta, ma
.4byte 0x3240b457  # vrgather.vi v8, v4, 1
.assert trap == 0 "vrgather.vi e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vi e16 lane 0 writes a0"
.assert rd_wdata == 0x5 "vrgather.vi e16 lane 0"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e01b857  # vmv.v.i v16, 3
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b857  # vmv.v.i v16, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x32480457  # vrgather.vv v8, v4, v16
.assert trap == 0 "vrgather.vv e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vv e32 lane 0 writes a0"
.assert rd_wdata == 0xb "vrgather.vv e32 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e32 lane 1 writes a0"
.assert rd_wdata == 0xb "vrgather.vv e32 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e32 lane 2 oob -> 0 writes a0"
.assert rd_wdata == 0x0 "vrgather.vv e32 lane 2 oob -> 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e32 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vrgather.vv e32 tail lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x30434457  # vrgather.vx v8, v4, t1, v0.t
.assert trap == 0 "vrgather.vx e32 masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vx e32 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vrgather.vx e32 masked lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vx e32 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vrgather.vx e32 masked-off lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vx e32 masked lane 2 writes a0"
.assert rd_wdata == 0x7 "vrgather.vx e32 masked lane 2"
.4byte 0xcd017657  # vsetivli a2, 2, e32, m1, ta, ma
.4byte 0x3240b457  # vrgather.vi v8, v4, 1
.assert trap == 0 "vrgather.vi e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vi e32 lane 0 writes a0"
.assert rd_wdata == 0x5 "vrgather.vi e32 lane 0"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x44000337  # lui t1, 0x44000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00436313  # ori t1, t1, 0x4
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x33000337  # lui t1, 0x33000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00336313  # ori t1, t1, 0x3
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x22000337  # lui t1, 0x22000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00236313  # ori t1, t1, 0x2
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x11000337  # lui t1, 0x11000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00136313  # ori t1, t1, 0x1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e01b857  # vmv.v.i v16, 3
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x02000313  # addi t1, zero, 32
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e013857  # vmv.v.i v16, 2
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x32480457  # vrgather.vv v8, v4, v16
.assert trap == 0 "vrgather.vv e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vv e64 lane 0 writes a0"
.assert rd_wdata == 0x3300000000000003 "vrgather.vv e64 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e64 lane 1 writes a0"
.assert rd_wdata == 0x1100000000000001 "vrgather.vv e64 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e64 lane 2 oob -> 0 writes a0"
.assert rd_wdata == 0x0 "vrgather.vv e64 lane 2 oob -> 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vv e64 tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vrgather.vv e64 tail lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x30434457  # vrgather.vx v8, v4, t1, v0.t
.assert trap == 0 "vrgather.vx e64 masked retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vx e64 masked lane 0 writes a0"
.assert rd_wdata == 0x3300000000000003 "vrgather.vx e64 masked lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vx e64 masked-off lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vrgather.vx e64 masked-off lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgather.vx e64 masked lane 2 writes a0"
.assert rd_wdata == 0x3300000000000003 "vrgather.vx e64 masked lane 2"
.4byte 0xcd917657  # vsetivli a2, 2, e64, m2, ta, ma
.4byte 0x3240b457  # vrgather.vi v8, v4, 1
.assert trap == 0 "vrgather.vi e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vi e64 lane 0 writes a0"
.assert rd_wdata == 0x2200000000000002 "vrgather.vi e64 lane 0"
# Section 4b: vrgather VLMAX-1/VLMAX, uimm5=16/31 zero-ext, and vrgatherei16 across e8/e16/e32/e64
.4byte 0x01007357  # vsetvli t1, zero, e32, m1, tu, mu
.4byte 0x5e073257  # vmv.v.i v4, 14
.4byte 0xfff30393  # addi t2, t1, -1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x3243c457  # vrgather.vx v8, v4, t2
.assert trap == 0 "vrgather.vx VLMAX-1 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vx idx=VLMAX-1 in-range writes a0"
.assert rd_wdata == 0xe "vrgather.vx idx=VLMAX-1 in-range"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x32434457  # vrgather.vx v8, v4, t1
.assert trap == 0 "vrgather.vx VLMAX retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vx idx=VLMAX -> 0 writes a0"
.assert rd_wdata == 0x0 "vrgather.vx idx=VLMAX -> 0"
.4byte 0xfff00393  # addi t2, zero, -1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x3243c457  # vrgather.vx v8, v4, t2
.assert trap == 0 "vrgather.vx huge idx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vx huge idx -> 0 writes a0"
.assert rd_wdata == 0x0 "vrgather.vx huge idx -> 0"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x32483457  # vrgather.vi v8, v4, 16
.assert trap == 0 "vrgather.vi e32 uimm5=16 oob retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vi e32 uimm5=16 -> 0 writes a0"
.assert rd_wdata == 0x0 "vrgather.vi e32 uimm5=16 -> 0"
.4byte 0x001072d7  # vsetvli t0, zero, e8, m2, tu, mu
.4byte 0x5e06b257  # vmv.v.i v4, 13
.4byte 0xc0117657  # vsetivli a2, 2, e8, m2, tu, mu
.4byte 0x32483457  # vrgather.vi v8, v4, 16
.assert trap == 0 "vrgather.vi e8 m2 uimm5=16 retires"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vi uimm5=16 zero-extended writes a0"
.assert rd_wdata == 0xd "vrgather.vi uimm5=16 zero-extended"
.4byte 0xc0117657  # vsetivli a2, 2, e8, m2, tu, mu
.4byte 0x324fb457  # vrgather.vi v8, v4, 31
.assert trap == 0 "vrgather.vi e8 m2 uimm5=31 retires"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vi uimm5=31 zero-extended writes a0"
.assert rd_wdata == 0xd "vrgather.vi uimm5=31 zero-extended"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc091f657  # vsetivli a2, 3, e16, m2, tu, mu
.4byte 0x5e00b857  # vmv.v.i v16, 1
.4byte 0xc0917657  # vsetivli a2, 2, e16, m2, tu, mu
.4byte 0x5e01b857  # vmv.v.i v16, 3
.4byte 0xc090f657  # vsetivli a2, 1, e16, m2, tu, mu
.4byte 0x10000313  # addi t1, zero, 256
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x3a480457  # vrgatherei16.vv v8, v4, v16
.assert trap == 0 "vrgatherei16.vv e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgatherei16.vv e8 idx=0x0100 -> 0 (16-bit index, not 8-bit) writes a0"
.assert rd_wdata == 0x0 "vrgatherei16.vv e8 idx=0x0100 -> 0 (16-bit index, not 8-bit)"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgatherei16.vv e8 idx=3 writes a0"
.assert rd_wdata == 0xb "vrgatherei16.vv e8 idx=3"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgatherei16.vv e8 tail untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vrgatherei16.vv e8 tail untouched"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e013257  # vmv.v.i v4, 2
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x3a420457  # vrgatherei16.vv v8, v4, v4
.assert trap == 0 "vrgatherei16.vv e16 vs2==vs1 legal retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgatherei16.vv e16 self-index lane 0 writes a0"
.assert rd_wdata == 0x3 "vrgatherei16.vv e16 self-index lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgatherei16.vv e16 self-index lane 3 writes a0"
.assert rd_wdata == 0x0 "vrgatherei16.vv e16 self-index lane 3"
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e013257  # vmv.v.i v4, 2
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc0837657  # vsetivli a2, 6, e16, m1, tu, mu
.4byte 0x5e00b857  # vmv.v.i v16, 1
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x5e013857  # vmv.v.i v16, 2
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x04000313  # addi t1, zero, 64
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e023857  # vmv.v.i v16, 4
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e02b857  # vmv.v.i v16, 5
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5e083457  # vmv.v.i v8, -16
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e0ab457  # vmv.v.i v8, -11
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x03700313  # addi t1, zero, 55
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x38480457  # vrgatherei16.vv v8, v4, v16, v0.t
.assert trap == 0 "vrgatherei16.vv e32 m2 masked retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgatherei16.vv e32 m2 lane 0 from upper reg writes a0"
.assert rd_wdata == 0x6 "vrgatherei16.vv e32 m2 lane 0 from upper reg"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgatherei16.vv e32 m2 idx=64 oob -> 0 writes a0"
.assert rd_wdata == 0x0 "vrgatherei16.vv e32 m2 idx=64 oob -> 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgatherei16.vv e32 m2 masked-off lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vrgatherei16.vv e32 m2 masked-off lane 3"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b657  # vslidedown.vi v12, v8, 5
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgatherei16.vv e32 m2 tail lane 5 writes a0"
.assert rd_wdata == 0xfffffffffffffff0 "vrgatherei16.vv e32 m2 tail lane 5"
.4byte 0xc1a2f657  # vsetivli a2, 5, e64, m4, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc1a27657  # vsetivli a2, 4, e64, m4, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc1a1f657  # vsetivli a2, 3, e64, m4, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1a17657  # vsetivli a2, 2, e64, m4, tu, mu
.4byte 0x5e013257  # vmv.v.i v4, 2
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x5e00ba57  # vmv.v.i v20, 1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e013a57  # vmv.v.i v20, 2
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x02000313  # addi t1, zero, 32
.4byte 0x5e034a57  # vmv.v.x v20, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e023a57  # vmv.v.i v20, 4
.4byte 0xcda2f657  # vsetivli a2, 5, e64, m4, ta, ma
.4byte 0x3a4a0857  # vrgatherei16.vv v16, v4, v20
.assert trap == 0 "vrgatherei16.vv e64 m4 retires"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vrgatherei16.vv e64 m4 lane 0 from reg+2 writes a0"
.assert rd_wdata == 0x5 "vrgatherei16.vv e64 m4 lane 0 from reg+2"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3f013657  # vslidedown.vi v12, v16, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgatherei16.vv e64 m4 idx=32 oob -> 0 writes a0"
.assert rd_wdata == 0x0 "vrgatherei16.vv e64 m4 idx=32 oob -> 0"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3f023657  # vslidedown.vi v12, v16, 4
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vrgatherei16.vv e64 m4 lane 4 writes a0"
.assert rd_wdata == 0x2 "vrgatherei16.vv e64 m4 lane 4"
.4byte 0xc0f17657  # vsetivli a2, 2, e16, mf2, tu, mu
.4byte 0x5e04b257  # vmv.v.i v4, 9
.4byte 0xc0f0f657  # vsetivli a2, 1, e16, mf2, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc0f17657  # vsetivli a2, 2, e16, mf2, tu, mu
.4byte 0x5e0c3457  # vmv.v.i v8, -8
.4byte 0xc0f0f657  # vsetivli a2, 1, e16, mf2, tu, mu
.4byte 0x5e0cb457  # vmv.v.i v8, -7
.4byte 0x00f072d7  # vsetvli t0, zero, e16, mf2, tu, mu
.4byte 0x3240b457  # vrgather.vi v8, v4, 1
.assert trap == 0 "vrgather.vi mf2 vlmax retires"
.4byte 0xc0f0f657  # vsetivli a2, 1, e16, mf2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather.vi mf2 vlmax lane 0 writes a0"
.assert rd_wdata == 0x9 "vrgather.vi mf2 vlmax lane 0"
.4byte 0xc0f07657  # vsetivli a2, 0, e16, mf2, tu, mu
.assert rd_addr == 12 "gather vl=0 writes a2"
.assert rd_wdata == 0x0 "gather vl=0"
.4byte 0x32403457  # vrgather.vi v8, v4, 0
.assert trap == 0 "vrgather.vi vl=0 retires"
.4byte 0x3a480457  # vrgatherei16.vv v8, v4, v16
.assert trap == 0 "vrgatherei16.vv vl=0 retires"
.4byte 0xc0f0f657  # vsetivli a2, 1, e16, mf2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "gather vl=0 leaves v8 untouched writes a0"
.assert rd_wdata == 0x9 "gather vl=0 leaves v8 untouched"

# Section 5: vcompress.vm across e8/e16/e32/e64 (all-zero, all-ones, sparse, vs1==v0, vl=0/VLMAX)
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e053157  # vmv.v.i v2, 10
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e412457  # vcompress.vm v8, v4, v2
.assert trap == 0 "vcompress.vm e8 sparse retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vcompress.vm e8 packed lane 0 writes a0"
.assert rd_wdata == 0x5 "vcompress.vm e8 packed lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e8 packed lane 1 writes a0"
.assert rd_wdata == 0xb "vcompress.vm e8 packed lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e8 undisturbed tail lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff3 "vcompress.vm e8 undisturbed tail lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e8 undisturbed tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vcompress.vm e8 undisturbed tail lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e412457  # vcompress.vm v8, v4, v2
.assert trap == 0 "vcompress.vm e16 sparse retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vcompress.vm e16 packed lane 0 writes a0"
.assert rd_wdata == 0x5 "vcompress.vm e16 packed lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e16 packed lane 1 writes a0"
.assert rd_wdata == 0xb "vcompress.vm e16 packed lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e16 undisturbed tail lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff3 "vcompress.vm e16 undisturbed tail lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e16 undisturbed tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vcompress.vm e16 undisturbed tail lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e412457  # vcompress.vm v8, v4, v2
.assert trap == 0 "vcompress.vm e32 sparse retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vcompress.vm e32 packed lane 0 writes a0"
.assert rd_wdata == 0x5 "vcompress.vm e32 packed lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e32 packed lane 1 writes a0"
.assert rd_wdata == 0xb "vcompress.vm e32 packed lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e32 undisturbed tail lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff3 "vcompress.vm e32 undisturbed tail lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e32 undisturbed tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vcompress.vm e32 undisturbed tail lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e412457  # vcompress.vm v8, v4, v2
.assert trap == 0 "vcompress.vm e64 sparse retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vcompress.vm e64 packed lane 0 writes a0"
.assert rd_wdata == 0x5 "vcompress.vm e64 packed lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e64 packed lane 1 writes a0"
.assert rd_wdata == 0xb "vcompress.vm e64 packed lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e64 undisturbed tail lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff3 "vcompress.vm e64 undisturbed tail lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm e64 undisturbed tail lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "vcompress.vm e64 undisturbed tail lane 3"
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e013257  # vmv.v.i v4, 2
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5e083457  # vmv.v.i v8, -16
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e08b457  # vmv.v.i v8, -15
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e093457  # vmv.v.i v8, -14
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e09b457  # vmv.v.i v8, -13
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e0a3457  # vmv.v.i v8, -12
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e0ab457  # vmv.v.i v8, -11
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e003157  # vmv.v.i v2, 0
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5e412457  # vcompress.vm v8, v4, v2
.assert trap == 0 "vcompress.vm all-zero mask retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vcompress.vm all-zero mask lane 0 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff5 "vcompress.vm all-zero mask lane 0 untouched"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823657  # vslidedown.vi v12, v8, 4
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm all-zero mask lane 4 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "vcompress.vm all-zero mask lane 4 untouched"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x02600313  # addi t1, zero, 38
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5e402457  # vcompress.vm v8, v4, v0
.assert trap == 0 "vcompress.vm vs1==v0 m2 retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vcompress.vm vs1==v0 lane 0 writes a0"
.assert rd_wdata == 0x2 "vcompress.vm vs1==v0 lane 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm vs1==v0 lane 1 writes a0"
.assert rd_wdata == 0x3 "vcompress.vm vs1==v0 lane 1"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e813657  # vslidedown.vi v12, v8, 2
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm vs1==v0 lane 2 (from upper reg) writes a0"
.assert rd_wdata == 0x6 "vcompress.vm vs1==v0 lane 2 (from upper reg)"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b657  # vslidedown.vi v12, v8, 3
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm vs1==v0 tail lane 3 untouched writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "vcompress.vm vs1==v0 tail lane 3 untouched"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e0fb157  # vmv.v.i v2, -1
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.4byte 0x5e043257  # vmv.v.i v4, 8
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.4byte 0x5e0f3457  # vmv.v.i v8, -2
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x5e0fb457  # vmv.v.i v8, -1
.4byte 0x0d7072d7  # vsetvli t0, zero, e32, mf2, ta, ma
.4byte 0x5e412457  # vcompress.vm v8, v4, v2
.assert trap == 0 "vcompress.vm all-ones mf2 vlmax retires"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vcompress.vm all-ones lane 0 writes a0"
.assert rd_wdata == 0x7 "vcompress.vm all-ones lane 0"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vcompress.vm all-ones lane 1 writes a0"
.assert rd_wdata == 0x8 "vcompress.vm all-ones lane 1"
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.4byte 0x5e073257  # vmv.v.i v4, 14
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x5e06b257  # vmv.v.i v4, 13
.4byte 0xc1707657  # vsetivli a2, 0, e32, mf2, tu, mu
.assert rd_addr == 12 "vcompress vl=0 writes a2"
.assert rd_wdata == 0x0 "vcompress vl=0"
.4byte 0x5e412457  # vcompress.vm v8, v4, v2
.assert trap == 0 "vcompress.vm vl=0 retires"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vcompress.vm vl=0 leaves v8 untouched writes a0"
.assert rd_wdata == 0x7 "vcompress.vm vl=0 leaves v8 untouched"

# Section 6: Whole-register moves vmv{1,2,4,8}r.v (all 4 sizes, vl=0, mismatched vtype, self-copy)
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00026337  # lui t1, 0x26
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02036313  # ori t1, t1, 0x20
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00016337  # lui t1, 0x16
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x01036313  # ori t1, t1, 0x10
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00026337  # lui t1, 0x26
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02136313  # ori t1, t1, 0x21
.4byte 0x5e0348d7  # vmv.v.x v17, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00016337  # lui t1, 0x16
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x01136313  # ori t1, t1, 0x11
.4byte 0x5e0348d7  # vmv.v.x v17, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00026337  # lui t1, 0x26
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02236313  # ori t1, t1, 0x22
.4byte 0x5e034957  # vmv.v.x v18, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00016337  # lui t1, 0x16
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x01236313  # ori t1, t1, 0x12
.4byte 0x5e034957  # vmv.v.x v18, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00026337  # lui t1, 0x26
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02336313  # ori t1, t1, 0x23
.4byte 0x5e0349d7  # vmv.v.x v19, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00016337  # lui t1, 0x16
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x01336313  # ori t1, t1, 0x13
.4byte 0x5e0349d7  # vmv.v.x v19, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00026337  # lui t1, 0x26
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02436313  # ori t1, t1, 0x24
.4byte 0x5e034a57  # vmv.v.x v20, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00016337  # lui t1, 0x16
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x01436313  # ori t1, t1, 0x14
.4byte 0x5e034a57  # vmv.v.x v20, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00026337  # lui t1, 0x26
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02536313  # ori t1, t1, 0x25
.4byte 0x5e034ad7  # vmv.v.x v21, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00016337  # lui t1, 0x16
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x01536313  # ori t1, t1, 0x15
.4byte 0x5e034ad7  # vmv.v.x v21, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00026337  # lui t1, 0x26
.4byte 0x00630313  # addi t1, t1, 6
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02636313  # ori t1, t1, 0x26
.4byte 0x5e034b57  # vmv.v.x v22, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00016337  # lui t1, 0x16
.4byte 0x00630313  # addi t1, t1, 6
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x01636313  # ori t1, t1, 0x16
.4byte 0x5e034b57  # vmv.v.x v22, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00026337  # lui t1, 0x26
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02736313  # ori t1, t1, 0x27
.4byte 0x5e034bd7  # vmv.v.x v23, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00016337  # lui t1, 0x16
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x01736313  # ori t1, t1, 0x17
.4byte 0x5e034bd7  # vmv.v.x v23, t1
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5a5a5337  # lui t1, 0x5a5a5
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3c336313  # ori t1, t1, 0x3c3
.4byte 0x5e034c57  # vmv.v.x v24, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x9f003c57  # vmv1r.v v24, v16
.assert trap == 0 "vmv1r.v retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vmv1r.v v24 lane 0 writes a0"
.assert rd_wdata == 0x1600000000010 "vmv1r.v v24 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3f80b657  # vslidedown.vi v12, v24, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vmv1r.v v24 lane 1 (beyond vl=1) writes a0"
.assert rd_wdata == 0x2600000000020 "vmv1r.v v24 lane 1 (beyond vl=1)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43902557  # vmv.x.s a0, v25
.assert rd_addr == 10 "vmv1r.v leaves neighbor v25 untouched writes a0"
.assert rd_wdata == 0x5a5a5000000003c3 "vmv1r.v leaves neighbor v25 untouched"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x9f00bc57  # vmv2r.v v24, v16
.assert trap == 0 "vmv2r.v retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43902557  # vmv.x.s a0, v25
.assert rd_addr == 10 "vmv2r.v v25 lane 0 writes a0"
.assert rd_wdata == 0x1600100000011 "vmv2r.v v25 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3f90b657  # vslidedown.vi v12, v25, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vmv2r.v v25 lane 1 writes a0"
.assert rd_wdata == 0x2600100000021 "vmv2r.v v25 lane 1"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43a02557  # vmv.x.s a0, v26
.assert rd_addr == 10 "vmv2r.v leaves neighbor v26 untouched writes a0"
.assert rd_wdata == 0x5a5a5000000003c3 "vmv2r.v leaves neighbor v26 untouched"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x9f01bc57  # vmv4r.v v24, v16
.assert trap == 0 "vmv4r.v retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43a02557  # vmv.x.s a0, v26
.assert rd_addr == 10 "vmv4r.v v26 lane 0 writes a0"
.assert rd_wdata == 0x1600200000012 "vmv4r.v v26 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3fb0b657  # vslidedown.vi v12, v27, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vmv4r.v v27 lane 1 writes a0"
.assert rd_wdata == 0x2600300000023 "vmv4r.v v27 lane 1"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vmv4r.v leaves neighbor v28 untouched writes a0"
.assert rd_wdata == 0x5a5a5000000003c3 "vmv4r.v leaves neighbor v28 untouched"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x9f03bc57  # vmv8r.v v24, v16
.assert trap == 0 "vmv8r.v retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vmv8r.v v28 lane 0 writes a0"
.assert rd_wdata == 0x1600400000014 "vmv8r.v v28 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43e02557  # vmv.x.s a0, v30
.assert rd_addr == 10 "vmv8r.v v30 lane 0 writes a0"
.assert rd_wdata == 0x1600600000016 "vmv8r.v v30 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43f02557  # vmv.x.s a0, v31
.assert rd_addr == 10 "vmv8r.v v31 lane 0 writes a0"
.assert rd_wdata == 0x1600700000017 "vmv8r.v v31 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff0b657  # vslidedown.vi v12, v31, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vmv8r.v v31 lane 1 writes a0"
.assert rd_wdata == 0x2600700000027 "vmv8r.v v31 lane 1"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5a5a5337  # lui t1, 0x5a5a5
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3c336313  # ori t1, t1, 0x3c3
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1807657  # vsetivli a2, 0, e64, m1, tu, mu
.assert rd_addr == 12 "vmvr vl=0 writes a2"
.assert rd_wdata == 0x0 "vmvr vl=0"
.4byte 0x9f003457  # vmv1r.v v8, v16
.assert trap == 0 "vmv1r.v vl=0 retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmv1r.v copies lane 0 when vl=0 writes a0"
.assert rd_wdata == 0x1600000000010 "vmv1r.v copies lane 0 when vl=0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vmv1r.v copies lane 1 when vl=0 writes a0"
.assert rd_wdata == 0x2600000000020 "vmv1r.v copies lane 1 when vl=0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xcc50f657  # vsetivli a2, 1, e8, mf8, ta, ma
.4byte 0x9f00b457  # vmv2r.v v8, v16
.assert trap == 0 "vmv2r.v mismatched vtype retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b657  # vslidedown.vi v12, v8, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vmv2r.v ignores e8/mf8/vl=1/v0=0 (v8 lane 1) writes a0"
.assert rd_wdata == 0x2600000000020 "vmv2r.v ignores e8/mf8/vl=1/v0=0 (v8 lane 1)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e90b657  # vslidedown.vi v12, v9, 1
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vmv2r.v ignores e8/mf8/vl=1/v0=0 (v9 lane 1) writes a0"
.assert rd_wdata == 0x2600100000021 "vmv2r.v ignores e8/mf8/vl=1/v0=0 (v9 lane 1)"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x9e803457  # vmv1r.v v8, v8
.assert trap == 0 "vmv1r.v self-copy retires"
.4byte 0x9e80b457  # vmv2r.v v8, v8
.assert trap == 0 "vmv2r.v self-copy retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmv{1,2}r.v self-copy preserves v8 writes a0"
.assert rd_wdata == 0x1600000000010 "vmv{1,2}r.v self-copy preserves v8"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vmv2r.v self-copy preserves v9 writes a0"
.assert rd_wdata == 0x1600100000011 "vmv2r.v self-copy preserves v9"

# Section 7: 22 illegal-instruction traps covering permute overlap, alignment, range, reserved, and vill rules
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0bb457  # vmv.v.i v8, -9
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x3a834457  # vslideup.vx v8, v8, t1
.assert trap == 1 "vslideup overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vslideup overlap mcause writes a0"
.assert rd_wdata == 0x2 "vslideup overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vslideup overlap mtval writes a0"
.assert rd_wdata == 0x3a834457 "vslideup overlap mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslideup overlap leaves v8 intact writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "vslideup overlap leaves v8 intact"
.4byte 0x3a836457  # vslide1up.vx v8, v8, t1
.assert trap == 1 "vslide1up overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vslide1up overlap mcause writes a0"
.assert rd_wdata == 0x2 "vslide1up overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vslide1up overlap mtval writes a0"
.assert rd_wdata == 0x3a836457 "vslide1up overlap mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vslide1up overlap leaves v8 intact writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "vslide1up overlap leaves v8 intact"
.4byte 0x3a80d457  # vfslide1up.vf v8, v8, f1
.assert trap == 1 "vfslide1up overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfslide1up overlap mcause writes a0"
.assert rd_wdata == 0x2 "vfslide1up overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfslide1up overlap mtval writes a0"
.assert rd_wdata == 0x3a80d457 "vfslide1up overlap mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfslide1up overlap leaves v8 intact writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "vfslide1up overlap leaves v8 intact"
.4byte 0x32820457  # vrgather.vv v8, v8, v4
.assert trap == 1 "vrgather vd==vs2 overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrgather vd==vs2 overlap mcause writes a0"
.assert rd_wdata == 0x2 "vrgather vd==vs2 overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrgather vd==vs2 overlap mtval writes a0"
.assert rd_wdata == 0x32820457 "vrgather vd==vs2 overlap mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vrgather vd==vs2 overlap leaves v8 intact writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "vrgather vd==vs2 overlap leaves v8 intact"
.4byte 0x32440457  # vrgather.vv v8, v4, v8
.assert trap == 1 "vrgather vd==vs1 overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrgather vd==vs1 overlap mcause writes a0"
.assert rd_wdata == 0x2 "vrgather vd==vs1 overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrgather vd==vs1 overlap mtval writes a0"
.assert rd_wdata == 0x32440457 "vrgather vd==vs1 overlap mtval"
.4byte 0xc0317657  # vsetivli a2, 2, e8, m8, tu, mu
.4byte 0x3b0c0457  # vrgatherei16.vv v8, v16, v24
.assert trap == 1 "vrgatherei16 emul16 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrgatherei16 emul16 mcause writes a0"
.assert rd_wdata == 0x2 "vrgatherei16 emul16 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrgatherei16 emul16 mtval writes a0"
.assert rd_wdata == 0x3b0c0457 "vrgatherei16 emul16 mtval"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x3a420457  # vrgatherei16.vv v8, v4, v4
.assert trap == 1 "vrgatherei16 src overlap e32 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrgatherei16 src overlap e32 mcause writes a0"
.assert rd_wdata == 0x2 "vrgatherei16 src overlap e32 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrgatherei16 src overlap e32 mtval writes a0"
.assert rd_wdata == 0x3a420457 "vrgatherei16 src overlap e32 mtval"
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x3a448457  # vrgatherei16.vv v8, v4, v9
.assert trap == 1 "vrgatherei16 vd/vs1 overlap m2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrgatherei16 vd/vs1 overlap m2 mcause writes a0"
.assert rd_wdata == 0x2 "vrgatherei16 vd/vs1 overlap m2 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrgatherei16 vd/vs1 overlap m2 mtval writes a0"
.assert rd_wdata == 0x3a448457 "vrgatherei16 vd/vs1 overlap m2 mtval"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x3a488457  # vrgatherei16.vv v8, v4, v17
.assert trap == 1 "vrgatherei16 misaligned vs1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrgatherei16 misaligned vs1 mcause writes a0"
.assert rd_wdata == 0x2 "vrgatherei16 misaligned vs1 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrgatherei16 misaligned vs1 mtval writes a0"
.assert rd_wdata == 0x3a488457 "vrgatherei16 misaligned vs1 mtval"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e812457  # vcompress.vm v8, v8, v2
.assert trap == 1 "vcompress vd==vs2 overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vcompress vd==vs2 overlap mcause writes a0"
.assert rd_wdata == 0x2 "vcompress vd==vs2 overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vcompress vd==vs2 overlap mtval writes a0"
.assert rd_wdata == 0x5e812457 "vcompress vd==vs2 overlap mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vcompress vd==vs2 overlap leaves v8 intact writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "vcompress vd==vs2 overlap leaves v8 intact"
.4byte 0x5e442457  # vcompress.vm v8, v4, v8
.assert trap == 1 "vcompress vd==vs1 overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vcompress vd==vs1 overlap mcause writes a0"
.assert rd_wdata == 0x2 "vcompress vd==vs1 overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vcompress vd==vs1 overlap mtval writes a0"
.assert rd_wdata == 0x5e442457 "vcompress vd==vs1 overlap mtval"
.4byte 0x5e422457  # vcompress.vm v8, v4, v4
.assert trap == 1 "vcompress vs2==vs1 overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vcompress vs2==vs1 overlap mcause writes a0"
.assert rd_wdata == 0x2 "vcompress vs2==vs1 overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vcompress vs2==vs1 overlap mtval writes a0"
.assert rd_wdata == 0x5e422457 "vcompress vs2==vs1 overlap mtval"
.4byte 0x5c412457  # reserved: vcompress.vm with vm=0
.assert trap == 1 "vcompress masked vm=0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vcompress masked vm=0 mcause writes a0"
.assert rd_wdata == 0x2 "vcompress masked vm=0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vcompress masked vm=0 mtval writes a0"
.assert rd_wdata == 0x5c412457 "vcompress masked vm=0 mtval"
.4byte 0x9e40b4d7  # vmv2r.v v9, v4
.assert trap == 1 "vmv2r misaligned vd traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmv2r misaligned vd mcause writes a0"
.assert rd_wdata == 0x2 "vmv2r misaligned vd mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmv2r misaligned vd mtval writes a0"
.assert rd_wdata == 0x9e40b4d7 "vmv2r misaligned vd mtval"
.4byte 0x9e61b457  # vmv4r.v v8, v6
.assert trap == 1 "vmv4r misaligned vs2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmv4r misaligned vs2 mcause writes a0"
.assert rd_wdata == 0x2 "vmv4r misaligned vs2 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmv4r misaligned vs2 mtval writes a0"
.assert rd_wdata == 0x9e61b457 "vmv4r misaligned vs2 mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmv4r misaligned vs2 leaves v8 intact writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "vmv4r misaligned vs2 leaves v8 intact"
.4byte 0x9e413457  # reserved: vmv3r.v (vs1=2)
.assert trap == 1 "vmvr reserved nr=3 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmvr reserved nr=3 mcause writes a0"
.assert rd_wdata == 0x2 "vmvr reserved nr=3 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmvr reserved nr=3 mtval writes a0"
.assert rd_wdata == 0x9e413457 "vmvr reserved nr=3 mtval"
.4byte 0x9c403457  # reserved: vmv1r.v with vm=0
.assert trap == 1 "vmvr masked vm=0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmvr masked vm=0 mcause writes a0"
.assert rd_wdata == 0x2 "vmvr masked vm=0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmvr masked vm=0 mtval writes a0"
.assert rd_wdata == 0x9c403457 "vmvr masked vm=0 mtval"
.4byte 0x3c40b057  # vslidedown.vi v0, v4, 1, v0.t
.assert trap == 1 "masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "masked vd==v0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "masked vd==v0 mtval writes a0"
.assert rd_wdata == 0x3c40b057 "masked vd==v0 mtval"
.4byte 0x3000b457  # vrgather.vi v8, v0, 1, v0.t
.assert trap == 1 "masked vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "masked vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "masked vs2==v0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "masked vs2==v0 mtval writes a0"
.assert rd_wdata == 0x3000b457 "masked vs2==v0 mtval"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x3a40d457  # vfslide1up.vf v8, v4, f1
.assert trap == 1 "vfslide1up e8 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfslide1up e8 mcause writes a0"
.assert rd_wdata == 0x2 "vfslide1up e8 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfslide1up e8 mtval writes a0"
.assert rd_wdata == 0x3a40d457 "vfslide1up e8 mtval"
.4byte 0xc1f0f657  # vsetivli a2, 1, e64, mf2, tu, mu
.assert rd_addr == 12 "vill=1 config writes a2"
.assert rd_wdata == 0x0 "vill=1 config"
.4byte 0x3a40b457  # vslideup.vi v8, v4, 1
.assert trap == 1 "vslideup under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vslideup under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vslideup under vill=1 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vslideup under vill=1 mtval writes a0"
.assert rd_wdata == 0x3a40b457 "vslideup under vill=1 mtval"
.4byte 0x9e403457  # vmv1r.v v8, v4
.assert trap == 1 "vmv1r under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmv1r under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vmv1r under vill=1 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmv1r under vill=1 mtval writes a0"
.assert rd_wdata == 0x9e403457 "vmv1r under vill=1 mtval"
