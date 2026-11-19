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
# The first page past MMIO faults in Bare mode, including a misaligned store.
.4byte 0x400310b7 # lui x1, 0x40031
.4byte 0x0020a023 # sw x2, 0(x1)
.4byte 0x341021f3 # csrr x3, mepc
.4byte 0x34302273 # csrr x4, mtval
.4byte 0x342022f3 # csrr x5, mcause
.4byte 0x0020a0a3 # sw x2, 1(x1)
.4byte 0x34302273 # csrr x4, mtval
.4byte 0x342022f3 # csrr x5, mcause
# Root 0x80001000 maps VA 0 to PA 0x40000000 with a writable 1 GiB leaf.
.4byte 0x00080337 # lui x6, 0x80
.4byte 0x00130313 # addi x6, x6, 1
.4byte 0x00c31093 # slli x1, x6, 12
.4byte 0x10000137 # lui x2, 0x10000
.4byte 0x0c710113 # addi x2, x2, 199
.4byte 0x0020b023 # sd x2, 0(x1)
.4byte 0x00100193 # addi x3, x0, 1
.4byte 0x03f19193 # slli x3, x3, 63
.4byte 0x0061e333 # or x6, x3, x6
.4byte 0x18031073 # csrw satp, x6
.4byte 0x12000073 # sfence.vma x0, x0
# MPRV with MPP=S. A mapped word round-trips before VA 0x31000 faults.
.4byte 0x000211b7 # lui x3, 0x21
.4byte 0x80018193 # addi x3, x3, -2048
.4byte 0x30019073 # csrw mstatus, x3
.4byte 0x000010b7 # lui x1, 0x1
.4byte 0x05a00113 # addi x2, x0, 90
.4byte 0x0020ae23 # sw x2, 28(x1)
.4byte 0x01c0a383 # lw x7, 28(x1)
.4byte 0x000310b7 # lui x1, 0x31
.4byte 0x0020a023 # sw x2, 0(x1)
.4byte 0x341021f3 # csrr x3, mepc
.4byte 0x34302273 # csrr x4, mtval
.4byte 0x342022f3 # csrr x5, mcause
