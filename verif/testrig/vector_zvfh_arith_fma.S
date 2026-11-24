# Vector Zvfh single-width arithmetic (13 modes) and FMA (16 modes) at SEW=16 (29 modes).
# Covers all 5 frm modes with readbacks, subnormals, NaN-boxing, canonical NaN, fflags, masks, tails, traps.
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

# Section 1: Control vfadd.vv into v5 with unique vmv.x.s x10, v5 (0x42502557).
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x80028293  # addi x5, x5, -2048
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x028612d7  # vfadd.vv v5, v8, v12
.assert trap == 0 "control vfadd.vv e16 retires"
.4byte 0x42502557  # vmv.x.s x10, v5
.assert rd_addr == 10 "control vfadd.vv 1.0+1.5=2.5h writes x10"
.assert rd_wdata == 0x4100 "control vfadd.vv 1.0+1.5=2.5h"
.4byte 0x3e50bc57  # vslidedown.vi v24, v5, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vfadd.vv 2.0-0.5=1.5h writes x10"
.assert rd_wdata == 0x3e00 "control vfadd.vv 2.0-0.5=1.5h"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "control vfadd.vv exact fflags==0 writes x11"
.assert rd_wdata == 0x0 "control vfadd.vv exact fflags==0"

# Section 2: All 13 single-width FP16 arith/div/sqrt/estimate ops across all 5 frm modes.
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0228293  # addi x5, x5, -1022
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0228293  # addi x5, x5, -1022
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000092b7  # lui x5, 0x9
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000092b7  # lui x5, 0x9
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.assert trap == 0 "vfadd.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vv RNE l0 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfadd.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfadd.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vv RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0280d857  # vfadd.vf v16, v8, f1
.assert trap == 0 "vfadd.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vf RNE l0 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfadd.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfadd.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vf RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a861857  # vfsub.vv v16, v8, v12
.assert trap == 0 "vfsub.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vv RNE l0 writes x10"
.assert rd_wdata == 0x3c00 "vfsub.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsub.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfsub.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfsub.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vv RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a80d857  # vfsub.vf v16, v8, f1
.assert trap == 0 "vfsub.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vf RNE l0 writes x10"
.assert rd_wdata == 0x3c00 "vfsub.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfsub.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfsub.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfsub.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vf RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9e80d857  # vfrsub.vf v16, v8, f1
.assert trap == 0 "vfrsub.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsub.vf RNE l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfrsub.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RNE l1 writes x10"
.assert rd_wdata == 0x3c02 "vfrsub.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfrsub.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RNE l3 writes x10"
.assert rd_wdata == 0x3c02 "vfrsub.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsub.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfrsub.vf RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.assert trap == 0 "vfadd.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3c01 "vfadd.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfadd.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RTZ l2 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfadd.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vv RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0280d857  # vfadd.vf v16, v8, f1
.assert trap == 0 "vfadd.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3c01 "vfadd.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfadd.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RTZ l2 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfadd.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vf RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a861857  # vfsub.vv v16, v8, v12
.assert trap == 0 "vfsub.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3c00 "vfsub.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsub.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RTZ l2 writes x10"
.assert rd_wdata == 0x3c01 "vfsub.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfsub.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vv RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a80d857  # vfsub.vf v16, v8, f1
.assert trap == 0 "vfsub.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3c00 "vfsub.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfsub.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RTZ l2 writes x10"
.assert rd_wdata == 0x3c01 "vfsub.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfsub.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vf RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9e80d857  # vfrsub.vf v16, v8, f1
.assert trap == 0 "vfrsub.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsub.vf RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfrsub.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RTZ l1 writes x10"
.assert rd_wdata == 0x3c01 "vfrsub.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfrsub.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RTZ l3 writes x10"
.assert rd_wdata == 0x3c02 "vfrsub.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsub.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfrsub.vf RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.assert trap == 0 "vfadd.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vv RDN l0 writes x10"
.assert rd_wdata == 0x3c01 "vfadd.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfadd.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RDN l2 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfadd.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vv RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0280d857  # vfadd.vf v16, v8, f1
.assert trap == 0 "vfadd.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vf RDN l0 writes x10"
.assert rd_wdata == 0x3c01 "vfadd.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfadd.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RDN l2 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfadd.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vf RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a861857  # vfsub.vv v16, v8, v12
.assert trap == 0 "vfsub.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vv RDN l0 writes x10"
.assert rd_wdata == 0x3c00 "vfsub.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfsub.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RDN l2 writes x10"
.assert rd_wdata == 0x3c01 "vfsub.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfsub.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vv RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a80d857  # vfsub.vf v16, v8, f1
.assert trap == 0 "vfsub.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vf RDN l0 writes x10"
.assert rd_wdata == 0x3c00 "vfsub.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfsub.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RDN l2 writes x10"
.assert rd_wdata == 0x3c01 "vfsub.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfsub.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vf RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9e80d857  # vfrsub.vf v16, v8, f1
.assert trap == 0 "vfrsub.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsub.vf RDN l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfrsub.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RDN l1 writes x10"
.assert rd_wdata == 0x3c01 "vfrsub.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfrsub.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RDN l3 writes x10"
.assert rd_wdata == 0x3c02 "vfrsub.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsub.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfrsub.vf RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.assert trap == 0 "vfadd.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vv RUP l0 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfadd.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RUP l2 writes x10"
.assert rd_wdata == 0x3c03 "vfadd.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfadd.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vv RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0280d857  # vfadd.vf v16, v8, f1
.assert trap == 0 "vfadd.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vf RUP l0 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfadd.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RUP l2 writes x10"
.assert rd_wdata == 0x3c03 "vfadd.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfadd.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vf RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a861857  # vfsub.vv v16, v8, v12
.assert trap == 0 "vfsub.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vv RUP l0 writes x10"
.assert rd_wdata == 0x3c01 "vfsub.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfsub.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RUP l2 writes x10"
.assert rd_wdata == 0x3c02 "vfsub.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfsub.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vv RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a80d857  # vfsub.vf v16, v8, f1
.assert trap == 0 "vfsub.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vf RUP l0 writes x10"
.assert rd_wdata == 0x3c01 "vfsub.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfsub.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RUP l2 writes x10"
.assert rd_wdata == 0x3c02 "vfsub.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfsub.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vf RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9e80d857  # vfrsub.vf v16, v8, f1
.assert trap == 0 "vfrsub.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsub.vf RUP l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfrsub.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RUP l1 writes x10"
.assert rd_wdata == 0x3c02 "vfrsub.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfrsub.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RUP l3 writes x10"
.assert rd_wdata == 0x3c03 "vfrsub.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsub.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfrsub.vf RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.assert trap == 0 "vfadd.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vv RMM l0 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfadd.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RMM l2 writes x10"
.assert rd_wdata == 0x3c03 "vfadd.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfadd.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vv RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0280d857  # vfadd.vf v16, v8, f1
.assert trap == 0 "vfadd.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vf RMM l0 writes x10"
.assert rd_wdata == 0x3c02 "vfadd.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfadd.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RMM l2 writes x10"
.assert rd_wdata == 0x3c03 "vfadd.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfadd.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfadd.vf RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a861857  # vfsub.vv v16, v8, v12
.assert trap == 0 "vfsub.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vv RMM l0 writes x10"
.assert rd_wdata == 0x3c01 "vfsub.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfsub.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RMM l2 writes x10"
.assert rd_wdata == 0x3c02 "vfsub.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfsub.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vv RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a80d857  # vfsub.vf v16, v8, f1
.assert trap == 0 "vfsub.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsub.vf RMM l0 writes x10"
.assert rd_wdata == 0x3c01 "vfsub.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfsub.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RMM l2 writes x10"
.assert rd_wdata == 0x3c02 "vfsub.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsub.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfsub.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsub.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfsub.vf RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9e80d857  # vfrsub.vf v16, v8, f1
.assert trap == 0 "vfrsub.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsub.vf RMM l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfrsub.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RMM l1 writes x10"
.assert rd_wdata == 0x3c02 "vfrsub.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfrsub.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsub.vf RMM l3 writes x10"
.assert rd_wdata == 0x3c03 "vfrsub.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsub.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfrsub.vf RMM fflags"
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0328293  # addi x5, x5, -1021
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0328293  # addi x5, x5, -1021
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92861857  # vfmul.vv v16, v8, v12
.assert trap == 0 "vfmul.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vv RNE l0 writes x10"
.assert rd_wdata == 0x3e04 "vfmul.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe04 "vfmul.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbe02 "vfmul.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RNE l3 writes x10"
.assert rd_wdata == 0x3e02 "vfmul.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vv RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9280d857  # vfmul.vf v16, v8, f1
.assert trap == 0 "vfmul.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vf RNE l0 writes x10"
.assert rd_wdata == 0x3e04 "vfmul.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe04 "vfmul.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RNE l2 writes x10"
.assert rd_wdata == 0x3e02 "vfmul.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbe02 "vfmul.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vf RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92861857  # vfmul.vv v16, v8, v12
.assert trap == 0 "vfmul.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3e04 "vfmul.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe04 "vfmul.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbe01 "vfmul.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RTZ l3 writes x10"
.assert rd_wdata == 0x3e01 "vfmul.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vv RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9280d857  # vfmul.vf v16, v8, f1
.assert trap == 0 "vfmul.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3e04 "vfmul.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe04 "vfmul.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RTZ l2 writes x10"
.assert rd_wdata == 0x3e01 "vfmul.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbe01 "vfmul.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vf RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92861857  # vfmul.vv v16, v8, v12
.assert trap == 0 "vfmul.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vv RDN l0 writes x10"
.assert rd_wdata == 0x3e04 "vfmul.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe05 "vfmul.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbe02 "vfmul.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RDN l3 writes x10"
.assert rd_wdata == 0x3e01 "vfmul.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vv RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9280d857  # vfmul.vf v16, v8, f1
.assert trap == 0 "vfmul.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vf RDN l0 writes x10"
.assert rd_wdata == 0x3e04 "vfmul.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe05 "vfmul.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RDN l2 writes x10"
.assert rd_wdata == 0x3e01 "vfmul.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbe02 "vfmul.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vf RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92861857  # vfmul.vv v16, v8, v12
.assert trap == 0 "vfmul.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vv RUP l0 writes x10"
.assert rd_wdata == 0x3e05 "vfmul.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe04 "vfmul.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbe01 "vfmul.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RUP l3 writes x10"
.assert rd_wdata == 0x3e02 "vfmul.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vv RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9280d857  # vfmul.vf v16, v8, f1
.assert trap == 0 "vfmul.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vf RUP l0 writes x10"
.assert rd_wdata == 0x3e05 "vfmul.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe04 "vfmul.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RUP l2 writes x10"
.assert rd_wdata == 0x3e02 "vfmul.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbe01 "vfmul.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vf RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92861857  # vfmul.vv v16, v8, v12
.assert trap == 0 "vfmul.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vv RMM l0 writes x10"
.assert rd_wdata == 0x3e05 "vfmul.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe05 "vfmul.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbe02 "vfmul.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv RMM l3 writes x10"
.assert rd_wdata == 0x3e02 "vfmul.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vv RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x9280d857  # vfmul.vf v16, v8, f1
.assert trap == 0 "vfmul.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vf RMM l0 writes x10"
.assert rd_wdata == 0x3e05 "vfmul.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbe05 "vfmul.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RMM l2 writes x10"
.assert rd_wdata == 0x3e02 "vfmul.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbe02 "vfmul.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmul.vf RMM fflags"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xbff28293  # addi x5, x5, -1025
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x80028293  # addi x5, x5, -2048
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92861857  # vfmul.vv v16, v8, v12
.assert trap == 0 "vfmul.vv subnormal/overflow corner retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmul.vv corner l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmul.vv corner l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv corner l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmul.vv corner l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv corner l2 writes x10"
.assert rd_wdata == 0x0 "vfmul.vv corner l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmul.vv corner l3 writes x10"
.assert rd_wdata == 0x7c00 "vfmul.vv corner l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmul.vv corner OF|UF|NX fflags writes x11"
.assert rd_wdata == 0x7 "vfmul.vv corner OF|UF|NX fflags"
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00328293  # addi x5, x5, 3
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00300293  # addi x5, x0, 3
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x60028293  # addi x5, x5, 1536
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x60028293  # addi x5, x5, 1536
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x00300293  # addi x5, x0, 3
.4byte 0xf4028153  # fmv.h.x f2, x5
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82861857  # vfdiv.vv v16, v8, v12
.assert trap == 0 "vfdiv.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vv RNE l0 writes x10"
.assert rd_wdata == 0x0 "vfdiv.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfdiv.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffff8002 "vfdiv.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RNE l3 writes x10"
.assert rd_wdata == 0x2 "vfdiv.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vv RNE fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vv RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x8280d857  # vfdiv.vf v16, v8, f1
.assert trap == 0 "vfdiv.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vf RNE l0 writes x10"
.assert rd_wdata == 0x0 "vfdiv.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfdiv.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RNE l2 writes x10"
.assert rd_wdata == 0x2 "vfdiv.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffff8002 "vfdiv.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vf RNE fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vf RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x87415857  # vfrdiv.vf v16, v20, f2
.assert trap == 0 "vfrdiv.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrdiv.vf RNE l0 writes x10"
.assert rd_wdata == 0x2 "vfrdiv.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffff8002 "vfrdiv.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RNE l2 writes x10"
.assert rd_wdata == 0x0 "vfrdiv.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfrdiv.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrdiv.vf RNE fflags writes x11"
.assert rd_wdata == 0x3 "vfrdiv.vf RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82861857  # vfdiv.vv v16, v8, v12
.assert trap == 0 "vfdiv.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vv RTZ l0 writes x10"
.assert rd_wdata == 0x0 "vfdiv.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfdiv.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfdiv.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RTZ l3 writes x10"
.assert rd_wdata == 0x1 "vfdiv.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vv RTZ fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vv RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x8280d857  # vfdiv.vf v16, v8, f1
.assert trap == 0 "vfdiv.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vf RTZ l0 writes x10"
.assert rd_wdata == 0x0 "vfdiv.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfdiv.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RTZ l2 writes x10"
.assert rd_wdata == 0x1 "vfdiv.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfdiv.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vf RTZ fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vf RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x87415857  # vfrdiv.vf v16, v20, f2
.assert trap == 0 "vfrdiv.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrdiv.vf RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfrdiv.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfrdiv.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RTZ l2 writes x10"
.assert rd_wdata == 0x0 "vfrdiv.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfrdiv.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrdiv.vf RTZ fflags writes x11"
.assert rd_wdata == 0x3 "vfrdiv.vf RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82861857  # vfdiv.vv v16, v8, v12
.assert trap == 0 "vfdiv.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vv RDN l0 writes x10"
.assert rd_wdata == 0x0 "vfdiv.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfdiv.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffff8002 "vfdiv.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RDN l3 writes x10"
.assert rd_wdata == 0x1 "vfdiv.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vv RDN fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vv RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x8280d857  # vfdiv.vf v16, v8, f1
.assert trap == 0 "vfdiv.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vf RDN l0 writes x10"
.assert rd_wdata == 0x0 "vfdiv.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfdiv.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RDN l2 writes x10"
.assert rd_wdata == 0x1 "vfdiv.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffff8002 "vfdiv.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vf RDN fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vf RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x87415857  # vfrdiv.vf v16, v20, f2
.assert trap == 0 "vfrdiv.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrdiv.vf RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfrdiv.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffff8002 "vfrdiv.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RDN l2 writes x10"
.assert rd_wdata == 0x0 "vfrdiv.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfrdiv.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrdiv.vf RDN fflags writes x11"
.assert rd_wdata == 0x3 "vfrdiv.vf RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82861857  # vfdiv.vv v16, v8, v12
.assert trap == 0 "vfdiv.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vv RUP l0 writes x10"
.assert rd_wdata == 0x1 "vfdiv.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfdiv.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfdiv.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RUP l3 writes x10"
.assert rd_wdata == 0x2 "vfdiv.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vv RUP fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vv RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x8280d857  # vfdiv.vf v16, v8, f1
.assert trap == 0 "vfdiv.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vf RUP l0 writes x10"
.assert rd_wdata == 0x1 "vfdiv.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfdiv.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RUP l2 writes x10"
.assert rd_wdata == 0x2 "vfdiv.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfdiv.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vf RUP fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vf RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x87415857  # vfrdiv.vf v16, v20, f2
.assert trap == 0 "vfrdiv.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrdiv.vf RUP l0 writes x10"
.assert rd_wdata == 0x2 "vfrdiv.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfrdiv.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RUP l2 writes x10"
.assert rd_wdata == 0x1 "vfrdiv.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfrdiv.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrdiv.vf RUP fflags writes x11"
.assert rd_wdata == 0x3 "vfrdiv.vf RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82861857  # vfdiv.vv v16, v8, v12
.assert trap == 0 "vfdiv.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vv RMM l0 writes x10"
.assert rd_wdata == 0x1 "vfdiv.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfdiv.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffff8002 "vfdiv.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv RMM l3 writes x10"
.assert rd_wdata == 0x2 "vfdiv.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vv RMM fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vv RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x8280d857  # vfdiv.vf v16, v8, f1
.assert trap == 0 "vfdiv.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vf RMM l0 writes x10"
.assert rd_wdata == 0x1 "vfdiv.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfdiv.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RMM l2 writes x10"
.assert rd_wdata == 0x2 "vfdiv.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffff8002 "vfdiv.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vf RMM fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vf RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x87415857  # vfrdiv.vf v16, v20, f2
.assert trap == 0 "vfrdiv.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrdiv.vf RMM l0 writes x10"
.assert rd_wdata == 0x2 "vfrdiv.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffff8002 "vfrdiv.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RMM l2 writes x10"
.assert rd_wdata == 0x1 "vfrdiv.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrdiv.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vfrdiv.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrdiv.vf RMM fflags writes x11"
.assert rd_wdata == 0x3 "vfrdiv.vf RMM fflags"
.4byte 0x40000293  # addi x5, x0, 1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
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
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x70028293  # addi x5, x5, 1792
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82861857  # vfdiv.vv v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vv normal RNE l0 writes x10"
.assert rd_wdata == 0x3555 "vfdiv.vv normal RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv normal RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffb555 "vfdiv.vv normal RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv normal RNE l2 writes x10"
.assert rd_wdata == 0x36db "vfdiv.vv normal RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv normal RNE l3 writes x10"
.assert rd_wdata == 0x155 "vfdiv.vv normal RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vv normal RNE fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vv normal RNE fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82861857  # vfdiv.vv v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv.vv normal RDN l0 writes x10"
.assert rd_wdata == 0x3555 "vfdiv.vv normal RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv normal RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffb556 "vfdiv.vv normal RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv normal RDN l2 writes x10"
.assert rd_wdata == 0x36db "vfdiv.vv normal RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv.vv normal RDN l3 writes x10"
.assert rd_wdata == 0x155 "vfdiv.vv normal RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv.vv normal RDN fflags writes x11"
.assert rd_wdata == 0x3 "vfdiv.vv normal RDN fflags"
.4byte 0x40000293  # addi x5, x0, 1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xbff28293  # addi x5, x5, -1025
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 0 "vfsqrt.v RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsqrt.v RNE l0 writes x10"
.assert rd_wdata == 0x3da8 "vfsqrt.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RNE l1 writes x10"
.assert rd_wdata == 0x3eee "vfsqrt.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RNE l2 writes x10"
.assert rd_wdata == 0xc00 "vfsqrt.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RNE l3 writes x10"
.assert rd_wdata == 0x2000 "vfsqrt.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsqrt.v RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfsqrt.v RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ec29857  # vfrec7.v v16, v12
.assert trap == 0 "vfrec7.v RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrec7.v RNE l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrec7.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RNE l1 writes x10"
.assert rd_wdata == 0x3550 "vfrec7.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RNE l2 writes x10"
.assert rd_wdata == 0x7c00 "vfrec7.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RNE l3 writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfrec7.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrec7.v RNE fflags writes x11"
.assert rd_wdata == 0x5 "vfrec7.v RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4f421857  # vfrsqrt7.v v16, v20
.assert trap == 0 "vfrsqrt7.v RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsqrt7.v RNE l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrsqrt7.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RNE l1 writes x10"
.assert rd_wdata == 0x39a0 "vfrsqrt7.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RNE l2 writes x10"
.assert rd_wdata == 0x6bf8 "vfrsqrt7.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RNE l3 writes x10"
.assert rd_wdata == 0x1c00 "vfrsqrt7.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsqrt7.v RNE fflags writes x11"
.assert rd_wdata == 0x0 "vfrsqrt7.v RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 0 "vfsqrt.v RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsqrt.v RTZ l0 writes x10"
.assert rd_wdata == 0x3da8 "vfsqrt.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RTZ l1 writes x10"
.assert rd_wdata == 0x3eed "vfsqrt.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RTZ l2 writes x10"
.assert rd_wdata == 0xc00 "vfsqrt.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RTZ l3 writes x10"
.assert rd_wdata == 0x2000 "vfsqrt.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsqrt.v RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfsqrt.v RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ec29857  # vfrec7.v v16, v12
.assert trap == 0 "vfrec7.v RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrec7.v RTZ l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrec7.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RTZ l1 writes x10"
.assert rd_wdata == 0x3550 "vfrec7.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RTZ l2 writes x10"
.assert rd_wdata == 0x7bff "vfrec7.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RTZ l3 writes x10"
.assert rd_wdata == 0xfffffffffffffbff "vfrec7.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrec7.v RTZ fflags writes x11"
.assert rd_wdata == 0x5 "vfrec7.v RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4f421857  # vfrsqrt7.v v16, v20
.assert trap == 0 "vfrsqrt7.v RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsqrt7.v RTZ l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrsqrt7.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RTZ l1 writes x10"
.assert rd_wdata == 0x39a0 "vfrsqrt7.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RTZ l2 writes x10"
.assert rd_wdata == 0x6bf8 "vfrsqrt7.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RTZ l3 writes x10"
.assert rd_wdata == 0x1c00 "vfrsqrt7.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsqrt7.v RTZ fflags writes x11"
.assert rd_wdata == 0x0 "vfrsqrt7.v RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 0 "vfsqrt.v RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsqrt.v RDN l0 writes x10"
.assert rd_wdata == 0x3da8 "vfsqrt.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RDN l1 writes x10"
.assert rd_wdata == 0x3eed "vfsqrt.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RDN l2 writes x10"
.assert rd_wdata == 0xc00 "vfsqrt.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RDN l3 writes x10"
.assert rd_wdata == 0x2000 "vfsqrt.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsqrt.v RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfsqrt.v RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ec29857  # vfrec7.v v16, v12
.assert trap == 0 "vfrec7.v RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrec7.v RDN l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrec7.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RDN l1 writes x10"
.assert rd_wdata == 0x3550 "vfrec7.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RDN l2 writes x10"
.assert rd_wdata == 0x7bff "vfrec7.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RDN l3 writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfrec7.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrec7.v RDN fflags writes x11"
.assert rd_wdata == 0x5 "vfrec7.v RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4f421857  # vfrsqrt7.v v16, v20
.assert trap == 0 "vfrsqrt7.v RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsqrt7.v RDN l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrsqrt7.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RDN l1 writes x10"
.assert rd_wdata == 0x39a0 "vfrsqrt7.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RDN l2 writes x10"
.assert rd_wdata == 0x6bf8 "vfrsqrt7.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RDN l3 writes x10"
.assert rd_wdata == 0x1c00 "vfrsqrt7.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsqrt7.v RDN fflags writes x11"
.assert rd_wdata == 0x0 "vfrsqrt7.v RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 0 "vfsqrt.v RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsqrt.v RUP l0 writes x10"
.assert rd_wdata == 0x3da9 "vfsqrt.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RUP l1 writes x10"
.assert rd_wdata == 0x3eee "vfsqrt.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RUP l2 writes x10"
.assert rd_wdata == 0xc00 "vfsqrt.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RUP l3 writes x10"
.assert rd_wdata == 0x2000 "vfsqrt.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsqrt.v RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfsqrt.v RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ec29857  # vfrec7.v v16, v12
.assert trap == 0 "vfrec7.v RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrec7.v RUP l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrec7.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RUP l1 writes x10"
.assert rd_wdata == 0x3550 "vfrec7.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RUP l2 writes x10"
.assert rd_wdata == 0x7c00 "vfrec7.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RUP l3 writes x10"
.assert rd_wdata == 0xfffffffffffffbff "vfrec7.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrec7.v RUP fflags writes x11"
.assert rd_wdata == 0x5 "vfrec7.v RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4f421857  # vfrsqrt7.v v16, v20
.assert trap == 0 "vfrsqrt7.v RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsqrt7.v RUP l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrsqrt7.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RUP l1 writes x10"
.assert rd_wdata == 0x39a0 "vfrsqrt7.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RUP l2 writes x10"
.assert rd_wdata == 0x6bf8 "vfrsqrt7.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RUP l3 writes x10"
.assert rd_wdata == 0x1c00 "vfrsqrt7.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsqrt7.v RUP fflags writes x11"
.assert rd_wdata == 0x0 "vfrsqrt7.v RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 0 "vfsqrt.v RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsqrt.v RMM l0 writes x10"
.assert rd_wdata == 0x3da8 "vfsqrt.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RMM l1 writes x10"
.assert rd_wdata == 0x3eee "vfsqrt.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RMM l2 writes x10"
.assert rd_wdata == 0xc00 "vfsqrt.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt.v RMM l3 writes x10"
.assert rd_wdata == 0x2000 "vfsqrt.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsqrt.v RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfsqrt.v RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ec29857  # vfrec7.v v16, v12
.assert trap == 0 "vfrec7.v RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrec7.v RMM l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrec7.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RMM l1 writes x10"
.assert rd_wdata == 0x3550 "vfrec7.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RMM l2 writes x10"
.assert rd_wdata == 0x7c00 "vfrec7.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrec7.v RMM l3 writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfrec7.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrec7.v RMM fflags writes x11"
.assert rd_wdata == 0x5 "vfrec7.v RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4f421857  # vfrsqrt7.v v16, v20
.assert trap == 0 "vfrsqrt7.v RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfrsqrt7.v RMM l0 writes x10"
.assert rd_wdata == 0x3bf8 "vfrsqrt7.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RMM l1 writes x10"
.assert rd_wdata == 0x39a0 "vfrsqrt7.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RMM l2 writes x10"
.assert rd_wdata == 0x6bf8 "vfrsqrt7.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfrsqrt7.v RMM l3 writes x10"
.assert rd_wdata == 0x1c00 "vfrsqrt7.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfrsqrt7.v RMM fflags writes x11"
.assert rd_wdata == 0x0 "vfrsqrt7.v RMM fflags"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
# FP16 specials: DZ, NV, non-canonical qNaN/sNaN canonicalization, unboxed .vf scalar -> 0x7e00.
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82861857  # vfdiv.vv v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfdiv 1.0/+0.0 = +inf writes x10"
.assert rd_wdata == 0x7c00 "vfdiv 1.0/+0.0 = +inf"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfdiv -1.0/-0.0 = +inf writes x10"
.assert rd_wdata == 0x7c00 "vfdiv -1.0/-0.0 = +inf"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfdiv /0 raises DZ writes x11"
.assert rd_wdata == 0x8 "vfdiv /0 raises DZ"
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e801857  # vfsqrt.v v16, v8
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfsqrt(-1.0) = qNaN writes x10"
.assert rd_wdata == 0x7e00 "vfsqrt(-1.0) = qNaN"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfsqrt(-0.0) = -0.0 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfsqrt(-0.0) = -0.0"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfsqrt(-1.0) raises NV writes x11"
.assert rd_wdata == 0x10 "vfsqrt(-1.0) raises NV"
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xfaa28293  # addi x5, x5, -86
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xf5528293  # addi x5, x5, -171
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd +qNaN -> canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfadd +qNaN -> canonical 0x7e00"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd -qNaN -> canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfadd -qNaN -> canonical 0x7e00"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd qNaN leaves fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfadd qNaN leaves fflags==0"
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd sNaN -> canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfadd sNaN -> canonical 0x7e00"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd +inf + -inf -> canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfadd +inf + -inf -> canonical 0x7e00"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfadd sNaN and inf-inf raise NV writes x11"
.assert rd_wdata == 0x10 "vfadd sNaN and inf-inf raise NV"
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0xf2028153  # fmv.d.x f2, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02815857  # vfadd.vf v16, v8, f2
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfadd.vf unboxed scalar -> canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfadd.vf unboxed scalar -> canonical 0x7e00"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfadd.vf unboxed scalar l1 -> canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfadd.vf unboxed scalar l1 -> canonical 0x7e00"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "unboxed scalar qNaN leaves fflags==0 writes x11"
.assert rd_wdata == 0x0 "unboxed scalar qNaN leaves fflags==0"

# Section 3: Single-rounding FMA residual + all 16 FP16 FMA forms across all 5 frm modes (5/5 distinct each).
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x80028293  # addi x5, x5, -2048
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x40000293  # addi x5, x0, 1024
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x40028293  # addi x5, x5, 1024
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0228293  # addi x5, x5, -1022
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb2861857  # vfmacc.vv v16, v12, v8
.assert trap == 0 "vfmacc.vv single-rounding residual retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vv single-rounding l0 writes x10"
.assert rd_wdata == 0x10 "vfmacc.vv single-rounding l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv single-rounding l1 writes x10"
.assert rd_wdata == 0x4840 "vfmacc.vv single-rounding l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv single-rounding l2 writes x10"
.assert rd_wdata == 0xffffffffffffb804 "vfmacc.vv single-rounding l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv single-rounding l3 writes x10"
.assert rd_wdata == 0x400 "vfmacc.vv single-rounding l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vv single-rounding fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vv single-rounding fflags"
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0228293  # addi x5, x5, -1022
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0228293  # addi x5, x5, -1022
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x000092b7  # lui x5, 0x9
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000092b7  # lui x5, 0x9
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0xf40280d3  # fmv.h.x f1, x5
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb2861857  # vfmacc.vv v16, v12, v8
.assert trap == 0 "vfmacc.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vv RNE l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmacc.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmacc.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vv RNE fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb280d857  # vfmacc.vf v16, f1, v8
.assert trap == 0 "vfmacc.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vf RNE l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmacc.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmacc.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vf RNE fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb6861857  # vfnmacc.vv v16, v12, v8
.assert trap == 0 "vfnmacc.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vv RNE l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RNE l1 writes x10"
.assert rd_wdata == 0x3c00 "vfnmacc.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RNE l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmacc.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vv RNE fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb680d857  # vfnmacc.vf v16, f1, v8
.assert trap == 0 "vfnmacc.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vf RNE l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RNE l1 writes x10"
.assert rd_wdata == 0x3c02 "vfnmacc.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RNE l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmacc.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vf RNE fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba861857  # vfmsac.vv v16, v12, v8
.assert trap == 0 "vfmsac.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vv RNE l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsac.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RNE l1 writes x10"
.assert rd_wdata == 0x3c02 "vfmsac.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsac.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RNE l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsac.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vv RNE fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba80d857  # vfmsac.vf v16, f1, v8
.assert trap == 0 "vfmsac.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vf RNE l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsac.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RNE l1 writes x10"
.assert rd_wdata == 0x3c00 "vfmsac.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsac.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RNE l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsac.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vf RNE fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe861857  # vfnmsac.vv v16, v12, v8
.assert trap == 0 "vfnmsac.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vv RNE l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsac.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsac.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsac.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsac.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vv RNE fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe80d857  # vfnmsac.vf v16, f1, v8
.assert trap == 0 "vfnmsac.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vf RNE l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsac.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfnmsac.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsac.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsac.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vf RNE fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa3461857  # vfmadd.vv v16, v12, v20
.assert trap == 0 "vfmadd.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vv RNE l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmadd.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmadd.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vv RNE fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa340d857  # vfmadd.vf v16, f1, v20
.assert trap == 0 "vfmadd.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vf RNE l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmadd.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmadd.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vf RNE fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa7461857  # vfnmadd.vv v16, v12, v20
.assert trap == 0 "vfnmadd.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vv RNE l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RNE l1 writes x10"
.assert rd_wdata == 0x3c00 "vfnmadd.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RNE l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmadd.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vv RNE fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa740d857  # vfnmadd.vf v16, f1, v20
.assert trap == 0 "vfnmadd.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vf RNE l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RNE l1 writes x10"
.assert rd_wdata == 0x3c02 "vfnmadd.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RNE l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmadd.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vf RNE fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab461857  # vfmsub.vv v16, v12, v20
.assert trap == 0 "vfmsub.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vv RNE l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsub.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RNE l1 writes x10"
.assert rd_wdata == 0x3c02 "vfmsub.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsub.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RNE l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsub.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vv RNE fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab40d857  # vfmsub.vf v16, f1, v20
.assert trap == 0 "vfmsub.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vf RNE l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsub.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RNE l1 writes x10"
.assert rd_wdata == 0x3c00 "vfmsub.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsub.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RNE l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsub.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vf RNE fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf461857  # vfnmsub.vv v16, v12, v20
.assert trap == 0 "vfnmsub.vv RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vv RNE l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsub.vv RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsub.vv RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsub.vv RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsub.vv RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vv RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vv RNE fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf40d857  # vfnmsub.vf v16, f1, v20
.assert trap == 0 "vfnmsub.vf RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vf RNE l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsub.vf RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfnmsub.vf RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RNE l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsub.vf RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RNE l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsub.vf RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vf RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vf RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb2861857  # vfmacc.vv v16, v12, v8
.assert trap == 0 "vfmacc.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3c01 "vfmacc.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmacc.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RTZ l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmacc.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vv RTZ fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb280d857  # vfmacc.vf v16, f1, v8
.assert trap == 0 "vfmacc.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3c01 "vfmacc.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmacc.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RTZ l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmacc.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vf RTZ fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb6861857  # vfnmacc.vv v16, v12, v8
.assert trap == 0 "vfnmacc.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vv RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmacc.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RTZ l1 writes x10"
.assert rd_wdata == 0x3c00 "vfnmacc.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RTZ l3 writes x10"
.assert rd_wdata == 0x3c01 "vfnmacc.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vv RTZ fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb680d857  # vfnmacc.vf v16, f1, v8
.assert trap == 0 "vfnmacc.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vf RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmacc.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RTZ l1 writes x10"
.assert rd_wdata == 0x3c01 "vfnmacc.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RTZ l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmacc.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vf RTZ fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba861857  # vfmsac.vv v16, v12, v8
.assert trap == 0 "vfmsac.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vv RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsac.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RTZ l1 writes x10"
.assert rd_wdata == 0x3c01 "vfmsac.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsac.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RTZ l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsac.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vv RTZ fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba80d857  # vfmsac.vf v16, f1, v8
.assert trap == 0 "vfmsac.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vf RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsac.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RTZ l1 writes x10"
.assert rd_wdata == 0x3c00 "vfmsac.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsac.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RTZ l3 writes x10"
.assert rd_wdata == 0x3c01 "vfmsac.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vf RTZ fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe861857  # vfnmsac.vv v16, v12, v8
.assert trap == 0 "vfnmsac.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsac.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsac.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RTZ l2 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsac.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsac.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vv RTZ fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe80d857  # vfnmsac.vf v16, f1, v8
.assert trap == 0 "vfnmsac.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsac.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfnmsac.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RTZ l2 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsac.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsac.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vf RTZ fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa3461857  # vfmadd.vv v16, v12, v20
.assert trap == 0 "vfmadd.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3c01 "vfmadd.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmadd.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RTZ l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmadd.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vv RTZ fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa340d857  # vfmadd.vf v16, f1, v20
.assert trap == 0 "vfmadd.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3c01 "vfmadd.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmadd.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RTZ l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmadd.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vf RTZ fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa7461857  # vfnmadd.vv v16, v12, v20
.assert trap == 0 "vfnmadd.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vv RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmadd.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RTZ l1 writes x10"
.assert rd_wdata == 0x3c00 "vfnmadd.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RTZ l3 writes x10"
.assert rd_wdata == 0x3c01 "vfnmadd.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vv RTZ fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa740d857  # vfnmadd.vf v16, f1, v20
.assert trap == 0 "vfnmadd.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vf RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmadd.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RTZ l1 writes x10"
.assert rd_wdata == 0x3c01 "vfnmadd.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RTZ l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmadd.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vf RTZ fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab461857  # vfmsub.vv v16, v12, v20
.assert trap == 0 "vfmsub.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vv RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsub.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RTZ l1 writes x10"
.assert rd_wdata == 0x3c01 "vfmsub.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsub.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RTZ l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsub.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vv RTZ fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab40d857  # vfmsub.vf v16, f1, v20
.assert trap == 0 "vfmsub.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vf RTZ l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsub.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RTZ l1 writes x10"
.assert rd_wdata == 0x3c00 "vfmsub.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsub.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RTZ l3 writes x10"
.assert rd_wdata == 0x3c01 "vfmsub.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vf RTZ fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf461857  # vfnmsub.vv v16, v12, v20
.assert trap == 0 "vfnmsub.vv RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vv RTZ l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsub.vv RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsub.vv RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RTZ l2 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsub.vv RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsub.vv RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vv RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vv RTZ fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf40d857  # vfnmsub.vf v16, f1, v20
.assert trap == 0 "vfnmsub.vf RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vf RTZ l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsub.vf RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfnmsub.vf RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RTZ l2 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsub.vf RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RTZ l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsub.vf RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vf RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vf RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb2861857  # vfmacc.vv v16, v12, v8
.assert trap == 0 "vfmacc.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vv RDN l0 writes x10"
.assert rd_wdata == 0x3c01 "vfmacc.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmacc.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RDN l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmacc.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vv RDN fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb280d857  # vfmacc.vf v16, f1, v8
.assert trap == 0 "vfmacc.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vf RDN l0 writes x10"
.assert rd_wdata == 0x3c01 "vfmacc.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmacc.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RDN l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfmacc.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vf RDN fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb6861857  # vfnmacc.vv v16, v12, v8
.assert trap == 0 "vfnmacc.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vv RDN l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RDN l1 writes x10"
.assert rd_wdata == 0x3c00 "vfnmacc.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmacc.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RDN l3 writes x10"
.assert rd_wdata == 0x3c01 "vfnmacc.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vv RDN fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb680d857  # vfnmacc.vf v16, f1, v8
.assert trap == 0 "vfnmacc.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vf RDN l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RDN l1 writes x10"
.assert rd_wdata == 0x3c01 "vfnmacc.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmacc.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RDN l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmacc.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vf RDN fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba861857  # vfmsac.vv v16, v12, v8
.assert trap == 0 "vfmsac.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vv RDN l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsac.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RDN l1 writes x10"
.assert rd_wdata == 0x3c01 "vfmsac.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsac.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RDN l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsac.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vv RDN fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba80d857  # vfmsac.vf v16, f1, v8
.assert trap == 0 "vfmsac.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vf RDN l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsac.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RDN l1 writes x10"
.assert rd_wdata == 0x3c00 "vfmsac.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsac.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RDN l3 writes x10"
.assert rd_wdata == 0x3c01 "vfmsac.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vf RDN fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe861857  # vfnmsac.vv v16, v12, v8
.assert trap == 0 "vfnmsac.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vv RDN l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsac.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsac.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RDN l2 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsac.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmsac.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vv RDN fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe80d857  # vfnmsac.vf v16, f1, v8
.assert trap == 0 "vfnmsac.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vf RDN l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsac.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsac.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RDN l2 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsac.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsac.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vf RDN fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa3461857  # vfmadd.vv v16, v12, v20
.assert trap == 0 "vfmadd.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vv RDN l0 writes x10"
.assert rd_wdata == 0x3c01 "vfmadd.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmadd.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RDN l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmadd.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vv RDN fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa340d857  # vfmadd.vf v16, f1, v20
.assert trap == 0 "vfmadd.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vf RDN l0 writes x10"
.assert rd_wdata == 0x3c01 "vfmadd.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmadd.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RDN l2 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfmadd.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vf RDN fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa7461857  # vfnmadd.vv v16, v12, v20
.assert trap == 0 "vfnmadd.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vv RDN l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RDN l1 writes x10"
.assert rd_wdata == 0x3c00 "vfnmadd.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmadd.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RDN l3 writes x10"
.assert rd_wdata == 0x3c01 "vfnmadd.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vv RDN fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa740d857  # vfnmadd.vf v16, f1, v20
.assert trap == 0 "vfnmadd.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vf RDN l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RDN l1 writes x10"
.assert rd_wdata == 0x3c01 "vfnmadd.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmadd.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RDN l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmadd.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vf RDN fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab461857  # vfmsub.vv v16, v12, v20
.assert trap == 0 "vfmsub.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vv RDN l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsub.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RDN l1 writes x10"
.assert rd_wdata == 0x3c01 "vfmsub.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsub.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RDN l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsub.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vv RDN fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab40d857  # vfmsub.vf v16, f1, v20
.assert trap == 0 "vfmsub.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vf RDN l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsub.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RDN l1 writes x10"
.assert rd_wdata == 0x3c00 "vfmsub.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsub.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RDN l3 writes x10"
.assert rd_wdata == 0x3c01 "vfmsub.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vf RDN fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf461857  # vfnmsub.vv v16, v12, v20
.assert trap == 0 "vfnmsub.vv RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vv RDN l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsub.vv RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsub.vv RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RDN l2 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsub.vv RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmsub.vv RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vv RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vv RDN fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf40d857  # vfnmsub.vf v16, f1, v20
.assert trap == 0 "vfnmsub.vf RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vf RDN l0 writes x10"
.assert rd_wdata == 0x3c00 "vfnmsub.vf RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsub.vf RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RDN l2 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsub.vf RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RDN l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsub.vf RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vf RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vf RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb2861857  # vfmacc.vv v16, v12, v8
.assert trap == 0 "vfmacc.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vv RUP l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmacc.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RUP l2 writes x10"
.assert rd_wdata == 0x3c03 "vfmacc.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmacc.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vv RUP fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb280d857  # vfmacc.vf v16, f1, v8
.assert trap == 0 "vfmacc.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vf RUP l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmacc.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RUP l2 writes x10"
.assert rd_wdata == 0x3c03 "vfmacc.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmacc.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vf RUP fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb6861857  # vfnmacc.vv v16, v12, v8
.assert trap == 0 "vfnmacc.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vv RUP l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmacc.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RUP l1 writes x10"
.assert rd_wdata == 0x3c01 "vfnmacc.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RUP l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmacc.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vv RUP fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb680d857  # vfnmacc.vf v16, f1, v8
.assert trap == 0 "vfnmacc.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vf RUP l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmacc.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RUP l1 writes x10"
.assert rd_wdata == 0x3c02 "vfnmacc.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RUP l3 writes x10"
.assert rd_wdata == 0x3c03 "vfnmacc.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vf RUP fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba861857  # vfmsac.vv v16, v12, v8
.assert trap == 0 "vfmsac.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vv RUP l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsac.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RUP l1 writes x10"
.assert rd_wdata == 0x3c02 "vfmsac.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsac.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RUP l3 writes x10"
.assert rd_wdata == 0x3c03 "vfmsac.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vv RUP fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba80d857  # vfmsac.vf v16, f1, v8
.assert trap == 0 "vfmsac.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vf RUP l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsac.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RUP l1 writes x10"
.assert rd_wdata == 0x3c01 "vfmsac.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsac.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RUP l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsac.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vf RUP fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe861857  # vfnmsac.vv v16, v12, v8
.assert trap == 0 "vfnmsac.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vv RUP l0 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsac.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsac.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RUP l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsac.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsac.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vv RUP fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe80d857  # vfnmsac.vf v16, f1, v8
.assert trap == 0 "vfnmsac.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vf RUP l0 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsac.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfnmsac.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RUP l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsac.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsac.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vf RUP fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa3461857  # vfmadd.vv v16, v12, v20
.assert trap == 0 "vfmadd.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vv RUP l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmadd.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RUP l2 writes x10"
.assert rd_wdata == 0x3c03 "vfmadd.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmadd.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vv RUP fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa340d857  # vfmadd.vf v16, f1, v20
.assert trap == 0 "vfmadd.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vf RUP l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmadd.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RUP l2 writes x10"
.assert rd_wdata == 0x3c03 "vfmadd.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmadd.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vf RUP fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa7461857  # vfnmadd.vv v16, v12, v20
.assert trap == 0 "vfnmadd.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vv RUP l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmadd.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RUP l1 writes x10"
.assert rd_wdata == 0x3c01 "vfnmadd.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RUP l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmadd.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vv RUP fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa740d857  # vfnmadd.vf v16, f1, v20
.assert trap == 0 "vfnmadd.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vf RUP l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmadd.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RUP l1 writes x10"
.assert rd_wdata == 0x3c02 "vfnmadd.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RUP l3 writes x10"
.assert rd_wdata == 0x3c03 "vfnmadd.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vf RUP fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab461857  # vfmsub.vv v16, v12, v20
.assert trap == 0 "vfmsub.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vv RUP l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsub.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RUP l1 writes x10"
.assert rd_wdata == 0x3c02 "vfmsub.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsub.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RUP l3 writes x10"
.assert rd_wdata == 0x3c03 "vfmsub.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vv RUP fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab40d857  # vfmsub.vf v16, f1, v20
.assert trap == 0 "vfmsub.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vf RUP l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfmsub.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RUP l1 writes x10"
.assert rd_wdata == 0x3c01 "vfmsub.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsub.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RUP l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsub.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vf RUP fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf461857  # vfnmsub.vv v16, v12, v20
.assert trap == 0 "vfnmsub.vv RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vv RUP l0 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsub.vv RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsub.vv RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RUP l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsub.vv RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsub.vv RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vv RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vv RUP fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf40d857  # vfnmsub.vf v16, f1, v20
.assert trap == 0 "vfnmsub.vf RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vf RUP l0 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsub.vf RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfnmsub.vf RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RUP l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsub.vf RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RUP l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsub.vf RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vf RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vf RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb2861857  # vfmacc.vv v16, v12, v8
.assert trap == 0 "vfmacc.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vv RMM l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmacc.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RMM l2 writes x10"
.assert rd_wdata == 0x3c03 "vfmacc.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmacc.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vv RMM fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb280d857  # vfmacc.vf v16, f1, v8
.assert trap == 0 "vfmacc.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmacc.vf RMM l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmacc.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmacc.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RMM l2 writes x10"
.assert rd_wdata == 0x3c03 "vfmacc.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmacc.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfmacc.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmacc.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmacc.vf RMM fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb6861857  # vfnmacc.vv v16, v12, v8
.assert trap == 0 "vfnmacc.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vv RMM l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RMM l1 writes x10"
.assert rd_wdata == 0x3c01 "vfnmacc.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmacc.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vv RMM l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmacc.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vv RMM fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb680d857  # vfnmacc.vf v16, f1, v8
.assert trap == 0 "vfnmacc.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmacc.vf RMM l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmacc.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RMM l1 writes x10"
.assert rd_wdata == 0x3c02 "vfnmacc.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmacc.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmacc.vf RMM l3 writes x10"
.assert rd_wdata == 0x3c03 "vfnmacc.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmacc.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfnmacc.vf RMM fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba861857  # vfmsac.vv v16, v12, v8
.assert trap == 0 "vfmsac.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vv RMM l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsac.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RMM l1 writes x10"
.assert rd_wdata == 0x3c02 "vfmsac.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsac.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vv RMM l3 writes x10"
.assert rd_wdata == 0x3c03 "vfmsac.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vv RMM fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xba80d857  # vfmsac.vf v16, f1, v8
.assert trap == 0 "vfmsac.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsac.vf RMM l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsac.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RMM l1 writes x10"
.assert rd_wdata == 0x3c01 "vfmsac.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsac.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsac.vf RMM l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsac.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsac.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmsac.vf RMM fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe861857  # vfnmsac.vv v16, v12, v8
.assert trap == 0 "vfnmsac.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vv RMM l0 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsac.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsac.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RMM l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsac.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmsac.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vv RMM fflags"
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xbe80d857  # vfnmsac.vf v16, f1, v8
.assert trap == 0 "vfnmsac.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsac.vf RMM l0 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsac.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsac.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RMM l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsac.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsac.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsac.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsac.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsac.vf RMM fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa3461857  # vfmadd.vv v16, v12, v20
.assert trap == 0 "vfmadd.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vv RMM l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmadd.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RMM l2 writes x10"
.assert rd_wdata == 0x3c03 "vfmadd.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmadd.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vv RMM fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa340d857  # vfmadd.vf v16, f1, v20
.assert trap == 0 "vfmadd.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmadd.vf RMM l0 writes x10"
.assert rd_wdata == 0x3c02 "vfmadd.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmadd.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RMM l2 writes x10"
.assert rd_wdata == 0x3c03 "vfmadd.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmadd.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfmadd.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmadd.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmadd.vf RMM fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa7461857  # vfnmadd.vv v16, v12, v20
.assert trap == 0 "vfnmadd.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vv RMM l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RMM l1 writes x10"
.assert rd_wdata == 0x3c01 "vfnmadd.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmadd.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vv RMM l3 writes x10"
.assert rd_wdata == 0x3c02 "vfnmadd.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vv RMM fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xa740d857  # vfnmadd.vf v16, f1, v20
.assert trap == 0 "vfnmadd.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmadd.vf RMM l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmadd.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RMM l1 writes x10"
.assert rd_wdata == 0x3c02 "vfnmadd.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmadd.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmadd.vf RMM l3 writes x10"
.assert rd_wdata == 0x3c03 "vfnmadd.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmadd.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfnmadd.vf RMM fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab461857  # vfmsub.vv v16, v12, v20
.assert trap == 0 "vfmsub.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vv RMM l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsub.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RMM l1 writes x10"
.assert rd_wdata == 0x3c02 "vfmsub.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsub.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vv RMM l3 writes x10"
.assert rd_wdata == 0x3c03 "vfmsub.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vv RMM fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xab40d857  # vfmsub.vf v16, f1, v20
.assert trap == 0 "vfmsub.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfmsub.vf RMM l0 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfmsub.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RMM l1 writes x10"
.assert rd_wdata == 0x3c01 "vfmsub.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfmsub.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfmsub.vf RMM l3 writes x10"
.assert rd_wdata == 0x3c02 "vfmsub.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfmsub.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfmsub.vf RMM fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf461857  # vfnmsub.vv v16, v12, v20
.assert trap == 0 "vfnmsub.vv RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vv RMM l0 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsub.vv RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsub.vv RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RMM l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsub.vv RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vv RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc03 "vfnmsub.vv RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vv RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vv RMM fflags"
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xaf40d857  # vfnmsub.vf v16, f1, v20
.assert trap == 0 "vfnmsub.vf RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfnmsub.vf RMM l0 writes x10"
.assert rd_wdata == 0x3c01 "vfnmsub.vf RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfnmsub.vf RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RMM l2 writes x10"
.assert rd_wdata == 0x3c02 "vfnmsub.vf RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfnmsub.vf RMM l3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfnmsub.vf RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfnmsub.vf RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfnmsub.vf RMM fflags"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"

# Section 4: Masked tu/mu & ta/ma (suppressed sNaN), vl=0, portable VLMAX, legal overlaps, traps.
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x00500293  # addi x5, x0, 5
.4byte 0x5e02c057  # vmv.v.x v0, x5
.4byte 0x00807fd7  # vsetvli x31, x0, e16, m1, tu, mu
.4byte 0x000062b7  # lui x5, 0x6
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
.4byte 0x00861857  # vfadd.vv v16, v8, v12, v0.t
.assert trap == 0 "masked vfadd.vv tu/mu retires"
.4byte 0xc082f657  # vsetivli x12, 5, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "masked vfadd.vv active l0 writes x10"
.assert rd_wdata == 0x4100 "masked vfadd.vv active l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vfadd.vv mu inactive l1 writes x10"
.assert rd_wdata == 0x5a5a "masked vfadd.vv mu inactive l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vfadd.vv active l2 writes x10"
.assert rd_wdata == 0x4200 "masked vfadd.vv active l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vfadd.vv mu inactive l3 writes x10"
.assert rd_wdata == 0x5a5a "masked vfadd.vv mu inactive l3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vfadd.vv tu tail l4 writes x10"
.assert rd_wdata == 0x5a5a "masked vfadd.vv tu tail l4"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "masked-off sNaN suppresses NV writes x11"
.assert rd_wdata == 0x0 "masked-off sNaN suppresses NV"
.4byte 0xcc827657  # vsetivli x12, 4, e16, m1, ta, ma
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x90861857  # vfmul.vv v16, v8, v12, v0.t
.assert trap == 0 "masked vfmul.vv ta/ma retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "masked vfmul.vv ta/ma active l0 writes x10"
.assert rd_wdata == 0x3e00 "masked vfmul.vv ta/ma active l0"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "masked vfmul.vv suppresses inactive sNaN NV writes x11"
.assert rd_wdata == 0x0 "masked vfmul.vv suppresses inactive sNaN NV"
.4byte 0xcc807657  # vsetivli x12, 0, e16, m1, ta, ma
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.assert trap == 0 "vfadd.vv vl=0 retires"
.4byte 0xb2861857  # vfmacc.vv v16, v12, v8
.assert trap == 0 "vfmacc.vv vl=0 retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vl=0 leaves fflags==0 writes x11"
.assert rd_wdata == 0x0 "vl=0 leaves fflags==0"
.4byte 0xc080f657  # vsetivli x12, 1, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vl=0 leaves v16[0] untouched writes x10"
.assert rd_wdata == 0x3e00 "vl=0 leaves v16[0] untouched"
.4byte 0x00e07fd7  # vsetvli x31, x0, e16, mf4, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x02841457  # vfadd.vv v8, v8, v8
.assert trap == 0 "in-place vfadd.vv VLMAX e16 mf4 retires"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "vfadd.vv VLMAX mf4 1+1=2 writes x10"
.assert rd_wdata == 0x4000 "vfadd.vv VLMAX mf4 1+1=2"
.4byte 0x00f07fd7  # vsetvli x31, x0, e16, mf2, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x02841457  # vfadd.vv v8, v8, v8
.assert trap == 0 "in-place vfadd.vv VLMAX e16 mf2 retires"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "vfadd.vv VLMAX mf2 1+1=2 writes x10"
.assert rd_wdata == 0x4000 "vfadd.vv VLMAX mf2 1+1=2"
.4byte 0x00807fd7  # vsetvli x31, x0, e16, m1, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x02841457  # vfadd.vv v8, v8, v8
.assert trap == 0 "in-place vfadd.vv VLMAX e16 m1 retires"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "vfadd.vv VLMAX m1 1+1=2 writes x10"
.assert rd_wdata == 0x4000 "vfadd.vv VLMAX m1 1+1=2"
.4byte 0x00907fd7  # vsetvli x31, x0, e16, m2, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x02841457  # vfadd.vv v8, v8, v8
.assert trap == 0 "in-place vfadd.vv VLMAX e16 m2 retires"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "vfadd.vv VLMAX m2 1+1=2 writes x10"
.assert rd_wdata == 0x4000 "vfadd.vv VLMAX m2 1+1=2"
.4byte 0x00a07fd7  # vsetvli x31, x0, e16, m4, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x02841457  # vfadd.vv v8, v8, v8
.assert trap == 0 "in-place vfadd.vv VLMAX e16 m4 retires"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "vfadd.vv VLMAX m4 1+1=2 writes x10"
.assert rd_wdata == 0x4000 "vfadd.vv VLMAX m4 1+1=2"
# Illegal Zvfh single-width traps: e8, masked v0, misaligned m2, reserved frm=5, vill.
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.assert trap == 1 "vfadd.vv at e8 traps"
.4byte 0xb2861857  # vfmacc.vv v16, v12, v8
.assert trap == 1 "vfmacc.vv at e8 traps"
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 1 "vfsqrt.v at e8 traps"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00861057  # vfadd.vv v0, v8, v12, v0.t
.assert trap == 1 "masked vfadd.vv vd==v0 traps"
.4byte 0x90061857  # vfmul.vv v16, v0, v12, v0.t
.assert trap == 1 "masked vfmul.vv vs2==v0 traps"
.4byte 0xc0927657  # vsetivli x12, 4, e16, m2, tu, mu
.4byte 0x028618d7  # vfadd.vv v17, v8, v12
.assert trap == 1 "vfadd.vv misaligned vd m2 traps"
.4byte 0x0022d073  # csrwi frm, 5
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.assert trap == 1 "vfadd.vv reserved frm=5 traps"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0xc2027657  # vsetivli reserved_sew4 (sets vill)
.4byte 0x02861857  # vfadd.vv v16, v8, v12
.assert trap == 1 "vfadd.vv under vill traps"
