# Single-width vector fused multiply-add results and accrued flags.
.noshrink
# Enable FS and VS and select RNE.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x00305073  # csrwi fcsr, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "VL writes x12"
.assert rd_wdata == 0x2 "e32 VL is 2"

# Binary32 (1 + 2^-23) * (1 - 2^-23) - 1 has exact residual -2^-46.
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x3f800337  # lui t1, 0x3f800
.4byte 0xffe30313  # addi t1, t1, -2
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xbf8003b7  # lui t2, 0xbf800
.4byte 0x5e03cb57  # vmv.v.x v22, t2
.4byte 0xb2941b57  # vfmacc.vv v22, v8, v9
.assert trap == 0 "binary32 fused accumulate retires"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xffffffffa8800000 "binary32 fused residual is -2^-46"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "binary32 fused residual raises no flags"

# Binary32 destructive forms with vs1 or fs1 = 2, vs2 = 3, old vd = 4.
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x408003b7  # lui t2, 0x40800
.4byte 0xf0028053  # fmv.w.x ft0, t0
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xb2941857  # vfmacc.vv v16, v8, v9
.assert trap == 0 "binary32 vfmacc.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x41200000 "binary32 vfmacc.vv yields 10"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xb6941857  # vfnmacc.vv v16, v8, v9
.assert trap == 0 "binary32 vfnmacc.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xffffffffc1200000 "binary32 vfnmacc.vv yields -10"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xba941857  # vfmsac.vv v16, v8, v9
.assert trap == 0 "binary32 vfmsac.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x40000000 "binary32 vfmsac.vv yields 2"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xbe941857  # vfnmsac.vv v16, v8, v9
.assert trap == 0 "binary32 vfnmsac.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xffffffffc0000000 "binary32 vfnmsac.vv yields -2"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xa2941857  # vfmadd.vv v16, v8, v9
.assert trap == 0 "binary32 vfmadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x41300000 "binary32 vfmadd.vv yields 11"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xa6941857  # vfnmadd.vv v16, v8, v9
.assert trap == 0 "binary32 vfnmadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xffffffffc1300000 "binary32 vfnmadd.vv yields -11"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xaa941857  # vfmsub.vv v16, v8, v9
.assert trap == 0 "binary32 vfmsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x40a00000 "binary32 vfmsub.vv yields 5"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xae941857  # vfnmsub.vv v16, v8, v9
.assert trap == 0 "binary32 vfnmsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xffffffffc0a00000 "binary32 vfnmsub.vv yields -5"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xb2905857  # vfmacc.vf v16, ft0, v9
.assert trap == 0 "binary32 vfmacc.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x41200000 "binary32 vfmacc.vf yields 10"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xb6905857  # vfnmacc.vf v16, ft0, v9
.assert trap == 0 "binary32 vfnmacc.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xffffffffc1200000 "binary32 vfnmacc.vf yields -10"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xba905857  # vfmsac.vf v16, ft0, v9
.assert trap == 0 "binary32 vfmsac.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x40000000 "binary32 vfmsac.vf yields 2"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xbe905857  # vfnmsac.vf v16, ft0, v9
.assert trap == 0 "binary32 vfnmsac.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xffffffffc0000000 "binary32 vfnmsac.vf yields -2"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xa2905857  # vfmadd.vf v16, ft0, v9
.assert trap == 0 "binary32 vfmadd.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x41300000 "binary32 vfmadd.vf yields 11"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xa6905857  # vfnmadd.vf v16, ft0, v9
.assert trap == 0 "binary32 vfnmadd.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xffffffffc1300000 "binary32 vfnmadd.vf yields -11"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xaa905857  # vfmsub.vf v16, ft0, v9
.assert trap == 0 "binary32 vfmsub.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x40a00000 "binary32 vfmsub.vf yields 5"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xae905857  # vfnmsub.vf v16, ft0, v9
.assert trap == 0 "binary32 vfnmsub.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xffffffffc0a00000 "binary32 vfnmsub.vf yields -5"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "exact binary32 forms raise no flags"

# Binary64 (1 + 2^-52) * (1 - 2^-52) - 1 has exact residual -2^-104.
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "VL writes x12"
.assert rd_wdata == 0x2 "e64 VL is 2"
.4byte 0x3ff002b7  # lui t0, 0x3ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0xf2028053  # fmv.d.x ft0, t0
.4byte 0x3ff00337  # lui t1, 0x3ff00
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xffe30313  # addi t1, t1, -2
.4byte 0x5e034bd7  # vmv.v.x v23, t1
.4byte 0xbff003b7  # lui t2, 0xbff00
.4byte 0x02039393  # slli t2, t2, 32
.4byte 0x5e03c557  # vmv.v.x v10, t2
.4byte 0xa2a05bd7  # vfmadd.vf v23, ft0, v10
.assert trap == 0 "binary64 fused multiply-add retires"
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xb970000000000000 "binary64 fused residual is -2^-104"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "binary64 fused residual raises no flags"

# Binary64 destructive forms with vs1 or fs1 = 2, vs2 = 3, old vd = 4.
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x40080337  # lui t1, 0x40080
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x401003b7  # lui t2, 0x40100
.4byte 0x02039393  # slli t2, t2, 32
.4byte 0xf2028053  # fmv.d.x ft0, t0
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xb2941857  # vfmacc.vv v16, v8, v9
.assert trap == 0 "binary64 vfmacc.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x4024000000000000 "binary64 vfmacc.vv yields 10"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xb6941857  # vfnmacc.vv v16, v8, v9
.assert trap == 0 "binary64 vfnmacc.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xc024000000000000 "binary64 vfnmacc.vv yields -10"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xba941857  # vfmsac.vv v16, v8, v9
.assert trap == 0 "binary64 vfmsac.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x4000000000000000 "binary64 vfmsac.vv yields 2"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xbe941857  # vfnmsac.vv v16, v8, v9
.assert trap == 0 "binary64 vfnmsac.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xc000000000000000 "binary64 vfnmsac.vv yields -2"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xa2941857  # vfmadd.vv v16, v8, v9
.assert trap == 0 "binary64 vfmadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x4026000000000000 "binary64 vfmadd.vv yields 11"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xa6941857  # vfnmadd.vv v16, v8, v9
.assert trap == 0 "binary64 vfnmadd.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xc026000000000000 "binary64 vfnmadd.vv yields -11"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xaa941857  # vfmsub.vv v16, v8, v9
.assert trap == 0 "binary64 vfmsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x4014000000000000 "binary64 vfmsub.vv yields 5"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xae941857  # vfnmsub.vv v16, v8, v9
.assert trap == 0 "binary64 vfnmsub.vv retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xc014000000000000 "binary64 vfnmsub.vv yields -5"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xb2905857  # vfmacc.vf v16, ft0, v9
.assert trap == 0 "binary64 vfmacc.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x4024000000000000 "binary64 vfmacc.vf yields 10"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xb6905857  # vfnmacc.vf v16, ft0, v9
.assert trap == 0 "binary64 vfnmacc.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xc024000000000000 "binary64 vfnmacc.vf yields -10"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xba905857  # vfmsac.vf v16, ft0, v9
.assert trap == 0 "binary64 vfmsac.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x4000000000000000 "binary64 vfmsac.vf yields 2"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xbe905857  # vfnmsac.vf v16, ft0, v9
.assert trap == 0 "binary64 vfnmsac.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xc000000000000000 "binary64 vfnmsac.vf yields -2"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xa2905857  # vfmadd.vf v16, ft0, v9
.assert trap == 0 "binary64 vfmadd.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x4026000000000000 "binary64 vfmadd.vf yields 11"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xa6905857  # vfnmadd.vf v16, ft0, v9
.assert trap == 0 "binary64 vfnmadd.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xc026000000000000 "binary64 vfnmadd.vf yields -11"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xaa905857  # vfmsub.vf v16, ft0, v9
.assert trap == 0 "binary64 vfmsub.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x4014000000000000 "binary64 vfmsub.vf yields 5"
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0xae905857  # vfnmsub.vf v16, ft0, v9
.assert trap == 0 "binary64 vfnmsub.vf retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0xc014000000000000 "binary64 vfnmsub.vf yields -5"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "exact binary64 forms raise no flags"

# Lane zero computes 2 * 3 + 1. Lane one would compute 0 * Inf + 1.
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "VL writes x12"
.assert rd_wdata == 0x2 "e32 VL is 2"
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x7f800337  # lui t1, 0x7f800
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x40400337  # lui t1, 0x40400
.4byte 0x420364d7  # vmv.s.x v9, t1
.4byte 0x3f8003b7  # lui t2, 0x3f800
.4byte 0x5e03c657  # vmv.v.x v12, t2
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
# Use agnostic policies and observe only the enabled result and accrued flags.
.4byte 0xcd017657  # vsetivli a2, 2, e32, m1, ta, ma
.assert rd_addr == 12 "VL writes x12"
.assert rd_wdata == 0x2 "e32 VL is 2"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0xb0941657  # vfmacc.vv v12, v8, v9, v0.t
.assert trap == 0 "masked binary32 fused accumulate retires"
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x40e00000 "enabled fused result is 7.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x0 "masked 0 * Inf raises no flags"

# Restore the addend before enabling the formerly masked lane.
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "VL writes x12"
.assert rd_wdata == 0x2 "e32 VL is 2"
.4byte 0x5e03c657  # vmv.v.x v12, t2
.4byte 0xb2941657  # vfmacc.vv v12, v8, v9
.assert trap == 0 "unmasked binary32 fused accumulate retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "fflags writes x11"
.assert rd_wdata == 0x10 "active 0 * Inf raises NV"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.assert rd_addr == 12 "VL writes x12"
.assert rd_wdata == 0x1 "e32 VL is 1"
.4byte 0x3ec0bad7  # vslidedown.vi v21, v12, 1
.4byte 0x43502557  # vmv.x.s a0, v21
.assert rd_addr == 10 "vector element writes x10"
.assert rd_wdata == 0x7fc00000 "active invalid fused result is canonical NaN"

# The exact binary32 fused result 1 * 1 + 2^-24 lies halfway above 1.
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "binary32 VL writes x12"
.assert rd_wdata == 0x2 "binary32 VL is two"
.4byte 0x00305073  # csrwi fcsr, 0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x338002b7  # lui t0, 0x33800
.4byte 0x5e02c857  # vmv.v.x v16, t0

# RNE selects the even significand and raises inexact.
.4byte 0xb2941857  # vfmacc.vv v16, v8, v9
.assert trap == 0 "RNE fused accumulate retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "RNE fused result writes x10"
.assert rd_wdata == 0x3f800000 "RNE rounds the fused result to 1.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "RNE fflags writes x11"
.assert rd_wdata == 0x1 "RNE fused result raises NX"

# RUP selects the next value above 1 and raises inexact.
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x00202673  # csrr a2, frm
.assert rd_addr == 12 "frm writes x12"
.assert rd_wdata == 0x3 "frm selects RUP"
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0xb2941857  # vfmacc.vv v16, v8, v9
.assert trap == 0 "RUP fused accumulate retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "RUP fused result writes x10"
.assert rd_wdata == 0x3f800001 "RUP rounds the fused result above 1.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "RUP fflags writes x11"
.assert rd_wdata == 0x1 "RUP fused result raises NX"
.4byte 0x00205073  # csrwi frm, 0
