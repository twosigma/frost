# Directed TestRIG trace for all 8 base-V integer multiply-add encodings:
# vmacc.{vv,vx}, vnmsac.{vv,vx}, vmadd.{vv,vx}, vnmsub.{vv,vx}.
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

# Section 1: Control readout (vmv.x.s a0, v23 = 0x43702557).
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e0fbbd7  # vmv.v.i v23, -1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034bd7  # vmv.v.x v23, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e01bbd7  # vmv.v.i v23, 3
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x10000337  # lui t1, 0x10000
.4byte 0x5e034bd7  # vmv.v.x v23, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e013257  # vmv.v.i v4, 2
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x00001337  # lui t1, 0x1
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x001f8f93  # addi t6, t6, 1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e013357  # vmv.v.i v6, 2
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e03b357  # vmv.v.i v6, 7
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xb6622bd7  # vmacc.vv v23, v4, v6
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x43702557  # vmv.x.s a0, v23
.assert rd_addr == 10 "ctrl vmacc.vv lane 0 writes a0"
.assert rd_wdata == 0x10010010 "ctrl vmacc.vv lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f70b857  # vslidedown.vi v16, v23, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "ctrl vmacc.vv lane 1 writes a0"
.assert rd_wdata == 0x26 "ctrl vmacc.vv lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f713857  # vslidedown.vi v16, v23, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "ctrl vmacc.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffff80000006 "ctrl vmacc.vv lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3f71b857  # vslidedown.vi v16, v23, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "ctrl vmacc.vv lane 3 wraparound writes a0"
.assert rd_wdata == 0x1 "ctrl vmacc.vv lane 3 wraparound"

# Section 2: All 8 encodings at SEW 8/16/32/64 (vd-as-accumulator vs vd-as-multiplicand & wraparound).
# --- SEW=8 (m1): .vv and .vx forms ---
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x07f00313  # addi t1, zero, 127
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0f3257  # vmv.v.i v4, -2
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x07f00313  # addi t1, zero, 127
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08300313  # addi t1, zero, 131
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0eb357  # vmv.v.i v6, -3
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e03b357  # vmv.v.i v6, 7
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08500313  # addi t1, zero, 133
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xb6622457  # vmacc.vv v8, v4, v6
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmacc.vv lane 0 writes a0"
.assert rd_wdata == 0x26 "e8 vmacc.vv lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmacc.vv lane 1 writes a0"
.assert rd_wdata == 0x0 "e8 vmacc.vv lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmacc.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff82 "e8 vmacc.vv lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmacc.vv lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vmacc.vv lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08500313  # addi t1, zero, 133
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xbe622457  # vnmsac.vv v8, v4, v6
.assert trap == 0 "vnmsac.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vnmsac.vv lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "e8 vnmsac.vv lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsac.vv lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "e8 vnmsac.vv lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsac.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff88 "e8 vnmsac.vv lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsac.vv lane 3 writes a0"
.assert rd_wdata == 0x3 "e8 vnmsac.vv lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08500313  # addi t1, zero, 133
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xa6622457  # vmadd.vv v8, v4, v6
.assert trap == 0 "vmadd.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmadd.vv lane 0 writes a0"
.assert rd_wdata == 0x16 "e8 vmadd.vv lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmadd.vv lane 1 writes a0"
.assert rd_wdata == 0x9 "e8 vmadd.vv lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmadd.vv lane 2 writes a0"
.assert rd_wdata == 0x7e "e8 vmadd.vv lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmadd.vv lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vmadd.vv lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08500313  # addi t1, zero, 133
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xae622457  # vnmsub.vv v8, v4, v6
.assert trap == 0 "vnmsub.vv retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vnmsub.vv lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "e8 vnmsub.vv lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsub.vv lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "e8 vnmsub.vv lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsub.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffffffffff88 "e8 vnmsub.vv lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsub.vv lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vnmsub.vv lane 3"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33440fb7  # lui t6, 0x33440
.4byte 0x0fdf8f93  # addi t6, t6, 253
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08500313  # addi t1, zero, 133
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xb662e457  # vmacc.vx v8, t0, v6
.assert trap == 0 "vmacc.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmacc.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffee "e8 vmacc.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmacc.vx lane 1 writes a0"
.assert rd_wdata == 0x3 "e8 vmacc.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmacc.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffc "e8 vmacc.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmacc.vx lane 3 writes a0"
.assert rd_wdata == 0x3 "e8 vmacc.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08500313  # addi t1, zero, 133
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xbe62e457  # vnmsac.vx v8, t0, v6
.assert trap == 0 "vnmsac.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vnmsac.vx lane 0 writes a0"
.assert rd_wdata == 0x18 "e8 vnmsac.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsac.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "e8 vnmsac.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsac.vx lane 2 writes a0"
.assert rd_wdata == 0xe "e8 vnmsac.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsac.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e8 vnmsac.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08500313  # addi t1, zero, 133
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xa662e457  # vmadd.vx v8, t0, v6
.assert trap == 0 "vmadd.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vmadd.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e8 vmadd.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmadd.vx lane 1 writes a0"
.assert rd_wdata == 0xf "e8 vmadd.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmadd.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "e8 vmadd.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vmadd.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vmadd.vx lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x08000313  # addi t1, zero, 128
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x08500313  # addi t1, zero, 133
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0xae62e457  # vnmsub.vx v8, t0, v6
.assert trap == 0 "vnmsub.vx retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vnmsub.vx lane 0 writes a0"
.assert rd_wdata == 0x10 "e8 vnmsub.vx lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsub.vx lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffeb "e8 vnmsub.vx lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsub.vx lane 2 writes a0"
.assert rd_wdata == 0x12 "e8 vnmsub.vx lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vnmsub.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e8 vnmsub.vx lane 3"
# --- SEW=16 (m1): .vv and .vx forms ---
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0f3257  # vmv.v.i v4, -2
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0eb357  # vmv.v.i v6, -3
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e03b357  # vmv.v.i v6, 7
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0xb6622457  # vmacc.vv v8, v4, v6
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmacc.vv lane 0 writes a0"
.assert rd_wdata == 0x26 "e16 vmacc.vv lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmacc.vv lane 1 writes a0"
.assert rd_wdata == 0x0 "e16 vmacc.vv lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmacc.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffffffff8002 "e16 vmacc.vv lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmacc.vv lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vmacc.vv lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0xbe622457  # vnmsac.vv v8, v4, v6
.assert trap == 0 "vnmsac.vv retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vnmsac.vv lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "e16 vnmsac.vv lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsac.vv lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "e16 vnmsac.vv lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsac.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffffffff8008 "e16 vnmsac.vv lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsac.vv lane 3 writes a0"
.assert rd_wdata == 0x3 "e16 vnmsac.vv lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0xa6622457  # vmadd.vv v8, v4, v6
.assert trap == 0 "vmadd.vv retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmadd.vv lane 0 writes a0"
.assert rd_wdata == 0x16 "e16 vmadd.vv lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmadd.vv lane 1 writes a0"
.assert rd_wdata == 0x9 "e16 vmadd.vv lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmadd.vv lane 2 writes a0"
.assert rd_wdata == 0x7ffe "e16 vmadd.vv lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmadd.vv lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vmadd.vv lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0xae622457  # vnmsub.vv v8, v4, v6
.assert trap == 0 "vnmsub.vv retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vnmsub.vv lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "e16 vnmsub.vv lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsub.vv lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "e16 vnmsub.vv lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsub.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffffffff8008 "e16 vnmsub.vv lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsub.vv lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vnmsub.vv lane 3"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x33450fb7  # lui t6, 0x33450
.4byte 0xffdf8f93  # addi t6, t6, -3
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0xb662e457  # vmacc.vx v8, t0, v6
.assert trap == 0 "vmacc.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmacc.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffee "e16 vmacc.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmacc.vx lane 1 writes a0"
.assert rd_wdata == 0x3 "e16 vmacc.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmacc.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffc "e16 vmacc.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmacc.vx lane 3 writes a0"
.assert rd_wdata == 0x3 "e16 vmacc.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0xbe62e457  # vnmsac.vx v8, t0, v6
.assert trap == 0 "vnmsac.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vnmsac.vx lane 0 writes a0"
.assert rd_wdata == 0x18 "e16 vnmsac.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsac.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "e16 vnmsac.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsac.vx lane 2 writes a0"
.assert rd_wdata == 0xe "e16 vnmsac.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsac.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e16 vnmsac.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0xa662e457  # vmadd.vx v8, t0, v6
.assert trap == 0 "vmadd.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vmadd.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e16 vmadd.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmadd.vx lane 1 writes a0"
.assert rd_wdata == 0xf "e16 vmadd.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmadd.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "e16 vmadd.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vmadd.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vmadd.vx lane 3"
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x00530313  # addi t1, t1, 5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0xae62e457  # vnmsub.vx v8, t0, v6
.assert trap == 0 "vnmsub.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vnmsub.vx lane 0 writes a0"
.assert rd_wdata == 0x10 "e16 vnmsub.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsub.vx lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffeb "e16 vnmsub.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsub.vx lane 2 writes a0"
.assert rd_wdata == 0x12 "e16 vnmsub.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vnmsub.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e16 vnmsub.vx lane 3"
# --- SEW=32 (m1): .vv and .vx forms ---
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0f3257  # vmv.v.i v4, -2
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x5e034357  # vmv.v.x v6, t1
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
.4byte 0x5e0eb357  # vmv.v.i v6, -3
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e03b357  # vmv.v.i v6, 7
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xb6622457  # vmacc.vv v8, v4, v6
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmacc.vv lane 0 writes a0"
.assert rd_wdata == 0x26 "e32 vmacc.vv lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmacc.vv lane 1 writes a0"
.assert rd_wdata == 0x0 "e32 vmacc.vv lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmacc.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffff80000002 "e32 vmacc.vv lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmacc.vv lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vmacc.vv lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xbe622457  # vnmsac.vv v8, v4, v6
.assert trap == 0 "vnmsac.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vnmsac.vv lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "e32 vnmsac.vv lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsac.vv lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "e32 vnmsac.vv lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsac.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffff80000008 "e32 vnmsac.vv lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsac.vv lane 3 writes a0"
.assert rd_wdata == 0x3 "e32 vnmsac.vv lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xa6622457  # vmadd.vv v8, v4, v6
.assert trap == 0 "vmadd.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmadd.vv lane 0 writes a0"
.assert rd_wdata == 0x16 "e32 vmadd.vv lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmadd.vv lane 1 writes a0"
.assert rd_wdata == 0x9 "e32 vmadd.vv lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmadd.vv lane 2 writes a0"
.assert rd_wdata == 0x7ffffffe "e32 vmadd.vv lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmadd.vv lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vmadd.vv lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xae622457  # vnmsub.vv v8, v4, v6
.assert trap == 0 "vnmsub.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vnmsub.vv lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "e32 vnmsub.vv lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsub.vv lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "e32 vnmsub.vv lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsub.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffff80000008 "e32 vnmsub.vv lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsub.vv lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vnmsub.vv lane 3"
.4byte 0x55aa12b7  # lui t0, 0x55aa1
.4byte 0x12228293  # addi t0, t0, 290
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xffd00f93  # addi t6, zero, -3
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f2e2b3  # or t0, t0, t6
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xb662e457  # vmacc.vx v8, t0, v6
.assert trap == 0 "vmacc.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmacc.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffee "e32 vmacc.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmacc.vx lane 1 writes a0"
.assert rd_wdata == 0x3 "e32 vmacc.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmacc.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffffc "e32 vmacc.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmacc.vx lane 3 writes a0"
.assert rd_wdata == 0x3 "e32 vmacc.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xbe62e457  # vnmsac.vx v8, t0, v6
.assert trap == 0 "vnmsac.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vnmsac.vx lane 0 writes a0"
.assert rd_wdata == 0x18 "e32 vnmsac.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsac.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "e32 vnmsac.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsac.vx lane 2 writes a0"
.assert rd_wdata == 0xe "e32 vnmsac.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsac.vx lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e32 vnmsac.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xa662e457  # vmadd.vx v8, t0, v6
.assert trap == 0 "vmadd.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vmadd.vx lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffffe "e32 vmadd.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmadd.vx lane 1 writes a0"
.assert rd_wdata == 0xf "e32 vmadd.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmadd.vx lane 2 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "e32 vmadd.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vmadd.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vmadd.vx lane 3"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x80000fb7  # lui t6, 0x80000
.4byte 0x005f8f93  # addi t6, t6, 5
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0xae62e457  # vnmsub.vx v8, t0, v6
.assert trap == 0 "vnmsub.vx retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vnmsub.vx lane 0 writes a0"
.assert rd_wdata == 0x10 "e32 vnmsub.vx lane 0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsub.vx lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffeb "e32 vnmsub.vx lane 1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsub.vx lane 2 writes a0"
.assert rd_wdata == 0x12 "e32 vnmsub.vx lane 2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vnmsub.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e32 vnmsub.vx lane 3"
# --- SEW=64 (m2): .vv and .vx forms ---
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
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
.4byte 0x5e0f3257  # vmv.v.i v4, -2
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xfff00f93  # addi t6, zero, -1
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00336313  # ori t1, t1, 0x3
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0eb357  # vmv.v.i v6, -3
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e03b357  # vmv.v.i v6, 7
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0xb6622457  # vmacc.vv v8, v4, v6
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmacc.vv lane 0 writes a0"
.assert rd_wdata == 0x26 "e64 vmacc.vv lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmacc.vv lane 1 writes a0"
.assert rd_wdata == 0x0 "e64 vmacc.vv lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmacc.vv lane 2 writes a0"
.assert rd_wdata == 0x8000000000000002 "e64 vmacc.vv lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmacc.vv lane 3 writes a0"
.assert rd_wdata == 0xfffffffffffffffd "e64 vmacc.vv lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0xbe622457  # vnmsac.vv v8, v4, v6
.assert trap == 0 "vnmsac.vv retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vnmsac.vv lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "e64 vnmsac.vv lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsac.vv lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff4 "e64 vnmsac.vv lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsac.vv lane 2 writes a0"
.assert rd_wdata == 0x8000000000000008 "e64 vnmsac.vv lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsac.vv lane 3 writes a0"
.assert rd_wdata == 0x3 "e64 vnmsac.vv lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0xa6622457  # vmadd.vv v8, v4, v6
.assert trap == 0 "vmadd.vv retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmadd.vv lane 0 writes a0"
.assert rd_wdata == 0x16 "e64 vmadd.vv lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmadd.vv lane 1 writes a0"
.assert rd_wdata == 0x9 "e64 vmadd.vv lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmadd.vv lane 2 writes a0"
.assert rd_wdata == 0x7ffffffffffffffe "e64 vmadd.vv lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmadd.vv lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vmadd.vv lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0xae622457  # vnmsub.vv v8, v4, v6
.assert trap == 0 "vnmsub.vv retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vnmsub.vv lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "e64 vnmsub.vv lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsub.vv lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff1 "e64 vnmsub.vv lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsub.vv lane 2 writes a0"
.assert rd_wdata == 0x8000000000000008 "e64 vnmsub.vv lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsub.vv lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vnmsub.vv lane 3"
.4byte 0x800002b7  # lui t0, 0x80000
.4byte 0x00128293  # addi t0, t0, 1
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0x0052e293  # ori t0, t0, 0x5
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0xb662e457  # vmacc.vx v8, t0, v6
.assert trap == 0 "vmacc.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmacc.vx lane 0 writes a0"
.assert rd_wdata == 0x8000000700000026 "e64 vmacc.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmacc.vx lane 1 writes a0"
.assert rd_wdata == 0x7ffffffcffffffeb "e64 vmacc.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmacc.vx lane 2 writes a0"
.assert rd_wdata == 0x8000000300000014 "e64 vmacc.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmacc.vx lane 3 writes a0"
.assert rd_wdata == 0x7ffffffefffffffb "e64 vmacc.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0xbe62e457  # vnmsac.vx v8, t0, v6
.assert trap == 0 "vnmsac.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vnmsac.vx lane 0 writes a0"
.assert rd_wdata == 0x7ffffff8ffffffe0 "e64 vnmsac.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsac.vx lane 1 writes a0"
.assert rd_wdata == 0x8000000300000009 "e64 vnmsac.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsac.vx lane 2 writes a0"
.assert rd_wdata == 0x7ffffffcfffffff6 "e64 vnmsac.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsac.vx lane 3 writes a0"
.assert rd_wdata == 0x8000000100000005 "e64 vnmsac.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0xa662e457  # vmadd.vx v8, t0, v6
.assert trap == 0 "vmadd.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vmadd.vx lane 0 writes a0"
.assert rd_wdata == 0x8000000300000016 "e64 vmadd.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmadd.vx lane 1 writes a0"
.assert rd_wdata == 0xfffffff9ffffffdf "e64 vmadd.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmadd.vx lane 2 writes a0"
.assert rd_wdata == 0x800000050000001c "e64 vmadd.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vmadd.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vmadd.vx lane 3"
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc191f657  # vsetivli a2, 3, e64, m2, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00536313  # ori t1, t1, 0x5
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1917657  # vsetivli a2, 2, e64, m2, tu, mu
.4byte 0x5e0d3457  # vmv.v.i v8, -6
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x5e01b457  # vmv.v.i v8, 3
.4byte 0xc1927657  # vsetivli a2, 4, e64, m2, tu, mu
.4byte 0xae62e457  # vnmsub.vx v8, t0, v6
.assert trap == 0 "vnmsub.vx retires"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vnmsub.vx lane 0 writes a0"
.assert rd_wdata == 0x7ffffffcfffffff8 "e64 vnmsub.vx lane 0"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsub.vx lane 1 writes a0"
.assert rd_wdata == 0x60000001b "e64 vnmsub.vx lane 1"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsub.vx lane 2 writes a0"
.assert rd_wdata == 0x7ffffffaffffffea "e64 vnmsub.vx lane 2"
.4byte 0xc190f657  # vsetivli a2, 1, e64, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vnmsub.vx lane 3 writes a0"
.assert rd_wdata == 0xffffffffffffffff "e64 vnmsub.vx lane 3"

# Section 3: Masking (v0.t, mu/ma), tails (tu/ta), vl==0, VLMAX, mf8..m8.
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x5e05b257  # vmv.v.i v4, 11
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x5e04b257  # vmv.v.i v4, 9
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc082f657  # vsetivli a2, 5, e16, m1, tu, mu
.4byte 0x50000313  # addi t1, zero, 1280
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x40000313  # addi t1, zero, 1024
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x30000313  # addi t1, zero, 768
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x20000313  # addi t1, zero, 512
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x10000313  # addi t1, zero, 256
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e02b057  # vmv.v.i v0, 5
.4byte 0x00000293  # addi t0, zero, 0
.4byte 0x02029293  # slli t0, t0, 32
.4byte 0xdead0fb7  # lui t6, 0xdead0
.4byte 0x005f8f93  # addi t6, t6, 5
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
.4byte 0xb4622457  # vmacc.vv v8, v4, v6, v0.t
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmacc.vv lane 0 writes a0"
.assert rd_wdata == 0x1411 "masked vmacc.vv lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmacc.vv lane 1 writes a0"
.assert rd_wdata == 0x2222 "masked vmacc.vv lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmacc.vv lane 2 writes a0"
.assert rd_wdata == 0x4833 "masked vmacc.vv lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmacc.vv lane 3 writes a0"
.assert rd_wdata == 0x4444 "masked vmacc.vv lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmacc.vv lane 4 writes a0"
.assert rd_wdata == 0x5555 "masked vmacc.vv lane 4"
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
.4byte 0xb462e457  # vmacc.vx v8, t0, v6, v0.t
.assert trap == 0 "vmacc.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmacc.vx lane 0 writes a0"
.assert rd_wdata == 0x1611 "masked vmacc.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmacc.vx lane 1 writes a0"
.assert rd_wdata == 0x2222 "masked vmacc.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmacc.vx lane 2 writes a0"
.assert rd_wdata == 0x4233 "masked vmacc.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmacc.vx lane 3 writes a0"
.assert rd_wdata == 0x4444 "masked vmacc.vx lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmacc.vx lane 4 writes a0"
.assert rd_wdata == 0x5555 "masked vmacc.vx lane 4"
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
.4byte 0xbc622457  # vnmsac.vv v8, v4, v6, v0.t
.assert trap == 0 "vnmsac.vv retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vnmsac.vv lane 0 writes a0"
.assert rd_wdata == 0xe11 "masked vnmsac.vv lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsac.vv lane 1 writes a0"
.assert rd_wdata == 0x2222 "masked vnmsac.vv lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsac.vv lane 2 writes a0"
.assert rd_wdata == 0x1e33 "masked vnmsac.vv lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsac.vv lane 3 writes a0"
.assert rd_wdata == 0x4444 "masked vnmsac.vv lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsac.vv lane 4 writes a0"
.assert rd_wdata == 0x5555 "masked vnmsac.vv lane 4"
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
.4byte 0xbc62e457  # vnmsac.vx v8, t0, v6, v0.t
.assert trap == 0 "vnmsac.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vnmsac.vx lane 0 writes a0"
.assert rd_wdata == 0xc11 "masked vnmsac.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsac.vx lane 1 writes a0"
.assert rd_wdata == 0x2222 "masked vnmsac.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsac.vx lane 2 writes a0"
.assert rd_wdata == 0x2433 "masked vnmsac.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsac.vx lane 3 writes a0"
.assert rd_wdata == 0x4444 "masked vnmsac.vx lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsac.vx lane 4 writes a0"
.assert rd_wdata == 0x5555 "masked vnmsac.vx lane 4"
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
.4byte 0xa4622457  # vmadd.vv v8, v4, v6, v0.t
.assert trap == 0 "vmadd.vv retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmadd.vv lane 0 writes a0"
.assert rd_wdata == 0x3433 "masked vmadd.vv lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmadd.vv lane 1 writes a0"
.assert rd_wdata == 0x2222 "masked vmadd.vv lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmadd.vv lane 2 writes a0"
.assert rd_wdata == 0x6965 "masked vmadd.vv lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmadd.vv lane 3 writes a0"
.assert rd_wdata == 0x4444 "masked vmadd.vv lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmadd.vv lane 4 writes a0"
.assert rd_wdata == 0x5555 "masked vmadd.vv lane 4"
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
.4byte 0xa462e457  # vmadd.vx v8, t0, v6, v0.t
.assert trap == 0 "vmadd.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vmadd.vx lane 0 writes a0"
.assert rd_wdata == 0x5655 "masked vmadd.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmadd.vx lane 1 writes a0"
.assert rd_wdata == 0x2222 "masked vmadd.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmadd.vx lane 2 writes a0"
.assert rd_wdata == 0x2ff "masked vmadd.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmadd.vx lane 3 writes a0"
.assert rd_wdata == 0x4444 "masked vmadd.vx lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vmadd.vx lane 4 writes a0"
.assert rd_wdata == 0x5555 "masked vmadd.vx lane 4"
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
.4byte 0xac622457  # vnmsub.vv v8, v4, v6, v0.t
.assert trap == 0 "vnmsub.vv retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vnmsub.vv lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffcdcd "masked vnmsub.vv lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsub.vv lane 1 writes a0"
.assert rd_wdata == 0x2222 "masked vnmsub.vv lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsub.vv lane 2 writes a0"
.assert rd_wdata == 0xffffffffffff9c9b "masked vnmsub.vv lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsub.vv lane 3 writes a0"
.assert rd_wdata == 0x4444 "masked vnmsub.vv lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsub.vv lane 4 writes a0"
.assert rd_wdata == 0x5555 "masked vnmsub.vv lane 4"
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
.4byte 0xac62e457  # vnmsub.vx v8, t0, v6, v0.t
.assert trap == 0 "vnmsub.vx retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vnmsub.vx lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffabab "masked vnmsub.vx lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsub.vx lane 1 writes a0"
.assert rd_wdata == 0x2222 "masked vnmsub.vx lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsub.vx lane 2 writes a0"
.assert rd_wdata == 0x301 "masked vnmsub.vx lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsub.vx lane 3 writes a0"
.assert rd_wdata == 0x4444 "masked vnmsub.vx lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked vnmsub.vx lane 4 writes a0"
.assert rd_wdata == 0x5555 "masked vnmsub.vx lane 4"
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5e03b257  # vmv.v.i v4, 7
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x5e023257  # vmv.v.i v4, 4
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e013257  # vmv.v.i v4, 2
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x25800313  # addi t1, zero, 600
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x1f400313  # addi t1, zero, 500
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x19000313  # addi t1, zero, 400
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x12c00313  # addi t1, zero, 300
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x0c800313  # addi t1, zero, 200
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x06400313  # addi t1, zero, 100
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x03c00313  # addi t1, zero, 60
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x03200313  # addi t1, zero, 50
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x02800313  # addi t1, zero, 40
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x01e00313  # addi t1, zero, 30
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e053457  # vmv.v.i v8, 10
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x02d00313  # addi t1, zero, 45
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xcd137657  # vsetivli a2, 6, e32, m2, ta, ma
.4byte 0xb4622457  # vmacc.vv v8, v4, v6, v0.t
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "m2 ta,ma masked vmacc lane 0 writes a0"
.assert rd_wdata == 0xd2 "m2 ta,ma masked vmacc lane 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "m2 ta,ma masked vmacc lane 3 writes a0"
.assert rd_wdata == 0x7f8 "m2 ta,ma masked vmacc lane 3"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "m2 ta,ma masked vmacc lane 5 (reg+1) writes a0"
.assert rd_wdata == 0x10a4 "m2 ta,ma masked vmacc lane 5 (reg+1)"
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x03c00313  # addi t1, zero, 60
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc112f657  # vsetivli a2, 5, e32, m2, tu, mu
.4byte 0x03200313  # addi t1, zero, 50
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x02800313  # addi t1, zero, 40
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc111f657  # vsetivli a2, 3, e32, m2, tu, mu
.4byte 0x01e00313  # addi t1, zero, 30
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1117657  # vsetivli a2, 2, e32, m2, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x5e053457  # vmv.v.i v8, 10
.4byte 0xcd137657  # vsetivli a2, 6, e32, m2, ta, ma
.4byte 0xae622457  # vnmsub.vv v8, v4, v6
.assert trap == 0 "vnmsub.vv retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "m2 ta,ma vnmsub lane 4 (reg+1) writes a0"
.assert rd_wdata == 0xc8 "m2 ta,ma vnmsub lane 4 (reg+1)"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "m2 ta,ma vnmsub lane 5 (reg+1) writes a0"
.assert rd_wdata == 0xb4 "m2 ta,ma vnmsub lane 5 (reg+1)"
.4byte 0xc0817657  # vsetivli a2, 2, e16, m1, tu, mu
.4byte 0x00009337  # lui t1, 0x9
.4byte 0x88830313  # addi t1, t1, -1912
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x00007337  # lui t1, 0x7
.4byte 0x77730313  # addi t1, t1, 1911
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0807657  # vsetivli a2, 0, e16, m1, tu, mu
.assert rd_addr == 12 "vl=0 int-mul-add writes a2"
.assert rd_wdata == 0x0 "vl=0 int-mul-add"
.4byte 0xb6622457  # vmacc.vv v8, v4, v6
.assert trap == 0 "vmacc.vv retires"
.4byte 0xbe62e457  # vnmsac.vx v8, t0, v6
.assert trap == 0 "vnmsac.vx retires"
.4byte 0xa6622457  # vmadd.vv v8, v4, v6
.assert trap == 0 "vmadd.vv retires"
.4byte 0xae62e457  # vnmsub.vx v8, t0, v6
.assert trap == 0 "vnmsub.vx retires"
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
.4byte 0x00507657  # vsetvli a2, zero, e8, mf8, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0x5e03b857  # vmv.v.i v16, 7
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x00507657  # vsetvli a2, zero, e8, mf8, tu, mu
.4byte 0xb7042c57  # vmacc.vv v24, v8, v16
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e8 mf8 lane 0 writes a0"
.assert rd_wdata == 0x26 "VLMAX e8 mf8 lane 0"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e8 mf8 lane 1 writes a0"
.assert rd_wdata == 0x26 "VLMAX e8 mf8 lane 1"
.4byte 0x00e07657  # vsetvli a2, zero, e16, mf4, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0x5e03b857  # vmv.v.i v16, 7
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x00e07657  # vsetvli a2, zero, e16, mf4, tu, mu
.4byte 0xbf02ec57  # vnmsac.vx v24, t0, v16
.assert trap == 0 "vnmsac.vx retires"
.4byte 0xc0e0f657  # vsetivli a2, 1, e16, mf4, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e16 mf4 lane 0 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "VLMAX e16 mf4 lane 0"
.4byte 0xc0e0f657  # vsetivli a2, 1, e16, mf4, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e16 mf4 lane 1 writes a0"
.assert rd_wdata == 0xffffffffffffffe0 "VLMAX e16 mf4 lane 1"
.4byte 0x01707657  # vsetvli a2, zero, e32, mf2, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0x5e03b857  # vmv.v.i v16, 7
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x01707657  # vsetvli a2, zero, e32, mf2, tu, mu
.4byte 0xa7042c57  # vmadd.vv v24, v8, v16
.assert trap == 0 "vmadd.vv retires"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e32 mf2 lane 0 writes a0"
.assert rd_wdata == 0x16 "VLMAX e32 mf2 lane 0"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e32 mf2 lane 1 writes a0"
.assert rd_wdata == 0x16 "VLMAX e32 mf2 lane 1"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0x5e03b857  # vmv.v.i v16, 7
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0xaf02ec57  # vnmsub.vx v24, t0, v16
.assert trap == 0 "vnmsub.vx retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e64 m1 lane 0 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "VLMAX e64 m1 lane 0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e64 m1 lane 1 writes a0"
.assert rd_wdata == 0xfffffffffffffff8 "VLMAX e64 m1 lane 1"
.4byte 0x01207657  # vsetvli a2, zero, e32, m4, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0x5e03b857  # vmv.v.i v16, 7
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x01207657  # vsetvli a2, zero, e32, m4, tu, mu
.4byte 0xb7042c57  # vmacc.vv v24, v8, v16
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc120f657  # vsetivli a2, 1, e32, m4, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e32 m4 lane 0 writes a0"
.assert rd_wdata == 0x26 "VLMAX e32 m4 lane 0"
.4byte 0xc120f657  # vsetivli a2, 1, e32, m4, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e32 m4 lane 1 writes a0"
.assert rd_wdata == 0x26 "VLMAX e32 m4 lane 1"
.4byte 0x01b07657  # vsetvli a2, zero, e64, m8, tu, mu
.4byte 0x5e02b457  # vmv.v.i v8, 5
.4byte 0x5e03b857  # vmv.v.i v16, 7
.4byte 0x5e01bc57  # vmv.v.i v24, 3
.4byte 0x00500293  # addi t0, zero, 5
.4byte 0x01b07657  # vsetvli a2, zero, e64, m8, tu, mu
.4byte 0xa702ec57  # vmadd.vx v24, t0, v16
.assert trap == 0 "vmadd.vx retires"
.4byte 0xc1b0f657  # vsetivli a2, 1, e64, m8, tu, mu
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "VLMAX e64 m8 lane 0 writes a0"
.assert rd_wdata == 0x16 "VLMAX e64 m8 lane 0"
.4byte 0xc1b0f657  # vsetivli a2, 1, e64, m8, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e64 m8 lane 1 writes a0"
.assert rd_wdata == 0x16 "VLMAX e64 m8 lane 1"

# Section 4: Legal overlaps (vd==vs1, vd==vs2, vs1==vs2, vd==vs1==vs2, unmasked v0).
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e05b357  # vmv.v.i v6, 11
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e03b357  # vmv.v.i v6, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xb6622257  # vmacc.vv v4, v4, v6
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "overlap vd==vs1 vmacc[0] writes a0"
.assert rd_wdata == 0x18 "overlap vd==vs1 vmacc[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e40b857  # vslidedown.vi v16, v4, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "overlap vd==vs1 vmacc[1] writes a0"
.assert rd_wdata == 0x3c "overlap vd==vs1 vmacc[1]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xa6622257  # vmadd.vv v4, v4, v6
.assert trap == 0 "vmadd.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "overlap vd==vs1 vmadd[0] writes a0"
.assert rd_wdata == 0x10 "overlap vd==vs1 vmadd[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e40b857  # vslidedown.vi v16, v4, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "overlap vd==vs1 vmadd[1] writes a0"
.assert rd_wdata == 0x24 "overlap vd==vs1 vmadd[1]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b257  # vmv.v.i v4, 3
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e05b357  # vmv.v.i v6, 11
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e03b357  # vmv.v.i v6, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xbe622357  # vnmsac.vv v6, v4, v6
.assert trap == 0 "vnmsac.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42602557  # vmv.x.s a0, v6
.assert rd_addr == 10 "overlap vd==vs2 vnmsac[0] writes a0"
.assert rd_wdata == 0xfffffffffffffff2 "overlap vd==vs2 vnmsac[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e60b857  # vslidedown.vi v16, v6, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "overlap vd==vs2 vnmsac[1] writes a0"
.assert rd_wdata == 0xffffffffffffffd4 "overlap vd==vs2 vnmsac[1]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e04b257  # vmv.v.i v4, 9
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e053457  # vmv.v.i v8, 10
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xb6422457  # vmacc.vv v8, v4, v4
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "overlap vs1==vs2 vmacc[0] writes a0"
.assert rd_wdata == 0x2e "overlap vs1==vs2 vmacc[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "overlap vs1==vs2 vmacc[1] writes a0"
.assert rd_wdata == 0x65 "overlap vs1==vs2 vmacc[1]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e04b257  # vmv.v.i v4, 9
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xae422257  # vnmsub.vv v4, v4, v4
.assert trap == 0 "vnmsub.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "overlap vd==vs1==vs2 vnmsub[0] writes a0"
.assert rd_wdata == 0xffffffffffffffe2 "overlap vd==vs1==vs2 vnmsub[0]"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e40b857  # vslidedown.vi v16, v4, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "overlap vd==vs1==vs2 vnmsub[1] writes a0"
.assert rd_wdata == 0xffffffffffffffb8 "overlap vd==vs1==vs2 vnmsub[1]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e023057  # vmv.v.i v0, 4
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e01b057  # vmv.v.i v0, 3
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e033257  # vmv.v.i v4, 6
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e02b257  # vmv.v.i v4, 5
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e043357  # vmv.v.i v6, 8
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e03b357  # vmv.v.i v6, 7
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xb6622057  # vmacc.vv v0, v4, v6
.assert trap == 0 "vmacc.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "unmasked legal vd==v0 vmacc[0] writes a0"
.assert rd_wdata == 0x26 "unmasked legal vd==v0 vmacc[0]"
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0xa6002257  # vmadd.vv v4, v0, v0
.assert trap == 0 "vmadd.vv retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42402557  # vmv.x.s a0, v4
.assert rd_addr == 10 "unmasked legal vs1==vs2==v0 vmadd[0] writes a0"
.assert rd_wdata == 0xe4 "unmasked legal vs1==vs2==v0 vmadd[0]"

# Section 5: Illegal-instruction traps (mcause == 2, mtval == insn, destination untouched).
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
.4byte 0xb4622057  # vmacc.vv v0, v4, v6, v0.t
.assert trap == 1 "vmacc.vv masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmacc.vv masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmacc.vv masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmacc.vv masked vd==v0 mtval writes a0"
.assert rd_wdata == 0xb4622057 "vmacc.vv masked vd==v0 mtval matches instruction"
.4byte 0xbc62e057  # vnmsac.vx v0, t0, v6, v0.t
.assert trap == 1 "vnmsac.vx masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vnmsac.vx masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vnmsac.vx masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vnmsac.vx masked vd==v0 mtval writes a0"
.assert rd_wdata == 0xbc62e057 "vnmsac.vx masked vd==v0 mtval matches instruction"
.4byte 0xa4622057  # vmadd.vv v0, v4, v6, v0.t
.assert trap == 1 "vmadd.vv masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmadd.vv masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmadd.vv masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmadd.vv masked vd==v0 mtval writes a0"
.assert rd_wdata == 0xa4622057 "vmadd.vv masked vd==v0 mtval matches instruction"
.4byte 0xac62e057  # vnmsub.vx v0, t0, v6, v0.t
.assert trap == 1 "vnmsub.vx masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vnmsub.vx masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vnmsub.vx masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vnmsub.vx masked vd==v0 mtval writes a0"
.assert rd_wdata == 0xac62e057 "vnmsub.vx masked vd==v0 mtval matches instruction"
.4byte 0xb4022457  # vmacc.vv v8, v4, v0, v0.t
.assert trap == 1 "vmacc.vv masked vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmacc.vv masked vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmacc.vv masked vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmacc.vv masked vs2==v0 mtval writes a0"
.assert rd_wdata == 0xb4022457 "vmacc.vv masked vs2==v0 mtval matches instruction"
.4byte 0xa402e457  # vmadd.vx v8, t0, v0, v0.t
.assert trap == 1 "vmadd.vx masked vs2==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmadd.vx masked vs2==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmadd.vx masked vs2==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmadd.vx masked vs2==v0 mtval writes a0"
.assert rd_wdata == 0xa402e457 "vmadd.vx masked vs2==v0 mtval matches instruction"
.4byte 0xbc602457  # vnmsac.vv v8, v0, v6, v0.t
.assert trap == 1 "vnmsac.vv masked vs1==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vnmsac.vv masked vs1==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vnmsac.vv masked vs1==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vnmsac.vv masked vs1==v0 mtval writes a0"
.assert rd_wdata == 0xbc602457 "vnmsac.vv masked vs1==v0 mtval matches instruction"
.4byte 0xac602457  # vnmsub.vv v8, v0, v6, v0.t
.assert trap == 1 "vnmsub.vv masked vs1==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vnmsub.vv masked vs1==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vnmsub.vv masked vs1==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vnmsub.vv masked vs1==v0 mtval writes a0"
.assert rd_wdata == 0xac602457 "vnmsub.vv masked vs1==v0 mtval matches instruction"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "v8 sentinel untouched after traps 1-8 writes a0"
.assert rd_wdata == 0x42 "v8 sentinel untouched after traps 1-8"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "v0 sentinel untouched after traps 1-8 writes a0"
.assert rd_wdata == 0x33 "v0 sentinel untouched after traps 1-8"
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0xb4622057  # vmacc.vv v0, v4, v6, v0.t
.assert trap == 1 "vmacc.vv m2 masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmacc.vv m2 masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmacc.vv m2 masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmacc.vv m2 masked vd==v0 mtval writes a0"
.assert rd_wdata == 0xb4622057 "vmacc.vv m2 masked vd==v0 mtval matches instruction"
.4byte 0xb66224d7  # vmacc.vv v9, v4, v6
.assert trap == 1 "vmacc.vv m2 misaligned vd traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmacc.vv m2 misaligned vd mcause writes a0"
.assert rd_wdata == 0x2 "vmacc.vv m2 misaligned vd illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmacc.vv m2 misaligned vd mtval writes a0"
.assert rd_wdata == 0xb66224d7 "vmacc.vv m2 misaligned vd mtval matches instruction"
.4byte 0xbe62a457  # vnmsac.vv v8, v5, v6
.assert trap == 1 "vnmsac.vv m2 misaligned vs1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vnmsac.vv m2 misaligned vs1 mcause writes a0"
.assert rd_wdata == 0x2 "vnmsac.vv m2 misaligned vs1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vnmsac.vv m2 misaligned vs1 mtval writes a0"
.assert rd_wdata == 0xbe62a457 "vnmsac.vv m2 misaligned vs1 mtval matches instruction"
.4byte 0xa6722457  # vmadd.vv v8, v4, v7
.assert trap == 1 "vmadd.vv m2 misaligned vs2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmadd.vv m2 misaligned vs2 mcause writes a0"
.assert rd_wdata == 0x2 "vmadd.vv m2 misaligned vs2 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmadd.vv m2 misaligned vs2 mtval writes a0"
.assert rd_wdata == 0xa6722457 "vmadd.vv m2 misaligned vs2 mtval matches instruction"
.4byte 0xae62e4d7  # vnmsub.vx v9, t0, v6
.assert trap == 1 "vnmsub.vx m2 misaligned vd traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vnmsub.vx m2 misaligned vd mcause writes a0"
.assert rd_wdata == 0x2 "vnmsub.vx m2 misaligned vd illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vnmsub.vx m2 misaligned vd mtval writes a0"
.assert rd_wdata == 0xae62e4d7 "vnmsub.vx m2 misaligned vd mtval matches instruction"
.4byte 0xc1227657  # vsetivli a2, 4, e32, m4, tu, mu
.4byte 0xb6822557  # vmacc.vv v10, v4, v8
.assert trap == 1 "vmacc.vv m4 misaligned vd traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmacc.vv m4 misaligned vd mcause writes a0"
.assert rd_wdata == 0x2 "vmacc.vv m4 misaligned vd illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmacc.vv m4 misaligned vd mtval writes a0"
.assert rd_wdata == 0xb6822557 "vmacc.vv m4 misaligned vd mtval matches instruction"
.4byte 0xc200f657  # vsetivli a2, 1, 0x20 (sets vill=1)
.assert rd_addr == 12 "vill vsetivli writes a2"
.assert rd_wdata == 0x0 "vill vsetivli sets vl=0"
.4byte 0xb6622457  # vmacc.vv v8, v4, v6
.assert trap == 1 "vmacc.vv under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmacc.vv under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vmacc.vv under vill=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmacc.vv under vill=1 mtval writes a0"
.assert rd_wdata == 0xb6622457 "vmacc.vv under vill=1 mtval matches instruction"
.4byte 0xa662e457  # vmadd.vx v8, t0, v6
.assert trap == 1 "vmadd.vx under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmadd.vx under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vmadd.vx under vill=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmadd.vx under vill=1 mtval writes a0"
.assert rd_wdata == 0xa662e457 "vmadd.vx under vill=1 mtval matches instruction"
