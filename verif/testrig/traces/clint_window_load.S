# A byte load at 0x7_FFFF_FDEC, just below 2^35 and outside FROST's map, is
# a load access fault. Sail's CLINT, which Zicntr requires, sat at
# 0x7_FFFF_0000, so Sail answered the load that FROST faults, and a random
# sequence that shifted a negative number right reached it.
.4byte 0x92a00093 # addi x1, x0, -1750
.4byte 0x01d0da13 # srli x20, x1, 29
.4byte 0xdeda4083 # lbu x1, x20[-531]
.4byte 0x342020f3 # csrr x1, mcause
.4byte 0x343020f3 # csrr x1, mtval
