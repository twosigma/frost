# Vector Zvbc (vclmul/vclmulh), Zvkned (AES-128/256), and Zvkg (GHASH) directed trace.
# Covers all 17 encodings, FIPS-197 KATs, GCM KATs, EGS=4 group bounds, vstart, and traps.
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

# Section 1: Zvbc vclmul/vclmulh (.vv/.vx) at e64, control on v3 (0x42302557), masks, tails, traps.
.4byte 0xc1817657  # vsetivli x12, 2, e64, m1, tu, mu
.assert rd_addr == 12 "vsetivli e64 m1 vl=2 writes x12"
.assert rd_wdata == 0x2 "vsetivli e64 m1 vl=2"
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x5e02c457  # vmv.v.x v8, x5
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
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0xfedcc2b7  # lui x5, 0xfedcc
.4byte 0xa9828293  # addi x5, x5, -1384
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x76543337  # lui x6, 0x76543
.4byte 0x21030313  # addi x6, x6, 528
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x328621d7  # vclmul.vv v3, v8, v12
.assert trap == 0 "control vclmul.vv retires"
.4byte 0x42302557  # vmv.x.s x10, v3
.assert rd_addr == 10 "control vclmul.vv lane 0 writes x10"
.assert rd_wdata == 0x40a0789828c810f0 "control vclmul.vv lane 0"
.4byte 0x3e30bc57  # vslidedown.vi v24, v3, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "control vclmul.vv lane 1 writes x10"
.assert rd_wdata == 0x0 "control vclmul.vv lane 1"
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.assert rd_addr == 12 "vsetivli e64 m2 vl=4 writes x12"
.assert rd_wdata == 0x4 "vsetivli e64 m2 vl=4"
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xfff00293  # addi x5, x0, -1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x02029293  # slli x5, x5, 32
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
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0xfff00293  # addi x5, x0, -1
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xfedcc2b7  # lui x5, 0xfedcc
.4byte 0xa9828293  # addi x5, x5, -1384
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x76543337  # lui x6, 0x76543
.4byte 0x21030313  # addi x6, x6, 528
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xa55a33b7  # lui x7, 0xa55a3
.4byte 0x3cc38393  # addi x7, x7, 972
.4byte 0x02039393  # slli x7, x7, 32
.4byte 0x0f0f1337  # lui x6, 0xf0f1
.4byte 0x23530313  # addi x6, x6, 565
.4byte 0x0063e3b3  # or x7, x7, x6
.4byte 0x32862857  # vclmul.vv v16, v8, v12
.assert trap == 0 "vclmul.vv e64 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vclmul.vv lane 0 writes x10"
.assert rd_wdata == 0x40a0789828c810f0 "vclmul.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmul.vv lane 1 writes x10"
.assert rd_wdata == 0x0 "vclmul.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmul.vv lane 2 writes x10"
.assert rd_wdata == 0x5555555555555555 "vclmul.vv lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmul.vv lane 3 writes x10"
.assert rd_wdata == 0x0 "vclmul.vv lane 3"
.4byte 0x36862857  # vclmulh.vv v16, v8, v12
.assert trap == 0 "vclmulh.vv e64 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vclmulh.vv lane 0 writes x10"
.assert rd_wdata == 0xe038d8688850b0 "vclmulh.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmulh.vv lane 1 writes x10"
.assert rd_wdata == 0x4000000000000000 "vclmulh.vv lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmulh.vv lane 2 writes x10"
.assert rd_wdata == 0x5555555555555555 "vclmulh.vv lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmulh.vv lane 3 writes x10"
.assert rd_wdata == 0x0 "vclmulh.vv lane 3"
.4byte 0x3283e857  # vclmul.vx v16, v8, x7
.assert trap == 0 "vclmul.vx e64 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vclmul.vx lane 0 writes x10"
.assert rd_wdata == 0x3592147e1071b743 "vclmul.vx lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmul.vx lane 1 writes x10"
.assert rd_wdata == 0x8000000000000000 "vclmul.vx lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmul.vx lane 2 writes x10"
.assert rd_wdata == 0x6336114405050e13 "vclmul.vx lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmul.vx lane 3 writes x10"
.assert rd_wdata == 0xa55a33cc0f0f1235 "vclmul.vx lane 3"
.4byte 0x3683e857  # vclmulh.vx v16, v8, x7
.assert trap == 0 "vclmulh.vx e64 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vclmulh.vx lane 0 writes x10"
.assert rd_wdata == 0xb035c38ff93c54 "vclmulh.vx lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmulh.vx lane 1 writes x10"
.assert rd_wdata == 0x52ad19e60787891a "vclmulh.vx lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmulh.vx lane 2 writes x10"
.assert rd_wdata == 0x6336114405050e13 "vclmulh.vx lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vclmulh.vx lane 3 writes x10"
.assert rd_wdata == 0x0 "vclmulh.vx lane 3"
.4byte 0xc000f657  # vsetivli x12, 1, e8, m1, tu, mu
.4byte 0x00500293  # addi x5, x0, 5
.4byte 0x5e02c057  # vmv.v.x v0, x5
.4byte 0x01a07fd7  # vsetvli x31, x0, e64, m4, tu, mu
.4byte 0x55aa52b7  # lui x5, 0x55aa5
.4byte 0x5aa28293  # addi x5, x5, 1450
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x55aa5337  # lui x6, 0x55aa5
.4byte 0x5aa30313  # addi x6, x6, 1450
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xc1a27657  # vsetivli x12, 4, e64, m4, tu, mu
.4byte 0x00100293  # addi x5, x0, 1
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0xfff00293  # addi x5, x0, -1
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x02029293  # slli x5, x5, 32
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
.4byte 0x00000293  # addi x5, x0, 0
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0xfff00293  # addi x5, x0, -1
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x800002b7  # lui x5, 0x80000
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xfedcc2b7  # lui x5, 0xfedcc
.4byte 0xa9828293  # addi x5, x5, -1384
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x76543337  # lui x6, 0x76543
.4byte 0x21030313  # addi x6, x6, 528
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x30862857  # vclmul.vv v16, v8, v12, v0.t
.assert trap == 0 "masked vclmul.vv tu/mu retires"
.4byte 0xc1a2f657  # vsetivli x12, 5, e64, m4, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "masked vclmul.vv lane 0 writes x10"
.assert rd_wdata == 0x40a0789828c810f0 "masked vclmul.vv lane 0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vclmul.vv mu lane 1 writes x10"
.assert rd_wdata == 0x55aa55aa55aa55aa "masked vclmul.vv mu lane 1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vclmul.vv lane 2 writes x10"
.assert rd_wdata == 0x5555555555555555 "masked vclmul.vv lane 2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vclmul.vv mu lane 3 writes x10"
.assert rd_wdata == 0x55aa55aa55aa55aa "masked vclmul.vv mu lane 3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vclmul.vv tu tail lane 4 writes x10"
.assert rd_wdata == 0x55aa55aa55aa55aa "masked vclmul.vv tu tail lane 4"
.4byte 0xcda27657  # vsetivli x12, 4, e64, m4, ta, ma
.4byte 0x3483e857  # vclmulh.vx v16, v8, x7, v0.t
.assert trap == 0 "masked vclmulh.vx ta/ma retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "masked vclmulh.vx ta/ma lane 0 writes x10"
.assert rd_wdata == 0xb035c38ff93c54 "masked vclmulh.vx ta/ma lane 0"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "masked vclmulh.vx ta/ma lane 2 writes x10"
.assert rd_wdata == 0x6336114405050e13 "masked vclmulh.vx ta/ma lane 2"
.4byte 0xcda07657  # vsetivli x12, 0, e64, m4, ta, ma
.4byte 0x32862857  # vclmul.vv v16, v8, v12
.assert trap == 0 "vclmul.vv vl=0 retires"
.4byte 0x3683e857  # vclmulh.vx v16, v8, x7
.assert trap == 0 "vclmulh.vx vl=0 retires"
.4byte 0xc1a0f657  # vsetivli x12, 1, e64, m4, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vclmul vl=0 preserves v16 writes x10"
.assert rd_wdata == 0xb035c38ff93c54 "vclmul vl=0 preserves v16"
.4byte 0x01807fd7  # vsetvli x31, x0, e64, m1, tu, mu
.4byte 0x112232b7  # lui x5, 0x11223
.4byte 0x34428293  # addi x5, x5, 836
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x55667337  # lui x6, 0x55667
.4byte 0x78830313  # addi x6, x6, 1928
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x01b00393  # addi x7, x0, 27
.4byte 0x3303e857  # vclmul.vx v16, v16, x7
.assert trap == 0 "in-place vclmul.vx VLMAX m1 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vclmul.vx VLMAX m1 lane 0 writes x10"
.assert rd_wdata == 0xa854fbab02fe5c58 "vclmul.vx VLMAX m1 lane 0"
.4byte 0x01907fd7  # vsetvli x31, x0, e64, m2, tu, mu
.4byte 0x112232b7  # lui x5, 0x11223
.4byte 0x34428293  # addi x5, x5, 836
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x55667337  # lui x6, 0x55667
.4byte 0x78830313  # addi x6, x6, 1928
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x01b00393  # addi x7, x0, 27
.4byte 0x3303e857  # vclmul.vx v16, v16, x7
.assert trap == 0 "in-place vclmul.vx VLMAX m2 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vclmul.vx VLMAX m2 lane 0 writes x10"
.assert rd_wdata == 0xa854fbab02fe5c58 "vclmul.vx VLMAX m2 lane 0"
.4byte 0x01a07fd7  # vsetvli x31, x0, e64, m4, tu, mu
.4byte 0x112232b7  # lui x5, 0x11223
.4byte 0x34428293  # addi x5, x5, 836
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x55667337  # lui x6, 0x55667
.4byte 0x78830313  # addi x6, x6, 1928
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x01b00393  # addi x7, x0, 27
.4byte 0x3303e857  # vclmul.vx v16, v16, x7
.assert trap == 0 "in-place vclmul.vx VLMAX m4 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vclmul.vx VLMAX m4 lane 0 writes x10"
.assert rd_wdata == 0xa854fbab02fe5c58 "vclmul.vx VLMAX m4 lane 0"
.4byte 0x01b07fd7  # vsetvli x31, x0, e64, m8, tu, mu
.4byte 0x112232b7  # lui x5, 0x11223
.4byte 0x34428293  # addi x5, x5, 836
.4byte 0x02029293  # slli x5, x5, 32
.4byte 0x55667337  # lui x6, 0x55667
.4byte 0x78830313  # addi x6, x6, 1928
.4byte 0x0062e2b3  # or x5, x5, x6
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x01b00393  # addi x7, x0, 27
.4byte 0x3303e857  # vclmul.vx v16, v16, x7
.assert trap == 0 "in-place vclmul.vx VLMAX m8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vclmul.vx VLMAX m8 lane 0 writes x10"
.assert rd_wdata == 0xa854fbab02fe5c58 "vclmul.vx VLMAX m8 lane 0"
# Zvbc illegal traps: SEW!=64 (e8/e16/e32), masked v0, misaligned m2, vill.
.4byte 0xc0017657  # vsetivli x12, 2, e8, m1, tu, mu
.4byte 0x32862857  # vclmul.vv v16, v8, v12
.assert trap == 1 "vclmul.vv at e8 traps"
.4byte 0x3283e857  # vclmul.vx v16, v8, x7
.assert trap == 1 "vclmul.vx at e8 traps"
.4byte 0x36862857  # vclmulh.vv v16, v8, v12
.assert trap == 1 "vclmulh.vv at e8 traps"
.4byte 0x3683e857  # vclmulh.vx v16, v8, x7
.assert trap == 1 "vclmulh.vx at e8 traps"
.4byte 0xc0817657  # vsetivli x12, 2, e16, m1, tu, mu
.4byte 0x32862857  # vclmul.vv v16, v8, v12
.assert trap == 1 "vclmul.vv at e16 traps"
.4byte 0x3283e857  # vclmul.vx v16, v8, x7
.assert trap == 1 "vclmul.vx at e16 traps"
.4byte 0x36862857  # vclmulh.vv v16, v8, v12
.assert trap == 1 "vclmulh.vv at e16 traps"
.4byte 0x3683e857  # vclmulh.vx v16, v8, x7
.assert trap == 1 "vclmulh.vx at e16 traps"
.4byte 0xc1017657  # vsetivli x12, 2, e32, m1, tu, mu
.4byte 0x32862857  # vclmul.vv v16, v8, v12
.assert trap == 1 "vclmul.vv at e32 traps"
.4byte 0x3283e857  # vclmul.vx v16, v8, x7
.assert trap == 1 "vclmul.vx at e32 traps"
.4byte 0x36862857  # vclmulh.vv v16, v8, v12
.assert trap == 1 "vclmulh.vv at e32 traps"
.4byte 0x3683e857  # vclmulh.vx v16, v8, x7
.assert trap == 1 "vclmulh.vx at e32 traps"
.4byte 0xc1817657  # vsetivli x12, 2, e64, m1, tu, mu
.4byte 0x30862057  # vclmul.vv v0, v8, v12, v0.t
.assert trap == 1 "masked vclmul.vv vd==v0 traps"
.4byte 0x34062857  # vclmulh.vv v16, v0, v12, v0.t
.assert trap == 1 "masked vclmulh.vv vs2==v0 traps"
.4byte 0x30802857  # vclmul.vv v16, v8, v0, v0.t
.assert trap == 1 "masked vclmul.vv vs1==v0 traps"
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.4byte 0x328628d7  # vclmul.vv v17, v8, v12
.assert trap == 1 "vclmul.vv misaligned vd at m2 traps"
.4byte 0xc2017657  # vsetivli reserved_sew4 (sets vill)
.4byte 0x32862857  # vclmul.vv v16, v8, v12
.assert trap == 1 "vclmul.vv under vill traps"

# Section 2: Zvkned FIPS-197 AES-128 encrypt/decrypt (all 10 Rcon values) & AES-256 vaeskf2.
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.assert rd_addr == 12 "vsetivli e32 m1 vl=4 writes x12"
.assert rd_wdata == 0x4 "vsetivli e32 m1 vl=4"
.4byte 0x0f0e12b7  # lui x5, 0xf0e1
.4byte 0xd0c28293  # addi x5, x5, -756
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x0b0a12b7  # lui x5, 0xb0a1
.4byte 0x90828293  # addi x5, x5, -1784
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x070602b7  # lui x5, 0x7060
.4byte 0x50428293  # addi x5, x5, 1284
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x030202b7  # lui x5, 0x3020
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x8a80a4f7  # vaeskf1.vi v9, v8, 1
.assert trap == 0 "vaeskf1.vi round 1 retires"
.4byte 0x8a912577  # vaeskf1.vi v10, v9, 2
.assert trap == 0 "vaeskf1.vi round 2 retires"
.4byte 0x8aa1a5f7  # vaeskf1.vi v11, v10, 3
.assert trap == 0 "vaeskf1.vi round 3 retires"
.4byte 0x8ab22677  # vaeskf1.vi v12, v11, 4
.assert trap == 0 "vaeskf1.vi round 4 retires"
.4byte 0x8ac2a6f7  # vaeskf1.vi v13, v12, 5
.assert trap == 0 "vaeskf1.vi round 5 retires"
.4byte 0x8ad32777  # vaeskf1.vi v14, v13, 6
.assert trap == 0 "vaeskf1.vi round 6 retires"
.4byte 0x8ae3a7f7  # vaeskf1.vi v15, v14, 7
.assert trap == 0 "vaeskf1.vi round 7 retires"
.4byte 0x8af42877  # vaeskf1.vi v16, v15, 8
.assert trap == 0 "vaeskf1.vi round 8 retires"
.4byte 0x8b04a8f7  # vaeskf1.vi v17, v16, 9
.assert trap == 0 "vaeskf1.vi round 9 retires"
.4byte 0x8b152977  # vaeskf1.vi v18, v17, 10
.assert trap == 0 "vaeskf1.vi round 10 retires"
.4byte 0x43202557  # vmv.x.s x10, v18
.assert rd_addr == 10 "FIPS-197 AES-128 key10 w0 writes x10"
.assert rd_wdata == 0x7f1d1113 "FIPS-197 AES-128 key10 w0"
.4byte 0x3f20bc57  # vslidedown.vi v24, v18, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-128 key10 w1 writes x10"
.assert rd_wdata == 0x174a94e3 "FIPS-197 AES-128 key10 w1"
.4byte 0x3f213c57  # vslidedown.vi v24, v18, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-128 key10 w2 writes x10"
.assert rd_wdata == 0xffffffff8ba707f3 "FIPS-197 AES-128 key10 w2"
.4byte 0x3f21bc57  # vslidedown.vi v24, v18, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-128 key10 w3 writes x10"
.assert rd_wdata == 0xffffffffc5302b4d "FIPS-197 AES-128 key10 w3"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xa683aa77  # vaesz.vs v20, v8
.assert trap == 0 "vaesz.vs encrypt k0 retires"
.4byte 0xa6912a77  # vaesem.vs v20, v9
.assert trap == 0 "vaesem.vs round 1 retires"
.4byte 0xa6a12a77  # vaesem.vs v20, v10
.assert trap == 0 "vaesem.vs round 2 retires"
.4byte 0xa6b12a77  # vaesem.vs v20, v11
.assert trap == 0 "vaesem.vs round 3 retires"
.4byte 0xa6c12a77  # vaesem.vs v20, v12
.assert trap == 0 "vaesem.vs round 4 retires"
.4byte 0xa6d12a77  # vaesem.vs v20, v13
.assert trap == 0 "vaesem.vs round 5 retires"
.4byte 0xa6e12a77  # vaesem.vs v20, v14
.assert trap == 0 "vaesem.vs round 6 retires"
.4byte 0xa6f12a77  # vaesem.vs v20, v15
.assert trap == 0 "vaesem.vs round 7 retires"
.4byte 0xa7012a77  # vaesem.vs v20, v16
.assert trap == 0 "vaesem.vs round 8 retires"
.4byte 0xa7112a77  # vaesem.vs v20, v17
.assert trap == 0 "vaesem.vs round 9 retires"
.4byte 0xa721aa77  # vaesef.vs v20, v18
.assert trap == 0 "vaesef.vs final round retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "FIPS-197 AES-128 ciphertext w0 writes x10"
.assert rd_wdata == 0xffffffffd8e0c469 "FIPS-197 AES-128 ciphertext w0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-128 ciphertext w1 writes x10"
.assert rd_wdata == 0x30047b6a "FIPS-197 AES-128 ciphertext w1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-128 ciphertext w2 writes x10"
.assert rd_wdata == 0xffffffff80b7cdd8 "FIPS-197 AES-128 ciphertext w2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-128 ciphertext w3 writes x10"
.assert rd_wdata == 0x5ac5b470 "FIPS-197 AES-128 ciphertext w3"
.4byte 0xa723aa77  # vaesz.vs v20, v18
.assert trap == 0 "vaesz.vs decrypt k10 retires"
.4byte 0xa7102a77  # vaesdm.vs v20, v17
.assert trap == 0 "vaesdm.vs round 9 retires"
.4byte 0xa7002a77  # vaesdm.vs v20, v16
.assert trap == 0 "vaesdm.vs round 8 retires"
.4byte 0xa6f02a77  # vaesdm.vs v20, v15
.assert trap == 0 "vaesdm.vs round 7 retires"
.4byte 0xa6e02a77  # vaesdm.vs v20, v14
.assert trap == 0 "vaesdm.vs round 6 retires"
.4byte 0xa6d02a77  # vaesdm.vs v20, v13
.assert trap == 0 "vaesdm.vs round 5 retires"
.4byte 0xa6c02a77  # vaesdm.vs v20, v12
.assert trap == 0 "vaesdm.vs round 4 retires"
.4byte 0xa6b02a77  # vaesdm.vs v20, v11
.assert trap == 0 "vaesdm.vs round 3 retires"
.4byte 0xa6a02a77  # vaesdm.vs v20, v10
.assert trap == 0 "vaesdm.vs round 2 retires"
.4byte 0xa6902a77  # vaesdm.vs v20, v9
.assert trap == 0 "vaesdm.vs round 1 retires"
.4byte 0xa680aa77  # vaesdf.vs v20, v8
.assert trap == 0 "vaesdf.vs final round retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "FIPS-197 AES-128 decrypted plaintext w0 writes x10"
.assert rd_wdata == 0x33221100 "FIPS-197 AES-128 decrypted plaintext w0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-128 decrypted plaintext w1 writes x10"
.assert rd_wdata == 0x77665544 "FIPS-197 AES-128 decrypted plaintext w1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-128 decrypted plaintext w2 writes x10"
.assert rd_wdata == 0xffffffffbbaa9988 "FIPS-197 AES-128 decrypted plaintext w2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-128 decrypted plaintext w3 writes x10"
.assert rd_wdata == 0xffffffffffeeddcc "FIPS-197 AES-128 decrypted plaintext w3"
# vaeskf1.vi out-of-range rnd (0->8, 11->3, 17->1) and vaeskf2.vi AES-256 (even/odd/oob).
.4byte 0x8a802af7  # vaeskf1.vi v21, v8, 0
.assert trap == 0 "vaeskf1.vi uimm=0 retires"
.4byte 0x43502557  # vmv.x.s x10, v21
.assert rd_addr == 10 "vaeskf1.vi uimm=0 w0 writes x10"
.assert rd_wdata == 0xfffffffffd74aa57 "vaeskf1.vi uimm=0 w0"
.4byte 0x3f50bc57  # vslidedown.vi v24, v21, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf1.vi uimm=0 w1 writes x10"
.assert rd_wdata == 0xfffffffffa72af53 "vaeskf1.vi uimm=0 w1"
.4byte 0x3f513c57  # vslidedown.vi v24, v21, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf1.vi uimm=0 w2 writes x10"
.assert rd_wdata == 0xfffffffff178a65b "vaeskf1.vi uimm=0 w2"
.4byte 0x3f51bc57  # vslidedown.vi v24, v21, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf1.vi uimm=0 w3 writes x10"
.assert rd_wdata == 0xfffffffffe76ab57 "vaeskf1.vi uimm=0 w3"
.4byte 0x8a85aaf7  # vaeskf1.vi v21, v8, 11
.assert trap == 0 "vaeskf1.vi uimm=11 retires"
.4byte 0x43502557  # vmv.x.s x10, v21
.assert rd_addr == 10 "vaeskf1.vi uimm=11 w0 writes x10"
.assert rd_wdata == 0xfffffffffd74aad3 "vaeskf1.vi uimm=11 w0"
.4byte 0x3f50bc57  # vslidedown.vi v24, v21, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf1.vi uimm=11 w1 writes x10"
.assert rd_wdata == 0xfffffffffa72afd7 "vaeskf1.vi uimm=11 w1"
.4byte 0x3f513c57  # vslidedown.vi v24, v21, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf1.vi uimm=11 w2 writes x10"
.assert rd_wdata == 0xfffffffff178a6df "vaeskf1.vi uimm=11 w2"
.4byte 0x3f51bc57  # vslidedown.vi v24, v21, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf1.vi uimm=11 w3 writes x10"
.assert rd_wdata == 0xfffffffffe76abd3 "vaeskf1.vi uimm=11 w3"
.4byte 0x8a88aaf7  # vaeskf1.vi v21, v8, 17
.assert trap == 0 "vaeskf1.vi uimm=17 retires"
.4byte 0x43502557  # vmv.x.s x10, v21
.assert rd_addr == 10 "vaeskf1.vi uimm=17 w0 writes x10"
.assert rd_wdata == 0xfffffffffd74aad6 "vaeskf1.vi uimm=17 w0"
.4byte 0x3f50bc57  # vslidedown.vi v24, v21, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf1.vi uimm=17 w1 writes x10"
.assert rd_wdata == 0xfffffffffa72afd2 "vaeskf1.vi uimm=17 w1"
.4byte 0x3f513c57  # vslidedown.vi v24, v21, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf1.vi uimm=17 w2 writes x10"
.assert rd_wdata == 0xfffffffff178a6da "vaeskf1.vi uimm=17 w2"
.4byte 0x3f51bc57  # vslidedown.vi v24, v21, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf1.vi uimm=17 w3 writes x10"
.assert rd_wdata == 0xfffffffffe76abd6 "vaeskf1.vi uimm=17 w3"
.4byte 0x0f0e12b7  # lui x5, 0xf0e1
.4byte 0xd0c28293  # addi x5, x5, -756
.4byte 0x5e02cad7  # vmv.v.x v21, x5
.4byte 0x0b0a12b7  # lui x5, 0xb0a1
.4byte 0x90828293  # addi x5, x5, -1784
.4byte 0x3b52ee57  # vslide1up.vx v28, v21, x5
.4byte 0x5e0e0ad7  # vmv.v.v v21, v28
.4byte 0x070602b7  # lui x5, 0x7060
.4byte 0x50428293  # addi x5, x5, 1284
.4byte 0x3b52ee57  # vslide1up.vx v28, v21, x5
.4byte 0x5e0e0ad7  # vmv.v.v v21, v28
.4byte 0x030202b7  # lui x5, 0x3020
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b52ee57  # vslide1up.vx v28, v21, x5
.4byte 0x5e0e0ad7  # vmv.v.v v21, v28
.4byte 0x1f1e22b7  # lui x5, 0x1f1e2
.4byte 0xd1c28293  # addi x5, x5, -740
.4byte 0x5e02cb57  # vmv.v.x v22, x5
.4byte 0x1b1a22b7  # lui x5, 0x1b1a2
.4byte 0x91828293  # addi x5, x5, -1768
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, x5
.4byte 0x5e0e0b57  # vmv.v.v v22, v28
.4byte 0x171612b7  # lui x5, 0x17161
.4byte 0x51428293  # addi x5, x5, 1300
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, x5
.4byte 0x5e0e0b57  # vmv.v.v v22, v28
.4byte 0x131212b7  # lui x5, 0x13121
.4byte 0x11028293  # addi x5, x5, 272
.4byte 0x3b62ee57  # vslide1up.vx v28, v22, x5
.4byte 0x5e0e0b57  # vmv.v.v v22, v28
.4byte 0xab612af7  # vaeskf2.vi v21, v22, 2
.assert trap == 0 "vaeskf2.vi rnd=2 retires"
.4byte 0x43502557  # vmv.x.s x10, v21
.assert rd_addr == 10 "FIPS-197 AES-256 key2 (even rnd) w0 writes x10"
.assert rd_wdata == 0xffffffff9fc273a5 "FIPS-197 AES-256 key2 (even rnd) w0"
.4byte 0x3f50bc57  # vslidedown.vi v24, v21, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-256 key2 (even rnd) w1 writes x10"
.assert rd_wdata == 0xffffffff98c476a1 "FIPS-197 AES-256 key2 (even rnd) w1"
.4byte 0x3f513c57  # vslidedown.vi v24, v21, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-256 key2 (even rnd) w2 writes x10"
.assert rd_wdata == 0xffffffff93ce7fa9 "FIPS-197 AES-256 key2 (even rnd) w2"
.4byte 0x3f51bc57  # vslidedown.vi v24, v21, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-256 key2 (even rnd) w3 writes x10"
.assert rd_wdata == 0xffffffff9cc072a5 "FIPS-197 AES-256 key2 (even rnd) w3"
.4byte 0xab51ab77  # vaeskf2.vi v22, v21, 3
.assert trap == 0 "vaeskf2.vi rnd=3 retires"
.4byte 0x43602557  # vmv.x.s x10, v22
.assert rd_addr == 10 "FIPS-197 AES-256 key3 (odd rnd) w0 writes x10"
.assert rd_wdata == 0xffffffffcda85116 "FIPS-197 AES-256 key3 (odd rnd) w0"
.4byte 0x3f60bc57  # vslidedown.vi v24, v22, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-256 key3 (odd rnd) w1 writes x10"
.assert rd_wdata == 0xffffffffdabe4402 "FIPS-197 AES-256 key3 (odd rnd) w1"
.4byte 0x3f613c57  # vslidedown.vi v24, v22, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-256 key3 (odd rnd) w2 writes x10"
.assert rd_wdata == 0xffffffffc1a45d1a "FIPS-197 AES-256 key3 (odd rnd) w2"
.4byte 0x3f61bc57  # vslidedown.vi v24, v22, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "FIPS-197 AES-256 key3 (odd rnd) w3 writes x10"
.assert rd_wdata == 0xffffffffdeba4006 "FIPS-197 AES-256 key3 (odd rnd) w3"
.4byte 0x0f0e12b7  # lui x5, 0xf0e1
.4byte 0xd0c28293  # addi x5, x5, -756
.4byte 0x5e02cbd7  # vmv.v.x v23, x5
.4byte 0x0b0a12b7  # lui x5, 0xb0a1
.4byte 0x90828293  # addi x5, x5, -1784
.4byte 0x3b72ee57  # vslide1up.vx v28, v23, x5
.4byte 0x5e0e0bd7  # vmv.v.v v23, v28
.4byte 0x070602b7  # lui x5, 0x7060
.4byte 0x50428293  # addi x5, x5, 1284
.4byte 0x3b72ee57  # vslide1up.vx v28, v23, x5
.4byte 0x5e0e0bd7  # vmv.v.v v23, v28
.4byte 0x030202b7  # lui x5, 0x3020
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b72ee57  # vslide1up.vx v28, v23, x5
.4byte 0x5e0e0bd7  # vmv.v.v v23, v28
.4byte 0xab50abf7  # vaeskf2.vi v23, v21, 1
.assert trap == 0 "vaeskf2.vi uimm=1 retires"
.4byte 0x43702557  # vmv.x.s x10, v23
.assert rd_addr == 10 "vaeskf2.vi uimm=1 w0 writes x10"
.assert rd_wdata == 0xffffffffddb84106 "vaeskf2.vi uimm=1 w0"
.4byte 0x3f70bc57  # vslidedown.vi v24, v23, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf2.vi uimm=1 w1 writes x10"
.assert rd_wdata == 0xffffffffdabe4402 "vaeskf2.vi uimm=1 w1"
.4byte 0x3f713c57  # vslidedown.vi v24, v23, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf2.vi uimm=1 w2 writes x10"
.assert rd_wdata == 0xffffffffd1b44d0a "vaeskf2.vi uimm=1 w2"
.4byte 0x3f71bc57  # vslidedown.vi v24, v23, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf2.vi uimm=1 w3 writes x10"
.assert rd_wdata == 0xffffffffdeba4006 "vaeskf2.vi uimm=1 w3"
.4byte 0x0f0e12b7  # lui x5, 0xf0e1
.4byte 0xd0c28293  # addi x5, x5, -756
.4byte 0x5e02cbd7  # vmv.v.x v23, x5
.4byte 0x0b0a12b7  # lui x5, 0xb0a1
.4byte 0x90828293  # addi x5, x5, -1784
.4byte 0x3b72ee57  # vslide1up.vx v28, v23, x5
.4byte 0x5e0e0bd7  # vmv.v.v v23, v28
.4byte 0x070602b7  # lui x5, 0x7060
.4byte 0x50428293  # addi x5, x5, 1284
.4byte 0x3b72ee57  # vslide1up.vx v28, v23, x5
.4byte 0x5e0e0bd7  # vmv.v.v v23, v28
.4byte 0x030202b7  # lui x5, 0x3020
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b72ee57  # vslide1up.vx v28, v23, x5
.4byte 0x5e0e0bd7  # vmv.v.v v23, v28
.4byte 0xab57abf7  # vaeskf2.vi v23, v21, 15
.assert trap == 0 "vaeskf2.vi uimm=15 retires"
.4byte 0x43702557  # vmv.x.s x10, v23
.assert rd_addr == 10 "vaeskf2.vi uimm=15 w0 writes x10"
.assert rd_wdata == 0xffffffffddb84106 "vaeskf2.vi uimm=15 w0"
.4byte 0x3f70bc57  # vslidedown.vi v24, v23, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf2.vi uimm=15 w1 writes x10"
.assert rd_wdata == 0xffffffffdabe4402 "vaeskf2.vi uimm=15 w1"
.4byte 0x3f713c57  # vslidedown.vi v24, v23, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf2.vi uimm=15 w2 writes x10"
.assert rd_wdata == 0xffffffffd1b44d0a "vaeskf2.vi uimm=15 w2"
.4byte 0x3f71bc57  # vslidedown.vi v24, v23, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf2.vi uimm=15 w3 writes x10"
.assert rd_wdata == 0xffffffffdeba4006 "vaeskf2.vi uimm=15 w3"
.4byte 0x0f0e12b7  # lui x5, 0xf0e1
.4byte 0xd0c28293  # addi x5, x5, -756
.4byte 0x5e02cbd7  # vmv.v.x v23, x5
.4byte 0x0b0a12b7  # lui x5, 0xb0a1
.4byte 0x90828293  # addi x5, x5, -1784
.4byte 0x3b72ee57  # vslide1up.vx v28, v23, x5
.4byte 0x5e0e0bd7  # vmv.v.v v23, v28
.4byte 0x070602b7  # lui x5, 0x7060
.4byte 0x50428293  # addi x5, x5, 1284
.4byte 0x3b72ee57  # vslide1up.vx v28, v23, x5
.4byte 0x5e0e0bd7  # vmv.v.v v23, v28
.4byte 0x030202b7  # lui x5, 0x3020
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b72ee57  # vslide1up.vx v28, v23, x5
.4byte 0x5e0e0bd7  # vmv.v.v v23, v28
.4byte 0xab5a2bf7  # vaeskf2.vi v23, v21, 20
.assert trap == 0 "vaeskf2.vi uimm=20 retires"
.4byte 0x43702557  # vmv.x.s x10, v23
.assert rd_addr == 10 "vaeskf2.vi uimm=20 w0 writes x10"
.assert rd_wdata == 0x5dcbb42 "vaeskf2.vi uimm=20 w0"
.4byte 0x3f70bc57  # vslidedown.vi v24, v23, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf2.vi uimm=20 w1 writes x10"
.assert rd_wdata == 0x2dabe46 "vaeskf2.vi uimm=20 w1"
.4byte 0x3f713c57  # vslidedown.vi v24, v23, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf2.vi uimm=20 w2 writes x10"
.assert rd_wdata == 0x9d0b74e "vaeskf2.vi uimm=20 w2"
.4byte 0x3f71bc57  # vslidedown.vi v24, v23, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaeskf2.vi uimm=20 w3 writes x10"
.assert rd_wdata == 0x6deba42 "vaeskf2.vi uimm=20 w3"
# Multi-group e32 m2 vl=8: all 4 AES .vv forms vs .vs broadcast, plus vstart=4 restart and tu tail.
.4byte 0xc1147657  # vsetivli x12, 8, e32, m2, tu, mu
.assert rd_addr == 12 "vsetivli e32 m2 vl=8 writes x12"
.assert rd_wdata == 0x8 "vsetivli e32 m2 vl=8"
.4byte 0x057672b7  # lui x5, 0x5767
.4byte 0xc2a28293  # addi x5, x5, -982
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x3939a2b7  # lui x5, 0x3939a
.4byte 0x32328293  # addi x5, x5, 803
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xb12c52b7  # lui x5, 0xb12c5
.4byte 0x48828293  # addi x5, x5, 1160
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x17ff02b7  # lui x5, 0x17ff0
.4byte 0xaa028293  # addi x5, x5, -1376
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x3c4fd2b7  # lui x5, 0x3c4fd
.4byte 0xf0928293  # addi x5, x5, -247
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x8815f2b7  # lui x5, 0x8815f
.4byte 0x7ab28293  # addi x5, x5, 1963
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xa6d2b2b7  # lui x5, 0xa6d2b
.4byte 0xe2828293  # addi x5, x5, -472
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x161582b7  # lui x5, 0x16158
.4byte 0xe2b28293  # addi x5, x5, -469
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 0 "vaesem.vv m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesem.vv m2 w0 writes x10"
.assert rd_wdata == 0xffffffffbb2ce8ea "vaesem.vv m2 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv m2 w1 writes x10"
.assert rd_wdata == 0x6c1d69ee "vaesem.vv m2 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv m2 w2 writes x10"
.assert rd_wdata == 0xffffffffb82b8494 "vaesem.vv m2 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv m2 w3 writes x10"
.assert rd_wdata == 0x6ef22cc0 "vaesem.vv m2 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv m2 w4 writes x10"
.assert rd_wdata == 0xffffffffce1883c3 "vaesem.vv m2 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv m2 w5 writes x10"
.assert rd_wdata == 0xffffffffc7d7337c "vaesem.vv m2 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv m2 w6 writes x10"
.assert rd_wdata == 0xffffffffcd05a58e "vaesem.vv m2 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv m2 w7 writes x10"
.assert rd_wdata == 0xffffffffa6fc87f8 "vaesem.vv m2 w7"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa6812877  # vaesem.vs v16, v8
.assert trap == 0 "vaesem.vs m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesem.vs m2 broadcast w0 writes x10"
.assert rd_wdata == 0xffffffffbb2ce8ea "vaesem.vs m2 broadcast w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vs m2 broadcast w1 writes x10"
.assert rd_wdata == 0x6c1d69ee "vaesem.vs m2 broadcast w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vs m2 broadcast w2 writes x10"
.assert rd_wdata == 0xffffffffb82b8494 "vaesem.vs m2 broadcast w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vs m2 broadcast w3 writes x10"
.assert rd_wdata == 0x6ef22cc0 "vaesem.vs m2 broadcast w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vs m2 broadcast w4 writes x10"
.assert rd_wdata == 0xffffffffcff30748 "vaesem.vs m2 broadcast w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vs m2 broadcast w5 writes x10"
.assert rd_wdata == 0xffffffffd029c9dc "vaesem.vs m2 broadcast w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vs m2 broadcast w6 writes x10"
.assert rd_wdata == 0x7c29f106 "vaesem.vs m2 broadcast w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vs m2 broadcast w7 writes x10"
.assert rd_wdata == 0xffffffff9fc524db "vaesem.vs m2 broadcast w7"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa281a877  # vaesef.vv v16, v8
.assert trap == 0 "vaesef.vv m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesef.vv m2 w0 writes x10"
.assert rd_wdata == 0xe53c008 "vaesef.vv m2 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv m2 w1 writes x10"
.assert rd_wdata == 0x641769ec "vaesef.vv m2 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv m2 w2 writes x10"
.assert rd_wdata == 0xffffffffd5576d6c "vaesef.vv m2 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv m2 w3 writes x10"
.assert rd_wdata == 0x64bd5e8 "vaesef.vv m2 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv m2 w4 writes x10"
.assert rd_wdata == 0x15206c3 "vaesef.vv m2 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv m2 w5 writes x10"
.assert rd_wdata == 0x7204ba93 "vaesef.vv m2 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv m2 w6 writes x10"
.assert rd_wdata == 0xffffffffccaa62e7 "vaesef.vv m2 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv m2 w7 writes x10"
.assert rd_wdata == 0xffffffffef45ee61 "vaesef.vv m2 w7"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa681a877  # vaesef.vs v16, v8
.assert trap == 0 "vaesef.vs m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesef.vs m2 broadcast w0 writes x10"
.assert rd_wdata == 0xe53c008 "vaesef.vs m2 broadcast w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vs m2 broadcast w1 writes x10"
.assert rd_wdata == 0x641769ec "vaesef.vs m2 broadcast w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vs m2 broadcast w2 writes x10"
.assert rd_wdata == 0xffffffffd5576d6c "vaesef.vs m2 broadcast w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vs m2 broadcast w3 writes x10"
.assert rd_wdata == 0x64bd5e8 "vaesef.vs m2 broadcast w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vs m2 broadcast w4 writes x10"
.assert rd_wdata == 0xb98248 "vaesef.vs m2 broadcast w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vs m2 broadcast w5 writes x10"
.assert rd_wdata == 0x65fa4033 "vaesef.vs m2 broadcast w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vs m2 broadcast w6 writes x10"
.assert rd_wdata == 0x7d86366f "vaesef.vs m2 broadcast w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vs m2 broadcast w7 writes x10"
.assert rd_wdata == 0xffffffffd67c4d42 "vaesef.vs m2 broadcast w7"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa2802877  # vaesdm.vv v16, v8
.assert trap == 0 "vaesdm.vv m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesdm.vv m2 w0 writes x10"
.assert rd_wdata == 0xffffffffda399262 "vaesdm.vv m2 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vv m2 w1 writes x10"
.assert rd_wdata == 0x5929693a "vaesdm.vv m2 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vv m2 w2 writes x10"
.assert rd_wdata == 0x77dfc837 "vaesdm.vv m2 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vv m2 w3 writes x10"
.assert rd_wdata == 0xffffffffc870c226 "vaesdm.vv m2 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vv m2 w4 writes x10"
.assert rd_wdata == 0x6608d0f6 "vaesdm.vv m2 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vv m2 w5 writes x10"
.assert rd_wdata == 0x6ded13d0 "vaesdm.vv m2 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vv m2 w6 writes x10"
.assert rd_wdata == 0x1c8b30b4 "vaesdm.vv m2 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vv m2 w7 writes x10"
.assert rd_wdata == 0xffffffffd23c9828 "vaesdm.vv m2 w7"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa6802877  # vaesdm.vs v16, v8
.assert trap == 0 "vaesdm.vs m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesdm.vs m2 broadcast w0 writes x10"
.assert rd_wdata == 0xffffffffda399262 "vaesdm.vs m2 broadcast w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vs m2 broadcast w1 writes x10"
.assert rd_wdata == 0x5929693a "vaesdm.vs m2 broadcast w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vs m2 broadcast w2 writes x10"
.assert rd_wdata == 0x77dfc837 "vaesdm.vs m2 broadcast w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vs m2 broadcast w3 writes x10"
.assert rd_wdata == 0xffffffffc870c226 "vaesdm.vs m2 broadcast w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vs m2 broadcast w4 writes x10"
.assert rd_wdata == 0xffffffffc63b2474 "vaesdm.vs m2 broadcast w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vs m2 broadcast w5 writes x10"
.assert rd_wdata == 0xffffffffcae524fb "vaesdm.vs m2 broadcast w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vs m2 broadcast w6 writes x10"
.assert rd_wdata == 0x195f5246 "vaesdm.vs m2 broadcast w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdm.vs m2 broadcast w7 writes x10"
.assert rd_wdata == 0x6d81a694 "vaesdm.vs m2 broadcast w7"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa280a877  # vaesdf.vv v16, v8
.assert trap == 0 "vaesdf.vv m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesdf.vv m2 w0 writes x10"
.assert rd_wdata == 0xffffffffa2f7cc8a "vaesdf.vv m2 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vv m2 w1 writes x10"
.assert rd_wdata == 0xffffffffbceacabf "vaesdf.vv m2 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vv m2 w2 writes x10"
.assert rd_wdata == 0xffffffffa0c3b185 "vaesdf.vv m2 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vv m2 w3 writes x10"
.assert rd_wdata == 0x5347e1a9 "vaesdf.vv m2 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vv m2 w4 writes x10"
.assert rd_wdata == 0x159c33f2 "vaesdf.vv m2 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vv m2 w5 writes x10"
.assert rd_wdata == 0x4fb5b70e "vaesdf.vv m2 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vv m2 w6 writes x10"
.assert rd_wdata == 0x44ad4eb4 "vaesdf.vv m2 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vv m2 w7 writes x10"
.assert rd_wdata == 0x63a5950d "vaesdf.vv m2 w7"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa680a877  # vaesdf.vs v16, v8
.assert trap == 0 "vaesdf.vs m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesdf.vs m2 broadcast w0 writes x10"
.assert rd_wdata == 0xffffffffa2f7cc8a "vaesdf.vs m2 broadcast w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vs m2 broadcast w1 writes x10"
.assert rd_wdata == 0xffffffffbceacabf "vaesdf.vs m2 broadcast w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vs m2 broadcast w2 writes x10"
.assert rd_wdata == 0xffffffffa0c3b185 "vaesdf.vs m2 broadcast w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vs m2 broadcast w3 writes x10"
.assert rd_wdata == 0x5347e1a9 "vaesdf.vs m2 broadcast w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vs m2 broadcast w4 writes x10"
.assert rd_wdata == 0x1477b779 "vaesdf.vs m2 broadcast w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vs m2 broadcast w5 writes x10"
.assert rd_wdata == 0x584b4dae "vaesdf.vs m2 broadcast w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vs m2 broadcast w6 writes x10"
.assert rd_wdata == 0xfffffffff5811a3c "vaesdf.vs m2 broadcast w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesdf.vs m2 broadcast w7 writes x10"
.assert rd_wdata == 0x5a9c362e "vaesdf.vs m2 broadcast w7"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00825073  # csrwi vstart, 4
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 0 "vaesem.vv vstart=4 vl=8 retires"
.4byte 0x00802573  # csrr x10, vstart
.assert rd_addr == 10 "vstart cleared to 0 after vaesem.vv writes x10"
.assert rd_wdata == 0x0 "vstart cleared to 0 after vaesem.vv"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesem.vv vstart=4 w0 writes x10"
.assert rd_wdata == 0xffffffffa8f64332 "vaesem.vv vstart=4 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv vstart=4 w1 writes x10"
.assert rd_wdata == 0xffffffff8d305a88 "vaesem.vv vstart=4 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv vstart=4 w2 writes x10"
.assert rd_wdata == 0xffffffffa2983131 "vaesem.vv vstart=4 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv vstart=4 w3 writes x10"
.assert rd_wdata == 0x340737e0 "vaesem.vv vstart=4 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv vstart=4 w4 writes x10"
.assert rd_wdata == 0xffffffffce1883c3 "vaesem.vv vstart=4 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv vstart=4 w5 writes x10"
.assert rd_wdata == 0xffffffffc7d7337c "vaesem.vv vstart=4 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv vstart=4 w6 writes x10"
.assert rd_wdata == 0xffffffffcd05a58e "vaesem.vv vstart=4 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesem.vv vstart=4 w7 writes x10"
.assert rd_wdata == 0xffffffffa6fc87f8 "vaesem.vv vstart=4 w7"
.4byte 0xffeee2b7  # lui x5, 0xffeee
.4byte 0xdcc28293  # addi x5, x5, -564
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0xbbaaa2b7  # lui x5, 0xbbaaa
.4byte 0x98828293  # addi x5, x5, -1656
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x776652b7  # lui x5, 0x77665
.4byte 0x54428293  # addi x5, x5, 1348
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x332212b7  # lui x5, 0x33221
.4byte 0x10028293  # addi x5, x5, 256
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x340732b7  # lui x5, 0x34073
.4byte 0x7e028293  # addi x5, x5, 2016
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa29832b7  # lui x5, 0xa2983
.4byte 0x13128293  # addi x5, x5, 305
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x8d3062b7  # lui x5, 0x8d306
.4byte 0xa8828293  # addi x5, x5, -1400
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa8f642b7  # lui x5, 0xa8f64
.4byte 0x33228293  # addi x5, x5, 818
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0xa281a877  # vaesef.vv v16, v8
.assert trap == 0 "vaesef.vv tu vl=4 m2 retires"
.4byte 0xc1147657  # vsetivli x12, 8, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vaesef.vv tu tail w0 writes x10"
.assert rd_wdata == 0xe53c008 "vaesef.vv tu tail w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv tu tail w1 writes x10"
.assert rd_wdata == 0x641769ec "vaesef.vv tu tail w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv tu tail w2 writes x10"
.assert rd_wdata == 0xffffffffd5576d6c "vaesef.vv tu tail w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv tu tail w3 writes x10"
.assert rd_wdata == 0x64bd5e8 "vaesef.vv tu tail w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv tu tail w4 writes x10"
.assert rd_wdata == 0x33221100 "vaesef.vv tu tail w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv tu tail w5 writes x10"
.assert rd_wdata == 0x77665544 "vaesef.vv tu tail w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv tu tail w6 writes x10"
.assert rd_wdata == 0xffffffffbbaa9988 "vaesef.vv tu tail w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vaesef.vv tu tail w7 writes x10"
.assert rd_wdata == 0xffffffffffeeddcc "vaesef.vv tu tail w7"
.4byte 0xcd107657  # vsetivli x12, 0, e32, m2, ta, ma
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 0 "vaesem.vv vl=0 retires"
.4byte 0xa683a877  # vaesz.vs v16, v8
.assert trap == 0 "vaesz.vs vl=0 retires"
.4byte 0xc1127657  # vsetivli x12, 4, e32, m2, tu, mu
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "AES vl=0 preserves v16 w0 writes x10"
.assert rd_wdata == 0xe53c008 "AES vl=0 preserves v16 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "AES vl=0 preserves v16 w1 writes x10"
.assert rd_wdata == 0x641769ec "AES vl=0 preserves v16 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "AES vl=0 preserves v16 w2 writes x10"
.assert rd_wdata == 0xffffffffd5576d6c "AES vl=0 preserves v16 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "AES vl=0 preserves v16 w3 writes x10"
.assert rd_wdata == 0x64bd5e8 "AES vl=0 preserves v16 w3"
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0x3c4fd2b7  # lui x5, 0x3c4fd
.4byte 0xf0928293  # addi x5, x5, -247
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0x8815f2b7  # lui x5, 0x8815f
.4byte 0x7ab28293  # addi x5, x5, 1963
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xa6d2b2b7  # lui x5, 0xa6d2b
.4byte 0xe2828293  # addi x5, x5, -472
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x161582b7  # lui x5, 0x16158
.4byte 0xe2b28293  # addi x5, x5, -469
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xa3412a77  # vaesem.vv v20, v20
.assert trap == 0 "in-place vaesem.vv v20, v20 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "in-place vaesem.vv w0 writes x10"
.assert rd_wdata == 0x6e945c57 "in-place vaesem.vv w0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "in-place vaesem.vv w1 writes x10"
.assert rd_wdata == 0xffffffff98549a3b "in-place vaesem.vv w1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "in-place vaesem.vv w2 writes x10"
.assert rd_wdata == 0xffffffffb5235597 "in-place vaesem.vv w2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "in-place vaesem.vv w3 writes x10"
.assert rd_wdata == 0xffffffffea9b3374 "in-place vaesem.vv w3"
.4byte 0x8b42aa77  # vaeskf1.vi v20, v20, 5
.assert trap == 0 "in-place vaeskf1.vi v20, v20, 5 retires"
.4byte 0x01007fd7  # vsetvli x31, x0, e32, m1, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 0 "vaesem.vv VLMAX m1 retires"
.4byte 0x01107fd7  # vsetvli x31, x0, e32, m2, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 0 "vaesem.vv VLMAX m2 retires"
.4byte 0x01207fd7  # vsetvli x31, x0, e32, m4, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 0 "vaesem.vv VLMAX m4 retires"
.4byte 0x01307fd7  # vsetvli x31, x0, e32, m8, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 0 "vaesem.vv VLMAX m8 retires"

# Section 3: Zvkg vgmul.vv & vghsh.vv (GCM KAT, multi-group m2, vstart=4, in-place, vl=0).
.4byte 0xc1147657  # vsetivli x12, 8, e32, m2, tu, mu
.4byte 0xefcdb2b7  # lui x5, 0xefcdb
.4byte 0xb8928293  # addi x5, x5, -1143
.4byte 0x5e02c457  # vmv.v.x v8, x5
.4byte 0x674522b7  # lui x5, 0x67452
.4byte 0x30128293  # addi x5, x5, 769
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xefcdb2b7  # lui x5, 0xefcdb
.4byte 0xb8928293  # addi x5, x5, -1143
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x674522b7  # lui x5, 0x67452
.4byte 0x30128293  # addi x5, x5, 769
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x2e2b32b7  # lui x5, 0x2e2b3
.4byte 0x4ca28293  # addi x5, x5, 1226
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x59fa52b7  # lui x5, 0x59fa5
.4byte 0xc8828293  # addi x5, x5, -888
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0x3b2c92b7  # lui x5, 0x3b2c9
.4byte 0xaef28293  # addi x5, x5, -1297
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xd44bf2b7  # lui x5, 0xd44bf
.4byte 0x96628293  # addi x5, x5, -1690
.4byte 0x3a82ee57  # vslide1up.vx v28, v8, x5
.4byte 0x5e0e0457  # vmv.v.v v8, v28
.4byte 0xf0f012b7  # lui x5, 0xf0f01
.4byte 0xf0f28293  # addi x5, x5, -241
.4byte 0x5e02c657  # vmv.v.x v12, x5
.4byte 0xcc33d2b7  # lui x5, 0xcc33d
.4byte 0xc3328293  # addi x5, x5, -973
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x55aa52b7  # lui x5, 0x55aa5
.4byte 0x5aa28293  # addi x5, x5, 1450
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x00ff02b7  # lui x5, 0xff0
.4byte 0x0ff28293  # addi x5, x5, 255
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x103252b7  # lui x5, 0x10325
.4byte 0x47628293  # addi x5, x5, 1142
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x98bae2b7  # lui x5, 0x98bae
.4byte 0xcfe28293  # addi x5, x5, -770
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xf0dec2b7  # lui x5, 0xf0dec
.4byte 0xc9a28293  # addi x5, x5, -870
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0x785632b7  # lui x5, 0x78563
.4byte 0x41228293  # addi x5, x5, 1042
.4byte 0x3ac2ee57  # vslide1up.vx v28, v12, x5
.4byte 0x5e0e0657  # vmv.v.v v12, v28
.4byte 0xd2c3b2b7  # lui x5, 0xd2c3b
.4byte 0x4a528293  # addi x5, x5, 1189
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x968782b7  # lui x5, 0x96878
.4byte 0x86928293  # addi x5, x5, -1943
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5a4b42b7  # lui x5, 0x5a4b4
.4byte 0xc2d28293  # addi x5, x5, -979
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1e0f62b7  # lui x5, 0x1e0f6
.4byte 0xaa528293  # addi x5, x5, -1371
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x78feb2b7  # lui x5, 0x78feb
.4byte 0x27128293  # addi x5, x5, 625
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xb9c232b7  # lui x5, 0xb9c23
.4byte 0x8f328293  # addi x5, x5, -1805
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x92a3b2b7  # lui x5, 0x92a3b
.4byte 0x66028293  # addi x5, x5, 1632
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xceda92b7  # lui x5, 0xceda9
.4byte 0x80328293  # addi x5, x5, -2045
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xa288a877  # vgmul.vv v16, v8
.assert trap == 0 "vgmul.vv m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vgmul.vv m2 w0 writes x10"
.assert rd_wdata == 0x46c72e5e "vgmul.vv m2 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vgmul.vv m2 w1 writes x10"
.assert rd_wdata == 0xffffffff88627091 "vgmul.vv m2 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vgmul.vv m2 w2 writes x10"
.assert rd_wdata == 0x68b0852c "vgmul.vv m2 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vgmul.vv m2 w3 writes x10"
.assert rd_wdata == 0xffffffffb7de5353 "vgmul.vv m2 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vgmul.vv m2 w4 writes x10"
.assert rd_wdata == 0x5a924a2c "vgmul.vv m2 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vgmul.vv m2 w5 writes x10"
.assert rd_wdata == 0xa327364 "vgmul.vv m2 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vgmul.vv m2 w6 writes x10"
.assert rd_wdata == 0x3cda23bc "vgmul.vv m2 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vgmul.vv m2 w7 writes x10"
.assert rd_wdata == 0xd03a584 "vgmul.vv m2 w7"
.4byte 0xd2c3b2b7  # lui x5, 0xd2c3b
.4byte 0x4a528293  # addi x5, x5, 1189
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x968782b7  # lui x5, 0x96878
.4byte 0x86928293  # addi x5, x5, -1943
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5a4b42b7  # lui x5, 0x5a4b4
.4byte 0xc2d28293  # addi x5, x5, -979
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1e0f62b7  # lui x5, 0x1e0f6
.4byte 0xaa528293  # addi x5, x5, -1371
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x78feb2b7  # lui x5, 0x78feb
.4byte 0x27128293  # addi x5, x5, 625
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xb9c232b7  # lui x5, 0xb9c23
.4byte 0x8f328293  # addi x5, x5, -1805
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x92a3b2b7  # lui x5, 0x92a3b
.4byte 0x66028293  # addi x5, x5, 1632
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xceda92b7  # lui x5, 0xceda9
.4byte 0x80328293  # addi x5, x5, -2045
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 0 "vghsh.vv m2 vl=8 retires"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vghsh.vv m2 w0 writes x10"
.assert rd_wdata == 0x109a55c3 "vghsh.vv m2 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv m2 w1 writes x10"
.assert rd_wdata == 0xffffffff9bcfe6b4 "vghsh.vv m2 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv m2 w2 writes x10"
.assert rd_wdata == 0x7d89f35a "vghsh.vv m2 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv m2 w3 writes x10"
.assert rd_wdata == 0x2a13cc70 "vghsh.vv m2 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv m2 w4 writes x10"
.assert rd_wdata == 0xffffffff87ba2445 "vghsh.vv m2 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv m2 w5 writes x10"
.assert rd_wdata == 0x8bd0ce8 "vghsh.vv m2 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv m2 w6 writes x10"
.assert rd_wdata == 0x2816ece5 "vghsh.vv m2 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv m2 w7 writes x10"
.assert rd_wdata == 0xffffffffe02e7d55 "vghsh.vv m2 w7"
.4byte 0xd2c3b2b7  # lui x5, 0xd2c3b
.4byte 0x4a528293  # addi x5, x5, 1189
.4byte 0x5e02c857  # vmv.v.x v16, x5
.4byte 0x968782b7  # lui x5, 0x96878
.4byte 0x86928293  # addi x5, x5, -1943
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x5a4b42b7  # lui x5, 0x5a4b4
.4byte 0xc2d28293  # addi x5, x5, -979
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x1e0f62b7  # lui x5, 0x1e0f6
.4byte 0xaa528293  # addi x5, x5, -1371
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x78feb2b7  # lui x5, 0x78feb
.4byte 0x27128293  # addi x5, x5, 625
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xb9c232b7  # lui x5, 0xb9c23
.4byte 0x8f328293  # addi x5, x5, -1805
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x92a3b2b7  # lui x5, 0x92a3b
.4byte 0x66028293  # addi x5, x5, 1632
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0xceda92b7  # lui x5, 0xceda9
.4byte 0x80328293  # addi x5, x5, -2045
.4byte 0x3b02ee57  # vslide1up.vx v28, v16, x5
.4byte 0x5e0e0857  # vmv.v.v v16, v28
.4byte 0x00825073  # csrwi vstart, 4
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 0 "vghsh.vv vstart=4 vl=8 retires"
.4byte 0x00802573  # csrr x10, vstart
.assert rd_addr == 10 "vstart cleared after vghsh.vv writes x10"
.assert rd_wdata == 0x0 "vstart cleared after vghsh.vv"
.4byte 0x43002557  # vmv.x.s x10, v16
.assert rd_addr == 10 "vghsh.vv vstart=4 w0 writes x10"
.assert rd_wdata == 0xffffffffceda8803 "vghsh.vv vstart=4 w0"
.4byte 0x3f00bc57  # vslidedown.vi v24, v16, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv vstart=4 w1 writes x10"
.assert rd_wdata == 0xffffffff92a3b660 "vghsh.vv vstart=4 w1"
.4byte 0x3f013c57  # vslidedown.vi v24, v16, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv vstart=4 w2 writes x10"
.assert rd_wdata == 0xffffffffb9c228f3 "vghsh.vv vstart=4 w2"
.4byte 0x3f01bc57  # vslidedown.vi v24, v16, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv vstart=4 w3 writes x10"
.assert rd_wdata == 0x78feb271 "vghsh.vv vstart=4 w3"
.4byte 0x3f023c57  # vslidedown.vi v24, v16, 4
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv vstart=4 w4 writes x10"
.assert rd_wdata == 0xffffffff87ba2445 "vghsh.vv vstart=4 w4"
.4byte 0x3f02bc57  # vslidedown.vi v24, v16, 5
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv vstart=4 w5 writes x10"
.assert rd_wdata == 0x8bd0ce8 "vghsh.vv vstart=4 w5"
.4byte 0x3f033c57  # vslidedown.vi v24, v16, 6
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv vstart=4 w6 writes x10"
.assert rd_wdata == 0x2816ece5 "vghsh.vv vstart=4 w6"
.4byte 0x3f03bc57  # vslidedown.vi v24, v16, 7
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "vghsh.vv vstart=4 w7 writes x10"
.assert rd_wdata == 0xffffffffe02e7d55 "vghsh.vv vstart=4 w7"
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0x2e2b32b7  # lui x5, 0x2e2b3
.4byte 0x4ca28293  # addi x5, x5, 1226
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0x59fa52b7  # lui x5, 0x59fa5
.4byte 0xc8828293  # addi x5, x5, -888
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x3b2c92b7  # lui x5, 0x3b2c9
.4byte 0xaef28293  # addi x5, x5, -1297
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xd44bf2b7  # lui x5, 0xd44bf
.4byte 0x96628293  # addi x5, x5, -1690
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xa348aa77  # vgmul.vv v20, v20
.assert trap == 0 "in-place vgmul.vv v20, v20 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "in-place vgmul.vv w0 writes x10"
.assert rd_wdata == 0x1b9069a5 "in-place vgmul.vv w0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "in-place vgmul.vv w1 writes x10"
.assert rd_wdata == 0x689b1b4 "in-place vgmul.vv w1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "in-place vgmul.vv w2 writes x10"
.assert rd_wdata == 0x249d05f5 "in-place vgmul.vv w2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "in-place vgmul.vv w3 writes x10"
.assert rd_wdata == 0x4d905c46 "in-place vgmul.vv w3"
.4byte 0x78feb2b7  # lui x5, 0x78feb
.4byte 0x27128293  # addi x5, x5, 625
.4byte 0x5e02ca57  # vmv.v.x v20, x5
.4byte 0xb9c232b7  # lui x5, 0xb9c23
.4byte 0x8f328293  # addi x5, x5, -1805
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0x92a3b2b7  # lui x5, 0x92a3b
.4byte 0x66028293  # addi x5, x5, 1632
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xceda92b7  # lui x5, 0xceda9
.4byte 0x80328293  # addi x5, x5, -2045
.4byte 0x3b42ee57  # vslide1up.vx v28, v20, x5
.4byte 0x5e0e0a57  # vmv.v.v v20, v28
.4byte 0xb28a2a77  # vghsh.vv v20, v8, v20
.assert trap == 0 "in-place vghsh.vv vd==vs1 retires"
.4byte 0x43402557  # vmv.x.s x10, v20
.assert rd_addr == 10 "in-place vghsh.vv vd==vs1 w0 writes x10"
.assert rd_wdata == 0x0 "in-place vghsh.vv vd==vs1 w0"
.4byte 0x3f40bc57  # vslidedown.vi v24, v20, 1
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "in-place vghsh.vv vd==vs1 w1 writes x10"
.assert rd_wdata == 0x0 "in-place vghsh.vv vd==vs1 w1"
.4byte 0x3f413c57  # vslidedown.vi v24, v20, 2
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "in-place vghsh.vv vd==vs1 w2 writes x10"
.assert rd_wdata == 0x0 "in-place vghsh.vv vd==vs1 w2"
.4byte 0x3f41bc57  # vslidedown.vi v24, v20, 3
.4byte 0x43802557  # vmv.x.s x10, v24
.assert rd_addr == 10 "in-place vghsh.vv vd==vs1 w3 writes x10"
.assert rd_wdata == 0x0 "in-place vghsh.vv vd==vs1 w3"
.4byte 0xc1007657  # vsetivli x12, 0, e32, m1, tu, mu
.4byte 0xa288aa77  # vgmul.vv v20, v8
.assert trap == 0 "vgmul.vv vl=0 retires"
.4byte 0xb2862a77  # vghsh.vv v20, v8, v12
.assert trap == 0 "vghsh.vv vl=0 retires"

# Section 4: OP-VE illegal traps (SEW!=32, vm=0, vl%4!=0, vstart%4!=0, EGW>VLEN*LMUL, overlap, align, vill).
.4byte 0xc0027657  # vsetivli x12, 4, e8, m1, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv at e8 traps"
.4byte 0xa6812877  # vaesem.vs v16, v8
.assert trap == 1 "vaesem.vs at e8 traps"
.4byte 0x8a80a877  # vaeskf1.vi v16, v8, 1
.assert trap == 1 "vaeskf1.vi at e8 traps"
.4byte 0xaa812877  # vaeskf2.vi v16, v8, 2
.assert trap == 1 "vaeskf2.vi at e8 traps"
.4byte 0xa683a877  # vaesz.vs v16, v8
.assert trap == 1 "vaesz.vs at e8 traps"
.4byte 0xa288a877  # vgmul.vv v16, v8
.assert trap == 1 "vgmul.vv at e8 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv at e8 traps"
.4byte 0xc0827657  # vsetivli x12, 4, e16, m1, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv at e16 traps"
.4byte 0xa6812877  # vaesem.vs v16, v8
.assert trap == 1 "vaesem.vs at e16 traps"
.4byte 0x8a80a877  # vaeskf1.vi v16, v8, 1
.assert trap == 1 "vaeskf1.vi at e16 traps"
.4byte 0xaa812877  # vaeskf2.vi v16, v8, 2
.assert trap == 1 "vaeskf2.vi at e16 traps"
.4byte 0xa683a877  # vaesz.vs v16, v8
.assert trap == 1 "vaesz.vs at e16 traps"
.4byte 0xa288a877  # vgmul.vv v16, v8
.assert trap == 1 "vgmul.vv at e16 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv at e16 traps"
.4byte 0xc1927657  # vsetivli x12, 4, e64, m2, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv at e64 traps"
.4byte 0xa6812877  # vaesem.vs v16, v8
.assert trap == 1 "vaesem.vs at e64 traps"
.4byte 0x8a80a877  # vaeskf1.vi v16, v8, 1
.assert trap == 1 "vaeskf1.vi at e64 traps"
.4byte 0xaa812877  # vaeskf2.vi v16, v8, 2
.assert trap == 1 "vaeskf2.vi at e64 traps"
.4byte 0xa683a877  # vaesz.vs v16, v8
.assert trap == 1 "vaesz.vs at e64 traps"
.4byte 0xa288a877  # vgmul.vv v16, v8
.assert trap == 1 "vgmul.vv at e64 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv at e64 traps"
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0xa0812877  # vaesem.vv v16, v8 (illegal vm=0)
.assert trap == 1 "vaesem.vv vm=0 traps"
.4byte 0xa4812877  # vaesem.vs v16, v8 (illegal vm=0)
.assert trap == 1 "vaesem.vs vm=0 traps"
.4byte 0x8880a877  # vaeskf1.vi v16, v8, 1 (illegal vm=0)
.assert trap == 1 "vaeskf1.vi vm=0 traps"
.4byte 0xa088a877  # vgmul.vv v16, v8 (illegal vm=0)
.assert trap == 1 "vgmul.vv vm=0 traps"
.4byte 0xb0862877  # vghsh.vv v16, v8, v12 (illegal vm=0)
.assert trap == 1 "vghsh.vv vm=0 traps"
.4byte 0xc100f657  # vsetivli x12, 1, e32, m1, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv vl=1 traps"
.4byte 0xa6812877  # vaesem.vs v16, v8
.assert trap == 1 "vaesem.vs vl=1 traps"
.4byte 0x8a80a877  # vaeskf1.vi v16, v8, 1
.assert trap == 1 "vaeskf1.vi vl=1 traps"
.4byte 0xa288a877  # vgmul.vv v16, v8
.assert trap == 1 "vgmul.vv vl=1 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv vl=1 traps"
.4byte 0xc1017657  # vsetivli x12, 2, e32, m1, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv vl=2 traps"
.4byte 0xa6812877  # vaesem.vs v16, v8
.assert trap == 1 "vaesem.vs vl=2 traps"
.4byte 0x8a80a877  # vaeskf1.vi v16, v8, 1
.assert trap == 1 "vaeskf1.vi vl=2 traps"
.4byte 0xa288a877  # vgmul.vv v16, v8
.assert trap == 1 "vgmul.vv vl=2 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv vl=2 traps"
.4byte 0xc101f657  # vsetivli x12, 3, e32, m1, tu, mu
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv vl=3 traps"
.4byte 0xa6812877  # vaesem.vs v16, v8
.assert trap == 1 "vaesem.vs vl=3 traps"
.4byte 0x8a80a877  # vaeskf1.vi v16, v8, 1
.assert trap == 1 "vaeskf1.vi vl=3 traps"
.4byte 0xa288a877  # vgmul.vv v16, v8
.assert trap == 1 "vgmul.vv vl=3 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv vl=3 traps"
.4byte 0xc112f657  # vsetivli x12, 5, e32, m2, tu, mu
.4byte 0xa280a877  # vaesdf.vv v16, v8
.assert trap == 1 "vaesdf.vv vl=5 m2 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv vl=5 m2 traps"
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv vstart=1 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv vstart=1 traps"
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv vstart=2 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv vstart=2 traps"
.4byte 0x0081d073  # csrwi vstart, 3
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv vstart=3 traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv vstart=3 traps"
.4byte 0x00805073  # csrwi vstart, 0
# EGW > VLEN*LMUL at e32 mf2 vl=0: traps at VLEN=128 (mcause=2), legal at VLEN=256/512 (mcause=0).
.4byte 0xc1707657  # vsetivli x12, 0, e32, mf2, tu, mu
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xa2812877  # vaesem.vv v16, v8
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xa6812877  # vaesem.vs v16, v8
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0x8a80a877  # vaeskf1.vi v16, v8, 1
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xa288a877  # vgmul.vv v16, v8
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.4byte 0x34202573  # csrr x10, mcause
.4byte 0x34201073  # csrw mcause, x0
.4byte 0xc1027657  # vsetivli x12, 4, e32, m1, tu, mu
.4byte 0xa6812477  # vaesem.vs v8, v8
.assert trap == 1 "vaesem.vs vd==vs2 traps"
.4byte 0xa683a477  # vaesz.vs v8, v8
.assert trap == 1 "vaesz.vs vd==vs2 traps"
.4byte 0xc1147657  # vsetivli x12, 8, e32, m2, tu, mu
.4byte 0xa6912477  # vaesem.vs v8, v9
.assert trap == 1 "vaesem.vs m2 vd group overlaps vs2=v9 traps"
.4byte 0xa2c124f7  # vaesem.vv v9, v12
.assert trap == 1 "vaesem.vv m2 misaligned vd traps"
.4byte 0xa2d12477  # vaesem.vv v8, v13
.assert trap == 1 "vaesem.vv m2 misaligned vs2 traps"
.4byte 0xb2c7a477  # vghsh.vv v8, v12, v15
.assert trap == 1 "vghsh.vv m2 misaligned vs1 traps"
.4byte 0xc2027657  # vsetivli reserved_sew4 (sets vill)
.4byte 0xa2812877  # vaesem.vv v16, v8
.assert trap == 1 "vaesem.vv under vill traps"
.4byte 0xa288a877  # vgmul.vv v16, v8
.assert trap == 1 "vgmul.vv under vill traps"
.4byte 0xb2862877  # vghsh.vv v16, v8, v12
.assert trap == 1 "vghsh.vv under vill traps"
