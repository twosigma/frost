# A byte load at 0x7_FFFF_FDEC faults in both models at the default 1 GiB
# DDR capacity. With 64 GiB configured, it reaches ordinary DDR in both.
# Sail disables its CLINT here so the selected DDR capacity governs access.
.4byte 0x92a00093 # addi x1, x0, -1750
.4byte 0x01d0da13 # srli x20, x1, 29
.4byte 0xdeda4083 # lbu x1, x20[-531]
.4byte 0x342020f3 # csrr x1, mcause
.4byte 0x343020f3 # csrr x1, mtval
