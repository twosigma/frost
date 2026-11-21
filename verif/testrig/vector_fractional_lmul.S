# Fractional LMUL at VLEN 128, 256 and 512.
.noshrink
# VLMAX = VLEN / 64 for e8/mf8, e16/mf4 and e32/mf2.
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0xfff00313  # addi t1, zero, -1
.4byte 0xc22023f3  # csrr t2, vlenb
.4byte 0x0033d393  # srli t2, t2, 3
.4byte 0xfff38e13  # addi t3, t2, -1

# Fill the full e8 destination register and its neighbor with sentinels.
.4byte 0x00037057  # vsetvli zero, t1, e8, m1, tu, mu
.4byte 0x5e03b4d7  # vmv.v.i v9, 7
.4byte 0x5e05b557  # vmv.v.i v10, 11
.4byte 0x005375d7  # vsetvli a1, t1, e8, mf8, tu, mu
.4byte 0x407585b3  # sub a1, a1, t2
.assert rd_addr == 11 "e8/mf8 VLMAX difference writes x11"
.assert rd_wdata == 0x0 "e8/mf8 VL is VLEN / 64"
.4byte 0xc2102673  # csrr a2, vtype
.assert rd_addr == 12 "e8/mf8 vtype writes x12"
.assert rd_wdata == 0x5 "e8/mf8 tu,mu vtype"
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0x0241b4d7  # vadd.vi v9, v4, 3
.assert trap == 0 "e8/mf8 add retires"
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "e8/mf8 first element writes x10"
.assert rd_wdata == 0x9 "e8/mf8 first active result"
.4byte 0x3e9e4357  # vslidedown.vx v6, v9, t3
.4byte 0x426026d7  # vmv.x.s a3, v6
.assert rd_addr == 13 "e8/mf8 last element writes x13"
.assert rd_wdata == 0x9 "e8/mf8 last active result"

# Read the first byte of the fractional tail with m1 and check the neighbor.
.4byte 0xc000f057  # vsetivli zero, 1, e8, m1, tu, mu
.4byte 0x3e93c357  # vslidedown.vx v6, v9, t2
.4byte 0x42602757  # vmv.x.s a4, v6
.assert rd_addr == 14 "e8/mf8 preserved tail writes x14"
.assert rd_wdata == 0x7 "e8/mf8 first undisturbed tail element"
.4byte 0x42a027d7  # vmv.x.s a5, v10
.assert rd_addr == 15 "e8/mf8 neighbor writes x15"
.assert rd_wdata == 0xb "e8/mf8 neighboring register"

# With ta,ma, read only the initialized, mask-enabled element zero.
.4byte 0xc0e0f057  # vsetivli zero, 1, e16, mf4, tu, mu
.4byte 0x00100293  # addi t0, zero, 1
.4byte 0x4202e057  # vmv.s.x v0, t0
.4byte 0x0ce375d7  # vsetvli a1, t1, e16, mf4, ta, ma
.4byte 0x407585b3  # sub a1, a1, t2
.assert rd_addr == 11 "e16/mf4 VLMAX difference writes x11"
.assert rd_wdata == 0x0 "e16/mf4 VL is VLEN / 64"
.4byte 0xc2102673  # csrr a2, vtype
.assert rd_addr == 12 "e16/mf4 vtype writes x12"
.assert rd_wdata == 0xce "e16/mf4 ta,ma vtype"
.4byte 0x5e0e3257  # vmv.v.i v4, -4
.4byte 0x0040b5d7  # vadd.vi v11, v4, 1, v0.t
.assert trap == 0 "e16/mf4 masked add retires"
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "e16/mf4 enabled element writes x10"
.assert rd_wdata == 0xfffffffffffffffd "e16/mf4 active masked result"

# Widen the enabled e16/mf4 element into an e32/mf2 destination.
.4byte 0xc442e657  # vwadd.vx v12, v4, t0, v0.t
.assert trap == 0 "e16/mf4 masked widening add retires"
.4byte 0x017375d7  # vsetvli a1, t1, e32, mf2, tu, mu
.4byte 0x407585b3  # sub a1, a1, t2
.assert rd_addr == 11 "e32/mf2 VLMAX difference writes x11"
.assert rd_wdata == 0x0 "e32/mf2 VL is VLEN / 64"
.4byte 0xc2102673  # csrr a2, vtype
.assert rd_addr == 12 "e32/mf2 vtype writes x12"
.assert rd_wdata == 0x17 "e32/mf2 tu,mu vtype"
.4byte 0x42c026d7  # vmv.x.s a3, v12
.assert rd_addr == 13 "e32/mf2 widened element writes x13"
.assert rd_wdata == 0xfffffffffffffffd "e32/mf2 active widened result"

# Reduce VL and observe the new active value and the initialized tail.
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0x024cb6d7  # vadd.vi v13, v4, -7
.4byte 0xc170f5d7  # vsetivli a1, 1, e32, mf2, tu, mu
.assert rd_addr == 11 "e32/mf2 small AVL writes x11"
.assert rd_wdata == 0x1 "e32/mf2 small AVL sets VL to one"
.4byte 0x024136d7  # vadd.vi v13, v4, 2
.assert trap == 0 "e32/mf2 one-element add retires"
.4byte 0x42d02557  # vmv.x.s a0, v13
.assert rd_addr == 10 "e32/mf2 active element writes x10"
.assert rd_wdata == 0x8 "e32/mf2 active result after reducing VL"
.4byte 0x3ed0b357  # vslidedown.vi v6, v13, 1
.4byte 0x426026d7  # vmv.x.s a3, v6
.assert rd_addr == 13 "e32/mf2 preserved element writes x13"
.assert rd_wdata == 0xffffffffffffffff "e32/mf2 undisturbed tail after reducing VL"

# Reject e64/mf2 after a legal setting with VL one. Recover with e32/mf2.
.4byte 0xc1f0f5d7  # vsetivli a1, 1, e64, mf2, tu, mu
.assert trap == 0 "e64/mf2 vector configuration retires"
.assert rd_addr == 11 "e64/mf2 rejected length writes x11"
.assert rd_wdata == 0x0 "e64/mf2 returns VL zero"
.4byte 0xc2102673  # csrr a2, vtype
.assert rd_addr == 12 "e64/mf2 vtype writes x12"
.assert rd_wdata == 0x8000000000000000 "e64/mf2 sets vill and clears the other vtype bits"
.4byte 0xc20026f3  # csrr a3, vl
.assert rd_addr == 13 "e64/mf2 vl writes x13"
.assert rd_wdata == 0x0 "e64/mf2 clears the vl CSR"
.4byte 0xc170f5d7  # vsetivli a1, 1, e32, mf2, tu, mu
.assert trap == 0 "e32/mf2 recovery retires"
.assert rd_addr == 11 "e32/mf2 recovered length writes x11"
.assert rd_wdata == 0x1 "e32/mf2 recovery returns VL one"
.4byte 0xc2102673  # csrr a2, vtype
.assert rd_addr == 12 "e32/mf2 recovery vtype writes x12"
.assert rd_wdata == 0x17 "e32/mf2 recovery clears vill"
.4byte 0xc20026f3  # csrr a3, vl
.assert rd_addr == 13 "e32/mf2 recovery vl writes x13"
.assert rd_wdata == 0x1 "e32/mf2 recovery restores the vl CSR"

# Reject e32/mf8 from the recovered state. Recover with e8/mf8.
.4byte 0xc150f5d7  # vsetivli a1, 1, e32, mf8, tu, mu
.assert trap == 0 "e32/mf8 vector configuration retires"
.assert rd_addr == 11 "e32/mf8 rejected length writes x11"
.assert rd_wdata == 0x0 "e32/mf8 returns VL zero"
.4byte 0xc2102673  # csrr a2, vtype
.assert rd_addr == 12 "e32/mf8 vtype writes x12"
.assert rd_wdata == 0x8000000000000000 "e32/mf8 sets vill and clears the other vtype bits"
.4byte 0xc20026f3  # csrr a3, vl
.assert rd_addr == 13 "e32/mf8 vl writes x13"
.assert rd_wdata == 0x0 "e32/mf8 clears the vl CSR"
.4byte 0xc050f5d7  # vsetivli a1, 1, e8, mf8, tu, mu
.assert trap == 0 "e8/mf8 recovery retires"
.assert rd_addr == 11 "e8/mf8 recovered length writes x11"
.assert rd_wdata == 0x1 "e8/mf8 recovery returns VL one"
.4byte 0xc2102673  # csrr a2, vtype
.assert rd_addr == 12 "e8/mf8 recovery vtype writes x12"
.assert rd_wdata == 0x5 "e8/mf8 recovery clears vill"
.4byte 0xc20026f3  # csrr a3, vl
.assert rd_addr == 13 "e8/mf8 recovery vl writes x13"
.assert rd_wdata == 0x1 "e8/mf8 recovery restores the vl CSR"
