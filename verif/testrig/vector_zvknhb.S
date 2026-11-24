# Vector Zvknhb (vsha2ms.vv, vsha2cl.vv, vsha2ch.vv) at SEW=32 (SHA-256) and SEW=64 (SHA-512).
# Covers FIPS-180-4 vectors, multi-group m2/m4, vstart=4 restart, tails, VLMAX, and EGS=4 traps.
.noshrink
# Preamble: enable VS, zero v0..v31, clear vstart and mcause.
.4byte 0x000062b7  # lui x5, 0x6
.4byte 0x60028293  # addi x5, x5, 1536
.4byte 0x3002a073  # csrs mstatus, x5
.4byte 0x00805073  # csrwi vstart, 0
.4byte 0x34201073  # csrw mcause, x0
.4byte 0x01b07fd7  # vsetvli x31, x0, e64, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0

# Section 1: Zvknhb SEW=32 (SHA-256), control vsha2ms.vv on v4 (0x42402557), CL/CH/MS.
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli e32 m1 vl=4 writes x12"
.assert rd_wdata == 0x4 "vsetivli e32 m1 vl=4"
.4byte 0xa55a12b7  # lui x5, 0xa55a1
.4byte 0xf1e28293  # addi x5, x5, -226
.4byte 0x5e02c257  # vmv.v.x v4, x5
.4byte 0x9abce2b7  # lui x5, 0x9abce
.4byte 0xef028293  # addi x5, x5, -272
.4byte 0x3a42ee57  # vslide1up.vx v28, v4, x5
.4byte 0x5e0e0257  # vmv.v.v v4, v28
.4byte 0x123452b7  # lui x5, 0x12345
.4byte 0x67828293  # addi x5, x5, 1656
.4byte 0x3a42ee57  # vslide1up.vx v28, v4, x5
.4byte 0x5e0e0257  # vmv.v.v v4, v28
.4byte 0x616262b7  # lui x5, 0x61626
.4byte 0x38028293  # addi x5, x5, 896
.4byte 0x3a42ee57  # vslide1up.vx v28, v4, x5
.4byte 0x5e0e0257  # vmv.v.v v4, v28
.4byte 0x99aac2b7  # lui x5, 0x99aac
.4byte 0xbcc28293  # addi x5, x5, -1076
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x556672b7  # lui x5, 0x55667
.4byte 0x78828293  # addi x5, x5, 1928
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x112232b7  # lui x5, 0x11223
.4byte 0x34428293  # addi x5, x5, 836
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x55aa32b7  # lui x5, 0x55aa3
.4byte 0x3cc28293  # addi x5, x5, 972
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x01800293  # addi x5, x0, 24
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0xdead12b7  # lui x5, 0xdead1
.4byte 0x0cc28293  # addi x5, x5, 204
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xcafec2b7  # lui x5, 0xcafec
.4byte 0xabe28293  # addi x5, x5, -1346
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x010202b7  # lui x5, 0x1020
.4byte 0x30428293  # addi x5, x5, 772
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xb6862277  # vsha2ms.vv v4, v8, v12
.assert trap == 0 "control vsha2ms.vv e32 retires"
.4byte 0x42402557  # vmv.x.s x10, v4
.assert rd_addr == 10 "control vsha2ms.vv e32 w0 writes x10"
.assert rd_wdata == 0xffffffff84c9dd79 "control vsha2ms.vv e32 w0"
.4byte 0x3e40bc57  # vslidedown.vi v24, v4, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vsha2ms.vv e32 w1 writes x10"
.assert rd_wdata == 0x2d8892cc "control vsha2ms.vv e32 w1"
.4byte 0x3e413c57  # vslidedown.vi v24, v4, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vsha2ms.vv e32 w2 writes x10"
.assert rd_wdata == 0xffffffffb3c0b7f1 "control vsha2ms.vv e32 w2"
.4byte 0x3e41bc57  # vslidedown.vi v24, v4, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vsha2ms.vv e32 w3 writes x10"
.assert rd_wdata == 0x207e0ae7 "control vsha2ms.vv e32 w3"
.4byte 0x3c6ef2b7  # lui x5, 0x3c6ef
.4byte 0x37228293  # addi x5, x5, 882
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xa54ff2b7  # lui x5, 0xa54ff
.4byte 0x53a28293  # addi x5, x5, 1338
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1f83e2b7  # lui x5, 0x1f83e
.4byte 0x9ab28293  # addi x5, x5, -1621
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5be0d2b7  # lui x5, 0x5be0d
.4byte 0xd1928293  # addi x5, x5, -743
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x6a09e2b7  # lui x5, 0x6a09e
.4byte 0x66728293  # addi x5, x5, 1639
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0xbb67b2b7  # lui x5, 0xbb67b
.4byte 0xe8528293  # addi x5, x5, -379
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x510e52b7  # lui x5, 0x510e5
.4byte 0x27f28293  # addi x5, x5, 639
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x9b0572b7  # lui x5, 0x9b057
.4byte 0x88c28293  # addi x5, x5, -1908
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xe9b5e2b7  # lui x5, 0xe9b5e
.4byte 0xba528293  # addi x5, x5, -1115
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0xb5c102b7  # lui x5, 0xb5c10
.4byte 0xbcf28293  # addi x5, x5, -1073
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x713742b7  # lui x5, 0x71374
.4byte 0x49128293  # addi x5, x5, 1169
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xa3ec92b7  # lui x5, 0xa3ec9
.4byte 0x31828293  # addi x5, x5, 792
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xbf462877  # vsha2cl.vv v16, v20, v12
.assert trap == 0 "vsha2cl.vv e32 q0 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2cl.vv e32 q0 w0 writes x10"
.assert rd_wdata == 0xfffffffffa2a4622 "vsha2cl.vv e32 q0 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 q0 w1 writes x10"
.assert rd_wdata == 0x78ce7989 "vsha2cl.vv e32 q0 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 q0 w2 writes x10"
.assert rd_wdata == 0x5d6aebcd "vsha2cl.vv e32 q0 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 q0 w3 writes x10"
.assert rd_wdata == 0x5a6ad9ad "vsha2cl.vv e32 q0 w3"
.4byte 0xbb062a77  # vsha2ch.vv v20, v16, v12
.assert trap == 0 "vsha2ch.vv e32 q0 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vsha2ch.vv e32 q0 w0 writes x10"
.assert rd_wdata == 0xfffffffff92939eb "vsha2ch.vv e32 q0 w0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 q0 w1 writes x10"
.assert rd_wdata == 0x24e00850 "vsha2ch.vv e32 q0 w1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 q0 w2 writes x10"
.assert rd_wdata == 0xffffffffc8c347a7 "vsha2ch.vv e32 q0 w2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 q0 w3 writes x10"
.assert rd_wdata == 0xffffffffd550f666 "vsha2ch.vv e32 q0 w3"
.4byte 0xab1c62b7  # lui x5, 0xab1c6
.4byte 0xed528293  # addi x5, x5, -299
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x923f82b7  # lui x5, 0x923f8
.4byte 0x2a428293  # addi x5, x5, 676
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x59f112b7  # lui x5, 0x59f11
.4byte 0x1f128293  # addi x5, x5, 497
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x3956c2b7  # lui x5, 0x3956c
.4byte 0x25b28293  # addi x5, x5, 603
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xbf462877  # vsha2cl.vv v16, v20, v12
.assert trap == 0 "vsha2cl.vv e32 q1 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2cl.vv e32 q1 w0 writes x10"
.assert rd_wdata == 0x43ada245 "vsha2cl.vv e32 q1 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 q1 w1 writes x10"
.assert rd_wdata == 0x714260ad "vsha2cl.vv e32 q1 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 q1 w2 writes x10"
.assert rd_wdata == 0x4409a6a "vsha2cl.vv e32 q1 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 q1 w3 writes x10"
.assert rd_wdata == 0x2b4209f5 "vsha2cl.vv e32 q1 w3"
.4byte 0xbb062a77  # vsha2ch.vv v20, v16, v12
.assert trap == 0 "vsha2ch.vv e32 q1 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vsha2ch.vv e32 q1 w0 writes x10"
.assert rd_wdata == 0xffffffff9b27a401 "vsha2ch.vv e32 q1 w0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 q1 w1 writes x10"
.assert rd_wdata == 0xc657a79 "vsha2ch.vv e32 q1 w1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 q1 w2 writes x10"
.assert rd_wdata == 0xffffffffe5030380 "vsha2ch.vv e32 q1 w2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 q1 w3 writes x10"
.assert rd_wdata == 0xffffffff85a07b5f "vsha2ch.vv e32 q1 w3"
# Multi-group e32 m2 vl=8, vstart=4 restart, tu tail, vl=0, portable VLMAX.
.4byte 0xc1147657  # vsetivli x12, 8, e32, m2, tu, mu
.4byte 0x5a6ae2b7  # lui x5, 0x5a6ae
.4byte 0x9ad28293  # addi x5, x5, -1619
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x5d6af2b7  # lui x5, 0x5d6af
.4byte 0xbcd28293  # addi x5, x5, -1075
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x78ce82b7  # lui x5, 0x78ce8
.4byte 0x98928293  # addi x5, x5, -1655
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xfa2a42b7  # lui x5, 0xfa2a4
.4byte 0x62228293  # addi x5, x5, 1570
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x3c6ef2b7  # lui x5, 0x3c6ef
.4byte 0x37228293  # addi x5, x5, 882
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa54ff2b7  # lui x5, 0xa54ff
.4byte 0x53a28293  # addi x5, x5, 1338
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1f83e2b7  # lui x5, 0x1f83e
.4byte 0x9ab28293  # addi x5, x5, -1621
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5be0d2b7  # lui x5, 0x5be0d
.4byte 0xd1928293  # addi x5, x5, -743
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xd550f2b7  # lui x5, 0xd550f
.4byte 0x66628293  # addi x5, x5, 1638
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0xc8c342b7  # lui x5, 0xc8c34
.4byte 0x7a728293  # addi x5, x5, 1959
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x24e012b7  # lui x5, 0x24e01
.4byte 0x85028293  # addi x5, x5, -1968
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xf92942b7  # lui x5, 0xf9294
.4byte 0x9eb28293  # addi x5, x5, -1557
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x6a09e2b7  # lui x5, 0x6a09e
.4byte 0x66728293  # addi x5, x5, 1639
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xbb67b2b7  # lui x5, 0xbb67b
.4byte 0xe8528293  # addi x5, x5, -379
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x510e52b7  # lui x5, 0x510e5
.4byte 0x27f28293  # addi x5, x5, 639
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x9b0572b7  # lui x5, 0x9b057
.4byte 0x88c28293  # addi x5, x5, -1908
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xab1c62b7  # lui x5, 0xab1c6
.4byte 0xed528293  # addi x5, x5, -299
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x923f82b7  # lui x5, 0x923f8
.4byte 0x2a428293  # addi x5, x5, 676
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x59f112b7  # lui x5, 0x59f11
.4byte 0x1f128293  # addi x5, x5, 497
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x3956c2b7  # lui x5, 0x3956c
.4byte 0x25b28293  # addi x5, x5, 603
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xe9b5e2b7  # lui x5, 0xe9b5e
.4byte 0xba528293  # addi x5, x5, -1115
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xb5c102b7  # lui x5, 0xb5c10
.4byte 0xbcf28293  # addi x5, x5, -1073
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x713742b7  # lui x5, 0x71374
.4byte 0x49128293  # addi x5, x5, 1169
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xa3ec92b7  # lui x5, 0xa3ec9
.4byte 0x31828293  # addi x5, x5, 792
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xbf462877  # vsha2cl.vv v16, v20, v12
.assert trap == 0 "vsha2cl.vv e32 m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2cl.vv e32 m2 w0 writes x10"
.assert rd_wdata == 0xfffffffffa2a4622 "vsha2cl.vv e32 m2 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 m2 w1 writes x10"
.assert rd_wdata == 0x78ce7989 "vsha2cl.vv e32 m2 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 m2 w2 writes x10"
.assert rd_wdata == 0x5d6aebcd "vsha2cl.vv e32 m2 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 m2 w3 writes x10"
.assert rd_wdata == 0x5a6ad9ad "vsha2cl.vv e32 m2 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 m2 w4 writes x10"
.assert rd_wdata == 0x43ada245 "vsha2cl.vv e32 m2 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 m2 w5 writes x10"
.assert rd_wdata == 0x714260ad "vsha2cl.vv e32 m2 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 m2 w6 writes x10"
.assert rd_wdata == 0x4409a6a "vsha2cl.vv e32 m2 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 m2 w7 writes x10"
.assert rd_wdata == 0x2b4209f5 "vsha2cl.vv e32 m2 w7"
.4byte 0x5a6ae2b7  # lui x5, 0x5a6ae
.4byte 0x9ad28293  # addi x5, x5, -1619
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x5d6af2b7  # lui x5, 0x5d6af
.4byte 0xbcd28293  # addi x5, x5, -1075
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x78ce82b7  # lui x5, 0x78ce8
.4byte 0x98928293  # addi x5, x5, -1655
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xfa2a42b7  # lui x5, 0xfa2a4
.4byte 0x62228293  # addi x5, x5, 1570
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x3c6ef2b7  # lui x5, 0x3c6ef
.4byte 0x37228293  # addi x5, x5, 882
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa54ff2b7  # lui x5, 0xa54ff
.4byte 0x53a28293  # addi x5, x5, 1338
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1f83e2b7  # lui x5, 0x1f83e
.4byte 0x9ab28293  # addi x5, x5, -1621
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5be0d2b7  # lui x5, 0x5be0d
.4byte 0xd1928293  # addi x5, x5, -743
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00825073  # csrwi vstart, 4
.4byte 0xbb462877  # vsha2ch.vv v16, v20, v12
.assert trap == 0 "vsha2ch.vv e32 m2 vstart=4 retires"
.4byte 0x00802573  # csrr x10, vstart
.assert rd_addr == 10 "vstart cleared after vsha2ch.vv e32 writes x10"
.assert rd_wdata == 0x0 "vstart cleared after vsha2ch.vv e32"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2ch.vv e32 vstart=4 w0 writes x10"
.assert rd_wdata == 0x5be0cd19 "vsha2ch.vv e32 vstart=4 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 vstart=4 w1 writes x10"
.assert rd_wdata == 0x1f83d9ab "vsha2ch.vv e32 vstart=4 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 vstart=4 w2 writes x10"
.assert rd_wdata == 0xffffffffa54ff53a "vsha2ch.vv e32 vstart=4 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 vstart=4 w3 writes x10"
.assert rd_wdata == 0x3c6ef372 "vsha2ch.vv e32 vstart=4 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 vstart=4 w4 writes x10"
.assert rd_wdata == 0xffffffff9c96628e "vsha2ch.vv e32 vstart=4 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 vstart=4 w5 writes x10"
.assert rd_wdata == 0x48f5774 "vsha2ch.vv e32 vstart=4 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 vstart=4 w6 writes x10"
.assert rd_wdata == 0x5d295ab3 "vsha2ch.vv e32 vstart=4 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e32 vstart=4 w7 writes x10"
.assert rd_wdata == 0x2f204700 "vsha2ch.vv e32 vstart=4 w7"
.4byte 0x5a6ae2b7  # lui x5, 0x5a6ae
.4byte 0x9ad28293  # addi x5, x5, -1619
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x5d6af2b7  # lui x5, 0x5d6af
.4byte 0xbcd28293  # addi x5, x5, -1075
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x78ce82b7  # lui x5, 0x78ce8
.4byte 0x98928293  # addi x5, x5, -1655
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xfa2a42b7  # lui x5, 0xfa2a4
.4byte 0x62228293  # addi x5, x5, 1570
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x3c6ef2b7  # lui x5, 0x3c6ef
.4byte 0x37228293  # addi x5, x5, 882
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa54ff2b7  # lui x5, 0xa54ff
.4byte 0x53a28293  # addi x5, x5, 1338
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1f83e2b7  # lui x5, 0x1f83e
.4byte 0x9ab28293  # addi x5, x5, -1621
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5be0d2b7  # lui x5, 0x5be0d
.4byte 0xd1928293  # addi x5, x5, -743
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0xbf462877  # vsha2cl.vv v16, v20, v12
.assert trap == 0 "vsha2cl.vv e32 tu vl=4 m2 retires"
.4byte 0xc1147657  # vsetivli x12, 8, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2cl.vv e32 tu tail w0 writes x10"
.assert rd_wdata == 0xfffffffffa2a4622 "vsha2cl.vv e32 tu tail w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 tu tail w1 writes x10"
.assert rd_wdata == 0x78ce7989 "vsha2cl.vv e32 tu tail w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 tu tail w2 writes x10"
.assert rd_wdata == 0x5d6aebcd "vsha2cl.vv e32 tu tail w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 tu tail w3 writes x10"
.assert rd_wdata == 0x5a6ad9ad "vsha2cl.vv e32 tu tail w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 tu tail w4 writes x10"
.assert rd_wdata == 0xfffffffffa2a4622 "vsha2cl.vv e32 tu tail w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 tu tail w5 writes x10"
.assert rd_wdata == 0x78ce7989 "vsha2cl.vv e32 tu tail w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 tu tail w6 writes x10"
.assert rd_wdata == 0x5d6aebcd "vsha2cl.vv e32 tu tail w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e32 tu tail w7 writes x10"
.assert rd_wdata == 0x5a6ad9ad "vsha2cl.vv e32 tu tail w7"
.4byte 0xcd007657  # vsetivli x12, 0, e32, m1, ta, ma
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 0 "vsha2ms.vv e32 m1 vl=0 retires"
.4byte 0xbf462877  # vsha2cl.vv v16, v20, v12
.assert trap == 0 "vsha2cl.vv e32 m1 vl=0 retires"
.4byte 0xbb462877  # vsha2ch.vv v16, v20, v12
.assert trap == 0 "vsha2ch.vv e32 m1 vl=0 retires"
.4byte 0x01007fd7  # vsetvli x31, x0, e32, m1, tu, mu
.4byte 0xb68c2877  # vsha2ms.vv v16, v8, v24
.assert trap == 0 "vsha2ms.vv e32 VLMAX m1 retires"
.4byte 0x01107fd7  # vsetvli x31, x0, e32, m2, tu, mu
.4byte 0xb68c2877  # vsha2ms.vv v16, v8, v24
.assert trap == 0 "vsha2ms.vv e32 VLMAX m2 retires"
.4byte 0x01207fd7  # vsetvli x31, x0, e32, m4, tu, mu
.4byte 0xb68c2877  # vsha2ms.vv v16, v8, v24
.assert trap == 0 "vsha2ms.vv e32 VLMAX m4 retires"
.4byte 0x01307fd7  # vsetvli x31, x0, e32, m8, tu, mu
.4byte 0xb68c2877  # vsha2ms.vv v16, v8, v24
.assert trap == 0 "vsha2ms.vv e32 VLMAX m8 retires"

# Section 2: Zvknhb SEW=64 (SHA-512) at e64 m2 (vl=4) & m4 (vl=8), vstart=4, tu, vl=0, VLMAX.
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.assert rd_addr == 12 "vsetivli e64 m2 vl=4 writes x12"
.assert rd_wdata == 0x4 "vsetivli e64 m2 vl=4"
.4byte 0xa55a12b7  # lui x5, 0xa55a1
.4byte 0xf1e28293  # addi x5, x5, -226
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x2d3c5337  # lui x6, 0x2d3c5
.4byte 0xb5a30313  # addi x6, x6, -1190
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x99aac2b7  # lui x5, 0x99aac
.4byte 0xbcc28293  # addi x5, x5, -1076
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xddef0337  # lui x6, 0xddef0
.4byte 0xf0130313  # addi x6, x6, -255
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x112232b7  # lui x5, 0x11223
.4byte 0x34428293  # addi x5, x5, 836
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x55667337  # lui x6, 0x55667
.4byte 0x78830313  # addi x6, x6, 1928
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x616262b7  # lui x5, 0x61626
.4byte 0x38028293  # addi x5, x5, 896
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x00100313  # addi x6, x0, 1
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x55aa52b7  # lui x5, 0x55aa5
.4byte 0x5aa28293  # addi x5, x5, 1450
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x33cc3337  # lui x6, 0x33cc3
.4byte 0x3cc30313  # addi x6, x6, 972
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xfedcc2b7  # lui x5, 0xfedcc
.4byte 0xa9828293  # addi x5, x5, -1384
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x76543337  # lui x6, 0x76543
.4byte 0x21030313  # addi x6, x6, 528
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x012342b7  # lui x5, 0x1234
.4byte 0x56728293  # addi x5, x5, 1383
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x89abd337  # lui x6, 0x89abd
.4byte 0xdef30313  # addi x6, x6, -529
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x01800293  # addi x5, x0, 24
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x123452b7  # lui x5, 0x12345
.4byte 0x67828293  # addi x5, x5, 1656
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x90abd337  # lui x6, 0x90abd
.4byte 0xdef30313  # addi x6, x6, -529
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x0f0f12b7  # lui x5, 0xf0f1
.4byte 0xf0f28293  # addi x5, x5, -241
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xf0f0f337  # lui x6, 0xf0f0f
.4byte 0x0f030313  # addi x6, x6, 240
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xcafec2b7  # lui x5, 0xcafec
.4byte 0xabe28293  # addi x5, x5, -1346
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xdeadc337  # lui x6, 0xdeadc
.4byte 0xeef30313  # addi x6, x6, -273
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 0 "vsha2ms.vv e64 m2 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2ms.vv e64 m2 w0 writes x10"
.assert rd_wdata == 0xc9391eec4a7495c6 "vsha2ms.vv e64 m2 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ms.vv e64 m2 w1 writes x10"
.assert rd_wdata == 0x334f2b18c4c3f895 "vsha2ms.vv e64 m2 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ms.vv e64 m2 w2 writes x10"
.assert rd_wdata == 0xfb426fa9d42955a1 "vsha2ms.vv e64 m2 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ms.vv e64 m2 w3 writes x10"
.assert rd_wdata == 0xc592535d18a8f8bd "vsha2ms.vv e64 m2 w3"
.4byte 0x3c6ef2b7  # lui x5, 0x3c6ef
.4byte 0x37228293  # addi x5, x5, 882
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xfe950337  # lui x6, 0xfe950
.4byte 0x82b30313  # addi x6, x6, -2005
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xa54ff2b7  # lui x5, 0xa54ff
.4byte 0x53a28293  # addi x5, x5, 1338
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x5f1d3337  # lui x6, 0x5f1d3
.4byte 0x6f130313  # addi x6, x6, 1777
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1f83e2b7  # lui x5, 0x1f83e
.4byte 0x9ab28293  # addi x5, x5, -1621
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xfb41c337  # lui x6, 0xfb41c
.4byte 0xd6b30313  # addi x6, x6, -661
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5be0d2b7  # lui x5, 0x5be0d
.4byte 0xd1928293  # addi x5, x5, -743
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x137e2337  # lui x6, 0x137e2
.4byte 0x17930313  # addi x6, x6, 377
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x6a09e2b7  # lui x5, 0x6a09e
.4byte 0x66728293  # addi x5, x5, 1639
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xf3bcd337  # lui x6, 0xf3bcd
.4byte 0x90830313  # addi x6, x6, -1784
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0xbb67b2b7  # lui x5, 0xbb67b
.4byte 0xe8528293  # addi x5, x5, -379
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x84caa337  # lui x6, 0x84caa
.4byte 0x73b30313  # addi x6, x6, 1851
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x510e52b7  # lui x5, 0x510e5
.4byte 0x27f28293  # addi x5, x5, 639
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xade68337  # lui x6, 0xade68
.4byte 0x2d130313  # addi x6, x6, 721
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x9b0572b7  # lui x5, 0x9b057
.4byte 0x88c28293  # addi x5, x5, -1908
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x2b3e7337  # lui x6, 0x2b3e7
.4byte 0xc1f30313  # addi x6, x6, -993
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x8f0ff2b7  # lui x5, 0x8f0ff
.4byte 0xac328293  # addi x5, x5, -1341
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xaec62337  # lui x6, 0xaec62
.4byte 0x71630313  # addi x6, x6, 1814
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0x4f6bb2b7  # lui x5, 0x4f6bb
.4byte 0x79c28293  # addi x5, x5, 1948
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xca3c4337  # lui x6, 0xca3c4
.4byte 0xa3030313  # addi x6, x6, -1488
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x825972b7  # lui x5, 0x82597
.4byte 0x7d528293  # addi x5, x5, 2005
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x7955e337  # lui x6, 0x7955e
.4byte 0xd5530313  # addi x6, x6, -683
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xa3ec92b7  # lui x5, 0xa3ec9
.4byte 0x31828293  # addi x5, x5, 792
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xd728b337  # lui x6, 0xd728b
.4byte 0xe2230313  # addi x6, x6, -478
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xbf462877  # vsha2cl.vv v16, v20, v12
.assert trap == 0 "vsha2cl.vv e64 m2 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2cl.vv e64 m2 w0 writes x10"
.assert rd_wdata == 0x58cb02347ab51f91 "vsha2cl.vv e64 m2 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m2 w1 writes x10"
.assert rd_wdata == 0xd4f71f419dcb8782 "vsha2cl.vv e64 m2 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m2 w2 writes x10"
.assert rd_wdata == 0xf6afceb8bcfcddf5 "vsha2cl.vv e64 m2 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m2 w3 writes x10"
.assert rd_wdata == 0x24432c0e50eda448 "vsha2cl.vv e64 m2 w3"
.4byte 0xbb062a77  # vsha2ch.vv v20, v16, v12
.assert trap == 0 "vsha2ch.vv e64 m2 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "vsha2ch.vv e64 m2 w0 writes x10"
.assert rd_wdata == 0x56c9140f2ea6c12e "vsha2ch.vv e64 m2 w0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 m2 w1 writes x10"
.assert rd_wdata == 0x5a50d7d32f11283a "vsha2ch.vv e64 m2 w1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 m2 w2 writes x10"
.assert rd_wdata == 0x87ae4a91784374f9 "vsha2ch.vv e64 m2 w2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 m2 w3 writes x10"
.assert rd_wdata == 0x8fcd54539c42bb51 "vsha2ch.vv e64 m2 w3"
.4byte 0xc1a47657  # vsetivli x12, 8, e64, m4, tu, mu
.assert rd_addr == 12 "vsetivli e64 m4 vl=8 writes x12"
.assert rd_wdata == 0x8 "vsetivli e64 m4 vl=8"
.4byte 0x244332b7  # lui x5, 0x24433
.4byte 0xc0e28293  # addi x5, x5, -1010
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x50eda337  # lui x6, 0x50eda
.4byte 0x44830313  # addi x6, x6, 1096
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xf6afd2b7  # lui x5, 0xf6afd
.4byte 0xeb828293  # addi x5, x5, -328
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xbcfce337  # lui x6, 0xbcfce
.4byte 0xdf530313  # addi x6, x6, -523
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xd4f722b7  # lui x5, 0xd4f72
.4byte 0xf4128293  # addi x5, x5, -191
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x9dcb8337  # lui x6, 0x9dcb8
.4byte 0x78230313  # addi x6, x6, 1922
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x58cb02b7  # lui x5, 0x58cb0
.4byte 0x23428293  # addi x5, x5, 564
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x7ab52337  # lui x6, 0x7ab52
.4byte 0xf9130313  # addi x6, x6, -111
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x3c6ef2b7  # lui x5, 0x3c6ef
.4byte 0x37228293  # addi x5, x5, 882
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xfe950337  # lui x6, 0xfe950
.4byte 0x82b30313  # addi x6, x6, -2005
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa54ff2b7  # lui x5, 0xa54ff
.4byte 0x53a28293  # addi x5, x5, 1338
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x5f1d3337  # lui x6, 0x5f1d3
.4byte 0x6f130313  # addi x6, x6, 1777
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1f83e2b7  # lui x5, 0x1f83e
.4byte 0x9ab28293  # addi x5, x5, -1621
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xfb41c337  # lui x6, 0xfb41c
.4byte 0xd6b30313  # addi x6, x6, -661
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5be0d2b7  # lui x5, 0x5be0d
.4byte 0xd1928293  # addi x5, x5, -743
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x137e2337  # lui x6, 0x137e2
.4byte 0x17930313  # addi x6, x6, 377
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8fcd52b7  # lui x5, 0x8fcd5
.4byte 0x45328293  # addi x5, x5, 1107
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x9c42c337  # lui x6, 0x9c42c
.4byte 0xb5130313  # addi x6, x6, -1199
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0x87ae52b7  # lui x5, 0x87ae5
.4byte 0xa9128293  # addi x5, x5, -1391
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x78437337  # lui x6, 0x78437
.4byte 0x4f930313  # addi x6, x6, 1273
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x5a50d2b7  # lui x5, 0x5a50d
.4byte 0x7d328293  # addi x5, x5, 2003
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x2f113337  # lui x6, 0x2f113
.4byte 0x83a30313  # addi x6, x6, -1990
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x56c912b7  # lui x5, 0x56c91
.4byte 0x40f28293  # addi x5, x5, 1039
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x2ea6c337  # lui x6, 0x2ea6c
.4byte 0x12e30313  # addi x6, x6, 302
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x6a09e2b7  # lui x5, 0x6a09e
.4byte 0x66728293  # addi x5, x5, 1639
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xf3bcd337  # lui x6, 0xf3bcd
.4byte 0x90830313  # addi x6, x6, -1784
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xbb67b2b7  # lui x5, 0xbb67b
.4byte 0xe8528293  # addi x5, x5, -379
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x84caa337  # lui x6, 0x84caa
.4byte 0x73b30313  # addi x6, x6, 1851
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x510e52b7  # lui x5, 0x510e5
.4byte 0x27f28293  # addi x5, x5, 639
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xade68337  # lui x6, 0xade68
.4byte 0x2d130313  # addi x6, x6, 721
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x9b0572b7  # lui x5, 0x9b057
.4byte 0x88c28293  # addi x5, x5, -1908
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x2b3e7337  # lui x6, 0x2b3e7
.4byte 0xc1f30313  # addi x6, x6, -993
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xc59252b7  # lui x5, 0xc5925
.4byte 0x35d28293  # addi x5, x5, 861
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x18a90337  # lui x6, 0x18a90
.4byte 0x8bd30313  # addi x6, x6, -1859
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0xfb4272b7  # lui x5, 0xfb427
.4byte 0xfa928293  # addi x5, x5, -87
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xd4295337  # lui x6, 0xd4295
.4byte 0x5a130313  # addi x6, x6, 1441
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x334f32b7  # lui x5, 0x334f3
.4byte 0xb1828293  # addi x5, x5, -1256
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xc4c40337  # lui x6, 0xc4c40
.4byte 0x89530313  # addi x6, x6, -1899
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xc93922b7  # lui x5, 0xc9392
.4byte 0xeec28293  # addi x5, x5, -276
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x4a749337  # lui x6, 0x4a749
.4byte 0x5c630313  # addi x6, x6, 1478
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x8f0ff2b7  # lui x5, 0x8f0ff
.4byte 0xac328293  # addi x5, x5, -1341
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xaec62337  # lui x6, 0xaec62
.4byte 0x71630313  # addi x6, x6, 1814
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x4f6bb2b7  # lui x5, 0x4f6bb
.4byte 0x79c28293  # addi x5, x5, 1948
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xca3c4337  # lui x6, 0xca3c4
.4byte 0xa3030313  # addi x6, x6, -1488
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x825972b7  # lui x5, 0x82597
.4byte 0x7d528293  # addi x5, x5, 2005
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x7955e337  # lui x6, 0x7955e
.4byte 0xd5530313  # addi x6, x6, -683
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xa3ec92b7  # lui x5, 0xa3ec9
.4byte 0x31828293  # addi x5, x5, 792
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xd728b337  # lui x6, 0xd728b
.4byte 0xe2230313  # addi x6, x6, -478
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xbf462877  # vsha2cl.vv v16, v20, v12
.assert trap == 0 "vsha2cl.vv e64 m4 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2cl.vv e64 m4 w0 writes x10"
.assert rd_wdata == 0x58cb02347ab51f91 "vsha2cl.vv e64 m4 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m4 w1 writes x10"
.assert rd_wdata == 0xd4f71f419dcb8782 "vsha2cl.vv e64 m4 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m4 w2 writes x10"
.assert rd_wdata == 0xf6afceb8bcfcddf5 "vsha2cl.vv e64 m4 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m4 w3 writes x10"
.assert rd_wdata == 0x24432c0e50eda448 "vsha2cl.vv e64 m4 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m4 w4 writes x10"
.assert rd_wdata == 0xf30b8320b8867ae1 "vsha2cl.vv e64 m4 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m4 w5 writes x10"
.assert rd_wdata == 0x68ae01497e511786 "vsha2cl.vv e64 m4 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m4 w6 writes x10"
.assert rd_wdata == 0x82e9f359006dbca "vsha2cl.vv e64 m4 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 m4 w7 writes x10"
.assert rd_wdata == 0xe3653b325a9878c1 "vsha2cl.vv e64 m4 w7"
.4byte 0x244332b7  # lui x5, 0x24433
.4byte 0xc0e28293  # addi x5, x5, -1010
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x50eda337  # lui x6, 0x50eda
.4byte 0x44830313  # addi x6, x6, 1096
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xf6afd2b7  # lui x5, 0xf6afd
.4byte 0xeb828293  # addi x5, x5, -328
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xbcfce337  # lui x6, 0xbcfce
.4byte 0xdf530313  # addi x6, x6, -523
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xd4f722b7  # lui x5, 0xd4f72
.4byte 0xf4128293  # addi x5, x5, -191
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x9dcb8337  # lui x6, 0x9dcb8
.4byte 0x78230313  # addi x6, x6, 1922
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x58cb02b7  # lui x5, 0x58cb0
.4byte 0x23428293  # addi x5, x5, 564
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x7ab52337  # lui x6, 0x7ab52
.4byte 0xf9130313  # addi x6, x6, -111
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x3c6ef2b7  # lui x5, 0x3c6ef
.4byte 0x37228293  # addi x5, x5, 882
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xfe950337  # lui x6, 0xfe950
.4byte 0x82b30313  # addi x6, x6, -2005
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa54ff2b7  # lui x5, 0xa54ff
.4byte 0x53a28293  # addi x5, x5, 1338
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x5f1d3337  # lui x6, 0x5f1d3
.4byte 0x6f130313  # addi x6, x6, 1777
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1f83e2b7  # lui x5, 0x1f83e
.4byte 0x9ab28293  # addi x5, x5, -1621
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xfb41c337  # lui x6, 0xfb41c
.4byte 0xd6b30313  # addi x6, x6, -661
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5be0d2b7  # lui x5, 0x5be0d
.4byte 0xd1928293  # addi x5, x5, -743
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x137e2337  # lui x6, 0x137e2
.4byte 0x17930313  # addi x6, x6, 377
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00825073  # csrwi vstart, 4
.4byte 0xbb462877  # vsha2ch.vv v16, v20, v12
.assert trap == 0 "vsha2ch.vv e64 m4 vstart=4 retires"
.4byte 0x00802573  # csrr x10, vstart
.assert rd_addr == 10 "vstart cleared after vsha2ch.vv e64 writes x10"
.assert rd_wdata == 0x0 "vstart cleared after vsha2ch.vv e64"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2ch.vv e64 vstart=4 w0 writes x10"
.assert rd_wdata == 0x5be0cd19137e2179 "vsha2ch.vv e64 vstart=4 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 vstart=4 w1 writes x10"
.assert rd_wdata == 0x1f83d9abfb41bd6b "vsha2ch.vv e64 vstart=4 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 vstart=4 w2 writes x10"
.assert rd_wdata == 0xa54ff53a5f1d36f1 "vsha2ch.vv e64 vstart=4 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 vstart=4 w3 writes x10"
.assert rd_wdata == 0x3c6ef372fe94f82b "vsha2ch.vv e64 vstart=4 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 vstart=4 w4 writes x10"
.assert rd_wdata == 0x2514d3de423b3abc "vsha2ch.vv e64 vstart=4 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 vstart=4 w5 writes x10"
.assert rd_wdata == 0xdd24f70b5b941fcc "vsha2ch.vv e64 vstart=4 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 vstart=4 w6 writes x10"
.assert rd_wdata == 0x3a37eff319bb9ba5 "vsha2ch.vv e64 vstart=4 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2ch.vv e64 vstart=4 w7 writes x10"
.assert rd_wdata == 0x475455dca71a287 "vsha2ch.vv e64 vstart=4 w7"
.4byte 0x244332b7  # lui x5, 0x24433
.4byte 0xc0e28293  # addi x5, x5, -1010
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x50eda337  # lui x6, 0x50eda
.4byte 0x44830313  # addi x6, x6, 1096
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xf6afd2b7  # lui x5, 0xf6afd
.4byte 0xeb828293  # addi x5, x5, -328
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xbcfce337  # lui x6, 0xbcfce
.4byte 0xdf530313  # addi x6, x6, -523
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xd4f722b7  # lui x5, 0xd4f72
.4byte 0xf4128293  # addi x5, x5, -191
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x9dcb8337  # lui x6, 0x9dcb8
.4byte 0x78230313  # addi x6, x6, 1922
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x58cb02b7  # lui x5, 0x58cb0
.4byte 0x23428293  # addi x5, x5, 564
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x7ab52337  # lui x6, 0x7ab52
.4byte 0xf9130313  # addi x6, x6, -111
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x3c6ef2b7  # lui x5, 0x3c6ef
.4byte 0x37228293  # addi x5, x5, 882
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xfe950337  # lui x6, 0xfe950
.4byte 0x82b30313  # addi x6, x6, -2005
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa54ff2b7  # lui x5, 0xa54ff
.4byte 0x53a28293  # addi x5, x5, 1338
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x5f1d3337  # lui x6, 0x5f1d3
.4byte 0x6f130313  # addi x6, x6, 1777
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1f83e2b7  # lui x5, 0x1f83e
.4byte 0x9ab28293  # addi x5, x5, -1621
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0xfb41c337  # lui x6, 0xfb41c
.4byte 0xd6b30313  # addi x6, x6, -661
.4byte 0x02031313  # slli x6, x6, 32
.4byte 0x02035313  # srli x6, x6, 32
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5be0d2b7  # lui x5, 0x5be0d
.4byte 0xd1928293  # addi x5, x5, -743
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x137e2337  # lui x6, 0x137e2
.4byte 0x17930313  # addi x6, x6, 377
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xc1a27657  # vsetivli x12, 4, e64, m4, tu, mu
.4byte 0xbf462877  # vsha2cl.vv v16, v20, v12
.assert trap == 0 "vsha2cl.vv e64 tu vl=4 m4 retires"
.4byte 0xc1a47657  # vsetivli x12, 8, e64, m4, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vsha2cl.vv e64 tu tail w0 writes x10"
.assert rd_wdata == 0x58cb02347ab51f91 "vsha2cl.vv e64 tu tail w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 tu tail w1 writes x10"
.assert rd_wdata == 0xd4f71f419dcb8782 "vsha2cl.vv e64 tu tail w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 tu tail w2 writes x10"
.assert rd_wdata == 0xf6afceb8bcfcddf5 "vsha2cl.vv e64 tu tail w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 tu tail w3 writes x10"
.assert rd_wdata == 0x24432c0e50eda448 "vsha2cl.vv e64 tu tail w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 tu tail w4 writes x10"
.assert rd_wdata == 0x58cb02347ab51f91 "vsha2cl.vv e64 tu tail w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 tu tail w5 writes x10"
.assert rd_wdata == 0xd4f71f419dcb8782 "vsha2cl.vv e64 tu tail w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 tu tail w6 writes x10"
.assert rd_wdata == 0xf6afceb8bcfcddf5 "vsha2cl.vv e64 tu tail w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vsha2cl.vv e64 tu tail w7 writes x10"
.assert rd_wdata == 0x24432c0e50eda448 "vsha2cl.vv e64 tu tail w7"
.4byte 0xcd907657  # vsetivli x12, 0, e64, m2, ta, ma
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 0 "vsha2ms.vv e64 m2 vl=0 retires"
.4byte 0xbf462877  # vsha2cl.vv v16, v20, v12
.assert trap == 0 "vsha2cl.vv e64 m2 vl=0 retires"
.4byte 0xbb462877  # vsha2ch.vv v16, v20, v12
.assert trap == 0 "vsha2ch.vv e64 m2 vl=0 retires"
.4byte 0x01907fd7  # vsetvli x31, x0, e64, m2, tu, mu
.4byte 0xb68c2877  # vsha2ms.vv v16, v8, v24
.assert trap == 0 "vsha2ms.vv e64 VLMAX m2 retires"
.4byte 0x01a07fd7  # vsetvli x31, x0, e64, m4, tu, mu
.4byte 0xb68c2877  # vsha2ms.vv v16, v8, v24
.assert trap == 0 "vsha2ms.vv e64 VLMAX m4 retires"
.4byte 0x01b07fd7  # vsetvli x31, x0, e64, m8, tu, mu
.4byte 0xb68c2877  # vsha2ms.vv v16, v8, v24
.assert trap == 0 "vsha2ms.vv e64 VLMAX m8 retires"

# Section 3: Zvknhb illegal traps (SEW=8/16, vm=0, vl%4!=0, vstart%4!=0, EGW>VLEN*LMUL, overlap, align, vill).
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv at e8 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv at e8 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv at e8 traps"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv at e16 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv at e16 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv at e16 traps"
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0xb4862877  # vsha2ms.vv v16, v8, v12 (illegal vm=0)
.assert trap == 1 "vsha2ms.vv vm=0 traps"
.4byte 0xbc862877  # vsha2cl.vv v16, v8, v12 (illegal vm=0)
.assert trap == 1 "vsha2cl.vv vm=0 traps"
.4byte 0xb8862877  # vsha2ch.vv v16, v8, v12 (illegal vm=0)
.assert trap == 1 "vsha2ch.vv vm=0 traps"
.4byte 0xc100f657  # vsetivli x12, 1, e32, m1, tu, mu
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e32 vl=1 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e32 vl=1 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e32 vl=1 traps"
.4byte 0xc1017657  # vsetivli x12, 2, e32, m1, tu, mu
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e32 vl=2 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e32 vl=2 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e32 vl=2 traps"
.4byte 0xc101f657  # vsetivli x12, 3, e32, m1, tu, mu
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e32 vl=3 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e32 vl=3 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e32 vl=3 traps"
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e32 vstart=1 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e32 vstart=1 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e32 vstart=1 traps"
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e32 vstart=2 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e32 vstart=2 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e32 vstart=2 traps"
.4byte 0x0081d073  # csrwi vstart, 3
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e32 vstart=3 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e32 vstart=3 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e32 vstart=3 traps"
.4byte 0x00805073  # csrwi vstart, 0
.4byte 0xc190f657  # vsetivli x12, 1, e64, m2, tu, mu
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e64 vl=1 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e64 vl=1 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e64 vl=1 traps"
.4byte 0xc1917657  # vsetivli x12, 2, e64, m2, tu, mu
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e64 vl=2 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e64 vl=2 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e64 vl=2 traps"
.4byte 0xc191f657  # vsetivli x12, 3, e64, m2, tu, mu
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e64 vl=3 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e64 vl=3 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e64 vl=3 traps"
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e64 vstart=1 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e64 vstart=1 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e64 vstart=1 traps"
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e64 vstart=2 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e64 vstart=2 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e64 vstart=2 traps"
.4byte 0x0081d073  # csrwi vstart, 3
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv e64 vstart=3 traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv e64 vstart=3 traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv e64 vstart=3 traps"
.4byte 0x00805073  # csrwi vstart, 0
# EGW > VLEN*LMUL at VLEN=128 (e32 mf2 & e64 m1, avl=4): traps at VLEN=128, retires at VLEN=256/512.
.4byte 0xc1727657  # vsetivli x12, 4, e32, mf2, tu, mu
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.4byte 0x34202573  # csrr x10, mcause
.4byte 0xc1827657  # vsetivli x12, 4, e64, m1, tu, mu
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0xb6862477  # vsha2ms.vv v8, v8, v12
.assert trap == 1 "vsha2ms.vv e32 vd==vs2 traps"
.4byte 0xb6862677  # vsha2ms.vv v12, v8, v12
.assert trap == 1 "vsha2ms.vv e32 vd==vs1 traps"
.4byte 0xbe862477  # vsha2cl.vv v8, v8, v12
.assert trap == 1 "vsha2cl.vv e32 vd==vs2 traps"
.4byte 0xbe862677  # vsha2cl.vv v12, v8, v12
.assert trap == 1 "vsha2cl.vv e32 vd==vs1 traps"
.4byte 0xba862477  # vsha2ch.vv v8, v8, v12
.assert trap == 1 "vsha2ch.vv e32 vd==vs2 traps"
.4byte 0xba862677  # vsha2ch.vv v12, v8, v12
.assert trap == 1 "vsha2ch.vv e32 vd==vs1 traps"
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.4byte 0xb6862477  # vsha2ms.vv v8, v8, v12
.assert trap == 1 "vsha2ms.vv e64 vd==vs2 traps"
.4byte 0xb6862677  # vsha2ms.vv v12, v8, v12
.assert trap == 1 "vsha2ms.vv e64 vd==vs1 traps"
.4byte 0xbe862477  # vsha2cl.vv v8, v8, v12
.assert trap == 1 "vsha2cl.vv e64 vd==vs2 traps"
.4byte 0xbe862677  # vsha2cl.vv v12, v8, v12
.assert trap == 1 "vsha2cl.vv e64 vd==vs1 traps"
.4byte 0xba862477  # vsha2ch.vv v8, v8, v12
.assert trap == 1 "vsha2ch.vv e64 vd==vs2 traps"
.4byte 0xba862677  # vsha2ch.vv v12, v8, v12
.assert trap == 1 "vsha2ch.vv e64 vd==vs1 traps"
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.4byte 0xb68628f7  # vsha2ms.vv v17, v8, v12
.assert trap == 1 "vsha2ms.vv e64 m2 misaligned vd traps"
.4byte 0xbe962877  # vsha2cl.vv v16, v9, v12
.assert trap == 1 "vsha2cl.vv e64 m2 misaligned vs2 traps"
.4byte 0xba86a877  # vsha2ch.vv v16, v8, v13
.assert trap == 1 "vsha2ch.vv e64 m2 misaligned vs1 traps"
.4byte 0xc2027657  # vsetivli reserved_sew4 (sets vill)
.4byte 0xb6862877  # vsha2ms.vv v16, v8, v12
.assert trap == 1 "vsha2ms.vv under vill traps"
.4byte 0xbe862877  # vsha2cl.vv v16, v8, v12
.assert trap == 1 "vsha2cl.vv under vill traps"
.4byte 0xba862877  # vsha2ch.vv v16, v8, v12
.assert trap == 1 "vsha2ch.vv under vill traps"
