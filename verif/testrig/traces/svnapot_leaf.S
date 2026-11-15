# Svnapot: a level-0 leaf with N (bit 63) set and PPN[3:0] = 1000 maps one
# page of a 64 KiB range, with PPN[3:0] taken from VA[15:12]. In M with MPRV
# and MPP = S: VA 0x13010 and 0x1f008 (slots 19 and 31 of the range at VA
# 0x10000, all holding one NAPOT PTE over 0x80010000) load and store the
# frames 0x80013000 and 0x8001f000. N with PPN[3:0] = 0001 (slot 32), N in a
# 2 MiB leaf (VA 0x200000) and N in a pointer (VA 0x400000) are page faults.
# Tables: root 0x80001000, level 1 0x80002000, level 0 0x80003000.
# Root[0] -> level-1 table.
.4byte 0x800010b7 # lui x1, 0x80001
.4byte 0x02009093 # slli x1, x1, 32
.4byte 0x0200d093 # srli x1, x1, 32
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0x80110113 # addi x2, x2, -2047
.4byte 0x0020b023 # sd x2, 0(x1)
# Level 1: [0] -> level 0; [1] a 2 MiB leaf over 0x80200000 with N; [2] the level-0 pointer with N.
.4byte 0x800021b7 # lui x3, 0x80002
.4byte 0x02019193 # slli x3, x3, 32
.4byte 0x0201d193 # srli x3, x3, 32
.4byte 0x20001137 # lui x2, 0x20001
.4byte 0xc0110113 # addi x2, x2, -1023
.4byte 0x0021b023 # sd x2, 0(x3)
.4byte 0x00100213 # addi x4, x0, 1
.4byte 0x03f21213 # slli x4, x4, 63
.4byte 0x004162b3 # or x5, x2, x4
.4byte 0x0051b823 # sd x5, 16(x3)
.4byte 0x20080337 # lui x6, 0x20080
.4byte 0x0cf30313 # addi x6, x6, 207
.4byte 0x00436333 # or x6, x6, x4
.4byte 0x0061b423 # sd x6, 8(x3)
# Level 0: slots 16..31 = NAPOT PTE (PPN 0x80018, R W A D V, N); slot 32 = N with PPN 0x80021.
.4byte 0x800033b7 # lui x7, 0x80003
.4byte 0x02039393 # slli x7, x7, 32
.4byte 0x0203d393 # srli x7, x7, 32
.4byte 0x20006437 # lui x8, 0x20006
.4byte 0x0cf40413 # addi x8, x8, 207
.4byte 0x00446433 # or x8, x8, x4
.4byte 0x08038493 # addi x9, x7, 128
.4byte 0x10038513 # addi x10, x7, 256
.4byte 0x0084b023 # sd x8, 0(x9)
.4byte 0x0084bc23 # sd x8, 24(x9)
.4byte 0x0684bc23 # sd x8, 120(x9)
.4byte 0x200085b7 # lui x11, 0x20008
.4byte 0x4cf58593 # addi x11, x11, 1231
.4byte 0x0045e5b3 # or x11, x11, x4
.4byte 0x00b53023 # sd x11, 0(x10)
# Data: 0x80013010 = 0x55, 0x8001f008 = 0x66.
.4byte 0x80013637 # lui x12, 0x80013
.4byte 0x02061613 # slli x12, x12, 32
.4byte 0x02065613 # srli x12, x12, 32
.4byte 0x05500693 # addi x13, x0, 85
.4byte 0x00d63823 # sd x13, 16(x12)
.4byte 0x8001f737 # lui x14, 0x8001f
.4byte 0x02071713 # slli x14, x14, 32
.4byte 0x02075713 # srli x14, x14, 32
.4byte 0x06600693 # addi x13, x0, 102
.4byte 0x00d73423 # sd x13, 8(x14)
# satp = Sv39, root 0x80001; MPRV = 1, MPP = S.
.4byte 0x000807b7 # lui x15, 0x80
.4byte 0x00178793 # addi x15, x15, 1
.4byte 0x0047e7b3 # or x15, x15, x4
.4byte 0x18079073 # csrw satp, x15
.4byte 0x12000073 # sfence.vma
.4byte 0x00021837 # lui x16, 0x21
.4byte 0x80080813 # addi x16, x16, -2048
.4byte 0x30082073 # csrs mstatus, x16
.4byte 0x000018b7 # lui x17, 0x1
# VA 0x13010 loads 0x55; VA 0x1f008 loads 0x66; a store through VA 0x13018 lands at 0x80013018.
.4byte 0x00013937 # lui x18, 0x13
.4byte 0x01093983 # ld x19, 16(x18)
.4byte 0x0001f937 # lui x18, 0x1f
.4byte 0x00893983 # ld x19, 8(x18)
.4byte 0x00013937 # lui x18, 0x13
.4byte 0x01393c23 # sd x19, 24(x18)
.4byte 0x30083073 # csrc mstatus, x16
.4byte 0x01863a03 # ld x20, 24(x12)
.4byte 0x30082073 # csrs mstatus, x16
# Slot 32: N with PPN[3:0] = 0001 is a load page fault.
.4byte 0x00020937 # lui x18, 0x20
.4byte 0x00093983 # ld x19, 0(x18)
.4byte 0x34202af3 # csrr x21, mcause
.4byte 0x34302b73 # csrr x22, mtval
.4byte 0x3008b073 # csrc mstatus, x17
# N in a 2 MiB leaf: load page fault.
.4byte 0x00200937 # lui x18, 0x200
.4byte 0x00893983 # ld x19, 8(x18)
.4byte 0x34202af3 # csrr x21, mcause
.4byte 0x34302b73 # csrr x22, mtval
.4byte 0x3008b073 # csrc mstatus, x17
# N in a pointer: store page fault.
.4byte 0x00400937 # lui x18, 0x400
.4byte 0x01393823 # sd x19, 16(x18)
.4byte 0x34202af3 # csrr x21, mcause
.4byte 0x34302b73 # csrr x22, mtval
.4byte 0x3008b073 # csrc mstatus, x17
.4byte 0x30083073 # csrc mstatus, x16
