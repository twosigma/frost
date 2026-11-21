.noshrink
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x40008437  # lui s0, 0x40008
.4byte 0x00141413  # slli s0, s0, 1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_wdata == 0x2 "two active lanes"
.4byte 0x00700313  # addi t1, zero, 7
.4byte 0x00500393  # addi t2, zero, 5
.4byte 0x5e03c457  # vmv.v.x v8, t2
.4byte 0x42036457  # vmv.s.x v8, t1
.4byte 0x02046427  # vse32.v v8, (s0)
.assert trap == 0 "the legal store retires"
.4byte 0x00046503  # lwu a0, 0(s0)
.assert rd_wdata == 0x7 "store writes element zero"
.4byte 0x00446503  # lwu a0, 4(s0)
.assert rd_wdata == 0x5 "store writes element one"
