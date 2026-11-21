# Vector floating-point conversions and accrued flags.
.noshrink
# Enable FS and VS and select RNE.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x00305073  # csrwi fcsr, 0

# Binary32 fractions exercise signed and unsigned rounding to integers.
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x403002b7  # lui t0, 0x40300
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a801c57  # vfcvt.xu.f.v v24, v8
.assert trap == 0 "vfcvt.xu.f.v retires"
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x3 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a831857  # vfcvt.rtz.xu.f.v v16, v8
.assert trap == 0 "vfcvt.rtz.xu.f.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x2 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0xc03002b7  # lui t0, 0xc0300
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a809857  # vfcvt.x.f.v v16, v8
.assert trap == 0 "vfcvt.x.f.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xfffffffffffffffd "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a839857  # vfcvt.rtz.x.f.v v16, v8
.assert trap == 0 "vfcvt.rtz.x.f.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xfffffffffffffffe "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
# Binary32 conversion of an integer with its top bit and low bit set.
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a811857  # vfcvt.f.xu.v v16, v8
.assert trap == 0 "vfcvt.f.xu.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x4f000000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a819857  # vfcvt.f.x.v v16, v8
.assert trap == 0 "vfcvt.f.x.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xffffffffcf000000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"

# Binary64 fractions exercise signed and unsigned rounding to integers.
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x400602b7  # lui t0, 0x40060
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a801857  # vfcvt.xu.f.v v16, v8
.assert trap == 0 "vfcvt.xu.f.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x3 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a831857  # vfcvt.rtz.xu.f.v v16, v8
.assert trap == 0 "vfcvt.rtz.xu.f.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x2 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0xc00602b7  # lui t0, 0xc0060
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a809857  # vfcvt.x.f.v v16, v8
.assert trap == 0 "vfcvt.x.f.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xfffffffffffffffd "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a839857  # vfcvt.rtz.x.f.v v16, v8
.assert trap == 0 "vfcvt.rtz.x.f.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xfffffffffffffffe "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
# Binary64 conversion of an integer with its top bit and low bit set.
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x0062e2b3  # or t0, t0, t1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a811857  # vfcvt.f.xu.v v16, v8
.assert trap == 0 "vfcvt.f.xu.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x43e0000000000000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a819857  # vfcvt.f.x.v v16, v8
.assert trap == 0 "vfcvt.f.x.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xc3e0000000000000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"

# Widen binary32 and 32-bit integers into 64-bit destinations.
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x403002b7  # lui t0, 0x40300
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a841857  # vfwcvt.xu.f.v v16, v8
.assert trap == 0 "vfwcvt.xu.f.v retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x3 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a871857  # vfwcvt.rtz.xu.f.v v16, v8
.assert trap == 0 "vfwcvt.rtz.xu.f.v retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x2 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0xc03002b7  # lui t0, 0xc0300
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a849857  # vfwcvt.x.f.v v16, v8
.assert trap == 0 "vfwcvt.x.f.v retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xfffffffffffffffd "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a879857  # vfwcvt.rtz.x.f.v v16, v8
.assert trap == 0 "vfwcvt.rtz.x.f.v retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xfffffffffffffffe "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a861857  # vfwcvt.f.f.v v16, v8
.assert trap == 0 "vfwcvt.f.f.v retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xc006000000000000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x0 "conversion flags"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a851857  # vfwcvt.f.xu.v v16, v8
.assert trap == 0 "vfwcvt.f.xu.v retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x41e0000000200000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x0 "conversion flags"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a859857  # vfwcvt.f.x.v v16, v8
.assert trap == 0 "vfwcvt.f.x.v retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xc1dfffffffc00000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x0 "conversion flags"

# Narrow 64-bit fractions and integers into 32-bit destinations.
.4byte 0x400602b7  # lui t0, 0x40060
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a881857  # vfncvt.xu.f.w v16, v8
.assert trap == 0 "vfncvt.xu.f.w retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x3 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8b1857  # vfncvt.rtz.xu.f.w v16, v8
.assert trap == 0 "vfncvt.rtz.xu.f.w retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x2 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0xc00602b7  # lui t0, 0xc0060
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a889857  # vfncvt.x.f.w v16, v8
.assert trap == 0 "vfncvt.x.f.w retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xfffffffffffffffd "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8b9857  # vfncvt.rtz.x.f.w v16, v8
.assert trap == 0 "vfncvt.rtz.x.f.w retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xfffffffffffffffe "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x0062e2b3  # or t0, t0, t1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a891857  # vfncvt.f.xu.w v16, v8
.assert trap == 0 "vfncvt.f.xu.w retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x5f000000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a899857  # vfncvt.f.x.w v16, v8
.assert trap == 0 "vfncvt.f.x.w retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0xffffffffdf000000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"

# A halfway value separates nearest-even from round-to-odd narrowing.
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x3ff002b7  # lui t0, 0x3ff00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x10000337  # lui t1, 0x10000
.4byte 0x0062e2b3  # or t0, t0, t1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "vfncvt.f.f.w retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x3f800000 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a9857  # vfncvt.rod.f.f.w v16, v8
.assert trap == 0 "vfncvt.rod.f.f.w retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x3f800001 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x1 "conversion flags"

# Narrow a finite binary64 value outside the binary32 range.
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x47f002b7  # lui t0, 0x47f00
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a8a1857  # vfncvt.f.f.w v16, v8
.assert trap == 0 "narrowing overflow retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "narrowed element writes x10"
.assert rd_wdata == 0x7f800000 "narrowing overflow rounds to positive infinity"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "narrowing flags write x11"
.assert rd_wdata == 0x5 "narrowing overflow sets OF and NX"

# A negative input converts to unsigned zero and raises invalid.
.4byte 0xbf8002b7  # lui t0, 0xbf800
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x4a801857  # vfcvt.xu.f.v v16, v8
.assert trap == 0 "vfcvt.xu.f.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x0 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x10 "conversion flags"

# The guard selects the finite first lane and preserves the second lane.
.4byte 0x7fc002b7  # lui t0, 0x7fc00
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x3f8002b7  # lui t0, 0x3f800
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0xc5017657  # vsetivli a2, 2, e32, m1, ta, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "active vector length"
.4byte 0x05500293  # addi t0, zero, 0x55
.4byte 0x5e02c857  # vmv.v.x v16, t0
.4byte 0x00105073  # csrwi fflags, 0
.4byte 0x48809857  # vfcvt.x.f.v v16, v8, v0.t
.assert trap == 0 "masked conversion retires"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "preserved element writes x10"
.assert rd_wdata == 0x55 "masked-off element keeps its original value"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x1 "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x0 "conversion flags"

# The unmasked conversion defines the result for the NaN lane.
.4byte 0x4a809857  # vfcvt.x.f.v v16, v8
.assert trap == 0 "unmasked conversion retires"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "converted element writes x10"
.assert rd_wdata == 0x7fffffff "converted element"
.4byte 0x001025f3  # csrr a1, fflags
.assert rd_addr == 11 "conversion flags writes x11"
.assert rd_wdata == 0x10 "conversion flags"
