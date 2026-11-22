# Fixed-point vector operations and illegal widening/narrowing overlap traps.
.noshrink
# Enable VS, clear fixed-point CSRs and zero all vector registers.
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xc2202e73  # csrr t3, vlenb
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x05a00493  # addi s1, zero, 90
.4byte 0x00006937  # lui s2, 0x6
.4byte 0xa5a90913  # addi s2, s2, -1446

# Section 1: vsaddu/vsadd/vssubu/vssub across e8, e16, e32, e64.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x0f000293  # addi t0, zero, 240
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x07000293  # addi t0, zero, 112
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x07f00293  # addi t0, zero, 127
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x08100293  # addi t0, zero, 129
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x02000293  # addi t0, zero, 32
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x02000293  # addi t0, zero, 32
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xdeadc437  # lui s0, 0xdeadc
.4byte 0xeef40413  # addi s0, s0, -273
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x12340fb7  # lui t6, 0x12340
.4byte 0x071f8f93  # addi t6, t6, 113
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e04c7d7  # vmv.v.x v15, s1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x868507d7  # vsadd.vv v15, v8, v10
.assert trap == 0 "vsadd.vv e8 control retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x42f02557  # vmv.x.s a0, v15
.assert rd_addr == 10 "vsadd.vv e8 control lane 0 writes x10"
.assert rd_wdata == 0x7f "vsadd.vv e8 control lane 0"
.4byte 0x3ef0be57  # vslidedown.vi v28, v15, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x10 "vsadd.vv e8 lane 1"
.4byte 0x3ef13e57  # vslidedown.vi v28, v15, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vsadd.vv e8 lane 2"
.4byte 0x3ef1be57  # vslidedown.vi v28, v15, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vv e8 tu tail lane 3 writes x10"
.assert rd_wdata == 0x5a "vsadd.vv e8 tu tail lane 3"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vv e8 sets vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vv e8 sets vxsat"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x82803857  # vsaddu.vi v16, v8, 0
.assert trap == 0 "vsaddu.vi sticky check retires"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vxsat remains sticky after non-saturating op writes x10"
.assert rd_wdata == 0x1 "vxsat remains sticky after non-saturating op"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x5e02c657  # vmv.v.x v12, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, t0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x3bc2e657  # vslide1up.vx v12, v28, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, t0
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x5e02c6d7  # vmv.v.x v13, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3ad2ee57  # vslide1up.vx v28, v13, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3bc2e6d7  # vslide1up.vx v13, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3ad2ee57  # vslide1up.vx v28, v13, t0
.4byte 0x5e0e06d7  # vmv.v.v v13, v28
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x82c68857  # vsaddu.vv v16, v12, v13
.assert trap == 0 "vsaddu.vv e8 non-sat with saturating tail retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vv e8 non-sat lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e8 non-sat lane 0"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vv e8 tail saturation does not set vxsat writes x10"
.assert rd_wdata == 0x0 "vsaddu.vv e8 tail saturation does not set vxsat"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x5e02c657  # vmv.v.x v12, t0
.4byte 0x01000293  # addi t0, zero, 16
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, t0
.4byte 0x0f000293  # addi t0, zero, 240
.4byte 0x3bc2e657  # vslide1up.vx v12, v28, t0
.4byte 0x01000293  # addi t0, zero, 16
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, t0
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e04c857  # vmv.v.x v16, s1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x80c50857  # vsaddu.vv v16, v12, v10, v0.t
.assert trap == 0 "vsaddu.vv e8 masked-off sat retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vv e8 masked lane 0 writes x10"
.assert rd_wdata == 0x30 "vsaddu.vv e8 masked lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e8 mu masked-off lane 1 writes x10"
.assert rd_wdata == 0x5a "vsaddu.vv e8 mu masked-off lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e8 masked lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff91 "vsaddu.vv e8 masked lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e8 tu tail lane 3 writes x10"
.assert rd_wdata == 0x5a "vsaddu.vv e8 tu tail lane 3"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vv e8 masked-off saturation does not set vxsat writes x10"
.assert rd_wdata == 0x0 "vsaddu.vv e8 masked-off saturation does not set vxsat"
.4byte 0xcc01f657  # vsetivli a2, 3, e8, m1, ta, ma
.4byte 0x82844857  # vsaddu.vx v16, v8, s0
.assert trap == 0 "vsaddu.vx e8 ta,ma retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffe1 "vsaddu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vsaddu.vx e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vx e8 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vx e8 vxsat"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x82850857  # vsaddu.vv v16, v8, v10
.assert trap == 0 "vsaddu.vv e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff90 "vsaddu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vv e8 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vv e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x828fb857  # vsaddu.vi v16, v8, -1
.assert trap == 0 "vsaddu.vi e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vi e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vi e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vi e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vi e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vi e8 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vi e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86844857  # vsadd.vx v16, v8, s0
.assert trap == 0 "vsadd.vx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x7f "vsadd.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x61 "vsadd.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vsadd.vx e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vx e8 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vx e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86883857  # vsadd.vi v16, v8, -16
.assert trap == 0 "vsadd.vi e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vi e8 lane 0 writes x10"
.assert rd_wdata == 0x60 "vsadd.vi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vi e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffe0 "vsadd.vi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vi e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vsadd.vi e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vi e8 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vi e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8a850857  # vssubu.vv v16, v8, v10
.assert trap == 0 "vssubu.vv e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssubu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x50 "vssubu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffd0 "vssubu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x0 "vssubu.vv e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssubu.vv e8 vxsat writes x10"
.assert rd_wdata == 0x1 "vssubu.vv e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8a844857  # vssubu.vx v16, v8, s0
.assert trap == 0 "vssubu.vx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssubu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssubu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x7f "vssubu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xf "vssubu.vx e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssubu.vx e8 vxsat writes x10"
.assert rd_wdata == 0x1 "vssubu.vx e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8e850857  # vssub.vv v16, v8, v10
.assert trap == 0 "vssub.vv e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssub.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x50 "vssub.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffd0 "vssub.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssub.vv e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssub.vv e8 vxsat writes x10"
.assert rd_wdata == 0x0 "vssub.vv e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8e844857  # vssub.vx v16, v8, s0
.assert trap == 0 "vssub.vx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssub.vx e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssub.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vssub.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vssub.vx e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssub.vx e8 vxsat writes x10"
.assert rd_wdata == 0x1 "vssub.vx e8 vxsat"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e040857  # vmv.v.v v16, v8
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x81050857  # vsaddu.vv v16, v16, v10, v0.t
.assert trap == 0 "vsaddu.vv e8 in-place masked retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vv e8 in-place masked lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff90 "vsaddu.vv e8 in-place masked lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e8 in-place masked-off lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffff0 "vsaddu.vv e8 in-place masked-off lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e8 in-place masked lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e8 in-place masked lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vv e8 active masked saturation sets vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vv e8 active masked saturation sets vxsat"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0xff028293  # addi t0, t0, -16
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfe028293  # addi t0, t0, -32
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0xdead0437  # lui s0, 0xdead0
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x00008fb7  # lui t6, 0x8
.4byte 0x001f8f93  # addi t6, t6, 1
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x82850857  # vsaddu.vv v16, v8, v10
.assert trap == 0 "vsaddu.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vv e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vv e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vv e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x82844857  # vsaddu.vx v16, v8, s0
.assert trap == 0 "vsaddu.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vx e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vsaddu.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vx e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vx e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vx e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vx e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x828fb857  # vsaddu.vi v16, v8, -1
.assert trap == 0 "vsaddu.vi e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vi e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vi e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vi e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vi e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vi e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vi e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86850857  # vsadd.vv v16, v8, v10
.assert trap == 0 "vsadd.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x7fd0 "vsadd.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vsadd.vv e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vv e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vv e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86844857  # vsadd.vx v16, v8, s0
.assert trap == 0 "vsadd.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vx e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vsadd.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vx e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vsadd.vx e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vx e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vx e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86883857  # vsadd.vi v16, v8, -16
.assert trap == 0 "vsadd.vi e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vi e16 lane 0 writes x10"
.assert rd_wdata == 0x7fe0 "vsadd.vi e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vi e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vsadd.vi e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vi e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vi e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8a850857  # vssubu.vv v16, v8, v10
.assert trap == 0 "vssubu.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssubu.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssubu.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x0 "vssubu.vv e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssubu.vv e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vssubu.vv e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8a844857  # vssubu.vx v16, v8, s0
.assert trap == 0 "vssubu.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssubu.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssubu.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x0 "vssubu.vx e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssubu.vx e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vssubu.vx e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8e850857  # vssub.vv v16, v8, v10
.assert trap == 0 "vssub.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssub.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x7fff "vssub.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssub.vv e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssub.vv e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vssub.vv e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8e844857  # vssub.vx v16, v8, s0
.assert trap == 0 "vssub.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssub.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x7fff "vssub.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vx e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssub.vx e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssub.vx e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vssub.vx e16 vxsat"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0xff028293  # addi t0, t0, -16
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x001f8f93  # addi t6, t6, 1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfe000f93  # addi t6, zero, -32
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0xabcdf437  # lui s0, 0xabcdf
.4byte 0xf0140413  # addi s0, s0, -255
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x001f8f93  # addi t6, t6, 1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x82850857  # vsaddu.vv v16, v8, v10
.assert trap == 0 "vsaddu.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vv e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vv e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x82844857  # vsaddu.vx v16, v8, s0
.assert trap == 0 "vsaddu.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vx e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vsaddu.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vx e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vx e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vx e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vx e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x828fb857  # vsaddu.vi v16, v8, -1
.assert trap == 0 "vsaddu.vi e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vi e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vi e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vi e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vi e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vi e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vi e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86850857  # vsadd.vv v16, v8, v10
.assert trap == 0 "vsadd.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffd0 "vsadd.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vsadd.vv e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vv e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vv e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86844857  # vsadd.vx v16, v8, s0
.assert trap == 0 "vsadd.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vx e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vsadd.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vx e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vsadd.vx e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vx e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vx e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86883857  # vsadd.vi v16, v8, -16
.assert trap == 0 "vsadd.vi e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vi e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffe0 "vsadd.vi e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vi e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vsadd.vi e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vi e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vi e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8a850857  # vssubu.vv v16, v8, v10
.assert trap == 0 "vssubu.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssubu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssubu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x0 "vssubu.vv e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssubu.vv e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vssubu.vv e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8a844857  # vssubu.vx v16, v8, s0
.assert trap == 0 "vssubu.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssubu.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssubu.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x0 "vssubu.vx e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssubu.vx e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vssubu.vx e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8e850857  # vssub.vv v16, v8, v10
.assert trap == 0 "vssub.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssub.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffff "vssub.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssub.vv e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssub.vv e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vssub.vv e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8e844857  # vssub.vx v16, v8, s0
.assert trap == 0 "vssub.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssub.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffff "vssub.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vx e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssub.vx e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssub.vx e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vssub.vx e32 vxsat"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xff000f93  # addi t6, zero, -16
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0xfe000293  # addi t0, zero, -32
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x80000437  # lui s0, 0x80000
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x82850857  # vsaddu.vv v16, v8, v10
.assert trap == 0 "vsaddu.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vv e64 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vv e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vv e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vv e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vv e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x82844857  # vsaddu.vx v16, v8, s0
.assert trap == 0 "vsaddu.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vx e64 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vsaddu.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vx e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vx e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vx e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vx e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x828fb857  # vsaddu.vi v16, v8, -1
.assert trap == 0 "vsaddu.vi e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vi e64 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vi e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vi e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vi e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vi e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vi e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86850857  # vsadd.vv v16, v8, v10
.assert trap == 0 "vsadd.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x7fffffffffffffd0 "vsadd.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vv e64 lane 1 writes x10"
.assert rd_wdata == 0x8000000000000000 "vsadd.vv e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vv e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vv e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86844857  # vsadd.vx v16, v8, s0
.assert trap == 0 "vsadd.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vx e64 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vsadd.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vx e64 lane 1 writes x10"
.assert rd_wdata == 0x8000000000000000 "vsadd.vx e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vx e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vx e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x86883857  # vsadd.vi v16, v8, -16
.assert trap == 0 "vsadd.vi e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsadd.vi e64 lane 0 writes x10"
.assert rd_wdata == 0x7fffffffffffffe0 "vsadd.vi e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsadd.vi e64 lane 1 writes x10"
.assert rd_wdata == 0x8000000000000000 "vsadd.vi e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsadd.vi e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vsadd.vi e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8a850857  # vssubu.vv v16, v8, v10
.assert trap == 0 "vssubu.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssubu.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssubu.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vv e64 lane 1 writes x10"
.assert rd_wdata == 0x0 "vssubu.vv e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssubu.vv e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vssubu.vv e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8a844857  # vssubu.vx v16, v8, s0
.assert trap == 0 "vssubu.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssubu.vx e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssubu.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssubu.vx e64 lane 1 writes x10"
.assert rd_wdata == 0x0 "vssubu.vx e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssubu.vx e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vssubu.vx e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8e850857  # vssub.vv v16, v8, v10
.assert trap == 0 "vssub.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssub.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x7fffffffffffffff "vssub.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vv e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssub.vv e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssub.vv e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vssub.vv e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x8e844857  # vssub.vx v16, v8, s0
.assert trap == 0 "vssub.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssub.vx e64 lane 0 writes x10"
.assert rd_wdata == 0x7fffffffffffffff "vssub.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssub.vx e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssub.vx e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vssub.vx e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vssub.vx e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x01107657  # vsetvli a2, zero, e32, m2, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xffe00f93  # addi t6, zero, -2
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x8282c857  # vsaddu.vx v16, v8, t0
.assert trap == 0 "vsaddu.vx e32 m2 VLMAX retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vx e32 m2 VLMAX lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vsaddu.vx e32 m2 VLMAX lane 0"
.4byte 0x001e5393  # srli t2, t3, 1
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsaddu.vx e32 m2 VLMAX last lane writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsaddu.vx e32 m2 VLMAX last lane"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vx e32 m2 VLMAX sets vxsat writes x10"
.assert rd_wdata == 0x1 "vsaddu.vx e32 m2 VLMAX sets vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00f07657  # vsetvli a2, zero, e16, mf2, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0x8287b857  # vsaddu.vi v16, v8, 15
.assert trap == 0 "vsaddu.vi e16 mf2 VLMAX retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsaddu.vi e16 mf2 lane 0 writes x10"
.assert rd_wdata == 0xf "vsaddu.vi e16 mf2 lane 0"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsaddu.vi e16 mf2 vxsat clear writes x10"
.assert rd_wdata == 0x0 "vsaddu.vi e16 mf2 vxsat clear"

# Section 2: vaaddu/vaadd/vasubu/vasub across e8..e64 and all four vxrm modes.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0x22852857  # vaaddu.vv v16, v8, v10
.assert trap == 0 "vaaddu.vv e8 vxrm=0 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=0 lane 0 writes x10"
.assert rd_wdata == 0x1 "vaaddu.vv e8 vxrm=0 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=0 lane 1 writes x10"
.assert rd_wdata == 0x2 "vaaddu.vv e8 vxrm=0 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=0 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaaddu.vv e8 vxrm=0 lane 2"
.4byte 0x00a0d073  # csrwi vxrm, 1
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 1 writes x10"
.assert rd_wdata == 0x1 "vxrm readback 1"
.4byte 0x22852857  # vaaddu.vv v16, v8, v10
.assert trap == 0 "vaaddu.vv e8 vxrm=1 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=1 lane 0 writes x10"
.assert rd_wdata == 0x0 "vaaddu.vv e8 vxrm=1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=1 lane 1 writes x10"
.assert rd_wdata == 0x2 "vaaddu.vv e8 vxrm=1 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=1 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaaddu.vv e8 vxrm=1 lane 2"
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0x22852857  # vaaddu.vv v16, v8, v10
.assert trap == 0 "vaaddu.vv e8 vxrm=2 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=2 lane 0 writes x10"
.assert rd_wdata == 0x0 "vaaddu.vv e8 vxrm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=2 lane 1 writes x10"
.assert rd_wdata == 0x1 "vaaddu.vv e8 vxrm=2 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=2 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaaddu.vv e8 vxrm=2 lane 2"
.4byte 0x00a1d073  # csrwi vxrm, 3
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 3 writes x10"
.assert rd_wdata == 0x3 "vxrm readback 3"
.4byte 0x22852857  # vaaddu.vv v16, v8, v10
.assert trap == 0 "vaaddu.vv e8 vxrm=3 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=3 lane 0 writes x10"
.assert rd_wdata == 0x1 "vaaddu.vv e8 vxrm=3 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=3 lane 1 writes x10"
.assert rd_wdata == 0x1 "vaaddu.vv e8 vxrm=3 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e8 vxrm=3 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaaddu.vv e8 vxrm=3 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vaaddu.vv never sets vxsat writes x10"
.assert rd_wdata == 0x0 "vaaddu.vv never sets vxsat"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x07f00293  # addi t0, zero, 127
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xcafec437  # lui s0, 0xcafec
.4byte 0xabe40413  # addi s0, s0, -1346
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x08000f93  # addi t6, zero, 128
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x22846857  # vaaddu.vx v16, v8, s0
.assert trap == 0 "vaaddu.vx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x40 "vaaddu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vaaddu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vaaddu.vx e8 lane 2"
.4byte 0x26852857  # vaadd.vv v16, v8, v10
.assert trap == 0 "vaadd.vv e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaadd.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x1 "vaadd.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vaadd.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vaadd.vv e8 lane 2"
.4byte 0x26846857  # vaadd.vx v16, v8, s0
.assert trap == 0 "vaadd.vx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaadd.vx e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffc0 "vaadd.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vaadd.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vaadd.vx e8 lane 2"
.4byte 0x2a852857  # vasubu.vv v16, v8, v10
.assert trap == 0 "vasubu.vv e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasubu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vasubu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vasubu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x0 "vasubu.vv e8 lane 2"
.4byte 0x2a846857  # vasubu.vx v16, v8, s0
.assert trap == 0 "vasubu.vx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasubu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffc0 "vasubu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vasubu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x0 "vasubu.vx e8 lane 2"
.4byte 0x2e852857  # vasub.vv v16, v8, v10
.assert trap == 0 "vasub.vv e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasub.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vasub.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vasub.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x0 "vasub.vv e8 lane 2"
.4byte 0x2e846857  # vasub.vx v16, v8, s0
.assert trap == 0 "vasub.vx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasub.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x40 "vasub.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vasub.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x0 "vasub.vx e8 lane 2"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e04c857  # vmv.v.x v16, s1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x2c852857  # vasub.vv v16, v8, v10, v0.t
.assert trap == 0 "vasub.vv e8 masked retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasub.vv e8 masked lane 0 writes x10"
.assert rd_wdata == 0x0 "vasub.vv e8 masked lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vv e8 mu masked-off lane 1 writes x10"
.assert rd_wdata == 0x5a "vasub.vv e8 mu masked-off lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vv e8 masked lane 2 writes x10"
.assert rd_wdata == 0x0 "vasub.vv e8 masked lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vv e8 tu tail lane 3 writes x10"
.assert rd_wdata == 0x5a "vasub.vv e8 tu tail lane 3"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "averaging ops e8 never set vxsat writes x10"
.assert rd_wdata == 0x0 "averaging ops e8 never set vxsat"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x11110437  # lui s0, 0x11110
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x00a0d073  # csrwi vxrm, 1
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 1 writes x10"
.assert rd_wdata == 0x1 "vxrm readback 1"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x22852857  # vaaddu.vv v16, v8, v10
.assert trap == 0 "vaaddu.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vv e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaaddu.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vaaddu.vv e16 lane 1"
.4byte 0x22846857  # vaaddu.vx v16, v8, s0
.assert trap == 0 "vaaddu.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vx e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vaaddu.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x4000 "vaaddu.vx e16 lane 1"
.4byte 0x26852857  # vaadd.vv v16, v8, v10
.assert trap == 0 "vaadd.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaadd.vv e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaadd.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x0 "vaadd.vv e16 lane 1"
.4byte 0x26846857  # vaadd.vx v16, v8, s0
.assert trap == 0 "vaadd.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaadd.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vaadd.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vx e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffc000 "vaadd.vx e16 lane 1"
.4byte 0x2a852857  # vasubu.vv v16, v8, v10
.assert trap == 0 "vasubu.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasubu.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vasubu.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x0 "vasubu.vv e16 lane 1"
.4byte 0x2a846857  # vasubu.vx v16, v8, s0
.assert trap == 0 "vasubu.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasubu.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x7fff "vasubu.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x4000 "vasubu.vx e16 lane 1"
.4byte 0x2e852857  # vasub.vv v16, v8, v10
.assert trap == 0 "vasub.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasub.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vasub.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vasub.vv e16 lane 1"
.4byte 0x2e846857  # vasub.vx v16, v8, s0
.assert trap == 0 "vasub.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasub.vx e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vasub.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vx e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffc000 "vasub.vx e16 lane 1"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x22223437  # lui s0, 0x22223
.4byte 0x33340413  # addi s0, s0, 819
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x22852857  # vaaddu.vv v16, v8, v10
.assert trap == 0 "vaaddu.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaaddu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff "vaaddu.vv e32 lane 1"
.4byte 0x22846857  # vaaddu.vx v16, v8, s0
.assert trap == 0 "vaaddu.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vx e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vaaddu.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x40000000 "vaaddu.vx e32 lane 1"
.4byte 0x26852857  # vaadd.vv v16, v8, v10
.assert trap == 0 "vaadd.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaadd.vv e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaadd.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaadd.vv e32 lane 1"
.4byte 0x26846857  # vaadd.vx v16, v8, s0
.assert trap == 0 "vaadd.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaadd.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vaadd.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x40000000 "vaadd.vx e32 lane 1"
.4byte 0x2a852857  # vasubu.vv v16, v8, v10
.assert trap == 0 "vasubu.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasubu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vasubu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vasubu.vv e32 lane 1"
.4byte 0x2a846857  # vasubu.vx v16, v8, s0
.assert trap == 0 "vasubu.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasubu.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffff "vasubu.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x3fffffff "vasubu.vx e32 lane 1"
.4byte 0x2e852857  # vasub.vv v16, v8, v10
.assert trap == 0 "vasub.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasub.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vasub.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff "vasub.vv e32 lane 1"
.4byte 0x2e846857  # vasub.vx v16, v8, s0
.assert trap == 0 "vasub.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasub.vx e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vasub.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x3fffffff "vasub.vx e32 lane 1"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0xfff00293  # addi t0, zero, -1
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0xfff00293  # addi t0, zero, -1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0xfff00293  # addi t0, zero, -1
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x80000437  # lui s0, 0x80000
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x00a1d073  # csrwi vxrm, 3
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 3 writes x10"
.assert rd_wdata == 0x3 "vxrm readback 3"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x22852857  # vaaddu.vv v16, v8, v10
.assert trap == 0 "vaaddu.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vv e64 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaaddu.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vv e64 lane 1 writes x10"
.assert rd_wdata == 0x7fffffffffffffff "vaaddu.vv e64 lane 1"
.4byte 0x22846857  # vaaddu.vx v16, v8, s0
.assert trap == 0 "vaaddu.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vx e64 lane 0 writes x10"
.assert rd_wdata == 0xbfffffffffffffff "vaaddu.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vx e64 lane 1 writes x10"
.assert rd_wdata == 0x4000000000000000 "vaaddu.vx e64 lane 1"
.4byte 0x26852857  # vaadd.vv v16, v8, v10
.assert trap == 0 "vaadd.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaadd.vv e64 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaadd.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vv e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vaadd.vv e64 lane 1"
.4byte 0x26846857  # vaadd.vx v16, v8, s0
.assert trap == 0 "vaadd.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaadd.vx e64 lane 0 writes x10"
.assert rd_wdata == 0xbfffffffffffffff "vaadd.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaadd.vx e64 lane 1 writes x10"
.assert rd_wdata == 0xc000000000000000 "vaadd.vx e64 lane 1"
.4byte 0x2a852857  # vasubu.vv v16, v8, v10
.assert trap == 0 "vasubu.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasubu.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vasubu.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vv e64 lane 1 writes x10"
.assert rd_wdata == 0x8000000000000001 "vasubu.vv e64 lane 1"
.4byte 0x2a846857  # vasubu.vx v16, v8, s0
.assert trap == 0 "vasubu.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasubu.vx e64 lane 0 writes x10"
.assert rd_wdata == 0x3fffffffffffffff "vasubu.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasubu.vx e64 lane 1 writes x10"
.assert rd_wdata == 0xc000000000000000 "vasubu.vx e64 lane 1"
.4byte 0x2e852857  # vasub.vv v16, v8, v10
.assert trap == 0 "vasub.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasub.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x0 "vasub.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vv e64 lane 1 writes x10"
.assert rd_wdata == 0x1 "vasub.vv e64 lane 1"
.4byte 0x2e846857  # vasub.vx v16, v8, s0
.assert trap == 0 "vasub.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vasub.vx e64 lane 0 writes x10"
.assert rd_wdata == 0x3fffffffffffffff "vasub.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vasub.vx e64 lane 1 writes x10"
.assert rd_wdata == 0x4000000000000000 "vasub.vx e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "averaging ops e16..e64 never set vxsat writes x10"
.assert rd_wdata == 0x0 "averaging ops e16..e64 never set vxsat"
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x2282e857  # vaaddu.vx v16, v8, t0
.assert trap == 0 "vaaddu.vx e32 VLMAX retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vaaddu.vx e32 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x1 "vaaddu.vx e32 VLMAX lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vaaddu.vx e32 VLMAX last lane writes x10"

# Section 3: vsmul.vv/vsmul.vx across e8..e64, vxrm 0..3 and INT_MIN*INT_MIN.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x04100293  # addi t0, zero, 65
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x04000293  # addi t0, zero, 64
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x04000293  # addi t0, zero, 64
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0x9e850857  # vsmul.vv v16, v8, v10
.assert trap == 0 "vsmul.vv e8 vxrm=0 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vv e8 vxrm=0 lane 0 writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e8 vxrm=0 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=0 lane 1 writes x10"
.assert rd_wdata == 0x2 "vsmul.vv e8 vxrm=0 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=0 lane 2 writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e8 vxrm=0 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=0 lane 3 writes x10"
.assert rd_wdata == 0x0 "vsmul.vv e8 vxrm=0 lane 3"
.4byte 0x00a0d073  # csrwi vxrm, 1
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 1 writes x10"
.assert rd_wdata == 0x1 "vxrm readback 1"
.4byte 0x9e850857  # vsmul.vv v16, v8, v10
.assert trap == 0 "vsmul.vv e8 vxrm=1 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vv e8 vxrm=1 lane 0 writes x10"
.assert rd_wdata == 0x0 "vsmul.vv e8 vxrm=1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=1 lane 1 writes x10"
.assert rd_wdata == 0x2 "vsmul.vv e8 vxrm=1 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=1 lane 2 writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e8 vxrm=1 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=1 lane 3 writes x10"
.assert rd_wdata == 0x0 "vsmul.vv e8 vxrm=1 lane 3"
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0x9e850857  # vsmul.vv v16, v8, v10
.assert trap == 0 "vsmul.vv e8 vxrm=2 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vv e8 vxrm=2 lane 0 writes x10"
.assert rd_wdata == 0x0 "vsmul.vv e8 vxrm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=2 lane 1 writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e8 vxrm=2 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=2 lane 2 writes x10"
.assert rd_wdata == 0x0 "vsmul.vv e8 vxrm=2 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=2 lane 3 writes x10"
.assert rd_wdata == 0x0 "vsmul.vv e8 vxrm=2 lane 3"
.4byte 0x00a1d073  # csrwi vxrm, 3
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 3 writes x10"
.assert rd_wdata == 0x3 "vxrm readback 3"
.4byte 0x9e850857  # vsmul.vv v16, v8, v10
.assert trap == 0 "vsmul.vv e8 vxrm=3 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vv e8 vxrm=3 lane 0 writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e8 vxrm=3 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=3 lane 1 writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e8 vxrm=3 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=3 lane 2 writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e8 vxrm=3 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 vxrm=3 lane 3 writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e8 vxrm=3 lane 3"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vv e8 non-sat vxsat clear writes x10"
.assert rd_wdata == 0x0 "vsmul.vv e8 non-sat vxsat clear"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x08100293  # addi t0, zero, 129
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x08100293  # addi t0, zero, 129
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x08100293  # addi t0, zero, 129
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e04c857  # vmv.v.x v16, s1
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x9c850857  # vsmul.vv v16, v8, v10, v0.t
.assert trap == 0 "vsmul.vv e8 masked-off sat retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vv e8 masked lane 0 writes x10"
.assert rd_wdata == 0x7f "vsmul.vv e8 masked lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 mu masked-off INT_MIN*INT_MIN lane 1 writes x10"
.assert rd_wdata == 0x5a "vsmul.vv e8 mu masked-off INT_MIN*INT_MIN lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 masked lane 2 writes x10"
.assert rd_wdata == 0x7e "vsmul.vv e8 masked lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e8 tu tail lane 3 writes x10"
.assert rd_wdata == 0x5a "vsmul.vv e8 tu tail lane 3"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vv e8 masked-off INT_MIN*INT_MIN does not set vxsat writes x10"
.assert rd_wdata == 0x0 "vsmul.vv e8 masked-off INT_MIN*INT_MIN does not set vxsat"
.4byte 0xabcd0437  # lui s0, 0xabcd0
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x08000f93  # addi t6, zero, 128
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xcc01f657  # vsetivli a2, 3, e8, m1, ta, ma
.4byte 0x9e844857  # vsmul.vx v16, v8, s0
.assert trap == 0 "vsmul.vx e8 sat retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x7f "vsmul.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x7f "vsmul.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x7f "vsmul.vx e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vx e8 INT_MIN*INT_MIN sets vxsat writes x10"
.assert rd_wdata == 0x1 "vsmul.vx e8 INT_MIN*INT_MIN sets vxsat"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0xbeef0437  # lui s0, 0xbeef0
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x00008fb7  # lui t6, 0x8
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x00a0d073  # csrwi vxrm, 1
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 1 writes x10"
.assert rd_wdata == 0x1 "vxrm readback 1"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x9e850857  # vsmul.vv v16, v8, v10
.assert trap == 0 "vsmul.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x7fff "vsmul.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x7fff "vsmul.vv e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vv e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x9e844857  # vsmul.vx v16, v8, s0
.assert trap == 0 "vsmul.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x7fff "vsmul.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x7fff "vsmul.vx e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vx e16 vxsat writes x10"
.assert rd_wdata == 0x1 "vsmul.vx e16 vxsat"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x001f8f93  # addi t6, t6, 1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x55550437  # lui s0, 0x55550
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x9e850857  # vsmul.vv v16, v8, v10
.assert trap == 0 "vsmul.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffff "vsmul.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff "vsmul.vv e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vv e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x9e844857  # vsmul.vx v16, v8, s0
.assert trap == 0 "vsmul.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffff "vsmul.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff "vsmul.vx e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vx e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vsmul.vx e32 vxsat"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x80000437  # lui s0, 0x80000
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x00a1d073  # csrwi vxrm, 3
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 3 writes x10"
.assert rd_wdata == 0x3 "vxrm readback 3"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x9e850857  # vsmul.vv v16, v8, v10
.assert trap == 0 "vsmul.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x7fffffffffffffff "vsmul.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vv e64 lane 1 writes x10"
.assert rd_wdata == 0x7fffffffffffffff "vsmul.vv e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vv e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vsmul.vv e64 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x9e844857  # vsmul.vx v16, v8, s0
.assert trap == 0 "vsmul.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vx e64 lane 0 writes x10"
.assert rd_wdata == 0x7fffffffffffffff "vsmul.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vx e64 lane 1 writes x10"
.assert rd_wdata == 0x7fffffffffffffff "vsmul.vx e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vx e64 vxsat writes x10"
.assert rd_wdata == 0x1 "vsmul.vx e64 vxsat"
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x9e82c857  # vsmul.vx v16, v8, t0
.assert trap == 0 "vsmul.vx e32 VLMAX retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsmul.vx e32 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x0 "vsmul.vx e32 VLMAX lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsmul.vx e32 VLMAX last lane writes x10"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vsmul.vx e32 VLMAX non-sat vxsat writes x10"
.assert rd_wdata == 0x0 "vsmul.vx e32 VLMAX non-sat vxsat"

# Section 4: vssrl/vssra across e8..e64, vxrm 0..3 and shift-masking.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x08100293  # addi t0, zero, 129
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x08900293  # addi t0, zero, 137
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x01800293  # addi t0, zero, 24
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x00800293  # addi t0, zero, 8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00400293  # addi t0, zero, 4
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x01400293  # addi t0, zero, 20
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x00400293  # addi t0, zero, 4
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x00c00293  # addi t0, zero, 12
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0xae850857  # vssra.vv v16, v8, v10
.assert trap == 0 "vssra.vv e8 vxrm=0 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vv e8 vxrm=0 lane 0 writes x10"
.assert rd_wdata == 0x1 "vssra.vv e8 vxrm=0 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=0 lane 1 writes x10"
.assert rd_wdata == 0x2 "vssra.vv e8 vxrm=0 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=0 lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff9 "vssra.vv e8 vxrm=0 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=0 lane 3 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vssra.vv e8 vxrm=0 lane 3"
.4byte 0x00a0d073  # csrwi vxrm, 1
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 1 writes x10"
.assert rd_wdata == 0x1 "vxrm readback 1"
.4byte 0xae850857  # vssra.vv v16, v8, v10
.assert trap == 0 "vssra.vv e8 vxrm=1 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vv e8 vxrm=1 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssra.vv e8 vxrm=1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=1 lane 1 writes x10"
.assert rd_wdata == 0x2 "vssra.vv e8 vxrm=1 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=1 lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff9 "vssra.vv e8 vxrm=1 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=1 lane 3 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vssra.vv e8 vxrm=1 lane 3"
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0xae850857  # vssra.vv v16, v8, v10
.assert trap == 0 "vssra.vv e8 vxrm=2 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vv e8 vxrm=2 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssra.vv e8 vxrm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=2 lane 1 writes x10"
.assert rd_wdata == 0x1 "vssra.vv e8 vxrm=2 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=2 lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vssra.vv e8 vxrm=2 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=2 lane 3 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vssra.vv e8 vxrm=2 lane 3"
.4byte 0x00a1d073  # csrwi vxrm, 3
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 3 writes x10"
.assert rd_wdata == 0x3 "vxrm readback 3"
.4byte 0xae850857  # vssra.vv v16, v8, v10
.assert trap == 0 "vssra.vv e8 vxrm=3 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vv e8 vxrm=3 lane 0 writes x10"
.assert rd_wdata == 0x1 "vssra.vv e8 vxrm=3 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=3 lane 1 writes x10"
.assert rd_wdata == 0x1 "vssra.vv e8 vxrm=3 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=3 lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff9 "vssra.vv e8 vxrm=3 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e8 vxrm=3 lane 3 writes x10"
.assert rd_wdata == 0xfffffffffffffff9 "vssra.vv e8 vxrm=3 lane 3"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xaa803857  # vssrl.vi v16, v8, 0
.assert trap == 0 "vssrl.vi e8 shamt=0 rod retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vi e8 shamt=0 rod lane 0 writes x10"
.assert rd_wdata == 0x8 "vssrl.vi e8 shamt=0 rod lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vi e8 shamt=0 rod lane 1 writes x10"
.assert rd_wdata == 0x18 "vssrl.vi e8 shamt=0 rod lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vi e8 shamt=0 rod lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff89 "vssrl.vi e8 shamt=0 rod lane 2"
.4byte 0xffff0437  # lui s0, 0xffff0
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x00c00f93  # addi t6, zero, 12
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x00a0d073  # csrwi vxrm, 1
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 1 writes x10"
.assert rd_wdata == 0x1 "vxrm readback 1"
.4byte 0xaa850857  # vssrl.vv v16, v8, v10
.assert trap == 0 "vssrl.vv e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssrl.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x2 "vssrl.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x9 "vssrl.vv e8 lane 2"
.4byte 0xaa844857  # vssrl.vx v16, v8, s0
.assert trap == 0 "vssrl.vx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssrl.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x2 "vssrl.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x9 "vssrl.vx e8 lane 2"
.4byte 0xaa8a3857  # vssrl.vi v16, v8, 20
.assert trap == 0 "vssrl.vi e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vi e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssrl.vi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vi e8 lane 1 writes x10"
.assert rd_wdata == 0x2 "vssrl.vi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vi e8 lane 2 writes x10"
.assert rd_wdata == 0x9 "vssrl.vi e8 lane 2"
.4byte 0xae844857  # vssra.vx v16, v8, s0
.assert trap == 0 "vssra.vx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssra.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x2 "vssra.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff9 "vssra.vx e8 lane 2"
.4byte 0xae8a3857  # vssra.vi v16, v8, 20
.assert trap == 0 "vssra.vi e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vi e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vssra.vi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vi e8 lane 1 writes x10"
.assert rd_wdata == 0x2 "vssra.vi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vi e8 lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff9 "vssra.vi e8 lane 2"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e04c857  # vmv.v.x v16, s1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xac8a3857  # vssra.vi v16, v8, 20, v0.t
.assert trap == 0 "vssra.vi e8 masked retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vi e8 masked lane 0 writes x10"
.assert rd_wdata == 0x0 "vssra.vi e8 masked lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vi e8 mu masked-off lane 1 writes x10"
.assert rd_wdata == 0x5a "vssra.vi e8 mu masked-off lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vi e8 masked lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff9 "vssra.vi e8 masked lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vi e8 tu tail lane 3 writes x10"
.assert rd_wdata == 0x5a "vssra.vi e8 tu tail lane 3"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "scaling shifts e8 never set vxsat writes x10"
.assert rd_wdata == 0x0 "scaling shifts e8 never set vxsat"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0xf1828293  # addi t0, t0, -232
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x00828293  # addi t0, t0, 8
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00f00293  # addi t0, zero, 15
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x01400293  # addi t0, zero, 20
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0xaaaa0437  # lui s0, 0xaaaa0
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x01400f93  # addi t6, zero, 20
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0xaa850857  # vssrl.vv v16, v8, v10
.assert trap == 0 "vssrl.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x801 "vssrl.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x1 "vssrl.vv e16 lane 1"
.4byte 0xaa844857  # vssrl.vx v16, v8, s0
.assert trap == 0 "vssrl.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x801 "vssrl.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x7f2 "vssrl.vx e16 lane 1"
.4byte 0xaa8a3857  # vssrl.vi v16, v8, 20
.assert trap == 0 "vssrl.vi e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vi e16 lane 0 writes x10"
.assert rd_wdata == 0x801 "vssrl.vi e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vi e16 lane 1 writes x10"
.assert rd_wdata == 0x7f2 "vssrl.vi e16 lane 1"
.4byte 0xae850857  # vssra.vv v16, v8, v10
.assert trap == 0 "vssra.vv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vv e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff801 "vssra.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x1 "vssra.vv e16 lane 1"
.4byte 0xae844857  # vssra.vx v16, v8, s0
.assert trap == 0 "vssra.vx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vx e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff801 "vssra.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x7f2 "vssra.vx e16 lane 1"
.4byte 0xae8a3857  # vssra.vi v16, v8, 20
.assert trap == 0 "vssra.vi e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vi e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff801 "vssra.vi e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vi e16 lane 1 writes x10"
.assert rd_wdata == 0x7f2 "vssra.vi e16 lane 1"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0xf1828293  # addi t0, t0, -232
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x008f8f93  # addi t6, t6, 8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x01f00293  # addi t0, zero, 31
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x02400293  # addi t0, zero, 36
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0xbbbb0437  # lui s0, 0xbbbb0
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x02400f93  # addi t6, zero, 36
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x00a0d073  # csrwi vxrm, 1
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 1 writes x10"
.assert rd_wdata == 0x1 "vxrm readback 1"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xaa850857  # vssrl.vv v16, v8, v10
.assert trap == 0 "vssrl.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x8000000 "vssrl.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x1 "vssrl.vv e32 lane 1"
.4byte 0xaa844857  # vssrl.vx v16, v8, s0
.assert trap == 0 "vssrl.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x8000000 "vssrl.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffff2 "vssrl.vx e32 lane 1"
.4byte 0xaa8a3857  # vssrl.vi v16, v8, 20
.assert trap == 0 "vssrl.vi e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vi e32 lane 0 writes x10"
.assert rd_wdata == 0x800 "vssrl.vi e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vi e32 lane 1 writes x10"
.assert rd_wdata == 0x800 "vssrl.vi e32 lane 1"
.4byte 0xae850857  # vssra.vv v16, v8, v10
.assert trap == 0 "vssra.vv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vv e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffff8000000 "vssra.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x1 "vssra.vv e32 lane 1"
.4byte 0xae844857  # vssra.vx v16, v8, s0
.assert trap == 0 "vssra.vx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vx e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffff8000000 "vssra.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffff2 "vssra.vx e32 lane 1"
.4byte 0xae8a3857  # vssra.vi v16, v8, 20
.assert trap == 0 "vssra.vi e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vi e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vssra.vi e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vi e32 lane 1 writes x10"
.assert rd_wdata == 0x800 "vssra.vi e32 lane 1"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0xfff00293  # addi t0, zero, -1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00800f93  # addi t6, zero, 8
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x03f00293  # addi t0, zero, 63
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x04400293  # addi t0, zero, 68
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x04400413  # addi s0, zero, 68
.4byte 0x00a1d073  # csrwi vxrm, 3
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 3 writes x10"
.assert rd_wdata == 0x3 "vxrm readback 3"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0xaa850857  # vssrl.vv v16, v8, v10
.assert trap == 0 "vssrl.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vv e64 lane 0 writes x10"
.assert rd_wdata == 0x800000000000001 "vssrl.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vv e64 lane 1 writes x10"
.assert rd_wdata == 0x1 "vssrl.vv e64 lane 1"
.4byte 0xaa844857  # vssrl.vx v16, v8, s0
.assert trap == 0 "vssrl.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vx e64 lane 0 writes x10"
.assert rd_wdata == 0x800000000000001 "vssrl.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vx e64 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffff "vssrl.vx e64 lane 1"
.4byte 0xaa8a3857  # vssrl.vi v16, v8, 20
.assert trap == 0 "vssrl.vi e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vi e64 lane 0 writes x10"
.assert rd_wdata == 0x80000000001 "vssrl.vi e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vi e64 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffff "vssrl.vi e64 lane 1"
.4byte 0xae850857  # vssra.vv v16, v8, v10
.assert trap == 0 "vssra.vv e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vv e64 lane 0 writes x10"
.assert rd_wdata == 0xf800000000000001 "vssra.vv e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vv e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssra.vv e64 lane 1"
.4byte 0xae844857  # vssra.vx v16, v8, s0
.assert trap == 0 "vssra.vx e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vx e64 lane 0 writes x10"
.assert rd_wdata == 0xf800000000000001 "vssra.vx e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vx e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssra.vx e64 lane 1"
.4byte 0xae8a3857  # vssra.vi v16, v8, 20
.assert trap == 0 "vssra.vi e64 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssra.vi e64 lane 0 writes x10"
.assert rd_wdata == 0xfffff80000000001 "vssra.vi e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssra.vi e64 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vssra.vi e64 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "scaling shifts e16..e64 never set vxsat writes x10"
.assert rd_wdata == 0x0 "scaling shifts e16..e64 never set vxsat"
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0xaa80b857  # vssrl.vi v16, v8, 1
.assert trap == 0 "vssrl.vi e32 VLMAX retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vssrl.vi e32 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x0 "vssrl.vi e32 VLMAX lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vssrl.vi e32 VLMAX last lane writes x10"

# Section 5: vnclipu/vnclip across e8<-e16, e16<-e32, e32<-e64 and rounding-before-sat.
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x1ff00293  # addi t0, zero, 511
.4byte 0x4202ea57  # vmv.s.x v20, t0
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0xbb40b857  # vnclipu.wi v16, v20, 1
.assert trap == 0 "vnclipu.wi e8 round-before-sat vxrm=2 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wi e8 round-before-sat vxrm=2 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclipu.wi e8 round-before-sat vxrm=2 lane 0"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e8 round-before-sat vxrm=2 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wi e8 round-before-sat vxrm=2 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0xbb40b857  # vnclipu.wi v16, v20, 1
.assert trap == 0 "vnclipu.wi e8 round-before-sat vxrm=0 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wi e8 round-before-sat vxrm=0 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclipu.wi e8 round-before-sat vxrm=0 lane 0"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e8 round-before-sat vxrm=0 vxsat writes x10"
.assert rd_wdata == 0x1 "vnclipu.wi e8 round-before-sat vxrm=0 vxsat"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x4202ea57  # vmv.s.x v20, t0
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0xbf40b857  # vnclip.wi v16, v20, 1
.assert trap == 0 "vnclip.wi e8 pos round-before-sat vxrm=2 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wi e8 pos round-before-sat vxrm=2 lane 0 writes x10"
.assert rd_wdata == 0x7f "vnclip.wi e8 pos round-before-sat vxrm=2 lane 0"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wi e8 pos round-before-sat vxrm=2 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wi e8 pos round-before-sat vxrm=2 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0xbf40b857  # vnclip.wi v16, v20, 1
.assert trap == 0 "vnclip.wi e8 pos round-before-sat vxrm=0 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wi e8 pos round-before-sat vxrm=0 lane 0 writes x10"
.assert rd_wdata == 0x7f "vnclip.wi e8 pos round-before-sat vxrm=0 lane 0"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wi e8 pos round-before-sat vxrm=0 vxsat writes x10"
.assert rd_wdata == 0x1 "vnclip.wi e8 pos round-before-sat vxrm=0 vxsat"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xeff28293  # addi t0, t0, -257
.4byte 0x4202ea57  # vmv.s.x v20, t0
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0xbf40b857  # vnclip.wi v16, v20, 1
.assert trap == 0 "vnclip.wi e8 neg round-before-sat vxrm=2 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wi e8 neg round-before-sat vxrm=2 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vnclip.wi e8 neg round-before-sat vxrm=2 lane 0"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wi e8 neg round-before-sat vxrm=2 vxsat writes x10"
.assert rd_wdata == 0x1 "vnclip.wi e8 neg round-before-sat vxrm=2 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0xbf40b857  # vnclip.wi v16, v20, 1
.assert trap == 0 "vnclip.wi e8 neg round-before-sat vxrm=0 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wi e8 neg round-before-sat vxrm=0 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vnclip.wi e8 neg round-before-sat vxrm=0 lane 0"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wi e8 neg round-before-sat vxrm=0 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wi e8 neg round-before-sat vxrm=0 vxsat"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x0000f2b7  # lui t0, 0xf
.4byte 0x08828293  # addi t0, t0, 136
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x01800293  # addi t0, zero, 24
.4byte 0x3bc2ea57  # vslide1up.vx v20, v28, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x04828293  # addi t0, t0, 72
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x01c00293  # addi t0, zero, 28
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x00400293  # addi t0, zero, 4
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x00c00293  # addi t0, zero, 12
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x12345437  # lui s0, 0x12345
.4byte 0x67840413  # addi s0, s0, 1656
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x01c00f93  # addi t6, zero, 28
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0xbf450857  # vnclip.wv v16, v20, v10
.assert trap == 0 "vnclip.wv e8 vxrm=0 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wv e8 vxrm=0 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vnclip.wv e8 vxrm=0 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e8 vxrm=0 lane 1 writes x10"
.assert rd_wdata == 0x2 "vnclip.wv e8 vxrm=0 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e8 vxrm=0 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclip.wv e8 vxrm=0 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wv e8 vxrm=0 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wv e8 vxrm=0 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a0d073  # csrwi vxrm, 1
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 1 writes x10"
.assert rd_wdata == 0x1 "vxrm readback 1"
.4byte 0xbf450857  # vnclip.wv v16, v20, v10
.assert trap == 0 "vnclip.wv e8 vxrm=1 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wv e8 vxrm=1 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vnclip.wv e8 vxrm=1 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e8 vxrm=1 lane 1 writes x10"
.assert rd_wdata == 0x2 "vnclip.wv e8 vxrm=1 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e8 vxrm=1 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclip.wv e8 vxrm=1 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wv e8 vxrm=1 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wv e8 vxrm=1 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a15073  # csrwi vxrm, 2
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 2 writes x10"
.assert rd_wdata == 0x2 "vxrm readback 2"
.4byte 0xbf450857  # vnclip.wv v16, v20, v10
.assert trap == 0 "vnclip.wv e8 vxrm=2 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wv e8 vxrm=2 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vnclip.wv e8 vxrm=2 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e8 vxrm=2 lane 1 writes x10"
.assert rd_wdata == 0x1 "vnclip.wv e8 vxrm=2 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e8 vxrm=2 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclip.wv e8 vxrm=2 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wv e8 vxrm=2 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wv e8 vxrm=2 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00a1d073  # csrwi vxrm, 3
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 3 writes x10"
.assert rd_wdata == 0x3 "vxrm readback 3"
.4byte 0xbf450857  # vnclip.wv v16, v20, v10
.assert trap == 0 "vnclip.wv e8 vxrm=3 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wv e8 vxrm=3 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff9 "vnclip.wv e8 vxrm=3 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e8 vxrm=3 lane 1 writes x10"
.assert rd_wdata == 0x1 "vnclip.wv e8 vxrm=3 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e8 vxrm=3 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclip.wv e8 vxrm=3 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wv e8 vxrm=3 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wv e8 vxrm=3 vxsat"
.4byte 0x00a0d073  # csrwi vxrm, 1
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 1 writes x10"
.assert rd_wdata == 0x1 "vxrm readback 1"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb450857  # vnclipu.wv v16, v20, v10
.assert trap == 0 "vnclipu.wv e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wv e8 lane 0 writes x10"
.assert rd_wdata == 0x8 "vnclipu.wv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wv e8 lane 1 writes x10"
.assert rd_wdata == 0x2 "vnclipu.wv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wv e8 lane 2 writes x10"
.assert rd_wdata == 0xf "vnclipu.wv e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wv e8 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wv e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb444857  # vnclipu.wx v16, v20, s0
.assert trap == 0 "vnclipu.wx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wx e8 lane 0 writes x10"
.assert rd_wdata == 0x8 "vnclipu.wx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wx e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vnclipu.wx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wx e8 lane 2 writes x10"
.assert rd_wdata == 0xf "vnclipu.wx e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wx e8 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wx e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb4e3857  # vnclipu.wi v16, v20, 28
.assert trap == 0 "vnclipu.wi e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wi e8 lane 0 writes x10"
.assert rd_wdata == 0x8 "vnclipu.wi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vnclipu.wi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e8 lane 2 writes x10"
.assert rd_wdata == 0xf "vnclipu.wi e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e8 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wi e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb403857  # vnclipu.wi v16, v20, 0
.assert trap == 0 "vnclipu.wi e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wi e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclipu.wi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e8 lane 1 writes x10"
.assert rd_wdata == 0x18 "vnclipu.wi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclipu.wi e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e8 vxsat writes x10"
.assert rd_wdata == 0x1 "vnclipu.wi e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbf444857  # vnclip.wx v16, v20, s0
.assert trap == 0 "vnclip.wx e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wx e8 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vnclip.wx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wx e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vnclip.wx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclip.wx e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wx e8 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wx e8 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbf47b857  # vnclip.wi v16, v20, 15
.assert trap == 0 "vnclip.wi e8 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wi e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclip.wi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wi e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vnclip.wi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wi e8 lane 2 writes x10"
.assert rd_wdata == 0x0 "vnclip.wi e8 lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wi e8 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wi e8 vxsat"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x5e02cb57  # vmv.v.x v22, t0
.4byte 0x01100293  # addi t0, zero, 17
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3bc2eb57  # vslide1up.vx v22, v28, t0
.4byte 0x04200293  # addi t0, zero, 66
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, t0
.4byte 0x5e0e0b57  # vmv.v.v v22, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e04c857  # vmv.v.x v16, s1
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xb9603857  # vnclipu.wi v16, v22, 0, v0.t
.assert trap == 0 "vnclipu.wi e8 masked-off sat retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wi e8 masked lane 0 writes x10"
.assert rd_wdata == 0x42 "vnclipu.wi e8 masked lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e8 mu masked-off lane 1 writes x10"
.assert rd_wdata == 0x5a "vnclipu.wi e8 mu masked-off lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e8 masked lane 2 writes x10"
.assert rd_wdata == 0x11 "vnclipu.wi e8 masked lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e8 tu tail lane 3 writes x10"
.assert rd_wdata == 0x5a "vnclipu.wi e8 tu tail lane 3"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e8 masked-off sat does not set vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wi e8 masked-off sat does not set vxsat"
.4byte 0xcc01f657  # vsetivli a2, 3, e8, m1, ta, ma
.4byte 0xbb603b57  # vnclipu.wi v22, v22, 0
.assert trap == 0 "vnclipu.wi e8 legal low-reg overlap retires"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vnclipu.wi e8 legal overlap lane 0 writes x10"
.assert rd_wdata == 0x42 "vnclipu.wi e8 legal overlap lane 0"
.4byte 0x3f60be57  # vslidedown.vi v28, v22, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e8 legal overlap lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclipu.wi e8 legal overlap lane 1"
.4byte 0x3f613e57  # vslidedown.vi v28, v22, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e8 legal overlap lane 2 writes x10"
.assert rd_wdata == 0x11 "vnclipu.wi e8 legal overlap lane 2"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e8 legal overlap sets vxsat writes x10"
.assert rd_wdata == 0x1 "vnclipu.wi e8 legal overlap sets vxsat"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x008f8f93  # addi t6, t6, 8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202ea57  # vmv.s.x v20, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x01f00293  # addi t0, zero, 31
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x01400293  # addi t0, zero, 20
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0xaaaa0437  # lui s0, 0xaaaa0
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x03400f93  # addi t6, zero, 52
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb450857  # vnclipu.wv v16, v20, v10
.assert trap == 0 "vnclipu.wv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wv e16 lane 0 writes x10"
.assert rd_wdata == 0x800 "vnclipu.wv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wv e16 lane 1 writes x10"
.assert rd_wdata == 0x1 "vnclipu.wv e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wv e16 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wv e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb444857  # vnclipu.wx v16, v20, s0
.assert trap == 0 "vnclipu.wx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wx e16 lane 0 writes x10"
.assert rd_wdata == 0x800 "vnclipu.wx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wx e16 lane 1 writes x10"
.assert rd_wdata == 0x800 "vnclipu.wx e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wx e16 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wx e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb4a3857  # vnclipu.wi v16, v20, 20
.assert trap == 0 "vnclipu.wi e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wi e16 lane 0 writes x10"
.assert rd_wdata == 0x800 "vnclipu.wi e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e16 lane 1 writes x10"
.assert rd_wdata == 0x800 "vnclipu.wi e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e16 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wi e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbf450857  # vnclip.wv v16, v20, v10
.assert trap == 0 "vnclip.wv e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wv e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vnclip.wv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclip.wv e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wv e16 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wv e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbf444857  # vnclip.wx v16, v20, s0
.assert trap == 0 "vnclip.wx e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wx e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vnclip.wx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wx e16 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vnclip.wx e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wx e16 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wx e16 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbf4a3857  # vnclip.wi v16, v20, 20
.assert trap == 0 "vnclip.wi e16 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wi e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vnclip.wi e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wi e16 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffff800 "vnclip.wi e16 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wi e16 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wi e16 vxsat"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00800f93  # addi t6, zero, 8
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x4202ea57  # vmv.s.x v20, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x03f00293  # addi t0, zero, 63
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x02400293  # addi t0, zero, 36
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x06400413  # addi s0, zero, 100
.4byte 0x00a1d073  # csrwi vxrm, 3
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 3 writes x10"
.assert rd_wdata == 0x3 "vxrm readback 3"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb450857  # vnclipu.wv v16, v20, v10
.assert trap == 0 "vnclipu.wv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wv e32 lane 0 writes x10"
.assert rd_wdata == 0x8000001 "vnclipu.wv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wv e32 lane 1 writes x10"
.assert rd_wdata == 0x1 "vnclipu.wv e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wv e32 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wv e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb444857  # vnclipu.wx v16, v20, s0
.assert trap == 0 "vnclipu.wx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wx e32 lane 0 writes x10"
.assert rd_wdata == 0x8000001 "vnclipu.wx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wx e32 lane 1 writes x10"
.assert rd_wdata == 0x8000000 "vnclipu.wx e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wx e32 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wx e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbb4fb857  # vnclipu.wi v16, v20, 31
.assert trap == 0 "vnclipu.wi e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wi e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclipu.wi e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclipu.wi e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vnclipu.wi e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbf450857  # vnclip.wv v16, v20, v10
.assert trap == 0 "vnclip.wv e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wv e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffff8000001 "vnclip.wv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclip.wv e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wv e32 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wv e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbf444857  # vnclip.wx v16, v20, s0
.assert trap == 0 "vnclip.wx e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wx e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffff8000001 "vnclip.wx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wx e32 lane 1 writes x10"
.assert rd_wdata == 0xfffffffff8000000 "vnclip.wx e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wx e32 vxsat writes x10"
.assert rd_wdata == 0x0 "vnclip.wx e32 vxsat"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xbf4fb857  # vnclip.wi v16, v20, 31
.assert trap == 0 "vnclip.wi e32 retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclip.wi e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vnclip.wi e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclip.wi e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vnclip.wi e32 lane 1"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclip.wi e32 vxsat writes x10"
.assert rd_wdata == 0x1 "vnclip.wi e32 vxsat"
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00a02573  # csrr a0, vxrm
.assert rd_addr == 10 "vxrm readback 0 writes x10"
.assert rd_wdata == 0x0 "vxrm readback 0"
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x00807657  # vsetvli a2, zero, e16, m1, tu, mu
.4byte 0x5208aa57  # vid.v v20
.4byte 0x00707657  # vsetvli a2, zero, e8, mf2, tu, mu
.4byte 0xbb403857  # vnclipu.wi v16, v20, 0
.assert trap == 0 "vnclipu.wi e8 mf2 VLMAX retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wi e8 mf2 lane 0 writes x10"
.assert rd_wdata == 0x0 "vnclipu.wi e8 mf2 lane 0"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e8 mf2 non-sat vxsat writes x10"
.assert rd_wdata == 0x0 "vnclipu.wi e8 mf2 non-sat vxsat"
.4byte 0x01a07657  # vsetvli a2, zero, e64, m4, tu, mu
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x01107657  # vsetvli a2, zero, e32, m2, tu, mu
.4byte 0xbb403857  # vnclipu.wi v16, v20, 0
.assert trap == 0 "vnclipu.wi e32 m2 VLMAX retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnclipu.wi e32 m2 VLMAX lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclipu.wi e32 m2 VLMAX lane 0"
.4byte 0x001e5393  # srli t2, t3, 1
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnclipu.wi e32 m2 VLMAX last lane writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnclipu.wi e32 m2 VLMAX last lane"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vnclipu.wi e32 m2 VLMAX sets vxsat writes x10"
.assert rd_wdata == 0x1 "vnclipu.wi e32 m2 VLMAX sets vxsat"

# Section 6: vl=0 preservation (no vxsat) and illegal-instruction traps.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x4202e557  # vmv.s.x v10, t0
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x4202ea57  # vmv.s.x v20, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x5e094857  # vmv.v.x v16, s2
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xc0807657  # vsetivli a2, 0, e16, m1, tu, mu
.assert rd_addr == 12 "vl=0 writes x12"
.assert rd_wdata == 0x0 "vl=0"
.4byte 0x82850857  # vsaddu.vv v16, v8, v10
.assert trap == 0 "vsaddu.vv vl=0 retires"
.4byte 0x26852857  # vaadd.vv v16, v8, v10
.assert trap == 0 "vaadd.vv vl=0 retires"
.4byte 0x9e850857  # vsmul.vv v16, v8, v10
.assert trap == 0 "vsmul.vv vl=0 retires"
.4byte 0xae850857  # vssra.vv v16, v8, v10
.assert trap == 0 "vssra.vv vl=0 retires"
.4byte 0xbb450857  # vnclipu.wv v16, v20, v10
.assert trap == 0 "vnclipu.wv vl=0 retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl=0 leaves destination unchanged writes x10"
.assert rd_wdata == 0x5a5a "vl=0 leaves destination unchanged"
.4byte 0x00902573  # csrr a0, vxsat
.assert rd_addr == 10 "vl=0 saturating ops do not set vxsat writes x10"
.assert rd_wdata == 0x0 "vl=0 saturating ops do not set vxsat"
.4byte 0x001072d7  # vsetvli t0, zero, e8, m2, tu, mu
.4byte 0x5e04ca57  # vmv.v.x v20, s1
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00400293  # addi t0, zero, 4
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xc3452a57  # vwaddu.vv v20, v20, v10
.assert trap == 1 "widening vd overlaps vs2 low half traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "widening vd overlaps vs2 low half traps mcause writes x10"
.assert rd_wdata == 0x2 "widening vd overlaps vs2 low half traps raises illegal instruction"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0xeeaa2a57  # vwmul.vv v20, v10, v20
.assert trap == 1 "widening vd overlaps vs1 low half traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "widening vd overlaps vs1 low half traps mcause writes x10"
.assert rd_wdata == 0x2 "widening vd overlaps vs1 low half traps raises illegal instruction"
.4byte 0xc0727657  # vsetivli a2, 4, e8, mf2, tu, mu
.4byte 0xc3452a57  # vwaddu.vv v20, v20, v10
.assert trap == 1 "widening vd overlaps fractional-LMUL vs2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "widening vd overlaps fractional-LMUL vs2 traps mcause writes x10"
.assert rd_wdata == 0x2 "widening vd overlaps fractional-LMUL vs2 traps raises illegal instruction"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xf3552a57  # vwmaccu.vv v20, v10, v21
.assert trap == 1 "widening multiply-add vd overlaps vs2 upper half traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "widening multiply-add vd overlaps vs2 upper half traps mcause writes x10"
.assert rd_wdata == 0x2 "widening multiply-add vd overlaps vs2 upper half traps raises illegal instruction"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xbb450ad7  # vnclipu.wv v21, v20, v10
.assert trap == 1 "narrowing vd overlaps wide vs2 upper half traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "narrowing vd overlaps wide vs2 upper half traps mcause writes x10"
.assert rd_wdata == 0x2 "narrowing vd overlaps wide vs2 upper half traps raises illegal instruction"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x80a60057  # vsaddu.vv v0, v10, v12, v0.t
.assert trap == 1 "masked fixed-point vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "masked fixed-point vd==v0 traps mcause writes x10"
.assert rd_wdata == 0x2 "masked fixed-point vd==v0 traps raises illegal instruction"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xbb450857  # vnclipu.wv v16, v20, v10
.assert trap == 1 "vnclipu.wv at e64 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vnclipu.wv at e64 traps mcause writes x10"
.assert rd_wdata == 0x2 "vnclipu.wv at e64 traps raises illegal instruction"
.4byte 0xc030f657  # vsetivli a2, 1, e8, m8, tu, mu
.4byte 0xbf40b857  # vnclip.wi v16, v20, 1
.assert trap == 1 "vnclip.wi at m8 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vnclip.wi at m8 traps mcause writes x10"
.assert rd_wdata == 0x2 "vnclip.wi at m8 traps raises illegal instruction"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "trapping widening overlap leaves v20 unchanged writes x10"
.assert rd_wdata == 0x5a "trapping widening overlap leaves v20 unchanged"
