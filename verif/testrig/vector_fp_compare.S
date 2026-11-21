# Vector floating-point comparison masks and accrued flags.
.noshrink
# Enable FS and VS and clear fcsr.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x00305073  # csrwi fcsr, 0

# Binary32 finite operands. v8 = [-1, 2], v9 = [-1, 3].
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "VL writes x12"
.assert rd_wdata == 0x2 "e32 VL is two"
.4byte 0xbf8002b7  # lui t0, 0xbf800
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x404003b7  # lui t2, 0x40400
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x4202e4d7  # vmv.s.x v9, t0
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0xf00300d3  # fmv.w.x ft1, t1
# Vector-vector comparisons exercise equality and both operand orders.
.4byte 0x62849c57  # vmfeq.vv v24, v8, v9
.assert trap == 0 "vmfeq.vv retires"
.4byte 0x43882557  # vcpop.m a0, v24
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4388a5d7  # vfirst.m a1, v24
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x72849857  # vmfne.vv v16, v8, v9
.assert trap == 0 "vmfne.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x6e849857  # vmflt.vv v16, v8, v9
.assert trap == 0 "vmflt.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x66849857  # vmfle.vv v16, v8, v9
.assert trap == 0 "vmfle.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x2 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x6e941857  # vmflt.vv v16, v9, v8
.assert trap == 0 "vmflt.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x0 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0xffffffffffffffff "first true index of compared mask bits"
.4byte 0x66941857  # vmfle.vv v16, v9, v8
.assert trap == 0 "vmfle.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
# Vector-scalar comparisons against -1 and 2 cover the ordering boundaries.
.4byte 0x62805857  # vmfeq.vf v16, v8, ft0
.assert trap == 0 "vmfeq.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x72805857  # vmfne.vf v16, v8, ft0
.assert trap == 0 "vmfne.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x6e805857  # vmflt.vf v16, v8, ft0
.assert trap == 0 "vmflt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x0 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0xffffffffffffffff "first true index of compared mask bits"
.4byte 0x66805857  # vmfle.vf v16, v8, ft0
.assert trap == 0 "vmfle.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x76805857  # vmfgt.vf v16, v8, ft0
.assert trap == 0 "vmfgt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x7e805857  # vmfge.vf v16, v8, ft0
.assert trap == 0 "vmfge.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x2 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x6e80d857  # vmflt.vf v16, v8, ft1
.assert trap == 0 "vmflt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x6680d857  # vmfle.vf v16, v8, ft1
.assert trap == 0 "vmfle.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x2 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x7680d857  # vmfgt.vf v16, v8, ft1
.assert trap == 0 "vmfgt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x0 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0xffffffffffffffff "first true index of compared mask bits"
.4byte 0x7e80d857  # vmfge.vf v16, v8, ft1
.assert trap == 0 "vmfge.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x0 "finite comparisons leave flags clear"

# Binary32 quiet NaN in vector element one.
.4byte 0x7fc00e37  # lui t3, 0x7fc00
.4byte 0x5e0e4557  # vmv.v.x v10, t3
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x62a41857  # vmfeq.vv v16, v10, v8
.assert trap == 0 "vmfeq.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x72a05857  # vmfne.vf v16, v10, ft0
.assert trap == 0 "vmfne.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x0 "quiet NaN equality and inequality leave flags clear"
.4byte 0x6ea0d857  # vmflt.vf v16, v10, ft1
.assert trap == 0 "vmflt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x10 "less than with quiet NaN raises NV"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x66a41857  # vmfle.vv v16, v10, v8
.assert trap == 0 "vmfle.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x10 "less than or equal with quiet NaN raises NV"
.4byte 0x00105073  # csrwi fflags, 0

# Binary32 signaling NaN in vector element one.
.4byte 0x7f800e37  # lui t3, 0x7f800
.4byte 0x001e0e13  # addi t3, t3, 1
.4byte 0x5e0e4557  # vmv.v.x v10, t3
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x62a41857  # vmfeq.vv v16, v10, v8
.assert trap == 0 "vmfeq.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x10 "equality with signaling NaN raises NV"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x72a05857  # vmfne.vf v16, v10, ft0
.assert trap == 0 "vmfne.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x10 "inequality with signaling NaN raises NV"
.4byte 0x00105073  # csrwi fflags, 0

# Binary64 finite operands. v8 = [-1, 2], v9 = [-1, 3].
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "VL writes x12"
.assert rd_wdata == 0x2 "e64 VL is two"
.4byte 0xbff002b7  # lui t0, 0xbff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x400803b7  # lui t2, 0x40080
.4byte 0x02039393  # slli t2, t2, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x4202e4d7  # vmv.s.x v9, t0
.4byte 0xf2028053  # fmv.d.x ft0, t0
.4byte 0xf20300d3  # fmv.d.x ft1, t1
# Vector-vector comparisons exercise equality and both operand orders.
.4byte 0x62849857  # vmfeq.vv v16, v8, v9
.assert trap == 0 "vmfeq.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x72849857  # vmfne.vv v16, v8, v9
.assert trap == 0 "vmfne.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x6e849857  # vmflt.vv v16, v8, v9
.assert trap == 0 "vmflt.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x66849857  # vmfle.vv v16, v8, v9
.assert trap == 0 "vmfle.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x2 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x6e941857  # vmflt.vv v16, v9, v8
.assert trap == 0 "vmflt.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x0 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0xffffffffffffffff "first true index of compared mask bits"
.4byte 0x66941857  # vmfle.vv v16, v9, v8
.assert trap == 0 "vmfle.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
# Vector-scalar comparisons against -1 and 2 cover the ordering boundaries.
.4byte 0x62805857  # vmfeq.vf v16, v8, ft0
.assert trap == 0 "vmfeq.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x72805857  # vmfne.vf v16, v8, ft0
.assert trap == 0 "vmfne.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x6e805857  # vmflt.vf v16, v8, ft0
.assert trap == 0 "vmflt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x0 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0xffffffffffffffff "first true index of compared mask bits"
.4byte 0x66805857  # vmfle.vf v16, v8, ft0
.assert trap == 0 "vmfle.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x76805857  # vmfgt.vf v16, v8, ft0
.assert trap == 0 "vmfgt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x7e805857  # vmfge.vf v16, v8, ft0
.assert trap == 0 "vmfge.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x2 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x6e80d857  # vmflt.vf v16, v8, ft1
.assert trap == 0 "vmflt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x6680d857  # vmfle.vf v16, v8, ft1
.assert trap == 0 "vmfle.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x2 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x7680d857  # vmfgt.vf v16, v8, ft1
.assert trap == 0 "vmfgt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x0 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0xffffffffffffffff "first true index of compared mask bits"
.4byte 0x7e80d857  # vmfge.vf v16, v8, ft1
.assert trap == 0 "vmfge.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x0 "finite comparisons leave flags clear"

# Binary64 quiet NaN in the scalar operand.
.4byte 0x7ff80e37  # lui t3, 0x7ff80
.4byte 0x020e1e13  # slli t3, t3, 32
.4byte 0xf20e0153  # fmv.d.x ft2, t3
.4byte 0x62815857  # vmfeq.vf v16, v8, ft2
.assert trap == 0 "vmfeq.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x0 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0xffffffffffffffff "first true index of compared mask bits"
.4byte 0x72815857  # vmfne.vf v16, v8, ft2
.assert trap == 0 "vmfne.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x2 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x0 "quiet NaN equality and inequality leave flags clear"
.4byte 0x76815857  # vmfgt.vf v16, v8, ft2
.assert trap == 0 "vmfgt.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x0 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0xffffffffffffffff "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x10 "greater than with quiet NaN raises NV"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x7e815857  # vmfge.vf v16, v8, ft2
.assert trap == 0 "vmfge.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x0 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0xffffffffffffffff "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x10 "greater than or equal with quiet NaN raises NV"
.4byte 0x00105073  # csrwi fflags, 0

# Binary64 signaling NaN in vector element one.
.4byte 0x7ff00e37  # lui t3, 0x7ff00
.4byte 0x020e1e13  # slli t3, t3, 32
.4byte 0x001e0e13  # addi t3, t3, 1
.4byte 0x5e0e4557  # vmv.v.x v10, t3
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x62a05857  # vmfeq.vf v16, v10, ft0
.assert trap == 0 "vmfeq.vf retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x10 "equality with signaling NaN raises NV"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x72a41857  # vmfne.vv v16, v10, v8
.assert trap == 0 "vmfne.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x1 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x10 "inequality with signaling NaN raises NV"
.4byte 0x00105073  # csrwi fflags, 0

# The guard enables element zero, where -1 is less than 2.
.4byte 0x00100e93  # addi t4, zero, 1
.4byte 0x420ee057  # vmv.s.x v0, t4
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0xcd817657  # vsetivli a2, 2, e64, m1, ta, ma
.assert rd_addr == 12 "VL writes x12"
.assert rd_wdata == 0x2 "e64 VL is two"
# The scalar mask reads use the same guard as the compare.
.4byte 0x6ca59857  # vmflt.vv v16, v10, v11, v0.t
.assert trap == 0 "vmflt.vv retires"
.4byte 0x41082557  # vcpop.m a0, v16, v0.t
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4108a5d7  # vfirst.m a1, v16, v0.t
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x0 "masked signaling NaN leaves flags clear"

# The unmasked compare defines both active result bits.
.4byte 0x6ea59857  # vmflt.vv v16, v10, v11
.assert trap == 0 "vmflt.vv retires"
.4byte 0x43082557  # vcpop.m a0, v16
.assert rd_addr == 10 "mask population writes x10"
.assert rd_wdata == 0x1 "population of compared mask bits"
.4byte 0x4308a5d7  # vfirst.m a1, v16
.assert rd_addr == 11 "first true index writes x11"
.assert rd_wdata == 0x0 "first true index of compared mask bits"
.4byte 0x00102673  # csrr a2, fflags
.assert rd_addr == 12 "fflags writes x12"
.assert rd_wdata == 0x10 "active signaling NaN raises NV"
