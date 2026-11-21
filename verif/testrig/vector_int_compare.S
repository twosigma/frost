# Vector integer predicates and active mask bits.
.noshrink
# Set VS and initialize four 32-bit integer lanes and their operands.
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x4 "four active lanes"
.4byte 0x5e0fb457  # vmv.v.i v8, -1
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x3a90b457  # vslideup.vi v8, v9, 1
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e4d7  # vmv.s.x v9, t0
.4byte 0x3a913457  # vslideup.vi v8, v9, 2
.4byte 0x400002b7  # lui t0, 0x40000
.4byte 0x4202e4d7  # vmv.s.x v9, t0
.4byte 0x3a91b457  # vslideup.vi v8, v9, 3
.4byte 0x5e040557  # vmv.v.v v10, v8
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x42036557  # vmv.s.x v10, t1
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x4202e4d7  # vmv.s.x v9, t0
.4byte 0x3a91b557  # vslideup.vi v10, v9, 3

# Vector predicates compare each pair of lanes.
.4byte 0x62850057  # vmseq.vv v0, v8, v10
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003cd7  # vmv.v.i v25, 0
.4byte 0x5d90bcd7  # vmerge.vim v25, v25, 1, v0
.4byte 0x43902557  # vmv.x.s a0, v25
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f90ba57  # vslidedown.vi v20, v25, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f913a57  # vslidedown.vi v20, v25, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 2"
.4byte 0x3f91ba57  # vslidedown.vi v20, v25, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x66850057  # vmsne.vv v0, v8, v10
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"
.4byte 0x6a850057  # vmsltu.vv v0, v8, v10
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"
.4byte 0x6e850057  # vmslt.vv v0, v8, v10
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x72850057  # vmsleu.vv v0, v8, v10
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"
.4byte 0x76850057  # vmsle.vv v0, v8, v10
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"

# Scalar predicates compare each lane with zero or one.
.4byte 0x62804057  # vmseq.vx v0, v8, zero
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x66804057  # vmsne.vx v0, v8, zero
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"
.4byte 0x6a834057  # vmsltu.vx v0, v8, t1
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x6e804057  # vmslt.vx v0, v8, zero
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x72804057  # vmsleu.vx v0, v8, zero
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x76804057  # vmsle.vx v0, v8, zero
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x7a804057  # vmsgtu.vx v0, v8, zero
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"
.4byte 0x7e804057  # vmsgt.vx v0, v8, zero
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"

# Immediate predicates use sign-extended negative values.
.4byte 0x628fb057  # vmseq.vi v0, v8, -1
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x668fb057  # vmsne.vi v0, v8, -1
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"
.4byte 0x728f3057  # vmsleu.vi v0, v8, -2
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"
.4byte 0x768fb057  # vmsle.vi v0, v8, -1
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x7a8f3057  # vmsgtu.vi v0, v8, -2
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 3"
.4byte 0x7e8fb057  # vmsgt.vi v0, v8, -1
.assert trap == 0 "integer comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"

# A guarded compare updates enabled bits and preserves disabled bits.
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x00e00293  # addi t0, zero, 14
.4byte 0x4202ecd7  # vmv.s.x v25, t0
.4byte 0x6c804cd7  # vmslt.vx v25, v8, zero, v0.t
.assert trap == 0 "masked comparison retires"
.4byte 0x679ca057  # vmand.mm v0, v25, v25
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 1"
.4byte 0x3f013a57  # vslidedown.vi v20, v16, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "predicate lane 2"
.4byte 0x3f01ba57  # vslidedown.vi v20, v16, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "predicate lane 3"

# At SEW 64, lane zero differs at bit 32 and lane one is equal.
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "active vector length writes x12"
.assert rd_wdata == 0x2 "two active e64 lanes"
.4byte 0xc21025f3  # csrr a1, vtype
.assert rd_addr == 11 "vector type writes x11"
.assert rd_wdata == 0x18 "e64 m1 tail and mask undisturbed"
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x4202e457  # vmv.s.x v8, t0
.4byte 0x5e003557  # vmv.v.i v10, 0
.4byte 0x62850057  # vmseq.vv v0, v8, v10
.assert trap == 0 "e64 equality comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "e64 equality lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "e64 equality lane 1"

# Compare zero against 2^32 and 2^63 with the same operands for both predicates.
.4byte 0x01f29293  # slli t0, t0, 31
.4byte 0x4202e4d7  # vmv.s.x v9, t0
.4byte 0x3a90b457  # vslideup.vi v8, v9, 1
.4byte 0x6ea40057  # vmslt.vv v0, v10, v8
.assert trap == 0 "e64 signed comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "e64 signed less-than lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x0 "e64 signed less-than lane 1"
.4byte 0x6aa40057  # vmsltu.vv v0, v10, v8
.assert trap == 0 "e64 unsigned comparison retires"
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5d00b857  # vmerge.vim v16, v16, 1, v0
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "e64 unsigned less-than lane zero"
.4byte 0x3f00ba57  # vslidedown.vi v20, v16, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "lane read writes x10"
.assert rd_wdata == 0x1 "e64 unsigned less-than lane 1"
