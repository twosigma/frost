# A JAL, a JALR, or a taken branch between LR and SC keeps the reservation, so
# each SC succeeds (x6, x8, and x9 read 0). TestRIG's build disables branch
# prediction, so the JAL and JALR mispredict and recover at commit, which
# cancelled FROST's reservation until commit-time recovery stopped clearing it.
.4byte 0x80200a37 # lui x20, 0x80200
.4byte 0x020a1a13 # slli x20, x20, 32
.4byte 0x020a5a13 # srli x20, x20, 32
.4byte 0x000a0a13 # addi x20, x20, 0
.4byte 0x00700393 # addi x7, x0, 7
.4byte 0x100a22af # lr.w x5, (x20)
.4byte 0x0080006f # jal x0, 8
.4byte 0x187a232f # sc.w x6, x7, (x20)
.4byte 0x100a32af # lr.d x5, (x20)
.4byte 0x10000067 # jalr x0, 256(x0)
.4byte 0x187a342f # sc.d x8, x7, (x20)
.4byte 0x100a22af # lr.w x5, (x20)
.4byte 0x00000463 # beq x0, x0, 8
.4byte 0x187a24af # sc.w x9, x7, (x20)
