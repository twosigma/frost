# Access faults outside the physical map write the faulting virtual address to
# mtval: a load, a store, an AMO, an LR, a misaligned load (the access fault
# outranks misalignment) and a byte store, at 2^48 + 0x18 and its neighbours.
# Each case is followed by a read of mtval and mcause.
.4byte 0x00100093 # addi x1, x0, 1
.4byte 0x03009093 # slli x1, x1, 48
.4byte 0x01808093 # addi x1, x1, 24
.4byte 0x0000b103 # ld x2, 0(x1)
.4byte 0x34302273 # csrr x4, mtval
.4byte 0x342022f3 # csrr x5, mcause
.4byte 0x0020b423 # sd x2, 8(x1)
.4byte 0x34302273 # csrr x4, mtval
.4byte 0x342022f3 # csrr x5, mcause
.4byte 0x0030b12f # amoadd.d x2, x3, (x1)
.4byte 0x34302273 # csrr x4, mtval
.4byte 0x342022f3 # csrr x5, mcause
.4byte 0x1000b12f # lr.d x2, (x1)
.4byte 0x34302273 # csrr x4, mtval
.4byte 0x342022f3 # csrr x5, mcause
.4byte 0x0020a103 # lw x2, 2(x1)
.4byte 0x34302273 # csrr x4, mtval
.4byte 0x342022f3 # csrr x5, mcause
.4byte 0xfe208fa3 # sb x2, -1(x1)
.4byte 0x34302273 # csrr x4, mtval
.4byte 0x342022f3 # csrr x5, mcause
