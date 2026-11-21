# Base floating-point results and flags at VLEN 128, 256 and 512.
.noshrink
# Enable FS and VS and select binary32 with two active elements.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x00305073  # csrwi fcsr, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "binary32 VL writes x12"
.assert rd_wdata == 0x2 "binary32 VL is two"

# Exact binary32 addition, 1.0 + 2.0.
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x028498d7  # vfadd.vv v17, v8, v9
.assert trap == 0 "exact binary32 add retires"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "exact binary32 sum writes x10"
.assert rd_wdata == 0x40400000 "exact binary32 sum is 3.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "exact binary32 flags write x11"
.assert rd_wdata == 0x0 "exact binary32 add raises no flags"

# Round the halfway value 1.0 + 2^-24 with RNE and RUP.
.4byte 0x338002b7  # lui t0, 0x33800
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x02849957  # vfadd.vv v18, v8, v9
.assert trap == 0 "RNE binary32 add retires"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "RNE binary32 sum writes x10"
.assert rd_wdata == 0x3f800000 "RNE rounds halfway to 1.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "RNE binary32 flags write x11"
.assert rd_wdata == 0x1 "RNE halfway raises NX"
.4byte 0x0021d073  # csrwi frm, 3
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x02849957  # vfadd.vv v18, v8, v9
.assert trap == 0 "RUP binary32 add retires"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "RUP binary32 sum writes x10"
.assert rd_wdata == 0x3f800001 "RUP rounds halfway above 1.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "RUP binary32 flags write x11"
.assert rd_wdata == 0x1 "RUP halfway raises NX"
.4byte 0x00205073  # csrwi frm, 0

# Element zero is finite and element one is a signaling NaN.
.4byte 0x7f8002b7  # lui t0, 0x7f800
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x4202e4d7  # vmv.s.x v9, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0xcd017057  # vsetivli zero, 2, e32, m1, ta, ma
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x00849a57  # vfadd.vv v20, v8, v9, v0.t
.assert trap == 0 "masked binary32 add retires"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "masked binary32 sum writes x10"
.assert rd_wdata == 0x40000000 "enabled element sums to 2.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "masked binary32 flags write x11"
.assert rd_wdata == 0x0 "masked signaling NaN raises no flags"

# The same operand raises NV when enabled. Read its now-active result.
.4byte 0xc1017057  # vsetivli zero, 2, e32, m1, tu, mu
.4byte 0x02849a57  # vfadd.vv v20, v8, v9
.assert trap == 0 "unmasked binary32 add retires"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "unmasked binary32 flags write x11"
.assert rd_wdata == 0x10 "active signaling NaN raises NV"
.4byte 0xc100f057  # vsetivli zero, 1, e32, m1, tu, mu
.4byte 0x3f40bad7  # vslidedown.vi v21, v20, 1
.4byte 0x43502557  # vmv.x.s a0, v21
.assert rd_addr == 10 "binary32 NaN readout writes x10"
.assert rd_wdata == 0x7fc00000 "active signaling NaN yields canonical NaN"

# Binary64 scalar multiply. Exact arithmetic preserves the accrued NV flag.
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "binary64 VL writes x12"
.assert rd_wdata == 0x1 "binary64 VL is one"
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x03e31313  # slli t1, t1, 62
.4byte 0xf2030053  # fmv.d.x ft0, t1
.4byte 0x3ff802b7  # lui t0, 0x3ff80
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x92805957  # vfmul.vf v18, v8, ft0
.assert trap == 0 "exact binary64 multiply retires"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "exact binary64 product writes x10"
.assert rd_wdata == 0x4008000000000000 "1.5 times 2.0 is 3.0"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "exact binary64 flags write x11"
.assert rd_wdata == 0x10 "exact binary64 multiply preserves NV"

# Double the largest binary64 power of two.
.4byte 0x7fe002b7  # lui t0, 0x7fe00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x92805957  # vfmul.vf v18, v8, ft0
.assert trap == 0 "overflowing binary64 multiply retires"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "overflow result writes x10"
.assert rd_wdata == 0x7ff0000000000000 "binary64 overflow gives positive infinity"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "overflow flags write x11"
.assert rd_wdata == 0x15 "overflow accrues OF and NX alongside NV"

# Halve the smallest positive binary64 subnormal under RNE.
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x3fe002b7  # lui t0, 0x3fe00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xf2028053  # fmv.d.x ft0, t0
.4byte 0x5e00b457  # vmv.v.i v8, 1
.4byte 0x92805957  # vfmul.vf v18, v8, ft0
.assert trap == 0 "underflowing binary64 multiply retires"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "underflow result writes x10"
.assert rd_wdata == 0x0 "binary64 halfway subnormal rounds to positive zero"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "underflow flags write x11"
.assert rd_wdata == 0x3 "binary64 underflow raises UF and NX"

# Divide 1.0 by positive zero and check sticky flags before clearing.
.4byte 0x3ff002b7  # lui t0, 0x3ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xf2000053  # fmv.d.x ft0, zero
.4byte 0x828059d7  # vfdiv.vf v19, v8, ft0
.assert trap == 0 "binary64 divide by zero retires"
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "divide-by-zero result writes x10"
.assert rd_wdata == 0x7ff0000000000000 "binary64 divide by zero gives positive infinity"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "divide-by-zero flags write x11"
.assert rd_wdata == 0xb "divide by zero accrues DZ alongside UF and NX"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "cleared flags write x11"
.assert rd_wdata == 0x0 "explicit clear resets the accrued flags"
