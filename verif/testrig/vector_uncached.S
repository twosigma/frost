# Uncached vector loads and stores across low BRAM, MMIO, APLIC, and IMSIC windows.
.noshrink
# Enable mstatus.VS, zero v0..v31, load region bases.
.4byte 0x60000293  # addi t0, zero, 1536
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x003072d7  # vsetvli t0, zero, e8, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0
.4byte 0x00020437  # lui s0, 0x20
.4byte 0x400004b7  # lui s1, 0x40000
.4byte 0x44000937  # lui s2, 0x44000
.4byte 0x480009b7  # lui s3, 0x48000
.4byte 0x40008a37  # lui s4, 0x40008
.4byte 0x001a1a13  # slli s4, s4, 1
.4byte 0x00040ab7  # lui s5, 0x40
.4byte 0x40031b37  # lui s6, 0x40031
# 1. Unit-stride e8/e16/e32/e64 store+load in bram (s0).
.4byte 0x00140e13  # addi t3, s0, 1
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x04400313  # addi t1, zero, 68
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x02200313  # addi t1, zero, 34
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x020e0427  # vse8.v v8, (t3)
.assert trap == 0 "bram vse8 retires"
.4byte 0x000e4503  # lbu a0, 0(t3)
.assert rd_addr == 10 "bram vse8 byte 0 writes x10"
.assert rd_wdata == 0x11 "bram vse8 byte 0"
.4byte 0x001e4503  # lbu a0, 1(t3)
.assert rd_addr == 10 "bram vse8 byte 1 writes x10"
.assert rd_wdata == 0x22 "bram vse8 byte 1"
.4byte 0x002e4503  # lbu a0, 2(t3)
.assert rd_addr == 10 "bram vse8 byte 2 writes x10"
.assert rd_wdata == 0x33 "bram vse8 byte 2"
.4byte 0x003e4503  # lbu a0, 3(t3)
.assert rd_addr == 10 "bram vse8 byte 3 writes x10"
.assert rd_wdata == 0x44 "bram vse8 byte 3"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x020e0487  # vle8.v v9, (t3)
.assert trap == 0 "bram vle8 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram vle8 lane 0 writes x10"
.assert rd_wdata == 0x11 "bram vle8 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle8 lane 1 writes x10"
.assert rd_wdata == 0x22 "bram vle8 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle8 lane 2 writes x10"
.assert rd_wdata == 0x33 "bram vle8 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle8 lane 3 writes x10"
.assert rd_wdata == 0x44 "bram vle8 lane 3"
.4byte 0x01040e13  # addi t3, s0, 16
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0xeef30313  # addi t1, t1, -273
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x23430313  # addi t1, t1, 564
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x020e5427  # vse16.v v8, (t3)
.assert trap == 0 "bram vse16 retires"
.4byte 0x000e5503  # lhu a0, 0(t3)
.assert rd_addr == 10 "bram vse16 half 0 writes x10"
.assert rd_wdata == 0x1234 "bram vse16 half 0"
.4byte 0x002e5503  # lhu a0, 2(t3)
.assert rd_addr == 10 "bram vse16 half 1 writes x10"
.assert rd_wdata == 0xbeef "bram vse16 half 1"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x020e5487  # vle16.v v9, (t3)
.assert trap == 0 "bram vle16 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram vle16 lane 0 writes x10"
.assert rd_wdata == 0x1234 "bram vle16 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffbeef "bram vle16 lane 1"
.4byte 0x02040e13  # addi t3, s0, 32
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xddef0337  # lui t1, 0xddef0
.4byte 0xf0130313  # addi t1, t1, -255
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x99aac337  # lui t1, 0x99aac
.4byte 0xbcc30313  # addi t1, t1, -1076
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x55667337  # lui t1, 0x55667
.4byte 0x78830313  # addi t1, t1, 1928
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x020e6427  # vse32.v v8, (t3)
.assert trap == 0 "bram vse32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "bram vse32 word 0 writes x10"
.assert rd_wdata == 0x11223344 "bram vse32 word 0"
.4byte 0x004e6503  # lwu a0, 4(t3)
.assert rd_addr == 10 "bram vse32 word 1 writes x10"
.assert rd_wdata == 0x55667788 "bram vse32 word 1"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "bram vse32 word 2 writes x10"
.assert rd_wdata == 0x99aabbcc "bram vse32 word 2"
.4byte 0x00ce6503  # lwu a0, 12(t3)
.assert rd_addr == 10 "bram vse32 word 3 writes x10"
.assert rd_wdata == 0xddeeff01 "bram vse32 word 3"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x020e6487  # vle32.v v9, (t3)
.assert trap == 0 "bram vle32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram vle32 lane 0 writes x10"
.assert rd_wdata == 0x11223344 "bram vle32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle32 lane 1 writes x10"
.assert rd_wdata == 0x55667788 "bram vle32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle32 lane 2 writes x10"
.assert rd_wdata == 0xffffffff99aabbcc "bram vle32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle32 lane 3 writes x10"
.assert rd_wdata == 0xffffffffddeeff01 "bram vle32 lane 3"
.4byte 0x04040e13  # addi t3, s0, 64
.4byte 0xa5a50337  # lui t1, 0xa5a50
.4byte 0x006e2023  # sw t1, 0(t3)
.4byte 0xa5a50337  # lui t1, 0xa5a50
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x006e2223  # sw t1, 4(t3)
.4byte 0xa5a50337  # lui t1, 0xa5a50
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x006e2423  # sw t1, 8(t3)
.4byte 0xa5a50337  # lui t1, 0xa5a50
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x006e2623  # sw t1, 12(t3)
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x000e6427  # vse32.v v8, (t3), v0.t
.assert trap == 0 "bram masked vse32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "bram masked vse32 word 0 writes x10"
.assert rd_wdata == 0x70000001 "bram masked vse32 word 0"
.4byte 0x004e6503  # lwu a0, 4(t3)
.assert rd_addr == 10 "bram masked vse32 word 1 writes x10"
.assert rd_wdata == 0xa5a50001 "bram masked vse32 word 1"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "bram masked vse32 word 2 writes x10"
.assert rd_wdata == 0x70000003 "bram masked vse32 word 2"
.4byte 0x00ce6503  # lwu a0, 12(t3)
.assert rd_addr == 10 "bram masked vse32 word 3 writes x10"
.assert rd_wdata == 0xa5a50003 "bram masked vse32 word 3"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x44444337  # lui t1, 0x44444
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x3a936a57  # vslide1up.vx v20, v9, t1
.4byte 0x33333337  # lui t1, 0x33333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x3b4364d7  # vslide1up.vx v9, v20, t1
.4byte 0x22222337  # lui t1, 0x22222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x3a936a57  # vslide1up.vx v20, v9, t1
.4byte 0x11111337  # lui t1, 0x11111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x3b4364d7  # vslide1up.vx v9, v20, t1
.4byte 0x000e6487  # vle32.v v9, (t3), v0.t
.assert trap == 0 "bram masked vle32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram masked vle32 lane 0 writes x10"
.assert rd_wdata == 0x70000001 "bram masked vle32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram masked vle32 lane 1 writes x10"
.assert rd_wdata == 0x22222222 "bram masked vle32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram masked vle32 lane 2 writes x10"
.assert rd_wdata == 0x70000003 "bram masked vle32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram masked vle32 lane 3 writes x10"
.assert rd_wdata == 0x44444444 "bram masked vle32 lane 3"
.4byte 0x06040e13  # addi t3, s0, 96
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0xfedcc337  # lui t1, 0xfedcc
.4byte 0xa9830313  # addi t1, t1, -1384
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x76543fb7  # lui t6, 0x76543
.4byte 0x210f8f93  # addi t6, t6, 528
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x01234337  # lui t1, 0x1234
.4byte 0x56730313  # addi t1, t1, 1383
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x89abdfb7  # lui t6, 0x89abd
.4byte 0xdeff8f93  # addi t6, t6, -529
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x020e7427  # vse64.v v8, (t3)
.assert trap == 0 "bram vse64 retires"
.4byte 0x000e3503  # ld a0, 0(t3)
.assert rd_addr == 10 "bram vse64 dword 0 writes x10"
.assert rd_wdata == 0x123456789abcdef "bram vse64 dword 0"
.4byte 0x008e3503  # ld a0, 8(t3)
.assert rd_addr == 10 "bram vse64 dword 1 writes x10"
.assert rd_wdata == 0xfedcba9876543210 "bram vse64 dword 1"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x020e7487  # vle64.v v9, (t3)
.assert trap == 0 "bram vle64 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram vle64 lane 0 writes x10"
.assert rd_wdata == 0x123456789abcdef "bram vle64 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle64 lane 1 writes x10"
.assert rd_wdata == 0xfedcba9876543210 "bram vle64 lane 1"
# 1. Unit-stride e8/e16/e32/e64 store+load in mmio (s1).
.4byte 0x00148e13  # addi t3, s1, 1
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x04400313  # addi t1, zero, 68
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x02200313  # addi t1, zero, 34
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x020e0427  # vse8.v v8, (t3)
.assert trap == 0 "mmio vse8 retires"
.4byte 0x000e4503  # lbu a0, 0(t3)
.assert rd_addr == 10 "mmio vse8 byte 0 writes x10"
.assert rd_wdata == 0x11 "mmio vse8 byte 0"
.4byte 0x001e4503  # lbu a0, 1(t3)
.assert rd_addr == 10 "mmio vse8 byte 1 writes x10"
.assert rd_wdata == 0x22 "mmio vse8 byte 1"
.4byte 0x002e4503  # lbu a0, 2(t3)
.assert rd_addr == 10 "mmio vse8 byte 2 writes x10"
.assert rd_wdata == 0x33 "mmio vse8 byte 2"
.4byte 0x003e4503  # lbu a0, 3(t3)
.assert rd_addr == 10 "mmio vse8 byte 3 writes x10"
.assert rd_wdata == 0x44 "mmio vse8 byte 3"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x020e0487  # vle8.v v9, (t3)
.assert trap == 0 "mmio vle8 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio vle8 lane 0 writes x10"
.assert rd_wdata == 0x11 "mmio vle8 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle8 lane 1 writes x10"
.assert rd_wdata == 0x22 "mmio vle8 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle8 lane 2 writes x10"
.assert rd_wdata == 0x33 "mmio vle8 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle8 lane 3 writes x10"
.assert rd_wdata == 0x44 "mmio vle8 lane 3"
.4byte 0x01048e13  # addi t3, s1, 16
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0xeef30313  # addi t1, t1, -273
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x23430313  # addi t1, t1, 564
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x020e5427  # vse16.v v8, (t3)
.assert trap == 0 "mmio vse16 retires"
.4byte 0x000e5503  # lhu a0, 0(t3)
.assert rd_addr == 10 "mmio vse16 half 0 writes x10"
.assert rd_wdata == 0x1234 "mmio vse16 half 0"
.4byte 0x002e5503  # lhu a0, 2(t3)
.assert rd_addr == 10 "mmio vse16 half 1 writes x10"
.assert rd_wdata == 0xbeef "mmio vse16 half 1"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x020e5487  # vle16.v v9, (t3)
.assert trap == 0 "mmio vle16 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio vle16 lane 0 writes x10"
.assert rd_wdata == 0x1234 "mmio vle16 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle16 lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffbeef "mmio vle16 lane 1"
.4byte 0x02048e13  # addi t3, s1, 32
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xddef0337  # lui t1, 0xddef0
.4byte 0xf0130313  # addi t1, t1, -255
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x99aac337  # lui t1, 0x99aac
.4byte 0xbcc30313  # addi t1, t1, -1076
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x55667337  # lui t1, 0x55667
.4byte 0x78830313  # addi t1, t1, 1928
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x020e6427  # vse32.v v8, (t3)
.assert trap == 0 "mmio vse32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "mmio vse32 word 0 writes x10"
.assert rd_wdata == 0x11223344 "mmio vse32 word 0"
.4byte 0x004e6503  # lwu a0, 4(t3)
.assert rd_addr == 10 "mmio vse32 word 1 writes x10"
.assert rd_wdata == 0x55667788 "mmio vse32 word 1"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "mmio vse32 word 2 writes x10"
.assert rd_wdata == 0x99aabbcc "mmio vse32 word 2"
.4byte 0x00ce6503  # lwu a0, 12(t3)
.assert rd_addr == 10 "mmio vse32 word 3 writes x10"
.assert rd_wdata == 0xddeeff01 "mmio vse32 word 3"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x020e6487  # vle32.v v9, (t3)
.assert trap == 0 "mmio vle32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio vle32 lane 0 writes x10"
.assert rd_wdata == 0x11223344 "mmio vle32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle32 lane 1 writes x10"
.assert rd_wdata == 0x55667788 "mmio vle32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle32 lane 2 writes x10"
.assert rd_wdata == 0xffffffff99aabbcc "mmio vle32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle32 lane 3 writes x10"
.assert rd_wdata == 0xffffffffddeeff01 "mmio vle32 lane 3"
.4byte 0x04048e13  # addi t3, s1, 64
.4byte 0xa5a50337  # lui t1, 0xa5a50
.4byte 0x006e2023  # sw t1, 0(t3)
.4byte 0xa5a50337  # lui t1, 0xa5a50
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x006e2223  # sw t1, 4(t3)
.4byte 0xa5a50337  # lui t1, 0xa5a50
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x006e2423  # sw t1, 8(t3)
.4byte 0xa5a50337  # lui t1, 0xa5a50
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x006e2623  # sw t1, 12(t3)
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x70000337  # lui t1, 0x70000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x000e6427  # vse32.v v8, (t3), v0.t
.assert trap == 0 "mmio masked vse32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "mmio masked vse32 word 0 writes x10"
.assert rd_wdata == 0x70000001 "mmio masked vse32 word 0"
.4byte 0x004e6503  # lwu a0, 4(t3)
.assert rd_addr == 10 "mmio masked vse32 word 1 writes x10"
.assert rd_wdata == 0xa5a50001 "mmio masked vse32 word 1"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "mmio masked vse32 word 2 writes x10"
.assert rd_wdata == 0x70000003 "mmio masked vse32 word 2"
.4byte 0x00ce6503  # lwu a0, 12(t3)
.assert rd_addr == 10 "mmio masked vse32 word 3 writes x10"
.assert rd_wdata == 0xa5a50003 "mmio masked vse32 word 3"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x44444337  # lui t1, 0x44444
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x3a936a57  # vslide1up.vx v20, v9, t1
.4byte 0x33333337  # lui t1, 0x33333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x3b4364d7  # vslide1up.vx v9, v20, t1
.4byte 0x22222337  # lui t1, 0x22222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x3a936a57  # vslide1up.vx v20, v9, t1
.4byte 0x11111337  # lui t1, 0x11111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x3b4364d7  # vslide1up.vx v9, v20, t1
.4byte 0x000e6487  # vle32.v v9, (t3), v0.t
.assert trap == 0 "mmio masked vle32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio masked vle32 lane 0 writes x10"
.assert rd_wdata == 0x70000001 "mmio masked vle32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio masked vle32 lane 1 writes x10"
.assert rd_wdata == 0x22222222 "mmio masked vle32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio masked vle32 lane 2 writes x10"
.assert rd_wdata == 0x70000003 "mmio masked vle32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio masked vle32 lane 3 writes x10"
.assert rd_wdata == 0x44444444 "mmio masked vle32 lane 3"
.4byte 0x06048e13  # addi t3, s1, 96
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0xfedcc337  # lui t1, 0xfedcc
.4byte 0xa9830313  # addi t1, t1, -1384
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x76543fb7  # lui t6, 0x76543
.4byte 0x210f8f93  # addi t6, t6, 528
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x01234337  # lui t1, 0x1234
.4byte 0x56730313  # addi t1, t1, 1383
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x89abdfb7  # lui t6, 0x89abd
.4byte 0xdeff8f93  # addi t6, t6, -529
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x020e7427  # vse64.v v8, (t3)
.assert trap == 0 "mmio vse64 retires"
.4byte 0x000e3503  # ld a0, 0(t3)
.assert rd_addr == 10 "mmio vse64 dword 0 writes x10"
.assert rd_wdata == 0x123456789abcdef "mmio vse64 dword 0"
.4byte 0x008e3503  # ld a0, 8(t3)
.assert rd_addr == 10 "mmio vse64 dword 1 writes x10"
.assert rd_wdata == 0xfedcba9876543210 "mmio vse64 dword 1"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x020e7487  # vle64.v v9, (t3)
.assert trap == 0 "mmio vle64 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio vle64 lane 0 writes x10"
.assert rd_wdata == 0x123456789abcdef "mmio vle64 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle64 lane 1 writes x10"
.assert rd_wdata == 0xfedcba9876543210 "mmio vle64 lane 1"
# 2. APLIC window unit-stride e32 store+load (s2).
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x44003337  # lui t1, 0x44003
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x44001337  # lui t1, 0x44001
.4byte 0x12230313  # addi t1, t1, 290
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x02096427  # vse32.v v8, (s2)
.assert trap == 0 "aplic vse32 retires"
.4byte 0x00096503  # lwu a0, 0(s2)
.assert rd_addr == 10 "aplic vse32 word 0 writes x10"
.assert rd_wdata == 0x44001122 "aplic vse32 word 0"
.4byte 0x00496503  # lwu a0, 4(s2)
.assert rd_addr == 10 "aplic vse32 word 1 writes x10"
.assert rd_wdata == 0x44003344 "aplic vse32 word 1"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x02096487  # vle32.v v9, (s2)
.assert trap == 0 "aplic vle32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "aplic vle32 lane 0 writes x10"
.assert rd_wdata == 0x44001122 "aplic vle32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "aplic vle32 lane 1 writes x10"
.assert rd_wdata == 0x44003344 "aplic vle32 lane 1"
# 2. IMSIC window unit-stride e32 store+load (s3).
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x48007337  # lui t1, 0x48007
.4byte 0x78830313  # addi t1, t1, 1928
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x48005337  # lui t1, 0x48005
.4byte 0x56630313  # addi t1, t1, 1382
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x0209e427  # vse32.v v8, (s3)
.assert trap == 0 "imsic vse32 retires"
.4byte 0x0009e503  # lwu a0, 0(s3)
.assert rd_addr == 10 "imsic vse32 word 0 writes x10"
.assert rd_wdata == 0x48005566 "imsic vse32 word 0"
.4byte 0x0049e503  # lwu a0, 4(s3)
.assert rd_addr == 10 "imsic vse32 word 1 writes x10"
.assert rd_wdata == 0x48007788 "imsic vse32 word 1"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x0209e487  # vle32.v v9, (s3)
.assert trap == 0 "imsic vle32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "imsic vle32 lane 0 writes x10"
.assert rd_wdata == 0x48005566 "imsic vle32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "imsic vle32 lane 1 writes x10"
.assert rd_wdata == 0x48007788 "imsic vle32 lane 1"
# 3. Mask store/load (vsm.v / vlm.v) at odd offset in bram.
.4byte 0x10140e13  # addi t3, s0, 257
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x03c00313  # addi t1, zero, 60
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0xc0087657  # vsetivli a2, 16, e8, m1, tu, mu
.4byte 0x02be0427  # vsm.v v8, (t3)
.assert trap == 0 "bram vsm retires"
.4byte 0x000e4503  # lbu a0, 0(t3)
.assert rd_addr == 10 "bram vsm byte 0 writes x10"
.assert rd_wdata == 0x3c "bram vsm byte 0"
.4byte 0x001e4503  # lbu a0, 1(t3)
.assert rd_addr == 10 "bram vsm byte 1 writes x10"
.assert rd_wdata == 0x5a "bram vsm byte 1"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x02be0487  # vlm.v v9, (t3)
.assert trap == 0 "bram vlm retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram vlm byte 0 writes x10"
.assert rd_wdata == 0x3c "bram vlm byte 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vlm byte 1 writes x10"
.assert rd_wdata == 0x5a "bram vlm byte 1"
# 3. Mask store/load (vsm.v / vlm.v) at odd offset in mmio.
.4byte 0x10148e13  # addi t3, s1, 257
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x03c00313  # addi t1, zero, 60
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0xc0087657  # vsetivli a2, 16, e8, m1, tu, mu
.4byte 0x02be0427  # vsm.v v8, (t3)
.assert trap == 0 "mmio vsm retires"
.4byte 0x000e4503  # lbu a0, 0(t3)
.assert rd_addr == 10 "mmio vsm byte 0 writes x10"
.assert rd_wdata == 0x3c "mmio vsm byte 0"
.4byte 0x001e4503  # lbu a0, 1(t3)
.assert rd_addr == 10 "mmio vsm byte 1 writes x10"
.assert rd_wdata == 0x5a "mmio vsm byte 1"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x02be0487  # vlm.v v9, (t3)
.assert trap == 0 "mmio vlm retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio vlm byte 0 writes x10"
.assert rd_wdata == 0x3c "mmio vlm byte 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vlm byte 1 writes x10"
.assert rd_wdata == 0x5a "mmio vlm byte 1"
# 4. Whole-register vs1r.v / vl1re32.v in bram (under vill=1).
.4byte 0x20040e13  # addi t3, s0, 512
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x55667fb7  # lui t6, 0x55667
.4byte 0x788f8f93  # addi t6, t6, 1928
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1f0f657  # vsetivli a2, 1, e64, mf2, tu, mu
.4byte 0x028e0427  # vs1r.v v8, (t3)
.assert trap == 0 "bram vs1r under vill retires"
.4byte 0x000e3503  # ld a0, 0(t3)
.assert rd_addr == 10 "bram vs1r dw 0 writes x10"
.assert rd_wdata == 0x1122334455667788 "bram vs1r dw 0"
.4byte 0x008e3503  # ld a0, 8(t3)
.assert rd_addr == 10 "bram vs1r dw 1 writes x10"
.assert rd_wdata == 0x1122334455667788 "bram vs1r dw 1"
.4byte 0x010e3503  # ld a0, 16(t3)
.4byte 0x018e3503  # ld a0, 24(t3)
.4byte 0x020e3503  # ld a0, 32(t3)
.4byte 0x028e3503  # ld a0, 40(t3)
.4byte 0x030e3503  # ld a0, 48(t3)
.4byte 0x038e3503  # ld a0, 56(t3)
.4byte 0x028e6487  # vl1re32.v v9, (t3)
.assert trap == 0 "bram vl1re32 under vill retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram vl1re32 lane 0 writes x10"
.assert rd_wdata == 0x1122334455667788 "bram vl1re32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vl1re32 lane 1 writes x10"
.assert rd_wdata == 0x1122334455667788 "bram vl1re32 lane 1"
# 4. Whole-register vs1r.v / vl1re32.v in mmio (under vill=1).
.4byte 0x20048e13  # addi t3, s1, 512
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0xcafec337  # lui t1, 0xcafec
.4byte 0xabe30313  # addi t1, t1, -1346
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x13572fb7  # lui t6, 0x13572
.4byte 0x468f8f93  # addi t6, t6, 1128
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1f0f657  # vsetivli a2, 1, e64, mf2, tu, mu
.4byte 0x028e0427  # vs1r.v v8, (t3)
.assert trap == 0 "mmio vs1r under vill retires"
.4byte 0x000e3503  # ld a0, 0(t3)
.assert rd_addr == 10 "mmio vs1r dw 0 writes x10"
.assert rd_wdata == 0xcafebabe13572468 "mmio vs1r dw 0"
.4byte 0x008e3503  # ld a0, 8(t3)
.assert rd_addr == 10 "mmio vs1r dw 1 writes x10"
.assert rd_wdata == 0xcafebabe13572468 "mmio vs1r dw 1"
.4byte 0x010e3503  # ld a0, 16(t3)
.4byte 0x018e3503  # ld a0, 24(t3)
.4byte 0x020e3503  # ld a0, 32(t3)
.4byte 0x028e3503  # ld a0, 40(t3)
.4byte 0x030e3503  # ld a0, 48(t3)
.4byte 0x038e3503  # ld a0, 56(t3)
.4byte 0x028e6487  # vl1re32.v v9, (t3)
.assert trap == 0 "mmio vl1re32 under vill retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio vl1re32 lane 0 writes x10"
.assert rd_wdata == 0xcafebabe13572468 "mmio vl1re32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vl1re32 lane 1 writes x10"
.assert rd_wdata == 0xcafebabe13572468 "mmio vl1re32 lane 1"
# 5. Strided vsse32/vlse32 (+8, -8, 0) in bram.
.4byte 0x30040e13  # addi t3, s0, 768
.4byte 0x00800e93  # addi t4, zero, 8
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x31000337  # lui t1, 0x31000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x31000337  # lui t1, 0x31000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x31000337  # lui t1, 0x31000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x31000337  # lui t1, 0x31000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x0bde6427  # vsse32.v v8, (t3), t4
.assert trap == 0 "bram pos vsse32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "bram pos vsse32 elem 0 writes x10"
.assert rd_wdata == 0x31000001 "bram pos vsse32 elem 0"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "bram pos vsse32 elem 1 writes x10"
.assert rd_wdata == 0x31000002 "bram pos vsse32 elem 1"
.4byte 0x010e6503  # lwu a0, 16(t3)
.assert rd_addr == 10 "bram pos vsse32 elem 2 writes x10"
.assert rd_wdata == 0x31000003 "bram pos vsse32 elem 2"
.4byte 0x018e6503  # lwu a0, 24(t3)
.assert rd_addr == 10 "bram pos vsse32 elem 3 writes x10"
.assert rd_wdata == 0x31000004 "bram pos vsse32 elem 3"
.4byte 0x31840e13  # addi t3, s0, 792
.4byte 0xff800e93  # addi t4, zero, -8
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x0bde6487  # vlse32.v v9, (t3), t4
.assert trap == 0 "bram neg vlse32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram neg vlse32 lane 0 writes x10"
.assert rd_wdata == 0x31000004 "bram neg vlse32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram neg vlse32 lane 1 writes x10"
.assert rd_wdata == 0x31000003 "bram neg vlse32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram neg vlse32 lane 2 writes x10"
.assert rd_wdata == 0x31000002 "bram neg vlse32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram neg vlse32 lane 3 writes x10"
.assert rd_wdata == 0x31000001 "bram neg vlse32 lane 3"
.4byte 0x34040e13  # addi t3, s0, 832
.4byte 0x0a0e6427  # vsse32.v v8, (t3), zero
.assert trap == 0 "bram zero-stride vsse32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "bram zero-stride vsse32 word writes x10"
.assert rd_wdata == 0x31000004 "bram zero-stride vsse32 last elem wins"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x0a0e6487  # vlse32.v v9, (t3), zero
.assert trap == 0 "bram zero-stride vlse32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram zero-stride vlse32 lane 0 writes x10"
.assert rd_wdata == 0x31000004 "bram zero-stride vlse32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram zero-stride vlse32 lane 1 writes x10"
.assert rd_wdata == 0x31000004 "bram zero-stride vlse32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram zero-stride vlse32 lane 2 writes x10"
.assert rd_wdata == 0x31000004 "bram zero-stride vlse32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram zero-stride vlse32 lane 3 writes x10"
.assert rd_wdata == 0x31000004 "bram zero-stride vlse32 lane 3"
# 5. Strided vsse32/vlse32 (+8, -8, 0) in mmio.
.4byte 0x30048e13  # addi t3, s1, 768
.4byte 0x00800e93  # addi t4, zero, 8
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x31000337  # lui t1, 0x31000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x31000337  # lui t1, 0x31000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x31000337  # lui t1, 0x31000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x31000337  # lui t1, 0x31000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x0bde6427  # vsse32.v v8, (t3), t4
.assert trap == 0 "mmio pos vsse32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "mmio pos vsse32 elem 0 writes x10"
.assert rd_wdata == 0x31000001 "mmio pos vsse32 elem 0"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "mmio pos vsse32 elem 1 writes x10"
.assert rd_wdata == 0x31000002 "mmio pos vsse32 elem 1"
.4byte 0x010e6503  # lwu a0, 16(t3)
.assert rd_addr == 10 "mmio pos vsse32 elem 2 writes x10"
.assert rd_wdata == 0x31000003 "mmio pos vsse32 elem 2"
.4byte 0x018e6503  # lwu a0, 24(t3)
.assert rd_addr == 10 "mmio pos vsse32 elem 3 writes x10"
.assert rd_wdata == 0x31000004 "mmio pos vsse32 elem 3"
.4byte 0x31848e13  # addi t3, s1, 792
.4byte 0xff800e93  # addi t4, zero, -8
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x0bde6487  # vlse32.v v9, (t3), t4
.assert trap == 0 "mmio neg vlse32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio neg vlse32 lane 0 writes x10"
.assert rd_wdata == 0x31000004 "mmio neg vlse32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio neg vlse32 lane 1 writes x10"
.assert rd_wdata == 0x31000003 "mmio neg vlse32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio neg vlse32 lane 2 writes x10"
.assert rd_wdata == 0x31000002 "mmio neg vlse32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio neg vlse32 lane 3 writes x10"
.assert rd_wdata == 0x31000001 "mmio neg vlse32 lane 3"
.4byte 0x34048e13  # addi t3, s1, 832
.4byte 0x0a0e6427  # vsse32.v v8, (t3), zero
.assert trap == 0 "mmio zero-stride vsse32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "mmio zero-stride vsse32 word writes x10"
.assert rd_wdata == 0x31000004 "mmio zero-stride vsse32 last elem wins"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x0a0e6487  # vlse32.v v9, (t3), zero
.assert trap == 0 "mmio zero-stride vlse32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio zero-stride vlse32 lane 0 writes x10"
.assert rd_wdata == 0x31000004 "mmio zero-stride vlse32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio zero-stride vlse32 lane 1 writes x10"
.assert rd_wdata == 0x31000004 "mmio zero-stride vlse32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio zero-stride vlse32 lane 2 writes x10"
.assert rd_wdata == 0x31000004 "mmio zero-stride vlse32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio zero-stride vlse32 lane 3 writes x10"
.assert rd_wdata == 0x31000004 "mmio zero-stride vlse32 lane 3"
# 6. Indexed vsoxei32/vloxei32 & vsuxei32/vluxei32 in bram.
.4byte 0x40040e13  # addi t3, s0, 1024
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00c00313  # addi t1, zero, 12
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x0f0e6427  # vsoxei32.v v8, (t3), v16
.assert trap == 0 "bram vsoxei32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "bram vsoxei32 off 0 writes x10"
.assert rd_wdata == 0x61000003 "bram vsoxei32 off 0"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "bram vsoxei32 off 8 writes x10"
.assert rd_wdata == 0x61000002 "bram vsoxei32 off 8"
.4byte 0x00ce6503  # lwu a0, 12(t3)
.assert rd_addr == 10 "bram vsoxei32 off 12 writes x10"
.assert rd_wdata == 0x61000004 "bram vsoxei32 off 12"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x01c00313  # addi t1, zero, 28
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x01800313  # addi t1, zero, 24
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x070e6427  # vsuxei32.v v8, (t3), v16
.assert trap == 0 "bram vsuxei32 retires"
.4byte 0x018e6503  # lwu a0, 24(t3)
.assert rd_addr == 10 "bram vsuxei32 off 24 writes x10"
.assert rd_wdata == 0x62000001 "bram vsuxei32 off 24"
.4byte 0x010e6503  # lwu a0, 16(t3)
.assert rd_addr == 10 "bram vsuxei32 off 16 writes x10"
.assert rd_wdata == 0x62000002 "bram vsuxei32 off 16"
.4byte 0x01ce6503  # lwu a0, 28(t3)
.assert rd_addr == 10 "bram vsuxei32 off 28 writes x10"
.assert rd_wdata == 0x62000003 "bram vsuxei32 off 28"
.4byte 0x014e6503  # lwu a0, 20(t3)
.assert rd_addr == 10 "bram vsuxei32 off 20 writes x10"
.assert rd_wdata == 0x62000004 "bram vsuxei32 off 20"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x070e6487  # vluxei32.v v9, (t3), v16
.assert trap == 0 "bram vluxei32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "bram vluxei32 lane 0 writes x10"
.assert rd_wdata == 0x62000001 "bram vluxei32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vluxei32 lane 1 writes x10"
.assert rd_wdata == 0x62000002 "bram vluxei32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vluxei32 lane 2 writes x10"
.assert rd_wdata == 0x62000003 "bram vluxei32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vluxei32 lane 3 writes x10"
.assert rd_wdata == 0x62000004 "bram vluxei32 lane 3"
# 6. Indexed vsoxei32/vloxei32 & vsuxei32/vluxei32 in mmio.
.4byte 0x40048e13  # addi t3, s1, 1024
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00c00313  # addi t1, zero, 12
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0x00800313  # addi t1, zero, 8
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x0f0e6427  # vsoxei32.v v8, (t3), v16
.assert trap == 0 "mmio vsoxei32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "mmio vsoxei32 off 0 writes x10"
.assert rd_wdata == 0x61000003 "mmio vsoxei32 off 0"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "mmio vsoxei32 off 8 writes x10"
.assert rd_wdata == 0x61000002 "mmio vsoxei32 off 8"
.4byte 0x00ce6503  # lwu a0, 12(t3)
.assert rd_addr == 10 "mmio vsoxei32 off 12 writes x10"
.assert rd_wdata == 0x61000004 "mmio vsoxei32 off 12"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x01c00313  # addi t1, zero, 28
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x01800313  # addi t1, zero, 24
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x070e6427  # vsuxei32.v v8, (t3), v16
.assert trap == 0 "mmio vsuxei32 retires"
.4byte 0x018e6503  # lwu a0, 24(t3)
.assert rd_addr == 10 "mmio vsuxei32 off 24 writes x10"
.assert rd_wdata == 0x62000001 "mmio vsuxei32 off 24"
.4byte 0x010e6503  # lwu a0, 16(t3)
.assert rd_addr == 10 "mmio vsuxei32 off 16 writes x10"
.assert rd_wdata == 0x62000002 "mmio vsuxei32 off 16"
.4byte 0x01ce6503  # lwu a0, 28(t3)
.assert rd_addr == 10 "mmio vsuxei32 off 28 writes x10"
.assert rd_wdata == 0x62000003 "mmio vsuxei32 off 28"
.4byte 0x014e6503  # lwu a0, 20(t3)
.assert rd_addr == 10 "mmio vsuxei32 off 20 writes x10"
.assert rd_wdata == 0x62000004 "mmio vsuxei32 off 20"
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x070e6487  # vluxei32.v v9, (t3), v16
.assert trap == 0 "mmio vluxei32 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mmio vluxei32 lane 0 writes x10"
.assert rd_wdata == 0x62000001 "mmio vluxei32 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vluxei32 lane 1 writes x10"
.assert rd_wdata == 0x62000002 "mmio vluxei32 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vluxei32 lane 2 writes x10"
.assert rd_wdata == 0x62000003 "mmio vluxei32 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vluxei32 lane 3 writes x10"
.assert rd_wdata == 0x62000004 "mmio vluxei32 lane 3"
# 6b. Mixed-region vluxei64.v across DDR + low BRAM + MMIO + APLIC in one op.
.4byte 0xd000b337  # lui t1, 0xd000b
.4byte 0xbcd30313  # addi t1, t1, -1075
.4byte 0x006a2023  # sw t1, 0(s4)
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x44000337  # lui t1, 0x44000
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x02030313  # addi t1, t1, 32
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0x00020337  # lui t1, 0x20
.4byte 0x02030313  # addi t1, t1, 32
.4byte 0x3b036a57  # vslide1up.vx v20, v16, t1
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80010fb7  # lui t6, 0x80010
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x3b436857  # vslide1up.vx v16, v20, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x07007487  # vluxei64.v v9, (zero), v16
.assert trap == 0 "mixed 4-region vluxei64 retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "mixed 4-region vluxei64 lane 0 writes x10"
.assert rd_wdata == 0xffffffffd000abcd "mixed 4-region vluxei64 lane 0"
.4byte 0x3e90ba57  # vslidedown.vi v20, v9, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mixed 4-region vluxei64 lane 1 writes x10"
.assert rd_wdata == 0x11223344 "mixed 4-region vluxei64 lane 1"
.4byte 0x3e913a57  # vslidedown.vi v20, v9, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mixed 4-region vluxei64 lane 2 writes x10"
.assert rd_wdata == 0x11223344 "mixed 4-region vluxei64 lane 2"
.4byte 0x3e91ba57  # vslidedown.vi v20, v9, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mixed 4-region vluxei64 lane 3 writes x10"
.assert rd_wdata == 0x44001122 "mixed 4-region vluxei64 lane 3"
# 7. Segment vsseg2e32/vlseg2e32 and vssseg2e32/vlsseg2e32 in bram.
.4byte 0x50040e13  # addi t3, s0, 1280
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x70010337  # lui t1, 0x70010
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x70010337  # lui t1, 0x70010
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x70020337  # lui t1, 0x70020
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a936a57  # vslide1up.vx v20, v9, t1
.4byte 0x70020337  # lui t1, 0x70020
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b4364d7  # vslide1up.vx v9, v20, t1
.4byte 0x220e6427  # vsseg2e32.v v8, (t3)
.assert trap == 0 "bram vsseg2e32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "bram vsseg2e32 off 0 writes x10"
.assert rd_wdata == 0x70010001 "bram vsseg2e32 off 0"
.4byte 0x004e6503  # lwu a0, 4(t3)
.assert rd_addr == 10 "bram vsseg2e32 off 4 writes x10"
.assert rd_wdata == 0x70020001 "bram vsseg2e32 off 4"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "bram vsseg2e32 off 8 writes x10"
.assert rd_wdata == 0x70010002 "bram vsseg2e32 off 8"
.4byte 0x00ce6503  # lwu a0, 12(t3)
.assert rd_addr == 10 "bram vsseg2e32 off 12 writes x10"
.assert rd_wdata == 0x70020002 "bram vsseg2e32 off 12"
.4byte 0x5e003557  # vmv.v.i v10, 0
.4byte 0x5e0035d7  # vmv.v.i v11, 0
.4byte 0x220e6507  # vlseg2e32.v v10, (t3)
.assert trap == 0 "bram vlseg2e32 retires"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "bram vlseg2e32 f0[0] writes x10"
.assert rd_wdata == 0x70010001 "bram vlseg2e32 f0[0]"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vlseg2e32 f0[1] writes x10"
.assert rd_wdata == 0x70010002 "bram vlseg2e32 f0[1]"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "bram vlseg2e32 f1[0] writes x10"
.assert rd_wdata == 0x70020001 "bram vlseg2e32 f1[0]"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vlseg2e32 f1[1] writes x10"
.assert rd_wdata == 0x70020002 "bram vlseg2e32 f1[1]"
.4byte 0x54040e13  # addi t3, s0, 1344
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x2bde6427  # vssseg2e32.v v8, (t3), t4
.assert trap == 0 "bram vssseg2e32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "bram vssseg2e32 off 0 writes x10"
.assert rd_wdata == 0x70010001 "bram vssseg2e32 off 0"
.4byte 0x004e6503  # lwu a0, 4(t3)
.assert rd_addr == 10 "bram vssseg2e32 off 4 writes x10"
.assert rd_wdata == 0x70020001 "bram vssseg2e32 off 4"
.4byte 0x010e6503  # lwu a0, 16(t3)
.assert rd_addr == 10 "bram vssseg2e32 off 16 writes x10"
.assert rd_wdata == 0x70010002 "bram vssseg2e32 off 16"
.4byte 0x014e6503  # lwu a0, 20(t3)
.assert rd_addr == 10 "bram vssseg2e32 off 20 writes x10"
.assert rd_wdata == 0x70020002 "bram vssseg2e32 off 20"
.4byte 0x5e003557  # vmv.v.i v10, 0
.4byte 0x5e0035d7  # vmv.v.i v11, 0
.4byte 0x2bde6507  # vlsseg2e32.v v10, (t3), t4
.assert trap == 0 "bram vlsseg2e32 retires"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vlsseg2e32 f0[1] writes x10"
.assert rd_wdata == 0x70010002 "bram vlsseg2e32 f0[1]"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vlsseg2e32 f1[1] writes x10"
.assert rd_wdata == 0x70020002 "bram vlsseg2e32 f1[1]"
# 7. Segment vsseg2e32/vlseg2e32 and vssseg2e32/vlsseg2e32 in mmio.
.4byte 0x50048e13  # addi t3, s1, 1280
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x70010337  # lui t1, 0x70010
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a836a57  # vslide1up.vx v20, v8, t1
.4byte 0x70010337  # lui t1, 0x70010
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b436457  # vslide1up.vx v8, v20, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x70020337  # lui t1, 0x70020
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x3a936a57  # vslide1up.vx v20, v9, t1
.4byte 0x70020337  # lui t1, 0x70020
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x3b4364d7  # vslide1up.vx v9, v20, t1
.4byte 0x220e6427  # vsseg2e32.v v8, (t3)
.assert trap == 0 "mmio vsseg2e32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "mmio vsseg2e32 off 0 writes x10"
.assert rd_wdata == 0x70010001 "mmio vsseg2e32 off 0"
.4byte 0x004e6503  # lwu a0, 4(t3)
.assert rd_addr == 10 "mmio vsseg2e32 off 4 writes x10"
.assert rd_wdata == 0x70020001 "mmio vsseg2e32 off 4"
.4byte 0x008e6503  # lwu a0, 8(t3)
.assert rd_addr == 10 "mmio vsseg2e32 off 8 writes x10"
.assert rd_wdata == 0x70010002 "mmio vsseg2e32 off 8"
.4byte 0x00ce6503  # lwu a0, 12(t3)
.assert rd_addr == 10 "mmio vsseg2e32 off 12 writes x10"
.assert rd_wdata == 0x70020002 "mmio vsseg2e32 off 12"
.4byte 0x5e003557  # vmv.v.i v10, 0
.4byte 0x5e0035d7  # vmv.v.i v11, 0
.4byte 0x220e6507  # vlseg2e32.v v10, (t3)
.assert trap == 0 "mmio vlseg2e32 retires"
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "mmio vlseg2e32 f0[0] writes x10"
.assert rd_wdata == 0x70010001 "mmio vlseg2e32 f0[0]"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vlseg2e32 f0[1] writes x10"
.assert rd_wdata == 0x70010002 "mmio vlseg2e32 f0[1]"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "mmio vlseg2e32 f1[0] writes x10"
.assert rd_wdata == 0x70020001 "mmio vlseg2e32 f1[0]"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vlseg2e32 f1[1] writes x10"
.assert rd_wdata == 0x70020002 "mmio vlseg2e32 f1[1]"
.4byte 0x54048e13  # addi t3, s1, 1344
.4byte 0x01000e93  # addi t4, zero, 16
.4byte 0x2bde6427  # vssseg2e32.v v8, (t3), t4
.assert trap == 0 "mmio vssseg2e32 retires"
.4byte 0x000e6503  # lwu a0, 0(t3)
.assert rd_addr == 10 "mmio vssseg2e32 off 0 writes x10"
.assert rd_wdata == 0x70010001 "mmio vssseg2e32 off 0"
.4byte 0x004e6503  # lwu a0, 4(t3)
.assert rd_addr == 10 "mmio vssseg2e32 off 4 writes x10"
.assert rd_wdata == 0x70020001 "mmio vssseg2e32 off 4"
.4byte 0x010e6503  # lwu a0, 16(t3)
.assert rd_addr == 10 "mmio vssseg2e32 off 16 writes x10"
.assert rd_wdata == 0x70010002 "mmio vssseg2e32 off 16"
.4byte 0x014e6503  # lwu a0, 20(t3)
.assert rd_addr == 10 "mmio vssseg2e32 off 20 writes x10"
.assert rd_wdata == 0x70020002 "mmio vssseg2e32 off 20"
.4byte 0x5e003557  # vmv.v.i v10, 0
.4byte 0x5e0035d7  # vmv.v.i v11, 0
.4byte 0x2bde6507  # vlsseg2e32.v v10, (t3), t4
.assert trap == 0 "mmio vlsseg2e32 retires"
.4byte 0x3ea0ba57  # vslidedown.vi v20, v10, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vlsseg2e32 f0[1] writes x10"
.assert rd_wdata == 0x70010002 "mmio vlsseg2e32 f0[1]"
.4byte 0x3eb0ba57  # vslidedown.vi v20, v11, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vlsseg2e32 f1[1] writes x10"
.assert rd_wdata == 0x70020002 "mmio vlsseg2e32 f1[1]"
# 8. Fault-only-first vle32ff.v at bram upper boundary 0x40000.
.4byte 0xff8a8e13  # addi t3, s5, -8
.4byte 0x13572337  # lui t1, 0x13572
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x006e2023  # sw t1, 0(t3)
.4byte 0x9acec337  # lui t1, 0x9acec
.4byte 0xdf030313  # addi t1, t1, -528
.4byte 0x006e2223  # sw t1, 4(t3)
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x030e6407  # vle32ff.v v8, (t3)
.assert trap == 0 "bram vle32ff boundary retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "bram vle32ff trimmed vl writes x10"
.assert rd_wdata == 0x2 "bram vle32ff trimmed vl"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "bram vle32ff vstart writes x10"
.assert rd_wdata == 0x0 "bram vle32ff vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "bram vle32ff lane 0 writes x10"
.assert rd_wdata == 0x13572468 "bram vle32ff lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle32ff lane 1 writes x10"
.assert rd_wdata == 0xffffffff9acebdf0 "bram vle32ff lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "bram vle32ff lane 2 undisturbed writes x10"
.assert rd_wdata == 0x5a5aa5a5 "bram vle32ff lane 2 undisturbed"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x030ae407  # vle32ff.v v8, (s5)
.assert trap == 1 "bram vle32ff elem-0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "bram vle32ff elem-0 mcause writes x10"
.assert rd_wdata == 0x5 "bram vle32ff elem-0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "bram vle32ff elem-0 mtval writes x10"
.assert rd_wdata == 0x40000 "bram vle32ff elem-0 mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "bram vle32ff elem-0 vstart writes x10"
.assert rd_wdata == 0x0 "bram vle32ff elem-0 vstart"
# 8. Fault-only-first vle32ff.v at mmio upper boundary 0x40031000.
.4byte 0xff8b0e13  # addi t3, s6, -8
.4byte 0x13572337  # lui t1, 0x13572
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x006e2023  # sw t1, 0(t3)
.4byte 0x9acec337  # lui t1, 0x9acec
.4byte 0xdf030313  # addi t1, t1, -528
.4byte 0x006e2223  # sw t1, 4(t3)
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x030e6407  # vle32ff.v v8, (t3)
.assert trap == 0 "mmio vle32ff boundary retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "mmio vle32ff trimmed vl writes x10"
.assert rd_wdata == 0x2 "mmio vle32ff trimmed vl"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "mmio vle32ff vstart writes x10"
.assert rd_wdata == 0x0 "mmio vle32ff vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "mmio vle32ff lane 0 writes x10"
.assert rd_wdata == 0x13572468 "mmio vle32ff lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle32ff lane 1 writes x10"
.assert rd_wdata == 0xffffffff9acebdf0 "mmio vle32ff lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "mmio vle32ff lane 2 undisturbed writes x10"
.assert rd_wdata == 0x5a5aa5a5 "mmio vle32ff lane 2 undisturbed"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x030b6407  # vle32ff.v v8, (s6)
.assert trap == 1 "mmio vle32ff elem-0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mmio vle32ff elem-0 mcause writes x10"
.assert rd_wdata == 0x5 "mmio vle32ff elem-0 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "mmio vle32ff elem-0 mtval writes x10"
.assert rd_wdata == 0x40031000 "mmio vle32ff elem-0 mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "mmio vle32ff elem-0 vstart writes x10"
.assert rd_wdata == 0x0 "mmio vle32ff elem-0 vstart"
# 9. Alignment faults (cause 4/6) and unmapped store fault (cause 7) matching scalar.
.4byte 0x00240e13  # addi t3, s0, 2
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x020e6407  # vle32.v v8, (t3)
.assert trap == 1 "bram misaligned vle32 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "bram misaligned vle32 mcause writes x10"
.assert rd_wdata == 0x4 "bram misaligned vle32 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "bram misaligned vle32 mtval writes x10"
.assert rd_wdata == 0x20002 "bram misaligned vle32 mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "bram misaligned vle32 vstart writes x10"
.assert rd_wdata == 0x0 "bram misaligned vle32 vstart"
.4byte 0x020e6427  # vse32.v v8, (t3)
.assert trap == 1 "bram misaligned vse32 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "bram misaligned vse32 mcause writes x10"
.assert rd_wdata == 0x6 "bram misaligned vse32 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "bram misaligned vse32 mtval writes x10"
.assert rd_wdata == 0x20002 "bram misaligned vse32 mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "bram misaligned vse32 vstart writes x10"
.assert rd_wdata == 0x0 "bram misaligned vse32 vstart"
.4byte 0x00248e13  # addi t3, s1, 2
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x020e6407  # vle32.v v8, (t3)
.assert trap == 1 "mmio misaligned vle32 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mmio misaligned vle32 mcause writes x10"
.assert rd_wdata == 0x4 "mmio misaligned vle32 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "mmio misaligned vle32 mtval writes x10"
.assert rd_wdata == 0x40000002 "mmio misaligned vle32 mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "mmio misaligned vle32 vstart writes x10"
.assert rd_wdata == 0x0 "mmio misaligned vle32 vstart"
.4byte 0x020e6427  # vse32.v v8, (t3)
.assert trap == 1 "mmio misaligned vse32 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "mmio misaligned vse32 mcause writes x10"
.assert rd_wdata == 0x6 "mmio misaligned vse32 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "mmio misaligned vse32 mtval writes x10"
.assert rd_wdata == 0x40000002 "mmio misaligned vse32 mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "mmio misaligned vse32 vstart writes x10"
.assert rd_wdata == 0x0 "mmio misaligned vse32 vstart"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x020ae427  # vse32.v v8, (s5)
.assert trap == 1 "unmapped vse32 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "unmapped vse32 mcause writes x10"
.assert rd_wdata == 0x7 "unmapped vse32 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "unmapped vse32 mtval writes x10"
.assert rd_wdata == 0x40000 "unmapped vse32 mtval"
# 9b. Partial element-1 misaligned MMIO load trap: vstart=1, elem 0 loaded.
.4byte 0x02048e13  # addi t3, s1, 32
.4byte 0x00200e93  # addi t4, zero, 2
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x0bde6407  # vlse32.v v8, (t3), t4
.assert trap == 1 "MMIO elem-1 misaligned vlse32 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "MMIO elem-1 misaligned mcause writes x10"
.assert rd_wdata == 0x4 "MMIO elem-1 misaligned mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "MMIO elem-1 misaligned mtval writes x10"
.assert rd_wdata == 0x40000022 "MMIO elem-1 misaligned mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "MMIO elem-1 misaligned vstart writes x10"
.assert rd_wdata == 0x1 "MMIO elem-1 misaligned vstart"
.4byte 0x00801073  # csrw vstart, zero
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "MMIO elem-1 misaligned elem 0 loaded writes x10"
.assert rd_wdata == 0x11223344 "MMIO elem-1 misaligned elem 0 loaded"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "MMIO elem-1 misaligned elem 1 kept writes x10"
.assert rd_wdata == 0x5a5aa5a5 "MMIO elem-1 misaligned elem 1 kept"
# 9c. Partial element-1 unmapped access fault at 0x40000: vstart=1, elem 0 loaded.
.4byte 0xffca8e13  # addi t3, s5, -4
.4byte 0x00400e93  # addi t4, zero, 4
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x0bde6407  # vlse32.v v8, (t3), t4
.assert trap == 1 "BRAM->unmapped elem-1 vlse32 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "BRAM->unmapped elem-1 mcause writes x10"
.assert rd_wdata == 0x5 "BRAM->unmapped elem-1 mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "BRAM->unmapped elem-1 mtval writes x10"
.assert rd_wdata == 0x40000 "BRAM->unmapped elem-1 mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "BRAM->unmapped elem-1 vstart writes x10"
.assert rd_wdata == 0x1 "BRAM->unmapped elem-1 vstart"
.4byte 0x00801073  # csrw vstart, zero
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "BRAM->unmapped elem-1 elem 0 loaded writes x10"
.assert rd_wdata == 0xffffffff9acebdf0 "BRAM->unmapped elem-1 elem 0 loaded"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "BRAM->unmapped elem-1 elem 1 kept writes x10"
.assert rd_wdata == 0x5a5aa5a5 "BRAM->unmapped elem-1 elem 1 kept"
# 9d. Nonzero vstart=1 resume on low BRAM unit-stride vle32.v.
.4byte 0x02040e13  # addi t3, s0, 32
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x77777337  # lui t1, 0x77777
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x00829073  # csrw vstart, t0
.4byte 0x020e6407  # vle32.v v8, (t3)
.assert trap == 0 "BRAM vstart=1 vle32 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "BRAM vstart=1 vle32 clears vstart writes x10"
.assert rd_wdata == 0x0 "BRAM vstart=1 vle32 clears vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "BRAM vstart=1 lane 0 preserved writes x10"
.assert rd_wdata == 0x77777777 "BRAM vstart=1 lane 0 preserved"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "BRAM vstart=1 lane 1 loaded writes x10"
.assert rd_wdata == 0x55667788 "BRAM vstart=1 lane 1 loaded"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "BRAM vstart=1 lane 2 loaded writes x10"
.assert rd_wdata == 0xffffffff99aabbcc "BRAM vstart=1 lane 2 loaded"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "BRAM vstart=1 lane 3 loaded writes x10"
.assert rd_wdata == 0xffffffffddeeff01 "BRAM vstart=1 lane 3 loaded"
