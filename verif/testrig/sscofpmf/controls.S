# Deterministic Sscofpmf delegation, fields and aliases; selectors stay disabled.
# Minimized counterexample: LCOFI survives a write to a reserved mideleg bit.
.4byte 0x000020b7 # lui x1, 2: LCOFI mask
.4byte 0x3030a173 # csrrs x2, mideleg, x1
.4byte 0x3030e173 # csrrsi x2, mideleg, 1: old value 0x2000
.4byte 0x3030b1f3 # csrrc x3, mideleg, x1: clear LCOFI
.4byte 0x30302273 # csrrs x4, mideleg, x0: zero
# Probe the full WARL mask, then preserve the other bits while clearing LCOFI.
.4byte 0xfff00093 # addi x1, x0, -1
.4byte 0x30309173 # csrrw x2, mideleg, x1
.4byte 0x303021f3 # csrrs x3, mideleg, x0: 0x2222
.4byte 0x000020b7 # lui x1, 2
.4byte 0x3030b173 # csrrc x2, mideleg, x1
.4byte 0x30302273 # csrrs x4, mideleg, x0: 0x0222
# Exercise immediate set, clear and write, including reserved bits.
.4byte 0x30317173 # csrrci x2, mideleg, 2
.4byte 0x303161f3 # csrrsi x3, mideleg, 2
.4byte 0x30305273 # csrrwi x4, mideleg, 0
.4byte 0x303fd173 # csrrwi x2, mideleg, 31
.4byte 0x303021f3 # csrrs x3, mideleg, x0: 2
.4byte 0x303ff273 # csrrci x4, mideleg, 31
.4byte 0x303022f3 # csrrs x5, mideleg, x0: zero
# Counter controls and aliases.
.4byte 0xfff00313 # addi x6, x0, -1
.4byte 0x03c31313 # slli x6, x6, 60: OF, MINH, SINH, UINH only
.4byte 0x32331073 # CSR 0x323, op 1, x6, rd x0
.4byte 0x323022f3 # CSR 0x323, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x32431073 # CSR 0x324, op 1, x6, rd x0
.4byte 0x324022f3 # CSR 0x324, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x32531073 # CSR 0x325, op 1, x6, rd x0
.4byte 0x325022f3 # CSR 0x325, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x32631073 # CSR 0x326, op 1, x6, rd x0
.4byte 0x326022f3 # CSR 0x326, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x32731073 # CSR 0x327, op 1, x6, rd x0
.4byte 0x327022f3 # CSR 0x327, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x32831073 # CSR 0x328, op 1, x6, rd x0
.4byte 0x328022f3 # CSR 0x328, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x32931073 # CSR 0x329, op 1, x6, rd x0
.4byte 0x329022f3 # CSR 0x329, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x32a31073 # CSR 0x32a, op 1, x6, rd x0
.4byte 0x32a022f3 # CSR 0x32a, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x30601073 # CSR 0x306, op 1, x0, rd x0
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x00100313 # addi x6, x0, 1
.4byte 0x03f31313 # slli x6, x6, 63: OF mask
.4byte 0x323332f3 # CSR 0x323, op 3, x6, rd x5
.4byte 0x323022f3 # CSR 0x323, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x324332f3 # CSR 0x324, op 3, x6, rd x5
.4byte 0x324022f3 # CSR 0x324, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x325332f3 # CSR 0x325, op 3, x6, rd x5
.4byte 0x325022f3 # CSR 0x325, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x326332f3 # CSR 0x326, op 3, x6, rd x5
.4byte 0x326022f3 # CSR 0x326, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x327332f3 # CSR 0x327, op 3, x6, rd x5
.4byte 0x327022f3 # CSR 0x327, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x328332f3 # CSR 0x328, op 3, x6, rd x5
.4byte 0x328022f3 # CSR 0x328, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x329332f3 # CSR 0x329, op 3, x6, rd x5
.4byte 0x329022f3 # CSR 0x329, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0x32a332f3 # CSR 0x32a, op 3, x6, rd x5
.4byte 0x32a022f3 # CSR 0x32a, op 2, x0, rd x5
.4byte 0xda0022f3 # CSR 0xda0, op 2, x0, rd x5
.4byte 0xfff00313 # addi x6, x0, -1
.4byte 0x30631073 # CSR 0x306, op 1, x6, rd x0
.4byte 0xb0931073 # CSR 0xb09, op 1, x6, rd x0
.4byte 0xb09022f3 # CSR 0xb09, op 2, x0, rd x5
.4byte 0xc09022f3 # CSR 0xc09, op 2, x0, rd x5
.4byte 0xb0901073 # CSR 0xb09, op 1, x0, rd x0
.4byte 0xc09022f3 # CSR 0xc09, op 2, x0, rd x5
.4byte 0xb0a31073 # CSR 0xb0a, op 1, x6, rd x0
.4byte 0xb0a022f3 # CSR 0xb0a, op 2, x0, rd x5
.4byte 0xc0a022f3 # CSR 0xc0a, op 2, x0, rd x5
.4byte 0xb0a01073 # CSR 0xb0a, op 1, x0, rd x0
.4byte 0xc0a022f3 # CSR 0xc0a, op 2, x0, rd x5
.4byte 0xda001073 # CSR 0xda0, op 1, x0, rd x0
