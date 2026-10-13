# FENCE r,0 (0x0200000F), a reserved FENCE hint, and PAUSE (FENCE w,0) both
# retire. FROST decoded fence r,0 as PAUSE, which no station completed, so
# nothing retired after it (issue #58).
.4byte 0x0200000f # fence r, 0
.4byte 0x00100093 # addi x1, x0, 1
.4byte 0x0100000f # pause
.4byte 0x00200113 # addi x2, x0, 2
.4byte 0x0210000f # fence r, w
.4byte 0x00300193 # addi x3, x0, 3
