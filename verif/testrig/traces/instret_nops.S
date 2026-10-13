# NOP and C.NOP retire and count in minstret; FROST dropped canonical NOPs
# in ID, so they never retired (issue #58).
.4byte 0xb02020f3 # csrr x1, minstret
.4byte 0x00000013 # nop
.4byte 0x00000013 # nop
.4byte 0x00000001 # c.nop
.4byte 0xb0202173 # csrr x2, minstret
.4byte 0x00100193 # addi x3, x0, 1
.4byte 0x00000013 # nop
.4byte 0x00000001 # c.nop
.4byte 0xc0202273 # csrr x4, instret
