# Ssu64xl: UXLEN is 64. mstatus.UXL (33:32) and mstatus.SXL (35:34) read 2
# and keep 2 when written with 1 or 0 (WARL, read-only on FROST); the sstatus
# view reads UXL = 2 as well, also after an sstatus write.
# Read mstatus and sstatus; isolate UXL and SXL.
.4byte 0x300020f3 # csrr x1, mstatus
.4byte 0x0200d113 # srli x2, x1, 32
.4byte 0x00f17113 # andi x2, x2, 15
.4byte 0x100021f3 # csrr x3, sstatus
.4byte 0x0201d213 # srli x4, x3, 32
.4byte 0x00327213 # andi x4, x4, 3
# Write UXL = 1, SXL = 1 through mstatus; then clear both; read back each time.
.4byte 0x00500293 # addi x5, x0, 5
.4byte 0x02029293 # slli x5, x5, 32
.4byte 0x3002a073 # csrs mstatus, x5
.4byte 0x300020f3 # csrr x1, mstatus
.4byte 0x0200d113 # srli x2, x1, 32
.4byte 0x00f17113 # andi x2, x2, 15
.4byte 0x00f00313 # addi x6, x0, 15
.4byte 0x02031313 # slli x6, x6, 32
.4byte 0x30033073 # csrc mstatus, x6
.4byte 0x300020f3 # csrr x1, mstatus
.4byte 0x0200d113 # srli x2, x1, 32
.4byte 0x00f17113 # andi x2, x2, 15
# Write UXL = 1 and then 0 through sstatus.
.4byte 0x00100393 # addi x7, x0, 1
.4byte 0x02039393 # slli x7, x7, 32
.4byte 0x1003a073 # csrs sstatus, x7
.4byte 0x100021f3 # csrr x3, sstatus
.4byte 0x0201d213 # srli x4, x3, 32
.4byte 0x00327213 # andi x4, x4, 3
.4byte 0x00300413 # addi x8, x0, 3
.4byte 0x02041413 # slli x8, x8, 32
.4byte 0x10043073 # csrc sstatus, x8
.4byte 0x100021f3 # csrr x3, sstatus
.4byte 0x0201d213 # srli x4, x3, 32
.4byte 0x00327213 # andi x4, x4, 3
