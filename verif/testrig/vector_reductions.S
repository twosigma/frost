# Directed TestRIG trace for base-V vector reduction instructions (16 encodings):
# vredsum, vredand, vredor, vredxor, vredminu, vredmin, vredmaxu, vredmax,
# vwredsumu, vwredsum, vfredusum, vfredosum, vfredmin, vfredmax,
# vfwredusum, vfwredosum. Run with --vlen 128, 256 or 512.
.noshrink
# Enable FP and vector state, zero v0..v31, clear fflags and frm
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
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 (init) readback writes a0"
.assert rd_wdata == 0x0 "frm=0 (init) readback"

# Section 1: Control anchor (unique vmv.x.s a0, v18 = 0x43202557)
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00004337  # lui t1, 0x4
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x12340337  # lui t1, 0x12340
.4byte 0x00a30313  # addi t1, t1, 10
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "ctrl vl=4 writes a2"
.assert rd_wdata == 0x4 "ctrl vl=4"
.4byte 0x02412957  # vredsum.vs v18, v4, v2
.assert trap == 0 "ctrl vredsum.vs retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "ctrl vredsum.vs lane 0 writes a0"
.assert rd_wdata == 0x1234a00a "ctrl vredsum.vs lane 0"

# Section 2: 8 single-width integer reductions across e8/e16/e32/e64
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e0eb257  # vmv.v.i v4, -3
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0xf8500313  # addi t1, zero, -123
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e07b157  # vmv.v.i v2, 15
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x02412457  # vredsum.vs v8, v4, v2
.assert trap == 0 "vredsum.vs e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredsum.vs e8 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff98 "vredsum.vs e8 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vredsum.vs e8 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x5a "vredsum.vs e8 tu lane 1 untouched"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x06412457  # vredand.vs v8, v4, v2
.assert trap == 0 "vredand.vs e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredand.vs e8 lane 0 writes a0"
.assert rd_wdata == 0x5 "vredand.vs e8 lane 0"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x0a412457  # vredor.vs v8, v4, v2
.assert trap == 0 "vredor.vs e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredor.vs e8 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vredor.vs e8 lane 0"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x0e412457  # vredxor.vs v8, v4, v2
.assert trap == 0 "vredxor.vs e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredxor.vs e8 lane 0 writes a0"
.assert rd_wdata == 0x70 "vredxor.vs e8 lane 0"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x12412457  # vredminu.vs v8, v4, v2
.assert trap == 0 "vredminu.vs e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredminu.vs e8 lane 0 writes a0"
.assert rd_wdata == 0x7 "vredminu.vs e8 lane 0"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x16412457  # vredmin.vs v8, v4, v2
.assert trap == 0 "vredmin.vs e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmin.vs e8 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff85 "vredmin.vs e8 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vredmin.vs e8 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x5a "vredmin.vs e8 tu lane 1 untouched"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x1a412457  # vredmaxu.vs v8, v4, v2
.assert trap == 0 "vredmaxu.vs e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmaxu.vs e8 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "vredmaxu.vs e8 lane 0"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x1e412457  # vredmax.vs v8, v4, v2
.assert trap == 0 "vredmax.vs e8 retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmax.vs e8 lane 0 writes a0"
.assert rd_wdata == 0xf "vredmax.vs e8 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x04412457  # vredand.vs v8, v4, v2, v0.t
.assert trap == 0 "vredand.vs e8 masked retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredand.vs e8 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredand.vs e8 masked lane 0"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x10412457  # vredminu.vs v8, v4, v2, v0.t
.assert trap == 0 "vredminu.vs e8 masked retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredminu.vs e8 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredminu.vs e8 masked lane 0"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x14412457  # vredmin.vs v8, v4, v2, v0.t
.assert trap == 0 "vredmin.vs e8 masked retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmin.vs e8 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredmin.vs e8 masked lane 0"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x1c412457  # vredmax.vs v8, v4, v2, v0.t
.assert trap == 0 "vredmax.vs e8 masked retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmax.vs e8 masked lane 0 writes a0"
.assert rd_wdata == 0xf "vredmax.vs e8 masked lane 0"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e0eb257  # vmv.v.i v4, -3
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0xffff8337  # lui t1, 0xffff8
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e07b157  # vmv.v.i v2, 15
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x02412457  # vredsum.vs v8, v4, v2
.assert trap == 0 "vredsum.vs e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredsum.vs e16 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8018 "vredsum.vs e16 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vredsum.vs e16 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x5a "vredsum.vs e16 tu lane 1 untouched"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x06412457  # vredand.vs v8, v4, v2
.assert trap == 0 "vredand.vs e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredand.vs e16 lane 0 writes a0"
.assert rd_wdata == 0x5 "vredand.vs e16 lane 0"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x0a412457  # vredor.vs v8, v4, v2
.assert trap == 0 "vredor.vs e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredor.vs e16 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vredor.vs e16 lane 0"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x0e412457  # vredxor.vs v8, v4, v2
.assert trap == 0 "vredxor.vs e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredxor.vs e16 lane 0 writes a0"
.assert rd_wdata == 0x7ff0 "vredxor.vs e16 lane 0"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x12412457  # vredminu.vs v8, v4, v2
.assert trap == 0 "vredminu.vs e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredminu.vs e16 lane 0 writes a0"
.assert rd_wdata == 0x7 "vredminu.vs e16 lane 0"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x16412457  # vredmin.vs v8, v4, v2
.assert trap == 0 "vredmin.vs e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmin.vs e16 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8005 "vredmin.vs e16 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vredmin.vs e16 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x5a "vredmin.vs e16 tu lane 1 untouched"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x1a412457  # vredmaxu.vs v8, v4, v2
.assert trap == 0 "vredmaxu.vs e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmaxu.vs e16 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "vredmaxu.vs e16 lane 0"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x1e412457  # vredmax.vs v8, v4, v2
.assert trap == 0 "vredmax.vs e16 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmax.vs e16 lane 0 writes a0"
.assert rd_wdata == 0xf "vredmax.vs e16 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x04412457  # vredand.vs v8, v4, v2, v0.t
.assert trap == 0 "vredand.vs e16 masked retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredand.vs e16 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredand.vs e16 masked lane 0"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x10412457  # vredminu.vs v8, v4, v2, v0.t
.assert trap == 0 "vredminu.vs e16 masked retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredminu.vs e16 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredminu.vs e16 masked lane 0"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x14412457  # vredmin.vs v8, v4, v2, v0.t
.assert trap == 0 "vredmin.vs e16 masked retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmin.vs e16 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredmin.vs e16 masked lane 0"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x1c412457  # vredmax.vs v8, v4, v2, v0.t
.assert trap == 0 "vredmax.vs e16 masked retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmax.vs e16 masked lane 0 writes a0"
.assert rd_wdata == 0xf "vredmax.vs e16 masked lane 0"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e0eb257  # vmv.v.i v4, -3
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e07b157  # vmv.v.i v2, 15
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x02412457  # vredsum.vs v8, v4, v2
.assert trap == 0 "vredsum.vs e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredsum.vs e32 lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000018 "vredsum.vs e32 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vredsum.vs e32 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x5a "vredsum.vs e32 tu lane 1 untouched"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x06412457  # vredand.vs v8, v4, v2
.assert trap == 0 "vredand.vs e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredand.vs e32 lane 0 writes a0"
.assert rd_wdata == 0x5 "vredand.vs e32 lane 0"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x0a412457  # vredor.vs v8, v4, v2
.assert trap == 0 "vredor.vs e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredor.vs e32 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vredor.vs e32 lane 0"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x0e412457  # vredxor.vs v8, v4, v2
.assert trap == 0 "vredxor.vs e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredxor.vs e32 lane 0 writes a0"
.assert rd_wdata == 0x7ffffff0 "vredxor.vs e32 lane 0"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x12412457  # vredminu.vs v8, v4, v2
.assert trap == 0 "vredminu.vs e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredminu.vs e32 lane 0 writes a0"
.assert rd_wdata == 0x7 "vredminu.vs e32 lane 0"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x16412457  # vredmin.vs v8, v4, v2
.assert trap == 0 "vredmin.vs e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmin.vs e32 lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000005 "vredmin.vs e32 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vredmin.vs e32 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x5a "vredmin.vs e32 tu lane 1 untouched"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x1a412457  # vredmaxu.vs v8, v4, v2
.assert trap == 0 "vredmaxu.vs e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmaxu.vs e32 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "vredmaxu.vs e32 lane 0"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x1e412457  # vredmax.vs v8, v4, v2
.assert trap == 0 "vredmax.vs e32 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmax.vs e32 lane 0 writes a0"
.assert rd_wdata == 0xf "vredmax.vs e32 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x04412457  # vredand.vs v8, v4, v2, v0.t
.assert trap == 0 "vredand.vs e32 masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredand.vs e32 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredand.vs e32 masked lane 0"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x10412457  # vredminu.vs v8, v4, v2, v0.t
.assert trap == 0 "vredminu.vs e32 masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredminu.vs e32 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredminu.vs e32 masked lane 0"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x14412457  # vredmin.vs v8, v4, v2, v0.t
.assert trap == 0 "vredmin.vs e32 masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmin.vs e32 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredmin.vs e32 masked lane 0"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x1c412457  # vredmax.vs v8, v4, v2, v0.t
.assert trap == 0 "vredmax.vs e32 masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmax.vs e32 masked lane 0 writes a0"
.assert rd_wdata == 0xf "vredmax.vs e32 masked lane 0"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e0eb257  # vmv.v.i v4, -3
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e07b157  # vmv.v.i v2, 15
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x02412457  # vredsum.vs v8, v4, v2
.assert trap == 0 "vredsum.vs e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredsum.vs e64 lane 0 writes a0"
.assert rd_wdata == 0x8000000000000018 "vredsum.vs e64 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vredsum.vs e64 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x5a "vredsum.vs e64 tu lane 1 untouched"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x06412457  # vredand.vs v8, v4, v2
.assert trap == 0 "vredand.vs e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredand.vs e64 lane 0 writes a0"
.assert rd_wdata == 0x5 "vredand.vs e64 lane 0"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x0a412457  # vredor.vs v8, v4, v2
.assert trap == 0 "vredor.vs e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredor.vs e64 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vredor.vs e64 lane 0"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x0e412457  # vredxor.vs v8, v4, v2
.assert trap == 0 "vredxor.vs e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredxor.vs e64 lane 0 writes a0"
.assert rd_wdata == 0x7ffffffffffffff0 "vredxor.vs e64 lane 0"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x12412457  # vredminu.vs v8, v4, v2
.assert trap == 0 "vredminu.vs e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredminu.vs e64 lane 0 writes a0"
.assert rd_wdata == 0x7 "vredminu.vs e64 lane 0"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x16412457  # vredmin.vs v8, v4, v2
.assert trap == 0 "vredmin.vs e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmin.vs e64 lane 0 writes a0"
.assert rd_wdata == 0x8000000000000005 "vredmin.vs e64 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vredmin.vs e64 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x5a "vredmin.vs e64 tu lane 1 untouched"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x1a412457  # vredmaxu.vs v8, v4, v2
.assert trap == 0 "vredmaxu.vs e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmaxu.vs e64 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "vredmaxu.vs e64 lane 0"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x1e412457  # vredmax.vs v8, v4, v2
.assert trap == 0 "vredmax.vs e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmax.vs e64 lane 0 writes a0"
.assert rd_wdata == 0xf "vredmax.vs e64 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x04412457  # vredand.vs v8, v4, v2, v0.t
.assert trap == 0 "vredand.vs e64 masked retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredand.vs e64 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredand.vs e64 masked lane 0"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x10412457  # vredminu.vs v8, v4, v2, v0.t
.assert trap == 0 "vredminu.vs e64 masked retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredminu.vs e64 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredminu.vs e64 masked lane 0"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x14412457  # vredmin.vs v8, v4, v2, v0.t
.assert trap == 0 "vredmin.vs e64 masked retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmin.vs e64 masked lane 0 writes a0"
.assert rd_wdata == 0x7 "vredmin.vs e64 masked lane 0"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x1c412457  # vredmax.vs v8, v4, v2, v0.t
.assert trap == 0 "vredmax.vs e64 masked retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredmax.vs e64 masked lane 0 writes a0"
.assert rd_wdata == 0xf "vredmax.vs e64 masked lane 0"
# Section 2b: integer reduction corners (all-zero mask, vl=0, VLMAX, ta/ma, mf8/mf4/mf2, m2 odd vd/vs1, legal overlaps)
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x03c00313  # addi t1, zero, 60
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x03200313  # addi t1, zero, 50
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x02800313  # addi t1, zero, 40
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x01e00313  # addi t1, zero, 30
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e053257  # vmv.v.i v4, 10
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e03b6d7  # vmv.v.i v13, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x66600313  # addi t1, zero, 1638
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x55500313  # addi t1, zero, 1365
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x0046a4d7  # vredsum.vs v9, v4, v13, v0.t
.assert trap == 0 "vredsum all-zero mask retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vredsum all-zero mask copies seed writes a0"
.assert rd_wdata == 0x7 "vredsum all-zero mask copies seed"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e90bbd7  # vslidedown.vi v23, v9, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vredsum all-zero mask tu lane 1 untouched writes a0"
.assert rd_wdata == 0x666 "vredsum all-zero mask tu lane 1 untouched"
.4byte 0xcd137657  # vsetivli a2, 6, e32, m2, ta, ma
.4byte 0x0246a4d7  # vredsum.vs v9, v4, v13
.assert trap == 0 "vredsum m2 odd vd/vs1 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vredsum m2 crossing odd vd/vs1 writes a0"
.assert rd_wdata == 0xd9 "vredsum m2 crossing odd vd/vs1"
.4byte 0xcd107657  # vsetivli a2, 0, e32, m2, ta, ma
.assert rd_addr == 12 "int red vl=0 writes a2"
.assert rd_wdata == 0x0 "int red vl=0"
.4byte 0x0246a4d7  # vredsum.vs v9, v4, v13
.assert trap == 0 "vredsum vl=0 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vredsum vl=0 leaves vd[0] untouched writes a0"
.assert rd_wdata == 0xd9 "vredsum vl=0 leaves vd[0] untouched"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e06b457  # vmv.v.i v8, 13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e05b457  # vmv.v.i v8, 11
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x02842457  # vredsum.vs v8, v8, v8
.assert trap == 0 "vredsum vd==vs2==vs1 legal retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredsum vd==vs2==vs1 result writes a0"
.assert rd_wdata == 0x22 "vredsum vd==vs2==vs1 result"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x0046a057  # vredsum.vs v0, v4, v13, v0.t
.assert trap == 0 "vredsum masked vd==v0 legal retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "vredsum masked vd==v0 result writes a0"
.assert rd_wdata == 0x2f "vredsum masked vd==v0 result"
.4byte 0x005072d7  # vsetvli t0, zero, e8, mf8, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x5e01b157  # vmv.v.i v2, 3
.4byte 0x005072d7  # vsetvli t0, zero, e8, mf8, tu, mu
.4byte 0x0a412457  # vredor.vs v8, v4, v2
.assert trap == 0 "vredor mf8 vlmax retires"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredor mf8 vlmax result (5 | 3 == 7) writes a0"
.assert rd_wdata == 0x7 "vredor mf8 vlmax result (5 | 3 == 7)"
.4byte 0xc0e17657  # vsetivli a2, 2, e16, mf4, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc0e0f657  # vsetivli a2, 1, e16, mf4, tu, mu
.4byte 0x5e00b157  # vmv.v.i v2, 1
.4byte 0xc0e17657  # vsetivli a2, 2, e16, mf4, tu, mu
.4byte 0x02412457  # vredsum.vs v8, v4, v2
.assert trap == 0 "vredsum mf4 retires"
.4byte 0xc0e0f657  # vsetivli a2, 1, e16, mf4, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vredsum mf4 result writes a0"
.assert rd_wdata == 0xd "vredsum mf4 result"

# Section 3: Widening integer reductions vwredsumu.vs and vwredsum.vs across e8/e16/e32
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x07f00313  # addi t1, zero, 127
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0xf8000313  # addi t1, zero, -128
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x10500313  # addi t1, zero, 261
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x5aa30313  # addi t1, t1, 1450
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xc2410457  # vwredsumu.vs v8, v4, v2
.assert trap == 0 "vwredsumu e8 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsumu e8->16 lane 0 writes a0"
.assert rd_wdata == 0x303 "vwredsumu e8->16 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vwredsumu e8->16 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x55aa "vwredsumu e8->16 tu lane 1 untouched"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xc6410457  # vwredsum.vs v8, v4, v2
.assert trap == 0 "vwredsum e8 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsum e8->16 lane 0 writes a0"
.assert rd_wdata == 0x103 "vwredsum e8->16 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xc0410457  # vwredsumu.vs v8, v4, v2, v0.t
.assert trap == 0 "vwredsumu e8 masked retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsumu e8 masked lane 0 writes a0"
.assert rd_wdata == 0x204 "vwredsumu e8 masked lane 0"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xc4410457  # vwredsum.vs v8, v4, v2, v0.t
.assert trap == 0 "vwredsum e8 masked retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsum e8 masked lane 0 writes a0"
.assert rd_wdata == 0x104 "vwredsum e8 masked lane 0"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0xffff8337  # lui t1, 0xffff8
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x5aa30313  # addi t1, t1, 1450
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xc2410457  # vwredsumu.vs v8, v4, v2
.assert trap == 0 "vwredsumu e16 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsumu e16->32 lane 0 writes a0"
.assert rd_wdata == 0x30003 "vwredsumu e16->32 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vwredsumu e16->32 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x55aa "vwredsumu e16->32 tu lane 1 untouched"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xc6410457  # vwredsum.vs v8, v4, v2
.assert trap == 0 "vwredsum e16 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsum e16->32 lane 0 writes a0"
.assert rd_wdata == 0x10003 "vwredsum e16->32 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xc0410457  # vwredsumu.vs v8, v4, v2, v0.t
.assert trap == 0 "vwredsumu e16 masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsumu e16 masked lane 0 writes a0"
.assert rd_wdata == 0x20004 "vwredsumu e16 masked lane 0"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xc4410457  # vwredsum.vs v8, v4, v2, v0.t
.assert trap == 0 "vwredsum e16 masked retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsum e16 masked lane 0 writes a0"
.assert rd_wdata == 0x10004 "vwredsum e16 masked lane 0"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x5aa30313  # addi t1, t1, 1450
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xc2410457  # vwredsumu.vs v8, v4, v2
.assert trap == 0 "vwredsumu e32 retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsumu e32->64 lane 0 writes a0"
.assert rd_wdata == 0x300000003 "vwredsumu e32->64 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vwredsumu e32->64 tu lane 1 untouched writes a0"
.assert rd_wdata == 0x55aa "vwredsumu e32->64 tu lane 1 untouched"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xc6410457  # vwredsum.vs v8, v4, v2
.assert trap == 0 "vwredsum e32 retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsum e32->64 lane 0 writes a0"
.assert rd_wdata == 0x100000003 "vwredsum e32->64 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xc0410457  # vwredsumu.vs v8, v4, v2, v0.t
.assert trap == 0 "vwredsumu e32 masked retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsumu e32 masked lane 0 writes a0"
.assert rd_wdata == 0x200000004 "vwredsumu e32 masked lane 0"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xc4410457  # vwredsum.vs v8, v4, v2, v0.t
.assert trap == 0 "vwredsum e32 masked retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsum e32 masked lane 0 writes a0"
.assert rd_wdata == 0x100000004 "vwredsum e32 masked lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00936313  # ori t1, t1, 0x9
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xc0410457  # vwredsumu.vs v8, v4, v2, v0.t
.assert trap == 0 "vwredsumu all-zero mask retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsumu all-zero mask copies 64b seed writes a0"
.assert rd_wdata == 0x100000005 "vwredsumu all-zero mask copies 64b seed"
.4byte 0xcd007657  # vsetivli a2, 0, e32, m1, ta, ma
.assert rd_addr == 12 "wred vl=0 writes a2"
.assert rd_wdata == 0x0 "wred vl=0"
.4byte 0xc6410457  # vwredsum.vs v8, v4, v2
.assert trap == 0 "vwredsum vl=0 retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsum vl=0 leaves vd[0] untouched writes a0"
.assert rd_wdata == 0x100000005 "vwredsum vl=0 leaves vd[0] untouched"
.4byte 0x013072d7  # vsetvli t0, zero, e32, m8, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc1317657  # vsetivli a2, 2, e32, m8, tu, mu
.4byte 0x5e0eb857  # vmv.v.i v16, -3
.4byte 0xc130f657  # vsetivli a2, 1, e32, m8, tu, mu
.4byte 0x5e053857  # vmv.v.i v16, 10
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x06400313  # addi t1, zero, 100
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x013072d7  # vsetvli t0, zero, e32, m8, tu, mu
.4byte 0xc70104d7  # vwredsum.vs v9, v16, v2
.assert trap == 0 "vwredsum e32 m8 vlmax odd vd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vwredsum e32 m8 vlmax result writes a0"
.assert rd_wdata == 0x6b "vwredsum e32 m8 vlmax result"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.4byte 0xc1010057  # vwredsumu.vs v0, v16, v2, v0.t
.assert trap == 0 "vwredsumu mf2 masked vd==v0 legal retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "vwredsumu mf2 masked vd==v0 result writes a0"
.assert rd_wdata == 0x6e "vwredsumu mf2 masked vd==v0 result"

# Section 4: Single-width FP reductions (all 5 frm modes on usum & osum, non-assoc, NaNs, signed zero, e32/e64)
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 (fp_red_e32_frm0) readback writes a0"
.assert rd_wdata == 0x0 "frm=0 (fp_red_e32_frm0) readback"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=0 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=0 pos_even writes a0"
.assert rd_wdata == 0x3f800000 "vfredosum.vs frm=0 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=0 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=0 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=0 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=0 pos_even writes a0"
.assert rd_wdata == 0x3f800000 "vfredusum.vs frm=0 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=0 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=0 pos_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xb3800337  # lui t1, 0xb3800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=0 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=0 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800000 "vfredosum.vs frm=0 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=0 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=0 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=0 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=0 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800000 "vfredusum.vs frm=0 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=0 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=0 neg_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=0 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=0 pos_odd writes a0"
.assert rd_wdata == 0x3f800002 "vfredosum.vs frm=0 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=0 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=0 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=0 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=0 pos_odd writes a0"
.assert rd_wdata == 0x3f800002 "vfredusum.vs frm=0 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=0 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=0 pos_odd NX)"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=1 (fp_red_e32_frm1) readback writes a0"
.assert rd_wdata == 0x1 "frm=1 (fp_red_e32_frm1) readback"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=1 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=1 pos_even writes a0"
.assert rd_wdata == 0x3f800000 "vfredosum.vs frm=1 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=1 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=1 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=1 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=1 pos_even writes a0"
.assert rd_wdata == 0x3f800000 "vfredusum.vs frm=1 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=1 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=1 pos_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xb3800337  # lui t1, 0xb3800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=1 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=1 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800000 "vfredosum.vs frm=1 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=1 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=1 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=1 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=1 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800000 "vfredusum.vs frm=1 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=1 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=1 neg_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=1 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=1 pos_odd writes a0"
.assert rd_wdata == 0x3f800001 "vfredosum.vs frm=1 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=1 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=1 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=1 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=1 pos_odd writes a0"
.assert rd_wdata == 0x3f800001 "vfredusum.vs frm=1 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=1 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=1 pos_odd NX)"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=2 (fp_red_e32_frm2) readback writes a0"
.assert rd_wdata == 0x2 "frm=2 (fp_red_e32_frm2) readback"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=2 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=2 pos_even writes a0"
.assert rd_wdata == 0x3f800000 "vfredosum.vs frm=2 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=2 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=2 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=2 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=2 pos_even writes a0"
.assert rd_wdata == 0x3f800000 "vfredusum.vs frm=2 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=2 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=2 pos_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xb3800337  # lui t1, 0xb3800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=2 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=2 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800001 "vfredosum.vs frm=2 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=2 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=2 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=2 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=2 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800001 "vfredusum.vs frm=2 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=2 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=2 neg_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=2 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=2 pos_odd writes a0"
.assert rd_wdata == 0x3f800001 "vfredosum.vs frm=2 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=2 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=2 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=2 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=2 pos_odd writes a0"
.assert rd_wdata == 0x3f800001 "vfredusum.vs frm=2 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=2 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=2 pos_odd NX)"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=3 (fp_red_e32_frm3) readback writes a0"
.assert rd_wdata == 0x3 "frm=3 (fp_red_e32_frm3) readback"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=3 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=3 pos_even writes a0"
.assert rd_wdata == 0x3f800001 "vfredosum.vs frm=3 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=3 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=3 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=3 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=3 pos_even writes a0"
.assert rd_wdata == 0x3f800001 "vfredusum.vs frm=3 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=3 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=3 pos_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xb3800337  # lui t1, 0xb3800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=3 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=3 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800000 "vfredosum.vs frm=3 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=3 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=3 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=3 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=3 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800000 "vfredusum.vs frm=3 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=3 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=3 neg_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=3 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=3 pos_odd writes a0"
.assert rd_wdata == 0x3f800002 "vfredosum.vs frm=3 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=3 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=3 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=3 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=3 pos_odd writes a0"
.assert rd_wdata == 0x3f800002 "vfredusum.vs frm=3 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=3 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=3 pos_odd NX)"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=4 (fp_red_e32_frm4) readback writes a0"
.assert rd_wdata == 0x4 "frm=4 (fp_red_e32_frm4) readback"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=4 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=4 pos_even writes a0"
.assert rd_wdata == 0x3f800001 "vfredosum.vs frm=4 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=4 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=4 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=4 pos_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=4 pos_even writes a0"
.assert rd_wdata == 0x3f800001 "vfredusum.vs frm=4 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=4 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=4 pos_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xb3800337  # lui t1, 0xb3800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=4 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=4 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800001 "vfredosum.vs frm=4 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=4 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=4 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=4 neg_even retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=4 neg_even writes a0"
.assert rd_wdata == 0xffffffffbf800001 "vfredusum.vs frm=4 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=4 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=4 neg_even NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum.vs frm=4 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum.vs frm=4 pos_odd writes a0"
.assert rd_wdata == 0x3f800002 "vfredosum.vs frm=4 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum.vs frm=4 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum.vs frm=4 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum.vs frm=4 pos_odd retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum.vs frm=4 pos_odd writes a0"
.assert rd_wdata == 0x3f800002 "vfredusum.vs frm=4 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum.vs frm=4 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredusum.vs frm=4 pos_odd NX)"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 (reset_rne_after_f32_sweep) readback writes a0"
.assert rd_wdata == 0x0 "frm=0 (reset_rne_after_f32_sweep) readback"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x33800337  # lui t1, 0x33800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x41200337  # lui t1, 0x41200
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x41100337  # lui t1, 0x41100
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum non-assoc retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum strict left-to-right == 1.0 writes a0"
.assert rd_wdata == 0x3f800000 "vfredosum strict left-to-right == 1.0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vfredosum tu lane 1 untouched writes a0"
.assert rd_wdata == 0x41200000 "vfredosum tu lane 1 untouched"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum non-assoc NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfredosum non-assoc NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum szero rne retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum szero RNE -> +0.0 writes a0"
.assert rd_wdata == 0x0 "vfredosum szero RNE -> +0.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum szero RNE clean) writes a1"
.assert rd_wdata == 0x0 "fflags (vfredosum szero RNE clean)"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=2 (szero_rdn) readback writes a0"
.assert rd_wdata == 0x2 "frm=2 (szero_rdn) readback"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum szero rdn retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum szero RDN -> -0.0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "vfredosum szero RDN -> -0.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum szero RDN clean) writes a1"
.assert rd_wdata == 0x0 "fflags (vfredosum szero RDN clean)"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 (restore_rne) readback writes a0"
.assert rd_wdata == 0x0 "frm=0 (restore_rne) readback"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum overflow retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum overflow -> +inf writes a0"
.assert rd_wdata == 0x7f800000 "vfredosum overflow -> +inf"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum overflow OF|NX) writes a1"
.assert rd_wdata == 0x5 "fflags (vfredosum overflow OF|NX)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xff800337  # lui t1, 0xff800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum inf-inf retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum inf-inf -> qNaN writes a0"
.assert rd_wdata == 0x7fc00000 "vfredusum inf-inf -> qNaN"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredusum inf-inf NV) writes a1"
.assert rd_wdata == 0x10 "fflags (vfredusum inf-inf NV)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e003157  # vmv.v.i v2, 0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x7fc00337  # lui t1, 0x7fc00
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x16411457  # vfredmin.vs v8, v4, v2
.assert trap == 0 "vfredmin e32 szero/qNaN retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredmin(-0.0, +0.0, qNaN) == -0.0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "vfredmin(-0.0, +0.0, qNaN) == -0.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredmin qNaN clean) writes a1"
.assert rd_wdata == 0x0 "fflags (vfredmin qNaN clean)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x1e411457  # vfredmax.vs v8, v4, v2
.assert trap == 0 "vfredmax e32 szero/qNaN retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredmax(-0.0, +0.0, qNaN) == +0.0 writes a0"
.assert rd_wdata == 0x0 "vfredmax(-0.0, +0.0, qNaN) == +0.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredmax qNaN clean) writes a1"
.assert rd_wdata == 0x0 "fflags (vfredmax qNaN clean)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x16411457  # vfredmin.vs v8, v4, v2
.assert trap == 0 "vfredmin e32 sNaN retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredmin active sNaN returns min finite 2.0 writes a0"
.assert rd_wdata == 0x40000000 "vfredmin active sNaN returns min finite 2.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredmin active sNaN raises NV) writes a1"
.assert rd_wdata == 0x10 "fflags (vfredmin active sNaN raises NV)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x14411457  # vfredmin.vs v8, v4, v2, v0.t
.assert trap == 0 "vfredmin masked-off sNaN retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredmin masked-off sNaN returns 2.0 writes a0"
.assert rd_wdata == 0x40000000 "vfredmin masked-off sNaN returns 2.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredmin masked-off sNaN leaves NV clear) writes a1"
.assert rd_wdata == 0x0 "fflags (vfredmin masked-off sNaN leaves NV clear)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x0c411457  # vfredosum.vs v8, v4, v2, v0.t
.assert trap == 0 "vfredosum masked-off sNaN retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum masked-off sNaN == 5+2+3=10.0 writes a0"
.assert rd_wdata == 0x41200000 "vfredosum masked-off sNaN == 5+2+3=10.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredosum masked-off sNaN leaves NV clear) writes a1"
.assert rd_wdata == 0x0 "fflags (vfredosum masked-off sNaN leaves NV clear)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x1c411457  # vfredmax.vs v8, v4, v2, v0.t
.assert trap == 0 "vfredmax all-masked-off sNaN seed retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredmax all-masked-off copies sNaN seed verbatim writes a0"
.assert rd_wdata == 0x7f800001 "vfredmax all-masked-off copies sNaN seed verbatim"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfredmax all-masked-off leaves fflags clear) writes a1"
.assert rd_wdata == 0x0 "fflags (vfredmax all-masked-off leaves fflags clear)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x40e00337  # lui t1, 0x40e00
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xcd007657  # vsetivli a2, 0, e32, m1, ta, ma
.assert rd_addr == 12 "fp red vl=0 writes a2"
.assert rd_wdata == 0x0 "fp red vl=0"
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum vl=0 retires"
.4byte 0x16411457  # vfredmin.vs v8, v4, v2
.assert trap == 0 "vfredmin vl=0 retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "fp red vl=0 leaves vd[0] untouched writes a0"
.assert rd_wdata == 0x40e00000 "fp red vl=0 leaves vd[0] untouched"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (fp red vl=0 leaves fflags clear) writes a1"
.assert rd_wdata == 0x0 "fflags (fp red vl=0 leaves fflags clear)"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x40100337  # lui t1, 0x40100
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0xc0020337  # lui t1, 0xc0020
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3ff80337  # lui t1, 0x3ff80
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3fe80337  # lui t1, 0x3fe80
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum e64 == 0.75+1.5-2.25+4.0 writes a0"
.assert rd_wdata == 0x4010000000000000 "vfredusum e64 == 0.75+1.5-2.25+4.0"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 0 "vfredosum e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredosum e64 == 4.0 writes a0"
.assert rd_wdata == 0x4010000000000000 "vfredosum e64 == 4.0"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x16411457  # vfredmin.vs v8, v4, v2
.assert trap == 0 "vfredmin e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredmin e64 == -2.25 writes a0"
.assert rd_wdata == 0xc002000000000000 "vfredmin e64 == -2.25"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x1e411457  # vfredmax.vs v8, v4, v2
.assert trap == 0 "vfredmax e64 retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredmax e64 == 4.0 writes a0"
.assert rd_wdata == 0x4010000000000000 "vfredmax e64 == 4.0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.4byte 0x41100337  # lui t1, 0x41100
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.4byte 0x0c411057  # vfredosum.vs v0, v4, v2, v0.t
.assert trap == 0 "vfredosum mf2 masked vd==v0 legal retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "vfredosum mf2 masked vd==v0 == 4.0 writes a0"
.assert rd_wdata == 0x40800000 "vfredosum mf2 masked vd==v0 == 4.0"
.4byte 0x0d7072d7  # vsetvli t0, zero, e32, mf2, ta, ma
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x40200337  # lui t1, 0x40200
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x0d7072d7  # vsetvli t0, zero, e32, mf2, ta, ma
.4byte 0x06411457  # vfredusum.vs v8, v4, v2
.assert trap == 0 "vfredusum mf2 vlmax retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredusum mf2 vlmax == 2.5 writes a0"
.assert rd_wdata == 0x40200000 "vfredusum mf2 vlmax == 2.5"
.4byte 0x017072d7  # vsetvli t0, zero, e32, mf2, tu, mu
.4byte 0x16411457  # vfredmin.vs v8, v4, v2
.assert trap == 0 "vfredmin mf2 vlmax retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfredmin mf2 vlmax == 0.0 writes a0"
.assert rd_wdata == 0x0 "vfredmin mf2 vlmax == 0.0"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x1e211157  # vfredmax.vs v2, v2, v2
.assert trap == 0 "vfredmax vd==vs2==vs1 legal retires"

# Section 5: Widening FP reductions vfwredusum.vs & vfwredosum.vs (all 5 frm modes, subnormals, overflow, NaNs, m8)
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 (wfp_red_frm0) readback writes a0"
.assert rd_wdata == 0x0 "frm=0 (wfp_red_frm0) readback"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=0 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=0 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000000 "vfwredosum.vs frm=0 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=0 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=0 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=0 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=0 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000000 "vfwredusum.vs frm=0 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=0 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=0 pos_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xbff00337  # lui t1, 0xbff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=0 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=0 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000000 "vfwredosum.vs frm=0 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=0 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=0 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=0 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=0 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000000 "vfwredusum.vs frm=0 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=0 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=0 neg_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00136313  # ori t1, t1, 0x1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=0 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=0 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000002 "vfwredosum.vs frm=0 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=0 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=0 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=0 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=0 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000002 "vfwredusum.vs frm=0 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=0 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=0 pos_odd NX)"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=1 (wfp_red_frm1) readback writes a0"
.assert rd_wdata == 0x1 "frm=1 (wfp_red_frm1) readback"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=1 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=1 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000000 "vfwredosum.vs frm=1 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=1 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=1 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=1 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=1 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000000 "vfwredusum.vs frm=1 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=1 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=1 pos_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xbff00337  # lui t1, 0xbff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=1 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=1 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000000 "vfwredosum.vs frm=1 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=1 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=1 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=1 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=1 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000000 "vfwredusum.vs frm=1 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=1 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=1 neg_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00136313  # ori t1, t1, 0x1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=1 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=1 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000001 "vfwredosum.vs frm=1 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=1 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=1 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=1 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=1 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000001 "vfwredusum.vs frm=1 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=1 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=1 pos_odd NX)"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=2 (wfp_red_frm2) readback writes a0"
.assert rd_wdata == 0x2 "frm=2 (wfp_red_frm2) readback"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=2 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=2 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000000 "vfwredosum.vs frm=2 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=2 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=2 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=2 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=2 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000000 "vfwredusum.vs frm=2 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=2 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=2 pos_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xbff00337  # lui t1, 0xbff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=2 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=2 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000001 "vfwredosum.vs frm=2 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=2 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=2 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=2 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=2 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000001 "vfwredusum.vs frm=2 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=2 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=2 neg_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00136313  # ori t1, t1, 0x1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=2 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=2 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000001 "vfwredosum.vs frm=2 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=2 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=2 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=2 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=2 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000001 "vfwredusum.vs frm=2 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=2 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=2 pos_odd NX)"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=3 (wfp_red_frm3) readback writes a0"
.assert rd_wdata == 0x3 "frm=3 (wfp_red_frm3) readback"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=3 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=3 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000001 "vfwredosum.vs frm=3 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=3 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=3 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=3 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=3 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000001 "vfwredusum.vs frm=3 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=3 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=3 pos_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xbff00337  # lui t1, 0xbff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=3 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=3 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000000 "vfwredosum.vs frm=3 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=3 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=3 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=3 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=3 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000000 "vfwredusum.vs frm=3 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=3 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=3 neg_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00136313  # ori t1, t1, 0x1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=3 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=3 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000002 "vfwredosum.vs frm=3 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=3 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=3 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=3 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=3 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000002 "vfwredusum.vs frm=3 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=3 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=3 pos_odd NX)"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=4 (wfp_red_frm4) readback writes a0"
.assert rd_wdata == 0x4 "frm=4 (wfp_red_frm4) readback"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=4 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=4 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000001 "vfwredosum.vs frm=4 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=4 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=4 pos_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=4 pos_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=4 pos_even writes a0"
.assert rd_wdata == 0x3ff0000000000001 "vfwredusum.vs frm=4 pos_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=4 pos_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=4 pos_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xbff00337  # lui t1, 0xbff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=4 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=4 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000001 "vfwredosum.vs frm=4 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=4 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=4 neg_even NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=4 neg_even retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=4 neg_even writes a0"
.assert rd_wdata == 0xbff0000000000001 "vfwredusum.vs frm=4 neg_even"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=4 neg_even NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=4 neg_even NX)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00136313  # ori t1, t1, 0x1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum.vs frm=4 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum.vs frm=4 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000002 "vfwredosum.vs frm=4 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum.vs frm=4 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredosum.vs frm=4 pos_odd NX)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum.vs frm=4 pos_odd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum.vs frm=4 pos_odd writes a0"
.assert rd_wdata == 0x3ff0000000000002 "vfwredusum.vs frm=4 pos_odd"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum.vs frm=4 pos_odd NX) writes a1"
.assert rd_wdata == 0x1 "fflags (vfwredusum.vs frm=4 pos_odd NX)"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 (reset_rne_after_wfp_sweep) readback writes a0"
.assert rd_wdata == 0x0 "frm=0 (reset_rne_after_wfp_sweep) readback"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e003157  # vmv.v.i v2, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e013257  # vmv.v.i v4, 2
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x40200337  # lui t1, 0x40200
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum subnormal retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum exact subnormal sum 3*2^-149 writes a0"
.assert rd_wdata == 0x36b8000000000000 "vfwredosum exact subnormal sum 3*2^-149"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80bbd7  # vslidedown.vi v23, v8, 1
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vfwredosum tu lane 1 untouched writes a0"
.assert rd_wdata == 0x4020000000000000 "vfwredosum tu lane 1 untouched"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum subnormal exact clean) writes a1"
.assert rd_wdata == 0x0 "fflags (vfwredosum subnormal exact clean)"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=2 (wfp_szero_rdn) readback writes a0"
.assert rd_wdata == 0x2 "frm=2 (wfp_szero_rdn) readback"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum szero rdn retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum szero RDN -> -0.0 writes a0"
.assert rd_wdata == 0x8000000000000000 "vfwredosum szero RDN -> -0.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum szero RDN clean) writes a1"
.assert rd_wdata == 0x0 "fflags (vfwredosum szero RDN clean)"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=3 (wfp_overflow_rup) readback writes a0"
.assert rd_wdata == 0x3 "frm=3 (wfp_overflow_rup) readback"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x7ff00337  # lui t1, 0x7ff00
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 0 "vfwredusum overflow rup retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum DBL_MAX+1 RUP -> +inf writes a0"
.assert rd_wdata == 0x7ff0000000000000 "vfwredusum DBL_MAX+1 RUP -> +inf"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum overflow OF|NX) writes a1"
.assert rd_wdata == 0x5 "fflags (vfwredusum overflow OF|NX)"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 (restore_rne_2) readback writes a0"
.assert rd_wdata == 0x0 "frm=0 (restore_rne_2) readback"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3fc00337  # lui t1, 0x3fc00
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xcc411457  # vfwredosum.vs v8, v4, v2, v0.t
.assert trap == 0 "vfwredosum masked-off sNaN retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum masked-off sNaN == 3.5 writes a0"
.assert rd_wdata == 0x400c000000000000 "vfwredosum masked-off sNaN == 3.5"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum masked-off sNaN clean) writes a1"
.assert rd_wdata == 0x0 "fflags (vfwredosum masked-off sNaN clean)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x7ff00337  # lui t1, 0x7ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00136313  # ori t1, t1, 0x1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xc4411457  # vfwredusum.vs v8, v4, v2, v0.t
.assert trap == 0 "vfwredusum all-masked-off sNaN retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredusum all-masked-off copies f64 sNaN seed writes a0"
.assert rd_wdata == 0x7ff0000000000001 "vfwredusum all-masked-off copies f64 sNaN seed"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredusum all-masked-off clean) writes a1"
.assert rd_wdata == 0x0 "fflags (vfwredusum all-masked-off clean)"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x40220337  # lui t1, 0x40220
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xcd007657  # vsetivli a2, 0, e32, m1, ta, ma
.assert rd_addr == 12 "wfp red vl=0 writes a2"
.assert rd_wdata == 0x0 "wfp red vl=0"
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 0 "vfwredosum vl=0 retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum vl=0 leaves vd[0] untouched writes a0"
.assert rd_wdata == 0x4022000000000000 "vfwredosum vl=0 leaves vd[0] untouched"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwredosum vl=0 clean) writes a1"
.assert rd_wdata == 0x0 "fflags (vfwredosum vl=0 clean)"
.4byte 0x013072d7  # vsetvli t0, zero, e32, m8, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc1317657  # vsetivli a2, 2, e32, m8, tu, mu
.4byte 0x40200337  # lui t1, 0x40200
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc130f657  # vsetivli a2, 1, e32, m8, tu, mu
.4byte 0x3fc00337  # lui t1, 0x3fc00
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x40080337  # lui t1, 0x40080
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x013072d7  # vsetvli t0, zero, e32, m8, tu, mu
.4byte 0xcf0114d7  # vfwredosum.vs v9, v16, v2
.assert trap == 0 "vfwredosum e32 m8 vlmax odd vd retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vfwredosum e32 m8 vlmax == 7.0 writes a0"
.assert rd_wdata == 0x401c000000000000 "vfwredosum e32 m8 vlmax == 7.0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.4byte 0xc5011057  # vfwredusum.vs v0, v16, v2, v0.t
.assert trap == 0 "vfwredusum mf2 masked vd==v0 legal retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "vfwredusum mf2 masked vd==v0 == 4.5 writes a0"
.assert rd_wdata == 0x4012000000000000 "vfwredusum mf2 masked vd==v0 == 4.5"

# Section 6: 15 illegal-instruction traps covering reduction width, overlap, v0, alignment, frm, and vill rules
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x5e0cb457  # vmv.v.i v8, -7
.4byte 0xc2410457  # vwredsumu.vs v8, v4, v2
.assert trap == 1 "vwredsumu e64 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vwredsumu e64 mcause writes a0"
.assert rd_wdata == 0x2 "vwredsumu e64 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vwredsumu e64 mtval writes a0"
.assert rd_wdata == 0xc2410457 "vwredsumu e64 mtval"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsumu e64 leaves v8 intact writes a0"
.assert rd_wdata == 0xfffffffffffffff9 "vwredsumu e64 leaves v8 intact"
.4byte 0xc6410457  # vwredsum.vs v8, v4, v2
.assert trap == 1 "vwredsum e64 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vwredsum e64 mcause writes a0"
.assert rd_wdata == 0x2 "vwredsum e64 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vwredsum e64 mtval writes a0"
.assert rd_wdata == 0xc6410457 "vwredsum e64 mtval"
.4byte 0xc6411457  # vfwredusum.vs v8, v4, v2
.assert trap == 1 "vfwredusum e64 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfwredusum e64 mcause writes a0"
.assert rd_wdata == 0x2 "vfwredusum e64 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfwredusum e64 mtval writes a0"
.assert rd_wdata == 0xc6411457 "vfwredusum e64 mtval"
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 1 "vfwredosum e64 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfwredosum e64 mcause writes a0"
.assert rd_wdata == 0x2 "vfwredosum e64 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfwredosum e64 mtval writes a0"
.assert rd_wdata == 0xce411457 "vfwredosum e64 mtval"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 1 "vfredosum e8 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfredosum e8 mcause writes a0"
.assert rd_wdata == 0x2 "vfredosum e8 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfredosum e8 mtval writes a0"
.assert rd_wdata == 0xe411457 "vfredosum e8 mtval"
.4byte 0xce411457  # vfwredosum.vs v8, v4, v2
.assert trap == 1 "vfwredosum e8 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfwredosum e8 mcause writes a0"
.assert rd_wdata == 0x2 "vfwredosum e8 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfwredosum e8 mtval writes a0"
.assert rd_wdata == 0xce411457 "vfwredosum e8 mtval"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0cb457  # vmv.v.i v8, -7
.4byte 0xc2420457  # vwredsumu.vs v8, v4, v4
.assert trap == 1 "vwredsumu vs1==vs2 overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vwredsumu vs1==vs2 overlap mcause writes a0"
.assert rd_wdata == 0x2 "vwredsumu vs1==vs2 overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vwredsumu vs1==vs2 overlap mtval writes a0"
.assert rd_wdata == 0xc2420457 "vwredsumu vs1==vs2 overlap mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vwredsumu vs1==vs2 overlap leaves v8 intact writes a0"
.assert rd_wdata == 0xfffffffffffffff9 "vwredsumu vs1==vs2 overlap leaves v8 intact"
.4byte 0xce421457  # vfwredosum.vs v8, v4, v4
.assert trap == 1 "vfwredosum vs1==vs2 overlap traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfwredosum vs1==vs2 overlap mcause writes a0"
.assert rd_wdata == 0x2 "vfwredosum vs1==vs2 overlap mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfwredosum vs1==vs2 overlap mtval writes a0"
.assert rd_wdata == 0xce421457 "vfwredosum vs1==vs2 overlap mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vfwredosum vs1==vs2 overlap leaves v8 intact writes a0"
.assert rd_wdata == 0xfffffffffffffff9 "vfwredosum vs1==vs2 overlap leaves v8 intact"
.4byte 0x00012457  # vredsum.vs v8, v0, v2, v0.t
.assert trap == 1 "vredsum masked vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vredsum masked vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vredsum masked vs2==v0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vredsum masked vs2==v0 mtval writes a0"
.assert rd_wdata == 0x12457 "vredsum masked vs2==v0 mtval"
.4byte 0x00402457  # vredsum.vs v8, v4, v0, v0.t
.assert trap == 1 "vredsum masked vs1==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vredsum masked vs1==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vredsum masked vs1==v0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vredsum masked vs1==v0 mtval writes a0"
.assert rd_wdata == 0x402457 "vredsum masked vs1==v0 mtval"
.4byte 0x0c011457  # vfredosum.vs v8, v0, v2, v0.t
.assert trap == 1 "vfredosum masked vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfredosum masked vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vfredosum masked vs2==v0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfredosum masked vs2==v0 mtval writes a0"
.assert rd_wdata == 0xc011457 "vfredosum masked vs2==v0 mtval"
.4byte 0x0c401457  # vfredosum.vs v8, v4, v0, v0.t
.assert trap == 1 "vfredosum masked vs1==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfredosum masked vs1==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vfredosum masked vs1==v0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfredosum masked vs1==v0 mtval writes a0"
.assert rd_wdata == 0xc401457 "vfredosum masked vs1==v0 mtval"
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x02512457  # vredsum.vs v8, v5, v2
.assert trap == 1 "vredsum misaligned vs2 m2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vredsum misaligned vs2 m2 mcause writes a0"
.assert rd_wdata == 0x2 "vredsum misaligned vs2 m2 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vredsum misaligned vs2 m2 mtval writes a0"
.assert rd_wdata == 0x2512457 "vredsum misaligned vs2 m2 mtval"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x0022d073  # csrwi frm, 5
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=5 (reserved_frm5) readback writes a0"
.assert rd_wdata == 0x5 "frm=5 (reserved_frm5) readback"
.4byte 0x0e411457  # vfredosum.vs v8, v4, v2
.assert trap == 1 "vfredosum reserved frm=5 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vfredosum reserved frm=5 mcause writes a0"
.assert rd_wdata == 0x2 "vfredosum reserved frm=5 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vfredosum reserved frm=5 mtval writes a0"
.assert rd_wdata == 0xe411457 "vfredosum reserved frm=5 mtval"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 (restore_after_frm5) readback writes a0"
.assert rd_wdata == 0x0 "frm=0 (restore_after_frm5) readback"
.4byte 0xc1f0f657  # vsetivli a2, 1, e64, mf2, tu, mu
.assert rd_addr == 12 "vill=1 config writes a2"
.assert rd_wdata == 0x0 "vill=1 config"
.4byte 0x02412457  # vredsum.vs v8, v4, v2
.assert trap == 1 "vredsum under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vredsum under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vredsum under vill=1 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vredsum under vill=1 mtval writes a0"
.assert rd_wdata == 0x2412457 "vredsum under vill=1 mtval"
