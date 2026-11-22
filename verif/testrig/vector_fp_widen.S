# Widening floating-point arithmetic and fused multiply-add operations (e32 -> e64).
.noshrink

# Enable FS and VS, zero v0..v31, and initialize frm=0 and fflags=0.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 1536
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 readback (init) writes x10"
.assert rd_wdata == 0x0 "frm=0 readback (init)"

# Early control readout: vfwadd.vv v10, v4, v6 at e32, m1 (unique vmv.x.s a0, v10).
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "control e32 m1 vl=2 writes x12"
.assert rd_wdata == 0x2 "control e32 m1 vl=2"
.4byte 0xc0600337  # lui t1, 0xc0600
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x3fc00337  # lui t1, 0x3fc00
.4byte 0x3bd36257  # vslide1up.vx v4, v29, t1
.4byte 0x3fa00337  # lui t1, 0x3fa00
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40100337  # lui t1, 0x40100
.4byte 0x3bd36357  # vslide1up.vx v6, v29, t1
.4byte 0xc2431557  # vfwadd.vv v10, v4, v6
.assert trap == 0 "vfwadd.vv control retires"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vfwadd.vv control lane 0 writes x10"
.assert rd_wdata == 0x400e000000000000 "vfwadd.vv control lane 0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv control) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.vv control)"

# Load reusable 3-lane tie vectors for 5-mode frm sweep across all 16 rounding-capable widening ops.
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 vl=3 writes x12"
.assert rd_wdata == 0x3 "e32 m1 vl=3"
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x3a236ed7  # vslide1up.vx v29, v2, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x25400337  # lui t1, 0x25400
.4byte 0x5e0341d7  # vmv.v.x v3, t1
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x3a336ed7  # vslide1up.vx v29, v3, t1
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0xa5400337  # lui t1, 0xa5400
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x3a436ed7  # vslide1up.vx v29, v4, t1
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x3bd36257  # vslide1up.vx v4, v29, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e0342d7  # vmv.v.x v5, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3a536ed7  # vslide1up.vx v29, v5, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3bd362d7  # vslide1up.vx v5, v29, t1
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x3a636ed7  # vslide1up.vx v29, v6, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3bd36357  # vslide1up.vx v6, v29, t1
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x5e0343d7  # vmv.v.x v7, t1
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x3a736ed7  # vslide1up.vx v29, v7, t1
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0x3bd363d7  # vslide1up.vx v7, v29, t1
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x5e034657  # vmv.v.x v12, t1
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x3ac36ed7  # vslide1up.vx v29, v12, t1
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0x3bd36657  # vslide1up.vx v12, v29, t1
.4byte 0x25000337  # lui t1, 0x25000
.4byte 0xf00300d3  # fmv.w.x f1, t1
.4byte 0xa5000337  # lui t1, 0xa5000
.4byte 0xf0030153  # fmv.w.x f2, t1
.4byte 0x25400337  # lui t1, 0x25400
.4byte 0xf00301d3  # fmv.w.x f3, t1
.4byte 0xa5400337  # lui t1, 0xa5400
.4byte 0xf0030253  # fmv.w.x f4, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.assert rd_addr == 12 "e64 m2 vl=3 writes x12"
.assert rd_wdata == 0x3 "e64 m2 vl=3"
.4byte 0xbff00337  # lui t1, 0xbff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00200f93  # addi t6, zero, 2
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3a836e57  # vslide1up.vx v28, v8, t1
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3bc36457  # vslide1up.vx v8, v28, t1

# All 5 frm modes (0=rne, 1=rtz, 2=rdn, 3=rup, 4=rmm) across all 16 rounding-capable widening ops.

# Rounding sweep frm = 0 across all 16 rounding-capable widening encodings.
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 readback (sweep_0) writes x10"
.assert rd_wdata == 0x0 "frm=0 readback (sweep_0)"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd.vv frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vv frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc261d957  # vfwadd.vf v18, v6, f3
.assert trap == 0 "vfwadd.vf frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vf frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vf frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca221a57  # vfwsub.vv v20, v2, v4
.assert trap == 0 "vfwsub.vv frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vv frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vv frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca625b57  # vfwsub.vf v22, v6, f4
.assert trap == 0 "vfwsub.vf frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vf frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vf frm=0)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwadd.vv frm=0 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=0 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwadd.vv frm=0 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=0 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.vv frm=0 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.vf frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.vf frm=0 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=0 lane 1 writes x10"
.assert rd_wdata == 0xbfeffffffffffffe "vfwadd.vf frm=0 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=0 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vfwadd.vf frm=0 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.vv frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwsub.vv frm=0 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=0 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwsub.vv frm=0 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=0 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.vv frm=0 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.vf frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.vf frm=0 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=0 lane 1 writes x10"
.assert rd_wdata == 0xbfeffffffffffffe "vfwsub.vf frm=0 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=0 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vfwsub.vf frm=0 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2839857  # vfwadd.wv v16, v8, v7
.assert trap == 0 "vfwadd.wv frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wv frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd280d957  # vfwadd.wf v18, v8, f1
.assert trap == 0 "vfwadd.wf frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wf frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wf frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda861a57  # vfwsub.wv v20, v8, v12
.assert trap == 0 "vfwsub.wv frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wv frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wv frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda815b57  # vfwsub.wf v22, v8, f2
.assert trap == 0 "vfwsub.wf frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wf frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wf frm=0)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wv frm=0 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=0 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wv frm=0 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=0 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwadd.wv frm=0 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.wf frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wf frm=0 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=0 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wf frm=0 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=0 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwadd.wf frm=0 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.wv frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wv frm=0 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=0 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wv frm=0 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=0 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwsub.wv frm=0 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.wf frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wf frm=0 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=0 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wf frm=0 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=0 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwsub.wf frm=0 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2539857  # vfwmacc.vv v16, v7, v5
.assert trap == 0 "vfwmacc.vv frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vv frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf250d957  # vfwmacc.vf v18, f1, v5
.assert trap == 0 "vfwmacc.vf frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vf frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vf frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6539a57  # vfwnmacc.vv v20, v7, v5
.assert trap == 0 "vfwnmacc.vv frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vv frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vv frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf650db57  # vfwnmacc.vf v22, f1, v5
.assert trap == 0 "vfwnmacc.vf frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vf frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vf frm=0)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vv frm=0 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=0 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vv frm=0 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=0 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmacc.vv frm=0 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmacc.vf frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vf frm=0 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=0 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vf frm=0 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=0 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmacc.vf frm=0 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmacc.vv frm=0 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vv frm=0 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=0 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vv frm=0 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=0 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmacc.vv frm=0 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmacc.vf frm=0 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vf frm=0 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=0 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vf frm=0 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=0 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmacc.vf frm=0 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa539857  # vfwmsac.vv v16, v7, v5
.assert trap == 0 "vfwmsac.vv frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vv frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vv frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa50d957  # vfwmsac.vf v18, f1, v5
.assert trap == 0 "vfwmsac.vf frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vf frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vf frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe539a57  # vfwnmsac.vv v20, v7, v5
.assert trap == 0 "vfwnmsac.vv frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vv frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vv frm=0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe50db57  # vfwnmsac.vf v22, f1, v5
.assert trap == 0 "vfwnmsac.vf frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vf frm=0) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vf frm=0)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmsac.vv frm=0 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmsac.vv frm=0 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=0 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwmsac.vv frm=0 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=0 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmsac.vv frm=0 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmsac.vf frm=0 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmsac.vf frm=0 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=0 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwmsac.vf frm=0 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=0 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmsac.vf frm=0 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmsac.vv frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmsac.vv frm=0 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=0 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwnmsac.vv frm=0 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=0 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmsac.vv frm=0 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmsac.vf frm=0 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmsac.vf frm=0 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=0 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwnmsac.vf frm=0 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=0 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmsac.vf frm=0 lane 2"

# Rounding sweep frm = 1 across all 16 rounding-capable widening encodings.
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=1 readback (sweep_1) writes x10"
.assert rd_wdata == 0x1 "frm=1 readback (sweep_1)"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd.vv frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vv frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc261d957  # vfwadd.vf v18, v6, f3
.assert trap == 0 "vfwadd.vf frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vf frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vf frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca221a57  # vfwsub.vv v20, v2, v4
.assert trap == 0 "vfwsub.vv frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vv frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vv frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca625b57  # vfwsub.vf v22, v6, f4
.assert trap == 0 "vfwsub.vf frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vf frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vf frm=1)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwadd.vv frm=1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=1 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwadd.vv frm=1 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=1 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwadd.vv frm=1 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.vf frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwadd.vf frm=1 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=1 lane 1 writes x10"
.assert rd_wdata == 0xbfeffffffffffffe "vfwadd.vf frm=1 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=1 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vfwadd.vf frm=1 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.vv frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwsub.vv frm=1 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=1 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwsub.vv frm=1 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=1 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwsub.vv frm=1 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.vf frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwsub.vf frm=1 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=1 lane 1 writes x10"
.assert rd_wdata == 0xbfeffffffffffffe "vfwsub.vf frm=1 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=1 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vfwsub.vf frm=1 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2839857  # vfwadd.wv v16, v8, v7
.assert trap == 0 "vfwadd.wv frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wv frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd280d957  # vfwadd.wf v18, v8, f1
.assert trap == 0 "vfwadd.wf frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wf frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wf frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda861a57  # vfwsub.wv v20, v8, v12
.assert trap == 0 "vfwsub.wv frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wv frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wv frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda815b57  # vfwsub.wf v22, v8, f2
.assert trap == 0 "vfwsub.wf frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wf frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wf frm=1)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.wv frm=1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=1 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wv frm=1 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=1 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwadd.wv frm=1 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.wf frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.wf frm=1 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=1 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wf frm=1 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=1 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwadd.wf frm=1 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.wv frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.wv frm=1 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=1 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wv frm=1 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=1 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwsub.wv frm=1 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.wf frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.wf frm=1 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=1 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wf frm=1 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=1 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwsub.wf frm=1 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2539857  # vfwmacc.vv v16, v7, v5
.assert trap == 0 "vfwmacc.vv frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vv frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf250d957  # vfwmacc.vf v18, f1, v5
.assert trap == 0 "vfwmacc.vf frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vf frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vf frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6539a57  # vfwnmacc.vv v20, v7, v5
.assert trap == 0 "vfwnmacc.vv frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vv frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vv frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf650db57  # vfwnmacc.vf v22, f1, v5
.assert trap == 0 "vfwnmacc.vf frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vf frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vf frm=1)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwmacc.vv frm=1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=1 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vv frm=1 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=1 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmacc.vv frm=1 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmacc.vf frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwmacc.vf frm=1 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=1 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vf frm=1 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=1 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmacc.vf frm=1 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmacc.vv frm=1 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwnmacc.vv frm=1 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=1 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vv frm=1 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=1 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmacc.vv frm=1 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmacc.vf frm=1 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwnmacc.vf frm=1 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=1 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vf frm=1 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=1 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmacc.vf frm=1 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa539857  # vfwmsac.vv v16, v7, v5
.assert trap == 0 "vfwmsac.vv frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vv frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vv frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa50d957  # vfwmsac.vf v18, f1, v5
.assert trap == 0 "vfwmsac.vf frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vf frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vf frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe539a57  # vfwnmsac.vv v20, v7, v5
.assert trap == 0 "vfwnmsac.vv frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vv frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vv frm=1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe50db57  # vfwnmsac.vf v22, f1, v5
.assert trap == 0 "vfwnmsac.vf frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vf frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vf frm=1)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmsac.vv frm=1 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmsac.vv frm=1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=1 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmsac.vv frm=1 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=1 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwmsac.vv frm=1 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmsac.vf frm=1 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmsac.vf frm=1 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=1 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmsac.vf frm=1 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=1 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwmsac.vf frm=1 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmsac.vv frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmsac.vv frm=1 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=1 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmsac.vv frm=1 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=1 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwnmsac.vv frm=1 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmsac.vf frm=1 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmsac.vf frm=1 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=1 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmsac.vf frm=1 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=1 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwnmsac.vf frm=1 lane 2"

# Rounding sweep frm = 2 across all 16 rounding-capable widening encodings.
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=2 readback (sweep_2) writes x10"
.assert rd_wdata == 0x2 "frm=2 readback (sweep_2)"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd.vv frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vv frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc261d957  # vfwadd.vf v18, v6, f3
.assert trap == 0 "vfwadd.vf frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vf frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vf frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca221a57  # vfwsub.vv v20, v2, v4
.assert trap == 0 "vfwsub.vv frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vv frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vv frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca625b57  # vfwsub.vf v22, v6, f4
.assert trap == 0 "vfwsub.vf frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vf frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vf frm=2)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwadd.vv frm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=2 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwadd.vv frm=2 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=2 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwadd.vv frm=2 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.vf frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwadd.vf frm=2 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=2 lane 1 writes x10"
.assert rd_wdata == 0xbfefffffffffffff "vfwadd.vf frm=2 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=2 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vfwadd.vf frm=2 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.vv frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwsub.vv frm=2 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=2 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwsub.vv frm=2 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=2 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwsub.vv frm=2 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.vf frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwsub.vf frm=2 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=2 lane 1 writes x10"
.assert rd_wdata == 0xbfefffffffffffff "vfwsub.vf frm=2 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=2 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vfwsub.vf frm=2 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2839857  # vfwadd.wv v16, v8, v7
.assert trap == 0 "vfwadd.wv frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wv frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd280d957  # vfwadd.wf v18, v8, f1
.assert trap == 0 "vfwadd.wf frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wf frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wf frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda861a57  # vfwsub.wv v20, v8, v12
.assert trap == 0 "vfwsub.wv frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wv frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wv frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda815b57  # vfwsub.wf v22, v8, f2
.assert trap == 0 "vfwsub.wf frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wf frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wf frm=2)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.wv frm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=2 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wv frm=2 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=2 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwadd.wv frm=2 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.wf frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.wf frm=2 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=2 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wf frm=2 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=2 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwadd.wf frm=2 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.wv frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.wv frm=2 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=2 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wv frm=2 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=2 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwsub.wv frm=2 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.wf frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.wf frm=2 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=2 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wf frm=2 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=2 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwsub.wf frm=2 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2539857  # vfwmacc.vv v16, v7, v5
.assert trap == 0 "vfwmacc.vv frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vv frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf250d957  # vfwmacc.vf v18, f1, v5
.assert trap == 0 "vfwmacc.vf frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vf frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vf frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6539a57  # vfwnmacc.vv v20, v7, v5
.assert trap == 0 "vfwnmacc.vv frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vv frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vv frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf650db57  # vfwnmacc.vf v22, f1, v5
.assert trap == 0 "vfwnmacc.vf frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vf frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vf frm=2)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwmacc.vv frm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=2 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vv frm=2 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=2 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmacc.vv frm=2 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmacc.vf frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwmacc.vf frm=2 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=2 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vf frm=2 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=2 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmacc.vf frm=2 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmacc.vv frm=2 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vv frm=2 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=2 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000003 "vfwnmacc.vv frm=2 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=2 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmacc.vv frm=2 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmacc.vf frm=2 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vf frm=2 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=2 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000003 "vfwnmacc.vf frm=2 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=2 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmacc.vf frm=2 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa539857  # vfwmsac.vv v16, v7, v5
.assert trap == 0 "vfwmsac.vv frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vv frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vv frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa50d957  # vfwmsac.vf v18, f1, v5
.assert trap == 0 "vfwmsac.vf frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vf frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vf frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe539a57  # vfwnmsac.vv v20, v7, v5
.assert trap == 0 "vfwnmsac.vv frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vv frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vv frm=2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe50db57  # vfwnmsac.vf v22, f1, v5
.assert trap == 0 "vfwnmsac.vf frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vf frm=2) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vf frm=2)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmsac.vv frm=2 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmsac.vv frm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=2 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwmsac.vv frm=2 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=2 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwmsac.vv frm=2 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmsac.vf frm=2 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmsac.vf frm=2 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=2 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwmsac.vf frm=2 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=2 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwmsac.vf frm=2 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmsac.vv frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmsac.vv frm=2 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=2 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmsac.vv frm=2 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=2 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmsac.vv frm=2 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmsac.vf frm=2 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwnmsac.vf frm=2 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=2 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmsac.vf frm=2 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=2 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmsac.vf frm=2 lane 2"

# Rounding sweep frm = 3 across all 16 rounding-capable widening encodings.
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=3 readback (sweep_3) writes x10"
.assert rd_wdata == 0x3 "frm=3 readback (sweep_3)"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd.vv frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vv frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc261d957  # vfwadd.vf v18, v6, f3
.assert trap == 0 "vfwadd.vf frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vf frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vf frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca221a57  # vfwsub.vv v20, v2, v4
.assert trap == 0 "vfwsub.vv frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vv frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vv frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca625b57  # vfwsub.vf v22, v6, f4
.assert trap == 0 "vfwsub.vf frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vf frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vf frm=3)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.vv frm=3 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=3 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwadd.vv frm=3 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=3 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.vv frm=3 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.vf frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.vf frm=3 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=3 lane 1 writes x10"
.assert rd_wdata == 0xbfeffffffffffffe "vfwadd.vf frm=3 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=3 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000001 "vfwadd.vf frm=3 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.vv frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.vv frm=3 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=3 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwsub.vv frm=3 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=3 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.vv frm=3 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.vf frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.vf frm=3 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=3 lane 1 writes x10"
.assert rd_wdata == 0xbfeffffffffffffe "vfwsub.vf frm=3 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=3 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000001 "vfwsub.vf frm=3 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2839857  # vfwadd.wv v16, v8, v7
.assert trap == 0 "vfwadd.wv frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wv frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd280d957  # vfwadd.wf v18, v8, f1
.assert trap == 0 "vfwadd.wf frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wf frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wf frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda861a57  # vfwsub.wv v20, v8, v12
.assert trap == 0 "vfwsub.wv frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wv frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wv frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda815b57  # vfwsub.wf v22, v8, f2
.assert trap == 0 "vfwsub.wf frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wf frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wf frm=3)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wv frm=3 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=3 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwadd.wv frm=3 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=3 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwadd.wv frm=3 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.wf frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wf frm=3 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=3 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwadd.wf frm=3 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=3 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwadd.wf frm=3 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.wv frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wv frm=3 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=3 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwsub.wv frm=3 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=3 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwsub.wv frm=3 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.wf frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wf frm=3 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=3 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwsub.wf frm=3 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=3 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwsub.wf frm=3 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2539857  # vfwmacc.vv v16, v7, v5
.assert trap == 0 "vfwmacc.vv frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vv frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf250d957  # vfwmacc.vf v18, f1, v5
.assert trap == 0 "vfwmacc.vf frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vf frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vf frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6539a57  # vfwnmacc.vv v20, v7, v5
.assert trap == 0 "vfwnmacc.vv frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vv frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vv frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf650db57  # vfwnmacc.vf v22, f1, v5
.assert trap == 0 "vfwnmacc.vf frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vf frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vf frm=3)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vv frm=3 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=3 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwmacc.vv frm=3 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=3 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmacc.vv frm=3 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmacc.vf frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vf frm=3 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=3 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwmacc.vf frm=3 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=3 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmacc.vf frm=3 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmacc.vv frm=3 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwnmacc.vv frm=3 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=3 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vv frm=3 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=3 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmacc.vv frm=3 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmacc.vf frm=3 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwnmacc.vf frm=3 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=3 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vf frm=3 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=3 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmacc.vf frm=3 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa539857  # vfwmsac.vv v16, v7, v5
.assert trap == 0 "vfwmsac.vv frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vv frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vv frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa50d957  # vfwmsac.vf v18, f1, v5
.assert trap == 0 "vfwmsac.vf frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vf frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vf frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe539a57  # vfwnmsac.vv v20, v7, v5
.assert trap == 0 "vfwnmsac.vv frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vv frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vv frm=3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe50db57  # vfwnmsac.vf v22, f1, v5
.assert trap == 0 "vfwnmsac.vf frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vf frm=3) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vf frm=3)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmsac.vv frm=3 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmsac.vv frm=3 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=3 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmsac.vv frm=3 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=3 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmsac.vv frm=3 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmsac.vf frm=3 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000000 "vfwmsac.vf frm=3 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=3 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmsac.vf frm=3 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=3 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmsac.vf frm=3 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmsac.vv frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmsac.vv frm=3 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=3 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwnmsac.vv frm=3 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=3 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwnmsac.vv frm=3 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmsac.vf frm=3 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmsac.vf frm=3 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=3 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwnmsac.vf frm=3 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=3 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwnmsac.vf frm=3 lane 2"

# Rounding sweep frm = 4 across all 16 rounding-capable widening encodings.
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=4 readback (sweep_4) writes x10"
.assert rd_wdata == 0x4 "frm=4 readback (sweep_4)"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd.vv frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vv frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc261d957  # vfwadd.vf v18, v6, f3
.assert trap == 0 "vfwadd.vf frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vf frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.vf frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca221a57  # vfwsub.vv v20, v2, v4
.assert trap == 0 "vfwsub.vv frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vv frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vv frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca625b57  # vfwsub.vf v22, v6, f4
.assert trap == 0 "vfwsub.vf frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vf frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.vf frm=4)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.vv frm=4 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=4 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwadd.vv frm=4 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv frm=4 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.vv frm=4 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.vf frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwadd.vf frm=4 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=4 lane 1 writes x10"
.assert rd_wdata == 0xbfefffffffffffff "vfwadd.vf frm=4 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vf frm=4 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vfwadd.vf frm=4 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.vv frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.vv frm=4 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=4 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwsub.vv frm=4 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vv frm=4 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.vv frm=4 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.vf frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwsub.vf frm=4 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=4 lane 1 writes x10"
.assert rd_wdata == 0xbfefffffffffffff "vfwsub.vf frm=4 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.vf frm=4 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vfwsub.vf frm=4 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2839857  # vfwadd.wv v16, v8, v7
.assert trap == 0 "vfwadd.wv frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wv frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd280d957  # vfwadd.wf v18, v8, f1
.assert trap == 0 "vfwadd.wf frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wf frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wf frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda861a57  # vfwsub.wv v20, v8, v12
.assert trap == 0 "vfwsub.wv frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wv frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wv frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xda815b57  # vfwsub.wf v22, v8, f2
.assert trap == 0 "vfwsub.wf frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wf frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwsub.wf frm=4)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wv frm=4 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=4 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwadd.wv frm=4 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv frm=4 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwadd.wv frm=4 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwadd.wf frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwadd.wf frm=4 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=4 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwadd.wf frm=4 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wf frm=4 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwadd.wf frm=4 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwsub.wv frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wv frm=4 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=4 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwsub.wv frm=4 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv frm=4 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwsub.wv frm=4 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwsub.wf frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwsub.wf frm=4 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=4 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwsub.wf frm=4 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wf frm=4 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwsub.wf frm=4 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2539857  # vfwmacc.vv v16, v7, v5
.assert trap == 0 "vfwmacc.vv frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vv frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf250d957  # vfwmacc.vf v18, f1, v5
.assert trap == 0 "vfwmacc.vf frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vf frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmacc.vf frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6539a57  # vfwnmacc.vv v20, v7, v5
.assert trap == 0 "vfwnmacc.vv frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vv frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vv frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf650db57  # vfwnmacc.vf v22, f1, v5
.assert trap == 0 "vfwnmacc.vf frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vf frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmacc.vf frm=4)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vv frm=4 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=4 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwmacc.vv frm=4 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv frm=4 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmacc.vv frm=4 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmacc.vf frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmacc.vf frm=4 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=4 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000003 "vfwmacc.vf frm=4 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vf frm=4 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmacc.vf frm=4 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmacc.vv frm=4 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vv frm=4 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=4 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000003 "vfwnmacc.vv frm=4 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv frm=4 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmacc.vv frm=4 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmacc.vf frm=4 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmacc.vf frm=4 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=4 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000003 "vfwnmacc.vf frm=4 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vf frm=4 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmacc.vf frm=4 lane 2"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x9e80b957  # vmv2r.v v18, v8
.4byte 0x9e80ba57  # vmv2r.v v20, v8
.4byte 0x9e80bb57  # vmv2r.v v22, v8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa539857  # vfwmsac.vv v16, v7, v5
.assert trap == 0 "vfwmsac.vv frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vv frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vv frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa50d957  # vfwmsac.vf v18, f1, v5
.assert trap == 0 "vfwmsac.vf frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vf frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwmsac.vf frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe539a57  # vfwnmsac.vv v20, v7, v5
.assert trap == 0 "vfwnmsac.vv frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vv frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vv frm=4)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe50db57  # vfwnmsac.vf v22, f1, v5
.assert trap == 0 "vfwnmsac.vf frm=4 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vf frm=4) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwnmsac.vf frm=4)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmsac.vv frm=4 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmsac.vv frm=4 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=4 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwmsac.vv frm=4 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv frm=4 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmsac.vv frm=4 lane 2"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vfwmsac.vf frm=4 lane 0 writes x10"
.assert rd_wdata == 0xbff0000000000001 "vfwmsac.vf frm=4 lane 0"
.4byte 0x3f20be57  # vslidedown.vi v28, v18, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=4 lane 1 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwmsac.vf frm=4 lane 1"
.4byte 0x3f213e57  # vslidedown.vi v28, v18, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vf frm=4 lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwmsac.vf frm=4 lane 2"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vfwnmsac.vv frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmsac.vv frm=4 lane 0"
.4byte 0x3f40be57  # vslidedown.vi v28, v20, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=4 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwnmsac.vv frm=4 lane 1"
.4byte 0x3f413e57  # vslidedown.vi v28, v20, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv frm=4 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmsac.vv frm=4 lane 2"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vfwnmsac.vf frm=4 lane 0 writes x10"
.assert rd_wdata == 0x3ff0000000000001 "vfwnmsac.vf frm=4 lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=4 lane 1 writes x10"
.assert rd_wdata == 0x3ff0000000000002 "vfwnmsac.vf frm=4 lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vf frm=4 lane 2 writes x10"
.assert rd_wdata == 0xbff0000000000002 "vfwnmsac.vf frm=4 lane 2"

# vfwmul.vv, vfwmul.vf, subnormal binary32 widening, exact binary64 subnormal FMA, and 4-sign FMA check.
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 readback (exact_and_signs) writes x10"
.assert rd_wdata == 0x0 "frm=0 readback (exact_and_signs)"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x00800337  # lui t1, 0x800
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x3a236ed7  # vslide1up.vx v29, v2, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0xc0000337  # lui t1, 0xc0000
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x3a336ed7  # vslide1up.vx v29, v3, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0xf00300d3  # fmv.w.x f1, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2219857  # vfwmul.vv v16, v2, v3
.assert trap == 0 "vfwmul.vv exact/subnormal retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmul.vv exact/subnormal) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmul.vv exact/subnormal)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmul.vv lane 0 writes x10"
.assert rd_wdata == 0x402e000000000000 "vfwmul.vv lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vv lane 1 writes x10"
.assert rd_wdata == 0x2d50000000000000 "vfwmul.vv lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vv lane 2 writes x10"
.assert rd_wdata == 0xb81fffffc0000000 "vfwmul.vv lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vv lane 3 writes x10"
.assert rd_wdata == 0x8000000000000000 "vfwmul.vv lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe220d857  # vfwmul.vf v16, v2, f1
.assert trap == 0 "vfwmul.vf exact/subnormal retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmul.vf exact/subnormal) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmul.vf exact/subnormal)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmul.vf lane 0 writes x10"
.assert rd_wdata == 0x402e000000000000 "vfwmul.vf lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vf lane 1 writes x10"
.assert rd_wdata == 0x36c4000000000000 "vfwmul.vf lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vf lane 2 writes x10"
.assert rd_wdata == 0x3833ffffd8000000 "vfwmul.vf lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vf lane 3 writes x10"
.assert rd_wdata == 0x8000000000000000 "vfwmul.vf lane 3"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x5e034e57  # vmv.v.x v28, t1
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3bc36457  # vslide1up.vx v8, v28, t1
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2219857  # vfwmacc.vv v16, v3, v2
.assert trap == 0 "vfwmacc.vv sign-check retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv sign-check) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmacc.vv sign-check)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv sign-check lane 0 writes x10"
.assert rd_wdata == 0x4031000000000000 "vfwmacc.vv sign-check lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv sign-check lane 1 writes x10"
.assert rd_wdata == 0x1 "vfwmacc.vv sign-check lane 1"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6219857  # vfwnmacc.vv v16, v3, v2
.assert trap == 0 "vfwnmacc.vv sign-check retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmacc.vv sign-check) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwnmacc.vv sign-check)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwnmacc.vv sign-check lane 0 writes x10"
.assert rd_wdata == 0xc031000000000000 "vfwnmacc.vv sign-check lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmacc.vv sign-check lane 1 writes x10"
.assert rd_wdata == 0x8000000000000001 "vfwnmacc.vv sign-check lane 1"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfa219857  # vfwmsac.vv v16, v3, v2
.assert trap == 0 "vfwmsac.vv sign-check retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmsac.vv sign-check) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmsac.vv sign-check)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmsac.vv sign-check lane 0 writes x10"
.assert rd_wdata == 0x402a000000000000 "vfwmsac.vv sign-check lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmsac.vv sign-check lane 1 writes x10"
.assert rd_wdata == 0x8000000000000001 "vfwmsac.vv sign-check lane 1"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfe219857  # vfwnmsac.vv v16, v3, v2
.assert trap == 0 "vfwnmsac.vv sign-check retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwnmsac.vv sign-check) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwnmsac.vv sign-check)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwnmsac.vv sign-check lane 0 writes x10"
.assert rd_wdata == 0xc02a000000000000 "vfwnmsac.vv sign-check lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwnmsac.vv sign-check lane 1 writes x10"
.assert rd_wdata == 0x1 "vfwnmsac.vv sign-check lane 1"

# Special values: signed-zero cancellation (rne vs rdn), DBL_MAX overflow (OF|NX), NaN/Inf/0*inf (NV), NaN-boxing.
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0xbf800337  # lui t1, 0xbf800
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 readback (szero_0) writes x10"
.assert rd_wdata == 0x0 "frm=0 readback (szero_0)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd.vv szero frm=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv szero frm=0) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.vv szero frm=0)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv szero frm=0 lane 0 writes x10"
.assert rd_wdata == 0x0 "vfwadd.vv szero frm=0 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv szero frm=0 lane 1 writes x10"
.assert rd_wdata == 0x8000000000000000 "vfwadd.vv szero frm=0 lane 1"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=2 readback (szero_2) writes x10"
.assert rd_wdata == 0x2 "frm=2 readback (szero_2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd.vv szero frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv szero frm=2) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.vv szero frm=2)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv szero frm=2 lane 0 writes x10"
.assert rd_wdata == 0x8000000000000000 "vfwadd.vv szero frm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv szero frm=2 lane 1 writes x10"
.assert rd_wdata == 0x8000000000000000 "vfwadd.vv szero frm=2 lane 1"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0xfff00337  # lui t1, 0xfff00
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034e57  # vmv.v.x v28, t1
.4byte 0x7ff00337  # lui t1, 0x7ff00
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3bc36457  # vslide1up.vx v8, v28, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=3 readback (ovf_vfwadd.wv_3) writes x10"
.assert rd_wdata == 0x3 "frm=3 readback (ovf_vfwadd.wv_3)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xd2811857  # vfwadd.wv v16, v8, v2
.assert trap == 0 "vfwadd.wv ovf frm=3 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv ovf frm=3) writes x11"
.assert rd_wdata == 0x5 "fflags (vfwadd.wv ovf frm=3)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv ovf frm=3 lane 0 writes x10"
.assert rd_wdata == 0x7ff0000000000000 "vfwadd.wv ovf frm=3 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv ovf frm=3 lane 1 writes x10"
.assert rd_wdata == 0xffeffffffffffffe "vfwadd.wv ovf frm=3 lane 1"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=1 readback (ovf_vfwadd.wv_1) writes x10"
.assert rd_wdata == 0x1 "frm=1 readback (ovf_vfwadd.wv_1)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xd2811857  # vfwadd.wv v16, v8, v2
.assert trap == 0 "vfwadd.wv ovf frm=1 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv ovf frm=1) writes x11"
.assert rd_wdata == 0x1 "fflags (vfwadd.wv ovf frm=1)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv ovf frm=1 lane 0 writes x10"
.assert rd_wdata == 0x7fefffffffffffff "vfwadd.wv ovf frm=1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv ovf frm=1 lane 1 writes x10"
.assert rd_wdata == 0xffeffffffffffffe "vfwadd.wv ovf frm=1 lane 1"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=2 readback (ovf_vfwsub.wv_2) writes x10"
.assert rd_wdata == 0x2 "frm=2 readback (ovf_vfwsub.wv_2)"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xda811857  # vfwsub.wv v16, v8, v2
.assert trap == 0 "vfwsub.wv ovf frm=2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.wv ovf frm=2) writes x11"
.assert rd_wdata == 0x5 "fflags (vfwsub.wv ovf frm=2)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwsub.wv ovf frm=2 lane 0 writes x10"
.assert rd_wdata == 0x7feffffffffffffe "vfwsub.wv ovf frm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwsub.wv ovf frm=2 lane 1 writes x10"
.assert rd_wdata == 0xfff0000000000000 "vfwsub.wv ovf frm=2 lane 1"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=3 readback (fma_ovf) writes x10"
.assert rd_wdata == 0x3 "frm=3 readback (fma_ovf)"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xf2211857  # vfwmacc.vv v16, v2, v2
.assert trap == 0 "vfwmacc.vv ovf retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv ovf) writes x11"
.assert rd_wdata == 0x5 "fflags (vfwmacc.vv ovf)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv ovf lane 0 writes x10"
.assert rd_wdata == 0x7ff0000000000000 "vfwmacc.vv ovf lane 0"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 readback (post_ovf) writes x10"
.assert rd_wdata == 0x0 "frm=0 readback (post_ovf)"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x7fc00337  # lui t1, 0x7fc00
.4byte 0x3a236ed7  # vslide1up.vx v29, v2, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3a336ed7  # vslide1up.vx v29, v3, t1
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0xfff00337  # lui t1, 0xfff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034e57  # vmv.v.x v28, t1
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3bc36857  # vslide1up.vx v16, v28, t1
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3b036e57  # vslide1up.vx v28, v16, t1
.4byte 0x7ff80337  # lui t1, 0x7ff80
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3bc36857  # vslide1up.vx v16, v28, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2219857  # vfwmacc.vv v16, v3, v2
.assert trap == 0 "vfwmacc 0*inf+qNaN retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc 0*inf+qNaN raises NV) writes x11"
.assert rd_wdata == 0x10 "fflags (vfwmacc 0*inf+qNaN raises NV)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc 0*inf+qNaN lane 0 writes x10"
.assert rd_wdata == 0x7ff8000000000000 "vfwmacc 0*inf+qNaN lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x7fc00337  # lui t1, 0x7fc00
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e0341d7  # vmv.v.x v3, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2219857  # vfwmul.vv v16, v2, v3
.assert trap == 0 "vfwmul qNaN retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmul qNaN leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmul qNaN leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmul qNaN lane 0 writes x10"
.assert rd_wdata == 0x7ff8000000000000 "vfwmul qNaN lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd sNaN retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd sNaN raises NV) writes x11"
.assert rd_wdata == 0x10 "fflags (vfwadd sNaN raises NV)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd sNaN lane 0 writes x10"
.assert rd_wdata == 0x7ff8000000000000 "vfwadd sNaN lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x5e0341d7  # vmv.v.x v3, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2219857  # vfwmul.vv v16, v2, v3
.assert trap == 0 "vfwmul 0*inf retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmul 0*inf raises NV) writes x11"
.assert rd_wdata == 0x10 "fflags (vfwmul 0*inf raises NV)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmul 0*inf lane 0 writes x10"
.assert rd_wdata == 0x7ff8000000000000 "vfwmul 0*inf lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca319857  # vfwsub.vv v16, v3, v3
.assert trap == 0 "vfwsub inf-inf retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub inf-inf raises NV) writes x11"
.assert rd_wdata == 0x10 "fflags (vfwsub inf-inf raises NV)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwsub inf-inf lane 0 writes x10"
.assert rd_wdata == 0x7ff8000000000000 "vfwsub inf-inf lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x7ff00337  # lui t1, 0x7ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2811857  # vfwadd.wv v16, v8, v2
.assert trap == 0 "vfwadd.wv sNaN retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv sNaN raises NV) writes x11"
.assert rd_wdata == 0x10 "fflags (vfwadd.wv sNaN raises NV)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv sNaN lane 0 writes x10"
.assert rd_wdata == 0x7ff8000000000000 "vfwadd.wv sNaN lane 0"
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0xf20302d3  # fmv.d.x f5, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc222d857  # vfwadd.vf v16, v2, f5
.assert trap == 0 "vfwadd.vf unboxed scalar retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vf unboxed scalar leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.vf unboxed scalar leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vf unboxed scalar lane 0 writes x10"
.assert rd_wdata == 0x7ff8000000000000 "vfwadd.vf unboxed scalar lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd282d857  # vfwadd.wf v16, v8, f5
.assert trap == 0 "vfwadd.wf unboxed scalar retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wf unboxed scalar leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.wf unboxed scalar leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wf unboxed scalar lane 0 writes x10"
.assert rd_wdata == 0x7ff8000000000000 "vfwadd.wf unboxed scalar lane 0"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf222d857  # vfwmacc.vf v16, f5, v2
.assert trap == 0 "vfwmacc.vf unboxed scalar retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vf unboxed scalar leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmacc.vf unboxed scalar leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vf unboxed scalar lane 0 writes x10"
.assert rd_wdata == 0x7ff8000000000000 "vfwmacc.vf unboxed scalar lane 0"

# Masking (tu, mu & ta, ma), masked-off sNaN leaving NV clear, vl=0 and VLMAX across all 4 groups.
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x00500313  # addi t1, zero, 5
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0xc0000337  # lui t1, 0xc0000
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3a236ed7  # vslide1up.vx v29, v2, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3a336ed7  # vslide1up.vx v29, v3, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x7ff00337  # lui t1, 0x7ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034e57  # vmv.v.x v28, t1
.4byte 0x40340337  # lui t1, 0x40340
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3bc36457  # vslide1up.vx v8, v28, t1
.4byte 0x7ff00337  # lui t1, 0x7ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3a836e57  # vslide1up.vx v28, v8, t1
.4byte 0x40240337  # lui t1, 0x40240
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3bc36457  # vslide1up.vx v8, v28, t1
.4byte 0x5a5a43b7  # lui t2, 0x5a5a4
.4byte 0xc3c38393  # addi t2, t2, -964
.4byte 0x02039393  # slli t2, t2, 32
.4byte 0xa5a5cfb7  # lui t6, 0xa5a5c
.4byte 0x3c3f8f93  # addi t6, t6, 963
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f3e3b3  # or t2, t2, t6
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vfwadd.vv masked vl=3 writes x12"
.assert rd_wdata == 0x3 "vfwadd.vv masked vl=3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc0219857  # vfwadd.vv v16, v2, v3, v0.t
.assert trap == 0 "vfwadd.vv masked tu mu retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv masked-off/tail sNaN leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.vv masked-off/tail sNaN leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv masked tu mu lane 0 writes x10"
.assert rd_wdata == 0x4020000000000000 "vfwadd.vv masked tu mu lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv masked tu mu lane 1 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwadd.vv masked tu mu lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv masked tu mu lane 2 writes x10"
.assert rd_wdata == 0x3ff0000000000000 "vfwadd.vv masked tu mu lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv masked tu mu lane 3 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwadd.vv masked tu mu lane 3"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vfwadd.wv masked vl=3 writes x12"
.assert rd_wdata == 0x3 "vfwadd.wv masked vl=3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd0819857  # vfwadd.wv v16, v8, v3, v0.t
.assert trap == 0 "vfwadd.wv masked tu mu retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv masked-off/tail sNaN leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.wv masked-off/tail sNaN leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv masked tu mu lane 0 writes x10"
.assert rd_wdata == 0x402e000000000000 "vfwadd.wv masked tu mu lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv masked tu mu lane 1 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwadd.wv masked tu mu lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv masked tu mu lane 2 writes x10"
.assert rd_wdata == 0x4037000000000000 "vfwadd.wv masked tu mu lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv masked tu mu lane 3 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwadd.wv masked tu mu lane 3"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vfwmul.vv masked vl=3 writes x12"
.assert rd_wdata == 0x3 "vfwmul.vv masked vl=3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe0219857  # vfwmul.vv v16, v2, v3, v0.t
.assert trap == 0 "vfwmul.vv masked tu mu retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmul.vv masked-off/tail sNaN leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmul.vv masked-off/tail sNaN leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmul.vv masked tu mu lane 0 writes x10"
.assert rd_wdata == 0x402e000000000000 "vfwmul.vv masked tu mu lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vv masked tu mu lane 1 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwmul.vv masked tu mu lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vv masked tu mu lane 2 writes x10"
.assert rd_wdata == 0xc018000000000000 "vfwmul.vv masked tu mu lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vv masked tu mu lane 3 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwmul.vv masked tu mu lane 3"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x5a5a4337  # lui t1, 0x5a5a4
.4byte 0xc3c30313  # addi t1, t1, -964
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa5a5cfb7  # lui t6, 0xa5a5c
.4byte 0x3c3f8f93  # addi t6, t6, 963
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034e57  # vmv.v.x v28, t1
.4byte 0x40340337  # lui t1, 0x40340
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3bc36857  # vslide1up.vx v16, v28, t1
.4byte 0x5a5a4337  # lui t1, 0x5a5a4
.4byte 0xc3c30313  # addi t1, t1, -964
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa5a5cfb7  # lui t6, 0xa5a5c
.4byte 0x3c3f8f93  # addi t6, t6, 963
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3b036e57  # vslide1up.vx v28, v16, t1
.4byte 0x40240337  # lui t1, 0x40240
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x3bc36857  # vslide1up.vx v16, v28, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vfwmacc.vv masked vl=3 writes x12"
.assert rd_wdata == 0x3 "vfwmacc.vv masked vl=3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf0219857  # vfwmacc.vv v16, v3, v2, v0.t
.assert trap == 0 "vfwmacc.vv masked tu mu retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv masked-off/tail sNaN leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmacc.vv masked-off/tail sNaN leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv masked tu mu lane 0 writes x10"
.assert rd_wdata == 0x4039000000000000 "vfwmacc.vv masked tu mu lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv masked tu mu lane 1 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwmacc.vv masked tu mu lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv masked tu mu lane 2 writes x10"
.assert rd_wdata == 0x402c000000000000 "vfwmacc.vv masked tu mu lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv masked tu mu lane 3 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwmacc.vv masked tu mu lane 3"
.4byte 0xcd017657  # vsetivli a2, 2, e32, m1, ta, ma
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc8219857  # vfwsub.vv v16, v2, v3, v0.t
.assert trap == 0 "vfwsub.vv ta ma masked retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwsub.vv ta ma masked) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwsub.vv ta ma masked)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwsub.vv ta ma lane 0 writes x10"
.assert rd_wdata == 0xc000000000000000 "vfwsub.vv ta ma lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e0341d7  # vmv.v.x v3, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x7ff00337  # lui t1, 0x7ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vfwadd.vv vl=0 writes x12"
.assert rd_wdata == 0x0 "vfwadd.vv vl=0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd.vv vl=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv vl=0 leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.vv vl=0 leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv vl=0 sentinel lane 0 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwadd.vv vl=0 sentinel lane 0"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vfwadd.wv vl=0 writes x12"
.assert rd_wdata == 0x0 "vfwadd.wv vl=0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2819857  # vfwadd.wv v16, v8, v3
.assert trap == 0 "vfwadd.wv vl=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv vl=0 leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.wv vl=0 leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv vl=0 sentinel lane 0 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwadd.wv vl=0 sentinel lane 0"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vfwmul.vv vl=0 writes x12"
.assert rd_wdata == 0x0 "vfwmul.vv vl=0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2219857  # vfwmul.vv v16, v2, v3
.assert trap == 0 "vfwmul.vv vl=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmul.vv vl=0 leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmul.vv vl=0 leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmul.vv vl=0 sentinel lane 0 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwmul.vv vl=0 sentinel lane 0"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vfwmacc.vv vl=0 writes x12"
.assert rd_wdata == 0x0 "vfwmacc.vv vl=0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2219857  # vfwmacc.vv v16, v3, v2
.assert trap == 0 "vfwmacc.vv vl=0 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv vl=0 leaves NV clear) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmacc.vv vl=0 leaves NV clear)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv vl=0 sentinel lane 0 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwmacc.vv vl=0 sentinel lane 0"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x5e034157  # vmv.v.x v2, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x5e0341d7  # vmv.v.x v3, t1
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 0 "vfwadd.vv VLMAX retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv VLMAX) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.vv VLMAX)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv VLMAX lane 0 writes x10"
.assert rd_wdata == 0x4020000000000000 "vfwadd.vv VLMAX lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.vv VLMAX lane 1 writes x10"
.assert rd_wdata == 0x4020000000000000 "vfwadd.vv VLMAX lane 1"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2819857  # vfwadd.wv v16, v8, v3
.assert trap == 0 "vfwadd.wv VLMAX retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.wv VLMAX) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.wv VLMAX)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.wv VLMAX lane 0 writes x10"
.assert rd_wdata == 0x401c000000000000 "vfwadd.wv VLMAX lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwadd.wv VLMAX lane 1 writes x10"
.assert rd_wdata == 0x401c000000000000 "vfwadd.wv VLMAX lane 1"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2219857  # vfwmul.vv v16, v2, v3
.assert trap == 0 "vfwmul.vv VLMAX retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmul.vv VLMAX) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmul.vv VLMAX)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmul.vv VLMAX lane 0 writes x10"
.assert rd_wdata == 0x402e000000000000 "vfwmul.vv VLMAX lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vv VLMAX lane 1 writes x10"
.assert rd_wdata == 0x402e000000000000 "vfwmul.vv VLMAX lane 1"
.4byte 0x9e80b857  # vmv2r.v v16, v8
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2219857  # vfwmacc.vv v16, v3, v2
.assert trap == 0 "vfwmacc.vv VLMAX retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmacc.vv VLMAX) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmacc.vv VLMAX)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmacc.vv VLMAX lane 0 writes x10"
.assert rd_wdata == 0x4031000000000000 "vfwmacc.vv VLMAX lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmacc.vv VLMAX lane 1 writes x10"
.assert rd_wdata == 0x4031000000000000 "vfwmacc.vv VLMAX lane 1"

# LMUL coverage: mf2 (wide m1), m2 (wide m4, vl=5), and m4 (wide m8, vl=9).
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x5e03c8d7  # vmv.v.x v17, t2
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.assert rd_addr == 12 "e32 mf2 vl=2 writes x12"
.assert rd_wdata == 0x2 "e32 mf2 vl=2"
.4byte 0xc0000337  # lui t1, 0xc0000
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x3bd36157  # vslide1up.vx v2, v29, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x3bd361d7  # vslide1up.vx v3, v29, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2219857  # vfwmul.vv v16, v2, v3
.assert trap == 0 "vfwmul.vv mf2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmul.vv mf2) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmul.vv mf2)"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmul.vv mf2 lane 0 writes x10"
.assert rd_wdata == 0x402e000000000000 "vfwmul.vv mf2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vfwmul.vv mf2 lane 1 writes x10"
.assert rd_wdata == 0xc018000000000000 "vfwmul.vv mf2 lane 1"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "vfwmul.vv mf2 neighbor v17 undisturbed writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwmul.vv mf2 neighbor v17 undisturbed"
.4byte 0x01a072d7  # vsetvli t0, zero, e64, m4, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.assert rd_addr == 12 "e32 m2 vl=5 writes x12"
.assert rd_wdata == 0x5 "e32 m2 vl=5"
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x40800337  # lui t1, 0x40800
.4byte 0x3a436c57  # vslide1up.vx v24, v4, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x3b836257  # vslide1up.vx v4, v24, t1
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x3a436c57  # vslide1up.vx v24, v4, t1
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0x3b836257  # vslide1up.vx v4, v24, t1
.4byte 0x42480337  # lui t1, 0x42480
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x42200337  # lui t1, 0x42200
.4byte 0x3a636c57  # vslide1up.vx v24, v6, t1
.4byte 0x41f00337  # lui t1, 0x41f00
.4byte 0x3b836357  # vslide1up.vx v6, v24, t1
.4byte 0x41a00337  # lui t1, 0x41a00
.4byte 0x3a636c57  # vslide1up.vx v24, v6, t1
.4byte 0x41200337  # lui t1, 0x41200
.4byte 0x3b836357  # vslide1up.vx v6, v24, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2431857  # vfwadd.vv v16, v4, v6
.assert trap == 0 "vfwadd.vv m2 vl=5 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwadd.vv m2 vl=5) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwadd.vv m2 vl=5)"
.4byte 0x01a072d7  # vsetvli t0, zero, e64, m4, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwadd.vv m2 vl=5 lane 0 writes x10"
.assert rd_wdata == 0x4026000000000000 "vfwadd.vv m2 vl=5 lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vfwadd.vv m2 vl=5 lane 1 writes x10"
.assert rd_wdata == 0x4036000000000000 "vfwadd.vv m2 vl=5 lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vfwadd.vv m2 vl=5 lane 2 writes x10"
.assert rd_wdata == 0x4040800000000000 "vfwadd.vv m2 vl=5 lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vfwadd.vv m2 vl=5 lane 3 writes x10"
.assert rd_wdata == 0x4046000000000000 "vfwadd.vv m2 vl=5 lane 3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vfwadd.vv m2 vl=5 lane 4 writes x10"
.assert rd_wdata == 0x404b800000000000 "vfwadd.vv m2 vl=5 lane 4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vfwadd.vv m2 vl=5 lane 5 writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwadd.vv m2 vl=5 lane 5"
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc124f657  # vsetivli a2, 9, e32, m4, tu, mu
.assert rd_addr == 12 "e32 m4 vl=9 writes x12"
.assert rd_wdata == 0x9 "e32 m4 vl=9"
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2441857  # vfwmul.vv v16, v4, v8
.assert trap == 0 "vfwmul.vv m4 vl=9 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (vfwmul.vv m4 vl=9) writes x11"
.assert rd_wdata == 0x0 "fflags (vfwmul.vv m4 vl=9)"
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vfwmul.vv m4 lane 0 writes x10"
.assert rd_wdata == 0x402e000000000000 "vfwmul.vv m4 lane 0"
.4byte 0x3f043c57  # vslidedown.vi v24, v16, 8
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vfwmul.vv m4 lane 8 writes x10"
.assert rd_wdata == 0x402e000000000000 "vfwmul.vv m4 lane 8"
.4byte 0x3f04bc57  # vslidedown.vi v24, v16, 9
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vfwmul.vv m4 tail lane 9 undisturbed writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "vfwmul.vv m4 tail lane 9 undisturbed"

# Legal register overlaps: upper-half narrow source (vs2, vs1) and in-place wide vs2.
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x3bd368d7  # vslide1up.vx v17, v29, t1
.4byte 0xc0000337  # lui t1, 0xc0000
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x3bd36457  # vslide1up.vx v8, v29, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc3141857  # vfwadd.vv v16, v17, v8
.assert trap == 0 "legal upper-half vs2 overlap retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (legal upper-half vs2) writes x11"
.assert rd_wdata == 0x0 "fflags (legal upper-half vs2)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "legal upper-half vs2 lane 0 writes x10"
.assert rd_wdata == 0x4020000000000000 "legal upper-half vs2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "legal upper-half vs2 lane 1 writes x10"
.assert rd_wdata == 0x4008000000000000 "legal upper-half vs2 lane 1"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xc0000337  # lui t1, 0xc0000
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x3bd368d7  # vslide1up.vx v17, v29, t1
.4byte 0x40a00337  # lui t1, 0x40a00
.4byte 0x5e034ed7  # vmv.v.x v29, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x3bd36457  # vslide1up.vx v8, v29, t1
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2889857  # vfwmul.vv v16, v8, v17
.assert trap == 0 "legal upper-half vs1 overlap retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (legal upper-half vs1) writes x11"
.assert rd_wdata == 0x0 "fflags (legal upper-half vs1)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "legal upper-half vs1 lane 0 writes x10"
.assert rd_wdata == 0x402e000000000000 "legal upper-half vs1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "legal upper-half vs1 lane 1 writes x10"
.assert rd_wdata == 0xc024000000000000 "legal upper-half vs1 lane 1"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd3041857  # vfwadd.wv v16, v16, v8
.assert trap == 0 "legal in-place wide vd==vs2 retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags (legal in-place wide) writes x11"
.assert rd_wdata == 0x0 "fflags (legal in-place wide)"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "legal in-place wide lane 0 writes x10"
.assert rd_wdata == 0x4032000000000000 "legal in-place wide lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "legal in-place wide lane 1 writes x10"
.assert rd_wdata == 0xc014000000000000 "legal in-place wide lane 1"

# Illegal-instruction traps: SEW 8/16/64, LMUL m8, reserved frm=5, misaligned vd/vs2, masked v0, illegal overlaps, vill=1.
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 1 "sew=64 vfwadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "sew=64 vfwadd.vv mcause writes x10"
.assert rd_wdata == 0x2 "sew=64 vfwadd.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "sew=64 vfwadd.vv mtval writes x10"
.assert rd_wdata == 0xc2219857 "sew=64 vfwadd.vv mtval"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "sew=64 vfwadd.vv leaves v16 intact writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "sew=64 vfwadd.vv leaves v16 intact"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 1 "sew=8 vfwadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "sew=8 vfwadd.vv mcause writes x10"
.assert rd_wdata == 0x2 "sew=8 vfwadd.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "sew=8 vfwadd.vv mtval writes x10"
.assert rd_wdata == 0xc2219857 "sew=8 vfwadd.vv mtval"
.4byte 0xc130f657  # vsetivli a2, 1, e32, m8, tu, mu
.4byte 0xe2041857  # vfwmul.vv v16, v0, v8
.assert trap == 1 "lmul=m8 vfwmul.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "lmul=m8 vfwmul.vv mcause writes x10"
.assert rd_wdata == 0x2 "lmul=m8 vfwmul.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "lmul=m8 vfwmul.vv mtval writes x10"
.assert rd_wdata == 0xe2041857 "lmul=m8 vfwmul.vv mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0022d073  # csrwi frm, 5
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=5 readback (reserved_frm) writes x10"
.assert rd_wdata == 0x5 "frm=5 readback (reserved_frm)"
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 1 "reserved frm=5 vfwadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved frm=5 vfwadd.vv mcause writes x10"
.assert rd_wdata == 0x2 "reserved frm=5 vfwadd.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved frm=5 vfwadd.vv mtval writes x10"
.assert rd_wdata == 0xc2219857 "reserved frm=5 vfwadd.vv mtval"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm=0 readback (restore_frm) writes x10"
.assert rd_wdata == 0x0 "frm=0 readback (restore_frm)"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xc22198d7  # reserved misaligned vd vfwadd.vv v17, v2, v3
.assert trap == 1 "misaligned vd vfwadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "misaligned vd vfwadd.vv mcause writes x10"
.assert rd_wdata == 0x2 "misaligned vd vfwadd.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "misaligned vd vfwadd.vv mtval writes x10"
.assert rd_wdata == 0xc22198d7 "misaligned vd vfwadd.vv mtval"
.4byte 0xd3319857  # reserved misaligned vs2 vfwadd.wv v16, v19, v3
.assert trap == 1 "misaligned vs2 vfwadd.wv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "misaligned vs2 vfwadd.wv mcause writes x10"
.assert rd_wdata == 0x2 "misaligned vs2 vfwadd.wv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "misaligned vs2 vfwadd.wv mtval writes x10"
.assert rd_wdata == 0xd3319857 "misaligned vs2 vfwadd.wv mtval"
.4byte 0xc0219057  # reserved masked vd=v0 vfwadd.vv
.assert trap == 1 "masked vd=v0 vfwadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "masked vd=v0 vfwadd.vv mcause writes x10"
.assert rd_wdata == 0x2 "masked vd=v0 vfwadd.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "masked vd=v0 vfwadd.vv mtval writes x10"
.assert rd_wdata == 0xc0219057 "masked vd=v0 vfwadd.vv mtval"
.4byte 0xc0019857  # reserved masked vs2=v0 vfwadd.vv
.assert trap == 1 "masked vs2=v0 vfwadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "masked vs2=v0 vfwadd.vv mcause writes x10"
.assert rd_wdata == 0x2 "masked vs2=v0 vfwadd.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "masked vs2=v0 vfwadd.vv mtval writes x10"
.assert rd_wdata == 0xc0019857 "masked vs2=v0 vfwadd.vv mtval"
.4byte 0xc3019857  # reserved low-half overlap vfwadd.vv v16, v16, v3
.assert trap == 1 "low-half overlap vfwadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "low-half overlap vfwadd.vv mcause writes x10"
.assert rd_wdata == 0x2 "low-half overlap vfwadd.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "low-half overlap vfwadd.vv mtval writes x10"
.assert rd_wdata == 0xc3019857 "low-half overlap vfwadd.vv mtval"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "low-half overlap vfwadd.vv leaves v16 intact writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "low-half overlap vfwadd.vv leaves v16 intact"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0xc3019857  # reserved mf2 overlap vfwadd.vv v16, v16, v3
.assert trap == 1 "mf2 overlap vfwadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mf2 overlap vfwadd.vv mcause writes x10"
.assert rd_wdata == 0x2 "mf2 overlap vfwadd.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "mf2 overlap vfwadd.vv mtval writes x10"
.assert rd_wdata == 0xc3019857 "mf2 overlap vfwadd.vv mtval"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xd34a9857  # reserved wide-vs2/vs1 overlap vfwadd.wv v16, v20, v21
.assert trap == 1 "wide-vs2/vs1 overlap vfwadd.wv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "wide-vs2/vs1 overlap vfwadd.wv mcause writes x10"
.assert rd_wdata == 0x2 "wide-vs2/vs1 overlap vfwadd.wv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "wide-vs2/vs1 overlap vfwadd.wv mtval writes x10"
.assert rd_wdata == 0xd34a9857 "wide-vs2/vs1 overlap vfwadd.wv mtval"
.4byte 0xf3119857  # reserved fwfma vd/vs2 overlap vfwmacc.vv v16, v3, v17
.assert trap == 1 "fwfma vd/vs2 overlap vfwmacc.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "fwfma vd/vs2 overlap vfwmacc.vv mcause writes x10"
.assert rd_wdata == 0x2 "fwfma vd/vs2 overlap vfwmacc.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "fwfma vd/vs2 overlap vfwmacc.vv mtval writes x10"
.assert rd_wdata == 0xf3119857 "fwfma vd/vs2 overlap vfwmacc.vv mtval"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "fwfma vd/vs2 overlap vfwmacc.vv leaves v16 intact writes x10"
.assert rd_wdata == 0x5a5a3c3ca5a5c3c3 "fwfma vd/vs2 overlap vfwmacc.vv leaves v16 intact"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xf6389857  # reserved fwfma vd/vs1 overlap vfwnmacc.vv v16, v17, v3
.assert trap == 1 "fwfma vd/vs1 overlap vfwnmacc.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "fwfma vd/vs1 overlap vfwnmacc.vv mcause writes x10"
.assert rd_wdata == 0x2 "fwfma vd/vs1 overlap vfwnmacc.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "fwfma vd/vs1 overlap vfwnmacc.vv mtval writes x10"
.assert rd_wdata == 0xf6389857 "fwfma vd/vs1 overlap vfwnmacc.vv mtval"
.4byte 0xc1f0f657  # vsetivli a2, 1, e64, mf2, tu, mu
.assert rd_addr == 12 "vill=1 config writes x12"
.assert rd_wdata == 0x0 "vill=1 config"
.4byte 0xc2219857  # vfwadd.vv v16, v2, v3
.assert trap == 1 "vill=1 vfwadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vill=1 vfwadd.vv mcause writes x10"
.assert rd_wdata == 0x2 "vill=1 vfwadd.vv mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vill=1 vfwadd.vv mtval writes x10"
.assert rd_wdata == 0xc2219857 "vill=1 vfwadd.vv mtval"
