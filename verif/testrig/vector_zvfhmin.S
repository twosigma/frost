# Vector Zvfhmin (FP16<->FP32 conversions) and base-V SEW=16 int16<->FP32 conversions.
# Contains zero Zvfh-only FP16 arithmetic instructions; runs with Zvfh disabled in Sail.
.noshrink
# Preamble: enable FS and VS, clear fcsr, and zero v0..v31.
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0x60028293  # addi x5, x5, 1536
.4byte 0x3002a073  # csrs mstatus, x5
.4byte 0x00305073  # csrwi fcsr, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "initial frm is RNE writes x10"
.assert rd_wdata == 0x0 "initial frm is RNE"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "initial fflags clear writes x11"
.assert rd_wdata == 0x0 "initial fflags clear"
.4byte 0x01b07fd7  # vsetvli x31, x0, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0

# Section 1: Zvfhmin vfwcvt.f.f.v (FP16 -> FP32) control on v1, subnormals, inf, qNaN/sNaN.
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.assert rd_addr == 12 "vsetivli e32 m2 vl=4 writes x12"
.assert rd_wdata == 0x4 "vsetivli e32 m2 vl=4"
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc01002b7  # lui x5, 0xc0100
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3fc002b7  # lui x5, 0x3fc00
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00807fd7  # vsetvli x31, x0, e16, m1, tu, mu
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0xa5a28293  # addi x5, x5, -1446
.4byte 0x5e02c0d7  # vmv.v.x v1, x5
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.assert rd_addr == 12 "vsetivli e16 m1 vl=4 writes x12"
.assert rd_wdata == 0x4 "vsetivli e16 m1 vl=4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a10d7  # vfncvt.f.f.w v1, v8
.assert trap == 0 "control vfncvt.f.f.w retires"
.4byte 0x42102557  # vmv.x.s x10, v1
.assert rd_addr == 10 "control vfncvt.f.f.w 1.5f -> 1.5h writes x10"
.assert rd_wdata == 0x3e00 "control vfncvt.f.f.w 1.5f -> 1.5h"
.4byte 0x3e10bc57  # vslidedown.vi v24, v1, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vfncvt.f.f.w -2.25f -> -2.25h writes x10"
.assert rd_wdata == 0xffffffffffffc080 "control vfncvt.f.f.w -2.25f -> -2.25h"
.4byte 0x3e113c57  # vslidedown.vi v24, v1, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vfncvt.f.f.w +0.0f -> +0.0h writes x10"
.assert rd_wdata == 0x0 "control vfncvt.f.f.w +0.0f -> +0.0h"
.4byte 0x3e11bc57  # vslidedown.vi v24, v1, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vfncvt.f.f.w -0.0f -> -0.0h writes x10"
.assert rd_wdata == 0xffffffffffff8000 "control vfncvt.f.f.w -0.0f -> -0.0h"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "exact control vfncvt.f.f.w clears fflags writes x11"
.assert rd_wdata == 0x0 "exact control vfncvt.f.f.w clears fflags"
.4byte 0xc082f657  # vsetivli x12, 5, e16, m1, tu, mu
.assert rd_addr == 12 "vsetivli e16 m1 vl=5 writes x12"
.assert rd_wdata == 0x5 "vsetivli e16 m1 vl=5"
.4byte 0x3e123c57  # vslidedown.vi v24, v1, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control v1 tail lane 4 undisturbed under tu writes x10"
.assert rd_wdata == 0x5a5a "control v1 tail lane 4 undisturbed under tu"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a161857  # vfwcvt.f.f.v v16, v1
.assert trap == 0 "vfwcvt.f.f.v normals/zeros retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.f.f.v 1.5h -> 1.5f writes x10"
.assert rd_wdata == 0x3fc00000 "vfwcvt.f.f.v 1.5h -> 1.5f"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v -2.25h -> -2.25f writes x10"
.assert rd_wdata == 0xffffffffc0100000 "vfwcvt.f.f.v -2.25h -> -2.25f"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v +0.0h -> +0.0f writes x10"
.assert rd_wdata == 0x0 "vfwcvt.f.f.v +0.0h -> +0.0f"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v -0.0h -> -0.0f writes x10"
.assert rd_wdata == 0xffffffff80000000 "vfwcvt.f.f.v -0.0h -> -0.0f"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.f.f.v normals/zeros clears fflags writes x11"
.assert rd_wdata == 0x0 "vfwcvt.f.f.v normals/zeros clears fflags"
.4byte 0x3fc002b7  # lui x5, 0x3fc00
.4byte 0xf0028053  # fmv.w.x f0, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x440070d3  # fcvt.h.s f1, f0
.4byte 0xe2008553  # fmv.x.d x10, f1
.assert rd_addr == 10 "Zfhmin fcvt.h.s NaN-boxes FP16 1.5h in f1 writes x10"
.assert rd_wdata == 0xffffffffffff3e00 "Zfhmin fcvt.h.s NaN-boxes FP16 1.5h in f1"
.4byte 0xe4008553  # fmv.x.h x10, f1
.assert rd_addr == 10 "Zfhmin fmv.x.h reads 1.5h matching vfncvt.f.f.w writes x10"
.assert rd_wdata == 0x3e00 "Zfhmin fmv.x.h reads 1.5h matching vfncvt.f.f.w"
.4byte 0x40208153  # fcvt.s.h f2, f1
.4byte 0xe0010553  # fmv.x.w x10, f2
.assert rd_addr == 10 "Zfhmin fcvt.s.h matches vfwcvt.f.f.v writes x10"
.assert rd_wdata == 0x3fc00000 "Zfhmin fcvt.s.h matches vfwcvt.f.f.v"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "Zfhmin scalar round-trip clears fflags writes x11"
.assert rd_wdata == 0x0 "Zfhmin scalar round-trip clears fflags"
# vfwcvt.f.f.v subnormals (0x0001, 0x03ff, 0x8001) and normal bounds (0x0400, 0x7bff).
.4byte 0xc082f657  # vsetivli x12, 5, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xbff28293  # addi x5, x5, -1025
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x40000293  # addi x5, x0, 1024
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3ff00293  # addi x5, x0, 1023
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "vfwcvt.f.f.v subnormals retires"
.4byte 0xc112f657  # vsetivli x12, 5, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.f.f.v min +subnorm 2^-24 writes x10"
.assert rd_wdata == 0x33800000 "vfwcvt.f.f.v min +subnorm 2^-24"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v max +subnorm writes x10"
.assert rd_wdata == 0x387fc000 "vfwcvt.f.f.v max +subnorm"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v min -subnorm -2^-24 writes x10"
.assert rd_wdata == 0xffffffffb3800000 "vfwcvt.f.f.v min -subnorm -2^-24"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v min +normal 2^-14 writes x10"
.assert rd_wdata == 0x38800000 "vfwcvt.f.f.v min +normal 2^-14"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v max finite 65504.0 writes x10"
.assert rd_wdata == 0x477fe000 "vfwcvt.f.f.v max finite 65504.0"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.f.f.v subnormals/bounds exact (fflags==0) writes x11"
.assert rd_wdata == 0x0 "vfwcvt.f.f.v subnormals/bounds exact (fflags==0)"
# vfwcvt.f.f.v infinities, non-canonical qNaNs (no NV), and sNaNs (NV).
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xf5528293  # addi x5, x5, -171
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xf5528293  # addi x5, x5, -171
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0028293  # addi x5, x5, -1024
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "vfwcvt.f.f.v inf/qNaN retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.f.f.v +inf writes x10"
.assert rd_wdata == 0x7f800000 "vfwcvt.f.f.v +inf"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v -inf writes x10"
.assert rd_wdata == 0xffffffffff800000 "vfwcvt.f.f.v -inf"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v +qNaN canonicalizes writes x10"
.assert rd_wdata == 0x7fc00000 "vfwcvt.f.f.v +qNaN canonicalizes"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v -qNaN canonicalizes writes x10"
.assert rd_wdata == 0x7fc00000 "vfwcvt.f.f.v -qNaN canonicalizes"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.f.f.v inf and qNaN leave fflags clear writes x11"
.assert rd_wdata == 0x0 "vfwcvt.f.f.v inf and qNaN leave fflags clear"
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xdff28293  # addi x5, x5, -513
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "vfwcvt.f.f.v sNaN retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfwcvt.f.f.v +sNaN -> canonical qNaN writes x10"
.assert rd_wdata == 0x7fc00000 "vfwcvt.f.f.v +sNaN -> canonical qNaN"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfwcvt.f.f.v -sNaN -> canonical qNaN writes x10"
.assert rd_wdata == 0x7fc00000 "vfwcvt.f.f.v -sNaN -> canonical qNaN"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfwcvt.f.f.v sNaN raises NV writes x11"
.assert rd_wdata == 0x10 "vfwcvt.f.f.v sNaN raises NV"

# Section 2: Zvfhmin vfncvt.f.f.w (FP32 -> FP16) across all 5 frm modes.
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0xbf8032b7  # lui x5, 0xbf803
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xbf8012b7  # lui x5, 0xbf801
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3f8032b7  # lui x5, 0x3f803
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3f8012b7  # lui x5, 0x3f801
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w ties RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RNE tie lane 0 writes x10"
.assert rd_wdata == 0x3c00 "vfncvt.f.f.w RNE tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RNE tie lane 1 writes x10"
.assert rd_wdata == 0x3c02 "vfncvt.f.f.w RNE tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RNE tie lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfncvt.f.f.w RNE tie lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RNE tie lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfncvt.f.f.w RNE tie lane 3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RNE ties raise NX writes x11"
.assert rd_wdata == 0x1 "vfncvt.f.f.w RNE ties raise NX"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w ties RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RTZ tie lane 0 writes x10"
.assert rd_wdata == 0x3c00 "vfncvt.f.f.w RTZ tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RTZ tie lane 1 writes x10"
.assert rd_wdata == 0x3c01 "vfncvt.f.f.w RTZ tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RTZ tie lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfncvt.f.f.w RTZ tie lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RTZ tie lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfncvt.f.f.w RTZ tie lane 3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RTZ ties raise NX writes x11"
.assert rd_wdata == 0x1 "vfncvt.f.f.w RTZ ties raise NX"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w ties RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RDN tie lane 0 writes x10"
.assert rd_wdata == 0x3c00 "vfncvt.f.f.w RDN tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RDN tie lane 1 writes x10"
.assert rd_wdata == 0x3c01 "vfncvt.f.f.w RDN tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RDN tie lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfncvt.f.f.w RDN tie lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RDN tie lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfncvt.f.f.w RDN tie lane 3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RDN ties raise NX writes x11"
.assert rd_wdata == 0x1 "vfncvt.f.f.w RDN ties raise NX"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w ties RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RUP tie lane 0 writes x10"
.assert rd_wdata == 0x3c01 "vfncvt.f.f.w RUP tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RUP tie lane 1 writes x10"
.assert rd_wdata == 0x3c02 "vfncvt.f.f.w RUP tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RUP tie lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffbc00 "vfncvt.f.f.w RUP tie lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RUP tie lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfncvt.f.f.w RUP tie lane 3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RUP ties raise NX writes x11"
.assert rd_wdata == 0x1 "vfncvt.f.f.w RUP ties raise NX"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w ties RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RMM tie lane 0 writes x10"
.assert rd_wdata == 0x3c01 "vfncvt.f.f.w RMM tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RMM tie lane 1 writes x10"
.assert rd_wdata == 0x3c02 "vfncvt.f.f.w RMM tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RMM tie lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffbc01 "vfncvt.f.f.w RMM tie lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RMM tie lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffbc02 "vfncvt.f.f.w RMM tie lane 3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RMM ties raise NX writes x11"
.assert rd_wdata == 0x1 "vfncvt.f.f.w RMM ties raise NX"
# vfncvt.f.f.w overflow (+/-65536.0 -> OF|NX across all 5 frm modes) and +65520.0 boundary.
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0xc78002b7  # lui x5, 0xc7800
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x478002b7  # lui x5, 0x47800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w overflow RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RNE ovf lane 0 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.f.w RNE ovf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RNE ovf lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfncvt.f.f.w RNE ovf lane 1"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RNE ovf raises OF|NX writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.f.w RNE ovf raises OF|NX"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w overflow RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RTZ ovf lane 0 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.f.w RTZ ovf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RTZ ovf lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffbff "vfncvt.f.f.w RTZ ovf lane 1"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RTZ ovf raises OF|NX writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.f.w RTZ ovf raises OF|NX"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w overflow RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RDN ovf lane 0 writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.f.w RDN ovf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RDN ovf lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfncvt.f.f.w RDN ovf lane 1"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RDN ovf raises OF|NX writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.f.w RDN ovf raises OF|NX"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w overflow RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RUP ovf lane 0 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.f.w RUP ovf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RUP ovf lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffbff "vfncvt.f.f.w RUP ovf lane 1"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RUP ovf raises OF|NX writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.f.w RUP ovf raises OF|NX"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w overflow RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RMM ovf lane 0 writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.f.w RMM ovf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RMM ovf lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfncvt.f.f.w RMM ovf lane 1"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RMM ovf raises OF|NX writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.f.w RMM ovf raises OF|NX"
.4byte 0xc110f657  # vsetivli x12, 1, e32, m2, tu, mu
.4byte 0x477ff2b7  # lui x5, 0x477ff
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xc080f657  # vsetivli x12, 1, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w boundary +65520 RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w +65520 RNE writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.f.w +65520 RNE"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w +65520 RNE fflags writes x11"
.assert rd_wdata == 0x5 "vfncvt.f.f.w +65520 RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w boundary +65520 RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w +65520 RTZ writes x10"
.assert rd_wdata == 0x7bff "vfncvt.f.f.w +65520 RTZ"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w +65520 RTZ fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.f.f.w +65520 RTZ fflags"
# vfncvt.f.f.w exact subnormal, inexact subnormal, tiny underflow, tininess-after-rounding.
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0xb87fc2b7  # lui x5, 0xb87fc
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x338002b7  # lui x5, 0x33800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w exact subnormals retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w exact +2^-24 writes x10"
.assert rd_wdata == 0x1 "vfncvt.f.f.w exact +2^-24"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w exact -max_subnorm writes x10"
.assert rd_wdata == 0xffffffffffff83ff "vfncvt.f.f.w exact -max_subnorm"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w exact subnormals leave fflags clear writes x11"
.assert rd_wdata == 0x0 "vfncvt.f.f.w exact subnormals leave fflags clear"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x308002b7  # lui x5, 0x30800
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x33c002b7  # lui x5, 0x33c00
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w subnorm/tiny RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RNE inexact subnorm writes x10"
.assert rd_wdata == 0x2 "vfncvt.f.f.w RNE inexact subnorm"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RNE tiny underflow writes x10"
.assert rd_wdata == 0x0 "vfncvt.f.f.w RNE tiny underflow"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RNE subnorm/tiny raises UF|NX writes x11"
.assert rd_wdata == 0x3 "vfncvt.f.f.w RNE subnorm/tiny raises UF|NX"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w subnorm/tiny RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RTZ inexact subnorm writes x10"
.assert rd_wdata == 0x1 "vfncvt.f.f.w RTZ inexact subnorm"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RTZ tiny underflow writes x10"
.assert rd_wdata == 0x0 "vfncvt.f.f.w RTZ tiny underflow"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RTZ subnorm/tiny raises UF|NX writes x11"
.assert rd_wdata == 0x3 "vfncvt.f.f.w RTZ subnorm/tiny raises UF|NX"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w subnorm/tiny RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RDN inexact subnorm writes x10"
.assert rd_wdata == 0x1 "vfncvt.f.f.w RDN inexact subnorm"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RDN tiny underflow writes x10"
.assert rd_wdata == 0x0 "vfncvt.f.f.w RDN tiny underflow"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RDN subnorm/tiny raises UF|NX writes x11"
.assert rd_wdata == 0x3 "vfncvt.f.f.w RDN subnorm/tiny raises UF|NX"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w subnorm/tiny RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RUP inexact subnorm writes x10"
.assert rd_wdata == 0x2 "vfncvt.f.f.w RUP inexact subnorm"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RUP tiny underflow writes x10"
.assert rd_wdata == 0x1 "vfncvt.f.f.w RUP tiny underflow"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RUP subnorm/tiny raises UF|NX writes x11"
.assert rd_wdata == 0x3 "vfncvt.f.f.w RUP subnorm/tiny raises UF|NX"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w subnorm/tiny RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w RMM inexact subnorm writes x10"
.assert rd_wdata == 0x2 "vfncvt.f.f.w RMM inexact subnorm"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w RMM tiny underflow writes x10"
.assert rd_wdata == 0x0 "vfncvt.f.f.w RMM tiny underflow"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w RMM subnorm/tiny raises UF|NX writes x11"
.assert rd_wdata == 0x3 "vfncvt.f.f.w RMM subnorm/tiny raises UF|NX"
.4byte 0xc110f657  # vsetivli x12, 1, e32, m2, tu, mu
.4byte 0x388002b7  # lui x5, 0x38800
.4byte 0x80028293  # addi x5, x5, -2048
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xc080f657  # vsetivli x12, 1, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w tininess RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w tininess RNE writes x10"
.assert rd_wdata == 0x400 "vfncvt.f.f.w tininess RNE"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w tininess RNE fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.f.f.w tininess RNE fflags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 1 writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w tininess RTZ retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w tininess RTZ writes x10"
.assert rd_wdata == 0x3ff "vfncvt.f.f.w tininess RTZ"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w tininess RTZ fflags writes x11"
.assert rd_wdata == 0x3 "vfncvt.f.f.w tininess RTZ fflags"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 2 writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w tininess RDN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w tininess RDN writes x10"
.assert rd_wdata == 0x3ff "vfncvt.f.f.w tininess RDN"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w tininess RDN fflags writes x11"
.assert rd_wdata == 0x3 "vfncvt.f.f.w tininess RDN fflags"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w tininess RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w tininess RUP writes x10"
.assert rd_wdata == 0x400 "vfncvt.f.f.w tininess RUP"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w tininess RUP fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.f.f.w tininess RUP fflags"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 4 writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w tininess RMM retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w tininess RMM writes x10"
.assert rd_wdata == 0x400 "vfncvt.f.f.w tininess RMM"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w tininess RMM fflags writes x11"
.assert rd_wdata == 0x1 "vfncvt.f.f.w tininess RMM fflags"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0xffc542b7  # lui x5, 0xffc54
.4byte 0x32128293  # addi x5, x5, 801
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x7fc122b7  # lui x5, 0x7fc12
.4byte 0x34528293  # addi x5, x5, 837
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xff8002b7  # lui x5, 0xff800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x7f8002b7  # lui x5, 0x7f800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w inf/qNaN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w +inf writes x10"
.assert rd_wdata == 0x7c00 "vfncvt.f.f.w +inf"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w -inf writes x10"
.assert rd_wdata == 0xfffffffffffffc00 "vfncvt.f.f.w -inf"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w +qNaN canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfncvt.f.f.w +qNaN canonical 0x7e00"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w -qNaN canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfncvt.f.f.w -qNaN canonical 0x7e00"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w inf/qNaN clears fflags writes x11"
.assert rd_wdata == 0x0 "vfncvt.f.f.w inf/qNaN clears fflags"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0xff8002b7  # lui x5, 0xff800
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x7f8002b7  # lui x5, 0x7f800
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w sNaN retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vfncvt.f.f.w +sNaN -> canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfncvt.f.f.w +sNaN -> canonical 0x7e00"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vfncvt.f.f.w -sNaN -> canonical 0x7e00 writes x10"
.assert rd_wdata == 0x7e00 "vfncvt.f.f.w -sNaN -> canonical 0x7e00"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vfncvt.f.f.w sNaN raises NV writes x11"
.assert rd_wdata == 0x10 "vfncvt.f.f.w sNaN raises NV"

# Section 3: Base-V SEW=16 int16 <-> FP32 conversions (all 6 forms).
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x000102b7  # lui x5, 0x10
.4byte 0xfff28293  # addi x5, x5, -1
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a851857  # vfwcvt.f.xu.v v16, v8
.assert trap == 0 "e16 vfwcvt.f.xu.v retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "e16 vfwcvt.f.xu.v 0 writes x10"
.assert rd_wdata == 0x0 "e16 vfwcvt.f.xu.v 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfwcvt.f.xu.v 1 writes x10"
.assert rd_wdata == 0x3f800000 "e16 vfwcvt.f.xu.v 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfwcvt.f.xu.v 32768 writes x10"
.assert rd_wdata == 0x47000000 "e16 vfwcvt.f.xu.v 32768"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfwcvt.f.xu.v 65535 writes x10"
.assert rd_wdata == 0x477fff00 "e16 vfwcvt.f.xu.v 65535"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "e16 vfwcvt.f.xu.v exact writes x11"
.assert rd_wdata == 0x0 "e16 vfwcvt.f.xu.v exact"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a859857  # vfwcvt.f.x.v v16, v8
.assert trap == 0 "e16 vfwcvt.f.x.v retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "e16 vfwcvt.f.x.v 0 writes x10"
.assert rd_wdata == 0x0 "e16 vfwcvt.f.x.v 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfwcvt.f.x.v 1 writes x10"
.assert rd_wdata == 0x3f800000 "e16 vfwcvt.f.x.v 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfwcvt.f.x.v -32768 writes x10"
.assert rd_wdata == 0xffffffffc7000000 "e16 vfwcvt.f.x.v -32768"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfwcvt.f.x.v -1 writes x10"
.assert rd_wdata == 0xffffffffbf800000 "e16 vfwcvt.f.x.v -1"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "e16 vfwcvt.f.x.v exact writes x11"
.assert rd_wdata == 0x0 "e16 vfwcvt.f.x.v exact"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0xc06002b7  # lui x5, 0xc0600
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xc02002b7  # lui x5, 0xc0200
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x406002b7  # lui x5, 0x40600
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x402002b7  # lui x5, 0x40200
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a889857  # vfncvt.x.f.w v16, v8
.assert trap == 0 "e16 vfncvt.x.f.w RNE retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "e16 vfncvt.x.f.w RNE +2.5 -> 2 writes x10"
.assert rd_wdata == 0x2 "e16 vfncvt.x.f.w RNE +2.5 -> 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.x.f.w RNE +3.5 -> 4 writes x10"
.assert rd_wdata == 0x4 "e16 vfncvt.x.f.w RNE +3.5 -> 4"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.x.f.w RNE -2.5 -> -2 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "e16 vfncvt.x.f.w RNE -2.5 -> -2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.x.f.w RNE -3.5 -> -4 writes x10"
.assert rd_wdata == 0xfffffffffffffffc "e16 vfncvt.x.f.w RNE -3.5 -> -4"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "e16 vfncvt.x.f.w RNE raises NX writes x11"
.assert rd_wdata == 0x1 "e16 vfncvt.x.f.w RNE raises NX"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 3 writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a889857  # vfncvt.x.f.w v16, v8
.assert trap == 0 "e16 vfncvt.x.f.w RUP retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "e16 vfncvt.x.f.w RUP +2.5 -> 3 writes x10"
.assert rd_wdata == 0x3 "e16 vfncvt.x.f.w RUP +2.5 -> 3"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.x.f.w RUP -2.5 -> -2 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "e16 vfncvt.x.f.w RUP -2.5 -> -2"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "e16 vfncvt.x.f.w RUP raises NX writes x11"
.assert rd_wdata == 0x1 "e16 vfncvt.x.f.w RUP raises NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8b9857  # vfncvt.rtz.x.f.w v16, v8
.assert trap == 0 "e16 vfncvt.rtz.x.f.w retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "e16 vfncvt.rtz.x.f.w +2.5 -> 2 writes x10"
.assert rd_wdata == 0x2 "e16 vfncvt.rtz.x.f.w +2.5 -> 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.rtz.x.f.w +3.5 -> 3 writes x10"
.assert rd_wdata == 0x3 "e16 vfncvt.rtz.x.f.w +3.5 -> 3"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.rtz.x.f.w -2.5 -> -2 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "e16 vfncvt.rtz.x.f.w -2.5 -> -2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.rtz.x.f.w -3.5 -> -3 writes x10"
.assert rd_wdata == 0xfffffffffffffffd "e16 vfncvt.rtz.x.f.w -3.5 -> -3"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "e16 vfncvt.rtz.x.f.w raises NX writes x11"
.assert rd_wdata == 0x1 "e16 vfncvt.rtz.x.f.w raises NX"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0xbf8002b7  # lui x5, 0xbf800
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x4788c2b7  # lui x5, 0x4788c
.4byte 0x80028293  # addi x5, x5, -2048
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x406002b7  # lui x5, 0x40600
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x402002b7  # lui x5, 0x40200
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr x10, frm
.assert rd_addr == 10 "frm readback equals 0 writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a881857  # vfncvt.xu.f.w v16, v8
.assert trap == 0 "e16 vfncvt.xu.f.w retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "e16 vfncvt.xu.f.w RNE +2.5 -> 2 writes x10"
.assert rd_wdata == 0x2 "e16 vfncvt.xu.f.w RNE +2.5 -> 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.xu.f.w RNE +3.5 -> 4 writes x10"
.assert rd_wdata == 0x4 "e16 vfncvt.xu.f.w RNE +3.5 -> 4"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.xu.f.w overflow clamps 0xffff writes x10"
.assert rd_wdata == 0xffffffffffffffff "e16 vfncvt.xu.f.w overflow clamps 0xffff"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.xu.f.w negative clamps 0 writes x10"
.assert rd_wdata == 0x0 "e16 vfncvt.xu.f.w negative clamps 0"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "e16 vfncvt.xu.f.w raises NV|NX writes x11"
.assert rd_wdata == 0x11 "e16 vfncvt.xu.f.w raises NV|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8b1857  # vfncvt.rtz.xu.f.w v16, v8
.assert trap == 0 "e16 vfncvt.rtz.xu.f.w retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "e16 vfncvt.rtz.xu.f.w +2.5 -> 2 writes x10"
.assert rd_wdata == 0x2 "e16 vfncvt.rtz.xu.f.w +2.5 -> 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.rtz.xu.f.w +3.5 -> 3 writes x10"
.assert rd_wdata == 0x3 "e16 vfncvt.rtz.xu.f.w +3.5 -> 3"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.rtz.xu.f.w overflow clamps 0xffff writes x10"
.assert rd_wdata == 0xffffffffffffffff "e16 vfncvt.rtz.xu.f.w overflow clamps 0xffff"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "e16 vfncvt.rtz.xu.f.w negative clamps 0 writes x10"
.assert rd_wdata == 0x0 "e16 vfncvt.rtz.xu.f.w negative clamps 0"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "e16 vfncvt.rtz.xu.f.w raises NV|NX writes x11"
.assert rd_wdata == 0x11 "e16 vfncvt.rtz.xu.f.w raises NV|NX"

# Section 4: Masking (tu/mu and ta/ma), vl==0, portable VLMAX (mf4..m4), legal overlaps.
.4byte 0x01107fd7  # vsetvli x31, x0, e32, m2, tu, mu
.4byte 0x112232b7  # lui x5, 0x11223
.4byte 0x34428293  # addi x5, x5, 836
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xc081f657  # vsetivli x12, 3, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0xe0028293  # addi x5, x5, -512
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x4202e057  # vmv.s.x v0, x5
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x48861857  # vfwcvt.f.f.v v16, v8, v0.t
.assert trap == 0 "masked tu,mu vfwcvt.f.f.v retires"
.4byte 0xc111f657  # vsetivli x12, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "masked vfwcvt.f.f.v active lane 0 writes x10"
.assert rd_wdata == 0x3fc00000 "masked vfwcvt.f.f.v active lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked-off lane 1 preserved under mu writes x10"
.assert rd_wdata == 0x11223344 "masked-off lane 1 preserved under mu"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "tail lane 2 preserved under tu writes x10"
.assert rd_wdata == 0x11223344 "tail lane 2 preserved under tu"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "masked-off and tail sNaN leave fflags clear writes x11"
.assert rd_wdata == 0x0 "masked-off and tail sNaN leave fflags clear"
.4byte 0xcc817657  # vsetivli x12, 2, e16, m1, ta, ma
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x48861a57  # vfwcvt.f.f.v v20, v8, v0.t
.assert trap == 0 "masked ta,ma vfwcvt.f.f.v retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "masked ta,ma vfwcvt.f.f.v active lane 0 writes x10"
.assert rd_wdata == 0x3fc00000 "masked ta,ma vfwcvt.f.f.v active lane 0"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "masked ta,ma vfwcvt.f.f.v disabled sNaN leaves fflags clear writes x11"
.assert rd_wdata == 0x0 "masked ta,ma vfwcvt.f.f.v disabled sNaN leaves fflags clear"
.4byte 0x00807fd7  # vsetvli x31, x0, e16, m1, tu, mu
.4byte 0x000032b7  # lui x5, 0x3
.4byte 0x34428293  # addi x5, x5, 836
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xc111f657  # vsetivli x12, 3, e32, m2, tu, mu
.4byte 0x7f8002b7  # lui x5, 0x7f800
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x7f8002b7  # lui x5, 0x7f800
.4byte 0x00128293  # addi x5, x5, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x401002b7  # lui x5, 0x40100
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, x5
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x488a1857  # vfncvt.f.f.w v16, v8, v0.t
.assert trap == 0 "masked tu,mu vfncvt.f.f.w retires"
.4byte 0xc081f657  # vsetivli x12, 3, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "masked vfncvt.f.f.w active lane 0 (2.25h) writes x10"
.assert rd_wdata == 0x4080 "masked vfncvt.f.f.w active lane 0 (2.25h)"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked-off lane 1 preserved under mu writes x10"
.assert rd_wdata == 0x3344 "masked-off lane 1 preserved under mu"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "tail lane 2 preserved under tu writes x10"
.assert rd_wdata == 0x3344 "tail lane 2 preserved under tu"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "masked-off and tail sNaN on vfncvt leave fflags clear writes x11"
.assert rd_wdata == 0x0 "masked-off and tail sNaN on vfncvt leave fflags clear"
.4byte 0xcc817657  # vsetivli x12, 2, e16, m1, ta, ma
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x488a1a57  # vfncvt.f.f.w v20, v8, v0.t
.assert trap == 0 "masked ta,ma vfncvt.f.f.w retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "masked ta,ma vfncvt.f.f.w active lane 0 writes x10"
.assert rd_wdata == 0x4080 "masked ta,ma vfncvt.f.f.w active lane 0"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "masked ta,ma vfncvt.f.f.w disabled sNaN leaves fflags clear writes x11"
.assert rd_wdata == 0x0 "masked ta,ma vfncvt.f.f.w disabled sNaN leaves fflags clear"
# vl == 0 leaves destination and fflags untouched.
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x000082b7  # lui x5, 0x8
.4byte 0xc0128293  # addi x5, x5, -1023
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x000022b7  # lui x5, 0x2
.4byte 0x22228293  # addi x5, x5, 546
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xc0807657  # vsetivli x12, 0, e16, m1, tu, mu
.assert rd_addr == 12 "vl equals 0 writes x12"
.assert rd_wdata == 0x0 "vl equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "vl==0 vfwcvt.f.f.v retires"
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vl==0 vfncvt.f.f.w retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "vl==0 Zvfhmin ops leave fflags clear writes x11"
.assert rd_wdata == 0x0 "vl==0 Zvfhmin ops leave fflags clear"
.4byte 0xc080f657  # vsetivli x12, 1, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vl==0 preserves destination writes x10"
.assert rd_wdata == 0x2222 "vl==0 preserves destination"
# Portable VLMAX across mf4, mf2, m1, m2, m4.
.4byte 0x00e07657  # vsetvli x12, x0, e16, mf4, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "VLMAX mf4 vfwcvt.f.f.v retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX mf4 vfwcvt.f.f.v exact writes x11"
.assert rd_wdata == 0x0 "VLMAX mf4 vfwcvt.f.f.v exact"
.4byte 0x01707657  # vsetvli x12, x0, e32, mf2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "VLMAX mf4 vfwcvt lane 0 == 3.0f writes x10"
.assert rd_wdata == 0x40400000 "VLMAX mf4 vfwcvt lane 0 == 3.0f"
.4byte 0x00e07657  # vsetvli x12, x0, e16, mf4, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4b0a1457  # vfncvt.f.f.w v8, v16
.assert trap == 0 "VLMAX mf4 vfncvt.f.f.w retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX mf4 vfncvt.f.f.w exact writes x11"
.assert rd_wdata == 0x0 "VLMAX mf4 vfncvt.f.f.w exact"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "VLMAX mf4 vfncvt lane 0 == 3.0h writes x10"
.assert rd_wdata == 0x4200 "VLMAX mf4 vfncvt lane 0 == 3.0h"
.4byte 0x00f07657  # vsetvli x12, x0, e16, mf2, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "VLMAX mf2 vfwcvt.f.f.v retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX mf2 vfwcvt.f.f.v exact writes x11"
.assert rd_wdata == 0x0 "VLMAX mf2 vfwcvt.f.f.v exact"
.4byte 0x01007657  # vsetvli x12, x0, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "VLMAX mf2 vfwcvt lane 0 == 3.0f writes x10"
.assert rd_wdata == 0x40400000 "VLMAX mf2 vfwcvt lane 0 == 3.0f"
.4byte 0x00f07657  # vsetvli x12, x0, e16, mf2, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4b0a1457  # vfncvt.f.f.w v8, v16
.assert trap == 0 "VLMAX mf2 vfncvt.f.f.w retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX mf2 vfncvt.f.f.w exact writes x11"
.assert rd_wdata == 0x0 "VLMAX mf2 vfncvt.f.f.w exact"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "VLMAX mf2 vfncvt lane 0 == 3.0h writes x10"
.assert rd_wdata == 0x4200 "VLMAX mf2 vfncvt lane 0 == 3.0h"
.4byte 0x00807657  # vsetvli x12, x0, e16, m1, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "VLMAX m1 vfwcvt.f.f.v retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX m1 vfwcvt.f.f.v exact writes x11"
.assert rd_wdata == 0x0 "VLMAX m1 vfwcvt.f.f.v exact"
.4byte 0x01107657  # vsetvli x12, x0, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "VLMAX m1 vfwcvt lane 0 == 3.0f writes x10"
.assert rd_wdata == 0x40400000 "VLMAX m1 vfwcvt lane 0 == 3.0f"
.4byte 0x00807657  # vsetvli x12, x0, e16, m1, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4b0a1457  # vfncvt.f.f.w v8, v16
.assert trap == 0 "VLMAX m1 vfncvt.f.f.w retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX m1 vfncvt.f.f.w exact writes x11"
.assert rd_wdata == 0x0 "VLMAX m1 vfncvt.f.f.w exact"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "VLMAX m1 vfncvt lane 0 == 3.0h writes x10"
.assert rd_wdata == 0x4200 "VLMAX m1 vfncvt lane 0 == 3.0h"
.4byte 0x00907657  # vsetvli x12, x0, e16, m2, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "VLMAX m2 vfwcvt.f.f.v retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX m2 vfwcvt.f.f.v exact writes x11"
.assert rd_wdata == 0x0 "VLMAX m2 vfwcvt.f.f.v exact"
.4byte 0x01207657  # vsetvli x12, x0, e32, m4, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "VLMAX m2 vfwcvt lane 0 == 3.0f writes x10"
.assert rd_wdata == 0x40400000 "VLMAX m2 vfwcvt lane 0 == 3.0f"
.4byte 0x00907657  # vsetvli x12, x0, e16, m2, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4b0a1457  # vfncvt.f.f.w v8, v16
.assert trap == 0 "VLMAX m2 vfncvt.f.f.w retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX m2 vfncvt.f.f.w exact writes x11"
.assert rd_wdata == 0x0 "VLMAX m2 vfncvt.f.f.w exact"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "VLMAX m2 vfncvt lane 0 == 3.0h writes x10"
.assert rd_wdata == 0x4200 "VLMAX m2 vfncvt lane 0 == 3.0h"
.4byte 0x00a07657  # vsetvli x12, x0, e16, m4, tu, mu
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x20028293  # addi x5, x5, 512
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "VLMAX m4 vfwcvt.f.f.v retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX m4 vfwcvt.f.f.v exact writes x11"
.assert rd_wdata == 0x0 "VLMAX m4 vfwcvt.f.f.v exact"
.4byte 0x01307657  # vsetvli x12, x0, e32, m8, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "VLMAX m4 vfwcvt lane 0 == 3.0f writes x10"
.assert rd_wdata == 0x40400000 "VLMAX m4 vfwcvt lane 0 == 3.0f"
.4byte 0x00a07657  # vsetvli x12, x0, e16, m4, tu, mu
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4b0a1457  # vfncvt.f.f.w v8, v16
.assert trap == 0 "VLMAX m4 vfncvt.f.f.w retires"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "VLMAX m4 vfncvt.f.f.w exact writes x11"
.assert rd_wdata == 0x0 "VLMAX m4 vfncvt.f.f.w exact"
.4byte 0x42802557  # vmv.x.s x10, v8
.assert rd_addr == 10 "VLMAX m4 vfncvt lane 0 == 3.0h writes x10"
.assert rd_wdata == 0x4200 "VLMAX m4 vfncvt lane 0 == 3.0h"
.4byte 0xc122f657  # vsetivli x12, 5, e32, m4, tu, mu
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "VLMAX m4 vfwcvt lane 4 (second reg at VLEN 128) writes x10"
.assert rd_wdata == 0x40400000 "VLMAX m4 vfwcvt lane 4 (second reg at VLEN 128)"
# Legal overlaps: widening source in upper half of dest; narrowing dest in lower half of src.
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x50028293  # addi x5, x5, 1280
.4byte 0x5e02c8d7  # vmv.v.x v17, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x40028293  # addi x5, x5, 1024
.4byte 0x3b12ed57  # vslide1up.vx v26, v17, x5
.4byte 0x5e0d08d7  # vmv.v.v v17, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4b161857  # vfwcvt.f.f.v v16, v17
.assert trap == 0 "legal m1 upper-reg overlap vfwcvt.f.f.v retires"
.4byte 0xc1117657  # vsetivli x12, 2, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "overlap m1 vfwcvt lane 0 == 4.0f writes x10"
.assert rd_wdata == 0x40800000 "overlap m1 vfwcvt lane 0 == 4.0f"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "overlap m1 vfwcvt lane 1 == -5.0f writes x10"
.assert rd_wdata == 0xffffffffc0a00000 "overlap m1 vfwcvt lane 1 == -5.0f"
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x4b0a1857  # vfncvt.f.f.w v16, v16
.assert trap == 0 "legal m1 lower-reg overlap vfncvt.f.f.w retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "overlap m1 vfncvt lane 0 == 4.0h writes x10"
.assert rd_wdata == 0x4400 "overlap m1 vfncvt lane 0 == 4.0h"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "overlap m1 vfncvt lane 1 == -5.0h writes x10"
.assert rd_wdata == 0xffffffffffffc500 "overlap m1 vfncvt lane 1 == -5.0h"
.4byte 0xc0917657  # vsetivli x12, 2, e16, m2, tu, mu
.4byte 0x0000c2b7  # lui x5, 0xc
.4byte 0x70028293  # addi x5, x5, 1792
.4byte 0x5e02c957  # vmv.v.x v18, x5
.4byte 0x000042b7  # lui x5, 0x4
.4byte 0x60028293  # addi x5, x5, 1536
.4byte 0x3b22ed57  # vslide1up.vx v26, v18, x5
.4byte 0x5e0d0957  # vmv.v.v v18, v26
.4byte 0x4b261857  # vfwcvt.f.f.v v16, v18
.assert trap == 0 "legal m2 upper-half overlap vfwcvt.f.f.v retires"
.4byte 0xc1217657  # vsetivli x12, 2, e32, m4, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "overlap m2 vfwcvt lane 0 == 6.0f writes x10"
.assert rd_wdata == 0x40c00000 "overlap m2 vfwcvt lane 0 == 6.0f"
.4byte 0xc0917657  # vsetivli x12, 2, e16, m2, tu, mu
.4byte 0x4b0a1857  # vfncvt.f.f.w v16, v16
.assert trap == 0 "legal m2 lower-half overlap vfncvt.f.f.w retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "overlap m2 vfncvt lane 0 == 6.0h writes x10"
.assert rd_wdata == 0x4600 "overlap m2 vfncvt lane 0 == 6.0h"
.4byte 0x001025f3  # csrr x11, fflags
.assert rd_addr == 11 "legal overlaps clear fflags writes x11"
.assert rd_wdata == 0x0 "legal overlaps clear fflags"

# Section 5: Illegal Zvfhmin traps (m8 range, e8 width, alignment, v0, overlap, frm, vill).
.4byte 0xc0b17657  # vsetivli x12, 2, e16, m8, tu, mu
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 1 "e16 m8 vfwcvt.f.f.v traps (EMUL 16)"
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 1 "e16 m8 vfncvt.f.f.w traps (EMUL 16)"
.4byte 0xc0017657  # vsetivli x12, 2, e8, m1, tu, mu
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 1 "e8 m1 vfwcvt.f.f.v traps (FP8)"
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 1 "e8 m1 vfncvt.f.f.w traps (FP8)"
.4byte 0xc1817657  # vsetivli x12, 2, e64, m1, tu, mu
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 1 "e64 m1 vfwcvt.f.f.v traps (EEW 128)"
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 1 "e64 m1 vfncvt.f.f.w traps (EEW 128)"
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x4a8618d7  # vfwcvt.f.f.v v17, v8
.assert trap == 1 "misaligned wide vd vfwcvt.f.f.v traps"
.4byte 0x4a9a1857  # vfncvt.f.f.w v16, v9
.assert trap == 1 "misaligned wide vs2 vfncvt.f.f.w traps"
.4byte 0x48861057  # vfwcvt.f.f.v v0, v8, v0.t
.assert trap == 1 "masked vd==v0 vfwcvt.f.f.v traps"
.4byte 0x488a1057  # vfncvt.f.f.w v0, v8, v0.t
.assert trap == 1 "masked vd==v0 vfncvt.f.f.w traps"
.4byte 0x48061857  # vfwcvt.f.f.v v16, v0, v0.t
.assert trap == 1 "masked vs2==v0 vfwcvt.f.f.v traps"
.4byte 0x480a1857  # vfncvt.f.f.w v16, v0, v0.t
.assert trap == 1 "masked vs2==v0 vfncvt.f.f.w traps"
.4byte 0x4b061857  # vfwcvt.f.f.v v16, v16
.assert trap == 1 "illegal lower-reg overlap vfwcvt.f.f.v traps"
.4byte 0x4b0a18d7  # vfncvt.f.f.w v17, v16
.assert trap == 1 "illegal upper-reg overlap vfncvt.f.f.w traps"
.4byte 0xc0f17657  # vsetivli x12, 2, e16, mf2, tu, mu
.4byte 0x4b061857  # vfwcvt.f.f.v v16, v16
.assert trap == 1 "illegal fractional overlap vfwcvt.f.f.v traps"
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x0022d073  # csrwi frm, 5
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 1 "reserved frm=5 vfncvt.f.f.w traps"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0xc200f057  # vsetivli x0, 1, e128, m1 (sets vill)
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 1 "vill vfwcvt.f.f.v traps"
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 1 "vill vfncvt.f.f.w traps"
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.assert rd_addr == 12 "vill cleared after recovery vsetivli writes x12"
.assert rd_wdata == 0x2 "vill cleared after recovery vsetivli"
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "post-vill recovery vfwcvt.f.f.v retires"
