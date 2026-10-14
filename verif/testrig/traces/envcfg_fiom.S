# menvcfg.FIOM and senvcfg.FIOM are writable, as the privileged
# specification requires once satp.MODE can leave Bare; FROST read both as
# zero. menvcfg also implements STCE, and senvcfg has no other field.
.4byte 0xfff00313 # addi x6, x0, -1
.4byte 0x30a31073 # csrw menvcfg, x6
.4byte 0x30a022f3 # csrr x5, menvcfg
.4byte 0x10a31073 # csrw senvcfg, x6
.4byte 0x10a023f3 # csrr x7, senvcfg
.4byte 0x10a0f073 # csrci senvcfg, 1
.4byte 0x10a02473 # csrr x8, senvcfg
.4byte 0x30a01073 # csrw menvcfg, x0
.4byte 0x30a024f3 # csrr x9, menvcfg
.4byte 0x30a0e073 # csrsi menvcfg, 1
.4byte 0x30a02573 # csrr x10, menvcfg
.4byte 0x30a01073 # csrw menvcfg, x0
