# Widening, extending and narrowing integer vector operations.
.noshrink
# Enable VS, clear fixed-point CSRs and zero all vector registers.
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0xc2202e73  # csrr t3, vlenb
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0
.4byte 0x0a500493  # addi s1, zero, 165
.4byte 0x00006937  # lui s2, 0x6
.4byte 0xa5a90913  # addi s2, s2, -1446
.4byte 0x5a5aa9b7  # lui s3, 0x5a5aa
.4byte 0x5a598993  # addi s3, s3, 1445
.4byte 0x5a5a6a37  # lui s4, 0x5a5a6
.4byte 0xa5aa0a13  # addi s4, s4, -1446
.4byte 0x020a1a13  # slli s4, s4, 32
.4byte 0xa5a5afb7  # lui t6, 0xa5a5a
.4byte 0x5a5f8f93  # addi t6, t6, 1445
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01fa6a33  # or s4, s4, t6
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0

# Section 1a: widening integer add/sub at SEW 8 -> 16, vl=3, tu, mu.
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e094757  # vmv.v.x v14, s2
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x01100293  # addi t0, zero, 17
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x02200293  # addi t0, zero, 34
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x07f00293  # addi t0, zero, 127
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x000032b7  # lui t0, 0x3
.4byte 0x34428293  # addi t0, t0, 836
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3bc2ea57  # vslide1up.vx v20, v28, t0
.4byte 0x000012b7  # lui t0, 0x1
.4byte 0x2ff28293  # addi t0, t0, 767
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x12345437  # lui s0, 0x12345
.4byte 0x67840413  # addi s0, s0, 1656
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x9abcefb7  # lui t6, 0x9abce
.4byte 0xefff8f93  # addi t6, t6, -257
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 vl=3 writes x12"
.assert rd_wdata == 0x3 "e8 m1 vl=3"
.4byte 0xc2852757  # vwaddu.vv v14, v8, v10
.assert trap == 0 "vwaddu.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vwaddu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x1fe "vwaddu.vv e8 lane 0"
.4byte 0x3ee0be57  # vslidedown.vi v28, v14, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xff "vwaddu.vv e8 lane 1"
.4byte 0x3ee13e57  # vslidedown.vi v28, v14, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vwaddu.vv e8 lane 2"
.4byte 0x3ee1be57  # vslidedown.vi v28, v14, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vv e8 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a "vwaddu.vv e8 tail lane 3"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xc2846857  # vwaddu.vx v16, v8, s0
.assert trap == 0 "vwaddu.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwaddu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x1fe "vwaddu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x17f "vwaddu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xff "vwaddu.vx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xd3452857  # vwaddu.wv v16, v20, v10
.assert trap == 0 "vwaddu.wv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwaddu.wv e8 lane 0 writes x10"
.assert rd_wdata == 0x13fe "vwaddu.wv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.wv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff807f "vwaddu.wv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.wv e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vwaddu.wv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xd3446857  # vwaddu.wx v16, v20, s0
.assert trap == 0 "vwaddu.wx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwaddu.wx e8 lane 0 writes x10"
.assert rd_wdata == 0x13fe "vwaddu.wx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.wx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff80ff "vwaddu.wx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.wx e8 lane 2 writes x10"
.assert rd_wdata == 0xff "vwaddu.wx e8 lane 2"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e094857  # vmv.v.x v16, s2
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xc6852857  # vwadd.vv v16, v8, v10
.assert trap == 0 "vwadd.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.vv e8 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vwadd.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vwadd.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vwadd.vv e8 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e8 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a "vwadd.vv e8 tail lane 3"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xc6846857  # vwadd.vx v16, v8, s0
.assert trap == 0 "vwadd.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.vx e8 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vwadd.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff7f "vwadd.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vwadd.vx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xd7452857  # vwadd.wv v16, v20, v10
.assert trap == 0 "vwadd.wv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.wv e8 lane 0 writes x10"
.assert rd_wdata == 0x12fe "vwadd.wv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.wv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff807f "vwadd.wv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.wv e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vwadd.wv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xd7446857  # vwadd.wx v16, v20, s0
.assert trap == 0 "vwadd.wx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.wx e8 lane 0 writes x10"
.assert rd_wdata == 0x12fe "vwadd.wx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.wx e8 lane 1 writes x10"
.assert rd_wdata == 0x7fff "vwadd.wx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.wx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vwadd.wx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xca852857  # vwsubu.vv v16, v8, v10
.assert trap == 0 "vwsubu.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsubu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vwsubu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x1 "vwsubu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vwsubu.vv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xca846857  # vwsubu.vx v16, v8, s0
.assert trap == 0 "vwsubu.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsubu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vwsubu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff81 "vwsubu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff01 "vwsubu.vx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xdb452857  # vwsubu.wv v16, v20, v10
.assert trap == 0 "vwsubu.wv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsubu.wv e8 lane 0 writes x10"
.assert rd_wdata == 0x1200 "vwsubu.wv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.wv e8 lane 1 writes x10"
.assert rd_wdata == 0x7f81 "vwsubu.wv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.wv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vwsubu.wv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xdb446857  # vwsubu.wx v16, v20, s0
.assert trap == 0 "vwsubu.wx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsubu.wx e8 lane 0 writes x10"
.assert rd_wdata == 0x1200 "vwsubu.wx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.wx e8 lane 1 writes x10"
.assert rd_wdata == 0x7f01 "vwsubu.wx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.wx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff01 "vwsubu.wx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xce852857  # vwsub.vv v16, v8, v10
.assert trap == 0 "vwsub.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsub.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vwsub.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff01 "vwsub.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vwsub.vv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xce846857  # vwsub.vx v16, v8, s0
.assert trap == 0 "vwsub.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsub.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x0 "vwsub.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff81 "vwsub.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vwsub.vx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xdf452857  # vwsub.wv v16, v20, v10
.assert trap == 0 "vwsub.wv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsub.wv e8 lane 0 writes x10"
.assert rd_wdata == 0x1300 "vwsub.wv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.wv e8 lane 1 writes x10"
.assert rd_wdata == 0x7f81 "vwsub.wv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.wv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vwsub.wv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xdf446857  # vwsub.wx v16, v20, s0
.assert trap == 0 "vwsub.wx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsub.wx e8 lane 0 writes x10"
.assert rd_wdata == 0x1300 "vwsub.wx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.wx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vwsub.wx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.wx e8 lane 2 writes x10"
.assert rd_wdata == 0x1 "vwsub.wx e8 lane 2"

# Section 1b: widening integer add/sub at SEW 16 -> 32, masked and overlaps.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000012b7  # lui t0, 0x1
.4byte 0x11128293  # addi t0, t0, 273
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x000022b7  # lui t0, 0x2
.4byte 0x22228293  # addi t0, t0, 546
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x333342b7  # lui t0, 0x33334
.4byte 0x44428293  # addi t0, t0, 1092
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3bc2ea57  # vslide1up.vx v20, v28, t0
.4byte 0x123482b7  # lui t0, 0x12348
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xaaaac437  # lui s0, 0xaaaac
.4byte 0xbbb40413  # addi s0, s0, -1093
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0xcccc8fb7  # lui t6, 0xcccc8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xc2852857  # vwaddu.vv v16, v8, v10
.assert trap == 0 "vwaddu.vv e16 retires"
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwaddu.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x10000 "vwaddu.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x10000 "vwaddu.vv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vv e16 lane 2 writes x10"
.assert rd_wdata == 0x10000 "vwaddu.vv e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xc6852857  # vwadd.vv v16, v8, v10
.assert trap == 0 "vwadd.vv e16 retires"
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.vv e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff0000 "vwadd.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x0 "vwadd.vv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e16 lane 2 writes x10"
.assert rd_wdata == 0x0 "vwadd.vv e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xca846857  # vwsubu.vx v16, v8, s0
.assert trap == 0 "vwsubu.vx e16 retires"
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsubu.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x0 "vwsubu.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x7fff "vwsubu.vx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.vx e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vwsubu.vx e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xdf446857  # vwsub.wx v16, v20, s0
.assert trap == 0 "vwsub.wx e16 retires"
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsub.wx e16 lane 0 writes x10"
.assert rd_wdata == 0x12350000 "vwsub.wx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.wx e16 lane 1 writes x10"
.assert rd_wdata == 0x8001 "vwsub.wx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.wx e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80008000 "vwsub.wx e16 lane 2"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e09c857  # vmv.v.x v16, s3
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xd1452857  # vwaddu.wv v16, v20, v10, v0.t
.assert trap == 0 "vwaddu.wv e16 retires"
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwaddu.wv e16 lane 0 writes x10"
.assert rd_wdata == 0x12350000 "vwaddu.wv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.wv e16 lane 1 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "vwaddu.wv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.wv e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffff8000ffff "vwaddu.wv e16 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.wv e16 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "vwaddu.wv e16 tail lane 3"
.4byte 0xcc81f657  # vsetivli a2, 3, e16, m1, ta, ma
.4byte 0xcc846857  # vwsub.vx v16, v8, s0, v0.t
.assert trap == 0 "vwsub.vx e16 ta,ma retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsub.vx e16 ta,ma enabled lane 0 writes x10"
.assert rd_wdata == 0x0 "vwsub.vx e16 ta,ma enabled lane 0"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x5e0408d7  # vmv.v.v v17, v8
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xc7152857  # vwadd.vv v16, v17, v10
.assert trap == 0 "vwadd.vv upper-half overlap retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.vv upper overlap lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff0000 "vwadd.vv upper overlap lane 0"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv upper overlap lane 2 writes x10"
.assert rd_wdata == 0x0 "vwadd.vv upper overlap lane 2"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xdf052857  # vwsub.wv v16, v16, v10
.assert trap == 0 "vwsub.wv in-place wide overlap retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsub.wv in-place lane 0 writes x10"
.assert rd_wdata == 0x12350000 "vwsub.wv in-place lane 0"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.wv in-place lane 2 writes x10"
.assert rd_wdata == 0xffffffff80000001 "vwsub.wv in-place lane 2"

# Section 1c: widening integer add/sub at SEW 32 -> 64, vl=3 and VLMAX.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x123452b7  # lui t0, 0x12345
.4byte 0x67828293  # addi t0, t0, 1656
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x222222b7  # lui t0, 0x22222
.4byte 0x22228293  # addi t0, t0, 546
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x333342b7  # lui t0, 0x33334
.4byte 0x44428293  # addi t0, t0, 1092
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x55556fb7  # lui t6, 0x55556
.4byte 0x666f8f93  # addi t6, t6, 1638
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3bc2ea57  # vslide1up.vx v20, v28, t0
.4byte 0x111122b7  # lui t0, 0x11112
.4byte 0x22228293  # addi t0, t0, 546
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x12345437  # lui s0, 0x12345
.4byte 0x67840413  # addi s0, s0, 1656
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xc2852857  # vwaddu.vv v16, v8, v10
.assert trap == 0 "vwaddu.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwaddu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x1fffffffe "vwaddu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffff "vwaddu.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x80000001 "vwaddu.vv e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xc6852857  # vwadd.vv v16, v8, v10
.assert trap == 0 "vwadd.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.vv e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vwadd.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vwadd.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80000001 "vwadd.vv e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xca852857  # vwsubu.vv v16, v8, v10
.assert trap == 0 "vwsubu.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsubu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vwsubu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x1 "vwsubu.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsubu.vv e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80000001 "vwsubu.vv e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xce852857  # vwsub.vv v16, v8, v10
.assert trap == 0 "vwsub.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwsub.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x0 "vwsub.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffff00000001 "vwsub.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwsub.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x80000001 "vwsub.vv e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xd3446857  # vwaddu.wx v16, v20, s0
.assert trap == 0 "vwaddu.wx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwaddu.wx e32 lane 0 writes x10"
.assert rd_wdata == 0x111122237fffffff "vwaddu.wx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.wx e32 lane 1 writes x10"
.assert rd_wdata == 0x8000000080000000 "vwaddu.wx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.wx e32 lane 2 writes x10"
.assert rd_wdata == 0x80000001 "vwaddu.wx e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xd7446857  # vwadd.wx v16, v20, s0
.assert trap == 0 "vwadd.wx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.wx e32 lane 0 writes x10"
.assert rd_wdata == 0x111122227fffffff "vwadd.wx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.wx e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff80000000 "vwadd.wx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.wx e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80000001 "vwadd.wx e32 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0a4857  # vmv.v.x v16, s4
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xc4852857  # vwadd.vv v16, v8, v10, v0.t
.assert trap == 0 "vwadd.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.vv e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vwadd.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "vwadd.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80000001 "vwadd.vv e32 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vv e32 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "vwadd.vv e32 tail lane 3"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc282e857  # vwaddu.vx v16, v8, t0
.assert trap == 0 "vwaddu.vx e32 VLMAX retires"
.4byte 0x01907657  # vsetvli a2, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwaddu.vx e32 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x80000000 "vwaddu.vx e32 VLMAX lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vx e32 VLMAX last lane writes x10"

# Section 2: vzext/vsext vf2/vf4/vf8 across all legal SEWs, masked and VLMAX.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x01200293  # addi t0, zero, 18
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x07a00293  # addi t0, zero, 122
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x08500293  # addi t0, zero, 133
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x5e094857  # vmv.v.x v16, s2
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x4a832857  # vzext.vf2 v16, v8
.assert trap == 0 "vzext.vf2 e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vzext.vf2 e16 lane 0 writes x10"
.assert rd_wdata == 0x85 "vzext.vf2 e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf2 e16 lane 1 writes x10"
.assert rd_wdata == 0x7a "vzext.vf2 e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf2 e16 lane 2 writes x10"
.assert rd_wdata == 0xff "vzext.vf2 e16 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf2 e16 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a "vzext.vf2 e16 tail lane 3"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x5e094857  # vmv.v.x v16, s2
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x4a83a857  # vsext.vf2 v16, v8
.assert trap == 0 "vsext.vf2 e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf2 e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff85 "vsext.vf2 e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e16 lane 1 writes x10"
.assert rd_wdata == 0x7a "vsext.vf2 e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsext.vf2 e16 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e16 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a "vsext.vf2 e16 tail lane 3"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x5e094857  # vmv.v.x v16, s2
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x4883a857  # vsext.vf2 v16, v8, v0.t
.assert trap == 0 "vsext.vf2 e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf2 e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff85 "vsext.vf2 e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e16 lane 1 writes x10"
.assert rd_wdata == 0x5a5a "vsext.vf2 e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsext.vf2 e16 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e16 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a "vsext.vf2 e16 tail lane 3"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e0408d7  # vmv.v.v v17, v8
.4byte 0xc091f657  # vsetivli a2, 3, e16, m2, tu, mu
.4byte 0x4b13a857  # vsext.vf2 v16, v17
.assert trap == 0 "vsext.vf2 upper-half overlap retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf2 upper overlap lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff85 "vsext.vf2 upper overlap lane 0"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 upper overlap lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsext.vf2 upper overlap lane 2"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3a92ee57  # vslide1up.vx v28, v9, t0
.4byte 0x04200293  # addi t0, zero, 66
.4byte 0x3bc2e4d7  # vslide1up.vx v9, v28, t0
.4byte 0x09300293  # addi t0, zero, 147
.4byte 0x3a92ee57  # vslide1up.vx v28, v9, t0
.4byte 0x5e0e04d7  # vmv.v.v v9, v28
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x4a832857  # vzext.vf2 v16, v8
.assert trap == 0 "vzext.vf2 e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vzext.vf2 e32 lane 0 writes x10"
.assert rd_wdata == 0x8001 "vzext.vf2 e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf2 e32 lane 1 writes x10"
.assert rd_wdata == 0x7fff "vzext.vf2 e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf2 e32 lane 2 writes x10"
.assert rd_wdata == 0xffff "vzext.vf2 e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x4a83a857  # vsext.vf2 v16, v8
.assert trap == 0 "vsext.vf2 e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf2 e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff8001 "vsext.vf2 e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e32 lane 1 writes x10"
.assert rd_wdata == 0x7fff "vsext.vf2 e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsext.vf2 e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x4a922857  # vzext.vf4 v16, v9
.assert trap == 0 "vzext.vf4 e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vzext.vf4 e32 lane 0 writes x10"
.assert rd_wdata == 0x93 "vzext.vf4 e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf4 e32 lane 1 writes x10"
.assert rd_wdata == 0x42 "vzext.vf4 e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf4 e32 lane 2 writes x10"
.assert rd_wdata == 0x80 "vzext.vf4 e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x4a92a857  # vsext.vf4 v16, v9
.assert trap == 0 "vsext.vf4 e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf4 e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff93 "vsext.vf4 e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf4 e32 lane 1 writes x10"
.assert rd_wdata == 0x42 "vsext.vf4 e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf4 e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vsext.vf4 e32 lane 2"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e09c857  # vmv.v.x v16, s3
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x48922857  # vzext.vf4 v16, v9, v0.t
.assert trap == 0 "vzext.vf4 e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vzext.vf4 e32 lane 0 writes x10"
.assert rd_wdata == 0x93 "vzext.vf4 e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf4 e32 lane 1 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "vzext.vf4 e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf4 e32 lane 2 writes x10"
.assert rd_wdata == 0x80 "vzext.vf4 e32 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf4 e32 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "vzext.vf4 e32 tail lane 3"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x001f8f93  # addi t6, t6, 1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00700293  # addi t0, zero, 7
.4byte 0x5e02c4d7  # vmv.v.x v9, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3a92ee57  # vslide1up.vx v28, v9, t0
.4byte 0x000012b7  # lui t0, 0x1
.4byte 0x23428293  # addi t0, t0, 564
.4byte 0x3bc2e4d7  # vslide1up.vx v9, v28, t0
.4byte 0x0000a2b7  # lui t0, 0xa
.4byte 0x55a28293  # addi t0, t0, 1370
.4byte 0x3a92ee57  # vslide1up.vx v28, v9, t0
.4byte 0x5e0e04d7  # vmv.v.v v9, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00900293  # addi t0, zero, 9
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x05a00293  # addi t0, zero, 90
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x0c300293  # addi t0, zero, 195
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x4a832857  # vzext.vf2 v16, v8
.assert trap == 0 "vzext.vf2 e64 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vzext.vf2 e64 lane 0 writes x10"
.assert rd_wdata == 0x80000001 "vzext.vf2 e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf2 e64 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff "vzext.vf2 e64 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf2 e64 lane 2 writes x10"
.assert rd_wdata == 0xffffffff "vzext.vf2 e64 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x4a83a857  # vsext.vf2 v16, v8
.assert trap == 0 "vsext.vf2 e64 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf2 e64 lane 0 writes x10"
.assert rd_wdata == 0xffffffff80000001 "vsext.vf2 e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e64 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff "vsext.vf2 e64 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf2 e64 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsext.vf2 e64 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x4a922857  # vzext.vf4 v16, v9
.assert trap == 0 "vzext.vf4 e64 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vzext.vf4 e64 lane 0 writes x10"
.assert rd_wdata == 0xa55a "vzext.vf4 e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf4 e64 lane 1 writes x10"
.assert rd_wdata == 0x1234 "vzext.vf4 e64 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf4 e64 lane 2 writes x10"
.assert rd_wdata == 0x8000 "vzext.vf4 e64 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x4a92a857  # vsext.vf4 v16, v9
.assert trap == 0 "vsext.vf4 e64 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf4 e64 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffa55a "vsext.vf4 e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf4 e64 lane 1 writes x10"
.assert rd_wdata == 0x1234 "vsext.vf4 e64 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf4 e64 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vsext.vf4 e64 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x4aa12857  # vzext.vf8 v16, v10
.assert trap == 0 "vzext.vf8 e64 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vzext.vf8 e64 lane 0 writes x10"
.assert rd_wdata == 0xc3 "vzext.vf8 e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf8 e64 lane 1 writes x10"
.assert rd_wdata == 0x5a "vzext.vf8 e64 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vzext.vf8 e64 lane 2 writes x10"
.assert rd_wdata == 0x80 "vzext.vf8 e64 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x4aa1a857  # vsext.vf8 v16, v10
.assert trap == 0 "vsext.vf8 e64 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf8 e64 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "vsext.vf8 e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf8 e64 lane 1 writes x10"
.assert rd_wdata == 0x5a "vsext.vf8 e64 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf8 e64 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vsext.vf8 e64 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0a4857  # vmv.v.x v16, s4
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x48a1a857  # vsext.vf8 v16, v10, v0.t
.assert trap == 0 "vsext.vf8 e64 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf8 e64 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "vsext.vf8 e64 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf8 e64 lane 1 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "vsext.vf8 e64 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf8 e64 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vsext.vf8 e64 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf8 e64 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "vsext.vf8 e64 tail lane 3"
.4byte 0x00007657  # vsetvli a2, zero, e8, m1, tu, mu
.4byte 0x5208a557  # vid.v v10
.4byte 0x2eafb557  # vxor.vi v10, v10, -1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x4aa1a857  # vsext.vf8 v16, v10
.assert trap == 0 "vsext.vf8 e64 VLMAX retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vsext.vf8 e64 VLMAX lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vsext.vf8 e64 VLMAX lane 0"
.4byte 0x003e5393  # srli t2, t3, 3
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vsext.vf8 e64 VLMAX last lane writes x10"

# Section 3: vnsrl/vnsra across e8<-e16, e16<-e32, e32<-e64.
.4byte 0x00a05073  # csrwi vxrm, 0
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x000012b7  # lui t0, 0x1
.4byte 0x23428293  # addi t0, t0, 564
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x0000f2b7  # lui t0, 0xf
.4byte 0x08828293  # addi t0, t0, 136
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0xf1828293  # addi t0, t0, -232
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
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e04c857  # vmv.v.x v16, s1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xb3450857  # vnsrl.wv v16, v20, v10
.assert trap == 0 "vnsrl.wv e8 retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wv e8 lane 0 writes x10"
.assert rd_wdata == 0x8 "vnsrl.wv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wv e8 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vnsrl.wv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wv e8 lane 2 writes x10"
.assert rd_wdata == 0xf "vnsrl.wv e8 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wv e8 tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "vnsrl.wv e8 tail lane 3"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xb7450857  # vnsra.wv v16, v20, v10
.assert trap == 0 "vnsra.wv e8 retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wv e8 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vnsra.wv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wv e8 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffff1 "vnsra.wv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xb3444857  # vnsrl.wx v16, v20, s0
.assert trap == 0 "vnsrl.wx e8 retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wx e8 lane 0 writes x10"
.assert rd_wdata == 0x8 "vnsrl.wx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wx e8 lane 1 writes x10"
.assert rd_wdata == 0x7 "vnsrl.wx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wx e8 lane 2 writes x10"
.assert rd_wdata == 0xf "vnsrl.wx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xb7444857  # vnsra.wx v16, v20, s0
.assert trap == 0 "vnsra.wx e8 retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wx e8 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vnsra.wx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e8 lane 1 writes x10"
.assert rd_wdata == 0x7 "vnsra.wx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xb34e3857  # vnsrl.wi v16, v20, 28
.assert trap == 0 "vnsrl.wi e8 retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wi e8 lane 0 writes x10"
.assert rd_wdata == 0x8 "vnsrl.wi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e8 lane 1 writes x10"
.assert rd_wdata == 0x7 "vnsrl.wi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e8 lane 2 writes x10"
.assert rd_wdata == 0xf "vnsrl.wi e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xb3403857  # vnsrl.wi v16, v20, 0
.assert trap == 0 "vnsrl.wi e8 retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wi e8 lane 0 writes x10"
.assert rd_wdata == 0x48 "vnsrl.wi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e8 lane 1 writes x10"
.assert rd_wdata == 0x18 "vnsrl.wi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff88 "vnsrl.wi e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xb747b857  # vnsra.wi v16, v20, 15
.assert trap == 0 "vnsra.wi e8 retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wi e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wi e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wi e8 lane 1 writes x10"
.assert rd_wdata == 0x0 "vnsra.wi e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wi e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wi e8 lane 2"
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e04c857  # vmv.v.x v16, s1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xb5450857  # vnsra.wv v16, v20, v10, v0.t
.assert trap == 0 "vnsra.wv e8 retires"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wv e8 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff8 "vnsra.wv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "vnsra.wv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wv e8 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wv e8 tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "vnsra.wv e8 tail lane 3"
.4byte 0x009025f3  # csrr a1, vxsat
.assert rd_addr == 11 "vxsat after narrowing shift writes x11"
.assert rd_wdata == 0x0 "narrowing shift does not set vxsat"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x112232b7  # lui t0, 0x11223
.4byte 0x34428293  # addi t0, t0, 836
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfedccfb7  # lui t6, 0xfedcc
.4byte 0xa98f8f93  # addi t6, t6, -1384
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x7fff82b7  # lui t0, 0x7fff8
.4byte 0x3bc2ea57  # vslide1up.vx v20, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x81234fb7  # lui t6, 0x81234
.4byte 0x567f8f93  # addi t6, t6, 1383
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x03400293  # addi t0, zero, 52
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x01000293  # addi t0, zero, 16
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x01400293  # addi t0, zero, 20
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x01400413  # addi s0, zero, 20
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xb3450857  # vnsrl.wv v16, v20, v10
.assert trap == 0 "vnsrl.wv e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wv e16 lane 0 writes x10"
.assert rd_wdata == 0x812 "vnsrl.wv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wv e16 lane 1 writes x10"
.assert rd_wdata == 0x7fff "vnsrl.wv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wv e16 lane 2 writes x10"
.assert rd_wdata == 0xfed "vnsrl.wv e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xb7450857  # vnsra.wv v16, v20, v10
.assert trap == 0 "vnsra.wv e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wv e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff812 "vnsra.wv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wv e16 lane 1 writes x10"
.assert rd_wdata == 0x7fff "vnsra.wv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wv e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffed "vnsra.wv e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xb3444857  # vnsrl.wx v16, v20, s0
.assert trap == 0 "vnsrl.wx e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wx e16 lane 0 writes x10"
.assert rd_wdata == 0x812 "vnsrl.wx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wx e16 lane 1 writes x10"
.assert rd_wdata == 0x7ff "vnsrl.wx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wx e16 lane 2 writes x10"
.assert rd_wdata == 0xfed "vnsrl.wx e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xb7444857  # vnsra.wx v16, v20, s0
.assert trap == 0 "vnsra.wx e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wx e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff812 "vnsra.wx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e16 lane 1 writes x10"
.assert rd_wdata == 0x7ff "vnsra.wx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffed "vnsra.wx e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xb34a3857  # vnsrl.wi v16, v20, 20
.assert trap == 0 "vnsrl.wi e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wi e16 lane 0 writes x10"
.assert rd_wdata == 0x812 "vnsrl.wi e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e16 lane 1 writes x10"
.assert rd_wdata == 0x7ff "vnsrl.wi e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e16 lane 2 writes x10"
.assert rd_wdata == 0xfed "vnsrl.wi e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xb74a3857  # vnsra.wi v16, v20, 20
.assert trap == 0 "vnsra.wi e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wi e16 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffff812 "vnsra.wi e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wi e16 lane 1 writes x10"
.assert rd_wdata == 0x7ff "vnsra.wi e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wi e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffed "vnsra.wi e16 lane 2"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x5e094857  # vmv.v.x v16, s2
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xb14a3857  # vnsrl.wi v16, v20, 20, v0.t
.assert trap == 0 "vnsrl.wi e16 retires"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wi e16 lane 0 writes x10"
.assert rd_wdata == 0x812 "vnsrl.wi e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e16 lane 1 writes x10"
.assert rd_wdata == 0x5a5a "vnsrl.wi e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e16 lane 2 writes x10"
.assert rd_wdata == 0xfed "vnsrl.wi e16 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e16 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a "vnsrl.wi e16 tail lane 3"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e0a0857  # vmv.v.v v16, v20
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xb3050857  # vnsrl.wv v16, v16, v10
.assert trap == 0 "vnsrl.wv lowest-register overlap retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wv low overlap lane 0 writes x10"
.assert rd_wdata == 0x812 "vnsrl.wv low overlap lane 0"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wv low overlap lane 2 writes x10"
.assert rd_wdata == 0xfed "vnsrl.wv low overlap lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x111122b7  # lui t0, 0x11112
.4byte 0x22228293  # addi t0, t0, 546
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33334fb7  # lui t6, 0x33334
.4byte 0x444f8f93  # addi t6, t6, 1092
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02ca57  # vmv.v.x v20, t0
.4byte 0xf00002b7  # lui t0, 0xf0000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3bc2ea57  # vslide1up.vx v20, v28, t0
.4byte 0x812342b7  # lui t0, 0x81234
.4byte 0x56728293  # addi t0, t0, 1383
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x89abdfb7  # lui t6, 0x89abd
.4byte 0xdeff8f93  # addi t6, t6, -529
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, t0
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x06400293  # addi t0, zero, 100
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x02000293  # addi t0, zero, 32
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x02400293  # addi t0, zero, 36
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x03f00413  # addi s0, zero, 63
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xb3450857  # vnsrl.wv v16, v20, v10
.assert trap == 0 "vnsrl.wv e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wv e32 lane 0 writes x10"
.assert rd_wdata == 0x8123456 "vnsrl.wv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wv e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff "vnsrl.wv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wv e32 lane 2 writes x10"
.assert rd_wdata == 0xf000000 "vnsrl.wv e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xb7450857  # vnsra.wv v16, v20, v10
.assert trap == 0 "vnsra.wv e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wv e32 lane 0 writes x10"
.assert rd_wdata == 0xfffffffff8123456 "vnsra.wv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wv e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff "vnsra.wv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wv e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffffff000000 "vnsra.wv e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xb3444857  # vnsrl.wx v16, v20, s0
.assert trap == 0 "vnsrl.wx e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wx e32 lane 0 writes x10"
.assert rd_wdata == 0x1 "vnsrl.wx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wx e32 lane 1 writes x10"
.assert rd_wdata == 0x0 "vnsrl.wx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wx e32 lane 2 writes x10"
.assert rd_wdata == 0x1 "vnsrl.wx e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xb7444857  # vnsra.wx v16, v20, s0
.assert trap == 0 "vnsra.wx e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wx e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e32 lane 1 writes x10"
.assert rd_wdata == 0x0 "vnsra.wx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wx e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xb34fb857  # vnsrl.wi v16, v20, 31
.assert trap == 0 "vnsrl.wi e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsrl.wi e32 lane 0 writes x10"
.assert rd_wdata == 0x2468acf "vnsrl.wi e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsrl.wi e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsrl.wi e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffffe0000000 "vnsrl.wi e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xb74fb857  # vnsra.wi v16, v20, 31
.assert trap == 0 "vnsra.wi e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wi e32 lane 0 writes x10"
.assert rd_wdata == 0x2468acf "vnsra.wi e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wi e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wi e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wi e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffffe0000000 "vnsra.wi e32 lane 2"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e09c857  # vmv.v.x v16, s3
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xb5444857  # vnsra.wx v16, v20, s0, v0.t
.assert trap == 0 "vnsra.wx e32 retires"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wx e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e32 lane 1 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "vnsra.wx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e32 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffff "vnsra.wx e32 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e32 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "vnsra.wx e32 tail lane 3"
.4byte 0x01907657  # vsetvli a2, zero, e64, m2, tu, mu
.4byte 0x5208aa57  # vid.v v20
.4byte 0x97423a57  # vsll.vi v20, v20, 4
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x2b42ca57  # vor.vx v20, v20, t0
.4byte 0x00400413  # addi s0, zero, 4
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0xb7444857  # vnsra.wx v16, v20, s0
.assert trap == 0 "vnsra.wx e32 VLMAX retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vnsra.wx e32 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x0 "vnsra.wx e32 VLMAX lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vnsra.wx e32 VLMAX last lane writes x10"

# Section 4: vwmulu/vwmulsu/vwmul across e8->e16, e16->e32, e32->e64.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00700293  # addi t0, zero, 7
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xabcdf437  # lui s0, 0xabcdf
.4byte 0xf0040413  # addi s0, s0, -256
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x0ff00f93  # addi t6, zero, 255
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xe2852857  # vwmulu.vv v16, v8, v10
.assert trap == 0 "vwmulu.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x7f80 "vwmulu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x7f80 "vwmulu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x4000 "vwmulu.vv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xe2846857  # vwmulu.vx v16, v8, s0
.assert trap == 0 "vwmulu.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x7f80 "vwmulu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffe01 "vwmulu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x7f80 "vwmulu.vx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xea852857  # vwmulsu.vv v16, v8, v10
.assert trap == 0 "vwmulsu.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulsu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff8080 "vwmulsu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vwmulsu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffc000 "vwmulsu.vv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xea846857  # vwmulsu.vx v16, v8, s0
.assert trap == 0 "vwmulsu.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulsu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff8080 "vwmulsu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff01 "vwmulsu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8080 "vwmulsu.vx e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xee852857  # vwmul.vv v16, v8, v10
.assert trap == 0 "vwmul.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmul.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x80 "vwmul.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x80 "vwmul.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vv e8 lane 2 writes x10"
.assert rd_wdata == 0x4000 "vwmul.vv e8 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xee846857  # vwmul.vx v16, v8, s0
.assert trap == 0 "vwmul.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmul.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x80 "vwmul.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x1 "vwmul.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x80 "vwmul.vx e8 lane 2"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e094857  # vmv.v.x v16, s2
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xe8852857  # vwmulsu.vv v16, v8, v10, v0.t
.assert trap == 0 "vwmulsu.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulsu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff8080 "vwmulsu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x5a5a "vwmulsu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffc000 "vwmulsu.vv e8 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vv e8 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a "vwmulsu.vv e8 tail lane 3"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xfff00413  # addi s0, zero, -1
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x12348fb7  # lui t6, 0x12348
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xe2852857  # vwmulu.vv v16, v8, v10
.assert trap == 0 "vwmulu.vv e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulu.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x7fff8000 "vwmulu.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x7fff8000 "vwmulu.vv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vv e16 lane 2 writes x10"
.assert rd_wdata == 0x40000000 "vwmulu.vv e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xe2846857  # vwmulu.vx v16, v8, s0
.assert trap == 0 "vwmulu.vx e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulu.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x40000000 "vwmulu.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x7fff8000 "vwmulu.vx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vx e16 lane 2 writes x10"
.assert rd_wdata == 0x40000000 "vwmulu.vx e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xea852857  # vwmulsu.vv v16, v8, v10
.assert trap == 0 "vwmulsu.vv e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulsu.vv e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffff80008000 "vwmulsu.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vwmulsu.vv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vv e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffffc0000000 "vwmulsu.vv e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xea846857  # vwmulsu.vx v16, v8, s0
.assert trap == 0 "vwmulsu.vx e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulsu.vx e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffc0000000 "vwmulsu.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vx e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vwmulsu.vx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vx e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffffc0000000 "vwmulsu.vx e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xee852857  # vwmul.vv v16, v8, v10
.assert trap == 0 "vwmul.vv e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmul.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x8000 "vwmul.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x8000 "vwmul.vv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vv e16 lane 2 writes x10"
.assert rd_wdata == 0x40000000 "vwmul.vv e16 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xee846857  # vwmul.vx v16, v8, s0
.assert trap == 0 "vwmul.vx e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmul.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x40000000 "vwmul.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x8000 "vwmul.vx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vx e16 lane 2 writes x10"
.assert rd_wdata == 0x40000000 "vwmul.vx e16 lane 2"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xaaaac437  # lui s0, 0xaaaac
.4byte 0xbbb40413  # addi s0, s0, -1093
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xe2852857  # vwmulu.vv v16, v8, v10
.assert trap == 0 "vwmulu.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffff80000000 "vwmulu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x7fffffff80000000 "vwmulu.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vwmulu.vv e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xe2846857  # vwmulu.vx v16, v8, s0
.assert trap == 0 "vwmulu.vx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulu.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffff80000000 "vwmulu.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vx e32 lane 1 writes x10"
.assert rd_wdata == 0xfffffffe00000001 "vwmulu.vx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x7fffffff80000000 "vwmulu.vx e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xea852857  # vwmulsu.vv v16, v8, v10
.assert trap == 0 "vwmulsu.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulsu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x8000000080000000 "vwmulsu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffff80000000 "vwmulsu.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vv e32 lane 2 writes x10"
.assert rd_wdata == 0xc000000000000000 "vwmulsu.vv e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xea846857  # vwmulsu.vx v16, v8, s0
.assert trap == 0 "vwmulsu.vx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulsu.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x8000000080000000 "vwmulsu.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vx e32 lane 1 writes x10"
.assert rd_wdata == 0xffffffff00000001 "vwmulsu.vx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulsu.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x8000000080000000 "vwmulsu.vx e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xee852857  # vwmul.vv v16, v8, v10
.assert trap == 0 "vwmul.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmul.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x80000000 "vwmul.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x80000000 "vwmul.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x4000000000000000 "vwmul.vv e32 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xee846857  # vwmul.vx v16, v8, s0
.assert trap == 0 "vwmul.vx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmul.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x80000000 "vwmul.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x1 "vwmul.vx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x80000000 "vwmul.vx e32 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0a4857  # vmv.v.x v16, s4
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xec846857  # vwmul.vx v16, v8, s0, v0.t
.assert trap == 0 "vwmul.vx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmul.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x80000000 "vwmul.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "vwmul.vx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x80000000 "vwmul.vx e32 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmul.vx e32 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "vwmul.vx e32 tail lane 3"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xe282e857  # vwmulu.vx v16, v8, t0
.assert trap == 0 "vwmulu.vx e32 VLMAX retires"
.4byte 0x01907657  # vsetvli a2, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmulu.vx e32 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x0 "vwmulu.vx e32 VLMAX lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmulu.vx e32 VLMAX last lane writes x10"

# Section 5: vwmaccu/vwmacc/vwmaccsu/vwmaccus across e8, e16, e32.
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0xa5a28293  # addi t0, t0, -1446
.4byte 0x5e02cb57  # vmv.v.x v22, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, t0
.4byte 0x000012b7  # lui t0, 0x1
.4byte 0x3bc2eb57  # vslide1up.vx v22, v28, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xffe28293  # addi t0, t0, -2
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, t0
.4byte 0x5e0e0b57  # vmv.v.v v22, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x08000293  # addi t0, zero, 128
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0xdeadc437  # lui s0, 0xdeadc
.4byte 0xeef40413  # addi s0, s0, -273
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x08000f93  # addi t6, zero, 128
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xf2a42857  # vwmaccu.vv v16, v8, v10
.assert trap == 0 "vwmaccu.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x7f7e "vwmaccu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8f80 "vwmaccu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8006 "vwmaccu.vv e8 lane 2"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xf2a46857  # vwmaccu.vx v16, s0, v10
.assert trap == 0 "vwmaccu.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x7f7e "vwmaccu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x5000 "vwmaccu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8180 "vwmaccu.vx e8 lane 2"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xf6a42857  # vwmacc.vv v16, v8, v10
.assert trap == 0 "vwmacc.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmacc.vv e8 lane 0 writes x10"
.assert rd_wdata == 0x7e "vwmacc.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x1080 "vwmacc.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8006 "vwmacc.vv e8 lane 2"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xf6a46857  # vwmacc.vx v16, s0, v10
.assert trap == 0 "vwmacc.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmacc.vx e8 lane 0 writes x10"
.assert rd_wdata == 0x7e "vwmacc.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vx e8 lane 1 writes x10"
.assert rd_wdata == 0x5000 "vwmacc.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x7e80 "vwmacc.vx e8 lane 2"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xfea42857  # vwmaccsu.vv v16, v8, v10
.assert trap == 0 "vwmaccsu.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccsu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff807e "vwmaccsu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0xf80 "vwmaccsu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8006 "vwmaccsu.vv e8 lane 2"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xfea46857  # vwmaccsu.vx v16, s0, v10
.assert trap == 0 "vwmaccsu.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccsu.vx e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff807e "vwmaccsu.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffd000 "vwmaccsu.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vx e8 lane 2 writes x10"
.assert rd_wdata == 0x7e80 "vwmaccsu.vx e8 lane 2"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xfaa46857  # vwmaccus.vx v16, s0, v10
.assert trap == 0 "vwmaccus.vx e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccus.vx e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff7e "vwmaccus.vx e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccus.vx e8 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffd000 "vwmaccus.vx e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccus.vx e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8180 "vwmaccus.vx e8 lane 2"
.4byte 0x009072d7  # vsetvli t0, zero, e16, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xfca42857  # vwmaccsu.vv v16, v8, v10, v0.t
.assert trap == 0 "vwmaccsu.vv e8 retires"
.4byte 0xc0927657  # vsetivli a2, 4, e16, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccsu.vv e8 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff807e "vwmaccsu.vv e8 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vv e8 lane 1 writes x10"
.assert rd_wdata == 0x1000 "vwmaccsu.vv e8 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vv e8 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffff8006 "vwmaccsu.vv e8 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vv e8 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a "vwmaccsu.vv e8 tail lane 3"
.4byte 0x009025f3  # csrr a1, vxsat
.assert rd_addr == 11 "vxsat after widening macc writes x11"
.assert rd_wdata == 0x0 "widening macc wraparound does not set vxsat"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5a5aa2b7  # lui t0, 0x5a5aa
.4byte 0x5a528293  # addi t0, t0, 1445
.4byte 0x5e02cb57  # vmv.v.x v22, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, t0
.4byte 0x100002b7  # lui t0, 0x10000
.4byte 0x3bc2eb57  # vslide1up.vx v22, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xff000f93  # addi t6, zero, -16
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, t0
.4byte 0x5e0e0b57  # vmv.v.v v22, v28
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00700293  # addi t0, zero, 7
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x000102b7  # lui t0, 0x10
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x12345437  # lui s0, 0x12345
.4byte 0x67840413  # addi s0, s0, 1656
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x9abc8fb7  # lui t6, 0x9abc8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xf2a42857  # vwmaccu.vv v16, v8, v10
.assert trap == 0 "vwmaccu.vv e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccu.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x7fff7ff0 "vwmaccu.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffff8fff8000 "vwmaccu.vv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vv e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80000015 "vwmaccu.vv e16 lane 2"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xf2a46857  # vwmaccu.vx v16, s0, v10
.assert trap == 0 "vwmaccu.vx e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccu.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x7fff7ff0 "vwmaccu.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x50000000 "vwmaccu.vx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vx e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80038000 "vwmaccu.vx e16 lane 2"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xf6a42857  # vwmacc.vv v16, v8, v10
.assert trap == 0 "vwmacc.vv e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmacc.vv e16 lane 0 writes x10"
.assert rd_wdata == 0x7ff0 "vwmacc.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vv e16 lane 1 writes x10"
.assert rd_wdata == 0x10008000 "vwmacc.vv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vv e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80000015 "vwmacc.vv e16 lane 2"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xf6a46857  # vwmacc.vx v16, s0, v10
.assert trap == 0 "vwmacc.vx e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmacc.vx e16 lane 0 writes x10"
.assert rd_wdata == 0x7ff0 "vwmacc.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vx e16 lane 1 writes x10"
.assert rd_wdata == 0x50000000 "vwmacc.vx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vx e16 lane 2 writes x10"
.assert rd_wdata == 0x7ffc8000 "vwmacc.vx e16 lane 2"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xfea42857  # vwmaccsu.vv v16, v8, v10
.assert trap == 0 "vwmaccsu.vv e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccsu.vv e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffff80007ff0 "vwmaccsu.vv e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vv e16 lane 1 writes x10"
.assert rd_wdata == 0xfff8000 "vwmaccsu.vv e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vv e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80000015 "vwmaccsu.vv e16 lane 2"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xfea46857  # vwmaccsu.vx v16, s0, v10
.assert trap == 0 "vwmaccsu.vx e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccsu.vx e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffff80007ff0 "vwmaccsu.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vx e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffd0000000 "vwmaccsu.vx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vx e16 lane 2 writes x10"
.assert rd_wdata == 0x7ffc8000 "vwmaccsu.vx e16 lane 2"
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xfaa46857  # vwmaccus.vx v16, s0, v10
.assert trap == 0 "vwmaccus.vx e16 retires"
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccus.vx e16 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff7ff0 "vwmaccus.vx e16 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccus.vx e16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffd0000000 "vwmaccus.vx e16 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccus.vx e16 lane 2 writes x10"
.assert rd_wdata == 0xffffffff80038000 "vwmaccus.vx e16 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5a5a62b7  # lui t0, 0x5a5a6
.4byte 0xa5a28293  # addi t0, t0, -1446
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xa5a5afb7  # lui t6, 0xa5a5a
.4byte 0x5a5f8f93  # addi t6, t6, 1445
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x5e02cb57  # vmv.v.x v22, t0
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, t0
.4byte 0x100002b7  # lui t0, 0x10000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x3bc2eb57  # vslide1up.vx v22, v28, t0
.4byte 0xff000293  # addi t0, zero, -16
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, t0
.4byte 0x5e0e0b57  # vmv.v.v v22, v28
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c457  # vmv.v.x v8, t0
.4byte 0x01000293  # addi t0, zero, 16
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3bc2e457  # vslide1up.vx v8, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, t0
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x5e02c557  # vmv.v.x v10, t0
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3bc2e557  # vslide1up.vx v10, v28, t0
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0x3aa2ee57  # vslide1up.vx v28, v10, t0
.4byte 0x5e0e0557  # vmv.v.v v10, v28
.4byte 0x55556437  # lui s0, 0x55556
.4byte 0x66640413  # addi s0, s0, 1638
.4byte 0x02041413  # slli s0, s0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f46433  # or s0, s0, t6
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xf2a42857  # vwmaccu.vv v16, v8, v10
.assert trap == 0 "vwmaccu.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffff7ffffff0 "vwmaccu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x8fffffff80000000 "vwmaccu.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x8000000000000030 "vwmaccu.vv e32 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xf2a46857  # vwmaccu.vx v16, s0, v10
.assert trap == 0 "vwmaccu.vx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccu.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x7fffffff7ffffff0 "vwmaccu.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x5000000000000000 "vwmaccu.vx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccu.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x8000000180000000 "vwmaccu.vx e32 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xf6a42857  # vwmacc.vv v16, v8, v10
.assert trap == 0 "vwmacc.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmacc.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x7ffffff0 "vwmacc.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vv e32 lane 1 writes x10"
.assert rd_wdata == 0x1000000080000000 "vwmacc.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x8000000000000030 "vwmacc.vv e32 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xf6a46857  # vwmacc.vx v16, s0, v10
.assert trap == 0 "vwmacc.vx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmacc.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x7ffffff0 "vwmacc.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x5000000000000000 "vwmacc.vx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x7ffffffe80000000 "vwmacc.vx e32 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xfea42857  # vwmaccsu.vv v16, v8, v10
.assert trap == 0 "vwmaccsu.vv e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccsu.vv e32 lane 0 writes x10"
.assert rd_wdata == 0x800000007ffffff0 "vwmaccsu.vv e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vv e32 lane 1 writes x10"
.assert rd_wdata == 0xfffffff80000000 "vwmaccsu.vv e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vv e32 lane 2 writes x10"
.assert rd_wdata == 0x8000000000000030 "vwmaccsu.vv e32 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xfea46857  # vwmaccsu.vx v16, s0, v10
.assert trap == 0 "vwmaccsu.vx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccsu.vx e32 lane 0 writes x10"
.assert rd_wdata == 0x800000007ffffff0 "vwmaccsu.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vx e32 lane 1 writes x10"
.assert rd_wdata == 0xd000000000000000 "vwmaccsu.vx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccsu.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x7ffffffe80000000 "vwmaccsu.vx e32 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xfaa46857  # vwmaccus.vx v16, s0, v10
.assert trap == 0 "vwmaccus.vx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccus.vx e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffff7ffffff0 "vwmaccus.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccus.vx e32 lane 1 writes x10"
.assert rd_wdata == 0xd000000000000000 "vwmaccus.vx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccus.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x8000000180000000 "vwmaccus.vx e32 lane 2"
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e0b0857  # vmv.v.v v16, v22
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xf8a46857  # vwmaccus.vx v16, s0, v10, v0.t
.assert trap == 0 "vwmaccus.vx e32 retires"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmaccus.vx e32 lane 0 writes x10"
.assert rd_wdata == 0xffffffff7ffffff0 "vwmaccus.vx e32 lane 0"
.4byte 0x3f00be57  # vslidedown.vi v28, v16, 1
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccus.vx e32 lane 1 writes x10"
.assert rd_wdata == 0x1000000000000000 "vwmaccus.vx e32 lane 1"
.4byte 0x3f013e57  # vslidedown.vi v28, v16, 2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccus.vx e32 lane 2 writes x10"
.assert rd_wdata == 0x8000000180000000 "vwmaccus.vx e32 lane 2"
.4byte 0x3f01be57  # vslidedown.vi v28, v16, 3
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmaccus.vx e32 tail lane 3 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "vwmaccus.vx e32 tail lane 3"
.4byte 0x01907657  # vsetvli a2, zero, e64, m2, tu, mu
.4byte 0x5e02b857  # vmv.v.i v16, 5
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0xf682e857  # vwmacc.vx v16, t0, v8
.assert trap == 0 "vwmacc.vx e32 VLMAX retires"
.4byte 0x01907657  # vsetvli a2, zero, e64, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwmacc.vx e32 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x5 "vwmacc.vx e32 VLMAX lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwmacc.vx e32 VLMAX last lane writes x10"

# Section 6: vl=0 preservation, fractional LMUL, m2->m4 and illegal traps.
.4byte 0x011072d7  # vsetvli t0, zero, e32, m2, tu, mu
.4byte 0x5e09c857  # vmv.v.x v16, s3
.4byte 0xc0807657  # vsetivli a2, 0, e16, m1, tu, mu
.assert rd_addr == 12 "vl=0 writes x12"
.assert rd_wdata == 0x0 "vl=0"
.4byte 0xc6852857  # vwadd.vv v16, v8, v10
.assert trap == 0 "vwadd.vv vl=0 retires"
.4byte 0x4a83a857  # vsext.vf2 v16, v8
.assert trap == 0 "vsext.vf2 vl=0 retires"
.4byte 0xb7450857  # vnsra.wv v16, v20, v10
.assert trap == 0 "vnsra.wv vl=0 retires"
.4byte 0xee852857  # vwmul.vv v16, v8, v10
.assert trap == 0 "vwmul.vv vl=0 retires"
.4byte 0xf6a42857  # vwmacc.vv v16, v8, v10
.assert trap == 0 "vwmacc.vv vl=0 retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl=0 leaves destination unchanged writes x10"
.assert rd_wdata == 0x5a5aa5a5 "vl=0 leaves destination unchanged"
.4byte 0x00f07657  # vsetvli a2, zero, e16, mf2, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0xc682e857  # vwadd.vx v16, v8, t0
.assert trap == 0 "vwadd.vx e16 mf2 VLMAX retires"
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwadd.vx e16 mf2 VLMAX lane 0 writes x10"
.assert rd_wdata == 0xffffffffffff8000 "vwadd.vx e16 mf2 VLMAX lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwadd.vx e16 mf2 VLMAX last lane writes x10"
.4byte 0x00907657  # vsetvli a2, zero, e16, m2, tu, mu
.4byte 0x5208a457  # vid.v v8
.4byte 0x000082b7  # lui t0, 0x8
.4byte 0xfff28293  # addi t0, t0, -1
.4byte 0xc282e857  # vwaddu.vx v16, v8, t0
.assert trap == 0 "vwaddu.vx e16 m2 VLMAX retires"
.4byte 0x01207657  # vsetvli a2, zero, e32, m4, tu, mu
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vwaddu.vx e16 m2 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x7fff "vwaddu.vx e16 m2 VLMAX lane 0"
.4byte 0x000e0393  # addi t2, t3, 0
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3f03ce57  # vslidedown.vx v28, v16, t2
.4byte 0x43c02557  # vmv.x.s a0, v28
.assert rd_addr == 10 "vwaddu.vx e16 m2 VLMAX last lane writes x10"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xc6852857  # vwadd.vv v16, v8, v10
.assert trap == 1 "vwadd.vv at e64 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vwadd.vv at e64 traps mcause writes x10"
.assert rd_wdata == 0x2 "vwadd.vv at e64 traps raises illegal instruction"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xb3450857  # vnsrl.wv v16, v20, v10
.assert trap == 1 "vnsrl.wv at e64 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vnsrl.wv at e64 traps mcause writes x10"
.assert rd_wdata == 0x2 "vnsrl.wv at e64 traps raises illegal instruction"
.4byte 0xc0b0f657  # vsetivli a2, 1, e16, m8, tu, mu
.4byte 0xee8c2857  # vwmul.vv v16, v8, v24
.assert trap == 1 "vwmul.vv at m8 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vwmul.vv at m8 traps mcause writes x10"
.assert rd_wdata == 0x2 "vwmul.vv at m8 traps raises illegal instruction"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x4a832857  # vzext.vf2 v16, v8
.assert trap == 1 "vzext.vf2 at e8 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vzext.vf2 at e8 traps mcause writes x10"
.assert rd_wdata == 0x2 "vzext.vf2 at e8 traps raises illegal instruction"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x4a82a857  # vsext.vf4 v16, v8
.assert trap == 1 "vsext.vf4 at e16 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vsext.vf4 at e16 traps mcause writes x10"
.assert rd_wdata == 0x2 "vsext.vf4 at e16 traps raises illegal instruction"
