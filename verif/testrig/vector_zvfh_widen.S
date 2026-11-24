# Vector Zvfh widening FP16->FP32 arithmetic and FMA (all 18 modes at SEW=16).
# Covers all 5 frm modes with readbacks, subnormal widening, unboxed scalars, masks, tails, overlaps, traps.
.noshrink
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0x60028293  # addi x5, x5, 1536
.4byte 0x3002a073  # csrs mstatus, x5
.4byte 0x00305073  # csrwi fcsr, 0
.4byte 0x01b07fd7  # vsetvli x31, x0, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0

# Section 1: Control vfwadd.vv at e16 mf2 -> e32 m1 into v7 (unique 0x42702557).
.4byte 0xc0f17657  # vsetivli x12, 2, e16, mf2, tu, mu
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc28613d7  # vfwadd.vv v7, v8, v12
.assert trap == 0 "control vfwadd.vv e16 mf2 retires"
.4byte 0xc1017657  # vsetivli x12, 2, e32, m1, tu, mu
.4byte 0x42702557  # vmv.x.s x10, v7
.assert rd_addr == 10 "control vfwadd.vv 1.0h+1.5h=2.5f writes x10"
.assert rd_wdata == 0x40200000 "control vfwadd.vv 1.0h+1.5h=2.5f"
.4byte 0x3e70bc57  # vslidedown.vi v24, v7, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vfwadd.vv 2^-24h+1.0h (inexact f32) writes x10"
.assert rd_wdata == 0x3f800000 "control vfwadd.vv 2^-24h+1.0h (inexact f32)"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "control vfwadd.vv fflags writes x11"
.assert rd_wdata == 0x1 "control vfwadd.vv fflags"

# Section 2: All 16 rounding widening FP16->FP32 modes across all 5 frm modes (5/5 distinct each) + exact vfwmul.
.4byte 0x00300293  # addi x5, x0, 3
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0xf4028153  # fmv.h.x f2, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x60028293  # addi x5, x5, 1536
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x60028293  # addi x5, x5, 1536
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00328293  # addi x5, x5, 3
.4byte 0x5e02c4d7  # vmv.v.x v9, x5
.4byte 0x00300293  # addi x5, x0, 3
.4byte 0x3a92ee57  # vslide1up.vx v28, v9, x5
.4byte 0x5e0e04d7  # vmv.v.v v9, v28
.4byte 0x00300293  # addi x5, x0, 3
.4byte 0x3a92ee57  # vslide1up.vx v28, v9, x5
.4byte 0x5e0e04d7  # vmv.v.v v9, v28
.4byte 0x00300293  # addi x5, x0, 3
.4byte 0x3a92ee57  # vslide1up.vx v28, v9, x5
.4byte 0x5e0e04d7  # vmv.v.v v9, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x5e02c557  # vmv.v.x v10, x5
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, x5
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, x5
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, x5
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0xbf8002b7  # lui x5, 0xbf800
.4byte 0x00228293  # addi x5, x5, 2
.4byte 0x5e02c757  # vmv.v.x v14, x5
.4byte 0x3f8002b7  # lui x5, 0x3f800
.4byte 0x00228293  # addi x5, x5, 2
.4byte 0x3ae2ee57  # vslide1up.vx v28, v14, x5
.4byte 0x5e0e0757  # vmv.v.v v14, v28
.4byte 0xbf8002b7  # lui x5, 0xbf800
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3ae2ee57  # vslide1up.vx v28, v14, x5
.4byte 0x5e0e0757  # vmv.v.v v14, v28
.4byte 0x3f8002b7  # lui x5, 0x3f800
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3ae2ee57  # vslide1up.vx v28, v14, x5
.4byte 0x5e0e0757  # vmv.v.v v14, v28
.4byte 0x5e070957  # vmv.v.v v18, v14
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2849857  # vfwadd.vv v16, v8, v9
.assert trap == 0 "vfwadd.vv RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vv RNE l0 writes x10"
.assert rd_wdata == 0x3fc00002 "vfwadd.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbfbffffe "vfwadd.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RNE l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwadd.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwadd.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vv RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc280d857  # vfwadd.vf v16, v8, f1
.assert trap == 0 "vfwadd.vf RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vf RNE l0 writes x10"
.assert rd_wdata == 0x3fc00002 "vfwadd.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbfbffffe "vfwadd.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RNE l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwadd.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwadd.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vf RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca849857  # vfwsub.vv v16, v8, v9
.assert trap == 0 "vfwsub.vv RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vv RNE l0 writes x10"
.assert rd_wdata == 0x3fbffffe "vfwsub.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00002 "vfwsub.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RNE l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwsub.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwsub.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vv RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca80d857  # vfwsub.vf v16, v8, f1
.assert trap == 0 "vfwsub.vf RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vf RNE l0 writes x10"
.assert rd_wdata == 0x3fbffffe "vfwsub.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00002 "vfwsub.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RNE l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwsub.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwsub.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vf RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e51857  # vfwadd.wv v16, v14, v10
.assert trap == 0 "vfwadd.wv RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wv RNE l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwadd.wv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RNE l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwadd.wv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wv RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e15857  # vfwadd.wf v16, v14, f2
.assert trap == 0 "vfwadd.wf RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wf RNE l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwadd.wf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RNE l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwadd.wf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wf RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae51857  # vfwsub.wv v16, v14, v10
.assert trap == 0 "vfwsub.wv RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wv RNE l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwsub.wv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwsub.wv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RNE l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwsub.wv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwsub.wv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wv RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae15857  # vfwsub.wf v16, v14, f2
.assert trap == 0 "vfwsub.wf RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wf RNE l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwsub.wf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwsub.wf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RNE l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwsub.wf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwsub.wf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wf RNE fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c51857  # vfwmacc.vv v16, v10, v12
.assert trap == 0 "vfwmacc.vv RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vv RNE l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwmacc.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RNE l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmacc.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vv RNE fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c15857  # vfwmacc.vf v16, f2, v12
.assert trap == 0 "vfwmacc.vf RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vf RNE l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmacc.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RNE l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmacc.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vf RNE fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c51857  # vfwnmacc.vv v16, v10, v12
.assert trap == 0 "vfwnmacc.vv RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vv RNE l0 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RNE l1 writes x10"
.assert rd_wdata == 0x3f800000 "vfwnmacc.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RNE l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RNE l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmacc.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vv RNE fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c15857  # vfwnmacc.vf v16, f2, v12
.assert trap == 0 "vfwnmacc.vf RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vf RNE l0 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RNE l1 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmacc.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RNE l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RNE l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmacc.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vf RNE fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac51857  # vfwmsac.vv v16, v10, v12
.assert trap == 0 "vfwmsac.vv RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vv RNE l0 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwmsac.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RNE l1 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmsac.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RNE l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmsac.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RNE l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmsac.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vv RNE fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac15857  # vfwmsac.vf v16, f2, v12
.assert trap == 0 "vfwmsac.vf RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vf RNE l0 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwmsac.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RNE l1 writes x10"
.assert rd_wdata == 0x3f800000 "vfwmsac.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RNE l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmsac.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RNE l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmsac.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vf RNE fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec51857  # vfwnmsac.vv v16, v10, v12
.assert trap == 0 "vfwnmsac.vv RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vv RNE l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwnmsac.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmsac.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RNE l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmsac.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmsac.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vv RNE fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec15857  # vfwnmsac.vf v16, f2, v12
.assert trap == 0 "vfwnmsac.vf RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vf RNE l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwnmsac.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwnmsac.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RNE l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmsac.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmsac.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vf RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2849857  # vfwadd.vv v16, v8, v9
.assert trap == 0 "vfwadd.vv RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3fc00001 "vfwadd.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbfbffffe "vfwadd.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RTZ l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwadd.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwadd.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vv RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc280d857  # vfwadd.vf v16, v8, f1
.assert trap == 0 "vfwadd.vf RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3fc00001 "vfwadd.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbfbffffe "vfwadd.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RTZ l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwadd.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffc0bfffff "vfwadd.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vf RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca849857  # vfwsub.vv v16, v8, v9
.assert trap == 0 "vfwsub.vv RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3fbffffe "vfwsub.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00001 "vfwsub.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RTZ l2 writes x10"
.assert rd_wdata == 0x40bfffff "vfwsub.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffc0bfffff "vfwsub.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vv RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca80d857  # vfwsub.vf v16, v8, f1
.assert trap == 0 "vfwsub.vf RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3fbffffe "vfwsub.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00001 "vfwsub.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RTZ l2 writes x10"
.assert rd_wdata == 0x40bfffff "vfwsub.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwsub.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vf RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e51857  # vfwadd.wv v16, v14, v10
.assert trap == 0 "vfwadd.wv RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wv RTZ l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwadd.wv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwadd.wv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RTZ l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwadd.wv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wv RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e15857  # vfwadd.wf v16, v14, f2
.assert trap == 0 "vfwadd.wf RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wf RTZ l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwadd.wf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwadd.wf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RTZ l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwadd.wf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wf RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae51857  # vfwsub.wv v16, v14, v10
.assert trap == 0 "vfwsub.wv RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wv RTZ l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwsub.wv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwsub.wv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RTZ l2 writes x10"
.assert rd_wdata == 0x3f800001 "vfwsub.wv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwsub.wv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wv RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae15857  # vfwsub.wf v16, v14, f2
.assert trap == 0 "vfwsub.wf RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wf RTZ l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwsub.wf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwsub.wf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RTZ l2 writes x10"
.assert rd_wdata == 0x3f800001 "vfwsub.wf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwsub.wf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wf RTZ fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c51857  # vfwmacc.vv v16, v10, v12
.assert trap == 0 "vfwmacc.vv RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmacc.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwmacc.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RTZ l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmacc.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vv RTZ fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c15857  # vfwmacc.vf v16, f2, v12
.assert trap == 0 "vfwmacc.vf RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmacc.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmacc.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RTZ l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmacc.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vf RTZ fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c51857  # vfwnmacc.vv v16, v10, v12
.assert trap == 0 "vfwnmacc.vv RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vv RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmacc.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RTZ l1 writes x10"
.assert rd_wdata == 0x3f800000 "vfwnmacc.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RTZ l3 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmacc.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vv RTZ fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c15857  # vfwnmacc.vf v16, f2, v12
.assert trap == 0 "vfwnmacc.vf RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vf RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmacc.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RTZ l1 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmacc.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RTZ l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmacc.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vf RTZ fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac51857  # vfwmsac.vv v16, v10, v12
.assert trap == 0 "vfwmsac.vv RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vv RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwmsac.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RTZ l1 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmsac.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmsac.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RTZ l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmsac.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vv RTZ fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac15857  # vfwmsac.vf v16, f2, v12
.assert trap == 0 "vfwmsac.vf RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vf RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwmsac.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RTZ l1 writes x10"
.assert rd_wdata == 0x3f800000 "vfwmsac.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmsac.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RTZ l3 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmsac.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vf RTZ fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec51857  # vfwnmsac.vv v16, v10, v12
.assert trap == 0 "vfwnmsac.vv RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwnmsac.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmsac.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RTZ l2 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmsac.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmsac.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vv RTZ fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec15857  # vfwnmsac.vf v16, f2, v12
.assert trap == 0 "vfwnmsac.vf RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwnmsac.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwnmsac.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RTZ l2 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmsac.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmsac.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vf RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2849857  # vfwadd.vv v16, v8, v9
.assert trap == 0 "vfwadd.vv RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vv RDN l0 writes x10"
.assert rd_wdata == 0x3fc00001 "vfwadd.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbfbfffff "vfwadd.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RDN l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwadd.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00001 "vfwadd.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vv RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc280d857  # vfwadd.vf v16, v8, f1
.assert trap == 0 "vfwadd.vf RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vf RDN l0 writes x10"
.assert rd_wdata == 0x3fc00001 "vfwadd.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbfbfffff "vfwadd.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RDN l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwadd.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwadd.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vf RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca849857  # vfwsub.vv v16, v8, v9
.assert trap == 0 "vfwsub.vv RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vv RDN l0 writes x10"
.assert rd_wdata == 0x3fbffffe "vfwsub.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00002 "vfwsub.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RDN l2 writes x10"
.assert rd_wdata == 0x40bfffff "vfwsub.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwsub.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vv RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca80d857  # vfwsub.vf v16, v8, f1
.assert trap == 0 "vfwsub.vf RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vf RDN l0 writes x10"
.assert rd_wdata == 0x3fbffffe "vfwsub.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00002 "vfwsub.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RDN l2 writes x10"
.assert rd_wdata == 0x40bfffff "vfwsub.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00001 "vfwsub.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vf RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e51857  # vfwadd.wv v16, v14, v10
.assert trap == 0 "vfwadd.wv RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wv RDN l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwadd.wv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwadd.wv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RDN l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwadd.wv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wv RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e15857  # vfwadd.wf v16, v14, f2
.assert trap == 0 "vfwadd.wf RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wf RDN l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwadd.wf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwadd.wf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RDN l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwadd.wf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wf RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae51857  # vfwsub.wv v16, v14, v10
.assert trap == 0 "vfwsub.wv RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wv RDN l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwsub.wv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwsub.wv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RDN l2 writes x10"
.assert rd_wdata == 0x3f800001 "vfwsub.wv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwsub.wv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wv RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae15857  # vfwsub.wf v16, v14, f2
.assert trap == 0 "vfwsub.wf RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wf RDN l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwsub.wf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwsub.wf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RDN l2 writes x10"
.assert rd_wdata == 0x3f800001 "vfwsub.wf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwsub.wf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wf RDN fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c51857  # vfwmacc.vv v16, v10, v12
.assert trap == 0 "vfwmacc.vv RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vv RDN l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmacc.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmacc.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RDN l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmacc.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vv RDN fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c15857  # vfwmacc.vf v16, f2, v12
.assert trap == 0 "vfwmacc.vf RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vf RDN l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmacc.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmacc.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RDN l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwmacc.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vf RDN fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c51857  # vfwnmacc.vv v16, v10, v12
.assert trap == 0 "vfwnmacc.vv RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vv RDN l0 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RDN l1 writes x10"
.assert rd_wdata == 0x3f800000 "vfwnmacc.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RDN l2 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwnmacc.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RDN l3 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmacc.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vv RDN fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c15857  # vfwnmacc.vf v16, f2, v12
.assert trap == 0 "vfwnmacc.vf RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vf RDN l0 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RDN l1 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmacc.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RDN l2 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwnmacc.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RDN l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmacc.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vf RDN fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac51857  # vfwmsac.vv v16, v10, v12
.assert trap == 0 "vfwmsac.vv RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vv RDN l0 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmsac.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RDN l1 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmsac.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RDN l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmsac.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RDN l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmsac.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vv RDN fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac15857  # vfwmsac.vf v16, f2, v12
.assert trap == 0 "vfwmsac.vf RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vf RDN l0 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmsac.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RDN l1 writes x10"
.assert rd_wdata == 0x3f800000 "vfwmsac.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RDN l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmsac.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RDN l3 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmsac.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vf RDN fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec51857  # vfwnmsac.vv v16, v10, v12
.assert trap == 0 "vfwnmsac.vv RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vv RDN l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwnmsac.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmsac.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RDN l2 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmsac.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwnmsac.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vv RDN fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec15857  # vfwnmsac.vf v16, f2, v12
.assert trap == 0 "vfwnmsac.vf RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vf RDN l0 writes x10"
.assert rd_wdata == 0x3f800000 "vfwnmsac.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmsac.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RDN l2 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmsac.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmsac.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vf RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2849857  # vfwadd.vv v16, v8, v9
.assert trap == 0 "vfwadd.vv RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vv RUP l0 writes x10"
.assert rd_wdata == 0x3fc00002 "vfwadd.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbfbffffe "vfwadd.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RUP l2 writes x10"
.assert rd_wdata == 0x40c00001 "vfwadd.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwadd.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vv RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc280d857  # vfwadd.vf v16, v8, f1
.assert trap == 0 "vfwadd.vf RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vf RUP l0 writes x10"
.assert rd_wdata == 0x3fc00002 "vfwadd.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbfbffffe "vfwadd.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RUP l2 writes x10"
.assert rd_wdata == 0x40c00001 "vfwadd.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffc0bfffff "vfwadd.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vf RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca849857  # vfwsub.vv v16, v8, v9
.assert trap == 0 "vfwsub.vv RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vv RUP l0 writes x10"
.assert rd_wdata == 0x3fbfffff "vfwsub.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00001 "vfwsub.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RUP l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwsub.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffc0bfffff "vfwsub.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vv RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca80d857  # vfwsub.vf v16, v8, f1
.assert trap == 0 "vfwsub.vf RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vf RUP l0 writes x10"
.assert rd_wdata == 0x3fbfffff "vfwsub.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00001 "vfwsub.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RUP l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwsub.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwsub.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vf RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e51857  # vfwadd.wv v16, v14, v10
.assert trap == 0 "vfwadd.wv RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wv RUP l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwadd.wv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RUP l2 writes x10"
.assert rd_wdata == 0x3f800003 "vfwadd.wv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwadd.wv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wv RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e15857  # vfwadd.wf v16, v14, f2
.assert trap == 0 "vfwadd.wf RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wf RUP l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwadd.wf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RUP l2 writes x10"
.assert rd_wdata == 0x3f800003 "vfwadd.wf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwadd.wf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wf RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae51857  # vfwsub.wv v16, v14, v10
.assert trap == 0 "vfwsub.wv RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wv RUP l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwsub.wv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwsub.wv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RUP l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwsub.wv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwsub.wv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wv RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae15857  # vfwsub.wf v16, v14, f2
.assert trap == 0 "vfwsub.wf RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wf RUP l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwsub.wf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwsub.wf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RUP l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwsub.wf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwsub.wf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wf RUP fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c51857  # vfwmacc.vv v16, v10, v12
.assert trap == 0 "vfwmacc.vv RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vv RUP l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwmacc.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RUP l2 writes x10"
.assert rd_wdata == 0x3f800003 "vfwmacc.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmacc.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vv RUP fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c15857  # vfwmacc.vf v16, f2, v12
.assert trap == 0 "vfwmacc.vf RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vf RUP l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmacc.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RUP l2 writes x10"
.assert rd_wdata == 0x3f800003 "vfwmacc.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmacc.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vf RUP fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c51857  # vfwnmacc.vv v16, v10, v12
.assert trap == 0 "vfwnmacc.vv RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vv RUP l0 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmacc.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RUP l1 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmacc.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RUP l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RUP l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmacc.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vv RUP fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c15857  # vfwnmacc.vf v16, f2, v12
.assert trap == 0 "vfwnmacc.vf RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vf RUP l0 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmacc.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RUP l1 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmacc.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RUP l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RUP l3 writes x10"
.assert rd_wdata == 0x3f800003 "vfwnmacc.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vf RUP fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac51857  # vfwmsac.vv v16, v10, v12
.assert trap == 0 "vfwmsac.vv RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vv RUP l0 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwmsac.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RUP l1 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmsac.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RUP l2 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmsac.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RUP l3 writes x10"
.assert rd_wdata == 0x3f800003 "vfwmsac.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vv RUP fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac15857  # vfwmsac.vf v16, f2, v12
.assert trap == 0 "vfwmsac.vf RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vf RUP l0 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwmsac.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RUP l1 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmsac.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RUP l2 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmsac.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RUP l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmsac.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vf RUP fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec51857  # vfwnmsac.vv v16, v10, v12
.assert trap == 0 "vfwnmsac.vv RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vv RUP l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmsac.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmsac.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RUP l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmsac.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmsac.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vv RUP fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec15857  # vfwnmsac.vf v16, f2, v12
.assert trap == 0 "vfwnmsac.vf RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vf RUP l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmsac.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfwnmsac.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RUP l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmsac.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmsac.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vf RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2849857  # vfwadd.vv v16, v8, v9
.assert trap == 0 "vfwadd.vv RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vv RMM l0 writes x10"
.assert rd_wdata == 0x3fc00002 "vfwadd.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbfbfffff "vfwadd.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RMM l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwadd.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwadd.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vv RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc280d857  # vfwadd.vf v16, v8, f1
.assert trap == 0 "vfwadd.vf RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vf RMM l0 writes x10"
.assert rd_wdata == 0x3fc00002 "vfwadd.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbfbfffff "vfwadd.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RMM l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwadd.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwadd.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.vf RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca849857  # vfwsub.vv v16, v8, v9
.assert trap == 0 "vfwsub.vv RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vv RMM l0 writes x10"
.assert rd_wdata == 0x3fbfffff "vfwsub.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00002 "vfwsub.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RMM l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwsub.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwsub.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vv RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xca80d857  # vfwsub.vf v16, v8, f1
.assert trap == 0 "vfwsub.vf RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.vf RMM l0 writes x10"
.assert rd_wdata == 0x3fbfffff "vfwsub.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbfc00002 "vfwsub.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RMM l2 writes x10"
.assert rd_wdata == 0x40c00000 "vfwsub.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffc0c00000 "vfwsub.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.vf RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e51857  # vfwadd.wv v16, v14, v10
.assert trap == 0 "vfwadd.wv RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wv RMM l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwadd.wv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RMM l2 writes x10"
.assert rd_wdata == 0x3f800003 "vfwadd.wv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwadd.wv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wv RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xd2e15857  # vfwadd.wf v16, v14, f2
.assert trap == 0 "vfwadd.wf RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.wf RMM l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwadd.wf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwadd.wf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RMM l2 writes x10"
.assert rd_wdata == 0x3f800003 "vfwadd.wf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwadd.wf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwadd.wf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.wf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwadd.wf RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae51857  # vfwsub.wv v16, v14, v10
.assert trap == 0 "vfwsub.wv RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wv RMM l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwsub.wv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwsub.wv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RMM l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwsub.wv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwsub.wv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wv RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xdae15857  # vfwsub.wf v16, v14, f2
.assert trap == 0 "vfwsub.wf RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwsub.wf RMM l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwsub.wf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwsub.wf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RMM l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwsub.wf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwsub.wf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwsub.wf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwsub.wf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwsub.wf RMM fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c51857  # vfwmacc.vv v16, v10, v12
.assert trap == 0 "vfwmacc.vv RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vv RMM l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmacc.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RMM l2 writes x10"
.assert rd_wdata == 0x3f800003 "vfwmacc.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmacc.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vv RMM fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf2c15857  # vfwmacc.vf v16, f2, v12
.assert trap == 0 "vfwmacc.vf RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmacc.vf RMM l0 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmacc.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmacc.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RMM l2 writes x10"
.assert rd_wdata == 0x3f800003 "vfwmacc.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmacc.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwmacc.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmacc.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwmacc.vf RMM fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c51857  # vfwnmacc.vv v16, v10, v12
.assert trap == 0 "vfwnmacc.vv RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vv RMM l0 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RMM l1 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmacc.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RMM l2 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwnmacc.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vv RMM l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmacc.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vv RMM fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xf6c15857  # vfwnmacc.vf v16, f2, v12
.assert trap == 0 "vfwnmacc.vf RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmacc.vf RMM l0 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmacc.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RMM l1 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmacc.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RMM l2 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwnmacc.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmacc.vf RMM l3 writes x10"
.assert rd_wdata == 0x3f800003 "vfwnmacc.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmacc.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmacc.vf RMM fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac51857  # vfwmsac.vv v16, v10, v12
.assert trap == 0 "vfwmsac.vv RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vv RMM l0 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmsac.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RMM l1 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmsac.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RMM l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmsac.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vv RMM l3 writes x10"
.assert rd_wdata == 0x3f800003 "vfwmsac.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vv RMM fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfac15857  # vfwmsac.vf v16, f2, v12
.assert trap == 0 "vfwmsac.vf RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmsac.vf RMM l0 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwmsac.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RMM l1 writes x10"
.assert rd_wdata == 0x3f800001 "vfwmsac.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RMM l2 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwmsac.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmsac.vf RMM l3 writes x10"
.assert rd_wdata == 0x3f800002 "vfwmsac.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmsac.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwmsac.vf RMM fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec51857  # vfwnmsac.vv v16, v10, v12
.assert trap == 0 "vfwnmsac.vv RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vv RMM l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmsac.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmsac.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RMM l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmsac.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffbf800003 "vfwnmsac.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vv RMM fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x5e090857  # vmv.v.v v16, v18
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xfec15857  # vfwnmsac.vf v16, f2, v12
.assert trap == 0 "vfwnmsac.vf RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwnmsac.vf RMM l0 writes x10"
.assert rd_wdata == 0x3f800001 "vfwnmsac.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffbf800001 "vfwnmsac.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RMM l2 writes x10"
.assert rd_wdata == 0x3f800002 "vfwnmsac.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwnmsac.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffbf800002 "vfwnmsac.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwnmsac.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwnmsac.vf RMM fflags"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
# Exact vfwmul.vv and vfwmul.vf (subnormal and max finite FP16 -> exact FP32, fflags==0).
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xbff28293  # addi x5, x5, -1025
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x08028293  # addi x5, x5, 128
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2861857  # vfwmul.vv v16, v8, v12
.assert trap == 0 "vfwmul.vv retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmul.vv l0 writes x10"
.assert rd_wdata == 0x40900000 "vfwmul.vv l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmul.vv l1 writes x10"
.assert rd_wdata == 0xffffffffc0102400 "vfwmul.vv l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmul.vv l2 writes x10"
.assert rd_wdata == 0x33800000 "vfwmul.vv l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmul.vv l3 writes x10"
.assert rd_wdata == 0x47800ffc "vfwmul.vv l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmul.vv exact fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfwmul.vv exact fflags==0"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe280d857  # vfwmul.vf v16, v8, f1
.assert trap == 0 "vfwmul.vf retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwmul.vf l0 writes x10"
.assert rd_wdata == 0x40700000 "vfwmul.vf l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmul.vf l1 writes x10"
.assert rd_wdata == 0xffffffffc0b40000 "vfwmul.vf l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmul.vf l2 writes x10"
.assert rd_wdata == 0x34200000 "vfwmul.vf l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwmul.vf l3 writes x10"
.assert rd_wdata == 0x481fec00 "vfwmul.vf l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmul.vf exact fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfwmul.vf exact fflags==0"
# Unboxed .vf scalar -> 0x7fc00000, masked tu/mu sNaN suppression, vl=0, VLMAX, overlaps, traps.
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0xf2028153  # fmv.d.x f2, x5
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc2815857  # vfwadd.vf v16, v8, f2
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwadd.vf unboxed scalar -> 0x7fc00000 writes x10"
.assert rd_wdata == 0x7fc00000 "vfwadd.vf unboxed scalar -> 0x7fc00000"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwadd.vf unboxed qNaN fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfwadd.vf unboxed qNaN fflags==0"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x00500293  # addi x5, x0, 5
.4byte 0x5e02c057  # vmv.v.x v0, x5
.4byte 0x01107fd7  # vsetvli x31, x0, e32, m2, tu, mu
.4byte 0x5a5a62b7  # lui x5, 0x5a5a6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe0861857  # vfwmul.vv v16, v8, v12, v0.t
.4byte 0xc112f657  # vsetivli x12, 5, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "masked vfwmul.vv active l0 writes x10"
.assert rd_wdata == 0x3fc00000 "masked vfwmul.vv active l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vfwmul.vv mu l1 writes x10"
.assert rd_wdata == 0x5a5a5a5a "masked vfwmul.vv mu l1"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vfwmul.vv tu tail l4 writes x10"
.assert rd_wdata == 0x5a5a5a5a "masked vfwmul.vv tu tail l4"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "masked vfwmul.vv suppresses inactive sNaN NV writes x11"
.assert rd_wdata == 0x0 "masked vfwmul.vv suppresses inactive sNaN NV"
.4byte 0xcc807657  # vsetivli x12, 0, e16, m1, ta, ma
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xe2861857  # vfwmul.vv v16, v8, v12
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwmul.vv vl=0 fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfwmul.vv vl=0 fflags==0"
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x5e02c8d7  # vmv.v.x v17, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3b12ee57  # vslide1up.vx v28, v17, x5
.4byte 0x5e0e08d7  # vmv.v.v v17, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc3161857  # vfwadd.vv v16, v17, v12
.assert trap == 0 "legal upper-half overlap vfwadd.vv v16, v17, v12 retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "upper-half overlap vfwadd.vv l0=2.0f writes x10"
.assert rd_wdata == 0x40000000 "upper-half overlap vfwadd.vv l0=2.0f"
.4byte 0x00e07fd7  # vsetvli x31, x0, e16, mf4, tu, mu
.4byte 0xc2861857  # vfwadd.vv v16, v8, v12
.assert trap == 0 "vfwadd.vv VLMAX e16 mf4 retires"
.4byte 0x00f07fd7  # vsetvli x31, x0, e16, mf2, tu, mu
.4byte 0xc2861857  # vfwadd.vv v16, v8, v12
.assert trap == 0 "vfwadd.vv VLMAX e16 mf2 retires"
.4byte 0x00807fd7  # vsetvli x31, x0, e16, m1, tu, mu
.4byte 0xc2861857  # vfwadd.vv v16, v8, v12
.assert trap == 0 "vfwadd.vv VLMAX e16 m1 retires"
.4byte 0x00907fd7  # vsetvli x31, x0, e16, m2, tu, mu
.4byte 0xc2861857  # vfwadd.vv v16, v8, v12
.assert trap == 0 "vfwadd.vv VLMAX e16 m2 retires"
.4byte 0x00a07fd7  # vsetvli x31, x0, e16, m4, tu, mu
.4byte 0xc2861857  # vfwadd.vv v16, v8, v12
.assert trap == 0 "vfwadd.vv VLMAX e16 m4 retires"
.4byte 0xc0b27657  # vsetivli x12, 4, e16, m8, tu, mu
.4byte 0xc28c1857  # vfwadd.vv v16, v8, v24
.assert trap == 1 "vfwadd.vv at m8 traps"
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0xc2861857  # vfwadd.vv v16, v8, v12
.assert trap == 1 "vfwadd.vv at e8 traps"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xc28618d7  # vfwadd.vv v17, v8, v12
.assert trap == 1 "vfwadd.vv odd vd at m1->m2 traps"
.4byte 0xc3061857  # vfwadd.vv v16, v16, v12
.assert trap == 1 "vfwadd.vv lower-half overlap vd==vs2 traps"
.4byte 0xf3161857  # vfwmacc.vv v16, v12, v17
.assert trap == 1 "vfwmacc.vv narrow-src overlap with wide vd traps"
.4byte 0xd2e71857  # vfwadd.wv v16, v14, v14
.assert trap == 1 "vfwadd.wv wide vs2 overlaps narrow vs1 traps"
.4byte 0xc0861057  # vfwadd.vv v0, v8, v12, v0.t
.assert trap == 1 "masked vfwadd.vv vd==v0 traps"
.4byte 0x0022d073  # csrwi frm, 5
.4byte 0xc2861857  # vfwadd.vv v16, v8, v12
.assert trap == 1 "vfwadd.vv reserved frm=5 traps"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0xc2027657  # vsetivli reserved_sew4 (sets vill)
.4byte 0xc2861857  # vfwadd.vv v16, v8, v12
.assert trap == 1 "vfwadd.vv under vill traps"
