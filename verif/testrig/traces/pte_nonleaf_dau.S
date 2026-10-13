# The privileged specification reserves D, A, and U on a non-leaf PTE, and
# the walk faults on a reserved bit. FROST's walker descended through such
# pointers (issue #58).
# Root table at 0x80001000; entries 0, 1, and 2 point to the level-1 table
# with A, D, and U set respectively (reserved on a non-leaf PTE).
.4byte 0x800010b7 # lui x1, 0x80001
.4byte 0x02009093 # slli x1, x1, 32
.4byte 0x0200d093 # srli x1, x1, 32
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0x84110113 # addi x2, x2, -1983
.4byte 0x0020b023 # sd x2, 0(x1)   # root[0]: pointer with A
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0x88110113 # addi x2, x2, -1919
.4byte 0x0020b423 # sd x2, 8(x1)   # root[1]: pointer with D
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0x81110113 # addi x2, x2, -2031
.4byte 0x0020b823 # sd x2, 16(x1)   # root[2]: pointer with U
# Level-1 table: entry 0 points to the level-0 table (V only).
.4byte 0x800021b7 # lui x3, 0x80002
.4byte 0x02019193 # slli x3, x3, 32
.4byte 0x0201d193 # srli x3, x3, 32
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0xc0110113 # addi x2, x2, -1023
.4byte 0x0021b023 # sd x2, 0(x3)
# Level-0 table: entry 0 maps a readable, accessed, dirty page.
.4byte 0x80003237 # lui x4, 0x80003
.4byte 0x02021213 # slli x4, x4, 32
.4byte 0x02025213 # srli x4, x4, 32
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0x0c710113 # addi x2, x2, 199
.4byte 0x00223023 # sd x2, 0(x4)
# satp = Sv39, root PPN 0x80001.
.4byte 0x00100293 # addi x5, x0, 1
.4byte 0x03f29293 # slli x5, x5, 63
.4byte 0x00080337 # lui x6, 0x80
.4byte 0x00130313 # addi x6, x6, 1
.4byte 0x0062e2b3 # or x5, x5, x6
.4byte 0x18029073 # csrw satp, x5
.4byte 0x12000073 # sfence.vma
# mstatus.MPRV = 1 and MPP = S: M-mode loads translate as S-mode.
.4byte 0x000213b7 # lui x7, 0x21
.4byte 0x80038393 # addi x7, x7, -2048
.4byte 0x3003a073 # csrs mstatus, x7
# Each load walks through one of the pointers and must take a load page fault (13).
# The trap sets MPP back to M, so clearing MPP[1] before each later load
# returns it to S.
.4byte 0x00003403 # ld x8, 0(x0)          # root[0], A set
.4byte 0x342024f3 # csrr x9, mcause
.4byte 0x000015b7 # lui x11, 0x1
.4byte 0x3005b073 # csrc mstatus, x11
.4byte 0x40000537 # lui x10, 0x40000
.4byte 0x00053403 # ld x8, 0(x10)         # root[1], D set
.4byte 0x342024f3 # csrr x9, mcause
.4byte 0x3005b073 # csrc mstatus, x11
.4byte 0x80000537 # lui x10, 0x80000
.4byte 0x02051513 # slli x10, x10, 32
.4byte 0x02055513 # srli x10, x10, 32
.4byte 0x00053403 # ld x8, 0(x10)         # root[2], U set
.4byte 0x342024f3 # csrr x9, mcause
