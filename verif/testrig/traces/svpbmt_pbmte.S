# Svpbmt: the PTE PBMT field (bits 62:61) under menvcfg.PBMTE, in M with
# MPRV and MPP=S. With PBMTE clear a leaf with PBMT = NC is a load page fault
# (13); with PBMTE set, a leaf with PBMT = 3 is a load or store page fault
# (13, 15), and a non-leaf PTE with PBMT set is a load page fault. A PMA page
# loads in both settings. menvcfg.PBMTE reads back. Sail and FROST agree on
# these; NC and IO data accesses are not compared (FROST sends them to its
# uncached alias, which this harness does not model as DDR), nor are AMOs and
# fetches on NC or IO pages (FROST refuses them as a PMA override; Sail does
# not).
# Tables: root 0x80001000, level 1 0x80002000, level 0 0x80003000.
# Root[0] -> level-1 table (V).
.4byte 0x800010b7 # lui x1, 0x80001
.4byte 0x02009093 # slli x1, x1, 32
.4byte 0x0200d093 # srli x1, x1, 32
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0x80110113 # addi x2, x2, -2047
.4byte 0x0020b023 # sd x2, 0(x1)
# Level 1: [0] -> level-0 table (V); [1] -> the same table with PBMT = NC.
.4byte 0x800021b7 # lui x3, 0x80002
.4byte 0x02019193 # slli x3, x3, 32
.4byte 0x0201d193 # srli x3, x3, 32
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0xc0110113 # addi x2, x2, -1023
.4byte 0x0021b023 # sd x2, 0(x3)
.4byte 0x00100213 # addi x4, x0, 1
.4byte 0x03d21213 # slli x4, x4, 61
.4byte 0x00416133 # or x2, x2, x4
.4byte 0x0021b423 # sd x2, 8(x3)
# Level 0: [0] PMA, [1] NC, [2] PBMT 3, each R W A D over 0x80004000..
.4byte 0x800032b7 # lui x5, 0x80003
.4byte 0x02029293 # slli x5, x5, 32
.4byte 0x0202d293 # srli x5, x5, 32
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0x0c710113 # addi x2, x2, 199
.4byte 0x0022b023 # sd x2, 0(x5)
.4byte 0x40010113 # addi x2, x2, 1024
.4byte 0x00416333 # or x6, x2, x4
.4byte 0x0062b423 # sd x6, 8(x5)
.4byte 0x40010113 # addi x2, x2, 1024
.4byte 0x00300313 # addi x6, x0, 3
.4byte 0x03d31313 # slli x6, x6, 61
.4byte 0x00616333 # or x6, x2, x6
.4byte 0x0062b823 # sd x6, 16(x5)
# A value in the PMA page's frame.
.4byte 0x800043b7 # lui x7, 0x80004
.4byte 0x02039393 # slli x7, x7, 32
.4byte 0x0203d393 # srli x7, x7, 32
.4byte 0x04d00413 # addi x8, x0, 77
.4byte 0x0083b823 # sd x8, 16(x7)
# menvcfg.PBMTE = 0; satp = Sv39, root PPN 0x80001.
.4byte 0x30a01073 # csrw menvcfg, x0
.4byte 0x00100493 # addi x9, x0, 1
.4byte 0x03f49493 # slli x9, x9, 63
.4byte 0x00080537 # lui x10, 0x80
.4byte 0x00150513 # addi x10, x10, 1
.4byte 0x00a4e4b3 # or x9, x9, x10
.4byte 0x18049073 # csrw satp, x9
.4byte 0x12000073 # sfence.vma
# mstatus.MPRV = 1 and MPP = S. A trap sets MPP back to M; clearing MPP[1] returns it to S.
.4byte 0x000215b7 # lui x11, 0x21
.4byte 0x80058593 # addi x11, x11, -2048
.4byte 0x3005a073 # csrs mstatus, x11
.4byte 0x00001637 # lui x12, 0x1
# PBMTE = 0: the PMA page loads; the NC page is a load page fault.
.4byte 0x01003683 # ld x13, 16(x0)
.4byte 0x01863683 # ld x13, 0x18(x12)
.4byte 0x34202773 # csrr x14, mcause
.4byte 0x343027f3 # csrr x15, mtval
.4byte 0x30063073 # csrc mstatus, x12
# PBMTE = 1, then sfence.vma.
.4byte 0x00100813 # addi x16, x0, 1
.4byte 0x03e81813 # slli x16, x16, 62
.4byte 0x30a82073 # csrs menvcfg, x16
.4byte 0x30a028f3 # csrr x17, menvcfg
.4byte 0x12000073 # sfence.vma
# PBMT 3: a load page fault and a store page fault.
.4byte 0x40060913 # addi x18, x12, 1024
.4byte 0x40090913 # addi x18, x18, 1024
.4byte 0x40090913 # addi x18, x18, 1024
.4byte 0x40090913 # addi x18, x18, 1024
.4byte 0x02093683 # ld x13, 32(x18)
.4byte 0x34202773 # csrr x14, mcause
.4byte 0x30063073 # csrc mstatus, x12
.4byte 0x02893423 # sd x8, 40(x18)
.4byte 0x34202773 # csrr x14, mcause
.4byte 0x30063073 # csrc mstatus, x12
# A non-leaf PTE with PBMT: VA 0x200000 walks through level-1 entry 1.
.4byte 0x002009b7 # lui x19, 0x200
.4byte 0x0089b683 # ld x13, 8(x19)
.4byte 0x34202773 # csrr x14, mcause
.4byte 0x30063073 # csrc mstatus, x12
# The PMA page still loads; PBMTE = 0 again with sfence.vma.
.4byte 0x01003683 # ld x13, 16(x0)
.4byte 0x30a83073 # csrc menvcfg, x16
.4byte 0x30a028f3 # csrr x17, menvcfg
.4byte 0x12000073 # sfence.vma
.4byte 0x03063683 # ld x13, 0x30(x12)
.4byte 0x34202773 # csrr x14, mcause
.4byte 0x30063073 # csrc mstatus, x12
