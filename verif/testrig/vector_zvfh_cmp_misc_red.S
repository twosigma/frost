# Vector Zvfh compares (10), misc/move/slide1 (17), and reductions (6) at SEW=16 (33 modes).
# Covers all 10 vfclass classes, NaN-boxing, all 5 frm modes on reductions, masks, tails, traps.
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

# Section 1: Control vfmin.vv into v6 with unique vmv.x.s x10, v6 (0x42602557).
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xf1128293  # addi x5, x5, -239
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xf2228293  # addi x5, x5, -222
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x12861357  # vfmin.vv v6, v8, v12
.assert trap == 0 "control vfmin.vv e16 retires"
.4byte 0x42602557  # vmv.x.s x10, v6
.assert rd_addr == 10 "control vfmin.vv min(2.0, 1.5)=1.5h writes x10"
.assert rd_wdata == 0x3e00 "control vfmin.vv min(2.0, 1.5)=1.5h"
.4byte 0x3e60bc57  # vslidedown.vi v24, v6, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmin.vv min(-0.0, +0.0)=-0.0 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfmin.vv min(-0.0, +0.0)=-0.0"
.4byte 0x3e613c57  # vslidedown.vi v24, v6, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmin.vv min(qNaN, 1.0)=1.0 writes x10"
.assert rd_wdata == 0x3c00 "vfmin.vv min(qNaN, 1.0)=1.0"
.4byte 0x3e61bc57  # vslidedown.vi v24, v6, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmin.vv min(qNaN, qNaN)=0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfmin.vv min(qNaN, qNaN)=0x7e00"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmin.vv qNaN leaves fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfmin.vv qNaN leaves fflags==0"
# Section 2: All 17 Zvfh misc/sign-inject/class/merge/mv/slide1 modes at SEW=16.
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x1280d857  # vfmin.vf v16, v8, f1
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmin.vf min(2.0, -0.0)=-0.0 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfmin.vf min(2.0, -0.0)=-0.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmin.vf min(-0.0, -0.0)=-0.0 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfmin.vf min(-0.0, -0.0)=-0.0"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmin.vf min(qNaN, -0.0)=-0.0 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfmin.vf min(qNaN, -0.0)=-0.0"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmin.vf fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfmin.vf fflags==0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x1a861857  # vfmax.vv v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmax.vv max(2.0, 1.5)=2.0 writes x10"
.assert rd_wdata == 0x4000 "vfmax.vv max(2.0, 1.5)=2.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmax.vv max(-0.0, +0.0)=+0.0 writes x10"
.assert rd_wdata == 0x0 "vfmax.vv max(-0.0, +0.0)=+0.0"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmax.vv max(qNaN, 1.0)=1.0 writes x10"
.assert rd_wdata == 0x3c00 "vfmax.vv max(qNaN, 1.0)=1.0"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmax.vv max(qNaN, qNaN)=0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfmax.vv max(qNaN, qNaN)=0x7e00"
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0x1a80d857  # vfmax.vf v16, v8, f1
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmax.vf max(-0.0, +0.0)=+0.0 writes x10"
.assert rd_wdata == 0x0 "vfmax.vf max(-0.0, +0.0)=+0.0"
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x13461857  # vfmin.vv v16, v20, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmin.vv min(sNaN, 1.5)=1.5 writes x10"
.assert rd_wdata == 0x3e00 "vfmin.vv min(sNaN, 1.5)=1.5"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmin.vv sNaN raises NV writes x11"
.assert rd_wdata == 0x10 "vfmin.vv sNaN raises NV"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x22861857  # vfsgnj.vv v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsgnj.vv l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsgnj.vv l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnj.vv l1 writes x10"
.assert rd_wdata == 0x3c00 "vfsgnj.vv l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnj.vv l2 writes x10"
.assert rd_wdata == 0xfffffffffffffc01 "vfsgnj.vv l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnj.vv l3 writes x10"
.assert rd_wdata == 0x0 "vfsgnj.vv l3"
.4byte 0x2280d857  # vfsgnj.vf v16, v8, f1
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsgnj.vf l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsgnj.vf l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnj.vf l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsgnj.vf l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnj.vf l2 writes x10"
.assert rd_wdata == 0xfffffffffffffc01 "vfsgnj.vf l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnj.vf l3 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfsgnj.vf l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsgnj never raises fflags writes x11"
.assert rd_wdata == 0x0 "vfsgnj never raises fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x26861857  # vfsgnjn.vv v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsgnjn.vv l0 writes x10"
.assert rd_wdata == 0x3c00 "vfsgnjn.vv l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjn.vv l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsgnjn.vv l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjn.vv l2 writes x10"
.assert rd_wdata == 0x7c01 "vfsgnjn.vv l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjn.vv l3 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfsgnjn.vv l3"
.4byte 0x2680d857  # vfsgnjn.vf v16, v8, f1
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsgnjn.vf l0 writes x10"
.assert rd_wdata == 0x3c00 "vfsgnjn.vf l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjn.vf l1 writes x10"
.assert rd_wdata == 0x3c00 "vfsgnjn.vf l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjn.vf l2 writes x10"
.assert rd_wdata == 0x7c01 "vfsgnjn.vf l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjn.vf l3 writes x10"
.assert rd_wdata == 0x0 "vfsgnjn.vf l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsgnjn never raises fflags writes x11"
.assert rd_wdata == 0x0 "vfsgnjn never raises fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x2a861857  # vfsgnjx.vv v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsgnjx.vv l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsgnjx.vv l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjx.vv l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsgnjx.vv l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjx.vv l2 writes x10"
.assert rd_wdata == 0xfffffffffffffc01 "vfsgnjx.vv l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjx.vv l3 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfsgnjx.vv l3"
.4byte 0x2a80d857  # vfsgnjx.vf v16, v8, f1
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsgnjx.vf l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsgnjx.vf l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjx.vf l1 writes x10"
.assert rd_wdata == 0x3c00 "vfsgnjx.vf l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjx.vf l2 writes x10"
.assert rd_wdata == 0xfffffffffffffc01 "vfsgnjx.vf l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsgnjx.vf l3 writes x10"
.assert rd_wdata == 0x0 "vfsgnjx.vf l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsgnjx never raises fflags writes x11"
.assert rd_wdata == 0x0 "vfsgnjx never raises fflags"
# vfclass.v covering all 10 FP16 classes.
.4byte 0xc0957657  # vsetivli x12, 10, e16, m2, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e881857  # vfclass.v v16, v8
.assert trap == 0 "vfclass.v all 10 classes retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfclass.v class bit 0 writes x10"
.assert rd_wdata == 0x1 "vfclass.v class bit 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfclass.v class bit 1 writes x10"
.assert rd_wdata == 0x2 "vfclass.v class bit 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfclass.v class bit 2 writes x10"
.assert rd_wdata == 0x4 "vfclass.v class bit 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfclass.v class bit 3 writes x10"
.assert rd_wdata == 0x8 "vfclass.v class bit 3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfclass.v class bit 4 writes x10"
.assert rd_wdata == 0x10 "vfclass.v class bit 4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfclass.v class bit 5 writes x10"
.assert rd_wdata == 0x20 "vfclass.v class bit 5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfclass.v class bit 6 writes x10"
.assert rd_wdata == 0x40 "vfclass.v class bit 6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfclass.v class bit 7 writes x10"
.assert rd_wdata == 0x80 "vfclass.v class bit 7"
.4byte 0x3f043c57  # vslidedown.vi v24, v16, 8
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfclass.v class bit 8 writes x10"
.assert rd_wdata == 0x100 "vfclass.v class bit 8"
.4byte 0x3f04bc57  # vslidedown.vi v24, v16, 9
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfclass.v class bit 9 writes x10"
.assert rd_wdata == 0x200 "vfclass.v class bit 9"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfclass.v leaves fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfclass.v leaves fflags==0"
# vfmv.v.f, vfmerge.vfm, vfmv.s.f, vfmv.f.s (NaN-boxing), vfslide1up/down.vf (boxed & unboxed).
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x00a00293  # addi x5, x0, 10
.4byte 0x5e02c057  # vmv.v.x v0, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x50028293  # addi x5, x5, 1280
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0xf2028153  # fmv.d.x f2, x5
.4byte 0x5e00d857  # vfmv.v.f v16, f1
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmv.v.f boxed l0 writes x10"
.assert rd_wdata == 0x4500 "vfmv.v.f boxed l0"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmv.v.f boxed l3 writes x10"
.assert rd_wdata == 0x4500 "vfmv.v.f boxed l3"
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x40028293  # addi x5, x5, 1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x5c80d857  # vfmerge.vfm v16, v8, f1, v0
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmerge.vfm m=0 l0 writes x10"
.assert rd_wdata == 0x3c00 "vfmerge.vfm m=0 l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmerge.vfm m=1 l1 writes x10"
.assert rd_wdata == 0x4500 "vfmerge.vfm m=1 l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmerge.vfm m=0 l2 writes x10"
.assert rd_wdata == 0x4200 "vfmerge.vfm m=0 l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmerge.vfm m=1 l3 writes x10"
.assert rd_wdata == 0x4500 "vfmerge.vfm m=1 l3"
.4byte 0x428011d7  # vfmv.f.s f3, v8
.4byte 0xe2018553  # fmv.x.d x10, f3
.assert rd_addr == 10 "vfmv.f.s NaN-boxes FP16 1.0h in f3 writes x10"
.assert rd_wdata == 0xffffffffffff3c00 "vfmv.f.s NaN-boxes FP16 1.0h in f3"
.4byte 0xe4018553  # fmv.x.h x10, f3
.assert rd_addr == 10 "vfmv.f.s fmv.x.h reads 0x3c00 writes x10"
.assert rd_wdata == 0x3c00 "vfmv.f.s fmv.x.h reads 0x3c00"
.4byte 0x42015857  # vfmv.s.f v16, f2
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmv.s.f unboxed scalar -> 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfmv.s.f unboxed scalar -> 0x7e00"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmv.s.f preserves lane 1 writes x10"
.assert rd_wdata == 0x4500 "vfmv.s.f preserves lane 1"
.4byte 0x3a80d857  # vfslide1up.vf v16, v8, f1
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfslide1up.vf l0=f1 writes x10"
.assert rd_wdata == 0x4500 "vfslide1up.vf l0=f1"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfslide1up.vf l1=vs2[0] writes x10"
.assert rd_wdata == 0x3c00 "vfslide1up.vf l1=vs2[0]"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfslide1up.vf l3=vs2[2] writes x10"
.assert rd_wdata == 0x4200 "vfslide1up.vf l3=vs2[2]"
.4byte 0x3e815857  # vfslide1down.vf v16, v8, f2
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfslide1down.vf l0=vs2[1] writes x10"
.assert rd_wdata == 0x4000 "vfslide1down.vf l0=vs2[1]"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfslide1down.vf unboxed f2 -> 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfslide1down.vf unboxed f2 -> 0x7e00"

# Section 3: All 10 Zvfh FP16 compares (-0==+0, qNaN/sNaN NV, masked NV suppression).
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x62861a57  # vmfeq.vv v20, v8, v12
.assert trap == 0 "vmfeq.vv e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmfeq.vv mask writes x10"
.assert rd_wdata == 0x1 "vmfeq.vv mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmfeq.vv fflags writes x11"
.assert rd_wdata == 0x0 "vmfeq.vv fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x6280da57  # vmfeq.vf v20, v8, f1
.assert trap == 0 "vmfeq.vf e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmfeq.vf mask writes x10"
.assert rd_wdata == 0x0 "vmfeq.vf mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmfeq.vf fflags writes x11"
.assert rd_wdata == 0x0 "vmfeq.vf fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x72861a57  # vmfne.vv v20, v8, v12
.assert trap == 0 "vmfne.vv e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmfne.vv mask writes x10"
.assert rd_wdata == 0xe "vmfne.vv mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmfne.vv fflags writes x11"
.assert rd_wdata == 0x0 "vmfne.vv fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x7280da57  # vmfne.vf v20, v8, f1
.assert trap == 0 "vmfne.vf e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmfne.vf mask writes x10"
.assert rd_wdata == 0xf "vmfne.vf mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmfne.vf fflags writes x11"
.assert rd_wdata == 0x0 "vmfne.vf fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x6e861a57  # vmflt.vv v20, v8, v12
.assert trap == 0 "vmflt.vv e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmflt.vv mask writes x10"
.assert rd_wdata == 0x2 "vmflt.vv mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmflt.vv fflags writes x11"
.assert rd_wdata == 0x10 "vmflt.vv fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x6e80da57  # vmflt.vf v20, v8, f1
.assert trap == 0 "vmflt.vf e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmflt.vf mask writes x10"
.assert rd_wdata == 0x3 "vmflt.vf mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmflt.vf fflags writes x11"
.assert rd_wdata == 0x10 "vmflt.vf fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x66861a57  # vmfle.vv v20, v8, v12
.assert trap == 0 "vmfle.vv e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmfle.vv mask writes x10"
.assert rd_wdata == 0x3 "vmfle.vv mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmfle.vv fflags writes x11"
.assert rd_wdata == 0x10 "vmfle.vv fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x6680da57  # vmfle.vf v20, v8, f1
.assert trap == 0 "vmfle.vf e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmfle.vf mask writes x10"
.assert rd_wdata == 0x3 "vmfle.vf mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmfle.vf fflags writes x11"
.assert rd_wdata == 0x10 "vmfle.vf fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x7680da57  # vmfgt.vf v20, v8, f1
.assert trap == 0 "vmfgt.vf e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmfgt.vf mask writes x10"
.assert rd_wdata == 0x4 "vmfgt.vf mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmfgt.vf fflags writes x11"
.assert rd_wdata == 0x10 "vmfgt.vf fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x7e80da57  # vmfge.vf v20, v8, f1
.assert trap == 0 "vmfge.vf e16 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vmfge.vf mask writes x10"
.assert rd_wdata == 0x4 "vmfge.vf mask"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vmfge.vf fflags writes x11"
.assert rd_wdata == 0x10 "vmfge.vf fflags"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x00700293  # addi x5, x0, 7
.4byte 0x5e02c057  # vmv.v.x v0, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x6c80da57  # vmflt.vf v20, v8, f1, v0.t
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "masked vmflt.vf suppresses inactive sNaN NV writes x11"
.assert rd_wdata == 0x0 "masked vmflt.vf suppresses inactive sNaN NV"

# Section 4: All 6 Zvfh FP16 reductions across all 5 frm modes, ordered sum, subnormals, masks, vl=0.
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x0000b2b7  # lui x5, 0xb
.4byte 0x40028293  # addi x5, x5, 1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x80028293  # addi x5, x5, -2048
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x80028293  # addi x5, x5, -2048
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000052b7  # lui x5, 0x5
.4byte 0x55528293  # addi x5, x5, 1365
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000052b7  # lui x5, 0x5
.4byte 0x55528293  # addi x5, x5, 1365
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000052b7  # lui x5, 0x5
.4byte 0x55528293  # addi x5, x5, 1365
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000072b7  # lui x5, 0x7
.4byte 0x80028293  # addi x5, x5, -2048
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x123452b7  # lui x5, 0x12345
.4byte 0x67828293  # addi x5, x5, 1656
.4byte 0x5e02c757  # vmv.v.x v14, x5
.4byte 0x3f8002b7  # lui x5, 0x3f800
.4byte 0x3ae2ee57  # vslide1up.vx v28, v14, x5
.4byte 0x5e0e0757  # vmv.v.v v14, v28
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x06861857  # vfredusum.vs v16, v8, v12
.assert trap == 0 "vfredusum.vs RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredusum.vs RNE vd[0] writes x10"
.assert rd_wdata == 0x6800 "vfredusum.vs RNE vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredusum.vs RNE tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredusum.vs RNE tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredusum.vs RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfredusum.vs RNE fflags"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0e861857  # vfredosum.vs v16, v8, v12
.assert trap == 0 "vfredosum.vs RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredosum.vs RNE vd[0] writes x10"
.assert rd_wdata == 0x6800 "vfredosum.vs RNE vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredosum.vs RNE tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredosum.vs RNE tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredosum.vs RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfredosum.vs RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc6871857  # vfwredusum.vs v16, v8, v14
.assert trap == 0 "vfwredusum.vs RNE retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredusum.vs RNE vd[0] writes x10"
.assert rd_wdata == 0x3fe00000 "vfwredusum.vs RNE vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredusum.vs RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwredusum.vs RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xce871857  # vfwredosum.vs v16, v8, v14
.assert trap == 0 "vfwredosum.vs RNE retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredosum.vs RNE vd[0] writes x10"
.assert rd_wdata == 0x3fe00000 "vfwredosum.vs RNE vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredosum.vs RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwredosum.vs RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x06861857  # vfredusum.vs v16, v8, v12
.assert trap == 0 "vfredusum.vs RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredusum.vs RTZ vd[0] writes x10"
.assert rd_wdata == 0x67ff "vfredusum.vs RTZ vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredusum.vs RTZ tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredusum.vs RTZ tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredusum.vs RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfredusum.vs RTZ fflags"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0e861857  # vfredosum.vs v16, v8, v12
.assert trap == 0 "vfredosum.vs RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredosum.vs RTZ vd[0] writes x10"
.assert rd_wdata == 0x67ff "vfredosum.vs RTZ vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredosum.vs RTZ tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredosum.vs RTZ tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredosum.vs RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfredosum.vs RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc6871857  # vfwredusum.vs v16, v8, v14
.assert trap == 0 "vfwredusum.vs RTZ retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredusum.vs RTZ vd[0] writes x10"
.assert rd_wdata == 0x3fe00000 "vfwredusum.vs RTZ vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredusum.vs RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwredusum.vs RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xce871857  # vfwredosum.vs v16, v8, v14
.assert trap == 0 "vfwredosum.vs RTZ retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredosum.vs RTZ vd[0] writes x10"
.assert rd_wdata == 0x3fe00000 "vfwredosum.vs RTZ vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredosum.vs RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwredosum.vs RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x06861857  # vfredusum.vs v16, v8, v12
.assert trap == 0 "vfredusum.vs RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredusum.vs RDN vd[0] writes x10"
.assert rd_wdata == 0x67ff "vfredusum.vs RDN vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredusum.vs RDN tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredusum.vs RDN tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredusum.vs RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfredusum.vs RDN fflags"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0e861857  # vfredosum.vs v16, v8, v12
.assert trap == 0 "vfredosum.vs RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredosum.vs RDN vd[0] writes x10"
.assert rd_wdata == 0x67ff "vfredosum.vs RDN vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredosum.vs RDN tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredosum.vs RDN tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredosum.vs RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfredosum.vs RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc6871857  # vfwredusum.vs v16, v8, v14
.assert trap == 0 "vfwredusum.vs RDN retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredusum.vs RDN vd[0] writes x10"
.assert rd_wdata == 0x3fe00000 "vfwredusum.vs RDN vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredusum.vs RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwredusum.vs RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xce871857  # vfwredosum.vs v16, v8, v14
.assert trap == 0 "vfwredosum.vs RDN retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredosum.vs RDN vd[0] writes x10"
.assert rd_wdata == 0x3fe00000 "vfwredosum.vs RDN vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredosum.vs RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwredosum.vs RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x06861857  # vfredusum.vs v16, v8, v12
.assert trap == 0 "vfredusum.vs RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredusum.vs RUP vd[0] writes x10"
.assert rd_wdata == 0x6803 "vfredusum.vs RUP vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredusum.vs RUP tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredusum.vs RUP tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredusum.vs RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfredusum.vs RUP fflags"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0e861857  # vfredosum.vs v16, v8, v12
.assert trap == 0 "vfredosum.vs RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredosum.vs RUP vd[0] writes x10"
.assert rd_wdata == 0x6803 "vfredosum.vs RUP vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredosum.vs RUP tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredosum.vs RUP tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredosum.vs RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfredosum.vs RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc6871857  # vfwredusum.vs v16, v8, v14
.assert trap == 0 "vfwredusum.vs RUP retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredusum.vs RUP vd[0] writes x10"
.assert rd_wdata == 0x3fe00001 "vfwredusum.vs RUP vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredusum.vs RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwredusum.vs RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xce871857  # vfwredosum.vs v16, v8, v14
.assert trap == 0 "vfwredosum.vs RUP retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredosum.vs RUP vd[0] writes x10"
.assert rd_wdata == 0x3fe00001 "vfwredosum.vs RUP vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredosum.vs RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwredosum.vs RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x06861857  # vfredusum.vs v16, v8, v12
.assert trap == 0 "vfredusum.vs RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredusum.vs RMM vd[0] writes x10"
.assert rd_wdata == 0x6800 "vfredusum.vs RMM vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredusum.vs RMM tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredusum.vs RMM tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredusum.vs RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfredusum.vs RMM fflags"
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0e861857  # vfredosum.vs v16, v8, v12
.assert trap == 0 "vfredosum.vs RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredosum.vs RMM vd[0] writes x10"
.assert rd_wdata == 0x6800 "vfredosum.vs RMM vd[0]"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfredosum.vs RMM tu vd[1] writes x10"
.assert rd_wdata == 0x5a5a "vfredosum.vs RMM tu vd[1]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredosum.vs RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfredosum.vs RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xc6871857  # vfwredusum.vs v16, v8, v14
.assert trap == 0 "vfwredusum.vs RMM retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredusum.vs RMM vd[0] writes x10"
.assert rd_wdata == 0x3fe00001 "vfwredusum.vs RMM vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredusum.vs RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwredusum.vs RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xce871857  # vfwredosum.vs v16, v8, v14
.assert trap == 0 "vfwredosum.vs RMM retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwredosum.vs RMM vd[0] writes x10"
.assert rd_wdata == 0x3fe00001 "vfwredosum.vs RMM vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwredosum.vs RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwredosum.vs RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x16861857  # vfredmin.vs v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredmin.vs vd[0] writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfredmin.vs vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredmin.vs fflags writes x11"
.assert rd_wdata == 0x0 "vfredmin.vs fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x1e861857  # vfredmax.vs v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredmax.vs vd[0] writes x10"
.assert rd_wdata == 0x4000 "vfredmax.vs vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredmax.vs fflags writes x11"
.assert rd_wdata == 0x0 "vfredmax.vs fflags"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0c861857  # vfredosum.vs v16, v8, v12, v0.t
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "all-masked vfredosum copies sNaN seed verbatim writes x10"
.assert rd_wdata == 0x7c01 "all-masked vfredosum copies sNaN seed verbatim"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "all-masked vfredosum suppresses NV writes x11"
.assert rd_wdata == 0x0 "all-masked vfredosum suppresses NV"
.4byte 0xc0807657  # vsetivli x12, 0, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0e861857  # vfredosum.vs v16, v8, v12
.4byte 0xc080f657  # vsetivli x12, 1, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfredosum vl=0 preserves vd[0] writes x10"
.assert rd_wdata == 0x7c01 "vfredosum vl=0 preserves vd[0]"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfredosum vl=0 leaves fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfredosum vl=0 leaves fflags==0"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x00f00293  # addi x5, x0, 15
.4byte 0x5e02c057  # vmv.v.x v0, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x60841057  # vmfeq.vv v0, v8, v8, v0.t
.assert trap == 0 "legal masked vmfeq.vv vd==v0 retires"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x00f00293  # addi x5, x0, 15
.4byte 0x5e02c057  # vmv.v.x v0, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x14861057  # vfredmin.vs v0, v8, v12, v0.t
.assert trap == 0 "legal masked vfredmin.vs vd==v0 retires"
.4byte 0x00e07fd7  # vsetvli x31, x0, e16, mf4, tu, mu
.4byte 0x2a841857  # vfsgnjx.vv v16, v8, v8
.assert trap == 0 "vfsgnjx.vv VLMAX e16 mf4 retires"
.4byte 0x00f07fd7  # vsetvli x31, x0, e16, mf2, tu, mu
.4byte 0x2a841857  # vfsgnjx.vv v16, v8, v8
.assert trap == 0 "vfsgnjx.vv VLMAX e16 mf2 retires"
.4byte 0x00807fd7  # vsetvli x31, x0, e16, m1, tu, mu
.4byte 0x2a841857  # vfsgnjx.vv v16, v8, v8
.assert trap == 0 "vfsgnjx.vv VLMAX e16 m1 retires"
.4byte 0x00907fd7  # vsetvli x31, x0, e16, m2, tu, mu
.4byte 0x2a841857  # vfsgnjx.vv v16, v8, v8
.assert trap == 0 "vfsgnjx.vv VLMAX e16 m2 retires"
.4byte 0x00a07fd7  # vsetvli x31, x0, e16, m4, tu, mu
.4byte 0x2a841857  # vfsgnjx.vv v16, v8, v8
.assert trap == 0 "vfsgnjx.vv VLMAX e16 m4 retires"
# Illegal Zvfh compare/misc/reduction traps.
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x3a80d457  # vfslide1up.vf v8, v8, f1
.assert trap == 1 "vfslide1up.vf vd==vs2 traps"
.4byte 0xce841857  # vfwredosum.vs v16, v8, v8
.assert trap == 1 "vfwredosum.vs vs2==vs1 traps"
.4byte 0x10061857  # vfmin.vv v16, v0, v12, v0.t
.assert trap == 1 "masked vfmin.vv vs2==v0 traps"
.4byte 0xc0927657  # vsetivli x12, 4, e16, m2, tu, mu
.4byte 0x128618d7  # vfmin.vv v17, v8, v12
.assert trap == 1 "vfmin.vv misaligned vd m2 traps"
.4byte 0x00235073  # csrwi frm, 6
.4byte 0x0e861857  # vfredosum.vs v16, v8, v12
.assert trap == 1 "vfredosum.vs reserved frm=6 traps"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0xc2027657  # vsetivli reserved_sew4 (sets vill)
.4byte 0x62861857  # vmfeq.vv v16, v8, v12
.assert trap == 1 "vmfeq.vv under vill traps"
