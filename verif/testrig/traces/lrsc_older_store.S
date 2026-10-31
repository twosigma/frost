# Six Device stores precede a store to the other word of the LR's doubleword.
# LR waits for every older committed store to drain before it reads.
# Both SCs succeed, so x6 and x9 read zero.
.4byte 0x00030cb7 # lui x25, 0x30
.4byte 0x40100e37 # lui x28, 0x40100
.4byte 0x008c8d13 # addi x26, x25, 8
.4byte 0x00cc8c13 # addi x24, x25, 12
.4byte 0x00700393 # addi x7, x0, 7
.4byte 0x001e1523 # sh x1, 10(x28)
.4byte 0x001e1623 # sh x1, 12(x28)
.4byte 0x001e1723 # sh x1, 14(x28)
.4byte 0x001e1823 # sh x1, 16(x28)
.4byte 0x001e1923 # sh x1, 18(x28)
.4byte 0x001e1a23 # sh x1, 20(x28)
.4byte 0x007ca623 # sw x7, 12(x25)
.4byte 0x100d22af # lr.w x5, (x26)
.4byte 0x187d232f # sc.w x6, x7, (x26)
.4byte 0x001e1523 # sh x1, 10(x28)
.4byte 0x001e1623 # sh x1, 12(x28)
.4byte 0x001e1723 # sh x1, 14(x28)
.4byte 0x001e1823 # sh x1, 16(x28)
.4byte 0x001e1923 # sh x1, 18(x28)
.4byte 0x001e1a23 # sh x1, 20(x28)
.4byte 0x007ca423 # sw x7, 8(x25)
.4byte 0x100c22af # lr.w x5, (x24)
.4byte 0x187c24af # sc.w x9, x7, (x24)
