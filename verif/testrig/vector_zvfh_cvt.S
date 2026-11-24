# Vector Zvfh conversions: 13 SEW=16 modes (incl. vfncvt.rod.f.f.w) + 6 SEW=8 int8<->FP16 modes (19 modes).
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

# Section 1: Control vfncvt.rod.f.f.w into v8 (unique 0x42802557) + ROD distinctness checks.
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x478002b7  # lui x5, 0x47800
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x3f8032b7  # lui x5, 0x3f803
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x3f8002b7  # lui x5, 0x3f800
.4byte 0x40028293  # addi x5, x5, 1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4aca9457  # vfncvt.rod.f.f.w v8, v12
.assert trap == 0 "control vfncvt.rod.f.f.w retires"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "vfncvt.rod.f.f.w l0 writes x10"
.assert rd_wdata == 0x3c01 "vfncvt.rod.f.f.w l0"
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rod.f.f.w l1 writes x10"
.assert rd_wdata == 0x3c01 "vfncvt.rod.f.f.w l1"
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rod.f.f.w l2 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.rod.f.f.w l2"
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rod.f.f.w l3 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rod.f.f.w l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rod.f.f.w combined OF|UF|NX writes x11"
.assert rd_wdata == 0x7 "vfncvt.rod.f.f.w combined OF|UF|NX"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4aca9857  # vfncvt.rod.f.f.w v16, v12
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rod.f.f.w ignores frm=RUP on odd LSB writes x10"
.assert rd_wdata == 0x3c01 "vfncvt.rod.f.f.w ignores frm=RUP on odd LSB"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"

# Section 2: 6 single-width SEW=16 FP16<->int16 conversions across all 5 frm modes.
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac01857  # vfcvt.xu.f.v v16, v12
.assert trap == 0 "vfcvt.xu.f.v RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.xu.f.v RNE l0 writes x10"
.assert rd_wdata == 0x2 "vfcvt.xu.f.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RNE l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RNE l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.xu.f.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RNE l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.xu.f.v RNE fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.xu.f.v RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac09857  # vfcvt.x.f.v v16, v12
.assert trap == 0 "vfcvt.x.f.v RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.x.f.v RNE l0 writes x10"
.assert rd_wdata == 0x2 "vfcvt.x.f.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RNE l1 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.x.f.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RNE l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.x.f.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RNE l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.x.f.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.x.f.v RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.x.f.v RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac31857  # vfcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.xu.f.v RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RNE l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.xu.f.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RNE l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RNE l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.xu.f.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RNE l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.xu.f.v RNE fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.rtz.xu.f.v RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac39857  # vfcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.x.f.v RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RNE l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfcvt.rtz.x.f.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RNE l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.x.f.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RNE l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.rtz.x.f.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.x.f.v RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac01857  # vfcvt.xu.f.v v16, v12
.assert trap == 0 "vfcvt.xu.f.v RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.xu.f.v RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.xu.f.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RTZ l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RTZ l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.xu.f.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RTZ l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.xu.f.v RTZ fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.xu.f.v RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac09857  # vfcvt.x.f.v v16, v12
.assert trap == 0 "vfcvt.x.f.v RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.x.f.v RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.x.f.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfcvt.x.f.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RTZ l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.x.f.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RTZ l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.x.f.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.x.f.v RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.x.f.v RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac31857  # vfcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.xu.f.v RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.xu.f.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RTZ l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RTZ l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.xu.f.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RTZ l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.xu.f.v RTZ fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.rtz.xu.f.v RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac39857  # vfcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.x.f.v RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfcvt.rtz.x.f.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RTZ l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.x.f.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RTZ l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.rtz.x.f.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.x.f.v RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac01857  # vfcvt.xu.f.v v16, v12
.assert trap == 0 "vfcvt.xu.f.v RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.xu.f.v RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.xu.f.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RDN l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RDN l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.xu.f.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RDN l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.xu.f.v RDN fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.xu.f.v RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac09857  # vfcvt.x.f.v v16, v12
.assert trap == 0 "vfcvt.x.f.v RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.x.f.v RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.x.f.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RDN l1 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.x.f.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RDN l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.x.f.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RDN l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffd "vfcvt.x.f.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.x.f.v RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.x.f.v RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac31857  # vfcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.xu.f.v RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.xu.f.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RDN l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RDN l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.xu.f.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RDN l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.xu.f.v RDN fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.rtz.xu.f.v RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac39857  # vfcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.x.f.v RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfcvt.rtz.x.f.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RDN l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.x.f.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RDN l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.rtz.x.f.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.x.f.v RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac01857  # vfcvt.xu.f.v v16, v12
.assert trap == 0 "vfcvt.xu.f.v RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.xu.f.v RUP l0 writes x10"
.assert rd_wdata == 0x2 "vfcvt.xu.f.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RUP l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RUP l2 writes x10"
.assert rd_wdata == 0x3 "vfcvt.xu.f.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RUP l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.xu.f.v RUP fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.xu.f.v RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac09857  # vfcvt.x.f.v v16, v12
.assert trap == 0 "vfcvt.x.f.v RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.x.f.v RUP l0 writes x10"
.assert rd_wdata == 0x2 "vfcvt.x.f.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfcvt.x.f.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RUP l2 writes x10"
.assert rd_wdata == 0x3 "vfcvt.x.f.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RUP l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.x.f.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.x.f.v RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.x.f.v RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac31857  # vfcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.xu.f.v RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RUP l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.xu.f.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RUP l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RUP l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.xu.f.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RUP l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.xu.f.v RUP fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.rtz.xu.f.v RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac39857  # vfcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.x.f.v RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RUP l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfcvt.rtz.x.f.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RUP l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.x.f.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RUP l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.rtz.x.f.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.x.f.v RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac01857  # vfcvt.xu.f.v v16, v12
.assert trap == 0 "vfcvt.xu.f.v RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.xu.f.v RMM l0 writes x10"
.assert rd_wdata == 0x2 "vfcvt.xu.f.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RMM l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RMM l2 writes x10"
.assert rd_wdata == 0x3 "vfcvt.xu.f.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v RMM l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.xu.f.v RMM fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.xu.f.v RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac09857  # vfcvt.x.f.v v16, v12
.assert trap == 0 "vfcvt.x.f.v RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.x.f.v RMM l0 writes x10"
.assert rd_wdata == 0x2 "vfcvt.x.f.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RMM l1 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.x.f.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RMM l2 writes x10"
.assert rd_wdata == 0x3 "vfcvt.x.f.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v RMM l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffd "vfcvt.x.f.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.x.f.v RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.x.f.v RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac31857  # vfcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.xu.f.v RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RMM l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.xu.f.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RMM l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RMM l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.xu.f.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.xu.f.v RMM l3 writes x10"
.assert rd_wdata == 0x0 "vfcvt.rtz.xu.f.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.xu.f.v RMM fflags writes x11"
.assert rd_wdata == 0x11 "vfcvt.rtz.xu.f.v RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac39857  # vfcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfcvt.rtz.x.f.v RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RMM l0 writes x10"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfcvt.rtz.x.f.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RMM l2 writes x10"
.assert rd_wdata == 0x2 "vfcvt.rtz.x.f.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.rtz.x.f.v RMM l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfcvt.rtz.x.f.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.rtz.x.f.v RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.rtz.x.f.v RMM fflags"
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xbff28293  # addi x5, x5, -1025
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xbff28293  # addi x5, x5, -1025
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac01857  # vfcvt.xu.f.v v16, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.xu.f.v sat l0 writes x10"
.assert rd_wdata == 0xffffffffffffffe0 "vfcvt.xu.f.v sat l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v sat l1 writes x10"
.assert rd_wdata == 0x0 "vfcvt.xu.f.v sat l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v sat l2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfcvt.xu.f.v sat l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.xu.f.v sat l3 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfcvt.xu.f.v sat l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.xu.f.v sat raises NV writes x11"
.assert rd_wdata == 0x10 "vfcvt.xu.f.v sat raises NV"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac09857  # vfcvt.x.f.v v16, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.x.f.v sat l0 writes x10"
.assert rd_wdata == 0x7fff "vfcvt.x.f.v sat l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v sat l1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vfcvt.x.f.v sat l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v sat l2 writes x10"
.assert rd_wdata == 0x7fff "vfcvt.x.f.v sat l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.x.f.v sat l3 writes x10"
.assert rd_wdata == 0x7fff "vfcvt.x.f.v sat l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.x.f.v sat raises NV writes x11"
.assert rd_wdata == 0x10 "vfcvt.x.f.v sat raises NV"
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x0000f2b7  # lui x5, 0xf
.4byte 0x7ff28293  # addi x5, x5, 2047
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x80128293  # addi x5, x5, -2047
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac11857  # vfcvt.f.xu.v v16, v12
.assert trap == 0 "vfcvt.f.xu.v RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.xu.v RNE l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.xu.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RNE l1 writes x10"
.assert rd_wdata == 0x6800 "vfcvt.f.xu.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RNE l2 writes x10"
.assert rd_wdata == 0x7bc0 "vfcvt.f.xu.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RNE l3 writes x10"
.assert rd_wdata == 0x7800 "vfcvt.f.xu.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.xu.v RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.xu.v RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac19857  # vfcvt.f.x.v v16, v12
.assert trap == 0 "vfcvt.f.x.v RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.x.v RNE l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.x.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RNE l1 writes x10"
.assert rd_wdata == 0x6800 "vfcvt.f.x.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RNE l2 writes x10"
.assert rd_wdata == 0xffffffffffffe800 "vfcvt.f.x.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RNE l3 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vfcvt.f.x.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.x.v RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.x.v RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac11857  # vfcvt.f.xu.v v16, v12
.assert trap == 0 "vfcvt.f.xu.v RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.xu.v RTZ l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.xu.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RTZ l1 writes x10"
.assert rd_wdata == 0x6800 "vfcvt.f.xu.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RTZ l2 writes x10"
.assert rd_wdata == 0x7bbf "vfcvt.f.xu.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RTZ l3 writes x10"
.assert rd_wdata == 0x7800 "vfcvt.f.xu.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.xu.v RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.xu.v RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac19857  # vfcvt.f.x.v v16, v12
.assert trap == 0 "vfcvt.f.x.v RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.x.v RTZ l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.x.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RTZ l1 writes x10"
.assert rd_wdata == 0x6800 "vfcvt.f.x.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RTZ l2 writes x10"
.assert rd_wdata == 0xffffffffffffe800 "vfcvt.f.x.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RTZ l3 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vfcvt.f.x.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.x.v RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.x.v RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac11857  # vfcvt.f.xu.v v16, v12
.assert trap == 0 "vfcvt.f.xu.v RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.xu.v RDN l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.xu.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RDN l1 writes x10"
.assert rd_wdata == 0x6800 "vfcvt.f.xu.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RDN l2 writes x10"
.assert rd_wdata == 0x7bbf "vfcvt.f.xu.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RDN l3 writes x10"
.assert rd_wdata == 0x7800 "vfcvt.f.xu.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.xu.v RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.xu.v RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac19857  # vfcvt.f.x.v v16, v12
.assert trap == 0 "vfcvt.f.x.v RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.x.v RDN l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.x.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RDN l1 writes x10"
.assert rd_wdata == 0x6800 "vfcvt.f.x.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RDN l2 writes x10"
.assert rd_wdata == 0xffffffffffffe801 "vfcvt.f.x.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RDN l3 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vfcvt.f.x.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.x.v RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.x.v RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac11857  # vfcvt.f.xu.v v16, v12
.assert trap == 0 "vfcvt.f.xu.v RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.xu.v RUP l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.xu.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RUP l1 writes x10"
.assert rd_wdata == 0x6801 "vfcvt.f.xu.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RUP l2 writes x10"
.assert rd_wdata == 0x7bc0 "vfcvt.f.xu.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RUP l3 writes x10"
.assert rd_wdata == 0x7800 "vfcvt.f.xu.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.xu.v RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.xu.v RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac19857  # vfcvt.f.x.v v16, v12
.assert trap == 0 "vfcvt.f.x.v RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.x.v RUP l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.x.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RUP l1 writes x10"
.assert rd_wdata == 0x6801 "vfcvt.f.x.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RUP l2 writes x10"
.assert rd_wdata == 0xffffffffffffe800 "vfcvt.f.x.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RUP l3 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vfcvt.f.x.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.x.v RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.x.v RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac11857  # vfcvt.f.xu.v v16, v12
.assert trap == 0 "vfcvt.f.xu.v RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.xu.v RMM l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.xu.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RMM l1 writes x10"
.assert rd_wdata == 0x6801 "vfcvt.f.xu.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RMM l2 writes x10"
.assert rd_wdata == 0x7bc0 "vfcvt.f.xu.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.xu.v RMM l3 writes x10"
.assert rd_wdata == 0x7800 "vfcvt.f.xu.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.xu.v RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.xu.v RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac19857  # vfcvt.f.x.v v16, v12
.assert trap == 0 "vfcvt.f.x.v RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfcvt.f.x.v RMM l0 writes x10"
.assert rd_wdata == 0x0 "vfcvt.f.x.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RMM l1 writes x10"
.assert rd_wdata == 0x6801 "vfcvt.f.x.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RMM l2 writes x10"
.assert rd_wdata == 0xffffffffffffe801 "vfcvt.f.x.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfcvt.f.x.v RMM l3 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vfcvt.f.x.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfcvt.f.x.v RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfcvt.f.x.v RMM fflags"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"

# Section 3: 4 vfwcvt FP16->int32 and 2 vfncvt int32->FP16 across all 5 frm modes.
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xbff28293  # addi x5, x5, -1025
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac41857  # vfwcvt.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.xu.f.v RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.xu.f.v RNE l0 writes x10"
.assert rd_wdata == 0x2 "vfwcvt.xu.f.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RNE l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.xu.f.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RNE l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.xu.f.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RNE l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.xu.f.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.xu.f.v RNE fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.xu.f.v RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac49857  # vfwcvt.x.f.v v16, v12
.assert trap == 0 "vfwcvt.x.f.v RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.x.f.v RNE l0 writes x10"
.assert rd_wdata == 0x2 "vfwcvt.x.f.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RNE l1 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfwcvt.x.f.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RNE l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.x.f.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RNE l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.x.f.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.x.f.v RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.x.f.v RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac71857  # vfwcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.xu.f.v RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RNE l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.xu.f.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RNE l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RNE l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RNE l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.xu.f.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.xu.f.v RNE fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.rtz.xu.f.v RNE fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac79857  # vfwcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.x.f.v RNE retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RNE l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfwcvt.rtz.x.f.v RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RNE l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.x.f.v RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RNE l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.x.f.v RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.x.f.v RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac41857  # vfwcvt.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.xu.f.v RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.xu.f.v RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.xu.f.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RTZ l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.xu.f.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RTZ l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.xu.f.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RTZ l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.xu.f.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.xu.f.v RTZ fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.xu.f.v RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac49857  # vfwcvt.x.f.v v16, v12
.assert trap == 0 "vfwcvt.x.f.v RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.x.f.v RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.x.f.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfwcvt.x.f.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RTZ l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.x.f.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RTZ l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.x.f.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.x.f.v RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.x.f.v RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac71857  # vfwcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.xu.f.v RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.xu.f.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RTZ l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RTZ l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RTZ l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.xu.f.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.xu.f.v RTZ fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.rtz.xu.f.v RTZ fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac79857  # vfwcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.x.f.v RTZ retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfwcvt.rtz.x.f.v RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RTZ l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.x.f.v RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RTZ l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.x.f.v RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.x.f.v RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac41857  # vfwcvt.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.xu.f.v RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.xu.f.v RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.xu.f.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RDN l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.xu.f.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RDN l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.xu.f.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RDN l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.xu.f.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.xu.f.v RDN fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.xu.f.v RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac49857  # vfwcvt.x.f.v v16, v12
.assert trap == 0 "vfwcvt.x.f.v RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.x.f.v RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.x.f.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RDN l1 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfwcvt.x.f.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RDN l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.x.f.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RDN l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.x.f.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.x.f.v RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.x.f.v RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac71857  # vfwcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.xu.f.v RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.xu.f.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RDN l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RDN l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RDN l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.xu.f.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.xu.f.v RDN fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.rtz.xu.f.v RDN fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac79857  # vfwcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.x.f.v RDN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfwcvt.rtz.x.f.v RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RDN l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.x.f.v RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RDN l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.x.f.v RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.x.f.v RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac41857  # vfwcvt.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.xu.f.v RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.xu.f.v RUP l0 writes x10"
.assert rd_wdata == 0x2 "vfwcvt.xu.f.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RUP l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.xu.f.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RUP l2 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.xu.f.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RUP l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.xu.f.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.xu.f.v RUP fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.xu.f.v RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac49857  # vfwcvt.x.f.v v16, v12
.assert trap == 0 "vfwcvt.x.f.v RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.x.f.v RUP l0 writes x10"
.assert rd_wdata == 0x2 "vfwcvt.x.f.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfwcvt.x.f.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RUP l2 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.x.f.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RUP l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.x.f.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.x.f.v RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.x.f.v RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac71857  # vfwcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.xu.f.v RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RUP l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.xu.f.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RUP l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RUP l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RUP l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.xu.f.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.xu.f.v RUP fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.rtz.xu.f.v RUP fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac79857  # vfwcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.x.f.v RUP retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RUP l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfwcvt.rtz.x.f.v RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RUP l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.x.f.v RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RUP l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.x.f.v RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.x.f.v RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac41857  # vfwcvt.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.xu.f.v RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.xu.f.v RMM l0 writes x10"
.assert rd_wdata == 0x2 "vfwcvt.xu.f.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RMM l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.xu.f.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RMM l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.xu.f.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.xu.f.v RMM l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.xu.f.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.xu.f.v RMM fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.xu.f.v RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac49857  # vfwcvt.x.f.v v16, v12
.assert trap == 0 "vfwcvt.x.f.v RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.x.f.v RMM l0 writes x10"
.assert rd_wdata == 0x2 "vfwcvt.x.f.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RMM l1 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfwcvt.x.f.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RMM l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.x.f.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.x.f.v RMM l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.x.f.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.x.f.v RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.x.f.v RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac71857  # vfwcvt.rtz.xu.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.xu.f.v RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RMM l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.xu.f.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RMM l1 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RMM l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.xu.f.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.xu.f.v RMM l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.xu.f.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.xu.f.v RMM fflags writes x11"
.assert rd_wdata == 0x11 "vfwcvt.rtz.xu.f.v RMM fflags"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac79857  # vfwcvt.rtz.x.f.v v16, v12
.assert trap == 0 "vfwcvt.rtz.x.f.v RMM retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RMM l0 writes x10"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfwcvt.rtz.x.f.v RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RMM l2 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.rtz.x.f.v RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.rtz.x.f.v RMM l3 writes x10"
.assert rd_wdata == 0xffe0 "vfwcvt.rtz.x.f.v RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.rtz.x.f.v RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfwcvt.rtz.x.f.v RMM fflags"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0xffff02b7  # lui x5, 0xffff0
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xfffff2b7  # lui x5, 0xfffff
.4byte 0x7ff28293  # addi x5, x5, 2047
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000012b7  # lui x5, 0x1
.4byte 0x80128293  # addi x5, x5, -2047
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac91857  # vfncvt.f.xu.w v16, v12
.assert trap == 0 "vfncvt.f.xu.w RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.xu.w RNE l0 writes x10"
.assert rd_wdata == 0x6800 "vfncvt.f.xu.w RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RNE l1 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.xu.w RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RNE l2 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.xu.w RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RNE l3 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.xu.w RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.xu.w RNE fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.xu.w RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac99857  # vfncvt.f.x.w v16, v12
.assert trap == 0 "vfncvt.f.x.w RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.x.w RNE l0 writes x10"
.assert rd_wdata == 0x6800 "vfncvt.f.x.w RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffe800 "vfncvt.f.x.w RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RNE l2 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.x.w RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RNE l3 writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfncvt.f.x.w RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.x.w RNE fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.x.w RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac91857  # vfncvt.f.xu.w v16, v12
.assert trap == 0 "vfncvt.f.xu.w RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.xu.w RTZ l0 writes x10"
.assert rd_wdata == 0x6800 "vfncvt.f.xu.w RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RTZ l1 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.xu.w RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RTZ l2 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.xu.w RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RTZ l3 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.xu.w RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.xu.w RTZ fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.xu.w RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac99857  # vfncvt.f.x.w v16, v12
.assert trap == 0 "vfncvt.f.x.w RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.x.w RTZ l0 writes x10"
.assert rd_wdata == 0x6800 "vfncvt.f.x.w RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffe800 "vfncvt.f.x.w RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RTZ l2 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.x.w RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RTZ l3 writes x10"
.assert rd_wdata == 0xfffffffffffffbff "vfncvt.f.x.w RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.x.w RTZ fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.x.w RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac91857  # vfncvt.f.xu.w v16, v12
.assert trap == 0 "vfncvt.f.xu.w RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.xu.w RDN l0 writes x10"
.assert rd_wdata == 0x6800 "vfncvt.f.xu.w RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RDN l1 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.xu.w RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RDN l2 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.xu.w RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RDN l3 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.xu.w RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.xu.w RDN fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.xu.w RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac99857  # vfncvt.f.x.w v16, v12
.assert trap == 0 "vfncvt.f.x.w RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.x.w RDN l0 writes x10"
.assert rd_wdata == 0x6800 "vfncvt.f.x.w RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffe801 "vfncvt.f.x.w RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RDN l2 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.x.w RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RDN l3 writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfncvt.f.x.w RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.x.w RDN fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.x.w RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac91857  # vfncvt.f.xu.w v16, v12
.assert trap == 0 "vfncvt.f.xu.w RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.xu.w RUP l0 writes x10"
.assert rd_wdata == 0x6801 "vfncvt.f.xu.w RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RUP l1 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.xu.w RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RUP l2 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.xu.w RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RUP l3 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.xu.w RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.xu.w RUP fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.xu.w RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac99857  # vfncvt.f.x.w v16, v12
.assert trap == 0 "vfncvt.f.x.w RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.x.w RUP l0 writes x10"
.assert rd_wdata == 0x6801 "vfncvt.f.x.w RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffe800 "vfncvt.f.x.w RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RUP l2 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.x.w RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RUP l3 writes x10"
.assert rd_wdata == 0xfffffffffffffbff "vfncvt.f.x.w RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.x.w RUP fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.x.w RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac91857  # vfncvt.f.xu.w v16, v12
.assert trap == 0 "vfncvt.f.xu.w RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.xu.w RMM l0 writes x10"
.assert rd_wdata == 0x6801 "vfncvt.f.xu.w RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RMM l1 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.xu.w RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RMM l2 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.xu.w RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.xu.w RMM l3 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.xu.w RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.xu.w RMM fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.xu.w RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac99857  # vfncvt.f.x.w v16, v12
.assert trap == 0 "vfncvt.f.x.w RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.x.w RMM l0 writes x10"
.assert rd_wdata == 0x6801 "vfncvt.f.x.w RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffe801 "vfncvt.f.x.w RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RMM l2 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.x.w RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.x.w RMM l3 writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfncvt.f.x.w RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.x.w RMM fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.x.w RMM fflags"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"

# Section 4: All 6 Zvfh SEW=8 int8 <-> FP16 conversions across all 5 frm modes + saturation.
.4byte 0xc002f657  # vsetivli x12, 5, e8, m1, tu, mu
.4byte 0x0ff00293  # addi x5, x0, 255
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x08000293  # addi x5, x0, 128
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x07f00293  # addi x5, x0, 127
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc002f657  # vsetivli x12, 5, e8, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac51857  # vfwcvt.f.xu.v v16, v12
.assert trap == 0 "vfwcvt.f.xu.v e8 retires"
.4byte 0xc092f657  # vsetivli x12, 5, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.f.xu.v e8 l0 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.f.xu.v e8 l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.xu.v e8 l1 writes x10"
.assert rd_wdata == 0x3c00 "vfwcvt.f.xu.v e8 l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.xu.v e8 l2 writes x10"
.assert rd_wdata == 0x57f0 "vfwcvt.f.xu.v e8 l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.xu.v e8 l3 writes x10"
.assert rd_wdata == 0x5800 "vfwcvt.f.xu.v e8 l3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.xu.v e8 l4 writes x10"
.assert rd_wdata == 0x5bf8 "vfwcvt.f.xu.v e8 l4"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.f.xu.v e8 exact fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfwcvt.f.xu.v e8 exact fflags==0"
.4byte 0xc002f657  # vsetivli x12, 5, e8, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac59857  # vfwcvt.f.x.v v16, v12
.assert trap == 0 "vfwcvt.f.x.v e8 retires"
.4byte 0xc092f657  # vsetivli x12, 5, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.f.x.v e8 l0 writes x10"
.assert rd_wdata == 0x0 "vfwcvt.f.x.v e8 l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.x.v e8 l1 writes x10"
.assert rd_wdata == 0x3c00 "vfwcvt.f.x.v e8 l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.x.v e8 l2 writes x10"
.assert rd_wdata == 0x57f0 "vfwcvt.f.x.v e8 l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.x.v e8 l3 writes x10"
.assert rd_wdata == 0xffffffffffffd800 "vfwcvt.f.x.v e8 l3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.x.v e8 l4 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfwcvt.f.x.v e8 l4"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.f.x.v e8 exact fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfwcvt.f.x.v e8 exact fflags==0"
.4byte 0xc0927657  # vsetivli x12, 4, e16, m2, tu, mu
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac81857  # vfncvt.xu.f.w v16, v12
.assert trap == 0 "vfncvt.xu.f.w e8 RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RNE l0 writes x10"
.assert rd_wdata == 0x2 "vfncvt.xu.f.w e8 RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RNE l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RNE l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.xu.f.w e8 RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RNE l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.xu.f.w e8 RNE fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.xu.f.w e8 RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac89857  # vfncvt.x.f.w v16, v12
.assert trap == 0 "vfncvt.x.f.w e8 RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.x.f.w e8 RNE l0 writes x10"
.assert rd_wdata == 0x2 "vfncvt.x.f.w e8 RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RNE l1 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.x.f.w e8 RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RNE l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.x.f.w e8 RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RNE l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.x.f.w e8 RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.x.f.w e8 RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.x.f.w e8 RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb1857  # vfncvt.rtz.xu.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.xu.f.w e8 RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RNE l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.xu.f.w e8 RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RNE l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RNE l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.xu.f.w e8 RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RNE l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.xu.f.w e8 RNE fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.rtz.xu.f.w e8 RNE fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb9857  # vfncvt.rtz.x.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.x.f.w e8 RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RNE l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RNE l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RNE l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.rtz.x.f.w e8 RNE l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RNE l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.x.f.w e8 RNE l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RNE l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.rtz.x.f.w e8 RNE l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.x.f.w e8 RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac81857  # vfncvt.xu.f.w v16, v12
.assert trap == 0 "vfncvt.xu.f.w e8 RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.xu.f.w e8 RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RTZ l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RTZ l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.xu.f.w e8 RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RTZ l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.xu.f.w e8 RTZ fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.xu.f.w e8 RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac89857  # vfncvt.x.f.w v16, v12
.assert trap == 0 "vfncvt.x.f.w e8 RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.x.f.w e8 RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.x.f.w e8 RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.x.f.w e8 RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RTZ l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.x.f.w e8 RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RTZ l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.x.f.w e8 RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.x.f.w e8 RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.x.f.w e8 RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb1857  # vfncvt.rtz.xu.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.xu.f.w e8 RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.xu.f.w e8 RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RTZ l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RTZ l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.xu.f.w e8 RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RTZ l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.xu.f.w e8 RTZ fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.rtz.xu.f.w e8 RTZ fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb9857  # vfncvt.rtz.x.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.x.f.w e8 RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RTZ l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RTZ l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RTZ l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.rtz.x.f.w e8 RTZ l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RTZ l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.x.f.w e8 RTZ l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RTZ l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.rtz.x.f.w e8 RTZ l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.x.f.w e8 RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac81857  # vfncvt.xu.f.w v16, v12
.assert trap == 0 "vfncvt.xu.f.w e8 RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.xu.f.w e8 RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RDN l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RDN l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.xu.f.w e8 RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RDN l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.xu.f.w e8 RDN fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.xu.f.w e8 RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac89857  # vfncvt.x.f.w v16, v12
.assert trap == 0 "vfncvt.x.f.w e8 RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.x.f.w e8 RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.x.f.w e8 RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RDN l1 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.x.f.w e8 RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RDN l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.x.f.w e8 RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RDN l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffd "vfncvt.x.f.w e8 RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.x.f.w e8 RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.x.f.w e8 RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb1857  # vfncvt.rtz.xu.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.xu.f.w e8 RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.xu.f.w e8 RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RDN l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RDN l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.xu.f.w e8 RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RDN l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.xu.f.w e8 RDN fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.rtz.xu.f.w e8 RDN fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb9857  # vfncvt.rtz.x.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.x.f.w e8 RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RDN l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RDN l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RDN l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.rtz.x.f.w e8 RDN l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RDN l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.x.f.w e8 RDN l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RDN l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.rtz.x.f.w e8 RDN l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.x.f.w e8 RDN fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac81857  # vfncvt.xu.f.w v16, v12
.assert trap == 0 "vfncvt.xu.f.w e8 RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RUP l0 writes x10"
.assert rd_wdata == 0x2 "vfncvt.xu.f.w e8 RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RUP l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RUP l2 writes x10"
.assert rd_wdata == 0x3 "vfncvt.xu.f.w e8 RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RUP l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.xu.f.w e8 RUP fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.xu.f.w e8 RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac89857  # vfncvt.x.f.w v16, v12
.assert trap == 0 "vfncvt.x.f.w e8 RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.x.f.w e8 RUP l0 writes x10"
.assert rd_wdata == 0x2 "vfncvt.x.f.w e8 RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.x.f.w e8 RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RUP l2 writes x10"
.assert rd_wdata == 0x3 "vfncvt.x.f.w e8 RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RUP l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.x.f.w e8 RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.x.f.w e8 RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.x.f.w e8 RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb1857  # vfncvt.rtz.xu.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.xu.f.w e8 RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RUP l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.xu.f.w e8 RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RUP l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RUP l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.xu.f.w e8 RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RUP l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.xu.f.w e8 RUP fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.rtz.xu.f.w e8 RUP fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb9857  # vfncvt.rtz.x.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.x.f.w e8 RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RUP l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RUP l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RUP l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.rtz.x.f.w e8 RUP l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RUP l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.x.f.w e8 RUP l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RUP l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.rtz.x.f.w e8 RUP l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.x.f.w e8 RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac81857  # vfncvt.xu.f.w v16, v12
.assert trap == 0 "vfncvt.xu.f.w e8 RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RMM l0 writes x10"
.assert rd_wdata == 0x2 "vfncvt.xu.f.w e8 RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RMM l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RMM l2 writes x10"
.assert rd_wdata == 0x3 "vfncvt.xu.f.w e8 RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 RMM l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.xu.f.w e8 RMM fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.xu.f.w e8 RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac89857  # vfncvt.x.f.w v16, v12
.assert trap == 0 "vfncvt.x.f.w e8 RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.x.f.w e8 RMM l0 writes x10"
.assert rd_wdata == 0x2 "vfncvt.x.f.w e8 RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RMM l1 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.x.f.w e8 RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RMM l2 writes x10"
.assert rd_wdata == 0x3 "vfncvt.x.f.w e8 RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 RMM l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffd "vfncvt.x.f.w e8 RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.x.f.w e8 RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.x.f.w e8 RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb1857  # vfncvt.rtz.xu.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.xu.f.w e8 RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RMM l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.xu.f.w e8 RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RMM l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RMM l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.xu.f.w e8 RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.xu.f.w e8 RMM l3 writes x10"
.assert rd_wdata == 0x0 "vfncvt.rtz.xu.f.w e8 RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.xu.f.w e8 RMM fflags writes x11"
.assert rd_wdata == 0x11 "vfncvt.rtz.xu.f.w e8 RMM fflags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4acb9857  # vfncvt.rtz.x.f.w v16, v12
.assert trap == 0 "vfncvt.rtz.x.f.w e8 RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RMM l0 writes x10"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RMM l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RMM l1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.rtz.x.f.w e8 RMM l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RMM l2 writes x10"
.assert rd_wdata == 0x2 "vfncvt.rtz.x.f.w e8 RMM l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.rtz.x.f.w e8 RMM l3 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vfncvt.rtz.x.f.w e8 RMM l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.rtz.x.f.w e8 RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.rtz.x.f.w e8 RMM fflags"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0xc0927657  # vsetivli x12, 4, e16, m2, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0000e2b7  # lui x5, 0xe
.4byte 0xc8028293  # addi x5, x5, -896
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xcb028293  # addi x5, x5, -848
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac81857  # vfncvt.xu.f.w v16, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.xu.f.w e8 sat l0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.xu.f.w e8 sat l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 sat l1 writes x10"
.assert rd_wdata == 0x0 "vfncvt.xu.f.w e8 sat l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 sat l2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.xu.f.w e8 sat l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.xu.f.w e8 sat l3 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vfncvt.xu.f.w e8 sat l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.xu.f.w e8 sat raises NV writes x11"
.assert rd_wdata == 0x10 "vfncvt.xu.f.w e8 sat raises NV"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac89857  # vfncvt.x.f.w v16, v12
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.x.f.w e8 sat l0 writes x10"
.assert rd_wdata == 0x7f "vfncvt.x.f.w e8 sat l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 sat l1 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vfncvt.x.f.w e8 sat l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 sat l2 writes x10"
.assert rd_wdata == 0x7f "vfncvt.x.f.w e8 sat l2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.x.f.w e8 sat l3 writes x10"
.assert rd_wdata == 0x7f "vfncvt.x.f.w e8 sat l3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.x.f.w e8 sat raises NV writes x11"
.assert rd_wdata == 0x10 "vfncvt.x.f.w e8 sat raises NV"
# Section 5: Masks, tails, vl=0, VLMAX, legal overlaps, and illegal e8/e16 conversion traps.
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x00500293  # addi x5, x0, 5
.4byte 0x5e02c057  # vmv.v.x v0, x5
.4byte 0x00007fd7  # vsetvli x31, x0, e8, m1, tu, mu
.4byte 0x05a00293  # addi x5, x0, 90
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xc0927657  # vsetivli x12, 4, e16, m2, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x48c89857  # vfncvt.x.f.w v16, v12, v0.t
.4byte 0xc002f657  # vsetivli x12, 5, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "masked vfncvt.x.f.w e8 active l0 writes x10"
.assert rd_wdata == 0x2 "masked vfncvt.x.f.w e8 active l0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vfncvt.x.f.w e8 mu l1 writes x10"
.assert rd_wdata == 0x5a "masked vfncvt.x.f.w e8 mu l1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vfncvt.x.f.w e8 active l2 writes x10"
.assert rd_wdata == 0x3 "masked vfncvt.x.f.w e8 active l2"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vfncvt.x.f.w e8 tu tail l4 writes x10"
.assert rd_wdata == 0x5a "masked vfncvt.x.f.w e8 tu tail l4"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "masked vfncvt.x.f.w e8 suppresses inactive sNaN NV writes x11"
.assert rd_wdata == 0x0 "masked vfncvt.x.f.w e8 suppresses inactive sNaN NV"
.4byte 0xcc007657  # vsetivli x12, 0, e8, m1, ta, ma
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ac89857  # vfncvt.x.f.w v16, v12
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.x.f.w e8 vl=0 fflags==0 writes x11"
.assert rd_wdata == 0x0 "vfncvt.x.f.w e8 vl=0 fflags==0"
.4byte 0x00507fd7  # vsetvli x31, x0, e8, mf8, tu, mu
.4byte 0x4b859857  # vfwcvt.f.x.v v16, v24
.assert trap == 0 "vfwcvt.f.x.v VLMAX e8 mf8 retires"
.4byte 0x00607fd7  # vsetvli x31, x0, e8, mf4, tu, mu
.4byte 0x4b859857  # vfwcvt.f.x.v v16, v24
.assert trap == 0 "vfwcvt.f.x.v VLMAX e8 mf4 retires"
.4byte 0x00707fd7  # vsetvli x31, x0, e8, mf2, tu, mu
.4byte 0x4b859857  # vfwcvt.f.x.v v16, v24
.assert trap == 0 "vfwcvt.f.x.v VLMAX e8 mf2 retires"
.4byte 0x00007fd7  # vsetvli x31, x0, e8, m1, tu, mu
.4byte 0x4b859857  # vfwcvt.f.x.v v16, v24
.assert trap == 0 "vfwcvt.f.x.v VLMAX e8 m1 retires"
.4byte 0x00107fd7  # vsetvli x31, x0, e8, m2, tu, mu
.4byte 0x4b859857  # vfwcvt.f.x.v v16, v24
.assert trap == 0 "vfwcvt.f.x.v VLMAX e8 m2 retires"
.4byte 0x00207fd7  # vsetvli x31, x0, e8, m4, tu, mu
.4byte 0x4b859857  # vfwcvt.f.x.v v16, v24
.assert trap == 0 "vfwcvt.f.x.v VLMAX e8 m4 retires"
.4byte 0x00e07fd7  # vsetvli x31, x0, e16, mf4, tu, mu
.4byte 0x4b819857  # vfcvt.f.x.v v16, v24
.assert trap == 0 "vfcvt.f.x.v VLMAX e16 mf4 retires"
.4byte 0x00f07fd7  # vsetvli x31, x0, e16, mf2, tu, mu
.4byte 0x4b819857  # vfcvt.f.x.v v16, v24
.assert trap == 0 "vfcvt.f.x.v VLMAX e16 mf2 retires"
.4byte 0x00807fd7  # vsetvli x31, x0, e16, m1, tu, mu
.4byte 0x4b819857  # vfcvt.f.x.v v16, v24
.assert trap == 0 "vfcvt.f.x.v VLMAX e16 m1 retires"
.4byte 0x00907fd7  # vsetvli x31, x0, e16, m2, tu, mu
.4byte 0x4b819857  # vfcvt.f.x.v v16, v24
.assert trap == 0 "vfcvt.f.x.v VLMAX e16 m2 retires"
.4byte 0x00a07fd7  # vsetvli x31, x0, e16, m4, tu, mu
.4byte 0x4b819857  # vfcvt.f.x.v v16, v24
.assert trap == 0 "vfcvt.f.x.v VLMAX e16 m4 retires"
.4byte 0xc0017657  # vsetivli x12, 2, e8, m1, tu, mu
.4byte 0x4ac89657  # vfncvt.x.f.w v12, v12
.assert trap == 0 "legal lowest-reg overlap vfncvt.x.f.w e8 retires"
.4byte 0x4b159857  # vfwcvt.f.x.v v16, v17
.assert trap == 0 "legal upper-half overlap vfwcvt.f.x.v e8 retires"
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0x4ac61857  # vfwcvt.f.f.v v16, v12
.assert trap == 1 "vfwcvt.f.f.v at e8 traps"
.4byte 0x4aca1857  # vfncvt.f.f.w v16, v12
.assert trap == 1 "vfncvt.f.f.w at e8 traps"
.4byte 0x4aca9857  # vfncvt.rod.f.f.w v16, v12
.assert trap == 1 "vfncvt.rod.f.f.w at e8 traps"
.4byte 0x4ac09857  # vfcvt.x.f.v v16, v12
.assert trap == 1 "vfcvt.x.f.v at e8 traps"
.4byte 0x4ac19857  # vfcvt.f.x.v v16, v12
.assert trap == 1 "vfcvt.f.x.v at e8 traps"
.4byte 0x4ac49857  # vfwcvt.x.f.v v16, v12
.assert trap == 1 "vfwcvt.x.f.v at e8 traps"
.4byte 0x4ac99857  # vfncvt.f.x.w v16, v12
.assert trap == 1 "vfncvt.f.x.w at e8 traps"
.4byte 0xc0327657  # vsetivli x12, 4, e8, m8, tu, mu
.4byte 0x4b859857  # vfwcvt.f.x.v v16, v24
.assert trap == 1 "vfwcvt.f.x.v e8 m8 traps"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x4aca96d7  # vfncvt.rod.f.f.w v13, v12
.assert trap == 1 "vfncvt.rod.f.f.w upper-reg overlap traps"
.4byte 0x48c09057  # vfcvt.x.f.v v0, v12, v0.t
.assert trap == 1 "masked vfcvt.x.f.v vd==v0 traps"
.4byte 0x0023d073  # csrwi frm, 7
.4byte 0x4ac09857  # vfcvt.x.f.v v16, v12
.assert trap == 1 "vfcvt.x.f.v reserved frm=7 traps"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0xc2027657  # vsetivli reserved_sew4 (sets vill)
.4byte 0x4ac09857  # vfcvt.x.f.v v16, v12
.assert trap == 1 "vfcvt.x.f.v under vill traps"
