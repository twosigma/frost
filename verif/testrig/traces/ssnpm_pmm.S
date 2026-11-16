# Ssnpm: senvcfg.PMM (bits 33:32) WARL and U-mode pointer masking, run in M
# with MPRV and MPP = U so every data access has effective privilege U. Under
# Bare a tagged pointer loads, stores and adds through the zero-extended
# address; under Sv39 through the sign-extended one. A pointer whose
# transformed form is out of the map (Bare) or non-canonical (Sv39) faults
# with mtval = the transformed address. With MXR set nothing is masked.
# senvcfg.PMM: 10, then the reserved 01 keeps 10; 11, then 01 keeps 11.
# Tables: root 0x80001000, level 1 0x80002000, level 0 0x80003000; VA 0x4000
# is a U page over 0x80004000.
# Data word 77 at 0x80004010.
.4byte 0x800040b7 # lui x1, 0x80004
.4byte 0x02009093 # slli x1, x1, 32
.4byte 0x0200d093 # srli x1, x1, 32
.4byte 0x04d00113 # addi x2, x0, 77
.4byte 0x0020b823 # sd x2, 16(x1)
# senvcfg.PMM WARL.
.4byte 0x00200193 # addi x3, x0, 2
.4byte 0x02019193 # slli x3, x3, 32
.4byte 0x10a19073 # csrw senvcfg, x3
.4byte 0x10a02273 # csrr x4, senvcfg
.4byte 0x00100293 # addi x5, x0, 1
.4byte 0x02029293 # slli x5, x5, 32
.4byte 0x10a29073 # csrw senvcfg, x5
.4byte 0x10a02273 # csrr x4, senvcfg
.4byte 0x00300313 # addi x6, x0, 3
.4byte 0x02031313 # slli x6, x6, 32
.4byte 0x10a31073 # csrw senvcfg, x6
.4byte 0x10a02273 # csrr x4, senvcfg
.4byte 0x10a29073 # csrw senvcfg, x5
.4byte 0x10a02273 # csrr x4, senvcfg
# MPRV = 1, MPP = U.
.4byte 0x000023b7 # lui x7, 0x2
.4byte 0x80038393 # addi x7, x7, -2048
.4byte 0x3003b073 # csrc mstatus, x7
.4byte 0x00020437 # lui x8, 0x20
.4byte 0x30042073 # csrs mstatus, x8
# Bare, PMLEN 16: tag 0xABCD loads 77; store 99 through tag 0x1234, load through 0xFFFF.
.4byte 0xabcd04b7 # lui x9, 0xabcd0
.4byte 0x02049493 # slli x9, x9, 32
.4byte 0x0090e533 # or x10, x1, x9
.4byte 0x01053583 # ld x11, 16(x10)
.4byte 0x12340637 # lui x12, 0x12340
.4byte 0x02061613 # slli x12, x12, 32
.4byte 0x00c0e6b3 # or x13, x1, x12
.4byte 0x06300713 # addi x14, x0, 99
.4byte 0x00e6bc23 # sd x14, 24(x13)
.4byte 0xfff00793 # addi x15, x0, -1
.4byte 0x03079793 # slli x15, x15, 48
.4byte 0x00f0e833 # or x16, x1, x15
.4byte 0x01883583 # ld x11, 24(x16)
.4byte 0x00e6b5af # amoadd.d x11, x14, (x13)
.4byte 0x00053583 # ld x11, 0(x10)
# Bare, PMLEN 16: bit 47 set leaves the map: load access fault, mtval zero-extended.
.4byte 0x00100893 # addi x17, x0, 1
.4byte 0x02f89893 # slli x17, x17, 47
.4byte 0x01156933 # or x18, x10, x17
.4byte 0x01093583 # ld x11, 16(x18)
.4byte 0x342029f3 # csrr x19, mcause
.4byte 0x34302a73 # csrr x20, mtval
.4byte 0x3003b073 # csrc mstatus, x7
# Bare, PMLEN 7 (senvcfg = 10): tag in bits 63:57 loads; bits 56:48 still fault.
.4byte 0x10a19073 # csrw senvcfg, x3
.4byte 0xb4000ab7 # lui x21, 0xb4000
.4byte 0x020a9a93 # slli x21, x21, 32
.4byte 0x0150eb33 # or x22, x1, x21
.4byte 0x010b3583 # ld x11, 16(x22)
.4byte 0x02eb3023 # sd x14, 32(x22)
.4byte 0x0200b583 # ld x11, 32(x1)
.4byte 0x01053583 # ld x11, 16(x10)
.4byte 0x342029f3 # csrr x19, mcause
.4byte 0x34302a73 # csrr x20, mtval
.4byte 0x3003b073 # csrc mstatus, x7
# Page tables (written with MPRV clear), satp = Sv39, sfence.vma.
.4byte 0x30043073 # csrc mstatus, x8
.4byte 0x80001bb7 # lui x23, 0x80001
.4byte 0x020b9b93 # slli x23, x23, 32
.4byte 0x020bdb93 # srli x23, x23, 32
.4byte 0x20001c37 # lui x24, 0x20001
.4byte 0x801c0c13 # addi x24, x24, -2047
.4byte 0x018bb023 # sd x24, 0(x23)
.4byte 0x80002cb7 # lui x25, 0x80002
.4byte 0x020c9c93 # slli x25, x25, 32
.4byte 0x020cdc93 # srli x25, x25, 32
.4byte 0x20001c37 # lui x24, 0x20001
.4byte 0xc01c0c13 # addi x24, x24, -1023
.4byte 0x018cb023 # sd x24, 0(x25)
.4byte 0x80003d37 # lui x26, 0x80003
.4byte 0x020d1d13 # slli x26, x26, 32
.4byte 0x020d5d13 # srli x26, x26, 32
.4byte 0x20001c37 # lui x24, 0x20001
.4byte 0x0d7c0c13 # addi x24, x24, 215
.4byte 0x038d3023 # sd x24, 32(x26)
.4byte 0x00100d93 # addi x27, x0, 1
.4byte 0x03fd9d93 # slli x27, x27, 63
.4byte 0x00080e37 # lui x28, 0x80
.4byte 0x001e0e13 # addi x28, x28, 1
.4byte 0x01cdedb3 # or x27, x27, x28
.4byte 0x180d9073 # csrw satp, x27
.4byte 0x12000073 # sfence.vma
.4byte 0x30042073 # csrs mstatus, x8
# Sv39, PMLEN 7: VA 0x4010 tagged 0x5A loads 77; bit 56 set is non-canonical (load page fault, mtval sign-extended).
.4byte 0x00004eb7 # lui x29, 0x4
.4byte 0x015eef33 # or x30, x29, x21
.4byte 0x010f3583 # ld x11, 16(x30)
.4byte 0x00ef35af # amoadd.d x11, x14, (x30)
.4byte 0x000f3583 # ld x11, 0(x30)
.4byte 0x00100f93 # addi x31, x0, 1
.4byte 0x038f9f93 # slli x31, x31, 56
.4byte 0x01ff6f33 # or x30, x30, x31
.4byte 0x010f3583 # ld x11, 16(x30)
.4byte 0x342029f3 # csrr x19, mcause
.4byte 0x34302a73 # csrr x20, mtval
.4byte 0x3003b073 # csrc mstatus, x7
# Sv39, PMLEN 16: tag 0xABCD stores and loads; bit 47 set faults (store page fault).
.4byte 0x10a31073 # csrw senvcfg, x6
.4byte 0x009eef33 # or x30, x29, x9
.4byte 0x022f3423 # sd x2, 40(x30)
.4byte 0x00feef33 # or x30, x29, x15
.4byte 0x028f3583 # ld x11, 40(x30)
.4byte 0x009eef33 # or x30, x29, x9
.4byte 0x011f6f33 # or x30, x30, x17
.4byte 0x022f3823 # sd x2, 48(x30)
.4byte 0x342029f3 # csrr x19, mcause
.4byte 0x34302a73 # csrr x20, mtval
.4byte 0x3003b073 # csrc mstatus, x7
# MXR set: no masking, so the tagged pointer is non-canonical with mtval unchanged.
.4byte 0x00080fb7 # lui x31, 0x80
.4byte 0x300fa073 # csrs mstatus, x31
.4byte 0x009eef33 # or x30, x29, x9
.4byte 0x010f3583 # ld x11, 16(x30)
.4byte 0x342029f3 # csrr x19, mcause
.4byte 0x34302a73 # csrr x20, mtval
.4byte 0x3003b073 # csrc mstatus, x7
.4byte 0x300fb073 # csrc mstatus, x31
# PMM = 00: the same pointer faults.
.4byte 0x10a01073 # csrw senvcfg, x0
.4byte 0x010f3583 # ld x11, 16(x30)
.4byte 0x342029f3 # csrr x19, mcause
.4byte 0x34302a73 # csrr x20, mtval
.4byte 0x3003b073 # csrc mstatus, x7
.4byte 0x30043073 # csrc mstatus, x8
