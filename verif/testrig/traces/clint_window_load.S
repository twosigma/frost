# A byte load at 0x7_FFFF_FDEC once faulted in FROST's 1 GiB DDR map while
# Sail's CLINT answered it. With the 64 GiB default, it is ordinary DDR in
# both implementations. This trace guards the capacity-sensitive comparison;
# under a 1 GiB configuration both implementations must instead fault.
.4byte 0x92a00093 # addi x1, x0, -1750
.4byte 0x01d0da13 # srli x20, x1, 29
.4byte 0xdeda4083 # lbu x1, x20[-531]
.4byte 0x342020f3 # csrr x1, mcause
.4byte 0x343020f3 # csrr x1, mtval
