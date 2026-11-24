# Directed TestRIG trace for all 15 base-V integer carry/borrow encodings:
# vadc.{vvm,vxm,vim}, vmadc.{vvm,vxm,vim,vv,vx,vi},
# vsbc.{vvm,vxm}, vmsbc.{vvm,vxm,vv,vx}.
# VLEN-portable across VLEN 128, 256, and 512; zero misa accesses.

# Preamble: enable mstatus.FS and mstatus.VS, zero v0..v31, clear vxsat.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x003072d7  # vsetvli t0, zero, e8, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0
.4byte 0x00905073  # csrwi vxsat, 0
.4byte 0x009025f3  # csrr a1, vxsat
.assert rd_addr == 11 "vxsat (initial vxsat clear) writes a1"
.assert rd_wdata == 0x0 "vxsat (initial vxsat clear)"

# Section 1: Control readout (vmv.x.s a0, v19 = 0x43302557).
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x12340337  # lui t1, 0x12340
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x00930313  # addi t1, t1, 9
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e03b057  # vmv.v.i v0, 7
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x404309d7  # vadc.vvm v19, v4, v6, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x43302557  # vmv.x.s a0, v19
.assert rd_addr == 10 "ctrl vadc.vvm lane 0 writes a0"
.assert rd_wdata == 0x1234a00a "ctrl vadc.vvm lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f30b757  # vslidedown.vi v14, v19, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "ctrl vadc.vvm lane 1 wrap with carry writes a0"
.assert rd_wdata == 0x0 "ctrl vadc.vvm lane 1 wrap with carry"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f313757  # vslidedown.vi v14, v19, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "ctrl vadc.vvm lane 2 signed overflow writes a0"
.assert rd_wdata == 0xffffffff80000001 "ctrl vadc.vvm lane 2 signed overflow"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f31b757  # vslidedown.vi v14, v19, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "ctrl vadc.vvm lane 3 high-bit wrap writes a0"
.assert rd_wdata == 0x0 "ctrl vadc.vvm lane 3 high-bit wrap"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x44430657  # vmadc.vvm v12, v4, v6, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "ctrl vmadc.vvm carry-out mask writes a0"
.assert rd_wdata == 0xa "ctrl vmadc.vvm carry-out mask"

# Section 2: All 15 carry/borrow encodings across e8, e16, e32, e64.
# --- SEW=8 (m1): vadc/vmadc/vsbc/vmsbc ---
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x07f00313  # addi t1, zero, 127
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x40430457  # vadc.vvm v8, v4, v6, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vadc.vvm MAX+0+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vadc.vvm MAX+0+0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vvm MAX+0+1 wrap writes a0"
.assert rd_wdata == 0x0 "e8 vadc.vvm MAX+0+1 wrap"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vvm MAX+MAX+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vadc.vvm MAX+MAX+1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vvm SMAX+1+0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vadc.vvm SMAX+1+0"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x44430657  # vmadc.vvm v12, v4, v6, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vvm carry-out writes a0"
.assert rd_wdata == 0x6 "e8 vmadc.vvm carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x46430657  # vmadc.vv v12, v4, v6
.assert trap == 0 "vmadc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vv ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e8 vmadc.vv ignores v0=0xFF"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x07f00313  # addi t1, zero, 127
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4042c457  # vadc.vxm v8, v4, t0, v0
.assert trap == 0 "vadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vadc.vxm MAX+0+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vadc.vxm MAX+0+0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vxm MAX+0+1 writes a0"
.assert rd_wdata == 0x0 "e8 vadc.vxm MAX+0+1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vxm 0+0+1 writes a0"
.assert rd_wdata == 0x1 "e8 vadc.vxm 0+0+1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vxm SMAX+0+0 writes a0"
.assert rd_wdata == 0x7f "e8 vadc.vxm SMAX+0+0"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4442c657  # vmadc.vxm v12, v4, t0, v0
.assert trap == 0 "vmadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vxm carry-out writes a0"
.assert rd_wdata == 0x2 "e8 vmadc.vxm carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4642c657  # vmadc.vx v12, v4, t0
.assert trap == 0 "vmadc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vx ignores v0=0xFF and upper rs1 writes a0"
.assert rd_wdata == 0x0 "e8 vmadc.vx ignores v0=0xFF and upper rs1"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xfff00293  # addi t0, zero, -1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4042c457  # vadc.vxm v8, v4, t0, v0
.assert trap == 0 "vadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vadc.vxm 0+MAX+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vadc.vxm 0+MAX+0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vxm 0+MAX+1 writes a0"
.assert rd_wdata == 0x0 "e8 vadc.vxm 0+MAX+1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vxm 1+MAX+0 writes a0"
.assert rd_wdata == 0x0 "e8 vadc.vxm 1+MAX+0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vxm MAX+MAX+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vadc.vxm MAX+MAX+1"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4442c657  # vmadc.vxm v12, v4, t0, v0
.assert trap == 0 "vmadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vxm rs1=-1 carry-out writes a0"
.assert rd_wdata == 0xe "e8 vmadc.vxm rs1=-1 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4642c657  # vmadc.vx v12, v4, t0
.assert trap == 0 "vmadc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vx rs1=-1 ignores v0=0xFF writes a0"
.assert rd_wdata == 0xc "e8 vmadc.vx rs1=-1 ignores v0=0xFF"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x404fb457  # vadc.vim v8, v4, -1, v0
.assert trap == 0 "vadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vadc.vim 0+(-1)+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vadc.vim 0+(-1)+0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vim 0+(-1)+1 writes a0"
.assert rd_wdata == 0x0 "e8 vadc.vim 0+(-1)+1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vim 1+(-1)+0 writes a0"
.assert rd_wdata == 0x0 "e8 vadc.vim 1+(-1)+0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vim MAX+(-1)+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vadc.vim MAX+(-1)+1"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x444fb657  # vmadc.vim v12, v4, -1, v0
.assert trap == 0 "vmadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vim simm5=-1 carry-out writes a0"
.assert rd_wdata == 0xe "e8 vmadc.vim simm5=-1 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x464fb657  # vmadc.vi v12, v4, -1
.assert trap == 0 "vmadc.vi retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vi simm5=-1 ignores v0=0xFF writes a0"
.assert rd_wdata == 0xc "e8 vmadc.vi simm5=-1 ignores v0=0xFF"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e07b257  # vmv.v.i v4, 15
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e07b257  # vmv.v.i v4, 15
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e023057  # vmv.v.i v0, 4
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x40483457  # vadc.vim v8, v4, -16, v0
.assert trap == 0 "vadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vadc.vim 16+(-16)+0 writes a0"
.assert rd_wdata == 0x0 "e8 vadc.vim 16+(-16)+0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vim 15+(-16)+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vadc.vim 15+(-16)+0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vim 15+(-16)+1 writes a0"
.assert rd_wdata == 0x0 "e8 vadc.vim 15+(-16)+1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vim 0+(-16)+0 writes a0"
.assert rd_wdata == 0xfffffffffffffff0 "e8 vadc.vim 0+(-16)+0"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x44483657  # vmadc.vim v12, v4, -16, v0
.assert trap == 0 "vmadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vim simm5=-16 carry-out writes a0"
.assert rd_wdata == 0x5 "e8 vmadc.vim simm5=-16 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x46483657  # vmadc.vi v12, v4, -16
.assert trap == 0 "vmadc.vi retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vi simm5=-16 ignores v0=0xFF writes a0"
.assert rd_wdata == 0x1 "e8 vmadc.vi simm5=-16 ignores v0=0xFF"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e08b257  # vmv.v.i v4, -15
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e083257  # vmv.v.i v4, -16
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e083257  # vmv.v.i v4, -16
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4047b457  # vadc.vim v8, v4, 15, v0
.assert trap == 0 "vadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vadc.vim (MAX-15)+15+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vadc.vim (MAX-15)+15+0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vadc.vim (MAX-15)+15+1 writes a0"
.assert rd_wdata == 0x0 "e8 vadc.vim (MAX-15)+15+1"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4447b657  # vmadc.vim v12, v4, 15, v0
.assert trap == 0 "vmadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vim simm5=+15 carry-out writes a0"
.assert rd_wdata == 0x6 "e8 vmadc.vim simm5=+15 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4647b657  # vmadc.vi v12, v4, 15
.assert trap == 0 "vmadc.vi retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmadc.vi simm5=+15 ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e8 vmadc.vi simm5=+15 ignores v0=0xFF"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vsbc.vvm 0-0-0 writes a0"
.assert rd_wdata == 0x0 "e8 vsbc.vvm 0-0-0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vsbc.vvm 0-0-1 underflow writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vsbc.vvm 0-0-1 underflow"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vsbc.vvm 0-MAX-1 double underflow writes a0"
.assert rd_wdata == 0x0 "e8 vsbc.vvm 0-MAX-1 double underflow"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vsbc.vvm SMIN-1-0 unsigned no borrow writes a0"
.assert rd_wdata == 0x7f "e8 vsbc.vvm SMIN-1-0 unsigned no borrow"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4c430657  # vmsbc.vvm v12, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmsbc.vvm borrow-out writes a0"
.assert rd_wdata == 0x6 "e8 vmsbc.vvm borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4e430657  # vmsbc.vv v12, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmsbc.vv ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e8 vmsbc.vv ignores v0=0xFF"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x07f00313  # addi t1, zero, 127
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vsbc.vvm 5-5-0 writes a0"
.assert rd_wdata == 0x0 "e8 vsbc.vvm 5-5-0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vsbc.vvm 5-5-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vsbc.vvm 5-5-1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vsbc.vvm SMAX-SMIN-0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vsbc.vvm SMAX-SMIN-0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vsbc.vvm MAX-MAX-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vsbc.vvm MAX-MAX-1"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4c430657  # vmsbc.vvm v12, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmsbc.vvm equal/sign borrow-out writes a0"
.assert rd_wdata == 0xe "e8 vmsbc.vvm equal/sign borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4e430657  # vmsbc.vv v12, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmsbc.vv equal/sign ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e8 vmsbc.vv equal/sign ignores v0=0xFF"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4842c457  # vsbc.vxm v8, v4, t0, v0
.assert trap == 0 "vsbc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vsbc.vxm 5-5-0 writes a0"
.assert rd_wdata == 0x0 "e8 vsbc.vxm 5-5-0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vsbc.vxm 5-5-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vsbc.vxm 5-5-1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vsbc.vxm 4-5-0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vsbc.vxm 4-5-0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 vsbc.vxm 6-5-0 writes a0"
.assert rd_wdata == 0x1 "e8 vsbc.vxm 6-5-0"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4c42c657  # vmsbc.vxm v12, v4, t0, v0
.assert trap == 0 "vmsbc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmsbc.vxm borrow-out writes a0"
.assert rd_wdata == 0x6 "e8 vmsbc.vxm borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4e42c657  # vmsbc.vx v12, v4, t0
.assert trap == 0 "vmsbc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 vmsbc.vx ignores v0=0xFF and upper rs1 writes a0"
.assert rd_wdata == 0x4 "e8 vmsbc.vx ignores v0=0xFF and upper rs1"
# --- SEW=16 (m1): vadc/vmadc/vsbc/vmsbc ---
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x40430457  # vadc.vvm v8, v4, v6, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vadc.vvm MAX+0+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vadc.vvm MAX+0+0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vvm MAX+0+1 wrap writes a0"
.assert rd_wdata == 0x0 "e16 vadc.vvm MAX+0+1 wrap"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vvm MAX+MAX+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vadc.vvm MAX+MAX+1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vvm SMAX+1+0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vadc.vvm SMAX+1+0"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x44430657  # vmadc.vvm v12, v4, v6, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmadc.vvm carry-out writes a0"
.assert rd_wdata == 0x6 "e16 vmadc.vvm carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x46430657  # vmadc.vv v12, v4, v6
.assert trap == 0 "vmadc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmadc.vv ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e16 vmadc.vv ignores v0=0xFF"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4042c457  # vadc.vxm v8, v4, t0, v0
.assert trap == 0 "vadc.vxm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vadc.vxm MAX+0+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vadc.vxm MAX+0+0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vxm MAX+0+1 writes a0"
.assert rd_wdata == 0x0 "e16 vadc.vxm MAX+0+1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vxm 0+0+1 writes a0"
.assert rd_wdata == 0x1 "e16 vadc.vxm 0+0+1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vxm SMAX+0+0 writes a0"
.assert rd_wdata == 0x7fff "e16 vadc.vxm SMAX+0+0"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4442c657  # vmadc.vxm v12, v4, t0, v0
.assert trap == 0 "vmadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmadc.vxm carry-out writes a0"
.assert rd_wdata == 0x2 "e16 vmadc.vxm carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4642c657  # vmadc.vx v12, v4, t0
.assert trap == 0 "vmadc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmadc.vx ignores v0=0xFF and upper rs1 writes a0"
.assert rd_wdata == 0x0 "e16 vmadc.vx ignores v0=0xFF and upper rs1"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xfff00293  # addi t0, zero, -1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4042c457  # vadc.vxm v8, v4, t0, v0
.assert trap == 0 "vadc.vxm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vadc.vxm 0+MAX+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vadc.vxm 0+MAX+0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vxm 0+MAX+1 writes a0"
.assert rd_wdata == 0x0 "e16 vadc.vxm 0+MAX+1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vxm 1+MAX+0 writes a0"
.assert rd_wdata == 0x0 "e16 vadc.vxm 1+MAX+0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vxm MAX+MAX+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vadc.vxm MAX+MAX+1"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4442c657  # vmadc.vxm v12, v4, t0, v0
.assert trap == 0 "vmadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmadc.vxm rs1=-1 carry-out writes a0"
.assert rd_wdata == 0xe "e16 vmadc.vxm rs1=-1 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4642c657  # vmadc.vx v12, v4, t0
.assert trap == 0 "vmadc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmadc.vx rs1=-1 ignores v0=0xFF writes a0"
.assert rd_wdata == 0xc "e16 vmadc.vx rs1=-1 ignores v0=0xFF"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x404fb457  # vadc.vim v8, v4, -1, v0
.assert trap == 0 "vadc.vim retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vadc.vim 0+(-1)+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vadc.vim 0+(-1)+0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vim 0+(-1)+1 writes a0"
.assert rd_wdata == 0x0 "e16 vadc.vim 0+(-1)+1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vim 1+(-1)+0 writes a0"
.assert rd_wdata == 0x0 "e16 vadc.vim 1+(-1)+0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vadc.vim MAX+(-1)+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vadc.vim MAX+(-1)+1"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x444fb657  # vmadc.vim v12, v4, -1, v0
.assert trap == 0 "vmadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmadc.vim simm5=-1 carry-out writes a0"
.assert rd_wdata == 0xe "e16 vmadc.vim simm5=-1 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x464fb657  # vmadc.vi v12, v4, -1
.assert trap == 0 "vmadc.vi retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmadc.vi simm5=-1 ignores v0=0xFF writes a0"
.assert rd_wdata == 0xc "e16 vmadc.vi simm5=-1 ignores v0=0xFF"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vsbc.vvm 0-0-0 writes a0"
.assert rd_wdata == 0x0 "e16 vsbc.vvm 0-0-0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vsbc.vvm 0-0-1 underflow writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vsbc.vvm 0-0-1 underflow"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vsbc.vvm 0-MAX-1 double underflow writes a0"
.assert rd_wdata == 0x0 "e16 vsbc.vvm 0-MAX-1 double underflow"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vsbc.vvm SMIN-1-0 unsigned no borrow writes a0"
.assert rd_wdata == 0x7fff "e16 vsbc.vvm SMIN-1-0 unsigned no borrow"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4c430657  # vmsbc.vvm v12, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmsbc.vvm borrow-out writes a0"
.assert rd_wdata == 0x6 "e16 vmsbc.vvm borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4e430657  # vmsbc.vv v12, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmsbc.vv ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e16 vmsbc.vv ignores v0=0xFF"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vsbc.vvm 5-5-0 writes a0"
.assert rd_wdata == 0x0 "e16 vsbc.vvm 5-5-0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vsbc.vvm 5-5-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vsbc.vvm 5-5-1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vsbc.vvm SMAX-SMIN-0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vsbc.vvm SMAX-SMIN-0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vsbc.vvm MAX-MAX-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vsbc.vvm MAX-MAX-1"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4c430657  # vmsbc.vvm v12, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmsbc.vvm equal/sign borrow-out writes a0"
.assert rd_wdata == 0xe "e16 vmsbc.vvm equal/sign borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4e430657  # vmsbc.vv v12, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmsbc.vv equal/sign ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e16 vmsbc.vv equal/sign ignores v0=0xFF"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4842c457  # vsbc.vxm v8, v4, t0, v0
.assert trap == 0 "vsbc.vxm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vsbc.vxm 5-5-0 writes a0"
.assert rd_wdata == 0x0 "e16 vsbc.vxm 5-5-0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vsbc.vxm 5-5-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vsbc.vxm 5-5-1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vsbc.vxm 4-5-0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vsbc.vxm 4-5-0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e16 vsbc.vxm 6-5-0 writes a0"
.assert rd_wdata == 0x1 "e16 vsbc.vxm 6-5-0"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4c42c657  # vmsbc.vxm v12, v4, t0, v0
.assert trap == 0 "vmsbc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmsbc.vxm borrow-out writes a0"
.assert rd_wdata == 0x6 "e16 vmsbc.vxm borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x4e42c657  # vmsbc.vx v12, v4, t0
.assert trap == 0 "vmsbc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e16 vmsbc.vx ignores v0=0xFF and upper rs1 writes a0"
.assert rd_wdata == 0x4 "e16 vmsbc.vx ignores v0=0xFF and upper rs1"
# --- SEW=32 (m1): vadc/vmadc/vsbc/vmsbc ---
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x40430457  # vadc.vvm v8, v4, v6, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vadc.vvm MAX+0+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vadc.vvm MAX+0+0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vvm MAX+0+1 wrap writes a0"
.assert rd_wdata == 0x0 "e32 vadc.vvm MAX+0+1 wrap"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vvm MAX+MAX+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vadc.vvm MAX+MAX+1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vvm SMAX+1+0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vadc.vvm SMAX+1+0"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x44430657  # vmadc.vvm v12, v4, v6, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmadc.vvm carry-out writes a0"
.assert rd_wdata == 0x6 "e32 vmadc.vvm carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x46430657  # vmadc.vv v12, v4, v6
.assert trap == 0 "vmadc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmadc.vv ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e32 vmadc.vv ignores v0=0xFF"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4042c457  # vadc.vxm v8, v4, t0, v0
.assert trap == 0 "vadc.vxm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vadc.vxm MAX+0+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vadc.vxm MAX+0+0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vxm MAX+0+1 writes a0"
.assert rd_wdata == 0x0 "e32 vadc.vxm MAX+0+1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vxm 0+0+1 writes a0"
.assert rd_wdata == 0x1 "e32 vadc.vxm 0+0+1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vxm SMAX+0+0 writes a0"
.assert rd_wdata == 0x7fffffff "e32 vadc.vxm SMAX+0+0"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4442c657  # vmadc.vxm v12, v4, t0, v0
.assert trap == 0 "vmadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmadc.vxm carry-out writes a0"
.assert rd_wdata == 0x2 "e32 vmadc.vxm carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4642c657  # vmadc.vx v12, v4, t0
.assert trap == 0 "vmadc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmadc.vx ignores v0=0xFF and upper rs1 writes a0"
.assert rd_wdata == 0x0 "e32 vmadc.vx ignores v0=0xFF and upper rs1"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xfff00293  # addi t0, zero, -1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4042c457  # vadc.vxm v8, v4, t0, v0
.assert trap == 0 "vadc.vxm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vadc.vxm 0+MAX+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vadc.vxm 0+MAX+0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vxm 0+MAX+1 writes a0"
.assert rd_wdata == 0x0 "e32 vadc.vxm 0+MAX+1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vxm 1+MAX+0 writes a0"
.assert rd_wdata == 0x0 "e32 vadc.vxm 1+MAX+0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vxm MAX+MAX+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vadc.vxm MAX+MAX+1"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4442c657  # vmadc.vxm v12, v4, t0, v0
.assert trap == 0 "vmadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmadc.vxm rs1=-1 carry-out writes a0"
.assert rd_wdata == 0xe "e32 vmadc.vxm rs1=-1 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4642c657  # vmadc.vx v12, v4, t0
.assert trap == 0 "vmadc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmadc.vx rs1=-1 ignores v0=0xFF writes a0"
.assert rd_wdata == 0xc "e32 vmadc.vx rs1=-1 ignores v0=0xFF"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x404fb457  # vadc.vim v8, v4, -1, v0
.assert trap == 0 "vadc.vim retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vadc.vim 0+(-1)+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vadc.vim 0+(-1)+0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vim 0+(-1)+1 writes a0"
.assert rd_wdata == 0x0 "e32 vadc.vim 0+(-1)+1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vim 1+(-1)+0 writes a0"
.assert rd_wdata == 0x0 "e32 vadc.vim 1+(-1)+0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vadc.vim MAX+(-1)+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vadc.vim MAX+(-1)+1"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x444fb657  # vmadc.vim v12, v4, -1, v0
.assert trap == 0 "vmadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmadc.vim simm5=-1 carry-out writes a0"
.assert rd_wdata == 0xe "e32 vmadc.vim simm5=-1 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x464fb657  # vmadc.vi v12, v4, -1
.assert trap == 0 "vmadc.vi retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmadc.vi simm5=-1 ignores v0=0xFF writes a0"
.assert rd_wdata == 0xc "e32 vmadc.vi simm5=-1 ignores v0=0xFF"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vsbc.vvm 0-0-0 writes a0"
.assert rd_wdata == 0x0 "e32 vsbc.vvm 0-0-0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vsbc.vvm 0-0-1 underflow writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vsbc.vvm 0-0-1 underflow"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vsbc.vvm 0-MAX-1 double underflow writes a0"
.assert rd_wdata == 0x0 "e32 vsbc.vvm 0-MAX-1 double underflow"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vsbc.vvm SMIN-1-0 unsigned no borrow writes a0"
.assert rd_wdata == 0x7fffffff "e32 vsbc.vvm SMIN-1-0 unsigned no borrow"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4c430657  # vmsbc.vvm v12, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmsbc.vvm borrow-out writes a0"
.assert rd_wdata == 0x6 "e32 vmsbc.vvm borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4e430657  # vmsbc.vv v12, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmsbc.vv ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e32 vmsbc.vv ignores v0=0xFF"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vsbc.vvm 5-5-0 writes a0"
.assert rd_wdata == 0x0 "e32 vsbc.vvm 5-5-0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vsbc.vvm 5-5-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vsbc.vvm 5-5-1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vsbc.vvm SMAX-SMIN-0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vsbc.vvm SMAX-SMIN-0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vsbc.vvm MAX-MAX-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vsbc.vvm MAX-MAX-1"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4c430657  # vmsbc.vvm v12, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmsbc.vvm equal/sign borrow-out writes a0"
.assert rd_wdata == 0xe "e32 vmsbc.vvm equal/sign borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4e430657  # vmsbc.vv v12, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmsbc.vv equal/sign ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e32 vmsbc.vv equal/sign ignores v0=0xFF"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x0052e293  # ori t0, t0, 0x5
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4842c457  # vsbc.vxm v8, v4, t0, v0
.assert trap == 0 "vsbc.vxm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vsbc.vxm 5-5-0 writes a0"
.assert rd_wdata == 0x0 "e32 vsbc.vxm 5-5-0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vsbc.vxm 5-5-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vsbc.vxm 5-5-1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vsbc.vxm 4-5-0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vsbc.vxm 4-5-0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e32 vsbc.vxm 6-5-0 writes a0"
.assert rd_wdata == 0x1 "e32 vsbc.vxm 6-5-0"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4c42c657  # vmsbc.vxm v12, v4, t0, v0
.assert trap == 0 "vmsbc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmsbc.vxm borrow-out writes a0"
.assert rd_wdata == 0x6 "e32 vmsbc.vxm borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x4e42c657  # vmsbc.vx v12, v4, t0
.assert trap == 0 "vmsbc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e32 vmsbc.vx ignores v0=0xFF and upper rs1 writes a0"
.assert rd_wdata == 0x4 "e32 vmsbc.vx ignores v0=0xFF and upper rs1"
# --- SEW=64 (m2): vadc/vmadc/vsbc/vmsbc ---
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x40430457  # vadc.vvm v8, v4, v6, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vadc.vvm MAX+0+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vadc.vvm MAX+0+0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vvm MAX+0+1 wrap writes a0"
.assert rd_wdata == 0x0 "e64 vadc.vvm MAX+0+1 wrap"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vvm MAX+MAX+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vadc.vvm MAX+MAX+1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vvm SMAX+1+0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vadc.vvm SMAX+1+0"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x44430657  # vmadc.vvm v12, v4, v6, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vvm carry-out writes a0"
.assert rd_wdata == 0x6 "e64 vmadc.vvm carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x46430657  # vmadc.vv v12, v4, v6
.assert trap == 0 "vmadc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vv ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e64 vmadc.vv ignores v0=0xFF"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4042c457  # vadc.vxm v8, v4, t0, v0
.assert trap == 0 "vadc.vxm retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vadc.vxm MAX+0+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vadc.vxm MAX+0+0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vxm MAX+0+1 writes a0"
.assert rd_wdata == 0x0 "e64 vadc.vxm MAX+0+1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vxm 0+0+1 writes a0"
.assert rd_wdata == 0x1 "e64 vadc.vxm 0+0+1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vxm SMAX+0+0 writes a0"
.assert rd_wdata == 0x7fffffffffffffff "e64 vadc.vxm SMAX+0+0"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4442c657  # vmadc.vxm v12, v4, t0, v0
.assert trap == 0 "vmadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vxm carry-out writes a0"
.assert rd_wdata == 0x2 "e64 vmadc.vxm carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4642c657  # vmadc.vx v12, v4, t0
.assert trap == 0 "vmadc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vx ignores v0=0xFF and upper rs1 writes a0"
.assert rd_wdata == 0x0 "e64 vmadc.vx ignores v0=0xFF and upper rs1"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xfff00293  # addi t0, zero, -1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4042c457  # vadc.vxm v8, v4, t0, v0
.assert trap == 0 "vadc.vxm retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vadc.vxm 0+MAX+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vadc.vxm 0+MAX+0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vxm 0+MAX+1 writes a0"
.assert rd_wdata == 0x0 "e64 vadc.vxm 0+MAX+1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vxm 1+MAX+0 writes a0"
.assert rd_wdata == 0x0 "e64 vadc.vxm 1+MAX+0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vxm MAX+MAX+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vadc.vxm MAX+MAX+1"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4442c657  # vmadc.vxm v12, v4, t0, v0
.assert trap == 0 "vmadc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vxm rs1=-1 carry-out writes a0"
.assert rd_wdata == 0xe "e64 vmadc.vxm rs1=-1 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4642c657  # vmadc.vx v12, v4, t0
.assert trap == 0 "vmadc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vx rs1=-1 ignores v0=0xFF writes a0"
.assert rd_wdata == 0xc "e64 vmadc.vx rs1=-1 ignores v0=0xFF"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x404fb457  # vadc.vim v8, v4, -1, v0
.assert trap == 0 "vadc.vim retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vadc.vim 0+(-1)+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vadc.vim 0+(-1)+0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vim 0+(-1)+1 writes a0"
.assert rd_wdata == 0x0 "e64 vadc.vim 0+(-1)+1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vim 1+(-1)+0 writes a0"
.assert rd_wdata == 0x0 "e64 vadc.vim 1+(-1)+0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vim MAX+(-1)+1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vadc.vim MAX+(-1)+1"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x444fb657  # vmadc.vim v12, v4, -1, v0
.assert trap == 0 "vmadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vim simm5=-1 carry-out writes a0"
.assert rd_wdata == 0xe "e64 vmadc.vim simm5=-1 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x464fb657  # vmadc.vi v12, v4, -1
.assert trap == 0 "vmadc.vi retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vi simm5=-1 ignores v0=0xFF writes a0"
.assert rd_wdata == 0xc "e64 vmadc.vi simm5=-1 ignores v0=0xFF"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e07b257  # vmv.v.i v4, 15
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e07b257  # vmv.v.i v4, 15
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e023057  # vmv.v.i v0, 4
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x40483457  # vadc.vim v8, v4, -16, v0
.assert trap == 0 "vadc.vim retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vadc.vim 16+(-16)+0 writes a0"
.assert rd_wdata == 0x0 "e64 vadc.vim 16+(-16)+0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vim 15+(-16)+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vadc.vim 15+(-16)+0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vim 15+(-16)+1 writes a0"
.assert rd_wdata == 0x0 "e64 vadc.vim 15+(-16)+1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vim 0+(-16)+0 writes a0"
.assert rd_wdata == 0xfffffffffffffff0 "e64 vadc.vim 0+(-16)+0"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x44483657  # vmadc.vim v12, v4, -16, v0
.assert trap == 0 "vmadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vim simm5=-16 carry-out writes a0"
.assert rd_wdata == 0x5 "e64 vmadc.vim simm5=-16 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x46483657  # vmadc.vi v12, v4, -16
.assert trap == 0 "vmadc.vi retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vi simm5=-16 ignores v0=0xFF writes a0"
.assert rd_wdata == 0x1 "e64 vmadc.vi simm5=-16 ignores v0=0xFF"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e08b257  # vmv.v.i v4, -15
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e083257  # vmv.v.i v4, -16
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e083257  # vmv.v.i v4, -16
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4047b457  # vadc.vim v8, v4, 15, v0
.assert trap == 0 "vadc.vim retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vadc.vim (MAX-15)+15+0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vadc.vim (MAX-15)+15+0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vadc.vim (MAX-15)+15+1 writes a0"
.assert rd_wdata == 0x0 "e64 vadc.vim (MAX-15)+15+1"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4447b657  # vmadc.vim v12, v4, 15, v0
.assert trap == 0 "vmadc.vim retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vim simm5=+15 carry-out writes a0"
.assert rd_wdata == 0x6 "e64 vmadc.vim simm5=+15 carry-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4647b657  # vmadc.vi v12, v4, 15
.assert trap == 0 "vmadc.vi retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmadc.vi simm5=+15 ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e64 vmadc.vi simm5=+15 ignores v0=0xFF"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033057  # vmv.v.i v0, 6
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vsbc.vvm 0-0-0 writes a0"
.assert rd_wdata == 0x0 "e64 vsbc.vvm 0-0-0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vsbc.vvm 0-0-1 underflow writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vsbc.vvm 0-0-1 underflow"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vsbc.vvm 0-MAX-1 double underflow writes a0"
.assert rd_wdata == 0x0 "e64 vsbc.vvm 0-MAX-1 double underflow"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vsbc.vvm SMIN-1-0 unsigned no borrow writes a0"
.assert rd_wdata == 0x7fffffffffffffff "e64 vsbc.vvm SMIN-1-0 unsigned no borrow"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4c430657  # vmsbc.vvm v12, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmsbc.vvm borrow-out writes a0"
.assert rd_wdata == 0x6 "e64 vmsbc.vvm borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4e430657  # vmsbc.vv v12, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmsbc.vv ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e64 vmsbc.vv ignores v0=0xFF"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vsbc.vvm 5-5-0 writes a0"
.assert rd_wdata == 0x0 "e64 vsbc.vvm 5-5-0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vsbc.vvm 5-5-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vsbc.vvm 5-5-1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vsbc.vvm SMAX-SMIN-0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vsbc.vvm SMAX-SMIN-0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vsbc.vvm MAX-MAX-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vsbc.vvm MAX-MAX-1"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4c430657  # vmsbc.vvm v12, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmsbc.vvm equal/sign borrow-out writes a0"
.assert rd_wdata == 0xe "e64 vmsbc.vvm equal/sign borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4e430657  # vmsbc.vv v12, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmsbc.vv equal/sign ignores v0=0xFF writes a0"
.assert rd_wdata == 0x4 "e64 vmsbc.vv equal/sign ignores v0=0xFF"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4842c457  # vsbc.vxm v8, v4, t0, v0
.assert trap == 0 "vsbc.vxm retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vsbc.vxm 5-5-0 writes a0"
.assert rd_wdata == 0x0 "e64 vsbc.vxm 5-5-0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vsbc.vxm 5-5-1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vsbc.vxm 5-5-1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vsbc.vxm 4-5-0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vsbc.vxm 4-5-0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e64 vsbc.vxm 6-5-0 writes a0"
.assert rd_wdata == 0x1 "e64 vsbc.vxm 6-5-0"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4c42c657  # vmsbc.vxm v12, v4, t0, v0
.assert trap == 0 "vmsbc.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmsbc.vxm borrow-out writes a0"
.assert rd_wdata == 0x6 "e64 vmsbc.vxm borrow-out"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x4e42c657  # vmsbc.vx v12, v4, t0
.assert trap == 0 "vmsbc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e64 vmsbc.vx ignores v0=0xFF and upper rs1 writes a0"
.assert rd_wdata == 0x4 "e64 vmsbc.vx ignores v0=0xFF and upper rs1"
.4byte 0x009025f3  # csrr a1, vxsat
.assert rd_addr == 11 "vxsat (carry/borrow never sets vxsat) writes a1"
.assert rd_wdata == 0x0 "vxsat (carry/borrow never sets vxsat)"

# Section 3: Multi-limb 128-bit chain, multi-byte mask, tail/vl=0/VLMAX/LMULs.
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x5e0fb2d7  # vmv.v.i v5, -1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e0532d7  # vmv.v.i v5, 10
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x5e0033d7  # vmv.v.i v7, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e02b3d7  # vmv.v.i v7, 5
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x46430057  # vmadc.vv v0, v4, v6
.assert trap == 0 "vmadc.vv retires"
.4byte 0x02430457  # vadd.vv v8, v4, v6
.4byte 0x405384d7  # vadc.vvm v9, v5, v7, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0x44538557  # vmadc.vvm v10, v5, v7, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "128b add lane0 lo writes a0"
.assert rd_wdata == 0x0 "128b add lane0 lo"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "128b add lane0 hi with carry writes a0"
.assert rd_wdata == 0x10 "128b add lane0 hi with carry"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "128b add lane1 lo writes a0"
.assert rd_wdata == 0xffffffffffffffff "128b add lane1 lo"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e90b757  # vslidedown.vi v14, v9, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "128b add lane1 hi no carry writes a0"
.assert rd_wdata == 0xffffffffffffffff "128b add lane1 hi no carry"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "128b add hi carry-out writes a0"
.assert rd_wdata == 0x0 "128b add hi carry-out"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x5e0032d7  # vmv.v.i v5, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e02b2d7  # vmv.v.i v5, 5
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x5e0033d7  # vmv.v.i v7, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5e0133d7  # vmv.v.i v7, 2
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x4e430057  # vmsbc.vv v0, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0x0a430457  # vsub.vv v8, v4, v6
.4byte 0x485384d7  # vsbc.vvm v9, v5, v7, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0x4c538557  # vmsbc.vvm v10, v5, v7, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "128b sub lane0 lo writes a0"
.assert rd_wdata == 0xffffffffffffffff "128b sub lane0 lo"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "128b sub lane0 hi with borrow writes a0"
.assert rd_wdata == 0x2 "128b sub lane0 hi with borrow"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "128b sub lane1 lo writes a0"
.assert rd_wdata == 0xffffffffffffffff "128b sub lane1 lo"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e90b757  # vslidedown.vi v14, v9, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "128b sub lane1 hi underflow writes a0"
.assert rd_wdata == 0xffffffffffffffff "128b sub lane1 hi underflow"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "128b sub hi borrow-out writes a0"
.assert rd_wdata == 0x2 "128b sub hi borrow-out"
# Multi-byte mask read/write at e8, m2, vl=20 (bytes 0, 1, 2 + tail nibble preservation).
.4byte 0xc01a7657  # vsetivli a2, 20, e8, m2, tu, mu
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x5e02c257  # vmv.v.x v4, t0
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x000aa337  # lui t1, 0xaa
.4byte 0x55a30313  # addi t1, t1, 1370
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00f10337  # lui t1, 0xf10
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x42036657  # vmv.s.x v12, t1
.4byte 0xc01a7657  # vsetivli a2, 20, e8, m2, tu, mu
.4byte 0x40430457  # vadc.vvm v8, v4, v6, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0x44430657  # vmadc.vvm v12, v4, v6, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "e8 m2 vl=20 vmadc byte 0 writes a0"
.assert rd_wdata == 0x5a "e8 m2 vl=20 vmadc byte 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3ec0b757  # vslidedown.vi v14, v12, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vl=20 vmadc byte 1 writes a0"
.assert rd_wdata == 0xffffffffffffffa5 "e8 m2 vl=20 vmadc byte 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3ec13757  # vslidedown.vi v14, v12, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vl=20 vmadc byte 2 (tail nibble 0xF preserved) writes a0"
.assert rd_wdata == 0xfffffffffffffffa "e8 m2 vl=20 vmadc byte 2 (tail nibble 0xF preserved)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 m2 vadc lane 0 (c=0) writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 m2 vadc lane 0 (c=0)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vadc lane 1 (c=1) writes a0"
.assert rd_wdata == 0x0 "e8 m2 vadc lane 1 (c=1)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e843757  # vslidedown.vi v14, v8, 8
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vadc lane 8 (byte 1 c=1) writes a0"
.assert rd_wdata == 0x0 "e8 m2 vadc lane 8 (byte 1 c=1)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e87b757  # vslidedown.vi v14, v8, 15
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vadc lane 15 (byte 1 c=1) writes a0"
.assert rd_wdata == 0x0 "e8 m2 vadc lane 15 (byte 1 c=1)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e883757  # vslidedown.vi v14, v8, 16
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vadc lane 16 (reg+1, byte 2 c=0) writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 m2 vadc lane 16 (reg+1, byte 2 c=0)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e89b757  # vslidedown.vi v14, v8, 19
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vadc lane 19 (reg+1, byte 2 c=1) writes a0"
.assert rd_wdata == 0x0 "e8 m2 vadc lane 19 (reg+1, byte 2 c=1)"
.4byte 0xc01a7657  # vsetivli a2, 20, e8, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00a00337  # lui t1, 0xa00
.4byte 0x420366d7  # vmv.s.x v13, t1
.4byte 0xc01a7657  # vsetivli a2, 20, e8, m2, tu, mu
.4byte 0x48430557  # vsbc.vvm v10, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0x4c4306d7  # vmsbc.vvm v13, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42d02557  # vmv.x.s a0, v13
.assert rd_addr == 10 "e8 m2 vl=20 vmsbc byte 0 writes a0"
.assert rd_wdata == 0x5a "e8 m2 vl=20 vmsbc byte 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3ed0b757  # vslidedown.vi v14, v13, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vl=20 vmsbc byte 1 writes a0"
.assert rd_wdata == 0xffffffffffffffa5 "e8 m2 vl=20 vmsbc byte 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3ed13757  # vslidedown.vi v14, v13, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vl=20 vmsbc byte 2 (tail nibble 0xA preserved) writes a0"
.assert rd_wdata == 0xffffffffffffffaa "e8 m2 vl=20 vmsbc byte 2 (tail nibble 0xA preserved)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3ea83757  # vslidedown.vi v14, v10, 16
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vsbc lane 16 (b=0) writes a0"
.assert rd_wdata == 0x0 "e8 m2 vsbc lane 16 (b=0)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3ea9b757  # vslidedown.vi v14, v10, 19
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "e8 m2 vsbc lane 19 (b=1) writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 m2 vsbc lane 19 (b=1)"
# Tail policies (tu, ta) and vl == 0 noop.
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00004337  # lui t1, 0x4
.4byte 0x44430313  # addi t1, t1, 1092
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x33330313  # addi t1, t1, 819
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00002337  # lui t1, 0x2
.4byte 0x22230313  # addi t1, t1, 546
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x11130313  # addi t1, t1, 273
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x40000313  # addi t1, zero, 1024
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x30000313  # addi t1, zero, 768
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x20000313  # addi t1, zero, 512
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x10000313  # addi t1, zero, 256
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e023357  # vmv.v.i v6, 4
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e01b357  # vmv.v.i v6, 3
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e013357  # vmv.v.i v6, 2
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x40430457  # vadc.vvm v8, v4, v6, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "tu vadc lane 0 writes a0"
.assert rd_wdata == 0x102 "tu vadc lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "tu vadc lane 1 writes a0"
.assert rd_wdata == 0x202 "tu vadc lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813757  # vslidedown.vi v14, v8, 2
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "tu vadc preserves tail lane 2 writes a0"
.assert rd_wdata == 0x3333 "tu vadc preserves tail lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b757  # vslidedown.vi v14, v8, 3
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "tu vadc preserves tail lane 3 writes a0"
.assert rd_wdata == 0x4444 "tu vadc preserves tail lane 3"
.4byte 0xcc817657  # vsetivli a2, 2, e16, m1, ta, ma
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "ta vsbc lane 0 writes a0"
.assert rd_wdata == 0xfe "ta vsbc lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "ta vsbc lane 1 writes a0"
.assert rd_wdata == 0x1fe "ta vsbc lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x0a500313  # addi t1, zero, 165
.4byte 0x42036657  # vmv.s.x v12, t1
.4byte 0xc0807657  # vsetivli a2, 0, e16, m1, tu, mu
.assert rd_addr == 12 "vl=0 for carry/borrow writes a2"
.assert rd_wdata == 0x0 "vl=0 for carry/borrow"
.4byte 0x40430457  # vadc.vvm v8, v4, v6, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0x44430657  # vmadc.vvm v12, v4, v6, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0x48430457  # vsbc.vvm v8, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0x4e430657  # vmsbc.vv v12, v4, v6
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl=0 leaves v8[0] untouched writes a0"
.assert rd_wdata == 0xfe "vl=0 leaves v8[0] untouched"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42c02557  # vmv.x.s a0, v12
.assert rd_addr == 10 "vl=0 leaves mask v12 untouched writes a0"
.assert rd_wdata == 0xffffffffffffffa5 "vl=0 leaves mask v12 untouched"
# Portable VLMAX across mf8, mf4, mf2, m1, m4, m8.
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0030d7  # vmv.v.i v1, 0
.4byte 0x00507657  # vsetvli a2, zero, e8, mf8, tu, mu
.4byte 0x5e0fb457  # vmv.v.i v8, -1
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0x00507657  # vsetvli a2, zero, e8, mf8, tu, mu
.4byte 0x40880c57  # vadc.vvm v24, v8, v16, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0x448800d7  # vmadc.vvm v1, v8, v16, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e8 mf8 vadc lane 0 wraps writes a0"
.assert rd_wdata == 0x0 "VLMAX e8 mf8 vadc lane 0 wraps"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42102557  # vmv.x.s a0, v1
.assert rd_addr == 10 "VLMAX e8 mf8 vmadc byte 0 writes a0"
.assert rd_wdata == 0x1 "VLMAX e8 mf8 vmadc byte 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0030d7  # vmv.v.i v1, 0
.4byte 0x00507657  # vsetvli a2, zero, e8, mf8, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x48880c57  # vsbc.vvm v24, v8, v16, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0x4c8800d7  # vmsbc.vvm v1, v8, v16, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e8 mf8 vsbc lane 0 borrows writes a0"
.assert rd_wdata == 0xffffffffffffffff "VLMAX e8 mf8 vsbc lane 0 borrows"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42102557  # vmv.x.s a0, v1
.assert rd_addr == 10 "VLMAX e8 mf8 vmsbc byte 0 writes a0"
.assert rd_wdata == 0x1 "VLMAX e8 mf8 vmsbc byte 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0030d7  # vmv.v.i v1, 0
.4byte 0x00e07657  # vsetvli a2, zero, e16, mf4, tu, mu
.4byte 0x5e0fb457  # vmv.v.i v8, -1
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0x00e07657  # vsetvli a2, zero, e16, mf4, tu, mu
.4byte 0x40880c57  # vadc.vvm v24, v8, v16, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0x448800d7  # vmadc.vvm v1, v8, v16, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc0e0f657  # vsetivli a2, 1, e16, mf4, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e16 mf4 vadc lane 0 wraps writes a0"
.assert rd_wdata == 0x0 "VLMAX e16 mf4 vadc lane 0 wraps"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42102557  # vmv.x.s a0, v1
.assert rd_addr == 10 "VLMAX e16 mf4 vmadc byte 0 writes a0"
.assert rd_wdata == 0x1 "VLMAX e16 mf4 vmadc byte 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0030d7  # vmv.v.i v1, 0
.4byte 0x01707657  # vsetvli a2, zero, e32, mf2, tu, mu
.4byte 0x5e0fb457  # vmv.v.i v8, -1
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0x01707657  # vsetvli a2, zero, e32, mf2, tu, mu
.4byte 0x40880c57  # vadc.vvm v24, v8, v16, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0x448800d7  # vmadc.vvm v1, v8, v16, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e32 mf2 vadc lane 0 wraps writes a0"
.assert rd_wdata == 0x0 "VLMAX e32 mf2 vadc lane 0 wraps"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42102557  # vmv.x.s a0, v1
.assert rd_addr == 10 "VLMAX e32 mf2 vmadc byte 0 writes a0"
.assert rd_wdata == 0x1 "VLMAX e32 mf2 vmadc byte 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0030d7  # vmv.v.i v1, 0
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0fb457  # vmv.v.i v8, -1
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x40880c57  # vadc.vvm v24, v8, v16, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0x448800d7  # vmadc.vvm v1, v8, v16, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e64 m1 vadc lane 0 wraps writes a0"
.assert rd_wdata == 0x0 "VLMAX e64 m1 vadc lane 0 wraps"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42102557  # vmv.x.s a0, v1
.assert rd_addr == 10 "VLMAX e64 m1 vmadc byte 0 writes a0"
.assert rd_wdata == 0x1 "VLMAX e64 m1 vmadc byte 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0030d7  # vmv.v.i v1, 0
.4byte 0x01207657  # vsetvli a2, zero, e32, m4, tu, mu
.4byte 0x5e0fb457  # vmv.v.i v8, -1
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0x01207657  # vsetvli a2, zero, e32, m4, tu, mu
.4byte 0x40880c57  # vadc.vvm v24, v8, v16, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0x448800d7  # vmadc.vvm v1, v8, v16, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc120f657  # vsetivli a2, 1, e32, m4, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e32 m4 vadc lane 0 wraps writes a0"
.assert rd_wdata == 0x0 "VLMAX e32 m4 vadc lane 0 wraps"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42102557  # vmv.x.s a0, v1
.assert rd_addr == 10 "VLMAX e32 m4 vmadc byte 0 writes a0"
.assert rd_wdata == 0x1 "VLMAX e32 m4 vmadc byte 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0030d7  # vmv.v.i v1, 0
.4byte 0x01207657  # vsetvli a2, zero, e32, m4, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x48880c57  # vsbc.vvm v24, v8, v16, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0x4c8800d7  # vmsbc.vvm v1, v8, v16, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc120f657  # vsetivli a2, 1, e32, m4, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e32 m4 vsbc lane 0 borrows writes a0"
.assert rd_wdata == 0xffffffffffffffff "VLMAX e32 m4 vsbc lane 0 borrows"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42102557  # vmv.x.s a0, v1
.assert rd_addr == 10 "VLMAX e32 m4 vmsbc byte 0 writes a0"
.assert rd_wdata == 0x1 "VLMAX e32 m4 vmsbc byte 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0030d7  # vmv.v.i v1, 0
.4byte 0x01b07657  # vsetvli a2, zero, e64, m8, tu, mu
.4byte 0x5e0fb457  # vmv.v.i v8, -1
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0x01b07657  # vsetvli a2, zero, e64, m8, tu, mu
.4byte 0x40880c57  # vadc.vvm v24, v8, v16, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0x448800d7  # vmadc.vvm v1, v8, v16, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc1b0f657  # vsetivli a2, 1, e64, m8, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e64 m8 vadc lane 0 wraps writes a0"
.assert rd_wdata == 0x0 "VLMAX e64 m8 vadc lane 0 wraps"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42102557  # vmv.x.s a0, v1
.assert rd_addr == 10 "VLMAX e64 m8 vmadc byte 0 writes a0"
.assert rd_wdata == 0x1 "VLMAX e64 m8 vmadc byte 0"

# Section 4: Legal overlaps (in-place vadc/vsbc, vd==v0, vm=1 v0 source, m2 lowest reg).
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x02000313  # addi t1, zero, 32
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x40430257  # vadc.vvm v4, v4, v6, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "in-place vd==vs2 vadc[0] writes a0"
.assert rd_wdata == 0x15 "in-place vd==vs2 vadc[0]"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e40b757  # vslidedown.vi v14, v4, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "in-place vd==vs2 vadc[1] writes a0"
.assert rd_wdata == 0x0 "in-place vd==vs2 vadc[1]"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x48430357  # vsbc.vvm v6, v4, v6, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42602557  # vmv.x.s a0, v6
.assert rd_addr == 10 "in-place vd==vs1 vsbc[0] writes a0"
.assert rd_wdata == 0x10 "in-place vd==vs1 vsbc[0]"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e60b757  # vslidedown.vi v14, v6, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "in-place vd==vs1 vsbc[1] writes a0"
.assert rd_wdata == 0xffffffffffffffff "in-place vd==vs1 vsbc[1]"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x40420257  # vadc.vvm v4, v4, v4, v0
.assert trap == 0 "vadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "in-place vd==vs2==vs1 vadc[0] writes a0"
.assert rd_wdata == 0x2a "in-place vd==vs2==vs1 vadc[0]"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e40b757  # vslidedown.vi v14, v4, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "in-place vd==vs2==vs1 vadc[1] writes a0"
.assert rd_wdata == 0x1 "in-place vd==vs2==vs1 vadc[1]"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x48420257  # vsbc.vvm v4, v4, v4, v0
.assert trap == 0 "vsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "in-place vd==vs2==vs1 vsbc[0] writes a0"
.assert rd_wdata == 0x0 "in-place vd==vs2==vs1 vsbc[0]"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e40b757  # vslidedown.vi v14, v4, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "in-place vd==vs2==vs1 vsbc[1] writes a0"
.assert rd_wdata == 0xffffffffffffffff "in-place vd==vs2==vs1 vsbc[1]"
.4byte 0xc0067657  # vsetivli a2, 12, e8, m1, tu, mu
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0x5e02c257  # vmv.v.x v4, t0
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00001337  # lui t1, 0x1
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0067657  # vsetivli a2, 12, e8, m1, tu, mu
.4byte 0x44430057  # vmadc.vvm v0, v4, v6, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "in-place vd==v0 vmadc.vvm byte 0 writes a0"
.assert rd_wdata == 0x5a "in-place vd==v0 vmadc.vvm byte 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e00b757  # vslidedown.vi v14, v0, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "in-place vd==v0 vmadc.vvm byte 1 writes a0"
.assert rd_wdata == 0xa "in-place vd==v0 vmadc.vvm byte 1"
.4byte 0xc0067657  # vsetivli a2, 12, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0x4c430057  # vmsbc.vvm v0, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "in-place vd==v0 vmsbc.vvm byte 0 writes a0"
.assert rd_wdata == 0x5a "in-place vd==v0 vmsbc.vvm byte 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e00b757  # vslidedown.vi v14, v0, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "in-place vd==v0 vmsbc.vvm byte 1 writes a0"
.assert rd_wdata == 0xa "in-place vd==v0 vmsbc.vvm byte 1"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e0fb057  # vmv.v.i v0, -1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x46030057  # vmadc.vv v0, v0, v6
.assert trap == 0 "vmadc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "vm=1 vmadc.vv vd==vs2==v0 writes a0"
.assert rd_wdata == 0xfffffffffffffff5 "vm=1 vmadc.vv vd==vs2==v0"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e00b057  # vmv.v.i v0, 1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x4e400257  # vmsbc.vv v4, v4, v0
.assert trap == 0 "vmsbc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "vm=1 vmsbc.vv vs1==v0 vd==vs2 writes a0"
.assert rd_wdata == 0x5 "vm=1 vmsbc.vv vs1==v0 vd==vs2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e0fb257  # vmv.v.i v4, -1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x01200313  # addi t1, zero, 18
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x464304d7  # vmadc.vv v9, v4, v6
.assert trap == 0 "vmadc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "m2 odd vd=v9 vmadc.vv writes a0"
.assert rd_wdata == 0x9 "m2 odd vd=v9 vmadc.vv"
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x44430257  # vmadc.vvm v4, v4, v6, v0
.assert trap == 0 "vmadc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "m2 lowest-reg overlap vd==vs2 vmadc.vvm writes a0"
.assert rd_wdata == 0xfffffffffffffffb "m2 lowest-reg overlap vd==vs2 vmadc.vvm"
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e00b257  # vmv.v.i v4, 1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e00b357  # vmv.v.i v6, 1
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x01200313  # addi t1, zero, 18
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x4c430357  # vmsbc.vvm v6, v4, v6, v0
.assert trap == 0 "vmsbc.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42602557  # vmv.x.s a0, v6
.assert rd_addr == 10 "m2 lowest-reg overlap vd==vs1 vmsbc.vvm writes a0"
.assert rd_wdata == 0x16 "m2 lowest-reg overlap vd==vs1 vmsbc.vvm"

# Section 5: Illegal-instruction traps (mcause == 2, mtval == insn, destination untouched).
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x42430457  # .4byte vadc.vv reserved vm=1
.assert trap == 1 "vadc.vvm vm=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vadc.vvm vm=1 mcause writes a0"
.assert rd_wdata == 0x2 "vadc.vvm vm=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vadc.vvm vm=1 mtval writes a0"
.assert rd_wdata == 0x42430457 "vadc.vvm vm=1 mtval matches instruction"
.4byte 0x4242c457  # .4byte vadc.vx reserved vm=1
.assert trap == 1 "vadc.vxm vm=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vadc.vxm vm=1 mcause writes a0"
.assert rd_wdata == 0x2 "vadc.vxm vm=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vadc.vxm vm=1 mtval writes a0"
.assert rd_wdata == 0x4242c457 "vadc.vxm vm=1 mtval matches instruction"
.4byte 0x4240b457  # .4byte vadc.vi reserved vm=1
.assert trap == 1 "vadc.vim vm=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vadc.vim vm=1 mcause writes a0"
.assert rd_wdata == 0x2 "vadc.vim vm=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vadc.vim vm=1 mtval writes a0"
.assert rd_wdata == 0x4240b457 "vadc.vim vm=1 mtval matches instruction"
.4byte 0x4a430457  # .4byte vsbc.vv reserved vm=1
.assert trap == 1 "vsbc.vvm vm=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vsbc.vvm vm=1 mcause writes a0"
.assert rd_wdata == 0x2 "vsbc.vvm vm=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vsbc.vvm vm=1 mtval writes a0"
.assert rd_wdata == 0x4a430457 "vsbc.vvm vm=1 mtval matches instruction"
.4byte 0x4a42c457  # .4byte vsbc.vx reserved vm=1
.assert trap == 1 "vsbc.vxm vm=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vsbc.vxm vm=1 mcause writes a0"
.assert rd_wdata == 0x2 "vsbc.vxm vm=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vsbc.vxm vm=1 mtval writes a0"
.assert rd_wdata == 0x4a42c457 "vsbc.vxm vm=1 mtval matches instruction"
.4byte 0x4840b457  # .4byte vsbc.vim reserved vi
.assert trap == 1 "vsbc.vim reserved traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vsbc.vim reserved mcause writes a0"
.assert rd_wdata == 0x2 "vsbc.vim reserved illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vsbc.vim reserved mtval writes a0"
.assert rd_wdata == 0x4840b457 "vsbc.vim reserved mtval matches instruction"
.4byte 0x4e40b457  # .4byte vmsbc.vi reserved vi
.assert trap == 1 "vmsbc.vi reserved traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmsbc.vi reserved mcause writes a0"
.assert rd_wdata == 0x2 "vmsbc.vi reserved illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmsbc.vi reserved mtval writes a0"
.assert rd_wdata == 0x4e40b457 "vmsbc.vi reserved mtval matches instruction"
.4byte 0x4c40b457  # .4byte vmsbc.vim reserved vi
.assert trap == 1 "vmsbc.vim reserved traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmsbc.vim reserved mcause writes a0"
.assert rd_wdata == 0x2 "vmsbc.vim reserved illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmsbc.vim reserved mtval writes a0"
.assert rd_wdata == 0x4c40b457 "vmsbc.vim reserved mtval matches instruction"
.4byte 0x40430057  # vadc.vvm v0, v4, v6, v0
.assert trap == 1 "vadc vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vadc vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vadc vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vadc vd==v0 mtval writes a0"
.assert rd_wdata == 0x40430057 "vadc vd==v0 mtval matches instruction"
.4byte 0x4842c057  # vsbc.vxm v0, v4, t0, v0
.assert trap == 1 "vsbc vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vsbc vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vsbc vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vsbc vd==v0 mtval writes a0"
.assert rd_wdata == 0x4842c057 "vsbc vd==v0 mtval matches instruction"
.4byte 0x40030457  # vadc.vvm v8, v0, v6, v0
.assert trap == 1 "vadc vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vadc vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vadc vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vadc vs2==v0 mtval writes a0"
.assert rd_wdata == 0x40030457 "vadc vs2==v0 mtval matches instruction"
.4byte 0x48400457  # vsbc.vvm v8, v4, v0, v0
.assert trap == 1 "vsbc vs1==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vsbc vs1==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vsbc vs1==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vsbc vs1==v0 mtval writes a0"
.assert rd_wdata == 0x48400457 "vsbc vs1==v0 mtval matches instruction"
.4byte 0x44030457  # vmadc.vvm v8, v0, v6, v0
.assert trap == 1 "vmadc.vvm vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmadc.vvm vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmadc.vvm vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmadc.vvm vs2==v0 mtval writes a0"
.assert rd_wdata == 0x44030457 "vmadc.vvm vs2==v0 mtval matches instruction"
.4byte 0x4c400457  # vmsbc.vvm v8, v4, v0, v0
.assert trap == 1 "vmsbc.vvm vs1==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmsbc.vvm vs1==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmsbc.vvm vs1==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmsbc.vvm vs1==v0 mtval writes a0"
.assert rd_wdata == 0x4c400457 "vmsbc.vvm vs1==v0 mtval matches instruction"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "v8 sentinel untouched after traps 1-14 writes a0"
.assert rd_wdata == 0x42 "v8 sentinel untouched after traps 1-14"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "v0 sentinel untouched after traps 1-14 writes a0"
.assert rd_wdata == 0x33 "v0 sentinel untouched after traps 1-14"
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x404302d7  # vadc.vvm v5, v4, v6, v0
.assert trap == 1 "vadc m2 misaligned vd traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vadc m2 misaligned vd mcause writes a0"
.assert rd_wdata == 0x2 "vadc m2 misaligned vd illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vadc m2 misaligned vd mtval writes a0"
.assert rd_wdata == 0x404302d7 "vadc m2 misaligned vd mtval matches instruction"
.4byte 0x465304d7  # vmadc.vv v9, v5, v6
.assert trap == 1 "vmadc m2 misaligned vs2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmadc m2 misaligned vs2 mcause writes a0"
.assert rd_wdata == 0x2 "vmadc m2 misaligned vs2 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmadc m2 misaligned vs2 mtval writes a0"
.assert rd_wdata == 0x465304d7 "vmadc m2 misaligned vs2 mtval matches instruction"
.4byte 0x48438457  # vsbc.vvm v8, v4, v7, v0
.assert trap == 1 "vsbc m2 misaligned vs1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vsbc m2 misaligned vs1 mcause writes a0"
.assert rd_wdata == 0x2 "vsbc m2 misaligned vs1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vsbc m2 misaligned vs1 mtval writes a0"
.assert rd_wdata == 0x48438457 "vsbc m2 misaligned vs1 mtval matches instruction"
.4byte 0xc200f657  # vsetivli a2, 1, 0x20 (sets vill=1)
.assert rd_addr == 12 "vill vsetivli writes a2"
.assert rd_wdata == 0x0 "vill vsetivli sets vl=0"
.4byte 0x40430457  # vadc.vvm v8, v4, v6, v0
.assert trap == 1 "vadc under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vadc under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vadc under vill=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vadc under vill=1 mtval writes a0"
.assert rd_wdata == 0x40430457 "vadc under vill=1 mtval matches instruction"
