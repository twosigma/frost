# Vector load and store source-width legality; run with --vlen 128, 256 or 512.
# Each vector memory encoding below reads one register at two element widths
# (a mask source has EEW 1), which is reserved: the reference raises an
# illegal-instruction exception before any access, and so must the core.
.noshrink
.4byte 0x60000293  # addi t0, x0, 0x600
.4byte 0x3002a073  # csrrs x0, mstatus, t0  # VS = Dirty
.4byte 0xfff00593  # addi a1, x0, -1
.4byte 0x01b5f057  # vsetvli x0, a1, e64,m8,tu,mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0

.4byte 0x0005f057  # vsetvli x0,a1,e8,m1,tu,mu
.4byte 0x5e0fb057  # vmv.v.i v0,-1: all mask bits active
.4byte 0x5208a457  # vid.v v8
.4byte 0x00000513  # addi a0, x0, 0: base; the reserved forms access nothing
.4byte 0x04050807  # vluxei8.v v16,(a0),v0,v0.t: v0 is mask and index: reserved
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x0085f057  # vsetvli x0,a1,e16,m1,tu,mu
.4byte 0x0c055807  # vloxei16.v v16,(a0),v0,v0.t at SEW 16: mask and index: reserved
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x0005f057  # vsetvli x0,a1,e8,m1,tu,mu
.4byte 0x04050427  # vsuxei8.v v8,(a0),v0,v0.t: mask and index: reserved
.assert trap == 1 "mask and index have different EEWs"
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x00050027  # vse8.v v0,(a0),v0.t: mask and data: reserved
.assert trap == 1 "mask and data have different EEWs"
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x0015f057  # vsetvli x0,a1,e8,m2,tu,mu
.4byte 0x00050027  # vse8.v v0,(a0),v0.t at LMUL 2: mask and data: reserved
.assert trap == 1 "mask and grouped data have different EEWs"
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x0005f057  # vsetvli x0,a1,e8,m1,tu,mu
.4byte 0x08550027  # vsse8.v v0,(a0),t0,v0.t: mask and data: reserved
.assert trap == 1 "mask and strided data have different EEWs"
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x04850027  # vsuxei8.v v0,(a0),v8,v0.t: mask and data: reserved
.assert trap == 1 "mask and indexed data have different EEWs"
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x20050027  # vsseg2e8.v v0,(a0),v0.t: mask and data: reserved
.assert trap == 1 "mask and segmented data have different EEWs"
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x0085f057  # vsetvli x0,a1,e16,m1,tu,mu
.4byte 0x06850427  # vsuxei8.v v8,(a0),v8 at SEW 16: data and index: reserved
.assert trap == 1 "data and byte indices have different EEWs"
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x0005f057  # vsetvli x0,a1,e8,m1,tu,mu
.4byte 0x0e856427  # vsoxei32.v v8,(a0),v8 at SEW 8: data and index: reserved
.assert trap == 1 "data and word indices have different EEWs"
.4byte 0x34202573  # csrr a0, mcause
.4byte 0x0085f057  # vsetvli x0,a1,e16,m1,tu,mu
.4byte 0x26950427  # vsuxseg2ei8.v v8,(a0),v9 at SEW 16: data and index: reserved
.assert trap == 1 "segmented data and indices have different EEWs"
.4byte 0x34202573  # csrr a0, mcause
