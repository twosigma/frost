# Directed TestRIG trace for the 18 remaining non-segment base-V integer encodings:
# 16 .vx forms (vrsub, vand, vsll/vsrl/vsra, vminu/vmin/vmaxu/vmax, vmulhu/vmulh/vmulhsu,
# vdivu/vdiv/vremu/vrem) and vmerge.vvm / vmerge.vxm.
# VLEN-portable across VLEN 128, 256, and 512; zero misa accesses.

# Preamble: enable mstatus.FS and mstatus.VS, zero v0..v31.
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0x60028293  # addi t0, t0, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x003072d7  # vsetvli t0, zero, e8, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0

# Section 1: Control readout (vmv.x.s a0, v20 = 0x43402557).
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x200212b7  # lui t0, 0x20021
.4byte 0x02028293  # addi t0, t0, 32
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x0e62ca57  # vrsub.vx v20, v6, t0
.assert trap == 0 "vrsub.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x43402557  # vmv.x.s a0, v20
.assert rd_addr == 10 "ctrl vrsub.vx lane 0 writes a0"
.assert rd_wdata == 0x20020020 "ctrl vrsub.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f40b857  # vslidedown.vi v16, v20, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "ctrl vrsub.vx lane 1 writes a0"
.assert rd_wdata == 0x2002101b "ctrl vrsub.vx lane 1"

# Section 2: All 18 encodings at SEW 8/16/32/64 (truncation, signedness, div/0, MIN/-1, merge).
# --- SEW=8 (m1) ---
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x07f00313  # addi t1, zero, 127
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x0fdf8f93  # addi t6, t6, 253
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x0e62c457  # vrsub.vx v8, v6, t0
.assert trap == 0 "vrsub.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vrsub.vx lane 0 writes a0"
.assert rd_wdata == 0x7d "e8 vrsub.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vrsub.vx lane 1 writes a0"
.assert rd_wdata == 0x7e "e8 vrsub.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vrsub.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "e8 vrsub.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vrsub.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e8 vrsub.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x2662c457  # vand.vx v8, v6, t0
.assert trap == 0 "vand.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vand.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vand.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vand.vx lane 1 writes a0"
.assert rd_wdata == 0x7d "e8 vand.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vand.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e8 vand.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vand.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vand.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x1262c457  # vminu.vx v8, v6, t0
.assert trap == 0 "vminu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vminu.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vminu.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vminu.vx lane 1 writes a0"
.assert rd_wdata == 0x7f "e8 vminu.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vminu.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e8 vminu.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vminu.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vminu.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x1662c457  # vmin.vx v8, v6, t0
.assert trap == 0 "vmin.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmin.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vmin.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmin.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vmin.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmin.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vmin.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmin.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vmin.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x1a62c457  # vmaxu.vx v8, v6, t0
.assert trap == 0 "vmaxu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmaxu.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vmaxu.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmaxu.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vmaxu.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmaxu.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vmaxu.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmaxu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vmaxu.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x1e62c457  # vmax.vx v8, v6, t0
.assert trap == 0 "vmax.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmax.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vmax.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmax.vx lane 1 writes a0"
.assert rd_wdata == 0x7f "e8 vmax.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmax.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e8 vmax.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmax.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vmax.vx lane 3"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x0ef00313  # addi t1, zero, 239
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x07c00313  # addi t1, zero, 124
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x0a500313  # addi t1, zero, 165
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x00bf8f93  # addi t6, t6, 11
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x9662c457  # vsll.vx v8, v6, t0
.assert trap == 0 "vsll.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vsll.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0x28 "e8 vsll.vx sh3 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsll.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "e8 vsll.vx sh3 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsll.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0x78 "e8 vsll.vx sh3 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xa262c457  # vsrl.vx v8, v6, t0
.assert trap == 0 "vsrl.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vsrl.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0x14 "e8 vsrl.vx sh3 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsrl.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xf "e8 vsrl.vx sh3 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsrl.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0x1d "e8 vsrl.vx sh3 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xa662c457  # vsra.vx v8, v6, t0
.assert trap == 0 "vsra.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vsra.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "e8 vsra.vx sh3 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsra.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xf "e8 vsra.vx sh3 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsra.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vsra.vx sh3 lane 2"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x01ff8f93  # addi t6, t6, 31
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x9662c457  # vsll.vx v8, v6, t0
.assert trap == 0 "vsll.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vsll.vx shmax lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vsll.vx shmax lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsll.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e8 vsll.vx shmax lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsll.vx shmax lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vsll.vx shmax lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xa262c457  # vsrl.vx v8, v6, t0
.assert trap == 0 "vsrl.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vsrl.vx shmax lane 0 writes a0"
.assert rd_wdata == 0x1 "e8 vsrl.vx shmax lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsrl.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e8 vsrl.vx shmax lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsrl.vx shmax lane 2 writes a0"
.assert rd_wdata == 0x1 "e8 vsrl.vx shmax lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0xa662c457  # vsra.vx v8, v6, t0
.assert trap == 0 "vsra.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vsra.vx shmax lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vsra.vx shmax lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsra.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e8 vsra.vx shmax lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vsra.vx shmax lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vsra.vx shmax lane 2"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x5e06b357  # vmv.v.i v6, 13
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0db357  # vmv.v.i v6, -5
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x087f8f93  # addi t6, t6, 135
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x9262e457  # vmulhu.vx v8, v6, t0
.assert trap == 0 "vmulhu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmulhu.vx lane 0 writes a0"
.assert rd_wdata == 0x43 "e8 vmulhu.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmulhu.vx lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffff84 "e8 vmulhu.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmulhu.vx lane 2 writes a0"
.assert rd_wdata == 0x6 "e8 vmulhu.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmulhu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffff86 "e8 vmulhu.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x9e62e457  # vmulh.vx v8, v6, t0
.assert trap == 0 "vmulh.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmulh.vx lane 0 writes a0"
.assert rd_wdata == 0x3c "e8 vmulh.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmulh.vx lane 1 writes a0"
.assert rd_wdata == 0x2 "e8 vmulh.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmulh.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff9 "e8 vmulh.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmulh.vx lane 3 writes a0"
.assert rd_wdata == 0x0 "e8 vmulh.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x9a62e457  # vmulhsu.vx v8, v6, t0
.assert trap == 0 "vmulhsu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmulhsu.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffbc "e8 vmulhsu.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmulhsu.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vmulhsu.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmulhsu.vx lane 2 writes a0"
.assert rd_wdata == 0x6 "e8 vmulhsu.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmulhsu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vmulhsu.vx lane 3"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x01d00313  # addi t1, zero, 29
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x0ef00313  # addi t1, zero, 239
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vdivu.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0x19 "e8 vdivu.vx pos5 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdivu.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0x2f "e8 vdivu.vx pos5 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdivu.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x5 "e8 vdivu.vx pos5 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vdiv.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffe7 "e8 vdiv.vx pos5 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdiv.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vdiv.vx pos5 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdiv.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x5 "e8 vdiv.vx pos5 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vremu.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0x3 "e8 vremu.vx pos5 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vremu.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0x4 "e8 vremu.vx pos5 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vremu.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x4 "e8 vremu.vx pos5 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vrem.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vrem.vx pos5 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vrem.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e8 vrem.vx pos5 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vrem.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x4 "e8 vrem.vx pos5 lane 2"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x0fdf8f93  # addi t6, t6, 253
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vdivu.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0x0 "e8 vdivu.vx neg3 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdivu.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0x0 "e8 vdivu.vx neg3 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdivu.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x0 "e8 vdivu.vx neg3 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vdiv.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0x2a "e8 vdiv.vx neg3 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdiv.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0x5 "e8 vdiv.vx neg3 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdiv.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "e8 vdiv.vx neg3 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vremu.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vremu.vx neg3 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vremu.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e8 vremu.vx neg3 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vremu.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x1d "e8 vremu.vx neg3 lane 2"
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vrem.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e8 vrem.vx neg3 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vrem.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e8 vrem.vx neg3 lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vrem.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x2 "e8 vrem.vx neg3 lane 2"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vdivu.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vdivu.vx div0 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdivu.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vdivu.vx div0 lane 1"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vdiv.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vdiv.vx div0 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdiv.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vdiv.vx div0 lane 1"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vremu.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vremu.vx div0 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vremu.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e8 vremu.vx div0 lane 1"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vrem.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vrem.vx div0 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vrem.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e8 vrem.vx div0 lane 1"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x0fff8f93  # addi t6, t6, 255
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vdivu.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x0 "e8 vdivu.vx min_neg1 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdivu.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x0 "e8 vdivu.vx min_neg1 lane 1"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vdiv.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vdiv.vx min_neg1 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vdiv.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x11 "e8 vdiv.vx min_neg1 lane 1"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vremu.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "e8 vremu.vx min_neg1 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vremu.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e8 vremu.vx min_neg1 lane 1"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vrem.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x0 "e8 vrem.vx min_neg1 lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vrem.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x0 "e8 vrem.vx min_neg1 lane 1"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e0db357  # vmv.v.i v6, -5
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08300313  # addi t1, zero, 131
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x02200313  # addi t1, zero, 34
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x07e00313  # addi t1, zero, 126
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x05500313  # addi t1, zero, 85
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x04400313  # addi t1, zero, 68
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5c620457  # vmerge.vvm v8, v6, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmerge.vvm lane 0 writes a0"
.assert rd_wdata == 0x11 "e8 vmerge.vvm lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmerge.vvm lane 1 writes a0"
.assert rd_wdata == 0x55 "e8 vmerge.vvm lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmerge.vvm lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff83 "e8 vmerge.vvm lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmerge.vvm lane 3 writes a0"
.assert rd_wdata == 0x77 "e8 vmerge.vvm lane 3"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x066f8f93  # addi t6, t6, 102
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5c62c457  # vmerge.vxm v8, v6, t0, v0
.assert trap == 0 "vmerge.vxm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmerge.vxm lane 0 writes a0"
.assert rd_wdata == 0x11 "e8 vmerge.vxm lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmerge.vxm lane 1 writes a0"
.assert rd_wdata == 0x66 "e8 vmerge.vxm lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmerge.vxm lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff83 "e8 vmerge.vxm lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmerge.vxm lane 3 writes a0"
.assert rd_wdata == 0x66 "e8 vmerge.vxm lane 3"
# --- SEW=16 (m1) ---
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33450fb7  # lui t6, 0x33450
.4byte 0xffdf8f93  # addi t6, t6, -3
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x0e62c457  # vrsub.vx v8, v6, t0
.assert trap == 0 "vrsub.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vrsub.vx lane 0 writes a0"
.assert rd_wdata == 0x7ffd "e16 vrsub.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vrsub.vx lane 1 writes a0"
.assert rd_wdata == 0x7ffe "e16 vrsub.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vrsub.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "e16 vrsub.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vrsub.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e16 vrsub.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x2662c457  # vand.vx v8, v6, t0
.assert trap == 0 "vand.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vand.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vand.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vand.vx lane 1 writes a0"
.assert rd_wdata == 0x7ffd "e16 vand.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vand.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e16 vand.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vand.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vand.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x1262c457  # vminu.vx v8, v6, t0
.assert trap == 0 "vminu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vminu.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vminu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vminu.vx lane 1 writes a0"
.assert rd_wdata == 0x7fff "e16 vminu.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vminu.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e16 vminu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vminu.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vminu.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x1662c457  # vmin.vx v8, v6, t0
.assert trap == 0 "vmin.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmin.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vmin.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmin.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vmin.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmin.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vmin.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmin.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vmin.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x1a62c457  # vmaxu.vx v8, v6, t0
.assert trap == 0 "vmaxu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmaxu.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vmaxu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmaxu.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vmaxu.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmaxu.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vmaxu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmaxu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vmaxu.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x1e62c457  # vmax.vx v8, v6, t0
.assert trap == 0 "vmax.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmax.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vmax.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmax.vx lane 1 writes a0"
.assert rd_wdata == 0x7fff "e16 vmax.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmax.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e16 vmax.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmax.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vmax.vx lane 3"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xfef30313  # addi t1, t1, -17
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xffc30313  # addi t1, t1, -4
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x02530313  # addi t1, t1, 37
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x013f8f93  # addi t6, t6, 19
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x9662c457  # vsll.vx v8, v6, t0
.assert trap == 0 "vsll.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vsll.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0x128 "e16 vsll.vx sh3 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsll.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "e16 vsll.vx sh3 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsll.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff78 "e16 vsll.vx sh3 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xa262c457  # vsrl.vx v8, v6, t0
.assert trap == 0 "vsrl.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vsrl.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0x1004 "e16 vsrl.vx sh3 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsrl.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xfff "e16 vsrl.vx sh3 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsrl.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0x1ffd "e16 vsrl.vx sh3 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xa662c457  # vsra.vx v8, v6, t0
.assert trap == 0 "vsra.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vsra.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffff004 "e16 vsra.vx sh3 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsra.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xfff "e16 vsra.vx sh3 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsra.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vsra.vx sh3 lane 2"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x03ff8f93  # addi t6, t6, 63
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x9662c457  # vsll.vx v8, v6, t0
.assert trap == 0 "vsll.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vsll.vx shmax lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vsll.vx shmax lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsll.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e16 vsll.vx shmax lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsll.vx shmax lane 2 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vsll.vx shmax lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xa262c457  # vsrl.vx v8, v6, t0
.assert trap == 0 "vsrl.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vsrl.vx shmax lane 0 writes a0"
.assert rd_wdata == 0x1 "e16 vsrl.vx shmax lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsrl.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e16 vsrl.vx shmax lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsrl.vx shmax lane 2 writes a0"
.assert rd_wdata == 0x1 "e16 vsrl.vx shmax lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0xa662c457  # vsra.vx v8, v6, t0
.assert trap == 0 "vsra.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vsra.vx shmax lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vsra.vx shmax lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsra.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e16 vsra.vx shmax lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vsra.vx shmax lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vsra.vx shmax lane 2"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e06b357  # vmv.v.i v6, 13
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0db357  # vmv.v.i v6, -5
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33448fb7  # lui t6, 0x33448
.4byte 0x007f8f93  # addi t6, t6, 7
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x9262e457  # vmulhu.vx v8, v6, t0
.assert trap == 0 "vmulhu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmulhu.vx lane 0 writes a0"
.assert rd_wdata == 0x4003 "e16 vmulhu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmulhu.vx lane 1 writes a0"
.assert rd_wdata == 0xffffffffffff8004 "e16 vmulhu.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmulhu.vx lane 2 writes a0"
.assert rd_wdata == 0x6 "e16 vmulhu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmulhu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffff8006 "e16 vmulhu.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x9e62e457  # vmulh.vx v8, v6, t0
.assert trap == 0 "vmulh.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmulh.vx lane 0 writes a0"
.assert rd_wdata == 0x3ffc "e16 vmulh.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmulh.vx lane 1 writes a0"
.assert rd_wdata == 0x2 "e16 vmulh.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmulh.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff9 "e16 vmulh.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmulh.vx lane 3 writes a0"
.assert rd_wdata == 0x0 "e16 vmulh.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x9a62e457  # vmulhsu.vx v8, v6, t0
.assert trap == 0 "vmulhsu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmulhsu.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffbffc "e16 vmulhsu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmulhsu.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vmulhsu.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmulhsu.vx lane 2 writes a0"
.assert rd_wdata == 0x6 "e16 vmulhsu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmulhsu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vmulhsu.vx lane 3"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x01d00313  # addi t1, zero, 29
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xfef30313  # addi t1, t1, -17
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vdivu.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0x1999 "e16 vdivu.vx pos5 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdivu.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0x332f "e16 vdivu.vx pos5 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdivu.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x5 "e16 vdivu.vx pos5 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vdiv.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffe667 "e16 vdiv.vx pos5 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdiv.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vdiv.vx pos5 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdiv.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x5 "e16 vdiv.vx pos5 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vremu.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0x3 "e16 vremu.vx pos5 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vremu.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0x4 "e16 vremu.vx pos5 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vremu.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x4 "e16 vremu.vx pos5 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vrem.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vrem.vx pos5 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vrem.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e16 vrem.vx pos5 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vrem.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x4 "e16 vrem.vx pos5 lane 2"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33450fb7  # lui t6, 0x33450
.4byte 0xffdf8f93  # addi t6, t6, -3
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vdivu.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0x0 "e16 vdivu.vx neg3 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdivu.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0x0 "e16 vdivu.vx neg3 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdivu.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x0 "e16 vdivu.vx neg3 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vdiv.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0x2aaa "e16 vdiv.vx neg3 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdiv.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0x5 "e16 vdiv.vx neg3 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdiv.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "e16 vdiv.vx neg3 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vremu.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vremu.vx neg3 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vremu.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e16 vremu.vx neg3 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vremu.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x1d "e16 vremu.vx neg3 lane 2"
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vrem.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e16 vrem.vx neg3 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vrem.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e16 vrem.vx neg3 lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vrem.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x2 "e16 vrem.vx neg3 lane 2"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vdivu.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vdivu.vx div0 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdivu.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vdivu.vx div0 lane 1"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vdiv.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vdiv.vx div0 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdiv.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vdiv.vx div0 lane 1"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vremu.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vremu.vx div0 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vremu.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e16 vremu.vx div0 lane 1"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vrem.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vrem.vx div0 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vrem.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e16 vrem.vx div0 lane 1"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33450fb7  # lui t6, 0x33450
.4byte 0xffff8f93  # addi t6, t6, -1
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vdivu.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x0 "e16 vdivu.vx min_neg1 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdivu.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x0 "e16 vdivu.vx min_neg1 lane 1"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vdiv.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vdiv.vx min_neg1 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vdiv.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x11 "e16 vdiv.vx min_neg1 lane 1"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vremu.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "e16 vremu.vx min_neg1 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vremu.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e16 vremu.vx min_neg1 lane 1"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vrem.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x0 "e16 vrem.vx min_neg1 lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vrem.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x0 "e16 vrem.vx min_neg1 lane 1"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e0db357  # vmv.v.i v6, -5
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x02200313  # addi t1, zero, 34
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xffe30313  # addi t1, t1, -2
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x05500313  # addi t1, zero, 85
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x04400313  # addi t1, zero, 68
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5c620457  # vmerge.vvm v8, v6, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmerge.vvm lane 0 writes a0"
.assert rd_wdata == 0x11 "e16 vmerge.vvm lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmerge.vvm lane 1 writes a0"
.assert rd_wdata == 0x55 "e16 vmerge.vvm lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmerge.vvm lane 2 writes a0"
.assert rd_wdata == 0xffffffffffff8003 "e16 vmerge.vvm lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmerge.vvm lane 3 writes a0"
.assert rd_wdata == 0x77 "e16 vmerge.vvm lane 3"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33446fb7  # lui t6, 0x33446
.4byte 0xa66f8f93  # addi t6, t6, -1434
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5c62c457  # vmerge.vxm v8, v6, t0, v0
.assert trap == 0 "vmerge.vxm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmerge.vxm lane 0 writes a0"
.assert rd_wdata == 0x11 "e16 vmerge.vxm lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmerge.vxm lane 1 writes a0"
.assert rd_wdata == 0x5a66 "e16 vmerge.vxm lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmerge.vxm lane 2 writes a0"
.assert rd_wdata == 0xffffffffffff8003 "e16 vmerge.vxm lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmerge.vxm lane 3 writes a0"
.assert rd_wdata == 0x5a66 "e16 vmerge.vxm lane 3"
# --- SEW=32 (m1) ---
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xffd00f93  # addi t6, zero, -3
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x0e62c457  # vrsub.vx v8, v6, t0
.assert trap == 0 "vrsub.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vrsub.vx lane 0 writes a0"
.assert rd_wdata == 0x7ffffffd "e32 vrsub.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vrsub.vx lane 1 writes a0"
.assert rd_wdata == 0x7ffffffe "e32 vrsub.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vrsub.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "e32 vrsub.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vrsub.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e32 vrsub.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x2662c457  # vand.vx v8, v6, t0
.assert trap == 0 "vand.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vand.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vand.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vand.vx lane 1 writes a0"
.assert rd_wdata == 0x7ffffffd "e32 vand.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vand.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e32 vand.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vand.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vand.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x1262c457  # vminu.vx v8, v6, t0
.assert trap == 0 "vminu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vminu.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vminu.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vminu.vx lane 1 writes a0"
.assert rd_wdata == 0x7fffffff "e32 vminu.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vminu.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e32 vminu.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vminu.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vminu.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x1662c457  # vmin.vx v8, v6, t0
.assert trap == 0 "vmin.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmin.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vmin.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmin.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vmin.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmin.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vmin.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmin.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vmin.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x1a62c457  # vmaxu.vx v8, v6, t0
.assert trap == 0 "vmaxu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmaxu.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vmaxu.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmaxu.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vmaxu.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmaxu.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vmaxu.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmaxu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vmaxu.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x1e62c457  # vmax.vx v8, v6, t0
.assert trap == 0 "vmax.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmax.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vmax.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmax.vx lane 1 writes a0"
.assert rd_wdata == 0x7fffffff "e32 vmax.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmax.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e32 vmax.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmax.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vmax.vx lane 3"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfef00f93  # addi t6, zero, -17
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xffc30313  # addi t1, t1, -4
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x025f8f93  # addi t6, t6, 37
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x0232e293  # ori t0, t0, 0x23
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x9662c457  # vsll.vx v8, v6, t0
.assert trap == 0 "vsll.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vsll.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0x128 "e32 vsll.vx sh3 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsll.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "e32 vsll.vx sh3 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsll.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff78 "e32 vsll.vx sh3 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xa262c457  # vsrl.vx v8, v6, t0
.assert trap == 0 "vsrl.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vsrl.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0x10000004 "e32 vsrl.vx sh3 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsrl.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xfffffff "e32 vsrl.vx sh3 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsrl.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0x1ffffffd "e32 vsrl.vx sh3 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xa662c457  # vsra.vx v8, v6, t0
.assert trap == 0 "vsra.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vsra.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0xfffffffff0000004 "e32 vsra.vx sh3 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsra.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xfffffff "e32 vsra.vx sh3 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsra.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vsra.vx sh3 lane 2"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x07f2e293  # ori t0, t0, 0x7f
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x9662c457  # vsll.vx v8, v6, t0
.assert trap == 0 "vsll.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vsll.vx shmax lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vsll.vx shmax lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsll.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e32 vsll.vx shmax lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsll.vx shmax lane 2 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vsll.vx shmax lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xa262c457  # vsrl.vx v8, v6, t0
.assert trap == 0 "vsrl.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vsrl.vx shmax lane 0 writes a0"
.assert rd_wdata == 0x1 "e32 vsrl.vx shmax lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsrl.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e32 vsrl.vx shmax lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsrl.vx shmax lane 2 writes a0"
.assert rd_wdata == 0x1 "e32 vsrl.vx shmax lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0xa662c457  # vsra.vx v8, v6, t0
.assert trap == 0 "vsra.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vsra.vx shmax lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vsra.vx shmax lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsra.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e32 vsra.vx shmax lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vsra.vx shmax lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vsra.vx shmax lane 2"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e06b357  # vmv.v.i v6, 13
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0db357  # vmv.v.i v6, -5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x007f8f93  # addi t6, t6, 7
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x9262e457  # vmulhu.vx v8, v6, t0
.assert trap == 0 "vmulhu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmulhu.vx lane 0 writes a0"
.assert rd_wdata == 0x40000003 "e32 vmulhu.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmulhu.vx lane 1 writes a0"
.assert rd_wdata == 0xffffffff80000004 "e32 vmulhu.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmulhu.vx lane 2 writes a0"
.assert rd_wdata == 0x6 "e32 vmulhu.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmulhu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffff80000006 "e32 vmulhu.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x9e62e457  # vmulh.vx v8, v6, t0
.assert trap == 0 "vmulh.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmulh.vx lane 0 writes a0"
.assert rd_wdata == 0x3ffffffc "e32 vmulh.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmulh.vx lane 1 writes a0"
.assert rd_wdata == 0x2 "e32 vmulh.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmulh.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff9 "e32 vmulh.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmulh.vx lane 3 writes a0"
.assert rd_wdata == 0x0 "e32 vmulh.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x9a62e457  # vmulhsu.vx v8, v6, t0
.assert trap == 0 "vmulhsu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmulhsu.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffbffffffc "e32 vmulhsu.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmulhsu.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vmulhsu.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmulhsu.vx lane 2 writes a0"
.assert rd_wdata == 0x6 "e32 vmulhsu.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmulhsu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vmulhsu.vx lane 3"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x01d00313  # addi t1, zero, 29
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfef00f93  # addi t6, zero, -17
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x0052e293  # ori t0, t0, 0x5
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vdivu.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0x19999999 "e32 vdivu.vx pos5 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdivu.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0x3333332f "e32 vdivu.vx pos5 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdivu.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x5 "e32 vdivu.vx pos5 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vdiv.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0xffffffffe6666667 "e32 vdiv.vx pos5 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdiv.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vdiv.vx pos5 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdiv.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x5 "e32 vdiv.vx pos5 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vremu.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0x3 "e32 vremu.vx pos5 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vremu.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0x4 "e32 vremu.vx pos5 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vremu.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x4 "e32 vremu.vx pos5 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vrem.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vrem.vx pos5 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vrem.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e32 vrem.vx pos5 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vrem.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x4 "e32 vrem.vx pos5 lane 2"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xffd00f93  # addi t6, zero, -3
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vdivu.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0x0 "e32 vdivu.vx neg3 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdivu.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0x0 "e32 vdivu.vx neg3 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdivu.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x0 "e32 vdivu.vx neg3 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vdiv.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0x2aaaaaaa "e32 vdiv.vx neg3 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdiv.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0x5 "e32 vdiv.vx neg3 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdiv.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "e32 vdiv.vx neg3 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vremu.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vremu.vx neg3 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vremu.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e32 vremu.vx neg3 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vremu.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x1d "e32 vremu.vx neg3 lane 2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vrem.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e32 vrem.vx neg3 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vrem.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e32 vrem.vx neg3 lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vrem.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x2 "e32 vrem.vx neg3 lane 2"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vdivu.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vdivu.vx div0 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdivu.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vdivu.vx div0 lane 1"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vdiv.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vdiv.vx div0 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdiv.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vdiv.vx div0 lane 1"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vremu.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vremu.vx div0 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vremu.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e32 vremu.vx div0 lane 1"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vrem.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vrem.vx div0 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vrem.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e32 vrem.vx div0 lane 1"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vdivu.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x0 "e32 vdivu.vx min_neg1 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdivu.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x0 "e32 vdivu.vx min_neg1 lane 1"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vdiv.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vdiv.vx min_neg1 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vdiv.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x11 "e32 vdiv.vx min_neg1 lane 1"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vremu.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0xffffffff80000000 "e32 vremu.vx min_neg1 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vremu.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e32 vremu.vx min_neg1 lane 1"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vrem.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x0 "e32 vrem.vx min_neg1 lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vrem.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x0 "e32 vrem.vx min_neg1 lane 1"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0db357  # vmv.v.i v6, -5
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x003f8f93  # addi t6, t6, 3
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x02200313  # addi t1, zero, 34
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xffe30313  # addi t1, t1, -2
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x05500313  # addi t1, zero, 85
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x04400313  # addi t1, zero, 68
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5c620457  # vmerge.vvm v8, v6, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmerge.vvm lane 0 writes a0"
.assert rd_wdata == 0x11 "e32 vmerge.vvm lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmerge.vvm lane 1 writes a0"
.assert rd_wdata == 0x55 "e32 vmerge.vvm lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmerge.vvm lane 2 writes a0"
.assert rd_wdata == 0xffffffff80000003 "e32 vmerge.vvm lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmerge.vvm lane 3 writes a0"
.assert rd_wdata == 0x77 "e32 vmerge.vvm lane 3"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x00006fb7  # lui t6, 0x6
.4byte 0xa66f8f93  # addi t6, t6, -1434
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5c62c457  # vmerge.vxm v8, v6, t0, v0
.assert trap == 0 "vmerge.vxm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmerge.vxm lane 0 writes a0"
.assert rd_wdata == 0x11 "e32 vmerge.vxm lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmerge.vxm lane 1 writes a0"
.assert rd_wdata == 0x5a66 "e32 vmerge.vxm lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmerge.vxm lane 2 writes a0"
.assert rd_wdata == 0xffffffff80000003 "e32 vmerge.vxm lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmerge.vxm lane 3 writes a0"
.assert rd_wdata == 0x5a66 "e32 vmerge.vxm lane 3"
# --- SEW=64 (m2) ---
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e02b357  # vmv.v.i v6, 5
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xffd00293  # addi t0, zero, -3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x0e62c457  # vrsub.vx v8, v6, t0
.assert trap == 0 "vrsub.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vrsub.vx lane 0 writes a0"
.assert rd_wdata == 0x7ffffffffffffffd "e64 vrsub.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vrsub.vx lane 1 writes a0"
.assert rd_wdata == 0x7ffffffffffffffe "e64 vrsub.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vrsub.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "e64 vrsub.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vrsub.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e64 vrsub.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x2662c457  # vand.vx v8, v6, t0
.assert trap == 0 "vand.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vand.vx lane 0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vand.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vand.vx lane 1 writes a0"
.assert rd_wdata == 0x7ffffffffffffffd "e64 vand.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vand.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e64 vand.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vand.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vand.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x1262c457  # vminu.vx v8, v6, t0
.assert trap == 0 "vminu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vminu.vx lane 0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vminu.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vminu.vx lane 1 writes a0"
.assert rd_wdata == 0x7fffffffffffffff "e64 vminu.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vminu.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e64 vminu.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vminu.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vminu.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x1662c457  # vmin.vx v8, v6, t0
.assert trap == 0 "vmin.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmin.vx lane 0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vmin.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmin.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vmin.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmin.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vmin.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmin.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vmin.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x1a62c457  # vmaxu.vx v8, v6, t0
.assert trap == 0 "vmaxu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmaxu.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vmaxu.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmaxu.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vmaxu.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmaxu.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vmaxu.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmaxu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vmaxu.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x1e62c457  # vmax.vx v8, v6, t0
.assert trap == 0 "vmax.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmax.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vmax.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmax.vx lane 1 writes a0"
.assert rd_wdata == 0x7fffffffffffffff "e64 vmax.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmax.vx lane 2 writes a0"
.assert rd_wdata == 0x5 "e64 vmax.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmax.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vmax.vx lane 3"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0xfef00313  # addi t1, zero, -17
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xffc00f93  # addi t6, zero, -4
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02536313  # ori t1, t1, 0x25
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x04300293  # addi t0, zero, 67
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x9662c457  # vsll.vx v8, v6, t0
.assert trap == 0 "vsll.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vsll.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0x128 "e64 vsll.vx sh3 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsll.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "e64 vsll.vx sh3 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsll.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff78 "e64 vsll.vx sh3 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0xa262c457  # vsrl.vx v8, v6, t0
.assert trap == 0 "vsrl.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vsrl.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0x1000000000000004 "e64 vsrl.vx sh3 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsrl.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff "e64 vsrl.vx sh3 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsrl.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0x1ffffffffffffffd "e64 vsrl.vx sh3 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0xa662c457  # vsra.vx v8, v6, t0
.assert trap == 0 "vsra.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vsra.vx sh3 lane 0 writes a0"
.assert rd_wdata == 0xf000000000000004 "e64 vsra.vx sh3 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsra.vx sh3 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff "e64 vsra.vx sh3 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsra.vx sh3 lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vsra.vx sh3 lane 2"
.4byte 0x0ff00293  # addi t0, zero, 255
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x9662c457  # vsll.vx v8, v6, t0
.assert trap == 0 "vsll.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vsll.vx shmax lane 0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vsll.vx shmax lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsll.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e64 vsll.vx shmax lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsll.vx shmax lane 2 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vsll.vx shmax lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0xa262c457  # vsrl.vx v8, v6, t0
.assert trap == 0 "vsrl.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vsrl.vx shmax lane 0 writes a0"
.assert rd_wdata == 0x1 "e64 vsrl.vx shmax lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsrl.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e64 vsrl.vx shmax lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsrl.vx shmax lane 2 writes a0"
.assert rd_wdata == 0x1 "e64 vsrl.vx shmax lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0xa662c457  # vsra.vx v8, v6, t0
.assert trap == 0 "vsra.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vsra.vx shmax lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vsra.vx shmax lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsra.vx shmax lane 1 writes a0"
.assert rd_wdata == 0x0 "e64 vsra.vx shmax lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vsra.vx shmax lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vsra.vx shmax lane 2"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0fb357  # vmv.v.i v6, -1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x5e06b357  # vmv.v.i v6, 13
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0db357  # vmv.v.i v6, -5
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x0072e293  # ori t0, t0, 0x7
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x9262e457  # vmulhu.vx v8, v6, t0
.assert trap == 0 "vmulhu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmulhu.vx lane 0 writes a0"
.assert rd_wdata == 0x4000000000000003 "e64 vmulhu.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmulhu.vx lane 1 writes a0"
.assert rd_wdata == 0x8000000000000004 "e64 vmulhu.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmulhu.vx lane 2 writes a0"
.assert rd_wdata == 0x6 "e64 vmulhu.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmulhu.vx lane 3 writes a0"
.assert rd_wdata == 0x8000000000000006 "e64 vmulhu.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x9e62e457  # vmulh.vx v8, v6, t0
.assert trap == 0 "vmulh.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmulh.vx lane 0 writes a0"
.assert rd_wdata == 0x3ffffffffffffffc "e64 vmulh.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmulh.vx lane 1 writes a0"
.assert rd_wdata == 0x2 "e64 vmulh.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmulh.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff9 "e64 vmulh.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmulh.vx lane 3 writes a0"
.assert rd_wdata == 0x0 "e64 vmulh.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x9a62e457  # vmulhsu.vx v8, v6, t0
.assert trap == 0 "vmulhsu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmulhsu.vx lane 0 writes a0"
.assert rd_wdata == 0xbffffffffffffffc "e64 vmulhsu.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmulhsu.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vmulhsu.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmulhsu.vx lane 2 writes a0"
.assert rd_wdata == 0x6 "e64 vmulhsu.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmulhsu.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vmulhsu.vx lane 3"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x01d00313  # addi t1, zero, 29
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0xfef00313  # addi t1, zero, -17
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vdivu.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0x1999999999999999 "e64 vdivu.vx pos5 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdivu.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0x333333333333332f "e64 vdivu.vx pos5 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdivu.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x5 "e64 vdivu.vx pos5 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vdiv.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0xe666666666666667 "e64 vdiv.vx pos5 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdiv.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vdiv.vx pos5 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdiv.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x5 "e64 vdiv.vx pos5 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vremu.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0x3 "e64 vremu.vx pos5 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vremu.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0x4 "e64 vremu.vx pos5 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vremu.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x4 "e64 vremu.vx pos5 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vrem.vx pos5 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vrem.vx pos5 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vrem.vx pos5 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e64 vrem.vx pos5 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vrem.vx pos5 lane 2 writes a0"
.assert rd_wdata == 0x4 "e64 vrem.vx pos5 lane 2"
.4byte 0xffd00293  # addi t0, zero, -3
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vdivu.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0x0 "e64 vdivu.vx neg3 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdivu.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0x0 "e64 vdivu.vx neg3 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdivu.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x0 "e64 vdivu.vx neg3 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vdiv.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0x2aaaaaaaaaaaaaaa "e64 vdiv.vx neg3 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdiv.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0x5 "e64 vdiv.vx neg3 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdiv.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "e64 vdiv.vx neg3 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vremu.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vremu.vx neg3 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vremu.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e64 vremu.vx neg3 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vremu.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x1d "e64 vremu.vx neg3 lane 2"
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vrem.vx neg3 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e64 vrem.vx neg3 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vrem.vx neg3 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e64 vrem.vx neg3 lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vrem.vx neg3 lane 2 writes a0"
.assert rd_wdata == 0x2 "e64 vrem.vx neg3 lane 2"
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vdivu.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vdivu.vx div0 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdivu.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vdivu.vx div0 lane 1"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vdiv.vx div0 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vdiv.vx div0 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdiv.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vdiv.vx div0 lane 1"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vremu.vx div0 lane 0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vremu.vx div0 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vremu.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e64 vremu.vx div0 lane 1"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vrem.vx div0 lane 0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vrem.vx div0 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vrem.vx div0 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e64 vrem.vx div0 lane 1"
.4byte 0xfff00293  # addi t0, zero, -1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x8262e457  # vdivu.vx v8, v6, t0
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vdivu.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x0 "e64 vdivu.vx min_neg1 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdivu.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x0 "e64 vdivu.vx min_neg1 lane 1"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vdiv.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vdiv.vx min_neg1 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vdiv.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x11 "e64 vdiv.vx min_neg1 lane 1"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x8a62e457  # vremu.vx v8, v6, t0
.assert trap == 0 "vremu.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vremu.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x8000000000000000 "e64 vremu.vx min_neg1 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vremu.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffef "e64 vremu.vx min_neg1 lane 1"
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x8e62e457  # vrem.vx v8, v6, t0
.assert trap == 0 "vrem.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vrem.vx min_neg1 lane 0 writes a0"
.assert rd_wdata == 0x0 "e64 vrem.vx min_neg1 lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vrem.vx min_neg1 lane 1 writes a0"
.assert rd_wdata == 0x0 "e64 vrem.vx min_neg1 lane 1"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e0db357  # vmv.v.i v6, -5
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00336313  # ori t1, t1, 0x3
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x02200313  # addi t1, zero, 34
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x01100313  # addi t1, zero, 17
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xffe00f93  # addi t6, zero, -2
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x05500313  # addi t1, zero, 85
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x04400313  # addi t1, zero, 68
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053057  # vmv.v.i v0, 10
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5c620457  # vmerge.vvm v8, v6, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmerge.vvm lane 0 writes a0"
.assert rd_wdata == 0x11 "e64 vmerge.vvm lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmerge.vvm lane 1 writes a0"
.assert rd_wdata == 0x55 "e64 vmerge.vvm lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmerge.vvm lane 2 writes a0"
.assert rd_wdata == 0x8000000000000003 "e64 vmerge.vvm lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmerge.vvm lane 3 writes a0"
.assert rd_wdata == 0x77 "e64 vmerge.vvm lane 3"
.4byte 0x000062b7  # lui t0, 0x6
.4byte 0xa6628293  # addi t0, t0, -1434
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5c62c457  # vmerge.vxm v8, v6, t0, v0
.assert trap == 0 "vmerge.vxm retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmerge.vxm lane 0 writes a0"
.assert rd_wdata == 0x11 "e64 vmerge.vxm lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmerge.vxm lane 1 writes a0"
.assert rd_wdata == 0x5a66 "e64 vmerge.vxm lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmerge.vxm lane 2 writes a0"
.assert rd_wdata == 0x8000000000000003 "e64 vmerge.vxm lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmerge.vxm lane 3 writes a0"
.assert rd_wdata == 0x5a66 "e64 vmerge.vxm lane 3"

# Section 3: Masking (tu,mu), ta,ma m2 reg-boundary, vl==0, portable VLMAX mf8..m8.
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x09900313  # addi t1, zero, 153
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x23430313  # addi t1, t1, 564
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e083357  # vmv.v.i v6, -16
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x01500313  # addi t1, zero, 21
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xbeef0fb7  # lui t6, 0xbeef0
.4byte 0x003f8f93  # addi t6, t6, 3
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x0c62c457  # vrsub.vx v8, v6, t0, v0.t
.assert trap == 0 "vrsub.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vrsub.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8003 "masked vrsub.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vrsub.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vrsub.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vrsub.vx lane 2 writes a0"
.assert rd_wdata == 0x13 "masked vrsub.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vrsub.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vrsub.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x2462c457  # vand.vx v8, v6, t0, v0.t
.assert trap == 0 "vand.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vand.vx lane 0 writes a0"
.assert rd_wdata == 0x0 "masked vand.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vand.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vand.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vand.vx lane 2 writes a0"
.assert rd_wdata == 0x0 "masked vand.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vand.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vand.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x9462c457  # vsll.vx v8, v6, t0, v0.t
.assert trap == 0 "vsll.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vsll.vx lane 0 writes a0"
.assert rd_wdata == 0x0 "masked vsll.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vsll.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vsll.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vsll.vx lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff80 "masked vsll.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vsll.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vsll.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0xa062c457  # vsrl.vx v8, v6, t0, v0.t
.assert trap == 0 "vsrl.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vsrl.vx lane 0 writes a0"
.assert rd_wdata == 0x1000 "masked vsrl.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vsrl.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vsrl.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vsrl.vx lane 2 writes a0"
.assert rd_wdata == 0x1ffe "masked vsrl.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vsrl.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vsrl.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0xa462c457  # vsra.vx v8, v6, t0, v0.t
.assert trap == 0 "vsra.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vsra.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffff000 "masked vsra.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vsra.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vsra.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vsra.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "masked vsra.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vsra.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vsra.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x1062c457  # vminu.vx v8, v6, t0, v0.t
.assert trap == 0 "vminu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vminu.vx lane 0 writes a0"
.assert rd_wdata == 0x3 "masked vminu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vminu.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vminu.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vminu.vx lane 2 writes a0"
.assert rd_wdata == 0x3 "masked vminu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vminu.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vminu.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x1462c457  # vmin.vx v8, v6, t0, v0.t
.assert trap == 0 "vmin.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmin.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "masked vmin.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmin.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vmin.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmin.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff0 "masked vmin.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmin.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vmin.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x1862c457  # vmaxu.vx v8, v6, t0, v0.t
.assert trap == 0 "vmaxu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmaxu.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffff8000 "masked vmaxu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmaxu.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vmaxu.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmaxu.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff0 "masked vmaxu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmaxu.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vmaxu.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x1c62c457  # vmax.vx v8, v6, t0, v0.t
.assert trap == 0 "vmax.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmax.vx lane 0 writes a0"
.assert rd_wdata == 0x3 "masked vmax.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmax.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vmax.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmax.vx lane 2 writes a0"
.assert rd_wdata == 0x3 "masked vmax.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmax.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vmax.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x9062e457  # vmulhu.vx v8, v6, t0, v0.t
.assert trap == 0 "vmulhu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmulhu.vx lane 0 writes a0"
.assert rd_wdata == 0x1 "masked vmulhu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmulhu.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vmulhu.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmulhu.vx lane 2 writes a0"
.assert rd_wdata == 0x2 "masked vmulhu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmulhu.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vmulhu.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x9c62e457  # vmulh.vx v8, v6, t0, v0.t
.assert trap == 0 "vmulh.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmulh.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "masked vmulh.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmulh.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vmulh.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmulh.vx lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffffff "masked vmulh.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmulh.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vmulh.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x9862e457  # vmulhsu.vx v8, v6, t0, v0.t
.assert trap == 0 "vmulhsu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmulhsu.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "masked vmulhsu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmulhsu.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vmulhsu.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmulhsu.vx lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffffff "masked vmulhsu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmulhsu.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vmulhsu.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x8062e457  # vdivu.vx v8, v6, t0, v0.t
.assert trap == 0 "vdivu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vdivu.vx lane 0 writes a0"
.assert rd_wdata == 0x2aaa "masked vdivu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vdivu.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vdivu.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vdivu.vx lane 2 writes a0"
.assert rd_wdata == 0x5550 "masked vdivu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vdivu.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vdivu.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x8462e457  # vdiv.vx v8, v6, t0, v0.t
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vdiv.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffd556 "masked vdiv.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vdiv.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vdiv.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vdiv.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffb "masked vdiv.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vdiv.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vdiv.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x8862e457  # vremu.vx v8, v6, t0, v0.t
.assert trap == 0 "vremu.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vremu.vx lane 0 writes a0"
.assert rd_wdata == 0x2 "masked vremu.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vremu.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vremu.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vremu.vx lane 2 writes a0"
.assert rd_wdata == 0x0 "masked vremu.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vremu.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vremu.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
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
.4byte 0x8c62e457  # vrem.vx v8, v6, t0, v0.t
.assert trap == 0 "vrem.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vrem.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "masked vrem.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vrem.vx lane 1 mu writes a0"
.assert rd_wdata == 0x2222 "masked vrem.vx lane 1 mu"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vrem.vx lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffffff "masked vrem.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vrem.vx lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "masked vrem.vx lane 4 tu"
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x0000b337  # lui t1, 0xb
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5c620457  # vmerge.vvm v8, v6, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmerge.vvm v0=0 lane 0 takes vs2 writes a0"
.assert rd_wdata == 0xffffffffffffb001 "vmerge.vvm v0=0 lane 0 takes vs2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vmerge.vvm v0=0 lane 3 takes vs2 writes a0"
.assert rd_wdata == 0xffffffffffffb004 "vmerge.vvm v0=0 lane 3 takes vs2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vmerge.vvm v0=0 lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "vmerge.vvm v0=0 lane 4 tu"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e07b057  # vmv.v.i v0, 15
.4byte 0x000072b7  # lui t0, 0x7
.4byte 0x77728293  # addi t0, t0, 1911
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x00005337  # lui t1, 0x5
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x0000c337  # lui t1, 0xc
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5c62c457  # vmerge.vxm v8, v6, t0, v0
.assert trap == 0 "vmerge.vxm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmerge.vxm v0=all1 lane 0 takes rs1 writes a0"
.assert rd_wdata == 0x7777 "vmerge.vxm v0=all1 lane 0 takes rs1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vmerge.vxm v0=all1 lane 3 takes rs1 writes a0"
.assert rd_wdata == 0x7777 "vmerge.vxm v0=all1 lane 3 takes rs1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vmerge.vxm v0=all1 lane 4 tu writes a0"
.assert rd_wdata == 0x5555 "vmerge.vxm v0=all1 lane 4 tu"
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x03c00313  # addi t1, zero, 60
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x03200313  # addi t1, zero, 50
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x02800313  # addi t1, zero, 40
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x01e00313  # addi t1, zero, 30
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e053357  # vmv.v.i v6, 10
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x25800313  # addi t1, zero, 600
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x1f400313  # addi t1, zero, 500
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x19000313  # addi t1, zero, 400
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x12c00313  # addi t1, zero, 300
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x0c800313  # addi t1, zero, 200
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x06400313  # addi t1, zero, 100
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x02d00313  # addi t1, zero, 45
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0x06400293  # addi t0, zero, 100
.4byte 0xcd137657  # vsetivli a2, 6, e32, m2, ta, ma
.4byte 0x0c62c457  # vrsub.vx v8, v6, t0, v0.t
.assert trap == 0 "vrsub.vx retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "m2 ta,ma masked vrsub.vx lane 0 writes a0"
.assert rd_wdata == 0x5a "m2 ta,ma masked vrsub.vx lane 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "m2 ta,ma masked vrsub.vx lane 5 (reg+1) writes a0"
.assert rd_wdata == 0x28 "m2 ta,ma masked vrsub.vx lane 5 (reg+1)"
.4byte 0xcd137657  # vsetivli a2, 6, e32, m2, ta, ma
.4byte 0x5c620457  # vmerge.vvm v8, v6, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "m2 ta,ma vmerge.vvm lane 4 (reg+1, v0=0) writes a0"
.assert rd_wdata == 0x32 "m2 ta,ma vmerge.vvm lane 4 (reg+1, v0=0)"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "m2 ta,ma vmerge.vvm lane 5 (reg+1, v0=1) writes a0"
.assert rd_wdata == 0x258 "m2 ta,ma vmerge.vvm lane 5 (reg+1, v0=1)"
.4byte 0xcd137657  # vsetivli a2, 6, e32, m2, ta, ma
.4byte 0x5c62c457  # vmerge.vxm v8, v6, t0, v0
.assert trap == 0 "vmerge.vxm retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "m2 ta,ma vmerge.vxm lane 4 (reg+1, v0=0) writes a0"
.assert rd_wdata == 0x32 "m2 ta,ma vmerge.vxm lane 4 (reg+1, v0=0)"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "m2 ta,ma vmerge.vxm lane 5 (reg+1, v0=1) writes a0"
.assert rd_wdata == 0x64 "m2 ta,ma vmerge.vxm lane 5 (reg+1, v0=1)"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00009337  # lui t1, 0x9
.4byte 0x88830313  # addi t1, t1, -1912
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x00007337  # lui t1, 0x7
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0807657  # vsetivli a2, 0, e16, m1, tu, mu
.assert rd_addr == 12 "vl=0 int-vx-merge writes a2"
.assert rd_wdata == 0x0 "vl=0 int-vx-merge"
.4byte 0x0e62c457  # vrsub.vx v8, v6, t0
.assert trap == 0 "vrsub.vx retires"
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0x5c620457  # vmerge.vvm v8, v6, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0x5c62c457  # vmerge.vxm v8, v6, t0, v0
.assert trap == 0 "vmerge.vxm retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl=0 leaves vd[0] untouched writes a0"
.assert rd_wdata == 0x7777 "vl=0 leaves vd[0] untouched"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vl=0 leaves vd[1] untouched writes a0"
.assert rd_wdata == 0xffffffffffff8888 "vl=0 leaves vd[1] untouched"
# Portable VLMAX across mf8, mf4, mf2, m1, m4, m8.
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0x00507657  # vsetvli a2, zero, e8, mf8, tu, mu
.4byte 0x5e03b457  # vmv.v.i v8, 7
.4byte 0x5e0bb857  # vmv.v.i v16, -9
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x00507657  # vsetvli a2, zero, e8, mf8, tu, mu
.4byte 0x0f02cc57  # vrsub.vx v24, v16, t0
.assert trap == 0 "vrsub.vx retires"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX vrsub e8 mf8 lane 0 writes a0"
.assert rd_wdata == 0xb "VLMAX vrsub e8 mf8 lane 0"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x3f80b457  # vslidedown.vi v8, v24, 1
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX vrsub e8 mf8 lane 1 writes a0"
.assert rd_wdata == 0xb "VLMAX vrsub e8 mf8 lane 1"
.4byte 0x00e07657  # vsetvli a2, zero, e16, mf4, tu, mu
.4byte 0x5e03b457  # vmv.v.i v8, 7
.4byte 0x5e0bb857  # vmv.v.i v16, -9
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x00e07657  # vsetvli a2, zero, e16, mf4, tu, mu
.4byte 0xa702cc57  # vsra.vx v24, v16, t0
.assert trap == 0 "vsra.vx retires"
.4byte 0xc0e0f657  # vsetivli a2, 1, e16, mf4, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX vsra e16 mf4 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "VLMAX vsra e16 mf4 lane 0"
.4byte 0xc0e0f657  # vsetivli a2, 1, e16, mf4, tu, mu
.4byte 0x3f80b457  # vslidedown.vi v8, v24, 1
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX vsra e16 mf4 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "VLMAX vsra e16 mf4 lane 1"
.4byte 0x01707657  # vsetvli a2, zero, e32, mf2, tu, mu
.4byte 0x5e03b457  # vmv.v.i v8, 7
.4byte 0x5e0bb857  # vmv.v.i v16, -9
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x01707657  # vsetvli a2, zero, e32, mf2, tu, mu
.4byte 0x9f02ec57  # vmulh.vx v24, v16, t0
.assert trap == 0 "vmulh.vx retires"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX vmulh e32 mf2 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffff "VLMAX vmulh e32 mf2 lane 0"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x3f80b457  # vslidedown.vi v8, v24, 1
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX vmulh e32 mf2 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "VLMAX vmulh e32 mf2 lane 1"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e03b457  # vmv.v.i v8, 7
.4byte 0x5e0bb857  # vmv.v.i v16, -9
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x8702ec57  # vdiv.vx v24, v16, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX vdiv e64 m1 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffc "VLMAX vdiv e64 m1 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3f80b457  # vslidedown.vi v8, v24, 1
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX vdiv e64 m1 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffffc "VLMAX vdiv e64 m1 lane 1"
.4byte 0x01207657  # vsetvli a2, zero, e32, m4, tu, mu
.4byte 0x5e03b457  # vmv.v.i v8, 7
.4byte 0x5e0bb857  # vmv.v.i v16, -9
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x01207657  # vsetvli a2, zero, e32, m4, tu, mu
.4byte 0x5d040c57  # vmerge.vvm v24, v16, v8, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc120f657  # vsetivli a2, 1, e32, m4, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX vmerge_vv e32 m4 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "VLMAX vmerge_vv e32 m4 lane 0"
.4byte 0xc120f657  # vsetivli a2, 1, e32, m4, tu, mu
.4byte 0x3f80b457  # vslidedown.vi v8, v24, 1
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX vmerge_vv e32 m4 lane 1 writes a0"
.assert rd_wdata == 0x7 "VLMAX vmerge_vv e32 m4 lane 1"
.4byte 0x01b07657  # vsetvli a2, zero, e64, m8, tu, mu
.4byte 0x5e03b457  # vmv.v.i v8, 7
.4byte 0x5e0bb857  # vmv.v.i v16, -9
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00200293  # addi t0, zero, 2
.4byte 0x01b07657  # vsetvli a2, zero, e64, m8, tu, mu
.4byte 0x5d02cc57  # vmerge.vxm v24, v16, t0, v0
.assert trap == 0 "vmerge.vxm retires"
.4byte 0xc1b0f657  # vsetivli a2, 1, e64, m8, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX vmerge_vx e64 m8 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff7 "VLMAX vmerge_vx e64 m8 lane 0"
.4byte 0xc1b0f657  # vsetivli a2, 1, e64, m8, tu, mu
.4byte 0x3f80b457  # vslidedown.vi v8, v24, 1
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX vmerge_vx e64 m8 lane 1 writes a0"
.assert rd_wdata == 0x2 "VLMAX vmerge_vx e64 m8 lane 1"

# Section 4: Legal overlaps (vd==vs2, unmasked v0, vmerge vd==vs2/vs1/vs1==vs2).
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053257  # vmv.v.i v4, 10
.4byte 0x02300293  # addi t0, zero, 35
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x0e42c257  # vrsub.vx v4, v4, t0
.assert trap == 0 "vrsub.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "overlap vd==vs2 vrsub.vx[0] writes a0"
.assert rd_wdata == 0x19 "overlap vd==vs2 vrsub.vx[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e40b857  # vslidedown.vi v16, v4, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "overlap vd==vs2 vrsub.vx[1] writes a0"
.assert rd_wdata == 0xf "overlap vd==vs2 vrsub.vx[1]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x0c800313  # addi t1, zero, 200
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x06400313  # addi t1, zero, 100
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0x00700293  # addi t0, zero, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x8602e057  # vdiv.vx v0, v0, t0
.assert trap == 0 "vdiv.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "unmasked legal vd==vs2==v0 vdiv.vx[0] writes a0"
.assert rd_wdata == 0xe "unmasked legal vd==vs2==v0 vdiv.vx[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e00b857  # vslidedown.vi v16, v0, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "unmasked legal vd==vs2==v0 vdiv.vx[1] writes a0"
.assert rd_wdata == 0x1c "unmasked legal vd==vs2==v0 vdiv.vx[1]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e013057  # vmv.v.i v0, 2
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x01600313  # addi t1, zero, 22
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x02c00313  # addi t1, zero, 44
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x02100313  # addi t1, zero, 33
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5c620357  # vmerge.vvm v6, v6, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42602557  # vmv.x.s a0, v6
.assert rd_addr == 10 "vmerge.vvm vd==vs2[0] writes a0"
.assert rd_wdata == 0x21 "vmerge.vvm vd==vs2[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e60b857  # vslidedown.vi v16, v6, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vmerge.vvm vd==vs2[1] writes a0"
.assert rd_wdata == 0x16 "vmerge.vvm vd==vs2[1]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x01600313  # addi t1, zero, 22
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x02c00313  # addi t1, zero, 44
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x02100313  # addi t1, zero, 33
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5c620257  # vmerge.vvm v4, v6, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "vmerge.vvm vd==vs1[0] writes a0"
.assert rd_wdata == 0x21 "vmerge.vvm vd==vs1[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e40b857  # vslidedown.vi v16, v4, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vmerge.vvm vd==vs1[1] writes a0"
.assert rd_wdata == 0x16 "vmerge.vvm vd==vs1[1]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x03700313  # addi t1, zero, 55
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5c420457  # vmerge.vvm v8, v4, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmerge.vvm vs1==vs2[0] writes a0"
.assert rd_wdata == 0x37 "vmerge.vvm vs1==vs2[0]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5c420257  # vmerge.vvm v4, v4, v4, v0
.assert trap == 0 "vmerge.vvm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e40b857  # vslidedown.vi v16, v4, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vmerge.vvm vd==vs1==vs2[1] writes a0"
.assert rd_wdata == 0x42 "vmerge.vvm vd==vs1==vs2[1]"
.4byte 0x06300293  # addi t0, zero, 99
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5c42c257  # vmerge.vxm v4, v4, t0, v0
.assert trap == 0 "vmerge.vxm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "vmerge.vxm vd==vs2[0] writes a0"
.assert rd_wdata == 0x37 "vmerge.vxm vd==vs2[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e40b857  # vslidedown.vi v16, v4, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "vmerge.vxm vd==vs2[1] writes a0"
.assert rd_wdata == 0x63 "vmerge.vxm vd==vs2[1]"

# Section 5: Illegal-instruction traps (mcause == 2, mtval == insn, destinations untouched).
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x04200313  # addi t1, zero, 66
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x03300313  # addi t1, zero, 51
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x0c62c057  # vrsub.vx v0, v6, t0, v0.t
.assert trap == 1 "vrsub.vx masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrsub.vx masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vrsub.vx masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrsub.vx masked vd==v0 mtval writes a0"
.assert rd_wdata == 0xc62c057 "vrsub.vx masked vd==v0 mtval matches instruction"
.4byte 0x9462c057  # vsll.vx v0, v6, t0, v0.t
.assert trap == 1 "vsll.vx masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vsll.vx masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vsll.vx masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vsll.vx masked vd==v0 mtval writes a0"
.assert rd_wdata == 0x9462c057 "vsll.vx masked vd==v0 mtval matches instruction"
.4byte 0x9c62e057  # vmulh.vx v0, v6, t0, v0.t
.assert trap == 1 "vmulh.vx masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmulh.vx masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmulh.vx masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmulh.vx masked vd==v0 mtval writes a0"
.assert rd_wdata == 0x9c62e057 "vmulh.vx masked vd==v0 mtval matches instruction"
.4byte 0x8462e057  # vdiv.vx v0, v6, t0, v0.t
.assert trap == 1 "vdiv.vx masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vdiv.vx masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vdiv.vx masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vdiv.vx masked vd==v0 mtval writes a0"
.assert rd_wdata == 0x8462e057 "vdiv.vx masked vd==v0 mtval matches instruction"
.4byte 0x2402c457  # vand.vx v8, v0, t0, v0.t
.assert trap == 1 "vand.vx masked vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vand.vx masked vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vand.vx masked vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vand.vx masked vs2==v0 mtval writes a0"
.assert rd_wdata == 0x2402c457 "vand.vx masked vs2==v0 mtval matches instruction"
.4byte 0x1402c457  # vmin.vx v8, v0, t0, v0.t
.assert trap == 1 "vmin.vx masked vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmin.vx masked vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmin.vx masked vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmin.vx masked vs2==v0 mtval writes a0"
.assert rd_wdata == 0x1402c457 "vmin.vx masked vs2==v0 mtval matches instruction"
.4byte 0x9802e457  # vmulhsu.vx v8, v0, t0, v0.t
.assert trap == 1 "vmulhsu.vx masked vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmulhsu.vx masked vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmulhsu.vx masked vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmulhsu.vx masked vs2==v0 mtval writes a0"
.assert rd_wdata == 0x9802e457 "vmulhsu.vx masked vs2==v0 mtval matches instruction"
.4byte 0x8c02e457  # vrem.vx v8, v0, t0, v0.t
.assert trap == 1 "vrem.vx masked vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrem.vx masked vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vrem.vx masked vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrem.vx masked vs2==v0 mtval writes a0"
.assert rd_wdata == 0x8c02e457 "vrem.vx masked vs2==v0 mtval matches instruction"
.4byte 0x5c620057  # vmerge.vvm v0, v6, v4, v0
.assert trap == 1 "vmerge.vvm vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmerge.vvm vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmerge.vvm vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmerge.vvm vd==v0 mtval writes a0"
.assert rd_wdata == 0x5c620057 "vmerge.vvm vd==v0 mtval matches instruction"
.4byte 0x5c62c057  # vmerge.vxm v0, v6, t0, v0
.assert trap == 1 "vmerge.vxm vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmerge.vxm vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmerge.vxm vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmerge.vxm vd==v0 mtval writes a0"
.assert rd_wdata == 0x5c62c057 "vmerge.vxm vd==v0 mtval matches instruction"
.4byte 0x5c020457  # vmerge.vvm v8, v0, v4, v0
.assert trap == 1 "vmerge.vvm vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmerge.vvm vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmerge.vvm vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmerge.vvm vs2==v0 mtval writes a0"
.assert rd_wdata == 0x5c020457 "vmerge.vvm vs2==v0 mtval matches instruction"
.4byte 0x5c600457  # vmerge.vvm v8, v6, v0, v0
.assert trap == 1 "vmerge.vvm vs1==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmerge.vvm vs1==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmerge.vvm vs1==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmerge.vvm vs1==v0 mtval writes a0"
.assert rd_wdata == 0x5c600457 "vmerge.vvm vs1==v0 mtval matches instruction"
.4byte 0x5c02c457  # vmerge.vxm v8, v0, t0, v0
.assert trap == 1 "vmerge.vxm vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmerge.vxm vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmerge.vxm vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmerge.vxm vs2==v0 mtval writes a0"
.assert rd_wdata == 0x5c02c457 "vmerge.vxm vs2==v0 mtval matches instruction"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "v8 sentinel untouched after v0-overlap traps writes a0"
.assert rd_wdata == 0x42 "v8 sentinel untouched after v0-overlap traps"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "v0 sentinel untouched after v0-overlap traps writes a0"
.assert rd_wdata == 0x33 "v0 sentinel untouched after v0-overlap traps"
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x0e62c4d7  # vrsub.vx v9, v6, t0
.assert trap == 1 "vrsub.vx m2 misaligned vd traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrsub.vx m2 misaligned vd mcause writes a0"
.assert rd_wdata == 0x2 "vrsub.vx m2 misaligned vd illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrsub.vx m2 misaligned vd mtval writes a0"
.assert rd_wdata == 0xe62c4d7 "vrsub.vx m2 misaligned vd mtval matches instruction"
.4byte 0x8672e457  # vdiv.vx v8, v7, t0
.assert trap == 1 "vdiv.vx m2 misaligned vs2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vdiv.vx m2 misaligned vs2 mcause writes a0"
.assert rd_wdata == 0x2 "vdiv.vx m2 misaligned vs2 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vdiv.vx m2 misaligned vs2 mtval writes a0"
.assert rd_wdata == 0x8672e457 "vdiv.vx m2 misaligned vs2 mtval matches instruction"
.4byte 0x5c628457  # vmerge.vvm v8, v6, v5, v0
.assert trap == 1 "vmerge.vvm m2 misaligned vs1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmerge.vvm m2 misaligned vs1 mcause writes a0"
.assert rd_wdata == 0x2 "vmerge.vvm m2 misaligned vs1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmerge.vvm m2 misaligned vs1 mtval writes a0"
.assert rd_wdata == 0x5c628457 "vmerge.vvm m2 misaligned vs1 mtval matches instruction"
.4byte 0xc1227657  # vsetivli a2, 4, e32, m4, tu, mu
.4byte 0x9282e557  # vmulhu.vx v10, v8, t0
.assert trap == 1 "vmulhu.vx m4 misaligned vd traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmulhu.vx m4 misaligned vd mcause writes a0"
.assert rd_wdata == 0x2 "vmulhu.vx m4 misaligned vd illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmulhu.vx m4 misaligned vd mtval writes a0"
.assert rd_wdata == 0x9282e557 "vmulhu.vx m4 misaligned vd mtval matches instruction"
.4byte 0xc200f657  # vsetivli a2, 1, 0x20 (sets vill=1)
.assert rd_addr == 12 "vill vsetivli writes a2"
.assert rd_wdata == 0x0 "vill vsetivli sets vl=0"
.4byte 0x0e62c457  # vrsub.vx v8, v6, t0
.assert trap == 1 "vrsub.vx under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vrsub.vx under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vrsub.vx under vill=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vrsub.vx under vill=1 mtval writes a0"
.assert rd_wdata == 0xe62c457 "vrsub.vx under vill=1 mtval matches instruction"
.4byte 0x8662e457  # vdiv.vx v8, v6, t0
.assert trap == 1 "vdiv.vx under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vdiv.vx under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vdiv.vx under vill=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vdiv.vx under vill=1 mtval writes a0"
.assert rd_wdata == 0x8662e457 "vdiv.vx under vill=1 mtval matches instruction"
.4byte 0x5c620457  # vmerge.vvm v8, v6, v4, v0
.assert trap == 1 "vmerge.vvm under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmerge.vvm under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vmerge.vvm under vill=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmerge.vvm under vill=1 mtval writes a0"
.assert rd_wdata == 0x5c620457 "vmerge.vvm under vill=1 mtval matches instruction"
