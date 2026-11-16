# Ssu64xl: UXLEN is 64. mstatus.UXL (33:32) and mstatus.SXL (35:34) read 2
# and keep 2 when written with 3, 0 or 1 (WARL, read-only on FROST); the
# sstatus view reads UXL = 2 as well, also after an sstatus write.
# Read mstatus and sstatus; isolate UXL and SXL.
.4byte 0x300020f3 # csrr x1, mstatus
.4byte 0x0200d113 # srli x2, x1, 32
.4byte 0x00f17113 # andi x2, x2, 15
.4byte 0x100021f3 # csrr x3, sstatus
.4byte 0x0201d213 # srli x4, x3, 32
.4byte 0x00327213 # andi x4, x4, 3
# Set both low bits of UXL and SXL through mstatus (csrs, requests 3); then clear
# them (csrc, requests 0); read back each time.
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
# Write UXL = 1 and SXL = 1 through mstatus with csrw (masked read-modify-write).
.4byte 0x300024f3 # csrr x9, mstatus
.4byte 0x00f00513 # addi x10, x0, 15
.4byte 0x02051513 # slli x10, x10, 32
.4byte 0xfff54593 # xori x11, x10, -1
.4byte 0x00b4f4b3 # and x9, x9, x11
.4byte 0x00500613 # addi x12, x0, 5
.4byte 0x02061613 # slli x12, x12, 32
.4byte 0x00c4e4b3 # or x9, x9, x12
.4byte 0x30049073 # csrw mstatus, x9
.4byte 0x300020f3 # csrr x1, mstatus
.4byte 0x0200d113 # srli x2, x1, 32
.4byte 0x00f17113 # andi x2, x2, 15
# Set the low UXL bit through sstatus (csrs, requests 3); then clear UXL
# (csrc, requests 0); read back each time.
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
# Write UXL = 1 through sstatus with csrw (masked read-modify-write).
.4byte 0x100024f3 # csrr x9, sstatus
.4byte 0x00300513 # addi x10, x0, 3
.4byte 0x02051513 # slli x10, x10, 32
.4byte 0xfff54593 # xori x11, x10, -1
.4byte 0x00b4f4b3 # and x9, x9, x11
.4byte 0x00100613 # addi x12, x0, 1
.4byte 0x02061613 # slli x12, x12, 32
.4byte 0x00c4e4b3 # or x9, x9, x12
.4byte 0x10049073 # csrw sstatus, x9
.4byte 0x100021f3 # csrr x3, sstatus
.4byte 0x0201d213 # srli x4, x3, 32
.4byte 0x00327213 # andi x4, x4, 3
