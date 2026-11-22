# Whole-register vector loads and stores in cached DDR.
.noshrink

# Enable VS, zero v0..v31, and form cached DDR source/destination bases.
.4byte 0x60000293  # addi t0, zero, 1536
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0
.4byte 0x40008437  # lui s0, 0x40008
.4byte 0x00141413  # slli s0, s0, 1
.4byte 0x40040493  # addi s1, s0, 1024
.4byte 0x11070f37  # lui t5, 0x11070
.4byte 0x503f0f13  # addi t5, t5, 1283
.4byte 0x020f1f13  # slli t5, t5, 32
.4byte 0x0b0d0fb7  # lui t6, 0xb0d0
.4byte 0x711f8f93  # addi t6, t6, 1809
.4byte 0x01ff6f33  # or t5, t5, t6
.4byte 0x5a5ac3b7  # lui t2, 0x5a5ac
.4byte 0x3c338393  # addi t2, t2, 963
.4byte 0x02039393  # slli t2, t2, 32
.4byte 0xa5a54fb7  # lui t6, 0xa5a54
.4byte 0xc3cf8f93  # addi t6, t6, -964
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f3e3b3  # or t2, t2, t6
.4byte 0x6d6d9e37  # lui t3, 0x6d6d9
.4byte 0x292e0e13  # addi t3, t3, 658
.4byte 0x020e1e13  # slli t3, t3, 32
.4byte 0x55aa3fb7  # lui t6, 0x55aa3
.4byte 0x3ccf8f93  # addi t6, t6, 972
.4byte 0x01fe6e33  # or t3, t3, t6

# Seed first two source doublewords and run vl1re64.v control on v12.
.4byte 0x13572337  # lui t1, 0x13572
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9acecfb7  # lui t6, 0x9acec
.4byte 0xdf1f8f93  # addi t6, t6, -527
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03c657  # vmv.v.x v12, t2
.4byte 0x5e03c6d7  # vmv.v.x v13, t2
.4byte 0x02847607  # vl1re64.v v12, (s0)
.assert trap == 0 "vl1re64.v control retires"
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vl1re64 control lane 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vl1re64 control lane 0"
.4byte 0x3ec0bed7  # vslidedown.vi v29, v12, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl1re64 control lane 1 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vl1re64 control lane 1"
.4byte 0x42d02557  # vmv.x.s a0, v13
.assert rd_addr == 10 "vl1re64 neighbor v13 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl1re64 neighbor v13 undisturbed"

# Fill remaining 62 unique doublewords in s0[16..511] (512 bytes total).
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643c23  # sd t1, 24(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02643023  # sd t1, 32(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02643423  # sd t1, 40(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02643823  # sd t1, 48(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02643c23  # sd t1, 56(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x04643023  # sd t1, 64(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x04643423  # sd t1, 72(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x04643823  # sd t1, 80(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x04643c23  # sd t1, 88(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x06643023  # sd t1, 96(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x06643423  # sd t1, 104(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x06643823  # sd t1, 112(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x06643c23  # sd t1, 120(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x08643023  # sd t1, 128(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x08643423  # sd t1, 136(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x08643823  # sd t1, 144(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x08643c23  # sd t1, 152(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0a643023  # sd t1, 160(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0a643423  # sd t1, 168(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0a643823  # sd t1, 176(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0a643c23  # sd t1, 184(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0c643023  # sd t1, 192(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0c643423  # sd t1, 200(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0c643823  # sd t1, 208(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0c643c23  # sd t1, 216(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0e643023  # sd t1, 224(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0e643423  # sd t1, 232(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0e643823  # sd t1, 240(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0e643c23  # sd t1, 248(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x10643023  # sd t1, 256(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x10643423  # sd t1, 264(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x10643823  # sd t1, 272(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x10643c23  # sd t1, 280(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x12643023  # sd t1, 288(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x12643423  # sd t1, 296(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x12643823  # sd t1, 304(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x12643c23  # sd t1, 312(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x14643023  # sd t1, 320(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x14643423  # sd t1, 328(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x14643823  # sd t1, 336(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x14643c23  # sd t1, 344(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x16643023  # sd t1, 352(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x16643423  # sd t1, 360(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x16643823  # sd t1, 368(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x16643c23  # sd t1, 376(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x18643023  # sd t1, 384(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x18643423  # sd t1, 392(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x18643823  # sd t1, 400(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x18643c23  # sd t1, 408(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1a643023  # sd t1, 416(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1a643423  # sd t1, 424(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1a643823  # sd t1, 432(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1a643c23  # sd t1, 440(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1c643023  # sd t1, 448(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1c643423  # sd t1, 456(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1c643823  # sd t1, 464(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1c643c23  # sd t1, 472(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1e643023  # sd t1, 480(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1e643423  # sd t1, 488(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1e643823  # sd t1, 496(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x1e643c23  # sd t1, 504(s0)

# 1-register loads: vl1re8.v (+0), vl1re16.v (+2), vl1re32.v (+4), vl1re64.v (+8).
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x02840407  # vl1re8.v v8, (s0)
.assert trap == 0 "vl1re8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl1re8 lane 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vl1re8 lane 0"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl1re8 lane 1 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vl1re8 lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl1re8 neighbor v9 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl1re8 neighbor v9 undisturbed"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x00240a13  # addi s4, s0, 2
.4byte 0x028a5407  # vl1re16.v v8, (s4)
.assert trap == 0 "vl1re16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl1re16 lane 0 writes x10"
.assert rd_wdata == 0xc502135724689ace "vl1re16 lane 0"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl1re16 lane 1 writes x10"
.assert rd_wdata == 0xcc13245e296ba5db "vl1re16 lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl1re16 neighbor v9 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl1re16 neighbor v9 undisturbed"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x00440a13  # addi s4, s0, 4
.4byte 0x028a6407  # vl1re32.v v8, (s4)
.assert trap == 0 "vl1re32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl1re32 lane 0 writes x10"
.assert rd_wdata == 0xa5dbc50213572468 "vl1re32 lane 0"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl1re32 lane 1 writes x10"
.assert rd_wdata == 0xb0e8cc13245e296b "vl1re32 lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl1re32 neighbor v9 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl1re32 neighbor v9 undisturbed"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x00840a13  # addi s4, s0, 8
.4byte 0x028a7407  # vl1re64.v v8, (s4)
.assert trap == 0 "vl1re64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl1re64 lane 0 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vl1re64 lane 0"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl1re64 lane 1 writes x10"
.assert rd_wdata == 0x35652e6eb0e8cc13 "vl1re64 lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl1re64 neighbor v9 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl1re64 neighbor v9 undisturbed"

# 2-register loads: vl2re8.v, vl2re16.v, vl2re32.v, vl2re64.v.
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x5e03c557  # vmv.v.x v10, t2
.4byte 0x22840407  # vl2re8.v v8, (s0)
.assert trap == 0 "vl2re8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl2re8 v8 lane 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vl2re8 v8 lane 0"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl2re8 v9 lane 0 writes x10"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vl2re8 neighbor v10 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl2re8 neighbor v10 undisturbed"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x5e03c557  # vmv.v.x v10, t2
.4byte 0x00240a13  # addi s4, s0, 2
.4byte 0x228a5407  # vl2re16.v v8, (s4)
.assert trap == 0 "vl2re16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl2re16 v8 lane 0 writes x10"
.assert rd_wdata == 0xc502135724689ace "vl2re16 v8 lane 0"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl2re16 v9 lane 0 writes x10"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vl2re16 neighbor v10 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl2re16 neighbor v10 undisturbed"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x5e03c557  # vmv.v.x v10, t2
.4byte 0x00440a13  # addi s4, s0, 4
.4byte 0x228a6407  # vl2re32.v v8, (s4)
.assert trap == 0 "vl2re32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl2re32 v8 lane 0 writes x10"
.assert rd_wdata == 0xa5dbc50213572468 "vl2re32 v8 lane 0"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl2re32 v9 lane 0 writes x10"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vl2re32 neighbor v10 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl2re32 neighbor v10 undisturbed"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x5e03c557  # vmv.v.x v10, t2
.4byte 0x01040a13  # addi s4, s0, 16
.4byte 0x228a7407  # vl2re64.v v8, (s4)
.assert trap == 0 "vl2re64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl2re64 v8 lane 0 writes x10"
.assert rd_wdata == 0x35652e6eb0e8cc13 "vl2re64 v8 lane 0"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl2re64 v9 lane 0 writes x10"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vl2re64 neighbor v10 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl2re64 neighbor v10 undisturbed"

# 4-register loads: vl4re8.v, vl4re16.v, vl4re32.v, vl4re64.v.
.4byte 0x01a072d7  # vsetvli t0, zero, e64, m4, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03ca57  # vmv.v.x v20, t2
.4byte 0x62840807  # vl4re8.v v16, (s0)
.assert trap == 0 "vl4re8.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl4re8 v16 lane 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vl4re8 v16 lane 0"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "vl4re8 v17 lane 0 writes x10"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vl4re8 v18 lane 0 writes x10"
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "vl4re8 v19 lane 0 writes x10"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vl4re8 neighbor v20 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl4re8 neighbor v20 undisturbed"
.4byte 0x01a072d7  # vsetvli t0, zero, e64, m4, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03ca57  # vmv.v.x v20, t2
.4byte 0x00240a13  # addi s4, s0, 2
.4byte 0x628a5807  # vl4re16.v v16, (s4)
.assert trap == 0 "vl4re16.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl4re16 v16 lane 0 writes x10"
.assert rd_wdata == 0xc502135724689ace "vl4re16 v16 lane 0"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "vl4re16 v17 lane 0 writes x10"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vl4re16 v18 lane 0 writes x10"
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "vl4re16 v19 lane 0 writes x10"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vl4re16 neighbor v20 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl4re16 neighbor v20 undisturbed"
.4byte 0x01a072d7  # vsetvli t0, zero, e64, m4, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03ca57  # vmv.v.x v20, t2
.4byte 0x00440a13  # addi s4, s0, 4
.4byte 0x628a6807  # vl4re32.v v16, (s4)
.assert trap == 0 "vl4re32.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl4re32 v16 lane 0 writes x10"
.assert rd_wdata == 0xa5dbc50213572468 "vl4re32 v16 lane 0"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "vl4re32 v17 lane 0 writes x10"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vl4re32 v18 lane 0 writes x10"
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "vl4re32 v19 lane 0 writes x10"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vl4re32 neighbor v20 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl4re32 neighbor v20 undisturbed"
.4byte 0x01a072d7  # vsetvli t0, zero, e64, m4, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03ca57  # vmv.v.x v20, t2
.4byte 0x02040a13  # addi s4, s0, 32
.4byte 0x628a7807  # vl4re64.v v16, (s4)
.assert trap == 0 "vl4re64.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl4re64 v16 lane 0 writes x10"
.assert rd_wdata == 0x57733874c702da35 "vl4re64 v16 lane 0"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "vl4re64 v17 lane 0 writes x10"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vl4re64 v18 lane 0 writes x10"
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "vl4re64 v19 lane 0 writes x10"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vl4re64 neighbor v20 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl4re64 neighbor v20 undisturbed"

# 8-register loads: vl8re8.v, vl8re16.v, vl8re32.v, vl8re64.v.
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03cc57  # vmv.v.x v24, t2
.4byte 0xe2840807  # vl8re8.v v16, (s0)
.assert trap == 0 "vl8re8.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl8re8 v16 lane 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vl8re8 v16 lane 0"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "vl8re8 v17 lane 0 writes x10"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vl8re8 v18 lane 0 writes x10"
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "vl8re8 v19 lane 0 writes x10"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vl8re8 v20 lane 0 writes x10"
.4byte 0x43502557  # vmv.x.s a0, v21
.assert rd_addr == 10 "vl8re8 v21 lane 0 writes x10"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vl8re8 v22 lane 0 writes x10"
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vl8re8 v23 lane 0 writes x10"
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vl8re8 neighbor v24 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl8re8 neighbor v24 undisturbed"
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03cc57  # vmv.v.x v24, t2
.4byte 0xe2845807  # vl8re16.v v16, (s0)
.assert trap == 0 "vl8re16.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl8re16 v16 lane 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vl8re16 v16 lane 0"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "vl8re16 v17 lane 0 writes x10"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vl8re16 v18 lane 0 writes x10"
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "vl8re16 v19 lane 0 writes x10"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vl8re16 v20 lane 0 writes x10"
.4byte 0x43502557  # vmv.x.s a0, v21
.assert rd_addr == 10 "vl8re16 v21 lane 0 writes x10"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vl8re16 v22 lane 0 writes x10"
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vl8re16 v23 lane 0 writes x10"
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vl8re16 neighbor v24 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl8re16 neighbor v24 undisturbed"
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03cc57  # vmv.v.x v24, t2
.4byte 0xe2846807  # vl8re32.v v16, (s0)
.assert trap == 0 "vl8re32.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl8re32 v16 lane 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vl8re32 v16 lane 0"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "vl8re32 v17 lane 0 writes x10"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vl8re32 v18 lane 0 writes x10"
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "vl8re32 v19 lane 0 writes x10"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vl8re32 v20 lane 0 writes x10"
.4byte 0x43502557  # vmv.x.s a0, v21
.assert rd_addr == 10 "vl8re32 v21 lane 0 writes x10"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vl8re32 v22 lane 0 writes x10"
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vl8re32 v23 lane 0 writes x10"
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vl8re32 neighbor v24 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl8re32 neighbor v24 undisturbed"
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e03c857  # vmv.v.x v16, t2
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e03cc57  # vmv.v.x v24, t2
.4byte 0xe2847807  # vl8re64.v v16, (s0)
.assert trap == 0 "vl8re64.v retires"
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl8re64 v16 lane 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vl8re64 v16 lane 0"
.4byte 0x43102557  # vmv.x.s a0, v17
.assert rd_addr == 10 "vl8re64 v17 lane 0 writes x10"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "vl8re64 v18 lane 0 writes x10"
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "vl8re64 v19 lane 0 writes x10"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vl8re64 v20 lane 0 writes x10"
.4byte 0x43502557  # vmv.x.s a0, v21
.assert rd_addr == 10 "vl8re64 v21 lane 0 writes x10"
.4byte 0x43602557  # vmv.x.s a0, v22
.assert rd_addr == 10 "vl8re64 v22 lane 0 writes x10"
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "vl8re64 v23 lane 0 writes x10"
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vl8re64 neighbor v24 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl8re64 neighbor v24 undisturbed"

# Whole-register stores: vs1r.v, vs2r.v, vs4r.v, vs8r.v with full VLEN-512 readbacks.
.4byte 0x02847407  # vl1re64.v v8, (s0)
.assert trap == 0 "vl1re64.v before vs1r retires"
.4byte 0x01c4b023  # sd t3, 0(s1)
.4byte 0x05c4b023  # sd t3, 64(s1)
.4byte 0x02848427  # vs1r.v v8, (s1)
.assert trap == 0 "vs1r.v base retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "vs1r base dw 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vs1r base dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "vs1r base dw 1 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vs1r base dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "vs1r base dw 2 writes x10"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "vs1r base dw 3 writes x10"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "vs1r base dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "vs1r base dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "vs1r base dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "vs1r base dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "vs1r base guard untouched writes x10"
.assert rd_wdata == 0x6d6d929255aa33cc "vs1r base guard untouched"
.4byte 0x08048a13  # addi s4, s1, 128
.4byte 0x22846407  # vl2re32.v v8, (s0)
.assert trap == 0 "vl2re32.v before vs2r retires"
.4byte 0x01ca3023  # sd t3, 0(s4)
.4byte 0x09ca3023  # sd t3, 128(s4)
.4byte 0x228a0427  # vs2r.v v8, (s4)
.assert trap == 0 "vs2r.v base retires"
.4byte 0x000a3503  # ld a0, 0(s4)
.assert rd_addr == 10 "vs2r base dw 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vs2r base dw 0"
.4byte 0x008a3503  # ld a0, 8(s4)
.assert rd_addr == 10 "vs2r base dw 1 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vs2r base dw 1"
.4byte 0x010a3503  # ld a0, 16(s4)
.assert rd_addr == 10 "vs2r base dw 2 writes x10"
.assert rd_wdata == 0x35652e6eb0e8cc13 "vs2r base dw 2"
.4byte 0x018a3503  # ld a0, 24(s4)
.assert rd_addr == 10 "vs2r base dw 3 writes x10"
.assert rd_wdata == 0x466c3371bbf5d324 "vs2r base dw 3"
.4byte 0x020a3503  # ld a0, 32(s4)
.assert rd_addr == 10 "vs2r base dw 4 writes x10"
.4byte 0x028a3503  # ld a0, 40(s4)
.assert rd_addr == 10 "vs2r base dw 5 writes x10"
.4byte 0x030a3503  # ld a0, 48(s4)
.assert rd_addr == 10 "vs2r base dw 6 writes x10"
.4byte 0x038a3503  # ld a0, 56(s4)
.assert rd_addr == 10 "vs2r base dw 7 writes x10"
.4byte 0x040a3503  # ld a0, 64(s4)
.assert rd_addr == 10 "vs2r base dw 8 writes x10"
.4byte 0x048a3503  # ld a0, 72(s4)
.assert rd_addr == 10 "vs2r base dw 9 writes x10"
.4byte 0x050a3503  # ld a0, 80(s4)
.assert rd_addr == 10 "vs2r base dw 10 writes x10"
.4byte 0x058a3503  # ld a0, 88(s4)
.assert rd_addr == 10 "vs2r base dw 11 writes x10"
.4byte 0x060a3503  # ld a0, 96(s4)
.assert rd_addr == 10 "vs2r base dw 12 writes x10"
.4byte 0x068a3503  # ld a0, 104(s4)
.assert rd_addr == 10 "vs2r base dw 13 writes x10"
.4byte 0x070a3503  # ld a0, 112(s4)
.assert rd_addr == 10 "vs2r base dw 14 writes x10"
.4byte 0x078a3503  # ld a0, 120(s4)
.assert rd_addr == 10 "vs2r base dw 15 writes x10"
.4byte 0x080a3503  # ld a0, 128(s4)
.assert rd_addr == 10 "vs2r base guard untouched writes x10"
.assert rd_wdata == 0x6d6d929255aa33cc "vs2r base guard untouched"
.4byte 0x18048a13  # addi s4, s1, 384
.4byte 0x62845807  # vl4re16.v v16, (s0)
.assert trap == 0 "vl4re16.v before vs4r retires"
.4byte 0x01ca3023  # sd t3, 0(s4)
.4byte 0x11ca3023  # sd t3, 256(s4)
.4byte 0x628a0827  # vs4r.v v16, (s4)
.assert trap == 0 "vs4r.v base retires"
.4byte 0x000a3503  # ld a0, 0(s4)
.assert rd_addr == 10 "vs4r base dw 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vs4r base dw 0"
.4byte 0x008a3503  # ld a0, 8(s4)
.assert rd_addr == 10 "vs4r base dw 1 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vs4r base dw 1"
.4byte 0x010a3503  # ld a0, 16(s4)
.assert rd_addr == 10 "vs4r base dw 2 writes x10"
.assert rd_wdata == 0x35652e6eb0e8cc13 "vs4r base dw 2"
.4byte 0x018a3503  # ld a0, 24(s4)
.assert rd_addr == 10 "vs4r base dw 3 writes x10"
.assert rd_wdata == 0x466c3371bbf5d324 "vs4r base dw 3"
.4byte 0x020a3503  # ld a0, 32(s4)
.assert rd_addr == 10 "vs4r base dw 4 writes x10"
.assert rd_wdata == 0x57733874c702da35 "vs4r base dw 4"
.4byte 0x028a3503  # ld a0, 40(s4)
.assert rd_addr == 10 "vs4r base dw 5 writes x10"
.assert rd_wdata == 0x687a3d77d20fe146 "vs4r base dw 5"
.4byte 0x030a3503  # ld a0, 48(s4)
.assert rd_addr == 10 "vs4r base dw 6 writes x10"
.assert rd_wdata == 0x7981427add1ce857 "vs4r base dw 6"
.4byte 0x038a3503  # ld a0, 56(s4)
.assert rd_addr == 10 "vs4r base dw 7 writes x10"
.assert rd_wdata == 0x8a88477de829ef68 "vs4r base dw 7"
.4byte 0x040a3503  # ld a0, 64(s4)
.assert rd_addr == 10 "vs4r base dw 8 writes x10"
.4byte 0x048a3503  # ld a0, 72(s4)
.assert rd_addr == 10 "vs4r base dw 9 writes x10"
.4byte 0x050a3503  # ld a0, 80(s4)
.assert rd_addr == 10 "vs4r base dw 10 writes x10"
.4byte 0x058a3503  # ld a0, 88(s4)
.assert rd_addr == 10 "vs4r base dw 11 writes x10"
.4byte 0x060a3503  # ld a0, 96(s4)
.assert rd_addr == 10 "vs4r base dw 12 writes x10"
.4byte 0x068a3503  # ld a0, 104(s4)
.assert rd_addr == 10 "vs4r base dw 13 writes x10"
.4byte 0x070a3503  # ld a0, 112(s4)
.assert rd_addr == 10 "vs4r base dw 14 writes x10"
.4byte 0x078a3503  # ld a0, 120(s4)
.assert rd_addr == 10 "vs4r base dw 15 writes x10"
.4byte 0x080a3503  # ld a0, 128(s4)
.assert rd_addr == 10 "vs4r base dw 16 writes x10"
.4byte 0x088a3503  # ld a0, 136(s4)
.assert rd_addr == 10 "vs4r base dw 17 writes x10"
.4byte 0x090a3503  # ld a0, 144(s4)
.assert rd_addr == 10 "vs4r base dw 18 writes x10"
.4byte 0x098a3503  # ld a0, 152(s4)
.assert rd_addr == 10 "vs4r base dw 19 writes x10"
.4byte 0x0a0a3503  # ld a0, 160(s4)
.assert rd_addr == 10 "vs4r base dw 20 writes x10"
.4byte 0x0a8a3503  # ld a0, 168(s4)
.assert rd_addr == 10 "vs4r base dw 21 writes x10"
.4byte 0x0b0a3503  # ld a0, 176(s4)
.assert rd_addr == 10 "vs4r base dw 22 writes x10"
.4byte 0x0b8a3503  # ld a0, 184(s4)
.assert rd_addr == 10 "vs4r base dw 23 writes x10"
.4byte 0x0c0a3503  # ld a0, 192(s4)
.assert rd_addr == 10 "vs4r base dw 24 writes x10"
.4byte 0x0c8a3503  # ld a0, 200(s4)
.assert rd_addr == 10 "vs4r base dw 25 writes x10"
.4byte 0x0d0a3503  # ld a0, 208(s4)
.assert rd_addr == 10 "vs4r base dw 26 writes x10"
.4byte 0x0d8a3503  # ld a0, 216(s4)
.assert rd_addr == 10 "vs4r base dw 27 writes x10"
.4byte 0x0e0a3503  # ld a0, 224(s4)
.assert rd_addr == 10 "vs4r base dw 28 writes x10"
.4byte 0x0e8a3503  # ld a0, 232(s4)
.assert rd_addr == 10 "vs4r base dw 29 writes x10"
.4byte 0x0f0a3503  # ld a0, 240(s4)
.assert rd_addr == 10 "vs4r base dw 30 writes x10"
.4byte 0x0f8a3503  # ld a0, 248(s4)
.assert rd_addr == 10 "vs4r base dw 31 writes x10"
.4byte 0x100a3503  # ld a0, 256(s4)
.assert rd_addr == 10 "vs4r base guard untouched writes x10"
.assert rd_wdata == 0x6d6d929255aa33cc "vs4r base guard untouched"
.4byte 0x30048a13  # addi s4, s1, 768
.4byte 0xe2840807  # vl8re8.v v16, (s0)
.assert trap == 0 "vl8re8.v before vs8r retires"
.4byte 0x01ca3023  # sd t3, 0(s4)
.4byte 0x21ca3023  # sd t3, 512(s4)
.4byte 0xe28a0827  # vs8r.v v16, (s4)
.assert trap == 0 "vs8r.v base retires"
.4byte 0x000a3503  # ld a0, 0(s4)
.assert rd_addr == 10 "vs8r base dw 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vs8r base dw 0"
.4byte 0x008a3503  # ld a0, 8(s4)
.assert rd_addr == 10 "vs8r base dw 1 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vs8r base dw 1"
.4byte 0x010a3503  # ld a0, 16(s4)
.assert rd_addr == 10 "vs8r base dw 2 writes x10"
.assert rd_wdata == 0x35652e6eb0e8cc13 "vs8r base dw 2"
.4byte 0x018a3503  # ld a0, 24(s4)
.assert rd_addr == 10 "vs8r base dw 3 writes x10"
.assert rd_wdata == 0x466c3371bbf5d324 "vs8r base dw 3"
.4byte 0x020a3503  # ld a0, 32(s4)
.assert rd_addr == 10 "vs8r base dw 4 writes x10"
.assert rd_wdata == 0x57733874c702da35 "vs8r base dw 4"
.4byte 0x028a3503  # ld a0, 40(s4)
.assert rd_addr == 10 "vs8r base dw 5 writes x10"
.assert rd_wdata == 0x687a3d77d20fe146 "vs8r base dw 5"
.4byte 0x030a3503  # ld a0, 48(s4)
.assert rd_addr == 10 "vs8r base dw 6 writes x10"
.assert rd_wdata == 0x7981427add1ce857 "vs8r base dw 6"
.4byte 0x038a3503  # ld a0, 56(s4)
.assert rd_addr == 10 "vs8r base dw 7 writes x10"
.assert rd_wdata == 0x8a88477de829ef68 "vs8r base dw 7"
.4byte 0x040a3503  # ld a0, 64(s4)
.assert rd_addr == 10 "vs8r base dw 8 writes x10"
.assert rd_wdata == 0x9b8f4c80f336f679 "vs8r base dw 8"
.4byte 0x048a3503  # ld a0, 72(s4)
.assert rd_addr == 10 "vs8r base dw 9 writes x10"
.assert rd_wdata == 0xac965183fe43fd8a "vs8r base dw 9"
.4byte 0x050a3503  # ld a0, 80(s4)
.assert rd_addr == 10 "vs8r base dw 10 writes x10"
.assert rd_wdata == 0xbd9d56870951049b "vs8r base dw 10"
.4byte 0x058a3503  # ld a0, 88(s4)
.assert rd_addr == 10 "vs8r base dw 11 writes x10"
.assert rd_wdata == 0xcea45b8a145e0bac "vs8r base dw 11"
.4byte 0x060a3503  # ld a0, 96(s4)
.assert rd_addr == 10 "vs8r base dw 12 writes x10"
.assert rd_wdata == 0xdfab608d1f6b12bd "vs8r base dw 12"
.4byte 0x068a3503  # ld a0, 104(s4)
.assert rd_addr == 10 "vs8r base dw 13 writes x10"
.assert rd_wdata == 0xf0b265902a7819ce "vs8r base dw 13"
.4byte 0x070a3503  # ld a0, 112(s4)
.assert rd_addr == 10 "vs8r base dw 14 writes x10"
.assert rd_wdata == 0x1b96a93358520df "vs8r base dw 14"
.4byte 0x078a3503  # ld a0, 120(s4)
.assert rd_addr == 10 "vs8r base dw 15 writes x10"
.assert rd_wdata == 0x12c06f96409227f0 "vs8r base dw 15"
.4byte 0x080a3503  # ld a0, 128(s4)
.assert rd_addr == 10 "vs8r base dw 16 writes x10"
.4byte 0x088a3503  # ld a0, 136(s4)
.assert rd_addr == 10 "vs8r base dw 17 writes x10"
.4byte 0x090a3503  # ld a0, 144(s4)
.assert rd_addr == 10 "vs8r base dw 18 writes x10"
.4byte 0x098a3503  # ld a0, 152(s4)
.assert rd_addr == 10 "vs8r base dw 19 writes x10"
.4byte 0x0a0a3503  # ld a0, 160(s4)
.assert rd_addr == 10 "vs8r base dw 20 writes x10"
.4byte 0x0a8a3503  # ld a0, 168(s4)
.assert rd_addr == 10 "vs8r base dw 21 writes x10"
.4byte 0x0b0a3503  # ld a0, 176(s4)
.assert rd_addr == 10 "vs8r base dw 22 writes x10"
.4byte 0x0b8a3503  # ld a0, 184(s4)
.assert rd_addr == 10 "vs8r base dw 23 writes x10"
.4byte 0x0c0a3503  # ld a0, 192(s4)
.assert rd_addr == 10 "vs8r base dw 24 writes x10"
.4byte 0x0c8a3503  # ld a0, 200(s4)
.assert rd_addr == 10 "vs8r base dw 25 writes x10"
.4byte 0x0d0a3503  # ld a0, 208(s4)
.assert rd_addr == 10 "vs8r base dw 26 writes x10"
.4byte 0x0d8a3503  # ld a0, 216(s4)
.assert rd_addr == 10 "vs8r base dw 27 writes x10"
.4byte 0x0e0a3503  # ld a0, 224(s4)
.assert rd_addr == 10 "vs8r base dw 28 writes x10"
.4byte 0x0e8a3503  # ld a0, 232(s4)
.assert rd_addr == 10 "vs8r base dw 29 writes x10"
.4byte 0x0f0a3503  # ld a0, 240(s4)
.assert rd_addr == 10 "vs8r base dw 30 writes x10"
.4byte 0x0f8a3503  # ld a0, 248(s4)
.assert rd_addr == 10 "vs8r base dw 31 writes x10"
.4byte 0x100a3503  # ld a0, 256(s4)
.assert rd_addr == 10 "vs8r base dw 32 writes x10"
.4byte 0x108a3503  # ld a0, 264(s4)
.assert rd_addr == 10 "vs8r base dw 33 writes x10"
.4byte 0x110a3503  # ld a0, 272(s4)
.assert rd_addr == 10 "vs8r base dw 34 writes x10"
.4byte 0x118a3503  # ld a0, 280(s4)
.assert rd_addr == 10 "vs8r base dw 35 writes x10"
.4byte 0x120a3503  # ld a0, 288(s4)
.assert rd_addr == 10 "vs8r base dw 36 writes x10"
.4byte 0x128a3503  # ld a0, 296(s4)
.assert rd_addr == 10 "vs8r base dw 37 writes x10"
.4byte 0x130a3503  # ld a0, 304(s4)
.assert rd_addr == 10 "vs8r base dw 38 writes x10"
.4byte 0x138a3503  # ld a0, 312(s4)
.assert rd_addr == 10 "vs8r base dw 39 writes x10"
.4byte 0x140a3503  # ld a0, 320(s4)
.assert rd_addr == 10 "vs8r base dw 40 writes x10"
.4byte 0x148a3503  # ld a0, 328(s4)
.assert rd_addr == 10 "vs8r base dw 41 writes x10"
.4byte 0x150a3503  # ld a0, 336(s4)
.assert rd_addr == 10 "vs8r base dw 42 writes x10"
.4byte 0x158a3503  # ld a0, 344(s4)
.assert rd_addr == 10 "vs8r base dw 43 writes x10"
.4byte 0x160a3503  # ld a0, 352(s4)
.assert rd_addr == 10 "vs8r base dw 44 writes x10"
.4byte 0x168a3503  # ld a0, 360(s4)
.assert rd_addr == 10 "vs8r base dw 45 writes x10"
.4byte 0x170a3503  # ld a0, 368(s4)
.assert rd_addr == 10 "vs8r base dw 46 writes x10"
.4byte 0x178a3503  # ld a0, 376(s4)
.assert rd_addr == 10 "vs8r base dw 47 writes x10"
.4byte 0x180a3503  # ld a0, 384(s4)
.assert rd_addr == 10 "vs8r base dw 48 writes x10"
.4byte 0x188a3503  # ld a0, 392(s4)
.assert rd_addr == 10 "vs8r base dw 49 writes x10"
.4byte 0x190a3503  # ld a0, 400(s4)
.assert rd_addr == 10 "vs8r base dw 50 writes x10"
.4byte 0x198a3503  # ld a0, 408(s4)
.assert rd_addr == 10 "vs8r base dw 51 writes x10"
.4byte 0x1a0a3503  # ld a0, 416(s4)
.assert rd_addr == 10 "vs8r base dw 52 writes x10"
.4byte 0x1a8a3503  # ld a0, 424(s4)
.assert rd_addr == 10 "vs8r base dw 53 writes x10"
.4byte 0x1b0a3503  # ld a0, 432(s4)
.assert rd_addr == 10 "vs8r base dw 54 writes x10"
.4byte 0x1b8a3503  # ld a0, 440(s4)
.assert rd_addr == 10 "vs8r base dw 55 writes x10"
.4byte 0x1c0a3503  # ld a0, 448(s4)
.assert rd_addr == 10 "vs8r base dw 56 writes x10"
.4byte 0x1c8a3503  # ld a0, 456(s4)
.assert rd_addr == 10 "vs8r base dw 57 writes x10"
.4byte 0x1d0a3503  # ld a0, 464(s4)
.assert rd_addr == 10 "vs8r base dw 58 writes x10"
.4byte 0x1d8a3503  # ld a0, 472(s4)
.assert rd_addr == 10 "vs8r base dw 59 writes x10"
.4byte 0x1e0a3503  # ld a0, 480(s4)
.assert rd_addr == 10 "vs8r base dw 60 writes x10"
.4byte 0x1e8a3503  # ld a0, 488(s4)
.assert rd_addr == 10 "vs8r base dw 61 writes x10"
.4byte 0x1f0a3503  # ld a0, 496(s4)
.assert rd_addr == 10 "vs8r base dw 62 writes x10"
.4byte 0x1f8a3503  # ld a0, 504(s4)
.assert rd_addr == 10 "vs8r base dw 63 writes x10"
.4byte 0x200a3503  # ld a0, 512(s4)
.assert rd_addr == 10 "vs8r base guard untouched writes x10"
.assert rd_wdata == 0x6d6d929255aa33cc "vs8r base guard untouched"

# vill == 1 exemption: whole-register loads and stores retire despite vtype.vill == 1.
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x5e03c557  # vmv.v.x v10, t2
.4byte 0xc1f0f657  # vsetivli a2, 1, e64, mf2, tu, mu
.assert rd_addr == 12 "illegal vsetivli sets vl=0 writes x12"
.assert rd_wdata == 0x0 "illegal vsetivli sets vl=0"
.4byte 0xc2102573  # csrr a0, vtype
.assert rd_addr == 10 "vtype.vill is set writes x10"
.assert rd_wdata == 0x8000000000000000 "vtype.vill is set"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "vl is zero under vill writes x10"
.assert rd_wdata == 0x0 "vl is zero under vill"
.4byte 0x01040a13  # addi s4, s0, 16
.4byte 0x58048a93  # addi s5, s1, 1408
.4byte 0x028a6407  # vl1re32.v v8, (s4)
.assert trap == 0 "vl1re32.v under vill=1 retires"
.4byte 0x01cab023  # sd t3, 0(s5)
.4byte 0x05cab023  # sd t3, 64(s5)
.4byte 0x028a8427  # vs1r.v v8, (s5)
.assert trap == 0 "vs1r.v vill1 retires"
.4byte 0x000ab503  # ld a0, 0(s5)
.assert rd_addr == 10 "vs1r vill1 dw 0 writes x10"
.assert rd_wdata == 0x35652e6eb0e8cc13 "vs1r vill1 dw 0"
.4byte 0x008ab503  # ld a0, 8(s5)
.assert rd_addr == 10 "vs1r vill1 dw 1 writes x10"
.assert rd_wdata == 0x466c3371bbf5d324 "vs1r vill1 dw 1"
.4byte 0x010ab503  # ld a0, 16(s5)
.assert rd_addr == 10 "vs1r vill1 dw 2 writes x10"
.4byte 0x018ab503  # ld a0, 24(s5)
.assert rd_addr == 10 "vs1r vill1 dw 3 writes x10"
.4byte 0x020ab503  # ld a0, 32(s5)
.assert rd_addr == 10 "vs1r vill1 dw 4 writes x10"
.4byte 0x028ab503  # ld a0, 40(s5)
.assert rd_addr == 10 "vs1r vill1 dw 5 writes x10"
.4byte 0x030ab503  # ld a0, 48(s5)
.assert rd_addr == 10 "vs1r vill1 dw 6 writes x10"
.4byte 0x038ab503  # ld a0, 56(s5)
.assert rd_addr == 10 "vs1r vill1 dw 7 writes x10"
.4byte 0x040ab503  # ld a0, 64(s5)
.assert rd_addr == 10 "vs1r vill1 guard untouched writes x10"
.assert rd_wdata == 0x6d6d929255aa33cc "vs1r vill1 guard untouched"
.4byte 0x02040a13  # addi s4, s0, 32
.4byte 0x60048a93  # addi s5, s1, 1536
.4byte 0x228a7407  # vl2re64.v v8, (s4)
.assert trap == 0 "vl2re64.v under vill=1 retires"
.4byte 0x01cab023  # sd t3, 0(s5)
.4byte 0x09cab023  # sd t3, 128(s5)
.4byte 0x228a8427  # vs2r.v v8, (s5)
.assert trap == 0 "vs2r.v vill2 retires"
.4byte 0x000ab503  # ld a0, 0(s5)
.assert rd_addr == 10 "vs2r vill2 dw 0 writes x10"
.assert rd_wdata == 0x57733874c702da35 "vs2r vill2 dw 0"
.4byte 0x008ab503  # ld a0, 8(s5)
.assert rd_addr == 10 "vs2r vill2 dw 1 writes x10"
.assert rd_wdata == 0x687a3d77d20fe146 "vs2r vill2 dw 1"
.4byte 0x010ab503  # ld a0, 16(s5)
.assert rd_addr == 10 "vs2r vill2 dw 2 writes x10"
.assert rd_wdata == 0x7981427add1ce857 "vs2r vill2 dw 2"
.4byte 0x018ab503  # ld a0, 24(s5)
.assert rd_addr == 10 "vs2r vill2 dw 3 writes x10"
.assert rd_wdata == 0x8a88477de829ef68 "vs2r vill2 dw 3"
.4byte 0x020ab503  # ld a0, 32(s5)
.assert rd_addr == 10 "vs2r vill2 dw 4 writes x10"
.4byte 0x028ab503  # ld a0, 40(s5)
.assert rd_addr == 10 "vs2r vill2 dw 5 writes x10"
.4byte 0x030ab503  # ld a0, 48(s5)
.assert rd_addr == 10 "vs2r vill2 dw 6 writes x10"
.4byte 0x038ab503  # ld a0, 56(s5)
.assert rd_addr == 10 "vs2r vill2 dw 7 writes x10"
.4byte 0x040ab503  # ld a0, 64(s5)
.assert rd_addr == 10 "vs2r vill2 dw 8 writes x10"
.4byte 0x048ab503  # ld a0, 72(s5)
.assert rd_addr == 10 "vs2r vill2 dw 9 writes x10"
.4byte 0x050ab503  # ld a0, 80(s5)
.assert rd_addr == 10 "vs2r vill2 dw 10 writes x10"
.4byte 0x058ab503  # ld a0, 88(s5)
.assert rd_addr == 10 "vs2r vill2 dw 11 writes x10"
.4byte 0x060ab503  # ld a0, 96(s5)
.assert rd_addr == 10 "vs2r vill2 dw 12 writes x10"
.4byte 0x068ab503  # ld a0, 104(s5)
.assert rd_addr == 10 "vs2r vill2 dw 13 writes x10"
.4byte 0x070ab503  # ld a0, 112(s5)
.assert rd_addr == 10 "vs2r vill2 dw 14 writes x10"
.4byte 0x078ab503  # ld a0, 120(s5)
.assert rd_addr == 10 "vs2r vill2 dw 15 writes x10"
.4byte 0x080ab503  # ld a0, 128(s5)
.assert rd_addr == 10 "vs2r vill2 guard untouched writes x10"
.assert rd_wdata == 0x6d6d929255aa33cc "vs2r vill2 guard untouched"
.4byte 0x22846487  # reserved whole-reg load nr=2 eew=32 vd=v9 vm=1 mew=0
.assert trap == 1 "misaligned vl2re32.v under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vill=1 misaligned load mcause writes x10"
.assert rd_wdata == 0x2 "vill=1 misaligned load mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vill=1 misaligned load mtval writes x10"
.assert rd_wdata == 0x22846487 "vill=1 misaligned load mtval"
.4byte 0x228484a7  # reserved whole-reg store nr=2 vs3=v9 vm=1 w=0 mew=0
.assert trap == 1 "misaligned vs2r.v under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vill=1 misaligned store mcause writes x10"
.assert rd_wdata == 0x2 "vill=1 misaligned store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vill=1 misaligned store mtval writes x10"
.assert rd_wdata == 0x228484a7 "vill=1 misaligned store mtval"
.4byte 0xc2102573  # csrr a0, vtype
.assert rd_addr == 10 "vtype.vill preserved writes x10"
.assert rd_wdata == 0x8000000000000000 "vtype.vill preserved"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "vl preserved under vill writes x10"
.assert rd_wdata == 0x0 "vl preserved under vill"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl2re64 under vill=1 v8 lane 0 writes x10"
.assert rd_wdata == 0x57733874c702da35 "vl2re64 under vill=1 v8 lane 0"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl2re64 under vill=1 v8 lane 1 writes x10"
.assert rd_wdata == 0x687a3d77d20fe146 "vl2re64 under vill=1 v8 lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl2re64 under vill=1 v9 lane 0 writes x10"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vl2re64 under vill=1 neighbor v10 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl2re64 under vill=1 neighbor v10 undisturbed"

# vl == 0 independence: whole-register loads and stores still transfer full registers.
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "vl=0 configuration writes x12"
.assert rd_wdata == 0x0 "vl=0 configuration"
.4byte 0x03040a13  # addi s4, s0, 48
.4byte 0x70048a93  # addi s5, s1, 1792
.4byte 0x028a5407  # vl1re16.v v8, (s4)
.assert trap == 0 "vl1re16.v under vl=0 retires"
.4byte 0x01cab023  # sd t3, 0(s5)
.4byte 0x05cab023  # sd t3, 64(s5)
.4byte 0x028a8427  # vs1r.v v8, (s5)
.assert trap == 0 "vs1r.v vl0 retires"
.4byte 0x000ab503  # ld a0, 0(s5)
.assert rd_addr == 10 "vs1r vl0 dw 0 writes x10"
.assert rd_wdata == 0x7981427add1ce857 "vs1r vl0 dw 0"
.4byte 0x008ab503  # ld a0, 8(s5)
.assert rd_addr == 10 "vs1r vl0 dw 1 writes x10"
.assert rd_wdata == 0x8a88477de829ef68 "vs1r vl0 dw 1"
.4byte 0x010ab503  # ld a0, 16(s5)
.assert rd_addr == 10 "vs1r vl0 dw 2 writes x10"
.4byte 0x018ab503  # ld a0, 24(s5)
.assert rd_addr == 10 "vs1r vl0 dw 3 writes x10"
.4byte 0x020ab503  # ld a0, 32(s5)
.assert rd_addr == 10 "vs1r vl0 dw 4 writes x10"
.4byte 0x028ab503  # ld a0, 40(s5)
.assert rd_addr == 10 "vs1r vl0 dw 5 writes x10"
.4byte 0x030ab503  # ld a0, 48(s5)
.assert rd_addr == 10 "vs1r vl0 dw 6 writes x10"
.4byte 0x038ab503  # ld a0, 56(s5)
.assert rd_addr == 10 "vs1r vl0 dw 7 writes x10"
.4byte 0x040ab503  # ld a0, 64(s5)
.assert rd_addr == 10 "vs1r vl0 guard untouched writes x10"
.assert rd_wdata == 0x6d6d929255aa33cc "vs1r vl0 guard untouched"
.4byte 0x60000b37  # lui s6, 0x60000
.4byte 0x001b1b13  # slli s6, s6, 1
.4byte 0x028b7407  # vl1re64.v v8, (s6)
.assert trap == 1 "vl1re64.v at 0xC0000000 traps even when vl=0"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vl=0 load access fault mcause writes x10"
.assert rd_wdata == 0x5 "vl=0 load access fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vl=0 load access fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "vl=0 load access fault mtval"
.4byte 0x028b0427  # vs1r.v v8, (s6)
.assert trap == 1 "vs1r.v at 0xC0000000 traps even when vl=0"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vl=0 store access fault mcause writes x10"
.assert rd_wdata == 0x7 "vl=0 store access fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vl=0 store access fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "vl=0 store access fault mtval"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl1re16 under vl=0 preserved after fault writes x10"
.assert rd_wdata == 0x7981427add1ce857 "vl1re16 under vl=0 preserved after fault"

# Mismatched vtype (e8, mf8, ta, ma, vl=1) and v0 == 0 mask independence.
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x5e03c557  # vmv.v.x v10, t2
.4byte 0xcc50f657  # vsetivli a2, 1, e8, mf8, ta, ma
.assert rd_addr == 12 "e8 mf8 ta ma vl=1 writes x12"
.assert rd_wdata == 0x1 "e8 mf8 ta ma vl=1"
.4byte 0x04040a13  # addi s4, s0, 64
.4byte 0x78048a93  # addi s5, s1, 1920
.4byte 0x228a7407  # vl2re64.v v8, (s4)
.assert trap == 0 "vl2re64.v under e8 mf8 v0=0 retires"
.4byte 0x01cab023  # sd t3, 0(s5)
.4byte 0x09cab023  # sd t3, 128(s5)
.4byte 0x228a8427  # vs2r.v v8, (s5)
.assert trap == 0 "vs2r.v vtype_v0 retires"
.4byte 0x000ab503  # ld a0, 0(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 0 writes x10"
.assert rd_wdata == 0x9b8f4c80f336f679 "vs2r vtype_v0 dw 0"
.4byte 0x008ab503  # ld a0, 8(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 1 writes x10"
.assert rd_wdata == 0xac965183fe43fd8a "vs2r vtype_v0 dw 1"
.4byte 0x010ab503  # ld a0, 16(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 2 writes x10"
.assert rd_wdata == 0xbd9d56870951049b "vs2r vtype_v0 dw 2"
.4byte 0x018ab503  # ld a0, 24(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 3 writes x10"
.assert rd_wdata == 0xcea45b8a145e0bac "vs2r vtype_v0 dw 3"
.4byte 0x020ab503  # ld a0, 32(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 4 writes x10"
.4byte 0x028ab503  # ld a0, 40(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 5 writes x10"
.4byte 0x030ab503  # ld a0, 48(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 6 writes x10"
.4byte 0x038ab503  # ld a0, 56(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 7 writes x10"
.4byte 0x040ab503  # ld a0, 64(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 8 writes x10"
.4byte 0x048ab503  # ld a0, 72(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 9 writes x10"
.4byte 0x050ab503  # ld a0, 80(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 10 writes x10"
.4byte 0x058ab503  # ld a0, 88(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 11 writes x10"
.4byte 0x060ab503  # ld a0, 96(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 12 writes x10"
.4byte 0x068ab503  # ld a0, 104(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 13 writes x10"
.4byte 0x070ab503  # ld a0, 112(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 14 writes x10"
.4byte 0x078ab503  # ld a0, 120(s5)
.assert rd_addr == 10 "vs2r vtype_v0 dw 15 writes x10"
.4byte 0x080ab503  # ld a0, 128(s5)
.assert rd_addr == 10 "vs2r vtype_v0 guard untouched writes x10"
.assert rd_wdata == 0x6d6d929255aa33cc "vs2r vtype_v0 guard untouched"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl2re64 under e8 mf8 v0=0 lane 0 writes x10"
.assert rd_wdata == 0x9b8f4c80f336f679 "vl2re64 under e8 mf8 v0=0 lane 0"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vl2re64 under e8 mf8 neighbor undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "vl2re64 under e8 mf8 neighbor undisturbed"

# Odd-address (base + 1) vl1re8.v and vs1r.v under e64, m8 (always byte-aligned).
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x00140a13  # addi s4, s0, 1
.4byte 0x100a8a93  # addi s5, s5, 256
.4byte 0x0a500e93  # addi t4, zero, 165
.4byte 0x01da8023  # sb t4, 0(s5)
.4byte 0x05da80a3  # sb t4, 65(s5)
.4byte 0x001a8a93  # addi s5, s5, 1
.4byte 0x028a0407  # vl1re8.v v8, (s4)
.assert trap == 0 "odd-address vl1re8.v retires"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "odd vl1re8 lane 0 writes x10"
.assert rd_wdata == 0x2135724689acebd "odd vl1re8 lane 0"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "odd vl1re8 lane 1 writes x10"
.assert rd_wdata == 0x13245e296ba5dbc5 "odd vl1re8 lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "odd vl1re8 under e64 m8 leaves v9 undisturbed writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "odd vl1re8 under e64 m8 leaves v9 undisturbed"
.4byte 0x01b072d7  # vsetvli t0, zero, e64, m8, tu, mu
.4byte 0x028a8427  # vs1r.v v8, (s5)
.assert trap == 0 "odd-address vs1r.v under e64 m8 retires"
.4byte 0x000ac503  # lbu a0, 0(s5)
.assert rd_addr == 10 "odd vs1r byte 0 writes x10"
.assert rd_wdata == 0xbd "odd vs1r byte 0"
.4byte 0x001ad503  # lhu a0, 1(s5)
.assert rd_addr == 10 "odd vs1r bytes 1..2 writes x10"
.assert rd_wdata == 0x9ace "odd vs1r bytes 1..2"
.4byte 0x003ae503  # lwu a0, 3(s5)
.assert rd_addr == 10 "odd vs1r bytes 3..6 writes x10"
.assert rd_wdata == 0x13572468 "odd vs1r bytes 3..6"
.4byte 0x007ab503  # ld a0, 7(s5)
.assert rd_addr == 10 "odd vs1r bytes 7..14 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "odd vs1r bytes 7..14"
.4byte 0x00fac503  # lbu a0, 15(s5)
.assert rd_addr == 10 "odd vs1r byte 15 writes x10"
.assert rd_wdata == 0x13 "odd vs1r byte 15"
.4byte 0x010ac503  # lbu a0, 16(s5)
.assert rd_addr == 10 "odd vs1r byte 16 writes x10"
.4byte 0x011ad503  # lhu a0, 17(s5)
.assert rd_addr == 10 "odd vs1r bytes 17..18 writes x10"
.4byte 0x013ae503  # lwu a0, 19(s5)
.assert rd_addr == 10 "odd vs1r bytes 19..22 writes x10"
.4byte 0x017ab503  # ld a0, 23(s5)
.assert rd_addr == 10 "odd vs1r bytes 23..30 writes x10"
.4byte 0x01fab503  # ld a0, 31(s5)
.assert rd_addr == 10 "odd vs1r bytes 31..38 writes x10"
.4byte 0x027ab503  # ld a0, 39(s5)
.assert rd_addr == 10 "odd vs1r bytes 39..46 writes x10"
.4byte 0x02fab503  # ld a0, 47(s5)
.assert rd_addr == 10 "odd vs1r bytes 47..54 writes x10"
.4byte 0x037ab503  # ld a0, 55(s5)
.assert rd_addr == 10 "odd vs1r bytes 55..62 writes x10"
.4byte 0x03fac503  # lbu a0, 63(s5)
.assert rd_addr == 10 "odd vs1r byte 63 writes x10"
.4byte 0xfffac503  # lbu a0, -1(s5)
.assert rd_addr == 10 "odd vs1r low guard byte untouched writes x10"
.assert rd_wdata == 0xa5 "odd vs1r low guard byte untouched"
.4byte 0x040ac503  # lbu a0, 64(s5)
.assert rd_addr == 10 "odd vs1r high guard byte untouched writes x10"
.assert rd_wdata == 0xa5 "odd vs1r high guard byte untouched"

# Cached DDR 4 KiB page-boundary crossing: vl2re64.v and vs2r.v across 0x80011000 / 0x80013000.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x00000913  # addi s2, zero, 0
.4byte 0x80011fb7  # lui t6, 0x80011
.4byte 0xff8f8f93  # addi t6, t6, -8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f96933  # or s2, s2, t6
.4byte 0x00000993  # addi s3, zero, 0
.4byte 0x80013fb7  # lui t6, 0x80013
.4byte 0xff8f8f93  # addi t6, t6, -8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f9e9b3  # or s3, s3, t6
.4byte 0x13572337  # lui t1, 0x13572
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9acecfb7  # lui t6, 0x9acec
.4byte 0xdf1f8f93  # addi t6, t6, -527
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693023  # sd t1, 0(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00693423  # sd t1, 8(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00693823  # sd t1, 16(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00693c23  # sd t1, 24(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02693023  # sd t1, 32(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02693423  # sd t1, 40(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02693823  # sd t1, 48(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02693c23  # sd t1, 56(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x04693023  # sd t1, 64(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x04693423  # sd t1, 72(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x04693823  # sd t1, 80(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x04693c23  # sd t1, 88(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x06693023  # sd t1, 96(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x06693423  # sd t1, 104(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x06693823  # sd t1, 112(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x06693c23  # sd t1, 120(s2)
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x22897407  # vl2re64.v v8, (s2)
.assert trap == 0 "page-crossing vl2re64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "page-crossing vl2re64 Page-0 lane 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "page-crossing vl2re64 Page-0 lane 0"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "page-crossing vl2re64 Page-1 lane 1 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "page-crossing vl2re64 Page-1 lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "page-crossing vl2re64 v9 lane 0 writes x10"
.4byte 0x01c9b023  # sd t3, 0(s3)
.4byte 0x09c9b023  # sd t3, 128(s3)
.4byte 0x22898427  # vs2r.v v8, (s3)
.assert trap == 0 "vs2r.v page_cross retires"
.4byte 0x0009b503  # ld a0, 0(s3)
.assert rd_addr == 10 "vs2r page_cross dw 0 writes x10"
.assert rd_wdata == 0x135724689acebdf1 "vs2r page_cross dw 0"
.4byte 0x0089b503  # ld a0, 8(s3)
.assert rd_addr == 10 "vs2r page_cross dw 1 writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vs2r page_cross dw 1"
.4byte 0x0109b503  # ld a0, 16(s3)
.assert rd_addr == 10 "vs2r page_cross dw 2 writes x10"
.assert rd_wdata == 0x35652e6eb0e8cc13 "vs2r page_cross dw 2"
.4byte 0x0189b503  # ld a0, 24(s3)
.assert rd_addr == 10 "vs2r page_cross dw 3 writes x10"
.assert rd_wdata == 0x466c3371bbf5d324 "vs2r page_cross dw 3"
.4byte 0x0209b503  # ld a0, 32(s3)
.assert rd_addr == 10 "vs2r page_cross dw 4 writes x10"
.4byte 0x0289b503  # ld a0, 40(s3)
.assert rd_addr == 10 "vs2r page_cross dw 5 writes x10"
.4byte 0x0309b503  # ld a0, 48(s3)
.assert rd_addr == 10 "vs2r page_cross dw 6 writes x10"
.4byte 0x0389b503  # ld a0, 56(s3)
.assert rd_addr == 10 "vs2r page_cross dw 7 writes x10"
.4byte 0x0409b503  # ld a0, 64(s3)
.assert rd_addr == 10 "vs2r page_cross dw 8 writes x10"
.4byte 0x0489b503  # ld a0, 72(s3)
.assert rd_addr == 10 "vs2r page_cross dw 9 writes x10"
.4byte 0x0509b503  # ld a0, 80(s3)
.assert rd_addr == 10 "vs2r page_cross dw 10 writes x10"
.4byte 0x0589b503  # ld a0, 88(s3)
.assert rd_addr == 10 "vs2r page_cross dw 11 writes x10"
.4byte 0x0609b503  # ld a0, 96(s3)
.assert rd_addr == 10 "vs2r page_cross dw 12 writes x10"
.4byte 0x0689b503  # ld a0, 104(s3)
.assert rd_addr == 10 "vs2r page_cross dw 13 writes x10"
.4byte 0x0709b503  # ld a0, 112(s3)
.assert rd_addr == 10 "vs2r page_cross dw 14 writes x10"
.4byte 0x0789b503  # ld a0, 120(s3)
.assert rd_addr == 10 "vs2r page_cross dw 15 writes x10"
.4byte 0x0809b503  # ld a0, 128(s3)
.assert rd_addr == 10 "vs2r page_cross guard untouched writes x10"
.assert rd_wdata == 0x6d6d929255aa33cc "vs2r page_cross guard untouched"

# Access faults at 0xC0000000 and Page-1 faults at 0xBFFFFFF8 distinguishing eew=8/16/32/64 vstart.
.4byte 0xff8b0b93  # addi s7, s6, -8
.4byte 0x2468beb7  # lui t4, 0x2468b
.4byte 0xce1e8e93  # addi t4, t4, -799
.4byte 0x020e9e93  # slli t4, t4, 32
.4byte 0x1357afb7  # lui t6, 0x1357a
.4byte 0xbdff8f93  # addi t6, t6, -1057
.4byte 0x01feeeb3  # or t4, t4, t6
.4byte 0x01dbb023  # sd t4, 0(s7)
.4byte 0x028b0427  # vs1r.v v8, (s6)
.assert trap == 1 "vs1r.v at 0xC0000000 raises store access fault"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vs1r.v access fault mcause writes x10"
.assert rd_wdata == 0x7 "vs1r.v access fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vs1r.v access fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "vs1r.v access fault mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vs1r.v Page-0 fault vstart writes x10"
.assert rd_wdata == 0x0 "vs1r.v Page-0 fault vstart"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x028b8407  # vl1re8.v v8, (s7)
.assert trap == 1 "vl1re8.v Page-1 fault at 0xC0000000 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vl1re8 Page-1 fault mcause writes x10"
.assert rd_wdata == 0x5 "vl1re8 Page-1 fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vl1re8 Page-1 fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "vl1re8 Page-1 fault mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vl1re8 Page-1 fault vstart=8 writes x10"
.assert rd_wdata == 0x8 "vl1re8 Page-1 fault vstart=8"
.4byte 0x02840407  # vl1re8.v v8, (s0)
.assert trap == 0 "vl1re8.v resume from vstart=8 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vl1re8 resume clears vstart writes x10"
.assert rd_wdata == 0x0 "vl1re8 resume clears vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl1re8 prestart bytes 0..7 preserved writes x10"
.assert rd_wdata == 0x2468ace113579bdf "vl1re8 prestart bytes 0..7 preserved"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl1re8 resumed bytes 8..15 loaded writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vl1re8 resumed bytes 8..15 loaded"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x028bd407  # vl1re16.v v8, (s7)
.assert trap == 1 "vl1re16.v Page-1 fault at 0xC0000000 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vl1re16 Page-1 fault mcause writes x10"
.assert rd_wdata == 0x5 "vl1re16 Page-1 fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vl1re16 Page-1 fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "vl1re16 Page-1 fault mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vl1re16 Page-1 fault vstart=4 writes x10"
.assert rd_wdata == 0x4 "vl1re16 Page-1 fault vstart=4"
.4byte 0x02845407  # vl1re16.v v8, (s0)
.assert trap == 0 "vl1re16.v resume from vstart=4 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vl1re16 resume clears vstart writes x10"
.assert rd_wdata == 0x0 "vl1re16 resume clears vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl1re16 prestart bytes 0..7 preserved writes x10"
.assert rd_wdata == 0x2468ace113579bdf "vl1re16 prestart bytes 0..7 preserved"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl1re16 resumed bytes 8..15 loaded writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vl1re16 resumed bytes 8..15 loaded"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x028be407  # vl1re32.v v8, (s7)
.assert trap == 1 "vl1re32.v Page-1 fault at 0xC0000000 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vl1re32 Page-1 fault mcause writes x10"
.assert rd_wdata == 0x5 "vl1re32 Page-1 fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vl1re32 Page-1 fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "vl1re32 Page-1 fault mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vl1re32 Page-1 fault vstart=2 writes x10"
.assert rd_wdata == 0x2 "vl1re32 Page-1 fault vstart=2"
.4byte 0x02846407  # vl1re32.v v8, (s0)
.assert trap == 0 "vl1re32.v resume from vstart=2 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vl1re32 resume clears vstart writes x10"
.assert rd_wdata == 0x0 "vl1re32 resume clears vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl1re32 prestart bytes 0..7 preserved writes x10"
.assert rd_wdata == 0x2468ace113579bdf "vl1re32 prestart bytes 0..7 preserved"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl1re32 resumed bytes 8..15 loaded writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vl1re32 resumed bytes 8..15 loaded"
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x028bf407  # vl1re64.v v8, (s7)
.assert trap == 1 "vl1re64.v Page-1 fault at 0xC0000000 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vl1re64 Page-1 fault mcause writes x10"
.assert rd_wdata == 0x5 "vl1re64 Page-1 fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vl1re64 Page-1 fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "vl1re64 Page-1 fault mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vl1re64 Page-1 fault vstart=1 writes x10"
.assert rd_wdata == 0x1 "vl1re64 Page-1 fault vstart=1"
.4byte 0x02847407  # vl1re64.v v8, (s0)
.assert trap == 0 "vl1re64.v resume from vstart=1 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vl1re64 resume clears vstart writes x10"
.assert rd_wdata == 0x0 "vl1re64 resume clears vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl1re64 prestart bytes 0..7 preserved writes x10"
.assert rd_wdata == 0x2468ace113579bdf "vl1re64 prestart bytes 0..7 preserved"
.4byte 0x3e80bed7  # vslidedown.vi v29, v8, 1
.4byte 0x43d02557  # vmv.x.s a0, v29
.assert rd_addr == 10 "vl1re64 resumed bytes 8..15 loaded writes x10"
.assert rd_wdata == 0x245e296ba5dbc502 "vl1re64 resumed bytes 8..15 loaded"

# Illegal-instruction traps: misaligned register groups, reserved nf, vm=0, store width, mew=1.
.4byte 0x5e03c4d7  # vmv.v.x v9, t2
.4byte 0x5e03c957  # vmv.v.x v18, t2
.4byte 0x5e03ca57  # vmv.v.x v20, t2
.4byte 0x22840487  # reserved whole-reg load nr=2 eew=8 vd=v9 vm=1 mew=0
.assert trap == 1 "misaligned vl2re8.v v9 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "misaligned vl2re8.v v9 mcause writes x10"
.assert rd_wdata == 0x2 "misaligned vl2re8.v v9 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "misaligned vl2re8.v v9 mtval writes x10"
.assert rd_wdata == 0x22840487 "misaligned vl2re8.v v9 mtval"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "misaligned vl2re8.v v9 leaves v9 intact writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "misaligned vl2re8.v v9 leaves v9 intact"
.4byte 0x62846907  # reserved whole-reg load nr=4 eew=32 vd=v18 vm=1 mew=0
.assert trap == 1 "misaligned vl4re32.v v18 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "misaligned vl4re32.v v18 mcause writes x10"
.assert rd_wdata == 0x2 "misaligned vl4re32.v v18 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "misaligned vl4re32.v v18 mtval writes x10"
.assert rd_wdata == 0x62846907 "misaligned vl4re32.v v18 mtval"
.4byte 0x43202557  # vmv.x.s a0, v18
.assert rd_addr == 10 "misaligned vl4re32.v v18 leaves v18 intact writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "misaligned vl4re32.v v18 leaves v18 intact"
.4byte 0xe2847a07  # reserved whole-reg load nr=8 eew=64 vd=v20 vm=1 mew=0
.assert trap == 1 "misaligned vl8re64.v v20 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "misaligned vl8re64.v v20 mcause writes x10"
.assert rd_wdata == 0x2 "misaligned vl8re64.v v20 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "misaligned vl8re64.v v20 mtval writes x10"
.assert rd_wdata == 0xe2847a07 "misaligned vl8re64.v v20 mtval"
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "misaligned vl8re64.v v20 leaves v20 intact writes x10"
.assert rd_wdata == 0x5a5ac3c3a5a53c3c "misaligned vl8re64.v v20 leaves v20 intact"
.4byte 0x228484a7  # reserved whole-reg store nr=2 vs3=v9 vm=1 w=0 mew=0
.assert trap == 1 "misaligned vs2r.v v9 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "misaligned vs2r.v v9 mcause writes x10"
.assert rd_wdata == 0x2 "misaligned vs2r.v v9 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "misaligned vs2r.v v9 mtval writes x10"
.assert rd_wdata == 0x228484a7 "misaligned vs2r.v v9 mtval"
.4byte 0x62848927  # reserved whole-reg store nr=4 vs3=v18 vm=1 w=0 mew=0
.assert trap == 1 "misaligned vs4r.v v18 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "misaligned vs4r.v v18 mcause writes x10"
.assert rd_wdata == 0x2 "misaligned vs4r.v v18 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "misaligned vs4r.v v18 mtval writes x10"
.assert rd_wdata == 0x62848927 "misaligned vs4r.v v18 mtval"
.4byte 0xe2848a27  # reserved whole-reg store nr=8 vs3=v20 vm=1 w=0 mew=0
.assert trap == 1 "misaligned vs8r.v v20 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "misaligned vs8r.v v20 mcause writes x10"
.assert rd_wdata == 0x2 "misaligned vs8r.v v20 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "misaligned vs8r.v v20 mtval writes x10"
.assert rd_wdata == 0xe2848a27 "misaligned vs8r.v v20 mtval"
.4byte 0x42840407  # reserved whole-reg load nr=3 eew=8 vd=v8 vm=1 mew=0
.assert trap == 1 "reserved nf=2 whole-reg load traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved nf=2 whole-reg load mcause writes x10"
.assert rd_wdata == 0x2 "reserved nf=2 whole-reg load mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved nf=2 whole-reg load mtval writes x10"
.assert rd_wdata == 0x42840407 "reserved nf=2 whole-reg load mtval"
.4byte 0x82845407  # reserved whole-reg load nr=5 eew=16 vd=v8 vm=1 mew=0
.assert trap == 1 "reserved nf=4 whole-reg load traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved nf=4 whole-reg load mcause writes x10"
.assert rd_wdata == 0x2 "reserved nf=4 whole-reg load mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved nf=4 whole-reg load mtval writes x10"
.assert rd_wdata == 0x82845407 "reserved nf=4 whole-reg load mtval"
.4byte 0xa2846407  # reserved whole-reg load nr=6 eew=32 vd=v8 vm=1 mew=0
.assert trap == 1 "reserved nf=5 whole-reg load traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved nf=5 whole-reg load mcause writes x10"
.assert rd_wdata == 0x2 "reserved nf=5 whole-reg load mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved nf=5 whole-reg load mtval writes x10"
.assert rd_wdata == 0xa2846407 "reserved nf=5 whole-reg load mtval"
.4byte 0xc2847407  # reserved whole-reg load nr=7 eew=64 vd=v8 vm=1 mew=0
.assert trap == 1 "reserved nf=6 whole-reg load traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved nf=6 whole-reg load mcause writes x10"
.assert rd_wdata == 0x2 "reserved nf=6 whole-reg load mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved nf=6 whole-reg load mtval writes x10"
.assert rd_wdata == 0xc2847407 "reserved nf=6 whole-reg load mtval"
.4byte 0x42848427  # reserved whole-reg store nr=3 vs3=v8 vm=1 w=0 mew=0
.assert trap == 1 "reserved nf=2 whole-reg store traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved nf=2 whole-reg store mcause writes x10"
.assert rd_wdata == 0x2 "reserved nf=2 whole-reg store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved nf=2 whole-reg store mtval writes x10"
.assert rd_wdata == 0x42848427 "reserved nf=2 whole-reg store mtval"
.4byte 0x82848427  # reserved whole-reg store nr=5 vs3=v8 vm=1 w=0 mew=0
.assert trap == 1 "reserved nf=4 whole-reg store traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved nf=4 whole-reg store mcause writes x10"
.assert rd_wdata == 0x2 "reserved nf=4 whole-reg store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved nf=4 whole-reg store mtval writes x10"
.assert rd_wdata == 0x82848427 "reserved nf=4 whole-reg store mtval"
.4byte 0xa2848427  # reserved whole-reg store nr=6 vs3=v8 vm=1 w=0 mew=0
.assert trap == 1 "reserved nf=5 whole-reg store traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved nf=5 whole-reg store mcause writes x10"
.assert rd_wdata == 0x2 "reserved nf=5 whole-reg store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved nf=5 whole-reg store mtval writes x10"
.assert rd_wdata == 0xa2848427 "reserved nf=5 whole-reg store mtval"
.4byte 0xc2848427  # reserved whole-reg store nr=7 vs3=v8 vm=1 w=0 mew=0
.assert trap == 1 "reserved nf=6 whole-reg store traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved nf=6 whole-reg store mcause writes x10"
.assert rd_wdata == 0x2 "reserved nf=6 whole-reg store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved nf=6 whole-reg store mtval writes x10"
.assert rd_wdata == 0xc2848427 "reserved nf=6 whole-reg store mtval"
.4byte 0x00840407  # reserved whole-reg load nr=1 eew=8 vd=v8 vm=0 mew=0
.assert trap == 1 "reserved masked vm=0 whole-reg load traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved masked vm=0 whole-reg load mcause writes x10"
.assert rd_wdata == 0x2 "reserved masked vm=0 whole-reg load mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved masked vm=0 whole-reg load mtval writes x10"
.assert rd_wdata == 0x840407 "reserved masked vm=0 whole-reg load mtval"
.4byte 0x00848427  # reserved whole-reg store nr=1 vs3=v8 vm=0 w=0 mew=0
.assert trap == 1 "reserved masked vm=0 whole-reg store traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved masked vm=0 whole-reg store mcause writes x10"
.assert rd_wdata == 0x2 "reserved masked vm=0 whole-reg store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved masked vm=0 whole-reg store mtval writes x10"
.assert rd_wdata == 0x848427 "reserved masked vm=0 whole-reg store mtval"
.4byte 0x0284d427  # reserved whole-reg store nr=1 vs3=v8 vm=1 w=5 mew=0
.assert trap == 1 "reserved width=e16 whole-reg store traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved width=e16 whole-reg store mcause writes x10"
.assert rd_wdata == 0x2 "reserved width=e16 whole-reg store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved width=e16 whole-reg store mtval writes x10"
.assert rd_wdata == 0x284d427 "reserved width=e16 whole-reg store mtval"
.4byte 0x0284e427  # reserved whole-reg store nr=1 vs3=v8 vm=1 w=6 mew=0
.assert trap == 1 "reserved width=e32 whole-reg store traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved width=e32 whole-reg store mcause writes x10"
.assert rd_wdata == 0x2 "reserved width=e32 whole-reg store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved width=e32 whole-reg store mtval writes x10"
.assert rd_wdata == 0x284e427 "reserved width=e32 whole-reg store mtval"
.4byte 0x0284f427  # reserved whole-reg store nr=1 vs3=v8 vm=1 w=7 mew=0
.assert trap == 1 "reserved width=e64 whole-reg store traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved width=e64 whole-reg store mcause writes x10"
.assert rd_wdata == 0x2 "reserved width=e64 whole-reg store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved width=e64 whole-reg store mtval writes x10"
.assert rd_wdata == 0x284f427 "reserved width=e64 whole-reg store mtval"
.4byte 0x12840407  # reserved whole-reg load nr=1 eew=8 vd=v8 vm=1 mew=1
.assert trap == 1 "reserved mew=1 whole-reg load traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved mew=1 whole-reg load mcause writes x10"
.assert rd_wdata == 0x2 "reserved mew=1 whole-reg load mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved mew=1 whole-reg load mtval writes x10"
.assert rd_wdata == 0x12840407 "reserved mew=1 whole-reg load mtval"
.4byte 0x12848427  # reserved whole-reg store nr=1 vs3=v8 vm=1 w=0 mew=1
.assert trap == 1 "reserved mew=1 whole-reg store traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "reserved mew=1 whole-reg store mcause writes x10"
.assert rd_wdata == 0x2 "reserved mew=1 whole-reg store mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "reserved mew=1 whole-reg store mtval writes x10"
.assert rd_wdata == 0x12848427 "reserved mew=1 whole-reg store mtval"
