.noshrink
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x40008437  # lui s0, 0x40008
.4byte 0x00141413  # slli s0, s0, 1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.assert rd_wdata == 0x2 "two active lanes"
.4byte 0x00700313  # addi t1, zero, 7
.4byte 0x00500393  # addi t2, zero, 5
.4byte 0x00642023  # sw t1, 0(s0)
.4byte 0x00742223  # sw t2, 4(s0)
.4byte 0x02046407  # vle32.v v8, (s0)
.assert trap == 0 "the legal load retires"
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_wdata == 0x7 "load reads element zero"
.4byte 0x3e80b4d7  # vslidedown.vi v9, v8, 1
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_wdata == 0x5 "load reads element one"
