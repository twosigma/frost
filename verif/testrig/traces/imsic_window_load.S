# An aligned doubleword load at 0x4800_00A8 reaches the IMSIC device window.
# TestRIG backs the window with RAM, which reads zero after reset.
.4byte 0x00007165 # c.addi16sp -400
.4byte 0x00001414 # c.addi4spn x13, 544
.4byte 0x000006de # c.slli x13, 23
.4byte 0x00008c55 # c.or x8, x13
.4byte 0x0000744c # c.ld x11, 168(x8)
.4byte 0x342020f3 # csrr x1, mcause
.4byte 0x343020f3 # csrr x1, mtval
