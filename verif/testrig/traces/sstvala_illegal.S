# Sstvala: an illegal-instruction trap writes the faulting instruction's bits
# to mtval, 32 bits for a native instruction and the 16 bits of a compressed
# one zero-extended. Each case is followed by a read of mtval and mcause.
# sail_frost.json sets xtval_nonzero.illegal_instruction.
.4byte 0xfedcba8b # custom-0, every field set
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x0000001c # c.addi4spn x15, 0 (reserved)
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x00009ffc # quadrant 0 funct3=100 bit 12 (reserved)
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x00008cc4 # c.sh slot with bit 6 set
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x00009c7d # zcb unary selector 111
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x00006201 # c.lui x4, 0
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x6005c573 # hlv.b x10, (x11)
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x91c5c573 # mop.r.0 with bit 28 set
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x0ff027f3 # csrrs x15, 0x0ff, x0 (no such CSR)
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0xf1129073 # csrrw x0, mvendorid, x5 (read-only)
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
.4byte 0x00000000 # all-zero parcel (c.unimp)
.4byte 0x343020f3 # csrr x1, mtval
.4byte 0x34202173 # csrr x2, mcause
