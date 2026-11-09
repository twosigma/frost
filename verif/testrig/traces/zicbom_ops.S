# Zicbom: cbo.clean, cbo.flush and cbo.inval in M on cached DDR, low BRAM,
# device windows and beyond the map, with the CBIE and CBCFE fields.
# Sail 0.16 and FROST agree when this trace replays (DESIGN open check 6).
# CBIE is WARL {00, 01, 11}: FROST stores 00 for a write of the reserved 10.
.4byte 0x02000313 # addi x6, x0, 32
.4byte 0x30a31073 # csrw menvcfg, x6
.4byte 0x30a022f3 # csrr x5, menvcfg
.4byte 0x10a31073 # csrw senvcfg, x6
.4byte 0x10a023f3 # csrr x7, senvcfg
# CBCFE and CBIE = 11 in menvcfg, CBIE = 01 in senvcfg.
.4byte 0x07000313 # addi x6, x0, 112
.4byte 0x30a31073 # csrw menvcfg, x6
.4byte 0x30a022f3 # csrr x5, menvcfg
.4byte 0x01000313 # addi x6, x0, 16
.4byte 0x10a31073 # csrw senvcfg, x6
.4byte 0x10a023f3 # csrr x7, senvcfg
# In M every op executes. Cached DDR, with a store and a load around them.
.4byte 0x00100493 # addi x9, x0, 1
.4byte 0x01f49493 # slli x9, x9, 31
.4byte 0x07b00513 # addi x10, x0, 123
.4byte 0x04a4b423 # sd x10, 72(x9)
.4byte 0x04548593 # addi x11, x9, 69
.4byte 0x0015a00f # cbo.clean (x11)
.4byte 0x0025a00f # cbo.flush (x11)
.4byte 0x0005a00f # cbo.inval (x11)
.4byte 0x0484b603 # ld x12, 72(x9)
# Low BRAM.
.4byte 0x7c500693 # addi x13, x0, 1989
.4byte 0x0016a00f # cbo.clean (x13)
.4byte 0x0026a00f # cbo.flush (x13)
.4byte 0x0006a00f # cbo.inval (x13)
# Device windows (D4: no-op where a load or store is permitted).
.4byte 0x40000437 # lui x8, 0x40000
.4byte 0x0014200f # cbo.clean (x8)
.4byte 0x0024200f # cbo.flush (x8)
.4byte 0x0004200f # cbo.inval (x8)
.4byte 0x44000737 # lui x14, 0x44000
.4byte 0x0027200f # cbo.flush (x14)
.4byte 0x40031737 # lui x14, 0x40031
.4byte 0x0017200f # cbo.clean (x14)
.4byte 0x0007200f # cbo.inval (x14)
# Beyond DDR: store access fault, mtval = rs1.
.4byte 0x00300713 # addi x14, x0, 3
.4byte 0x01e71713 # slli x14, x14, 30
.4byte 0x01370713 # addi x14, x14, 19
.4byte 0x0017200f # cbo.clean (x14)
.4byte 0x342027f3 # csrr x15, mcause
.4byte 0x34302873 # csrr x16, mtval
.4byte 0x0007200f # cbo.inval (x14)
.4byte 0x342027f3 # csrr x15, mcause
.4byte 0x34302873 # csrr x16, mtval
# Unassigned funct12 0x003 is illegal.
.4byte 0x0034a00f # cbo funct12=0x003 (x9)
.4byte 0x342027f3 # csrr x15, mcause
.4byte 0x30a01073 # csrw menvcfg, x0
.4byte 0x10a01073 # csrw senvcfg, x0
