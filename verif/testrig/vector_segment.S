# Segment unit-stride and strided vector loads and stores in cached DDR.
.noshrink
# Enable VS and select cached DDR source and destination buffers.
.4byte 0x60000293  # addi t0, zero, 1536
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x40008437  # lui s0, 0x40008
.4byte 0x00141413  # slli s0, s0, 1
.4byte 0x20040493  # addi s1, s0, 512
.4byte 0xc2202e73  # csrr t3, vlenb
.4byte 0x13070f37  # lui t5, 0x13070
.4byte 0x503f0f13  # addi t5, t5, 1283
.4byte 0x020f1f13  # slli t5, t5, 32
.4byte 0x0b0d0fb7  # lui t6, 0xb0d0
.4byte 0x711f8f93  # addi t6, t6, 1809
.4byte 0x01ff6f33  # or t5, t5, t6
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x5e003557  # vmv.v.i v10, 0
.4byte 0x5e0035d7  # vmv.v.i v11, 0
.4byte 0x5e003657  # vmv.v.i v12, 0
.4byte 0x5e0036d7  # vmv.v.i v13, 0
.4byte 0x5e003757  # vmv.v.i v14, 0
.4byte 0x5e0037d7  # vmv.v.i v15, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0x5e003ad7  # vmv.v.i v21, 0
.4byte 0x5e003f57  # vmv.v.i v30, 0
.4byte 0x5e003fd7  # vmv.v.i v31, 0

# Unit-stride segment vlseg2e32 control under tu, mu.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a6d1337  # lui t1, 0x5a6d1
.4byte 0x02130313  # addi t1, t1, 33
.4byte 0x5e034f57  # vmv.v.x v30, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e034fd7  # vmv.v.x v31, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x19476337  # lui t1, 0x19476
.4byte 0xb8130313  # addi t1, t1, -1151
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642823  # sw t1, 16(s0)
.4byte 0x22046f07  # vlseg2e32.v v30, (s0)
.assert trap == 0 "vlseg2e32.v retires"
.4byte 0x43e02557  # vmv.x.s a0, v30
.assert rd_addr == 10 "vlseg2e32 control f0 lane 0 writes x10"
.assert rd_wdata == 0x19475b81 "vlseg2e32 control f0 lane 0"
.4byte 0x3fe0ba57  # vslidedown.vi v20, v30, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e32 control f0 lane 1 writes x10"
.assert rd_wdata == 0x19476aeb "vlseg2e32 control f0 lane 1"
.4byte 0x3fe13a57  # vslidedown.vi v20, v30, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e32 control f0 tail lane 2 writes x10"
.assert rd_wdata == 0x5a6d1021 "vlseg2e32 control f0 tail lane 2"
.4byte 0x43f02557  # vmv.x.s a0, v31
.assert rd_addr == 10 "vlseg2e32 control f1 lane 0 writes x10"
.assert rd_wdata == 0x19476336 "vlseg2e32 control f1 lane 0"
.4byte 0x3ff0ba57  # vslidedown.vi v20, v31, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e32 control f1 lane 1 writes x10"
.assert rd_wdata == 0x194772a0 "vlseg2e32 control f1 lane 1"
.4byte 0x3ff13a57  # vslidedown.vi v20, v31, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e32 control f1 tail lane 2 writes x10"
.assert rd_wdata == 0x5a6d1046 "vlseg2e32 control f1 tail lane 2"
.4byte 0x61210337  # lui t1, 0x61210
.4byte 0x01930313  # addi t1, t1, 25
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a823  # sw t1, 16(s1)
.4byte 0x2204ef27  # vsseg2e32.v v30, (s1)
.assert trap == 0 "vsseg2e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vlseg2e32 control store off 0 writes x10"
.assert rd_wdata == 0x19475b81 "vlseg2e32 control store off 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vlseg2e32 control store off 4 writes x10"
.assert rd_wdata == 0x19476336 "vlseg2e32 control store off 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "vlseg2e32 control store off 8 writes x10"
.assert rd_wdata == 0x19476aeb "vlseg2e32 control store off 8"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "vlseg2e32 control store off 12 writes x10"
.assert rd_wdata == 0x194772a0 "vlseg2e32 control store off 12"
.4byte 0x0104e503  # lwu a0, 16(s1)
.assert rd_addr == 10 "vlseg2e32 control store guard off 16 writes x10"
.assert rd_wdata == 0x61210075 "vlseg2e32 control store guard off 16"

# Unit-stride segment vlseg2e64 m2 vl=3 unmasked under tu, mu.
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5a7c6337  # lui t1, 0x5a7c6
.4byte 0xa4430313  # addi t1, t1, -1468
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa60b0fb7  # lui t6, 0xa60b0
.4byte 0x088f8f93  # addi t6, t6, 136
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.assert rd_addr == 12 "e64 m2 active vector length writes x12"
.assert rd_wdata == 0x3 "e64 m2 active vector length"
.4byte 0x1b284337  # lui t1, 0x1b284
.4byte 0x15630313  # addi t1, t1, 342
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x6b808fb7  # lui t6, 0x6b808
.4byte 0x9aaf8f93  # addi t6, t6, -1622
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643423  # sd t1, 8(s0)
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
.4byte 0x22047407  # vlseg2e64.v v8, (s0)
.assert trap == 0 "vlseg2e64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x1b2841566b8079aa "vlseg2e64 m2 vl=3 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x41364b5c819a87cc "vlseg2e64 m2 vl=3 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked f0 lane 2 writes x10"
.assert rd_wdata == 0x6744556297b495ee "vlseg2e64 m2 vl=3 unmasked f0 lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked f0 tail lane 3 writes x10"
.assert rd_wdata == 0x5a7c5a44a60b0088 "vlseg2e64 m2 vl=3 unmasked f0 tail lane 3"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x2e2f4659768d80bb "vlseg2e64 m2 vl=3 unmasked f1 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0x543d505f8ca78edd "vlseg2e64 m2 vl=3 unmasked f1 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked f1 lane 2 writes x10"
.assert rd_wdata == 0x7a4b5a65a2c19cff "vlseg2e64 m2 vl=3 unmasked f1 lane 2"
.4byte 0x3ea1ba57  # vslidedown.vi v20, v10, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked f1 tail lane 3 writes x10"
.assert rd_wdata == 0x6d835f47b1180799 "vlseg2e64 m2 vl=3 unmasked f1 tail lane 3"
.4byte 0x611f1337  # lui t1, 0x611f1
.4byte 0x11630313  # addi t1, t1, 278
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x112b0fb7  # lui t6, 0x112b0
.4byte 0x022f8f93  # addi t6, t6, 34
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b423  # sd t1, 40(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x2204f427  # vsseg2e64.v v8, (s1)
.assert trap == 0 "vsseg2e64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked store off 0 writes x10"
.assert rd_wdata == 0x1b2841566b8079aa "vlseg2e64 m2 vl=3 unmasked store off 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked store off 8 writes x10"
.assert rd_wdata == 0x2e2f4659768d80bb "vlseg2e64 m2 vl=3 unmasked store off 8"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked store off 16 writes x10"
.assert rd_wdata == 0x41364b5c819a87cc "vlseg2e64 m2 vl=3 unmasked store off 16"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked store off 24 writes x10"
.assert rd_wdata == 0x543d505f8ca78edd "vlseg2e64 m2 vl=3 unmasked store off 24"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked store off 32 writes x10"
.assert rd_wdata == 0x6744556297b495ee "vlseg2e64 m2 vl=3 unmasked store off 32"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked store off 40 writes x10"
.assert rd_wdata == 0x7a4b5a65a2c19cff "vlseg2e64 m2 vl=3 unmasked store off 40"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "vlseg2e64 m2 vl=3 unmasked store guard off 48 writes x10"
.assert rd_wdata == 0xd3492f2853792a88 "vlseg2e64 m2 vl=3 unmasked store guard off 48"

# Unit-stride segment vlseg3e16 m1 vl=2 unmasked under tu, mu.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x84330313  # addi t1, t1, -1981
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01d30313  # addi t1, t1, 29
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x01d30313  # addi t1, t1, 29
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e16 m1 active vector length"
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x16d30313  # addi t1, t1, 365
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641423  # sh t1, 8(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641523  # sh t1, 10(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641623  # sh t1, 12(s0)
.4byte 0x42045407  # vlseg3e16.v v8, (s0)
.assert trap == 0 "vlseg3e16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x216d "vlseg3e16 m1 vl=2 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x35b6 "vlseg3e16 m1 vl=2 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked f0 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffa843 "vlseg3e16 m1 vl=2 unmasked f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x2830 "vlseg3e16 m1 vl=2 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0x3c79 "vlseg3e16 m1 vl=2 unmasked f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked f1 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffa860 "vlseg3e16 m1 vl=2 unmasked f1 tail lane 2"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked f2 lane 0 writes x10"
.assert rd_wdata == 0x2ef3 "vlseg3e16 m1 vl=2 unmasked f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked f2 lane 1 writes x10"
.assert rd_wdata == 0x433c "vlseg3e16 m1 vl=2 unmasked f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked f2 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffa87d "vlseg3e16 m1 vl=2 unmasked f2 tail lane 2"
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x42530313  # addi t1, t1, 1061
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649423  # sh t1, 8(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649523  # sh t1, 10(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649623  # sh t1, 12(s1)
.4byte 0x4204d427  # vsseg3e16.v v8, (s1)
.assert trap == 0 "vsseg3e16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked store off 0 writes x10"
.assert rd_wdata == 0x216d "vlseg3e16 m1 vl=2 unmasked store off 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked store off 2 writes x10"
.assert rd_wdata == 0x2830 "vlseg3e16 m1 vl=2 unmasked store off 2"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked store off 4 writes x10"
.assert rd_wdata == 0x2ef3 "vlseg3e16 m1 vl=2 unmasked store off 4"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked store off 6 writes x10"
.assert rd_wdata == 0x35b6 "vlseg3e16 m1 vl=2 unmasked store off 6"
.4byte 0x0084d503  # lhu a0, 8(s1)
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked store off 8 writes x10"
.assert rd_wdata == 0x3c79 "vlseg3e16 m1 vl=2 unmasked store off 8"
.4byte 0x00a4d503  # lhu a0, 10(s1)
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked store off 10 writes x10"
.assert rd_wdata == 0x433c "vlseg3e16 m1 vl=2 unmasked store off 10"
.4byte 0x00c4d503  # lhu a0, 12(s1)
.assert rd_addr == 10 "vlseg3e16 m1 vl=2 unmasked store guard off 12 writes x10"
.assert rd_wdata == 0x6497 "vlseg3e16 m1 vl=2 unmasked store guard off 12"

# Unit-stride segment vlseg4e8 m1 vl=2 unmasked under tu, mu.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0ad00313  # addi t1, zero, 173
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e8 m1 active vector length"
.4byte 0x02d00313  # addi t1, zero, 45
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640223  # sb t1, 4(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006402a3  # sb t1, 5(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640323  # sb t1, 6(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006403a3  # sb t1, 7(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640423  # sb t1, 8(s0)
.4byte 0x62040407  # vlseg4e8.v v8, (s0)
.assert trap == 0 "vlseg4e8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x2d "vlseg4e8 m1 vl=2 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x1 "vlseg4e8 m1 vl=2 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f0 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffad "vlseg4e8 m1 vl=2 unmasked f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x62 "vlseg4e8 m1 vl=2 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0x36 "vlseg4e8 m1 vl=2 unmasked f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f1 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffb4 "vlseg4e8 m1 vl=2 unmasked f1 tail lane 2"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f2 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff97 "vlseg4e8 m1 vl=2 unmasked f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f2 lane 1 writes x10"
.assert rd_wdata == 0x6b "vlseg4e8 m1 vl=2 unmasked f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f2 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffbb "vlseg4e8 m1 vl=2 unmasked f2 tail lane 2"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f3 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffcc "vlseg4e8 m1 vl=2 unmasked f3 lane 0"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f3 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffa0 "vlseg4e8 m1 vl=2 unmasked f3 lane 1"
.4byte 0x3eb13a57  # vslidedown.vi v20, v11, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked f3 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffc2 "vlseg4e8 m1 vl=2 unmasked f3 tail lane 2"
.4byte 0x07500313  # addi t1, zero, 117
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648123  # sb t1, 2(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648223  # sb t1, 4(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006482a3  # sb t1, 5(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648323  # sb t1, 6(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006483a3  # sb t1, 7(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648423  # sb t1, 8(s1)
.4byte 0x62048427  # vsseg4e8.v v8, (s1)
.assert trap == 0 "vsseg4e8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked store off 0 writes x10"
.assert rd_wdata == 0x2d "vlseg4e8 m1 vl=2 unmasked store off 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked store off 1 writes x10"
.assert rd_wdata == 0x62 "vlseg4e8 m1 vl=2 unmasked store off 1"
.4byte 0x0024c503  # lbu a0, 2(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked store off 2 writes x10"
.assert rd_wdata == 0x97 "vlseg4e8 m1 vl=2 unmasked store off 2"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked store off 3 writes x10"
.assert rd_wdata == 0xcc "vlseg4e8 m1 vl=2 unmasked store off 3"
.4byte 0x0044c503  # lbu a0, 4(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked store off 4 writes x10"
.assert rd_wdata == 0x1 "vlseg4e8 m1 vl=2 unmasked store off 4"
.4byte 0x0054c503  # lbu a0, 5(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked store off 5 writes x10"
.assert rd_wdata == 0x36 "vlseg4e8 m1 vl=2 unmasked store off 5"
.4byte 0x0064c503  # lbu a0, 6(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked store off 6 writes x10"
.assert rd_wdata == 0x6b "vlseg4e8 m1 vl=2 unmasked store off 6"
.4byte 0x0074c503  # lbu a0, 7(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked store off 7 writes x10"
.assert rd_wdata == 0xa0 "vlseg4e8 m1 vl=2 unmasked store off 7"
.4byte 0x0084c503  # lbu a0, 8(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=2 unmasked store guard off 8 writes x10"
.assert rd_wdata == 0x9d "vlseg4e8 m1 vl=2 unmasked store guard off 8"

# Unit-stride segment vlseg5e16 m1 vl=2 unmasked under tu, mu.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0xa6530313  # addi t1, t1, -1435
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01d30313  # addi t1, t1, 29
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x01d30313  # addi t1, t1, 29
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x01d30313  # addi t1, t1, 29
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0x01d30313  # addi t1, t1, 29
.4byte 0x5e034657  # vmv.v.x v12, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e16 m1 active vector length"
.4byte 0x00003337  # lui t1, 0x3
.4byte 0xb9330313  # addi t1, t1, -1133
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641423  # sh t1, 8(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641523  # sh t1, 10(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641623  # sh t1, 12(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641723  # sh t1, 14(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641823  # sh t1, 16(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641923  # sh t1, 18(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641a23  # sh t1, 20(s0)
.4byte 0x82045407  # vlseg5e16.v v8, (s0)
.assert trap == 0 "vlseg5e16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x2b93 "vlseg5e16 m1 vl=2 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x4d62 "vlseg5e16 m1 vl=2 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f0 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffaa65 "vlseg5e16 m1 vl=2 unmasked f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x3256 "vlseg5e16 m1 vl=2 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0x5425 "vlseg5e16 m1 vl=2 unmasked f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f1 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffaa82 "vlseg5e16 m1 vl=2 unmasked f1 tail lane 2"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f2 lane 0 writes x10"
.assert rd_wdata == 0x3919 "vlseg5e16 m1 vl=2 unmasked f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f2 lane 1 writes x10"
.assert rd_wdata == 0x5ae8 "vlseg5e16 m1 vl=2 unmasked f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f2 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffaa9f "vlseg5e16 m1 vl=2 unmasked f2 tail lane 2"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f3 lane 0 writes x10"
.assert rd_wdata == 0x3fdc "vlseg5e16 m1 vl=2 unmasked f3 lane 0"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f3 lane 1 writes x10"
.assert rd_wdata == 0x61ab "vlseg5e16 m1 vl=2 unmasked f3 lane 1"
.4byte 0x3eb13a57  # vslidedown.vi v20, v11, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f3 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffaabc "vlseg5e16 m1 vl=2 unmasked f3 tail lane 2"
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f4 lane 0 writes x10"
.assert rd_wdata == 0x469f "vlseg5e16 m1 vl=2 unmasked f4 lane 0"
.4byte 0x3ec0ba57  # vslidedown.vi v20, v12, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f4 lane 1 writes x10"
.assert rd_wdata == 0x686e "vlseg5e16 m1 vl=2 unmasked f4 lane 1"
.4byte 0x3ec13a57  # vslidedown.vi v20, v12, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked f4 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffaad9 "vlseg5e16 m1 vl=2 unmasked f4 tail lane 2"
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x63330313  # addi t1, t1, 1587
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649423  # sh t1, 8(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649523  # sh t1, 10(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649623  # sh t1, 12(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649723  # sh t1, 14(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649823  # sh t1, 16(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649923  # sh t1, 18(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649a23  # sh t1, 20(s1)
.4byte 0x8204d427  # vsseg5e16.v v8, (s1)
.assert trap == 0 "vsseg5e16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 0 writes x10"
.assert rd_wdata == 0x2b93 "vlseg5e16 m1 vl=2 unmasked store off 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 2 writes x10"
.assert rd_wdata == 0x3256 "vlseg5e16 m1 vl=2 unmasked store off 2"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 4 writes x10"
.assert rd_wdata == 0x3919 "vlseg5e16 m1 vl=2 unmasked store off 4"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 6 writes x10"
.assert rd_wdata == 0x3fdc "vlseg5e16 m1 vl=2 unmasked store off 6"
.4byte 0x0084d503  # lhu a0, 8(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 8 writes x10"
.assert rd_wdata == 0x469f "vlseg5e16 m1 vl=2 unmasked store off 8"
.4byte 0x00a4d503  # lhu a0, 10(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 10 writes x10"
.assert rd_wdata == 0x4d62 "vlseg5e16 m1 vl=2 unmasked store off 10"
.4byte 0x00c4d503  # lhu a0, 12(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 12 writes x10"
.assert rd_wdata == 0x5425 "vlseg5e16 m1 vl=2 unmasked store off 12"
.4byte 0x00e4d503  # lhu a0, 14(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 14 writes x10"
.assert rd_wdata == 0x5ae8 "vlseg5e16 m1 vl=2 unmasked store off 14"
.4byte 0x0104d503  # lhu a0, 16(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 16 writes x10"
.assert rd_wdata == 0x61ab "vlseg5e16 m1 vl=2 unmasked store off 16"
.4byte 0x0124d503  # lhu a0, 18(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store off 18 writes x10"
.assert rd_wdata == 0x686e "vlseg5e16 m1 vl=2 unmasked store off 18"
.4byte 0x0144d503  # lhu a0, 20(s1)
.assert rd_addr == 10 "vlseg5e16 m1 vl=2 unmasked store guard off 20 writes x10"
.assert rd_wdata == 0x66f1 "vlseg5e16 m1 vl=2 unmasked store guard off 20"

# Unit-stride segment vlseg6e32 m1 vl=2 unmasked under tu, mu.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5acc1337  # lui t1, 0x5acc1
.4byte 0x0c630313  # addi t1, t1, 198
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e034657  # vmv.v.x v12, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0346d7  # vmv.v.x v13, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x3ca67337  # lui t1, 0x3ca67
.4byte 0x4ae30313  # addi t1, t1, 1198
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642823  # sw t1, 16(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642a23  # sw t1, 20(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642c23  # sw t1, 24(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642e23  # sw t1, 28(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642023  # sw t1, 32(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642223  # sw t1, 36(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642423  # sw t1, 40(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642623  # sw t1, 44(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642823  # sw t1, 48(s0)
.4byte 0xa2046407  # vlseg6e32.v v8, (s0)
.assert trap == 0 "vlseg6e32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x3ca674ae "vlseg6e32 m1 vl=2 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x3ca6a2ec "vlseg6e32 m1 vl=2 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f0 tail lane 2 writes x10"
.assert rd_wdata == 0x5acc10c6 "vlseg6e32 m1 vl=2 unmasked f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x3ca67c63 "vlseg6e32 m1 vl=2 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0x3ca6aaa1 "vlseg6e32 m1 vl=2 unmasked f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f1 tail lane 2 writes x10"
.assert rd_wdata == 0x5acc10eb "vlseg6e32 m1 vl=2 unmasked f1 tail lane 2"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f2 lane 0 writes x10"
.assert rd_wdata == 0x3ca68418 "vlseg6e32 m1 vl=2 unmasked f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f2 lane 1 writes x10"
.assert rd_wdata == 0x3ca6b256 "vlseg6e32 m1 vl=2 unmasked f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f2 tail lane 2 writes x10"
.assert rd_wdata == 0x5acc1110 "vlseg6e32 m1 vl=2 unmasked f2 tail lane 2"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f3 lane 0 writes x10"
.assert rd_wdata == 0x3ca68bcd "vlseg6e32 m1 vl=2 unmasked f3 lane 0"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f3 lane 1 writes x10"
.assert rd_wdata == 0x3ca6ba0b "vlseg6e32 m1 vl=2 unmasked f3 lane 1"
.4byte 0x3eb13a57  # vslidedown.vi v20, v11, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f3 tail lane 2 writes x10"
.assert rd_wdata == 0x5acc1135 "vlseg6e32 m1 vl=2 unmasked f3 tail lane 2"
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f4 lane 0 writes x10"
.assert rd_wdata == 0x3ca69382 "vlseg6e32 m1 vl=2 unmasked f4 lane 0"
.4byte 0x3ec0ba57  # vslidedown.vi v20, v12, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f4 lane 1 writes x10"
.assert rd_wdata == 0x3ca6c1c0 "vlseg6e32 m1 vl=2 unmasked f4 lane 1"
.4byte 0x3ec13a57  # vslidedown.vi v20, v12, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f4 tail lane 2 writes x10"
.assert rd_wdata == 0x5acc115a "vlseg6e32 m1 vl=2 unmasked f4 tail lane 2"
.4byte 0x42d02557  # vmv.x.s a0, v13
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f5 lane 0 writes x10"
.assert rd_wdata == 0x3ca69b37 "vlseg6e32 m1 vl=2 unmasked f5 lane 0"
.4byte 0x3ed0ba57  # vslidedown.vi v20, v13, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f5 lane 1 writes x10"
.assert rd_wdata == 0x3ca6c975 "vlseg6e32 m1 vl=2 unmasked f5 lane 1"
.4byte 0x3ed13a57  # vslidedown.vi v20, v13, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked f5 tail lane 2 writes x10"
.assert rd_wdata == 0x5acc117f "vlseg6e32 m1 vl=2 unmasked f5 tail lane 2"
.4byte 0x61760337  # lui t1, 0x61760
.4byte 0x09630313  # addi t1, t1, 150
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a823  # sw t1, 16(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064aa23  # sw t1, 20(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064ae23  # sw t1, 28(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a023  # sw t1, 32(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a223  # sw t1, 36(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a423  # sw t1, 40(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a623  # sw t1, 44(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a823  # sw t1, 48(s1)
.4byte 0xa204e427  # vsseg6e32.v v8, (s1)
.assert trap == 0 "vsseg6e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 0 writes x10"
.assert rd_wdata == 0x3ca674ae "vlseg6e32 m1 vl=2 unmasked store off 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 4 writes x10"
.assert rd_wdata == 0x3ca67c63 "vlseg6e32 m1 vl=2 unmasked store off 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 8 writes x10"
.assert rd_wdata == 0x3ca68418 "vlseg6e32 m1 vl=2 unmasked store off 8"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 12 writes x10"
.assert rd_wdata == 0x3ca68bcd "vlseg6e32 m1 vl=2 unmasked store off 12"
.4byte 0x0104e503  # lwu a0, 16(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 16 writes x10"
.assert rd_wdata == 0x3ca69382 "vlseg6e32 m1 vl=2 unmasked store off 16"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 20 writes x10"
.assert rd_wdata == 0x3ca69b37 "vlseg6e32 m1 vl=2 unmasked store off 20"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 24 writes x10"
.assert rd_wdata == 0x3ca6a2ec "vlseg6e32 m1 vl=2 unmasked store off 24"
.4byte 0x01c4e503  # lwu a0, 28(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 28 writes x10"
.assert rd_wdata == 0x3ca6aaa1 "vlseg6e32 m1 vl=2 unmasked store off 28"
.4byte 0x0204e503  # lwu a0, 32(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 32 writes x10"
.assert rd_wdata == 0x3ca6b256 "vlseg6e32 m1 vl=2 unmasked store off 32"
.4byte 0x0244e503  # lwu a0, 36(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 36 writes x10"
.assert rd_wdata == 0x3ca6ba0b "vlseg6e32 m1 vl=2 unmasked store off 36"
.4byte 0x0284e503  # lwu a0, 40(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 40 writes x10"
.assert rd_wdata == 0x3ca6c1c0 "vlseg6e32 m1 vl=2 unmasked store off 40"
.4byte 0x02c4e503  # lwu a0, 44(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store off 44 writes x10"
.assert rd_wdata == 0x3ca6c975 "vlseg6e32 m1 vl=2 unmasked store off 44"
.4byte 0x0304e503  # lwu a0, 48(s1)
.assert rd_addr == 10 "vlseg6e32 m1 vl=2 unmasked store guard off 48 writes x10"
.assert rd_wdata == 0x617601aa "vlseg6e32 m1 vl=2 unmasked store guard off 48"

# Unit-stride segment vlseg7e8 m1 vl=2 unmasked under tu, mu.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0b600313  # addi t1, zero, 182
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e034657  # vmv.v.x v12, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0346d7  # vmv.v.x v13, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e034757  # vmv.v.x v14, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e8 m1 active vector length"
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640223  # sb t1, 4(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006402a3  # sb t1, 5(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640323  # sb t1, 6(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006403a3  # sb t1, 7(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640423  # sb t1, 8(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006404a3  # sb t1, 9(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640523  # sb t1, 10(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006405a3  # sb t1, 11(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640623  # sb t1, 12(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006406a3  # sb t1, 13(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640723  # sb t1, 14(s0)
.4byte 0xc2040407  # vlseg7e8.v v8, (s0)
.assert trap == 0 "vlseg7e8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x42 "vlseg7e8 m1 vl=2 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffb5 "vlseg7e8 m1 vl=2 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f0 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffb6 "vlseg7e8 m1 vl=2 unmasked f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x77 "vlseg7e8 m1 vl=2 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffea "vlseg7e8 m1 vl=2 unmasked f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f1 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffbd "vlseg7e8 m1 vl=2 unmasked f1 tail lane 2"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f2 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffac "vlseg7e8 m1 vl=2 unmasked f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f2 lane 1 writes x10"
.assert rd_wdata == 0x1f "vlseg7e8 m1 vl=2 unmasked f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f2 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffc4 "vlseg7e8 m1 vl=2 unmasked f2 tail lane 2"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f3 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffe1 "vlseg7e8 m1 vl=2 unmasked f3 lane 0"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f3 lane 1 writes x10"
.assert rd_wdata == 0x54 "vlseg7e8 m1 vl=2 unmasked f3 lane 1"
.4byte 0x3eb13a57  # vslidedown.vi v20, v11, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f3 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffcb "vlseg7e8 m1 vl=2 unmasked f3 tail lane 2"
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f4 lane 0 writes x10"
.assert rd_wdata == 0x16 "vlseg7e8 m1 vl=2 unmasked f4 lane 0"
.4byte 0x3ec0ba57  # vslidedown.vi v20, v12, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f4 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff89 "vlseg7e8 m1 vl=2 unmasked f4 lane 1"
.4byte 0x3ec13a57  # vslidedown.vi v20, v12, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f4 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffd2 "vlseg7e8 m1 vl=2 unmasked f4 tail lane 2"
.4byte 0x42d02557  # vmv.x.s a0, v13
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f5 lane 0 writes x10"
.assert rd_wdata == 0x4b "vlseg7e8 m1 vl=2 unmasked f5 lane 0"
.4byte 0x3ed0ba57  # vslidedown.vi v20, v13, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f5 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffbe "vlseg7e8 m1 vl=2 unmasked f5 lane 1"
.4byte 0x3ed13a57  # vslidedown.vi v20, v13, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f5 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffd9 "vlseg7e8 m1 vl=2 unmasked f5 tail lane 2"
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f6 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff80 "vlseg7e8 m1 vl=2 unmasked f6 lane 0"
.4byte 0x3ee0ba57  # vslidedown.vi v20, v14, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f6 lane 1 writes x10"
.assert rd_wdata == 0xfffffffffffffff3 "vlseg7e8 m1 vl=2 unmasked f6 lane 1"
.4byte 0x3ee13a57  # vslidedown.vi v20, v14, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked f6 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffe0 "vlseg7e8 m1 vl=2 unmasked f6 tail lane 2"
.4byte 0x08400313  # addi t1, zero, 132
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648123  # sb t1, 2(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648223  # sb t1, 4(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006482a3  # sb t1, 5(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648323  # sb t1, 6(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006483a3  # sb t1, 7(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648423  # sb t1, 8(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006484a3  # sb t1, 9(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648523  # sb t1, 10(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006485a3  # sb t1, 11(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648623  # sb t1, 12(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006486a3  # sb t1, 13(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648723  # sb t1, 14(s1)
.4byte 0xc2048427  # vsseg7e8.v v8, (s1)
.assert trap == 0 "vsseg7e8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 0 writes x10"
.assert rd_wdata == 0x42 "vlseg7e8 m1 vl=2 unmasked store off 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 1 writes x10"
.assert rd_wdata == 0x77 "vlseg7e8 m1 vl=2 unmasked store off 1"
.4byte 0x0024c503  # lbu a0, 2(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 2 writes x10"
.assert rd_wdata == 0xac "vlseg7e8 m1 vl=2 unmasked store off 2"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 3 writes x10"
.assert rd_wdata == 0xe1 "vlseg7e8 m1 vl=2 unmasked store off 3"
.4byte 0x0044c503  # lbu a0, 4(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 4 writes x10"
.assert rd_wdata == 0x16 "vlseg7e8 m1 vl=2 unmasked store off 4"
.4byte 0x0054c503  # lbu a0, 5(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 5 writes x10"
.assert rd_wdata == 0x4b "vlseg7e8 m1 vl=2 unmasked store off 5"
.4byte 0x0064c503  # lbu a0, 6(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 6 writes x10"
.assert rd_wdata == 0x80 "vlseg7e8 m1 vl=2 unmasked store off 6"
.4byte 0x0074c503  # lbu a0, 7(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 7 writes x10"
.assert rd_wdata == 0xb5 "vlseg7e8 m1 vl=2 unmasked store off 7"
.4byte 0x0084c503  # lbu a0, 8(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 8 writes x10"
.assert rd_wdata == 0xea "vlseg7e8 m1 vl=2 unmasked store off 8"
.4byte 0x0094c503  # lbu a0, 9(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 9 writes x10"
.assert rd_wdata == 0x1f "vlseg7e8 m1 vl=2 unmasked store off 9"
.4byte 0x00a4c503  # lbu a0, 10(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 10 writes x10"
.assert rd_wdata == 0x54 "vlseg7e8 m1 vl=2 unmasked store off 10"
.4byte 0x00b4c503  # lbu a0, 11(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 11 writes x10"
.assert rd_wdata == 0x89 "vlseg7e8 m1 vl=2 unmasked store off 11"
.4byte 0x00c4c503  # lbu a0, 12(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 12 writes x10"
.assert rd_wdata == 0xbe "vlseg7e8 m1 vl=2 unmasked store off 12"
.4byte 0x00d4c503  # lbu a0, 13(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store off 13 writes x10"
.assert rd_wdata == 0xf3 "vlseg7e8 m1 vl=2 unmasked store off 13"
.4byte 0x00e4c503  # lbu a0, 14(s1)
.assert rd_addr == 10 "vlseg7e8 m1 vl=2 unmasked store guard off 14 writes x10"
.assert rd_wdata == 0xca "vlseg7e8 m1 vl=2 unmasked store guard off 14"

# Unit-stride segment vlseg8e64 m1 vl=1 unmasked under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5ae26337  # lui t1, 0x5ae26
.4byte 0xb1030313  # addi t1, t1, -1264
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa73d0fb7  # lui t6, 0xa73d0
.4byte 0x220f8f93  # addi t6, t6, 544
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e034657  # vmv.v.x v12, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e0346d7  # vmv.v.x v13, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e034757  # vmv.v.x v14, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e0347d7  # vmv.v.x v15, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x1 "e64 m1 active vector length"
.4byte 0x393a7337  # lui t1, 0x393a7
.4byte 0xb8c30313  # addi t1, t1, -1140
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xadce8fb7  # lui t6, 0xadce8
.4byte 0x010f8f93  # addi t6, t6, 16
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643423  # sd t1, 8(s0)
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
.4byte 0xe2047407  # vlseg8e64.v v8, (s0)
.assert trap == 0 "vlseg8e64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x393a6b8cadce8010 "vlseg8e64 m1 vl=1 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f0 tail lane 1 writes x10"
.assert rd_wdata == 0x5ae25b10a73d0220 "vlseg8e64 m1 vl=1 unmasked f0 tail lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x4c41708fb8db8721 "vlseg8e64 m1 vl=1 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f1 tail lane 1 writes x10"
.assert rd_wdata == 0x6de96013b24a0931 "vlseg8e64 m1 vl=1 unmasked f1 tail lane 1"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f2 lane 0 writes x10"
.assert rd_wdata == 0x5f487592c3e88e32 "vlseg8e64 m1 vl=1 unmasked f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f2 tail lane 1 writes x10"
.assert rd_wdata == 0x80f06516bd571042 "vlseg8e64 m1 vl=1 unmasked f2 tail lane 1"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f3 lane 0 writes x10"
.assert rd_wdata == 0x724f7a95cef59543 "vlseg8e64 m1 vl=1 unmasked f3 lane 0"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f3 tail lane 1 writes x10"
.assert rd_wdata == 0x93f76a19c8641753 "vlseg8e64 m1 vl=1 unmasked f3 tail lane 1"
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f4 lane 0 writes x10"
.assert rd_wdata == 0x85567f98da029c54 "vlseg8e64 m1 vl=1 unmasked f4 lane 0"
.4byte 0x3ec0ba57  # vslidedown.vi v20, v12, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f4 tail lane 1 writes x10"
.assert rd_wdata == 0xa6fe6f1cd3711e64 "vlseg8e64 m1 vl=1 unmasked f4 tail lane 1"
.4byte 0x42d02557  # vmv.x.s a0, v13
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f5 lane 0 writes x10"
.assert rd_wdata == 0x985d849be50fa365 "vlseg8e64 m1 vl=1 unmasked f5 lane 0"
.4byte 0x3ed0ba57  # vslidedown.vi v20, v13, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f5 tail lane 1 writes x10"
.assert rd_wdata == 0xba05741fde7e2575 "vlseg8e64 m1 vl=1 unmasked f5 tail lane 1"
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f6 lane 0 writes x10"
.assert rd_wdata == 0xab64899ef01caa76 "vlseg8e64 m1 vl=1 unmasked f6 lane 0"
.4byte 0x3ee0ba57  # vslidedown.vi v20, v14, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f6 tail lane 1 writes x10"
.assert rd_wdata == 0xcd0c7922e98b2c86 "vlseg8e64 m1 vl=1 unmasked f6 tail lane 1"
.4byte 0x42f02557  # vmv.x.s a0, v15
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f7 lane 0 writes x10"
.assert rd_wdata == 0xbe6b8ea1fb29b187 "vlseg8e64 m1 vl=1 unmasked f7 lane 0"
.4byte 0x3ef0ba57  # vslidedown.vi v20, v15, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked f7 tail lane 1 writes x10"
.assert rd_wdata == 0xe0137e25f4983397 "vlseg8e64 m1 vl=1 unmasked f7 tail lane 1"
.4byte 0x61491337  # lui t1, 0x61491
.4byte 0x15830313  # addi t1, t1, 344
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11790fb7  # lui t6, 0x11790
.4byte 0x088f8f93  # addi t6, t6, 136
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b423  # sd t1, 40(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264bc23  # sd t1, 56(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0464b023  # sd t1, 64(s1)
.4byte 0xe204f427  # vsseg8e64.v v8, (s1)
.assert trap == 0 "vsseg8e64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked store off 0 writes x10"
.assert rd_wdata == 0x393a6b8cadce8010 "vlseg8e64 m1 vl=1 unmasked store off 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked store off 8 writes x10"
.assert rd_wdata == 0x4c41708fb8db8721 "vlseg8e64 m1 vl=1 unmasked store off 8"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked store off 16 writes x10"
.assert rd_wdata == 0x5f487592c3e88e32 "vlseg8e64 m1 vl=1 unmasked store off 16"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked store off 24 writes x10"
.assert rd_wdata == 0x724f7a95cef59543 "vlseg8e64 m1 vl=1 unmasked store off 24"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked store off 32 writes x10"
.assert rd_wdata == 0x85567f98da029c54 "vlseg8e64 m1 vl=1 unmasked store off 32"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked store off 40 writes x10"
.assert rd_wdata == 0x985d849be50fa365 "vlseg8e64 m1 vl=1 unmasked store off 40"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked store off 48 writes x10"
.assert rd_wdata == 0xab64899ef01caa76 "vlseg8e64 m1 vl=1 unmasked store off 48"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked store off 56 writes x10"
.assert rd_wdata == 0xbe6b8ea1fb29b187 "vlseg8e64 m1 vl=1 unmasked store off 56"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "vlseg8e64 m1 vl=1 unmasked store guard off 64 writes x10"
.assert rd_wdata == 0xf981397069e13910 "vlseg8e64 m1 vl=1 unmasked store guard off 64"

# Unit-stride segment vlseg3e32 m1 vl=3 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5b051337  # lui t1, 0x5b051
.4byte 0x12930313  # addi t1, t1, 297
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x51df8337  # lui t1, 0x51df8
.4byte 0x3c930313  # addi t1, t1, 969
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642823  # sw t1, 16(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642a23  # sw t1, 20(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642c23  # sw t1, 24(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642e23  # sw t1, 28(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642023  # sw t1, 32(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642223  # sw t1, 36(s0)
.4byte 0x40046407  # vlseg3e32.v v8, (s0), v0.t
.assert trap == 0 "vlseg3e32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f0 lane 0 writes x10"
.assert rd_wdata == 0x51df83c9 "vlseg3e32 m1 vl=3 mask=0b101 f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f0 lane 1 writes x10"
.assert rd_wdata == 0x5b051129 "vlseg3e32 m1 vl=3 mask=0b101 f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f0 lane 2 writes x10"
.assert rd_wdata == 0x51dfb207 "vlseg3e32 m1 vl=3 mask=0b101 f0 lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f0 tail lane 3 writes x10"
.assert rd_wdata == 0x5b051129 "vlseg3e32 m1 vl=3 mask=0b101 f0 tail lane 3"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f1 lane 0 writes x10"
.assert rd_wdata == 0x51df8b7e "vlseg3e32 m1 vl=3 mask=0b101 f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f1 lane 1 writes x10"
.assert rd_wdata == 0x5b05114e "vlseg3e32 m1 vl=3 mask=0b101 f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f1 lane 2 writes x10"
.assert rd_wdata == 0x51dfb9bc "vlseg3e32 m1 vl=3 mask=0b101 f1 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f1 tail lane 3 writes x10"
.assert rd_wdata == 0x5b05114e "vlseg3e32 m1 vl=3 mask=0b101 f1 tail lane 3"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f2 lane 0 writes x10"
.assert rd_wdata == 0x51df9333 "vlseg3e32 m1 vl=3 mask=0b101 f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f2 lane 1 writes x10"
.assert rd_wdata == 0x5b051173 "vlseg3e32 m1 vl=3 mask=0b101 f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f2 lane 2 writes x10"
.assert rd_wdata == 0x51dfc171 "vlseg3e32 m1 vl=3 mask=0b101 f2 lane 2"
.4byte 0x3ea1ba57  # vslidedown.vi v20, v10, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 f2 tail lane 3 writes x10"
.assert rd_wdata == 0x5b051173 "vlseg3e32 m1 vl=3 mask=0b101 f2 tail lane 3"
.4byte 0x61a90337  # lui t1, 0x61a90
.4byte 0x0e130313  # addi t1, t1, 225
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a823  # sw t1, 16(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064aa23  # sw t1, 20(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064ae23  # sw t1, 28(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a023  # sw t1, 32(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a223  # sw t1, 36(s1)
.4byte 0x4004e427  # vsseg3e32.v v8, (s1), v0.t
.assert trap == 0 "vsseg3e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store off 0 writes x10"
.assert rd_wdata == 0x51df83c9 "vlseg3e32 m1 vl=3 mask=0b101 store off 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store off 4 writes x10"
.assert rd_wdata == 0x51df8b7e "vlseg3e32 m1 vl=3 mask=0b101 store off 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store off 8 writes x10"
.assert rd_wdata == 0x51df9333 "vlseg3e32 m1 vl=3 mask=0b101 store off 8"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store off 12 writes x10"
.assert rd_wdata == 0x61a90126 "vlseg3e32 m1 vl=3 mask=0b101 store off 12"
.4byte 0x0104e503  # lwu a0, 16(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store off 16 writes x10"
.assert rd_wdata == 0x61a9013d "vlseg3e32 m1 vl=3 mask=0b101 store off 16"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store off 20 writes x10"
.assert rd_wdata == 0x61a90154 "vlseg3e32 m1 vl=3 mask=0b101 store off 20"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store off 24 writes x10"
.assert rd_wdata == 0x51dfb207 "vlseg3e32 m1 vl=3 mask=0b101 store off 24"
.4byte 0x01c4e503  # lwu a0, 28(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store off 28 writes x10"
.assert rd_wdata == 0x51dfb9bc "vlseg3e32 m1 vl=3 mask=0b101 store off 28"
.4byte 0x0204e503  # lwu a0, 32(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store off 32 writes x10"
.assert rd_wdata == 0x51dfc171 "vlseg3e32 m1 vl=3 mask=0b101 store off 32"
.4byte 0x0244e503  # lwu a0, 36(s1)
.assert rd_addr == 10 "vlseg3e32 m1 vl=3 mask=0b101 store guard off 36 writes x10"
.assert rd_wdata == 0x61a901b0 "vlseg3e32 m1 vl=3 mask=0b101 store guard off 36"

# Unit-stride segment vlseg4e8 m1 vl=3 mask=0b10 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0bf00313  # addi t1, zero, 191
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x05700313  # addi t1, zero, 87
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640223  # sb t1, 4(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006402a3  # sb t1, 5(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640323  # sb t1, 6(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006403a3  # sb t1, 7(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640423  # sb t1, 8(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006404a3  # sb t1, 9(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640523  # sb t1, 10(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006405a3  # sb t1, 11(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640623  # sb t1, 12(s0)
.4byte 0x60040407  # vlseg4e8.v v8, (s0), v0.t
.assert trap == 0 "vlseg4e8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f0 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffbf "vlseg4e8 m1 vl=3 mask=0b10 f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f0 lane 1 writes x10"
.assert rd_wdata == 0x2b "vlseg4e8 m1 vl=3 mask=0b10 f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f0 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffbf "vlseg4e8 m1 vl=3 mask=0b10 f0 lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f0 tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffbf "vlseg4e8 m1 vl=3 mask=0b10 f0 tail lane 3"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f1 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffc6 "vlseg4e8 m1 vl=3 mask=0b10 f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f1 lane 1 writes x10"
.assert rd_wdata == 0x60 "vlseg4e8 m1 vl=3 mask=0b10 f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f1 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffc6 "vlseg4e8 m1 vl=3 mask=0b10 f1 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f1 tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffc6 "vlseg4e8 m1 vl=3 mask=0b10 f1 tail lane 3"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f2 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffcd "vlseg4e8 m1 vl=3 mask=0b10 f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f2 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff95 "vlseg4e8 m1 vl=3 mask=0b10 f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f2 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffcd "vlseg4e8 m1 vl=3 mask=0b10 f2 lane 2"
.4byte 0x3ea1ba57  # vslidedown.vi v20, v10, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f2 tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffcd "vlseg4e8 m1 vl=3 mask=0b10 f2 tail lane 3"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f3 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffd4 "vlseg4e8 m1 vl=3 mask=0b10 f3 lane 0"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f3 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffca "vlseg4e8 m1 vl=3 mask=0b10 f3 lane 1"
.4byte 0x3eb13a57  # vslidedown.vi v20, v11, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f3 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffd4 "vlseg4e8 m1 vl=3 mask=0b10 f3 lane 2"
.4byte 0x3eb1ba57  # vslidedown.vi v20, v11, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 f3 tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffd4 "vlseg4e8 m1 vl=3 mask=0b10 f3 tail lane 3"
.4byte 0x09300313  # addi t1, zero, 147
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648123  # sb t1, 2(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648223  # sb t1, 4(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006482a3  # sb t1, 5(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648323  # sb t1, 6(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006483a3  # sb t1, 7(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648423  # sb t1, 8(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006484a3  # sb t1, 9(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648523  # sb t1, 10(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006485a3  # sb t1, 11(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648623  # sb t1, 12(s1)
.4byte 0x60048427  # vsseg4e8.v v8, (s1), v0.t
.assert trap == 0 "vsseg4e8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 0 writes x10"
.assert rd_wdata == 0x93 "vlseg4e8 m1 vl=3 mask=0b10 store off 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 1 writes x10"
.assert rd_wdata == 0x98 "vlseg4e8 m1 vl=3 mask=0b10 store off 1"
.4byte 0x0024c503  # lbu a0, 2(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 2 writes x10"
.assert rd_wdata == 0x9d "vlseg4e8 m1 vl=3 mask=0b10 store off 2"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 3 writes x10"
.assert rd_wdata == 0xa2 "vlseg4e8 m1 vl=3 mask=0b10 store off 3"
.4byte 0x0044c503  # lbu a0, 4(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 4 writes x10"
.assert rd_wdata == 0x2b "vlseg4e8 m1 vl=3 mask=0b10 store off 4"
.4byte 0x0054c503  # lbu a0, 5(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 5 writes x10"
.assert rd_wdata == 0x60 "vlseg4e8 m1 vl=3 mask=0b10 store off 5"
.4byte 0x0064c503  # lbu a0, 6(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 6 writes x10"
.assert rd_wdata == 0x95 "vlseg4e8 m1 vl=3 mask=0b10 store off 6"
.4byte 0x0074c503  # lbu a0, 7(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 7 writes x10"
.assert rd_wdata == 0xca "vlseg4e8 m1 vl=3 mask=0b10 store off 7"
.4byte 0x0084c503  # lbu a0, 8(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 8 writes x10"
.assert rd_wdata == 0xbb "vlseg4e8 m1 vl=3 mask=0b10 store off 8"
.4byte 0x0094c503  # lbu a0, 9(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 9 writes x10"
.assert rd_wdata == 0xc0 "vlseg4e8 m1 vl=3 mask=0b10 store off 9"
.4byte 0x00a4c503  # lbu a0, 10(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 10 writes x10"
.assert rd_wdata == 0xc5 "vlseg4e8 m1 vl=3 mask=0b10 store off 10"
.4byte 0x00b4c503  # lbu a0, 11(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store off 11 writes x10"
.assert rd_wdata == 0xca "vlseg4e8 m1 vl=3 mask=0b10 store off 11"
.4byte 0x00c4c503  # lbu a0, 12(s1)
.assert rd_addr == 10 "vlseg4e8 m1 vl=3 mask=0b10 store guard off 12 writes x10"
.assert rd_wdata == 0xcf "vlseg4e8 m1 vl=3 mask=0b10 store guard off 12"

# Strided segment vlsseg2e32 m1 vl=2 stride=16 unmasked under tu, mu.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5b511337  # lui t1, 0x5b511
.4byte 0x1ad30313  # addi t1, t1, 429
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x6e2b9337  # lui t1, 0x6e2b9
.4byte 0x7ed30313  # addi t1, t1, 2029
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642823  # sw t1, 16(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642a23  # sw t1, 20(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642023  # sw t1, 32(s0)
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x2bd46407  # vlsseg2e32.v v8, (s0), t4
.assert trap == 0 "vlsseg2e32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x6e2b97ed "vlsseg2e32 m1 vl=2 stride=16 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x6e2ba757 "vlsseg2e32 m1 vl=2 stride=16 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked f0 tail lane 2 writes x10"
.assert rd_wdata == 0x5b5111ad "vlsseg2e32 m1 vl=2 stride=16 unmasked f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x6e2b9fa2 "vlsseg2e32 m1 vl=2 stride=16 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0x6e2baf0c "vlsseg2e32 m1 vl=2 stride=16 unmasked f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked f1 tail lane 2 writes x10"
.assert rd_wdata == 0x5b5111d2 "vlsseg2e32 m1 vl=2 stride=16 unmasked f1 tail lane 2"
.4byte 0x61ed0337  # lui t1, 0x61ed0
.4byte 0x14530313  # addi t1, t1, 325
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a823  # sw t1, 16(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064aa23  # sw t1, 20(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a023  # sw t1, 32(s1)
.4byte 0x2bd4e427  # vssseg2e32.v v8, (s1), t4
.assert trap == 0 "vssseg2e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 0 writes x10"
.assert rd_wdata == 0x6e2b97ed "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 4 writes x10"
.assert rd_wdata == 0x6e2b9fa2 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 4"
.4byte 0x0104e503  # lwu a0, 16(s1)
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 16 writes x10"
.assert rd_wdata == 0x6e2ba757 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 16"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 20 writes x10"
.assert rd_wdata == 0x6e2baf0c "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 20"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 8 writes x10"
.assert rd_wdata == 0x61ed01a1 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 8"
.4byte 0x0204e503  # lwu a0, 32(s1)
.assert rd_addr == 10 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 32 writes x10"
.assert rd_wdata == 0x61ed01b8 "vlsseg2e32 m1 vl=2 stride=16 unmasked store off 32"

# Strided segment vlsseg3e16 m1 vl=2 stride=10 unmasked under tu, mu.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x3fe30313  # addi t1, t1, 1022
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01d30313  # addi t1, t1, 29
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x01d30313  # addi t1, t1, 29
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e16 m1 active vector length"
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x93e30313  # addi t1, t1, -1730
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641523  # sh t1, 10(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641623  # sh t1, 12(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641723  # sh t1, 14(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641a23  # sh t1, 20(s0)
.4byte 0x00a00e93  # addi t4, zero, 10
.4byte 0x4bd45407  # vlsseg3e16.v v8, (s0), t4
.assert trap == 0 "vlsseg3e16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x593e "vlsseg3e16 m1 vl=2 stride=10 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x6d87 "vlsseg3e16 m1 vl=2 stride=10 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked f0 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffb3fe "vlsseg3e16 m1 vl=2 stride=10 unmasked f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x6001 "vlsseg3e16 m1 vl=2 stride=10 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0x744a "vlsseg3e16 m1 vl=2 stride=10 unmasked f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked f1 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffb41b "vlsseg3e16 m1 vl=2 stride=10 unmasked f1 tail lane 2"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked f2 lane 0 writes x10"
.assert rd_wdata == 0x66c4 "vlsseg3e16 m1 vl=2 stride=10 unmasked f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked f2 lane 1 writes x10"
.assert rd_wdata == 0x7b0d "vlsseg3e16 m1 vl=2 stride=10 unmasked f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked f2 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffb438 "vlsseg3e16 m1 vl=2 stride=10 unmasked f2 tail lane 2"
.4byte 0x00007337  # lui t1, 0x7
.4byte 0xf7230313  # addi t1, t1, -142
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649523  # sh t1, 10(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649623  # sh t1, 12(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649723  # sh t1, 14(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649a23  # sh t1, 20(s1)
.4byte 0x4bd4d427  # vssseg3e16.v v8, (s1), t4
.assert trap == 0 "vssseg3e16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 0 writes x10"
.assert rd_wdata == 0x593e "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 2 writes x10"
.assert rd_wdata == 0x6001 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 2"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 4 writes x10"
.assert rd_wdata == 0x66c4 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 4"
.4byte 0x00a4d503  # lhu a0, 10(s1)
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 10 writes x10"
.assert rd_wdata == 0x6d87 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 10"
.4byte 0x00c4d503  # lhu a0, 12(s1)
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 12 writes x10"
.assert rd_wdata == 0x744a "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 12"
.4byte 0x00e4d503  # lhu a0, 14(s1)
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 14 writes x10"
.assert rd_wdata == 0x7b0d "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 14"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 6 writes x10"
.assert rd_wdata == 0x6fe4 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 6"
.4byte 0x0144d503  # lhu a0, 20(s1)
.assert rd_addr == 10 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 20 writes x10"
.assert rd_wdata == 0x6ff7 "vlsseg3e16 m1 vl=2 stride=10 unmasked store off 20"

# Strided segment vlsseg4e8 m1 vl=2 stride=7 unmasked under tu, mu.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0ce00313  # addi t1, zero, 206
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e8 m1 active vector length"
.4byte 0x07a00313  # addi t1, zero, 122
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006403a3  # sb t1, 7(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640423  # sb t1, 8(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006404a3  # sb t1, 9(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640523  # sb t1, 10(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640223  # sb t1, 4(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640723  # sb t1, 14(s0)
.4byte 0x00700e93  # addi t4, zero, 7
.4byte 0x6bd40407  # vlsseg4e8.v v8, (s0), t4
.assert trap == 0 "vlsseg4e8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x7a "vlsseg4e8 m1 vl=2 stride=7 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x4e "vlsseg4e8 m1 vl=2 stride=7 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f0 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffce "vlsseg4e8 m1 vl=2 stride=7 unmasked f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffaf "vlsseg4e8 m1 vl=2 stride=7 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff83 "vlsseg4e8 m1 vl=2 stride=7 unmasked f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f1 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffd5 "vlsseg4e8 m1 vl=2 stride=7 unmasked f1 tail lane 2"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f2 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffe4 "vlsseg4e8 m1 vl=2 stride=7 unmasked f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f2 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffb8 "vlsseg4e8 m1 vl=2 stride=7 unmasked f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f2 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffdc "vlsseg4e8 m1 vl=2 stride=7 unmasked f2 tail lane 2"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f3 lane 0 writes x10"
.assert rd_wdata == 0x19 "vlsseg4e8 m1 vl=2 stride=7 unmasked f3 lane 0"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f3 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffed "vlsseg4e8 m1 vl=2 stride=7 unmasked f3 lane 1"
.4byte 0x3eb13a57  # vslidedown.vi v20, v11, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked f3 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffe3 "vlsseg4e8 m1 vl=2 stride=7 unmasked f3 tail lane 2"
.4byte 0x0ac00313  # addi t1, zero, 172
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648123  # sb t1, 2(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006483a3  # sb t1, 7(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648423  # sb t1, 8(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006484a3  # sb t1, 9(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648523  # sb t1, 10(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648223  # sb t1, 4(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648723  # sb t1, 14(s1)
.4byte 0x6bd48427  # vssseg4e8.v v8, (s1), t4
.assert trap == 0 "vssseg4e8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 0 writes x10"
.assert rd_wdata == 0x7a "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 1 writes x10"
.assert rd_wdata == 0xaf "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 1"
.4byte 0x0024c503  # lbu a0, 2(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 2 writes x10"
.assert rd_wdata == 0xe4 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 2"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 3 writes x10"
.assert rd_wdata == 0x19 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 3"
.4byte 0x0074c503  # lbu a0, 7(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 7 writes x10"
.assert rd_wdata == 0x4e "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 7"
.4byte 0x0084c503  # lbu a0, 8(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 8 writes x10"
.assert rd_wdata == 0x83 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 8"
.4byte 0x0094c503  # lbu a0, 9(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 9 writes x10"
.assert rd_wdata == 0xb8 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 9"
.4byte 0x00a4c503  # lbu a0, 10(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 10 writes x10"
.assert rd_wdata == 0xed "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 10"
.4byte 0x0044c503  # lbu a0, 4(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 4 writes x10"
.assert rd_wdata == 0xd4 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 4"
.4byte 0x00e4c503  # lbu a0, 14(s1)
.assert rd_addr == 10 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 14 writes x10"
.assert rd_wdata == 0xd9 "vlsseg4e8 m1 vl=2 stride=7 unmasked store off 14"

# Strided segment vlsseg2e64 m2 vl=3 stride=24 unmasked under tu, mu.
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5b6a6337  # lui t1, 0x5b6a6
.4byte 0xc2030313  # addi t1, t1, -992
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa8d50fb7  # lui t6, 0xa8d50
.4byte 0x440f8f93  # addi t6, t6, 1088
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.assert rd_addr == 12 "e64 m2 active vector length writes x12"
.assert rd_wdata == 0x3 "e64 m2 active vector length"
.4byte 0x6152a337  # lui t1, 0x6152a
.4byte 0x3d530313  # addi t1, t1, 981
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x06369fb7  # lui t6, 0x6369
.4byte 0x898f8f93  # addi t6, t6, -1896
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643c23  # sd t1, 24(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02643023  # sd t1, 32(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02643823  # sd t1, 48(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02643c23  # sd t1, 56(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x04643423  # sd t1, 72(s0)
.4byte 0x01800e93  # addi t4, zero, 24
.4byte 0x2bd47407  # vlsseg2e64.v v8, (s0), t4
.assert trap == 0 "vlsseg2e64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0x6152a3d506368898 "vlsseg2e64 m2 vl=3 stride=24 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x8760addb1c5096ba "vlsseg2e64 m2 vl=3 stride=24 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked f0 lane 2 writes x10"
.assert rd_wdata == 0xad6eb7e1326aa4dc "vlsseg2e64 m2 vl=3 stride=24 unmasked f0 lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked f0 tail lane 3 writes x10"
.assert rd_wdata == 0x5b6a5c20a8d50440 "vlsseg2e64 m2 vl=3 stride=24 unmasked f0 tail lane 3"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0x7459a8d811438fa9 "vlsseg2e64 m2 vl=3 stride=24 unmasked f1 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0x9a67b2de275d9dcb "vlsseg2e64 m2 vl=3 stride=24 unmasked f1 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked f1 lane 2 writes x10"
.assert rd_wdata == 0xc075bce43d77abed "vlsseg2e64 m2 vl=3 stride=24 unmasked f1 lane 2"
.4byte 0x3ea1ba57  # vslidedown.vi v20, v10, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked f1 tail lane 3 writes x10"
.assert rd_wdata == 0x6e716123b3e20b51 "vlsseg2e64 m2 vl=3 stride=24 unmasked f1 tail lane 3"
.4byte 0x61811337  # lui t1, 0x61811
.4byte 0x1b030313  # addi t1, t1, 432
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11e10fb7  # lui t6, 0x11e10
.4byte 0x110f8f93  # addi t6, t6, 272
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264bc23  # sd t1, 56(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0464b423  # sd t1, 72(s1)
.4byte 0x2bd4f427  # vssseg2e64.v v8, (s1), t4
.assert trap == 0 "vssseg2e64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 0 writes x10"
.assert rd_wdata == 0x6152a3d506368898 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 8 writes x10"
.assert rd_wdata == 0x7459a8d811438fa9 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 8"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 24 writes x10"
.assert rd_wdata == 0x8760addb1c5096ba "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 24"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 32 writes x10"
.assert rd_wdata == 0x9a67b2de275d9dcb "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 32"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 48 writes x10"
.assert rd_wdata == 0xad6eb7e1326aa4dc "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 48"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 56 writes x10"
.assert rd_wdata == 0xc075bce43d77abed "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 56"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 16 writes x10"
.assert rd_wdata == 0xd3ab2fc2542f2b76 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 16"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 72 writes x10"
.assert rd_wdata == 0xe6b234c55f3c3287 "vlsseg2e64 m2 vl=3 stride=24 unmasked store off 72"

# Strided segment vlsseg8e8 m1 vl=2 stride=12 unmasked under tu, mu.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0d400313  # addi t1, zero, 212
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e034657  # vmv.v.x v12, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0346d7  # vmv.v.x v13, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e034757  # vmv.v.x v14, t1
.4byte 0x00730313  # addi t1, t1, 7
.4byte 0x5e0347d7  # vmv.v.x v15, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e8 m1 active vector length"
.4byte 0x08800313  # addi t1, zero, 136
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640223  # sb t1, 4(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006402a3  # sb t1, 5(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640323  # sb t1, 6(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006403a3  # sb t1, 7(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640623  # sb t1, 12(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006406a3  # sb t1, 13(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640723  # sb t1, 14(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006407a3  # sb t1, 15(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640823  # sb t1, 16(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006408a3  # sb t1, 17(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640923  # sb t1, 18(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x006409a3  # sb t1, 19(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640423  # sb t1, 8(s0)
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00640c23  # sb t1, 24(s0)
.4byte 0x00c00e93  # addi t4, zero, 12
.4byte 0xebd40407  # vlsseg8e8.v v8, (s0), t4
.assert trap == 0 "vlsseg8e8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f0 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff88 "vlsseg8e8 m1 vl=2 stride=12 unmasked f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f0 lane 1 writes x10"
.assert rd_wdata == 0x30 "vlsseg8e8 m1 vl=2 stride=12 unmasked f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f0 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffd4 "vlsseg8e8 m1 vl=2 stride=12 unmasked f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f1 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffbd "vlsseg8e8 m1 vl=2 stride=12 unmasked f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f1 lane 1 writes x10"
.assert rd_wdata == 0x65 "vlsseg8e8 m1 vl=2 stride=12 unmasked f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f1 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffdb "vlsseg8e8 m1 vl=2 stride=12 unmasked f1 tail lane 2"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f2 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffff2 "vlsseg8e8 m1 vl=2 stride=12 unmasked f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f2 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff9a "vlsseg8e8 m1 vl=2 stride=12 unmasked f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f2 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffe2 "vlsseg8e8 m1 vl=2 stride=12 unmasked f2 tail lane 2"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f3 lane 0 writes x10"
.assert rd_wdata == 0x27 "vlsseg8e8 m1 vl=2 stride=12 unmasked f3 lane 0"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f3 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffcf "vlsseg8e8 m1 vl=2 stride=12 unmasked f3 lane 1"
.4byte 0x3eb13a57  # vslidedown.vi v20, v11, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f3 tail lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffffe9 "vlsseg8e8 m1 vl=2 stride=12 unmasked f3 tail lane 2"
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f4 lane 0 writes x10"
.assert rd_wdata == 0x5c "vlsseg8e8 m1 vl=2 stride=12 unmasked f4 lane 0"
.4byte 0x3ec0ba57  # vslidedown.vi v20, v12, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f4 lane 1 writes x10"
.assert rd_wdata == 0x4 "vlsseg8e8 m1 vl=2 stride=12 unmasked f4 lane 1"
.4byte 0x3ec13a57  # vslidedown.vi v20, v12, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f4 tail lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff0 "vlsseg8e8 m1 vl=2 stride=12 unmasked f4 tail lane 2"
.4byte 0x42d02557  # vmv.x.s a0, v13
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f5 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffff91 "vlsseg8e8 m1 vl=2 stride=12 unmasked f5 lane 0"
.4byte 0x3ed0ba57  # vslidedown.vi v20, v13, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f5 lane 1 writes x10"
.assert rd_wdata == 0x39 "vlsseg8e8 m1 vl=2 stride=12 unmasked f5 lane 1"
.4byte 0x3ed13a57  # vslidedown.vi v20, v13, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f5 tail lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffff7 "vlsseg8e8 m1 vl=2 stride=12 unmasked f5 tail lane 2"
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f6 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffffc6 "vlsseg8e8 m1 vl=2 stride=12 unmasked f6 lane 0"
.4byte 0x3ee0ba57  # vslidedown.vi v20, v14, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f6 lane 1 writes x10"
.assert rd_wdata == 0x6e "vlsseg8e8 m1 vl=2 stride=12 unmasked f6 lane 1"
.4byte 0x3ee13a57  # vslidedown.vi v20, v14, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f6 tail lane 2 writes x10"
.assert rd_wdata == 0xfffffffffffffffe "vlsseg8e8 m1 vl=2 stride=12 unmasked f6 tail lane 2"
.4byte 0x42f02557  # vmv.x.s a0, v15
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f7 lane 0 writes x10"
.assert rd_wdata == 0xfffffffffffffffb "vlsseg8e8 m1 vl=2 stride=12 unmasked f7 lane 0"
.4byte 0x3ef0ba57  # vslidedown.vi v20, v15, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f7 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffa3 "vlsseg8e8 m1 vl=2 stride=12 unmasked f7 lane 1"
.4byte 0x3ef13a57  # vslidedown.vi v20, v15, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked f7 tail lane 2 writes x10"
.assert rd_wdata == 0x5 "vlsseg8e8 m1 vl=2 stride=12 unmasked f7 tail lane 2"
.4byte 0x0b600313  # addi t1, zero, 182
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648123  # sb t1, 2(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648223  # sb t1, 4(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006482a3  # sb t1, 5(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648323  # sb t1, 6(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006483a3  # sb t1, 7(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648623  # sb t1, 12(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006486a3  # sb t1, 13(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648723  # sb t1, 14(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006487a3  # sb t1, 15(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648823  # sb t1, 16(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006488a3  # sb t1, 17(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648923  # sb t1, 18(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x006489a3  # sb t1, 19(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648423  # sb t1, 8(s1)
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x00648c23  # sb t1, 24(s1)
.4byte 0xebd48427  # vssseg8e8.v v8, (s1), t4
.assert trap == 0 "vssseg8e8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 0 writes x10"
.assert rd_wdata == 0x88 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 1 writes x10"
.assert rd_wdata == 0xbd "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 1"
.4byte 0x0024c503  # lbu a0, 2(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 2 writes x10"
.assert rd_wdata == 0xf2 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 2"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 3 writes x10"
.assert rd_wdata == 0x27 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 3"
.4byte 0x0044c503  # lbu a0, 4(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 4 writes x10"
.assert rd_wdata == 0x5c "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 4"
.4byte 0x0054c503  # lbu a0, 5(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 5 writes x10"
.assert rd_wdata == 0x91 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 5"
.4byte 0x0064c503  # lbu a0, 6(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 6 writes x10"
.assert rd_wdata == 0xc6 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 6"
.4byte 0x0074c503  # lbu a0, 7(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 7 writes x10"
.assert rd_wdata == 0xfb "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 7"
.4byte 0x00c4c503  # lbu a0, 12(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 12 writes x10"
.assert rd_wdata == 0x30 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 12"
.4byte 0x00d4c503  # lbu a0, 13(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 13 writes x10"
.assert rd_wdata == 0x65 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 13"
.4byte 0x00e4c503  # lbu a0, 14(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 14 writes x10"
.assert rd_wdata == 0x9a "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 14"
.4byte 0x00f4c503  # lbu a0, 15(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 15 writes x10"
.assert rd_wdata == 0xcf "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 15"
.4byte 0x0104c503  # lbu a0, 16(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 16 writes x10"
.assert rd_wdata == 0x4 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 16"
.4byte 0x0114c503  # lbu a0, 17(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 17 writes x10"
.assert rd_wdata == 0x39 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 17"
.4byte 0x0124c503  # lbu a0, 18(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 18 writes x10"
.assert rd_wdata == 0x6e "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 18"
.4byte 0x0134c503  # lbu a0, 19(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 19 writes x10"
.assert rd_wdata == 0xa3 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 19"
.4byte 0x0084c503  # lbu a0, 8(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 8 writes x10"
.assert rd_wdata == 0x6 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 8"
.4byte 0x0184c503  # lbu a0, 24(s1)
.assert rd_addr == 10 "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 24 writes x10"
.assert rd_wdata == 0xb "vlsseg8e8 m1 vl=2 stride=12 unmasked store off 24"

# Strided segment vlsseg3e32 m1 vl=3 stride=16 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5be91337  # lui t1, 0x5be91
.4byte 0x2b530313  # addi t1, t1, 693
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0xa6c3c337  # lui t1, 0xa6c3c
.4byte 0x03530313  # addi t1, t1, 53
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642823  # sw t1, 16(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642a23  # sw t1, 20(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642c23  # sw t1, 24(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642023  # sw t1, 32(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642223  # sw t1, 36(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642423  # sw t1, 40(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02642823  # sw t1, 48(s0)
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x49d46407  # vlsseg3e32.v v8, (s0), t4, v0.t
.assert trap == 0 "vlsseg3e32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f0 lane 0 writes x10"
.assert rd_wdata == 0xffffffffa6c3c035 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f0 lane 1 writes x10"
.assert rd_wdata == 0x5be912b5 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f0 lane 2 writes x10"
.assert rd_wdata == 0xffffffffa6c3ee73 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f0 lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f0 tail lane 3 writes x10"
.assert rd_wdata == 0x5be912b5 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f0 tail lane 3"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f1 lane 0 writes x10"
.assert rd_wdata == 0xffffffffa6c3c7ea "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f1 lane 1 writes x10"
.assert rd_wdata == 0x5be912da "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f1 lane 2 writes x10"
.assert rd_wdata == 0xffffffffa6c3f628 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f1 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f1 tail lane 3 writes x10"
.assert rd_wdata == 0x5be912da "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f1 tail lane 3"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f2 lane 0 writes x10"
.assert rd_wdata == 0xffffffffa6c3cf9f "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f2 lane 1 writes x10"
.assert rd_wdata == 0x5be912ff "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f2 lane 2 writes x10"
.assert rd_wdata == 0xffffffffa6c3fddd "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f2 lane 2"
.4byte 0x3ea1ba57  # vslidedown.vi v20, v10, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f2 tail lane 3 writes x10"
.assert rd_wdata == 0x5be912ff "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 f2 tail lane 3"
.4byte 0x62750337  # lui t1, 0x62750
.4byte 0x20d30313  # addi t1, t1, 525
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a823  # sw t1, 16(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064aa23  # sw t1, 20(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a023  # sw t1, 32(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a223  # sw t1, 36(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a423  # sw t1, 40(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0264a823  # sw t1, 48(s1)
.4byte 0x49d4e427  # vssseg3e32.v v8, (s1), t4, v0.t
.assert trap == 0 "vssseg3e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 0 writes x10"
.assert rd_wdata == 0xa6c3c035 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 4 writes x10"
.assert rd_wdata == 0xa6c3c7ea "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 8 writes x10"
.assert rd_wdata == 0xa6c3cf9f "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 8"
.4byte 0x0104e503  # lwu a0, 16(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 16 writes x10"
.assert rd_wdata == 0x62750252 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 16"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 20 writes x10"
.assert rd_wdata == 0x62750269 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 20"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 24 writes x10"
.assert rd_wdata == 0x62750280 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 24"
.4byte 0x0204e503  # lwu a0, 32(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 32 writes x10"
.assert rd_wdata == 0xa6c3ee73 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 32"
.4byte 0x0244e503  # lwu a0, 36(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 36 writes x10"
.assert rd_wdata == 0xa6c3f628 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 36"
.4byte 0x0284e503  # lwu a0, 40(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 40 writes x10"
.assert rd_wdata == 0xa6c3fddd "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 40"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 12 writes x10"
.assert rd_wdata == 0x627502dc "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 12"
.4byte 0x0304e503  # lwu a0, 48(s1)
.assert rd_addr == 10 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 48 writes x10"
.assert rd_wdata == 0x627502f3 "vlsseg3e32 m1 vl=3 stride=16 mask=0b101 store off 48"

# Strided segment vlsseg2e16 m1 vl=3 stride=8 mask=0b10 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0xc8630313  # addi t1, t1, -890
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01d30313  # addi t1, t1, 29
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x1d630313  # addi t1, t1, 470
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641423  # sh t1, 8(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641523  # sh t1, 10(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641823  # sh t1, 16(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641923  # sh t1, 18(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x6c330313  # addi t1, t1, 1731
.4byte 0x00641c23  # sh t1, 24(s0)
.4byte 0x00800e93  # addi t4, zero, 8
.4byte 0x29d45407  # vlsseg2e16.v v8, (s0), t4, v0.t
.assert trap == 0 "vlsseg2e16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f0 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffbc86 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f0 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8f5c "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f0 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffbc86 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f0 lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f0 tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffbc86 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f0 tail lane 3"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f1 lane 0 writes x10"
.assert rd_wdata == 0xffffffffffffbca3 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f1 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff961f "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f1 lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffbca3 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f1 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f1 tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffbca3 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 f1 tail lane 3"
.4byte 0x00007337  # lui t1, 0x7
.4byte 0x7aa30313  # addi t1, t1, 1962
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649423  # sh t1, 8(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649523  # sh t1, 10(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649823  # sh t1, 16(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649923  # sh t1, 18(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x01330313  # addi t1, t1, 19
.4byte 0x00649c23  # sh t1, 24(s1)
.4byte 0x29d4d427  # vssseg2e16.v v8, (s1), t4, v0.t
.assert trap == 0 "vssseg2e16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 0 writes x10"
.assert rd_wdata == 0x77aa "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 2 writes x10"
.assert rd_wdata == 0x77bd "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 2"
.4byte 0x0084d503  # lhu a0, 8(s1)
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 8 writes x10"
.assert rd_wdata == 0x8f5c "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 8"
.4byte 0x00a4d503  # lhu a0, 10(s1)
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 10 writes x10"
.assert rd_wdata == 0x961f "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 10"
.4byte 0x0104d503  # lhu a0, 16(s1)
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 16 writes x10"
.assert rd_wdata == 0x77f6 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 16"
.4byte 0x0124d503  # lhu a0, 18(s1)
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 18 writes x10"
.assert rd_wdata == 0x7809 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 18"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 4 writes x10"
.assert rd_wdata == 0x781c "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 4"
.4byte 0x0184d503  # lhu a0, 24(s1)
.assert rd_addr == 10 "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 24 writes x10"
.assert rd_wdata == 0x782f "vlsseg2e16 m1 vl=3 stride=8 mask=0b10 store off 24"

# Strided segment vlsseg2e64 m1 vl=2 stride=24 mask=0b10 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5bf26337  # lui t1, 0x5bf26
.4byte 0xd3030313  # addi t1, t1, -720
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaa6d0fb7  # lui t6, 0xaa6d0
.4byte 0x660f8f93  # addi t6, t6, 1632
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x896ae337  # lui t1, 0x896ae
.4byte 0xc1d30313  # addi t1, t1, -995
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e9e9fb7  # lui t6, 0x5e9e9
.4byte 0x120f8f93  # addi t6, t6, 288
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643c23  # sd t1, 24(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02643023  # sd t1, 32(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02643823  # sd t1, 48(s0)
.4byte 0x01800e93  # addi t4, zero, 24
.4byte 0x29d47407  # vlsseg2e64.v v8, (s0), t4, v0.t
.assert trap == 0 "vlsseg2e64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 f0 lane 0 writes x10"
.assert rd_wdata == 0x5bf25d30aa6d0660 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 f0 lane 1 writes x10"
.assert rd_wdata == 0xaf78e62374b89f42 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 f0 lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 f1 lane 0 writes x10"
.assert rd_wdata == 0x6ef96233b57a0d71 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 f1 lane 1 writes x10"
.assert rd_wdata == 0xc27feb267fc5a653 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 f1 lane 1"
.4byte 0x61b91337  # lui t1, 0x61b91
.4byte 0x20830313  # addi t1, t1, 520
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x12490fb7  # lui t6, 0x12490
.4byte 0x198f8f93  # addi t6, t6, 408
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x29d4f427  # vssseg2e64.v v8, (s1), t4, v0.t
.assert trap == 0 "vssseg2e64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 0 writes x10"
.assert rd_wdata == 0x61b9120812490198 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 8 writes x10"
.assert rd_wdata == 0x74c0170b1d5608a9 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 8"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 24 writes x10"
.assert rd_wdata == 0xaf78e62374b89f42 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 24"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 32 writes x10"
.assert rd_wdata == 0xc27feb267fc5a653 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 32"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 16 writes x10"
.assert rd_wdata == 0xadd526143e7d1ddc "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 16"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 48 writes x10"
.assert rd_wdata == 0xc0dc2b17498a24ed "vlsseg2e64 m1 vl=2 stride=24 mask=0b10 store off 48"

# Negative-stride segment transfer walking downward in cached DDR.
.4byte 0x04040913  # addi s2, s0, 64
.4byte 0x04048993  # addi s3, s1, 64

# Strided segment vlsseg3e32 neg-stride under tu, mu.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5c351337  # lui t1, 0x5c351
.4byte 0x33930313  # addi t1, t1, 825
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0xc30fd337  # lui t1, 0xc30fd
.4byte 0x45930313  # addi t1, t1, 1113
.4byte 0x00692023  # sw t1, 0(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00692223  # sw t1, 4(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00692423  # sw t1, 8(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0xfe692823  # sw t1, -16(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0xfe692a23  # sw t1, -12(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0xfe692c23  # sw t1, -8(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0xfe692023  # sw t1, -32(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0xfe692223  # sw t1, -28(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0xfe692423  # sw t1, -24(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0xfe692e23  # sw t1, -4(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0xfc692823  # sw t1, -48(s2)
.4byte 0xff000e93  # addi t4, zero, -16
.4byte 0x4bd96407  # vlsseg3e32.v v8, (s2), t4
.assert trap == 0 "vlsseg3e32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg3e32 neg-stride f0 lane 0 writes x10"
.assert rd_wdata == 0xffffffffc30fd459 "vlsseg3e32 neg-stride f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 neg-stride f0 lane 1 writes x10"
.assert rd_wdata == 0xffffffffc30feb78 "vlsseg3e32 neg-stride f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 neg-stride f0 lane 2 writes x10"
.assert rd_wdata == 0xffffffffc3100297 "vlsseg3e32 neg-stride f0 lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 neg-stride f0 tail lane 3 writes x10"
.assert rd_wdata == 0x5c351339 "vlsseg3e32 neg-stride f0 tail lane 3"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg3e32 neg-stride f1 lane 0 writes x10"
.assert rd_wdata == 0xffffffffc30fdc0e "vlsseg3e32 neg-stride f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 neg-stride f1 lane 1 writes x10"
.assert rd_wdata == 0xffffffffc30ff32d "vlsseg3e32 neg-stride f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 neg-stride f1 lane 2 writes x10"
.assert rd_wdata == 0xffffffffc3100a4c "vlsseg3e32 neg-stride f1 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 neg-stride f1 tail lane 3 writes x10"
.assert rd_wdata == 0x5c35135e "vlsseg3e32 neg-stride f1 tail lane 3"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlsseg3e32 neg-stride f2 lane 0 writes x10"
.assert rd_wdata == 0xffffffffc30fe3c3 "vlsseg3e32 neg-stride f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 neg-stride f2 lane 1 writes x10"
.assert rd_wdata == 0xffffffffc30ffae2 "vlsseg3e32 neg-stride f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 neg-stride f2 lane 2 writes x10"
.assert rd_wdata == 0xffffffffc3101201 "vlsseg3e32 neg-stride f2 lane 2"
.4byte 0x3ea1ba57  # vslidedown.vi v20, v10, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg3e32 neg-stride f2 tail lane 3 writes x10"
.assert rd_wdata == 0x5c351383 "vlsseg3e32 neg-stride f2 tail lane 3"
.4byte 0x62b90337  # lui t1, 0x62b90
.4byte 0x27130313  # addi t1, t1, 625
.4byte 0x0069a023  # sw t1, 0(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0069a223  # sw t1, 4(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0069a423  # sw t1, 8(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0xfe69a823  # sw t1, -16(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0xfe69aa23  # sw t1, -12(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0xfe69ac23  # sw t1, -8(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0xfe69a023  # sw t1, -32(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0xfe69a223  # sw t1, -28(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0xfe69a423  # sw t1, -24(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0xfe69ae23  # sw t1, -4(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0xfc69a823  # sw t1, -48(s3)
.4byte 0x4bd9e427  # vssseg3e32.v v8, (s3), t4
.assert trap == 0 "vssseg3e32.v retires"
.4byte 0x0009e503  # lwu a0, 0(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off 0 writes x10"
.assert rd_wdata == 0xc30fd459 "vlsseg3e32 neg-stride store off 0"
.4byte 0x0049e503  # lwu a0, 4(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off 4 writes x10"
.assert rd_wdata == 0xc30fdc0e "vlsseg3e32 neg-stride store off 4"
.4byte 0x0089e503  # lwu a0, 8(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off 8 writes x10"
.assert rd_wdata == 0xc30fe3c3 "vlsseg3e32 neg-stride store off 8"
.4byte 0xff09e503  # lwu a0, -16(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off -16 writes x10"
.assert rd_wdata == 0xc30feb78 "vlsseg3e32 neg-stride store off -16"
.4byte 0xff49e503  # lwu a0, -12(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off -12 writes x10"
.assert rd_wdata == 0xc30ff32d "vlsseg3e32 neg-stride store off -12"
.4byte 0xff89e503  # lwu a0, -8(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off -8 writes x10"
.assert rd_wdata == 0xc30ffae2 "vlsseg3e32 neg-stride store off -8"
.4byte 0xfe09e503  # lwu a0, -32(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off -32 writes x10"
.assert rd_wdata == 0xc3100297 "vlsseg3e32 neg-stride store off -32"
.4byte 0xfe49e503  # lwu a0, -28(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off -28 writes x10"
.assert rd_wdata == 0xc3100a4c "vlsseg3e32 neg-stride store off -28"
.4byte 0xfe89e503  # lwu a0, -24(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off -24 writes x10"
.assert rd_wdata == 0xc3101201 "vlsseg3e32 neg-stride store off -24"
.4byte 0xffc9e503  # lwu a0, -4(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off -4 writes x10"
.assert rd_wdata == 0x62b90340 "vlsseg3e32 neg-stride store off -4"
.4byte 0xfd09e503  # lwu a0, -48(s3)
.assert rd_addr == 10 "vlsseg3e32 neg-stride store off -48 writes x10"
.assert rd_wdata == 0x62b90357 "vlsseg3e32 neg-stride store off -48"

# Strided segment vlsseg2e32 zero-stride(x0) under tu, mu.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5c481337  # lui t1, 0x5c481
.4byte 0x35a30313  # addi t1, t1, 858
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0xca22e337  # lui t1, 0xca22e
.4byte 0x96230313  # addi t1, t1, -1694
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x2a046407  # vlsseg2e32.v v8, (s0), zero
.assert trap == 0 "vlsseg2e32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg2e32 zero-stride(x0) f0 lane 0 writes x10"
.assert rd_wdata == 0xffffffffca22d962 "vlsseg2e32 zero-stride(x0) f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 zero-stride(x0) f0 lane 1 writes x10"
.assert rd_wdata == 0xffffffffca22d962 "vlsseg2e32 zero-stride(x0) f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 zero-stride(x0) f0 tail lane 2 writes x10"
.assert rd_wdata == 0x5c48135a "vlsseg2e32 zero-stride(x0) f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg2e32 zero-stride(x0) f1 lane 0 writes x10"
.assert rd_wdata == 0xffffffffca22e117 "vlsseg2e32 zero-stride(x0) f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 zero-stride(x0) f1 lane 1 writes x10"
.assert rd_wdata == 0xffffffffca22e117 "vlsseg2e32 zero-stride(x0) f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 zero-stride(x0) f1 tail lane 2 writes x10"
.assert rd_wdata == 0x5c48137f "vlsseg2e32 zero-stride(x0) f1 tail lane 2"
.4byte 0x62ca0337  # lui t1, 0x62ca0
.4byte 0x28a30313  # addi t1, t1, 650
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x2a04e427  # vssseg2e32.v v8, (s1), zero
.assert trap == 0 "vssseg2e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vlsseg2e32 zero-stride(x0) store off 0 writes x10"
.assert rd_wdata == 0xca22d962 "vlsseg2e32 zero-stride(x0) store off 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vlsseg2e32 zero-stride(x0) store off 4 writes x10"
.assert rd_wdata == 0xca22e117 "vlsseg2e32 zero-stride(x0) store off 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "vlsseg2e32 zero-stride(x0) store off 8 writes x10"
.assert rd_wdata == 0x62ca02b8 "vlsseg2e32 zero-stride(x0) store off 8"

# Strided segment vlsseg2e32 masked zero-stride(t4) under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5c5b1337  # lui t1, 0x5c5b1
.4byte 0x37b30313  # addi t1, t1, 891
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0xd135e337  # lui t1, 0xd135e
.4byte 0xe6b30313  # addi t1, t1, -405
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x00000e93  # addi t4, zero, 0
.4byte 0x29d46407  # vlsseg2e32.v v8, (s0), t4, v0.t
.assert trap == 0 "vlsseg2e32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg2e32 masked zero-stride(t4) f0 lane 0 writes x10"
.assert rd_wdata == 0x5c5b137b "vlsseg2e32 masked zero-stride(t4) f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 masked zero-stride(t4) f0 lane 1 writes x10"
.assert rd_wdata == 0xffffffffd135de6b "vlsseg2e32 masked zero-stride(t4) f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 masked zero-stride(t4) f0 tail lane 2 writes x10"
.assert rd_wdata == 0x5c5b137b "vlsseg2e32 masked zero-stride(t4) f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg2e32 masked zero-stride(t4) f1 lane 0 writes x10"
.assert rd_wdata == 0x5c5b13a0 "vlsseg2e32 masked zero-stride(t4) f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 masked zero-stride(t4) f1 lane 1 writes x10"
.assert rd_wdata == 0xffffffffd135e620 "vlsseg2e32 masked zero-stride(t4) f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "vlsseg2e32 masked zero-stride(t4) f1 tail lane 2 writes x10"
.assert rd_wdata == 0x5c5b13a0 "vlsseg2e32 masked zero-stride(t4) f1 tail lane 2"
.4byte 0x62db0337  # lui t1, 0x62db0
.4byte 0x2a330313  # addi t1, t1, 675
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x29d4e427  # vssseg2e32.v v8, (s1), t4, v0.t
.assert trap == 0 "vssseg2e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vlsseg2e32 masked zero-stride(t4) store off 0 writes x10"
.assert rd_wdata == 0xd135de6b "vlsseg2e32 masked zero-stride(t4) store off 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vlsseg2e32 masked zero-stride(t4) store off 4 writes x10"
.assert rd_wdata == 0xd135e620 "vlsseg2e32 masked zero-stride(t4) store off 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "vlsseg2e32 masked zero-stride(t4) store off 8 writes x10"
.assert rd_wdata == 0x62db02d1 "vlsseg2e32 masked zero-stride(t4) store off 8"

# Unit-stride segment EEW 16 with SEW 32 and LMUL 1 (EMUL=1/2).
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0xcafec337  # lui t1, 0xcafec
.4byte 0xabe30313  # addi t1, t1, -1346
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xdeadc337  # lui t1, 0xdeadc
.4byte 0xeef30313  # addi t1, t1, -273
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x35730313  # addi t1, t1, 855
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0xace30313  # addi t1, t1, -1330
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0xdf030313  # addi t1, t1, -528
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x22045407  # vlseg2e16.v v8, (s0)
.assert trap == 0 "vlseg2e16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "EMUL=1/2 seg f0 packed halfwords writes x10"
.assert rd_wdata == 0xffffffff9ace1357 "EMUL=1/2 seg f0 packed halfwords"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "EMUL=1/2 seg f0 tail word writes x10"
.assert rd_wdata == 0xffffffffcafebabe "EMUL=1/2 seg f0 tail word"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "EMUL=1/2 seg f1 packed halfwords writes x10"
.assert rd_wdata == 0xffffffffbdf02468 "EMUL=1/2 seg f1 packed halfwords"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "EMUL=1/2 seg f1 tail word writes x10"
.assert rd_wdata == 0xffffffffdeadbeef "EMUL=1/2 seg f1 tail word"
.4byte 0x0000d337  # lui t1, 0xd
.4byte 0x10030313  # addi t1, t1, 256
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x00649423  # sh t1, 8(s1)
.4byte 0x2204d427  # vsseg2e16.v v8, (s1)
.assert trap == 0 "vsseg2e16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "EMUL=1/2 seg store off 0 writes x10"
.assert rd_wdata == 0x1357 "EMUL=1/2 seg store off 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "EMUL=1/2 seg store off 2 writes x10"
.assert rd_wdata == 0x2468 "EMUL=1/2 seg store off 2"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "EMUL=1/2 seg store off 4 writes x10"
.assert rd_wdata == 0x9ace "EMUL=1/2 seg store off 4"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "EMUL=1/2 seg store off 6 writes x10"
.assert rd_wdata == 0xbdf0 "EMUL=1/2 seg store off 6"
.4byte 0x0084d503  # lhu a0, 8(s1)
.assert rd_addr == 10 "EMUL=1/2 seg store guard off 8 writes x10"
.assert rd_wdata == 0xd104 "EMUL=1/2 seg store guard off 8"

# Full-VLMAX unit-stride segment transfer (e64 m1, NF=2).
.4byte 0x18171337  # lui t1, 0x18171
.4byte 0x61530313  # addi t1, t1, 1557
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x14131fb7  # lui t6, 0x14131
.4byte 0x211f8f93  # addi t6, t6, 529
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00643423  # sd t1, 8(s0)
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
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0xa1a1a337  # lui t1, 0xa1a1a
.4byte 0x1a130313  # addi t1, t1, 417
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa1a1afb7  # lui t6, 0xa1a1a
.4byte 0x1a1f8f93  # addi t6, t6, 417
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x22047407  # vlseg2e64.v v8, (s0)
.assert trap == 0 "vlseg2e64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX vlseg2e64 f0 lane 0 writes x10"
.assert rd_wdata == 0x1817161514131211 "VLMAX vlseg2e64 f0 lane 0"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "VLMAX vlseg2e64 f1 lane 0 writes x10"
.assert rd_wdata == 0x2b1e1b181f201922 "VLMAX vlseg2e64 f1 lane 0"
.4byte 0x003e5393  # srli t2, t3, 3
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX vlseg2e64 f0 last lane writes x10"
.4byte 0x3e93ca57  # vslidedown.vx v20, v9, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX vlseg2e64 f1 last lane writes x10"
.4byte 0xf1f1f337  # lui t1, 0xf1f1f
.4byte 0x1f130313  # addi t1, t1, 497
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf1f1ffb7  # lui t6, 0xf1f1f
.4byte 0x1f1f8f93  # addi t6, t6, 497
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x0264b023  # sd t1, 32(s1)
.4byte 0x0264b423  # sd t1, 40(s1)
.4byte 0x0264b823  # sd t1, 48(s1)
.4byte 0x0264bc23  # sd t1, 56(s1)
.4byte 0x0464b023  # sd t1, 64(s1)
.4byte 0x0464b423  # sd t1, 72(s1)
.4byte 0x0464b823  # sd t1, 80(s1)
.4byte 0x0464bc23  # sd t1, 88(s1)
.4byte 0x0664b023  # sd t1, 96(s1)
.4byte 0x0664b423  # sd t1, 104(s1)
.4byte 0x0664b823  # sd t1, 112(s1)
.4byte 0x0664bc23  # sd t1, 120(s1)
.4byte 0x0864b023  # sd t1, 128(s1)
.4byte 0x2204f427  # vsseg2e64.v v8, (s1)
.assert trap == 0 "vsseg2e64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 0 f0 writes x10"
.assert rd_wdata == 0x1817161514131211 "VLMAX vsseg2e64 seg 0 f0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 0 f1 writes x10"
.assert rd_wdata == 0x2b1e1b181f201922 "VLMAX vsseg2e64 seg 0 f1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 1 f0 writes x10"
.assert rd_wdata == 0x3e25201b2a2d2033 "VLMAX vsseg2e64 seg 1 f0"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 1 f1 writes x10"
.assert rd_wdata == 0x512c251e353a2744 "VLMAX vsseg2e64 seg 1 f1"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 2 f0 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 2 f1 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 3 f0 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 3 f1 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 4 f0 writes x10"
.4byte 0x0484b503  # ld a0, 72(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 4 f1 writes x10"
.4byte 0x0504b503  # ld a0, 80(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 5 f0 writes x10"
.4byte 0x0584b503  # ld a0, 88(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 5 f1 writes x10"
.4byte 0x0604b503  # ld a0, 96(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 6 f0 writes x10"
.4byte 0x0684b503  # ld a0, 104(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 6 f1 writes x10"
.4byte 0x0704b503  # ld a0, 112(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 7 f0 writes x10"
.4byte 0x0784b503  # ld a0, 120(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 seg 7 f1 writes x10"
.4byte 0x0804b503  # ld a0, 128(s1)
.assert rd_addr == 10 "VLMAX vsseg2e64 guard writes x10"
.assert rd_wdata == 0xf1f1f1f1f1f1f1f1 "VLMAX vsseg2e64 guard"

# Zero-length and all-masked-off segment transfers leave state intact.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x0badc337  # lui t1, 0xbadc
.4byte 0x0de30313  # addi t1, t1, 222
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x77777337  # lui t1, 0x77777
.4byte 0x77130313  # addi t1, t1, 1905
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x66666337  # lui t1, 0x66666
.4byte 0x66130313  # addi t1, t1, 1633
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x0 "e32 m1 active vector length"
.4byte 0x42046407  # vlseg3e32.v v8, (s0)
.assert trap == 0 "vlseg3e32.v retires"
.4byte 0x4204e427  # vsseg3e32.v v8, (s1)
.assert trap == 0 "vsseg3e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vl=0 vsseg3e32 intact off 0 writes x10"
.assert rd_wdata == 0x66666661 "vl=0 vsseg3e32 intact off 0"
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x4bd46407  # vlsseg3e32.v v8, (s0), t4
.assert trap == 0 "vlsseg3e32.v retires"
.4byte 0x4bd4e427  # vssseg3e32.v v8, (s1), t4
.assert trap == 0 "vssseg3e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vl=0 vssseg3e32 intact off 0 writes x10"
.assert rd_wdata == 0x66666661 "vl=0 vssseg3e32 intact off 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x1 "e32 m1 active vector length"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl=0 seg f0 intact writes x10"
.assert rd_wdata == 0xbadc0de "vl=0 seg f0 intact"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vl=0 seg f1 intact writes x10"
.assert rd_wdata == 0xbadc0df "vl=0 seg f1 intact"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vl=0 seg f2 intact writes x10"
.assert rd_wdata == 0xbadc0e0 "vl=0 seg f2 intact"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x0feee337  # lui t1, 0xfeee
.4byte 0xac030313  # addi t1, t1, -1344
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x77770337  # lui t1, 0x77770
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x00642823  # sw t1, 16(s0)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x00642a23  # sw t1, 20(s0)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x00642c23  # sw t1, 24(s0)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x55550337  # lui t1, 0x55550
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064a823  # sw t1, 16(s1)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064aa23  # sw t1, 20(s1)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x40046407  # vlseg3e32.v v8, (s0), v0.t
.assert trap == 0 "vlseg3e32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "all-masked vlseg3e32 f0 lane 0 writes x10"
.assert rd_wdata == 0xfeedac0 "all-masked vlseg3e32 f0 lane 0"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "all-masked vlseg3e32 f1 lane 0 writes x10"
.assert rd_wdata == 0xfeedac1 "all-masked vlseg3e32 f1 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "all-masked vlseg3e32 f2 lane 1 writes x10"
.assert rd_wdata == 0xfeedac2 "all-masked vlseg3e32 f2 lane 1"
.4byte 0x4004e427  # vsseg3e32.v v8, (s1), v0.t
.assert trap == 0 "vsseg3e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "all-masked vsseg3e32 off 0 writes x10"
.assert rd_wdata == 0x55550000 "all-masked vsseg3e32 off 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "all-masked vsseg3e32 off 4 writes x10"
.assert rd_wdata == 0x55550004 "all-masked vsseg3e32 off 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "all-masked vsseg3e32 off 8 writes x10"
.assert rd_wdata == 0x55550008 "all-masked vsseg3e32 off 8"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "all-masked vsseg3e32 off 12 writes x10"
.assert rd_wdata == 0x5555000c "all-masked vsseg3e32 off 12"
.4byte 0x0104e503  # lwu a0, 16(s1)
.assert rd_addr == 10 "all-masked vsseg3e32 off 16 writes x10"
.assert rd_wdata == 0x55550010 "all-masked vsseg3e32 off 16"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "all-masked vsseg3e32 off 20 writes x10"
.assert rd_wdata == 0x55550014 "all-masked vsseg3e32 off 20"
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x49d46407  # vlsseg3e32.v v8, (s0), t4, v0.t
.assert trap == 0 "vlsseg3e32.v retires"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "all-masked vlsseg3e32 f0 lane 1 writes x10"
.assert rd_wdata == 0xfeedac0 "all-masked vlsseg3e32 f0 lane 1"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "all-masked vlsseg3e32 f2 lane 0 writes x10"
.assert rd_wdata == 0xfeedac2 "all-masked vlsseg3e32 f2 lane 0"
.4byte 0x49d4e427  # vssseg3e32.v v8, (s1), t4, v0.t
.assert trap == 0 "vssseg3e32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "all-masked vssseg3e32 off 0 writes x10"
.assert rd_wdata == 0x55550000 "all-masked vssseg3e32 off 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "all-masked vssseg3e32 off 4 writes x10"
.assert rd_wdata == 0x55550004 "all-masked vssseg3e32 off 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "all-masked vssseg3e32 off 8 writes x10"
.assert rd_wdata == 0x55550008 "all-masked vssseg3e32 off 8"
.4byte 0x0104e503  # lwu a0, 16(s1)
.assert rd_addr == 10 "all-masked vssseg3e32 off 16 writes x10"
.assert rd_wdata == 0x55550010 "all-masked vssseg3e32 off 16"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "all-masked vssseg3e32 off 20 writes x10"
.assert rd_wdata == 0x55550014 "all-masked vssseg3e32 off 20"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "all-masked vssseg3e32 off 24 writes x10"
.assert rd_wdata == 0x55550018 "all-masked vssseg3e32 off 24"

# Cached DDR segment transfers crossing a 4 KiB page boundary inside segment 0.
.4byte 0x00000913  # addi s2, zero, 0
.4byte 0x02091913  # slli s2, s2, 32
.4byte 0x80012fb7  # lui t6, 0x80012
.4byte 0xff8f8f93  # addi t6, t6, -8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f96933  # or s2, s2, t6
.4byte 0x00000993  # addi s3, zero, 0
.4byte 0x02099993  # slli s3, s3, 32
.4byte 0x80013fb7  # lui t6, 0x80013
.4byte 0xff8f8f93  # addi t6, t6, -8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f9e9b3  # or s3, s3, t6

# Unit-stride segment page-crossing vlseg4e32 under tu, mu.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5cf31337  # lui t1, 0x5cf31
.4byte 0x48330313  # addi t1, t1, 1155
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e0345d7  # vmv.v.x v11, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x09ce0337  # lui t1, 0x9ce0
.4byte 0x6b330313  # addi t1, t1, 1715
.4byte 0x00692023  # sw t1, 0(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00692223  # sw t1, 4(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00692423  # sw t1, 8(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00692623  # sw t1, 12(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00692823  # sw t1, 16(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00692a23  # sw t1, 20(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00692c23  # sw t1, 24(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x00692e23  # sw t1, 28(s2)
.4byte 0x7b530313  # addi t1, t1, 1973
.4byte 0x02692023  # sw t1, 32(s2)
.4byte 0x62096407  # vlseg4e32.v v8, (s2)
.assert trap == 0 "vlseg4e32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "page-crossing vlseg4e32 f0 lane 0 writes x10"
.assert rd_wdata == 0x9ce06b3 "page-crossing vlseg4e32 f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlseg4e32 f0 lane 1 writes x10"
.assert rd_wdata == 0x9ce2587 "page-crossing vlseg4e32 f0 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlseg4e32 f0 tail lane 2 writes x10"
.assert rd_wdata == 0x5cf31483 "page-crossing vlseg4e32 f0 tail lane 2"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "page-crossing vlseg4e32 f1 lane 0 writes x10"
.assert rd_wdata == 0x9ce0e68 "page-crossing vlseg4e32 f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlseg4e32 f1 lane 1 writes x10"
.assert rd_wdata == 0x9ce2d3c "page-crossing vlseg4e32 f1 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlseg4e32 f1 tail lane 2 writes x10"
.assert rd_wdata == 0x5cf314a8 "page-crossing vlseg4e32 f1 tail lane 2"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "page-crossing vlseg4e32 f2 lane 0 writes x10"
.assert rd_wdata == 0x9ce161d "page-crossing vlseg4e32 f2 lane 0"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlseg4e32 f2 lane 1 writes x10"
.assert rd_wdata == 0x9ce34f1 "page-crossing vlseg4e32 f2 lane 1"
.4byte 0x3ea13a57  # vslidedown.vi v20, v10, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlseg4e32 f2 tail lane 2 writes x10"
.assert rd_wdata == 0x5cf314cd "page-crossing vlseg4e32 f2 tail lane 2"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "page-crossing vlseg4e32 f3 lane 0 writes x10"
.assert rd_wdata == 0x9ce1dd2 "page-crossing vlseg4e32 f3 lane 0"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlseg4e32 f3 lane 1 writes x10"
.assert rd_wdata == 0x9ce3ca6 "page-crossing vlseg4e32 f3 lane 1"
.4byte 0x3eb13a57  # vslidedown.vi v20, v11, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlseg4e32 f3 tail lane 2 writes x10"
.assert rd_wdata == 0x5cf314f2 "page-crossing vlseg4e32 f3 tail lane 2"
.4byte 0x63630337  # lui t1, 0x63630
.4byte 0x36b30313  # addi t1, t1, 875
.4byte 0x0069a023  # sw t1, 0(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0069a223  # sw t1, 4(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0069a423  # sw t1, 8(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0069a623  # sw t1, 12(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0069a823  # sw t1, 16(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0069aa23  # sw t1, 20(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0069ac23  # sw t1, 24(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0069ae23  # sw t1, 28(s3)
.4byte 0x01730313  # addi t1, t1, 23
.4byte 0x0269a023  # sw t1, 32(s3)
.4byte 0x6209e427  # vsseg4e32.v v8, (s3)
.assert trap == 0 "vsseg4e32.v retires"
.4byte 0x0009e503  # lwu a0, 0(s3)
.assert rd_addr == 10 "page-crossing vlseg4e32 store off 0 writes x10"
.assert rd_wdata == 0x9ce06b3 "page-crossing vlseg4e32 store off 0"
.4byte 0x0049e503  # lwu a0, 4(s3)
.assert rd_addr == 10 "page-crossing vlseg4e32 store off 4 writes x10"
.assert rd_wdata == 0x9ce0e68 "page-crossing vlseg4e32 store off 4"
.4byte 0x0089e503  # lwu a0, 8(s3)
.assert rd_addr == 10 "page-crossing vlseg4e32 store off 8 writes x10"
.assert rd_wdata == 0x9ce161d "page-crossing vlseg4e32 store off 8"
.4byte 0x00c9e503  # lwu a0, 12(s3)
.assert rd_addr == 10 "page-crossing vlseg4e32 store off 12 writes x10"
.assert rd_wdata == 0x9ce1dd2 "page-crossing vlseg4e32 store off 12"
.4byte 0x0109e503  # lwu a0, 16(s3)
.assert rd_addr == 10 "page-crossing vlseg4e32 store off 16 writes x10"
.assert rd_wdata == 0x9ce2587 "page-crossing vlseg4e32 store off 16"
.4byte 0x0149e503  # lwu a0, 20(s3)
.assert rd_addr == 10 "page-crossing vlseg4e32 store off 20 writes x10"
.assert rd_wdata == 0x9ce2d3c "page-crossing vlseg4e32 store off 20"
.4byte 0x0189e503  # lwu a0, 24(s3)
.assert rd_addr == 10 "page-crossing vlseg4e32 store off 24 writes x10"
.assert rd_wdata == 0x9ce34f1 "page-crossing vlseg4e32 store off 24"
.4byte 0x01c9e503  # lwu a0, 28(s3)
.assert rd_addr == 10 "page-crossing vlseg4e32 store off 28 writes x10"
.assert rd_wdata == 0x9ce3ca6 "page-crossing vlseg4e32 store off 28"
.4byte 0x0209e503  # lwu a0, 32(s3)
.assert rd_addr == 10 "page-crossing vlseg4e32 store guard off 32 writes x10"
.assert rd_wdata == 0x63630423 "page-crossing vlseg4e32 store guard off 32"

# Strided segment page-crossing vlsseg2e64 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5cbe6337  # lui t1, 0x5cbe6
.4byte 0xec830313  # addi t1, t1, -312
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xacd11fb7  # lui t6, 0xacd11
.4byte 0x990f8f93  # addi t6, t6, -1648
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0xc58f3337  # lui t1, 0xc58f3
.4byte 0x08930313  # addi t1, t1, 137
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xe33aafb7  # lui t6, 0xe33aa
.4byte 0xdecf8f93  # addi t6, t6, -532
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693023  # sd t1, 0(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00693423  # sd t1, 8(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00693c23  # sd t1, 24(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02693023  # sd t1, 32(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x00693823  # sd t1, 16(s2)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x02693823  # sd t1, 48(s2)
.4byte 0x01800e93  # addi t4, zero, 24
.4byte 0x2bd97407  # vlsseg2e64.v v8, (s2), t4
.assert trap == 0 "vlsseg2e64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "page-crossing vlsseg2e64 f0 lane 0 writes x10"
.assert rd_wdata == 0xc58f3089e33a9dec "page-crossing vlsseg2e64 f0 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlsseg2e64 f0 lane 1 writes x10"
.assert rd_wdata == 0xeb9d3a8ff954ac0e "page-crossing vlsseg2e64 f0 lane 1"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "page-crossing vlsseg2e64 f1 lane 0 writes x10"
.assert rd_wdata == 0xd896358cee47a4fd "page-crossing vlsseg2e64 f1 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing vlsseg2e64 f1 lane 1 writes x10"
.assert rd_wdata == 0xfea43f930461b31f "page-crossing vlsseg2e64 f1 lane 1"
.4byte 0x620d1337  # lui t1, 0x620d1
.4byte 0x28c30313  # addi t1, t1, 652
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x12e50fb7  # lui t6, 0x12e50
.4byte 0x264f8f93  # addi t6, t6, 612
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b023  # sd t1, 0(s3)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0069b423  # sd t1, 8(s3)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0069bc23  # sd t1, 24(s3)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0269b023  # sd t1, 32(s3)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0069b823  # sd t1, 16(s3)
.4byte 0x01e30333  # add t1, t1, t5
.4byte 0x0269b823  # sd t1, 48(s3)
.4byte 0x2bd9f427  # vssseg2e64.v v8, (s3), t4
.assert trap == 0 "vssseg2e64.v retires"
.4byte 0x0009b503  # ld a0, 0(s3)
.assert rd_addr == 10 "page-crossing vlsseg2e64 store off 0 writes x10"
.assert rd_wdata == 0xc58f3089e33a9dec "page-crossing vlsseg2e64 store off 0"
.4byte 0x0089b503  # ld a0, 8(s3)
.assert rd_addr == 10 "page-crossing vlsseg2e64 store off 8 writes x10"
.assert rd_wdata == 0xd896358cee47a4fd "page-crossing vlsseg2e64 store off 8"
.4byte 0x0189b503  # ld a0, 24(s3)
.assert rd_addr == 10 "page-crossing vlsseg2e64 store off 24 writes x10"
.assert rd_wdata == 0xeb9d3a8ff954ac0e "page-crossing vlsseg2e64 store off 24"
.4byte 0x0209b503  # ld a0, 32(s3)
.assert rd_addr == 10 "page-crossing vlsseg2e64 store off 32 writes x10"
.assert rd_wdata == 0xfea43f930461b31f "page-crossing vlsseg2e64 store off 32"
.4byte 0x0109b503  # ld a0, 16(s3)
.assert rd_addr == 10 "page-crossing vlsseg2e64 store off 16 writes x10"
.assert rd_wdata == 0xae2926983f191ea8 "page-crossing vlsseg2e64 store off 16"
.4byte 0x0309b503  # ld a0, 48(s3)
.assert rd_addr == 10 "page-crossing vlsseg2e64 store off 48 writes x10"
.assert rd_wdata == 0xc1302b9b4a2625b9 "page-crossing vlsseg2e64 store off 48"
