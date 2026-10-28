# AMOs to either doubleword in the reserved line cancel the reservation.
# An AMO to the next line preserves it. The first two SCs fail; the third succeeds.
.4byte 0x80200a37 # lui x20, 0x80200
.4byte 0x020a1a13 # slli x20, x20, 32
.4byte 0x020a5a13 # srli x20, x20, 32
.4byte 0x000a0a13 # addi x20, x20, 0
.4byte 0x00700393 # addi x7, x0, 7
.4byte 0x100a32af # lr.d x5, (x20)
.4byte 0x007a202f # amoadd.w x0, x7, (x20)
.4byte 0x187a332f # sc.d x6, x7, (x20)
.4byte 0x100a32af # lr.d x5, (x20)
.4byte 0x008a0a93 # addi x21, x20, 8
.4byte 0x007ab02f # amoadd.d x0, x7, (x21)
.4byte 0x187a342f # sc.d x8, x7, (x20)
.4byte 0x100a32af # lr.d x5, (x20)
.4byte 0x020a0a93 # addi x21, x20, 32
.4byte 0x007ab02f # amoadd.d x0, x7, (x21)
.4byte 0x187a34af # sc.d x9, x7, (x20)
