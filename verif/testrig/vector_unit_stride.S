# Unit-stride vector loads and stores and mask transfers in cached DDR.
.noshrink
# Enable VS and select cached DDR source and destination buffers.
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x40008437  # lui s0, 0x40008
.4byte 0x00141413  # slli s0, s0, 1
.4byte 0x10040493  # addi s1, s0, 256
.4byte 0xc2202e73  # csrr t3, vlenb
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e0030d7  # vmv.v.i v1, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0x5e003ad7  # vmv.v.i v21, 0
.4byte 0x5e003d57  # vmv.v.i v26, 0

# Unmasked unit-stride EEW 8 with vl=3 below VLMAX under tu, mu.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0a500313  # addi t1, zero, 165
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x03100313  # addi t1, zero, 49
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x08200313  # addi t1, zero, 130
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x05700313  # addi t1, zero, 87
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x07e00313  # addi t1, zero, 126
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x02040407  # vle8.v v8, (s0)
.assert trap == 0 "vle8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 loaded active lane 0 writes x10"
.assert rd_wdata == 0x31 "e8 loaded active lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 loaded active lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff82 "e8 loaded active lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 loaded active lane 2 writes x10"
.assert rd_wdata == 0x57 "e8 loaded active lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 tail-undisturbed lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "e8 tail-undisturbed lane 3"
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x01200313  # addi t1, zero, 18
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x01300313  # addi t1, zero, 19
.4byte 0x00648123  # sb t1, 2(s1)
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x02048427  # vse8.v v8, (s1)
.assert trap == 0 "vse8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 unmasked store at offset 0 writes x10"
.assert rd_wdata == 0x31 "e8 unmasked store at offset 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "e8 unmasked store at offset 1 writes x10"
.assert rd_wdata == 0x82 "e8 unmasked store at offset 1"
.4byte 0x0024c503  # lbu a0, 2(s1)
.assert rd_addr == 10 "e8 unmasked store at offset 2 writes x10"
.assert rd_wdata == 0x57 "e8 unmasked store at offset 2"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "e8 unmasked store at offset 3 writes x10"
.assert rd_wdata == 0x14 "e8 unmasked store at offset 3"

# Unmasked unit-stride EEW 16 with vl=3 below VLMAX under tu, mu.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x55a30313  # addi t1, t1, 1370
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x23430313  # addi t1, t1, 564
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0xa5b30313  # addi t1, t1, -1445
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x00005337  # lui t1, 0x5
.4byte 0xc3d30313  # addi t1, t1, -963
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xe6f30313  # addi t1, t1, -401
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x02045407  # vle16.v v8, (s0)
.assert trap == 0 "vle16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 loaded active lane 0 writes x10"
.assert rd_wdata == 0x1234 "e16 loaded active lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 loaded active lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff9a5b "e16 loaded active lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 loaded active lane 2 writes x10"
.assert rd_wdata == 0x4c3d "e16 loaded active lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 tail-undisturbed lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffa55a "e16 tail-undisturbed lane 3"
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x0204d427  # vse16.v v8, (s1)
.assert trap == 0 "vse16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 unmasked store at offset 0 writes x10"
.assert rd_wdata == 0x1234 "e16 unmasked store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 unmasked store at offset 2 writes x10"
.assert rd_wdata == 0x9a5b "e16 unmasked store at offset 2"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "e16 unmasked store at offset 4 writes x10"
.assert rd_wdata == 0x4c3d "e16 unmasked store at offset 4"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "e16 unmasked store at offset 6 writes x10"
.assert rd_wdata == 0x2444 "e16 unmasked store at offset 6"

# Unmasked unit-stride EEW 32 with vl=2 below VLMAX under tu, mu.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034d57  # vmv.v.x v26, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x12345337  # lui t1, 0x12345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9a5b5fb7  # lui t6, 0x9a5b5
.4byte 0xc3df8f93  # addi t6, t6, -963
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x7e6f6337  # lui t1, 0x7e6f6
.4byte 0xd4c30313  # addi t1, t1, -692
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x02046d07  # vle32.v v26, (s0)
.assert trap == 0 "vle32.v retires"
.4byte 0x43a02557  # vmv.x.s a0, v26
.assert rd_addr == 10 "e32 loaded active lane 0 writes x10"
.assert rd_wdata == 0x12345678 "e32 loaded active lane 0"
.4byte 0x3fa0ba57  # vslidedown.vi v20, v26, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 loaded active lane 1 writes x10"
.assert rd_wdata == 0xffffffff9a5b4c3d "e32 loaded active lane 1"
.4byte 0x3fa13a57  # vslidedown.vi v20, v26, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 tail-undisturbed lane 2 writes x10"
.assert rd_wdata == 0x5a5aa5a5 "e32 tail-undisturbed lane 2"
.4byte 0x31111337  # lui t1, 0x31111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x32222337  # lui t1, 0x32222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x33333337  # lui t1, 0x33333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x0204ed27  # vse32.v v26, (s1)
.assert trap == 0 "vse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 unmasked store at offset 0 writes x10"
.assert rd_wdata == 0x12345678 "e32 unmasked store at offset 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 unmasked store at offset 4 writes x10"
.assert rd_wdata == 0x9a5b4c3d "e32 unmasked store at offset 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "e32 unmasked store at offset 8 writes x10"
.assert rd_wdata == 0x33333333 "e32 unmasked store at offset 8"

# Unmasked unit-stride EEW 64 with vl=1 below VLMAX under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa5a5afb7  # lui t6, 0xa5a5a
.4byte 0x5a5f8f93  # addi t6, t6, 1445
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x1 "e64 m1 active vector length"
.4byte 0x92345337  # lui t1, 0x92345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x23456fb7  # lui t6, 0x23456
.4byte 0x789f8f93  # addi t6, t6, 1929
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x6a5b5337  # lui t1, 0x6a5b5
.4byte 0xc3d30313  # addi t1, t1, -963
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x34568fb7  # lui t6, 0x34568
.4byte 0x89af8f93  # addi t6, t6, -1894
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x02047407  # vle64.v v8, (s0)
.assert trap == 0 "vle64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 loaded active lane 0 writes x10"
.assert rd_wdata == 0x9234567823456789 "e64 loaded active lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 tail-undisturbed lane 1 writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "e64 tail-undisturbed lane 1"
.4byte 0x41111337  # lui t1, 0x41111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x42222337  # lui t1, 0x42222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x0204f427  # vse64.v v8, (s1)
.assert trap == 0 "vse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 unmasked store at offset 0 writes x10"
.assert rd_wdata == 0x9234567823456789 "e64 unmasked store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 unmasked store at offset 8 writes x10"
.assert rd_wdata == 0x4222222222222222 "e64 unmasked store at offset 8"

# Masked unit-stride EEW 8 m1 vl=3 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0c300313  # addi t1, zero, 195
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e8 m1 active vector length"
.4byte 0x01500313  # addi t1, zero, 21
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x02600313  # addi t1, zero, 38
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x09700313  # addi t1, zero, 151
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x04800313  # addi t1, zero, 72
.4byte 0x006401a3  # sb t1, 3(s0)
.4byte 0x00040407  # vle8.v v8, (s0), v0.t
.assert trap == 0 "vle8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 m1 enabled lane 0 writes x10"
.assert rd_wdata == 0x15 "e8 m1 enabled lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 m1 masked-off lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "e8 m1 masked-off lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 m1 enabled lane 2 writes x10"
.assert rd_wdata == 0xffffffffffffff97 "e8 m1 enabled lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 m1 tail lane 3 writes x10"
.assert rd_wdata == 0xffffffffffffffc3 "e8 m1 tail lane 3"
.4byte 0x05100313  # addi t1, zero, 81
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x05200313  # addi t1, zero, 82
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x05300313  # addi t1, zero, 83
.4byte 0x00648123  # sb t1, 2(s1)
.4byte 0x05400313  # addi t1, zero, 84
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x00048427  # vse8.v v8, (s1), v0.t
.assert trap == 0 "vse8.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "e8 m1 masked store at offset 0 writes x10"
.assert rd_wdata == 0x15 "e8 m1 masked store at offset 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "e8 m1 masked store at offset 1 writes x10"
.assert rd_wdata == 0x52 "e8 m1 masked store at offset 1"
.4byte 0x0024c503  # lbu a0, 2(s1)
.assert rd_addr == 10 "e8 m1 masked store at offset 2 writes x10"
.assert rd_wdata == 0x97 "e8 m1 masked store at offset 2"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "e8 m1 masked store at offset 3 writes x10"
.assert rd_wdata == 0x54 "e8 m1 masked store at offset 3"

# Masked unit-stride EEW 16 m1 vl=3 mask=0b10 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00004337  # lui t1, 0x4
.4byte 0xc3c30313  # addi t1, t1, -964
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e16 m1 active vector length"
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00641023  # sh t1, 0(s0)
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00641123  # sh t1, 2(s0)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x00004337  # lui t1, 0x4
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x00641323  # sh t1, 6(s0)
.4byte 0x00045407  # vle16.v v8, (s0), v0.t
.assert trap == 0 "vle16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 m1 masked-off lane 0 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 masked-off lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 m1 enabled lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff8222 "e16 m1 enabled lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 m1 masked-off lane 2 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 masked-off lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 m1 tail lane 3 writes x10"
.assert rd_wdata == 0x3c3c "e16 m1 tail lane 3"
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x0004d427  # vse16.v v8, (s1), v0.t
.assert trap == 0 "vse16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "e16 m1 masked store at offset 0 writes x10"
.assert rd_wdata == 0x6111 "e16 m1 masked store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "e16 m1 masked store at offset 2 writes x10"
.assert rd_wdata == 0x8222 "e16 m1 masked store at offset 2"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "e16 m1 masked store at offset 4 writes x10"
.assert rd_wdata == 0x6333 "e16 m1 masked store at offset 4"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "e16 m1 masked store at offset 6 writes x10"
.assert rd_wdata == 0x6444 "e16 m1 masked store at offset 6"

# Masked unit-stride EEW 32 m1 vl=3 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x33445337  # lui t1, 0x33445
.4byte 0x56630313  # addi t1, t1, 1382
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x22334337  # lui t1, 0x22334
.4byte 0x45530313  # addi t1, t1, 1109
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x99aacfb7  # lui t6, 0x99aac
.4byte 0xbccf8f93  # addi t6, t6, -1076
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642423  # sw t1, 8(s0)
.4byte 0x44556337  # lui t1, 0x44556
.4byte 0x67730313  # addi t1, t1, 1655
.4byte 0x00642623  # sw t1, 12(s0)
.4byte 0x00046407  # vle32.v v8, (s0), v0.t
.assert trap == 0 "vle32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 m1 enabled lane 0 writes x10"
.assert rd_wdata == 0x11223344 "e32 m1 enabled lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 m1 masked-off lane 1 writes x10"
.assert rd_wdata == 0x33445566 "e32 m1 masked-off lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 m1 enabled lane 2 writes x10"
.assert rd_wdata == 0xffffffff99aabbcc "e32 m1 enabled lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 m1 tail lane 3 writes x10"
.assert rd_wdata == 0x33445566 "e32 m1 tail lane 3"
.4byte 0x71000337  # lui t1, 0x71000
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x72000337  # lui t1, 0x72000
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x73000337  # lui t1, 0x73000
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x74000337  # lui t1, 0x74000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x0004e427  # vse32.v v8, (s1), v0.t
.assert trap == 0 "vse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "e32 m1 masked store at offset 0 writes x10"
.assert rd_wdata == 0x11223344 "e32 m1 masked store at offset 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "e32 m1 masked store at offset 4 writes x10"
.assert rd_wdata == 0x72000002 "e32 m1 masked store at offset 4"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "e32 m1 masked store at offset 8 writes x10"
.assert rd_wdata == 0x99aabbcc "e32 m1 masked store at offset 8"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "e32 m1 masked store at offset 12 writes x10"
.assert rd_wdata == 0x74000004 "e32 m1 masked store at offset 12"

# Masked unit-stride EEW 64 m1 vl=2 mask=0b10 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x0f1e3337  # lui t1, 0xf1e3
.4byte 0xd3c30313  # addi t1, t1, -708
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x4b5a7fb7  # lui t6, 0x4b5a7
.4byte 0x978f8f93  # addi t6, t6, -1672
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x11112337  # lui t1, 0x11112
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33334fb7  # lui t6, 0x33334
.4byte 0x444f8f93  # addi t6, t6, 1092
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x88887337  # lui t1, 0x88887
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x66665fb7  # lui t6, 0x66665
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x00047407  # vle64.v v8, (s0), v0.t
.assert trap == 0 "vle64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 m1 masked-off lane 0 writes x10"
.assert rd_wdata == 0xf1e2d3c4b5a6978 "e64 m1 masked-off lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m1 enabled lane 1 writes x10"
.assert rd_wdata == 0x8888777766665555 "e64 m1 enabled lane 1"
.4byte 0x71111337  # lui t1, 0x71111
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x11111fb7  # lui t6, 0x11111
.4byte 0x111f8f93  # addi t6, t6, 273
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x72222337  # lui t1, 0x72222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x73333337  # lui t1, 0x73333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33333fb7  # lui t6, 0x33333
.4byte 0x333f8f93  # addi t6, t6, 819
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x0004f427  # vse64.v v8, (s1), v0.t
.assert trap == 0 "vse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 m1 masked store at offset 0 writes x10"
.assert rd_wdata == 0x7111111111111111 "e64 m1 masked store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 m1 masked store at offset 8 writes x10"
.assert rd_wdata == 0x8888777766665555 "e64 m1 masked store at offset 8"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 m1 masked store at offset 16 writes x10"
.assert rd_wdata == 0x7333333333333333 "e64 m1 masked store at offset 16"

# Masked unit-stride EEW 64 m2 vl=3 mask=0b101 under tu, mu.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x1f2e4337  # lui t1, 0x1f2e4
.4byte 0xd4c30313  # addi t1, t1, -692
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5b6a8fb7  # lui t6, 0x5b6a8
.4byte 0x988f8f93  # addi t6, t6, -1656
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.assert rd_addr == 12 "e64 m2 active vector length writes x12"
.assert rd_wdata == 0x3 "e64 m2 active vector length"
.4byte 0x21222337  # lui t1, 0x21222
.4byte 0x32430313  # addi t1, t1, 804
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x25262fb7  # lui t6, 0x25262
.4byte 0x728f8f93  # addi t6, t6, 1832
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x31323337  # lui t1, 0x31323
.4byte 0x33430313  # addi t1, t1, 820
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x35363fb7  # lui t6, 0x35363
.4byte 0x738f8f93  # addi t6, t6, 1848
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0xa1a2a337  # lui t1, 0xa1a2a
.4byte 0x3a430313  # addi t1, t1, 932
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa5a6afb7  # lui t6, 0xa5a6a
.4byte 0x7a8f8f93  # addi t6, t6, 1960
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0x41424337  # lui t1, 0x41424
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x45464fb7  # lui t6, 0x45464
.4byte 0x748f8f93  # addi t6, t6, 1864
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643c23  # sd t1, 24(s0)
.4byte 0x00047407  # vle64.v v8, (s0), v0.t
.assert trap == 0 "vle64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 m2 enabled lane 0 writes x10"
.assert rd_wdata == 0x2122232425262728 "e64 m2 enabled lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m2 masked-off lane 1 writes x10"
.assert rd_wdata == 0x1f2e3d4c5b6a7988 "e64 m2 masked-off lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m2 enabled lane 2 writes x10"
.assert rd_wdata == 0xa1a2a3a4a5a6a7a8 "e64 m2 enabled lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m2 tail lane 3 writes x10"
.assert rd_wdata == 0x1f2e3d4c5b6a7988 "e64 m2 tail lane 3"
.4byte 0x61000337  # lui t1, 0x61000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00100f93  # addi t6, zero, 1
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x62000337  # lui t1, 0x62000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00200f93  # addi t6, zero, 2
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x63000337  # lui t1, 0x63000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00300f93  # addi t6, zero, 3
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0x64000337  # lui t1, 0x64000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00400f93  # addi t6, zero, 4
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064bc23  # sd t1, 24(s1)
.4byte 0x0004f427  # vse64.v v8, (s1), v0.t
.assert trap == 0 "vse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 m2 masked store at offset 0 writes x10"
.assert rd_wdata == 0x2122232425262728 "e64 m2 masked store at offset 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 m2 masked store at offset 8 writes x10"
.assert rd_wdata == 0x6200000000000002 "e64 m2 masked store at offset 8"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 m2 masked store at offset 16 writes x10"
.assert rd_wdata == 0xa1a2a3a4a5a6a7a8 "e64 m2 masked store at offset 16"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e64 m2 masked store at offset 24 writes x10"
.assert rd_wdata == 0x6400000000000004 "e64 m2 masked store at offset 24"

# Masked load under ta, ma observes only the enabled element.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0xcd017657  # vsetivli a2, 2, e32, m1, ta, ma
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x2468b337  # lui t1, 0x2468b
.4byte 0xce030313  # addi t1, t1, -800
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x1357a337  # lui t1, 0x1357a
.4byte 0xbdf30313  # addi t1, t1, -1057
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x00046407  # vle32.v v8, (s0), v0.t
.assert trap == 0 "vle32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "ta, ma enabled element zero writes x10"
.assert rd_wdata == 0x2468ace0 "ta, ma enabled element zero"

# Full-VLMAX unit-stride transfers across all four widths and VLENs.
.4byte 0x18171337  # lui t1, 0x18171
.4byte 0x61530313  # addi t1, t1, 1557
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x14131fb7  # lui t6, 0x14131
.4byte 0x211f8f93  # addi t6, t6, 529
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x28272337  # lui t1, 0x28272
.4byte 0x62530313  # addi t1, t1, 1573
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x24232fb7  # lui t6, 0x24232
.4byte 0x221f8f93  # addi t6, t6, 545
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x38373337  # lui t1, 0x38373
.4byte 0x63530313  # addi t1, t1, 1589
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x34333fb7  # lui t6, 0x34333
.4byte 0x231f8f93  # addi t6, t6, 561
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0x48474337  # lui t1, 0x48474
.4byte 0x64530313  # addi t1, t1, 1605
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x44434fb7  # lui t6, 0x44434
.4byte 0x241f8f93  # addi t6, t6, 577
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643c23  # sd t1, 24(s0)
.4byte 0x58575337  # lui t1, 0x58575
.4byte 0x65530313  # addi t1, t1, 1621
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x54535fb7  # lui t6, 0x54535
.4byte 0x251f8f93  # addi t6, t6, 593
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643023  # sd t1, 32(s0)
.4byte 0x68676337  # lui t1, 0x68676
.4byte 0x66530313  # addi t1, t1, 1637
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x64636fb7  # lui t6, 0x64636
.4byte 0x261f8f93  # addi t6, t6, 609
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643423  # sd t1, 40(s0)
.4byte 0x78777337  # lui t1, 0x78777
.4byte 0x67530313  # addi t1, t1, 1653
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x74737fb7  # lui t6, 0x74737
.4byte 0x271f8f93  # addi t6, t6, 625
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643823  # sd t1, 48(s0)
.4byte 0x88878337  # lui t1, 0x88878
.4byte 0x68530313  # addi t1, t1, 1669
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x84838fb7  # lui t6, 0x84838
.4byte 0x281f8f93  # addi t6, t6, 641
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643c23  # sd t1, 56(s0)

# Full-VLMAX unmasked EEW 8 load and store.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0a100313  # addi t1, zero, 161
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00007657  # vsetvli a2, zero, e8, m1, tu, mu
.4byte 0x02040407  # vle8.v v8, (s0)
.assert trap == 0 "vle8.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x11 "e8 VLMAX lane 0"
.4byte 0xfffe0393  # addi t2, t3, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8 VLMAX last lane writes x10"
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
.4byte 0x02048427  # vse8.v v8, (s1)
.assert trap == 0 "vse8.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e8 VLMAX stored dw 0 writes x10"
.assert rd_wdata == 0x1817161514131211 "e8 VLMAX stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e8 VLMAX stored dw 1 writes x10"
.assert rd_wdata == 0x2827262524232221 "e8 VLMAX stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e8 VLMAX readback dw 2 writes x10"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e8 VLMAX readback dw 3 writes x10"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e8 VLMAX readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e8 VLMAX readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e8 VLMAX readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e8 VLMAX readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e8 VLMAX untouched guard dw writes x10"
.assert rd_wdata == 0xf1f1f1f1f1f1f1f1 "e8 VLMAX untouched guard dw"

# Full-VLMAX unmasked EEW 16 load and store.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x2a230313  # addi t1, t1, 674
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x00807657  # vsetvli a2, zero, e16, m1, tu, mu
.4byte 0x02045407  # vle16.v v8, (s0)
.assert trap == 0 "vle16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x1211 "e16 VLMAX lane 0"
.4byte 0x001e5393  # srli t2, t3, 1
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16 VLMAX last lane writes x10"
.4byte 0xf2f2f337  # lui t1, 0xf2f2f
.4byte 0x2f230313  # addi t1, t1, 754
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf2f2ffb7  # lui t6, 0xf2f2f
.4byte 0x2f2f8f93  # addi t6, t6, 754
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
.4byte 0x0204d427  # vse16.v v8, (s1)
.assert trap == 0 "vse16.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e16 VLMAX stored dw 0 writes x10"
.assert rd_wdata == 0x1817161514131211 "e16 VLMAX stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e16 VLMAX stored dw 1 writes x10"
.assert rd_wdata == 0x2827262524232221 "e16 VLMAX stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e16 VLMAX readback dw 2 writes x10"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e16 VLMAX readback dw 3 writes x10"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e16 VLMAX readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e16 VLMAX readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e16 VLMAX readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e16 VLMAX readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e16 VLMAX untouched guard dw writes x10"
.assert rd_wdata == 0xf2f2f2f2f2f2f2f2 "e16 VLMAX untouched guard dw"

# Full-VLMAX unmasked EEW 32 load and store.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa3a3afb7  # lui t6, 0xa3a3a
.4byte 0x3a3f8f93  # addi t6, t6, 931
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x02046407  # vle32.v v8, (s0)
.assert trap == 0 "vle32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x14131211 "e32 VLMAX lane 0"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32 VLMAX last lane writes x10"
.4byte 0xf3f3f337  # lui t1, 0xf3f3f
.4byte 0x3f330313  # addi t1, t1, 1011
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf3f3ffb7  # lui t6, 0xf3f3f
.4byte 0x3f3f8f93  # addi t6, t6, 1011
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
.4byte 0x0204e427  # vse32.v v8, (s1)
.assert trap == 0 "vse32.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e32 VLMAX stored dw 0 writes x10"
.assert rd_wdata == 0x1817161514131211 "e32 VLMAX stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e32 VLMAX stored dw 1 writes x10"
.assert rd_wdata == 0x2827262524232221 "e32 VLMAX stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e32 VLMAX readback dw 2 writes x10"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e32 VLMAX readback dw 3 writes x10"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e32 VLMAX readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e32 VLMAX readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e32 VLMAX readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e32 VLMAX readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e32 VLMAX untouched guard dw writes x10"
.assert rd_wdata == 0xf3f3f3f3f3f3f3f3 "e32 VLMAX untouched guard dw"

# Full-VLMAX unmasked EEW 64 load and store.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0xa4a4a337  # lui t1, 0xa4a4a
.4byte 0x4a430313  # addi t1, t1, 1188
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa4a4afb7  # lui t6, 0xa4a4a
.4byte 0x4a4f8f93  # addi t6, t6, 1188
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x02047407  # vle64.v v8, (s0)
.assert trap == 0 "vle64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 VLMAX lane 0 writes x10"
.assert rd_wdata == 0x1817161514131211 "e64 VLMAX lane 0"
.4byte 0x003e5393  # srli t2, t3, 3
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 VLMAX last lane writes x10"
.4byte 0xf4f4f337  # lui t1, 0xf4f4f
.4byte 0x4f430313  # addi t1, t1, 1268
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf4f4ffb7  # lui t6, 0xf4f4f
.4byte 0x4f4f8f93  # addi t6, t6, 1268
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
.4byte 0x0204f427  # vse64.v v8, (s1)
.assert trap == 0 "vse64.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "e64 VLMAX stored dw 0 writes x10"
.assert rd_wdata == 0x1817161514131211 "e64 VLMAX stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "e64 VLMAX stored dw 1 writes x10"
.assert rd_wdata == 0x2827262524232221 "e64 VLMAX stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "e64 VLMAX readback dw 2 writes x10"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "e64 VLMAX readback dw 3 writes x10"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "e64 VLMAX readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "e64 VLMAX readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "e64 VLMAX readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "e64 VLMAX readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "e64 VLMAX untouched guard dw writes x10"
.assert rd_wdata == 0xf4f4f4f4f4f4f4f4 "e64 VLMAX untouched guard dw"

# Full-VLMAX masked EEW 32 load and store with alternating mask.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x0000a2b7  # lui t0, 0xa
.4byte 0x55a28293  # addi t0, t0, 1370
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x55aa5337  # lui t1, 0x55aa5
.4byte 0x5aa30313  # addi t1, t1, 1450
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x00046407  # vle32.v v8, (s0), v0.t
.assert trap == 0 "vle32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX masked e32 disabled lane 0 writes x10"
.assert rd_wdata == 0x55aa55aa "VLMAX masked e32 disabled lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX masked e32 enabled lane 1 writes x10"
.assert rd_wdata == 0x18171615 "VLMAX masked e32 enabled lane 1"
.4byte 0x002e5393  # srli t2, t3, 2
.4byte 0xfff38393  # addi t2, t2, -1
.4byte 0x3e83ca57  # vslidedown.vx v20, v8, t2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX masked e32 last lane writes x10"
.4byte 0xf5f5f337  # lui t1, 0xf5f5f
.4byte 0x5f530313  # addi t1, t1, 1525
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xf5f5ffb7  # lui t6, 0xf5f5f
.4byte 0x5f5f8f93  # addi t6, t6, 1525
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
.4byte 0x0004e427  # vse32.v v8, (s1), v0.t
.assert trap == 0 "vse32.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "VLMAX masked e32 stored dw 0 writes x10"
.assert rd_wdata == 0x18171615f5f5f5f5 "VLMAX masked e32 stored dw 0"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "VLMAX masked e32 stored dw 1 writes x10"
.assert rd_wdata == 0x28272625f5f5f5f5 "VLMAX masked e32 stored dw 1"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "VLMAX masked e32 readback dw 2 writes x10"
.4byte 0x0184b503  # ld a0, 24(s1)
.assert rd_addr == 10 "VLMAX masked e32 readback dw 3 writes x10"
.4byte 0x0204b503  # ld a0, 32(s1)
.assert rd_addr == 10 "VLMAX masked e32 readback dw 4 writes x10"
.4byte 0x0284b503  # ld a0, 40(s1)
.assert rd_addr == 10 "VLMAX masked e32 readback dw 5 writes x10"
.4byte 0x0304b503  # ld a0, 48(s1)
.assert rd_addr == 10 "VLMAX masked e32 readback dw 6 writes x10"
.4byte 0x0384b503  # ld a0, 56(s1)
.assert rd_addr == 10 "VLMAX masked e32 readback dw 7 writes x10"
.4byte 0x0404b503  # ld a0, 64(s1)
.assert rd_addr == 10 "VLMAX masked e32 untouched guard dw writes x10"
.assert rd_wdata == 0xf5f5f5f5f5f5f5f5 "VLMAX masked e32 untouched guard dw"

# Mask load and store with vl=8 (one byte, below VLMAX).
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x8 "e8 m1 active vector length"
.4byte 0x09600313  # addi t1, zero, 150
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x02b40087  # vlm.v v1, (s0)
.assert trap == 0 "vlm.v retires"
.4byte 0x42182557  # vcpop.m a0, v1
.assert rd_addr == 10 "vlm.v vl=8 popcount writes x10"
.assert rd_wdata == 0x4 "vlm.v vl=8 popcount"
.4byte 0x4218a557  # vfirst.m a0, v1
.assert rd_addr == 10 "vlm.v vl=8 first set bit writes x10"
.assert rd_wdata == 0x1 "vlm.v vl=8 first set bit"
.4byte 0x0a100313  # addi t1, zero, 161
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x0b200313  # addi t1, zero, 178
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x02b480a7  # vsm.v v1, (s1)
.assert trap == 0 "vsm.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "vsm.v vl=8 at offset 0 writes x10"
.assert rd_wdata == 0x96 "vsm.v vl=8 at offset 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "vsm.v vl=8 at offset 1 writes x10"
.assert rd_wdata == 0xb2 "vsm.v vl=8 at offset 1"

# Mask load and store with vl=12 (ceil(12/8)=2 bytes, below VLMAX).
.4byte 0xc0067657  # vsetivli a2, 12, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0xc "e8 m1 active vector length"
.4byte 0x09600313  # addi t1, zero, 150
.4byte 0x00640023  # sb t1, 0(s0)
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x006400a3  # sb t1, 1(s0)
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x00640123  # sb t1, 2(s0)
.4byte 0x02b40087  # vlm.v v1, (s0)
.assert trap == 0 "vlm.v retires"
.4byte 0x42182557  # vcpop.m a0, v1
.assert rd_addr == 10 "vlm.v vl=12 popcount writes x10"
.assert rd_wdata == 0x6 "vlm.v vl=12 popcount"
.4byte 0x4218a557  # vfirst.m a0, v1
.assert rd_addr == 10 "vlm.v vl=12 first set bit writes x10"
.assert rd_wdata == 0x1 "vlm.v vl=12 first set bit"
.4byte 0x0c100313  # addi t1, zero, 193
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x0c200313  # addi t1, zero, 194
.4byte 0x006480a3  # sb t1, 1(s1)
.4byte 0x0c300313  # addi t1, zero, 195
.4byte 0x00648123  # sb t1, 2(s1)
.4byte 0x02b480a7  # vsm.v v1, (s1)
.assert trap == 0 "vsm.v retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "vsm.v vl=12 at offset 0 writes x10"
.assert rd_wdata == 0x96 "vsm.v vl=12 at offset 0"
.4byte 0x0014c503  # lbu a0, 1(s1)
.assert rd_addr == 10 "vsm.v vl=12 at offset 1 writes x10"
.assert rd_wdata == 0x5a "vsm.v vl=12 at offset 1"
.4byte 0x0024c503  # lbu a0, 2(s1)
.assert rd_addr == 10 "vsm.v vl=12 at offset 2 writes x10"
.assert rd_wdata == 0xc3 "vsm.v vl=12 at offset 2"

# Mask load and store at vl=VLMAX (e8, m1 -> 2, 4 or 8 mask bytes).
.4byte 0x81726337  # lui t1, 0x81726
.4byte 0x35430313  # addi t1, t1, 852
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x45362fb7  # lui t6, 0x45362
.4byte 0x718f8f93  # addi t6, t6, 1816
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x00007657  # vsetvli a2, zero, e8, m1, tu, mu
.4byte 0x02b40007  # vlm.v v0, (s0)
.assert trap == 0 "vlm.v retires"
.4byte 0x42082557  # vcpop.m a0, v0
.assert rd_addr == 10 "vlm.v VLMAX popcount writes x10"
.4byte 0x4208a557  # vfirst.m a0, v0
.assert rd_addr == 10 "vlm.v VLMAX first set bit writes x10"
.assert rd_wdata == 0x3 "vlm.v VLMAX first set bit"
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0xbbbbc337  # lui t1, 0xbbbbc
.4byte 0xbbb30313  # addi t1, t1, -1093
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xbbbbcfb7  # lui t6, 0xbbbbc
.4byte 0xbbbf8f93  # addi t6, t6, -1093
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b423  # sd t1, 8(s1)
.4byte 0x02b48027  # vsm.v v0, (s1)
.assert trap == 0 "vsm.v retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "vsm.v VLMAX mask bytes readback writes x10"
.4byte 0x0084b503  # ld a0, 8(s1)
.assert rd_addr == 10 "vsm.v VLMAX untouched guard dw writes x10"
.assert rd_wdata == 0xbbbbbbbbbbbbbbbb "vsm.v VLMAX untouched guard dw"

# Unit-stride EEW 16 with SEW 32 and LMUL 1 (EMUL=1/2).
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xcafecfb7  # lui t6, 0xcafec
.4byte 0xabef8f93  # addi t6, t6, -1346
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x99930313  # addi t1, t1, -1639
.4byte 0x00641223  # sh t1, 4(s0)
.4byte 0x02045407  # vle16.v v8, (s0)
.assert trap == 0 "vle16.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "EMUL=1/2 packed loaded halfwords writes x10"
.assert rd_wdata == 0x24681357 "EMUL=1/2 packed loaded halfwords"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "EMUL=1/2 tail-undisturbed upper word writes x10"
.assert rd_wdata == 0xffffffffcafebabe "EMUL=1/2 tail-undisturbed upper word"
.4byte 0x0000d337  # lui t1, 0xd
.4byte 0x1d130313  # addi t1, t1, 465
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x0000d337  # lui t1, 0xd
.4byte 0x2d230313  # addi t1, t1, 722
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x0000d337  # lui t1, 0xd
.4byte 0x3d330313  # addi t1, t1, 979
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x0204d427  # vse16.v v8, (s1)
.assert trap == 0 "vse16.v retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "EMUL=1/2 store at offset 0 writes x10"
.assert rd_wdata == 0x1357 "EMUL=1/2 store at offset 0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "EMUL=1/2 store at offset 2 writes x10"
.assert rd_wdata == 0x2468 "EMUL=1/2 store at offset 2"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "EMUL=1/2 store at offset 4 writes x10"
.assert rd_wdata == 0xd3d3 "EMUL=1/2 store at offset 4"

# Zero-length and all-masked-off transfers leave vector and memory intact.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x0badc337  # lui t1, 0xbadc
.4byte 0x0de30313  # addi t1, t1, 222
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x77777337  # lui t1, 0x77777
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x66666337  # lui t1, 0x66666
.4byte 0x66630313  # addi t1, t1, 1638
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x0 "e32 m1 active vector length"
.4byte 0x02046407  # vle32.v v8, (s0)
.assert trap == 0 "vle32.v retires"
.4byte 0x0204e427  # vse32.v v8, (s1)
.assert trap == 0 "vse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vl=0 store leaves memory intact at offset 0 writes x10"
.assert rd_wdata == 0x66666666 "vl=0 store leaves memory intact at offset 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x1 "e32 m1 active vector length"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl=0 load leaves vector intact writes x10"
.assert rd_wdata == 0xbadc0de "vl=0 load leaves vector intact"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x0feee337  # lui t1, 0xfeee
.4byte 0xace30313  # addi t1, t1, -1330
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x77777337  # lui t1, 0x77777
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x88889fb7  # lui t6, 0x88889
.4byte 0x888f8f93  # addi t6, t6, -1912
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00642223  # sw t1, 4(s0)
.4byte 0x00046407  # vle32.v v8, (s0), v0.t
.assert trap == 0 "vle32.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "all-masked load lane 0 undisturbed writes x10"
.assert rd_wdata == 0xfeedace "all-masked load lane 0 undisturbed"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "all-masked load lane 1 undisturbed writes x10"
.assert rd_wdata == 0xfeedace "all-masked load lane 1 undisturbed"
.4byte 0x55551337  # lui t1, 0x55551
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x55552337  # lui t1, 0x55552
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x0004e427  # vse32.v v8, (s1), v0.t
.assert trap == 0 "vse32.v retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "all-masked store intact at offset 0 writes x10"
.assert rd_wdata == 0x55551111 "all-masked store intact at offset 0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "all-masked store intact at offset 4 writes x10"
.assert rd_wdata == 0x55552222 "all-masked store intact at offset 4"

# Cached DDR unit-stride transfer across a 4 KiB page and 32-byte sector boundary.
.4byte 0x00000913  # addi s2, zero, 0
.4byte 0x02091913  # slli s2, s2, 32
.4byte 0x80011fb7  # lui t6, 0x80011
.4byte 0xff8f8f93  # addi t6, t6, -8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f96933  # or s2, s2, t6
.4byte 0x00000993  # addi s3, zero, 0
.4byte 0x02099993  # slli s3, s3, 32
.4byte 0x80012fb7  # lui t6, 0x80012
.4byte 0xff8f8f93  # addi t6, t6, -8
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f9e9b3  # or s3, s3, t6
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x10203337  # lui t1, 0x10203
.4byte 0x04030313  # addi t1, t1, 64
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x50607fb7  # lui t6, 0x50607
.4byte 0x080f8f93  # addi t6, t6, 128
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x01020337  # lui t1, 0x1020
.4byte 0x30430313  # addi t1, t1, 772
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x05060fb7  # lui t6, 0x5060
.4byte 0x708f8f93  # addi t6, t6, 1800
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693023  # sd t1, 0(s2)
.4byte 0x898a9337  # lui t1, 0x898a9
.4byte 0xb8c30313  # addi t1, t1, -1140
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x8d8e9fb7  # lui t6, 0x8d8e9
.4byte 0xf90f8f93  # addi t6, t6, -112
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693423  # sd t1, 8(s2)
.4byte 0x02097407  # vle64.v v8, (s2)
.assert trap == 0 "vle64.v retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "page-crossing load lane 0 writes x10"
.assert rd_wdata == 0x102030405060708 "page-crossing load lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "page-crossing load lane 1 writes x10"
.assert rd_wdata == 0x898a8b8c8d8e8f90 "page-crossing load lane 1"
.4byte 0x22222337  # lui t1, 0x22222
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x22222fb7  # lui t6, 0x22222
.4byte 0x222f8f93  # addi t6, t6, 546
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b023  # sd t1, 0(s3)
.4byte 0x33333337  # lui t1, 0x33333
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x33333fb7  # lui t6, 0x33333
.4byte 0x333f8f93  # addi t6, t6, 819
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b423  # sd t1, 8(s3)
.4byte 0x0209f427  # vse64.v v8, (s3)
.assert trap == 0 "vse64.v retires"
.4byte 0x0009b503  # ld a0, 0(s3)
.assert rd_addr == 10 "page-crossing store at offset 0 writes x10"
.assert rd_wdata == 0x102030405060708 "page-crossing store at offset 0"
.4byte 0x0089b503  # ld a0, 8(s3)
.assert rd_addr == 10 "page-crossing store at offset 8 writes x10"
.assert rd_wdata == 0x898a8b8c8d8e8f90 "page-crossing store at offset 8"
