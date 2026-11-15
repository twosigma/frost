# LR.W and LR.D require rs2 = 0; nonzero rs2 encodings are reserved and raise
# an illegal-instruction trap (mcause = 2, mtval = faulting instruction bits),
# without creating a reservation. Legal rs2 = 0 encodings still reserve and pair
# with SC.
.4byte 0x80200137 # lui x2, 0x80200
.4byte 0x02011113 # slli x2, x2, 32
.4byte 0x02015113 # srli x2, x2, 32
.4byte 0x00900393 # addi x7, x0, 9
.4byte 0x00713023 # sd x7, 0(x2)
.4byte 0x101120af # lr.w x1, (x2) with rs2 = x1 (reserved)
.4byte 0x343021f3 # csrr x3, mtval
.4byte 0x34202273 # csrr x4, mcause
.4byte 0x1871232f # sc.w x6, x7, (x2) (must fail: no reservation)
.4byte 0x17f132af # lr.d.aqrl x5, (x2) with rs2 = x31 (reserved)
.4byte 0x343021f3 # csrr x3, mtval
.4byte 0x34202273 # csrr x4, mcause
.4byte 0x1871332f # sc.d x6, x7, (x2) (must fail: no reservation)
.4byte 0x100120af # lr.w x1, (x2) (legal, rs2 = x0)
.4byte 0x1871232f # sc.w x6, x7, (x2)
.4byte 0x100132af # lr.d x5, (x2) (legal, rs2 = x0)
.4byte 0x187133af # sc.d x7, x7, (x2)
