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

.4byte 0x0105f057  # vsetvli x0,a1,e32,m1,tu,mu
.4byte 0x5e0fb057  # vmv.v.i v0,-1: all mask bits active
.4byte 0xf2000053  # fmv.d.x f0,x0
.4byte 0x00801857  # vfadd.vv data/mask alias: reserved
.4byte 0x34202573  # csrr a0,mcause
.4byte 0x0c801857  # vfredosum.vs seed/mask alias: reserved
.4byte 0x34202573  # csrr a0,mcause
.4byte 0xf3141857  # vfwmacc.vv old vd/vs2 alias: reserved
.4byte 0x34202573  # csrr a0,mcause
.4byte 0xf6889857  # vfwnmacc.vv old vd/vs1 alias: reserved
.4byte 0x34202573  # csrr a0,mcause
.4byte 0xfa805857  # vfwmsac.vf with disjoint narrow source and wide accumulator
.4byte 0x34202573  # csrr a0,mcause
.4byte 0x00805857  # vfadd.vf v16,v8,f0,v0.t: legal scalar f0 source
.4byte 0xc3141857  # vfwadd.vv v16,v17,v8: legal upper destination overlap
.4byte 0x43002557  # vmv.x.s a0,v16
