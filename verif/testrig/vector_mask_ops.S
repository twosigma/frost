# Directed TestRIG trace for all 15 base-V mask-register encodings:
# vmandn.mm, vmand.mm, vmor.mm, vmxor.mm, vmorn.mm, vmnand.mm, vmnor.mm, vmxnor.mm,
# vcpop.m, vfirst.m, vmsbf.m, vmsof.m, vmsif.m, viota.m, vid.v.
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

# Section 1: Control readout (vmv.x.s a0, v21 = 0x43502557).
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00001337  # lui t1, 0x1
.4byte 0xaa530313  # addi t1, t1, -1371
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x33300313  # addi t1, zero, 819
.4byte 0x42036357  # vmv.s.x v6, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003ad7  # vmv.v.i v21, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0x42036ad7  # vmv.s.x v21, t1
.4byte 0xc0067657  # vsetivli a2, 12, e8, m1, tu, mu
.4byte 0x62432ad7  # vmandn.mm v21, v4, v6
.assert trap == 0 "vmandn.mm retires"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x43502557  # vmv.x.s a0, v21
.assert rd_addr == 10 "ctrl vmandn.mm with tail nibble writes a0"
.assert rd_wdata == 0xf884 "ctrl vmandn.mm with tail nibble"

# Section 2: All 8 mask-register logical ops (truth tables, >64-bit, tail, overlaps, vl=0, VLMAX).
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0xdeadc337  # lui t1, 0xdeadc
.4byte 0xeef30313  # addi t1, t1, -273
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x0000afb7  # lui t6, 0xa
.4byte 0x50cf8f93  # addi t6, t6, 1292
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x5555b337  # lui t1, 0x5555b
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00ff1fb7  # lui t6, 0xff1
.4byte 0xf0cf8f93  # addi t6, t6, -244
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003357  # vmv.v.i v6, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0xcafec337  # lui t1, 0xcafec
.4byte 0xabe30313  # addi t1, t1, -1346
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00004fb7  # lui t6, 0x4
.4byte 0xc0af8f93  # addi t6, t6, -1014
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034357  # vmv.v.x v6, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3333d337  # lui t1, 0x3333d
.4byte 0xccc30313  # addi t1, t1, -820
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x0f0f3fb7  # lui t6, 0xf0f3
.4byte 0x30af8f93  # addi t6, t6, 778
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036357  # vmv.s.x v6, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x12345337  # lui t1, 0x12345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9abc5fb7  # lui t6, 0x9abc5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vmandn.mm vl=80 writes a2"
.assert rd_wdata == 0x50 "vmandn.mm vl=80"
.4byte 0x62432457  # vmandn.mm v8, v4, v6
.assert trap == 0 "vmandn.mm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmandn.mm vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0x4444222200f00c04 "vmandn.mm vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmandn.mm vl=80 bits 64..79 + tail 80..127 writes a0"
.assert rd_wdata == 0x123456789abc8104 "vmandn.mm vl=80 bits 64..79 + tail 80..127"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x12345337  # lui t1, 0x12345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9abc5fb7  # lui t6, 0x9abc5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vmand.mm vl=80 writes a2"
.assert rd_wdata == 0x50 "vmand.mm vl=80"
.4byte 0x66432457  # vmand.mm v8, v4, v6
.assert trap == 0 "vmand.mm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmand.mm vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0x11118888000f0308 "vmand.mm vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmand.mm vl=80 bits 64..79 + tail 80..127 writes a0"
.assert rd_wdata == 0x123456789abc2408 "vmand.mm vl=80 bits 64..79 + tail 80..127"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x12345337  # lui t1, 0x12345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9abc5fb7  # lui t6, 0x9abc5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vmor.mm vl=80 writes a2"
.assert rd_wdata == 0x50 "vmor.mm vl=80"
.4byte 0x6a432457  # vmor.mm v8, v4, v6
.assert trap == 0 "vmor.mm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmor.mm vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0x7777eeee0fff3f0e "vmor.mm vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmor.mm vl=80 bits 64..79 + tail 80..127 writes a0"
.assert rd_wdata == 0x123456789abcbd0e "vmor.mm vl=80 bits 64..79 + tail 80..127"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x12345337  # lui t1, 0x12345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9abc5fb7  # lui t6, 0x9abc5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vmxor.mm vl=80 writes a2"
.assert rd_wdata == 0x50 "vmxor.mm vl=80"
.4byte 0x6e432457  # vmxor.mm v8, v4, v6
.assert trap == 0 "vmxor.mm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmxor.mm vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0x666666660ff03c06 "vmxor.mm vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmxor.mm vl=80 bits 64..79 + tail 80..127 writes a0"
.assert rd_wdata == 0x123456789abc9906 "vmxor.mm vl=80 bits 64..79 + tail 80..127"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x12345337  # lui t1, 0x12345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9abc5fb7  # lui t6, 0x9abc5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vmorn.mm vl=80 writes a2"
.assert rd_wdata == 0x50 "vmorn.mm vl=80"
.4byte 0x72432457  # vmorn.mm v8, v4, v6
.assert trap == 0 "vmorn.mm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmorn.mm vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0xddddbbbbf0ffcffd "vmorn.mm vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmorn.mm vl=80 bits 64..79 + tail 80..127 writes a0"
.assert rd_wdata == 0x123456789abce7fd "vmorn.mm vl=80 bits 64..79 + tail 80..127"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x12345337  # lui t1, 0x12345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9abc5fb7  # lui t6, 0x9abc5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vmnand.mm vl=80 writes a2"
.assert rd_wdata == 0x50 "vmnand.mm vl=80"
.4byte 0x76432457  # vmnand.mm v8, v4, v6
.assert trap == 0 "vmnand.mm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmnand.mm vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0xeeee7777fff0fcf7 "vmnand.mm vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmnand.mm vl=80 bits 64..79 + tail 80..127 writes a0"
.assert rd_wdata == 0x123456789abcdbf7 "vmnand.mm vl=80 bits 64..79 + tail 80..127"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x12345337  # lui t1, 0x12345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9abc5fb7  # lui t6, 0x9abc5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vmnor.mm vl=80 writes a2"
.assert rd_wdata == 0x50 "vmnor.mm vl=80"
.4byte 0x7a432457  # vmnor.mm v8, v4, v6
.assert trap == 0 "vmnor.mm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmnor.mm vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0x88881111f000c0f1 "vmnor.mm vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmnor.mm vl=80 bits 64..79 + tail 80..127 writes a0"
.assert rd_wdata == 0x123456789abc42f1 "vmnor.mm vl=80 bits 64..79 + tail 80..127"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x12345337  # lui t1, 0x12345
.4byte 0x67830313  # addi t1, t1, 1656
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x9abc5fb7  # lui t6, 0x9abc5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xaaaab337  # lui t1, 0xaaaab
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xaaaabfb7  # lui t6, 0xaaaab
.4byte 0xaaaf8f93  # addi t6, t6, -1366
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vmxnor.mm vl=80 writes a2"
.assert rd_wdata == 0x50 "vmxnor.mm vl=80"
.4byte 0x7e432457  # vmxnor.mm v8, v4, v6
.assert trap == 0 "vmxnor.mm retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmxnor.mm vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0x99999999f00fc3f9 "vmxnor.mm vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmxnor.mm vl=80 bits 64..79 + tail 80..127 writes a0"
.assert rd_wdata == 0x123456789abc66f9 "vmxnor.mm vl=80 bits 64..79 + tail 80..127"
# Mask logical overlaps (vd==vs2, vd==vs1, vd==vs2==vs1, v0, odd regs at m2, vl=0, VLMAX).
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0034d7  # vmv.v.i v9, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0f000313  # addi t1, zero, 240
.4byte 0x420364d7  # vmv.s.x v9, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0035d7  # vmv.v.i v11, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0cc00313  # addi t1, zero, 204
.4byte 0x420365d7  # vmv.s.x v11, t1
.4byte 0xcd147657  # vsetivli a2, 8, e32, m2, ta, ma
.4byte 0x6295a4d7  # vmandn.mm v9, v9, v11
.assert trap == 0 "vmandn.mm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "m2 odd vd==vs2 vmandn.mm writes a0"
.assert rd_wdata == 0x30 "m2 odd vd==vs2 vmandn.mm"
.4byte 0xc1147657  # vsetivli a2, 8, e32, m2, tu, mu
.4byte 0x7295a5d7  # vmorn.mm v11, v9, v11
.assert trap == 0 "vmorn.mm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42b02557  # vmv.x.s a0, v11
.assert rd_addr == 10 "m2 odd vd==vs1 vmorn.mm writes a0"
.assert rd_wdata == 0x33 "m2 odd vd==vs1 vmorn.mm"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0a500313  # addi t1, zero, 165
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x6e002057  # vmxor.mm v0, v0, v0
.assert trap == 0 "vmxor.mm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "vmclr (vmxor v0,v0,v0) writes a0"
.assert rd_wdata == 0x0 "vmclr (vmxor v0,v0,v0)"
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x7e002057  # vmxnor.mm v0, v0, v0
.assert trap == 0 "vmxnor.mm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "vmset (vmxnor v0,v0,v0) writes a0"
.assert rd_wdata == 0xffffffffffffffff "vmset (vmxnor v0,v0,v0)"
.4byte 0xc0007657  # vsetivli a2, 0, e8, m1, tu, mu
.assert rd_addr == 12 "vl=0 mask logical writes a2"
.assert rd_wdata == 0x0 "vl=0 mask logical"
.4byte 0x6e002057  # vmxor.mm v0, v0, v0
.assert trap == 0 "vmxor.mm retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "vl=0 leaves v0 untouched writes a0"
.assert rd_wdata == 0xffffffffffffffff "vl=0 leaves v0 untouched"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x6e002057  # vmxor.mm v0, v0, v0
.assert trap == 0 "vmxor.mm retires"
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x42082557  # vcpop.m a0, v0
.assert trap == 0 "VLMAX e64 m1 vmxor cleared active bits retires"
.assert rd_addr == 10 "VLMAX e64 m1 vmxor cleared active bits writes a0"
.assert rd_wdata == 0x0 "VLMAX e64 m1 vmxor cleared active bits"

# Section 3: vcpop.m and vfirst.m (blocks 0 and 1, masked/unmasked, empty, vl=0, VLMAX, vs2==v0).
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x04008337  # lui t1, 0x4008
.4byte 0x00830313  # addi t1, t1, 8
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00020fb7  # lui t6, 0x20
.4byte 0x008f8f93  # addi t6, t6, 8
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x04008337  # lui t1, 0x4008
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x80000337  # lui t1, 0x80000
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x00020fb7  # lui t6, 0x20
.4byte 0x020f8f93  # addi t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vcpop/vfirst vl=80 writes a2"
.assert rd_wdata == 0x50 "vcpop/vfirst vl=80"
.4byte 0x42482557  # vcpop.m a0, v4
.assert trap == 0 "vcpop.m unmasked vl=80 (3+2, ignores bit 90) retires"
.assert rd_addr == 10 "vcpop.m unmasked vl=80 (3+2, ignores bit 90) writes a0"
.assert rd_wdata == 0x5 "vcpop.m unmasked vl=80 (3+2, ignores bit 90)"
.4byte 0x4248a557  # vfirst.m a0, v4
.assert trap == 0 "vfirst.m unmasked vl=80 finds bit 3 retires"
.assert rd_addr == 10 "vfirst.m unmasked vl=80 finds bit 3 writes a0"
.assert rd_wdata == 0x3 "vfirst.m unmasked vl=80 finds bit 3"
.4byte 0x40482557  # vcpop.m a0, v4, v0.t
.assert trap == 0 "vcpop.m masked vl=80 (bits 17,63,79) retires"
.assert rd_addr == 10 "vcpop.m masked vl=80 (bits 17,63,79) writes a0"
.assert rd_wdata == 0x3 "vcpop.m masked vl=80 (bits 17,63,79)"
.4byte 0x4048a557  # vfirst.m a0, v4, v0.t
.assert trap == 0 "vfirst.m masked vl=80 skips masked-off bit 3, finds 17 retires"
.assert rd_addr == 10 "vfirst.m masked vl=80 skips masked-off bit 3, finds 17 writes a0"
.assert rd_wdata == 0x11 "vfirst.m masked vl=80 skips masked-off bit 3, finds 17"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0032d7  # vmv.v.i v5, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x04008337  # lui t1, 0x4008
.4byte 0x00830313  # addi t1, t1, 8
.4byte 0x5e0342d7  # vmv.v.x v5, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x420362d7  # vmv.s.x v5, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00008337  # lui t1, 0x8
.4byte 0x5e034057  # vmv.v.x v0, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0xfff00313  # addi t1, zero, -1
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.4byte 0x42582557  # vcpop.m a0, v5
.assert trap == 0 "vcpop.m block-1 unmasked vl=80 (67,79) retires"
.assert rd_addr == 10 "vcpop.m block-1 unmasked vl=80 (67,79) writes a0"
.assert rd_wdata == 0x2 "vcpop.m block-1 unmasked vl=80 (67,79)"
.4byte 0x4258a557  # vfirst.m a0, v5
.assert trap == 0 "vfirst.m block-1 unmasked finds bit 67 retires"
.assert rd_addr == 10 "vfirst.m block-1 unmasked finds bit 67 writes a0"
.assert rd_wdata == 0x43 "vfirst.m block-1 unmasked finds bit 67"
.4byte 0x40582557  # vcpop.m a0, v5, v0.t
.assert trap == 0 "vcpop.m block-1 masked vl=80 (79) retires"
.assert rd_addr == 10 "vcpop.m block-1 masked vl=80 (79) writes a0"
.assert rd_wdata == 0x1 "vcpop.m block-1 masked vl=80 (79)"
.4byte 0x4058a557  # vfirst.m a0, v5, v0.t
.assert trap == 0 "vfirst.m block-1 masked skips 67, finds 79 retires"
.assert rd_addr == 10 "vfirst.m block-1 masked skips 67, finds 79 writes a0"
.assert rd_wdata == 0x4f "vfirst.m block-1 masked skips 67, finds 79"
.4byte 0x04000293  # addi t0, zero, 64
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.assert rd_addr == 12 "vl=64 cuts off block 1 writes a2"
.assert rd_wdata == 0x40 "vl=64 cuts off block 1"
.4byte 0x42582557  # vcpop.m a0, v5
.assert trap == 0 "vcpop.m vl=64 ignores bit 67 -> 0 retires"
.assert rd_addr == 10 "vcpop.m vl=64 ignores bit 67 -> 0 writes a0"
.assert rd_wdata == 0x0 "vcpop.m vl=64 ignores bit 67 -> 0"
.4byte 0x4258a557  # vfirst.m a0, v5
.assert trap == 0 "vfirst.m vl=64 ignores bit 67 -> -1 retires"
.assert rd_addr == 10 "vfirst.m vl=64 ignores bit 67 -> -1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vfirst.m vl=64 ignores bit 67 -> -1"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0ff00313  # addi t1, zero, 255
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xf0030313  # addi t1, t1, -256
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0087657  # vsetivli a2, 16, e8, m1, tu, mu
.4byte 0x40482557  # vcpop.m a0, v4, v0.t
.assert trap == 0 "vcpop.m masked disjoint -> 0 retires"
.assert rd_addr == 10 "vcpop.m masked disjoint -> 0 writes a0"
.assert rd_wdata == 0x0 "vcpop.m masked disjoint -> 0"
.4byte 0x4048a557  # vfirst.m a0, v4, v0.t
.assert trap == 0 "vfirst.m masked disjoint -> -1 retires"
.assert rd_addr == 10 "vfirst.m masked disjoint -> -1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vfirst.m masked disjoint -> -1"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0a000313  # addi t1, zero, 160
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0087657  # vsetivli a2, 16, e8, m1, tu, mu
.4byte 0x40082557  # vcpop.m a0, v0, v0.t
.assert trap == 0 "vcpop.m legal masked vs2==v0 retires"
.assert rd_addr == 10 "vcpop.m legal masked vs2==v0 writes a0"
.assert rd_wdata == 0x2 "vcpop.m legal masked vs2==v0"
.4byte 0x4008a557  # vfirst.m a0, v0, v0.t
.assert trap == 0 "vfirst.m legal masked vs2==v0 retires"
.assert rd_addr == 10 "vfirst.m legal masked vs2==v0 writes a0"
.assert rd_wdata == 0x5 "vfirst.m legal masked vs2==v0"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xfff30313  # addi t1, t1, -1
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0007657  # vsetivli a2, 0, e8, m1, tu, mu
.assert rd_addr == 12 "vl=0 vcpop/vfirst writes a2"
.assert rd_wdata == 0x0 "vl=0 vcpop/vfirst"
.4byte 0x42482557  # vcpop.m a0, v4
.assert trap == 0 "vcpop.m vl=0 -> 0 retires"
.assert rd_addr == 10 "vcpop.m vl=0 -> 0 writes a0"
.assert rd_wdata == 0x0 "vcpop.m vl=0 -> 0"
.4byte 0x4248a557  # vfirst.m a0, v4
.assert trap == 0 "vfirst.m vl=0 -> -1 retires"
.assert rd_addr == 10 "vfirst.m vl=0 -> -1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vfirst.m vl=0 -> -1"
.4byte 0x40482557  # vcpop.m a0, v4, v0.t
.assert trap == 0 "vcpop.m masked vl=0 -> 0 retires"
.assert rd_addr == 10 "vcpop.m masked vl=0 -> 0 writes a0"
.assert rd_wdata == 0x0 "vcpop.m masked vl=0 -> 0"
.4byte 0x4048a557  # vfirst.m a0, v4, v0.t
.assert trap == 0 "vfirst.m masked vl=0 -> -1 retires"
.assert rd_addr == 10 "vfirst.m masked vl=0 -> -1 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vfirst.m masked vl=0 -> -1"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x42482557  # vcpop.m a0, v4
.assert trap == 0 "vcpop.m VLMAX e64 m1 retires"
.assert rd_addr == 10 "vcpop.m VLMAX e64 m1 writes a0"
.assert rd_wdata == 0x1 "vcpop.m VLMAX e64 m1"
.4byte 0x4248a557  # vfirst.m a0, v4
.assert trap == 0 "vfirst.m VLMAX e64 m1 retires"
.assert rd_addr == 10 "vfirst.m VLMAX e64 m1 writes a0"
.assert rd_wdata == 0x1 "vfirst.m VLMAX e64 m1"

# Section 4: vmsbf.m, vmsof.m, vmsif.m (bit 0, multi-set, block 1, masked-off skip, none-set, mu, vl=0).
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00b00313  # addi t1, zero, 11
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0x0aa30313  # addi t1, t1, 170
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x5240a457  # vmsbf.m v8, v4
.assert trap == 0 "vmsbf.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsbf.m bit0 set (vl=8, tail preserved) writes a0"
.assert rd_wdata == 0xf000 "vmsbf.m bit0 set (vl=8, tail preserved)"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0x0aa30313  # addi t1, t1, 170
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x52412457  # vmsof.m v8, v4
.assert trap == 0 "vmsof.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsof.m bit0 set (vl=8, tail preserved) writes a0"
.assert rd_wdata == 0xf001 "vmsof.m bit0 set (vl=8, tail preserved)"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0x0aa30313  # addi t1, t1, 170
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x5241a457  # vmsif.m v8, v4
.assert trap == 0 "vmsif.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsif.m bit0 set (vl=8, tail preserved) writes a0"
.assert rd_wdata == 0xf001 "vmsif.m bit0 set (vl=8, tail preserved)"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x20800313  # addi t1, zero, 520
.4byte 0x5e034257  # vmv.v.x v4, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xabcd5fb7  # lui t6, 0xabcd5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x55555337  # lui t1, 0x55555
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x55555fb7  # lui t6, 0x55555
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.4byte 0x5240a457  # vmsbf.m v8, v4
.assert trap == 0 "vmsbf.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsbf.m vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vmsbf.m vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmsbf.m vl=80 bits 64..79 + tail writes a0"
.assert rd_wdata == 0xabcd0007 "vmsbf.m vl=80 bits 64..79 + tail"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xabcd5fb7  # lui t6, 0xabcd5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x55555337  # lui t1, 0x55555
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x55555fb7  # lui t6, 0x55555
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.4byte 0x52412457  # vmsof.m v8, v4
.assert trap == 0 "vmsof.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsof.m vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0x0 "vmsof.m vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmsof.m vl=80 bits 64..79 + tail writes a0"
.assert rd_wdata == 0xabcd0008 "vmsof.m vl=80 bits 64..79 + tail"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x00000313  # addi t1, zero, 0
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xabcd5fb7  # lui t6, 0xabcd5
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x55555337  # lui t1, 0x55555
.4byte 0x55530313  # addi t1, t1, 1365
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x55555fb7  # lui t6, 0x55555
.4byte 0x555f8f93  # addi t6, t6, 1365
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x05000293  # addi t0, zero, 80
.4byte 0x0032f657  # vsetvli a2, t0, e8, m8, tu, mu
.4byte 0x5241a457  # vmsif.m v8, v4
.assert trap == 0 "vmsif.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsif.m vl=80 bits 0..63 writes a0"
.assert rd_wdata == 0xffffffffffffffff "vmsif.m vl=80 bits 0..63"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80b757  # vslidedown.vi v14, v8, 1
.4byte 0x42e02557  # vmv.x.s a0, v14
.assert rd_addr == 10 "vmsif.m vl=80 bits 64..79 + tail writes a0"
.assert rd_wdata == 0xabcd000f "vmsif.m vl=80 bits 64..79 + tail"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xc5530313  # addi t1, t1, -939
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0057657  # vsetivli a2, 10, e8, m1, tu, mu
.4byte 0x5240a457  # vmsbf.m v8, v4
.assert trap == 0 "vmsbf.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsbf.m all-zero source vl=10 writes a0"
.assert rd_wdata == 0xffff "vmsbf.m all-zero source vl=10"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xc5530313  # addi t1, t1, -939
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0057657  # vsetivli a2, 10, e8, m1, tu, mu
.4byte 0x52412457  # vmsof.m v8, v4
.assert trap == 0 "vmsof.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsof.m all-zero source vl=10 writes a0"
.assert rd_wdata == 0xfc00 "vmsof.m all-zero source vl=10"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xc5530313  # addi t1, t1, -939
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0057657  # vsetivli a2, 10, e8, m1, tu, mu
.4byte 0x5241a457  # vmsif.m v8, v4
.assert trap == 0 "vmsif.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsif.m all-zero source vl=10 writes a0"
.assert rd_wdata == 0xffff "vmsif.m all-zero source vl=10"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x22200313  # addi t1, zero, 546
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x7ed00313  # addi t1, zero, 2029
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0067657  # vsetivli a2, 12, e8, m1, tu, mu
.4byte 0x5040a457  # vmsbf.m v8, v4, v0.t
.assert trap == 0 "vmsbf.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsbf.m masked skips bit1, triggers bit5, mu preserved writes a0"
.assert rd_wdata == 0xf80f "vmsbf.m masked skips bit1, triggers bit5, mu preserved"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0067657  # vsetivli a2, 12, e8, m1, tu, mu
.4byte 0x50412457  # vmsof.m v8, v4, v0.t
.assert trap == 0 "vmsof.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsof.m masked skips bit1, triggers bit5, mu preserved writes a0"
.assert rd_wdata == 0xf822 "vmsof.m masked skips bit1, triggers bit5, mu preserved"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00010337  # lui t1, 0x10
.4byte 0xaaa30313  # addi t1, t1, -1366
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0067657  # vsetivli a2, 12, e8, m1, tu, mu
.4byte 0x5041a457  # vmsif.m v8, v4, v0.t
.assert trap == 0 "vmsif.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsif.m masked skips bit1, triggers bit5, mu preserved writes a0"
.assert rd_wdata == 0xf82f "vmsif.m masked skips bit1, triggers bit5, mu preserved"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0fd00313  # addi t1, zero, 253
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x5040a457  # vmsbf.m v8, v4, v0.t
.assert trap == 0 "vmsbf.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsbf.m masked none-active writes a0"
.assert rd_wdata == 0xf0ff "vmsbf.m masked none-active"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x50412457  # vmsof.m v8, v4, v0.t
.assert trap == 0 "vmsof.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsof.m masked none-active writes a0"
.assert rd_wdata == 0xf002 "vmsof.m masked none-active"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x5041a457  # vmsif.m v8, v4, v0.t
.assert trap == 0 "vmsif.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vmsif.m masked none-active writes a0"
.assert rd_wdata == 0xf0ff "vmsif.m masked none-active"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00400313  # addi t1, zero, 4
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x5240a057  # vmsbf.m v0, v4
.assert trap == 0 "vmsbf.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "unmasked legal vd==v0 vmsbf.m writes a0"
.assert rd_wdata == 0xf003 "unmasked legal vd==v0 vmsbf.m"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000f337  # lui t1, 0xf
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0047657  # vsetivli a2, 8, e8, m1, tu, mu
.4byte 0x50012457  # vmsof.m v8, v0, v0.t
.assert trap == 0 "vmsof.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked legal vs2==v0 vmsof.m writes a0"
.assert rd_wdata == 0xf004 "masked legal vs2==v0 vmsof.m"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x0000a337  # lui t1, 0xa
.4byte 0x55a30313  # addi t1, t1, 1370
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0xc0007657  # vsetivli a2, 0, e8, m1, tu, mu
.assert rd_addr == 12 "vl=0 mask scans writes a2"
.assert rd_wdata == 0x0 "vl=0 mask scans"
.4byte 0x5240a457  # vmsbf.m v8, v4
.assert trap == 0 "vmsbf.m retires"
.4byte 0x52412457  # vmsof.m v8, v4
.assert trap == 0 "vmsof.m retires"
.4byte 0x5241a457  # vmsif.m v8, v4
.assert trap == 0 "vmsif.m retires"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl=0 leaves vmsbf/vmsof/vmsif vd untouched writes a0"
.assert rd_wdata == 0xa55a "vl=0 leaves vmsbf/vmsof/vmsif vd untouched"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003257  # vmv.v.i v4, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00200313  # addi t1, zero, 2
.4byte 0x42036257  # vmv.s.x v4, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5240a457  # vmsbf.m v8, v4
.assert trap == 0 "vmsbf.m retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX e64 m1 vmsbf.m writes a0"
.assert rd_wdata == 0x1 "VLMAX e64 m1 vmsbf.m"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x52412457  # vmsof.m v8, v4
.assert trap == 0 "vmsof.m retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX e64 m1 vmsof.m writes a0"
.assert rd_wdata == 0x2 "VLMAX e64 m1 vmsof.m"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5241a457  # vmsif.m v8, v4
.assert trap == 0 "vmsif.m retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "VLMAX e64 m1 vmsif.m writes a0"
.assert rd_wdata == 0x3 "VLMAX e64 m1 vmsif.m"

# Section 5: viota.m and vid.v across e8, e16, e32, e64 (unmasked, masked mu, tu/ta, vl=0, VLMAX, LMULs).
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0036d7  # vmv.v.i v13, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x02d00313  # addi t1, zero, 45
.4byte 0x420366d7  # vmv.s.x v13, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x03600313  # addi t1, zero, 54
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc003f657  # vsetivli a2, 7, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0037657  # vsetivli a2, 6, e8, m1, tu, mu
.4byte 0x52d82457  # viota.m v8, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 viota.m unmasked lane 0 writes a0"
.assert rd_wdata == 0x0 "e8 viota.m unmasked lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m unmasked lane 1 writes a0"
.assert rd_wdata == 0x1 "e8 viota.m unmasked lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m unmasked lane 2 writes a0"
.assert rd_wdata == 0x1 "e8 viota.m unmasked lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m unmasked lane 3 writes a0"
.assert rd_wdata == 0x2 "e8 viota.m unmasked lane 3"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m unmasked lane 4 writes a0"
.assert rd_wdata == 0x3 "e8 viota.m unmasked lane 4"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m unmasked lane 5 writes a0"
.assert rd_wdata == 0x3 "e8 viota.m unmasked lane 5"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m unmasked lane 6 writes a0"
.assert rd_wdata == 0x5a "e8 viota.m unmasked lane 6"
.4byte 0xc003f657  # vsetivli a2, 7, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0037657  # vsetivli a2, 6, e8, m1, tu, mu
.4byte 0x50d82457  # viota.m v8, v13, v0.t
.assert trap == 0 "viota.m retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 viota.m masked lane 0 writes a0"
.assert rd_wdata == 0x5a "e8 viota.m masked lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m masked lane 1 writes a0"
.assert rd_wdata == 0x0 "e8 viota.m masked lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m masked lane 2 writes a0"
.assert rd_wdata == 0x0 "e8 viota.m masked lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m masked lane 3 writes a0"
.assert rd_wdata == 0x5a "e8 viota.m masked lane 3"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m masked lane 4 writes a0"
.assert rd_wdata == 0x1 "e8 viota.m masked lane 4"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m masked lane 5 writes a0"
.assert rd_wdata == 0x1 "e8 viota.m masked lane 5"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 viota.m masked lane 6 writes a0"
.assert rd_wdata == 0x5a "e8 viota.m masked lane 6"
.4byte 0xc003f657  # vsetivli a2, 7, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0037657  # vsetivli a2, 6, e8, m1, tu, mu
.4byte 0x5208a457  # vid.v v8
.assert trap == 0 "vid.v retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vid.v unmasked lane 0 writes a0"
.assert rd_wdata == 0x0 "e8 vid.v unmasked lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v unmasked lane 1 writes a0"
.assert rd_wdata == 0x1 "e8 vid.v unmasked lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v unmasked lane 2 writes a0"
.assert rd_wdata == 0x2 "e8 vid.v unmasked lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v unmasked lane 3 writes a0"
.assert rd_wdata == 0x3 "e8 vid.v unmasked lane 3"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v unmasked lane 4 writes a0"
.assert rd_wdata == 0x4 "e8 vid.v unmasked lane 4"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v unmasked lane 5 writes a0"
.assert rd_wdata == 0x5 "e8 vid.v unmasked lane 5"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v unmasked lane 6 writes a0"
.assert rd_wdata == 0x5a "e8 vid.v unmasked lane 6"
.4byte 0xc003f657  # vsetivli a2, 7, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0037657  # vsetivli a2, 6, e8, m1, tu, mu
.4byte 0x5008a457  # vid.v v8, v0.t
.assert trap == 0 "vid.v retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 vid.v masked lane 0 writes a0"
.assert rd_wdata == 0x5a "e8 vid.v masked lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v masked lane 1 writes a0"
.assert rd_wdata == 0x1 "e8 vid.v masked lane 1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v masked lane 2 writes a0"
.assert rd_wdata == 0x2 "e8 vid.v masked lane 2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v masked lane 3 writes a0"
.assert rd_wdata == 0x5a "e8 vid.v masked lane 3"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v masked lane 4 writes a0"
.assert rd_wdata == 0x4 "e8 vid.v masked lane 4"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v masked lane 5 writes a0"
.assert rd_wdata == 0x5 "e8 vid.v masked lane 5"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 vid.v masked lane 6 writes a0"
.assert rd_wdata == 0x5a "e8 vid.v masked lane 6"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0036d7  # vmv.v.i v13, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x02d00313  # addi t1, zero, 45
.4byte 0x420366d7  # vmv.s.x v13, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x03600313  # addi t1, zero, 54
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc083f657  # vsetivli a2, 7, e16, m1, tu, mu
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0837657  # vsetivli a2, 6, e16, m1, tu, mu
.4byte 0x52d82457  # viota.m v8, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 viota.m unmasked lane 0 writes a0"
.assert rd_wdata == 0x0 "e16 viota.m unmasked lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m unmasked lane 1 writes a0"
.assert rd_wdata == 0x1 "e16 viota.m unmasked lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m unmasked lane 2 writes a0"
.assert rd_wdata == 0x1 "e16 viota.m unmasked lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m unmasked lane 3 writes a0"
.assert rd_wdata == 0x2 "e16 viota.m unmasked lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m unmasked lane 4 writes a0"
.assert rd_wdata == 0x3 "e16 viota.m unmasked lane 4"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m unmasked lane 5 writes a0"
.assert rd_wdata == 0x3 "e16 viota.m unmasked lane 5"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m unmasked lane 6 writes a0"
.assert rd_wdata == 0x5a5a "e16 viota.m unmasked lane 6"
.4byte 0xc083f657  # vsetivli a2, 7, e16, m1, tu, mu
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0837657  # vsetivli a2, 6, e16, m1, tu, mu
.4byte 0x50d82457  # viota.m v8, v13, v0.t
.assert trap == 0 "viota.m retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 viota.m masked lane 0 writes a0"
.assert rd_wdata == 0x5a5a "e16 viota.m masked lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m masked lane 1 writes a0"
.assert rd_wdata == 0x0 "e16 viota.m masked lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m masked lane 2 writes a0"
.assert rd_wdata == 0x0 "e16 viota.m masked lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m masked lane 3 writes a0"
.assert rd_wdata == 0x5a5a "e16 viota.m masked lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m masked lane 4 writes a0"
.assert rd_wdata == 0x1 "e16 viota.m masked lane 4"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m masked lane 5 writes a0"
.assert rd_wdata == 0x1 "e16 viota.m masked lane 5"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 viota.m masked lane 6 writes a0"
.assert rd_wdata == 0x5a5a "e16 viota.m masked lane 6"
.4byte 0xc083f657  # vsetivli a2, 7, e16, m1, tu, mu
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0837657  # vsetivli a2, 6, e16, m1, tu, mu
.4byte 0x5208a457  # vid.v v8
.assert trap == 0 "vid.v retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vid.v unmasked lane 0 writes a0"
.assert rd_wdata == 0x0 "e16 vid.v unmasked lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v unmasked lane 1 writes a0"
.assert rd_wdata == 0x1 "e16 vid.v unmasked lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v unmasked lane 2 writes a0"
.assert rd_wdata == 0x2 "e16 vid.v unmasked lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v unmasked lane 3 writes a0"
.assert rd_wdata == 0x3 "e16 vid.v unmasked lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v unmasked lane 4 writes a0"
.assert rd_wdata == 0x4 "e16 vid.v unmasked lane 4"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v unmasked lane 5 writes a0"
.assert rd_wdata == 0x5 "e16 vid.v unmasked lane 5"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v unmasked lane 6 writes a0"
.assert rd_wdata == 0x5a5a "e16 vid.v unmasked lane 6"
.4byte 0xc083f657  # vsetivli a2, 7, e16, m1, tu, mu
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0837657  # vsetivli a2, 6, e16, m1, tu, mu
.4byte 0x5008a457  # vid.v v8, v0.t
.assert trap == 0 "vid.v retires"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e16 vid.v masked lane 0 writes a0"
.assert rd_wdata == 0x5a5a "e16 vid.v masked lane 0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v masked lane 1 writes a0"
.assert rd_wdata == 0x1 "e16 vid.v masked lane 1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v masked lane 2 writes a0"
.assert rd_wdata == 0x2 "e16 vid.v masked lane 2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v masked lane 3 writes a0"
.assert rd_wdata == 0x5a5a "e16 vid.v masked lane 3"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v masked lane 4 writes a0"
.assert rd_wdata == 0x4 "e16 vid.v masked lane 4"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v masked lane 5 writes a0"
.assert rd_wdata == 0x5 "e16 vid.v masked lane 5"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e16 vid.v masked lane 6 writes a0"
.assert rd_wdata == 0x5a5a "e16 vid.v masked lane 6"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0036d7  # vmv.v.i v13, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x02d00313  # addi t1, zero, 45
.4byte 0x420366d7  # vmv.s.x v13, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x03600313  # addi t1, zero, 54
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc113f657  # vsetivli a2, 7, e32, m2, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x52d82457  # viota.m v8, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 viota.m unmasked lane 0 writes a0"
.assert rd_wdata == 0x0 "e32 viota.m unmasked lane 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m unmasked lane 1 writes a0"
.assert rd_wdata == 0x1 "e32 viota.m unmasked lane 1"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m unmasked lane 2 writes a0"
.assert rd_wdata == 0x1 "e32 viota.m unmasked lane 2"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m unmasked lane 3 writes a0"
.assert rd_wdata == 0x2 "e32 viota.m unmasked lane 3"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m unmasked lane 4 writes a0"
.assert rd_wdata == 0x3 "e32 viota.m unmasked lane 4"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m unmasked lane 5 writes a0"
.assert rd_wdata == 0x3 "e32 viota.m unmasked lane 5"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m unmasked lane 6 writes a0"
.assert rd_wdata == 0x5a5a5a5a "e32 viota.m unmasked lane 6"
.4byte 0xc113f657  # vsetivli a2, 7, e32, m2, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x50d82457  # viota.m v8, v13, v0.t
.assert trap == 0 "viota.m retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 viota.m masked lane 0 writes a0"
.assert rd_wdata == 0x5a5a5a5a "e32 viota.m masked lane 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m masked lane 1 writes a0"
.assert rd_wdata == 0x0 "e32 viota.m masked lane 1"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m masked lane 2 writes a0"
.assert rd_wdata == 0x0 "e32 viota.m masked lane 2"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m masked lane 3 writes a0"
.assert rd_wdata == 0x5a5a5a5a "e32 viota.m masked lane 3"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m masked lane 4 writes a0"
.assert rd_wdata == 0x1 "e32 viota.m masked lane 4"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m masked lane 5 writes a0"
.assert rd_wdata == 0x1 "e32 viota.m masked lane 5"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 viota.m masked lane 6 writes a0"
.assert rd_wdata == 0x5a5a5a5a "e32 viota.m masked lane 6"
.4byte 0xc113f657  # vsetivli a2, 7, e32, m2, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5208a457  # vid.v v8
.assert trap == 0 "vid.v retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vid.v unmasked lane 0 writes a0"
.assert rd_wdata == 0x0 "e32 vid.v unmasked lane 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v unmasked lane 1 writes a0"
.assert rd_wdata == 0x1 "e32 vid.v unmasked lane 1"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v unmasked lane 2 writes a0"
.assert rd_wdata == 0x2 "e32 vid.v unmasked lane 2"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v unmasked lane 3 writes a0"
.assert rd_wdata == 0x3 "e32 vid.v unmasked lane 3"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v unmasked lane 4 writes a0"
.assert rd_wdata == 0x4 "e32 vid.v unmasked lane 4"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v unmasked lane 5 writes a0"
.assert rd_wdata == 0x5 "e32 vid.v unmasked lane 5"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v unmasked lane 6 writes a0"
.assert rd_wdata == 0x5a5a5a5a "e32 vid.v unmasked lane 6"
.4byte 0xc113f657  # vsetivli a2, 7, e32, m2, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1137657  # vsetivli a2, 6, e32, m2, tu, mu
.4byte 0x5008a457  # vid.v v8, v0.t
.assert trap == 0 "vid.v retires"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e32 vid.v masked lane 0 writes a0"
.assert rd_wdata == 0x5a5a5a5a "e32 vid.v masked lane 0"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v masked lane 1 writes a0"
.assert rd_wdata == 0x1 "e32 vid.v masked lane 1"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v masked lane 2 writes a0"
.assert rd_wdata == 0x2 "e32 vid.v masked lane 2"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v masked lane 3 writes a0"
.assert rd_wdata == 0x5a5a5a5a "e32 vid.v masked lane 3"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v masked lane 4 writes a0"
.assert rd_wdata == 0x4 "e32 vid.v masked lane 4"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v masked lane 5 writes a0"
.assert rd_wdata == 0x5 "e32 vid.v masked lane 5"
.4byte 0xc110f657  # vsetivli a2, 1, e32, m2, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e32 vid.v masked lane 6 writes a0"
.assert rd_wdata == 0x5a5a5a5a "e32 vid.v masked lane 6"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0036d7  # vmv.v.i v13, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x02d00313  # addi t1, zero, 45
.4byte 0x420366d7  # vmv.s.x v13, t1
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x03600313  # addi t1, zero, 54
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc1a3f657  # vsetivli a2, 7, e64, m4, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5a5a6fb7  # lui t6, 0x5a5a6
.4byte 0xa5af8f93  # addi t6, t6, -1446
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1a37657  # vsetivli a2, 6, e64, m4, tu, mu
.4byte 0x52d82457  # viota.m v8, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 viota.m unmasked lane 0 writes a0"
.assert rd_wdata == 0x0 "e64 viota.m unmasked lane 0"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m unmasked lane 1 writes a0"
.assert rd_wdata == 0x1 "e64 viota.m unmasked lane 1"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m unmasked lane 2 writes a0"
.assert rd_wdata == 0x1 "e64 viota.m unmasked lane 2"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m unmasked lane 3 writes a0"
.assert rd_wdata == 0x2 "e64 viota.m unmasked lane 3"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m unmasked lane 4 writes a0"
.assert rd_wdata == 0x3 "e64 viota.m unmasked lane 4"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m unmasked lane 5 writes a0"
.assert rd_wdata == 0x3 "e64 viota.m unmasked lane 5"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m unmasked lane 6 writes a0"
.assert rd_wdata == 0x5a5a5a5a5a5a5a5a "e64 viota.m unmasked lane 6"
.4byte 0xc1a3f657  # vsetivli a2, 7, e64, m4, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5a5a6fb7  # lui t6, 0x5a5a6
.4byte 0xa5af8f93  # addi t6, t6, -1446
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1a37657  # vsetivli a2, 6, e64, m4, tu, mu
.4byte 0x50d82457  # viota.m v8, v13, v0.t
.assert trap == 0 "viota.m retires"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 viota.m masked lane 0 writes a0"
.assert rd_wdata == 0x5a5a5a5a5a5a5a5a "e64 viota.m masked lane 0"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m masked lane 1 writes a0"
.assert rd_wdata == 0x0 "e64 viota.m masked lane 1"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m masked lane 2 writes a0"
.assert rd_wdata == 0x0 "e64 viota.m masked lane 2"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m masked lane 3 writes a0"
.assert rd_wdata == 0x5a5a5a5a5a5a5a5a "e64 viota.m masked lane 3"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m masked lane 4 writes a0"
.assert rd_wdata == 0x1 "e64 viota.m masked lane 4"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m masked lane 5 writes a0"
.assert rd_wdata == 0x1 "e64 viota.m masked lane 5"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 viota.m masked lane 6 writes a0"
.assert rd_wdata == 0x5a5a5a5a5a5a5a5a "e64 viota.m masked lane 6"
.4byte 0xc1a3f657  # vsetivli a2, 7, e64, m4, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5a5a6fb7  # lui t6, 0x5a5a6
.4byte 0xa5af8f93  # addi t6, t6, -1446
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1a37657  # vsetivli a2, 6, e64, m4, tu, mu
.4byte 0x5208a457  # vid.v v8
.assert trap == 0 "vid.v retires"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vid.v unmasked lane 0 writes a0"
.assert rd_wdata == 0x0 "e64 vid.v unmasked lane 0"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v unmasked lane 1 writes a0"
.assert rd_wdata == 0x1 "e64 vid.v unmasked lane 1"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v unmasked lane 2 writes a0"
.assert rd_wdata == 0x2 "e64 vid.v unmasked lane 2"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v unmasked lane 3 writes a0"
.assert rd_wdata == 0x3 "e64 vid.v unmasked lane 3"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v unmasked lane 4 writes a0"
.assert rd_wdata == 0x4 "e64 vid.v unmasked lane 4"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v unmasked lane 5 writes a0"
.assert rd_wdata == 0x5 "e64 vid.v unmasked lane 5"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v unmasked lane 6 writes a0"
.assert rd_wdata == 0x5a5a5a5a5a5a5a5a "e64 vid.v unmasked lane 6"
.4byte 0xc1a3f657  # vsetivli a2, 7, e64, m4, tu, mu
.4byte 0x5a5a6337  # lui t1, 0x5a5a6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5a5a6fb7  # lui t6, 0x5a5a6
.4byte 0xa5af8f93  # addi t6, t6, -1446
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1a37657  # vsetivli a2, 6, e64, m4, tu, mu
.4byte 0x5008a457  # vid.v v8, v0.t
.assert trap == 0 "vid.v retires"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e64 vid.v masked lane 0 writes a0"
.assert rd_wdata == 0x5a5a5a5a5a5a5a5a "e64 vid.v masked lane 0"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e80b857  # vslidedown.vi v16, v8, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v masked lane 1 writes a0"
.assert rd_wdata == 0x1 "e64 vid.v masked lane 1"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v masked lane 2 writes a0"
.assert rd_wdata == 0x2 "e64 vid.v masked lane 2"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v masked lane 3 writes a0"
.assert rd_wdata == 0x5a5a5a5a5a5a5a5a "e64 vid.v masked lane 3"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e823857  # vslidedown.vi v16, v8, 4
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v masked lane 4 writes a0"
.assert rd_wdata == 0x4 "e64 vid.v masked lane 4"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e82b857  # vslidedown.vi v16, v8, 5
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v masked lane 5 writes a0"
.assert rd_wdata == 0x5 "e64 vid.v masked lane 5"
.4byte 0xc1a0f657  # vsetivli a2, 1, e64, m4, tu, mu
.4byte 0x3e833857  # vslidedown.vi v16, v8, 6
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e64 vid.v masked lane 6 writes a0"
.assert rd_wdata == 0x5a5a5a5a5a5a5a5a "e64 vid.v masked lane 6"
# Multi-register e8, m2, vl=20 on viota.m and vid.v + legal overlaps + LMULs + vl=0 + VLMAX.
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0036d7  # vmv.v.i v13, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x000aa337  # lui t1, 0xaa
.4byte 0x55a30313  # addi t1, t1, 1370
.4byte 0x420366d7  # vmv.s.x v13, t1
.4byte 0xcc1a7657  # vsetivli a2, 20, e8, m2, ta, ma
.4byte 0x52d82457  # viota.m v8, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "e8 m2 viota lane 0 writes a0"
.assert rd_wdata == 0x0 "e8 m2 viota lane 0"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e843857  # vslidedown.vi v16, v8, 8
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 m2 viota lane 8 (after byte 0) writes a0"
.assert rd_wdata == 0x4 "e8 m2 viota lane 8 (after byte 0)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e883857  # vslidedown.vi v16, v8, 16
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 m2 viota lane 16 (reg+1 after byte 1) writes a0"
.assert rd_wdata == 0x8 "e8 m2 viota lane 16 (reg+1 after byte 1)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3e89b857  # vslidedown.vi v16, v8, 19
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 m2 viota lane 19 (bit 17 counted, bit 19 not yet) writes a0"
.assert rd_wdata == 0x9 "e8 m2 viota lane 19 (bit 17 counted, bit 19 not yet)"
.4byte 0xcc1a7657  # vsetivli a2, 20, e8, m2, ta, ma
.4byte 0x5208a557  # vid.v v10
.assert trap == 0 "vid.v retires"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "e8 m2 vid lane 0 writes a0"
.assert rd_wdata == 0x0 "e8 m2 vid lane 0"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3ea7b857  # vslidedown.vi v16, v10, 15
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 m2 vid lane 15 writes a0"
.assert rd_wdata == 0xf "e8 m2 vid lane 15"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3ea83857  # vslidedown.vi v16, v10, 16
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 m2 vid lane 16 (reg+1) writes a0"
.assert rd_wdata == 0x10 "e8 m2 vid lane 16 (reg+1)"
.4byte 0xc010f657  # vsetivli a2, 1, e8, m2, tu, mu
.4byte 0x3ea9b857  # vslidedown.vi v16, v10, 19
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "e8 m2 vid lane 19 writes a0"
.assert rd_wdata == 0x13 "e8 m2 vid lane 19"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0036d7  # vmv.v.i v13, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00d00313  # addi t1, zero, 13
.4byte 0x420366d7  # vmv.s.x v13, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x52d82057  # viota.m v0, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e01b857  # vslidedown.vi v16, v0, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "unmasked legal vd==v0 viota lane 3 writes a0"
.assert rd_wdata == 0x2 "unmasked legal vd==v0 viota lane 3"
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x5208a057  # vid.v v0
.assert trap == 0 "vid.v retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e01b857  # vslidedown.vi v16, v0, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "unmasked legal vd==v0 vid lane 3 writes a0"
.assert rd_wdata == 0x3 "unmasked legal vd==v0 vid lane 3"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00b00313  # addi t1, zero, 11
.4byte 0x42036057  # vmv.s.x v0, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc001f657  # vsetivli a2, 3, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x07700313  # addi t1, zero, 119
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x50082457  # viota.m v8, v0, v0.t
.assert trap == 0 "viota.m retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked legal vs2==v0 viota lane 0 writes a0"
.assert rd_wdata == 0x0 "masked legal vs2==v0 viota lane 0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813857  # vslidedown.vi v16, v8, 2
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked legal vs2==v0 viota lane 2 mu writes a0"
.assert rd_wdata == 0x77 "masked legal vs2==v0 viota lane 2 mu"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81b857  # vslidedown.vi v16, v8, 3
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "masked legal vs2==v0 viota lane 3 writes a0"
.assert rd_wdata == 0x2 "masked legal vs2==v0 viota lane 3"
.4byte 0xc0017657  # vsetivli a2, 2, e8, m1, tu, mu
.4byte 0x06600313  # addi t1, zero, 102
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x06600313  # addi t1, zero, 102
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0007657  # vsetivli a2, 0, e8, m1, tu, mu
.assert rd_addr == 12 "vl=0 viota/vid writes a2"
.assert rd_wdata == 0x0 "vl=0 viota/vid"
.4byte 0x52d82457  # viota.m v8, v13
.assert trap == 0 "viota.m retires"
.4byte 0x5208a457  # vid.v v8
.assert trap == 0 "vid.v retires"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vl=0 leaves viota/vid vd untouched writes a0"
.assert rd_wdata == 0x66 "vl=0 leaves viota/vid vd untouched"
.4byte 0x01807657  # vsetvli a2, zero, e64, m1, tu, mu
.4byte 0x5e0036d7  # vmv.v.i v13, 0
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x00100313  # addi t1, zero, 1
.4byte 0x420366d7  # vmv.s.x v13, t1
.4byte 0x00507657  # vsetvli a2, zero, e8, mf8, tu, mu
.4byte 0x52d82c57  # viota.m v24, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e8 mf8 viota lane 1 writes a0"
.assert rd_wdata == 0x1 "VLMAX e8 mf8 viota lane 1"
.4byte 0x00507657  # vsetvli a2, zero, e8, mf8, tu, mu
.4byte 0x5208ac57  # vid.v v24
.assert trap == 0 "vid.v retires"
.4byte 0xc050f657  # vsetivli a2, 1, e8, mf8, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e8 mf8 vid lane 1 writes a0"
.assert rd_wdata == 0x1 "VLMAX e8 mf8 vid lane 1"
.4byte 0x00e07657  # vsetvli a2, zero, e16, mf4, tu, mu
.4byte 0x52d82c57  # viota.m v24, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc0e0f657  # vsetivli a2, 1, e16, mf4, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e16 mf4 viota lane 1 writes a0"
.assert rd_wdata == 0x1 "VLMAX e16 mf4 viota lane 1"
.4byte 0x00e07657  # vsetvli a2, zero, e16, mf4, tu, mu
.4byte 0x5208ac57  # vid.v v24
.assert trap == 0 "vid.v retires"
.4byte 0xc0e0f657  # vsetivli a2, 1, e16, mf4, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e16 mf4 vid lane 1 writes a0"
.assert rd_wdata == 0x1 "VLMAX e16 mf4 vid lane 1"
.4byte 0x01707657  # vsetvli a2, zero, e32, mf2, tu, mu
.4byte 0x52d82c57  # viota.m v24, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e32 mf2 viota lane 1 writes a0"
.assert rd_wdata == 0x1 "VLMAX e32 mf2 viota lane 1"
.4byte 0x01707657  # vsetvli a2, zero, e32, mf2, tu, mu
.4byte 0x5208ac57  # vid.v v24
.assert trap == 0 "vid.v retires"
.4byte 0xc170f657  # vsetivli a2, 1, e32, mf2, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e32 mf2 vid lane 1 writes a0"
.assert rd_wdata == 0x1 "VLMAX e32 mf2 vid lane 1"
.4byte 0x01b07657  # vsetvli a2, zero, e64, m8, tu, mu
.4byte 0x52d82c57  # viota.m v24, v13
.assert trap == 0 "viota.m retires"
.4byte 0xc1b0f657  # vsetivli a2, 1, e64, m8, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e64 m8 viota lane 1 writes a0"
.assert rd_wdata == 0x1 "VLMAX e64 m8 viota lane 1"
.4byte 0x01b07657  # vsetvli a2, zero, e64, m8, tu, mu
.4byte 0x5208ac57  # vid.v v24
.assert trap == 0 "vid.v retires"
.4byte 0xc1b0f657  # vsetivli a2, 1, e64, m8, tu, mu
.4byte 0x3f80b857  # vslidedown.vi v16, v24, 1
.4byte 0x43002557  # vmv.x.s a0, v16
.assert rd_addr == 10 "VLMAX e64 m8 vid lane 1 writes a0"
.assert rd_wdata == 0x1 "VLMAX e64 m8 vid lane 1"

# Section 6: Illegal-instruction traps (mcause == 2, mtval == insn, destination untouched).
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
.4byte 0x64432457  # .4byte vmand.mm reserved vm=0
.assert trap == 1 "vmand.mm vm=0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmand.mm vm=0 mcause writes a0"
.assert rd_wdata == 0x2 "vmand.mm vm=0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmand.mm vm=0 mtval writes a0"
.assert rd_wdata == 0x64432457 "vmand.mm vm=0 mtval matches instruction"
.4byte 0x6c432457  # .4byte vmxor.mm reserved vm=0
.assert trap == 1 "vmxor.mm vm=0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmxor.mm vm=0 mcause writes a0"
.assert rd_wdata == 0x2 "vmxor.mm vm=0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmxor.mm vm=0 mtval writes a0"
.assert rd_wdata == 0x6c432457 "vmxor.mm vm=0 mtval matches instruction"
.4byte 0x5280a457  # vmsbf.m v8, v8
.assert trap == 1 "vmsbf vd==vs2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmsbf vd==vs2 mcause writes a0"
.assert rd_wdata == 0x2 "vmsbf vd==vs2 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmsbf vd==vs2 mtval writes a0"
.assert rd_wdata == 0x5280a457 "vmsbf vd==vs2 mtval matches instruction"
.4byte 0x52812457  # vmsof.m v8, v8
.assert trap == 1 "vmsof vd==vs2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmsof vd==vs2 mcause writes a0"
.assert rd_wdata == 0x2 "vmsof vd==vs2 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmsof vd==vs2 mtval writes a0"
.assert rd_wdata == 0x52812457 "vmsof vd==vs2 mtval matches instruction"
.4byte 0x5081a457  # vmsif.m v8, v8, v0.t
.assert trap == 1 "vmsif masked vd==vs2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmsif masked vd==vs2 mcause writes a0"
.assert rd_wdata == 0x2 "vmsif masked vd==vs2 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmsif masked vd==vs2 mtval writes a0"
.assert rd_wdata == 0x5081a457 "vmsif masked vd==vs2 mtval matches instruction"
.4byte 0x5040a057  # vmsbf.m v0, v4, v0.t
.assert trap == 1 "vmsbf masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmsbf masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmsbf masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmsbf masked vd==v0 mtval writes a0"
.assert rd_wdata == 0x5040a057 "vmsbf masked vd==v0 mtval matches instruction"
.4byte 0x50412057  # vmsof.m v0, v4, v0.t
.assert trap == 1 "vmsof masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmsof masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmsof masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmsof masked vd==v0 mtval writes a0"
.assert rd_wdata == 0x50412057 "vmsof masked vd==v0 mtval matches instruction"
.4byte 0x5041a057  # vmsif.m v0, v4, v0.t
.assert trap == 1 "vmsif masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmsif masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vmsif masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmsif masked vd==v0 mtval writes a0"
.assert rd_wdata == 0x5041a057 "vmsif masked vd==v0 mtval matches instruction"
.4byte 0x52882457  # viota.m v8, v8
.assert trap == 1 "viota vd==vs2 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "viota vd==vs2 mcause writes a0"
.assert rd_wdata == 0x2 "viota vd==vs2 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "viota vd==vs2 mtval writes a0"
.assert rd_wdata == 0x52882457 "viota vd==vs2 mtval matches instruction"
.4byte 0x50482057  # viota.m v0, v4, v0.t
.assert trap == 1 "viota masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "viota masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "viota masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "viota masked vd==v0 mtval writes a0"
.assert rd_wdata == 0x50482057 "viota masked vd==v0 mtval matches instruction"
.4byte 0x5008a057  # vid.v v0, v0.t
.assert trap == 1 "vid masked vd==v0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vid masked vd==v0 mcause writes a0"
.assert rd_wdata == 0x2 "vid masked vd==v0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vid masked vd==v0 mtval writes a0"
.assert rd_wdata == 0x5008a057 "vid masked vd==v0 mtval matches instruction"
.4byte 0x5248a457  # .4byte vid.v reserved vs2!=0
.assert trap == 1 "vid vs2!=0 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vid vs2!=0 mcause writes a0"
.assert rd_wdata == 0x2 "vid vs2!=0 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vid vs2!=0 mtval writes a0"
.assert rd_wdata == 0x5248a457 "vid vs2!=0 mtval matches instruction"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "v8 sentinel untouched after traps 1-12 writes a0"
.assert rd_wdata == 0x42 "v8 sentinel untouched after traps 1-12"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42002557  # vmv.x.s a0, v0
.assert rd_addr == 10 "v0 sentinel untouched after traps 1-12 writes a0"
.assert rd_wdata == 0x33 "v0 sentinel untouched after traps 1-12"
.4byte 0xc1127657  # vsetivli a2, 4, e32, m2, tu, mu
.4byte 0x52d824d7  # viota.m v9, v13
.assert trap == 1 "viota m2 misaligned vd traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "viota m2 misaligned vd mcause writes a0"
.assert rd_wdata == 0x2 "viota m2 misaligned vd illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "viota m2 misaligned vd mtval writes a0"
.assert rd_wdata == 0x52d824d7 "viota m2 misaligned vd mtval matches instruction"
.4byte 0x5208a4d7  # vid.v v9
.assert trap == 1 "vid m2 misaligned vd traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vid m2 misaligned vd mcause writes a0"
.assert rd_wdata == 0x2 "vid m2 misaligned vd illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vid m2 misaligned vd mtval writes a0"
.assert rd_wdata == 0x5208a4d7 "vid m2 misaligned vd mtval matches instruction"
.4byte 0xc200f657  # vsetivli a2, 1, 0x20 (sets vill=1)
.assert rd_addr == 12 "vill vsetivli writes a2"
.assert rd_wdata == 0x0 "vill vsetivli sets vl=0"
.4byte 0x66432457  # vmand.mm v8, v4, v6
.assert trap == 1 "vmand under vill=1 traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vmand under vill=1 mcause writes a0"
.assert rd_wdata == 0x2 "vmand under vill=1 illegal-instruction cause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vmand under vill=1 mtval writes a0"
.assert rd_wdata == 0x66432457 "vmand under vill=1 mtval matches instruction"
