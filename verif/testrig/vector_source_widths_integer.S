# Vector source-width legality; run with --vlen 128, 256 or 512.
.noshrink
.4byte 0x000062b7  # lui t0, 6
.4byte 0x3002a073  # csrrs x0, mstatus, t0  # FS = Dirty
.4byte 0x60000293  # addi t0, x0, 0x600
.4byte 0x3002a073  # csrrs x0, mstatus, t0  # VS = Dirty
.4byte 0xfff00593  # addi a1, x0, -1
.4byte 0x01b5f057  # vsetvli x0, a1, e64,m8,tu,mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00905073  # csrwi vxsat, 0

.4byte 0x0005f057  # vsetvli x0,a1, selected SEW,m1,tu,mu
.4byte 0x5e02b057  # vmv.v.i v0,5
.4byte 0x5e03b457  # vmv.v.i v8,7
.4byte 0x5e06b857  # vmv.v.i v16,13
.4byte 0x5000a857  # vmsbf.m v16,v0,v0.t: mask source has EEW1
.4byte 0x43002557  # vmv.x.s a0,v16
.4byte 0x50012857  # vmsof.m v16,v0,v0.t: mask source has EEW1
.4byte 0x43002557  # vmv.x.s a0,v16
.4byte 0x5001a857  # vmsif.m v16,v0,v0.t: mask source has EEW1
.4byte 0x43002557  # vmv.x.s a0,v16
.4byte 0x50082857  # viota.m v16,v0,v0.t: mask source has EEW1
.4byte 0x43002557  # vmv.x.s a0,v16
.4byte 0x00800857  # vadd.vv v16,v8,v0,v0.t: data/mask alias is reserved
.4byte 0x34202573  # csrr a0,mcause: compare precise illegal-instruction result
.4byte 0x94802857  # vmul.vv v16,v8,v0,v0.t: data/mask alias is reserved
.4byte 0x34202573  # csrr a0,mcause: compare precise illegal-instruction result
.4byte 0x00802857  # vredsum.vs v16,v8,v0,v0.t: data/mask alias is reserved
.4byte 0x34202573  # csrr a0,mcause: compare precise illegal-instruction result
.4byte 0x00804857  # vadd.vx v16,v8,x0,v0.t: legal
.4byte 0x0105f057  # vsetvli x0,a1, selected SEW,m1,tu,mu
.4byte 0xf3142857  # vwmaccu.vv: wide old vd overlaps a narrow input
.4byte 0x34202573  # csrr a0,mcause: compare precise illegal-instruction result
.4byte 0xf688a857  # vwmacc.vv: wide old vd overlaps a narrow input
.4byte 0x34202573  # csrr a0,mcause: compare precise illegal-instruction result
.4byte 0xff156857  # vwmaccsu.vx: wide old vd overlaps a narrow input
.4byte 0x34202573  # csrr a0,mcause: compare precise illegal-instruction result
.4byte 0xc3142857  # vwaddu.vv v16,v17,v8: upper overlap is legal without old vd source
.4byte 0x43002557  # vmv.x.s a0,v16
