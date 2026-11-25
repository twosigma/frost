# Nonzero-vstart resumption across strided, indexed, segment and fault-only-first loads and stores.
.noshrink
# Enable mstatus.VS, zero v0..v31, set cached DDR bases.
.4byte 0x60000293  # addi t0, zero, 0x600
.4byte 0x3002a073  # csrs mstatus, t0
.4byte 0x40008437  # lui s0, 0x40008
.4byte 0x00141413  # slli s0, s0, 1
.4byte 0x40040493  # addi s1, s0, 1024
.4byte 0x60000937  # lui s2, 0x60000
.4byte 0x00191913  # slli s2, s2, 1
.4byte 0x003072d7  # vsetvli t0, zero, e8, m8, tu, mu
.4byte 0x5e003057  # vmv.v.i v0, 0
.4byte 0x5e003457  # vmv.v.i v8, 0
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x5e003c57  # vmv.v.i v24, 0
# Populate 128 seeded bytes at s0 (0x80010000).
.4byte 0x4563c337  # lui t1, 0x4563c
.4byte 0xf5230313  # addi t1, t1, -174
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x1edfbfb7  # lui t6, 0x1edfb
.4byte 0x0ccf8f93  # addi t6, t6, 204
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643023  # sd t1, 0(s0)
.4byte 0x9fee1337  # lui t1, 0x9fee1
.4byte 0xb2130313  # addi t1, t1, -1247
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa5d52fb7  # lui t6, 0xa5d52
.4byte 0x83ff8f93  # addi t6, t6, -1985
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643423  # sd t1, 8(s0)
.4byte 0x0ff32337  # lui t1, 0xff32
.4byte 0x4dd30313  # addi t1, t1, 1245
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x114ccfb7  # lui t6, 0x114cc
.4byte 0x2f5f8f93  # addi t6, t6, 757
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643823  # sd t1, 16(s0)
.4byte 0x4ef25337  # lui t1, 0x4ef25
.4byte 0x3ec30313  # addi t1, t1, 1004
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xc975afb7  # lui t6, 0xc975a
.4byte 0x7e8f8f93  # addi t6, t6, 2024
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x00643c23  # sd t1, 24(s0)
.4byte 0x2ba66337  # lui t1, 0x2ba66
.4byte 0xecd30313  # addi t1, t1, -307
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa4f02fb7  # lui t6, 0xa4f02
.4byte 0xf5df8f93  # addi t6, t6, -163
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643023  # sd t1, 32(s0)
.4byte 0x7fa9e337  # lui t1, 0x7fa9e
.4byte 0x53230313  # addi t1, t1, 1330
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xd66fbfb7  # lui t6, 0xd66fb
.4byte 0xb04f8f93  # addi t6, t6, -1276
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643423  # sd t1, 40(s0)
.4byte 0x7a8c2337  # lui t1, 0x7a8c2
.4byte 0x63e30313  # addi t1, t1, 1598
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x17225fb7  # lui t6, 0x17225
.4byte 0xb2af8f93  # addi t6, t6, -1238
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643823  # sd t1, 48(s0)
.4byte 0x5ffb2337  # lui t1, 0x5ffb2
.4byte 0x37730313  # addi t1, t1, 887
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xe97dafb7  # lui t6, 0xe97da
.4byte 0x148f8f93  # addi t6, t6, 328
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x02643c23  # sd t1, 56(s0)
.4byte 0x0dc88337  # lui t1, 0xdc88
.4byte 0x7ad30313  # addi t1, t1, 1965
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x5857bfb7  # lui t6, 0x5857b
.4byte 0x7dbf8f93  # addi t6, t6, 2011
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x04643023  # sd t1, 64(s0)
.4byte 0x8df14337  # lui t1, 0x8df14
.4byte 0x6ac30313  # addi t1, t1, 1708
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xdef62fb7  # lui t6, 0xdef62
.4byte 0x990f8f93  # addi t6, t6, -1648
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x04643423  # sd t1, 72(s0)
.4byte 0xb3673337  # lui t1, 0xb3673
.4byte 0x7fa30313  # addi t1, t1, 2042
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xcae0afb7  # lui t6, 0xcae0a
.4byte 0xed1f8f93  # addi t6, t6, -303
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x04643823  # sd t1, 80(s0)
.4byte 0x89289337  # lui t1, 0x89289
.4byte 0xf3630313  # addi t1, t1, -202
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xae938fb7  # lui t6, 0xae938
.4byte 0x29cf8f93  # addi t6, t6, 668
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x04643c23  # sd t1, 88(s0)
.4byte 0xf9d8e337  # lui t1, 0xf9d8e
.4byte 0x6e430313  # addi t1, t1, 1764
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x02640fb7  # lui t6, 0x2640
.4byte 0x6bef8f93  # addi t6, t6, 1726
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x06643023  # sd t1, 96(s0)
.4byte 0x3cd3c337  # lui t1, 0x3cd3c
.4byte 0xa8530313  # addi t1, t1, -1403
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xb90a8fb7  # lui t6, 0xb90a8
.4byte 0x1c6f8f93  # addi t6, t6, 454
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x06643423  # sd t1, 104(s0)
.4byte 0x559af337  # lui t1, 0x559af
.4byte 0xd4930313  # addi t1, t1, -695
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x0cb83fb7  # lui t6, 0xcb83
.4byte 0xddcf8f93  # addi t6, t6, -548
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x06643823  # sd t1, 112(s0)
.4byte 0x704b0337  # lui t1, 0x704b0
.4byte 0xef730313  # addi t1, t1, -265
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x8b14afb7  # lui t6, 0x8b14a
.4byte 0x339f8f93  # addi t6, t6, 825
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x06643c23  # sd t1, 120(s0)
.4byte 0xfc090993  # addi s3, s2, -64
# Populate 64 seeded bytes at s3=0xbfffffc0 below DDR limit.
.4byte 0x4563c337  # lui t1, 0x4563c
.4byte 0xf5230313  # addi t1, t1, -174
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x1edfbfb7  # lui t6, 0x1edfb
.4byte 0x0ccf8f93  # addi t6, t6, 204
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b023  # sd t1, 0(s3)
.4byte 0x9fee1337  # lui t1, 0x9fee1
.4byte 0xb2130313  # addi t1, t1, -1247
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa5d52fb7  # lui t6, 0xa5d52
.4byte 0x83ff8f93  # addi t6, t6, -1985
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b423  # sd t1, 8(s3)
.4byte 0x0ff32337  # lui t1, 0xff32
.4byte 0x4dd30313  # addi t1, t1, 1245
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x114ccfb7  # lui t6, 0x114cc
.4byte 0x2f5f8f93  # addi t6, t6, 757
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069b823  # sd t1, 16(s3)
.4byte 0x4ef25337  # lui t1, 0x4ef25
.4byte 0x3ec30313  # addi t1, t1, 1004
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xc975afb7  # lui t6, 0xc975a
.4byte 0x7e8f8f93  # addi t6, t6, 2024
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0069bc23  # sd t1, 24(s3)
.4byte 0x2ba66337  # lui t1, 0x2ba66
.4byte 0xecd30313  # addi t1, t1, -307
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xa4f02fb7  # lui t6, 0xa4f02
.4byte 0xf5df8f93  # addi t6, t6, -163
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0269b023  # sd t1, 32(s3)
.4byte 0x7fa9e337  # lui t1, 0x7fa9e
.4byte 0x53230313  # addi t1, t1, 1330
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xd66fbfb7  # lui t6, 0xd66fb
.4byte 0xb04f8f93  # addi t6, t6, -1276
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0269b423  # sd t1, 40(s3)
.4byte 0x7a8c2337  # lui t1, 0x7a8c2
.4byte 0x63e30313  # addi t1, t1, 1598
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x17225fb7  # lui t6, 0x17225
.4byte 0xb2af8f93  # addi t6, t6, -1238
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0269b823  # sd t1, 48(s3)
.4byte 0x5ffb2337  # lui t1, 0x5ffb2
.4byte 0x37730313  # addi t1, t1, 887
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0xe97dafb7  # lui t6, 0xe97da
.4byte 0x148f8f93  # addi t6, t6, 328
.4byte 0x020f9f93  # slli t6, t6, 32
.4byte 0x020fdf93  # srli t6, t6, 32
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0269bc23  # sd t1, 56(s3)

# 1. Strided loads and stores resumed from nonzero vstart (e8/e16/e32/e64).
.4byte 0x000072d7  # vsetvli t0, zero, e8, m1, tu, mu
.4byte 0x05a00313  # addi t1, zero, 90
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x00300393  # addi t2, zero, 3
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x0a740407  # vlse8.v v8, (s0), t2 [vstart=2]
.assert trap == 0 "vlse8 vstart=2 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlse8 clears vstart writes a0"
.assert rd_wdata == 0x0 "vlse8 clears vstart"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlse8 vs=2 l0 writes a0"
.assert rd_wdata == 0x5a "vlse8 vs=2 l0"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse8 vs=2 l1 writes a0"
.assert rd_wdata == 0x5a "vlse8 vs=2 l1"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse8 vs=2 l2 writes a0"
.assert rd_wdata == 0x63 "vlse8 vs=2 l2"
.4byte 0xc000f657  # vsetivli a2, 1, e8, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse8 vs=2 l3 writes a0"
.assert rd_wdata == 0x18 "vlse8 vs=2 l3"
.4byte 0x05b00313  # addi t1, zero, 91
.4byte 0x00648023  # sb t1, 0(s1)
.4byte 0x05800313  # addi t1, zero, 88
.4byte 0x006481a3  # sb t1, 3(s1)
.4byte 0x05900313  # addi t1, zero, 89
.4byte 0x00648323  # sb t1, 6(s1)
.4byte 0x05e00313  # addi t1, zero, 94
.4byte 0x006484a3  # sb t1, 9(s1)
.4byte 0xc0027657  # vsetivli a2, 4, e8, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x0a748427  # vsse8.v v8, (s1), t2 [vstart=2]
.assert trap == 0 "vsse8 vstart=2 retires"
.4byte 0x0004c503  # lbu a0, 0(s1)
.assert rd_addr == 10 "vsse8 vs=2 l0 writes a0"
.assert rd_wdata == 0x5b "vsse8 vs=2 l0"
.4byte 0x0034c503  # lbu a0, 3(s1)
.assert rd_addr == 10 "vsse8 vs=2 l1 writes a0"
.assert rd_wdata == 0x58 "vsse8 vs=2 l1"
.4byte 0x0064c503  # lbu a0, 6(s1)
.assert rd_addr == 10 "vsse8 vs=2 l2 writes a0"
.assert rd_wdata == 0x63 "vsse8 vs=2 l2"
.4byte 0x0094c503  # lbu a0, 9(s1)
.assert rd_addr == 10 "vsse8 vs=2 l3 writes a0"
.assert rd_wdata == 0x18 "vsse8 vs=2 l3"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vsse8 clears vstart writes a0"
.assert rd_wdata == 0x0 "vsse8 clears vstart"
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x00600393  # addi t2, zero, 6
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x0a745407  # vlse16.v v8, (s0), t2 [vstart=1]
.assert trap == 0 "vlse16 vstart=1 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlse16 clears vstart writes a0"
.assert rd_wdata == 0x0 "vlse16 clears vstart"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlse16 vs=1 l0 writes a0"
.assert rd_wdata == 0x5a5a "vlse16 vs=1 l0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse16 vs=1 l1 writes a0"
.assert rd_wdata == 0x4563 "vlse16 vs=1 l1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse16 vs=1 l2 writes a0"
.assert rd_wdata == 0xb21 "vlse16 vs=1 l2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse16 vs=1 l3 writes a0"
.assert rd_wdata == 0x114c "vlse16 vs=1 l3"
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5b30313  # addi t1, t1, -1445
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5830313  # addi t1, t1, -1448
.4byte 0x00649323  # sh t1, 6(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5930313  # addi t1, t1, -1447
.4byte 0x00649623  # sh t1, 12(s1)
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5e30313  # addi t1, t1, -1442
.4byte 0x00649923  # sh t1, 18(s1)
.4byte 0xc0827657  # vsetivli a2, 4, e16, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x0a74d427  # vsse16.v v8, (s1), t2 [vstart=1]
.assert trap == 0 "vsse16 vstart=1 retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "vsse16 vs=1 l0 writes a0"
.assert rd_wdata == 0x5a5b "vsse16 vs=1 l0"
.4byte 0x0064d503  # lhu a0, 6(s1)
.assert rd_addr == 10 "vsse16 vs=1 l1 writes a0"
.assert rd_wdata == 0x4563 "vsse16 vs=1 l1"
.4byte 0x00c4d503  # lhu a0, 12(s1)
.assert rd_addr == 10 "vsse16 vs=1 l2 writes a0"
.assert rd_wdata == 0xb21 "vsse16 vs=1 l2"
.4byte 0x0124d503  # lhu a0, 18(s1)
.assert rd_addr == 10 "vsse16 vs=1 l3 writes a0"
.assert rd_wdata == 0x114c "vsse16 vs=1 l3"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vsse16 clears vstart writes a0"
.assert rd_wdata == 0x0 "vsse16 clears vstart"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00c00393  # addi t2, zero, 12
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x0a746407  # vlse32.v v8, (s0), t2 [vstart=2]
.assert trap == 0 "vlse32 vstart=2 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlse32 clears vstart writes a0"
.assert rd_wdata == 0x0 "vlse32 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlse32 vs=2 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlse32 vs=2 l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse32 vs=2 l1 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlse32 vs=2 l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse32 vs=2 l2 writes a0"
.assert rd_wdata == 0xffffffffc975a7e8 "vlse32 vs=2 l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse32 vs=2 l3 writes a0"
.assert rd_wdata == 0x2ba65ecd "vlse32 vs=2 l3"
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a430313  # addi t1, t1, 1444
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a730313  # addi t1, t1, 1447
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a630313  # addi t1, t1, 1446
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a130313  # addi t1, t1, 1441
.4byte 0x0264a223  # sw t1, 36(s1)
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x0a74e427  # vsse32.v v8, (s1), t2 [vstart=2]
.assert trap == 0 "vsse32 vstart=2 retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vsse32 vs=2 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a4 "vsse32 vs=2 l0"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "vsse32 vs=2 l1 writes a0"
.assert rd_wdata == 0x5a5aa5a7 "vsse32 vs=2 l1"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "vsse32 vs=2 l2 writes a0"
.assert rd_wdata == 0xc975a7e8 "vsse32 vs=2 l2"
.4byte 0x0244e503  # lwu a0, 36(s1)
.assert rd_addr == 10 "vsse32 vs=2 l3 writes a0"
.assert rd_wdata == 0x2ba65ecd "vsse32 vs=2 l3"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vsse32 clears vstart writes a0"
.assert rd_wdata == 0x0 "vsse32 clears vstart"
.4byte 0x018072d7  # vsetvli t0, zero, e64, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x12345fb7  # lui t6, 0x12345
.4byte 0x678f8f93  # addi t6, t6, 1656
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x01000393  # addi t2, zero, 16
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x0a747407  # vlse64.v v8, (s0), t2 [vstart=1]
.assert trap == 0 "vlse64 vstart=1 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlse64 clears vstart writes a0"
.assert rd_wdata == 0x0 "vlse64 clears vstart"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlse64 vs=1 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a512345678 "vlse64 vs=1 l0"
.4byte 0xc180f657  # vsetivli a2, 1, e64, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse64 vs=1 l1 writes a0"
.assert rd_wdata == 0xff324dd114cc2f5 "vlse64 vs=1 l1"
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x12345fb7  # lui t6, 0x12345
.4byte 0x679f8f93  # addi t6, t6, 1657
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b023  # sd t1, 0(s1)
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x02031313  # slli t1, t1, 32
.4byte 0x12345fb7  # lui t6, 0x12345
.4byte 0x67af8f93  # addi t6, t6, 1658
.4byte 0x01f36333  # or t1, t1, t6
.4byte 0x0064b823  # sd t1, 16(s1)
.4byte 0xc1817657  # vsetivli a2, 2, e64, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x0a74f427  # vsse64.v v8, (s1), t2 [vstart=1]
.assert trap == 0 "vsse64 vstart=1 retires"
.4byte 0x0004b503  # ld a0, 0(s1)
.assert rd_addr == 10 "vsse64 vs=1 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a512345679 "vsse64 vs=1 l0"
.4byte 0x0104b503  # ld a0, 16(s1)
.assert rd_addr == 10 "vsse64 vs=1 l1 writes a0"
.assert rd_wdata == 0xff324dd114cc2f5 "vsse64 vs=1 l1"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vsse64 clears vstart writes a0"
.assert rd_wdata == 0x0 "vsse64 clears vstart"
# Negative-stride masked vlse32/vsse32 resumed from vstart=1 and vstart>=vl.
.4byte 0x03040a13  # addi s4, s0, 48
.4byte 0xff400393  # addi t2, zero, -12
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e05b057  # vmv.v.i v0, 11
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x087a6407  # vlse32.v v8, (s4), t2, v0.t [vstart=1]
.assert trap == 0 "masked neg vlse32 vstart=1 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "masked neg vlse32 clears vstart writes a0"
.assert rd_wdata == 0x0 "masked neg vlse32 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked neg vlse32 prestart l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "masked neg vlse32 prestart l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "masked neg vlse32 active l1 writes a0"
.assert rd_wdata == 0x2ba65ecd "masked neg vlse32 active l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "masked neg vlse32 masked l2 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "masked neg vlse32 masked l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "masked neg vlse32 active l3 writes a0"
.assert rd_wdata == 0xffffffff9fee0b21 "masked neg vlse32 active l3"
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x0a046407  # vlse32.v v8, (s0), zero [vstart=2]
.assert trap == 0 "zero-stride vlse32 vstart=2 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "zero-stride vlse32 clears vstart writes a0"
.assert rd_wdata == 0x0 "zero-stride vlse32 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "zero-stride vlse32 vs=2 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "zero-stride vlse32 vs=2 l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "zero-stride vlse32 vs=2 l1 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "zero-stride vlse32 vs=2 l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "zero-stride vlse32 vs=2 l2 writes a0"
.assert rd_wdata == 0x1edfb0cc "zero-stride vlse32 vs=2 l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "zero-stride vlse32 vs=2 l3 writes a0"
.assert rd_wdata == 0x1edfb0cc "zero-stride vlse32 vs=2 l3"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x0081d073  # csrwi vstart, 3
.4byte 0x0a796407  # vlse32.v v8, (s2), t2 [vstart=3 >= vl]
.assert trap == 0 "vlse32 vstart>=vl at DDR_LIMIT no-op"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlse32 vstart>=vl clears vstart writes a0"
.assert rd_wdata == 0x0 "vlse32 vstart>=vl clears vstart"

# 2. Indexed loads and stores resumed from nonzero vstart (ux, ox, masked, in-place vd==vs2).
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e023857  # vmv.v.i v16, 4
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x02c00313  # addi t1, zero, 44
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x5e063857  # vmv.v.i v16, 12
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x01c00313  # addi t1, zero, 28
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x07046407  # vluxei32.v v8, (s0), v16 [vstart=2]
.assert trap == 0 "vluxei32 vstart=2 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vluxei32 clears vstart writes a0"
.assert rd_wdata == 0x0 "vluxei32 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vluxei32 vs=2 prestart l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vluxei32 vs=2 prestart l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vluxei32 vs=2 prestart l1 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vluxei32 vs=2 prestart l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vluxei32 vs=2 active l2 writes a0"
.assert rd_wdata == 0x7fa9e532 "vluxei32 vs=2 active l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vluxei32 vs=2 active l3 writes a0"
.assert rd_wdata == 0x4563bf52 "vluxei32 vs=2 active l3"
.4byte 0x11110337  # lui t1, 0x11110
.4byte 0x00130313  # addi t1, t1, 1
.4byte 0x0064ae23  # sw t1, 28(s1)
.4byte 0x11110337  # lui t1, 0x11110
.4byte 0x00230313  # addi t1, t1, 2
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x11110337  # lui t1, 0x11110
.4byte 0x00330313  # addi t1, t1, 3
.4byte 0x0264a623  # sw t1, 44(s1)
.4byte 0x11110337  # lui t1, 0x11110
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x0f04e427  # vsoxei32.v v8, (s1), v16 [vstart=2]
.assert trap == 0 "vsoxei32 vstart=2 retires"
.4byte 0x01c4e503  # lwu a0, 28(s1)
.assert rd_addr == 10 "vsoxei32 vs=2 prestart off 28 writes a0"
.assert rd_wdata == 0x11110001 "vsoxei32 vs=2 prestart off 28"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "vsoxei32 vs=2 prestart off 12 writes a0"
.assert rd_wdata == 0x11110002 "vsoxei32 vs=2 prestart off 12"
.4byte 0x02c4e503  # lwu a0, 44(s1)
.assert rd_addr == 10 "vsoxei32 vs=2 active off 44 writes a0"
.assert rd_wdata == 0x7fa9e532 "vsoxei32 vs=2 active off 44"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vsoxei32 vs=2 active off 4 writes a0"
.assert rd_wdata == 0x4563bf52 "vsoxei32 vs=2 active off 4"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vsoxei32 clears vstart writes a0"
.assert rd_wdata == 0x0 "vsoxei32 clears vstart"
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x5e043457  # vmv.v.i v8, 8
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x01400313  # addi t1, zero, 20
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x0e846407  # vloxei32.v v8, (s0), v8 [in-place vstart=2]
.assert trap == 0 "in-place vloxei32 vstart=2 retires without reading prestart indices"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "in-place vloxei32 clears vstart writes a0"
.assert rd_wdata == 0x0 "in-place vloxei32 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "in-place vloxei32 prestart l0 untouched writes a0"
.assert rd_wdata == 0x40000000 "in-place vloxei32 prestart l0 untouched"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "in-place vloxei32 prestart l1 untouched writes a0"
.assert rd_wdata == 0x40000004 "in-place vloxei32 prestart l1 untouched"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "in-place vloxei32 resumed l2 writes a0"
.assert rd_wdata == 0xff324dd "in-place vloxei32 resumed l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "in-place vloxei32 resumed l3 writes a0"
.assert rd_wdata == 0xffffffffa5d5183f "in-place vloxei32 resumed l3"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e06b057  # vmv.v.i v0, 13
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x01000313  # addi t1, zero, 16
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x02000313  # addi t1, zero, 32
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x40000337  # lui t1, 0x40000
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x05046407  # vluxei32.v v8, (s0), v16, v0.t [vstart=1]
.assert trap == 0 "masked vluxei32 vstart=1 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "masked vluxei32 clears vstart writes a0"
.assert rd_wdata == 0x0 "masked vluxei32 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "masked vluxei32 prestart l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "masked vluxei32 prestart l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "masked vluxei32 masked l1 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "masked vluxei32 masked l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "masked vluxei32 active l2 writes a0"
.assert rd_wdata == 0xffffffffa4f01f5d "masked vluxei32 active l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "masked vluxei32 active l3 writes a0"
.assert rd_wdata == 0x114cc2f5 "masked vluxei32 active l3"

# 3. Segment loads and stores resumed from nonzero vstart (unit, strided, indexed).
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x22046407  # vlseg2e32.v v8, (s0) [vstart=2]
.assert trap == 0 "vlseg2e32 vstart=2 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlseg2e32 clears vstart writes a0"
.assert rd_wdata == 0x0 "vlseg2e32 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg2e32 vs=2 f0 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlseg2e32 vs=2 f0 l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg2e32 vs=2 f1 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlseg2e32 vs=2 f1 l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32 vs=2 f0 l1 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlseg2e32 vs=2 f0 l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e90bc57  # vslidedown.vi v24, v9, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32 vs=2 f1 l1 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlseg2e32 vs=2 f1 l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32 vs=2 f0 l2 writes a0"
.assert rd_wdata == 0x114cc2f5 "vlseg2e32 vs=2 f0 l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e913c57  # vslidedown.vi v24, v9, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32 vs=2 f1 l2 writes a0"
.assert rd_wdata == 0xff324dd "vlseg2e32 vs=2 f1 l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32 vs=2 f0 l3 writes a0"
.assert rd_wdata == 0xffffffffc975a7e8 "vlseg2e32 vs=2 f0 l3"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e91bc57  # vslidedown.vi v24, v9, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32 vs=2 f1 l3 writes a0"
.assert rd_wdata == 0x4ef253ec "vlseg2e32 vs=2 f1 l3"
.4byte 0x22220337  # lui t1, 0x22220
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x22220337  # lui t1, 0x22220
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x22220337  # lui t1, 0x22220
.4byte 0x00830313  # addi t1, t1, 8
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x22220337  # lui t1, 0x22220
.4byte 0x00c30313  # addi t1, t1, 12
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0x22220337  # lui t1, 0x22220
.4byte 0x01030313  # addi t1, t1, 16
.4byte 0x0064a823  # sw t1, 16(s1)
.4byte 0x22220337  # lui t1, 0x22220
.4byte 0x01430313  # addi t1, t1, 20
.4byte 0x0064aa23  # sw t1, 20(s1)
.4byte 0x22220337  # lui t1, 0x22220
.4byte 0x01830313  # addi t1, t1, 24
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x22220337  # lui t1, 0x22220
.4byte 0x01c30313  # addi t1, t1, 28
.4byte 0x0064ae23  # sw t1, 28(s1)
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x2204e427  # vsseg2e32.v v8, (s1) [vstart=2]
.assert trap == 0 "vsseg2e32 vstart=2 retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vsseg2e32 vs=2 l0 f0 writes a0"
.assert rd_wdata == 0x22220000 "vsseg2e32 vs=2 l0 f0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vsseg2e32 vs=2 l0 f1 writes a0"
.assert rd_wdata == 0x22220004 "vsseg2e32 vs=2 l0 f1"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "vsseg2e32 vs=2 l1 f0 writes a0"
.assert rd_wdata == 0x22220008 "vsseg2e32 vs=2 l1 f0"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "vsseg2e32 vs=2 l1 f1 writes a0"
.assert rd_wdata == 0x2222000c "vsseg2e32 vs=2 l1 f1"
.4byte 0x0104e503  # lwu a0, 16(s1)
.assert rd_addr == 10 "vsseg2e32 vs=2 l2 f0 writes a0"
.assert rd_wdata == 0x114cc2f5 "vsseg2e32 vs=2 l2 f0"
.4byte 0x0144e503  # lwu a0, 20(s1)
.assert rd_addr == 10 "vsseg2e32 vs=2 l2 f1 writes a0"
.assert rd_wdata == 0xff324dd "vsseg2e32 vs=2 l2 f1"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "vsseg2e32 vs=2 l3 f0 writes a0"
.assert rd_wdata == 0xc975a7e8 "vsseg2e32 vs=2 l3 f0"
.4byte 0x01c4e503  # lwu a0, 28(s1)
.assert rd_addr == 10 "vsseg2e32 vs=2 l3 f1 writes a0"
.assert rd_wdata == 0x4ef253ec "vsseg2e32 vs=2 l3 f1"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vsseg2e32 clears vstart writes a0"
.assert rd_wdata == 0x0 "vsseg2e32 clears vstart"
.4byte 0x00c00393  # addi t2, zero, 12
.4byte 0x008072d7  # vsetvli t0, zero, e16, m1, tu, mu
.4byte 0x00006337  # lui t1, 0x6
.4byte 0xa5a30313  # addi t1, t1, -1446
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0x5e034557  # vmv.v.x v10, t1
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x4a745407  # vlsseg3e16.v v8, (s0), t2 [vstart=1]
.assert trap == 0 "vlsseg3e16 vstart=1 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlsseg3e16 clears vstart writes a0"
.assert rd_wdata == 0x0 "vlsseg3e16 clears vstart"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlsseg3e16 vs=1 f0 l0 writes a0"
.assert rd_wdata == 0x5a5a "vlsseg3e16 vs=1 f0 l0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlsseg3e16 vs=1 f1 l0 writes a0"
.assert rd_wdata == 0x5a5a "vlsseg3e16 vs=1 f1 l0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x42a02557  # vmv.x.s a0, v10
.assert rd_addr == 10 "vlsseg3e16 vs=1 f2 l0 writes a0"
.assert rd_wdata == 0x5a5a "vlsseg3e16 vs=1 f2 l0"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlsseg3e16 vs=1 f0 l1 writes a0"
.assert rd_wdata == 0xb21 "vlsseg3e16 vs=1 f0 l1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e90bc57  # vslidedown.vi v24, v9, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlsseg3e16 vs=1 f1 l1 writes a0"
.assert rd_wdata == 0xffffffffffff9fee "vlsseg3e16 vs=1 f1 l1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3ea0bc57  # vslidedown.vi v24, v10, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlsseg3e16 vs=1 f2 l1 writes a0"
.assert rd_wdata == 0xffffffffffffc2f5 "vlsseg3e16 vs=1 f2 l1"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlsseg3e16 vs=1 f0 l2 writes a0"
.assert rd_wdata == 0xffffffffffffa7e8 "vlsseg3e16 vs=1 f0 l2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3e913c57  # vslidedown.vi v24, v9, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlsseg3e16 vs=1 f1 l2 writes a0"
.assert rd_wdata == 0xffffffffffffc975 "vlsseg3e16 vs=1 f1 l2"
.4byte 0xc080f657  # vsetivli a2, 1, e16, m1, tu, mu
.4byte 0x3ea13c57  # vslidedown.vi v24, v10, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlsseg3e16 vs=1 f2 l2 writes a0"
.assert rd_wdata == 0x53ec "vlsseg3e16 vs=1 f2 l2"
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x30030313  # addi t1, t1, 768
.4byte 0x00649023  # sh t1, 0(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x30230313  # addi t1, t1, 770
.4byte 0x00649123  # sh t1, 2(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x30430313  # addi t1, t1, 772
.4byte 0x00649223  # sh t1, 4(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x30c30313  # addi t1, t1, 780
.4byte 0x00649623  # sh t1, 12(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x30e30313  # addi t1, t1, 782
.4byte 0x00649723  # sh t1, 14(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x31030313  # addi t1, t1, 784
.4byte 0x00649823  # sh t1, 16(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x31830313  # addi t1, t1, 792
.4byte 0x00649c23  # sh t1, 24(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x31a30313  # addi t1, t1, 794
.4byte 0x00649d23  # sh t1, 26(s1)
.4byte 0x00003337  # lui t1, 0x3
.4byte 0x31c30313  # addi t1, t1, 796
.4byte 0x00649e23  # sh t1, 28(s1)
.4byte 0xc081f657  # vsetivli a2, 3, e16, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x4a74d427  # vssseg3e16.v v8, (s1), t2 [vstart=1]
.assert trap == 0 "vssseg3e16 vstart=1 retires"
.4byte 0x0004d503  # lhu a0, 0(s1)
.assert rd_addr == 10 "vssseg3e16 vs=1 l0 f0 writes a0"
.assert rd_wdata == 0x3300 "vssseg3e16 vs=1 l0 f0"
.4byte 0x0024d503  # lhu a0, 2(s1)
.assert rd_addr == 10 "vssseg3e16 vs=1 l0 f1 writes a0"
.assert rd_wdata == 0x3302 "vssseg3e16 vs=1 l0 f1"
.4byte 0x0044d503  # lhu a0, 4(s1)
.assert rd_addr == 10 "vssseg3e16 vs=1 l0 f2 writes a0"
.assert rd_wdata == 0x3304 "vssseg3e16 vs=1 l0 f2"
.4byte 0x00c4d503  # lhu a0, 12(s1)
.assert rd_addr == 10 "vssseg3e16 vs=1 l1 f0 writes a0"
.assert rd_wdata == 0xb21 "vssseg3e16 vs=1 l1 f0"
.4byte 0x00e4d503  # lhu a0, 14(s1)
.assert rd_addr == 10 "vssseg3e16 vs=1 l1 f1 writes a0"
.assert rd_wdata == 0x9fee "vssseg3e16 vs=1 l1 f1"
.4byte 0x0104d503  # lhu a0, 16(s1)
.assert rd_addr == 10 "vssseg3e16 vs=1 l1 f2 writes a0"
.assert rd_wdata == 0xc2f5 "vssseg3e16 vs=1 l1 f2"
.4byte 0x0184d503  # lhu a0, 24(s1)
.assert rd_addr == 10 "vssseg3e16 vs=1 l2 f0 writes a0"
.assert rd_wdata == 0xa7e8 "vssseg3e16 vs=1 l2 f0"
.4byte 0x01a4d503  # lhu a0, 26(s1)
.assert rd_addr == 10 "vssseg3e16 vs=1 l2 f1 writes a0"
.assert rd_wdata == 0xc975 "vssseg3e16 vs=1 l2 f1"
.4byte 0x01c4d503  # lhu a0, 28(s1)
.assert rd_addr == 10 "vssseg3e16 vs=1 l2 f2 writes a0"
.assert rd_wdata == 0x53ec "vssseg3e16 vs=1 l2 f2"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vssseg3e16 clears vstart writes a0"
.assert rd_wdata == 0x0 "vssseg3e16 clears vstart"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x5e043857  # vmv.v.i v16, 8
.4byte 0xc1017657  # vsetivli a2, 2, e32, m1, tu, mu
.4byte 0x01800313  # addi t1, zero, 24
.4byte 0x5e034857  # vmv.v.x v16, t1
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x5e003857  # vmv.v.i v16, 0
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x27046407  # vluxseg2e32.v v8, (s0), v16 [vstart=1]
.assert trap == 0 "vluxseg2e32 vstart=1 retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vluxseg2e32 clears vstart writes a0"
.assert rd_wdata == 0x0 "vluxseg2e32 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vluxseg2e32 vs=1 f0 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vluxseg2e32 vs=1 f0 l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vluxseg2e32 vs=1 f1 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vluxseg2e32 vs=1 f1 l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vluxseg2e32 vs=1 f0 l1 writes a0"
.assert rd_wdata == 0xffffffffc975a7e8 "vluxseg2e32 vs=1 f0 l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e90bc57  # vslidedown.vi v24, v9, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vluxseg2e32 vs=1 f1 l1 writes a0"
.assert rd_wdata == 0x4ef253ec "vluxseg2e32 vs=1 f1 l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vluxseg2e32 vs=1 f0 l2 writes a0"
.assert rd_wdata == 0xffffffffa5d5183f "vluxseg2e32 vs=1 f0 l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e913c57  # vslidedown.vi v24, v9, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vluxseg2e32 vs=1 f1 l2 writes a0"
.assert rd_wdata == 0xffffffff9fee0b21 "vluxseg2e32 vs=1 f1 l2"
.4byte 0x44440337  # lui t1, 0x44440
.4byte 0x0064a023  # sw t1, 0(s1)
.4byte 0x44440337  # lui t1, 0x44440
.4byte 0x00430313  # addi t1, t1, 4
.4byte 0x0064a223  # sw t1, 4(s1)
.4byte 0x44440337  # lui t1, 0x44440
.4byte 0x01830313  # addi t1, t1, 24
.4byte 0x0064ac23  # sw t1, 24(s1)
.4byte 0x44440337  # lui t1, 0x44440
.4byte 0x01c30313  # addi t1, t1, 28
.4byte 0x0064ae23  # sw t1, 28(s1)
.4byte 0x44440337  # lui t1, 0x44440
.4byte 0x00830313  # addi t1, t1, 8
.4byte 0x0064a423  # sw t1, 8(s1)
.4byte 0x44440337  # lui t1, 0x44440
.4byte 0x00c30313  # addi t1, t1, 12
.4byte 0x0064a623  # sw t1, 12(s1)
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x2f04e427  # vsoxseg2e32.v v8, (s1), v16 [vstart=1]
.assert trap == 0 "vsoxseg2e32 vstart=1 retires"
.4byte 0x0004e503  # lwu a0, 0(s1)
.assert rd_addr == 10 "vsoxseg2e32 vs=1 l0 f0 writes a0"
.assert rd_wdata == 0x44440000 "vsoxseg2e32 vs=1 l0 f0"
.4byte 0x0044e503  # lwu a0, 4(s1)
.assert rd_addr == 10 "vsoxseg2e32 vs=1 l0 f1 writes a0"
.assert rd_wdata == 0x44440004 "vsoxseg2e32 vs=1 l0 f1"
.4byte 0x0184e503  # lwu a0, 24(s1)
.assert rd_addr == 10 "vsoxseg2e32 vs=1 l1 f0 writes a0"
.assert rd_wdata == 0xc975a7e8 "vsoxseg2e32 vs=1 l1 f0"
.4byte 0x01c4e503  # lwu a0, 28(s1)
.assert rd_addr == 10 "vsoxseg2e32 vs=1 l1 f1 writes a0"
.assert rd_wdata == 0x4ef253ec "vsoxseg2e32 vs=1 l1 f1"
.4byte 0x0084e503  # lwu a0, 8(s1)
.assert rd_addr == 10 "vsoxseg2e32 vs=1 l2 f0 writes a0"
.assert rd_wdata == 0xa5d5183f "vsoxseg2e32 vs=1 l2 f0"
.4byte 0x00c4e503  # lwu a0, 12(s1)
.assert rd_addr == 10 "vsoxseg2e32 vs=1 l2 f1 writes a0"
.assert rd_wdata == 0x9fee0b21 "vsoxseg2e32 vs=1 l2 f1"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vsoxseg2e32 clears vstart writes a0"
.assert rd_wdata == 0x0 "vsoxseg2e32 clears vstart"

# 4. Fault-only-first loads resumed from nonzero vstart (no-fault, i>vstart trim, i==vstart trim, segment, vstart>=vl).
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x03046407  # vle32ff.v v8, (s0) [vstart=2, no fault]
.assert trap == 0 "vle32ff vstart=2 no-fault retires"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "vle32ff vstart=2 no-fault vl==4 writes a0"
.assert rd_wdata == 0x4 "vle32ff vstart=2 no-fault vl==4"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vle32ff vstart=2 clears vstart writes a0"
.assert rd_wdata == 0x0 "vle32ff vstart=2 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vle32ff no-fault vs=2 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vle32ff no-fault vs=2 l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vle32ff no-fault vs=2 l1 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vle32ff no-fault vs=2 l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vle32ff no-fault vs=2 l2 writes a0"
.assert rd_wdata == 0xffffffffa5d5183f "vle32ff no-fault vs=2 l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vle32ff no-fault vs=2 l3 writes a0"
.assert rd_wdata == 0xffffffff9fee0b21 "vle32ff no-fault vs=2 l3"
.4byte 0xff490a13  # addi s4, s2, -12
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x030a6407  # vle32ff.v v8, (s4) [vstart=1, fault at elem 3]
.assert trap == 0 "vle32ff vstart=1 trims at elem 3"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "vle32ff vs=1 trimmed vl==3 writes a0"
.assert rd_wdata == 0x3 "vle32ff vs=1 trimmed vl==3"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vle32ff vs=1 clears vstart writes a0"
.assert rd_wdata == 0x0 "vle32ff vs=1 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vle32ff vs=1 prestart l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vle32ff vs=1 prestart l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vle32ff vs=1 loaded l1 writes a0"
.assert rd_wdata == 0xffffffffe97da148 "vle32ff vs=1 loaded l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vle32ff vs=1 loaded l2 writes a0"
.assert rd_wdata == 0x5ffb2377 "vle32ff vs=1 loaded l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vle32ff vs=1 fault l3 undisturbed writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vle32ff vs=1 fault l3 undisturbed"
.4byte 0xff890a13  # addi s4, s2, -8
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x00815073  # csrwi vstart, 2
.4byte 0x030a6407  # vle32ff.v v8, (s4) [vstart=2, fault at elem 2]
.assert trap == 0 "vle32ff fault at i==vstart>0 trims without trapping"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "vle32ff i==vstart trims vl==2 writes a0"
.assert rd_wdata == 0x2 "vle32ff i==vstart trims vl==2"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vle32ff i==vstart clears vstart writes a0"
.assert rd_wdata == 0x0 "vle32ff i==vstart clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vle32ff i==vstart l0 untouched writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vle32ff i==vstart l0 untouched"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vle32ff i==vstart l1 untouched writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vle32ff i==vstart l1 untouched"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vle32ff i==vstart l2 untouched writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vle32ff i==vstart l2 untouched"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vle32ff i==vstart l3 untouched writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vle32ff i==vstart l3 untouched"
.4byte 0xff090a13  # addi s4, s2, -16
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0x5e0344d7  # vmv.v.x v9, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x0080d073  # csrwi vstart, 1
.4byte 0x230a6407  # vlseg2e32ff.v v8, (s4) [vstart=1, fault at seg 2]
.assert trap == 0 "vlseg2e32ff vstart=1 trims at seg 2"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "vlseg2e32ff vs=1 trimmed vl==2 writes a0"
.assert rd_wdata == 0x2 "vlseg2e32ff vs=1 trimmed vl==2"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlseg2e32ff vs=1 clears vstart writes a0"
.assert rd_wdata == 0x0 "vlseg2e32ff vs=1 clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlseg2e32ff vs=1 prestart f0 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlseg2e32ff vs=1 prestart f0 l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42902557  # vmv.x.s a0, v9
.assert rd_addr == 10 "vlseg2e32ff vs=1 prestart f1 l0 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlseg2e32ff vs=1 prestart f1 l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32ff vs=1 loaded f0 l1 writes a0"
.assert rd_wdata == 0xffffffffe97da148 "vlseg2e32ff vs=1 loaded f0 l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e90bc57  # vslidedown.vi v24, v9, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32ff vs=1 loaded f1 l1 writes a0"
.assert rd_wdata == 0x5ffb2377 "vlseg2e32ff vs=1 loaded f1 l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32ff vs=1 fault f0 l2 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlseg2e32ff vs=1 fault f0 l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e913c57  # vslidedown.vi v24, v9, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlseg2e32ff vs=1 fault f1 l2 writes a0"
.assert rd_wdata == 0x5a5aa5a5 "vlseg2e32ff vs=1 fault f1 l2"
.4byte 0xc101f657  # vsetivli a2, 3, e32, m1, tu, mu
.4byte 0x0081d073  # csrwi vstart, 3
.4byte 0x03096407  # vle32ff.v v8, (s2) [vstart=3 >= vl]
.assert trap == 0 "vle32ff vstart>=vl at DDR_LIMIT no-op"
.4byte 0xc2002573  # csrr a0, vl
.assert rd_addr == 10 "vle32ff vstart>=vl preserves vl==3 writes a0"
.assert rd_wdata == 0x3 "vle32ff vstart>=vl preserves vl==3"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vle32ff vstart>=vl clears vstart writes a0"
.assert rd_wdata == 0x0 "vle32ff vstart>=vl clears vstart"

# 5. Fault-triggered vstart resumption on non-FoF strided and indexed loads/stores.
.4byte 0xff090a13  # addi s4, s2, -16
.4byte 0x00800393  # addi t2, zero, 8
.4byte 0x010072d7  # vsetvli t0, zero, e32, m1, tu, mu
.4byte 0x5a5aa337  # lui t1, 0x5a5aa
.4byte 0x5a530313  # addi t1, t1, 1445
.4byte 0x5e034457  # vmv.v.x v8, t1
.4byte 0xc1027657  # vsetivli a2, 4, e32, m1, tu, mu
.4byte 0x0a7a6407  # vlse32.v v8, (s4), t2
.assert trap == 1 "vlse32 elem2 access fault traps"
.4byte 0x34202573  # csrr a0, mcause
.assert rd_addr == 10 "vlse32 elem2 access fault mcause writes a0"
.assert rd_wdata == 0x5 "vlse32 elem2 access fault mcause"
.4byte 0x34302573  # csrr a0, mtval
.assert rd_addr == 10 "vlse32 elem2 access fault mtval writes a0"
.assert rd_wdata == 0xc0000000 "vlse32 elem2 access fault mtval"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlse32 fault sets vstart==2 writes a0"
.assert rd_wdata == 0x2 "vlse32 fault sets vstart==2"
.4byte 0x0a746407  # vlse32.v v8, (s0), t2
.assert trap == 0 "vlse32 fault-resume retires"
.4byte 0x00802573  # csrr a0, vstart
.assert rd_addr == 10 "vlse32 fault-resume clears vstart writes a0"
.assert rd_wdata == 0x0 "vlse32 fault-resume clears vstart"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x42802557  # vmv.x.s a0, v8
.assert rd_addr == 10 "vlse32 fault-resume prestart l0 writes a0"
.assert rd_wdata == 0x17224b2a "vlse32 fault-resume prestart l0"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e80bc57  # vslidedown.vi v24, v8, 1
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse32 fault-resume prestart l1 writes a0"
.assert rd_wdata == 0xffffffffe97da148 "vlse32 fault-resume prestart l1"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e813c57  # vslidedown.vi v24, v8, 2
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse32 fault-resume resumed l2 writes a0"
.assert rd_wdata == 0x114cc2f5 "vlse32 fault-resume resumed l2"
.4byte 0xc100f657  # vsetivli a2, 1, e32, m1, tu, mu
.4byte 0x3e81bc57  # vslidedown.vi v24, v8, 3
.4byte 0x43802557  # vmv.x.s a0, v24
.assert rd_addr == 10 "vlse32 fault-resume resumed l3 writes a0"
.assert rd_wdata == 0xffffffffc975a7e8 "vlse32 fault-resume resumed l3"
