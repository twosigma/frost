# Single-width vector floating-point operations across binary32 and binary64.
.noshrink
# Enable FS and VS, clear fcsr, and read back frm and fflags.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 1536
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x00305073  # csrwi fcsr, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x0 "initial frm is RNE"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "initial fflags clear"
.4byte 0x01b07fd7  # vsetvli t6, zero, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0

# Section 1: binary32 add/sub, control readout on v13, all five frm modes, and specials.
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c6d7  # vmv.v.x v13, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x406002b7  # lui t0, 0x40600
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3f0002b7  # lui t0, 0x3f000
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x3fa002b7  # lui t0, 0x3fa00
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x3fa002b7  # lui t0, 0x3fa00
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a8496d7  # vfsub.vv v13, v8, v9
.assert trap == 0 "vfsub.vv retires"
.4byte 0x42d02557  # vmv.x.s a0, v13
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40100000 "control vfsub.vv yields 2.25"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "exact vfsub.vv clears flags"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0x3ed13c57  # vslidedown.vi v24, v13, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "tail lane 2 of v13 stays undisturbed"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x0a805857  # vfsub.vf v16, v8, ft0
.assert trap == 0 "vfsub.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40100000 "vfsub.vf 3.5 - 1.25"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbe800000 "vfsub.vf 1.0 - 1.25"
.4byte 0x9e805857  # vfrsub.vf v16, v8, ft0
.assert trap == 0 "vfrsub.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0100000 "vfrsub.vf 1.25 - 3.5"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3e800000 "vfrsub.vf 1.25 - 1.0"
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 0 "vfadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40980000 "vfadd.vv 3.5 + 1.25"
.4byte 0x03005857  # vfadd.vf v16, v16, ft0
.assert trap == 0 "vfadd.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40c00000 "in-place vfadd.vf 4.75 + 1.25"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "exact add/sub leave flags clear"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0xbf8002b7  # lui t0, 0xbf800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0xb38002b7  # lui t0, 0xb3800
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x338002b7  # lui t0, 0x33800
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x338002b7  # lui t0, 0x33800
.4byte 0x3ba2e4d7  # vslide1up.vx v9, v26, t0
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 0 "vfadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800000 "RNE tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800002 "RNE tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf800000 "RNE tie lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RNE tie raises NX"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 0 "vfadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800000 "RTZ tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800001 "RTZ tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf800000 "RTZ tie lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RTZ tie raises NX"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 0 "vfadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800000 "RDN tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800001 "RDN tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf800001 "RDN tie lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RDN tie raises NX"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 0 "vfadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800001 "RUP tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800002 "RUP tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf800000 "RUP tie lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RUP tie raises NX"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 0 "vfadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800001 "RMM tie lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f800002 "RMM tie lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf800001 "RMM tie lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RMM tie raises NX"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a849857  # vfsub.vv v16, v8, v9
.assert trap == 0 "vfsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80000000 "RDN 1.0 - 1.0 yields -0.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "RDN zero cancellation clears flags"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 0 "vfadd.vv retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f7fffff "RTZ overflow clamps to MAX_FINITE"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x5 "RTZ overflow raises OF|NX"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a849857  # vfsub.vv v16, v8, v9
.assert trap == 0 "vfsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x0 "RNE 1.0 - 1.0 yields +0.0"
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 0 "vfadd.vv retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800000 "RNE overflow yields +inf"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x5 "RNE overflow raises OF|NX"
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a849857  # vfsub.vv v16, v8, v9
.assert trap == 0 "vfsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "inf - inf yields canonical qNaN"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x10 "inf - inf raises NV"
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0xf20280d3  # fmv.d.x ft1, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0290d857  # vfadd.vf v16, v9, ft1
.assert trap == 0 "vfadd.vf retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "improperly NaN-boxed scalar unboxes to qNaN"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "unboxed qNaN leaves flags clear"
# Binary64 add/sub across vl<VLMAX, masked mu, vl=0, and vl=VLMAX.
.4byte 0x01807fd7  # vsetvli t6, zero, e64, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x1e1e3f37  # lui t5, 0x1e1e3
.4byte 0xd2df0f13  # addi t5, t5, -723
.4byte 0x01e2e2b3  # or t0, t0, t5
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x7ff002b7  # lui t0, 0x7ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x401602b7  # lui t0, 0x40160
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x7ff002b7  # lui t0, 0x7ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x3ff402b7  # lui t0, 0x3ff40
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x3ff402b7  # lui t0, 0x3ff40
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xf2028053  # fmv.d.x ft0, t0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x1 "VL equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a849857  # vfsub.vv v16, v8, v9
.assert trap == 0 "vfsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4011000000000000 "e64 vfsub.vv 5.5 - 1.25"
.4byte 0x0a805857  # vfsub.vf v16, v8, ft0
.assert trap == 0 "vfsub.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4011000000000000 "e64 vfsub.vf 5.5 - 1.25"
.4byte 0x9e805857  # vfrsub.vf v16, v8, ft0
.assert trap == 0 "vfrsub.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xc011000000000000 "e64 vfrsub.vf 1.25 - 5.5"
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 0 "vfadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x401b000000000000 "e64 vfadd.vv 5.5 + 1.25"
.4byte 0x02805857  # vfadd.vf v16, v8, ft0
.assert trap == 0 "vfadd.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x401b000000000000 "e64 vfadd.vf 5.5 + 1.25"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e64 tail inf - inf leaves flags clear"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c1e1e2d2d "e64 tail lane 1 preserved under tu"
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x08849857  # vfsub.vv v16, v8, v9, v0.t
.assert trap == 0 "vfsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4011000000000000 "masked e64 vfsub.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c1e1e2d2d "masked-off e64 lane 1 preserved under mu"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "masked-off inf - inf leaves flags clear"
.4byte 0xc1807657  # vsetivli a2, 0, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x0a849857  # vfsub.vv v16, v8, v9
.assert trap == 0 "vfsub.vv retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4011000000000000 "vl=0 leaves e64 lane 0 unchanged"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "vl=0 inf - inf leaves flags clear"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x0a805857  # vfsub.vf v16, v8, ft0
.assert trap == 0 "vfsub.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4011000000000000 "vl=VLMAX e64 vfsub.vf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7ff0000000000000 "vl=VLMAX e64 vfsub.vf lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "vl=VLMAX e64 vfsub.vf clears flags"

# Section 2: binary32 and binary64 mul, div, rdiv, and sqrt.
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x008002b7  # lui t0, 0x800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xc04002b7  # lui t0, 0xc0400
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3f0002b7  # lui t0, 0x3f000
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x402002b7  # lui t0, 0x40200
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x402002b7  # lui t0, 0x40200
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92849857  # vfmul.vv v16, v8, v9
.assert trap == 0 "vfmul.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0f00000 "e32 vfmul.vv -3.0 * 2.5"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400000 "e32 vfmul.vv inexact subnormal"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "e32 vfmul.vv underflow raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92805857  # vfmul.vf v16, v8, ft0
.assert trap == 0 "vfmul.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0f00000 "e32 vfmul.vf -3.0 * 2.5"
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x404002b7  # lui t0, 0x40400
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92849857  # vfmul.vv v16, v8, v9
.assert trap == 0 "vfmul.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "0.0 * inf yields canonical qNaN"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x10 "0.0 * inf raises NV"
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x40f002b7  # lui t0, 0x40f00
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x404002b7  # lui t0, 0x40400
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x402002b7  # lui t0, 0x40200
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82849857  # vfdiv.vv v16, v8, v9
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40400000 "e32 vfdiv.vv 7.5 / 2.5"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3eaaaaab "e32 vfdiv.vv RNE 1.0 / 3.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "1.0 / 3.0 raises NX"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82849857  # vfdiv.vv v16, v8, v9
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3eaaaaaa "e32 vfdiv.vv RTZ 1.0 / 3.0"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x410002b7  # lui t0, 0x41000
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82805857  # vfdiv.vf v16, v8, ft0
.assert trap == 0 "vfdiv.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40800000 "e32 vfdiv.vf 8.0 / 2.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x0 "e32 vfdiv.vf 0.0 / 2.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "exact vfdiv.vf clears flags"
.4byte 0x86805857  # vfrdiv.vf v16, v8, ft0
.assert trap == 0 "vfrdiv.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3e800000 "e32 vfrdiv.vf 2.0 / 8.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800000 "e32 vfrdiv.vf 2.0 / 0.0 yields +inf"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x8 "2.0 / 0.0 raises DZ"
.4byte 0x004002b7  # lui t0, 0x400
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3f0002b7  # lui t0, 0x3f000
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82849857  # vfdiv.vv v16, v8, v9
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "0.0 / 0.0 yields canonical qNaN"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x800000 "subnormal / 0.5 normalizes to 2^-126"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x10 "0.0 / 0.0 raises NV only"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x002002b7  # lui t0, 0x200
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x411002b7  # lui t0, 0x41100
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 0 "vfsqrt.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40400000 "e32 vfsqrt.v 9.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x1f800000 "e32 vfsqrt.v subnormal 2^-128 -> 2^-64"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80000000 "e32 vfsqrt.v -0.0 yields -0.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "exact vfsqrt.v including -0.0 clears flags"
.4byte 0xbf8002b7  # lui t0, 0xbf800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 0 "vfsqrt.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fb504f3 "e32 vfsqrt.v 2.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800000 "e32 vfsqrt.v +inf"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "e32 vfsqrt.v -1.0 yields canonical qNaN"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x11 "vfsqrt.v 2.0 and -1.0 raise NV|NX"
# All five frm modes across vfmul.vv, vfdiv.vv, vfrdiv.vf, and vfsqrt.v.
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0xbf8012b7  # lui t0, 0xbf801
.4byte 0x80028293  # addi t0, t0, -2048
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x3f8022b7  # lui t0, 0x3f802
.4byte 0x80028293  # addi t0, t0, -2048
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x3f8012b7  # lui t0, 0x3f801
.4byte 0x80028293  # addi t0, t0, -2048
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x3f8012b7  # lui t0, 0x3f801
.4byte 0x80028293  # addi t0, t0, -2048
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x3f8012b7  # lui t0, 0x3f801
.4byte 0x80028293  # addi t0, t0, -2048
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x3f8012b7  # lui t0, 0x3f801
.4byte 0x80028293  # addi t0, t0, -2048
.4byte 0x3ba2e4d7  # vslide1up.vx v9, v26, t0
.4byte 0x808002b7  # lui t0, 0x80800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x008002b7  # lui t0, 0x800
.4byte 0x00328293  # addi t0, t0, 3
.4byte 0x3aa2ed57  # vslide1up.vx v26, v10, t0
.4byte 0x008002b7  # lui t0, 0x800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x3ba2e557  # vslide1up.vx v10, v26, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x5e02c5d7  # vmv.v.x v11, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x3ab2ed57  # vslide1up.vx v26, v11, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x3ba2e5d7  # vslide1up.vx v11, v26, t0
.4byte 0x3fe002b7  # lui t0, 0x3fe00
.4byte 0x5e02c657  # vmv.v.x v12, t0
.4byte 0xc00002b7  # lui t0, 0xc0000
.4byte 0x3ac2ed57  # vslide1up.vx v26, v12, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x3ba2e657  # vslide1up.vx v12, v26, t0
.4byte 0x008002b7  # lui t0, 0x800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0xf00280d3  # fmv.w.x ft1, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x5e02c757  # vmv.v.x v14, t0
.4byte 0x40a002b7  # lui t0, 0x40a00
.4byte 0x3ae2ed57  # vslide1up.vx v26, v14, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x3ba2e757  # vslide1up.vx v14, v26, t0
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92849857  # vfmul.vv v16, v8, v9
.assert trap == 0 "vfmul.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f801000 "RNE vfmul.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f802002 "RNE vfmul.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf801000 "RNE vfmul.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RNE vfmul.vv raises NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82a59857  # vfdiv.vv v16, v10, v11
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400000 "RNE vfdiv.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400002 "RNE vfdiv.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400000 "RNE vfdiv.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RNE vfdiv.vv raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x86c0d857  # vfrdiv.vf v16, v12, ft1
.assert trap == 0 "vfrdiv.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400000 "RNE vfrdiv.vf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400000 "RNE vfrdiv.vf lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x492493 "RNE vfrdiv.vf lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RNE vfrdiv.vf raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ee01857  # vfsqrt.v v16, v14
.assert trap == 0 "vfsqrt.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fb504f3 "RNE vfsqrt.v lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400f1bbd "RNE vfsqrt.v lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RNE vfsqrt.v raises NX"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92849857  # vfmul.vv v16, v8, v9
.assert trap == 0 "vfmul.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f801000 "RTZ vfmul.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f802001 "RTZ vfmul.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf801000 "RTZ vfmul.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RTZ vfmul.vv raises NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82a59857  # vfdiv.vv v16, v10, v11
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400000 "RTZ vfdiv.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400001 "RTZ vfdiv.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400000 "RTZ vfdiv.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RTZ vfdiv.vv raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x86c0d857  # vfrdiv.vf v16, v12, ft1
.assert trap == 0 "vfrdiv.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400000 "RTZ vfrdiv.vf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400000 "RTZ vfrdiv.vf lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x492492 "RTZ vfrdiv.vf lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RTZ vfrdiv.vf raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ee01857  # vfsqrt.v v16, v14
.assert trap == 0 "vfsqrt.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fb504f3 "RTZ vfsqrt.v lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400f1bbc "RTZ vfsqrt.v lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RTZ vfsqrt.v raises NX"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92849857  # vfmul.vv v16, v8, v9
.assert trap == 0 "vfmul.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f801000 "RDN vfmul.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f802001 "RDN vfmul.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf801001 "RDN vfmul.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RDN vfmul.vv raises NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82a59857  # vfdiv.vv v16, v10, v11
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400000 "RDN vfdiv.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400001 "RDN vfdiv.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400001 "RDN vfdiv.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RDN vfdiv.vv raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x86c0d857  # vfrdiv.vf v16, v12, ft1
.assert trap == 0 "vfrdiv.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400000 "RDN vfrdiv.vf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400001 "RDN vfrdiv.vf lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x492492 "RDN vfrdiv.vf lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RDN vfrdiv.vf raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ee01857  # vfsqrt.v v16, v14
.assert trap == 0 "vfsqrt.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fb504f3 "RDN vfsqrt.v lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400f1bbc "RDN vfsqrt.v lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RDN vfsqrt.v raises NX"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92849857  # vfmul.vv v16, v8, v9
.assert trap == 0 "vfmul.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f801001 "RUP vfmul.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f802002 "RUP vfmul.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf801000 "RUP vfmul.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RUP vfmul.vv raises NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82a59857  # vfdiv.vv v16, v10, v11
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400001 "RUP vfdiv.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400002 "RUP vfdiv.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400000 "RUP vfdiv.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RUP vfdiv.vv raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x86c0d857  # vfrdiv.vf v16, v12, ft1
.assert trap == 0 "vfrdiv.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400001 "RUP vfrdiv.vf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400000 "RUP vfrdiv.vf lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x492493 "RUP vfrdiv.vf lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RUP vfrdiv.vf raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ee01857  # vfsqrt.v v16, v14
.assert trap == 0 "vfsqrt.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fb504f4 "RUP vfsqrt.v lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400f1bbd "RUP vfsqrt.v lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RUP vfsqrt.v raises NX"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92849857  # vfmul.vv v16, v8, v9
.assert trap == 0 "vfmul.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f801001 "RMM vfmul.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f802002 "RMM vfmul.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf801001 "RMM vfmul.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RMM vfmul.vv raises NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x82a59857  # vfdiv.vv v16, v10, v11
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400001 "RMM vfdiv.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400002 "RMM vfdiv.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400001 "RMM vfdiv.vv lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RMM vfdiv.vv raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x86c0d857  # vfrdiv.vf v16, v12, ft1
.assert trap == 0 "vfrdiv.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400001 "RMM vfrdiv.vf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80400001 "RMM vfrdiv.vf lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x492493 "RMM vfrdiv.vf lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x3 "RMM vfrdiv.vf raises UF|NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ee01857  # vfsqrt.v v16, v14
.assert trap == 0 "vfsqrt.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fb504f3 "RMM vfsqrt.v lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x400f1bbd "RMM vfsqrt.v lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "RMM vfsqrt.v raises NX"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x01807fd7  # vsetvli t6, zero, e64, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x1e1e3f37  # lui t5, 0x1e1e3
.4byte 0xd2df0f13  # addi t5, t5, -723
.4byte 0x01e2e2b3  # or t0, t0, t5
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0xbff002b7  # lui t0, 0xbff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x402202b7  # lui t0, 0x40220
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xf2028053  # fmv.d.x ft0, t0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x1 "VL equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x92849857  # vfmul.vv v16, v8, v9
.assert trap == 0 "vfmul.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4032000000000000 "e64 vfmul.vv 9.0 * 2.0"
.4byte 0x92805857  # vfmul.vf v16, v8, ft0
.assert trap == 0 "vfmul.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4032000000000000 "e64 vfmul.vf 9.0 * 2.0"
.4byte 0x82849857  # vfdiv.vv v16, v8, v9
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4012000000000000 "e64 vfdiv.vv 9.0 / 2.0"
.4byte 0x82805857  # vfdiv.vf v16, v8, ft0
.assert trap == 0 "vfdiv.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4012000000000000 "e64 vfdiv.vf 9.0 / 2.0"
.4byte 0x86805857  # vfrdiv.vf v16, v8, ft0
.assert trap == 0 "vfrdiv.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fcc71c71c71c71c "e64 vfrdiv.vf 2.0 / 9.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x1 "e64 2.0 / 9.0 raises NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 0 "vfsqrt.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4008000000000000 "e64 vfsqrt.v 9.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e64 vfsqrt.v 9.0 clears flags"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c1e1e2d2d "e64 mul/div/sqrt tail lane 1 preserved"
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x80849857  # vfdiv.vv v16, v8, v9, v0.t
.assert trap == 0 "vfdiv.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4012000000000000 "masked e64 vfdiv.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c1e1e2d2d "masked-off e64 div0 lane 1 preserved"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "masked-off e64 div0 leaves flags clear"
.4byte 0xc1807657  # vsetivli a2, 0, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x4e801857  # vfsqrt.v v16, v8
.assert trap == 0 "vfsqrt.v retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4012000000000000 "vl=0 vfsqrt.v leaves lane 0 unchanged"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "vl=0 vfsqrt.v leaves flags clear"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x401002b7  # lui t0, 0x40100
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x92a05857  # vfmul.vf v16, v10, ft0
.assert trap == 0 "vfmul.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4020000000000000 "vl=VLMAX e64 vfmul.vf lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4020000000000000 "vl=VLMAX e64 vfmul.vf lane 1"
.4byte 0x4ea01857  # vfsqrt.v v16, v10
.assert trap == 0 "vfsqrt.v retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4000000000000000 "vl=VLMAX e64 vfsqrt.v lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "vl=VLMAX e64 mul/sqrt clears flags"

# Section 3: vfrsqrt7.v and vfrec7.v tables, subnormals, overflows, and flags.
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0x002002b7  # lui t0, 0x200
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e821857  # vfrsqrt7.v v16, v8
.assert trap == 0 "vfrsqrt7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f7f0000 "e32 vfrsqrt7.v normal/subnormal lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f340000 "e32 vfrsqrt7.v normal/subnormal lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5f7f0000 "e32 vfrsqrt7.v normal/subnormal lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e32 vfrsqrt7.v finite positive clears flags"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x4 "VL equals 4"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "e32 vfrsqrt7.v tail lane 3 preserved"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0xbf8002b7  # lui t0, 0xbf800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e821857  # vfrsqrt7.v v16, v8
.assert trap == 0 "vfrsqrt7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff800000 "e32 vfrsqrt7.v special lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x0 "e32 vfrsqrt7.v special lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "e32 vfrsqrt7.v special lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x18 "e32 vfrsqrt7.v -0.0 and -1.0 raise NV|DZ"
.4byte 0x7f0002b7  # lui t0, 0x7f000
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x002002b7  # lui t0, 0x200
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x3fc002b7  # lui t0, 0x3fc00
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e829857  # vfrec7.v v16, v8
.assert trap == 0 "vfrec7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3f2a0000 "e32 vfrec7.v normal/subnormal lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f7f0000 "e32 vfrec7.v normal/subnormal lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fc000 "e32 vfrec7.v normal/subnormal lane 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e32 vfrec7.v subnormal output raises no flags"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x801002b7  # lui t0, 0x80100
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x001002b7  # lui t0, 0x100
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e829857  # vfrec7.v v16, v8
.assert trap == 0 "vfrec7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800000 "e32 vfrec7.v overflow RNE lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff800000 "e32 vfrec7.v overflow RNE lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x5 "e32 vfrec7.v overflow RNE raises OF|NX"
.4byte 0x0020d073  # csrwi frm, 1
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x1 "frm readback equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e829857  # vfrec7.v v16, v8
.assert trap == 0 "vfrec7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f7fffff "e32 vfrec7.v overflow RTZ lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff7fffff "e32 vfrec7.v overflow RTZ lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x5 "e32 vfrec7.v overflow RTZ raises OF|NX"
.4byte 0x00215073  # csrwi frm, 2
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x2 "frm readback equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e829857  # vfrec7.v v16, v8
.assert trap == 0 "vfrec7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f7fffff "e32 vfrec7.v overflow RDN lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff800000 "e32 vfrec7.v overflow RDN lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x5 "e32 vfrec7.v overflow RDN raises OF|NX"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x3 "frm readback equals 3"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e829857  # vfrec7.v v16, v8
.assert trap == 0 "vfrec7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800000 "e32 vfrec7.v overflow RUP lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff7fffff "e32 vfrec7.v overflow RUP lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x5 "e32 vfrec7.v overflow RUP raises OF|NX"
.4byte 0x00225073  # csrwi frm, 4
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x4 "frm readback equals 4"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e829857  # vfrec7.v v16, v8
.assert trap == 0 "vfrec7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800000 "e32 vfrec7.v overflow RMM lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff800000 "e32 vfrec7.v overflow RMM lane 1"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x5 "e32 vfrec7.v overflow RMM raises OF|NX"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xff8002b7  # lui t0, 0xff800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4c829857  # vfrec7.v v16, v8, v0.t
.assert trap == 0 "vfrec7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80000000 "masked e32 vfrec7.v -inf yields -0.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "masked-off e32 vfrec7.v lane 1 preserved"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "masked-off vfrec7.v zero leaves DZ clear"
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x4e829857  # vfrec7.v v16, v8
.assert trap == 0 "vfrec7.v retires"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80000000 "vl=0 vfrec7.v preserves lane 0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "vl=0 vfrec7.v zero leaves DZ clear"
.4byte 0x01807fd7  # vsetvli t6, zero, e64, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x1e1e3f37  # lui t5, 0x1e1e3
.4byte 0xd2df0f13  # addi t5, t5, -723
.4byte 0x01e2e2b3  # or t0, t0, t5
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x3ff802b7  # lui t0, 0x3ff80
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x1 "VL equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e821857  # vfrsqrt7.v v16, v8
.assert trap == 0 "vfrsqrt7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fea000000000000 "e64 vfrsqrt7.v 1.5"
.4byte 0x4e829857  # vfrec7.v v16, v8
.assert trap == 0 "vfrec7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fe5400000000000 "e64 vfrec7.v 1.5"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e64 estimates on 1.5 clear flags"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c1e1e2d2d "e64 estimate tail lane 1 preserved"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e829857  # vfrec7.v v16, v8
.assert trap == 0 "vfrec7.v retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7ff0000000000000 "e64 vfrec7.v tiny subnormal overflows to +inf"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x5 "e64 vfrec7.v overflow raises OF|NX"
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xbff002b7  # lui t0, 0xbff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e821857  # vfrsqrt7.v v16, v8
.assert trap == 0 "vfrsqrt7.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7ff8000000000000 "e64 vfrsqrt7.v -1.0 yields canonical qNaN"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xfff0000000000000 "e64 vfrsqrt7.v -0.0 yields -inf"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x18 "e64 vfrsqrt7.v -1.0 and -0.0 raise NV|DZ"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4ea21857  # vfrsqrt7.v v16, v10
.assert trap == 0 "vfrsqrt7.v retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fe6800000000000 "vl=VLMAX e64 vfrsqrt7.v 2.0"
.4byte 0x4ea29857  # vfrec7.v v16, v10
.assert trap == 0 "vfrec7.v retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fdfe00000000000 "vl=VLMAX e64 vfrec7.v 2.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "vl=VLMAX e64 estimates clear flags"

# Section 4: vfmin and vfmax across signed zeros, qNaN, sNaN, and NaN-boxing.
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0xc04002b7  # lui t0, 0xc0400
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0xbf8002b7  # lui t0, 0xbf800
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3ba2e4d7  # vslide1up.vx v9, v26, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x12849857  # vfmin.vv v16, v8, v9
.assert trap == 0 "vfmin.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80000000 "vfmin(-0.0, +0.0) == -0.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80000000 "vfmin(+0.0, -0.0) == -0.0"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0400000 "vfmin(-3.0, -1.0) == -3.0"
.4byte 0x1a849857  # vfmax.vv v16, v8, v9
.assert trap == 0 "vfmax.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x0 "vfmax(-0.0, +0.0) == +0.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x0 "vfmax(+0.0, -0.0) == +0.0"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffbf800000 "vfmax(-3.0, -1.0) == -1.0"
.4byte 0x12805857  # vfmin.vf v16, v8, ft0
.assert trap == 0 "vfmin.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffff80000000 "vfmin.vf(-0.0, +0.0) == -0.0"
.4byte 0x1a805857  # vfmax.vf v16, v8, ft0
.assert trap == 0 "vfmax.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x0 "vfmax.vf(-0.0, +0.0) == +0.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "signed-zero min/max clear flags"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x4 "VL equals 4"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "e32 min/max tail lane 3 preserved"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x7fc002b7  # lui t0, 0x7fc00
.4byte 0x45628293  # addi t0, t0, 1110
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x7fc002b7  # lui t0, 0x7fc00
.4byte 0x12328293  # addi t0, t0, 291
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x7fc002b7  # lui t0, 0x7fc00
.4byte 0x78928293  # addi t0, t0, 1929
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x3fc002b7  # lui t0, 0x3fc00
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x12849857  # vfmin.vv v16, v8, v9
.assert trap == 0 "vfmin.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fc00000 "vfmin(qNaN, 1.5) == 1.5"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "vfmin(qNaN, qNaN) == canonical qNaN"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "qNaN min leaves flags clear"
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x3fc002b7  # lui t0, 0x3fc00
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3fc002b7  # lui t0, 0x3fc00
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x402002b7  # lui t0, 0x40200
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x10849857  # vfmin.vv v16, v8, v9, v0.t
.assert trap == 0 "vfmin.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fc00000 "masked vfmin.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "masked-off sNaN lane 1 preserved"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "masked-off sNaN leaves NV clear"
.4byte 0x1a849857  # vfmax.vv v16, v8, v9
.assert trap == 0 "vfmax.vv retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fc00000 "vfmax(sNaN, 1.5) == 1.5"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x10 "active sNaN in vfmax raises NV"
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xc2c60f37  # lui t5, 0xc2c60
.4byte 0x020f1f13  # slli t5, t5, 32
.4byte 0x020f5f13  # srli t5, t5, 32
.4byte 0x01e2e2b3  # or t0, t0, t5
.4byte 0xf20280d3  # fmv.d.x ft1, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x1290d857  # vfmin.vf v16, v9, ft1
.assert trap == 0 "vfmin.vf retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x3fc00000 "improperly NaN-boxed scalar acts as qNaN in vfmin.vf"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "unboxed qNaN in vfmin.vf leaves flags clear"
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x12849857  # vfmin.vv v16, v8, v9
.assert trap == 0 "vfmin.vv retires"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "vl=0 vfmin.vv sNaN leaves flags clear"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x40a002b7  # lui t0, 0x40a00
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0x1aa05857  # vfmax.vf v16, v10, ft0
.assert trap == 0 "vfmax.vf retires"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40a00000 "vl=VLMAX e32 vfmax.vf lane 3"
.4byte 0x01807fd7  # vsetvli t6, zero, e64, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x1e1e3f37  # lui t5, 0x1e1e3
.4byte 0xd2df0f13  # addi t5, t5, -723
.4byte 0x01e2e2b3  # or t0, t0, t5
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x7ff002b7  # lui t0, 0x7ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x400802b7  # lui t0, 0x40080
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xf2028053  # fmv.d.x ft0, t0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x1 "VL equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x12849857  # vfmin.vv v16, v8, v9
.assert trap == 0 "vfmin.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x8000000000000000 "e64 vfmin(-0.0, +0.0) == -0.0"
.4byte 0x12805857  # vfmin.vf v16, v8, ft0
.assert trap == 0 "vfmin.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x8000000000000000 "e64 vfmin.vf(-0.0, +0.0) == -0.0"
.4byte 0x1a849857  # vfmax.vv v16, v8, v9
.assert trap == 0 "vfmax.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x0 "e64 vfmax(-0.0, +0.0) == +0.0"
.4byte 0x1a805857  # vfmax.vf v16, v8, ft0
.assert trap == 0 "vfmax.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x0 "e64 vfmax.vf(-0.0, +0.0) == +0.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e64 min/max tail sNaN leaves flags clear"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c1e1e2d2d "e64 min/max tail lane 1 preserved"
.4byte 0x12849857  # vfmin.vv v16, v8, v9
.assert trap == 0 "vfmin.vv retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4008000000000000 "e64 vfmin(sNaN, 3.0) == 3.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x10 "e64 vfmin sNaN raises NV"

# Section 5: vfsgnj, vfsgnjn, and vfsgnjx preserving NaN payloads without flags.
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0xffc002b7  # lui t0, 0xffc00
.4byte 0x45628293  # addi t0, t0, 1110
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x12328293  # addi t0, t0, 291
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0xbf8002b7  # lui t0, 0xbf800
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0xbf8002b7  # lui t0, 0xbf800
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x22849857  # vfsgnj.vv v16, v8, v9
.assert trap == 0 "vfsgnj.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff800123 "e32 vfsgnj.vv preserves sNaN payload with neg sign"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00456 "e32 vfsgnj.vv preserves qNaN payload with pos sign"
.4byte 0x22805857  # vfsgnj.vf v16, v8, ft0
.assert trap == 0 "vfsgnj.vf retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffffc00456 "e32 vfsgnj.vf sets neg sign"
.4byte 0x26849857  # vfsgnjn.vv v16, v8, v9
.assert trap == 0 "vfsgnjn.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800123 "e32 vfsgnjn.vv negates neg sign to pos"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffffc00456 "e32 vfsgnjn.vv negates pos sign to neg"
.4byte 0x26805857  # vfsgnjn.vf v16, v8, ft0
.assert trap == 0 "vfsgnjn.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800123 "e32 vfsgnjn.vf negates scalar sign"
.4byte 0x2a849857  # vfsgnjx.vv v16, v8, v9
.assert trap == 0 "vfsgnjx.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff800123 "e32 vfsgnjx.vv 0 xor 1 = 1"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffffc00456 "e32 vfsgnjx.vv 1 xor 0 = 1"
.4byte 0x2a805857  # vfsgnjx.vf v16, v8, ft0
.assert trap == 0 "vfsgnjx.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff800123 "e32 vfsgnjx.vf 0 xor 1 = 1"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00456 "e32 vfsgnjx.vf 1 xor 1 = 0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e32 sign-injection on sNaN leaves flags clear"
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xbf800f37  # lui t5, 0xbf800
.4byte 0x020f1f13  # slli t5, t5, 32
.4byte 0x020f5f13  # srli t5, t5, 32
.4byte 0x01e2e2b3  # or t0, t0, t5
.4byte 0xf20280d3  # fmv.d.x ft1, t0
.4byte 0x2280d857  # vfsgnj.vf v16, v8, ft1
.assert trap == 0 "vfsgnj.vf retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00456 "improperly NaN-boxed scalar supplies sign 0 of canonical qNaN"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "e32 sign-injection tail lane 2 preserved"
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x24849857  # vfsgnjn.vv v16, v8, v9, v0.t
.assert trap == 0 "vfsgnjn.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800123 "masked e32 vfsgnjn.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "masked-off e32 vfsgnjn.vv lane 1 preserved"
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x22849857  # vfsgnj.vv v16, v8, v9
.assert trap == 0 "vfsgnj.vv retires"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800123 "vl=0 vfsgnj.vv preserves lane 0"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x2a805857  # vfsgnjx.vf v16, v8, ft0
.assert trap == 0 "vfsgnjx.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffff800123 "vl=VLMAX e32 vfsgnjx.vf lane 0"
.4byte 0x01807fd7  # vsetvli t6, zero, e64, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x1e1e3f37  # lui t5, 0x1e1e3
.4byte 0xd2df0f13  # addi t5, t5, -723
.4byte 0x01e2e2b3  # or t0, t0, t5
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0xc00002b7  # lui t0, 0xc0000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x7ff002b7  # lui t0, 0x7ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x12328293  # addi t0, t0, 291
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x3ff002b7  # lui t0, 0x3ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0xbff002b7  # lui t0, 0xbff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0xbff002b7  # lui t0, 0xbff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xf2028053  # fmv.d.x ft0, t0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x1 "VL equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x22849857  # vfsgnj.vv v16, v8, v9
.assert trap == 0 "vfsgnj.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xfff0000000000123 "e64 vfsgnj.vv"
.4byte 0x22805857  # vfsgnj.vf v16, v8, ft0
.assert trap == 0 "vfsgnj.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xfff0000000000123 "e64 vfsgnj.vf"
.4byte 0x26849857  # vfsgnjn.vv v16, v8, v9
.assert trap == 0 "vfsgnjn.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7ff0000000000123 "e64 vfsgnjn.vv"
.4byte 0x26805857  # vfsgnjn.vf v16, v8, ft0
.assert trap == 0 "vfsgnjn.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7ff0000000000123 "e64 vfsgnjn.vf"
.4byte 0x2a849857  # vfsgnjx.vv v16, v8, v9
.assert trap == 0 "vfsgnjx.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xfff0000000000123 "e64 vfsgnjx.vv"
.4byte 0x2a805857  # vfsgnjx.vf v16, v8, ft0
.assert trap == 0 "vfsgnjx.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xfff0000000000123 "e64 vfsgnjx.vf"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e64 sign-injection on sNaN leaves flags clear"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c1e1e2d2d "e64 sign-injection tail lane 1 preserved"

# Section 6: vfclass.v covering all ten IEEE-754 classes at binary32 and binary64.
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xc00002b7  # lui t0, 0xc0000
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0xff8002b7  # lui t0, 0xff800
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e881857  # vfclass.v v16, v8
.assert trap == 0 "vfclass.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x1 "e32 vfclass -inf"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x2 "e32 vfclass -normal"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4 "e32 vfclass -subnormal"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x4 "VL equals 4"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "e32 vfclass tail lane 3 preserved"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x4e881857  # vfclass.v v16, v8
.assert trap == 0 "vfclass.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x8 "e32 vfclass -0.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x10 "e32 vfclass +0.0"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x20 "e32 vfclass +subnormal"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40 "e32 vfclass +normal"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0xffc002b7  # lui t0, 0xffc00
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xff8002b7  # lui t0, 0xff800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x4e881857  # vfclass.v v16, v8
.assert trap == 0 "vfclass.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x80 "e32 vfclass +inf"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x100 "e32 vfclass neg sNaN"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x200 "e32 vfclass neg qNaN"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e32 vfclass.v on sNaN leaves flags clear"
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x4c881857  # vfclass.v v16, v8, v0.t
.assert trap == 0 "vfclass.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x80 "masked e32 vfclass.v lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "masked-off e32 vfclass.v lane 1 preserved"
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x4e881857  # vfclass.v v16, v8
.assert trap == 0 "vfclass.v retires"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x80 "vl=0 vfclass.v preserves lane 0"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x4 "VL equals 4"
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0xbff802b7  # lui t0, 0xbff80
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0xfff002b7  # lui t0, 0xfff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4e881857  # vfclass.v v16, v8
.assert trap == 0 "vfclass.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x1 "e64 vfclass -inf"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x2 "e64 vfclass -normal"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4 "e64 vfclass -subnormal"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x8 "e64 vfclass -0.0"
.4byte 0x7ff002b7  # lui t0, 0x7ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x3ff802b7  # lui t0, 0x3ff80
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x4e881857  # vfclass.v v16, v8
.assert trap == 0 "vfclass.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x10 "e64 vfclass +0.0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x20 "e64 vfclass +subnormal"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40 "e64 vfclass +normal"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x80 "e64 vfclass +inf"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x7ff802b7  # lui t0, 0x7ff80
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x7ff002b7  # lui t0, 0x7ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x4e881857  # vfclass.v v16, v8
.assert trap == 0 "vfclass.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x100 "e64 vfclass sNaN"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x200 "e64 vfclass qNaN"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e64 vfclass.v on sNaN leaves flags clear"

# Section 7: vfmerge.vfm, vfmv.v.f, vfmv.s.f, and vfmv.f.s at binary32 and binary64.
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0x404002b7  # lui t0, 0x40400
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0xc08002b7  # lui t0, 0xc0800
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x5c805857  # vfmerge.vfm v16, v8, ft0, v0
.assert trap == 0 "vfmerge.vfm retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0800000 "e32 vfmerge.vfm lane 0 selects scalar"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800001 "e32 vfmerge.vfm lane 1 keeps vs2 sNaN"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0800000 "e32 vfmerge.vfm lane 2 selects scalar"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e32 vfmerge.vfm with sNaN leaves flags clear"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x4 "VL equals 4"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "e32 vfmerge.vfm tail lane 3 preserved"
.4byte 0x412002b7  # lui t0, 0x41200
.4byte 0xf20280d3  # fmv.d.x ft1, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x5c80d857  # vfmerge.vfm v16, v8, ft1, v0
.assert trap == 0 "vfmerge.vfm retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "vfmerge.vfm unboxes bad scalar to qNaN"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7f800001 "vfmerge.vfm keeps vs2 on mask=0"
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x5e005857  # vfmv.v.f v16, ft0
.assert trap == 0 "vfmv.v.f retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0800000 "e32 vfmv.v.f lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0800000 "e32 vfmv.v.f lane 1"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x3 "VL equals 3"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "e32 vfmv.v.f tail lane 2 preserved"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x5e00d857  # vfmv.v.f v16, ft1
.assert trap == 0 "vfmv.v.f retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "e32 vfmv.v.f unboxes bad scalar to qNaN"
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x5e005857  # vfmv.v.f v16, ft0
.assert trap == 0 "vfmv.v.f retires"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "vl=0 vfmv.v.f preserves lane 0"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x5e005857  # vfmv.v.f v16, ft0
.assert trap == 0 "vfmv.v.f retires"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0800000 "vl=VLMAX e32 vfmv.v.f lane 3"
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x42005857  # vfmv.s.f v16, ft0
.assert trap == 0 "vfmv.s.f retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0800000 "e32 vfmv.s.f writes lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "e32 vfmv.s.f leaves lane 1 undisturbed"
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x4200d857  # vfmv.s.f v16, ft1
.assert trap == 0 "vfmv.s.f retires"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0800000 "vl=0 vfmv.s.f preserves lane 0"
.4byte 0x4200d857  # vfmv.s.f v16, ft1
.assert trap == 0 "vfmv.s.f retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x7fc00000 "e32 vfmv.s.f unboxes bad scalar to qNaN"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x42005857  # vfmv.s.f v16, ft0
.assert trap == 0 "vfmv.s.f retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xffffffffc0800000 "vl=VLMAX e32 vfmv.s.f writes lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "vl=VLMAX e32 vfmv.s.f keeps lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x1 "VL equals 1"
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x4202e857  # vmv.s.x v16, t0
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x43001157  # vfmv.f.s ft2, v16
.assert trap == 0 "vfmv.f.s retires"
.4byte 0xe2010553  # fmv.x.d a0, ft2
.assert rd_addr == 10 "fmv.x.d writes x10"
.assert rd_wdata == 0xffffffff7f800001 "e32 vfmv.f.s at vl=0 NaN-boxes sNaN"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e32 merge/moves leave flags clear"
.4byte 0x01807fd7  # vsetvli t6, zero, e64, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x1e1e3f37  # lui t5, 0x1e1e3
.4byte 0xd2df0f13  # addi t5, t5, -723
.4byte 0x01e2e2b3  # or t0, t0, t5
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x402002b7  # lui t0, 0x40200
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x401c02b7  # lui t0, 0x401c0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0xc02302b7  # lui t0, 0xc0230
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xf2028053  # fmv.d.x ft0, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x1 "VL equals 1"
.4byte 0x5c805857  # vfmerge.vfm v16, v8, ft0, v0
.assert trap == 0 "vfmerge.vfm retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xc023000000000000 "e64 vfmerge.vfm lane 0"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c1e1e2d2d "e64 vfmerge.vfm tail lane 1 preserved"
.4byte 0x5c805857  # vfmerge.vfm v16, v8, ft0, v0
.assert trap == 0 "vfmerge.vfm retires"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4020000000000000 "e64 vfmerge.vfm mask=0 selects vs2"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x1 "VL equals 1"
.4byte 0x5e005857  # vfmv.v.f v16, ft0
.assert trap == 0 "vfmv.v.f retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xc023000000000000 "e64 vfmv.v.f lane 0"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4020000000000000 "e64 vfmv.v.f tail lane 1 preserved"
.4byte 0x402882b7  # lui t0, 0x40288
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xf2028153  # fmv.d.x ft2, t0
.4byte 0x42015857  # vfmv.s.f v16, ft2
.assert trap == 0 "vfmv.s.f retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4028800000000000 "e64 vfmv.s.f lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x4020000000000000 "e64 vfmv.s.f lane 1 preserved"
.4byte 0xc1807657  # vsetivli a2, 0, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x430011d7  # vfmv.f.s ft3, v16
.assert trap == 0 "vfmv.f.s retires"
.4byte 0xe2018553  # fmv.x.d a0, ft3
.assert rd_addr == 10 "fmv.x.d writes x10"
.assert rd_wdata == 0x4028800000000000 "e64 vfmv.f.s at vl=0 reads lane 0"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5c805857  # vfmerge.vfm v16, v8, ft0, v0
.assert trap == 0 "vfmerge.vfm retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xc023000000000000 "vl=VLMAX e64 vfmerge.vfm lane 0"
.4byte 0xc1807657  # vsetivli a2, 0, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x0 "VL equals 0"
.4byte 0x5c815857  # vfmerge.vfm v16, v8, ft2, v0
.assert trap == 0 "vfmerge.vfm retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0xc023000000000000 "vl=0 vfmerge.vfm preserves lane 0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "e64 merge/moves leave flags clear"

# Section 8: fractional LMUL (e32, mf2), multi-register LMUL (e32, m2), and ta/ma.
.4byte 0x01007fd7  # vsetvli t6, zero, e32, m1, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x40c002b7  # lui t0, 0x40c00
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x408002b7  # lui t0, 0x40800
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x3fc002b7  # lui t0, 0x3fc00
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x1 "VL equals 1"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x0a849857  # vfsub.vv v16, v8, v9
.assert trap == 0 "vfsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40900000 "e32 mf2 vfsub.vv lane 0"
.4byte 0xc1717657  # vsetivli a2, 2, e32, mf2, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "e32 mf2 tail lane 1 preserved"
.4byte 0x01107fd7  # vsetvli t6, zero, e32, m2, tu, mu
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x5 "VL equals 5"
.4byte 0x40a002b7  # lui t0, 0x40a00
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x408002b7  # lui t0, 0x40800
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x404002b7  # lui t0, 0x40400
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x3ba2e457  # vslide1up.vx v8, v26, t0
.4byte 0x412002b7  # lui t0, 0x41200
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0x02805857  # vfadd.vf v16, v8, ft0
.assert trap == 0 "vfadd.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x41300000 "e32 m2 vfadd.vf lane 0"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x41700000 "e32 m2 vfadd.vf lane 4 across group boundary"
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x6 "VL equals 6"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "e32 m2 tail lane 5 preserved"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x411002b7  # lui t0, 0x41100
.4byte 0x3a82ed57  # vslide1up.vx v26, v8, t0
.4byte 0x5e0d0457  # vmv.v.v v8, v26
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x3a92ed57  # vslide1up.vx v26, v9, t0
.4byte 0x5e0d04d7  # vmv.v.v v9, v26
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0xcd017657  # vsetivli a2, 2, e32, m1, ta, ma
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x08849857  # vfsub.vv v16, v8, v9, v0.t
.assert trap == 0 "vfsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x40e00000 "ta/ma masked vfsub.vv active lane 0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "ta/ma masked-off inf - inf leaves flags clear"

# Section 9: illegal single-width FP instruction traps (mcause == 2).
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x5a5a42b7  # lui t0, 0x5a5a4
.4byte 0xc3c28293  # addi t0, t0, -964
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x02849857  # vfadd.vv v16, v8, v9
.assert trap == 1 "vfadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mcause writes x10"
.assert rd_wdata == 0x2 "e8 vfadd.vv raises illegal instruction"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "trapping e8 vfadd.vv leaves v16 unchanged"
.4byte 0x0022d073  # csrwi frm, 5
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x5 "frm readback equals 5"
.4byte 0x0a849857  # vfsub.vv v16, v8, v9
.assert trap == 1 "vfsub.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mcause writes x10"
.assert rd_wdata == 0x2 "reserved frm=5 raises illegal instruction"
.4byte 0x00205073  # csrwi frm, 0
.4byte 0x00202573  # csrr a0, frm
.assert rd_addr == 10 "frm writes x10"
.assert rd_wdata == 0x0 "frm readback equals 0"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "element read writes x10"
.assert rd_wdata == 0x5a5a3c3c "trapping frm=5 vfsub.vv leaves v16 unchanged"
.4byte 0x10849057  # vfmin.vv v0, v8, v9, v0.t
.assert trap == 1 "vfmin.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mcause writes x10"
.assert rd_wdata == 0x2 "masked vd==v0 raises illegal instruction"
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x028518d7  # vfadd.vv v17, v8, v10
.assert trap == 1 "vfadd.vv traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mcause writes x10"
.assert rd_wdata == 0x2 "misaligned m2 vfadd.vv raises illegal instruction"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli writes x12"
.assert rd_wdata == 0x2 "VL equals 2"
.4byte 0x5e805857  # reserved vfmv.v.f vs2=v8
.assert trap == 1 "vfmv.v.f traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mcause writes x10"
.assert rd_wdata == 0x2 "vfmv.v.f with vs2!=0 raises illegal instruction"
.4byte 0x40005857  # reserved vfmv.s.f vm=0
.assert trap == 1 "vfmv.s.f traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mcause writes x10"
.assert rd_wdata == 0x2 "masked vfmv.s.f raises illegal instruction"
