# Fault-only-first vector loads at the 1 GiB cached DDR upper boundary.
.noshrink
# Enable VS and form cached DDR buffer s1=0x80010000 and limit s0=0xC0000000.
.4byte 0x60000293  # addi t0, zero, 1536
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x60000437  # lui s0, 0x60000
.4byte 0x00141413  # slli s0, s0, 1
.4byte 0x400084b7  # lui s1, 0x40008
.4byte 0x00149493  # slli s1, s1, 1
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0x5e003a57  # vmv.v.i v20, 0
.4byte 0x5e003ad7  # vmv.v.i v21, 0
.4byte 0x5e003fd7  # vmv.v.i v31, 0

# Scalar load at 0xC0000000 raises load access fault in both models.
.4byte 0x00046503  # lwu a0, 0(s0)
.assert trap == 1 "scalar lwu at 0xC0000000 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "scalar fault mcause writes x10"
.assert rd_wdata == 0x5 "scalar fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "scalar fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "scalar fault mtval"

# Unmasked vle32ff.v across 0xC0000000 trims vl from 4 to 2 (v31 control).
.4byte 0xff840913  # addi s2, s0, -8
.4byte 0x13572337  # lui t1, 0x13572
.4byte 0x46830313  # addi t1, t1, 1128
.4byte 0x00692023  # sw t1, 0(s2)
.4byte 0x9acec337  # lui t1, 0x9acec
.4byte 0xdf030313  # addi t1, t1, -528
.4byte 0x00692223  # sw t1, 4(s2)
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034fd7  # vmv.v.x v31, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x4 "e32 m1 active vector length"
.4byte 0x03096f87  # vle32ff.v v31, (s2)
.assert trap == 0 "vle32ff.v retires"
.4byte 0x43f02557  # vmv.x.s a0, v31
.assert rd_addr == 10 "e32ff trim lane 0 writes x10"
.assert rd_wdata == 0x13572468 "e32ff trim lane 0"
.4byte 0x3ff0ba57  # vslidedown.vi v20, v31, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32ff trim lane 1 writes x10"
.assert rd_wdata == 0xffffffff9acebdf0 "e32ff trim lane 1"
.4byte 0x3ff13a57  # vslidedown.vi v20, v31, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32ff faulting lane 2 undisturbed writes x10"
.assert rd_wdata == 0x5a5aa5a5 "e32ff faulting lane 2 undisturbed"
.4byte 0x3ff1ba57  # vslidedown.vi v20, v31, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e32ff post-fault lane 3 undisturbed writes x10"
.assert rd_wdata == 0x5a5aa5a5 "e32ff post-fault lane 3 undisturbed"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "e32ff trimmed vl writes x10"
.assert rd_wdata == 0x2 "e32ff trimmed vl"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "e32ff vstart writes x10"
.assert rd_wdata == 0x0 "e32ff vstart"

# Unmasked vle64ff.v across 0xC0000000 trims vl from 2 to 1.
.4byte 0xff840913  # addi s2, s0, -8
.4byte 0x11223337  # lui t1, 0x11223
.4byte 0x34430313  # addi t1, t1, 836
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x55667fb7  # lui t6, 0x55667
.4byte 0x788f8f93  # addi t6, t6, 1928
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693023  # sd t1, 0(s2)
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
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x03097407  # vle64ff.v v8, (s2)
.assert trap == 0 "vle64ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "e64ff trimmed vl writes x10"
.assert rd_wdata == 0x1 "e64ff trimmed vl"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "e64ff vstart writes x10"
.assert rd_wdata == 0x0 "e64ff vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64ff trim lane 0 writes x10"
.assert rd_wdata == 0x1122334455667788 "e64ff trim lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64ff faulting lane 1 undisturbed writes x10"
.assert rd_wdata == 0x5a5a5a5aa5a5a5a5 "e64ff faulting lane 1 undisturbed"

# Unmasked vle8ff.v across 0xC0000000 trims vl from 4 to 2.
.4byte 0xffe40913  # addi s2, s0, -2
.4byte 0x03100313  # addi t1, zero, 49
.4byte 0x00690023  # sb t1, 0(s2)
.4byte 0x08200313  # addi t1, zero, 130
.4byte 0x006900a3  # sb t1, 1(s2)
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0a500313  # addi t1, zero, 165
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x4 "e8 m1 active vector length"
.4byte 0x03090407  # vle8ff.v v8, (s2)
.assert trap == 0 "vle8ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "e8ff trimmed vl writes x10"
.assert rd_wdata == 0x2 "e8ff trimmed vl"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "e8ff vstart writes x10"
.assert rd_wdata == 0x0 "e8ff vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8ff trim lane 0 writes x10"
.assert rd_wdata == 0x31 "e8ff trim lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8ff trim lane 1 writes x10"
.assert rd_wdata == 0xffffffffffffff82 "e8ff trim lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8ff faulting lane 2 undisturbed writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "e8ff faulting lane 2 undisturbed"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e8ff post-fault lane 3 undisturbed writes x10"
.assert rd_wdata == 0xffffffffffffffa5 "e8ff post-fault lane 3 undisturbed"

# Unmasked vle16ff.v across 0xC0000000 trims vl from 4 to 3.
.4byte 0xffa40913  # addi s2, s0, -6
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x23430313  # addi t1, t1, 564
.4byte 0x00691023  # sh t1, 0(s2)
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0xa5b30313  # addi t1, t1, -1445
.4byte 0x00691123  # sh t1, 2(s2)
.4byte 0x00005337  # lui t1, 0x5
.4byte 0xc3d30313  # addi t1, t1, -963
.4byte 0x00691223  # sh t1, 4(s2)
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x55a30313  # addi t1, t1, 1370
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x4 "e16 m1 active vector length"
.4byte 0x03095407  # vle16ff.v v8, (s2)
.assert trap == 0 "vle16ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "e16ff trimmed vl writes x10"
.assert rd_wdata == 0x3 "e16ff trimmed vl"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "e16ff vstart writes x10"
.assert rd_wdata == 0x0 "e16ff vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16ff trim lane 0 writes x10"
.assert rd_wdata == 0x1234 "e16ff trim lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16ff trim lane 1 writes x10"
.assert rd_wdata == 0xffffffffffff9a5b "e16ff trim lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16ff trim lane 2 writes x10"
.assert rd_wdata == 0x4c3d "e16ff trim lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e16ff faulting lane 3 undisturbed writes x10"
.assert rd_wdata == 0xffffffffffffa55a "e16ff faulting lane 3 undisturbed"

# Multi-register e64 m2 vle64ff.v across 0xC0000000 trims vl from 4 to 3.
.4byte 0xfe840913  # addi s2, s0, -24
.4byte 0x21222337  # lui t1, 0x21222
.4byte 0x32430313  # addi t1, t1, 804
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x25262fb7  # lui t6, 0x25262
.4byte 0x728f8f93  # addi t6, t6, 1832
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693023  # sd t1, 0(s2)
.4byte 0x91929337  # lui t1, 0x91929
.4byte 0x39430313  # addi t1, t1, 916
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x95969fb7  # lui t6, 0x95969
.4byte 0x798f8f93  # addi t6, t6, 1944
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693423  # sd t1, 8(s2)
.4byte 0x31323337  # lui t1, 0x31323
.4byte 0x33430313  # addi t1, t1, 820
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x35363fb7  # lui t6, 0x35363
.4byte 0x738f8f93  # addi t6, t6, 1848
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00693823  # sd t1, 16(s2)
.4byte 0x019072d7  # vsetvli t0, zero, e64, m2, tu, mu
.4byte 0x1f2e4337  # lui t1, 0x1f2e4
.4byte 0xd4c30313  # addi t1, t1, -692
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5b6a8fb7  # lui t6, 0x5b6a8
.4byte 0x988f8f93  # addi t6, t6, -1656
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.assert rd_addr == 12 "e64 m2 active vector length writes x12"
.assert rd_wdata == 0x4 "e64 m2 active vector length"
.4byte 0x03097407  # vle64ff.v v8, (s2)
.assert trap == 0 "vle64ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "e64 m2 trimmed vl writes x10"
.assert rd_wdata == 0x3 "e64 m2 trimmed vl"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 m2 lane 0 writes x10"
.assert rd_wdata == 0x2122232425262728 "e64 m2 lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m2 lane 1 writes x10"
.assert rd_wdata == 0x9192939495969798 "e64 m2 lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m2 lane 2 writes x10"
.assert rd_wdata == 0x3132333435363738 "e64 m2 lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "e64 m2 faulting lane 3 undisturbed writes x10"
.assert rd_wdata == 0x1f2e3d4c5b6a7988 "e64 m2 faulting lane 3 undisturbed"

# Full-VLMAX vle32ff.v across 0xC0000000 trims vl to 3 at all VLENs.
.4byte 0xff440913  # addi s2, s0, -12
.4byte 0x10203337  # lui t1, 0x10203
.4byte 0x04030313  # addi t1, t1, 64
.4byte 0x00692023  # sw t1, 0(s2)
.4byte 0x8090a337  # lui t1, 0x8090a
.4byte 0x0b030313  # addi t1, t1, 176
.4byte 0x00692223  # sw t1, 4(s2)
.4byte 0x50607337  # lui t1, 0x50607
.4byte 0x08030313  # addi t1, t1, 128
.4byte 0x00692423  # sw t1, 8(s2)
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x3c3cc337  # lui t1, 0x3c3cc
.4byte 0x3c330313  # addi t1, t1, 963
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x01007657  # vsetvli a2, zero, e32, m1, tu, mu
.4byte 0x03096407  # vle32ff.v v8, (s2)
.assert trap == 0 "vle32ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "VLMAX e32ff trimmed vl writes x10"
.assert rd_wdata == 0x3 "VLMAX e32ff trimmed vl"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX e32ff lane 0 writes x10"
.assert rd_wdata == 0x10203040 "VLMAX e32ff lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX e32ff lane 1 writes x10"
.assert rd_wdata == 0xffffffff8090a0b0 "VLMAX e32ff lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX e32ff lane 2 writes x10"
.assert rd_wdata == 0x50607080 "VLMAX e32ff lane 2"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "VLMAX e32ff faulting lane 3 undisturbed writes x10"
.assert rd_wdata == 0x3c3cc3c3 "VLMAX e32ff faulting lane 3 undisturbed"

# Masked vle32ff.v with faulting addresses masked off keeps vl unchanged.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00300293  # addi t0, zero, 3
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0xff840913  # addi s2, s0, -8
.4byte 0x24681337  # lui t1, 0x24681
.4byte 0x35730313  # addi t1, t1, 855
.4byte 0x00692023  # sw t1, 0(s2)
.4byte 0x86427337  # lui t1, 0x86427
.4byte 0x53130313  # addi t1, t1, 1329
.4byte 0x00692223  # sw t1, 4(s2)
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x6d6dd337  # lui t1, 0x6d6dd
.4byte 0x6d630313  # addi t1, t1, 1750
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x4 "e32 m1 active vector length"
.4byte 0x01096407  # vle32ff.v v8, (s2), v0.t
.assert trap == 0 "vle32ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "masked-off fault leaves vl unchanged writes x10"
.assert rd_wdata == 0x4 "masked-off fault leaves vl unchanged"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked-off fault lane 0 loaded writes x10"
.assert rd_wdata == 0x24681357 "masked-off fault lane 0 loaded"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "masked-off fault lane 1 loaded writes x10"
.assert rd_wdata == 0xffffffff86427531 "masked-off fault lane 1 loaded"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "masked-off fault lane 2 undisturbed writes x10"
.assert rd_wdata == 0x6d6dd6d6 "masked-off fault lane 2 undisturbed"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "masked-off fault lane 3 undisturbed writes x10"
.assert rd_wdata == 0x6d6dd6d6 "masked-off fault lane 3 undisturbed"

# Masked vle32ff.v trims vl to active faulting element index 2.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00e00293  # addi t0, zero, 14
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0xff840913  # addi s2, s0, -8
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x4e4ee337  # lui t1, 0x4e4ee
.4byte 0x4e430313  # addi t1, t1, 1252
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x4 "e32 m1 active vector length"
.4byte 0x01096407  # vle32ff.v v8, (s2), v0.t
.assert trap == 0 "vle32ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "masked active fault trimmed vl writes x10"
.assert rd_wdata == 0x2 "masked active fault trimmed vl"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked active fault lane 0 undisturbed writes x10"
.assert rd_wdata == 0x4e4ee4e4 "masked active fault lane 0 undisturbed"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "masked active fault lane 1 loaded writes x10"
.assert rd_wdata == 0xffffffff86427531 "masked active fault lane 1 loaded"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "masked active fault lane 2 undisturbed writes x10"
.assert rd_wdata == 0x4e4ee4e4 "masked active fault lane 2 undisturbed"
.4byte 0x3e81ba57  # vslidedown.vi v20, v8, 3
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "masked active fault lane 3 undisturbed writes x10"
.assert rd_wdata == 0x4e4ee4e4 "masked active fault lane 3 undisturbed"

# Masked vle32ff.v with element 0 masked off at 0xC0000000 trims vl to 1.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x7a7aa337  # lui t1, 0x7a7aa
.4byte 0x7a730313  # addi t1, t1, 1959
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x01046407  # vle32ff.v v8, (s0), v0.t
.assert trap == 0 "vle32ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "masked elem 0 at limit trims vl to 1 writes x10"
.assert rd_wdata == 0x1 "masked elem 0 at limit trims vl to 1"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked elem 0 at limit lane 0 undisturbed writes x10"
.assert rd_wdata == 0x7a7aa7a7 "masked elem 0 at limit lane 0 undisturbed"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "masked elem 0 at limit lane 1 undisturbed writes x10"
.assert rd_wdata == 0x7a7aa7a7 "masked elem 0 at limit lane 1 undisturbed"

# Non-faulting vle32ff.v in cached DDR keeps vl unchanged.
.4byte 0x11112337  # lui t1, 0x11112
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x9999b337  # lui t1, 0x9999b
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x2b2bb337  # lui t1, 0x2b2bb
.4byte 0x2b230313  # addi t1, t1, 690
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x0304e407  # vle32ff.v v8, (s1)
.assert trap == 0 "vle32ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "non-faulting e32ff vl unchanged writes x10"
.assert rd_wdata == 0x2 "non-faulting e32ff vl unchanged"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "non-faulting e32ff lane 0 writes x10"
.assert rd_wdata == 0x11112222 "non-faulting e32ff lane 0"
.4byte 0x3e80ba57  # vslidedown.vi v20, v8, 1
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "non-faulting e32ff lane 1 writes x10"
.assert rd_wdata == 0xffffffff9999aaaa "non-faulting e32ff lane 1"
.4byte 0x3e813a57  # vslidedown.vi v20, v8, 2
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "non-faulting e32ff tail lane 2 writes x10"
.assert rd_wdata == 0x2b2bb2b2 "non-faulting e32ff tail lane 2"

# Zero-length and all-masked-off vle32ff.v at 0xC0000000 do not trap.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x0badc337  # lui t1, 0xbadc
.4byte 0x0de30313  # addi t1, t1, 222
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1007657  # vsetivli a2, 0, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x0 "e32 m1 active vector length"
.4byte 0x03046407  # vle32ff.v v8, (s0)
.assert trap == 0 "vle32ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "vl=0 at limit vl unchanged writes x10"
.assert rd_wdata == 0x0 "vl=0 at limit vl unchanged"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e32 m1 active vector length"
.4byte 0x01046407  # vle32ff.v v8, (s0), v0.t
.assert trap == 0 "vle32ff.v retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "all-masked at limit vl unchanged writes x10"
.assert rd_wdata == 0x2 "all-masked at limit vl unchanged"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "all-masked at limit lane 0 undisturbed writes x10"
.assert rd_wdata == 0xbadc0de "all-masked at limit lane 0 undisturbed"

# Unmasked vle8ff.v faulting on element 0 at 0xC0000000 traps.
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x0c500313  # addi t1, zero, 197
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.assert rd_addr == 12 "e8 m1 active vector length writes x12"
.assert rd_wdata == 0x4 "e8 m1 active vector length"
.4byte 0x03040407  # vle8ff.v v8, (s0)
.assert trap == 1 "vle8ff.v traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "e8ff elem 0 fault mcause writes x10"
.assert rd_wdata == 0x5 "e8ff elem 0 fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "e8ff elem 0 fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "e8ff elem 0 fault mtval"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "e8ff elem 0 fault vl unchanged writes x10"
.assert rd_wdata == 0x4 "e8ff elem 0 fault vl unchanged"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "e8ff elem 0 fault vstart writes x10"
.assert rd_wdata == 0x0 "e8ff elem 0 fault vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8ff elem 0 fault lane 0 undisturbed writes x10"
.assert rd_wdata == 0xffffffffffffffc5 "e8ff elem 0 fault lane 0 undisturbed"

# Unmasked vle16ff.v faulting on element 0 at 0xC0000000 traps.
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0x55c30313  # addi t1, t1, 1372
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.assert rd_addr == 12 "e16 m1 active vector length writes x12"
.assert rd_wdata == 0x4 "e16 m1 active vector length"
.4byte 0x03045407  # vle16ff.v v8, (s0)
.assert trap == 1 "vle16ff.v traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "e16ff elem 0 fault mcause writes x10"
.assert rd_wdata == 0x5 "e16ff elem 0 fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "e16ff elem 0 fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "e16ff elem 0 fault mtval"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "e16ff elem 0 fault vl unchanged writes x10"
.assert rd_wdata == 0x4 "e16ff elem 0 fault vl unchanged"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "e16ff elem 0 fault vstart writes x10"
.assert rd_wdata == 0x0 "e16ff elem 0 fault vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16ff elem 0 fault lane 0 undisturbed writes x10"
.assert rd_wdata == 0xffffffffffffc55c "e16ff elem 0 fault lane 0 undisturbed"

# Unmasked vle32ff.v faulting on element 0 at 0xC0000000 traps.
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5c5cc337  # lui t1, 0x5c5cc
.4byte 0x5c530313  # addi t1, t1, 1477
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x03046407  # vle32ff.v v8, (s0)
.assert trap == 1 "vle32ff.v traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "e32ff elem 0 fault mcause writes x10"
.assert rd_wdata == 0x5 "e32ff elem 0 fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "e32ff elem 0 fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "e32ff elem 0 fault mtval"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "e32ff elem 0 fault vl unchanged writes x10"
.assert rd_wdata == 0x3 "e32ff elem 0 fault vl unchanged"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "e32ff elem 0 fault vstart writes x10"
.assert rd_wdata == 0x0 "e32ff elem 0 fault vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32ff elem 0 fault lane 0 undisturbed writes x10"
.assert rd_wdata == 0x5c5cc5c5 "e32ff elem 0 fault lane 0 undisturbed"

# Unmasked vle64ff.v faulting on element 0 at 0xC0000000 traps.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5c5c6337  # lui t1, 0x5c5c6
.4byte 0xc5c30313  # addi t1, t1, -932
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xc5c5cfb7  # lui t6, 0xc5c5c
.4byte 0x5c5f8f93  # addi t6, t6, 1477
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.assert rd_addr == 12 "e64 m1 active vector length writes x12"
.assert rd_wdata == 0x2 "e64 m1 active vector length"
.4byte 0x03047407  # vle64ff.v v8, (s0)
.assert trap == 1 "vle64ff.v traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "e64ff elem 0 fault mcause writes x10"
.assert rd_wdata == 0x5 "e64ff elem 0 fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "e64ff elem 0 fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "e64ff elem 0 fault mtval"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "e64ff elem 0 fault vl unchanged writes x10"
.assert rd_wdata == 0x2 "e64ff elem 0 fault vl unchanged"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "e64ff elem 0 fault vstart writes x10"
.assert rd_wdata == 0x0 "e64ff elem 0 fault vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64ff elem 0 fault lane 0 undisturbed writes x10"
.assert rd_wdata == 0x5c5c5c5cc5c5c5c5 "e64ff elem 0 fault lane 0 undisturbed"

# Masked vle32ff.v with active element 0 at 0xC0000000 traps.
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x3e3ee337  # lui t1, 0x3e3ee
.4byte 0x3e330313  # addi t1, t1, 995
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.assert rd_addr == 12 "e32 m1 active vector length writes x12"
.assert rd_wdata == 0x3 "e32 m1 active vector length"
.4byte 0x01046407  # vle32ff.v v8, (s0), v0.t
.assert trap == 1 "vle32ff.v traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "masked e32ff elem 0 fault mcause writes x10"
.assert rd_wdata == 0x5 "masked e32ff elem 0 fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "masked e32ff elem 0 fault mtval writes x10"
.assert rd_wdata == 0xc0000000 "masked e32ff elem 0 fault mtval"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "masked e32ff elem 0 fault vl unchanged writes x10"
.assert rd_wdata == 0x3 "masked e32ff elem 0 fault vl unchanged"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "masked e32ff elem 0 fault vstart writes x10"
.assert rd_wdata == 0x0 "masked e32ff elem 0 fault vstart"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked e32ff elem 0 fault lane 0 undisturbed writes x10"
.assert rd_wdata == 0x3e3ee3e3 "masked e32ff elem 0 fault lane 0 undisturbed"
